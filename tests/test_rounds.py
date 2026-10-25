"""Improvement rounds learn from each other (forge/rounds.py): the critic sees the last round, the fixer is
corrected by what its last fix did, issues on read-only files are recorded, and each round gets one line."""

from __future__ import annotations

import io
import json
import shutil

import pytest

from forge import rounds
from forge.llm import FakeLLM
from forge.loop import UI, Run, new_game
from forge.memory import RunStore
from test_loop import CONFIG_SRC, LESSONS, luau, settings  # noqa: F401

SPEC = {
    "title": "Coin Rush",
    "slug": "coin-rush",
    "pitch": "Collect coins",
    "core_loop": "run to coins, collect",
    "modules": [
        {"path": "ServerScriptService/Game.server.luau", "purpose": "coins", "depends": ["ReplicatedStorage/Config.luau"]},
        {"path": "ReplicatedStorage/Config.luau", "purpose": "tunables", "depends": []},
    ],
    "acceptance": ["touching a coin bumps coin_collected", "clearing the zone bumps zone_cleared"],
}

GAME = """\
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Config"))
local COIN = "coin_collected"
for i = 1, Config.CoinCount do
    local coin = Instance.new("Part")
    coin.Anchored = true
    coin.Parent = workspace
end
"""


def critique(score, *issues):
    return json.dumps({"score": score, "summary": f"round at {score}", "done": False,
                       "issues": [{"path": p, "problem": t, "fix_hint": "fix it"} for p, t in issues]})


# ------------------------------------------------------------------------------------------- pure functions

def test_acceptance_splits_met_missing_and_counters_no_script_names():
    acc = rounds.acceptance(SPEC, {"coin_collected": 2, "zone_cleared": 0}, {"a.luau": 'count("coin_collected")'})
    assert acc == {"named": ["coin_collected", "zone_cleared"], "met": ["coin_collected"],
                   "missing": ["zone_cleared"], "unemitted": ["zone_cleared"]}
    assert rounds.acceptance(SPEC, {}, {"a.luau": 'x = "zone_cleared"'})["unemitted"] == ["coin_collected"]


def test_either_counter_of_an_or_criterion_meets_it():
    spec = {"acceptance": ["Falling or touching lava returns the player (player_fell or player_died increments)"]}
    assert rounds.acceptance(spec, {"player_died": 1})["missing"] == []
    assert rounds.acceptance(spec, {})["missing"] == ["player_fell", "player_died"]


def test_past_rounds_rebuilds_rounds_saved_before_the_history_existed():
    its = [{"n": 1, "score": 5, "issues": [{"path": "Game.server.luau", "problem": "zone_cleared never fires"},
                                           {"path": "Other.luau", "problem": "coin_collected is 0"}]}]
    files = {(1, "report.json"): {"counters": {"coin_collected": 1}},
             (1, "record.json"): {"fixes": [{"path": "ServerScriptService/Game.server.luau", "kind": "critic"},
                                            {"path": "ServerScriptService/Game.server.luau", "kind": "compile"}]}}
    [r] = rounds.past_rounds(its, SPEC, lambda n, name: files.get((n, name)))
    assert r["met"] == ["coin_collected"] and r["missing"] == ["zone_cleared"]
    assert r["fixed"] == {"ServerScriptService/Game.server.luau": ["zone_cleared"]}


def hist(*rows):
    return [{"n": n, "score": s, "met": met, "missing": miss, "fixed": fixed, "issues": [], "rolled_back": None}
            for n, s, met, miss, fixed in rows]


GAME_PATH = "ServerScriptService/Game.server.luau"


def test_a_fix_that_did_not_make_its_counter_fire_is_rejected_in_the_fixer_task():
    history = hist((1, 5, [], ["coin_collected", "zone_cleared"], {GAME_PATH: ["zone_cleared"]}),
                   (2, 5, [], ["coin_collected", "zone_cleared"], {GAME_PATH: ["coin_collected", "zone_cleared"]}))
    now = {"met": ["coin_collected"], "missing": ["zone_cleared"], "unemitted": ["zone_cleared"], "score": 5}
    text, taught = rounds.fixer_correction(history, GAME_PATH, now)
    assert text.startswith(rounds.RETRY_MARK)  # forge.ledger counts this call as a correction
    assert "2 rounds in a row" in text and "different approach" in text
    assert "coin_collected fire: keep that code path intact" in text
    assert 'No script contains the name "zone_cleared"' in text
    assert taught == "Game left zone_cleared at 0 after 2 tries, told to try another way"


