--!strict
-- PopupGateRules [owner: G3]. Pure rules for ClientLib/PopupGate (spec: game/tests/popup_gate.spec.luau):
-- which pop-up that opens BY ITSELF may show now. Phones made this urgent: on a first join a kid got the
-- first-call card, LEVEL 2!, NEW GEAR!, an achievement toast and GO NOW in the same second.
--
--   1. Onboarding (the first call isn't done yet): only the onboarding flow (tutorial cards, the first-call
--      card, the call itself). Celebration cards, achievement toasts, other players' pass fanfare and every
--      auto modal are DROPPED (not queued: a queue would dump them all on the screen the moment the call
--      ends). What they announce is still saved (XP, gear, trophies: the chips / dots show it).
--   2. After that, at most ONE auto modal at a time, and a modal only Gap seconds after the last pop-up
--      (modal or centre card) went away.
--   3. A session shows at most SessionCap auto modals (a brand-new player's first session: NewbieCap, and
--      only the kinds marked newbie = true: the like-ask and the remind-me ask). Everything else is "defer": it stays pending (a red dot, the
--      server's flag) and gets its turn next session.
--
--   PopupGateRules.Kinds[kind] = { class = "modal" | "card" | "toast" | "banner", prio, newbie }
--   PopupGateRules.decide(kind, state) -> "show" | "wait" | "drop" | "defer"
--     state: { onboarding, newbieSession, now, open (kind of the auto modal up, or nil), lastEnd,
--              autoShown (auto modals shown this session) }
local PopupGateRules = {}

PopupGateRules.Gap = 8 -- seconds between one pop-up going away and the next auto modal
PopupGateRules.SessionCap = 2 -- auto modals per session (returning players)
-- in the session a player was new in: the remind-me ask (notify) and the like-ask, never more. Day-1 return was
-- 1-2 %, so the one ask that brings them back tomorrow gets its slot in the first session (docs/game/21-retention.md)
PopupGateRules.NewbieCap = 2

export type Kind = { class: string, prio: number, newbie: boolean }

PopupGateRules.Kinds = table.freeze({
	-- auto modals (one at a time, spaced, capped per session)
	news = table.freeze({ class = "modal", prio = 2, newbie = false }), -- WHAT'S NEW (UpdateLog)
	like = table.freeze({ class = "modal", prio = 3, newbie = true }), -- "Having fun? 👍" (SocialAsk)
	notify = table.freeze({ class = "modal", prio = 2, newbie = true }), -- "🔔 Remind me tomorrow?" (RetentionController)
	offer = table.freeze({ class = "modal", prio = 3, newbie = false }), -- lobby pass offer card
	-- centre cards: LEVEL UP / NEW GEAR / TIER UP (HudLayout.celebrate takes turns already)
	celebrate = table.freeze({ class = "card", prio = 5, newbie = true }),
	-- toasts / banners that aren't about what you're doing right now
	achievement = table.freeze({ class = "toast", prio = 6, newbie = true }),
	fanfare = table.freeze({ class = "banner", prio = 6, newbie = true }), -- someone else got a pass
} :: { [string]: Kind })

export type State = {
	onboarding: boolean,
	newbieSession: boolean,
	now: number,
	open: string?,
	lastEnd: number,
	autoShown: number,
}

function PopupGateRules.decide(kind: string, s: State): string
	local k = PopupGateRules.Kinds[kind]
	if not k then
		return "show" -- not a pop-up we gate
	end
	if s.onboarding then
		return "drop"
	end
	if k.class ~= "modal" then
		return "show" -- cards queue in HudLayout; toasts / banners have their own queues
	end
	if s.newbieSession and not k.newbie then
		return "defer"
	end
	local cap = if s.newbieSession then PopupGateRules.NewbieCap else PopupGateRules.SessionCap
	if s.autoShown >= cap then
		return "defer"
	end
	if s.open ~= nil then
		return "wait"
	end
	if s.now - s.lastEnd < PopupGateRules.Gap then
		return "wait"
	end
	return "show"
end

return PopupGateRules
