--!strict
-- Lib/Admin/AdminRules (ranks, parser, targeting, rate limit, autocomplete) + AdminCommands data +
-- ProfileSchema v7 gifted passes.
local Spec = require("./Spec")
local R = require("../ReplicatedStorage/Lib/Admin/AdminRules")
local C = require("../ReplicatedStorage/Lib/Admin/AdminCommands")
local Schema = require("../ServerScriptService/Lib/Data/ProfileSchema")

local CMDS = C.Commands :: any
local NOW = 1_792_800_000

local ROSTER: { R.Who } = {
	{ userId = 1, name = "ArvinDev", displayName = "Arvin", squad = "S1", instance = "" },
	{ userId = 2, name = "bobby", displayName = "Bob", squad = "S1", instance = "" },
	{ userId = 3, name = "Bobcat", displayName = "Kitty", squad = "", instance = "run_7" },
	{ userId = 4, name = "zed", displayName = "Zed", squad = "S2", instance = "run_7" },
}

local function ids(list: { number }): string
	local c = table.clone(list)
	table.sort(c)
	local s = {}
	for _, v in c do
		table.insert(s, tostring(v))
	end
	return table.concat(s, ",")
end

------------------------------------------------------------------------------------------- ranks

Spec.test("creator (User) is Owner, everyone else Player", function()
	Spec.eq(R.rankOf({ userId = 42, creatorType = "User", creatorId = 42 }), 3)
	Spec.eq(R.rankOf({ userId = 7, creatorType = "User", creatorId = 42 }), 0)
end)

Spec.test("config lists give Owner / Admin / Mod", function()
	local ctx = { owners = { 10 }, admins = { 20 }, mods = { 30 }, creatorType = "User", creatorId = 1 }
	local function r(id: number): number
		local c = table.clone(ctx) :: any
		c.userId = id
		return R.rankOf(c)
	end
	Spec.eq(r(10), 3)
	Spec.eq(r(20), 2)
	Spec.eq(r(30), 1)
	Spec.eq(r(40), 0)
end)

Spec.test("group creator: rank thresholds", function()
	local g = { owner = 255, admin = 200, mod = 100 }
	Spec.eq(R.rankOf({ userId = 5, creatorType = "Group", creatorId = 9, groupRank = 255, groupRanks = g }), 3)
	Spec.eq(R.rankOf({ userId = 5, creatorType = "Group", creatorId = 9, groupRank = 210, groupRanks = g }), 2)
	Spec.eq(R.rankOf({ userId = 5, creatorType = "Group", creatorId = 9, groupRank = 100, groupRanks = g }), 1)
	Spec.eq(R.rankOf({ userId = 5, creatorType = "Group", creatorId = 9, groupRank = 1, groupRanks = g }), 0)
	-- a group creator id is never matched as a user id
	Spec.eq(R.rankOf({ userId = 9, creatorType = "Group", creatorId = 9, groupRank = 0, groupRanks = g }), 0)
end)

Spec.test("Studio dev override: the real Studio account owns a CreatorId-0 place, only in Studio", function()
	Spec.eq(R.rankOf({ userId = 123, creatorType = "User", creatorId = 0, isStudio = true, studioOwner = true }), 3)
	Spec.eq(R.rankOf({ userId = -1, creatorType = "User", creatorId = 0, isStudio = true, studioOwner = true }), 0)
	Spec.eq(R.rankOf({ userId = 123, creatorType = "User", creatorId = 0, isStudio = false, studioOwner = true }), 0)
end)

Spec.test("test override attribute only counts in Studio", function()
	Spec.eq(R.rankOf({ userId = 42, creatorType = "User", creatorId = 42, isStudio = true, override = 0 }), 0)
	Spec.eq(R.rankOf({ userId = 42, creatorType = "User", creatorId = 42, isStudio = false, override = 0 }), 3)
	Spec.eq(R.rankOf({ userId = 7, isStudio = false, override = 3 }), 0)
end)

