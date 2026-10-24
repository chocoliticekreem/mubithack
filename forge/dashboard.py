"""`forge dashboard`: a live, read-only view of everything Forge is doing, at http://127.0.0.1:8765.

It reads what Forge already writes under runs/ and never changes anything:
- running work: MCP background jobs (runs/jobs/) and CLI logs (runs/*.log), with live log tails;
- per game: iterations (critic score, version, rollbacks), saved versions, improve/fix cycles
  (anomalies, fix attempts, verifier verdicts), tester reports;
- Mubit: calls per role against the 25 examples a task needs before it trains, latest request ids;
- per version, a "mission": what it improved in a few plain words, files changed, fixes kept;
- mission control (team_view): one lane per agent and tester, tester screenshots with assertions,
  the Mubit ledger's correction moments, scores per version and wall clock per stage.
  GET /api/shot serves the step screenshots (PNG under runs/<slug>/tests or iterations only).

The page polls /api/state every few seconds. Its one write is POST /api/rollback {slug, version}, from
127.0.0.1 only: the same GameVersions.restore as `forge rollback`, saved as a new version. Stdlib only.
"""

from __future__ import annotations

import json
import re
import time
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from forge.config import Settings, load_settings
from forge.memory import RunStore

TRAIN_AT = 25
LOG_TAIL = 40
PLAYTEST_RECENT = 30 * 60  # seconds: playtests touched this recently show under Running
CONSOLE_URL = "https://app.mubit.ai/console/"
EXIT_MARK = "__exit "


