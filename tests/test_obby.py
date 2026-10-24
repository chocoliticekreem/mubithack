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
def test_luau_rules_and_kinds_are_the_python_ones(tmp_path):
    root = _kit_game(tmp_path)
    got = _offline(root, 'local K = require(game.ReplicatedStorage.Kit.ObbyKit)\n'
                         'return { ok = true, detail = game:GetService("HttpService"):JSONEncode('
                         '{ rules = K.Rules, kinds = K.Kinds, names = K.KindNames, common = K.Common }) }')
    for name in ("GRAVITY", "WALK_SPEED", "JUMP_HEIGHT", "EDGE_SLACK", "MAX_RISE", "RISE_MARGIN", "MIN_RISE", "MAX_GAP",
                 "MAX_LAUNCH_GAP", "LAUNCH_HOLD", "PAD_SIZE", "PAD_THICK", "MAX_SIDE", "MAX_STAGE_LENGTH", "MIN_PIECES",
                 "MAX_PIECES", "SAMPLE_DT", "SAMPLES", "MIN_RUN", "HOP_TIME", "CRUSH_HEIGHT", "BALL_CLEARANCE", "JUMP_SPEED"):
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
    # a park-themed obby gets the ParkObby template (the tested wiring) by its keywords, plus every kit it requires
    park = set(names("An amusement-park obby with 200 stages"))
    requires = next(e for e in director.kit_index() if e["name"] == "ParkObby")["requires"]
    assert park == {"ParkObby", *requires}
    # ParkObby is for obbies only: a funfair tycoon never gets the obby template
    assert "ParkObby" not in names("a funfair tycoon")
    assert names("a parkour climb") == ["ObbyKit"] and names("checkpoints every few stages, then a finish") == ["ObbyKit"]
    assert names("A co-op tower defence: waves walk a path") == [] and names("a cube tycoon") == []
    extra = {"name": "Music", "path_in_game": "ReplicatedStorage/Kit/Music.luau", "genres": ["*"], "keywords": [],
             "describe": "music", "api": []}
    real = director.kit_index()
    monkeypatch.setattr(director, "kit_index", lambda: (*real, extra))
    assert names("a cube tycoon") == ["Music"]
    monkeypatch.setattr(director, "kit_index", lambda: real)
    # music and costumes come only from the words for them, never from the genre alone
    assert names("An obby with music and lobby costumes") == ["ObbyKit", "MusicPlayer", "Cosmetics", "CosmeticsClient"]


OBBY_DOC = {"fantasy": "Run a giant candy obby", "core_loop": "jump -> checkpoint -> next zone",
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
        "obby-checkpoint-saves-and-respawns", "obby-coins-collectible"}
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
