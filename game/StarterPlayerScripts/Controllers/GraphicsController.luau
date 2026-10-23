--!strict
-- GraphicsController [owner: AV lane]. Client-side look: per-location lighting, smoke/heat grading and a
-- cheap material pass. Everything here is local to this player, so parallel squads in different
-- mission instances each see their own location's look while the server keeps the lobby baseline.
--
-- Location = Player attr InstanceId -> Workspace.Instances.<id> attr LocationId; in the lobby (or v1's
-- single round) the Workspace.Map location whose bounding box holds the camera; else the server's
-- Lighting attr LocationPreset. Preset = Player attr AtmospherePreset (override, AtmosphereService:
-- SetPlayerPreset) > AtmosphereConfig.LocationPresets[location] > server's Lighting attr AtmospherePreset.
-- Changing preset blends every number/colour over AtmosphereConfig.TweenSeconds (ClockTime too, so
-- the sun visibly sweeps when you roll out to a night mission).
--
-- Overlays (blended on top, weights smoothed per frame):
--   Smoke: nearby Burning parts within SmokeRadius of the camera, x full when a roof raycast says
--          "indoors" (doc's smoke-filled room, no hand-placed zones needed).
--   Heat:  Player attr Heat (HeatService) above HeatFrom -> warm tint. Off by default
--          (AtmosphereConfig.HeatOverlay): FirstPersonController already grades heat.
-- Material pass: SmoothPlastic parts in the player's current location get a real Enum.Material from
--   the part attr MaterialHint or AtmosphereConfig.MaterialPass.Rules (by name). Chunked per frame.
--
-- API (other controllers, nil-guarded):
--   GraphicsController:GetLocationId(): string?     -- where the player is (AudioController uses it)
--   GraphicsController:GetPreset(): string?         -- preset currently blended to
--   GraphicsController:ForcePreset(name: string?)   -- local debug override (nil clears)
--   GraphicsController:GetSmoke(): number           -- current smoke overlay weight 0..1
--   GraphicsController:SetPostHook(fn: ((values) -> ())?) -- ShaderController: edit the composed
--     { kind -> { prop -> value } } right before it is written (graphics tiers). nil clears.
--   GraphicsController:MarkDirty()                   -- force a recompose + write next frame
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("AtmosphereConfig") :: ModuleScript) :: any
local AvLogic = require(script.Parent.Parent:WaitForChild("Lib"):WaitForChild("AvLogic") :: ModuleScript)

local GraphicsController = {}
GraphicsController.Priority = 20

local player = Players.LocalPlayer

local KIND_CLASS: { [string]: string } = {
	Lighting = "Lighting",
	Atmosphere = "Atmosphere",
	Sky = "Sky",
	Clouds = "Clouds",
	ColorCorrection = "ColorCorrectionEffect",
	Bloom = "BloomEffect",
	SunRays = "SunRaysEffect",
	DepthOfField = "DepthOfFieldEffect",
}

type Values = { [string]: { [string]: any } } -- kind -> prop -> value

local state = {
	presetName = nil :: string?,
	from = nil :: Values?,
	to = nil :: Values?,
	alpha = 1,
	blendSeconds = 1,
	dirty = true,
	smoke = 0,
	smokeTarget = 0,
	heat = 0,
	heatTarget = 0,
	locationId = nil :: string?,
	locationModel = nil :: Instance?,
	forced = nil :: string?,
	insts = {} :: { [string]: Instance },
}

local burning: { [BasePart]: true } = {}
local postHook: ((Values) -> ())? = nil

-- Effect instances ------------------------------------------------------------------------------------

