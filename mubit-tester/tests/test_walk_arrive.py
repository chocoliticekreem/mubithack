"""walk_to arrival contract: within 1 stud of the target point by default, `arrive_radius` loosens it.
The shipped `walk_arrive` scenario must pass on a harness that honours it and fail on the old
behaviour (stopping ~5 studs short, so testers never stood on touch pads). Also checks both Luau
actuators (client agent and swarm bots) implement the same default."""

from __future__ import annotations

import math
import re
from pathlib import Path

from mubit_tester.harness import Harness
from mubit_tester.scenario import load_scenario, run_scenario
from test_harness import FakeStudio

REPO = Path(__file__).resolve().parent.parent.parent
ROBLOX = REPO / "mubit-tester" / "roblox"


def _world(short_by: float | None):
    """A one-player harness whose walk_to stops `short_by` studs short (None: honours arrive_radius)."""
    me = {"userId": 1, "name": "Player1", "pos": [0.0, 3.0, 0.0], "health": 100}

    def act(args):
        a = args.get("args") or {}
        goal = a["pos"]
        stop = short_by if short_by is not None else min(0.4, float(a.get("arrive_radius") or 1.0))
        dx, dz = goal[0] - me["pos"][0], goal[2] - me["pos"][2]
        d = math.hypot(dx, dz)
        k = max(0.0, (d - stop) / d) if d else 0.0
        me["pos"] = [me["pos"][0] + dx * k, goal[1], me["pos"][2] + dz * k]
        dist = math.hypot(goal[0] - me["pos"][0], goal[2] - me["pos"][2])
        radius = float(a.get("arrive_radius") or 1.0)
        return {"done": dist <= radius, "dist": round(dist, 2), "pos": me["pos"], "detail": f"{dist:.1f} studs"}

    return FakeStudio({"players": lambda a: [dict(me)], "act": act})


async def test_walk_arrive_scenario_passes_within_one_stud():
    sc = load_scenario("walk_arrive", REPO)
    res = await run_scenario(Harness(_world(None)), sc)
    assert res["passed"], res["steps"]


async def test_walk_arrive_scenario_catches_stopping_short():
    sc = load_scenario("walk_arrive", REPO)
    res = await run_scenario(Harness(_world(5.0)), sc)
    assert not res["passed"]
    failed = [s for s in res["steps"] if not s["ok"]]
    assert failed and failed[0]["label"] in ("walk 12 studs", "arrived within 1 stud")


def test_luau_actuators_default_to_one_stud():
    agent = (ROBLOX / "ForgeTestAgent.client.luau").read_text()
    server = (ROBLOX / "ForgeTest.server.luau").read_text()
    assert re.search(r"^local ARRIVE = 1\b", agent, re.M)
    assert "args.arrive_radius" in agent
    assert re.search(r"^local BOT_ARRIVE = 1\b", server, re.M)
    assert "a.arrive_radius" in server
