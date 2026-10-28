--!strict
-- DriveController [owner: Drive]. The drive to a call, on the client (DriveConfig; server: DriveService).
-- Live funnel: 28-35% quit between "In Truck" and "Arrived On Scene". NO autopilot: this only draws and
-- sends intent; a kid always drives.
--   * ARRIVING bar (everyone in a truck while my run is Dispatched): the call card ("HOUSE FIRE · 6 Birch Rd"),
--     "ARRIVING IN 12s" (DriveMath.eta of the GPS road distance left, NavigationController:GetRouteInfo) with
--     the metres left, and a progress bar with a truck sliding to the flame. Riders also see PRACTICE FIRES n/N.
--     On arrival it flashes ARRIVING NOW! and goes. TopCentre stack (HudLayout), under the GO card.
--   * Driver: a big TURN LEFT / RIGHT / U-TURN arrow card when the next turn is DriveConfig.TurnShowStuds
--     away, and WRONG WAY! TURN AROUND when the truck runs back along the route for WrongWaySeconds (the GPS
--     re-routes on its own once you're off the line); its arrow turns to point back along the route.
--     Touch (DriveConfig.TouchTurnAlways): the card is bigger, sits in the TopCentre stack right under the
--     ARRIVING bar and never hides on a call (STRAIGHT ON + metres to the next turn between turns).
--   * Riders (any non-driver seat of a truck): HONK (H / Y), SIREN (G / X) and the roof WATER CANNON (hold
--     click / R2 / the SPRAY thumb button): it auto-aims at the nearest practice fire in front (DriveService
--     tag DriveTarget, my run) within CannonRange, draws a water beam from the truck roof, and sends
--     Drive/Hit every HitInterval. "SPRAY!" bubbles float over practice fires in range.
--   * NOBODY'S DRIVING!: a rider on a call whose driver's seat stays empty NoDriverSeconds gets a big
--     TAKE THE WHEEL! button (Drive/TakeWheel moves them over).
-- Touch: rider buttons go into ClientLib/ThumbLayout (SPRAY primary, HONK upleft, SIREN left; VehicleController
-- puts OFF above). Gamepad: R2 / Y / X; the TAKE THE WHEEL! button is a normal GUI button (D-pad select).
local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("DriveConfig") :: ModuleScript) :: any
local VehicleConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("VehicleConfig") :: ModuleScript) :: any
local DriveMath = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Vehicle"):WaitForChild("DriveMath") :: ModuleScript)
local Loc = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Loc") :: ModuleScript)
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript)
local HudLayout = require(ClientLib:WaitForChild("HudLayout") :: ModuleScript)
local ThumbLayout = require(ClientLib:WaitForChild("ThumbLayout") :: ModuleScript)
local InputHints = require(ClientLib:WaitForChild("InputHints") :: ModuleScript) :: any

local DriveController = {}
DriveController.Priority = 72 -- after NavigationController (70)

local player = Players.LocalPlayer
local controllers: { [string]: any } = {}
local TRUCK_TAG: string = (Names.Tag :: any).Truck or "Truck"
local TARGET_TAG = "DriveTarget"
local CREAM: Color3 = Palette.UiCream or Color3.fromRGB(255, 244, 222)
local WARN: Color3 = Palette.UiWarn or Color3.fromRGB(255, 197, 49)
local WATER = Color3.fromRGB(120, 210, 255)
local DARK: Color3 = Palette.UiPanelDark or Color3.fromRGB(30, 34, 44)

------------------------------------------------------------------------------------------ state

local function seated(): (BasePart?, Model?)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	local node: Instance? = seat
	while node and node ~= workspace do
		if node:IsA("Model") and CollectionService:HasTag(node, TRUCK_TAG) then
			return seat, node :: Model
		end
		node = node.Parent
	end
	return nil, nil
end

local function myRun(): Instance?
	local id = player:GetAttribute(Names.Attr.InstanceId)
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local runs = workspace:FindFirstChild("Runs")
	return runs and runs:FindFirstChild(id)
end

local function routeInfo(): any
	local nav = controllers.NavigationController
	if not nav or type(nav.GetRouteInfo) ~= "function" then
		return nil
	end
	local ok, info = pcall(nav.GetRouteInfo, nav)
	return if ok then info else nil
end

------------------------------------------------------------------------------------------ UI

