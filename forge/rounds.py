"""Round history for the build loop (forge/loop.py): what each improvement round changed.

Every round used to start from nothing: the critic never saw the last round, the fixer never learned what
its last fix did, and issues on read-only kit files were dropped without a word. So the same issues came back
round after round at the same score. These pure functions turn state.json and iterations/<n>/ into:
- acceptance progress: which acceptance counters fire this round, and which no script can ever bump;
- a "## Previous rounds" block for the critic, so it judges the change instead of starting over;
- per-file corrections for the fixer, using the ledger's RETRY_MARK, so a fix that did not make its counter
  fire becomes a correction in the fixer's own Mubit task (forge/ledger.py counts it);
- one plain line per round for the MuMake panel.
No LLM calls here.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Callable

RETRY_MARK = "## Your previous fix was rejected"  # forge.ledger.RETRY_MARK
COUNTER_RX = re.compile(r"\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b")
HISTORY_ROUNDS = 4
ISSUE_CHARS = 160


def acceptance_counters(spec: dict) -> list[str]:
    """Counter names (snake_case words) the spec's acceptance criteria name, in order."""
    text = " ".join(str(a) for a in spec.get("acceptance") or [])
    return list(dict.fromkeys(COUNTER_RX.findall(text)))


def mentioned(text: str, names: list[str]) -> list[str]:
    return [c for c in names if re.search(rf"\b{re.escape(c)}\b", text or "")]


def _fired(counters: dict, name: str) -> bool:
    try:
        return float(counters.get(name) or 0) > 0
    except (TypeError, ValueError):
        return False


def acceptance(spec: dict, counters: dict | None, sources: dict[str, str] | None = None) -> dict:
    """{"named", "met", "missing", "unemitted"}: unemitted = missing counters no script even names as a
    string, so no playtest can see them until an editable file bumps them."""
    named = acceptance_counters(spec)
    counters = counters or {}
    met = [c for c in named if _fired(counters, c)]
    # "player_fell or player_died increments": one alternative firing meets the criterion
    either = set()
    for a in spec.get("acceptance") or []:
        for x, y in re.findall(r"\b([a-z][a-z0-9]*(?:_[a-z0-9]+)+)\s+or\s+([a-z][a-z0-9]*(?:_[a-z0-9]+)+)\b", str(a)):
            if _fired(counters, x) or _fired(counters, y):
                either |= {x, y}
    missing = [c for c in named if c not in met and c not in either]
    met = [c for c in named if c not in missing]
    out = {"named": named, "met": met, "missing": missing}
    if sources is not None:
        text = "\n".join(sources.values())
        out["unemitted"] = [c for c in missing if not re.search(rf"""["']{re.escape(c)}["']""", text)]
    return out


def _short(path: str) -> str:
    return Path(str(path)).name.split(".")[0] or str(path)


def _matches(issue_path: str, path: str) -> bool:
    ip = str(issue_path or "").strip().replace("\\", "/")
    return bool(ip) and (ip == path or path.endswith("/" + ip) or _short(ip).lower() == _short(path).lower())


def past_rounds(iterations: list[dict], spec: dict, load: Callable[[int, str], Any]) -> list[dict]:
    """state["iterations"] -> [{n, score, met, missing, fixed: {path: [counters asked]}, issues, rolled_back}],
    oldest first. Rounds saved before this module existed are rebuilt from report.json and record.json."""
    out = []
    for it in sorted((i for i in iterations if isinstance(i, dict)), key=lambda i: i.get("n", 0)):
        n = it.get("n")
        acc = it.get("acceptance")
        if not isinstance(acc, dict) or "met" not in acc:
            report = load(n, "report.json") or {}
            acc = acceptance(spec, report.get("counters") or {})
        fixed = it.get("fixed")
        if not isinstance(fixed, dict):
            rec = load(n, "record.json") or {}
            paths = list(dict.fromkeys(f.get("path") for f in rec.get("fixes") or []
                                       if f.get("kind") == "critic" and f.get("path")))
            fixed = {}
            for p in paths:
                text = " ".join(f"{i.get('problem', '')} {i.get('fix_hint', '')}"
                                for i in it.get("issues") or [] if _matches(i.get("path"), p))
                fixed[p] = mentioned(text, acceptance_counters(spec))
        out.append({"n": n, "score": it.get("score"), "met": list(acc.get("met") or []),
                    "missing": list(acc.get("missing") or []), "fixed": fixed,
                    "issues": [i for i in it.get("issues") or [] if isinstance(i, dict)],
                    "rolled_back": it.get("rolled_back_to")})
    return out