local function findOrMake(kind: string): Instance?
	if kind == "Lighting" then
		return Lighting
	end
	local cached = state.insts[kind]
	if cached and cached.Parent then
		return cached
	end
	local class = KIND_CLASS[kind]
	local parent: Instance? = if kind == "Clouds" then workspace:FindFirstChildOfClass("Terrain") else Lighting
	if not class or not parent then
		return nil
	end
	-- Prefer the server's replicated Forge_<Kind>; else a Studio default with the plain name; else make a
	-- local one. Never grab another controller's effect (e.g. FirstPersonController's FirstPersonHeatCC).
	local inst: Instance? = parent:FindFirstChild("Forge_" .. kind)
	if not (inst and inst:IsA(class)) then
		inst = nil
		for _, child in parent:GetChildren() do
			if child:IsA(class) and (child.Name == kind or child.Name == class) then
				inst = child
				break
			end
		end
	end
	if not inst then
		local ok, made = pcall(Instance.new, class)
		if not ok then
			return nil
		end
		made.Name = "Forge_" .. kind
		made.Parent = parent
		inst = made
	end
	state.insts[kind] = inst :: Instance
	return inst
end

-- Value maths -----------------------------------------------------------------------------------------

local function lerpValue(a: any, b: any, t: number): any
	if t >= 1 then
		return b
	end
	if t <= 0 or a == nil then
		return if a == nil then b else a
	end
	local ta, tb = typeof(a), typeof(b)
	if ta == "number" and tb == "number" then
		return AvLogic.lerp(a, b, t)
	elseif ta == "Color3" and tb == "Color3" then
		return (a :: Color3):Lerp(b :: Color3, t)
	end
	return b -- booleans and anything else snap to the target
end

local function copyPreset(p: any): Values
	local out: Values = {}
	for kind in KIND_CLASS do
		local props = p and p[kind]
		if props then
			local t = {}
			for k, v in props do
				t[k] = v
			end
			out[kind] = t
		end
	end
	return out
end

local function ease(t: number): number
	return t * t * (3 - 2 * t) -- smoothstep
end

local function composeBase(): Values
	local to = state.to :: Values
	local from = state.from or to
	local t = ease(math.clamp(state.alpha, 0, 1))
	local out: Values = {}
	for kind, props in to do
		local f = from[kind] or {}
		local o = {}
		for k, v in props do
			o[k] = lerpValue(f[k], v, t)
		end
		out[kind] = o
	end
	return out
end

local function applyOverlay(values: Values, overlay: any, w: number)
	if not overlay or w <= 0.001 then
		return
	end
	for kind, props in overlay do
		local target = values[kind]
		if target then
			for k, v in props :: { [string]: any } do
				if target[k] ~= nil then
					target[k] = lerpValue(target[k], v, w)
				end
			end
		end
	end
end

local warned: { [string]: boolean } = {}

local function write(values: Values)
	for kind, props in values do
		local inst = findOrMake(kind)
		if inst then
			for k, v in props do
				local ok = pcall(function()
					if (inst :: any)[k] ~= v then
						(inst :: any)[k] = v
					end
				end)
				if not ok and not warned[kind .. k] then
					warned[kind .. k] = true
					warn(`[GraphicsController] cannot set {kind}.{k}`)
				end
			end
		end
	end
end

-- Location ----------------------------------------------------------------------------------------------

type Box = { cf: CFrame, half: Vector3 }
local mapBoxes: { [Instance]: Box } = {}
local boxesAt = -math.huge

local function refreshBoxes()
	table.clear(mapBoxes)
	local map = workspace:FindFirstChild("Map")
	if not map then
		return
	end
	for _, m in map:GetChildren() do
		if m:IsA("Model") and m:GetAttribute(Names.Attr.LocationId) ~= nil then
			local ok, cf, size = pcall(function()
				return (m :: Model):GetBoundingBox()
			end)
			if ok then
				mapBoxes[m] = { cf = cf, half = size / 2 }
			end
		end
	end
	boxesAt = os.clock()
end

local function v3(p: Vector3): AvLogic.P3
	return { x = p.X, y = p.Y, z = p.Z }
end

local ZERO: AvLogic.P3 = { x = 0, y = 0, z = 0 }

