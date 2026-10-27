--!strict
-- AnalyticsController [owner: Analytics]. The client half of Services/TrackService (docs/game/20-analytics.md).
-- Sends three kinds of report through Analytics/Client; the server validates, caps and records them:
--   "ui"    a popup / panel (Lib/Analytics/Schema.Screens) opened or closed, with seconds open. Watched,
--           not called: every UiWatchSeconds it checks each listed ScreenGui for a visible, opaque panel
--           covering >= MinPanelShare of the screen, so no other controller needs an analytics call.
--   "error" a LocalScript error (ScriptContext.Error), deduplicated, at most MaxErrors per session
--   "perf"  only when the server sampled this session (Player attr AnalyticsPerf = seconds): average fps,
--           worst 1-second fps, ping, memory, graphics quality
-- Reads: Player attr AnalyticsPerf. No UI of its own.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ScriptContext = game:GetService("ScriptContext")
local Stats = game:GetService("Stats")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net") :: ModuleScript)
local Schema = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Analytics"):WaitForChild("Schema") :: ModuleScript)

local AnalyticsController = {}
AnalyticsController.Priority = 200 -- last: it only watches

local UI_WATCH_SECONDS = 1
local MIN_PANEL_SHARE = 0.1 -- of the viewport area
local MAX_DEPTH = 3
local MAX_ERRORS = 15
local PERF_ATTR = "AnalyticsPerf"

local player = Players.LocalPlayer
local remote: RemoteEvent? = nil
local queued: { { any } } = {}

local function send(kind: string, data: { [string]: any })
	if remote then
		(remote :: RemoteEvent):FireServer(kind, data)
	elseif #queued < 20 then
		table.insert(queued, { kind, data })
	end
end

------------------------------------------------------------------------------------------ ui

local function opaque(g: GuiObject): boolean
	if g.BackgroundTransparency < 0.9 then
		return true
	end
	if g:IsA("ImageLabel") or g:IsA("ImageButton") then
		return g.ImageTransparency < 0.9 and g.Image ~= ""
	end
	return false
end

local function hasPanel(node: Instance, depth: number, minArea: number): boolean
	for _, c in node:GetChildren() do
		if not c:IsA("GuiObject") or not c.Visible then
			continue
		end
		local s = c.AbsoluteSize
		if s.X * s.Y >= minArea and opaque(c) then
			return true
		end
		if depth < MAX_DEPTH and hasPanel(c, depth + 1, minArea) then
			return true
		end
	end
	return false
end

local function isOpen(gui: Instance?): boolean
	if not gui or not gui:IsA("ScreenGui") or not gui.Enabled then
		return false
	end
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	return hasPanel(gui, 1, vp.X * vp.Y * MIN_PANEL_SHARE)
end

local function watchUi()
	local playerGui = player:WaitForChild("PlayerGui")
	local openAt: { [string]: number } = {}
	while true do
		task.wait(UI_WATCH_SECONDS)
		for _, name in Schema.Screens do
			local ok, open = pcall(isOpen, playerGui:FindFirstChild(name))
			open = ok and open
			if open and not openAt[name] then
				openAt[name] = os.clock()
				send("ui", { screen = name, open = true })
			elseif not open and openAt[name] then
				send("ui", { screen = name, open = false, seconds = os.clock() - openAt[name] })
				openAt[name] = nil
			end
		end
	end
end

------------------------------------------------------------------------------------------ errors

local sentErrors = 0
local seen: { [string]: boolean } = {}

local function onError(message: string, trace: string, scr: Instance?)
	if sentErrors >= MAX_ERRORS then
		return
	end
	local source = if scr then scr:GetFullName() else "?"
	local key = source .. "|" .. string.sub(message, 1, 80)
	if seen[key] then
		return
	end
	seen[key] = true
	sentErrors += 1
	send("error", {
		message = string.sub(message, 1, 300),
		source = string.sub(source, 1, 150),
		trace = string.sub(trace or "", 1, 400),
	})
end

------------------------------------------------------------------------------------------ perf

local function perfLoop()
	local frames, windowFrames, windowStart, periodStart = 0, 0, os.clock(), os.clock()
	local worst = math.huge
	RunService.RenderStepped:Connect(function()
		frames += 1
		windowFrames += 1
		local now = os.clock()
		if now - windowStart >= 1 then
			worst = math.min(worst, windowFrames / (now - windowStart))
			windowFrames, windowStart = 0, now
		end
	end)
	while true do
		task.wait(5)
		local every = player:GetAttribute(PERF_ATTR)
		local now = os.clock()
		if type(every) ~= "number" then
			frames, periodStart, worst = 0, now, math.huge
			continue
		end
		if now - periodStart < math.max(30, every) then
			continue
		end
		local fps = frames / (now - periodStart)
		local quality: number? = nil
		pcall(function()
			quality = (UserSettings():GetService("UserGameSettings") :: any).SavedQualityLevel.Value
		end)
		local ping: number? = nil
		pcall(function()
			ping = player:GetNetworkPing() * 1000
		end)
		send("perf", {
			fps = fps,
			fps_low = if worst < math.huge then worst else fps,
			ping = ping,
			mem = Stats:GetTotalMemoryUsageMb(),
			quality = quality,
		})
		frames, periodStart, worst = 0, now, math.huge
	end
end

------------------------------------------------------------------------------------------ lifecycle

function AnalyticsController:Init(_: { [string]: any }) end

function AnalyticsController:Start()
	ScriptContext.Error:Connect(function(message: string, trace: string, scr: Instance?)
		pcall(onError, message, trace, scr)
	end)
	task.spawn(watchUi)
	task.spawn(perfLoop)
	remote = Net.event("Analytics", "Client") -- waits for the server to declare it
	for _, q in queued do
		(remote :: RemoteEvent):FireServer(q[1], q[2])
	end
	queued = {}
end

return AnalyticsController
