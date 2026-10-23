"""Python side of the in-game test harness (ServerStorage.ForgeTest), see docs/TESTER.md.

Every command is one `execute_luau` in the Server datamodel that invokes the ForgeTest
BindableFunction with a command name and a JSON argument object, and returns its JSON reply
`{"ok": bool, "result": any, "error": str?}`.

Players are addressed by name, UserId or helmet number ("1".."4"); the value is passed through as
`userId` and the server resolves it.

Routing (multiplayer / Team Test):
- A local "Clients and Servers" test opens a separate Studio window for the server. When the
  selected window has no Server datamodel, `relocate` (given by the MCP server) finds the window
  that has one and the call is retried there.
- A Team Test with real friends runs the server in the cloud, so no window has a Server datamodel.
  Then commands are relayed from a Client datamodel through
  `ForgeTestRemote:InvokeServer("ForgeTest", "call", cmd, argsJson)` (`mode = "client"`).

Errors starting with "unsupported:" mean the game can't do that yet (missing or K0-stub service);
see `is_unsupported`.
"""

from __future__ import annotations

import asyncio
import json
import time
from typing import Any, Awaitable, Callable

from forge.studio import StudioError, extract_json

READY_POLL = 1.0
NOT_RUNNING_HINT = ("Is a playtest running (play_start / multiplayer_start) and is "
                    "ServerScriptService/ForgeTest.server.luau synced?")
UNSUPPORTED = "unsupported:"


class HarnessError(RuntimeError):
    pass


def is_unsupported(err: Any) -> bool:
    """True for harness errors that mean "the game doesn't have this yet" (skip, don't fail)."""
    return UNSUPPORTED in str(err)


def _long_bracket(s: str) -> str:
    """Wrap `s` in a Luau long-bracket string whose level doesn't occur inside it."""
    level = 2
    while f"]{'=' * level}]" in s:
        level += 1
    eq = "=" * level
    return f"[{eq}[{s}]{eq}]"


def _check_cmd(cmd: str) -> None:
    if not cmd or not all(c.isalnum() or c == "_" for c in cmd):
        raise ValueError(f"bad harness command {cmd!r}")


def _payload(args: dict | None) -> str:
    return json.dumps(args or {}, ensure_ascii=False, separators=(",", ":"), default=str)


def build_call_luau(cmd: str, args: dict | None = None) -> str:
    _check_cmd(cmd)
    missing = json.dumps({"ok": False, "error": "ForgeTest not found in ServerStorage. " + NOT_RUNNING_HINT})
    return (
        'local f = game:GetService("ServerStorage"):WaitForChild("ForgeTest", 5)\n'
        f"if not f then return {_long_bracket(missing)} end\n"
        f'return f:Invoke("{cmd}", {_long_bracket(_payload(args))})'
    )


def build_relay_luau(cmd: str, args: dict | None = None) -> str:
    """Same call, run in a Client datamodel and relayed to the server through ForgeTestRemote."""
    _check_cmd(cmd)
    missing = json.dumps({"ok": False, "error": "ForgeTestRemote not found in ReplicatedStorage. " + NOT_RUNNING_HINT})
    return (
        'local rf = game:GetService("ReplicatedStorage"):WaitForChild("ForgeTestRemote", 5)\n'
        f"if not rf then return {_long_bracket(missing)} end\n"
        f'return rf:InvokeServer("ForgeTest", "call", "{cmd}", {_long_bracket(_payload(args))})'
    )


def parse_reply(text: Any, cmd: str = "?") -> Any:
    """Return `result` from a ForgeTest reply; raise HarnessError on ok=false or garbage."""
    obj = text if isinstance(text, dict) else extract_json(text if isinstance(text, str) else str(text))
    if not isinstance(obj, dict) or "ok" not in obj:
        raise HarnessError(f"{cmd}: unparseable ForgeTest reply: {str(text)[:400]!r}")
    if not obj.get("ok"):
        raise HarnessError(f"{cmd}: {obj.get('error') or 'failed (no error message)'}")
    return obj.get("result")


def _clean(args: dict) -> dict:
    return {k: v for k, v in args.items() if v is not None}


