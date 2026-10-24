"""`forge dashboard`: a live, read-only view of everything Forge is doing, at http://127.0.0.1:8765.

It reads what Forge already writes under runs/ and never changes anything:
- running work: MCP background jobs (runs/jobs/) and CLI logs (runs/*.log), with live log tails;
- per game: iterations (critic score, version, rollbacks), saved versions, improve/fix cycles
  (anomalies, fix attempts, verifier verdicts), tester reports;
- Mubit: calls per role against the 25 examples a task needs before it trains, latest request ids;
- per version, a "mission": what it improved in a few plain words, files changed, fixes kept.

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
    runs = running(s)
    games = [game_view(s, slug, runs) for slug in RunStore.list_games(s)]
    games.sort(key=lambda g: (g["live"] is None, -g["updated"]))
    return {"now": time.time(), "running": runs, "games": games, "mubit": mubit_view(s)}


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
