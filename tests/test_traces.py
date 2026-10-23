"""Full Mubit traces (prompt + reply per call) and the Luau output cap."""

from __future__ import annotations

import json

import pytest

from forge import roles
from forge.llm import LLMError, LLMResult, MubitLLM
from test_llm_roles import _settings


def test_every_call_saves_a_full_trace(tmp_path):
    log = tmp_path / "game" / "calls.jsonl"
    llm = MubitLLM(_settings(tmp_path), log)
    llm._call_anthropic = lambda system, user, sid, mt: ("the reply", "mreq_1", 10, 3, "claude-sonnet-5-5")
    llm.complete("auditor", "the full user message", session_id="improve-g-1")
    traces = list((tmp_path / "game" / "traces").glob("*-auditor-mreq_1.json"))
    assert len(traces) == 1
    t = json.loads(traces[0].read_text())
    assert t["user"] == "the full user message" and t["reply"] == "the reply"
    assert t["request_id"] == "mreq_1" and t["session_id"] == "improve-g-1"
    assert t["system_prompt"] == "auditor.md" and len(t["system_sha256"]) == 16
    assert t["input_tokens"] == 10 and t["output_tokens"] == 3
    assert "mbt_secret_key" not in traces[0].read_text()


def test_failed_calls_are_traced_too(tmp_path):
    log = tmp_path / "calls.jsonl"
    llm = MubitLLM(_settings(tmp_path), log)

    def boom(*a):
        raise ValueError("bad request")

    llm._call_anthropic = boom
    with pytest.raises(LLMError):
        llm.complete("fixer", "fix this", session_id="g")
    t = json.loads(next((tmp_path / "traces").glob("*-fixer-no-id.json")).read_text())
    assert t["reply"] is None and "bad request" in t["error"] and t["user"] == "fix this"


class CapLLM:
    def __init__(self, outs):
        self.outs = list(outs)
        self.max_tokens = []

    def complete(self, role, user, *, session_id, max_tokens=4096):
        self.max_tokens.append(max_tokens)
        text, tokens = self.outs.pop(0)
        return LLMResult(text=text, role=role, request_id="r", model="m", latency_ms=0,
                         input_tokens=1, output_tokens=tokens)


def test_cut_off_luau_reply_is_an_error_not_a_half_file():
    llm = CapLLM([("```luau\nlocal a = \n```", roles.LUAU_MAX_TOKENS)])
    with pytest.raises(LLMError, match="cut off"):
        roles.fix_file(llm, "A.luau", "return 1", "p", "c", "", session_id="s")
    assert llm.max_tokens == [roles.LUAU_MAX_TOKENS]


def test_full_luau_reply_under_the_cap_is_used():
    llm = CapLLM([("```luau\nreturn 2\n```", 900)])
    assert roles.fix_file(llm, "A.luau", "return 1", "p", "c", "", session_id="s").strip() == "return 2"