def test_a_fix_that_worked_is_confirmed_and_an_untouched_file_gets_nothing():
    history = hist((1, 5, [], ["coin_collected"], {GAME_PATH: ["coin_collected"]}))
    text, taught = rounds.fixer_correction(history, GAME_PATH, {"met": ["coin_collected"], "missing": []})
    assert rounds.RETRY_MARK not in text and "worked" in text and taught == "Game fix confirmed (coin_collected fire)"
    assert rounds.fixer_correction(history, "ReplicatedStorage/Other.luau", {"met": [], "missing": []}) == ("", "")
    assert rounds.fixer_correction([], GAME_PATH, {"met": [], "missing": ["coin_collected"]}) == ("", "")


def test_critic_block_shows_the_trend_what_changed_and_what_cannot_be_fixed():
    assert rounds.critic_block([], {"met": [], "missing": []}, []) == ""
    history = hist((1, 5, [], ["coin_collected", "zone_cleared"], {GAME_PATH: ["zone_cleared"]}),
                   (2, 5, [], ["coin_collected", "zone_cleared"], {GAME_PATH: ["zone_cleared"]}))
    history[-1]["issues"] = [{"path": GAME_PATH, "problem": "zone_cleared never fires"}]
    now = {"met": ["coin_collected"], "missing": ["zone_cleared"], "unemitted": ["zone_cleared"]}
    block = rounds.critic_block(history, now, ["ReplicatedStorage/Kit/ObbyKit.luau"],
                                [{"path": "ReplicatedStorage/Kit/ObbyKit.luau", "problem": "lava does not kill"}])
    assert block.startswith("## Previous rounds")
    assert "- Round 2: score 5, acceptance counters 0/2 (missing: coin_collected, zone_cleared); fixer then changed: Game" in block
    assert "now firing: coin_collected" in block and "still missing: zone_cleared" in block
    assert "Missing for several rounds in a row: zone_cleared" in block
    assert 'No script contains the counter name "zone_cleared"' in block
    assert "Read-only Forge kit files" in block and "lava does not kill" in block
    assert "- ServerScriptService/Game.server.luau: zone_cleared never fires" in block


def test_round_line_reads_as_one_sentence_for_the_panel():
    prev = hist((6, 5, ["coin_collected"], ["zone_cleared", "gate_used"], {}))[0]
    rec = {"score": 6.0, "acceptance": {"met": ["coin_collected", "gate_used"], "missing": ["zone_cleared"]},
           "fixes": [{"path": GAME_PATH, "kind": "critic"}, {"path": GAME_PATH, "kind": "compile"},
                     {"path": "ServerScriptService/Gift.server.luau", "kind": "critic"}],
           "blocked_issues": [{"path": "x", "problem": "y"}],
           "taught": ["Game left zone_cleared at 0 after 3 tries, told to try another way"]}
    assert rounds.round_line(prev, rec) == (
        "score 5 -> 6, acceptance 1/3 -> 2/3 (+gate_used); fixed: Game, Gift; skipped 1 on read-only kit files; "
        "taught the fixer: Game left zone_cleared at 0 after 3 tries, told to try another way")
    assert rounds.round_line(None, {"score": 5, "acceptance": {"met": [], "missing": ["a_b"]}}) == "score 5, acceptance 0/1"


def test_the_real_obby_run_would_have_corrected_the_fixer():
    """runs/make-me-an-obby-with-100 shape: zone_cleared asked of StudioSelfTest round after round."""
    path = "ServerScriptService/StudioSelfTest.server.luau"
    spec = {"acceptance": ["ride_gate_used and zone_cleared reach at least 1"]}
    history = hist(*[(n, 5, [], ["ride_gate_used", "zone_cleared"], {path: ["ride_gate_used", "zone_cleared"]})
                     for n in range(1, 7)])
    now = {**rounds.acceptance(spec, {"ride_gate_used": 1}, {"ObbyKit.luau": 'count("ride_gate_used")'}), "score": 6}
    text, taught = rounds.fixer_correction(history, path, now)
    assert "6 rounds in a row" in text and "ride_gate_used fire" in text and '"zone_cleared"' in text
    assert taught.startswith("StudioSelfTest left zone_cleared at 0 after 6 tries")


