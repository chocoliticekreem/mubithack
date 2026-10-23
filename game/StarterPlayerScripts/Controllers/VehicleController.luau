--!strict
-- VehicleController [owner: Vehicle agent]. Fire trucks on the client (docs/game/08 "Vehicles").
--   * Driving: when the local player sits in a truck's "DriveSeat" (the server hands them network
--     ownership) this runs the goofy driving every physics step (ClientLib/TruckDrive maths,
--     VehicleConfig numbers): jelly raycast suspension, body roll, wheelies on launch and bumps,
--     handbrake drift, cartoon squash + "BOING!" on hard landings, self-righting.
--   * Camera while driving: chase cam (spring follow, right-drag to look around, FOV by speed) or the
--     cab view through the windshield (V toggles; head/hats hidden so nothing clips). FirstPersonController
--     is paused and comes back on exit.
--   * Keys (VehicleConfig.Key*): WASD drive, SPACE handbrake/drift, F hop out, G siren, H horn, V camera,
--     R unflip/respawn. Passengers: F hops off. While seated, every ProximityPrompt is hidden and a hint
--     bar shows the keys instead. Getting out puts you outside the door (the server pops it open).
--     A "RESPAWN TRUCK" button (and R) also shows on foot when your truck is flipped or far away.
--   * Steering wheels turn with each truck's DriveSeat.SteerFloat and the dash bobblehead wobbles
--     (Motor6D "SteeringMotor" / "BobbleMotor", nearby trucks only).
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

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local VehicleConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("VehicleConfig") :: ModuleScript)
local TruckDrive = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("TruckDrive") :: ModuleScript)

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
local lastVelY = 0
local prevThrottle = 0
local prevFrontComp = 0
local squashT = math.huge
local squashSoft = 1
local engine: Sound? = nil
local boing: Sound? = nil

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
local hintLabel: TextLabel? = nil
local camMode = "chase" -- "chase" | "cab"
local riding: Model? = nil -- truck the local player sits in as a passenger
local hiddenParts: { [BasePart]: boolean } = {}

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

