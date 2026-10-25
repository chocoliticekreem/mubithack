--!strict
-- Lib/Social/AskRules: when the "Having fun? 👍" card and the invite asks may show.
local Spec = require("./Spec")
local AskRules = require("../ReplicatedStorage/Lib/Social/AskRules")

local ME = 42

local function payload(stars: number, extra: { [string]: any }?): any
	local p: any = { stars = stars, stats = { { userId = ME }, { userId = 7 } } }
	for k, v in extra or {} do
		p[k] = v
	end
	return p
end

Spec.test("happy: 2+ stars on a call you were on", function()
	Spec.eq(AskRules.happy(payload(2), ME, false), true)
	Spec.eq(AskRules.happy(payload(3), ME, false), true)
	Spec.eq(AskRules.happy(payload(1), ME, false), false, "one star is not a happy moment")
	Spec.eq(AskRules.happy(payload(0), ME, false), false)
	Spec.eq(AskRules.happy(payload(3), 999, false), false, "not on that call")
	Spec.eq(AskRules.happy({ stars = 2 }, ME, false), true, "no stats list: trust the stars")
end)

Spec.test("happy: a level up counts, a timed-out rookie call never does", function()
	Spec.eq(AskRules.happy(payload(1), ME, true), true, "level up on a 1-star call")
	Spec.eq(AskRules.happy(nil, ME, true), true, "level up at the station")
	Spec.eq(AskRules.happy(payload(1, { rookieWin = true }), ME, false), false)
	Spec.eq(AskRules.happy(payload(2, { rookieWin = true }), ME, true), false, "even with a level up")
	Spec.eq(AskRules.happy(payload(3, { rookie = true }), ME, false), true, "a rookie call won for real is fine")
end)

Spec.test("canAsk: once per session, MaxEver ever, only once the profile is loaded", function()
	Spec.eq(AskRules.canAsk({ loaded = true, askedThisSession = 0, ever = 0 }), true)
	Spec.eq(AskRules.canAsk({ loaded = false, askedThisSession = 0, ever = 0 }), false)
	Spec.eq(AskRules.canAsk({ loaded = true, askedThisSession = 1, ever = 1 }), false, "once per session")
	Spec.eq(AskRules.canAsk({ loaded = true, askedThisSession = 0, ever = AskRules.Cfg.MaxEver - 1 }), true)
	Spec.eq(AskRules.canAsk({ loaded = true, askedThisSession = 0, ever = AskRules.Cfg.MaxEver }), false, "cap ever")
	Spec.eq(AskRules.Cfg.MaxEver, 3)
	Spec.eq(AskRules.Cfg.PerSession, 1)
end)

Spec.test("squadmates counts the others only when you're on the call", function()
	Spec.eq(AskRules.squadmates(payload(2), ME), 1)
	Spec.eq(AskRules.squadmates({ stats = { { userId = ME } } }, ME), 0, "solo")
	Spec.eq(AskRules.squadmates(payload(2), 999), 0, "not mine")
	Spec.eq(AskRules.squadmates(nil, ME), 0)
end)

Spec.test("invite nudge: squad calls, once a session, never with a pass offer", function()
	local base = { squadmates = 1, nudged = 0, offerOnScreen = false, canInvite = true }
	Spec.eq(AskRules.inviteNudge(base), true)
	Spec.eq(AskRules.inviteNudge({ squadmates = 0, nudged = 0, offerOnScreen = false, canInvite = true }), false, "solo")
	Spec.eq(AskRules.inviteNudge({ squadmates = 2, nudged = 1, offerOnScreen = false, canInvite = true }), false, "once")
	Spec.eq(AskRules.inviteNudge({ squadmates = 2, nudged = 0, offerOnScreen = true, canInvite = true }), false, "offer")
	Spec.eq(AskRules.inviteNudge({ squadmates = 2, nudged = 0, offerOnScreen = false, canInvite = false }), false)
end)

Spec.test("calm: lobby only, nothing else on screen, settled, no recent pass offer", function()
	local function ctx(over: { [string]: any }?): any
		local c: any = {
			inLobby = true, onPad = false, onboarded = true, tutorial = false, modal = false, busy = false,
			alive = true, sinceLobby = 30, sinceOffer = math.huge, offerUp = false,
		}
		for k, v in over or {} do
			c[k] = v
		end
		return c
	end
	Spec.eq(AskRules.calm(ctx()), true)
	Spec.eq(AskRules.calm(ctx({ inLobby = false })), false, "never during a call")
	Spec.eq(AskRules.calm(ctx({ onPad = true })), false, "never on a pad")
	Spec.eq(AskRules.calm(ctx({ onboarded = false })), false)
	Spec.eq(AskRules.calm(ctx({ tutorial = true })), false)
	Spec.eq(AskRules.calm(ctx({ modal = true })), false)
	Spec.eq(AskRules.calm(ctx({ busy = true })), false, "never over the results screen")
	Spec.eq(AskRules.calm(ctx({ alive = false })), false)
	Spec.eq(AskRules.calm(ctx({ sinceLobby = 2 })), false, "let the lobby settle")
	Spec.eq(AskRules.calm(ctx({ sinceOffer = 10 })), false, "a pass offer just came")
	Spec.eq(AskRules.calm(ctx({ offerUp = true })), false, "a pass offer is on screen")
end)

return Spec.finish()
