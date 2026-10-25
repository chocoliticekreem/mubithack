--!strict
-- Funnel [owner: Onboarding]. Pure step logic for the Creator Dashboard funnels
-- (Services/FunnelService logs them through AnalyticsService; spec-tested in game/tests/funnel.spec.luau).
-- Every name here is a CONSTANT: AnalyticsService caps distinct step / event names, so nothing
-- free-form (player names, mission titles, ids) ever goes into a name.
--
--   Funnel.Onboarding      -- ordered step names of the first-session funnel (LogOnboardingFunnelStepEvent)
--   Funnel.Mission         -- ordered step names of the per-call funnel (LogFunnelStepEvent, MissionFunnelName)
--   Funnel.MissionFunnelName
--   Funnel.Events          -- custom event names (LogCustomEvent)
--   Funnel.index(steps, name) -> number            -- 1-based, 0 = unknown name
--   Funnel.new() -> Track                          -- { last = 0 }
--   Funnel.reach(track, steps, name) -> number?    -- the step number to log, or nil: unknown name, or not
--       past the furthest step already logged (steps only ever move forward; a skipped step is skipped)
--   Funnel.lastName(track, steps) -> string        -- name of the furthest step logged ("None" before any)
--   Funnel.minutes(seconds) -> number              -- whole minutes, rounded, >= 0
local Funnel = {}

Funnel.Onboarding = table.freeze({
	"Joined",
	"Spawned",
	"Saw Fire Card",
	"First Spray",
	"Fire Out",
	"Auto Queued",
	"Mission Launched",
	"In Truck",
	"Arrived On Scene",
	"First Mission Fire Out",
	"Mission Complete",
	"Back In Lobby",
})

Funnel.MissionFunnelName = "Mission"
Funnel.Mission = table.freeze({
	"Dispatched",
	"In Truck",
	"Arrived On Scene",
	"First Fire Out",
	"Mission Complete",
	"Back In Lobby",
})

Funnel.Events = table.freeze({
	FirstSpraySeconds = "FirstSpraySeconds", -- value: seconds from joining to the first spray on a fire
	SessionMinutes = "SessionMinutes", -- value: minutes online this session (on leave)
	OnboardingQuitStep = "OnboardingQuitStep", -- value: furthest onboarding step number when a new player left
	TutorialSkipped = "TutorialSkipped", -- value: onboarding step number when they pressed SKIP
	FirstCallDeclined = "FirstCallDeclined", -- value: seconds left on the countdown when they pressed NOT YET
	-- WHAT'S NEW panel (Services/UpdateLogService; CustomField01 = the Config/UpdateLog version)
	UpdateLogShown = "UpdateLogShown", -- value: 1 = popped up on join, 2 = opened from the NEWS chip
	NotifyPrompted = "NotifyPrompted", -- value: 1; the update-notification opt-in prompt opened
	NotifyAccepted = "NotifyAccepted", -- value: 1; reserved: Roblox doesn't report the opt-in answer to the game
	FavoritePrompted = "FavoritePrompted", -- value: 1; the favorite-the-game prompt opened
	FavoriteAccepted = "FavoriteAccepted", -- value: 1; PromptSetFavoriteCompleted said Success
	-- pass offers (Services/OfferService; CustomField01 = "<PassKey>_<moment>", moment results | lobby)
	OfferShown = "OfferShown", -- value: 1; the client drew the offer card
	OfferClicked = "OfferClicked", -- value: 1; BUY on the card (the Roblox purchase prompt opens)
	OfferDeclined = "OfferDeclined", -- value: 1; "No thanks"
	OfferPurchased = "OfferPurchased", -- value: R$ price; bought within Offers.ClickWindow of tapping BUY on its offer
	PassPurchased = "PassPurchased", -- value: R$ price; every pass purchase (CustomField01 = "<PassKey>_offer" | "<PassKey>_store")
	-- friendly asks (Services/SocialAskService; CustomField01 = where: like | lobby | results). Nothing is ever
	-- given for liking, favoriting or inviting. FavoritePrompted / FavoriteAccepted / NotifyPrompted above are
	-- reused with field "like" when they come from the "Having fun? 👍" card.
	LikeAskShown = "LikeAskShown", -- value: 1; the "Having fun? 👍" card opened (field "like")
	LikeAskClosed = "LikeAskClosed", -- value: seconds it was open; field "like_ok" | "like_dismiss" | "like_back"
	InviteAskShown = "InviteAskShown", -- value: 1; the results-screen "Bring your friends next time!" line
	InvitePrompted = "InvitePrompted", -- value: 1; SocialService:PromptGameInvite opened
	InviteSent = "InviteSent", -- value: number of friends invited (GameInvitePromptClosed recipients)
})

export type Track = { last: number }

function Funnel.index(steps: { string }, name: string): number
	for i, s in steps do
		if s == name then
			return i
		end
	end
	return 0
end

function Funnel.new(): Track
	return { last = 0 }
end

function Funnel.reach(track: Track, steps: { string }, name: string): number?
	local i = Funnel.index(steps, name)
	if i == 0 or i <= track.last then
		return nil
	end
	track.last = i
	return i
end

function Funnel.lastName(track: Track, steps: { string }): string
	return steps[track.last] or "None"
end

function Funnel.minutes(seconds: number): number
	return math.max(0, math.floor(seconds / 60 + 0.5))
end

return Funnel
