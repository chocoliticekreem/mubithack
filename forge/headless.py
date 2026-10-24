"""Headless by default: run a game in the fake engine (game/tools/headless.luau) instead of Roblox Studio.

Most of what Forge used to wait on a Studio playtest for is logic: boot errors, counters, checks,
scenario steps that call server APIs, testers walking to pads and holding prompts. The headless engine
runs all of that with the `luau` CLI on a simulated clock (a 30 s round in well under a second), and
it says loudly what it cannot model (`needs_studio`: physics movers, impulses, camera projection, UI
layout, shape casts). Studio is kept for what really needs a renderer: screenshots, the visual judge,
physics feel and client UI layout.

Two ways to run:
- one shot (`checks.run_headless`): bundle + boot + one action, a fresh process each time;
- a session (`HeadlessStudio`): the bundle stays up under `luau -i` and answers one call at a time. It
  duck-types `forge.studio.Studio` (execute_luau / state / play / stop / probe_report / console), so the
  ForgeTest harness, checks, scenarios, the census and the testers run on it unchanged. Its simulated
  players are real clients: their LocalScripts (ForgeTestAgent included) run on their side, remotes go
  client <-> server in-process.

Studio policy (`--studio auto|always|never`, env FORGE_STUDIO_MODE, default auto):
- auto:   headless first; Studio only for screenshots / the visual judge (when a Studio is free) and for
          checks that failed headless or need Studio;
- always: the old behaviour (every playtest and check in Studio);
- never:  no Studio at all; what needs Studio is reported as skipped, never as passed.

Every execution is counted (`record`) in runs/_engine_usage.jsonl, so `forge headless --stats` can show
how much ran headless vs in Studio and how many Studio minutes were spent.
"""

from __future__ import annotations

import json
import os
import pty
import select
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any

from forge.studio import StudioError

STUDIO_MODES = ("auto", "always", "never")
OUT_MARK = "@@HEADLESS@@"
SESSION_BOOT_TIMEOUT = 60.0  # wall seconds to boot a session
CALL_TIMEOUT = 120.0  # wall seconds for one call (the simulated clock usually runs 50-500x real time)
IDLE_CAP = 10.0  # simulated seconds that pass between two calls at most (idle = "wall")
USAGE_FILE = "_engine_usage.jsonl"


class NeedsStudio(StudioError):
    """The headless engine cannot answer this (a screenshot, real input, a renderer): run it in Studio."""


# ---------------------------------------------------------------- policy


def studio_mode(flag: str | None = None) -> str:
    """The Studio policy: the flag, else $FORGE_STUDIO_MODE, else "auto"."""
    m = (flag or os.environ.get("FORGE_STUDIO_MODE") or "auto").strip().lower()
    if m not in STUDIO_MODES:
        raise ValueError(f"--studio must be one of {', '.join(STUDIO_MODES)} (got {m!r})")
    return m


def split_studio_arg(value: str | None) -> tuple[str | None, str | None]:
    """`--studio` takes a policy (auto|always|never) or, as before, a place / window name.
    -> (mode or None, place or None)."""
    if value is None:
        return None, None
    v = value.strip()
    if v.lower() in STUDIO_MODES:
        return v.lower(), None
    return None, v or None


def studio_slot_free(max_slots: int | None = None) -> bool:
    """Is one of the shared Studio slots (scripts/studio-slot.sh, broker.StudioSlots) free right now?"""
    d = Path("/tmp/forge-studio-slots")
    n = max_slots or int(os.environ.get("STUDIO_SLOTS", "4") or 4)
    if not d.is_dir():
        return True
    return sum(1 for p in d.glob("slot*") if p.is_dir()) < n


def available() -> bool:
    return shutil.which("luau") is not None


# ---------------------------------------------------------------- usage ledger


def usage_path() -> Path:
    from forge.config import load_settings
    return load_settings().runs_dir / USAGE_FILE


