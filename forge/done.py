"""`forge done <slug>`: is the game ready? One bar, the same for every game, each part proved by a record:

- checks: the latest executable check run (runs/<slug>/checks/results.json) has at least one check
  and every check passes;
- features: every feature in features.jsonl is verified (for UI features that includes a tester
  pressing its buttons, forge/feature.py);
- open: the latest fix cycle left nothing high or medium open;
- critic: the latest build iteration scored at least CRITIC_BAR (games seeded from human code
  have no build iterations; for them this part is not applicable).

A part with no record yet is not met: unknown is never "ready".
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from forge.config import Settings
from forge.memory import RunStore

CRITIC_BAR = 8.0


def _read(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _lines(path: Path) -> list[dict]:
    try:
        return [json.loads(ln) for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip()]
    except (OSError, ValueError):
        return []


def _checks(run: Path) -> dict:
    results = _read(run / "checks" / "results.json")
    if isinstance(results, dict):
        results = results.get("results")
    if not isinstance(results, list) or not results:
        return {"part": "checks", "ok": False, "detail": "no check run yet (forge checks <slug> --plan --run)"}
    failed = [r for r in results if not r.get("ok")]
    return {"part": "checks", "ok": not failed,
            "detail": f"{len(results) - len(failed)}/{len(results)} pass"
                      + (": failing " + ", ".join(str(r.get("id")) for r in failed[:5]) if failed else "")}


def _features(run: Path, spec: dict) -> dict:
    # the spec lists every feature; features.jsonl (newer runs) holds the latest verified result
    latest: dict[str, dict] = {}
    for f in list(spec.get("features") or []) + _lines(run / "features.jsonl"):
        latest[str(f.get("request", ""))] = f
    if not latest:
        return {"part": "features", "ok": True, "detail": "no agent-added features"}
    bad = [r for r, f in latest.items() if not f.get("verified")]
    return {"part": "features", "ok": not bad,
            "detail": f"{len(latest) - len(bad)}/{len(latest)} verified"
                      + (": not verified " + "; ".join(b[:40] for b in bad) if bad else "")}


def _open(run: Path) -> dict:
    scores = _read(run / "improve" / "scores.json")
    if not isinstance(scores, list) or not scores:
        return {"part": "open", "ok": False, "detail": "no fix cycle yet (forge fix <slug>)"}
    last = scores[-1]
    n = int(last.get("open") or 0)
    return {"part": "open", "ok": n == 0, "detail": f"cycle {last.get('cycle')}: {n} high/medium open"}


def _critic(state: dict, seeded: bool) -> dict:
    its = [i for i in state.get("iterations") or [] if i.get("score") is not None]
    if not its:
        if seeded:
            return {"part": "critic", "ok": True, "detail": "n/a (seeded from human code)"}
        return {"part": "critic", "ok": False, "detail": "no critic score yet"}
    score = float(its[-1]["score"])
    return {"part": "critic", "ok": score >= CRITIC_BAR, "detail": f"{score:g}/10 (bar {CRITIC_BAR:g})"}


def readiness(settings: Settings, slug: str) -> dict:
    store = RunStore(settings, slug)
    spec = _read(store.spec_path) or {}
    state = _read(store.state_path) or {}
    parts = [_checks(store.dir), _features(store.dir, spec), _open(store.dir),
             _critic(state, bool(spec.get("base_files")))]
    return {"slug": slug, "ready": all(p["ok"] for p in parts), "parts": parts}


def render(r: dict) -> str:
    head = f"{r['slug']}: " + ("READY" if r["ready"] else "not ready yet")
    return "\n".join([head] + [f"  [{'x' if p['ok'] else ' '}] {p['part']:<9} {p['detail']}" for p in r["parts"]])
