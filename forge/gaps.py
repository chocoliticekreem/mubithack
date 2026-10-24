"""Trace-driven gap finder: what is still missing or broken in a game, ranked, with evidence.

It reads everything Forge already records for runs/<slug>/ (no Studio, no writes outside
orchestrator/):
- critic iterations (state.json, iterations/<n>/critique.json + screenshot.png),
- AI tester runs (tests/<run>/report.json + step-NN.json/.png),
- executable checks (checks/results.json), fix cycles (improve/<n>.json, scores.json),
- features (features.jsonl), human tester reports (improve/reports.jsonl),
- Mubit calls (calls.jsonl: failures per role) and traces (calls per role),
- the readiness bar (forge done) and a static scan of the game code against a genre checklist.

Every evidence line gets a reference id ([critic:2], [test:<run>/step-03], [check:<id>], ...). The
`gap_finder` Mubit task (forge/prompts/gap_finder.md, fixed) turns that into a ranked list of gaps,
each with evidence refs, an impact score and one concrete Forge job (fix | feature | visual).
parse_gaps() keeps only refs that exist, so a gap can't cite evidence nobody recorded.

Human corrections on a gap list (`forge gaps <slug> --correct "..."`, `--reject <id>`) go to the same
Mubit task with the previous list in the user message, so the gap finder learns from them.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from forge.config import Settings
from forge.memory import RunStore, slugify

ROLE = "gap_finder"
MAX_GAPS = 12
MAX_USER_CHARS = 30_000
JOB_KINDS = ("fix", "feature", "visual")
GAP_KINDS = ("broken", "missing", "polish")
RUNTIME_FILES = ("ForgeProbe", "ForgeTest", "ForgeTelemetry", "ForgeTestAgent", "DevHook")
CORRECTION_MARK = "## Correction from the developer"

# ---------------------------------------------------------------- genre checklists
# Each item: id, label, why players care, and code signals (all regexes in a group must hit some file;
# any group may match). The scan only says "mentioned in code"; the gap finder weighs it against tests.

CHECKLISTS: dict[str, list[dict]] = {
    "tycoon": [
        {"id": "plot_claiming", "label": "plot claiming (claim gate/pad, one owner per plot, freed on leave)",
         "signals": [[r"[Cc]laim"], [r"\bOwner\b", r"PlayerRemoving"]]},
        {"id": "droppers_tiers", "label": "droppers with tiers (better droppers, higher cube value)",
         "signals": [[r"[Dd]ropper", r"[Tt]ier|[Ll]evel|DROPPERS\s*="]]},
        {"id": "conveyor_collector", "label": "conveyor + collector that pays out",
         "signals": [[r"[Cc]onveyor", r"[Cc]ollector"]]},
        {"id": "upgrade_tree", "label": "upgrade tree (several buyable upgrades that unlock in order)",
         "signals": [[r"[Uu]pgrade", r"[Rr]equires|[Uu]nlock|prereq"]]},
        {"id": "rebirth", "label": "rebirth / prestige (reset for a permanent multiplier)",
         "signals": [[r"[Rr]ebirth|[Pp]restige"]]},
        {"id": "shop_ui", "label": "shop UI (buttons with prices, affordability, purchase feedback)",
         "signals": [[r"ScreenGui|Frame", r"[Ss]hop|[Bb]uy"]]},
        {"id": "leaderboard", "label": "leaderboard (leaderstats and/or a world leaderboard)",
         "signals": [[r"leaderstats"], [r"OrderedDataStore|[Ll]eaderboard"]]},
        {"id": "saving", "label": "saving progress (DataStore, with retries and session lock)",
         "signals": [[r"DataStoreService|GetDataStore|ProfileStore|ProfileService"]]},
        {"id": "tutorial", "label": "tutorial / first 60 seconds (arrow, hints, first purchase guided)",
         "signals": [[r"[Tt]utorial|[Oo]nboard|[Gg]uide|Beam|[Aa]rrow|[Hh]int"]]},
        {"id": "juice_sound", "label": "juice: sounds (buy, cash, rebirth, ambient)",
         "signals": [[r"Instance\.new\(\s*\"Sound\"|SoundId"]]},
        {"id": "juice_particles", "label": "juice: particles (sparkles on cash/buy, dropper puffs)",
         "signals": [[r"ParticleEmitter|Sparkles"]]},
        {"id": "juice_tweens", "label": "juice: tweens (buttons pop, builds rise in, UI bounces)",
         "signals": [[r"TweenService"]]},
        {"id": "number_popups", "label": "juice: number popups (+$ floating text where cash is made)",
         "signals": [[r"BillboardGui", r"\+\s*\$|\"\+\"|[Pp]opup|[Ff]loat"]]},
        {"id": "multiplayer_fairness", "label": "multiplayer fairness (server authority, debounce, per-player state)",
         "signals": [[r"[Dd]ebounce|[Cc]ooldown|os\.clock", r"PlayerRemoving"]]},
        {"id": "no_grey_art", "label": "no grey placeholder art (themed materials and colors on every part)",
         "signals": [[r"Enum\.Material\.", r"Color3\.fromRGB|BrickColor"]]},
        {"id": "performance", "label": "performance (caps on spawned parts, cleanup, no per-frame waste)",
         "signals": [[r"Debris|:Destroy\(\)", r"MAX_|[Cc]ap\b|#.*>="]]},
    ],
    "generic": [
        {"id": "core_loop", "label": "a clear core loop that happens within 30 seconds", "signals": [[r"ForgeTelemetry"]]},
        {"id": "tutorial", "label": "first 60 seconds: the player knows what to do",
         "signals": [[r"[Tt]utorial|[Hh]int|[Gg]uide|[Aa]rrow"]]},
        {"id": "progression", "label": "progression (unlocks, levels, upgrades)", "signals": [[r"[Uu]pgrade|[Ll]evel|[Uu]nlock"]]},
        {"id": "ui", "label": "readable UI (HUD, feedback toasts)", "signals": [[r"ScreenGui"]]},
        {"id": "saving", "label": "saving progress", "signals": [[r"DataStoreService|GetDataStore"]]},
        {"id": "juice_sound", "label": "juice: sounds", "signals": [[r"Instance\.new\(\s*\"Sound\"|SoundId"]]},
        {"id": "juice_particles", "label": "juice: particles", "signals": [[r"ParticleEmitter"]]},
        {"id": "juice_tweens", "label": "juice: tweens", "signals": [[r"TweenService"]]},
        {"id": "multiplayer_fairness", "label": "multiplayer fairness", "signals": [[r"[Dd]ebounce|[Cc]ooldown"]]},
        {"id": "no_grey_art", "label": "no grey placeholder art", "signals": [[r"Enum\.Material\.", r"Color3\.fromRGB|BrickColor"]]},
        {"id": "performance", "label": "performance", "signals": [[r"Debris|:Destroy\(\)"]]},
    ],
}


def detect_genre(spec: dict, goal: str = "") -> str:
    text = " ".join(str(spec.get(k) or "") for k in ("title", "pitch", "core_loop")) + " " + goal
    low = text.lower()
    if "tycoon" in low or ("dropper" in low and "conveyor" in low):
        return "tycoon"
    return "generic"


def _read(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def _lines(path: Path) -> list[dict]:
    out = []
    try:
        for ln in path.read_text(encoding="utf-8").splitlines():
            try:
                rec = json.loads(ln)
            except ValueError:
                continue
            if isinstance(rec, dict):
                out.append(rec)
    except OSError:
        pass
    return out


def _clip(text: Any, n: int = 240) -> str:
    s = " ".join(str(text or "").split())
    return s if len(s) <= n else s[: n - 1] + "…"


def game_sources(game_dir: Path) -> dict[str, str]:
    """Game .luau files (relative path -> text), without Forge's runtime/test harness files."""
    out = {}
    for p in sorted(game_dir.rglob("*.luau")):
        rel = p.relative_to(game_dir).as_posix()
        if rel.startswith("tools/") or any(p.name.startswith(r) for r in RUNTIME_FILES):
            continue
        try:
            out[rel] = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
    return out