def record(kind: str, where: str, seconds: float, *, slug: str = "", n: int = 1, ok: bool | None = None,
           note: str = "", path: Path | None = None) -> None:
    """Count one execution (a check, a playtest, a tester session...) as headless or studio."""
    if path is None and (os.environ.get("PYTEST_CURRENT_TEST") or os.environ.get("FORGE_USAGE") == "0"):
        return  # tests never write the real ledger
    row = {"ts": time.time(), "kind": kind, "where": where, "seconds": round(float(seconds), 3), "n": int(n),
           "slug": slug}
    if ok is not None:
        row["ok"] = bool(ok)
    if note:
        row["note"] = note[:200]
    try:
        p = path or usage_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a", encoding="utf-8") as f:
            f.write(json.dumps(row) + "\n")
    except OSError:
        pass


def usage_stats(since: float = 0.0, slug: str | None = None, path: Path | None = None) -> dict:
    """{headless: n, studio: n, share_headless, studio_minutes, headless_minutes, by_kind: {kind: {...}}}"""
    p = path or usage_path()
    out: dict[str, Any] = {"headless": 0, "studio": 0, "studio_minutes": 0.0, "headless_minutes": 0.0, "by_kind": {}}
    if not p.is_file():
        out["share_headless"] = None
        return out
    for line in p.read_text(encoding="utf-8").splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("ts", 0) < since or (slug and r.get("slug") != slug):
            continue
        where = "studio" if r.get("where") == "studio" else "headless"
        n = int(r.get("n") or 1)
        out[where] += n
        out[f"{where}_minutes"] += float(r.get("seconds") or 0) / 60
        k = out["by_kind"].setdefault(r.get("kind") or "?", {"headless": 0, "studio": 0})
        k[where] += n
    total = out["headless"] + out["studio"]
    out["share_headless"] = round(out["headless"] / total, 3) if total else None
    out["studio_minutes"] = round(out["studio_minutes"], 2)
    out["headless_minutes"] = round(out["headless_minutes"], 2)
    return out


# ---------------------------------------------------------------- a persistent session


def luau_string(s: str) -> str:
    """A one-line Luau string literal (the REPL reads one line per call)."""
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif o < 32 or o == 127:
            out.append(f"\\{o:03d}")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _lua_arg(v: Any) -> str:
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(float(v)) if isinstance(v, float) else str(v)
    return luau_string(str(v))


