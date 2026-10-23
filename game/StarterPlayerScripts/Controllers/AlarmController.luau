--!strict
-- AlarmController [owner: Station v2]. Client-only station dispatch alarm (docs/game/08 "Station v2",
-- docs/game/02 §2 "Alarm" overlay, trailer t=3). Nothing here affects gameplay; all of it is local and
-- restored afterwards.
--
-- The sequence (stages from Lib/AlarmLogic):
--   tones : every beacon strobes red/white
--   wail  : the StationAlarm speakers wail (looped Sound "Siren"), beacons spin (the "Reflector" part
--           orbits the bulb carrying a SpotLight), bulbs glow, the watch-room DispatchScreen flashes
--           "DISPATCH! <title>", the dispatched bays' indicator lamps and door stripes blink red
--   go    : the dispatched bays turn GREEN: LampGreen lights with a blinking "GO", DoorStripes go green
-- Levels: FULL for the squad that was dispatched (full siren volume + a red screen pulse "AlarmCC"),
-- QUIET for everyone else in the station (lights and GO lamps the same, siren at
-- AlarmLogic.QuietVolume, no screen tint).
--
-- Triggers:
--   * Mission/Alarm  (S->C squad: missionId, title)      -> FULL, my squad's bays, DispatchSeconds
--   * Lobby/Countdown (S->C squad: padId, seconds, title) -> FULL from LobbyConfig.AlarmFromSeconds (3)
--     down to 0 (0 = dispatched: DispatchSeconds)
--   * Lobby/Fx "alarm" | "dispatch" (title, bays?, seconds?) -> FULL (for a v2 dispatcher)
--   * Lobby/Board (S->C all) -> a squad I'm not in turns "Launching": QUIET with that squad's bays as
--     its countdown hits 3
--   * Workspace.Runs.<runId> RoundState -> "Dispatched": FULL if my InstanceId is that run, else QUIET
-- Bays = the Helmet attribute (1..4) of the squad's players (bay = helmet number, docs/game/08).
-- Siren SoundId: the speaker's "SoundId" attribute, else AudioConfig.Sounds.Siren.id ("" = silent).
-- Public: AlarmController:Run(seconds: number, level: number?, bays: {number}?, title: string?)
--         AlarmController.DispatchSeconds (tunable, default max(GameConfig.AlarmSeconds, 10))
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local GameConfig = require(ConfigFolder:WaitForChild("GameConfig") :: ModuleScript) :: any
local LobbyConfig = require(ConfigFolder:WaitForChild("LobbyConfig") :: ModuleScript) :: any
local AlarmLogic = require(script.Parent.Parent:WaitForChild("Lib"):WaitForChild("AlarmLogic") :: ModuleScript)

local TAG_STATION_ALARM = (Names.Tag :: any).StationAlarm or "StationAlarm"
local ATTR_BAY = (Names.Attr :: any).Bay or "Bay"

local AlarmController = {}
AlarmController.Priority = 60
AlarmController.DispatchSeconds = math.max(tonumber(GameConfig.AlarmSeconds) or 6, 10)
AlarmController.SirenVolume = 0.8

local player = Players.LocalPlayer
local RED = Color3.fromRGB(255, 70, 60)
local WHITE = Color3.new(1, 1, 1)
local GREEN = Color3.fromRGB(80, 255, 110)
local DARK_RED = Color3.fromRGB(90, 16, 16)
local DARK_GREEN = Color3.fromRGB(31, 74, 34)
local SCREEN_RED = Color3.fromRGB(150, 20, 20)

local state = AlarmLogic.new()
local runConn: RBXScriptConnection? = nil
local seenLaunch: { [string]: boolean } = {}

local function count(name: string)
	pcall(function()
		(require(ReplicatedStorage:FindFirstChild("ForgeTelemetry") :: ModuleScript) :: any).count(name, 1)
	end)
end

