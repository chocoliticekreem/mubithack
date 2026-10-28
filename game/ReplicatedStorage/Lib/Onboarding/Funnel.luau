--!strict
-- Funnel [owner: Onboarding]. Pure step logic for the Creator Dashboard funnels
-- (Services/FunnelService logs them through AnalyticsService; spec-tested in game/tests/funnel.spec.luau).
-- Every name here is a CONSTANT: AnalyticsService caps distinct step / event names, so nothing
-- free-form (player names, mission titles, ids) ever goes into a name.
--
--   Funnel.Onboarding      -- ordered step names of the first-session funnel (LogOnboardingFunnelStepEvent),
--                             legacy meanings kept (v1/v2); CustomField01 = device since v3
--   Funnel.OnboardingV3    -- ordered steps of the v3 funnel (LogFunnelStepEvent, Funnel.V3FunnelName)
--   Funnel.Devices, Funnel.device(info) -> string, Funnel.isDevice(name) -> boolean
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

-- Onboarding v3 (cold open + panda house, 2026-10-25). Its steps differ from the legacy onboarding funnel
-- above, so it is its OWN recurring funnel (LogFunnelStepEvent, funnel name "OnboardingV3", one session per
-- join) and the legacy funnel keeps its 12 meanings untouched (both are logged, so old vs new compare).
-- Every step carries the device (CustomField01 = Funnel.Devices). If a step's meaning ever changes, add
-- "OnboardingV4" instead of renumbering this one.
Funnel.V3FunnelName = "OnboardingV3"
Funnel.OnboardingV3 = table.freeze({
	"Joined", -- 1 the server saw the player
	"Spawned", -- 2 first character
	"Cutscene Shown", -- 3 the cold open started on the client
	"Cutscene Ended", -- 4 watched to the end or skipped (ColdOpenSkipped says when)
	"Fire Card Shown", -- 5 SPRAY THE FIRE! on screen
	"First Spray", -- 6 first spray that hit a burning part
	"Fire Out", -- 7 the panda house fire is out
	"Panda Picked Up", -- 8 picked up the panda
	"Panda Saved", -- 9 carried it outside (celebration + XP)
	"HUD Revealed", -- 10 the client revealed the XP bar / HELP / pads stage
	"Pad Stepped", -- 11 on a squad pad (the auto-queued first call, or walked onto one)
	"Call Launched", -- 12 InstanceId set
	"In Truck", -- 13 seated in a truck on the call
	"Arrived On Scene", -- 14 the run went Active
	"First Fire Out On Call", -- 15 put out a fire on the call
	"Call Complete", -- 16 MissionEnded
	"Back In Lobby", -- 17 InstanceId back to ""
})

-- device tag (CustomField01 of every onboarding step; constant set)
Funnel.Devices = table.freeze({ "Phone", "Tablet", "PC", "Console", "Unknown" })

export type DeviceInfo = {
	touch: boolean,
	keyboard: boolean,
	mouse: boolean,
	gamepad: boolean,
	tenFoot: boolean,
	viewportX: number,
	viewportY: number,
}

-- Phone / Tablet / PC / Console from what the client reports. Console = a 10-foot interface (Xbox /
-- PlayStation), or a gamepad with no keyboard and no touch screen. Touch-only: the short side of the
-- screen decides (phones are < 600 px tall in landscape, tablets more).
function Funnel.device(d: DeviceInfo): string
	if d.tenFoot then
		return "Console"
	end
	if d.touch and not d.keyboard and not d.mouse then
		local short = math.min(d.viewportX, d.viewportY)
		return if short >= 600 then "Tablet" else "Phone"
	end
	if d.gamepad and not d.keyboard and not d.touch then
		return "Console"
	end
	return "PC"
end

function Funnel.isDevice(name: any): boolean
	return type(name) == "string" and table.find(Funnel.Devices, name) ~= nil
end

