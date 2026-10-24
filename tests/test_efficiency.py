"""Fewer Mubit calls for the same work: replies parsed locally instead of a repair call, the investigator's
context kept to a budget, and every call Forge did not need recorded in skipped.jsonl. All offline."""

from __future__ import annotations

import dataclasses
import json

import pytest

from forge import improve as imp
from forge import llm as fllm
from forge import roles
from forge.config import load_settings
from forge.llm import CachedLLM, FakeLLM, parse_reply, stream_verdict
from forge.memory import RunStore

NS = "an" + "tml:"  # the namespace prefix real investigator replies put on their tool-call tags


def _tool_call(name: str, params: dict, ns: str = NS) -> str:
    body = "".join(f'<{ns}parameter name="{k}">{v}</{ns}parameter>\n' for k, v in params.items())
    return f'<{ns}invoke name="{name}">\n{body}</{ns}invoke>'


# --- replies parsed locally, no repair call --------------------------------------------------------


@pytest.mark.parametrize("ns", [NS, "", "x:"])
def test_tool_call_reply_becomes_the_action_without_a_repair_call(ns):
    # the probe code holds `local out={}`: the old parser took that `{}` as the reply and paid for a repair
    code = "local out={}\nout.n = #workspace:GetChildren()\nreturn game:GetService('HttpService'):JSONEncode(out)"
    reply = _tool_call("probe", {"datamodel": "Server", "code": code, "why": "count parts"}, ns)
    llm = FakeLLM({"investigator": [reply]})
    obj, res = llm.complete_json("investigator", "x", session_id="s", required=["action"])
    assert obj == {"action": "probe", "datamodel": "Server", "code": code, "why": "count parts"}
    assert len(llm.calls) == 1


def test_tool_call_parameters_keep_json_values_and_only_the_first_call_counts():
    reply = (_tool_call("move_to_instance", {"args": '{"path": "Workspace.Map.Hydrant1"}', "reason": "refill",
                                             "bug": "null"})
             + "\n\n" + _tool_call("move_to_instance", {"args": '{"path": "elsewhere"}', "reason": "again"}))
    obj, how = parse_reply(reply, ["action", "reason"])
    assert how == "tool_call"
    assert obj == {"action": "move_to_instance", "args": {"path": "Workspace.Map.Hydrant1"}, "reason": "refill",
                   "bug": None}
    # a number stays a number, a plain word stays text
    obj, _ = parse_reply(_tool_call("read", {"path": "ServerScriptService/A.luau", "why": "42"}), ["action"])
    assert obj["why"] == 42 and obj["path"] == "ServerScriptService/A.luau"


def test_bare_parameters_name_their_action():
    reply = f'<{NS}parameter name="action">read</{NS}parameter>\n<{NS}parameter name="path">A.luau</{NS}parameter>'
    assert parse_reply(reply, ["action"]) == ({"action": "read", "path": "A.luau"}, "tool_call")


def test_cut_off_tool_call_still_gets_a_repair_call():
    # no closing tag: the code parameter may be cut, so the reply is never taken as a (code-less) probe
    cut = f'<{NS}invoke name="probe">\n<{NS}parameter name="datamodel">Server</{NS}parameter>\n<{NS}parameter name="code">loc'
    good = json.dumps({"action": "probe", "datamodel": "Server", "code": "return 1"})
    llm = FakeLLM({"investigator": [cut, good]})
    obj, _ = llm.complete_json("investigator", "x", session_id="s", required=["action"])
    assert obj["code"] == "return 1" and len(llm.calls) == 2
    assert "could not be used" in llm.calls[1].user


def test_raw_tabs_in_json_strings_are_read_without_a_repair_call():
    # a real patcher reply: Luau indentation as raw tabs inside the "find" string is invalid strict JSON
    reply = '{"summary": "s", "edits": [{"find": "\tlocal a = 1", "replace": "\tlocal a = 2"}]}'
    with pytest.raises(ValueError):
        json.loads(reply)
    llm = FakeLLM({"patcher": [reply]})
    obj, _ = llm.complete_json("patcher", "x", session_id="s", required=["edits"])
    assert obj["edits"][0]["find"] == "\tlocal a = 1" and len(llm.calls) == 1


def test_clean_json_still_wins_and_is_labelled_json():
    reply = json.dumps({"action": "read", "path": "B.luau"}) + "\n" + _tool_call("probe", {"code": "x"})
    assert parse_reply(reply, ["action"]) == ({"action": "read", "path": "B.luau"}, "json")
    with pytest.raises(ValueError):
        parse_reply("no json here", ["action"])


def test_tool_call_replies_are_not_aborted_as_prose():
    long_call = f'<{NS}invoke name="probe">\n<{NS}parameter name="code">' + "local x = 1\n" * 200
    assert stream_verdict("investigator", long_call) == "more"
    assert stream_verdict("investigator", "Let me think about it. " * 100) == "abort"


# --- skipped.jsonl: the calls Forge did not need ---------------------------------------------------


