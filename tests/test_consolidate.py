"""forge consolidate: the module map, plan validation (no kit / level / runtime paths, no dangling requires),
execution, and the gate's keep / roll back, all with a FakeLLM and a fake Studio."""
from __future__ import annotations

import dataclasses
import io
import json
import re
import shutil
from pathlib import Path

import pytest

from forge import consolidate as cs
from forge import scenarios
from forge.config import load_settings
from forge.llm import ROLES, FakeLLM, load_prompt
from forge.loop import UI
from forge.memory import RunStore
from forge.versions import GameVersions

REPO = Path(__file__).resolve().parent.parent
needs_luau = pytest.mark.skipif(shutil.which("luau-compile") is None, reason="luau-compile not on PATH")
SLUG = "fair"

GAME = {
    "ServerScriptService/Game.server.luau": """-- Game: boots the lobby and the effects
local ServerScriptService = game:GetService("ServerScriptService")
local Telemetry = require(game:GetService("ReplicatedStorage"):WaitForChild("ForgeTelemetry"))
local Fx = require(ServerScriptService:WaitForChild("Fx"))
Fx.init()
Telemetry.count("game_started", 1)
""",
    "ServerScriptService/Fx.luau": """-- Fx: death and jump pad effects for clients
local M = {}
function M.init() end
function M.burst(player) end
return M
""",
    "ServerScriptService/Juice.luau": """-- Juice: coin effects for clients
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local M = {}
function M.coin(player)
	local r = Instance.new("RemoteEvent")
	r.Name = "JuiceRemote"
	r.Parent = ReplicatedStorage
end
return M
""",
    "ServerScriptService/Progress.luau": """-- Progress: coins and stages
local ServerScriptService = game:GetService("ServerScriptService")
local Juice = nil
local mod = ServerScriptService:WaitForChild("Juice", 5)
if mod then
	Juice = require(mod)
end
local M = {}
function M.coin(player)
	Juice.coin(player)
end
return M
""",
    "ServerScriptService/PingAck.server.luau": """-- PingAck: counts a client HUD pop
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry"))
local REMOTE_NAME = "PingAck"
local remote = Instance.new("RemoteEvent")
remote.Name = REMOTE_NAME
remote.Parent = ReplicatedStorage
remote.OnServerEvent:Connect(function(player)
	Telemetry.count("hud_pop", 1)
end)
""",
    "StarterPlayerScripts/Hud.client.luau": """-- Hud: the coin counter
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local scripts = script.Parent
local m = scripts and scripts:WaitForChild("HudFx", 10)
local HudFx = require(m)
HudFx.pop()
local ack = ReplicatedStorage:WaitForChild("PingAck", 5)
if ack then ack:FireServer() end
""",
    "StarterPlayerScripts/HudFx.luau": """-- HudFx: pops the coin counter
local M = {}
function M.pop() end
return M
""",
    "ReplicatedStorage/Config.luau": "-- Config: numbers\nreturn { COINS = 3 }\n",
    "ReplicatedStorage/HudConfig.luau": '-- HudConfig: names\nreturn { RemoteName = "PingAck" }\n',
    "ReplicatedStorage/Kit/ObbyKit.luau": "-- ObbyKit: the kit\nreturn {}\n",
    "ReplicatedStorage/Levels/Zone01.luau": "-- Zone01: level data\nreturn {}\n",
    "ReplicatedStorage/GameAssets.luau": "-- GameAssets: art kit\nreturn {}\n",
}
CHECK = "-- check: the course builds\n-- covers: acceptance: stages\nreturn { ok = true, detail = 'fine' }\n"


@pytest.fixture
def game(tmp_path, monkeypatch):
    monkeypatch.setattr(scenarios, "SETTLE_S", 0.0)
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")
    store = RunStore(s, SLUG)
    store.ensure()
    store.save_spec({"title": "Fair", "pitch": "an obby", "core_loop": "jump",
                     "modules": [{"path": p, "purpose": "x", "depends": []} for p in GAME if "/Kit/" not in p]
                     + [{"path": "ReplicatedStorage/Kit/ObbyKit.luau", "prebuilt": True, "kit": "ObbyKit"}],
                     "features": [{"request": "make pickups juicy"}]})
    store.save_state(store.new_state("idea"))
    for rel, text in GAME.items():
        p = store.game_dir / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    for rel in ("ReplicatedStorage/ForgeTelemetry.luau", "ServerScriptService/ForgeProbe.server.luau"):
        (store.game_dir / rel).write_text((REPO / "game" / rel).read_text())
    (store.dir / "checks").mkdir()
    (store.dir / "checks" / "01-builds.luau").write_text(CHECK)
    GameVersions(store.game_dir).snapshot("v1: built")
    return s, store


