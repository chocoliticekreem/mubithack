"""forge compare: static code comparison against a reference game, scored per category relative to it."""

from __future__ import annotations

import dataclasses
import json
import os
from pathlib import Path

import pytest

from forge import compare as cmp
from forge.config import load_settings
from forge.done import readiness, render
from forge.llm import FakeLLM

# A small reference built the Flame and Blame way: thin bootstraps, services with Init/Start, a Net module
# (rate limits + validation), a versioned DataService, a UiKit, juice, telemetry, a spec test.
GOOD = {
    "ServerScriptService/Main.server.luau": """
local folder = script.Parent:WaitForChild("Services")
local services = {}
for _, child in folder:GetChildren() do
	local ok, mod = pcall(require, child)
	if ok then services[child.Name] = mod end
end
for _, mod in services do if mod.Init then mod:Init(services) end end
for _, mod in services do if mod.Start then task.spawn(mod.Start, mod) end end
""",
    "ServerScriptService/Services/DataService.luau": """
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataConfig = require(ReplicatedStorage.Config.DataConfig)
local Schema = require(script.Parent.Parent.Lib.ProfileSchema)
local DataService = {}
local profiles = {}
local store = nil
function DataService:Init(services)
	self.services = services
end
local function open()
	if RunService:IsStudio() and DataConfig.UseMemoryInStudio then
		return nil
	end
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore(DataConfig.StoreName)
	end)
	return ok and ds or nil
end
local function load(player)
	for attempt = 1, DataConfig.Retries do
		local ok, data = pcall(function()
			return store and store:UpdateAsync(tostring(player.UserId), function(old) return old end)
		end)
		if ok then
			profiles[player] = Schema.migrate(data)
			return
		end
		task.wait(attempt)
	end
end
local function save(player)
	local p = profiles[player]
	if p and store then
		pcall(function()
			store:UpdateAsync(tostring(player.UserId), function() return p end)
		end)
	end
	profiles[player] = nil
end
function DataService:Start()
	store = open()
	Players.PlayerAdded:Connect(load)
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
	Players.PlayerRemoving:Connect(save)
	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			save(player)
		end
	end)
end
function DataService._selftest()
	return true, "ok"
end
return DataService
""",
    "ServerScriptService/Lib/ProfileSchema.luau": """
local ProfileSchema = {}
ProfileSchema.Version = 2
local MIGRATIONS = {
	[1] = function(p) p.coins = p.coins or 0 end,
}
function ProfileSchema.migrate(raw)
	local p = raw or { version = ProfileSchema.Version, coins = 0, level = 1 }
	while (p.version or 1) < ProfileSchema.Version do
		MIGRATIONS[p.version or 1](p)
		p.version = (p.version or 1) + 1
	end
	return p
end
return ProfileSchema
""",
    "ServerScriptService/Services/ShopService.luau": """
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage.Shared.Net)
local ShopConfig = require(ReplicatedStorage.Config.ShopConfig)
local Telemetry = require(ReplicatedStorage.ForgeTelemetry)
local ShopService = {}
function ShopService:Init(services)
	self.services = services
end
function ShopService:Start()
	Net.onServer(Net.event("Shop", "Buy"), { rate = 2, burst = 1 }, function(player, itemId)
		if typeof(itemId) ~= "string" or not ShopConfig.Items[itemId] then
			return
		end
		Telemetry.count("item_bought")
		Telemetry.count("upgrade_level")
		Net.notify(player, "Unlocked " .. itemId .. "!", "good")
	end)
end
function ShopService._selftest()
	return true, "ok"
end
return ShopService
""",
    "ServerScriptService/Services/MapService.luau": """
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MapConfig = require(ReplicatedStorage.Config.MapConfig)
local Telemetry = require(ReplicatedStorage.ForgeTelemetry)
local MapService = {}
function MapService:Init(services)
	self.services = services
end
function MapService:Start()
	local model = Instance.new("Model")
	for i = 1, MapConfig.Pads do
		local part = Instance.new("Part")
		part.Material = Enum.Material.Neon
		part.Color = Color3.fromRGB(255, 200, 40)
		part.Parent = model
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Collect"
		prompt.Parent = part
		prompt.Triggered:Connect(function(player)
			Telemetry.count("pad_collected")
			part:Destroy()
		end)
	end
	model.Parent = workspace
	local light = Instance.new("PointLight")
	light.Parent = model
end
function MapService._selftest()
	return true, "ok"
end
return MapService
""",
    "ReplicatedStorage/Shared/Net.luau": """
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Net = {}
function Net.event(ns, name)
	local folder = ReplicatedStorage:FindFirstChild(ns) or Instance.new("Folder")
	folder.Name = ns
	folder.Parent = ReplicatedStorage
	local remote = folder:FindFirstChild(name)
	if not remote and RunService:IsServer() then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
	end
	return remote or folder:WaitForChild(name)
end
function Net.onServer(remote, limit, handler)
	local cooldown = 1 / limit.rate
	local tokens = {}
	remote.OnServerEvent:Connect(function(player, ...)
		local t = os.clock()
		if (tokens[player] or 0) > t then
			return
		end
		tokens[player] = t + cooldown
		pcall(handler, player, ...)
	end)
	Players.PlayerRemoving:Connect(function(player)
		tokens[player] = nil
	end)
end
function Net.notify(player, text, kind)
	Net.event("Shared", "Notify"):FireClient(player, text, kind)
end
return Net
""",
    "ReplicatedStorage/Config/ShopConfig.luau": """
return { Items = { Sword = { price = 10 }, Boots = { price = 25 } } }
""",
    "ReplicatedStorage/Config/DataConfig.luau": """
return { StoreName = "Profiles", UseMemoryInStudio = true, Retries = 3 }
""",
    "ReplicatedStorage/Config/MapConfig.luau": """
return { Pads = 4 }
""",
    "StarterPlayerScripts/Main.client.luau": """
local Controllers = script.Parent:WaitForChild("Controllers")
local controllers = {}
for _, child in Controllers:GetChildren() do
	controllers[child.Name] = require(child)
end
for _, c in controllers do if c.Init then c:Init(controllers) end end
for _, c in controllers do if c.Start then task.spawn(c.Start, c) end end
""",
    "StarterPlayerScripts/ClientLib/UiKit.luau": """
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local UiKit = {}
function UiKit.screen(name)
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	local scale = Instance.new("UIScale")
	scale.Scale = if UserInputService.TouchEnabled then 0.8 else 1
	scale.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return gui
end
function UiKit.panel(parent, name)
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = UDim2.fromScale(0.3, 0.1)
	f.Position = UDim2.new(0.5, 0, 0.05, 0)
	Instance.new("UICorner").Parent = f
	Instance.new("UIStroke").Parent = f
	Instance.new("UIGradient").Parent = f
	Instance.new("UIPadding").Parent = f
	Instance.new("UIListLayout").Parent = f
	Instance.new("UIAspectRatioConstraint").Parent = f
	f.Parent = parent
	return f
end
function UiKit.label(parent, text)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.fromOffset(200, 40)
	l.TextScaled = true
	l.Text = text
	l.Parent = parent
	return l
end
function UiKit.pop(gui)
	TweenService:Create(gui, TweenInfo.new(0.2), { Size = gui.Size }):Play()
end
return UiKit
""",
    "StarterPlayerScripts/Controllers/HudController.luau": """
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit"))
local Net = require(ReplicatedStorage.Shared.Net)
local HudController = {}
function HudController:Init(controllers)
	self.controllers = controllers
end
local function toast(gui, text)
	local l = UiKit.label(gui, text)
	UiKit.pop(l)
end
function HudController:Start()
	local gui = UiKit.screen("Hud")
	local panel = UiKit.panel(gui, "Coins")
	UiKit.label(panel, "Coins: 0")
	UiKit.label(panel, "Hint: walk to a glowing pad")
	Net.event("Shared", "Notify").OnClientEvent:Connect(function(text)
		toast(gui, text)
		local s = Instance.new("Sound")
		s.SoundId = "rbxassetid://1"
		s:Play()
		local fx = Instance.new("ParticleEmitter")
		fx:Emit(20)
		local hum = Players.LocalPlayer.Character and Players.LocalPlayer.Character:FindFirstChild("Humanoid")
		if hum then
			hum.CameraOffset = Vector3.new(0, 0.2, 0)
			TweenService:Create(hum, TweenInfo.new(0.2), { CameraOffset = Vector3.zero }):Play()
		end
	end)
	local music = Instance.new("Sound")
	music.Looped = true
	music.Name = "Music"
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Parent = game:GetService("Lighting")
end
return HudController
""",
    "tests/shop.spec.luau": """
local ShopConfig = require("../ReplicatedStorage/Config/ShopConfig")
assert(ShopConfig.Items.Sword.price == 10)
""",
}

