--!strict
-- CashInFx (client): cash-in popups, sounds, particles, HUD pulse, purchase confetti, spinning collector rings.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local CollectionService = game:GetService("CollectionService")

local localPlayer = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("CashInConfig", 10) :: ModuleScript) :: any

-- Sliding one-second window of popup timestamps
local stamps: { number } = {}
local function allowPopup(): boolean
	local now = os.clock()
	local kept: { number } = {}
	for _, t in stamps do
		if now - t < 1 then
			table.insert(kept, t)
		end
	end
	stamps = kept
	if #stamps >= Config.MAX_POPUPS_PER_SECOND then
		return false
	end
	table.insert(stamps, now)
	return true
end

local function makeAnchor(pos: Vector3, lifetime: number): Part
	local part = Instance.new("Part")
	part.Name = "FxAnchor"
	part.Size = Vector3.new(0.5, 0.5, 0.5)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CFrame = CFrame.new(pos)
	part.Parent = workspace
	Debris:AddItem(part, lifetime)
	return part
end

local function playSound(parent: Instance, id: string, speed: number, volume: number)
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.PlaybackSpeed = speed
	s.RollOffMaxDistance = 120
	s.Parent = parent
	s:Play()
	Debris:AddItem(s, 3)
end

local function pulseHud()
	local pg = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	local label = pg:FindFirstChild("CashLabel", true)
	if not label or not label:IsA("TextLabel") then
		return
	end
	local scale = label:FindFirstChild("CashPulse") :: UIScale?
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "CashPulse"
		scale.Parent = label
	end
	local sc = scale :: UIScale
	sc.Scale = 1
	local up = TweenService:Create(sc, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1.2 })
	up.Completed:Connect(function()
		TweenService:Create(sc, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end)
	up:Play()
end

local function sparkles(part: Part)
	local e = Instance.new("ParticleEmitter")
	e.Color = ColorSequence.new(Color3.fromRGB(255, 226, 90), Color3.fromRGB(255, 180, 40))
	e.LightEmission = 1
	e.Lifetime = NumberRange.new(0.5, 0.9)
	e.Speed = NumberRange.new(8, 16)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Acceleration = Vector3.new(0, -10, 0)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 0) })
	e.Rate = 0
	e.Enabled = false
	e.Parent = part
	e:Emit(15)
end

local function popupText(pos: Vector3, amount: number, color: Color3)
	local part = makeAnchor(pos + Vector3.new(0, 3, 0), 1.6)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(140, 50)
	gui.AlwaysOnTop = true
	gui.StudsOffsetWorldSpace = Vector3.zero
	gui.Adornee = part
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "+$" .. tostring(math.floor(amount + 0.5))
	label.TextScaled = true
	label.Font = Enum.Font.LuckiestGuy
	label.TextColor3 = color
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(28, 22, 38)
	stroke.Parent = label
	gui.Parent = part
	local info = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(gui, info, { StudsOffsetWorldSpace = Vector3.new(0, 5, 0) }):Play()
	TweenService:Create(label, info, { TextTransparency = 1 }):Play()
	TweenService:Create(stroke, info, { Transparency = 1 }):Play()
end

local function onCashIn(amount: any, tier: any, pos: any)
	if type(amount) ~= "number" or amount ~= amount or typeof(pos) ~= "Vector3" then
		return
	end
	if not allowPopup() then
		return
	end
	local anchor = makeAnchor(pos, 3)
	local vol: number = Config.CASHIN_VOLUME or 0.4
	playSound(anchor, Config.CASHIN_SOUND_ID, Config.pitchForTier(tier), vol)
	sparkles(anchor)
	popupText(pos, amount, Config.colorForTier(tier))
	pulseHud()
end

local function onPurchaseFx(pos: any)
	local target: Vector3? = nil
	if typeof(pos) == "Vector3" then
		target = pos
	else
		local char = localPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			target = hrp.Position
		end
	end
	if not target then
		return
	end
	if not allowPopup() then
		return
	end
	local anchor = makeAnchor(target, 3)
	local popVol: number = Config.POP_VOLUME or 0.5
	playSound(anchor, Config.POP_SOUND_ID, 1.1, popVol)
	local e = Instance.new("ParticleEmitter")
	e.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 90, 90)),
		ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 220, 60)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(90, 220, 110)),
		ColorSequenceKeypoint.new(0.75, Color3.fromRGB(80, 170, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 100, 255)),
	})
	e.LightEmission = 0.5
	e.Lifetime = NumberRange.new(0.7, 1.2)
	e.Speed = NumberRange.new(14, 28)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Acceleration = Vector3.new(0, -25, 0)
	e.RotSpeed = NumberRange.new(-200, 200)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0.2) })
	e.Rate = 0
	e.Enabled = false
	e.Parent = anchor
	e:Emit(30)
end

-- Ring spinning (client-local)
local rings: { [BasePart]: boolean } = {}
local function addRing(inst: Instance)
	if inst:IsA("BasePart") then
		rings[inst] = true
	end
end
for _, inst in CollectionService:GetTagged(Config.RING_TAG) do
	addRing(inst)
end
CollectionService:GetInstanceAddedSignal(Config.RING_TAG):Connect(addRing)
CollectionService:GetInstanceRemovedSignal(Config.RING_TAG):Connect(function(inst: Instance)
	if inst:IsA("BasePart") then
		rings[inst] = nil
	end
end)
RunService.RenderStepped:Connect(function(dt: number)
	local ang = math.rad(Config.RING_SPIN_DEG_PER_SEC) * dt
	for ring in rings do
		if ring.Parent then
			ring.CFrame = ring.CFrame * CFrame.Angles(0, ang, 0)
		else
			rings[ring] = nil
		end
	end
end)

-- Remotes
local function findRemote(folder: Instance?, name: string): RemoteEvent?
	local r = folder and folder:WaitForChild(name, 10)
	if r and r:IsA("RemoteEvent") then
		return r
	end
	local direct = ReplicatedStorage:FindFirstChild(name)
	if direct and direct:IsA("RemoteEvent") then
		return direct
	end
	return nil
end

task.spawn(function()
	local folder = ReplicatedStorage:WaitForChild("Remotes", 10)
	local cashIn = findRemote(folder, Config.CASHIN_REMOTE)
	if cashIn then
		cashIn.OnClientEvent:Connect(onCashIn)
	end
	local purchase = findRemote(folder, Config.PURCHASE_REMOTE)
	if purchase then
		purchase.OnClientEvent:Connect(onPurchaseFx)
	end
end)
