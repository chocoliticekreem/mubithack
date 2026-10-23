--!strict
-- ShaderController [owner: Graphics/shader lane]. The game's "shader pack" (RoShade-style look built
-- from engine post effects, since Roblox has no custom shaders). Client-local; nothing replicates.
-- Contract + manual Studio settings: docs/game/09-graphics-ultra.md. Numbers: Config/ShaderConfig.
-- Maths (tiers, blends, weights): ClientLib/PostFx (spec: game/tests/shader.spec.luau).
--
-- Quality tiers Low / High / Ultra:
--   * auto-detected from the Roblox graphics slider, device class and measured fps (PostFx.detectTier),
--     re-checked while playing in Auto (PostFx.adaptTier steps down when fps sags);
--   * forced from a lobby button (GRAPHICS: AUTO/LOW/HIGH/ULTRA), saved via Data/Setting
--     ("graphicsQuality", 0..3); DataService mirrors it to Player attr GraphicsQuality.
-- What a tier changes:
--   * GraphicsController:SetPostHook -> ShaderConfig.TierMods[tier] on top of the location preset
--     (Low: no shadows/bloom/sunrays/DoF; Ultra: fire-tuned Bloom, stronger SunRays, haze/glare) and
--     DepthOfField pulses with camera speed (sprint / driving "motion blur" proxy).
--   * Lighting.Shader_Lift + Shader_Filmic: layered ColorCorrections = per-location cinematic grade
--     (lift/gamma approximation), blended with the location preset; Shader_FireGlow: warm grade that
--     follows FireFxController's own flickering PointLights (read-only, we never add fire lights).
--   * Lighting.Shader_Haze (BlurEffect) + warm wavy band: heat shimmer near fires.
--   * ScreenGui ShaderFx: edge vignette, chromatic edge fringe, lens dirt (sun / fire glare), film grain.
--   * Wet-road illusion: Reflectance on road parts under Wet grades (night), restored otherwise.
--   * Volumetric light shafts: gradient Beams along the sun/moon direction through nearby smoke columns.
--   * Driving FOV kick (additive, plays nice with FirstPersonController / ToolController FOV writes).
-- API (nil-guarded by callers):
--   ShaderController:GetTier(): "Low" | "High" | "Ultra"
--   ShaderController:GetSetting(): number            -- 0 Auto, 1 Low, 2 High, 3 Ultra
--   ShaderController:SetSetting(n: number)           -- applies + saves (same as the lobby button)
--   ShaderController:_stats() -> { tier, setting, fps, glow, haze, motion, shafts, wet }
local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ShaderConfig") :: ModuleScript) :: any
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local PostFx = require(ClientLib:WaitForChild("PostFx") :: ModuleScript)
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript)

local ShaderController = {}
ShaderController.Priority = 25 -- after GraphicsController (20)

local player = Players.LocalPlayer
local Graphics: any = nil

type Tier = PostFx.Tier
type Grade = PostFx.Grade

local state = {
	setting = 0,
	detected = "High" :: Tier,
	tier = "High" :: Tier,
	adapt = PostFx.newAdaptState(),
	fps = 60,
	sampled = false,
	presetName = nil :: string?,
	gradeFrom = nil :: Grade?,
	gradeTo = nil :: Grade?,
	gradeAlpha = 1,
	grade = nil :: Grade?,
	motion = 0,
	motionWritten = 0,
	camPrev = nil :: Vector3?,
	camSpeed = 0,
	haze = 0,
	hazeTarget = 0,
	glow = 0,
	lens = 0,
	grainAt = 0,
	driveSpeed = 0,
	fovKick = 0,
	fovApplied = 0,
	fovWritten = nil :: number?,
}

local burning: { [BasePart]: true } = {}
local fireLights: { PointLight } = {}
local rng = Random.new()

-- Helpers ------------------------------------------------------------------------------------------------

local function c3(rgb: PostFx.RGB): Color3
	return Color3.new(rgb.r, rgb.g, rgb.b)
end

local function hex3(h: string): Color3
	return c3(PostFx.hex(h))
end

local function budget(): { [string]: any }
	return Cfg.Budgets[state.tier] or Cfg.Budgets.High
end

local function gradeFor(presetName: string?): Grade
	local raw = (presetName and Cfg.Grades[presetName]) or Cfg.Grades.Default
	return PostFx.grade(raw)
end

local function seq(points: { { number } }): NumberSequence
	local kps = {}
	for _, p in points do
		table.insert(kps, NumberSequenceKeypoint.new(math.clamp(p[1], 0, 1), math.clamp(p[2], 0, 1)))
	end
	return NumberSequence.new(kps)
