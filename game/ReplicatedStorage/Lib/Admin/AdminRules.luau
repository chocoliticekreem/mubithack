--!strict
-- AdminRules [owner: Admin]. PURE: rank resolution, the command parser, target selection, rate limiting,
-- autocomplete and help text for the Kohl's-style admin system. No Roblox APIs (no game, Players,
-- Instance, task, os.time), so game/tests/admin.spec.luau runs it with the `luau` CLI.
-- AdminService (server) is the only thing that acts on a parsed command; AdminController (client) uses
-- complete/helpLines for the console only.
--
--   AdminRules.rankOf(ctx: RankCtx): number                     -- 0 Player, 1 Mod, 2 Admin, 3 Owner
--   AdminRules.rankFromName(s): number?                          -- "admin" | "2" -> 2
--   AdminRules.tokenize(s): { string }                           -- whitespace split, "quoted words" kept
--   AdminRules.parse(text, prefixes): Parsed?                    -- nil = not a command
--   AdminRules.find(commands, name): Command?                    -- by name or alias, case-insensitive
--   AdminRules.bind(def, tokens, lists?): (Bound?, string?)      -- validate args against the def
--   AdminRules.resolve(spec, callerId, roster, pick?): ({ number }, string?)  -- target UserIds
--   AdminRules.canRun(rank, def): boolean
--   AdminRules.canAffect(callerRank, targetRank, isSelf): boolean
--   AdminRules.allow(bucket, now, rate, burst): boolean          -- token bucket (mutates bucket)
--   AdminRules.usage(def): string                                -- ":tp <players> <destination>"
--   AdminRules.helpLines(commands, rank): { string }
--   AdminRules.complete(input, commands, rank, names, lists): { string }  -- full-line suggestions
--   AdminRules.clock(seconds): string                            -- UTC "hh:mm:ss"
--   AdminRules.logLine(entry): string

local AdminRules = {}

export type Arg = { name: string, kind: string, optional: boolean?, min: number?, max: number? }
export type Command = {
	name: string,
	aliases: { string }?,
	rank: number,
	args: { Arg },
	help: string,
	harmful: boolean?,
	group: string,
}

-- Everything rankOf needs, gathered by the caller (AdminService) from game/Players/RunService.
export type RankCtx = {
	userId: number,
	owners: { number }?,
	admins: { number }?,
	mods: { number }?,
	creatorType: string?, -- "User" | "Group"
	creatorId: number?,
	groupRank: number?, -- the player's rank in the creator group (0 = not a member)
	groupRanks: { owner: number?, admin: number?, mod: number? }?,
	isStudio: boolean?,
	studioOwner: boolean?, -- Studio dev override: a real Studio account (UserId > 0) is Owner
	sessionRank: number?, -- granted by :setrank for this server only
	override: number?, -- Studio-only test override (attribute AdminRankDebug); ignored outside Studio
}

export type Parsed = { name: string, tokens: { string } }
export type Bound = { [string]: any }
-- One player as targeting sees it (AdminService builds these from Players).
export type Who = { userId: number, name: string, displayName: string, squad: string?, instance: string? }

local RANK_NAMES = { [0] = "Player", [1] = "Mod", [2] = "Admin", [3] = "Owner" }
local OWNER = 3

local function has(list: { number }?, id: number): boolean
	return type(list) == "table" and table.find(list, id) ~= nil
end

------------------------------------------------------------------------------------------- ranks

function AdminRules.rankOf(ctx: RankCtx): number
	local id = ctx.userId
	if ctx.isStudio == true and type(ctx.override) == "number" then
		return math.clamp(math.floor(ctx.override), 0, OWNER)
	end
	local rank = 0
	if ctx.creatorType == "User" and type(ctx.creatorId) == "number" and ctx.creatorId > 0 and id == ctx.creatorId then
		rank = OWNER
	elseif has(ctx.owners, id) then
		rank = OWNER
	elseif ctx.isStudio == true and ctx.studioOwner == true and id > 0 then
		rank = OWNER -- Studio dev override: a local place has CreatorId 0, the Studio user owns it
	end
	if rank < OWNER and ctx.creatorType == "Group" and type(ctx.groupRank) == "number" and ctx.groupRank > 0 then
		local g = ctx.groupRanks or {}
		if type(g.owner) == "number" and ctx.groupRank >= g.owner then
			rank = OWNER
		elseif type(g.admin) == "number" and ctx.groupRank >= g.admin then
			rank = math.max(rank, 2)
		elseif type(g.mod) == "number" and ctx.groupRank >= g.mod then
			rank = math.max(rank, 1)
		end
	end
	if rank < 2 and has(ctx.admins, id) then
		rank = 2
	end
	if rank < 1 and has(ctx.mods, id) then
		rank = 1
	end
	if rank < OWNER and type(ctx.sessionRank) == "number" then
		rank = math.clamp(math.floor(ctx.sessionRank), 0, 2) -- :setrank can't mint owners or demote one
	end
	return rank