def _rows(store):
    spec = store.load_spec()
    prot = cs.protected_paths(spec, store.game_dir)
    return prot, cs.module_map(store.game_dir, prot)


# ------------------------------------------------------------------------------------- map + references


def test_module_map_resolves_requires_callers_remotes_counters_and_dead_code(game):
    _, store = game
    prot, rows = _rows(store)
    by = {r["path"]: r for r in rows}
    assert "ReplicatedStorage/Kit/ObbyKit.luau" not in by and "ReplicatedStorage/GameAssets.luau" not in by
    assert "ReplicatedStorage/Levels/Zone01.luau" not in by and "ReplicatedStorage/ForgeTelemetry.luau" not in by
    assert by["ServerScriptService/Fx.luau"]["required_by"] == ["ServerScriptService/Game.server.luau"]
    # a local assigned from a lookup and required two lines later is a require
    assert by["ServerScriptService/Juice.luau"]["required_by"] == ["ServerScriptService/Progress.luau"]
    assert by["StarterPlayerScripts/HudFx.luau"]["required_by"] == ["StarterPlayerScripts/Hud.client.luau"]
    assert by["ServerScriptService/PingAck.server.luau"]["remotes"]["creates"] == ["PingAck"]
    assert by["ServerScriptService/PingAck.server.luau"]["counters"] == ["hud_pop"]
    assert by["ServerScriptService/Juice.luau"]["functions"] == ["M.coin"]
    assert by["ReplicatedStorage/Config.luau"]["unused"] is True  # nothing requires or names it
    assert by["ServerScriptService/Fx.luau"]["unused"] is False
    text = cs.map_text(rows)
    assert "NOTHING requires or names it" in text and "creates remotes PingAck" in text


def test_dangling_finds_lookups_of_modules_that_are_gone(tmp_path):
    for rel, text in {
        "StarterPlayerScripts/Controllers/HudController.luau":
            'local m = script.Parent:WaitForChild("HudFx", 10)\nlocal H = require(m)\n'
            'local ok = require(script.Parent.Parent:WaitForChild("HudFx"))\n'
            'local ps = game:GetService("Players").LocalPlayer:WaitForChild("PlayerScripts")\n'
            'local P = require(ps:WaitForChild("PlayerModule"))\n'
            '-- require(script.Parent:WaitForChild("Gone"))\n',
        "StarterPlayerScripts/HudFx.luau": "return {}\n",
        "ServerScriptService/A.luau": 'local SSS = game:GetService("ServerScriptService")\n'
                                      'local B = require(SSS:WaitForChild("B"))\nlocal remote = '
                                      'game:GetService("ReplicatedStorage"):WaitForChild("Remote")\n',
    }.items():
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / rel).write_text(text)
    got = sorted((r["file"], r["target"]) for r in cs.dangling(tmp_path, set()))
    # script.Parent of a controller is the Controllers folder; PlayerModule is Roblox's; comments and
    # lookups nobody requires (a remote) never count
    assert got == [("ServerScriptService/A.luau", "ServerScriptService/B"),
                   ("StarterPlayerScripts/Controllers/HudController.luau", "StarterPlayerScripts/Controllers/HudFx")]


# ------------------------------------------------------------------------------------- validation

def _plan(**over):
    raw = {"summary": "one feedback system", "merges": [], "server_bootstrap": [], "client_bootstrap": [],
           "delete": [], "rewire": []}
    raw.update(over)
    return raw


