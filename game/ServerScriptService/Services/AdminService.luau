--!strict
-- AdminService [owner: Admin]. Our own Kohl's-style admin system (no external MainModule): ranks, chat
-- commands (":fly me"), the staff console (AdminController, ";" key) and the server command log.
-- Every command is parsed and rank-checked HERE; the client only sends text. No command runs code.
--
-- Ranks: Lib/Admin/AdminRules.rankOf with AdminConfig (creator / Owners / Admins / Mods / group ranks /
--   Studio dev override / Studio-only AdminRankDebug test attribute / SAVED grants).
-- Saved ranks: :admin (Owner) / :mod / :unadmin / :setrank (Admin+; AdminRules.canGrant) and the console's
--   PLAYERS list write DataStore AdminConfig.RankStore, key "staff" = { [UserId] = { rank, name, by, at } }
--   (UpdateAsync; memory in Studio / when DataService isn't persistent). A grant overrides the config lists
--   and sticks across servers and rejoins; other servers re-read it on a MessagingService ping
--   (AdminConfig.RankTopic) and every RankRefreshSeconds. Targets may be offline (name or #UserId).
--   :admins lists everyone with a rank, online or not.
-- Trolls (group Troll, def.troll): TrollService:Run per target. Can't troll a higher rank (Owner: anyone),
--   all / others / @groups need Admin, plus a second rate limit (AdminConfig.Troll.Rate / Burst).
-- Commands: Lib/Admin/AdminCommands (data: rank, args, help). Targets: me, all, others, random, @lobby,
--   @squad, @<squad or call id>, #<UserId>, partial names, comma lists. Harmful commands (kick, ban, mute,
--   kill, freeze) only hit lower ranks. Rate limit: AdminConfig.Rate / Burst per player.
-- Input: TextChatService TextChatCommands (":name" + first alias) and Player.Chatted (legacy chat, other
--   aliases), deduped; Admin/Run from the console.
-- Owner gifts: :giftpass / :revokepass -> MonetizationService:GiftPass/RevokePass (profile v7 gifts, an
--   in-game entitlement, NOT a real Roblox pass); :giftxp; :donorboard reset.
-- Bans: DataStore AdminConfig.BanStore keyed by UserId (memory only when DataService isn't persistent,
--   i.e. Studio); checked on join. :m / :h text goes through TextService:FilterStringAsync.
--
-- Remotes: Admin/Run (C->S: text; 4/s burst 6) -- staff console
--          Admin/Result (S->C caller: ok: boolean, lines: { string }, open: "cmds" | nil)
--          Admin/Announce (S->C all: kind "m" | "h", from: string, text: string)  -- filtered text only
-- Writes: Player attrs AdminRank, AdminRankName, AdminFly, AdminNoclip, AdminGod, AdminFrozen,
--   AdminInvisible, AdminMuted (AdminConfig.Attr; UI only, never trusted)
-- Consumes (nil-guarded): DataService, MonetizationService, BattlePassService, InventoryService,
--   MissionService, LobbyService, FireService, VehicleService, EventService, AtmosphereService, SquadService
-- Counters: admin_commands, admin_denied, admin_rate_limited, admin_failed, admin_rank_grants
-- Test hooks (DevHook only): _run(player, text) -> "ok|line1\nline2", _rank(player), _logs(n?),
--   _ban(userId, name, reason?), _banned(userId), _grants() -> "id=rank,...", _restart() (drops this
--   server's rank cache and re-reads the store, like a new server), _selftest()

local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TextChatService = game:GetService("TextChatService")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript) :: any
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigFolder:WaitForChild("AdminConfig") :: ModuleScript) :: any
local MonetizationConfig = require(ConfigFolder:WaitForChild("MonetizationConfig") :: ModuleScript) :: any
local MissionCatalog = require(ConfigFolder:WaitForChild("MissionCatalog") :: ModuleScript) :: any
local EventConfig = require(ConfigFolder:WaitForChild("EventConfig") :: ModuleScript) :: any
local AtmosphereConfig = require(ConfigFolder:WaitForChild("AtmosphereConfig") :: ModuleScript) :: any
local Lib = ReplicatedStorage:WaitForChild("Lib")
local AdminLib = Lib:WaitForChild("Admin")
local Rules = require(AdminLib:WaitForChild("AdminRules") :: ModuleScript)
local Commands = require(AdminLib:WaitForChild("AdminCommands") :: ModuleScript)
local ItemDefs = require(Lib:WaitForChild("Items"):WaitForChild("ItemDefs") :: ModuleScript) :: any
local Schema = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Data"):WaitForChild("ProfileSchema") :: ModuleScript)

local AdminService = {}
AdminService.Priority = 70

local IS_STUDIO = RunService:IsStudio()
local A = Cfg.Attr
local CHAT_PREFIXES = { Cfg.ChatPrefix }
local CONSOLE_PREFIXES = { ":", ";", "" }

type Ctx = {
	caller: Player,
	rank: number,
	args: { [string]: any },
	def: Rules.Command,
	notes: { string },
}
type Handler = (Ctx) -> (boolean, string)

type Grant = { rank: number, name: string, by: string, at: number }
-- The rank store: a DataStore, or (Studio / no persistence) a memory mock with the same two methods.
type RankStore = {
	kind: string?, -- the memory mock only
	GetAsync: (self: any, key: string) -> any,
	UpdateAsync: (self: any, key: string, fn: (old: any) -> any) -> any,
}

local services: { [string]: any } = {}
local groupRanks: { [Player]: number } = {}
local grants: { [number]: Grant } = {} -- this server's copy of the saved ranks
local rankStore: RankStore? = nil
local rankStoreKind = "none" -- "datastore" | "memory"
local RANK_KEY = "staff"
local nameCache: { [number]: string } = {}
local buckets: { [Player]: { tokens: number?, at: number? } } = {}
local trollBuckets: { [Player]: { tokens: number?, at: number? } } = {}
local lastChat: { [Player]: { text: string, at: number } } = {}
local logs: { Rules.LogEntry } = {}
local bans: { [string]: { name: string, reason: string, by: string, at: number } } = {} -- memory copy
local banStore: GlobalDataStore? = nil
local muted: { [number]: boolean } = {}
local shuttingDown = false
local resultRemote: RemoteEvent? = nil
local announceRemote: RemoteEvent? = nil

------------------------------------------------------------------------------------------ lists