local function resolveLocation(): (string?, Instance?)
	local iid = player:GetAttribute(Names.Attr.InstanceId)
	if type(iid) == "string" and iid ~= "" then
		local folder = workspace:FindFirstChild("Instances")
		local model = folder and folder:FindFirstChild(iid)
		local loc = model and model:GetAttribute(Names.Attr.LocationId)
		if type(loc) == "string" then
			return loc, model
		end
	end
	if os.clock() - boxesAt > 10 then
		refreshBoxes()
	end
	local cam = workspace.CurrentCamera
	if cam then
		local margin = Cfg.LocationMargin or 40
		for model, box in mapBoxes do
			if model.Parent then
				local local3 = box.cf:PointToObjectSpace(cam.CFrame.Position)
				if AvLogic.inBox(v3(local3), ZERO, v3(box.half), margin) then
					local loc = model:GetAttribute(Names.Attr.LocationId)
					if type(loc) == "string" then
						return loc, model
					end
				end
			end
		end
	end
	local serverLoc = Lighting:GetAttribute(Names.Attr.LocationPreset)
	return if type(serverLoc) == "string" then serverLoc else nil, nil
end

local function presetExists(name: string): boolean
	return Cfg.Presets[name] ~= nil
end

local function wantedPreset(locationId: string?): string
	local override = state.forced
	if not override then
		local attr = player:GetAttribute("AtmospherePreset")
		override = if type(attr) == "string" then attr else nil
	end
	local serverDefault = Lighting:GetAttribute("AtmospherePreset")
	return AvLogic.pickPreset(
		override,
		locationId,
		Cfg.LocationPresets or {},
		if type(serverDefault) == "string" then serverDefault else nil,
		Cfg.Default,
		presetExists
	)
end

local function blendTo(name: string, seconds: number)
	if name == state.presetName then
		return
	end
	local preset = Cfg.Presets[name]
	if not preset then
		return
	end
	state.from = if state.to then composeBase() else nil
	state.to = copyPreset(preset)
	state.presetName = name
	state.alpha = if state.from == nil or seconds <= 0 then 1 else 0
	state.blendSeconds = math.max(0.05, seconds)
	state.dirty = true
end

-- Material pass -------------------------------------------------------------------------------------------

local materialCache: { [string]: Enum.Material | false } = {}
local passed: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local passQueue: { Instance } = {}

local function materialNamed(name: string): Enum.Material?
	local cached = materialCache[name]
	if cached == nil then
		local ok, item = pcall(function()
			return (Enum.Material :: any)[name]
		end)
		cached = if ok and item then item else false
		materialCache[name] = cached
	end
	return if cached then cached :: Enum.Material else nil
end

local function materialFor(part: BasePart): Enum.Material?
	local hint = part:GetAttribute("MaterialHint")
	if type(hint) == "string" then
		return materialNamed(hint)
	end
	if part.Material ~= Enum.Material.SmoothPlastic and part.Material ~= Enum.Material.Plastic then
		return nil
	end
	if part.Transparency >= 0.95 then
		return nil
	end
	local lname = string.lower(part.Name)
	for _, rule in Cfg.MaterialPass.Rules do
		if string.find(lname, rule[1], 1, true) then
			return materialNamed(rule[2])
		end
	end
	return nil
end

local function queueMaterialPass(root: Instance?)
	local mp = Cfg.MaterialPass
	if not root or not mp or not mp.Enabled or passed[root] then
		return
	end
	passed[root] = true
	table.insert(passQueue, root)
end

local function runMaterialPasses()
	while true do
		local root = table.remove(passQueue, 1)
		if not root then
			task.wait(0.5)
			continue
		end
		local list = root:GetDescendants()
		local per = math.max(20, Cfg.MaterialPass.PerFrame or 250)
		local changed = 0
		for i, d in list do
			if d:IsA("BasePart") and not CollectionService:HasTag(d, Names.Tag.Burning) then
				local m = materialFor(d)
				if m and d.Material ~= m then
					d.Material = m
					changed += 1
				end
			end
			if i % per == 0 then
				task.wait()
			end
		end
		if changed > 0 then
			print(`[GraphicsController] material pass {root.Name}: {changed} parts`)
		end
	end
end

-- Overlays ------------------------------------------------------------------------------------------------

local roofParams = RaycastParams.new()
roofParams.FilterType = Enum.RaycastFilterType.Exclude
roofParams.IgnoreWater = true

local function isIndoors(pos: Vector3): boolean
	local ignore: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	roofParams.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(pos, Vector3.new(0, Cfg.RoofCheck or 45, 0), roofParams)
	return hit ~= nil and hit.Instance.Transparency < 0.9
