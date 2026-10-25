--!strict
-- TeamBonusService [owner: Social]. "10x more fun with friends" (Tizyz rule #3) in the core loop. Every
-- bonus only ADDS on top of solo play; the numbers live in ReplicatedStorage/Lib/Social/TeamRules (pure).
--   COMBO!    FireService.Combo: 2+ hoses on one fire -> each hose cools x comboMult (FireService does the
--             maths); here: a big "COMBO! x1.5" pop for every hose, world text over the fire, ComboXp each
--             (per-player cooldown + per-call cap) and a combo tally for the results screen.
--   TEAMWORK! RescueService.Rescued: the rescue counts as teamwork when another squadmate (same InstanceId)
--             walked with the carrier (RescueService.Escorted, which also makes the carry faster), carried
--             it too, or was spraying fire near the carrier while the carry was on ("cleared the path").
--             Rescuer + helpers get the pop, TeamworkXp and a teamwork tally. One player still carries alone.
--   STREAK    MissionService.MissionEnded: calls finished (1+ star) in a row with the same 2+ players.
--             Player attr SquadStreak; from 2 up a "SQUAD STREAK x3!" pop + StreakXp x min(streak, cap).
--   RESULTS   on MissionEnded (2+ players) sends the squad its rows { userId, name, rescued, firesOut, combos,
--             teamwork }, the BEST TEAMMATE (TeamRules.best) and the streak; TeamBonusController draws them
--             as two cards on the results screen. Solo calls send nothing (the screen is unchanged).
--
-- Public API:  TeamBonusService:GetRunStats(instanceId): { [number]: { combos: number, teamwork: number } }
-- Remotes: Social/Bonus (S->C one: kind "combo"|"teamwork"|"streak", info { mult?, with: { string }, xp,
--            streak? }), Social/Squad (S->C squad: { instanceId, rows, best: userId?, streak })
-- Consumes (nil-guarded): FireService.Combo/.Doused, RescueService.Picked/.Escorted/.Delivered/.Rescued,
--   MissionService.MissionEnded, DataService:AddXp
-- Writes: Player attr SquadStreak (number). Counters: team_combos, team_teamwork, team_streaks
-- Test hooks (DevHook only): _combo(userIds?), _teamwork(userIds?), _ended(instanceId, won), _state()
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local TeamRules = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Social"):WaitForChild("TeamRules") :: ModuleScript)

local Cfg = TeamRules.Cfg

local TeamBonusService = {}
TeamBonusService.Priority = 70

type Tally = { combos: number, teamwork: number, comboXp: number }

local services: { [string]: any } = {}
local bonusRemote: RemoteEvent? = nil
local squadRemote: RemoteEvent? = nil
local runStats: { [string]: { [number]: Tally } } = {} -- instanceId -> userId -> tally
local comboXpAt: { [Player]: number } = {}
local lastSpray: { [Player]: { t: number, pos: Vector3 } } = {}
local carryStart: { [string]: number } = {} -- rescueId -> os.clock() of the first pick-up
local helpers: { [string]: { [Player]: boolean } } = {} -- rescueId -> escorts / co-carriers
local streak: { [number]: { n: number, key: string? } } = {}

local function runOf(p: Player): string
	local v = p:GetAttribute(Names.Attr.InstanceId)
	return if type(v) == "string" then v else ""
end

local function tally(p: Player): Tally?
	local run = runOf(p)
	if run == "" then
		return nil
	end
	local byUser = runStats[run] or {}
	runStats[run] = byUser
	local t = byUser[p.UserId] or { combos = 0, teamwork = 0, comboXp = 0 }
	byUser[p.UserId] = t
	return t
end

local function addXp(p: Player, amount: number, reason: string): number
	local Data = services.DataService
	if amount <= 0 or not Data or type(Data.AddXp) ~= "function" then
		return 0
	end
	local ok, got = pcall(Data.AddXp, Data, p, amount, reason)
	return if ok and type(got) == "number" then got else 0
end

local function send(p: Player, kind: string, info: { [string]: any })
	if bonusRemote and p.Parent == Players then
		bonusRemote:FireClient(p, kind, info)
	end
end

local function othersNames(list: { Player }, me: Player): { string }
	local out = {}
	for _, o in list do
		if o ~= me then
			table.insert(out, o.DisplayName)
		end
	end
	return out
end

local function rootPos(p: Player): Vector3?
	local char = p.Character
	local r = char and char:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r.Position else nil
end

------------------------------------------------------------------------------------------ COMBO

local function onCombo(part: BasePart?, hoses: { Player }, mult: number)
	Telemetry.count("team_combos")
	if part and part.Parent then
		Popup.show(part, `COMBO! x{mult}`, "good", hoses[1])
	end
	local now = os.clock()
	for _, p in hoses do
		local t = tally(p)
		if t then
			t.combos += 1
		end
		local xp = 0
		if now - (comboXpAt[p] or -math.huge) >= Cfg.ComboXpCooldown and (not t or t.comboXp < Cfg.ComboXpPerRun) then
			comboXpAt[p] = now
			xp = addXp(p, Cfg.ComboXp, "Combo")
			if t then
				t.comboXp += xp
			end
		end
		send(p, "combo", { mult = mult, with = othersNames(hoses, p), xp = xp })
	end
end

---------------------------------------------------------------------------------------- TEAMWORK

local function onRescued(who: Player, rescueId: string)
	local run = runOf(who)
	local set = helpers[rescueId] or {}
	local started = carryStart[rescueId]
	helpers[rescueId] = nil
	carryStart[rescueId] = nil
	if run == "" then
		return
	end
	-- "cleared the path": a squadmate sprayed fire near the carrier while the carry was on
	local at = rootPos(who)
	if started and at then
		for p, s in lastSpray do
			if p ~= who and p.Parent == Players and runOf(p) == run and s.t >= started and (s.pos - at).Magnitude <= Cfg.ClearPathRadius then
				set[p] = true
			end
		end
	end
	local team: { Player } = { who }
	for p in set do
		if p ~= who and p.Parent == Players and runOf(p) == run then
			table.insert(team, p)
		end
	end
	if #team < 2 then
		return
	end
	Telemetry.count("team_teamwork")
	for _, p in team do
		local t = tally(p)
		if t then
			t.teamwork += 1
		end
		local xp = addXp(p, Cfg.TeamworkXp, "Teamwork")
		send(p, "teamwork", { with = othersNames(team, p), xp = xp })
	end
end

------------------------------------------------------------------------------------ STREAK + RESULTS

local function onMissionEnded(instanceId: string, payload: any)
	local byUser = runStats[instanceId] or {}
	runStats[instanceId] = nil
	if type(payload) ~= "table" or type(payload.stats) ~= "table" then
		return
	end
	local ids: { number } = {}
	local rows: { TeamRules.Row } = {}
	for _, s in payload.stats do
		if type(s) == "table" and type(s.userId) == "number" then
			local t = byUser[s.userId]
			table.insert(ids, s.userId)
			table.insert(rows, {
				userId = s.userId,
				name = tostring(s.name or ""),
				rescued = tonumber(s.rescued) or 0,
				firesOut = tonumber(s.firesOut) or 0,
				combos = if t then t.combos else 0,
				teamwork = if t then t.teamwork else 0,
			})
		end
	end
	local won = (tonumber(payload.stars) or 0) >= 1
	local key = TeamRules.squadKey(ids)
	local squadStreak = math.huge
	for _, id in ids do
		local st = streak[id] or { n = 0, key = nil }
		local n = if #ids >= 2 then TeamRules.nextStreak(st.n, st.key, key, won) else 0
		streak[id] = { n = n, key = if #ids >= 2 then key else nil }
		squadStreak = math.min(squadStreak, n)
		local p = Players:GetPlayerByUserId(id)
		if p then
			p:SetAttribute("SquadStreak", n)
		end
	end
	if #ids < 2 then
		return -- solo call: the results screen stays as it was
	end
	if squadStreak == math.huge then
		squadStreak = 0
	end
	local best = TeamRules.best(rows)
	local members: { Player } = {}
	for _, id in ids do
		local p = Players:GetPlayerByUserId(id)
		if p then
			table.insert(members, p)
		end
	end
	if squadRemote then
		for _, p in members do
			squadRemote:FireClient(p, { instanceId = instanceId, rows = rows, best = best, streak = squadStreak })
		end
	end
	if squadStreak >= 2 then
		Telemetry.count("team_streaks")
		for _, p in members do
			local xp = addXp(p, Cfg.StreakXp * math.min(squadStreak, Cfg.StreakXpCap), "Squad streak")
			send(p, "streak", { streak = squadStreak, with = othersNames(members, p), xp = xp })
		end
	end
end

------------------------------------------------------------------------------------------- API

function TeamBonusService:GetRunStats(instanceId: string): { [number]: { combos: number, teamwork: number } }
	return (runStats[instanceId] or {}) :: any
end

function TeamBonusService:Init(all: { [string]: any })
	services = all
end

function TeamBonusService:Start()
	bonusRemote = Net.event("Social", "Bonus")
	squadRemote = Net.event("Social", "Squad")
	local Fire = services.FireService
	if Fire then
		if Fire.Combo then
			Fire.Combo:Connect(onCombo)
		end
		if Fire.Doused then
			Fire.Doused:Connect(function(p: Player)
				local pos = rootPos(p)
				if pos then
					lastSpray[p] = { t = os.clock(), pos = pos }
				end
			end)
		end
	end
	local Rescue = services.RescueService
	if Rescue then
		if Rescue.Picked then
			Rescue.Picked:Connect(function(_p: Player, id: string)
				carryStart[id] = carryStart[id] or os.clock()
			end)
		end
		if Rescue.Escorted then
			Rescue.Escorted:Connect(function(helper: Player, _carrier: Player, id: string)
				local set = helpers[id] or {}
				helpers[id] = set
				set[helper] = true
			end)
		end
		if Rescue.Delivered then
			-- co-carriers (the panda pair): Delivered fires for each carrier right after Rescued
			Rescue.Delivered:Connect(function(p: Player, id: string)
				local set = helpers[id]
				if set then
					set[p] = true
				end
			end)
		end
		if Rescue.Rescued then
			Rescue.Rescued:Connect(function(who: Player, id: string)
				local set = helpers[id] or {}
				helpers[id] = set
				task.defer(onRescued, who, id) -- after the Delivered signals for co-carriers
			end)
		end
	end
	local Mission = services.MissionService
	if Mission and Mission.MissionEnded then
		Mission.MissionEnded:Connect(function(instanceId: string, payload: any)
			local ok, err = pcall(onMissionEnded, instanceId, payload)
			if not ok then
				warn(`[TeamBonusService] results: {err}`)
			end
		end)
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		comboXpAt[p] = nil
		lastSpray[p] = nil
	end)
end

-------------------------------------------------------------------------------------- test hooks

local function pick(userIds: { number }?): { Player }
	local out = {}
	for _, p in Players:GetPlayers() do
		if not userIds or table.find(userIds, p.UserId) then
			table.insert(out, p)
		end
	end
	return out
end

function TeamBonusService:_combo(userIds: { number }?): number
	local list = pick(userIds)
	onCombo(nil, list, TeamRules.comboMult(#list))
	return #list
end

function TeamBonusService:_teamwork(userIds: { number }?): number
	local list = pick(userIds)
	if #list == 0 then
		return 0
	end
	local id = `_test{os.clock()}`
	helpers[id] = {}
	carryStart[id] = os.clock()
	for i = 2, #list do
		helpers[id][list[i]] = true
	end
	onRescued(list[1], id)
	return #list
end

function TeamBonusService:_ended(instanceId: string, won: boolean): string
	local stats = {}
	for _, p in Players:GetPlayers() do
		if runOf(p) == instanceId or instanceId == "*" then
			table.insert(stats, { userId = p.UserId, name = p.DisplayName, rescued = 1, firesOut = 2 })
		end
	end
	onMissionEnded(instanceId, { stars = if won then 2 else 0, stats = stats })
	return `{#stats} rows`
end

function TeamBonusService:_state(): string
	local out = {}
	for run, byUser in runStats do
		for id, t in byUser do
			table.insert(out, `{run}/{id}: combos={t.combos} teamwork={t.teamwork} xp={t.comboXp}`)
		end
	end
	for id, st in streak do
		table.insert(out, `streak {id}={st.n}`)
	end
	return table.concat(out, "; ")
end

return TeamBonusService