local function sirenSoundId(speaker: BasePart): string
	local own = speaker:GetAttribute("SoundId")
	if type(own) == "string" and own ~= "" then
		return own
	end
	local ok, id = pcall(function()
		local AudioConfig = require(ConfigFolder:FindFirstChild("AudioConfig") :: ModuleScript) :: any
		return AudioConfig.Sounds.Siren.id
	end)
	return if ok and type(id) == "string" then id else ""
end

------------------------------------------------------------------ the station's alarm parts

type Rig = {
	bulbs: { BasePart },
	bulbColor: { [BasePart]: Color3 },
	reflectors: { { part: BasePart, center: Vector3, base: CFrame, light: SpotLight } },
	speakers: { { part: BasePart, sound: Sound } },
	reds: { { part: BasePart, bay: number, color: Color3 } },
	greens: { { part: BasePart, bay: number, color: Color3, mat: Enum.Material, text: TextLabel? } },
	stripes: { { part: BasePart, bay: number, color: Color3 } },
	screens: { { label: TextLabel, text: string, bg: Color3, fg: Color3 } },
	cc: ColorCorrectionEffect?,
}

local function stationRoot(): Instance?
	local map = workspace:FindFirstChild("Map")
	local st = map and map:FindFirstChild("Station")
	if st then
		return st
	end
	for _, sp in CollectionService:GetTagged(TAG_STATION_ALARM) do
		local m = sp:FindFirstAncestor("Station")
		if m then
			return m
		end
	end
	return nil
end

local function collect(): Rig
	local rig: Rig = {
		bulbs = {},
		bulbColor = {},
		reflectors = {},
		speakers = {},
		reds = {},
		greens = {},
		stripes = {},
		screens = {},
		cc = nil,
	}
	local seen: { [Instance]: boolean } = {}
	local function addBulb(p: BasePart)
		if not seen[p] then
			seen[p] = true
			table.insert(rig.bulbs, p)
			rig.bulbColor[p] = p.Color
		end
	end
	for _, inst in CollectionService:GetTagged(Names.Tag.AlarmLamp) do
		if inst:IsA("BasePart") then
			addBulb(inst)
		end
	end
	local root = stationRoot()
	if root then
		for _, d in root:GetDescendants() do
			if not d:IsA("BasePart") then
				continue
			end
			local bay = tonumber(d:GetAttribute(ATTR_BAY)) or 0
			local parentName = d.Parent and d.Parent.Name or ""
			if d.Name == "Bulb" and parentName == "AlarmLight" then
				addBulb(d)
			elseif d.Name == "Reflector" and parentName == "AlarmLight" then
				local bulb = (d.Parent :: Instance):FindFirstChild("Bulb")
				if bulb and bulb:IsA("BasePart") then
					local s = Instance.new("SpotLight")
					s.Name = "AlarmBeacon"
					s.Color = RED
					s.Brightness = 0
					s.Range = 40
					s.Angle = 55
					s.Face = Enum.NormalId.Right
					s.Shadows = false
					s.Parent = d
					table.insert(rig.reflectors, { part = d, center = bulb.Position, base = d.CFrame, light = s })
				end
			elseif d.Name == "LampRed" then
				table.insert(rig.reds, { part = d, bay = bay, color = d.Color })
			elseif d.Name == "LampGreen" then
				local t = d:FindFirstChild("Text", true)
				table.insert(rig.greens, {
					part = d,
					bay = bay,
					color = d.Color,
					mat = d.Material,
					text = if t and t:IsA("TextLabel") then t else nil,
				})
			elseif d.Name == "DoorStripe" then
				table.insert(rig.stripes, { part = d, bay = bay, color = d.Color })
			elseif d.Name == "DispatchScreen" then
				local gui = d:FindFirstChild("DispatchGui")
				local t = gui and gui:FindFirstChild("Text")
				if t and t:IsA("TextLabel") then
					table.insert(rig.screens, { label = t, text = t.Text, bg = t.BackgroundColor3, fg = t.TextColor3 })
				end
			end
		end
	end
	for _, sp in CollectionService:GetTagged(TAG_STATION_ALARM) do
		if sp:IsA("BasePart") then
			local snd = sp:FindFirstChildOfClass("Sound")
			if not snd then
				local made = Instance.new("Sound")
				made.Name = "Siren"
				made.Looped = true
				made.RollOffMaxDistance = 220
				made.Parent = sp
				snd = made
			end
			local s = snd :: Sound
			local id = sirenSoundId(sp)
			if id ~= "" then
				s.SoundId = id
				s.Looped = true
				s.Volume = 0
				s.PlaybackSpeed = 1
				s:Play()
			end
			table.insert(rig.speakers, { part = sp, sound = s })
		end
	end
	return rig