type Ui = {
	gui: ScreenGui,
	bar: Frame,
	call: TextLabel,
	eta: TextLabel,
	dist: TextLabel,
	fill: Frame,
	truck: TextLabel,
	extra: TextLabel,
	turnGui: ScreenGui,
	turn: Frame,
	turnIcon: TextLabel,
	turnText: TextLabel,
	turnDist: TextLabel,
	wheel: Frame,
	wheelBtn: TextButton,
}
local ui: Ui? = nil

local function build(): Ui
	local gui = UiKit.screen("DriveHud", 6)
	local bar = Instance.new("Frame")
	bar.Name = "ArrivingBar"
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.new(0.5, 0, 0, 120)
	bar.Size = UDim2.fromOffset(440, 78)
	bar.BackgroundColor3 = DARK
	bar.BackgroundTransparency = 0.12
	bar.Visible = false
	bar.Parent = gui
	UiKit.corner(bar, 14)
	UiKit.stroke(bar, 3, WARN)
	local call = UiKit.label(bar, "Call", "", UDim2.new(1, -20, 0, 22), UDim2.fromOffset(10, 5), {
		font = UiKit.Header,
		textSize = 20,
		color = WARN,
		stroke = true,
		align = Enum.TextXAlignment.Left,
	})
	call.TextTruncate = Enum.TextTruncate.AtEnd
	call.TextWrapped = false
	local eta = UiKit.label(bar, "Eta", "", UDim2.new(0.66, -10, 0, 26), UDim2.fromOffset(10, 27), {
		font = UiKit.Header,
		textSize = 25,
		color = CREAM,
		stroke = true,
		align = Enum.TextXAlignment.Left,
	})
	eta.TextWrapped = false
	local dist = UiKit.label(bar, "Dist", "", UDim2.new(0.34, -10, 0, 26), UDim2.new(0.66, 0, 0, 27), {
		font = UiKit.Header,
		textSize = 22,
		color = CREAM,
		stroke = true,
		align = Enum.TextXAlignment.Right,
	})
	dist.TextWrapped = false
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.new(0, 12, 1, -18)
	track.Size = UDim2.new(1, -52, 0, 10)
	track.BackgroundColor3 = Color3.fromRGB(70, 74, 86)
	track.Parent = bar
	UiKit.corner(track, 5)
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = WARN
	fill.Parent = track
	UiKit.corner(fill, 5)
	local truck = UiKit.label(track, "Truck", "🚒", UDim2.fromOffset(26, 26), UDim2.new(0, 0, 0.5, 0), { textSize = 22 })
	truck.AnchorPoint = Vector2.new(0.5, 0.5)
	truck.ZIndex = 3
	local flame = UiKit.label(bar, "Flame", "🔥", UDim2.fromOffset(28, 28), UDim2.new(1, -36, 1, -31), { textSize = 22 })
	flame.ZIndex = 3
	local extra = UiKit.label(bar, "Extra", "", UDim2.new(1, 0, 0, 22), UDim2.new(0, 0, 1, 4), {
		font = UiKit.Header,
		textSize = 18,
		color = WATER,
		stroke = true,
	})
	extra.Visible = false
	HudLayout.add("TopCentre", bar, 22, function(): number
		return if extra.Visible then 104 else 78
	end)

	-- big turn arrow / WRONG WAY card (driver), upper middle of the screen
	local turnGui = UiKit.screen("DriveTurn", 5)
	local turn = Instance.new("Frame")
	turn.Name = "Turn"
	turn.AnchorPoint = Vector2.new(0.5, 0.5)
	turn.Position = UDim2.fromScale(0.5, 0.32)
	turn.Size = UDim2.fromOffset(300, 92)
	turn.BackgroundColor3 = DARK
	turn.BackgroundTransparency = 0.15
	turn.Visible = false
	turn.Parent = turnGui
	UiKit.corner(turn, 18)
	UiKit.stroke(turn, 4, Color3.fromHex("#7FF5F0"))
	local icon = UiKit.label(turn, "Icon", "", UDim2.fromOffset(82, 82), UDim2.fromOffset(6, 5), {
		font = UiKit.Header,
		textSize = 64,
		color = Color3.fromHex("#7FF5F0"),
		stroke = true,
	})
	local turnText = UiKit.label(turn, "Text", "", UDim2.new(1, -100, 0, 44), UDim2.fromOffset(92, 6), {
		font = UiKit.Header,
		textSize = 36,
		color = CREAM,
		stroke = true,
		scaled = true,
		align = Enum.TextXAlignment.Left,
	})
	local turnDist = UiKit.label(turn, "Dist", "", UDim2.new(1, -100, 0, 30), UDim2.fromOffset(92, 52), {
		font = UiKit.Header,
		textSize = 26,
		color = Color3.fromHex("#7FF5F0"),
		stroke = true,
		align = Enum.TextXAlignment.Left,
	})
	if InputHints.isTouch() and Cfg.TouchTurnAlways then
		-- phones: always up on a call, at the top (right under the ARRIVING bar), bigger arrow
		turn.AnchorPoint = Vector2.new(0.5, 0)
		turn.Size = UDim2.fromOffset(360, 104)
		icon.Size = UDim2.fromOffset(96, 96)
		icon.TextSize = 84
		turnText.Position = UDim2.fromOffset(106, 8)
		turnText.Size = UDim2.new(1, -114, 0, 50)
		turnDist.Position = UDim2.fromOffset(106, 60)
		turnDist.Size = UDim2.new(1, -114, 0, 34)
		HudLayout.add("TopCentre", turn, 23)
	end

	-- NOBODY'S DRIVING! card for riders
	local wheel = Instance.new("Frame")
	wheel.Name = "NoDriver"
	wheel.AnchorPoint = Vector2.new(0.5, 0.5)
	wheel.Position = UDim2.fromScale(0.5, 0.42)
	wheel.Size = UDim2.fromOffset(420, 150)
	wheel.BackgroundColor3 = DARK
	wheel.BackgroundTransparency = 0.1
	wheel.Visible = false
	wheel.Parent = turnGui
	UiKit.corner(wheel, 18)
	UiKit.stroke(wheel, 4, WARN)
	UiKit.label(wheel, "Head", "NOBODY'S DRIVING!", UDim2.new(1, -20, 0, 36), UDim2.fromOffset(10, 8), {
		font = UiKit.Header,
		textSize = 32,
		color = WARN,
		stroke = true,
		scaled = true,
	})
	UiKit.label(wheel, "Sub", "Hop in the driver's seat and drive to the fire!", UDim2.new(1, -20, 0, 26), UDim2.fromOffset(10, 44), {
		textSize = 20,
		color = CREAM,
		stroke = true,
		scaled = true,
	})
	local btn = UiKit.button(wheel, "TakeWheel", "TAKE THE WHEEL!", UDim2.fromOffset(300, 56), UDim2.new(0.5, 0, 1, -40), Color3.fromRGB(70, 200, 90)) -- (centre-anchored)
	UiKit.onTap(btn, function()
		pcall(function()
			Net.event("Drive", "TakeWheel"):FireServer()
		end)
	end)
	return {
		gui = gui,
		bar = bar,
		call = call,
		eta = eta,
		dist = dist,
		fill = fill,
		truck = truck,
		extra = extra,
		turnGui = turnGui,
		turn = turn,
		turnIcon = icon,
		turnText = turnText,
		turnDist = turnDist,
		wheel = wheel,
		wheelBtn = btn,
	}
