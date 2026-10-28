--!strict
-- VehicleController [owner: Vehicle agent]. Fire trucks on the client (docs/game/08 "Vehicles").
--   * Driving: when the local player sits in a truck's "DriveSeat" (the server hands them network
--     ownership) this runs the goofy driving every physics step (ClientLib/TruckDrive maths,
--     VehicleConfig numbers), ARCADE handling: raycast springs carry the weight (damped, through the
--     centre of mass), the tyres kill sideways sliding, pitch / roll follow the ground under the truck
--     (no bobbing, wobble or flips; kerbs can't launch it), yaw = speed / turning radius (tight when
--     slow, gentle when fast), the stick sets a target speed and letting go brakes to a stop (and it
--     holds still on slopes). Self-rights after a crash.
--   * Touch (InputHints.isTouch, or the Studio attr DevTouch): dead zone + expo on the stick, a
--     sideways push still drives forward, lower top speed (TouchMaxSpeed), and a released stick
--     lines the truck up with the road (NavigationController:GetRoadDir). Always the chase cam.
--     On a call, touch only: ROUTE ASSIST (DriveConfig.Assist*): while the stick pushes forward nearly centred
--     the turn bends gently toward a point AssistLookAhead studs along the GPS route (NavigationController
--     GetRouteInfo ax / az). Not autopilot: no push, no movement; steering past AssistMaxSteer turns it off.
--   * AUTO-UNSTICK (any device, DriveConfig.Unstick*): pushing UnstickSeconds without getting UnstickStuds
--     anywhere = stuck. The truck is lifted, backed off a few studs (DriveMath.unstickTries) and swung toward
--     the route, only onto anchored ground at the same height with the whole truck box free and a clear
--     sweep there (never through a wall or the map); "UNSTUCK!" pops and Drive/Unstuck (C->S) tells
--     DriveService (UnstuckApplied). No free spot = nothing moves; VehicleService's "Truck reset!" stays the net.
--   * Studio test drives: player attr DevDrive = Vector2(steer, throttle) overrides the seat.
--   * On a call (my run is Dispatched): on a straight stretch of road (DriveMath.straight, the road from
--     NavigationController:GetRoadDir) the TOP SPEED eases up to x DriveConfig.StraightBoostRookie (rookie
--     runs, run attr Rookie) or x StraightBoostCall, and back down into turns. Only the target speed changes:
--     accel, braking, grip and the turning circle (arcadeYaw keeps the normal max) are PR #253's.
--   * Camera while driving: chase cam (spring follow, right-drag to look around, FOV by speed) or the
--     cab view through the windshield (V toggles; you start in it if you sat down in first person; for the local viewer only, the cab/door mesh skins,
--     roof, visors, pillars and your own body go see-through - shotgun passengers in first person get
--     the same). FirstPersonController
--     is paused and comes back on exit.
--   * Keys (VehicleConfig.Key*): WASD drive, SPACE hop out (no drift), G siren, H horn, V camera,
--     R unflip/respawn. Passengers: F hops off. While seated, every ProximityPrompt is hidden and a hint
--     bar shows the keys instead. Getting out is instant: you stand beside the truck on a free spot (Lib/Vehicle/TruckExit).
--     A "RESPAWN TRUCK" button (and R) also shows on foot when your truck is flipped or far away.
--   * Steering wheels turn with each truck's DriveSeat.SteerFloat and the dash bobblehead wobbles
--     (Motor6D "SteeringMotor" / "BobbleMotor", nearby trucks only).
--   * Road wheels: the front pair steer with SteerFloat and every wheel rolls with the chassis'
--     forward speed (Motor6D "WheelMotor" under each "WheelPivot_<axle>_<s>", VehicleConfig.Wheel*).
--   * Everyone: light bars flash and sirens wail (pitch climbs with speed) on trucks with attr SirenOn;
--     "HONK!" pop over a truck on Vehicle/Honked; "SLAM!" / "BONK!" pops on Vehicle/Pop.
-- Local visuals only; gameplay effects (run over, prop hits, blame) are decided by VehicleService.
local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local InputHints = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("InputHints") :: ModuleScript) :: any
local ThumbLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("ThumbLayout") :: ModuleScript)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local VehicleConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("VehicleConfig") :: ModuleScript)
local TruckExit = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Vehicle"):WaitForChild("TruckExit") :: ModuleScript)
local TruckDrive = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("TruckDrive") :: ModuleScript)
local DriveConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("DriveConfig") :: ModuleScript) :: any
local DriveMath = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Vehicle"):WaitForChild("DriveMath") :: ModuleScript)
local WorldPopup = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("WorldPopup") :: ModuleScript)
local Calm = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("Calm") :: ModuleScript)
local Loc = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Loc") :: ModuleScript)

local VehicleController = {}
VehicleController.Priority = 60

local player = Players.LocalPlayer
local controllers: { [string]: any } = {}

-- Suspension corners in chassis space (chassis is 8.4 x 1.2 x 25; front is -Z). First two = front.
local CORNERS = {
	Vector3.new(-3.8, 0, -10.5),
	Vector3.new(3.8, 0, -10.5),
	Vector3.new(-3.8, 0, 10),
	Vector3.new(3.8, 0, 10),
}

local driving: Model? = nil
local handbrake = false
local upsideDown = 0
local airborne = 0
local jumpHiddenOn: Humanoid? = nil -- touch driving hid Roblox's jump button on this humanoid
local boostS = 1 -- smoothed straight-road top-speed multiplier (on a call)
local throttleS = 0 -- smoothed (rate-limited) throttle / steer actually driving the truck
local steerS = 0
local engine: Sound? = nil
local unstickWatch: DriveMath.StuckWatch? = nil -- auto-unstick timer (DriveMath.stuckWatch)
local lastUnstick = 0

-- chase camera state
local camPos: Vector3? = nil
local camYaw = 0
local camPitch = 0
local looking = false
local lookReleasedAt = 0
local camDip = 0
local savedCamType: Enum.CameraType? = nil
local savedFov = 70

local respawnButton: TextButton? = nil
local STATION_RADIUS = 150 -- studs from a TruckBay that count as "at the station"
local hintLabel: TextLabel? = nil
local camMode = "chase" -- "chase" | "cab"
local riding: Model? = nil -- truck the local player sits in as a passenger
local hiddenParts: { [BasePart]: boolean } = {}
local onFootFirstPerson = false -- last on-foot frame was first person (zoomed all the way in)

local function key(name: string, fallback: Enum.KeyCode): Enum.KeyCode
	local ok, k = pcall(function()
		return (Enum.KeyCode :: any)[(VehicleConfig :: any)[name]]
	end)
	return if ok and k then k else fallback
end

---------------------------------------------------------------------------- helpers

-- The truck model the local player is sitting in the DriveSeat of, if any.
local function drivenTruck(): Model?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seatPart = hum and hum.SeatPart
	if not seatPart or seatPart.Name ~= "DriveSeat" then
		return nil
	end
	local m = seatPart.Parent
	return if m and m:IsA("Model") and m:HasTag(Names.Tag.Truck) then m else nil
end

-- the truck I own and drove last (attr OwnerRank 1); trucks change hands, so never by model name
local function myTruck(): Model?
	local f = workspace:FindFirstChild("Trucks")
	local best: Model?, bestRank = nil, math.huge
	for _, m in (if f then f:GetChildren() else {}) do
		if m:IsA("Model") and m:GetAttribute("OwnerUserId") == player.UserId then
			local r = tonumber(m:GetAttribute("OwnerRank")) or 99
			if r < bestRank then
				best, bestRank = m, r
			end
		end
	end
	return best
end

local function rayParams(truck: Model): RaycastParams
	local list: { Instance } = { truck }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = list
	params.IgnoreWater = true
	return params
end

local function pop(root: BasePart, text: string, color: Color3, offset: Vector3)
	-- subtle world text over the truck (ClientLib/WorldPopup: caps, dedupe, feedback setting)
	WorldPopup.show(root, text, { color = color, height = math.max(offset.Y - 2, 2) })
end

---------------------------------------------------------------------------- driving physics

