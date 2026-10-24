import dataclasses
import json

from forge.config import load_settings
from forge.done import readiness, render


def _settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


BEATS = [{"t": 5, "beat": "claims a plot", "counter": "plot_claimed", "min": 1},
         {"t": 20, "beat": "buys the first dropper", "counter": "item_bought", "min": 1}]
CENSUS = {"source": "playtest", "parts": 120, "grey": 4, "sounds": 3, "screen_guis": 2}
FUN = {"score": 8.5, "scores": {"fun": 8, "juice": 9, "clarity": 8, "visuals": 9}, "census": CENSUS}


def _game(tmp_path, *, spec=None, state=None, scores=None, results=None, features=None, fun=None,
          report=None):
    run = tmp_path / "runs" / "g"
    (run / "improve").mkdir(parents=True)
    (run / "spec.json").write_text(json.dumps(spec or {}))
    (run / "state.json").write_text(json.dumps(state or {}))
    if fun is not None:
        (run / "fun").mkdir()
        (run / "fun" / "latest.json").write_text(json.dumps(fun))
    if report is not None:
        (run / "iterations" / "2").mkdir(parents=True)
        (run / "iterations" / "2" / "report.json").write_text(json.dumps(report))
    if scores is not None:
        (run / "improve" / "scores.json").write_text(json.dumps(scores))
    if results is not None:
        (run / "checks").mkdir()
        (run / "checks" / "results.json").write_text(json.dumps(results))
    if features is not None:
        (run / "features.jsonl").write_text("".join(json.dumps(f) + "\n" for f in features))


def _played(tmp_path, ok=True):
    """A game folder and a journey of exactly this code (forge/journey.py)."""
    from forge import journey

    game = tmp_path / "runs" / "g" / "game" / "ServerScriptService"
    game.mkdir(parents=True, exist_ok=True)
    (game / "Main.server.luau").write_text('print("hi")\n')
    steps = [{"step": "join", "ok": True, "detail": "Ana joined"},
             {"step": "prompts", "ok": ok, "detail": "1/1 prompts did something" if ok else
              "0/1 prompts did something: FAIL 'Try on costumes' was triggered, but nothing happened"}]
    journey.save(tmp_path / "runs" / "g", {"ok": ok, "engine": "headless", "steps": steps}, game.parent)


def test_ready_when_every_part_is_proved(tmp_path, monkeypatch):
    from forge import interactions

    # the audit itself is tested in test_interactions (it needs luau-ast); here: a clean audit counts
    monkeypatch.setattr(interactions, "audit", lambda game_dir: {"ok": True, "findings": [], "stats": {"objects": 2}})
    _game(tmp_path, state={"iterations": [{"score": 6}, {"score": 8.5}]}, scores=[{"cycle": 3, "open": 0}],
          results=[{"id": "a", "ok": True}, {"id": "b", "ok": True}],
          features=[{"request": "pass", "verified": False}, {"request": "pass", "verified": True}],
          spec={"first_60s": BEATS}, fun=FUN, report={"counters": {"plot_claimed": 1, "item_bought": 2}})
    _played(tmp_path)
    r = readiness(_settings(tmp_path), "g")
    assert r["ready"], r
    assert "READY" in render(r)
    parts = {p["part"]: p for p in r["parts"]}
    assert "2/2 beats" in parts["first60"]["detail"] and "4/120" in parts["visuals"]["detail"]
    assert parts["journey"]["detail"] == "2/2 steps (headless, journey 1): join, prompts"


def test_a_dead_interaction_or_a_failed_stale_or_missing_journey_blocks(tmp_path, monkeypatch):
    from forge import interactions

    _game(tmp_path)
    parts = {p["part"]: p for p in readiness(_settings(tmp_path), "g")["parts"]}
    assert not parts["journey"]["ok"] and parts["journey"]["detail"].startswith("no journey yet")
    _played(tmp_path, ok=False)
    monkeypatch.setattr(interactions, "audit", lambda game_dir: {"ok": False, "stats": {}, "findings": [
        {"kind": "prompt_no_handler", "severity": "high", "file": "ServerScriptService/Shop.luau", "line": 196,
         "object": 'ProximityPrompt "ChangingRoomPrompt"'}]})
    parts = {p["part"]: p for p in readiness(_settings(tmp_path), "g")["parts"]}
    assert not parts["interactions"]["ok"] and "Shop.luau:196" in parts["interactions"]["detail"]
    assert not parts["journey"]["ok"] and "prompts FAILED" in parts["journey"]["detail"]
    _played(tmp_path, ok=True)
    (tmp_path / "runs" / "g" / "game" / "ServerScriptService" / "Main.server.luau").write_text('print("changed")\n')
    parts = {p["part"]: p for p in readiness(_settings(tmp_path), "g")["parts"]}
    assert not parts["journey"]["ok"] and parts["journey"]["detail"].startswith("stale")
    monkeypatch.setattr(interactions, "audit", lambda game_dir: {"ok": None, "skipped": "luau-ast not on PATH",
                                                                 "findings": [], "stats": {}})
    parts = {p["part"]: p for p in readiness(_settings(tmp_path), "g")["parts"]}
    assert not parts["interactions"]["ok"] and parts["interactions"]["detail"].startswith("unknown")