def scan_checklist(genre: str, sources: dict[str, str]) -> list[dict]:
    """Static signals per checklist item: which files mention it (every regex in a group must hit)."""
    out = []
    for item in CHECKLISTS.get(genre) or CHECKLISTS["generic"]:
        hits: set[str] = set()
        for group in item["signals"]:
            files = [path for path, text in sources.items() if all(re.search(rx, text) for rx in group)]
            hits.update(files)
        out.append({"id": item["id"], "label": item["label"], "present": bool(hits), "files": sorted(hits)[:4]})
    return out


def grey_scan(sources: dict[str, str]) -> dict:
    parts = sum(len(re.findall(r"Instance\.new\(\s*\"(?:Part|WedgePart|MeshPart|CornerWedgePart)\"", t))
                for t in sources.values())
    styled = sum(len(re.findall(r"\.(?:Color|BrickColor|Material)\s*=", t)) for t in sources.values())
    grey = sum(len(re.findall(r"Medium stone grey|163,\s*162,\s*165|fromRGB\(\s*1[2-6]\d,\s*1[2-6]\d,\s*1[2-6]\d\s*\)", t))
               for t in sources.values())
    return {"parts_created": parts, "color_or_material_sets": styled, "grey_literals": grey}


# ---------------------------------------------------------------- evidence