-- A door dragged off its hinge (wedged on a curb or a body) would yank the whole cab over or down
-- into the road; the driver's client owns the doors, so it puts such a door straight back on.
local function rehingeDoors(truck: Model, chassis: BasePart)
	local snap = tonumber((VehicleConfig :: any).DoorHingeSnap) or 1.5
	for _, side in { "L", "R" } do
		local door = truck:FindFirstChild(`Door_{side}`)
		local panel = door and door:FindFirstChild(`DoorPanel_{side}`)
		local h = panel and panel:FindFirstChild("DoorHinge")
		if h and h:IsA("HingeConstraint") and panel:IsA("BasePart") then
			local a0, a1 = h.Attachment0, h.Attachment1
			if a0 and a1 and (a0.WorldPosition - a1.WorldPosition).Magnitude > snap then
				panel.CFrame = a0.WorldCFrame * a1.CFrame:Inverse()
				panel.AssemblyLinearVelocity = chassis.AssemblyLinearVelocity
				panel.AssemblyAngularVelocity = Vector3.zero
			end
		end
	end
end

-- Studio only: scripted test drives. Player attr DevDrive = Vector2(steer, throttle) overrides the
-- seat; DevTouch = true runs it through the touch stick shaping as if it came from a thumb.
local function devInput(): Vector2?
	if not RunService:IsStudio() then
		return nil
	end
	local v = player:GetAttribute("DevDrive")
	return if typeof(v) == "Vector2" then v else nil
end

local function touchDriving(): boolean
	if RunService:IsStudio() and player:GetAttribute("DevTouch") == true then
		return true
	end
	return InputHints.isTouch()
end

