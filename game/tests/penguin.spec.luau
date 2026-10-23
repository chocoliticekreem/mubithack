--!strict
-- PenguinRules: which costume parts the penguin strips, how limbs are coloured, belly/face patch maths.
local Spec = require("./Spec")
local R = require("../ServerScriptService/Lib/Squad/PenguinRules")

Spec.test("strips coat bits and limb bands", function()
	for _, n in { "CoatHem", "CollarLine", "Mouth", "Soot", "ChestBand1", "Toggle2", "LeftLowerArmBand1", "RightLowerLegBand3" } do
		Spec.eq(R.strip(n), true, n)
	end
end)

Spec.test("keeps the head, helmet, eyes, collar, tank and straps", function()
	for _, n in { "HeadBlob", "BodyBlob", "HelmetDome", "Shield", "Eye1", "Pupil2", "Collar", "Tank", "TankBand", "Harness", "Strap1", "BadgeTag" } do
		Spec.eq(R.strip(n), false, n)
	end
end)

Spec.test("limbs go black, feet go orange, the rest is left alone", function()
	Spec.eq(R.limbColor("LeftUpperArm"), "Black")
	Spec.eq(R.limbColor("RightHand"), "Black")
	Spec.eq(R.limbColor("LowerTorso"), "Black")
	Spec.eq(R.limbColor("Left Leg"), "Black")
	Spec.eq(R.limbColor("RightFoot"), "Feet")
	Spec.eq(R.limbColor("Head"), nil)
	Spec.eq(R.limbColor("HumanoidRootPart"), nil)
end)

Spec.test("patch is smaller than the blob and pokes out of its front", function()
	local size = { x = 3, y = 3.6, z = 2.7 }
	local sx, sy, sz, dy, dz = R.patch(size, { x = 0.78, y = 0.82, z = 0.7 }, 0.06)
	Spec.near(sx, 2.34, 1e-6, "sx")
	Spec.near(sy, 2.952, 1e-6, "sy")
	Spec.truthy(sz < size.z, "thinner")
	Spec.truthy(dy < 0, "sits lower")
	local front = dz - sz / 2
	Spec.truthy(front < -size.z / 2, "front past the blob's front")
	Spec.truthy(front > -size.z / 2 - 0.3, "but only just")
end)

return Spec.finish()
