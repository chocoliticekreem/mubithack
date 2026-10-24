--!strict
-- SquadController [owner: G3]. Client side of SquadService: the Downed look and the lobby emotes.
--   - Every Downed character (Player attr Downed): spiral eyes (the costume's pupils orbit on their
--     PupilWeld, local only) and dizzy stars circling over the head (local parts under the camera).
--   - Local player Downed: small bleed-out banner (attr DownedUntil) and your own Revive/Slap prompts
--     hidden (you can't revive yourself).
--   - Lobby emotes on Z wave, X facepalm, C blame-point at the teammate you look at (1 / 2 belong to
--     the inventory swap).
--     Sends Squad/Emote; poses arms locally on every client from Squad/Fx.
--   - Squad/Fx pops: "SLAP!", "BONK", oxygen hiss puff, emote speech bubbles, camera shake.
-- Reads: Player attrs Downed, DownedUntil, InstanceId, Helmet; Workspace attr RoundState;
--        character Folder "Costume" (HeadBlob, PupilWeld with attr BaseC0)
-- Remotes: Squad/Emote (C->S emote, targetUserId?), Squad/Fx (S->C kind, userId, a?, b?)
-- Uses (nil-guarded): FirstPersonController:Shake
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local InputHints = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("InputHints") :: ModuleScript) :: any

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = ReplicatedStorage:WaitForChild("Config")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local SquadConfig = require(Config:WaitForChild("SquadConfig") :: ModuleScript)
local LobbyConfig = require(Config:WaitForChild("LobbyConfig") :: ModuleScript)
local WorldPopup = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("WorldPopup") :: ModuleScript)

local SquadController = {}
SquadController.Priority = 60

local LocalPlayer = Players.LocalPlayer
local controllers: { [string]: any } = {}
local emoteRemote: RemoteEvent? = nil
local starFolders: { [Model]: Folder } = {}
local spinning: { [Model]: boolean } = {}
local gui: ScreenGui? = nil
local downedLabel: TextLabel? = nil
local hintLabel: TextLabel? = nil
local lastEmote = 0

local EMOTE_KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.Z] = "wave",
	[Enum.KeyCode.X] = "facepalm",
	[Enum.KeyCode.C] = "blame",
}

-- Same rules as Lib/Squad/SquadRules (server-only folder), inlined for the client.
local function orbit(i: number, n: number, t: number, radius: number, rps: number): (number, number)
	local a = (i - 1) / math.max(1, n) * math.pi * 2 + t * rps * math.pi * 2
	return math.cos(a) * radius, math.sin(a) * radius
end

local function inLobby(): boolean
	local inst = LocalPlayer:GetAttribute(Names.Attr.InstanceId)
	if type(inst) == "string" and inst ~= "" then
		return false
	end
	if LobbyConfig.UseLobby then
		return true
	end
	local state = workspace:GetAttribute(Names.Attr.RoundState)
	return state ~= "Active" and state ~= "Alarm"
end

-- my call isn't over (not Results / Done). After a squad wipe the round sits in Results with everyone still
-- Downed: no "crawl to a teammate" banner over the results card.
local function roundLive(): boolean
	local iid = LocalPlayer:GetAttribute(Names.Attr.InstanceId)
	local holder: Instance? = workspace
	if type(iid) == "string" and iid ~= "" then
		local folder = workspace:FindFirstChild("Instances")
		holder = folder and folder:FindFirstChild(iid)
		if not holder then
			for _, m in game:GetService("CollectionService"):GetTagged("IncidentSite") do
				if m:GetAttribute(Names.Attr.InstanceId) == iid then
					holder = m
					break
				end
			end
		end
	end
	local st = holder and holder:GetAttribute(Names.Attr.RoundState)
	return st ~= "Results" and st ~= "Done"
end

local function badgeOf(player: Player): string
	local n = player:GetAttribute(Names.Attr.Helmet)
	return string.format("%02d", if type(n) == "number" then n else 1)
end

local function headOf(character: Model): BasePart?
	local costume = character:FindFirstChild("Costume")
	local blob = costume and costume:FindFirstChild("HeadBlob")
	if blob and blob:IsA("BasePart") then
		return blob
	end
	return character:FindFirstChild("Head") :: BasePart?
end

local function shake(mag: number, secs: number)
	local fp = controllers.FirstPersonController
	if fp and type(fp.Shake) == "function" then
		pcall(fp.Shake, fp, mag, secs)
	end
end

