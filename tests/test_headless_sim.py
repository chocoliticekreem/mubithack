"""The headless engine's simulated players (game/tools/headless.luau + forge.headless): clients running
their LocalScripts, remotes client <-> server, kinematic walking, Touched, ProximityPrompts, the virtual
clock, spatial queries, and the honesty rule (anything it can't model is needs_studio, never a pass)."""
from __future__ import annotations

import asyncio
import json
import shutil
from pathlib import Path

import pytest

from forge import checks
from forge import headless as hl

REPO = Path(__file__).resolve().parent.parent
pytestmark = pytest.mark.skipif(shutil.which("luau") is None, reason="luau CLI not installed")


def _write(root: Path, rel: str, text: str) -> None:
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


def _game(root: Path) -> Path:
    """A server with a pad (Touched), a prompt (Triggered), remotes both ways and a client script."""
    _write(root, "ServerScriptService/World.server.luau", r"""
local RS = game:GetService("ReplicatedStorage")
local pad = Instance.new("Part")
pad.Name = "Pad"
pad.Anchored = true
pad.Size = Vector3.new(6, 1, 6)
pad.Position = Vector3.new(30, 0.5, 0)
pad.Parent = workspace
pad:SetAttribute("Touches", 0)
pad:SetAttribute("Ended", 0)
pad.Touched:Connect(function(hit)
	if game.Players:GetPlayerFromCharacter(hit.Parent) then
		pad:SetAttribute("Touches", pad:GetAttribute("Touches") + 1)
	end
end)
pad.TouchEnded:Connect(function(hit)
	pad:SetAttribute("Ended", pad:GetAttribute("Ended") + 1)
end)
local post = Instance.new("Part")
post.Name = "Post"
post.Anchored = true
post.Position = Vector3.new(0, 3, 20)
post.Parent = workspace
local prompt = Instance.new("ProximityPrompt")
prompt.HoldDuration = 0.5
prompt.MaxActivationDistance = 8
prompt.Parent = post
prompt.Triggered:Connect(function(player)
	workspace:SetAttribute("TriggeredBy", player.Name)
end)
local ev = Instance.new("RemoteEvent")
ev.Name = "Ping"
ev.Parent = RS
ev.OnServerEvent:Connect(function(player, payload)
	workspace:SetAttribute("PingFrom", player.Name .. ":" .. tostring(payload.n))
	payload.n = 999 -- the client's table must not change (arguments are copied)
	ev:FireClient(player, { reply = payload.n + 1 })
end)
local fn = Instance.new("RemoteFunction")
fn.Name = "Ask"
fn.Parent = RS
fn.OnServerInvoke = function(player, x)
	return player.Name .. "=" .. tostring(x * 2)
end
""")
    _write(root, "StarterPlayerScripts/Client.client.luau", r"""
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer
local ev = RS:WaitForChild("Ping")
local fn = RS:WaitForChild("Ask")
fn.OnClientInvoke = function(q)
	return lp.Name .. " answers " .. tostring(q)
end
local mine = Instance.new("Folder")
mine.Name = "ClientOnly_" .. lp.Name
mine.Parent = workspace
local sent = { n = lp.UserId }
ev.OnClientEvent:Connect(function(msg)
	lp:SetAttribute("Reply", msg.reply)
	lp:SetAttribute("SentStill", sent.n)
end)
ev:FireServer(sent)
lp:SetAttribute("Asked", fn:InvokeServer(21))
lp:SetAttribute("IsClient", game:GetService("RunService"):IsClient())
""")
    return root


def _check(body: str, cid: str = "c", needs: str = "") -> checks.Check:
    head = f"-- check: {cid}\n" + (f"-- needs: {needs}\n" if needs else "")
    return checks.parse(head + body, cid)