end

local function metres(studs: number): string
	return Loc.t("{1} m", { DriveMath.metres(studs) })
end

------------------------------------------------------------------------------------------ rider: honk, siren, water cannon

local riderBound = false
local spraying = false
local beam: Beam? = nil
local beamA0: Attachment? = nil
local beamA1: Attachment? = nil
local splash: ParticleEmitter? = nil
local lastHitAt = 0

local function targetsInRange(truck: Model): { Model }
	local out = {}
	local id = player:GetAttribute(Names.Attr.InstanceId)
	local from = truck:GetPivot().Position
	local range = tonumber(Cfg.CannonRange) or 110
	for _, m in CollectionService:GetTagged(TARGET_TAG) do
		if m:IsA("Model") and m:GetAttribute("RunId") == id and m:GetAttribute("Out") ~= true then
			local d = (m:GetPivot().Position - from).Magnitude
			if d <= range then
				table.insert(out, m :: Model)
			end
		end
	end
	return out
end

-- the practice fire the cannon points at: in front of the camera first, else the nearest one
local function aimTarget(truck: Model): Model?
	local cam = workspace.CurrentCamera
	local list = targetsInRange(truck)
	local from = truck:GetPivot().Position
	local best: Model?, bestScore = nil, -math.huge
	for _, m in list do
		local p = m:GetPivot().Position
		local d = (p - from).Magnitude
		local score = -d
		if cam then
			local dir = (p - cam.CFrame.Position)
			if dir.Magnitude > 1e-3 and cam.CFrame.LookVector:Dot(dir.Unit) > (tonumber(Cfg.CannonCone) or 0.2) then
				score += 1000
			end
		end
		if score > bestScore then
			best, bestScore = m, score
		end
	end
	return best
