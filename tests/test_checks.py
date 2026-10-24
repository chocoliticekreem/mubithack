import asyncio
import shutil
import subprocess

import pytest

from forge import checks as fchecks
from forge.checks import (Check, check_id, helpers_doc, lint_setup, load_checks, parse, result_from, run_check,
                          run_checks, save_check, setup_failure, summary, wrap)


class FakeStudio:
    def __init__(self, reply=None, exc=None):
        self.reply, self.exc, self.calls = reply, exc, []

    async def execute_luau(self, code, datamodel="Edit", timeout=None):
        self.calls.append((code, datamodel))
        if self.exc:
            raise self.exc
        return self.reply


def test_save_load_round_trip(tmp_path):
    c = Check(id=check_id("Buy pad: 2nd dropper!"), title="Buy pad works", covers="acceptance: dropper",
              body="return { ok = true, detail = 'x' }")
    save_check(tmp_path, c)
    [got] = load_checks(tmp_path)
    assert got.id == "buy-pad-2nd-dropper" and got.title == "Buy pad works" and got.covers == "acceptance: dropper"
    assert "return { ok = true" in got.body
    assert parse(got.body).title == "Buy pad works"


def test_result_from_reads_json_and_rejects_garbage():
    assert result_from('{"ok":true,"detail":"cash 25 -> 0"}') == {"ok": True, "detail": "cash 25 -> 0"}
    assert result_from('{"ok":false,"error":"boom"}')["error"] == "boom"
    assert result_from("nothing")["ok"] is False


def test_run_check_uses_server_and_reports_errors():
    ok = asyncio.run(run_check(FakeStudio('{"ok":true,"detail":"d"}'), Check("a", "A", "", "return {ok=true}")))
    assert ok == {"id": "a", "title": "A", "ok": True, "detail": "d"}
    bad = asyncio.run(run_check(FakeStudio(exc=TimeoutError("slow")), Check("b", "B", "", "")))
    assert bad["ok"] is False and "TimeoutError" in bad["error"]
    assert "FAIL b" in summary([ok, bad]) and "1/2 pass" in summary([ok, bad])


# ---------------------------------------------------------------- setup: a check that never reached its situation

ROUND_FAIL = '{"ok":false,"error":"setup: round did not start (RoundState=Lobby, via MissionService:StartRound)"}'


class PlayStudio(FakeStudio):
    """Also play/stop; the player probe (scenarios.wait_for_player) says yes; checks get the next reply."""

    def __init__(self, replies):
        super().__init__()
        self.replies, self.events = list(replies), []

    async def play(self):
        self.events.append("play")

    async def stop(self):
        self.events.append("stop")

    async def execute_luau(self, code, datamodel="Edit", timeout=None):
        if "HumanoidRootPart" in code and "__http" not in code:
            return "yes"
        self.events.append("check")
        return self.replies.pop(0)


@pytest.fixture
def no_settle(monkeypatch):
    monkeypatch.setattr(fchecks, "RESTART_SETTLE", 0)


def test_setup_failure_is_in_the_error_or_in_a_detail_built_from_one():
    assert setup_failure({"ok": False, "error": "setup: no player"})
    # run 2: checks wrapped forge.startRound in pcall and returned its error as a clean ok = false
    assert setup_failure({"ok": False, "detail": "startRound failed: setup: round did not start"})
    assert not setup_failure({"ok": False, "detail": "cash 5 -> -5"})
    assert not setup_failure({"ok": True, "detail": "setup: fine"})
    assert "UNKNOWN (could not set up) a" in summary([{"id": "a", "ok": False, "error": "setup: x"}])


def test_lint_wants_a_setup_assertion_outside_comments():
    assert lint_setup("return { ok = true, detail = '' }") == fchecks.LINT_SETUP
    assert lint_setup("-- error('setup: only a comment')\n--[[ assert(x, \"setup: y\") ]]\nreturn {ok=true}")
    assert lint_setup('assert(tierAfter > tierBefore, "setup: no tier-up")\nreturn {ok=true}') is None
    assert lint_setup("if not p then error('setup: no player') end\nreturn {ok=true}") is None
    assert lint_setup('error(string.format("setup: no %s", name))') is None


def test_helper_docs_tell_every_writer_to_prove_the_situation_first():
    doc = helpers_doc({})
    assert 'assert(tierAfter > tierBefore, "setup: no tier-up")' in doc and "pass without testing anything" in doc
    assert "no pcall" in doc and "Results phase" in doc


async def test_a_setup_failure_reruns_once_in_a_fresh_playtest(no_settle):
    st = PlayStudio([ROUND_FAIL, '{"ok":true,"detail":"Active"}'])
    logs = []
    res = await run_check(st, Check("r", "Round starts", "", "forge.startRound()"), log=logs.append)
    assert res["ok"] is True and res["restarted"] is True and "setup: round" in res["first"]["error"]
    assert st.events == ["check", "stop", "play", "check"] and "fresh playtest" in logs[0]
    assert "setup" not in res


async def test_still_unknown_after_a_fresh_playtest_and_no_restart_storm(no_settle):
    st = PlayStudio([ROUND_FAIL, ROUND_FAIL, ROUND_FAIL, '{"ok":false,"detail":"cash 5 -> -5"}'])
    a, b, c = (Check(i, i, "", "") for i in "abc")
    res = await run_checks(st, [a, b, c], log=lambda _: None)
    assert res[0]["setup"] is True and res[0]["restarted"] is True
    # the fresh playtest did not help, so the rest of the batch is not restarted again
    assert res[1]["setup"] is True and "restarted" not in res[1]
    assert res[2]["ok"] is False and "setup" not in res[2]
    assert st.events.count("play") == 1


async def test_no_restart_without_play_stop_or_when_not_asked(no_settle):
    plain = await run_check(FakeStudio(ROUND_FAIL), Check("a", "A", "", ""))
    assert plain["setup"] is True and "restarted" not in plain
    st = PlayStudio([ROUND_FAIL])
    assert (await run_check(st, Check("a", "A", "", ""), fresh=False))["setup"] is True and st.events == ["check"]


def test_start_round_waits_out_a_round_still_in_its_results_phase():
    w = wrap("forge.startRound(20)\nreturn { ok = true, detail = '' }")
    helper = w[w.index("function forge.startRound"):w.index("function forge.endRound")]
    assert "forge.roundIdle()" in helper and helper.index("forge.waitFor") < helper.index('forge.harness("round"')


@pytest.mark.skipif(not shutil.which("luau-compile"), reason="luau-compile not on PATH")
def test_wrapped_check_compiles(tmp_path):
    body = "local x = 1\ntask.wait(0)\nif x == 1 then return { ok = true, detail = 'one' } end\nreturn { ok = false }"
    f = tmp_path / "c.luau"
    f.write_text(wrap(body))
    assert subprocess.run(["luau-compile", "--null", str(f)], capture_output=True).returncode == 0
