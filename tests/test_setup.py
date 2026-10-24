"""forge MCP `setup`: the guided first run (key, model, luau, Studio)."""

from __future__ import annotations

import dataclasses
import os

import pytest
from mcp.server.mcpserver.exceptions import ToolError

from forge import mcp_server as fm
from forge.config import load_settings


@pytest.fixture
def env(tmp_path, monkeypatch):
    (tmp_path / ".env.example").write_text("FORGE_MODEL=claude-sonnet-5-5\nMUBIT_API_KEY=\n")
    monkeypatch.delenv("MUBIT_API_KEY", raising=False)
    base = load_settings()
    monkeypatch.setattr(fm, "_settings", lambda: dataclasses.replace(
        base, repo_root=tmp_path, runs_dir=tmp_path / "runs", model="claude-sonnet-5-5",
        mubit_api_key=os.environ.get("MUBIT_API_KEY") or None))
    keys = {"good": "mbt_good"}
    monkeypatch.setattr(fm, "check_key", lambda url, key: (key == keys["good"], "HTTP 401 invalid_key"))
    studios: list[dict] = []

    async def connected(settings, tries=4):
        return list(studios)

    monkeypatch.setattr(fm, "connected_studios", connected)
    monkeypatch.setattr(fm.shutil, "which", lambda name: "/bin/" + name)
    app = tmp_path / "RobloxStudio.app"
    app.mkdir()
    monkeypatch.setattr(fm, "STUDIO_APP", app)
    return tmp_path, studios


async def test_fresh_machine_lists_the_key_and_studio_steps(env):
    out = await fm.setup()
    assert "2 step(s) left" in out
    assert "setup(mubit_api_key=" in out and "Enable Studio as MCP server" in out


async def test_good_key_is_saved_and_setup_turns_ready(env):
    root, studios = env
    studios.append({"id": "s1", "name": "Forge.rbxlx"})
    out = await fm.setup(mubit_api_key=" mbt_good ")
    assert "ready" in out and "Mubit key works" in out and "`Forge.rbxlx`" in out
    text = (root / ".env").read_text()
    assert "MUBIT_API_KEY=mbt_good" in text and "FORGE_MODEL=claude-sonnet-5-5" in text
    assert "build_game(" in out


async def test_bad_key_is_rejected_and_not_saved(env):
    root, _ = env
    with pytest.raises(ToolError, match="invalid_key"):
        await fm.setup(mubit_api_key="mbt_bad")
    assert not (root / ".env").exists()


async def test_saving_a_key_twice_replaces_it(env):
    root, _ = env
    fm.save_key(root, "mbt_one")
    fm.save_key(root, "mbt_two")
    text = (root / ".env").read_text()
    assert text.count("MUBIT_API_KEY=") == 1 and "mbt_two" in text


async def test_missing_luau_and_studio_app_are_steps(env, monkeypatch):
    root, _ = env
    monkeypatch.setattr(fm.shutil, "which", lambda name: None)
    monkeypatch.setattr(fm, "STUDIO_APP", root / "nope.app")
    out = await fm.setup(mubit_api_key="mbt_good")
    assert "install_luau=True" in out and "create.roblox.com" in out


async def test_open_place_builds_and_opens_a_forge_place(env, monkeypatch):
    opened = []
    monkeypatch.setattr(fm, "_open_place", lambda s: opened.append(s) or "place/Forge.rbxlx")
    out = await fm.setup(mubit_api_key="mbt_good", open_place=True)
    assert opened and "In the Studio window that just opened" in out
