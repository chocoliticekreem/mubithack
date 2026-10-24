"""The scenario designer: plan checks from a spec, run them, split game bugs from check bugs."""

from __future__ import annotations

import asyncio
import json
from dataclasses import replace

import pytest

from forge import scenarios as sc
from forge.checks import Check, load_checks, save_check
from forge.config import load_settings
from forge.llm import FakeLLM, load_prompt
from forge.memory import RunStore

SPEC = {
    "title": "Coin Shop", "slug": "shop", "pitch": "Buy a hat for 10 coins.",
    "core_loop": "Collect coins, touch the shop pad to buy a hat once.",
    "modules": [{"path": "ServerScriptService/Shop.luau", "purpose": "shop pad"}],
    "acceptance": ["Buying the hat costs 10 coins", "The hat can only be bought once"],
}
OK_BODY = 'local p = game.Players:GetPlayers()[1]\nreturn { ok = p ~= nil, detail = "player" }'
BAD_BODY = "local x = = 1\nreturn { ok = true }"


@pytest.fixture
def settings(tmp_path):
    s = replace(load_settings(), runs_dir=tmp_path / "runs")
    store = RunStore(s, "shop")
    store.ensure()
    store.save_spec(SPEC)
    game = store.game_dir
    (game / "ServerScriptService").mkdir(parents=True)
    (game / "ServerScriptService" / "Shop.luau").write_text(
        "-- Shop: the hat pad\nlocal pad = workspace:FindFirstChild('HatPad')\nreturn {}\n")
    (game / "ServerScriptService" / "ForgeTest.server.luau").write_text("-- harness\nprint('x')\n")
    (game / "StarterPlayerScripts").mkdir()
    (game / "StarterPlayerScripts" / "Hud.client.luau").write_text("-- Hud\n")
    return s


def plan_reply(*checks):
    return json.dumps({"checks": [{"title": t, "covers": c, "body": b} for t, c, b in checks]})


class FakeStudio:
    """Play/stop plus execute_luau: the player probe says yes; each check returns the next reply."""

    def __init__(self, replies):
        self.replies = list(replies)
        self.events: list[str] = []

    async def play(self):
        self.events.append("play")

    async def stop(self):
        self.events.append("stop")

    async def execute_luau(self, code, datamodel="Edit", timeout=None):
        assert datamodel == "Server"
        if "HumanoidRootPart" in code and "__http" not in code:
            return "yes"
        self.events.append("check")
        return self.replies.pop(0)


@pytest.fixture(autouse=True)
def fast(monkeypatch):
    monkeypatch.setattr(sc, "SETTLE_S", 0)


def test_new_roles_have_prompts():
    assert "checks" in load_prompt("scenarist") and "game_bug" in load_prompt("check_reviewer")


def test_plan_message_has_spec_map_and_server_code_but_not_the_runtime(settings):
    store = RunStore(settings, "shop")
    msg = sc.plan_message(SPEC, sc.file_map(store.game_dir), sc.key_code(store.game_dir, SPEC), ["Old one"], 9)
    assert "Buying the hat costs 10 coins" in msg and "HatPad" in msg and "- Old one" in msg
    assert "StarterPlayerScripts/Hud.client.luau" in msg  # in the file map
    assert "ForgeTest" not in msg.split("## Key server code")[1]
    assert "at most 9 checks" in msg


def test_plan_saves_checks_and_never_overwrites(settings):
    store = RunStore(settings, "shop")
    save_check(store.dir, Check(id="hat-costs-10", title="Hat costs 10", covers="mine", body="return {ok=true}"))
    llm = FakeLLM({"scenarist": [plan_reply(("Hat costs 10", "acceptance: cost", OK_BODY),
                                            ("Hat once only", "edge: hat - twice", OK_BODY))]})
    saved = sc.plan_checks(settings, "shop", llm=llm, log=lambda m: None)
    assert [c.id for c in saved] == ["01-hat-once-only"]
    got = {c.id: c for c in load_checks(store.dir)}
    assert got["hat-costs-10"].covers == "mine"  # the existing check is untouched
    assert got["01-hat-once-only"].covers == "edge: hat - twice"
    more = FakeLLM({"scenarist": [plan_reply(("Hat once only", "dup", OK_BODY), ("Zero coins", "edge", OK_BODY))]})
    assert [c.id for c in sc.plan_checks(settings, "shop", llm=more, log=lambda m: None)] == ["02-zero-coins"]
    assert "Hat costs 10" in llm.calls[0].user  # existing titles are sent so they are not repeated


