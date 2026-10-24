"""Forge kit modules (forge/kit/modules): the verified music library in sounds.json, MusicPlayer,
Cosmetics + CosmeticsClient, and the index the install step reads."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

KIT = Path(__file__).resolve().parents[1] / "forge" / "kit"
MODULES = KIT / "modules"
MOODS = {"carnival", "pop", "lobby", "spooky", "pirate", "intense", "victory", "water"}
LUAU = shutil.which("luau-compile")
needs_luau = pytest.mark.skipif(LUAU is None, reason="luau-compile not on PATH")


def _music() -> dict:
    return json.loads((KIT / "sounds.json").read_text(encoding="utf-8"))["music"]


def _index() -> list[dict]:
    return json.loads((MODULES / "index.json").read_text(encoding="utf-8"))


def test_music_library_is_verified_and_covers_every_mood():
    music = _music()
    assert 10 <= len(music) <= 16
    assert {m["mood"] for m in music.values()} == MOODS
    ids = [m["id"] for m in music.values()]
    assert len(set(ids)) == len(ids)
    for name, m in music.items():
        assert re.fullmatch(r"[A-Z][A-Za-z]+", name), name
        assert re.fullmatch(r"rbxassetid://\d+", m["id"]), name
        assert m["describe"] and m["keywords"] and m["mood"] in m["keywords"], name
        assert 0 < m["volume"] <= 0.5, name
        assert m["time_length"] > 20, name  # loops, not stings
        assert "Roblox licensed library" in m["source"], name
        assert re.match(r"\d{4}-\d{2}-\d{2} Studio playtest$", m["checked"]), name


def test_music_player_tracks_match_sounds_json():
    src = (MODULES / "MusicPlayer.luau").read_text(encoding="utf-8")
    rx = r'\{ name = "(\w+)", id = "(rbxassetid://\d+)", mood = "(\w+)", volume = ([\d.]+) \}'
    tracks = [(n, i, m, float(v)) for n, i, m, v in re.findall(rx, src)]
    assert tracks == [(n, m["id"], m["mood"], m["volume"]) for n, m in _music().items()]


def test_music_player_aliases_only_name_real_moods():
    src = (MODULES / "MusicPlayer.luau").read_text(encoding="utf-8")
    block = src.split("local ALIASES = {", 1)[1].split("\n}", 1)[0]
    targets = set(re.findall(r'= "(\w+)"', block))
    assert targets and targets <= MOODS


def test_index_entries_point_at_real_modules():
    entries = _index()
    names = [e["name"] for e in entries]
    assert len(set(names)) == len(names)
    assert {f"{n}.luau" for n in names} == {p.name for p in MODULES.glob("*.luau")}
    for e in entries:
        assert set(e) == {"name", "path_in_game", "genres", "keywords", "describe", "api"}, e["name"]
        assert e["path_in_game"] == f"ReplicatedStorage/Kit/{e['name']}.luau"
        assert (MODULES / f"{e['name']}.luau").is_file()
        assert e["genres"] and e["keywords"] and e["describe"]
        assert f"require(game.ReplicatedStorage.Kit.{e['name']})" in e["api"]
        first = (MODULES / f"{e['name']}.luau").read_text(encoding="utf-8").splitlines()[1]
        assert first.startswith(f"-- {e['name']} (Forge kit,"), e["name"]


def test_cosmetics_catalog_matches_the_api_and_uses_no_asset_ids():
    src = (MODULES / "Cosmetics.luau").read_text(encoding="utf-8")
    catalog = re.findall(r'\{ id = "(\w+)", name = "[^"]+", slot = "(\w+)"', src)
    slots = {}
    for cid, slot in catalog:
        slots.setdefault(slot, []).append(cid)
    assert set(slots) == {"head", "back", "trail", "body"}
    assert {"MouseEars", "TopHat", "ClownWig", "Crown", "BalloonHat", "AstronautHelmet", "PartyCone"} <= set(slots["head"])
    api = next(e["api"] for e in _index() if e["name"] == "Cosmetics")
    for cid, _ in catalog:
        assert re.search(rf"\b{cid}\b", api), cid
    for name in ("Cosmetics.luau", "CosmeticsClient.luau"):
        text = (MODULES / name).read_text(encoding="utf-8")
        assert "rbxassetid" not in text and "MeshId" not in text and "TextureID" not in text, name


@needs_luau
def test_kit_modules_compile():
    for p in sorted(MODULES.glob("*.luau")):
        r = subprocess.run([LUAU, "--null", str(p)], capture_output=True, text=True, check=False)
        assert r.returncode == 0, f"{p.name}: {r.stdout}{r.stderr}"
