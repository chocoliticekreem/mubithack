--!strict
-- WorldPopup [owner: Feedback]. The one subtle feedback renderer: small world text ~2-3 studs above a
-- player's / NPC's / object's head that rises gently and fades over ~1 s (docs: FeedbackConfig).
--   * BillboardGui in PlayerGui, AlwaysOnTop = false, MaxDistance = FeedbackConfig.MaxDistance, 16 px
--     text with a soft outline. Popups farther than MaxDistance from the camera are skipped.
--   * Max 1 per subject (newest replaces), global cap 6, same text over the same subject within 2 s is
--     dropped (Lib/PopupLogic, spec-tested).
--   * Mode (Player attr Feedback, ProfileSchema setting "feedback"): Normal / Minimal (only popups you
--     are part of) / Off. A small lobby button under GRAPHICS cycles it and saves it.
--   * Your own character in first person: the popup sits a little ahead of the camera, upper middle.
--
-- API (every client pop goes through this; servers use Shared/Popup.show):
--   WorldPopup.show(subject: Instance | Vector3, text: string, opts: Opts?): boolean
--     subject = Player, character / NPC / prop Model, BasePart, Attachment or a world position.
--     opts = { kind = "info"|"good"|"bad"|"blame"?, color: Color3?, big: boolean?, mine: boolean?,
--              seconds: number?, height: number? (studs above the subject's top, overrides HeadOffset) }
--   WorldPopup.start()                 -- listens to Shared/Popup + builds the setting button (idempotent;
--                                         HudController:Start calls it)
--   WorldPopup.getMode(): "Normal" | "Minimal" | "Off"
--   WorldPopup.setMode(mode: string | number, save: boolean?)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("FeedbackConfig") :: ModuleScript) :: any
local PopupLogic =
	require(script.Parent.Parent:WaitForChild("Lib"):WaitForChild("PopupLogic") :: ModuleScript)

local WorldPopup = {}

export type Opts = {
	kind: string?,
	color: Color3?,
	big: boolean?,
	mine: boolean?,
	seconds: number?,
	height: number?,
}

local LocalPlayer = Players.LocalPlayer
local KIND_COLORS: { [string]: Color3 } = {
	info = Color3.fromRGB(246, 239, 224),
	good = Color3.fromRGB(165, 236, 150),
	bad = Color3.fromRGB(255, 154, 134),
	blame = Color3.fromRGB(255, 214, 112),
}

local state: PopupLogic.State? = nil
local live: { [number]: { gui: BillboardGui, anchor: Instance? } } = {}
local keys: { [Instance]: string } = setmetatable({}, { __mode = "k" }) :: any
local keySeq = 0
local localMode: PopupLogic.Mode? = nil
local started = false

local function logic(): PopupLogic.State
	local s = state
	if not s then
		s = PopupLogic.new({
			cap = tonumber(Cfg.Cap) or 6,
			perSubject = tonumber(Cfg.PerSubject) or 1,
			dedupeSeconds = tonumber(Cfg.DedupeSeconds) or 2,
			lifeSeconds = tonumber(Cfg.Seconds) or 1,
		})
		state = s
	end
	return s :: PopupLogic.State
end

function WorldPopup.getMode(): PopupLogic.Mode
	if localMode then
		return localMode
	end
	local v = LocalPlayer:GetAttribute(Cfg.SettingAttr)
	return PopupLogic.mode(if v ~= nil then v else Cfg.Mode)
end

local function keyOf(inst: Instance): string
	local k = keys[inst]
	if not k then
		keySeq += 1
		k = `i{keySeq}`
		keys[inst] = k
	end
	return k
end

-- subject -> (adornee part or nil, world position, key, studs above the adornee's centre, is me)
local function resolve(subject: any, height: number?): (BasePart?, Vector3?, string, number, boolean)
	local up = tonumber(Cfg.HeadOffset) or 1.8
	if typeof(subject) == "Vector3" then
		local v = subject :: Vector3
		return nil, v, `p{math.floor(v.X / 6)},{math.floor(v.Y / 6)},{math.floor(v.Z / 6)}`, height or 1, false
	end
	if typeof(subject) ~= "Instance" then
		return nil, nil, "", 0, false
	end
	local inst = subject :: Instance
	if inst:IsA("Player") then
		local c = (inst :: Player).Character
		if not c then
			return nil, nil, "", 0, false
		end
		inst = c
	end
	if inst:IsA("Attachment") then
		return nil, (inst :: Attachment).WorldPosition, keyOf(inst), height or 1, false
	end
	-- a part inside a character / NPC counts as that character
	if inst:IsA("BasePart") then
		local m = inst:FindFirstAncestorOfClass("Model")
		if m and m:FindFirstChildOfClass("Humanoid") then
			inst = m
		end
	end
	local part: BasePart? = nil
	if inst:IsA("Model") then
		local m = inst :: Model
		local head = m:FindFirstChild("Head")
		part = if head and head:IsA("BasePart") then head else m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
	elseif inst:IsA("BasePart") then
		part = inst :: BasePart
	end
	if not part then
		return nil, nil, "", 0, false
	end
	local p = part :: BasePart
	local mine = LocalPlayer.Character ~= nil and inst == LocalPlayer.Character
	return p, p.Position, keyOf(inst), height or (p.Size.Y / 2 + up), mine
end

local function finish(id: number)
	local rec = live[id]
	live[id] = nil
	if rec then
		rec.gui:Destroy()
		if rec.anchor then
			rec.anchor:Destroy()
		end
	end
end

local function firstPerson(): boolean
	local cam = workspace.CurrentCamera
	local char = LocalPlayer.Character
	local head = char and char:FindFirstChild("Head") :: BasePart?
	return cam ~= nil and head ~= nil and (cam.CFrame.Position - head.Position).Magnitude < 2
end

function WorldPopup.show(subject: any, text: string, opts: Opts?): boolean
	local o: Opts = opts or {}
	if type(text) ~= "string" or text == "" then
		return false
	end
	local cam = workspace.CurrentCamera
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not cam or not pg then
		return false
	end
	local part, pos, key, height, isMe = resolve(subject, o.height)
	if not pos or key == "" then
		return false
	end
	local maxD = tonumber(Cfg.MaxDistance) or 60
	if (cam.CFrame.Position - pos).Magnitude > maxD then
		return false
	end
	local d = PopupLogic.admit(logic(), os.clock(), key, text, WorldPopup.getMode(), isMe or o.mine == true)
	if not d.show then
		return false
	end
	for _, id in d.evict do
		finish(id)
	end

	-- your own head in first person is behind the camera: float it a little ahead, upper middle
	local anchor: Attachment? = nil
	if isMe and firstPerson() then
		local look = cam.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
		part = nil
		pos = cam.CFrame.Position + flat * 10
		height = 2.6
	end
	if not part then
		local a = Instance.new("Attachment")
		a.Name = "WorldPopupAnchor"
		a.WorldPosition = pos :: Vector3
		a.Parent = workspace.Terrain
		anchor = a
	end

	local secs = o.seconds or tonumber(Cfg.Seconds) or 1
	local size = (tonumber(Cfg.TextSize) or 16) + (if o.big then 2 else 0)
	local gui = Instance.new("BillboardGui")
	gui.Name = "WorldPopup"
	gui.ResetOnSpawn = false
	gui.Adornee = if part then part else anchor
	gui.Size = UDim2.fromOffset(math.clamp(#text * (size * 0.62) + 24, 60, 320), size + 10)
	gui.StudsOffsetWorldSpace = Vector3.new(0, height, 0)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = maxD
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextSize = size
	label.TextWrapped = false
	label.Text = text
	label.TextColor3 = o.color or KIND_COLORS[o.kind or "info"] or KIND_COLORS.info
	label.TextStrokeColor3 = Palette.UiInk
	label.TextStrokeTransparency = 1
	label.TextTransparency = 1
	label.Parent = gui
	gui.Parent = pg
	live[d.id] = { gui = gui, anchor = anchor }

	local outline = tonumber(Cfg.OutlineTransparency) or 0.45
	TweenService:Create(label, TweenInfo.new(0.12), { TextTransparency = 0, TextStrokeTransparency = outline }):Play()
	TweenService:Create(gui, TweenInfo.new(secs, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		StudsOffsetWorldSpace = Vector3.new(0, height + (tonumber(Cfg.Rise) or 1.2), 0),
	}):Play()
	task.delay(secs * 0.6, function()
		if label.Parent then
			TweenService:Create(label, TweenInfo.new(secs * 0.4), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
	end)
	local id = d.id
	task.delay(secs + 0.05, function()
		if live[id] then
			finish(id)
			PopupLogic.release(logic(), id)
		end
	end)
	return true
end

-- A positional pop (Physics/Pop etc.) that lands on a player sticks to that player's head instead.
function WorldPopup.subjectAt(pos: Vector3, radius: number?): any
	local best: Model? = nil
	local bestD = radius or 5
	for _, p in Players:GetPlayers() do
		local c = p.Character
		local r = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r then
			local d = (r.Position - pos).Magnitude
			if d < bestD then
				best, bestD = c, d
			end
		end
	end
	return best or pos
end

-- settings ---------------------------------------------------------------------------------------------
local LABEL: { [string]: string } = { Normal = "POP-UPS: NORMAL", Minimal = "POP-UPS: MINIMAL", Off = "POP-UPS: OFF" }
local button: TextButton? = nil
local buttonGui: ScreenGui? = nil

local function inLobby(): boolean
	local iid = LocalPlayer:GetAttribute(Names.Attr.InstanceId)
	return iid == nil or iid == ""
end

local function refreshButton()
	if button then
		button.Text = LABEL[WorldPopup.getMode()]
	end
	if buttonGui then
		buttonGui.Enabled = inLobby()
	end
end

function WorldPopup.setMode(mode: any, save: boolean?)
	local m = PopupLogic.mode(mode)
	localMode = m
	refreshButton()
	if save then
		task.spawn(function()
			local ok, err = pcall(function()
				Net.event("Data", "Setting"):FireServer(Cfg.SettingKey, PopupLogic.index(m))
			end)
			if not ok then
				warn(`[WorldPopup] could not save feedback setting: {err}`)
			end
		end)
	end
end

local function buildButton()
	local UiKit = require(script.Parent:WaitForChild("UiKit") :: ModuleScript) :: any
	local sg = UiKit.screen("FeedbackSettingsUI", 5)
	buttonGui = sg
	local btn = UiKit.button(sg, "Feedback", LABEL.Normal, UDim2.fromOffset(250, 34), UDim2.fromOffset(16 + 125, 240), Color3.fromRGB(60, 70, 96))
	btn.TextSize = 18
	button = btn
	btn.Activated:Connect(function()
		local i = PopupLogic.index(WorldPopup.getMode())
		WorldPopup.setMode((i + 1) % 3, true)
		UiKit.pop(btn, 0.2)
	end)
	LocalPlayer:GetAttributeChangedSignal(Names.Attr.InstanceId):Connect(refreshButton)
	LocalPlayer:GetAttributeChangedSignal(Cfg.SettingAttr):Connect(function()
		localMode = nil -- the saved value (DataService) wins once it lands
		refreshButton()
	end)
	refreshButton()
end

function WorldPopup.start()
	if started then
		return
	end
	started = true
	task.spawn(function()
		local ok, err = pcall(buildButton)
		if not ok then
			warn(`[WorldPopup] setting button: {err}`)
		end
	end)
	task.spawn(function()
		local ok, err = pcall(function()
			Net.event("Shared", "Popup").OnClientEvent:Connect(
				function(subject: any, pos: any, text: any, kind: any, actorId: any, subjectId: any)
					if type(text) ~= "string" then
						return
					end
					local target = if typeof(subject) == "Instance" and (subject :: Instance).Parent then subject else pos
					if typeof(target) ~= "Instance" and typeof(target) ~= "Vector3" then
						return
					end
					local me = LocalPlayer.UserId
					WorldPopup.show(target, text, {
						kind = if type(kind) == "string" then kind else "info",
						mine = actorId == me or subjectId == me,
						big = kind == "blame",
					})
				end
			)
		end)
		if not ok then
			warn(`[WorldPopup] Shared/Popup: {err}`)
		end
	end)
end

return WorldPopup
