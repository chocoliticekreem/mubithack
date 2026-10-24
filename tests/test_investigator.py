"""The investigator: probes in the live playtest and code reads before the fixer edits anything."""

from __future__ import annotations

import json

from forge import improve as imp
from forge.improve import run_cycle
from forge.llm import FakeLLM, load_prompt
from test_fix_loop import HOSE, HOSE_FILE, _seeded_game, settings  # noqa: F401
from test_improve import FakeHarness, audit_reply, fake_playtest

RACK_FILE = "ServerScriptService/Services/RackService.luau"


class FakeStudio:
    def __init__(self, replies):
        self.replies = list(replies)
        self.ran: list[tuple[str, str]] = []

    async def execute_luau(self, code, datamodel="Edit", timeout=None):
        self.ran.append((datamodel, code))
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply


class StudioHarness(FakeHarness):
    def __init__(self, studio):
        super().__init__()
        self.studio = studio


def _game_with_rack(settings):
    game = _seeded_game(settings)
    (game / RACK_FILE).write_text("-- RackService: gear racks and their prompts\nreturn {rack = 1}\n")
    (game / "tests").mkdir()
    (game / "tests" / "rack.spec.luau").write_text("return {}\n")
    return game


async def test_investigation_probes_reads_and_concludes(settings):
    game = _game_with_rack(settings)
    studio = FakeStudio(["plain prompt here: triggered", RuntimeError("Studio dropped")])
    llm = FakeLLM({"investigator": [
        json.dumps({"action": "probe", "datamodel": "Client", "code": "return 'x'", "why": "control"}),
        json.dumps({"action": "probe", "datamodel": "Server", "code": "return 'y'", "why": "rack"}),
        json.dumps({"action": "read", "path": RACK_FILE, "why": "how racks are built"}),
        json.dumps({"action": "conclude", "root_cause": "rack part sits inside the wall", "file": RACK_FILE,
                    "evidence": "probe 1 vs 2", "fix_hint": "move the part out"}),
    ]})
    out = await imp.investigate(settings, "fab", HOSE, llm=llm, studio=studio, session_id="s", log=lambda _: None)
    assert out["conclusion"]["file"] == RACK_FILE and len(out["steps"]) == 3
    assert studio.ran[0][0] == "Client" and studio.ran[1][0] == "Server"
    assert "probe error: RuntimeError" in out["steps"][1]["result"]
    assert "gear racks and their prompts" in out["steps"][2]["result"]
    first = llm.calls[0].user
    assert RACK_FILE in first and "gear racks and their prompts" in first and "tests/rack.spec.luau" not in first
    assert "plain prompt here: triggered" in llm.calls[1].user
    assert len({c.session_id for c in llm.calls}) == 1


async def test_conclusion_with_a_bad_file_falls_back(settings):
    _game_with_rack(settings)
    llm = FakeLLM({"investigator": [json.dumps({"action": "conclude", "root_cause": "r", "file": "../../etc/x",
                                                "evidence": "e", "fix_hint": "h"})]})
    out = await imp.investigate(settings, "fab", HOSE, llm=llm, studio=FakeStudio([]), session_id="s",
                                log=lambda _: None)
    assert out["conclusion"]["file"] is None


async def test_out_of_steps_forces_a_conclusion_prompt(settings):
    _game_with_rack(settings)
    probe = json.dumps({"action": "probe", "datamodel": "Server", "code": "return 1", "why": "w"})
    llm = FakeLLM({"investigator": [probe, probe]})
    out = await imp.investigate(settings, "fab", HOSE, llm=llm, studio=FakeStudio(["1", "1"]), session_id="s",
                                max_steps=2, log=lambda _: None)
    assert out["conclusion"] is None and "last step: conclude now" in llm.calls[1].user


async def test_fix_uses_the_investigated_file_and_root_cause(settings):
    game = _game_with_rack(settings)
    llm = FakeLLM({
        "auditor": [audit_reply([HOSE])],
        "investigator": [json.dumps({"action": "conclude", "root_cause": "rack part sits inside the wall",
                                     "file": RACK_FILE, "evidence": "e", "fix_hint": "move it"})],
        "fixer": ["```luau\nreturn {rack = 2}\n```"],
        "verifier": [json.dumps({"verdict": "fixed", "evidence": "rounds start now"})],
    })

    async def resync(root):
        pass

    cycle = await run_cycle(settings, "fab", llm=llm, harness=StudioHarness(FakeStudio([])),
                            playtest=fake_playtest([]), faults=[], goal="play", rounds=1, fix=True,
                            resync=resync, log=lambda _: None, repro=False)
    fx = cycle["code_fixes"][0]
    assert fx["status"] == "kept" and fx["path"] == RACK_FILE  # not the keyword guess (HoseService)
    assert (game / RACK_FILE).read_text().strip() == "return {rack = 2}"
    fixer_msg = next(c.user for c in llm.calls if c.role == "fixer")
    assert "rack part sits inside the wall" in fixer_msg and "move it" in fixer_msg
    assert fx["investigation"]["conclusion"]["root_cause"] == "rack part sits inside the wall"


def test_investigator_prompt_exists():
    assert "probe" in load_prompt("investigator")
