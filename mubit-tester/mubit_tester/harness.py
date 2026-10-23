"""Python side of the in-game test harness (ServerStorage.ForgeTest), see docs/TESTER.md.

Every command is one `execute_luau` in the Server datamodel that invokes the ForgeTest
BindableFunction with a command name and a JSON argument object, and returns its JSON reply
`{"ok": bool, "result": any, "error": str?}`.

Players are addressed by name, UserId or helmet number ("1".."4"); the value is passed through as
`userId` and the server resolves it.
"""

from __future__ import annotations

import asyncio
import json
import time
from typing import Any

from forge.studio import StudioError, extract_json

READY_POLL = 1.0
NOT_RUNNING_HINT = ("Is a playtest running (play_start / multiplayer_start) and is "
                    "ServerScriptService/ForgeTest.server.luau synced?")


class HarnessError(RuntimeError):
    pass


def _long_bracket(s: str) -> str:
    """Wrap `s` in a Luau long-bracket string whose level doesn't occur inside it."""
    level = 2
    while f"]{'=' * level}]" in s:
        level += 1
    eq = "=" * level
    return f"[{eq}[{s}]{eq}]"


def build_call_luau(cmd: str, args: dict | None = None) -> str:
    if not cmd or not all(c.isalnum() or c == "_" for c in cmd):
        raise ValueError(f"bad harness command {cmd!r}")
    payload = json.dumps(args or {}, ensure_ascii=False, separators=(",", ":"), default=str)
    missing = json.dumps({"ok": False, "error": "ForgeTest not found in ServerStorage. " + NOT_RUNNING_HINT})
    return (
        'local f = game:GetService("ServerStorage"):WaitForChild("ForgeTest", 5)\n'
        f"if not f then return {_long_bracket(missing)} end\n"
        f'return f:Invoke("{cmd}", {_long_bracket(payload)})'
    )


def parse_reply(text: Any, cmd: str = "?") -> Any:
    """Return `result` from a ForgeTest reply; raise HarnessError on ok=false or garbage."""
    obj = text if isinstance(text, dict) else extract_json(text if isinstance(text, str) else str(text))
    if not isinstance(obj, dict) or "ok" not in obj:
        raise HarnessError(f"{cmd}: unparseable ForgeTest reply: {str(text)[:400]!r}")
    if not obj.get("ok"):
        raise HarnessError(f"{cmd}: {obj.get('error') or 'failed (no error message)'}")
    return obj.get("result")


class Harness:
    """Wraps a connected forge.studio.Studio (or anything with execute_luau/state/play/stop)."""

    def __init__(self, studio: Any, timeout: float = 60.0) -> None:
        self.studio = studio
        self.timeout = timeout
        self.started_play = False

    async def call(self, cmd: str, **args: Any) -> Any:
        code = build_call_luau(cmd, args)
        try:
            text = await asyncio.wait_for(self.studio.execute_luau(code, "Server"), self.timeout)
        except asyncio.TimeoutError as e:
            raise HarnessError(f"{cmd}: timed out after {self.timeout:.0f}s") from e
        except StudioError as e:
            raise HarnessError(f"{cmd}: {e}. {NOT_RUNNING_HINT}") from e
        return parse_reply(text, cmd)

    async def ensure_ready(self, timeout: float = 30) -> dict:
        """Make sure play is running and ForgeTest answers `ping` (starts solo play if needed)."""
        st = await self.studio.state()
        if st.get("playing") is not True:
            await self.studio.play()
            self.started_play = True
        deadline = time.monotonic() + timeout
        last: Exception | None = None
        while True:
            try:
                res = await self.call("ping")
                return res if isinstance(res, dict) else {"result": res}
            except HarnessError as e:
                last = e
            if time.monotonic() >= deadline:
                raise HarnessError(f"harness not ready after {timeout:.0f}s: {last}")
            await asyncio.sleep(READY_POLL)

    # ---- thin helpers

    async def ping(self) -> Any:
        return await self.call("ping")

    async def players(self) -> list[dict]:
        return await self.call("players") or []

    async def observe(self, user_id: Any, radius: float | None = None, max: int | None = None) -> dict:
        args: dict = {"userId": user_id}
        if radius is not None:
            args["radius"] = radius
        if max is not None:
            args["max"] = max
        return await self.call("observe", **args)

    async def act(self, user_id: Any, action: str, **args: Any) -> dict:
        return await self.call("act", userId=user_id, action=action, args=args)

    async def act_all(self, action: str, **args: Any) -> dict[str, Any]:
        """Run one action on every connected player concurrently -> {name: result | {"error"}}."""
        players = await self.players()

        async def one(p: dict) -> Any:
            try:
                return await self.act(p.get("userId"), action, **args)
            except HarnessError as e:
                return {"done": False, "error": str(e)}

        results = await asyncio.gather(*(one(p) for p in players))
        return {str(p.get("name") or p.get("userId")): r for p, r in zip(players, results)}

    async def query(self, **args: Any) -> list[dict]:
        return await self.call("query", **{k: v for k, v in args.items() if v is not None}) or []

    async def inspect(self, path: str) -> dict:
        return await self.call("inspect", path=path)

    async def events(self, since: float | None = None) -> dict:
        return await self.call("events", **({} if since is None else {"since": since}))

    async def counters(self) -> dict:
        return await self.call("counters")

    async def probe(self) -> dict:
        """ForgeProbe report (errors, warnings, counters) through forge.studio."""
        return await self.studio.probe_report()
