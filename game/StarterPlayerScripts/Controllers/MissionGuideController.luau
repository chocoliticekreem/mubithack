--!strict
-- MissionGuideController [owner: Onboarding]. The first-time mission guide + the returning-player tip.
-- Server: Services/MissionGuideService sets Player attrs GuideMode ("full" | "tip"), GuideRookies and
-- GuideMission when a run starts. Copy + targets: Config/MissionGuides. Step logic: Lib/Onboarding/GuideFlow.
--   * "tip": a one-line card at dispatch (TipSeconds), then gone.
--   * "full": at dispatch a "NEW CALL" card says a guide is coming; on arrival (run RoundState leaves
--     Dispatched) it walks the steps: card (chip n/N, head, sub), a bouncing arrow + highlight on the
--     step's world target, an edge badge when the target is off screen. Each step ends on its done
--     condition (watched here, from attributes / tags / prompts / Hazard Fx), its maxSeconds, or when
--     an optional target isn't at this site. Veterans in a squad with a rookie see a "show them how" line.
--   * Skip any time: SkipKey (J) or the SKIP button. Finish or skip -> MissionGuide/Seen.
-- The card sits on the left under the objectives panel (top centre = timer/objective, top right =
-- minimap/squad, top left = level/objectives), and nothing on it but the SKIP button takes input.
--   * One-time hints (MissionGuides.Hints): the first time you stand next to a rescue or a carry prop,
--     "PICK THEM UP!" (E, then walk them to the truck). Seen = Player attr GuideHints (server, profile).
-- Public: MissionGuideController:IsActive(): boolean, :Skip()
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript) :: any
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local ConfigDir = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigDir:WaitForChild("MissionGuides") :: ModuleScript) :: any
local Catalog = require(ConfigDir:WaitForChild("MissionCatalog") :: ModuleScript) :: any
local Flow = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Onboarding"):WaitForChild("GuideFlow") :: ModuleScript)
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript)
local InputHints = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("InputHints") :: ModuleScript) :: any
local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript)

local MissionGuideController = {}
MissionGuideController.Priority = 125

local player = Players.LocalPlayer
local Attr = Names.Attr
local INK = Palette.UiInk
local CREAM = Palette.UiCream
local GUIDE = Color3.fromHex(Cfg.HighlightColor or "#5BE0FF")
local GOOD = Palette.UiGood or Color3.fromHex("#6BD66B")
local SCAN_EVERY = 0.2

type Run = {
	runId: string,
	missionId: string,
	mode: string,
	call: string,
	rookies: string,
	flow: Flow.State?,
	startedSteps: boolean,
	tipUntil: number,
	finished: boolean,
	-- observations for done conditions
	rescued: { [string]: boolean },
	carried: { [string]: boolean },
	rescuedBase: number,
	fireOutAt: number,
	promptAt: number,
	hazards: { [string]: number },
	seen: { [string]: boolean },
	doneUntil: number,
	lastScan: number,
	target: BasePart?,
	model: Instance?,
	stepKey: string,
}

local run: Run? = nil
local lastSpray = -math.huge
local hint = { shown = 0, firstAt = 0, sent = {} :: { [string]: boolean }, lastScan = 0, part = nil :: BasePart?, model = nil :: Instance? }
local ui: { [string]: any } = {}

------------------------------------------------------------------------------------------ helpers

local function now(): number
	return os.clock()
end

local function root(): BasePart?
	local c = player.Character
	local r = c and c:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function firstPart(inst: Instance?): BasePart?
	if not inst then
		return nil
	end
	if inst:IsA("BasePart") then
		return inst
	end
	if inst:IsA("Model") then
		if inst.PrimaryPart then
			return inst.PrimaryPart
		end
		local hrp = inst:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			return hrp
		end
	end
	return inst:FindFirstChildWhichIsA("BasePart", true)
end

local function catalogCall(missionId: string): string
	for _, def in Catalog do
		if def.id == missionId then
			return def.call or def.title or missionId
		end
	end
	return missionId
end

local function runFolder(r: Run): Instance?
	local runs = workspace:FindFirstChild("Runs")
	return runs and runs:FindFirstChild(r.runId)
end

local function site(r: Run): Instance?
	local f = runFolder(r)
	local v = f and f:FindFirstChild("Site")
	if v and v:IsA("ObjectValue") and v.Value and v.Value:IsDescendantOf(workspace) then
		return v.Value
	end
	local inst = workspace:FindFirstChild("Instances")
	local m = inst and inst:FindFirstChild(r.runId)
	return if m and m:IsA("Model") then m else nil
