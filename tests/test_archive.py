"""forge archive: the committed record of how a game was improved."""

from __future__ import annotations

import dataclasses
import json

from forge.archive import archive
from forge.config import load_settings
from forge.memory import RunStore
from forge.versions import GameVersions


def test_archive_keeps_cycles_traces_versions_and_playtests(tmp_path):
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")
    store = RunStore(s, "fab")
    store.ensure()
    store.save_spec({"title": "F"})
    store.save_state(store.new_state("idea"))
    g = store.game_dir
    g.mkdir(parents=True)
    (g / "A.luau").write_text("return 1\n")
    v = GameVersions(g)
    v.snapshot("seeded")
    (g / "A.luau").write_text("return 2\n")
    v.snapshot("fix: board never starts a round in A.luau (verifier: fixed, mreq_9)")
    imp = store.dir / "improve"
    (imp / "traces").mkdir(parents=True)
    (imp / "traces" / "t-auditor-mreq_1.json").write_text(json.dumps({"user": "u", "reply": "r"}))
    (imp / "calls.jsonl").write_text(json.dumps({"role": "auditor", "request_id": "mreq_1"}) + "\n")
    (imp / "1.json").write_text(json.dumps({"code_fixes": [{"status": "kept"}]}))
    (imp / "scores.json").write_text(json.dumps([{"cycle": 1, "ts": "t", "planted": 0, "detected": 0,
                                                   "open": 1, "code_kept": 1, "code_tried": 1}]))
    (imp / "patches").mkdir()
    (imp / "patches" / "x.luau").write_text("-- patch")
    pt = s.runs_dir / "playtests" / "pt-1"
    pt.mkdir(parents=True)
    (pt / "report.json").write_text(json.dumps({"goal": "g"}))
    (s.runs_dir / "fix-live-1.log").write_text("[cycle 1] planted 0 faults:\n")

    out = tmp_path / "evidence"
    [res] = archive(s, ["fab"], out)
    d = out / "fab"
    assert (d / "improve" / "1.json").exists() and (d / "improve" / "traces" / "t-auditor-mreq_1.json").exists()
    assert not (d / "improve" / "patches").exists()
    assert not (d / "game").exists()  # source is not copied, versions.md names the changed files
    versions = (d / "versions.md").read_text()
    assert "## v2" in versions and "fix: board never starts a round" in versions and "A.luau" in versions
    assert (d / "playtests" / "pt-1" / "report.json").exists()
    assert (out / "logs" / "fix-live-1.log").exists()
    index = (out / "INDEX.md").read_text()
    assert "code fixes kept 1/1" in index and "2 saved versions" in index
    assert res["traces"] == 1 and res["calls"] == 1 and res["versions"] == 2

    archive(s, ["fab"], out)  # running again refreshes, never duplicates
    assert len(list((out / "fab" / "playtests").iterdir())) == 1