def _fmt_score(score: Any) -> str:
    return "?" if score is None else f"{float(score):g}"


def _acc(r: dict) -> str:
    total = len(r["met"]) + len(r["missing"])
    return f"{len(r['met'])}/{total}" if total else "n/a"


def critic_block(history: list[dict], now: dict, read_only: list[str], blocked: list[dict] | None = None) -> str:
    """The critic's "## Previous rounds" section ("" on the first round)."""
    if not history:
        return ""
    lines = ["## Previous rounds (judge what changed since the last round)"]
    for r in history[-HISTORY_ROUNDS:]:
        miss = f" (missing: {', '.join(r['missing'][:6])})" if r["missing"] else ""
        fixed = ", ".join(_short(p) for p in r["fixed"]) or "nothing"
        rb = f"; rolled back to {r['rolled_back']}" if r.get("rolled_back") else ""
        lines.append(f"- Round {r['n']}: score {_fmt_score(r['score'])}, acceptance counters {_acc(r)}{miss}; "
                     f"fixer then changed: {fixed}{rb}")
    last = history[-1]
    newly = [c for c in now.get("met") or [] if c not in last["met"]]
    lost = [c for c in last["met"] if c in (now.get("missing") or [])]
    total = len(now.get("met") or []) + len(now.get("missing") or [])
    lines.append(f"- This round: acceptance counters {len(now.get('met') or [])}/{total}"
                 + (f"; now firing: {', '.join(newly)}" if newly else "; nothing new fires")
                 + (f"; stopped firing: {', '.join(lost)}" if lost else "")
                 + (f"; still missing: {', '.join(now['missing'][:6])}" if now.get("missing") else ""))
    if last["issues"]:
        lines.append(f"Round {last['n']} issues the fixer worked on:")
        lines += [f"- {i.get('path', '?')}: {str(i.get('problem', ''))[:ISSUE_CHARS]}" for i in last["issues"][:6]]
    recurring = [c for c in now.get("missing") or []
                 if sum(c in r["missing"] for r in history[-HISTORY_ROUNDS:]) >= 2]
    if recurring:
        lines.append(f"Missing for several rounds in a row: {', '.join(recurring)}. The fixes so far did not work: "
                     "name the root cause, not the same symptom again.")
    if now.get("unemitted"):
        lines.append("No script contains the counter name "
                     + ", ".join(f'"{c}"' for c in now["unemitted"])
                     + ": point that issue at an editable file that can bump it where the moment happens.")
    if read_only:
        lines.append("Read-only Forge kit files (the fixer cannot edit them; an issue on them is skipped): "
                     + ", ".join(read_only))
    if blocked:
        lines.append(f"Skipped last round, on read-only files: "
                     + "; ".join(f"{b['path']}: {str(b.get('problem', ''))[:100]}" for b in blocked[:3]))
    lines.append("Do not re-raise an issue the counters show is fixed. Score this round on its own evidence.")
    return "\n".join(lines) + "\n\n"


def read_only_list(protected: set[str], runtime: tuple[str, ...]) -> list[str]:
    """Protected files worth naming to the critic: kit and template files; level data as one glob."""
    names = sorted(p for p in protected if p not in runtime and "/Levels/" not in p)
    if any("/Levels/" in p for p in protected):
        names.append("ReplicatedStorage/Levels/*")
    return names


def streak(history: list[dict], path: str, counter: str) -> int:
    """Rounds in a row (newest back) whose fixer was asked to make `counter` fire in `path`."""
    k = 0
    for r in reversed(history):
        if counter in (r["fixed"].get(path) or []):
            k += 1
        else:
            break
    return k


