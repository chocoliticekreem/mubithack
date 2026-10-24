"""ForgeTelemetry's client channel (game/ReplicatedStorage/ForgeTelemetry.luau): LocalScripts count through
one shared, rate-limited remote the server creates; the server validates every name and amount. The server
half runs in the headless engine (game/tools/headless.luau), the client half in a small fake engine."""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from forge import checks

REPO = Path(__file__).resolve().parent.parent
MODULE = REPO / "game" / "ReplicatedStorage" / "ForgeTelemetry.luau"
pytestmark = pytest.mark.skipif(shutil.which("luau") is None, reason="luau CLI not installed")


def _game(root: Path) -> Path:
    for rel, text in {
        "ReplicatedStorage/ForgeTelemetry.luau": MODULE.read_text(),
        "ServerScriptService/Main.server.luau": (
            'local T = require(game:GetService("ReplicatedStorage"):WaitForChild("ForgeTelemetry"))\n'
            'T.count("booted", 1)\n'),
    }.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    return root


def _server_check(tmp_path, body: str) -> dict:
    head = ('local RS = game:GetService("ReplicatedStorage")\n'
            'local HttpService = game:GetService("HttpService")\n'
            'local T = require(RS:WaitForChild("ForgeTelemetry"))\n'
            'local remote = RS:FindFirstChild("ForgeTelemetryRemote")\n'
            'if not remote then error("setup: the server made no ForgeTelemetryRemote") end\n'
            'local p = game:GetService("Players"):GetPlayers()[1]\n'
            'if not p then error("setup: no player") end\n')
    res = checks.run_check_offline(_game(tmp_path), checks.parse(head + body, "telemetry"), timeout=10)
    assert res.get("boot_errors") == 0, res
    return res


def test_server_counts_valid_client_names_and_drops_the_rest(tmp_path):
    res = _server_check(tmp_path, """
remote.OnServerEvent:Fire(p, { zone_banner = 2, hud_pop = 1, ["bad name"] = 1, RBXhack = 1, neg = -3,
	nan = 0 / 0, big = 5000, text = "7" })
remote.OnServerEvent:Fire(p, "not a table")
task.wait(0.1)
local c = T.get()
return { ok = c.zone_banner == 2 and c.hud_pop == 1 and c.big == 1000 and c.booted == 1
	and c.bad_name == nil and c.RBXhack == nil and c._RBXhack == nil and c.neg == nil and c.text == nil
	and c.telemetry_client_dropped == 6, detail = HttpService:JSONEncode(c) }
""")
    assert res["ok"], res


def test_server_rate_limits_each_player(tmp_path):
    res = _server_check(tmp_path, """
for _ = 1, 12 do
	remote.OnServerEvent:Fire(p, { tick = 1 })
end
local c = T.get()
return { ok = c.tick == 8 and c.telemetry_client_dropped == 4, detail = HttpService:JSONEncode(c) }
""")
    assert res["ok"], res


def test_server_caps_distinct_names_per_player(tmp_path):
    res = _server_check(tmp_path, """
for m = 0, 2 do
	local batch = {}
	for i = 1, 30 do
		batch["n" .. (m * 30 + i)] = 1
	end
	remote.OnServerEvent:Fire(p, batch)
end
local c, names = T.get(), 0
for k in c do
	if string.match(k, "^n%d+$") then names += 1 end
end
remote.OnServerEvent:Fire(p, { n1 = 1 })
local again = T.get()
local seen = 0
for i = 1, 90 do
	if again["n" .. i] then seen += 1 end
end
return { ok = names == 64 and c.telemetry_client_dropped == 26 and seen == 64,
	detail = names .. " names, dropped " .. tostring(c.telemetry_client_dropped) }
""")
    assert res["ok"], res


