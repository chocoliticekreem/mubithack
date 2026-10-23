--!strict
-- TruckBuilder [owner: G2]. Fire truck No. 67 (docs/game/02 §FireTruck, docs/TARGET_GAME.md ending shot).
-- API: TruckBuilder.Build(parent: Instance, cf: CFrame): Model
--   cf = ground point under the truck centre; the truck faces -Z of cf. About 10 W x 9.6 H x 27 L studs.
--   Static, fully anchored model (VehicleService makes it drivable later). PrimaryPart = "Chassis".
--   Tags: model -> Names.Tag.Truck; "Reel" (hose reel, ProximityPrompt "Refill") -> TruckRefill;
--   "RescueDropoff" (invisible, non-collide, CanTouch box at the open back) -> RescueDropoff.
--   Named parts for VehicleService/VehicleController: Chassis, Wheel_<axle>_<L|R>, LightRed, LightBlue,
--   LightWhite, Siren, Headlight_L/R, TailLight_L/R, Bench_L/R (crew seats), Deck.
-- TruckBuilder.Preview (Studio command bar or execute_luau, Edit mode):
--   local T = require(game.ServerScriptService.Lib.Map.Props.TruckBuilder)
--   local old = workspace:FindFirstChild("FireTruck67"); if old then old:Destroy() end
--   T.Build(workspace, CFrame.new(0, 0, 0))   -- then frame it with F in the Explorer
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)

