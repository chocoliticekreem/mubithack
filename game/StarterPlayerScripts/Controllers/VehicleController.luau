--!strict
-- VehicleController [owner: G2]. Truck 67 on the client:
--   * Driving: when the local player sits in "DriveSeat" (server gives them network ownership), this runs
--     the bouncy raycast suspension + arcade drive every physics step (ClientLib/TruckDrive maths,
--     VehicleConfig numbers). Chase camera while driving; first person comes back on exit.
--   * Input while driving: H = horn (Vehicle/Horn), G = siren toggle (Vehicle/Siren). Space = hop out.
--   * Light bar: LightRed/LightBlue/LightWhite flash while truck attr SirenOn or RoundState Alarm/Active.
--   * "HONK!" pop over the truck for everyone on Vehicle/Honked.
-- Local visuals only; gameplay effects (run over, blame) are decided by VehicleService.
local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local VehicleConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("VehicleConfig") :: ModuleScript)
local TruckDrive = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("TruckDrive") :: ModuleScript)

local VehicleController = {}
VehicleController.Priority = 60

local player = Players.LocalPlayer
-- Suspension corners in chassis space (chassis is 8.4 x 1.2 x 25; front is -Z).
local CORNERS = {
	Vector3.new(-3.8, 0, -10.5),
	Vector3.new(3.8, 0, -10.5),
	Vector3.new(-3.8, 0, 10),
	Vector3.new(3.8, 0, 10),
}

local driving = false
local savedCam: { mode: Enum.CameraMode, min: number, max: number }? = nil
local upsideDown = 0
local airborne = 0
local engine: Sound? = nil
local boing: Sound? = nil

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
	local hits = 0
	for _, c in CORNERS do
		local origin = cf:PointToWorldSpace(c)
		local res = workspace:Raycast(origin, -up * rest, params)
		local dist = if res then res.Distance else nil
		if dist then
			hits += 1
		end
		local vel = chassis:GetVelocityAtPosition(origin):Dot(up)
		local a = TruckDrive.spring(dist, rest, vel, VehicleConfig.Spring, VehicleConfig.Damping)
		if a > 0 then
			chassis:ApplyImpulseAtPosition(up * a * mass * 0.25 * dt, origin)
		end
	end
	local grounded = hits >= 2
	local ctrl = if grounded then 1 else VehicleConfig.AirControl

	-- comedy boing on a hard landing
	if grounded and airborne > 0.35 then
		if boing and boing.SoundId ~= "" then
			boing.PlaybackSpeed = 0.8 + math.random() * 0.4
			boing:Play()
		end
	end
	airborne = if grounded then 0 else airborne + dt

	local v = chassis.AssemblyLinearVelocity
	local look = cf.LookVector
	local fwd = Vector3.new(look.X, 0, look.Z)
	fwd = if fwd.Magnitude > 0.05 then fwd.Unit else Vector3.new(0, 0, -1)
	local right = Vector3.new(-fwd.Z, 0, fwd.X)
	local fwdSpeed = v:Dot(fwd)
	local lat = v:Dot(right)
	local throttle = seat.ThrottleFloat
	local steer = seat.SteerFloat
	local acc = TruckDrive.drive(throttle, fwdSpeed, VehicleConfig.MaxSpeed, VehicleConfig.Accel, VehicleConfig.Brake)
	local dv = fwd * acc * dt * ctrl
	if grounded then
		dv += right * TruckDrive.grip(lat, VehicleConfig.Grip) * dt
	end
	chassis.AssemblyLinearVelocity = v + dv

	local av = chassis.AssemblyAngularVelocity
	local yawTarget = TruckDrive.steerRate(steer, fwdSpeed, VehicleConfig.TurnSpeed, VehicleConfig.MaxSpeed) * ctrl
	local k = math.min(1, dt * 6)
	local tilt = if grounded then math.max(0, 1 - dt * 1.5) else 1
	chassis.AssemblyAngularVelocity = Vector3.new(av.X * tilt, av.Y + (yawTarget - av.Y) * k, av.Z * tilt)

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

