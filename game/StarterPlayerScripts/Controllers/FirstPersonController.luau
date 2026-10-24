--!strict
-- FirstPersonController [owner: G1]. The trailer's camera (docs/game/02-art-feel-ui.md §7):
--   * Mission over (results / back to the station): steps out of first person once so the mouse is
--     free and the cursor shows; the zoom stays free (scroll back in any time).
--   * LockFirstPerson while the player is in a mission (Player attr InstanceId ~= "" and its
--     Workspace.Runs.<id> RoundState is Alarm/Dispatched/Active, or no run folder yet); free third
--     person in the lobby / station (InstanceId == "") and on the results screen. V flips it (first
--     person in the lobby, third person on a mission) until the mission state changes. Unlocked
--     while Ragdolled, Downed, seated (VehicleController owns the driving camera) or when
--     SetEnabled(false). PhysicsConfig.FirstPerson = false turns the lock off everywhere. The mode is
--     re-asserted whenever something else (SquadService's spawn/revive lock) changes CameraMode.
--   * Physics hands (ClientLib/PhysicsHands, HandsConfig.Enabled): gloves on springs that collide,
--     reach, grab, slap and hold the equipped Tool as a floppy physics item (see that file).
--     Fallback on touch-only devices (unless HandsConfig.MobileEnabled) or when disabled: the simple
--     camera-attached Viewmodel (ClientLib/Viewmodel): olive/yellow gloves + turnout sleeves with
--     reflective bands; poses empty / hose / axe / carry / item from the equipped Tool and the
--     Carrying attr; axe swing on Tool.Activated, hose jitter while Spraying.
--   * The rescue you carry fades (local only) while you look through it in first person.
--   * Soot on the gloves after time near fire. Other players' arms follow their replicated hands
--     (PhysicsHands.startRemote, always on).
--   * Head bob, tool sway (camera-rotation spring), landing dip, sprint FOV.
--   * Screen: smoke-darkened edge vignette near Burning parts, heat tint at Heat >= 60 with heavy
--     breathing, sweat drops at >= 85, pulse near 100 (Player attr Heat, written by HeatService).
--   * Trauma camera shake for hazards/explosions (Shake).
-- Camera/screen are pure client visuals; the physics hands talk to HandsService (Hands/* remotes).
-- Public API for other controllers (03 §10 "v1.5 additions"):
--   FirstPersonController:SetEnabled(on: boolean)             -- e.g. ResultsController unlocks the mouse
--   FirstPersonController:Shake(magnitude: number, seconds: number)
--   FirstPersonController:GetViewmodel(): Instance?    -- the physics hands folder or the Viewmodel
--   FirstPersonController:GetNozzlePosition(): Vector3? -- where the first-person nozzle tip is now
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript) :: any
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local HeatConfig = require(ConfigFolder:WaitForChild("HeatConfig") :: ModuleScript) :: any
local PhysicsConfig = require(ConfigFolder:WaitForChild("PhysicsConfig") :: ModuleScript) :: any
local HandsConfig = require(ConfigFolder:WaitForChild("HandsConfig") :: ModuleScript) :: any
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local Viewmodel = require(ClientLib:WaitForChild("Viewmodel") :: ModuleScript)
local PhysicsHands = require(ClientLib:WaitForChild("PhysicsHands") :: ModuleScript)
local AxeArm = require(ClientLib:WaitForChild("AxeArm") :: ModuleScript)

local FirstPersonController = {}
FirstPersonController.Priority = 50

-- Camera feel numbers not in PhysicsConfig (02 §7, research §2). FOV and head bob amplitude/rate
-- come from PhysicsConfig (FieldOfView, HeadBobAmplitude, HeadBobHz) at use time.
local CAM = {
	SprintFovAdd = 8,
	SprintSpeed = 18, -- horizontal studs/s above which the sprint FOV kicks in
	FovLerp = 8,
	WalkSpeedRef = 16,
	ViewmodelBobScale = 1.4,
	ShakePitch = math.rad(3),
	ShakeYaw = math.rad(3),
	ShakeRoll = math.rad(2),
	SwayPerRad = 0.9, -- viewmodel lag per radian of camera turn
	SwayMax = math.rad(6),
	SwaySpring = 12,
	DipStuds = 0.25,
	DipDown = 0.08,
	DipUp = 0.2,
	LobbyZoom = 14,
	SmokeRange = 26, -- studs: Burning parts closer than this darken the screen edges
	SootAfter = 10, -- seconds near fire until gloves are fully sooty
}

local ATTR_HEAT = Names.Attr.Heat
local ATTR_INSTANCE = Names.Attr.InstanceId

local player = Players.LocalPlayer

local function attr(name: string): any
	return player:GetAttribute(name)
end

local MISSION_STATES = { Alarm = true, Dispatched = true, Active = true }

-- On a mission: our run (Workspace.Runs.<InstanceId>) is underway. The workspace-wide RoundState is
-- a summary of ANY squad's run, so it must not lock players still in the station.
local function inMission(): boolean
	local id = attr(ATTR_INSTANCE)
	if type(id) ~= "string" or id == "" then
		return false
	end
	local runs = workspace:FindFirstChild("Runs")
	local run = runs and runs:FindFirstChild(id)
	if not run then
		return true -- v1.5 instance (no Runs folder): InstanceId alone means "on a mission"
	end
	local st = run:GetAttribute(Names.Attr.RoundState)
	return st == nil or MISSION_STATES[st] == true
end

local function poseFor(char: Model?): (string, Tool?)
	local carrying = attr(Names.Attr.Carrying)
	if type(carrying) == "string" and carrying ~= "" then
		return "carry", nil
	end
	local tool = char and char:FindFirstChildOfClass("Tool")
	if not tool then
		return "empty", nil
	end
	local n = string.lower(tool.Name)
	if string.find(n, "hose") or string.find(n, "nozzle") then
		return "hose", tool
	elseif string.find(n, "axe") then
		return "axe", tool
	end
	return "item", tool
end

-- Screen overlay: four edge frames with UIGradient ramps (02 §9 hazard vignettes), a full-screen
-- warm wash, and a few sweat drops.
type Overlay = {
	gui: ScreenGui,
	edges: { Frame },
	wash: Frame,
	drops: { { frame: Frame, x: number, y: number, speed: number } },
}

local function buildOverlay(): Overlay
	local gui = Instance.new("ScreenGui")
	gui.Name = "FirstPersonFx"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = -5 -- under the HUD
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local wash = Instance.new("Frame")
	wash.Name = "Wash"
	wash.Size = UDim2.fromScale(1, 1)
	wash.BorderSizePixel = 0
	wash.BackgroundColor3 = Palette.FireEdge
	wash.BackgroundTransparency = 1
	wash.Parent = gui

	local edges: { Frame } = {}
	-- {anchor, position, size, gradient rotation}: gradient goes opaque at the screen edge.
	local specs = {
		{ Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.32), 90 }, -- top
		{ Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromScale(1, 0.32), -90 }, -- bottom
		{ Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(0.26, 1), 0 }, -- left
		{ Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.fromScale(0.26, 1), 180 }, -- right
	}
	for i, s in specs do
		local f = Instance.new("Frame")
		f.Name = "Edge" .. i
		f.AnchorPoint = s[1] :: Vector2
		f.Position = s[2] :: UDim2
		f.Size = s[3] :: UDim2
		f.BorderSizePixel = 0
		f.BackgroundColor3 = Palette.SmokeBlack
		f.BackgroundTransparency = 1
		local g = Instance.new("UIGradient")
		g.Rotation = s[4] :: number
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.55, 0.65),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Parent = f
		f.Parent = gui
		table.insert(edges, f)
	end

	local drops = {}
	for i = 1, 7 do
		local d = Instance.new("Frame")
		d.Name = "Sweat" .. i
		d.AnchorPoint = Vector2.new(0.5, 0.5)
		d.Size = UDim2.fromOffset(16 + (i % 3) * 6, 26 + (i % 3) * 8)
		d.BackgroundColor3 = Palette.WaterSpray
		d.BackgroundTransparency = 1
		d.BorderSizePixel = 0
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = d
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(1, 1, 1)
		stroke.Thickness = 2
		stroke.Transparency = 1
		stroke.Parent = d
		d.Parent = gui
		table.insert(drops, { frame = d, x = math.random(), y = math.random() * 0.3, speed = 0.08 + math.random() * 0.12 })
	end

	gui.Parent = player:WaitForChild("PlayerGui")
	return { gui = gui, edges = edges, wash = wash, drops = drops }
end

local vm: Viewmodel.Viewmodel? = nil
local hands: PhysicsHands.PhysicsHands? = nil

-- Physics hands unless disabled, or on a touch-only device (no mouse buttons to grab with).
local function wantPhysicsHands(): boolean
	if HandsConfig.Enabled == false then
		return false
	end
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and not UserInputService.MouseEnabled
	return not touchOnly or HandsConfig.MobileEnabled == true
end

local function pressureFor(pose: string, tool: Tool?): number
	local water, size = "Water", "TankSize"
	if tool and string.find(string.lower(tool.Name), "extinguish") then
		water, size = "Foam", "FoamSize"
	elseif pose ~= "hose" then
		return 1
	end
	local w = tonumber(attr(water)) or 0
	local s = tonumber(attr(size)) or 0
	return if s > 0 then math.clamp(w / s, 0, 1) else 1
end
local overlay: Overlay? = nil
local cc: ColorCorrectionEffect? = nil
local breath: Sound? = nil

local state = {
	t = 0,
	fov = 80,
	enabled = true,
	locked = nil :: boolean?,
	trauma = 0,
	traumaDecay = 1.6,
	sway = Vector2.zero,
	lastLook = nil :: Vector3?,
	dipT = -1,
	dipScale = 1,
	fallSpeed = 0,
	fireProx = 0, -- 0..1, nearest Burning part
	nearFireSeconds = 0,
	scanAt = 0,
	mission = false,
	viewFlip = false, -- V pressed: the other view until the mission state changes
	stepOutPending = false, -- mission just ended: step out of first person once (free mouse)
	hiddenTool = nil :: Tool?,
	toolConn = nil :: RBXScriptConnection?,
	toolFor = nil :: Tool?,
	heatShown = 0,
	bobPhase = 0,
	lastShake = CFrame.identity,
	shadowChar = nil :: Model?, -- character whose shadows we switched off for first person
}

-- In first person the (locally invisible) body still casts shadows, and the gloves sit inside it,
-- so they'd render in its shadow (the "black hands" look). Switch our own body's shadows off
-- locally while in first person; other players still see them.
local function setBodyShadows(char: Model?, fp: boolean)
	local want = if fp then char else nil
	if state.shadowChar == want then
		return
	end
	local function apply(m: Model?, cast: boolean)
		if not m then
			return
		end
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") and not d:IsA("Terrain") then
				if cast then
					local was = d:GetAttribute("FPShadow")
					if was ~= nil then
						d.CastShadow = was
						d:SetAttribute("FPShadow", nil)
					end
				elseif d:GetAttribute("FPShadow") == nil then
					d:SetAttribute("FPShadow", d.CastShadow)
					d.CastShadow = false
				end
			end
		end
	end
	if state.shadowChar and state.shadowChar.Parent then
		apply(state.shadowChar, true)
	end
	state.shadowChar = want
	apply(want, false)
end

local function wantLock(char: Model?): boolean
	if not state.enabled or PhysicsConfig.FirstPerson == false then
		return false
	end
	if inMission() == state.viewFlip then
		return false
	end
	if attr(Names.Attr.Downed) == true then
		return false
	end
	return not (char and char:GetAttribute(Names.Attr.Ragdolled) == true)
end

local function seated(char: Model?): boolean
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.SeatPart ~= nil
end

-- Step the camera out of the head once (lobby / results), so the mouse is free and the cursor shows.
-- Zoom stays free: CameraMinZoomDistance goes back to 0.5 right after, so scrolling in works again.
local function stepOut()
	player.CameraMaxZoomDistance = math.max(player.CameraMaxZoomDistance, CAM.LobbyZoom)
	local cam = workspace.CurrentCamera
	local char = player.Character
	local head = char and char:FindFirstChild("Head") :: BasePart?
	if cam and head and (cam.CFrame.Position - head.Position).Magnitude < 2 then
		-- don't shove the camera through a wall behind you (station spawn pads sit ~8 studs from
		-- the west wall; a forced 10-stud zoom left the camera stuck inside it until you moved)
		local back = -cam.CFrame.LookVector * 10
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { char :: Model }
		local hit = workspace:Raycast(head.Position, back, params)
		player.CameraMinZoomDistance = if hit then math.clamp(hit.Distance - 1, 2, 10) else 10
		task.delay(0.1, function()
			player.CameraMinZoomDistance = 0.5
		end)
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

-- Only touches the camera properties when the wanted mode changes, so other scripts (cinematics)
-- can still take over between transitions.
local function applyCameraMode(lock: boolean)
	-- someone else (SquadService on spawn/revive) changed CameraMode: re-assert ours
	local isLocked = player.CameraMode == Enum.CameraMode.LockFirstPerson
	if state.locked ~= nil and isLocked ~= state.locked then
		state.locked = nil
	end
	if state.locked == lock then
		return
	end
	state.locked = lock
	if lock then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
		player.CameraMinZoomDistance = 0.5
	else
		player.CameraMode = Enum.CameraMode.Classic
		player.CameraMinZoomDistance = 0.5
		stepOut()
	end
end

local function isFirstPerson(cam: Camera, char: Model?): boolean
	local head = char and char:FindFirstChild("Head") :: BasePart?
	if not head then
		return false
	end
	return (cam.CFrame.Position - head.Position).Magnitude < 1.6
end

local function scanFire(root: BasePart?)
	if not root then
		state.fireProx = 0
		return
	end
	local best = math.huge
	local pos = root.Position
	for _, p in CollectionService:GetTagged(Names.Tag.Burning) do
		if p:IsA("BasePart") then
			local d = (p.Position - pos).Magnitude
			if d < best then
				best = d
			end
		end
	end
	state.fireProx = if best == math.huge then 0 else math.clamp(1 - best / CAM.SmokeRange, 0, 1)
end

-- In first person the real Tool (welded to the invisible body's hand) is hidden locally, trail
-- included, so only the glove-held copy shows; others always see the real one. The axe is never
-- hidden: there is ONE axe, the real Tool (ClientLib/AxeArm), seen the same in 1P and 3P.
local function hideToolLocally(tool: Tool?)
	if tool and tool.Name == "Axe" then
		for _, d in tool:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = 0
			end
		end
		tool = nil
	end
	if state.hiddenTool and state.hiddenTool ~= tool then
		for _, d in state.hiddenTool:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = 0
			elseif d:IsA("Trail") and d:GetAttribute("FPHidden") then
				d.Enabled = true
				d:SetAttribute("FPHidden", nil)
			end
		end
		state.hiddenTool = nil
	end
	if tool then
		for _, d in tool:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = 1
			elseif d:IsA("Trail") and d.Enabled then
				d.Enabled = false
				d:SetAttribute("FPHidden", true)
			end
		end
		state.hiddenTool = tool
	end
end

-- In first person the rescue you carry hangs right in front of the camera and filled most of the
-- screen (a dog's face, edge to edge). Fade it locally while you look out through it; others see it
-- as normal.
local CARRY_FADE = 0.75
local fadedCarry: Model? = nil
local function fadeCarried(model: Model?)
	if fadedCarry == model then
		return
	end
	if fadedCarry then
		for _, d in fadedCarry:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = 0
			end
		end
	end
	fadedCarry = model
	if model then
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = CARRY_FADE
			end
		end
	end
end

local function carriedModel(): Model?
	local id = attr(Names.Attr.Carrying)
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local folder = workspace:FindFirstChild("Rescuables")
	local m = folder and folder:FindFirstChild(id)
	return if m and m:IsA("Model") then m else nil
end

local function bindSwing(tool: Tool?, pose: string)
	if state.toolFor == tool then
		return
	end
	if state.toolConn then
		state.toolConn:Disconnect()
		state.toolConn = nil
	end
	state.toolFor = tool
	if tool and pose == "axe" then
		state.toolConn = tool.Activated:Connect(function()
			if vm then
				vm:Swing()
			end
		end)
	end
end

local function updateScreen(dt: number)
	local o = overlay
	if not o then
		return
	end
	local heat = tonumber(attr(ATTR_HEAT)) or 0
	state.heatShown += (heat - state.heatShown) * math.min(1, dt * 6)
	local h = state.heatShown
	local warmAt = HeatConfig.WarmAt or 60
	local sweatyAt = HeatConfig.SweatyAt or 85
	local maxHeat = HeatConfig.Max or 100

	-- smoke darkens the edges near fire; heat pushes them orange and pulses near the top
	local heatRatio = math.clamp(h / maxHeat, 0, 1)
	local pulse = if h >= 70 then 0.5 + 0.5 * math.sin(state.t * math.pi * 2 * (1 + (h - 70) / 30)) else 0
	-- gear: a worn gas mask (attr GasMask) clears the smoke darkening; heat still tints the edges
	local smoke = if attr("GasMask") == true then 0 else state.fireProx * 0.75
	local strength = math.clamp(math.max(smoke, heatRatio * 0.85) + pulse * 0.15, 0, 0.95)
	local color = Palette.SmokeBlack:Lerp(Palette.FireEdge, math.clamp((h - 30) / 60, 0, 1))
	for _, e in o.edges do
		e.BackgroundColor3 = color
		e.BackgroundTransparency = 1 - strength
	end

	local warm = math.clamp((h - warmAt) / (maxHeat - warmAt), 0, 1)
	o.wash.BackgroundTransparency = 1 - (warm * 0.14 + pulse * warm * 0.06)
	if cc then
		cc.TintColor = Color3.new(1, 1, 1):Lerp(Color3.fromHex("#FFC79A"), warm)
		cc.Saturation = -0.15 * state.fireProx + 0.1 * warm
		cc.Brightness = -0.06 * state.fireProx
	end

	if breath then
		local want = if h >= warmAt then 0.25 + 0.5 * warm else 0
		breath.Volume += (want - breath.Volume) * math.min(1, dt * 3)
		breath.PlaybackSpeed = 1 + 0.35 * warm
		if want > 0 and not breath.IsPlaying and breath.SoundId ~= "" then
			breath:Play()
		elseif want == 0 and breath.IsPlaying and breath.Volume < 0.02 then
			breath:Stop()
		end
	end

	local sweaty = h >= sweatyAt
	for _, d in o.drops do
		if sweaty then
			d.y += d.speed * dt
			if d.y > 1.1 then
				d.y = -0.05
				d.x = math.random()
				d.speed = 0.08 + math.random() * 0.14
			end
			-- stay near the edges so the crosshair is clear
			local x = if d.x < 0.5 then d.x * 0.3 else 0.7 + (d.x - 0.5) * 0.6
			d.frame.Position = UDim2.fromScale(x, d.y)
			d.frame.BackgroundTransparency = 0.35
			local s = d.frame:FindFirstChildOfClass("UIStroke")
			if s then
				s.Transparency = 0.5
			end
		elseif d.frame.BackgroundTransparency < 1 then
			d.frame.BackgroundTransparency = math.min(1, d.frame.BackgroundTransparency + dt * 2)
			local s = d.frame:FindFirstChildOfClass("UIStroke")
			if s then
				s.Transparency = math.min(1, s.Transparency + dt * 2)
			end
		end
	end
end

local function step(dt: number)
	state.t += dt
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?

	if state.t >= state.scanAt then
		state.scanAt = state.t + 0.2
		scanFire(root)
	end
	if state.fireProx > 0.35 then
		state.nearFireSeconds = math.min(CAM.SootAfter, state.nearFireSeconds + dt)
	end

	local vel = if root then root.AssemblyLinearVelocity else Vector3.zero
	local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
	if vel.Y < -1 then
		state.fallSpeed = math.max(state.fallSpeed, -vel.Y)
	end

	-- per-frame mode check (cheap; only writes on change)
	local mission = inMission()
	if mission ~= state.mission then
		state.mission = mission
		state.viewFlip = false
		if not mission then
			state.nearFireSeconds = 0 -- soot washes off back at the station
			-- mission over (results / back to the station): hand the mouse back. First person keeps
			-- the cursor locked to the centre, so step out of the head once; the zoom stays free.
			state.stepOutPending = true
		end
	end
	if state.stepOutPending then
		if state.mission then
			state.stepOutPending = false
		elseif not seated(char) and cam.CameraType ~= Enum.CameraType.Scriptable then
			-- (still in the truck: this waits until you hop out)
			state.stepOutPending = false
			stepOut()
		end
	end
	if seated(char) then
		state.locked = nil -- VehicleController owns the camera while driving; re-apply on exit
	else
		applyCameraMode(wantLock(char))
	end
	local scripted = cam.CameraType == Enum.CameraType.Scriptable

	-- sprint FOV
	local baseFov = tonumber(PhysicsConfig.FieldOfView) or 80
	local wantFov = if speed > CAM.SprintSpeed then baseFov + CAM.SprintFovAdd else baseFov
	state.fov += (wantFov - state.fov) * math.min(1, dt * CAM.FovLerp)
	if not scripted then
		cam.FieldOfView = state.fov
	end

	local fp = state.enabled and not scripted and isFirstPerson(cam, char) and hum ~= nil and hum.Health > 0
	setBodyShadows(char, fp)
	fadeCarried(if fp then carriedModel() else nil)
	local downed = attr(Names.Attr.Downed) == true

	-- head bob and landing dip (camera)
	local amp = tonumber(PhysicsConfig.HeadBobAmplitude) or 0.12
	local hz = tonumber(PhysicsConfig.HeadBobHz) or 1.8
	local moving = if hum and hum.FloorMaterial ~= Enum.Material.Air
		then math.clamp(speed / CAM.WalkSpeedRef, 0, 1.3)
		else 0
	state.bobPhase += dt * hz * math.pi * 2 * math.max(moving, 0.0001)
	local bobY = -math.abs(math.sin(state.bobPhase)) * amp * moving
	local bobX = math.cos(state.bobPhase) * amp * 0.6 * moving
	local dip = 0
	if state.dipT >= 0 then
		state.dipT += dt
		local d = state.dipT
		if d < CAM.DipDown then
			dip = -CAM.DipStuds * state.dipScale * (d / CAM.DipDown)
		elseif d < CAM.DipDown + CAM.DipUp then
			dip = -CAM.DipStuds * state.dipScale * (1 - (d - CAM.DipDown) / CAM.DipUp)
		else
			state.dipT = -1
		end
	end

	-- trauma shake (02 §8): angles = max * trauma^2 * noise
	local shake = CFrame.identity
	if state.trauma > 0 then
		local k = state.trauma * state.trauma
		local n = state.t * 25
		shake = CFrame.Angles(
			CAM.ShakePitch * k * math.noise(n, 0.5),
			CAM.ShakeYaw * k * math.noise(n, 10.5),
			CAM.ShakeRoll * k * math.noise(n, 20.5)
		)
		state.trauma = math.max(0, state.trauma - state.traumaDecay * dt)
	end
	if not scripted then
		if fp then
			cam.CFrame = cam.CFrame * CFrame.new(bobX, bobY + dip, 0) * shake
		else
			cam.CFrame = cam.CFrame * shake
		end
		state.lastShake = shake
	end

	-- sway: viewmodel lags behind camera turns
	local look = cam.CFrame.LookVector
	local target = Vector2.zero
	if state.lastLook and dt > 0 then
		local last = state.lastLook :: Vector3
		local yaw = math.atan2(-look.X, -look.Z) - math.atan2(-last.X, -last.Z)
		if yaw > math.pi then
			yaw -= 2 * math.pi
		elseif yaw < -math.pi then
			yaw += 2 * math.pi
		end
		local pitch = math.asin(math.clamp(look.Y, -1, 1)) - math.asin(math.clamp(last.Y, -1, 1))
		target = Vector2.new(
			math.clamp(-pitch * CAM.SwayPerRad * 8, -CAM.SwayMax, CAM.SwayMax),
			math.clamp(-yaw * CAM.SwayPerRad * 8, -CAM.SwayMax, CAM.SwayMax)
		)
	end
	state.lastLook = look
	state.sway += (target - state.sway) * math.min(1, dt * CAM.SwaySpring)

	local h = hands
	if h then
		local pose, tool = poseFor(char)
		local seated = hum ~= nil and hum.Sit
		local show = fp and not downed and not seated and not (char and char:GetAttribute(Names.Attr.Ragdolled) == true)
		h:SetActive(show)
		if show then
			hideToolLocally(tool)
			h:SetSoot(state.nearFireSeconds / CAM.SootAfter)
			h:Update(dt, cam.CFrame, {
				pose = pose,
				tool = tool,
				bob = Vector2.new(bobX, bobY) * CAM.ViewmodelBobScale,
				sway = state.sway,
				dip = dip * 0.5,
				spraying = attr(Names.Attr.Spraying) == true,
				pressure = pressureFor(pose, tool),
			}, function(m: number, s: number)
				FirstPersonController:Shake(m, s)
			end)
		else
			hideToolLocally(nil)
		end
	end

	local v = if hands then nil else vm
	if v then
		local pose, tool = poseFor(char)
		bindSwing(tool, pose)
		local show = fp and not downed and not (hum ~= nil and hum.Sit) -- no hands over the windshield
		v:SetVisible(show)
		if show then
			hideToolLocally(tool)
			v:SetSoot(state.nearFireSeconds / CAM.SootAfter)
			v:Update(dt, cam.CFrame, {
				pose = pose :: any,
				bob = Vector2.new(bobX, bobY) * CAM.ViewmodelBobScale,
				sway = state.sway,
				spraying = attr(Names.Attr.Spraying) == true,
				dip = dip * 0.5,
			})
		else
			hideToolLocally(nil)
		end
	end

	updateScreen(dt)
end

local function watchCharacter(char: Model)
	local hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
	if not hum then
		return
	end
	state.fallSpeed = 0
	hum.StateChanged:Connect(function(_old, new)
		if new == Enum.HumanoidStateType.Landed then
			state.dipScale = math.clamp(state.fallSpeed / 40, 0.4, 1.6)
			state.dipT = 0
			state.fallSpeed = 0
		end
	end)
end

function FirstPersonController:Init(_controllers: { [string]: any }) end

function FirstPersonController:Start()
	-- other players' arms + SLAP!/THUNK pops run on every client, whatever this one uses
	PhysicsHands.startRemote(function(kind: string, _position: Vector3, extra: number)
		if (kind == "slap" or kind == "bonk") and extra == player.UserId then
			FirstPersonController:Shake(0.6, 0.35) -- you got slapped
		end
	end)
	-- the one physical axe: arm IK + head contact, local and every other player's (1P == 3P)
	AxeArm.start({
		shake = function(m: number, s: number)
			FirstPersonController:Shake(m, s)
		end,
	})
	if wantPhysicsHands() then
		local ok, res = pcall(PhysicsHands.new)
		if ok then
			hands = res
			res:BindInput()
		else
			warn(`[FirstPerson] physics hands failed, using the simple viewmodel: {res}`)
		end
	end
	vm = Viewmodel.new()
	if hands then
		vm:SetVisible(false)
	end
	local function parentVm()
		if vm then
			vm:SetParent(workspace.CurrentCamera)
		end
	end
	parentVm()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(parentVm)

	overlay = buildOverlay()

	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = "FirstPersonHeatCC"
	effect.Parent = Lighting
	cc = effect

	local s = Instance.new("Sound")
	s.Name = "FirstPersonBreathing"
	s.Looped = true
	s.Volume = 0
	s.SoundId = HeatConfig.BreathingSoundId or ""
	s.Parent = SoundService
	breath = s

	-- V: flip first / third person (until the mission state changes)
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == Enum.KeyCode.V then
			state.viewFlip = not state.viewFlip
		end
	end)

	state.fov = tonumber(PhysicsConfig.FieldOfView) or 80
	state.mission = inMission()
	applyCameraMode(wantLock(player.Character))
	player.CharacterAdded:Connect(function(char)
		state.locked = nil -- re-apply the mode for the new character
		watchCharacter(char)
	end)
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end

	-- The default camera derives next frame's look from Camera.CFrame, so take last frame's shake
	-- rotation back out before it runs (otherwise noise accumulates into drift).
	RunService:BindToRenderStep("FFCamUnshake", Enum.RenderPriority.Camera.Value - 1, function()
		local cam = workspace.CurrentCamera
		if cam and state.lastShake ~= CFrame.identity then
			if cam.CameraType ~= Enum.CameraType.Scriptable then
				cam.CFrame = cam.CFrame * state.lastShake:Inverse()
			end
			state.lastShake = CFrame.identity
		end
	end)
	RunService:BindToRenderStep("FFCam", Enum.RenderPriority.Camera.Value + 1, step)
end

function FirstPersonController:SetEnabled(on: boolean)
	state.enabled = on == true
	if not state.enabled then
		if vm then
			vm:SetVisible(false)
		end
		if hands then
			hands:SetActive(false)
		end
		hideToolLocally(nil)
		fadeCarried(nil)
	end
end

function FirstPersonController:Shake(magnitude: number, seconds: number)
	local m = math.clamp(tonumber(magnitude) or 0, 0, 1)
	if m <= 0 then
		return
	end
	state.trauma = math.min(1, state.trauma + m)
	state.traumaDecay = math.clamp(state.trauma / math.max(tonumber(seconds) or 0.5, 0.05), 0.3, 10)
end

function FirstPersonController:GetViewmodel(): Instance?
	if hands then
		return hands:GetModel()
	end
	return if vm then vm.model else nil
end

function FirstPersonController:GetNozzlePosition(): Vector3?
	if hands then
		local n = hands:GetNozzle()
		return if n then n.WorldPosition else nil
	end
	local tip = if vm then vm:GetNozzle() else nil
	return if tip then (tip.CFrame * CFrame.new(tip.Size.X / 2, 0, 0)).Position else nil
end

return FirstPersonController