# One big Script, deprecated APIs, globals, unvalidated + unlimited remote, bare DataStore call, no cleanup,
# a client that sets its own cash, offset-only UI, no juice, no telemetry, no tests.
PAD = "".join(f"local filler{i} = {i}\n" for i in range(300))
BAD = {
    "ServerScriptService/Game.server.luau": """
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local store = DataStoreService:GetDataStore("Cash")
local cash = {}
_G.cash = cash
local remote = Instance.new("RemoteEvent")
remote.Name = "AddCash"
remote.Parent = game:GetService("ReplicatedStorage")
remote.OnServerEvent:Connect(function(player, amount)
	cash[player] = (cash[player] or 0) + amount
end)
Players.PlayerAdded:Connect(function(player)
	cash[player] = store:GetAsync(tostring(player.UserId)) or 0
end)
local pad = Instance.new("Part")
pad.Touched:Connect(function(hit)
	local player = Players:GetPlayerFromCharacter(hit.Parent)
	if player then cash[player] = (cash[player] or 0) + 1 end
end)
while true do
	wait(1)
end
""" + PAD,
    "ServerScriptService/Shop.luau": """
local Shop = {}
function Shop.make()
	local r = Instance.new("RemoteEvent")
	r.Name = "Buy"
	return r
end
return Shop
""",
    "StarterPlayerScripts/Hud.client.luau": """
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
local label = Instance.new("TextLabel")
label.Size = UDim2.fromOffset(200, 50)
label.Position = UDim2.new(0, 10, 0, 10)
label.Parent = gui
gui.Parent = player:WaitForChild("PlayerGui")
player.leaderstats.Cash.Value = 5
""",
}


