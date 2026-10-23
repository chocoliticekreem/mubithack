--!strict
-- Ragdoll [contract K0 v1.5; body owned by G1]. STUB: does nothing until G1 implements it.
-- "Funky physics" for characters, shared by every system that shoves people around: hose friendly
-- fire and hose recoil (ToolService.HoseHit / .HoseRecoil), explosions, electrocution, fire tornado
-- and tidal wave (HazardService), slaps, axe hits.
--
--   Ragdoll.enable(character: Model, seconds: number): boolean      -- limp for N s, then stand up
--   Ragdoll.knockback(character: Model, impulse: Vector3): boolean  -- velocity change in studs/s
--   Ragdoll.isRagdolled(character: Model): boolean
--
-- Server call: sets the character attr Ragdolled and fires Shared/Ragdoll (S->C, owner only:
-- seconds: number, impulse: Vector3?) to the character's player, because each client owns its own
-- character physics. PhysicsFxController applies it (Motor6D -> BallSocketConstraint swap or
-- PlatformStand, AssemblyLinearVelocity += impulse, clamped to PhysicsConfig.MaxImpulse).
-- Client call (local character only): applies directly. NPCs (server-owned): applied on the server.
-- Returns false when nothing was applied (stub, no Humanoid, already ragdolled for longer).
-- Shared/Ragdoll is declared by Main.server.luau (no single owner), like Shared/Notify.
local Names = require(script.Parent:WaitForChild("Names") :: ModuleScript)

local Ragdoll = {}

function Ragdoll.enable(_character: Model, _seconds: number): boolean
	return false
end

function Ragdoll.knockback(_character: Model, _impulse: Vector3): boolean
	return false
end

function Ragdoll.isRagdolled(character: Model): boolean
	return character:GetAttribute(Names.Attr.Ragdolled) == true
end

function Ragdoll._selftest(): (boolean, string)
	return true, "stub"
end

return Ragdoll
