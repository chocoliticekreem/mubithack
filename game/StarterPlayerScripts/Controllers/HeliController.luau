--!strict
-- HeliController [owner: Heli]. The FIRE HELICOPTER on the client (server: HeliService; numbers:
-- Config/HeliConfig; maths: Lib/Heli/HeliRules).
--   * Every heli nearby (tag "Heli"): spinning main + tail rotors (Motor6D Transform, local only), the
--     bucket hangs on its rope and rests on the ground when landed (BucketMotor), sways with speed, shows
--     water when attr Fill >= 0.5. Heli/Fx: the big DROP (pour + splash ring + spray + sound + screen
--     shake near it) and the FILL dip (small splash).
--   * Prompts: "Hop in" on a heli reads Fly (yours) / Ride (a friend's); the helipad kiosk reads
--     "Fly the helicopter" for owners and "GET THE HELICOPTER" for everyone else (the server opens the
--     store for them).
--   * Pilot (your own heli's PilotSeat, State "flying"): no auto-pilot, arcade flight. You own the
--     physics; every frame the stick / WASD (camera-relative), UP / DOWN and HeliRules.velocity set the
--     LinearVelocity, and AlignOrientation keeps it level (lean only for looks: it can't flip).
--     Keys: WASD / left stick move, mouse / right stick look, SPACE / R2 or A up, Q or SHIFT / L2
--     down, CLICK or G / X or R1 DROP, F / B out (safe auto-land). Touch: Roblox's thumbstick + UP (the
--     jump spot), DROP (big), DOWN, OUT. The camera follows the heli (Custom camera, zoomed out).
--   * Riders: F / SPACE / B / OUT hops out (onto the ground beside it).
--   * HUD while flying: bucket meter + what to do now; a key strip on PC / gamepad.
--   * On foot, owners: a round SUMMON HELI button on the right (U): Heli/Summon.
-- Test hooks (execute_luau on the Client): _input(mx, mz, up) (fake stick, nil clears), _drop(), _exit(),
--   _summon(), _debug() -> JSON
local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript)
local InputHints = require(ClientLib:WaitForChild("InputHints") :: ModuleScript) :: any
local ThumbLayout = require(ClientLib:WaitForChild("ThumbLayout") :: ModuleScript)
local Calm = require(ClientLib:WaitForChild("Calm") :: ModuleScript) :: any
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigFolder:WaitForChild("HeliConfig") :: ModuleScript) :: any
local MonCfg = require(ConfigFolder:WaitForChild("MonetizationConfig") :: ModuleScript) :: any
local HeliLib = ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Heli")
local Rules = require(HeliLib:WaitForChild("HeliRules") :: ModuleScript)
local Builder = require(HeliLib:WaitForChild("HeliBuilder") :: ModuleScript)
local Loc = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Loc") :: ModuleScript) :: any

local HeliController = {}
HeliController.Priority = 62

local player = Players.LocalPlayer
local controllers: { [string]: any } = {}

local ACTIONS = { "HeliUp", "HeliDown", "HeliDrop", "HeliExit" }

local mode: string? = nil -- "pilot" | "rider" | nil
local current: Model? = nil
local upHeld, downHeld = false, false
local trigUp, trigDown = 0, 0
local yaw = 0
local cmd = Vector3.zero -- the velocity we asked for last frame (smoothed from this, not from the physics:
-- sitting on the pad, contact would otherwise keep the measured speed at 0 and the heli never lifts)
local fakeInput: { mx: number, mz: number, up: number }? = nil
local jumpHiddenOn: Humanoid? = nil
local savedZoom: { min: number, max: number }? = nil
local savedSubject: Instance? = nil
local controls: any = nil

-- HUD
local hud: ScreenGui? = nil
local meter: Frame? = nil
local meterFill: Frame? = nil
local meterText: TextLabel? = nil
local keyStrip: TextLabel? = nil
local summonBtn: TextButton? = nil

-- shake
local shakeT, shakeMag = 0, 0
local lastShake = CFrame.identity