---------------------------------------------------------------------------- pops / bubbles
local function bubble(character: Model?, text: string, color: Color3, seconds: number, big: boolean?)
	if not character then
		return
	end
	-- subtle world text over the head (ClientLib/WorldPopup: caps, dedupe, feedback setting)
	WorldPopup.show(character, text, {
		color = if color == Palette.UiInk then nil else color,
		big = big,
		mine = character == LocalPlayer.Character,
		seconds = math.min(seconds, 1.4),
	})
end

local function puff(character: Model?, color: Color3)
	local head = character and headOf(character)
	if not head then
		return
	end
	local p = Instance.new("Part")
	p.Name = "SquadPuff"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.one * 0.2
	p.CFrame = head.CFrame
	local pe = Instance.new("ParticleEmitter")
	pe.Rate = 0
	pe.Lifetime = NumberRange.new(0.5, 0.9)
	pe.Speed = NumberRange.new(4, 8)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 1.6) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	pe.Color = ColorSequence.new(color)
	pe.Drag = 4
	pe.Parent = p
	p.Parent = workspace.CurrentCamera
	pe:Emit(30)
	task.delay(2, function()
		p:Destroy()
	end)
end

---------------------------------------------------------------------------- emote poses (local only)
local function motor(character: Model, r15: string, r15Parent: string, r6: string): Motor6D?
	local part = character:FindFirstChild(r15Parent)
	local m = part and part:FindFirstChild(r15)
	if m and m:IsA("Motor6D") then
		return m
	end
	local torso = character:FindFirstChild("Torso")
	local m6 = torso and torso:FindFirstChild(r6)
	if m6 and m6:IsA("Motor6D") then
		return m6
	end
	return nil
end

local posing: { [Motor6D]: CFrame } = {}

local function pose(m: Motor6D?, seconds: number, fn: (base: CFrame, t: number) -> CFrame)
	if not m then
		return
	end
	local base = posing[m] or m.C0
	posing[m] = base
	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - t0
		if t >= seconds or not m.Parent then
			conn:Disconnect()
			if m.Parent then
				m.C0 = base
			end
			posing[m] = nil
			return
		end
		m.C0 = fn(base, t)
	end)
end

local function playEmote(player: Player, emote: string, target: Player?)
	local char = player.Character
	if not char then
		return
	end
	local secs = SquadConfig.EmoteSeconds
	local shoulder = motor(char, "RightShoulder", "RightUpperArm", "Right Shoulder")
	local neck = motor(char, "Neck", "Head", "Neck")
	if emote == "wave" then
		bubble(char, "HEY!", Palette.UiInk, secs)
		pose(shoulder, secs, function(base, t)
			return base * CFrame.Angles(0, 0, math.rad(150 + 25 * math.sin(t * 14)))
		end)
	elseif emote == "facepalm" then
		bubble(char, "*facepalm*", Palette.UiInk, secs)
		pose(shoulder, secs, function(base, _t)
			return base * CFrame.Angles(math.rad(145), 0, 0) * CFrame.Angles(0, 0, math.rad(-35))
		end)
		pose(neck, secs, function(base, t)
			return base * CFrame.Angles(math.rad(-22 - 4 * math.sin(t * 6)), math.rad(8 * math.sin(t * 3)), 0)
		end)
	elseif emote == "blame" then
		local who = if target then `IT WAS {badgeOf(target)}!` else "IT WAS... SOMEONE!"
		bubble(char, who, Palette.UiRed, secs + 0.5)
		pose(shoulder, secs, function(base, t)
			return base * CFrame.Angles(math.rad(90 + 6 * math.sin(t * 20)), 0, 0)
		end)
		if target and target.Character then
			bubble(target.Character, "?!", Palette.UiRed, secs)
			if target == LocalPlayer then
				shake(0.3, 0.25)
			end
		end
	end
end

local function pickBlameTarget(): Player?
	local cam = workspace.CurrentCamera
	if not cam then
		return nil
	end
	local best: Player? = nil
	local bestScore = -math.huge
	for _, p in Players:GetPlayers() do
		if p == LocalPlayer then
			continue
		end
		local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			continue
		end
		local v = root.Position - cam.CFrame.Position
		local dist = v.Magnitude
		if dist > SquadConfig.BlameRange or dist < 0.1 then
			continue
		end
		local dot = cam.CFrame.LookVector:Dot(v.Unit)
		-- mostly "who am I looking at", a little "who is closest"
		local score = dot * 2 - dist / SquadConfig.BlameRange
		if dot > 0.5 and score > bestScore then
			best, bestScore = p, score
		end
	end
	return best