# ------------------------------------------------------------------------------------- through the real loop

@pytest.mark.skipif(shutil.which("luau-compile") is None, reason="luau-compile not on PATH")
async def test_two_rounds_carry_history_to_critic_and_fixer(settings, monkeypatch):
    from forge import headless

    monkeypatch.setenv("FORGE_FUN_CRITIC", "0")
    monkeypatch.setattr(headless, "available", lambda: True)
    reports = iter([{"counters": {}}, {"counters": {"coin_collected": 3}}])

    async def playtest(self, rec):
        rec["steps"].append({"step": "playtest", "ok": True, "engine": "headless"})
        return next(reports), ""
    monkeypatch.setattr(Run, "headless_playtest", playtest)

    probe = "ServerScriptService/ForgeProbe.server.luau"  # Forge runtime: the fixer may not edit it
    llm = FakeLLM({
        "designer": [json.dumps(SPEC)],
        "coder": [luau(CONFIG_SRC), luau(GAME)],
        "critic": [critique(5, (GAME_PATH, "coin_collected and zone_cleared never fire"), (probe, "probe is slow")),
                   critique(6, (GAME_PATH, "zone_cleared still never fires"))],
        "fixer": [luau(GAME), luau(GAME)],
        "reflector": [LESSONS, LESSONS],
    })
    slug = await new_game("Coin rush rounds", iterations=2, use_studio=False, settings=settings, llm=llm,
                          ui=UI(io.StringIO()))
    its = RunStore(settings, slug).load_state()["iterations"]

    critic_users = [c.user for c in llm.calls if c.role == "critic"]
    assert "## Previous rounds" not in critic_users[0]
    assert "- Round 1: score 5, acceptance counters 0/2" in critic_users[1]
    assert "now firing: coin_collected" in critic_users[1]
    assert 'No script contains the counter name "zone_cleared"' in critic_users[1]
    assert f"Skipped last round, on read-only files: {probe}: probe is slow" in critic_users[1]

    fixer_users = [c.user for c in llm.calls if c.role == "fixer"]
    assert len(fixer_users) == 2  # the probe issue never reached a fixer
    assert rounds.RETRY_MARK not in fixer_users[0]
    assert rounds.RETRY_MARK in fixer_users[1] and "zone_cleared" in fixer_users[1].split(rounds.RETRY_MARK)[1]
    assert "Score by round (oldest first, this round last): 5, 6" in fixer_users[1]

    assert its[0]["blocked_issues"] == [{"path": probe, "problem": "probe is slow"}]
    assert its[0]["fixed"] == {GAME_PATH: ["coin_collected", "zone_cleared"]}
    assert its[0]["round_line"] == "score 5, acceptance 0/2; fixed: Game; skipped 1 on read-only kit files"
    assert its[1]["acceptance"]["met"] == ["coin_collected"]
    assert its[1]["round_line"] == ("score 5 -> 6, acceptance 0/2 -> 1/2 (+coin_collected); fixed: Game; "
                                    "taught the fixer: Game left zone_cleared at 0 after 1 try, told to try another way")
    reflector_users = [c.user for c in llm.calls if c.role == "reflector"]
    assert "Round outcome: score 5 -> 6" in reflector_users[1]
    # this build's dead ends: saved for the next build, and in the reflector's summary
    ends = rounds.read_dead_ends(settings.runs_dir)
    assert [e["slug"] for e in ends] == [slug]
    assert any('"zone_cleared"' in line for line in ends[0]["lines"])
    assert "Dead ends in this build so far" in reflector_users[1]


def test_dead_ends_name_what_rounds_could_not_move():
    its = [{"n": n, "score": 5, "fixed": {"ServerScriptService/Gifts.luau": ["zone_cleared"]},
            "acceptance": {"met": ["coin_collected"], "missing": ["zone_cleared", "gift_claimed"],
                           "unemitted": ["zone_cleared"]}} for n in (1, 2, 3)]
    its[-1]["blocked_issues"] = [{"path": "ReplicatedStorage/Kit/ObbyKit.luau", "problem": "lava"}]
    lines = rounds.dead_ends(its, {})
    assert lines[0].startswith('"zone_cleared" was promised in acceptance but nothing ever counted it (3 rounds)')
    assert lines[1].startswith('"gift_claimed" stayed 0 through 3 rounds')
    assert "Gifts were rewritten 3 rounds while the score stayed 5-5" in lines[2]
    assert "1 critic issues were on read-only kit files (ObbyKit)" in lines[3]
    assert rounds.dead_ends([{"n": 1, "score": 8, "acceptance": {"met": ["a_b"], "missing": []}}], {}) == []


