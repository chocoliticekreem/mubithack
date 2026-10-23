--!strict
-- RescueConfig [owner: G3]. Civilians and pets.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Count = 5, -- NPCs spawned per round (one per RescueSpawn marker, up to this many)
})
