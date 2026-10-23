"""forge dashboard: what it collects from runs/, and the HTTP server."""

from __future__ import annotations

import dataclasses
import json
import threading
import time
import urllib.request

import pytest

from forge import dashboard as db
from forge.config import load_settings
from forge.memory import RunStore
from forge.versions import GameVersions


@pytest.fixture
def settings(tmp_path):
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")
    runs = s.runs_dir
    (runs / "jobs").mkdir(parents=True)
    (runs / "jobs" / "fix-1.log").write_text("[auditor] 2 anomalies\nWARN studio_mcp noise\n__exit 0\n")
    (runs / "jobs" / "fix-1.json").write_text(json.dumps(
        {"id": "fix-1", "args": ["fix", "g1"], "pid": 999999, "log": str(runs / "jobs" / "fix-1.log")}))
    (runs / "warmup.log").write_text("[designer] spec.json ok\n")
    pt = runs / "playtests" / "pt-1"
    pt.mkdir(parents=True)
    (pt / "report.json").write_text(json.dumps({
        "goal": "start a round", "players": [{}], "ended": None,
        "steps": [{"n": 1, "player_name": "P1", "action": {"action": "interact", "reason": "board"},
                   "result": "no prompt"}],
        "bugs": [{"title": "Mission Board never triggers", "severity": "high"}]}))

    store = RunStore(s, "g1")
    store.ensure()
    store.save_spec({"title": "Lava", "pitch": "climb", "base_files": ["a.luau"]})
    state = store.new_state("idea")
    state["iterations"] = [{"n": 1, "score": 6, "version": "v1"},
                           {"n": 2, "score": 3, "version": "v2", "rolled_back_to": "v1"}]
    store.save_state(state)
    store.game_dir.mkdir(parents=True, exist_ok=True)
    (store.game_dir / "a.luau").write_text("return 1\n")
    GameVersions(store.game_dir).snapshot("seeded")
    imp = store.dir / "improve"
    imp.mkdir()
    (imp / "scores.json").write_text(json.dumps([{"cycle": 1, "ts": "t", "planted": 0, "detected": 0, "missed": 0,
                                                  "unmatched": 1, "fixed_verified": 0, "open": 1,
                                                  "code_kept": 1, "code_tried": 1}]))
    (imp / "1.json").write_text(json.dumps({
        "audit": {"anomalies": [{"title": "Board dead", "severity": "high", "system": "round"}]},
        "code_fixes": [{"anomaly": "Board dead", "status": "kept", "version": "v2", "attempts": []}]}))
    (imp / "calls.jsonl").write_text(json.dumps({"role": "auditor", "request_id": "mreq_a", "ts": "1"}) + "\n")
    (store.dir / "calls.jsonl").write_text(
        "\n".join(json.dumps({"role": "fixer", "request_id": f"mreq_{i}", "ts": str(i)}) for i in range(3))
        + "\n" + json.dumps({"role": "fixer", "request_id": None}) + "\nnot json\n")
    return s


def test_collect_shows_jobs_logs_playtests_games_and_mubit(settings):
    d = db.collect(settings)
    run = {r["name"]: r for r in d["running"]}
    assert run["fix-1"]["status"] == "finished" and run["fix-1"]["tail"] == ["[auditor] 2 anomalies"]
    assert run["warmup.log"]["status"] == "active"
    pt = run["playtest pt-1"]
    assert pt["status"] == "running" and "step 1" in pt["command"]
    assert any("Mission Board never triggers" in ln for ln in pt["tail"])

    g = d["games"][0]
    assert g["slug"] == "g1" and g["seeded"] and g["iterations"][1]["rolled_back_to"] == "v1"
    assert [v["version"] for v in g["versions"]] == ["v1"]
    assert g["cycles"][0]["anomalies"][0]["title"] == "Board dead"
    assert g["cycles"][0]["code_fixes"][0]["status"] == "kept"
    assert g["calls"] == {"fixer": 3, "auditor": 1}

    roles = {r["role"]: r for r in d["mubit"]["roles"]}
    assert roles["fixer"]["calls"] == 3 and roles["fixer"]["latest"]["request_id"] == "mreq_2"
    assert d["mubit"]["train_at"] == 25


def test_empty_runs_dir(tmp_path):
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "nothing")
    d = db.collect(s)
    assert d["running"] == [] and d["games"] == [] and d["mubit"]["total"] == 0


def test_server_serves_page_and_state(settings):
    server = db.serve("127.0.0.1", 0, settings)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        page = urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=5).read().decode()
        assert "<title>Forge runs</title>" in page and "/api/state" in page
        state = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=5).read())
        assert state["games"][0]["slug"] == "g1"
        with pytest.raises(urllib.error.HTTPError):
            urllib.request.urlopen(f"http://127.0.0.1:{port}/nope", timeout=5)
    finally:
        server.shutdown()


def test_old_playtests_are_not_listed_as_running(settings):
    d = db.running(settings, now=time.time() + db.PLAYTEST_RECENT + 60)
    assert not any(r["kind"] == "playtest" for r in d)
