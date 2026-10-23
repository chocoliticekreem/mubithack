--!strict
-- AudioController [owner: AV lane]. Plays every sound in Config/AudioConfig, client-side, on budget.
--
-- Mixing: SoundService.Forge_Audio.Master > {Music, SFX, Ambience, UI, Voice} SoundGroups (local).
-- Derived from replicated state (no server traffic):
--   Burning tag   -> crackle loop on the CrackleMax nearest fire clusters (volume by FireLevel), an
--                    ignite whoosh when a nearby part catches, a steam hiss when one is put out
--                    (removed without Charred), and a 2D roar bed scaled by how many fires are near.
--   Door / Window -> crash / shatter when attr Broken turns true.
--   Player attr Spraying -> hose loop on that player's character.
--   Character attr Ragdolled -> slide whistle.
--   Mission/Alarm -> alarm bell at the nearest AlarmLamps (+ quiet 2D copy) and the truck siren.
--   Instance RoundState -> music (lobby funk / mission brass with a faster tension tail / results),
--                    siren burst on arrival (Active); Mission/Results -> fanfare or sad trombone.
--   Location (GraphicsController:GetLocationId) -> ambience bed (AudioConfig.LocationAmbience).
--   Shared/Notify kind "blame" -> record scratch.
-- From the server (AudioService): Audio/Play (name, at, opts), Audio/Stinger (kind).
-- Budgets (docs/game/02 §12): <= MaxPlaying sounds total, crackles <= CrackleMax nearest, steam and
-- ignite rate-limited. An empty SoundId is skipped, so blanking a bad id in AudioConfig is safe.
--
-- API (other controllers, nil-guarded):
--   AudioController:Play(name: string, at: (Instance | Vector3)?, opts: Opts?): Sound?   -- nil at = 2D
--   AudioController:Loop(name: string, at: (Instance | Vector3)?, opts: Opts?): () -> ()  -- returns stop
--   AudioController:Stinger(kind: string)        -- AudioConfig.Stingers kind; ducks the music
--   AudioController:SetMusic(name: string?)       -- override the automatic track (nil = automatic)
--   AudioController:GetStats(): { playing: number, crackles: number, loops: number }
--   Opts = { volume: number?, speed: number?, pitchVar: number? }
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("AudioConfig") :: ModuleScript) :: any
local AvLogic = require(script.Parent.Parent:WaitForChild("Lib"):WaitForChild("AvLogic") :: ModuleScript)

export type Opts = { volume: number?, speed: number?, pitchVar: number? }

local AudioController = {}
AudioController.Priority = 30

local player = Players.LocalPlayer
local controllers: { [string]: any } = {}
local rng = Random.new()

local root: Folder? = nil
local groups: { [string]: SoundGroup } = {}
local playing = 0 -- one-shots currently playing
local loops = 0 -- loops currently alive

local burning: { [BasePart]: true } = {}
local crackles: { [BasePart]: () -> () } = {}
local crackleCount = 0
local roarStop: (() -> ())? = nil
local roarSound: Sound? = nil
local igniteRate: AvLogic.Rate? = nil
local steamRate: AvLogic.Rate? = nil
local hoseLoops: { [Player]: () -> () } = {}

local music = {
	override = nil :: string?,
	name = nil :: string?,
	sound = nil :: Sound?,
	stop = nil :: (() -> ())?,
}
local ambience = { name = nil :: string?, stop = nil :: (() -> ())? }
local rescueStreak = { n = 0, at = -math.huge }
local duckToken = 0

-- Setup ----------------------------------------------------------------------------------------------------

local function ensureGroups()
	if root and root.Parent then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "Forge_Audio"
	local master = Instance.new("SoundGroup")
	master.Name = "Master"
	master.Volume = Cfg.GroupVolume.Master or 1
	master.Parent = folder
	groups.Master = master
	for _, g in { "Music", "SFX", "Ambience", "UI", "Voice" } do
		local sg = Instance.new("SoundGroup")
		sg.Name = g
		sg.Volume = Cfg.GroupVolume[g] or 1
		sg.Parent = master
		groups[g] = sg
	end
	folder.Parent = SoundService
	root = folder
end