def _read_json(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def _tail(path: Path, n: int = LOG_TAIL) -> list[str]:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    return [ln for ln in lines if "WARN studio_mcp" not in ln and "HTTP Request:" not in ln][-n:]


def _calls(path: Path) -> list[dict]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return []
    out = []
    for ln in text.splitlines():
        try:
            out.append(json.loads(ln))
        except ValueError:
            continue
    return out


def _alive(pid: int) -> bool:
    import os

    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def running(settings: Settings, now: float | None = None) -> list[dict]:
    """MCP jobs and CLI logs, newest first, each with status and a log tail."""
    now = now or time.time()
    out: list[dict] = []
    for meta_path in (settings.runs_dir / "jobs").glob("*.json"):
        meta = _read_json(meta_path, {})
        log = Path(meta.get("log", ""))
        lines = _tail(log, 400)
        code = next((ln[len(EXIT_MARK):].strip() for ln in reversed(lines) if ln.startswith(EXIT_MARK)), None)
        if code is not None:
            status = "finished" if code == "0" else f"failed (exit {code})"
        elif meta.get("cancelled"):
            status = "cancelled"
        else:
            status = "running" if _alive(int(meta.get("pid", 0) or 0)) else "stopped"
        out.append({"name": meta.get("id", meta_path.stem), "kind": "job", "status": status,
                    "command": "forge " + " ".join(meta.get("args", [])),
                    "updated": log.stat().st_mtime if log.exists() else meta_path.stat().st_mtime,
                    "tail": [ln for ln in lines if not ln.startswith(EXIT_MARK)][-LOG_TAIL:]})
    for report in (settings.runs_dir / "playtests").glob("*/report.json"):
        mtime = report.stat().st_mtime
        if now - mtime > PLAYTEST_RECENT:
            continue
        rep = _read_json(report, {}) or {}
        steps = rep.get("steps") or []
        lines = [f"{s.get('player_name') or ''} #{s.get('n')}: {(s.get('action') or {}).get('action', '')} "
                 f"- {str((s.get('action') or {}).get('reason', ''))[:90]} -> {str(s.get('result', ''))[:90]}"
                 for s in steps[-12:]]
        lines += [f"BUG [{b.get('severity')}] {b.get('title')}" for b in rep.get("bugs") or []]
        done = bool(rep.get("ended"))
        out.append({"name": f"playtest {report.parent.name}", "kind": "playtest",
                    "status": "finished" if done else "running",
                    "command": f"AI testers ({len(rep.get('players') or [])} players), goal: {rep.get('goal', '')}"
                               + (f" · goal met: {rep.get('goal_met')}" if done else f" · step {len(steps)}"),
                    "updated": mtime, "tail": lines})
    for log in settings.runs_dir.glob("*.log"):
        mtime = log.stat().st_mtime
        out.append({"name": log.name, "kind": "log", "status": "active" if now - mtime < 120 else "idle",
                    "command": log.name, "updated": mtime, "tail": _tail(log)})
    return sorted(out, key=lambda r: -r["updated"])


def _versions(game_dir: Path) -> list[dict]:
    from forge.versions import GameVersions, VersionError

    try:
        return GameVersions(game_dir).log()
    except (VersionError, OSError):
        return []


_DIFF_CACHE: dict[tuple[str, str], list[str]] = {}
_STOP = re.compile(r"\s(?:about|is|are|was|were|never|not|no longer|unverified|too|does|doesn't|only|"
                   r"fails?|missing|absent|instead|when|because|so|returns?|stops?|breaks?|can't|cannot|"
                   r"has|have|shows?|appears?|keeps?|in|on|at|after|during|while|that|which)\b", re.I)
ROLE_WORDS = {"designer": "designer", "coder": "coder", "build": "coder", "fixer": "fixer", "patcher": "patcher",
              "critic": "critic", "score": "critic", "studio": "tester", "check": "tester", "playtest": "tester",
              "tester": "tester", "investigator": "investigator", "auditor": "auditor", "triage": "auditor",
              "cycle": "auditor", "verifier": "verifier", "planner": "planner", "feature": "planner",
              "reflector": "coach", "version": "keeper", "versions": "keeper"}


def _words(text: str, n: int = 5) -> str:
    """The head of a problem/feature line, cut before the commentary:
    'Cube drop rate about twice the specified rate' -> 'cube drop rate'."""
    text = re.split(r"[,;:(]|\s-\s|\sin\s[A-Z]\w*/", text.strip(), maxsplit=1)[0]
    text = _STOP.split(text, maxsplit=1)[0]
    text = re.sub(r"^(?:please\s+)?(?:add|adds|added|build|make|create)\s+", "", text.strip(), flags=re.I)
    text = re.sub(r"^(?:a|an|the|some)\s+", "", text, flags=re.I)
    out = " ".join(text.split()[:n]).strip(" .")
    return out[:1].lower() + out[1:] if out[1:2].islower() or len(out) == 1 else out


def _module(path: str) -> str:
    stem = Path(path or "").name.split(".")[0]
    return re.sub(r"(?<=[a-z])(?=[A-Z])", " ", stem).replace("Service", "").strip() or stem


def _changed(game_dir: Path, tag: str) -> list[str]:
    """Files a version changed against the one before (versions are a straight line of commits).
    Tags never move, so the answer is cached."""
    from forge.versions import GameVersions, VersionError

    key = (str(game_dir), tag)
    if key not in _DIFF_CACHE:
        try:
            out = GameVersions(game_dir)._git("diff-tree", "-r", "--root", "--no-commit-id", "--name-only", tag)
        except (VersionError, OSError):
            return []
        _DIFF_CACHE[key] = [ln for ln in out.splitlines() if ln and ln != ".gitignore"]
    return _DIFF_CACHE[key]


def what_improved(message: str, iterations: list[dict], seeded: bool = False) -> dict:
    """A version's commit message -> {kind, title} in a few plain words, for the chest pop-up."""
    first = (message or "").strip().splitlines()[0] if (message or "").strip() else ""
    m = re.match(r"iteration (\d+): code under test", first)
    if m:
        n = int(m.group(1))
        prev = next((it for it in iterations if it.get("n") == n - 1), None)
        if prev and prev.get("fixes"):
            mods = list(dict.fromkeys(_module(i.get("path", "")) for i in prev.get("issues") or [] if i.get("path")))
            what = ", ".join(mods[:3]) if mods else f"{prev['fixes']} things"
            return {"kind": "round", "title": f"Fixed {what}"}
        if n == 1 and not seeded:
            return {"kind": "build", "title": "Built the first version"}
        return {"kind": "round", "title": f"Playtest round {n}"}
    if first.startswith("seeded"):
        return {"kind": "build", "title": "Started from the base game"}
    if first.startswith("fix:"):
        return {"kind": "fix", "title": f"Fixed {_words(first[4:])}"}
    if first.startswith("feature:"):
        return {"kind": "feature", "title": f"Added {_words(first[8:])}"}
    if first.startswith("before feature:"):
        return {"kind": "save", "title": f"Save point before {_words(first[15:], 4)}"}
    if first.startswith("before fixes"):
        return {"kind": "save", "title": "Save point before a bug hunt"}
    m = re.match(r"rollback to (v\d+)", first)
    if m:
        return {"kind": "rollback", "title": f"Went back to {m.group(1)}"}
    return {"kind": "other", "title": _words(first, 6).capitalize() or "Saved"}


def missions(game_dir: Path, versions: list[dict], iterations: list[dict], cycles: list[dict],
             seeded: bool = False) -> list[dict]:
    """One chest per saved version, oldest first."""
    scores = {it.get("version"): it.get("score") for it in iterations if it.get("version")}
    fixes: dict[str, list[str]] = {}
    for c in cycles:
        for f in c.get("code_fixes") or []:
            if f.get("status") == "kept" and f.get("version"):
                fixes.setdefault(f["version"], []).append(f.get("anomaly") or "")
    out = []
    for i, v in enumerate(versions):
        files = _changed(game_dir, v["version"])
        out.append({**what_improved(v.get("message", ""), iterations, seeded), "version": v["version"],
                    "n": i + 1, "date": v.get("date"), "message": v.get("message", ""),
                    "score": scores.get(v["version"]), "files": len(files), "file_list": files[:12],
                    "fixes": fixes.get(v["version"], []), "current": i == len(versions) - 1})
    return out


def _features(path: Path) -> list[dict]:
    return [{**{k: f.get(k) for k in ("request", "version", "verified", "ts")}, "built": len(f.get("built") or [])}
            for f in _calls(path)]


def live_for(settings: Settings, slug: str, runs: list[dict]) -> dict | None:
    """The freshest job/log building this game right now, with the role at work from its latest line."""
    pat = re.compile(re.escape(slug) + r"(?![\w-])")
    for r in runs:
        if r["status"] not in ("running", "active") or r["kind"] == "playtest":
            continue
        hit = pat.search(r.get("command", "")) or any(pat.search(ln) for ln in r.get("tail", []))
        if not hit and r["kind"] == "log":
            try:
                hit = pat.search((settings.runs_dir / r["name"]).read_text(encoding="utf-8", errors="replace"))
            except OSError:
                hit = None
        if not hit:
            continue
        role, line = None, ""
        for ln in reversed(r.get("tail", [])):
            m = re.match(r"\s*\[([a-z]+)", ln)
            if m and m.group(1) in ROLE_WORDS:
                role, line = ROLE_WORDS[m.group(1)], ln.strip()
                break
        m = re.search(r"(?:--iterations|-n)\s+(\d+)", r.get("command", ""))
        return {"name": r["name"], "role": role, "line": line, "updated": r["updated"],
                "target": int(m.group(1)) if m else None}
    return None


def game_view(settings: Settings, slug: str, runs: list[dict] | None = None) -> dict:
    store = RunStore(settings, slug)
    spec = _read_json(store.spec_path, {}) or {}
    state = _read_json(store.state_path, {}) or {}
    imp = store.dir / "improve"
    cycles = []
    for row in _read_json(imp / "scores.json", []) or []:
        detail = _read_json(imp / f"{row.get('cycle')}.json", {}) or {}
        cycles.append({**row,
                       "anomalies": (detail.get("audit") or {}).get("anomalies", []),
                       "code_fixes": detail.get("code_fixes", []),
                       "verdicts": detail.get("verdicts", []),
                       "missed": (detail.get("score") or {}).get("missed", row.get("missed"))})
    reports = []
    try:
        reports = [json.loads(ln) for ln in (imp / "reports.jsonl").read_text(encoding="utf-8").splitlines()
                   if ln.strip()]
    except (OSError, ValueError):
        pass
    calls = _calls(store.calls_log) + _calls(imp / "calls.jsonl")
    mtimes = [p.stat().st_mtime for p in (store.state_path, store.calls_log, imp / "scores.json") if p.exists()]
    iterations = state.get("iterations", [])
    versions = _versions(store.game_dir)
    seeded = bool(spec.get("base_files"))
    live = live_for(settings, slug, runs or [])
    scores = [it.get("score") for it in iterations if it.get("score") is not None]
    # `forge new/run` default to 3 rounds; a finished game's target is what it actually ran.
    target = (live or {}).get("target") or (max(3, len(iterations) + 1) if live else len(iterations))
    return {
        "slug": slug, "title": spec.get("title") or slug, "pitch": spec.get("pitch", ""),
        "seeded": seeded, "updated": max(mtimes) if mtimes else 0,
        "live": live,
        "goal": {"rounds": len(iterations), "target": target, "score": scores[-1] if scores else None,
                 "best": max(scores) if scores else None, "max": 10},
        "missions": missions(store.game_dir, versions, iterations, cycles, seeded),
        "features": _features(store.dir / "features.jsonl"),
        "iterations": [{k: it.get(k) for k in ("n", "score", "version", "rolled_back_to", "fixes",
                                                "summary", "studio", "ended")}
                       for it in state.get("iterations", [])],
        "corrections": [{k: c.get(k) for k in ("path", "note", "request_id", "kind")}
                        for c in state.get("corrections", [])],
        "versions": versions,
        "cycles": cycles,
        "reports": [{"ts": r.get("ts"), "reporter": r.get("reporter"), "text": r.get("text"),
                     "anomalies": (r.get("triage") or {}).get("anomalies", []),
                     "auditor_missed": r.get("auditor_missed", [])} for r in reports],
        "calls": dict(Counter(c.get("role") for c in calls if c.get("request_id"))),
        # forge orchestrate: state, budget, queue, rounds (before/after scores) and the latest gap list
        "orchestrator": _read_json(store.dir / "orchestrator" / "status.json", None),
        # forge autopilot: rounds, evidence counts, anomalies, decisions + reasons, kept / rolled back, scores
        "autopilot": autopilot_view(store.dir),
    }


def autopilot_view(run_dir: Path) -> dict | None:
    """The Autopilot lane (forge/autopilot.py): status.json plus per-round rows, newest last."""
    st = _read_json(run_dir / "autopilot" / "status.json", None)
    if not isinstance(st, dict):
        return None
    rows = []
    for r in st.get("rounds") or []:
        rows.append({"round": r.get("round"), "verdict": r.get("verdict"), "version": r.get("version"),
                     "evidence": r.get("evidence") or {}, "evidence_items": r.get("evidence_items"),
                     "prefilter": r.get("prefilter"), "anomalies": (r.get("anomalies") or [])[:6],
                     "anomalies_n": len(r.get("anomalies") or []),
                     "gaps": len(r.get("gaps") or []),
                     "decisions": [{k: d.get(k) for k in ("title", "kind", "score", "picked", "reason", "outcome")}
                                   for d in (r.get("decisions") or [])[:8]],
                     "kept": r.get("kept", 0), "rolled_back": r.get("rolled_back", 0),
                     "regressions": r.get("regressions") or [], "what_improved": r.get("what_improved"),
                     "why": r.get("why"), "scores": r.get("scores") or {}})
    return {"state": st.get("state"), "round": st.get("round"), "phase": st.get("phase"),
            "budget": st.get("budget") or {}, "stop_reason": st.get("stop_reason"), "target": st.get("target"),
            "idea": st.get("idea"), "rounds": rows, "trend": st.get("score_trend") or [],
            "kept": sum(r["kept"] for r in rows), "rolled_back": sum(r["rolled_back"] for r in rows),
            "anomalies": sum(r["anomalies_n"] for r in rows)}


def mubit_view(settings: Settings) -> dict:
    files = list(settings.runs_dir.glob("*/calls.jsonl")) + list(settings.runs_dir.glob("*/improve/calls.jsonl")) \
        + list(settings.runs_dir.glob("playtests/*/calls.jsonl"))
    calls = [c for f in files for c in _calls(f) if c.get("request_id")]
    by_role = Counter(c.get("role") for c in calls)
    latest: dict[str, dict] = {}
    for c in sorted(calls, key=lambda c: str(c.get("ts", ""))):
        latest[c.get("role")] = {"request_id": c.get("request_id"), "ts": c.get("ts")}
    roles = sorted(by_role, key=lambda r: (-by_role[r], r))
    return {"train_at": TRAIN_AT, "console": CONSOLE_URL, "total": len(calls),
            "roles": [{"role": r, "calls": by_role[r], "latest": latest.get(r, {})} for r in roles]}


# ---------------------------------------------------------------- live team view (lanes, shots, speed)
#
# Inputs, all optional (each panel falls back to what older runs already write):
# - runs/<slug>/timings.json (forge/loop.py): {"stages": [{name, start, end, secs, before_secs}],
#   "lanes": [{id, role, label, status, step, thought, latency_ms, start, end, calls}],
#   "calls": [{role, lane, label, start, end, latency_ms, step, thought}],
#   "speedups": [{stage, before_secs, after_secs}], "total_secs"}. Times are epoch seconds or ISO.
#   Without it, lanes and stage times come from calls.jsonl (end time and latency of every Mubit call).
# - runs/<slug>/tests/<run>/report.json + step-NN.png (+ optional step-NN.json): the tester swarm.
#   Steps carry action/reason, latency_ms and assertions [{text, ok, detail}].
# - runs/<slug>/iterations/<n>/screenshot.png and critique.json (score, fun).

ROLE_ORDER = ("planner", "designer", "coder", "fixer", "patcher", "tester", "player", "judge", "critic",
              "auditor", "triage", "investigator", "verifier", "reflector")
LANE_SPANS = 40       # call intervals kept per lane for the swimlane strip
SHOTS_PER_TESTER = 8  # newest steps per tester in the screenshot feed
RUNNING_FOR = 90      # seconds: a tester run touched this recently, with no end, is running
_TTL: dict[str, tuple[float, Any]] = {}


def _cached(key: str, ttl: float, fn):
    hit = _TTL.get(key)
    if hit and time.time() - hit[0] < ttl:
        return hit[1]
    val = fn()
    _TTL[key] = (time.time(), val)
    return val


def _epoch(v: Any) -> float | None:
    """ISO string or epoch number -> epoch seconds."""
    if v is None or v == "" or isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    from datetime import datetime, timezone

    try:
        d = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        return None
    return (d if d.tzinfo else d.replace(tzinfo=timezone.utc)).timestamp()


def _num(*vals: Any) -> float | None:
    for v in vals:
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return float(v)
    return None


def _clip(text: Any, n: int = 160) -> str:
    s = " ".join(str(text or "").split())
    return s if len(s) <= n else s[: n - 1] + "…"


def _role_rank(role: str) -> int:
    return ROLE_ORDER.index(role) if role in ROLE_ORDER else len(ROLE_ORDER)


def _trace_for(dirs: list[Path], rid: str | None) -> dict:
    if not rid or not re.fullmatch(r"[\w.-]+", rid):
        return {}
    for d in dirs:
        for p in d.glob(f"*-{rid}.json"):
            t = _read_json(p, {})
            if isinstance(t, dict):
                return t
    return {}


_THOUGHT_KEYS = ("thought", "summary", "reason", "plan", "evidence", "diagnosis", "conclusion", "verdict", "title")


def thought_of(reply: Any) -> str:
    """A one-line 'what it was thinking' from a reply: a JSON summary/reason field, the first Luau
    comment, or the first line."""
    text = str(reply or "").strip()
    if not text:
        return ""
    body = re.sub(r"^```\w*\n|\n?```\s*$", "", text).strip()
    try:
        obj = json.loads(body)
    except ValueError:
        obj = None
    if isinstance(obj, dict):
        for k in _THOUGHT_KEYS:
            if isinstance(obj.get(k), str) and obj[k].strip():
                return _clip(obj[k])
        if isinstance(obj.get("score"), (int, float)):
            return f"score {obj['score']}/10"
    m = re.search(r"^\s*--+\s*(.+)$", body, re.M)
    if m:
        return _clip(m.group(1))
    return _clip(body.splitlines()[0]) if body else ""


def step_of(user: Any) -> str:
    """What a call was working on, from its user message: the file/module or the problem's head."""
    u = str(user or "")
    path = re.search(r"^path:\s*(\S+)", u, re.M)
    prob = re.search(r"^## (?:Problem|Anomaly|Game idea|Feature)[^\n]*\n(.+)", u, re.M)
    if path and prob:
        return _clip(f"{Path(path.group(1)).name}: {prob.group(1)}", 120)
    if path:
        return f"writing {Path(path.group(1)).name}"
    if prob:
        return _clip(prob.group(1), 120)
    return ""


def _intervals(calls: list[dict]) -> list[dict]:
    """Calls -> [{role, start, end, latency_ms, request_id, ok}]: start is the logged end minus latency."""
    out = []
    for c in calls:
        end = _epoch(c.get("ts"))
        if end is None or not c.get("role"):
            continue
        lat = _num(c.get("latency_ms")) or 0.0
        out.append({"role": c["role"], "start": end - lat / 1000, "end": end, "latency_ms": int(lat),
                    "request_id": c.get("request_id"), "ok": not c.get("error")})
    return sorted(out, key=lambda c: (c["start"], c["end"]))


def _pack(ivs: list[dict]) -> list[list[dict]]:
    """Interval partitioning: calls of one role that overlap in time go to separate lanes, so N coders
    writing modules at once show as coder #1..#N."""
    lanes: list[list[dict]] = []
    for iv in ivs:
        for lane in lanes:
            if lane[-1]["end"] <= iv["start"] + 0.5:
                lane.append(iv)
                break
        else:
            lanes.append([iv])
    return lanes


def _union(ivs: list[dict]) -> float:
    total, cur_s, cur_e = 0.0, None, None
    for iv in sorted(ivs, key=lambda c: c["start"]):
        if cur_e is None or iv["start"] > cur_e:
            if cur_e is not None:
                total += cur_e - cur_s
            cur_s, cur_e = iv["start"], iv["end"]
        else:
            cur_e = max(cur_e, iv["end"])
    return total + ((cur_e - cur_s) if cur_e is not None else 0.0)


def read_timings(path: Path) -> dict:
    """timings.json in any of the shapes above -> {stages, lanes, calls, speedups, total_secs}."""
    raw = _read_json(path, None)
    if isinstance(raw, list):
        raw = {"stages": [r for r in raw if isinstance(r, dict) and not r.get("role")],
               "calls": [r for r in raw if isinstance(r, dict) and r.get("role")]}
    if not isinstance(raw, dict):
        return {"stages": [], "lanes": [], "calls": [], "speedups": [], "total_secs": None}
    stages = []
    for s in raw.get("stages") or []:
        if not isinstance(s, dict):
            continue
        start, end = _epoch(s.get("start")), _epoch(s.get("end"))
        secs = _num(s.get("secs"), s.get("seconds"), s.get("wall_s"), s.get("wall_secs"))
        if secs is None and start is not None and end is not None:
            secs = end - start
        stages.append({"stage": str(s.get("stage") or s.get("name") or "?"), "start": start, "end": end,
                       "secs": round(secs, 1) if secs is not None else None,
                       "before_secs": _num(s.get("before_secs"), s.get("baseline_secs"), s.get("serial_secs")),
                       "parallel": s.get("parallel") or s.get("workers"),
                       "running": start is not None and end is None and secs is None})
    speedups = []
    for s in raw.get("speedups") or []:
        if isinstance(s, dict):
            b, a = _num(s.get("before_secs"), s.get("before")), _num(s.get("after_secs"), s.get("after"))
            speedups.append({"stage": str(s.get("stage") or s.get("name") or "total"), "before_secs": b,
                             "after_secs": a, "x": round(b / a, 1) if b and a else None})
    return {"stages": stages, "speedups": speedups,
            "lanes": [ln for ln in raw.get("lanes") or [] if isinstance(ln, dict)],
            "calls": [c for c in raw.get("calls") or raw.get("events") or [] if isinstance(c, dict)],
            "total_secs": _num(raw.get("total_secs"), raw.get("wall_secs"))}


def _span(start: float | None, end: float | None, t0: float) -> list:
    return [round((start if start is not None else t0) - t0, 1), None if end is None else round(end - t0, 1)]


def _lanes_from_timings(t: dict, t0: float) -> list[dict]:
    out = []
    for ln in t["lanes"]:
        role = str(ln.get("role") or "agent")
        start, end = _epoch(ln.get("start")), _epoch(ln.get("end"))
        out.append({"id": str(ln.get("id") or ln.get("label") or role), "role": role,
                    "label": str(ln.get("label") or role), "kind": "tester" if role in ("tester", "player") else "role",
                    "status": str(ln.get("status") or ("running" if start is not None and end is None else "done")),
                    "step": _clip(ln.get("step") or "", 140), "thought": _clip(ln.get("thought") or ""),
                    "latency_ms": int(_num(ln.get("latency_ms")) or 0), "calls": int(_num(ln.get("calls")) or 0),
                    "spans": [_span(start, end, t0)] if start is not None else []})
    groups: dict[str, list[dict]] = {}
    for c in t["calls"]:
        groups.setdefault(str(c.get("lane") or c.get("worker") or c.get("role")), []).append(c)
    for lane_id, cs in groups.items():
        cs.sort(key=lambda c: _epoch(c.get("start")) or 0)
        last = cs[-1]
        role = str(last.get("role") or lane_id)
        out.append({"id": lane_id, "role": role, "label": str(last.get("lane_label") or lane_id),
                    "kind": "tester" if role in ("tester", "player") else "role",
                    "status": "running" if _epoch(last.get("end")) is None else ("failed" if last.get("error") else "done"),
                    "step": _clip(last.get("step") or last.get("label") or "", 140),
                    "thought": _clip(last.get("thought") or ""),
                    "latency_ms": int(_num(last.get("latency_ms")) or 0), "calls": len(cs),
                    "spans": [_span(_epoch(c.get("start")), _epoch(c.get("end")), t0) for c in cs[-LANE_SPANS:]
                              if _epoch(c.get("start")) is not None]})
    return out


def _peak(lanes: list[dict]) -> int:
    """Most lanes busy at the same moment."""
    ev = []
    for ln in lanes:
        for s, e in ln["spans"]:
            ev += [(s, 1), (e if e is not None else 1e12, -1)]
    cur = best = 0
    for _, d in sorted(ev, key=lambda x: (x[0], x[1])):
        cur += d
        best = max(best, cur)
    return best


ROLE_STEP = {"designer": "designing the game", "coder": "writing a module", "critic": "playtesting and scoring",
             "auditor": "hunting for bugs", "triage": "sorting a bug report", "investigator": "finding where a bug hides",
             "verifier": "checking a fix in play", "reflector": "writing lessons for next time", "planner": "planning a feature",
             "fixer": "fixing a bug", "patcher": "patching a big file", "judge": "judging a playtest"}


def lanes_view(run_dir: Path, calls: list[dict], live_role: str | None, timings: dict,
               testers: list[dict], now: float, live_since: float | None = None) -> dict:
    """Every role and tester as a swimlane: what it is on now, what it thought, how long its call took."""
    ivs = _intervals(calls)
    starts = [iv["start"] for iv in ivs] + [s["start"] for s in timings["stages"] if s["start"] is not None]
    starts += [e for e in (_epoch(c.get("start")) for c in timings["calls"] + timings["lanes"]) if e is not None]
    starts += [s["start"] for t in testers for s in t["spans"]]
    t0 = min(starts) if starts else now
    if timings["lanes"] or timings["calls"]:
        lanes = _lanes_from_timings(timings, t0)
    else:
        lanes = []
        trace_dirs = [run_dir / "traces", run_dir / "improve" / "traces"]
        by_role: dict[str, list[dict]] = {}
        for iv in ivs:
            by_role.setdefault(iv["role"], []).append(iv)
        for role, rivs in by_role.items():
            packed = _pack(rivs)
            for i, lane in enumerate(packed):
                last = lane[-1]
                tr = _trace_for(trace_dirs, last["request_id"])
                name = role if len(packed) == 1 else f"{role} #{i + 1}"
                lanes.append({"id": name.replace(" #", "-"), "role": role, "label": name,
                              "kind": "tester" if role in ("player", "judge") else "role",
                              "status": "done" if last["ok"] else "failed",
                              "step": step_of(tr.get("user")) or ROLE_STEP.get(role, ""),
                              "thought": thought_of(tr.get("reply")),
                              "latency_ms": last["latency_ms"], "calls": len(lane),
                              "spans": [_span(iv["start"], iv["end"], t0) for iv in lane[-LANE_SPANS:]]})
        if live_role:  # calls are logged when they end, so the one in flight is only known from the log
            mine = [ln for ln in lanes if ROLE_WORDS.get(ln["role"], ln["role"]) == live_role]
            # the call in flight started after the last logged one ended and before the log last moved
            since = min(now, live_since or now)
            if mine:
                mine[-1]["status"] = "running"
                mine[-1]["step"] = ROLE_STEP.get(mine[-1]["role"], mine[-1]["step"])
                mine[-1]["thought"] = ""
                last_end = max((e for _, e in mine[-1]["spans"] if e is not None), default=since - t0) + t0
                mine[-1]["spans"].append(_span(max(last_end, since), None, t0))
            else:
                lanes.append({"id": live_role, "role": live_role, "label": live_role, "kind": "role",
                              "status": "running", "step": ROLE_STEP.get(live_role, ""), "thought": "",
                              "latency_ms": 0, "calls": 0, "spans": [_span(since, None, t0)]})
    for t in testers:
        last = t["steps"][-1] if t["steps"] else {}
        lanes.append({"id": f"tester-{t['run']}", "role": "tester", "label": t["label"], "kind": "tester",
                      "status": t["status"],
                      "step": f"step {last['n']}: {last['action']}" if last else "starting",
                      "thought": last.get("reason", ""), "latency_ms": last.get("latency_ms") or 0,
                      "calls": t["n_steps"], "passed": t["passed"], "failed": t["failed"],
                      "spans": [_span(s["start"], s["end"], t0) for s in t["spans"]]
                      + ([_span(max(s["end"] for s in t["spans"]), None, t0)]
                         if t["status"] == "running" and t["spans"] else [])})
    lanes.sort(key=lambda ln: (_role_rank(ln["role"]), ln["label"]))
    ends = [e for ln in lanes for _, e in ln["spans"] if e is not None]
    running_n = sum(1 for ln in lanes if ln["status"] == "running")
    span = max(ends + ([now - t0] if running_n else []) + [1.0])
    return {"t0": t0, "span_secs": round(span, 1), "lanes": lanes, "running": running_n,
            "parallel_peak": _peak(lanes)}


def _assertions(step: dict) -> list[dict]:
    raw = step.get("assertions") or step.get("checks") or step.get("asserts") or []
    raw = [raw] if isinstance(raw, dict) else list(raw)
    if isinstance(step.get("assert"), dict):
        raw.append(step["assert"])
    out = []
    for a in raw:
        if isinstance(a, str):
            out.append({"text": _clip(a, 140), "ok": None, "detail": ""})
        elif isinstance(a, dict):
            ok = next((a[k] for k in ("ok", "pass", "passed") if isinstance(a.get(k), bool)), None)
            out.append({"text": _clip(a.get("text") or a.get("name") or a.get("expect") or a.get("assert") or "", 140),
                        "ok": ok, "detail": _clip(a.get("detail") or a.get("actual") or a.get("evidence") or "", 160)})
    return out


def shot_url(slug: str, rel: str) -> str:
    from urllib.parse import quote

    return f"/api/shot?slug={quote(slug)}&path={quote(rel)}"


def testers_view(run_dir: Path, slug: str, now: float) -> list[dict]:
    """Tester runs under runs/<slug>/tests/<run>/: report.json steps + step-NN.png screenshots, oldest first."""
    root = run_dir / "tests"
    if not root.is_dir():
        return []
    out = []
    for i, rdir in enumerate(sorted((p for p in root.iterdir() if p.is_dir()), key=lambda p: p.name)):
        rep = _read_json(rdir / "report.json", {}) or {}
        shots = {int(m.group(1)): p for p in rdir.glob("step-*.png") if (m := re.match(r"step-(\d+)\.png$", p.name))}
        by_n = {}
        for k, s in enumerate(x for x in rep.get("steps") or [] if isinstance(x, dict)):
            by_n[int(_num(s.get("n")) or k + 1)] = s
        for n in shots:
            if n not in by_n:
                by_n[n] = {"n": n, **(_read_json(rdir / f"step-{n:02d}.json", {}) or {})}
        steps, spans = [], []
        for n in sorted(by_n):
            s = by_n[n]
            act = s.get("action") if isinstance(s.get("action"), dict) else {"action": s.get("action")}
            args = act.get("args") if isinstance(act.get("args"), dict) else {}
            asserts = _assertions(s)
            oks = [a["ok"] for a in asserts if a["ok"] is not None]
            ok = all(oks) if oks else (s.get("ok") if isinstance(s.get("ok"), bool) else None)
            what = " ".join(str(x) for x in (act.get("action") or "", args.get("target") or args.get("name") or "") if x)
            steps.append({"n": n, "action": _clip(what or "step", 60),
                          "reason": _clip(act.get("reason") or s.get("reason") or s.get("thought") or ""),
                          "result": _clip(s.get("result") or "", 200), "latency_ms": int(_num(s.get("latency_ms")) or 0),
                          "assertions": asserts, "ok": ok,
                          "shot": shot_url(slug, f"tests/{rdir.name}/{shots[n].name}") if n in shots else None})
            end = _epoch(s.get("ts") or s.get("ended"))
            if end is not None:
                dur = (_num(s.get("step_ms"), s.get("latency_ms")) or 0) / 1000
                spans.append({"start": end - dur, "end": end})
        files = list(rdir.iterdir())
        mtime = max([p.stat().st_mtime for p in files] or [rdir.stat().st_mtime])
        started, ended = _epoch(rep.get("started")), _epoch(rep.get("ended"))
        if not spans and started is not None:  # no per-step times: one bar for the whole run
            spans = [{"start": started, "end": ended or mtime}]
        if ended is not None or rep.get("ended"):
            status = "failed" if rep.get("goal_met") is False else "done"
        else:
            status = "running" if now - mtime < RUNNING_FOR else "stopped"
        out.append({"run": rdir.name,
                    "label": str(rep.get("tester") or rep.get("persona") or rep.get("player_name") or f"tester #{i + 1}"),
                    "goal": _clip(rep.get("goal") or "", 140), "status": status, "started": started or mtime,
                    "n_steps": len(steps), "passed": sum(1 for s in steps for a in s["assertions"] if a["ok"] is True),
                    "failed": sum(1 for s in steps for a in s["assertions"] if a["ok"] is False),
                    "goal_met": rep.get("goal_met"), "summary": _clip(rep.get("summary") or "", 240),
                    "steps": steps[-SHOTS_PER_TESTER:], "spans": spans[-LANE_SPANS:], "updated": mtime})
    return out


def iteration_shots(run_dir: Path, slug: str) -> list[dict]:
    """The critic's playtest screenshot per build iteration."""
    out = [{"n": int(p.parent.name), "shot": shot_url(slug, f"iterations/{p.parent.name}/screenshot.png")}
           for p in (run_dir / "iterations").glob("*/screenshot.png") if p.parent.name.isdigit()]
    return sorted(out, key=lambda s: s["n"])


def _numstat(game_dir: Path, tag: str) -> dict:
    """Lines added/removed by a version (versions are a straight line of commits; tags never move)."""
    from forge.versions import GameVersions, VersionError

    key = (str(game_dir), "numstat:" + tag)
    if key not in _DIFF_CACHE:
        try:
            out = GameVersions(game_dir)._git("diff-tree", "-r", "--root", "--no-commit-id", "--numstat", tag)
        except (VersionError, OSError):
            return {"added": 0, "removed": 0}
        add = rem = 0
        for ln in out.splitlines():
            parts = ln.split("\t")
            if len(parts) == 3 and parts[2] != ".gitignore":
                add += int(parts[0]) if parts[0].isdigit() else 0
                rem += int(parts[1]) if parts[1].isdigit() else 0
        _DIFF_CACHE[key] = [str(add), str(rem)]
    a, r = _DIFF_CACHE[key]
    return {"added": int(a), "removed": int(r)}


def _fun(critique: Any) -> float | None:
    if not isinstance(critique, dict):
        return None
    scores = critique.get("scores") if isinstance(critique.get("scores"), dict) else {}
    return _num(critique.get("fun"), critique.get("fun_score"), scores.get("fun"))


def timeline_view(run_dir: Path, game_dir: Path, missions_: list[dict], iterations: list[dict]) -> list[dict]:
    """Per version: critic and fun score, the change in score, what improved, and its diff size."""
    by_v: dict[str, dict] = {}
    for it in iterations:
        if it.get("version"):
            crit = _read_json(run_dir / "iterations" / str(it.get("n")) / "critique.json", {})
            by_v[it["version"]] = {"score": _num(it.get("score")), "fun": _num(it.get("fun")) or _fun(crit),
                                   "iteration": it.get("n"), "summary": _clip(it.get("summary") or "", 200)}
    out, prev = [], None
    for m in missions_:
        sc = by_v.get(m["version"], {})
        score = sc.get("score") if sc.get("score") is not None else _num(m.get("score"))
        out.append({"version": m["version"], "kind": m["kind"], "title": m["title"], "date": m.get("date"),
                    "score": score, "fun": sc.get("fun"), "iteration": sc.get("iteration"),
                    "summary": sc.get("summary", ""),
                    "delta": round(score - prev, 1) if score is not None and prev is not None else None,
                    "files": m["files"], **_numstat(game_dir, m["version"]), "fixes": m["fixes"][:4],
                    "current": m["current"]})
        if score is not None:
            prev = score
    return out


def speed_view(calls: list[dict], timings: dict, lanes: dict) -> dict:
    """Wall clock per stage, and how much running agents side by side saved against one at a time."""
    stages = [dict(s) for s in timings["stages"]]
    ivs = _intervals(calls)
    if not stages:
        by_role: dict[str, list[dict]] = {}
        for iv in ivs:
            by_role.setdefault(iv["role"], []).append(iv)
        for role in sorted(by_role, key=_role_rank):
            rivs = by_role[role]
            stages.append({"stage": role, "start": rivs[0]["start"], "end": max(iv["end"] for iv in rivs),
                           "secs": round(_union(rivs), 1),
                           "before_secs": round(sum(iv["latency_ms"] for iv in rivs) / 1000, 1),
                           "parallel": len(_pack(rivs)), "running": False})
    for s in stages:
        b, a = s.get("before_secs"), s.get("secs")
        s["x"] = round(b / a, 1) if b and a and b > a * 1.05 else None
    speedups = list(timings["speedups"])
    serial = sum(iv["latency_ms"] for iv in ivs) / 1000
    wall = timings.get("total_secs") or _union(ivs)
    if not speedups and serial and wall and serial > wall * 1.05:
        speedups.append({"stage": "all Mubit calls", "before_secs": round(serial, 1), "after_secs": round(wall, 1),
                         "x": round(serial / wall, 1)})
    lat = sorted(iv["latency_ms"] for iv in ivs)
    return {"stages": stages, "speedups": speedups, "wall_secs": round(wall or 0, 1),
            "serial_secs": round(serial, 1), "calls": len(ivs), "peak_parallel": lanes["parallel_peak"],
            "p50_ms": lat[len(lat) // 2] if lat else None, "p90_ms": lat[min(len(lat) - 1, int(len(lat) * .9))] if lat else None}


def ledger_view(settings: Settings) -> dict:
    """forge ledger (cached a few seconds): per Mubit task, calls, corrections fed and verified (kept)
    examples, and the latest 'correction -> model update' moments."""
    from forge import ledger as ledger_mod

    def build() -> dict:
        empty = {"roles": [], "moments": [], "corrections": 0, "verified": 0, "total_calls": 0,
                 "train_at": TRAIN_AT, "console": CONSOLE_URL}
        if not settings.runs_dir.is_dir():
            return empty
        try:
            data = ledger_mod.ledger(settings)
            calls = ledger_mod.traces(settings.runs_dir)
        except OSError:
            return empty
        stamps: dict[str, list[str]] = {}
        for c in calls:
            stamps.setdefault(c.get("role"), []).append(str(c.get("ts") or ""))
        moments = []
        for e in sorted(data["entries"], key=lambda e: str(e.get("ts") or "")):
            if e["kind"] != "correction" and not e.get("verified"):
                continue
            n = sum(1 for ts in stamps.get(e["role"], []) if ts <= str(e.get("ts") or ""))
            moments.append({"slug": e.get("slug"), "role": e["role"],
                            "kind": "correction" if e["kind"] == "correction" else "verified",
                            "ts": e.get("ts"), "request_id": e.get("request_id"),
                            "what": _clip(e.get("anomaly") or e.get("why") or "", 140), "verdict": e.get("verdict"),
                            "verified": bool(e.get("verified")), "example_n": n, "train_at": TRAIN_AT, "trains": n >= TRAIN_AT})
        roles = [{**r, "kept": r["verified"], "train_at": TRAIN_AT, "trains": r["calls"] >= TRAIN_AT}
                 for r in data["roles"]]
        return {**empty, "roles": roles, "moments": moments[-12:][::-1], "corrections": data["corrections"],
                "verified": data["verified"], "total_calls": data["total_calls"]}

    return _cached(f"ledger:{settings.runs_dir}", 5.0, build)


def team_view(settings: Settings, slug: str, game: dict, now: float | None = None) -> dict:
    """The live panels for one game: agent lanes, screenshot feed, version timeline, speed."""
    now = now or time.time()
    store = RunStore(settings, slug)
    calls = _calls(store.calls_log) + _calls(store.dir / "improve" / "calls.jsonl")
    timings = read_timings(store.dir / "timings.json")
    orch = read_timings(store.dir / "orchestrator" / "timings.json")  # forge orchestrate: one lane per worker
    for key in ("stages", "lanes", "calls"):
        timings[key] = timings[key] + orch[key]
    testers = testers_view(store.dir, slug, now)
    live = game.get("live") or {}
    lanes = lanes_view(store.dir, calls, live.get("role"), timings, testers, now, live.get("updated"))
    state = _read_json(store.state_path, {}) or {}
    return {"lanes": lanes, "testers": testers, "critic_shots": iteration_shots(store.dir, slug),
            "timeline": timeline_view(store.dir, store.game_dir, game["missions"], state.get("iterations", [])),
            "speed": speed_view(calls, timings, lanes), "has_timings": (store.dir / "timings.json").exists()}


def collect(settings: Settings | None = None) -> dict:
    s = settings or load_settings()
    now = time.time()
    runs = running(s, now)
    games = [game_view(s, slug, runs) for slug in RunStore.list_games(s)]
    for g in games:
        g["team"] = team_view(s, g["slug"], g, now)
    games.sort(key=lambda g: (g["live"] is None, -g["updated"]))
    return {"now": now, "running": runs, "games": games, "mubit": {**mubit_view(s), "ledger": ledger_view(s)}}


def shot_path(settings: Settings, slug: str, rel: str) -> Path | None:
    """A screenshot the page may show: a .png under runs/<slug>/tests/ or runs/<slug>/iterations/."""
    if slug not in RunStore.list_games(settings) or not rel.endswith(".png"):
        return None
    base = (settings.runs_dir / slug).resolve()
    p = (base / rel).resolve()
    if not p.is_file() or not any(p.is_relative_to(base / d) for d in ("tests", "iterations")):
        return None
    return p


class RollbackError(ValueError):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


def rollback(settings: Settings, slug: str, version: str) -> dict:
    """Same path as `forge rollback <slug> <version> --no-sync`: restore the files, saved as a NEW
    version. Studio picks them up through `forge watch`; nothing is synced from here."""
    from forge.versions import GameVersions, VersionError

    if slug not in RunStore.list_games(settings):
        raise RollbackError(404, f"no game {slug!r}")
    if not re.fullmatch(r"v\d+", version or ""):
        raise RollbackError(400, f"bad version {version!r}")
    if live_for(settings, slug, running(settings)):
        raise RollbackError(409, "Forge is building this game right now; wait until the run finishes")
    try:
        tag = GameVersions(RunStore(settings, slug).game_dir).restore(version, "from the dashboard")
    except VersionError as e:
        raise RollbackError(400, str(e)) from e
    return {"slug": slug, "restored": version, "as": tag}


# ---------------------------------------------------------------- server

PAGE = Path(__file__).parent / "dashboard.html"
LOCAL = ("127.0.0.1", "::1", "::ffff:127.0.0.1")


def make_handler(settings: Settings):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args) -> None:  # keep the terminal quiet
            pass

        def _send(self, code: int, body: bytes, ctype: str, cache: str = "no-store") -> None:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", cache)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            route, _, query = self.path.partition("?")
            if route == "/api/state":
                self._send(200, json.dumps(collect(settings), default=str).encode(), "application/json")
            elif route == "/api/shot":
                from urllib.parse import parse_qs

                q = parse_qs(query)
                p = shot_path(settings, (q.get("slug") or [""])[0], (q.get("path") or [""])[0])
                if p is None:
                    self._send(404, b"no such screenshot", "text/plain")
                else:
                    self._send(200, p.read_bytes(), "image/png", "max-age=300")  # a step's shot never changes
            elif self.path in ("/", "/index.html"):
                self._send(200, PAGE.read_bytes(), "text/html; charset=utf-8")
            else:
                self._send(404, b"not found", "text/plain")

        def _json(self, code: int, obj: dict) -> None:
            self._send(code, json.dumps(obj).encode(), "application/json")

        def do_POST(self) -> None:  # noqa: N802
            if self.path.split("?")[0] != "/api/rollback":
                self._send(404, b"not found", "text/plain")
                return
            # --host 0.0.0.0 shares the page; a rollback still has to come from this machine.
            if self.client_address[0] not in LOCAL:
                self._json(403, {"error": "rollback only works from this computer (127.0.0.1)"})
                return
            try:
                size = min(int(self.headers.get("Content-Length") or 0), 10_000)
                body = json.loads(self.rfile.read(size) or b"{}")
                self._json(200, rollback(settings, str(body.get("slug", "")), str(body.get("version", ""))))
            except RollbackError as e:
                self._json(e.code, {"error": str(e)})
            except (ValueError, AttributeError):
                self._json(400, {"error": "send JSON {slug, version}"})

    return Handler


def serve(host: str = "127.0.0.1", port: int = 8765, settings: Settings | None = None) -> ThreadingHTTPServer:
    return ThreadingHTTPServer((host, port), make_handler(settings or load_settings()))