@pytest.mark.skipif(not sc.luau_compiler(), reason="luau-compile not installed")
def test_check_that_does_not_compile_gets_one_correction(settings):
    llm = FakeLLM({"scenarist": [
        plan_reply(("Good", "acceptance: a", OK_BODY), ("Broken", "acceptance: b", BAD_BODY)),
        plan_reply(("Broken", "acceptance: b", OK_BODY)),
    ]})
    saved = sc.plan_checks(settings, "shop", llm=llm, log=lambda m: None)
    assert [c.id for c in saved] == ["01-good", "02-broken"]  # plan order kept
    assert "did not compile" in llm.calls[1].user and "check.luau" in llm.calls[1].user


@pytest.mark.skipif(not sc.luau_compiler(), reason="luau-compile not installed")
def test_check_still_broken_after_correction_is_dropped(settings):
    llm = FakeLLM({"scenarist": [plan_reply(("Broken", "x", BAD_BODY)), plan_reply(("Broken", "x", BAD_BODY))]})
    assert sc.plan_checks(settings, "shop", llm=llm, log=lambda m: None) == []
    assert len(llm.calls) == 2


def test_compile_is_skipped_without_luau_compile(settings, monkeypatch):
    monkeypatch.setattr(sc, "luau_compiler", lambda: None)
    assert sc.compile_error(BAD_BODY) is None


def _three_checks(settings):
    store = RunStore(settings, "shop")
    for t, cov in (("Passes", "acceptance: a"), ("Real bug", "acceptance: Buying the hat costs 10 coins"),
                   ("Bad check", "edge: hat - twice")):
        save_check(store.dir, Check(id=sc.check_id(t), title=t, covers=cov, body=OK_BODY))
    return store


def test_run_reviews_failures_in_one_call_and_splits_bugs(settings):
    store = _three_checks(settings)
    review = json.dumps({"reviews": [
        {"id": "real-bug", "verdict": "game_bug", "reason": "cash went 5 -> -5", "kind": "economy",
         "system": "shop", "severity": "high", "expected": "no purchase below cost"},
        {"id": "bad-check", "verdict": "check_bug", "reason": "used FireServer", "body": OK_BODY},
    ]})
    llm = FakeLLM({"check_reviewer": [review]})
    # load order is alphabetical: bad-check, passes, real-bug; then the rewritten bad-check re-runs
    studio = FakeStudio(['{"ok":false,"error":"FireServer can only be called from the client"}',
                         '{"ok":true,"detail":"fine"}', '{"ok":false,"detail":"cash 5 -> -5"}',
                         '{"ok":true,"detail":"rewritten ok"}'])
    results = asyncio.run(sc.run_plan(studio, "shop", settings=settings, llm=llm, log=lambda m: None))
    assert studio.events[0] == "play" and studio.events[-1] == "stop"
    assert len([c for c in llm.calls if c.role == "check_reviewer"]) == 1
    v = {r["id"]: r["verdict"] for r in results}
    assert v == {"bad-check": "check_bug_fixed", "passes": "pass", "real-bug": "game_bug"}
    assert sc.load_results(store.dir)[2]["detail"] == "cash 5 -> -5"
    [a] = sc.as_anomalies(results)
    assert set(a) >= {"title", "kind", "severity", "system", "observed", "expected", "evidence"}
    assert (a["kind"], a["severity"], a["system"], a["check"]) == ("economy", "high", "shop", "real-bug")
    assert "cash 5 -> -5" in a["observed"] and "real-bug" in a["evidence"]


