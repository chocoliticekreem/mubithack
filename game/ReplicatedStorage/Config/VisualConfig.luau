--!strict
-- VisualConfig [owner: Assets/visuals lane]. Which generated hero meshes (assets/manifest.json ->
-- Config/AssetIds) replace part-built visuals, and how each one is fitted. Read by
-- ServerScriptService/Lib/Map/Props/MeshSkin (+ TruckBuilder). docs/game/07-assets.md.
--
-- DATA ONLY: no requires, no Roblox APIs, so game/tests/mesh_skin.spec.luau can load it with `luau`.
-- Fallback rule: an asset keeps its part-built look when UseHeroMeshes = false, its entry has
-- enabled = false, its AssetIds id is "" / missing, or the mesh fails to load.
-- Vectors are { x, y, z } in studs; rot is degrees, applied as CFrame.Angles(rx, ry, rz) after offset.
-- size is the MeshPart.Size in the mesh's OWN axes (before rot). "native" = the mesh's MeshSize.
-- mirrorL = true: the left-side copy is turned 180 degrees about Y (Roblox has no negative scale).
-- Tune live (server; rebuild the truck after):
--   ServerStorage.DevHook:Invoke("VisualConfig", ".Set", "UseHeroMeshes", false)
--
-- Orientation facts (checked live 2026-10-23): FireTruckHero faces -Z (same as TruckBuilder) and its
-- "67" texture is mirrored on the +X side and the back. TruckWheel's axle is its Z axis with the hub
-- on the -Z face. TruckLightBar's lenses face -Z (red at +X). TruckDoor's art is on +X (manifest).

local VisualConfig = {
	-- master switch: false = everything part-built. Keep it OFF for the truck: FireTruckHero is a whole
	-- closed toy truck (own short cab, windows, wheels, a baked-in driver) 4.7x5.2x8 native, so fitted
	-- over our enterable cab you see the part-built cab/dash through its windows and sit inside its shell
	-- in cab view ("a truck inside the truck"); it can't cover the open crew deck either. Checked live
	-- 2026-10-23.
	UseHeroMeshes = false,
	RenderFidelity = "Automatic", -- Enum.RenderFidelity name (Automatic = LOD, mobile friendly)
	CollisionFidelity = "Box", -- skins never collide; Box is the cheapest

	Meshes = {
		-- Whole truck in one mesh, fitted over the cab + equipment box (truck-local z -13.5 .. 6.6);
		-- the open crew deck behind it stays part-built.
		FireTruckHero = {
			enabled = true,
			native = { 4.685, 5.227, 8.0 },
			size = { 10, 9.6, 20.1 },
			offset = { 0, 4.8, -3.45 },
			rot = { 0, 0, 0 },
		},
		-- One per Wheel_<axle>_<side> part, offset/rot relative to that wheel's centre.
		-- Axle = mesh Z, hub on -Z: yaw -90 puts the hub on +X (right side); mirrorL flips it for the left.
		TruckWheel = {
			enabled = true,
			native = { 1.6, 1.607, 0.779 },
			size = { 4.0, 4.0, 1.7 },
			offset = { 0, 0.2, 0 },
			rot = { 0, -90, 0 },
			mirrorL = true,
		},
		-- Roof light bar housing; the LightRed/White/Blue neon parts sit on top of it and still flash.
		TruckLightBar = {
			enabled = true,
			native = { 1.859, 1.0, 0.686 },
			size = { 7.0, 1.2, 1.4 },
			offset = { 0, 9.3, -10.4 }, -- on the hero cab roof (its own pods are ~9.0)
			rot = { 0, 0, 0 },
		},
		-- On each hinged DoorPanel (swings with it). offset.x is mirrored per side (x * -1 on the left).
		TruckDoor = {
			enabled = true,
			native = { 0.5, 0.506, 0.469 },
			size = { 0.4, 5.4, 3.1 },
			offset = { 4.85, 5.4, -6.65 },
			rot = { 0, 0, 0 },
			mirrorL = true,
			sided = true,
		},
		-- Kit alternative to the hero (front cab + rear box); off: both came back with their own wheels.
		TruckCab = { enabled = false, native = { 6.7, 6.5, 7.9 }, size = { 10.2, 6.4, 8.2 }, offset = { 0, 5.55, -8.9 }, rot = { 0, 0, 0 } },
		TruckBody = { enabled = false, native = { 4.463, 5.0, 9.748 }, size = { 10, 4.8, 11.6 }, offset = { 0, 4.8, 0.8 }, rot = { 0, 0, 0 } },
	},

	-- Truck fitting while the hero mesh is on (TruckBuilder).
	Truck = {
		-- wheel centres (truck-local z) so the TruckWheel skins sit over the hero's own two axles;
		-- the rear axle stays under the open crew deck. Part-built axles: Front -10.2, Mid 5.4, Rear 9.4.
		HeroAxleZ = { Front = -9.28, Mid = 2.18, Rear = 9.4 },
		-- red plates over the hero's box sides / back (they hide the mirrored "67"), with our own "67"
		PanelX = 4.6, -- |x| of the side plates (hero box side ~4.46; lockers stand proud at 5.05)
		PanelZ = { -5.0, 6.4 }, -- side plate z range
		PanelY = { 2.9, 7.9 }, -- side + back plate y range
		BackPanelZ = 6.62, -- back plate (faces the crew deck)
		RoofBadgeY = 9.0, -- the overhead "67" sits on the hero's roof
		PanelColor = "#DE2C2A", -- plates match the hero texture's red (TruckRed reads darker beside it)
		-- part names (prefix match) hidden under the hero mesh; they keep colliding
		Hide = {
			"CabNose", "CabCowl", "CabBack", "CabRoof", "CabHeader", "CabSideFront_", "APillar_", "BPillar_",
			"DoorSill_", "Windshield", "Visor", "SideWindow_", "MirrorArm_", "Mirror_", "MirrorGlass_",
			"CabStep_", "Grille", "HeadlightRim_", "Headlight_", "Indicator_", "FrontBumper", "StripeFront",
			"Stripe_", "Body", "Fender_Front_", "Fender_Mid_", "SideSkirt_", "StripeCab_", "CabRoofEdge",
			"CabCorner_", "CabRoofCorner_", "AirHorn", "FuelTank_", "FuelStrap_", "Exhaust", "FenderLip_Front_",
			"FenderLip_Mid_",
		} :: { string },
	},
}

-- Same contract as Shared/Config.define (kept inline so this module has no requires).
;(VisualConfig :: any).Set = function(key: string, value: any)
	if (VisualConfig :: any)[key] == nil then
		error(`[Config] unknown key {key}`)
	end
	(VisualConfig :: any)[key] = value
end

return VisualConfig