local spin: { [Model]: { rotor: number, tail: number, speed: number, sway: Vector3 } } = {}

local function owns(): boolean
	return player:GetAttribute(MonCfg.Attr.PassPrefix .. Cfg.PassKey) == true
end

local function humanoid(): Humanoid?
	local c = player.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function getControls(): any
	if controls then
		return controls
	end
	local ok, pm = pcall(function()
		return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 5) :: ModuleScript) :: any
	end)
	if ok and pm then
		controls = pm:GetControls()
	end
	return controls
end

local function rayParams(m: Model?): RaycastParams
	local ignore: { Instance } = {}
	local f = Workspace:FindFirstChild("Helis")
	if f then
		table.insert(ignore, f)
	elseif m then
		table.insert(ignore, m)
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = ignore
	rp.RespectCanCollide = true
	return rp
end

local function clearanceOf(root: BasePart, rp: RaycastParams): number
	local hit = Workspace:Raycast(root.Position, Vector3.new(0, -300, 0), rp)
	if not hit then
		return math.huge
	end
	return root.Position.Y - hit.Position.Y - Builder.SkidDepth
end

------------------------------------------------------------------------------------------- input

local function onAction(name: string, state: Enum.UserInputState, input: InputObject?): Enum.ContextActionResult
	local down = state == Enum.UserInputState.Begin or state == Enum.UserInputState.Change
	-- triggers are analog: Change carries Position.Z
	if input and (input.KeyCode == Enum.KeyCode.ButtonR2 or input.KeyCode == Enum.KeyCode.ButtonL2) then
		local z = if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then 0 else input.Position.Z
		if name == "HeliUp" then
			trigUp = z
		elseif name == "HeliDown" then
			trigDown = z
		end
		return Enum.ContextActionResult.Sink
	end
	if name == "HeliUp" then
		upHeld = down
	elseif name == "HeliDown" then
		downHeld = down
	elseif name == "HeliDrop" then
		if state == Enum.UserInputState.Begin and mode == "pilot" then
			Net.event("Heli", "Drop"):FireServer()
		end
	elseif name == "HeliExit" then
		if state == Enum.UserInputState.Begin then
			Net.event("Heli", "Exit"):FireServer()
		end
	end
	return Enum.ContextActionResult.Sink
end

local function keysOf(list: any, pad: any): { Enum.KeyCode }
	local out = {}
	for _, k in list or {} do
		table.insert(out, k)
	end
	for _, k in pad or {} do
		table.insert(out, k)
	end
	return out
end

local function bindPilot()
	local high = Enum.ContextActionPriority.High.Value + 10
	ContextActionService:BindActionAtPriority("HeliUp", onAction, true, high, table.unpack(keysOf(Cfg.KeyUp, Cfg.PadUp)))
	ContextActionService:BindActionAtPriority("HeliDown", onAction, true, high, table.unpack(keysOf(Cfg.KeyDown, Cfg.PadDown)))
	ContextActionService:BindActionAtPriority("HeliDrop", onAction, true, high, table.unpack(keysOf(Cfg.KeyDrop, Cfg.PadDrop)))
	ContextActionService:BindActionAtPriority("HeliExit", onAction, true, high, table.unpack(keysOf(Cfg.KeyExit, Cfg.PadExit)))
	ContextActionService:SetTitle("HeliUp", Loc.t("UP"))
	ContextActionService:SetTitle("HeliDown", Loc.t("DOWN"))
	ContextActionService:SetTitle("HeliDrop", Loc.t("DROP"))
	ContextActionService:SetTitle("HeliExit", Loc.t("OUT"))
	ThumbLayout.place("HeliUp", "jump", onAction)
	ThumbLayout.place("HeliDrop", "primary", onAction)
	ThumbLayout.place("HeliDown", "left", onAction)
	ThumbLayout.place("HeliExit", "above", onAction)
end

