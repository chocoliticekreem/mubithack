"""Headless by default, wired in: the build loop playtests headless and uses Studio only for one screenshot
pass (auto), keeps the old Studio playtest (always), never touches Studio (never); the autopilot measures
headless and keeps Studio for the final verify; `--studio auto|always|never` works on any command.
All with FakeLLM."""
from __future__ import annotations

import dataclasses
import io
import json
import shutil
from pathlib import Path

import pytest

from forge import autopilot as apm
from forge import cli
from forge.config import load_settings
from forge.llm import FakeLLM
from forge.loop import UI, new_game
from forge.memory import RunStore, slugify

pytestmark = pytest.mark.skipif(shutil.which("luau") is None or shutil.which("luau-compile") is None,
                                reason="luau CLI not installed")

GAME = """\
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Telemetry = require(RS:WaitForChild("ForgeTelemetry"))
local pad = Instance.new("Part")
pad.Name = "Pad"
pad.Anchored = true
pad.Color = Color3.fromRGB(255, 200, 0)
pad.Position = Vector3.new(0, 0.5, 0)
pad.Parent = workspace
Players.PlayerAdded:Connect(function() Telemetry.count("joined", 1) end)
task.spawn(function() while true do task.wait(1) Telemetry.count("ticks", 1) end end)
"""

SPEC = {"title": "Pad Game", "slug": "pad-game", "pitch": "stand on pads", "core_loop": "walk, touch",
        "modules": [{"path": "ServerScriptService/Game.server.luau", "purpose": "pads", "depends": []}],
        "acceptance": ["a pad exists"]}
CRITIQUE = {"score": 9, "summary": "fine", "done": True, "issues": []}


def luau(src: str) -> str:
    return f"```luau\n{src}\n```"


class FakeStudio:
    """Records what the loop asks of Studio."""

    def __init__(self, playing: bool = False):
        self.calls: list[str] = []
        self.playing = playing

    async def state(self):
        self.calls.append("state")
        return {"playing": self.playing}

    async def sync(self, root, port=None, **kw):
        self.calls.append("sync")
        return "synced"

    async def play(self, **kw):
        self.calls.append("play")

    async def stop(self):
        self.calls.append("stop")

    async def screenshot(self, out, camera=None, look_at=None):
        self.calls.append("screenshot")
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        Path(out).write_bytes(b"\x89PNG fake")
        return Path(out)

    async def probe_report(self):
        self.calls.append("probe_report")
        return {"uptime": 9, "errors": [], "warnings": [], "counters": {"studio": 1}, "players": 1}

    async def console(self):
        self.calls.append("console")
        return ""

    async def execute_luau(self, code, dm="Edit", timeout=None):
        self.calls.append(f"execute_luau:{dm}")
        return "{}"

    async def wait_ready(self, *a, **k):
        self.calls.append("wait_ready")
        return {}


def _settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


async def _new(tmp_path, monkeypatch, mode: str, studio: FakeStudio | None, use_studio: bool = True):
    from forge import loop

    monkeypatch.setenv("FORGE_STUDIO_MODE", mode)
    monkeypatch.setenv("FORGE_STUDIO", "Forge-agents-test")
    monkeypatch.setenv("FORGE_FUN_CRITIC", "0")
    monkeypatch.setenv("FORGE_PLAY_SECONDS", "0")
    monkeypatch.setattr(loop, "wait_for_game", _no_wait)

    async def fake_open(self, stack):
        return studio

    monkeypatch.setattr(loop.Run, "open_studio", fake_open)
    monkeypatch.setattr(loop, "SCREENSHOT_SETTLE", 0.0)
    settings = _settings(tmp_path)
    idea = "Pad game " + mode
    llm = FakeLLM({"designer": [json.dumps(SPEC)], "coder": [luau(GAME)], "critic": [json.dumps(CRITIQUE)],
                   "reflector": ["# lessons\n"]}, log_path=settings.runs_dir / slugify(idea) / "calls.jsonl")
    slug = await new_game(idea, iterations=1, use_studio=use_studio, settings=settings, llm=llm,
                          ui=UI(io.StringIO()), use_director=False)
    store = RunStore(settings, slug)
    return store, llm


