"""`forge done <slug>`: is the game ready? One bar, the same for every game, each part proved by a record:

- checks: the latest executable check run (runs/<slug>/checks/results.json, written by `forge checks
  --run` and again at the end of every fix cycle) has at least one check and every check passes
  (dropped checks were broken tests and do not count);
- features: every feature in features.jsonl is verified (for UI features that includes a tester
  pressing its buttons, forge/feature.py);
- open: the latest fix cycle left nothing high or medium open;
- critic: the latest build iteration scored at least CRITIC_BAR (games seeded from human code
  have no build iterations; for them this part is not applicable).
- fun: the latest fun critique (forge/fun.py, runs/<slug>/fun/latest.json) scored at least FUN_BAR
  (mean of fun, juice, clarity, visuals);
- visuals / hud / sounds: the latest scene census (the playtest census if there is one, else the
  source) shows at most GREY_MAX default-grey parts, a ScreenGui HUD and at least one sound;
- first60: every beat of the director's first-60-seconds script (spec["first_60s"]) happened: its
  counter reached its minimum in the latest playtest (a beat with no counter: the fun critic saw it).
Seeded games (human code) have no fun critique or director script; for them fun/first60 are n/a.

A part with no record yet is not met: unknown is never "ready".
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from forge.config import Settings
from forge.fun import FUN_BAR, static_census, visual_checks
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
    if isinstance(results, list):  # a dropped check was a broken test, moved out of the suite
        results = [r for r in results if isinstance(r, dict) and r.get("verdict") != "dropped"]
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


def _fun(run: Path, seeded: bool) -> dict:
    latest = _read(run / "fun" / "latest.json")
    if not isinstance(latest, dict) or latest.get("score") is None:
        if seeded:
            return {"part": "fun", "ok": True, "detail": "n/a (seeded from human code)"}
        return {"part": "fun", "ok": False, "detail": "no fun critique yet"}
    score = float(latest["score"])
    sc = latest.get("scores") or {}
    detail = f"{score:g}/10 (bar {FUN_BAR:g})"
    if sc:
        detail += "  " + " ".join(f"{k} {float(v):g}" for k, v in sc.items())
    return {"part": "fun", "ok": score >= FUN_BAR, "detail": detail}


def _latest_report(run: Path) -> dict:
    its = run / "iterations"
    if not its.is_dir():
        return {}
    reports = sorted((p for p in its.glob("*/report.json") if p.parent.name.isdigit()),
                     key=lambda p: int(p.parent.name))
    return (_read(reports[-1]) or {}) if reports else {}


def _census(run: Path, game_dir: Path) -> dict:
    """Playtest census (fun critique, else the latest iteration report), else read from the source."""
    latest = _read(run / "fun" / "latest.json")
    if isinstance(latest, dict) and isinstance(latest.get("census"), dict) and latest["census"]:
        return latest["census"]
    rep = _latest_report(run).get("census")
    if isinstance(rep, dict) and rep:
        return rep
    files = {}
    if game_dir.is_dir():
        for p in game_dir.rglob("*.luau"):
            rel = p.relative_to(game_dir).as_posix()
            if not rel.startswith("tools/"):
                files[rel] = p.read_text(encoding="utf-8", errors="replace")
    return static_census(files) if files else {}


def _polish(run: Path, game_dir: Path) -> list[dict]:
    c = _census(run, game_dir)
    checks = visual_checks(c)
    src = c.get("source", "no census")
    if "parts" in c:
        grey = f"{c.get('grey', 0)}/{c.get('parts', 0)} parts default grey"
    else:
        grey = f"{c.get('colour_sites', 0)} colour sets for {c.get('part_sites', 0)} part sites"
    hud = (f"{c.get('screen_guis')} ScreenGuis" if "screen_guis" in c
           else f"{c.get('screen_gui_sites', 0)} ScreenGui sites")
    if "sounds" in c or "client_sounds" in c:
        snd = f"{int(c.get('sounds') or 0) + int(c.get('client_sounds') or 0)} sounds"
    else:
        snd = f"{c.get('sound_sites', 0)} sound sites"

    def part(name: str, ok, detail: str) -> dict:
        return {"part": name, "ok": bool(ok), "detail": (detail if ok is not None else "unknown") + f" ({src})"}

    return [part("visuals", checks["grey_ok"], grey), part("hud", checks["hud_ok"], hud),
            part("sounds", checks["sounds_ok"], snd)]


def _counters(run: Path) -> dict[str, float]:
    """Highest value of each counter in the latest build playtest and the latest fix cycle's rounds."""
    sources = [_latest_report(run).get("counters") or {}]
    scores = _read(run / "improve" / "scores.json")
    if isinstance(scores, list) and scores:
        cyc = _read(run / "improve" / f"{scores[-1].get('cycle')}.json") or {}
        sources += [d.get("counters") or {} for d in cyc.get("before") or [] if isinstance(d, dict)]
    out: dict[str, float] = {}
    for src in sources:
        for k, v in (src.items() if isinstance(src, dict) else []):
            try:
                out[k] = max(out.get(k, 0.0), float(v))
            except (TypeError, ValueError):
                pass
    return out


def _first60(run: Path, spec: dict, seeded: bool) -> dict:
    beats = [b for b in spec.get("first_60s") or [] if isinstance(b, dict)]
    if not beats:
        if seeded:
            return {"part": "first60", "ok": True, "detail": "n/a (seeded from human code)"}
        return {"part": "first60", "ok": False, "detail": "no first-60-seconds script (build with the director)"}
    counters = _counters(run)
    seen = {b.get("beat"): b.get("ok")
            for b in (_read(run / "fun" / "latest.json") or {}).get("first_60_seconds") or [] if isinstance(b, dict)}
    failed = []
    for b in beats:
        c = b.get("counter")
        ok = counters.get(c, 0) >= int(b.get("min") or 1) if c else bool(seen.get(b.get("beat")))
        if not ok:
            failed.append(c or str(b.get("beat"))[:30])
    return {"part": "first60", "ok": not failed,
            "detail": f"{len(beats) - len(failed)}/{len(beats)} beats"
                      + (": missing " + ", ".join(failed[:5]) if failed else "")}


def readiness(settings: Settings, slug: str) -> dict:
    store = RunStore(settings, slug)
    spec = _read(store.spec_path) or {}
    state = _read(store.state_path) or {}
    seeded = bool(spec.get("base_files"))
    parts = [_checks(store.dir), _features(store.dir, spec), _open(store.dir), _critic(state, seeded),
             _fun(store.dir, seeded), *_polish(store.dir, store.game_dir), _first60(store.dir, spec, seeded)]
    return {"slug": slug, "ready": all(p["ok"] for p in parts), "parts": parts}


def render(r: dict) -> str:
    head = f"{r['slug']}: " + ("READY" if r["ready"] else "not ready yet")
    return "\n".join([head] + [f"  [{'x' if p['ok'] else ' '}] {p['part']:<9} {p['detail']}" for p in r["parts"]])
