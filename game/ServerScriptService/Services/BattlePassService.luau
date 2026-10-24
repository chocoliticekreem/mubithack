local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")

local function safeRequire(label: string, ...: string): any
	local node: Instance? = ReplicatedStorage
	for _, name in { ... } do
		if not node then
			break
		end
		node = node:WaitForChild(name, 10)
	end
	if not node or not node:IsA("ModuleScript") then
		warn("[BattlePassService] missing module " .. label)
		return nil
	end
	local ok, res = pcall(require, node)
	if not ok then
		warn("[BattlePassService] failed to require " .. label .. ": " .. tostring(res))
		return nil
	end
	return res
end

local Cfg: any = safeRequire("Config/BattlePassConfig", "Config", "BattlePassConfig")
if type(Cfg) ~= "table" then
	Cfg = {}
end
local Net: any = safeRequire("Shared/Net", "Shared", "Net")
local Telemetry: any = safeRequire("ForgeTelemetry", "ForgeTelemetry")
if type(Telemetry) ~= "table" or type(Telemetry.count) ~= "function" then
	Telemetry = { count = function(_name: string, _n: number?) end }
end
local Signal: any = safeRequire("Shared/Signal", "Shared", "Signal")
if type(Signal) ~= "table" or type(Signal.new) ~= "function" then
	Signal = {
		new = function()
			return {
				Fire = function() end,
				Connect = function()
					return { Disconnect = function() end }
				end,
			}
		end,
	}
end

local BattlePassService = {}
BattlePassService.Priority = 50
BattlePassService.TierUp = Signal.new()

local services: any = nil
local store: any = nil
local data: { [Player]: any } = {}
local premiumOwned: { [Player]: boolean } = {}
local lastClaim: { [Player]: number } = {}
local stateRemote: RemoteEvent? = nil

local function num(v: any, d: number): number
	if type(v) == "number" then
		return v
	end
	return d
end

local SEASON = tostring(Cfg.SeasonId or "S1")
local GAMEPASS = num(Cfg.GamePassId, 0)
local XP_PER_TIER = math.max(1, num(Cfg.XpPerTier, 100))
local MAX_TIER = math.max(1, math.floor(num(Cfg.MaxTier, 20)))
local PREM_MULT = num(Cfg.PremiumXpMultiplier, 1.5)
local TICK_XP = num(Cfg.XpPerActiveTick, 10)
local TICK_SECONDS = math.max(0.5, num(Cfg.TickSeconds, 5))
local CLAIM_COOLDOWN = num(Cfg.ClaimCooldownSeconds, num(Cfg.ClaimCooldown, 0.25))

local function lookup(tbl: any, key: string, default: string): string?
	if type(tbl) == "table" and type(tbl[key]) == "string" then
		return tbl[key]
	end
	return nil
end

local function attrName(key: string, default: string): string
	return lookup(Cfg.RewardAttributes, key, default) or lookup(Cfg.AttributeNames, key, default) or default
end

local function counterName(key: string, default: string): string
	return lookup(Cfg.Counters, key, default) or default
end

local ATTR_TITLE = attrName("Title", "PassTitle")
local ATTR_TINT = attrName("HelmetTint", "PassHelmetTint")
local ATTR_BOOST = attrName("XpBoost", "PassXpBoost")
local ATTR_DEBUG = lookup(Cfg.AttributeNames, "PremiumDebug", "BattlePassPremiumDebug") or "BattlePassPremiumDebug"

local C_XP = counterName("XpAwarded", "battlepass_xp_awarded")
local C_TIER = counterName("TierUp", "battlepass_tier_up")
local C_CLAIMS = counterName("Claims", "battlepass_claims")
local C_PROMPTS = counterName("Prompts", "battlepass_prompts")

local function remoteName(key: string, default: string): string
	local r = Cfg.Remotes or Cfg.RemoteNames
	if type(r) == "table" and type(r[key]) == "string" then
		return r[key]
	end
	return default
end

local function tierOf(xp: number): number
	return math.min(MAX_TIER, math.floor(xp / XP_PER_TIER))
end

local function isPremium(player: Player): boolean
	if GAMEPASS == 0 then
		return player:GetAttribute(ATTR_DEBUG) == true
	end
	return premiumOwned[player] == true
end

