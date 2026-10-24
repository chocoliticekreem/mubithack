import dataclasses
import json

from forge.config import load_settings
from forge.ledger import ledger, render


def _w(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj))


def _trace(game, n, role, rid, session, user):
    _w(game / "improve" / "traces" / f"2026102{n}-{role}-{rid}.json",
       {"ts": f"2026-10-24T00:0{n}:00+00:00", "role": role, "request_id": rid, "session_id": session,
        "user": user})


def _settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


def test_ledger_links_corrections_and_proved_fixes(tmp_path):
    game = tmp_path / "runs" / "g"
    sid = "improve-g-1"
    problem = "Playtest anomaly (bug, high, system x): Pads do nothing\n"
    _trace(game, 1, "fixer", "r1", sid, problem)
    _trace(game, 2, "fixer", "r2", sid, problem + "\n## Your previous fix was rejected\nno change")
    _trace(game, 3, "player", "p1", "play", "observe")
    _trace(game, 4, "investigator", "i9", sid, "probe")
    _w(game / "improve" / "1.json", {
        "cycle": 1, "session_id": sid, "ts": "2026-10-24T00:05:00+00:00",
        "correction": {"request_id": "a1"},
        "code_fixes": [{"anomaly": "Pads do nothing", "status": "kept", "attempts": [
            {"status": "unchanged", "verdict": {"request_id": "v1"}},
            {"status": "fixed", "verdict": {"request_id": "v2"}}],
            "reinvestigation": {"request_ids": ["i9"]}},
            {"anomaly": "Other", "status": "unproven", "attempts": []}]})
    _w(game / "state.json", {"corrections": [{"request_id": "h1", "note": "real players too"}]})

    data = ledger(_settings(tmp_path))

    by = {e["request_id"]: e for e in data["entries"]}
    assert by["r1"]["kind"] == "answer" and by["r1"]["verdict"] == "unchanged" and not by["r1"]["verified"]
    assert by["r2"]["kind"] == "correction" and by["r2"]["verified"]
    assert by["r2"]["verifier_request_id"] == "v2"
    assert by["a1"]["role"] == "auditor" and by["i9"]["role"] == "investigator"
    assert by["h1"]["kind"] == "correction"
    roles = {r["role"]: r for r in data["roles"]}
    assert roles["fixer"] == {"role": "fixer", "calls": 2, "corrections": 2, "verified": 1, "rejected": 1}
    assert data["total_calls"] == 4 and data["verified"] == 1
    text = render(data)
    assert "GOOD fixer" in text and "r2" in text


def test_ledger_empty_runs(tmp_path):
    (tmp_path / "runs").mkdir()
    data = ledger(_settings(tmp_path))
    assert data["total_calls"] == 0 and data["entries"] == []
    assert "Mubit calls recorded: 0" in render(data)
