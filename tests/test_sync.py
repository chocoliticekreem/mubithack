"""Tests for game/tools/sync.py (stdlib sync tool) and the base game runtime Luau."""
from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import urllib.request
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
GAME = REPO / "game"


def _load_sync():
    spec = importlib.util.spec_from_file_location("forge_game_sync", GAME / "tools" / "sync.py")
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


sync = _load_sync()

needs_luau = pytest.mark.skipif(shutil.which("luau-compile") is None, reason="luau-compile not installed")


def _write(root: Path, rel: str, text: str) -> Path:
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)
    return p


def _compile(path: Path) -> subprocess.CompletedProcess:
    return subprocess.run(["luau-compile", "--null", str(path)], capture_output=True, text=True)


@needs_luau
def test_check_passes_good_tree(tmp_path):
    _write(tmp_path, "ServerScriptService/Main.server.luau", 'print("hi")\n')
    _write(tmp_path, "ReplicatedStorage/Shared/Config.luau", "return { speed = 16 }\n")
    assert sync.check(tmp_path) == []
    assert sync.main(["check", "--root", str(tmp_path)]) == 0


@needs_luau
def test_check_catches_syntax_error(tmp_path, capsys):
    _write(tmp_path, "ServerScriptService/Main.server.luau", 'print("hi")\n')
    _write(tmp_path, "ReplicatedStorage/Broken.luau", "local x = \nprint(1\n")
    bad = sync.check(tmp_path)
    assert len(bad) == 1
    rel, msg = bad[0]
    assert rel == "ReplicatedStorage/Broken.luau"
    assert "SyntaxError" in msg or "Expected" in msg
    assert str(tmp_path) not in msg
    assert sync.main(["check", "--root", str(tmp_path)]) == 1
    assert "FAIL ReplicatedStorage/Broken.luau" in capsys.readouterr().out


def test_manifest_mapping(tmp_path):
    _write(tmp_path, "ServerScriptService/Main.server.luau", "")
    _write(tmp_path, "ServerScriptService/Services/Round/RoundService.luau", "")
    _write(tmp_path, "ReplicatedStorage/Config.luau", "")
    _write(tmp_path, "StarterPlayerScripts/Hud.client.luau", "")
    _write(tmp_path, "StarterGui/Menu/Button.client.luau", "")
    _write(tmp_path, "tools/ignored.luau", "")          # not a synced root
    _write(tmp_path, "Other/ignored.luau", "")          # not a synced root
    _write(tmp_path, "ReplicatedStorage/notes.txt", "")  # not luau

    out = sync.write_manifest(tmp_path)
    assert out == tmp_path / "tools" / "manifest.json"
    entries = {e["path"]: e for e in json.loads(out.read_text())}
    assert set(entries) == {
        "ServerScriptService/Main.server.luau",
        "ServerScriptService/Services/Round/RoundService.luau",
        "ReplicatedStorage/Config.luau",
        "StarterPlayerScripts/Hud.client.luau",
        "StarterGui/Menu/Button.client.luau",
    }
    assert entries["ServerScriptService/Main.server.luau"] == {
        "service": "ServerScriptService", "dirs": [], "name": "Main", "class": "Script",
        "path": "ServerScriptService/Main.server.luau",
    }
    nested = entries["ServerScriptService/Services/Round/RoundService.luau"]
    assert nested["dirs"] == ["Services", "Round"]
    assert nested["name"] == "RoundService" and nested["class"] == "ModuleScript"
    assert entries["ReplicatedStorage/Config.luau"]["class"] == "ModuleScript"
    hud = entries["StarterPlayerScripts/Hud.client.luau"]
    assert hud["service"] == "StarterPlayerScripts"
    assert hud["name"] == "Hud" and hud["class"] == "LocalScript"
    btn = entries["StarterGui/Menu/Button.client.luau"]
    assert btn["service"] == "StarterGui" and btn["dirs"] == ["Menu"]


def test_serve_in_thread_serves_files(tmp_path):
    _write(tmp_path, "ServerScriptService/A B.server.luau", 'print("served")\n')
    sync.write_manifest(tmp_path)
    srv = sync.serve_in_thread(tmp_path, 0)
    try:
        host, port = srv.server_address[:2]
        assert host == "127.0.0.1"
        base = f"http://127.0.0.1:{port}/"
        with urllib.request.urlopen(base + "tools/manifest.json?t=1", timeout=5) as r:
            manifest = json.loads(r.read())
            assert r.headers.get("Cache-Control") == "no-store"
        assert manifest[0]["path"] == "ServerScriptService/A B.server.luau"
        with urllib.request.urlopen(base + "ServerScriptService/A%20B.server.luau?t=2", timeout=5) as r:
            assert r.read().decode() == 'print("served")\n'
    finally:
        srv.shutdown()
        srv.server_close()


def test_pull_luau_params():
    src = sync.pull_luau(4321, prune=False)
    assert "http://127.0.0.1:4321/" in src
    assert "local PRUNE = false" in src
    assert "__PORT__" not in src and "__PRUNE__" not in src
    assert "local PRUNE = true" in sync.pull_luau(4321)
    assert "ForgeManaged" in src and "HttpEnabled = was" in src


@needs_luau
@pytest.mark.parametrize("prune", [True, False])
def test_pull_luau_compiles(tmp_path, prune):
    p = tmp_path / "pull.luau"
    p.write_text(sync.pull_luau(34873, prune=prune))
    r = _compile(p)
    assert r.returncode == 0, r.stdout + r.stderr


def test_checked_in_pull_luau_is_current():
    assert (GAME / "tools" / "pull.luau").read_text() == sync.pull_luau(sync.DEFAULT_PORT)


@needs_luau
@pytest.mark.parametrize("rel", [
    "ServerScriptService/ForgeProbe.server.luau",
    "ReplicatedStorage/ForgeTelemetry.luau",
    "tools/pull.luau",
])
def test_runtime_luau_compiles(rel):
    r = _compile(GAME / rel)
    assert r.returncode == 0, r.stdout + r.stderr