end

function AdminRules.rankName(rank: number): string
	return RANK_NAMES[rank] or "Player"
end

function AdminRules.rankFromName(s: any): number?
	if type(s) == "number" then
		return if RANK_NAMES[s] then s else nil
	end
	if type(s) ~= "string" then
		return nil
	end
	local n = tonumber(s)
	if n and RANK_NAMES[n] then
		return n
	end
	local l = string.lower(s)
	for r, name in RANK_NAMES do
		if string.lower(name) == l then
			return r
		end
	end
	if l == "moderator" then
		return 1
	elseif l == "none" or l == "user" then
		return 0
	end
	return nil
end

------------------------------------------------------------------------------------------ parser

function AdminRules.tokenize(s: string): { string }
	local out: { string } = {}
	local i, n = 1, #s
	while i <= n do
		local c = string.sub(s, i, i)
		if string.match(c, "%s") then
			i += 1
		elseif c == '"' then
			local close = string.find(s, '"', i + 1, true)
			local stop = close or (n + 1)
			table.insert(out, string.sub(s, i + 1, stop - 1))
			i = stop + 1
		else
			local stop = string.find(s, "%s", i) or (n + 1)
			table.insert(out, string.sub(s, i, stop - 1))
			i = stop
		end
	end
	return out
end