def test_validation_refuses_prebuilt_runtime_and_bootstrap_paths(game):
    _, store = game
    prot, rows = _rows(store)
    raw = _plan(merges=[
        {"into": "ServerScriptService/AllFx.luau", "from": ["ServerScriptService/Fx.luau", "ReplicatedStorage/Kit/ObbyKit.luau"]},
        {"into": "ReplicatedStorage/Levels/Zone01.luau", "from": ["ReplicatedStorage/Config.luau", "ReplicatedStorage/HudConfig.luau"]},
        {"into": "ServerScriptService/Main.server.luau", "from": ["ServerScriptService/Fx.luau", "ServerScriptService/Juice.luau"]},
        {"into": "ReplicatedStorage/X.luau", "from": ["ReplicatedStorage/GameAssets.luau", "ReplicatedStorage/ForgeTelemetry.luau"]},
    ], delete=[{"path": "ServerScriptService/ForgeProbe.server.luau"}, {"path": "tools/sync.py"}])
    plan, problems = cs.validate(raw, store.game_dir, prot, rows)
    assert plan["units"] == [] and plan["delete"] == []
    text = "\n".join(problems)
    for p in ("ObbyKit", "Zone01", "GameAssets", "ForgeTelemetry", "ForgeProbe"):
        assert re.search(rf"{p}[\w.]*\.luau is prebuilt", text), p  # the architect learns why, not just "no"
    assert "Main.server.luau is the bootstrap path" in text


def test_validation_keeps_sides_apart_budget_one_owner_and_the_cap(game):
    _, store = game
    prot, rows = _rows(store)
    big = store.game_dir / "ServerScriptService/Big.luau"
    big.write_text("-- Big\nlocal M = {}\n" + "local x = 1\n" * 2000 + "return M\n")
    prot, rows = _rows(store)
    raw = _plan(
        merges=[
            {"into": "ServerScriptService/Services/FxService.luau", "from": ["ServerScriptService/Fx.luau", "ServerScriptService/Juice.luau"]},
            {"into": "ServerScriptService/Mixed.luau", "from": ["ServerScriptService/Progress.luau", "StarterPlayerScripts/HudFx.luau"]},
            {"into": "ServerScriptService/Huge.luau", "from": ["ServerScriptService/Big.luau", "ServerScriptService/Progress.luau"]},
            {"into": "ServerScriptService/Again.luau", "from": ["ServerScriptService/Fx.luau", "ServerScriptService/Progress.luau"]},
            {"into": "ServerScriptService/Progress.luau", "from": ["ServerScriptService/Big.luau"]},
            {"into": "ReplicatedStorage/AllConfig.luau", "from": ["ReplicatedStorage/Config.luau", "ReplicatedStorage/HudConfig.luau"]},
        ],
        server_bootstrap=[{"from": "ServerScriptService/Progress.luau", "into": "ServerScriptService/Services/ProgressService.luau"},
                          {"from": "ServerScriptService/Game.server.luau", "into": "ServerScriptService/GameService.luau"},
                          {"from": "ServerScriptService/Game.server.luau", "into": "ServerScriptService/Services/GameService.luau"}],
        client_bootstrap=[{"from": "StarterPlayerScripts/Hud.client.luau", "into": "StarterPlayerScripts/Controllers/HudController.luau"}])
    plan, problems = cs.validate(raw, store.game_dir, prot, rows, max_merges=3)
    assert [(u["kind"], u["into"]) for u in plan["units"]] == [
        ("service", "ServerScriptService/Services/FxService.luau"),
        ("merge", "ReplicatedStorage/AllConfig.luau"),
        ("service", "ServerScriptService/Services/GameService.luau")]
    text = "\n".join(problems)
    assert "keep one side" in text and "budget" in text and "already used by another entry" in text
    assert "needs two or more files" in text and "is not a .server.luau script" in text
    assert "must be ServerScriptService/Services/<Name>Service.luau" in text
    assert "over the limit of 3" in text  # the client controller came fourth


def test_validation_rewires_every_caller_of_a_removed_module(game):
    _, store = game
    prot, rows = _rows(store)
    raw = _plan(merges=[{"into": "ServerScriptService/Services/FxService.luau",
                         "from": ["ServerScriptService/Fx.luau", "ServerScriptService/Juice.luau"]}],
                delete=[{"path": "StarterPlayerScripts/HudFx.luau", "why": "dead"}])
    plan, problems = cs.validate(raw, store.game_dir, prot, rows)
    rewired = {r["path"]: r["change"] for r in plan["rewire"]}
    assert set(plan["auto_rewire"]) == {"ServerScriptService/Game.server.luau", "ServerScriptService/Progress.luau",
                                         "StarterPlayerScripts/Hud.client.luau"}
    assert "require ServerScriptService/Services/FxService.luau instead" in rewired["ServerScriptService/Progress.luau"]
    assert "deleted" in rewired["StarterPlayerScripts/Hud.client.luau"]


