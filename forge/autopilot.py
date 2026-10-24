"""`forge autopilot <idea-or-slug>`: one self-driving loop from an idea to a ready game, driven by the logs.

    make     an idea -> forge new (director) compile-only, then boot it headless (errors -> forge correct)
    round r:
      observe  the current version's measurement (Studio playtest: ForgeProbe errors/counters/physics, census,
               screenshot; checks headless first then Studio; a focused QA run; a short swarm; ForgeBridge
               events; critic + fun critic) + every earlier record -> one EvidenceStore (forge/evidence.py)
      detect   statistical pre-filter (z-scores, diffs vs the previous version, flat / untouched counters,
               leaks, stuck testers, time to first reward) -> Mubit `anomaly_detector` (new task) and the
               existing `gap_finder` (genre checklist + spec). Both must cite evidence ids.
      decide   merge + rank by impact x confidence (x evidence, x corroboration) -> orchestrator jobs
               (fix / feature / visual; test = focus of the next QA run), each with a call budget
      act      the jobs run through forge.orchestrator's queue, broker and workers (parallel where safe)
      verify   re-measure (focused checks + QA on what changed + a short swarm) and gate it against the
               previous version: any hard regression -> GameVersions.restore (rolled back), else kept
      learn    every decision's outcome -> learn.jsonl; the next detector / gap finder call carries the
               outcomes (same Mubit tasks); `--correct <id> "note"` -> a correction call in the right task;
               rounds.json + journal.md say what improved and why (the dashboard's Autopilot lane)
    until `forge done` is green and the scores reach --target, or --max-calls / --minutes run out.

Crash-safe and resumable: every phase writes runs/<slug>/autopilot/rounds/<r>/<phase>.json atomically and a
rerun skips what is written; the job queue (autopilot/queue.json) recovers jobs whose worker died; the call
and minute budgets are kept in autopilot/state.json across sessions.

`forge autopilot --advise --root game` is read-only: it reads the logs and telemetry of the human-built game
(evidence/<name>*, runs/<name>*, games/<name>/reports, the source) and writes a ranked report of anomalies
and improvements under runs/autopilot-advise/<name>/, never touching the game's files.
"""

from __future__ import annotations

import asyncio
import dataclasses
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from forge import evidence as evm
from forge import gaps as gapmod
from forge import llm as llm_mod
from forge.config import Settings
from forge.memory import RunStore, slugify, unique_slug

ROLE = "anomaly_detector"
if ROLE not in llm_mod.ROLES:  # a new Mubit task (forge/prompts/anomaly_detector.md, fixed text)
    llm_mod.ROLES = tuple(llm_mod.ROLES) + (ROLE,)

PHASES = ("observe", "detect", "decide", "act", "verify", "learn")
JOB_KINDS = ("fix", "feature", "polish", "asset", "test")
JOB_MAP = {"fix": "fix", "feature": "feature", "visual": "visual", "polish": "visual", "asset": "visual",
           "test": "test"}
JOB_ALIASES = {"bug": "fix", "fix_bug": "fix", "art": "asset", "sound": "asset", "juice": "polish",
               "visual": "polish", "perf": "polish", "investigate": "test", "verify": "test", "add": "feature"}
KINDS = ("error_spike", "flat_counter", "regression", "perf", "stuck", "untouched", "slow_reward", "physics", "other")
SEVERITY = {"high": 1.0, "medium": 0.8, "low": 0.55}
# estimated Mubit calls per job kind (forge correct ~3, forge feature -n 1 --polish 0 ~25)
COST = {"fix": 4, "feature": 28, "visual": 22, "test": 0}
CORRECTION_MARK = "## Correction from the developer"
OUTCOME_MARK = "## Outcomes of your previous findings"
MAX_USER_CHARS = 28_000
CRITIC_DROP = 1.0       # an LLM score this much lower is a soft regression (journal + detector evidence)
PHYSICS_RISE = 2
SMOKE_SEED = 7          # every autopilot measurement's scripted smoke play uses this seed (like for like)
BLAME_TAGS = ("job-", "combo-")  # per-job blame trials and their baseline: checks + scripted smoke play, no LLM
RECHECKS = 2            # re-runs of a check that passed before and fails now; one pass = it flips on the same code
PREFILTER = "prefilter"  # the source of the pre-filter's stand-ins when the detector call fails (not its findings)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _read(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def _write(path: Path, data: Any) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=1, ensure_ascii=False, default=str), encoding="utf-8")
    tmp.replace(path)
    return path


def _append(path: Path, rec: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")


def _lines(path: Path) -> list[dict]:
    try:
        return [json.loads(ln) for ln in Path(path).read_text(encoding="utf-8").splitlines() if ln.strip()]
    except (OSError, ValueError):
        return []


_clip = evm._clip


def _num(v: Any, lo: float, hi: float, default: float) -> float:
    try:
        x = float(v)
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, x))


norm_error = evm.norm_error


# ---------------------------------------------------------------- the anomaly detector (Mubit task)


def detector_message(goal: str, spec: dict, m: dict, cands: list[dict], st: evm.EvidenceStore, *,
                     declared: list[str] | None = None, outcomes: list[dict] | None = None,
                     rejected: list[dict] | None = None, previous: list[dict] | None = None,
                     correction: str | None = None) -> str:
    head = [f"## Goal\n{goal or 'Make this game genuinely good for real players.'}",
            "## Game\n" + f"title: {spec.get('title')}\npitch: {_clip(spec.get('pitch'), 300)}\n"
            f"core loop: {_clip(spec.get('core_loop'), 600)}\n"
            + "acceptance:\n" + "\n".join(f"- {_clip(a, 180)}" for a in (spec.get("acceptance") or [])[:12])
            + (f"\ndeclared telemetry counters: {', '.join(declared[:40])}" if declared else ""),
            f"## Version under test\n{m.get('label')} ({m.get('version') or 'unversioned'}), measured "
            f"{m.get('ts') or ''} ({'Studio playtest' if m.get('studio') else 'headless boot'})",
            "## Statistical pre-filter (deterministic: z >= 2.5 vs history, diffs vs the previous version)\n"
            + ("\n".join(f"- [{c['id']}] {c['severity']}: {c['text']} (evidence: {', '.join(c['evidence'])})"
                         for c in cands) or "- nothing moved outside its normal range")]
    tail: list[str] = []
    if outcomes:
        tail.append(OUTCOME_MARK + "\n" + "\n".join(
            f"- [{o.get('id')}] {_clip(o.get('title'), 100)} -> {o.get('outcome')}: {_clip(o.get('why'), 220)}"
            for o in outcomes[-16:]))
    if rejected:
        tail.append("## Anomalies the developer rejected (never report these again)\n" + "\n".join(
            f"- {r.get('id')}: {_clip(r.get('title'), 100)} ({_clip(r.get('note'), 160)})" for r in rejected[-20:]))
    if previous:
        tail.append("## Your previous anomaly list\n" + json.dumps(
            [{k: a.get(k) for k in ("id", "title", "kind", "severity", "impact", "evidence")} | {"job": a.get("job")}
             for a in previous[:10]], ensure_ascii=False))
    if correction:
        tail.append(f"{CORRECTION_MARK}\n{correction.strip()}\n\nApply this correction and reply with the full "
                    "corrected anomaly list.")
    fixed = "\n\n".join(head + tail)
    budget = max(3000, MAX_USER_CHARS - len(fixed) - 200)
    return "\n\n".join(head + ["## Evidence\n" + st.render(budget)] + tail)


def _norm_job(v: Any) -> str:
    s = str(v or "").strip().lower()
    s = JOB_ALIASES.get(s, s)
    return s if s in JOB_KINDS else "fix"


def parse_anomalies(obj: dict, refs: dict | set, *, files: list[str] | None = None,
                    rejected: set[str] | None = None) -> dict:
    """Validate the detector's reply like gaps.parse_gaps: real evidence ids only (an anomaly with none ranks
    at half), job kinds normalised, a fix path must be a real file, rejected ids dropped, ranked."""
    known = set(refs)
    out: list[dict] = []
    seen: set[str] = set()
    for raw in obj.get("anomalies") or []:
        if not isinstance(raw, dict):
            continue
        title = _clip(raw.get("title"), 120)
        job = raw.get("job") if isinstance(raw.get("job"), dict) else {}
        request = str(job.get("request") or "").strip()
        if not title or not request:
            continue
        aid = "an-" + slugify(title, max_words=8, max_len=56)
        if aid in seen or aid in (rejected or set()):
            continue
        seen.add(aid)
        cited = [str(r).strip().strip("[]") for r in raw.get("evidence") or [] if str(r).strip()]
        good = [r for r in cited if r in known]
        sev = str(raw.get("severity") or "medium").lower()
        sev = sev if sev in SEVERITY else "medium"
        impact = _num(raw.get("impact"), 1, 10, 5)
        conf = _num(raw.get("confidence"), 0, 1, 0.6)
        path = str(job.get("path") or "").strip() or None
        if path and files is not None and path not in files:
            path = None
        kind = str(raw.get("kind") or "other").lower()
        out.append({"id": aid, "title": title, "kind": kind if kind in KINDS else "other", "severity": sev,
                    "impact": impact, "confidence": conf, "rank": round(impact * conf * (1.0 if good else 0.5), 2),
                    "evidence": good, "unverified": [r for r in cited if r not in known],
                    "system": _clip(raw.get("system"), 60), "why": _clip(raw.get("why"), 300),
                    "job": {"kind": _norm_job(job.get("kind")), "request": request[:1200],
                            **({"path": path} if path else {})}})
    out.sort(key=lambda a: (-a["rank"], -a["impact"]))
    noise = [str(n) for n in obj.get("noise") or [] if isinstance(n, (str, int))][:20]
    return {"summary": _clip(obj.get("summary"), 600), "anomalies": out[:10], "noise": noise}


def from_prefilter(cands: list[dict]) -> list[dict]:
    """When the detector call fails, the pre-filter's high/medium candidates stand in (low confidence). Their source
    is PREFILTER: the detector never made them, so their labels never reach its Mubit task."""
    out = []
    for c in cands:
        if c["severity"] == "low":
            continue
        imp = 7 if c["severity"] == "high" else 5
        kind = "test" if c["kind"] in ("stuck", "untouched", "ttfr") else "fix"
        out.append({"id": "an-" + slugify(c["id"], max_words=8, max_len=56), "source": PREFILTER,
                    "title": _clip(c["text"], 120),
                    "kind": "other", "severity": c["severity"], "impact": imp, "confidence": 0.4,
                    "rank": round(imp * 0.4, 2), "evidence": [c["id"]] + c["evidence"][:3], "unverified": [],
                    "system": c.get("metric") or "", "why": "statistical pre-filter (the detector call failed)",
                    "job": {"kind": kind, "request": f"Investigate and fix: {c['text']}"}})
    return out


# ---------------------------------------------------------------- decide


def _tokens(text: str) -> set[str]:
    return {w for w in re.findall(r"[a-z0-9]+", str(text).lower()) if len(w) > 2} - {"the", "and", "not", "for", "with"}


def similar(a: str, b: str) -> float:
    ta, tb = _tokens(a), _tokens(b)
    return len(ta & tb) / len(ta | tb) if ta and tb else 0.0


SPECIFIC = ("check:", "stuck:", "err:", "physics:", "bridge:")


def specific_refs(refs: list[str]) -> set[str]:
    """Evidence ids that pin one concrete observation (a failing check, a stuck span, one error, one tester
    bug): two findings citing the same one are the same problem. Broad ids (metrics, genre, scores) are not."""
    return {r for r in refs or [] if str(r).startswith(SPECIFIC)
            or (str(r).startswith(("test:", "swarm:")) and "#" in str(r))}


def candidates(anomalies: list[dict], gaps: list[dict]) -> list[dict]:
    """Anomalies and gaps as one list. A gap that matches an anomaly (similar title, or the same fix file)
    is merged into it: both detectors agree, so confidence goes up and the evidence is the union. An anomaly keeps
    its source (the detector, or PREFILTER for a stand-in) and a gap its own job kind (gap_kind): each finder is
    labelled for its own finding only (gap_label)."""
    out: list[dict] = []
    for a in anomalies:
        dup = next((c for c in out if specific_refs(c["evidence"]) & specific_refs(a["evidence"])), None)
        if dup is not None:  # the detector named one problem twice: keep the higher-ranked wording
            dup["evidence"] = list(dict.fromkeys(dup["evidence"] + list(a["evidence"])))
            dup["impact"] = max(dup["impact"], a["impact"])
            continue
        src = a.get("source") or ROLE
        out.append({"id": a["id"], "source": src, "sources": [src], "title": a["title"],
                    "impact": a["impact"], "confidence": a["confidence"], "severity": a.get("severity"),
                    "evidence": list(a["evidence"]), "why": a.get("why"), "request_id": a.get("request_id"),
                    "job": dict(a["job"]), "kind": JOB_MAP.get(a["job"]["kind"], "fix")})
    for g in gaps:
        gjob = dict(g["job"])
        match = None
        for c in out:
            if c["source"] == "gap_finder":
                continue
            same_file = gjob.get("path") and gjob.get("path") == c["job"].get("path")
            shared = specific_refs(c["evidence"]) & specific_refs(g["evidence"])
            if similar(c["title"], g["title"]) >= 0.5 or same_file or shared:
                match = c
                break
        if match is not None:
            match["sources"].append("gap_finder")
            match["gap"] = g["id"]
            match["gap_kind"] = JOB_MAP.get(gjob["kind"], "feature")
            match["impact"] = max(match["impact"], g["impact"])
            match["confidence"] = min(1.0, max(match["confidence"], g["confidence"]) + 0.1)
            match["evidence"] = list(dict.fromkeys(match["evidence"] + list(g["evidence"])))
            continue
        kind = JOB_MAP.get(gjob["kind"], "feature")
        out.append({"id": "gap-" + g["id"], "gap": g["id"], "source": "gap_finder", "sources": ["gap_finder"],
                    "title": g["title"], "impact": g["impact"], "confidence": g["confidence"],
                    "evidence": list(g["evidence"]), "why": g.get("why"), "request_id": g.get("request_id"),
                    "job": gjob, "kind": kind, "gap_kind": kind})
    for c in out:
        c["score"] = score_candidate(c)
    out.sort(key=lambda c: (-c["score"], -c["impact"]))
    return out


def score_candidate(c: dict) -> float:
    """impact x confidence, halved without real evidence, x1.25 when a statistic or both detectors back it."""
    ev = c.get("evidence") or []
    s = c["impact"] * c["confidence"] * (1.0 if ev else 0.5)
    if any(str(e).startswith("stat:") for e in ev) or len(c.get("sources") or []) > 1:
        s *= 1.25
    return round(s, 2)


def decide(cands: list[dict], *, per_round: int, min_rank: float, calls_left: int | None,
           reserve: int = 0, tries: dict[str, int] | None = None, max_tries: int = 2,
           rejected: set[str] | None = None, skip: dict[str, str] | None = None) -> list[dict]:
    """Pick jobs for this round, best first, and give every candidate a reason (picked or why not). `skip`: id ->
    why it gets no job (an anomaly the reproducer could not prove)."""
    tries = tries or {}
    skip = skip or {}
    left = None if calls_left is None else max(0, calls_left - reserve)
    picked = 0
    tests = 0
    out = []
    for c in cands:
        d = {**c, "picked": False, "budget": COST.get(c["kind"], 10)}
        why_score = f"score {c['score']:g} = impact {c['impact']:g} x confidence {c['confidence']:.2g}" + \
            (" x1.25 corroborated" if len(c.get("sources") or []) > 1 or any(
                str(e).startswith("stat:") for e in c.get("evidence") or []) else "") + \
            ("" if c.get("evidence") else " x0.5 no evidence")
        if c["id"] in (rejected or set()) or c.get("gap") in (rejected or set()):
            d["reason"] = "skipped: the developer rejected it"
        elif c["id"] in skip:
            d["reason"] = f"skipped: {skip[c['id']]}"
        elif c["score"] < min_rank:
            d["reason"] = f"skipped: {why_score} is below the bar {min_rank:g}"
        elif tries.get(c["id"], 0) >= max_tries:
            d["reason"] = f"skipped: tried {tries[c['id']]} times already (rolled back or failed)"
        elif picked >= per_round:
            d["reason"] = f"skipped: {per_round} jobs per round already picked ({why_score})"
        elif c["kind"] == "test" and tests >= 1:
            d["reason"] = "skipped: one focused test per round"
        elif left is not None and d["budget"] > left:
            d["reason"] = f"skipped: needs ~{d['budget']} calls, {left} left after the verify reserve"
        else:
            d["picked"] = True
            picked += 1
            tests += c["kind"] == "test"
            if left is not None:
                left -= d["budget"]
            d["reason"] = f"picked: {why_score}; cites {', '.join(c['evidence'][:4]) or 'nothing'}" + \
                (f"; both detectors ({' + '.join(c['sources'])})" if len(c.get("sources") or []) > 1 else "")
        out.append(d)
    return out


# ---------------------------------------------------------------- labels: the detector by reproduction, the fixer by the gate