def test_clients_run_localscripts_and_remotes_cross_both_ways(tmp_path):
    root = _game(tmp_path)
    res = checks.run_check_offline(root, _check(r"""
local p = game.Players:GetPlayers()[1]
task.wait(0.5)
local ok = p:GetAttribute("Reply") == 1000 and p:GetAttribute("SentStill") == p.UserId
	and workspace:GetAttribute("PingFrom") == p.Name .. ":" .. p.UserId
	and p:GetAttribute("Asked") == p.Name .. "=42" and p:GetAttribute("IsClient") == true
	and game:GetService("RunService"):IsServer() and game.Players.LocalPlayer == nil
return { ok = ok, detail = tostring(p:GetAttribute("Reply")) .. " " .. tostring(p:GetAttribute("Asked")) }
"""))
    assert res["ok"], res
    assert res["verdict"] == "pass"


def test_server_cannot_see_what_a_client_created_and_invokes_each_client(tmp_path):
    root = _game(tmp_path)
    res = checks.run_check_offline(root, _check(r"""
local p = game.Players:GetPlayers()[1]
task.wait(0.2)
local hidden = workspace:FindFirstChild("ClientOnly_" .. p.Name) == nil
local answer = game.ReplicatedStorage.Ask:InvokeClient(p, "q")
return { ok = hidden and answer == p.Name .. " answers q", detail = tostring(answer) }
"""))
    assert res["ok"], res


def test_server_only_calls_fail_loudly_from_the_wrong_side(tmp_path):
    root = _game(tmp_path)
    res = checks.run_check_offline(root, _check(r"""
local ok, err = pcall(function() game.ReplicatedStorage.Ping:FireServer(1) end)
return { ok = not ok and string.find(tostring(err), "only be called from the client") ~= nil, detail = tostring(err) }
"""))
    assert res["ok"], res


def test_walking_onto_a_pad_fires_touched_once_and_touch_ended_on_leaving(tmp_path):
    root = _game(tmp_path)
    res = checks.run_check_offline(root, _check(r"""
local p = game.Players:GetPlayers()[1]
local hum = p.Character.Humanoid
local root = p.Character.HumanoidRootPart
root.CFrame = CFrame.new(0, 3, 0)
local t0 = os.clock()
hum:MoveTo(workspace.Pad.Position)
local reached = hum.MoveToFinished:Wait()
local took = os.clock() - t0
task.wait(1)
local touches = workspace.Pad:GetAttribute("Touches")
hum:MoveTo(Vector3.new(0, 0.5, 0))
hum.MoveToFinished:Wait()
local ended = workspace.Pad:GetAttribute("Ended")
-- 30 studs at WalkSpeed 16: about 1.9 s of simulated time
return { ok = reached and touches == 1 and ended >= 1 and took > 1.5 and took < 2.5,
	detail = string.format("reached=%s touches=%d ended=%d took=%.2f", tostring(reached), touches, ended, took) }
"""))
    assert res["ok"], res


def test_virtual_clock_runs_a_long_wait_fast(tmp_path):
    root = _game(tmp_path)
    import time
    t0 = time.time()
    res = checks.run_check_offline(root, _check(r"""
local beats = 0
local c = game:GetService("RunService").Heartbeat:Connect(function() beats += 1 end)
local t = os.clock()
task.wait(60)
c:Disconnect()
return { ok = os.clock() - t >= 60 and beats >= 1700, detail = tostring(beats) }
""", "clock"), timeout=90)
    assert res["ok"], res
    assert time.time() - t0 < 20  # a minute of game time, seconds of wall time


def test_datastore_is_in_memory(tmp_path):
    root = _game(tmp_path)
    res = checks.run_check_offline(root, _check(r"""
local ds = game:GetService("DataStoreService"):GetDataStore("Saves")
ds:SetAsync("k", { coins = 5 })
ds:UpdateAsync("k", function(old) old.coins += 1 return old end)
return { ok = ds:GetAsync("k").coins == 6, detail = tostring(ds:GetAsync("k").coins) }
"""))
    assert res["ok"], res