local function bindRider()
	local high = Enum.ContextActionPriority.High.Value + 10
	local keys = keysOf(Cfg.KeyExit, Cfg.PadExit)
	table.insert(keys, Enum.KeyCode.Space)
	table.insert(keys, Enum.KeyCode.ButtonA)
	ContextActionService:BindActionAtPriority("HeliExit", onAction, true, high, table.unpack(keys))
	ContextActionService:SetTitle("HeliExit", Loc.t("OUT"))
	ThumbLayout.place("HeliExit", "jump", onAction)
end

local function unbindAll()
	for _, a in ACTIONS do
		ThumbLayout.forget(a)
		pcall(function()
			ContextActionService:UnbindAction(a)
		end)
	end
	upHeld, downHeld, trigUp, trigDown = false, false, 0, 0
end

------------------------------------------------------------------------------------------- HUD

local function buildHud()
	local g = UiKit.screen("HeliHud", 8)
	hud = g
	local f = UiKit.panel(g, "Bucket", UDim2.fromOffset(340, 64), UDim2.new(1, -12, 0, 168), Vector2.new(1, 0)) -- under the minimap: clear of the thumb buttons
	f.Visible = false
	meter = f
	local icon = UiKit.label(f, "Icon", "💧", UDim2.fromOffset(50, 50), UDim2.fromOffset(8, 7), { textSize = 34 })
	icon.ZIndex = 3
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.Size = UDim2.new(1, -78, 0, 20)
	bar.Position = UDim2.fromOffset(64, 8)
	bar.BackgroundColor3 = Palette.UiPanelDark
	bar.BorderSizePixel = 0
	bar.Parent = f
	UiKit.corner(bar, 10)
	UiKit.stroke(bar, 2, Palette.UiInk)
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Palette.UiWater
	fill.BorderSizePixel = 0
	fill.Parent = bar
	UiKit.corner(fill, 10)
	meterFill = fill
	meterText = UiKit.label(f, "Text", "", UDim2.new(1, -72, 0, 26), UDim2.fromOffset(64, 32), {
		font = UiKit.Header,
		textSize = 18,
		color = Palette.UiInk,
		align = Enum.TextXAlignment.Left,
	})
	local strip = UiKit.label(g, "Keys", "", UDim2.fromOffset(720, 26), UDim2.new(0.5, -360, 1, -82), {
		font = UiKit.Body,
		textSize = 18,
		color = Palette.UiCream,
		stroke = true,
	})
	strip.Visible = false
	keyStrip = strip

	-- SUMMON HELI (owners, on foot): right edge, above the thumb cluster
	local b = Instance.new("TextButton")
	b.Name = "SummonHeli"
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.new(1, -12, 0.42, 0)
	b.Size = UDim2.fromOffset(76, 76)
	b.BackgroundColor3 = Palette.UiRed
	b.Text = ""
	b.AutoButtonColor = true
	b.Visible = false
	b.Parent = g
	UiKit.corner(b, 38)
	UiKit.stroke(b, 3, Palette.UiInk)
	UiKit.label(b, "Glyph", "🚁", UDim2.fromScale(1, 0.62), UDim2.fromScale(0, 0.04), { textSize = 36 })
	local lab = UiKit.label(b, "Label", "", UDim2.new(1, 8, 0, 20), UDim2.new(0, -4, 1, -24), {
		font = UiKit.Header,
		textSize = 15,
		color = Palette.UiCream,
		stroke = true,
	})
	InputHints.setChip(lab, Cfg.KeySummon.Name, "HELI")
	UiKit.onTap(b, function()
		Net.event("Heli", "Summon"):FireServer()
		UiKit.punch(b, 0.1)
	end)
	summonBtn = b
end

local function inMission(): boolean
	local iid = player:GetAttribute("InstanceId")
	return type(iid) == "string" and iid ~= ""
end

local function syncSummon()
	local b = summonBtn
	if not b then
		return
	end
	local hum = humanoid()
	b.Visible = owns() and mode == nil and hum ~= nil and hum.Health > 0 and hum.SeatPart == nil
end

