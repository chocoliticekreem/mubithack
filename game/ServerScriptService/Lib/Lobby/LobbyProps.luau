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
-- Coordinates are StationBuilder's local studs (station v2). The front yard (StationBuilder "Plaza") is
-- X -104..-22, Z 30..64; the bays' apron X -22..62 stays clear for the trucks. One simple line from the
-- station to the street (LobbyProps.Layout):
--   facade + LOCKER door (x -53)  ->  START row (spawns, Z 36.5)  ->  3 big pads (Z 50, 26 apart, 10-stud
--   walkways between)  ->  the PICK A MISSION board at the street edge (Z 62.5, facing the station).
-- So a player spawns facing the pads, the board is straight ahead behind them, and one step forward is a
-- pad. The station origin is the station model's "StationOrigin" attribute when present (StationBuilder
-- places the station at CityConfig.StationOrigin), else the origin LobbyService passes.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)

local LobbyProps = {}

local APRON_Y = 0.5

-- Lobby layout (station-local studs). StationBuilder's OutsideSpawns + front-yard paving use the same
-- numbers (keep them in step): spawns on the START row at StartZ, pads centred on PadZ.
LobbyProps.Layout = table.freeze({
	CenterX = -68, -- the middle pad
	BoardX = -55, -- the board: between pads 2 and 3, on the LOCKER door's line (x -53), so no pad sign hides it
	PadZ = 50,
	PadSpacing = 26, -- 16-stud pads: 10-stud walkways between them
	PadDia = 16, -- room for a squad of 8 (LobbyConfig.PadRadius 8.5 counts as "on")
	StartZ = 36.5,
	BoardZ = 62.5,
	BellX = -110,
	BellZ = 40,
})
local L = LobbyProps.Layout

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
	-- the big PICK A MISSION board at the street end of the yard, facing the station (and the START row):
	-- you see it the moment you spawn, straight ahead past the pads
	local W, Hh = 16, 10
	local cx, cz = L.BoardX, L.BoardZ
	local cy = APRON_Y + 2 + Hh / 2
	local face = O * CFrame.lookAt(Vector3.new(cx, cy, cz), Vector3.new(cx, cy, cz - 1))
	local frame = part(model, "BoardFrame", face * CFrame.new(0, 0, 0.35), Vector3.new(W + 1, Hh + 1, 0.4), C.Wood)
	frame.Material = Enum.Material.Wood
	local postH = cy + Hh / 2 - APRON_Y
	for _, dx in { -W / 2 + 0.8, W / 2 - 0.8 } do
		part(model, "BoardPost", face * CFrame.new(dx, APRON_Y + postH / 2 - cy, 0.8), Vector3.new(0.8, postH, 0.8), C.Steel)
	end
	part(model, "BoardHeader", face * CFrame.new(0, Hh / 2 + 1.6, 0.2), Vector3.new(W * 0.8, 2.4, 0.4), C.Red, { material = Enum.Material.Neon })
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
	prompt.ActionText = "Pick a mission"
	prompt.ObjectText = "Mission Board"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 18
	prompt.RequiresLineOfSight = false
	prompt.Parent = board

	local click = Instance.new("ClickDetector")
	click.Name = "BoardClick"
	click.MaxActivationDistance = 80
	click.Parent = board

	-- Header label above the board (separate part so the board canvas is all mission rows).
	local header = model:FindFirstChild("BoardHeader") :: BasePart
	local hg = Instance.new("SurfaceGui")
	hg.Face = Enum.NormalId.Front
	hg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	hg.PixelsPerStud = pps
	hg.LightInfluence = 0
	hg.Parent = header
	local ht = text(hg, "Title", UDim2.fromScale(0, 0.05), UDim2.fromScale(1, 0.9), "PICK A MISSION", C.Cream, Enum.Font.LuckiestGuy)
	stroke(ht, 4)
	-- the street side of the board: who we are (it's the back of a sign, not a blank slab)
	local bg = Instance.new("SurfaceGui")
	bg.Face = Enum.NormalId.Back
	bg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	bg.PixelsPerStud = 20
	bg.LightInfluence = 0.4
	bg.Parent = frame
	local bt = text(bg, "Back", UDim2.fromScale(0.05, 0.2), UDim2.fromScale(0.9, 0.6), "FIRE STATION 67", C.Cream, Enum.Font.LuckiestGuy)
	stroke(bt, 3)
	return board, gui, prompt
end

-- A grid of big call cards (3 across): just the call's name and one status word, readable from the
-- START row. The blurb / players / heat live in the picker (LobbyController), not on the wall.
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
	pad.PaddingTop = UDim.new(0.025, 0)
	pad.PaddingBottom = UDim.new(0.025, 0)
	pad.Parent = list
	local cols = 3
	local n = math.max(#rows, 1)
	local lines = math.ceil(n / cols)
	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.fromScale(0.015, 0.02)
	grid.CellSize = UDim2.fromScale((1 - 0.015 * (cols - 1)) / cols, (1 - 0.02 * (lines - 1)) / lines)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = list
	for i, r in rows do
		local f = Instance.new("Frame")
		f.Name = r.id
		f.LayoutOrder = i
		f.BackgroundColor3 = if r.pads ~= "" then C.DarkRed elseif r.enabled then hex("2E4452") else hex("1C2329")
		f.BorderSizePixel = 0
		f.Parent = list
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.2, 0)
		corner.Parent = f
		local tt = text(f, "Title", UDim2.fromScale(0.04, 0.04), UDim2.fromScale(0.92, 0.6), r.title, if r.enabled then C.Yellow else C.Grey, Enum.Font.LuckiestGuy)
		if r.enabled then
			stroke(tt, 1.5)
		end
		local status = if not r.enabled then "SOON" elseif r.pads ~= "" then r.pads else "ON CALL"
		text(f, "Status", UDim2.fromScale(0.04, 0.64), UDim2.fromScale(0.92, 0.32), status, if not r.enabled then C.Grey elseif r.pads ~= "" then C.Cream else C.Green, Enum.Font.LuckiestGuy)
	end
end

------------------------------------------------------------------ pads

local function buildPad(model: Model, O: CFrame, padId: number, x: number, z: number): PadRec
	local base = O * CFrame.new(x, APRON_Y, z)
	local D = L.PadDia
	local ring = disc(model, `PadRing{padId}`, base * CFrame.new(0, 0.08, 0), D + 1.6, 0.16, C.PadIdle, { material = Enum.Material.Neon, collide = false, shadow = false })
	local pad = disc(model, `SquadPad{padId}`, base * CFrame.new(0, 0.14, 0), D, 0.2, C.Concrete, { touch = false })
	pad:SetAttribute(Names.Attr.PadId, padId)
	CollectionService:AddTag(pad, Names.Tag.SquadPad)
	local num = disc(model, `PadNumber{padId}`, base * CFrame.new(0, 0.2, 0), 7, 0.2, C.Red, { collide = false })
	num.Material = Enum.Material.SmoothPlastic
	-- the pad number painted big on the red spot (readable from the START row and from above)
	local numFace = part(model, `PadNumberText{padId}`, base * CFrame.new(0, 0.32, 0), Vector3.new(6, 0.05, 6), C.Red, { collide = false, query = false, shadow = false, transparency = 1 })
	local ng = Instance.new("SurfaceGui")
	ng.Face = Enum.NormalId.Top
	ng.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	ng.PixelsPerStud = 30
	ng.LightInfluence = 0
	ng.Parent = numFace
	local nt = text(ng, "Number", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), tostring(padId), C.Cream, Enum.Font.LuckiestGuy)
	stroke(nt, 3)
	-- a GO arrow (two chevrons) on the walkway in front of the pad (station side), pointing onto it
	for k, dz in { -10.4, -12.6 } do
		for _, sx in { -1, 1 } do
			part(model, `PadArrow{padId}`, base * CFrame.new(sx * 1.25, 0.03, dz) * CFrame.Angles(0, -sx * math.rad(45), 0), Vector3.new(0.7, 0.06, 3.6), C.Yellow, {
				material = Enum.Material.Neon,
				collide = false,
				query = false,
				shadow = false,
				transparency = if k == 1 then 0 else 0.4,
			})
		end
	end

	local light = Instance.new("PointLight")
	light.Color = C.PadIdle
	light.Range = 20
	light.Brightness = 1.5
	light.Parent = ring

	local bb = Instance.new("BillboardGui")
	bb.Name = "PadBillboard"
	-- sized in studs (it is a sign over the pad, not a HUD element) and hung high so standing on the pad
	-- doesn't fill your screen (LobbyController also hides your own pad's sign). Big, few words: the call
	-- name, then STEP ON! / ROLLING IN 7, then 2/4 READY.
	bb.Size = UDim2.new(9, 0, 5.2, 0)
	-- hung on an attachment straight up: the pad is a cylinder lying on its side, and an offset on the
	-- part itself left the sign at floor level on the pad's edge
	local anchor = Instance.new("Attachment")
	anchor.Name = "PadBillboardAnchor"
	anchor.Parent = pad
	anchor.WorldCFrame = CFrame.new(pad.Position + Vector3.new(0, 10, 0))
	bb.Adornee = anchor
	bb.MaxDistance = 140
	bb.LightInfluence = 0
	bb.Parent = pad
	local title = text(bb, "Pad", UDim2.fromScale(0.3, 0), UDim2.fromScale(0.4, 0.13), `PAD {padId}`, C.Cream, Enum.Font.LuckiestGuy)
	stroke(title, 2)
	local mission = text(bb, "Mission", UDim2.fromScale(0, 0.13), UDim2.fromScale(1, 0.24), "", C.Yellow, Enum.Font.LuckiestGuy)
	stroke(mission, 3)
	local count = text(bb, "Count", UDim2.fromScale(0, 0.37), UDim2.fromScale(1, 0.3), "", C.Cream, Enum.Font.LuckiestGuy)
	stroke(count, 3)
	local ready = text(bb, "Ready", UDim2.fromScale(0, 0.67), UDim2.fromScale(1, 0.18), "", C.Cream, Enum.Font.LuckiestGuy)
	stroke(ready, 2)
	local names = text(bb, "Names", UDim2.fromScale(0, 0.86), UDim2.fromScale(1, 0.13), "", C.Cream, Enum.Font.GothamBold)
	stroke(names, 1)

	-- LOCK IN: a ring of invisible walls just outside the pad (off until the last 5 s) and a see-through
	-- glowing column over it that pulses while the squad is locked in
	local fence: { BasePart } = {}
	local fenceR, segs = D / 2 + 0.7, 20
	local segW = 2 * math.pi * fenceR / segs + 0.5
	for k = 1, segs do
		local a = (k - 0.5) * 2 * math.pi / segs
		local cf = base * CFrame.Angles(0, a, 0) * CFrame.new(0, 7, -fenceR)
		local w = part(model, `PadFence{padId}`, cf, Vector3.new(segW, 14, 0.6), C.PadHot, { collide = false, query = false, shadow = false, transparency = 1 })
		table.insert(fence, w)
	end
	local glow = part(model, `PadLockGlow{padId}`, base * CFrame.new(0, 3.2, 0) * CFrame.Angles(0, 0, math.rad(90)), Vector3.new(6.2, D + 1.6, D + 1.6), C.PadHot, {
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
	prompt.MaxActivationDistance = 13
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
	-- at the west end of the yard, off the walkways (it used to stand between the pads and the door)
	local x, z = L.BellX, L.BellZ
	local LAWN_Y = APRON_Y
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
	for i = 1, padCount do
		local x = L.CenterX + (i - (padCount + 1) / 2) * L.PadSpacing
		table.insert(out, Vector3.new(x, APRON_Y, L.PadZ))
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