async def _no_wait(studio, wait):
    return {"mode": "ready", "secs": 0.0}


@pytest.mark.asyncio
async def test_auto_playtests_headless_and_uses_studio_only_for_one_screenshot(tmp_path, monkeypatch):
    studio = FakeStudio()
    store, llm = await _new(tmp_path, monkeypatch, "auto", studio)
    report = store.load_iteration_json(1, "report.json")
    rec = store.load_iteration_json(1, "record.json")
    assert report["engine"] == "headless" and report["errors"] == []
    assert report["counters"]["joined"] == 2 and report["counters"]["ticks"] >= 25  # 2 players, 30 s simulated
    assert report["census"]["parts"] >= 1
    assert rec["engine"] == "headless" and rec["studio"] is False
    # Studio did nothing but the screenshot pass
    assert studio.calls == ["state", "sync", "play", "screenshot", "stop"]
    assert (store.iteration_dir(1) / "screenshot.png").exists()
    assert any(s["step"] == "screenshot" and s.get("engine") == "studio" for s in rec["steps"])
    # the critic judged the headless report
    critic = [c for c in llm.calls if c.role == "critic"][0]
    assert '"engine": "headless"' in critic.user or "headless" in critic.user


@pytest.mark.asyncio
async def test_auto_skips_the_screenshot_when_studio_is_busy_or_missing(tmp_path, monkeypatch):
    busy = FakeStudio(playing=True)
    store, _ = await _new(tmp_path, monkeypatch, "auto", busy)
    rec = store.load_iteration_json(1, "record.json")
    assert busy.calls == ["state"]
    assert any(s["step"] == "screenshot" and "busy" in s.get("skipped", "") for s in rec["steps"])
    store2, _ = await _new(tmp_path / "b", monkeypatch, "auto", None)
    rec2 = store2.load_iteration_json(1, "record.json")
    assert any(s["step"] == "screenshot" and "no free Studio" in s.get("skipped", "") for s in rec2["steps"])
    assert store2.load_iteration_json(1, "report.json")["engine"] == "headless"


@pytest.mark.asyncio
async def test_always_keeps_the_studio_playtest(tmp_path, monkeypatch):
    studio = FakeStudio()
    store, _ = await _new(tmp_path, monkeypatch, "always", studio)
    report = store.load_iteration_json(1, "report.json")
    assert report["counters"] == {"studio": 1}  # from the (fake) ForgeProbe, not the headless engine
    assert "probe_report" in studio.calls and "execute_luau:Server" in studio.calls  # census in Studio
    assert store.load_iteration_json(1, "record.json")["engine"] == "studio"


@pytest.mark.asyncio
async def test_never_and_no_studio_never_touch_studio(tmp_path, monkeypatch):
    studio = FakeStudio()
    store, _ = await _new(tmp_path, monkeypatch, "never", studio)
    assert studio.calls == []
    assert store.load_iteration_json(1, "report.json")["engine"] == "headless"
    studio2 = FakeStudio()
    store2, _ = await _new(tmp_path / "b", monkeypatch, "auto", studio2, use_studio=False)
    assert studio2.calls == [] and store2.load_iteration_json(1, "report.json")["engine"] == "headless"


def test_studio_flag_on_any_command(monkeypatch):
    monkeypatch.delenv("FORGE_STUDIO_MODE", raising=False)
    assert cli.take_studio_mode(["new", "idea", "--studio", "never", "-n", "2"]) == ["new", "idea", "-n", "2"]
    import os
    assert os.environ["FORGE_STUDIO_MODE"] == "never"
    assert cli.take_studio_mode(["run", "g", "--studio=always"]) == ["run", "g"]
    assert os.environ["FORGE_STUDIO_MODE"] == "always"
    # a place name is still a place name
    assert cli.take_studio_mode(["checks", "g", "--studio", "Forge-agents-3"]) == ["checks", "g", "--studio",
                                                                                  "Forge-agents-3"]


# ---------------------------------------------------------------- autopilot


