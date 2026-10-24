--!strict
-- RescueController [owner: G3]. Client feel for rescues; every outcome is decided by RescueService.
--   * While carrying (Player attr Carrying ~= ""): hint panel "[G] drop  [hold Q] YEET", a charge bar,
--     and the Truck highlighted. G sends Rescue/Drop; holding Q charges a throw, releasing sends
--     Rescue/Throw(cameraLook, charge). Touch / gamepad buttons via ContextActionService.
--   * Flailing: the Motor6D "Flail" joints of carried / flying NPCs wave wildly; NPCs with Moving run;
--     Mood "cower" flaps its arms over its head, "wave"/"approach" waves you over, Coughing jerks.
--   * Voices: screams / woofs / meows / panda grunts while carried or flying (RescueConfig.Sound*).
--   * Rescue/Fx: confetti + cheer on delivery, dust + thud + shake on landing, whoosh on a yeet,
--     black smoke + sizzle on a toasting. Shake goes through FirstPersonController:Shake (nil-guarded).
local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local InputHints = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("InputHints") :: ModuleScript) :: any
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local RescueConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("RescueConfig") :: ModuleScript)

local RescueController = {}
RescueController.Priority = 60

local player = Players.LocalPlayer
local controllers: { [string]: any } = {}

local CONFETTI = {
	Palette.UiRed,
	Palette.UiWarn,
	Palette.UiGood,
	Palette.UiWater,
	Palette.UiFlameMid,
	Palette.UiCream,
}

local VOICE: { [string]: string } = {
	Civilian = "SoundScream",
	Dog = "SoundWoof",
	Cat = "SoundMeow",
	Panda = "SoundPanda",
}

local function shake(magnitude: number, seconds: number)
	local fp = controllers.FirstPersonController
	if fp and type(fp.Shake) == "function" then
		pcall(fp.Shake, fp, magnitude, seconds)
	end
end

local function sound(key: string, parent: Instance, volume: number?, pitch: number?)
	local id = (RescueConfig :: any)[key]
	if type(id) ~= "string" or id == "" then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume or 0.8
	s.PlaybackSpeed = pitch or (0.9 + math.random() * 0.3)
	s.RollOffMaxDistance = 120
	s.Parent = parent
	s:Play()
	Debris:AddItem(s, 6)
end

-- A short-lived invisible anchor part at `pos` for particles and 3D sounds.
local function anchor(pos: Vector3, life: number): BasePart
	local p = Instance.new("Part")
	p.Name = "RescueFx"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.one
	p.CFrame = CFrame.new(pos)
	p.Parent = workspace
	Debris:AddItem(p, life)
	return p
end

local function burst(pos: Vector3, count: number, props: { [string]: any })
	local p = anchor(pos, 5)
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	for k, v in props do
		(e :: any)[k] = v
	end
	e.Parent = p
	e:Emit(count)
	return p
end

