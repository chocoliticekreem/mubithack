"""Roblox Studio MCP client (stdio) for forge.

Spawns Studio's bundled StudioMCP proxy (settings.studio_mcp_path) and talks MCP over stdio using
the `mcp` SDK. Every Studio tool needs a studio_id; `Studio` picks one automatically on the first
call (or via `select()`).

Observed shapes (StudioMCP 1.0.0, protocol 2025-11-25): results come back as text content; e.g.
list_roblox_studios -> '{"studios":[{"id": ..., "name": ...}]}'. Shapes of the other tools aren't
documented, so the parsers below are defensive (JSON when possible, plain text otherwise).
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import json
import os
import re
import shutil
import sys
import time
from contextlib import AsyncExitStack
from pathlib import Path
from typing import Any, Iterable, TextIO

import anyio
from mcp.client.session import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client

from forge import sync as fsync
from forge.config import Settings, load_settings

OPEN_STUDIO_HINT = (
    "Open Roblox Studio with a place, and enable Assistant → ⋯ → Manage MCP Servers → MCP "
    "(\"Enable Studio as MCP server\")."
)
DEFAULT_CALL_TIMEOUT = 120.0
PLAY_TIMEOUT = 60.0
# get_studio_state costs ~30 ms, so poll play/stop transitions often (was 1.0 s)
POLL_INTERVAL = 0.1
DATAMODELS = ("Edit", "Server", "Client")

PROBE_CODE = 'return game:GetService("ServerStorage"):WaitForChild("ForgeProbe", 5):Invoke("report")'


# the first list after StudioMCP starts is often empty: retry quickly, ~7.5 s in total as before
SELECT_RETRIES = 30
DROPOUT_TEXT = "No Roblox Studio instances are connected"
DROPOUT_RETRIES = 4
DROPOUT_WAIT_SECONDS = 2.0
SELECT_RETRY_SECONDS = 0.25


class StudioError(RuntimeError):
    pass


def _matching(studios: list[dict], hint: str) -> list[dict]:
    """An exact id wins, then an exact name (with or without .rbxlx), then a name containing the hint."""
    h = hint.lower()

    def name(s: dict) -> str:
        return str(s.get("name", "")).lower()

    for test in (lambda s: str(s.get("id", "")).lower() == h,
                 lambda s: h in (name(s), name(s).removesuffix(".rbxlx").removesuffix(".rbxl")),
                 lambda s: h in name(s)):
        hits = [s for s in studios if test(s)]
        if hits:
            return hits
    return []


# --------------------------------------------------------------------------- result parsing


def _attr(block: Any, name: str, default: Any = None) -> Any:
    if isinstance(block, dict):
        return block.get(name, default)
    return getattr(block, name, default)


def content_text(content: Iterable[Any] | None) -> str:
    """Join the text of all text content blocks (and text embedded resources)."""
    parts: list[str] = []
    for block in content or []:
        kind = _attr(block, "type")
        if kind == "text":
            parts.append(_attr(block, "text", "") or "")
        elif kind == "resource":
            res = _attr(block, "resource")
            text = _attr(res, "text") if res is not None else None
            if text:
                parts.append(text)
    return "\n".join(parts)


def extract_image(content: Iterable[Any] | None) -> tuple[bytes, str] | None:
    """Return (bytes, mime type) of the first image block (or image blob resource), if any."""
    for block in content or []:
        kind = _attr(block, "type")
        if kind == "image":
            data = _attr(block, "data")
            mime = _attr(block, "mime_type") or _attr(block, "mimeType") or "image/png"
        elif kind == "resource":
            res = _attr(block, "resource")
            data = _attr(res, "blob") if res is not None else None
            mime = (_attr(res, "mime_type") or _attr(res, "mimeType") or "") if res is not None else ""
            if not mime.startswith("image/"):
                continue
        else:
            continue
        if data:
            try:
                return base64.b64decode(data), mime
            except (ValueError, TypeError):
                continue
    return None


def extract_json(text: str | None) -> Any:
    """Parse JSON from tool output. Handles plain JSON, double-encoded JSON strings, and JSON
    embedded in other text (e.g. '[RETURNED RESULTS]\\n{...}'). Returns None if nothing parses."""
    if not text:
        return None
    s = text.strip()
    try:
        obj = json.loads(s)
    except ValueError:
        obj = None
    else:
        if isinstance(obj, str):
            inner = extract_json(obj)
            return inner if inner is not None else obj
        return obj
    decoder = json.JSONDecoder()
    for m in re.finditer(r"[\[{]", s):
        try:
            obj, _ = decoder.raw_decode(s, m.start())
        except ValueError:
            continue
        if isinstance(obj, (dict, list)):
            return obj
    return None


def parse_studios(obj: Any) -> list[dict]:
    """Normalize list_roblox_studios output to [{id, name, ...}]."""
    if isinstance(obj, str):
        obj = extract_json(obj)
    if isinstance(obj, dict):
        obj = obj.get("studios", obj.get("instances", []))
    out: list[dict] = []
    for item in obj or []:
        if isinstance(item, dict):
            sid = item.get("id") or item.get("studio_id") or item.get("instance_id")
            if sid is None:
                continue
            d = dict(item)
            d["id"] = str(sid)
            d.setdefault("name", str(item.get("name") or sid))
            out.append(d)
        elif isinstance(item, (str, int)):
            out.append({"id": str(item), "name": str(item)})
    return out


def _canon_dm(s: str) -> set[str]:
    return {dm for dm in DATAMODELS if re.search(rf"\b{dm}\b", s, re.IGNORECASE)}


def available_datamodels(state: Any) -> set[str]:
    """Datamodel types (Edit/Server/Client) the studio state says are available."""
    if isinstance(state, str):
        parsed = extract_json(state)
        state = parsed if parsed is not None else {"raw": state}
    found: set[str] = set()

    def walk(node: Any) -> None:
        if isinstance(node, dict):
            for k, v in node.items():
                if "datamodel" in str(k).lower() or "data_model" in str(k).lower():
                    if isinstance(v, list):
                        for x in v:
                            found.update(_canon_dm(str(x)))
                    elif isinstance(v, str):
                        found.update(_canon_dm(v))
                    elif isinstance(v, dict):  # {"Edit": true, "Server": false}
                        found.update(dm for dm in _canon_dm(" ".join(map(str, v))) if v.get(dm, v.get(dm.lower())))
                else:
                    walk(v)
        elif isinstance(node, list):
            for x in node:
                walk(x)

    walk(state)
    if not found and isinstance(state, dict) and isinstance(state.get("raw"), str):
        found = _canon_dm(state["raw"])
    return found


def is_playing(state: Any) -> bool | None:
    """True if a playtest is running, False if in edit mode, None if the state can't be read."""
    dms = available_datamodels(state)
    if "Server" in dms:
        return True
    if "Edit" in dms:
        return False
    if isinstance(state, dict):
        for k, v in state.items():
            lk = str(k).lower()
            if "play" in lk or "mode" in lk:
                if isinstance(v, bool):
                    return v
                if isinstance(v, str):
                    lv = v.lower()
                    if any(w in lv for w in ("edit", "stop", "idle", "notplaying", "not playing")):
                        return False
                    if any(w in lv for w in ("play", "run", "server", "client")):
                        return True
    return None