local function syncMeter()
	local f, fill, txt = meter, meterFill, meterText
	if not f or not fill or not txt then
		return
	end
	local m = current
	if mode ~= "pilot" or not m then
		f.Visible = false
		return
	end
	f.Visible = true
	local amount = tonumber(m:GetAttribute("Fill")) or 0
	fill.Size = UDim2.fromScale(math.clamp(amount, 0, 1), 1)
	local wait = (tonumber(m:GetAttribute("NextDrop")) or 0) - Workspace:GetServerTimeNow()
	local state = m:GetAttribute("State")
	if state == "landing" then
		txt.Text = "LANDING..."
	elseif amount >= 1 and wait > 0 then
		txt.Text = Loc.t("READY IN {1}", { math.ceil(wait) })
		fill.BackgroundColor3 = Palette.UiWater
	elseif amount >= 1 then
		txt.Text = "FULL! Fly over a fire and DROP"
		fill.BackgroundColor3 = Palette.UiGood
	elseif amount > 0 then
		txt.Text = "FILLING..."
		fill.BackgroundColor3 = Palette.UiWater
	else
		txt.Text = "EMPTY: fly low over water"
		fill.BackgroundColor3 = Palette.UiWater
	end
end

local function syncKeys()
	local k = keyStrip
	if not k then
		return
	end
	if mode == "pilot" then
		k.Visible = not InputHints.isTouch()
		k.Text = InputHints.pick(
			"WASD fly · SPACE up · Q down · CLICK drop · F out",
			"",
			"Stick fly · R2 up · L2 down · X drop · B out"
		)
	elseif mode == "rider" then
		k.Visible = not InputHints.isTouch()
		k.Text = InputHints.pick("F hop out", "", "B hop out")
	else
		k.Visible = false
	end
end

------------------------------------------------------------------------------------------- flight

-- the "Hop in" prompt of the heli you sit in is hidden for you (no sticker / outline while flying)
local function boardPrompt(m: Model, on: boolean)
	local root = m.PrimaryPart
	local att = root and root:FindFirstChild("HopInAtt")
	local pr = att and att:FindFirstChild("HeliBoard") :: ProximityPrompt?
	if pr then
		pr.Enabled = on
	end
end

local function enter(m: Model, seat: Seat)
	current = m
	boardPrompt(m, false)
	mode = if seat.Name == "PilotSeat" then "pilot" else "rider"
	local hum = humanoid()
	if hum then
		hum:UnequipTools()
		if hum:GetStateEnabled(Enum.HumanoidStateType.Jumping) then
			hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false) -- SPACE / A / the jump button never drop you out
			jumpHiddenOn = hum
		end
	end
	local FP = controllers.FirstPersonController
	if FP and type(FP.SetEnabled) == "function" then
		pcall(FP.SetEnabled, FP, false)
	end
	local root = m.PrimaryPart
	local cam = Workspace.CurrentCamera
	if cam and root then
		savedSubject = cam.CameraSubject
		cam.CameraSubject = root
		savedZoom = { min = player.CameraMinZoomDistance, max = player.CameraMaxZoomDistance }
		player.CameraMaxZoomDistance = math.max(player.CameraMaxZoomDistance, Cfg.CamMaxZoom)
		player.CameraMinZoomDistance = Cfg.CamMinZoom
	end
	cmd = Vector3.zero
	if root then
		local _, y, _ = root.CFrame:ToEulerAnglesYXZ()
		yaw = y
	end
	if mode == "pilot" then
		bindPilot()
	else
		bindRider()
	end
	syncKeys()
	syncSummon()
end

