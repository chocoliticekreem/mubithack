"""forge dashboard: agent levels and the per-round green arrow, from recorded run data only."""

from __future__ import annotations

import json
from pathlib import Path

from forge import dashboard as db


def iso(minute: int) -> str:
    return f"2026-10-25T00:{minute:02d}:00Z"


def make_run(tmp_path: Path, rounds: list[dict], level_rows: list[dict] = (), qa: dict | None = None,
             roles: tuple[str, ...] = ("fixer", "critic", "reflector", "level_designer", "coder")) -> tuple[Path, list[dict]]:
    run = tmp_path / "game"
    run.mkdir(parents=True)
    its = []
    for i, r in enumerate(rounds, start=1):
        d = run / "iterations" / str(i)
        d.mkdir(parents=True)
        (d / "record.json").write_text(json.dumps({"n": i, "lessons_updated": r.get("lessons", False),
                                                   "fun": {"score": r["fun"]} if "fun" in r else None}))
        its.append({"n": i, "score": r.get("score"), "ended": iso(10 + i * 5), "taught": r.get("taught", []),
                    "acceptance": {"met": r.get("met", []), "missing": []}})
    (run / "state.json").write_text(json.dumps({"iterations": its, "corrections": []}))
    if level_rows:
        (run / "levels").mkdir()
        (run / "levels" / "log.jsonl").write_text("\n".join(json.dumps(x) for x in level_rows))
    for name, met in (qa or {}).items():
        (run / "tests" / name).mkdir(parents=True)
        (run / "tests" / name / "report.json").write_text(json.dumps({"goal_met": met}))
    calls = [{"role": r, "ts": iso(11), "request_id": f"mreq_{r}", "source": "build", "trace_dir": run / "traces"}
             for r in roles]
    return run, calls


def zone(minute: int, corrections: int, errors: int = 0) -> dict:
    return {"ts": iso(minute), "zone": minute, "corrections": corrections, "fallback": [],
            "attempts": [{"errors": 1}] * corrections + [{"errors": errors}]}


def test_corrections_the_fixer_received_are_xp_but_not_an_arrow(tmp_path):
    no = "ParkGifts left gift_ready at 0 after 1 try, told to try another way"
    run, calls = make_run(tmp_path, [{"score": 5, "taught": []}, {"score": 5, "taught": [no, no.replace("1 try", "2 tries")]},
                                     {"score": 5, "taught": [no, no, no]}])
    fx = db.agent_levels(run, calls)["fixer"]
    assert fx["xp"] == 5 and fx["level"] == 2 and fx["next_xp"] == 6 and fx["floor_xp"] == 3
    assert fx["round"] == 3 and fx["gained"] == 3
    assert not fx["improved"] and fx["reason"] == "" and not fx["level_up"]


def test_a_confirmed_fix_and_more_counters_firing_improve_the_fixer_and_level_it_up(tmp_path):
    run, calls = make_run(tmp_path, [{"met": ["a"]}, {"met": ["a", "b"],
                                                     "taught": ["ParkGifts fix confirmed (gift_ready fire)"]}])
    fx = db.agent_levels(run, calls)["fixer"]
    assert fx["improved"] and fx["round"] == 2
    assert "fix confirmed" in fx["reason"] and "acceptance counters firing 1 -> 2" in fx["reason"]
    assert fx["xp"] == 3 and fx["level"] == 2 and fx["level_up"]


def test_critic_arrow_only_when_the_score_it_gave_rose(tmp_path):
    run, calls = make_run(tmp_path, [{"score": 5}, {"score": 6}, {"score": 6}])
    cr = db.agent_levels(run, calls)["critic"]
    assert not cr["improved"] and cr["rounds_improved"] == 1 and cr["xp"] == 4
    run2, calls2 = make_run(tmp_path / "b", [{"score": 5}, {"score": 7}])
    cr2 = db.agent_levels(run2, calls2)["critic"]
    assert cr2["improved"] and cr2["reason"] == "score it gave rose 5 -> 7"


def test_fun_critic_uses_the_fun_score_from_the_round_record(tmp_path):
    run, calls = make_run(tmp_path, [{"fun": 5.2}, {"fun": 6.0}], roles=("fun_critic",))
    assert db.agent_levels(run, calls)["fun_critic"]["reason"] == "score it gave rose 5.2 -> 6"


def test_reflector_improves_in_a_round_it_rewrote_lessons_and_not_otherwise(tmp_path):
    run, calls = make_run(tmp_path, [{"lessons": True}, {"lessons": False}])
    rf = db.agent_levels(run, calls)["reflector"]
    assert rf["xp"] == 1 and not rf["improved"]
    run2, calls2 = make_run(tmp_path / "b", [{"lessons": True}, {"lessons": True}])
    assert db.agent_levels(run2, calls2)["reflector"]["improved"]


def test_level_designer_improves_when_zones_pass_with_no_corrections_in_that_round(tmp_path):
    # round 1 ends at :15, round 2 at :20; a zone that never passed earns nothing
    rows = [zone(12, 0), zone(17, 0), zone(18, 1), zone(19, 0, errors=2)]
    run, calls = make_run(tmp_path, [{}, {}], level_rows=rows)
    ld = db.agent_levels(run, calls)["level_designer"]
    assert ld["improved"] and ld["reason"] == "1 zone passed with no corrections"
    assert ld["xp"] == 1 + 1 + 2 and ld["gained"] == 3
    run2, calls2 = make_run(tmp_path / "b", [{}, {}], level_rows=[zone(12, 0), zone(18, 2)])
    assert not db.agent_levels(run2, calls2)["level_designer"]["improved"]


def test_qa_tester_roles_improve_when_the_pass_rate_rose(tmp_path):
    qa = {"01-qa-1-0100": True, "01-qa-2-0100": False, "02-qa-1-0200": True, "02-qa-2-0200": True}
    run, calls = make_run(tmp_path, [{}, {}], qa=qa, roles=("player",))
    pl = db.agent_levels(run, calls)["player"]
    assert pl["improved"] and pl["reason"] == "QA pass rate rose 50% -> 100%" and pl["xp"] == 3


def test_roles_with_no_signal_earn_xp_per_answered_call_and_never_get_an_arrow(tmp_path):
    run, calls = make_run(tmp_path, [{"score": 5}, {"score": 9, "lessons": True}])
    calls += [{**calls[-1], "error": "boom"}]
    co = db.agent_levels(run, calls)["coder"]
    assert co["xp"] == 1 and not co["improved"] and not co["level_up"]


def test_no_rounds_yet_means_no_arrows(tmp_path):
    run, calls = make_run(tmp_path, [])
    lv = db.agent_levels(run, calls)
    assert all(not v["improved"] and v["round"] is None for v in lv.values())


def test_agents_view_carries_the_level(tmp_path):
    run, calls = make_run(tmp_path, [{"score": 5}, {"score": 6}])
    rows = db.agents_view(calls, None, 0, db.agent_levels(run, calls))
    assert next(a for a in rows if a["role"] == "critic")["level"]["improved"]
    assert db.agents_view(calls, None, 0)[0]["level"] is None