-- Touch only: the direction of the road under the truck (NavigationController's road graph), so a
-- released stick lines the truck up with the street instead of drifting into the kerb.
local function roadDir(pos: Vector3): (number?, number?)
	local nav = controllers.NavigationController
	if not nav or type(nav.GetRoadDir) ~= "function" then
		return nil, nil
	end
	local ok, dx, dz = pcall(nav.GetRoadDir, nav, pos.X, pos.Z, tonumber((VehicleConfig :: any).TouchAlignRange) or 16)
	if ok and type(dx) == "number" and type(dz) == "number" then
		return dx, dz
	end
	return nil, nil
end

-- On a call (my run Dispatched): the straight-road top-speed multiplier for this run, else 1.
local function callBoost(): number
	if RunService:IsStudio() and player:GetAttribute("DevNoBoost") == true then
		return 1 -- Studio A/B measurements only
	end
	local id = player:GetAttribute(Names.Attr.InstanceId)
	if type(id) ~= "string" or id == "" then
		return 1
	end
	local runs = workspace:FindFirstChild("Runs")
	local run = runs and runs:FindFirstChild(id)
	if not run or run:GetAttribute(Names.Attr.RoundState) ~= "Dispatched" then
		return 1
	end
	local k = if run:GetAttribute("Rookie") == true then DriveConfig.StraightBoostRookie else DriveConfig.StraightBoostCall
	return math.max(1, tonumber(k) or 1)
end

local function straightRoad(pos: Vector3, fwd: Vector3, steer: number): boolean
	local nav = controllers.NavigationController
	if not nav or type(nav.GetRoadDir) ~= "function" then
		return false
	end
	local ok, dx, dz = pcall(nav.GetRoadDir, nav, pos.X, pos.Z, tonumber(DriveConfig.StraightRoadRange) or 26)
	if not ok or type(dx) ~= "number" or type(dz) ~= "number" then
		return false
	end
	return DriveMath.straight(fwd.X, fwd.Z, dx, dz, steer, tonumber(DriveConfig.StraightMaxDeg) or 12, tonumber(DriveConfig.StraightMaxSteer) or 0.25)
end

-- My run is Dispatched (driving to a call).
local function onCall(): boolean
	local id = player:GetAttribute(Names.Attr.InstanceId)
	if type(id) ~= "string" or id == "" then
		return false
	end
	local runs = workspace:FindFirstChild("Runs")
	local run = runs and runs:FindFirstChild(id)
	return run ~= nil and run:GetAttribute(Names.Attr.RoundState) == "Dispatched"
end

-- The live GPS route (NavigationController:GetRouteInfo) while on a call, else nil.
local function callRoute(): any
	local nav = controllers.NavigationController
	if not nav or type(nav.GetRouteInfo) ~= "function" or not onCall() then
		return nil
	end
	local ok, info = pcall(nav.GetRouteInfo, nav)
	return if ok and type(info) == "table" and not info.arrived then info else nil
end

-- Touch route assist: extra yaw (rad/s, same sign as yawTarget) that bends the truck toward the GPS line
-- ahead, faded out as the stick steers. 0 when off the route, not pushing forward, or the route is behind.
local function routeAssist(pos: Vector3, fwd: Vector3, rawSteer: number, throttle: number, fwdSpeed: number): number
	if DriveConfig.Assist ~= true or throttle < 0.1 or fwdSpeed < (tonumber(DriveConfig.AssistMinSpeed) or 5) then
		return 0
	end
	local w = DriveMath.assistWeight(rawSteer, tonumber(DriveConfig.AssistMaxSteer) or 0.35)
	if w <= 0 then
		return 0
	end
	local info = callRoute()
	if not info or type(info.ax) ~= "number" or type(info.az) ~= "number" then
		return 0
	end
	if (tonumber(info.off) or math.huge) > (tonumber(DriveConfig.AssistMaxOff) or 40) then
		return 0
	end
	local ang = DriveMath.headingTo(fwd.X, fwd.Z, info.ax - pos.X, info.az - pos.Z)
	if math.abs(ang) > math.rad(tonumber(DriveConfig.AssistMaxDeg) or 50) then
		return 0
	end
	return -ang * (tonumber(DriveConfig.AssistGain) or 1.4) * w
end

-- AUTO-UNSTICK. Tries DriveMath.unstickTries() spots behind the truck (away from the push), nose swung toward
-- the route (or the road under it). A spot counts only with anchored, walkable ground within 3 studs of the
-- ground the truck stands on now, the whole truck box free there (things that don't collide with the truck
-- skipped) and a clear straight sweep from here to there. Returns the try that worked, or nil.
local function unstick(truck: Model, chassis: BasePart, push: number): number?
	local cf = chassis.CFrame
	local look = cf.LookVector
	local fwd = Vector3.new(look.X, 0, look.Z)
	if fwd.Magnitude < 0.1 then
		return nil -- on its side: the self-right handles that
	end
	fwd = fwd.Unit
	local right = Vector3.new(-fwd.Z, 0, fwd.X)
	local away = if push >= 0 then -fwd else fwd
	local want = fwd
	local info = callRoute()
	if info and (math.abs(info.dx) + math.abs(info.dz)) > 0.1 then
		want = Vector3.new(info.dx, 0, info.dz).Unit
	else
		local rx, rz = roadDir(chassis.Position)
		if rx and rz then
			local r = Vector3.new(rx, 0, rz)
			want = if r:Dot(fwd) >= 0 then r else -r
		end
	end
	local params = rayParams(truck)
	params.RespectCanCollide = true
	params.CollisionGroup = chassis.CollisionGroup
	local here = workspace:Raycast(chassis.Position + Vector3.new(0, 2, 0), Vector3.new(0, -24, 0), params)
	if not here then
		return nil -- over nothing: VehicleService's net puts it back on a road
	end
	local ride = math.clamp(chassis.Position.Y - here.Position.Y, 1.5, 6)
	local lift = tonumber(DriveConfig.UnstickLift) or 1.2
	local shave = tonumber(DriveConfig.UnstickClearance) or 0.6
	local boxCF, boxSize = truck:GetBoundingBox()
	local rel = cf:ToObjectSpace(boxCF)
	local size = Vector3.new(math.max(boxSize.X - shave * 2, 1), math.max(boxSize.Y - shave * 2 - lift, 1), math.max(boxSize.Z - shave * 2, 1))
	local over = OverlapParams.new()
	over.FilterType = Enum.RaycastFilterType.Exclude
	over.FilterDescendantsInstances = { truck, workspace.Terrain }
	for _, p in Players:GetPlayers() do
		if p.Character then
			over:AddToFilter(p.Character)
		end
	end
	over.RespectCanCollide = true
	over.CollisionGroup = chassis.CollisionGroup
	local sweep = RaycastParams.new()
	sweep.FilterType = Enum.RaycastFilterType.Exclude
	sweep.FilterDescendantsInstances = over.FilterDescendantsInstances
	sweep.RespectCanCollide = true
	sweep.CollisionGroup = chassis.CollisionGroup
	for i, t in DriveMath.unstickTries() do
		local pos = chassis.Position + away * t.back + right * t.side
		local g = workspace:Raycast(Vector3.new(pos.X, here.Position.Y + 6, pos.Z), Vector3.new(0, -12, 0), params)
		if not g or not g.Instance.Anchored or g.Normal.Y < 0.75 or math.abs(g.Position.Y - here.Position.Y) > 3 then
			continue
		end
		local face = fwd:Lerp(want, t.turn)
		face = if face.Magnitude > 0.1 then face.Unit else fwd
		local newCF = CFrame.lookAt(g.Position, g.Position + face) + Vector3.new(0, ride + lift, 0)
		local box = newCF * rel + Vector3.new(0, shave, 0)
		if #workspace:GetPartBoundsInBox(box, size, over) > 0 then
			continue
		end
		-- the way there is clear: never through a wall (the box we start in is ignored by a shapecast)
		local delta = newCF.Position - cf.Position
		local from = (cf * rel) + Vector3.new(0, lift + shave, 0)
		if delta.Magnitude > 0.1 and workspace:Blockcast(from, size * Vector3.new(0.8, 0.7, 0.8), delta, sweep) then
			continue
		end
		truck:PivotTo(newCF * cf:ToObjectSpace(truck:GetPivot()))
		chassis.AssemblyLinearVelocity = Vector3.zero
		chassis.AssemblyAngularVelocity = Vector3.zero
		throttleS, steerS = 0, 0
		return i
	end
	return nil
end

local function unstickStep(truck: Model, chassis: BasePart, push: number)
	if DriveConfig.Unstick ~= true then
		return
	end
	local now = os.clock()
	local p = chassis.Position
	local due
	unstickWatch, due = DriveMath.stuckWatch(
		unstickWatch,
		now,
		p.X,
		p.Z,
		math.abs(push) > 0.25,
		tonumber(DriveConfig.UnstickSeconds) or 3,
		tonumber(DriveConfig.UnstickStuds) or 2.5
	)
	if not due or now - lastUnstick < (tonumber(DriveConfig.UnstickCooldown) or 4) then
		return
	end
	lastUnstick = now
	local ok, try = pcall(unstick, truck, chassis, push)
	local worked = ok and type(try) == "number"
	if worked then
		pop(chassis, Loc.t("UNSTUCK!"), Color3.fromRGB(120, 230, 140), Vector3.new(0, 10, 0))
	end
	pcall(function()
		Net.event("Drive", "Unstuck"):FireServer(if worked then try else 0)
	end)
end

-- Arcade handling ("grips like a Jailbreak car"): the springs only carry the truck's weight, the
-- tyres kill sideways sliding, pitch / roll follow the ground (never the springs or a kerb), yaw is
-- speed / turning radius, the stick sets a target speed and letting go brakes to a stop.
local function step(truck: Model, dt: number)
	local seat = truck:FindFirstChild("DriveSeat") :: VehicleSeat?
	local chassis = truck.PrimaryPart
	if not seat or not chassis or chassis.Anchored then
		return
	end
	rehingeDoors(truck, chassis)
	local cfgAny = VehicleConfig :: any
	-- velocities set here hold for the whole frame: at low fps use a clamped dt for kicks and cap the
	-- per-frame turn (TruckDrive.stepDt / servoGain / capRate), or one slow frame flings the truck
	local h = TruckDrive.stepDt(dt, tonumber(cfgAny.MaxStepDt) or 1 / 30)
	local tiltCap = tonumber(cfgAny.MaxTiltPerFrame) or 0.12
	local cf = chassis.CFrame
	local up = cf.UpVector
	local mass = chassis.AssemblyMass
	local params = rayParams(truck)
	local rest = VehicleConfig.RideRest

	-- Suspension: four rays, each a near-critically damped spring that only LIFTS the truck, through
	-- the centre of mass (no rocking torque). Rays start RayLift above each corner: a ray never hits a
	-- part it starts inside, so a chassis that sank into a thin road top (hard landing, a fling) still
	-- sees that top and is pushed back out instead of falling on through, under the map.
	local lift = tonumber(cfgAny.RayLift) or 2
	local hits = 0
	local deepest = 0 -- studs the chassis bottom sits below the surface it stands on (sunk)
	local bottom = chassis.Size.Y / 2
	local normal = Vector3.zero
	local lifted = 0
	local vUp = chassis.AssemblyLinearVelocity:Dot(up)
	for _, c in CORNERS do
		local origin = cf:PointToWorldSpace(c)
		local res = workspace:Raycast(origin + up * lift, -up * (rest + lift), params)
		local dist = if res then TruckDrive.cornerDist(res.Distance, lift) else nil
		if res and dist and res.Instance.Anchored and res.Instance.CanCollide then
			deepest = math.max(deepest, TruckDrive.sinkDepth(dist, bottom))
		end
		if res and dist and dist < rest then
			hits += 1
			normal += res.Normal
		end
		lifted += TruckDrive.spring(dist, rest, vUp, VehicleConfig.Spring, VehicleConfig.Damping) * 0.25
	end
	if lifted > 0 then
		chassis:ApplyImpulse(up * lifted * mass * h)
	end
	local grounded = hits >= 2
	local ctrl = if grounded then 1 else VehicleConfig.AirControl

	-- Sunk into the ground anyway (a fling, a hard landing on a thin part): lift it back on top right now
	-- and kill the downward speed, before the solver can push it the rest of the way through.
	if deepest > (tonumber(cfgAny.SinkLift) or 0.25) and up.Y > 0.3 then
		chassis.CFrame = chassis.CFrame + Vector3.new(0, deepest + 0.1, 0)
		local vy = chassis.AssemblyLinearVelocity
		chassis.AssemblyLinearVelocity = Vector3.new(vy.X, math.max(vy.Y, 0), vy.Z)
		cf = chassis.CFrame
	end
	-- Speed caps: a box falling faster than ~2 studs a physics step tunnels through thin road tops,
	-- and a crash fling (traffic, lamps, props) can spike the speed far past anything driving does.
	do
		local vc = chassis.AssemblyLinearVelocity
		local fall = tonumber(cfgAny.MaxFallSpeed) or 120
		local fling = tonumber(cfgAny.MaxFlingSpeed) or 150
		if vc.Y < -fall or vc.Magnitude > fling then
			local x, y, z = TruckDrive.capVelocity(vc.X, vc.Y, vc.Z, fall, fling)
			chassis.AssemblyLinearVelocity = Vector3.new(x, y, z)
		end
	end

	local v = chassis.AssemblyLinearVelocity
	airborne = if grounded then 0 else airborne + dt

	local look = cf.LookVector
	local fwd = Vector3.new(look.X, 0, look.Z)
	fwd = if fwd.Magnitude > 0.05 then fwd.Unit else Vector3.new(0, 0, -1)
	local right = Vector3.new(-fwd.Z, 0, fwd.X)
	local fwdSpeed = v:Dot(fwd)
	local lat = v:Dot(right)

	-- input: keyboard / gamepad straight from the seat; a touch thumb goes through dead zone + expo, and
	-- a sideways push still drives (TruckDrive.touchStick). Then rate-limited, so nothing lurches.
	local rawThrottle, rawSteer = seat.ThrottleFloat, seat.SteerFloat
	local dev = devInput()
	if dev then
		rawSteer, rawThrottle = dev.X, dev.Y
	end
	local touch = touchDriving()
	local maxSpeed = VehicleConfig.MaxSpeed
	if touch then
		rawSteer, rawThrottle = TruckDrive.touchStick(
			rawSteer,
			rawThrottle,
			fwdSpeed,
			tonumber(cfgAny.TouchDeadzone) or 0.15,
			tonumber(cfgAny.TouchSteerExpo) or 1.5,
			tonumber(cfgAny.TouchCruise) or 0.45
		)
		maxSpeed = tonumber(cfgAny.TouchMaxSpeed) or maxSpeed
	end
	throttleS = TruckDrive.approach(throttleS, rawThrottle, h, tonumber(cfgAny.ThrottleRise) or 4, tonumber(cfgAny.ThrottleFall) or 8)
	local steerRate = if touch then tonumber(cfgAny.TouchSteerRate) or 4 else tonumber(cfgAny.SteerRate) or 7
	steerS = TruckDrive.approach(steerS, rawSteer, h, steerRate, steerRate * 1.6)
	unstickStep(truck, chassis, rawThrottle)
	local throttle, steer = throttleS, steerS
	if dev then
		chassis:SetAttribute("DevDriveState", Vector3.new(throttle, steer, hits)) -- Studio test drives only
	end

	-- on a call: a quicker top speed on straight roads (eases in, and back out before / in turns)
	local boostWant = 1
	if grounded then
		local k = callBoost()
		if k > 1 and straightRoad(chassis.Position, fwd, steer) then
			boostWant = k
		end
	end
	boostS = DriveMath.approach(boostS, boostWant, h, tonumber(DriveConfig.BoostRise) or 0.8, tonumber(DriveConfig.BoostFall) or 2.5)
	-- drive: target speed from the stick, brake against the motion, coast-down to a stop on release
	local acc = TruckDrive.arcadeDrive(
		throttle,
		fwdSpeed,
		maxSpeed * boostS,
		VehicleConfig.Accel,
		VehicleConfig.Brake,
		tonumber(cfgAny.CoastBrake) or 30
	)
	local dFwd = acc * h * ctrl
	-- braking / coasting stops the truck, it never throws it backwards (only those: a push away from
	-- a near-standstill must not be clamped to a rounding-error residual speed)
	local slowing = math.abs(throttle) < 0.02 or math.abs(fwdSpeed) > 0.5
	if slowing and acc * fwdSpeed < 0 and math.abs(dFwd) > math.abs(fwdSpeed) then
		dFwd = -fwdSpeed
	end
	local newV = v + fwd * dFwd
	if grounded then
		-- tyres grip: the sideways slide dies almost at once (no drifting, no ice skating)
		local keep = math.exp(-(tonumber(cfgAny.Grip) or 20) * h)
		newV -= right * lat * (1 - keep)
		-- parked (no throttle, nearly stopped): hold still, even on a slope
		local planar = Vector3.new(newV.X, 0, newV.Z).Magnitude
		if math.abs(throttle) < 0.02 and planar < (tonumber(cfgAny.HoldBelow) or 2) then
			newV = Vector3.new(0, newV.Y, 0)
		end
		-- kerbs / props / ramps never launch it: cap the climb rate to what a road's slope could give
		local climb = math.max(tonumber(cfgAny.MaxClimb) or 10, planar * 0.45)
		if newV.Y > climb then
			newV = Vector3.new(newV.X, climb, newV.Z)
		end
	elseif airborne > 0.12 then
		-- a cartoon truck, not a glider: extra gravity once it is really in the air
		newV -= Vector3.new(0, (tonumber(cfgAny.AirDownforce) or 60) * h, 0)
	end
	chassis.AssemblyLinearVelocity = newV

	-- rotation in truck axes: yaw (up), pitch (right, + = nose up), roll (look, + = right side down)
	local U, R, L = cf.UpVector, cf.RightVector, cf.LookVector
	local yaw = chassis.AssemblyAngularVelocity:Dot(U)
	local yawTarget = TruckDrive.arcadeYaw(
		steer,
		fwdSpeed,
		maxSpeed,
		tonumber(cfgAny.TurnRadiusLow) or 16,
		tonumber(cfgAny.TurnRadiusHigh) or 80,
		tonumber(cfgAny.MaxYawRate) or 1.5
	) * ctrl
	-- touch, on a call: bend toward the GPS line while the kid pushes forward (stick nearly centred)
	local assist = if touch and grounded then routeAssist(chassis.Position, fwd, rawSteer, throttle, fwdSpeed) else 0
	yawTarget += assist
	-- touch, stick let go: line up with the road you're on (gently; only when already nearly straight)
	if touch and grounded and assist == 0 and math.abs(rawSteer) < 0.05 and fwdSpeed > 8 then
		local rx, rz = roadDir(chassis.Position)
		if rx and rz then
			local ang = TruckDrive.alignAngle(fwd.X, fwd.Z, rx, rz)
			if math.abs(ang) < math.rad(tonumber(cfgAny.TouchAlignMaxDeg) or 22) then
				yawTarget -= ang * (tonumber(cfgAny.TouchAlign) or 1.2)
			end
		end
	end
	local yawGain = if grounded then tonumber(cfgAny.YawResponse) or 10 else 2
	yaw += (yawTarget - yaw) * math.min(1, h * yawGain)

	-- pitch / roll: servo the truck's up toward the ground under it (the rays' normals), or level in the
	-- air. This replaces whatever the springs / a kerb / a crash did: no bobbing, no wobble, no flips.
	local wantUp = if hits > 0 then normal.Unit else Vector3.yAxis
	if wantUp.Y < 0.5 then
		wantUp = Vector3.yAxis -- a wall is not a floor
	end
	local axis = U:Cross(wantUp) -- rotation that takes U onto wantUp (|axis| = sin(angle))
	local stiff = if grounded then tonumber(cfgAny.UprightStiffness) or 10 else tonumber(cfgAny.UprightAir) or 3
	local k = TruckDrive.servoGain(stiff, dt, 0.5)
	local pitch = TruckDrive.capRate(axis:Dot(R) * k, dt, tiltCap)
	local roll = TruckDrive.capRate(axis:Dot(L) * k, dt, tiltCap)
	chassis.AssemblyAngularVelocity = U * yaw + R * pitch + L * roll

	-- flipped anyway (a big crash)? pop back upright after a beat
	if up.Y < 0.2 then
		upsideDown += dt
		if upsideDown > VehicleConfig.SelfRightAfter then
			upsideDown = 0
			local pos = chassis.Position + Vector3.new(0, 6, 0)
			truck:PivotTo(CFrame.lookAt(pos, pos + fwd) * chassis.CFrame:ToObjectSpace(truck:GetPivot()))
			chassis.AssemblyLinearVelocity = Vector3.zero
			chassis.AssemblyAngularVelocity = Vector3.zero
		end
	else
		upsideDown = 0
	end

	if engine then
		engine.PlaybackSpeed = 0.7 + math.min(1, math.abs(fwdSpeed) / VehicleConfig.MaxSpeed) * 0.9
	end
