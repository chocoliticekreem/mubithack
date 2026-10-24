"""`forge orchestrate`: gap-find -> jobs -> workers (leases) -> verify -> re-score, with FakeLLM and a fake runner."""

import dataclasses
import json
import threading

import pytest

from forge import orchestrator
from forge.broker import Broker, JobQueue, StudioSlots
from forge.config import load_settings
from forge.llm import FakeLLM
from forge.orchestrator import JobRun, Options, Orchestrator, job_argv


@pytest.fixture(autouse=True)
def fast_poll(monkeypatch):
    monkeypatch.setattr(orchestrator, "POLL_S", 0.02)


def _fake_checks(monkeypatch, headless_pass: bool):
    """One saved check; checks.triage says it passed headless, or that it still needs Studio."""
    import forge.checks as chk
    import forge.scenarios as sc

    c = chk.Check(id="cash-rises", title="cash rises", covers="acceptance: cash rises", body="return {ok=true}")
    monkeypatch.setattr(chk, "load_checks", lambda run_dir: [c])
    monkeypatch.setattr(chk, "triage", lambda game_dir, checks: (
        ([{"id": "cash-rises", "ok": True, "detail": "headless"}], []) if headless_pass else ([], [c])))
    saved = []

    def save(run_dir, results):
        saved.append(results)
        (run_dir / "checks").mkdir(parents=True, exist_ok=True)
        (run_dir / "checks" / "results.json").write_text(json.dumps(results))

    monkeypatch.setattr(sc, "save_results", save)
    return saved


def _settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


def _game(tmp_path, critic=6):
    run = tmp_path / "runs" / "g"
    (run / "game" / "ServerScriptService").mkdir(parents=True)
    (run / "game" / "ServerScriptService" / "Tycoon.luau").write_text("local M = {}\n-- dropper conveyor\nreturn M\n")
    (run / "spec.json").write_text(json.dumps({"title": "Tiny Tycoon", "pitch": "a tycoon", "modules": [],
                                               "acceptance": ["cash rises"]}))
    (run / "state.json").write_text(json.dumps({"iterations": [{"n": 1, "score": critic}]}))
    return run


def _gaps(*items):
    return json.dumps({"summary": "thin", "score": 4, "gaps": [
        {"title": t, "kind": "missing", "impact": imp, "confidence": 1, "evidence": ["genre:saving"],
         "job": {"kind": kind, "request": f"do {t}", **({"path": path} if path else {})}}
        for t, imp, kind, path in items]})


class FakeRunner:
    """Pretends to be the forge CLI: a playtest writes a critic score; checks/fix make `forge done` green."""

    def __init__(self, run, scores):
        self.run = run
        self.scores = list(scores)
        self.calls: list[tuple] = []
        self.active = 0
        self.peak_studio = 0
        self.lock = threading.Lock()

    def __call__(self, job, env, should_stop, beat):
        with self.lock:
            self.calls.append((job["kind"], job["title"], dict(env)))
            if "FORGE_STUDIO" in env:
                self.active += 1
                self.peak_studio = max(self.peak_studio, self.active)
        beat()
        try:
            if job["kind"] == "playtest":
                state = json.loads((self.run / "state.json").read_text())
                n = len(state["iterations"]) + 1
                state["iterations"].append({"n": n, "score": self.scores.pop(0) if self.scores else 6})
                (self.run / "state.json").write_text(json.dumps(state))
            if job["kind"] == "checks":
                (self.run / "checks").mkdir(exist_ok=True)
                (self.run / "checks" / "results.json").write_text(json.dumps([{"id": "a", "ok": True}]))
            if job["kind"] == "fix_cycle":
                (self.run / "improve").mkdir(exist_ok=True)
                (self.run / "improve" / "scores.json").write_text(json.dumps([{"cycle": 1, "open": 0}]))
            # a few Mubit calls per job, as the real commands would log
            with (self.run / "calls.jsonl").open("a") as f:
                f.write(json.dumps({"role": "coder"}) + "\n")
            return JobRun(True, {"exit": "0"})
        finally:
            with self.lock:
                if "FORGE_STUDIO" in env:
                    self.active -= 1


class FakeKeeper:
    opened: set = set()

    def prepare(self, place):
        return f"id-{place}"

    def release(self, place):
        pass


def _orch(tmp_path, llm, runner, **opts):
    s = _settings(tmp_path)
    slots = StudioSlots(tmp_path / "slots", running=lambda n: True)
    broker = Broker(tmp_path / "broker", {"llm": ["llm-1", "llm-2", "llm-3", "llm-4"],
                                         "game": ["game:g#1", "game:g#2", "game:g#3"], "sync": ["34901"],
                                         "studio": ["Forge-agents-30"]}, studio_slots=slots)
    o = Options(goal="10x better tycoon", workers=3, studios=["Forge-agents-30"], max_calls=None, minutes=5,
                **opts)
    return Orchestrator(s, "g", o, llm=llm, runner=runner, broker=broker, keeper=FakeKeeper(), slots=slots)