end

local function ensureBeam(truck: Model)
	local chassis = truck.PrimaryPart
	if not chassis then
		return
	end
	if not beam or not beam.Parent or (beamA0 and beamA0.Parent ~= chassis) then
		if beam then
			beam:Destroy()
		end
		if beamA0 then
			beamA0:Destroy()
		end
		local a0 = Instance.new("Attachment")
		a0.Name = "CannonNozzle_Local"
		a0.Position = Vector3.new(0, 6.5, -6)
		a0.Parent = chassis
		local a1 = beamA1 or Instance.new("Attachment")
		a1.Name = "CannonEnd_Local"
		a1.Parent = workspace.Terrain
		local b = Instance.new("Beam")
		b.Name = "CannonWater_Local"
		b.Attachment0 = a0
		b.Attachment1 = a1
		b.Color = ColorSequence.new(WATER)
		b.Width0 = 0.8
		b.Width1 = 2.6
		b.LightEmission = 0.6
		b.Transparency = NumberSequence.new(0.15, 0.45)
		b.FaceCamera = true
		b.Segments = 12
		b.CurveSize0 = 6
		b.Enabled = false
		b.Parent = chassis
		local e = splash or Instance.new("ParticleEmitter")
		e.Name = "Splash"
		e.Color = ColorSequence.new(WATER)
		e.Size = NumberSequence.new(1.2, 0)
		e.Speed = NumberRange.new(8, 16)
		e.SpreadAngle = Vector2.new(70, 70)
		e.Lifetime = NumberRange.new(0.3, 0.6)
		e.Rate = 0
		e.Parent = a1
		beam, beamA0, beamA1, splash = b, a0, a1, e
	end
end

local function stopSpray()
	spraying = false
	if beam then
		beam.Enabled = false
	end
	if splash then
		splash.Rate = 0
	end
end

local function sprayStep(truck: Model)
	ensureBeam(truck)
	local b, a1 = beam, beamA1
	if not b or not a1 then
		return
	end
	local target = aimTarget(truck)
	local cam = workspace.CurrentCamera
	local at: Vector3
	if target then
		local flame = target:FindFirstChild("Flame")
		at = if flame and flame:IsA("BasePart") then flame.Position else target:GetPivot().Position
	elseif cam then
		at = cam.CFrame.Position + cam.CFrame.LookVector * 50
	else
		return
	end
	a1.WorldPosition = at
	b.Enabled = true
	if splash then
		splash.Rate = if target then 60 else 0
	end
	local now = os.clock()
	if target and now - lastHitAt >= (tonumber(Cfg.HitInterval) or 0.25) then
		lastHitAt = now
		pcall(function()
			Net.event("Drive", "Hit"):FireServer(target)
		end)
	end
end

local function onRiderAction(name: string, state: Enum.UserInputState, _input: any): Enum.ContextActionResult
	if name == "DriveSpray" then
		spraying = state == Enum.UserInputState.Begin or state == Enum.UserInputState.Change
		if not spraying then
			stopSpray()
		end
		return Enum.ContextActionResult.Sink
	end
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	if name == "DriveHonk" then
		pcall(function()
			Net.event("Vehicle", "Horn"):FireServer()
		end)
	elseif name == "DriveSiren" then
		pcall(function()
			Net.event("Vehicle", "Siren"):FireServer()
		end)
	end
	return Enum.ContextActionResult.Sink
end

local function keyOf(name: string, fallback: Enum.KeyCode): Enum.KeyCode
	local ok, k = pcall(function()
		return (Enum.KeyCode :: any)[VehicleConfig[name]]
	end)
	return if ok and k then k else fallback
end

