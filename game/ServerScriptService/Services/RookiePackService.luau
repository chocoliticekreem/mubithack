--!strict
-- RookiePackService [owner: Retention]. The ROOKIE PACK: a one-time R$49 developer product
-- (Config/RetentionConfig.RookiePack). What you get, all fixed (no random items, no timers to pressure you):
--   * 2x mission XP for BoostMinutes of PLAY time (counts down only while you're in the game; the bonus is
--     added on top of DataService's mission XP through DataService.MissionRecorded)
--   * the Rookie Star Helmet + Rookie Blue Truck Paint (BattlePassConfig.Rewards helmet_rookie / paint_rookie,
--     owned through BattlePassService:GrantExtra, equipped at once, kept across seasons)
-- Offered ONCE (RookiePack.MaxShows) on the results screen of the player's 2nd finished call (AfterCalls):
-- Services/OfferService asks :ShouldOffer and sends it in place of a pass offer, under the same offer caps.
-- ProductId 0 = not created yet: never offered, never prompted, the receipt path never matches.
-- Purchases: MonetizationService's ProcessReceipt (the only ProcessReceipt) calls :Apply for this product id
-- (idempotent per PurchaseId: the global ledger + profile retention.rookie.receipts).
-- Public API (nil-guarded callers):
--   :ShouldOffer(player, rookieCall) -> (boolean, string)   -- RetentionRules.rookieOffer for this player
--   :NoteShown(player)                                       -- the card was drawn (rookie.shows += 1, saved)
--   :Prompt(player) -> boolean                               -- opens the Roblox purchase prompt (id > 0, not bought)
--   :Apply(player, purchaseId) -> "applied" | "duplicate" | "absent"   -- the receipt grant
--   :Price() -> number                                       -- R$ (GetProductInfo, else Config Price)
-- Writes: Player attrs RookieBoostLeft (seconds of 2x XP left; 0 = none), RookiePackOwned (boolean)
-- Analytics (FunnelService:LogCustom): RookiePackBought (value R$; field "offer" | "other")
-- Counters: rookie_pack_prompted, rookie_pack_bought, rookie_pack_bonus_xp
-- Test hooks (DevHook only): _grant(player, purchaseId?) -> string, _state(player) -> JSON,
--   _reset(player) (forget shows / purchase / boost), _boost(player, seconds)
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("RetentionConfig") :: ModuleScript) :: any
local Rules = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Retention"):WaitForChild("RetentionRules") :: ModuleScript)
local Schema = require(game:GetService("ServerScriptService"):WaitForChild("Lib"):WaitForChild("Data"):WaitForChild("ProfileSchema") :: ModuleScript)

local RookiePackService = {}
RookiePackService.Priority = 97 -- after DataService (20), BattlePassService (50), FunnelService (95)

local TICK = 10 -- s between boost countdown steps
local ATTR_BOOST = "RookieBoostLeft"
local ATTR_OWNED = "RookiePackOwned"

local services: { [string]: any } = {}
local price: number? = nil
local clickedAt: { [Player]: number } = {}

local function count(name: string, n: number?)
	pcall(Telemetry.count, name, n or 1)
end

local function P(): any
	return Cfg.RookiePack
end

local function profileOf(player: Player): any
	local Data = services.DataService
	return Data and type(Data.GetProfile) == "function" and Data:GetProfile(player) or nil
end

local function rookieOf(player: Player): any
	local p = profileOf(player)
	local r = p and p.retention
	return r and r.rookie
end

local function update(player: Player, fn: (any) -> ()): boolean
	local Data = services.DataService
	if not Data or type(Data.Update) ~= "function" then
		return false
	end
	local ok, res = pcall(Data.Update, Data, player, function(p: any)
		if type(p.retention) ~= "table" or type(p.retention.rookie) ~= "table" then
			return
		end
		fn(p.retention.rookie)
	end)
	return ok and res == true
end

local function setAttrs(player: Player)
	local r = rookieOf(player)
	player:SetAttribute(ATTR_BOOST, if r then r.boostLeft else 0)
	player:SetAttribute(ATTR_OWNED, r ~= nil and r.bought == true)
end

local function grantCosmetics(player: Player, equip: boolean)
	local BP = services.BattlePassService
	if BP and type(BP.GrantExtra) == "function" then
		local ok, err = pcall(BP.GrantExtra, BP, player, { P().Helmet, P().Paint }, equip)
		if not ok then
			warn(`[RookiePackService] cosmetics for {player.Name}: {err}`)
		end
	end
end

function RookiePackService:Price(): number
	return price or tonumber(P().Price) or 49
end

function RookiePackService:ShouldOffer(player: Player, rookieCall: boolean): (boolean, string)
	local p = profileOf(player)
	local r = p and p.retention and p.retention.rookie
	if not p or not r then
		return false, "no profile"
	end
	return Rules.rookieOffer({
		productId = tonumber(P().ProductId) or 0,
		bought = r.bought,
		shows = r.shows,
		maxShows = P().MaxShows,
		missionsPlayed = p.missionsPlayed,
		afterCalls = P().AfterCalls,
		firstCallDone = player:GetAttribute("FirstCallDone") ~= false,
		rookieCall = rookieCall,
	})
end

function RookiePackService:NoteShown(player: Player)
	update(player, function(r: any)
		r.shows += 1
	end)
	local Data = services.DataService
	if Data and type(Data.Save) == "function" then
		task.spawn(pcall, Data.Save, Data, player)
	end
end