end

-- Instances (all made in Start, local to this client) --------------------------------------------------

local fx = {
	lift = nil :: ColorCorrectionEffect?,
	filmic = nil :: ColorCorrectionEffect?,
	glowCC = nil :: ColorCorrectionEffect?,
	blur = nil :: BlurEffect?,
	gui = nil :: ScreenGui?,
	vignette = {} :: { UIGradient },
	fringe = {} :: { UIGradient },
	lensBlobs = {} :: { { frame: GuiObject, alpha: number } },
	lensImage = nil :: ImageLabel?,
	grain = {} :: { UIGradient },
	grainImage = nil :: ImageLabel?,
	hazeBand = nil :: Frame?,
	hazeGrad = nil :: UIGradient?,
	anchor = nil :: BasePart?,
	shafts = {} :: { { top: Attachment, bottom: Attachment, beams: { Beam } } },
	settingsGui = nil :: ScreenGui?,
	settingsButton = nil :: TextButton?,
}

local lastVignette, lastFringe = -1, -1

local function cc(name: string): ColorCorrectionEffect
	local existing = Lighting:FindFirstChild(name)
	if existing and existing:IsA("ColorCorrectionEffect") then
		return existing
	end
	local e = Instance.new("ColorCorrectionEffect")
	e.Name = name
	e.Parent = Lighting
	return e
end

local function edgeGradient(parent: Instance, name: string, color: Color3, size: UDim2, pos: UDim2, rotation: number): UIGradient
	local f = Instance.new("Frame")
	f.Name = name
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color
	f.BackgroundTransparency = 0
	f.Size = size
	f.Position = pos
	f.Active = false
	f.Parent = parent
	local g = Instance.new("UIGradient")
	g.Rotation = rotation
	g.Transparency = NumberSequence.new(1)
	g.Parent = f
	return g
end