def _tree(root: Path, files: dict[str, str]) -> Path:
    for rel, text in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text.lstrip("\n"), encoding="utf-8")
    return root


def _line(files: dict[str, str], rel: str, needle: str) -> int:
    return next(i for i, ln in enumerate(files[rel].lstrip("\n").split("\n"), 1) if needle in ln)


@pytest.fixture
def good(tmp_path):
    return _tree(tmp_path / "good", GOOD)


@pytest.fixture
def bad(tmp_path):
    return _tree(tmp_path / "bad", BAD)


def _cats(report: dict) -> dict[str, dict]:
    return {c["id"]: c for c in report["categories"]}


def _row(report: dict, metric: str) -> dict:
    return next(r for c in report["categories"] for r in c["metrics"] if r["id"] == metric)


# ---------------------------------------------------------------- reading code


def test_strip_comments_keeps_line_numbers_and_strings():
    src = ('local a = 1 -- wait(1)\n--[[ block\nwait(2)\n]] local b = "--not a comment"\n'
           "local c = [[ long -- string ]]\n--[==[ x ]==] wait(3)\n")
    code = cmp.strip_comments(src)
    assert code.count("\n") == src.count("\n")
    assert "wait(1)" not in code and "wait(2)" not in code
    assert '"--not a comment"' in code and "[[ long -- string ]]" in code
    assert code.split("\n")[5].strip() == "wait(3)"


