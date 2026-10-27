--!strict
-- FanfareController [owner: Monetization]. Client side of FanfareService (Fanfare/Show): the big moment
-- when someone gets a game pass (bought or gifted) or donates.
--   * everyone: a full-width gold banner near the top ("🎁 ARVIN GIFTED BOB THE PREMIUM PASS!"), queued so
--     two never overlap; the Fanfare sting (AudioConfig.Sounds.Fanfare); a system chat line;
--     confetti + fireworks around the receiver and a gold glow (Highlight + light) on them for glowSeconds.
--   * the receiver: a card that says what they got and what it does, with a big OK button (touch friendly).
-- Calm mode (ClientLib/Calm, the effects setting) keeps the banner and the card, with far fewer particles
-- and one firework instead of five.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local AudioConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("AudioConfig") :: ModuleScript) :: any
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript)
local Calm = require(ClientLib:WaitForChild("Calm") :: ModuleScript) :: any
local HudLayout = require(ClientLib:WaitForChild("HudLayout") :: ModuleScript) :: any
local PopupGate = require(ClientLib:WaitForChild("PopupGate") :: ModuleScript) :: any

local FanfareController = {}
FanfareController.Priority = 140

local player = Players.LocalPlayer
local BANNER_SECONDS = 5
local GOLD = Color3.fromHex("#FFC531")
local COLORS = {
	Color3.fromHex("#E8412C"), GOLD, Color3.fromHex("#4FB3D9"), Color3.fromHex("#6CC24A"),
	Color3.fromHex("#FF7AB6"), Color3.fromHex("#B07CFF"),
}

type Payload = {
	kind: string,
	receiverUserId: number,
	banner: string,
	sub: string,
	chat: string,
	title: string,
	body: string,
	glowSeconds: number,
}

local gui: ScreenGui? = nil
local banner: Frame? = nil
local bannerText: TextLabel? = nil
local bannerSub: TextLabel? = nil
local card: Frame? = nil
local cardTitle: TextLabel? = nil
local cardBody: TextLabel? = nil
local queue: { Payload } = {}
local showing = false
local shownCount = 0

---------------------------------------------------------------------------------------------- ui