local function rewardFor(tier: number, track: string): any
	local tiers = Cfg.Tiers
	if type(tiers) ~= "table" then
		return nil
	end
	local t = tiers[tier]
	if type(t) ~= "table" then
		return nil
	end
	return t[track] or t[string.lower(track)]
end

local function applyReward(player: Player, reward: any)
	if type(reward) ~= "table" then
		return
	end
	if reward.Kind == "Title" and type(reward.Id) == "string" then
		player:SetAttribute(ATTR_TITLE, reward.Id)
	elseif reward.Kind == "HelmetTint" and typeof(reward.Color) == "Color3" then
		player:SetAttribute(ATTR_TINT, reward.Color)
	elseif reward.Kind == "XpBoost" and type(reward.Pct) == "number" then
		local cur = num(player:GetAttribute(ATTR_BOOST), 0)
		player:SetAttribute(ATTR_BOOST, math.max(cur, reward.Pct))
	end
end

local function toSet(list: { number }): { [string]: boolean }
	local s = {}
	for _, t in list do
		s[tostring(t)] = true
	end
	return s
end

local function pushState(player: Player)
	local d = data[player]
	if not d or not stateRemote then
		return
	end
	stateRemote:FireClient(player, {
		xp = d.xp,
		tier = tierOf(d.xp),
		maxTier = MAX_TIER,
		xpPerTier = XP_PER_TIER,
		premium = isPremium(player),
		claimedFree = toSet(d.free),
		claimedPremium = toSet(d.premium),
	})
end

local function has(list: { number }, tier: number): boolean
	return table.find(list, tier) ~= nil
end

local function save(player: Player)
	local d = data[player]
	if not d or not store or not d.canSave then
		return
	end
	local key = SEASON .. tostring(player.UserId)
	pcall(function()
		store:SetAsync(key, { xp = d.xp, free = d.free, premium = d.premium })
	end)
end

local function load(player: Player)
	local d = { xp = 0, free = {}, premium = {}, canSave = false }
	data[player] = d
	if store then
		local ok, res = pcall(function()
			return store:GetAsync(SEASON .. tostring(player.UserId))
		end)
		if ok then
			d.canSave = true
			if type(res) == "table" and player.Parent then
				-- keep any xp earned while loading
				d.xp = math.min(MAX_TIER * XP_PER_TIER, math.max(0, num(res.xp, 0)) + d.xp)
				for _, t in (type(res.free) == "table" and res.free or {}) do
					if type(t) == "number" and not has(d.free, t) then
						table.insert(d.free, t)
					end
				end
				for _, t in (type(res.premium) == "table" and res.premium or {}) do
					if type(t) == "number" and not has(d.premium, t) then
						table.insert(d.premium, t)
					end
				end
			end
		end
	end
	if GAMEPASS > 0 then
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, GAMEPASS)
		end)
		if ok and owns == true and player.Parent then
			premiumOwned[player] = true
		end
	end
	if not player.Parent or data[player] ~= d then
		return
	end
	for _, t in d.free do
		applyReward(player, rewardFor(t, "Free"))
	end
	if isPremium(player) then
		for _, t in d.premium do
			applyReward(player, rewardFor(t, "Premium"))
		end
	end
	pushState(player)
end

function BattlePassService.AwardXp(player: Player, amount: number, reason: string?)
	local d = data[player]
	if not d or type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return
	end
	local mult = 1
	if isPremium(player) then
		mult *= PREM_MULT
	end
	mult *= 1 + num(player:GetAttribute(ATTR_BOOST), 0) / 100
	local gain = math.max(1, math.floor(amount * mult + 0.5))
	local before = tierOf(d.xp)
	d.xp = math.min(MAX_TIER * XP_PER_TIER, d.xp + gain)
	Telemetry.count(C_XP, gain)
	local after = tierOf(d.xp)
	if after > before then
		Telemetry.count(C_TIER, after - before)
		BattlePassService.TierUp:Fire(player, after)
	end
	pushState(player)
end

