--!nonstrict
-- MusicPlayer (Forge kit, client): looping background music per area, crossfaded, with a mute button.
-- Track ids are Roblox-licensed (APM) music from forge/kit/sounds.json "music"; each one loaded in a
-- Studio playtest (IsLoaded, TimeLength > 20 s) on the date recorded there. Do not rewrite; require it.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local MusicPlayer = {}

-- The same list as sounds.json "music" (tests/test_kit_modules.py keeps them in sync).
MusicPlayer.Tracks = {
	{ name = "CircusAndClowns", id = "rbxassetid://9046172474", mood = "carnival", volume = 0.35 },
	{ name = "Funfair", id = "rbxassetid://1838895004", mood = "carnival", volume = 0.35 },
	{ name = "CarouselWaltz", id = "rbxassetid://9046170527", mood = "carnival", volume = 0.35 },
	{ name = "UpbeatPop", id = "rbxassetid://1839763308", mood = "pop", volume = 0.35 },
	{ name = "SummerSunshine", id = "rbxassetid://1843525041", mood = "pop", volume = 0.35 },
	{ name = "EasyUke", id = "rbxassetid://9038762538", mood = "lobby", volume = 0.35 },
	{ name = "SunShines", id = "rbxassetid://9043403524", mood = "lobby", volume = 0.35 },
	{ name = "CreepyCrawlies", id = "rbxassetid://9045310530", mood = "spooky", volume = 0.35 },
	{ name = "RideTheBroomstick", id = "rbxassetid://1847480042", mood = "spooky", volume = 0.35 },
	{ name = "HighSeaAdventure", id = "rbxassetid://1846751102", mood = "pirate", volume = 0.35 },
	{ name = "BuccaneerOverture", id = "rbxassetid://1837777556", mood = "pirate", volume = 0.35 },
	{ name = "SonicRollerCoaster", id = "rbxassetid://1837339537", mood = "intense", volume = 0.35 },
	{ name = "HellRacingSquad", id = "rbxassetid://9047147693", mood = "intense", volume = 0.35 },
	{ name = "BuddiesFanfare", id = "rbxassetid://1835767054", mood = "victory", volume = 0.35 },
	{ name = "PartyCelebration", id = "rbxassetid://1845412717", mood = "victory", volume = 0.35 },
	{ name = "CalmWaters", id = "rbxassetid://1842181702", mood = "water", volume = 0.35 },
}

-- Words in an area name that pick a mood, so Area = "Haunted House" works with no config.
local ALIASES = {
	fair = "carnival", fairground = "carnival", funfair = "carnival", circus = "carnival", carousel = "carnival",
	amusement = "carnival", park = "carnival", clown = "carnival", teacup = "carnival", teacups = "carnival",
	ferris = "carnival", happy = "pop", upbeat = "pop", dance = "pop", bumper = "pop", arcade = "pop",
	chill = "lobby", hub = "lobby", menu = "lobby", spawn = "lobby", plaza = "lobby", shop = "lobby", gate = "lobby",
	haunted = "spooky", ghost = "spooky", horror = "spooky", halloween = "spooky", scary = "spooky",
	graveyard = "spooky", adventure = "pirate", ship = "pirate", treasure = "pirate", sea = "pirate",
	island = "pirate", coaster = "intense", fast = "intense", action = "intense", race = "intense",
	racing = "intense", chase = "intense", boss = "intense", lava = "intense", win = "victory",
	finale = "victory", finish = "victory", celebration = "victory", party = "victory", fireworks = "victory",
	calm = "water", ocean = "water", flume = "water", beach = "water", river = "water", lake = "water",
	pool = "water", swim = "water", underwater = "water",
}

local DEFAULT_VOLUME, DEFAULT_FADE = 0.35, 1.5
local INK, CREAM = Color3.fromRGB(28, 22, 38), Color3.fromRGB(255, 248, 232)
local INFO, BAD = Color3.fromRGB(64, 170, 255), Color3.fromRGB(240, 68, 64)

local byName, moods = {}, {}
for _, t in MusicPlayer.Tracks do
	byName[t.name] = t
	moods[t.mood] = moods[t.mood] or {}
	table.insert(moods[t.mood], t)
end
MusicPlayer.Moods = moods

local cfg = { areas = {}, default = "lobby", volume = DEFAULT_VOLUME, fade = DEFAULT_FADE }
local group: SoundGroup? = nil
local current: Sound? = nil
local leaving: Sound? = nil
local button: TextButton? = nil
local started, muted, area = false, false, nil
local assigned, rotation = {}, {}

