--!strict
-- MapConfig [owner: G2]. Seed and location slots.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Seed = 6767,
	SlotSize = 400, -- studs; each location gets its own SlotSize x SlotSize square
	SlotsPerRow = 4,
	SlotOrigin = function(slot: number): CFrame
		local row = slot // 4
		local col = slot % 4
		return CFrame.new(col * 400, 0, row * 400)
	end,
})
