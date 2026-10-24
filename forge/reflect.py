"""`forge reflect <slug>`: after each build, fix cycle and orchestrate round, a reflection on what Forge did.

A reflection covers everything since the previous one (the first covers the whole run) and is read from the
records every command already writes. It makes no Mubit call unless --llm is given:
    calls.jsonl       every Mubit call: role, tokens, latency, errors      (anywhere under runs/<slug>/)
    skipped.jsonl     calls that were not needed: reply-cache hits, JSON repairs parsed locally (forge/llm.py)
    traces/*.json     each call's user message: JSON repair calls and fixer retries
    improve/<n>.json  fix cycles: anomalies, investigations, reproductions, attempts, kept or rolled back
    state.json, iterations/<n>/record.json   build iterations: scores, fixes, rollbacks, failed steps
    timings.json      stage wall times of the last forge new / run / feature (and orchestrator/timings.json)
    features.jsonl    features built (forge feature)
Out: runs/<slug>/reflection/<n>.md for people, one line per reflection in runs/<slug>/reflection/reflection.jsonl
for tools. `forge reflect --all` sums every game into runs/reflection.md. With --llm the findings go to the
`reflector` (its fixed system prompt, the findings in the user message: the same Mubit task as every lessons
update), which rewrites runs/lessons.md.
"""

from __future__ import annotations

import json
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from forge.config import Settings
from forge.llm import SKIPPED_LOG

DIR = "reflection"
LOG = "reflection.jsonl"
REPAIR_MARK = "## Your previous reply could not be used"
RETRY_MARK = "## Your previous fix was rejected"
RUN_TOKENS = 8000  # Mubit's run size: calls above it are harder to train on (docs/ARCHITECTURE.md, rule 3)
INVESTIGATE_STEPS = 8  # forge.improve.INVESTIGATE_STEPS (not imported: improve pulls in the whole harness)
STAGES = {
    "design": ("director", "designer", "planner"),
    "build": ("coder",),
    "critique": ("critic", "fun_critic"),
    "playtest": ("player", "judge", "explorer", "test_planner", "step_judge", "visual_judge", "swarm_tester",
                 "swarm_triage"),
    "audit": ("auditor", "triage", "gap_finder"),
    "investigate": ("investigator",),
    "checks": ("scenarist", "check_reviewer", "reproducer"),
    "fix": ("fixer", "patcher"),
    "verify": ("verifier",),
    "reflect": ("reflector",),
}
STAGE_OF = {role: stage for stage, roles in STAGES.items() for role in roles}
NOT_GAMES = {"bench", "jobs", "playtests", "studio-plugin"}


# ---------------------------------------------------------------- reading the records


