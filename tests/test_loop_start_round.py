"""Build-loop playtests start a round when the game's spec asks (playtest.start_round), so the critic sees
the core loop instead of an idle lobby."""

from __future__ import annotations

import dataclasses
import io
import json
from pathlib import Path

import pytest

from forge import loop
from forge.config import load_settings
from forge.loop import UI, Run
from forge.memory import RunStore


class LoopStudio:
    def __init__(self):
        self.ran: list[tuple[str, str]] = []

    async def sync(self, root, port, prune=True):
        return "OK 1 files"

    async def play(self):
        return None

    async def execute_luau(self, code, datamodel="Edit", timeout=None):
        if code.startswith("-- forge census"):
            return "{}"  # scene census for the fun critic (forge/fun.py); not a round start
        self.ran.append((datamodel, code))
        return '{"ok":true,"result":{"RoundState":"Active"}}'

    async def probe_report(self):
        return {"uptime": 1, "errors": [], "counters": {"flareups": 2}}

    async def console(self):
        return ""

    async def screenshot(self, path):
        return None

    async def stop(self):
        return None


@pytest.fixture
def run(tmp_path, monkeypatch):
    monkeypatch.setattr(loop, "START_ROUND_DELAY", 0)
    monkeypatch.setenv("FORGE_PLAY_SECONDS", "0")
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")
    store = RunStore(s, "g")
    store.ensure()
    r = Run(s, store, llm=object.__new__(type("L", (), {"complete": None})), ui=UI(io.StringIO()))
    return r


async def test_round_is_started_when_the_spec_asks(run, tmp_path):
    run.spec = {"playtest": {"start_round": True, "round_seconds": 150}}
    studio = LoopStudio()
    report, _ = await run.playtest(studio, {"steps": []}, tmp_path)
    [(dm, code)] = studio.ran
    assert dm == "Server" and '"round"' in code and '"Active"' in code and "150" in code
    assert report["counters"]["flareups"] == 2


async def test_no_round_start_by_default(run, tmp_path):
    run.spec = {}
    studio = LoopStudio()
    await run.playtest(studio, {"steps": []}, tmp_path)
    assert studio.ran == []


def test_flame_and_blame_seed_turns_it_on():
    spec = json.loads((Path(loop.__file__).parent / "seeds" / "flame-and-blame.json").read_text())
    assert spec["playtest"]["start_round"] is True