def test_prose_in_comments_never_counts(tmp_path):
    game = _tree(tmp_path / "g", {"ServerScriptService/A.server.luau": "-- never wait(1) or _G here\nprint(1)\n"})
    rep = cmp.compare(game, game)
    assert _row(rep, "modern_api")["value"] == 0


# ---------------------------------------------------------------- scoring


def test_reference_scores_ten_against_itself(good):
    rep = cmp.compare(good, good)
    assert rep["overall"] == 10.0 and rep["verdict"] == "on par with the reference"
    for c in rep["categories"]:
        assert c["score"] == 10.0, (c["id"], [(r["id"], r["score"]) for r in c["metrics"]])
        assert c["gaps"] == []
    # every category is actually measured on the reference, not skipped as n/a
    for metric in ("lifecycle", "remote_validation", "pcall_io", "remote_rate_limit", "persistence",
                   "ui_styling", "juice_kinds", "telemetry", "tests"):
        assert _row(rep, metric)["score"] == 1.0, metric


def test_every_category_sees_the_bad_game(good, bad):
    rep = cmp.compare(bad, good)
    cats = _cats(rep)
    assert rep["overall"] < 4
    for cid, c in cats.items():
        assert c["score"] is not None and c["score"] < 6, (cid, c["score"])
        assert c["gaps"] and len(c["gaps"]) <= 3
    assert cats["juice"]["score"] == 0 and cats["observability"]["score"] == 0

    game = "ServerScriptService/Game.server.luau"
    misses = {m: {(e["file"], e["line"]) for e in _row(rep, m)["misses"]} for m in
              ("modern_api", "pcall_io", "existing_players", "player_cleanup", "remote_validation",
               "remote_rate_limit", "touch_debounce", "remotes_central")}
    assert (game, _line(BAD, game, "wait(1)")) in misses["modern_api"]
    assert (game, _line(BAD, game, "_G.cash")) in misses["modern_api"]
    assert (game, _line(BAD, game, "store:GetAsync")) in misses["pcall_io"]
    assert (game, _line(BAD, game, "PlayerAdded")) in misses["existing_players"]
    assert (game, _line(BAD, game, "OnServerEvent")) in misses["remote_validation"]
    assert (game, _line(BAD, game, "OnServerEvent")) in misses["remote_rate_limit"]
    assert (game, _line(BAD, game, "pad.Touched")) in misses["touch_debounce"]
    assert {f for f, _ in misses["remotes_central"]} == {game, "ServerScriptService/Shop.luau"}
    hud = "StarterPlayerScripts/Hud.client.luau"
    assert _row(rep, "server_authority")["misses"][0] == {
        "file": hud, "line": _line(BAD, hud, "Cash.Value"), "text": "player.leaderstats.Cash.Value = 5"}
    assert _row(rep, "persistence")["score"] == 1.0  # it saves, but nothing around saving is safe
    assert _row(rep, "safe_writes")["score"] == 0 and _row(rep, "studio_fallback")["score"] == 0
    assert _row(rep, "server_split")["score"] < 0.5 and _row(rep, "lifecycle")["score"] == 0


