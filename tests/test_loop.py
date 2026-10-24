"""End-to-end loop test with FakeLLM and no Studio: design -> build -> compile/fix -> critic -> fix -> reflect."""

from __future__ import annotations

import dataclasses
import io
import json
import shutil

import pytest

from forge.config import load_settings
from forge.llm import FakeLLM
from forge.loop import RUNTIME_FILES, UI, correct, new_game
from forge.memory import RunStore, read_lessons, slugify

pytestmark = pytest.mark.skipif(shutil.which("luau-compile") is None, reason="luau-compile not on PATH")

SPEC = {
    "title": "Coin Rush",
    "slug": "coin-rush",
    "pitch": "Collect coins before time runs out",
    "core_loop": "spawn, run to coins, collect, score",
    "modules": [
        {"path": "ServerScriptService/Game.server.luau", "purpose": "spawns coins, awards points",
         "depends": ["ReplicatedStorage/Config.luau"]},
        {"path": "ReplicatedStorage/Config.luau", "purpose": "tunables", "depends": []},
    ],
    "acceptance": ["coins spawn", "touching a coin adds a point"],
}

CONFIG_SRC = """\
local Config = {}
Config.CoinCount = 10
Config.RoundSeconds = 60
return Config
"""

GAME_BROKEN = """\
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Config"))
for i = 1, Config.CoinCount do
    local coin = Instance.new("Part"
    coin.Parent = workspace
end
"""

GAME_FIXED = """\
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Config"))
for i = 1, Config.CoinCount do
    local coin = Instance.new("Part")
    coin.Anchored = true
    coin.Position = Vector3.new(i * 4, 3, 0)
    coin.Parent = workspace
end
"""

GAME_CRITIC_FIXED = GAME_FIXED + """\
local Players = game:GetService("Players")
local function onPlayer(player)
    local stats = Instance.new("Folder")
    stats.Name = "leaderstats"
    stats.Parent = player
end
Players.PlayerAdded:Connect(onPlayer)
for _, p in Players:GetPlayers() do onPlayer(p) end
"""

GAME_HUMAN_FIXED = GAME_CRITIC_FIXED + "-- coins now spin\n"

CRITIQUE = {
    "score": 6,
    "summary": "Coins spawn but there is no scoring",
    "issues": [{"path": "ServerScriptService/Game.server.luau", "problem": "no leaderstats",
                "fix_hint": "create leaderstats on PlayerAdded"}],
    "done": False,
}

LESSONS = "# Forge lessons\n\n- Always close Instance.new( calls.\n- Create leaderstats for scoring games.\n"


def luau(src: str) -> str:
    return f"Here is the file.\n```luau\n{src}```\n"


@pytest.fixture
def settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


