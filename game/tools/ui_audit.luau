--!nocheck
-- ui_audit.luau: HUD overlap / clipping / text-fit / flicker audit for the live client.
-- Run it in the Client datamodel of a running playtest (Studio MCP execute_luau, or `forge ui-audit`).
-- It returns one JSON string:
--   { viewport, inset, widgets = n, overlaps = [...], offscreen = [...], topbar = [...], textOverflow = [...],
--     flicker = [...], counts = { overlaps, offscreen, topbar, textOverflow, flicker } }
--
-- A "widget" is the first GuiObject on the way down from a ScreenGui that actually draws something
-- (a background, text or an image). Fully transparent containers are walked through; a widget's own
-- children are part of it and never compared with it. Full-screen layers (vignettes, backdrops,
-- overlays) are not widgets. A dimmed backdrop (full-screen, mostly opaque) hides every widget of a
-- lower DisplayOrder, so a modal over the HUD is not an overlap. World-tracked markers are listed apart.
--
-- Pairs of widgets whose rects intersect by more than TOL px on both axes are overlaps, unless both
-- sit in the same ScreenGui and one of them names the other in its "LayoutAllowOverlap" attribute.
local OPTS = { tol = 4, flickerSeconds = 1.5, minSize = 6 } -- forge ui-audit may rewrite this line

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local pg = player:WaitForChild("PlayerGui")
local vp = workspace.CurrentCamera.ViewportSize
local topbar = GuiService.TopbarInset -- Rect in screen space: the free part of the top bar
-- AbsolutePosition is measured from the top-left of the inset area (below the top bar) for EVERY
-- ScreenGui, IgnoreGuiInset or not, so screen space = AbsolutePosition + inset.
local inset = GuiService:GetGuiInset()