def _read(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _lines(path: Path) -> list[dict]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    out = []
    for ln in text.splitlines():
        try:
            rec = json.loads(ln) if ln.strip() else None
        except ValueError:
            continue
        if isinstance(rec, dict):
            out.append(rec)
    return out


def _epoch(ts: Any) -> float | None:
    try:
        return datetime.fromisoformat(str(ts).replace("Z", "+00:00")).timestamp() if ts else None
    except ValueError:
        return None


def _iso(t: float | None) -> str | None:
    return datetime.fromtimestamp(t, timezone.utc).isoformat(timespec="seconds") if t is not None else None


def collect(settings: Settings, slug: str, since: float | None = None, until: float | None = None) -> dict:
    """Every record of a game with a timestamp in [since, until]; None means open-ended. Records carry whole
    seconds, so the second `since` falls in counts again (a record written just after the previous reflection
    must not be lost). A record without a timestamp only counts when the window is the whole run."""
    run = settings.runs_dir / slug

    def win(ts: Any) -> bool:
        t = _epoch(ts)
        if t is None:
            return since is None
        return (since is None or t >= int(since)) and (until is None or t <= until)

    marks: dict[str, Counter] = defaultdict(Counter)
    for p in run.glob("**/traces/*.json"):
        t = _read(p)
        if isinstance(t, dict) and win(t.get("ts")):
            user = str(t.get("user") or "")
            m = marks[str(t.get("role"))]
            m["traced"] += 1
            m["repairs"] += REPAIR_MARK in user
            m["retries"] += RETRY_MARK in user and REPAIR_MARK not in user  # a repair re-sends the retry
    cycle_paths = sorted((run / "improve").glob("[0-9]*.json"), key=lambda p: int(p.stem))
    state = _read(run / "state.json") or {}
    iterations = []
    for it in state.get("iterations") or []:
        if win(it.get("ended")):
            rec = _read(run / "iterations" / str(it.get("n")) / "record.json") or {}
            iterations.append({**it, "steps": rec.get("steps") or []})
    return {
        "slug": slug,
        "calls": [c for p in sorted(run.glob("**/calls.jsonl")) for c in _lines(p) if win(c.get("ts"))],
        "skipped": [s for p in sorted(run.glob(f"**/{SKIPPED_LOG}")) for s in _lines(p) if win(s.get("ts"))],
        "marks": dict(marks),
        "cycles": [c for c in map(_read, cycle_paths) if isinstance(c, dict) and win(c.get("ts"))],
        "iterations": iterations,
        "corrections": [c for c in state.get("corrections") or [] if win(c.get("ts"))],
        "features": [f for f in _lines(run / "features.jsonl") if win(f.get("ts"))],
        "timings": [t for t in (_read(run / "timings.json"), _read(run / "orchestrator" / "timings.json"))
                    if isinstance(t, dict) and win(t.get("started"))],
    }


# ---------------------------------------------------------------- numbers


def _role_rows(data: dict) -> dict[str, dict]:
    rows: dict[str, dict] = {}

    def row(role: str) -> dict:
        return rows.setdefault(role, {"calls": 0, "input_tokens": 0, "output_tokens": 0, "latency_s": 0.0,
                                      "errors": 0, "aborted": 0, "over_run_size": 0, "repairs": 0, "retries": 0,
                                      "cache_hits": 0, "repairs_avoided": 0, "saved_input_tokens": 0})

    for c in data["calls"]:
        r = row(str(c.get("role")))
        tin = int(c.get("input_tokens") or 0)
        r["calls"] += 1
        r["input_tokens"] += tin
        r["output_tokens"] += int(c.get("output_tokens") or 0)
        r["latency_s"] = round(r["latency_s"] + int(c.get("latency_ms") or 0) / 1000, 1)
        r["errors"] += bool(c.get("error"))
        r["aborted"] += bool(c.get("aborted"))
        r["over_run_size"] += tin > RUN_TOKENS
    for role, m in data["marks"].items():
        row(role).update(repairs=m["repairs"], retries=m["retries"])
    for s in data["skipped"]:
        r = row(str(s.get("role")))
        r["cache_hits" if s.get("kind") == "cache_hit" else "repairs_avoided"] += 1
        r["saved_input_tokens"] += int(s.get("input_tokens") or 0)
    return dict(sorted(rows.items(), key=lambda kv: (-kv[1]["input_tokens"], kv[0])))


def _stage_rows(roles: dict[str, dict]) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for role, r in roles.items():
        s = out.setdefault(STAGE_OF.get(role, "other"), {"calls": 0, "input_tokens": 0, "latency_s": 0.0})
        s["calls"] += r["calls"]
        s["input_tokens"] += r["input_tokens"]
        s["latency_s"] = round(s["latency_s"] + r["latency_s"], 1)
    total = sum(s["latency_s"] for s in out.values()) or 1.0
    for s in out.values():
        s["share"] = round(s["latency_s"] / total, 3)
    return dict(sorted(out.items(), key=lambda kv: -kv[1]["latency_s"]))


def _setup_error(r: dict) -> bool:
    return "setup:" in str(r.get("error") or "") or "setup:" in str(r.get("detail") or "")


def _fixes(data: dict) -> list[dict]:
    out = []
    for c in data["cycles"]:
        for fx in c.get("code_fixes") or []:
            inv = fx.get("investigation") or {}
            out.append({"cycle": c.get("cycle"), "anomaly": str(fx.get("anomaly") or ""), "path": fx.get("path"),
                        "status": fx.get("status"),
                        "attempts": [a for a in fx.get("attempts") or [] if isinstance(a, dict)],
                        "investigation_steps": len(inv.get("steps") or []) if inv else None,
                        "concluded": bool(inv.get("conclusion")) if inv else None,
                        "repro": [a.get("status") for a in (fx.get("repro") or {}).get("attempts") or []]})
    return out


def failures(data: dict) -> Counter:
    """Why things did not work, by cause: fix outcomes and every rejected attempt, reproducer outcomes,
    checks that failed in setup, failed Mubit calls and failed loop steps."""
    out: Counter = Counter()
    for fx in _fixes(data):
        if fx["status"] in ("unproven", "no_file", "compile_failed", "no_fix_needed"):
            out[fx["status"]] += 1
        for a in fx["attempts"]:
            if a.get("status") not in ("fixed", None):
                out[a["status"]] += 1
        for status in fx["repro"]:
            if status != "proven":
                out[f"reproducer_{status}"] += 1
    for c in data["cycles"]:
        ck = c.get("checks") or {}
        out["setup_error"] += sum(1 for r in (ck.get("start") or []) + (ck.get("end") or [])
                                  if isinstance(r, dict) and not r.get("ok") and _setup_error(r))
    for call in data["calls"]:
        if call.get("error"):
            err = str(call["error"]).lower()
            out["mubit_rate_limit" if "429" in err or "rate" in err else
                "mubit_overloaded" if "overloaded" in err or "529" in err else "mubit_error"] += 1
    for it in data["iterations"]:
        for s in it.get("steps") or []:
            if not s.get("ok"):
                out[f"step_{str(s.get('step', '?')).split(':')[0]}"] += 1
    return Counter({k: v for k, v in out.items() if v})


def summarize(data: dict) -> dict:
    roles = _role_rows(data)
    fixes = _fixes(data)
    statuses = Counter(str(f["status"]) for f in fixes)
    return {
        "calls": sum(r["calls"] for r in roles.values()),
        "input_tokens": sum(r["input_tokens"] for r in roles.values()),
        "output_tokens": sum(r["output_tokens"] for r in roles.values()),
        "latency_s": round(sum(r["latency_s"] for r in roles.values()), 1),
        "errors": sum(r["errors"] for r in roles.values()),
        "cache_hits": sum(r["cache_hits"] for r in roles.values()),
        "repairs_avoided": sum(r["repairs_avoided"] for r in roles.values()),
        "saved_input_tokens": sum(r["saved_input_tokens"] for r in roles.values()),
        "by_role": roles,
        "by_stage": _stage_rows(roles),
        "wall_stages": [{"command": t.get("command"), "name": s.get("name"), "secs": s.get("secs")}
                        for t in data["timings"] for s in t.get("stages") or [] if s.get("secs") is not None],
        "fixes": fixes,
        "kept": statuses.get("kept", 0),
        "rolled_back": statuses.get("rolled_back", 0),
        "unproven": statuses.get("unproven", 0),
        "failures": dict(failures(data).most_common()),
    }


# ---------------------------------------------------------------- weaknesses (heuristics over the records)


def _w(wid: str, finding: str, evidence: str, fix: str, waste: int = 0) -> dict:
    return {"id": wid, "finding": finding, "evidence": evidence, "fix": fix, "wasted_calls": waste}


def _repair_weaknesses(summary: dict) -> list[dict]:
    out = []
    for role, r in summary["by_role"].items():
        if r["repairs"] >= 3 and r["repairs"] >= 0.15 * r["calls"]:
            out.append(_w("json_repairs", f"{role}: {r['repairs']} of {r['calls']} calls were JSON repair calls",
                          f"{r['repairs']} traced calls carry '{REPAIR_MARK}'"
                          + (f"; {r['repairs_avoided']} more replies were parsed locally" if r["repairs_avoided"] else ""),
                          "parse that reply shape locally (forge/llm.py parse_reply) or fix how the role is asked",
                          r["repairs"]))
        if r["calls"] >= 3 and r["over_run_size"] >= 0.5 * r["calls"]:
            out.append(_w("oversized_calls", f"{role}: {r['over_run_size']} of {r['calls']} calls are over Mubit's "
                          f"~{RUN_TOKENS}-token run size", f"mean input {r['input_tokens'] // max(1, r['calls'])} tokens",
                          "budget the context this role re-sends on every call (forge/roles.py)"))
        if r["aborted"] >= 3:
            out.append(_w("aborted_replies", f"{role}: {r['aborted']} replies were cut short as prose",
                          "aborted=true in calls.jsonl", "the role answers in prose: check what its message asks for",
                          r["aborted"]))
    return out


def _investigation_weaknesses(summary: dict) -> list[dict]:
    out = []
    invs = [f for f in summary["fixes"] if f["investigation_steps"] is not None]
    capped = [f for f in invs if f["investigation_steps"] >= INVESTIGATE_STEPS - 1]
    if len(invs) >= 2 and len(capped) >= 0.5 * len(invs):
        out.append(_w("investigator_step_cap", f"{len(capped)} of {len(invs)} investigations used every step "
                      f"(cap {INVESTIGATE_STEPS})", "steps per investigation: "
                      + ", ".join(str(f["investigation_steps"]) for f in invs),
                      "the investigator rarely concludes early: tell it how many steps are left, or lower the cap"))
    wasted = [f for f in invs if f["status"] == "unproven" and f["investigation_steps"]]
    if wasted:
        n = sum(f["investigation_steps"] + 1 for f in wasted)
        out.append(_w("investigated_then_unproven", f"{len(wasted)} anomalies were investigated, then never "
                      f"reproduced (about {n} investigator calls)", "; ".join(f["anomaly"][:60] for f in wasted[:3]),
                      "reproduce first when the anomaly names a check or a counter; investigate only proven bugs", n))
    return out


def _fix_weaknesses(data: dict, summary: dict) -> list[dict]:
    out = []
    by_setup = []
    for f in summary["fixes"]:
        for a in f["attempts"]:
            broke = [g for g in ((a.get("checks") or {}).get("guards") or []) if isinstance(g, dict) and not g.get("ok")]
            if a.get("status") == "check_regression" and broke and all(_setup_error(g) for g in broke):
                by_setup.append(f["anomaly"])
    if by_setup:
        out.append(_w("guard_setup_rejections", f"{len(by_setup)} fix attempts were rejected because a guard check "
                      "failed in setup, not because the game broke", "; ".join(sorted(set(a[:60] for a in by_setup))),
                      "a guard that cannot set up (error 'setup: ...') is inconclusive: rerun it or fix its setup "
                      "before counting it as a regression", len(by_setup)))
    repeats = [f for f in summary["fixes"] if len(f["attempts"]) >= 2 and len({(a.get("status"), str(a.get("error") or "")[:80])
                                                                              for a in f["attempts"]}) == 1]
    if repeats:
        n = sum(len(f["attempts"]) - 1 for f in repeats)
        out.append(_w("retry_repeated_failure", f"{len(repeats)} fixes failed the same way on every retry "
                      f"({n} retry attempts changed nothing)", "; ".join(f"{f['anomaly'][:50]}: {f['attempts'][0].get('status')}"
                                                                        for f in repeats[:3]),
                      "the retry message did not move the fixer: add what the check measured, or stop after one",
                      n))
    for c in data["cycles"]:
        tried = c.get("code_fixes") or []
        if len(tried) >= 2 and not c.get("code_kept"):
            causes = Counter(a.get("status") for f in tried for a in f.get("attempts") or [] if a.get("status") != "fixed")
            top = ", ".join(f"{k} {v}" for k, v in causes.most_common(3)) or "no attempt reached a verdict"
            out.append(_w("cycle_kept_nothing", f"fix cycle {c.get('cycle')} tried {len(tried)} anomalies and kept none",
                          f"rejections: {top}", "look at the top rejection cause first"))
    setup = summary["failures"].get("setup_error", 0)
    if setup:
        out.append(_w("check_setup_errors", f"{setup} check runs failed in setup", "checks whose result says 'setup:'",
                      "the check could not set up its situation (often starting a round): fix the check or the harness"))
    vetoes = sum(1 for f in summary["fixes"] for a in f["attempts"]
                 if a.get("checks") and (a.get("verdict") or {}).get("verdict") == "regression")
    if vetoes:
        out.append(_w("verifier_vetoes", f"the verifier vetoed {vetoes} fixes that passed their checks",
                      "verdict regression after the repro check and guards passed",
                      "keep the verifier; turn what it saw into a check so the guards catch it next time"))
    return out


def _other_weaknesses(data: dict, summary: dict) -> list[dict]:
    out = []
    errors = {k: v for k, v in summary["failures"].items() if k.startswith("mubit_")}
    if errors:
        out.append(_w("mubit_errors", f"{sum(errors.values())} Mubit calls failed", json.dumps(errors),
                      "rate limits: fewer FORGE_JOBS; overloaded: retry later", sum(errors.values())))
    stages = summary["by_stage"]
    if stages:
        name, top = next(iter(stages.items()))
        if top["share"] >= 0.5 and summary["latency_s"] >= 60:
            out.append(_w("dominant_stage", f"{name} took {top['share'] * 100:.0f}% of the LLM time",
                          f"{top['latency_s']:.0f}s of {summary['latency_s']:.0f}s over {top['calls']} calls",
                          "that stage is where a cut saves the most"))
    rolled = [it for it in data["iterations"] if it.get("rolled_back_to")]
    if rolled:
        out.append(_w("score_rollbacks", f"{len(rolled)} build iterations scored lower and were rolled back",
                      ", ".join(f"#{it.get('n')} -> {it.get('rolled_back_to')}" for it in rolled),
                      "the critic's fixes made the game worse: read those iterations' fixes"))
    return out


def weaknesses(data: dict, summary: dict) -> list[dict]:
    found = (_repair_weaknesses(summary) + _investigation_weaknesses(summary) + _fix_weaknesses(data, summary)
             + _other_weaknesses(data, summary))
    return sorted(found, key=lambda w: -w["wasted_calls"])


# ---------------------------------------------------------------- what was attempted


def attempted(data: dict, summary: dict) -> list[str]:
    out = [f"{t.get('command')}: {t.get('total_secs') or 0:.0f}s wall, {len(t.get('calls') or [])} timed calls"
           for t in data["timings"]]
    scores = [it.get("score") for it in data["iterations"] if it.get("score") is not None]
    if data["iterations"]:
        out.append(f"{len(data['iterations'])} build iteration(s), critic "
                   + (" -> ".join(f"{s:g}" for s in scores) if scores else "not scored"))
    call_ts = sorted(t for t in (_epoch(c.get("ts")) for c in data["calls"]) if t is not None)
    prev_end = None
    for c in data["cycles"]:
        st = Counter(str(f.get("status")) for f in c.get("code_fixes") or [])
        ck = c.get("checks") or {}
        end = _epoch(c.get("ts"))
        first = next((t for t in call_ts if (prev_end is None or t > prev_end) and end is not None and t <= end), None)
        wall = f", ~{end - first:.0f}s from its first Mubit call" if first is not None and end is not None else ""
        prev_end = end
        out.append(f"fix cycle {c.get('cycle')} ({c.get('session_id')}{wall}): {len(c.get('code_fixes') or [])} "
                   f"anomalies tried ({', '.join(f'{k} {v}' for k, v in st.most_common()) or 'none'}), "
                   f"{c.get('open', 0)} left open"
                   + (f"; checks: {len(ck.get('proven') or [])} proven, {len(ck.get('kept') or [])} joined the suite"
                      if c.get("repro") else ""))
    for f in data["features"]:
        out.append(f"feature \"{str(f.get('request') or '')[:70]}\": "
                   f"{'verified' if f.get('verified') else 'built, not verified'} ({f.get('version')})")
    for c in data["corrections"]:
        out.append(f"human correction of {c.get('path')}: {str(c.get('note') or '')[:70]}")
    return out or ["nothing new was recorded"]


# ---------------------------------------------------------------- one reflection


def _readiness(settings: Settings, slug: str) -> dict | None:
    from forge.done import readiness
    try:
        r = readiness(settings, slug)
    except Exception:  # noqa: BLE001 - a game without every record still gets its reflection
        return None
    return {"ready": r["ready"], "ok": sum(1 for p in r["parts"] if p["ok"]), "of": len(r["parts"]),
            "failing": [p["part"] for p in r["parts"] if not p["ok"]]}


def build(settings: Settings, slug: str, *, since: float | None, until: float, label: str = "") -> dict:
    data = collect(settings, slug, since, until)
    summary = summarize(data)
    return {"slug": slug, "label": label, "ts": _iso(until), "since": _iso(since), "until": until,
            "since_epoch": since, "attempted": attempted(data, summary), "summary": summary,
            "weaknesses": weaknesses(data, summary), "done": _readiness(settings, slug)}


def history(settings: Settings, slug: str) -> list[dict]:
    return _lines(settings.runs_dir / slug / DIR / LOG)


def reflect(settings: Settings, slug: str, *, label: str = "", since: float | None = None, llm: Any = None,
            log: Callable[[str], None] = print) -> dict | None:
    """Write the next reflection: runs/<slug>/reflection/<n>.md and a line in reflection.jsonl. It covers
    everything since `since`, else since the previous reflection (the first: the whole run). Returns the
    record, or None when nothing was recorded in that window. With an llm, the findings also go to the
    reflector, which rewrites runs/lessons.md."""
    from forge.broker import file_lock

    out_dir = settings.runs_dir / slug / DIR
    with file_lock(out_dir / ".lock"):
        past = history(settings, slug)
        start = since if since is not None else (past[-1].get("until") if past else None)
        rec = build(settings, slug, since=start, until=time.time(), label=label)
        if not rec["summary"]["calls"] and rec["attempted"] == ["nothing new was recorded"]:
            log(f"[reflect] {slug}: nothing new since reflection {len(past)}")
            return None
        rec["n"] = len(past) + 1
        if llm is not None:
            rec["llm"] = _ask_reflector(settings, slug, rec, llm, log)
        md = out_dir / f"{rec['n']}.md"
        md.write_text(render(rec) + "\n", encoding="utf-8")
        with (out_dir / LOG).open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")
    s = rec["summary"]
    log(f"[reflect] {slug} #{rec['n']}: {s['calls']} Mubit calls, {s['input_tokens']} tokens in, "
        f"{s['cache_hits']} cache hits, {s['repairs_avoided']} repairs parsed locally, kept {s['kept']} / "
        f"rolled back {s['rolled_back']}, {len(rec['weaknesses'])} weaknesses -> {md}")
    return rec


def maybe_reflect(settings: Settings, slug: str, *, label: str = "", since: float | None = None,
                  log: Callable[[str], None] = print) -> dict | None:
    """The end-of-command hook: a reflection without LLM calls that never fails the command."""
    try:
        return reflect(settings, slug, label=label, since=since, log=log)
    except Exception as e:  # noqa: BLE001
        log(f"[reflect] {slug}: no reflection ({type(e).__name__}: {e})")
        return None


def _ask_reflector(settings: Settings, slug: str, rec: dict, llm: Any, log: Callable[[str], None]) -> dict:
    """The reflection's findings -> the reflector (same Mubit task as every lessons update) -> runs/lessons.md."""
    from forge import roles
    from forge.loop import TracingLLM
    from forge.memory import read_lessons, write_lessons

    traced = llm if isinstance(llm, TracingLLM) else TracingLLM(llm)
    s = rec["summary"]
    lines = ["Reflection over Forge's last run of one game. Turn the failures and weaknesses below into general "
             "lessons for future builds and fixes (how to keep fixes local, what to check before changing a file, "
             "how a fix breaks other systems). Rules that apply to any game, not this game's names or numbers.", ""]
    lines += [f"- {a}" for a in rec["attempted"]]
    lines += ["", "Rejected or failed fix attempts:"]
    for f in s["fixes"]:
        for a in f["attempts"]:
            if a.get("status") != "fixed":
                why = (a.get("verdict") or {}).get("evidence") or a.get("error") or ""
                lines.append(f"- {f['anomaly'][:100]} in {f['path']}: {a.get('status')}. {str(why)[:300]}")
    lines += ["", "Failures by cause: " + ", ".join(f"{k} {v}" for k, v in s["failures"].items()), "",
              "Weaknesses observed:"] + [f"- {w['finding']} ({w['evidence'][:200]})" for w in rec["weaknesses"]]
    try:
        new = roles.reflect(traced, read_lessons(settings), "\n".join(lines), session_id=f"reflect-{slug}-{rec['n']}")
    except Exception as e:  # noqa: BLE001
        log(f"[reflect] reflector call failed: {type(e).__name__}: {str(e)[:120]}")
        return {"ok": False, "error": f"{type(e).__name__}: {e}"[:300]}
    write_lessons(settings, new)
    rid = traced.results[-1].request_id if traced.results else None
    log(f"[reflect] lessons updated by the reflector {rid or ''}".rstrip())
    return {"ok": True, "lessons_updated": True, "request_id": rid}


# ---------------------------------------------------------------- markdown


def _table(head: list[str], rows: list[list[Any]]) -> list[str]:
    out = ["| " + " | ".join(head) + " |", "|" + "|".join("---" for _ in head) + "|"]
    return out + ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]