-- Every Mission step carries CustomField01 = device (same set as OnboardingV3) since 2026-10-26;
-- Mission Complete's end reason moved to CustomField02.
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
	-- Onboarding v3 (CustomField01 = device)
	ColdOpenSkipped = "ColdOpenSkipped", -- value: seconds into the cold open when they skipped it
	OnboardingV3QuitStep = "OnboardingV3QuitStep", -- value: furthest OnboardingV3 step number when a new player left (CustomField01 = step name, CustomField02 = device)
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
	-- per-call twists + speed run (Services/TwistService; CustomField01 = twist id, Config/TwistConfig.Defs)
	TwistRolled = "TwistRolled", -- value: 1; a call got a twist at dispatch
	TwistCompleted = "TwistCompleted", -- value: 1; the twisted call ended ALL CLEAR (cat: and the cat was saved)
	CallTime = "CallTime", -- value: seconds from dispatch to the results; field = twist id or "none"
	-- pad -> launch and results -> call #2 (FunnelService:LogDevice: CustomField01 = device, CustomField02 = kind)
	PadWaitSeconds = "PadWaitSeconds", -- value: seconds from stepping on a pad to launch; kind solo | squad | late
	PadLeftBeforeLaunch = "PadLeftBeforeLaunch", -- value: seconds on the pad; kind walked | notyet | quit
	ResultsChoice = "ResultsChoice", -- value: seconds the results screen was up; kind tap | auto | stay
	DailyChestOpened = "DailyChestOpened", -- value: streak day 1..7; kind = the reward id
	-- the drive to a call (Services/DriveService through FunnelService:LogCustomFields; CustomField01 = device
	-- Phone | Tablet | PC | Console | Unknown, CustomField02 / 03 below). Live funnel: 28-35% quit in the truck.
	DriveStart = "DriveStart", -- value: road route length in metres; F2 role driver | passenger, F3 rookie | call
	DriveArrive = "DriveArrive", -- value: seconds in the truck until the run went Active; F2 role, F3 rookie | call
	DriveQuit = "DriveQuit", -- value: metres of road left; F2 role, F3 Lib/Vehicle/DriveMath.quitField
	--                          ("left|t30-60|r1|s0|w10+": quit the game or the call, seconds bucket, resets, stuck, wrong-way s)
	TruckReset = "TruckReset", -- value: 1; "Truck reset!" (VehicleService.Rescued); F2 why, F3 call | free
	TruckStuck = "TruckStuck", -- value: metres left; no progress for DriveConfig.StuckSeconds on a call;
	--                            F2 role, F3 nodriver | notstarted | idle | blocked | wrongway
	UnstuckApplied = "UnstuckApplied", -- value: metres left (0 off a call); the driver's client auto-unstuck the
	--                                    truck (VehicleController); F2 role, F3 call | free
	-- fire pacing per call (Services/CallPaceService at MissionEnded through FunnelService:LogCustomFields;
	-- CustomField01 = device, CustomField02 = rookie | call). "Fires sit there, then come back" check.
	FireHitTicks = "FireHitTicks", -- value: spray ticks that hit a burning part on this call
	FiresOutOnCall = "FiresOutOnCall", -- value: burning parts this player put out on this call
	ReignitesOnCall = "ReignitesOnCall", -- value: put-out parts that caught again at the call's site
	-- arrival -> first fire out (Services/ArrivalService through FunnelService:LogCustomFields; CustomField01 =
	-- device, 02 = rookie | call, 03 = touch auto-aim locks Lib/Fire/SprayAssist.lockBucket). Live funnel: 23.6%
	-- of phones (9.5% of PCs) arrived and left before putting out one fire.
	ArrivalToFireOut = "ArrivalToFireOut", -- value: seconds from arrival on scene to YOUR first fire out on the call
	ArrivalNoFireOut = "ArrivalNoFireOut", -- value: seconds on scene before the call ended / you left without one
	IdleSecondsOnCall = "IdleSecondsOnCall", -- value: seconds on scene with no burning fire within CallPaceService.IdleRadius
	-- come-back reasons (Services/RetentionService, Services/RookiePackService; docs/game/21-retention.md).
	-- NotifyPrompted / NotifyAccepted above are reused with field "retention" for the remind-me opt-in.
	NotifyAsk = "NotifyAsk", -- value: 1; the "🔔 REMIND ME TOMORROW?" card: field shown | yes | no
	ReturnGap = "ReturnGap", -- value: days since the previous join day (-1 first); F1 device, F2 first | same_day |
	--                          next_day | d2_6 | d7plus, F3 days since install d0 | d1 | d2_6 | d7plus
	RookiePackBought = "RookiePackBought", -- value: R$; field offer (within 10 min of its BUY) | other
	-- (ROOKIE PACK shown / clicked / declined: OfferShown / OfferClicked / OfferDeclined, field "RookiePack_results")
	-- call length (Services/CallLengthService; CustomField01 = device, CustomField02 = the player's lifetime call
	-- number bucket "1".."5" | "6-10" | "11+", Lib/Mission/CallRamp.bucket). Live: 24% quit between the first
	-- fire out and the end of the call; Config/CallRampConfig keeps calls 1-3 under ~2 minutes.
	CallDuration = "CallDuration", -- value: seconds from dispatch to the results; F3 win | timeout | fail
	QuitMidCall = "QuitMidCall", -- value: seconds into the call when they quit; F3 drive | scene | left_drive | left_scene
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
