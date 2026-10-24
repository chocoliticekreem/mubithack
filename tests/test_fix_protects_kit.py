import dataclasses

from forge import director, improve
from forge.config import load_settings


def _game(tmp_path):
    g = tmp_path / "game"
    for rel, src in {
        "ReplicatedStorage/Kit/ObbyKit.luau": "-- ObbyKit\nlocal R = { JUMP_HEIGHT = 7.2 }\nreturn R\n",
        "ReplicatedStorage/GameAssets.luau": "-- GameAssets\nreturn {}\n",
        "ServerScriptService/Course.luau": "-- Course: uses ObbyKit jump height and checkpoints\nreturn {}\n",
    }.items():
        (g / rel).parent.mkdir(parents=True, exist_ok=True)
        (g / rel).write_text(src)
    return g


def test_kit_owned_paths_are_the_spec_kit_modules_and_game_assets():
    spec = {"modules": [{"path": "ReplicatedStorage/Kit/ObbyKit.luau", "prebuilt": True, "kit": "ObbyKit"},
                        {"path": "ServerScriptService/Course.luau"}]}
    owned = improve.kit_owned_paths(spec)
    assert "ReplicatedStorage/Kit/ObbyKit.luau" in owned and director.GAME_ASSETS in owned
    assert "ServerScriptService/Course.luau" not in owned


def test_candidate_file_never_picks_an_excluded_kit_file(tmp_path):
    g = _game(tmp_path)
    s = dataclasses.replace(load_settings(), base_game_dir=g)
    anomaly = {"title": "ObbyKit jump height too low for the course", "path": "ReplicatedStorage/Kit/ObbyKit.luau",
               "kind": "bug", "severity": "high", "system": "obby", "observed": "", "expected": ""}
    kit = {"ReplicatedStorage/Kit/ObbyKit.luau", director.GAME_ASSETS}
    assert improve.candidate_file(s, g, anomaly) == "ReplicatedStorage/Kit/ObbyKit.luau"  # unprotected: named file
    picked = improve.candidate_file(s, g, anomaly, exclude=kit)
    assert picked not in kit and picked == "ServerScriptService/Course.luau"
