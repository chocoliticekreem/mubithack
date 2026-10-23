--!strict
-- FeedbackConfig [owner: Feedback]. One subtle feedback system (ClientLib/WorldPopup + HudController toasts):
--   * minor juice (pops, slaps, bonks, honks, blame callouts) = small world text ABOVE the subject's head,
--     only for players near it (Shared/Popup.show on the server, WorldPopup.show on the client)
--   * screen toasts (Net.notify) only for important events: dispatch/alarm, mission start/end, results,
--     level up, your own downed/overheated. Max 2 visible, top-centre under the timer, 2.5 s.
-- Player setting "feedback" (ProfileSchema.Settings, 0 Normal / 1 Minimal / 2 Off) is mirrored by
-- DataService to Player attr Feedback; WorldPopup's lobby button cycles it. Mode below is the default.
--   Normal  = every world popup near you
--   Minimal = only popups you are part of (about you, or you caused them)
--   Off     = no world popups (important screen toasts still show)
-- Read at use time so ".Set" live-tunes it.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Mode = "Normal", -- default when the player has no saved setting
	SettingKey = "feedback", -- ProfileSchema.Settings key (number 0..2)
	SettingAttr = "Feedback", -- Player attr DataService mirrors it to

	-- world popups (WorldPopup)
	SendRadius = 70, -- server only sends a popup to players this close to its subject (plus actor/subject)
	MaxDistance = 60, -- BillboardGui.MaxDistance; client also skips popups farther than this
	HeadOffset = 2.4, -- studs above the head / top of the subject
	TextSize = 16, -- px (big kinds +2)
	Seconds = 1.0, -- rise + fade
	Rise = 1.2, -- studs it drifts up while fading
	Cap = 6, -- max popups on screen
	PerSubject = 1, -- newest replaces the old one over the same subject
	DedupeSeconds = 2, -- same text over the same subject within this is dropped
	OutlineTransparency = 0.45, -- soft text stroke

	-- screen toasts (HudController)
	ToastMax = 2,
	ToastSeconds = 2.5,
	ToastDedupeSeconds = 2,
	ToastTextSize = 17,
	ToastTop = 74, -- px from the top: just under the timer pill
})
