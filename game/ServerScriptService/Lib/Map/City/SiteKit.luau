--!strict
-- SiteKit [owner: CityBuilder]. Part helpers for the city: cheap anchored parts, flammable walls
-- with door/window openings (chunked to <= 8 studs), and the IncidentSite contract
-- (docs/game/08 "City"): a Model tagged IncidentSite with attrs SiteId, MissionTypes, Busy,
-- DisplayName, SiteKind, BuildingId, LocationId = "City", RoadNode; children FireStart / RescueSpawn
-- markers, a TruckSpot part and an ArrivalZone part.
--
--   SiteKit.part(parent, name, cf, size, color, opts?) -> Part
--       opts: material, transparency, collide, flammable, fuel, tags, shape, neon, query, cast
--   SiteKit.wedge(parent, name, cf, size, color, opts?) -> WedgePart   -- tall side at +Z
--   SiteKit.cyl(parent, name, cf, height, diameter, color, opts?) -> Part   -- vertical axis
--   SiteKit.ball(parent, name, cf, d, color, opts?) -> Part
--   SiteKit.sign(part, text, face, textColor?, bg?)          -- SurfaceGui text on one face
--   SiteKit.wall(parent, frame, a, b, y0, h, color, openings?, bid?) -- local XZ points a -> b
--       openings: { { at = distance from a (centre), w = width, kind = "door"|"window"|"glass"|"gap", locked? } }
--   SiteKit.newSite(parent, info, frame) -> Model
--   SiteKit.fireStart(site, id, cf) / rescue(site, id, kind, cf, pose, variant?) / truckSpot(site, cf)
--   SiteKit.arrival(site, cf, size?) / hazard(part, hazardId)
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)
local CityConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("CityConfig") :: ModuleScript) :: any

local SiteKit = {}

local hex = Color3.fromHex
SiteKit.C = {
	Asphalt = hex("#46434C"),
	AsphaltDark = hex("#3B3940"),
	Sidewalk = hex("#C9BFB3"),
	Kerb = hex("#A99D90"),
	Concrete = hex("#B7B1A8"),
	Grass = hex("#6E9E45"),
	GrassDark = hex("#5E8C3E"),
	LineYellow = hex("#E3B23C"),
	LineWhite = hex("#EDE8DE"),
	Trim = hex("#F2EDE4"),
	Glass = hex("#9EC9DA"),
	GlassDark = hex("#3E5866"),
	Wood = hex("#9A6A40"),
	RoofBrown = hex("#5A3A32"),
	RoofSlate = hex("#4E4A5A"),
	RoofTerra = hex("#8A4A35"),
	Brick = hex("#A65A44"),
	BrickDark = hex("#7E4536"),
	Metal = hex("#8C9096"),
	MetalDark = hex("#55595E"),
	Red = hex("#C8232B"),
	Water = hex("#4FA3C7"),
	Trunk = hex("#6B4A2F"),
	Leaf = { hex("#5E9E3E"), hex("#77B04A"), hex("#4F8A3A"), hex("#8DBE52") },
	Walls = {
		hex("#E8D3A8"), -- cream
		hex("#D98B6F"), -- salmon
		hex("#9DB38A"), -- sage
		hex("#9EC1CC"), -- pale blue
		hex("#D9C6E3"), -- lilac
		hex("#F2D2B0"), -- peach
		hex("#E9C46A"), -- mustard
		hex("#2A9D8F"), -- teal
	},
	Awnings = { hex("#C8232B"), hex("#2A9D8F"), hex("#E9C46A"), hex("#3D5A80"), hex("#E76F51"), hex("#6A4C93") },
	Furniture = { hex("#B5651D"), hex("#3D5A80"), hex("#8E5572"), hex("#5B8E7D"), hex("#C08552") },
}

export type Opts = {
	material: Enum.Material?,
	transparency: number?,
	collide: boolean?,
	flammable: boolean?,
	fuel: number?,
	tags: { string }?,
	shape: Enum.PartType?,
	neon: boolean?,
	query: boolean?,
	cast: boolean?,
}