local function leave()
	if not mode then
		return
	end
	mode = nil
	if current and current.Parent then
		boardPrompt(current, true)
	end
	current = nil
	unbindAll()
	if jumpHiddenOn then
		if jumpHiddenOn.Parent then
			jumpHiddenOn:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		end
		jumpHiddenOn = nil
	end
	local cam = Workspace.CurrentCamera
	if cam then
		local hum = humanoid()
		cam.CameraSubject = if savedSubject and savedSubject.Parent then savedSubject else hum
	end
	if savedZoom then
		player.CameraMinZoomDistance = savedZoom.min
		player.CameraMaxZoomDistance = savedZoom.max
		savedZoom = nil
	end
	local FP = controllers.FirstPersonController
	if FP and type(FP.SetEnabled) == "function" then
		pcall(FP.SetEnabled, FP, true)
	end
	syncKeys()
	syncMeter()
	syncSummon()
end

local function onSeat()
	local hum = humanoid()
	local seat = hum and hum.SeatPart
	local m = seat and seat.Parent
	if seat and seat:IsA("Seat") and m and m:IsA("Model") and CollectionService:HasTag(m, "Heli") then
		if current ~= m or mode ~= (if seat.Name == "PilotSeat" then "pilot" else "rider") then
			leave()
			enter(m, seat)
		end
	else
		leave()
	end
end

local function fly(dt: number)
	local m = current
	if mode ~= "pilot" or not m or m:GetAttribute("State") ~= "flying" then
		return
	end
	local root = m.PrimaryPart
	if not root or root.Anchored then
		return
	end
	local mv = root:FindFirstChild("Move") :: LinearVelocity?
	local ao = root:FindFirstChild("Level") :: AlignOrientation?
	if not mv or not ao then
		return
	end
	-- stick / WASD, camera-relative on the flat
	local mx, mz, up = 0, 0, 0
	local fi = fakeInput
	local cam = Workspace.CurrentCamera
	if fi then
		mx, mz, up = fi.mx, fi.mz, fi.up
	else
		local c = getControls()
		local raw = if c then c:GetMoveVector() else Vector3.zero
		local look = if cam then cam.CFrame.LookVector else Vector3.new(0, 0, -1)
		local flat = Vector3.new(look.X, 0, look.Z)
		flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
		local right = Vector3.new(-flat.Z, 0, flat.X)
		local w = right * raw.X + flat * -raw.Z
		mx, mz = w.X, w.Z
		local u = (if upHeld then 1 else 0) + trigUp
		local d = (if downHeld then 1 else 0) + trigDown
		up = math.clamp(u - d, -1, 1)
	end
	local rp = rayParams(m)
	local clear = clearanceOf(root, rp)
	local vel = cmd
	-- something solid just ahead (a wall, a tower): stop pushing and hop over it
	local blocked = false
	local dir = Vector3.new(mx, 0, mz)
	if dir.Magnitude > 0.1 then
		local probe = (tonumber(Cfg.ObstacleProbe) or 9) + Vector3.new(vel.X, 0, vel.Z).Magnitude * 0.25
		-- from the cabin's middle, smaller than the hull's height so the ground under the skids never counts
		local hit = Workspace:Spherecast(root.Position + Vector3.new(0, 1, 0), 3.2, dir.Unit * probe, rp)
		blocked = hit ~= nil and math.abs(hit.Normal.Y) < 0.6
	end
	local bmin = m:GetAttribute("BoundsMin")
	local bmax = m:GetAttribute("BoundsMax")
	local b = if typeof(bmin) == "Vector3" and typeof(bmax) == "Vector3"
		then { minX = bmin.X, maxX = bmax.X, minZ = bmin.Z, maxZ = bmax.Z }
		else nil
	local vx, vy, vz = Rules.velocity(
		{ mx = mx, mz = mz, up = up, touch = InputHints.isTouch() },
		{ vx = vel.X, vy = vel.Y, vz = vel.Z, dt = dt, x = root.Position.X, y = root.Position.Y, z = root.Position.Z, clearance = clear, blocked = blocked, bounds = b },
		Cfg
	)
	cmd = Vector3.new(vx, vy, vz)
	mv.VectorVelocity = cmd
	local newYaw = Rules.yawToward(yaw, vx, vz, dt, Cfg)
	local turn = (newYaw - yaw) / math.max(dt, 1e-3)
	yaw = newYaw
	-- lean: nose down with forward speed, bank into turns (looks only: AlignOrientation holds it)
	local fwd = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	local speed = (tonumber(Cfg.Speed) or 70)
	local f = Vector3.new(vx, 0, vz):Dot(fwd) / speed
	local pitch = -math.rad(tonumber(Cfg.TiltDegrees) or 14) * math.clamp(f, -1, 1)
	local roll = -math.rad(tonumber(Cfg.BankDegrees) or 10) * math.clamp(turn / 1.5, -1, 1)
	ao.CFrame = CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, roll)
