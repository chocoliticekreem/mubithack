--!strict
-- PenguinRules [owner: Squad/costume]. Pure helpers for PenguinBuilder (no Roblox APIs, so
-- game/tests/penguin.spec.luau can run them in the luau CLI).
--   PenguinRules.strip(name) -> boolean        -- costume part the penguin removes (coat bits, mouth, bands)
--   PenguinRules.limbColor(name) -> string?    -- "Black" | "Feet" for an R15/R6 body part, nil = leave alone
--   PenguinRules.patch(size, scale, drop) -> (sx, sy, sz, dy, dz)
--       an inner ellipsoid (belly / face patch) on an outer one of `size` {x,y,z}: its size and the
--       offset (dy studs up, dz studs along Z; negative dz = toward the front) so its front pokes out.
local PenguinRules = {}

-- Coat-only pieces of the trailer firefighter costume. Kept: HeadBlob, BodyBlob, eyes, pupils,
-- the helmet set, the yellow Collar (reads as a firefighter scarf), the air tank and harness straps.
local STRIP_EXACT = {
	CoatHem = true,
	CollarLine = true,
	Mouth = true,
	Soot = true,
}
local STRIP_PREFIX = { "ChestBand", "Toggle" }

function PenguinRules.strip(name: string): boolean
	if STRIP_EXACT[name] then
		return true
	end
	for _, p in STRIP_PREFIX do
		if string.sub(name, 1, #p) == p then
			return true
		end
	end
	-- CostumeBuilder reflective limb bands: "<Limb>Band<i>" (but never the tank's TankBand)
	if string.match(name, "^%a+Band%d$") and string.sub(name, 1, 4) ~= "Tank" then
		return true
	end
	return false
end

local BLACK = {
	UpperTorso = true,
	LowerTorso = true,
	Torso = true,
	LeftUpperArm = true,
	RightUpperArm = true,
	LeftLowerArm = true,
	RightLowerArm = true,
	LeftHand = true,
	RightHand = true,
	["Left Arm"] = true,
	["Right Arm"] = true,
	LeftUpperLeg = true,
	RightUpperLeg = true,
	LeftLowerLeg = true,
	RightLowerLeg = true,
	["Left Leg"] = true,
	["Right Leg"] = true,
}

function PenguinRules.limbColor(name: string): string?
	if name == "LeftFoot" or name == "RightFoot" then
		return "Feet"
	end
	if BLACK[name] then
		return "Black"
	end
	return nil
end

type V3 = { x: number, y: number, z: number }

function PenguinRules.patch(size: V3, scale: V3, drop: number): (number, number, number, number, number)
	local sx, sy, sz = size.x * scale.x, size.y * scale.y, size.z * scale.z
	-- the inner blob's front ends 5% of the depth past the outer blob's front
	local dz = -(size.z / 2 - sz / 2) - size.z * 0.05
	return sx, sy, sz, -size.y * drop, dz
end

return PenguinRules