end

local function setGlow(bulb: BasePart, on: boolean)
	for _, l in bulb:GetChildren() do
		if l:IsA("Light") then
			l.Enabled = on
		end
	end
end

local function restore(rig: Rig)
	for _, b in rig.bulbs do
		if b.Parent then
			setGlow(b, false)
			b.Color = rig.bulbColor[b] or b.Color
		end
	end
	for _, r in rig.reflectors do
		r.light:Destroy()
		if r.part.Parent then
			r.part.CFrame = r.base
		end
	end
	for _, sp in rig.speakers do
		sp.sound:Stop()
		sp.sound.Volume = 0
		sp.sound.PlaybackSpeed = 1
	end
	for _, r in rig.reds do
		r.part.Color = r.color
	end
	for _, g in rig.greens do
		g.part.Color = g.color
		g.part.Material = g.mat
		if g.text then
			g.text.TextTransparency = 1
			g.text.TextStrokeTransparency = 1
		end
	end
	for _, s in rig.stripes do
		s.part.Color = s.color
	end
	for _, sc in rig.screens do
		sc.label.Text = sc.text
		sc.label.BackgroundColor3 = sc.bg
		sc.label.TextColor3 = sc.fg
	end
	if rig.cc then
		rig.cc.TintColor = WHITE
		rig.cc.Enabled = false
	end
end

------------------------------------------------------------------ the sequence

local function step(rig: Rig)
	local now = os.clock()
	if AlarmLogic.expire(state, now) then
		if runConn then
			runConn:Disconnect()
			runConn = nil
		end
		restore(rig)
		return
	end
	local stage = AlarmLogic.stage(state, now)
	local t = now - state.startedAt
	local full = state.level >= AlarmLogic.FULL

	-- beacons
	local strobeOn = AlarmLogic.strobe(t)
	local pulse = (math.sin(t * 4 * math.pi) + 1) / 2
	for _, b in rig.bulbs do
		if not b.Parent then
			continue
		end
		if stage == "tones" then
			b.Color = if strobeOn then WHITE else RED
			setGlow(b, strobeOn)
		else
			b.Color = (rig.bulbColor[b] or RED):Lerp(WHITE, pulse * 0.35)
			setGlow(b, true)
		end
	end
	local angle = AlarmLogic.beaconAngle(t)
	for _, r in rig.reflectors do
		if r.part.Parent then
			r.part.CFrame = CFrame.new(r.center) * CFrame.Angles(0, angle, 0) * CFrame.new(0.55, 0, 0)
		end
		r.light.Brightness = if stage == "tones" then 0 else 7
	end

	-- siren
	local vol = if stage == "tones" then 0 else AlarmLogic.volume(state.level, AlarmController.SirenVolume)
	for _, sp in rig.speakers do
		sp.sound.Volume = vol
		if sp.part:GetAttribute("Wail") == true then
			sp.sound.PlaybackSpeed = AlarmLogic.wail(t)
		end
	end

	-- bay doors
	local go = stage == "go"
	local blink = AlarmLogic.goBlink(t)
	for _, r in rig.reds do
		if state.bays[r.bay] then
			r.part.Color = if (not go and strobeOn) then RED else DARK_RED
		end
	end
	for _, g in rig.greens do
		if state.bays[g.bay] then
			g.part.Material = if go then Enum.Material.Neon else g.mat
			g.part.Color = if go then GREEN else DARK_GREEN
			if g.text then
				local tt = if go and blink then 0 else 1
				g.text.TextTransparency = tt
				g.text.TextStrokeTransparency = tt
			end
		end
	end
	for _, s in rig.stripes do
		if state.bays[s.bay] then
			s.part.Color = if go then GREEN:Lerp(WHITE, pulse * 0.25) else (if strobeOn then RED else DARK_RED)
		end
	end

	-- watch-room screen
	for _, sc in rig.screens do
		sc.label.Text = if state.title ~= "" then `DISPATCH!\n{state.title}` else "DISPATCH!\nALL HANDS"
		sc.label.BackgroundColor3 = if strobeOn then SCREEN_RED else Color3.fromRGB(40, 8, 8)
		sc.label.TextColor3 = WHITE
	end

	-- screen tint for the dispatched squad only
	if full then
		if not rig.cc then
			local cc = Lighting:FindFirstChild("AlarmCC")
			if not (cc and cc:IsA("ColorCorrectionEffect")) then
				local made = Instance.new("ColorCorrectionEffect")
				made.Name = "AlarmCC"
				made.Parent = Lighting
				cc = made
			end
			rig.cc = cc :: ColorCorrectionEffect
		end
		local cc = rig.cc :: ColorCorrectionEffect
		cc.Enabled = true
		local p1 = (math.sin(t * 2 * math.pi) + 1) / 2
		cc.TintColor = WHITE:Lerp(RED, p1 * 0.5)
	elseif rig.cc then
		rig.cc.TintColor = WHITE
	end