def test_gaps_point_at_reference_files_that_do_it(good, bad):
    rep = cmp.compare(bad, good)
    for c in rep["categories"]:
        for g in c["gaps"]:
            assert g["pointer"], g
            path, _, line = g["pointer"].rpartition(":")
            assert int(line) >= 1
            assert (good / path).is_file() or (cmp.REPO_ROOT / path).is_file(), g["pointer"]
            assert g["text"].startswith(("Reference", "Genre bar")) and g["short"]
    ref = {m: _row(rep, m)["ref"] for m in ("lifecycle", "remotes_central", "safe_writes", "remote_rate_limit")}
    assert (ref["lifecycle"]["file"], ref["lifecycle"]["line"]) == ("ServerScriptService/Main.server.luau", 3)
    assert ref["remotes_central"]["file"] == ref["remote_rate_limit"]["file"] == "ReplicatedStorage/Shared/Net.luau"
    assert ref["safe_writes"]["file"] == "ServerScriptService/Services/DataService.luau"
    juice = next(g for g in _cats(rep)["juice"]["gaps"] if g["metric"] == "juice_kinds")
    assert juice["missing"][:2] == ["sound", "particles"]
    assert juice["pointers"]["sound"].startswith("StarterPlayerScripts/Controllers/HudController.luau:")
    assert rep["gaps"] and rep["gaps"][0]["loss"] >= rep["gaps"][-1]["loss"]


def _scaled(files: dict[str, str], copies: int) -> dict[str, str]:
    """The same code quality at several times the size: every module and spec copied, each copy with its own
    name and counters. Net and the two bootstraps stay single, as they would in a bigger game."""
    out = dict(files)
    for rel, text in files.items():
        name = rel.rsplit("/", 1)[-1].split(".")[0]
        if name == "Net" or rel.endswith((".server.luau", ".client.luau")):
            continue
        kind = next((k for k in ("Service", "Controller") if name.endswith(k)), "")
        for i in range(2, copies + 1):
            new = name[: len(name) - len(kind)] + str(i) + kind
            out[rel.replace(f"/{name}.", f"/{new}.")] = text.replace(name, new).replace('count("', f'count("c{i}_')
    return out


def test_scores_compare_ratios_not_size(tmp_path, good):
    big = _tree(tmp_path / "big", _scaled(GOOD, 5))
    small_vs_big = cmp.compare(good, big)
    big_vs_small = cmp.compare(big, good)
    assert small_vs_big["size"]["game"]["sloc"] * 3 < small_vs_big["size"]["reference"]["sloc"]
    row = _row(small_vs_big, "sound_density")
    assert "3 sites" in row["game"] and "15 sites" in row["reference"]  # raw counts would score this 3/15
    for rep in (small_vs_big, big_vs_small):
        cats = [(c["id"], c["score"]) for c in rep["categories"]]
        assert rep["overall"] >= 9.3 and all(s >= 8 for _, s in cats), cats


def test_metric_score_rules():
    m = next(x for x in cmp.METRICS if x.id == "remote_validation")
    assert cmp.metric_score(m, cmp.Val(0.5), cmp.Val(1.0)) == 0.5
    assert cmp.metric_score(m, cmp.Val(1.0), cmp.Val(0.5)) == 1.0  # better than the reference caps at 1
    assert cmp.metric_score(m, cmp.Val(None), cmp.Val(1.0)) is None  # nothing to validate: n/a
    assert cmp.metric_score(m, cmp.Val(0.0), cmp.Val(0.0)) is None  # the reference doesn't do it either
    low = next(x for x in cmp.METRICS if x.id == "modern_api")
    assert cmp.metric_score(low, cmp.Val(0.0), cmp.Val(0.0)) == 1.0
    assert cmp.metric_score(low, cmp.Val(1.5), cmp.Val(0.0)) == pytest.approx(0.25)
    tgt = next(x for x in cmp.METRICS if x.id == "buyables")
    assert cmp.metric_score(tgt, cmp.Val(5.0), cmp.Val(None)) == 0.5  # genre bar, not the reference


# ---------------------------------------------------------------- genre content