end

---------------------------------------------------------------------------- chase camera

-- gamepad right stick looks around the truck (same yaw / pitch the mouse right-drag sets; it eases back
-- behind the truck 0.8 s after you let go)
local function padLook(dt: number)
	for _, st in UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1) do
		if st.KeyCode == Enum.KeyCode.Thumbstick2 then
			local p = st.Position
			if p.Magnitude > 0.2 then
				camYaw -= p.X * dt * 3
				camPitch = math.clamp(camPitch + p.Y * dt * 1.2, -0.25, 0.8)
				lookReleasedAt = os.clock()
			end
		end
	end
end

local function camStep(dt: number)
	local truck = driving
	local chassis = truck and truck.PrimaryPart
	local cam = workspace.CurrentCamera
	if not truck or not chassis or not cam then
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	padLook(dt)
	if not looking and os.clock() - lookReleasedAt > 0.8 then
		local k = math.min(1, dt * 2.5)
		camYaw -= camYaw * k
		camPitch -= camPitch * k
	end
	local seat = truck:FindFirstChild("DriveSeat") :: BasePart?
	if camMode == "cab" and seat then
		-- through the windshield from the driver's head; a little sway from the suspension
		local eye = seat.CFrame * CFrame.new(VehicleConfig.CabEye)
		local pitch = (tonumber((VehicleConfig :: any).CabPitch) or 0) - camPitch * 0.8
		local lookCF = eye * CFrame.Angles(0, camYaw * 0.8, 0) * CFrame.Angles(math.clamp(pitch, -0.6, 0.5), 0, 0)
		cam.CFrame = lookCF * CFrame.new(0, -camDip * 0.15, 0)
		camDip = math.max(0, camDip - dt * 5)
		local speed = chassis.AssemblyLinearVelocity.Magnitude
		local want = TruckDrive.fov(speed, VehicleConfig.MaxSpeed, VehicleConfig.CabFov, VehicleConfig.FovAdd * 0.5)
		cam.FieldOfView += (want - cam.FieldOfView) * math.min(1, dt * 4)
		camPos = nil
		return
	end
	local look = chassis.CFrame.LookVector
	local fwd = Vector3.new(look.X, 0, look.Z)
	fwd = if fwd.Magnitude > 0.05 then fwd.Unit else Vector3.new(0, 0, -1)
	local speed = chassis.AssemblyLinearVelocity.Magnitude

	-- touch: a bit further back and higher, looking further ahead (a phone screen is small and the
	-- truck filled it; kids need to see the road and the turn coming)
	local cfgAny = VehicleConfig :: any
	local touch = touchDriving()
	local camDist = if touch then tonumber(cfgAny.TouchCamDistance) or 38 else VehicleConfig.CamDistance
	local camHeight = if touch then tonumber(cfgAny.TouchCamHeight) or 18 else VehicleConfig.CamHeight
	local lookAhead = if touch then tonumber(cfgAny.TouchCamLookAhead) or 28 else VehicleConfig.CamLookAhead
	local orbit = CFrame.Angles(0, camYaw, 0)
	local back = orbit:VectorToWorldSpace(-fwd)
	local height = camHeight + camPitch * camDist - camDip
	local desired = chassis.Position + back * camDist + Vector3.new(0, height, 0)
	local target = chassis.Position + fwd * lookAhead + Vector3.new(0, 5, 0)

	local cur = camPos or desired
	cur = cur:Lerp(desired, 1 - math.exp(-VehicleConfig.CamStiffness * dt))
	camPos = cur
	camDip = math.max(0, camDip - dt * 5)

	-- don't let buildings swallow the camera: sweep a small sphere from the look target back to the
	-- camera and stop in front of the first thing it touches (a thin ray slipped past wall edges and
	-- the near plane still clipped into the bay's back wall). While obstructed the spring position is
	-- pulled in too, so the camera eases back out instead of starting inside the wall.
	local final = cur
	local dir = cur - target
	local dist = dir.Magnitude
	if dist > 0.5 then
		local unit = dir / dist
		local params = rayParams(truck)
		local radius = tonumber((VehicleConfig :: any).CamCollideRadius) or 1.5
		local hit: RaycastResult? = nil
		for _ = 1, 4 do
			local ok, res = pcall(workspace.Spherecast, workspace, target, radius, dir, params)
			hit = if ok then res else workspace:Raycast(target, dir, params)
			local inst = hit and hit.Instance
			-- see-through / walk-through things (trigger zones, glass, smoke, neon rings) don't block
			if inst and inst:IsA("BasePart") and (not inst.CanCollide or inst.Transparency > 0.6) then
				params:AddToFilter(inst)
				hit = nil
			else
				break
			end
		end
		if hit then
			local safe = math.max(2, hit.Distance - 0.4)
			final = target + unit * safe
			camPos = final
		end
	end
	cam.CFrame = CFrame.lookAt(final, target)
	local wantFov = TruckDrive.fov(speed, VehicleConfig.MaxSpeed, VehicleConfig.FovBase, VehicleConfig.FovAdd)
	cam.FieldOfView += (wantFov - cam.FieldOfView) * math.min(1, dt * 4)
end

-- Cab see-through (local only, LocalTransparencyModifier): when you look out from a cab seat in first
-- person (driver in cab view, or the shotgun passenger), hide what sits between your eyes and the
-- road: the generated cab/door/hero mesh skins (opaque shells) and the centre windshield pillar; thin
-- the glass. The cab interior (headliner, sun visors, rear-view mirror, A-pillars) stays so it reads as
-- a real cab; only what sits on top of the roof is dropped. Your own body is hidden too.
local CAB_HIDE_NAMES = { "^CabSkin$", "^DoorSkin", "^HeroSkin$", "^WindshieldPillar$" }
local CAB_THIN: { [string]: number } = { Windshield = 0.75, SideWindow_L = 0.6, SideWindow_R = 0.6 }
local cabSeeFor: Model? = nil
local cabSeeSet: { [BasePart]: number } = {}

local function cabSeeParts(truck: Model): { [BasePart]: number }
	local chassis = truck.PrimaryPart
	local out: { [BasePart]: number } = {}
	if not chassis then
		return out
	end
	local inv = chassis.CFrame:Inverse()
	for _, d in truck:GetDescendants() do
		if d:IsA("BasePart") then
			local name = d.Name
			local thin = CAB_THIN[name]
			if thin then
				out[d] = thin
			else
				local hide = false
				for _, pat in CAB_HIDE_NAMES do
					if string.match(name, pat) then
						hide = true
						break
					end
				end
				if not hide then
					-- the roof and anything on it (light bar, badge, horns), above the headliner;
					-- chassis space (chassis centre is 2 above the ground point), front is -Z
					local r = inv * d.Position
					hide = r.Z > -13.8 and r.Z < -4.6 and math.abs(r.X) < 5.8 and r.Y > 6.3
				end
				if hide then
					out[d] = 1
				end
			end
		end
	end
	return out
end

local function setCabSee(truck: Model?)
	if truck == cabSeeFor then
		return
	end
	for part in cabSeeSet do
		if part.Parent then
			part.LocalTransparencyModifier = 0
		end
	end
	cabSeeSet = {}
	cabSeeFor = truck
	if truck then
		cabSeeSet = cabSeeParts(truck)
		for part, t in cabSeeSet do
			part.LocalTransparencyModifier = t
		end
	else
		for part in hiddenParts do
			if part.Parent then
				part.LocalTransparencyModifier = 0
			end
		end
		table.clear(hiddenParts)
	end
end

-- Every frame while looking out of a cab: keep your own body hidden (the default camera scripts also
-- write LocalTransparencyModifier on the character).
local function hideBody()
	local char = player.Character
	if not char then
		return
	end
	for _, d in char:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = 1
			hiddenParts[d] = true
		end
	end
end

-- Is the local player looking out of a cab seat right now? Driver: cab view (V). Passenger: a cab
-- seat (shotgun) with the camera at the head (first person).
local function cabSeeStep()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if not seat then
		-- on foot, after the camera ran: zoomed all the way in? (enterDrive picks the cab view then)
		local cam = workspace.CurrentCamera
		local head = char and char:FindFirstChild("Head") :: BasePart?
		onFootFirstPerson = cam ~= nil and head ~= nil and cam.CameraType ~= Enum.CameraType.Scriptable
			and (cam.CFrame.Position - head.Position).Magnitude < 1.6
	end
	local truck = seat and seat.Parent
	local want: Model? = nil
	if char and seat and truck and truck:IsA("Model") and truck:HasTag(Names.Tag.Truck) then
		if seat.Name == "DriveSeat" then
			want = if driving == truck and camMode == "cab" then truck else nil
		else
			local chassis = truck.PrimaryPart
			local head = char:FindFirstChild("Head") :: BasePart?
			local cam = workspace.CurrentCamera
			local inCab = chassis ~= nil and chassis.CFrame:PointToObjectSpace(seat.Position).Z < -4
			if inCab and head and cam and (cam.CFrame.Position - head.Position).Magnitude < 2 then
				want = truck
			end
		end
	end
	setCabSee(want)
	if want then
		hideBody()
	end
end

---------------------------------------------------------------------------- input

local function respawn()
	pcall(function()
		Net.event("Vehicle", "Respawn"):FireServer()
	end)
end

-- Where you land when you get out: beside the truck on a spot that's actually free (another truck, a
-- wall or a prop is never where you end up): ReplicatedStorage/Lib/Vehicle/TruckExit.
local function exitCF(truck: Model, seat: BasePart): CFrame?
	if not truck.PrimaryPart then
		return nil
	end
	local char = player.Character
	return TruckExit.spot(truck, seat, if char then { char } else {})