local function build()
	local g = UiKit.screen("FanfareGui", 60)
	gui = g

	local b = Instance.new("Frame")
	b.Name = "Banner"
	b.AnchorPoint = Vector2.new(0.5, 0)
	b.Position = UDim2.new(0.5, 0, 0, -140)
	b.Size = UDim2.new(1, 0, 0, 104)
	b.BackgroundColor3 = GOLD
	b.BorderSizePixel = 0
	b.Visible = false
	b.ZIndex = 30
	b.Parent = g
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromHex("#FF8A1F")),
		ColorSequenceKeypoint.new(0.5, Color3.fromHex("#FFE45C")),
		ColorSequenceKeypoint.new(1, Color3.fromHex("#FF8A1F")),
	})
	grad.Parent = b
	UiKit.stroke(b, 4, Palette.UiInk)
	local t = UiKit.label(b, "Text", "", UDim2.new(1, -40, 0, 60), UDim2.fromOffset(20, 8), {
		font = UiKit.Header,
		textSize = 44,
		color = Palette.UiCream,
		stroke = true,
		strokeThickness = 3,
	})
	t.TextScaled = true
	t.ZIndex = 31
	local s = UiKit.label(b, "Sub", "", UDim2.new(1, -40, 0, 26), UDim2.fromOffset(20, 70), {
		font = UiKit.Body,
		textSize = 22,
		color = Palette.UiInk,
	})
	s.ZIndex = 31
	banner, bannerText, bannerSub = b, t, s

	-- the receiver's card
	local c = UiKit.panel(g, "GiftCard", UDim2.fromOffset(520, 300), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	c.Visible = false
	c:SetAttribute("Menu", true)
	local ct = UiKit.label(c, "Title", "", UDim2.new(1, -32, 0, 56), UDim2.fromOffset(16, 14), {
		font = UiKit.Header,
		textSize = 44,
		color = Palette.UiRed,
	})
	local cb = UiKit.label(c, "Body", "", UDim2.new(1, -40, 0, 130), UDim2.fromOffset(20, 76), {
		font = UiKit.Body,
		textSize = 26,
		color = Palette.UiInk,
	})
	cb.TextWrapped = true
	local ok = UiKit.button(c, "Ok", "OK!", UDim2.fromOffset(220, 64), UDim2.new(0.5, 0, 1, -48), Palette.UiGood)
	ok.TextSize = 34
	card, cardTitle, cardBody = c, ct, cb
	local function close()
		c.Visible = false
	end
	HudLayout.modal(c, { dim = 0.5, onDismiss = close })
	UiKit.onTap(ok, close)
end

------------------------------------------------------------------------------------------- world

local function characterOf(userId: number): (Model?, BasePart?)
	local p = Players:GetPlayerByUserId(userId)
	local c = p and p.Character
	local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	return c, root
end

local function confetti(root: BasePart, count: number)
	local at = Instance.new("Attachment")
	at.Name = "FanfareConfetti"
	at.Position = Vector3.new(0, 3, 0)
	at.Parent = root
	for _, col in COLORS do
		local e = Instance.new("ParticleEmitter")
		e.Enabled = false
		e.Color = ColorSequence.new(col)
		e.Size = NumberSequence.new(0.35)
		e.Squash = NumberSequence.new(-0.6)
		e.Lifetime = NumberRange.new(2.2, 3.2)
		e.Speed = NumberRange.new(16, 28)
		e.SpreadAngle = Vector2.new(70, 70)
		e.Acceleration = Vector3.new(0, -22, 0)
		e.Drag = 1.2
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-300, 300)
		e.EmissionDirection = Enum.NormalId.Top
		e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		e.Parent = at
		e:Emit(math.max(1, math.floor(count / #COLORS)))
	end
	task.delay(4, function()
		at:Destroy()
	end)
end

local function firework(origin: Vector3, delay: number, sparks: number)
	task.delay(delay, function()
		local col = COLORS[math.random(1, #COLORS)]
		local rocket = Instance.new("Part")
		rocket.Name = "FanfareFirework"
		rocket.Shape = Enum.PartType.Ball
		rocket.Size = Vector3.one * 0.6
		rocket.Material = Enum.Material.Neon
		rocket.Color = col
		rocket.Anchored = true
		rocket.CanCollide = false
		rocket.CanQuery = false
		rocket.CanTouch = false
		local a = math.random() * math.pi * 2
		local start = origin + Vector3.new(math.cos(a) * 5, 0, math.sin(a) * 5)
		rocket.Position = start
		rocket.Parent = workspace
		local top = start + Vector3.new(0, 18 + math.random() * 8, 0)
		local tw = TweenService:Create(rocket, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = top })
		tw:Play()
		tw.Completed:Wait()
		rocket.Transparency = 1
		local e = Instance.new("ParticleEmitter")
		e.Enabled = false
		e.Color = ColorSequence.new(col, GOLD)
		e.LightEmission = 1
		e.Size = NumberSequence.new(0.5, 0)
		e.Lifetime = NumberRange.new(0.8, 1.3)
		e.Speed = NumberRange.new(14, 22)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Acceleration = Vector3.new(0, -10, 0)
		e.Drag = 1.5
		e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		e.Parent = rocket
		e:Emit(sparks)
		task.delay(2, function()
			rocket:Destroy()
		end)
	end)
end

local function glow(c: Model, root: BasePart, seconds: number)
	local old = c:FindFirstChild("FanfareGlow")
	if old then
		old:Destroy()
	end
	local h = Instance.new("Highlight")
	h.Name = "FanfareGlow"
	h.FillColor = GOLD
	h.FillTransparency = 0.55
	h.OutlineColor = Color3.fromHex("#FFE45C")
	h.OutlineTransparency = 0
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Adornee = c
	h.Parent = c
	local light = Instance.new("PointLight")
	light.Name = "FanfareLight"
	light.Color = GOLD
	light.Brightness = 3
	light.Range = 14
	light.Parent = root
	task.delay(seconds, function()
		h:Destroy()
		light:Destroy()
	end)
end

local function chatLine(text: string)
	pcall(function()
		local channels = TextChatService:FindFirstChild("TextChannels")
		local general = channels and (channels:FindFirstChild("RBXSystem") or channels:FindFirstChild("RBXGeneral"))
		if general and general:IsA("TextChannel") then
			general:DisplaySystemMessage(`<font color="#FFC531"><b>{text}</b></font>`)
		end
	end)
end

------------------------------------------------------------------------------------------- show

local function showBanner(p: Payload)
	local b, t, s = banner, bannerText, bannerSub
	if not (b and t and s) then
		return
	end
	t.Text = p.banner
	s.Text = p.sub
	b.Position = UDim2.new(0.5, 0, 0, -140)
	b.Visible = true
	TweenService:Create(b, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.new(0.5, 0, 0, 60) }):Play()
	if not Calm.on() then
		UiKit.punch(b, 0.06)
	end
	task.wait(BANNER_SECONDS)
	local out = TweenService:Create(b, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Position = UDim2.new(0.5, 0, 0, -140) })
	out:Play()
	out.Completed:Wait()
	b.Visible = false
end

local function showCard(p: Payload)
	local c, ct, cb = card, cardTitle, cardBody
	if not (c and ct and cb) then
		return
	end
	ct.Text = p.title
	cb.Text = p.body
	c.Visible = true
	UiKit.pop(c, 0.3)
end

local function run(p: Payload)
	shownCount += 1
	local calm = Calm.on()
	UiKit.sound(AudioConfig.Sounds.Fanfare and AudioConfig.Sounds.Fanfare.id, 0.7)
	chatLine(p.chat)
	local c, root = characterOf(p.receiverUserId)
	if c and root then
		confetti(root, if calm then 24 else 120)
		local n = if calm then 1 else 5
		for i = 1, n do
			firework(root.Position, (i - 1) * 0.35, if calm then 20 else 60)
		end
		glow(c, root, p.glowSeconds or 10)
	end
	if p.receiverUserId == player.UserId then
		showCard(p)
	end
	showBanner(p)
end

local function pump()
	if showing then
		return
	end
	showing = true
	task.spawn(function()
		while #queue > 0 do
			local p = table.remove(queue, 1) :: Payload
			local ok, err = pcall(run, p)
			if not ok then
				warn(`[FanfareController] {err}`)
			end
		end
		showing = false
	end)
end

function FanfareController:Init(_all) end

function FanfareController:Start()
	build()
	local show = Net.event("Fanfare", "Show")
	show.OnClientEvent:Connect(function(raw: any)
		if type(raw) ~= "table" or type(raw.banner) ~= "string" or type(raw.receiverUserId) ~= "number" then
			return
		end
		local p: Payload = {
			kind = tostring(raw.kind),
			receiverUserId = raw.receiverUserId,
			banner = raw.banner,
			sub = if type(raw.sub) == "string" then raw.sub else "",
			chat = if type(raw.chat) == "string" then raw.chat else raw.banner,
			title = if type(raw.title) == "string" then raw.title else "",
			body = if type(raw.body) == "string" then raw.body else "",
			glowSeconds = math.clamp(tonumber(raw.glowSeconds) or 10, 1, 30),
		}
		-- someone ELSE's pass while you're still on your first call: skip it (PopupGate "fanfare"); your own
		-- purchase / gift always shows
		if p.receiverUserId ~= player.UserId and PopupGate.decide("fanfare") == "drop" then
			return
		end
		if #queue < 6 then
			table.insert(queue, p)
		end
		pump()
	end)
end

-- test hooks (execute_luau on the Client)
function FanfareController:_state(): string
	local b, c = banner, card
	return `shown={shownCount} banner={b ~= nil and b.Visible} card={c ~= nil and c.Visible} text={if bannerText then bannerText.Text else ""}`
end

return FanfareController