class Evidence:
    """Evidence lines grouped by section, each with a reference id the gap finder may cite."""

    def __init__(self) -> None:
        self.sections: list[tuple[str, list[tuple[str, str]]]] = []
        self.refs: dict[str, str] = {}

    def section(self, title: str) -> list[tuple[str, str]]:
        rows: list[tuple[str, str]] = []
        self.sections.append((title, rows))
        return rows

    def add(self, rows: list[tuple[str, str]], ref: str, text: str) -> None:
        rows.append((ref, text))
        self.refs[ref] = text

    def render(self, budget: int) -> str:
        out: list[str] = []
        used = 0
        for title, rows in self.sections:
            if not rows:
                continue
            block = [f"### {title}"] + [f"- [{ref}] {text}" for ref, text in rows]
            text = "\n".join(block)
            if used + len(text) > budget:
                keep = []
                for ln in block:
                    if used + len(ln) + 1 > budget:
                        break
                    keep.append(ln)
                    used += len(ln) + 1
                if len(keep) > 1:
                    out.append("\n".join(keep) + "\n- (more omitted)")
                break
            out.append(text)
            used += len(text) + 2
        return "\n\n".join(out)


def _critic(ev: Evidence, run: Path, state: dict) -> None:
    rows = ev.section("Critic (playtest + console + code review per build iteration)")
    its = [i for i in state.get("iterations") or [] if isinstance(i, dict)]
    for it in its[-3:]:
        n = it.get("n")
        crit = _read(run / "iterations" / str(n) / "critique.json", {}) or {}
        score = crit.get("score", it.get("score"))
        fun = crit.get("fun") or (crit.get("scores") or {}).get("fun") if isinstance(crit, dict) else None
        shot = run / "iterations" / str(n) / "screenshot.png"
        ev.add(rows, f"critic:{n}", f"iteration {n}: score {score}/10" + (f", fun {fun}" if fun is not None else "")
               + f": {_clip(crit.get('summary') or it.get('summary'), 360)}"
               + (f" (screenshot iterations/{n}/screenshot.png)" if shot.exists() else ""))
        for i, issue in enumerate((crit.get("issues") or [])[:6], 1):
            if isinstance(issue, dict):
                ev.add(rows, f"critic:{n}#{i}", f"{issue.get('path')}: {_clip(issue.get('problem'), 260)}")


