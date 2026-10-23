--!strict
-- TruckBuilder [owner: G2]. Fire truck No. 67 (docs/game/02 §FireTruck, docs/TARGET_GAME.md ending shot).
-- API: TruckBuilder.Build(parent: Instance, cf: CFrame): Model
--   cf = ground point under the truck centre; the truck faces -Z of cf. About 10 W x 9.6 H x 27 L studs.
--   Static, fully anchored model (VehicleService makes it drivable later). PrimaryPart = "Chassis".
--   Tags: model -> Names.Tag.Truck; "Reel" (hose reel, ProximityPrompt "Refill") -> TruckRefill;
--   "RescueDropoff" (invisible, non-collide, CanTouch box at the open back) -> RescueDropoff.
--   Named parts for VehicleService/VehicleController: Chassis, Wheel_<axle>_<L|R>, LightRed, LightBlue,
--   LightWhite, Siren, Headlight_L/R, TailLight_L/R, Bench_L/R (crew seats), Deck.
-- v2 mount points (docs/game/08 "Vehicles" / "Inventory"):
--   "Locker_<L|R><1..3>" tagged TruckCompartment, attr Item (TruckBuilder.CompartmentItems) -> InventoryService
--   "DriveSeat" (VehicleSeat, driver side of the cab), "CrewSeat_1..4" (back benches), "CrewSeat_5" (shotgun)
--   -> VehicleService welds everything to the Chassis when it makes the truck drivable, except parts
--   with attr Jointed = true: the hinged doors ("Door_L"/"Door_R" Models, root "DoorPanel_<s>",
--   HingeConstraint "DoorHinge", handle "DoorHandle_<s>"), the steering wheel (Motor6D "SteeringMotor")
--   and the dash bobblehead (Motor6D "BobbleMotor").
-- Cab interior: dash with gauges, glowing buttons, radio, siren switch panel, steering wheel, two
--   cushioned seats, door trims, rear-view mirror, sun visors, dome light ("CabLight"), bobblehead.
-- Hero mesh skins (MeshSkin + Config/VisualConfig, ids from Config/AssetIds; each one falls back to the
--   part-built look when its id is "" / it fails to load / VisualConfig.UseHeroMeshes = false):
--   "HeroSkin" (FireTruckHero) over the cab + equipment box: the parts it replaces go Transparency 1
--     but keep colliding (VisualConfig.Truck.Hide); the visual wheels move onto its two axles; red
--     plates + our own "67" cover its mirrored "67" (right side + back).
--   "WheelSkin_<axle>_<s>" (TruckWheel) per wheel, "LightBarSkin" (TruckLightBar) under the flashing
--   neon lights, "DoorSkin_<s>" (TruckDoor) welded to each hinged door panel.
--   Skins are MeshParts: CanCollide/CanQuery/CanTouch false, Massless, attr MeshSkin = asset key.
-- TruckBuilder.Preview (Studio command bar or execute_luau, Edit mode):
--   local T = require(game.ServerScriptService.Lib.Map.Props.TruckBuilder)
--   local old = workspace:FindFirstChild("FireTruck67"); if old then old:Destroy() end
--   T.Build(workspace, CFrame.new(0, 0, 0))   -- then frame it with F in the Explorer
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)
local MeshSkin = require(script.Parent:WaitForChild("MeshSkin") :: ModuleScript)

local TruckBuilder = {}

-- Tag string (not in the frozen Names yet, so fall back to the literal).
TruckBuilder.CompartmentTag = (Names.Tag :: any).TruckCompartment or "TruckCompartment"
-- Item in each side locker, front to back (Inventory item ids).
TruckBuilder.CompartmentItems = { "Axe", "Extinguisher", "OxygenTank" }

-- Palette (docs/game/02 §1).
local TruckRed = Color3.fromRGB(200, 35, 43) -- #C8232B
local TruckRedDark = Color3.fromRGB(150, 24, 30)
local Chrome = Color3.fromRGB(214, 216, 220) -- #D6D8DC
local Steel = Color3.fromRGB(150, 152, 158)
local Tyre = Color3.fromRGB(34, 34, 34) -- #222
local Ink = Color3.fromRGB(26, 18, 16) -- #1A1210 NumberInk
local White = Color3.fromRGB(242, 238, 230)
local Gold = Color3.fromRGB(232, 194, 74) -- #E8C24A HelmetShield
local HoseYellow = Color3.fromRGB(232, 184, 58) -- #E8B83A
local Brass = Color3.fromRGB(200, 154, 60) -- #C89A3C
local GlassTint = Color3.fromRGB(120, 175, 200)
local BenchWood = Color3.fromRGB(138, 74, 40) -- #8A4A28
local HeadlightGlow = Color3.fromRGB(255, 244, 196)
local Charcoal = Color3.fromRGB(52, 52, 58)
local SeatLeather = Color3.fromRGB(92, 34, 30)

local ROT_Z_AXIS = CFrame.Angles(0, math.rad(90), 0) -- cylinder axis (X) -> Z

-- "67" (or any text) on one face of `part`.
local function label(part: BasePart, face: Enum.NormalId, text: string, color: Color3, strokeColor: Color3?)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Label"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 60
	gui.LightInfluence = 0.6
	local t = Instance.new("TextLabel")
	t.Name = "Text"
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Text = text
	t.Font = Enum.Font.LuckiestGuy
	t.TextScaled = true
	t.TextColor3 = color
	if strokeColor then
		t.TextStrokeColor3 = strokeColor
		t.TextStrokeTransparency = 0
	else
		t.TextStrokeTransparency = 1
	end
	t.Parent = gui
	gui.Parent = part
end

