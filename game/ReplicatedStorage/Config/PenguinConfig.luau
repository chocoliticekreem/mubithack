--!strict
-- PenguinConfig [owner: Squad/costume]. Every player firefighter is a goofy cartoon penguin
-- (Lib/Squad/PenguinBuilder, applied by CostumeBuilder.dress on each spawn). The R15 rig, Humanoid,
-- hitboxes and HipHeight are untouched: the penguin is only recolouring plus Massless, non-colliding
-- welded parts, so hands, axe, ragdoll, seats and first person behave exactly as before.
-- Colours are hex strings so the pure spec (game/tests/penguin.spec.luau) can read this file.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Enabled = true, -- false = the plain trailer firefighter costume

	Black = "#1E1B24", -- feathers (head, back, flippers, legs)
	White = "#F6F3EA", -- belly and face patch
	Beak = "#F5A623",
	BeakLower = "#E07A1C",
	Feet = "#F08A2A",

	-- white belly: fraction of the black body blob, pushed forward so an oval shows on the front
	BellyScale = { x = 0.78, y = 0.82, z = 0.7 },
	BellyDrop = 0.06, -- fraction of body height the belly sits below the body centre
	-- white face patch under the googly eyes, same trick on the head blob
	FaceScale = { x = 0.74, y = 0.62, z = 0.7 },
	FaceDrop = 0.2, -- fraction of head height

	BeakSize = { x = 0.75, y = 0.32, z = 0.9 }, -- studs, upper beak (lower is a bit smaller)
	FlipperThick = 0.55, -- studs, side-to-side thickness of a flipper paddle
	FlipperWide = 1.25, -- studs, front-to-back width of the upper-arm paddle (forearm: 85%)
	FootSize = { x = 1.25, y = 0.32, z = 1.7 }, -- studs, flat orange feet
})
