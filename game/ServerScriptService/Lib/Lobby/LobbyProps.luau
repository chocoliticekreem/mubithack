--!strict
-- LobbyProps [owner: G3]. Builds the station lobby furniture LobbyService needs when StationBuilder
-- doesn't provide it: the big Mission Board (tag MissionBoard, SurfaceGui + ProximityPrompt +
-- ClickDetector) on the front plaza, N glowing queue pads (tag SquadPad, attr PadId) in front of it with
-- a BillboardGui each, and the "please do not ring" bell on the west lawn. Also renders the board
-- rows and pad billboards. Called only from LobbyService:Start (never at require time).
--
--   local built = LobbyProps.build(parent, stationOrigin, padCount)
--   LobbyProps.renderBoard(built.boardGui, rows)   -- rows: { BoardRow }
--   LobbyProps.renderPad(built.pads[i], view)      -- view: PadView
--   LobbyProps.setLocked(built.pads[i], on)         -- LOCKED IN: the pad's fence goes solid + the glow
--                                                     column pulses (LobbyService, last 5 s of a countdown)
-- Coordinates are StationBuilder's local studs (station v2): the plaza in front of the west wing is
-- X -60..-22, Z 30..64 (the bays' apron X -22..62 stays clear for the trucks). The station origin is
-- the station model's "StationOrigin" attribute when present (StationBuilder places the station at
-- CityConfig.StationOrigin), else the origin LobbyService passes.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)

local LobbyProps = {}

local APRON_Y = 0.5
local LAWN_Y = 0.3

local hex = Color3.fromHex
local C = {
	Red = hex("C8232B"),
	DarkRed = hex("8E1A1F"),
	Cream = hex("FFF1D6"),
	Ink = hex("1A1210"),
	Wood = hex("8A4A28"),
	Brass = hex("C89A3C"),
	Steel = hex("4A4650"),
	Concrete = hex("6E6862"),
	Board = hex("22303A"),
	Yellow = hex("E3B23C"),
	Green = hex("6BCB5A"),
	Grey = hex("8C8A88"),
	PadIdle = hex("4FB3D9"),
	PadForming = hex("E3B23C"),
	PadHot = hex("FF3B2A"),
}
LobbyProps.Colors = C

export type PadRec = {
	padId: number,
	part: BasePart, -- tagged SquadPad
	ring: BasePart,
	light: PointLight,
	title: TextLabel,
	mission: TextLabel,
	ready: TextLabel,
	count: TextLabel,
	names: TextLabel,
	prompt: ProximityPrompt,
	fence: { BasePart }, -- invisible wall ring, CanCollide only while locked
	lockGlow: BasePart, -- see-through neon column, shown (pulsing) while locked
	lockTween: Tween?,
}

export type Built = {
	model: Model,
	board: BasePart,
	boardGui: SurfaceGui,
	prompt: ProximityPrompt,
	pads: { PadRec },
	bell: BasePart,
	bellPrompt: ProximityPrompt,
	siren: Sound,
}

export type BoardRow = {
	id: string,
	title: string,
	blurb: string,
	players: string,
	difficulty: number,
	enabled: boolean,
	pads: string, -- "PAD 1, 3" or ""
}

export type PadView = {
	mission: string,
	ready: string,
	count: string,
	names: string,
	color: Color3,
	hot: boolean,
}

local function part(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, opts: { [string]: any }?): Part
	local o = opts or {}
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = o.collide ~= false
	p.CanTouch = o.touch == true
	p.CanQuery = o.query ~= false
	p.CastShadow = o.shadow ~= false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = o.material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if o.shape then
		p.Shape = o.shape
	end
	if o.transparency then
		p.Transparency = o.transparency
	end
	p.Parent = parent
	return p
end

-- A flat disc lying on the ground: Roblox cylinders run along X, so roll them 90 degrees.
local function disc(parent: Instance, name: string, at: CFrame, dia: number, thick: number, color: Color3, opts: { [string]: any }?): Part
	local o = table.clone(opts or {})
	o.shape = Enum.PartType.Cylinder
	return part(parent, name, at * CFrame.Angles(0, 0, math.rad(90)), Vector3.new(thick, dia, dia), color, o)
end

local function text(parent: Instance, name: string, pos: UDim2, size: UDim2, str: string, color: Color3, font: Enum.Font, xAlign: Enum.TextXAlignment?): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.Position = pos
	t.Size = size
	t.Text = str
	t.TextColor3 = color
	t.Font = font
	t.TextScaled = true
	t.TextWrapped = true
	t.TextXAlignment = xAlign or Enum.TextXAlignment.Center
	t.Parent = parent
	return t