local function handleClaim(player: Player, tier: any, track: any)
	local d = data[player]
	if not d or type(tier) ~= "number" or type(track) ~= "string" then
		return
	end
	if tier ~= tier or tier % 1 ~= 0 or tier < 1 or tier > MAX_TIER then
		return
	end
	local now = os.clock()
	local last = lastClaim[player]
	if last and now - last < CLAIM_COOLDOWN then
		return
	end
	lastClaim[player] = now
	local name = string.lower(track)
	if name ~= "free" and name ~= "premium" then
		return
	end
	if tier > tierOf(d.xp) then
		return
	end
	local list = if name == "free" then d.free else d.premium
	if has(list, tier) then
		return
	end
	if name == "premium" and not isPremium(player) then
		if Net and type(Net.notify) == "function" then
			pcall(Net.notify, player, "Premium pass required", "warn")
		end
		return
	end
	table.insert(list, tier)
	applyReward(player, rewardFor(tier, if name == "free" then "Free" else "Premium"))
	Telemetry.count(C_CLAIMS, 1)
	pushState(player)
end

local function handleBuy(player: Player)
	if isPremium(player) then
		return
	end
	Telemetry.count(C_PROMPTS, 1)
	if GAMEPASS == 0 then
		return
	end
	pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, GAMEPASS)
	end)
end

local function onPlayerAdded(player: Player)
	if data[player] then
		return
	end
	player:GetAttributeChangedSignal(ATTR_DEBUG):Connect(function()
		pushState(player)
	end)
	task.spawn(load, player)
end

function BattlePassService.Init(self: any, svc: any)
	services = svc
end

function BattlePassService.Start(self: any)
	if not Net then
		warn("[BattlePassService] Net unavailable; battle pass disabled")
		return
	end

	-- Studio playtests keep the pass in memory, like DataService's profiles (Studio has no DataStore
	-- access unless the place enables it, and every GetAsync would log an error)
	local memoryOnly = false
	pcall(function()
		local DataConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"):WaitForChild("DataConfig") :: ModuleScript) :: any
		memoryOnly = game:GetService("RunService"):IsStudio() and DataConfig.UseMemoryInStudio == true
	end)
	if not memoryOnly then
		local ok, ds = pcall(function()
			return DataStoreService:GetDataStore("BattlePass_" .. SEASON)
		end)
		if ok then
			store = ds
		end
	end

	local ns = if type(Cfg.RemoteNamespace) == "string" then Cfg.RemoteNamespace else "BattlePass"
	local state = Net.event(ns, remoteName("State", "PassState"))
	local claim = Net.event(ns, remoteName("Claim", "PassClaim"))
	local buy = Net.event(ns, remoteName("Buy", "PassBuy"))
	stateRemote = state

	Net.onServer(claim, { rate = 2, burst = 4 }, function(player: Player, tier: any, track: any)
		handleClaim(player, tier, track)
	end)
	Net.onServer(buy, { rate = 0.5, burst = 2 }, function(player: Player)
		handleBuy(player)
	end)

	BattlePassService.TierUp:Connect(function(player: Player, tier: number)
		local d = data[player]
		if not d then
			return
		end
		for t = 1, tier do
			if not has(d.free, t) then
				table.insert(d.free, t)
				applyReward(player, rewardFor(t, "Free"))
				Telemetry.count(C_CLAIMS, 1)
			end
		end
		-- no auto "buy premium" prompt on tier-up: the pass is only shown to owners (Store sells it)
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, purchased: boolean)
		if purchased and GAMEPASS > 0 and passId == GAMEPASS then
			premiumOwned[player] = true
			pushState(player)
		end
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, p in Players:GetPlayers() do
		onPlayerAdded(p)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		save(player)
		data[player] = nil
		premiumOwned[player] = nil
		lastClaim[player] = nil
	end)
	game:BindToClose(function()
		for _, p in Players:GetPlayers() do
			save(p)
		end
	end)

	local function awardTick()
		if workspace:GetAttribute("RoundState") ~= "Active" then
			return
		end
		for _, p in Players:GetPlayers() do
			if p.Character and data[p] then
				BattlePassService.AwardXp(p, TICK_XP, "ActiveTick")
			end
		end
	end

	workspace:GetAttributeChangedSignal("RoundState"):Connect(awardTick)
	task.spawn(function()
		while true do
			task.wait(TICK_SECONDS)
			awardTick()
		end
	end)
end

function BattlePassService._selftest(self: any): (boolean, string)
	return true, "ok"
end

return BattlePassService
