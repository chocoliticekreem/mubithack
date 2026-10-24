"""Headless game runs (game/tools/headless.luau via forge.checks): boot, checks, triage, and the
incremental pull script exercised against the fake engine."""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

from forge import checks
from forge import sync as fsync

REPO = Path(__file__).resolve().parent.parent
pytestmark = pytest.mark.skipif(shutil.which("luau") is None, reason="luau CLI not installed")


def _write(root: Path, rel: str, text: str) -> None:
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


def _shop(root: Path) -> Path:
    """A tiny server: leaderstats on join, a Shop module with Buy(player, cost)."""
    _write(root, "ReplicatedStorage/Config.luau", "return { START_CASH = 50, COST = 20 }\n")
    _write(root, "ReplicatedStorage/ForgeTelemetry.luau",
           (REPO / "game/ReplicatedStorage/ForgeTelemetry.luau").read_text())
    _write(root, "ServerScriptService/Shop.luau", """
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"))
local Shop = {}
function Shop.Buy(player, cost)
	local cash = player.leaderstats.Cash
	if cash.Value < cost then return false end
	cash.Value -= cost
	return true
end
return Shop
""")
    _write(root, "ServerScriptService/Main.server.luau", """
local Players = game:GetService("Players")
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"))
local Telemetry = require(game:GetService("ReplicatedStorage"):WaitForChild("ForgeTelemetry"))
Players.PlayerAdded:Connect(function(p)
	local ls = Instance.new("Folder")
	ls.Name = "leaderstats"
	local cash = Instance.new("IntValue")
	cash.Name = "Cash"
	cash.Value = Config.START_CASH
	cash.Parent = ls
	ls.Parent = p
	Telemetry.count("joined", 1)
end)
task.spawn(function()
	while true do
		task.wait(1)
		Telemetry.count("ticks", 1)
	end
end)
workspace:SetAttribute("ServerBooted", true)
""")
    return root


def test_boot_reports_counters_and_players(tmp_path):
    rep = checks.boot_offline(_shop(tmp_path), boot=1, play=3)
    assert rep["errors"] == [], rep
    assert rep["players"] == 1
    assert rep["counters"]["joined"] == 1
    assert rep["counters"]["ticks"] >= 3  # simulated clock: task.wait loops really run


def test_boot_catches_a_runtime_error_with_its_script(tmp_path):
    root = _shop(tmp_path)
    _write(root, "ServerScriptService/Broken.server.luau",
           "local Config = require(game.ReplicatedStorage.Config)\nlocal x = Config.MISSING.value\n")
    rep = checks.boot_offline(root)
    msgs = [e["message"] for e in rep["errors"]]
    assert any("Broken" in m and "MISSING" not in m or "index nil" in m for m in msgs), rep["errors"]
    assert any(e["script"].endswith("Broken") for e in rep["errors"]), rep["errors"]


def test_boot_warns_on_an_infinite_wait_for_child(tmp_path):
    root = _shop(tmp_path)
    _write(root, "ServerScriptService/Waits.server.luau", "game.ReplicatedStorage:WaitForChild('Nope')\n")
    rep = checks.boot_offline(root, boot=1, play=6)
    assert any("Infinite yield" in w and "Nope" in w for w in rep["warnings"]), rep["warnings"]


CHECK_OK = """-- check: buying costs 20
-- covers: shop
local Players = game:GetService("Players")
local Shop = require(game:GetService("ServerScriptService").Shop)
local p = Players:GetPlayers()[1]
local before = p.leaderstats.Cash.Value
local ok = Shop.Buy(p, 20)
local after = p.leaderstats.Cash.Value
p.leaderstats.Cash.Value = before
return { ok = ok and after == before - 20, detail = before .. " -> " .. after }
"""


def test_check_runs_offline(tmp_path):
    root = _shop(tmp_path)
    res = checks.run_check_offline(root, checks.parse(CHECK_OK, "buy"))
    res.pop("sim", None)
    assert res == {"id": "buy", "title": "buying costs 20", "where": "offline", "ok": True,
                   "detail": "50 -> 30", "boot_errors": 0, "verdict": "pass"}


def test_failing_erroring_and_slow_checks(tmp_path):
    root = _shop(tmp_path)
    fail = checks.parse("-- check: f\nreturn { ok = false, detail = 'nope' }\n", "f")
    err = checks.parse("-- check: e\nlocal x = nil\nreturn x.y\n", "e")
    slow = checks.parse("-- check: s\nwhile true do task.wait(1) end\n", "s")
    bad = checks.parse("-- check: b\nreturn 5\n", "b")
    res = {r["id"]: r for r in checks.run_checks_offline(root, [fail, err, slow, bad], timeout=3)}
    assert res["f"]["ok"] is False and res["f"]["detail"] == "nope"
    assert res["e"]["ok"] is False and "index nil" in res["e"]["error"]
    assert res["s"]["ok"] is False and "timed out" in res["s"]["error"]
    assert res["b"]["ok"] is False and "must return" in res["b"]["error"]