def test_a_second_vm_does_not_listen_twice(tmp_path):
    # execute_luau runs in its own VM: requiring the module there must not add a second listener.
    res = _server_check(tmp_path, """
local fresh = RS.ForgeTelemetry:Clone()
fresh.Parent = RS
local T2 = require(fresh)
remote.OnServerEvent:Fire(p, { once = 1 })
return { ok = T.get().once == 1 and remote:GetAttribute("Listening") == true and T2 ~= nil,
	detail = tostring(T.get().once) }
""")
    assert res["ok"], res


# ------------------------------------------------------------------------------------- client half

CLIENT_HARNESS = r"""
local fired, delayed, created = {}, {}, 0
local remote = { Name = "ForgeTelemetryRemote" }
function remote:IsA(c) return c == "RemoteEvent" end
function remote:FireServer(batch) table.insert(fired, batch) end
local studio = __STUDIO__
local services = {
	RunService = { IsServer = function() return false end, IsClient = function() return true end,
		IsStudio = function() return studio end, IsRunning = function() return true end },
	ReplicatedStorage = { FindFirstChild = function(_, n) return if n == "ForgeTelemetryRemote" then remote else nil end,
		WaitForChild = function() error("waited") end },
	Players = { PlayerRemoving = { Connect = function() end } },
	ServerStorage = {},
}
local game = { GetService = function(_, n) return services[n] end }
local Instance = { new = function() created += 1; return {} end }
local task = { delay = function(_, f) table.insert(delayed, f) end }
local T = (function()
__MODULE__
end)()
T.count("zone_banner")
T.count("zone_banner", 2)
T.count("hud pop")
T.count("bad", -1)
T.count("nan", 0 / 0)
T.count(("x"):rep(80))
local nGets = 0
for _ in T.get() do nGets += 1 end
local queued = #delayed
for _, f in delayed do f() end
T.count("later", 1)
for i = queued + 1, #delayed do delayed[i]() end
local scheduled = #delayed
for i = 1, 40 do T.count("many" .. i) end
for i = scheduled + 1, #delayed do delayed[i]() end
local out = {}
for i, b in fired do
	local keys = {}
	for k, v in b do table.insert(keys, k .. "=" .. tostring(v)) end
	table.sort(keys)
	out[i] = if i <= 2 then table.concat(keys, ",") else tostring(#keys)
end
print("@@" .. table.concat(out, ";") .. "|" .. queued .. "|" .. scheduled .. "|" .. nGets .. "|" .. created)
"""


def _client(tmp_path: Path, studio: bool) -> str:
    src = (CLIENT_HARNESS.replace("__STUDIO__", "true" if studio else "false")
           .replace("__MODULE__", MODULE.read_text()))
    path = tmp_path / "client.luau"
    path.write_text(src)
    r = subprocess.run([shutil.which("luau"), str(path)], capture_output=True, text=True, timeout=20)
    line = next((ln for ln in r.stdout.splitlines() if ln.startswith("@@")), None)
    assert line, r.stdout + r.stderr
    return line[2:]


def test_client_sums_counts_into_one_message_per_flush(tmp_path):
    batches, queued, scheduled, gets, created = _client(tmp_path, True).split("|")
    first, second, third = batches.split(";")
    assert first == "hud_pop=1,zone_banner=3"  # names cleaned like the server's; bad amounts dropped
    assert second == "later=1"  # the next count after a flush starts a new message
    assert third == "32"  # a message never carries more names than the server accepts
    assert (queued, scheduled) == ("1", "2")  # one flush per window, never a yield in count()
    assert gets == "0" and created == "0"  # get() is server only; the client creates no Instances


def test_client_channel_is_off_outside_studio(tmp_path):
    batches, queued, _, _, _ = _client(tmp_path, False).split("|")
    assert batches == "" and queued == "0"


def test_module_still_compiles_and_documents_the_client_channel():
    text = MODULE.read_text()
    if shutil.which("luau-compile"):
        assert subprocess.run(["luau-compile", "--null", str(MODULE)], capture_output=True).returncode == 0
    assert "LocalScripts" in text and '"ForgeTelemetryRemote"' in text and '"telemetry_client_dropped"' in text
