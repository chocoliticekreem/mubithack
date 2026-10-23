--!strict
-- VehicleConfig [owner: G2]. Truck 67 numbers.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	TruckNumber = 67,
	HomeLocation = "Station", -- ResetTruck() parks here
})