def test_a_loop_without_yield_times_out_instead_of_hanging(tmp_path):
    root = _shop(tmp_path)
    _write(root, "ServerScriptService/Spin.server.luau", "while true do end\n")
    out = checks.run_headless(root, {"mode": "boot"}, timeout=2)
    assert "timed out" in out["error"]


def test_triage_trusts_only_offline_passes(tmp_path):
    root = _shop(tmp_path)
    ok = checks.parse(CHECK_OK, "buy")
    fail = checks.parse("-- check: f\nreturn { ok = false, detail = 'x' }\n", "fail")
    studio = checks.parse("-- check: physics\n-- needs: studio\nreturn { ok = true, detail = '' }\n", "phys")
    passed, need = checks.triage(root, [ok, fail, studio])
    assert [r["id"] for r in passed] == ["buy"]
    assert [c.id for c in need] == ["fail", "phys"]


def test_needs_header_round_trips():
    c = checks.parse("-- check: t\n-- covers: c\n-- needs: studio\nreturn {ok=true}\n", "t")
    assert c.needs == "studio"
    again = checks.parse(checks.render(c), "t")
    assert again.needs == "studio" and checks.render(again).count("-- needs:") == 1
    assert "-- needs" not in checks.render(checks.parse("-- check: t\nreturn 1\n", "t"))


def test_datatypes_behave(tmp_path):
    root = _shop(tmp_path)
    body = """
local cf = CFrame.lookAt(Vector3.new(0, 0, 0), Vector3.new(0, 0, -10))
local look = cf.LookVector
local moved = CFrame.new(1, 2, 3) * CFrame.Angles(0, math.pi / 2, 0)
local back = moved * moved:Inverse()
local p = Instance.new("Part")
p.Position = Vector3.new(5, 6, 7)
local ok = (look - Vector3.new(0, 0, -1)).Magnitude < 1e-6
	and back.Position.Magnitude < 1e-6
	and p.CFrame.Position == Vector3.new(5, 6, 7)
	and Color3.fromRGB(255, 0, 0).R == 1
	and UDim2.fromScale(1, 0.5).Y.Scale == 0.5
	and Enum.Material.Plastic == Enum.Material.Plastic
	and typeof(Vector3.zero) == "Vector3" and typeof(p) == "Instance"
	and game:GetService("HttpService"):JSONDecode('{"a":[1,2]}').a[2] == 2
return { ok = ok, detail = tostring(look) }
"""
    res = checks.run_check_offline(root, checks.parse(body, "dt"))
    assert res["ok"], res


def test_incremental_pull_script_skips_unchanged_files(tmp_path):
    """The Luau half of incremental sync, run against the fake engine: first pull creates every
    script, a second identical pull skips them all, an edit re-pushes only that file, and a
    removed file is pruned."""
    root = tmp_path / "g"
    _write(root, "ReplicatedStorage/A.luau", "return 1\n")
    _write(root, "ServerScriptService/Main.server.luau", "print('main')\n")
    _write(root, "ServerScriptService/Lib/B.luau", "return 'b'\n")
    _write(root, "ReplicatedStorage/Old/Deep/Gone.luau", "return 0\n")

    def pull(pushed):
        entries = fsync.manifest_entries(root)
        return fsync.pull_luau(1, prune=True, manifest=entries, inline=fsync.inline_plan(root, entries, pushed))

    first = pull(None)
    second = pull(fsync.hashes(fsync.manifest_entries(root)))
    _write(root, "ServerScriptService/Lib/B.luau", "return 'b2'\n")
    (root / "ReplicatedStorage" / "A.luau").unlink()
    shutil.rmtree(root / "ReplicatedStorage" / "Old")
    third = pull({"ReplicatedStorage/A.luau": "x", **{
        p: h for p, h in fsync.hashes(fsync.manifest_entries(root)).items() if not p.endswith("B.luau")}})
    headless = (REPO / "game/tools/headless.luau").read_text()
    prog = ["local H = (function()", headless, "end)()",
            "local function run(src) local f = assert(loadstring(src)); setfenv(f, setmetatable({}, {__index = function(_, k) local v = H.G[k]; if v ~= nil then return v end; return _G[k] end})); print(f()) end"]
    for src in (first, second, third):
        prog.append(f"run({fsync.long_string(src)})")
    prog.append('local b = H.game:GetService("ServerScriptService").Lib.B; print("B=" .. b.Source .. "|" .. tostring(b:GetAttribute("ForgeHash")))')
    prog_file = tmp_path / "prog.luau"
    prog_file.write_text("\n".join(prog))
    out = subprocess.run(["luau", str(prog_file)], capture_output=True, text=True, timeout=20)
    assert out.returncode == 0, out.stderr
    lines = out.stdout.splitlines()
    assert lines[0].startswith("OK 4 files, changed: ") and "skipped 0, fetched 0" in lines[0]
    assert lines[1] == "OK 4 files, changed: none; skipped 4, fetched 0"
    assert "changed: ServerScriptService/Lib/B.luau" in lines[2] and "ReplicatedStorage.A" in lines[2]
    assert "ReplicatedStorage.Old.Deep.Gone" in lines[2]
    # emptied folders the sync made are pruned too (deepest first); Lib still holds B
    assert "ReplicatedStorage.Old.Deep, ReplicatedStorage.Old;" in lines[2] and ".Lib," not in lines[2]
    assert "skipped 1, fetched 0" in lines[2]
    assert lines[3] == "B=return 'b2'"
    assert lines[4] == "|" + fsync.hashes(fsync.manifest_entries(root))["ServerScriptService/Lib/B.luau"]