end

---------------------------------------------------------------------------- downed fx
local function starsFor(character: Model): Folder
	local f = starFolders[character]
	if f and f.Parent then
		return f
	end
	local folder = Instance.new("Folder")
	folder.Name = "DizzyStars"
	for i = 1, SquadConfig.StarCount do
		local s = Instance.new("Part")
		s.Name = `Star{i}`
		s.Anchored = true
		s.CanCollide = false
		s.CanQuery = false
		s.CanTouch = false
		s.CastShadow = false
		s.Material = Enum.Material.Neon
		s.Color = Color3.fromHex("#FFE45C")
		s.Size = Vector3.new(0.4, 0.4, 0.14)
		s.Parent = folder
	end
	folder.Parent = workspace.CurrentCamera
	starFolders[character] = folder
	return folder
end

local function clearDownedFx(character: Model)
	local f = starFolders[character]
	if f then
		f:Destroy()
		starFolders[character] = nil
	end
	if spinning[character] then
		spinning[character] = nil
		local costume = character:FindFirstChild("Costume")
		if costume then
			for _, d in costume:GetDescendants() do
				if d:IsA("Weld") and d.Name == "PupilWeld" then
					local base = d:GetAttribute("BaseC0")
					if typeof(base) == "CFrame" then
						d.C0 = base
					end
				end
			end
		end
	end
end

local function stepDowned()
	local t = os.clock()
	local alive: { [Model]: boolean } = {}
	for _, p in Players:GetPlayers() do
		local char = p.Character
		if not char then
			continue
		end
		if p:GetAttribute(Names.Attr.Downed) ~= true then
			if starFolders[char] or spinning[char] then
				clearDownedFx(char)
			end
			continue
		end
		alive[char] = true
		local head = headOf(char)
		if not head then
			continue
		end
		-- dizzy stars, always above the head in world space (works lying down)
		local centre = head.Position + Vector3.new(0, 1.6, 0)
		local folder = starsFor(char)
		local n = SquadConfig.StarCount
		for i, s in folder:GetChildren() do
			if s:IsA("BasePart") then
				local x, z = orbit(i, n, t, SquadConfig.StarRadius, SquadConfig.StarSpin)
				local bob = math.sin(t * 5 + i) * 0.15
				s.CFrame = CFrame.new(centre + Vector3.new(x, bob, z)) * CFrame.Angles(t * 3, t * 4 + i, math.rad(45))
			end
		end
		-- spiral eyes: pupils orbit inside the eye, opposite directions = maximum derp
		local costume = char:FindFirstChild("Costume")
		if costume then
			spinning[char] = true
			local k = 0
			for _, d in costume:GetDescendants() do
				if d:IsA("Weld") and d.Name == "PupilWeld" then
					local base = d:GetAttribute("BaseC0")
					if typeof(base) == "CFrame" then
						k += 1
						local dir = if k % 2 == 0 then -1 else 1
						local x, y = orbit(1, 1, t * dir, 0.18, SquadConfig.PupilSpin)
						d.C0 = base * CFrame.new(x, y, 0)
					end
				end
			end
		end
	end
	for char in starFolders do
		if not alive[char] then
			clearDownedFx(char)
		end
	end
end

---------------------------------------------------------------------------- local UI
local function makeGui()
	local pg = LocalPlayer:WaitForChild("PlayerGui")
	local sg = Instance.new("ScreenGui")
	sg.Name = "SquadGui"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 5

	local downed = Instance.new("TextLabel")
	downed.Name = "Downed"
	downed.AnchorPoint = Vector2.new(0.5, 1)
	downed.Position = UDim2.new(0.5, 0, 1, -110)
	downed.Size = UDim2.fromOffset(520, 46)
	downed.BackgroundColor3 = Palette.UiPanelDark
	downed.BackgroundTransparency = 0.25
	downed.Font = Enum.Font.LuckiestGuy
	downed.TextScaled = true
	downed.TextColor3 = Palette.UiCream
	downed.Visible = false
	local c1 = Instance.new("UICorner")
	c1.CornerRadius = UDim.new(0, 12)
	c1.Parent = downed
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = downed
	downed.Parent = sg

	local hint = Instance.new("TextLabel")
	hint.Name = "EmoteHint"
	hint.AnchorPoint = Vector2.new(0, 1)
	hint.Position = UDim2.new(0, 16, 1, -60) -- above OnboardingController's [H] HELP chip (bottom left)
	hint.Size = UDim2.fromOffset(260, 22)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.GothamBold
	hint.TextScaled = true
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.TextColor3 = Palette.UiCream
	hint.TextStrokeTransparency = 0.4
	hint.Text = "[Z] Wave   [X] Facepalm   [C] Blame!"
	hint.Visible = false
	hint.Parent = sg

	sg.Parent = pg
	gui, downedLabel, hintLabel = sg, downed, hint