async def test_new_game_no_studio(settings):
    responses = {
        "designer": [json.dumps(SPEC)],
        # build order is dependency order: Config first, then Game (with a syntax error)
        "coder": [luau(CONFIG_SRC), luau(GAME_BROKEN)],
        # 1st fixer reply fixes the compile error, 2nd addresses the critic issue
        "fixer": [luau(GAME_FIXED), luau(GAME_CRITIC_FIXED)],
        "critic": [json.dumps(CRITIQUE)],
        "reflector": [LESSONS],
    }
    idea = "Coin rush: collect coins before time runs out"
    llm = FakeLLM(responses, log_path=settings.runs_dir / slugify(idea) / "calls.jsonl")
    out = io.StringIO()
    slug = await new_game(idea, iterations=1, use_studio=False, settings=settings, llm=llm, ui=UI(out))

    assert slug == slugify(idea)
    store = RunStore(settings, slug)
    game = store.game_dir
    assert (game / "ReplicatedStorage/Config.luau").read_text().strip() == CONFIG_SRC.strip()
    assert (game / "ServerScriptService/Game.server.luau").read_text().strip() == GAME_CRITIC_FIXED.strip()

    # only the Forge runtime is copied in, never the human Flame and Blame tree
    for rel in RUNTIME_FILES:
        assert (game / rel).exists(), rel
    assert not (game / "ServerScriptService/Main.server.luau").exists()
    assert not (game / "ReplicatedStorage/Shared").exists()

    spec = store.load_spec()
    assert [m["path"] for m in spec["modules"]] == [m["path"] for m in SPEC["modules"]]

    state = store.load_state()
    assert state["slug"] == slug and state["idea"] == idea
    assert len(state["iterations"]) == 1
    it = state["iterations"][0]
    assert it["n"] == 1 and it["score"] == 6 and it["issues"][0]["problem"] == "no leaderstats"

    rec = store.load_iteration_json(1, "record.json")
    kinds = [f["kind"] for f in rec["fixes"]]
    assert kinds == ["compile", "critic"]
    assert rec["compile_errors"] == []
    assert store.load_iteration_json(1, "critique.json")["score"] == 6
    assert store.load_iteration_json(1, "report.json")["runtime"].startswith("not run")

    assert read_lessons(settings).strip() == LESSONS.strip()

    # calls.jsonl: one line per call, by role
    roles = [c["role"] for c in store.read_calls()]
    assert roles == ["designer", "coder", "coder", "fixer", "critic", "fixer", "reflector"]

    log = out.getvalue()
    for tag in ("[designer]", "[coder]", "[fixer]", "[critic]", "[reflector]", "[check]"):
        assert tag in log, tag

    # human correction on the same game
    llm2 = FakeLLM({"fixer": [luau(GAME_HUMAN_FIXED)]})
    corr = await correct(slug, "Game", "make the coins spin", use_studio=False,
                         settings=settings, llm=llm2, ui=UI(io.StringIO()))
    assert corr["path"] == "ServerScriptService/Game.server.luau"
    assert corr["compile_ok"] is True
    assert (game / "ServerScriptService/Game.server.luau").read_text().endswith("-- coins now spin\n")
    state = store.load_state()
    assert state["corrections"][-1]["kind"] == "human"
    assert state["corrections"][-1]["note"] == "make the coins spin"


def test_lessons_seeded(settings):
    text = read_lessons(settings)
    assert "Forge lessons" in text
    assert (settings.runs_dir / "lessons.md").exists()



class _ReadyStudio:
    def __init__(self, res):
        self.res = res
        self.calls = []

    async def wait_ready(self, timeout=30.0, grace=0.25):
        self.calls.append(timeout)
        if isinstance(self.res, Exception):
            raise self.res
        return self.res


def _sleeps(monkeypatch):
    import asyncio as aio

    import forge.loop as lp
    slept = []

    async def fake_sleep(s):
        slept.append(s)

    monkeypatch.setattr(lp.asyncio, "sleep", fake_sleep)
    return aio, slept


def test_playtest_wait_is_event_based(monkeypatch):
    from forge.loop import wait_for_game
    monkeypatch.delenv("FORGE_PLAY_SECONDS", raising=False)
    monkeypatch.setenv("FORGE_OBSERVE_SECONDS", "3")
    aio, slept = _sleeps(monkeypatch)
    st = _ReadyStudio({"ready": True, "secs": 1.2})
    res = aio.run(wait_for_game(st, 8.0))
    assert res["mode"] == "ready" and slept == [3.0] and st.calls == [10.0]  # boot + 3 s, not a fixed 8 s


def test_playtest_wait_falls_back_and_respects_an_explicit_setting(monkeypatch):
    from forge.loop import wait_for_game
    monkeypatch.delenv("FORGE_PLAY_SECONDS", raising=False)
    aio, slept = _sleeps(monkeypatch)
    res = aio.run(wait_for_game(_ReadyStudio({"ready": False, "error": "no ForgeProbe"}), 8.0))
    assert res["mode"] == "fallback" and "ForgeProbe" in res["error"] and 7.0 < slept[-1] <= 8.0
    res = aio.run(wait_for_game(_ReadyStudio(RuntimeError("studio gone")), 8.0))
    assert res["mode"] == "fallback"
    assert aio.run(wait_for_game(object(), 5.0))["mode"] == "fixed" and slept[-1] == 5.0  # no wait_ready
    monkeypatch.setenv("FORGE_PLAY_SECONDS", "6")
    st = _ReadyStudio({"ready": True})
    assert aio.run(wait_for_game(st, 6.0))["mode"] == "fixed" and st.calls == []  # explicit: old behaviour
