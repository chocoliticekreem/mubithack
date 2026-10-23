"""Tests for mubit_tester.scenario: ops, paths/vars, the runner, timeouts, the shipped scenarios."""

from __future__ import annotations

import copy
import json
import math
from pathlib import Path

import pytest

from mubit_tester import scenario as sm
from mubit_tester.harness import Harness, HarnessError
from mubit_tester.scenario import (ScenarioError, compare, get_path, list_scenarios, load_scenario,
                                   resolve, run_scenario)
from test_harness import PLAYERS, FakeStudio

REPO = Path(__file__).resolve().parent.parent
M = sm._MISSING


class World:
    """A tiny game: players walk instantly; the hydrant prompt raises Water and logs an event."""

    def __init__(self, move: bool = True, refill: str = "water", probe_errors: list | None = None):
        self.players = copy.deepcopy(PLAYERS)
        self.move = move
        self.refill = refill
        self.t = 10.0
        self.log: list[dict] = []
        self.probe_errors = probe_errors or []

    def find(self, who):
        return next(p for p in self.players if str(who) in (str(p["userId"]), p["name"], p["helmet"]))

    def handlers(self) -> dict:
        return {
            "players": lambda a: copy.deepcopy(self.players),
            "events": self.events,
            "act": self.act,
            "query": lambda a: [{"path": "Workspace.Map.Station.Hydrant", "name": "Hydrant", "tags": ["Hydrant"],
                                 "pos": [40, 1, 0], "dist": 40, "attrs": {}}] if a.get("tag") == "Hydrant" else [],
        }

    def events(self, a):
        self.t += 1
        since = a.get("since") or 0
        return {"now": self.t, "events": [e for e in self.log if e["t"] > since]}

    def act(self, a):
        p = self.find(a["userId"])
        args = a.get("args") or {}
        if a["action"] == "walk_to":
            if self.move:
                p["pos"] = list(args.get("pos") or [40, 3, 2])
            return {"done": self.move, "detail": "arrived" if self.move else "stuck"}
        if a["action"] == "interact":
            self.t += 1
            if self.refill == "water":
                p["attrs"]["Water"] = p["attrs"].get("Water", 0) + 50
            elif self.refill == "event":
                self.log.append({"t": self.t, "kind": "prompt", "data": {"prompt": "Hydrant.RefillPrompt"}})
            return {"done": True, "detail": "triggered"}
        return {"done": True}


def harness_for(world: World) -> Harness:
    st = FakeStudio(world.handlers())

    async def probe_report():
        return {"errors": world.probe_errors, "warnings": []}
    st.probe_report = probe_report
    return Harness(st)


# ---------------------------------------------------------------- pure pieces

@pytest.mark.parametrize("op,got,value,base,expect", [
    ("==", 3, 3.0, M, True), ("==", "a", "b", M, False), ("!=", 1, 2, M, True),
    ("<", 1, 2, M, True), (">", 1, 2, M, False), (">=", 2, 2, M, True), ("<", "x", 2, M, False),
    ("exists", 0, None, M, True), ("exists", None, None, M, False), ("exists", M, None, M, False),
    ("missing", M, None, M, True), ("truthy", [], None, M, False), ("falsy", 0, None, M, True),
    ("len==", [], 0, M, True), ("len>=", [1, 2], 3, M, False), ("len>", "abc", 2, M, True),
    ("contains", [1, 2], 2, M, True), ("contains", "hello", "ell", M, True),
    ("contains", [{"kind": "prompt", "data": {"p": "Hydrant.X"}}], "Hydrant", M, True),
    ("contains", [{"kind": "a", "x": 1}], {"kind": "a"}, M, True),
    ("changed", 2, None, 1, True), ("changed", 1, None, 1, False), ("changed", 1, None, M, False),
    ("increased", 5, None, 1, True), ("increased", 5, None, None, True), ("decreased", 5, None, 1, False),
    ("moved", [10, 0, 0], 8, [0, 0, 0], True), ("moved", [1, 0, 0], 8, [0, 0, 0], False),
    ("moved", {"x": 0, "y": 0, "z": 9}, 8, [0, 0, 0], True), ("moved", "x", 8, [0, 0, 0], False),
    ("<", M, 1, M, False),
])
def test_compare(op, got, value, base, expect):
    assert compare(op, got, value, base) is expect


def test_compare_unknown_op():
    with pytest.raises(ScenarioError):
        compare("~=", 1, 1)


def test_get_path_and_wildcards():
    obj = {"result": copy.deepcopy(PLAYERS)}
    assert get_path(obj, "result.0.attrs.Water") == 0
    assert get_path(obj, "result.1.attrs.Water") is M
    assert get_path(obj, "result.*.helmet") == ["1", "2"]
    assert get_path(obj, "result.9.name") is M
    assert get_path(obj, "result.x") is M
    assert get_path(obj, "") is obj


def test_resolve_vars():
    vars = {"p": PLAYERS, "t0": {"now": 5}}
    assert resolve({"since": "$t0.now", "who": ["$p.1.name", "lit"]}, vars) == {"since": 5, "who": ["Player2", "lit"]}
    assert resolve("$p.*.userId", vars) == [-1, -2]
    assert resolve("$", vars) == "$"
    with pytest.raises(ScenarioError, match="unknown variable"):
        resolve("$nope", vars)
    with pytest.raises(ScenarioError, match="path not found"):
        resolve("$p.0.attrs.Nope", vars)