class Harness:
    """Wraps a connected forge.studio.Studio (or anything with execute_luau/state/play/stop).

    `relocate`: optional async callback used when a Server-datamodel call fails; it should point
    `studio` at the right window (returning "server"), switch to client relay (returning "client")
    or return None when nothing better exists.
    """

    def __init__(self, studio: Any, timeout: float = 60.0,
                 relocate: Callable[[], Awaitable[str | None]] | None = None, mode: str = "server") -> None:
        self.studio = studio
        self.timeout = timeout
        self.started_play = False
        self.relocate = relocate
        self.mode = mode  # "server" (execute in the Server datamodel) | "client" (relay)

    async def _once(self, cmd: str, args: dict) -> Any:
        if self.mode == "client":
            code, dm = build_relay_luau(cmd, args), "Client"
        else:
            code, dm = build_call_luau(cmd, args), "Server"
        text = await asyncio.wait_for(self.studio.execute_luau(code, dm), self.timeout)
        return parse_reply(text, cmd)

    async def call(self, cmd: str, **args: Any) -> Any:
        try:
            try:
                return await self._once(cmd, args)
            except StudioError:
                if self.relocate is None:
                    raise
                mode = await self.relocate()
                if not mode:
                    raise
                self.mode = mode
                return await self._once(cmd, args)
        except asyncio.TimeoutError as e:
            raise HarnessError(f"{cmd}: timed out after {self.timeout:.0f}s") from e
        except StudioError as e:
            raise HarnessError(f"{cmd}: {e}. {NOT_RUNNING_HINT}") from e

    async def ensure_ready(self, timeout: float = 30) -> dict:
        """Make sure play is running and ForgeTest answers `ping` (starts solo play if needed)."""
        st = await self.studio.state()
        if st.get("playing") is not True and self.mode != "client":
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

    async def caps(self) -> dict:
        return await self.call("caps") or {}

    async def players(self, instance_id: str | None = None, squad_id: str | None = None) -> list[dict]:
        return await self.call("players", **_clean({"instanceId": instance_id, "squadId": squad_id})) or []

    async def observe(self, user_id: Any, radius: float | None = None, max: int | None = None,
                      instance_id: str | None = None) -> dict:
        args: dict = {"userId": user_id}
        if radius is not None:
            args["radius"] = radius
        if max is not None:
            args["max"] = max
        if instance_id:
            args["instanceId"] = instance_id
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
        return await self.call("query", **_clean(args)) or []

    async def inspect(self, path: str) -> dict:
        return await self.call("inspect", path=path)

    async def events(self, since: float | None = None, instance_id: str | None = None,
                     squad_id: str | None = None, kinds: list[str] | str | None = None) -> dict:
        return await self.call("events", **_clean({"since": since, "instanceId": instance_id,
                                                    "squadId": squad_id, "kinds": kinds}))

    async def counters(self) -> dict:
        return await self.call("counters")

    # ---- lobby / squads / mission instances

    async def squads(self, squad_id: str | None = None, pad: Any = None) -> dict:
        return await self.call("squads", **_clean({"squadId": squad_id, "pad": pad})) or {}

    async def instances(self, instance_id: str | None = None) -> list[dict]:
        return await self.call("instances", **_clean({"instanceId": instance_id})) or []

    async def queue(self, user_id: Any, pad: Any = 1, walk: bool = False, join: bool = False,
                    wait: float | None = None) -> dict:
        return await self.call("queue", **_clean({"userId": user_id, "pad": pad, "walk": walk or None,
                                                   "join": join or None, "wait": wait}))

    async def launch(self, pad: Any = None, squad_id: str | None = None, mission_id: str | None = None,
                     wait: float | None = None) -> dict:
        return await self.call("launch", **_clean({"pad": pad, "squadId": squad_id, "missionId": mission_id,
                                                    "wait": wait}))

    async def mission_start(self, mission_id: str | None = None, players: list | None = None,
                            squad_id: str | None = None, wait: float | None = None) -> dict:
        return await self.call("mission_start", **_clean({"missionId": mission_id, "players": players,
                                                           "squadId": squad_id, "wait": wait}))

    async def mission_end(self, instance_id: str, reason: str = "forced", wait: float | None = None) -> dict:
        return await self.call("mission_end", **_clean({"instanceId": instance_id, "reason": reason, "wait": wait}))

    async def blame(self, instance_id: str | None = None, awards: bool = False) -> dict:
        return await self.call("blame", **_clean({"instanceId": instance_id, "awards": awards or None}))

    async def probe(self) -> dict:
        """ForgeProbe report (errors, warnings, counters) through forge.studio."""
        return await self.studio.probe_report()
