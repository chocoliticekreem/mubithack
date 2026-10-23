import json
import re
from pathlib import Path

import pytest

from forge import roles
from forge.config import Settings
from forge.llm import (
    PROMPTS_DIR,
    ROLES,
    FakeLLM,
    LLMError,
    MubitLLM,
    extract_json_object,
    fake_default_reply,
    load_prompt,
    make_llm,
)

SPEC = {
    "title": "Coin Dash",
    "slug": "Coin Dash!",
    "pitch": "Grab coins.",
    "core_loop": "Run, touch coins, score.",
    "modules": [
        {"path": "ReplicatedStorage/Config.luau", "purpose": "numbers", "depends": []},
        {"path": "ServerScriptService/Game.server.luau", "purpose": "loop",
         "depends": ["ReplicatedStorage/Config.luau", "ReplicatedStorage/ForgeTelemetry.luau",
                     "ReplicatedStorage/Nope.luau"]},
        {"path": "StarterPlayerScripts/Hud.client.luau", "purpose": "ui", "depends": []},
    ],
    "acceptance": ["coins_collected increments"],
}


def _settings(tmp_path: Path, key: str | None = "mbt_secret_key") -> Settings:
    return Settings(
        mubit_api_key=key, provider="anthropic", base_url="https://api.mubit.ai/anthropic",
        model="claude-sonnet-5", studio_mcp_path="", sync_port=34873, repo_root=tmp_path,
        runs_dir=tmp_path / "runs", base_game_dir=tmp_path / "game",
    )


# --- prompts -------------------------------------------------------------------------------


@pytest.mark.parametrize("role", ROLES)
def test_prompt_files_exist_and_are_static(role):
    path = PROMPTS_DIR / f"{role}.md"
    assert path.exists()
    text = path.read_text()
    assert len(text) > 500
    # no per-call templating of any kind
    assert not re.search(r"\{[a-z_][a-z0-9_]*\}", text), "format-style placeholder found"
    assert "{{" not in text and "}}" not in text
    assert "$" + "{" not in text and "%s" not in text
    assert load_prompt(role) == text.strip()


def test_lessons_header_not_in_prompts():
    for role in ROLES:
        assert roles.LESSONS_HEADER not in load_prompt(role)


# --- JSON extraction / repair ---------------------------------------------------------------


def test_extract_json_fenced_and_bare():
    assert extract_json_object('Sure!\n```json\n{"a": 1}\n```\nbye') == {"a": 1}
    assert extract_json_object('prefix {"a": {"b": [1, 2]}} suffix {"c": 3}') == {"a": {"b": [1, 2]}}
    assert extract_json_object('[1,2] then {"x": "}"}') == {"x": "}"}
    with pytest.raises(ValueError):
        extract_json_object("no json here")


def test_complete_json_repairs_then_succeeds():
    llm = FakeLLM({"critic": ["not json at all", '{"score": 3}',
                              '{"score": 3, "summary": "s", "issues": [], "done": false}']})
    obj, res = llm.complete_json("critic", "USER", session_id="g",
                                 required=["score", "summary", "issues", "done"])
    assert obj["score"] == 3
    assert len(llm.calls) == 3
    # repair calls are in the same role and carry the original user message, the error and output
    assert all(c.role == "critic" for c in llm.calls)
    assert llm.calls[1].user.startswith("USER")
    assert "not json at all" in llm.calls[1].user
    assert "missing required keys: summary" in llm.calls[2].user


def test_complete_json_gives_up_after_two_repairs():
    llm = FakeLLM({"critic": ["x", "y", "z", '{"score":1}']})
    with pytest.raises(LLMError):
        llm.complete_json("critic", "U", session_id="g", required=["score"])
    assert len(llm.calls) == 3


def test_fake_llm_exhausted_raises():
    with pytest.raises(LLMError):
        FakeLLM({}).complete("coder", "u", session_id="g")


# --- extract_luau ---------------------------------------------------------------------------


def test_extract_luau():
    assert extract_luau_ok("Here:\n```luau\nprint(1)\n```\n") == "print(1)\n"
    assert extract_luau_ok("```lua\nlocal x = 1\nreturn x\n```") == "local x = 1\nreturn x\n"
    # prefers a tagged luau block over an untagged one
    assert extract_luau_ok("```\nnot this\n```\n```luau\nthis()\n```") == "this()\n"
    with pytest.raises(LLMError):
        roles.extract_luau("no code")
    with pytest.raises(LLMError):
        roles.extract_luau("```luau\nunterminated")


def extract_luau_ok(text):
    return roles.extract_luau(text)


# --- roles round-trips ----------------------------------------------------------------------


def test_design_round_trip_and_normalization():
    llm = FakeLLM({"designer": ["```json\n" + json.dumps(SPEC) + "\n```"]})
    spec = roles.design(llm, "a coin game", "- use task.wait", session_id="coin-dash")
    assert spec["slug"] == "coin-dash"
    game = spec["modules"][1]
    assert game["depends"] == ["ReplicatedStorage/Config.luau", "ReplicatedStorage/ForgeTelemetry.luau"]
    user = llm.calls[0].user
    assert "a coin game" in user
    assert roles.LESSONS_HEADER in user and "- use task.wait" in user
    assert llm.calls[0].session_id == "coin-dash"


def test_design_retries_invalid_paths():
    bad = dict(SPEC, modules=[{"path": "Workspace/Thing.server.luau", "purpose": "", "depends": []}])
    llm = FakeLLM({"designer": [json.dumps(bad), json.dumps(SPEC)]})
    spec = roles.design(llm, "idea", "", session_id="g")
    assert len(spec["modules"]) == 3
    assert "Workspace/Thing.server.luau" in llm.calls[1].user


