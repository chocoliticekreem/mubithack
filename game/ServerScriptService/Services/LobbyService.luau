--!strict
-- LobbyService [owner: G3]. The fire station is the LOBBY. Players spawn on the StationSpawn pads.
-- A big Mission Board (tag MissionBoard: SurfaceGui + ProximityPrompt + ClickDetector) lists
-- MissionCatalog; 3 glowing queue pads (tag SquadPad, attr PadId) on the apron each show their
-- squad's call + "2/4 READY". Stepping on a pad joins its squad; the first player on a pad starts a
-- countdown (LobbyConfig.CountdownSeconds, cut to FullCountdownSeconds when the squad is full, reset
-- when the pad empties). At 3..2..1 the station alarm lamps flash; at 0 the alarm blares and the
-- squad launches into its OWN mission instance (MissionService:StartMission), so several pads count
-- down and launch in parallel. On MissionService.MissionEnded the squad comes home ("Welcome back,
-- heroes (mostly)"). Idle fun: slide the fire pole, ring the bell, honk truck 67; standing still
-- labels you "on coffee break". Queue/countdown rules live in the pure ReplicatedStorage/Lobby/LobbyQueue.
-- LobbyConfig.UseLobby = false keeps v1's single auto-round (remotes are still declared).
--
-- Public API (contract, docs/game/03-tech-architecture.md §10 "v1.5 additions"):
--   LobbyService:GetSquads(): { Types.Squad }
--   LobbyService:GetSquad(squadId: string): Types.Squad?
--   LobbyService:Join(player: Player, padId: number): string?     -- squadId; first on a pad leads
--   LobbyService:Leave(player: Player)
--   LobbyService:Choose(player: Player, missionId: string): boolean -- leader only, enabled missions only
--   LobbyService:Launch(squadId: string, missionId: string): string? -- instanceId (MissionService:StartMission)
--   LobbyService:ReturnToLobby(players: { Player })               -- back onto station pads, InstanceId = ""
-- Signals: SquadChanged(squadId: string), Launched(squadId: string, missionId: string, instanceId: string)
-- Remotes: Lobby/Board (S->C all: squads: { Types.Squad }), Lobby/Choose (C->S missionId: string, 2/s),
--          Lobby/Launch (C->S none, 1/s; leader only: cuts the countdown to LaunchCountdown)
--          added: Lobby/Countdown (S->C squad: padId: number, seconds: number (-1 = cancel), title: string)
--                 Lobby/Fx (S->C one: kind: "slide" | "welcome" | "toast", ...args)
-- Writes: Player attrs SquadId ("" = none), InstanceId ("" = in the lobby); Workspace.Map.Station.Lobby;
--         counters squads_launched, lobby_joins, lobby_returns, lobby_bell, lobby_honk, lobby_pole, lobby_afk
-- Test hooks (DevHook only): _join(player, padId), _launch(squadId, missionId), _selftest()
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Types = require(Shared:WaitForChild("Types") :: ModuleScript)
local ConfigDir = ReplicatedStorage:WaitForChild("Config")
local LobbyConfig = require(ConfigDir:WaitForChild("LobbyConfig") :: ModuleScript) :: any
local MapConfig = require(ConfigDir:WaitForChild("MapConfig") :: ModuleScript) :: any
local MissionCatalog = require(ConfigDir:WaitForChild("MissionCatalog") :: ModuleScript) :: { any }
local LobbyQueue = require(ReplicatedStorage:WaitForChild("Lobby"):WaitForChild("LobbyQueue") :: ModuleScript)

local LobbyService = {}
LobbyService.Priority = 55
LobbyService.SquadChanged = Signal.new() :: Signal.Signal<string>
LobbyService.Launched = Signal.new() :: Signal.Signal<string, string, string>

type ActiveSquad = Types.Squad & { fallback: boolean? }

local services: { [string]: any } = {}
local byId: { [string]: any } = {}
local queue: LobbyQueue.State? = nil
local built: any = nil -- LobbyProps.Built
local stationModel: Model? = nil
local active: { [string]: ActiveSquad } = {} -- launched squads (InMission), by squadId
local remotes: { [string]: RemoteEvent } = {}
local afk: { [Player]: { pos: Vector3, t: number, tagged: boolean } } = {}
local cooldown: { [string]: number } = {}
local fallbackSeq = 0
local launching: { [number]: boolean } = {} -- userIds between countdown 0 and InstanceId being set

local function count(name: string, n: number?)
	pcall(function()
		require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript).count(name, n or 1)
	end)
end

local function catalogIndex()
	table.clear(byId)
	for _, m in MissionCatalog do
		byId[m.id] = m
	end
end

local function firstEnabled(): string?
	for _, m in MissionCatalog do
		if m.enabled then
			return m.id
		end
	end
	return nil
