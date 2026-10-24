"""The self-improving loop on top of mubit-tester (docs/MUBIT_LOOP.md).

One cycle:
    plant known faults (live config) -> N playtest rounds -> auditor finds anomalies
    -> score against the planted faults -> missed faults become corrected auditor calls
    -> detected faults are fixed (config restored) -> one more round -> verifier judges each fix
    -> runs/<slug>/improve/<cycle>.json + scores.json, playbook.md updated for the next cycle

Every LLM call goes through Mubit under the fixed `auditor` / `verifier` prompts, so each one is an
example in that role's Mubit task. Corrections are new calls in the same task. Faults are planted
through ForgeTest's `config` command, which only lasts while play runs, so a cycle keeps one play
session open from planting to the last round.
"""

from __future__ import annotations

import asyncio
import dataclasses
import json
from collections import Counter
from pathlib import Path
from typing import Any, Awaitable, Callable

from forge.config import Settings
from forge.llm import LLM, LLMError
from forge.memory import RunStore, now_iso
from forge.patch import PATCH_ABOVE_LINES

AUDIT_KEYS = ["summary", "anomalies"]
VERIFY_KEYS = ["verdict", "evidence"]
VERDICTS = ("fixed", "not_fixed", "regression", "inconclusive")
FAULTS_DIR = Path(__file__).parent / "faults"
MAX_ROUND_ERRORS = 3

Playtest = Callable[..., Awaitable[dict]]


# ---------------------------------------------------------------- digests


def round_digest(report: dict, n: int) -> dict:
    """The compact, code-free view of one playtest report that the auditor and verifier read."""
    probe = report.get("probe") or {}
    errors = [e for e in (probe.get("errors") or []) if e]
    messages = [str(e.get("message", e) if isinstance(e, dict) else e)[:200] for e in errors]
    kinds = Counter(str(e.get("kind")) for e in (report.get("events") or []) if isinstance(e, dict))
    return {
        "round": n,
        "goal": report.get("goal", ""),
        "goal_met": report.get("goal_met"),
        "players": len(report.get("players") or []),
        "counters": report.get("counters") or probe.get("counters") or {},
        "errors": {"count": len(errors), "first": messages[:MAX_ROUND_ERRORS]},
        "bugs": [{"title": b.get("title", ""), "severity": b.get("severity", "")}
                 for b in (report.get("bugs") or []) if isinstance(b, dict)],
        "events": dict(kinds),
    }


def _digests_block(title: str, digests: list[dict]) -> str:
    lines = [f"## {title}"] + [json.dumps(d, ensure_ascii=False) for d in digests]
    return "\n".join(lines)


# ---------------------------------------------------------------- auditor / verifier calls


def _game_block(spec: dict) -> str:
    out = f"## Game\n{spec.get('pitch', '')}\nCore loop: {spec.get('core_loop', '')}"
    acceptance = [str(a) for a in (spec.get("acceptance") or []) if a][-12:]
    if acceptance:
        # end-to-end check: anything on this list the rounds show as missing or broken is an anomaly
        out += "\nAcceptance checks the game must meet:\n" + "\n".join(f"- {a}" for a in acceptance)
    return out


def audit_message(spec: dict, playbook: str, digests: list[dict], verified: list[str] | None = None) -> str:
    parts = [_game_block(spec), "## Playbook\n" + (playbook.strip() or "(empty)"),
             _digests_block("Rounds", digests)]
    if verified:
        parts.append("## Verified outcome\n" + "\n".join(f"- {v}" for v in verified))
    parts.append("Return only the audit JSON object.")
    return "\n\n".join(parts)


def _norm_anomaly(a: Any) -> dict | None:
    if not isinstance(a, dict) or not a.get("title"):
        return None
    sev = str(a.get("severity") or "medium").lower()
    return {
        "kind": str(a.get("kind") or ""), "system": str(a.get("system") or "").lower(),
        "title": str(a["title"]), "expected": str(a.get("expected") or ""),
        "observed": str(a.get("observed") or ""),
        "severity": sev if sev in ("high", "medium", "low") else "medium",
    }


def audit(llm: LLM, spec: dict, playbook: str, digests: list[dict], *, session_id: str,
          verified: list[str] | None = None) -> dict:
    obj, res = llm.complete_json("auditor", audit_message(spec, playbook, digests, verified),
                                 session_id=session_id, required=AUDIT_KEYS, max_tokens=2048)
    anomalies = [a for a in (_norm_anomaly(x) for x in obj.get("anomalies") or []) if a]
    return {"summary": str(obj.get("summary") or ""), "anomalies": anomalies,
            "request_id": res.request_id}


def verify_message(anomaly: dict, change: str, before: list[dict], after: list[dict]) -> str:
    table, hard = telemetry_changes(before, after)
    parts = ["## Anomaly\n" + json.dumps(anomaly, ensure_ascii=False), "## Change\n" + change,
             _digests_block("Before", before), _digests_block("After", after),
             "## Telemetry changes (computed, peak per counter)\n" + "\n".join(table)]
    if hard:
        parts.append("## Flagged changes (computed; judge whether each is a regression or the fix working)\n"
                     + "\n".join(f"- {h}" for h in hard))
    parts.append("Return only the verdict JSON object.")
    return "\n\n".join(parts)