def _tests(ev: Evidence, run: Path) -> None:
    rows = ev.section("AI tester runs (newest first; screenshots per step)")
    runs = sorted((p for p in (run / "tests").glob("*/report.json")), key=lambda p: p.parent.name, reverse=True)
    for rep_path in runs[:5]:
        rep = _read(rep_path, {}) or {}
        rid = rep_path.parent.name
        shots = sorted(p.name for p in rep_path.parent.glob("step-*.png"))
        ev.add(rows, f"test:{rid}", f"{rep.get('tester') or rep.get('kind') or 'tester'} goal "
               f"\"{_clip(rep.get('goal'), 120)}\": goal_met={rep.get('goal_met')}, "
               f"{len(rep.get('steps') or [])} steps, {len(shots)} screenshots. {_clip(rep.get('summary'), 300)}")
        for i, bug in enumerate((rep.get("bugs") or [])[:4], 1):
            if isinstance(bug, dict):
                ev.add(rows, f"test:{rid}#bug{i}", f"[{bug.get('severity')}] {_clip(bug.get('title'), 120)}: "
                       f"{_clip(bug.get('evidence'), 200)}")
        failed = 0
        for sj in sorted(rep_path.parent.glob("step-*.json")):
            step = _read(sj, {}) or {}
            bad = [a for a in step.get("assertions") or [] if isinstance(a, dict) and not a.get("ok")]
            if bad and failed < 4:
                failed += 1
                act = step.get("action")
                act = act.get("action") if isinstance(act, dict) else act
                ev.add(rows, f"test:{rid}/{sj.stem}", f"{_clip(act or sj.stem, 80)} failed: " + "; ".join(_clip(f"{a.get('text')} ({a.get('detail')})", 140) for a in bad[:3])
                       + (f" (screenshot {sj.stem}.png)" if (sj.with_suffix('.png')).exists() else ""))


def _checks(ev: Evidence, run: Path) -> None:
    rows = ev.section("Executable checks (Luau, run in the live game)")
    res = _read(run / "checks" / "results.json")
    if isinstance(res, dict):
        res = res.get("results")
    for r in (res or [])[:20]:
        if isinstance(r, dict):
            ev.add(rows, f"check:{r.get('id')}", f"{'PASS' if r.get('ok') else 'FAIL'} {_clip(r.get('title'), 90)}"
                   + ("" if r.get("ok") else f": {_clip(r.get('detail'), 160)} (verdict {r.get('verdict')})"))


def _cycles(ev: Evidence, run: Path) -> None:
    rows = ev.section("Fix cycles (auditor anomalies, fixes kept or rolled back)")
    paths = sorted((run / "improve").glob("[0-9]*.json"), key=lambda p: int(p.stem))
    for p in paths[-2:]:
        cyc = _read(p, {}) or {}
        n = p.stem
        anomalies = (cyc.get("audit") or {}).get("anomalies") or []
        fixes = cyc.get("code_fixes") or []
        ev.add(rows, f"cycle:{n}", f"cycle {n}: {len(anomalies)} anomalies, open {cyc.get('open')}, "
               f"fixes kept {sum(1 for f in fixes if f.get('status') == 'kept')}/{len(fixes)}")
        for i, a in enumerate(anomalies[:6], 1):
            if isinstance(a, dict):
                ev.add(rows, f"cycle:{n}#a{i}", f"[{a.get('severity')}] {a.get('system')}: {_clip(a.get('title'), 100)}: "
                       f"{_clip(a.get('observed'), 160)}")


def _features(ev: Evidence, run: Path, spec: dict) -> None:
    rows = ev.section("Features the agent added (verified = proved in play)")
    feats = list(spec.get("features") or []) + _lines(run / "features.jsonl")
    latest: dict[str, dict] = {}
    for f in feats:
        if isinstance(f, dict):
            latest[str(f.get("request", ""))[:200]] = f
    for i, (req, f) in enumerate(list(latest.items())[-8:], 1):
        ev.add(rows, f"feature:{i}", f"{'verified' if f.get('verified') else 'NOT verified'} "
               f"({f.get('status') or ''}) {_clip(req, 200)}")


def _reports(ev: Evidence, run: Path) -> None:
    rows = ev.section("Human tester reports")
    for i, r in enumerate(_lines(run / "improve" / "reports.jsonl")[-4:], 1):
        ev.add(rows, f"report:{i}", f"{r.get('reporter') or 'tester'}: {_clip(r.get('text'), 260)}")


