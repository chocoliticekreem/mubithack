import dataclasses
import json

from forge.config import load_settings
from forge.done import readiness, render


def _settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


def _game(tmp_path, *, spec=None, state=None, scores=None, results=None, features=None):
    run = tmp_path / "runs" / "g"
    (run / "improve").mkdir(parents=True)
    (run / "spec.json").write_text(json.dumps(spec or {}))
    (run / "state.json").write_text(json.dumps(state or {}))
    if scores is not None:
        (run / "improve" / "scores.json").write_text(json.dumps(scores))
    if results is not None:
        (run / "checks").mkdir()
        (run / "checks" / "results.json").write_text(json.dumps(results))
    if features is not None:
        (run / "features.jsonl").write_text("".join(json.dumps(f) + "\n" for f in features))


def test_ready_when_every_part_is_proved(tmp_path):
    _game(tmp_path, state={"iterations": [{"score": 6}, {"score": 8.5}]}, scores=[{"cycle": 3, "open": 0}],
          results=[{"id": "a", "ok": True}, {"id": "b", "ok": True}],
          features=[{"request": "pass", "verified": False}, {"request": "pass", "verified": True}])
    r = readiness(_settings(tmp_path), "g")
    assert r["ready"], r
    assert "READY" in render(r)


def test_unknown_is_never_ready(tmp_path):
    _game(tmp_path)
    r = readiness(_settings(tmp_path), "g")
    parts = {p["part"]: p for p in r["parts"]}
    assert not r["ready"]
    assert not parts["checks"]["ok"] and not parts["open"]["ok"] and not parts["critic"]["ok"]
    assert parts["features"]["ok"]


def test_failures_are_named(tmp_path):
    _game(tmp_path, spec={"base_files": ["x.luau"]}, scores=[{"cycle": 1, "open": 2}],
          results={"results": [{"id": "claim-works", "ok": False}, {"id": "b", "ok": True}]},
          features=[{"request": "game passes, like a battle pass", "verified": False}])
    r = readiness(_settings(tmp_path), "g")
    parts = {p["part"]: p for p in r["parts"]}
    assert "claim-works" in parts["checks"]["detail"] and "1/2" in parts["checks"]["detail"]
    assert "not verified" in parts["features"]["detail"] and "2 high/medium open" in parts["open"]["detail"]
    assert parts["critic"]["ok"] and "n/a" in parts["critic"]["detail"]
    assert "not ready yet" in render(r)


def test_features_from_spec_count_when_no_log(tmp_path):
    _game(tmp_path, spec={"features": [{"request": "battle pass"}]}, scores=[{"cycle": 1, "open": 0}])
    parts = {p["part"]: p for p in readiness(_settings(tmp_path), "g")["parts"]}
    assert not parts["features"]["ok"] and "battle pass" in parts["features"]["detail"]