def verify(llm: LLM, anomaly: dict, change: str, before: list[dict], after: list[dict], *,
           session_id: str) -> dict:
    obj, res = llm.complete_json("verifier", verify_message(anomaly, change, before, after),
                                 session_id=session_id, required=VERIFY_KEYS, max_tokens=1024)
    verdict = str(obj.get("verdict") or "").lower()
    return {"verdict": verdict if verdict in VERDICTS else "inconclusive",
            "evidence": str(obj.get("evidence") or ""),
            "regressions": [str(r) for r in (obj.get("regressions") or []) if r],
            "request_id": res.request_id}


# ---------------------------------------------------------------- faults


def load_faults(slug: str, path: Path | None = None) -> list[dict]:
    """Faults for a game: forge/faults/<slug>.json unless a path is given."""
    data = json.loads(Path(path or FAULTS_DIR / f"{slug}.json").read_text(encoding="utf-8"))
    faults = data.get("faults") if isinstance(data, dict) else data
    for f in faults:
        missing = [k for k in ("id", "module", "key", "value", "systems", "match", "symptom")
                   if k not in f]
        if missing:
            raise ValueError(f"fault {f.get('id', '?')}: missing {', '.join(missing)}")
    return faults


def default_faults(faults: list[dict], only: list[str] | None = None) -> list[dict]:
    """The faults to plant: the named ones, else every fault not marked "default": false."""
    if only:
        unknown = set(only) - {f["id"] for f in faults}
        if unknown:
            raise ValueError(f"unknown fault ids: {', '.join(sorted(unknown))}")
        return [f for f in faults if f["id"] in only]
    return [f for f in faults if f.get("default", True)]


async def plant(harness, faults: list[dict]) -> dict[str, Any]:
    """Set each fault's config value live; return {fault id: the value it replaced}."""
    keys = [(f["module"], f["key"]) for f in faults]
    if len(keys) != len(set(keys)):
        raise ValueError("two faults set the same config key; plant them in separate cycles")
    old: dict[str, Any] = {}
    for f in faults:
        res = await harness.call("config", module=f["module"], key=f["key"], value=f["value"])
        old[f["id"]] = (res or {}).get("old")
    return old


async def clear(harness, faults: list[dict], old: dict[str, Any]) -> None:
    for f in faults:
        if f["id"] in old and old[f["id"]] is not None:
            await harness.call("config", module=f["module"], key=f["key"], value=old[f["id"]])


def matches(anomaly: dict, fault: dict) -> bool:
    """A fault is detected by an anomaly in one of its systems that names one of its keywords."""
    if anomaly["system"] not in [s.lower() for s in fault["systems"]]:
        return False
    text = " ".join((anomaly["title"], anomaly["expected"], anomaly["observed"])).lower()
    return any(k.lower() in text for k in fault["match"])


def score(anomalies: list[dict], faults: list[dict]) -> dict:
    detected = {f["id"]: next((i for i, a in enumerate(anomalies) if matches(a, f)), None)
                for f in faults}
    used = {i for i in detected.values() if i is not None}
    return {
        "planted": len(faults),
        "detected": sorted(fid for fid, i in detected.items() if i is not None),
        "missed": sorted(fid for fid, i in detected.items() if i is None),
        "anomaly_for": {fid: i for fid, i in detected.items() if i is not None},
        "unmatched_anomalies": [i for i in range(len(anomalies)) if i not in used],
    }


# ---------------------------------------------------------------- run state


class ImproveStore:
    def __init__(self, settings: Settings, slug: str):
        self.run = RunStore(settings, slug)
        self.dir = self.run.dir / "improve"
        self.scores_path = self.dir / "scores.json"
        self.playbook_path = self.dir / "playbook.md"

    def scores(self) -> list[dict]:
        if not self.scores_path.exists():
            return []
        return json.loads(self.scores_path.read_text(encoding="utf-8"))

    def playbook(self) -> str:
        return self.playbook_path.read_text(encoding="utf-8") if self.playbook_path.exists() else ""

    def save_cycle(self, cycle: dict) -> Path:
        self.dir.mkdir(parents=True, exist_ok=True)
        path = self.dir / f"{cycle['cycle']}.json"
        path.write_text(json.dumps(cycle, indent=2, ensure_ascii=False), encoding="utf-8")
        row = {k: cycle[k] for k in ("cycle", "ts", "planted", "detected", "missed",
                                     "unmatched", "fixed_verified")}
        row.update({"open": cycle.get("open", 0), "code_kept": cycle.get("code_kept", 0),
                    "code_tried": len(cycle.get("code_fixes") or [])})
        self.scores_path.write_text(json.dumps(self.scores() + [row], indent=2), encoding="utf-8")
        return path

    @property
    def unproven_path(self) -> Path:
        return self.dir / "unproven.json"

    def _unproven(self) -> list[dict]:
        if not self.unproven_path.exists():
            return []
        return json.loads(self.unproven_path.read_text(encoding="utf-8"))

    def mark_unproven(self, anomaly: dict) -> None:
        rows = self._unproven()
        rows.append({"system": anomaly.get("system", ""), "title": anomaly.get("title", "")})
        self.dir.mkdir(parents=True, exist_ok=True)
        self.unproven_path.write_text(json.dumps(rows[-50:], indent=1), encoding="utf-8")

    def was_unproven(self, anomaly: dict) -> bool:
        import difflib

        t = anomaly.get("title", "").lower()
        return any(difflib.SequenceMatcher(None, t, r["title"].lower()).ratio() >= UNPROVEN_SIMILAR
                   for r in self._unproven())

    def learn(self, lessons: list[str]) -> None:
        """Fast learning: lessons from missed faults go into the next audit's playbook."""
        known = self.playbook()
        new = [ln for ln in lessons if ln and ln not in known]
        if new:
            self.dir.mkdir(parents=True, exist_ok=True)
            self.playbook_path.write_text(known + "".join(f"- {ln}\n" for ln in new),
                                          encoding="utf-8")