Spec.test("a saved grant caps at Admin and never demotes an owner", function()
	Spec.eq(R.rankOf({ userId = 7, grantedRank = 2 }), 2)
	Spec.eq(R.rankOf({ userId = 7, grantedRank = 3 }), 2)
	Spec.eq(R.rankOf({ userId = 7, admins = { 7 }, grantedRank = 0 }), 0)
	Spec.eq(R.rankOf({ userId = 42, creatorType = "User", creatorId = 42, grantedRank = 0 }), 3)
end)

Spec.test("rankFromName", function()
	Spec.eq(R.rankFromName("admin"), 2)
	Spec.eq(R.rankFromName("Mod"), 1)
	Spec.eq(R.rankFromName("moderator"), 1)
	Spec.eq(R.rankFromName("0"), 0)
	Spec.eq(R.rankFromName("king"), nil)
end)

------------------------------------------------------------------------------------------ parser

Spec.test("tokenize keeps quoted words", function()
	local t = R.tokenize('  kick  bob "being very rude" now ')
	Spec.eq(#t, 4)
	Spec.eq(t[3], "being very rude")
end)

Spec.test("parse needs the chat prefix; console prefix is optional", function()
	Spec.eq(R.parse("hello there", { ":" }), nil)
	local p = R.parse(":Kick bob rude", { ":" }) :: R.Parsed
	Spec.eq(p.name, "kick")
	Spec.eq(#p.tokens, 2)
	local q = R.parse("fly me", { ":", ";", "" }) :: R.Parsed
	Spec.eq(q.name, "fly")
	local s = R.parse(";fly me", { ":", ";", "" }) :: R.Parsed
	Spec.eq(s.name, "fly")
	Spec.eq(R.parse(":", { ":" }), nil)
	Spec.eq(R.parse(":)", { ":" }), nil) -- smileys aren't commands
	Spec.eq(R.parse(nil, { ":" }), nil)
end)

Spec.test("find by name or alias", function()
	Spec.eq((R.find(CMDS, "teleport") :: any).name, "tp")
	Spec.eq((R.find(CMDS, "WS") :: any).name, "speed")
	Spec.eq(R.find(CMDS, "loadstring"), nil)
end)

Spec.test("no arbitrary code execution command exists", function()
	for _, bad in { "loadstring", "s", "script", "exec", "eval", "run", "lua", "require" } do
		Spec.eq(R.find(CMDS, bad), nil, bad)
	end
end)

Spec.test("every command has a known rank, group and help", function()
	local seen = {}
	for _, c in CMDS do
		Spec.truthy(c.rank >= 1 and c.rank <= 3, c.name)
		Spec.truthy(c.help ~= "" and c.group ~= "", c.name)
		Spec.eq(seen[c.name], nil, "dup " .. c.name)
		seen[c.name] = true
	end
	Spec.eq((R.find(CMDS, "giftpass") :: any).rank, 3)
	Spec.eq((R.find(CMDS, "revokepass") :: any).rank, 3)
	Spec.eq((R.find(CMDS, "shutdown") :: any).rank, 3)
	Spec.truthy(string.find((R.find(CMDS, "giftpass") :: any).help, "in-game entitlement", 1, true) ~= nil)
end)

Spec.test("bind: numbers clamp, text eats the rest, optional players default to me", function()
	local speed = R.find(CMDS, "speed") :: any
	local b = R.bind(speed, { "bob", "999" }) :: any
	Spec.eq(b.players, "bob")
	Spec.eq(b.speed, 200)
	local _, err = R.bind(speed, { "bob", "fast" })
	Spec.eq(err, "speed must be a number")
	local kick = R.bind(R.find(CMDS, "kick") :: any, { "bob", "stop", "spamming" }) :: any
	Spec.eq(kick.reason, "stop spamming")
	local fly = R.bind(R.find(CMDS, "fly") :: any, {}) :: any
	Spec.eq(fly.players, "me")
	local _, missing = R.bind(R.find(CMDS, "bring") :: any, {})
	Spec.eq(missing, "missing players")
	local _, extra = R.bind(R.find(CMDS, "bring") :: any, { "a", "b" })
	Spec.truthy(extra and string.find(extra, "too many"))
end)

Spec.test("bind: list kinds accept case-insensitive names and unique prefixes", function()
	local gift = R.find(CMDS, "giftpass") :: any
	local b = R.bind(gift, { "bob", "premiumpass" }, C.Lists) :: any
	Spec.eq(b.pass, "PremiumPass")
	local b2 = R.bind(gift, { "bob", "unl" }, C.Lists) :: any
	Spec.eq(b2.pass, "UnlimitedFoam")
	local _, err = R.bind(gift, { "bob", "VIP" }, C.Lists)
	Spec.truthy(err and string.find(err, "unknown pass"))
end)

------------------------------------------------------------------------------------------ targets

Spec.test("me / all / others", function()
	Spec.eq(ids((R.resolve("me", 1, ROSTER))), "1")
	Spec.eq(ids((R.resolve("all", 1, ROSTER))), "1,2,3,4")
	Spec.eq(ids((R.resolve("others", 1, ROSTER))), "2,3,4")
end)

Spec.test("partial names: exact name wins, else every prefix match (name or display)", function()
	Spec.eq(ids((R.resolve("bo", 1, ROSTER))), "2,3")
	Spec.eq(ids((R.resolve("bobby", 1, ROSTER))), "2")
	Spec.eq(ids((R.resolve("kit", 1, ROSTER))), "3")
	Spec.eq(ids((R.resolve("ZE", 1, ROSTER))), "4")
end)

Spec.test("display-name exact match beats prefixes", function()
	-- "bob" exactly equals display "Bob" (userId 2), so Bobcat is not included
	Spec.eq(ids((R.resolve("bob", 1, ROSTER))), "2")
end)

Spec.test("@lobby / @squad / @<id> / #UserId / comma lists", function()
	Spec.eq(ids((R.resolve("@lobby", 1, ROSTER))), "1,2")
	Spec.eq(ids((R.resolve("@squad", 1, ROSTER))), "1,2") -- same SquadId S1
	Spec.eq(ids((R.resolve("@squad", 3, ROSTER))), "3,4") -- same call run_7
	Spec.eq(ids((R.resolve("@run_7", 1, ROSTER))), "3,4")
	Spec.eq(ids((R.resolve("#4", 1, ROSTER))), "4")
	Spec.eq(ids((R.resolve("me,zed,me", 1, ROSTER))), "1,4")
end)

Spec.test("no match is an error", function()
	local out, err = R.resolve("nobody", 1, ROSTER)
	Spec.eq(#out, 0)
	Spec.truthy(err and string.find(err, "nobody"))
end)

Spec.test("random uses the service's pick", function()
	Spec.eq(ids((R.resolve("random", 1, ROSTER, 3))), "3")
end)

---------------------------------------------------------------------------------------- policies

Spec.test("canRun by rank", function()
	local gift = R.find(CMDS, "giftpass") :: any
	Spec.eq(R.canRun(2, gift), false)
	Spec.eq(R.canRun(3, gift), true)
	Spec.eq(R.canRun(0, R.find(CMDS, "cmds") :: any), false)
end)

Spec.test("canAffect: lower ranks only, self always, owner anyone", function()
	Spec.eq(R.canAffect(1, 0, false), true)
	Spec.eq(R.canAffect(1, 1, false), false)
	Spec.eq(R.canAffect(2, 3, false), false)
	Spec.eq(R.canAffect(2, 2, true), true)
	Spec.eq(R.canAffect(3, 3, false), true)
end)

Spec.test("rate limit: burst then refill", function()
	local b = {}
	local n = 0
	for _ = 1, 10 do
		if R.allow(b, 0, 2, 4) then
			n += 1
		end
	end
	Spec.eq(n, 4)
	Spec.eq(R.allow(b, 0.2, 2, 4), false)
	Spec.eq(R.allow(b, 0.6, 2, 4), true)
end)

--------------------------------------------------------------------------------------- help/complete

Spec.test("help lists only what the rank can run", function()
	local mod = table.concat(R.helpLines(CMDS, 1), "\n")
	Spec.truthy(string.find(mod, ":kick", 1, true))
	Spec.eq(string.find(mod, ":giftpass", 1, true), nil)
	local owner = table.concat(R.helpLines(CMDS, 3), "\n")
	Spec.truthy(string.find(owner, ":giftpass <players> <pass>", 1, true))
	Spec.eq(#R.helpLines(CMDS, 0), 0)
end)

Spec.test("complete command names, players and lists", function()
	local a = R.complete(":gi", CMDS, 3, {}, C.Lists)
	Spec.eq(table.concat(a, "|"), ":give |:giant |:giftpass |:giftxp ")
	Spec.eq(#R.complete(":gi", CMDS, 2, {}, C.Lists), 2) -- admins don't see giftpass/giftxp
	local p = R.complete(":kick bo", CMDS, 1, { "bobby", "Bobcat", "zed" }, C.Lists)
	Spec.eq(table.concat(p, "|"), ":kick bobby |:kick Bobcat ")
	local l = R.complete(":giftpass bobby Pr", CMDS, 3, { "bobby" }, C.Lists)
	Spec.eq(l[1], ":giftpass bobby PremiumPass")
	local comma = R.complete(":bring me,z", CMDS, 1, { "zed" }, C.Lists)
	Spec.eq(comma[1], ":bring me,zed")
	Spec.eq(R.complete("fl", CMDS, 2, {}, C.Lists)[1], ":fly ")
end)

Spec.test("log line", function()
	local line = R.logLine({ at = 3661, by = "Arvin", rank = 3, text = ":fly me", ok = true, result = "1 player" })
	Spec.eq(line, "[01:01:01] Arvin (Owner): :fly me -> 1 player")
end)

------------------------------------------------------------------------------- ProfileSchema gifts

Spec.test("ProfileSchema v7 adds gifts and migrates v6", function()
	Spec.eq(Schema.Version >= 7, true)
	local p = Schema.default(NOW)
	Spec.eq(type(p.gifts.passes), "table")
	local v6 = Schema.default(NOW) :: any
	v6.version = 6
	v6.gifts = nil
	local m = Schema.migrate(v6, NOW) :: any
	Spec.eq(m.version, Schema.Version)
	Spec.eq(next(m.gifts.passes), nil)
end)

Spec.test("giftPass / revokePass are idempotent and reconcile drops junk", function()
	local p = Schema.default(NOW)
	Spec.eq(Schema.giftPass(p, "PremiumPass", 42, NOW), true)
	Spec.eq(Schema.giftPass(p, "PremiumPass", 42, NOW), false)
	Spec.eq(Schema.hasGift(p, "PremiumPass"), true)
	Spec.eq(Schema.giftPass(p, "", 42, NOW), false)
	Spec.eq(table.concat(Schema.giftedPasses(p), ","), "PremiumPass")
	Spec.eq(Schema.revokePass(p, "PremiumPass"), true)
	Spec.eq(Schema.revokePass(p, "PremiumPass"), false)
	Spec.eq(Schema.hasGift(p, "PremiumPass"), false)
	local raw = Schema.default(NOW) :: any
	raw.gifts.passes = { UnlimitedFoam = { by = 1, at = 2 }, [5] = true, Bad = "x" }
	local r = Schema.reconcile(raw, NOW) :: any
	Spec.eq(table.concat(Schema.giftedPasses(r), ","), "UnlimitedFoam")
end)

Spec.test("xpForLevel lands exactly on the level", function()
	for _, lvl in { 1, 2, 5, 20, 99 } do
		Spec.eq((Schema.levelForXp(Schema.xpForLevel(lvl))), lvl)
	end
	Spec.eq(Schema.xpForLevel(1), 0)
	Spec.eq(Schema.xpForLevel(2), 100)
end)

--------------------------------------------------------------------------------- saved ranks

Spec.test("canGrant: Owner grants up to Admin, Admin grants Mod, nobody touches self or Owner", function()
	Spec.eq((R.canGrant(3, 0, 2, false)), true) -- owner makes an admin
	Spec.eq((R.canGrant(3, 2, 0, false)), true) -- owner un-admins
	Spec.eq((R.canGrant(2, 0, 1, false)), true) -- admin makes a mod
	Spec.eq((R.canGrant(2, 1, 0, false)), true) -- admin un-mods
	local ok, why = R.canGrant(2, 0, 2, false)
	Spec.eq(ok, false)
	Spec.truthy(why and string.find(why, "Owner"))
	Spec.eq((R.canGrant(2, 2, 0, false)), false) -- admin can't demote an admin
	Spec.eq((R.canGrant(1, 0, 1, false)), false) -- mods can't grant
	Spec.eq((R.canGrant(3, 3, 0, false)), false) -- nobody changes an owner
	Spec.eq((R.canGrant(3, 0, 3, false)), false) -- can't mint owners
	Spec.eq((R.canGrant(2, 1, 1, true)), false) -- not your own rank
end)

Spec.test("grantAction: store, clear back to the config default, or nothing", function()
	Spec.eq(R.grantAction(0, nil, 2), "set")
	Spec.eq(R.grantAction(0, 2, 2), "same")
	Spec.eq(R.grantAction(0, 2, 0), "clear") -- :unadmin a granted admin: drop the record
	Spec.eq(R.grantAction(2, nil, 0), "set") -- :unadmin a config admin: a saved 0 overrides the list
	Spec.eq(R.grantAction(2, 0, 2), "clear") -- back to the config admin rank
	Spec.eq(R.grantAction(0, nil, 0), "same")
end)

Spec.test("a saved grant overrides the config lists (rejoin / new server uses the same record)", function()
	local ctx = { userId = 7, admins = { 7 }, creatorType = "User", creatorId = 1 } :: any
	Spec.eq(R.rankOf(ctx), 2)
	ctx.grantedRank = 0
	Spec.eq(R.rankOf(ctx), 0)
	ctx.grantedRank = 1
	Spec.eq(R.rankOf(ctx), 1)
	Spec.eq(R.rankOf({ userId = 9, grantedRank = 2 }), 2)
end)

Spec.test("staff commands: :admin is Owner only, :mod / :unadmin / :setrank Admin, :admins Mod", function()
	Spec.eq((R.find(CMDS, "admin") :: any).rank, 3)
	Spec.eq((R.find(CMDS, "mod") :: any).rank, 2)
	Spec.eq((R.find(CMDS, "unadmin") :: any).rank, 2)
	Spec.eq((R.find(CMDS, "unmod") :: any).name, "unadmin")
	Spec.eq((R.find(CMDS, "setrank") :: any).rank, 2)
	Spec.eq((R.find(CMDS, "admins") :: any).rank, 1)
	Spec.eq((R.find(CMDS, "admin") :: any).grant, 2)
	Spec.eq((R.find(CMDS, "mod") :: any).grant, 1)
	Spec.eq((R.find(CMDS, "unadmin") :: any).grant, 0)
end)

Spec.test(":admins lines: highest rank first, offline included, players left out", function()
	local lines = R.staffLines({
		{ userId = 5, name = "zed", rank = 1, source = "saved by Arvin", online = false },
		{ userId = 1, name = "Arvin", rank = 3, source = "creator", online = true },
		{ userId = 6, name = "amy", rank = 2, source = "config", online = false },
		{ userId = 8, name = "kid", rank = 0, source = "saved by Arvin", online = true },
	})
	Spec.eq(#lines, 3)
	Spec.truthy(string.find(lines[1], "Owner: Arvin", 1, true))
	Spec.truthy(string.find(lines[2], "Admin: amy (#6) - config", 1, true))
	Spec.truthy(string.find(lines[3], "Mod: zed", 1, true))
	Spec.eq(string.find(lines[3], "online", 1, true), nil)
end)

-------------------------------------------------------------------------------------------- trolls

local TROLLS = {
	"fling", "rocket", "spin", "tiny", "giant", "bighead", "ragdoll", "noodle", "explode", "slap", "jail",
	"clone", "penguinrain", "dance", "confetti", "sparkles", "fakeban", "invert",
}

Spec.test("every troll command exists, is Mod+, a troll, and shows in :cmds with help", function()
	local help = table.concat(R.helpLines(CMDS, 1), "\n")
	Spec.truthy(string.find(help, "== TROLL ==", 1, true))
	for _, name in TROLLS do
		local c = R.find(CMDS, name) :: any
		Spec.truthy(c ~= nil, name)
		Spec.eq(c.rank, 1, name)
		Spec.eq(c.troll, true, name)
		Spec.eq(c.group, "Troll", name)
		Spec.truthy(string.find(help, ":" .. name .. " [players]", 1, true), name)
	end
	for _, name in { "normal", "unjail" } do
		local c = R.find(CMDS, name) :: any
		Spec.eq(c.rank, 1, name)
		Spec.truthy(not c.troll, name .. " is a revert, not a troll")
	end
	Spec.eq((R.find(CMDS, "kaboom") :: any).name, "explode")
	Spec.eq((R.find(CMDS, "untroll") :: any).name, "normal")
end)

Spec.test("canTroll: not a higher rank; equal is fine; the Owner trolls anyone; self always", function()
	Spec.eq(R.canTroll(1, 0, false), true)
	Spec.eq(R.canTroll(1, 1, false), true)
	Spec.eq(R.canTroll(1, 2, false), false)
	Spec.eq(R.canTroll(2, 3, false), false)
	Spec.eq(R.canTroll(3, 3, false), true)
	Spec.eq(R.canTroll(1, 3, true), true)
end)

Spec.test("massTarget: all / everyone / others / @groups anywhere in the list", function()
	Spec.eq(R.massTarget("all"), true)
	Spec.eq(R.massTarget("me,Others"), true)
	Spec.eq(R.massTarget(" everyone "), true)
	Spec.eq(R.massTarget("@lobby"), true)
	Spec.eq(R.massTarget("me"), false)
	Spec.eq(R.massTarget("bob,zed"), false)
	Spec.eq(R.massTarget("#12"), false)
	Spec.eq(R.massTarget("allison"), false) -- a name that starts with "all" is one player
end)

--------------------------------------------------------------------------------------- gift fanfare

local Fanfare = require("../ServerScriptService/Lib/Monetization/FanfareText")
local PASSES = {
	{ key = "UnlimitedFoam", name = "UNLIMITED FOAM", perk = "Unlimited Foam: your extinguisher never runs out!" },
	{ key = "PremiumPass", name = "PREMIUM PASS", blurb = "Gold track." },
}

Spec.test("fanfare words: gift, purchase and donation", function()
	local g = Fanfare.build({ kind = "gift", receiver = "Bob", giver = "Arvin", pass = "PremiumPass" }, PASSES)
	Spec.eq(g.banner, "🎁 ARVIN GIFTED BOB THE PREMIUM PASS!")
	Spec.truthy(string.find(g.chat, "Arvin gifted Bob the Premium Pass", 1, true))
	Spec.eq(g.title, "YOU GOT A GIFT!")
	Spec.truthy(string.find(g.body, "Premium Pass: Gold track.", 1, true))
	local p = Fanfare.build({ kind = "pass", receiver = "Bob", pass = "UnlimitedFoam" }, PASSES)
	Spec.eq(p.banner, "⭐ BOB JUST GOT UNLIMITED FOAM!")
	Spec.eq(p.body, "You now have Unlimited Foam: your extinguisher never runs out!")
	local d = Fanfare.build({ kind = "donate", receiver = "Bob", robux = 100 }, PASSES)
	Spec.eq(d.banner, "💖 BOB DONATED R$ 100 TO STATION 67!")
	Spec.truthy(string.find(d.body, "Donation Board", 1, true))
end)

Spec.test("fanfare words survive odd input", function()
	local g = Fanfare.build({ kind = "gift", receiver = "  ", giver = nil, pass = "Nope" }, PASSES)
	Spec.truthy(string.find(g.banner, "SOMEONE GIFTED SOMEONE THE NOPE", 1, true))
	Spec.eq(Fanfare.titleCase("UNLIMITED FOAM"), "Unlimited Foam")
	local long = Fanfare.build({ kind = "pass", receiver = string.rep("x", 80), pass = "UnlimitedFoam" }, PASSES)
	Spec.truthy(#long.banner < 80)
end)

return Spec.finish()