# --------------------------------------------------------------------------- readiness / hot reload

# Runs in the Server datamodel right after play starts and waits *inside Studio* until the game is up,
# so Python makes one call instead of sleeping and polling. Ready = ForgeProbe exists and either the game
# set workspace.ServerBooted, or (for games that never set it) a player's character has spawned and
# ServerBooted stayed unset for a short grace period.
READY_LUAU = r"""
local t0 = os.clock()
local Players = game:GetService("Players")
local SS = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local LIMIT, GRACE = __LIMIT__, __GRACE__
local charSince = nil
local function state()
	local char = false
	for _, p in Players:GetPlayers() do
		if p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
			char = true
		end
	end
	return SS:FindFirstChild("ForgeProbe") ~= nil, workspace:GetAttribute("ServerBooted"), char
end
local ready, reason = false, "timeout"
while os.clock() - t0 < LIMIT do
	local probe, booted, char = state()
	if probe and booted == true then
		ready, reason = true, "ServerBooted"
		break
	end
	if probe and booted == nil and char then
		charSince = charSince or os.clock()
		if os.clock() - charSince >= GRACE then
			ready, reason = true, "character"
			break
		end
	end
	if os.clock() - t0 > 5 and booted == nil and not char then
		-- no ForgeProbe, or a run with no player and no ServerBooted: nothing more to wait for
		ready, reason = probe, if probe then "probe" else "no ForgeProbe"
		break
	end
	task.wait(0.05)
end
return HttpService:JSONEncode({ ready = ready, reason = reason, waited = os.clock() - t0,
	booted = workspace:GetAttribute("ServerBooted") == true, mapReady = workspace:GetAttribute("MapReady") == true,
	players = #Players:GetPlayers() })
"""

