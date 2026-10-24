"""Obby tester abilities: teleport_stage / obby_try (ForgeTest commands), the `obby` observation block, and the
macros and guidance the AI testers get. Contract: checkpoints are tagged Checkpoint with a Stage attribute,
hazards are tagged KillPart."""

from __future__ import annotations

import re
from pathlib import Path

from mubit_tester import ai
from mubit_tester import harness as hm
from mubit_tester.harness import Harness, act_budget
from test_harness import FakeStudio
from test_tester_ai import FakeHarness, ScriptedLLM, _a, _obs, _settings

ROBLOX = Path(__file__).resolve().parent.parent / "roblox"
OBBY = {"stage": 2, "stages": 3, "max_stage": 3, "nearest": {"stage": 2, "dist": 1},
        "next": {"stage": 3, "path": "Workspace.Obby.Checkpoint3", "pos": [0, 11, 30], "dist": 14},
        "hazards": [{"name": "Lava", "path": "Workspace.Obby.Lava", "dist": 9, "pos": [0, 1, 20]}]}


def test_map_obby_actions():
    assert ai.map_action({"action": "teleport_stage", "args": {"stage": "40"}}) == ("teleport_stage", {"stage": 40})
    assert ai.map_action({"action": "teleport_stage", "args": {}}).startswith("error: teleport_stage needs stage")
    assert ai.map_action({"action": "obby_try", "args": {"from_stage": 20, "attempts": 9}}) == \
        ("obby_try", {"from_stage": 20, "attempts": 5})
    assert ai.map_action({"action": "obby_try", "args": {"timeout": 500}}) == \
        ("obby_try", {"attempts": 1, "timeout": 60.0})
    assert "must be a stage number" in ai.map_action({"action": "obby_try", "args": {"from_stage": "top"}})
    assert "obby_try takes attempts" in ai.map_action({"action": "repeat", "args": {
        "action": "obby_try", "args": {"from_stage": 1}, "times": 3}})


async def test_harness_sends_obby_commands_not_acts_and_waits_for_every_attempt(monkeypatch):
    sent = []
    st = FakeStudio({"obby_try": lambda a: sent.append(("obby_try", a)) or {"done": True, "detail": "reached"},
                     "teleport_stage": lambda a: sent.append(("teleport_stage", a)) or {"stage": a["stage"]}})
    waits = []
    real = hm.asyncio.wait_for

    async def wait_for(aw, timeout):
        waits.append(timeout)
        return await real(aw, timeout)
    monkeypatch.setattr(hm.asyncio, "wait_for", wait_for)
    h = Harness(st, timeout=60)
    assert (await h.obby_try(101, from_stage=20, attempts=3))["done"] is True
    assert await h.teleport_stage(101, 40) == {"stage": 40}
    assert sent == [("obby_try", {"userId": 101, "from_stage": 20, "attempts": 3}),
                    ("teleport_stage", {"userId": 101, "stage": 40})]
    assert waits == [act_budget("obby_try", {"attempts": 3}), 60]
    assert act_budget("obby_try", {"attempts": 3}) == 3 * (hm.OBBY_TIMEOUT + hm.OBBY_OVERHEAD) + 5
    assert act_budget("obby_try", {"attempts": 5, "timeout": 60}) == hm.MCP_CALL_LIMIT


class ObbyHarness(FakeHarness):
    def __init__(self):
        super().__init__([{"userId": 101, "name": "Alice", "helmet": 1}])

    async def observe(self, user_id):
        return dict(_obs(user_id), obby=OBBY)

    async def act(self, user_id, action, **args):
        await super().act(user_id, action, **args)
        if action == "obby_try":
            return {"done": False, "reached": False, "detail": "stage 2 -> 3: NOT reached after 2 attempt(s); last: fell "
                    "on hazard Workspace.Obby.Lava at [0, 1, 20]"}
        return {"done": True, "detail": f"{action} ok"}


async def test_obby_testers_get_the_guide_and_the_runner_result(tmp_path):
    llm = ScriptedLLM({"Alice": [_a("obby_try", {"from_stage": 2, "attempts": 2})]}, delay=0)
    h = ObbyHarness()
    rep = await ai.multi_playtest(_settings(tmp_path), "beat the obby", players=1, steps=2, llm=llm, harness=h,
                                  step_seconds=0)
    assert (101, "obby_try", {"from_stage": 2, "attempts": 2}) in h.acts
    first = next(c.user for c in llm.calls if c.role == "player")
    assert "## Obby" in first and "teleport_stage" in first and "Sample the course" in first
    assert '"max_stage":3' in first.replace(" ", "")  # the observation's obby block reaches the tester
    assert "fell on hazard Workspace.Obby.Lava" in rep["steps"][0]["result"]


def test_no_obby_guide_without_checkpoints():
    msg = ai.agent_user_message("g", {"name": "A", "role": "r"}, 1, 2, [], _obs(101), [], [])
    assert "## Obby" not in msg


def test_luau_harness_has_the_obby_contract():
    server = (ROBLOX / "ForgeTest.server.luau").read_text()
    assert re.search(r'OBBY_CHECKPOINT, OBBY_HAZARD = "Checkpoint", "KillPart"', server)
    assert 'inst:GetAttribute("Stage")' in server and 'FindFirstChild("Stage")' in server  # attr or leaderstats
    assert "teleport_stage = teleportStage," in server and "obby_try = obbyTry," in server
    assert "AgentCanJump = true" in server[server.index("local function obbyRun"):]
    assert "out.obby = obby" in server
    for result in ('"reached"', '"fell"', '"stuck"'):
        assert result in server


def test_luau_harness_runs_from_spawn_jumps_hazards_and_bots_move_like_players():
    server = (ROBLOX / "ForgeTest.server.luau").read_text()
    start = server[server.index("local function startPart"):server.index("local function stageOf")]
    assert 'GetTagged("ObbyStart")' in start and '"SpawnLocation"' in start and "stage == 0" in start
    assert "local part = stagePart(cps, stage)" in server  # teleport_stage 0 = the course start
    run_try = server[server.index("local function obbyTry"):]
    assert "local fromPart = stagePart(cps, from)" in run_try and "fromPart :: BasePart" in run_try
    runner = server[server.index("local function obbyRun"):server.index("local function obbyTry")]
    assert "HasTag(hit.Instance, OBBY_HAZARD)" in runner  # a lava strip is not floor: jump it
    assert "solidFloor(under)" in runner and "not solidFloor(workspace:Raycast(" in runner
    bot = server[server.index("local function buildBotModel"):server.index("local attachBot")]
    for prop in ("UseJumpPower", "JumpPower", "JumpHeight", "WalkSpeed"):
        assert f"hum.{prop} = StarterPlayer.Character{prop}" in bot
