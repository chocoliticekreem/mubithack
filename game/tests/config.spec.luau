--!strict
-- Config.define: Set changes a known key and rejects unknown keys.
local Spec = require("./Spec")
local Config = require("../ReplicatedStorage/Shared/Config")

Spec.test("define keeps values", function()
	local c = Config.define({ TickHz = 5 })
	Spec.eq(c.TickHz, 5)
end)

Spec.test("Set changes a known key", function()
	local c = Config.define({ TickHz = 5 }) :: any
	c.Set("TickHz", 10)
	Spec.eq(c.TickHz, 10)
end)

Spec.test("Set rejects an unknown key", function()
	local c = Config.define({ TickHz = 5 }) :: any
	Spec.errors(function()
		c.Set("TikHz", 10)
	end, "unknown key TikHz")
end)

return Spec.finish()