# Hot reload, run in the Server datamodel during play. For each changed server-only ModuleScript it
# makes a clone holding the new source and asks ForgeProbe (which runs in the game's own VM, so it
# shares the live require cache) to require the clone and copy its functions into the live module
# table. Callers keep their reference to the same table, so the next call runs the new code.
HOT_RELOAD_LUAU = r"""
local HttpService = game:GetService("HttpService")
local SS = game:GetService("ServerStorage")
local items = HttpService:JSONDecode(__ITEMS__)
local probe = SS:FindFirstChild("ForgeProbe")
local out = {}
for _, it in items do
	local parent: Instance? = game:GetService(it.service)
	for _, d in it.dirs do
		parent = parent and parent:FindFirstChild(d)
	end
	local inst = parent and parent:FindFirstChild(it.name)
	if not inst or not inst:IsA("ModuleScript") then
		out[it.path] = "missing"
		continue
	end
	local clone = inst:Clone()
	clone.Source = it.source
	clone.Parent = inst.Parent
	clone.Name = inst.Name .. "__forge_reload"
	inst.Source = it.source
	if not probe then
		out[it.path] = "no ForgeProbe"
	else
		local ok, res = pcall(function()
			return probe:Invoke("hotreload", inst, clone)
		end)
		out[it.path] = if ok then tostring(res) else "error: " .. tostring(res)
	end
	clone:Destroy()
end
return HttpService:JSONEncode(out)
"""

HOT_SERVICES = ("ServerScriptService", "ServerStorage")
_STATE_RE = re.compile(r"^local\s+(\w+)\s*(?::[^=]+)?=\s*(\{\s*\}|0|nil|false|true)\s*(--.*)?$", re.MULTILINE)
_RETURN_RE = re.compile(r"^return\s+(\w+)\s*$", re.MULTILINE)


def module_state_vars(source: str) -> list[str]:
    """Top-level locals that look like mutable module state (`local x = {}` / `= 0` / `= nil`),
    other than the returned module table. Reloading such a module would reset that state."""
    ret = _RETURN_RE.findall(source)
    mod = ret[-1] if ret else None
    return [m.group(1) for m in _STATE_RE.finditer(source) if m.group(1) != mod]


def hot_reload_plan(entries: list[dict], changed: list[str], sources: dict[str, str],
                    added: Iterable[str] = ()) -> dict[str, list]:
    """Split changed paths into {"reload": [entry...], "restart": [(path, why)...]}.
    Only existing server-only ModuleScripts without module-level state are hot-reloaded."""
    by_path = {e["path"]: e for e in entries}
    new = set(added)
    plan: dict[str, list] = {"reload": [], "restart": []}
    for path in changed:
        e = by_path.get(path)
        if e is None:
            plan["restart"].append((path, "removed"))
        elif path in new:
            plan["restart"].append((path, "new file"))
        elif e["class"] != "ModuleScript":
            plan["restart"].append((path, f"{e['class']} (only ModuleScripts reload)"))
        elif e["service"] not in HOT_SERVICES:
            plan["restart"].append((path, f"{e['service']} module (clients hold their own copy)"))
        elif state := module_state_vars(sources.get(path, "")):
            plan["restart"].append((path, f"module state: {', '.join(state[:3])}"))
        else:
            plan["reload"].append(e)
    return plan