def _calls(ev: Evidence, run: Path) -> None:
    rows = ev.section("Mubit calls (per role; failures are calls that errored or could not be parsed)")
    calls: list[dict] = []
    for p in [run / "calls.jsonl", run / "improve" / "calls.jsonl", *run.glob("tests/*/calls.jsonl")]:
        calls += _lines(p)
    by: dict[str, list[int]] = {}
    for c in calls:
        role = str(c.get("role") or "?")
        rec = by.setdefault(role, [0, 0])
        rec[0] += 1
        rec[1] += 1 if c.get("error") else 0
    for role, (n, bad) in sorted(by.items(), key=lambda kv: -kv[1][0]):
        ev.add(rows, f"calls:{role}", f"{role}: {n} calls, {bad} failed")


def _done(ev: Evidence, settings: Settings, slug: str) -> dict:
    from forge.done import readiness
    rows = ev.section("Readiness bar (forge done)")
    try:
        r = readiness(settings, slug)
    except Exception as e:  # noqa: BLE001
        ev.add(rows, "done:error", f"readiness failed: {e}")
        return {}
    for p in r["parts"]:
        ev.add(rows, f"done:{p['part']}", f"{'met' if p['ok'] else 'NOT met'}: {p['detail']}")
    return r


def _code(ev: Evidence, sources: dict[str, str], genre: str) -> list[dict]:
    rows = ev.section("Game source files (lines)")
    for path, text in sources.items():
        ev.add(rows, f"code:{path}", f"{text.count(chr(10)) + 1} lines")
    grey = grey_scan(sources)
    rows2 = ev.section(f"Genre checklist ({genre}) with a static code scan")
    scan = scan_checklist(genre, sources)
    for item in scan:
        ev.add(rows2, f"genre:{item['id']}", f"{item['label']}: "
               + (f"mentioned in {', '.join(item['files'])}" if item["present"] else "not found in code"))
    ev.add(rows2, "genre:grey_scan", f"parts created in code {grey['parts_created']}, color/material assignments "
           f"{grey['color_or_material_sets']}, grey color literals {grey['grey_literals']}")
    return scan


def collect_evidence(settings: Settings, slug: str, goal: str = "") -> dict:
    """Everything recorded about the game, as {spec, genre, scan, done, evidence: Evidence}."""
    store = RunStore(settings, slug)
    run = store.dir
    spec = _read(store.spec_path, {}) or {}
    state = _read(store.state_path, {}) or {}
    genre = detect_genre(spec, goal)
    ev = Evidence()
    done = _done(ev, settings, slug)
    _critic(ev, run, state)
    _tests(ev, run)
    _checks(ev, run)
    _cycles(ev, run)
    _features(ev, run, spec)
    _reports(ev, run)
    _calls(ev, run)
    scan = _code(ev, game_sources(store.game_dir), genre)
    return {"slug": slug, "spec": spec, "genre": genre, "scan": scan, "done": done, "evidence": ev}


# ---------------------------------------------------------------- the Mubit call


def orch_dir(settings: Settings, slug: str) -> Path:
    return RunStore(settings, slug).dir / "orchestrator"


def rejected(settings: Settings, slug: str) -> list[dict]:
    return list(_read(orch_dir(settings, slug) / "rejected.json", []) or [])


def gap_message(collected: dict, goal: str, *, previous: list[dict] | None = None,
                rejected_gaps: list[dict] | None = None, done_jobs: list[str] | None = None,
                correction: str | None = None) -> str:
    spec = collected["spec"]
    head = [f"## Goal\n{goal or 'Make this game genuinely good for real players.'}",
            "## Game spec",
            f"title: {spec.get('title')}\npitch: {_clip(spec.get('pitch'), 300)}\n"
            f"core loop: {_clip(spec.get('core_loop'), 700)}",
            "modules:\n" + "\n".join(f"- {m.get('path')}: {_clip(m.get('purpose'), 140)}"
                                     for m in (spec.get("modules") or [])[:20] if isinstance(m, dict)),
            "acceptance:\n" + "\n".join(f"- {_clip(a, 200)}" for a in (spec.get("acceptance") or [])[:16])]
    tail: list[str] = []
    if done_jobs:
        tail.append("## Jobs already done (do not repeat unless newer evidence shows it is still broken)\n"
                    + "\n".join(f"- {_clip(j, 200)}" for j in done_jobs[-20:]))
    if rejected_gaps:
        tail.append("## Gaps the developer rejected (never propose these again)\n"
                    + "\n".join(f"- {g.get('title')}: {_clip(g.get('reason'), 200)}" for g in rejected_gaps[-20:]))
    if previous:
        tail.append("## Your previous gap list\n" + json.dumps(
            [{k: g.get(k) for k in ("id", "title", "impact", "kind", "evidence")} | {"job": g.get("job")}
             for g in previous[:MAX_GAPS]], ensure_ascii=False))
    if correction:
        tail.append(f"{CORRECTION_MARK}\n{correction.strip()}\n\nApply this correction and reply with the full "
                    "corrected gap list.")
    fixed = "\n\n".join(head + tail)
    budget = max(4000, MAX_USER_CHARS - len(fixed) - 200)
    return "\n\n".join(head + ["## Evidence\n" + collected["evidence"].render(budget)] + tail)


