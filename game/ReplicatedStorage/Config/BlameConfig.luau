--!strict
-- BlameConfig [owner: G3]. Award thresholds.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	MaxAwardsPerPlayer = 2,
})
