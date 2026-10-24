--!strict
-- Shared constants for Cube Cash Tycoon. Single source of truth for tunables.
-- NOTE: upgrade prices live ONLY in ReplicatedStorage/Upgrades.luau. Do not add costs here.

local Config = {
	-- Economy
	STARTING_CASH = 10, -- initial Cash leaderstat so the first buy happens within ~30s

	-- Cubes / dropping
	DROP_INTERVAL = 2, -- seconds between cubes per dropper (design: one cube every 2s)
	CUBE_VALUE = 1,
	CUBE_SIZE = Vector3.new(1.5, 1.5, 1.5),
	MAX_CUBES_PER_PLOT = 30,

	-- Conveyor
	CONVEYOR_SPEED = 8,
	FAST_CONVEYOR_SPEED = 16,
	CONVEYOR_LENGTH = 24,

	-- Plots
	PLOT_SIZE = Vector3.new(40, 1, 40),
	PLOT_SPACING = 60,
	MAX_PLOTS = 6, -- one plot per theme (6 themes), no repeats
	PLOT_COUNT = 6,

	-- Colors (palette only, no grey)
	PLOT_COLOR = Color3.fromRGB(120, 220, 140),
	CONVEYOR_COLOR = Color3.fromRGB(43, 45, 66), -- #2B2D42 deep navy
	CUBE_COLOR = Color3.fromRGB(255, 210, 63), -- #FFD23F
	DROPPER_COLOR = Color3.fromRGB(127, 227, 255), -- #7FE3FF
	COLLECTOR_COLOR = Color3.fromRGB(255, 106, 43), -- #FF6A2B
	BUTTON_COLOR = Color3.fromRGB(76, 217, 100), -- #4CD964
	BOUGHT_COLOR = Color3.fromRGB(242, 196, 107), -- #F2C46B (warm gold, never grey)

	-- World floor
	BASEPLATE_COLOR = Color3.fromRGB(116, 196, 98), -- bright grass green
	BASEPLATE_MATERIAL = Enum.Material.Grass,

	-- Remotes
	REMOTES_FOLDER = "TycoonRemotes",
	REMOTE_NOTIFY = "Notify",
}

return Config
