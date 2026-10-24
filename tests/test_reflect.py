"""`forge reflect`: the reflection log after a build, a fix cycle or an orchestrate round. Records are written
by hand in a temp runs dir; no Mubit call is made unless a test passes a FakeLLM."""

from __future__ import annotations

import argparse
import dataclasses
import json
from datetime import datetime, timezone

import pytest

from forge import cli
from forge import reflect as fr
from forge.config import load_settings
from forge.llm import FakeLLM

T0 = datetime(2026, 10, 24, 3, 0, tzinfo=timezone.utc).timestamp()


def iso(t: float) -> str:
    return datetime.fromtimestamp(t, timezone.utc).isoformat(timespec="seconds")


@pytest.fixture
def settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


class Clock:
    def __init__(self, t: float):
        self.t = t

    def time(self) -> float:
        return self.t


@pytest.fixture
def clock(monkeypatch):
    c = Clock(T0 + 3600)
    monkeypatch.setattr(fr, "time", c)
    return c


def _jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")


def _call(role, t, tin=1000, tout=100, ms=2000, **kw):
    return {"ts": iso(t), "role": role, "session_id": "improve-g-1", "request_id": f"mreq_{role}_{t}",
            "latency_ms": ms, "input_tokens": tin, "output_tokens": tout, **kw}


def _trace(run, role, t, user):
    p = run / "improve" / "traces" / f"{int(t)}-{role}.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps({"ts": iso(t), "role": role, "request_id": "r", "user": user}))


GUARD_SETUP = {"id": "07-round", "ok": False, "error": "startRound failed: setup: round did not start"}


def _fix_cycle_run(settings):
    run = settings.runs_dir / "g"
    (run / "improve").mkdir(parents=True)
    (run / "state.json").write_text(json.dumps({"iterations": [
        {"n": 1, "score": 6, "ended": iso(T0 + 10)},
        {"n": 2, "score": 4, "ended": iso(T0 + 20), "rolled_back_to": "v1"}], "corrections": []}))
    calls = [_call("investigator", T0 + 100 + i, tin=11_000) for i in range(8)]
    calls += [_call("patcher", T0 + 200), _call("patcher", T0 + 210), _call("verifier", T0 + 220, ms=500),
              _call("player", T0 + 50, tin=4000), _call("coder", T0 + 60, error="RateLimitError: 429")]
    _jsonl(run / "improve" / "calls.jsonl", calls)
    _jsonl(run / "improve" / "skipped.jsonl", [
        {"ts": iso(T0 + 101), "kind": "repair_avoided", "how": "tool_call", "role": "investigator", "input_tokens": 11_000},
        {"ts": iso(T0 + 61), "kind": "cache_hit", "role": "coder", "input_tokens": 3000}])
    for i in range(3):
        _trace(run, "investigator", T0 + 100 + i, "## Anomaly\n...\n## Your previous reply could not be used\nError: x")
    _trace(run, "patcher", T0 + 210, "## Problem\n...\n## Your previous fix was rejected\nwhy")
    cycle = {"cycle": 1, "ts": iso(T0 + 300), "session_id": "improve-g-1", "repro": True, "open": 2,
             "code_kept": 1, "checks": {"start": [GUARD_SETUP, {"id": "01-ok", "ok": True}], "proven": ["c1"],
                                        "kept": ["c1"], "end": []},
             "code_fixes": [
                 {"anomaly": "Hose never cools", "path": "ServerScriptService/Hose.luau", "status": "kept",
                  "investigation": {"steps": [{}] * 2, "conclusion": {"file": "x"}},
                  "repro": {"attempts": [{"status": "proven"}]},
                  "attempts": [{"status": "fixed", "checks": {"repro": {"ok": True}, "guards": []},
                                "verdict": {"verdict": "fixed"}}]},
                 {"anomaly": "Battle pass remotes missing", "path": "ServerScriptService/Pass.luau",
                  "status": "rolled_back", "investigation": {"steps": [{}] * 7, "conclusion": {"file": "y"}},
                  "attempts": [{"status": "check_regression", "error": "Your fix broke checks that passed before: 07",
                                "checks": {"repro": {"ok": True}, "guards": [GUARD_SETUP]}}] * 2},
                 {"anomaly": "No UI to pick a call", "path": None, "status": "unproven",
                  "investigation": {"steps": [{}] * 7, "conclusion": {"file": None}},
                  "repro": {"attempts": [{"status": "passed"}]}},
             ]}
    (run / "improve" / "1.json").write_text(json.dumps(cycle))
    _jsonl(run / "features.jsonl", [{"ts": iso(T0 + 400), "request": "battle pass", "verified": True, "version": "v3"}])
    return run