# ---------------------------------------------------------------- one cycle


ROUND_TIMEOUT = 360.0  # seconds; a Studio call can stall and nothing else would end the round


async def _rounds(settings, playtest: Playtest, n: int, start: int, *, goal: str, players, steps: int,
                  llm, harness) -> list[dict]:
    out = []
    for i in range(n):
        try:
            rep = await asyncio.wait_for(playtest(settings, goal, players, steps, llm=llm, harness=harness),
                                         ROUND_TIMEOUT)
        except asyncio.TimeoutError:
            rep = {"goal": goal, "probe": {"errors": [{"message": f"playtest round timed out after {ROUND_TIMEOUT:.0f}s"}]}}
        out.append(round_digest(rep, start + i))
    return out


# Seconds to let a freshly started round get going (teleport, intro countdown) before testers act.
START_ROUND_WAIT = 8.0
END_ROUND_WAIT = 2.0


def round_starting(playtest: Playtest, *, seconds: int | None = None, wait: float = START_ROUND_WAIT) -> Playtest:
    """Wrap a playtest so every round begins inside the game proper: end any running round, then start
    one through the harness's `round` command (ForgeTest contract, not game-specific). Testers otherwise
    spend their steps in a lobby and never reach the core loop."""
    async def wrapped(settings, goal, players, steps, *, llm, harness):
        await harness.ensure_ready()
        try:
            await harness.call("round", state="Results")
            await asyncio.sleep(END_ROUND_WAIT)
        except Exception:  # noqa: BLE001 - nothing to end is fine
            pass
        args = {"state": "Active"}
        if seconds:
            args["seconds"] = seconds
        await harness.call("round", **args)
        await asyncio.sleep(wait)
        return await playtest(settings, goal, players, steps, llm=llm, harness=harness)
    return wrapped


# ---------------------------------------------------------------- guards on fixes (general, not per game)

# A fix for one anomaly should be local. Removing more than this many of a file's lines (and at least
# DESTRUCTIVE_MIN_LINES) is treated as a rewrite that throws away working code, and is rejected unseen.
DESTRUCTIVE_SHARE = 0.25
DESTRUCTIVE_MIN_LINES = 40


def removed_lines(old: str, new: str) -> int:
    import difflib

    return sum(1 for ln in difflib.ndiff(old.splitlines(), new.splitlines()) if ln.startswith("- "))


def destructive(old: str, new: str) -> str | None:
    """Why this fix is too destructive to try, or None."""
    total = len(old.splitlines())
    gone = removed_lines(old, new)
    if gone >= DESTRUCTIVE_MIN_LINES and gone > total * DESTRUCTIVE_SHARE:
        return (f"Your fix removed {gone} of the file's {total} lines. A fix for one anomaly must be local: "
                "keep every unrelated function, part and comment exactly as it was and change only the lines "
                "the root cause needs.")
    return None


def _peaks(digests: list[dict]) -> dict:
    out: dict = {}
    for d in digests:
        for k, v in (d.get("counters") or {}).items():
            if isinstance(v, (int, float)):
                out[k] = max(out.get(k, v), v)
    return out


def hard_regressions(before: list[dict], after: list[dict]) -> list[str]:
    """Regressions that overrule a 'fixed' verdict: only more server errors. Counter drops go to the
    verifier as flags, because many fixes are meant to make counters fall (run on Flame and Blame: a
    verified fire-balance fix was wrongly overruled when fire_cap_hit and collapses went to zero)."""
    _, flags = telemetry_changes(before, after)
    return [f for f in flags if f.startswith("server errors")]


def telemetry_changes(before: list[dict], after: list[dict]) -> tuple[list[str], list[str]]:
    """(table lines for the verifier, flags). Flags: a counter that was present and non-zero before and
    is missing or zero after, or more server errors than before. Lost counters are only flags for the
    verifier to judge (a fire fix SHOULD make fire_cap_hit disappear); see hard_regressions."""
    b, a = _peaks(before), _peaks(after)
    lines, hard = [], []
    for k in sorted(set(b) | set(a)):
        bv, av = b.get(k), a.get(k)
        lines.append(f"- {k}: {bv if bv is not None else 'absent'} -> {av if av is not None else 'absent'}")
        if bv and not av:
            hard.append(f"counter {k} went from {bv} to {av if av is not None else 'absent'}")
    be = max((d.get("errors") or {}).get("count", 0) for d in before) if before else 0
    ae = max((d.get("errors") or {}).get("count", 0) for d in after) if after else 0
    lines.append(f"- server errors: {be} -> {ae}")
    if ae > be:
        hard.append(f"server errors rose from {be} to {ae}")
    return lines, hard


