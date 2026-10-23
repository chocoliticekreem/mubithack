--!strict
-- ToolConfig [owner: G1]. Hose, tank, axe and door numbers.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	TankSize = 100, -- litres in the backpack tank
	LitresPerSpray = 1.2, -- per Tool/Spray event; the client sends 10/s, so 12 L/s
})