def test_validation_names_files_that_still_use_a_deleted_remote(game):
    _, store = game
    prot, rows = _rows(store)
    plan, problems = cs.validate(_plan(delete=[{"path": "ServerScriptService/PingAck.server.luau"}]),
                                 store.game_dir, prot, rows)
    assert [d["path"] for d in plan["delete"]] == ["ServerScriptService/PingAck.server.luau"]
    hit = [p for p in problems if "remote PingAck" in p]
    assert {p.split(" ", 1)[0] for p in hit} == {"ReplicatedStorage/HudConfig.luau", "StarterPlayerScripts/Hud.client.luau"}
    plan, problems = cs.validate(_plan(delete=[{"path": "ServerScriptService/PingAck.server.luau"}],
                                       rewire=[{"path": "StarterPlayerScripts/Hud.client.luau", "change": "count directly"},
                                               {"path": "ReplicatedStorage/HudConfig.luau", "change": "drop the name"}]),
                                 store.game_dir, prot, rows)
    assert problems == []


def test_architect_is_a_registered_role_with_a_fixed_prompt():
    assert "architect" in ROLES
    text = load_prompt("architect")
    assert "server_bootstrap" in text and "Services" in text and "never merge, move" in text


# ------------------------------------------------------------------------------------- the pass

ARCH_PLAN = {
    "summary": "one server effects service, the HUD as a controller, no ack script",
    "merges": [{"into": "ServerScriptService/Services/FxService.luau",
                "from": ["ServerScriptService/Fx.luau", "ServerScriptService/Juice.luau"],
                "purpose": "every client effect; keeps coin and burst", "why": "two effect senders"}],
    "client_bootstrap": [{"from": "StarterPlayerScripts/Hud.client.luau",
                          "into": "StarterPlayerScripts/Controllers/HudController.luau", "purpose": "the HUD"}],
    "delete": [{"path": "ServerScriptService/PingAck.server.luau", "why": "telemetry-only ack"}],
    "rewire": [{"path": "ReplicatedStorage/HudConfig.luau", "change": "drop the PingAck name"}],
}
SERVICE = """local FxService = {}
function FxService:Init(services) self.services = services end
function FxService:Start() end
function FxService.init() end
function FxService.burst(player) end
function FxService.coin(player) end
return FxService
"""
CONTROLLER = """local HudController = {}
function HudController:Init(controllers) end
function HudController:Start()
	local HudFx = require(script.Parent.Parent:WaitForChild("HudFx", 10))
	HudFx.pop()
	require(game:GetService("ReplicatedStorage"):WaitForChild("ForgeTelemetry")).count("hud_pop", 1)
end
return HudController
"""


def _fence(src: str) -> str:
    return f"```luau\n{src}```"


def _default(controller: str = CONTROLLER):
    def reply(role: str, user: str) -> str:
        path = re.search(r"^path: (\S+)", user, re.M).group(1)
        if role == "coder":
            return _fence(SERVICE if path.endswith("FxService.luau") else controller)
        if role == "fixer":  # rewires: the file with its old lookups pointed at the new homes
            src = user.split("```luau\n", 1)[1].split("\n```", 1)[0] + "\n"
            src = src.replace('WaitForChild("Fx")', 'WaitForChild("Services"):WaitForChild("FxService")')
            src = src.replace('WaitForChild("Juice", 5)', 'WaitForChild("Services"):WaitForChild("FxService", 5)')
            src = src.replace('script.Parent:WaitForChild("HudFx", 10)', 'script.Parent.Parent:WaitForChild("HudFx", 10)')
            return _fence(src.replace('"PingAck"', '"none"'))
        raise AssertionError(f"unexpected role {role}")
    return reply


class FakeStudio:
    """Records syncs and playtests; ForgeProbe reports what `errors(root)` says about the synced tree."""

    def __init__(self, errors=None, counters=None):
        self.errors = errors or (lambda root: [])
        self.counters = counters or (lambda root: {"game_started": 1})
        self.root: Path | None = None
        self.syncs: list[list[str]] = []
        self.plays = 0
        self.playing = False

    async def sync(self, root, port=None):
        self.root = Path(root)
        self.syncs.append(cs.game_files(self.root))
        return f"OK {len(self.syncs[-1])} files"

    async def play(self, *a, **k):
        self.plays += 1
        self.playing = True
        return {"ready": True}

    async def stop(self):
        self.playing = False

    async def execute_luau(self, code, datamodel="Edit", timeout=None):
        if "GetLogHistory" in code:
            return json.dumps({"errors": [], "warnings": []})
        if 'and "yes" or "no"' in code:
            return "yes"
        return json.dumps({"ok": True, "detail": "fine"})

    async def probe_report(self):
        return {"errors": [{"message": m} for m in self.errors(self.root)], "warnings": [],
                "counters": self.counters(self.root)}


