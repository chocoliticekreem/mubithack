"""Obby arsenal: the reachability validator (forge/obby.py), ObbyKit (forge/kit/modules/ObbyKit.luau) running the
same rules in Luau, the kit-modules mechanism (forge/director.py), the obby genre checks and the obby checklist."""

from __future__ import annotations

import dataclasses
import io
import json
import shutil
import subprocess
from pathlib import Path

import pytest

from forge import checks, director, gaps, obby, roles
from forge.config import load_settings
from forge.llm import FakeLLM
from forge.loop import Run, UI
from forge.memory import RunStore

LUAU = shutil.which("luau-compile")
needs_luau = pytest.mark.skipif(LUAU is None, reason="luau-compile not on PATH")
needs_headless = pytest.mark.skipif(not checks.headless_available(), reason="luau CLI not on PATH")
KIT = director.KIT_MODULES_DIR / "ObbyKit.luau"
KIT_PATH = "ReplicatedStorage/Kit/ObbyKit.luau"

# Landed by a server-owned R15 runner in Studio (walk 16, jump height 7.2, gravity 196.2), jumping 0.75 studs
# before the edge: the validator must never allow more than a real jump clears.
MEASURED_LANDED = {0: 10.0, 3: 9.0, 6: 8.0, -6: 11.5}


def stage(n: int, *pieces: dict) -> dict:
    return obby.normalize_stage({"stage": n, "pieces": list(pieces)}, n)


def errs(*pieces: dict) -> list[str]:
    return obby.validate_stage(stage(1, *pieces), 1)


CP = {"kind": "checkpoint", "gap": 5}

# A zone with one problem of (almost) every kind, used for Python <-> Luau parity.
PARITY = [
    {"stage": 1, "pieces": [{"kind": "platform", "gap": 6}, {"kind": "checkpoint", "gap": 5}]},
    {"stage": 2, "pieces": [
        {"kind": "platform", "gap": 6, "side": 3},
        {"kind": "moving", "gap": 14, "move": [0, 0, -8], "period": 4},
        {"kind": "lava", "gap": 0, "rise": 0.8},
        {"kind": "disappearing", "gap": 4, "count": 6, "stagger": 0.3, "on": 1.5},
        {"kind": "jumppad", "gap": 5},
        {"kind": "platform", "gap": 12, "rise": 12, "shape": "round", "size": [9, 1, 3]},
        {"kind": "pendulum", "gap": 5, "swing": 20, "length": 6},
        {"kind": "spinner", "gap": 4, "speed": 400},
        {"kind": "checkpoint", "gap": 13}]},
    {"stage": 3, "pieces": [
        {"kind": "conveyor", "gap": 5, "dir": "back", "speed": 12},
        {"kind": "platform", "gap": 7},
        {"kind": "trampoline", "gap": 4},
        {"kind": "turntable", "gap": 6, "rise": 15},
        {"kind": "moving", "gap": 3, "move": [12, 0, 0], "period": 3, "phase": 0.25},
        {"kind": "moving", "gap": 3, "move": [0, 0, -14], "period": 5},
        {"kind": "warpzone", "gap": 3},
        {"kind": "checkpoint", "gap": 25, "rise": -30}]},
    {"stage": 7, "pieces": [{"kind": "checkpoint"}]},
]

# v2 layout: turned pads, logs, ramps and the body-aware crush rule, each with a problem v1 would not report.
DIAGONAL = {"kind": "platform", "gap": 8, "side": 12, "size": [6, 1, 6]}  # 8.9 off a square pad, 10.8 off its disc
PARITY_V2 = [
    {"stage": 1, "turn": 45, "pieces": [
        DIAGONAL,
        {"kind": "platform", "shape": "cylinder", "gap": 4, "rise": 1, "size": [10, 4, 9]},
        {"kind": "platform", "shape": "wedge-ramp", "gap": 9.5, "rise": 3, "size": [8, 3, 8]},
        {"kind": "platform", "shape": "wedge-ramp", "gap": 4, "rise": 2, "size": [8, 6, 4]},
        {"kind": "lava", "gap": 0, "rise": -1, "size": [8, 1, 3]},
        {"kind": "platform", "shape": "wedge-ramp", "gap": 0, "rise": 1, "size": [8, 3, 8]},
        {"kind": "checkpoint", "gap": 5}]},
    {"stage": 2, "turn": 120, "pieces": [
        {"kind": "platform", "gap": 6, "size": [8, 3, 8]},
        {"kind": "moving", "gap": 2, "rise": -7, "move": [0, 0, -6], "period": 4},
        {"kind": "checkpoint", "gap": 5, "rise": 7}]},
    {"stage": 3, "turn": -90, "pieces": [
        DIAGONAL,
        {"kind": "platform", "shape": "cylinder", "gap": 4, "size": [10, 1, 4]},
        {"kind": "platform", "gap": 9.6, "side": 3, "size": [8, 1, 8]},
        {"kind": "checkpoint", "gap": 5}]},
    {"stage": 4, "turn": 45, "pieces": [  # a first piece 1 stud out: inside the corner the turned pad points forward
        {"kind": "platform", "gap": 1, "size": [6, 1, 6]},
        {"kind": "platform", "shape": "round", "gap": 1, "side": 9, "rise": -3, "size": [6, 1, 6]},
        {"kind": "checkpoint", "gap": 5, "rise": 3}]},
]

GOOD = [
    {"stage": 1, "name": "Hop", "pieces": [{"kind": "platform", "gap": 6, "coins": 2},
                                           {"kind": "lava", "gap": 0, "size": [8, 1, 3]},
                                           {"kind": "platform", "gap": 0, "side": 2}, CP]},
    {"stage": 2, "name": "Ride", "pieces": [
        {"kind": "moving", "gap": 14, "move": [0, 0, -8], "period": 4},
        {"kind": "disappearing", "gap": 5, "count": 4, "stagger": 0.6, "on": 2.5},
        {"kind": "jumppad", "gap": 5},
        {"kind": "platform", "gap": 12, "rise": 12, "shape": "round", "size": [9, 1, 9]},
        {"kind": "pendulum", "gap": 5}, {"kind": "spinner", "gap": 4}, {"kind": "checkpoint", "gap": 6}]},
    {"stage": 3, "name": "Belt", "pieces": [
        {"kind": "conveyor", "gap": 5, "dir": "left", "speed": 6}, {"kind": "trampoline", "gap": 4},
        {"kind": "turntable", "gap": 6, "rise": 12}, {"kind": "checkpoint", "gap": 6}]},
]


# ---------------------------------------------------------------- the jump model


def test_jump_limits_stay_under_what_a_real_runner_lands():
    plain = obby._plain()
    for rise, landed in MEASURED_LANDED.items():
        assert obby.reach(plain, rise) <= landed + 0.05, rise
    assert round(obby.reach(plain, 0), 1) == 10.0 and round(obby.reach(plain, 6), 1) == 7.4
    assert obby.reach(plain, 6.01) is None and obby.reach(plain, -20) == obby.MAX_GAP
    pad = obby._plain(max(obby.JUMP_SPEED, obby.launch_speed(90)), launched=True)
    assert 29 < obby.max_rise(pad) < 31  # measured apex of a 90 launch held 0.12 s: 32.4


def test_validator_names_each_broken_jump_exactly():
    assert errs({"kind": "platform", "gap": 6}, CP) == []
    assert errs({"kind": "platform", "gap": 10.5}, CP) == [
        "stage 1 jump from the start pad to piece 1 (platform): gap 10.5 at rise 0.0 > max 10.0"]
    assert errs({"kind": "platform", "gap": 4, "rise": 6.5}, CP) == [
        "stage 1 jump from the start pad to piece 1 (platform): rise 6.5 > max 6.0"]
    assert errs({"kind": "platform", "gap": 8, "side": 14}, CP) == []  # 9.4 studs once the side offset counts
    assert errs({"kind": "platform", "gap": 8, "side": 16}, CP) == [
        "stage 1 jump from the start pad to piece 1 (platform): gap 10.6 at rise 0.0 > max 10.0"]
    drop = errs({"kind": "lava", "gap": 2, "rise": -10}, {"kind": "platform", "gap": 0, "rise": -15}, CP)
    assert "stage 1 jump from the start pad to piece 2 (platform): drop 25.0 > max 20.0" in drop


