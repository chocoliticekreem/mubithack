--!strict
-- TeamBonusController [owner: Social]. Client side of TeamBonusService ("10x more fun with friends").
--   * Social/Bonus: a big punchy pop under the top HUD, "COMBO! x1.5" / "TEAMWORK!" / "SQUAD STREAK x3!",
--     with who it was with and the XP. Never covers the centre of the screen for long (1.4 s, no input).
--   * Results screen (squad calls only, 2+ players): ResultsController calls :ResultsCards(strip, payload,
--     cardW, cardH) and flips the two cards in before the award cards:
--       SQUAD     a row per player: SAVED, FIRES, COMBOS (+ the squad streak in the band)
--       BEST TEAMMATE  avatar headshot, name and why (TeamRules.best); nobody scored -> a COMBO tip
--     The rows start from the payload's stats and fill in when Social/Squad arrives (same moment).
-- Solo calls get no cards, so the results screen is unchanged for them.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local TeamRules = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Social"):WaitForChild("TeamRules") :: ModuleScript)
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript) :: any

local TeamBonusController = {}
TeamBonusController.Priority = 70

local SQUAD_W = 300
local ROW_H = 20
local GOLD = Color3.fromHex("#FFC531")

type SquadData = { instanceId: string?, rows: { TeamRules.Row }, best: number?, streak: number }
local latest: SquadData? = nil
local onSquad: ((SquadData) -> ())? = nil -- the open results screen's re-render

---------------------------------------------------------------------------------------- the pop

local popGui: ScreenGui? = nil
local popToken = 0

local function withText(list: any): string
	if type(list) ~= "table" or #list == 0 then
		return ""
	end
	if #list == 1 then
		return `with {list[1]}`
	end
	return `with {list[1]} +{#list - 1}`
end

local function pop(kind: string, info: { [string]: any })
	local title, color
	if kind == "combo" then
		title, color = `COMBO! x{tonumber(info.mult) or 1.5}`, Palette.FireEdge
	elseif kind == "teamwork" then
		title, color = "TEAMWORK!", Palette.UiGood
	elseif kind == "streak" then
		title, color = `SQUAD STREAK x{tonumber(info.streak) or 2}!`, GOLD
	else
		return
	end
	local xp = tonumber(info.xp) or 0
	local sub = withText(info.with)
	if xp > 0 then
		sub = if sub == "" then `+{xp} XP` else `{sub}  +{xp} XP`
	end
	if kind == "combo" and sub == "" then
		sub = "faster with friends!"
	end

	local gui = popGui
	if not gui or not gui.Parent then
		gui = UiKit.screen("TeamBonus", 30)
		popGui = gui
	end
	local g = gui :: ScreenGui
	local old = g:FindFirstChild("Pop")
	if old then
		old:Destroy()
	end
	popToken += 1
	local token = popToken
	local holder = Instance.new("Frame")
	holder.Name = "Pop"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.fromScale(0.5, 0.24)
	holder.Size = UDim2.fromOffset(620, 110)
	holder.Active = false
	holder.Parent = g
	local t = UiKit.label(holder, "Title", title, UDim2.new(1, 0, 0, 70), UDim2.fromOffset(0, 0), {
		font = UiKit.Header,
		textSize = 64,
		color = color,
		stroke = true,
		strokeThickness = 4,
	})
	t.Rotation = -4
	local s = UiKit.label(holder, "Sub", sub, UDim2.new(1, 0, 0, 34), UDim2.fromOffset(0, 72), {
		font = UiKit.Header,
		textSize = 30,
		color = Palette.UiCream,
		stroke = true,
		strokeThickness = 3,
	})
	UiKit.pop(holder, 0.25)
	task.delay(1.4, function()
		if token ~= popToken or not holder.Parent then
			return
		end
		UiKit.tween(t, 0.35, { TextTransparency = 1 })
		UiKit.tween(s, 0.35, { TextTransparency = 1 })
		for _, st in holder:GetDescendants() do
			if st:IsA("UIStroke") then
				UiKit.tween(st, 0.35, { Transparency = 1 })
			end
		end
		task.delay(0.4, function()
			if holder.Parent then
				holder:Destroy()
			end
		end)
	end)
end

-------------------------------------------------------------------------------------- results cards

local function rowsFromPayload(payload: any): { TeamRules.Row }
	local rows = {}
	for _, s in payload.stats or {} do
		if type(s) == "table" and type(s.userId) == "number" then
			table.insert(rows, { userId = s.userId, name = tostring(s.name or "?"), rescued = tonumber(s.rescued) or 0, firesOut = tonumber(s.firesOut) or 0, combos = 0, teamwork = 0 })
		end
	end
	return rows