local function buildOverlay()
	local gui = Instance.new("ScreenGui")
	gui.Name = "ShaderFx"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.DisplayOrder = Cfg.OverlayDisplayOrder or -10
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	fx.gui = gui

	-- Edge vignette: 4 gradients from the edges inwards (corners overlap = darker corners, like a lens).
	local d = Cfg.VignetteDepth or 0.28
	local vc = hex3(Cfg.VignetteColor or "#000000")
	fx.vignette = {
		edgeGradient(gui, "VigL", vc, UDim2.fromScale(d, 1), UDim2.fromScale(0, 0), 0),
		edgeGradient(gui, "VigR", vc, UDim2.fromScale(d, 1), UDim2.fromScale(1 - d, 0), 180),
		edgeGradient(gui, "VigT", vc, UDim2.fromScale(1, d), UDim2.fromScale(0, 0), 90),
		edgeGradient(gui, "VigB", vc, UDim2.fromScale(1, d), UDim2.fromScale(0, 1 - d), 270),
	}
	-- Chromatic fringe: thin red (left/right) and cyan (top/bottom) edges, like cheap-lens aberration.
	local fd = 0.05
	fx.fringe = {
		edgeGradient(gui, "FringeL", Color3.fromRGB(255, 40, 30), UDim2.fromScale(fd, 1), UDim2.fromScale(0, 0), 0),
		edgeGradient(gui, "FringeR", Color3.fromRGB(255, 40, 30), UDim2.fromScale(fd, 1), UDim2.fromScale(1 - fd, 0), 180),
		edgeGradient(gui, "FringeT", Color3.fromRGB(30, 200, 255), UDim2.fromScale(1, fd), UDim2.fromScale(0, 0), 90),
		edgeGradient(gui, "FringeB", Color3.fromRGB(30, 200, 255), UDim2.fromScale(1, fd), UDim2.fromScale(0, 1 - fd), 270),
	}

	-- Lens dirt: an image if configured, else soft procedural smudges.
	local lensId = Cfg.Images and Cfg.Images.LensDirt or ""
	if lensId ~= "" then
		local img = Instance.new("ImageLabel")
		img.Name = "LensDirt"
		img.BackgroundTransparency = 1
		img.Size = UDim2.fromScale(1, 1)
		img.Image = lensId
		img.ImageTransparency = 1
		img.Parent = gui
		fx.lensImage = img
	else
		local lensRng = Random.new(67) -- fixed seed: the same smudges every session, like a real lens
		for i = 1, Cfg.LensBlobs or 7 do
			local s = lensRng:NextNumber(0.12, 0.34)
			local f = Instance.new("Frame")
			f.Name = "Lens" .. i
			f.BorderSizePixel = 0
			f.BackgroundColor3 = Color3.fromRGB(255, 236, 200)
			f.BackgroundTransparency = 1
			f.SizeConstraint = Enum.SizeConstraint.RelativeYY
			f.Size = UDim2.fromScale(s, s)
			f.AnchorPoint = Vector2.new(0.5, 0.5)
			f.Position = UDim2.fromScale(lensRng:NextNumber(0.08, 0.92), lensRng:NextNumber(0.1, 0.9))
			f.Parent = gui
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0.5, 0)
			corner.Parent = f
			local g = Instance.new("UIGradient")
			g.Rotation = lensRng:NextNumber(0, 180)
			g.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.5, 0),
				NumberSequenceKeypoint.new(1, 1),
			})
			g.Parent = f
			table.insert(fx.lensBlobs, { frame = f, alpha = lensRng:NextNumber(0.4, 1) })
		end
	end

	-- Film grain: a tiled noise image if configured, else two re-rolled gradient layers (light + dark).
	local grainId = Cfg.Images and Cfg.Images.Grain or ""
	if grainId ~= "" then
		local img = Instance.new("ImageLabel")
		img.Name = "Grain"
		img.BackgroundTransparency = 1
		img.Size = UDim2.new(1, 256, 1, 256)
		img.Image = grainId
		img.ScaleType = Enum.ScaleType.Tile
		img.TileSize = UDim2.fromOffset(256, 256)
		img.ImageTransparency = 1
		img.Parent = gui
		fx.grainImage = img
	else
		for i, col in { Color3.new(1, 1, 1), Color3.new(0, 0, 0) } do
			local f = Instance.new("Frame")
			f.Name = "Grain" .. i
			f.BorderSizePixel = 0
			f.BackgroundColor3 = col
			f.Size = UDim2.fromScale(1.5, 1.5)
			f.AnchorPoint = Vector2.new(0.5, 0.5)
			f.Position = UDim2.fromScale(0.5, 0.5)
			f.Parent = gui
			local g = Instance.new("UIGradient")
			g.Transparency = NumberSequence.new(1)
			g.Parent = f
			table.insert(fx.grain, g)
		end
	end

	-- Heat shimmer band (bottom of the screen, wavy warm gradient).
	local band = Instance.new("Frame")
	band.Name = "HeatShimmer"
	band.BorderSizePixel = 0
	band.BackgroundColor3 = hex3(Cfg.HazeTint or "#FFB070")
	band.Size = UDim2.fromScale(1, 0.4)
	band.Position = UDim2.fromScale(0, 0.6)
	band.Visible = false
	band.Parent = gui
	local hg = Instance.new("UIGradient")
	hg.Rotation = 90
	hg.Transparency = NumberSequence.new(1)
	hg.Parent = band
	fx.hazeBand, fx.hazeGrad = band, hg

	gui.Parent = player:WaitForChild("PlayerGui")
end

local function buildShafts()
	local anchor = Instance.new("Part")
	anchor.Name = "ShaderShaftAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.CFrame = CFrame.new(0, -500, 0)
	anchor.Parent = workspace
	fx.anchor = anchor
end

local function ensureShaft(i: number)
	local anchor = fx.anchor
	if fx.shafts[i] or not anchor then
		return
	end
	local top = Instance.new("Attachment")
	top.Name = "ShaftTop" .. i
	top.Parent = anchor
	local bottom = Instance.new("Attachment")
	bottom.Name = "ShaftBottom" .. i
	bottom.Parent = anchor
	local beams = {}
	for j = 1, 2 do
		local b = Instance.new("Beam")
		b.Name = `Shaft{i}_{j}`
		b.Attachment0 = top
		b.Attachment1 = bottom
		b.FaceCamera = true
		b.Segments = 1
		b.LightEmission = 1
		b.LightInfluence = 0
		b.Texture = ""
		b.Enabled = false
		b.Parent = anchor
		table.insert(beams, b)
	end
	fx.shafts[i] = { top = top, bottom = bottom, beams = beams }
end

-- Settings UI -------------------------------------------------------------------------------------------

local function inLobby(): boolean
	local iid = player:GetAttribute(Names.Attr.InstanceId)
	return iid == nil or iid == ""
end

local function refreshButton()
	local b = fx.settingsButton
	if b then
		b.Text = PostFx.settingLabel(state.setting, state.tier)
	end
	if fx.settingsGui then
		fx.settingsGui.Enabled = inLobby()
	end