function TruckBuilder.Build(parent: Instance, cf: CFrame): Model
	local m = Instance.new("Model")
	m.Name = "FireTruck67"

	-- Local helper: block at local position `pos` (relative to cf), optional extra rotation.
	local function P(name: string, pos: Vector3, size: Vector3, color: Color3, opts: MapKit.PartOpts?, rot: CFrame?): Part
		local o = table.clone(opts or {} :: any) :: MapKit.PartOpts
		o.color = color
		local at = cf * CFrame.new(pos)
		if rot then
			at *= rot
		end
		return MapKit.part(m, name, at, size, o)
	end
	local deco: MapKit.PartOpts = { collide = false }

	-- Hero mesh first (it decides where the visual wheels go); parented at the end.
	local visual = MeshSkin.config() or {}
	local truckCfg = (visual :: any).Truck or {}
	local heroSpec = MeshSkin.spec("FireTruckHero")
	local hero = if heroSpec then MeshSkin.make(heroSpec, "HeroSkin", cf) else nil

	-- Coordinates: x = right, y = up, z = back (front bumper near z = -13.5, tail near z = +13.5).
	---------------------------------------------------------------- chassis + wheels
	local chassis = P("Chassis", Vector3.new(0, 2.0, 0), Vector3.new(8.4, 1.2, 25), Tyre)
	P("SideSkirt_L", Vector3.new(-4.85, 2.5, 1.5), Vector3.new(0.3, 0.8, 3.6), Steel)
	P("SideSkirt_R", Vector3.new(4.85, 2.5, 1.5), Vector3.new(0.3, 0.8, 3.6), Steel)

	local axles = { Front = -10.2, Mid = 5.4, Rear = 9.4 }
	if hero and type(truckCfg.HeroAxleZ) == "table" then
		for k, z in truckCfg.HeroAxleZ do
			if axles[k] and type(z) == "number" then
				axles[k] = z
			end
		end
	end
	for axleName, z in axles do
		for _, side in { -1, 1 } do
			local s = if side < 0 then "L" else "R"
			P(`Wheel_{axleName}_{s}`, Vector3.new(side * 4.2, 1.8, z), Vector3.new(1.6, 3.6, 3.6), Tyre, { shape = Enum.PartType.Cylinder })
			P(`Hub_{axleName}_{s}`, Vector3.new(side * 4.45, 1.8, z), Vector3.new(1.4, 1.9, 1.9), Steel, { shape = Enum.PartType.Cylinder, collide = false })
			P(`HubCap_{axleName}_{s}`, Vector3.new(side * 5.1, 1.8, z), Vector3.new(0.2, 0.8, 0.8), Chrome, { shape = Enum.PartType.Cylinder, collide = false })
		end
	end
	local wheelSpec = MeshSkin.spec("TruckWheel")
	if wheelSpec then
		for axleName, z in axles do
			for _, side in { -1, 1 } do
				local s = if side < 0 then "L" else "R"
				local skin = MeshSkin.make(wheelSpec, `WheelSkin_{axleName}_{s}`, cf * CFrame.new(side * 4.2, 1.8, z), s)
				if skin then
					skin.Parent = m
					MeshSkin.hide({ m:FindFirstChild(`Wheel_{axleName}_{s}`) :: any, m:FindFirstChild(`Hub_{axleName}_{s}`) :: any, m:FindFirstChild(`HubCap_{axleName}_{s}`) :: any })
				end
			end
		end
	end
	-- Wheel arches (chunky red fenders over each axle).
	for axleName, z in axles do
		for _, side in { -1, 1 } do
			P(`Fender_{axleName}_{if side < 0 then "L" else "R"}`, Vector3.new(side * 4.6, 3.95, z), Vector3.new(1.4, 0.5, 4.0), TruckRedDark)
		end
	end

	---------------------------------------------------------------- cab (z -13 .. -5): a hollow shell you can sit in
	local shell: { Instance } = {} -- exterior shell parts (hidden when a TruckCab mesh skin is used)
	local function S(part: Part): Part
		table.insert(shell, part)
		return part
	end
	S(P("CabFloor", Vector3.new(0, 2.75, -8.8), Vector3.new(9.4, 0.5, 7.6), Charcoal, { material = Enum.Material.DiamondPlate }))
	S(P("CabNose", Vector3.new(0, 4.2, -12.75), Vector3.new(10, 3.6, 0.5), TruckRed))
	S(P("CabCowl", Vector3.new(0, 6.08, -12.45), Vector3.new(10, 0.25, 0.45), TruckRedDark))
	S(P("CabBack", Vector3.new(0, 5.3, -4.95), Vector3.new(10, 5.8, 0.3), TruckRed))
	S(P("CabRoof", Vector3.new(0, 8.45, -8.8), Vector3.new(10.2, 0.5, 7.8), TruckRed))
	S(P("CabHeader", Vector3.new(0, 8.07, -12.45), Vector3.new(10, 0.3, 0.4), TruckRed))
	-- Windshield with a chrome frame and a centre pillar.
	P("Windshield", Vector3.new(0, 7.1, -12.45), Vector3.new(8.8, 1.9, 0.15), GlassTint, { material = Enum.Material.Glass, transparency = 0.35, collide = false })
	P("WindshieldPillar", Vector3.new(0, 7.1, -12.5), Vector3.new(0.35, 1.9, 0.2), TruckRedDark, deco)
	P("Visor", Vector3.new(0, 8.25, -12.65), Vector3.new(9.4, 0.35, 0.6), TruckRedDark, deco)
	for _, side in { -1, 1 } do
		local s = if side < 0 then "L" else "R"
		local x = side * 4.85
		-- lower side wall in front of the door (over the front wheel) + quarter glass above it
		S(P(`CabSideFront_{s}`, Vector3.new(x, 4.2, -10.6), Vector3.new(0.3, 3.6, 4.8), TruckRed))
		P(`SideWindow_{s}`, Vector3.new(side * 4.95, 7.08, -10.25), Vector3.new(0.12, 2.0, 3.9), GlassTint, { material = Enum.Material.Glass, transparency = 0.35, collide = false })
		S(P(`APillar_{s}`, Vector3.new(x, 7.1, -12.35), Vector3.new(0.35, 2.2, 0.35), TruckRed))
		S(P(`BPillar_{s}`, Vector3.new(x, 7.1, -8.27), Vector3.new(0.3, 2.2, 0.2), TruckRed))
		S(P(`DoorSill_{s}`, Vector3.new(x, 2.62, -6.65), Vector3.new(0.3, 0.25, 3.1), TruckRedDark))
		-- Mirror on an arm.
		P(`MirrorArm_{s}`, Vector3.new(side * 5.5, 6.6, -11.6), Vector3.new(1.0, 0.2, 0.2), Ink, deco)
		P(`Mirror_{s}`, Vector3.new(side * 6.05, 6.9, -11.6), Vector3.new(0.3, 1.3, 0.7), Ink, deco)
		P(`MirrorGlass_{s}`, Vector3.new(side * 6.05, 6.9, -11.24), Vector3.new(0.22, 1.15, 0.04), GlassTint, { material = Enum.Material.Glass, collide = false })
		-- Step under the door.
		P(`CabStep_{s}`, Vector3.new(side * 4.9, 2.4, -6.65), Vector3.new(0.9, 0.3, 2.6), Chrome, { material = Enum.Material.DiamondPlate })
	end

	-- Doors: each one is its own Model ("Door_L"/"Door_R") welded to DoorPanel_<s>, hinged at its front
	-- edge to CabSideFront_<s> (HingeConstraint "DoorHinge"). Parts carry attr Jointed = true so
	-- VehicleService doesn't weld them to the chassis; it sets the hinge limits/servo.
	for _, side in { -1, 1 } do
		local s = if side < 0 then "L" else "R"
		local door = Instance.new("Model")
		door.Name = `Door_{s}`
		door:SetAttribute("Side", s)
		door.Parent = m
		local function D(name: string, pos: Vector3, size: Vector3, color: Color3, opts: MapKit.PartOpts?, rot: CFrame?): Part
			local part = P(name, pos, size, color, opts, rot)
			part.Parent = door
			part:SetAttribute("Jointed", true)
			return part
		end
		local x = side * 4.85
		local panel = D(`DoorPanel_{s}`, Vector3.new(x, 4.375, -6.65), Vector3.new(0.3, 3.25, 3.0), TruckRed)
		D(`DoorFrameTop_{s}`, Vector3.new(x, 8.05, -6.65), Vector3.new(0.25, 0.2, 3.0), TruckRed)
		D(`DoorFrameBack_{s}`, Vector3.new(x, 6.98, -5.25), Vector3.new(0.25, 1.95, 0.2), TruckRed)
		D(`DoorFrameFront_{s}`, Vector3.new(x, 6.98, -8.05), Vector3.new(0.25, 1.95, 0.2), TruckRed)
		D(`DoorWindow_{s}`, Vector3.new(x, 6.98, -6.65), Vector3.new(0.1, 1.95, 2.6), GlassTint, { material = Enum.Material.Glass, transparency = 0.35, collide = false })
		D(`DoorSeam_{s}`, Vector3.new(side * 5.01, 4.375, -6.65), Vector3.new(0.04, 3.05, 2.8), TruckRedDark, deco)
		D(`DoorHandle_{s}`, Vector3.new(side * 5.08, 5.55, -5.7), Vector3.new(0.16, 0.28, 0.85), Chrome, { material = Enum.Material.Metal, collide = false })
		local badge = D(`DoorBadge_{s}`, Vector3.new(side * 5.05, 4.25, -6.65), Vector3.new(0.06, 1.8, 2.2), White, deco)
		D(`DoorBadgeRim_{s}`, Vector3.new(side * 5.03, 4.25, -6.65), Vector3.new(0.05, 2.1, 2.5), Gold, deco)
		label(badge, if side < 0 then Enum.NormalId.Left else Enum.NormalId.Right, "67", TruckRed, Ink)
		-- inside: trim, armrest, pull handle
		D(`DoorTrim_{s}`, Vector3.new(side * 4.68, 4.5, -6.65), Vector3.new(0.05, 2.4, 2.6), Charcoal, deco)
		D(`DoorArmrest_{s}`, Vector3.new(side * 4.55, 4.95, -6.5), Vector3.new(0.3, 0.25, 1.7), SeatLeather, { material = Enum.Material.Fabric, collide = false })
		D(`DoorPull_{s}`, Vector3.new(side * 4.62, 5.45, -7.55), Vector3.new(0.12, 0.2, 0.6), Chrome, deco)
		for _, part in door:GetChildren() do
			if part:IsA("BasePart") and part ~= panel then
				local w = Instance.new("WeldConstraint")
				w.Part0 = panel
				w.Part1 = part
				w.Parent = part
			end
		end
		door.PrimaryPart = panel
		-- Hinge line: front edge of the door, vertical. Primary axis = -Y on the left and +Y on the
		-- right, so a positive hinge angle swings the door OUT on both sides.
		local post = m:FindFirstChild(`CabSideFront_{s}`) :: BasePart
		local hingeWorld = CFrame.fromMatrix((cf * CFrame.new(side * 5.0, 5.3, -8.15)).Position, cf.UpVector * side, cf.LookVector)
		local a0 = Instance.new("Attachment")
		a0.Name = "DoorHingeA"
		a0.Parent = post
		a0.WorldCFrame = hingeWorld
		local a1 = Instance.new("Attachment")
		a1.Name = "DoorHingeB"
		a1.Parent = panel
		a1.WorldCFrame = hingeWorld
		local hinge = Instance.new("HingeConstraint")
		hinge.Name = "DoorHinge"
		hinge.Attachment0 = a0
		hinge.Attachment1 = a1
		hinge.LimitsEnabled = true
		hinge.LowerAngle = 0
		hinge.UpperAngle = 95
		hinge.Parent = panel
		-- skin with a generated mesh when the assets lane has one
		local doorSpec = MeshSkin.spec("TruckDoor")
		local doorSkin = if doorSpec then MeshSkin.make(doorSpec, `DoorSkin_{s}`, cf, s) else nil
		if doorSkin then
			MeshSkin.hide(door:GetChildren())
			doorSkin.Parent = door
			doorSkin:SetAttribute("Jointed", true) -- swings with the door (VehicleService skips Jointed parts)
			local dw = Instance.new("WeldConstraint")
			dw.Part0 = panel
			dw.Part1 = doorSkin
			dw.Parent = doorSkin
		end
	end

	---------------------------------------------------------------- cab interior
	-- dashboard
	P("Dash", Vector3.new(0, 5.2, -11.6), Vector3.new(9.4, 1.6, 1.6), Charcoal, deco)
	P("DashTop", Vector3.new(0, 6.05, -11.75), Vector3.new(9.4, 0.2, 1.4), Ink, { material = Enum.Material.Fabric, collide = false })
	P("DashTrim", Vector3.new(0, 5.98, -10.82), Vector3.new(9.4, 0.08, 0.06), Chrome, deco)
	-- gauge cluster (driver side) + big speedo
	local function gauge(name: string, x: number, y: number, dia: number, needleDeg: number)
		P(`{name}Rim`, Vector3.new(x, y, -10.78), Vector3.new(0.08, dia + 0.14, dia + 0.14), Chrome, { shape = Enum.PartType.Cylinder, collide = false }, ROT_Z_AXIS)
		P(`{name}Face`, Vector3.new(x, y, -10.74), Vector3.new(0.04, dia, dia), White, { shape = Enum.PartType.Cylinder, collide = false }, ROT_Z_AXIS)
		P(`{name}Needle`, Vector3.new(x, y, -10.71), Vector3.new(0.05, dia * 0.42, 0.03), Color3.fromRGB(255, 50, 40), { neon = true, collide = false }, CFrame.Angles(0, 0, math.rad(needleDeg)) * CFrame.new(0, dia * 0.18, 0))
	end
	gauge("GaugeFuel", -3.35, 5.45, 0.55, 50)
	gauge("Speedo", -2.4, 5.2, 0.85, -35)
	gauge("GaugeTemp", -1.45, 5.45, 0.55, -60)
	-- glowing buttons
	local btnColors = { Color3.fromRGB(255, 60, 60), Color3.fromRGB(80, 255, 120), Color3.fromRGB(255, 190, 40), Color3.fromRGB(70, 150, 255) }
	for i, c in btnColors do
		P(`DashButton_{i}`, Vector3.new(-0.85 + (i - 1) * 0.32, 5.62, -10.76), Vector3.new(0.22, 0.22, 0.06), c, { neon = true, collide = false })
	end
	-- radio
	P("Radio", Vector3.new(0.45, 5.0, -10.77), Vector3.new(1.6, 0.55, 0.08), Ink, deco)
	local radioDisplay = P("RadioDisplay", Vector3.new(0.3, 5.03, -10.72), Vector3.new(0.9, 0.26, 0.04), Color3.fromRGB(120, 255, 170), { neon = true, collide = false })
	label(radioDisplay, Enum.NormalId.Back, "67.0 FM", Ink)
	for i, dx in { -0.45, 1.0 } do
		P(`RadioKnob_{i}`, Vector3.new(0.45 + dx * 0.6, 5.0, -10.7), Vector3.new(0.12, 0.22, 0.22), Chrome, { shape = Enum.PartType.Cylinder, collide = false }, ROT_Z_AXIS)
	end
	-- siren switch panel
	P("SirenPanel", Vector3.new(2.5, 5.35, -10.77), Vector3.new(1.9, 0.85, 0.08), Ink, deco)
	local sirenLabel = P("SirenPanelLabel", Vector3.new(2.5, 5.9, -10.77), Vector3.new(1.9, 0.26, 0.05), TruckRed, deco)
	label(sirenLabel, Enum.NormalId.Back, "SIREN", White)
	for i = 1, 3 do
		local sx = 1.9 + (i - 1) * 0.42
		P(`SirenSwitch_{i}`, Vector3.new(sx, 5.42, -10.68), Vector3.new(0.1, 0.32, 0.1), Chrome, deco, CFrame.Angles(math.rad(25), 0, 0))
		P(`SirenGuard_{i}`, Vector3.new(sx, 5.2, -10.7), Vector3.new(0.22, 0.08, 0.14), Color3.fromRGB(255, 60, 40), { neon = true, collide = false })
	end
	P("WailButton", Vector3.new(3.2, 5.3, -10.71), Vector3.new(0.08, 0.38, 0.38), Color3.fromRGB(255, 40, 40), { shape = Enum.PartType.Cylinder, neon = true, collide = false }, ROT_Z_AXIS)
	-- rear-view mirror + sun visors
	P("RearViewMirror", Vector3.new(0, 7.65, -12.1), Vector3.new(1.5, 0.42, 0.12), Ink, deco)
	P("RearViewGlass", Vector3.new(0, 7.65, -12.03), Vector3.new(1.35, 0.3, 0.03), GlassTint, { material = Enum.Material.Glass, collide = false })
	for _, side in { -1, 1 } do
		P(`SunVisor_{if side < 0 then "L" else "R"}`, Vector3.new(side * 2.4, 7.97, -11.9), Vector3.new(2.4, 0.08, 0.9), Charcoal, deco)
	end
	-- headliner + dome light
	P("Headliner", Vector3.new(0, 8.15, -8.7), Vector3.new(9.4, 0.08, 7.2), Color3.fromRGB(196, 188, 172), { material = Enum.Material.Fabric, collide = false })
	local dome = P("DomeLight", Vector3.new(0, 8.09, -8.4), Vector3.new(1.2, 0.08, 0.6), HeadlightGlow, { neon = true, collide = false })
	local domeLight = Instance.new("PointLight")
	domeLight.Name = "CabLight"
	domeLight.Color = Color3.fromRGB(255, 226, 170)
	domeLight.Range = 9
	domeLight.Brightness = 0.7
	domeLight.Shadows = false
	domeLight.Parent = dome
	-- two cushioned seats (driver left, shotgun right)
	for _, side in { -1, 1 } do
		local s = if side < 0 then "L" else "R"
		local x = side * 2.4
		P(`CabSeatBase_{s}`, Vector3.new(x, 3.2, -7.0), Vector3.new(2.2, 0.4, 2.0), Ink, deco)
		P(`CabSeatCushion_{s}`, Vector3.new(x, 3.62, -7.0), Vector3.new(2.6, 0.5, 2.4), SeatLeather, { material = Enum.Material.Fabric, collide = false })
		P(`CabSeatPiping_{s}`, Vector3.new(x, 3.62, -8.21), Vector3.new(2.6, 0.5, 0.06), Gold, deco)
		P(`CabSeatBack_{s}`, Vector3.new(x, 5.1, -5.62), Vector3.new(2.6, 2.6, 0.5), SeatLeather, { material = Enum.Material.Fabric, collide = false }, CFrame.Angles(math.rad(-8), 0, 0))
		P(`CabSeatHeadrest_{s}`, Vector3.new(x, 6.75, -5.45), Vector3.new(1.6, 0.75, 0.45), SeatLeather, { material = Enum.Material.Fabric, collide = false })
	end
	P("GearStick", Vector3.new(-0.7, 3.7, -8.4), Vector3.new(0.12, 1.3, 0.12), Chrome, deco, CFrame.Angles(math.rad(-15), 0, 0))
	P("GearKnob", Vector3.new(-0.7, 4.35, -8.55), Vector3.new(0.38, 0.38, 0.38), Ink, { shape = Enum.PartType.Ball, collide = false })
	-- chunky steering wheel on a Motor6D ("SteeringMotor") so VehicleController can turn it
	local hubCF = cf * CFrame.new(-2.4, 5.95, -9.05) * CFrame.Angles(math.rad(-35), 0, 0)
	local wheel = Instance.new("Model")
	wheel.Name = "SteeringWheel"
	wheel.Parent = m
	local column = MapKit.part(wheel, "SteeringColumn", hubCF * CFrame.new(0, 0, -0.8), Vector3.new(0.35, 0.35, 1.6), { color = Ink, collide = false })
	local hub = MapKit.part(wheel, "SteeringHub", hubCF, Vector3.new(0.6, 0.6, 0.25), { color = TruckRed, collide = false })
	hub:SetAttribute("Jointed", true)
	local function W(name: string, at: CFrame, size: Vector3, color: Color3)
		local part = MapKit.part(wheel, name, at, size, { color = color, collide = false })
		part:SetAttribute("Jointed", true)
		local w = Instance.new("WeldConstraint")
		w.Part0 = hub
		w.Part1 = part
		w.Parent = part
	end
	for i = 0, 11 do
		local a = i * math.pi / 6
		W(`Rim_{i}`, hubCF * CFrame.Angles(0, 0, a) * CFrame.new(0, 1.1, 0), Vector3.new(0.62, 0.24, 0.24), Ink)
	end
	for i, a in { 0, 2 * math.pi / 3, 4 * math.pi / 3 } do
		W(`Spoke_{i}`, hubCF * CFrame.Angles(0, 0, a + math.pi) * CFrame.new(0, 0.55, 0), Vector3.new(0.18, 1.1, 0.1), Steel)
	end
	W("HornCap", hubCF * CFrame.new(0, 0, 0.14), Vector3.new(0.45, 0.45, 0.06), Gold)
	local motor = Instance.new("Motor6D")
	motor.Name = "SteeringMotor"
	motor.Part0 = column
	motor.Part1 = hub
	motor.C0 = column.CFrame:ToObjectSpace(hubCF)
	motor.C1 = CFrame.identity
	motor.Parent = column
	-- bobblehead firefighter on the dash ("BobbleMotor" wobbles on the client)
	local bobBase = P("BobbleBody", Vector3.new(1.3, 6.38, -11.55), Vector3.new(0.45, 0.45, 0.45), TruckRed, { shape = Enum.PartType.Cylinder, collide = false }, CFrame.Angles(0, 0, math.rad(90)))
	local headCF = cf * CFrame.new(1.3, 6.95, -11.55)
	local head = MapKit.part(m, "BobbleHead", headCF, Vector3.new(0.6, 0.6, 0.6), { color = Color3.fromRGB(255, 205, 160), shape = Enum.PartType.Ball, collide = false })
	head:SetAttribute("Jointed", true)
	local helmet = MapKit.part(m, "BobbleHelmet", headCF * CFrame.new(0, 0.22, 0) * CFrame.Angles(0, 0, math.rad(90)), Vector3.new(0.4, 0.68, 0.68), { color = Gold, shape = Enum.PartType.Cylinder, collide = false })
	helmet:SetAttribute("Jointed", true)
	local hw = Instance.new("WeldConstraint")
	hw.Part0 = head
	hw.Part1 = helmet
	hw.Parent = helmet
	local face = MapKit.part(m, "BobbleFace", headCF * CFrame.new(0, -0.02, 0.29), Vector3.new(0.4, 0.3, 0.02), { color = White, transparency = 1, collide = false })
	face:SetAttribute("Jointed", true)
	label(face, Enum.NormalId.Back, ":D", Ink)
	local fw = Instance.new("WeldConstraint")
	fw.Part0 = head
	fw.Part1 = face
	fw.Parent = face
	local bob = Instance.new("Motor6D")
	bob.Name = "BobbleMotor"
	bob.Part0 = bobBase
	bob.Part1 = head
	bob.C0 = bobBase.CFrame:ToObjectSpace(headCF * CFrame.new(0, -0.35, 0))
	bob.C1 = CFrame.new(0, -0.35, 0)
	bob.Parent = bobBase
	-- kit alternative (VisualConfig.Meshes.TruckCab, off by default): skin just the cab shell
	local cabSpec = if hero then nil else MeshSkin.spec("TruckCab")
	local cabSkin = if cabSpec then MeshSkin.make(cabSpec, "CabSkin", cf) else nil
	if cabSkin then
		MeshSkin.hide(shell)
		cabSkin.Parent = m
	end

	-- "67" on the roof for the overhead camera.
	local roofBadge = P("RoofBadge", Vector3.new(0, 8.72, -7.8), Vector3.new(4.2, 0.06, 3.0), White, deco)
	label(roofBadge, Enum.NormalId.Top, "67", TruckRed, Ink)

	-- Front: grille, headlights, bumper, siren.
	P("Grille", Vector3.new(0, 4.3, -13.05), Vector3.new(5.0, 2.6, 0.15), Ink, deco)
	for i = 0, 4 do
		P(`GrilleBar_{i}`, Vector3.new(0, 3.3 + i * 0.5, -13.12), Vector3.new(5.0, 0.18, 0.1), Chrome, deco)
	end
	for _, side in { -1, 1 } do
		local s = if side < 0 then "L" else "R"
		P(`HeadlightRim_{s}`, Vector3.new(side * 3.7, 4.3, -13.05), Vector3.new(0.2, 1.7, 1.7), Chrome, { shape = Enum.PartType.Cylinder, collide = false }, ROT_Z_AXIS)
		P(`Headlight_{s}`, Vector3.new(side * 3.7, 4.3, -13.12), Vector3.new(0.2, 1.3, 1.3), HeadlightGlow, { shape = Enum.PartType.Cylinder, neon = true, collide = false }, ROT_Z_AXIS)
		P(`Indicator_{s}`, Vector3.new(side * 3.7, 3.1, -13.06), Vector3.new(1.0, 0.4, 0.12), Color3.fromRGB(255, 170, 40), { neon = true, collide = false })
	end
	P("FrontBumper", Vector3.new(0, 2.5, -13.4), Vector3.new(10.6, 1.0, 1.0), Chrome, { material = Enum.Material.Metal })
	local siren = P("Siren", Vector3.new(-2.6, 2.5, -14.1), Vector3.new(0.8, 1.1, 1.1), Chrome, { shape = Enum.PartType.Cylinder, material = Enum.Material.Metal }, ROT_Z_AXIS)
	P("SirenGrille", Vector3.new(-2.6, 2.5, -14.52), Vector3.new(0.05, 0.8, 0.8), Ink, { shape = Enum.PartType.Cylinder, collide = false }, ROT_Z_AXIS)
	local sirenSound = Instance.new("Sound")
	sirenSound.Name = "SirenSound"
	sirenSound.Looped = true
	sirenSound.Volume = 0.6
	sirenSound.RollOffMaxDistance = 300
	sirenSound.Parent = siren

	-- Roof light bar: red | white | blue neon on a dark base.
	local barBase = P("LightBarBase", Vector3.new(0, 8.9, -11.4), Vector3.new(8.0, 0.45, 1.4), Ink)
	local lightRed = P("LightRed", Vector3.new(-2.6, 9.4, -11.4), Vector3.new(2.6, 0.6, 1.1), Color3.fromRGB(255, 45, 45), { neon = true, collide = false })
	local lightWhite = P("LightWhite", Vector3.new(0, 9.4, -11.4), Vector3.new(1.8, 0.5, 1.0), Color3.fromRGB(255, 250, 235), { neon = true, collide = false })
	local lightBlue = P("LightBlue", Vector3.new(2.6, 9.4, -11.4), Vector3.new(2.6, 0.6, 1.1), Color3.fromRGB(45, 120, 255), { neon = true, collide = false })
	-- light bar mesh: the housing; the neon parts become thin caps on its lenses (VehicleController
	-- still flashes them by name). The mesh has red at +X, so the caps follow it.
	local barSpec = MeshSkin.spec("TruckLightBar")
	local barSkin = if barSpec then MeshSkin.make(barSpec, "LightBarSkin", cf) else nil
	if barSkin then
		barSkin.Parent = m
		MeshSkin.hide({ barBase })
		local w = barSkin.Size.X / 3
		for i, lp in { lightBlue, lightWhite, lightRed } do
			lp.Size = Vector3.new(w * 0.8, 0.12, barSkin.Size.Z * 0.6)
			lp.CFrame = barSkin.CFrame * CFrame.new((i - 2) * w, barSkin.Size.Y / 2 + 0.06, 0)
		end
	end

	---------------------------------------------------------------- body / side compartments (z -5 .. 6.6)
	P("Body", Vector3.new(0, 4.8, 0.8), Vector3.new(10, 4.8, 11.6), TruckRed)
	P("BodyTop", Vector3.new(0, 7.35, 0.8), Vector3.new(10.2, 0.3, 11.8), TruckRedDark)
	-- Rolling-shutter compartment doors: 3 per side, chrome with ribs and a handle bar.
	local doorZ = { -2.9, 0.8, 4.5 }
	for _, side in { -1, 1 } do
		local s = if side < 0 then "L" else "R"
		for i, z in doorZ do
			local locker = P(`Locker_{s}{i}`, Vector3.new(side * 5.05, 4.3, z), Vector3.new(0.12, 3.1, 3.2), Chrome, {
				material = Enum.Material.Metal,
				collide = false,
				tags = { TruckBuilder.CompartmentTag },
			})
			locker:SetAttribute("Item", TruckBuilder.CompartmentItems[i] or "Axe")
			for r = 1, 3 do
				P(`LockerRib_{s}{i}_{r}`, Vector3.new(side * 5.13, 3.3 + r * 0.75, z), Vector3.new(0.06, 0.08, 3.2), Steel, deco)
			end
			P(`LockerHandle_{s}{i}`, Vector3.new(side * 5.16, 3.05, z), Vector3.new(0.1, 0.25, 1.6), Ink, deco)
		end
	end
	-- White stripe along both sides (body + cab), above the lockers.
	for _, side in { -1, 1 } do
		local s = if side < 0 then "L" else "R"
		P(`Stripe_{s}`, Vector3.new(side * 5.09, 6.35, -3.5), Vector3.new(0.1, 0.8, 19.9), White, deco)
	end
	-- Front stripe across the cab nose, under the windshield.
	P("StripeFront", Vector3.new(0, 5.9, -13.04), Vector3.new(10, 0.5, 0.1), White, deco)

	---------------------------------------------------------------- open crew area at the back (z 6.6 .. 13)
	P("Deck", Vector3.new(0, 2.9, 9.8), Vector3.new(10, 0.6, 6.4), Steel, { material = Enum.Material.DiamondPlate })
	for _, side in { -1, 1 } do
		local s = if side < 0 then "L" else "R"
		P(`SideWall_{s}`, Vector3.new(side * 4.75, 4.0, 9.8), Vector3.new(0.5, 1.6, 6.4), TruckRed)
		P(`SideRail_{s}`, Vector3.new(side * 4.75, 5.5, 9.8), Vector3.new(0.3, 0.3, 6.4), Chrome, { material = Enum.Material.Metal })
		for k, z in { 7.2, 9.8, 12.4 } do
			P(`RailPost_{s}{k}`, Vector3.new(side * 4.75, 5.05, z), Vector3.new(0.25, 0.9, 0.25), Chrome, deco)
		end
		-- Crew bench facing inward (seat + cushion).
		P(`Bench_{s}`, Vector3.new(side * 3.7, 3.8, 10.0), Vector3.new(1.6, 1.2, 5.2), Ink)
		P(`BenchSeat_{s}`, Vector3.new(side * 3.7, 4.5, 10.0), Vector3.new(1.7, 0.25, 5.3), BenchWood)
		-- Grab handle at the rear corners.
		P(`GrabRail_{s}`, Vector3.new(side * 4.75, 6.6, 12.9), Vector3.new(0.25, 2.0, 0.25), Chrome, deco)
	end
	-- Hose reel on the back wall of the compartment block; this is the refill point.
	local reel = P("Reel", Vector3.new(0, 5.4, 7.6), Vector3.new(4.6, 2.4, 2.4), HoseYellow, { shape = Enum.PartType.Cylinder, tags = { Names.Tag.TruckRefill } })
	for _, side in { -1, 1 } do
		P(`ReelFlange_{if side < 0 then "L" else "R"}`, Vector3.new(side * 2.45, 5.4, 7.6), Vector3.new(0.3, 3.1, 3.1), Chrome, { shape = Enum.PartType.Cylinder, material = Enum.Material.Metal })
		P(`ReelBracket_{if side < 0 then "L" else "R"}`, Vector3.new(side * 2.45, 4.2, 7.0), Vector3.new(0.3, 2.4, 0.6), Steel, deco)
	end
	for i = 0, 3 do -- hose wraps as darker bands so it reads as coiled hose
		P(`HoseWrap_{i}`, Vector3.new(-1.65 + i * 1.1, 5.4, 7.6), Vector3.new(0.2, 2.5, 2.5), Brass, { shape = Enum.PartType.Cylinder, collide = false })
	end
	P("Nozzle", Vector3.new(1.4, 4.0, 8.4), Vector3.new(0.5, 1.2, 0.5), Brass, deco)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Refill"
	prompt.ObjectText = "Fire Truck 67"
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = reel

	-- Tailboard with the big rear "67", tail lights, step bumper.
	local tail = P("Tailgate", Vector3.new(0, 3.8, 12.85), Vector3.new(10, 1.6, 0.5), TruckRed)
	local tailBadge = P("TailBadge", Vector3.new(0, 3.8, 13.13), Vector3.new(3.2, 1.4, 0.06), White, deco)
	label(tailBadge, Enum.NormalId.Back, "67", TruckRed, Ink)
	for _, side in { -1, 1 } do
		local s = if side < 0 then "L" else "R"
		P(`TailLight_{s}`, Vector3.new(side * 3.9, 3.8, 13.13), Vector3.new(1.4, 0.8, 0.1), Color3.fromRGB(255, 40, 40), { neon = true, collide = false })
		P(`ReverseLight_{s}`, Vector3.new(side * 2.6, 3.8, 13.13), Vector3.new(0.6, 0.6, 0.1), White, { neon = true, collide = false })
	end
	P("RearBumper", Vector3.new(0, 2.4, 13.4), Vector3.new(10.4, 0.6, 1.2), Chrome, { material = Enum.Material.DiamondPlate })
	tail:SetAttribute("Seats", "crew") -- marker for VehicleService (crew climbs over the tailgate)

	---------------------------------------------------------------- ladder on top
	local ladderY = 8.4
	P("LadderStandFront", Vector3.new(0, 7.9, -3.6), Vector3.new(4.2, 0.8, 0.8), Ink)
	P("LadderStandRear", Vector3.new(0, 7.9, 5.6), Vector3.new(4.2, 0.8, 0.8), Ink)
	-- Two posts carry the ladder's overhang above the crew deck.
	for _, side in { -1, 1 } do
		P(`LadderPost_{if side < 0 then "L" else "R"}`, Vector3.new(side * 1.9, 5.5, 12.6), Vector3.new(0.3, 5.6, 0.3), Ink, deco)
	end
	local ladderLen = 17.6
	local ladderZ = 3.8
	for _, side in { -1, 1 } do
		P(`LadderRail_{if side < 0 then "L" else "R"}`, Vector3.new(side * 1.8, ladderY + 0.1, ladderZ), Vector3.new(0.4, 0.5, ladderLen), Chrome, { material = Enum.Material.Metal })
	end
	local rungs = 12
	for i = 0, rungs - 1 do
		local z = ladderZ - ladderLen / 2 + 0.7 + i * ((ladderLen - 1.4) / (rungs - 1))
		P(`LadderRung_{i}`, Vector3.new(0, ladderY + 0.1, z), Vector3.new(3.2, 0.25, 0.25), Chrome, { material = Enum.Material.Metal, collide = false })
	end

	---------------------------------------------------------------- gameplay volumes
	P("RescueDropoff", Vector3.new(0, 3.5, 15.0), Vector3.new(12, 7, 6), White, {
		transparency = 1,
		collide = false,
		tags = { Names.Tag.RescueDropoff },
	}).CanTouch = true

	---------------------------------------------------------------- seats (mount points; VehicleService welds them)
	local driveSeat = Instance.new("VehicleSeat")
	driveSeat.Name = "DriveSeat"
	driveSeat.Size = Vector3.new(2, 0.4, 2)
	driveSeat.Transparency = 1
	driveSeat.CanCollide = false
	driveSeat.CanTouch = false -- you get in through the door prompt, never by bumping it
	driveSeat.HeadsUpDisplay = false
	driveSeat.Anchored = true
	driveSeat.CFrame = cf * CFrame.new(-2.4, 4.1, -7.0)
	driveSeat.Parent = m
	local n = 0
	for _, side in { -1, 1 } do
		for _, dz in { -1.4, 1.4 } do
			n += 1
			local s = Instance.new("Seat")
			s.Name = `CrewSeat_{n}`
			s.Size = Vector3.new(1.6, 0.3, 2)
			s.Transparency = 1
			s.CanCollide = false
			s.CanTouch = false -- sit via the seat's prompt, never by bumping it
			s.Anchored = true
			-- face the middle of the deck
			s.CFrame = cf * CFrame.new(side * 3.7, 4.8, 10.0 + dz) * CFrame.Angles(0, side * math.pi / 2, 0)
			s.Parent = m
		end
	end

	-- shotgun seat in the cab (right side)
	local shotgun = Instance.new("Seat")
	shotgun.Name = "CrewSeat_5"
	shotgun.Size = Vector3.new(2, 0.4, 2)
	shotgun.Transparency = 1
	shotgun.CanCollide = false
	shotgun.CanTouch = false
	shotgun.Anchored = true
	shotgun.CFrame = cf * CFrame.new(2.4, 4.1, -7.0)
	shotgun.Parent = m

	---------------------------------------------------------------- hero mesh (FireTruckHero)
	if hero then
		hero.Parent = m
		local hidden: { Instance } = {}
		for _, d in m:GetChildren() do
			if d:IsA("BasePart") and d ~= hero and MeshSkin.matches(d.Name, truckCfg.Hide) then
				table.insert(hidden, d)
			end
		end
		MeshSkin.hide(hidden)
		-- Red plates over the box sides + back hide the hero's mirrored "67"; ours goes above the lockers.
		local px = tonumber(truckCfg.PanelX) or 4.6
		local pz = if type(truckCfg.PanelZ) == "table" then truckCfg.PanelZ else { -5.0, 6.4 }
		local py = if type(truckCfg.PanelY) == "table" then truckCfg.PanelY else { 2.9, 7.9 }
		local zc, zl = (pz[1] + pz[2]) / 2, pz[2] - pz[1]
		local yc, yh = (py[1] + py[2]) / 2, py[2] - py[1]
		local numberOpts: MapKit.PartOpts = { collide = false, transparency = 1 }
		local plate = if type(truckCfg.PanelColor) == "string" then Color3.fromHex(truckCfg.PanelColor) else TruckRed
		for _, side in { -1, 1 } do
			local s = if side < 0 then "L" else "R"
			P(`HeroPanel_{s}`, Vector3.new(side * px, yc, zc), Vector3.new(0.12, yh, zl), plate, deco)
			local num = P(`HeroNumber_{s}`, Vector3.new(side * (px + 0.08), py[2] - 1.1, zc), Vector3.new(0.04, 1.7, 3.4), TruckRed, numberOpts)
			label(num, if side < 0 then Enum.NormalId.Left else Enum.NormalId.Right, "67", White, Ink)
		end
		local bz = tonumber(truckCfg.BackPanelZ) or 6.62
		P("HeroBackPanel", Vector3.new(0, yc, bz), Vector3.new(2 * px - 0.2, yh, 0.12), plate, deco)
		local backNum = P("HeroBackNumber", Vector3.new(0, py[2] - 0.9, bz + 0.08), Vector3.new(3.2, 1.4, 0.04), TruckRed, numberOpts)
		label(backNum, Enum.NormalId.Back, "67", White, Ink)
		local roofY = tonumber(truckCfg.RoofBadgeY)
		if roofY then
			roofBadge.CFrame = cf * CFrame.new(0, roofY, -7.8)
		end
	end

	m.PrimaryPart = chassis
	CollectionService:AddTag(m, Names.Tag.Truck)
	m.Parent = parent
	return m
end

return TruckBuilder
