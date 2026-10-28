--!strict
-- OfferService [owner: Monetization]. Well-timed, honest game pass offers + their conversion analytics.
-- Decides server side (pure rules: Lib/Monetization/OfferRules, caps in MonetizationConfig.Offers):
--   * results: after a finished call (MissionService.MissionEnded, DecideDelay s later so the XP / level /
--     pass XP of that call have landed): every ResultsEvery-th non-rookie call this session, one pass the
--     player doesn't own and that is on sale. Relevant first: foam ran out -> Unlimited Foam; a big fire
--     (firesOut + burnedParts >= Offers.BigFire) -> Helicopter ("WANT A FIRE HELICOPTER?"); levelled up /
--     rescued RescueHero+ / earned pass XP -> Premium Pass; else rotate. ResultsController draws the card
--     (ClientLib/OfferCard) beside NEXT CALL, never in its way.
--   * lobby: back at the station after a call that levelled you up, when no results offer was shown for
--     it (MinGapSeconds), once per session: OfferController's small corner card.
--   Caps: MaxPerSession offers, MinGapSeconds apart, MaxDeclines "No thanks" per pass, never a rookie call.
--   * ROOKIE PACK (Services/RookiePackService, Config/RetentionConfig.RookiePack): on the results of the player's
--     2nd finished call ever (and later results if the caps blocked it), ONCE ever, in place of a pass offer and
--     under the same MaxPerSession / MinGapSeconds caps (not ResultsEvery: call 2 may be the session's 1st
--     non-rookie call). Key "RookiePack" (field "RookiePack_results"); BUY opens the developer product prompt.
--     ProductId 0 = never offered.
-- "For sale" = a configured id whose GetProductInfo says IsForSale (checked once per server; an
-- unanswered check counts as for sale, the purchase prompt itself is the final word).
-- Remotes: Monetization/Offer   (S->C owner: { id, key, reason, moment, price, headline, short })
--          Monetization/OfferAct (C->S: action "shown" | "buy" | "no", id: number; 2/s burst 4)
-- Analytics (FunnelService:LogCustom, CustomField01 = "<Key>_<moment>"): OfferShown, OfferClicked,
--   OfferDeclined, OfferPurchased (bought within ClickWindow of its BUY; value = R$), PassPurchased
--   (every pass bought; field "<Key>_offer" | "<Key>_store"; value = R$).
-- Counters: offer_sent, offer_shown, offer_clicked, offer_declined, offer_purchased
-- Consumes (nil-guarded): MissionService.MissionEnded, MonetizationService (:Owns, :PromptPass),
--   FunnelService (:LogCustom)
-- Test hooks (DevHook only): _offer(player, moment?, reason?) -> string (force an offer past the caps),
--   _bought(player, key) (the purchase-finished analytics), _state(player) -> JSON
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MonetizationConfig") :: ModuleScript) :: any
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local Lib = ServerScriptService:WaitForChild("Lib"):WaitForChild("Monetization")
local MRules = require(Lib:WaitForChild("MonetizationRules") :: ModuleScript)
local Rules = require(Lib:WaitForChild("OfferRules") :: ModuleScript)

local OfferService = {}
OfferService.Priority = 96 -- after MonetizationService (60), MissionService (60), FunnelService (95)

local O = Cfg.Offers
local RetentionConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("RetentionConfig") :: ModuleScript) :: any
local ROOKIE_KEY = "RookiePack"
local INSTANCE_ATTR: string = (Names.Attr :: any).InstanceId or "InstanceId"

type Pending = { id: number, key: string, moment: string, shownAt: number? }
type State = {
	completed: number, -- non-rookie calls finished this session
	shown: number,
	lobbyShown: number,
	lastShown: number, -- os.clock() of the last shown offer (-inf = none)
	declined: { [string]: number },
	rotation: number,
	nextId: number,
	pending: Pending?,
	clicked: { [string]: { at: number, moment: string } },
	-- this run's signals
	foamEmpty: boolean,
	levelAtStart: number,
	levelUpUnoffered: boolean, -- the last call levelled you up and no offer was shown for it
	lastRun: string,
}

local services: { [string]: any } = {}
local states: { [Player]: State } = {}
local forSale: { [string]: boolean } = {} -- nil = not checked yet / no answer (counts as for sale)
local prices: { [string]: number } = {}
local offerRemote: RemoteEvent? = nil