local function bindRider(on: boolean)
	if on == riderBound then
		return
	end
	riderBound = on
	local high = Enum.ContextActionPriority.High.Value
	if on then
		if Cfg.Targets then -- the roof cannon only has something to spray when practice fires are on
			ContextActionService:BindActionAtPriority("DriveSpray", onRiderAction, true, high, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2)
			ContextActionService:SetTitle("DriveSpray", "SPRAY")
			ThumbLayout.place("DriveSpray", "primary", onRiderAction)
		end
		ContextActionService:BindActionAtPriority("DriveHonk", onRiderAction, true, high, keyOf("KeyHorn", Enum.KeyCode.H), Enum.KeyCode.ButtonY)
		ContextActionService:BindActionAtPriority("DriveSiren", onRiderAction, true, high, keyOf("KeySiren", Enum.KeyCode.G), Enum.KeyCode.ButtonX)
		ContextActionService:SetTitle("DriveHonk", "HONK")
		ContextActionService:SetTitle("DriveSiren", "SIREN")
		ThumbLayout.place("DriveHonk", "upleft", onRiderAction)
		ThumbLayout.place("DriveSiren", "left", onRiderAction)
	else
		for _, a in { "DriveSpray", "DriveHonk", "DriveSiren" } do
			ThumbLayout.forget(a)
			ContextActionService:UnbindAction(a)
		end
		stopSpray()
	end
end

-- "SPRAY!" bubbles over practice fires (riders only, local)
local bubbles: { [Model]: BillboardGui } = {}
local function updateBubbles(truck: Model?, rider: boolean)
	local live: { [Model]: boolean } = {}
	if truck and rider then
		for _, m in targetsInRange(truck) do
			live[m] = true
			if not bubbles[m] then
				local flame = m:FindFirstChild("Flame")
				local g = Instance.new("BillboardGui")
				g.Name = "SprayBubble_Local"
				g.Size = UDim2.fromOffset(110, 40)
				g.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
				g.AlwaysOnTop = true
				g.LightInfluence = 0
				g.Adornee = if flame and flame:IsA("BasePart") then flame else m.PrimaryPart
				local l = UiKit.label(g, "Text", "SPRAY!", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
					font = UiKit.Header,
					textSize = 28,
					color = WATER,
					stroke = true,
				})
				l.TextScaled = true
				g.Parent = player:FindFirstChildOfClass("PlayerGui")
				bubbles[m] = g
			end
		end
	end
	for m, g in bubbles do
		if not live[m] then
			g:Destroy()
			bubbles[m] = nil
		end
	end
end

------------------------------------------------------------------------------------------ per frame

local etaS = 0
local wrongFor = 0
local noDriverFor = 0
local arrivedFlash = 0
local wasDriving = false
local lastRun: Instance? = nil

local ICON = { left = "⬅", right = "➡", uturn = "↩" }