DETECTOR_LABELS = ("confirmed", "not_reproduced")
FIX_LABELS = ("kept", "rolled_back", "conflict")


def needs_repro(d: dict) -> bool:
    """A finding about broken behaviour (a fix job) is reproduced before it gets a job; a missing feature, a polish
    pass or a focused test is not (it is labelled by whether its job is kept)."""
    return d.get("kind") == "fix"


def repro_anomaly(d: dict, refs: dict[str, str]) -> dict:
    """A decision in the anomaly shape forge/repro.py's reproducer reads (the improve cycle's auditor shape)."""
    seen = [f"[{e}] {_clip(refs[e], 200)}" for e in d.get("evidence") or [] if e in refs][:6]
    return {"kind": d.get("kind"), "system": d.get("system") or "", "title": d["title"],
            "expected": _clip(d["job"]["request"], 600), "observed": _clip(d.get("why"), 300),
            "severity": d.get("severity") or "medium", "evidence": seen,
            **({"path": d["job"]["path"]} if d["job"].get("path") else {})}


def _repro_why(res: dict) -> str:
    last = (res.get("attempts") or [{}])[-1]
    status = last.get("status") or "no check"
    out = (last.get("result") or {}).get("detail") or (last.get("result") or {}).get("error") or last.get("error")
    return _clip(f"the reproducer's check {last.get('check') or ''} {status}" + (f": {out}" if out else ""), 240)


def detector_outcomes(outs: list[dict]) -> list[dict]:
    """What the anomaly detector is told about its earlier findings: whether the reproducer proved them (fix C).
    A fix result labels the fixer only and never reaches the detector."""
    return [{"id": o.get("id"), "title": o.get("title"), "round": o.get("round"), "outcome": o["detector_label"],
             "why": o.get("detector_why")}
            for o in outs if o.get("detector_label") in DETECTOR_LABELS
            and ROLE in (o.get("sources") or [o.get("source")])]


def fix_labels(act: dict, ver: dict, units: list[dict] | None) -> dict[str, dict]:
    """Fix C: each build job's fix label (kept | rolled_back | conflict, or None when per-job blame was inconclusive)
    from the gate that judged its own code, by decision id: per-job blame's when it ran, else the batch verdict. A
    job that failed or changed no file has none."""
    blame = (ver.get("blame") or {}).get("labels") or {}
    changed = None if units is None else {u["id"] for u in units}
    built = [j["gap"] for j in act.get("jobs") or [] if j.get("gap") and j.get("kind") in ("fix", "feature", "visual")
             and j.get("status") == "done" and (changed is None or j["gap"] in changed)]
    out: dict[str, dict] = {}
    for gid in built:
        if gid in blame:
            out[gid] = blame[gid]
        elif ver.get("verdict") == "kept":
            out[gid] = {"fix_label": "kept", "why": "; ".join(ver.get("improvements") or []) or "no regression"}
        elif ver.get("verdict") == "rolled_back" and len(built) == 1:  # one job is its own batch
            out[gid] = {"fix_label": "rolled_back", "why": "; ".join(ver.get("regressions") or [])}
        elif ver.get("verdict") == "rolled_back":  # several jobs and no per-job blame: the batch's failure is no one's
            out[gid] = {"fix_label": None, "blame": "inconclusive", "why": _clip(
                "the batch failed and per-job blame could not run: " + "; ".join(ver.get("regressions") or []), 300)}
    return out


def gap_label(o: dict) -> str | None:
    """A learn.jsonl record's negative label for the gap finder, or None, by the gap's own kind (gap_kind: a gap
    merged into an anomaly keeps it). Broken behaviour (fix) is labelled by reproduction (not reproduced), a
    missing feature or polish by its own job (rolled back or failed). A merged gap whose decision ran another kind
    of job gets none: that job was not the gap's. Nor do a conflict, an inconclusive blame, or the fix result of a
    proven bug."""
    gk = o.get("gap_kind") or o.get("kind")
    if gk == "fix" and o.get("detector_label") == "not_reproduced":
        return "not reproduced"
    if gk in ("feature", "visual") and o.get("kind") == gk and o.get("outcome") in ("rolled_back", "failed"):
        return o["outcome"]
    return None


# ---------------------------------------------------------------- verify: the regression gate


def _err_set(m: dict) -> set[str]:
    return {norm_error(e.get("message")) for e in m.get("errors") or [] if isinstance(e, dict)}


DEAD_COUNTERS = "core counters stopped moving"
DEAD_SCRIPTED = "scripted play counters stopped moving"
BROKEN_PLAY = "scripted play no longer runs"
STILL_FAILING = "reproducing checks do not pass"
FLIPPING = "checks that flip on the same code now fail"


def soft_dead_counters(g: dict) -> bool:
    """Soft counters (not from a like-for-like scripted play) that stopped moving: often sampling noise (the
    unseeded smoke play's runs land differently each time, so jump_pad_used can be 0 by chance), worth one
    confirming measurement for the journal. It never changes the verdict."""
    return any(str(s).startswith(DEAD_COUNTERS) for s in g.get("soft") or [])


def merge_counters(a: dict, b: dict) -> dict:
    """`a` with each counter at its larger value across two measurements of the same version: a counter that
    moved in either one is alive."""
    out = dict(a)
    ca, cb = a.get("counters") or {}, b.get("counters") or {}
    keys = {k for k, v in list(ca.items()) + list(cb.items()) if isinstance(v, (int, float))}
    out["counters"] = {k: max(float(ca.get(k) or 0), float(cb.get(k) or 0)) for k in keys}
    return out


def _numbers(d: dict | None) -> dict[str, float]:
    return {k: float(v or 0) for k, v in (d or {}).items() if isinstance(v, (int, float))}


def scripted_counters(before: dict, after: dict) -> tuple[dict[str, float], dict[str, float]]:
    """The counters both measurements took from the same scripted play (evm.HARD_SOURCES: a fixed smoke play of
    the same seed and stage assignments, the journey) -> (before, after) values of what that play moved; ({}, {})
    when nothing is like for like. Only these counters can roll a version back."""
    hb: dict[str, float] = {}
    ha: dict[str, float] = {}
    for src in evm.HARD_SOURCES:
        sb, sa = before.get(src) or {}, after.get(src) or {}
        if not (sb.get("comparable") and sa.get("comparable")) or before.get("studio") != after.get("studio"):
            continue
        if (sb.get("seed"), sb.get("stages")) != (sa.get("seed"), sa.get("stages")):
            continue
        keys = {k for k, s in (before.get("counter_sources") or {}).items() if s == src}
        cb, ca = _numbers(sb.get("counters")), _numbers(sa.get("counters"))
        hb.update({k: cb.get(k, 0.0) for k in keys})
        ha.update({k: ca.get(k, 0.0) for k in keys})
    return hb, ha


def broken_play(before: dict, after: dict) -> str | None:
    """Why a scripted play that ran like for like in `before` did not run in `after` under the same conditions
    (engine, seed, stage assignments, nothing cut for budget): no player found, or the play errored. None when it
    ran, or when the two plays are not like for like."""
    if before.get("studio") != after.get("studio"):
        return None
    for src in evm.HARD_SOURCES:
        sb, sa = before.get(src) or {}, after.get(src) or {}
        if sb.get("comparable") and sa.get("fixed") and sa.get("failed") \
                and (sb.get("seed"), sb.get("stages")) == (sa.get("seed"), sa.get("stages")):
            return f"{src}: {_clip(sa['failed'], 160)}"
    return None


def gate(before: dict, after: dict, *, must_pass: list[str] | None = None, flaky: list[str] | None = None) -> dict:
    """Keep or roll back, on deterministic evidence only (fix A of docs/research/2026-10-24-self-improvement-
    diagnosis.md). Hard regressions (any one rolls back): files that don't compile, more headless boot errors, new
    runtime errors in a like-for-like probe (same engine), checks that passed and now fail, a reproducing check of
    a fix job that does not pass (`must_pass`), more physics flags, counters of a scripted play
    (scripted_counters) that moved before and stay 0 under the same script, and that scripted play no longer
    running (broken_play). Soft regressions (journal and detector evidence, never a rollback): every other counter
    (LLM swarm or QA play, an unseeded smoke play), critic and fun scores, and a check in `flaky` (seen to flip on
    unchanged code, Autopilot.settle_checks) that now fails. Improvements are listed for the journal."""
    reg: list[str] = []
    soft: list[str] = []
    imp: list[str] = []
    notes: list[str] = []
    if after.get("compile_errors"):
        reg.append(f"{len(after['compile_errors'])} files fail luau-compile")
    b_boot, a_boot = int(before.get("boot_errors") or 0), int(after.get("boot_errors") or 0)
    if a_boot > b_boot:
        reg.append(f"headless boot errors {b_boot} -> {a_boot}")
    elif a_boot < b_boot:
        imp.append(f"headless boot errors {b_boot} -> {a_boot}")
    if before.get("studio") == after.get("studio"):  # compare like with like (Studio vs headless probe)
        new = sorted(_err_set(after) - _err_set(before))
        gone = sorted(_err_set(before) - _err_set(after))
        if new:
            reg.append(f"{len(new)} new runtime errors: {_clip('; '.join(new), 240)}")
        if gone:
            imp.append(f"{len(gone)} runtime errors gone: {_clip('; '.join(gone), 200)}")
        hb, ha = scripted_counters(before, after)
        bc = {k: v for k, v in _numbers(before.get("counters")).items() if k not in hb}
        ac = {k: v for k, v in _numbers(after.get("counters")).items() if k not in hb}

        def dead(b: dict, a: dict) -> list[str]:
            return sorted(k for k, v in b.items() if v > 0 and a.get(k, 0) == 0 and not evm.SETUP_RX.search(k)
                          and not evm.PERF_RX.search(k))

        if dead(hb, ha):
            reg.append(f"{DEAD_SCRIPTED}: {', '.join(dead(hb, ha)[:6])}")
        play = broken_play(before, after)
        if play:
            reg.append(f"{BROKEN_PLAY}: {play}")
        if dead(bc, ac):
            soft.append(f"{DEAD_COUNTERS}: {', '.join(dead(bc, ac)[:6])}")
        alive = [k for k, v in list(ac.items()) + list(ha.items()) if v > 0 and {**bc, **hb}.get(k, 0) == 0
                 and not evm.PERF_RX.search(k)]
        known = set(bc) | set(hb) | set(before.get("declared") or [])
        proof = [k for k in alive if k in known]  # a counter the jobs just added can't prove their own work
        if proof:
            imp.append(f"counters now moving: {', '.join(sorted(proof)[:6])}")
        if len(proof) < len(alive):
            notes.append(f"new counters (added this round, not counted as proof): "
                         f"{', '.join(sorted(set(alive) - set(proof))[:6])}")
        pb = len((before.get("physics") or {}).get("flagged") or [])
        pa = len((after.get("physics") or {}).get("flagged") or [])
        if pa >= pb + PHYSICS_RISE:
            reg.append(f"physics flags {pb} -> {pa}")
        elif pa < pb:
            imp.append(f"physics flags {pb} -> {pa}")
    lost = sorted(set((before.get("checks") or {}).get("passing") or [])
                  & set((after.get("checks") or {}).get("failing") or []))
    flips = [c for c in lost if c in set(flaky or [])]  # a coin flip on the same code is not deterministic evidence
    if len(flips) < len(lost):
        reg.append(f"checks that passed now fail: {', '.join([c for c in lost if c not in flips][:6])}")
    if flips:
        soft.append(f"{FLIPPING}: {', '.join(flips[:6])}")
    unfixed = sorted(set(must_pass or []) - set((after.get("checks") or {}).get("passing") or []))
    if unfixed:  # the bug a fix job was for is still there (fix C: the fixer is judged by its reproducing check)
        reg.append(f"{STILL_FAILING}: {', '.join(unfixed[:6])}")
    bp, ap = (before.get("checks") or {}).get("pass"), (after.get("checks") or {}).get("pass")
    if bp is not None and ap is not None and ap > bp:
        imp.append(f"checks passing {bp} -> {ap}")
    for key in ("critic", "fun"):
        a, b = before.get(key), after.get(key)
        if a is None or b is None:
            continue
        if b <= a - CRITIC_DROP:
            soft.append(f"{key} score {a:g} -> {b:g}")
        elif b > a:
            imp.append(f"{key} score {a:g} -> {b:g}")
    bh, ah = before.get("swarm_high"), after.get("swarm_high")
    if bh is not None and ah is not None and ah < bh:
        imp.append(f"high-severity swarm bugs {bh} -> {ah}")
    return {"verdict": "rolled_back" if reg else "kept", "regressions": reg, "soft": soft, "improvements": imp,
            "notes": notes}


# ---------------------------------------------------------------- options and the loop


@dataclass
class AutoOptions:
    goal: str = ""
    studios: list[str] = field(default_factory=list)
    use_studio: bool = True
    max_calls: int | None = 250
    minutes: float | None = 120.0
    rounds: int = 4
    per_round: int = 3
    min_rank: float = 2.0
    target: float = 8.0
    workers: int = 3
    make_iterations: int = 0
    qa_steps: int = 4
    swarm_players: int = 2
    swarm_minutes: float = 1.0
    critic: bool = True
    plan_checks: int = 6
    verify_reserve: int = 30   # calls kept back for each round's verify (QA, swarm, critics)
    polish: int = 0            # forge feature --polish N for feature/visual jobs


Measurer = Callable[["Autopilot", int, str, str], dict]
Reproducer = Callable[["Autopilot", int, dict], "dict | None"]
Rechecker = Callable[["Autopilot", str], "str | None"]


class BudgetSpent(Exception):
    pass