local TruckBuilder = {}

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

	-- Coordinates: x = right, y = up, z = back (front bumper near z = -13.5, tail near z = +13.5).
	---------------------------------------------------------------- chassis + wheels
	local chassis = P("Chassis", Vector3.new(0, 2.0, 0), Vector3.new(8.4, 1.2, 25), Tyre)
	P("SideSkirt_L", Vector3.new(-4.85, 2.5, 1.5), Vector3.new(0.3, 0.8, 3.6), Steel)
	P("SideSkirt_R", Vector3.new(4.85, 2.5, 1.5), Vector3.new(0.3, 0.8, 3.6), Steel)

	local axles = { Front = -10.2, Mid = 5.4, Rear = 9.4 }
	for axleName, z in axles do
		for _, side in { -1, 1 } do
			local s = if side < 0 then "L" else "R"
			P(`Wheel_{axleName}_{s}`, Vector3.new(side * 4.2, 1.8, z), Vector3.new(1.6, 3.6, 3.6), Tyre, { shape = Enum.PartType.Cylinder })
			P(`Hub_{axleName}_{s}`, Vector3.new(side * 4.45, 1.8, z), Vector3.new(1.4, 1.9, 1.9), Steel, { shape = Enum.PartType.Cylinder, collide = false })
			P(`HubCap_{axleName}_{s}`, Vector3.new(side * 5.1, 1.8, z), Vector3.new(0.2, 0.8, 0.8), Chrome, { shape = Enum.PartType.Cylinder, collide = false })
		end
	end
	-- Wheel arches (chunky red fenders over each axle).
	for axleName, z in axles do
		for _, side in { -1, 1 } do
			P(`Fender_{axleName}_{if side < 0 then "L" else "R"}`, Vector3.new(side * 4.6, 3.95, z), Vector3.new(1.4, 0.5, 4.0), TruckRedDark)
		end
	end

	---------------------------------------------------------------- cab (z -13 .. -5)
	P("CabLower", Vector3.new(0, 4.2, -9), Vector3.new(10, 3.6, 8), TruckRed)
	P("CabUpper", Vector3.new(0, 7.1, -8.7), Vector3.new(10, 2.2, 7.4), TruckRed)
	P("CabRoof", Vector3.new(0, 8.45, -8.8), Vector3.new(10.2, 0.5, 7.8), TruckRed)
	-- Windshield (front face of the upper cab) with a chrome frame and a centre pillar.
	P("Windshield", Vector3.new(0, 7.1, -12.45), Vector3.new(8.8, 1.9, 0.15), GlassTint, { material = Enum.Material.Glass, transparency = 0.15, collide = false })
	P("WindshieldPillar", Vector3.new(0, 7.1, -12.5), Vector3.new(0.35, 1.9, 0.2), TruckRedDark, deco)
	P("Visor", Vector3.new(0, 8.25, -12.65), Vector3.new(9.4, 0.35, 0.6), TruckRedDark, deco)
	-- Side windows.
	for _, side in { -1, 1 } do
		local s = if side < 0 then "L" else "R"
		P(`SideWindow_{s}`, Vector3.new(side * 5.03, 7.1, -10.3), Vector3.new(0.12, 1.7, 3.6), GlassTint, { material = Enum.Material.Glass, transparency = 0.15, collide = false })
		P(`RearWindow_{s}`, Vector3.new(side * 5.03, 7.1, -6.9), Vector3.new(0.12, 1.7, 2.6), GlassTint, { material = Enum.Material.Glass, transparency = 0.15, collide = false })
		-- Door: darker seam + white badge with "67".
		P(`DoorSeam_{s}`, Vector3.new(side * 5.02, 4.4, -6.9), Vector3.new(0.1, 3.4, 3.8), TruckRedDark, deco)
		P(`DoorPanel_{s}`, Vector3.new(side * 5.06, 4.4, -6.9), Vector3.new(0.1, 3.1, 3.5), TruckRed, deco)
		P(`DoorHandle_{s}`, Vector3.new(side * 5.15, 5.4, -5.6), Vector3.new(0.15, 0.25, 0.8), Chrome, deco)
		local badge = P(`DoorBadge_{s}`, Vector3.new(side * 5.13, 4.4, -6.9), Vector3.new(0.08, 1.8, 2.4), White, deco)
		P(`DoorBadgeRim_{s}`, Vector3.new(side * 5.11, 4.4, -6.9), Vector3.new(0.06, 2.1, 2.7), Gold, deco)
		label(badge, if side < 0 then Enum.NormalId.Left else Enum.NormalId.Right, "67", TruckRed, Ink)
		-- Mirror on an arm.
		P(`MirrorArm_{s}`, Vector3.new(side * 5.5, 6.6, -11.6), Vector3.new(1.0, 0.2, 0.2), Ink, deco)
		P(`Mirror_{s}`, Vector3.new(side * 6.05, 6.9, -11.6), Vector3.new(0.3, 1.3, 0.7), Ink, deco)
		-- Step under the door.
		P(`CabStep_{s}`, Vector3.new(side * 4.9, 2.55, -6.9), Vector3.new(0.9, 0.3, 2.6), Chrome, { material = Enum.Material.DiamondPlate })
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
	P("LightBarBase", Vector3.new(0, 8.9, -11.4), Vector3.new(8.0, 0.45, 1.4), Ink)
	P("LightRed", Vector3.new(-2.6, 9.4, -11.4), Vector3.new(2.6, 0.6, 1.1), Color3.fromRGB(255, 45, 45), { neon = true, collide = false })
	P("LightWhite", Vector3.new(0, 9.4, -11.4), Vector3.new(1.8, 0.5, 1.0), Color3.fromRGB(255, 250, 235), { neon = true, collide = false })
	P("LightBlue", Vector3.new(2.6, 9.4, -11.4), Vector3.new(2.6, 0.6, 1.1), Color3.fromRGB(45, 120, 255), { neon = true, collide = false })

	---------------------------------------------------------------- body / side compartments (z -5 .. 6.6)
	P("Body", Vector3.new(0, 4.8, 0.8), Vector3.new(10, 4.8, 11.6), TruckRed)
	P("BodyTop", Vector3.new(0, 7.35, 0.8), Vector3.new(10.2, 0.3, 11.8), TruckRedDark)
	-- Rolling-shutter compartment doors: 3 per side, chrome with ribs and a handle bar.
	local doorZ = { -2.9, 0.8, 4.5 }
	for _, side in { -1, 1 } do
		local s = if side < 0 then "L" else "R"
		for i, z in doorZ do
			P(`Locker_{s}{i}`, Vector3.new(side * 5.05, 4.3, z), Vector3.new(0.12, 3.1, 3.2), Chrome, { material = Enum.Material.Metal, collide = false })
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

	m.PrimaryPart = chassis
	CollectionService:AddTag(m, Names.Tag.Truck)
	m.Parent = parent
	return m
end

return TruckBuilder
