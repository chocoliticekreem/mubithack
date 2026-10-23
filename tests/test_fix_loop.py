"""The code-fix half of the self-improving loop: real anomalies -> fixer -> resync -> replay ->
verifier -> keep or roll back."""

from __future__ import annotations

import json
from pathlib import Path

from forge import improve as imp
from forge.improve import ImproveStore, run_cycle
from forge.llm import FakeLLM
from test_improve import FAULTS, FakeHarness, audit_reply, fake_playtest, settings  # noqa: F401

HOSE = {"kind": "broken_link", "system": "water", "title": "HoseService never cools fire",
        "expected": "fire goes out", "observed": "fires_extinguished 0", "severity": "high"}
FIRE = {"kind": "balance", "system": "fire", "title": "FireService spreads too fast",
        "expected": "slower", "observed": "fires_spread 90", "severity": "medium"}
LOW = {**HOSE, "title": "HoseService colour is odd", "severity": "low"}
HOSE_FILE = "ServerScriptService/Services/HoseService.luau"
FIRE_FILE = "ServerScriptService/Services/FireService.luau"


def _seeded_game(settings):
    store = ImproveStore(settings, "fab").run
    store.ensure()
    store.save_spec({"pitch": "fire game", "core_loop": "spray", "base_files": [FIRE_FILE]})
    for rel, src in {HOSE_FILE: "return {hose = 1}\n", FIRE_FILE: "return {fire = 1}\n"}.items():
        (store.game_dir / rel).parent.mkdir(parents=True, exist_ok=True)
        (store.game_dir / rel).write_text(src)
    return store.game_dir


def _fix_llm(anomalies, fixer, verdicts):
    return FakeLLM({"auditor": [audit_reply(anomalies)],
                    "fixer": [f"```luau\n{src}\n```" for src in fixer],
                    "verifier": [json.dumps({"verdict": v, "evidence": "e"}) for v in verdicts]})


async def _fix_cycle(settings, llm, faults=(), **kw):
    synced, seen = [], []

    async def resync(root):
        synced.append((root / HOSE_FILE).read_text())

    cycle = await run_cycle(settings, "fab", llm=llm, harness=FakeHarness(), playtest=fake_playtest(seen),
                            faults=list(faults), goal="play", rounds=1, fix=True, resync=resync,
                            log=lambda _: None, **kw)
    return cycle, synced, seen


async def test_verified_code_fix_is_kept(settings):
    game = _seeded_game(settings)
    llm = _fix_llm([HOSE], ["return {hose = 2}"], ["fixed"])
    cycle, synced, seen = await _fix_cycle(settings, llm)
    assert [f["status"] for f in cycle["code_fixes"]] == ["kept"]
    assert (game / HOSE_FILE).read_text().strip() == "return {hose = 2}"
    assert [s.strip() for s in synced] == ["return {hose = 2}"] and len(seen) == 2
    assert "HoseService never cools fire" in next(c.user for c in llm.calls if c.role == "fixer")
    assert cycle["code_kept"] == 1 and cycle["open"] == 1
    assert ImproveStore(settings, "fab").scores()[0]["code_kept"] == 1


async def test_unverified_code_fix_is_rolled_back_and_resynced(settings):
    game = _seeded_game(settings)
    cycle, synced, _ = await _fix_cycle(settings, _fix_llm([HOSE], ["return {hose = 3}"], ["not_fixed"]))
    assert cycle["code_fixes"][0]["status"] == "rolled_back"
    assert (game / HOSE_FILE).read_text() == "return {hose = 1}\n"
    assert [s.strip() for s in synced] == ["return {hose = 3}", "return {hose = 1}"]


async def test_human_owned_file_only_gets_a_patch(settings):
    game = _seeded_game(settings)
    cycle, synced, _ = await _fix_cycle(settings, _fix_llm([FIRE], ["return {fire = 2}"], []))
    fx = cycle["code_fixes"][0]
    assert fx["status"] == "suggested" and fx["path"] == FIRE_FILE
    assert Path(fx["patch"]).read_text().strip() == "return {fire = 2}"
    assert (game / FIRE_FILE).read_text() == "return {fire = 1}\n"
    assert synced == []


async def test_code_that_does_not_compile_is_restored(settings):
    game = _seeded_game(settings)
    cycle, synced, _ = await _fix_cycle(settings, _fix_llm([HOSE], ["local = = broken"], []))
    assert cycle["code_fixes"][0]["status"] == "compile_failed"
    assert (game / HOSE_FILE).read_text() == "return {hose = 1}\n"
    assert synced == []


async def test_low_severity_is_not_fixed_and_counts_as_closed(settings):
    _seeded_game(settings)
    llm = _fix_llm([LOW], [], [])
    cycle, _, _ = await _fix_cycle(settings, llm)
    assert cycle["code_fixes"] == [] and cycle["open"] == 0
    assert "fixer" not in [c.role for c in llm.calls]


async def test_planted_faults_get_a_clean_baseline_before_code_fixes(settings):
    _seeded_game(settings)
    llm = FakeLLM({"auditor": [audit_reply([HOSE]), audit_reply([HOSE])],
                   "fixer": ["```luau\nreturn {hose = 2}\n```"],
                   "verifier": [json.dumps({"verdict": "fixed", "evidence": "e"})]})
    cycle, _, seen = await _fix_cycle(settings, llm, faults=FAULTS)
    assert len(seen) == 3  # faulted round, clean baseline, replay after the fix
    assert seen[1][("ToolConfig", "LitresPerSpray")] == 1.2
    assert cycle["code_fixes"][0]["status"] == "kept"


async def test_tester_report_anomalies_are_fixed_too(settings):
    _seeded_game(settings)
    store = ImproveStore(settings, "fab")
    store.dir.mkdir(parents=True, exist_ok=True)
    (store.dir / "reports.jsonl").write_text(json.dumps(
        {"ts": "2000-01-01T00:00:00+00:00", "triage": {"anomalies": [HOSE]}}) + "\n")
    extra = imp.pending_report_anomalies(store)
    assert extra == [HOSE]
    cycle, _, _ = await _fix_cycle(settings, _fix_llm([], ["return {hose = 2}"], ["fixed"]),
                                   extra_anomalies=extra)
    assert cycle["code_kept"] == 1
    assert imp.pending_report_anomalies(store) == []  # older than the cycle now
