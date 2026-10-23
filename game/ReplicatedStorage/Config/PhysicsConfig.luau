--!strict
-- PhysicsConfig [owner: G1]. First-person camera feel and ragdoll/knockback limits (v1.5).
-- Read on the client by FirstPersonController / PhysicsFxController, and by Ragdoll on both sides.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	FirstPerson = true, -- lock the camera to first person (LocalPlayer.CameraMode)
	FieldOfView = 80,
	HeadBobAmplitude = 0.12, -- studs at walk speed
	HeadBobHz = 1.8, -- steps per second at walk speed
	ViewmodelGloves = true, -- gloves + sleeves viewmodel (Palette.GloveOlive / CoatYellow)
	RagdollMaxSeconds = 4, -- longest single ragdoll
	MaxImpulse = 120, -- studs/s cap on one knockback (tornado fling ~100)
	HoseHitImpulse = 25, -- studs/s per friendly-fire hose hit (docs/game/01 §7.5)
	SlapImpulse = 8,
	ExplosionImpulse = 80,
})
