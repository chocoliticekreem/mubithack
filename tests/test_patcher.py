"""The patcher: exact edits for large files, so fixes stay local (whole-file rewrites shrank 1,000+ line files)."""

from __future__ import annotations

import json

import pytest

from forge import roles
from forge.improve import run_cycle
from forge.llm import FakeLLM, LLMError, load_prompt
from forge.patch import PATCH_ABOVE_LINES, PatchError, apply_edits, outline, relevant_excerpt
from test_fix_guards import _playtests
from test_fix_loop import HOSE, HOSE_FILE, _seeded_game, settings  # noqa: F401
from test_improve import FakeHarness, audit_reply

BIG = "\n".join(
    ["local Hose = {}", "", "function Hose.spray(player, target)", "\tlocal water = player:GetAttribute('Water')",
     "\tif water <= 0 then", "\t\treturn false", "\tend", "\treturn true", "end", ""]
    + [f"local filler{i} = {i}" for i in range(PATCH_ABOVE_LINES)]
    + ["", "local function refill(player)", "\tplayer:SetAttribute('Water', 100)", "end", "", "return Hose"])


def test_apply_edits_exact_once():
    out = apply_edits(BIG, [{"find": "\tif water <= 0 then\n\t\treturn false", "replace": "\tif (water or 0) <= 0 then\n\t\treturn false"}])
    assert "(water or 0)" in out and out.count("\n") == BIG.count("\n")
    with pytest.raises(PatchError, match="not found"):
        apply_edits(BIG, [{"find": "nope nope", "replace": "x"}])
    with pytest.raises(PatchError, match="appears"):
        apply_edits(BIG, [{"find": "local filler1", "replace": "x"}])  # filler1, filler10, filler100, ...
    with pytest.raises(PatchError):
        apply_edits(BIG, [])


def test_outline_and_excerpt_point_at_the_right_code():
    o = outline(BIG)
    assert "3: Hose.spray" in o and "refill" in o
    ex = relevant_excerpt(BIG, "Hose spray never uses Water attribute")
    assert "    4| \tlocal water = player:GetAttribute('Water')" in ex
    assert "filler200" not in ex  # far-away filler is left out


def test_patch_file_sends_an_excerpt_and_applies_the_edits():
    edit = {"find": "\tif water <= 0 then", "replace": "\tif (water or 0) <= 0 then"}
    llm = FakeLLM({"patcher": [json.dumps({"summary": "nil-guard water", "edits": [edit]})]})
    out = roles.patch_file(llm, HOSE_FILE, BIG, "Hose spray errors when Water is nil", "ctx", "", session_id="s")
    assert "(water or 0)" in out and len(out.splitlines()) == len(BIG.splitlines())
    msg = llm.calls[0].user
    assert f"({len(BIG.splitlines())} lines)" in msg and "Hose.spray" in msg and "filler250" not in msg


def test_patch_that_does_not_apply_is_an_llm_error():
    llm = FakeLLM({"patcher": [json.dumps({"summary": "s", "edits": [{"find": "missing", "replace": "x"}]})]})
    with pytest.raises(LLMError, match="could not be applied"):
        roles.patch_file(llm, HOSE_FILE, BIG, "p", "c", "", session_id="s")


async def test_fix_loop_uses_the_patcher_for_big_files_and_retries_with_the_reason(settings):
    game = _seeded_game(settings)
    (game / HOSE_FILE).write_text(BIG)
    good = {"find": "\tif water <= 0 then", "replace": "\tif (water or 0) <= 0 then"}
    llm = FakeLLM({"auditor": [audit_reply([HOSE])],
                   "patcher": [json.dumps({"summary": "s", "edits": [{"find": "missing", "replace": "x"}]}),
                               json.dumps({"summary": "s", "edits": [good]})],
                   "verifier": [json.dumps({"verdict": "fixed", "evidence": "e"})]})

    async def resync(root):
        pass

    cycle = await run_cycle(settings, "fab", llm=llm, harness=FakeHarness(), playtest=_playtests([{"a": 1}] * 2),
                            faults=[], goal="play", rounds=1, fix=True, resync=resync, log=lambda _: None)
    fx = cycle["code_fixes"][0]
    assert [t["status"] for t in fx["attempts"]] == ["fixer_error", "fixed"] and fx["status"] == "kept"
    assert "not found in the file" in [c.user for c in llm.calls if c.role == "patcher"][1]
    assert "fixer" not in [c.role for c in llm.calls]
    text = (game / HOSE_FILE).read_text()
    assert "(water or 0)" in text and len(text.splitlines()) == len(BIG.splitlines())


def test_patcher_prompt_exists():
    assert "find" in load_prompt("patcher")
