--!strict
-- FirstPersonController [owner: G1]. STUB from K0 (v1.5): does nothing until G1 replaces this file.
-- Will render: first-person camera lock (LocalPlayer.CameraMode = LockFirstPerson when
-- PhysicsConfig.FirstPerson), FOV, viewmodel gloves/sleeves parented to the camera, head bob scaled by
-- walk speed, and camera shake for hazards. Unlocks while the local character is Ragdolled.
-- (SquadService may also set CameraMode server-side as a fallback; both are idempotent.)
-- Public API for other controllers:
--   FirstPersonController:SetEnabled(on: boolean)             -- e.g. ResultsController unlocks the mouse
--   FirstPersonController:Shake(magnitude: number, seconds: number)
--   FirstPersonController:GetViewmodel(): Model?
local FirstPersonController = {}
FirstPersonController.Priority = 50

function FirstPersonController:Init(_controllers: { [string]: any }) end

function FirstPersonController:Start() end

function FirstPersonController:SetEnabled(_on: boolean) end

function FirstPersonController:Shake(_magnitude: number, _seconds: number) end

function FirstPersonController:GetViewmodel(): Model?
	return nil
end

return FirstPersonController