_TRANSPORT_ERRORS = (anyio.ClosedResourceError, anyio.BrokenResourceError, anyio.EndOfStream,
                     BrokenPipeError, ConnectionError)


# --------------------------------------------------------------------------- client


class Studio:
    """Async context manager wrapping the StudioMCP stdio server.

    One session is kept for the whole `async with` and reused by every call; if the StudioMCP
    process dies, the next call reconnects once and retries. `timings` records (tool, seconds) for
    every call (see `forge bench-io`).
    """

    def __init__(
        self,
        settings: Settings | None = None,
        *,
        call_timeout: float = DEFAULT_CALL_TIMEOUT,
        studio_id: str | None = None,
        errlog: TextIO | None = None,
    ) -> None:
        self.settings = settings or load_settings()
        self.call_timeout = call_timeout
        self.studio_id = studio_id
        self.tools: dict[str, Any] = {}
        self.timings: list[tuple[str, float]] = []
        self.poll_interval: float | None = None  # None: POLL_INTERVAL (module constant, patchable)
        self._errlog = errlog or sys.stderr
        self._stack: AsyncExitStack | None = None
        self._session: ClientSession | None = None
        self._capture_n = 0
        self._servers: dict[int, tuple[Path, Any]] = {}
        self._ports: dict[Path, int] = {}
        # what the Edit datamodel of each studio holds: {(studio_id, root): {path: hash}}
        self._pushed: dict[tuple[str, str], dict[str, str]] = {}
        self._playing: bool | None = None
        self.reconnects = 0

    # ---- lifecycle

    async def _connect(self) -> None:
        path = self.settings.studio_mcp_path
        if not Path(path).exists():
            raise StudioError(f"StudioMCP binary not found at {path} (set STUDIO_MCP_PATH). {OPEN_STUDIO_HINT}")
        stack = AsyncExitStack()
        await stack.__aenter__()
        try:
            params = StdioServerParameters(command=path)
            read, write = await stack.enter_async_context(stdio_client(params, errlog=self._errlog))
            session = ClientSession(read, write, read_timeout_seconds=self.call_timeout)
            self._session = await stack.enter_async_context(session)
            with anyio.fail_after(30):
                await self._session.initialize()
            await self.refresh_tools()
        except BaseException:
            await stack.aclose()
            self._session = None
            raise
        self._stack = stack

    async def _disconnect(self) -> None:
        stack, self._stack, self._session = self._stack, None, None
        if stack is not None:
            await stack.aclose()

    async def __aenter__(self) -> "Studio":
        await self._connect()
        return self

    async def __aexit__(self, *exc: Any) -> None:
        for _, server in self._servers.values():
            _shutdown_server(server)
        self._servers.clear()
        await self._disconnect()

    async def reconnect(self) -> None:
        """Drop the StudioMCP session and start a fresh one (keeps studio_id and sync state)."""
        with contextlib.suppress(Exception):
            await self._disconnect()
        self._stack, self._session = None, None
        await self._connect()
        self.reconnects += 1

    async def refresh_tools(self) -> list[str]:
        assert self._session is not None
        res = await self._session.list_tools()
        self.tools = {t.name: t for t in res.tools}
        return list(self.tools)

    # ---- raw calls

    async def call_result(self, tool: str, timeout: float | None = None, **args: Any) -> Any:
        """Call a tool and return the CallToolResult. Injects studio_id; raises StudioError."""
        if self._session is None:
            raise StudioError("Studio client is not connected (use `async with Studio() as s`)")
        if tool != "list_roblox_studios" and "studio_id" not in args:
            args["studio_id"] = self.studio_id or await self.select()
        limit = timeout or self.call_timeout
        reconnected = False
        attempt = 0
        while True:
            t0 = time.perf_counter()
            try:
                with anyio.fail_after(limit):
                    result = await self._session.call_tool(tool, args, read_timeout_seconds=limit)
            except TimeoutError as e:
                raise StudioError(f"{tool} timed out after {limit:.0f}s") from e
            except StudioError:
                raise
            except _TRANSPORT_ERRORS as e:
                # the StudioMCP process went away: one fresh session, then retry the call
                if reconnected or self._stack is None:
                    raise StudioError(f"{tool} failed: {type(e).__name__}: {e}") from e
                reconnected = True
                try:
                    await self.reconnect()
                except Exception as e2:
                    raise StudioError(f"{tool} failed and StudioMCP did not reconnect: {e2}") from e
                continue
            except Exception as e:  # MCP protocol errors etc.
                raise StudioError(f"{tool} failed: {type(e).__name__}: {e}") from e
            finally:
                self.timings.append((tool, time.perf_counter() - t0))
            if not getattr(result, "is_error", False):
                return result
            text = content_text(result.content) or str(result)
            # StudioMCP briefly loses the Studio connection; the window comes back within seconds
            if DROPOUT_TEXT in text and attempt < DROPOUT_RETRIES:
                attempt += 1
                await asyncio.sleep(DROPOUT_WAIT_SECONDS)
                continue
            if DROPOUT_TEXT in text:
                raise StudioError(f"{tool} error: Studio stayed disconnected: {text}")
            raise StudioError(f"{tool} error: {text}")

    async def call(self, tool: str, **args: Any) -> str:
        """Raw tool call; returns the text content (structured content as JSON if no text)."""
        result = await self.call_result(tool, **args)
        text = content_text(result.content)
        if not text and getattr(result, "structured_content", None) is not None:
            text = json.dumps(result.structured_content)
        return text

    # ---- studios

    async def list_studios(self) -> list[dict]:
        return parse_studios(await self.call("list_roblox_studios"))

    async def select(self, name_hint: str | None = None) -> str:
        """Pick the Studio `name_hint` (an id, or a name or part of one; default $FORGE_STUDIO) names.
        Several Studios are often open at once (other agents' playtests), so this never guesses: an
        ambiguous hint, or several windows and no hint, is an error that lists the ids to pin."""
        name_hint = name_hint or os.environ.get("FORGE_STUDIO") or None
        studios: list[dict] = []
        matches: list[dict] = []
        for attempt in range(SELECT_RETRIES + 1):  # the first lists after StudioMCP starts are often short
            if attempt:
                await asyncio.sleep(SELECT_RETRY_SECONDS)
            studios = await self.list_studios()
            matches = _matching(studios, name_hint) if name_hint else studios
            if matches:
                break
        if not studios:
            raise StudioError(f"No Roblox Studio is connected to MCP. {OPEN_STUDIO_HINT}")
        listing = ", ".join(f"{s.get('id')} ({s.get('name')})" for s in studios)
        if not matches:
            raise StudioError(f"No connected Studio matches {name_hint!r}; open: {listing}")
        if len(matches) > 1:
            what = f"{len(matches)} Studios match {name_hint!r}" if name_hint else \
                f"{len(matches)} Studios are connected and none is pinned"
            raise StudioError(f"{what}: {listing}. Pin one by id: FORGE_STUDIO=<id> (or --studio <id>).")
        if matches[0]["id"] != self.studio_id:
            self._playing = None
        self.studio_id = matches[0]["id"]
        return self.studio_id

    # ---- luau / state

    async def execute_luau(self, code: str, datamodel: str = "Edit", timeout: float | None = None) -> str:
        if datamodel not in DATAMODELS:
            raise ValueError(f"datamodel must be one of {DATAMODELS}, got {datamodel!r}")
        return await self.call("execute_luau", code=code, datamodel_type=datamodel, timeout=timeout)

    async def state(self) -> dict:
        """get_studio_state, parsed. Always has "raw" (text), "datamodels" and "playing"."""
        text = await self.call("get_studio_state")
        obj = extract_json(text)
        st: dict = dict(obj) if isinstance(obj, dict) else {"value": obj} if obj is not None else {}
        st["raw"] = text
        st["datamodels"] = sorted(available_datamodels(obj if obj is not None else text))
        st["playing"] = is_playing(st)
        if st["playing"] is not None:
            self._playing = st["playing"]
        return st

    def _poll(self) -> float:
        return self.poll_interval if self.poll_interval is not None else POLL_INTERVAL

    async def _wait_for(self, playing: bool, timeout: float) -> dict:
        st: dict = {}
        with anyio.move_on_after(timeout):
            while True:
                try:
                    st = await self.state()
                except StudioError:
                    st = {}
                if st.get("playing") is playing:
                    return st
                await anyio.sleep(self._poll())
        raise StudioError(
            f"Timed out after {timeout:.0f}s waiting for Studio to {'start' if playing else 'stop'} play; "
            f"last state: {st.get('raw', st)!r}"[:800]
        )

    async def _set_play(self, start: bool) -> None:
        st = await self.state()
        if st.get("playing") is start:
            return
        last: Exception | None = None
        for _ in range(2):  # start/stop is known to fail sometimes after the first run: retry once
            try:
                await self.call("start_stop_play", is_start=start, timeout=PLAY_TIMEOUT)
            except StudioError as e:
                last = e
            try:
                await self._wait_for(start, PLAY_TIMEOUT)
                self._playing = start
                return
            except StudioError as e:
                last = e
        raise StudioError(f"Could not {'start' if start else 'stop'} play: {last}")

    async def play(self, ready: bool = True, ready_timeout: float = 30.0) -> dict:
        """Start a playtest and wait until the Server datamodel is available, then (ready=True) until
        the game itself is up (see wait_ready). Returns the readiness info ({} when ready=False)."""
        await self._set_play(True)
        if not ready:
            return {}
        return await self.wait_ready(ready_timeout)

    async def wait_ready(self, timeout: float = 30.0, grace: float = 0.5) -> dict:
        """One Server-datamodel call that returns once ForgeProbe exists and the game booted
        (workspace.ServerBooted, or a spawned character for games that never set it).
        Never raises: {"ready": False, "error": ...} when it can't tell."""
        code = READY_LUAU.replace("__LIMIT__", f"{float(timeout):g}").replace("__GRACE__", f"{float(grace):g}")
        last = ""
        for _ in range(3):  # the Server datamodel can lag the state by a moment
            try:
                text = await self.execute_luau(code, "Server", timeout=timeout + 10)
            except StudioError as e:
                last = str(e)
                await asyncio.sleep(0.2)
                continue
            obj = extract_json(text)
            if isinstance(obj, dict):
                return obj
            last = f"unparseable: {text[:200]!r}"
        return {"ready": False, "error": last[:300]}

    async def stop(self) -> None:
        """Stop the playtest and wait until back in Edit."""
        await self._set_play(False)

    async def console(self) -> str:
        return await self.call("get_console_output")

    async def screenshot(self, out: Path, camera: tuple | list | None = None,
                         look_at: tuple | list | None = None) -> Path | None:
        """screen_capture; writes the image to `out` and returns it, or None if no image came back.
        camera/look_at (x, y, z) place the capture camera."""
        out = Path(out)
        self._capture_n += 1
        args: dict = {"capture_id": f"ScreenCapture_{self._capture_n}"}
        if camera is not None and look_at is not None:
            args.update(camera_position=list(camera), look_at_position=list(look_at))
        try:
            result = await self.call_result("screen_capture", **args)
        except StudioError as e:
            print(f"[studio] screenshot failed: {e}", file=self._errlog)
            return None
        img = extract_image(result.content)
        out.parent.mkdir(parents=True, exist_ok=True)
        if img is not None:
            out.write_bytes(img[0])
            return out
        # Some builds may save to disk and return a path instead.
        for m in re.finditer(r"(/[^\s\"']+\.(?:png|jpe?g))", content_text(result.content)):
            src = Path(m.group(1))
            if src.exists():
                shutil.copyfile(src, out)
                return out
        return None

    async def probe_report(self) -> dict:
        """ForgeProbe report from the Server datamodel (during play). {"error": ...} on failure."""
        try:
            text = await self.execute_luau(PROBE_CODE, "Server")
        except StudioError as e:
            return {"error": str(e)}
        obj = extract_json(text)
        if isinstance(obj, dict):
            return obj
        return {"error": f"unparseable ForgeProbe report: {text[:500]!r}"}

    # ---- sync

    def _serve(self, root: Path, port: int) -> int:
        """Keep one long-lived file server per root (the HTTP fallback of the pull script).
        Falls back to a free port when `port` is taken (e.g. another agent's Studio session)."""
        for p, (r, _) in self._servers.items():
            if r == root:
                return p
        current = self._servers.get(port)
        if current is not None:  # this port serves another root: move it
            _shutdown_server(current[1])
            del self._servers[port]
        try:
            server = fsync.serve_in_thread(root, port)
        except OSError:
            try:
                server = fsync.serve_in_thread(root, 0)
            except OSError as e:
                raise StudioError(f"cannot serve {root} on 127.0.0.1: {e}") from e
        actual = int(server.server_address[1])
        self._servers[actual] = (root, server)
        return actual

    def pushed(self, root: Path) -> dict[str, str] | None:
        """{path: hash} this client last pushed from `root` into the selected Studio, if known."""
        return self._pushed.get((str(self.studio_id), str(Path(root).resolve())))

    async def sync(self, root: Path, port: int | None = None, prune: bool = True,
                   incremental: bool = True) -> str:
        """Push `root` into the Edit datamodel (stops a running playtest first).

        incremental (default): the manifest (with hashes) and the sources changed since this client's
        last push travel inside one execute_luau call; Studio skips files whose ForgeHash matches and
        fetches anything else that changed from the long-lived local file server.
        incremental=False: the original path (Studio fetches the manifest and every file over HTTP).
        """
        root = Path(root).resolve()
        port = self._serve(root, int(port or self.settings.sync_port))
        entries = fsync.manifest_entries(root)
        fsync.write_manifest(root)  # still written: the HTTP fallback and `sync.py pull` read it
        if self._playing is not False:
            st = await self.state()
            if st.get("playing"):
                await self.stop()
        if not incremental:
            return await self.execute_luau(fsync.pull_luau(port, prune=prune, force=True), "Edit")
        key = (str(self.studio_id), str(root))
        inline = fsync.inline_plan(root, entries, self._pushed.get(key))
        out = await self.execute_luau(fsync.pull_luau(port, prune=prune, manifest=entries, inline=inline), "Edit")
        if str(out).startswith("OK"):
            self._pushed[key] = fsync.hashes(entries)
        else:
            self._pushed.pop(key, None)
        return out

    async def hot_reload(self, root: Path) -> dict:
        """Push changed server ModuleScripts into the running playtest without stopping it.

        Returns {"reloaded": {path: result}, "restart": [(path, why)], "changed": [...]}. When
        "restart" is non-empty those changes need stop -> sync -> play; nothing was reloaded then.
        The Edit datamodel is untouched (it is locked during play); the next sync() pushes it.
        """
        root = Path(root).resolve()
        entries = fsync.manifest_entries(root)
        key = (str(self.studio_id), str(root))
        pushed = self._pushed.get(key)
        if pushed is None:
            return {"reloaded": {}, "restart": [("*", "nothing synced from this root yet")], "changed": []}
        d = fsync.changed_paths(entries, pushed)
        changed = d["changed"] + d["added"] + d["removed"]
        sources = {p: (root / p).read_text(encoding="utf-8", errors="replace") for p in d["changed"] + d["added"]}
        plan = hot_reload_plan(entries, changed, sources, added=d["added"])
        if plan["restart"] or not plan["reload"]:
            return {"reloaded": {}, "restart": plan["restart"], "changed": changed}
        items = [{"path": e["path"], "service": e["service"], "dirs": e["dirs"], "name": e["name"],
                  "source": sources[e["path"]]} for e in plan["reload"]]
        code = HOT_RELOAD_LUAU.replace("__ITEMS__", fsync.long_string(json.dumps(items)), 1)
        text = await self.execute_luau(code, "Server")
        obj = extract_json(text)
        return {"reloaded": obj if isinstance(obj, dict) else {"*": text[:300]}, "restart": [], "changed": changed}


def _shutdown_server(server: Any) -> None:
    try:
        server.shutdown()
        server.server_close()
    except Exception:
        pass
