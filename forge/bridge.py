"""Forge <-> Roblox Studio plugin bridge (protocol: docs/STUDIO_PLUGIN.md).

A small local HTTP server on 127.0.0.1 that the ForgeBridge Studio plugin (studio-plugin/
ForgeBridge.plugin.luau) long-polls. It gives Forge two things StudioMCP can't:

* a live event stream from Studio (output, errors, play state, selection, script tree changes,
  dock-widget button presses), read with `GET /events?since=N`;
* fast command execution: `POST /run` queues a command and the waiting long-poll picks it up at
  once, so there is no MCP process / JSON-RPC round trip per command.

Safety: every request needs the bridge token (header X-Forge-Token). The token is baked into the
plugin file by `forge plugin install`, and the plugin only *binds* (creates UI, streams events, runs
commands) when the server says its place is on the allow list (`forge plugin serve --place NAME`).
Any other Studio window, or any window while the server is down, stays a silent no-op.

Pieces:
  Bridge        thread-safe state (sessions, command queues, results, event ring). No I/O.
  make_server   ThreadingHTTPServer exposing Bridge over HTTP.
  BridgeClient  urllib client used by forge/studio.py, the CLI and the MCP tools.
  Actions       what the dock widget buttons do (Run tests, Ask Forge to fix this).
  register(mcp) adds studio_events / studio_run / studio_status to an MCP server.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import uuid
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen

PROTOCOL = 1
DEFAULT_PORT = int(os.environ.get("FORGE_BRIDGE_PORT", "34880"))
DATAMODELS = ("Edit", "Server", "Client")
OPS = ("ping", "run", "state", "tree", "play")
POLL_WAIT = 15.0          # seconds a long-poll is held open
SESSION_TTL = 25.0        # a session that hasn't polled for this long is gone
MAX_EVENTS = 5000
MAX_BATCH = 200           # events accepted per POST
MAX_FIELD = 4000          # characters kept per event string field
DEFAULT_RUN_TIMEOUT = 30.0
PLAY_WAIT = 30.0


class BridgeError(RuntimeError):
    pass


class LuauError(BridgeError):
    """The command reached Studio and the Luau itself failed (compile or runtime error)."""


def place_key(name: str | None) -> str:
    """'Forge-agents-25.rbxlx' -> 'forge-agents-25' (what the allow list compares)."""
    s = str(name or "").strip().lower()
    return re.sub(r"\.(rbxlx|rbxl)$", "", s)


def place_allowed(name: str | None, places: set[str] | list[str] | tuple[str, ...]) -> bool:
    """Exact place keys, or prefixes ending in '*' ('forge*' allows Forge and every Forge-agents-N)."""
    key = place_key(name)
    for p in places:
        if p.endswith("*") and key.startswith(p[:-1]):
            return True
        if p == key:
            return True
    return False


def _clip(v: Any) -> Any:
    if isinstance(v, str):
        return v if len(v) <= MAX_FIELD else v[:MAX_FIELD] + "…"
    if isinstance(v, dict):
        return {str(k)[:64]: _clip(x) for k, x in list(v.items())[:50]}
    if isinstance(v, list):
        return [_clip(x) for x in v[:50]]
    return v


# --------------------------------------------------------------------------- state


class Bridge:
    """All bridge state. Thread-safe; every method may be called from any HTTP thread."""

    def __init__(self, token: str, places: list[str] | tuple[str, ...] = (),
                 clock: Callable[[], float] = time.monotonic, poll_wait: float = POLL_WAIT,
                 session_ttl: float = SESSION_TTL) -> None:
        self.token = token
        self.places = {place_key(p) for p in places if p}
        self.clock = clock
        self.poll_wait = poll_wait
        self.session_ttl = session_ttl
        self.cond = threading.Condition()
        self.sessions: dict[str, dict] = {}
        self.queue: deque[dict] = deque()
        self.pending: dict[str, dict] = {}       # command id -> command (delivered or not)
        self.results: dict[str, dict] = {}
        self.events: deque[dict] = deque(maxlen=MAX_EVENTS)
        self.seq = 0
        self.forge: dict[str, Any] = {"job": None, "role": None, "last_test": None, "message": None,
                                      "last_error": None}
        self.forge_version = 0
        self.started = time.time()
        self.listeners: list[Callable[[dict], None]] = []

    # ---- helpers (call with self.cond held)

    def _emit(self, ev: dict) -> dict:
        self.seq += 1
        ev = {"seq": self.seq, "time": round(time.time(), 3), **ev}
        self.events.append(ev)
        self.cond.notify_all()
        return ev

    def _expire(self) -> None:
        now = self.clock()
        for sid, s in list(self.sessions.items()):
            if now - s["last_seen"] > self.session_ttl:
                self._drop(sid, "timeout")

    def _drop(self, sid: str, why: str) -> None:
        s = self.sessions.pop(sid, None)
        if not s:
            return
        self._emit({"type": "session", "state": "gone", "dm": s["dm"], "place": s["place"],
                    "session": sid, "why": why})
        if s["dm"] == "Server":
            self._emit({"type": "play", "state": "stopped", "place": s["place"]})
        for cid, cmd in list(self.pending.items()):  # commands it held will never answer
            if cmd.get("session") == sid:
                self.pending.pop(cid, None)
                self.results[cid] = {"id": cid, "ok": False, "error": f"Studio {s['dm']} datamodel went away ({why})"}

    def _live(self, dm: str | None = None) -> list[dict]:
        self._expire()
        out = [s for s in self.sessions.values() if dm is None or s["dm"] == dm]
        return sorted(out, key=lambda s: s["since"], reverse=True)

    def _fire(self, events: list[dict]) -> None:
        for ev in events:
            for fn in list(self.listeners):
                try:
                    fn(ev)
                except Exception as e:  # a listener must never break the plugin's request
                    print(f"[bridge] listener failed: {e}", file=sys.stderr)

    # ---- plugin side

    def hello(self, place: str, dm: str, session: str, version: int = PROTOCOL) -> dict:
        if dm not in DATAMODELS:
            raise BridgeError(f"bad datamodel {dm!r}")
        bound = place_allowed(place, self.places)
        reply = {"protocol": PROTOCOL, "bound": bound, "poll_wait": self.poll_wait}
        if not bound:
            return reply
        with self.cond:
            fresh = session not in self.sessions
            if fresh and dm in ("Edit", "Server"):  # one window has one of each: a reload replaces
                for sid, s in list(self.sessions.items()):
                    if s["dm"] == dm and place_key(s["place"]) == place_key(place):
                        self._drop(sid, "replaced")
            self.sessions[session] = {"session": session, "place": str(place), "dm": dm,
                                      "version": version, "since": self.clock(), "last_seen": self.clock()}
            if fresh:
                self._emit({"type": "session", "state": "up", "dm": dm, "place": str(place), "session": session})
                if dm == "Server":
                    self._emit({"type": "play", "state": "started", "place": str(place)})
            reply["forge"] = dict(self.forge, version=self.forge_version)
        return reply

    def poll(self, session: str, wait: float | None = None, forge_version: int = -1) -> dict:
        """Long-poll: returns as soon as a command for this session's datamodel is queued or the
        Forge status changed, else after `wait` seconds with no commands."""
        wait = self.poll_wait if wait is None else max(0.0, min(float(wait), 60.0))
        deadline = self.clock() + wait
        with self.cond:
            while True:
                s = self.sessions.get(session)
                if s is None:
                    return {"unknown_session": True, "commands": []}
                s["last_seen"] = self.clock()
                cmds = [c for c in self.queue if c["dm"] == s["dm"]]
                if cmds or forge_version != self.forge_version:
                    for c in cmds:
                        self.queue.remove(c)
                        c["session"] = session
                        c["delivered"] = self.clock()
                    return {"commands": [{"id": c["id"], "op": c["op"], "args": c["args"]} for c in cmds],
                            "forge": dict(self.forge, version=self.forge_version)}
                left = deadline - self.clock()
                if left <= 0:
                    return {"commands": []}
                self.cond.wait(min(left, 1.0))

    def result(self, session: str, payload: dict) -> None:
        cid = str(payload.get("id") or "")
        with self.cond:
            if session in self.sessions:
                self.sessions[session]["last_seen"] = self.clock()
            cmd = self.pending.pop(cid, None)
            if cmd is None:
                return
            self.results[cid] = {"id": cid, "ok": bool(payload.get("ok")), "result": payload.get("result"),
                                 "error": payload.get("error"), "studio_ms": payload.get("ms"),
                                 "dm": cmd["dm"],
                                 # where the time went: waiting for a poll to pick it up, then the
                                 # trip into Studio, the run and the result POST back
                                 "pickup_ms": round((cmd.get("delivered", cmd["queued"]) - cmd["queued"]) * 1000, 1),
                                 "return_ms": round((self.clock() - cmd.get("delivered", cmd["queued"])) * 1000, 1)}
            self.cond.notify_all()

    def add_events(self, session: str, events: list[dict]) -> int:
        out = []
        last_error = None
        with self.cond:
            s = self.sessions.get(session)
            if s is None:
                return 0
            s["last_seen"] = self.clock()
            for ev in list(events)[:MAX_BATCH]:
                if not isinstance(ev, dict) or not ev.get("type"):
                    continue
                ev = _clip({k: v for k, v in ev.items() if k not in ("seq", "time")})
                ev.setdefault("dm", s["dm"])
                out.append(self._emit(ev))
                if ev["type"] == "error":
                    last_error = {"message": str(ev.get("message", ""))[:600], "script": ev.get("script"),
                                  "trace": str(ev.get("trace", ""))[:600], "dm": ev["dm"]}
        if last_error and last_error != self.forge.get("last_error"):
            # play errors happen in the Server datamodel; this carries them to the Edit widget
            self.set_forge(last_error=last_error)
        self._fire(out)
        return len(out)

    def bye(self, session: str) -> None:
        with self.cond:
            self._drop(session, "bye")

    # ---- forge side

    def submit(self, op: str, args: dict | None = None, dm: str = "Edit") -> str:
        if op not in OPS:
            raise BridgeError(f"unknown op {op!r}; one of {', '.join(OPS)}")
        if dm not in DATAMODELS:
            raise BridgeError(f"bad datamodel {dm!r}")
        with self.cond:
            if not self._live(dm):
                raise BridgeError(f"no ForgeBridge plugin connected in the {dm} datamodel")
            cid = uuid.uuid4().hex[:12]
            cmd = {"id": cid, "op": op, "args": dict(args or {}), "dm": dm, "queued": self.clock()}
            self.queue.append(cmd)
            self.pending[cid] = cmd
            self.cond.notify_all()
            return cid

    def wait_result(self, cid: str, timeout: float = DEFAULT_RUN_TIMEOUT) -> dict:
        deadline = self.clock() + timeout
        with self.cond:
            while cid not in self.results:
                left = deadline - self.clock()
                if left <= 0:
                    cmd = self.pending.pop(cid, None)
                    if cmd is not None and cmd in self.queue:
                        self.queue.remove(cmd)
                    raise BridgeError(f"command {cid} timed out after {timeout:.0f}s")
                self._expire()
                self.cond.wait(min(left, 0.5))
            return self.results.pop(cid)

    def run(self, op: str, args: dict | None = None, dm: str = "Edit",
            timeout: float = DEFAULT_RUN_TIMEOUT) -> dict:
        """Run one command and wait for its result. `play` is routed and waited on specially:
        start goes to Edit and waits for the Server datamodel to connect; stop goes to Server and
        waits for it to go away."""
        args = dict(args or {})
        t0 = time.perf_counter()
        if op == "play":
            start = bool(args.get("start", True))
            with self.cond:
                playing = bool(self._live("Server"))
            if playing == start:
                return {"ok": True, "result": "already " + ("playing" if start else "stopped"), "ms": 0.0}
            dm = "Edit" if start else "Server"
        res = self.wait_result(self.submit(op, args, dm), timeout)
        if op == "play" and res.get("ok"):
            self.wait_play(bool(args.get("start", True)), min(timeout, PLAY_WAIT))
        res["ms"] = round((time.perf_counter() - t0) * 1000, 1)
        return res

    def wait_play(self, playing: bool, timeout: float = PLAY_WAIT) -> None:
        deadline = self.clock() + timeout
        with self.cond:
            while bool(self._live("Server")) != playing:
                left = deadline - self.clock()
                if left <= 0:
                    raise BridgeError(f"play did not {'start' if playing else 'stop'} within {timeout:.0f}s")
                self.cond.wait(min(left, 0.5))

    def set_forge(self, **fields: Any) -> dict:
        with self.cond:
            changed = False
            for k, v in fields.items():
                if k in ("version",):
                    continue
                v = _clip(v)
                if self.forge.get(k) != v:
                    self.forge[k] = v
                    changed = True
            if changed:
                self.forge_version += 1
                self._emit({"type": "forge", **self.forge})
                self.cond.notify_all()
            return dict(self.forge, version=self.forge_version)

    def get_events(self, since: int = 0, types: list[str] | None = None, limit: int = 200,
                   wait: float = 0.0) -> dict:
        """Events with seq > since (oldest first). With wait > 0, blocks until at least one arrives."""
        deadline = self.clock() + max(0.0, min(wait, 60.0))
        with self.cond:
            while True:
                evs = [e for e in self.events if e["seq"] > since and (not types or e["type"] in types)]
                if evs or self.clock() >= deadline:
                    break
                self.cond.wait(min(deadline - self.clock(), 1.0))
            evs = evs[:max(1, limit)]
            nxt = evs[-1]["seq"] if evs else max(since, 0)
            if not evs and since > self.seq:
                nxt = self.seq
            return {"events": evs, "next": nxt, "latest": self.seq}

    def status(self) -> dict:
        with self.cond:
            live = self._live()
            now = self.clock()
            return {
                "protocol": PROTOCOL, "places": sorted(self.places),
                "connected": bool(live), "playing": any(s["dm"] == "Server" for s in live),
                "sessions": [{"dm": s["dm"], "place": s["place"], "session": s["session"],
                              "idle_s": round(now - s["last_seen"], 1)} for s in live],
                "queued": len(self.queue), "events": self.seq,
                "forge": dict(self.forge, version=self.forge_version),
                "uptime_s": round(time.time() - self.started, 1),
            }


# --------------------------------------------------------------------------- HTTP server


def _handler(bridge: Bridge) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "ForgeBridge/1"

        def log_message(self, *a: Any) -> None:  # quiet
            pass

        def _send(self, code: int, obj: Any) -> None:
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _body(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 4_000_000:
                raise BridgeError("body too large")
            raw = self.rfile.read(n) if n else b""
            obj = json.loads(raw or b"{}")
            if not isinstance(obj, dict):
                raise BridgeError("body must be a JSON object")
            return obj

        def _dispatch(self, method: str) -> None:
            url = urlparse(self.path)
            q = {k: v[-1] for k, v in parse_qs(url.query).items()}
            if url.path == "/health":
                return self._send(200, {"ok": True, "protocol": PROTOCOL, "service": "forge-bridge"})
            if not secrets.compare_digest(self.headers.get("X-Forge-Token") or "", bridge.token):
                return self._send(401, {"error": "bad or missing X-Forge-Token"})
            body = self._body() if method == "POST" else {}
            p = url.path
            try:
                if p == "/plugin/hello" and method == "POST":
                    return self._send(200, bridge.hello(str(body.get("place", "")), str(body.get("dm", "")),
                                                        str(body.get("session", "")), int(body.get("version") or 0)))
                if p == "/plugin/poll":
                    return self._send(200, bridge.poll(q.get("session", ""), float(q.get("wait", bridge.poll_wait)),
                                                       int(q.get("fv", -1))))
                if p == "/plugin/result" and method == "POST":
                    bridge.result(str(body.get("session", "")), body)
                    return self._send(200, {"ok": True})
                if p == "/plugin/events" and method == "POST":
                    n = bridge.add_events(str(body.get("session", "")), body.get("events") or [])
                    return self._send(200, {"ok": True, "accepted": n})
                if p == "/plugin/bye" and method == "POST":
                    bridge.bye(str(body.get("session", "")))
                    return self._send(200, {"ok": True})
                if p == "/status" and method == "GET":
                    return self._send(200, bridge.status())
                if p == "/status" and method == "POST":
                    return self._send(200, bridge.set_forge(**body))
                if p == "/events":
                    types = [t for t in q.get("types", "").split(",") if t]
                    return self._send(200, bridge.get_events(int(q.get("since", 0)), types or None,
                                                             int(q.get("limit", 200)), float(q.get("wait", 0))))
                if p == "/run" and method == "POST":
                    res = bridge.run(str(body.get("op", "run")), body.get("args") or {},
                                     str(body.get("dm", "Edit")), float(body.get("timeout") or DEFAULT_RUN_TIMEOUT))
                    return self._send(200, res)
            except BridgeError as e:
                return self._send(409, {"ok": False, "error": str(e)})
            except (ValueError, TypeError) as e:
                return self._send(400, {"ok": False, "error": f"{type(e).__name__}: {e}"})
            return self._send(404, {"error": f"no route {method} {p}"})

        def do_GET(self) -> None:
            self._dispatch("GET")

        def do_POST(self) -> None:
            try:
                self._dispatch("POST")
            except (BridgeError, ValueError) as e:
                self._send(400, {"ok": False, "error": str(e)})

    return Handler


def make_server(bridge: Bridge, port: int = DEFAULT_PORT, host: str = "127.0.0.1") -> ThreadingHTTPServer:
    server = ThreadingHTTPServer((host, port), _handler(bridge))
    server.daemon_threads = True
    return server


def serve_in_thread(bridge: Bridge, port: int = DEFAULT_PORT) -> ThreadingHTTPServer:
    server = make_server(bridge, port)
    threading.Thread(target=server.serve_forever, name="forge-bridge", daemon=True).start()
    return server


# --------------------------------------------------------------------------- token / store


def store_dir(repo_root: Path | None = None) -> Path:
    if repo_root is None:
        from forge.config import load_settings
        repo_root = load_settings().repo_root
    d = Path(repo_root) / "runs" / "studio-bridge"
    d.mkdir(parents=True, exist_ok=True)
    return d


def load_token(store: Path | None = None, create: bool = True) -> str | None:
    """The bridge token (runs/studio-bridge/token, 0600). FORGE_BRIDGE_TOKEN overrides."""
    if os.environ.get("FORGE_BRIDGE_TOKEN"):
        return os.environ["FORGE_BRIDGE_TOKEN"]
    path = (store or store_dir()) / "token"
    if path.is_file():
        return path.read_text().strip() or None
    if not create:
        return None
    tok = secrets.token_hex(16)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(tok)
    return tok


# --------------------------------------------------------------------------- client


class BridgeClient:
    """Talks to a running bridge server. All methods raise BridgeError on failure."""

    def __init__(self, port: int = DEFAULT_PORT, token: str | None = None, timeout: float = 5.0) -> None:
        self.port = port
        self.token = token if token is not None else (load_token(create=False) or "")
        self.timeout = timeout

    def _call(self, method: str, path: str, body: dict | None = None, timeout: float | None = None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        req = Request(f"http://127.0.0.1:{self.port}{path}", data=data, method=method,
                      headers={"X-Forge-Token": self.token, "Content-Type": "application/json"})
        try:
            with urlopen(req, timeout=timeout or self.timeout) as r:
                return json.load(r)
        except HTTPError as e:
            try:
                msg = json.load(e).get("error")
            except Exception:
                msg = e.reason
            raise BridgeError(f"bridge {e.code}: {msg}") from e
        except (URLError, TimeoutError, ConnectionError, OSError) as e:
            raise BridgeError(f"bridge not reachable on 127.0.0.1:{self.port}: {e}") from e

    def health(self) -> bool:
        try:
            return bool(self._call("GET", "/health", timeout=1.0).get("ok"))
        except BridgeError:
            return False

    def status(self) -> dict:
        return self._call("GET", "/status", timeout=2.0)

    def set_status(self, **fields: Any) -> dict:
        return self._call("POST", "/status", fields)

    def events(self, since: int = 0, types: list[str] | None = None, limit: int = 200, wait: float = 0) -> dict:
        q = f"/events?since={int(since)}&limit={int(limit)}&wait={float(wait)}"
        if types:
            q += "&types=" + ",".join(types)
        return self._call("GET", q, timeout=wait + 5)

    def run(self, op: str, args: dict | None = None, dm: str = "Edit",
            timeout: float = DEFAULT_RUN_TIMEOUT) -> dict:
        return self._call("POST", "/run", {"op": op, "args": args or {}, "dm": dm, "timeout": timeout},
                          timeout=timeout + 5)

    def luau(self, code: str, dm: str = "Edit", timeout: float = DEFAULT_RUN_TIMEOUT) -> str:
        """Run Luau like StudioMCP execute_luau; returns the result text, raises BridgeError on error."""
        res = self.run("run", {"code": code}, dm, timeout)
        if not res.get("ok"):
            raise LuauError(str(res.get("error") or "Luau error"))
        out = res.get("result")
        return out if isinstance(out, str) else json.dumps(out)


def connected_client(place: str | None = None, dm: str | None = None,
                     port: int = DEFAULT_PORT) -> BridgeClient | None:
    """A client if a bridge is up with a plugin session for `place` (and `dm`), else None.
    Never raises: callers fall back to StudioMCP. FORGE_BRIDGE=0 turns the bridge off."""
    if os.environ.get("FORGE_BRIDGE", "1") == "0":
        return None
    try:
        tok = load_token(create=False)
    except Exception:
        return None
    if not tok:
        return None
    client = BridgeClient(port, tok)
    try:
        st = client.status()
    except BridgeError:
        return None
    for s in st.get("sessions", []):
        if (place is None or place_key(s["place"]) == place_key(place)) and (dm is None or s["dm"] == dm):
            return client
    return None


# --------------------------------------------------------------------------- widget actions


def studio_path_to_file(game_root: Path, path: str) -> Path | None:
    """'ServerScriptService.Fire.FireSim' -> game_root/ServerScriptService/Fire/FireSim(.server|.client).luau"""
    parts = [p for p in str(path).split(".") if p]
    if parts[:1] == ["game"]:
        parts = parts[1:]
    if parts[:2] == ["StarterPlayer", "StarterPlayerScripts"]:
        parts = parts[1:]
    if not parts:
        return None
    base = Path(game_root).joinpath(*parts[:-1])
    for suffix in (".server.luau", ".client.luau", ".luau", ".server.lua", ".client.lua", ".lua"):
        f = base / (parts[-1] + suffix)
        if f.is_file():
            return f
    return None


def test_summary(scenario: str, code: int, out: str) -> str:
    """One line for the widget from `forge test scenario_run` output: PASS/FAIL plus the failing step."""
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    head = lines[0] if lines else "no output"
    failed = code != 0 or "FAIL" in head.upper()
    if not failed:
        steps = sum(1 for ln in lines if re.match(r"\|\s*\d+\s*\|", ln))
        return f"PASS {scenario}" + (f": {steps} steps" if steps else "")
    for ln in lines:
        cells = [c.strip() for c in ln.strip("|").split("|")]
        if len(cells) >= 3 and cells[0].isdigit() and cells[2].upper() == "FAIL":
            return f"FAIL {scenario}: step {cells[0]} {cells[1]}"[:160]
    return f"FAIL {scenario}: {head.strip('# ').replace('`', '')}"[:160]


class Actions:
    """Runs what the dock widget's buttons ask for, in the serve process, one job at a time.

    run_tests   -> `forge test scenario_run <scenario>` against this Studio (FORGE_STUDIO=place)
    fix_request -> `forge correct <slug> <file> "<error>"` when Forge's status names a slug, else the
                   request is left in the event stream for an MCP client (studio_events) to act on.
    """

    def __init__(self, bridge: Bridge, repo_root: Path, scenario: str = "smoke",
                 spawn: Callable[..., Any] | None = None) -> None:
        self.bridge = bridge
        self.repo_root = Path(repo_root)
        self.scenario = scenario
        self.spawn = spawn or self._spawn
        self.lock = threading.Lock()
        bridge.listeners.append(self.on_event)

    def _forge_argv(self, *args: str) -> list[str]:
        return [sys.executable, "-c", "import sys; from forge.cli import main; sys.exit(main(sys.argv[1:]))", *args]

    def _spawn(self, argv: list[str], env: dict, done: Callable[[int, str], None]) -> None:
        def go() -> None:
            try:
                p = subprocess.run(argv, cwd=self.repo_root, env=env, capture_output=True, text=True, timeout=900)
                done(p.returncode, (p.stdout or "") + (p.stderr or ""))
            except Exception as e:
                done(1, f"{type(e).__name__}: {e}")
        threading.Thread(target=go, daemon=True).start()

    def on_event(self, ev: dict) -> None:
        kind = ev.get("type")
        if kind not in ("run_tests", "fix_request"):
            return
        if not self.lock.acquire(blocking=False):
            self.bridge.set_forge(message=f"busy: {self.bridge.forge.get('job')}; try again when it finishes")
            return
        try:
            env = {**os.environ, "FORGE_STUDIO": place_key(ev.get("place") or self._place())}
            if kind == "run_tests":
                self._run_tests(env)
            else:
                self._fix(ev, env)
        except Exception:
            self.lock.release()
            raise

    def _place(self) -> str:
        sess = self.bridge.status()["sessions"]
        return sess[0]["place"] if sess else ""

    def _finish(self, **fields: Any) -> None:
        self.bridge.set_forge(**fields)
        self.lock.release()

    def _run_tests(self, env: dict) -> None:
        self.bridge.set_forge(job=f"tests: {self.scenario}", role="tester", message="running…")

        def done(code: int, out: str) -> None:
            self._finish(job=None, role=None, last_test=test_summary(self.scenario, code, out),
                         message=f"full report: {self._save_report(out)}")
        self.spawn(self._forge_argv("test", "scenario_run", self.scenario), env, done)

    def _save_report(self, out: str) -> str:
        path = self.repo_root / "runs" / "studio-bridge" / "last_test.md"
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(out)
            return str(path.relative_to(self.repo_root))
        except OSError:
            return "(not saved)"

    def _fix(self, ev: dict, env: dict) -> None:
        slug = self.bridge.forge.get("slug")
        script = str(ev.get("script") or "")
        note = str(ev.get("error") or ev.get("note") or "").strip() or f"{script} is broken; check the Output errors"
        if not slug:
            self._finish(message=f"fix request for {script} is waiting in studio_events: "
                                 f"Forge's status names no game (slug) to correct")
            return
        from forge.config import load_settings
        from forge.memory import RunStore
        root = RunStore(load_settings(), slug).game_dir
        f = studio_path_to_file(root, script)
        if f is None:
            self._finish(message=f"no file in runs/{slug}/game for {script}")
            return
        rel = str(f.relative_to(root))
        self.bridge.set_forge(job=f"fix {rel}", role="fixer", message=note[:200])

        def done(code: int, out: str) -> None:
            tail = (out.strip().splitlines() or ["done"])[-1]
            self._finish(job=None, role=None, message=("fixed: " if code == 0 else "fix failed: ") + tail[:160])
        self.spawn(self._forge_argv("correct", slug, rel, note), env, done)


# --------------------------------------------------------------------------- MCP tools


def _fmt_event(e: dict) -> str:
    t = e.get("type")
    rest = {k: v for k, v in e.items() if k not in ("seq", "time", "type")}
    if t in ("log", "error"):
        return f"#{e['seq']} [{e.get('dm')}] {t}{'/' + str(e.get('kind')) if e.get('kind') else ''}: {e.get('message', '')}"
    return f"#{e['seq']} {t}: {json.dumps(rest, ensure_ascii=False)[:400]}"


def register(mcp: Any, port: int | None = None) -> list[str]:
    """Add studio_events / studio_run / studio_status to an MCP server (MCPServer / FastMCP)."""

    def client() -> BridgeClient:
        return BridgeClient(port or DEFAULT_PORT)

    @mcp.tool()
    def studio_status() -> str:
        """ForgeBridge plugin status: is a Studio window bound, which datamodels (Edit/Server/Client)
        are connected, play state, and what Forge's dock widget shows (job, role, last test)."""
        try:
            return json.dumps(client().status(), indent=1)
        except BridgeError as e:
            return f"bridge not running ({e}). Start it with: forge plugin serve --place <PlaceName>"

    @mcp.tool()
    def studio_events(since: int = 0, types: str = "", limit: int = 100, wait: float = 0) -> str:
        """Live events streamed from Studio by the ForgeBridge plugin, oldest first: log, error (with
        script + trace), play (started/stopped), selection, tree (script added/removed/edited),
        fix_request / run_tests (dock widget buttons), session, forge. Pass the returned `next` as
        `since` to read only new events; `types` is a comma list filter; `wait` seconds blocks until
        something arrives."""
        try:
            res = client().events(since, [t for t in types.split(",") if t] or None, limit, wait)
        except BridgeError as e:
            return f"bridge not running ({e})"
        lines = [_fmt_event(e) for e in res["events"]] or ["(no new events)"]
        return "\n".join(lines) + f"\nnext={res['next']}"

    @mcp.tool()
    def studio_run(code: str = "", op: str = "run", datamodel: str = "Edit", start: bool = True,
                   path: str = "", timeout: float = 30) -> str:
        """Run a command in Studio through the ForgeBridge plugin (no StudioMCP round trip).
        op=run: execute Luau `code` in `datamodel` (Edit/Server/Client) and return its value.
        op=play: start (start=true) or stop play. op=state: datamodel/selection/play state.
        op=tree: children of `path` (e.g. "ServerScriptService"). op=ping: round trip only."""
        args: dict[str, Any] = {}
        if op == "run":
            args["code"] = code
        elif op == "play":
            args["start"] = start
        elif op == "tree":
            args["path"] = path
        try:
            res = client().run(op, args, datamodel, timeout)
        except BridgeError as e:
            return f"error: {e}"
        head = f"{'ok' if res.get('ok') else 'error'} in {res.get('ms')} ms"
        body = res.get("result") if res.get("ok") else res.get("error")
        return head + "\n" + (body if isinstance(body, str) else json.dumps(body, indent=1))

    return ["studio_status", "studio_events", "studio_run"]


