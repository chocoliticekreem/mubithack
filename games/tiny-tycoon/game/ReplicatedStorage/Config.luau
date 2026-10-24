--!strict
-- Shared constants for Cube Cash Tycoon. Single source of truth for tunables.

local Config = {
	-- Cubes / dropping
	DROP_INTERVAL = 2, -- seconds between cubes per dropper (design: one cube every 2s)
	CUBE_VALUE = 1,
	CUBE_SIZE = Vector3.new(1.5, 1.5, 1.5),
	MAX_CUBES_PER_PLOT = 30,

	-- Conveyor
	CONVEYOR_SPEED = 8,
	FAST_CONVEYOR_SPEED = 16,
	CONVEYOR_LENGTH = 24,

	-- Costs
	DROPPER_COST = 25,
	CONVEYOR_COST = 50,

	-- Plots
	PLOT_SIZE = Vector3.new(40, 1, 40),
	PLOT_SPACING = 60,
	MAX_PLOTS = 8,

	-- Colors
	PLOT_COLOR = Color3.fromRGB(120, 220, 140),
	CONVEYOR_COLOR = Color3.fromRGB(60, 60, 70),
	CUBE_COLOR = Color3.fromRGB(255, 210, 40),
	DROPPER_COLOR = Color3.fromRGB(80, 160, 255),
	COLLECTOR_COLOR = Color3.fromRGB(255, 90, 90),
	BUTTON_COLOR = Color3.fromRGB(60, 220, 100),
	BOUGHT_COLOR = Color3.fromRGB(130, 130, 130),

	-- Remotes
	REMOTES_FOLDER = "TycoonRemotes",
	REMOTE_NOTIFY = "Notify",
}

return Config