end

local function roundState(r: Run): string?
	local f = runFolder(r)
	local st = f and f:GetAttribute(Attr.RoundState)
	return if type(st) == "string" then st else nil
end

local siteBoundsCache: { [Instance]: { centre: Vector3, radius: number } } = setmetatable({}, { __mode = "k" }) :: any
local function siteBounds(s: Instance): (Vector3, number)
	local c = siteBoundsCache[s]
	if not c then
		local centre, radius = Vector3.zero, 200
		if s:IsA("Model") then
			local cf, size = s:GetBoundingBox()
			centre = cf.Position
			radius = math.max(size.X, size.Z) / 2 + 40
		elseif s:IsA("BasePart") then
			centre = s.Position
		end
		c = { centre = centre, radius = radius }
		siteBoundsCache[s] = c
	end
	return c.centre, c.radius
end

local function nearSite(s: Instance?, part: BasePart): boolean
	if not s then
		return false
	end
	if part:IsDescendantOf(s) then
		return true
	end
	local centre, radius = siteBounds(s)
	local d = part.Position - centre
	return Vector3.new(d.X, 0, d.Z).Magnitude <= radius
end

local function myTruck(): Model?
	for _, t in CollectionService:GetTagged(Names.Tag.Truck) do
		if t:IsA("Model") and t:GetAttribute("OwnerUserId") == player.UserId and t:IsDescendantOf(workspace) then
			return t
		end
	end
	return nil
end

local function runRescues(r: Run): { Model }
	local out = {}
	local folder = workspace:FindFirstChild("Rescuables")
	if not folder then
		return out
	end
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and m:GetAttribute(Attr.InstanceId) == r.runId then
			table.insert(out, m)
		end
	end
	return out
end

local function hasPrompt(inst: Instance): boolean
	for _, d in inst:GetDescendants() do
		if d:IsA("ProximityPrompt") and d.Enabled then
			return true
		end
	end
	return false
end

local function pick(cands: { BasePart }, highest: boolean?): BasePart?
	local r = root()
	local best: BasePart?, score = nil, math.huge
	for _, p in cands do
		local s = if highest then -p.Position.Y else (if r then (p.Position - r.Position).Magnitude else 0)
		if s < score then
			best, score = p, s
		end
	end
	return best
end

------------------------------------------------------------------------------------------ targets

local function resolve(r: Run, step: Flow.Step): (BasePart?, Instance?)
	local t = step.target
	if not t or t.kind == "none" then
		return nil, nil
	end
	local s = site(r)
	if t.kind == "truck" then
		local truck = myTruck()
		if not truck then
			return nil, nil
		end
		for _, d in truck:GetDescendants() do
			if d:HasTag(t.tag) and (t.attr == nil or d:GetAttribute(t.attr) == t.value) then
				local p = firstPart(d)
				if p then
					return p, d
				end
			end
		end
		return nil, nil
	elseif t.kind == "tag" then
		if not s then
			return nil, nil
		end
		local cands: { BasePart } = {}
		local models: { [BasePart]: Instance } = {}
		for _, inst in CollectionService:GetTagged(t.tag) do
			if not inst:IsDescendantOf(s) then
				continue
			end
			if t.attr ~= nil then
				local v = inst:GetAttribute(t.attr)
				if t.value ~= nil and v ~= t.value then
					continue
				end
				if t.notValue ~= nil and v == t.notValue then
					continue
				end
			end
			if t.prompt and not hasPrompt(inst) then
				continue
			end
			local p = firstPart(inst)
			if p then
				table.insert(cands, p)
				models[p] = inst
			end
		end
		local p = pick(cands, t.highest)
		return p, p and models[p]
	elseif t.kind == "rescue" then
		local cands: { BasePart } = {}
		local models: { [BasePart]: Instance } = {}
		for _, m in runRescues(r) do
			local st = m:GetAttribute(Attr.RescueState)
			if st ~= "Trapped" and st ~= "Downed" then
				continue
			end
			if t.rescueKind and m:GetAttribute(Attr.Kind) ~= t.rescueKind then
				continue
			end
			local p = firstPart(m)
			if p then
				table.insert(cands, p)
				models[p] = m
			end
		end
		local p = pick(cands, t.highest)
		return p, p and models[p]
	elseif t.kind == "burning" then
		local cands: { BasePart } = {}
		for _, inst in CollectionService:GetTagged(Names.Tag.Burning) do
			if inst:IsA("BasePart") and nearSite(s, inst) then
				table.insert(cands, inst)
			end
		end
		local p = pick(cands, t.highest)
		return p, p
	elseif t.kind == "prompt" then
		if not s then
			return nil, nil
		end
		local cands: { BasePart } = {}
		for _, d in s:GetDescendants() do
			if d:IsA("ProximityPrompt") and d.Enabled and d.ActionText == t.action then
				local p = d.Parent
				if p and p:IsA("BasePart") then
					table.insert(cands, p)
				end
			end
		end
		local p = pick(cands, t.highest)
		return p, p
	elseif t.kind == "named" then
		local inst = s and s:FindFirstChild(t.name, true)
		local p = firstPart(inst)
		return p, inst
	end
	return nil, nil
