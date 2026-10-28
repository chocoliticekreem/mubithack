--!strict
-- FireCallController [owner: G1]. "Where is the fire?" the moment your squad arrives (docs/game/21-phone-first-fire.md).
-- Live funnel, 7 days: 23.6% of phone players arrived on scene and left before putting out one fire (PC 9.5%).
-- On a phone the HUD's fire marker hid within 20 m (70 studs, i.e. at every arrival), the fires sit inside
-- buildings, and the only pointer was the rookie guide's small arrow (rookies only, after "GRAB THE HOSE").
-- From the moment YOUR run goes Active (workspace.Runs.<InstanceId> RoundState) until YOU put out a fire
-- (a Burning part loses its tag with OutBy = you) or the site has none left:
--   * a glowing beacon column on the NEAREST burning part of your site (local parts under the camera)
--   * one huge bouncing arrow over it (BillboardGui, always on top) with the distance; when it's off screen,
--     one huge edge arrow at the screen edge pointing at it (kept off HUD widgets: HudLayout.clear)
--   * a top banner "SPRAY THE FIRE!" + distance (HudLayout TopCentre, under the timer); touch adds one line:
--     "Hop out first!" while you're seated, else "Hold the SPRAY button to put it out!"
--   * LocalPlayer attr FireCallGuide = true (local only) while it shows: HudController hides its own small
--     fire marker so there is ONE arrow to the fire.
-- Every device (the PC/console marker had the same 20 m blind spot). Nothing here changes gameplay.
-- Public: FireCallController:IsActive(): boolean; test hook :_state() -> { active, dist, target }
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript) :: any
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript)
local HudLayout = require(ClientLib:WaitForChild("HudLayout") :: ModuleScript)
local InputHints = require(ClientLib:WaitForChild("InputHints") :: ModuleScript) :: any
local Calm = require(ClientLib:WaitForChild("Calm") :: ModuleScript) :: any
local Loc = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Loc") :: ModuleScript)

local FireCallController = {}
FireCallController.Priority = 72

local player = Players.LocalPlayer
local BURNING: string = Names.Tag.Burning
local ATTR = "FireCallGuide"
local YELLOW = Palette.UiWarn or Color3.fromHex("#FFC531")
local INK = Palette.UiInk
local CREAM = Palette.UiCream
local SCAN_EVERY = 0.2
local STUDS_PER_M = 3.5

type Ui = {
	banner: Frame,
	head: TextLabel,
	dist: TextLabel,
	sub: TextLabel,
	edge: Frame,
	edgePivot: Frame,
	edgeDist: TextLabel,
	beacon: Part,
	anchor: Part,
	board: BillboardGui,
	boardArrow: Frame,
	boardDist: TextLabel,
}

local ui: Ui? = nil
local runId = ""
local doneRun = "" -- the run you already put a fire out on
local target: BasePart? = nil
local lastScan = 0
local active = false

------------------------------------------------------------------------------------------ build

local function arrowShape(parent: Instance, w: number, color: Color3): Frame
	-- a fat down arrow made of frames: shaft + a rotated square head (no image assets)
	local holder = Instance.new("Frame")
	holder.Name = "Arrow"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(w, w * 1.15)
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, 1, 0)
	holder.Parent = parent
	local shaft = Instance.new("Frame")
	shaft.Name = "Shaft"
	shaft.AnchorPoint = Vector2.new(0.5, 0)
	shaft.Position = UDim2.fromScale(0.5, 0)
	shaft.Size = UDim2.new(0.4, 0, 0.6, 0)
	shaft.BackgroundColor3 = color
	shaft.BorderSizePixel = 0
	UiKit.stroke(shaft, 4, INK)
	shaft.Parent = holder
	local head = Instance.new("Frame")
	head.Name = "Head"
	head.AnchorPoint = Vector2.new(0.5, 0.5)
	head.Position = UDim2.fromScale(0.5, 0.62)
	head.Size = UDim2.fromOffset(w * 0.62, w * 0.62)
	head.Rotation = 45
	head.BackgroundColor3 = color
	head.BorderSizePixel = 0
	head.ZIndex = 2
	UiKit.stroke(head, 4, INK)
	head.Parent = holder
	-- a cap over the head's top half hides the seam where the shaft meets it
	local cap = Instance.new("Frame")
	cap.Name = "Cap"
	cap.AnchorPoint = Vector2.new(0.5, 0)
	cap.Position = UDim2.fromScale(0.5, 0.35)
	cap.Size = UDim2.new(0.4, -8, 0.3, 0)
	cap.BackgroundColor3 = color
	cap.BorderSizePixel = 0
	cap.ZIndex = 3
	cap.Parent = holder
	return holder