def test_round_runs_gaps_then_builds_then_verifies_until_target(tmp_path, monkeypatch):
    import forge.done

    run = _game(tmp_path)
    real = forge.done.readiness

    def readiness(settings, slug):  # the bar's own parts are tested in test_done; here: checks + fix cycle ran
        r = real(settings, slug)
        ok = (run / "checks" / "results.json").exists() and (run / "improve" / "scores.json").exists()
        return {**r, "ready": ok}

    monkeypatch.setattr(forge.done, "readiness", readiness)
    _fake_checks(monkeypatch, headless_pass=False)
    llm = FakeLLM({"gap_finder": [_gaps(("Saving", 9, "feature", None), ("Belt sticks", 8, "fix",
                                                                         "ServerScriptService/Tycoon.luau"),
                                        ("Sparkles", 6, "visual", None), ("Tiny", 1, "feature", None))]})
    runner = FakeRunner(run, scores=[8.5])
    res = _orch(tmp_path, llm, runner).run()
    kinds = [c[0] for c in runner.calls]
    # builds by gap rank (Tiny is below the bar), then the Studio verification jobs
    assert kinds[:3] == ["feature", "fix", "visual"]
    assert kinds[3:] == ["playtest", "checks", "fix_cycle"]
    assert res["after"]["target_met"] and res["stop_reason"].startswith("target met")
    assert res["before"]["critic"] == 6 and res["after"]["critic"] == 8.5
    assert runner.peak_studio == 1  # one Studio window: never two Studio jobs at once
    studio_env = next(c[2] for c in runner.calls if c[0] == "playtest")
    assert studio_env == {"FORGE_SYNC_PORT": "34901", "FORGE_STUDIO": "id-Forge-agents-30"}
    assert "FORGE_STUDIO" not in next(c[2] for c in runner.calls if c[0] == "fix")  # LLM-only job
    rounds = json.loads((run / "orchestrator" / "rounds.json").read_text())
    assert rounds[0]["gaps"][0]["id"] == "saving" and all(j["status"] == "done" for j in rounds[0]["jobs"])
    status = json.loads((run / "orchestrator" / "status.json").read_text())
    assert status["state"] == "finished" and status["after"]["ready"]
    timings = json.loads((run / "orchestrator" / "timings.json").read_text())  # forge.timings format
    assert [st["name"] for st in timings["stages"]] == ["resume", "round 1"]
    assert {c["role"] for c in timings["calls"]} >= {"gap_finder", "coder", "fixer", "critic", "tester", "auditor"}
    assert all(c["end"] is not None and c["lane"] for c in timings["calls"]) and not timings["running"]


def test_loops_rounds_and_feeds_done_jobs_back(tmp_path):
    run = _game(tmp_path)
    llm = FakeLLM({"gap_finder": [_gaps(("Saving", 9, "feature", None)), _gaps(("Rebirth", 7, "feature", None))]})
    runner = FakeRunner(run, scores=[6.5, 7.0])
    res = _orch(tmp_path, llm, runner, rounds=2, checks=False, fix_cycle=False).run()
    assert [r["round"] for r in res["rounds"]] == [1, 2]
    assert "feature: Saving" in llm.calls[1].user  # round 2's gap finder sees what round 1 did
    assert res["stop_reason"] == "ran 2 round(s)"
    assert [c[0] for c in runner.calls] == ["feature", "playtest", "feature", "playtest"]


def test_call_budget_stops_the_loop(tmp_path):
    run = _game(tmp_path)
    llm = FakeLLM({"gap_finder": [_gaps(("A", 9, "feature", None), ("B", 8, "feature", None),
                                        ("C", 7, "feature", None))]})
    o = _orch(tmp_path, llm, FakeRunner(run, scores=[6]), rounds=3)
    o.opts.max_calls = 1
    o.opts.workers = 1
    res = o.run()
    assert res["stop_reason"].startswith("call budget spent")
    q = JobQueue(run / "orchestrator")
    assert any(j["status"] == "cancelled" for j in q.jobs())
    assert len(res["rounds"]) == 1


def test_resume_recovers_a_crashed_job_first(tmp_path):
    run = _game(tmp_path)
    q = JobQueue(run / "orchestrator", alive=lambda pid: pid != 999999)
    j = q.add("feature", "half-built feature", priority=5, args={"request": "x"}, needs=["llm", "game"])
    q.claim("old-worker", pid=999999)  # that orchestrator crashed mid-job
    llm = FakeLLM({"gap_finder": [_gaps()]})
    runner = FakeRunner(run, scores=[])
    res = _orch(tmp_path, llm, runner, rounds=1).run()
    assert runner.calls[0][:2] == ("feature", "half-built feature")
    assert JobQueue(run / "orchestrator").get(j["id"])["status"] == "done"
    assert res["stop_reason"] == "no gaps above the bar"