JOB_ALIASES = {"bug": "fix", "fix_bug": "fix", "art": "visual", "asset": "visual", "juice": "visual",
               "polish": "visual", "add": "feature", "system": "feature"}
GAP_ALIASES = {"bug": "broken", "fix": "broken", "error": "broken", "absent": "missing", "juice": "polish",
               "visual": "polish"}


def _norm_kind(v: Any, allowed: tuple[str, ...], default: str) -> str:
    s = str(v or "").strip().lower()
    s = (JOB_ALIASES if "feature" in allowed else GAP_ALIASES).get(s, s)
    return s if s in allowed else default


def _num(v: Any, lo: float, hi: float, default: float) -> float:
    try:
        x = float(v)
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, x))


def parse_gaps(obj: dict, refs: dict[str, str] | set[str], *, rejected_titles: list[str] | None = None,
               files: list[str] | None = None) -> dict:
    """Validate and rank the gap finder's reply.

    - drops gaps without a title or a job request, and gaps the developer rejected;
    - keeps only evidence refs that exist (unknown ones go to `unverified`); a gap with no real
      evidence ranks lower (rank = impact * confidence * 0.5);
    - a fix job's path must be a real game file, else it becomes a path-less fix;
    - dedupes by id (slug of the title); sorts by rank, highest first; at most MAX_GAPS.
    """
    known = set(refs)
    reject = {slugify(t, max_words=8, max_len=60) for t in rejected_titles or []}
    out: list[dict] = []
    seen: set[str] = set()
    for raw in obj.get("gaps") or []:
        if not isinstance(raw, dict):
            continue
        title = _clip(raw.get("title"), 120)
        job = raw.get("job") if isinstance(raw.get("job"), dict) else {}
        request = str(job.get("request") or "").strip()
        if not title or not request:
            continue
        gid = slugify(title, max_words=8, max_len=60)
        if gid in seen or gid in reject:
            continue
        seen.add(gid)
        cited = [str(r).strip().strip("[]") for r in raw.get("evidence") or [] if str(r).strip()]
        good = [r for r in cited if r in known]
        if good and all(r.startswith("done:") for r in good):
            continue  # "run the checks / critic" is the orchestrator's own verify step, not a game change
        impact = _num(raw.get("impact"), 1, 10, 5)
        conf = _num(raw.get("confidence"), 0, 1, 0.7)
        jkind = _norm_kind(job.get("kind"), JOB_KINDS, "feature")
        path = str(job.get("path") or "").strip() or None
        if path and files is not None and path not in files:
            path = None
        rank = round(impact * conf * (1.0 if good else 0.5), 2)
        out.append({"id": gid, "title": title, "area": _clip(raw.get("area"), 40) or "other",
                    "kind": _norm_kind(raw.get("kind"), GAP_KINDS, "missing"), "impact": impact,
                    "confidence": conf, "rank": rank, "evidence": good, "unverified": [r for r in cited if r not in known],
                    "why": _clip(raw.get("why"), 300),
                    "job": {"kind": jkind, "request": request[:1200], **({"path": path} if path else {})}})
    out.sort(key=lambda g: (-g["rank"], -g["impact"]))
    return {"summary": _clip(obj.get("summary"), 600), "score": _num(obj.get("score"), 0, 10, 0) if obj.get("score") is not None else None,
            "gaps": out[:MAX_GAPS]}


