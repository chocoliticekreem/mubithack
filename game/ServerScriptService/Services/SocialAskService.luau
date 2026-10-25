--!strict
-- SocialAskService [owner: Social]. Server half of the friendly asks (Controllers/SocialAskController draws
-- them; rules + caps: ReplicatedStorage/Lib/Social/AskRules).
--   * "Having fun? 👍" card: after a HAPPY moment (a call finished with >= 2 stars, or a level up; never
--     the rookie call that only counted because time ran out) the player gets attr LikeAskReady = true. The
--     client opens the card back at the station once the screen is calm, and reports LikeAskShown; only
--     then is it counted: once per session, AskRules.Cfg.MaxEver times ever (profile updates.likeAsks,
--     mirrored to attr LikeAsks). Roblox has no thumbs-up API, so the card points at the 👍 on the game
--     page and offers favorite / notify / invite prompts. NO reward of any kind for any of them.
--   * SocialAsk/Event (C->S, name, source: number, value: number?, kind: number?; 6/s): funnel events
--     through FunnelService:LogCustom. source 1 = like card, 2 = lobby INVITE chip, 3 = results invite line
--     (CustomField01 like | lobby | results). Names: LikeAskShown, LikeAskClosed (value = seconds open;
--     kind 1 = OK, 2 = X / tap outside, 3 = gamepad B -> field like_ok | like_dismiss | like_back),
--     InviteAskShown, InvitePrompted, InviteSent (value = friends invited), FavoritePrompted,
--     FavoriteAccepted, NotifyPrompted. Each name at most AskRules.Cfg.EventCap times per player per session.
-- Counters: like_ask_ready, like_ask_shown, like_ask_closed, invite_ask_shown, invite_prompted,
--   invite_sent, like_favorite_prompted, like_favorite_accepted, like_notify_prompted
-- Consumes (nil-guarded): DataService (:WaitForProfile, :Update), MissionService.MissionEnded, FunnelService
-- Test hooks (DevHook only): _ready(player) (force LikeAskReady past the happy check, still capped),
--   _reset(player) (likeAsks = 0, session cleared), _state(player) -> JSON
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local AskRules = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Social"):WaitForChild("AskRules") :: ModuleScript)
local Schema = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Data"):WaitForChild("ProfileSchema") :: ModuleScript)

local SocialAskService = {}
SocialAskService.Priority = 97 -- after DataService (20), MissionService (60), FunnelService (95)

local Cfg = AskRules.Cfg
local INSTANCE_ATTR: string = (Names.Attr :: any).InstanceId or "InstanceId"
local ATTR_READY = "LikeAskReady"
local ATTR_EVER = "LikeAsks"
local DECIDE_DELAY = 3 -- s after MissionEnded: the call's XP / level up has landed by then

local SOURCES = { "like", "lobby", "results" }
local EVENTS: { [string]: string } = {
	LikeAskShown = "like_ask_shown",
	LikeAskClosed = "like_ask_closed",
	InviteAskShown = "invite_ask_shown",
	InvitePrompted = "invite_prompted",
	InviteSent = "invite_sent",
	FavoritePrompted = "like_favorite_prompted",
	FavoriteAccepted = "like_favorite_accepted",
	NotifyPrompted = "like_notify_prompted",
}

type State = {
	loaded: boolean,
	ever: number,
	askedThisSession: number,
	logged: { [string]: number },
	lastRun: string,
	levelAtStart: number,
	level: number?,
}

local services: { [string]: any } = {}
local states: { [Player]: State } = {}

local function count(name: string)
	pcall(Telemetry.count, name, 1)
end

local function level(player: Player): number?
	return tonumber(player:GetAttribute("Level"))
end

local function inCall(player: Player): boolean
	local id = player:GetAttribute(INSTANCE_ATTR)
	return type(id) == "string" and id ~= ""
end

local function update(player: Player, fn: (any) -> ()): boolean
	local Data = services.DataService
	if not Data or type(Data.Update) ~= "function" then
		return false
	end
	local ok, res = pcall(Data.Update, Data, player, fn)
	return ok and res == true
end

-- a happy moment: offer the card (the client still waits for a calm screen in the lobby)
local function happy(player: Player, s: State, why: string)
	if not AskRules.canAsk(s) or player:GetAttribute(ATTR_READY) == true then
		return
	end
	player:SetAttribute(ATTR_READY, true)
	count("like_ask_ready")
	print(`[SocialAsk] {player.Name} ready ({why})`)
end

local function onMissionEnded(runId: string, payload: any)
	for player, s in states do
		if s.lastRun ~= runId then
			continue
		end
		task.delay(DECIDE_DELAY, function()
			if not player.Parent or states[player] ~= s then
				return
			end
			local lv = level(player) or s.levelAtStart
			if AskRules.happy(payload, player.UserId, lv > s.levelAtStart) then
				happy(player, s, "call")
			end
		end)
	end
end

