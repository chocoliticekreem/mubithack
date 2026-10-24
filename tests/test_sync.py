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
        "path": "ServerScriptService/Main.server.luau", "hash": sync.file_hash(b""), "size": 0,
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
    assert "ForgeManaged" in src and "setHttp(was)" in src


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


# ---------------------------------------------------------------------------- incremental sync

def test_manifest_hash_tracks_content(tmp_path):
    p = _write(tmp_path, "ReplicatedStorage/A.luau", "return 1\n")
    h1 = sync.manifest_entries(tmp_path)[0]["hash"]
    p.write_text("return 2\n")
    e = sync.manifest_entries(tmp_path)[0]
    assert e["hash"] != h1 and e["hash"] == sync.file_hash(b"return 2\n")
    p.write_text("return 'é'\n")  # size is the UTF-8 byte length Studio's #Source reports
    assert sync.manifest_entries(tmp_path)[0]["size"] == len("return 'é'\n".encode())


def test_changed_paths():
    entries = [{"path": "a", "hash": "1"}, {"path": "b", "hash": "2"}, {"path": "c", "hash": "3"}]
    assert sync.changed_paths(entries, {"a": "1", "b": "X", "gone": "9"}) == {
        "changed": ["b"], "added": ["c"], "removed": ["gone"]}
    assert sync.changed_paths(entries, None) == {"changed": [], "added": ["a", "b", "c"], "removed": []}
    assert sync.changed_paths(entries, sync.hashes(entries)) == {"changed": [], "added": [], "removed": []}


def test_inline_plan_sends_only_changes_within_budget(tmp_path):
    _write(tmp_path, "ReplicatedStorage/Small.luau", "return 1\n")
    _write(tmp_path, "ReplicatedStorage/Big.luau", "return '" + "x" * 500 + "'\n")
    _write(tmp_path, "ServerScriptService/Same.server.luau", "print(1)\n")
    entries = sync.manifest_entries(tmp_path)
    # nothing pushed yet: everything that fits, smallest first
    assert set(sync.inline_plan(tmp_path, entries, None)) == {e["path"] for e in entries}
    assert set(sync.inline_plan(tmp_path, entries, None, budget=20)) == {
        "ReplicatedStorage/Small.luau", "ServerScriptService/Same.server.luau"}
    pushed = sync.hashes(entries)
    assert sync.inline_plan(tmp_path, entries, pushed) == {}
    _write(tmp_path, "ReplicatedStorage/Small.luau", "return 2\n")
    entries = sync.manifest_entries(tmp_path)
    assert sync.inline_plan(tmp_path, entries, pushed) == {"ReplicatedStorage/Small.luau": "return 2\n"}


@pytest.mark.skipif(shutil.which("luau") is None, reason="luau not installed")
@pytest.mark.parametrize("text", ["plain", "a]]b", "x]=]y]==]z", "", "trailing]", "a]]=", "\nleading newline"])
def test_long_string_round_trips_through_luau(tmp_path, text):
    p = tmp_path / "s.luau"
    p.write_text(f"local s = {sync.long_string(text)}\nprint(#s .. ':' .. s)\n")
    r = subprocess.run(["luau", str(p)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert r.stdout == f"{len(text.encode())}:{text}\n"


def test_pull_luau_inline_manifest(tmp_path):
    _write(tmp_path, "ReplicatedStorage/A.luau", "-- __MANIFEST__ __INLINE__ ]]\nreturn 1\n")
    entries = sync.manifest_entries(tmp_path)
    src = sync.pull_luau(4321, manifest=entries, inline={"ReplicatedStorage/A.luau": "-- __INLINE__\nreturn 1\n"})
    assert "local MANIFEST_JSON: string? = nil" not in src
    assert "local INLINE_JSON: string? = nil" not in src
    assert src.count("__INLINE__") == 1  # only the one inside the embedded source
    plain = sync.pull_luau(4321)
    assert "local MANIFEST_JSON: string? = nil" in plain and "local INLINE_JSON: string? = nil" in plain
    assert 'GetAttribute("ForgeHash") == e.hash' in plain
    assert "local FORCE = false" in plain and "local FORCE = true" in sync.pull_luau(4321, force=True)


@needs_luau
def test_pull_luau_with_inline_compiles(tmp_path):
    _write(tmp_path, "ReplicatedStorage/A.luau", "local s = [[x]] return s\n")
    entries = sync.manifest_entries(tmp_path)
    p = tmp_path / "pull.luau"
    p.write_text(sync.pull_luau(1, manifest=entries, inline=sync.inline_plan(tmp_path, entries, None)))
    r = _compile(p)
    assert r.returncode == 0, r.stdout + r.stderr