class HeadlessStudio:
    """A headless game server that looks like `forge.studio.Studio` to Forge's callers.

    `play()` boots a fresh server (with `players` simulated clients), `stop()` shuts it down. Each call
    runs on a simulated clock; between calls the world advances by the wall time that passed (capped at
    IDLE_CAP) when `idle="wall"`, or by a fixed number of simulated seconds.
    """

    studio_id = "headless"
    headless = True

    def __init__(self, game_dir: Path, players: int = 1, clients: bool = True, boot: float = 2.0,
                 settle: float = 1.0, idle: float | str = "wall", slug: str = "", kind: str = "session"):
        self.game_dir = Path(game_dir)
        self.players, self.clients, self.boot, self.settle = players, clients, boot, settle
        self.idle = idle
        self.slug, self.kind = slug, kind
        self._proc: subprocess.Popen | None = None
        self._fd: int | None = None
        self._buf = b""
        self._lock = threading.Lock()
        self._last = 0.0
        self._started = 0.0
        self._src: str | None = None
        self.boot_report: dict = {}
        self.calls = 0
        self.sim_seconds = 0.0
        self.needs_studio: dict[str, int] = {}

    # -------------------------------------------------- lifecycle
    def _spawn(self) -> None:
        from forge import checks

        exe = shutil.which("luau")
        if not exe:
            raise StudioError("luau CLI not on PATH (brew install luau)")
        src = checks.bundle(self.game_dir, {"mode": "serve", "boot": self.boot, "play": self.settle,
                                            "players": self.players, "clients": self.clients})
        with tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False, encoding="utf-8") as f:
            f.write(src)
            self._src = f.name
        master, slave = pty.openpty()  # a pty: the REPL flushes each line (a pipe would buffer)
        self._proc = subprocess.Popen([exe, "-i", self._src], stdin=subprocess.PIPE, stdout=slave,
                                      stderr=slave, close_fds=True)
        os.close(slave)
        self._fd, self._buf = master, b""
        self._started = time.time()
        first = self._read_mark(SESSION_BOOT_TIMEOUT)
        self.boot_report = first.get("report") or {}
        self._last = time.time()

    def _read_mark(self, timeout: float) -> dict:
        assert self._fd is not None
        deadline = time.time() + timeout
        mark = OUT_MARK.encode()
        while True:
            i = self._buf.find(mark)
            if i >= 0:
                j = self._buf.find(b"\n", i)
                if j >= 0:
                    line = self._buf[i + len(mark):j].decode("utf-8", "replace").strip()
                    self._buf = self._buf[j + 1:]
                    try:
                        return json.loads(line)
                    except ValueError as e:
                        raise StudioError(f"headless: unreadable reply ({e}): {line[:300]}") from e
            left = deadline - time.time()
            if left <= 0:
                self._kill()
                raise StudioError(f"headless call timed out after {timeout:.0f}s (a loop without task.wait?)")
            r, _, _ = select.select([self._fd], [], [], min(left, 0.5))
            if r:
                try:
                    chunk = os.read(self._fd, 1 << 16)
                except OSError:
                    chunk = b""
                if not chunk:
                    tail = self._buf[-800:].decode("utf-8", "replace")
                    self._kill()
                    raise StudioError(f"headless session exited: {tail}")
                self._buf += chunk
                if len(self._buf) > (8 << 20):  # a game printing in a loop: keep the tail
                    self._buf = self._buf[-(1 << 20):]

    def _kill(self) -> None:
        if self._proc is not None:
            try:
                self._proc.kill()
                self._proc.wait(timeout=5)
            except Exception:  # noqa: BLE001
                pass
        if self._fd is not None:
            try:
                os.close(self._fd)
            except OSError:
                pass
        if self._src:
            Path(self._src).unlink(missing_ok=True)
        self._proc, self._fd, self._src = None, None, None

    @property
    def running(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def rpc(self, op: str, *args: Any, timeout: float = CALL_TIMEOUT) -> dict:
        """One H.rpc(op, ...) round trip (blocking)."""
        with self._lock:
            if not self.running:
                self._spawn()
            assert self._proc is not None and self._proc.stdin is not None
            line = f"__FORGE_HEADLESS.rpc({luau_string(op)}" + "".join(", " + _lua_arg(a) for a in args) + ")\n"
            try:
                self._proc.stdin.write(line.encode("utf-8"))
                self._proc.stdin.flush()
            except (BrokenPipeError, OSError) as e:
                self._kill()
                raise StudioError(f"headless session is gone: {e}") from e
            out = self._read_mark(timeout)
            self._last = time.time()
            self.calls += 1
            return out

    def _idle_advance(self) -> None:
        if not self.running:
            return
        if self.idle == "wall":
            gap = min(max(time.time() - self._last, 0.0), IDLE_CAP)
        else:
            gap = float(self.idle or 0)
        if gap >= 1 / 30:
            self.rpc("run", round(gap, 3))
            self.sim_seconds += gap

    # -------------------------------------------------- the Studio surface
    def exec_sync(self, code: str, datamodel: str = "Server", timeout: float | None = None) -> dict:
        """Run Luau like execute_luau -> the raw exec reply {ok, text?, error?, sim, needs_studio, misses}."""
        self._idle_advance()
        dm = "Server" if datamodel in (None, "", "Server", "Edit") else datamodel
        sim_timeout = float(timeout) if timeout else 60.0
        out = self.rpc("exec", code, dm, sim_timeout, timeout=max(CALL_TIMEOUT, sim_timeout))
        self.sim_seconds += float(out.get("sim") or 0)
        for n in out.get("needs_studio") or []:
            self.needs_studio[n.get("feature", "?")] = self.needs_studio.get(n.get("feature", "?"), 0) + int(n.get("count") or 1)
        return out

    async def execute_luau(self, code: str, datamodel: str = "Edit", timeout: float | None = None) -> str:
        import anyio

        out = await anyio.to_thread.run_sync(self.exec_sync, code, datamodel, timeout)
        if not out.get("ok"):
            raise StudioError(f"headless execute_luau: {out.get('error')}")
        return str(out.get("text") or "")

    async def call(self, tool: str, **args: Any) -> str:
        if tool == "execute_luau":
            return await self.execute_luau(args.get("code", ""), args.get("datamodel_type") or "Server")
        if tool == "get_studio_state":
            return json.dumps(await self.state())
        raise NeedsStudio(f"needs studio: {tool} has no headless equivalent")

    async def list_studios(self) -> list[dict]:
        return [{"id": self.studio_id, "name": "headless", "active": True}]

    async def state(self) -> dict:
        dms = ["Edit", "Server"] + (["Client"] if self.clients and self.players else [])
        return {"playing": self.running, "datamodels": dms if self.running else ["Edit"], "raw": "headless"}

    async def play(self, ready: bool = True, ready_timeout: float = 30.0) -> dict:
        import anyio

        await self.stop()
        await anyio.to_thread.run_sync(self._spawn)
        return await self.state()

    async def wait_ready(self, timeout: float = 30.0, grace: float = 0.25) -> dict:
        if not self.running:
            return await self.play()
        return await self.state()

    async def stop(self) -> None:
        if self._proc is not None:
            record(self.kind, "headless", time.time() - self._started, slug=self.slug, n=1,
                   note=f"{self.calls} calls, {self.sim_seconds:.0f}s simulated")
        self._kill()

    async def probe_report(self) -> dict:
        """The engine's ForgeProbe-shaped report: errors, warnings, counters, players, uptime, needs_studio."""
        import anyio

        out = await anyio.to_thread.run_sync(self.rpc, "report")
        return out.get("report") or {}

    async def console(self) -> str:
        rep = await self.probe_report()
        lines = [f"[warn] {w}" for w in rep.get("warnings") or []]
        lines += [f"[error] {e.get('script', '')}: {e.get('message', '')}" for e in rep.get("errors") or []]
        return "\n".join(lines)

    async def screenshot(self, out: Path, camera: Any = None, look_at: Any = None) -> Path:
        raise NeedsStudio("needs studio: a screenshot needs a renderer")

    async def sync(self, root: Path, port: int | None = None, prune: bool = True, incremental: bool = True) -> dict:
        """Point the session at `root` (the next play() boots it)."""
        await self.stop()
        self.game_dir = Path(root)
        return {"headless": True, "root": str(root)}

    async def hot_reload(self, root: Path) -> dict:
        await self.sync(root)
        await self.play()
        return {"headless": True, "restarted": True}

    async def run(self, seconds: float) -> None:
        """Fast-forward the simulated clock."""
        import anyio

        await anyio.to_thread.run_sync(self.rpc, "run", float(seconds))
        self.sim_seconds += float(seconds)

    async def __aenter__(self) -> "HeadlessStudio":
        return self

    async def __aexit__(self, *exc: Any) -> None:
        await self.stop()

    def __del__(self) -> None:  # a forgotten session must not leave a luau process behind
        try:
            self._kill()
        except Exception:  # noqa: BLE001
            pass


# ---------------------------------------------------------------- the headless playtest


async def playtest(game_dir: Path, *, play: float = 20.0, players: int = 2, clients: bool = True, slug: str = "",
                   start_round: bool = False, log: Any = None) -> dict:
    """The build loop's playtest without Studio: boot the server with `players` simulated clients, start a
    round through the ForgeTest harness when `start_round`, run `play` simulated seconds, then take the
    probe report and the scene census (server and client halves). -> a ForgeProbe-shaped report plus
    census, needs_studio, approx, engine="headless", wall (seconds)."""
    from forge import fun

    t0 = time.time()
    hs = HeadlessStudio(game_dir, players=players, clients=clients, idle=0.0, slug=slug, kind="playtest")
    try:
        await hs.play()
        if start_round:
            from mubit_tester.harness import build_call_luau

            try:
                await hs.execute_luau(build_call_luau("round", {"state": "Active"}), "Server", timeout=20)
            except StudioError as e:
                if log:
                    log(f"[headless] round start failed: {e}")
        await hs.run(play)
        rep = dict(await hs.probe_report())
        rep["census"] = await fun.census(hs)
        rep["census"]["source"] = "headless playtest"
    except StudioError as e:
        rep = {"error": str(e), "errors": [], "warnings": []}
    finally:
        await hs.stop()
    rep["engine"] = "headless"
    rep["wall"] = round(time.time() - t0, 2)
    rep["simulated"] = round(hs.sim_seconds, 1)
    return rep
