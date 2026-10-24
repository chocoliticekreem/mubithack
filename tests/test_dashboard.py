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
        assert "<title>MuHack Workshop</title>" in page and "/api/state" in page and "/api/rollback" in page
        state = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=5).read())
        assert state["games"][0]["slug"] == "g1"
        with pytest.raises(urllib.error.HTTPError):
            urllib.request.urlopen(f"http://127.0.0.1:{port}/nope", timeout=5)
    finally:
        server.shutdown()


def test_old_playtests_are_not_listed_as_running(settings):
    d = db.running(settings, now=time.time() + db.PLAYTEST_RECENT + 60)
    assert not any(r["kind"] == "playtest" for r in d)


def test_what_improved_says_it_in_plain_words():
    its = [{"n": 1, "fixes": 2, "issues": [{"path": "ServerScriptService/Services/FlareUpService.luau"},
                                           {"path": "ServerScriptService/Plots.luau"}]}]
    w = db.what_improved
    assert w("iteration 1: code under test", its) == {"kind": "build", "title": "Built the first version"}
    assert w("iteration 1: code under test", its, seeded=True)["title"] == "Playtest round 1"
    assert w("iteration 2: code under test", its) == {"kind": "round", "title": "Fixed Flare Up, Plots"}
    assert w("fix: Cube drop rate about twice the specified rate in ReplicatedStorage/Config.luau "
             "(verifier: fixed, mreq_1)", [])["title"] == "Fixed cube drop rate"
    assert w("fix: Pathfinding returns NoPath in the lobby", [])["title"] == "Fixed pathfinding"
    assert w("feature: game passes, like a battle pass (3 new, 0 edited)", []) == \
        {"kind": "feature", "title": "Added game passes"}
    assert w("feature: Add a conveyor belt that moves orbs (2 new, 1 edited)", [])["title"] == "Added conveyor belt"
    assert w("before fixes (improve-g1-2)", [])["kind"] == "save"
    assert w("rollback to v4: iteration 4 scored 5", []) == {"kind": "rollback", "title": "Went back to v4"}
    assert w("seeded from /x/game (186 human files)", [])["title"] == "Started from the base game"
    assert w("", [])["title"] == "Saved"


def test_one_chest_per_version_with_files_and_kept_fixes(settings):
    gdir = RunStore(settings, "g1").game_dir
    (gdir / "b.luau").write_text("return 2\n")
    (gdir / "c.luau").write_text("return 3\n")
    GameVersions(gdir).snapshot("fix: Board dead in ServerScriptService/Round.luau (verifier: fixed)")
    m = db.collect(settings)["games"][0]["missions"]
    assert [x["version"] for x in m] == ["v1", "v2"]
    assert m[0]["title"] == "Started from the base game" and m[0]["files"] == 1 and not m[0]["current"]
    assert m[1]["kind"] == "fix" and m[1]["title"] == "Fixed board dead" and m[1]["current"]
    assert m[1]["files"] == 2 and m[1]["file_list"] == ["b.luau", "c.luau"]
    assert m[1]["fixes"] == ["Board dead"]  # the kept fix cycle 1 recorded for v2


def test_live_run_shows_the_working_role_and_blocks_rollback(settings):
    (settings.runs_dir / "g1-run.log").write_text("━━ forge run  g1 ━━\n  [critic]  6 files ✓\n  [fixer]  a.luau ✓\n")
    g = db.collect(settings)["games"][0]
    assert g["live"]["role"] == "fixer" and g["live"]["name"] == "g1-run.log"
    assert g["goal"] == {"rounds": 2, "target": 3, "score": 3, "best": 6, "max": 10}
    with pytest.raises(db.RollbackError) as e:
        db.rollback(settings, "g1", "v1")
    assert e.value.code == 409


def test_running_now_lists_live_runs_and_only_live_autopilots(settings):
    import os

    (settings.runs_dir / "g1-run.log").write_text("━━ forge run  g1 ━━\n  [fixer]  a.luau ✓\n")
    ap = RunStore(settings, "g1").dir / "autopilot"
    ap.mkdir()
    (ap / "status.json").write_text(json.dumps({"state": "running", "pid": os.getpid(), "round": 2, "phase": "detect"}))
    d = db.collect(settings)
    run = next(a for a in d["active"] if a["name"] == "g1-run.log")
    assert run["slug"] == "g1" and run["role"] == "fixer" and run["step"] == "[fixer] a.luau ✓"
    assert run["elapsed"] is None or run["elapsed"] >= 0
    auto = next(a for a in d["active"] if a["kind"] == "autopilot")
    assert auto["slug"] == "g1" and auto["role"] == "fixer" and auto["step"] == "round 2 · detect · fixing a bug"
    assert next(a for a in d["games"][0]["agents"] if a["role"] == "fixer")["running"] is True
    (ap / "status.json").write_text(json.dumps({"state": "running", "pid": 999999, "round": 2}))  # crashed
    assert not [a for a in db.collect(settings)["active"] if a["kind"] == "autopilot"]


def _post(port, body):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/api/rollback", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def test_rollback_endpoint_restores_as_a_new_version(settings, monkeypatch):
    gdir = RunStore(settings, "g1").game_dir
    gv = GameVersions(gdir)
    (gdir / "a.luau").write_text("return 'broken'\n")
    gv.snapshot("iteration 2: code under test")
    server = db.serve("127.0.0.1", 0, settings)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        assert _post(port, {"slug": "g1", "version": "v1"}) == (200, {"slug": "g1", "restored": "v1", "as": "v3"})
        assert (gdir / "a.luau").read_text() == "return 1\n"
        assert gv.tags() == ["v1", "v2", "v3"]  # nothing lost
        assert _post(port, {"slug": "g1", "version": "v9"})[0] == 400
        assert _post(port, {"slug": "g1", "version": "HEAD~1"})[0] == 400
        assert _post(port, {"slug": "nope", "version": "v1"})[0] == 404
        assert _post(port, ["not", "an", "object"])[0] == 400
        monkeypatch.setattr(db, "LOCAL", ())
        assert _post(port, {"slug": "g1", "version": "v1"})[0] == 403
        assert gv.tags() == ["v1", "v2", "v3"]
    finally:
        server.shutdown()