class Autopilot:
    """The self-driving loop for one game. `measurer(ap, round, tag, focus) -> Measurement`, `reproducer(ap, round,
    anomaly) -> repro.reproduce() result | None`, `rechecker(ap, check id) -> checks.verdict of one more run on the
    current files | None` and `runner` (orchestrator job runner) are injectable so the whole loop runs under
    FakeLLM in tests."""

    def __init__(self, settings: Settings, target: str, opts: AutoOptions, *, llm: Any = None,
                 runner: Any = None, measurer: Measurer | None = None, broker: Any = None, slots: Any = None,
                 keeper: Any = None, maker: Callable[[str], str] | None = None,
                 clock: Callable[[], float] = time.time, log: Callable[[str], None] | None = None,
                 reproducer: Reproducer | None = None, rechecker: Rechecker | None = None):
        self.s = settings
        self.target = target
        self.opts = opts
        self.llm = llm
        self.runner = runner
        self.measurer = measurer or studio_measure
        self.reproducer = reproducer or headless_reproduce
        self.rechecker = rechecker or headless_recheck
        self.broker = broker
        self.slots = slots
        self.keeper = keeper
        self.maker = maker
        self.clock = clock
        self._log = log
        self.t_session = clock()
        self.slug: str | None = target if (settings.runs_dir / target / "spec.json").exists() else None
        self.state: dict = {}
        if self.slug:
            self._bind(self.slug)

    # -- paths, state, budget

    def _bind(self, slug: str) -> None:
        self.slug = slug
        self.store = RunStore(self.s, slug)
        self.dir = self.store.dir / "autopilot"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.state = _read(self.dir / "state.json", {}) or {}
        if not self.state:
            self.state = {"slug": slug, "idea": self.target if self.target != slug else None, "created": now_iso(),
                          "calls_base": 0 if self.target != slug else evm_count(self.store.dir),
                          "minutes_prev": 0.0, "sessions": 0, "rounds": {}, "current": None, "previous": None,
                          "stop_reason": None, "tries": {}}
        self.state["sessions"] = int(self.state.get("sessions") or 0) + 1
        self.state["stop_reason"] = None
        self.state["opts"] = dataclasses.asdict(self.opts)
        self.save_state()

    def log(self, msg: str) -> None:
        line = f"{time.strftime('%H:%M:%S')} [autopilot] {msg}"
        (self._log or print)(line)
        if self.slug:
            try:
                with (self.s.runs_dir / f"autopilot-{self.slug}.log").open("a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except OSError:
                pass

    def save_state(self) -> None:
        if self.slug:
            st = dict(self.state)
            st["minutes_used"] = self.minutes_used()
            _write(self.dir / "state.json", st)

    def rdir(self, r: int) -> Path:
        return self.dir / "rounds" / str(r)

    def calls_used(self) -> int:
        if not self.slug:
            return 0
        return evm_count(self.store.dir) - int(self.state.get("calls_base") or 0)

    def minutes_used(self) -> float:
        return round(float(self.state.get("minutes_prev") or 0) + (self.clock() - self.t_session) / 60, 2)

    def calls_left(self) -> int | None:
        return None if self.opts.max_calls is None else self.opts.max_calls - self.calls_used()

    def budget(self) -> dict:
        return {"calls_used": self.calls_used(), "max_calls": self.opts.max_calls,
                "minutes_used": self.minutes_used(), "minutes": self.opts.minutes}

    def over_budget(self) -> str | None:
        if self.opts.max_calls is not None and self.calls_used() >= self.opts.max_calls:
            return f"call budget spent ({self.calls_used()}/{self.opts.max_calls} Mubit calls)"
        if self.opts.minutes is not None and self.minutes_used() >= self.opts.minutes:
            return f"time budget spent ({self.opts.minutes:g} min)"
        return None

    def check_budget(self) -> None:
        why = self.over_budget()
        if why:
            raise BudgetSpent(why)

    def get_llm(self) -> Any:
        if self.llm is None:
            self.llm = llm_mod.make_llm(self.s, log_path=self.dir / "calls.jsonl")
        return self.llm

    def write_status(self, state: str, **extra: Any) -> None:
        if not self.slug:
            return
        rounds = _read(self.dir / "rounds.json", []) or []
        _write(self.dir / "status.json", {
            "slug": self.slug, "idea": self.state.get("idea"), "goal": self.opts.goal, "state": state,
            "pid": os.getpid(), "updated": now_iso(), "round": self.state.get("round"),
            "phase": self.state.get("phase"), "budget": self.budget(), "stop_reason": self.state.get("stop_reason"),
            "target": self.opts.target, "current": _brief(self.state.get("current")),
            "rounds": rounds, "score_trend": score_trend(self.store.dir), **extra})

    # -- make

    def make(self) -> str:
        """An idea -> a built game (forge new with the director, compile-only), versioned and booted headless."""
        if self.slug:
            return self.slug
        idx_path = self.s.runs_dir / "autopilot-index.json"
        idx = _read(idx_path, {}) or {}
        slug = idx.get(self.target)
        if slug and (self.s.runs_dir / slug / "spec.json").exists():
            store = RunStore(self.s, slug)
            missing = [m for m in (store.load_spec().get("modules") or [])
                       if not (store.game_dir / m["path"]).exists()]
            if missing:  # a crash during forge new: build what is missing
                from forge.loop import run_game
                asyncio.run(run_game(slug, 0, False, settings=self.s, llm=self.llm))
        else:
            predicted = unique_slug(self.s, slugify(self.target))
            idx[self.target] = predicted
            _write(idx_path, idx)
            if self.maker:
                slug = self.maker(self.target)
            else:
                from forge.loop import new_game
                slug = asyncio.run(new_game(self.target, self.opts.make_iterations, False, settings=self.s,
                                            llm=self.llm))
            idx[self.target] = slug
            _write(idx_path, idx)
        self._bind(slug)
        self.log(f"made {slug} from the idea \"{self.target}\"")
        snapshot_if_dirty(self.store.game_dir, f"autopilot: built from the idea: {self.target}")
        self.boot_fix()
        return slug

    def boot_fix(self, tries: int = 2) -> None:
        """Boot headless; a script that errors at boot gets one forge correct per try (no Studio needed)."""
        from forge import checks as chk
        if not chk.headless_available():
            return
        for i in range(tries):
            rep = chk.boot_offline(self.store.game_dir)
            errs = [e for e in rep.get("errors") or [] if isinstance(e, dict) and e.get("script")]
            self.log(f"headless boot: {len(rep.get('errors') or [])} errors")
            if not errs:
                return
            from forge.loop import correct
            for path in list(dict.fromkeys(_script_path(self.store.game_dir, e["script"]) for e in errs))[:2]:
                if not path:
                    continue
                msg = "; ".join(_clip(e.get("message"), 200) for e in errs if _script_path(self.store.game_dir, e["script"]) == path)
                self.check_budget()
                asyncio.run(correct(self.slug, path, f"This script errors when the server boots: {msg}", False,
                                    settings=self.s, llm=self.get_llm()))
            snapshot_if_dirty(self.store.game_dir, f"autopilot: boot fixes (try {i + 1})")

    # -- observe

    def measure(self, r: int, tag: str, focus: str) -> dict:
        t0 = time.time()
        m = self.measurer(self, r, tag, focus)
        m.setdefault("ts", now_iso())
        m.setdefault("t0", t0)
        m.setdefault("label", f"ap{r}{tag[:1]}")
        if not m.get("version"):
            m["version"] = current_tag(self.store.game_dir)
        _write(self.rdir(r) / f"measure-{tag}.json", m)
        return m

    def build_evidence(self, r: int, m: dict) -> tuple[evm.EvidenceStore, list[dict]]:
        st = evm.EvidenceStore(self.rdir(r) / "evidence.json")
        for h in evm.history(self.store.dir) + kept_measurements(self.dir, exclude=m.get("label")):
            evm.add_measurement(st, h, source="history")
        prev = self.state.get("previous")
        evm.add_measurement(st, m, source="this version")
        since = float(m.get("t0") or 0) - 5
        until = rejected_after(self.dir, since)  # testers of a rolled-back version measured other code
        stuck = evm.add_tests(st, self.store.dir, since=since, until=until)
        stuck += evm.add_swarm(st, self.s.runs_dir / "playtests", self.slug, since=since, until=until)
        checks = evm.add_checks(st, self.store.dir)
        m.setdefault("checks", checks)
        evm.add_calls(st, self.store.dir)
        evm.add_bridge(st, m.get("bridge_events") or [], place=(self.opts.studios or [None])[0])
        for key in ("critic", "fun"):
            if m.get(key) is not None:
                st.add(f"score:{key}", "score", "critics", f"{key} {m[key]:g}/10: {_clip(m.get(key + '_summary'), 260)}")
        if m.get("screenshot"):
            st.add("shot:latest", "screenshot", "playtest", f"playtest screenshot {m['screenshot']}")
        spec = _read(self.store.spec_path, {}) or {}
        sources = gapmod.game_sources(self.store.game_dir)
        declared = evm.declared_counters(sources, spec)
        for k in declared:
            if float((m.get("counters") or {}).get(k) or 0) == 0:
                st.add(f"untouched:{k}", "untouched", "telemetry", f"counter {k} (declared in code) stayed 0")
        ttfr_items = st.of_kind("ttfr")
        ttfr = ttfr_items[0].data.get("seconds") if ttfr_items else None
        cands = evm.prefilter(m, prev, st, declared=declared, stuck=stuck, ttfr=ttfr, ttfr_known=bool(ttfr_items))
        evm.metric_items(st, list(dict.fromkeys(["errors", "instances", "physics_flagged"] + [
            e[len("metric:"):] for c in cands for e in c["evidence"] if e.startswith("metric:")])))
        for c in cands:
            st.add(c["id"], "stat", "prefilter", c["text"])
        st.save()
        _write(self.rdir(r) / "prefilter.json", {"candidates": cands, "declared": declared})
        return st, cands

    def observe(self, r: int) -> dict:
        p = self.rdir(r) / "observe.json"
        done = _read(p)
        if done:
            return done
        self.check_budget()
        cur = self.state.get("current")
        if not cur:
            self.log(f"round {r}: measuring the baseline version")
            cur = self.measure(r, "baseline", self.opts.goal or "the core loop and the first 60 seconds")
            self.commit(cur, r, "baseline")
        st, cands = self.build_evidence(r, cur)
        out = {"label": cur.get("label"), "version": cur.get("version"), "counts": st.counts(),
               "candidates": len(cands), "evidence_items": len(st.items)}
        self.log(f"round {r}: evidence {len(st.items)} items {st.counts()}; pre-filter {len(cands)} candidates")
        _write(p, out)
        return out

    # -- detect

    def outcomes(self) -> list[dict]:
        return [o for o in _lines(self.dir / "learn.jsonl") if o.get("outcome") != "skipped" or o.get("detector_label")]

    def rejected(self) -> list[dict]:
        return list(_read(self.dir / "rejected.json", []) or [])

    def detect(self, r: int) -> dict:
        p = self.rdir(r) / "detect.json"
        done = _read(p)
        if done:
            return done
        self.check_budget()
        st = evm.EvidenceStore.load(self.rdir(r) / "evidence.json")
        pre = _read(self.rdir(r) / "prefilter.json", {}) or {}
        cands, declared = pre.get("candidates") or [], pre.get("declared") or []
        cur = self.state.get("current") or {}
        spec = _read(self.store.spec_path, {}) or {}
        llm = self.get_llm()
        outs = self.outcomes()
        labels = detector_outcomes(outs)
        # only last round's negative labels are new feedback; older ones were already fed back
        bad_outs = [o for o in labels if o["outcome"] == "not_reproduced" and o.get("round") == r - 1]
        prev_an = [a for a in (_read(self.rdir(r - 1) / "detect.json", {}) or {}).get("anomalies") or []
                   if (a.get("source") or ROLE) == ROLE] if r > 1 else None  # its own findings, not stand-ins
        user = detector_message(self.opts.goal, spec, cur, cands, st, declared=declared, outcomes=labels,
                                rejected=self.rejected(), previous=prev_an)
        files = list(gapmod.game_sources(self.store.game_dir))
        rejected_ids = {x["id"] for x in self.rejected()}
        an_rid = None
        try:
            obj, res = llm.complete_json(ROLE, user, session_id=self.slug, required=["anomalies"], max_tokens=5000)
            parsed = parse_anomalies(obj, st.refs(), files=files, rejected=rejected_ids)
            an_rid = res.request_id
        except Exception as e:  # noqa: BLE001
            self.log(f"anomaly detector failed ({type(e).__name__}: {_clip(e, 120)}); using the pre-filter")
            parsed = {"summary": "detector failed; statistical candidates only", "anomalies": from_prefilter(cands),
                      "noise": []}
        for a in parsed["anomalies"]:
            a["request_id"] = an_rid
        if an_rid and bad_outs:  # this call carried findings the reproducer could not prove: a training correction
            _append(self.dir / "corrections.jsonl", {"ts": now_iso(), "role": ROLE, "kind": "outcome",
                                                     "round": r, "request_id": an_rid, "label": "not_reproduced",
                                                     "note": f"{len(bad_outs)} earlier findings not reproduced"})
        self.check_budget()
        gaps_rec = self.find_gaps(r, st, outs)
        out = {"summary": parsed["summary"], "anomalies": parsed["anomalies"], "noise": parsed["noise"],
               "request_id": an_rid, "gaps": gaps_rec.get("gaps") or [], "gaps_file": gaps_rec.get("n"),
               "gap_summary": gaps_rec.get("summary"), "gap_score": gaps_rec.get("score"),
               "gap_request_id": gaps_rec.get("request_id"), "prefilter": len(cands)}
        self.log(f"round {r}: {len(out['anomalies'])} anomalies, {len(out['gaps'])} gaps "
                 f"(noise: {len(out['noise'])} pre-filter candidates)")
        _write(p, out)
        return out

    def find_gaps(self, r: int, st: evm.EvidenceStore, outs: list[dict]) -> dict:
        """The existing gap_finder task, with this round's autopilot evidence in front of its own evidence,
        the jobs kept so far, and (when something was rolled back) the outcome as a correction."""
        try:
            collected = gapmod.collect_evidence(self.s, self.slug, self.opts.goal)
            ev = collected["evidence"]
            rows: list[tuple[str, str]] = []
            for it in st.items.values():
                if it.kind in ("error", "physics", "bridge", "bug", "stuck", "untouched", "ttfr", "stat", "swarm",
                               "qa", "score", "census") and it.id not in ev.refs:
                    rows.append((it.id, it.text))
                    ev.refs[it.id] = it.text
            ev.sections.insert(0, ("Autopilot measurements of this version (errors, testers, behaviour, statistics)",
                                   rows[:60]))
            kept = [f"{o.get('kind') or 'job'}: {o.get('title')}" for o in outs if o.get("outcome") == "kept"]
            bad = [o for o in outs if o.get("round") == r - 1 and "gap_finder" in (o.get("sources") or [o.get("source")])
                   and gap_label(o) is not None]
            correction = None
            if bad:
                correction = "These gaps' jobs were tried and did not survive verification:\n" + "\n".join(
                    f"- {o.get('title')}: {gap_label(o)} ({_clip(o.get('detector_why') or o.get('why'), 200)})"
                    for o in bad[-8:]) + \
                    "\nDo not propose them again unchanged; if they still matter, propose a different job."
            prev = gapmod.latest(self.s, self.slug)
            rej = gapmod.rejected(self.s, self.slug)
            user = gapmod.gap_message(collected, self.opts.goal, previous=(prev or {}).get("gaps"),
                                      rejected_gaps=rej, done_jobs=kept, correction=correction)
            obj, res = self.get_llm().complete_json(gapmod.ROLE, user, session_id=self.slug, required=["gaps"],
                                                    max_tokens=6000)
            parsed = gapmod.parse_gaps(obj, ev.refs, rejected_titles=[g.get("title", "") for g in rej],
                                       files=list(gapmod.game_sources(self.store.game_dir)))
            d = gapmod.orch_dir(self.s, self.slug) / "gaps"
            d.mkdir(parents=True, exist_ok=True)
            n = gapmod._next_n(d)
            rec = {"n": n, "ts": now_iso(), "round": r, "request_id": res.request_id, "genre": collected["genre"],
                   "correction": correction, "scan": collected["scan"], "source": "autopilot",
                   "done": {"ready": (collected["done"] or {}).get("ready")}, "evidence_refs": len(ev.refs), **parsed}
            _write(d / f"{n}.json", rec)
            for g in rec["gaps"]:
                g["request_id"] = res.request_id
            if correction:
                _append(self.dir / "corrections.jsonl", {"ts": now_iso(), "role": gapmod.ROLE, "kind": "outcome",
                                                         "round": r, "request_id": res.request_id,
                                                         "note": f"{len(bad)} gaps not reproduced, or feature jobs "
                                                                 "not kept"})
            return rec
        except Exception as e:  # noqa: BLE001
            self.log(f"gap finder failed: {type(e).__name__}: {_clip(e, 160)}")
            return {"gaps": []}

    # -- decide

    def decide(self, r: int) -> dict:
        p = self.rdir(r) / "decide.json"
        done = _read(p)
        if done:
            return done
        det = _read(self.rdir(r) / "detect.json", {}) or {}
        cands = candidates(det.get("anomalies") or [], det.get("gaps") or [])
        rejected = {x["id"] for x in self.rejected()} | {g.get("id") for g in gapmod.rejected(self.s, self.slug)}
        repro: dict[str, dict] = {}
        skip: dict[str, str] = {}
        while True:  # a finding the reproducer cannot prove gets no job; its slot goes to the next candidate
            left = self.calls_left()
            ds = decide(cands, per_round=self.opts.per_round, min_rank=self.opts.min_rank, calls_left=left,
                        reserve=self.opts.verify_reserve, tries=self.state.get("tries") or {}, rejected=rejected,
                        skip=skip)
            todo = [d for d in ds if d["picked"] and needs_repro(d) and d["id"] not in repro]
            if not todo:
                break
            for d in todo:
                rp = repro[d["id"]] = self.reproduce(r, d)
                if rp["label"] == "not_reproduced":
                    skip[d["id"]] = f"not reproduced ({rp['why']}): no fix job"
        for d in ds:
            rp = repro.get(d["id"])
            if rp is None:
                continue
            d["detector_label"], d["detector_why"] = rp["label"], rp["why"]
            if d["picked"] and rp.get("check"):
                d["check"], d["problem"] = rp["check"], rp.get("problem")
        out = {"decisions": ds, "picked": [d["id"] for d in ds if d["picked"]], "calls_left": left,
               "reproduced": {k: v["label"] for k, v in repro.items()}}
        for d in ds:
            self.log(f"round {r}: {'PICK' if d['picked'] else 'skip'} [{d['kind']}] {d['title'][:70]} :: {d['reason'][:140]}")
        _write(p, out)
        return out

    def reproduce(self, r: int, d: dict) -> dict:
        """Fix C: the detector label of a broken-behaviour finding, before it may become a fix job. A saved check it
        cites that fails on this version proves it; else the reproducer writes a check that must fail while the bug
        exists (forge/repro.py, run headless). -> {label confirmed | not_reproduced | None, why, check?, problem?
        (the failing check for the fixer's request)}. not_reproduced only when a check ran cleanly and passed (the
        game behaved correctly): it gets no job and counts as a try. None (no label, the job goes ahead unproven,
        as before reproduction existed) when no check ran cleanly: no engine, the reproducer crashed (a session
        that cannot boot the game), the Mubit call failed, or every check errored, could not set up or named no
        consumer. Saved per finding in rounds/<r>/repro/, so a resumed round does not pay for it twice."""
        from forge import repro as frepro
        from forge.scenarios import load_results

        p = self.rdir(r) / "repro" / f"{d['id']}.json"
        done = _read(p)
        if done is not None:
            return done
        failing = set(((self.state.get("current") or {}).get("checks") or {}).get("failing") or [])
        cited = [e.split(":", 1)[1] for e in d.get("evidence") or [] if str(e).startswith("check:")
                 and str(e).split(":", 1)[1] in failing]
        saved = frepro.find(self.store.dir, cited[0]) if cited else None
        if saved is not None:
            row = next((x for x in load_results(self.store.dir) if x.get("id") == saved.id), {})
            out = {"label": "confirmed", "why": f"the saved check {saved.id} fails on this version", "check": saved.id,
                   "problem": frepro.problem_block(saved, row)}
        else:
            self.check_budget()
            st = evm.EvidenceStore.load(self.rdir(r) / "evidence.json")
            crash = None
            try:
                res = self.reproducer(self, r, repro_anomaly(d, st.refs()))
            except BudgetSpent:
                raise
            except Exception as e:  # noqa: BLE001 - e.g. a headless session that cannot boot the game proves nothing
                res, crash = None, f"{type(e).__name__}: {_clip(e, 160)}"
            if crash:
                out = {"label": None, "why": f"the reproducer could not run ({crash}): the finding is not labelled"}
            elif res is None:
                out = {"label": None, "why": "no engine could run a check here: the finding is not labelled"}
            elif res.get("proven") and res.get("check") is not None:
                check, result = res["check"], res.get("result") or {}
                frepro.save_pending(self.store.dir, check)
                out = {"label": "confirmed", "check": check.id, "problem": frepro.problem_block(check, result),
                       "why": _clip(f"the reproducer's check {check.id} fails while the bug exists: "
                                    f"{result.get('detail') or ''}", 240)}
            elif any(a.get("status") == "passed" for a in res.get("attempts") or []):
                out = {"label": "not_reproduced", "why": _repro_why(res)}
                tries = self.state.setdefault("tries", {})  # a reproduction is a try: at most max_tries per finding
                tries[d["id"]] = int(tries.get(d["id"], 0)) + 1
                self.save_state()
            else:
                out = {"label": None, "why": _clip(f"no check ran cleanly ({_repro_why(res)}): the finding is not "
                                                   "labelled", 300)}
        self.log(f"round {r}: reproduce [{d['id']}] -> {out['label']}: {out['why'][:140]}")
        _write(p, out)
        return out

    # -- act

    def act(self, r: int) -> dict:
        p = self.rdir(r) / "act.json"
        done = _read(p)
        if done:
            return done
        dec = _read(self.rdir(r) / "decide.json", {}) or {}
        picked = [d for d in dec.get("decisions") or [] if d.get("picked")]
        rinfo = self.state.setdefault("rounds", {}).setdefault(str(r), {})
        if "baseline" not in rinfo:
            rinfo["baseline"] = snapshot_if_dirty(self.store.game_dir, f"autopilot round {r}: before the jobs") \
                or current_tag(self.store.game_dir)
            backup_checks(self.store.dir, self.rdir(r))
            self.save_state()
        builds = [d for d in picked if d["kind"] in ("fix", "feature", "visual")]
        tests = [d for d in picked if d["kind"] == "test"]
        jobs: list[dict] = []
        if builds:
            jobs = self.run_jobs(r, builds)
        for d in picked:
            self.state.setdefault("tries", {})[d["id"]] = int((self.state.get("tries") or {}).get(d["id"], 0)) + 1
        self.save_state()
        focus = "; ".join([_clip(d["job"]["request"], 160) for d in tests] +
                          [_clip(d["title"], 80) for d in builds]) or (self.opts.goal or "the core loop")
        out = {"baseline": rinfo["baseline"], "jobs": jobs, "tests": [d["id"] for d in tests], "focus": focus,
               "built": sum(1 for j in jobs if j.get("status") == "done")}
        _write(p, out)
        return out

    def run_jobs(self, r: int, builds: list[dict]) -> list[dict]:
        from forge.broker import JobQueue
        from forge.orchestrator import CliRunner, Options, Orchestrator
        left = self.calls_left()
        mins = None if self.opts.minutes is None else max(1.0, self.opts.minutes - self.minutes_used())
        runner = _JobChanges(self.runner or CliRunner(self.s, self.slug, self.opts.use_studio), self.store.game_dir,
                             self.rdir(r) / "jobs")
        orch = Orchestrator(self.s, self.slug, Options(goal=self.opts.goal, workers=self.opts.workers,
                                                       studios=list(self.opts.studios), use_studio=self.opts.use_studio,
                                                       max_calls=None if left is None else max(1, left - self.opts.verify_reserve // 2),
                                                       minutes=mins),
                            llm=self.get_llm(), runner=runner, broker=self.broker, slots=self.slots,
                            keeper=_KeepOpen(self.keeper) if self.keeper is not None else None,
                            queue=JobQueue(self.dir), clock=self.clock)
        if self.keeper is None:  # the orchestrator made the real keeper; keep it, hand it a non-closing view
            self.keeper = orch.keeper
            orch.keeper = _KeepOpen(self.keeper)
        self.broker, self.slots = orch.broker, orch.slots
        existing = [j for j in orch.queue.jobs() if j.get("round") == r]
        if not existing:  # a resumed round keeps the jobs it queued before the crash
            for d in builds:  # a proven bug's job carries its failing check: what "fixed" means (forge/repro.py)
                args = {"request": d["job"]["request"] + (f"\n\n{d['problem']}" if d.get("problem") else ""),
                        "polish": self.opts.polish,
                        **({"path": d["job"]["path"]} if d["job"].get("path") and d["kind"] == "fix" else {})}
                orch.queue.add(d["kind"], d["title"], priority=d["score"], args=args,
                               needs=orch._needs(d["kind"], args), gap=d["id"], round=r)
            ids = [j["id"] for j in orch.queue.jobs() if j.get("round") == r]
            orch.queue.add("verify", f"autopilot round {r}: compile every file", priority=1, needs=[], round=r, after=ids)
        lost = orch.queue.recover(orch.broker)
        if lost:
            self.log(f"recovered {len(lost)} job(s) from a crashed session")
        threads = [threading.Thread(target=orch._worker, args=(f"ap{i + 1}",), daemon=True)
                   for i in range(max(1, self.opts.workers))]
        for t in threads:
            t.start()
        try:
            orch._wait(orch.queue.idle)
        finally:
            orch._stop.set()
            for t in threads:
                t.join(timeout=120)
            orch.write_status("finished")
        jobs = [{k: j.get(k) for k in ("id", "kind", "title", "status", "error", "gap")}
                for j in orch.queue.jobs() if j.get("round") == r]
        for j in jobs:
            self.log(f"round {r}: job {j['id']} {j['status']}" + (f": {_clip(j['error'], 120)}" if j.get("error") else ""))
        if orch.stop_reason:
            self.log(f"round {r}: orchestrator stopped: {orch.stop_reason}")
        return jobs

    # -- verify

    def verify(self, r: int) -> dict:
        p = self.rdir(r) / "verify.json"
        done = _read(p)
        if done:
            return done
        act = _read(self.rdir(r) / "act.json", {}) or {}
        before = self.state.get("current") or {}
        units = self.job_units(r, act)
        g = _read(self.rdir(r) / "batch.json")  # a crash during per-job blame: the batch verdict stands, blame again
        if g:
            self.log(f"round {r}: resuming per-job blame of a batch that was rolled back")
        else:
            changed = changed_since(self.store.game_dir, act.get("baseline"))
            if not changed and not act.get("tests"):
                out = {"verdict": "no_change", "regressions": [], "improvements": [],
                       "why": "no job changed a file" if act.get("jobs") else "nothing was picked this round"}
                _write(p, out)
                return out
            self.check_budget()
            focus = act.get("focus") or self.opts.goal
            after = self.measure(r, "after", focus)
            must = self.must_pass(r, act, units)
            g = self.judge(before, after, must_pass=must) if changed else {
                "verdict": "kept", "regressions": [], "soft": [], "improvements": [], "why": "test only: no files changed"}
            if changed and g["verdict"] == "kept" and soft_dead_counters(g):
                # #150's confirming measurement, now for soft counters only: it tells noise from a real drop for
                # the journal and the next detector call; the verdict comes from the hard evidence alone
                self.log(f"round {r}: soft {'; '.join(g['soft'])[:160]}; measuring once more to confirm")
                self.check_budget()
                merged = merge_counters(after, self.measure(r, "confirm", focus))
                second = gate(before, merged, must_pass=must, flaky=self.state.get("flaky"))
                g["confirmed"] = {"first": [s for s in g["soft"] if s.startswith(DEAD_COUNTERS)],
                                  "second": [s for s in second["soft"] if s.startswith(DEAD_COUNTERS)]}
                g["soft"], after = second["soft"], merged
            g["changed"] = changed
            g["before"], g["after"] = _brief(before), _brief(after)
            if g["verdict"] == "rolled_back":
                tag = rollback(self.store.game_dir, act.get("baseline"), "; ".join(g["regressions"])[:300])
                restore_checks(self.store.dir, self.rdir(r))
                g["restored_as"] = tag
                self.log(f"round {r}: ROLLED BACK to {act.get('baseline')} ({tag}): {'; '.join(g['regressions'])[:200]}")
                _write(self.rdir(r) / "batch.json", g)
            else:
                tag = snapshot_if_dirty(self.store.game_dir, f"autopilot round {r}: kept ("
                                        + ("; ".join(g["improvements"]) or "no regression")[:200] + ")")
                after["version"] = tag or after.get("version")
                self.commit(after, r, "after")
                g["version"] = after["version"]
                self.log(f"round {r}: KEPT {after['version']}: " + ("; ".join(g["improvements"]) or "no regression"))
        blame = self.blame(r, act, before, g, units) if g["verdict"] == "rolled_back" else None
        if blame:
            m = blame.pop("measurement")
            g["blame"] = blame
            if blame["kept"]:
                self.commit(m, r, "kept")
                g["verdict"], g["version"] = "partial", m["version"]
                self.log(f"round {r}: PARTIAL {m['version']}: kept {', '.join(blame['kept'])} after per-job blame")
        g["jobs"] = fix_labels(act, g, units)
        self.promote_checks(r, g["jobs"])
        _write(p, g)
        return g

    def job_units(self, r: int, act: dict) -> list[dict] | None:
        """Each done build job's own edits, from the trees recorded around it (rounds/<r>/jobs/, _JobChanges):
        [{id (the decision), job, from, to, paths, t0, score, check}], jobs that changed nothing left out. None when
        a done job has no record (it ran before the recorder, e.g. in an older session). A file another job (done
        or failed) held the lock on while both ran is that job's."""
        from forge.versions import GameVersions

        dec = {d["id"]: d for d in (_read(self.rdir(r) / "decide.json", {}) or {}).get("decisions") or []}
        recs, done = [], set()
        for j in act.get("jobs") or []:
            if j.get("kind") not in ("fix", "feature", "visual"):
                continue
            rec = _read(self.rdir(r) / "jobs" / f"{j['id']}.json")
            ok = bool(rec and rec.get("to"))
            if j.get("status") == "done":
                if not ok:
                    return None
                done.add(j["id"])
            if ok:
                recs.append(rec)
        gv = GameVersions(self.store.game_dir)
        units = []
        for rec in recs:
            if rec["id"] not in done:
                continue
            others = {o.get("path") for o in recs if o is not rec and o.get("path")
                      and o["t0"] < rec["t1"] and rec["t0"] < o["t1"]}
            paths = [x for x in gv.changed_between(rec["from"], rec["to"]) if x not in others]
            d = dec.get(rec.get("gap")) or {}
            if paths:
                units.append({"id": rec.get("gap"), "job": rec["id"], "from": rec["from"], "to": rec["to"],
                              "paths": paths, "t0": rec["t0"], "score": d.get("score"), "check": d.get("check")})
        return units

    def must_pass(self, r: int, act: dict, units: list[dict] | None) -> list[str]:
        """The reproducing checks of this round's fix jobs that ran and changed code: each must pass after them."""
        if units is not None:
            return [u["check"] for u in units if u.get("check")]
        done = {j.get("gap") for j in act.get("jobs") or [] if j.get("status") == "done"}
        return [d["check"] for d in (_read(self.rdir(r) / "decide.json", {}) or {}).get("decisions") or []
                if d.get("picked") and d.get("check") and d["id"] in done]

    def judge(self, before: dict, after: dict, *, must_pass: list[str] | None = None) -> dict:
        """gate() of the files on disk now, after settle_checks, so a check that flips on the same code is soft."""
        self.settle_checks(before, after)
        return gate(before, after, must_pass=must_pass, flaky=self.state.get("flaky"))

    def settle_checks(self, before: dict, after: dict) -> None:
        """A check that passed in `before` and fails in `after` is run again on the same files (rechecker, up to
        RECHECKS times). One pass means it flips on unchanged code (the funfair obby's obby-movers-carry failed 2 of 6
        headless runs of one version): not deterministic evidence, so it gates soft from then on (state["flaky"]).
        A re-run that cannot judge it here (no engine, unknown, needs Studio) leaves the failure hard."""
        flaky = set(self.state.get("flaky") or [])
        lost = sorted(set((before.get("checks") or {}).get("passing") or [])
                      & set((after.get("checks") or {}).get("failing") or []) - flaky)
        flips = []
        for cid in lost:
            for _ in range(RECHECKS):
                verdict = self.rechecker(self, cid)
                if verdict == "pass":
                    flips.append(cid)
                if verdict != "fail":
                    break
        if flips:
            self.state["flaky"] = sorted(flaky | set(flips))
            self.save_state()
            self.log(f"checks that flip on the same code (soft from now on): {', '.join(flips)}")

    def blame(self, r: int, act: dict, before: dict, batch: dict, units: list[dict] | None) -> dict | None:
        """Fix B: the batch failed the gate, so find which jobs did it. Each job's own edits are re-applied alone on
        the round's baseline (GameVersions.apply, so the baseline is back between jobs) and gated alone against the
        baseline measured the same way first (tag job-baseline). BLAME_TAGS measurements are cheap (the checks and
        the scripted smoke play: no QA, swarm or critic) and always headless, so a trial is never compared with a
        Studio measurement. Jobs that pass alone are combined, best first; one that only fails together with the
        kept ones is a conflict, not a bad fix. Edits no done job made (a failed job's leftovers) are never
        re-applied. What passes is measured once more the way the batch was and gated against the round's `before`
        (confirm_kept) before it is kept. None when there is nothing to tell apart (one job and nothing else edited,
        or a job's edits were not recorded). -> {labels: {id: {fix_label, why, conflict_with?, blame?}}, kept, alone,
        unattributed, version, measurement}"""
        base = act.get("baseline")
        if not units or not base:
            return None
        unattributed = sorted(set(batch.get("changed") or []) - {x for u in units for x in u["paths"]})
        if len(units) < 2 and not unattributed:
            return None  # one job is its own batch
        from forge.versions import GameVersions, VersionError

        gv = GameVersions(self.store.game_dir)
        focus = act.get("focus") or self.opts.goal

        def put(us: list[dict], tag: str) -> dict | None:
            ids = [u["id"] for u in us]
            try:
                gv.apply(base, [(u["from"], u["to"], u["paths"]) for u in sorted(us, key=lambda u: u["t0"])],
                         f"autopilot round {r} blame: {' + '.join(ids) or 'the baseline'}"[:300])
            except VersionError as e:
                self.log(f"round {r}: blame: {' + '.join(ids)} does not apply on {base}: {_clip(e, 160)}")
                return None
            return self.measure(r, tag, focus)

        ref = put([], "job-baseline")
        if ref is None:
            return None

        def trial(us: list[dict], tag: str) -> dict | None:
            m = put(us, tag)
            return None if m is None else self.judge(ref, m, must_pass=[u["check"] for u in us if u.get("check")])

        ranked = sorted(units, key=lambda u: -float(u.get("score") or 0))
        alone = {u["id"]: trial([u], f"job-{u['id']}") for u in ranked}
        labels: dict[str, dict] = {}
        kept: list[dict] = []
        for u in ranked:
            g1 = alone[u["id"]]
            if g1 is not None and g1["verdict"] == "rolled_back":
                labels[u["id"]] = {"fix_label": "rolled_back", "why": "fails alone: " + "; ".join(g1["regressions"])}
            elif g1 is not None and not kept:
                kept = [u]
            else:
                g2 = trial(kept + [u], f"combo-{u['id']}") if kept else None
                if g2 is not None and g2["verdict"] == "kept":
                    kept = kept + [u]
                    continue
                on = ", ".join(k["id"] for k in kept) or "the baseline alone"
                labels[u["id"]] = {"fix_label": "conflict", "conflict_with": [k["id"] for k in kept], "why": _clip(
                    ("passes alone" if g1 is not None else "does not apply alone") + f"; with {on}: "
                    + ("; ".join(g2["regressions"]) if g2 is not None else "does not apply"), 300)}
        version, m = self.confirm_kept(r, act, before, kept, labels)
        for k, v in labels.items():
            self.log(f"round {r}: blame [{k}] {v['fix_label'] or v.get('blame')}: {v['why'][:140]}")
        return {"labels": labels, "kept": [u["id"] for u in kept] if m else [], "version": version, "measurement": m,
                "unattributed": unattributed,
                "alone": {k: (g["regressions"] if g is not None else "does not apply") for k, g in alone.items()}}

    def confirm_kept(self, r: int, act: dict, before: dict, kept: list[dict], labels: dict[str, dict]
                     ) -> tuple[str, dict | None]:
        """The jobs per-job blame would keep, measured the way the batch was (tag "kept" is not cheap: in Studio when
        the round is, with QA, swarm and critics) and gated against the round's `before`, so the version committed
        as current is like for like with the next round's gate. Passes -> each is labelled kept, even when every
        job had passed alone and together (the batch's failure did not recur). Fails -> nothing is kept: one job
        fails alone (rolled_back); several cannot be told apart (no fix label, blame inconclusive): a batch
        failure the cheap measurements could not reproduce is never a negative label. -> (version now on disk,
        the measurement to commit | None)"""
        from forge.versions import GameVersions

        gv = GameVersions(self.store.game_dir)
        base = act["baseline"]
        if kept:
            ids = [u["id"] for u in kept]
            version = gv.apply(base, [(u["from"], u["to"], u["paths"]) for u in sorted(kept, key=lambda u: u["t0"])],
                               f"autopilot round {r}: kept after per-job blame: {', '.join(ids)}"[:300])
            m = self.measure(r, "kept", act.get("focus") or self.opts.goal)
            g = self.judge(before, m, must_pass=[u["check"] for u in kept if u.get("check")])
            if g["verdict"] == "kept":
                m.update(label=f"ap{r}k", version=version)
                _write(self.rdir(r) / "measure-kept.json", m)
                why = "; ".join(g["improvements"]) or "no hard regression alone" + (" or together" if len(kept) > 1 else "")
                labels.update({i: {"fix_label": "kept", "why": why} for i in ids})
                return version, m
            regs = "; ".join(g["regressions"])
            if len(kept) == 1:
                labels[ids[0]] = {"fix_label": "rolled_back", "why": _clip(f"fails alone, measured like the batch: {regs}",
                                                                           300)}
            else:
                labels.update({i: {"fix_label": None, "blame": "inconclusive", "why": _clip(
                    f"{' + '.join(ids)} pass the cheap blame measurements alone and together, but fail measured like "
                    f"the batch: {regs}", 300)} for i in ids})
        version = gv.restore(base, f"autopilot round {r}: per-job blame kept no job")
        restore_checks(self.store.dir, self.rdir(r))
        return version, None

    def promote_checks(self, r: int, labels: dict[str, dict]) -> None:
        """A kept fix's reproducing check joins the suite as a regression guard (forge/repro.py); a fix that was not
        kept leaves it pending: the bug is still there."""
        from forge import repro as frepro

        dec = {d["id"]: d for d in (_read(self.rdir(r) / "decide.json", {}) or {}).get("decisions") or []}
        for k, v in labels.items():
            cid = (dec.get(k) or {}).get("check")
            check = frepro.find(self.store.dir, cid) if cid and v.get("fix_label") == "kept" else None
            if check is not None:
                frepro.promote(self.store.dir, check)

    def commit(self, m: dict, r: int, tag: str) -> None:
        """A measurement becomes the current version: an iteration record (report.json, critique.json,
        screenshot) so forge done, the gap finder and the dashboard read it like any build iteration."""
        self.state["previous"] = self.state.get("current")
        self.state["current"] = {k: v for k, v in m.items() if k not in ("bridge_events", "critic_obj", "fun_obj")}
        n = self.store.next_iteration()
        it = self.store.iteration_dir(n)
        report = {"counters": m.get("counters") or {}, "errors": m.get("errors") or [],
                  "warnings": m.get("warnings") or [], "instances": m.get("instances"),
                  "physics": m.get("physics") or {}, "census": m.get("census") or {}, "players": m.get("players"),
                  "source": f"autopilot round {r} ({tag})"}
        _write(it / "report.json", report)
        if m.get("screenshot") and Path(m["screenshot"]).exists():
            shutil.copy2(m["screenshot"], it / "screenshot.png")
        crit = dict(m.get("critic_obj") or {})
        if m.get("critic") is not None:
            crit.setdefault("score", m["critic"])
            if m.get("fun_obj"):
                crit["fun"] = {k: m["fun_obj"].get(k) for k in ("score", "scores", "summary")}
            _write(it / "critique.json", crit)
            state = self.store.load_state()
            state["iterations"].append({"n": n, "score": m["critic"], "summary": crit.get("summary") or "",
                                        "issues": crit.get("issues") or [], "version": m.get("version"),
                                        "source": "autopilot", "autopilot_round": r, "ended": now_iso(),
                                        "errors": [e.get("message") for e in m.get("errors") or []][:6]})
            self.store.save_state(state)
        if m.get("fun_obj") or m.get("fun") is not None:
            from forge.fun import FunStore
            FunStore(self.s, self.slug).save(f"ap{r}", m.get("fun_obj") or {"score": m["fun"],
                                                                            "census": m.get("census") or {}})
        self.state["current"]["iteration"] = n
        self.save_state()

    # -- learn

    def learn(self, r: int) -> dict:
        p = self.rdir(r) / "learn.json"
        done = _read(p)
        if done:
            return done
        det = _read(self.rdir(r) / "detect.json", {}) or {}
        dec = _read(self.rdir(r) / "decide.json", {}) or {}
        act = _read(self.rdir(r) / "act.json", {}) or {}
        ver = _read(self.rdir(r) / "verify.json", {}) or {}
        obs = _read(self.rdir(r) / "observe.json", {}) or {}
        jobs = {j.get("gap"): j for j in act.get("jobs") or []}
        labels = ver.get("jobs")  # fix labels by decision id (fix_labels); absent when no file changed
        entries = []
        for d in dec.get("decisions") or []:
            fix = None
            if not d.get("picked"):
                outcome = "not_reproduced" if d.get("detector_label") == "not_reproduced" else "skipped"
                why = d.get("reason")
            elif d["kind"] == "test":
                outcome, why = "tested", f"focused QA ran on it: {act.get('focus', '')[:160]}"
            else:
                j = jobs.get(d["id"]) or {}
                if j.get("status") != "done":
                    outcome, why = "failed", f"job {j.get('status')}: {j.get('error')}"
                elif labels is not None and d["id"] in labels:  # fix_label None: blame was inconclusive, no label
                    fix = labels[d["id"]]["fix_label"]
                    outcome = fix or labels[d["id"]].get("blame") or "inconclusive"
                    why = labels[d["id"]].get("why")
                elif labels is None and ver.get("verdict") in ("kept", "rolled_back"):  # verify.json of older code
                    fix = outcome = ver["verdict"]
                    why = "; ".join(ver.get("improvements" if fix == "kept" else "regressions") or []) or "no regression"
                else:
                    outcome, why = "no_change", ver.get("why") or "it changed no file"
            e = {"ts": now_iso(), "round": r, "id": d["id"], "title": d["title"], "kind": d["kind"],
                 "source": d.get("source"), "sources": d.get("sources"), "request_id": d.get("request_id"),
                 "score": d.get("score"), "outcome": outcome, "why": _clip(why, 300),
                 # the detector is labelled by reproduction, the fixer by the gate (fix C): never one by the other
                 "detector_label": d.get("detector_label"), "detector_why": d.get("detector_why"), "fix_label": fix,
                 **({"check": d["check"]} if d.get("check") else {}),
                 **({"gap_kind": d["gap_kind"]} if d.get("gap_kind") else {})}
            entries.append(e)
            if outcome != "skipped" or e["detector_label"]:
                _append(self.dir / "learn.jsonl", e)
        kept = [e for e in entries if e["outcome"] == "kept"]
        rolled = [e for e in entries if e["outcome"] == "rolled_back"]
        conflicts = [e for e in entries if e["outcome"] == "conflict"]
        verdict = ver.get("verdict") or "no_change"
        if verdict == "kept":
            what = "; ".join(ver.get("improvements") or [])
        elif verdict == "partial":
            what = (f"per-job blame kept {', '.join(e['title'] for e in kept)}; the batch failed on: "
                    + "; ".join(ver.get("regressions") or []))
        else:
            what = "nothing kept: " + "; ".join(ver.get("regressions") or [ver.get("why") or "no change"])
        why = "; ".join(f"{e['title']} ({e['outcome']})" for e in entries if e["outcome"] not in ("skipped",)) or \
            "no job was picked"
        summary = {"round": r, "ts": now_iso(), "verdict": verdict, "version": ver.get("version") or obs.get("version"),
                   "baseline": act.get("baseline"), "restored_as": ver.get("restored_as"),
                   "evidence": obs.get("counts") or {}, "evidence_items": obs.get("evidence_items"),
                   "prefilter": det.get("prefilter"), "anomalies": [{k: a.get(k) for k in ("id", "title", "severity",
                                                                                         "rank", "kind", "evidence")}
                                                                  for a in det.get("anomalies") or []],
                   "gaps": [{k: g.get(k) for k in ("id", "title", "rank", "kind")} for g in det.get("gaps") or []],
                   "decisions": [{k: d.get(k) for k in ("id", "title", "kind", "score", "picked", "reason", "sources")}
                                 | {"outcome": next((e["outcome"] for e in entries if e["id"] == d["id"]), None)}
                                 for d in dec.get("decisions") or []],
                   "jobs": act.get("jobs") or [], "kept": len(kept), "rolled_back": len(rolled),
                   "conflicts": len(conflicts), "regressions": ver.get("regressions") or [],
                   "soft": ver.get("soft") or [], "improvements": ver.get("improvements") or [],
                   "scores": {"before": ver.get("before"), "after": ver.get("after")},
                   "what_improved": what, "why": why, "budget": self.budget(),
                   "request_ids": {"anomaly_detector": det.get("request_id"), "gap_finder": det.get("gap_request_id")}}
        rounds = [x for x in _read(self.dir / "rounds.json", []) or [] if x.get("round") != r] + [summary]
        _write(self.dir / "rounds.json", sorted(rounds, key=lambda x: x["round"]))
        soft = "; ".join(ver.get("soft") or []) + (
            f" (confirming measurement: {'; '.join(ver['confirmed']['second']) or 'it moved again'})"
            if ver.get("confirmed") else "")
        with (self.dir / "journal.md").open("a", encoding="utf-8") as f:
            f.write(f"## Round {r}: {verdict}\n- What improved: {what}\n- Why: {why}\n"
                    + (f"- Soft signals (journal and detector evidence, no rollback): {soft}\n" if soft else "")
                    + f"- Evidence: {obs.get('evidence_items')} items {obs.get('counts')}; "
                    f"{len(det.get('anomalies') or [])} anomalies, {len(det.get('gaps') or [])} gaps\n"
                    f"- Budget: {self.budget()}\n\n")
        _write(p, summary)
        return summary

    # -- the loop

    def target_met(self) -> tuple[bool, dict]:
        from forge.done import readiness
        try:
            r = readiness(self.s, self.slug)
        except Exception as e:  # noqa: BLE001
            r = {"ready": False, "parts": [{"part": "done", "ok": False, "detail": str(e)}]}
        cur = self.state.get("current") or {}
        crit, fun = cur.get("critic"), cur.get("fun")
        ok = bool(r.get("ready")) and crit is not None and crit >= self.opts.target and (fun is None or fun >= self.opts.target)
        return ok, {"ready": bool(r.get("ready")), "critic": crit, "fun": fun,
                    "missing": [p["part"] for p in r.get("parts") or [] if not p["ok"]]}

    def final_verify(self, r: int) -> dict | None:
        """--studio auto: every round measured headless; the version the loop ends on is measured once more
        in Studio (screenshot, Studio checks, testers with the visual judge). Skipped with a note when no
        Studio place was given or the policy is never / always (always measured in Studio all along)."""
        from forge import headless as hl

        if hl.studio_mode() != "auto" or not (self.opts.use_studio and self.opts.studios) or not self.slug:
            return None
        p = self.dir / "final.json"
        if _read(p):
            return _read(p)
        try:
            m = self.measure(max(1, r - 1), "final", self.opts.goal or "final verify")
        except BudgetSpent:
            raise
        except Exception as e:  # noqa: BLE001
            self.log(f"final verify in Studio failed: {type(e).__name__}: {_clip(e, 160)}")
            return None
        out = {"version": m.get("version"), "errors": len(m.get("errors") or []), "studio": m.get("studio"),
               "screenshot": m.get("screenshot"), "checks": m.get("checks"), "critic": m.get("critic"),
               "fun": m.get("fun")}
        _write(p, out)
        self.log(f"final verify in Studio: {out['errors']} errors, checks {out.get('checks') or {}}")
        return out

    def round(self, r: int) -> dict:
        self.state["round"] = r
        for phase in PHASES:
            self.state["phase"] = phase
            self.save_state()
            self.write_status("running")
            getattr(self, phase)(r)
        return _read(self.rdir(r) / "learn.json", {}) or {}

    def run(self) -> dict:
        try:
            if not self.slug:
                self.make()
            self.write_status("running")
            done_rounds = sorted(int(k) for k, v in (self.state.get("rounds") or {}).items() if v.get("learned"))
            r = (done_rounds[-1] + 1) if done_rounds else 1
            first = r
            while True:
                ok, info = self.target_met()
                if ok:
                    self.state["stop_reason"] = f"target met: forge done is green and scores >= {self.opts.target:g}"
                    break
                if r >= first + self.opts.rounds:
                    self.state["stop_reason"] = f"ran {self.opts.rounds} round(s); still missing {', '.join(info['missing']) or 'score'}"
                    break
                self.check_budget()
                summary = self.round(r)
                self.state.setdefault("rounds", {}).setdefault(str(r), {})["learned"] = True
                self.save_state()
                if not any(d.get("picked") for d in summary.get("decisions") or []) and summary.get("verdict") == "no_change":
                    self.state["stop_reason"] = "nothing above the bar to do (no anomaly or gap worth a job)"
                    break
                r += 1
            self.final_verify(r)
        except BudgetSpent as e:
            self.state["stop_reason"] = str(e)
        except BaseException as e:  # a crash or Ctrl-C/SIGTERM: say so; a rerun resumes from the saved phases
            self.state["stop_reason"] = f"interrupted ({type(e).__name__}: {_clip(e, 120)}); rerun to resume"
            raise
        finally:
            if self.slug:
                if self.keeper is not None:
                    for place in self.opts.studios:
                        if place in getattr(self.keeper, "opened", set()):
                            self.keeper.release(place)
                self.state["minutes_prev"] = self.minutes_used()
                self.t_session = self.clock()
                self.state["phase"] = "finished"
                self.save_state()
                self.write_status("finished")
                self.log(f"finished: {self.state.get('stop_reason')}; {self.budget()}")
        return {"slug": self.slug, "stop_reason": self.state.get("stop_reason"), "budget": self.budget(),
                "rounds": _read(self.dir / "rounds.json", []) if self.slug else []}


# ---------------------------------------------------------------- helpers: versions, checks, scores


def kept_measurements(ap_dir: Path, exclude: str | None = None) -> list[dict]:
    """Measurements of versions that exist: each round's baseline, every kept 'after' and the version per-job
    blame kept ('kept', when its confirmation passed: verdict partial), oldest first."""
    out = []
    for r in sorted(int(p.name) for p in (ap_dir / "rounds").glob("*") if p.name.isdigit()):
        rd = ap_dir / "rounds" / str(r)
        for tag in ("baseline", "after", "kept"):
            m = _read(rd / f"measure-{tag}.json")
            if not m or m.get("label") == exclude:
                continue
            verdict = (_read(rd / "verify.json", {}) or {}).get("verdict")
            if (tag == "after" and verdict != "kept") or (tag == "kept" and verdict != "partial"):
                continue
            out.append(m)
    return out


def rejected_after(ap_dir: Path, since: float) -> float | None:
    """Start time of the first rolled-back measurement after `since` (tests after it saw rejected code; a partial
    round's batch was rolled back too)."""
    ts = []
    for rd in (ap_dir / "rounds").glob("*"):
        m = _read(rd / "measure-after.json")
        if m and float(m.get("t0") or 0) > since and (_read(rd / "verify.json", {}) or {}).get("verdict") in (
                "rolled_back", "partial"):
            ts.append(float(m["t0"]) - 1)
    return min(ts) if ts else None


class _JobChanges:
    """The job runner (forge/orchestrator.py) wrapped so each build job's own edits are known: the game's files as
    a git tree when the job starts and when it ends (GameVersions.tree) -> rounds/<r>/jobs/<job id>.json. A retried
    job keeps the tree of its first start. Per-job blame (Autopilot.blame) replays one job's edits from these."""

    def __init__(self, inner: Any, game_dir: Path, out_dir: Path) -> None:
        from forge.versions import GameVersions

        self.inner, self.gv, self.out = inner, GameVersions(game_dir), out_dir
        self.lock = threading.Lock()  # one git index: the tree captures of parallel jobs take turns

    def _tree(self) -> str | None:
        from forge.versions import VersionError

        try:
            return self.gv.tree()
        except (OSError, VersionError):
            return None  # no record: blame falls back to the batch verdict for the round

    def __call__(self, job: dict, env: dict, should_stop: Callable[[], bool], beat: Callable[[], None]) -> Any:
        p = self.out / f"{job['id']}.json"
        with self.lock:
            rec = _read(p) or {"id": job["id"], "gap": job.get("gap"), "kind": job["kind"],
                               "path": (job.get("args") or {}).get("path"), "t0": time.time(), "from": self._tree()}
        try:
            return self.inner(job, env, should_stop, beat)
        finally:
            with self.lock:
                to = self._tree()
                if rec.get("from") and to:
                    _write(p, {**rec, "t1": time.time(), "to": to})


class _KeepOpen:
    """The orchestrator's view of the Studio keeper during act: it may open the window, never close it
    (verify needs it next; the autopilot closes it at the end)."""

    def __init__(self, keeper: Any) -> None:
        self.keeper = keeper
        self.opened: set[str] = set()

    def prepare(self, place: str) -> str | None:
        return self.keeper.prepare(place)

    def release(self, place: str) -> None:
        return None


def evm_count(run_dir: Path) -> int:
    from forge.orchestrator import count_calls
    return count_calls(run_dir) if run_dir.exists() else 0


def _git(game_dir: Path, *args: str) -> str:
    res = subprocess.run(["git", *args], cwd=game_dir, capture_output=True, text=True)
    return res.stdout.strip() if res.returncode == 0 else ""


def current_tag(game_dir: Path) -> str | None:
    from forge.versions import GameVersions
    try:
        return GameVersions(game_dir).current()
    except Exception:  # noqa: BLE001
        return None


def snapshot_if_dirty(game_dir: Path, message: str) -> str | None:
    """A new version when files changed since the last one; else the current tag."""
    from forge.versions import GameVersions
    gv = GameVersions(game_dir)
    if not game_dir.exists():
        return None
    if gv.exists() and gv.current() and not _git(game_dir, "status", "--porcelain"):
        return gv.current()
    return gv.snapshot(message)


def changed_since(game_dir: Path, tag: str | None) -> list[str]:
    if not tag:
        return []
    snapshot_if_dirty(game_dir, "autopilot: files the jobs wrote")
    out = _git(game_dir, "diff", "--name-only", tag, "HEAD")
    return [p for p in out.splitlines() if p.endswith(".luau")]


def rollback(game_dir: Path, tag: str | None, reason: str) -> str | None:
    from forge.versions import GameVersions
    if not tag:
        return None
    return GameVersions(game_dir).restore(tag, f"autopilot regression gate: {reason}")


def backup_checks(run_dir: Path, rdir: Path) -> None:
    src = run_dir / "checks" / "results.json"
    if src.exists():
        rdir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, rdir / "checks-before.json")


def restore_checks(run_dir: Path, rdir: Path) -> None:
    src = rdir / "checks-before.json"
    if src.exists():
        shutil.copy2(src, run_dir / "checks" / "results.json")


def _script_path(game_dir: Path, script: str) -> str | None:
    """'ServerScriptService.Game' -> 'ServerScriptService/Game.server.luau' (a real file), else None."""
    name = str(script or "").replace(".", "/").split(":")[0]
    leaf = name.split("/")[-1]
    for p in sorted(game_dir.rglob("*.luau")):
        rel = p.relative_to(game_dir).as_posix()
        if rel.startswith("tools/"):
            continue
        stem = p.name.split(".")[0]
        if stem == leaf:
            return rel
    return None


def _brief(m: dict | None) -> dict | None:
    if not m:
        return None
    return {"label": m.get("label"), "version": m.get("version"), "critic": m.get("critic"), "fun": m.get("fun"),
            "errors": len(m.get("errors") or []), "boot_errors": m.get("boot_errors"),
            "checks": {k: (m.get("checks") or {}).get(k) for k in ("pass", "fail")},
            "physics": len((m.get("physics") or {}).get("flagged") or []), "swarm_high": m.get("swarm_high"),
            "ttfr_s": m.get("ttfr_s"), "screenshot": m.get("screenshot"), "studio": m.get("studio"),
            **{k: m[k] for k in ("round_started", "observed_s") if k in m}}


def score_trend(run_dir: Path) -> list[dict]:
    """Critic / fun / errors per autopilot measurement (kept and rejected), oldest first."""
    out = []
    for r in sorted((int(p.name) for p in (run_dir / "autopilot" / "rounds").glob("*") if p.name.isdigit())):
        for tag in ("baseline", "after"):
            m = _read(run_dir / "autopilot" / "rounds" / str(r) / f"measure-{tag}.json")
            if m:
                ver = _read(run_dir / "autopilot" / "rounds" / str(r) / "verify.json", {}) or {}
                out.append({"round": r, "tag": tag, "label": m.get("label"), "version": m.get("version"),
                            "critic": m.get("critic"), "fun": m.get("fun"), "errors": len(m.get("errors") or []),
                            "checks_pass": (m.get("checks") or {}).get("pass"),
                            "kept": None if tag == "baseline" else ver.get("verdict") == "kept"})
    return out


# ---------------------------------------------------------------- the real measurement (Studio + headless)


def studio_measure(ap: Autopilot, r: int, tag: str, focus: str) -> dict:
    """Measure the current files: compile, headless boot, checks, a playtest (probe + census), a focused QA
    run, a short swarm, ForgeBridge events, critic + fun critic.

    Headless by default (forge/headless.py, --studio auto|never): the playtest, the checks, QA and the swarm
    run on the headless engine with simulated players, no Studio lease. Studio is used only for the final
    verify (tag "final", --studio auto) and for every measurement with --studio always: then the playtest
    gets a screenshot, failed checks are re-run in Studio and the testers' visual judge sees screenshots.

    The checks include the pending ones (proven bugs, forge/repro.py): a fix job is judged by its check passing.
    A per-job blame measurement (tag in BLAME_TAGS) is the hard evidence only: compile, boot, checks and the headless
    playtest with its scripted smoke play; no QA, swarm or critic, so no LLM call."""
    from forge import checks as chk
    from forge import headless as hl
    from forge import repro as frepro
    from forge.loop import _load_check_fn
    s, store = ap.s, ap.store
    cheap = tag.startswith(BLAME_TAGS)
    out_dir = ap.rdir(r) / tag
    out_dir.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    compile_errors = [list(e) for e in _load_check_fn(s)(store.game_dir)]
    boot = chk.boot_offline(store.game_dir) if chk.headless_available() else {}
    llm = ap.get_llm()
    existing = chk.load_checks(store.dir)
    if not existing and ap.opts.plan_checks and not compile_errors and not cheap:
        try:
            from forge.scenarios import plan_checks
            plan_checks(s, ap.slug, llm=llm, max_checks=ap.opts.plan_checks, log=ap.log)
            existing = chk.load_checks(store.dir)
        except Exception as e:  # noqa: BLE001
            ap.log(f"check planning failed: {type(e).__name__}: {_clip(e, 120)}")
    existing = existing + frepro.load_pending(store.dir)
    mode = hl.studio_mode()
    in_studio = (ap.opts.use_studio and bool(ap.opts.studios) and not compile_errors and not cheap
                 and (mode == "always" or (mode == "auto" and tag == "final")))
    passed, rest = chk.triage(store.game_dir, existing, mode="auto" if in_studio else "never") if existing else ([], [])
    results = [{**x, "verdict": x.get("verdict") or "pass", "source": "headless"} for x in passed]
    m: dict = {}
    console = ""
    if in_studio:
        try:
            m, console, results = asyncio.run(_studio_part(ap, r, tag, focus, out_dir, rest, results))
        except BudgetSpent:
            raise
        except Exception as e:  # noqa: BLE001
            ap.log(f"Studio measurement failed: {type(e).__name__}: {_clip(e, 200)}; using the headless boot")
            m = {}
    elif not compile_errors and hl.available():
        try:
            m, console = asyncio.run(_headless_part(ap, r, tag, focus, out_dir, cheap=cheap))
        except BudgetSpent:
            raise
        except Exception as e:  # noqa: BLE001
            ap.log(f"headless measurement failed: {type(e).__name__}: {_clip(e, 200)}; using the headless boot")
            m = {}
        if results:
            from forge.scenarios import save_results
            save_results(store.dir, results)
    if not m:
        m = evm.measurement_from_probe(boot, label=f"ap{r}{tag[:1]}", studio=False)
        if results:
            from forge.scenarios import save_results
            save_results(store.dir, results)
    m.update(compile_errors=compile_errors, boot_errors=len(boot.get("errors") or []) if boot else None, t0=t0,
             # an unknown (setup failure, or needs Studio to judge) is neither: it must not read as a regression
             checks={"pass": sum(1 for x in results if x.get("ok")),
                     "fail": sum(1 for x in results if not x.get("ok") and not x.get("setup")),
                     "passing": [x["id"] for x in results if x.get("ok")],
                     "failing": [x["id"] for x in results if not x.get("ok") and not x.get("setup")],
                     "unknown": [x["id"] for x in results if not x.get("ok") and x.get("setup")]} if results else {})
    m["declared"] = evm.declared_counters(gapmod.game_sources(store.game_dir), _read(store.spec_path, {}) or {})
    m["bridge_events"] = [e for e in evm.bridge_events() if float(e.get("time") or 0) >= t0 - 1]
    if ap.opts.critic and not compile_errors and not cheap and (ap.calls_left() is None or ap.calls_left() > 4):
        files = gapmod.game_sources(store.game_dir)
        spec = _read(store.spec_path, {}) or {}
        probe = {k: m.get(k) for k in ("counters", "errors", "warnings", "instances", "players")}
        try:
            from forge import roles
            crit = roles.critique(llm, spec, probe, console, files, session_id=ap.slug)
            m.update(critic=float(crit.get("score") or 0), critic_summary=crit.get("summary"), critic_obj=crit)
        except Exception as e:  # noqa: BLE001
            ap.log(f"critic failed: {type(e).__name__}: {_clip(e, 120)}")
        if os.environ.get("FORGE_FUN_CRITIC", "1") != "0" and not spec.get("base_files"):
            try:
                from forge.fun import fun_critique
                fun = fun_critique(llm, spec, files, probe, census=m.get("census") or None, session_id=ap.slug)
                m.update(fun=float(fun.get("score") or 0), fun_summary=fun.get("summary"), fun_obj=fun)
            except Exception as e:  # noqa: BLE001
                ap.log(f"fun critic failed: {type(e).__name__}: {_clip(e, 120)}")
    return m


def headless_reproduce(ap: Autopilot, r: int, anomaly: dict) -> dict | None:
    """The reproducer (forge/repro.py, Mubit task `reproducer`) on a headless session of the current version ->
    repro.reproduce()'s {proven, check, result, attempts}; None when no engine here can run a check (the luau CLI
    is missing), so the finding stays unlabelled instead of looking unreproducible. A proven check must also fail
    the way the gate will run it (checks.run_check_offline, as in studio_measure): one only Studio can judge stays
    unlabelled, or every fix of that bug would be rolled back for a check the gate can never see pass."""
    from forge import checks as chk
    from forge import headless as hl
    from forge import repro as frepro

    if not chk.headless_available():
        return None

    async def go() -> dict:
        hs = hl.HeadlessStudio(ap.store.game_dir, players=1, slug=ap.slug, kind="repro")
        try:
            await hs.play()
            return await frepro.reproduce(ap.s, ap.slug, anomaly, None, llm=ap.get_llm(), studio=hs,
                                          session_id=ap.slug, log=ap.log)
        finally:
            await hs.stop()

    res = asyncio.run(go())
    if res.get("proven") and res.get("check") is not None:
        offline = chk.run_check_offline(ap.store.game_dir, res["check"])
        if offline.get("verdict") != "fail":
            ap.log(f"round {r}: {res['check'].id} fails in the session but is {offline.get('verdict')} where the gate "
                   "runs checks: not labelled")
            return None
    return res


def headless_recheck(ap: Autopilot, check_id: str) -> str | None:
    """One saved check (suite or pending) run once more headless on the current files, the way a measurement
    runs it (checks.run_check_offline) -> its checks.verdict: pass | fail | unknown | needs_studio. None when it
    cannot run here: no luau CLI, no such check, or a check marked `-- needs: studio` (no headless verdict counts)."""
    from forge import checks as chk
    from forge import repro as frepro

    if not chk.headless_available():
        return None
    check = frepro.find(ap.store.dir, check_id)
    if check is None or check.needs == "studio":
        return None
    return chk.run_check_offline(ap.store.game_dir, check).get("verdict")


async def _headless_part(ap: Autopilot, r: int, tag: str, focus: str, out_dir: Path, *,
                         cheap: bool = False) -> tuple[dict, str]:
    """The measurement without Studio: a headless playtest (probe report + census), then a focused QA run and
    a short swarm on headless sessions (simulated players; no screenshots, so no visual judge). The playtest
    plays the scripted smoke play as a fixed play (SMOKE_SEED, and the bot stages of the version this one is
    compared with), so its counters are like for like and may gate (evidence.HARD_SOURCES). cheap (per-job
    blame): the playtest only."""
    from forge import headless as hl
    from forge import smoke
    s, store = ap.s, ap.store
    t0 = time.time()
    spec = _read(store.spec_path, {}) or {}
    stages = ((ap.state.get("current") or {}).get("smoke") or {}).get("stages")
    report = await hl.playtest(store.game_dir, play=30.0, players=max(1, ap.opts.swarm_players or 1),
                               start_round=bool((spec.get("playtest") or {}).get("start_round")), slug=ap.slug,
                               during=lambda hs: smoke.smoke_play(hs, spec, store.game_dir, budget_s=smoke.smoke_seconds(),
                                                                  seed=SMOKE_SEED, stages=stages))
    steps = [{"step": "playtest", "ok": "error" not in report, "engine": "headless", "secs": report.get("wall")}]
    m = evm.measurement_from_probe(report, label=f"ap{r}{tag[:1]}", studio=False, playtest_steps=steps)
    m["census"] = report.get("census") or {}
    m["engine"] = "headless"
    m["needs_studio"] = [n.get("feature") for n in report.get("needs_studio") or []]
    console = "\n".join([f"[warn] {w}" for w in report.get("warnings") or []])
    llm = ap.get_llm()
    gsettings = dataclasses.replace(s, base_game_dir=store.game_dir)
    if ap.opts.qa_steps and not cheap and (ap.calls_left() is None or ap.calls_left() > 12):
        hs = hl.HeadlessStudio(store.game_dir, players=1, slug=ap.slug, kind="qa")
        try:
            from mubit_tester.protocol import qa_test
            qa = await qa_test(gsettings, focus, game_dir=store.game_dir, slug=ap.slug, max_steps=ap.opts.qa_steps,
                               llm=llm, studio=hs, max_investigations=1, key_images=2)
            m["qa"] = {"run_id": qa.get("run_id"), "goal_met": qa.get("goal_met"), "bugs": len(qa.get("bugs") or []),
                       "test_dir": qa.get("test_dir"), "screenshots": [], "engine": "headless"}
        except Exception as e:  # noqa: BLE001
            ap.log(f"QA (headless) failed: {type(e).__name__}: {_clip(e, 160)}")
        finally:
            await hs.stop()
    if ap.opts.swarm_players and not cheap and (ap.calls_left() is None or ap.calls_left() > 20):
        hs = hl.HeadlessStudio(store.game_dir, players=ap.opts.swarm_players, slug=ap.slug, kind="swarm")
        try:
            from mubit_tester.swarm import run_swarm
            sw = await run_swarm(gsettings, players=ap.opts.swarm_players, minutes=ap.opts.swarm_minutes,
                                 llm=llm, studio=hs, slug=ap.slug, goal=focus, max_steps=12, screenshots=False)
            bugs = [b for b in sw.get("bugs") or [] if b.get("real")]
            t = evm.first_reward(sw.get("soak") or [])
            m.update(swarm={"run_id": sw.get("run_id"), "bugs": len(bugs), "shots": 0, "engine": "headless"},
                     swarm_high=sum(1 for b in bugs if b.get("severity") == "high"), ttfr_s=t)
        except Exception as e:  # noqa: BLE001
            ap.log(f"swarm (headless) failed: {type(e).__name__}: {_clip(e, 160)}")
        finally:
            await hs.stop()
    ap.log(f"measured headless in {time.time() - t0:.0f}s ({len(report.get('errors') or [])} errors"
           + (f"; needs Studio to judge: {', '.join(m['needs_studio'])[:120]}" if m["needs_studio"] else "") + ")")
    return m, console


async def _studio_part(ap: Autopilot, r: int, tag: str, focus: str, out_dir: Path, rest: list, results: list):
    from forge.loop import Run
    from forge.orchestrator import LLM_SLOTS, SYNC_PORTS, StudioKeeper
    from forge.broker import Broker, StudioSlots
    from forge.studio import Studio
    if ap.slots is None:
        ap.slots = StudioSlots()
    if ap.broker is None:
        ap.broker = Broker(pools={"llm": [f"llm-{i}" for i in range(1, LLM_SLOTS + 1)], "sync": SYNC_PORTS,
                                  "studio": list(ap.opts.studios),
                                  "game": [f"game:{ap.store.dir}#{i}" for i in range(1, 5)]},
                           studio_slots=ap.slots)
    if ap.keeper is None:
        ap.keeper = StudioKeeper(ap.s, ap.slug, ap.slots, ap.log)
    holder = f"autopilot-{ap.slug}-measure"
    deadline = time.monotonic() + 1800
    leases = None
    while leases is None:
        leases = ap.broker.try_acquire(["studio", "sync", "game:all"], holder)
        if leases is None:
            if time.monotonic() > deadline:
                raise RuntimeError(f"no Studio lease in 30 min (busy: {ap.broker.last_blocked})")
            await asyncio.sleep(3)
    try:
        place = next(x["slot"] for x in leases if x["pool"] == "studio")
        port = int(next(x["slot"] for x in leases if x["pool"] == "sync"))
        sid = await asyncio.to_thread(ap.keeper.prepare, place)
        if not sid:
            raise RuntimeError(f"Studio {place} did not connect")
        s2 = dataclasses.replace(ap.s, sync_port=port)
        llm = ap.get_llm()
        async with Studio(s2, studio_id=sid) as st:
            await st.select(sid)
            run = Run(s2, ap.store, llm)
            run.spec = ap.store.load_spec()
            rec: dict = {"steps": []}
            report, console = await run.playtest(st, rec, out_dir)
            run.close()
            shot = out_dir / "screenshot.png"
            m = evm.measurement_from_probe(report, label=f"ap{r}{tag[:1]}", studio=True,
                                           screenshot=str(shot) if shot.exists() else None,
                                           playtest_steps=rec["steps"])
            if rest:
                from forge.scenarios import run_plan
                try:
                    results = await run_plan(st, ap.slug, settings=s2, llm=llm, log=ap.log,
                                             only={c.id for c in rest}, prior=results)
                except Exception as e:  # noqa: BLE001
                    ap.log(f"Studio checks failed: {type(e).__name__}: {_clip(e, 160)}")
            elif results:
                from forge.scenarios import save_results
                save_results(ap.store.dir, results)
            gsettings = dataclasses.replace(s2, base_game_dir=ap.store.game_dir)
            if ap.opts.qa_steps and (ap.calls_left() is None or ap.calls_left() > 12):
                try:
                    from mubit_tester.protocol import qa_test
                    qa = await qa_test(gsettings, focus, game_dir=ap.store.game_dir, slug=ap.slug,
                                       max_steps=ap.opts.qa_steps, llm=llm, studio=st, max_investigations=1,
                                       key_images=2)
                    m["qa"] = {"run_id": qa.get("run_id"), "goal_met": qa.get("goal_met"),
                               "bugs": len(qa.get("bugs") or []), "test_dir": qa.get("test_dir"),
                               "screenshots": (qa.get("screenshots") or [])[:4]}
                except Exception as e:  # noqa: BLE001
                    ap.log(f"QA failed: {type(e).__name__}: {_clip(e, 160)}")
                    await _safe_stop(st)
            if ap.opts.swarm_players and (ap.calls_left() is None or ap.calls_left() > 20):
                try:
                    from mubit_tester.swarm import run_swarm
                    sw = await run_swarm(gsettings, players=ap.opts.swarm_players, minutes=ap.opts.swarm_minutes,
                                         llm=llm, studio=st, slug=ap.slug, goal=focus, max_steps=12)
                    bugs = [b for b in sw.get("bugs") or [] if b.get("real")]
                    t = evm.first_reward(sw.get("soak") or [])
                    m.update(swarm={"run_id": sw.get("run_id"), "bugs": len(bugs), "shots": len(sw.get("shots") or [])},
                             swarm_high=sum(1 for b in bugs if b.get("severity") == "high"), ttfr_s=t)
                except Exception as e:  # noqa: BLE001
                    ap.log(f"swarm failed: {type(e).__name__}: {_clip(e, 160)}")
                    await _safe_stop(st)
            await _safe_stop(st)
        return m, console, results
    finally:
        ap.broker.release(holder)
        from forge import headless as hl
        hl.record("measure", "studio", time.monotonic() - deadline + 1800, slug=ap.slug, note=tag)


async def _safe_stop(st: Any) -> None:
    try:
        state = await st.state()
        if state.get("playing") or state.get("running"):
            await st.stop()
    except Exception:  # noqa: BLE001
        try:
            await st.stop()
        except Exception:  # noqa: BLE001
            pass


# ---------------------------------------------------------------- human corrections


def find_run_with(settings: Settings, item_id: str) -> str | None:
    """The newest autopilot run whose decisions mention `item_id`."""
    best = None
    for d in settings.runs_dir.glob("*/autopilot/rounds/*/decide.json"):
        rec = _read(d, {}) or {}
        if any(x.get("id") == item_id or x.get("gap") == item_id for x in rec.get("decisions") or []):
            mt = d.stat().st_mtime
            if best is None or mt > best[0]:
                best = (mt, d.parents[3].name)
    return best[1] if best else None


def correct(settings: Settings, slug: str, item_id: str, note: str, *, llm: Any = None,
            goal: str = "") -> dict:
    """`forge autopilot <slug> --correct <id> "note"`: the developer's note on one finding becomes a call in
    the Mubit task that produced it (anomaly_detector or gap_finder), and the id is never proposed again."""
    store = RunStore(settings, slug)
    ap_dir = store.dir / "autopilot"
    rounds = sorted((int(p.name) for p in (ap_dir / "rounds").glob("*") if p.name.isdigit()), reverse=True)
    found, r_found = None, None
    for r in rounds:
        dec = _read(ap_dir / "rounds" / str(r) / "decide.json", {}) or {}
        for d in dec.get("decisions") or []:
            if item_id in (d.get("id"), d.get("gap"), "an-" + item_id, "gap-" + item_id):
                found, r_found = d, r
                break
        if found:
            break
    if not found:
        raise KeyError(f"no autopilot decision {item_id!r} in {slug}")
    llm = llm or llm_mod.make_llm(settings, log_path=ap_dir / "calls.jsonl")
    rec: dict = {"ts": now_iso(), "id": found["id"], "title": found["title"], "note": note, "round": r_found,
                 "kind": "correction"}
    rej = list(_read(ap_dir / "rejected.json", []) or [])
    rej.append({"id": found["id"], "title": found["title"], "note": note, "ts": rec["ts"]})
    _write(ap_dir / "rejected.json", rej)
    if ROLE in (found.get("sources") or [found.get("source")]):
        det = _read(ap_dir / "rounds" / str(r_found) / "detect.json", {}) or {}
        st = evm.EvidenceStore.load(ap_dir / "rounds" / str(r_found) / "evidence.json")
        pre = _read(ap_dir / "rounds" / str(r_found) / "prefilter.json", {}) or {}
        spec = _read(store.spec_path, {}) or {}
        user = detector_message(goal, spec, (_read(ap_dir / "state.json", {}) or {}).get("current") or {},
                                pre.get("candidates") or [], st, declared=pre.get("declared"),
                                rejected=rej, previous=det.get("anomalies"),
                                correction=f"About [{found['id']}] {found['title']}: {note}")
        obj, res = llm.complete_json(ROLE, user, session_id=slug, required=["anomalies"], max_tokens=5000)
        parsed = parse_anomalies(obj, st.refs(), files=list(gapmod.game_sources(store.game_dir)),
                                 rejected={x["id"] for x in rej})
        k = len(list((ap_dir / "corrections").glob("*.json"))) + 1
        _write(ap_dir / "corrections" / f"{k}.json", {**rec, "request_id": res.request_id, **parsed})
        rec.update(role=ROLE, request_id=res.request_id, after=[a["id"] for a in parsed["anomalies"]])
    if "gap_finder" in (found.get("sources") or [found.get("source")]) and found.get("gap"):
        g = gapmod.correct_gaps(settings, slug, note, llm=llm, goal=goal, reject=[found["gap"]])
        rec.setdefault("role", gapmod.ROLE)
        rec.update(gap_request_id=g.get("request_id"), gaps_after=[x["id"] for x in g["gaps"]])
        rec.setdefault("request_id", g.get("request_id"))
    _append(ap_dir / "corrections.jsonl", rec)
    return rec


# ---------------------------------------------------------------- advisory mode (read-only)


def default_name(settings: Settings, root: Path) -> str:
    root = Path(root).resolve()
    if root == Path(settings.base_game_dir).resolve():
        seeds = sorted((Path(__file__).parent / "seeds").glob("*.json"))
        return seeds[0].stem if seeds else "game"
    return root.parent.name if root.name == "game" else root.name


def evidence_dirs(settings: Settings, name: str, extra: list[Path] | None = None) -> list[Path]:
    out = []
    for base in (settings.repo_root / "evidence", settings.runs_dir):
        if base.is_dir():
            out += sorted(p for p in base.iterdir() if p.is_dir() and p.name.startswith(name))
    return out + [Path(p) for p in extra or [] if Path(p).is_dir()]


STATIC_KINDS = ("code", "genre")             # code-scan facts: current by construction, never "broken" proof
ABSENCE_KINDS = ("untouched",)              # "never moved": absence, not proof that something is broken
LIVE_SOURCE = "fresh session"
OLD_WEIGHT = 0.3                            # an unreproduced claim from an older build
STATIC_WEIGHT = 0.8                         # a missing-feature claim backed only by the code scan
FRESHNESS_NOTE = ("Evidence marked (old: game <version>, N commits ago) was recorded on an older build of the game. "
                  "Many of those problems may be fixed. Weigh old evidence low unless the fresh session or a "
                  "current probe shows the same thing. Tester-harness limits (prompts the harness could not press, "
                  "pathfinding NoPath) are not in the evidence: they are not game bugs.")


def _git_ts(path: Path) -> float | None:
    """Commit time of the last commit touching `path` (None outside git)."""
    try:
        out = subprocess.run(["git", "log", "-1", "--format=%ct", "--", path.name], cwd=path.parent,
                             capture_output=True, text=True, check=True).stdout.strip()
        return float(out) if out else None
    except (OSError, ValueError, subprocess.CalledProcessError):
        return None


def harness_list(st: evm.EvidenceStore) -> list[dict]:
    """Tooling items grouped by what the tester harness could not do (goes to the harness fix list)."""
    groups: dict[str, list[evm.Item]] = {}
    for it in st.of_kind("tooling"):
        low = it.text.lower()
        key = ("ProximityPrompt hold/press never triggers from the harness" if "trigger" in low else
               "Pathfinding / navmesh: the harness can't path (NoPath)" if ("path" in low or "navmesh" in low) else
               "other harness limit")
        groups.setdefault(key, []).append(it)
    return [{"title": k, "count": len(v), "ids": [i.id for i in v][:8], "example": v[0].text,
             "stale": sum(1 for i in v if i.data.get("stale"))} for k, v in sorted(groups.items(), key=lambda kv: -len(kv[1]))]


SHORT_PROBE_S = 60  # a live probe shorter than this can't prove a counter regression vs full-round history


def classify(c: dict, st: evm.EvidenceStore, live: set[str], weak: set[str] | None = None) -> dict:
    """A ranked candidate's freshness: verified now (a live re-check, or evidence recorded on the current
    build), static
    (code scan only: a missing part, not a broken one), unverified (old), or tooling (harness limits only)."""
    refs = [r for r in c.get("evidence") or [] if r in st.items]
    kinds = {r: "untouched" if r.startswith("stat:untouched") or r in (weak or set()) else st.items[r].kind
             for r in refs}  # absence and weak leads never verify a claim on their own
    if refs and all(k == "tooling" for k in kinds.values()):
        status, w = "tooling", 0.0
    elif any((r in live or not st.items[r].data.get("stale")) and kinds[r] not in STATIC_KINDS + ABSENCE_KINDS
             for r in refs):
        status, w = "verified now", 1.0  # a live re-check, or a record made on the current build
    elif refs and all(k in STATIC_KINDS + ABSENCE_KINDS for k in kinds.values()):
        status, w = "static", STATIC_WEIGHT  # missing in code, or never exercised: nothing broken to reproduce
    else:
        status, w = "unverified (old)", OLD_WEIGHT
    old = sorted({st.items[r].data.get("version") for r in refs if st.items[r].data.get("stale")} - {None})
    return {**c, "status": status, "score_raw": c["score"], "score": round(c["score"] * w, 2), "old_versions": old}


async def fresh_session(settings: Settings, root: Path, place: str, *, slug: str, focus: str, llm: Any,
                        out_dir: Path, qa_steps: int = 4, swarm_players: int = 2, swarm_minutes: float = 1.0,
                        log: Callable[[str], None] = print) -> dict:
    """A short live session on the CURRENT build of `root` in our own Studio window: a probe playtest
    (errors, counters, census, screenshot), a focused QA run and a short swarm. Opens the place built from
    `root` (never syncs into a shared place) and closes it at the end. Nothing is written under `root`."""
    from forge import fun
    from forge.broker import StudioSlots
    from forge.orchestrator import StudioKeeper
    from forge.studio import Studio

    slots = StudioSlots()

    def opener(p: str) -> None:
        out = settings.repo_root / "place" / f"{p}.rbxlx"
        out.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([sys.executable, str(settings.base_game_dir / "tools" / "make_place.py"), "--root", str(root),
                        "--out", str(out)], check=True, capture_output=True)
        subprocess.run(["open", "-a", "/Applications/RobloxStudio.app", str(out)], check=False)

    keeper = StudioKeeper(settings, slug, slots, log, opener=opener)
    # testers read the game's spec from <game_dir>/../spec.json: give them runs/<slug>/{spec.json, game -> root}
    # (a symlink: nothing is copied or written into root)
    run_dir = settings.runs_dir / slug
    run_dir.mkdir(parents=True, exist_ok=True)
    spec = _read(Path(__file__).parent / "seeds" / f"{slug.removeprefix('advise-')}.json", {}) or {}
    if spec:
        _write(run_dir / "spec.json", spec)
    link = run_dir / "game"
    if not link.exists():
        link.symlink_to(Path(root).resolve(), target_is_directory=True)
    deadline = time.monotonic() + 1800
    while not (slots.held_by(place) or slots.try_acquire(place)):
        if time.monotonic() > deadline:
            raise RuntimeError("no free Studio slot in 30 min")
        await asyncio.sleep(10)
    out: dict = {"t0": time.time(), "runs": []}
    try:
        sid = await asyncio.to_thread(keeper.prepare, place)
        if not sid:
            raise RuntimeError(f"Studio {place} did not connect")
        gsettings = dataclasses.replace(settings, base_game_dir=link)
        async with Studio(settings, studio_id=sid) as st:
            await st.select(sid)
            try:
                await st.play()
                round_started = False
                pt = spec.get("playtest") or {}
                if pt.get("start_round"):  # measure a live round like the build loop does, not the lobby
                    from forge.loop import START_ROUND_DELAY
                    from mubit_tester.harness import build_call_luau
                    await asyncio.sleep(START_ROUND_DELAY)
                    args = {"state": "Active", **({"seconds": int(pt["round_seconds"])} if pt.get("round_seconds") else {})}
                    res = await st.execute_luau(build_call_luau("round", args), "Server")
                    round_started = "error" not in str(res).lower()
                    log(f"fresh probe: start round -> {_clip(res, 120)}")
                observed = 25 if round_started else 8
                await asyncio.sleep(observed)
                probe = await st.probe_report()
                try:
                    probe["census"] = await fun.census(st)
                except Exception:  # noqa: BLE001
                    pass
                shot = await st.screenshot(out_dir / "fresh-screenshot.png")
                out["probe"] = evm.measurement_from_probe(probe, label="now", studio=True,
                                                          screenshot=str(shot) if shot else None,
                                                          round_started=round_started, observed_s=observed,
                                                          comparable=round_started or not pt.get("start_round"))
            finally:
                await _safe_stop(st)
            if qa_steps:
                try:
                    from mubit_tester.protocol import qa_test
                    qa = await qa_test(gsettings, focus, game_dir=link, slug=slug, max_steps=qa_steps, llm=llm,
                                       studio=st, max_investigations=1, key_images=2)
                    out["qa"] = {k: qa.get(k) for k in ("run_id", "goal_met", "test_dir", "summary")}
                    out["qa"]["bugs"] = [b.get("title") for b in qa.get("bugs") or []]
                    out["runs"].append(qa.get("run_id"))
                except Exception as e:  # noqa: BLE001
                    log(f"fresh QA failed: {type(e).__name__}: {_clip(e, 160)}")
                await _safe_stop(st)
            if swarm_players:
                try:
                    from mubit_tester.swarm import run_swarm
                    sw = await run_swarm(gsettings, players=swarm_players, minutes=swarm_minutes, llm=llm, studio=st,
                                         slug=slug, goal=focus, max_steps=10)
                    out["swarm"] = {"run_id": sw.get("run_id"), "summary": sw.get("summary"),
                                    "bugs": [b.get("title") for b in sw.get("bugs") or []]}
                    out["runs"].append(sw.get("run_id"))
                except Exception as e:  # noqa: BLE001
                    log(f"fresh swarm failed: {type(e).__name__}: {_clip(e, 160)}")
                await _safe_stop(st)
    finally:
        keeper.opened.add(place)
        keeper.release(place)  # closes our window, frees the slot
    return out


def advise(settings: Settings, root: Path, *, llm: Any = None, name: str | None = None, goal: str = "",
           extra_dirs: list[Path] | None = None, out_dir: Path | None = None, fresh: dict | None = None,
           fresh_place: str | None = None, qa_steps: int = 4, swarm_players: int = 2,
           swarm_minutes: float = 1.0) -> dict:
    """Read-only advisory pass on a human-built game -> ranked improvements + anomalies (one anomaly_detector
    call, one gap_finder call), never writing under `root`.

    Version-aware: every item carries the game version (git commit touching `root`) it was recorded on;
    older items are marked old and weighted down. `fresh_place` runs a short live session (probe, focused QA
    on the old claims, short swarm) on the current build first; old claims it reproduces count as current.
    Harness failures (prompts the tester couldn't press, NoPath) are `tooling`: kept out of the LLM evidence
    and listed as a tester-harness fix list. A ranked claim is "verified now" only with live evidence."""
    root = Path(root)
    name = name or default_name(settings, root)
    out_dir = out_dir or settings.runs_dir / "autopilot-advise" / name / time.strftime("%Y%m%d-%H%M%S")
    out_dir.mkdir(parents=True, exist_ok=True)
    llm = llm or llm_mod.make_llm(settings, log_path=out_dir / "calls.jsonl")
    dirs = evidence_dirs(settings, name, extra_dirs)
    gv = evm.GameVersions(root)
    st = evm.EvidenceStore()
    hist: list[dict] = []
    stuck: list[dict] = []
    spec: dict = _read(Path(__file__).parent / "seeds" / f"{name}.json", {}) or {}
    for d in dirs:
        spec = spec or _read(d / "spec.json", {}) or {}
        h = evm.history(d)
        for m in h:
            m["label"] = f"{d.name}:{m['label']}"
        hist += h
        stuck += evm.add_tests(st, d, limit=8)
        if (d / "playtests").is_dir():
            for p in sorted((d / "playtests").glob("*/report.json"), key=lambda p: p.parent.name, reverse=True)[:10]:
                rep = _read(p, {}) or {}
                rid = p.parent.name
                ts = evm.parse_ts(rep.get("started"))
                st.add(f"test:{rid}", "test", d.name, f"{rep.get('kind')} \"{_clip(rep.get('goal'), 90)}\": "
                       f"goal_met={rep.get('goal_met')}, {len(rep.get('steps') or [])} steps. "
                       f"{_clip(rep.get('summary'), 200)}", ts=ts)
                for i, b in enumerate((rep.get("bugs") or rep.get("bug_hints") or [])[:4], 1):
                    if isinstance(b, dict):
                        text = f"[{b.get('severity', '?')}] {_clip(b.get('title'), 120)}: {_clip(b.get('evidence'), 160)}"
                        st.add(f"test:{rid}#bug{i}", "tooling" if evm.is_tooling(text) else "bug", d.name, text, ts=ts)
                for sp in evm.stuck_spans(rep.get("steps") or []):
                    tool = evm.is_tooling(sp["result"])
                    if not tool:
                        stuck.append({**sp, "run": rid})
                    st.add(f"stuck:{rid}@{sp['from']}", "tooling" if tool else "stuck", d.name,
                           f"{sp['tester']} stuck {sp['steps']} steps doing {sp['action']} near {sp['pos']}: "
                           f"{sp['result']}", ts=ts)
        for p in sorted((d / "improve").glob("[0-9]*.json"), key=lambda p: int(p.stem))[-3:] if (d / "improve").is_dir() else []:
            cyc = _read(p, {}) or {}
            ts = evm.parse_ts(cyc.get("ts"))
            for i, a in enumerate(((cyc.get("audit") or {}).get("anomalies") or [])[:6], 1):
                if isinstance(a, dict):
                    text = f"[{a.get('severity')}] {a.get('system')}: {_clip(a.get('title'), 110)}: {_clip(a.get('observed'), 160)}"
                    st.add(f"cycle:{d.name}:{p.stem}#a{i}", "tooling" if evm.is_tooling(text) else "audit", d.name,
                           text, ts=ts)
            for i, fx in enumerate((cyc.get("code_fixes") or [])[:4], 1):
                st.add(f"cycle:{d.name}:{p.stem}#f{i}", "fix", d.name, f"fix {fx.get('status')} {fx.get('path')}: "
                       f"{_clip(fx.get('anomaly'), 140)}", ts=ts)
        for i, rp in enumerate(_lines(d / "improve" / "reports.jsonl")[-4:], 1):
            st.add(f"report:{d.name}#{i}", "report", d.name, f"{rp.get('reporter') or 'tester'}: {_clip(rp.get('text'), 260)}",
                   ts=evm.parse_ts(rp.get("ts")))
        evm.add_calls(st, d)
    for p in sorted((settings.repo_root / "games" / name / "reports").glob("*.md")):
        if "autopilot" in p.name:  # our own earlier advice is not evidence
            continue
        ts = _git_ts(p)  # a run report describes the build it was written about
        for i, ln in enumerate(ln.strip() for ln in p.read_text(encoding="utf-8").splitlines()):
            if re.match(r"^(-|\d+\.|\|)", ln) and len(ln) > 12 and not set(ln) <= set("|-: "):
                text = _clip(ln.lstrip("-|0123456789. "), 260)
                st.add(f"report:{p.stem}#{i}", "tooling" if evm.is_tooling(text) else "report", "games/reports", text,
                       ts=ts)
    for m in hist:
        evm.add_measurement(st, m, source="history")

    # the live re-check on the current build
    old_claims = [it for it in st.of_kind("bug", "audit", "report") if it.data.get("ts") is not None]
    focus = "Re-check on the current build whether these older reports still happen: " + "; ".join(
        dict.fromkeys(_clip(re.sub(r"^\[[^\]]*\]\s*", "", it.text).split(":")[0], 70) for it in old_claims[:12])) \
        if old_claims else (goal or "the core loop and the first 5 minutes")
    if fresh is None and fresh_place:
        fresh = asyncio.run(fresh_session(settings, root, fresh_place, slug=f"advise-{name}", focus=focus[:900],
                                          llm=llm, out_dir=out_dir, qa_steps=qa_steps, swarm_players=swarm_players,
                                          swarm_minutes=swarm_minutes))
    live: set[str] = set()
    current = hist[-1] if hist else {"label": "source", "counters": {}, "errors": []}
    previous = hist[-2] if len(hist) > 1 else None
    if fresh:
        before = set(st.items)
        if fresh.get("probe"):
            evm.add_measurement(st, fresh["probe"], source=LIVE_SOURCE)
            # compare with history only like for like (a lobby probe vs playtests that ran a round says nothing)
            current = fresh["probe"]
            previous = (hist[-1] if hist else None) if fresh["probe"].get("comparable", True) else None
        t0 = float(fresh.get("t0") or 0) - 5
        evm.add_tests(st, settings.runs_dir / f"advise-{name}", since=t0, limit=8)
        evm.add_swarm(st, settings.runs_dir / "playtests", f"advise-{name}", since=t0)
        live = {i.id for i in st.items.values() if i.id not in before or LIVE_SOURCE in (i.data.get("also") or [])
                or i.source == LIVE_SOURCE}
        fresh_texts = [st.items[i].text for i in live if st.items[i].kind in ("bug", "error", "stuck", "qa", "test")]
        for it in old_claims:  # an older claim the fresh session saw again is current
            if it.id not in live and any(similar(it.text, t) >= 0.35 for t in fresh_texts):
                it.data["reproduced"] = True
                live.add(it.id)
    sources = gapmod.game_sources(root)
    declared = evm.declared_counters(sources, spec)
    seen_any = {k for m in hist + ([current] if fresh else []) for k, v in (m.get("counters") or {}).items()
                if float(v or 0) > 0}
    hist_ts = max((float(m.get("ts") or 0) for m in hist), default=None)
    for k in declared:
        if k not in seen_any and (hist or fresh):
            ref = st.add(f"untouched:{k}", "untouched", "telemetry", f"counter {k} is bumped in code but never moved in "
                         f"{len(hist)} recorded playtests" + (" or the fresh session" if fresh else ""),
                         ts=None if fresh else hist_ts)
            if fresh:
                live.add(ref)
    cands = evm.prefilter(current, previous, st, declared=[k for k in declared if k not in seen_any], stuck=stuck)
    evm.metric_items(st, list(dict.fromkeys(["errors"] + [e[len("metric:"):] for c in cands for e in c["evidence"]
                                                          if e.startswith("metric:")])))
    for c in cands:  # with a fresh session the pre-filter compares the current build: its findings are live
        ref = st.add(c["id"], "stat", "prefilter", c["text"], ts=None if fresh else hist_ts)
        if fresh:
            live.add(ref)
    genre = gapmod.detect_genre(spec, goal)
    for item in gapmod.scan_checklist(genre, sources):
        st.add(f"genre:{item['id']}", "genre", "code scan", f"{item['label']}: " + (
            f"mentioned in {', '.join(item['files'])}" if item["present"] else "not found in code"))
    for path, text in list(sources.items())[:60]:
        st.add(f"code:{path}", "code", "source", f"{text.count(chr(10)) + 1} lines")
    for i in live:
        if i in st.items:
            st.items[i].data["live"] = True
    versions = evm.tag_versions(st, gv)

    # the LLMs see game evidence only (no harness limits), old items marked
    seen = evm.EvidenceStore()
    seen.items = {k: v for k, v in st.items.items() if v.kind != "tooling"}
    seen.series = st.series
    note_goal = (goal or "Make this game genuinely good for real players.") + "\n\n" + FRESHNESS_NOTE
    files = list(sources)
    sid = f"advise-{name}"
    try:
        obj, res = llm.complete_json(ROLE, detector_message(note_goal, spec, current, cands, seen, declared=declared),
                                     session_id=sid, required=["anomalies"], max_tokens=5000)
        det = parse_anomalies(obj, seen.refs(), files=files)
        det["request_id"] = res.request_id
    except Exception as e:  # noqa: BLE001
        det = {"summary": f"detector failed: {e}", "anomalies": from_prefilter(cands), "noise": [], "request_id": None}
    ev = gapmod.Evidence()
    for kind in ("stat", "error", "bug", "stuck", "qa", "test", "swarm", "audit", "untouched", "report", "fix", "metric",
                 "physics", "census", "calls", "genre", "code"):
        rows = ev.section(kind)
        for it in seen.of_kind(kind):
            old = f"(old: game {it.data.get('version')}, {it.data.get('behind')} commits ago) " if it.data.get("stale") else ""
            ev.add(rows, it.id, old + it.text)
    gmsg = gapmod.gap_message({"spec": spec, "evidence": ev}, note_goal)
    try:
        gobj, gres = llm.complete_json(gapmod.ROLE, gmsg, session_id=sid, required=["gaps"], max_tokens=6000)
        gp = gapmod.parse_gaps(gobj, ev.refs, files=files)
        gp["request_id"] = gres.request_id
    except Exception as e:  # noqa: BLE001
        gp = {"summary": f"gap finder failed: {e}", "score": None, "gaps": [], "request_id": None}
    for a in det["anomalies"]:
        a["request_id"] = det.get("request_id")
    for g in gp["gaps"]:
        g["request_id"] = gp.get("request_id")
    weak = set()
    if fresh and float((fresh.get("probe") or {}).get("observed_s") or SHORT_PROBE_S) < SHORT_PROBE_S:
        weak = {c["id"] for c in cands if c["kind"] in ("regression", "drop")}
    ranked = [classify(c, st, live, weak) for c in candidates(det["anomalies"], gp["gaps"])]
    order = {"verified now": 0, "static": 1, "unverified (old)": 2, "tooling": 3}
    ranked.sort(key=lambda c: (order[c["status"]], -c["score"]))
    harness = harness_list(st)
    for c in [c for c in ranked if c["status"] == "tooling"]:
        harness.append({"title": c["title"], "count": len(c["evidence"]), "ids": c["evidence"][:8],
                        "example": _clip(c["job"]["request"], 200), "stale": None})
    calls = sum(1 for _ in (out_dir / "calls.jsonl").open()) if (out_dir / "calls.jsonl").exists() else None
    rep = {"name": name, "root": str(root), "ts": now_iso(), "mode": "advise (read-only)", "sources": [str(d) for d in dirs],
           "evidence": st.counts(), "evidence_items": len(st.items), "history_points": len(hist), "versions": versions,
           "live_items": len(live & set(st.items)), "fresh": {k: v for k, v in (fresh or {}).items() if k != "probe"},
           "fresh_probe": _brief(fresh.get("probe")) if fresh and fresh.get("probe") else None, "focus": focus,
           "prefilter": cands, "anomalies": det, "gaps": gp, "ranked": [c for c in ranked if c["status"] != "tooling"],
           "harness": harness, "mubit_calls": calls, "out_dir": str(out_dir)}
    st.save(out_dir / "evidence.json")
    _write(out_dir / "report.json", rep)
    (out_dir / "report.md").write_text(render_advice(rep), encoding="utf-8")
    return rep


def render_advice(rep: dict) -> str:
    det, gp = rep["anomalies"], rep["gaps"]
    v = rep.get("versions") or {}
    fr = rep.get("fresh") or {}
    L = [f"# Autopilot advice: {rep['name']} (read-only)", "",
         f"{rep['ts']} · root `{rep['root']}` at game version `{v.get('current')}` · {rep['evidence_items']} evidence "
         f"items ({v.get('stale', 0)} from older builds, {rep.get('live_items', 0)} live on this build) from "
         f"{len(rep['sources'])} record folders + the human run reports + the source"
         + (f" + a fresh session (QA `{(fr.get('qa') or {}).get('run_id')}`, swarm `{(fr.get('swarm') or {}).get('run_id')}`)"
            if fr else " (no fresh session: every runtime claim is unverified)")
         + f" · {rep.get('mubit_calls')} Mubit calls. No game file was changed.", "",
         "Evidence: " + ", ".join(f"{k} {n}" for k, n in rep["evidence"].items()), ""]
    if rep.get("fresh_probe"):
        fp = rep["fresh_probe"]
        L += [f"Fresh probe on `{v.get('current')}`"
              + (" (a round started through the test harness)" if fp.get("round_started") else " (lobby)")
              + (f", watched {fp['observed_s']} s: older playtests ran longer, so rate counters (fires, spreads, "
                 "flare-ups) read low; treat their regressions as leads to confirm" if fp.get("observed_s") else "")
              + f": {fp.get('errors')} runtime errors, {fp.get('physics')} physics flags. "
              f"Screenshot: `{fp.get('screenshot')}`.", ""]
    for status, head in (("verified now", "Verified on the current build"),
                         ("static", "Missing or never exercised (code scan / counters that never moved)"),
                         ("unverified (old)", "Unverified (old): from older builds, not reproduced by the fresh session")):
        rows = [c for c in rep["ranked"] if c["status"] == status]
        L += [f"## {head} ({len(rows)})", ""]
        if not rows:
            L += ["None.", ""]
            continue
        L += ["| # | score | from | kind | improvement | evidence |", "|---|---|---|---|---|---|"]
        for i, c in enumerate(rows[:12], 1):
            old = f" (old builds: {', '.join(c['old_versions'][:3])})" if c.get("old_versions") else ""
            L.append(f"| {i} | {c['score']:g} (raw {c['score_raw']:g}) | {' + '.join(s.replace('_', ' ') for s in c['sources'])} "
                     f"| {c['kind']} | **{c['title']}**: {_clip(c['job']['request'], 240)} | "
                     f"{', '.join(c['evidence'][:4])}{old} |")
        L.append("")
    L += ["## Tester-harness fix list (tooling, not game bugs)", ""]
    for h in rep.get("harness") or []:
        L.append(f"- **{h['title']}**: {h['count']} sightings"
                 + (f" ({h['stale']} on older builds)" if h.get("stale") else "")
                 + f", e.g. {_clip(h['example'], 180)} ({', '.join(h['ids'][:4])})")
    if not rep.get("harness"):
        L.append("None.")
    L += ["", "## Anomaly detector summary", "", det.get("summary") or "", "",
          "## Gap finder summary", "", gp.get("summary") or "", "", "## Statistical pre-filter (no LLM)", ""]
    for c in rep["prefilter"]:
        L.append(f"- `{c['id']}` {c['severity']}: {c['text']}")
    if rep.get("focus"):
        L += ["", f"Fresh QA focus: {_clip(rep['focus'], 600)}"]
    L += ["", f"Mubit request ids: anomaly_detector `{det.get('request_id')}`, gap_finder `{gp.get('request_id')}`"]
    return "\n".join(L) + "\n"


def render_rounds(rounds: list[dict]) -> str:
    L = ["| round | evidence | anomalies | gaps | jobs (picked) | verdict | critic | fun | errors |",
         "|---|---|---|---|---|---|---|---|---|"]
    for r in rounds:
        b, a = (r.get("scores") or {}).get("before") or {}, (r.get("scores") or {}).get("after") or {}
        picked = [d for d in r.get("decisions") or [] if d.get("picked")]

        def arrow(k: str) -> str:
            return f"{b.get(k)} -> {a.get(k)}" if a else f"{b.get(k)}"
        L.append(f"| {r['round']} | {r.get('evidence_items')} | {len(r.get('anomalies') or [])} | "
                 f"{len(r.get('gaps') or [])} | {len(picked)}: " + "; ".join(_clip(d['title'], 40) for d in picked)
                 + f" | {r.get('verdict')} | {arrow('critic')} | {arrow('fun')} | {arrow('errors')} |")
    return "\n".join(L)