# ---------------------------------------------------------------- code fixes for real anomalies

FIX_SEVERITIES = ("high", "medium")
UNPROVEN_SIMILAR = 0.6
# Only skip when the investigator says the problem is not in the game's code. A plausible but unproven
# cause is still worth one attempt: the guards and the verifier reject a fix that does not help.
UNPROVEN_MARKERS = ("testing artefact", "testing artifact", "not a game bug", "test expectation",
                    "no code fix is needed", "no code change is needed")


def unproven(conclusion: dict) -> bool:
    """No conclusion, no file to change, or the investigator says it is the test, not the game."""
    if not conclusion or not conclusion.get("file"):
        return True
    text = str(conclusion.get("root_cause", "")).lower()
    for negated in ("not a testing artefact", "not a testing artifact", "not just a testing artefact",
                    "rather than a testing artefact", "is a game bug"):
        text = text.replace(negated, "")  # "a game bug, not a testing artefact" must not count as a skip
    return any(m in text for m in UNPROVEN_MARKERS)
NOT_IN_STUDIO = ("tests/", "tools/")
Resync = Callable[[Path], Awaitable[None]]


def studio_resync(harness, port: int | None = None) -> Resync:
    """Stop play, push the game folder into Studio (no prune), start play again."""
    async def resync(root: Path) -> None:
        studio = harness.studio
        st = await studio.state()
        if st.get("playing") is True:
            await studio.stop()
        await studio.sync(root, port, prune=False)
        await harness.ensure_ready()
    return resync


def _anomaly_text(a: dict) -> str:
    return " ".join((a["title"], a["system"], a.get("expected", ""), a.get("observed", "")))


def candidate_file(settings: Settings, game_dir: Path, anomaly: dict) -> str | None:
    """The game file most likely to hold the anomaly (paths and names first, then keywords)."""
    from mubit_tester.ai import find_candidate_files

    ranked = find_candidate_files(dataclasses.replace(settings, base_game_dir=game_dir),
                                  _anomaly_text(anomaly), limit=10)
    # only files that are synced into Studio can fix what testers saw (not unit specs or tools)
    live = [rel for rel, _ in ranked if not rel.startswith(NOT_IN_STUDIO)]
    return live[0] if live else None