end

local function sampleOverlays()
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local pos = cam.CFrame.Position
	local r = Cfg.SmokeRadius or 22
	local r2 = r * r
	local near = 0
	for part in burning do
		if part.Parent then
			local d = part.Position - pos
			if d:Dot(d) <= r2 then
				near += 1
			end
		else
			burning[part] = nil
		end
	end
	state.smokeTarget = if near > 0 then AvLogic.smokeWeight(near, isIndoors(pos), Cfg.SmokeFullAt or 5) else 0
	if player:GetAttribute("GasMask") == true then
		state.smokeTarget = 0 -- gear: the gas mask sees through smoke (GearController draws the mask frame)
	end
	local heat = player:GetAttribute(Names.Attr.Heat)
	local from = Cfg.HeatFrom or 25
	state.heatTarget = if type(heat) == "number" then math.clamp((heat - from) / math.max(1, 100 - from), 0, 1) else 0
end

-- Frame ---------------------------------------------------------------------------------------------------

local function step(dt: number)
	if not state.to then
		return
	end
	if state.alpha < 1 then
		state.alpha = math.min(1, state.alpha + dt / state.blendSeconds)
		state.dirty = true
	end
	local k = math.min(1, dt * (Cfg.OverlayResponse or 2.5))
	local ns = state.smoke + (state.smokeTarget - state.smoke) * k
	local nh = state.heat + (state.heatTarget - state.heat) * k
	if math.abs(ns - state.smoke) > 0.001 or math.abs(nh - state.heat) > 0.001 then
		state.dirty = true
	end
	state.smoke, state.heat = ns, nh
	if not state.dirty then
		return
	end
	state.dirty = false
	local values = composeBase()
	applyOverlay(values, Cfg.Overlays and Cfg.Overlays.Smoke, state.smoke)
	if Cfg.HeatOverlay then
		applyOverlay(values, Cfg.Overlays and Cfg.Overlays.Heat, state.heat)
	end
	if postHook then
		local ok, err = pcall(postHook, values)
		if not ok and not warned.postHook then
			warned.postHook = true
			warn(`[GraphicsController] post hook failed: {err}`)
		end
	end
	write(values)
end

-- Controller ----------------------------------------------------------------------------------------------

function GraphicsController:Init(_controllers: { [string]: any }) end

function GraphicsController:Start()
	-- Let the server's Forge_* effects replicate first so we reuse them instead of making doubles.
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end
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

	-- The server re-applying a preset overwrites our local values: force a full rewrite.
	Lighting:GetAttributeChangedSignal("AtmospherePreset"):Connect(function()
		state.dirty = true
	end)

	local loc, model = resolveLocation()
	state.locationId, state.locationModel = loc, model
	blendTo(wantedPreset(loc), 0)
	queueMaterialPass(model)

	task.spawn(runMaterialPasses)
	RunService.RenderStepped:Connect(step)

	task.spawn(function()
		local lastLoc = 0
		while true do
			task.wait(1 / math.max(1, Cfg.SmokeHz or 5))
			sampleOverlays()
			if os.clock() - lastLoc >= 1 / math.max(0.2, Cfg.LocationHz or 2) then
				lastLoc = os.clock()
				local l, m = resolveLocation()
				if l ~= state.locationId or m ~= state.locationModel then
					state.locationId, state.locationModel = l, m
					queueMaterialPass(m)
				end
				blendTo(wantedPreset(l), Cfg.TweenSeconds or 2.5)
			end
		end
	end)
end

function GraphicsController:GetLocationId(): string?
	return state.locationId
end

function GraphicsController:GetPreset(): string?
	return state.presetName
end

function GraphicsController:ForcePreset(name: string?)
	state.forced = name
	blendTo(wantedPreset(state.locationId), Cfg.TweenSeconds or 2.5)
end

function GraphicsController:GetSmoke(): number
	return state.smoke
end

function GraphicsController:SetPostHook(fn: ((Values) -> ())?)
	postHook = fn
	state.dirty = true
end

function GraphicsController:MarkDirty()
	state.dirty = true
end

return GraphicsController