end

local function build(): Ui
	-- top banner (scaled HUD gui, TopCentre stack under the timer)
	local gui = UiKit.screen("FireCall", 6)
	local banner = UiKit.panel(gui, "SprayBanner", UDim2.fromOffset(500, 64), UDim2.new(0.5, 0, 0, 80), Vector2.new(0.5, 0))
	banner.BackgroundColor3 = YELLOW
	banner.Visible = false
	local head = UiKit.label(banner, "Head", "SPRAY THE FIRE!", UDim2.new(1, -130, 0, 52), UDim2.fromOffset(14, 4), {
		font = UiKit.Header,
		textSize = 46,
		color = INK,
		align = Enum.TextXAlignment.Left,
	})
	head.TextScaled = true
	local dist = UiKit.label(banner, "Dist", "0m", UDim2.fromOffset(112, 52), UDim2.new(1, -120, 0, 4), {
		font = UiKit.Header,
		textSize = 44,
		color = Palette.FireEdge or Color3.fromHex("#FF5A1F"),
		stroke = true,
		strokeThickness = 2,
	})
	local sub = UiKit.label(banner, "Sub", "", UDim2.new(1, -20, 0, 32), UDim2.fromOffset(10, 54), {
		font = UiKit.Body,
		textSize = 28, -- ~15 px on a phone (UiKit scale 0.55)
		color = INK,
	})
	sub.Visible = false
	HudLayout.add("TopCentre", banner, 12)
	HudLayout.reserve(banner)

	-- the off-screen edge arrow (full-bleed, unscaled: viewport px)
	local edgeGui = UiKit.screen("FireCallEdge", 5, true)
	local vs = edgeGui:FindFirstChild("ViewportScale")
	if vs then
		vs:Destroy()
	end
	local edge = Instance.new("Frame")
	edge.Name = "EdgeArrow"
	edge.AnchorPoint = Vector2.new(0.5, 0.5)
	edge.Size = UDim2.fromOffset(76, 76)
	edge.BackgroundTransparency = 1
	edge.Visible = false
	edge.Parent = edgeGui
	local pivot = Instance.new("Frame")
	pivot.Name = "Pivot"
	pivot.AnchorPoint = Vector2.new(0.5, 0.5)
	pivot.Position = UDim2.fromScale(0.5, 0.5)
	pivot.Size = UDim2.fromScale(1, 1)
	pivot.BackgroundTransparency = 1
	pivot.Parent = edge
	local tip = Instance.new("Frame")
	tip.Name = "Tip"
	tip.AnchorPoint = Vector2.new(0.5, 0.5)
	tip.Position = UDim2.new(1, 6, 0.5, 0)
	tip.Size = UDim2.fromOffset(36, 36)
	tip.Rotation = 45
	tip.BackgroundColor3 = YELLOW
	tip.BorderSizePixel = 0
	UiKit.stroke(tip, 4, INK)
	tip.Parent = pivot
	local circle = Instance.new("Frame")
	circle.Name = "Circle"
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.fromScale(0.5, 0.5)
	circle.Size = UDim2.fromOffset(68, 68)
	circle.BackgroundColor3 = YELLOW
	circle.BorderSizePixel = 0
	circle.ZIndex = 2
	UiKit.corner(circle, 68)
	UiKit.stroke(circle, 4, INK)
	circle.Parent = edge
	local icon = UiKit.label(circle, "Icon", "🔥", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), { textSize = 38 })
	icon.ZIndex = 3
	local edgeDist = UiKit.label(edge, "Dist", "0m", UDim2.fromOffset(110, 28), UDim2.new(0.5, -55, 1, 4), {
		font = UiKit.Header,
		textSize = 26,
		color = CREAM,
		stroke = true,
	})

	-- world: beacon column + the big arrow over the fire (local only, under the camera)
	local beacon = Instance.new("Part")
	beacon.Name = "FireCallBeacon"
	beacon.Shape = Enum.PartType.Cylinder
	beacon.Material = Enum.Material.Neon
	beacon.Color = YELLOW
	beacon.Transparency = 0.6
	beacon.Anchored = true
	beacon.CanCollide = false
	beacon.CanQuery = false
	beacon.CanTouch = false
	beacon.CastShadow = false
	beacon.Size = Vector3.new(80, 3, 3) -- cylinder axis = X; stood up in place()
	local anchor = Instance.new("Part")
	anchor.Name = "FireCallArrowAnchor"
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	local board = Instance.new("BillboardGui")
	board.Name = "FireCallArrow"
	board.AlwaysOnTop = true
	board.LightInfluence = 0
	board.Size = UDim2.fromOffset(120, 170)
	board.SizeOffset = Vector2.new(0, 0.5)
	board.MaxDistance = 2000
	board.ResetOnSpawn = false
	board.Adornee = anchor
	board.Enabled = false
	local boardDist = UiKit.label(board, "Dist", "0m", UDim2.new(1, 0, 0, 34), UDim2.fromScale(0, 0), {
		font = UiKit.Header,
		textSize = 32,
		color = CREAM,
		stroke = true,
	})
	local boardArrow = arrowShape(board, 96, YELLOW)
	board.Parent = player:WaitForChild("PlayerGui")

	return {
		banner = banner,
		head = head,
		dist = dist,
		sub = sub,
		edge = edge,
		edgePivot = pivot,
		edgeDist = edgeDist,
		beacon = beacon,
		anchor = anchor,
		board = board,
		boardArrow = boardArrow,
		boardDist = boardDist,
	}