local function moodOf(text: string): string?
	local lower = string.lower(text)
	if moods[lower] then
		return lower
	end
	for word in string.gmatch(lower, "%a+") do
		if moods[word] then
			return word
		end
		if ALIASES[word] then
			return ALIASES[word]
		end
	end
	return nil
end

-- Each area keeps one track; areas that share a mood take its tracks in turn.
local function pick(mood: string, key: string)
	if assigned[key] then
		return assigned[key]
	end
	local list = moods[mood]
	local i = rotation[mood] or 1
	rotation[mood] = i % #list + 1
	assigned[key] = list[i]
	return list[i]
end

-- key: a track name, an rbxassetid:// id, a mood, or any text containing a mood word.
local function resolve(key: any, areaKey: string)
	if key == nil then
		return nil
	end
	local s = tostring(key)
	if byName[s] then
		return byName[s]
	end
	if string.match(s, "^rbxassetid://%d+$") then
		return { name = s, id = s, mood = "custom", volume = DEFAULT_VOLUME }
	end
	local mood = moodOf(s)
	return mood and pick(mood, areaKey) or nil
end

local function areaValue(name: any): any
	local v = cfg.areas[name]
	if v == nil then
		v = cfg.areas[tostring(name)]
	end
	if v == nil and tonumber(name) then
		v = cfg.areas[tonumber(name)]
	end
	return v
end

-- Volume fades step on Heartbeat, not TweenService: tweens stall when the client renders no frames (a
-- hidden window), which left the old track playing at full volume. A new fade on the same instance
-- replaces the old one, and its onDone never runs.
local fades = {}
RunService.Heartbeat:Connect(function()
	local now, finished = os.clock(), {}
	for inst, f in fades do
		local a = math.clamp((now - f.t0) / f.seconds, 0, 1)
		inst.Volume = f.from + (f.to - f.from) * a * a * (3 - 2 * a)
		if a >= 1 then
			fades[inst] = nil
			table.insert(finished, f.onDone)
		end
	end
	for _, done in finished do
		done()
	end
end)

local function fade(inst: Instance, volume: number, seconds: number, onDone: (() -> ())?)
	fades[inst] = { from = (inst :: any).Volume, to = volume, t0 = os.clock(), seconds = math.max(seconds, 0.01),
		onDone = onDone or function() end }
end

local function targetVolume(track): number
	return (track.volume or DEFAULT_VOLUME) * cfg.volume / DEFAULT_VOLUME
end

local function fadeOut(s: Sound)
	if leaving and leaving ~= s then
		fades[leaving] = nil
		leaving:Destroy() -- never more than two tracks: the one leaving and the one arriving
	end
	leaving = s
	fade(s, 0, cfg.fade, function()
		if current ~= s then
			if leaving == s then
				leaving = nil
			end
			s:Destroy()
		end
	end)
end

local function switchTo(track)
	if current and current:GetAttribute("Track") == track.name then
		return
	end
	local old = current
	if leaving and leaving:GetAttribute("Track") == track.name then
		current, leaving = leaving, nil -- the track we just left comes back without restarting
		fade(current, targetVolume(track), cfg.fade)
	else
		local s = Instance.new("Sound")
		s.Name = "Music_" .. track.name
		s.SoundId, s.Looped, s.Volume, s.SoundGroup = track.id, true, 0, group
		s:SetAttribute("Track", track.name)
		s:SetAttribute("Mood", track.mood)
		s.Parent = group
		s:Play()
		fade(s, targetVolume(track), cfg.fade)
		current = s
	end
	if old then
		fadeOut(old)
	end
	Players.LocalPlayer:SetAttribute("MusicTrack", track.name)
end

local function styleButton()
	if not button then
		return
	end
	button.Text = if muted then "🔇" else "🎵"
	button.BackgroundColor3 = if muted then BAD else INFO
	local g = button:FindFirstChildOfClass("UIGradient")
	if g then
		local base = button.BackgroundColor3
		g.Color = ColorSequence.new(base:Lerp(Color3.new(1, 1, 1), 0.35), base:Lerp(Color3.new(), 0.12))
	end
end

