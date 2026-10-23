"""Tests for mubit_tester.harness: Luau call building, reply parsing, ensure_ready, helpers."""

from __future__ import annotations

import json
import re
from typing import Any

import pytest

from forge.studio import StudioError
from mubit_tester import harness as hm
from mubit_tester.harness import Harness, HarnessError, build_call_luau, parse_reply

CALL_RE = re.compile(r'Invoke\("(\w+)", \[(=+)\[(.*)\]\2\]\)\s*$', re.S)


def decode_call(code: str) -> tuple[str, dict]:
    m = CALL_RE.search(code)
    assert m, code
    return m.group(1), json.loads(m.group(3))


class FakeStudio:
    """Answers ForgeTest calls from `handlers[cmd](args) -> result` (or raises to send ok=false)."""

    def __init__(self, handlers: dict | None = None, playing: bool = True, ready_after: int = 0):
        self.handlers = handlers or {}
        self.playing = playing
        self.ready_after = ready_after  # number of ping calls that fail first
        self.calls: list[tuple[str, dict]] = []
        self.codes: list[tuple[str, str]] = []
        self.played = 0
        self.stopped = 0
        self.studio_id = "fake-studio"

    async def execute_luau(self, code: str, datamodel: str = "Edit", timeout=None) -> str:
        self.codes.append((code, datamodel))
        if 'ExecuteMultiplayerTestAsync' in code:
            return "unsupported: nope"
        if "ForgeProbe" in code:
            return "ok"
        if not self.playing:
            raise StudioError("execute_luau error: no Server datamodel")
        cmd, args = decode_call(code)
        self.calls.append((cmd, args))
        if cmd == "ping" and self.ready_after > 0:
            self.ready_after -= 1
            return json.dumps({"ok": False, "error": "ForgeTest not found"})
        fn = self.handlers.get(cmd)
        if fn is None:
            if cmd == "ping":
                return json.dumps({"ok": True, "result": {"version": 1, "players": 1}})
            return json.dumps({"ok": False, "error": f"unknown command {cmd}"})
        try:
            return json.dumps({"ok": True, "result": fn(args)})
        except Exception as e:  # noqa: BLE001
            return json.dumps({"ok": False, "error": str(e)})

    async def state(self) -> dict:
        return {"playing": self.playing, "datamodels": ["Edit", "Server"] if self.playing else ["Edit"]}

    async def play(self) -> None:
        self.played += 1
        self.playing = True

    async def stop(self) -> None:
        self.stopped += 1
        self.playing = False

    async def probe_report(self) -> dict:
        return {"errors": [], "warnings": ["w1"], "uptime": 3}

    async def list_studios(self) -> list[dict]:
        return [{"id": "fake-studio", "name": "Forge.rbxlx"}]

    async def select(self, hint=None) -> str:
        return self.studio_id

    async def console(self) -> str:
        return "\n".join(f"line {i}" for i in range(200))

    async def call(self, tool: str, **args: Any) -> str:
        return json.dumps({"datamodels": ["Edit"]})


PLAYERS = [
    {"userId": -1, "name": "Player1", "helmet": "1", "pos": [0, 3, 0], "health": 100, "maxHealth": 100,
     "attrs": {"Water": 0}, "tool": None, "backpack": [], "carrying": None, "downed": False},
    {"userId": -2, "name": "Player2", "helmet": "2", "pos": [5, 3, 0], "health": 100, "maxHealth": 100,
     "attrs": {}, "tool": "Hose", "backpack": [], "carrying": None, "downed": False},
]


def test_build_call_luau_shape():
    code = build_call_luau("observe", {"userId": "1", "radius": 50})
    assert 'game:GetService("ServerStorage"):WaitForChild("ForgeTest", 5)' in code
    assert decode_call(code) == ("observe", {"userId": "1", "radius": 50})
    # no args -> empty object
    assert decode_call(build_call_luau("ping"))[1] == {}


def test_build_call_luau_escapes_long_brackets():
    tricky = {"text": "a]==]b]===]c"}
    code = build_call_luau("act", tricky)
    m = CALL_RE.search(code)
    assert m and len(m.group(2)) == 4
    assert json.loads(m.group(3)) == tricky


def test_build_call_luau_rejects_bad_cmd():
    with pytest.raises(ValueError):
        build_call_luau('ping") os.exit() --')


def test_parse_reply():
    assert parse_reply('{"ok": true, "result": [1, 2]}') == [1, 2]
    assert parse_reply('[RETURNED RESULTS]\n{"ok":true,"result":{"a":1}}') == {"a": 1}
    with pytest.raises(HarnessError, match="no such path"):
        parse_reply('{"ok": false, "error": "no such path"}', "inspect")
    with pytest.raises(HarnessError, match="unparseable"):
        parse_reply("Script error at line 1")


async def test_call_and_helpers():
    st = FakeStudio({
        "players": lambda a: PLAYERS,
        "act": lambda a: {"done": True, "detail": f"{a['action']} by {a['userId']}"},
        "query": lambda a: [{"path": "Workspace.Map.H0", "tags": [a["tag"]]}],
        "events": lambda a: {"now": 12.5, "events": [{"t": 1, "kind": "x", "data": {}}]},
    })
    h = Harness(st)
    assert len(await h.players()) == 2
    res = await h.act("1", "walk_to", pos=[1, 2, 3])
    assert res["done"] is True
    assert st.calls[-1] == ("act", {"userId": "1", "action": "walk_to", "args": {"pos": [1, 2, 3]}})
    assert st.codes[-1][1] == "Server"
    await h.query(tag="Hydrant", near="1", radius=None)
    assert st.calls[-1] == ("query", {"tag": "Hydrant", "near": "1"})  # None dropped
    assert (await h.events(3))["now"] == 12.5 and st.calls[-1][1] == {"since": 3}
    with pytest.raises(HarnessError, match="unknown command inspect"):
        await h.inspect("Workspace.Nope")


async def test_act_all_fans_out_and_collects_errors():
    def act(a):
        if a["userId"] == -2:
            raise RuntimeError("character missing")
        return {"done": True}
    h = Harness(FakeStudio({"players": lambda a: PLAYERS, "act": act}))
    res = await h.act_all("jump")
    assert res["Player1"] == {"done": True}
    assert res["Player2"]["done"] is False and "character missing" in res["Player2"]["error"]


async def test_studio_error_becomes_harness_error_with_hint():
    h = Harness(FakeStudio(playing=False))
    with pytest.raises(HarnessError, match="play_start"):
        await h.players()


async def test_ensure_ready_starts_play_and_polls(monkeypatch):
    monkeypatch.setattr(hm, "READY_POLL", 0.01)
    st = FakeStudio(playing=False, ready_after=2)
    h = Harness(st)
    ping = await h.ensure_ready(timeout=5)
    assert ping["version"] == 1
    assert st.played == 1 and h.started_play
    assert [c for c, _ in st.calls].count("ping") == 3


async def test_ensure_ready_times_out(monkeypatch):
    monkeypatch.setattr(hm, "READY_POLL", 0.01)
    h = Harness(FakeStudio(playing=True, ready_after=10_000))
    with pytest.raises(HarnessError, match="not ready"):
        await h.ensure_ready(timeout=0.05)
    assert not h.started_play
