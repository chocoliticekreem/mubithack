--!strict
-- HazardController [owner: GF]. STUB from K0 (v1.5): does nothing until GF replaces this file.
-- Will render: Hazard/Zapped (skeleton flash, screen white-out), Hazard/Fx (tornado column, explosion
-- flash, tidal wave sweep), live-puddle glow on WetFloor parts while their FuseBox has Power = true,
-- and camera shake through FirstPersonController:Shake.
local HazardController = {}
HazardController.Priority = 100

function HazardController:Init(_controllers: { [string]: any }) end

function HazardController:Start() end

return HazardController