end

-- Turn the default camera to look along `look` (flattened, a little down), keeping its zoom. Used on
-- getting in (look down the truck, not wherever you happened to face) and out (look the way you step).
local function aimCamera(look: Vector3, minDist: number?)
	local cam = workspace.CurrentCamera
	local flat = Vector3.new(look.X, 0, look.Z)
	if not cam or cam.CameraType == Enum.CameraType.Scriptable or flat.Magnitude < 0.05 then
		return
	end
	local focus = cam.Focus.Position
	local dist = math.max(minDist or 0.5, (cam.CFrame.Position - focus).Magnitude)
	local dir = (flat.Unit + Vector3.new(0, -0.2, 0)).Unit
	cam.CFrame = CFrame.lookAt(focus - dir * dist, focus)
end

local function hopOut()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if not hum or not seat then
		return
	end
	local truck = seat.Parent
	local target = if truck and truck:IsA("Model") then exitCF(truck, seat) else nil
	local weld = seat:FindFirstChild("SeatWeld")
	if weld then
		weld:Destroy()
	end
	hum.Sit = false -- no jump, no door: you're just standing beside the truck
	task.delay(0.05, function()
		if target and char.Parent and not hum.SeatPart then
			char:PivotTo(target)
			local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				root.AssemblyLinearVelocity = Vector3.zero
			end
			if InputHints.isTouch() then
				-- phones: the camera came back 3 studs behind the helmet with the truck right behind it (the
				-- whole screen was your head). Look along the truck instead (the camera sits in the open beside
				-- it, not inside it), at a normal third-person distance.
				aimCamera(seat.CFrame.LookVector, 12)
			else
				aimCamera(target.LookVector)
			end
		end
	end)
end