def test_check_bug_without_rewrite_or_still_failing_is_dropped(settings):
    store = _three_checks(settings)
    review = json.dumps({"reviews": [
        {"id": "bad-check", "verdict": "check_bug", "reason": "cannot be tested", "body": ""},
        {"id": "real-bug", "verdict": "check_bug", "reason": "wrong wait", "body": OK_BODY},
    ]})
    studio = FakeStudio(['{"ok":false,"detail":"x"}', '{"ok":true}', '{"ok":false,"detail":"y"}',
                         '{"ok":false,"detail":"still"}'])
    results = asyncio.run(sc.run_plan(studio, "shop", settings=settings,
                                      llm=FakeLLM({"check_reviewer": [review]}), log=lambda m: None))
    assert {r["id"]: r["verdict"] for r in results} == {"bad-check": "dropped", "passes": "pass",
                                                       "real-bug": "dropped"}
    assert [c.id for c in load_checks(store.dir)] == ["passes"]
    assert sorted(p.name for p in (store.dir / "checks" / "dropped").glob("*.luau")) == ["bad-check.luau",
                                                                                         "real-bug.luau"]
    assert sc.as_anomalies(results) == []


def test_unreviewed_failure_stays_a_game_bug(settings):
    _three_checks(settings)
    studio = FakeStudio(['{"ok":true}', '{"ok":true}', '{"ok":false,"detail":"boom"}'])
    results = asyncio.run(sc.run_plan(studio, "shop", settings=settings,
                                      llm=FakeLLM({"check_reviewer": ['{"reviews": []}']}), log=lambda m: None))
    [a] = sc.as_anomalies(results)
    assert a["check"] == "real-bug" and a["severity"] == "medium" and a["kind"] == "error"


def test_stop_play_even_when_a_check_crashes(settings):
    _three_checks(settings)

    class Boom(FakeStudio):
        async def execute_luau(self, code, datamodel="Edit", timeout=None):
            if "__http" in code:
                raise RuntimeError("studio gone")
            return "yes"

    studio = Boom([])
    results = asyncio.run(sc.run_plan(studio, "shop", settings=settings, llm=None, log=lambda m: None))
    assert studio.events == ["play", "stop"] and not any(r["ok"] for r in results)


def test_irreversible_checks_each_get_a_fresh_playtest(settings):
    store = RunStore(settings, "shop")
    for t, cov in (("Buy hat", "acceptance: buy; irreversible"), ("Zero coins", "edge: zero"),
                   ("Buy twice", "edge: twice (Irreversible)"), ("Hat pad exists", "acceptance: pad")):
        save_check(store.dir, Check(id=sc.check_id(t), title=t, covers=cov, body=OK_BODY))
    groups = sc.play_sessions(load_checks(store.dir))
    assert [[c.id for c in g] for g in groups] == [["hat-pad-exists", "zero-coins"], ["buy-hat"], ["buy-twice"]]
    studio = FakeStudio(['{"ok":true}'] * 4)
    results = asyncio.run(sc.run_plan(studio, "shop", settings=settings, llm=None, log=lambda m: None))
    assert [r["id"] for r in results] == ["buy-hat", "buy-twice", "hat-pad-exists", "zero-coins"]
    assert studio.events == ["play", "check", "check", "stop", "play", "check", "stop", "play", "check", "stop"]


def test_inconclusive_pass_counts_as_failure(settings):
    _three_checks(settings)
    studio = FakeStudio(['{"ok":true,"detail":"Inconclusive: income arrived"}', '{"ok":true}', '{"ok":true}'])
    results = asyncio.run(sc.run_plan(studio, "shop", settings=settings, llm=None, log=lambda m: None))
    assert [r["ok"] for r in results] == [False, True, True]


def test_as_anomalies_severity_from_covers_without_review():
    res = [{"id": "a", "title": "A", "covers": "acceptance: x", "ok": False, "detail": "d", "verdict": "game_bug"},
           {"id": "b", "title": "B", "covers": "edge: y", "ok": False, "detail": "d", "verdict": "game_bug"},
           {"id": "c", "title": "C", "ok": True, "verdict": "pass"}]
    assert [a["severity"] for a in sc.as_anomalies(res)] == ["high", "medium"]