def test_content_uses_the_genre_bar(good, bad):
    tycoon = cmp.compare(bad, good, spec={"title": "Cube Cash Tycoon", "pitch": "droppers and conveyors"})
    obby = cmp.compare(bad, good, spec={"title": "Lava Obby", "pitch": "an obby with checkpoints"})
    generic = cmp.compare(bad, good)
    ids = {r["genre"]: [r["id"] for r in _cats(r)["content"]["metrics"]] for r in (tycoon, obby, generic)}
    assert ids == {"tycoon": ["tycoon_checklist", "buyables"],
                   "obby": ["obby_checklist", "stages", "obstacle_kinds", "zones"],
                   "generic": ["generic_checklist", "interactions", "progression"]}
    gap = next(g for g in _cats(tycoon)["content"]["gaps"] if g["metric"] == "tycoon_checklist")
    assert gap["pointers"]["rebirth"] == "forge/ui_library/RebirthPanel.luau:1"  # the reference has no rebirth
    assert gap["pointers"]["droppers_tiers"] == "forge/lessons_library/tycoon.md:1"
    assert _row(tycoon, "buyables")["game"].startswith("0/10")


def test_obby_depth_counts(tmp_path, good):
    game = _tree(tmp_path / "obby", {
        "ReplicatedStorage/Config.luau": 'return { STAGE_COUNT = 12, Zones = { "Desert", "Forest", "Sky" } }\n',
        "ServerScriptService/Obby.server.luau": ("local kill = 1\nlocal spinner = 2\nlocal conveyor = 3\n"
                                                 "local jumpPad = 4\nlocal disappearing = 5\n"),
    })
    rep = cmp.compare(game, good, spec={"title": "Sky Obby"})
    assert _row(rep, "stages")["value"] == 12 and _row(rep, "zones")["value"] == 3
    assert _row(rep, "obstacle_kinds")["value"] == 5


# ---------------------------------------------------------------- report shape + playtest record


def test_report_shape(good, bad):
    rep = cmp.compare(bad, good, name="b", ref_name="g")
    assert {"game", "reference", "genre", "ts", "size", "overall", "verdict", "categories", "gaps"} <= set(rep)
    assert [c["id"] for c in rep["categories"]] == list(cmp.CATEGORY_IDS)
    for c in rep["categories"]:
        assert {"id", "label", "score", "metrics", "evidence", "gaps"} <= set(c)
        assert 0 <= c["score"] <= 10
        for e in c["evidence"]:
            assert e["line"] >= 1 and e["file"] and isinstance(e["text"], str)
        for r in c["metrics"]:
            assert {"id", "label", "kind", "score", "game", "reference", "evidence", "misses", "ref"} <= set(r)
    json.dumps(rep)  # saved as-is


def test_probe_errors_reads_the_newest_playtest(tmp_path):
    run = tmp_path / "run"
    (run / "iterations" / "2").mkdir(parents=True)
    (run / "improve").mkdir()
    report, cycle = run / "iterations" / "2" / "report.json", run / "improve" / "3.json"
    report.write_text(json.dumps({"errors": [{"message": "boom"}, {"message": "bang"}]}))
    cycle.write_text(json.dumps({"before": [{"errors": {"count": 0, "first": []}}, {"errors": {"count": 1}}]}))
    os.utime(report, (1000, 1000))
    os.utime(cycle, (2000, 2000))
    assert cmp.probe_errors(run) == (1, "improve/3.json", "fix cycle, 2 rounds")
    os.utime(report, (3000, 3000))
    assert cmp.probe_errors(run)[:2] == (2, "iterations/2/report.json")
    assert cmp.probe_errors(tmp_path / "nothing") == (None, "", "no playtest yet")


# ---------------------------------------------------------------- CLI, judge, forge done


@pytest.fixture
def settings(tmp_path, good, monkeypatch):
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs", base_game_dir=good)
    monkeypatch.setattr(cmp, "load_settings", lambda: s)
    run = s.runs_dir / "g"
    _tree(run / "game", BAD)
    (run / "spec.json").write_text(json.dumps({"title": "Cash Grab", "pitch": "grab cash"}))
    return s