end

------------------------------------------------------------------------------------------- visuals

local function animate(dt: number)
	local cam = Workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else Vector3.zero
	local rp: RaycastParams? = nil
	for _, m in CollectionService:GetTagged("Heli") do
		if not m:IsA("Model") or not m.Parent then
			continue
		end
		local root = m.PrimaryPart
		if not root or (root.Position - camPos).Magnitude > 600 then
			continue
		end
		local s = spin[m]
		if not s then
			s = { rotor = 0, tail = 0, speed = 0, sway = Vector3.zero }
			spin[m] = s
			m.Destroying:Connect(function()
				spin[m] = nil
			end)
		end
		local st = m:GetAttribute("State")
		local target = if st == "parked" and m:GetAttribute("Pilot") == 0 then 0 else 1
		s.speed += (target - s.speed) * math.min(1, dt * (if target > s.speed then 1.2 else 0.5))
		local rate = (tonumber(Cfg.RotorRpm) or 360) / 60 * math.pi * 2
		s.rotor = (s.rotor + rate * s.speed * dt) % (math.pi * 2)
		s.tail = (s.tail + rate * 1.6 * s.speed * dt) % (math.pi * 2)
		local rm = root:FindFirstChild("RotorMotor") :: Motor6D?
		if rm then
			rm.Transform = CFrame.Angles(0, s.rotor, 0)
		end
		local tm = root:FindFirstChild("TailMotor") :: Motor6D?
		if tm then
			tm.Transform = CFrame.Angles(s.tail, 0, 0)
		end
		-- bucket: hangs on the rope, rests on the ground when low; sways against the motion
		local bm = root:FindFirstChild("BucketMotor") :: Motor6D?
		if bm then
			rp = rp or rayParams(nil)
			local clear = clearanceOf(root, rp :: RaycastParams)
			local drop = Rules.ropeDrop(clear + Builder.SkidDepth + Builder.BellyY, Cfg)
			local lift = (tonumber(Cfg.RopeLength) or 11) - drop
			local v = root.AssemblyLinearVelocity
			local local_ = root.CFrame:VectorToObjectSpace(Vector3.new(v.X, 0, v.Z))
			local want = Vector3.new(-local_.X, 0, -local_.Z) * 0.04
			want = if want.Magnitude > 2.5 then want.Unit * 2.5 else want
			if drop < 3 then
				want = Vector3.zero
			end
			s.sway = s.sway:Lerp(want, math.min(1, dt * 3))
			-- tilt-independent: undo the body's lean so the bucket hangs straight down
			local rx, _, rz = root.CFrame:ToEulerAnglesXYZ()
			local hang = CFrame.Angles(-rx * 0.8, 0, -rz * 0.8)
			bm.Transform = CFrame.new(s.sway.X, lift, s.sway.Z) * hang
		end
		local water = m:FindFirstChild("BucketWater") :: BasePart?
		if water then
			local full = (tonumber(m:GetAttribute("Fill")) or 0) >= 0.5
			water.Transparency = if full then 0.1 else 1
		end
	end
	-- the pilot's meter
	syncMeter()
end

local function shakeStep()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if shakeT > 0 then
		local k = shakeMag * shakeT
		local t = os.clock() * 30
		lastShake = CFrame.Angles(math.noise(t, 1) * k * 0.06, math.noise(t, 7) * k * 0.06, math.noise(t, 13) * k * 0.04)
		cam.CFrame = cam.CFrame * lastShake
	else
		lastShake = CFrame.identity
	end