def test_reflection_counts_calls_skips_fixes_and_failures(settings, clock):
    run = _fix_cycle_run(settings)
    rec = fr.reflect(settings, "g", label="forge fix", log=lambda _: None)
    assert rec["n"] == 1 and rec["since"] is None
    s = rec["summary"]
    assert s["calls"] == 13 and s["errors"] == 1
    inv = s["by_role"]["investigator"]
    assert inv["calls"] == 8 and inv["input_tokens"] == 88_000 and inv["repairs"] == 3 and inv["over_run_size"] == 8
    assert inv["repairs_avoided"] == 1 and s["by_role"]["coder"]["cache_hits"] == 1
    assert s["by_role"]["patcher"]["retries"] == 1
    assert s["by_stage"]["investigate"]["calls"] == 8 and s["by_stage"]["fix"]["calls"] == 2
    assert (s["kept"], s["rolled_back"], s["unproven"]) == (1, 1, 1)
    assert s["failures"] == {"check_regression": 2, "unproven": 1, "reproducer_passed": 1, "setup_error": 1,
                             "mubit_rate_limit": 1}
    ids = {w["id"] for w in rec["weaknesses"]}
    assert {"json_repairs", "oversized_calls", "investigated_then_unproven", "guard_setup_rejections",
            "retry_repeated_failure", "check_setup_errors", "score_rollbacks", "mubit_errors",
            "investigator_step_cap"} <= ids
    assert "cycle_kept_nothing" not in ids  # it kept one
    assert any("fix cycle 1" in a and "kept 1" in a for a in rec["attempted"])
    assert any(a.startswith("feature \"battle pass\": verified") for a in rec["attempted"])
    md = (run / "reflection" / "1.md").read_text()
    for part in ("## What was attempted", "## Kept and rolled back", "## Mubit calls", "## Time by stage",
                 "## Failures by cause", "## System weaknesses", "guard check failed in setup"):
        assert part in md
    [line] = (run / "reflection" / "reflection.jsonl").read_text().splitlines()
    assert json.loads(line)["n"] == 1


def test_next_reflection_covers_only_what_happened_since(settings, clock):
    run = _fix_cycle_run(settings)
    first = fr.reflect(settings, "g", log=lambda _: None)
    clock.t += 60
    assert fr.reflect(settings, "g", log=lambda _: None) is None  # nothing new: no empty reflection
    assert not (run / "reflection" / "2.md").exists()
    _jsonl(run / "calls.jsonl", [_call("critic", first["until"] + 10, tin=7000)])
    clock.t += 60
    second = fr.reflect(settings, "g", log=lambda _: None)
    assert second["n"] == 2 and second["since"] == iso(first["until"])
    assert second["summary"]["calls"] == 1 and list(second["summary"]["by_role"]) == ["critic"]
    assert second["summary"]["fixes"] == []  # the fix cycle belongs to reflection 1
    # an explicit window (an orchestrate round) may overlap earlier reflections
    third = fr.reflect(settings, "g", since=T0, log=lambda _: None)
    assert third["n"] == 3 and third["summary"]["calls"] == 14


def test_reflect_all_sums_every_game(settings, clock):
    _fix_cycle_run(settings)
    other = settings.runs_dir / "h"
    _jsonl(other / "calls.jsonl", [_call("coder", T0 + 5), _call("coder", T0 + 6)])
    (settings.runs_dir / "bench").mkdir()
    _jsonl(settings.runs_dir / "bench" / "x" / "calls.jsonl", [_call("coder", T0)])
    out, text = fr.reflect_all(settings)
    assert [g["slug"] for g in out["games"]] == ["g", "h"]
    assert out["total"]["calls"] == 15 and out["total"]["kept"] == 1
    top = {w["id"]: w for w in out["weaknesses"]}
    assert top["json_repairs"]["games"] == ["g"]
    assert (settings.runs_dir / "reflection.md").read_text().strip() == text.strip()