def render(rec: dict) -> str:
    s = rec["summary"]
    lines = [f"# Reflection {rec.get('n', '-')}: {rec['slug']}" + (f" ({rec['label']})" if rec.get("label") else ""),
             "", f"{rec['ts']}, covering " + (f"everything after {rec['since']}" if rec.get("since") else "the whole run"),
             "", "## What was attempted"] + [f"- {a}" for a in rec["attempted"]]
    if s["fixes"]:
        lines += ["", f"## Kept and rolled back ({s['kept']} kept, {s['rolled_back']} rolled back, "
                      f"{s['unproven']} unproven)", ""]
        lines += _table(["cycle", "anomaly", "file", "status", "attempts"],
                        [[f["cycle"], f["anomaly"][:70].replace("|", "/"), f["path"] or "-", f["status"],
                          ", ".join(str(a.get("status")) for a in f["attempts"]) or "-"] for f in s["fixes"]])
    lines += ["", "## Mubit calls", "",
              f"{s['calls']} calls, {s['input_tokens']} input / {s['output_tokens']} output tokens, {s['latency_s']:.0f}s "
              f"of LLM time, {s['errors']} failed. Not needed: {s['cache_hits']} reply-cache hits, "
              f"{s['repairs_avoided']} JSON repairs parsed locally (~{s['saved_input_tokens']} input tokens).", ""]
    lines += _table(["role", "calls", "tokens in", "tokens out", "LLM s", "repairs", "retries", f"over {RUN_TOKENS // 1000}k",
                     "cache hits", "repairs avoided"],
                    [[k, r["calls"], r["input_tokens"], r["output_tokens"], f"{r['latency_s']:.0f}", r["repairs"],
                      r["retries"], r["over_run_size"], r["cache_hits"], r["repairs_avoided"]] for k, r in s["by_role"].items()])
    lines += ["", "## Time by stage", ""]
    lines += _table(["stage", "calls", "tokens in", "LLM s", "share"],
                    [[k, v["calls"], v["input_tokens"], f"{v['latency_s']:.0f}", f"{v['share'] * 100:.0f}%"]
                     for k, v in s["by_stage"].items()])
    if s["wall_stages"]:
        lines += ["", "Wall time (timings.json): " + ", ".join(f"{w['name']} {w['secs']:.0f}s" for w in s["wall_stages"])]
    lines += ["", "## Failures by cause", ""]
    lines += _table(["cause", "count"], [[k, v] for k, v in s["failures"].items()]) if s["failures"] else ["none"]
    lines += ["", "## System weaknesses", ""]
    lines += [f"{i}. **{w['finding']}**. Evidence: {w['evidence']}. Next: {w['fix']}."
              for i, w in enumerate(rec["weaknesses"], 1)] or ["none observed"]
    d = rec.get("done")
    if d:
        lines += ["", "## Where the game stands", "",
                  f"forge done: {d['ok']}/{d['of']} parts" + (" (READY)" if d["ready"] else
                                                              f", failing: {', '.join(d['failing'])}")]
    if rec.get("llm"):
        lines += ["", f"Reflector: {json.dumps(rec['llm'])}"]
    return "\n".join(lines)