def test_critique_round_trip_and_normalization():
    reply = json.dumps({"score": "12", "summary": "ok",
                        "issues": [{"path": "ServerScriptService/Game.server.luau", "problem": "p"}, "junk"],
                        "done": "false"})
    llm = FakeLLM({"critic": [reply]})
    report = {"uptime": 10, "errors": [{"message": f"e{i}"} for i in range(30)], "counters": {}}
    c = roles.critique(llm, SPEC, report, "console\n" * 5000,
                       {"ServerScriptService/Game.server.luau": "print(1)\n" * 4000}, session_id="g")
    assert c["score"] == 10 and c["done"] is False
    assert c["issues"] == [{"path": "ServerScriptService/Game.server.luau", "problem": "p", "fix_hint": ""}]
    assert len(llm.calls[0].user) <= roles.MAX_USER_CHARS + 200
    assert "more errors omitted" in llm.calls[0].user


def test_code_module_includes_deps_and_lessons():
    llm = FakeLLM({"coder": ["```luau\nlocal M = {}\nreturn M\n```"]})
    big_dep = "local Config = {}\nfunction Config.get() end\n" + "-- filler\n" * 5000 + "return Config\n"
    src = roles.code_module(llm, SPEC, SPEC["modules"][1], {"ReplicatedStorage/Config.luau": big_dep},
                            "- lesson one", session_id="g")
    assert src == "local M = {}\nreturn M\n"
    user = llm.calls[0].user
    assert "path: ServerScriptService/Game.server.luau" in user
    assert "function Config.get()" in user and "API summary" in user
    assert roles.LESSONS_HEADER in user
    assert len(user) < roles.MAX_USER_CHARS


def test_code_module_retries_missing_fence():
    llm = FakeLLM({"coder": ["oops no code", "```luau\nprint(1)\n```"]})
    assert roles.code_module(llm, SPEC, SPEC["modules"][0], {}, "", session_id="g") == "print(1)\n"
    assert len(llm.calls) == 2


def test_fix_file_keeps_source_whole():
    source = "print('x')\n" * 1000
    llm = FakeLLM({"fixer": ["```luau\nprint('fixed')\n```"]})
    out = roles.fix_file(llm, "ServerScriptService/Game.server.luau", source, "error: boom",
                         "ctx", "- l", session_id="g")
    assert out == "print('fixed')\n"
    assert source in llm.calls[0].user


def test_reflect_strips_fence():
    llm = FakeLLM({"reflector": ["```markdown\n# Lessons\n- a\n```"]})
    assert roles.reflect(llm, "", "summary", session_id="g") == "# Lessons\n- a\n"


def test_fake_default_drives_all_roles():
    llm = FakeLLM({}, default=fake_default_reply)
    spec = roles.design(llm, "x", "", session_id="g")
    for m in spec["modules"]:
        assert roles.code_module(llm, spec, m, {}, "", session_id="g").strip()
    assert roles.critique(llm, spec, {}, "", {}, session_id="g")["score"] == 5
    assert roles.reflect(llm, "", "s", session_id="g").startswith("# Lessons")


# --- make_llm / MubitLLM --------------------------------------------------------------------


def test_make_llm_requires_key(tmp_path, monkeypatch):
    monkeypatch.delenv("FORGE_FAKE_LLM", raising=False)
    with pytest.raises(LLMError, match="MUBIT_API_KEY"):
        make_llm(_settings(tmp_path, key=None), None)
    monkeypatch.setenv("FORGE_FAKE_LLM", "1")
    assert isinstance(make_llm(_settings(tmp_path, key=None), None), FakeLLM)


class _FakeStatusError(Exception):
    def __init__(self, status, headers):
        super().__init__(f"status {status}")
        self.status_code = status
        self.response = type("R", (), {"headers": headers})()


def test_mubit_retries_429_and_logs(tmp_path):
    log = tmp_path / "calls.jsonl"
    llm = MubitLLM(_settings(tmp_path), log)
    sleeps = []
    llm.sleep = sleeps.append
    attempts = []

    def fake_call(system, user, session_id, max_tokens):
        attempts.append(system)
        if len(attempts) == 1:
            raise _FakeStatusError(429, {"retry-after": "1.5"})
        return "hi", "mreq_abc", 10, 2, "claude-sonnet-5"

    llm._call_anthropic = fake_call
    res = llm.complete("coder", "hello", session_id="g")
    assert res.text == "hi" and res.request_id == "mreq_abc"
    assert sleeps == [1.5]
    assert attempts[0] == load_prompt("coder")
    lines = log.read_text().splitlines()
    rec = json.loads(lines[-1])
    for k in ("ts", "role", "session_id", "model", "request_id", "latency_ms",
              "input_tokens", "output_tokens", "user_chars", "reply_chars"):
        assert k in rec
    assert "mbt_secret_key" not in log.read_text()


def test_mubit_does_not_retry_400(tmp_path):
    llm = MubitLLM(_settings(tmp_path), None)
    llm.sleep = lambda s: None
    n = []

    def fake_call(*a):
        n.append(1)
        raise _FakeStatusError(400, {})

    llm._call_anthropic = fake_call
    with pytest.raises(LLMError):
        llm.complete("coder", "x", session_id="g")
    assert len(n) == 1


def test_mubit_refuses_non_mubit_url(tmp_path):
    s = _settings(tmp_path)
    s = Settings(**{**s.__dict__, "base_url": "https://api.anthropic.com"})
    with pytest.raises(LLMError):
        MubitLLM(s, None)