end

------------------------------------------------------------------------------------------ state

local function myRun(): Instance?
	local id = player:GetAttribute("InstanceId")
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local runs = workspace:FindFirstChild("Runs")
	return runs and runs:FindFirstChild(id)
end

local function siteOf(run: Instance): Instance?
	local v = run:FindFirstChild("Site")
	if v and v:IsA("ObjectValue") then
		return v.Value
	end
	return nil
end

local function nearestFire(site: Instance?, from: Vector3): BasePart?
	local best: BasePart? = nil
	local bd = math.huge
	for _, p in CollectionService:GetTagged(BURNING) do
		if p:IsA("BasePart") and p:IsDescendantOf(workspace) and (site == nil or p:IsDescendantOf(site)) then
			local d = (p.Position - from).Magnitude
			if d < bd then
				best, bd = p, d
			end
		end
	end
	return best
end

local function seated(): boolean
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.SeatPart ~= nil
end

local function hide(u: Ui)
	if not active and target == nil and not u.board.Enabled and not u.edge.Visible then
		return
	end
	if active then
		active = false
		player:SetAttribute(ATTR, nil)
	end
	u.banner.Visible = false
	u.edge.Visible = false
	u.board.Enabled = false
	u.beacon.Parent = nil
	u.anchor.Parent = nil
	target = nil
end