async def fix_code(settings: Settings, slug: str, anomalies: list[dict], before: list[dict], *,
                   llm: LLM, harness, playtest: Playtest, resync: Resync, goal: str, players=None,
                   steps: int = 15, max_fixes: int = 3, session_id: str, edit_human: bool = False,
                   retries: int = 1, investigate_first: bool = True,
                   log: Callable[[str], None] = print) -> list[dict]:
    """Fix real anomalies in code, one at a time: fixer -> compile -> resync -> replay -> verifier.

    The game folder is versioned (forge/versions.py): the state before the first fix is a version,
    and every kept fix is a new one, so any of them can be restored later (`forge rollback`).
    A rejected fix gets `retries` more attempts; each retry tells the fixer why the last one was
    rejected (a correction in the fixer's Mubit task). If none is verified `fixed`, the file is
    restored and Studio resynced. Human-owned files (a seeded game's base_files) only get a saved
    patch unless `edit_human` is set; the Forge runtime is never edited."""
    from forge import roles
    from forge import sync as fsync
    from forge.loop import RUNTIME_FILES
    from forge.memory import read_lessons
    from forge.versions import GameVersions

    store = ImproveStore(settings, slug)
    root = store.run.game_dir
    spec = store.run.load_spec() if store.run.spec_path.exists() else {}
    protected = set(RUNTIME_FILES)
    if not edit_human:
        protected |= {p for p in spec.get("base_files") or [] if isinstance(p, str)}
    versions = GameVersions(root)
    start = versions.snapshot(f"before fixes ({session_id})")
    log(f"[versions] {start}: the game before this cycle's fixes")
    context = (f"Game: {spec.get('pitch', slug)}\nRound digests before the fix:\n"
               + "\n".join(json.dumps(d) for d in before[-2:]))[:4000]
    results: list[dict] = []
    todo = sorted((x for x in anomalies if x["severity"] in FIX_SEVERITIES),
                  key=lambda x: store.was_unproven(x))  # stable: unproven-before anomalies go last
    for a in todo[:max(0, max_fixes)]:
        found = None
        studio = getattr(harness, "studio", None)
        if investigate_first and studio is not None:
            await harness.ensure_ready()
            found = await investigate(settings, slug, a, llm=llm, studio=studio, session_id=session_id, log=log)
        concl = (found or {}).get("conclusion") or {}
        if found is not None and unproven(concl):
            store.mark_unproven(a)
            results.append({"anomaly": a["title"], "status": "unproven", "investigation": found})
            log(f"[fix] {a['title']}: investigator could not prove a code cause, skipped")
            continue
        rel = concl.get("file") or candidate_file(settings, root, a)
        if rel is None:
            results.append({"anomaly": a["title"], "status": "no_file", "investigation": found})
            log(f"[fix] {a['title']}: no matching file")
            continue
        old = (root / rel).read_text(encoding="utf-8")
        problem = (f"Playtest anomaly ({a['kind']}, {a['severity']}, system {a['system']}): {a['title']}\n"
                   f"Expected: {a.get('expected', '')}\nObserved: {a.get('observed', '')}")
        if concl:
            problem += (f"\n\n## Root cause (from experiments in the running game)\n{concl.get('root_cause', '')}\n"
                        f"Evidence: {concl.get('evidence', '')}\nFix hint: {concl.get('fix_hint', '')}")
        rec: dict = {"anomaly": a["title"], "path": rel, "attempts": [], "investigation": found}
        if rel in protected:
            new = await asyncio.to_thread(roles.fix_file, llm, rel, old, problem, context,
                                          read_lessons(settings), session_id=session_id)
            patch = store.dir / "patches" / (rel.replace("/", "__") + f".{len(results)}.luau")
            patch.parent.mkdir(parents=True, exist_ok=True)
            patch.write_text(new, encoding="utf-8")
            results.append({**rec, "status": "suggested", "patch": str(patch)})
            log(f"[fix] {a['title']}: {rel} is human-owned, patch saved to {patch.name}")
            continue

        status, why = "rolled_back", ""
        try:
            for attempt in range(1 + max(0, retries)):
                ask = problem if not why else (
                    f"{problem}\n\n## Your previous fix was rejected\n{why}\n"
                    "Try a different approach; the file below is the original.")
                # big files get exact edits (patcher); small ones a whole-file rewrite (fixer)
                big = len(old.splitlines()) > PATCH_ABOVE_LINES
                rewrite = roles.patch_file if big else roles.fix_file
                try:
                    new = await asyncio.to_thread(rewrite, llm, rel, old, ask, context,
                                                  read_lessons(settings), session_id=session_id)
                except LLMError as e:
                    if big and "no edits" in str(e):
                        rec["attempts"].append({"status": "no_fix_needed", "error": str(e)[:300]})
                        status = "no_fix_needed"
                        store.mark_unproven(a)
                        log(f"[fix] {a['title']}: patcher sees no code change to make, skipped")
                        break
                    rec["attempts"].append({"status": "fixer_error", "error": str(e)[:300]})
                    why = (f"Your patch could not be applied: {e}" if big else
                           "Your reply could not be used: return the full file in one ```luau block.")
                    log(f"[fix] {a['title']}: attempt {attempt + 1} fixer reply unusable ({str(e)[:80]})")
                    continue
                too_big = destructive(old, new)
                if too_big:
                    rec["attempts"].append({"status": "too_destructive", "error": too_big,
                                            "removed_lines": removed_lines(old, new)})
                    why = too_big
                    log(f"[fix] {a['title']}: attempt {attempt + 1} rejected unseen: {too_big[:90]}")
                    continue
                (root / rel).write_text(new, encoding="utf-8")
                errors = [e for p, e in fsync.check(root) if p == rel]
                if errors:
                    rec["attempts"].append({"status": "compile_failed", "error": errors[0][:300]})
                    why = f"It did not compile: {errors[0][:500]}"
                    log(f"[fix] {a['title']}: attempt {attempt + 1} failed to compile")
                    continue
                await resync(root)
                after = await _rounds(settings, playtest, 1, len(before) + 1, goal=goal, players=players,
                                      steps=steps, llm=llm, harness=harness)
                v = await asyncio.to_thread(verify, llm, a, f"Rewrote {rel} to fix it.", before, after,
                                            session_id=session_id)
                hard = hard_regressions(before, after)
                if v["verdict"] == "fixed" and hard:
                    v = {**v, "verdict": "regression", "regressions": v["regressions"] + hard,
                         "evidence": v["evidence"] + " Overruled by computed regressions: " + "; ".join(hard)}
                rec["attempts"].append({"status": v["verdict"], "verdict": v})
                if v["verdict"] == "fixed":
                    status = "kept"
                    rec["version"] = versions.snapshot(
                        f"fix: {a['title']} in {rel} (verifier: fixed, {v['request_id']})")
                    log(f"[fix] {a['title']}: {rel} fixed and verified, kept as {rec['version']}")
                    break
                why = f"The verifier said {v['verdict']}: {v['evidence']}" + (
                    f" Regressions: {'; '.join(v['regressions'])}" if v["regressions"] else "")
                log(f"[fix] {a['title']}: attempt {attempt + 1} {v['verdict']} {v['request_id']}")
        except BaseException:
            # Studio dropping, a playtest failing, Ctrl-C: never leave a half-tested fix behind
            (root / rel).write_text(old, encoding="utf-8")
            log(f"[fix] {a['title']}: stopped mid-fix, {rel} restored")
            raise
        if status == "no_fix_needed":
            results.append({**rec, "status": status})
            continue
        if status != "kept":
            (root / rel).write_text(old, encoding="utf-8")
            if any(x["status"] not in ("compile_failed", "fixer_error", "too_destructive")
                   for x in rec["attempts"]):
                await resync(root)
            if all(x["status"] == "compile_failed" for x in rec["attempts"]):
                status = "compile_failed"
            log(f"[fix] {a['title']}: no attempt verified, {rel} restored")
            if found and studio is not None:
                # correction for the investigator's Mubit task: its conclusion led to rejected fixes
                redo = await investigate(settings, slug, a, llm=llm, studio=studio, session_id=session_id,
                                         verified=f"A fix to {rel} based on your conclusion was rejected: {why}",
                                         max_steps=1, log=log)
                rec["reinvestigation"] = redo
        results.append({**rec, "status": status})
    await learn_from_fixes(settings, results, llm=llm, session_id=session_id, log=log)
    return results


