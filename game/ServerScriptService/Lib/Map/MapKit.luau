--!strict
-- MapKit [owner: G2]. The only part helpers builders use. Everything is Anchored and built under an
-- unparented Model (MapService parents it once). Large flammable surfaces are split into <= 8-stud
-- chunks so fire stays local. Style: chunky low-poly, SmoothPlastic, warm colours (docs/game/02).
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)

local MapKit = {}

MapKit.WarmColors = {
	Color3.fromRGB(233, 196, 106), -- mustard
	Color3.fromRGB(231, 111, 81), -- terracotta
	Color3.fromRGB(244, 162, 97), -- peach
	Color3.fromRGB(42, 157, 143), -- teal
	Color3.fromRGB(168, 218, 220), -- pale blue
	Color3.fromRGB(205, 180, 219), -- lilac
}
MapKit.Red = Color3.fromRGB(200, 40, 35)
MapKit.White = Color3.fromRGB(240, 236, 228)
MapKit.Black = Color3.fromRGB(25, 22, 22)
MapKit.Wood = Color3.fromRGB(150, 100, 60)
MapKit.Grass = Color3.fromRGB(110, 150, 80)
MapKit.Asphalt = Color3.fromRGB(60, 60, 66)
MapKit.Concrete = Color3.fromRGB(170, 168, 160)

export type PartOpts = {
	color: Color3?,
	material: Enum.Material?,
	shape: Enum.PartType?,
	transparency: number?,
	collide: boolean?,
	flammable: boolean?,
	fuel: number?,
	tags: { string }?,
	neon: boolean?,
}

-- One anchored part at `cf` with `size`, parented to `parent`.
function MapKit.part(parent: Instance, name: string, cf: CFrame, size: Vector3, opts: PartOpts?): Part
	local o = opts or {} :: PartOpts
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanTouch = false
	p.Size = size
	p.CFrame = cf
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = if o.neon then Enum.Material.Neon else (o.material or Enum.Material.SmoothPlastic)
	p.Color = o.color or MapKit.Concrete
	if o.shape then
		p.Shape = o.shape
	end
	p.Transparency = o.transparency or 0
	p.CanCollide = if o.collide == nil then true else o.collide
	if o.flammable then
		CollectionService:AddTag(p, Names.Tag.Flammable)
		if o.fuel then
			p:SetAttribute(Names.Attr.Fuel, o.fuel)
		end
	end
	for _, t in o.tags or {} do
		CollectionService:AddTag(p, t)
	end
	p.Parent = parent
	return p
end

-- Ground slab: top surface at origin's Y.
function MapKit.slab(parent: Instance, name: string, origin: CFrame, size: Vector3, color: Color3?): Part
	return MapKit.part(parent, name, origin * CFrame.new(0, -size.Y / 2, 0), size, { color = color or MapKit.Grass })
end

-- A wall from local point a to b (on the XZ plane of `origin`), height h, thickness t.
-- Split into <= 8-stud chunks; flammable unless opts.flammable == false.
function MapKit.wall(parent: Instance, name: string, origin: CFrame, a: Vector3, b: Vector3, h: number, opts: PartOpts?): { Part }
	local o = table.clone(opts or {} :: any) :: PartOpts
	if o.flammable == nil then
		o.flammable = true
	end
	local t = 1
	local d = b - a
	local len = d.Magnitude
	local n = math.max(1, math.ceil(len / 8))
	local out = {}
	local dir = d.Unit
	local rot = CFrame.lookAt(Vector3.zero, dir) -- part length (Z) runs along the wall
	for i = 1, n do
		local mid = a + dir * ((i - 0.5) * len / n)
		local cf = origin * CFrame.new(mid.X, mid.Y + h / 2, mid.Z) * rot
		table.insert(out, MapKit.part(parent, `{name}_{i}`, cf, Vector3.new(t, h, len / n), o))
	end
	return out
end

-- A door panel (tagged Door, ProximityPrompt "Open"/"Break"). Locked doors need the axe.
function MapKit.door(parent: Instance, name: string, cf: CFrame, locked: boolean): Part
	local d = MapKit.part(parent, name, cf, Vector3.new(4, 7, 0.6), {
		color = if locked then Color3.fromRGB(120, 60, 40) else MapKit.Wood,
		flammable = true,
		fuel = 30,
		tags = { Names.Tag.Door },
	})
	d:SetAttribute(Names.Attr.Locked, locked)
	d:SetAttribute(Names.Attr.Broken, false)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = if locked then "Break (axe)" else "Open"
	prompt.ObjectText = "Door"
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = d
	return d
end

-- A 4x4 window pane (tagged Window).
function MapKit.window(parent: Instance, name: string, cf: CFrame): Part
	return MapKit.part(parent, name, cf, Vector3.new(4, 4, 0.3), {
		color = Color3.fromRGB(180, 220, 240),
		material = Enum.Material.Glass,
		transparency = 0.4,
		tags = { Names.Tag.Window },
	})
end

-- Red fire hydrant (tagged Hydrant; decoration: no prompt, trucks have endless water). cf = base on the ground.
function MapKit.hydrant(parent: Instance, cf: CFrame): Model
	local m = Instance.new("Model")
	m.Name = "Hydrant"
	local body = MapKit.part(m, "Body", cf * CFrame.new(0, 1.5, 0), Vector3.new(1.4, 3, 1.4), {
		color = MapKit.Red,
		shape = Enum.PartType.Cylinder,
		tags = { Names.Tag.Hydrant },
	})
	body.CFrame = cf * CFrame.new(0, 1.5, 0) * CFrame.Angles(0, 0, math.rad(90))
	MapKit.part(m, "Cap", cf * CFrame.new(0, 3.2, 0), Vector3.new(1.6, 0.6, 1.6), { color = MapKit.Red })
	MapKit.part(m, "NozzleL", cf * CFrame.new(-0.9, 2, 0), Vector3.new(0.6, 0.6, 0.6), { color = Color3.fromRGB(230, 200, 60) })
	MapKit.part(m, "NozzleR", cf * CFrame.new(0.9, 2, 0), Vector3.new(0.6, 0.6, 0.6), { color = Color3.fromRGB(230, 200, 60) })
	m.PrimaryPart = body
	m.Parent = parent
	return m
end

-- Big googly eyes (white ball + black pupil) at `cf` facing -Z of cf. size = eye diameter.
function MapKit.googlyEyes(parent: Instance, cf: CFrame, size: number, gap: number?)
	local g = gap or size * 0.55
	for i, side in { -1, 1 } do
		local eyeCf = cf * CFrame.new(side * g, 0, 0)
		local eye = MapKit.part(parent, `Eye{i}`, eyeCf, Vector3.one * size, {
			color = MapKit.White,
			shape = Enum.PartType.Ball,
			collide = false,
		})
		eye.Massless = true
		local pupil = MapKit.part(parent, `Pupil{i}`, eyeCf * CFrame.new(0, -size * 0.08, -size * 0.38), Vector3.one * size * 0.42, {
			color = MapKit.Black,
			shape = Enum.PartType.Ball,
			collide = false,
		})
		pupil.Massless = true
	end
end

function MapKit.pick<T>(rng: Random, list: { T }): T
	return list[rng:NextInteger(1, #list)]
end

-- Stable string hash (same as MapService) for per-building seeds.
function MapKit.hash(s: string): number
	local h = 0
	for i = 1, #s do
		h = (h * 31 + string.byte(s, i)) % 1000003
	end
	return h
end

return MapKit