local function place(u: Ui, part: BasePart, from: Vector3, t: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local top = part.Position.Y + part.Size.Y / 2
	local base = part.Position.Y - part.Size.Y / 2
	local height = u.beacon.Size.X
	u.beacon.CFrame = CFrame.new(part.Position.X, base + height / 2, part.Position.Z) * CFrame.Angles(0, 0, math.rad(90))
	local pulse = if Calm.on() then 0 else 0.12 * math.sin(t * 5)
	u.beacon.Transparency = 0.6 + pulse
	u.beacon.Parent = cam
	local bob = if Calm.on() then 0 else math.abs(math.sin(t * 4)) * 1.6
	u.anchor.CFrame = CFrame.new(part.Position.X, top + 3 + bob, part.Position.Z)
	u.anchor.Parent = cam

	local metres = math.floor((part.Position - from).Magnitude / STUDS_PER_M + 0.5)
	local mText = Loc.t("{1}m", { metres })
	u.dist.Text = mText
	u.boardDist.Text = mText
	u.edgeDist.Text = mText

	-- on screen: the big arrow over the fire. Off screen: the big edge arrow.
	local v, onScreen = cam:WorldToViewportPoint(u.anchor.Position)
	local vp = cam.ViewportSize
	local margin = 50
	local topClear = GuiService:GetGuiInset().Y + 40
	local visible = onScreen and v.X > margin and v.X < vp.X - margin and v.Y > topClear and v.Y < vp.Y - margin
	u.board.Enabled = visible
	u.edge.Visible = not visible
	if not visible then
		local cx, cy = vp.X / 2, vp.Y / 2
		local dx, dy = v.X - cx, v.Y - cy
		if v.Z < 0 then
			dx, dy = -dx, -dy
		end
		if math.abs(dx) < 1e-3 and math.abs(dy) < 1e-3 then
			dy = 1
		end
		local rx, ry = vp.X * 0.42, math.min(vp.Y * 0.36, vp.Y / 2 - topClear)
		local k = 1 / math.sqrt((dx / rx) ^ 2 + (dy / ry) ^ 2)
		local ex, ey = HudLayout.clear(cx + dx * k, cy + dy * k, 46, "FireCallEdge", HudLayout.Prio.Fire)
		u.edge.Position = UDim2.fromOffset(ex, ey)
		u.edgePivot.Rotation = math.deg(math.atan2(dy, dx))
	end
end

local function refresh(u: Ui)
	local t = os.clock()
	local run = myRun()
	if not run or run:GetAttribute("RoundState") ~= "Active" then
		hide(u)
		return
	end
	if run.Name ~= runId then
		runId = run.Name
		target = nil
	end
	if doneRun == runId then
		hide(u)
		return
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		hide(u)
		return
	end
	local from = root.Position
	if not target or not target.Parent or not target:HasTag(BURNING) or t - lastScan > SCAN_EVERY then
		lastScan = t
		target = nearestFire(siteOf(run), from)
	end
	local part = target
	if not part then
		hide(u)
		return
	end
	if not active then
		active = true
		player:SetAttribute(ATTR, true)
		u.banner.Visible = true
		UiKit.pop(u.banner, 0.3)
	end
	local touch = InputHints.isTouch()
	if u.sub.Visible ~= touch then
		u.sub.Visible = touch
		u.banner.Size = UDim2.fromOffset(500, if touch then 92 else 64) -- HudLayout restacks on Size
	end
	if touch then
		u.sub.Text = if seated() then "Hop out first!" else "Hold the SPRAY button to put it out!"
	end
	place(u, part, from, t)
end

------------------------------------------------------------------------------------------ lifecycle

function FireCallController:Init(_all: { [string]: any }) end

function FireCallController:Start()
	local u = build()
	ui = u
	-- YOUR first fire out on this call ends the guide (FireService sets OutBy just before the tag goes)
	CollectionService:GetInstanceRemovedSignal(BURNING):Connect(function(inst: Instance)
		if runId ~= "" and inst:GetAttribute(Names.Attr.OutBy or "OutBy") == player.UserId then
			doneRun = runId
		end
	end)
	RunService.RenderStepped:Connect(function()
		local ok, err = pcall(refresh, u)
		if not ok then
			warn(`[FireCallController] {err}`)
			pcall(hide, u)
		end
	end)
end

function FireCallController:IsActive(): boolean
	return active
end

function FireCallController:_state(): { [string]: any }
	local u = ui
	return {
		active = active,
		target = if target then target:GetFullName() else nil,
		dist = if u then u.dist.Text else nil,
		edge = if u then u.edge.Visible else nil,
		arrow = if u then u.board.Enabled else nil,
	}
end

return FireCallController