def fixer_correction(history: list[dict], path: str, now: dict) -> tuple[str, str]:
    """(text for the fixer's problem, one line for the round) about this file's previous fix. A fix whose
    counter still does not fire is a rejection (RETRY_MARK); one that made it fire is confirmed."""
    if not history:
        return "", ""
    last = history[-1]
    asked = last["fixed"].get(path)
    if asked is None:
        return "", ""
    still = [c for c in asked if c in (now.get("missing") or [])]
    worked = [c for c in asked if c in (now.get("met") or []) and c not in last["met"]]
    name = _short(path)
    if still:
        tries = streak(history, path, still[0])
        text = (f"{RETRY_MARK}\nRound {last['n']} asked you to make {', '.join(still)} fire from this file. "
                f"The playtest after your fix still shows {', '.join(still)} at 0"
                f" ({tries} round{'s' if tries != 1 else ''} in a row; score {_fmt_score(last['score'])}"
                f" -> {_fmt_score(now.get('score'))}). Try a different approach: find why the event never "
                "happens or is never counted, not the same change again.")
        if worked:
            text += f" Your fix did make {', '.join(worked)} fire: keep that code path intact."
        if [c for c in still if c in (now.get("unemitted") or [])]:
            text += (" No script contains the name " + ", ".join(f'"{c}"' for c in still
                                                                  if c in (now.get('unemitted') or []))
                     + ", so nothing can bump it until a file you can edit calls Telemetry.count with it.")
        return text, f"{name} left {still[0]} at 0 after {tries} {'try' if tries == 1 else 'tries'}, told to try another way"
    if worked:
        text = (f"## Your last fix on this file worked\nRound {last['n']} asked for {', '.join(worked)}; "
                "they fire now. Keep that code path intact.")
        return text, f"{name} fix confirmed ({', '.join(worked)} fire)"
    return "", ""


def trend(history: list[dict], score: Any) -> str:
    scores = [_fmt_score(r["score"]) for r in history[-HISTORY_ROUNDS:]] + [_fmt_score(score)]
    return "Score by round (oldest first, this round last): " + ", ".join(scores)


def round_line(prev: dict | None, rec: dict) -> str:
    """'score 5 -> 6, acceptance 11/13 -> 12/13 (+ride_gate_used); fixed: A, B; taught the fixer: ...'"""
    acc = rec.get("acceptance") or {}
    now = {"met": acc.get("met") or [], "missing": acc.get("missing") or []}
    score = _fmt_score(rec.get("score"))
    parts = []
    if prev:
        parts.append(f"score {_fmt_score(prev['score'])} -> {score}")
        if now["met"] or now["missing"]:
            newly = [c for c in now["met"] if c not in prev["met"]]
            lost = [c for c in prev["met"] if c in now["missing"]]
            delta = ", ".join([f"+{c}" for c in newly] + [f"-{c}" for c in lost])
            parts.append(f"acceptance {_acc(prev)} -> {_acc(now)}" + (f" ({delta})" if delta else ""))
    else:
        parts.append(f"score {score}")
        if now["met"] or now["missing"]:
            parts.append(f"acceptance {_acc(now)}")
    head = ", ".join(parts)
    tail = []
    if rec.get("rolled_back_to"):
        tail.append(f"rolled back to {rec['rolled_back_to']}")
    fixed = list(dict.fromkeys(_short(f["path"]) for f in rec.get("fixes") or [] if f.get("kind") == "critic"))
    if fixed:
        tail.append("fixed: " + ", ".join(fixed))
    if rec.get("blocked_issues"):
        tail.append(f"skipped {len(rec['blocked_issues'])} on read-only kit files")
    if rec.get("taught"):
        tail.append("taught the fixer: " + "; ".join(rec["taught"][:2]))
    return "; ".join([head] + tail)


# ---------------------------------------------------------------- obby rounds, per docs/GAME_PRODUCTION_GUIDE.md
# The guide's obby recipe (6): movement and recovery -> reachable course -> checkpoints -> completion -> variety,
# and (10) no rounds on cosmetics while required gameplay is incomplete. A real run spent 21 fixes on gifts, FX
# and sound while lava did not kill and QA bots fell at stages 1, 71 and 92.