end

-- Tier ----------------------------------------------------------------------------------------------------

local applyTier: (Tier) -> ()

local function deviceInfo(): PostFx.DeviceInfo
	local q = 0
	pcall(function()
		local s = UserSettings():GetService("UserGameSettings")
		q = (s.SavedQualityLevel :: any).Value
	end)
	local isConsole = false
	pcall(function()
		isConsole = GuiService:IsTenFootInterface()
	end)
	return {
		savedQuality = q,
		isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled,
		isConsole = isConsole,
		fps = if state.sampled then state.fps else nil,
	}
end

local function redetect()
	state.detected = PostFx.detectTier(deviceInfo(), Cfg.Detect)
	applyTier(PostFx.resolveTier(state.setting, state.detected))
end

local function setSetting(n: number, save: boolean)
	n = math.clamp(math.floor(n), 0, 3)
	state.setting = n
	state.adapt = PostFx.newAdaptState()
	redetect()
	if save then
		task.spawn(function()
			local ok, err = pcall(function()
				Net.event("Data", "Setting"):FireServer(Cfg.SettingKey, n)
			end)
			if not ok then
				warn(`[ShaderController] could not save graphics setting: {err}`)
			end
		end)
	end
end

-- Grade ----------------------------------------------------------------------------------------------------

local function followPreset()
	local name = Graphics and type(Graphics.GetPreset) == "function" and Graphics:GetPreset() or nil
	if name == state.presetName and state.gradeTo then
		return
	end
	state.presetName = name
	local target = gradeFor(name)
	if not state.grade then
		state.gradeFrom, state.gradeTo, state.gradeAlpha, state.grade = target, target, 1, target
	else
		state.gradeFrom, state.gradeTo, state.gradeAlpha = state.grade, target, 0
	end
end

local function writeCC(e: ColorCorrectionEffect?, c: PostFx.CC, on: boolean)
	if not e then
		return
	end
	e.Enabled = on
	if on then
		e.Brightness = c.brightness
		e.Contrast = c.contrast
		e.Saturation = c.saturation
		e.TintColor = c3(c.tint)
	end
end

-- Wet roads -------------------------------------------------------------------------------------------------

local roads: { [BasePart]: number } = setmetatable({}, { __mode = "k" }) :: any -- part -> original Reflectance
local roadCount = 0
local wetOn = false

local function isRoad(p: BasePart): boolean
	if p.Material == Enum.Material.Asphalt then
		return true
	end
	local n = string.lower(p.Name)
	for _, pat in Cfg.WetNamePatterns do
		if string.find(n, pat, 1, true) then
			return true
		end
	end
	return false
end

local function scanRoads()
	local map = workspace:FindFirstChild("Map")
	if not map then
		return
	end
	local list = map:GetDescendants()
	for i, d in list do
		if roadCount >= (Cfg.WetMaxParts or 600) then
			break
		end
		if d:IsA("BasePart") and roads[d] == nil and d.Transparency < 0.9 and isRoad(d) then
			roads[d] = d.Reflectance
			roadCount += 1
			if wetOn then
				d.Reflectance = math.max(d.Reflectance, Cfg.WetReflectance or 0.14)
			end
		end
		if i % 400 == 0 then
			task.wait()
		end
	end
end

local function setWet(on: boolean)
	if on == wetOn then
		return
	end
	wetOn = on
	for part, orig in roads do
		if part.Parent then
			part.Reflectance = if on then math.max(orig, Cfg.WetReflectance or 0.14) else orig
		end
	end
end

-- Fires: sampling (SampleHz) ------------------------------------------------------------------------------

type Cluster = { pos: Vector3, count: number }
local clusters: { Cluster } = {}

