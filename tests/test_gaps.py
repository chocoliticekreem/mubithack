"""Gap finder: evidence from Forge's records, parsing/ranking of the gap_finder reply, corrections."""

import dataclasses
import json

from forge import gaps
from forge.config import load_settings
from forge.llm import FakeLLM, load_prompt

TYCOON_SPEC = {
    "title": "Cube Cash Tycoon", "slug": "g", "pitch": "Cubes roll down your conveyor",
    "core_loop": "A dropper spawns cubes onto a conveyor; the collector pays cash; buy upgrades.",
    "modules": [{"path": "ServerScriptService/Tycoon.luau", "purpose": "tycoon logic", "depends": []}],
    "acceptance": ["cubes_collected increases"],
}


def _settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


def _game(tmp_path):
    run = tmp_path / "runs" / "g"
    (run / "game" / "ServerScriptService").mkdir(parents=True)
    (run / "game" / "ServerScriptService" / "Tycoon.luau").write_text(
        'local Players = game:GetService("Players")\n-- dropper + conveyor + collector\n'
        'local p = Instance.new("Part")\nlocal ls = Instance.new("Folder") ls.Name = "leaderstats"\n'
        'local TweenService = game:GetService("TweenService")\n')
    (run / "game" / "ServerScriptService" / "ForgeProbe.server.luau").write_text("-- runtime, DataStoreService")
    (run / "spec.json").write_text(json.dumps(TYCOON_SPEC))
    (run / "state.json").write_text(json.dumps({"iterations": [{"n": 2, "score": 7}]}))
    (run / "iterations" / "2").mkdir(parents=True)
    (run / "iterations" / "2" / "critique.json").write_text(json.dumps(
        {"score": 7, "summary": "works but thin", "issues": [{"path": "ServerScriptService/Tycoon.luau",
                                                             "problem": "cubes stick on the belt"}]}))
    (run / "iterations" / "2" / "screenshot.png").write_bytes(b"png")
    t = run / "tests" / "20261024-024205-8059"
    t.mkdir(parents=True)
    (t / "report.json").write_text(json.dumps({"goal": "buy both pads", "goal_met": False, "summary": "pad 2 never bought",
                                               "bugs": [{"title": "pad ignores touch", "severity": "high",
                                                         "evidence": "cash stayed 60"}], "steps": [{}, {}]}))
    (t / "step-03.json").write_text(json.dumps({"action": {"action": "touch pad"},
                                                "assertions": [{"text": "cash drops by 50", "ok": False, "detail": "60 -> 60"}]}))
    (t / "step-03.png").write_bytes(b"png")
    (run / "calls.jsonl").write_text(json.dumps({"role": "coder"}) + "\n" + json.dumps({"role": "fixer", "error": "x"}) + "\n")
    return run


def test_prompt_is_a_fixed_role():
    text = load_prompt("gap_finder")
    assert "gap finder" in text and "{" in text  # output schema, no per-call text
    assert "tiny-tycoon" not in text and "Cube Cash" not in text


def test_evidence_and_checklist(tmp_path):
    _game(tmp_path)
    c = gaps.collect_evidence(_settings(tmp_path), "g")
    assert c["genre"] == "tycoon"
    refs = c["evidence"].refs
    for ref in ("critic:2", "critic:2#1", "test:20261024-024205-8059", "test:20261024-024205-8059#bug1",
                "test:20261024-024205-8059/step-03", "calls:fixer", "done:checks",
                "code:ServerScriptService/Tycoon.luau", "genre:saving", "genre:rebirth"):
        assert ref in refs, ref
    scan = {i["id"]: i for i in c["scan"]}
    assert scan["conveyor_collector"]["present"] and scan["leaderboard"]["present"]
    assert not scan["saving"]["present"]  # runtime files (ForgeProbe) don't count
    assert not scan["rebirth"]["present"]
    assert "1 failed" in refs["calls:fixer"]
    msg = gaps.gap_message(c, "make it great")
    assert "[genre:saving]" in msg and "[test:20261024-024205-8059/step-03]" in msg and "make it great" in msg