end

------------------------------------------------------------------------------------------ conditions

local function rescueById(r: Run, id: string): Model?
	for _, m in runRescues(r) do
		if m:GetAttribute(Attr.RescueId) == id then
			return m
		end
	end
	return nil
end

local function countRescued(r: Run): number
	local n = 0
	for _ in r.rescued do
		n += 1
	end
	return n
end

-- bookkeeping every scan: which of this run's rescues are saved (state Rescued, or carried and then gone)
local function observeRescues(r: Run)
	local present: { [string]: boolean } = {}
	for _, m in runRescues(r) do
		local id = m:GetAttribute(Attr.RescueId)
		if type(id) ~= "string" then
			continue
		end
		present[id] = true
		local st = m:GetAttribute(Attr.RescueState)
		if st == "Rescued" then
			r.rescued[id] = true
		elseif st == "Carried" then
			r.carried[id] = true
		end
	end
	for id in r.carried do
		if not present[id] then
			r.rescued[id] = true
			r.carried[id] = nil
		end
	end
end

local function evalDone(r: Run, step: Flow.Step, part: BasePart?, model: Instance?, stepStart: number): boolean
	local d = step.done
	local k = d.kind
	if k == "hand" then
		local hand = player:GetAttribute("InvHand")
		if d.items then
			return table.find(d.items, hand) ~= nil
		end
		return hand == d.item
	elseif k == "ladder" then
		local folder = workspace:FindFirstChild("PlacedLadders")
		if folder then
			for _, l in folder:GetChildren() do
				-- yours, and (when the step has a target) stood up next to it, so an old ladder doesn't count
				if l:GetAttribute("OwnerUserId") == player.UserId and l:IsA("BasePart") then
					local flat = (l.Position - (if part then part.Position else l.Position)) * Vector3.new(1, 0, 1)
					if flat.Magnitude <= 30 then
						return true
					end
				end
			end
		end
		return false
	elseif k == "attr" then
		local s = site(r)
		if not s then
			return false
		end
		local any = false
		for _, inst in CollectionService:GetTagged(d.tag) do
			if inst:IsDescendantOf(s) then
				any = true
				if inst:GetAttribute(d.attr) ~= d.value then
					return false
				end
			end
		end
		return any
	elseif k == "carrying" then
		local id = player:GetAttribute(Attr.Carrying)
		if type(id) ~= "string" or id == "" then
			return false
		end
		if not d.rescueKind then
			return true
		end
		local m = rescueById(r, id)
		return m ~= nil and m:GetAttribute(Attr.Kind) == d.rescueKind
	elseif k == "rescued" then
		return countRescued(r) > r.rescuedBase
	elseif k == "fireOut" then
		if r.fireOutAt >= stepStart then
			return true
		end
		-- nothing left burning at the site: nothing to teach here
		local s = site(r)
		if not s or now() - stepStart < 2 then
			return false
		end
		for _, inst in CollectionService:GetTagged(Names.Tag.Burning) do
			if inst:IsA("BasePart") and nearSite(s, inst) then
				return false
			end
		end
		return true
	elseif k == "slapped" or k == "pair" then
		for _, m in runRescues(r) do
			if d.rescueKind and m:GetAttribute(Attr.Kind) ~= d.rescueKind then
				continue
			end
			local st = m:GetAttribute(Attr.RescueState)
			if st == "Rescued" then
				return true
			end
			if k == "slapped" and (m:GetAttribute("Slapped") == true or st == "Carried") then
				return true
			end
			if k == "pair" then
				local id = m:GetAttribute(Attr.RescueId)
				local n = 0
				for _, p in Players:GetPlayers() do
					if id ~= nil and p:GetAttribute(Attr.Carrying) == id then
						n += 1
					end
				end
				if n >= 2 then
					return true
				end
			end
		end
		return false
	elseif k == "near" then
		local rp = root()
		return part ~= nil and rp ~= nil and (part.Position - rp.Position).Magnitude <= (d.studs or 15)
	elseif k == "prompt" then
		return r.promptAt >= stepStart
	elseif k == "appeared" then
		return part ~= nil
	elseif k == "gone" then
		return part == nil and r.seen[step.id] == true
	elseif k == "hazard" then
		return r.hazards[d.hazardId] ~= nil
	end
	return false