def test_fun_bar_grey_hud_sounds_and_first60_each_block(tmp_path):
    grey = {**CENSUS, "grey": 90, "sounds": 0, "screen_guis": 0}
    _game(tmp_path, spec={"first_60s": BEATS}, fun={**FUN, "score": 7, "census": grey},
          report={"counters": {"plot_claimed": 1}})
    parts = {p["part"]: p for p in readiness(_settings(tmp_path), "g")["parts"]}
    assert not parts["fun"]["ok"] and "7/10" in parts["fun"]["detail"]
    assert not parts["visuals"]["ok"] and "90/120" in parts["visuals"]["detail"]
    assert not parts["hud"]["ok"] and not parts["sounds"]["ok"]
    assert not parts["first60"]["ok"] and "item_bought" in parts["first60"]["detail"]


def test_census_falls_back_to_report_then_source(tmp_path):
    _game(tmp_path, report={"census": CENSUS, "counters": {}})
    parts = {p["part"]: p for p in readiness(_settings(tmp_path), "g")["parts"]}
    assert parts["sounds"]["ok"] and "(playtest)" in parts["sounds"]["detail"]
    assert not parts["first60"]["ok"] and "director" in parts["first60"]["detail"]

    game = tmp_path / "runs" / "g" / "game" / "StarterPlayerScripts"
    game.mkdir(parents=True)
    (game / "Hud.client.luau").write_text('local g = Instance.new("ScreenGui")\nGameAssets.play("Coin")\n')
    (tmp_path / "runs" / "g" / "iterations" / "2" / "report.json").write_text("{}")
    parts = {p["part"]: p for p in readiness(_settings(tmp_path), "g")["parts"]}
    assert parts["hud"]["ok"] and parts["sounds"]["ok"] and "(static)" in parts["hud"]["detail"]


def test_first60_reads_fix_cycle_rounds_and_critic_for_counterless_beats(tmp_path):
    beats = BEATS + [{"t": 30, "beat": "sees the rebirth bar", "counter": "", "min": 1}]
    _game(tmp_path, spec={"first_60s": beats}, scores=[{"cycle": 1, "open": 0}],
          fun={**FUN, "first_60_seconds": [{"beat": "sees the rebirth bar", "ok": True}]})
    (tmp_path / "runs" / "g" / "improve" / "1.json").write_text(json.dumps(
        {"before": [{"counters": {"plot_claimed": 1}}, {"counters": {"item_bought": 1}}]}))
    parts = {p["part"]: p for p in readiness(_settings(tmp_path), "g")["parts"]}
    assert parts["first60"]["ok"], parts["first60"]


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
    assert parts["fun"]["ok"] and parts["first60"]["ok"]  # seeded human games: n/a
    assert "not ready yet" in render(r)


def test_dropped_checks_do_not_count(tmp_path):
    _game(tmp_path, results={"results": [{"id": "a", "ok": True, "verdict": "pass"},
                                         {"id": "broken-test", "ok": False, "verdict": "dropped"}]})
    parts = {p["part"]: p for p in readiness(_settings(tmp_path), "g")["parts"]}
    assert parts["checks"]["ok"] and parts["checks"]["detail"] == "1/1 pass"


def test_features_from_spec_count_when_no_log(tmp_path):
    _game(tmp_path, spec={"features": [{"request": "battle pass"}]}, scores=[{"cycle": 1, "open": 0}])
    parts = {p["part"]: p for p in readiness(_settings(tmp_path), "g")["parts"]}
    assert not parts["features"]["ok"] and "battle pass" in parts["features"]["detail"]