OBBY_RX = re.compile(r"\b(obby|obbies|platformer|parkour)\b", re.I)
REQUIRED_RX = re.compile(r"checkpoint|respawn|kill|lava|hazard|\bfell\b|\bfall|\bdie|\bdied|death|reach|jump|"
                         r"finish|stuck|spawn|course|stage \d", re.I)
QA_FILE = "qa_latest.json"  # written by the MuMake companion's Studio QA bots (mubit_tester.studio_service)

OBBY_RECIPE = (
    "## What this genre needs first (production guide: obby recipe)\n"
    "Judge and order work as: movement and recovery -> reachable course -> checkpoints and respawn -> falls and "
    "hazards that kill -> finish -> the promised stage count; only then difficulty curve, distinct obstacles, "
    "rewards, effects and sound. While any required item fails, put it first in your issues and do not let "
    "cosmetic polish raise the score. A bot that fails once may be the bot: weigh repeated failures at the same "
    "stage, not one fall.")


def is_obby(spec: dict) -> bool:
    """Generated specs often leave genre empty: a course laid out in zones (spec.levels) is an obby too."""
    if (spec.get("levels") or {}).get("zones"):
        return True
    return bool(OBBY_RX.search(f"{spec.get('genre') or ''} {spec.get('title') or ''} {spec.get('pitch') or ''}"))