def test_job_commands():
    assert job_argv({"kind": "fix", "args": {"request": "r", "path": "A.luau"}}, "g", use_studio=True) == \
        ["correct", "g", "A.luau", "r", "--no-studio"]
    assert job_argv({"kind": "feature", "args": {"request": "r"}}, "g", use_studio=True) == \
        ["feature", "g", "r", "--iterations", "1", "--polish", "1"]
    assert job_argv({"kind": "feature", "args": {"request": "r"}}, "g", use_studio=False)[-1] == "--no-studio"
    assert job_argv({"kind": "fix", "args": {"request": "r"}}, "g", use_studio=True)[:2] == ["feature", "g"]
    assert job_argv({"kind": "playtest", "args": {}}, "g", use_studio=False) == ["run", "g", "--iterations", "1",
                                                                                "--no-studio"]
    assert job_argv({"kind": "gaps", "args": {}}, "g", use_studio=True) is None


def test_mcp_tools_start_the_orchestrator(tmp_path, monkeypatch):
    import forge.mcp_server as fm

    s = _settings(tmp_path)
    monkeypatch.setattr(fm, "_settings", lambda: s)
    seen = []
    monkeypatch.setattr(fm, "start_job", lambda kind, args, env=None, argv=None:
                        seen.append((kind, args)) or {"id": f"{kind}-1"})
    _game(tmp_path)
    assert "orchestrate-1" in fm.orchestrate("g", goal="10x", max_calls=50, studio="Forge-agents-30")
    assert seen[0] == ("orchestrate", ["orchestrate", "g", "--goal", "10x", "--max-calls", "50", "--minutes", "120",
                                       "--rounds", "3", "--workers", "4", "--per-round", "4",
                                       "--studio", "Forge-agents-30"])
    fm.gaps("g", correct="saving matters less", reject=["saving"])
    assert seen[1][1] == ["gaps", "g", "--goal", "", "--correct", "saving matters less", "--reject", "saving"]
    assert "No gap list" in fm.gaps("g")
    assert "never run" in fm.orchestrator("g")


class SlowFixRunner(FakeRunner):
    """Fix jobs take a moment, so overlapping ones are visible; records which files were being fixed at once."""

    def __init__(self, run):
        super().__init__(run, scores=[])
        self.editing: list = []
        self.peak_fixes = 0
        self.same_file_overlap = False

    def __call__(self, job, env, should_stop, beat):
        import time

        path = (job.get("args") or {}).get("path")
        if job["kind"] == "fix":
            with self.lock:
                self.same_file_overlap |= path in self.editing
                self.editing.append(path)
                self.peak_fixes = max(self.peak_fixes, len(self.editing))
            time.sleep(0.3)
            with self.lock:
                self.editing.remove(path)
        return super().__call__(job, env, should_stop, beat)


def test_fixes_to_different_files_run_in_parallel_and_same_file_never(tmp_path):
    run = _game(tmp_path)
    llm = FakeLLM({"gap_finder": [_gaps(("A broken", 9, "fix", "A.luau"), ("B broken", 8, "fix", "B.luau"),
                                        ("C broken", 7, "fix", "C.luau"), ("A again", 6, "fix", "A.luau"))]})
    for name in ("A", "B", "C"):
        (run / "game" / f"{name}.luau").write_text("return {}\n")
    runner = SlowFixRunner(run)
    _orch(tmp_path, llm, runner, rounds=1, per_round=4, checks=False, fix_cycle=False).run()
    assert runner.peak_fixes == 3  # A, B, C at once (3 workers); the second A fix waits for the first
    assert not runner.same_file_overlap
    kinds = [c[0] for c in runner.calls]
    assert kinds.count("fix") == 4 and kinds[-1] == "playtest"  # the whole-game writer waits for every fix


def test_checks_that_pass_headless_never_take_a_studio_lease(tmp_path, monkeypatch):
    run = _game(tmp_path)
    saved = _fake_checks(monkeypatch, headless_pass=True)
    llm = FakeLLM({"gap_finder": [_gaps(("Saving", 9, "fix", "ServerScriptService/Tycoon.luau"))]})
    runner = FakeRunner(run, scores=[6])
    _orch(tmp_path, llm, runner, rounds=1, fix_cycle=False).run()
    assert "checks" not in [c[0] for c in runner.calls]  # the Studio checks job was marked done, not run
    assert saved and saved[0][0]["source"] == "headless"
    q = {j["kind"]: j for j in JobQueue(run / "orchestrator").jobs()}
    assert q["checks"]["status"] == "done" and "headless" in q["checks"]["result"]["skipped"]
    assert q["checks_offline"]["result"]["headless_passed"] == 1