end

function AlarmController:Run(seconds: number, level: number?, bays: { number }?, title: string?)
	local fresh = AlarmLogic.trigger(state, os.clock(), level or AlarmLogic.FULL, seconds, bays, title)
	if fresh then
		count(if state.level >= AlarmLogic.FULL then "station_alarm_full" else "station_alarm_quiet")
	end
	if runConn then
		return
	end
	local rig = collect()
	runConn = RunService.RenderStepped:Connect(function()
		local ok, err = pcall(step, rig)
		if not ok then
			warn(`[AlarmController] {err}`)
			if runConn then
				runConn:Disconnect()
				runConn = nil
			end
			pcall(restore, rig)
			state = AlarmLogic.new()
		end
	end)
end

------------------------------------------------------------------ who gets which bays

local function helmetOf(p: Player): number?
	return tonumber(p:GetAttribute(Names.Attr.Helmet))
end

-- Bays of everyone in my squad / run (and mine).
local function mySquadBays(): { number }
	local out: { number } = {}
	local mine = helmetOf(player)
	if mine then
		table.insert(out, mine)
	end
	local sq = player:GetAttribute(Names.Attr.SquadId)
	local inst = player:GetAttribute(Names.Attr.InstanceId)
	for _, p in Players:GetPlayers() do
		if p == player then
			continue
		end
		local same = (type(sq) == "string" and sq ~= "" and p:GetAttribute(Names.Attr.SquadId) == sq)
			or (type(inst) == "string" and inst ~= "" and p:GetAttribute(Names.Attr.InstanceId) == inst)
		local h = helmetOf(p)
		if same and h then
			table.insert(out, h)
		end
	end
	return out
end

local function baysOfUserIds(uids: { any }): { number }
	local out: { number } = {}
	for _, uid in uids do
		local p = Players:GetPlayerByUserId(tonumber(uid) or 0)
		local h = p and helmetOf(p)
		if h then
			table.insert(out, h)
		end
	end
	return out
end

local function baysOfRun(runId: string): { number }
	local out: { number } = {}
	for _, p in Players:GetPlayers() do
		local h = helmetOf(p)
		if h and p:GetAttribute(Names.Attr.InstanceId) == runId then
			table.insert(out, h)
		end
	end
	return out
