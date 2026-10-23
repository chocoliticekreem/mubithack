--!strict
-- MapConfig [owner: G2]. Seed and location slots.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Seed = 6767,
	SlotSize = 400, -- studs; each location gets its own SlotSize x SlotSize square
	SlotsPerRow = 4,
	-- v1.5 parallel missions: each squad's mission is built as its own instance in a free slot.
	-- Slots 0..3 are the fixed v1 locations (Station = 0, Town = 1); instances use 4 .. 4 + MaxInstances - 1.
	InstanceFirstSlot = 4,
	MaxInstances = 8,
	SlotOrigin = function(slot: number): CFrame
		local row = slot // 4
		local col = slot % 4
		return CFrame.new(col * 400, 0, row * 400)
	end,
})