end

local function unshake()
	local cam = Workspace.CurrentCamera
	if cam and lastShake ~= CFrame.identity then
		cam.CFrame = cam.CFrame * lastShake:Inverse()
		lastShake = CFrame.identity
	end
end

local function sound(id: string, at: Vector3, volume: number)
	if id == "" then
		return
	end
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.one
	p.Position = at
	p.Parent = Workspace
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.RollOffMaxDistance = 220
	s.RollOffMinDistance = 20
	s.Parent = p
	s:Play()
	game:GetService("Debris"):AddItem(p, 4)
end

local function splashFx(ground: Vector3, big: boolean)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(1, 1, 1)
	p.CFrame = CFrame.new(ground + Vector3.new(0, 0.5, 0))
	p.Parent = Workspace
	local radius = tonumber(Cfg.DropRadius) or 18
	local ring = Instance.new("ParticleEmitter")
	ring.Texture = "rbxasset://textures/particles/smoke_main.dds"
	ring.Color = ColorSequence.new(Color3.fromHex("#DDF6FF"), Palette.UiWater)
	ring.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, if big then 9 else 3) })
	ring.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 1) })
	ring.Lifetime = NumberRange.new(0.7, 1.3)
	ring.Speed = NumberRange.new(if big then radius * 1.4 else 8, if big then radius * 2 else 14)
	ring.SpreadAngle = Vector2.new(180, 8)
	ring.EmissionDirection = Enum.NormalId.Top
	ring.Acceleration = Vector3.new(0, -20, 0)
	ring.Drag = 2.5
	ring.Rate = 0
	ring.Parent = p
	local spray = Instance.new("ParticleEmitter")
	spray.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	spray.Color = ColorSequence.new(Palette.UiWater)
	spray.LightEmission = 0.4
	spray.Size = NumberSequence.new(if big then 1.6 else 0.8)
	spray.Lifetime = NumberRange.new(0.8, 1.4)
	spray.Speed = NumberRange.new(if big then 30 else 12, if big then 55 else 20)
	spray.SpreadAngle = Vector2.new(40, 40)
	spray.EmissionDirection = Enum.NormalId.Top
	spray.Acceleration = Vector3.new(0, -80, 0)
	spray.Rate = 0
	spray.Parent = p
	ring:Emit(if big then 70 else 14)
	spray:Emit(if big then 90 else 20)
	game:GetService("Debris"):AddItem(p, 3)
end

local function onFx(kind: any, m: any, pos: any, hits: any)
	if typeof(pos) ~= "Vector3" then
		return
	end
	if kind == "drop" then
		local bucket = typeof(m) == "Instance" and (m :: Instance):FindFirstChild("Bucket")
		local pour = bucket and bucket:FindFirstChild("Pour") :: ParticleEmitter?
		if pour then
			pour:Emit(140)
		end
		task.delay(0.35, function()
			splashFx(pos, true)
			sound(Cfg.SplashSoundId, pos, 1.4)
			local cam = Workspace.CurrentCamera
			local d = if cam then (cam.CFrame.Position - pos).Magnitude else math.huge
			local r = tonumber(Cfg.ShakeRadius) or 70
			if d < r then
				shakeMag = Calm.fx(1 - d / r * 0.6)
				shakeT = 1
			end
		end)
	elseif kind == "fill" then
		splashFx(pos, false)
		sound(Cfg.FillSoundId, pos, 0.9)
	end
end

------------------------------------------------------------------------------------------- prompts

local function labelPrompt(prompt: ProximityPrompt)
	if prompt.Name == "HeliBoard" then
		local ownerId = prompt:GetAttribute("HeliOwner")
		prompt.ActionText = if ownerId == player.UserId then "Fly" else "Ride"
	elseif prompt.Name == "HeliPadPrompt" then
		prompt.ActionText = if owns() then "Fly the helicopter" else "GET THE HELICOPTER"
	end
end

------------------------------------------------------------------------------------------- lifecycle