local function sortedKeys(t: any): { string }
	local out: { string } = {}
	if type(t) == "table" then
		for k in t do
			if type(k) == "string" and k ~= "Set" then
				table.insert(out, k)
			end
		end
	end
	table.sort(out)
	return out
end

local function lists(): { [string]: { string } }
	local missions: { string } = {}
	for _, m in MissionCatalog do
		if type(m) == "table" and type(m.id) == "string" and m.enabled == true then
			table.insert(missions, m.id)
		end
	end
	table.sort(missions)
	return {
		pass = sortedKeys(MonetizationConfig.GamePasses),
		item = sortedKeys(ItemDefs.Items),
		mission = missions,
		event = sortedKeys(EventConfig.Weights),
		preset = sortedKeys(AtmosphereConfig.Presets),
		rank = Commands.Lists.rank,
	}
end

------------------------------------------------------------------------------------------ ranks

-- withGrant = false: the rank the config alone gives (what an :unadmin falls back to).
local function rankOfId(userId: number, player: Player?, withGrant: boolean?): number
	local override = if IS_STUDIO and player then player:GetAttribute(Cfg.DebugAttribute) else nil
	local g = grants[userId]
	return Rules.rankOf({
		userId = userId,
		owners = Cfg.Owners,
		admins = Cfg.Admins,
		mods = Cfg.Mods,
		creatorType = if game.CreatorType == Enum.CreatorType.Group then "Group" else "User",
		creatorId = game.CreatorId,
		groupRank = if player then groupRanks[player] else nil,
		groupRanks = Cfg.GroupRanks,
		isStudio = IS_STUDIO,
		studioOwner = Cfg.StudioOwner and player ~= nil, -- the Studio override is the person at the keyboard only
		grantedRank = if withGrant ~= false and g then g.rank else nil,
		override = if type(override) == "number" then override else nil,
	})
end

local function rankOf(player: Player): number
	return rankOfId(player.UserId, player)
end

local function refreshRank(player: Player)
	if not player.Parent then
		return
	end
	local r = rankOf(player)
	player:SetAttribute(A.Rank, r)
	player:SetAttribute(A.RankName, Rules.rankName(r))
end

local function refreshAll()
	for _, p in Players:GetPlayers() do
		refreshRank(p)
	end
end

-------------------------------------------------------------------------------------- saved ranks

local function memoryRankStore(): RankStore
	local data: { [string]: any } = {}
	local function copy(t: any): any
		if type(t) ~= "table" then
			return t
		end
		local out = {}
		for k, v in t do
			out[k] = copy(v)
		end
		return out
	end
	return {
		kind = "memory",
		GetAsync = function(_self, key: string)
			return copy(data[key])
		end,
		UpdateAsync = function(_self, key: string, fn: (any) -> any)
			local new = fn(copy(data[key]))
			if new ~= nil then
				data[key] = copy(new)
			end
			return copy(new)
		end,
	}
end

-- Keeps only well-formed records: { ["<UserId>"] = { rank 0..2, name, by, at } }.
local function sanitizeGrants(raw: any): { [number]: Grant }
	local out: { [number]: Grant } = {}
	if type(raw) ~= "table" then
		return out
	end
	for k, v in raw do
		local id = tonumber(k)
		if id and type(v) == "table" and type(v.rank) == "number" and v.rank >= 0 and v.rank <= 2 then
			out[id] = {
				rank = math.floor(v.rank),
				name = if type(v.name) == "string" then v.name else `#{id}`,
				by = if type(v.by) == "string" then v.by else "?",
				at = if type(v.at) == "number" then v.at else 0,
			}
		end
	end
	return out
end

local function loadGrants(): boolean
	local store = rankStore
	if not store then
		return false
	end
	local ok, res = pcall(function()
		return store:GetAsync(RANK_KEY)
	end)
	if not ok then
		warn(`[AdminService] rank store read: {res}`)
		return false
	end
	grants = sanitizeGrants(res)
	for id, g in grants do
		nameCache[id] = g.name
	end
	refreshAll()
	return true
end

local function publishRanks()
	if IS_STUDIO then
		return
	end
	task.spawn(function()
		pcall(function()
			MessagingService:PublishAsync(Cfg.RankTopic, game.JobId)
		end)
	end)
end

-- rank nil = drop the record (the config already gives the wanted rank). Returns ok, error.
local function saveGrant(userId: number, name: string, rank: number?, by: string): (boolean, string?)
	local store = rankStore
	if not store then
		return false, "the rank store isn't ready"
	end
	local ok, res = pcall(function()
		return store:UpdateAsync(RANK_KEY, function(old: any)
			local t = if type(old) == "table" then old else {}
			if rank == nil then
				t[tostring(userId)] = nil
			else
				t[tostring(userId)] = { rank = rank, name = name, by = by, at = os.time() }
			end
			return t
		end)
	end)
	if not ok then
		warn(`[AdminService] rank store write: {res}`)
		return false, "couldn't save the rank (DataStore error), try again"
	end
	grants = sanitizeGrants(res)
	nameCache[userId] = name
	refreshAll()
	publishRanks()
	Telemetry.count("admin_rank_grants")
	return true, nil
end

------------------------------------------------------------------------------------------- utils

local function rootOf(p: Player): BasePart?
	local c = p.Character
	return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function humOf(p: Player): Humanoid?
	local c = p.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function roster(): { Rules.Who }
	local out: { Rules.Who } = {}
	for _, p in Players:GetPlayers() do
		table.insert(out, {
			userId = p.UserId,
			name = p.Name,
			displayName = p.DisplayName,
			squad = (p:GetAttribute(Names.Attr.SquadId) :: string?) or "",
			instance = (p:GetAttribute(Names.Attr.InstanceId) :: string?) or "",
		})
	end
	return out
end