def test_llm_reflection_goes_to_the_reflector_task(settings, clock):
    _fix_cycle_run(settings)
    (settings.runs_dir / "lessons.md").write_text("# Lessons\n- old\n")
    llm = FakeLLM({"reflector": ["# Lessons\n## Fixing and debugging\n- A guard that fails in setup proves nothing.\n"]})
    rec = fr.reflect(settings, "g", llm=llm, log=lambda _: None)
    assert rec["llm"] == {"ok": True, "lessons_updated": True, "request_id": "fake-1"}
    [call] = llm.calls
    assert call.role == "reflector" and call.session_id == "reflect-g-1"
    assert "Battle pass remotes missing" in call.user and "guard check failed in setup" in call.user
    assert "fails in setup proves nothing" in (settings.runs_dir / "lessons.md").read_text()


def test_hook_never_fails_the_command(settings, monkeypatch):
    monkeypatch.setattr(fr, "reflect", lambda *a, **k: (_ for _ in ()).throw(OSError("disk full")))
    seen = []
    assert fr.maybe_reflect(settings, "g", log=seen.append) is None
    assert "no reflection (OSError: disk full)" in seen[0]


def test_fix_and_new_reflect_at_the_end(settings, monkeypatch):
    calls = []
    monkeypatch.setattr(fr, "maybe_reflect", lambda s, slug, **k: calls.append((slug, k.get("label"))))
    monkeypatch.setattr(cli, "load_settings", lambda: settings)

    async def broken(*a, **k):
        raise RuntimeError("Studio dropped")

    monkeypatch.setattr(cli, "_improve", broken)
    with pytest.raises(RuntimeError):
        cli.cmd_fix(argparse.Namespace(slug="g", cycles=2))
    assert calls == [("g", "forge fix (--cycles 2)")]  # even a stopped fix run is reflected on

    import forge.loop

    async def built(*a, **k):
        return "new-game"

    monkeypatch.setattr(forge.loop, "new_game", built)
    cli.cmd_new(argparse.Namespace(idea="x", iterations=1, no_studio=True, no_director=True, jobs=None))
    assert calls[-1] == ("new-game", "forge new")


def test_reflect_cli(settings, monkeypatch, capsys, clock):
    _fix_cycle_run(settings)
    monkeypatch.setattr(cli, "load_settings", lambda: settings)
    assert cli.main(["reflect", "g"]) == 0
    assert "# Reflection 1: g (forge reflect)" in capsys.readouterr().out
    assert cli.main(["reflect", "--all"]) == 0
    assert "# Forge reflection: every game" in capsys.readouterr().out
    assert cli.main(["reflect"]) == 2
    assert cli.main(["reflect", "nope"]) == 1


def test_orchestrate_round_writes_a_reflection(tmp_path, monkeypatch):
    import time

    from forge import orchestrator
    from test_orchestrator import FakeRunner, _game, _gaps, _orch

    class StampedRunner(FakeRunner):  # each job logs a Mubit call the way the real commands do
        def __call__(self, job, env, should_stop, beat):
            out = super().__call__(job, env, should_stop, beat)
            _jsonl(self.run / "calls.jsonl", [_call("coder", time.time())])
            return out

    monkeypatch.setattr(orchestrator, "POLL_S", 0.02)
    run = _game(tmp_path)
    _jsonl(run / "calls.jsonl", [_call("coder", time.time() - 3600)])  # an earlier session: not this round
    llm = FakeLLM({"gap_finder": [_gaps(("Saving", 9, "feature", None))]})
    _orch(tmp_path, llm, StampedRunner(run, scores=[6.5]), rounds=1, checks=False, fix_cycle=False).run()
    [rec] = fr.history(dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs"), "g")
    assert rec["label"] == "orchestrate round 1" and (run / "reflection" / "1.md").exists()
    assert rec["summary"]["by_role"]["coder"]["calls"] == 2  # the feature and playtest jobs
