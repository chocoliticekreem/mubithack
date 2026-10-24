--!strict
-- AdminCommands [owner: Admin]. DATA ONLY: every Kohl's-style admin command, its minimum rank, its
-- arguments and its help line. Pure Luau (no Roblox APIs) so game/tests/admin.spec.luau loads it with
-- the `luau` CLI. AdminService (server) runs them; AdminController (client) shows :cmds and autocompletes
-- from the same list. The server never trusts the client: it re-checks the rank of every command.
--
-- Arg kinds (Lib/Admin/AdminRules.bind / complete):
--   players  one or more targets: me, all, others, random, @lobby, @squad, @<squad or call id>, #<UserId>,
--            partial names; comma-separated ("me,bob"). Optional players default to "me".
--   player   the same syntax, but it must resolve to exactly one player
--   number   a number (clamped by min/max)
--   word     one word;  text = the rest of the line
--   pass / item / mission / event / preset / rank   one word from a known list (autocomplete)
-- harmful = the command can only touch targets of a LOWER rank than the caller (or the caller).
-- troll   = a goofy, kid-safe, auto-reverting prank (TrollService). Targets of a HIGHER rank are skipped
--           (equal is fine; the Owner can troll anyone), `all` / `others` / @groups need Admin, and a
--           second, stricter rate limit applies (AdminConfig.Troll.Rate / Burst).
-- grant   = the rank a staff command saves (AdminRules.canGrant); targets may be offline (name / #UserId).

export type Arg = { name: string, kind: string, optional: boolean?, min: number?, max: number? }
export type Command = {
	name: string,
	aliases: { string }?,
	rank: number,
	args: { Arg },
	help: string,
	harmful: boolean?,
	troll: boolean?,
	grant: number?,
	group: string,
}

local AdminCommands = {}

AdminCommands.Ranks = table.freeze({ Player = 0, Mod = 1, Admin = 2, Owner = 3 })
AdminCommands.RankNames = table.freeze({ [0] = "Player", [1] = "Mod", [2] = "Admin", [3] = "Owner" })

local MOD, ADMIN, OWNER = 1, 2, 3

local function P(name: string?, optional: boolean?): Arg
	return { name = name or "players", kind = "players", optional = optional }
end

local Commands: { Command } = {
	-- info
	{ name = "cmds", aliases = { "commands", "help" }, rank = MOD, args = {}, group = "Info", help = "List the commands you can use" },
	{ name = "logs", aliases = { "log" }, rank = MOD, args = { { name = "count", kind = "number", optional = true, min = 1, max = 60 } }, group = "Info", help = "Show the latest admin commands (who, what, when)" },

	-- movement and body
	{ name = "tp", aliases = { "teleport" }, rank = MOD, args = { P("players"), { name = "destination", kind = "player" } }, group = "Movement", help = "Teleport players to another player" },
	{ name = "bring", rank = MOD, args = { P() }, group = "Movement", help = "Bring players to you" },
	{ name = "to", aliases = { "goto" }, rank = MOD, args = { { name = "player", kind = "player" } }, group = "Movement", help = "Go to a player" },
	{ name = "fly", rank = ADMIN, args = { P(nil, true) }, group = "Movement", help = "Let players fly (WASD, Space up, Ctrl down)" },
	{ name = "unfly", rank = ADMIN, args = { P(nil, true) }, group = "Movement", help = "Stop flying" },
	{ name = "noclip", rank = ADMIN, args = { P(nil, true) }, group = "Movement", help = "Walk through walls (run again or :clip to stop)" },
	{ name = "clip", rank = ADMIN, args = { P(nil, true) }, group = "Movement", help = "Turn noclip off" },
	{ name = "speed", aliases = { "ws", "walkspeed" }, rank = ADMIN, args = { P(), { name = "speed", kind = "number", min = 0, max = 200 } }, group = "Movement", help = "Set walk speed (default 16)" },
	{ name = "jump", aliases = { "jp", "jumppower" }, rank = ADMIN, args = { P(), { name = "power", kind = "number", min = 0, max = 300 } }, group = "Movement", help = "Set jump power (default 50)" },
	{ name = "heal", rank = MOD, args = { P(nil, true) }, group = "Body", help = "Full health, and revive if downed" },
	{ name = "kill", rank = ADMIN, args = { P() }, group = "Body", harmful = true, help = "Kill players" },
	{ name = "respawn", aliases = { "re", "refresh" }, rank = MOD, args = { P(nil, true) }, group = "Body", help = "Respawn players" },
	{ name = "god", rank = ADMIN, args = { P(nil, true) }, group = "Body", help = "Can't take damage" },
	{ name = "ungod", rank = ADMIN, args = { P(nil, true) }, group = "Body", help = "Turn god mode off" },
	{ name = "freeze", rank = MOD, args = { P() }, group = "Body", harmful = true, help = "Freeze players in place" },
	{ name = "thaw", aliases = { "unfreeze" }, rank = MOD, args = { P() }, group = "Body", help = "Unfreeze players" },
	{ name = "invisible", aliases = { "invis" }, rank = ADMIN, args = { P(nil, true) }, group = "Body", help = "Make players invisible" },
	{ name = "visible", aliases = { "vis" }, rank = ADMIN, args = { P(nil, true) }, group = "Body", help = "Make players visible again" },

	-- moderation
	{ name = "kick", rank = MOD, args = { P(), { name = "reason", kind = "text", optional = true } }, group = "Moderation", harmful = true, help = "Kick players with a reason" },
	{ name = "ban", rank = ADMIN, args = { P(), { name = "reason", kind = "text", optional = true } }, group = "Moderation", harmful = true, help = "Ban players (saved ban list) and kick them" },
	{ name = "unban", rank = ADMIN, args = { { name = "user", kind = "word" } }, group = "Moderation", help = "Unban a UserId or username" },
	{ name = "bans", aliases = { "banlist" }, rank = ADMIN, args = {}, group = "Moderation", help = "List banned players" },
	{ name = "mute", rank = MOD, args = { P() }, group = "Moderation", harmful = true, help = "Stop players from chatting" },
	{ name = "unmute", rank = MOD, args = { P() }, group = "Moderation", help = "Let players chat again" },
	{ name = "shutdown", rank = OWNER, args = { { name = "reason", kind = "text", optional = true } }, group = "Moderation", help = "Kick everyone and close this server" },

	-- staff: ranks are SAVED (they stick across servers and rejoins); targets can be offline
	{ name = "admins", aliases = { "staff", "ranks" }, rank = MOD, args = {}, group = "Staff", help = "List everyone with a rank, online or not" },
	{ name = "admin", rank = OWNER, args = { P() }, group = "Staff", grant = ADMIN, help = "Make players Admin (saved; Owner only)" },
	{ name = "mod", aliases = { "moderator" }, rank = ADMIN, args = { P() }, group = "Staff", grant = MOD, help = "Make players Mod (saved)" },
	{ name = "unadmin", aliases = { "unmod", "demote" }, rank = ADMIN, args = { P() }, group = "Staff", grant = 0, help = "Take a rank away: back to Player (saved)" },
	{ name = "setrank", aliases = { "rank" }, rank = ADMIN, args = { P(), { name = "rank", kind = "rank" } }, group = "Staff", help = "Set Player / Mod / Admin (saved; only the Owner grants Admin)" },

	-- messages
	{ name = "m", aliases = { "message", "announce" }, rank = MOD, args = { { name = "message", kind = "text" } }, group = "Messages", help = "Server announcement banner (chat-filtered)" },
	{ name = "h", aliases = { "hint" }, rank = MOD, args = { { name = "hint", kind = "text" } }, group = "Messages", help = "Small hint at the top of everyone's screen (chat-filtered)" },

	-- game
	{ name = "fire", aliases = { "ignite" }, rank = ADMIN, args = { P(nil, true) }, group = "Game", help = "Set something flammable on fire near the players" },
	{ name = "extinguish", aliases = { "ext" }, rank = ADMIN, args = { P(nil, true) }, group = "Game", help = "Put out the fires at the players' call (all = every fire)" },
	{ name = "mission", aliases = { "call" }, rank = ADMIN, args = { { name = "mission", kind = "mission" }, P(nil, true) }, group = "Game", help = "Start a call for the players' squad" },
	{ name = "endmission", aliases = { "endcall" }, rank = ADMIN, args = { P(nil, true) }, group = "Game", help = "End the players' call (all = every call)" },
	{ name = "give", rank = ADMIN, args = { P(), { name = "item", kind = "item" } }, group = "Game", help = "Give players a gear item" },
	{ name = "xp", rank = ADMIN, args = { P(), { name = "amount", kind = "number", min = 1, max = 100000 } }, group = "Game", help = "Award battle pass XP" },
	{ name = "level", aliases = { "lvl" }, rank = ADMIN, args = { P(), { name = "level", kind = "number", min = 1, max = 99 } }, group = "Game", help = "Set players' profile level" },
	{ name = "truck", rank = ADMIN, args = { P(nil, true) }, group = "Game", help = "Respawn the players' fire truck" },
	{ name = "event", rank = ADMIN, args = { { name = "event", kind = "event" }, P(nil, true) }, group = "Game", help = "Start a crazy event at the players' call" },
	{ name = "weather", aliases = { "sky" }, rank = ADMIN, args = { { name = "preset", kind = "preset" } }, group = "Game", help = "Change the lighting / weather preset" },

	-- troll: goofy, harmless, and every one reverts by itself (:normal reverts them all at once)
	{ name = "fling", aliases = { "yeet" }, rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "YEET them in a random direction" },
	{ name = "rocket", rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "Blast off straight up, then parachute down safely" },
	{ name = "spin", rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "Spin like a top for 5 s" },
	{ name = "tiny", aliases = { "small" }, rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "Shrink to half size for 30 s" },
	{ name = "giant", aliases = { "big" }, rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "Grow to double size for 30 s" },
	{ name = "bighead", rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "Huge head for 20 s" },
	{ name = "ragdoll", aliases = { "flop" }, rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "Go floppy for 4 s" },
	{ name = "noodle", rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "Wobbly noodle arms for 10 s" },
	{ name = "explode", aliases = { "boom", "kaboom" }, rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "Cartoon KABOOM: smoke and a fling, no damage" },
	{ name = "slap", rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "A big SLAP! (the hands slap)" },
	{ name = "jail", rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "Lock in a little cage for 60 s" },
	{ name = "unjail", rank = MOD, args = { P(nil, true) }, group = "Troll", help = "Let players out of jail" },
	{ name = "clone", rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "A harmless copy waddles around for 20 s" },
	{ name = "penguinrain", aliases = { "penguins" }, rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "Plushie penguins fall from the sky around them" },
	{ name = "dance", rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "Bust a move for 8 s" },
	{ name = "confetti", rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "Party confetti burst" },
	{ name = "sparkles", aliases = { "sparkle" }, rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "Sparkly for 15 s" },
	{ name = "fakeban", rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "A scary BANNED screen for 3 s... jk!" },
	{ name = "invert", rank = MOD, args = { P(nil, true) }, group = "Troll", troll = true, help = "Flip their controls for 10 s" },
	{ name = "normal", aliases = { "untroll", "unsize" }, rank = MOD, args = { P(nil, true) }, group = "Troll", help = "Undo every troll on players right now" },

	-- owner
	{ name = "giftpass", rank = OWNER, args = { P(), { name = "pass", kind = "pass" } }, group = "Owner", help = "Gift a game pass as an in-game entitlement (not a real Roblox pass)" },
	{ name = "revokepass", rank = OWNER, args = { P(), { name = "pass", kind = "pass" } }, group = "Owner", help = "Take back a gifted in-game pass entitlement" },
	{ name = "giftxp", rank = OWNER, args = { P(), { name = "amount", kind = "number", min = 1, max = 100000 } }, group = "Owner", help = "Gift profile XP + battle pass XP" },
	{ name = "donorboard", rank = OWNER, args = { { name = "action", kind = "word" } }, group = "Owner", help = "donorboard reset: wipe the Donation Board's top donors" },
}

AdminCommands.Commands = Commands

-- Values for the word-from-a-list kinds that don't depend on other configs.
AdminCommands.Lists = {
	pass = { "UnlimitedFoam", "PremiumPass" },
	rank = { "Player", "Mod", "Admin" },
	event = { "news_heli", "geyser_hydrant", "raccoon", "rainstorm", "wind_gust", "ice_cream" },
}

return AdminCommands
