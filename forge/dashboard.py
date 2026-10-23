"""`forge dashboard`: a live, read-only view of everything Forge is doing, at http://127.0.0.1:8765.

It reads what Forge already writes under runs/ and never changes anything:
- running work: MCP background jobs (runs/jobs/) and CLI logs (runs/*.log), with live log tails;
- per game: iterations (critic score, version, rollbacks), saved versions, improve/fix cycles
  (anomalies, fix attempts, verifier verdicts), tester reports;
- Mubit: calls per role against the 25 examples a task needs before it trains, latest request ids.

The page polls /api/state every few seconds. Standard library only.
"""

from __future__ import annotations

import json
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


def game_view(settings: Settings, slug: str) -> dict:
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
    return {
        "slug": slug, "title": spec.get("title") or slug, "pitch": spec.get("pitch", ""),
        "seeded": bool(spec.get("base_files")), "updated": max(mtimes) if mtimes else 0,
        "iterations": [{k: it.get(k) for k in ("n", "score", "version", "rolled_back_to", "fixes",
                                                "summary", "studio", "ended")}
                       for it in state.get("iterations", [])],
        "corrections": [{k: c.get(k) for k in ("path", "note", "request_id", "kind")}
                        for c in state.get("corrections", [])],
        "versions": _versions(store.game_dir),
        "cycles": cycles,
        "reports": [{"ts": r.get("ts"), "reporter": r.get("reporter"), "text": r.get("text"),
                     "anomalies": (r.get("triage") or {}).get("anomalies", []),
                     "auditor_missed": r.get("auditor_missed", [])} for r in reports],
        "calls": dict(Counter(c.get("role") for c in calls if c.get("request_id"))),
    }


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


def collect(settings: Settings | None = None) -> dict:
    s = settings or load_settings()
    games = [game_view(s, slug) for slug in RunStore.list_games(s)]
    games.sort(key=lambda g: -g["updated"])
    return {"now": time.time(), "running": running(s), "games": games, "mubit": mubit_view(s)}


# ---------------------------------------------------------------- server

PAGE = Path(__file__).parent / "dashboard.html"


def make_handler(settings: Settings):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args) -> None:  # keep the terminal quiet
            pass

        def _send(self, code: int, body: bytes, ctype: str) -> None:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            if self.path.split("?")[0] == "/api/state":
                self._send(200, json.dumps(collect(settings), default=str).encode(), "application/json")
            elif self.path in ("/", "/index.html"):
                self._send(200, PAGE.read_bytes(), "text/html; charset=utf-8")
            else:
                self._send(404, b"not found", "text/plain")

    return Handler


def serve(host: str = "127.0.0.1", port: int = 8765, settings: Settings | None = None) -> ThreadingHTTPServer:
    return ThreadingHTTPServer((host, port), make_handler(settings or load_settings()))
