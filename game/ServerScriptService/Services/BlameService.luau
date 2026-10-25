--!strict
-- BlameService [owner: G3]. The per-round ledger behind the Blame screen. Listens to every gameplay signal,
-- keeps one stats row per player (Types.PlayerStats + ledger extras, see Lib/Blame/Awards), turns them into
-- awards with Lib/Blame/Awards and shouts funny kill-feed callouts ("02 hosed 03 into a pool!") as
-- small Shared/Popup world text over the victim (or actor), for players near it (was a squad-wide toast).
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   BlameService:GetStats(player: Player): Types.PlayerStats
--   BlameService:BuildAwards(): { Types.Award }       -- players currently in the server (v1 single round)
--   BlameService:Reset()                              -- MissionService calls it at StartRound
-- v1.5 additions (parallel instances; additive, nothing above changed):
--   BlameService:BuildAwardsFor(players: { Player }): { Types.Award }   -- one squad / instance
--   BlameService:ResetPlayers(players: { Player })                       -- clears just those rows
--   (also auto-resets a squad's rows on MissionService.MissionStarted and everyone on RoundStarted)
-- Consumes (in Start, each nil-guarded):
--   FireService.Extinguished(part, by)      -> by.firesOut += 1
--   FireService.Spread(from, to)            -> nearest in-round player within ArsonRadius of `to`: firesStarted += 1
--   ToolService.WaterUsed(player, litres)   -> water += litres
--   ToolService.DoorBroken(player, door)    -> doors += 1                                    (+ callout)
--   ToolService.HoseHit(sprayer, victim)    -> sprayer.teammateSprayed, victim.hosedBy (1/s per pair) (+ callout)
--   RescueService.Rescued(player, id, kind) -> rescued (+ pandas / cats / dogs)
--   RescueService.Dropped(player, id)       -> drops                                          (+ callout)
--   SquadService.Downed(victim, cause, culprit) -> victim.timesDowned; culprit.downedOthers    (+ callout)
--   HeatService.Overheated(player)          -> overheats                                      (+ callout)
--   HazardService.Zapped(victim, culprit)   -> victim.zapped; culprit.zappedOthers           (+ callout)
--   HazardService.Flung(victim, "explosion")-> victim.explosions (was nearest)                (+ callout)
--   Player attrs: Carrying ~= "" -> carrySeconds
--   HazardService.Caused(culprit, "backdraft") -> culprit.backdraftsCaused
--   RescueService.Thrown(player, id)        -> yeets
--   HandsService.Slapped(slapper, victim)   -> pairs["slap:<victim>"]
-- Per-pair tallies for the results' BLAME OF THE CALL card (StarterPlayerScripts/Lib/BlameOfCall): row.pairs =
-- { ["hose:<victimUserId>"] = n, ["down:..."], ["zap:..."], ["slap:..."] } on the actor's row (sent in stats).
-- Counters: blame_callouts, awards_built
-- Test hooks (DevHook only): _bump(player, field, n), _callout(event, actor, victim?), _selftest()
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Types = require(Shared:WaitForChild("Types") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local BlameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BlameConfig") :: ModuleScript) :: any
local Awards = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Blame"):WaitForChild("Awards") :: ModuleScript)

local BlameService = {}
BlameService.Priority = 70

-- Ledger extras beyond Types.PlayerStats (Awards reads missing ones as 0).
local EXTRAS = {
	"hosedBy",
	"drops",
	"cats",
	"dogs",
	"overheats",
	"zapped",
	"zappedOthers",
	"explosions",
	"revives",
	"carrySeconds",
	"backdraftsCaused",
	"yeets",
}

local services: { [string]: any } = {}
local ledger: { [number]: { [string]: any } } = {}
local lastSaid: { [string]: number } = {}
local lastHoseCount: { [string]: number } = {}
local calloutRoll = 0
local started = false

local function helmetOf(player: Player): number
	local Squad = services.SquadService
	if Squad then
		local ok, n = pcall(Squad.GetHelmet, Squad, player)
		if ok and type(n) == "number" then
			return n
		end
	end
	return (player:GetAttribute(Names.Attr.Helmet) :: number?) or 1
end

local function scopeOf(player: Player): string
	local id = player:GetAttribute(Names.Attr.InstanceId)
	return if type(id) == "string" then id else ""
end

-- In a round? v1: Workspace RoundState; v1.5: the player's instance Model RoundState.
local function inRound(player: Player): boolean
	local id = scopeOf(player)
	if id ~= "" then
		local folder = workspace:FindFirstChild("Instances")
		local inst = folder and folder:FindFirstChild(id)
		local st = inst and inst:GetAttribute(Names.Attr.RoundState)
		return st == nil or st == "Active"
	end
	return workspace:GetAttribute(Names.Attr.RoundState) == "Active"
end

local function entry(player: Player): { [string]: any }
	local s = ledger[player.UserId]
	if not s then
		local row: { [string]: any } = {
			userId = player.UserId,
			helmet = helmetOf(player),
			name = player.DisplayName,
			firesOut = 0,
			firesStarted = 0,
			water = 0,
			doors = 0,
			rescued = 0,
			pandas = 0,
			downedOthers = 0,
			timesDowned = 0,
			teammateSprayed = 0,
		}
		for _, f in EXTRAS do
			row[f] = 0
		end
		row.pairs = {}
		ledger[player.UserId] = row
		return row
	end
	return s
end

local function isPlayer(p: any): boolean
	return typeof(p) == "Instance" and (p :: Instance):IsA("Player") and (p :: Player).Parent == Players
end

local function bump(player: any, field: string, n: number?)
	if not isPlayer(player) then
		return
	end
	local s = entry(player :: Player)
	if type(s[field]) ~= "number" then
		warn(`[BlameService] unknown stat {field}`)
		return
	end
	s[field] += (n or 1)
end

-- actor did `kind` to victim (one more time): BLAME OF THE CALL's "Bob sprayed Alice 3 times"
local function pair(actor: any, kind: string, victim: any)
	if not isPlayer(actor) or not isPlayer(victim) or actor == victim then
		return
	end
	local row = entry(actor :: Player)
	local key = `{kind}:{(victim :: Player).UserId}`
	row.pairs[key] = (row.pairs[key] or 0) + 1
end

local function callout(event: string, actor: Player, victim: Player?)
	if not BlameConfig.KillFeed or not isPlayer(actor) then
		return
	end
	local key = `{event}:{actor.UserId}:{if victim then victim.UserId else 0}`
	local now = os.clock()
	if lastSaid[key] and now - lastSaid[key] < BlameConfig.KillFeedRepeatSeconds then
		return
	end
	lastSaid[key] = now
	calloutRoll += 1
	local text = Awards.callout(event, helmetOf(actor), if victim then helmetOf(victim) else nil, calloutRoll)
	-- small world text over the victim (or the actor), only for players near it (Shared/Popup)
	Popup.show(victim or actor, text, "blame", actor)
	Telemetry.count("blame_callouts")
end

local function nearestPlayer(pos: Vector3, radius: number): Player?
	local best: Player? = nil
	local bestD = radius
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local d = (root.Position - pos).Magnitude
			if d <= bestD then
				best, bestD = player, d
			end
		end
	end
	return best
end

local function connect(svc: any, signalName: string, fn: (...any) -> ())
	local sig = svc and svc[signalName]
	if type(sig) == "table" and type(sig.Connect) == "function" then
		sig:Connect(function(...)
			local ok, err = pcall(fn, ...)
			if not ok then
				warn(`[BlameService] {signalName}: {err}`)
			end
		end)
	end
end

function BlameService:Init(all: { [string]: any })
	services = all
end

function BlameService:Start()
	if started then
		return
	end
	started = true
	local Fire = services.FireService
	connect(Fire, "Extinguished", function(_part: BasePart, by: Player?)
		bump(by, "firesOut")
	end)
	connect(Fire, "Spread", function(_from: BasePart, to: BasePart)
		local p = nearestPlayer(to.Position, BlameConfig.ArsonRadius)
		if p and inRound(p) then
			bump(p, "firesStarted")
			local n = entry(p).firesStarted
			if n == 3 or n % 8 == 0 then
				callout("spread", p, nil)
			end
		end
	end)

	local Tool = services.ToolService
	connect(Tool, "WaterUsed", function(player: Player, litres: number)
		if type(litres) == "number" and litres > 0 then
			bump(player, "water", litres)
		end
	end)
	connect(Tool, "DoorBroken", function(player: Player, _door: BasePart)
		bump(player, "doors")
		callout("door", player, nil)
	end)
	connect(Tool, "HoseHit", function(sprayer: Player, victim: Player)
		if sprayer == victim or not isPlayer(sprayer) or not isPlayer(victim) then
			return
		end
		-- HoseHit can fire every spray tick; count at most once per second per pair
		local key = `{sprayer.UserId}:{victim.UserId}`
		local now = os.clock()
		if lastHoseCount[key] and now - lastHoseCount[key] < 1 then
			return
		end
		lastHoseCount[key] = now
		bump(sprayer, "teammateSprayed")
		bump(victim, "hosedBy")
		pair(sprayer, "hose", victim)
		callout("hose", sprayer, victim)
	end)

	local Rescue = services.RescueService
	connect(Rescue, "Rescued", function(player: Player, _id: string, kind: string)
		bump(player, "rescued")
		if kind == "Panda" then
			bump(player, "pandas")
		elseif kind == "Cat" then
			bump(player, "cats")
		elseif kind == "Dog" then
			bump(player, "dogs")
		end
	end)
	connect(Rescue, "Thrown", function(player: Player, _id: string)
		bump(player, "yeets")
	end)
	connect(Rescue, "Dropped", function(player: Player, _id: string)
		bump(player, "drops")
		callout("drop", player, nil)
	end)

	local Squad = services.SquadService
	connect(Squad, "Downed", function(victim: Player, _cause: string, culprit: Player?)
		bump(victim, "timesDowned")
		if culprit and culprit ~= victim and isPlayer(culprit) then
			bump(culprit, "downedOthers")
			pair(culprit, "down", victim)
			callout("down", culprit, victim)
		end
	end)

	connect(services.HeatService, "Overheated", function(player: Player)
		bump(player, "overheats")
		callout("overheat", player, nil)
	end)

	local Hazard = services.HazardService
	connect(Hazard, "Zapped", function(victim: Player, culprit: Player?)
		bump(victim, "zapped")
		if culprit and culprit ~= victim and isPlayer(culprit) then
			bump(culprit, "zappedOthers")
			pair(culprit, "zap", victim)
			callout("zap", culprit, victim)
		end
	end)
	connect(Hazard, "Caused", function(culprit: Player?, hazardId: string)
		if hazardId == "backdraft" then
			bump(culprit, "backdraftsCaused")
		end
	end)
	connect(services.HandsService, "Slapped", function(slapper: Player, victim: Player?)
		pair(slapper, "slap", victim)
	end)
	connect(Hazard, "Flung", function(victim: Player, hazardId: string)
		if hazardId == "explosion" then
			bump(victim, "explosions")
			callout("boom", victim, nil)
		end
	end)

	-- new round / mission: fresh ledger rows
	local Mission = services.MissionService
	connect(Mission, "RoundStarted", function(_locationId: string)
		BlameService:Reset()
	end)
	connect(Mission, "MissionStarted", function(instanceId: string, _missionId: string)
		task.defer(function()
			local squad = {}
			for _, p in Players:GetPlayers() do
				if scopeOf(p) == instanceId then
					table.insert(squad, p)
				end
			end
			BlameService:ResetPlayers(squad)
		end)
	end)

	task.spawn(function()
		while true do
			local dt = math.max(0.25, tonumber(BlameConfig.CarryTickSeconds) or 1)
			task.wait(dt)
			for _, p in Players:GetPlayers() do
				local c = p:GetAttribute(Names.Attr.Carrying)
				if type(c) == "string" and c ~= "" and inRound(p) then
					bump(p, "carrySeconds", dt)
				end
			end
		end
	end)
end

function BlameService:GetStats(player: Player): Types.PlayerStats
	local s = table.clone(entry(player))
	s.pairs = table.clone(s.pairs or {})
	s.helmet = helmetOf(player)
	s.name = player.DisplayName
	s.water = math.floor(s.water)
	s.carrySeconds = math.floor(s.carrySeconds or 0)
	return s :: any
end

function BlameService:BuildAwardsFor(players: { Player }): { Types.Award }
	local list = {}
	for _, player in players do
		if isPlayer(player) then
			table.insert(list, self:GetStats(player))
		end
	end
	Telemetry.count("awards_built")
	return Awards.build(list :: any, BlameConfig.MaxAwardsPerPlayer) :: any
end

function BlameService:BuildAwards(): { Types.Award }
	return self:BuildAwardsFor(Players:GetPlayers())
end

function BlameService:Reset()
	table.clear(ledger)
	table.clear(lastSaid)
	table.clear(lastHoseCount)
end

function BlameService:ResetPlayers(players: { Player })
	for _, p in players do
		if typeof(p) == "Instance" and p:IsA("Player") then
			ledger[p.UserId] = nil
		end
	end
end

-- test hooks -------------------------------------------------------------------------------
function BlameService:_bump(player: Player, field: string, n: number?)
	bump(player, field, n)
end

function BlameService:_callout(event: string, actor: Player, victim: Player?)
	lastSaid = {}
	callout(event, actor, victim)
end

function BlameService:_selftest(): (boolean, string)
	if #Awards.build({}, BlameConfig.MaxAwardsPerPlayer) ~= 0 then
		return false, "Awards.build({}) should be empty"
	end
	local fake = {
		userId = 1,
		helmet = 1,
		name = "t",
		firesOut = 0,
		firesStarted = 0,
		water = 0,
		doors = 0,
		rescued = 0,
		pandas = 1,
		downedOthers = 0,
		timesDowned = 0,
		teammateSprayed = 0,
	}
	local list = Awards.build({ fake } :: any, BlameConfig.MaxAwardsPerPlayer)
	if #list ~= 2 or list[1].id ~= "panda" or list[2].id ~= "scapegoat" then
		return false, "panda award pipeline broken"
	end
	local wired = 0
	for _, name in { "FireService", "ToolService", "RescueService", "SquadService", "HeatService", "HazardService" } do
		if services[name] then
			wired += 1
		end
	end
	return true, `{#Awards.catalog()} awards, {wired}/6 sources`
end

return BlameService