end

local function band(face: Frame, text: string, color: Color3): TextLabel
	local b = Instance.new("Frame")
	b.Name = "Band"
	b.Size = UDim2.new(1, 0, 0, 52)
	b.BackgroundColor3 = color
	b.BorderSizePixel = 0
	b.ZIndex = 1
	UiKit.corner(b, 12)
	b.Parent = face
	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(1, 0, 0, 14)
	fill.Position = UDim2.new(0, 0, 1, -14)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = b
	local l = UiKit.label(b, "Text", text, UDim2.new(1, -12, 1, -14), UDim2.fromOffset(6, 7), {
		font = UiKit.Header,
		color = Palette.UiCream,
		stroke = true,
		scaled = true, -- "BEST TEAMMATE" on one line in a 190 px card
	})
	l.TextWrapped = false
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 26
	cap.Parent = l
	return l
end

local function holderFace(parent: Instance, name: string, order: number, w: number, h: number): (Frame, Frame)
	local holder = Instance.new("Frame")
	holder.Name = name
	holder.LayoutOrder = order
	holder.Size = UDim2.fromOffset(w, h + 10)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = parent
	local face = UiKit.panel(holder, "Face", UDim2.new(0, w, 0, h), UDim2.new(0.5, 0, 0.5, 0), Vector2.new(0.5, 0.5))
	face.Rotation = if order % 2 == 0 then 2 else -2
	return holder, face
end

local function renderSquad(face: Frame, data: SquadData)
	local old = face:FindFirstChild("Body")
	if old then
		old:Destroy()
	end
	local bandText = face:FindFirstChild("Band") and (face :: any).Band:FindFirstChild("Text")
	if bandText then
		bandText.Text = if data.streak >= 2 then `SQUAD  STREAK x{data.streak}!` else "SQUAD"
	end
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(8, 56)
	body.Size = UDim2.new(1, -16, 1, -60)
	body.Parent = face
	local cols = { { "SAVED", "rescued", Palette.UiGood }, { "FIRES", "firesOut", Palette.FireEdge }, { "COMBO", "combos", Palette.UiWater } }
	local nameW = 0.46
	local colW = (1 - nameW) / #cols
	for c, col in cols do
		UiKit.label(body, `H{c}`, col[1] :: string, UDim2.new(colW, 0, 0, 18), UDim2.new(nameW + (c - 1) * colW, 0, 0, 0), {
			font = UiKit.Header,
			textSize = 14,
			color = col[3] :: Color3,
		})
	end
	local me = Players.LocalPlayer.UserId
	local rows = table.clone(data.rows)
	table.sort(rows, function(a, b)
		return TeamRules.score(a) > TeamRules.score(b)
	end)
	local maxRows = math.floor((face.Size.Y.Offset - 80) / ROW_H)
	for i, r in rows do
		if i > maxRows then
			break
		end
		local y = 20 + (i - 1) * ROW_H
		local isBest = data.best ~= nil and r.userId == data.best
		if r.userId == me or isBest then
			local hl = Instance.new("Frame")
			hl.Name = `Hl{i}`
			hl.BackgroundColor3 = if isBest then GOLD else Palette.UiWater
			hl.BackgroundTransparency = 0.55
			hl.BorderSizePixel = 0
			hl.Position = UDim2.fromOffset(-4, y)
			hl.Size = UDim2.new(1, 8, 0, ROW_H)
			UiKit.corner(hl, 6)
			hl.Parent = body
		end
		local n = UiKit.label(body, `Name{i}`, (if isBest then "★ " else "") .. tostring(r.name or "?"), UDim2.new(nameW, -2, 0, ROW_H), UDim2.fromOffset(0, y), {
			font = UiKit.Body,
			textSize = 16,
			align = Enum.TextXAlignment.Left,
		})
		n.TextTruncate = Enum.TextTruncate.AtEnd
		n.TextWrapped = false
		for c, col in cols do
			UiKit.label(body, `V{i}_{c}`, tostring((r :: any)[col[2]] or 0), UDim2.new(colW, 0, 0, ROW_H), UDim2.new(nameW + (c - 1) * colW, 0, 0, y), {
				font = UiKit.Header,
				textSize = 18,
				color = Palette.UiInk,
			})
		end
	end
end

