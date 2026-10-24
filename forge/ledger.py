"""`forge ledger`: what Forge has fed Mubit, rebuilt from the records every run already writes.

Every Mubit call is traced (runs/**/traces/*.json: role, request id, session, full user message).
Every fix cycle is saved (runs/<slug>/improve/<n>.json: anomalies, attempts, verifier verdicts).
Together they give, per Mubit task (role):
- calls: recorded calls, the examples Mubit trains that task's adapter on;
- corrections: calls that carry a correction in the same task. A fixer/patcher retry after the
  verifier rejected its fix, an auditor re-audit after it missed a planted fault, an investigator
  re-investigation after its conclusion led to a rejected fix, or a human `forge correct`;
- verified: fixer/patcher replies whose fix was then proved in a playtest (verifier: fixed) and kept.
  These are the replies to rate Good in the Mubit console; the rejected ones to rate Bad.
Nothing here calls Mubit or changes a run.
"""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from typing import Any

from forge.config import Settings

RETRY_MARK = "## Your previous fix was rejected"
FIX_ROLES = ("fixer", "patcher")


def _read(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def traces(runs_dir: Path) -> list[dict]:
    """Every traced Mubit call under runs/, oldest first (user message kept, reply dropped)."""
    out = []
    for p in runs_dir.glob("**/traces/*.json"):
        t = _read(p)
        if isinstance(t, dict) and t.get("request_id"):
            out.append({k: t.get(k) for k in ("ts", "role", "session_id", "request_id", "user")})
    return sorted(out, key=lambda t: str(t.get("ts") or ""))


def _fix_calls(calls: list[dict], session_id: str, anomaly: str) -> list[dict]:
    """The fixer/patcher calls one anomaly's fix attempts made, in order."""
    title = f": {anomaly}\n"
    return [c for c in calls if c.get("role") in FIX_ROLES and c.get("session_id") == session_id
            and title in str(c.get("user") or "")]


def _cycle_entries(slug: str, cycle: dict, calls: list[dict]) -> list[dict]:
    sid = str(cycle.get("session_id") or "")
    out: list[dict] = []
    corr = cycle.get("correction") or {}
    if corr.get("request_id"):
        out.append({"slug": slug, "cycle": cycle.get("cycle"), "role": "auditor", "kind": "correction",
                    "why": "missed a planted fault; re-audited with the verified symptom",
                    "request_id": corr["request_id"], "ts": cycle.get("ts")})
    for fx in cycle.get("code_fixes") or []:
        anomaly = str(fx.get("anomaly") or "")
        made = _fix_calls(calls, sid, anomaly)
        attempts = [a for a in fx.get("attempts") or [] if a.get("status") != "no_fix_needed"]
        for i, call in enumerate(made):
            verdict = (attempts[i] if i < len(attempts) else {}).get("status")
            kind = "correction" if RETRY_MARK in str(call.get("user") or "") else "answer"
            out.append({"slug": slug, "cycle": cycle.get("cycle"), "role": call["role"], "kind": kind,
                        "anomaly": anomaly, "request_id": call["request_id"], "ts": call.get("ts"),
                        "verdict": verdict,
                        "verified": verdict == "fixed" and fx.get("status") == "kept",
                        "verifier_request_id": ((attempts[i] if i < len(attempts) else {}).get("verdict")
                                                or {}).get("request_id")})
        for rid in (fx.get("reinvestigation") or {}).get("request_ids") or []:
            out.append({"slug": slug, "cycle": cycle.get("cycle"), "role": "investigator",
                        "kind": "correction", "anomaly": anomaly, "request_id": rid, "ts": cycle.get("ts"),
                        "why": "its conclusion led to a rejected fix; told why and asked again"})
    return out


def ledger(settings: Settings) -> dict:
    runs = settings.runs_dir
    calls = traces(runs)
    entries: list[dict] = []
    for game in sorted(p for p in runs.iterdir() if p.is_dir()):
        for path in sorted((game / "improve").glob("[0-9]*.json"), key=lambda p: int(p.stem)):
            cycle = _read(path)
            if isinstance(cycle, dict):
                entries += _cycle_entries(game.name, cycle, calls)
        for c in (_read(game / "state.json") or {}).get("corrections") or []:
            if c.get("request_id"):
                entries.append({"slug": game.name, "role": "fixer", "kind": "correction", "ts": c.get("ts"),
                                "request_id": c["request_id"], "why": f"human: {str(c.get('note', ''))[:120]}"})
        try:  # forge gaps --correct: developer corrections in the gap_finder task (forge/gaps.py)
            gap_corr = [json.loads(ln) for ln in (game / "orchestrator" / "corrections.jsonl").read_text(
                encoding="utf-8").splitlines() if ln.strip()]
        except (OSError, ValueError):
            gap_corr = []
        for c in gap_corr:
            if c.get("request_id"):
                entries.append({"slug": game.name, "role": "gap_finder", "kind": "correction", "ts": c.get("ts"),
                                "request_id": c["request_id"], "why": f"human: {str(c.get('note', ''))[:120]}"})
    by_role = Counter(c.get("role") for c in calls)
    roles = []
    for role, n in by_role.most_common():
        mine = [e for e in entries if e["role"] == role]
        roles.append({"role": role, "calls": n,
                      "corrections": sum(1 for e in mine if e["kind"] == "correction"),
                      "verified": sum(1 for e in mine if e.get("verified")),
                      "rejected": sum(1 for e in mine if e.get("verdict") not in (None, "fixed"))})
    return {"total_calls": len(calls), "roles": roles, "entries": entries,
            "corrections": sum(1 for e in entries if e["kind"] == "correction"),
            "verified": sum(1 for e in entries if e.get("verified"))}


def render(data: dict, recent: int = 12) -> str:
    lines = [f"Mubit calls recorded: {data['total_calls']}  ·  corrections: {data['corrections']}  ·  "
             f"fixes proved in play: {data['verified']}", "",
             f"{'task (role)':<14} {'calls':>6} {'corrections':>12} {'verified':>9} {'rejected':>9}"]
    for r in data["roles"]:
        lines.append(f"{r['role']:<14} {r['calls']:>6} {r['corrections']:>12} {r['verified']:>9} {r['rejected']:>9}")
    picked = [e for e in data["entries"] if e["kind"] == "correction" or e.get("verified")]
    shown = sorted(picked, key=lambda e: str(e.get("ts") or ""))[-recent:]
    if shown:
        lines += ["", "Latest corrections and verified fixes (rate them in the console -> Requests):"]
        for e in shown:
            tag = "GOOD" if e.get("verified") else ("BAD " if e.get("verdict") not in (None, "fixed") else "corr")
            what = e.get("anomaly") or e.get("why") or ""
            lines.append(f"  {tag} {e['role']:<12} {e['request_id']}  {e['slug'][:28]}  {str(what)[:70]}")
    return "\n".join(lines)