end

------------------------------------------------------------------------------------------ ui

local function build()
	local gui = UiKit.screen("MissionGuide", 24)
	ui.gui = gui
	local card = Instance.new("Frame")
	card.Name = "Card"
	-- left column, under the objectives and the building bar (ClientLib/HudLayout owns Position.Y)
	-- 350 wide: the top-centre CALL! card starts at x >= 380 on any screen (half of >= 1280 design units
	-- minus its 260 half-width), so the left column must end before that
	card.Position = UDim2.fromOffset(14, 196)
	card.Size = UDim2.fromOffset(350, 96)
	card.BackgroundColor3 = Palette.UiPanelDark
	card.BackgroundTransparency = 0.08
	card.Active = false
	card.Visible = false
	card.Parent = gui
	HudLayout.add("Left", card, 30)
	HudLayout.reserve(card)
	UiKit.corner(card, 14)
	local cs = UiKit.stroke(card, 3, GUIDE)
	local chip = Instance.new("Frame")
	chip.Name = "Chip"
	chip.Position = UDim2.fromOffset(10, 10)
	chip.Size = UDim2.fromOffset(84, 50)
	chip.BackgroundColor3 = GUIDE
	chip.Parent = card
	UiKit.corner(chip, 10)
	local chipText = UiKit.label(chip, "T", "1/4", UDim2.new(1, -10, 1, -12), UDim2.fromOffset(5, 6), { font = UiKit.Header, color = INK })
	chipText.TextScaled = true
	local head = UiKit.label(card, "Head", "", UDim2.new(1, -116, 0, 32), UDim2.fromOffset(104, 8), {
		font = UiKit.Header,
		color = CREAM,
		align = Enum.TextXAlignment.Left,
		stroke = true,
		strokeThickness = 2,
	})
	head.TextScaled = true
	local sub = UiKit.label(card, "Sub", "", UDim2.new(1, -116, 0, 44), UDim2.fromOffset(104, 42), {
		font = UiKit.Body,
		color = CREAM,
		align = Enum.TextXAlignment.Left,
	})
	sub.TextScaled = true
	sub.TextWrapped = true
	sub.TextYAlignment = Enum.TextYAlignment.Top
	local skip = Instance.new("TextButton")
	skip.Name = "Skip"
	skip.Position = UDim2.fromOffset(10, 66)
	skip.Size = UDim2.fromOffset(84, 22)
	skip.BackgroundColor3 = Palette.UiPanelDark
	skip.BackgroundTransparency = 0.2
	skip.Font = UiKit.Header
	skip.TextColor3 = CREAM
	skip.TextSize = 15
	InputHints.setChip(skip, Cfg.SkipKey or "J", "SKIP", true)
	skip.AutoButtonColor = true
	skip.Parent = card
	UiKit.corner(skip, 6)
	UiKit.stroke(skip, 1.5)
	-- "show them how" ribbon for veterans in a squad with a rookie
	local ribbon = UiKit.label(card, "Rookie", "", UDim2.new(1, -20, 0, 22), UDim2.new(0, 10, 1, 4), {
		font = UiKit.Body,
		color = GUIDE,
		align = Enum.TextXAlignment.Left,
		stroke = true,
		strokeThickness = 1.5,
	})
	ribbon.TextScaled = true
	ribbon.Visible = false
	local scale = Instance.new("UIScale")
	scale.Parent = card
	ui.card, ui.cardStroke, ui.chip, ui.chipText, ui.head, ui.sub, ui.skip, ui.ribbon, ui.scale =
		card, cs, chip, chipText, head, sub, skip, ribbon, scale

	-- world arrow + highlight (same shape as the station tutorial's, in the guide colour)
	local bb = Instance.new("BillboardGui")
	bb.Name = "MissionGuideArrow"
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(200, 110)
	bb.Enabled = false
	bb.ResetOnSpawn = false
	bb.Parent = player:WaitForChild("PlayerGui")
	local lbl = UiKit.label(bb, "Label", "", UDim2.new(1, 0, 0, 30), UDim2.fromOffset(0, 0), {
		font = UiKit.Header,
		color = GUIDE,
		stroke = true,
		strokeThickness = 3,
	})
	lbl.TextScaled = true
	local shaft = Instance.new("Frame")
	shaft.AnchorPoint = Vector2.new(0.5, 0)
	shaft.Position = UDim2.new(0.5, 0, 0, 36)
	shaft.Size = UDim2.fromOffset(16, 32)
	shaft.BackgroundColor3 = GUIDE
	shaft.BorderSizePixel = 0
	shaft.Parent = bb
	UiKit.stroke(shaft, 3, INK)
	local tip = Instance.new("Frame")
	tip.AnchorPoint = Vector2.new(0.5, 0.5)
	tip.Position = UDim2.new(0.5, 0, 0, 74)
	tip.Size = UDim2.fromOffset(32, 32)
	tip.Rotation = 45
	tip.BackgroundColor3 = GUIDE
	tip.BorderSizePixel = 0
	tip.Parent = bb
	UiKit.stroke(tip, 3, INK)
	local hl = Instance.new("Highlight")
	hl.Name = "MissionGuideHighlight"
	hl.FillColor = GUIDE
	hl.OutlineColor = GUIDE
	hl.FillTransparency = 0.75
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Enabled = false
	ui.arrow, ui.arrowLabel, ui.highlight = bb, lbl, hl

	-- a glowing guide line from you to the target (local only; Attachment1 lives on a local anchor part)
	local anchor = Instance.new("Part")
	anchor.Name = "MissionGuideAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	local a1 = Instance.new("Attachment")
	a1.Parent = anchor
	local beam = Instance.new("Beam")
	beam.Name = "MissionGuideBeam"
	beam.Attachment1 = a1
	beam.Color = ColorSequence.new(GUIDE)
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Width0 = 0.35
	beam.Width1 = 0.9
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.85),
		NumberSequenceKeypoint.new(0.25, 0.35),
		NumberSequenceKeypoint.new(1, 0.15),
	})
	beam.Enabled = false
	beam.Parent = anchor
	ui.anchor, ui.beam = anchor, beam

	-- edge badge when the target is off screen (own full-bleed gui: viewport pixels)
	local edgeGui = Instance.new("ScreenGui")
	edgeGui.Name = "MissionGuideEdge"
	edgeGui.IgnoreGuiInset = true
	edgeGui.ResetOnSpawn = false
	edgeGui.DisplayOrder = 24
	edgeGui.Parent = player:WaitForChild("PlayerGui")
	local edge = Instance.new("Frame")
	edge.Name = "Edge"
	edge.AnchorPoint = Vector2.new(0.5, 0.5)
	edge.Size = UDim2.fromOffset(46, 46)
	edge.BackgroundColor3 = GUIDE
	edge.Visible = false
	edge.Parent = edgeGui
	UiKit.corner(edge, 23)
	UiKit.stroke(edge, 3, INK)
	local pointer = Instance.new("Frame")
	pointer.AnchorPoint = Vector2.new(0.5, 0.5)
	pointer.Size = UDim2.fromOffset(20, 20)
	pointer.Rotation = 45
	pointer.BackgroundColor3 = GUIDE
	pointer.BorderSizePixel = 0
	pointer.ZIndex = 0
	pointer.Parent = edge
	UiKit.stroke(pointer, 3, INK)
	local q = UiKit.label(edge, "Q", "?", UDim2.new(1, -12, 1, -12), UDim2.fromOffset(6, 7), { font = UiKit.Header, color = INK })
	q.TextScaled = true
	q.ZIndex = 2
	ui.edge, ui.pointer = edge, pointer