def test_raycast_and_overlap_queries_see_part_boxes(tmp_path):
    root = _game(tmp_path)
    res = checks.run_check_offline(root, _check(r"""
local hit = workspace:Raycast(Vector3.new(30, 10, 0), Vector3.new(0, -20, 0))
local inBox = workspace:GetPartBoundsInBox(CFrame.new(30, 0.5, 0), Vector3.new(2, 2, 2))
local found = false
for _, p in inBox do if p.Name == "Pad" then found = true end end
return { ok = hit ~= nil and hit.Instance.Name == "Pad" and math.abs(hit.Position.Y - 1) < 1e-6
	and hit.Normal.Y > 0.99 and found, detail = tostring(hit and hit.Instance) }
"""))
    assert res["ok"], res


def test_physics_movers_are_needs_studio_never_a_pass(tmp_path):
    root = _game(tmp_path)
    mover = _check(r"""
local bv = Instance.new("BodyVelocity")
bv.Parent = workspace.Pad
return { ok = true, detail = "claims a pass" }
""", "mover")
    res = checks.run_check_offline(root, mover)
    assert res["ok"] is False and res["verdict"] == "needs_studio"
    assert "physics: BodyVelocity" in res["needs_studio"]
    passed, need = checks.triage(root, [mover], mode="auto")
    assert passed == [] and [c.id for c in need] == ["mover"]
    kept, need = checks.triage(root, [mover], mode="never")
    assert need == [] and kept[0]["ok"] is False and kept[0]["setup"] is True


def test_triage_policy_always_runs_nothing_headless(tmp_path):
    root = _game(tmp_path)
    c = _check("return { ok = true, detail = '' }")
    assert checks.triage(root, [c], mode="always") == ([], [c])
    passed, need = checks.triage(root, [c], mode="auto")
    assert [r["id"] for r in passed] == ["c"] and need == []


def test_boot_report_lists_needs_studio_and_approximations(tmp_path):
    root = _game(tmp_path)
    _write(root, "ServerScriptService/Physics.server.luau",
           'local p = Instance.new("Part") p.Parent = workspace p:ApplyImpulse(Vector3.new(0, 100, 0))\n')
    rep = checks.boot_offline(root, clients=True)
    assert rep["errors"] == [], rep["errors"]
    assert any(n["feature"] == "physics: ApplyImpulse" for n in rep["needs_studio"])
    assert rep["clients"] is True and rep["engine"] == "headless"


# ---------------------------------------------------------------- sessions (HeadlessStudio)


def _run(coro):
    return asyncio.run(coro)


def test_session_answers_execute_luau_and_holds_prompts_in_range(tmp_path):
    root = _game(tmp_path)

    async def go():
        hs = hl.HeadlessStudio(root, players=1, idle=0.0)
        await hs.play()
        try:
            # out of range: nothing happens
            far = await hs.execute_luau(r"""
local post = workspace.Post
local root = game.Players.LocalPlayer.Character.HumanoidRootPart
root.CFrame = CFrame.new(0, 3, 60)
task.wait(0.3)
local prompt = post.ProximityPrompt
prompt:InputHoldBegin() task.wait(0.7) prompt:InputHoldEnd()
return tostring(workspace:GetAttribute("TriggeredBy"))""", "Client")
            near = await hs.execute_luau(r"""
local root = game.Players.LocalPlayer.Character.HumanoidRootPart
root.CFrame = CFrame.new(0, 3, 16)
local shown = false
game:GetService("ProximityPromptService").PromptShown:Connect(function() shown = true end)
task.wait(0.3)
local prompt = workspace.Post.ProximityPrompt
prompt:InputHoldBegin() task.wait(0.7) prompt:InputHoldEnd()
return tostring(shown) .. " " .. tostring(workspace:GetAttribute("TriggeredBy"))""", "Client")
            st = await hs.state()
            rep = await hs.probe_report()
            with pytest.raises(hl.NeedsStudio):
                await hs.screenshot(tmp_path / "x.png")
            return far, near, st, rep
        finally:
            await hs.stop()

    far, near, st, rep = _run(go())
    assert far == "nil"
    assert near == "true HeadlessPlayer1"
    assert st["playing"] is True and "Client" in st["datamodels"]
    assert rep["errors"] == [] and rep["players"] == 1