local function onShown(player: Player, s: State): boolean
	if player:GetAttribute(ATTR_READY) ~= true or not AskRules.canAsk(s) then
		return false
	end
	player:SetAttribute(ATTR_READY, false)
	s.askedThisSession += 1
	s.ever += 1
	player:SetAttribute(ATTR_EVER, s.ever)
	update(player, function(p)
		s.ever = math.max(s.ever, Schema.markLikeAsked(p))
	end)
	return true
end

local CLOSE_KINDS = { "like_ok", "like_dismiss", "like_back" }

-- kind: LikeAskClosed only (1 = OK, 2 = X / tap outside, 3 = gamepad B)
local function onEvent(player: Player, name: any, source: any, value: any, kind: any)
	local s = states[player]
	if not s or type(name) ~= "string" or EVENTS[name] == nil then
		return
	end
	local where = SOURCES[if type(source) == "number" then math.floor(source) else 0]
	if not where then
		return
	end
	local n = (s.logged[name] or 0) + 1
	if n > Cfg.EventCap then
		return
	end
	if name == "LikeAskShown" and (where ~= "like" or not onShown(player, s)) then
		return -- only a card the server offered counts (and is capped)
	end
	s.logged[name] = n
	count(EVENTS[name])
	local v = tonumber(value) or 1
	if v ~= v or v == math.huge or v == -math.huge then
		v = 1
	end
	v = math.clamp(math.floor(v), 0, if name == "LikeAskClosed" then 600 else 50)
	local field = where
	if name == "LikeAskClosed" then
		field = CLOSE_KINDS[if type(kind) == "number" then math.floor(kind) else 0] or "like_ok"
	end
	local Funnel = services.FunnelService
	if Funnel and type(Funnel.LogCustom) == "function" then
		pcall(Funnel.LogCustom, Funnel, player, name, v, field)
	end
end

local function onPlayer(player: Player)
	if states[player] then
		return
	end
	local s: State = {
		loaded = false,
		ever = 0,
		askedThisSession = 0,
		logged = {},
		lastRun = "",
		levelAtStart = level(player) or 1,
		level = level(player),
	}
	states[player] = s
	player:SetAttribute(ATTR_READY, false)
	player:GetAttributeChangedSignal(INSTANCE_ATTR):Connect(function()
		local id = player:GetAttribute(INSTANCE_ATTR)
		if type(id) == "string" and id ~= "" and id ~= s.lastRun then
			s.lastRun = id
			s.levelAtStart = level(player) or s.levelAtStart
		end
	end)
	-- a level up at the station (not on a call: the call's own level up is judged with its results, so a
	-- timed-out rookie call never counts)
	player:GetAttributeChangedSignal("Level"):Connect(function()
		local now = level(player)
		local before = s.level
		s.level = now
		if now and before and now > before and not inCall(player) then
			happy(player, s, "level")
		end
	end)
	task.spawn(function()
		local Data = services.DataService
		local p: any = nil
		if Data and type(Data.WaitForProfile) == "function" then
			local ok, res = pcall(Data.WaitForProfile, Data, player, 30)
			p = if ok then res else nil
		end
		if player.Parent ~= Players or states[player] ~= s then
			return
		end
		local u = type(p) == "table" and type(p.updates) == "table" and p.updates or nil
		s.ever = math.max(s.ever, if u then math.floor(tonumber(u.likeAsks) or 0) else 0)
		-- no profile (DataService down): still allowed, it just isn't remembered across sessions
		s.loaded = true
		s.level = level(player)
		player:SetAttribute(ATTR_EVER, s.ever)
	end)
end

function SocialAskService:Init(all: { [string]: any })
	services = all
end

function SocialAskService:Start()
	local event = Net.event("SocialAsk", "Event")
	Net.onServer(event, { rate = 6, burst = 6 }, onEvent)
	local Mission = services.MissionService
	if Mission and Mission.MissionEnded then
		Mission.MissionEnded:Connect(onMissionEnded)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		states[p] = nil
	end)
end

----------------------------------------------------------------------------------------- test hooks

function SocialAskService:_ready(player: Player): string
	local s = states[player]
	if not s then
		return "no state"
	end
	if not AskRules.canAsk(s) then
		return `capped (session {s.askedThisSession}, ever {s.ever}, loaded {s.loaded})`
	end
	happy(player, s, "test")
	return "ready"
end

function SocialAskService:_reset(player: Player): string
	local s = states[player]
	if not s then
		return "no state"
	end
	s.ever = 0
	s.askedThisSession = 0
	s.logged = {}
	player:SetAttribute(ATTR_EVER, 0)
	player:SetAttribute(ATTR_READY, false)
	update(player, function(p)
		if type(p.updates) == "table" then
			p.updates.likeAsks = 0
		end
	end)
	return "ok"
end

function SocialAskService:_state(player: Player): string
	local s = states[player]
	if not s then
		return "{}"
	end
	return HttpService:JSONEncode({
		loaded = s.loaded,
		ever = s.ever,
		askedThisSession = s.askedThisSession,
		ready = player:GetAttribute(ATTR_READY),
		logged = s.logged,
		lastRun = s.lastRun,
		levelAtStart = s.levelAtStart,
	})
end

return SocialAskService