def _skipped(log_dir):
    path = log_dir / fllm.SKIPPED_LOG
    return [json.loads(ln) for ln in path.read_text().splitlines()] if path.exists() else []


def test_avoided_repairs_and_cache_hits_are_logged_next_to_calls(tmp_path):
    log = tmp_path / "improve" / "calls.jsonl"
    llm = FakeLLM({"investigator": [_tool_call("read", {"path": "A.luau"})]}, log_path=log)
    llm.complete_json("investigator", "x", session_id="s", required=["action"])
    [rec] = _skipped(log.parent)
    assert rec["kind"] == "repair_avoided" and rec["how"] == "tool_call" and rec["role"] == "investigator"
    assert rec["request_id"] == "fake-1"
    # calls.jsonl stays the log of real calls: one line for the one call made
    assert len(log.read_text().splitlines()) == 1

    inner = FakeLLM({}, default=lambda r, u: "```luau\nreturn 1\n```", log_path=log)
    cache = CachedLLM(inner, tmp_path / "cache")
    cache.complete("coder", "module A", session_id="s1")
    cache.complete("coder", "module A", session_id="s2")
    hits = [r for r in _skipped(log.parent) if r["kind"] == "cache_hit"]
    assert len(hits) == 1 and hits[0]["role"] == "coder" and hits[0]["session_id"] == "s2"
    assert hits[0]["request_id"] == "fake-1"  # the reply it reused


def test_clean_replies_log_nothing_skipped(tmp_path):
    log = tmp_path / "calls.jsonl"
    llm = FakeLLM({"investigator": [json.dumps({"action": "read", "path": "A.luau"})]}, log_path=log)
    llm.complete_json("investigator", "x", session_id="s", required=["action"])
    assert _skipped(tmp_path) == []


# --- the reply cache key -----------------------------------------------------------------------------


def test_cache_key_changes_when_any_input_changes(tmp_path, monkeypatch):
    inner = FakeLLM({})
    inner.model = "m1"
    cache = CachedLLM(inner, tmp_path / "c")
    base = cache.key("coder", "module A\nlessons v1", 4096)
    assert cache.key("coder", "module A\nlessons v1", 4096) == base  # same input, same key
    changed = {
        "role": cache.key("designer", "module A\nlessons v1", 4096),
        "user message": cache.key("coder", "module A\nlessons v2", 4096),
        "max_tokens": cache.key("coder", "module A\nlessons v1", 2048),
    }
    inner.model = "m2"
    changed["model"] = cache.key("coder", "module A\nlessons v1", 4096)
    inner.model = "m1"
    monkeypatch.setitem(fllm._PROMPT_CACHE, "coder", fllm.load_prompt("coder") + "\nedited")
    changed["system prompt"] = cache.key("coder", "module A\nlessons v1", 4096)
    for what, key in changed.items():
        assert key != base, f"cache key ignores the {what}"
    assert len(set(changed.values())) == len(changed)
    # the parts are separated: "409" + "6x" and "4096" + "x" join to the same text but are different inputs
    assert cache.key("coder", "6x", 409) != cache.key("coder", "x", 4096)


# --- the investigator's context, kept to a budget ----------------------------------------------------

ANOMALY = {"kind": "broken_link", "system": "water", "title": "Hose never cools the fire",
           "expected": "fire goes out", "observed": "fires_extinguished 0", "severity": "high"}


def _read_step(path: str, n_lines: int, needle_at: int) -> dict:
    lines = [f"local filler{i} = {i}" for i in range(n_lines)]
    lines[needle_at] = "local function cool(fire) fire.extinguished = false end -- the hose bug"
    return {"action": {"action": "read", "path": path, "why": "w"}, "result": "\n".join(lines)}


def _probe_step(k: int) -> dict:
    return {"action": {"action": "probe", "datamodel": "Server", "code": f"return {k} -- " + "x" * 900,
                       "why": "w"}, "result": f"probe {k}: " + "y" * 1400}


def test_short_step_history_is_unchanged():
    steps = [{"action": {"action": "probe", "code": "return 1", "why": "w"}, "result": "1"},
             {"action": {"action": "read", "path": "A.luau"}, "result": "return {}"}]
    old = "\n\n".join(f"{i + 1}. {json.dumps(s['action'], ensure_ascii=False)[:1500]}\nResult: {s['result']}"
                      for i, s in enumerate(steps))
    assert roles.steps_block(steps, "hose") == old


