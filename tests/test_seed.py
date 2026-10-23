"""forge seed / promote, the seeded-game fixer guard, and FORGE_STUDIO selection."""

from __future__ import annotations

import contextlib
import dataclasses
import io
import json

import pytest

from forge.config import load_settings
from forge.llm import FakeLLM
from forge.loop import RUNTIME_FILES, UI, Run
from forge.memory import RunStore
from forge.seed import SEEDS_DIR, promote, seed

SPEC = {"title": "T", "pitch": "p", "modules": [
    {"path": "ServerScriptService/Services/FlareUpService.luau", "purpose": "x", "depends": []}]}


@pytest.fixture
def settings(tmp_path):
    base = tmp_path / "game"
    for rel, src in {
        "ServerScriptService/ForgeProbe.server.luau": "-- probe\n",
        "ReplicatedStorage/ForgeTelemetry.luau": "return {}\n",
        "ServerScriptService/Main.server.luau": "-- boot\n",
        "ServerScriptService/Services/FireService.luau": "return {}\n",
        "tools/sync.py": "# tool\n",
        "tools/manifest.json": "[]\n",
    }.items():
        (base / rel).parent.mkdir(parents=True, exist_ok=True)
        (base / rel).write_text(src)
    spec_file = tmp_path / "spec.json"
    spec_file.write_text(json.dumps(SPEC))
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs", base_game_dir=base)
    return s, spec_file


def test_seed_copies_human_tree_and_records_base_files(settings):
    s, spec_file = settings
    store = seed(s, "fab", spec_file)
    assert (store.game_dir / "ServerScriptService/Services/FireService.luau").read_text() == "return {}\n"
    assert not (store.game_dir / "tools/manifest.json").exists()
    spec = store.load_spec()
    assert spec["slug"] == "fab"
    assert "ServerScriptService/Services/FireService.luau" in spec["base_files"]
    assert "ServerScriptService/Main.server.luau" in spec["base_files"]
    assert [m["path"] for m in spec["modules"]] == ["ServerScriptService/Services/FlareUpService.luau"]
    assert store.load_state()["idea"] == "p"


def test_reseed_keeps_forge_files_and_state(settings):
    s, spec_file = settings
    store = seed(s, "fab", spec_file)
    forge_file = store.game_dir / "ServerScriptService/Services/FlareUpService.luau"
    forge_file.write_text("-- forge made this\n")
    state = store.load_state()
    state["corrections"].append({"note": "keep me"})
    store.save_state(state)
    (s.base_game_dir / "ServerScriptService/Services/FireService.luau").write_text("-- v2\n")
    seed(s, "fab", spec_file)
    assert forge_file.read_text() == "-- forge made this\n"
    assert (store.game_dir / "ServerScriptService/Services/FireService.luau").read_text() == "-- v2\n"
    assert store.load_state()["corrections"] == [{"note": "keep me"}]


def test_promote_copies_back_and_rejects_bad_paths(settings):
    s, spec_file = settings
    store = seed(s, "fab", spec_file)
    rel = "ServerScriptService/Services/FlareUpService.luau"
    (store.game_dir / rel).write_text("-- flare\n")
    dest = promote(s, "fab", rel)
    assert dest == s.base_game_dir / rel and dest.read_text() == "-- flare\n"
    with pytest.raises(ValueError):
        promote(s, "fab", "../etc/passwd.luau")
    with pytest.raises(FileNotFoundError):
        promote(s, "fab", "ServerScriptService/Nope.luau")


def test_base_files_protect_seeded_human_files(settings):
    s, spec_file = settings
    store = seed(s, "fab", spec_file)
    run = Run(s, store, llm=FakeLLM({}), ui=UI(io.StringIO()))
    assert run.base_files == set(RUNTIME_FILES)
    run.spec = store.load_spec()
    assert "ServerScriptService/Services/FireService.luau" in run.base_files
    assert "ServerScriptService/Services/FlareUpService.luau" not in run.base_files
    assert "ServerScriptService/Services/FireService.luau" not in run.game_files()


def test_flame_and_blame_seed_spec_is_valid():
    spec = json.loads((SEEDS_DIR / "flame-and-blame.json").read_text())
    assert spec["slug"] == "flame-and-blame"
    assert [m["path"] for m in spec["modules"]] == ["ServerScriptService/Services/FlareUpService.luau"]
    assert "flareups" in spec["modules"][0]["purpose"]


async def test_open_studio_uses_forge_studio_env(settings, monkeypatch):
    s, spec_file = settings
    seen = {}

    class FakeStudio:
        def __init__(self, _settings):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        async def select(self, name_hint=None):
            seen["hint"] = name_hint
            return "studio-1"

    monkeypatch.setattr("forge.studio.Studio", FakeStudio)
    monkeypatch.setenv("FORGE_STUDIO", "Forge-ai")
    run = Run(s, RunStore(s, "fab"), llm=FakeLLM({}), ui=UI(io.StringIO()))
    async with contextlib.AsyncExitStack() as stack:
        assert await run.open_studio(stack) is not None
    assert seen["hint"] == "Forge-ai"