def test_parse_ranks_filters_and_validates():
    refs = {"critic:2", "genre:saving", "test:r1", "done:checks"}
    obj = {"summary": "thin", "score": 4, "gaps": [
        {"title": "Run the checks", "impact": 6, "evidence": ["done:checks"], "job": {"kind": "feature", "request": "run"}},
        {"title": "No saving", "kind": "missing", "impact": 9, "confidence": 1, "evidence": ["genre:saving"],
         "job": {"kind": "feature", "request": "Add DataStore saving"}},
        {"title": "Belt sticks", "kind": "bug", "impact": 8, "confidence": 0.9, "evidence": ["[critic:2]", "made:up"],
         "job": {"kind": "bug", "request": "cubes stick", "path": "ServerScriptService/Tycoon.luau"}},
        {"title": "Invented", "impact": 10, "confidence": 1, "evidence": ["nope:1"],
         "job": {"kind": "fix", "request": "x", "path": "Nope.luau"}},
        {"title": "No saving", "impact": 3, "job": {"kind": "feature", "request": "dupe"}},
        {"title": "Rejected one", "impact": 10, "evidence": ["critic:2"], "job": {"kind": "feature", "request": "y"}},
        {"title": "no job", "impact": 10},
        {"title": "Sparkles", "impact": 99, "confidence": 5, "evidence": ["test:r1"], "job": {"kind": "juice", "request": "z"}},
    ]}
    out = gaps.parse_gaps(obj, refs, rejected_titles=["Rejected one"],
                          files=["ServerScriptService/Tycoon.luau"])
    ids = [g["id"] for g in out["gaps"]]
    assert ids == ["sparkles", "no-saving", "belt-sticks", "invented"]
    by = {g["id"]: g for g in out["gaps"]}
    assert by["sparkles"]["impact"] == 10 and by["sparkles"]["confidence"] == 1 and by["sparkles"]["job"]["kind"] == "visual"
    assert by["belt-sticks"]["evidence"] == ["critic:2"] and by["belt-sticks"]["unverified"] == ["made:up"]
    assert by["belt-sticks"]["job"] == {"kind": "fix", "request": "cubes stick", "path": "ServerScriptService/Tycoon.luau"}
    assert by["belt-sticks"]["kind"] == "broken"
    # no real evidence: half rank, and a made-up file path is dropped
    assert by["invented"]["rank"] == 5 and "path" not in by["invented"]["job"]
    assert out["score"] == 4


def _reply(*titles):
    return json.dumps({"summary": "s", "score": 5, "gaps": [
        {"title": t, "kind": "missing", "impact": 8 - i, "confidence": 0.9, "evidence": ["genre:saving"],
         "job": {"kind": "feature", "request": f"build {t}"}} for i, t in enumerate(titles)]})


def test_find_and_correct_go_through_the_same_task(tmp_path):
    run = _game(tmp_path)
    s = _settings(tmp_path)
    llm = FakeLLM({"gap_finder": [_reply("Saving", "Rebirth"), _reply("Rebirth", "Tutorial")]})
    rec = gaps.find_gaps(s, "g", llm=llm, goal="10x better tycoon")
    assert [g["id"] for g in rec["gaps"]] == ["saving", "rebirth"]
    assert (run / "orchestrator" / "gaps" / "1.json").exists()
    rec2 = gaps.correct_gaps(s, "g", "Saving is fine for a demo; first fix the first 60 seconds", llm=llm,
                             reject=["saving"])
    assert [g["id"] for g in rec2["gaps"]] == ["rebirth", "tutorial"]
    assert [c.role for c in llm.calls] == ["gap_finder", "gap_finder"]  # same Mubit task
    second = llm.calls[1].user
    assert gaps.CORRECTION_MARK in second and "first 60 seconds" in second
    assert "Your previous gap list" in second and "Gaps the developer rejected" in second
    corr = [json.loads(ln) for ln in (run / "orchestrator" / "corrections.jsonl").read_text().splitlines()]
    assert corr[0]["before"] == ["saving", "rebirth"] and corr[0]["after"] == ["rebirth", "tutorial"]
    assert corr[0]["rejected"] == ["saving"]
    # a rejected gap is never proposed again, even if the model repeats it
    llm.responses["gap_finder"] = [_reply("Saving", "Juice")]
    rec3 = gaps.find_gaps(s, "g", llm=llm)
    assert [g["id"] for g in rec3["gaps"]] == ["juice"]
    assert "build Juice" in gaps.render(rec3)