@pytest.mark.parametrize("game", ["games/tiny-tycoon/game", "game"])
def test_real_games_boot_headless(game):
    root = REPO / game
    if not (root / "ServerScriptService").is_dir():
        pytest.skip(f"{game} not present")
    rep = checks.boot_offline(root, boot=1, play=1)
    assert "error" not in rep, rep
    assert rep["players"] == 1


# ---------------------------------------------------------------- forge.startRound across rounds (Flame and Blame run 2)

ROUND_GAME = """
local HttpService = game:GetService("HttpService")
-- the last round is still showing its results; the game frees its players only back in the lobby
workspace:SetAttribute("RoundState", "Results")
task.delay(12, function()
	workspace:SetAttribute("RoundState", "Lobby")
end)
local f = Instance.new("BindableFunction")
f.Name = "ForgeTest"
f.OnInvoke = function(cmd, argsJson)
	local args = HttpService:JSONDecode(argsJson)
	-- like MissionService:StartRound: nobody is free during Results, so a start then does nothing
	if cmd == "round" and args.state == "Active" and workspace:GetAttribute("RoundState") == "Lobby" then
		workspace:SetAttribute("RoundState", "Active")
	end
	return HttpService:JSONEncode({ ok = true, result = { via = "MissionService:StartRound" } })
end
f.Parent = game:GetService("ServerStorage")
"""


def _with_helpers(body: str) -> str:
    """A check body with the `forge` helpers in front (the headless engine runs bodies unwrapped)."""
    return ('local __http = game:GetService("HttpService")\n' + checks.HELPERS
            + "return (function()\n" + body + "\nend)()\n")


def test_start_round_waits_out_the_last_rounds_results_phase(tmp_path):
    _write(tmp_path, "ServerScriptService/Round.server.luau", ROUND_GAME)
    _write(tmp_path, "ServerScriptService/MissionService.luau", "return {}\n")  # the game drives its rounds
    body = ("forge.startRound(15)\n"
            "return { ok = workspace:GetAttribute('RoundState') == 'Active', "
            "detail = tostring(workspace:GetAttribute('RoundState')) }")
    res = checks.run_check_offline(tmp_path, checks.parse(_with_helpers(body), "round"))
    assert res["ok"] is True and res["detail"] == "Active", res
    # what run 2's helper did: start at once and wait for Active, which never comes
    old = ("forge.harness('round', { state = 'Active' })\n"
           "local up = forge.waitFor(function() return workspace:GetAttribute('RoundState') == 'Active' end, 15)\n"
           "return { ok = up == true, detail = tostring(workspace:GetAttribute('RoundState')) }")
    res = checks.run_check_offline(tmp_path, checks.parse(_with_helpers(old), "old"))
    assert res["ok"] is False and res["detail"] == "Lobby", res


ATTRIBUTE_GAME = """
local HttpService = game:GetService("HttpService")
workspace:SetAttribute("RoundState", "Results")  -- left by the harness's own `round Results`: nothing ends it
local f = Instance.new("BindableFunction")
f.Name = "ForgeTest"
f.OnInvoke = function(cmd, argsJson)
	local args = HttpService:JSONDecode(argsJson)
	if cmd == "round" and args.state then
		workspace:SetAttribute("RoundState", args.state)  -- no MissionService: the harness sets the attribute
	end
	return HttpService:JSONEncode({ ok = true, result = { via = "attribute" } })
end
f.Parent = game:GetService("ServerStorage")
"""


def test_start_round_does_not_wait_when_no_game_code_drives_rounds(tmp_path):
    _write(tmp_path, "ServerScriptService/Round.server.luau", ATTRIBUTE_GAME)
    body = ("local t0 = os.clock()\nforge.startRound(15)\n"
            "return { ok = workspace:GetAttribute('RoundState') == 'Active', detail = tostring(os.clock() - t0) }")
    res = checks.run_check_offline(tmp_path, checks.parse(_with_helpers(body), "attr"))
    assert res["ok"] is True and float(res["detail"]) < 2, res