local function confetti(pos: Vector3)
	local keys = {}
	for i, c in CONFETTI do
		table.insert(keys, ColorSequenceKeypoint.new((i - 1) / (#CONFETTI - 1), c))
	end
	local p = burst(pos + Vector3.new(0, 2, 0), RescueConfig.Confetti, {
		Color = ColorSequence.new(keys),
		Size = NumberSequence.new(0.35),
		Lifetime = NumberRange.new(2, 3.2),
		Speed = NumberRange.new(28, 46),
		SpreadAngle = Vector2.new(55, 55),
		Acceleration = Vector3.new(0, -32, 0),
		Drag = 1.5,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-400, 400),
		LightEmission = 0.2,
		EmissionDirection = Enum.NormalId.Top,
	})
	sound("SoundCheer", p, 1, 1)
	-- (the big floating "SAVED!" is gone: RescueService sends one small "X rescued the dog!" popup
	-- over the NPC through Shared/Popup -> ClientLib/WorldPopup)
end

local function myRoot(): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function near(pos: Vector3, studs: number): number
	local root = myRoot()
	if not root then
		return 0
	end
	return math.clamp(1 - (root.Position - pos).Magnitude / studs, 0, 1)
end

local function onFx(kind: any, pos: any, data: any)
	if type(kind) ~= "string" or typeof(pos) ~= "Vector3" then
		return
	end
	local d = if type(data) == "table" then data else {}
	if kind == "delivered" then
		confetti(pos)
		local k = near(pos, 40)
		if k > 0 then
			shake(0.3 * k, 0.25)
		end
	elseif kind == "landed" then
		local hard = d.hard == true
		local p = burst(pos - Vector3.new(0, 1.5, 0), if hard then 28 else 12, {
			Color = ColorSequence.new(Palette.Sidewalk, Palette.SmokeGrey),
			Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 3) }),
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) }),
			Lifetime = NumberRange.new(0.6, 1.1),
			Speed = NumberRange.new(6, 14),
			SpreadAngle = Vector2.new(80, 80),
			Drag = 4,
			EmissionDirection = Enum.NormalId.Top,
		})
		sound("SoundThud", p, if hard then 1 else 0.6)
		local k = near(pos, if hard then 45 else 25)
		if k > 0 then
			shake((if hard then 1.1 else 0.4) * k, if hard then 0.4 else 0.2)
		end
	elseif kind == "yeet" then
		local p = anchor(pos, 3)
		sound("SoundWhoosh", p, 1)
		if d.by == player.UserId then
			shake(0.5, 0.2)
		end
	elseif kind == "toasted" then
		local p = burst(pos, 30, {
			Color = ColorSequence.new(Palette.SmokeBlack, Palette.SmokeGrey),
			Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 5) }),
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) }),
			Lifetime = NumberRange.new(1.2, 2.2),
			Speed = NumberRange.new(4, 10),
			SpreadAngle = Vector2.new(40, 40),
			Acceleration = Vector3.new(0, 6, 0),
			EmissionDirection = Enum.NormalId.Top,
		})
		sound("SoundSizzle", p, 1)
	end
end

-- Flail animation --------------------------------------------------------------------------------

type Rig = { motors: { Motor6D }, phase: { number }, arm: { boolean }, at: number, voiceAt: number, animated: boolean }
local rigs: { [Model]: Rig } = {}

local function rigOf(model: Model, now: number): Rig
	local rig = rigs[model]
	local stale = rig == nil or now - rig.at > 1
	if rig and not stale then
		for _, m in rig.motors do
			if not m.Parent then
				stale = true
				break
			end
		end
	end
	if stale then
		local motors: { Motor6D } = {}
		local phase: { number } = {}
		local arm: { boolean } = {}
		for _, d in model:GetDescendants() do
			if d:IsA("Motor6D") and d.Name == "Flail" then
				table.insert(motors, d)
				local limb = d.Part1
				local name = if limb then limb.Name else ""
				local idx = tonumber(string.match(name, "%d") or "") or 0
				local isArm = string.find(name, "Arm") ~= nil or string.find(name, "Sleeve") ~= nil or string.find(name, "FrontLeg") ~= nil
				-- left/right limbs swing in opposite phase; arms a quarter turn from the legs
				local p = (idx % 2) * math.pi + (if isArm then math.pi / 2 else 0)
				table.insert(phase, p)
				table.insert(arm, isArm)
			end
		end
		rig = {
			motors = motors,
			phase = phase,
			arm = arm,
			at = now,
			voiceAt = if rig then rig.voiceAt else now + math.random(),
			animated = if rig then rig.animated else false,
		}
		rigs[model] = rig
	end
	return rig :: Rig
end