def test_validator_checks_structure_params_and_kind_rules():
    assert errs({"kind": "platform"}, {"kind": "platform"}) == ["stage 1 must end with a checkpoint piece"]
    assert errs(CP)[0] == "stage 1 has 1 pieces; use 2 to 11 (the checkpoint included)"
    assert "has 2 checkpoints" in errs(CP, CP)[0]
    assert "unknown kind 'warp'" in errs({"kind": "warp"}, CP)[0]
    assert errs({"kind": "spinner", "speed": 400}, CP) == ["stage 1 piece 1 (spinner): speed 400 out of range [30, 180]"]
    assert "size width 1 out of range [2, 40]" in errs({"kind": "platform", "size": [1, 1, 8]}, CP)[0]
    assert "dir 'up' must be one of forward, back, left, right" in errs({"kind": "conveyor", "dir": "up"}, CP)[0]
    assert "the ball never clears the bridge" in errs({"kind": "pendulum", "swing": 20, "length": 6}, CP)[0]
    assert "tile 6 is not solid in time" in errs({"kind": "disappearing", "count": 6, "stagger": 0.3, "on": 1.5}, CP)[0]
    assert errs({"kind": "disappearing", "count": 6, "stagger": 0.6, "on": 2.5}, CP) == []
    assert "kill parts lie at floor level" in errs({"kind": "platform"}, {"kind": "lava", "gap": 0, "rise": 1},
                                                   {"kind": "platform", "gap": 0, "rise": -1}, CP)[0]
    many = [{"kind": "platform", "gap": 3}] * 11 + [CP]
    assert "has 12 pieces" in obby.validate_stage(stage(1, *many), 1)[0]
    long = [{"kind": "platform", "gap": 9, "size": [8, 1, 30]}] * 6 + [CP]
    assert any("studs long" in e for e in obby.validate_stage(stage(1, *long), 1))


def test_movers_are_judged_over_their_motion():
    ferry = errs({"kind": "platform"}, {"kind": "moving", "gap": 14, "move": [0, 0, -8]}, CP)
    assert ferry == []  # out of reach at rest, in reach once it comes back
    never = errs({"kind": "moving", "gap": 20, "move": [0, 0, 3]}, CP)
    assert never == ["stage 1 jump from the start pad to piece 1 (moving): never in reach for 0.3s "
                     "(closest: gap 20.0 at rise 0.0, max 10.0)"]
    crush = errs({"kind": "platform"}, {"kind": "moving", "gap": 3, "move": [0, 0, -12]}, CP)
    assert any("passes through piece 1 (platform)" in e for e in crush)


def test_launches_and_back_conveyors_change_the_reach():
    assert errs({"kind": "jumppad"}, {"kind": "platform", "gap": 12, "rise": 15}, CP) == []
    assert errs({"kind": "platform"}, {"kind": "platform", "gap": 12, "rise": 15}, CP)
    assert "max 3.5" in errs({"kind": "conveyor", "dir": "back", "speed": 12}, {"kind": "platform", "gap": 7}, CP)[0]


def test_every_fallback_stage_validates():
    for d in range(1, 11):
        assert obby.validate_stage(obby.fallback_stage(9, d), 9) == [], d


def test_turned_pads_and_shapes_change_the_measured_jumps():
    turned = obby.normalize_stage({"stage": 1, "turn": 30, "pieces": [DIAGONAL, CP]}, 1)
    square = obby.normalize_stage({"stage": 1, "turn": 90, "pieces": [DIAGONAL, CP]}, 1)
    assert obby.validate_stage(square, 1) == []  # a right-angle turn keeps the pad square
    assert obby.validate_stage(turned, 1) == [
        "stage 1 jump from the start pad to piece 1 (platform): gap 10.8 at rise 0.0 > max 10.0"]
    log = obby.normalize_piece({"kind": "platform", "shape": "cylinder", "size": [10, 1, 6]})
    assert log["size"] == [10, 6, 6]  # a log's height is its diameter
    surfaces, _ = obby.layout(stage(1, {"kind": "platform", "shape": "cylinder", "gap": 4, "size": [10, 1, 6]}, CP))
    s = surfaces[1]
    assert (s.l, s.bl, s.h) == (3, 6, 6) and s.land_drop == s.off_drop == pytest.approx(3 * obby.LOG_DROP)
    ramp = obby.layout(stage(1, {"kind": "platform", "shape": "wedge-ramp", "gap": 4, "rise": 4, "size": [8, 4, 8]}, CP))
    assert ramp[0][1].land_drop == 4 and ramp[0][1].off_drop == 0
    assert errs({"kind": "platform", "shape": "wedge-ramp", "gap": 4, "rise": 4, "size": [8, 4, 8]}, CP) == []  # walk on
    assert errs({"kind": "platform", "gap": 4, "rise": 4, "size": [8, 1, 8]}, CP) == []
    # rise 7 with a 1-stud climb: its low edge sits 6 up, right at the limit; rise 8 puts it 7 up
    assert errs({"kind": "platform", "shape": "wedge-ramp", "gap": 4, "rise": 7, "size": [8, 1, 8]}, CP) == []
    assert errs({"kind": "platform", "shape": "wedge-ramp", "gap": 4, "rise": 8, "size": [8, 1, 8]}, CP) == [
        "stage 1 jump from the start pad to piece 1 (platform): rise 7.0 > max 6.0"]


def test_crush_rule_counts_body_thickness():
    # a mover 5.5 under a 1-thick piece: a player riding it (5 tall) hits that piece's underside; v1 let it pass
    over = [{"kind": "platform", "gap": 6, "size": [8, 1, 8]},
            {"kind": "moving", "gap": 2, "rise": -5.5, "move": [0, 0, -6], "period": 4}, dict(CP, rise=5.5)]
    assert any("passes through piece 1 (platform)" in e for e in errs(*over))
    thick = [dict(over[0], size=[8, 3, 8]), dict(over[1], rise=-7.5), dict(CP, rise=6)]
    assert any("passes through piece 1 (platform)" in e for e in errs(*thick))
    clear = [over[0], dict(over[1], rise=-12), dict(CP, gap=3, rise=4)]
    assert not any("passes through" in e for e in errs(*clear))


def _vstage(n: int, turn: float, *pieces: dict) -> dict:
    return obby.normalize_stage({"stage": n, "turn": turn, "pieces": [*pieces, CP]}, n)


ROUND = {"kind": "platform", "shape": "round", "gap": 4, "size": [8, 1, 8]}
BLOCK = {"kind": "platform", "gap": 4, "size": [8, 1, 8]}
LAVA = {"kind": "lava", "gap": 0, "rise": -0.5, "size": [8, 1, 3]}