end

local function showCard(chip: string, head: string, sub: string, chipColor: Color3?, key: string)
	local card: Frame = ui.card
	ui.chip.BackgroundColor3 = chipColor or GUIDE
	if ui.stepKey == key and card.Visible then
		return
	end
	ui.stepKey = key
	ui.chipText.Text = chip
	ui.head.Text = head
	InputHints.set(ui.sub, sub) -- "Press E" -> "Tap the button" on a phone
	card.Visible = true
	ui.scale.Scale = 0.6
	TweenService:Create(ui.scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	UiKit.pop(ui.chip, 0.3)
end

local function hideCard()
	ui.card.Visible = false
	ui.stepKey = ""
end

local function placeArrow(part: BasePart?, model: Instance?, label: string, t: number)
	local bb: BillboardGui = ui.arrow
	local hl: Highlight = ui.highlight
	local beam: Beam = ui.beam
	if not part or not part:IsDescendantOf(workspace) then
		bb.Enabled = false
		hl.Enabled = false
		beam.Enabled = false
		ui.edge.Visible = false
		return
	end
	-- guide line: from your chest to the target (hidden when you're right on top of it)
	local rp = root()
	local a0 = rp and rp:FindFirstChild("MissionGuideA0")
	if rp and not a0 then
		local a = Instance.new("Attachment")
		a.Name = "MissionGuideA0"
		a.Position = Vector3.new(0, 0.5, 0)
		a.Parent = rp
		a0 = a
	end
	ui.anchor.CFrame = CFrame.new(part.Position)
	if ui.anchor.Parent ~= workspace.CurrentCamera then
		ui.anchor.Parent = workspace.CurrentCamera
	end
	beam.Attachment0 = a0 :: Attachment?
	beam.Enabled = rp ~= nil and (part.Position - rp.Position).Magnitude > 8
	if bb.Adornee ~= part then
		bb.Adornee = part
	end
	bb.StudsOffsetWorldSpace = Vector3.new(0, part.Size.Y / 2 + (Cfg.ArrowHeight or 4.5) + math.sin(t * 5) * (Cfg.ArrowBob or 0.6), 0)
	ui.arrowLabel.Text = label
	bb.Enabled = true
	local m = model or part
	if m:IsDescendantOf(workspace) then
		if hl.Adornee ~= m then
			hl.Adornee = m
		end
		if hl.Parent ~= workspace.CurrentCamera then
			hl.Parent = workspace.CurrentCamera
		end
		hl.FillTransparency = 0.7 + 0.15 * math.sin(t * 4)
		hl.Enabled = true
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local sp, onScreen = cam:WorldToViewportPoint(part.Position)
	if onScreen and sp.Z > 0 then
		ui.edge.Visible = false
		return
	end
	local vp = cam.ViewportSize
	local rel = cam.CFrame:PointToObjectSpace(part.Position)
	local side = if rel.X >= 0 then 1 else -1
	-- left: under the guide card, above the Pass button; right: under the minimap / GPS panel
	local ex, ey = HudLayout.clear(if side > 0 then vp.X - 56 else 56, vp.Y * (if side > 0 then 0.66 else 0.42), 30, "GuideEdge", HudLayout.Prio.Guide)
	ui.edge.Position = UDim2.fromOffset(ex, ey)
	ui.pointer.Position = UDim2.fromOffset(23 + side * 27, 23)
	ui.edge.Visible = true
end

------------------------------------------------------------------------------------------ run lifecycle

local function sendSeen(r: Run)
	pcall(function()
		Net.event("MissionGuide", "Seen"):FireServer(r.missionId)
	end)
end

local function finish(r: Run, skipped: boolean)
	if r.finished then
		return
	end
	r.finished = true
	if r.flow then
		Flow.skip(r.flow)
	end
	placeArrow(nil, nil, "", 0)
	ui.ribbon.Visible = false
	if r.mode == "full" then
		sendSeen(r)
	end
	if skipped then
		hideCard()
	else
		showCard("DONE!", "YOU'VE GOT THIS", "Guide over. Go be a hero. Or at least a witness.", GOOD, "done")
		task.delay(2.5, function()
			if run == r or run == nil then
				hideCard()
			end
		end)
	end
end

local function stop()
	run = nil
	hideCard()
	placeArrow(nil, nil, "", 0)
	if ui.ribbon then
		ui.ribbon.Visible = false
	end
end

local function begin()
	local runId = player:GetAttribute(Attr.InstanceId)
	local missionId = player:GetAttribute("GuideMission")
	local mode = player:GetAttribute("GuideMode")
	if type(runId) ~= "string" or runId == "" or type(missionId) ~= "string" or missionId == "" then
		stop()
		return
	end
	if run and run.runId == runId and run.missionId == missionId then
		return
	end
	stop()
	local r: Run = {
		runId = runId,
		missionId = missionId,
		mode = if mode == "full" then "full" else "tip",
		call = catalogCall(missionId),
		rookies = tostring(player:GetAttribute("GuideRookies") or ""),
		flow = nil,
		startedSteps = false,
		tipUntil = now() + (Cfg.TipSeconds or 9),
		finished = false,
		rescued = {},
		carried = {},
		rescuedBase = 0,
		fireOutAt = -math.huge,
		promptAt = -math.huge,
		hazards = {},
		seen = {},
		doneUntil = 0,
		lastScan = 0,
		target = nil,
		model = nil,
		stepKey = "",
	}
	run = r
	if r.mode == "full" then
		local mine = false
		for name in string.gmatch(r.rookies, "[^,]+") do
			if string.gsub(name, "^%s+", "") == player.DisplayName then
				mine = true
			end
		end
		if r.rookies ~= "" and not mine then
			ui.ribbon.Text = (string.gsub(Cfg.RookieLine or "", "{names}", r.rookies))
		else
			ui.ribbon.Text = ""
		end
	end
end

function MissionGuideController:IsActive(): boolean
	return run ~= nil and not (run :: Run).finished
end

function MissionGuideController:Skip()
	local r = run
	if r and not r.finished then
		finish(r, true)
	end
end

local function hintSeen(id: string): boolean
	if hint.sent[id] then
		return true
	end
	local seen = player:GetAttribute("GuideHints")
	if type(seen) ~= "string" then
		return true -- not loaded yet: say nothing
	end
	for s in string.gmatch(seen, "[^,]+") do
		if s == id then
			return true
		end
	end
	return false
end

local function markHint(id: string)
	if hint.sent[id] then
		return
	end
	hint.sent[id] = true
	pcall(function()
		Net.event("MissionGuide", "Seen"):FireServer("hint:" .. id)
	end)
end

-- the carry hint: nearest rescue (still to save) or carry prop within `studs`. Returns true while shown.
local function carryHint(t: number): boolean
	local h = Cfg.Hints and Cfg.Hints.carry
	if not h or hintSeen("carry") then
		return false
	end
	local carrying = (player:GetAttribute(Attr.Carrying) or "") ~= "" or (player:GetAttribute("InvCarry") or "") ~= ""
	if carrying then
		if hint.shown > 0 then
			markHint("carry") -- they did it
		end
		hint.part = nil
		return false
	end
	if t - hint.lastScan >= 0.25 then
		hint.lastScan = t
		hint.part, hint.model = nil, nil
		local rp = root()
		if rp then
			local best = h.studs or 11
			local folder = workspace:FindFirstChild("Rescuables")
			for _, m in (if folder then folder:GetChildren() else {}) :: { Instance } do
				local st = m:GetAttribute(Attr.RescueState)
				if st == "Trapped" or st == "Downed" then
					local p = firstPart(m)
					local d = p and (p.Position - rp.Position).Magnitude
					if p and d and d < best then
						best, hint.part, hint.model = d, p, m
					end
				end
			end
			for _, inst in CollectionService:GetTagged("Carryable") do
				local p = firstPart(inst)
				local d = p and p:IsDescendantOf(workspace) and (p.Position - rp.Position).Magnitude
				if p and d and d < best then
					best, hint.part, hint.model = d, p, inst
				end
			end
		end
	end
	if not hint.part then
		return false
	end
	if hint.shown == 0 then
		hint.firstAt = now()
	end
	hint.shown += 1
	if now() - hint.firstAt >= (h.seconds or 7) then
		markHint("carry")
	end
	showCard("TIP", h.head, h.sub, nil, "hint:carry")
	ui.skip.Visible = false
	placeArrow(hint.part, hint.model, h.head, t)
	return true
end

local function update(t: number)
	local r = run
	local busy = r ~= nil and not r.finished
	if not busy then
		if carryHint(t) then
			return
		elseif ui.stepKey == "hint:carry" then
			hideCard()
			placeArrow(nil, nil, "", t)
		end
	end
	if not r then
		return
	end
	if r.mode == "tip" then
		if now() < r.tipUntil then
			local tip = Flow.tip(Cfg, r.missionId)
			if tip then
				showCard("TIP", string.upper(r.call), tip, nil, "tip")
				ui.skip.Visible = false
			end
		else
			r.finished = true
			hideCard()
		end
		return
	end
	if r.finished then
		return
	end
	ui.skip.Visible = true
	local st = roundState(r)
	if not r.startedSteps then
		if st == "Dispatched" or st == nil and runFolder(r) ~= nil then
			showCard(Cfg.ChipNew or "NEW CALL", `FIRST {string.upper(r.call)}!`, "Quick guide when you get there. Follow the GPS for now.", nil, "intro")
			ui.ribbon.Visible = ui.ribbon.Text ~= ""
			return
		end
		r.startedSteps = true
		observeRescues(r)
		r.flow = Flow.new(Flow.steps(Cfg, r.missionId), now(), Cfg.GraceSeconds)
		r.rescuedBase = countRescued(r)
	end
	local flow = r.flow :: Flow.State
	if st == "Results" or st == "Done" then
		finish(r, true)
		return
	end
	-- scan the world (throttled)
	if t - r.lastScan >= SCAN_EVERY then
		r.lastScan = t
		observeRescues(r)
		local step = Flow.current(flow)
		if step then
			local part, model = resolve(r, step)
			r.target, r.model = part, model
			if part then
				r.seen[step.id] = true
			end
			local before = flow.index
			local nextStep, why = Flow.tick(flow, { found = part ~= nil, done = evalDone(r, step, part, model, flow.stepStart) }, now())
			if flow.index ~= before then
				-- local-only breadcrumb for tests / ForgeTest ("<step id>:<why>")
				player:SetAttribute("GuideLast", `{step.id}:{why}`)
				r.rescuedBase = countRescued(r)
				r.target, r.model = nil, nil
				if why == "done" then
					r.doneUntil = now() + (Cfg.DoneFlashSeconds or 0.9)
				end
				-- a step whose target is the same thing as the one just finished counts as seen already
				if nextStep and r.seen[step.id] and nextStep.target and step.target and nextStep.target.name ~= nil and nextStep.target.name == step.target.name then
					r.seen[nextStep.id] = true
				end
			end
			if not nextStep then
				finish(r, false)
				return
			end
		end
	end
	local step = Flow.current(flow)
	if not step then
		return
	end
	local total = #flow.steps
	if now() < r.doneUntil then
		ui.chip.BackgroundColor3 = GOOD
		ui.chipText.Text = "NICE!"
		placeArrow(nil, nil, "", t)
		return
	end
	showCard(`{flow.index}/{total}`, step.head, step.sub, nil, `{r.missionId}|{step.id}`)
	ui.ribbon.Visible = ui.ribbon.Text ~= ""
	placeArrow(r.target, r.model, step.head, t)
end

------------------------------------------------------------------------------------------ lifecycle

function MissionGuideController:Init(_all: { [string]: any }) end

function MissionGuideController:Start()
	build()
	ui.skip.Activated:Connect(function()
		MissionGuideController:Skip()
	end)
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode.Name == (Cfg.SkipKey or "J") then
			MissionGuideController:Skip()
		end
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
		local r = run
		if who ~= player or not r then
			return
		end
		local m = r.model or r.target
		if m and (prompt:IsDescendantOf(m) or prompt.Parent == m) then
			r.promptAt = now()
		end
	end)
	-- fires going out while YOU spray (Spraying attr) at your site
	player:GetAttributeChangedSignal(Attr.Spraying):Connect(function()
		lastSpray = now()
	end)
	CollectionService:GetInstanceRemovedSignal(Names.Tag.Burning):Connect(function(inst: Instance)
		local r = run
		if not r or not inst:IsA("BasePart") then
			return
		end
		local sprayingNow = player:GetAttribute(Attr.Spraying) == true
		if (sprayingNow or now() - lastSpray < 4) and nearSite(site(r), inst) then
			r.fireOutAt = now()
		end
	end)
	task.spawn(function()
		local ok, fx = pcall(Net.event, "Hazard", "Fx")
		if ok and fx then
			fx.OnClientEvent:Connect(function(hazardId: any, pos: any)
				local r = run
				if not r or type(hazardId) ~= "string" then
					return
				end
				local s = site(r)
				if s and typeof(pos) == "Vector3" then
					local centre, radius = siteBounds(s)
					if (pos - centre).Magnitude > radius + 200 then
						return
					end
				end
				r.hazards[hazardId] = now()
			end)
		end
	end)
	player:GetAttributeChangedSignal("GuideMission"):Connect(begin)
	player:GetAttributeChangedSignal(Attr.InstanceId):Connect(function()
		local id = player:GetAttribute(Attr.InstanceId)
		if type(id) ~= "string" or id == "" then
			stop()
		else
			begin()
		end
	end)
	begin()
	local t = 0
	RunService.RenderStepped:Connect(function(dt: number)
		t += dt
		local ok, err = pcall(update, t)
		if not ok then
			warn(`[MissionGuide] {err}`)
			stop()
		end
	end)
end

return MissionGuideController