end

local function stroke(t: TextLabel, thickness: number)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = C.Ink
	s.Parent = t
end

------------------------------------------------------------------ board

local function buildBoard(model: Model, O: CFrame, pps: number): (BasePart, SurfaceGui, ProximityPrompt)
	local W, Hh = 12, 8.5
	local cx, cz = -40, 38
	local cy = APRON_Y + 1.5 + Hh / 2
	local face = O * CFrame.lookAt(Vector3.new(cx, cy, cz), Vector3.new(cx, cy, cz + 1))
	local frame = part(model, "BoardFrame", face * CFrame.new(0, 0, 0.35), Vector3.new(W + 0.8, Hh + 0.8, 0.4), C.Wood)
	frame.Material = Enum.Material.Wood
	for _, dx in { -W / 2 + 0.6, W / 2 - 0.6 } do
		local postH = cy + Hh / 2 - APRON_Y
		part(model, "BoardPost", O * CFrame.new(cx + dx, APRON_Y + postH / 2, cz - 0.7), Vector3.new(0.6, postH, 0.6), C.Steel)
	end
	part(model, "BoardHeader", face * CFrame.new(0, Hh / 2 + 0.9, 0.2), Vector3.new(W * 0.7, 1.4, 0.4), C.Red, { material = Enum.Material.Neon })
	local board = part(model, "MissionBoard", face, Vector3.new(W, Hh, 0.3), C.Board)
	CollectionService:AddTag(board, Names.Tag.MissionBoard)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "BoardGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pps
	gui.LightInfluence = 0
	gui.Brightness = 1.4
	gui.MaxDistance = 220
	gui.Parent = board

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BoardPrompt"
	prompt.ActionText = "Pick a call"
	prompt.ObjectText = "Mission Board"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 16
	prompt.RequiresLineOfSight = false
	prompt.Parent = board

	local click = Instance.new("ClickDetector")
	click.Name = "BoardClick"
	click.MaxActivationDistance = 60
	click.Parent = board

	-- Header label above the board (separate part so the board canvas is all mission rows).
	local header = model:FindFirstChild("BoardHeader") :: BasePart
	local hg = Instance.new("SurfaceGui")
	hg.Face = Enum.NormalId.Front
	hg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	hg.PixelsPerStud = pps
	hg.LightInfluence = 0
	hg.Parent = header
	local ht = text(hg, "Title", UDim2.fromScale(0, 0.05), UDim2.fromScale(1, 0.9), "DISPATCH - CALLS TODAY", C.Cream, Enum.Font.LuckiestGuy)
	stroke(ht, 3)
	return board, gui, prompt
end

function LobbyProps.renderBoard(gui: SurfaceGui, rows: { BoardRow })
	gui:ClearAllChildren()
	local list = Instance.new("Frame")
	list.Name = "Rows"
	list.BackgroundTransparency = 1
	list.Size = UDim2.fromScale(1, 1)
	list.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.02, 0)
	pad.PaddingRight = UDim.new(0.02, 0)
	pad.PaddingTop = UDim.new(0.015, 0)
	pad.Parent = list
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0.008, 0)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	local n = math.max(#rows, 1)
	local h = (0.97 - 0.008 * n) / n
	for i, r in rows do
		local f = Instance.new("Frame")
		f.Name = r.id
		f.LayoutOrder = i
		f.Size = UDim2.fromScale(1, h)
		f.BackgroundColor3 = if r.pads ~= "" then C.DarkRed elseif r.enabled then hex("2E4452") else hex("1C2329")
		f.BorderSizePixel = 0
		f.Parent = list
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.18, 0)
		corner.Parent = f
		local dim = if r.enabled then C.Cream else C.Grey
		text(f, "Title", UDim2.fromScale(0.02, 0.04), UDim2.fromScale(0.36, 0.52), r.title, if r.enabled then C.Yellow else C.Grey, Enum.Font.FredokaOne, Enum.TextXAlignment.Left)
		text(f, "Blurb", UDim2.fromScale(0.02, 0.56), UDim2.fromScale(0.62, 0.4), r.blurb, dim, Enum.Font.Gotham, Enum.TextXAlignment.Left)
		text(f, "Players", UDim2.fromScale(0.40, 0.06), UDim2.fromScale(0.2, 0.42), r.players, dim, Enum.Font.GothamBold, Enum.TextXAlignment.Left)
		local chilis = string.rep("*", r.difficulty) .. string.rep("-", 5 - r.difficulty)
		text(f, "Difficulty", UDim2.fromScale(0.64, 0.06), UDim2.fromScale(0.16, 0.42), `HEAT {chilis}`, if r.difficulty >= 4 then hex("FF7A3A") else dim, Enum.Font.GothamBold, Enum.TextXAlignment.Left)
		local status = if not r.enabled then "COMING SOON" elseif r.pads ~= "" then r.pads else "ON CALL"
		local st = text(f, "Status", UDim2.fromScale(0.80, 0.12), UDim2.fromScale(0.18, 0.76), status, if not r.enabled then C.Grey elseif r.pads ~= "" then C.Cream else C.Green, Enum.Font.LuckiestGuy)
		if r.enabled then
			stroke(st, 1.5)
		end
	end