end

local function title(missionId: string?): string
	local def = missionId and byId[missionId]
	return if def then def.title else "No call"
end

local function playerById(uid: number): Player?
	return Players:GetPlayerByUserId(uid)
end

local function rootOf(player: Player): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function inLobby(player: Player): boolean
	local id = player:GetAttribute(Names.Attr.InstanceId)
	return id == nil or id == ""
end

local function ready(key: string, seconds: number): boolean
	local now = os.clock()
	if (cooldown[key] or 0) > now then
		return false
	end
	cooldown[key] = now + seconds
	return true
end

local function playSound(parent: Instance, soundId: string, volume: number?)
	if soundId == nil or soundId == "" then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = soundId
	s.Volume = volume or 1
	s.RollOffMaxDistance = 160
	s.Parent = parent
	s:Play()
	Debris:AddItem(s, 8)
end

-- "HONK!" / "DING!" pop-up over a part, visible to everyone nearby.
local function popText(adornee: BasePart, str: string, _color: Color3, _height: number)
	Popup.show(adornee, str, "blame") -- small world text for players nearby (ClientLib/WorldPopup)
end

------------------------------------------------------------------ squads as Types.Squad

local function padSquad(pad: LobbyQueue.Pad): Types.Squad?
	if not pad.squadId or #pad.members == 0 then
		return nil
	end
	local secs = pad.remaining and math.ceil(pad.remaining) or nil
	return {
		id = pad.squadId,
		padId = pad.padId,
		leader = pad.leader or pad.members[1],
		members = table.clone(pad.members),
		missionId = pad.missionId,
		instanceId = nil,
		state = if secs and secs <= LobbyConfig.FullCountdownSeconds then "Launching" else "Forming",
	}
end

function LobbyService:GetSquads(): { Types.Squad }
	local out: { Types.Squad } = {}
	if queue then
		for _, pad in queue.pads do
			local s = padSquad(pad)
			if s then
				table.insert(out, s)
			end
		end
	end
	for _, s in active do
		table.insert(out, {
			id = s.id,
			padId = s.padId,
			leader = s.leader,
			members = table.clone(s.members),
			missionId = s.missionId,
			instanceId = s.instanceId,
			state = s.state,
		})
	end
	return out
end

function LobbyService:GetSquad(squadId: string): Types.Squad?
	for _, s in LobbyService:GetSquads() do
		if s.id == squadId then
			return s
		end
	end
	return nil
end

------------------------------------------------------------------ rendering

local function boardRows(): { any }
	local picked: { [string]: { number } } = {}
	if queue then
		for _, pad in queue.pads do
			if pad.missionId and #pad.members > 0 then
				picked[pad.missionId] = picked[pad.missionId] or {}
				table.insert(picked[pad.missionId], pad.padId)
			end
		end
	end
	local rows = {}
	for _, m in MissionCatalog do
		local pads = picked[m.id]
		table.insert(rows, {
			id = m.id,
			title = m.title,
			blurb = m.blurb,
			players = LobbyQueue.playersText(m),
			difficulty = LobbyQueue.difficulty(m),
			enabled = m.enabled == true,
			pads = if pads then "PAD " .. table.concat(pads, ", ") else "",
		})
	end
	return rows
end

local function renderBoard()
	if not built then
		return
	end
	local LobbyProps = require(ServerScriptService.Lib.Lobby.LobbyProps :: ModuleScript) :: any
	LobbyProps.renderBoard(built.boardGui, boardRows())
end