function HeliController:Init(all: { [string]: any })
	controllers = all
end

function HeliController:Start()
	buildHud()
	Net.event("Heli", "Fx").OnClientEvent:Connect(onFx)

	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		labelPrompt(prompt)
	end)
	player:GetAttributeChangedSignal(MonCfg.Attr.PassPrefix .. Cfg.PassKey):Connect(syncSummon)
	player:GetAttributeChangedSignal("InstanceId"):Connect(syncSummon)

	local function hookChar(char: Model)
		local hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
		if not hum then
			return
		end
		leave()
		jumpHiddenOn = nil
		hum:GetPropertyChangedSignal("SeatPart"):Connect(onSeat)
		hum.Died:Connect(function()
			leave()
			syncSummon()
		end)
		onSeat()
		syncSummon()
	end
	player.CharacterAdded:Connect(hookChar)
	if player.Character then
		task.spawn(hookChar, player.Character)
	end
	InputHints.onChanged(function()
		syncKeys()
	end)

	-- PC: H summons (on foot); a free mouse click drops while flying
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == Cfg.KeySummon and mode == nil and owns() then
			Net.event("Heli", "Summon"):FireServer()
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 and mode == "pilot" then
			Net.event("Heli", "Drop"):FireServer()
		end
	end)

	RunService.PreSimulation:Connect(function(dt: number)
		local ok, err = pcall(fly, dt)
		if not ok then
			warn(`[HeliController] fly: {err}`)
		end
	end)
	RunService.Heartbeat:Connect(function(dt: number)
		if shakeT > 0 then
			shakeT = math.max(0, shakeT - dt / 0.5)
		end
		local ok, err = pcall(animate, dt)
		if not ok then
			warn(`[HeliController] animate: {err}`)
		end
	end)
	RunService:BindToRenderStep("HeliUnshake", Enum.RenderPriority.Camera.Value - 2, unshake)
	RunService:BindToRenderStep("HeliShake", Enum.RenderPriority.Camera.Value + 3, shakeStep)
	syncSummon()

	-- test hook (Studio MCP): Players.LocalPlayer.HeliTest:Invoke("input", mx, mz, up) / ("input") clears,
	-- ("drop"), ("exit"), ("summon"), ("debug") -> JSON
	if RunService:IsStudio() then
		local hook = Instance.new("BindableFunction")
		hook.Name = "HeliTest"
		hook.OnInvoke = function(cmd: string, a: any, b: any, c: any): any
			if cmd == "input" then
				HeliController:_input(a, b, c)
			elseif cmd == "drop" then
				HeliController:_drop()
			elseif cmd == "exit" then
				HeliController:_exit()
			elseif cmd == "summon" then
				HeliController:_summon()
			end
			return HeliController:_debug()
		end
		hook.Parent = player
	end
end

------------------------------------------------------------------------------------------ test hooks

function HeliController:_input(mx: number?, mz: number?, up: number?)
	if mx == nil then
		fakeInput = nil
	else
		fakeInput = { mx = mx or 0, mz = mz or 0, up = up or 0 }
	end
end

function HeliController:_drop()
	Net.event("Heli", "Drop"):FireServer()
end

function HeliController:_exit()
	Net.event("Heli", "Exit"):FireServer()
end

function HeliController:_summon()
	Net.event("Heli", "Summon"):FireServer()
end

function HeliController:_debug(): string
	local m = current
	local root = m and m.PrimaryPart
	return HttpService:JSONEncode({
		mode = mode,
		heli = m and m.Name,
		state = m and m:GetAttribute("State"),
		fill = m and m:GetAttribute("Fill"),
		pos = root and { math.floor(root.Position.X), math.floor(root.Position.Y), math.floor(root.Position.Z) },
		vel = root and math.floor(root.AssemblyLinearVelocity.Magnitude),
		summonVisible = summonBtn and summonBtn.Visible,
		meter = meterText and meterText.Text,
		keys = keyStrip and keyStrip.Text,
	})
end

return HeliController
