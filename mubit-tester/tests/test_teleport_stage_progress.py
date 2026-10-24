"""teleport_stage is a test fixture ("a save at stage N"): it sets the player's progress through the game's ObbyKit
before moving them, so obbies' next-checkpoint-only rule (by design) doesn't look like a progression bug."""

from pathlib import Path

HARNESS = Path(__file__).resolve().parents[1] / "roblox" / "ForgeTest.server.luau"


def _teleport_body() -> str:
    src = HARNESS.read_text(encoding="utf-8")
    return src.split("local function teleportStage(args)", 1)[1].split("\nend\n", 1)[0]


def test_teleport_stage_sets_progress_through_the_kit_before_moving():
    body = _teleport_body()
    assert "ObbyKit.setStage" in body and "args.set_stage ~= false" in body
    assert body.index("ObbyKit.setStage") < body.index("char:PivotTo")


def test_a_game_without_the_kit_still_teleports():
    body = _teleport_body()
    # the kit lookup is optional and guarded: no kit, no require error, the teleport still runs
    assert 'FindFirstChild("ObbyKit")' in body and "pcall(require, mod)" in body