end

------------------------------------------------------------------ lifecycle

local function watchRuns()
	local function hook(run: Instance)
		local function check()
			if run:GetAttribute(Names.Attr.RoundState) ~= "Dispatched" then
				return
			end
			local mine = player:GetAttribute(Names.Attr.InstanceId) == run.Name
			local title = run:GetAttribute("Address") or run:GetAttribute("Title") or run:GetAttribute(Names.Attr.MissionId)
			AlarmController:Run(
				AlarmController.DispatchSeconds,
				if mine then AlarmLogic.FULL else AlarmLogic.QUIET,
				baysOfRun(run.Name),
				if type(title) == "string" then title else nil
			)
		end
		run:GetAttributeChangedSignal(Names.Attr.RoundState):Connect(check)
		check()
	end
	local function hookFolder(runs: Instance)
		for _, r in runs:GetChildren() do
			hook(r)
		end
		runs.ChildAdded:Connect(hook)
	end
	local runs = workspace:FindFirstChild("Runs")
	if runs then
		hookFolder(runs)
		return
	end
	local conn: RBXScriptConnection? = nil
	conn = workspace.ChildAdded:Connect(function(child: Instance)
		if child.Name == "Runs" and conn then
			conn:Disconnect()
			conn = nil
			hookFolder(child)
		end
	end)
end

function AlarmController:Init(_controllers: { [string]: any }) end

function AlarmController:Start()
	task.spawn(function()
		local ok, Alarm = pcall(Net.event, "Mission", "Alarm")
		if ok then
			(Alarm :: RemoteEvent).OnClientEvent:Connect(function(_missionId: any, title: any)
				AlarmController:Run(AlarmController.DispatchSeconds, AlarmLogic.FULL, mySquadBays(), if type(title) == "string" then title else nil)
			end)
		end
	end)
	task.spawn(function()
		local ok, Countdown = pcall(Net.event, "Lobby", "Countdown")
		if ok then
			(Countdown :: RemoteEvent).OnClientEvent:Connect(function(_padId: any, seconds: any, title: any)
				local s = tonumber(seconds)
				local from = tonumber(LobbyConfig.AlarmFromSeconds) or 3
				if s and s >= 0 and s <= from then
					local dur = if s <= 0 then AlarmController.DispatchSeconds else s + 0.5
					AlarmController:Run(dur, AlarmLogic.FULL, mySquadBays(), if type(title) == "string" then title else nil)
				end
			end)
		end
	end)
	task.spawn(function()
		local ok, Fx = pcall(Net.event, "Lobby", "Fx")
		if ok then
			(Fx :: RemoteEvent).OnClientEvent:Connect(function(kind: any, a: any, b: any, c: any)
				if kind == "alarm" or kind == "dispatch" then
					local bays = if type(b) == "table" then AlarmLogic.cleanBays(b) else mySquadBays()
					AlarmController:Run(tonumber(c) or AlarmController.DispatchSeconds, AlarmLogic.FULL, bays, if type(a) == "string" then a else nil)
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
				local members = if type(s.members) == "table" then s.members else {}
				local mine = table.find(members, player.UserId) ~= nil
				if s.state == "Launching" and not seenLaunch[key] then
					seenLaunch[key] = true
					if mine then
						continue -- my own countdown drives the FULL alarm
					end
					local countdown = tonumber(LobbyConfig.FullCountdownSeconds) or tonumber(LobbyConfig.LaunchCountdown) or 5
					local bays = baysOfUserIds(members)
					task.delay(math.max(0, countdown - 3), function()
						AlarmController:Run(3 + AlarmController.DispatchSeconds * 0.6, AlarmLogic.QUIET, bays, nil)
					end)
				elseif s.state ~= "Launching" then
					seenLaunch[key] = nil
				end
			end
		end)
	end)
	task.spawn(watchRuns)
end

return AlarmController