end

------------------------------------------------------------------ pads

local function buildPad(model: Model, O: CFrame, padId: number, x: number, z: number): PadRec
	local base = O * CFrame.new(x, APRON_Y, z)
	local ring = disc(model, `PadRing{padId}`, base * CFrame.new(0, 0.08, 0), 15.4, 0.16, C.PadIdle, { material = Enum.Material.Neon, collide = false, shadow = false })
	local pad = disc(model, `SquadPad{padId}`, base * CFrame.new(0, 0.14, 0), 14, 0.2, C.Concrete, { touch = false })
	pad:SetAttribute(Names.Attr.PadId, padId)
	CollectionService:AddTag(pad, Names.Tag.SquadPad)
	local num = disc(model, `PadNumber{padId}`, base * CFrame.new(0, 0.2, 0), 4, 0.2, C.Red, { collide = false })
	num.Material = Enum.Material.SmoothPlastic

	local light = Instance.new("PointLight")
	light.Color = C.PadIdle
	light.Range = 20
	light.Brightness = 1.5
	light.Parent = ring

	local bb = Instance.new("BillboardGui")
	bb.Name = "PadBillboard"
	-- sized in studs (it is a sign over the pad, not a HUD element) and kept small + high so standing
	-- on the pad doesn't fill your screen; readable across the apron, gone from the far side of the bay
	bb.Size = UDim2.new(6, 0, 3.75, 0)
	-- hung on an attachment 8.5 studs straight up: the pad is a cylinder lying on its side, and an
	-- offset on the part itself left the sign at floor level on the pad's edge
	local anchor = Instance.new("Attachment")
	anchor.Name = "PadBillboardAnchor"
	anchor.Parent = pad
	anchor.WorldCFrame = CFrame.new(pad.Position + Vector3.new(0, 8.5, 0))
	bb.Adornee = anchor
	bb.MaxDistance = 90
	bb.LightInfluence = 0
	bb.Parent = pad
	local title = text(bb, "Pad", UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.16), `PAD {padId}`, C.Cream, Enum.Font.LuckiestGuy)
	stroke(title, 2)
	local mission = text(bb, "Mission", UDim2.fromScale(0, 0.16), UDim2.fromScale(1, 0.16), "", C.Yellow, Enum.Font.FredokaOne)
	stroke(mission, 2)
	local ready = text(bb, "Ready", UDim2.fromScale(0, 0.32), UDim2.fromScale(1, 0.16), "", C.Cream, Enum.Font.LuckiestGuy)
	stroke(ready, 2)
	local count = text(bb, "Count", UDim2.fromScale(0, 0.48), UDim2.fromScale(1, 0.34), "", C.Cream, Enum.Font.LuckiestGuy)
	stroke(count, 3)
	local names = text(bb, "Names", UDim2.fromScale(0, 0.84), UDim2.fromScale(1, 0.14), "", C.Cream, Enum.Font.GothamBold)
	stroke(names, 1)

	-- LOCK IN: a ring of invisible walls just outside the pad (off until the last 5 s) and a see-through
	-- glowing column over it that pulses while the squad is locked in
	local fence: { BasePart } = {}
	local fenceR, segs = 7.7, 18
	local segW = 2 * math.pi * fenceR / segs + 0.5
	for k = 1, segs do
		local a = (k - 0.5) * 2 * math.pi / segs
		local cf = base * CFrame.Angles(0, a, 0) * CFrame.new(0, 7, -fenceR)
		local w = part(model, `PadFence{padId}`, cf, Vector3.new(segW, 14, 0.6), C.PadHot, { collide = false, query = false, shadow = false, transparency = 1 })
		table.insert(fence, w)
	end
	local glow = part(model, `PadLockGlow{padId}`, base * CFrame.new(0, 3.2, 0) * CFrame.Angles(0, 0, math.rad(90)), Vector3.new(6.2, 15.6, 15.6), C.PadHot, {
		shape = Enum.PartType.Cylinder,
		material = Enum.Material.ForceField,
		collide = false,
		query = false,
		shadow = false,
		transparency = 1,
	})

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PadPrompt"
	prompt.ActionText = "Change call"
	prompt.ObjectText = `Pad {padId}`
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = pad

	return {
		padId = padId,
		part = pad,
		ring = ring,
		light = light,
		title = title,
		mission = mission,
		ready = ready,
		count = count,
		names = names,
		prompt = prompt,
		fence = fence,
		lockGlow = glow,
		lockTween = nil,
	}
