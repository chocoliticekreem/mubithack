--!strict
-- BattlePassService [owner: BattlePass]. The season battle pass: 20 tiers, a free track for everyone and a
-- premium track for Premium Battle Pass owners (MonetizationConfig.GamePasses.PremiumPass; MonetizationService
-- sets Player attr Pass_PremiumPass). Rules are pure in ReplicatedStorage/Lib/BattlePass/PassRules; rewards
-- and tiers in Config/BattlePassConfig; world cosmetics in Lib/BattlePass/PassCosmetics.
--
-- Data: the player profile's `pass` (ProfileSchema v6, DataService: DataStore live, memory in Studio,
--   session-locked). The old BattlePass_S1 store is imported once per player in live games.
-- XP: every TickSeconds of an Active run (workspace.Runs.<InstanceId>.RoundState), fires you put out
--   (FireService.Extinguished), rescues you deliver (RescueService.Delivered), mission end + stars
--   (MissionService.MissionEnded). Premium x PremiumXpMultiplier, claimed boosts add up to BoostCapPct %.
-- Claims: free rewards auto-claim on tier-up; premium ones wait for a Claim / CLAIM ALL press. Claims
--   are idempotent (PassRules.claim). New rewards auto-equip into an empty slot for pass owners.
-- Cosmetics (equipped per slot, saved in the profile): helmet tint on the penguin's helmet, title over
--   the head (+ squad strip / results via attr PassTitle), hose colour (tool + hose line + viewmodel via
--   attrs PassHose/PassHoseStripe), golden nozzle (attr PassNozzle), truck underglow, emote [K].
--
-- Public API (nil-guarded callers):
--   BattlePassService:AwardXp(player, amount, reason?) -> number   -- pass XP actually given
--   BattlePassService:IsPremium(player) -> boolean
--   BattlePassService:GetState(player) -> table?                   -- the State payload below
-- Signals: TierUp(player, tier), XpGained(player, amount, reason)
-- Remotes (BattlePass/*):
--   State   (S->C owner: state table)          Gain (S->C owner: amount, reason, tier, tiersGained, rewardIds)
--   Claimed (S->C owner: { {tier, track, id} }) Fx (S->C all: "emote", userId, style)
--   Request (C->S: "claim", tier, track | "claimAll" | "equip", id | "unequip", slot | "emote" | "state"; 6/s)
-- Writes: Player attrs BattlePassConfig.Attr.* (PassXp, PassTier, PassPremium, PassXpBoost, PassRunXp,
--   PassTitle, PassTitleColor, PassHose, PassHoseStripe, PassNozzle, PassClaimable)
-- Counters: battlepass_xp_awarded, battlepass_tier_up, battlepass_claims, battlepass_equips, battlepass_emotes
-- Test hooks (DevHook only): _award(player, n, reason?), _setXp(player, xp), _state(player) -> JSON,
--   _premium(player, on), _claim(player, tier, track), _equip(player, id), _selftest()
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BattlePassConfig") :: ModuleScript) :: any
local DataConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("DataConfig") :: ModuleScript) :: any
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local PassRules = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("BattlePass"):WaitForChild("PassRules") :: ModuleScript)
local PassCosmetics = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("BattlePass"):WaitForChild("PassCosmetics") :: ModuleScript)

local BattlePassService = {}
BattlePassService.Priority = 50
BattlePassService.TierUp = Signal.new() :: Signal.Signal<Player, number>
BattlePassService.XpGained = Signal.new() :: Signal.Signal<Player, number, string>

type Pass = PassRules.Pass

local services: { [string]: any } = {}
local stateRemote: RemoteEvent? = nil
local gainRemote: RemoteEvent? = nil
local claimedRemote: RemoteEvent? = nil
local fxRemote: RemoteEvent? = nil
local legacyStore: any = nil
local fallback: { [Player]: Pass } = {} -- only when DataService is missing (never in the real game)
local ready: { [Player]: boolean } = {}
local starting: { [Player]: boolean } = {}
local lastEmote: { [Player]: number } = {}

local A = Cfg.Attr

local function opts(): PassRules.Opts
	return {
		perTier = Cfg.XpPerTier,
		maxTier = Cfg.MaxTier,
		tiers = Cfg.Tiers,
		rewards = Cfg.Rewards,
		boostCap = Cfg.BoostCapPct,
	}
end

local function data(): any
	return services.DataService
end

-- The LIVE pass table (inside the profile). nil until the profile loaded.
local function passOf(player: Player): Pass?
	local d = data()
	if d then
		local p = d:GetProfile(player)
		return p and (p :: any).pass
	end
	return fallback[player]
end

-- The only way to change a pass (DataService:Update keeps the profile consistent and saved).
local function mutate(player: Player, fn: (Pass) -> ()): boolean
	local d = data()
	if d then
		return d:Update(player, function(profile: any)
			fn(profile.pass)
		end)
	end
	local p = fallback[player]
	if not p then
		return false
	end
	fn(p)
	return true
end

function BattlePassService:IsPremium(player: Player): boolean
	return player:GetAttribute(Cfg.PremiumAttribute) == true or player:GetAttribute(Cfg.PremiumDebugAttribute) == true
end

local function isPremium(player: Player): boolean
	return BattlePassService:IsPremium(player)
end

local function inMission(player: Player): boolean
	local iid = player:GetAttribute("InstanceId")
	return type(iid) == "string" and iid ~= ""
end

local function reward(id: string?): { [string]: any }?
	if type(id) ~= "string" then
		return nil
	end
	return Cfg.Rewards[id]
end

-- equipped, minus anything you can't use right now (premium lapsed / not yet confirmed this session)
local function effective(player: Player, p: Pass): { [string]: { [string]: any } }
	local owned = PassRules.owned(p, isPremium(player), opts())
	local out: { [string]: { [string]: any } } = {}
	for slot, id in p.equipped do
		local r = reward(id)
		if r and owned[id] and r.Slot == slot then
			out[slot] = r
		end
	end
	return out
end

local function hexColor(v: any): Color3?
	if type(v) ~= "string" then
		return nil
	end
	local ok, c = pcall(Color3.fromHex, v)
	return if ok then c else nil
end

---------------------------------------------------------------------------------- cosmetics

local function applyTools(player: Player, eq: { [string]: { [string]: any } })
	for _, holder in { player:FindFirstChildOfClass("Backpack"), player.Character } do
		if holder then
			local t = holder:FindFirstChild("Hose")
			if t and t:IsA("Tool") then
				pcall(PassCosmetics.tool, t, eq.hose, eq.nozzle)
			end
		end
	end
end

local function applyTruck(player: Player, eq: { [string]: { [string]: any } })
	local trucks = workspace:FindFirstChild("Trucks")
	local truck = trucks and trucks:FindFirstChild(`FireTruck_{player.UserId}`)
	if truck and truck:IsA("Model") then
		pcall(PassCosmetics.truck, truck, eq.truck)
	end
end

local function applyCharacter(player: Player, eq: { [string]: { [string]: any } })
	local char = player.Character
	if not char or not char:FindFirstChild("Costume") then
		return
	end
	pcall(PassCosmetics.helmet, char, eq.helmet)
	pcall(PassCosmetics.title, char, eq.title)
	-- your own title would float in your face in first person (missions); hide it from you there
	local gui = char:FindFirstChild("PassTitle", true)
	if gui and gui:IsA("BillboardGui") then
		gui.PlayerToHideFrom = if inMission(player) then player else nil
	end
end

local function applyAttrs(player: Player, eq: { [string]: { [string]: any } })
	local t = eq.title
	player:SetAttribute(A.Title, if t then t.Name else "")
	player:SetAttribute(A.TitleColor, if t then hexColor(t.Color) else nil)
	player:SetAttribute(A.Hose, if eq.hose then hexColor(eq.hose.Color) else nil)
	player:SetAttribute(A.HoseStripe, if eq.hose then hexColor(eq.hose.Stripe) else nil)
	player:SetAttribute(A.Nozzle, if eq.nozzle then hexColor(eq.nozzle.Color) else nil)
end

local function applyAll(player: Player)
	local p = passOf(player)
	if not p or not player.Parent then
		return
	end
	local eq = effective(player, p)
	applyAttrs(player, eq)
	applyCharacter(player, eq)
	applyTools(player, eq)
	applyTruck(player, eq)
end

---------------------------------------------------------------------------------- state

function BattlePassService:GetState(player: Player): { [string]: any }?
	local p = passOf(player)
	if not p then
		return nil
	end
	local o = opts()
	local prem = isPremium(player)
	local tier, into, need = PassRules.progress(p.xp, o)
	local equipped: { [string]: string } = {}
	for slot in effective(player, p) do
		equipped[slot] = p.equipped[slot]
	end
	return {
		season = Cfg.SeasonId,
		seasonName = Cfg.SeasonName,
		endsAt = Cfg.SeasonEndsAt,
		xp = p.xp,
		tier = tier,
		into = into,
		need = need,
		perTier = o.perTier,
		maxTier = o.maxTier,
		premium = prem,
		free = table.clone(p.free),
		premiumClaimed = table.clone(p.premium),
		equipped = equipped,
		boost = PassRules.boostPct(p, prem, o),
		claimable = PassRules.claimable(p, prem, o),
		runXp = tonumber(player:GetAttribute(A.RunXp)) or 0,
	}
end

local function push(player: Player)
	local s = BattlePassService:GetState(player)
	if not s then
		return
	end
	player:SetAttribute(A.Xp, s.xp)
	player:SetAttribute(A.Tier, s.tier)
	player:SetAttribute(A.Premium, s.premium)
	player:SetAttribute(A.Boost, s.boost)
	player:SetAttribute(A.Claimable, s.claimable)
	if stateRemote then
		stateRemote:FireClient(player, s)
	end
end

-- New rewards drop into an empty slot (everyone has the panel to swap them back).
local function autoEquip(player: Player, p: Pass, ids: { string }): boolean
	local changed = false
	for _, id in ids do
		local r = reward(id)
		if r and r.Slot ~= "boost" and p.equipped[r.Slot] == nil then
			if PassRules.equip(p, id, true, opts()) then
				changed = true
			end
		end
	end
	return changed
end

---------------------------------------------------------------------------------- XP

function BattlePassService:AwardXp(player: Player, amount: number, reason: string?): number
	local p = passOf(player)
	if not p or not ready[player] or type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return 0
	end
	local o = opts()
	local prem = isPremium(player)
	local gain = PassRules.gain(amount, prem, Cfg.PremiumXpMultiplier, PassRules.boostPct(p, prem, o))
	local added, before, after = 0, 0, 0
	local newIds: { string } = {}
	local equippedChanged = false
	mutate(player, function(pass: Pass)
		added, before, after = PassRules.addXp(pass, gain, o)
		if after > before then
			for _, c in PassRules.claimAll(pass, prem, o, true) do
				table.insert(newIds, c.id)
			end
			equippedChanged = autoEquip(player, pass, newIds)
		end
	end)
	if added <= 0 then
		return 0
	end
	local why = reason or "XP"
	Telemetry.count("battlepass_xp_awarded", added)
	player:SetAttribute(A.RunXp, (tonumber(player:GetAttribute(A.RunXp)) or 0) + added)
	BattlePassService.XpGained:Fire(player, added, why)
	if after > before then
		Telemetry.count("battlepass_tier_up", after - before)
		Telemetry.count("battlepass_claims", #newIds)
		BattlePassService.TierUp:Fire(player, after)
	end
	if gainRemote then
		gainRemote:FireClient(player, added, why, after, after - before, newIds)
	end
	push(player)
	if equippedChanged then
		applyAll(player)
	end
	return added
end

---------------------------------------------------------------------------------- requests

local function claimOne(player: Player, tier: any, track: any): boolean
	local o = opts()
	local prem = isPremium(player)
	local ok, why, id = false, nil :: string?, nil :: string?
	local equipped = false
	mutate(player, function(pass: Pass)
		ok, why, id = PassRules.claim(pass, tier, track, prem, o)
		if ok and id then
			equipped = autoEquip(player, pass, { id })
		end
	end)
	if not ok then
		if why == "premium" then
			Net.notify(player, "Premium Battle Pass needed: get it in the STORE", "bad")
		elseif why == "locked" then
			Net.notify(player, `Reach tier {tier} first!`, "bad")
		end
		push(player)
		return false
	end
	Telemetry.count("battlepass_claims")
	local r = reward(id)
	if r then
		Net.notify(player, `Unlocked: {r.Name}!`, "good")
	end
	if claimedRemote then
		claimedRemote:FireClient(player, { { tier = tier, track = string.lower(track), id = id } })
	end
	push(player)
	if equipped then
		applyAll(player)
	end
	return true
end

local function claimAll(player: Player): number
	local made: { PassRules.Claim } = {}
	local equipped = false
	mutate(player, function(pass: Pass)
		made = PassRules.claimAll(pass, isPremium(player), opts())
		local ids = {}
		for _, c in made do
			table.insert(ids, c.id)
		end
		equipped = autoEquip(player, pass, ids)
	end)
	if #made > 0 then
		Telemetry.count("battlepass_claims", #made)
		Net.notify(player, if #made == 1 then `Unlocked: {(reward(made[1].id) or {}).Name or "a reward"}!` else `Unlocked {#made} rewards!`, "good")
		if claimedRemote then
			claimedRemote:FireClient(player, made)
		end
	end
	push(player)
	if equipped then
		applyAll(player)
	end
	return #made
end

local function equip(player: Player, id: any): boolean
	local ok = false
	mutate(player, function(pass: Pass)
		ok = PassRules.equip(pass, id, isPremium(player), opts())
	end)
	if ok then
		Telemetry.count("battlepass_equips")
		applyAll(player)
	end
	push(player)
	return ok
end

local function unequip(player: Player, slot: any): boolean
	local ok = false
	mutate(player, function(pass: Pass)
		ok = PassRules.unequip(pass, slot)
	end)
	if ok then
		applyAll(player)
	end
	push(player)
	return ok
end

local function emote(player: Player)
	local p = passOf(player)
	if not p then
		return
	end
	local r = effective(player, p).emote
	if not r then
		Net.notify(player, "Equip an emote in the Battle Pass locker", "info")
		return
	end
	local now = os.clock()
	if lastEmote[player] and now - lastEmote[player] < (tonumber(Cfg.EmoteCooldown) or 2.5) then
		return
	end
	if player:GetAttribute("Downed") == true then
		return
	end
	lastEmote[player] = now
	Telemetry.count("battlepass_emotes")
	if fxRemote then
		fxRemote:FireAllClients("emote", player.UserId, r.Style or "spin")
	end
end

local function onRequest(player: Player, kind: any, a: any, b: any)
	if not ready[player] then
		return
	end
	if kind == "claim" then
		claimOne(player, a, b)
	elseif kind == "claimAll" then
		claimAll(player)
	elseif kind == "equip" then
		equip(player, a)
	elseif kind == "unequip" then
		unequip(player, a)
	elseif kind == "emote" then
		emote(player)
	elseif kind == "state" then
		push(player)
	end
end

---------------------------------------------------------------------------------- lifecycle

local function importLegacy(player: Player)
	local p = passOf(player)
	if not p or p.legacy or not legacyStore then
		return
	end
	local ok, old = pcall(function()
		return legacyStore:GetAsync(Cfg.SeasonId .. tostring(player.UserId))
	end)
	if not ok or not player.Parent then
		return -- try again next session (legacy stays false)
	end
	mutate(player, function(pass: Pass)
		PassRules.mergeLegacy(pass, old, opts())
	end)
end

local function onProfile(player: Player)
	if ready[player] or starting[player] or not player.Parent then
		return
	end
	starting[player] = true
	local d = data()
	if d then
		d:Update(player, function(profile: any)
			local fresh, reset = PassRules.reconcile(profile.pass, Cfg.SeasonId)
			profile.pass = fresh
			if reset then
				print(`[BattlePassService] {player.Name}: new season {Cfg.SeasonId}, pass reset`)
			end
		end)
	else
		fallback[player] = PassRules.blank(Cfg.SeasonId)
	end
	importLegacy(player)
	-- free rewards for tiers reached earlier (e.g. the legacy import) are claimed now
	mutate(player, function(pass: Pass)
		PassRules.claimAll(pass, isPremium(player), opts(), true)
	end)
	ready[player] = true
	starting[player] = nil
	player:SetAttribute(A.RunXp, 0)
	push(player)
	applyAll(player)
end

local function watchCharacter(player: Player, char: Model)
	char.ChildAdded:Connect(function(c)
		if c.Name == "Costume" then
			task.defer(applyAll, player) -- CostumeBuilder.dress rebuilt the costume
		elseif c:IsA("Tool") and c.Name == "Hose" then
			task.defer(applyAll, player)
		end
	end)
	if char:FindFirstChild("Costume") then
		task.defer(applyAll, player)
	end
end

local function onPlayer(player: Player)
	player.CharacterAdded:Connect(function(char)
		watchCharacter(player, char)
	end)
	if player.Character then
		watchCharacter(player, player.Character)
	end
	task.spawn(function()
		local bp = player:WaitForChild("Backpack", 30)
		if bp then
			bp.ChildAdded:Connect(function(c)
				if c:IsA("Tool") and c.Name == "Hose" then
					task.defer(applyAll, player)
				end
			end)
		end
	end)
	for _, attr in { Cfg.PremiumAttribute, Cfg.PremiumDebugAttribute } do
		player:GetAttributeChangedSignal(attr):Connect(function()
			if ready[player] then
				push(player)
				applyAll(player)
			end
		end)
	end
	player:GetAttributeChangedSignal("InstanceId"):Connect(function()
		if inMission(player) then
			player:SetAttribute(A.RunXp, 0) -- a new run starts counting from zero (Results shows it)
		end
		applyAll(player) -- title visibility (first person on missions)
	end)
	local d = data()
	if d then
		if d:GetProfile(player) then
			task.spawn(onProfile, player)
		end
	else
		task.spawn(onProfile, player)
	end
end

local function inActiveRun(p: Player): boolean
	if workspace:GetAttribute("RoundState") == "Active" then
		return true -- v1 auto-round
	end
	local iid = p:GetAttribute("InstanceId")
	if type(iid) ~= "string" or iid == "" then
		return false
	end
	local runs = workspace:FindFirstChild("Runs")
	local run = runs and runs:FindFirstChild(iid)
	return run ~= nil and run:GetAttribute("RoundState") == "Active"
end

function BattlePassService:Init(all: { [string]: any })
	services = all
end

function BattlePassService:Start()
	stateRemote = Net.event("BattlePass", "State")
	gainRemote = Net.event("BattlePass", "Gain")
	claimedRemote = Net.event("BattlePass", "Claimed")
	fxRemote = Net.event("BattlePass", "Fx")
	Net.onServer(Net.event("BattlePass", "Request"), { rate = 6, burst = 10 }, onRequest)

	-- the old standalone store is only read (once per player) in live games
	local studioMemory = RunService:IsStudio() and DataConfig.UseMemoryInStudio == true
	if not studioMemory then
		local ok, ds = pcall(function()
			return DataStoreService:GetDataStore(Cfg.LegacyStore)
		end)
		legacyStore = if ok then ds else nil
	end

	local d = data()
	if d and d.ProfileLoaded then
		d.ProfileLoaded:Connect(function(player: Player)
			task.spawn(onProfile, player)
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		ready[player] = nil
		starting[player] = nil
		fallback[player] = nil
		lastEmote[player] = nil
	end)

	-- trucks are rebuilt on respawn / bay changes: re-apply the owner's underglow
	task.spawn(function()
		local trucks = workspace:WaitForChild("Trucks", 60)
		if not trucks then
			return
		end
		trucks.ChildAdded:Connect(function(m)
			task.delay(0.5, function()
				local owner = Players:GetPlayerByUserId(tonumber(m:GetAttribute("OwnerUserId")) or 0)
				if owner and ready[owner] then
					applyAll(owner)
				end
			end)
		end)
	end)

	-- XP sources
	local Fire = services.FireService
	if Fire and Fire.Extinguished then
		Fire.Extinguished:Connect(function(_part: BasePart, by: Player?)
			if by then
				BattlePassService:AwardXp(by, Cfg.XpPerFireOut, "Fire out")
			end
		end)
	end
	local Rescue = services.RescueService
	if Rescue and Rescue.Delivered then
		Rescue.Delivered:Connect(function(by: Player)
			BattlePassService:AwardXp(by, Cfg.XpBonusRescue, "Rescue")
		end)
	end
	local Mission = services.MissionService
	if Mission and Mission.MissionEnded then
		Mission.MissionEnded:Connect(function(instanceId: string, payload: any)
			local stars = if type(payload) == "table" then tonumber(payload.stars) or 0 else 0
			local amount = Cfg.XpBonusRoundComplete + stars * Cfg.XpPerStar
			local done: { [Player]: boolean } = {}
			if type(payload) == "table" and type(payload.stats) == "table" then
				for _, st in payload.stats do
					local p = type(st) == "table" and Players:GetPlayerByUserId(tonumber(st.userId) or 0)
					if p then
						done[p] = true
					end
				end
			end
			for _, p in Players:GetPlayers() do
				if p:GetAttribute("InstanceId") == instanceId then
					done[p] = true
				end
			end
			for p in done do
				BattlePassService:AwardXp(p, amount, if stars > 0 then `Mission {string.rep("*", stars)}` else "Mission")
			end
		end)
	end
	task.spawn(function()
		while true do
			task.wait(Cfg.TickSeconds)
			for _, p in Players:GetPlayers() do
				if p.Character and ready[p] and inActiveRun(p) then
					BattlePassService:AwardXp(p, Cfg.XpPerActiveTick, "Active")
				end
			end
		end
	end)
end

---------------------------------------------------------------------------------- test hooks

function BattlePassService:_award(player: Player, n: number, reason: string?): number
	return self:AwardXp(player, n, reason or "Test")
end

function BattlePassService:_setXp(player: Player, xp: number)
	mutate(player, function(pass: Pass)
		pass.xp = math.clamp(math.floor(xp), 0, Cfg.XpPerTier * Cfg.MaxTier)
	end)
	push(player)
end

function BattlePassService:_state(player: Player): string
	return HttpService:JSONEncode(self:GetState(player) or {})
end

function BattlePassService:_premium(player: Player, on: boolean)
	player:SetAttribute(Cfg.PremiumDebugAttribute, if on then true else nil)
end

function BattlePassService:_claim(player: Player, tier: number, track: string): boolean
	return claimOne(player, tier, track)
end

function BattlePassService:_equip(player: Player, id: string): boolean
	return equip(player, id)
end

function BattlePassService:_selftest(): (boolean, string)
	local seen: { [string]: number } = {}
	if #Cfg.Tiers ~= Cfg.MaxTier then
		return false, `{#Cfg.Tiers} tiers but MaxTier {Cfg.MaxTier}`
	end
	for t, row in Cfg.Tiers do
		for _, id in { row.Free, row.Premium } do
			if not Cfg.Rewards[id] then
				return false, `tier {t}: unknown reward {id}`
			end
			if seen[id] then
				return false, `reward {id} used at tiers {seen[id]} and {t}`
			end
			seen[id] = t
		end
	end
	return true, `{Cfg.MaxTier} tiers, {#Players:GetPlayers()} players`
end

return BattlePassService