def _next_n(d: Path) -> int:
    ns = [int(p.stem) for p in d.glob("[0-9]*.json") if p.stem.isdigit()]
    return max(ns, default=0) + 1


def latest(settings: Settings, slug: str) -> dict | None:
    d = orch_dir(settings, slug) / "gaps"
    ns = sorted((int(p.stem) for p in d.glob("[0-9]*.json") if p.stem.isdigit()))
    return _read(d / f"{ns[-1]}.json") if ns else None


def find_gaps(settings: Settings, slug: str, *, llm: Any, goal: str = "", session_id: str | None = None,
              done_jobs: list[str] | None = None, correction: str | None = None,
              previous: list[dict] | None = None, round: int | None = None) -> dict:
    """One gap_finder call (plus JSON repairs) -> ranked gaps saved to orchestrator/gaps/<n>.json."""
    collected = collect_evidence(settings, slug, goal)
    rej = rejected(settings, slug)
    user = gap_message(collected, goal, previous=previous, rejected_gaps=rej, done_jobs=done_jobs,
                       correction=correction)
    obj, res = llm.complete_json(ROLE, user, session_id=session_id or slug, required=["gaps"], max_tokens=6000)
    files = list(game_sources(RunStore(settings, slug).game_dir))
    parsed = parse_gaps(obj, collected["evidence"].refs, rejected_titles=[g.get("title", "") for g in rej],
                        files=files)
    d = orch_dir(settings, slug) / "gaps"
    d.mkdir(parents=True, exist_ok=True)
    n = _next_n(d)
    rec = {"n": n, "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "round": round,
           "request_id": res.request_id, "genre": collected["genre"], "correction": correction,
           "scan": collected["scan"], "done": {"ready": (collected["done"] or {}).get("ready")},
           "evidence_refs": len(collected["evidence"].refs), **parsed}
    (d / f"{n}.json").write_text(json.dumps(rec, indent=1, ensure_ascii=False), encoding="utf-8")
    return rec


def correct_gaps(settings: Settings, slug: str, note: str, *, llm: Any, goal: str = "",
                 reject: list[str] | None = None, session_id: str | None = None) -> dict:
    """A developer's correction on the latest gap list -> the same gap_finder Mubit task, with the previous
    list and the note in the user message. `reject` gap ids are also remembered and never proposed again."""
    prev = latest(settings, slug) or {"gaps": []}
    d = orch_dir(settings, slug)
    if reject:
        rej = rejected(settings, slug)
        for g in prev.get("gaps") or []:
            if g["id"] in reject:
                rej.append({"id": g["id"], "title": g["title"], "reason": note,
                            "ts": datetime.now(timezone.utc).isoformat(timespec="seconds")})
        d.mkdir(parents=True, exist_ok=True)
        (d / "rejected.json").write_text(json.dumps(rej, indent=1, ensure_ascii=False), encoding="utf-8")
    rec = find_gaps(settings, slug, llm=llm, goal=goal, session_id=session_id, correction=note,
                    previous=prev.get("gaps") or [])
    with (d / "corrections.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps({"ts": rec["ts"], "role": ROLE, "kind": "correction", "note": note,
                            "rejected": reject or [], "request_id": rec.get("request_id"),
                            "before": [g["id"] for g in prev.get("gaps") or []],
                            "after": [g["id"] for g in rec["gaps"]], "gaps_file": rec["n"]}) + "\n")
    return rec


def render(rec: dict, limit: int = MAX_GAPS) -> str:
    lines = [f"gap list #{rec.get('n')} ({rec.get('genre')}), estimated score {rec.get('score')}: {rec.get('summary')}"]
    for i, g in enumerate(rec.get("gaps", [])[:limit], 1):
        job = g["job"]
        lines.append(f"{i:>2}. [{g['kind']:<7} impact {g['impact']:g} rank {g['rank']:g}] {g['title']}  ({g['id']})")
        lines.append(f"      job {job['kind']}{(' ' + job['path']) if job.get('path') else ''}: {_clip(job['request'], 160)}")
        if g["evidence"]:
            lines.append(f"      evidence: {', '.join(g['evidence'][:6])}")
    return "\n".join(lines)
