--!strict
-- SquadService [owner: G3]. The crew: helmet numbers 01..04 per squad, everyone dressed as a trailer
-- firefighter (Lib/Squad/CostumeBuilder), spawning on the StationSpawn pads in the lobby, Downed
-- (lying on your back, spiral eyes, circling stars, slow crawl) and revive (hold E to give oxygen, or
-- an instant F SLAP that costs the slapper a blame point), bleed-out respawn at the truck, squad
-- wipe = mission failed, and lobby emotes on the number keys (wave / facepalm / blame-point).
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   SquadService:GetHelmet(player: Player): number       -- 1..4
--   SquadService:Down(player: Player, cause: string, culprit: Player?)
--   SquadService:Revive(player: Player, by: Player?, method: string?)  -- method "oxygen" (default) | "slap" | "auto"
--   SquadService:RespawnAll()                            -- everyone back to a StationSpawn pad
--   SquadService:IsDowned(player: Player): boolean
-- Signals: Downed(victim: Player, cause: string, culprit: Player?)
--          Revived(victim: Player, by: Player?, method: string)   -- "slap" = +SquadConfig.SlapBlame blame for `by`
--          Wiped(groupKey: string, players: { Player })            -- everyone in a mission downed
--          Emoted(player: Player, emote: string, target: Player?)  -- lobby emotes (blame-point has a target)
-- Remotes: Squad/Emote (C->S emote: string, targetUserId: number?; 1/s), Squad/Fx (S->C all:
--          kind "down"|"revive"|"emote", userId, a?, b?)
-- Writes: Player attrs Helmet, Downed, DownedUntil (SquadConfig.AttrDownedUntil); character
--         Folder "Costume"; counters player_downs, player_revives, slap_revives, player_bleedouts,
--         squad_wipes, emotes
-- Consumes (nil-guarded): MapService:GetSpawnCFrame/GetInstance, VehicleService:GetTruck,
--   HeatService.Overheated, HazardService.Zapped/.Flung, MissionService.RoundEnded/.MissionEnded,
--   MissionService:EndRound/EndMission, Shared/Ragdoll (G1)
-- Test hooks (DevHook only): _down(player, cause?), _revive(player, by?, method?), _emote(player, emote, target?),
--   _selftest()
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = ReplicatedStorage:WaitForChild("Config")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Ragdoll = require(Shared:WaitForChild("Ragdoll") :: ModuleScript)
local SquadConfig = require(Config:WaitForChild("SquadConfig") :: ModuleScript)
local LobbyConfig = require(Config:WaitForChild("LobbyConfig") :: ModuleScript)
local PhysicsConfig = require(Config:WaitForChild("PhysicsConfig") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local SquadLib = ServerScriptService:WaitForChild("Lib"):WaitForChild("Squad")
local SquadRules = require(SquadLib:WaitForChild("SquadRules") :: ModuleScript)
local CostumeBuilder = require(SquadLib:WaitForChild("CostumeBuilder") :: ModuleScript)

local SquadService = {}
SquadService.Priority = 10
SquadService.Downed = Signal.new() :: Signal.Signal<Player, string, Player?>
SquadService.Revived = Signal.new() :: Signal.Signal<Player, Player?, string>
SquadService.Wiped = Signal.new() :: Signal.Signal<string, { Player }>
SquadService.Emoted = Signal.new() :: Signal.Signal<Player, string, Player?>

local services: { [string]: any } = {}
local helmets: { [Player]: number } = {}
local downToken: { [Player]: number } = {}
local respawnAtTruck: { [Player]: string } = {} -- player -> group key, consumed by the next CharacterAdded
local wiped: { [string]: boolean } = {}
local fxRemote: RemoteEvent? = nil

---------------------------------------------------------------------------- helpers
local function tagOf(player: Player): string
	return SquadRules.tag(SquadService:GetHelmet(player))
end

local function humanoidOf(player: Player): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function rootOf(player: Player): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function roundState(): string?
	return workspace:GetAttribute(Names.Attr.RoundState) :: string?
end

local function groupKeyOf(player: Player): string?
	return SquadRules.groupKey(player:GetAttribute(Names.Attr.InstanceId) :: string?, LobbyConfig.UseLobby == true, roundState())
end

local function inLobby(player: Player): boolean
	return SquadRules.inLobby(player:GetAttribute(Names.Attr.InstanceId) :: string?, LobbyConfig.UseLobby == true, roundState())
end

local function fx(kind: string, userId: number, a: any?, b: any?)
	if fxRemote then
		fxRemote:FireAllClients(kind, userId, a, b)
	end
end

local function sound(parent: Instance?, id: string)
	if not parent or id == "" then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = 0.8
	s.Parent = parent
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
	task.delay(6, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

local function setPlayerCamera(player: Player, firstPerson: boolean)
	if firstPerson and PhysicsConfig.FirstPerson then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	else
		player.CameraMode = Enum.CameraMode.Classic
	end
end

---------------------------------------------------------------------------- helmets
local function squadOf(player: Player): string
	return (player:GetAttribute(Names.Attr.SquadId) :: string?) or ""
end

local function assignHelmet(player: Player): number
	local mine = squadOf(player)
	local taken: { [number]: boolean } = {}
	for other, n in helmets do
		if other ~= player and other.Parent and squadOf(other) == mine then
			taken[n] = true
		end
	end
	local n = SquadRules.pickHelmet(taken, SquadConfig.MaxHelmet)
	helmets[player] = n
	player:SetAttribute(Names.Attr.Helmet, n)
	local char = player.Character
	if char then
		CostumeBuilder.setNumber(char, n)
	end
	return n
end

---------------------------------------------------------------------------- lying pose
local function rootMotor(character: Model): Motor6D?
	local lower = character:FindFirstChild("LowerTorso")
	local m = lower and lower:FindFirstChild("Root")
	if m and m:IsA("Motor6D") then
		return m
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local r6 = hrp and hrp:FindFirstChild("RootJoint")
	if r6 and r6:IsA("Motor6D") then
		return r6
	end
	return nil
end

-- On your back, face up (so teammates see the spiral eyes), head trailing behind: a slow worm crawl.
local function setLying(character: Model, on: boolean)
	local hum = character:FindFirstChildOfClass("Humanoid")
	local motor = rootMotor(character)
	if motor then
		local base = motor:GetAttribute("SquadBaseC0") :: CFrame?
		if base == nil then
			base = motor.C0
			motor:SetAttribute("SquadBaseC0", base)
		end
		local b = base :: CFrame
		motor.C0 = if on then b * CFrame.new(0, -SquadConfig.DownedDrop, 0) * CFrame.Angles(math.rad(90), 0, 0) else b
	end
	if hum then
		local hip = hum:GetAttribute("SquadBaseHip") :: number?
		if hip == nil then
			hip = hum.HipHeight
			hum:SetAttribute("SquadBaseHip", hip)
		end
		hum.HipHeight = if on then SquadConfig.DownedHipHeight else hip :: number
	end
end

local function clearPrompts(player: Player)
	local root = rootOf(player)
	if not root then
		return
	end
	for _, name in { "Revive", "Slap" } do
		local p = root:FindFirstChild(name)
		if p then
			p:Destroy()
		end
	end
end

---------------------------------------------------------------------------- spawning
local function waitMap()
	local t0 = os.clock()
	while workspace:GetAttribute(Names.Attr.MapReady) ~= true and os.clock() - t0 < 10 do
		task.wait(0.2)
	end
end

local function padCFrame(helmet: number): CFrame?
	local Map = services.MapService
	if not Map then
		return nil
	end
	waitMap()
	local ok, cf = pcall(Map.GetSpawnCFrame, Map, helmet)
	return if ok then cf else nil
end

local function truckCFrame(key: string, player: Player?): CFrame?
	local truck: Instance? = nil
	if key ~= "round" then
		local Map = services.MapService
		local inst = Map and Map.GetInstance and Map:GetInstance(key)
		inst = inst or (workspace:FindFirstChild("Instances") and (workspace :: any).Instances:FindFirstChild(key))
		if inst then
			for _, d in inst:GetDescendants() do
				if d:HasTag(Names.Tag.Truck) then
					truck = d
					break
				end
			end
			if not truck then
				for _, d in inst:GetDescendants() do
					if d:HasTag(Names.Tag.TruckSpot) then
						truck = d
						break
					end
				end
			end
		end
	end
	if not truck then
		local Vehicle = services.VehicleService
		local ok, t = pcall(function()
			return Vehicle and Vehicle:GetTruck(player) -- v2: one truck per player
		end)
		truck = if ok then t else nil
	end
	if truck and (truck:IsA("Model") or truck:IsA("BasePart")) then
		local cf = (truck :: any):GetPivot() :: CFrame
		return CFrame.new(cf.Position + cf.RightVector * 9 + Vector3.new(0, 4, 0)) * cf.Rotation
	end
	return nil
end

---------------------------------------------------------------------------- squad wipe
local function membersOf(key: string): { Player }
	local list = {}
	for _, p in Players:GetPlayers() do
		if groupKeyOf(p) == key then
			table.insert(list, p)
		end
	end
	return list
end

local function isWiped(key: string): (boolean, { Player })
	local members = membersOf(key)
	local downed = {}
	for _, p in members do
		table.insert(downed, p:GetAttribute(Names.Attr.Downed) == true)
	end
	return SquadRules.isWiped(downed, SquadConfig.WipeMinPlayers), members
end

local function checkWipe(victim: Player)
	local key = groupKeyOf(victim)
	if not key or wiped[key] then
		return
	end
	local now, members = isWiped(key)
	if not now then
		return
	end
	wiped[key] = true -- cleared when that mission/round ends (onGroupEnded)
	Telemetry.count("squad_wipes")
	SquadService.Wiped:Fire(key, members)
	if not SquadConfig.WipeEndsMission then
		return -- MissionService ends the run as "wiped" from the Downed attrs
	end
	task.delay(SquadConfig.WipeGraceSeconds, function()
		local still
		still, members = isWiped(key)
		if not still then
			return
		end
		local Mission = services.MissionService
		if Mission and SquadConfig.WipeEndsMission then
			for _, p in members do
				Net.notify(p, "The whole crew is napping... MISSION FAILED", "bad")
			end
			local ok, err = pcall(function()
				if key == "round" then
					Mission:EndRound("forced")
				else
					Mission:EndMission(key, "forced")
				end
			end)
			if not ok then
				warn(`[SquadService] end mission on wipe: {err}`)
			end
		end
	end)
end

-- Mission over: stand everyone in that group back up (no credit), allow the next wipe.
local function onGroupEnded(key: string?)
	if key then
		wiped[key] = nil
	end
	for _, p in Players:GetPlayers() do
		if p:GetAttribute(Names.Attr.Downed) == true then
			local k = groupKeyOf(p)
			if k == nil or k == key then
				SquadService:Revive(p, nil, "auto")
			end
		end
	end
end

---------------------------------------------------------------------------- characters
local function onCharacter(player: Player, character: Model)
	downToken[player] = (downToken[player] or 0) + 1
	player:SetAttribute(Names.Attr.Downed, false)
	player:SetAttribute(SquadConfig.AttrDownedUntil, nil)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	local hum = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not root or not hum then
		return
	end
	hum.BreakJointsOnDeath = false
	hum.HealthChanged:Connect(function(health: number)
		if health > 0 and health <= SquadConfig.DownAtHealth and player:GetAttribute(Names.Attr.Downed) ~= true then
			SquadService:Down(player, "hurt", nil)
		end
	end)
	character.ChildAdded:Connect(function(child)
		if player:GetAttribute(Names.Attr.Downed) == true and child:IsA("Tool") then
			task.defer(function()
				hum:UnequipTools()
			end)
		elseif child:IsA("Accessory") or child:IsA("Shirt") or child:IsA("Pants") then
			task.defer(function()
				if character:FindFirstChild("Costume") then
					child:Destroy()
				end
			end)
		end
	end)
	task.wait() -- let the default spawn finish before we move it
	local helmet = SquadService:GetHelmet(player)
	local truckKey = respawnAtTruck[player]
	respawnAtTruck[player] = nil
	local cf = truckKey and truckCFrame(truckKey, player) or padCFrame(helmet)
	if cf and character.Parent then
		character:PivotTo(cf)
	end
	local ok, err = pcall(CostumeBuilder.dress, character, helmet, player)
	if not ok then
		warn(`[SquadService] costume failed: {err}`)
	end
	setPlayerCamera(player, true)
end

local function onPlayer(player: Player)
	assignHelmet(player)
	player:SetAttribute(Names.Attr.Downed, false)
	player:GetAttributeChangedSignal(Names.Attr.SquadId):Connect(function()
		assignHelmet(player)
	end)
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
end

---------------------------------------------------------------------------- emotes
local function onEmote(player: Player, emote: any, targetUserId: any)
	if not SquadRules.isEmote(emote, SquadConfig.Emotes) then
		return
	end
	if not inLobby(player) or player:GetAttribute(Names.Attr.Downed) == true then
		return
	end
	local target: Player? = nil
	if emote == "blame" and type(targetUserId) == "number" then
		local t = Players:GetPlayerByUserId(targetUserId)
		if t and t ~= player then
			target = t
		end
	end
	Telemetry.count("emotes")
	fx("emote", player.UserId, emote, target and target.UserId)
	sound(rootOf(player), SquadConfig.EmoteSoundId)
	SquadService.Emoted:Fire(player, emote :: string, target)
	if target then
		Popup.show(target, `{tagOf(player)} blames {tagOf(target)}!`, "blame", player)
	end
end

---------------------------------------------------------------------------- lifecycle
function SquadService:Init(all: { [string]: any })
	services = all
end

function SquadService:Start()
	StarterPlayer.LoadCharacterAppearance = false -- everyone wears the same uniform
	fxRemote = Net.event("Squad", "Fx")
	Net.onServer(Net.event("Squad", "Emote"), { rate = 1, burst = 1 }, onEmote)

	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		local key = groupKeyOf(player)
		helmets[player] = nil
		downToken[player] = nil
		respawnAtTruck[player] = nil
		if key then
			-- the last standing player leaving can still wipe the rest
			task.defer(function()
				for _, p in membersOf(key) do
					checkWipe(p)
					break
				end
			end)
		end
	end)

	local Heat = services.HeatService
	if Heat and Heat.Overheated then
		Heat.Overheated:Connect(function(player: Player)
			SquadService:Down(player, "heat", nil)
		end)
	end
	local Hazard = services.HazardService
	if Hazard then
		if Hazard.Zapped then
			Hazard.Zapped:Connect(function(victim: Player, culprit: Player?)
				SquadService:Down(victim, "electrocution", culprit)
			end)
		end
		if Hazard.Flung then
			Hazard.Flung:Connect(function(victim: Player, hazardId: string)
				SquadService:Down(victim, hazardId, nil)
			end)
		end
	end
	local Mission = services.MissionService
	if Mission then
		if Mission.RoundEnded then
			Mission.RoundEnded:Connect(function()
				onGroupEnded("round")
			end)
		end
		if Mission.MissionEnded then
			Mission.MissionEnded:Connect(function(instanceId: string)
				onGroupEnded(instanceId)
			end)
		end
		if Mission.RoundStarted then
			Mission.RoundStarted:Connect(function()
				wiped.round = nil
			end)
		end
	end
end

---------------------------------------------------------------------------- API
function SquadService:GetHelmet(player: Player): number
	return helmets[player] or (player:GetAttribute(Names.Attr.Helmet) :: number?) or 1
end

function SquadService:IsDowned(player: Player): boolean
	return player:GetAttribute(Names.Attr.Downed) == true
end

function SquadService:Down(player: Player, cause: string, culprit: Player?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if player:GetAttribute(Names.Attr.Downed) == true then
		return
	end
	if not SquadRules.causeDowns(cause, SquadConfig.DownCauses) then
		return
	end
	local hum = humanoidOf(player)
	local root = rootOf(player)
	local char = player.Character
	if not hum or not root or not char or hum.Health <= 0 then
		return
	end
	player:SetAttribute(Names.Attr.Downed, true)
	player:SetAttribute(SquadConfig.AttrDownedUntil, workspace:GetServerTimeNow() + SquadConfig.BleedOutSeconds)
	hum:UnequipTools()
	hum.WalkSpeed = SquadConfig.CrawlSpeed
	hum.UseJumpPower = false
	hum.JumpHeight = 0
	if hum.Health < SquadConfig.DownAtHealth then
		hum.Health = math.min(hum.MaxHealth, SquadConfig.DownAtHealth)
	end
	if SquadConfig.DownedThirdPerson then
		setPlayerCamera(player, false)
	end

	-- the flop (G1's ragdoll, if it's in), then lie on your back
	downToken[player] = (downToken[player] or 0) + 1
	local token = downToken[player]
	local okRag, flopped = pcall(Ragdoll.enable, char, SquadConfig.FlopSeconds)
	if okRag and flopped then
		task.delay(SquadConfig.FlopSeconds, function()
			if downToken[player] == token and player.Character == char then
				setLying(char, true)
			end
		end)
	else
		setLying(char, true)
	end

	clearPrompts(player)
	local oxygen = Instance.new("ProximityPrompt")
	oxygen.Name = "Revive"
	oxygen.ActionText = "Give oxygen"
	oxygen.ObjectText = tagOf(player)
	oxygen.KeyboardKeyCode = Enum.KeyCode.E
	oxygen.HoldDuration = SquadConfig.ReviveHold
	oxygen.MaxActivationDistance = SquadConfig.ReviveDistance
	oxygen.RequiresLineOfSight = false
	oxygen.Triggered:Connect(function(by: Player)
		SquadService:_tryRevive(player, by, "oxygen")
	end)
	oxygen.Parent = root
	local slap = Instance.new("ProximityPrompt")
	slap.Name = "Slap"
	slap.ActionText = "SLAP awake (+1 blame)"
	slap.ObjectText = tagOf(player)
	slap.KeyboardKeyCode = Enum.KeyCode.F
	slap.GamepadKeyCode = Enum.KeyCode.ButtonY
	slap.HoldDuration = 0
	slap.MaxActivationDistance = SquadConfig.ReviveDistance
	slap.RequiresLineOfSight = false
	slap.UIOffset = Vector2.new(0, 70)
	slap.Triggered:Connect(function(by: Player)
		SquadService:_tryRevive(player, by, "slap")
	end)
	slap.Parent = root

	SquadService.Downed:Fire(player, cause, culprit)
	Telemetry.count("player_downs")
	fx("down", player.UserId, cause, culprit and culprit.UserId)
	sound(root, SquadConfig.DownSoundId)
	local why = if culprit then ` ({tagOf(culprit)}'s fault)` else ""
	-- your own downed stays a screen toast; everyone near sees a small popup over you
	Net.notify(player, `You're down!{why}`, "bad")
	Popup.show(player, `DOWN!{why}`, "bad", culprit)

	task.delay(SquadConfig.BleedOutSeconds, function()
		if downToken[player] ~= token or player:GetAttribute(Names.Attr.Downed) ~= true or not player.Parent then
			return
		end
		Telemetry.count("player_bleedouts")
		local key = groupKeyOf(player)
		if key then
			respawnAtTruck[player] = key
		end
		Net.notify(player, "You napped too long. Back to the truck!", "info")
		player:LoadCharacter() -- CharacterAdded clears Downed and places them
	end)

	checkWipe(player)
end

function SquadService:_tryRevive(victim: Player, by: Player, method: string)
	local a, b = rootOf(victim), rootOf(by)
	local ok = SquadRules.canRevive({
		self = victim == by,
		victimDowned = victim:GetAttribute(Names.Attr.Downed) == true,
		reviverDowned = by:GetAttribute(Names.Attr.Downed) == true,
		sameGroup = groupKeyOf(victim) == groupKeyOf(by),
		distance = if a and b then (a.Position - b.Position).Magnitude else math.huge,
		maxDistance = SquadConfig.ReviveDistance + 2,
	})
	if ok then
		self:Revive(victim, by, method)
	end
end

function SquadService:Revive(player: Player, by: Player?, method: string?)
	if player:GetAttribute(Names.Attr.Downed) ~= true then
		return
	end
	local how = method or "oxygen"
	downToken[player] = (downToken[player] or 0) + 1
	player:SetAttribute(Names.Attr.Downed, false)
	player:SetAttribute(SquadConfig.AttrDownedUntil, nil)
	clearPrompts(player)
	local char = player.Character
	if char then
		setLying(char, false)
	end
	local health, blame = SquadRules.reviveOutcome(how, SquadConfig)
	local hum = humanoidOf(player)
	if hum then
		hum.WalkSpeed = SquadConfig.WalkSpeed
		hum.UseJumpPower = false
		hum.JumpHeight = SquadConfig.JumpHeight
		hum.Health = math.min(hum.MaxHealth, math.max(hum.Health, health))
	end
	setPlayerCamera(player, true)

	if how == "slap" and by and char then
		local a, b = rootOf(player), rootOf(by)
		local dir = if a and b then (a.Position - b.Position) * Vector3.new(1, 0, 1) else Vector3.zero
		dir = if dir.Magnitude > 0.01 then dir.Unit else Vector3.new(1, 0, 0)
		pcall(Ragdoll.knockback, char, dir * SquadConfig.SlapImpulse + Vector3.new(0, SquadConfig.SlapImpulse * 0.4, 0))
		sound(a, SquadConfig.SlapSoundId)
		Telemetry.count("slap_revives")
		Popup.show(player, `SLAPPED awake by {tagOf(by)}!`, "blame", by)
	elseif by then
		sound(rootOf(player), SquadConfig.ReviveSoundId)
		Popup.show(player, `Revived by {tagOf(by)}!`, "good", by)
	end
	if by then
		Telemetry.count("player_revives")
	end
	fx("revive", player.UserId, by and by.UserId, how)
	SquadService.Revived:Fire(player, by, how)
end

function SquadService:RespawnAll()
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			player:LoadCharacter()
		end)
	end
end

---------------------------------------------------------------------------- test hooks
function SquadService:_down(player: Player, cause: string?)
	self:Down(player, cause or "test", nil)
end

function SquadService:_revive(player: Player, by: Player?, method: string?)
	self:Revive(player, by, method)
end

function SquadService:_emote(player: Player, emote: string, target: Player?)
	onEmote(player, emote, target and target.UserId)
end

function SquadService:_selftest(): (boolean, string)
	local seen: { [string]: boolean } = {}
	for _, player in Players:GetPlayers() do
		local n = player:GetAttribute(Names.Attr.Helmet)
		if type(n) ~= "number" or n < 1 or n > SquadConfig.MaxHelmet then
			return false, `{player.Name} has no helmet`
		end
		local key = `{squadOf(player)}#{n}`
		if seen[key] and #Players:GetPlayers() <= SquadConfig.MaxHelmet then
			return false, `duplicate helmet {n} in squad "{squadOf(player)}"`
		end
		seen[key] = true
		local char = player.Character
		if char and char:FindFirstChildOfClass("Humanoid") and not char:FindFirstChild("Costume") then
			return false, `{player.Name} is not dressed`
		end
	end
	return true, `{#Players:GetPlayers()} crew`
end

return SquadService