local function step(dt: number)
	local u = ui
	if not u then
		return
	end
	local seat, truck = seated()
	local run = myRun()
	local state = if run then run:GetAttribute(Names.Attr.RoundState) else nil
	local onCall = run ~= nil and state == "Dispatched"
	local isDriver = seat ~= nil and seat.Name == "DriveSeat"
	local rider = seat ~= nil and not isDriver
	bindRider(rider)
	if rider and spraying and truck then
		sprayStep(truck)
	elseif beam and beam.Enabled and not spraying then
		stopSpray()
	end
	updateBubbles(truck, rider and onCall)

	-- arrival flash: the run went from Dispatched to on scene while we were driving to it
	if wasDriving and run == lastRun and not onCall and run then
		arrivedFlash = 1.6
	end
	wasDriving = onCall and seat ~= nil
	lastRun = run

	local info = if onCall then routeInfo() else nil
	local speed = 0
	if truck and truck.PrimaryPart then
		local v = truck.PrimaryPart.AssemblyLinearVelocity
		speed = Vector3.new(v.X, 0, v.Z).Magnitude
	end

	-- ARRIVING bar
	if arrivedFlash > 0 then
		arrivedFlash -= dt
		u.bar.Visible = arrivedFlash > 0
		u.eta.Text = Loc.t("ARRIVING NOW!")
		u.dist.Text = ""
		u.fill.Size = UDim2.fromScale(1, 1)
		u.truck.Position = UDim2.new(1, 0, 0.5, 0)
		u.extra.Visible = false
	elseif onCall and seat and info and run then
		u.bar.Visible = true
		local callName = tostring(run:GetAttribute("Call") or "Fire")
		local addr = run:GetAttribute("Address")
		u.call.Text = Loc.t("{1} · {2}", { string.upper(Loc.t(callName)), if type(addr) == "string" then addr else "" })
		local want = DriveMath.eta(info.left, speed, tonumber(Cfg.EtaMinSpeed) or 30)
		etaS = if etaS <= 0 then want else etaS + (want - etaS) * math.clamp(dt * (tonumber(Cfg.EtaSmoothing) or 2), 0, 1)
		u.eta.Text = Loc.t("ARRIVING IN {1}s", { math.max(1, math.floor(etaS + 0.5)) })
		u.dist.Text = metres(info.left)
		local k = DriveMath.progress(info.total, info.left)
		u.fill.Size = UDim2.fromScale(k, 1)
		u.truck.Position = UDim2.new(k, 0, 0.5, 0)
		if rider and truck then
			local total, out = 0, 0
			local id = player:GetAttribute(Names.Attr.InstanceId)
			for _, m in CollectionService:GetTagged(TARGET_TAG) do
				if m:GetAttribute("RunId") == id then
					total += 1
					if m:GetAttribute("Out") == true then
						out += 1
					end
				end
			end
			u.extra.Visible = total > 0
			u.extra.Text = Loc.t("PRACTICE FIRES  {1}/{2}", { out, total })
		else
			u.extra.Visible = false
		end
	else
		u.bar.Visible = false
		etaS = 0
	end

	-- driver: big turn arrow / WRONG WAY (touch: always up on a call)
	local showTurn = false
	local rot = 0
	if isDriver and onCall and info and not info.arrived and truck then
		local look = truck:GetPivot().LookVector
		local dot = look.X * info.dx + look.Z * info.dz
		if speed > (tonumber(Cfg.WrongWayMinSpeed) or 8) and dot < -0.3 then
			wrongFor += dt
		else
			wrongFor = 0
		end
		if wrongFor >= (tonumber(Cfg.WrongWaySeconds) or 1.5) then
			showTurn = true
			-- an arrow that points back along the route, as seen from the camera
			local cam = workspace.CurrentCamera
			local cl = if cam then cam.CFrame.LookVector else look
			u.turnIcon.Text = "⬆"
			rot = DriveMath.cueRotation(cl.X, cl.Z, info.dx, info.dz)
			u.turnText.Text = Loc.t("WRONG WAY!")
			u.turnDist.Text = Loc.t("TURN AROUND")
			u.turnIcon.TextColor3 = WARN
		elseif info.turn and info.turnDist <= (tonumber(Cfg.TurnShowStuds) or 110) and info.turnDist >= (tonumber(Cfg.TurnHideStuds) or 6) then
			showTurn = true
			u.turnIcon.Text = ICON[info.turn] or "⬆"
			u.turnText.Text = if info.turn == "uturn" then Loc.t("U-TURN") else Loc.t("TURN {1}", { Loc.t(string.upper(info.turn)) })
			u.turnDist.Text = metres(info.turnDist)
			u.turnIcon.TextColor3 = Color3.fromHex("#7FF5F0")
		elseif Cfg.TouchTurnAlways and InputHints.isTouch() then
			showTurn = true
			u.turnIcon.Text = "⬆"
			u.turnText.Text = Loc.t("STRAIGHT ON")
			u.turnDist.Text = metres(if info.turn and info.turnDist > 0 then info.turnDist else info.left)
			u.turnIcon.TextColor3 = Color3.fromHex("#7FF5F0")
		end
	else
		wrongFor = 0
	end
	u.turnIcon.Rotation = rot
	u.turn.Visible = showTurn

	-- rider with an empty driver's seat on a call
	local empty = false
	if rider and onCall and truck then
		local ds = truck:FindFirstChild("DriveSeat")
		empty = ds ~= nil and ds:IsA("VehicleSeat") and ds.Occupant == nil
	end
	noDriverFor = if empty then noDriverFor + dt else 0
	u.wheel.Visible = noDriverFor >= (tonumber(Cfg.NoDriverSeconds) or 3)
end

------------------------------------------------------------------------------------------ lifecycle

function DriveController:Init(all: { [string]: any })
	controllers = all
end

function DriveController:Start()
	ui = build()
	local quietUntil = 0
	RunService.RenderStepped:Connect(function(dt: number)
		local ok, err = pcall(step, dt)
		if not ok and os.clock() > quietUntil then
			quietUntil = os.clock() + 5
			warn(`[Drive] {err}`)
		end
	end)
	player.CharacterRemoving:Connect(function()
		bindRider(false)
	end)
end

return DriveController