REFLECT_HEADER = ("Fix loop outcomes. Turn the REJECTED attempts below into general lessons about fixing game code "
                  "(how to keep fixes local, what to check before changing a file, how a fix can break other "
                  "systems). Write rules that apply to any game, not to this game's names, places or numbers.")


async def learn_from_fixes(settings: Settings, results: list[dict], *, llm: LLM, session_id: str,
                           log: Callable[[str], None] = print) -> bool:
    """Rejected fix attempts -> the reflector (Mubit task) updates the shared lessons every fixer and
    investigator call reads. Returns True when lessons were updated."""
    from forge import roles
    from forge.memory import read_lessons, write_lessons

    rejected = [(r, t) for r in results for t in r.get("attempts", [])
                if t.get("status") not in ("fixed", None)]
    if not rejected:
        return False
    lines = [REFLECT_HEADER, ""]
    for r, t in rejected:
        detail = (t.get("verdict") or {}).get("evidence") or t.get("error") or ""
        lines.append(f"- anomaly '{r['anomaly']}' in {r.get('path')}: {t['status']}. {str(detail)[:500]}")
    kept = [r for r in results if r.get("status") == "kept"]
    if kept:
        lines += ["", "Kept (verified) fixes: " + "; ".join(f"{r['anomaly']} in {r['path']}" for r in kept)]
    try:
        new = await asyncio.to_thread(roles.reflect, llm, read_lessons(settings), "\n".join(lines),
                                      session_id=session_id)
    except LLMError as e:
        log(f"[reflector] lessons not updated: {str(e)[:100]}")
        return False
    write_lessons(settings, new)
    log(f"[reflector] lessons updated from {len(rejected)} rejected fix attempt(s)")
    return True


# ---------------------------------------------------------------- investigator (root cause before a fix)

INVESTIGATE_STEPS = 8
PROBE_TIMEOUT = 45.0
PROBE_RESULT_CHARS = 1500
READ_CHARS = 7000


def file_index(game_dir: Path, limit: int = 12_000) -> str:
    """Every Studio-synced Luau file with its first comment line: the investigator's map of the game."""
    rows = []
    for p in sorted(game_dir.rglob("*.luau")):
        rel = p.relative_to(game_dir).as_posix()
        if rel.startswith(NOT_IN_STUDIO) or "/." in rel:
            continue
        head = ""
        for ln in p.read_text(encoding="utf-8", errors="replace").splitlines()[:6]:
            if ln.strip().startswith("--") and not ln.strip().startswith("--!"):
                head = ln.strip().lstrip("-").strip()[:110]
                break
        rows.append(f"{rel}" + (f"  -- {head}" if head else ""))
    text = "\n".join(rows)
    return text if len(text) <= limit else text[:limit] + "\n...[more files]"


def investigate_message(anomaly: dict, index: str, steps: list[dict], verified: str | None) -> str:
    parts = ["## Anomaly\n" + json.dumps(anomaly, ensure_ascii=False), "## Game files\n" + index]
    if steps:
        parts.append("## Steps so far\n" + "\n\n".join(
            f"{i + 1}. {json.dumps(s['action'], ensure_ascii=False)[:1500]}\nResult: {s['result']}"
            for i, s in enumerate(steps)))
    if verified:
        parts.append("## Verified outcome\n" + verified)
    parts.append("Reply with ONE action as a JSON object.")
    return "\n\n".join(parts)