local function renderPad(padId: number)
	local q = queue
	if not built or not q then
		return
	end
	local rec = built.pads[padId]
	local pad = q.pads[padId]
	if not rec or not pad then
		return
	end
	local LobbyProps = require(ServerScriptService.Lib.Lobby.LobbyProps :: ModuleScript) :: any
	local C = LobbyProps.Colors
	local cap = LobbyQueue.capacity(q, padId)
	local secs = LobbyQueue.secondsLeft(q, padId)
	local names = {}
	for _, uid in pad.members do
		local p = playerById(uid)
		table.insert(names, if p then p.DisplayName else "?")
	end
	local hot = secs ~= nil and secs <= LobbyConfig.AlarmFromSeconds
	LobbyProps.renderPad(rec, {
		mission = title(pad.missionId),
		ready = LobbyQueue.readyText(#pad.members, cap),
		count = if secs then `ROLLING IN {secs}` elseif #pad.members == 0 then "STEP ON TO JOIN" else "",
		names = table.concat(names, "  "),
		color = if hot then C.PadHot elseif #pad.members > 0 then C.PadForming else C.PadIdle,
		hot = hot,
	})
end

local function broadcast()
	local r = remotes.Board
	if r then
		r:FireAllClients(LobbyService:GetSquads())
	end
end

local function syncSquadAttrs()
	local q = queue
	if not q then
		return
	end
	for _, p in Players:GetPlayers() do
		if inLobby(p) then
			local padId = LobbyQueue.padOf(q, p.UserId)
			local sid = if padId then q.pads[padId].squadId or "" else ""
			if p:GetAttribute(Names.Attr.SquadId) ~= sid then
				p:SetAttribute(Names.Attr.SquadId, sid)
			end
		end
	end
end

local function padChanged(padId: number, squadId: string?)
	renderPad(padId)
	if squadId then
		LobbyService.SquadChanged:Fire(squadId)
	end
end

local function toMembers(uids: { number }, ...: any)
	local r = remotes.Countdown
	if not r then
		return
	end
	for _, uid in uids do
		local p = playerById(uid)
		if p then
			r:FireClient(p, ...)
		end
	end
end

------------------------------------------------------------------ station alarm

local function alarmParts(): { BasePart }
	local out: { BasePart } = {}
	local station = stationModel
	if not station then
		return out
	end
	for _, d in station:GetDescendants() do
		if d:IsA("BasePart") and (d:HasTag(Names.Tag.AlarmLamp) or (d.Name == "Bulb" and d.Parent and d.Parent.Name == "AlarmLight")) then
			table.insert(out, d)
		end
	end
	return out
end

local function flashAlarm(seconds: number)
	for _, bulb in alarmParts() do
		local light = bulb:FindFirstChildWhichIsA("Light")
		if light then
			light.Enabled = true
			task.delay(seconds, function()
				if light.Parent then
					light.Enabled = false
				end
			end)
		end
	end
	if built and built.siren and LobbyConfig.SirenSoundId ~= "" then
		built.siren.SoundId = LobbyConfig.SirenSoundId
		built.siren:Play()
	end
end

------------------------------------------------------------------ teleport helpers

local function stationSpawn(i: number): CFrame
	local Map = services.MapService
	local slot = ((i - 1) % 4) + 1
	local ok, cf = pcall(function()
		return Map and Map:GetSpawnCFrame(slot)
	end)
	if ok and typeof(cf) == "CFrame" then
		return cf
	end
	return MapConfig.SlotOrigin(0) * CFrame.new(-31 + (slot - 1) * 5, 4, 8)
end

local function pivot(player: Player, cf: CFrame)
	local char = player.Character
	if char then
		char:PivotTo(cf)
	end
end

local function missionSpawn(model: Model): CFrame
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and (d.Name == "PlayerSpawn" or d:HasTag("PlayerSpawn")) then
			return d.CFrame * CFrame.new(0, 4, 0)
		end
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:HasTag(Names.Tag.TruckSpot) then
			return d.CFrame * CFrame.new(8, 4, 0)
		end
	end
	return model:GetPivot() * CFrame.new(0, 6, 0)
end

------------------------------------------------------------------ public API

function LobbyService:Join(player: Player, padId: number): string?
	local q = queue
	if not q or not inLobby(player) then
		return nil
	end
	local before = LobbyQueue.padOf(q, player.UserId)
	local ok = LobbyQueue.join(q, padId, player.UserId)
	if not ok then
		return if before == padId then q.pads[padId].squadId else nil
	end
	-- Put them physically on the pad so the position poll agrees (DevHook / scripted joins).
	if built and built.pads[padId] then
		local rec = built.pads[padId]
		local onIt = false
		local root = rootOf(player)
		if root then
			local d = root.Position - rec.part.Position
			onIt = Vector3.new(d.X, 0, d.Z).Magnitude <= LobbyConfig.PadRadius
		end
		if not onIt then
			pivot(player, CFrame.new(rec.part.Position + Vector3.new(0, 3.5, 0)))
		end
	end
	count("lobby_joins")
	syncSquadAttrs()
	if before then
		padChanged(before, q.pads[before].squadId)
	end
	padChanged(padId, q.pads[padId].squadId)
	renderBoard()
	broadcast()
	return q.pads[padId].squadId
end

function LobbyService:Leave(player: Player)
	local q = queue
	if not q then
		return
	end
	local padId = LobbyQueue.padOf(q, player.UserId)
	if not padId then
		return
	end
	local sid = q.pads[padId].squadId
	LobbyQueue.leave(q, player.UserId)
	player:SetAttribute(Names.Attr.SquadId, "")
	-- Step them off the pad so the next poll doesn't put them straight back.
	if built and built.pads[padId] then
		pivot(player, CFrame.new(built.pads[padId].part.Position + Vector3.new(0, 3.5, -7)))
	end
	toMembers({ player.UserId }, padId, -1, "")
	padChanged(padId, sid)
	renderBoard()
	broadcast()
end

function LobbyService:Choose(player: Player, missionId: string): boolean
	local q = queue
	local def = byId[missionId]
	if not q or not def or def.enabled ~= true then
		return false
	end
	local ok = LobbyQueue.choose(q, player.UserId, missionId)
	local padId = LobbyQueue.padOf(q, player.UserId)
	if ok then
		if padId then
			padChanged(padId, q.pads[padId].squadId)
			Net.notify(player, `Squad call: {def.title}`, "good")
		else
			Net.notify(player, `{def.title} it is. Step on a pad to roll out.`, "info")
		end
		renderBoard()
		broadcast()
	else
		Net.notify(player, "Only the squad leader picks the call.", "bad")
	end
	return ok
end

local function enabledIds(): { string }
	local out = {}
	for _, m in MissionCatalog do
		if m.enabled then
			table.insert(out, m.id)
		end
	end
	return out
end

local function endFallback(squadId: string)
	local s = active[squadId]
	if not s then
		return
	end
	local list: { Player } = {}
	for _, uid in s.members do
		local p = playerById(uid)
		if p then
			table.insert(list, p)
		end
	end
	LobbyService:ReturnToLobby(list)
	active[squadId] = nil
	local Map = services.MapService
	if Map and s.instanceId then
		pcall(Map.DestroyInstance, Map, s.instanceId)
	end
	broadcast()
end

function LobbyService:Launch(squadId: string, missionId: string): string?
	local q = queue
	if not q then
		return nil
	end
	local def = byId[missionId]
	if not def or def.enabled ~= true then
		warn(`[LobbyService] Launch {squadId}: mission {missionId} is not enabled`)
		return nil
	end
	-- Pull the squad off its pad (manual launch) or take it from a just-finished countdown.
	local squad: ActiveSquad? = active[squadId]
	if squad and squad.state == "InMission" then
		return squad.instanceId
	end
	if not squad then
		local pad = LobbyQueue.padBySquad(q, squadId)
		if not pad then
			return nil
		end
		squad = {
			id = squadId,
			padId = pad.padId,
			leader = pad.leader or pad.members[1],
			members = table.clone(pad.members),
			missionId = missionId,
			instanceId = nil,
			state = "Launching",
		}
		for _, uid in squad.members do
			LobbyQueue.leave(q, uid)
			launching[uid] = true
		end
		padChanged(pad.padId, nil)
	end
	local s = squad :: ActiveSquad
	s.missionId = missionId
	local function done()
		for _, uid in s.members do
			launching[uid] = nil
		end
	end
	local players: { Player } = {}
	for _, uid in s.members do
		local p = playerById(uid)
		if p and inLobby(p) then
			table.insert(players, p)
		end
	end
	if #players == 0 then
		active[squadId] = nil
		done()
		return nil
	end
	-- 0: the alarm blares; clients flash GO and fade.
	toMembers(s.members, s.padId, 0, def.title)
	flashAlarm(1.5)
	if built then
		playSound(built.board, LobbyConfig.AlarmSoundId, 1)
	end

	local instanceId: string? = nil
	local Mission = services.MissionService
	if Mission and type(Mission.StartMission) == "function" then
		local ok, res = pcall(Mission.StartMission, Mission, players, missionId)
		if ok and type(res) == "string" and res ~= "" then
			instanceId = res
		elseif not ok then
			warn(`[LobbyService] MissionService:StartMission failed: {res}`)
		end
	end
	if not instanceId then
		-- MissionService isn't real yet (stub returns nil): build the instance and teleport ourselves.
		local Map = services.MapService
		fallbackSeq += 1
		local id = `L{fallbackSeq}-{def.id}`
		local ok, model = pcall(function()
			return Map and Map:BuildInstance(def.locationId, id)
		end)
		if not ok or typeof(model) ~= "Instance" then
			warn(`[LobbyService] fallback BuildInstance({def.locationId}) failed: {model}`)
			for _, p in players do
				Net.notify(p, "Dispatch is jammed. No free trucks, try again in a sec.", "bad")
				toMembers({ p.UserId }, s.padId, -1, "")
			end
			active[squadId] = nil
			done()
			syncSquadAttrs()
			broadcast()
			return nil
		end
		instanceId = id
		s.fallback = true
		local spawnCf = missionSpawn(model :: Model)
		for i, p in players do
			local angle = (i - 1) * math.pi / 2
			pivot(p, spawnCf * CFrame.new(math.cos(angle) * 3, 0, math.sin(angle) * 3))
		end
		task.delay(def.seconds or 180, function()
			if active[squadId] and active[squadId].instanceId == id then
				endFallback(squadId)
			end
		end)
	end
	local iid = instanceId :: string
	s.instanceId = iid
	s.state = "InMission"
	active[squadId] = s
	for _, p in players do
		p:SetAttribute(Names.Attr.SquadId, squadId)
		p:SetAttribute(Names.Attr.InstanceId, iid)
		local a = afk[p]
		if a and a.tagged then
			a.tagged = false
			local head = p.Character and p.Character:FindFirstChild("Head")
			local tag = head and head:FindFirstChild("CoffeeBreak")
			if tag then
				tag:Destroy()
			end
		end
	end
	done()
	count("squads_launched")
	LobbyService.Launched:Fire(squadId, missionId, iid)
	LobbyService.SquadChanged:Fire(squadId)
	renderBoard()
	broadcast()
	print(`[LobbyService] squad {squadId} ({#players}p) launched {missionId} -> {iid}{if s.fallback then " (fallback)" else ""}`)
	return iid
end

function LobbyService:ReturnToLobby(players: { Player })
	for i, p in players do
		if p.Parent ~= Players then
			continue
		end
		p:SetAttribute(Names.Attr.InstanceId, "")
		p:SetAttribute(Names.Attr.SquadId, "")
		pivot(p, stationSpawn(i) * CFrame.new(math.random(-10, 10) / 10, 0, math.random(-10, 10) / 10))
		local r = remotes.Fx
		if r then
			r:FireClient(p, "welcome", LobbyConfig.WelcomeText)
		end
		count("lobby_returns") -- (the "welcome" Lobby/Fx says it; no duplicate screen toast)
		for sid, s in active do
			local idx = table.find(s.members, p.UserId)
			if idx then
				table.remove(s.members, idx)
				if #s.members == 0 then
					active[sid] = nil
					if s.fallback and s.instanceId then
						local Map = services.MapService
						if Map then
							pcall(Map.DestroyInstance, Map, s.instanceId)
						end
					end
				end
				LobbyService.SquadChanged:Fire(sid)
			end
		end
		afk[p] = { pos = Vector3.zero, t = os.clock(), tagged = false }
	end
	broadcast()
end

------------------------------------------------------------------ idle fun

local function setupPole(station: Model)
	local poleFolder = station:FindFirstChild("FirePole", true)
	local pole = poleFolder and poleFolder:FindFirstChild("Pole") :: BasePart?
	local mat = poleFolder and poleFolder:FindFirstChild("Mat") :: BasePart?
	if not pole or not mat or not pole:IsA("BasePart") or not mat:IsA("BasePart") then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PolePrompt"
	prompt.ActionText = "Slide the pole"
	prompt.ObjectText = "Fire pole"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = mat
	local p0 = pole :: BasePart
	prompt.Triggered:Connect(function(player: Player)
		if not inLobby(player) or not ready(`pole{player.UserId}`, LobbyConfig.PoleSlideSeconds + 0.6) then
			return
		end
		local x = p0.Position.X + 1.3
		local z = p0.Position.Z
		local topY = p0.Position.Y + p0.Size.Y / 2 - 3.2
		local bottomY = (mat :: BasePart).Position.Y + 3
		local face = CFrame.Angles(0, math.rad(-90), 0)
		local r = remotes.Fx
		if r then
			r:FireClient(player, "slide", CFrame.new(x, topY, z) * face, CFrame.new(x, bottomY, z) * face, LobbyConfig.PoleSlideSeconds)
		end
		count("lobby_pole")
	end)
end

local function setupTruck(station: Model)
	local truck: Model? = nil
	for _, d in station:GetDescendants() do
		if d:IsA("Model") and d:HasTag(Names.Tag.Truck) then
			truck = d
			break
		end
	end
	if not truck then
		for _, d in station:GetDescendants() do
			if d:IsA("Model") and string.find(d.Name, "Truck") then
				truck = d
				break
			end
		end
	end
	if not truck then
		return
	end
	local horn: BasePart? = truck.PrimaryPart
	if not horn then
		local best = 0
		for _, d in truck:GetDescendants() do
			if d:IsA("BasePart") and d.Size.Magnitude > best then
				best = d.Size.Magnitude
				horn = d
			end
		end
	end
	if not horn then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HonkPrompt"
	prompt.ActionText = "Honk"
	prompt.ObjectText = "Truck 67"
	prompt.KeyboardKeyCode = Enum.KeyCode.H
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = horn
	local hp = horn :: BasePart
	local lines = { "HONK!", "HOOONK!", "BWAAMP!", "honk?" }
	prompt.Triggered:Connect(function(player: Player)
		if not ready("honk", LobbyConfig.HonkCooldown) then
			return
		end
		playSound(hp, LobbyConfig.HonkSoundId, 1)
		popText(hp, lines[math.random(1, #lines)], Color3.fromHex("FFE14A"), hp.Size.Y / 2 + 6)
		count("lobby_honk")
		if math.random() < 0.3 then
			Popup.show(player, "The station dog is unimpressed.", "info", player)
		end
	end)
end

local function setupBell()
	if not built then
		return
	end
	local bell: BasePart = built.bell
	local home = bell.CFrame
	built.bellPrompt.Triggered:Connect(function(player: Player)
		if not ready("bell", LobbyConfig.BellCooldown) then
			return
		end
		playSound(bell, LobbyConfig.BellSoundId, 1)
		popText(bell, "DING!", Color3.fromHex("FFD35A"), 3)
		local swing = TweenService:Create(bell, TweenInfo.new(0.12, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 5, true), {
			CFrame = home * CFrame.Angles(math.rad(28), 0, 0),
		})
		swing:Play()
		swing.Completed:Once(function()
			bell.CFrame = home
		end)
		count("lobby_bell")
		Popup.show(player, `{player.DisplayName} rang the bell. Nobody knows why.`, "info", player)
	end)
end

local function setAfkTag(player: Player, on: boolean)
	local head = player.Character and player.Character:FindFirstChild("Head")
	if not head then
		return
	end
	local tag = head:FindFirstChild("CoffeeBreak")
	if on and not tag then
		local bb = Instance.new("BillboardGui")
		bb.Name = "CoffeeBreak"
		bb.Size = UDim2.new(7, 0, 1.4, 0)
		bb.StudsOffset = Vector3.new(0, 2.6, 0)
		bb.MaxDistance = 80
		bb.LightInfluence = 0
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Size = UDim2.fromScale(1, 1)
		t.Text = "on coffee break"
		t.TextScaled = true
		t.Font = Enum.Font.FredokaOne
		t.TextColor3 = Color3.fromHex("F2E3C6")
		local s = Instance.new("UIStroke")
		s.Thickness = 2
		s.Color = Color3.fromHex("5A3A22")
		s.Parent = t
		t.Parent = bb
		bb.Parent = head
		count("lobby_afk")
	elseif not on and tag then
		tag:Destroy()
	end
end

local function updateAfk(now: number)
	for _, p in Players:GetPlayers() do
		local root = rootOf(p)
		if not root then
			continue
		end
		local a = afk[p]
		if not a then
			a = { pos = root.Position, t = now, tagged = false }
			afk[p] = a
		end
		local rec = a :: { pos: Vector3, t: number, tagged: boolean }
		if (root.Position - rec.pos).Magnitude > 0.4 or not inLobby(p) then
			rec.pos = root.Position
			rec.t = now
			if rec.tagged then
				rec.tagged = false
				setAfkTag(p, false)
			end
		elseif not rec.tagged and now - rec.t >= LobbyConfig.AfkSeconds then
			rec.tagged = true
			setAfkTag(p, true)
		end
	end
end

------------------------------------------------------------------ the poll loop

local function poll(dt: number)
	local q = queue
	if not q or not built then
		return
	end
	local present: { number } = {}
	local onPad: { [number]: number } = {}
	for _, p in Players:GetPlayers() do
		if not inLobby(p) or launching[p.UserId] then
			continue
		end
		table.insert(present, p.UserId)
		local root = rootOf(p)
		local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
		if not root or not hum or hum.Health <= 0 then
			continue
		end
		for _, rec in built.pads do
			local d = root.Position - rec.part.Position
			if Vector3.new(d.X, 0, d.Z).Magnitude <= LobbyConfig.PadRadius and d.Y > -1 and d.Y < LobbyConfig.PadHeight then
				onPad[p.UserId] = rec.padId
				break
			end
		end
	end
	local before: { [number]: string? } = {}
	for _, pad in q.pads do
		before[pad.padId] = pad.squadId
	end
	local prevPad: { [number]: number? } = {}
	for _, uid in present do
		prevPad[uid] = LobbyQueue.padOf(q, uid)
	end
	local changed = LobbyQueue.apply(q, onPad, present)
	local any = false
	for padId in changed do
		any = true
		padChanged(padId, q.pads[padId].squadId or before[padId])
	end
	if any then
		syncSquadAttrs()
		-- Joiners see the clock immediately; leavers get their countdown cleared.
		for _, uid in present do
			local now = LobbyQueue.padOf(q, uid)
			if now ~= prevPad[uid] then
				if now then
					count("lobby_joins")
					toMembers({ uid }, now, LobbyQueue.secondsLeft(q, now) or -1, title(q.pads[now].missionId))
				else
					toMembers({ uid }, prevPad[uid] or 0, -1, "")
				end
			end
		end
		renderBoard()
		broadcast()
	end

	for _, e in LobbyQueue.tick(q, dt) do
		local pad = q.pads[e.padId]
		if e.kind == "count" then
			renderPad(e.padId)
			toMembers(pad.members, e.padId, e.seconds, title(pad.missionId))
			if (e.seconds or 99) <= LobbyConfig.AlarmFromSeconds then
				flashAlarm(0.45)
			end
			if e.seconds == LobbyConfig.FullCountdownSeconds then
				broadcast() -- state flips to "Launching"
			end
		elseif e.kind == "short" then
			local need = LobbyQueue.minPlayers(q, e.padId)
			for _, uid in pad.members do
				local p = playerById(uid)
				if p then
					Net.notify(p, `{title(e.missionId)} needs {need} firefighters. Grab a friend!`, "bad")
				end
			end
			toMembers(pad.members, e.padId, LobbyQueue.secondsLeft(q, e.padId) or -1, title(pad.missionId))
			renderPad(e.padId)
		elseif e.kind == "launch" and e.squadId and e.members then
			active[e.squadId] = {
				id = e.squadId,
				padId = e.padId,
				leader = e.members[1],
				members = e.members,
				missionId = e.missionId,
				instanceId = nil,
				state = "Launching",
			}
			for _, uid in e.members do
				launching[uid] = true
			end
			renderPad(e.padId)
			local sid, mid = e.squadId :: string, (e.missionId or firstEnabled() or "") :: string
			task.spawn(function()
				local ok, err = pcall(LobbyService.Launch, LobbyService, sid, mid)
				if not ok then
					warn(`[LobbyService] launch {sid} failed: {err}`)
					active[sid] = nil
				end
				for _, uid in e.members or {} do
					launching[uid] = nil
				end
			end)
		end
	end
end

------------------------------------------------------------------ lifecycle

local function waitForStation(): Model?
	local t0 = os.clock()
	while os.clock() - t0 < 60 do
		local Map = services.MapService
		local m = Map and Map:GetLocation(LobbyConfig.LobbyLocation)
		if m then
			return m
		end
		local folder = workspace:FindFirstChild("Map")
		local found = folder and folder:FindFirstChild(LobbyConfig.LobbyLocation)
		if found and found:IsA("Model") then
			return found
		end
		task.wait(0.25)
	end
	return nil
end

local function buildLobby(station: Model)
	stationModel = station
	local old = station:FindFirstChild("Lobby")
	if old then
		old:Destroy()
	end
	local LobbyProps = require(ServerScriptService.Lib.Lobby.LobbyProps :: ModuleScript) :: any
	built = LobbyProps.build(station, MapConfig.SlotOrigin(0), LobbyConfig.SquadPads, LobbyConfig.BoardPixelsPerStud)
	for _, rec in built.pads do
		rec.prompt.Triggered:Connect(function(player: Player)
			local q = queue
			if not q then
				return
			end
			local ids = enabledIds()
			if #ids <= 1 then
				Net.notify(player, "Only one call today. It's a kitchen fire. Again.", "info")
				return
			end
			local pad = q.pads[rec.padId]
			local i = table.find(ids, pad.missionId or "") or 0
			local nextId = ids[(i % #ids) + 1]
			if LobbyQueue.setPadMission(q, rec.padId, player.UserId, nextId) then
				padChanged(rec.padId, pad.squadId)
				renderBoard()
				broadcast()
			else
				Net.notify(player, "Only the squad leader picks the call.", "bad")
			end
		end)
	end
	setupBell()
	setupPole(station)
	setupTruck(station)
	renderBoard()
	if queue then
		for _, pad in queue.pads do
			renderPad(pad.padId)
		end
	end
	print(`[LobbyService] lobby built: board + {#built.pads} pads`)
end

local function spawnInStation(player: Player, character: Model)
	task.delay(0.25, function()
		if not LobbyConfig.UseLobby or not inLobby(player) or player.Character ~= character then
			return
		end
		local slot = table.find(Players:GetPlayers(), player) or 1
		character:PivotTo(stationSpawn(slot))
	end)
end

local function onPlayer(player: Player)
	if player:GetAttribute(Names.Attr.SquadId) == nil then
		player:SetAttribute(Names.Attr.SquadId, "")
	end
	if player:GetAttribute(Names.Attr.InstanceId) == nil then
		player:SetAttribute(Names.Attr.InstanceId, "")
	end
	player.CharacterAdded:Connect(function(c)
		spawnInStation(player, c)
	end)
	if player.Character then
		spawnInStation(player, player.Character)
	end
	task.delay(1, function()
		local r = remotes.Board
		if r and player.Parent == Players then
			r:FireClient(player, LobbyService:GetSquads())
		end
	end)
end

function LobbyService:Init(all: { [string]: any })
	services = all
end

function LobbyService:Start()
	remotes.Board = Net.event("Lobby", "Board")
	remotes.Choose = Net.event("Lobby", "Choose")
	remotes.Launch = Net.event("Lobby", "Launch")
	remotes.Countdown = Net.event("Lobby", "Countdown")
	remotes.Fx = Net.event("Lobby", "Fx")
	if not LobbyConfig.UseLobby then
		return
	end
	catalogIndex()
	queue = LobbyQueue.new({
		pads = LobbyConfig.SquadPads,
		maxSize = LobbyConfig.MaxSquadSize,
		countdown = LobbyConfig.CountdownSeconds,
		fullCountdown = LobbyConfig.FullCountdownSeconds,
		defaultMission = firstEnabled(),
		limits = function(id: string): (number, number)
			local m = byId[id]
			if m and m.players then
				return m.players.min or 1, m.players.max or LobbyConfig.MaxSquadSize
			end
			return 1, LobbyConfig.MaxSquadSize
		end,
	})

	Net.onServer(remotes.Choose, { rate = 2, burst = 2 }, function(player: Player, missionId: any)
		if type(missionId) ~= "string" or #missionId > 64 then
			return
		end
		LobbyService:Choose(player, missionId)
	end)
	Net.onServer(remotes.Launch, { rate = 1, burst = 1 }, function(player: Player)
		local q = queue
		if not q then
			return
		end
		local padId = LobbyQueue.padOf(q, player.UserId)
		if not padId or q.pads[padId].leader ~= player.UserId then
			Net.notify(player, "Only the squad leader can hit GO.", "bad")
			return
		end
		if LobbyQueue.hurry(q, padId, LobbyConfig.LaunchCountdown) then
			local pad = q.pads[padId]
			toMembers(pad.members, padId, LobbyQueue.secondsLeft(q, padId) or -1, title(pad.missionId))
			renderPad(padId)
		end
	end)

	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerAdded:Connect(onPlayer)
	Players.PlayerRemoving:Connect(function(p: Player)
		afk[p] = nil
		for sid, s in active do
			local i = table.find(s.members, p.UserId)
			if i then
				table.remove(s.members, i)
				if #s.members == 0 then
					active[sid] = nil
				end
			end
		end
	end)

	local Mission = services.MissionService
	if Mission and Mission.MissionEnded then
		Mission.MissionEnded:Connect(function(instanceId: string, _results: any)
			for sid, s in active do
				if s.instanceId == instanceId then
					task.delay(LobbyConfig.ReturnSeconds, function()
						local cur = active[sid]
						if not cur or cur.instanceId ~= instanceId then
							return
						end
						-- Safety net: MissionService normally hands the squad back itself (ReturnToLobby after
						-- its results screen). Only bring home members still stuck in this instance.
						local list: { Player } = {}
						for _, uid in cur.members do
							local p = playerById(uid)
							if p and p:GetAttribute(Names.Attr.InstanceId) == instanceId then
								table.insert(list, p)
							end
						end
						active[sid] = nil
						if #list > 0 then
							LobbyService:ReturnToLobby(list)
						end
					end)
				end
			end
		end)
	end
	local Map = services.MapService
	if Map and Map.LocationBuilt then
		Map.LocationBuilt:Connect(function(model: Model, id: string)
			if id == LobbyConfig.LobbyLocation and model ~= stationModel then
				buildLobby(model)
			end
		end)
	end

	local station = waitForStation()
	if not station then
		warn("[LobbyService] no Station location after 60 s: the lobby is not built")
		return
	end
	if station ~= stationModel then
		buildLobby(station)
	end

	local last = os.clock()
	while true do
		task.wait(1 / LobbyConfig.PollHz)
		local now = os.clock()
		local dt = math.min(now - last, 0.5)
		last = now
		local ok, err = pcall(poll, dt)
		if not ok then
			warn(`[LobbyService] poll: {err}`)
		end
		pcall(updateAfk, now)
	end
end

------------------------------------------------------------------ test hooks

function LobbyService:_join(player: Player, padId: number): string?
	return self:Join(player, padId)
end

function LobbyService:_launch(squadId: string, missionId: string): string?
	return self:Launch(squadId, missionId)
end

function LobbyService:_selftest(): (boolean, string)
	if not LobbyConfig.UseLobby then
		return true, "UseLobby = false"
	end
	if not built or not built.model.Parent then
		return false, "lobby not built"
	end
	local boards = 0
	for _, b in CollectionService:GetTagged(Names.Tag.MissionBoard) do
		if b:IsDescendantOf(workspace) then
			boards += 1
		end
	end
	local pads = 0
	for _, p in CollectionService:GetTagged(Names.Tag.SquadPad) do
		if p:IsDescendantOf(workspace) then
			pads += 1
		end
	end
	if boards < 1 or pads < LobbyConfig.SquadPads then
		return false, `board {boards}, pads {pads}`
	end
	return true, `board {boards}, pads {pads}, squads {#LobbyService:GetSquads()}`
end

return LobbyService
