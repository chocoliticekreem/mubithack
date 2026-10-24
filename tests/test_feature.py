"""forge feature: plan -> new modules + hook-in edits -> compile -> version (no Studio here)."""

from __future__ import annotations

import dataclasses
import io
import json
import shutil

import pytest

from forge.config import load_settings
from forge.feature import add_feature, validate_plan
from forge.llm import FakeLLM, load_prompt
from forge.loop import UI
from forge.memory import RunStore
from forge.versions import GameVersions

pytestmark = pytest.mark.skipif(shutil.which("luau-compile") is None, reason="luau-compile not on PATH")

MAIN = "ServerScriptService/Main.server.luau"
NEW = "ServerScriptService/Services/FlareUpService.luau"


@pytest.fixture
def game(tmp_path):
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")
    store = RunStore(s, "fab")
    store.ensure()
    store.save_spec({"title": "F", "pitch": "firefighters", "core_loop": "spray", "modules": [], "base_files": [MAIN]})
    store.save_state(store.new_state("idea"))
    (store.game_dir / MAIN).parent.mkdir(parents=True, exist_ok=True)
    (store.game_dir / MAIN).write_text("-- Main: boots services\nprint('boot')\n")
    return s, store


def plan(**over):
    return json.dumps({"summary": "fires reignite", "new_modules": [
        {"path": NEW, "purpose": "relights a burnt part every 40s", "depends": []}],
        "edits": [{"path": MAIN, "change": "print that flare-ups are on"}],
        "telemetry": ["flareups"], "acceptance": ["a fire reignites"], **over})


async def test_feature_builds_new_modules_and_hook_edits_and_saves_a_version(game):
    s, store = game
    llm = FakeLLM({"planner": [plan()],
                   "coder": ["```luau\nlocal F = {}\nreturn F\n```"],
                   "fixer": ["```luau\n-- Main: boots services\nprint('boot')\nprint('flare-ups on')\n```"]})
    res = await add_feature(s, "fab", "make fires reignite sometimes", llm=llm, ui=UI(io.StringIO()),
                            iterations=0, log=lambda _: None)
    assert res["built"] == [NEW] and res["edited"] == [MAIN] and res["compile_errors"] == []
    assert (store.game_dir / NEW).exists() and "flare-ups on" in (store.game_dir / MAIN).read_text()
    spec = store.load_spec()
    assert NEW in [m["path"] for m in spec["modules"]] and spec["features"][0]["request"].startswith("make fires")
    assert "flareups" in next(m for m in spec["modules"] if m["path"] == NEW)["purpose"]
    log = [v["message"] for v in GameVersions(store.game_dir).log()]
    assert log[0].startswith("before feature") and log[-1].startswith("feature: make fires reignite")
    assert "make fires reignite sometimes" in llm.calls[0].user and "## Game files" in llm.calls[0].user
    assert (store.dir / "features.jsonl").exists()


def test_plan_validation_drops_unsafe_or_impossible_parts(tmp_path):
    (tmp_path / "ServerScriptService").mkdir()
    (tmp_path / MAIN).write_text("x")
    p = validate_plan({"summary": "s", "new_modules": [
        {"path": NEW}, {"path": MAIN}, {"path": "../../etc/x.luau"}, {"path": "Workspace/X.luau"}],
        "edits": [{"path": MAIN, "change": "c"}, {"path": "missing.luau", "change": "c"}]}, tmp_path)
    assert [m["path"] for m in p["new_modules"]] == [NEW]
    assert [e["path"] for e in p["edits"]] == [MAIN]


async def test_empty_plan_builds_nothing(game):
    s, store = game
    llm = FakeLLM({"planner": [json.dumps({"summary": "s", "new_modules": [], "edits": []})]})
    res = await add_feature(s, "fab", "x", llm=llm, ui=UI(io.StringIO()), iterations=0, log=lambda _: None)
    assert res["status"] == "nothing_to_build"


def test_planner_prompt_exists():
    assert "new_modules" in load_prompt("planner")


async def test_planner_hears_client_code_counts_and_the_game_gets_the_runtime(game):
    # planner.md (frozen) asks for counters "on the server"; overnight that became one *Ack script per client effect
    from forge.roles import CLIENT_TELEMETRY_NOTE

    s, store = game
    llm = FakeLLM({"planner": [json.dumps({"summary": "s", "new_modules": [], "edits": []})]})
    await add_feature(s, "fab", "pop the HUD on coins", llm=llm, ui=UI(io.StringIO()), iterations=0,
                      log=lambda _: None)
    user = llm.calls[0].user
    assert CLIENT_TELEMETRY_NOTE.rstrip() in user and "*Ack module" in user
    runtime = (store.game_dir / "ReplicatedStorage/ForgeTelemetry.luau").read_text()
    assert runtime == (s.base_game_dir / "ReplicatedStorage/ForgeTelemetry.luau").read_text()
    assert "ForgeTelemetryRemote" in runtime