def test_dead_ends_carry_to_the_next_build_newest_first(tmp_path):
    its = [{"n": 1, "score": 5, "acceptance": {"missing": ["zone_cleared"], "unemitted": []}}]
    rounds.record_dead_ends(tmp_path, "park-a", {"title": "Park A", "genre": "obby"}, its)
    rounds.record_dead_ends(tmp_path, "park-b", {"title": "Park B"}, its)
    block = rounds.dead_ends_block(tmp_path)
    assert block.index("- Park B:") < block.index("- Park A (obby):")
    assert "Park A" not in rounds.dead_ends_block(tmp_path, exclude="park-a")
    rounds.record_dead_ends(tmp_path, "park-b", {"title": "Park B"}, [{"n": 2, "score": 8, "acceptance": {}}])
    assert [e["slug"] for e in rounds.read_dead_ends(tmp_path)] == ["park-a"]  # fixed since: its entry goes
    (tmp_path / rounds.DEAD_ENDS_FILE).write_text("not json")
    assert rounds.dead_ends_block(tmp_path) == ""


def test_an_obby_critic_gets_the_recipe_and_the_studio_qa_bots(tmp_path):
    obby = {"genre": "obby", "title": "Carnival Climb"}
    assert rounds.guide_block({"genre": "tycoon", "title": "Pizza Plant"}, None) == ""
    assert rounds.guide_block(obby, None).startswith("## What this genre needs first")
    (tmp_path / rounds.QA_FILE).write_text(json.dumps({"round": 3, "attempts": 2, "bots": [
        {"zone": "Front Gate Plaza", "stage": 1, "reached": False, "detail": "fell off the course after 2.9s"},
        {"zone": "Sky Wheel", "stage": 41, "reached": True, "detail": "reached stage 42"}]}))
    block = rounds.guide_block(obby, rounds.read_qa(tmp_path))
    assert "## Studio QA bots, last install (real play in Studio, 2 attempt(s) each): 1/2 reached" in block
    assert "- Front Gate Plaza stage 1: did NOT: fell off the course after 2.9s" in block
    assert "- Sky Wheel stage 41: reached the next checkpoint" in block
    (tmp_path / rounds.QA_FILE).write_text("{}")
    assert rounds.read_qa(tmp_path) is None


def test_an_obby_fixes_required_gameplay_before_polish():
    obby = {"genre": "obby"}
    issues = ["Confetti burst is too small on zone clear", "Touching lava at stage 8 does not kill the player",
              "Gift balloon sound is quiet", "Players fall through the checkpoint at stage 31"]
    ordered = sorted(issues, key=lambda t: not rounds.required_first(obby, t))
    assert ordered[:2] == [issues[1], issues[3]]
    assert not rounds.required_first({"genre": "tycoon"}, issues[1])


def test_counters_the_headless_player_never_triggers_are_unknown_not_broken():
    acc = {"met": ["coin_collected"], "missing": ["costume_buy", "park_finished", "ghost_counter"],
           "unemitted": ["ghost_counter"]}
    block = rounds.unexercised_block(acc)
    assert "A script bumps costume_buy, park_finished, but the scripted headless player never did" in block
    assert "ghost_counter" not in block  # nothing bumps it: that one really is missing
    assert rounds.unexercised_block({"met": ["a_b"], "missing": []}) == ""


def test_studio_qa_counters_join_the_report_and_are_named():
    qa = {"bots": [], "counters": {"zone_cleared": 1, "park_finished": 1, "coin_collected": 3, "x_y": 0}}
    merged, added = rounds.studio_counters({"coin_collected": 5, "zone_cleared": 0}, qa)
    assert merged == {"coin_collected": 5, "zone_cleared": 1, "park_finished": 1}
    assert sorted(added) == ["park_finished", "zone_cleared"]
    assert rounds.studio_counters({"a_b": 1}, None) == ({"a_b": 1}, [])