-- text = ":kick bob being rude". prefixes = { ":" } (chat) or { ":", ";", "" } (console, prefix optional).
function AdminRules.parse(text: any, prefixes: { string }): Parsed?
	if type(text) ~= "string" then
		return nil
	end
	local s = string.match(text, "^%s*(.-)%s*$") or ""
	if s == "" or #s > 500 then
		return nil
	end
	local body: string? = nil
	for _, p in prefixes do
		if p == "" then
			body = body or s
		elseif string.sub(s, 1, #p) == p then
			body = string.sub(s, #p + 1)
			break
		end
	end
	if not body or body == "" then
		return nil
	end
	local tokens = AdminRules.tokenize(body)
	local name = table.remove(tokens, 1)
	if not name or not string.match(name, "^[%a][%w_]*$") then
		return nil
	end
	return { name = string.lower(name), tokens = tokens }
end

function AdminRules.find(commands: { Command }, name: string): Command?
	local l = string.lower(name)
	for _, c in commands do
		if c.name == l then
			return c
		end
	end
	for _, c in commands do
		for _, a in c.aliases or {} do
			if a == l then
				return c
			end
		end
	end
	return nil
end

local function fromList(list: { string }?, word: string): string?
	if type(list) ~= "table" then
		return word -- unknown list: let the service validate
	end
	local l = string.lower(word)
	for _, v in list do
		if string.lower(v) == l then
			return v
		end
	end
	local hit: string? = nil
	for _, v in list do
		if string.sub(string.lower(v), 1, #l) == l then
			if hit then
				return nil -- ambiguous prefix
			end
			hit = v
		end
	end
	return hit
end

-- Validates tokens against def.args. Returns { [arg.name] = value } (players/player stay raw specs; the
-- service resolves them against the live roster). Missing optional players default to "me".
function AdminRules.bind(def: Command, tokens: { string }, lists: { [string]: { string } }?): (Bound?, string?)
	local out: Bound = {}
	local i = 1
	for idx, arg in def.args do
		local tok = tokens[i]
		if arg.kind == "text" then
			if tok == nil then
				if not arg.optional then
					return nil, `missing {arg.name}`
				end
				out[arg.name] = ""
			else
				out[arg.name] = table.concat(tokens, " ", i)
				i = #tokens + 1
			end
			continue
		end
		if tok == nil then
			if not arg.optional then
				return nil, `missing {arg.name}`
			end
			if arg.kind == "players" or arg.kind == "player" then
				out[arg.name] = "me"
			end
			continue
		end
		if arg.kind == "number" then
			local n = tonumber(tok)
			if not n or n ~= n or n == math.huge or n == -math.huge then
				return nil, `{arg.name} must be a number`
			end
			if arg.min then
				n = math.max(arg.min, n)
			end
			if arg.max then
				n = math.min(arg.max, n)
			end
			out[arg.name] = n
		elseif arg.kind == "players" or arg.kind == "player" or arg.kind == "word" then
			out[arg.name] = tok
		else
			local v = fromList(lists and lists[arg.kind], tok)
			if not v then
				return nil, `unknown {arg.name} "{tok}"`
			end
			out[arg.name] = v
		end
		i += 1
		local _ = idx
	end
	if tokens[i] ~= nil then
		return nil, `too many arguments (usage: {AdminRules.usage(def)})`
	end
	return out, nil
end

------------------------------------------------------------------------------------------ targets

local function lower(s: string?): string
	return string.lower(s or "")
end

-- spec: "me" | "all" | "others" | "random" | "@lobby" | "@squad" | "@<squad or call id>" | "#<UserId>" |
-- a (partial) name or display name; comma-separated. Exact name beats display name beats prefix.
function AdminRules.resolve(spec: string, callerId: number, roster: { Who }, pick: number?): ({ number }, string?)
	local out: { number } = {}
	local seen: { [number]: boolean } = {}
	local function add(id: number)
		if not seen[id] then
			seen[id] = true
			table.insert(out, id)
		end
	end
	local caller: Who? = nil
	for _, w in roster do
		if w.userId == callerId then
			caller = w
		end
	end
	local missing: { string } = {}
	for part in string.gmatch(spec, "[^,]+") do
		local p = lower(string.match(part, "^%s*(.-)%s*$"))
		local before = #out
		if p == "me" then
			if caller then
				add(callerId)
			end
		elseif p == "all" or p == "everyone" then
			for _, w in roster do
				add(w.userId)
			end
		elseif p == "others" then
			for _, w in roster do
				if w.userId ~= callerId then
					add(w.userId)
				end
			end
		elseif p == "random" then
			if #roster > 0 then
				-- pick = the service's math.random(#roster); pure fallback: the first player
				local i = math.clamp(math.floor(pick or 1), 1, #roster)
				add(roster[i].userId)
			end
		elseif string.sub(p, 1, 1) == "@" then
			local tag = string.sub(p, 2)
			for _, w in roster do
				local squad, inst = lower(w.squad), lower(w.instance)
				if tag == "lobby" then
					if inst == "" then
						add(w.userId)
					end
				elseif tag == "squad" or tag == "team" then
					if caller then
						local cs, ci = lower(caller.squad), lower(caller.instance)
						if (ci ~= "" and inst == ci) or (cs ~= "" and squad == cs) or w.userId == callerId then
							add(w.userId)
						end
					end
				elseif tag ~= "" and (squad == tag or inst == tag) then
					add(w.userId)
				end
			end
		elseif string.sub(p, 1, 1) == "#" then
			local id = tonumber(string.sub(p, 2))
			for _, w in roster do
				if w.userId == id then
					add(w.userId)
				end
			end
		elseif p ~= "" then
			local exact: Who? = nil
			for _, w in roster do
				if lower(w.name) == p then
					exact = w
				end
			end
			if not exact then
				for _, w in roster do
					if lower(w.displayName) == p then
						exact = w
					end
				end
			end
			if exact then
				add(exact.userId)
			else
				for _, w in roster do
					if string.sub(lower(w.name), 1, #p) == p or string.sub(lower(w.displayName), 1, #p) == p then
						add(w.userId)
					end
				end
			end
		end
		if #out == before and p ~= "" then
			table.insert(missing, p)
		end
	end
	if #out == 0 then
		return out, if #missing > 0 then `no player matches "{table.concat(missing, ",")}"` else "no players"
	end
	return out, nil
end

---------------------------------------------------------------------------------------- policies

function AdminRules.canRun(rank: number, def: Command): boolean
	return rank >= def.rank
end

-- Kohl's rule: you can't act on someone of your own rank or higher (owners can; anyone can on themself).
function AdminRules.canAffect(callerRank: number, targetRank: number, isSelf: boolean): boolean
	return isSelf or callerRank >= OWNER or callerRank > targetRank
end

-- Token bucket: `rate` commands/second sustained, `burst` extra. Mutates bucket { tokens, at }.
function AdminRules.allow(bucket: { tokens: number?, at: number? }, now: number, rate: number, burst: number): boolean
	local cap = math.max(1, burst)
	local have = math.min(cap, (bucket.tokens or cap) + (now - (bucket.at or now)) * rate)
	bucket.at = now
	if have < 1 then
		bucket.tokens = have
		return false
	end
	bucket.tokens = have - 1
	return true
end

------------------------------------------------------------------------------------------- help

function AdminRules.usage(def: Command): string
	local parts = { ":" .. def.name }
	for _, a in def.args do
		table.insert(parts, if a.optional then `[{a.name}]` else `<{a.name}>`)
	end
	return table.concat(parts, " ")
end

function AdminRules.helpLines(commands: { Command }, rank: number): { string }
	local out: { string } = {}
	local group = ""
	for _, c in commands do
		if rank >= c.rank then
			if c.group ~= group then
				group = c.group
				table.insert(out, `== {string.upper(group)} ==`)
			end
			table.insert(out, `{AdminRules.usage(c)}  - {c.help}`)
		end
	end
	return out
end

local SPECIAL_TARGETS = { "me", "all", "others", "random", "@lobby", "@squad" }

-- Suggestions for the console: whole-line completions of the word under the cursor (the last one).
function AdminRules.complete(input: string, commands: { Command }, rank: number, names: { string }, lists: { [string]: { string } }?): { string }
	local out: { string } = {}
	local prefix = string.match(input, "^%s*([:;]?)") or ""
	local body = string.sub(string.match(input, "^%s*(.*)$") or "", #prefix + 1)
	local endsWithSpace = string.match(body, "%s$") ~= nil
	local tokens = AdminRules.tokenize(body)
	if endsWithSpace then
		table.insert(tokens, "")
	end
	local lead = if prefix == "" then ":" else prefix
	if #tokens <= 1 then
		local w = string.lower(tokens[1] or "")
		for _, c in commands do
			if rank >= c.rank and string.sub(c.name, 1, #w) == w then
				table.insert(out, lead .. c.name .. (if #c.args > 0 then " " else ""))
			end
		end
		return out
	end
	local def = AdminRules.find(commands, tokens[1])
	if not def or rank < def.rank then
		return out
	end
	local argIndex = #tokens - 1
	local arg = def.args[argIndex]
	if not arg then
		return out
	end
	local word = tokens[#tokens]
	local head = lead .. table.concat(tokens, " ", 1, #tokens - 1) .. " "
	local pool: { string } = {}
	if arg.kind == "players" or arg.kind == "player" then
		-- complete the last comma part
		local before, last = string.match(word, "^(.*,)([^,]*)$")
		local stem = before or ""
		word = last or word
		for _, s in SPECIAL_TARGETS do
			table.insert(pool, stem .. s)
		end
		for _, n in names do
			table.insert(pool, stem .. n)
		end
		word = stem .. word
	elseif lists and lists[arg.kind] then
		pool = lists[arg.kind]
	elseif arg.kind == "word" and def.name == "donorboard" then
		pool = { "reset" }
	end
	local lw = string.lower(word)
	for _, v in pool do
		if string.sub(string.lower(v), 1, #lw) == lw then
			table.insert(out, head .. v .. (if argIndex < #def.args then " " else ""))
		end
		if #out >= 12 then
			break
		end
	end
	return out
end

-------------------------------------------------------------------------------------------- logs

function AdminRules.clock(seconds: number): string
	local s = math.floor(seconds) % 86400
	return string.format("%02d:%02d:%02d", s // 3600, (s // 60) % 60, s % 60)
end

export type LogEntry = { at: number, by: string, rank: number, text: string, ok: boolean, result: string }

function AdminRules.logLine(e: LogEntry): string
	return `[{AdminRules.clock(e.at)}] {e.by} ({AdminRules.rankName(e.rank)}): {e.text} -> {if e.ok then "" else "FAILED: "}{e.result}`
end

return AdminRules