async def _consolidate(s, llm, studio, **kw):
    return await cs.consolidate(s, SLUG, llm=llm, ui=UI(io.StringIO()), studio=studio, probe_seconds=0,
                                log=lambda _: None, **kw)


@needs_luau
async def test_plan_only_changes_nothing(game):
    s, store = game
    before = {p: (store.game_dir / p).read_text() for p in cs.game_files(store.game_dir)}
    llm = FakeLLM({"architect": [json.dumps(ARCH_PLAN)]})
    rec = await _consolidate(s, llm, None, plan_only=True)
    assert rec["outcome"] == "plan_only" and [u["into"] for u in rec["plan"]["units"]] == [
        "ServerScriptService/Services/FxService.luau", "StarterPlayerScripts/Controllers/HudController.luau"]
    assert {p: (store.game_dir / p).read_text() for p in cs.game_files(store.game_dir)} == before
    assert len(GameVersions(store.game_dir).tags()) == 1
    assert [c.role for c in llm.calls] == ["architect"]
    user = llm.calls[0].user
    assert "## Module map" in user and "## Architecture gaps" in user and "## Prebuilt" in user and "## Limits" in user
    assert json.loads((store.dir / "consolidate" / "1.json").read_text())["outcome"] == "plan_only"


@needs_luau
async def test_a_passing_gate_keeps_the_pass(game):
    s, store = game
    llm = FakeLLM({"architect": [json.dumps(ARCH_PLAN)]}, default=_default())
    studio = FakeStudio()
    rec = await _consolidate(s, llm, studio)
    assert rec["outcome"] == "kept", rec.get("why")
    g = store.game_dir
    for gone in ("ServerScriptService/Fx.luau", "ServerScriptService/Juice.luau", "ServerScriptService/PingAck.server.luau",
                 "StarterPlayerScripts/Hud.client.luau"):
        assert not (g / gone).exists(), gone
    assert (g / "ServerScriptService/Services/FxService.luau").read_text() == SERVICE
    assert "Forge's server bootstrap" in (g / cs.SERVER_BOOT).read_text()
    assert "Forge's client bootstrap" in (g / cs.CLIENT_BOOT).read_text()
    # callers of the merged modules were rewired by the fixer (auto-added) and point at the service now
    assert 'WaitForChild("Services"):WaitForChild("FxService", 5)' in (g / "ServerScriptService/Progress.luau").read_text()
    assert set(rec["plan"]["auto_rewire"]) == {"ServerScriptService/Game.server.luau", "ServerScriptService/Progress.luau"}
    assert rec["execute"]["dangling"] == [] and cs.dangling(g, cs.protected_paths(store.load_spec(), g)) == []
    # the coder saw the originals in full, the callers' call sites and the boot contract
    coder = next(c.user for c in llm.calls if c.role == "coder" and "FxService" in c.user.split("\n", 2)[1])
    assert "function M.coin(player)" in coder and "Juice.coin(player)" in coder and "Init(services)" in coder
    # a rewire after a delete sees what the deleted script did, so counter and remote names stay the same
    cfg = next(c.user for c in llm.calls if c.role == "fixer" and "HudConfig" in c.user.split("\n", 2)[1])
    assert "The deleted ServerScriptService/PingAck.server.luau did this" in cfg and 'count("hud_pop", 1)' in cfg
    spec = store.load_spec()
    paths = {m["path"] for m in spec["modules"]}
    assert "ServerScriptService/Fx.luau" not in paths and "ServerScriptService/Services/FxService.luau" in paths
    assert cs.SERVER_BOOT in paths and spec["consolidations"][0]["deleted"]
    log = [v["message"] for v in GameVersions(g).log()]
    assert log[-2].startswith("before consolidate") and log[-1].startswith("consolidate:")
    # runtime refreshed before the baseline, so both measurements ran the same ForgeTelemetry
    assert (g / "ReplicatedStorage/ForgeTelemetry.luau").read_text() == (s.base_game_dir / "ReplicatedStorage/ForgeTelemetry.luau").read_text()
    assert len(studio.syncs) == 2 and studio.plays == 4 and not studio.playing  # checks + probe, before and after
    assert rec["compare_after"]["metrics"]["lifecycle"] > rec["compare_before"]["metrics"]["lifecycle"]
    assert json.loads((store.dir / "checks" / "results.json").read_text())["results"][0]["source"] == "consolidate 1"


