--!strict
-- PhysicsFxController [owner: G1]. STUB from K0 (v1.5): does nothing until G1 replaces this file.
-- Will apply: Shared/Ragdoll (seconds, impulse?) to the local character via Ragdoll (the client owns
-- its character physics), Tool/Pushed (G1.7) velocity, and the local hose recoil while spraying.
-- Also the "funky" extras: wobble on landing, comedic spin on big knockbacks.
local PhysicsFxController = {}
PhysicsFxController.Priority = 100

function PhysicsFxController:Init(_controllers: { [string]: any }) end

function PhysicsFxController:Start() end

return PhysicsFxController