function RookiePackService:Prompt(player: Player): boolean
	local id = tonumber(P().ProductId) or 0
	local r = rookieOf(player)
	if id <= 0 or not r or r.bought then
		return false
	end
	clickedAt[player] = os.clock()
	count("rookie_pack_prompted")
	local ok, err = pcall(MarketplaceService.PromptProductPurchase, MarketplaceService, player, id)
	if not ok then
		warn(`[RookiePackService] prompt: {err}`)
	end
	return ok
end

-- The receipt grant (MonetizationService ProcessReceipt). Must be idempotent per purchaseId.
function RookiePackService:Apply(player: Player?, purchaseId: string): string
	if not player or player.Parent ~= Players then
		return "absent"
	end
	local Data = services.DataService
	if not Data or type(Data.WaitForProfile) ~= "function" or not Data:WaitForProfile(player, 10) then
		return "absent"
	end
	local result = "absent"
	local okU = Data:Update(player, function(p: any)
		if not Schema.addRookieReceipt(p, purchaseId) then
			result = "duplicate"
			return
		end
		local r = Schema.retention(p).rookie
		r.bought = true
		r.boostLeft = math.min(r.boostLeft + math.floor((tonumber(P().BoostMinutes) or 30) * 60), 24 * 3600)
		result = "applied"
	end)
	if not okU then
		return "absent"
	end
	if result == "applied" then
		grantCosmetics(player, true)
		setAttrs(player)
		count("rookie_pack_bought")
		local fromOffer = clickedAt[player] ~= nil and os.clock() - (clickedAt[player] :: number) < 600
		local F = services.FunnelService
		if F and type(F.LogCustom) == "function" then
			pcall(F.LogCustom, F, player, "RookiePackBought", RookiePackService:Price(), if fromOffer then "offer" else "other")
		end
		Net.notify(player, "ROOKIE PACK! 2x XP for 30 min + Rookie Star Helmet + Rookie Blue Truck Paint!", "good")
		print(`[RookiePackService] {player.Name}: ROOKIE PACK applied ({purchaseId})`)
	end
	return result
end

-- 2x XP: the same XP again on top of a recorded mission while the boost runs
local function onMissionRecorded(player: Player, _missionId: string, summary: any)
	local r = rookieOf(player)
	if not r or (r.boostLeft or 0) <= 0 or type(summary) ~= "table" then
		return
	end
	local bonus = math.floor((tonumber(summary.xp) or 0) * math.max(0, (tonumber(P().XpMultiplier) or 2) - 1))
	local Data = services.DataService
	if bonus > 0 and Data and type(Data.AddXp) == "function" then
		pcall(Data.AddXp, Data, player, bonus, "Rookie Pack 2x XP")
		count("rookie_pack_bonus_xp", bonus)
	end
end

local function tick()
	for _, player in Players:GetPlayers() do
		local r = rookieOf(player)
		if r and (r.boostLeft or 0) > 0 then
			update(player, function(rk: any)
				rk.boostLeft = Rules.boostLeft(rk.boostLeft, TICK)
			end)
			setAttrs(player)
		end
	end
end

local function onProfile(player: Player)
	local r = rookieOf(player)
	if r and r.bought then
		-- the pass may have loaded after the purchase (or a new season): idempotent, never re-equips
		task.delay(3, grantCosmetics, player, false)
	end
	setAttrs(player)
end

function RookiePackService:Init(all: { [string]: any })
	services = all
end

function RookiePackService:Start()
	local Data = services.DataService
	if Data then
		if Data.MissionRecorded then
			Data.MissionRecorded:Connect(onMissionRecorded)
		end
		if Data.ProfileLoaded then
			Data.ProfileLoaded:Connect(onProfile)
		end
		for _, p in Players:GetPlayers() do
			if profileOf(p) then
				task.spawn(onProfile, p)
			end
		end
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		clickedAt[p] = nil
	end)
	task.spawn(function()
		local id = tonumber(P().ProductId) or 0
		if id > 0 then
			local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, id, Enum.InfoType.Product)
			if ok and type(info) == "table" and type((info :: any).PriceInRobux) == "number" then
				price = (info :: any).PriceInRobux
			end
		end
	end)
	task.spawn(function()
		while true do
			task.wait(TICK)
			local ok, err = pcall(tick)
			if not ok then
				warn(`[RookiePackService] tick: {err}`)
			end
		end
	end)
end

------------------------------------------------------------------------------------------ test hooks

function RookiePackService:_grant(player: Player, purchaseId: string?): string
	return RookiePackService:Apply(player, purchaseId or HttpService:GenerateGUID(false))
end

function RookiePackService:_state(player: Player): string
	local should, why = RookiePackService:ShouldOffer(player, false)
	local p = profileOf(player)
	return HttpService:JSONEncode({
		rookie = rookieOf(player),
		missionsPlayed = p and p.missionsPlayed,
		shouldOffer = should,
		why = why,
		boostAttr = player:GetAttribute(ATTR_BOOST),
	})
end

function RookiePackService:_reset(player: Player): boolean
	local ok = update(player, function(r: any)
		r.shows = 0
		r.bought = false
		r.boostLeft = 0
		r.receipts = {}
	end)
	setAttrs(player)
	return ok
end

function RookiePackService:_boost(player: Player, seconds: number): boolean
	local ok = update(player, function(r: any)
		r.boostLeft = math.max(0, math.floor(seconds))
	end)
	setAttrs(player)
	return ok
end

return RookiePackService