local function apply(p: BasePart, color: Color3, o: Opts)
	p.Anchored = true
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = if o.neon then Enum.Material.Neon else (o.material or Enum.Material.SmoothPlastic)
	p.Color = color
	p.Transparency = o.transparency or 0
	p.CanCollide = if o.collide == nil then true else o.collide
	if o.query == false then
		p.CanQuery = false
	end
	if o.cast == false then
		p.CastShadow = false
	end
	if o.flammable then
		CollectionService:AddTag(p, Names.Tag.Flammable)
		p:SetAttribute(Names.Attr.Fuel, o.fuel or 20)
	end
	for _, t in o.tags or {} do
		CollectionService:AddTag(p, t)
	end
end

function SiteKit.part(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, opts: Opts?): Part
	local o = opts or {} :: Opts
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	if o.shape then
		p.Shape = o.shape
	end
	apply(p, color, o)
	p.Parent = parent
	return p
end

function SiteKit.wedge(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, opts: Opts?): WedgePart
	local w = Instance.new("WedgePart")
	w.Name = name
	w.Size = size
	w.CFrame = cf
	apply(w, color, opts or {})
	w.Parent = parent
	return w
end

local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

function SiteKit.cyl(parent: Instance, name: string, cf: CFrame, height: number, d: number, color: Color3, opts: Opts?): Part
	local o = table.clone(opts or {}) :: Opts
	o.shape = Enum.PartType.Cylinder
	return SiteKit.part(parent, name, cf * UPRIGHT, Vector3.new(height, d, d), color, o)
end

function SiteKit.ball(parent: Instance, name: string, cf: CFrame, d: number, color: Color3, opts: Opts?): Part
	local o = table.clone(opts or {}) :: Opts
	o.shape = Enum.PartType.Ball
	return SiteKit.part(parent, name, cf, Vector3.one * d, color, o)
end

function SiteKit.sign(p: BasePart, text: string, face: Enum.NormalId, textColor: Color3?, bg: Color3?)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 20
	gui.LightInfluence = 0.2
	gui.MaxDistance = 260
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = bg or p.Color
	t.BackgroundTransparency = if bg then 0 else 1
	t.TextColor3 = textColor or Color3.new(1, 1, 1)
	t.TextScaled = true
	t.Font = Enum.Font.FredokaOne
	t.Text = text
	t.Parent = gui
	gui.Parent = p
end

-- Flammable wall from local point a to b (XZ of `frame`), bottom at y0, height h, 1 thick.
-- Openings are centred `at` studs from a; solid runs are chunked to <= 8 studs.
function SiteKit.wall(parent: Instance, frame: CFrame, a: Vector3, b: Vector3, y0: number, h: number, color: Color3, openings: { any }?, bid: string?): { BasePart }
	local out: { BasePart } = {}
	local d = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local len = d.Magnitude
	if len < 0.05 then
		return out
	end
	local dir = d.Unit
	local rot = CFrame.lookAt(Vector3.zero, dir) -- local Z along the wall
	local across = rot * CFrame.Angles(0, math.rad(90), 0) -- local X along the wall (doors, panes)
	local function at(s: number, y: number): CFrame
		local p = a + dir * s
		return frame * CFrame.new(p.X, y, p.Z)
	end
	local function solid(s0: number, s1: number, yb: number, yt: number, name: string)
		local l = s1 - s0
		if l < 0.05 or yt - yb < 0.05 then
			return
		end
		local n = math.max(1, math.ceil(l / 8))
		for i = 1, n do
			local m = s0 + (i - 0.5) * l / n
			local p = SiteKit.part(parent, name, at(m, (yb + yt) / 2) * rot, Vector3.new(1, yt - yb, l / n), color, {
				flammable = true,
				fuel = 25,
			})
			if bid then
				p:SetAttribute(Names.Attr.BuildingId, bid)
			end
			table.insert(out, p)
		end
	end
	local ops = table.clone(openings or {})
	table.sort(ops, function(x, y)
		return x.at < y.at
	end)
	local cursor = 0
	for _, op in ops do
		local s0, s1 = op.at - op.w / 2, op.at + op.w / 2
		solid(cursor, s0, y0, y0 + h, "Wall")
		if op.kind == "door" then
			local door = MapKit.door(parent, "Door", at(op.at, y0 + 3.5) * across, op.locked == true)
			if bid then
				door:SetAttribute(Names.Attr.BuildingId, bid)
			end
			solid(s0, s1, y0 + 7, y0 + h, "Lintel")
		elseif op.kind == "window" then
			solid(s0, s1, y0, y0 + 3, "Sill")
			local win = MapKit.window(parent, "Window", at(op.at, y0 + 5) * across)
			win.Size = Vector3.new(op.w, 4, 0.3)
			solid(s0, s1, y0 + 7, y0 + h, "Lintel")
		elseif op.kind == "glass" then
			solid(s0, s1, y0, y0 + 1.5, "Sill")
			SiteKit.part(parent, "Window", at(op.at, y0 + 4.5) * across, Vector3.new(op.w, 6, 0.3), SiteKit.C.Glass, {
				material = Enum.Material.Glass,
				transparency = 0.45,
				tags = { Names.Tag.Window },
			})
			solid(s0, s1, y0 + 7.5, y0 + h, "Lintel")
		elseif op.kind == "gap" then
			solid(s0, s1, y0 + (op.top or 8), y0 + h, "Lintel")
		end
		cursor = s1
	end
	solid(cursor, len, y0, y0 + h, "Wall")
	return out
