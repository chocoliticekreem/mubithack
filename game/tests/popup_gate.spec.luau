--!strict
-- PopupGateRules: one gatekeeper for pop-ups that open by themselves (first join on phones was a pile).
local Spec = require("./Spec")
local R = require("../StarterPlayerScripts/Lib/PopupGateRules")

local function st(o: any): any
	return {
		onboarding = o.onboarding == true,
		newbieSession = o.newbieSession == true,
		now = o.now or 100,
		open = o.open,
		lastEnd = o.lastEnd or -math.huge,
		autoShown = o.autoShown or 0,
	}
end

Spec.test("during the first call nothing but onboarding: every gated kind is dropped, not queued", function()
	for kind in R.Kinds do
		Spec.eq(R.decide(kind, st({ onboarding = true, newbieSession = true })), "drop")
	end
end)

Spec.test("kinds we don't gate always show", function()
	Spec.eq(R.decide("turn", st({ onboarding = true })), "show")
	Spec.eq(R.decide("whatever", st({ open = "news" })), "show")
end)

Spec.test("after onboarding: cards, toasts and banners show (their own queues take turns)", function()
	Spec.eq(R.decide("celebrate", st({ newbieSession = true, open = "like" })), "show")
	Spec.eq(R.decide("achievement", st({})), "show")
	Spec.eq(R.decide("fanfare", st({})), "show")
end)

Spec.test("one auto modal at a time", function()
	Spec.eq(R.decide("news", st({ open = "offer" })), "wait")
	Spec.eq(R.decide("offer", st({ open = "news" })), "wait")
	Spec.eq(R.decide("news", st({})), "show")
end)

Spec.test("a modal waits Gap seconds after the last pop-up went away", function()
	Spec.eq(R.Gap >= 8, true)
	Spec.eq(R.decide("news", st({ now = 100, lastEnd = 100 - R.Gap + 1 })), "wait")
	Spec.eq(R.decide("news", st({ now = 100, lastEnd = 100 - R.Gap })), "show")
end)

Spec.test("a new player's first session: only the like-ask, once; the rest wait for next session", function()
	Spec.eq(R.decide("news", st({ newbieSession = true })), "defer")
	Spec.eq(R.decide("offer", st({ newbieSession = true })), "defer")
	Spec.eq(R.decide("like", st({ newbieSession = true })), "show")
	Spec.eq(R.decide("like", st({ newbieSession = true, autoShown = R.NewbieCap })), "defer")
end)

Spec.test("returning players: at most SessionCap auto modals a session", function()
	Spec.eq(R.decide("offer", st({ autoShown = R.SessionCap - 1 })), "show")
	Spec.eq(R.decide("offer", st({ autoShown = R.SessionCap })), "defer")
	Spec.eq(R.decide("like", st({ autoShown = R.SessionCap })), "defer")
end)

return Spec.finish()