-- Where a sound lives. Instance -> parented to it (3D if it's a part/attachment); Vector3 -> a temporary
-- Attachment in Terrain; nil -> 2D in our SoundService folder. Returns (parent, cleanup?).
local function emitter(at: (Instance | Vector3)?): (Instance?, Instance?)
	if typeof(at) == "Vector3" then
		local terrain = workspace:FindFirstChildOfClass("Terrain")
		if not terrain then
			return nil, nil
		end
		local a = Instance.new("Attachment")
		a.Name = "Forge_Sfx"
		a.WorldPosition = at :: Vector3
		a.Parent = terrain
		return a, a
	elseif typeof(at) == "Instance" then
		local inst = at :: Instance
		if inst:IsA("Model") then
			local m = inst :: Model
			local p = m.PrimaryPart or m:FindFirstChild("HumanoidRootPart") or m:FindFirstChildWhichIsA("BasePart", true)
			return p, nil
		end
		if inst.Parent == nil then
			return nil, nil
		end
		return inst, nil
	end
	return root, nil
end

local function make(name: string, at: (Instance | Vector3)?, opts: Opts?, looped: boolean): (Sound?, Instance?)
	local def = Cfg.Sounds[name]
	if not def or def.id == nil or def.id == "" then
		return nil, nil
	end
	ensureGroups()
	local parent, cleanup = emitter(at)
	if not parent then
		return nil, nil
	end
	local o = opts or {} :: Opts
	local s = Instance.new("Sound")
	s.Name = "Forge_" .. name
	s.SoundId = def.id
	s.Volume = if o.volume ~= nil then o.volume else def.volume
	s.Looped = looped
	local var = if o.pitchVar ~= nil then o.pitchVar else (def.pitchVar or (if looped then 0 else Cfg.PitchVar))
	s.PlaybackSpeed = (o.speed or 1) * (1 + (rng:NextNumber() * 2 - 1) * var)
	s.SoundGroup = groups[def.group] or groups.SFX
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = def.minDist or Cfg.RollOffMin
	s.RollOffMaxDistance = def.maxDist or Cfg.RollOffMax
	if def.startAt then
		s.TimePosition = def.startAt
	end
	s.Parent = parent
	return s, cleanup
end

-- Public: one-shots and loops -------------------------------------------------------------------------------

function AudioController:Play(name: string, at: (Instance | Vector3)?, opts: Opts?): Sound?
	if playing + loops >= (Cfg.MaxPlaying or 24) then
		return nil
	end
	local s, cleanup = make(name, at, opts, false)
	if not s then
		return nil
	end
	playing += 1
	local done = false
	local function finish()
		if done then
			return
		end
		done = true
		playing -= 1
		s:Destroy()
		if cleanup then
			cleanup:Destroy()
		end
	end
	s.Ended:Once(finish)
	s.Destroying:Once(function()
		if not done then
			done = true
			playing -= 1
			if cleanup then
				cleanup:Destroy()
			end
		end
	end)
	task.delay(12, finish) -- safety net if Ended never fires (failed load)
	s:Play()
	return s
end

-- Returns (stop, sound); the loop also stops itself if its parent is destroyed.
local function loopSound(name: string, at: (Instance | Vector3)?, opts: Opts?): (() -> (), Sound?)
	local s, cleanup = make(name, at, opts, true)
	if not s then
		return function() end, nil
	end
	loops += 1
	local stopped = false
	local function stop()
		if stopped then
			return
		end
		stopped = true
		loops -= 1
		s:Destroy()
		if cleanup then
			cleanup:Destroy()
		end
	end
	s.Destroying:Once(function()
		if not stopped then
			stopped = true
			loops -= 1
			if cleanup then
				cleanup:Destroy()
			end
		end
	end)
	s:Play()
	return stop, s
end

function AudioController:Loop(name: string, at: (Instance | Vector3)?, opts: Opts?): () -> ()
	return (loopSound(name, at, opts))
end

local function fade(s: Sound?, to: number, seconds: number, thenDestroy: boolean)
	if not s then
		return
	end
	local t = TweenService:Create(s, TweenInfo.new(seconds, Enum.EasingStyle.Sine), { Volume = to })
	if thenDestroy then
		t.Completed:Once(function()
			s:Destroy()
		end)
	end
	t:Play()
end

local function duck()
	local g = groups.Music
	if not g then
		return
	end
	duckToken += 1
	local token = duckToken
	TweenService:Create(g, TweenInfo.new(0.15), { Volume = Cfg.DuckVolume or 0.12 }):Play()
	task.delay(Cfg.DuckSeconds or 1.6, function()
		if token == duckToken then
			TweenService:Create(g, TweenInfo.new(0.8), { Volume = Cfg.GroupVolume.Music or 0.35 }):Play()
		end
	end)
end

function AudioController:Stinger(kind: string)
	local name = Cfg.Stingers[kind]
	if not name then
		return
	end
	local speed = 1
	if kind == "Rescue" then
		local now = os.clock()
		if now - rescueStreak.at > (Cfg.RescueStreakReset or 12) then
			rescueStreak.n = 0
		end
		rescueStreak.n += 1
		rescueStreak.at = now
		speed = AvLogic.streakPitch(rescueStreak.n, Cfg.RescueDingStep or 0.05)
	end
	if AudioController:Play(name, nil, { speed = speed, pitchVar = 0 }) then
		duck()
	end
end

-- Music / ambience ------------------------------------------------------------------------------------------

local function myInstance(): Instance?
	local iid = player:GetAttribute(Names.Attr.InstanceId)
	if type(iid) ~= "string" or iid == "" then
		return nil
	end
	local folder = workspace:FindFirstChild("Instances")
	return folder and folder:FindFirstChild(iid)
end

local function myRoundState(): (string?, number?)
	local inst = myInstance()
	if not inst then
		return "Lobby", nil
	end
	local st = inst:GetAttribute(Names.Attr.RoundState)
	local ends = inst:GetAttribute(Names.Attr.RoundEndsAt)
	return if type(st) == "string" then st else nil, if type(ends) == "number" then ends else nil
end

local function setTrack(name: string?)
	if name == music.name then
		return
	end
	local fadeTime = Cfg.MusicFade or 1.2
	if music.sound then
		local old, oldStop = music.sound, music.stop
		fade(old, 0, fadeTime, false)
		task.delay(fadeTime, function()
			if oldStop then
				oldStop()
			end
		end)
	end
	music.name, music.sound, music.stop = name, nil, nil
	if not name then
		return
	end
	local def = Cfg.Sounds[name]
	local stop, s = loopSound(name, nil, { volume = 0 })
	music.stop = stop
	music.sound = s
	if s and def then
		fade(s, def.volume, fadeTime, false)
	end
end

local function setAmbience(name: string?)
	if name == ambience.name then
		return
	end
	if ambience.stop then
		ambience.stop()
	end
	ambience.name = name
	ambience.stop = if name then AudioController:Loop(name, nil) else nil
end

function AudioController:SetMusic(name: string?)
	music.override = name
	setTrack(name or AvLogic.musicFor((myRoundState())))
end

-- Siren / alarm ------------------------------------------------------------------------------------------------

local function nearestTagged(tag: string, n: number, filter: ((Instance) -> boolean)?): { Instance }
	local cam = workspace.CurrentCamera
	if not cam then
		return {}
	end
	local pos = cam.CFrame.Position
	local list: { { i: Instance, d: number } } = {}
	for _, inst in CollectionService:GetTagged(tag) do
		if filter and not filter(inst) then
			continue
		end
		local p: Vector3? = nil
		if inst:IsA("BasePart") then
			p = inst.Position
		elseif inst:IsA("Model") then
			p = inst:GetPivot().Position
		end
		if p then
			table.insert(list, { i = inst, d = (p - pos).Magnitude })
		end
	end
	table.sort(list, function(a, b)
		return a.d < b.d
	end)
	local out = {}
	for k = 1, math.min(n, #list) do
		table.insert(out, list[k].i)
	end
	return out
end

local function playFor(name: string, at: (Instance | Vector3)?, seconds: number, opts: Opts?)
	local stop = AudioController:Loop(name, at, opts)
	task.delay(seconds, stop)
end

local function siren(seconds: number)
	local inst = myInstance()
	local trucks = nearestTagged(Names.Tag.Truck, 1, function(t)
		return inst == nil or t:IsDescendantOf(inst)
	end)
	if trucks[1] then
		playFor("Siren", trucks[1], seconds)
	end
end

local function onAlarm()
	for _, lamp in nearestTagged(Names.Tag.AlarmLamp, 3) do
		playFor("Alarm", lamp, Cfg.AlarmSeconds or 4)
	end
	playFor("Alarm", nil, Cfg.AlarmSeconds or 4, { volume = 0.4 * (Cfg.Sounds.Alarm and Cfg.Sounds.Alarm.volume or 0.6) })
	siren(Cfg.SirenSeconds or 8)
end

-- Fire ---------------------------------------------------------------------------------------------------------

local function crackleVolume(part: BasePart): number
	local def = Cfg.Sounds.Crackle
	local lvl = part:GetAttribute(Names.Attr.FireLevel)
	local l = if type(lvl) == "number" then lvl else 1
	return (def and def.volume or 0.7) * (0.45 + 0.2 * math.clamp(l, 1, 3))
end

local function updateCrackles()
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local parts: { BasePart } = {}
	local pts: { AvLogic.P3 } = {}
	for part in burning do
		if part.Parent then
			table.insert(parts, part)
			local p = part.Position
			table.insert(pts, { x = p.X, y = p.Y, z = p.Z })
		else
			burning[part] = nil
		end
	end
	local c = cam.CFrame.Position
	local picked = AvLogic.pickNearest(
		{ x = c.X, y = c.Y, z = c.Z },
		pts,
		Cfg.CrackleMax or 6,
		Cfg.CrackleRadius or 110,
		Cfg.CrackleClusterRadius or 10
	)
	local keep: { [BasePart]: boolean } = {}
	for _, i in picked do
		keep[parts[i]] = true
	end
	for part, stop in crackles do
		if not keep[part] then
			stop()
			crackles[part] = nil
			crackleCount -= 1
		end
	end
	for part in keep do
		if not crackles[part] then
			crackles[part] = AudioController:Loop("Crackle", part, { volume = crackleVolume(part) })
			crackleCount += 1
		end
	end

	-- 2D roar bed from fires near me (instances are 400 studs apart, so 250 never crosses into another).
	local near = 0
	for _, p in pts do
		local dx, dy, dz = p.x - c.X, p.y - c.Y, p.z - c.Z
		if dx * dx + dy * dy + dz * dz < 250 * 250 then
			near += 1
		end
	end
	local vol = AvLogic.roarVolume(near, Cfg.RoarFullAt or 30, Cfg.RoarMaxVolume or 0.6)
	if vol > 0 and not roarStop then
		roarStop, roarSound = loopSound("FireRoar", nil, { volume = 0 })
	end
	if roarSound then
		fade(roarSound, vol, 0.8, false)
	end
	if vol <= 0 and roarStop then
		local stop = roarStop
		roarStop, roarSound = nil, nil
		task.delay(0.8, stop)
	end
end

local function withinCrackleRadius(part: BasePart): boolean
	local cam = workspace.CurrentCamera
	local r = Cfg.CrackleRadius or 110
	return cam ~= nil and (part.Position - cam.CFrame.Position).Magnitude <= r
end

local function onBurningAdded(inst: Instance, quiet: boolean)
	if not inst:IsA("BasePart") then
		return
	end
	local part = inst :: BasePart
	burning[part] = true
	if quiet or not withinCrackleRadius(part) then
		return
	end
	local ok
	ok, igniteRate = AvLogic.rateAllow(igniteRate, os.clock(), 3)
	if ok then
		AudioController:Play("Ignite", part)
	end
end

local function onBurningRemoved(inst: Instance)
	local part = inst :: BasePart
	burning[part] = nil
	local stop = crackles[part]
	if stop then
		stop()
		crackles[part] = nil
		crackleCount -= 1
	end
	if not inst:IsA("BasePart") or not part:IsDescendantOf(workspace) then
		return
	end
	if part:GetAttribute(Names.Attr.Charred) == true or not withinCrackleRadius(part) then
		return
	end
	local ok
	ok, steamRate = AvLogic.rateAllow(steamRate, os.clock(), Cfg.SteamPerSecond or 4)
	if ok then
		AudioController:Play("Steam", part.Position)
	end
end

-- Doors / windows / players ----------------------------------------------------------------------------------------

local function watchBreakable(inst: Instance, soundName: string)
	if not inst:IsA("BasePart") then
		return
	end
	inst:GetAttributeChangedSignal(Names.Attr.Broken):Connect(function()
		if inst:GetAttribute(Names.Attr.Broken) == true and inst:IsDescendantOf(workspace) then
			AudioController:Play(soundName, (inst :: BasePart).Position)
		end
	end)
end

local function watchCharacter(p: Player, char: Model)
	char:GetAttributeChangedSignal(Names.Attr.Ragdolled):Connect(function()
		if char:GetAttribute(Names.Attr.Ragdolled) == true then
			AudioController:Play("SlideWhistle", if p == player then nil else char)
		end
	end)
end

local function updateHose(p: Player)
	local on = p:GetAttribute(Names.Attr.Spraying) == true
	local stop = hoseLoops[p]
	if on and not stop then
		local char = p.Character
		local tool = char and char:FindFirstChildOfClass("Tool")
		local handle = tool and tool:FindFirstChild("Handle")
		local at = handle or (char and char:FindFirstChild("HumanoidRootPart"))
		if at then
			hoseLoops[p] = AudioController:Loop("HoseLoop", at)
		end
	elseif not on and stop then
		stop()
		hoseLoops[p] = nil
	end
end

local function watchPlayer(p: Player)
	p:GetAttributeChangedSignal(Names.Attr.Spraying):Connect(function()
		updateHose(p)
	end)
	if p.Character then
		watchCharacter(p, p.Character)
	end
	p.CharacterAdded:Connect(function(c)
		local stop = hoseLoops[p]
		if stop then
			stop()
			hoseLoops[p] = nil
		end
		watchCharacter(p, c)
	end)
end

-- Remotes (declared by other owners; never block boot on them) -------------------------------------------------------

local function onRemote(ns: string, name: string, fn: (...any) -> ())
	task.spawn(function()
		local ok, remote = pcall(Net.event, ns, name)
		if not ok then
			return -- owner not running in this build; harmless
		end
		(remote :: RemoteEvent).OnClientEvent:Connect(function(...)
			local fine, err = pcall(fn, ...)
			if not fine then
				warn(`[AudioController] {ns}/{name}: {err}`)
			end
		end)
	end)
end

-- Controller ------------------------------------------------------------------------------------------------------

function AudioController:Init(all: { [string]: any })
	controllers = all
end

function AudioController:Start()
	ensureGroups()

	for _, inst in CollectionService:GetTagged(Names.Tag.Burning) do
		onBurningAdded(inst, true)
	end
	CollectionService:GetInstanceAddedSignal(Names.Tag.Burning):Connect(function(inst)
		onBurningAdded(inst, false)
	end)
	CollectionService:GetInstanceRemovedSignal(Names.Tag.Burning):Connect(onBurningRemoved)

	for tag, snd in { [Names.Tag.Door] = "DoorBreak", [Names.Tag.Window] = "GlassShatter" } do
		for _, inst in CollectionService:GetTagged(tag) do
			watchBreakable(inst, snd)
		end
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst)
			watchBreakable(inst, snd)
		end)
	end

	for _, p in Players:GetPlayers() do
		watchPlayer(p)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function(p)
		local stop = hoseLoops[p]
		if stop then
			stop()
			hoseLoops[p] = nil
		end
	end)

	onRemote("Audio", "Play", function(name: string, at: any, opts: any)
		AudioController:Play(name, at, opts)
	end)
	onRemote("Audio", "Stinger", function(kind: string)
		AudioController:Stinger(kind)
	end)
	onRemote("Mission", "Alarm", function()
		onAlarm()
	end)
	onRemote("Mission", "Results", function(payload: any)
		local stars = type(payload) == "table" and tonumber(payload.stars) or 0
		local reason = type(payload) == "table" and payload.reason or nil
		AudioController:Stinger(if (stars or 0) >= 2 and reason ~= "allOut" then "RoundComplete" else "RoundFailed")
	end)
	onRemote("Shared", "Notify", function(_text: string, kind: string?)
		if kind == "blame" then
			AudioController:Stinger("Blame")
		end
	end)

	-- Crackle budget.
	task.spawn(function()
		while true do
			task.wait(1 / math.max(0.5, Cfg.CrackleHz or 3))
			updateCrackles()
		end
	end)

	-- Music, tension, arrival siren and ambience (1 Hz).
	task.spawn(function()
		local lastState: string? = nil
		while true do
			local st, endsAt = myRoundState()
			if not music.override then
				setTrack(AvLogic.musicFor(st))
			end
			if music.sound and music.name == "MissionMusic" then
				local left = if endsAt then endsAt - workspace:GetServerTimeNow() else math.huge
				local tense = st == "Active" and left <= (Cfg.TensionSeconds or 30)
				music.sound.PlaybackSpeed = if tense then (Cfg.TensionSpeed or 1.06) else 1
			end
			if st == "Active" and lastState ~= "Active" and lastState ~= nil then
				siren(Cfg.ArriveSirenSeconds or 5)
			end
			lastState = st
			local gfx = controllers.GraphicsController
			local loc = gfx and gfx.GetLocationId and gfx:GetLocationId() or nil
			setAmbience(loc and Cfg.LocationAmbience[loc] or nil)
			task.wait(1)
		end
	end)
end

function AudioController:GetStats(): { playing: number, crackles: number, loops: number }
	return { playing = playing, crackles = crackleCount, loops = loops }
end

return AudioController