local function myTruck(): Model?
	local f = workspace:FindFirstChild("Trucks")
	local m = f and f:FindFirstChild(`FireTruck_{player.UserId}`)
	return if m and m:IsA("Model") then m else nil
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
	local gui = Instance.new("BillboardGui")
	gui.Name = "TruckPop"
	gui.Size = UDim2.fromOffset(170, 64)
	gui.StudsOffsetWorldSpace = offset
	gui.AlwaysOnTop = true
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Font = Enum.Font.LuckiestGuy
	t.TextScaled = true
	t.Text = text
	t.TextColor3 = color
	t.TextStrokeTransparency = 0
	t.Rotation = math.random(-12, 12)
	t.Parent = gui
	gui.Parent = root
	TweenService:Create(gui, TweenInfo.new(0.7), { StudsOffsetWorldSpace = offset + Vector3.new(0, 4, 0) }):Play()
	TweenService:Create(t, TweenInfo.new(0.7), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	task.delay(0.75, function()
		gui:Destroy()
	end)
end

---------------------------------------------------------------------------- driving physics

local function step(truck: Model, dt: number)
	local seat = truck:FindFirstChild("DriveSeat") :: VehicleSeat?
	local chassis = truck.PrimaryPart
	if not seat or not chassis or chassis.Anchored then
		return
	end
	local cf = chassis.CFrame
	local up = cf.UpVector
	local mass = chassis.AssemblyMass
	local params = rayParams(truck)
	local rest = VehicleConfig.RideRest

	-- landing squash: the springs go soft for a beat, so the body slams down and rebounds
	squashT += dt
	local springK = VehicleConfig.Spring * TruckDrive.squashSpring(squashT, VehicleConfig.SquashSeconds, squashSoft)

	local hits = 0
	local frontComp = 0
	for i, c in CORNERS do
		local origin = cf:PointToWorldSpace(c)
		local res = workspace:Raycast(origin, -up * rest, params)
		local dist = if res then res.Distance else nil
		if dist then
			hits += 1
			if i <= 2 then
				frontComp += (rest - dist) * 0.5
			end
		end
		local vel = chassis:GetVelocityAtPosition(origin):Dot(up)
		local a = TruckDrive.spring(dist, rest, vel, springK, VehicleConfig.Damping)
		if a > 0 then
			chassis:ApplyImpulseAtPosition(up * a * mass * 0.25 * dt, origin)
		end
	end
	local grounded = hits >= 2
	local ctrl = if grounded then 1 else VehicleConfig.AirControl

	local v = chassis.AssemblyLinearVelocity
	-- hard landing -> cartoon squash + BOING
	if grounded and airborne > 0 then
		local amt = TruckDrive.squash(airborne, -lastVelY)
		if amt > 0 then
			squashT = 0
			squashSoft = 1 - (1 - VehicleConfig.SquashSoften) * amt
			camDip = math.max(camDip, 1.5 * amt)
			if boing and boing.SoundId ~= "" then
				boing.PlaybackSpeed = 0.8 + math.random() * 0.4
				boing:Play()
			end
			pop(chassis, if amt > 0.7 then "BOI-OI-OING!" else "BOING!", Color3.fromRGB(120, 230, 255), Vector3.new(0, 9, 0))
		end
	end
	airborne = if grounded then 0 else airborne + dt
	lastVelY = v.Y

	local look = cf.LookVector
	local fwd = Vector3.new(look.X, 0, look.Z)
	fwd = if fwd.Magnitude > 0.05 then fwd.Unit else Vector3.new(0, 0, -1)
	local right = Vector3.new(-fwd.Z, 0, fwd.X)
	local fwdSpeed = v:Dot(fwd)
	local lat = v:Dot(right)
	local throttle = seat.ThrottleFloat
	local steer = seat.SteerFloat

	-- drive + grip (handbrake = drift)
	local acc = TruckDrive.drive(throttle, fwdSpeed, VehicleConfig.MaxSpeed, VehicleConfig.Accel, VehicleConfig.Brake)
	local dv = fwd * acc * dt * ctrl
	if grounded then
		local grip = if handbrake then VehicleConfig.DriftGrip else VehicleConfig.Grip
		dv += right * TruckDrive.grip(lat, grip) * dt
		if handbrake and math.abs(fwdSpeed) > 1 then
			dv -= fwd * math.sign(fwdSpeed) * math.min(math.abs(fwdSpeed), VehicleConfig.HandbrakeDrag * dt)
		end
	end
	chassis.AssemblyLinearVelocity = v + dv

	-- rotation in truck axes: yaw (up), pitch (right, + = nose up), roll (look, + = right side down)
	local U, R, L = cf.UpVector, cf.RightVector, cf.LookVector
	local av = chassis.AssemblyAngularVelocity
	local yaw, pitch, roll = av:Dot(U), av:Dot(R), av:Dot(L)

	local yawTarget = TruckDrive.steerRate(steer, fwdSpeed, VehicleConfig.TurnSpeed, VehicleConfig.MaxSpeed) * ctrl
	if handbrake and grounded then
		yawTarget *= VehicleConfig.DriftTurn
	end
	yaw += (yawTarget - yaw) * math.min(1, dt * 6)

	if grounded then
		-- body roll: lean out of the turn
		local rollNow = -R.Y
		local want = TruckDrive.rollTarget(steer, fwdSpeed, VehicleConfig.MaxSpeed, VehicleConfig.BodyRoll)
		local rollRate = (want - rollNow) * VehicleConfig.RollStiffness
		roll += (rollRate - roll) * math.min(1, dt * 8)
		-- wheelies: flooring it from a stop, and slamming the front wheels into a bump
		pitch += TruckDrive.wheelie(throttle, prevThrottle, fwdSpeed, VehicleConfig.MaxSpeed, VehicleConfig.WheelieKick)
		local compRate = (frontComp - prevFrontComp) / math.max(dt, 1e-3)
		pitch += TruckDrive.bump(compRate, VehicleConfig.BumpThreshold, VehicleConfig.BumpKick) * math.min(1, math.abs(fwdSpeed) / 20)
		pitch *= math.max(0, 1 - dt * 1.2)
	end
	prevThrottle = throttle
	prevFrontComp = frontComp
	chassis.AssemblyAngularVelocity = U * yaw + R * pitch + L * roll

	-- flipped? pop back upright after a beat (goofy, keeps the round going)
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

local function camStep(dt: number)
	local truck = driving
	local chassis = truck and truck.PrimaryPart
	local cam = workspace.CurrentCamera
	if not truck or not chassis or not cam then
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	if not looking and os.clock() - lookReleasedAt > 0.8 then
		local k = math.min(1, dt * 2.5)
		camYaw -= camYaw * k
		camPitch -= camPitch * k
	end
	local seat = truck:FindFirstChild("DriveSeat") :: BasePart?
	if camMode == "cab" and seat then
		-- through the windshield from the driver's head; a little sway from the suspension
		local eye = seat.CFrame * CFrame.new(VehicleConfig.CabEye)
		local lookCF = eye * CFrame.Angles(0, camYaw * 0.8, 0) * CFrame.Angles(math.clamp(-camPitch * 0.8, -0.6, 0.5), 0, 0)
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

	local orbit = CFrame.Angles(0, camYaw, 0)
	local back = orbit:VectorToWorldSpace(-fwd)
	local height = VehicleConfig.CamHeight + camPitch * VehicleConfig.CamDistance - camDip
	local desired = chassis.Position + back * VehicleConfig.CamDistance + Vector3.new(0, height, 0)
	local target = chassis.Position + fwd * VehicleConfig.CamLookAhead + Vector3.new(0, 3, 0)

	local cur = camPos or desired
	cur = cur:Lerp(desired, 1 - math.exp(-VehicleConfig.CamStiffness * dt))
	camPos = cur
	camDip = math.max(0, camDip - dt * 5)

	-- don't let buildings swallow the camera
	local dir = cur - target
	local hit = workspace:Raycast(target, dir, rayParams(truck))
	local final = if hit then hit.Position + hit.Normal * 1.2 else cur
	cam.CFrame = CFrame.lookAt(final, target)
	local wantFov = TruckDrive.fov(speed, VehicleConfig.MaxSpeed, VehicleConfig.FovBase, VehicleConfig.FovAdd)
	cam.FieldOfView += (wantFov - cam.FieldOfView) * math.min(1, dt * 4)
end

-- Cab view: hide your own head + hats so the camera never looks out through your face.
local function hideHead(on: boolean)
	local char = player.Character
	if on and char then
		for _, d in char:GetDescendants() do
			if d:IsA("BasePart") and (d.Name == "Head" or d:FindFirstAncestorOfClass("Accessory")) then
				d.LocalTransparencyModifier = 1
				hiddenParts[d] = true
			end
		end
	elseif not on then
		for part in hiddenParts do
			if part.Parent then
				part.LocalTransparencyModifier = 0
			end
		end
		table.clear(hiddenParts)
	end
end

---------------------------------------------------------------------------- input

local function respawn()
	pcall(function()
		Net.event("Vehicle", "Respawn"):FireServer()
	end)
end

-- Where you land when you get out: cab seats -> outside that side's door; benches -> behind the tailgate.
local function exitCF(truck: Model, seat: BasePart): CFrame?
	local chassis = truck.PrimaryPart
	if not chassis then
		return nil
	end
	local c = chassis.CFrame
	local rel = c:PointToObjectSpace(seat.Position)
	local side = if rel.X < 0 then -1 else 1
	if rel.Z < -4 then
		local pos = c * Vector3.new(side * 7.6, 1.5, -4.2)
		return CFrame.lookAt(pos, pos + c.RightVector * side)
	end
	local pos = c * Vector3.new(side * 3, 1.5, 16.5)
	return CFrame.lookAt(pos, pos - c.LookVector)
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
	hum.Sit = false
	hum.Jump = true
	task.delay(0.05, function()
		if target and char.Parent and not hum.SeatPart then
			char:PivotTo(target)
			local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				root.AssemblyLinearVelocity = Vector3.zero
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
		hideHead(camMode == "cab")
	end
	return Enum.ContextActionResult.Sink
end

local function enterDrive(truck: Model)
	driving = truck
	handbrake = false
	airborne, upsideDown, prevThrottle, prevFrontComp = 0, 0, 0, 0
	squashT = math.huge
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
	ContextActionService:BindActionAtPriority("TruckHandbrake", onAction, true, high, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)
	ContextActionService:BindActionAtPriority("TruckHorn", onAction, true, high, key("KeyHorn", Enum.KeyCode.H), Enum.KeyCode.ButtonY)
	ContextActionService:BindActionAtPriority("TruckSiren", onAction, true, high, key("KeySiren", Enum.KeyCode.G), Enum.KeyCode.ButtonX)
	ContextActionService:BindActionAtPriority("TruckExit", onAction, true, high, key("KeyExit", Enum.KeyCode.F), Enum.KeyCode.ButtonB)
	ContextActionService:BindActionAtPriority("TruckCam", onAction, false, high, key("KeyCam", Enum.KeyCode.V), Enum.KeyCode.ButtonR3)
	ContextActionService:SetTitle("TruckHandbrake", "DRIFT")
	ContextActionService:SetTitle("TruckHorn", "HONK")
	ContextActionService:SetTitle("TruckSiren", "SIREN")
	ContextActionService:SetTitle("TruckExit", "OUT")
	camMode = if VehicleConfig.DefaultCam == "cab" then "cab" else "chase"
	hideHead(camMode == "cab")
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
	if chassis then
		local b = Instance.new("Sound")
		b.Name = "LocalBoing"
		b.SoundId = VehicleConfig.BoingSoundId
		b.Volume = 0.8
		b.Parent = chassis
		boing = b
	end
end

local function exitDrive()
	driving = nil
	handbrake = false
	for _, a in { "TruckHandbrake", "TruckHorn", "TruckSiren", "TruckExit", "TruckCam" } do
		ContextActionService:UnbindAction(a)
	end
	hideHead(false)
	pcall(function()
		RunService:UnbindFromRenderStep("TruckCam")
	end)
	if engine then
		engine:Destroy()
		engine = nil
	end
	if boing then
		boing:Destroy()
		boing = nil
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
	elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
		local p = input.Position
		if p.Magnitude > 0.2 then
			camYaw -= p.X * 0.08
			camPitch = math.clamp(camPitch + p.Y * 0.03, -0.25, 0.8)
			lookReleasedAt = os.clock()
		end
	end
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
	b.Text = `[{VehicleConfig.KeyRespawn}] RESPAWN TRUCK`
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
	hint.Visible = false
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
		if driving then
			show = true
		elseif chassis and root then
			local flipped = chassis.CFrame.UpVector.Y < 0.3
			local far = (chassis.Position - root.Position).Magnitude > 250
			show = flipped or far
		end
		if respawnButton then
			respawnButton.Visible = show
		end
		if show ~= respawnBound then
			respawnBound = show
			if show then
				ContextActionService:BindAction("TruckRespawn", onAction, false, key("KeyRespawn", Enum.KeyCode.R))
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
local function animateCabs(dt: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local camPosNow = cam.CFrame.Position
	for _, truck in CollectionService:GetTagged(Names.Tag.Truck) do
		local chassis = truck:IsA("Model") and truck.PrimaryPart
		if not chassis or (chassis.Position - camPosNow).Magnitude > 90 then
			continue
		end
		local m = truck :: Model
		local seat = m:FindFirstChild("DriveSeat") :: VehicleSeat?
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

local function updateSeated()
	local truck, seat = seatedTruck()
	local isDriver = seat ~= nil and seat.Name == "DriveSeat"
	if ProximityPromptService.Enabled ~= (truck == nil) then
		ProximityPromptService.Enabled = truck == nil
	end
	local passenger = if truck and not isDriver then truck else nil
	if passenger ~= riding then
		if riding then
			ContextActionService:UnbindAction("TruckExit")
		end
		riding = passenger
		if passenger then
			ContextActionService:BindActionAtPriority(
				"TruckExit",
				onAction,
				true,
				Enum.ContextActionPriority.High.Value,
				key("KeyExit", Enum.KeyCode.F),
				Enum.KeyCode.ButtonB
			)
			ContextActionService:SetTitle("TruckExit", "OFF")
		end
	end
	local hint = hintLabel
	if hint then
		hint.Visible = truck ~= nil
		if isDriver then
			hint.Text = `{VehicleConfig.KeyExit}: exit   {VehicleConfig.KeySiren}: siren   {VehicleConfig.KeyHorn}: horn   SPACE: drift   {VehicleConfig.KeyCam}: camera   {VehicleConfig.KeyRespawn}: unflip`
		elseif truck then
			hint.Text = `{VehicleConfig.KeyExit}: hop off`
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
