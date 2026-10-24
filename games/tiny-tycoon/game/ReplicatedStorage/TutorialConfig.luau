--!strict
-- Pure shared tunables for the first-60-seconds tutorial.
-- No side effects: this ModuleScript only returns a table.

local TutorialConfig = {
	TOTAL_SECONDS = 60,
	SKIP_UPGRADES = 3,

	REMOTE_NAME = "TutorialStep",

	EVENTS = {
		START = "start",
		CLAIMED = "claimed",
		CASHED = "cashed",
		BOUGHT = "bought",
		SKIP = "skip",
	},

	-- Banner text per step (index = step number).
	STEPS = {
		"Walk to a CLAIM gate to claim your plot",
		"Watch your dropper make cash",
		"Step on the glowing GREEN pad: $10",
		"Tap the yellow SHOP button, buy Fast Belt!",
	},

	-- Which server event advances away from each step.
	-- step 1 -> 'claimed', step 2 -> timed fallback (ADVANCE_DELAY, no waiting for a cash event),
	-- step 3 -> 'bought', step 4 -> ends when the shop opens.
	ADVANCE_ON = {
		"claimed",
		"claimed",
		"bought",
		"shop",
	},

	-- Seconds to wait after entering a step before it auto-advances (keyed by step number).
	-- Step 2 advances ~8 s after entering it even if no cash event ever arrives,
	-- so the player is never left without guidance.
	ADVANCE_DELAY = {
		[2] = 8,
	},

	-- Timed fallback (seconds) used when an expected server event never arrives.
	-- Keyed by step number; step 2 -> step 3 after about 8 seconds.
	FALLBACK_DELAY = {
		[2] = 8,
	},

	-- Seconds after the shop step begins before the client pulses the SHOP button
	-- if the shop has not been opened yet.
	SHOP_NUDGE_SECONDS = 8,

	-- Sound played (via GameAssets.play) on each step change.
	STEP_SOUND = "Pop",

	-- Play a sparkle burst (GameAssets.burst) on every step advance.
	STEP_SPARKLE = true,

	-- Steps where the bouncing arrow must stay over the target (step 3 = the buy pad,
	-- the Dropper 2 pad).
	ARROW_STEPS = {
		[3] = true,
	},

	-- Arrow visuals.
	ARROW_COLOR = Color3.fromRGB(255, 221, 51),
	ARROW_SIZE = Vector3.new(3, 3, 3),
	ARROW_HEIGHT = 11, -- studs above target
	BOUNCE_HEIGHT = 1.5,
	BOUNCE_SPEED = 4, -- radians per second

	-- Beam from player to target.
	BEAM_COLOR = Color3.fromRGB(255, 240, 120),
	BEAM_WIDTH = 1,

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
	TutorialConfig.EVENTS.SKIP,
}

return TutorialConfig