local function onAction(name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if name == "TruckHandbrake" then
		handbrake = state == Enum.UserInputState.Begin or state == Enum.UserInputState.Change
		return Enum.ContextActionResult.Sink -- Space must not jump us out of the seat
	end
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if name == "TruckHorn" then
		Net.event("Vehicle", "Horn"):FireServer()
	elseif name == "TruckSiren" then
		Net.event("Vehicle", "Siren"):FireServer()
	elseif name == "TruckRespawn" then
		respawn()
	elseif name == "TruckExit" then
		hopOut()
	elseif name == "TruckCam" then
		camMode = if camMode == "chase" then "cab" else "chase"
		cabSeeStep()
	end
	return Enum.ContextActionResult.Sink
end

local function enterDrive(truck: Model)
	driving = truck
	handbrake = false
	airborne, upsideDown = 0, 0
	throttleS, steerS = 0, 0
	camPos, camYaw, camPitch = nil, 0, 0
	local FP = controllers.FirstPersonController
	if FP and type(FP.SetEnabled) == "function" then
		pcall(FP.SetEnabled, FP, false)
	end
	local cam = workspace.CurrentCamera
	if cam then
		savedCamType = cam.CameraType
		savedFov = cam.FieldOfView
	end
	local high = Enum.ContextActionPriority.High.Value
	ContextActionService:BindActionAtPriority("TruckHorn", onAction, true, high, key("KeyHorn", Enum.KeyCode.H), Enum.KeyCode.ButtonY)
	ContextActionService:BindActionAtPriority("TruckSiren", onAction, true, high, key("KeySiren", Enum.KeyCode.G), Enum.KeyCode.ButtonX)
	ContextActionService:BindActionAtPriority("TruckExit", onAction, true, high, key("KeyExit", Enum.KeyCode.Space), Enum.KeyCode.ButtonA, Enum.KeyCode.ButtonB)
	ContextActionService:BindActionAtPriority("TruckCam", onAction, false, high, key("KeyCam", Enum.KeyCode.V), Enum.KeyCode.ButtonR3)
	ContextActionService:SetTitle("TruckHorn", "HONK")
	ContextActionService:SetTitle("TruckSiren", "SIREN")
	ContextActionService:SetTitle("TruckExit", "OUT")
	-- touch: one cluster on the right round the jump spot (ClientLib/ThumbLayout); the stick is the
	-- left half. Roblox's own jump button also throws you out of a seat, and the big button next to it
	-- is where a kid's thumb rests: so while driving the jump button is hidden (Jumping state off), OUT
	-- takes its place at its size, and the big button is the harmless HONK.
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum and touchDriving() and hum:GetStateEnabled(Enum.HumanoidStateType.Jumping) then
		hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		jumpHiddenOn = hum
	end
	ThumbLayout.place("TruckExit", "jump", onAction)
	ThumbLayout.place("TruckHorn", "primary", onAction)
	ThumbLayout.place("TruckSiren", "left", onAction)
	-- first-person players (zoomed all the way in) start in the cab view, everyone else in the chase cam
	-- (touch: always the chase cam: a phone screen through the windshield shows dashboard, not road)
	camMode = if not touchDriving() and (VehicleConfig.DefaultCam == "cab" or onFootFirstPerson) then "cab" else "chase"
	RunService:BindToRenderStep("TruckCam", Enum.RenderPriority.Camera.Value + 10, camStep)
	local chassis = truck.PrimaryPart
	if chassis and VehicleConfig.EngineSoundId ~= "" then
		local s = Instance.new("Sound")
		s.Name = "LocalEngine"
		s.SoundId = VehicleConfig.EngineSoundId
		s.Looped = true
		s.Volume = 0.5
		s.Parent = chassis
		s:Play()
		engine = s
	end
end

local function exitDrive()
	driving = nil
	if jumpHiddenOn then
		if jumpHiddenOn.Parent then
			jumpHiddenOn:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		end
		jumpHiddenOn = nil
	end
	handbrake = false
	-- a right-drag look in progress (or the mission ending mid-drag) must not leave the mouse held
	if looking then
		looking = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
	UserInputService.MouseIconEnabled = true
	for _, a in { "TruckHorn", "TruckSiren", "TruckExit", "TruckCam" } do
		ThumbLayout.forget(a)
		ContextActionService:UnbindAction(a)
	end
	setCabSee(nil)
	pcall(function()
		RunService:UnbindFromRenderStep("TruckCam")
	end)
	if engine then
		engine:Destroy()
		engine = nil
	end
	local cam = workspace.CurrentCamera
	if cam then
		cam.CameraType = if savedCamType and savedCamType ~= Enum.CameraType.Scriptable then savedCamType else Enum.CameraType.Custom
		cam.FieldOfView = savedFov
	end
	local FP = controllers.FirstPersonController
	if FP and type(FP.SetEnabled) == "function" then
		pcall(FP.SetEnabled, FP, true)
	end
end

local function onLookInput(input: InputObject, processed: boolean)
	if not driving then
		if looking and input.UserInputType == Enum.UserInputType.MouseButton2 and input.UserInputState == Enum.UserInputState.End then
			looking = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		if input.UserInputState == Enum.UserInputState.Begin and not processed then
			looking = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		elseif input.UserInputState == Enum.UserInputState.End then
			looking = false
			lookReleasedAt = os.clock()
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	elseif input.UserInputType == Enum.UserInputType.MouseMovement and looking then
		camYaw -= input.Delta.X * 0.006
		camPitch = math.clamp(camPitch + input.Delta.Y * 0.004, -0.25, 0.8)
	end
	-- gamepad right stick: read every frame in camStep (padLook), not per InputChanged event: a stick held
	-- still fires no events, so the old per-event turn stopped while you held it over
end

---------------------------------------------------------------------------- respawn button

local function makeRespawnButton()
	local pg = player:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "TruckHud"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	local b = Instance.new("TextButton")
	b.Name = "Respawn"
	b.AnchorPoint = Vector2.new(0, 1)
	b.Position = UDim2.new(0, 16, 1, -150)
	b.Size = UDim2.fromOffset(190, 46)
	b.BackgroundColor3 = Color3.fromRGB(200, 35, 43)
	b.TextColor3 = Color3.fromRGB(255, 244, 196)
	b.Font = Enum.Font.LuckiestGuy
	b.TextScaled = true
	InputHints.setChip(b, VehicleConfig.KeyRespawn, "RESPAWN TRUCK")
	b.Visible = false
	b.AutoButtonColor = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(26, 18, 16)
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = b
	b.Activated:Connect(respawn)
	b.Parent = gui
	local hint = Instance.new("TextLabel")
	hint.Name = "Hints"
	hint.AnchorPoint = Vector2.new(0.5, 1)
	hint.Position = UDim2.new(0.5, 0, 1, -18)
	hint.Size = UDim2.fromOffset(640, 34)
	hint.BackgroundColor3 = Color3.fromRGB(26, 18, 16)
	hint.BackgroundTransparency = 0.25
	hint.TextColor3 = Color3.fromRGB(255, 244, 196)
	hint.Font = Enum.Font.GothamBold
	hint.TextScaled = true
	hint.TextWrapped = true
	hint.Visible = false
	local maxText = Instance.new("UITextSizeConstraint")
	maxText.MaxTextSize = 22
	maxText.Parent = hint
	-- Fit between the screen's left edge and HudController's bottom-right heat gauge
	-- (kept at the old ~170 px reserve, symmetric); wrap to two lines on narrow / phone screens instead of running under them.
	local function layoutHints()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local vp = cam.ViewportSize
		local s = math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.55, 1.4)
		local reserve = 172 * s + 10
		local w = math.max(200, math.min(math.floor(640 * math.max(s, 0.8)), math.floor(vp.X - 2 * reserve)))
		local h = if w < 460 then math.floor(48 * math.max(s, 0.8)) else math.floor(34 * math.max(s, 0.8))
		if InputHints.isTouch() then
			-- phones: one short line ABOVE the thumbstick zone (bottom-left 40% x 45%) and left of the thumb
			-- buttons (at the bottom it sat on the stick and ran under SIREN)
			w = math.max(140, math.min(math.floor(vp.X * 0.4) - 10, math.floor(ThumbLayout.clusterLeft() - 20)))
			h = math.floor(30 * math.max(s, 0.8))
			hint.AnchorPoint = Vector2.new(0, 1)
			hint.Position = UDim2.new(0, 10, 0.55, -6)
		else
			hint.AnchorPoint = Vector2.new(0.5, 1)
			hint.Position = UDim2.new(0.5, 0, 1, -18)
		end
		hint.Size = UDim2.fromOffset(w, h)
		-- the RESPAWN button scales like the UiKit HUD: unscaled it ran into the PASS / STORE chips on phones
		b.Position = UDim2.new(0, math.floor(16 * s), 1, -math.floor(150 * s))
		b.Size = UDim2.fromOffset(math.floor(190 * s), math.floor(46 * s))
	end
	layoutHints()
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(layoutHints)
	end
	InputHints.onChanged(function()
		task.defer(layoutHints)
	end)
	task.delay(1, layoutHints) -- the jump button (ThumbLayout's anchor) exists by now
	local hc = Instance.new("UICorner")
	hc.CornerRadius = UDim.new(0, 10)
	hc.Parent = hint
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = hint
	hint.Parent = gui
	hintLabel = hint
	gui.Parent = pg
	local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript) :: any
	HudLayout.reserve(hint) -- world markers / edge arrows stay off the driving hints
	HudLayout.reserve(b)
	respawnButton = b
