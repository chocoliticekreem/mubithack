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
from forge.llm import LLM
from forge.memory import RunStore, now_iso

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
    return f"## Game\n{spec.get('pitch', '')}\nCore loop: {spec.get('core_loop', '')}"


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
    return "\n\n".join([
        "## Anomaly\n" + json.dumps(anomaly, ensure_ascii=False),
        "## Change\n" + change,
        _digests_block("Before", before),
        _digests_block("After", after),
        "Return only the verdict JSON object.",
    ])


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

    def learn(self, lessons: list[str]) -> None:
        """Fast learning: lessons from missed faults go into the next audit's playbook."""
        known = self.playbook()
        new = [ln for ln in lessons if ln and ln not in known]
        if new:
            self.dir.mkdir(parents=True, exist_ok=True)
            self.playbook_path.write_text(known + "".join(f"- {ln}\n" for ln in new),
                                          encoding="utf-8")


# ---------------------------------------------------------------- one cycle


async def _rounds(settings, playtest: Playtest, n: int, start: int, *, goal: str, players, steps: int,
                  llm, harness) -> list[dict]:
    out = []
    for i in range(n):
        rep = await playtest(settings, goal, players, steps, llm=llm, harness=harness)
        out.append(round_digest(rep, start + i))
    return out


# ---------------------------------------------------------------- code fixes for real anomalies

FIX_SEVERITIES = ("high", "medium")
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
                                  _anomaly_text(anomaly), limit=1)
    return ranked[0][0] if ranked else None


async def fix_code(settings: Settings, slug: str, anomalies: list[dict], before: list[dict], *,
                   llm: LLM, harness, playtest: Playtest, resync: Resync, goal: str, players=None,
                   steps: int = 15, max_fixes: int = 3, session_id: str, edit_human: bool = False,
                   retries: int = 1, log: Callable[[str], None] = print) -> list[dict]:
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
    for a in [x for x in anomalies if x["severity"] in FIX_SEVERITIES][:max(0, max_fixes)]:
        rel = candidate_file(settings, root, a)
        if rel is None:
            results.append({"anomaly": a["title"], "status": "no_file"})
            log(f"[fix] {a['title']}: no matching file")
            continue
        old = (root / rel).read_text(encoding="utf-8")
        problem = (f"Playtest anomaly ({a['kind']}, {a['severity']}, system {a['system']}): {a['title']}\n"
                   f"Expected: {a.get('expected', '')}\nObserved: {a.get('observed', '')}")
        rec: dict = {"anomaly": a["title"], "path": rel, "attempts": []}
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
        for attempt in range(1 + max(0, retries)):
            ask = problem if not why else (
                f"{problem}\n\n## Your previous fix was rejected\n{why}\n"
                "Try a different approach; the file below is the original.")
            new = await asyncio.to_thread(roles.fix_file, llm, rel, old, ask, context,
                                          read_lessons(settings), session_id=session_id)
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
        if status != "kept":
            (root / rel).write_text(old, encoding="utf-8")
            if any(x["status"] != "compile_failed" for x in rec["attempts"]):
                await resync(root)
            if all(x["status"] == "compile_failed" for x in rec["attempts"]):
                status = "compile_failed"
            log(f"[fix] {a['title']}: no attempt verified, {rel} restored")
        results.append({**rec, "status": status})
    return results


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