def test_zone_rules_name_every_variety_problem_exactly():
    zone = {"stages": [
        _vstage(1, 0, BLOCK, BLOCK, BLOCK),
        _vstage(2, 30, ROUND, LAVA, dict(BLOCK, gap=0, rise=0.5)),
        _vstage(3, 0, ROUND, LAVA, dict(BLOCK, gap=0, rise=0.5)),
        _vstage(4, 0, {"kind": "moving", "gap": 4, "move": [4, 0, 0]}, BLOCK)]}
    assert all(obby.validate_stage(s, s["stage"]) == [] for s in zone["stages"])
    assert obby.zone_rules(zone, 1, 4, "carousel") == [
        "stage 1 has 3 plain platforms in its 3 pieces (the checkpoint not counted); at most half may be plain block "
        "platforms: use round, cylinder or wedge-ramp shapes or obstacles",
        "stage 1 has no obstacle: give it at least one of lava, moving, disappearing, jumppad, conveyor, trampoline, "
        "spinner, turntable, pendulum",
        "stage 2 and stage 3 share the kind sequence [platform, lava, platform]; no two stages of a zone may: change "
        "all but one",
        "the zone uses 3 kinds (platform, lava, moving); use at least 4",
        "the zone is the carousel zone: its signature kind turntable is in 0 of its 4 stages (none); use it in at least 2",
        "the zone is the carousel zone: its signature kind moving is in 1 of its 4 stages (4); use it in at least 2",
        "the zone turns in 1 of its 4 stages (2); at least 2 need a turn (turn -90 to 90 degrees, right +, on the "
        "stage's start pad)",
        "the zone climbs 0.0 studs from its start to its last checkpoint; it must climb at least 4 (1 per stage): add "
        "rises, wedge-ramps or jump pads",
        "stage 3 piece 4 (checkpoint) leaves the zone's plot: x 44.8 is past its right edge (38); keep to the route's "
        "turns and stage lengths",
        "stage 4 piece 3 (checkpoint) leaves the zone's plot: x 63.8 is past its right edge (38); keep to the route's "
        "turns and stage lengths"]
    stats = obby.rule_stats(zone, 1, 4, "carousel")
    assert stats["plain_share"] == round(6 / 11, 3) and stats["kinds"] == ["platform", "lava", "moving"]
    assert stats["distinct_sequences"] == 3 and stats["turned"] == 1 and stats["climb"] == 0
    assert stats["signature"] == {"turntable": 0, "moving": 1} and stats["need"] == 2 and stats["shaped"] == 2
    assert stats["extent"] == [-5.0, 63.8, -5.0, 156.6] and stats["outside_plot"] == 2


def test_theme_palettes_keep_every_zone_s_main_colour_apart():
    import itertools
    import math

    def lab(h: str) -> tuple[float, float, float]:
        rgb = [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]
        r, g, b = (c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb)
        f = lambda t: t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116  # noqa: E731
        x, y, z = ((0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047, 0.2126 * r + 0.7152 * g + 0.0722 * b,
                   (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883)
        return 116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))

    assert set(obby.THEME_PALETTES) == set(obby.THEMES) and all(len(p) == 3 for p in obby.THEME_PALETTES.values())
    closest = min(math.dist(lab(a[0]), lab(b[0])) for a, b in itertools.combinations(obby.THEME_PALETTES.values(), 2))
    assert closest >= 25, closest  # CIE76: no two zones' platforms read as the same colour


def test_route_plan_is_a_switchback_that_fits_the_plot_for_every_zone_size():
    shape = lambda n: "".join("C" if p["role"] == "corner" else "o" if p["dir"] == "out" else "b"  # noqa: E731
                              for p in obby.route_plan(n))
    assert shape(20) == "oooooCbbbbCooooCbbbb" and shape(4) == "ooCb" and shape(3) == "ooC" and shape(1) == "o"
    plan = obby.route_plan(20)
    assert [p["index"] + 1 for p in plan if p["turn"]] == [6, 7, 11, 12, 16, 17]  # corner, then the next run's first
    assert {p["turn"] for p in plan} == {0.0, obby.CORNER_TURN} == {0.0, -90.0}  # left: right steers into the rides
    for n in range(1, 101):
        plan, at, ends = obby.route_plan(n), 0, []
        for p in plan:
            if p["role"] == "run":
                at += 1 if p["dir"] == "out" else -1
                ends.append(at)
        assert len(plan) == n and (sum(1 for p in plan if p["turn"]) >= obby.share_need(n) or n == 1), n
        assert min(ends) >= 1 and max(ends) <= obby.MAX_RUN_STAGES == 5, n  # runs back end in front of the start


def _lift(n: int, k: int) -> dict:
    piece, cp = [({"kind": "jumppad", "gap": 4}, 6), ({"kind": "trampoline", "gap": 4}, 4),
                 ({"kind": "moving", "gap": 3, "move": [0, 16, 0], "period": 5}, 3)][k % 3]
    return obby.normalize_stage({"stage": n, "pieces": [piece, {"kind": "checkpoint", "gap": cp, "rise": 16}]}, n)


