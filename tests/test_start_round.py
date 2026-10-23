"""--start-round: each test round begins inside the game, through the harness's generic `round` command."""

from __future__ import annotations

from forge import improve as imp


class RoundHarness:
    def __init__(self, fail_results=False):
        self.calls: list[tuple] = []
        self.fail_results = fail_results

    async def ensure_ready(self):
        self.calls.append(("ready",))

    async def call(self, cmd, **args):
        self.calls.append((cmd, args))
        if self.fail_results and args.get("state") == "Results":
            raise RuntimeError("no round running")
        return {"RoundState": args.get("state")}


async def test_round_is_ended_then_started_before_the_testers_play(monkeypatch):
    monkeypatch.setattr(imp, "START_ROUND_WAIT", 0)
    monkeypatch.setattr(imp, "END_ROUND_WAIT", 0)
    played = []

    async def playtest(settings, goal, players, steps, *, llm, harness):
        played.append(list(harness.calls))
        return {"goal": goal}

    h = RoundHarness()
    rep = await imp.round_starting(playtest, seconds=120)(None, "g", None, 5, llm=None, harness=h)
    assert rep == {"goal": "g"}
    assert played[0] == [("ready",), ("round", {"state": "Results"}), ("round", {"state": "Active", "seconds": 120})]


async def test_nothing_to_end_is_fine(monkeypatch):
    monkeypatch.setattr(imp, "START_ROUND_WAIT", 0)
    monkeypatch.setattr(imp, "END_ROUND_WAIT", 0)

    async def playtest(settings, goal, players, steps, *, llm, harness):
        return {"ok": True}

    h = RoundHarness(fail_results=True)
    assert await imp.round_starting(playtest)(None, "g", None, 5, llm=None, harness=h) == {"ok": True}
    assert ("round", {"state": "Active"}) in h.calls
