--!strict
-- HazardMath: blast falloff, tornado wander/leash, wave sweep, backdraft cone, collapse threshold.
local Spec = require("./Spec")
local H = require("../ServerScriptService/Lib/Hazard/HazardMath")

Spec.test("falloff is 1 at centre, 0 at the edge and beyond", function()
	Spec.eq(H.falloff(0, 10), 1)
	Spec.near(H.falloff(5, 10), 0.5)
	Spec.eq(H.falloff(10, 10), 0)
	Spec.eq(H.falloff(25, 10), 0)
	Spec.eq(H.falloff(1, 0), 0)
end)

Spec.test("knockback keeps a floor inside the radius and is 0 outside", function()
	Spec.eq(H.knockback(0, 20, 100, 30), 100)
	Spec.near(H.knockback(19.99, 20, 100, 30), 30, 0.1)
	Spec.eq(H.knockback(20, 20, 100, 30), 0)
end)

Spec.test("blastDamage rounds and is 0 outside", function()
	Spec.eq(H.blastDamage(0, 15, 60), 60)
	Spec.eq(H.blastDamage(7.5, 15, 60), 30)
	Spec.eq(H.blastDamage(16, 15, 60), 0)
end)

Spec.test("tornado moves `speed*dt` per step", function()
	local x, z = H.tornadoStep(0, 0, 0, nil, nil, 0, 8, 1, function()
		return 0.5
	end, 0, 0, 100)
	Spec.near(math.sqrt(x * x + z * z), 8, 1e-6)
end)

Spec.test("tornado turns toward a target with full bias", function()
	local x, z = H.tornadoStep(0, 0, 0, 0, 50, 1, 8, 1, function()
		return 0.5
	end, 0, 0, 100)
	Spec.near(x, 0, 1e-6)
	Spec.near(z, 8, 1e-6)
end)

Spec.test("tornado on a long leash-break drifts back toward the field", function()
	local x, z, h = 200, 0, 0 -- heading away (+x), 200 studs out of a 60-stud leash
	for _ = 1, 40 do
		x, z, h = H.tornadoStep(x, z, h, nil, nil, 0, 8, 1, function()
			return 0.5
		end, 0, 0, 60)
	end
	Spec.truthy(math.sqrt(x * x + z * z) < 200, "came back closer")
end)

Spec.test("inBox", function()
	Spec.truthy(H.inBox(1, 0, 1, 0, 0, 0, 2, 1, 2))
	Spec.eq(H.inBox(3, 0, 1, 0, 0, 0, 2, 1, 2), false)
end)

Spec.test("wave front clamps to the path length and hits within its thickness", function()
	Spec.eq(H.waveFront(2, 40, 300), 80)
	Spec.eq(H.waveFront(100, 40, 300), 300)
	Spec.eq(H.waveFront(-1, 40, 300), 0)
	Spec.truthy(H.waveHit(70, 80, 20))
	Spec.eq(H.waveHit(90, 80, 20), false)
	Spec.eq(H.waveHit(50, 80, 20), false)
end)

Spec.test("backdraft cone", function()
	local cos30 = math.cos(math.rad(30))
	Spec.truthy(H.inCone(0, 0, -10, 0, 0, -1, 20, cos30))
	Spec.eq(H.inCone(10, 0, 0, 0, 0, -1, 20, cos30), false) -- 90 degrees off
	Spec.eq(H.inCone(0, 0, -25, 0, 0, -1, 20, cos30), false) -- too far
end)

Spec.test("collapse threshold", function()
	Spec.truthy(H.collapseShouldFall(2, 4, 0.5))
	Spec.eq(H.collapseShouldFall(1, 4, 0.5), false)
	Spec.eq(H.collapseShouldFall(0, 0, 0.5), false)
end)

return Spec.finish()