def test_check_wildcard_all_must_hold():
    ok, got = sm.check({"path": "result.*.health", "op": ">", "value": 50}, PLAYERS)
    assert ok and got == [100, 100]
    hurt = copy.deepcopy(PLAYERS)
    hurt[1]["health"] = 0
    assert not sm.check({"path": "result.*.health", "op": ">", "value": 50}, hurt)[0]
    assert not sm.check({"path": "result.*.health", "op": ">", "value": 0}, [])[0]  # nobody -> fail


def test_validate_and_load(tmp_path):
    with pytest.raises(ScenarioError):
        sm.validate({"steps": []})
    with pytest.raises(ScenarioError, match="exactly one"):
        sm.validate({"steps": [{"act": {}, "call": {}}]})
    with pytest.raises(ScenarioError, match="available"):
        load_scenario("does_not_exist", REPO)
    sc = load_scenario('{"name": "x", "steps": [{"wait": 0}]}', REPO)
    assert sc["name"] == "x"


def test_shipped_scenarios_load():
    names = {s["name"] for s in list_scenarios(REPO)}
    assert {"smoke", "hydrant_refill"} <= names
    for n in ("smoke", "hydrant_refill", "smoke.json"):
        load_scenario(n, REPO)
    for p in (REPO / "scenarios").glob("*.json"):
        json.loads(p.read_text())


# ---------------------------------------------------------------- runner

async def test_smoke_passes():
    w = World()
    res = await run_scenario(harness_for(w), load_scenario("smoke", REPO))
    assert res["passed"], res
    assert [s["ok"] for s in res["steps"]] == [True] * 4
    # offset walk: every player moved ~10 studs on x
    assert all(math.isclose(p["pos"][0] - q["pos"][0], 10) for p, q in zip(w.players, PLAYERS))


async def test_smoke_fails_on_probe_errors():
    w = World(probe_errors=[{"message": "boom", "trace": "", "script": "X", "count": 1}])
    res = await run_scenario(harness_for(w), load_scenario("smoke", REPO))
    assert not res["passed"]
    assert res["steps"][-1]["ok"] is False and "len==" in res["steps"][-1]["detail"]


async def test_wait_until_times_out_and_stops():
    sc = load_scenario("smoke", REPO)
    sc["steps"][2]["wait_until"]["timeout"] = 0.2
    sc["steps"][2]["wait_until"]["interval"] = 0.05
    res = await run_scenario(harness_for(World(move=False)), sc)
    assert not res["passed"]
    assert len(res["steps"]) == 2  # act failed (done=false) -> stop_on_fail
    sc["stop_on_fail"] = False
    res = await run_scenario(harness_for(World(move=False)), sc)
    assert [s["ok"] for s in res["steps"]] == [True, False, False, True]
    assert "after 0.2s" in res["steps"][2]["detail"]
    assert res["steps"][2]["ms"] >= 150


@pytest.mark.parametrize("refill", ["water", "event"])
async def test_hydrant_refill_passes_via_water_or_event(refill):
    w = World(refill=refill)
    res = await run_scenario(harness_for(w), load_scenario("hydrant_refill", REPO))
    assert res["passed"], res
    if refill == "event":
        assert any("Hydrant" in json.dumps(e) for e in res["events"])


async def test_hydrant_refill_fails_when_nothing_happens():
    sc = load_scenario("hydrant_refill", REPO)
    sc["steps"][-1]["wait_until"]["timeout"] = 0.2
    sc["steps"][-1]["wait_until"]["interval"] = 0.05
    res = await run_scenario(harness_for(World(refill="none")), sc)
    assert not res["passed"] and res["steps"][-1]["ok"] is False


async def test_baseline_changed_and_harness_errors():
    w = World()
    h = harness_for(w)
    sc = {"name": "b", "stop_on_fail": False, "steps": [
        {"act": {"player": "1", "action": "walk_to", "args": {"pos": [3, 3, 3]}}},
        {"wait_until": {"cmd": "players", "path": "result.0.pos", "op": "changed", "timeout": 0.2, "interval": 0.05}},
        {"call": {"cmd": "inspect", "args": {"path": "Workspace.Nope"}}},
        {"assert": {"cmd": "players", "path": "result.0.pos", "op": "==", "value": [3, 3, 3]}, "label": "at target"},
    ]}
    res = await run_scenario(h, sc)
    oks = [s["ok"] for s in res["steps"]]
    assert oks == [True, False, False, True]  # nothing changes after the first poll baseline
    assert "unknown command inspect" in res["steps"][2]["detail"]
    assert res["steps"][3]["label"] == "at target"
    md = sm.format_result(res)
    assert "FAIL" in md and "at target" in md


async def test_act_offset_needs_position_and_save_vars():
    w = World()
    h = harness_for(w)
    sc = {"name": "v", "steps": [
        {"call": {"cmd": "players"}, "save": "p"},
        {"act": {"player": "$p.1.userId", "action": "walk_to", "offset": [0, 0, 4]}, "save": "walk"},
        {"assert": {"cmd": "players", "path": "result.1.pos", "op": "moved", "from": "$p.1.pos", "value": 3.9}},
        {"wait": 0},
    ]}
    res = await run_scenario(h, sc)
    assert res["passed"], res
    sc["steps"][1]["act"]["player"] = "ghost"
    with pytest.raises(StopIteration):
        w.find("ghost")
    res = await run_scenario(h, sc)
    assert not res["passed"] and "no position" in res["steps"][1]["detail"]


async def test_events_failure_does_not_break_runner():
    class H:
        async def events(self, since=None):
            raise HarnessError("events: nope")

        async def call(self, cmd, **a):
            return {"x": 1}

        async def probe(self):
            return {}
    res = await run_scenario(H(), {"steps": [{"assert": {"cmd": "ping", "path": "result.x", "op": "==", "value": 1}}]})
    assert res["passed"] and res["events"] == []