local function count(name: string)
	pcall(Telemetry.count, name, 1)
end

local function log(player: Player, event: string, value: number, field: string)
	local F = services.FunnelService
	if F and type(F.LogCustom) == "function" then
		pcall(F.LogCustom, F, player, event, value, field)
	end
end

local function defOf(key: string): any
	for _, d in Cfg.Passes do
		if d.key == key then
			return d
		end
	end
	return nil
end

local function priceOf(key: string): number
	local d = defOf(key)
	return prices[key] or (d and tonumber(d.price)) or 0
end

local function level(player: Player): number
	return tonumber(player:GetAttribute("Level")) or 1
end

local function owns(player: Player, key: string): boolean
	local M = services.MonetizationService
	if M and type(M.Owns) == "function" then
		local ok, res = pcall(M.Owns, M, player, key)
		if ok then
			return res == true
		end
	end
	return player:GetAttribute(Cfg.Attr.PassPrefix .. key) == true
end

local function passList(player: Player): { Rules.Pass }
	local out = {}
	for _, d in Cfg.Passes do
		local id = MRules.passId(Cfg.GamePasses, d.key)
		table.insert(out, { key = d.key, forSale = id > 0 and forSale[d.key] ~= false, owned = owns(player, d.key) })
	end
	return out
end

local function checkForSale()
	for _, d in Cfg.Passes do
		local id = MRules.passId(Cfg.GamePasses, d.key)
		if id == 0 then
			forSale[d.key] = false
			continue
		end
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(id, Enum.InfoType.GamePass)
		end)
		if ok and type(info) == "table" then
			local i = info :: any
			if i.IsForSale == false then
				forSale[d.key] = false
			end
			if type(i.PriceInRobux) == "number" then
				prices[d.key] = i.PriceInRobux
			end
		end
	end
end

local function send(player: Player, s: State, key: string, reason: string, moment: string): string
	local r = offerRemote
	if not r then
		return "no remote"
	end
	if player:GetAttribute("FirstCallDone") == false then
		return "first call not done" -- Onboarding v3: no offer before a newbie's first call is complete
	end
	s.nextId += 1
	s.pending = { id = s.nextId, key = key, moment = moment }
	local heads = O.Headlines[key] or {}
	local d = defOf(key) or {}
	count("offer_sent")
	r:FireClient(player, {
		id = s.nextId,
		key = key,
		reason = reason,
		moment = moment,
		price = priceOf(key),
		headline = heads[reason] or heads.default or d.name or key,
		short = O.Short[key] or d.blurb or "",
	})
	return `sent {key} ({reason}, {moment})`
end

-- the ROOKIE PACK instead of a pass offer on this results screen? (its own once-ever rule + the session caps)
local function tryRookie(player: Player, s: State, rookie: boolean): boolean
	local RP = services.RookiePackService
	if not RP or type(RP.ShouldOffer) ~= "function" or rookie then
		return false
	end
	if s.shown >= (tonumber(O.MaxPerSession) or 4) or os.clock() - s.lastShown < (tonumber(O.MinGapSeconds) or 150) then
		return false
	end
	local ok, should = pcall(RP.ShouldOffer, RP, player, rookie)
	if not ok or not should then
		return false
	end
	local r = offerRemote
	if not r or player:GetAttribute("FirstCallDone") == false then
		return false
	end
	local P = RetentionConfig.RookiePack
	s.nextId += 1
	s.pending = { id = s.nextId, key = ROOKIE_KEY, moment = "results" }
	count("offer_sent")
	r:FireClient(player, {
		id = s.nextId,
		key = ROOKIE_KEY,
		reason = "rookie",
		moment = "results",
		price = RP:Price(),
		headline = P.Headline,
		short = P.Short,
		name = P.Name,
		icon = P.Icon,
		color = P.Color,
	})
	return true
end

local function ctxFor(player: Player, s: State, moment: string, signals: Rules.Signals, rookie: boolean): Rules.Ctx
	return {
		moment = moment,
		passes = passList(player),
		rookie = rookie,
		completed = s.completed,
		shown = s.shown,
		lobbyShown = s.lobbyShown,
		sinceLast = os.clock() - s.lastShown,
		declined = s.declined,
		rotation = s.rotation,
		signals = signals,
	}