-- ScreenGuis we never audit (Roblox's own, debug, or the mouse unlock helper).
local SKIP_GUIS = { BubbleChat = true, Chat = true, Freecam = true, MenuMouse = true }
-- ScreenGuis with a negative DisplayOrder are screen effects under the HUD (vignettes, smoke, sweat,
-- the gas mask), never widgets. Anything with the attribute UiAuditIgnore = true is skipped too.
-- World-tracked screen markers are audited like any widget (HudLayout.clear keeps them off the HUD);
-- OPTS.noMarkers = true lists them apart instead.
local WORLD_GUIS = if OPTS.noMarkers then { HudMarkers = true } else {}

local function shown(o: Instance): boolean
	local cur = o
	while cur and cur ~= pg do
		if cur:IsA("GuiObject") and not cur.Visible then
			return false
		end
		if cur:IsA("LayerCollector") and not cur.Enabled then
			return false
		end
		if cur:IsA("CanvasGroup") and cur.GroupTransparency >= 0.99 then
			return false
		end
		cur = cur.Parent
	end
	return true
end

local function draws(o: GuiObject): boolean
	-- confetti / sparks: small rotated childless bits
	if o.Rotation % 360 ~= 0 and o.AbsoluteSize.X < 16 and o.AbsoluteSize.Y < 16 and #o:GetChildren() == 0 then
		return false
	end
	-- a gradient fade with nothing inside (vignette edges, glows) is a screen effect, not a widget
	if o:IsA("Frame") and o:FindFirstChildOfClass("UIGradient") and not o:FindFirstChildWhichIsA("GuiObject") then
		local g = o:FindFirstChildOfClass("UIGradient") :: UIGradient
		local kp = g.Transparency.Keypoints
		if kp[#kp].Value >= 0.95 or kp[1].Value >= 0.95 then
			return false
		end
	end
	if o.BackgroundTransparency < 0.95 then
		return true
	end
	if (o:IsA("TextLabel") or o:IsA("TextButton") or o:IsA("TextBox")) and o.Text ~= "" and o.TextTransparency < 0.95 then
		return true
	end
	if (o:IsA("ImageLabel") or o:IsA("ImageButton")) and o.Image ~= "" and o.ImageTransparency < 0.95 then
		return true
	end
	if o:IsA("ViewportFrame") then
		return true
	end
	-- a transparent frame with a visible UIStroke border still draws a box
	local s = o:FindFirstChildOfClass("UIStroke")
	if s and s.Enabled and s.Transparency < 0.95 and s.ApplyStrokeMode == Enum.ApplyStrokeMode.Border then
		return true
	end
	return false
end

local function path(o: Instance): string
	local parts = {}
	local cur = o
	while cur and cur ~= pg do
		table.insert(parts, 1, cur.Name)
		cur = cur.Parent
	end
	return table.concat(parts, ".")
end

-- screen rect {x0, y0, x1, y1}
local function rect(o: GuiObject, gui: ScreenGui)
	local p, s = o.AbsolutePosition, o.AbsoluteSize
	return { p.X + inset.X, p.Y + inset.Y, p.X + inset.X + s.X, p.Y + inset.Y + s.Y }
end

local function isFull(r): boolean
	return (r[3] - r[1]) >= vp.X * 0.97 and (r[4] - r[2]) >= vp.Y * 0.9
end

local widgets = {}
local markers = 0
local backdrops = {} -- display orders that carry a dim full-screen backdrop

-- panel: the first non-full-screen GuiObject under the ScreenGui (or under a full-screen layer).
-- Widgets of the same panel are one composed thing (a minimap and its compass, hotbar tiles) and are
-- not compared with each other.
-- clip: the visible rect of the nearest ClipsDescendants ancestor (scrolling lists, masks); what is
-- scrolled out of it is not on screen.
local function clipTo(r, clip)
	if not clip then
		return r
	end
	return { math.max(r[1], clip[1]), math.max(r[2], clip[2]), math.min(r[3], clip[3]), math.min(r[4], clip[4]) }
end

-- the ZIndex of o's top-level ancestor inside its ScreenGui (sibling z-order between panels)
local function topZ(o: Instance, gui: ScreenGui): number
	local cur = o
	while cur.Parent and cur.Parent ~= gui do
		cur = cur.Parent
	end
	return if cur:IsA("GuiObject") then cur.ZIndex else 0
end

-- a text-only label (no background, no border) only covers its rendered text, not its whole box
local function textRect(c: GuiObject, r)
	if not (c:IsA("TextLabel") or c:IsA("TextButton")) or c.BackgroundTransparency < 0.95 then
		return r
	end
	local s = c:FindFirstChildOfClass("UIStroke")
	if s and s.ApplyStrokeMode == Enum.ApplyStrokeMode.Border and s.Transparency < 0.95 then
		return r
	end
	local tb = c.TextBounds
	local w, h = math.min(tb.X, r[3] - r[1]), math.min(tb.Y, r[4] - r[2])
	local x0 = if c.TextXAlignment == Enum.TextXAlignment.Left then r[1]
		elseif c.TextXAlignment == Enum.TextXAlignment.Right then r[3] - w
		else (r[1] + r[3] - w) / 2
	local y0 = if c.TextYAlignment == Enum.TextYAlignment.Top then r[2]
		elseif c.TextYAlignment == Enum.TextYAlignment.Bottom then r[4] - h
		else (r[2] + r[4] - h) / 2
	return { x0, y0, x0 + w, y0 + h }
end

local function walk(o: Instance, gui: ScreenGui, panel: Instance?, clip)
	for _, c in o:GetChildren() do
		if c:IsA("GuiObject") and c.Visible and c:GetAttribute("UiAuditIgnore") ~= true then
			local r = clipTo(rect(c, gui), clip)
			local cClip = if c.ClipsDescendants or c:IsA("ScrollingFrame") then r else clip
			local cPanel = panel or c
			local w, h = r[3] - r[1], r[4] - r[2]
			if isFull(r) then
				if (c:IsA("Frame") or c:IsA("TextButton")) and c.BackgroundTransparency <= 0.6 then
					table.insert(backdrops, { order = gui.DisplayOrder, gui = gui, z = topZ(c, gui), path = path(c) })
				end
				walk(c, gui, nil, cClip) -- a full-screen layer: its children are the panels
			elseif draws(c) then
				if w >= OPTS.minSize and h >= OPTS.minSize then
					table.insert(widgets, {
						inst = c,
						gui = gui,
						r = textRect(c, r),
						path = path(c),
						order = gui.DisplayOrder,
						panel = cPanel,
						z = topZ(c, gui),
					})
				end
			else
				walk(c, gui, cPanel, cClip)
			end
		elseif c:IsA("Folder") then
			walk(c, gui, panel, clip)
		end
	end
end

for _, gui in pg:GetChildren() do
	if gui:IsA("ScreenGui") and gui.Enabled and not SKIP_GUIS[gui.Name] and gui.DisplayOrder >= 0
		and gui:GetAttribute("UiAuditIgnore") ~= true then
		if WORLD_GUIS[gui.Name] then
			for _, d in gui:GetDescendants() do
				if d:IsA("GuiObject") and d.Visible and shown(d) then
					markers += 1
				end
			end
		else
			walk(gui, gui, nil)
		end
	end
end

-- drop widgets under a dim backdrop: one in a higher-DisplayOrder gui, or in the same gui with a higher
-- top-level ZIndex (a modal's dim sits just under its panel and over the gui's own chips)
local function isCovered(w): boolean
	for _, b in backdrops do
		if b.order > w.order or (b.gui == w.gui and b.z > w.z) then
			return true
		end
	end
	return false
end
local live = {}
local covered = 0
for _, w in widgets do
	if isCovered(w) then
		covered += 1
	elseif shown(w.inst) then
		table.insert(live, w)
	end
end

local function allowed(a, b): boolean
	local function names(x, y)
		local allow = x.inst:GetAttribute("LayoutAllowOverlap")
		if type(allow) ~= "string" then
			return false
		end
		for token in string.gmatch(allow, "[^,%s]+") do
			if y.inst.Name == token or y.gui.Name == token then
				return true
			end
		end
		return false
	end
	return names(a, b) or names(b, a)
end

local function fmt(r)
	return string.format("%d,%d %dx%d", r[1], r[2], r[3] - r[1], r[4] - r[2])
end

local overlaps = {}
for i = 1, #live do
	local a = live[i]
	for j = i + 1, #live do
		local b = live[j]
		if a.panel ~= b.panel and not (a.inst:IsAncestorOf(b.inst) or b.inst:IsAncestorOf(a.inst)) then
			local ix = math.min(a.r[3], b.r[3]) - math.max(a.r[1], b.r[1])
			local iy = math.min(a.r[4], b.r[4]) - math.max(a.r[2], b.r[2])
			if ix > OPTS.tol and iy > OPTS.tol and not allowed(a, b) then
				table.insert(overlaps, {
					a = a.path,
					b = b.path,
					ar = fmt(a.r),
					br = fmt(b.r),
					px = string.format("%dx%d", ix, iy),
				})
			end
		end
	end
end

local offscreen, underTopbar = {}, {}
for _, w in live do
	local r = w.r
	if r[1] < -OPTS.tol or r[2] < -OPTS.tol or r[3] > vp.X + OPTS.tol or r[4] > vp.Y + OPTS.tol then
		table.insert(offscreen, { w = w.path, r = fmt(r) })
	end
	-- Roblox's own top-bar buttons: left of TopbarInset.Min.X and right of TopbarInset.Max.X, above its bottom.
	local tbBottom = topbar.Max.Y
	if r[2] < tbBottom - OPTS.tol then
		if r[1] < topbar.Min.X - OPTS.tol or r[3] > topbar.Max.X + OPTS.tol then
			table.insert(underTopbar, { w = w.path, r = fmt(r) })
		end
	end
end

local overflow = {}
for _, w in live do
	local list = w.inst:GetDescendants()
	table.insert(list, w.inst)
	for _, d in list do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and not d.TextScaled and d.Text ~= ""
			and d.TextTransparency < 0.95 and shown(d) and not d.TextFits then
			-- AutomaticSize grows the box, a scroll list scrolls, and TextTruncate ends in "..." on purpose
			if d.AutomaticSize == Enum.AutomaticSize.None and d.TextTruncate == Enum.TextTruncate.None
				and not d:FindFirstAncestorWhichIsA("ScrollingFrame") then
				table.insert(overflow, { t = path(d), text = string.sub(d.Text, 1, 40), size = tostring(d.AbsoluteSize) })
			end
		end
	end
end

-- flicker: count Visible toggles on every GuiObject for a short window
local flicker = {}
if OPTS.flickerSeconds > 0 then
	local counts, conns = {}, {}
	for _, gui in pg:GetChildren() do
		if gui:IsA("ScreenGui") and not SKIP_GUIS[gui.Name] and not WORLD_GUIS[gui.Name] then
			table.insert(conns, gui:GetPropertyChangedSignal("Enabled"):Connect(function()
				counts[gui] = (counts[gui] or 0) + 1
			end))
			for _, d in gui:GetDescendants() do
				if d:IsA("GuiObject") then
					table.insert(conns, d:GetPropertyChangedSignal("Visible"):Connect(function()
						counts[d] = (counts[d] or 0) + 1
					end))
				end
			end
		end
	end
	local t0 = os.clock()
	while os.clock() - t0 < OPTS.flickerSeconds do
		RunService.Heartbeat:Wait()
	end
	for _, c in conns do
		c:Disconnect()
	end
	for inst, n in counts do
		if n >= 4 then
			table.insert(flicker, { w = path(inst), toggles = n })
		end
	end
end

local report = {
	viewport = string.format("%dx%d", vp.X, vp.Y),
	inset = string.format("%d,%d", inset.X, inset.Y),
	topbar = string.format("%d..%d x %d", topbar.Min.X, topbar.Max.X, topbar.Max.Y),
	widgets = #live,
	covered = covered,
	markers = markers,
	overlaps = overlaps,
	offscreen = offscreen,
	underTopbar = underTopbar,
	textOverflow = overflow,
	flicker = flicker,
	counts = {
		overlaps = #overlaps,
		offscreen = #offscreen,
		underTopbar = #underTopbar,
		textOverflow = #overflow,
		flicker = #flicker,
	},
}
if OPTS.list then
	local l = {}
	for _, w in live do
		table.insert(l, w.path .. " @ " .. fmt(w.r) .. " d" .. w.order)
	end
	report.list = l
end
return HttpService:JSONEncode(report)