def test_cli_prints_the_table_and_saves_numbered_reports(settings, capsys):
    from forge.cli import main

    assert main(["compare", "g"]) == 0
    out = capsys.readouterr().out
    assert "g vs game" in out and "overall" in out and "Data" in out and " -> " in out
    d = settings.runs_dir / "g" / "compare"
    saved = json.loads((d / "1.json").read_text())
    assert saved["n"] == 1 and saved["game"] == "g" and saved["reference"] == "game"
    md = (d / "1.md").read_text()
    assert md.startswith("# forge compare: g vs game") and "Copy from `" in md

    assert main(["compare", "g", "--json"]) == 0
    printed = json.loads(capsys.readouterr().out)
    assert printed["n"] == 2 and (d / "2.json").exists() and len(printed["categories"]) == 7


def test_cli_folder_target_is_read_only(settings, tmp_path, capsys):
    from forge.cli import main

    folder = _tree(tmp_path / "elsewhere" / "mygame", BAD)
    before = sorted(p.relative_to(folder) for p in folder.rglob("*"))
    assert main(["compare", str(folder), "--against", "g"]) == 0
    assert "mygame vs g" in capsys.readouterr().out
    assert (settings.runs_dir / "compare" / "mygame" / "1.json").exists()
    assert sorted(p.relative_to(folder) for p in folder.rglob("*")) == before


JUDGE_REPLY = {
    "summary": "Robust enough, but nothing is saved safely and nothing makes a sound.",
    "verdict": "far on data and juice",
    "improvements": [
        {"title": "Save cash with UpdateAsync under pcall", "category": "data", "impact": 9, "effort": "M",
         "why": "players lose progress", "how": "move saving into a DataService",
         "files": ["ServerScriptService/Game.server.luau", "ServerScriptService/Nope.luau",
                   "ServerScriptService/Services/DataService.luau"],
         "reference": "ServerScriptService/Services/DataService.luau:20"},
        {"title": "Add a buy sound", "category": "sounds", "impact": 6, "files": [], "reference": "nope.luau:3"},
        {"title": ""},
    ],
}


def test_cli_llm_judge_is_one_code_judge_call(settings, monkeypatch, capsys):
    import forge.llm
    from forge.cli import main

    fake = FakeLLM({"code_judge": [json.dumps(JUDGE_REPLY)]})
    monkeypatch.setattr(forge.llm, "make_llm", lambda s, log_path=None: fake)
    assert main(["compare", "g", "--llm"]) == 0
    assert "judge #1 [data, impact 9] Save cash with UpdateAsync under pcall" in capsys.readouterr().out
    assert [(c.role, c.session_id) for c in fake.calls] == [("code_judge", "g")]
    user = fake.calls[0].user
    assert "## Weakest areas, side by side" in user and "#### This game (" in user
    assert "ServerScriptService/Game.server.luau" in user and "#### Reference (" in user
    assert len(user) <= cmp.MAX_USER_CHARS + 2000

    llm = json.loads((settings.runs_dir / "g" / "compare" / "1.json").read_text())["llm"]
    first, second = llm["improvements"]
    assert first["files"] == ["ServerScriptService/Game.server.luau"]
    assert first["new_files"] == ["ServerScriptService/Nope.luau", "ServerScriptService/Services/DataService.luau"]
    assert first["reference"] == "ServerScriptService/Services/DataService.luau:20"
    assert second["category"] == "other" and second["reference"] is None and second["rank"] == 2
    assert llm["request_id"] == "fake-1"
    assert "## Code judge" in (settings.runs_dir / "g" / "compare" / "1.md").read_text()


def test_forge_done_shows_compare_but_never_blocks(settings):
    plain = readiness(settings, "g")
    r = readiness(settings, "g", compare=True)
    assert "compare" not in plain and r["ready"] == plain["ready"] and r["parts"] == plain["parts"]
    assert set(r["compare"]["categories"]) == set(cmp.CATEGORY_IDS) and r["compare"]["reference"] == "game"
    text = render(r)
    assert "[i] compare" in text and "forge compare g" in text
    assert cmp.done_summary(settings, "no-such-game") is None
