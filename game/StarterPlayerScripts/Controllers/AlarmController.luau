--!strict
-- AlarmController [owner: G2]. Client-only station alarm (docs/game/02 §2 "Alarm" overlay, trailer t=3).
-- The station's alarm lamps (parts tagged AlarmLamp, plus StationBuilder's "AlarmLight" Models' "Bulb"
-- parts) switch their lights on, grow a rotating red beacon (two local SpotLights on spinning
-- Attachments), the bulbs pulse, and a local ColorCorrection "AlarmCC" pulses white <-> red at 1 Hz.
-- Triggers:
--   * Mission/Alarm (S->C squad: missionId, title) -> runs for GameConfig.AlarmSeconds
--   * Lobby/Countdown (S->C squad: padId, seconds, title) -> lamps fire when it hits
--     LobbyConfig.AlarmFromSeconds (3) and run to launch
--   * Lobby/Board (S->C all: squads) -> when a squad turns "Launching" (LobbyConfig.FullCountdownSeconds
--     left), everyone else in the station sees the lamps too as that countdown hits 3
-- Public (for other controllers): AlarmController:Run(seconds: number)
-- Nothing here affects gameplay; everything is restored afterwards.
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local GameConfig = require(ConfigFolder:WaitForChild("GameConfig") :: ModuleScript) :: any
local LobbyConfig = require(ConfigFolder:WaitForChild("LobbyConfig") :: ModuleScript) :: any

local AlarmController = {}
AlarmController.Priority = 60

local RED = Color3.fromRGB(255, 70, 60)
local runUntil = 0
local running = false
local seenLaunch: { [string]: boolean } = {}

local function lamps(): { BasePart }
	local out: { BasePart } = {}
	local seen: { [Instance]: boolean } = {}
	for _, inst in CollectionService:GetTagged(Names.Tag.AlarmLamp) do
		if inst:IsA("BasePart") and not seen[inst] then
			seen[inst] = true
			table.insert(out, inst)
		end
	end
	-- StationBuilder's lamps: Models named "AlarmLight" with a Neon "Bulb"
	local map = workspace:FindFirstChild("Map")
	local station = map and map:FindFirstChild("Station")
	if station then
		for _, d in station:GetDescendants() do
			if d.Name == "Bulb" and d:IsA("BasePart") and d.Parent and d.Parent.Name == "AlarmLight" and not seen[d] then
				seen[d] = true
				table.insert(out, d)
			end
		end
	end
	return out
end

local function setLights(lamp: BasePart, on: boolean)
	for _, l in lamp:GetChildren() do
		if l:IsA("Light") and l.Name ~= "AlarmBeacon" then
			l.Enabled = on
		end
	end
end

local function beacon(lamp: BasePart)
	for _, yaw in { 0, math.pi } do
		local holder = Instance.new("Attachment")
		holder.Name = "AlarmBeaconArm"
		holder.CFrame = CFrame.Angles(0, yaw, 0)
		holder.Parent = lamp
		local s = Instance.new("SpotLight")
		s.Name = "AlarmBeacon"
		s.Color = RED
		s.Brightness = 6
		s.Range = 40
		s.Angle = 50
		s.Face = Enum.NormalId.Front
		s.Parent = holder
		holder:SetAttribute("Yaw", yaw)
	end
end

local function runAlarm()
	if running then
		return
	end
	running = true
	local list = lamps()
	local baseColor: { [BasePart]: Color3 } = {}
	for _, lamp in list do
		baseColor[lamp] = lamp.Color
		setLights(lamp, true)
		beacon(lamp)
	end
	local cc = Lighting:FindFirstChild("AlarmCC") :: ColorCorrectionEffect?
	if not cc then
		local made = Instance.new("ColorCorrectionEffect")
		made.Name = "AlarmCC"
		made.Parent = Lighting
		cc = made
	end
	local effect = cc :: ColorCorrectionEffect
	effect.Enabled = true
	local t = 0
	local conn = RunService.RenderStepped:Connect(function(dt: number)
		t += dt
		local angle = t * 2 * math.pi -- one turn per second
		for _, lamp in list do
			if not lamp.Parent then
				continue
			end
			for _, arm in lamp:GetChildren() do
				if arm:IsA("Attachment") and arm.Name == "AlarmBeaconArm" then
					local yaw = (arm:GetAttribute("Yaw") :: number?) or 0
					arm.CFrame = CFrame.Angles(0, yaw + angle, 0) * CFrame.Angles(math.rad(-10), 0, 0)
				end
			end
			local pulse = (math.sin(t * 4 * math.pi) + 1) / 2
			lamp.Color = (baseColor[lamp] or RED):Lerp(Color3.new(1, 1, 1), pulse * 0.4)
		end
		local pulse = (math.sin(t * 2 * math.pi) + 1) / 2
		effect.TintColor = Color3.new(1, 1, 1):Lerp(RED, pulse * 0.6)
	end)
	while os.clock() < runUntil do
		task.wait(0.1)
	end
	conn:Disconnect()
	for _, lamp in list do
		if lamp.Parent then
			setLights(lamp, false)
			lamp.Color = baseColor[lamp] or lamp.Color
			for _, c in lamp:GetChildren() do
				if c:IsA("Attachment") and c.Name == "AlarmBeaconArm" then
					c:Destroy()
				end
			end
		end
	end
	effect.TintColor = Color3.new(1, 1, 1)
	effect.Enabled = false
	running = false
end

function AlarmController:Run(seconds: number)
	runUntil = math.max(runUntil, os.clock() + seconds)
	task.spawn(runAlarm)
end

function AlarmController:Init(_controllers: { [string]: any }) end

function AlarmController:Start()
	task.spawn(function()
		local ok, Alarm = pcall(Net.event, "Mission", "Alarm")
		if ok then
			(Alarm :: RemoteEvent).OnClientEvent:Connect(function(_missionId: string, _title: string)
				AlarmController:Run(tonumber(GameConfig.AlarmSeconds) or 6)
			end)
		end
	end)
	task.spawn(function()
		local ok, Countdown = pcall(Net.event, "Lobby", "Countdown")
		if ok then
			(Countdown :: RemoteEvent).OnClientEvent:Connect(function(_padId: any, seconds: any, _title: any)
				local s = tonumber(seconds)
				local from = tonumber(LobbyConfig.AlarmFromSeconds) or 3
				if s and s > 0 and s <= from then
					AlarmController:Run(s + 0.5)
				end
			end)
		end
	end)
	task.spawn(function()
		local ok, Board = pcall(Net.event, "Lobby", "Board")
		if not ok then
			return
		end
		(Board :: RemoteEvent).OnClientEvent:Connect(function(squads: any)
			if type(squads) ~= "table" then
				return
			end
			for _, s in squads do
				if type(s) ~= "table" or type(s.id) ~= "string" then
					continue
				end
				local key = `{s.id}:{tostring(s.missionId)}`
				if s.state == "Launching" and not seenLaunch[key] then
					seenLaunch[key] = true
					-- the station lights go off as the countdown hits 3
					local countdown = tonumber(LobbyConfig.FullCountdownSeconds) or tonumber(LobbyConfig.LaunchCountdown) or 5
					task.delay(math.max(0, countdown - 3), function()
						AlarmController:Run(3.5)
					end)
				elseif s.state ~= "Launching" then
					seenLaunch[key] = nil
				end
			end
		end)
	end)
end

return AlarmController
