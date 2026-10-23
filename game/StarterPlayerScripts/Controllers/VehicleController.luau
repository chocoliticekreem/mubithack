--!strict
-- VehicleController [owner: Vehicle agent]. Fire trucks on the client (docs/game/08 "Vehicles").
--   * Driving: when the local player sits in a truck's "DriveSeat" (the server hands them network
--     ownership) this runs the goofy driving every physics step (ClientLib/TruckDrive maths,
--     VehicleConfig numbers): jelly raycast suspension, body roll, wheelies on launch and bumps,
--     handbrake drift, cartoon squash + "BOING!" on hard landings, self-righting.
--   * Chase camera while driving (Scriptable, spring follow, right-drag to look around, FOV by speed);
--     FirstPersonController is paused and comes back on exit.
--   * Keys while driving: WASD drive, SPACE handbrake/drift, H horn, F siren, R unflip/respawn, E hop out.
--     A "RESPAWN TRUCK" button (and R) also shows on foot when your truck is flipped or far away.
--   * Everyone: light bars flash and sirens wail (pitch climbs with speed) on trucks with attr SirenOn;
--     "HONK!" pop over a truck on Vehicle/Honked.
-- Local visuals only; gameplay effects (run over, prop hits, blame) are decided by VehicleService.
local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
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
	local look = chassis.CFrame.LookVector
	local fwd = Vector3.new(look.X, 0, look.Z)
	fwd = if fwd.Magnitude > 0.05 then fwd.Unit else Vector3.new(0, 0, -1)
	local speed = chassis.AssemblyLinearVelocity.Magnitude

	if not looking and os.clock() - lookReleasedAt > 0.8 then
		local k = math.min(1, dt * 2.5)
		camYaw -= camYaw * k
		camPitch -= camPitch * k
	end
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

---------------------------------------------------------------------------- input

local function respawn()
	pcall(function()
		Net.event("Vehicle", "Respawn"):FireServer()
	end)
end

local function hopOut()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.Sit = false
		hum.Jump = true
	end
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
	ContextActionService:BindActionAtPriority("TruckHorn", onAction, true, high, Enum.KeyCode.H, Enum.KeyCode.ButtonY)
	ContextActionService:BindActionAtPriority("TruckSiren", onAction, true, high, Enum.KeyCode.F, Enum.KeyCode.ButtonX)
	ContextActionService:BindActionAtPriority("TruckExit", onAction, true, high, Enum.KeyCode.E, Enum.KeyCode.ButtonB)
	ContextActionService:SetTitle("TruckHandbrake", "DRIFT")
	ContextActionService:SetTitle("TruckHorn", "HONK")
	ContextActionService:SetTitle("TruckSiren", "SIREN")
	ContextActionService:SetTitle("TruckExit", "OUT")
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
	for _, a in { "TruckHandbrake", "TruckHorn", "TruckSiren", "TruckExit" } do
		ContextActionService:UnbindAction(a)
	end
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
		camPitch = math.clamp(camPitch - input.Delta.Y * 0.004, -0.25, 0.8)
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
	b.Text = "[R] RESPAWN TRUCK"
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
				ContextActionService:BindAction("TruckRespawn", onAction, false, Enum.KeyCode.R)
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
	end)
end

return VehicleController