local function animate(_t: number, _dt: number)
	local now = os.clock()
	local seen: { [Model]: boolean } = {}
	for _, inst in CollectionService:GetTagged(Names.Tag.Rescuable) do
		if not inst:IsA("Model") then
			continue
		end
		local model = inst :: Model
		seen[model] = true
		local state = model:GetAttribute(Names.Attr.RescueState)
		local flying = model:GetAttribute("Flying") == true
		local wild = state == "Carried" or flying
		local trapped = state == "Trapped"
		local mood = if trapped then model:GetAttribute("Mood") else nil
		local moving = trapped and model:GetAttribute("Moving") == true
		local coughAt = model:GetAttribute("Coughing")
		local coughing = trapped and type(coughAt) == "number" and workspace:GetServerTimeNow() - coughAt < 0.9
		local rig = rigOf(model, now)
		if wild or moving then
			-- carried/flying: flail everything; running: legs and arms pump (zoomies faster)
			local zoom = mood == "zoom"
			local speed = if wild then 22 elseif zoom then 20 else 13
			local amp = if wild then math.rad(70) elseif zoom then math.rad(55) else math.rad(40)
			for i, m in rig.motors do
				local a = math.sin(now * speed + rig.phase[i]) * amp
				local b = if wild then math.cos(now * speed * 0.7 + rig.phase[i]) * amp * 0.5 else 0
				m.Transform = CFrame.Angles(a, 0, b)
			end
			rig.animated = true
		elseif mood == "cower" or mood == "wave" or mood == "approach" or coughing then
			-- cower: arms flap wildly over the head, legs tucked; wave: arms swing "over here!";
			-- cough: everything jerks
			for i, m in rig.motors do
				if coughing then
					m.Transform = CFrame.Angles(math.sin(now * 35 + rig.phase[i]) * math.rad(14), 0, 0)
				elseif rig.arm[i] then
					local fast = mood == "cower"
					local s = if fast then 16 else 9
					m.Transform = CFrame.Angles(math.rad(if fast then 150 else 120) + math.sin(now * s + rig.phase[i]) * math.rad(35), 0, math.cos(now * s + rig.phase[i]) * math.rad(25))
				else
					m.Transform = if mood == "cower" then CFrame.Angles(math.rad(-25), 0, 0) else CFrame.identity
				end
			end
			rig.animated = true
			if wild and now >= rig.voiceAt then
				rig.voiceAt = now + RescueConfig.VoiceInterval * (0.7 + math.random() * 0.6)
				local root = model.PrimaryPart
				local kind = tostring(model:GetAttribute(Names.Attr.Kind) or "Civilian")
				if root then
					sound(VOICE[kind] or "SoundScream", root, 0.9)
				end
			end
		elseif rig.animated then
			for _, m in rig.motors do
				m.Transform = CFrame.identity
			end
			rig.animated = false
		end
	end
	for model in rigs do
		if not seen[model] then
			rigs[model] = nil
		end
	end
end

-- Carry HUD + input ----------------------------------------------------------------------------

local function kindOf(rescueId: string): string
	for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
		if m:GetAttribute(Names.Attr.RescueId) == rescueId then
			return string.lower(tostring(m:GetAttribute(Names.Attr.Kind) or "civilian"))
		end
	end
	return "civilian"
end

local function carryingId(): string
	local v = player:GetAttribute(Names.Attr.Carrying)
	return if type(v) == "string" then v else ""
end

function RescueController:Init(all: { [string]: any })
	controllers = all
end