-- Resolves a players spec to Player objects. Harmful commands drop targets of equal/higher rank;
-- mode "troll" drops only HIGHER ranks (AdminRules.canTroll: the Owner trolls anyone).
local function targets(ctx: Ctx, spec: string, harmful: (boolean | string)?): ({ Player }, string?)
	local list = roster()
	local ids, err = Rules.resolve(spec, ctx.caller.UserId, list, math.random(math.max(1, #list)))
	if err then
		return {}, err
	end
	local out: { Player } = {}
	local skipped = 0
	for _, id in ids do
		local p = Players:GetPlayerByUserId(id)
		if p then
			if harmful == "troll" then
				if not Rules.canTroll(ctx.rank, rankOf(p), p == ctx.caller) then
					skipped += 1
				else
					table.insert(out, p)
				end
			elseif harmful and not Rules.canAffect(ctx.rank, rankOf(p), p == ctx.caller) then
				skipped += 1
			else
				table.insert(out, p)
			end
		end
	end
	local higher = if harmful == "troll" then "a higher rank" else "equal or higher rank"
	if skipped > 0 then
		table.insert(ctx.notes, `skipped {skipped} player(s) of {higher}`)
	end
	if #out == 0 then
		return out, if skipped > 0 then `you can't target players of {higher}` else "no players"
	end
	return out, nil
end

local function namesOf(list: { Player }): string
	local n: { string } = {}
	for i, p in list do
		if i > 4 then
			table.insert(n, `+{#list - 4} more`)
			break
		end
		table.insert(n, p.Name)
	end
	return table.concat(n, ", ")
end

-- Runs fn per target; returns how many returned true.
local function each(list: { Player }, fn: (Player) -> boolean?): number
	local n = 0
	for _, p in list do
		local ok, res = pcall(fn, p)
		if ok and res ~= false then
			n += 1
		elseif not ok then
			warn(`[AdminService] {p.Name}: {res}`)
		end
	end
	return n
end

local function done(verb: string, list: { Player }, n: number?): (boolean, string)
	local count = n or #list
	if count == 0 then
		return false, `{verb}: nothing happened`
	end
	return true, `{verb}: {namesOf(list)}`
end

local function moveTo(p: Player, cf: CFrame)
	local hum = humOf(p)
	if hum and hum.SeatPart then
		hum.Sit = false
		task.wait()
	end
	local c = p.Character
	if c then
		c:PivotTo(cf)
	end
end

local function filterBroadcast(text: string, fromUserId: number): string?
	local ok, res = pcall(function()
		local r = TextService:FilterStringAsync(text, fromUserId, Enum.TextFilterContext.PublicChat)
		return r:GetNonChatStringForBroadcastAsync()
	end)
	if not ok then
		warn(`[AdminService] filter failed: {res}`)
		return nil
	end
	return res :: string
end

------------------------------------------------------------------------------------------- mutes

local function applyMute(player: Player)
	local on = muted[player.UserId] == true
	player:SetAttribute(A.Muted, if on then true else nil)
	for _, d in TextChatService:GetDescendants() do
		if d:IsA("TextSource") and d.UserId == player.UserId then
			d.CanSend = not on
		end
	end
end

-------------------------------------------------------------------------------------------- bans

local function banKey(userId: number): string
	return tostring(userId)
end

local function getBan(userId: number): any
	local mem = bans[banKey(userId)]
	if mem then
		return mem
	end
	local ds = banStore
	if not ds then
		return nil
	end
	local ok, res = pcall(function()
		return ds:GetAsync(banKey(userId))
	end)
	if ok and type(res) == "table" then
		bans[banKey(userId)] = res
		return res
	end
	return nil
end

local function setBan(userId: number, record: any): boolean
	bans[banKey(userId)] = record
	local ds = banStore
	if not ds then
		return true
	end
	local ok, err = pcall(function()
		if record then
			ds:SetAsync(banKey(userId), record, { userId })
		else
			ds:RemoveAsync(banKey(userId))
		end
	end)
	if not ok then
		warn(`[AdminService] ban store: {err}`)
	end
	return ok
end

------------------------------------------------------------------------------------------- body

local function setGod(p: Player, on: boolean): boolean
	local hum = humOf(p)
	p:SetAttribute(A.God, if on then true else nil)
	if not hum then
		return false
	end
	if on then
		hum.MaxHealth = math.huge
		hum.Health = math.huge
	else
		hum.MaxHealth = 100
		hum.Health = 100
	end
	return true
end

local function setInvisible(p: Player, on: boolean): boolean
	local c = p.Character
	p:SetAttribute(A.Invisible, if on then true else nil)
	if not c then
		return false
	end
	for _, d in c:GetDescendants() do
		if d:IsA("BasePart") or d:IsA("Decal") then
			if d.Name == "HumanoidRootPart" then
				continue
			end
			if on then
				if d:GetAttribute("AdminT") == nil then
					d:SetAttribute("AdminT", (d :: any).Transparency)
				end
				(d :: any).Transparency = 1
			else
				local t = d:GetAttribute("AdminT")
				if type(t) == "number" then
					(d :: any).Transparency = t
				end
				d:SetAttribute("AdminT", nil)
			end
		elseif d:IsA("BillboardGui") then
			if on then
				if d:GetAttribute("AdminEnabled") == nil then
					d:SetAttribute("AdminEnabled", d.Enabled)
				end
				d.Enabled = false
			else
				local e = d:GetAttribute("AdminEnabled")
				if type(e) == "boolean" then
					d.Enabled = e
				end
				d:SetAttribute("AdminEnabled", nil)
			end
		end
	end
	local hum = c:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.DisplayDistanceType = if on then Enum.HumanoidDisplayDistanceType.None else Enum.HumanoidDisplayDistanceType.Viewer
	end
	return true
end

local function setFrozen(p: Player, on: boolean): boolean
	local root = rootOf(p)
	p:SetAttribute(A.Frozen, if on then true else nil)
	if not root then
		return false
	end
	root.Anchored = on
	return true
end

local function instanceOf(p: Player): string
	local iid = p:GetAttribute(Names.Attr.InstanceId)
	return if type(iid) == "string" then iid else ""
end

----------------------------------------------------------------------------------------- handlers

local H: { [string]: Handler } = {}

H.cmds = function(_ctx)
	return true, "opened the command list"
end

H.logs = function(ctx)
	local n = math.floor(ctx.args.count or Cfg.LogShow)
	local from = math.max(1, #logs - n + 1)
	for i = from, #logs do
		table.insert(ctx.notes, Rules.logLine(logs[i]))
	end
	return true, `last {#logs - from + 1} command(s):`
end

H.tp = function(ctx)
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local dest, err2 = targets(ctx, ctx.args.destination)
	if err2 then
		return false, err2
	end
	if #dest ~= 1 then
		return false, "destination must be exactly one player"
	end
	local to = rootOf(dest[1])
	if not to then
		return false, `{dest[1].Name} has no character`
	end
	local n = each(list, function(p)
		if p == dest[1] then
			return false
		end
		moveTo(p, to.CFrame * CFrame.new(0, 0, 4))
		return true
	end)
	return done(`teleported to {dest[1].Name}`, list, n)
end

H.bring = function(ctx)
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local to = rootOf(ctx.caller)
	if not to then
		return false, "you have no character"
	end
	local i = 0
	local n = each(list, function(p)
		if p == ctx.caller then
			return false
		end
		i += 1
		moveTo(p, to.CFrame * CFrame.new((i % 3 - 1) * 4, 0, -4 - (i // 3) * 4))
		return true
	end)
	return done("brought", list, n)
end

H.to = function(ctx)
	local list, err = targets(ctx, ctx.args.player)
	if err then
		return false, err
	end
	local to = rootOf(list[1])
	if not to then
		return false, `{list[1].Name} has no character`
	end
	moveTo(ctx.caller, to.CFrame * CFrame.new(0, 0, 4))
	return true, `went to {list[1].Name}`
end

local function flag(attr: string, on: boolean, verb: string): Handler
	return function(ctx)
		local list, err = targets(ctx, ctx.args.players)
		if err then
			return false, err
		end
		each(list, function(p)
			p:SetAttribute(attr, if on then true else nil)
			return true
		end)
		return done(verb, list)
	end
end

H.fly = flag(A.Fly, true, "flying")
H.unfly = flag(A.Fly, false, "stopped flying")
H.noclip = flag(A.Noclip, true, "noclip on")
H.clip = flag(A.Noclip, false, "noclip off")

H.speed = function(ctx)
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local n = each(list, function(p)
		local hum = humOf(p)
		if not hum then
			return false
		end
		hum.WalkSpeed = ctx.args.speed
		return true
	end)
	return done(`speed {ctx.args.speed}`, list, n)
end

H.jump = function(ctx)
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local n = each(list, function(p)
		local hum = humOf(p)
		if not hum then
			return false
		end
		hum.UseJumpPower = true
		hum.JumpPower = ctx.args.power
		return true
	end)
	return done(`jump power {ctx.args.power}`, list, n)
end

H.heal = function(ctx)
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local Squad = services.SquadService
	local n = each(list, function(p)
		local hum = humOf(p)
		if not hum then
			return false
		end
		if Squad and type(Squad.IsDowned) == "function" and Squad:IsDowned(p) then
			Squad:Revive(p, ctx.caller, "admin")
		end
		hum.Health = hum.MaxHealth
		return true
	end)
	return done("healed", list, n)
end

H.kill = function(ctx)
	local list, err = targets(ctx, ctx.args.players, true)
	if err then
		return false, err
	end
	local n = each(list, function(p)
		local hum = humOf(p)
		if not hum then
			return false
		end
		setGod(p, false)
		hum.Health = 0
		return true
	end)
	return done("killed", list, n)
end

H.respawn = function(ctx)
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local n = each(list, function(p)
		p:LoadCharacter()
		return true
	end)
	return done("respawned", list, n)
end

H.god = function(ctx)
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	return done("god mode on", list, each(list, function(p)
		return setGod(p, true)
	end))
end

H.ungod = function(ctx)
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	return done("god mode off", list, each(list, function(p)
		return setGod(p, false)
	end))
end

H.freeze = function(ctx)
	local list, err = targets(ctx, ctx.args.players, true)
	if err then
		return false, err
	end
	return done("frozen", list, each(list, function(p)
		return setFrozen(p, true)
	end))
end

H.thaw = function(ctx)
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	return done("thawed", list, each(list, function(p)
		return setFrozen(p, false)
	end))
end

H.invisible = function(ctx)
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	return done("invisible", list, each(list, function(p)
		return setInvisible(p, true)
	end))
end

H.visible = function(ctx)
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	return done("visible", list, each(list, function(p)
		return setInvisible(p, false)
	end))
end

H.kick = function(ctx)
	local list, err = targets(ctx, ctx.args.players, true)
	if err then
		return false, err
	end
	local reason = if ctx.args.reason ~= "" then ctx.args.reason else "Kicked by a moderator"
	reason = string.sub(reason, 1, Cfg.MaxMessageLength)
	local n = each(list, function(p)
		if p == ctx.caller then
			return false -- kicking yourself is almost always a typo
		end
		p:Kick(reason)
		return true
	end)
	return done("kicked", list, n)
end

H.ban = function(ctx)
	local list, err = targets(ctx, ctx.args.players, true)
	if err then
		return false, err
	end
	local reason = if ctx.args.reason ~= "" then ctx.args.reason else "Banned by an admin"
	reason = string.sub(reason, 1, Cfg.MaxMessageLength)
	local n = each(list, function(p)
		if p == ctx.caller then
			return false
		end
		setBan(p.UserId, { name = p.Name, reason = reason, by = ctx.caller.Name, at = os.time() })
		p:Kick(`Banned: {reason}`)
		return true
	end)
	if banStore == nil then
		table.insert(ctx.notes, "ban list is in memory only (Studio / no DataStore)")
	end
	return done("banned", list, n)
end

H.unban = function(ctx)
	local user = ctx.args.user
	local id = tonumber(user)
	if not id then
		for k, rec in bans do
			if type(rec) == "table" and string.lower(rec.name or "") == string.lower(user) then
				id = tonumber(k)
			end
		end
	end
	if not id then
		local ok, res = pcall(function()
			return Players:GetUserIdFromNameAsync(user)
		end)
		id = if ok then res else nil
	end
	if not id then
		return false, `no user "{user}"`
	end
	if not getBan(id) then
		return false, `{user} isn't banned`
	end
	setBan(id, nil)
	return true, `unbanned {user} ({id})`
end

H.bans = function(ctx)
	local n = 0
	for k, rec in bans do
		if type(rec) == "table" then
			n += 1
			table.insert(ctx.notes, `{rec.name} ({k}): {rec.reason} - by {rec.by}`)
		end
	end
	return true, `{n} ban(s) known on this server`
end

H.mute = function(ctx)
	local list, err = targets(ctx, ctx.args.players, true)
	if err then
		return false, err
	end
	return done("muted", list, each(list, function(p)
		muted[p.UserId] = true
		applyMute(p)
		return true
	end))
end

H.unmute = function(ctx)
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	return done("unmuted", list, each(list, function(p)
		muted[p.UserId] = nil
		applyMute(p)
		return true
	end))
end

H.shutdown = function(ctx)
	local reason = if ctx.args.reason ~= "" then ctx.args.reason else "This server is shutting down. Please rejoin!"
	reason = string.sub(reason, 1, Cfg.MaxMessageLength)
	shuttingDown = true
	task.delay(1, function()
		for _, p in Players:GetPlayers() do
			p:Kick(reason)
		end
	end)
	return true, "shutting down in 1 s"
end

------------------------------------------------------------------------------------------- staff

type Someone = { userId: number, name: string, player: Player? }

local function nameOfId(userId: number): string
	local p = Players:GetPlayerByUserId(userId)
	if p then
		return p.Name
	end
	local cached = nameCache[userId]
	if cached then
		return cached
	end
	if userId > 0 then
		local ok, res = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		if ok and type(res) == "string" then
			nameCache[userId] = res
			return res
		end
	end
	return `#{userId}`
end

-- Grant targets: online players (normal targeting, one by one: no all / others / @groups), else ONE
-- offline user by #UserId, a saved staff name, or a Roblox username.
local function grantTargets(ctx: Ctx, spec: string): ({ Someone }, string?)
	if Rules.massTarget(spec) or string.lower(spec) == "random" then
		return {}, "pick players by name for rank changes (no all / others / @groups)"
	end
	local list = roster()
	local ids = Rules.resolve(spec, ctx.caller.UserId, list)
	local out: { Someone } = {}
	for _, id in ids do
		local p = Players:GetPlayerByUserId(id)
		if p then
			table.insert(out, { userId = id, name = p.Name, player = p })
		end
	end
	if #out > 0 then
		return out, nil
	end
	local word = string.match(spec, "^%s*(.-)%s*$") or ""
	if word == "" or string.find(word, ",", 1, true) then
		return {}, `no player matches "{spec}"`
	end
	local id = if string.sub(word, 1, 1) == "#" then tonumber(string.sub(word, 2)) else nil
	if not id then
		for gid, g in grants do
			if string.lower(g.name) == string.lower(word) then
				id = gid
			end
		end
	end
	if not id then
		local ok, res = pcall(function()
			return Players:GetUserIdFromNameAsync(word)
		end)
		id = if ok and type(res) == "number" then res else nil
	end
	if not id then
		return {}, `no player or Roblox user "{word}"`
	end
	return { { userId = id, name = nameOfId(id), player = nil } }, nil
end

local function grant(ctx: Ctx, who: Someone, newRank: number): (boolean, string)
	local current = if who.player then rankOf(who.player) else rankOfId(who.userId, nil)
	local ok, why = Rules.canGrant(ctx.rank, current, newRank, who.userId == ctx.caller.UserId)
	if not ok then
		return false, `{who.name}: {why}`
	end
	local saved = grants[who.userId]
	local default = rankOfId(who.userId, who.player, false)
	local action = Rules.grantAction(default, if saved then saved.rank else nil, newRank)
	if action == "same" then
		return true, `{who.name} is already {Rules.rankName(current)}`
	end
	local okSave, err = saveGrant(who.userId, who.name, if action == "clear" then nil else newRank, ctx.caller.Name)
	if not okSave then
		return false, err or "couldn't save"
	end
	local now = if who.player then rankOf(who.player) else rankOfId(who.userId, nil)
	if who.player then
		local msg = if now >= 1
			then `{ctx.caller.DisplayName} made you {Rules.rankName(now)}! Press ; or tap ADMIN for commands.`
			else `You are a Player again.`
		Net.notify(who.player, msg, if now >= 1 then "good" else "info")
	end
	return true, `{who.name} is now {Rules.rankName(now)} (saved{if who.player then "" else ", offline"})`
end

local function grantHandler(fixed: number?): Handler
	return function(ctx)
		local r = fixed
		if r == nil then
			r = Rules.rankFromName(ctx.args.rank)
		end
		if r == nil or r > 2 then
			return false, "rank must be Player, Mod or Admin"
		end
		local list, err = grantTargets(ctx, ctx.args.players)
		if err then
			return false, err
		end
		local n = 0
		local first = ""
		for i, who in list do
			local ok, msg = grant(ctx, who, r)
			if i == 1 then
				first = msg
			else
				table.insert(ctx.notes, msg)
			end
			if ok then
				n += 1
			end
		end
		if #list > 1 then
			table.insert(ctx.notes, 1, first)
			return n > 0, `{Rules.rankName(r)}: {n} of {#list} player(s)`
		end
		return n > 0, first
	end
end

H.admin = grantHandler(2)
H.mod = grantHandler(1)
H.unadmin = grantHandler(0)
H.setrank = grantHandler(nil)

H.admins = function(ctx)
	local rows: { Rules.StaffRow } = {}
	local seen: { [number]: boolean } = {}
	local function add(id: number, source: string)
		if seen[id] or id == 0 then
			return
		end
		seen[id] = true
		local p = Players:GetPlayerByUserId(id)
		local r = if p then rankOf(p) else rankOfId(id, nil)
		table.insert(rows, { userId = id, name = nameOfId(id), rank = r, source = source, online = p ~= nil })
	end
	if game.CreatorType == Enum.CreatorType.User and game.CreatorId > 0 then
		add(game.CreatorId, "creator")
	end
	for id, g in grants do
		add(id, `saved by {g.by}`)
	end
	for _, list in { Cfg.Owners, Cfg.Admins, Cfg.Mods } do
		for _, id in list do
			add(id, "config")
		end
	end
	for _, p in Players:GetPlayers() do
		add(p.UserId, if IS_STUDIO then "studio / group" else "group")
	end
	local lines = Rules.staffLines(rows)
	for _, l in lines do
		table.insert(ctx.notes, l)
	end
	return true, `{#lines} staff (ranks are saved: they stick across servers)`
end

------------------------------------------------------------------------------------------- trolls

local function trollHandler(kind: string): Handler
	return function(ctx)
		local Troll = services.TrollService
		if not Troll then
			return false, "TrollService is not running"
		end
		local list, err = targets(ctx, ctx.args.players, "troll")
		if err then
			return false, err
		end
		local n = 0
		local word = kind
		for _, p in list do
			local ok, msg = Troll:Run(kind, p, ctx.caller)
			if ok then
				n += 1
				word = msg
			else
				table.insert(ctx.notes, `{p.Name}: {msg}`)
			end
		end
		return done(word, list, n)
	end
end

for _, def in Commands.Commands do
	if def.troll then
		H[def.name] = trollHandler(def.name)
	end
end

H.unjail = function(ctx)
	local Troll = services.TrollService
	if not Troll then
		return false, "TrollService is not running"
	end
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	return done("unjailed", list, each(list, function(p)
		return Troll:Revert(p, "jail") > 0
	end))
end

H.normal = function(ctx)
	local Troll = services.TrollService
	if not Troll then
		return false, "TrollService is not running"
	end
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local total = 0
	for _, p in list do
		total += Troll:Revert(p)
	end
	return true, `back to normal: {namesOf(list)} ({total} effect(s) undone)`
end

local function announce(kind: string, ctx: Ctx, key: string): (boolean, string)
	local raw = string.sub(ctx.args[key], 1, Cfg.MaxMessageLength)
	if raw == "" then
		return false, "nothing to say"
	end
	local text = filterBroadcast(raw, ctx.caller.UserId)
	if not text then
		return false, "the chat filter is unavailable, message not sent"
	end
	local r = announceRemote
	if r then
		r:FireAllClients(kind, ctx.caller.DisplayName, text)
	end
	return true, if kind == "m" then "message sent" else "hint sent"
end

H.m = function(ctx)
	return announce("m", ctx, "message")
end

H.h = function(ctx)
	return announce("h", ctx, "hint")
end

H.fire = function(ctx)
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local Fire = services.FireService
	if not Fire then
		return false, "FireService is not running"
	end
	local flammable = CollectionService:GetTagged(Names.Tag.Flammable)
	local lit = 0
	for _, p in list do
		local root = rootOf(p)
		if not root then
			continue
		end
		local best: BasePart? = nil
		local bestD = Cfg.FireRadius
		for _, inst in flammable do
			if inst:IsA("BasePart") and inst:IsDescendantOf(workspace) and not inst:HasTag(Names.Tag.Burning) then
				local d = (inst.Position - root.Position).Magnitude
				if d < bestD then
					best, bestD = inst, d
				end
			end
		end
		if best and Fire:Ignite(best, nil) then
			lit += 1
			table.insert(ctx.notes, `lit {best.Name} {math.floor(bestD)} studs from {p.Name}`)
		end
	end
	if lit == 0 then
		return false, `nothing flammable within {Cfg.FireRadius} studs`
	end
	return true, `lit {lit} fire(s)`
end

H.extinguish = function(ctx)
	local Fire = services.FireService
	if not Fire then
		return false, "FireService is not running"
	end
	local spec = string.lower(ctx.args.players)
	if spec == "all" then
		local before = Fire:CountBurning(nil)
		Fire:ExtinguishAll(nil)
		return true, `put out every fire ({before})`
	end
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local seen: { [string]: boolean } = {}
	local out = 0
	for _, p in list do
		local iid = instanceOf(p)
		local loc = if iid ~= "" then iid else "Station"
		if not seen[loc] then
			seen[loc] = true
			out += Fire:CountBurning(loc)
			Fire:ExtinguishAll(loc)
		end
	end
	return true, `put out {out} fire(s)`
end

H.mission = function(ctx)
	local Mission = services.MissionService
	if not Mission then
		return false, "MissionService is not running"
	end
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	-- a target queued on a squad pad launches that whole squad through the lobby
	local Lobby = services.LobbyService
	if Lobby and type(Lobby.Launch) == "function" then
		for _, p in list do
			local sid = p:GetAttribute(Names.Attr.SquadId)
			if type(sid) == "string" and sid ~= "" and instanceOf(p) == "" then
				local iid = Lobby:Launch(sid, ctx.args.mission)
				if iid then
					return true, `launched squad {sid} on {ctx.args.mission} ({iid})`
				end
			end
		end
	end
	local squad: { Player } = {}
	for _, p in list do
		if instanceOf(p) == "" then
			table.insert(squad, p)
		end
	end
	if #squad == 0 then
		return false, "everyone targeted is already on a call (:endmission first)"
	end
	local iid = Mission:StartMission(squad, ctx.args.mission)
	if not iid then
		return false, `couldn't start {ctx.args.mission}`
	end
	return true, `started {ctx.args.mission} ({iid}) for {namesOf(squad)}`
end

H.endmission = function(ctx)
	local Mission = services.MissionService
	if not Mission then
		return false, "MissionService is not running"
	end
	local ids: { string } = {}
	if string.lower(ctx.args.players) == "all" then
		for _, m in Mission:GetMissions() do
			table.insert(ids, m.instanceId)
		end
	else
		local list, err = targets(ctx, ctx.args.players)
		if err then
			return false, err
		end
		for _, p in list do
			local iid = instanceOf(p)
			if iid ~= "" and not table.find(ids, iid) then
				table.insert(ids, iid)
			end
		end
	end
	if #ids == 0 then
		return false, "no call to end"
	end
	for _, iid in ids do
		Mission:EndMission(iid, "forced")
	end
	return true, `ended {#ids} call(s): {table.concat(ids, ", ")}`
end

H.give = function(ctx)
	local Inv = services.InventoryService
	if not Inv then
		return false, "InventoryService is not running"
	end
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	return done(`gave {ctx.args.item}`, list, each(list, function(p)
		return Inv:Give(p, ctx.args.item)
	end))
end

H.xp = function(ctx)
	local BP = services.BattlePassService
	if not BP then
		return false, "BattlePassService is not running"
	end
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local amount = math.floor(ctx.args.amount)
	return done(`+{amount} pass XP`, list, each(list, function(p)
		return BP:AwardXp(p, amount, "Admin") > 0
	end))
end

H.level = function(ctx)
	local Data = services.DataService
	if not Data then
		return false, "DataService is not running"
	end
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local lvl = math.floor(ctx.args.level)
	return done(`level {lvl}`, list, each(list, function(p)
		return Data:Update(p, function(prof: any)
			prof.xp = Schema.xpForLevel(lvl)
		end)
	end))
end

H.truck = function(ctx)
	local Vehicle = services.VehicleService
	if not Vehicle then
		return false, "VehicleService is not running"
	end
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local n = each(list, function(p)
		return Vehicle:RespawnTruck(p)
	end)
	if n < #list then
		table.insert(ctx.notes, "some trucks are on respawn cooldown")
	end
	return done("respawned truck", list, n)
end

H.event = function(ctx)
	local Events = services.EventService
	if not Events then
		return false, "EventService is not running"
	end
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local runId: string? = nil
	for _, p in list do
		local iid = instanceOf(p)
		if iid ~= "" then
			runId = iid
			break
		end
	end
	local ok, msg = Events:Force(runId, ctx.args.event)
	return ok, `{ctx.args.event}: {msg}`
end

H.weather = function(ctx)
	local Atmo = services.AtmosphereService
	if not Atmo then
		return false, "AtmosphereService is not running"
	end
	local ok = Atmo:Apply(ctx.args.preset, 2)
	return ok, if ok then `weather {ctx.args.preset}` else `unknown preset {ctx.args.preset}`
end

H.giftpass = function(ctx)
	local Mon = services.MonetizationService
	if not Mon or type(Mon.GiftPass) ~= "function" then
		return false, "MonetizationService is not running"
	end
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local n = 0
	for _, p in list do
		local ok, msg = Mon:GiftPass(p, ctx.args.pass, ctx.caller.UserId)
		table.insert(ctx.notes, msg)
		if ok then
			n += 1
		end
	end
	return n > 0, `gifted {ctx.args.pass} to {n} player(s) (in-game entitlement, not a Roblox pass)`
end

H.revokepass = function(ctx)
	local Mon = services.MonetizationService
	if not Mon or type(Mon.RevokePass) ~= "function" then
		return false, "MonetizationService is not running"
	end
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local n = 0
	for _, p in list do
		local ok, msg = Mon:RevokePass(p, ctx.args.pass)
		table.insert(ctx.notes, msg)
		if ok then
			n += 1
		end
	end
	return n > 0, `revoked {ctx.args.pass} from {n} player(s)`
end

H.giftxp = function(ctx)
	local list, err = targets(ctx, ctx.args.players)
	if err then
		return false, err
	end
	local amount = math.floor(ctx.args.amount)
	local Data, BP = services.DataService, services.BattlePassService
	local n = each(list, function(p)
		local a = if Data then Data:AddXp(p, amount, "Gift") else 0
		local b = if BP then BP:AwardXp(p, amount, "Gift") else 0
		if a + b > 0 then
			Net.notify(p, `{ctx.caller.DisplayName} gifted you {amount} XP!`, "good")
			return true
		end
		return false
	end)
	return done(`gifted {amount} XP`, list, n)
end

H.donorboard = function(ctx)
	if string.lower(ctx.args.action) ~= "reset" then
		return false, "usage: :donorboard reset"
	end
	local Mon = services.MonetizationService
	if not Mon or type(Mon.ResetDonorBoard) ~= "function" then
		return false, "MonetizationService is not running"
	end
	return Mon:ResetDonorBoard()
end

------------------------------------------------------------------------------------------ execute

local function log(caller: Player, rank: number, text: string, ok: boolean, result: string)
	table.insert(logs, { at = os.time(), by = caller.Name, rank = rank, text = string.sub(text, 1, 160), ok = ok, result = result })
	while #logs > Cfg.LogSize do
		table.remove(logs, 1)
	end
end

-- source "chat" | "console". Returns nil when the text isn't a command for this player (chat stays chat).
local function execute(caller: Player, text: any, source: string): (boolean?, { string }, string?)
	local parsed = Rules.parse(text, if source == "chat" then CHAT_PREFIXES else CONSOLE_PREFIXES)
	if not parsed then
		return nil, { "not a command" }
	end
	local rank = rankOf(caller)
	local def = Rules.find(Commands.Commands :: any, parsed.name)
	if rank < 1 then
		if def then
			Telemetry.count("admin_denied")
			log(caller, rank, text, false, "denied (not staff)")
		end
		return if source == "console" then false else nil, { "You can't use admin commands." }
	end
	if not def then
		return false, { `unknown command :{parsed.name} (try :cmds)` }
	end
	local bucket = buckets[caller]
	if not bucket then
		bucket = {}
		buckets[caller] = bucket
	end
	if not Rules.allow(bucket, os.clock(), Cfg.Rate, Cfg.Burst) then
		Telemetry.count("admin_rate_limited")
		return false, { "slow down: too many commands" }
	end
	if not Rules.canRun(rank, def) then
		Telemetry.count("admin_denied")
		log(caller, rank, text, false, `denied (needs {Rules.rankName(def.rank)})`)
		return false, { `:{def.name} needs {Rules.rankName(def.rank)} rank` }
	end
	local args, bindErr = Rules.bind(def, parsed.tokens, lists())
	if not args then
		return false, { `{bindErr} - usage: {Rules.usage(def)}` }
	end
	local handler = H[def.name]
	if not handler then
		return false, { `:{def.name} is not implemented` }
	end
	if def.troll then
		if rank < 2 and Rules.massTarget(tostring(args.players or "")) then
			Telemetry.count("admin_denied")
			log(caller, rank, text, false, "denied (all / others need Admin)")
			return false, { "trolling all / others / a whole group needs Admin rank" }
		end
		local tb = trollBuckets[caller]
		if not tb then
			tb = {}
			trollBuckets[caller] = tb
		end
		if not Rules.allow(tb, os.clock(), Cfg.Troll.Rate, Cfg.Troll.Burst) then
			Telemetry.count("admin_rate_limited")
			log(caller, rank, text, false, "rate limited (trolls)")
			return false, { "slow down: one troll at a time" }
		end
	end
	local ctx: Ctx = { caller = caller, rank = rank, args = args, def = def, notes = {} }
	local ok, a, b = pcall(handler, ctx)
	local success: boolean = ok and a == true
	local msg: string = if ok then tostring(b) else `error: {a}`
	if not ok then
		warn(`[AdminService] :{def.name} by {caller.Name}: {a}`)
	end
	Telemetry.count("admin_commands")
	if not success then
		Telemetry.count("admin_failed")
	end
	log(caller, rank, text, success, msg)
	local lines = { msg }
	for _, n in ctx.notes do
		table.insert(lines, n)
	end
	return success, lines, if def.name == "cmds" then "cmds" else nil
end

local function reply(caller: Player, ok: boolean, lines: { string }, open: string?, source: string)
	local r = resultRemote
	if r and caller.Parent then
		r:FireClient(caller, ok, lines, open)
	end
	if source == "chat" and open == nil then
		Net.notify(caller, lines[1] or "", if ok then "good" else "bad")
	end
end

local function onChat(player: Player, text: string)
	if type(text) ~= "string" or string.sub(string.match(text, "^%s*(.*)") or "", 1, #Cfg.ChatPrefix) ~= Cfg.ChatPrefix then
		return
	end
	-- TextChatCommand.Triggered and Player.Chatted can both see the same line: run it once.
	local last = lastChat[player]
	local now = os.clock()
	if last and last.text == text and now - last.at < 1 then
		return
	end
	lastChat[player] = { text = text, at = now }
	local ok, lines, open = execute(player, text, "chat")
	if ok ~= nil then
		reply(player, ok, lines, open, "chat")
	end
end

local function hookTextChat()
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "Station67Admin"
	for _, def in Commands.Commands do
		local cmd = Instance.new("TextChatCommand")
		cmd.Name = `Admin_{def.name}`
		cmd.PrimaryAlias = Cfg.ChatPrefix .. def.name
		local alias = def.aliases and def.aliases[1]
		cmd.SecondaryAlias = if alias then Cfg.ChatPrefix .. alias else ""
		cmd.Triggered:Connect(function(source: TextSource, text: string)
			local p = Players:GetPlayerByUserId(source.UserId)
			if p then
				onChat(p, text)
			end
		end)
		cmd.Parent = folder
	end
	folder.Parent = TextChatService
	TextChatService.DescendantAdded:Connect(function(d)
		if d:IsA("TextSource") and muted[d.UserId] then
			d.CanSend = false
		end
	end)
end

------------------------------------------------------------------------------------------ players

local function onCharacter(player: Player, _char: Model)
	player:SetAttribute(A.Frozen, nil)
	player:SetAttribute(A.Invisible, nil)
	if player:GetAttribute(A.God) == true then
		task.defer(function()
			setGod(player, true)
		end)
	end
end

local function onPlayerAdded(player: Player)
	if shuttingDown then
		player:Kick("This server is shutting down. Please rejoin!")
		return
	end
	local ban = getBan(player.UserId)
	if ban then
		player:Kick(`Banned: {ban.reason or "no reason"}`)
		return
	end
	refreshRank(player)
	if game.CreatorType == Enum.CreatorType.Group and player.UserId > 0 then
		task.spawn(function()
			local ok, r = pcall(function()
				return player:GetRankInGroup(game.CreatorId)
			end)
			if ok and type(r) == "number" then
				groupRanks[player] = r
				refreshRank(player)
			end
		end)
	end
	player:GetAttributeChangedSignal(Cfg.DebugAttribute):Connect(function()
		refreshRank(player)
	end)
	player.Chatted:Connect(function(msg: string)
		onChat(player, msg)
	end)
	player.CharacterAdded:Connect(function(c)
		onCharacter(player, c)
	end)
	if muted[player.UserId] then
		applyMute(player)
	end
end

--------------------------------------------------------------------------------------------- boot

function AdminService:Init(all: { [string]: any })
	services = all
end

function AdminService:Start()
	local Data = services.DataService
	local persistent = Data ~= nil and type(Data.IsPersistent) == "function" and Data:IsPersistent()
	if persistent then
		pcall(function()
			banStore = DataStoreService:GetDataStore(Cfg.BanStore)
		end)
		pcall(function()
			rankStore = (DataStoreService:GetDataStore(Cfg.RankStore) :: any) :: RankStore
			rankStoreKind = "datastore"
		end)
	end
	if not rankStore then
		rankStore = memoryRankStore()
		rankStoreKind = "memory"
	end
	loadGrants()
	if not IS_STUDIO then
		pcall(function()
			MessagingService:SubscribeAsync(Cfg.RankTopic, function(msg: any)
				if type(msg) == "table" and msg.Data ~= game.JobId then
					loadGrants()
				end
			end)
		end)
	end
	task.spawn(function()
		while true do
			task.wait(math.max(15, Cfg.RankRefreshSeconds))
			loadGrants()
		end
	end)

	local run = Net.event("Admin", "Run")
	resultRemote = Net.event("Admin", "Result")
	announceRemote = Net.event("Admin", "Announce")
	Net.onServer(run, { rate = 4, burst = 6 }, function(player: Player, text: any)
		if type(text) ~= "string" or #text > 500 then
			return
		end
		local ok, lines, open = execute(player, text, "console")
		reply(player, ok == true, lines, open, "console")
	end)

	pcall(hookTextChat)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		groupRanks[p] = nil
		buckets[p] = nil
		trollBuckets[p] = nil
		lastChat[p] = nil
	end)
end

------------------------------------------------------------------------------------------ hooks

-- ForgeTest / DevHook: run a command as `player` exactly like the console does.
function AdminService:_run(player: Player, text: string): string
	local ok, lines = execute(player, text, "console")
	return `{if ok then "ok" else "fail"}|{table.concat(lines, "\n")}`
end

function AdminService:_rank(player: Player): number
	return rankOf(player)
end

function AdminService:_logs(n: number?): string
	local out = {}
	for i = math.max(1, #logs - (n or 10) + 1), #logs do
		table.insert(out, Rules.logLine(logs[i]))
	end
	return table.concat(out, "\n")
end

function AdminService:_ban(userId: number, name: string, reason: string?): boolean
	return setBan(userId, { name = name, reason = reason or "test", by = "DevHook", at = os.time() })
end

function AdminService:_banned(userId: number): boolean
	return getBan(userId) ~= nil
end

function AdminService:_grants(): string
	local out = {}
	for id, g in grants do
		table.insert(out, `{id}={g.rank}`)
	end
	table.sort(out)
	return table.concat(out, ",")
end

-- A server restart as far as ranks go: forget this server's copy, re-read the store, re-rank everyone.
function AdminService:_restart(): string
	grants = {}
	nameCache = {}
	refreshAll()
	local ok = loadGrants()
	return `reloaded={ok} store={rankStoreKind} grants={self:_grants()}`
end

function AdminService:_selftest(): (boolean, string)
	local missing = {}
	for _, def in Commands.Commands do
		if not H[def.name] then
			table.insert(missing, def.name)
		end
	end
	local store = rankStoreKind
	return #missing == 0,
		`commands={#Commands.Commands} missing={table.concat(missing, ",")} persistentBans={banStore ~= nil} rankStore={store}`
end

return AdminService