local function onAction(name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if name == "TruckHorn" then
		Net.event("Vehicle", "Horn"):FireServer()
	elseif name == "TruckSiren" then
		Net.event("Vehicle", "Siren"):FireServer()
	end
	return Enum.ContextActionResult.Sink
end

local function enterDrive(truck: Model)
	if driving then
		return
	end
	driving = true
	savedCam = { mode = player.CameraMode, min = player.CameraMinZoomDistance, max = player.CameraMaxZoomDistance }
	player.CameraMode = Enum.CameraMode.Classic
	player.CameraMaxZoomDistance = 45
	player.CameraMinZoomDistance = 26
	ContextActionService:BindAction("TruckHorn", onAction, true, Enum.KeyCode.H, Enum.KeyCode.ButtonY)
	ContextActionService:BindAction("TruckSiren", onAction, true, Enum.KeyCode.G, Enum.KeyCode.ButtonX)
	ContextActionService:SetTitle("TruckHorn", "HONK")
	ContextActionService:SetTitle("TruckSiren", "SIREN")
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
	if chassis and not boing then
		local b = Instance.new("Sound")
		b.Name = "LocalBoing"
		b.SoundId = VehicleConfig.BoingSoundId
		b.Volume = 0.8
		b.Parent = chassis
		boing = b
	end
end

local function exitDrive()
	if not driving then
		return
	end
	driving = false
	ContextActionService:UnbindAction("TruckHorn")
	ContextActionService:UnbindAction("TruckSiren")
	if engine then
		engine:Destroy()
		engine = nil
	end
	if boing then
		boing:Destroy()
		boing = nil
	end
	local s = savedCam
	if s then
		player.CameraMinZoomDistance = s.min
		player.CameraMaxZoomDistance = s.max
		player.CameraMode = s.mode
	end
	savedCam = nil
end

local function honkPop(truck: Model?)
	local root = if typeof(truck) == "Instance" and truck:IsA("Model") then truck.PrimaryPart else nil
	if not root then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "HonkPop"
	gui.Size = UDim2.fromOffset(160, 60)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 11, -10)
	gui.AlwaysOnTop = true
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Font = Enum.Font.LuckiestGuy
	t.TextScaled = true
	t.Text = if math.random() < 0.15 then "HONK HONK!" else "HONK!"
	t.TextColor3 = Color3.fromRGB(255, 228, 92)
	t.TextStrokeTransparency = 0
	t.Rotation = math.random(-12, 12)
	t.Parent = gui
	gui.Parent = root
	TweenService:Create(gui, TweenInfo.new(0.7), { StudsOffsetWorldSpace = Vector3.new(0, 15, -10) }):Play()
	TweenService:Create(t, TweenInfo.new(0.7), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	task.delay(0.75, function()
		gui:Destroy()
	end)
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

local function lightBar(truck: Model, roundHot: boolean, phase: boolean)
	local r = truck:FindFirstChild("LightRed")
	local b = truck:FindFirstChild("LightBlue")
	local w = truck:FindFirstChild("LightWhite")
	local flashing = roundHot or truck:GetAttribute("SirenOn") == true
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
		local state = workspace:GetAttribute(Names.Attr.RoundState)
		for _, truck in CollectionService:GetTagged(Names.Tag.Truck) do
			if truck:IsA("Model") then
				-- lobby truck follows the v1 round summary; instance trucks follow their instance's RoundState
				local inst = truck:FindFirstAncestorWhichIsA("Model")
				local st = if inst and inst:GetAttribute(Names.Attr.InstanceId) then inst:GetAttribute(Names.Attr.RoundState) else state
				lightBar(truck, st == "Alarm" or st == "Active", phase)
			end
		end
	end
end

function VehicleController:Init(_controllers: { [string]: any }) end

function VehicleController:Start()
	task.spawn(lightBarLoop)
	task.spawn(function()
		local ok, Honked = pcall(Net.event, "Vehicle", "Honked")
		if ok then
			(Honked :: RemoteEvent).OnClientEvent:Connect(honkPop)
		end
	end)
	RunService.PreSimulation:Connect(function(dt: number)
		local truck = drivenTruck()
		if truck then
			enterDrive(truck)
			step(truck, dt)
		elseif driving then
			exitDrive()
		end
	end)
end

return VehicleController