end

local function rescuedBy(payload: any, userId: number): number
	if type(payload) == "table" and type(payload.stats) == "table" then
		for _, st in payload.stats do
			if type(st) == "table" and st.userId == userId then
				return tonumber(st.rescued) or 0
			end
		end
	end
	return 0
end

local function onMissionEnded(runId: string, payload: any)
	local rookie = type(payload) == "table" and payload.rookie == true
	for player, s in states do
		if s.lastRun ~= runId then
			continue
		end
		task.delay(tonumber(O.DecideDelay) or 2.5, function()
			if not player.Parent or states[player] ~= s then
				return
			end
			if not rookie then
				s.completed += 1
			end
			local levelUp = level(player) > s.levelAtStart
			local big = 0
			if type(payload) == "table" then
				big = (tonumber(payload.firesOut) or 0) + (tonumber(payload.burnedParts) or 0)
			end
			local signals = {
				foamEmpty = s.foamEmpty,
				rescued = rescuedBy(payload, player.UserId),
				levelUp = levelUp,
				passXp = tonumber(player:GetAttribute("PassRunXp")) or 0,
				bigFire = big >= (tonumber(O.BigFire) or 12),
			}
			if tryRookie(player, s, rookie) then
				s.levelUpUnoffered = false
				return
			end
			local key, reason = Rules.pick(ctxFor(player, s, "results", signals, rookie), O)
			-- the lobby card may pick up a level up the results screen didn't use
			s.levelUpUnoffered = levelUp and key == nil and not rookie
			if key and reason then
				send(player, s, key, reason, "results")
			end
		end)
	end
end

local function onBackInLobby(player: Player, s: State)
	if not s.levelUpUnoffered then
		return
	end
	s.levelUpUnoffered = false
	task.delay(4, function() -- let the lobby (and any NEW GEAR card) settle first
		if not player.Parent or states[player] ~= s or player:GetAttribute(INSTANCE_ATTR) ~= "" then
			return
		end
		local key, reason = Rules.pick(ctxFor(player, s, "lobby", { levelUp = true }, false), O)
		if key and reason then
			send(player, s, key, reason, "lobby")
		end
	end)
end

local function onAct(player: Player, action: any, id: any)
	local s = states[player]
	local p = s and s.pending
	if not s or not p or type(id) ~= "number" or p.id ~= id then
		return
	end
	local field = Rules.field(p.key, p.moment)
	if action == "shown" then
		if p.shownAt then
			return
		end
		p.shownAt = os.clock()
		s.shown += 1
		s.lastShown = os.clock()
		s.rotation += 1
		if p.moment == "lobby" then
			s.lobbyShown += 1
		end
		count("offer_shown")
		log(player, "OfferShown", 1, field)
		if p.key == ROOKIE_KEY then
			local RP = services.RookiePackService
			if RP and type(RP.NoteShown) == "function" then
				RP:NoteShown(player)
			end
		end
	elseif action == "buy" then
		s.pending = nil
		s.clicked[p.key] = { at = os.clock(), moment = p.moment }
		count("offer_clicked")
		log(player, "OfferClicked", 1, field)
		local M = services.MonetizationService
		local RP = services.RookiePackService
		if p.key == ROOKIE_KEY then
			if RP and type(RP.Prompt) == "function" then
				RP:Prompt(player)
			end
		elseif M and type(M.PromptPass) == "function" then
			M:PromptPass(player, p.key)
		end
	elseif action == "no" then
		s.pending = nil
		s.declined[p.key] = (s.declined[p.key] or 0) + 1
		count("offer_declined")
		log(player, "OfferDeclined", 1, field)
	end
end

local function onPurchaseFinished(player: Player, passId: number, purchased: boolean)
	local key = MRules.passKey(Cfg.GamePasses, passId)
	local s = states[player]
	if not key or not purchased or not s then
		return
	end
	local c = s.clicked[key]
	local fromOffer = c ~= nil and os.clock() - c.at <= (tonumber(O.ClickWindow) or 600)
	local price = priceOf(key)
	if fromOffer and c then
		count("offer_purchased")
		log(player, "OfferPurchased", price, Rules.field(key, c.moment))
	end
	s.clicked[key] = nil
	log(player, "PassPurchased", price, `{key}_{if fromOffer then "offer" else "store"}`)