@needs_luau
async def test_a_new_server_error_rolls_the_pass_back(game):
    s, store = game
    before = {p: (store.game_dir / p).read_text() for p in cs.game_files(store.game_dir)}
    spec_before = store.load_spec()
    llm = FakeLLM({"architect": [json.dumps(ARCH_PLAN)]}, default=_default())
    studio = FakeStudio(errors=lambda root: ["FxService:12: attempt to index nil"]
                        if (root / "ServerScriptService/Services").exists() else [])
    rec = await _consolidate(s, llm, studio)
    assert rec["outcome"] == "rolled_back"
    assert any("new server error" in w for w in rec["why"])
    after = {p: (store.game_dir / p).read_text() for p in cs.game_files(store.game_dir)}
    # the game's own files are back; only the refreshed Forge runtime (part of the baseline) differs
    assert {p: after.get(p) for p in before if "ForgeTelemetry" not in p} == {
        p: t for p, t in before.items() if "ForgeTelemetry" not in p}
    assert all(p.startswith("tools/") or "Forge" in p for p in set(after) - set(before)), set(after) - set(before)
    assert store.load_spec() == spec_before
    log = [v["message"] for v in GameVersions(store.game_dir).log()]
    assert log[-1].startswith(f"rollback to {rec['version_before']}: consolidate gate failed")
    assert "after" in rec and "probe2" in rec["after"]  # the finding had to repeat in a second probe
    assert studio.syncs[-1] == cs.game_files(store.game_dir)  # Studio was left on the restored game
    # the next pass's architect hears why this one was refused
    assert "rolled back" in cs.last_pass_text(store.dir / "consolidate") and "new server error" in \
        cs.last_pass_text(store.dir / "consolidate")


@needs_luau
async def test_a_lost_boot_counter_rolls_back(game):
    s, store = game
    llm = FakeLLM({"architect": [json.dumps(ARCH_PLAN)]}, default=_default())
    studio = FakeStudio(counters=lambda root: {} if any((root / "ServerScriptService/Services").glob("*.luau"))
                        else {"game_started": 1})
    rec = await _consolidate(s, llm, studio)
    assert rec["outcome"] == "rolled_back" and rec["why"] == ["counter game_started was 1 before and is absent now"]


@needs_luau
async def test_a_one_off_probe_blip_does_not_roll_back(game):
    s, store = game
    seen = {"probes": 0}

    def counters(root):
        seen["probes"] += 1
        return {} if seen["probes"] == 2 else {"game_started": 1}  # only the first probe after the change

    llm = FakeLLM({"architect": [json.dumps(ARCH_PLAN)]}, default=_default())
    rec = await _consolidate(s, llm, FakeStudio(counters=counters))
    assert rec["outcome"] == "kept", rec.get("why")
    assert seen["probes"] == 3 and rec["after"]["probe2"]["server"]["counters"] == {"game_started": 1}


@needs_luau
async def test_code_that_does_not_compile_rolls_back_before_studio_time(game):
    s, store = game
    broken = "```luau\nlocal function oops(\n```"
    llm = FakeLLM({"architect": [json.dumps(ARCH_PLAN)], "coder": [broken, broken], "fixer": [broken] * 6},
                  default=_default())
    studio = FakeStudio()
    rec = await _consolidate(s, llm, studio)
    assert rec["outcome"] == "rolled_back" and any("does not compile" in w for w in rec["why"])
    assert "after" not in rec and studio.plays == 2  # only the baseline played
    assert (store.game_dir / "ServerScriptService/Fx.luau").exists()
    assert not list((store.game_dir / "ServerScriptService").glob("Services/*.luau"))