end

local function stepUi()
	if downedLabel then
		local isDown = LocalPlayer:GetAttribute(Names.Attr.Downed) == true and roundLive()
		downedLabel.Visible = isDown
		if isDown then
			local untilT = LocalPlayer:GetAttribute(SquadConfig.AttrDownedUntil)
			local left = if type(untilT) == "number" then math.max(0, math.ceil(untilT - workspace:GetServerTimeNow())) else 0
			downedLabel.Text = InputHints.pick(
				`@_@  Crawl to a teammate! Oxygen (E) or SLAP (F)  {left}s`,
				`@_@  Crawl to a teammate for Oxygen or a SLAP  {left}s`
			)
		end
	end
	if hintLabel then
		hintLabel.Visible = inLobby() and LocalPlayer:GetAttribute(Names.Attr.Downed) ~= true
			and LocalPlayer:GetAttribute("HelpOpen") ~= false -- OnboardingController: emotes live in Help (H)
			and InputHints.mode() == "keyboard" -- Z / X / C mean nothing on a phone or a gamepad
	end
end

-- you can't revive yourself: hide your own prompts locally
local function watchOwnPrompts(character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not root then
		return
	end
	local function hide(child: Instance)
		if child:IsA("ProximityPrompt") and (child.Name == "Revive" or child.Name == "Slap") then
			child.Enabled = false
		end
	end
	for _, c in root:GetChildren() do
		hide(c)
	end
	root.ChildAdded:Connect(hide)
end

---------------------------------------------------------------------------- Fx remote
local function onFx(kind: string, userId: number, a: any, b: any)
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end
	local char = player.Character
	if kind == "emote" then
		local target = if type(b) == "number" then Players:GetPlayerByUserId(b) else nil
		playEmote(player, tostring(a), target)
	elseif kind == "down" then
		bubble(char, if a == "heat" then "WELL DONE!" elseif a == "electrocution" then "BZZT!" else "BONK!", Palette.UiRed, 1.2, true)
		if player == LocalPlayer then
			shake(0.6, 0.4)
		end
	elseif kind == "revive" then
		local by = if type(a) == "number" then Players:GetPlayerByUserId(a) else nil
		if b == "slap" then
			bubble(char, "SLAP!", Palette.UiRed, 1.1, true)
			puff(char, Palette.UiCream)
			if player == LocalPlayer or by == LocalPlayer then
				shake(0.8, 0.3)
			end
		elseif b == "oxygen" then
			bubble(char, "!!", Palette.UiWater, 1.2, true)
			puff(char, Palette.SmokeWhite)
		end
	end
end

---------------------------------------------------------------------------- lifecycle
function SquadController:Init(all: { [string]: any })
	controllers = all
end

function SquadController:Start()
	emoteRemote = Net.event("Squad", "Emote")
	Net.event("Squad", "Fx").OnClientEvent:Connect(function(kind: string, userId: number, a: any, b: any)
		local ok, err = pcall(onFx, kind, userId, a, b)
		if not ok then
			warn(`[SquadController] fx: {err}`)
		end
	end)
	makeGui()
	LocalPlayer.CharacterAdded:Connect(watchOwnPrompts)
	if LocalPlayer.Character then
		task.spawn(watchOwnPrompts, LocalPlayer.Character)
	end
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		local emote = EMOTE_KEYS[input.KeyCode]
		if not emote or not inLobby() or LocalPlayer:GetAttribute(Names.Attr.Downed) == true then
			return
		end
		if os.clock() - lastEmote < 1.05 then
			return
		end
		lastEmote = os.clock()
		local target = if emote == "blame" then pickBlameTarget() else nil
		if emoteRemote then
			emoteRemote:FireServer(emote, target and target.UserId)
		end
	end)
	RunService.RenderStepped:Connect(function()
		local ok, err = pcall(stepDowned)
		if not ok then
			warn(`[SquadController] downed fx: {err}`)
		end
		stepUi()
	end)
	Players.PlayerRemoving:Connect(function(p)
		if p.Character then
			clearDownedFx(p.Character)
		end
	end)
end

return SquadController
