"""The fix loop treats dead interactions (forge/interactions.py) and failed journey steps (forge/journey.py) as
anomalies. They are proven already, so no reproducer runs, and a fix to a dead interaction is re-audited before
the playtest round: still dead, it is rejected with the audit's words."""

from __future__ import annotations

import json
import shutil

import pytest

from forge import journey
from forge.improve import ImproveStore, run_cycle
from forge.llm import FakeLLM
from test_improve import audit_reply, settings  # noqa: F401
from test_interactions import SHOP, SHOP_FIXED

pytestmark = pytest.mark.skipif(not (shutil.which("luau-ast") and shutil.which("luau-compile")),
                                reason="needs luau-ast and luau-compile")
SHOP_FILE = "ServerScriptService/Shop.luau"


class Studio:
    async def execute_luau(self, code, datamodel="Edit", timeout=None):
        return "probe ok"


class Harness:
    def __init__(self):
        self.studio = Studio()

    async def ensure_ready(self):
        return {"ok": True}


def _game(settings):
    run = ImproveStore(settings, "fab").run
    run.ensure()
    run.save_spec({"pitch": "funfair obby", "core_loop": "try on costumes, then jump"})
    (run.game_dir / SHOP_FILE).parent.mkdir(parents=True, exist_ok=True)
    (run.game_dir / SHOP_FILE).write_text(SHOP)
    return run.game_dir


def _conclude():
    return json.dumps({"action": "conclude", "root_cause": "setupPad never connects Triggered", "file": SHOP_FILE,
                       "evidence": "static audit", "fix_hint": "connect Triggered"})


async def _cycle(settings, llm, monkeypatch, refresh=None, **kw):
    async def no_journey(*a, **k):
        return None

    async def playtest(settings_, goal, players, steps, *, llm, harness):
        return {"goal": goal, "counters": {"checkpoint_reached": 1}}

    async def resync(root):
        pass

    monkeypatch.setenv("FORGE_JOURNEY", "1")
    monkeypatch.setattr(journey, "refresh", refresh or no_journey)  # the journey run itself: test_journey
    return await run_cycle(settings, "fab", llm=llm, harness=Harness(), playtest=playtest, faults=[], goal="play",
                           rounds=1, fix=True, resync=resync, log=lambda _: None, **kw)


async def test_a_dead_prompt_is_fixed_without_a_reproducer_and_kept_once_the_audit_is_clean(settings, monkeypatch):
    game = _game(settings)
    llm = FakeLLM({"auditor": [audit_reply([])], "investigator": [_conclude()],
                   "fixer": [f"```luau\n{SHOP_FIXED}\n```"],
                   "verifier": [json.dumps({"verdict": "inconclusive", "evidence": "e"})]})
    cycle = await _cycle(settings, llm, monkeypatch)
    fx = cycle["code_fixes"][0]
    assert fx["status"] == "kept" and fx["path"] == SHOP_FILE, fx
    assert "reproducer" not in [c.role for c in llm.calls]
    fixer = next(c.user for c in llm.calls if c.role == "fixer")
    assert "## Proof" in fixer and "static interaction audit" in fixer and "Try on costumes" in fixer
    assert "Triggered:Connect" in (game / SHOP_FILE).read_text()
    assert cycle["open"] == 1


async def test_a_fix_that_leaves_the_prompt_dead_is_rejected_by_the_audit_before_any_playtest(settings, monkeypatch):
    game = _game(settings)
    still = SHOP.replace("local Shop = {}", "local Shop = {} -- tidied")
    llm = FakeLLM({"auditor": [audit_reply([])], "investigator": [_conclude(), _conclude()],
                   "fixer": [f"```luau\n{still}\n```"] * 2, "reflector": ["- connect Triggered on the prompt"]})
    cycle = await _cycle(settings, llm, monkeypatch)
    fx = cycle["code_fixes"][0]
    assert fx["status"] == "rolled_back" and [t["status"] for t in fx["attempts"]] == ["check_failed"] * 2
    assert "verifier" not in [c.role for c in llm.calls]
    retry = [c.user for c in llm.calls if c.role == "fixer"][1]
    assert "still finds it after your fix" in retry
    assert (game / SHOP_FILE).read_text() == SHOP


async def test_proven_anomalies_come_first_in_the_fix_budget(settings, monkeypatch):
    game = _game(settings)
    guess = {"kind": "balance", "system": "coins", "title": "Coins feel slow", "expected": "e", "observed": "o",
             "severity": "high"}
    llm = FakeLLM({"auditor": [audit_reply([guess])], "investigator": [_conclude()],
                   "fixer": [f"```luau\n{SHOP_FIXED}\n```"],
                   "verifier": [json.dumps({"verdict": "inconclusive", "evidence": "e"})]})
    cycle = await _cycle(settings, llm, monkeypatch, max_fixes=1)
    assert [f["anomaly"] for f in cycle["code_fixes"]][0].startswith("[interactions]")  # not the auditor's guess
    assert cycle["code_fixes"][0]["status"] == "kept" and "Triggered:Connect" in (game / SHOP_FILE).read_text()