def read_qa(run_dir: Path) -> dict | None:
    try:
        data = json.loads((Path(run_dir) / QA_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) and isinstance(data.get("bots"), list) else None


def guide_block(spec: dict, qa: dict | None) -> str:
    """The obby recipe and the latest Studio QA bots' play, for the critic's user message ("" for other genres)."""
    if not is_obby(spec):
        return ""
    parts = [OBBY_RECIPE]
    bots = [b for b in (qa or {}).get("bots") or [] if isinstance(b, dict)]
    if bots:
        ok = sum(1 for b in bots if b.get("reached"))
        rows = [f"- {b.get('zone', '?')} stage {b.get('stage', '?')}: "
                + ("reached the next checkpoint" if b.get("reached") else f"did NOT: {str(b.get('detail', ''))[:160]}")
                for b in bots]
        parts.append(f"## Studio QA bots, last install (real play in Studio, {b0 if (b0 := qa.get('attempts')) else 1} "
                     f"attempt(s) each): {ok}/{len(bots)} reached the next checkpoint\n" + "\n".join(rows))
    return "\n\n".join(parts)


def studio_counters(report_counters: dict, qa: dict | None) -> tuple[dict, list[str]]:
    """The playtest's counters plus those the last Studio QA play of this same version fired (touch pads, gates,
    the finish: things the headless engine cannot fire). Returns (merged, names that only Studio showed)."""
    seen = {k: v for k, v in ((qa or {}).get("counters") or {}).items() if isinstance(v, (int, float)) and v > 0}
    merged = dict(report_counters or {})
    added = [k for k in seen if not merged.get(k)]
    for k in added:
        merged[k] = seen[k]
    return merged, added


def required_first(spec: dict, text: str) -> bool:
    """Is this issue about the obby's required gameplay (the recipe's proof), not polish?"""
    return is_obby(spec) and bool(REQUIRED_RX.search(text))


def unexercised_block(acc: dict) -> str:
    """Counters a script does bump but that read 0: the headless player never did those actions (buy, finish all
    stages, take a ride gate). Production guide 9.3: an unexercised case is unknown, not a failed one. A real run
    sat at 5/10 for rounds while the fixer rewrote working code for exactly these."""
    gone = set(acc.get("unemitted") or [])
    idle = [c for c in acc.get("missing") or [] if c not in gone]
    if not idle:
        return ""
    return ("## Not exercised by this playtest (unknown, not broken)\n"
            f"A script bumps {', '.join(idle[:8])}, but the scripted headless player never did those actions, so they "
            "read 0. Judge those features from the code that bumps them and from the Studio QA bots. Do not lower the "
            "score or ask for a rewrite only because they read 0; raise an issue only if the code path is wrong.")


# ---------------------------------------------------------------- dead ends, carried from build to build
# The reflector rewrites runs/lessons.md each round, so what one build could never fix lives in its own file:
# runs/dead_ends.json, one entry per game (its latest rounds). The next build's director and designer read it,
# and the reflector (a Mubit task) reflects on it with each round's summary.

DEAD_ENDS_FILE = "dead_ends.json"
DEAD_ENDS_KEEP = 8  # builds remembered
DEAD_ENDS_LINES = 12  # lines in the block a new build reads
CHURN_ROUNDS = 3  # a file fixed this many rounds while the score stays flat is a dead end


def dead_ends(iterations: list[dict], spec: dict) -> list[str]:
    """Plain lines on what this build's rounds could not fix, from state.json iterations (newest last)."""
    its = [it for it in iterations if isinstance(it, dict)]
    if not its:
        return []
    acc = its[-1].get("acceptance") or {}
    unemitted = list(acc.get("unemitted") or [])
    out = [f'"{c}" was promised in acceptance but nothing ever counted it ({len(its)} rounds): only promise '
           "counters the kit or a game script really bumps" for c in unemitted]
    out += [f'"{c}" stayed 0 through {len(its)} rounds of fixes: design it so a normal playtest triggers it'
            for c in acc.get("missing") or [] if c not in unemitted]
    churn: dict[str, int] = {}
    for it in its:
        for path in (it.get("fixed") or {}):
            churn[path] = churn.get(path, 0) + 1
    scores = [it["score"] for it in its if isinstance(it.get("score"), (int, float))]
    stuck = [p for p, n in sorted(churn.items(), key=lambda x: -x[1]) if n >= CHURN_ROUNDS]
    if stuck and scores and max(scores) - min(scores) <= 1:
        out.append(f"{', '.join(_short(p) for p in stuck[:3])} were rewritten {churn[stuck[0]]} rounds while the "
                   f"score stayed {_fmt_score(min(scores))}-{_fmt_score(max(scores))}: plan that system simpler "
                   "from the start")
    blocked = its[-1].get("blocked_issues") or []
    if blocked:
        files = sorted({_short(str(b.get("path", ""))) for b in blocked if isinstance(b, dict)})
        out.append(f"{len(blocked)} critic issues were on read-only kit files ({', '.join(files[:3])}): ask for "
                   "those behaviours from game-owned scripts instead")
    return out[:6]


def read_dead_ends(runs_dir: Path) -> list[dict]:
    try:
        data = json.loads((Path(runs_dir) / DEAD_ENDS_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    return [e for e in data if isinstance(e, dict)] if isinstance(data, list) else []


def record_dead_ends(runs_dir: Path, slug: str, spec: dict, iterations: list[dict]) -> list[str]:
    """Replace this game's entry with its current dead ends (none: the entry goes). Returns its lines."""
    lines = dead_ends(iterations, spec)
    keep = [e for e in read_dead_ends(runs_dir) if e.get("slug") != slug]
    if lines:
        keep.append({"slug": slug, "title": str(spec.get("title") or slug), "genre": str(spec.get("genre") or ""),
                     "rounds": len([it for it in iterations if isinstance(it, dict)]), "lines": lines})
    path = Path(runs_dir) / DEAD_ENDS_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(keep[-DEAD_ENDS_KEEP:], indent=1), encoding="utf-8")
    return lines


def dead_ends_block(runs_dir: Path, exclude: str | None = None) -> str:
    """The block a new build's director and designer read (newest builds first); "" when there is none."""
    rows = []
    for e in reversed(read_dead_ends(runs_dir)):
        if e.get("slug") == exclude:
            continue
        who = e.get("title") or e.get("slug")
        rows += [f"- {who}{f' ({g})' if (g := e.get('genre')) else ''}: {line}" for line in e.get("lines") or []]
    if not rows:
        return ""
    return ("\n\n## Dead ends from earlier builds (Forge could not fix these in their improvement rounds; "
            "design around them)\n" + "\n".join(rows[:DEAD_ENDS_LINES]) + "\n")
