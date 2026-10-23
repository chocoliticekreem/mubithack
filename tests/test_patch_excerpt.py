"""The patcher's excerpt stays within budget and the problem always reaches it (a merged excerpt once sent a
whole 1,548-line file and the message was cut before the problem)."""

from __future__ import annotations

import json

from forge import roles
from forge.llm import FakeLLM
from forge.patch import relevant_excerpt

DENSE = "\n".join(f"\tlocal prompt{i} = invPrompt(part, 'Grab', 'Gear Rack', dist) -- rack {i}" for i in range(1500))


def test_many_matching_lines_stay_within_budget():
    ex = relevant_excerpt(DENSE, "gear rack prompt invPrompt part", budget=5000)
    assert len(ex) <= 5000 + 200
    assert "    1| " in ex


def test_problem_is_never_cut_off_by_a_big_file():
    llm = FakeLLM({"patcher": [json.dumps({"summary": "s", "edits": [{"find": "local prompt7 = ", "replace": "local prompt7 = "}]})]})
    roles.patch_file(llm, "A.luau", DENSE, "THE PROBLEM: racks never fire", "ctx", "", session_id="s")
    msg = llm.calls[0].user
    assert "THE PROBLEM: racks never fire" in msg
    assert msg.index("## Problem") < msg.index("## Relevant code")
    assert len(msg) <= roles.MAX_USER_CHARS + 500