def test_a_zone_built_to_the_route_stays_in_its_plot_and_stacks_its_runs():
    mid = [{"kind": "turntable", "gap": 4, "size": [8, 1, 8]}, {"kind": "conveyor", "gap": 4, "size": [6, 1, 8]},
           {"kind": "spinner", "gap": 4, "size": [10, 1, 10]}, {"kind": "disappearing", "gap": 4, "count": 2, "spacing": 2},
           {"kind": "trampoline", "gap": 4, "size": [6, 1, 6]}]
    stages, corners = [], 0
    for p in obby.route_plan(20):
        n = p["index"] + 1
        if p["role"] == "corner":
            stages.append(_lift(n, corners))
            corners += 1
        else:
            stages.append(_vstage(n, 0, dict(ROUND, gap=3), {"kind": "moving", "gap": 4, "move": [4, 0, 0]}, mid[n % 5],
                                  dict(ROUND, gap=3, rise=2), mid[(n // 5) % 5]))
    zone = obby.apply_route({"stages": stages}, 1, 20)
    assert all(55 <= obby.stage_length(s) <= 80 for s in zone["stages"] if len(s["pieces"]) > 2)
    assert obby.validate_zone(zone, 1, 20) == [] and obby.footprint_problems(zone, 1, 20) == []
    assert obby.crossing_problems(zone, 1, 20) == []  # runs 3 and 4 pass over runs 1 and 2, two lifts higher
    x0, x1, z0, z1 = obby.extent(zone, 1, 20)
    assert -obby.PLOT_HALF_WIDTH <= x0 and x1 <= obby.PLOT_HALF_WIDTH and -obby.PLOT_BACK <= z0 and z1 <= obby.PLOT_LENGTH
    frames, _ = obby.course_layout(zone, 1, 20)
    assert [round(f["heading"]) for f in frames[5:8]] == [-90, -180, -180] and frames[-1]["y"] >= 3 * 15
    straight = obby.apply_route(dict(zone, stages=[dict(s, turn=0) for s in zone["stages"]]), 1, 20)
    assert straight == zone  # Forge owns the turns: whatever the designer wrote, the route's are kept
    off = [dict(s, turn=0) for s in zone["stages"]]
    assert [p["stage"] for p in obby.footprint_problems({"stages": off}, 1, 20)] == list(range(7, 21))
    assert obby.footprint_problems({"stages": off}, 1, 20)[0]["text"] == (
        "stage 7 piece 6 (checkpoint) leaves the zone's plot: z 469.0 is past its far end (450); keep to the route's "
        "turns and stage lengths")
    assert obby.zone_rules(zone, 1, 20, "carousel") == []
    assert [r["climb"] for r in obby.run_climbs(zone, 1, 20)] == [10, 8, 8, 8]  # the corners lift 16 each on top
    steep = dict(zone, stages=[dict(s, pieces=s["pieces"][:-1] + [dict(s["pieces"][-1], rise=10)]) if s["stage"] == 3 else s
                               for s in zone["stages"]])
    climbs = [p for p in obby.rule_problems(steep, 1, 20, "carousel") if p["code"] == "climb"]
    assert [(p["text"], p["stages"]) for p in climbs] == [(
        "the zone's run 1 (stages 1-5) climbs 20.0 studs; a run climbs at most 12 (the corners lift the course a level "
        "each): after a rise or a jump pad's high platform, drop back down", [1, 2, 3, 4, 5])]


def test_signature_kinds_per_theme_and_the_finale_mix():
    assert set(obby.SIGNATURES) == set(obby.THEMES)
    vertical = _vstage(1, 0, ROUND, {"kind": "moving", "gap": 4, "move": [0, 8, 0]}, dict(BLOCK, rise=8))
    sideways = _vstage(1, 0, ROUND, {"kind": "moving", "gap": 4, "move": [8, 0, 0]}, BLOCK)
    ferris = obby.SIGNATURES["ferris"][0][2]
    assert any(ferris(p) for p in vertical["pieces"]) and not any(ferris(p) for p in sideways["pieces"])
    entrance = obby.SIGNATURES["entrance"][0][2]
    assert entrance(ROUND) and not entrance(BLOCK) and not entrance(LAVA)
    mix = {"stages": [_vstage(1, 30, ROUND, LAVA, dict(BLOCK, gap=0, rise=1)), _vstage(2, -30, ROUND, LAVA, dict(BLOCK, gap=0, rise=2))]}
    assert "the zone uses 2 kinds (platform, lava); use at least 6 (the finale is a mix of everything)" in \
        obby.zone_rules(mix, 1, 2, "finale")
    assert not any("signature" in e for e in obby.zone_rules(mix, 1, 2, "finale"))
    assert not any("signature" in e for e in obby.zone_rules(mix, 1, 2, None))


def test_course_layout_turns_and_the_course_never_crosses_itself():
    loop = {"stages": [_vstage(n, 0 if n == 1 else 90, BLOCK) for n in range(1, 6)]}
    frames, _ = obby.course_layout(loop, 1, 5)
    assert [round(f["heading"]) for f in frames[:5]] == [0, 90, 180, 270, 360]
    assert (round(frames[1]["x"], 1), round(frames[1]["z"], 1)) == (0.0, 27.0)  # stage 2 starts on stage 1's checkpoint
    assert (round(frames[2]["x"], 1), round(frames[2]["z"], 1)) == (27.0, 27.0)  # ... facing right after its turn
    tail = ": the course crosses itself after its turns; turn the other way, climb higher or shift it sideways"
    assert [p["text"] for p in obby.crossing_problems(loop, 1, 5)] == [  # four right turns close the square
        "stage 4 piece 2 (checkpoint) runs into the zone's start pad" + tail,
        "stage 5 jump to piece 1 (platform) runs into the zone's start pad" + tail,
        "stage 5 piece 2 (checkpoint) runs into the jump to stage 2 piece 1 (platform)" + tail]
    zigzag = {"stages": [_vstage(n, [0, 45, -45, 45, -45][n - 1], BLOCK) for n in range(1, 6)]}
    assert obby.crossing_problems(zigzag, 1, 5) == []
    spiral = {"stages": [_vstage(n, 0 if n == 1 else 90, dict(BLOCK, rise=14)) for n in range(1, 6)]}
    assert obby.crossing_problems(spiral, 1, 5) == [] and obby.climb(spiral, 1, 5) == 70  # 14 up per stage clears it


def test_fallback_stages_keep_the_per_stage_variety_rules():
    for n in range(4):
        for d in range(1, 11):
            st = obby.fallback_stage(20 + n, d)
            assert obby.validate_stage(st, 20 + n) == [], (n, d)
            assert [p for p in obby.rule_problems({"stages": [st]}, 20 + n, 1) if p["stage"]] == [], (n, d)
    seqs = {tuple(p["kind"] for p in obby.fallback_stage(n, 5)["pieces"]) for n in range(4)}
    assert len(seqs) == 4


def test_zone_normalize_validate_merge_and_render(tmp_path):
    zone = obby.normalize_zone({"zone": 2, "name": "Z", "palette": ["#ff8800", "nope", "00ff00"], "material": "wood",
                                "stages": [GOOD[1], GOOD[0], {"stage": 9, "pieces": [CP]}]}, 2, 1, 3)
    assert zone["palette"] == ["#FF8800", "#00FF00"] and zone["material"] == "Wood"
    assert [s["stage"] for s in zone["stages"]] == [1, 2, 9]
    assert obby.validate_zone(zone, 1, 3)[:2] == ["stage 3 is missing", "stage 9 is outside this zone's range 1-3"]
    assert obby.bad_stages(zone, 1, 3) == [3]
    fixed = obby.merge_stages(zone, {"stages": [GOOD[2]]})
    assert [s["stage"] for s in fixed["stages"]] == [1, 2, 3, 9]
    fixed["stages"] = fixed["stages"][:3]
    assert obby.validate_zone(fixed, 1, 3) == []
    fixed["name"] = 'Quote "zone"\nline'
    text = obby.render_zone_luau(fixed)
    assert text.startswith("-- Zone 2: Quote") and 'name = "Quote \\"zone\\"\\nline"' in text
    if LUAU:
        f = tmp_path / "Zone02.luau"
        f.write_text(text)
        r = subprocess.run([LUAU, "--null", str(f)], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr


def test_docs_for_the_level_designer_list_every_kind_and_limit():
    kinds = obby.kinds_doc()
    assert all(f"- {k}:" in kinds for k in obby.KINDS)
    assert "period 4 [2, 12]" in kinds and "Materials: SmoothPlastic" in kinds
    limits = obby.limits_doc()
    assert "rise 0: 10.0" in limits and "rise 6: 7.4" in limits and "jumppad" in limits


# ---------------------------------------------------------------- the same rules in Luau


def _kit_game(tmp_path: Path, zone: dict | None = None, server: str | None = None) -> Path:
    root = tmp_path / "game"
    for sub in ("ReplicatedStorage/Kit", "ReplicatedStorage/Levels", "ServerScriptService"):
        (root / sub).mkdir(parents=True, exist_ok=True)
    shutil.copy(KIT, root / KIT_PATH)
    shutil.copy(load_settings().base_game_dir / "ReplicatedStorage/ForgeTelemetry.luau",
                root / "ReplicatedStorage/ForgeTelemetry.luau")
    if zone is not None:
        (root / "ReplicatedStorage/Levels/Zone01.luau").write_text(obby.render_zone_luau(zone))
    if server:
        (root / "ServerScriptService/Obby.server.luau").write_text(server)
    return root


def _offline(root: Path, body: str) -> dict:
    res = checks.run_check_offline(root, checks.Check(id="t", title="t", covers="", body=body))
    assert res.get("ok"), res
    return json.loads(res["detail"])


@needs_luau
def test_kit_compiles():
    r = subprocess.run([LUAU, "--null", str(KIT)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


@needs_headless
def test_luau_validator_matches_python_message_for_message(tmp_path):
    zone = obby.normalize_zone({"zone": 1, "name": "Parity", "stages": PARITY}, 1, 1, 4)
    py = obby.validate_zone(zone, 1, 4)
    root = _kit_game(tmp_path, zone)
    lu = _offline(root, 'local K = require(game.ReplicatedStorage.Kit.ObbyKit)\n'
                        'local Z = require(game.ReplicatedStorage.Levels.Zone01)\n'
                        'return { ok = true, detail = game:GetService("HttpService"):JSONEncode('
                        'K.LevelBuilder.validateZone(Z, 1, 4)) }')
    assert len(py) >= 10 and lu == py


@needs_headless
def test_luau_v2_layout_matches_python_message_for_message(tmp_path):
    """Turned pads, logs, ramps and the body-aware crush rule: the same problems, word for word."""
    zone = obby.normalize_zone({"zone": 1, "name": "Parity v2", "stages": PARITY_V2}, 1, 1, 4)
    py = obby.validate_zone(zone, 1, 4)
    root = _kit_game(tmp_path, zone)
    lu = _offline(root, 'local K = require(game.ReplicatedStorage.Kit.ObbyKit)\n'
                        'local Z = require(game.ReplicatedStorage.Levels.Zone01)\n'
                        'return { ok = true, detail = game:GetService("HttpService"):JSONEncode('
                        'K.LevelBuilder.validateZone(Z, 1, 4)) }')
    assert lu == py == [
        "stage 1 piece 2 (platform): size length 9 out of range [2, 8]",
        "stage 1 piece 4 (platform): wedge-ramp climbs 6 over length 4; keep its height at most its length (45 degrees)",
        "stage 1 jump from the start pad to piece 1 (platform): gap 10.8 at rise 0.0 > max 10.0",
        "stage 1 jump from piece 2 (platform) to piece 3 (platform): gap 11.8 at rise 0.6 > max 9.8",
        "stage 1 piece 5 (lava): top 5.0 is above the floor around it (3.0); kill parts lie at floor level",
        "stage 2 turn 120 out of range [-90, 90]",
        "stage 2 jump from piece 2 (moving) to piece 3 (checkpoint): never in reach for 0.3s (closest: rise 7.0 > max 6.0)",
        "stage 2 piece 2 (moving) passes through piece 1 (platform)",
        "stage 3 jump from piece 2 (platform) to piece 3 (platform): gap 10.6 at rise 0.3 > max 9.9",
        "stage 4 piece 1 (platform) overlaps the start pad, whose corners reach 7.1 studs forward after the turn of 45: "
        "start it further out"]


@needs_headless
def test_luau_rules_and_kinds_are_the_python_ones(tmp_path):
    root = _kit_game(tmp_path)
    got = _offline(root, 'local K = require(game.ReplicatedStorage.Kit.ObbyKit)\n'
                         'return { ok = true, detail = game:GetService("HttpService"):JSONEncode('
                         '{ rules = K.Rules, kinds = K.Kinds, names = K.KindNames, common = K.Common }) }')
    for name in ("GRAVITY", "WALK_SPEED", "JUMP_HEIGHT", "EDGE_SLACK", "MAX_RISE", "RISE_MARGIN", "MIN_RISE", "MAX_GAP",
                 "MAX_LAUNCH_GAP", "LAUNCH_HOLD", "PAD_SIZE", "PAD_THICK", "MAX_SIDE", "MAX_STAGE_LENGTH", "MIN_PIECES",
                 "MAX_PIECES", "SAMPLE_DT", "SAMPLES", "MIN_RUN", "HOP_TIME", "CRUSH_HEIGHT", "BALL_CLEARANCE", "JUMP_SPEED",
                 "MAX_TURN", "LOG_MAX_DIAMETER", "LOG_STRIP", "LOG_DROP", "RAMP_MAX_CLIMB"):
        assert got["rules"][name] == pytest.approx(getattr(obby, name)), name
    assert got["names"] == list(obby.KINDS)
    assert [[c[0], c[1], c[2], c[3]] for c in got["common"]] == [[k, *v] for k, v in obby.COMMON.items()]
    for kind, spec in obby.KINDS.items():
        lk = got["kinds"][kind]
        assert lk["size"] == list(spec["size"]) and lk["min"] == list(spec["min"]) and lk["max"] == list(spec["max"]), kind
        assert bool(lk.get("round")) == bool(spec.get("round")) and lk.get("standable", True) == spec.get("standable", True)
        py_params = [[n, list(d[0]) if isinstance(d[0], tuple) else d[0], *d[1:]] for n, d in spec["params"].items()]
        assert (lk["params"] or []) == py_params, kind


@needs_headless
def test_kit_builds_the_course_headless_and_the_audit_reads_real_parts(tmp_path):
    zone = obby.normalize_zone({"zone": 1, "name": "Demo", "stages": GOOD}, 1, 1, 3)
    assert obby.validate_zone(zone, 1, 3) == []
    root = _kit_game(tmp_path, zone, 'require(game:GetService("ReplicatedStorage").Kit.ObbyKit).start()\n')
    rep = checks.boot_offline(root, play=1.0)
    assert rep.get("errors") == [] and rep.get("counters", {}).get("stages_built") == 3, rep
    body = """local CS = game:GetService("CollectionService")
local K = require(game.ReplicatedStorage.Kit.ObbyKit)
local before = K.LevelBuilder.audit()
local cp = nil
for _, c in CS:GetTagged("Checkpoint") do if c:GetAttribute("Stage") == 1 then cp = c end end
cp.CFrame = cp.CFrame * CFrame.new(0, 0, -15)
local p = game:GetService("Players"):GetPlayers()[1]
return { ok = true, detail = game:GetService("HttpService"):JSONEncode({ before = before, after = K.LevelBuilder.audit(),
  checkpoints = #CS:GetTagged("Checkpoint"), stages = workspace.Obby:GetAttribute("Stages"), coins = #CS:GetTagged("Coin"),
  kill = #CS:GetTagged("KillPart"), stage = p.leaderstats.Stage.Value, zone = p:GetAttribute("ZoneName"),
  saved = p:GetAttribute("SavedStage"), start = #CS:GetTagged("ObbyStart") }) }"""
    got = _offline(root, body)
    assert got["before"] == [] and got["checkpoints"] == 3 and got["stages"] == 3 and got["start"] == 1
    assert got["coins"] == 2 and got["kill"] == 3 and got["stage"] == 0 and got["zone"] == "Demo" and got["saved"] == 0
    assert any(e.startswith("stage 1 jump from piece 3 (platform) to piece 4 (checkpoint): gap 20.0") for e in got["after"])


PARK_ZONES = [
    {"zone": 1, "name": "Pony Parade", "theme_id": "carousel", "stages": [
        {"stage": 1, "pieces": [ROUND, {"kind": "moving", "gap": 4, "move": [4, 0, 0]}, CP]},
        {"stage": 2, "turn": 45, "pieces": [
            {"kind": "platform", "shape": "wedge-ramp", "gap": 4, "rise": 2, "size": [8, 2, 8]},
            {"kind": "platform", "shape": "cylinder", "gap": 4, "size": [10, 4, 4]}, dict(CP, gap=4)]}]},
    {"zone": 2, "name": "Gondola Heights", "theme_id": "ferris", "stages": [
        {"stage": 3, "turn": -90, "pieces": [BLOCK, {"kind": "trampoline", "gap": 4}, dict(CP, gap=4)]},
        {"stage": 4, "turn": 30, "pieces": [ROUND, {"kind": "jumppad", "gap": 4},
                                            {"kind": "platform", "gap": 6, "rise": 8, "size": [8, 1, 8]}, dict(CP, gap=4)]}]},
]
PARK_SERVER = """local K = require(game:GetService("ReplicatedStorage").Kit.ObbyKit)
local Themes = {}
function Themes.dress(kind, model, params, theme, rng)
	workspace:SetAttribute("DressCalls", (workspace:GetAttribute("DressCalls") or 0) + 1)
	workspace:SetAttribute("Dress_" .. kind, theme)
	local base = model:FindFirstChildWhichIsA("BasePart")
	local prop = Instance.new("Part")
	prop.Name, prop.Anchored, prop.CanCollide, prop.Size = "ThemeProp", true, true, Vector3.new(2, 2, 2)
	prop.CFrame = base.CFrame
	prop.Parent = model
	game:GetService("CollectionService"):AddTag(prop, "KillPart")
	assert(typeof(rng) == "Random" and params.kind == kind)
end
function Themes.stageDecor(stage, theme, rng, n)
	workspace:SetAttribute("DecorCalls", (workspace:GetAttribute("DecorCalls") or 0) + 1)
	if n == 3 then
		error("decor bug")
	end
end
K.start({ anchors = { [1] = CFrame.new(0, 40, 0), [2] = CFrame.new(400, 80, 0) * CFrame.Angles(0, math.rad(90), 0) },
	themes = Themes })
"""
PARK_INSPECT = """local CS = game:GetService("CollectionService")
local K = require(game.ReplicatedStorage.Kit.ObbyKit)
local out = { audit = K.LevelBuilder.audit(), stages = workspace.Obby:GetAttribute("Stages"),
	gates = workspace.Obby:GetAttribute("RideGates"), frames = {}, props = 0, badProps = 0,
	dress = workspace:GetAttribute("DressCalls"), decor = workspace:GetAttribute("DecorCalls"),
	dressPlatform = workspace:GetAttribute("Dress_platform"), dressTrampoline = workspace:GetAttribute("Dress_trampoline") }
for _, m in CS:GetTagged("ObbyStage") do
	local o = m:GetAttribute("Origin")
	out.frames[tostring(m:GetAttribute("Stage"))] = { turn = m:GetAttribute("Turn"), look = { o.LookVector.X, o.LookVector.Z },
		pos = { o.Position.X, o.Position.Y, o.Position.Z }, theme = m:GetAttribute("Theme") }
end
for _, d in workspace.Obby:GetDescendants() do
	if d.Name == "ThemeProp" then
		out.props += 1
		if d.CanCollide or d.CanTouch or d.CanQuery or not d.Massless or CS:HasTag(d, "KillPart") then
			out.badProps += 1
		end
	end
end
local gate = CS:GetTagged("RideGate")[1]
local zs = CS:GetTagged("ObbyZoneStart")[1]
out.gate = { stage = gate:GetAttribute("Stage"), nextZone = gate:GetAttribute("NextZone"),
	prompt = gate.RidePad.RidePrompt.ActionText, padTagged = CS:HasTag(gate.RidePad, "RideGatePad") }
out.zoneStart = { pos = { zs.Position.X, zs.Position.Y, zs.Position.Z }, after = zs:GetAttribute("AfterStage"),
	zone = zs:GetAttribute("Zone") }
local s = CS:GetTagged("ObbyStart")[1].Position
out.start = { s.X, s.Y, s.Z }
return game:GetService("HttpService"):JSONEncode(out)
"""
PARK_PLAYER = """local CS = game:GetService("CollectionService")
local K = require(game.ReplicatedStorage.Kit.ObbyKit)
local p = game:GetService("Players"):GetPlayers()[1]
local pad = CS:GetTagged("RideGate")[1].RidePad
local zs = CS:GetTagged("ObbyZoneStart")[1]
local function where()
	local r = p.Character.HumanoidRootPart.Position
	return { stage = K.getStage(p), saved = p:GetAttribute("SavedStage"), toZone2 = (r - zs.Position).Magnitude,
		toGate = (r - pad.Position).Magnitude, ride = p:GetAttribute("LastRide") }
end
local out = {}
K.setStage(p, 0)
p.Character:PivotTo(pad.CFrame * CFrame.new(0, 3, 0))
task.wait(1.6)
out.unearned = where()
p.Character:PivotTo(pad.CFrame * CFrame.new(0, 20, 30))
K.setStage(p, 1)
task.wait(1.6)
p.Character:PivotTo(pad.CFrame * CFrame.new(0, 3, 0))
task.wait(0.5)
out.touch = where()
K.respawn(p)
out.respawn = where()
p.Character:PivotTo(pad.CFrame * CFrame.new(7, 3, 0))
task.wait(1.6)
out.beside = where()
return game:GetService("HttpService"):JSONEncode(out)
"""
PARK_PROMPT = """local prompt = game:GetService("CollectionService"):GetTagged("RideGate")[1].RidePad.RidePrompt
task.wait(0.3)
prompt:InputHoldBegin() task.wait(0.2) prompt:InputHoldEnd()
task.wait(0.3)
return "pressed"
"""


@needs_headless
def test_kit_builds_zones_at_anchors_with_turns_themes_and_a_connected_ride_gate(tmp_path):
    import asyncio

    from forge import headless as hl

    root = _kit_game(tmp_path, None, PARK_SERVER)
    for z in PARK_ZONES:
        data = obby.normalize_zone(z, z["zone"], z["stages"][0]["stage"], 2, z["theme_id"])
        assert obby.validate_zone(data, z["stages"][0]["stage"], 2) == [], z["name"]
        (root / f"ReplicatedStorage/Levels/Zone{z['zone']:02d}.luau").write_text(obby.render_zone_luau(data))

    async def go():
        hs = hl.HeadlessStudio(root, players=1, idle=0.0)
        await hs.play()
        try:
            state = json.loads(await hs.execute_luau(PARK_INSPECT, "Server"))
            player = json.loads(await hs.execute_luau(PARK_PLAYER, "Server"))
            pressed = await hs.execute_luau(PARK_PROMPT, "Client")
            after = json.loads(await hs.execute_luau(
                'local K = require(game.ReplicatedStorage.Kit.ObbyKit)\nlocal p = game.Players:GetPlayers()[1]\n'
                'local zs = game:GetService("CollectionService"):GetTagged("ObbyZoneStart")[1]\n'
                'return game:GetService("HttpService"):JSONEncode({ stage = K.getStage(p), toZone2 = '
                '(p.Character.HumanoidRootPart.Position - zs.Position).Magnitude })', "Server"))
            report = await hs.probe_report()
            return state, player, pressed, after, report
        finally:
            await hs.stop()

    state, player, pressed, after, report = asyncio.run(go())
    assert state["audit"] == [] and state["stages"] == 4 and state["gates"] == 1, state
    # pads sit with their top on the anchor (Position is the center, half a stud lower)
    assert state["start"] == [0, 39.5, 0] and state["zoneStart"] == {"pos": [400, 79.5, 0], "after": 2, "zone": 2}
    f = state["frames"]
    assert [f[k]["turn"] for k in "1234"] == [0, 45, -90, 30] and f["1"]["theme"] == "carousel" and f["3"]["theme"] == "ferris"
    assert f["1"]["look"] == pytest.approx([0, -1], abs=1e-6)
    assert f["2"]["look"] == pytest.approx([2 ** -0.5, -(2 ** -0.5)], abs=1e-6)  # 45 right of the course
    assert f["3"]["pos"] == pytest.approx([400, 80, 0]) and f["3"]["look"] == pytest.approx([0, 1], abs=1e-6)  # anchor -90
    assert state["gate"] == {"stage": 2, "nextZone": 2, "prompt": "Ride to Gondola Heights", "padTagged": True}
    assert state["dress"] == 13 and state["decor"] == 4 and state["props"] == 13 and state["badProps"] == 0
    assert state["dressPlatform"] == "ferris" and state["dressTrampoline"] == "ferris"
    assert player["unearned"]["stage"] == 0 and player["unearned"]["toGate"] < 5  # stage 0 can't ride zone 1's gate
    assert player["touch"]["stage"] == 2 and player["touch"]["saved"] == 2 and player["touch"]["ride"] == 2
    assert player["touch"]["toZone2"] < 5 and player["respawn"]["toZone2"] < 5  # stage 2 respawns on zone 2's start
    assert player["beside"]["toGate"] < 9  # standing beside the pad does not ride
    assert pressed == "pressed" and after["stage"] == 2 and after["toZone2"] < 5  # the prompt rides too
    assert report["errors"] == [] and report["counters"].get("ride_gate_used") == 2, report


WORLD_SERVER = """local K = require(game:GetService("ReplicatedStorage").Kit.ObbyKit)
local function part(name, size, cf, class)
	local p = Instance.new(class or "Part")
	p.Name, p.Anchored, p.Size, p.CFrame = name, true, size, cf
	p.Parent = workspace
	return p
end
part("Ground", Vector3.new(2000, 2, 2000), CFrame.new(0, -1, 0))
part("Tower", Vector3.new(6, 79, 6), CFrame.new(400, 39.5, 0)) -- zone 2's start pad sits on it, like WorldKit's
part("ParkSpawn", Vector3.new(12, 1, 12), CFrame.new(0, 0.5, 300), "SpawnLocation")
K.start({ anchors = { [1] = CFrame.new(0, 40, 0), [2] = CFrame.new(400, 80, 0) * CFrame.Angles(0, math.rad(90), 0) },
	gates = { [1] = CFrame.new(-60, 0.4, 300), [2] = CFrame.new(60, 0.4, 300) }, spawn = CFrame.new(0, 1, 300) })
"""
WORLD_PLAYER = """local CS = game:GetService("CollectionService")
local K = require(game.ReplicatedStorage.Kit.ObbyKit)
local p = game:GetService("Players"):GetPlayers()[1]
local gate = CS:GetTagged("RideEntrance")[1]
local start = CS:GetTagged("ObbyStart")[1]
local zs = CS:GetTagged("ObbyZoneStart")[1]
local cp3 = nil
for _, c in CS:GetTagged("Checkpoint") do if c:GetAttribute("Stage") == 3 then cp3 = c end end
local function at()
	local r = p.Character.HumanoidRootPart.Position
	return { lobby = (r - Vector3.new(0, 1, 300)).Magnitude, start = (r - start.Position).Magnitude,
		zone2 = (r - zs.Position).Magnitude, gate = (r - gate.EntrancePad.Position).Magnitude, cp3 = (r - cp3.Position).Magnitude,
		stage = K.getStage(p), notice = p:GetAttribute("RideNotice"), ride = p:GetAttribute("LastRide"),
		onCourse = p:GetAttribute("OnCourse") == true }
end
local out = { spawned = at() }
K.respawn(p)
out.respawn = at()
p.Character:PivotTo(gate.EntrancePad.CFrame * CFrame.new(0, 3, 0))
task.wait(1.6)
out.locked = at()
out.lockedGui = p.PlayerGui:FindFirstChild("ObbyNotice") ~= nil
local function step()
	p.Character:PivotTo(gate.EntrancePad.CFrame * CFrame.new(0, 3, 20))
	task.wait(1.6)
	p.Character:PivotTo(gate.EntrancePad.CFrame * CFrame.new(0, 3, 0))
	task.wait(0.6)
end
K.setStage(p, 2)
step()
out.ride = at()
K.setStage(p, 3)
step()
out.inside = at()
K.setStage(p, 0)
K.respawn(p)
out.afterCourse = at()
out.gate = { zone = gate:GetAttribute("Zone"), stage = gate:GetAttribute("Stage"), last = gate:GetAttribute("LastStage"),
	from = gate:GetAttribute("FromZoneName"), prompt = gate.EntrancePad.RidePrompt.ActionText,
	padTagged = CS:HasTag(gate.EntrancePad, "RideEntrancePad"), n = #CS:GetTagged("RideEntrance") }
local supports, bad, tops = 0, 0, {}
for _, s in workspace.Obby.Supports:GetChildren() do
	if s.Name == "Support" then
		supports += 1
		table.insert(tops, s.Position.Y + s.Size.X / 2)
	end
	if s.CanCollide or s.CanTouch or s.CanQuery then
		bad += 1
	end
end
table.sort(tops)
out.supports = { n = supports, attr = workspace.Obby:GetAttribute("Supports"), bad = bad, tops = tops,
 }
local st = workspace.Obby.Stages.Stage001
out.colors = { st["01_platform"].Platform.Color:ToHex(), st["02_moving"].Mover.Color:ToHex() }
out.underZone2 = #workspace.Obby.Supports:GetChildren()
return game:GetService("HttpService"):JSONEncode(out)
"""


@needs_headless
def test_kit_in_a_world_spawns_in_the_lobby_rides_ground_gates_and_stands_on_supports(tmp_path):
    import asyncio

    from forge import headless as hl

    root = _kit_game(tmp_path, None, WORLD_SERVER)
    for z in PARK_ZONES:
        data = obby.normalize_zone(dict(z, palette=list(obby.THEME_PALETTES[z["theme_id"]])), z["zone"],
                                   z["stages"][0]["stage"], 2, z["theme_id"])
        (root / f"ReplicatedStorage/Levels/Zone{z['zone']:02d}.luau").write_text(obby.render_zone_luau(data))

    async def go():
        hs = hl.HeadlessStudio(root, players=1, idle=0.0)
        await hs.play()
        try:
            got = json.loads(await hs.execute_luau(WORLD_PLAYER, "Server"))
            return got, await hs.probe_report()
        finally:
            await hs.stop()

    got, report = asyncio.run(go())
    assert got["spawned"]["lobby"] < 6 and got["spawned"]["start"] > 250 and not got["spawned"]["onCourse"]  # new: lobby
    assert got["respawn"]["lobby"] < 6  # a stage-0 player who never reached the course respawns in the lobby
    assert got["locked"]["gate"] < 5 and got["locked"]["notice"] == "Finish Pony Parade first" and got["lockedGui"]
    assert got["ride"]["zone2"] < 5 and got["ride"]["ride"] == 2 and got["ride"]["onCourse"]  # zone 1 done: ride up
    assert got["inside"]["cp3"] < 6 and got["inside"]["stage"] == 3  # inside zone 2: back to their own checkpoint
    assert got["afterCourse"]["start"] < 5  # once on the course, a stage-0 respawn is the start pad again
    assert got["gate"] == {"zone": 2, "stage": 2, "last": 4, "from": "Pony Parade", "prompt": "Ride to Gondola Heights",
                           "padTagged": True, "n": 1}  # zone 1's gate (at the START stairs in a park) gets none
    sup = got["supports"]
    # zone 1's start pad, checkpoints 1-4 and the ride gate's pad; zone 2's start pad stands on its tower: none
    assert sup["n"] == sup["attr"] == 6 and sup["bad"] == 0 and 79 - 0.5 not in sup["tops"]
    assert sup["tops"] == [39, 39, 41, 41, 79, 87]  # each column reaches up to its pad's underside
    carousel = [c.lstrip("#").lower() for c in obby.THEME_PALETTES["carousel"]]
    assert got["colors"] == [carousel[0], carousel[2]]  # piece 2's colours rotate: its mover takes the highlight
    assert report["errors"] == [] and report["counters"].get("ride_entrance_used") == 2, report
    assert report["counters"].get("ride_entrance_locked") == 1, report


# ---------------------------------------------------------------- kit modules (director)


def test_index_entries_have_the_schema_and_their_files():
    entries = director.kit_index()
    assert entries and len({e["name"] for e in entries}) == len(entries)
    for e in entries:
        assert set(e) >= {"name", "path_in_game", "genres", "keywords", "describe", "api"}
        assert (director.KIT_MODULES_DIR / f"{e['name']}.luau").exists()
        assert e["path_in_game"].startswith("ReplicatedStorage/") and e["path_in_game"].endswith(".luau")


def test_kit_modules_match_by_genre_or_keyword_only(monkeypatch):
    names = lambda t: [e["name"] for e in director.match_kit_modules(t)]  # noqa: E731
    kits = ["ObbyKit", "ObbyThemes"]
    assert names("An amusement-park obby with 200 stages") == kits
    assert names("a parkour climb") == kits and names("checkpoints every few stages, then a finish") == kits
    assert names("A co-op tower defence: waves walk a path") == [] and names("a cube tycoon") == []
    extra = {"name": "Music", "path_in_game": "ReplicatedStorage/Kit/Music.luau", "genres": ["*"], "keywords": [],
             "describe": "music", "api": []}
    real = director.kit_index()
    monkeypatch.setattr(director, "kit_index", lambda: (*real, extra))
    assert names("a cube tycoon") == ["Music"]
    monkeypatch.setattr(director, "kit_index", lambda: real)
    # music and costumes come only from the words for them, never from the genre alone
    assert names("An obby with music and lobby costumes") == [*kits, "MusicPlayer", "Cosmetics", "CosmeticsClient"]


OBBY_DOC = {"fantasy": "Run a giant amusement park obby", "core_loop": "jump -> checkpoint -> next zone",
            "systems": [], "juice": [], "first_60_seconds": [], "visual_style": {"palette": ["#FF8A65"]},
            "sounds": [], "module_budget": 5, "acceptance": []}


def _obby_spec() -> dict:
    return {"title": "Park Obby", "slug": "park-obby", "pitch": "p", "core_loop": "c",
            "modules": [{"path": KIT_PATH, "purpose": "my own copy", "depends": []},
                        {"path": "ServerScriptService/Obby.server.luau", "purpose": "ObbyKit.start()",
                         "depends": [KIT_PATH]},
                        {"path": "StarterPlayerScripts/Hud.client.luau", "purpose": "stage HUD", "depends": [KIT_PATH]}],
            "acceptance": ["stages exist"]}


def test_designer_learns_the_kit_and_the_spec_lists_it_prebuilt():
    llm = FakeLLM({"director": [json.dumps(OBBY_DOC)], "designer": [json.dumps(_obby_spec())]})
    spec = director.plan(llm, "an obby with 40 stages", "", session_id="g")
    designer = llm.calls[1].user
    assert f"`{KIT_PATH}` is PREBUILT (ObbyKit:" in designer and "do NOT plan modules that re-implement" in designer
    paths = [m["path"] for m in spec["modules"]]
    assert paths[:2] == [director.GAME_ASSETS, KIT_PATH] and paths.count(KIT_PATH) == 1
    kit = spec["modules"][1]
    assert kit["prebuilt"] and kit["kit"] == "ObbyKit" and kit["purpose"].startswith("PREBUILT kit module ObbyKit")
    assert KIT_PATH in next(m for m in spec["modules"] if m["path"].endswith("Obby.server.luau"))["depends"]
    assert director.kit_modules_in(spec)[0]["name"] == "ObbyKit"


def _spec_with_kit(levels: dict | None = None) -> dict:
    spec = {"title": "Park Obby", "modules": [director.kit_module(director.kit_index()[0]),
                                              {"path": "ServerScriptService/Obby.server.luau", "purpose": "boot",
                                               "depends": [KIT_PATH]}], "acceptance": []}
    if levels:
        spec["levels"] = levels
    return spec


@needs_luau
def test_install_kit_copies_the_kit_and_its_genre_checks(tmp_path):
    game = tmp_path / "runs" / "g" / "game"
    spec = _spec_with_kit({"zones": 10, "stages_per_zone": 20})
    assert director.install_kit(spec, game) == [KIT_PATH]
    assert (game / KIT_PATH).read_text() == KIT.read_text()
    found = checks.load_checks(game.parent)
    assert {c.id for c in found} == {p.stem for p in (director.GENRE_CHECKS_DIR / "obby").glob("*.luau")}
    sources = checks.game_sources(game)
    for c in found:
        assert "__EXPECTED_STAGES__" not in c.body and c.title and c.covers.startswith("genre obby:")
        consumer = checks.valid_consumer(game, c.body.split("-- consumer:", 1)[1].splitlines()[0], sources)
        assert consumer and consumer.startswith(KIT_PATH + ":"), c.id
        f = tmp_path / f"{c.id}.luau"
        f.write_text(checks.wrap(c.body))
        r = subprocess.run([LUAU, "--null", str(f)], capture_output=True, text=True)
        assert r.returncode == 0, (c.id, r.stdout + r.stderr)
    count = next(c for c in found if c.id == "obby-stage-count")
    assert "local expected = 200" in count.body
    assert {c.id for c in found if "irreversible" in c.covers} == {
        "obby-checkpoint-saves-and-respawns", "obby-coins-collectible", "obby-ride-gates"}
    assert {c.id for c in found if c.needs != "studio"} == {
        "obby-stage-count", "obby-checkpoint-per-stage", "obby-reachability"}  # the rest need real physics


def test_genre_check_waits_fit_the_execute_luau_limit():
    """Live, a check that waited 15+6+8+15+1.5 s timed out at the 30 s execute_luau limit; keep every check's
    worst-case waits well under it."""
    import re

    for f in sorted((director.GENRE_CHECKS_DIR / "obby").glob("*.luau")):
        text = f.read_text()
        waits = [float(x) for x in re.findall(r"^end, (\d+(?:\.\d+)?)\)", text, re.MULTILINE)]
        waits += [float(x) for x in re.findall(r"^task\.wait\((\d+(?:\.\d+)?)\)", text, re.MULTILINE)]
        assert sum(waits) <= 0.75 * checks.CHECK_TIMEOUT, (f.name, waits)


def test_consumer_marker_that_is_not_in_the_kit_fails_loudly(tmp_path):
    game = tmp_path / "game"
    (game / "ReplicatedStorage/Kit").mkdir(parents=True)
    shutil.copy(KIT, game / KIT_PATH)
    with pytest.raises(ValueError, match="not found"):
        director.resolve_consumers(f'-- consumer: {KIT_PATH}:"no such line anywhere"\n', game)


def test_genre_checks_for_a_kit_the_game_lacks_are_skipped(tmp_path, monkeypatch):
    """A future module that shares the obby genre (say cosmetics for obby and tycoon games) must not drag the
    ObbyKit checks into a game without ObbyKit."""
    other = {"name": "Cosmetics", "path_in_game": "ReplicatedStorage/Kit/Cosmetics.luau", "genres": ["obby", "tycoon"],
             "keywords": [], "describe": "trails", "api": []}
    real = director.kit_index()
    monkeypatch.setattr(director, "kit_index", lambda: (*real, other))
    game = tmp_path / "runs" / "g" / "game"
    (game / "ReplicatedStorage/Kit").mkdir(parents=True)
    spec = {"modules": [director.kit_module(other)]}
    assert director.install_genre_checks(spec, game) == []
    assert not (game.parent / "checks").exists()


def test_coder_message_lists_the_kit_api_not_its_source():
    spec = _spec_with_kit()
    llm = FakeLLM({"coder": ["```luau\nreturn {}\n```"]})
    roles.code_module(llm, spec, spec["modules"][1], {KIT_PATH: KIT.read_text()}, "", session_id="g")
    user = llm.calls[0].user
    assert "## Prebuilt kit modules" in user and "ObbyKit.start(opts?)" in user and "ObbyKit.onFinish" in user
    assert f"### {KIT_PATH}\n```luau" not in user and "local function normalizePiece" not in user
    assert "Prebuilt kit modules (require them" in director.coder_notes(spec, "- lesson")
    assert director.coder_notes({"modules": []}, "x") == "x"


@pytest.fixture
def settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


def test_fixer_never_gets_kit_or_level_files(settings):
    store = RunStore(settings, "g")
    store.ensure()
    (store.game_dir / obby.LEVELS_DIR).mkdir(parents=True)
    (store.game_dir / obby.LEVELS_DIR / "Zone01.luau").write_text("return {}\n")
    run = Run(settings, store, FakeLLM({}), UI(io.StringIO()))
    run.spec = _spec_with_kit()
    try:
        assert {KIT_PATH, f"{obby.LEVELS_DIR}/Zone01.luau"} <= run.base_files
        assert not run._fixable(KIT_PATH) and run._fixable("ServerScriptService/Obby.server.luau")
    finally:
        run.close()


# ---------------------------------------------------------------- the obby checklist


def test_obby_genre_and_checklist_scan_skips_the_kit(tmp_path):
    assert gaps.detect_genre({"title": "Funfair Frenzy", "pitch": "an amusement park obby"}) == "obby"
    assert gaps.detect_genre({"pitch": "beat 50 stages, a checkpoint on each"}) == "obby"
    assert gaps.detect_genre({"pitch": "a tower defence"}) == "generic"
    assert gaps.detect_genre({"pitch": "an obby tycoon"}) == "tycoon"
    game = tmp_path / "game"
    (game / "ReplicatedStorage/Kit").mkdir(parents=True)
    shutil.copy(KIT, game / KIT_PATH)
    assert gaps.game_sources(game) == {}
    scan = {i["id"]: i["present"] for i in gaps.scan_checklist("obby", gaps.game_sources(game))}
    assert set(scan) == {i["id"] for i in gaps.CHECKLISTS["obby"]} and not any(scan.values())
    (game / "ServerScriptService").mkdir()
    (game / "ServerScriptService/Obby.server.luau").write_text("ObbyKit.start({})\nObbyKit.onFinish(function() end)\n")
    scan = {i["id"]: i["present"] for i in gaps.scan_checklist("obby", gaps.game_sources(game))}
    assert scan["course_built"] and scan["finish_celebration"] and not scan["music_per_zone"]


def test_obby_lessons_cover_long_courses_and_fit_the_designer_budget():
    text = director.genre_lessons("an obby with 200 stages")
    assert "obby best practices" in text and "Zones of ~20 stages" in text and "tycoon" not in text.lower()
    assert len(text) < 4000  # the designer's lessons budget: curated obby + fun lessons must fit