async def investigate(settings: Settings, slug: str, anomaly: dict, *, llm: LLM, studio, session_id: str,
                      verified: str | None = None, max_steps: int = INVESTIGATE_STEPS,
                      log: Callable[[str], None] = print) -> dict:
    """Find an anomaly's root cause with probes in the live playtest and code reads (Mubit task
    `investigator`). Returns {"conclusion": {...} | None, "steps": [...], "request_ids": [...]}."""
    root = RunStore(settings, slug).game_dir
    index = file_index(root)
    steps: list[dict] = []
    rids: list[str] = []
    for n in range(max(1, max_steps)):
        last = n == max_steps - 1
        msg = investigate_message(anomaly, index, steps, verified)
        if last:
            msg += "\nThis is your last step: conclude now."
        try:
            act, res = await asyncio.to_thread(llm.complete_json, "investigator", msg, session_id=session_id,
                                               required=["action"], max_tokens=2048)
        except LLMError as e:
            log(f"[investigator] unusable reply: {str(e)[:100]}")
            break
        rids.append(res.request_id)
        kind = str(act.get("action", "")).lower()
        if kind == "conclude":
            path = str(act.get("file", "")).strip().lstrip("/")
            act["file"] = path if (root / path).is_file() and not path.startswith(NOT_IN_STUDIO) else None
            log(f"[investigator] root cause: {str(act.get('root_cause', ''))[:160]} -> {act['file']} {res.request_id}")
            return {"conclusion": act, "steps": steps, "request_ids": rids}
        if kind == "read":
            path = str(act.get("path", "")).strip().lstrip("/")
            target = root / path
            if ".." in path.split("/") or not target.is_file():
                result = f"no such file: {path}"
            else:
                src = target.read_text(encoding="utf-8", errors="replace")
                result = src if len(src) <= READ_CHARS else src[:READ_CHARS] + f"\n...[{len(src) - READ_CHARS} more chars]"
            log(f"[investigator] read {path}")
        elif kind == "probe":
            dm = "Client" if str(act.get("datamodel", "Server")).lower() == "client" else "Server"
            try:
                out = await asyncio.wait_for(studio.execute_luau(str(act.get("code", "")), dm), PROBE_TIMEOUT)
                result = str(out)
            except Exception as e:  # noqa: BLE001 - a failing probe is a result the investigator can use
                result = f"probe error: {type(e).__name__}: {e}"
            result = result[:PROBE_RESULT_CHARS]
            log(f"[investigator] probe ({dm}): {str(act.get('why', ''))[:100]} -> {result[:120]}")
        else:
            result = f"unknown action {kind!r}: use read, probe or conclude"
        steps.append({"action": act, "result": result})
    return {"conclusion": None, "steps": steps, "request_ids": rids}


def pending_report_anomalies(store: ImproveStore) -> list[dict]:
    """Triaged anomalies from tester reports filed since the last improve cycle."""
    rows = store.scores()
    since = rows[-1]["ts"] if rows else ""
    path = store.dir / "reports.jsonl"
    if not path.exists():
        return []
    out = []
    for ln in path.read_text(encoding="utf-8").splitlines():
        rec = json.loads(ln) if ln.strip() else None
        if rec and rec.get("ts", "") > since:
            out += (rec.get("triage") or {}).get("anomalies") or []
    return out


async def run_cycle(settings: Settings, slug: str, *, llm: LLM, harness, playtest: Playtest,
                    faults: list[dict], goal: str, rounds: int = 3, players=None, steps: int = 15,
                    log: Callable[[str], None] = print, fix: bool = False, max_fixes: int = 3,
                    extra_anomalies: list[dict] | None = None, resync: Resync | None = None,
                    edit_human: bool = False) -> dict:
    store = ImproveStore(settings, slug)
    spec = store.run.load_spec() if store.run.spec_path.exists() else {"pitch": slug, "core_loop": ""}
    n = len(store.scores()) + 1
    session_id = f"improve-{slug}-{n}"

    await harness.ensure_ready()
    old = await plant(harness, faults)
    log(f"[cycle {n}] planted {len(faults)} faults: {', '.join(f['id'] for f in faults)}")
    try:
        before = await _rounds(settings, playtest, rounds, 1, goal=goal, players=players,
                               steps=steps, llm=llm, harness=harness)
        found = await asyncio.to_thread(audit, llm, spec, store.playbook(), before,
                                        session_id=session_id)
        sc = score(found["anomalies"], faults)
        log(f"[auditor] {len(found['anomalies'])} anomalies, detected {len(sc['detected'])}/"
            f"{len(faults)} {found['request_id']}")

        by_id = {f["id"]: f for f in faults}
        correction = None
        if sc["missed"]:
            verified = [by_id[fid]["symptom"] for fid in sc["missed"]]
            correction = await asyncio.to_thread(audit, llm, spec, store.playbook(), before,
                                                 session_id=session_id, verified=verified)
            log(f"[auditor] correction for missed {', '.join(sc['missed'])} "
                f"{correction['request_id']}")

        fixed_faults = [by_id[fid] for fid in sc["detected"]]
        await clear(harness, fixed_faults, old)
        verdicts = []
        if fixed_faults:
            after = await _rounds(settings, playtest, 1, rounds + 1, goal=goal, players=players,
                                  steps=steps, llm=llm, harness=harness)
            for f in fixed_faults:
                anomaly = found["anomalies"][sc["anomaly_for"][f["id"]]]
                change = f"{f['module']}.{f['key']} set back to {old.get(f['id'])!r}"
                v = await asyncio.to_thread(verify, llm, anomaly, change, before, after,
                                            session_id=session_id)
                verdicts.append({"fault": f["id"], **v})
                log(f"[verifier] {f['id']}: {v['verdict']} {v['request_id']}")
    finally:
        await clear(harness, faults, old)

    store.learn([by_id[fid].get("lesson", "") for fid in sc["missed"]])

    real = [found["anomalies"][i] for i in sc["unmatched_anomalies"]] + list(extra_anomalies or [])
    code_fixes: list[dict] = []
    if fix and real:
        resync = resync or studio_resync(harness)
        baseline = before
        if faults:  # the rounds above had faults planted; measure the clean game first
            await resync(store.run.game_dir)
            baseline = await _rounds(settings, playtest, 1, 1, goal=goal, players=players,
                                     steps=steps, llm=llm, harness=harness)
        code_fixes = await fix_code(settings, slug, real, baseline, llm=llm, harness=harness,
                                    playtest=playtest, resync=resync, goal=goal, players=players,
                                    steps=steps, max_fixes=max_fixes, session_id=session_id,
                                    edit_human=edit_human, log=log)
    cycle = {
        "cycle": n, "ts": now_iso(), "session_id": session_id, "goal": goal,
        "planted": len(faults), "detected": len(sc["detected"]), "missed": len(sc["missed"]),
        "unmatched": len(sc["unmatched_anomalies"]),
        "fixed_verified": sum(1 for v in verdicts if v["verdict"] == "fixed"),
        "score": sc, "audit": found, "correction": correction, "verdicts": verdicts,
        "before": before, "open": sum(1 for a in real if a["severity"] in FIX_SEVERITIES),
        "code_fixes": code_fixes, "code_kept": sum(1 for f in code_fixes if f["status"] == "kept"),
    }
    path = store.save_cycle(cycle)
    log(f"[cycle {n}] detected {cycle['detected']}/{cycle['planted']}, unmatched anomalies "
        f"{cycle['unmatched']}, fixed+verified {cycle['fixed_verified']}, open {cycle['open']}, "
        f"code fixes kept {cycle['code_kept']}/{len(code_fixes)} -> {path}")
    return cycle