end

function LobbyProps.setLocked(rec: PadRec, on: boolean)
	for _, w in rec.fence do
		w.CanCollide = on
	end
	if rec.lockTween then
		rec.lockTween:Cancel()
		rec.lockTween = nil
	end
	local g = rec.lockGlow
	if on then
		g.Transparency = 0.15
		local tw = TweenService:Create(g, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Transparency = 0.7 })
		tw:Play()
		rec.lockTween = tw
	else
		g.Transparency = 1
	end
end

function LobbyProps.renderPad(rec: PadRec, view: PadView)
	rec.mission.Text = view.mission
	rec.ready.Text = view.ready
	rec.count.Text = view.count
	rec.count.TextColor3 = if view.hot then C.PadHot else C.Cream
	rec.names.Text = view.names
	rec.ring.Color = view.color
	rec.light.Color = view.color
	rec.light.Brightness = if view.hot then 4 else 1.5
end

------------------------------------------------------------------ bell

local function buildBell(model: Model, O: CFrame): (BasePart, ProximityPrompt)
	local x, z = -68, 40
	local top = LAWN_Y + 9
	part(model, "BellPostL", O * CFrame.new(x - 2, LAWN_Y + 4.5, z), Vector3.new(0.6, 9, 0.6), C.Wood)
	part(model, "BellPostR", O * CFrame.new(x + 2, LAWN_Y + 4.5, z), Vector3.new(0.6, 9, 0.6), C.Wood)
	part(model, "BellYoke", O * CFrame.new(x, top, z), Vector3.new(5, 0.6, 0.8), C.Wood)
	local bell = part(model, "Bell", O * CFrame.new(x, top - 1.6, z), Vector3.new(2.6, 2.6, 2.6), C.Brass, { shape = Enum.PartType.Ball, material = Enum.Material.Metal })
	part(model, "BellLip", O * CFrame.new(x, top - 2.7, z), Vector3.new(3, 0.4, 3), C.Brass, { material = Enum.Material.Metal, collide = false })
	local sign = part(model, "BellSign", O * CFrame.new(x, LAWN_Y + 3, z + 0.5), Vector3.new(3.6, 1.6, 0.2), C.Cream)
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Back -- +Z, toward the street
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 60
	sg.Parent = sign
	text(sg, "Text", UDim2.fromScale(0.04, 0.05), UDim2.fromScale(0.92, 0.9), "PLEASE DO NOT\nRING THE BELL", C.Red, Enum.Font.LuckiestGuy)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BellPrompt"
	prompt.ActionText = "Ring the bell"
	prompt.ObjectText = "Bell"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = bell
	return bell, prompt
end

------------------------------------------------------------------ entry

function LobbyProps.padCenters(padCount: number): { Vector3 }
	local out = {}
	local spacing = 19 -- 14-stud pads: room for a squad of 4 on each
	for i = 1, padCount do
		local x = -40 + (i - (padCount + 1) / 2) * spacing
		table.insert(out, Vector3.new(x, APRON_Y, 51))
	end
	return out
end

function LobbyProps.build(parent: Instance, origin: CFrame, padCount: number, pps: number?): Built
	local stationOrigin = parent:GetAttribute("StationOrigin")
	if typeof(stationOrigin) == "CFrame" then
		origin = stationOrigin
	end
	local model = Instance.new("Model")
	model.Name = "Lobby"
	local board, gui, prompt = buildBoard(model, origin, pps or 50)
	local pads: { PadRec } = {}
	for i, c in LobbyProps.padCenters(padCount) do
		pads[i] = buildPad(model, origin, i, c.X, c.Z)
	end
	local bell, bellPrompt = buildBell(model, origin)
	local siren = Instance.new("Sound")
	siren.Name = "Siren"
	siren.Volume = 0.8
	siren.RollOffMaxDistance = 200
	siren.Parent = board
	model.Parent = parent
	return {
		model = model,
		board = board,
		boardGui = gui,
		prompt = prompt,
		pads = pads,
		bell = bell,
		bellPrompt = bellPrompt,
		siren = siren,
	}
end

return LobbyProps