def _journey_rec(n, ok, base=True):
    prompt = {"path": "Workspace.Lobby.ChangingRoomPad.ChangingRoomPrompt", "action": "Try on costumes",
              "name": "ChangingRoomPrompt", "ok": ok,
              "detail": "'Try on costumes' at Lobby.ChangingRoomPad.ChangingRoomPrompt " + (
                  "opened Cosmetics.Dim" if ok else "was triggered and the server saw it, but nothing happened")}
    return {"n": n, "engine": "headless", "prompts": [prompt],
            "steps": [{"step": "join", "ok": True, "detail": "joined"}, {"step": "prompts", "ok": ok, "detail": "p"},
                      {"step": "stage1", "ok": base, "detail": "reached checkpoint 1" if base else "fell at stage 1"}]}


def _scripted(*recs):
    """A refresh that hands out these journeys to the fix attempts (forced); the cycle's own refreshes get none."""
    queue = list(recs)

    async def refresh(harness, game_dir, run_dir, *, force=False, log=print):
        return queue.pop(0) if force and queue else None
    refresh.queue = queue
    return refresh


async def test_the_live_journey_judges_a_fix_the_static_audit_calls_clean(settings, monkeypatch):
    """Forge's own loop kept a changing-room fix whose handler opened nothing: the audit only sees Triggered
    connected. With the journey as the judge that attempt is rejected in the journey's words, and the next kept."""
    game = _game(settings)
    llm = FakeLLM({"auditor": [audit_reply([])], "investigator": [_conclude(), _conclude()],
                   "fixer": [f"```luau\n{SHOP_FIXED}\n```"] * 2, "reflector": ["- open the panel, not just connect"],
                   "verifier": [json.dumps({"verdict": "inconclusive", "evidence": "e"})]})
    refresh = _scripted(_journey_rec(5, False), _journey_rec(6, True))
    cycle = await _cycle(settings, llm, monkeypatch, refresh=refresh)
    fx = cycle["code_fixes"][0]
    assert [t["status"] for t in fx["attempts"]] == ["check_failed", "fixed"] and fx["status"] == "kept"
    assert "in the running game it still does nothing (live journey 5)" in fx["attempts"][0]["error"]
    retry = [c.user for c in llm.calls if c.role == "fixer"][1]
    assert "but nothing happened" in retry  # the fixer is told what the player saw
    assert "Triggered:Connect" in (game / SHOP_FILE).read_text() and not refresh.queue


async def test_a_journey_step_fix_is_kept_only_when_the_step_passes_and_nothing_else_breaks(settings):
    a = {"ref": "journey:prompts", "kind": "journey"}
    base = _journey_rec(1, False)
    assert "but nothing happened" in journey.still_failing(_journey_rec(2, False), a, base)
    assert journey.still_failing(_journey_rec(3, True), a, base) == ""
    broke = journey.still_failing(_journey_rec(4, True, base=False), a, base)
    assert "step(s) that passed before now fail: stage1: fell at stage 1" in broke
    lobby = {"ref": "journey:lobby", "kind": "journey"}
    bare = {"steps": [{"step": "lobby", "ok": False, "detail": "the ground is the grey template Baseplate"}]}
    assert "still fails step lobby" in journey.still_failing(bare, lobby, None)


def _buttons(*items, ok=False):
    return {"steps": [{"step": "buttons", "ok": ok, "detail": "b"}],
            "buttons": [{"path": p, "text": t, "ok": v, "detail": f"{t}: {'works' if v else 'nothing happened'}"}
                        for p, t, v in items]}


async def test_a_button_the_fix_uncovered_is_the_next_anomaly_not_a_veto(settings):
    """Live: the fixer's RESET fix worked (back on checkpoint 1 in 1.6 s), but the GIFT button the layout fix had
    just uncovered failed the same step, and the whole fix was thrown away."""
    a = {"ref": "journey:buttons", "kind": "journey"}
    base = _buttons(("HUD.TextButton[1]", "RESET", False), ("HUD.Mute", "MUTE", True))
    after = _buttons(("HUD.TextButton[1]", "RESET", True), ("HUD.Mute", "MUTE", True), ("HUD.TextButton[2]", "GIFT", False))
    assert journey.still_failing(after, a, base) == ""
    worse = _buttons(("HUD.TextButton[1]", "RESET", True), ("HUD.Mute", "MUTE", False))
    assert "MUTE: nothing happened" in journey.still_failing(worse, a, base)
    assert "RESET: nothing happened" in journey.still_failing(base, a, base)
