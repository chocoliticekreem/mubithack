--!strict
-- Pure shared tunables for the first-60-seconds tutorial.
-- No side effects: this ModuleScript only returns a table.

local TutorialConfig = {
	TOTAL_SECONDS = 60,
	SKIP_UPGRADES = 3,

	REMOTE_NAME = "TutorialStep",

	-- Re-show a stuck step's hint after this many seconds without progress.
	STUCK_RESHOW_SECONDS = 5,

	-- If the player has not opened the SHOP this many seconds after the shop step
	-- begins, the server advances the step anyway so guidance never stalls.
	SHOP_STEP_FALLBACK_SECONDS = 12,

	EVENTS = {
		START = "start",
		CLAIMED = "claimed",
		CASHED = "cashed",
		BOUGHT = "bought",
		SHOP = "shop",
		UPGRADED = "upgraded",
		DONE = "done",
		SKIP = "skip",
	},

	-- Banner text per step (index = step number). One short command each.
	STEPS = {
		"Walk to the CLAIM gate!", -- 1: claim a plot
		"Collect $10 from cubes!", -- 2: first cash-in
		"Step on the glowing green pad!", -- 3: buy Dropper 2
		"Tap the SHOP button!", -- 4: open the shop
		"Buy an upgrade in the SHOP!", -- 5: buy a tier upgrade
		"You did it! Keep growing!", -- 6: done
	},

	-- Which server event advances away from each step.
	-- step 1 -> 'claimed', step 2 -> 'cashed' (timed fallback via ADVANCE_DELAY),
	-- step 3 -> 'bought', step 4 -> 'shop' (SHOP panel opened; fallback after
	-- SHOP_STEP_FALLBACK_SECONDS), step 5 -> 'upgraded', step 6 -> final.
	ADVANCE_ON = {
		"claimed",
		"cashed",
		"bought",
		"shop",
		"upgraded",
		"done",
	},

	-- Seconds to wait after entering a step before it auto-advances (keyed by step number).
	-- Step 2 advances ~8 s after entering it even if no cash event ever arrives,
	-- so the player is never left without guidance.
	ADVANCE_DELAY = {
		[2] = 8,
		[4] = 12,
	},

	-- Timed fallback (seconds) used when an expected server event never arrives.
	-- Keyed by step number.
	FALLBACK_DELAY = {
		[2] = 8,
		[4] = 12,
	},

	-- Seconds after the shop step begins before the client pulses the SHOP button
	-- if the shop has not been opened yet.
	SHOP_NUDGE_SECONDS = 8,

	-- Sound played (via GameAssets.play) on each step change.
	STEP_SOUND = "Pop",

	-- Play a sparkle burst (GameAssets.burst) on every step advance.
	STEP_SPARKLE = true,

	-- Steps where the bouncing arrow must stay over the target
	-- (step 1 = claim gate, step 2 = dropper, step 3 = the Dropper 2 buy pad).
	ARROW_STEPS = {
		[1] = true,
		[2] = true,
		[3] = true,
	},

	-- Steps where a Beam from the player to the target is shown.
	BEAM_STEPS = {
		[1] = true,
		[2] = true,
		[3] = true,
	},

	-- Keep the guide beam alive (re-create if missing) until the player's
	-- upgrades_bought stat reaches this value.
	BEAM_KEEP_UNTIL_UPGRADES_BOUGHT = 1,
	BEAM_PERSIST = true,

	-- Steps where the target gets a Highlight so it is visible from across the plot.
	HIGHLIGHT_STEPS = {
		[1] = true,
		[2] = true,
		[3] = true,
	},

	-- Highlight visuals on the target pad.
	HIGHLIGHT_FILL_COLOR = Color3.fromRGB(76, 217, 100),
	HIGHLIGHT_OUTLINE_COLOR = Color3.fromRGB(255, 255, 255),
	HIGHLIGHT_FILL_TRANSPARENCY = 0.5,
	HIGHLIGHT_OUTLINE_TRANSPARENCY = 0,

	-- Arrow visuals.
	ARROW_COLOR = Color3.fromRGB(255, 221, 51),
	ARROW_SIZE = Vector3.new(3, 3, 3),
	ARROW_HEIGHT = 11, -- studs above target
	BOUNCE_HEIGHT = 1.5,
	BOUNCE_SPEED = 4, -- radians per second

	-- Beam from player to target.
	BEAM_COLOR = Color3.fromRGB(255, 240, 120),
	BEAM_WIDTH = 2,

	-- Banner visuals.
	BANNER_COLOR = Color3.fromRGB(30, 30, 50),
	BANNER_TEXT_COLOR = Color3.fromRGB(255, 255, 255),
	BANNER_STROKE_COLOR = Color3.fromRGB(255, 221, 51),
}

-- Convenience lookups.
TutorialConfig.EVENT_NAMES = {
	TutorialConfig.EVENTS.START,
	TutorialConfig.EVENTS.CLAIMED,
	TutorialConfig.EVENTS.CASHED,
	TutorialConfig.EVENTS.BOUGHT,
	TutorialConfig.EVENTS.SHOP,
	TutorialConfig.EVENTS.UPGRADED,
	TutorialConfig.EVENTS.DONE,
	TutorialConfig.EVENTS.SKIP,
}

return TutorialConfig