end

local function onPlayer(player: Player)
	if states[player] then
		return
	end
	local s: State = {
		completed = 0,
		shown = 0,
		lobbyShown = 0,
		lastShown = -math.huge,
		declined = {},
		rotation = player.UserId % 2, -- half the players see the other pass first
		nextId = 0,
		pending = nil,
		clicked = {},
		foamEmpty = false,
		levelAtStart = level(player),
		levelUpUnoffered = false,
		lastRun = "",
	}
	states[player] = s
	player:GetAttributeChangedSignal(INSTANCE_ATTR):Connect(function()
		local id = player:GetAttribute(INSTANCE_ATTR)
		if type(id) == "string" and id ~= "" then
			if id ~= s.lastRun then
				s.lastRun = id
				s.foamEmpty = false
				s.levelAtStart = level(player)
			end
		elseif s.lastRun ~= "" then
			onBackInLobby(player, s)
		end
	end)
	player:GetAttributeChangedSignal("Foam"):Connect(function()
		local f = player:GetAttribute("Foam")
		local id = player:GetAttribute(INSTANCE_ATTR)
		if type(f) == "number" and f <= 0 and type(id) == "string" and id ~= "" then
			s.foamEmpty = true
		end
	end)
end

function OfferService:Init(all: { [string]: any })
	services = all
end

function OfferService:Start()
	offerRemote = Net.event("Monetization", "Offer")
	local act = Net.event("Monetization", "OfferAct")
	Net.onServer(act, { rate = 2, burst = 4 }, onAct)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onPurchaseFinished)
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
	task.spawn(checkForSale)
end

------------------------------------------------------------------------------------------ test hooks

-- Studio: force an offer (skips the caps, still never an owned / unsold pass).
function OfferService:_offer(player: Player, moment: string?, reason: string?): string
	local s = states[player]
	if not s then
		return "no state"
	end
	if reason == "rookie" then -- Studio: the ROOKIE PACK card itself (even with ProductId 0: BUY then does nothing)
		local r = offerRemote
		if not r then
			return "no remote"
		end
		local P = RetentionConfig.RookiePack
		s.nextId += 1
		s.pending = { id = s.nextId, key = ROOKIE_KEY, moment = moment or "results" }
		r:FireClient(player, { id = s.nextId, key = ROOKIE_KEY, reason = "rookie", moment = moment or "results", price = P.Price,
			headline = P.Headline, short = P.Short, name = P.Name, icon = P.Icon, color = P.Color })
		return "sent RookiePack (test)"
	end
	local list = Rules.candidates(ctxFor(player, s, moment or "results", {}, false), O)
	if #list == 0 then
		return "nothing to offer (all owned / not for sale)"
	end
	local key = list[(s.rotation % #list) + 1]
	if reason == "foam" and table.find(list, "UnlimitedFoam") then
		key = "UnlimitedFoam"
	elseif (reason == "level" or reason == "rescue" or reason == "passxp") and table.find(list, "PremiumPass") then
		key = "PremiumPass"
	elseif reason == "bigfire" and table.find(list, "Helicopter") then
		key = "Helicopter"
	end
	return send(player, s, key, reason or "default", moment or "results")
end

-- Studio: the "pass bought" path (MarketplaceService.PromptGamePassPurchaseFinished can't be faked).
function OfferService:_bought(player: Player, key: string): string
	onPurchaseFinished(player, MRules.passId(Cfg.GamePasses, key), true)
	return "ok"
end

function OfferService:_state(player: Player): string
	local s = states[player]
	if not s then
		return "{}"
	end
	return HttpService:JSONEncode({
		completed = s.completed,
		shown = s.shown,
		lobbyShown = s.lobbyShown,
		sinceLast = if s.lastShown == -math.huge then -1 else math.floor(os.clock() - s.lastShown),
		declined = s.declined,
		rotation = s.rotation,
		pending = if s.pending then s.pending.key else nil,
		foamEmpty = s.foamEmpty,
		levelUpUnoffered = s.levelUpUnoffered,
		forSale = forSale,
	})
end

return OfferService