def test_long_step_history_cuts_the_oldest_steps_first_and_keeps_the_newest_whole():
    steps = [_read_step("ServerScriptService/Hose.luau", 400, 250)] + [_probe_step(k) for k in range(2, 7)]
    focus = imp._focus(ANOMALY)
    full = roles.steps_block(steps, focus, budget=10**9)
    block = roles.steps_block(steps, focus)
    assert len(full) > roles.STEPS_BUDGET and len(block) < len(full)
    assert block == "\n\n".join([roles._cut_step(i, steps[i], focus) for i in range(4)] + full.split("\n\n")[4:])
    rows = block.split("\n\n")
    assert len(rows) == len(steps)  # every step still listed, in order
    # the old read keeps its lines that match the anomaly (with their line numbers), not the file's head
    assert "read it again" in rows[0] and "251| local function cool(fire)" in rows[0] and "filler0 " not in rows[0]
    assert all("...[cut]" in r for r in rows[1:4])
    # the newest two steps are never cut, even when the rest cannot get the block under budget
    assert rows[4] == roles._step_text(4, steps[4]["action"], steps[4]["result"])
    assert rows[5] == roles._step_text(5, steps[5]["action"], steps[5]["result"])


def test_step_history_is_cut_only_as_far_as_the_budget_needs():
    steps = [_read_step("ServerScriptService/Hose.luau", 400, 250), _probe_step(2), _probe_step(3)]
    whole = [roles._step_text(i, s["action"], s["result"]) for i, s in enumerate(steps)]
    block = roles.steps_block(steps, imp._focus(ANOMALY), budget=len("\n\n".join(whole)) - 100)
    rows = block.split("\n\n")
    assert "read it again" in rows[0] and rows[1:] == whole[1:]  # one cut was enough


def _big_game(tmp_path):
    settings = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")
    store = RunStore(settings, "big")
    store.ensure()
    files = {f"ServerScriptService/Services/Service{i:03d}.luau": f"-- Service{i:03d}: handles thing {i}\nreturn {{}}\n"
             for i in range(150)}
    files["ServerScriptService/Services/HoseService.luau"] = "-- HoseService: water, the hose and cooling fires\nreturn {}\n"
    files["StarterPlayerScripts/Controllers/SprayController.luau"] = "-- spray input\nlocal hose = true\nreturn {}\n"
    files["tests/hose.spec.luau"] = "-- unit spec\nreturn {}\n"
    for rel, src in files.items():
        (store.game_dir / rel).parent.mkdir(parents=True, exist_ok=True)
        (store.game_dir / rel).write_text(src)
    return settings, store.game_dir


def test_big_game_index_names_every_file_and_ranks_the_anomaly_files(tmp_path):
    _, game = _big_game(tmp_path)
    full = imp.file_index(game, limit=10**9)
    assert len(full) > roles.INDEX_CHARS  # too big to send whole
    idx = imp.file_index(game, focus=imp._focus(ANOMALY))
    assert len(idx) <= roles.INDEX_CHARS
    for rel in (ln.split("  -- ")[0] for ln in full.splitlines()):
        assert rel.rsplit("/", 1)[-1] in idx, f"{rel} missing from the index"  # the old cut dropped half the files
    assert "tests/" not in idx and "hose.spec" not in idx
    best = idx.split("\n\n")[0].splitlines()
    assert best[1] == "ServerScriptService/Services/HoseService.luau  -- HoseService: water, the hose and cooling fires"
    # a game that fits keeps the plain list with every comment line
    assert imp.file_index(game, limit=len(full)) == full


def test_index_listing_alone_over_budget_is_cut_with_a_note():
    rows = [(f"ServerScriptService/F{i:04d}.luau", "", "") for i in range(2000)]
    out = roles.compact_index(rows, "x", budget=1000)
    assert len(out) <= 1100 and "file list truncated" in out


async def test_investigator_reads_a_file_named_without_its_folder(tmp_path):
    settings, game = _big_game(tmp_path)
    llm = FakeLLM({"investigator": [
        json.dumps({"action": "read", "path": "HoseService.luau", "why": "named in the index by folder"}),
        json.dumps({"action": "conclude", "root_cause": "r", "file": "HoseService.luau", "evidence": "e",
                    "fix_hint": "h"}),
    ]})

    class NoStudio:
        async def execute_luau(self, code, datamodel="Edit"):
            raise AssertionError("no probe expected")

    out = await imp.investigate(settings, "big", ANOMALY, llm=llm, studio=NoStudio(), session_id="s",
                                log=lambda _: None)
    assert out["steps"][0]["result"].startswith("(the file is ServerScriptService/Services/HoseService.luau)")
    assert "cooling fires" in out["steps"][0]["result"]
    assert out["conclusion"]["file"] == "ServerScriptService/Services/HoseService.luau"
    # still refused: escaping the game folder, an unknown name, and a file that is not synced into Studio
    for bad in ("../../etc/passwd", "nothing.luau"):
        assert imp._game_path(game, bad) is None
    assert imp._game_path(game, "tests/hose.spec.luau") is None
    assert imp._game_path(game, "tests/hose.spec.luau", synced=False) == "tests/hose.spec.luau"
    (game / "ReplicatedStorage").mkdir(exist_ok=True)
    (game / "ReplicatedStorage" / "HoseService.luau").write_text("return {}\n")
    assert imp._game_path(game, "HoseService.luau") is None  # two files by that name: no guess
