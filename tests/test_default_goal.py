"""The testers' default goal comes from the game's own spec, not from Flame and Blame."""

from forge.cli import build_parser, default_goal


def test_goal_comes_from_the_core_loop():
    g = default_goal({"core_loop": "droppers make cash cubes, buy upgrades with the cash"})
    assert "droppers make cash cubes" in g and "fire" not in g


def test_goal_falls_back_to_the_pitch():
    assert "tycoon" in default_goal({"pitch": "a tiny tycoon"})


def test_no_hardcoded_firefighting_default():
    assert build_parser().parse_args(["fix", "x"]).goal is None
    assert build_parser().parse_args(["improve", "x"]).goal is None