local function sampleFires()
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	local hazeR2 = (Cfg.HazeRadius or 20) ^ 2
	local glowR2 = (Cfg.FireGlow.Radius or 60) ^ 2
	local shaftR2 = (Cfg.ShaftRadius or 150) ^ 2
	local near = 0
	local lights: { { any } } = {}
	local fires: { { any } } = {}
	for part in burning do
		if not part.Parent then
			burning[part] = nil
			continue
		end
		local pos = part.Position
		local d2 = (pos - camPos):Dot(pos - camPos)
		if d2 <= hazeR2 then
			near += 1
		end
		if d2 <= glowR2 then
			local a = part:FindFirstChild("FireFx")
			local l = a and a:FindFirstChildOfClass("PointLight")
			if l then
				table.insert(lights, { l, d2 })
			end
		end
		if d2 <= shaftR2 then
			table.insert(fires, { pos, d2 })
		end
	end
	state.hazeTarget = PostFx.clamp01(near / math.max(1, Cfg.HazeFullAt or 6))

	table.sort(lights, function(a, b)
		return a[2] < b[2]
	end)
	table.clear(fireLights)
	for i = 1, math.min(#lights, Cfg.FireGlow.MaxLights or 6) do
		table.insert(fireLights, lights[i][1])
	end

	-- greedy clustering, nearest first
	table.sort(fires, function(a, b)
		return a[2] < b[2]
	end)
	table.clear(clusters)
	local cr = Cfg.ShaftCluster or 30
	for _, f in fires do
		local pos = f[1] :: Vector3
		local merged = false
		for _, c in clusters do
			if (c.pos - pos).Magnitude <= cr then
				c.pos = c.pos:Lerp(pos, 1 / (c.count + 1))
				c.count += 1
				merged = true
				break
			end
		end
		if not merged then
			table.insert(clusters, { pos = pos, count = 1 })
		end
	end
end

local function updateShafts()
	local want = budget().shafts or 0
	local g = state.grade
	local sun = Lighting:GetSunDirection()
	local dir, scale = sun, 1
	if sun.Y < 0.05 then
		dir, scale = Lighting:GetMoonDirection(), Cfg.ShaftNightScale or 0.5
	end
	if dir.Y < 0.15 then
		dir = Vector3.new(dir.X, 0.15, dir.Z) -- keep shafts slanting down even at sunset
	end
	dir = dir.Unit
	local flat = Vector3.new(dir.X, 0, dir.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zero
	local h = Cfg.ShaftHeight or 22
	local a = (Cfg.ShaftAlpha or 0.16) * scale
	local color = ColorSequence.new(if g then c3(g.shaft) else Color3.new(1, 0.85, 0.65))
	for i = 1, math.max(want, #fx.shafts) do
		local c = if i <= want then clusters[i] else nil
		if c then
			ensureShaft(i)
		end
		local s = fx.shafts[i]
		if s then
			if c then
				local base = c.pos
				s.top.WorldPosition = base + Vector3.new(0, h * 0.5, 0) + dir * h * 0.6
				s.bottom.WorldPosition = base - flat * h * 0.35
				for j, b in s.beams do
					local alpha = a * (if j == 1 then 1 else 0.55) * math.min(1.5, 0.6 + 0.2 * c.count)
					b.Width0 = Cfg.ShaftWidth0 or 5
					b.Width1 = (Cfg.ShaftWidth1 or 12) * (if j == 1 then 1 else 1.7)
					b.Color = color
					b.Transparency = seq({ { 0, 1 }, { 0.3, 1 - alpha }, { 0.7, 1 - alpha * 0.6 }, { 1, 1 } })
					b.Enabled = true
				end
			else
				for _, b in s.beams do
					b.Enabled = false
				end
			end
		end
	end
end

-- Tier application -------------------------------------------------------------------------------------------

applyTier = function(tier: Tier)
	local changed = tier ~= state.tier
	state.tier = tier
	player:SetAttribute(Cfg.TierAttr or "GraphicsTier", tier)
	local b = budget()
	if fx.gui then
		fx.gui.Enabled = b.overlays == true
	end
	if not b.haze and fx.blur then
		fx.blur.Enabled = false
	end
	if not b.fireGlow and fx.glowCC then
		fx.glowCC.Enabled = false
	end
	if (b.shafts or 0) == 0 then
		for _, s in fx.shafts do
			for _, beam in s.beams do
				beam.Enabled = false
			end
		end
	end
	setWet(b.wetRoads == true and state.grade ~= nil and (state.grade :: Grade).wet)
	if changed and Graphics and type(Graphics.MarkDirty) == "function" then
		Graphics:MarkDirty()
	end
	refreshButton()
end

-- GraphicsController post hook: tier mods + motion DoF on top of the location preset.
local function postHook(values: { [string]: { [string]: any } })
	PostFx.applyMods(values, Cfg.TierMods[state.tier])
	local w = state.motion
	state.motionWritten = w
	local dof = values.DepthOfField
	if budget().motionDof and dof and w > 0.002 then
		dof.Enabled = true
		for k, v in Cfg.MotionDof do
			local cur = dof[k]
			dof[k] = if type(cur) == "number" then PostFx.lerp(cur, v, w) else v * w
		end
	end
end

-- Frame --------------------------------------------------------------------------------------------------------

local function step(dt: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local b = budget()
	local t = os.clock()

	-- fps (EMA) + auto adapt
	if dt > 0 then
		state.fps += (1 / dt - state.fps) * math.min(1, dt * 2)
	end
	if state.sampled and state.setting == 0 then
		local nt = PostFx.adaptTier(state.adapt, state.tier, state.fps, dt, Cfg.Adapt, state.detected)
		if nt then
			applyTier(nt)
			b = budget()
		end
	end

	-- grade blend
	followPreset()
	if state.gradeTo then
		if state.gradeAlpha < 1 then
			state.gradeAlpha = math.min(1, state.gradeAlpha + dt / math.max(0.05, Cfg.GradeBlendSeconds or 2.5))
		end
		state.grade = PostFx.blendGrade(state.gradeFrom :: Grade, state.gradeTo :: Grade, PostFx.smoothstep(state.gradeAlpha))
	end
	local g = state.grade
	if not g then
		return
	end
	local gw = b.gradeWeight or 0
	local scaled = PostFx.scaleGrade(g, gw)
	writeCC(fx.lift, scaled.lift, gw > 0)
	writeCC(fx.filmic, scaled.filmic, gw > 0)

	-- camera speed -> motion weight
	local pos = cam.CFrame.Position
	if state.camPrev and dt > 0 then
		local sp = (pos - (state.camPrev :: Vector3)).Magnitude / dt
		if sp > 400 then
			sp = 0 -- teleport / respawn, not motion
		end
		state.camSpeed += (sp - state.camSpeed) * math.min(1, dt * 8)
	end
	state.camPrev = pos
	local mTarget = if b.motionDof then PostFx.motionWeight(state.camSpeed, Cfg.MotionFrom or 16, Cfg.MotionFull or 70) else 0
	state.motion += (mTarget - state.motion) * math.min(1, dt * (Cfg.MotionResponse or 4))
	if math.abs(state.motion - state.motionWritten) > 0.01 and Graphics and type(Graphics.MarkDirty) == "function" then
		Graphics:MarkDirty()
	end

	-- fire glow: follows FireFx's own flickering lights
	local glowCfg = Cfg.FireGlow
	if b.fireGlow and fx.glowCC then
		local list = {}
		for _, l in fireLights do
			if l.Parent and l.Enabled then
				local lp = (l.Parent :: any).WorldPosition or pos
				table.insert(list, { (lp - pos).Magnitude, l.Brightness })
			end
		end
		state.glow = PostFx.fireGlow(list, glowCfg)
		local e = fx.glowCC :: ColorCorrectionEffect
		e.Enabled = state.glow > 0.003
		if e.Enabled then
			e.TintColor = c3(PostFx.lerpRgb({ r = 1, g = 1, b = 1 }, g.fireTint, state.glow * (glowCfg.TintStrength or 0.35)))
			e.Brightness = state.glow * (glowCfg.Brightness or 0.05)
			e.Contrast = 0
			e.Saturation = state.glow * 0.05
		end
	else
		state.glow = 0
	end

	-- heat shimmer
	state.haze += ((if b.haze then state.hazeTarget else 0) - state.haze) * math.min(1, dt * 2)
	if fx.blur then
		local hz = state.haze
		fx.blur.Enabled = hz > 0.01
		if hz > 0.01 then
			fx.blur.Size = hz * (Cfg.HazeBlur or 2.5) * (0.65 + 0.35 * math.sin(t * (Cfg.HazeHz or 7) * math.pi * 2))
		end
	end
	if fx.hazeBand and fx.hazeGrad then
		local hz = state.haze
		fx.hazeBand.Visible = b.overlays and hz > 0.01
		if fx.hazeBand.Visible then
			local a = hz * (Cfg.HazeMaxAlpha or 0.12)
			local wob = 0.04 * math.sin(t * 5.3) + 0.02 * math.sin(t * 11.1)
			fx.hazeGrad.Transparency = seq({ { 0, 1 }, { 0.45 + wob, 1 - a * 0.5 }, { 0.8 - wob, 1 - a }, { 1, 1 - a * 0.6 } })
			fx.hazeGrad.Offset = Vector2.new(0.03 * math.sin(t * 3.1), 0.02 * math.sin(t * 4.7))
		end
	end

	if not b.overlays then
		return
	end

	-- vignette + fringe (rebuild sequences only when they change)
	local v = scaled.vignette
	if math.abs(v - lastVignette) > 0.005 then
		lastVignette = v
		local a = v * (Cfg.VignetteMaxAlpha or 0.55)
		local s = seq({ { 0, 1 - a }, { 0.45, 1 - a * 0.35 }, { 1, 1 } })
		for _, gr in fx.vignette do
			gr.Transparency = s
		end
	end
	local f = scaled.fringe
	if math.abs(f - lastFringe) > 0.005 then
		lastFringe = f
		local a = f * (Cfg.FringeMaxAlpha or 0.12)
		local s = seq({ { 0, 1 - a }, { 1, 1 } })
		for _, gr in fx.fringe do
			gr.Transparency = s
		end
	end

	-- lens dirt: looking toward the sun, or a bright fire
	local lensTarget = 0
	if b.lens then
		local sun = Lighting:GetSunDirection()
		local visible = PostFx.smoothstep((sun.Y + 0.02) / 0.15)
		lensTarget = PostFx.lensWeight(cam.CFrame.LookVector:Dot(sun), visible, Cfg.LensPower or 6)
		lensTarget = PostFx.clamp01(lensTarget + state.glow * (Cfg.LensFireBoost or 0.6)) * scaled.lens
	end
	state.lens += (lensTarget - state.lens) * math.min(1, dt * 3)
	local lensA = state.lens * (Cfg.LensMaxAlpha or 0.22)
	if fx.lensImage then
		fx.lensImage.ImageTransparency = 1 - lensA
	end
	for _, blob in fx.lensBlobs do
		blob.frame.BackgroundTransparency = 1 - lensA * blob.alpha
	end

	-- film grain (re-rolled GrainFps times a second)
	local grainOn = b.grain and scaled.grain > 0.01
	if t >= state.grainAt then
		state.grainAt = t + 1 / math.max(1, Cfg.GrainFps or 24)
		local maxA = scaled.grain * (Cfg.GrainMaxAlpha or 0.07)
		if fx.grainImage then
			fx.grainImage.Visible = grainOn
			fx.grainImage.ImageTransparency = 1 - maxA * 4
			fx.grainImage.Position = UDim2.fromOffset(-rng:NextInteger(0, 255), -rng:NextInteger(0, 255))
		end
		for _, gr in fx.grain do
			local frame = gr.Parent :: GuiObject
			frame.Visible = grainOn
			if grainOn then
				gr.Transparency = seq(PostFx.grainKeypoints(function()
					return rng:NextNumber()
				end, Cfg.GrainKeypoints or 18, maxA))
				gr.Rotation = rng:NextNumber(0, 360)
				gr.Offset = Vector2.new(rng:NextNumber(-0.2, 0.2), rng:NextNumber(-0.2, 0.2))
			end
		end
	end
end

-- Driving FOV kick: additive on top of whatever FirstPersonController / ToolController wrote this frame.
local function fovStep(dt: number)
	local cam = workspace.CurrentCamera
	if not cam or cam.CameraType == Enum.CameraType.Scriptable then
		state.fovWritten = nil
		state.fovApplied = 0
		return
	end
	local target = 0
	local add = budget().driveFov or 0
	if add > 0 then
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local seat = hum and hum.SeatPart
		if seat and seat.Name == "DriveSeat" then
			local v = seat.AssemblyLinearVelocity
			local sp = Vector3.new(v.X, 0, v.Z).Magnitude
			target = add * PostFx.motionWeight(sp, Cfg.DriveFovFrom or 10, Cfg.DriveFovFull or 80)
		end
	end
	state.fovKick += (target - state.fovKick) * math.min(1, dt * 3)
	if math.abs(state.fovKick) < 0.01 and state.fovApplied == 0 then
		return
	end
	local base = cam.FieldOfView
	if state.fovWritten and math.abs(cam.FieldOfView - (state.fovWritten :: number)) < 1e-3 then
		base -= state.fovApplied
	end
	state.fovApplied = if math.abs(state.fovKick) < 0.01 then 0 else state.fovKick
	local fov = math.clamp(base + state.fovApplied, 1, 120)
	cam.FieldOfView = fov
	state.fovWritten = fov
end

-- Controller ----------------------------------------------------------------------------------------------------

function ShaderController:Init(controllers: { [string]: any })
	Graphics = controllers.GraphicsController
end

function ShaderController:Start()
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end

	fx.lift = cc("Shader_Lift")
	fx.filmic = cc("Shader_Filmic")
	fx.glowCC = cc("Shader_FireGlow")
	;(fx.glowCC :: ColorCorrectionEffect).Enabled = false
	local blur = Lighting:FindFirstChild("Shader_Haze")
	if not (blur and blur:IsA("BlurEffect")) then
		blur = Instance.new("BlurEffect")
		blur.Name = "Shader_Haze"
		blur.Parent = Lighting
	end
	fx.blur = blur :: BlurEffect
	;(fx.blur :: BlurEffect).Enabled = false
	buildOverlay()
	buildShafts()

	-- settings button (lobby only)
	local sg = UiKit.screen("GraphicsSettingsUI", 5)
	fx.settingsGui = sg
	local btn = UiKit.button(sg, "Quality", "GRAPHICS", UDim2.fromOffset(250, 40), UDim2.fromOffset(16 + 125, 196), Color3.fromRGB(60, 70, 96))
	btn.TextSize = 20
	fx.settingsButton = btn
	btn.Activated:Connect(function()
		setSetting(PostFx.nextSetting(state.setting), true)
		UiKit.pop(btn, 0.2)
	end)
	player:GetAttributeChangedSignal(Names.Attr.InstanceId):Connect(refreshButton)

	-- persisted setting from DataService (Player attr), then initial pick
	local saved = player:GetAttribute(Cfg.SettingAttr)
	state.setting = if type(saved) == "number" then math.clamp(math.floor(saved), 0, 3) else 0
	player:GetAttributeChangedSignal(Cfg.SettingAttr):Connect(function()
		local v = player:GetAttribute(Cfg.SettingAttr)
		if type(v) == "number" and math.floor(v) ~= state.setting then
			setSetting(v, false)
		end
	end)
	pcall(function()
		local s = UserSettings():GetService("UserGameSettings")
		s:GetPropertyChangedSignal("SavedQualityLevel"):Connect(function()
			if state.setting == 0 then
				redetect()
			end
		end)
	end)
	state.tier = "Ultra" -- force applyTier's change path on the first pick
	redetect()
	if Graphics and type(Graphics.SetPostHook) == "function" then
		Graphics:SetPostHook(postHook)
	else
		warn("[ShaderController] GraphicsController has no SetPostHook; tier preset mods disabled")
	end

	-- burning parts
	for _, p in CollectionService:GetTagged(Names.Tag.Burning) do
		if p:IsA("BasePart") then
			burning[p] = true
		end
	end
	CollectionService:GetInstanceAddedSignal(Names.Tag.Burning):Connect(function(p)
		if p:IsA("BasePart") then
			burning[p] = true
		end
	end)
	CollectionService:GetInstanceRemovedSignal(Names.Tag.Burning):Connect(function(p)
		burning[p :: BasePart] = nil
	end)

	RunService.RenderStepped:Connect(step)
	RunService:BindToRenderStep("ShaderFov", Enum.RenderPriority.Camera.Value + 4, fovStep)

	-- fps sample, then a real detection
	task.delay(Cfg.Detect.SampleSeconds or 4, function()
		state.sampled = true
		if state.setting == 0 then
			redetect()
		end
	end)

	-- slow loop: fires, shafts, wet roads
	task.spawn(function()
		local lastScan = -math.huge
		while true do
			task.wait(1 / math.max(1, Cfg.SampleHz or 4))
			local b = budget()
			if b.fireGlow or b.haze or (b.shafts or 0) > 0 then
				sampleFires()
			else
				table.clear(fireLights)
				table.clear(clusters)
				state.hazeTarget = 0
			end
			if (b.shafts or 0) > 0 or #fx.shafts > 0 then
				updateShafts()
			end
			local wantWet = b.wetRoads == true and state.grade ~= nil and (state.grade :: Grade).wet
			if wantWet and os.clock() - lastScan >= (Cfg.WetScanSeconds or 20) then
				lastScan = os.clock()
				scanRoads()
			end
			setWet(wantWet)
		end
	end)
end

function ShaderController:GetTier(): Tier
	return state.tier
end

function ShaderController:GetSetting(): number
	return state.setting
end

function ShaderController:SetSetting(n: number)
	setSetting(n, true)
end

function ShaderController:_stats(): { [string]: any }
	local shafts = 0
	for _, s in fx.shafts do
		if s.beams[1].Enabled then
			shafts += 1
		end
	end
	return {
		tier = state.tier,
		setting = state.setting,
		detected = state.detected,
		fps = math.floor(state.fps),
		glow = state.glow,
		haze = state.haze,
		motion = state.motion,
		shafts = shafts,
		wet = wetOn,
		roads = roadCount,
		preset = state.presetName,
	}
end

return ShaderController