local function renderBest(face: Frame, data: SquadData)
	local old = face:FindFirstChild("Body")
	if old then
		old:Destroy()
	end
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Size = UDim2.fromScale(1, 1)
	body.Parent = face
	local row: TeamRules.Row? = nil
	for _, r in data.rows do
		if r.userId == data.best then
			row = r
		end
	end
	if not row then
		UiKit.label(body, "Tip", "Spray the SAME fire together for a COMBO!\n\nWalk with whoever carries someone for TEAMWORK!", UDim2.new(1, -20, 0, 170), UDim2.fromOffset(10, 62), {
			textSize = 18,
		})
		return
	end
	local r = row :: TeamRules.Row
	local img = Instance.new("ImageLabel")
	img.Name = "Face"
	img.AnchorPoint = Vector2.new(0.5, 0)
	img.Position = UDim2.new(0.5, 0, 0, 60)
	img.Size = UDim2.fromOffset(84, 84)
	img.BackgroundColor3 = Palette.UiWater
	img.BorderSizePixel = 0
	img.ZIndex = 2
	UiKit.corner(img, 42)
	UiKit.stroke(img, 3, GOLD)
	img.Image = if r.userId > 0 then `rbxthumb://type=AvatarHeadShot&id={r.userId}&w=150&h=150` else ""
	img.Parent = body
	if r.userId <= 0 then
		UiKit.label(img, "Initial", string.upper(string.sub(tostring(r.name or "?"), 1, 1)), UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
			font = UiKit.Header,
			textSize = 48,
			color = Palette.UiCream,
			stroke = true,
		})
	end
	local name = UiKit.label(body, "Name", tostring(r.name or "?"), UDim2.new(1, -16, 0, 30), UDim2.fromOffset(8, 150), {
		font = UiKit.Header,
		textSize = 24,
	})
	name.TextTruncate = Enum.TextTruncate.AtEnd
	local why = {}
	local function add(n: number?, one: string, many: string)
		if n and n > 0 then
			table.insert(why, `{n} {if n == 1 then one else many}`)
		end
	end
	add(r.combos, "COMBO", "COMBOS")
	add(r.teamwork, "TEAMWORK", "TEAMWORKS")
	add(r.rescued, "SAVED", "SAVED")
	add(r.firesOut, "FIRE OUT", "FIRES OUT")
	UiKit.label(body, "Why", table.concat(why, " · "), UDim2.new(1, -16, 0, 56), UDim2.fromOffset(8, 184), {
		textSize = 16,
		color = Palette.CoatShadow,
	})
end

-- ResultsController hook: the two squad cards (holder, face) to flip in first; {} for a solo call.
function TeamBonusController:ResultsCards(strip: Instance, payload: any, cardW: number, cardH: number): { { Frame } }
	if type(payload) ~= "table" or type(payload.stats) ~= "table" or #payload.stats < 2 then
		return {}
	end
	local iid = payload.instanceId
	local data: SquadData = { instanceId = iid, rows = rowsFromPayload(payload), best = nil, streak = 0 }
	local l = latest
	if l and (iid == nil or l.instanceId == iid) then
		data = l
	end
	local sh, sf = holderFace(strip, "SquadCard", -2, SQUAD_W, cardH)
	band(sf, "SQUAD", Palette.UiWater)
	local bh, bf = holderFace(strip, "BestTeammateCard", -1, cardW, cardH)
	band(bf, "BEST TEAMMATE", GOLD)
	renderSquad(sf, data)
	renderBest(bf, data)
	onSquad = function(d: SquadData)
		if (iid == nil or d.instanceId == iid) and sf.Parent and bf.Parent then
			renderSquad(sf, d)
			renderBest(bf, d)
		end
	end
	return { { sh, sf }, { bh, bf } }
end

function TeamBonusController:Init(_all: { [string]: any }) end

function TeamBonusController:Start()
	Net.event("Social", "Bonus").OnClientEvent:Connect(function(kind: any, info: any)
		if type(kind) == "string" then
			local ok, err = pcall(pop, kind, if type(info) == "table" then info else {})
			if not ok then
				warn(`[TeamBonusController] pop: {err}`)
			end
		end
	end)
	Net.event("Social", "Squad").OnClientEvent:Connect(function(d: any)
		if type(d) ~= "table" or type(d.rows) ~= "table" then
			return
		end
		local data: SquadData = { instanceId = d.instanceId, rows = d.rows, best = tonumber(d.best), streak = tonumber(d.streak) or 0 }
		latest = data
		local cb = onSquad
		if cb then
			pcall(cb, data)
		end
	end)
end

-- Test hooks (call from a client harness): show a pop / the squad data as if the server sent it.
function TeamBonusController:_pop(kind: string, info: { [string]: any }?)
	pop(kind, info or {})
end

return TeamBonusController