end

local respawnBound = false
local function respawnLoop()
	while true do
		task.wait(0.5)
		local show = false
		local truck = myTruck()
		local chassis = truck and truck.PrimaryPart
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		-- the RESPAWN TRUCK button only lives at the station (near the bays); out in the city R still
		-- unflips the truck you're driving, without a button in the way
		local atStation = false
		if root then
			for _, bay in CollectionService:GetTagged("TruckBay") do
				if bay:IsA("BasePart") and (bay.Position - root.Position).Magnitude < STATION_RADIUS then
					atStation = true
					break
				end
			end
		end
		if atStation and chassis and root and not driving then
			local flipped = chassis.CFrame.UpVector.Y < 0.3
			local far = (chassis.Position - root.Position).Magnitude > 250
			show = flipped or far
		end
		if respawnButton then
			respawnButton.Visible = show
		end
		local bind = show or driving
		if bind ~= respawnBound then
			respawnBound = bind
			if bind then
				ContextActionService:BindAction("TruckRespawn", onAction, false, key("KeyRespawn", Enum.KeyCode.R), Enum.KeyCode.DPadRight)
			else
				ContextActionService:UnbindAction("TruckRespawn")
			end
		end
	end
end

---------------------------------------------------------------------------- everyone: lights, siren, honk

local function honkPop(truck: Model?)
	local root = if typeof(truck) == "Instance" and truck:IsA("Model") then truck.PrimaryPart else nil
	if root then
		pop(root, if math.random() < 0.15 then "HONK HONK!" else "HONK!", Color3.fromRGB(255, 228, 92), Vector3.new(0, 11, -10))
	end
end

local function glow(part: BasePart, color: Color3): PointLight
	local l = part:FindFirstChild("FlashLight") :: PointLight?
	if l then
		return l
	end
	local made = Instance.new("PointLight")
	made.Name = "FlashLight"
	made.Color = color
	made.Range = 18
	made.Brightness = 4
	made.Parent = part
	return made
end

local function lightBar(truck: Model, flashing: boolean, phase: boolean)
	local r = truck:FindFirstChild("LightRed")
	local b = truck:FindFirstChild("LightBlue")
	local w = truck:FindFirstChild("LightWhite")
	if r and r:IsA("BasePart") then
		r.Transparency = if flashing and not phase then 0.7 else (if flashing then 0 else 0.5)
		glow(r, Color3.fromRGB(255, 45, 45)).Enabled = flashing and phase
	end
	if b and b:IsA("BasePart") then
		b.Transparency = if flashing and phase then 0.7 else (if flashing then 0 else 0.5)
		glow(b, Color3.fromRGB(45, 120, 255)).Enabled = flashing and not phase
	end
	if w and w:IsA("BasePart") then
		w.Transparency = if flashing then (if math.random() < 0.5 then 0 else 0.6) else 0.5
	end
end

local function lightBarLoop()
	local phase = false
	while true do
		task.wait(0.16)
		phase = not phase
		for _, truck in CollectionService:GetTagged(Names.Tag.Truck) do
			if truck:IsA("Model") and truck:IsDescendantOf(workspace) then
				local on = truck:GetAttribute("SirenOn") == true
				-- v1 fallback trucks inside a mission instance also flash while that round is hot
				if not on and truck:GetAttribute("OwnerUserId") == nil then
					local inst = truck:FindFirstAncestorWhichIsA("Model")
					local st = inst and inst:GetAttribute(Names.Attr.RoundState)
					on = st == "Alarm" or st == "Active"
				end
				lightBar(truck, on, phase)
			end
		end
	end
end

-- Wailing siren: pitch rides a slow sine and climbs with the truck's speed (local only).
local function sirenStep()
	local t = os.clock()
	for _, truck in CollectionService:GetTagged(Names.Tag.Truck) do
		if truck:IsA("Model") and truck:GetAttribute("SirenOn") == true then
			local chassis = truck.PrimaryPart
			local snd = truck:FindFirstChild("SirenSound", true)
			if chassis and snd and snd:IsA("Sound") then
				local speed = chassis.AssemblyLinearVelocity.Magnitude
				snd.PlaybackSpeed = TruckDrive.sirenPitch(
					speed,
					VehicleConfig.MaxSpeed,
					t,
					VehicleConfig.SirenWailHz,
					VehicleConfig.SirenPitchBase,
					VehicleConfig.SirenPitchSpeed,
					VehicleConfig.SirenPitchWail
				)
			end
		end
	end
end

local POP_COLORS: { [string]: Color3 } = {
	slam = Color3.fromRGB(255, 120, 60),
	bonk = Color3.fromRGB(255, 228, 92),
}

local function onPop(part: Instance?, text: string?, kind: string?)
	if typeof(part) == "Instance" and part:IsA("BasePart") and type(text) == "string" then
		pop(part, text, POP_COLORS[kind or ""] or Color3.fromRGB(255, 255, 255), Vector3.new(0, 4, 0))
	end
end

-- Steering wheels follow SteerFloat; bobbleheads wobble from the truck's sway. Nearby trucks only.
local wheelAngle: { [Model]: number } = {}
local bobble: { [Model]: { x: number, z: number, vx: number, vz: number, last: Vector3? } } = {}
type WheelRig = { motor: Motor6D, front: boolean, radius: number, angle: number }
type WheelState = { wheels: { WheelRig }, steer: number, retryAt: number }
local roadWheels: { [Model]: WheelState } = {}
local function wheelsOf(m: Model): WheelState?
	local st = roadWheels[m]
	if st then
		if #st.wheels > 0 and st.wheels[1].motor.Parent then
			return st
		elseif os.clock() < st.retryAt then
			return nil
		end
	end
	local list: { WheelRig } = {}
	for _, c in m:GetChildren() do
		if c:IsA("BasePart") and string.sub(c.Name, 1, 11) == "WheelPivot_" then
			local motor = c:FindFirstChild("WheelMotor")
			local key = string.sub(c.Name, 12)
			local tyre = m:FindFirstChild(`Wheel_{key}`)
			if motor and motor:IsA("Motor6D") then
				local r = if tyre and tyre:IsA("BasePart") then tyre.Size.Y / 2 else 1.8
				table.insert(list, { motor = motor, front = string.sub(key, 1, 6) == "Front_", radius = math.max(r, 0.5), angle = 0 })
			end
		end
	end
	-- none = not rigged (static truck) or not streamed in yet: look again in a second
	st = { wheels = list, steer = if st then st.steer else 0, retryAt = os.clock() + 1 }
	roadWheels[m] = st
	return if #list > 0 then st else nil
end

-- Front wheels yaw with the stick (SteerFloat +1 = right = negative yaw, the truck faces -Z); every
-- wheel rolls about its axle (X) by speed / radius, negative angle = top rolling forward.
local function animateWheels(m: Model, chassis: BasePart, seat: VehicleSeat?, dt: number)
	local st = wheelsOf(m)
	if not st then
		return
	end
	local fwd = chassis.CFrame.LookVector:Dot(chassis.AssemblyLinearVelocity)
	local maxSteer = math.rad(tonumber(VehicleConfig.WheelSteerAngle) or 30)
	local want = if seat then -seat.SteerFloat * maxSteer else 0
	st.steer += (want - st.steer) * math.min(1, dt * (tonumber(VehicleConfig.WheelSteerRate) or 10))
	for _, w in st.wheels do
		w.angle = (w.angle - fwd * dt / w.radius) % (2 * math.pi)
		local roll = CFrame.Angles(w.angle, 0, 0)
		w.motor.Transform = if w.front then CFrame.Angles(0, st.steer, 0) * roll else roll
	end
end