end

-- The IncidentSite Model. `frame` = the building's front-centre on the ground, -Z = toward the street.
function SiteKit.newSite(parent: Instance, info: any, frame: CFrame): Model
	local m = Instance.new("Model")
	m.Name = info.siteId
	CollectionService:AddTag(m, CityConfig.SiteTag)
	m:SetAttribute("SiteId", info.siteId)
	m:SetAttribute("MissionTypes", info.missionTypes)
	m:SetAttribute("Busy", false)
	m:SetAttribute("DisplayName", info.displayName)
	m:SetAttribute("SiteKind", info.kind)
	m:SetAttribute("District", info.district)
	m:SetAttribute("RoadNode", info.roadNode)
	m:SetAttribute(Names.Attr.BuildingId, info.siteId)
	m:SetAttribute(Names.Attr.LocationId, "City")
	m.WorldPivot = frame
	m.Parent = parent
	return m
end

local function marker(parent: Instance, name: string, cf: CFrame, size: Vector3, tag: string?, attrs: { [string]: any }?): Part
	local p = SiteKit.part(parent, name, cf, size, SiteKit.C.Red, {
		transparency = 1,
		collide = false,
		query = false,
		cast = false,
		tags = if tag then { tag } else nil,
	})
	for k, v in attrs or {} do
		p:SetAttribute(k, v)
	end
	return p
end
SiteKit.marker = marker

function SiteKit.fireStart(site: Model, id: string, cf: CFrame): Part
	return marker(site, id, cf, Vector3.new(2, 2, 2), Names.Tag.FireStart, {
		FireId = id,
		[Names.Attr.BuildingId] = site.Name,
	})
end

-- cf = feet on the floor; -Z of cf is the facing direction.
function SiteKit.rescue(site: Model, id: string, kind: string, cf: CFrame, pose: string, variant: string?): Part
	return marker(site, id, cf * CFrame.new(0, 1, 0), Vector3.new(2, 2, 2), Names.Tag.RescueSpawn, {
		[Names.Attr.Kind] = kind,
		SpawnId = id,
		[Names.Attr.BuildingId] = site.Name,
		Pose = pose,
		Variant = variant,
	})
end

-- cf = parking spot on the ground, -Z = the way the parked truck faces.
function SiteKit.truckSpot(site: Model, cf: CFrame): Part
	local p = marker(site, "TruckSpot", cf * CFrame.new(0, 0.5, 0), Vector3.new(4, 1, 4), Names.Tag.TruckSpot, {
		[Names.Attr.LocationId] = "City",
		SiteId = site.Name,
	})
	return p
end

function SiteKit.arrival(site: Model, cf: CFrame, size: Vector3?): Part
	local s = size or CityConfig.ArrivalSize
	local p = marker(site, "ArrivalZone", cf * CFrame.new(0, s.Y / 2, 0), s, CityConfig.ArrivalTag, { SiteId = site.Name })
	p.CanTouch = true
	return p
end

function SiteKit.hazard(p: BasePart, hazardId: string)
	CollectionService:AddTag(p, Names.Tag.Hazard)
	p:SetAttribute(Names.Attr.HazardId, hazardId)
end

return SiteKit
