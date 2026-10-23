"""The build loop versions each iteration and rolls back when the critic score drops."""

from __future__ import annotations

import io
import json
import shutil

import pytest

from forge.llm import FakeLLM
from forge.loop import UI, new_game
from forge.memory import RunStore, slugify
from forge.versions import GameVersions
from test_loop import CONFIG_SRC, CRITIQUE, GAME_BROKEN, GAME_CRITIC_FIXED, GAME_FIXED, LESSONS, SPEC, luau, settings  # noqa: F401

pytestmark = pytest.mark.skipif(shutil.which("luau-compile") is None, reason="luau-compile not on PATH")


async def test_score_drop_rolls_back_to_the_best_version(settings):
    worse = {**CRITIQUE, "score": 3, "summary": "the leaderstats change broke the round"}
    llm = FakeLLM({
        "designer": [json.dumps(SPEC)],
        "coder": [luau(CONFIG_SRC), luau(GAME_BROKEN)],
        "fixer": [luau(GAME_FIXED), luau(GAME_CRITIC_FIXED)],
        "critic": [json.dumps(CRITIQUE), json.dumps(worse)],
        "reflector": [LESSONS, LESSONS],
    })
    idea = "Coin rush rollback"
    slug = await new_game(idea, iterations=2, use_studio=False, settings=settings, llm=llm, ui=UI(io.StringIO()))
    store = RunStore(settings, slug)
    game_file = store.game_dir / "ServerScriptService/Game.server.luau"

    its = store.load_state()["iterations"]
    assert [(it["version"], it["score"]) for it in its] == [("v1", 6), ("v2", 3)]
    assert its[1]["rolled_back_to"] == "v1" and its[1]["fixes"] == 0
    assert game_file.read_text().strip() == GAME_FIXED.strip()  # iteration 1's tested code
    assert [c.role for c in llm.calls].count("fixer") == 2  # no fixer on the rolled-back iteration
    assert "Rolled back to v1" in [c.user for c in llm.calls if c.role == "reflector"][1]
    log = GameVersions(store.game_dir).log()
    assert log[-1]["message"].startswith("rollback to v1: iteration 2 scored 3")
    assert slug == slugify(idea)


async def test_small_score_dip_does_not_roll_back(settings):
    dip = {**CRITIQUE, "score": 5.5}
    llm = FakeLLM({
        "designer": [json.dumps(SPEC)],
        "coder": [luau(CONFIG_SRC), luau(GAME_BROKEN)],
        "fixer": [luau(GAME_FIXED), luau(GAME_CRITIC_FIXED), luau(GAME_CRITIC_FIXED)],
        "critic": [json.dumps(CRITIQUE), json.dumps(dip)],
        "reflector": [LESSONS, LESSONS],
    })
    slug = await new_game("Coin rush dip", iterations=2, use_studio=False, settings=settings, llm=llm,
                          ui=UI(io.StringIO()))
    its = RunStore(settings, slug).load_state()["iterations"]
    assert its[1].get("rolled_back_to") is None