def test_session_advances_time_between_calls_and_reports_errors(tmp_path):
    root = _game(tmp_path)

    async def go():
        hs = hl.HeadlessStudio(root, players=1, idle=5.0)
        await hs.play()
        try:
            a = float(await hs.execute_luau("return os.clock()", "Server"))
            b = float(await hs.execute_luau("return os.clock()", "Server"))
            with pytest.raises(hl.StudioError):
                await hs.execute_luau("error('boom')", "Server")
            return a, b
        finally:
            await hs.stop()

    a, b = _run(go())
    assert b - a >= 5


def test_forge_test_harness_drives_a_simulated_player_headless(tmp_path):
    """The real ForgeTest server + ForgeTestAgent client, driven by mubit_tester's Harness over a session:
    a tester walks onto the pad (Touched) and holds the prompt (Triggered) with no Studio."""
    from mubit_tester.harness import Harness

    root = _game(tmp_path)
    _write(root, "ServerScriptService/ForgeTest.server.luau",
           (REPO / "mubit-tester/roblox/ForgeTest.server.luau").read_text())
    _write(root, "StarterPlayerScripts/ForgeTestAgent.client.luau",
           (REPO / "mubit-tester/roblox/ForgeTestAgent.client.luau").read_text())

    async def go():
        hs = hl.HeadlessStudio(root, players=1, idle=0.0)
        await hs.play()
        try:
            h = Harness(hs)
            players = await h.players()
            walk = await h.act("1", "walk_to", path="Workspace.Pad")
            use = await h.act("1", "go_use", path="Workspace.Post")
            touches = await hs.execute_luau('return workspace.Pad:GetAttribute("Touches")', "Server")
            by = await hs.execute_luau('return workspace:GetAttribute("TriggeredBy")', "Server")
            rep = await hs.probe_report()
            return players, walk, use, touches, by, rep
        finally:
            await hs.stop()

    players, walk, use, touches, by, rep = _run(go())
    assert players and players[0]["agent"] is True
    assert walk["done"] is True, walk
    assert int(touches) >= 1
    assert use.get("done") is True and by == "HeadlessPlayer1", use
    assert rep["errors"] == [], rep["errors"]


def test_headless_playtest_has_probe_fields_and_census(tmp_path):
    root = _game(tmp_path)
    rep = _run(hl.playtest(root, play=5, players=2))
    assert rep["engine"] == "headless" and rep["errors"] == [] and rep["players"] == 2
    assert rep["census"]["parts"] >= 2 and "client_error" not in rep["census"]
    assert rep["simulated"] >= 5


# ---------------------------------------------------------------- policy + ledger


def test_studio_mode_and_the_overloaded_flag(monkeypatch):
    monkeypatch.delenv("FORGE_STUDIO_MODE", raising=False)
    assert hl.studio_mode() == "auto"
    monkeypatch.setenv("FORGE_STUDIO_MODE", "never")
    assert hl.studio_mode() == "never" and hl.studio_mode("always") == "always"
    with pytest.raises(ValueError):
        hl.studio_mode("sometimes")
    assert hl.split_studio_arg("auto") == ("auto", None)
    assert hl.split_studio_arg("Forge-agents-3") == (None, "Forge-agents-3")
    assert hl.split_studio_arg(None) == (None, None)


def test_usage_ledger_counts_where_things_ran(tmp_path):
    p = tmp_path / "u.jsonl"
    hl.record("check", "headless", 0.2, n=9, path=p)
    hl.record("check", "studio", 30, n=1, path=p)
    hl.record("playtest", "studio", 90, path=p)
    st = hl.usage_stats(path=p)
    assert st["headless"] == 9 and st["studio"] == 2
    assert st["share_headless"] == round(9 / 11, 3)
    assert st["studio_minutes"] == 2.0
    assert st["by_kind"]["check"] == {"headless": 9, "studio": 1}


def test_luau_string_escapes_everything_onto_one_line():
    s = 'a "b" \\ c\nd\te\x01'
    lit = hl.luau_string(s)
    assert "\n" not in lit and lit.startswith('"')
    assert json.loads(json.dumps(lit))  # plain text
