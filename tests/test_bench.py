"""forge bench: the cheap mode (FakeLLM, no Studio) runs the real loop end to end and records the numbers."""

from __future__ import annotations

import dataclasses
import json
import shutil

import pytest

from forge import bench, loop
from forge.config import load_settings

needs_luau = pytest.mark.skipif(not shutil.which("luau-compile"), reason="luau-compile not on PATH")


@pytest.fixture
def settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


def test_suite_has_five_fixed_ideas():
    assert bench.SUITE_IDS == ["tycoon", "obby", "minigame", "simulator", "defence"]
    assert all(len(s["idea"]) > 40 for s in bench.SUITE)


@needs_luau
async def test_cheap_bench_records_every_metric(settings, tmp_path):
    orig = {n: getattr(loop.Run, n) for n in ("build_all", "iterate", "compile_fix", "playtest")}
    result, path = await bench.run_bench(["tycoon", "obby"], iterations=2, fake=True, settings=settings,
                                         label="test")

    # the stage wrappers are removed afterwards
    assert {n: getattr(loop.Run, n) for n in orig} == orig

    assert path.parent == settings.runs_dir / "bench"
    saved = json.loads(path.read_text())
    assert saved["mode"] == "fake" and saved["label"] == "test"
    assert [i["id"] for i in saved["ideas"]] == ["tycoon", "obby"]
    assert path.with_suffix(".md").read_text().startswith("# forge bench")

    for i in saved["ideas"]:
        assert i["ok"], i["error"]
        assert set(i["stages"]) >= {"design", "build", "iterate", "compile_fix"}
        assert i["llm"]["calls"] > 0 and i["llm"]["request_ids"][0].startswith("fake-")
        assert i["llm"]["by_role"]["designer"] == 1
        # fake coder writes a broken server script: 2 of 3 modules compile first try, the fixer repairs it
        assert i["compile_first"]["modules"] == 3
        assert i["compile_first"]["failing"] == ["ServerScriptService/Game.server.luau"]
        assert i["compile_first"]["pass_rate"] == pytest.approx(0.667)
        assert i["fixes"]["compile"] == 1 and i["compile_errors_left"] == 0
        assert i["iterations"] == 2 and i["critic"]["final"] == 6
        assert i["done"]["of"] == 4 and i["done"]["ready"] is False
        assert i["corrections"] == 0
        assert i["acceptance"]["criteria"] == 2
        # each idea lives in its own runs dir with fresh starter lessons
        assert (settings.runs_dir / "bench" / saved["stamp"] / i["id"] / i["slug"] / "spec.json").exists()

    t = saved["totals"]
    assert t["built"] == 2 and t["fixes"] == 2 and t["first_try_pass_rate"] == pytest.approx(0.667)


def test_compare_reports_deltas_with_direction():
    def res(stamp, wall, rate, critic):
        idea = {"id": "tycoon", "ok": True, "wall_s": wall, "stages": {"build": wall / 2},
                "llm": {"calls": 10, "input_tokens": 100, "output_tokens": 50},
                "compile_first": {"pass_rate": rate}, "fixes": {"total": 2}, "compile_errors_left": 0,
                "critic": {"final": critic}, "fun": {"final": None}, "acceptance": {"passed": 0, "checks": 0},
                "done": {"ok": 1, "of": 4}, "corrections": 0}
        return {"stamp": stamp, "mode": "real", "git": {"sha": stamp}, "ideas": [idea]}

    out = bench.compare(res("a", 100.0, 0.5, 6), res("b", 60.0, 1.0, 7))
    assert "| wall s | 100.0 | 60.0 | -40.0 | better |" in out
    assert "| 1st-try compile | 0.50 | 1.00 | +0.50 | better |" in out
    assert "| critic final | 6 | 7 | +1 | better |" in out
    assert "totals over tycoon" in out


def test_cli_compare_and_list(settings, capsys, monkeypatch):
    d = settings.runs_dir / "bench"
    d.mkdir(parents=True)
    for st, wall in (("20260101T000000Z", 50.0), ("20260102T000000Z", 40.0)):
        (d / f"{st}.json").write_text(json.dumps({
            "stamp": st, "mode": "fake", "git": {}, "totals": {"wall_s": wall},
            "ideas": [{"id": "obby", "wall_s": wall}]}))
    monkeypatch.setattr(bench, "load_settings", lambda: settings)
    from forge.cli import main

    assert main(["bench", "--compare", "prev", "latest"]) == 0
    assert "| wall s | 50.0 | 40.0 | -10.0 | better |" in capsys.readouterr().out
    assert main(["bench", "--list"]) == 0
    assert "20260102T000000Z" in capsys.readouterr().out