local function animateCabs(dt: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local camPosNow = cam.CFrame.Position
	local wheelRange = tonumber(VehicleConfig.WheelAnimRange) or 250
	for _, truck in CollectionService:GetTagged(Names.Tag.Truck) do
		local chassis = truck:IsA("Model") and truck.PrimaryPart
		if not chassis then
			continue
		end
		local dist = (chassis.Position - camPosNow).Magnitude
		if dist > wheelRange then
			continue
		end
		local m = truck :: Model
		local seat = m:FindFirstChild("DriveSeat") :: VehicleSeat?
		animateWheels(m, chassis, seat, dt)
		if dist > 90 then
			continue
		end
		local wheel = m:FindFirstChild("SteeringWheel")
		local column = wheel and wheel:FindFirstChild("SteeringColumn")
		local motor = column and column:FindFirstChild("SteeringMotor") :: Motor6D?
		if seat and motor then
			local want = -seat.SteerFloat * 2.4
			local a = wheelAngle[m] or 0
			a += (want - a) * math.min(1, dt * 8)
			wheelAngle[m] = a
			motor.Transform = CFrame.Angles(0, 0, a)
		end
		local body = m:FindFirstChild("BobbleBody")
		local bm = body and body:FindFirstChild("BobbleMotor") :: Motor6D?
		if bm then
			local st = bobble[m] or { x = 0, z = 0, vx = 0, vz = 0, last = nil }
			bobble[m] = st
			local v = chassis.AssemblyLinearVelocity
			local last = st.last or v
			st.last = v
			local acc = chassis.CFrame:VectorToObjectSpace(v - last) / math.max(dt, 1e-3)
			-- spring-damper head: kicked by acceleration, wobbles back
			st.vx += (-st.x * 120 - st.vx * 3 - acc.Z * 0.02) * dt
			st.vz += (-st.z * 120 - st.vz * 3 + acc.X * 0.02) * dt
			st.x = math.clamp(st.x + st.vx * dt, -0.9, 0.9)
			st.z = math.clamp(st.z + st.vz * dt, -0.9, 0.9)
			bm.Transform = CFrame.Angles(st.x, 0, st.z)
		end
	end
	for m in wheelAngle do
		if not m.Parent then
			wheelAngle[m] = nil
			bobble[m] = nil
		end
	end
	for m in roadWheels do
		if not m.Parent then
			roadWheels[m] = nil
		end
	end
end

-- Seated anywhere in a truck: hide every prompt (no "press F to sit" while sitting), show key hints,
-- and let passengers hop off with the exit key.
local function seatedTruck(): (Model?, BasePart?)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	local m = seat and seat.Parent
	if seat and m and m:IsA("Model") and m:HasTag(Names.Tag.Truck) then
		return m, seat
	end
	return nil, nil
end

local seatedIn: BasePart? = nil -- truck seat the local player sat in last frame
local riderJumpOff: Humanoid? = nil -- a rider's humanoid whose jump we turned off (touch), until they're out

-- Getting in: the camera looks down the truck (seat forward), not the way you faced on foot. In first
-- person the default camera keeps its world yaw, so a passenger who boarded facing backwards rode along
-- staring out the back. (The driver's chase / cab cams follow the truck anyway.)
local function onSeatChanged(seat: BasePart?)
	if seat then
		aimCamera(seat.CFrame.LookVector)
	end
end

local hintTruck: Model? = nil
local hintSince = 0
local HINT_CALM_SECONDS = 5

local function updateSeated()
	local truck, seat = seatedTruck()
	local isDriver = seat ~= nil and seat.Name == "DriveSeat"
	if seat ~= seatedIn then
		seatedIn = seat
		onSeatChanged(seat)
	end
	if ProximityPromptService.Enabled ~= (truck == nil) then
		ProximityPromptService.Enabled = truck == nil
	end
	local passenger = if truck and not isDriver then truck else nil
	if passenger ~= riding then
		if riding and driving then
			-- moved from a crew seat to the wheel (TAKE THE WHEEL): enterDrive already bound the driver's
			-- OUT under the same name, so unbinding here used to leave the new driver with no way out
			if riderJumpOff and not jumpHiddenOn then
				jumpHiddenOn = riderJumpOff -- the jump stays off while driving; exitDrive turns it back on
			end
			riderJumpOff = nil
		elseif riding then
			ThumbLayout.forget("TruckExit")
			ContextActionService:UnbindAction("TruckExit")
			if riderJumpOff then
				if riderJumpOff.Parent then
					riderJumpOff:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
				end
				riderJumpOff = nil
			end
		end
		riding = passenger
		if passenger then
			ContextActionService:BindActionAtPriority(
				"TruckExit",
				onAction,
				true,
				Enum.ContextActionPriority.High.Value,
				key("KeyExit", Enum.KeyCode.Space),
				Enum.KeyCode.ButtonA,
				Enum.KeyCode.ButtonB
			)
			ContextActionService:SetTitle("TruckExit", "OUT")
			-- the big primary spot is the rider's SPRAY (water cannon, DriveController); HONK / SIREN beside it.
			-- Touch: the same big OUT as the driver's, on the jump button's spot (Roblox's jump hides: it
			-- also threw riders out, so two buttons did one thing and the small OFF was easy to miss).
			-- Jumping comes back the moment you're out of the seat, however you got out.
			local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if hum and touchDriving() and hum:GetStateEnabled(Enum.HumanoidStateType.Jumping) then
				hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
				riderJumpOff = hum
			end
			ThumbLayout.place("TruckExit", if touchDriving() then "jump" else "above", onAction)
		end
	end
	if truck ~= hintTruck then
		hintTruck = truck
		hintSince = os.clock()
	end
	local hint = hintLabel
	if hint then
		-- calm (phones): the on-screen buttons name themselves; the key bar shows for a few seconds, then goes
		-- touch: always just the first few seconds (the buttons name themselves; the stick zone stays clear)
		hint.Visible = truck ~= nil and not ((Calm.on() or touchDriving()) and os.clock() - hintSince > HINT_CALM_SECONDS)
		if isDriver then
			-- touch: the buttons are the ContextAction titles bound above (OUT, SIREN, HONK, DRIFT)
			hint.Text = InputHints.pick(
				`SPACE: hop out   {VehicleConfig.KeySiren}: siren   {VehicleConfig.KeyHorn}: horn   {VehicleConfig.KeyCam}: camera   {VehicleConfig.KeyRespawn}: unflip`,
				"Push the stick to drive!",
				"R2 gas  L2 brake  stick steer   A: out   X: siren   Y: horn   R3: camera   D-PAD RIGHT: unflip"
			)
		elseif truck then
			hint.Text = InputHints.pick(
				`CLICK: water cannon   {VehicleConfig.KeyHorn}: honk   {VehicleConfig.KeySiren}: siren   SPACE: hop off`,
				-- no SPRAY button while practice fires are off (DriveConfig.Targets): don't name one
				if DriveConfig.Targets then "SPRAY the fires!   ·   HONK  SIREN  OUT" else "HONK  SIREN  OUT",
				"R2: water cannon   Y: honk   X: siren   A: hop off"
			)
		end
	end
end

---------------------------------------------------------------------------- lifecycle

function VehicleController:Init(all: { [string]: any })
	controllers = all
end

function VehicleController:Start()
	task.spawn(lightBarLoop)
	task.spawn(function()
		local ok, Honked = pcall(Net.event, "Vehicle", "Honked")
		if ok then
			(Honked :: RemoteEvent).OnClientEvent:Connect(honkPop)
		end
	end)
	task.spawn(function()
		local ok, Pop = pcall(Net.event, "Vehicle", "Pop")
		if ok then
			(Pop :: RemoteEvent).OnClientEvent:Connect(onPop)
		end
	end)
	RunService.RenderStepped:Connect(animateCabs)
	RunService:BindToRenderStep("TruckCabSee", Enum.RenderPriority.Camera.Value + 20, cabSeeStep)
	task.spawn(function()
		pcall(makeRespawnButton)
		respawnLoop()
	end)
	UserInputService.InputBegan:Connect(onLookInput)
	UserInputService.InputChanged:Connect(onLookInput)
	UserInputService.InputEnded:Connect(onLookInput)
	RunService.Heartbeat:Connect(sirenStep)
	RunService.PreSimulation:Connect(function(dt: number)
		local truck = drivenTruck()
		if truck then
			if driving ~= truck then
				if driving then
					exitDrive()
				end
				enterDrive(truck)
			end
			step(truck, dt)
		elseif driving then
			exitDrive()
		end
		updateSeated()
	end)
end

return VehicleController