# --------------------------------------------------------------------------- plugin build / install


def plugin_dir(repo_root: Path) -> Path:
    return Path(repo_root) / "studio-plugin"


def build_plugin(repo_root: Path, token: str, port: int = DEFAULT_PORT,
                 places: list[str] | tuple[str, ...] = ()) -> str:
    """The single-file plugin source (Lua) with the bridge URL, token and place allow list baked in.
    The plugin makes no request at all in a place that isn't on `places`."""
    keys = sorted({place_key(p) for p in places if p})
    if not keys:
        raise BridgeError("name at least one place the plugin may bind to (--place NAME)")
    src = (plugin_dir(repo_root) / "ForgeBridge.plugin.luau").read_text()
    for marker in ("__FORGE_BRIDGE_URL__", "__FORGE_BRIDGE_TOKEN__", "__FORGE_BRIDGE_PLACES__"):
        if marker not in src:
            raise BridgeError(f"plugin source is missing {marker}")
    return (src.replace("__FORGE_BRIDGE_URL__", f"http://127.0.0.1:{int(port)}")
            .replace("__FORGE_BRIDGE_TOKEN__", token)
            .replace("__FORGE_BRIDGE_PLACES__", ",".join(keys)))


def default_plugins_dir() -> Path:
    """Studio's local plugins folder: ~/Documents/Roblox/Plugins (macOS), %LOCALAPPDATA%/Roblox/Plugins (Windows)."""
    if sys.platform.startswith("win") and os.environ.get("LOCALAPPDATA"):
        return Path(os.environ["LOCALAPPDATA"]) / "Roblox" / "Plugins"
    return Path.home() / "Documents" / "Roblox" / "Plugins"


def install_plugin(repo_root: Path, places: list[str], plugins_dir: Path | None = None,
                   port: int = DEFAULT_PORT) -> Path:
    token = load_token(store_dir(repo_root))
    assert token
    src = build_plugin(repo_root, token, port, places)
    d = Path(plugins_dir or default_plugins_dir())
    d.mkdir(parents=True, exist_ok=True)
    out = d / "ForgeBridge.lua"
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(src)
    return out


def serve_forever(repo_root: Path, places: list[str], port: int = DEFAULT_PORT,
                  scenario: str = "smoke") -> None:
    token = load_token(store_dir(repo_root))
    assert token
    bridge = Bridge(token, places)
    Actions(bridge, repo_root, scenario)
    server = make_server(bridge, port)
    (store_dir(repo_root) / "bridge.pid").write_text(str(os.getpid()))
    print(f"forge bridge on 127.0.0.1:{port}; binding places: {', '.join(sorted(bridge.places)) or '(none)'}",
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