# ---------------------------------------------------------------- every game


def games(settings: Settings) -> list[str]:
    root = settings.runs_dir
    if not root.is_dir():
        return []
    return sorted(p.name for p in root.iterdir() if p.is_dir() and not p.name.startswith(".")
                  and p.name not in NOT_GAMES and any(p.glob("**/calls.jsonl")))


def reflect_all(settings: Settings) -> tuple[dict, str]:
    """Every game's whole record, summed: per game numbers, totals, and the weaknesses seen in most games.
    Saved as runs/reflection.md; it reads the records, not the per-game reflections, so nothing counts twice."""
    rows, seen = [], defaultdict(list)
    for slug in games(settings):
        data = collect(settings, slug)
        s = summarize(data)
        ws = weaknesses(data, s)
        for w in ws:
            seen[w["id"]].append((slug, w))
        rows.append({"slug": slug, **{k: s[k] for k in ("calls", "input_tokens", "output_tokens", "latency_s", "errors",
                                                        "cache_hits", "repairs_avoided", "kept", "rolled_back",
                                                        "unproven")},
                     "repairs": sum(r["repairs"] for r in s["by_role"].values()),
                     "top_role": next(iter(s["by_role"]), "-"), "weaknesses": [w["id"] for w in ws]})
    total = {k: sum(r[k] for r in rows) for k in ("calls", "input_tokens", "output_tokens", "latency_s", "errors",
                                                  "cache_hits", "repairs_avoided", "repairs", "kept", "rolled_back",
                                                  "unproven")}
    found = [{"id": wid, "games": sorted({g for g, _ in ws}), "times": len(ws),
              "wasted_calls": sum(w["wasted_calls"] for _, w in ws), "example": ws[0][1]} for wid, ws in seen.items()]
    out = {"ts": _iso(time.time()), "games": rows, "total": total,
           "weaknesses": sorted(found, key=lambda w: (-w["wasted_calls"], -len(w["games"]), w["id"]))}
    md = ["# Forge reflection: every game", "", f"{out['ts']}, {len(rows)} games", ""]
    md += _table(["game", "calls", "tokens in", "tokens out", "LLM s", "repairs", "cache hits", "repairs avoided",
                  "kept", "rolled back", "unproven", "top role"],
                 [[r["slug"], r["calls"], r["input_tokens"], r["output_tokens"], f"{r['latency_s']:.0f}", r["repairs"],
                   r["cache_hits"], r["repairs_avoided"], r["kept"], r["rolled_back"], r["unproven"], r["top_role"]]
                  for r in rows])
    md += ["", f"**Total:** {total['calls']} calls, {total['input_tokens']} / {total['output_tokens']} tokens, "
               f"{total['latency_s']:.0f}s LLM, {total['repairs']} repair calls, {total['cache_hits']} cache hits, "
               f"{total['repairs_avoided']} repairs parsed locally; fixes kept {total['kept']}, rolled back "
               f"{total['rolled_back']}, unproven {total['unproven']}.", "", "## Weaknesses seen across games", ""]
    md += [f"- **{w['id']}**: {w['times']}x in {len(w['games'])} game(s) ({', '.join(w['games'][:4])}"
           f"{', ...' if len(w['games']) > 4 else ''}), ~{w['wasted_calls']} wasted calls. "
           f"e.g. {w['example']['finding']}. Next: {w['example']['fix']}."
           for w in out["weaknesses"]] or ["none observed"]
    text = "\n".join(md)
    settings.runs_dir.mkdir(parents=True, exist_ok=True)
    (settings.runs_dir / "reflection.md").write_text(text + "\n", encoding="utf-8")
    return out, text