def _ap_game(settings, slug="g"):
    run = settings.runs_dir / slug
    (run / "game" / "ServerScriptService").mkdir(parents=True, exist_ok=True)
    (run / "game" / "ReplicatedStorage").mkdir(parents=True, exist_ok=True)
    (run / "game" / "ServerScriptService" / "Game.server.luau").write_text(GAME)
    repo = Path(__file__).resolve().parent.parent
    (run / "game" / "ReplicatedStorage" / "ForgeTelemetry.luau").write_text(
        (repo / "game/ReplicatedStorage/ForgeTelemetry.luau").read_text())
    (run / "spec.json").write_text(json.dumps(SPEC))
    (run / "state.json").write_text(json.dumps({"iterations": []}))
    (run / "checks").mkdir()
    (run / "checks" / "pad.luau").write_text("-- check: a pad exists\nreturn { ok = workspace:FindFirstChild('Pad') ~= nil, detail = '' }\n")
    (run / "checks" / "fails.luau").write_text("-- check: fails\nreturn { ok = false, detail = 'no' }\n")
    return run


def test_autopilot_measures_headless_with_checks_and_no_studio_lease(tmp_path, monkeypatch):
    monkeypatch.setenv("FORGE_STUDIO_MODE", "auto")
    settings = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs", repo_root=tmp_path)
    _ap_game(settings)
    opts = apm.AutoOptions(use_studio=True, studios=["Forge-agents-99"], rounds=1, verify_reserve=0, qa_steps=0,
                           swarm_players=0, critic=False, plan_checks=0)
    ap = apm.Autopilot(settings, "g", opts, llm=FakeLLM({}), log=lambda s: None)

    def no_studio(*a, **k):
        raise AssertionError("a headless round must not lease Studio")

    monkeypatch.setattr(apm, "_studio_part", no_studio)
    m = apm.studio_measure(ap, 1, "baseline", "goal")
    assert m["engine"] == "headless" and m["studio"] is False
    assert (m["counters"] or {}).get("joined") == 1
    assert m["checks"]["passing"] == ["pad"] and m["checks"]["failing"] == ["fails"]


def test_autopilot_final_verify_is_the_only_studio_measurement(tmp_path, monkeypatch):
    monkeypatch.setenv("FORGE_STUDIO_MODE", "auto")
    settings = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs", repo_root=tmp_path)
    _ap_game(settings)
    seen = []

    def measurer(ap, r, tag, focus):
        seen.append(tag)
        return {"label": f"ap{r}{tag[:1]}", "studio": tag == "final", "errors": [], "counters": {}}

    opts = apm.AutoOptions(use_studio=True, studios=["Forge-agents-99"], rounds=1, verify_reserve=0)
    ap = apm.Autopilot(settings, "g", opts, llm=FakeLLM({}), measurer=measurer, log=lambda s: None)
    out = ap.final_verify(2)
    assert seen == ["final"] and out["studio"] is True
    assert ap.final_verify(2) == out  # once
    monkeypatch.setenv("FORGE_STUDIO_MODE", "never")
    ap2 = apm.Autopilot(settings, "g", dataclasses.replace(opts), llm=FakeLLM({}), measurer=measurer,
                        log=lambda s: None)
    (ap2.dir / "final.json").unlink(missing_ok=True)
    assert ap2.final_verify(2) is None and seen == ["final"]


def test_orchestrator_headless_jobs_take_no_studio_lease(tmp_path, monkeypatch):
    from forge.orchestrator import job_needs

    monkeypatch.setenv("FORGE_STUDIO_MODE", "auto")
    assert "studio" not in job_needs("playtest", {}, tmp_path, use_studio=True)
    assert "studio" not in job_needs("fix_cycle", {}, tmp_path, use_studio=True)
    assert "studio" in job_needs("checks", {}, tmp_path, use_studio=True)  # only checks that failed headless
    assert "studio" in job_needs("visual", {}, tmp_path, use_studio=True)
    monkeypatch.setenv("FORGE_STUDIO_MODE", "always")
    assert "studio" in job_needs("playtest", {}, tmp_path, use_studio=True)
    monkeypatch.setenv("FORGE_STUDIO_MODE", "never")
    assert all("studio" not in job_needs(k, {}, tmp_path, use_studio=True) for k in ("playtest", "checks", "visual"))
