"""Roblox Studio MCP client (stdio) for forge.

Spawns Studio's bundled StudioMCP proxy (settings.studio_mcp_path) and talks MCP over stdio using
the `mcp` SDK. Every Studio tool needs a studio_id; `Studio` picks one automatically on the first
call (or via `select()`).

Observed shapes (StudioMCP 1.0.0, protocol 2025-11-25): results come back as text content; e.g.
list_roblox_studios -> '{"studios":[{"id": ..., "name": ...}]}'. Shapes of the other tools aren't
documented, so the parsers below are defensive (JSON when possible, plain text otherwise).
"""

from __future__ import annotations

import base64
import json
import re
import shutil
import sys
from contextlib import AsyncExitStack
from pathlib import Path
from typing import Any, Iterable, TextIO

import anyio
from mcp.client.session import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client

from forge.config import Settings, load_settings

OPEN_STUDIO_HINT = (
    "Open Roblox Studio with a place, and enable Assistant → ⋯ → Manage MCP Servers → MCP "
    "(\"Enable Studio as MCP server\")."
)
DEFAULT_CALL_TIMEOUT = 120.0
PLAY_TIMEOUT = 60.0
POLL_INTERVAL = 1.0
DATAMODELS = ("Edit", "Server", "Client")

PROBE_CODE = 'return game:GetService("ServerStorage"):WaitForChild("ForgeProbe", 5):Invoke("report")'


class StudioError(RuntimeError):
    pass


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


# --------------------------------------------------------------------------- client


class Studio:
    """Async context manager wrapping the StudioMCP stdio server."""

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
        self._errlog = errlog or sys.stderr
        self._stack: AsyncExitStack | None = None
        self._session: ClientSession | None = None
        self._capture_n = 0
        self._servers: dict[int, tuple[Path, Any]] = {}

    # ---- lifecycle

    async def __aenter__(self) -> "Studio":
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
        return self

    async def __aexit__(self, *exc: Any) -> None:
        for _, server in self._servers.values():
            _shutdown_server(server)
        self._servers.clear()
        stack, self._stack, self._session = self._stack, None, None
        if stack is not None:
            await stack.aclose()

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
        try:
            with anyio.fail_after(limit):
                result = await self._session.call_tool(tool, args, read_timeout_seconds=limit)
        except TimeoutError as e:
            raise StudioError(f"{tool} timed out after {limit:.0f}s") from e
        except StudioError:
            raise
        except Exception as e:  # MCP protocol errors, broken pipe, etc.
            raise StudioError(f"{tool} failed: {type(e).__name__}: {e}") from e
        if getattr(result, "is_error", False):
            raise StudioError(f"{tool} error: {content_text(result.content) or result}")
        return result

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
        studios = await self.list_studios()
        if not studios:
            raise StudioError(f"No Roblox Studio is connected to MCP. {OPEN_STUDIO_HINT}")
        chosen = studios[0]
        if name_hint:
            matches = [s for s in studios if name_hint.lower() in str(s.get("name", "")).lower()]
            if not matches:
                names = ", ".join(repr(s.get("name")) for s in studios)
                raise StudioError(f"No connected Studio matches {name_hint!r}; open: {names}")
            chosen = matches[0]
        self.studio_id = chosen["id"]
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
        return st

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
                await anyio.sleep(POLL_INTERVAL)
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
                return
            except StudioError as e:
                last = e
        raise StudioError(f"Could not {'start' if start else 'stop'} play: {last}")

    async def play(self) -> None:
        """Start a playtest and wait until the Server datamodel is available."""
        await self._set_play(True)

    async def stop(self) -> None:
        """Stop the playtest and wait until back in Edit."""
        await self._set_play(False)

    async def console(self) -> str:
        return await self.call("get_console_output")

    async def screenshot(self, out: Path) -> Path | None:
        """screen_capture; writes the image to `out` and returns it, or None if no image came back."""
        out = Path(out)
        self._capture_n += 1
        try:
            result = await self.call_result("screen_capture", capture_id=f"ScreenCapture_{self._capture_n}")
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

    async def sync(self, root: Path, port: int | None = None) -> str:
        """Write manifest, serve `root` on 127.0.0.1:port, run pull_luau in the Edit datamodel."""
        from forge import sync as fsync

        root = Path(root).resolve()
        port = int(port or self.settings.sync_port)
        fsync.write_manifest(root)
        current = self._servers.get(port)
        if current is None or current[0] != root:
            if current is not None:
                _shutdown_server(current[1])
            try:
                server = fsync.serve_in_thread(root, port)
            except OSError as e:
                raise StudioError(f"cannot serve {root} on 127.0.0.1:{port}: {e}") from e
            self._servers[port] = (root, server)
        st = await self.state()
        if st.get("playing"):
            await self.stop()
        return await self.execute_luau(fsync.pull_luau(port), "Edit")


def _shutdown_server(server: Any) -> None:
    try:
        server.shutdown()
        server.server_close()
    except Exception:
        pass