@needs_luau
async def test_studio_dropping_mid_gate_still_restores_the_game(game):
    s, store = game

    class Dropping(FakeStudio):
        async def sync(self, root, port=None):
            if self.syncs:
                raise ConnectionError("StudioMCP went away")
            return await super().sync(root, port)

    llm = FakeLLM({"architect": [json.dumps(ARCH_PLAN)]}, default=_default())
    with pytest.raises(ConnectionError):
        await _consolidate(s, llm, Dropping())
    rec = json.loads((store.dir / "consolidate" / "1.json").read_text())
    assert rec["outcome"] == "rolled_back" and "StudioMCP went away" in rec["why"][0]
    assert (store.game_dir / "ServerScriptService/Fx.luau").exists()
    assert not list((store.game_dir / "ServerScriptService").glob("Services/*.luau"))
    assert GameVersions(store.game_dir).log()[-1]["message"].startswith("rollback to")


@needs_luau
async def test_a_lookup_of_a_moved_module_gets_one_fix_from_the_fixer(game):
    s, store = game
    stale = CONTROLLER.replace("script.Parent.Parent:WaitForChild", "script.Parent:WaitForChild")
    llm = FakeLLM({"architect": [json.dumps(ARCH_PLAN)]}, default=_default(controller=stale))
    rec = await _consolidate(s, llm, FakeStudio())
    assert rec["outcome"] == "kept", rec.get("why")
    fixes = [c.user for c in llm.calls if c.role == "fixer" and "HudController" in c.user.split("\n", 3)[1]]
    assert fixes and "look up modules that no longer exist" in fixes[0]
    text = (store.game_dir / "StarterPlayerScripts/Controllers/HudController.luau").read_text()
    assert 'script.Parent.Parent:WaitForChild("HudFx", 10)' in text


def test_prebuilt_bootstrap_boots_services_headless(tmp_path):
    if shutil.which("luau") is None:
        pytest.skip("luau CLI not installed")
    from forge import checks

    files = {
        "ServerScriptService/Main.server.luau": (cs.BOOT_DIR / "Main.server.luau").read_text(),
        "ReplicatedStorage/ForgeTelemetry.luau": (REPO / "game/ReplicatedStorage/ForgeTelemetry.luau").read_text(),
        "ServerScriptService/Services/AService.luau": (
            'local T = require(game:GetService("ReplicatedStorage"):WaitForChild("ForgeTelemetry"))\n'
            "local A = { Priority = 1 }\nfunction A:Init(services) self.peer = services.BService end\n"
            'function A:Start() T.count(if self.peer then "a_saw_b" else "a_alone", 1) end\nreturn A\n'),
        "ServerScriptService/Services/BService.luau": (
            'local T = require(game:GetService("ReplicatedStorage"):WaitForChild("ForgeTelemetry"))\n'
            'local B = {}\nfunction B:Start() T.count("b_started", 1) end\nreturn B\n'),
        "ServerScriptService/Services/Broken.luau": "error('not a service')\n",
    }
    for rel, text in files.items():
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / rel).write_text(text)
    rep = checks.boot_offline(tmp_path)
    assert rep["errors"] == [], rep["errors"]
    assert rep["counters"].get("a_saw_b") == 1 and rep["counters"].get("b_started") == 1


def test_check_and_probe_findings():
    before = {"server": {"errors": ["old 12"], "warnings": [], "counters": {"game_started": 1, "flaky": 0}},
              "client": {"errors": [], "warnings": []}, "player": True}
    after = {"server": {"errors": ["old 13", "new boom"], "warnings": ["[Hud] HudFx failed", "unrelated thing"],
                        "counters": {}},
             "client": {"error": "no Client datamodel"}, "player": True}
    got = cs.probe_findings(before, after, {"Hud", "HudFx"})
    assert sorted(got.values()) == ["counter game_started was 1 before and is absent now",
                                    "new server error: new boom",
                                    "new warning naming a changed module: [Hud] HudFx failed"]
    checks_b = {"a": {"ok": True}, "b": {"ok": True}, "c": {"ok": False}}
    checks_a = {"a": {"ok": False, "detail": "x"}, "b": {"ok": False, "error": "setup: no round"}, "c": {"ok": False}}
    assert cs.check_findings(checks_b, checks_a) == ["a"]


def test_cli_registers_consolidate():
    from forge.cli import build_parser

    args = build_parser().parse_args(["consolidate", "g", "--plan-only", "--max-merges", "2"])
    assert args.cmd == "consolidate" and args.plan_only and args.max_merges == 2
