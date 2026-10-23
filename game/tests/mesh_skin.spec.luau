--!strict
-- MeshSkin + VisualConfig: hero-mesh fallback rules and per-side placement.
local Spec = require("./Spec")
local MeshSkin = require("../ServerScriptService/Lib/Map/Props/MeshSkin")
local Cfg = require("../ReplicatedStorage/Config/VisualConfig") :: any

local IDS = {
	FireTruckHero = "rbxassetid://1",
	FireTruckHero_Texture = "rbxassetid://2",
	TruckWheel = "rbxassetid://3",
	TruckWheel_Texture = "",
	TruckDoor = "rbxassetid://4",
	TruckLightBar = "",
	TruckCab = "rbxassetid://5",
}

local function cfg(over: { [string]: any }?): any
	local c = table.clone(Cfg)
	c.Meshes = table.clone(Cfg.Meshes)
	for k, v in over or {} do
		c[k] = v
	end
	return c
end

Spec.test("resolves an enabled mesh with its texture and fitted size", function()
	local s = MeshSkin.resolve("FireTruckHero", IDS, cfg()) :: MeshSkin.Spec
	Spec.truthy(s ~= nil, "hero resolves")
	Spec.eq(s.meshId, "rbxassetid://1")
	Spec.eq(s.textureId, "rbxassetid://2")
	Spec.eq(s.size[3], Cfg.Meshes.FireTruckHero.size[3])
	local w = MeshSkin.resolve("TruckWheel", IDS, cfg()) :: MeshSkin.Spec
	Spec.eq(w.textureId, "") -- no texture is fine, the mesh still applies
end)

Spec.test("falls back (nil) when the id is empty or missing", function()
	Spec.eq(MeshSkin.resolve("TruckLightBar", IDS, cfg()), nil)
	Spec.eq(MeshSkin.resolve("FireAxe", IDS, cfg()), nil)
	Spec.eq(MeshSkin.resolve("FireTruckHero", nil, cfg()), nil)
	Spec.eq(MeshSkin.resolve("FireTruckHero", { FireTruckHero = 123 }, cfg()), nil)
end)

Spec.test("falls back when the master switch is off or the entry is disabled/unknown", function()
	Spec.eq(MeshSkin.resolve("FireTruckHero", IDS, cfg({ UseHeroMeshes = false })), nil)
	Spec.eq(MeshSkin.resolve("FireTruckHero", IDS, nil), nil)
	Spec.eq(MeshSkin.resolve("TruckCab", IDS, cfg()), nil) -- kit cab is off by default
	Spec.eq(MeshSkin.resolve("Nope", { Nope = "rbxassetid://9" }, cfg()), nil)
	local c = cfg()
	c.Meshes.FireTruckHero = { enabled = true, size = { 0, 1, 1 } }
	Spec.eq(MeshSkin.resolve("FireTruckHero", IDS, c), nil) -- a zero size is a broken entry
end)

Spec.test("left side mirrors: 180 degree yaw for one-sided meshes, offset.x for sided ones", function()
	local w = MeshSkin.resolve("TruckWheel", IDS, cfg()) :: MeshSkin.Spec
	local _, rR = MeshSkin.place(w, "R")
	local _, rL = MeshSkin.place(w, "L")
	Spec.eq(rR[2], -90) -- hub (-Z) faces +X on the right
	Spec.eq(rL[2], 90) -- and -X on the left
	local d = MeshSkin.resolve("TruckDoor", IDS, cfg()) :: MeshSkin.Spec
	local oR = MeshSkin.place(d, "R")
	local oL, dL = MeshSkin.place(d, "L")
	Spec.eq(oR[1], Cfg.Meshes.TruckDoor.offset[1])
	Spec.eq(oL[1], -Cfg.Meshes.TruckDoor.offset[1])
	Spec.eq(math.abs(dL[2]), 180)
	local h = MeshSkin.resolve("FireTruckHero", IDS, cfg()) :: MeshSkin.Spec
	local oh, rh = MeshSkin.place(h, nil)
	Spec.eq(oh[3], Cfg.Meshes.FireTruckHero.offset[3])
	Spec.eq(rh[2], 0)
	Spec.eq(h.offset[1], Cfg.Meshes.FireTruckHero.offset[1]) -- place() never mutates the spec
end)

Spec.test("hide list matches by prefix only", function()
	local hide = Cfg.Truck.Hide
	Spec.truthy(MeshSkin.matches("CabRoof", hide), "cab shell")
	Spec.truthy(MeshSkin.matches("BodyTop", hide), "Body prefix")
	Spec.truthy(MeshSkin.matches("GrilleBar_3", hide), "Grille prefix")
	Spec.truthy(not MeshSkin.matches("BobbleBody", hide), "bobblehead stays")
	Spec.truthy(not MeshSkin.matches("Locker_L1", hide), "lockers stay (gameplay)")
	Spec.truthy(not MeshSkin.matches("Fender_Rear_L", hide), "rear fender stays over the deck axle")
	Spec.truthy(not MeshSkin.matches("SunVisor_L", hide), "interior stays")
	Spec.truthy(not MeshSkin.matches("Anything", nil), "nil list")
end)

Spec.test("hero fitting stays inside the truck footprint", function()
	local h = Cfg.Meshes.FireTruckHero
	Spec.truthy(h.offset[3] - h.size[3] / 2 >= -13.6, "front at the bumper")
	Spec.truthy(h.offset[3] + h.size[3] / 2 <= 6.7, "stops before the crew deck")
	Spec.truthy(h.size[1] <= 10.01 and h.size[2] <= 9.61, "10 x 9.6 footprint")
	local ax = Cfg.Truck.HeroAxleZ
	Spec.truthy(ax.Front < ax.Mid and ax.Mid < ax.Rear, "axles front to back")
	Spec.truthy(Cfg.Truck.PanelX < 5.05 - 0.06, "side plates sit inside the lockers")
end)

Spec.test("Set rejects unknown keys", function()
	local ok = pcall(function()
		Cfg.Set("NotAKey", 1)
	end)
	Spec.truthy(not ok, "unknown key errors")
end)

return Spec.finish()