# ---------------------------------------------------------------- tester reports (triage)


def triage_message(spec: dict, text: str, digests: list[dict]) -> str:
    return "\n\n".join([_game_block(spec), "## Tester report\n" + text.strip(),
                        _digests_block("Rounds", digests), "Return only the triage JSON object."])


def triage(llm: LLM, spec: dict, text: str, digests: list[dict], *, session_id: str) -> dict:
    obj, res = llm.complete_json("triage", triage_message(spec, text, digests), session_id=session_id,
                                 required=AUDIT_KEYS, max_tokens=2048)
    anomalies = [a for a in (_norm_anomaly(x) for x in obj.get("anomalies") or []) if a]
    return {"summary": str(obj.get("summary") or ""), "anomalies": anomalies,
            "request_id": res.request_id}


def _playtest_digests(settings: Settings, run_ids: list[str]) -> list[dict]:
    from mubit_tester.play import load_report

    return [round_digest(load_report(settings, rid), i + 1) for i, rid in enumerate(run_ids)]


def _latest_cycle(store: ImproveStore) -> dict | None:
    rows = store.scores()
    if not rows:
        return None
    path = store.dir / f"{rows[-1]['cycle']}.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def file_report(settings: Settings, slug: str, text: str, *, llm: LLM, run_ids: list[str] | None = None,
                reporter: str | None = None, log: Callable[[str], None] = print) -> dict:
    """A human tester's report -> triage -> auditor correction for anything the auditor missed.

    Rounds come from the named playtest runs, else from the latest improve cycle. The auditor's
    view of those rounds is a fresh audit (named runs) or that cycle's audit. Every triaged anomaly
    in a system the auditor did not flag becomes a verified outcome in a re-sent auditor call (the
    correction, in the auditor's Mubit task) and a playbook lesson."""
    if not text.strip():
        raise ValueError("the report is empty")
    store = ImproveStore(settings, slug)
    spec = store.run.load_spec() if store.run.spec_path.exists() else {"pitch": slug, "core_loop": ""}
    session_id = f"reports-{slug}"
    cycle = None if run_ids else _latest_cycle(store)
    digests = _playtest_digests(settings, run_ids) if run_ids else (cycle or {}).get("before", [])

    found = triage(llm, spec, text, digests, session_id=session_id)
    log(f"[triage] {len(found['anomalies'])} anomalies {found['request_id']}")

    audit_result = None
    if digests:
        audit_result = (cycle or {}).get("audit") or audit(llm, spec, store.playbook(), digests,
                                                            session_id=session_id)
    flagged = {a["system"] for a in (audit_result or {}).get("anomalies", [])}
    missed = [a for a in found["anomalies"] if a["system"] not in flagged]

    correction = None
    if digests and missed:
        verified = [f"A human tester found: {a['title']} ({a['system']}). {a['observed']}" for a in missed]
        correction = audit(llm, spec, store.playbook(), digests, session_id=session_id, verified=verified)
        log(f"[auditor] correction from the tester report {correction['request_id']}")
    store.learn([f"Testers reported {a['title']} in {a['system']}: check that {a['expected']}"
                 for a in missed])

    record = {"ts": now_iso(), "reporter": reporter, "text": text.strip(), "run_ids": run_ids or [],
              "rounds": len(digests), "triage": found, "auditor_missed": [a["title"] for a in missed],
              "correction": correction}
    store.dir.mkdir(parents=True, exist_ok=True)
    with (store.dir / "reports.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")
    return record


def list_reports(settings: Settings, slug: str) -> list[dict]:
    path = ImproveStore(settings, slug).dir / "reports.jsonl"
    if not path.exists():
        return []
    return [json.loads(ln) for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip()]