function RescueController:Start()
	local Fx = Net.event("Rescue", "Fx")
	Fx.OnClientEvent:Connect(onFx)
	RunService.Stepped:Connect(animate)

	local Drop = Net.event("Rescue", "Drop")
	local Throw = Net.event("Rescue", "Throw")

	-- UiKit.screen: the same viewport UIScale as the hotbar under it, so on a phone the slot shrinks with
	-- it instead of staying 360 px wide and running into the heat warning above
	local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript) :: any
	local gui = UiKit.screen("Carry", 2)

	local slot = Instance.new("Frame")
	slot.Name = "CarrySlot"
	slot.AnchorPoint = Vector2.new(0.5, 1)
	-- above the hotbar: its row is 72 + 22 + 4 tall at 1,-4 and the slot tags poke ~12 above it
	slot.Position = UDim2.new(0.5, 0, 1, -122)
	slot.Size = UDim2.fromOffset(360, 74)
	slot.BackgroundColor3 = Palette.UiPanelDark
	slot.BackgroundTransparency = 0.15
	slot.Visible = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = slot
	local border = Instance.new("UIStroke")
	border.Thickness = 3
	border.Color = Palette.UiInk
	border.Parent = slot
	local sizeLimit = Instance.new("UISizeConstraint")
	sizeLimit.MaxSize = Vector2.new(360, 74)
	sizeLimit.Parent = slot
	slot.Parent = gui
	local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript) :: any
	HudLayout.reserve(slot) -- world markers / edge arrows stay off it

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(12, 6)
	label.Size = UDim2.new(1, -24, 0, 44)
	label.Font = Enum.Font.LuckiestGuy
	label.TextScaled = true
	label.TextColor3 = Palette.UiCream
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.Text = ""
	label.Parent = slot

	local barBack = Instance.new("Frame")
	barBack.Name = "Charge"
	barBack.Position = UDim2.new(0, 12, 1, -18)
	barBack.Size = UDim2.new(1, -24, 0, 10)
	barBack.BackgroundColor3 = Palette.UiInk
	barBack.BorderSizePixel = 0
	barBack.Parent = slot
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Palette.UiFlameMid
	fill.BorderSizePixel = 0
	fill.Parent = barBack

	local highlight: Highlight? = nil
	local chargeStart: number? = nil
	local bound = false

	local function charge(): number
		if not chargeStart then
			return 0
		end
		return math.clamp((os.clock() - chargeStart) / RescueConfig.ThrowChargeTime, 0, 1)
	end

	local function onDrop(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
		if state == Enum.UserInputState.Begin and carryingId() ~= "" then
			Drop:FireServer()
		end
		return Enum.ContextActionResult.Sink
	end

	local function onThrow(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
		if carryingId() == "" then
			chargeStart = nil
			return Enum.ContextActionResult.Pass
		end
		if state == Enum.UserInputState.Begin then
			chargeStart = os.clock()
		elseif state == Enum.UserInputState.End and chargeStart then
			local c = charge()
			chargeStart = nil
			local cam = workspace.CurrentCamera
			local look = if cam then cam.CFrame.LookVector else Vector3.new(0, 0, -1)
			Throw:FireServer(look, c)
		elseif state == Enum.UserInputState.Cancel then
			chargeStart = nil
		end
		return Enum.ContextActionResult.Sink
	end

	local function refresh()
		local id = carryingId()
		local on = id ~= ""
		slot.Visible = on
		if on and not bound then
			ContextActionService:BindAction("RescueDrop", onDrop, true, Enum.KeyCode.G, Enum.KeyCode.ButtonB)
			ContextActionService:BindAction("RescueThrow", onThrow, true, Enum.KeyCode.Q, Enum.KeyCode.ButtonX)
			ContextActionService:SetTitle("RescueDrop", "DROP")
			ContextActionService:SetTitle("RescueThrow", "YEET")
			bound = true
		elseif not on and bound then
			ContextActionService:UnbindAction("RescueDrop")
			ContextActionService:UnbindAction("RescueThrow")
			bound = false
			chargeStart = nil
		end
		if on then
			-- HudController's carry slot already says what and where; this panel is the controls
			local kind = kindOf(id)
			local lol = if kind == "panda" then " (lol)" else ""
			InputHints.setPick(label, `[G] DROP   [hold Q] YEET{lol}`, `Tap DROP   ·   hold YEET{lol}`, `[B] DROP   [hold X] YEET{lol}`)
			slot.Size = UDim2.fromOffset(330, 66)
			TweenService:Create(slot, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				Size = UDim2.fromOffset(360, 74),
			}):Play()
			local truck = CollectionService:GetTagged(Names.Tag.Truck)[1]
			if truck and not highlight then
				local h = Instance.new("Highlight")
				h.FillTransparency = 0.8
				h.FillColor = Palette.UiGood
				h.OutlineColor = Palette.UiGood
				h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				h.Adornee = truck
				h.Parent = gui
				highlight = h
			end
		elseif highlight then
			highlight:Destroy()
			highlight = nil
		end
	end

	player:GetAttributeChangedSignal(Names.Attr.Carrying):Connect(refresh)
	refresh()

	RunService.RenderStepped:Connect(function()
		if not slot.Visible then
			return
		end
		local c = charge()
		fill.Size = UDim2.fromScale(c, 1)
		fill.BackgroundColor3 = if c >= 1 then Palette.UiRed else Palette.UiFlameMid
		-- sit above InventoryController's hotbar: both guis share UiKit's viewport UIScale, so a fixed
		-- design offset holds on every screen (the hotbar row is 98 tall at 1,-4; its tags poke ~12 above)
		local baseY = -122
		if c >= 1 then
			-- full power: the panel trembles
			slot.Position = UDim2.new(0.5, math.random(-3, 3), 1, baseY + math.random(-2, 2))
		else
			slot.Position = UDim2.new(0.5, 0, 1, baseY)
		end
	end)
end

return RescueController
