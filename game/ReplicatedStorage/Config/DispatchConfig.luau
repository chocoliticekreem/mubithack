--!strict
-- DispatchConfig [owner: Dispatch]. The free-roam DISPATCH radio (ServerScriptService/Services/DispatchService,
-- StarterPlayerScripts/Controllers/DispatchController): calls roll in while you're free, ACCEPT from anywhere.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Enabled = true,

	-- Incoming calls (only while you're free: no mission, not queued on a pad, not mid-tutorial)
	OfferMinSeconds = 30, -- a new call rolls in this long after the last one closed...
	OfferMaxSeconds = 60, -- ...at most this long (random in between)
	FirstOfferSeconds = 20, -- after joining / finishing a call, the first one comes a bit sooner
	OfferSeconds = 20, -- an unanswered INCOMING CALL card goes away after this
	ListSize = 5, -- calls in the DISPATCH list (one per mission type, plus a small job)
	ListSeconds = 90, -- a call picked from the list must be accepted within this
	AcceptCooldown = 3, -- seconds between accepts per player (on top of the remote's rate limit)

	-- Where calls come from: a free IncidentSite this far from you (studs), else the nearest free one
	NearStuds = 250,
	FarStuds = 1600,
	MetersPerStud = 0.28, -- Roblox's own scale: the card reads "450 m"
	Exclude = { dam_finale = true }, -- the finale is a big set piece, not a radio call

	-- Small free-roam jobs (no timer, no squad): a bin fire on a street corner, put it out for XP
	MiniChance = 0.35, -- share of incoming calls that are a small job
	MiniMinStuds = 120, -- spawned on a road this far from you...
	MiniMaxStuds = 450, -- ...at most this far
	MiniXp = 25, -- each player who helped put it out
	MiniSeconds = 180, -- an unattended small fire burns itself out after this
	MiniFuel = 30, -- seconds of fuel per burning item
	MiniCalls = { "Bin fire", "Trash fire", "Rubbish fire" },

	Keys = { Toggle = "L", Accept = "Y", Decline = "N" },
})