local function buildButton()
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "MusicToggle", false, 5
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	local shadow = Instance.new("Frame")
	shadow.AnchorPoint, shadow.Size = Vector2.new(1, 0.5), UDim2.fromOffset(54, 54)
	shadow.Position = UDim2.new(1, -14, 0.5, -64)
	shadow.BackgroundColor3, shadow.BackgroundTransparency, shadow.BorderSizePixel = INK, 0.4, 0
	Instance.new("UICorner", shadow).CornerRadius = UDim.new(1, 0)
	shadow.Parent = gui
	local b = Instance.new("TextButton")
	b.Name = "MusicMute"
	b.AnchorPoint, b.Size, b.Position = Vector2.new(1, 0.5), UDim2.fromOffset(54, 54), UDim2.new(1, -14, 0.5, -70)
	b.AutoButtonColor, b.BorderSizePixel, b.TextScaled = false, 0, true
	b.Font, b.TextColor3 = Enum.Font.FredokaOne, CREAM
	Instance.new("UICorner", b).CornerRadius = UDim.new(1, 0)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness, stroke.Color, stroke.ApplyStrokeMode = 3, INK, Enum.ApplyStrokeMode.Border
	stroke.Parent = b
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Parent = b
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0.2, 0), UDim.new(0.2, 0)
	pad.Parent = b
	local scale = Instance.new("UIScale")
	scale.Parent = b
	b.Activated:Connect(function()
		MusicPlayer.toggleMute()
		scale.Scale = 1.25
		TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	end)
	b.Parent = gui
	button = b
	styleButton()
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

-- config: areas {[areaName] = mood | track name | "rbxassetid://..."}, attribute (player attribute to
-- follow, default "Area"), default (mood when no area, "lobby"), volume (0.35), fade (seconds, 1.5),
-- muteButton (true). Moods: carnival, pop, lobby, spooky, pirate, intense, victory, water.
function MusicPlayer.start(config: { [string]: any }?)
	assert(RunService:IsClient(), "MusicPlayer.start runs on the client (a LocalScript)")
	if started then
		return MusicPlayer
	end
	started = true
	config = config or {}
	cfg.areas = config.areas or {}
	cfg.default = config.default or "lobby"
	cfg.volume = config.volume or DEFAULT_VOLUME
	cfg.fade = config.fade or DEFAULT_FADE
	local player = Players.LocalPlayer
	group = SoundService:FindFirstChild("ForgeMusic") :: SoundGroup?
	if not group then
		group = Instance.new("SoundGroup")
		group.Name = "ForgeMusic"
		group.Parent = SoundService
	end
	muted = player:GetAttribute("MusicMuted") == true
	group.Volume = if muted then 0 else 1
	local keys = {}
	for k in cfg.areas do
		table.insert(keys, tostring(k))
	end
	table.sort(keys) -- same area -> track spread on every client
	for _, k in keys do
		local v = areaValue(k)
		local mood = v ~= nil and not byName[tostring(v)] and moodOf(tostring(v))
		if mood then
			pick(mood, k)
		end
	end
	if config.muteButton ~= false then
		buildButton()
	end
	player:GetAttributeChangedSignal("MusicMuted"):Connect(function() -- a settings panel can mute too
		if (player:GetAttribute("MusicMuted") == true) ~= muted then
			MusicPlayer.setMuted(player:GetAttribute("MusicMuted") == true)
		end
	end)
	local attr = config.attribute or "Area"
	player:GetAttributeChangedSignal(attr):Connect(function()
		MusicPlayer.setArea(player:GetAttribute(attr))
	end)
	MusicPlayer.setArea(player:GetAttribute(attr))
	return MusicPlayer
end

-- Switch to an area's music (crossfade). nil -> the default mood.
function MusicPlayer.setArea(name: any)
	area = name
	local track = nil
	if name ~= nil then
		local v = areaValue(name)
		track = resolve(if v ~= nil then v else name, tostring(name))
	end
	track = track or resolve(cfg.default, "default:" .. tostring(cfg.default))
	if track and group then
		switchTo(track)
	end
	Players.LocalPlayer:SetAttribute("MusicArea", if name ~= nil then tostring(name) else nil)
end

-- Play a mood, track name or id now (e.g. "victory" at the finish); the next area change replaces it.
function MusicPlayer.play(key: string)
	local track = resolve(key, "play:" .. tostring(key))
	if track and group then
		switchTo(track)
	end
end

function MusicPlayer.setMuted(on: boolean)
	muted = on == true
	Players.LocalPlayer:SetAttribute("MusicMuted", muted)
	if group then
		fade(group, if muted then 0 else 1, 0.3)
	end
	styleButton()
end

function MusicPlayer.toggleMute()
	MusicPlayer.setMuted(not muted)
end

function MusicPlayer.isMuted(): boolean
	return muted
end

function MusicPlayer.current(): { [string]: any }
	return { area = area, track = current and current:GetAttribute("Track"), muted = muted }
end

return MusicPlayer
