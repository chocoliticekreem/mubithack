--!strict
-- EventService [owner: GF]. Rare, goofy "crazy events" that can drop into ANY call once the squad is on
-- scene (EventConfig: Enabled, Chance per call, FirstAfter window, MaxPerMission, Weights). Each event is
-- announced with a banner (Net.notify to the squad) and world popups, runs for a few seconds and cleans
-- itself up; everything it builds lives in Workspace.CrazyEvents (a handful of anchored parts each).
--   news_heli       Channel 67 News chopper circles the site, spotlight + beam on one squad member
--   geyser_hydrant  the site's hydrant erupts: a water column that launches whoever stands on it and
--                   waters the fires around it
--   raccoon         a raccoon runs at a hose holder and steals the nozzle (InventoryService:StowHose puts
--                   it back on the truck reel)
--   rainstorm       a cloud over the site: every fire gets a little water, the squad cools down
--   wind_gust       fire jumps downwind (FireService:Ignite next to burning parts), players get shoved
--   ice_cream       an ice-cream truck parks by the apron: free sundae prompt + a cold aura (HeatService:Cool)
--
-- Public API:
--   EventService:Force(runId: string?, eventId: string): (boolean, string)  -- nil runId = newest Active run
--   EventService:GetActive(runId: string): { string }
-- Signals: EventStarted(runId: string, eventId: string)
-- Consumes (nil-guarded): MissionService:GetMissions/GetMission + .MissionEnded, MapService:GetInstance,
--   FireService:ApplyWater/Ignite, HeatService:Cool, InventoryService:StowHose, VehicleService:GetTruck,
--   Lib/Hazard/Twists.douse (scripted fires), Shared/Ragdoll.knockback, Shared/Popup
-- Reads: tags Burning, Flammable, Hydrant; Player attrs InstanceId, InvHand; run RoundState (raw)
-- Counters: crazy_events, crazy_<eventId>, geyser_rides, raccoon_thefts, sundaes
-- Test hooks (DevHook only): _force(runId?, eventId), _selftest()
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Ragdoll = require(Shared:WaitForChild("Ragdoll") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local EventConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("EventConfig") :: ModuleScript) :: any
local Twists = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Hazard"):WaitForChild("Twists") :: ModuleScript) :: any

local EventService = {}
EventService.Priority = 75
EventService.EventStarted = Signal.new() :: Signal.Signal<string, string>

type Ctx = {
	runId: string,
	root: Model,
	anchor: CFrame, -- the site's ArrivalZone (axes = the site frame; -Z toward the street)
	centre: Vector3, -- middle of the site on the ground
	model: Model, -- this event's container under Workspace.CrazyEvents
	alive: () -> boolean,
	players: () -> { Player },
}
type RunState = { rolled: boolean, nextAt: number?, fired: number, live: { [string]: () -> () } }

local services: { [string]: any } = {}
local state: { [string]: RunState } = {}
local rng = Random.new()
local V = Vector3.new
local CF = CFrame.new

local function count(name: string, n: number?)
	Telemetry.count(name, n or 1)
end

local function call(svc: string, method: string, ...: any): any
	local s = services[svc]
	if s and type(s[method]) == "function" then
		local ok, res = pcall(s[method], s, ...)
		if ok then
			return res
		end
		warn(`[EventService] {svc}:{method} failed: {res}`)
	end
	return nil
end

local function folder(): Folder
	local f = workspace:FindFirstChild("CrazyEvents")
	if not (f and f:IsA("Folder")) then
		f = Instance.new("Folder")
		f.Name = "CrazyEvents"
		f.Parent = workspace
	end
	return f :: Folder
end

local function part(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, o: { [string]: any }?): Part
	local opts = o or {}
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = opts.shadow == true
	p.Material = opts.material or Enum.Material.SmoothPlastic
	p.Transparency = opts.transparency or 0
	if opts.shape then
		p.Shape = opts.shape
	end
	p.Parent = parent
	return p
end

local function sign(p: BasePart, face: Enum.NormalId, text: string, color: Color3)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.LightInfluence = 0.3
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.TextColor3 = color
	t.Text = text
	t.Parent = gui
	gui.Parent = p
end

local function groundY(pos: Vector3, up: number?): number
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = { folder() }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	rp.FilterDescendantsInstances = ignore
	local u = up or 40
	local hit = workspace:Raycast(pos + V(0, u, 0), V(0, -(u + 80), 0), rp)
	return if hit then hit.Position.Y else pos.Y
end

local function rootPart(p: Player): BasePart?
	local c = p.Character
	return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function burningIn(root: Instance, cap: number?): { BasePart }
	local out: { BasePart } = {}
	for _, inst in CollectionService:GetTagged(Names.Tag.Burning) do
		if inst:IsA("BasePart") and inst:IsDescendantOf(root) then
			table.insert(out, inst)
			if cap and #out >= cap then
				break
			end
		end
	end
	return out
end

local function tell(ctx: Ctx, text: string, kind: string)
	for _, p in ctx.players() do
		Net.notify(p, text, kind)
	end
end

local function rawState(m: any): string
	return tostring(m.roundState or m.state or "")
end

---------------------------------------------------------------------------------------------- events

-- Every event: fn(ctx) -> stop | nil (nil = could not run here; another event is tried).
local EVENTS: { [string]: (Ctx) -> (() -> ())? } = {}

-- Channel 67 News chopper ------------------------------------------------------------------------
local NEWS_LINES = {
	"...and here we see a firefighter going the WRONG way.",
	"Live from the scene: it's on fire. Back to you, Tom.",
	"Viewers at home: is that a panda?",
	"Our chopper is in no danger. Probably.",
	"Breaking: local hero hoses own teammate.",
	"Stay tuned for the weather. Spoiler: smoky.",
}

EVENTS.news_heli = function(ctx: Ctx): (() -> ())?
	local m = ctx.model
	local white = Color3.fromHex("#F2EDE4")
	local blue = Color3.fromHex("#3D5A80")
	local body = part(m, "Body", CF(), V(5, 4.2, 9), white, { shadow = true })
	local stripe = part(m, "Stripe", CF(), V(5.1, 1.2, 9.1), blue)
	local boom = part(m, "TailBoom", CF(), V(1, 1, 8), white)
	local fin = part(m, "TailFin", CF(), V(0.3, 3, 1.6), blue)
	local rotor = part(m, "Rotor", CF(), V(22, 0.2, 1.1), Color3.fromHex("#2B2B2E"))
	local skidL = part(m, "SkidL", CF(), V(0.4, 0.4, 8), Color3.fromHex("#2B2B2E"))
	local skidR = part(m, "SkidR", CF(), V(0.4, 0.4, 8), Color3.fromHex("#2B2B2E"))
	sign(stripe, Enum.NormalId.Right, "67 NEWS", white)
	sign(stripe, Enum.NormalId.Left, "67 NEWS", white)
	local lamp = part(m, "Lamp", CF(), V(1, 1, 1), Color3.fromRGB(255, 250, 200), { material = Enum.Material.Neon })
	local spot = Instance.new("SpotLight")
	spot.Face = Enum.NormalId.Front
	spot.Range = 120
	spot.Angle = 22
	spot.Brightness = 7
	spot.Color = Color3.fromRGB(255, 250, 220)
	spot.Shadows = true
	spot.Parent = lamp
	local target = part(m, "SpotTarget", CF(ctx.centre), V(0.2, 0.2, 0.2), white, { transparency = 1 })
	local a0 = Instance.new("Attachment")
	a0.Parent = lamp
	local a1 = Instance.new("Attachment")
	a1.Parent = target
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Width0 = 1.5
	beam.Width1 = 12
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.Color = ColorSequence.new(Color3.fromRGB(255, 248, 210))
	beam.Transparency = NumberSequence.new(0.6, 0.9)
	beam.Segments = 1
	beam.Parent = lamp
	m.PrimaryPart = body

	local following: Player? = nil
	local function pickTarget()
		local list = ctx.players()
		if #list == 0 then
			following = nil
			return
		end
		following = list[rng:NextInteger(1, #list)]
		Popup.show(following :: Player, "ON AIR! Wave to the camera!", "info")
	end
	pickTarget()
	tell(ctx, "BREAKING: the Channel 67 News chopper is live over your call. Smile!", "info")
	local t0 = os.clock()
	local lastSwitch, lastLine = t0, t0
	local aim = ctx.centre
	local leaving = false
	local conn = RunService.Heartbeat:Connect(function(dt: number)
		local t = os.clock() - t0
		local a = t * 0.35
		local R = EventConfig.HeliRadius
		local lift = if leaving then (os.clock() - lastSwitch) * 25 else 0
		local pos = ctx.centre + V(math.cos(a) * R, EventConfig.HeliHeight + lift, math.sin(a) * R)
		local tangent = V(-math.sin(a), 0, math.cos(a))
		local frame = CFrame.lookAt(pos, pos + tangent) * CFrame.Angles(math.rad(-6), 0, math.rad(8))
		body.CFrame = frame
		stripe.CFrame = frame * CF(0, -0.4, 0)
		boom.CFrame = frame * CF(0, 0.6, 8)
		fin.CFrame = frame * CF(0, 1.8, 11.4)
		rotor.CFrame = frame * CF(0, 2.6, 0) * CFrame.Angles(0, t * 25, 0)
		skidL.CFrame = frame * CF(-2, -2.6, 0)
		skidR.CFrame = frame * CF(2, -2.6, 0)
		local hrp = following and rootPart(following)
		local want = if hrp then hrp.Position else ctx.centre
		aim = aim:Lerp(want, math.min(1, dt * 4))
		target.CFrame = CF(aim)
		local lampPos = (frame * CF(0, -2.4, -3)).Position
		lamp.CFrame = CFrame.lookAt(lampPos, aim)
	end)
	task.spawn(function()
		while ctx.alive() and not leaving and os.clock() - t0 < EventConfig.HeliSeconds do
			task.wait(1)
			local now = os.clock()
			if now - lastSwitch >= EventConfig.HeliSwitchSeconds then
				lastSwitch = now
				pickTarget()
			end
			if now - lastLine >= 10 then
				lastLine = now
				Popup.show(body, NEWS_LINES[rng:NextInteger(1, #NEWS_LINES)], "info")
			end
		end
		if not leaving then
			leaving = true
			lastSwitch = os.clock()
			task.wait(3)
		end
		conn:Disconnect()
		m:Destroy()
	end)
	return function()
		leaving = true
		conn:Disconnect()
		m:Destroy()
	end
end

-- geyser hydrant ---------------------------------------------------------------------------------
local function siteHydrant(ctx: Ctx): Vector3?
	local best: Vector3? = nil
	local bd = math.huge
	for _, inst in CollectionService:GetTagged(Names.Tag.Hydrant) do
		local p: BasePart? = if inst:IsA("BasePart") then inst elseif inst:IsA("Model") then (inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)) else nil
		if p and p:IsDescendantOf(workspace) then
			local d = (p.Position - ctx.anchor.Position).Magnitude - (if inst:IsDescendantOf(ctx.root) then 1000 else 0)
			if d < bd and d < 140 then
				best, bd = p.Position, d
			end
		end
	end
	return best
end

EVENTS.geyser_hydrant = function(ctx: Ctx): (() -> ())?
	local at = siteHydrant(ctx) or (ctx.anchor * CF(14, 0, 0)).Position
	local base = V(at.X, groundY(at, 6), at.Z)
	local m = ctx.model
	local H = EventConfig.GeyserHeight
	local col = part(m, "Geyser", CF(base) * CFrame.Angles(0, 0, math.pi / 2), V(0.2, 3.2, 3.2), Color3.fromHex("#4FA3C7"), {
		shape = Enum.PartType.Cylinder,
		transparency = 0.3,
	})
	local top = part(m, "GeyserTop", CF(base), V(1, 1, 1), Color3.fromHex("#4FA3C7"), { transparency = 1 })
	local spray = Instance.new("ParticleEmitter")
	spray.Color = ColorSequence.new(Color3.fromRGB(220, 240, 255), Color3.fromRGB(120, 190, 230))
	spray.Size = NumberSequence.new(1, 3)
	spray.Transparency = NumberSequence.new(0.2, 1)
	spray.Speed = NumberRange.new(14, 26)
	spray.SpreadAngle = Vector2.new(70, 70)
	spray.Lifetime = NumberRange.new(0.8, 1.4)
	spray.Acceleration = V(0, -50, 0)
	spray.Rate = 70
	spray.EmissionDirection = Enum.NormalId.Top
	spray.Parent = top
	TweenService:Create(col, TweenInfo.new(1.2, Enum.EasingStyle.Back), {
		Size = V(H, 3.2, 3.2),
		CFrame = CF(base + V(0, H / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
	}):Play()
	TweenService:Create(top, TweenInfo.new(1.2, Enum.EasingStyle.Back), { CFrame = CF(base + V(0, H, 0)) }):Play()
	tell(ctx, "The hydrant blew its top! Free water for the fires (and free rides).", "good")
	Popup.show(base + V(0, 6, 0), "GEYSER!", "good")
	local running = true
	local rode: { [Player]: number } = {}
	task.spawn(function()
		local t0 = os.clock()
		local lastWater = 0
		while running and ctx.alive() and os.clock() - t0 < EventConfig.GeyserSeconds do
			task.wait(0.25)
			local now = os.clock()
			for _, p in ctx.players() do
				local hrp = rootPart(p)
				if hrp and p.Character then
					local flat = V(hrp.Position.X - base.X, 0, hrp.Position.Z - base.Z).Magnitude
					if flat < 3.6 and hrp.Position.Y > base.Y - 3 and hrp.Position.Y < base.Y + H and now - (rode[p] or 0) > 2.5 then
						rode[p] = now
						Ragdoll.knockback(p.Character, V(rng:NextNumber(-8, 8), EventConfig.GeyserLaunch, rng:NextNumber(-8, 8)))
						count("geyser_rides")
						Popup.show(p, "WHEEEE! Geyser ride!", "good")
					end
				end
			end
			if now - lastWater >= 1 then
				lastWater = now
				for _, b in burningIn(ctx.root, 40) do
					if (b.Position - base).Magnitude <= EventConfig.GeyserWaterRadius then
						call("FireService", "ApplyWater", nil, b.Position + V(0, 3, 0), V(0, -1, 0), EventConfig.GeyserLitres)
					end
				end
				Twists.douse(ctx.runId, base, EventConfig.GeyserWaterRadius, 0.5)
			end
		end
		running = false
		if m.Parent then
			spray.Enabled = false
			TweenService:Create(col, TweenInfo.new(0.8), { Size = V(0.2, 3.2, 3.2), CFrame = CF(base) * CFrame.Angles(0, 0, math.pi / 2) }):Play()
			task.wait(1)
			m:Destroy()
		end
	end)
	return function()
		running = false
		m:Destroy()
	end
end

-- raccoon -----------------------------------------------------------------------------------------
local function holdsHose(p: Player): boolean
	local c = p.Character
	return (c ~= nil and c:FindFirstChild("Hose") ~= nil) or p:GetAttribute("InvHand") == "Hose"
end

EVENTS.raccoon = function(ctx: Ctx): (() -> ())?
	local victim: Player? = nil
	for _, p in ctx.players() do
		if holdsHose(p) and rootPart(p) then
			victim = p
			break
		end
	end
	if not victim then
		return nil -- nobody has a nozzle to steal
	end
	local who = victim :: Player
	local m = ctx.model
	local grey = Color3.fromHex("#8C8C8C")
	local dark = Color3.fromHex("#2B2B2E")
	local body = part(m, "Body", CF(), V(1.5, 1.2, 2.6), grey)
	local head = part(m, "Head", CF(), V(1.2, 1, 1), grey)
	local mask = part(m, "Mask", CF(), V(1.25, 0.35, 0.2), dark)
	local tail1 = part(m, "Tail", CF(), V(0.55, 0.55, 1), dark)
	local tail2 = part(m, "Tail", CF(), V(0.55, 0.55, 1), Color3.fromHex("#BDBDBD"))
	local earL = part(m, "Ear", CF(), V(0.3, 0.4, 0.2), dark)
	local earR = part(m, "Ear", CF(), V(0.3, 0.4, 0.2), dark)
	local nozzle = part(m, "Nozzle", CF(), V(0.4, 0.4, 1.2), Color3.fromHex("#C9A227"), { material = Enum.Material.Metal, transparency = 1 })
	local hrp0 = rootPart(who) :: BasePart
	local dir = V(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
	dir = if dir.Magnitude > 0.1 then dir.Unit else V(1, 0, 0)
	local pos = hrp0.Position + dir * 24
	local function place(p: Vector3, look: Vector3, t: number)
		local y = groundY(p, 4)
		local hop = math.abs(math.sin(t * 14)) * 0.4
		local f = CFrame.lookAt(V(p.X, y + 0.7 + hop, p.Z), V(p.X, y + 0.7 + hop, p.Z) + look)
		body.CFrame = f
		head.CFrame = f * CF(0, 0.3, -1.6)
		mask.CFrame = f * CF(0, 0.4, -2.12)
		earL.CFrame = f * CF(-0.4, 0.95, -1.6)
		earR.CFrame = f * CF(0.4, 0.95, -1.6)
		tail1.CFrame = f * CF(0, 0.5, 1.6) * CFrame.Angles(math.rad(25 + math.sin(t * 9) * 15), 0, 0)
		tail2.CFrame = f * CF(0, 0.85, 2.4) * CFrame.Angles(math.rad(35), 0, 0)
		nozzle.CFrame = f * CF(0, 0.1, -2.5)
	end
	tell(ctx, "RACCOON ON SCENE! Guard your nozzles!", "bad")
	Popup.show(pos, "*rustle rustle*", "info")
	local running = true
	task.spawn(function()
		local t0 = os.clock()
		local stole = false
		local away = V(0, 0, 0)
		local runTo: Vector3? = nil
		while running and ctx.alive() and os.clock() - t0 < 16 do
			local dt = task.wait()
			local t = os.clock() - t0
			local goal: Vector3
			if not stole then
				local hrp = rootPart(who)
				if not hrp or t > 8 then
					break
				end
				goal = hrp.Position
				local flat = V(goal.X - pos.X, 0, goal.Z - pos.Z)
				if flat.Magnitude < 3 then
					stole = true
					count("raccoon_thefts")
					nozzle.Transparency = 0
					local truck = call("VehicleService", "GetTruck", who)
					call("InventoryService", "StowHose", who)
					Popup.show(who, "A RACCOON STOLE YOUR NOZZLE!", "bad")
					Net.notify(who, "Trash panda! Your nozzle is back on the truck reel. Go grab it.", "bad")
					runTo = if typeof(truck) == "Instance" and truck:IsA("Model") then truck:GetPivot().Position else nil
					away = -flat.Unit
				end
			else
				goal = runTo or (pos + away * 10)
				if runTo and V(goal.X - pos.X, 0, goal.Z - pos.Z).Magnitude < 4 then
					break
				end
			end
			local flat = V(goal.X - pos.X, 0, goal.Z - pos.Z)
			if flat.Magnitude > 0.1 then
				local step = math.min(flat.Magnitude, EventConfig.RaccoonSpeed * (if stole then 1.3 else 1) * dt)
				pos += flat.Unit * step
				place(pos, flat.Unit, t)
			end
		end
		if m.Parent then
			Popup.show(pos, "*victorious chittering*", "info")
			m:Destroy()
		end
	end)
	place(pos, -dir, 0)
	return function()
		running = false
		m:Destroy()
	end
end

-- rainstorm ---------------------------------------------------------------------------------------
EVENTS.rainstorm = function(ctx: Ctx): (() -> ())?
	local m = ctx.model
	local c = ctx.centre
	local cloud = part(m, "RainCloud", CF(c + V(0, 78, 0)), V(160, 8, 160), Color3.fromHex("#4E4A5A"), { transparency = 1, shadow = true })
	TweenService:Create(cloud, TweenInfo.new(2), { Transparency = 0.35 }):Play()
	local box = part(m, "RainBox", CF(c + V(0, 62, 0)), V(140, 1, 140), Color3.new(1, 1, 1), { transparency = 1 })
	local rain = Instance.new("ParticleEmitter")
	rain.Color = ColorSequence.new(Color3.fromRGB(190, 215, 240))
	rain.Size = NumberSequence.new(0.18)
	rain.Squash = NumberSequence.new(-2.5)
	rain.Orientation = Enum.ParticleOrientation.VelocityParallel
	rain.Transparency = NumberSequence.new(0.35)
	rain.LightEmission = 0.2
	rain.Speed = NumberRange.new(85, 100)
	rain.Lifetime = NumberRange.new(0.7, 0.8)
	rain.Rate = 450
	rain.EmissionDirection = Enum.NormalId.Bottom
	rain.Parent = box
	tell(ctx, "Sudden downpour! The sky is on your side for once.", "good")
	local running = true
	task.spawn(function()
		local t0 = os.clock()
		while running and ctx.alive() and os.clock() - t0 < EventConfig.RainSeconds do
			task.wait(EventConfig.RainEvery)
			for _, b in burningIn(ctx.root, 60) do
				call("FireService", "ApplyWater", nil, b.Position + V(0, 3, 0), V(0, -1, 0), EventConfig.RainLitres)
			end
			Twists.douse(ctx.runId, c, 250, EventConfig.RainScripted)
			for _, p in ctx.players() do
				call("HeatService", "Cool", p, EventConfig.RainCool, nil)
			end
		end
		running = false
		if m.Parent then
			rain.Enabled = false
			TweenService:Create(cloud, TweenInfo.new(2), { Transparency = 1 }):Play()
			task.wait(2)
			m:Destroy()
		end
	end)
	return function()
		running = false
		m:Destroy()
	end
end

-- wind gusts --------------------------------------------------------------------------------------
local WINDS = {
	{ from = "west", to = "east", v = V(1, 0, 0) },
	{ from = "east", to = "west", v = V(-1, 0, 0) },
	{ from = "north", to = "south", v = V(0, 0, 1) },
	{ from = "south", to = "north", v = V(0, 0, -1) },
}

EVENTS.wind_gust = function(ctx: Ctx): (() -> ())?
	local w = WINDS[rng:NextInteger(1, #WINDS)]
	local m = ctx.model
	local box = part(m, "WindBox", CF(ctx.centre + V(0, 12, 0)) * CF(-w.v * 50), V(30, 22, 30), Color3.new(1, 1, 1), { transparency = 1 })
	local gust = Instance.new("ParticleEmitter")
	gust.Color = ColorSequence.new(Color3.fromRGB(230, 225, 210))
	gust.Size = NumberSequence.new(0.25)
	gust.Squash = NumberSequence.new(-3)
	gust.Orientation = Enum.ParticleOrientation.VelocityParallel
	gust.Transparency = NumberSequence.new(0.4, 1)
	gust.Speed = NumberRange.new(60, 80)
	gust.Lifetime = NumberRange.new(1.2, 1.6)
	gust.Rate = 90
	gust.EmissionDirection = Enum.NormalId.Front
	gust.SpreadAngle = Vector2.new(8, 8)
	gust.Parent = box
	box.CFrame = CFrame.lookAt(box.Position, box.Position + w.v)
	tell(ctx, `WIND GUST from the {w.from}! The fire is jumping {w.to}!`, "bad")
	local running = true
	task.spawn(function()
		local t0 = os.clock()
		local tick = 0
		local op = OverlapParams.new()
		op.FilterType = Enum.RaycastFilterType.Include
		op.FilterDescendantsInstances = { ctx.root }
		while running and ctx.alive() and os.clock() - t0 < EventConfig.WindSeconds do
			task.wait(EventConfig.WindEvery)
			tick += 1
			local lit = 0
			for _, b in burningIn(ctx.root, 30) do
				if lit >= EventConfig.WindSpreadPerTick then
					break
				end
				for _, q in workspace:GetPartBoundsInRadius(b.Position + w.v * 7, 5, op) do
					if q:HasTag(Names.Tag.Flammable) and not q:HasTag(Names.Tag.Burning) then
						if call("FireService", "Ignite", q, nil) then
							lit += 1
						end
						break
					end
				end
			end
			if tick % 2 == 1 then
				for _, p in ctx.players() do
					if p.Character then
						Ragdoll.knockback(p.Character, w.v * EventConfig.WindPush + V(0, 6, 0))
					end
				end
				if tick == 1 then
					for _, p in ctx.players() do
						Popup.show(p, "WHOOSH!", "info")
					end
				end
			end
		end
		running = false
		m:Destroy()
	end)
	return function()
		running = false
		m:Destroy()
	end
end

-- ice-cream truck ---------------------------------------------------------------------------------
EVENTS.ice_cream = function(ctx: Ctx): (() -> ())?
	local m = ctx.model
	local street = ctx.anchor * CF(0, 0, -6)
	local right = V(ctx.anchor.RightVector.X, 0, ctx.anchor.RightVector.Z).Unit
	local y = groundY(street.Position, 10)
	local park = V(street.Position.X, y, street.Position.Z) - V(ctx.anchor.LookVector.X, 0, ctx.anchor.LookVector.Z).Unit * 4
	local from = park - right * 110
	local to = park + right * 110
	local pink = Color3.fromHex("#F7C6D9")
	local body = part(m, "Body", CF(), V(6, 6, 11), Color3.fromHex("#FDF6EC"), { shadow = true })
	local cab = part(m, "Cab", CF(), V(6, 4.4, 3.6), pink)
	local glass = part(m, "Windshield", CF(), V(5.4, 2, 0.2), Color3.fromHex("#3E5866"), { material = Enum.Material.Glass })
	local stripe = part(m, "Stripe", CF(), V(6.1, 1.4, 11.1), pink)
	local cone = part(m, "Cone", CF(), V(4, 2.2, 2.2), Color3.fromHex("#D9A55A"), { shape = Enum.PartType.Cylinder })
	local scoop = part(m, "Scoop", CF(), V(3.6, 3.6, 3.6), Color3.fromHex("#F49AC1"), { shape = Enum.PartType.Ball })
	local cherry = part(m, "Cherry", CF(), V(1, 1, 1), Color3.fromHex("#C8232B"), { shape = Enum.PartType.Ball })
	local wheels: { BasePart } = {}
	for i = 1, 4 do
		wheels[i] = part(m, "Wheel", CF(), V(0.9, 2.4, 2.4), Color3.fromHex("#2B2B2E"), { shape = Enum.PartType.Cylinder })
	end
	sign(stripe, Enum.NormalId.Right, "MR. FROSTY 67 · FREE SUNDAES", Color3.fromHex("#C8232B"))
	sign(stripe, Enum.NormalId.Left, "MR. FROSTY 67 · FREE SUNDAES", Color3.fromHex("#C8232B"))
	local WHEEL_AT = { { -3, -3.4 }, { 3, -3.4 }, { -3, 3.6 }, { 3, 3.6 } }
	local function place(p: Vector3)
		-- local -Z = driving direction (right)
		local f = CFrame.lookAt(p, p + right)
		body.CFrame = f * CF(0, 4.2, 1.2)
		stripe.CFrame = f * CF(0, 3.2, 1.2)
		cab.CFrame = f * CF(0, 3.4, -6)
		glass.CFrame = f * CF(0, 4.6, -7.85) * CFrame.Angles(math.rad(-12), 0, 0)
		cone.CFrame = f * CF(0, 8.2, 2) * CFrame.Angles(0, 0, math.pi / 2)
		scoop.CFrame = f * CF(0, 10.6, 2)
		cherry.CFrame = f * CF(0, 12.6, 2)
		for i, w in WHEEL_AT do
			wheels[i].CFrame = f * CF(w[1], 1.2, w[2])
		end
	end
	place(from)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Grab a free sundae"
	prompt.ObjectText = "Mr. Frosty"
	prompt.HoldDuration = 0 -- PromptConfig: taking is instant
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false
	prompt.Parent = body
	local served: { [Player]: boolean } = {}
	prompt.Triggered:Connect(function(p: Player)
		if served[p] then
			Popup.show(p, "One sundae per firefighter!", "info")
			return
		end
		served[p] = true
		count("sundaes")
		call("HeatService", "Cool", p, EventConfig.IceCreamCool, nil)
		Popup.show(p, `BRAIN FREEZE! Heat -{EventConfig.IceCreamCool}`, "good")
	end)
	tell(ctx, "Ding-a-ling! An ice-cream truck is pulling up. Free sundaes cool you down!", "good")
	local running = true
	task.spawn(function()
		local function drive(a: Vector3, b: Vector3, secs: number)
			local t0 = os.clock()
			while running and m.Parent do
				local k = math.min(1, (os.clock() - t0) / secs)
				place(a:Lerp(b, k))
				if k >= 1 then
					break
				end
				task.wait()
			end
		end
		drive(from, park, 5)
		prompt.Enabled = true
		local t0 = os.clock()
		while running and ctx.alive() and os.clock() - t0 < EventConfig.IceCreamPark do
			task.wait(1)
			Popup.show(cherry, "Ding-a-ling-a-ling!", "info")
			for _, p in ctx.players() do
				local hrp = rootPart(p)
				if hrp and (hrp.Position - park).Magnitude <= EventConfig.IceCreamAura then
					call("HeatService", "Cool", p, EventConfig.IceCreamAuraCool, nil)
				end
			end
		end
		prompt.Enabled = false
		drive(park, to, 5)
		running = false
		m:Destroy()
	end)
	return function()
		running = false
		m:Destroy()
	end
end

EventService.Ids = { "news_heli", "geyser_hydrant", "raccoon", "rainstorm", "wind_gust", "ice_cream" }

---------------------------------------------------------------------------------------------- runner

local function playersOf(runId: string): { Player }
	local out: { Player } = {}
	local Mission = services.MissionService
	local m = if Mission and type(Mission.GetMission) == "function" then Mission:GetMission(runId) else nil
	if m and type(m.players) == "table" then
		for _, uid in m.players do
			local p = Players:GetPlayerByUserId(uid)
			if p and p:GetAttribute(Names.Attr.InstanceId) == runId then
				table.insert(out, p)
			end
		end
	end
	return out
end

local function siteFrame(root: Model): (CFrame, Vector3)
	local zone = root:FindFirstChild("ArrivalZone", true) or root:FindFirstChild("TruckSpot", true)
	local anchor = if zone and zone:IsA("BasePart") then zone.CFrame else root:GetPivot()
	anchor = CFrame.new(anchor.Position.X, groundY(anchor.Position, 6), anchor.Position.Z) * (anchor - anchor.Position)
	-- the middle of the site: halfway between the apron and the building behind it
	local back = -V(anchor.LookVector.X, 0, anchor.LookVector.Z)
	back = if back.Magnitude > 0.1 then back.Unit else V(0, 0, 1)
	return anchor, anchor.Position + back * 25
end

local function stateOf(runId: string): RunState
	local s = state[runId]
	if not s then
		s = { rolled = false, nextAt = nil, fired = 0, live = {} }
		state[runId] = s
	end
	return s
end

local function stopRun(runId: string)
	local s = state[runId]
	state[runId] = nil
	if s then
		for _, stop in s.live do
			pcall(stop)
		end
	end
end

local function start(runId: string, eventId: string): (boolean, string)
	local fn = EVENTS[eventId]
	if not fn then
		return false, `unknown event {eventId}`
	end
	local root = call("MapService", "GetInstance", runId)
	if not (typeof(root) == "Instance" and root:IsA("Model") and root.Parent) then
		return false, `no site for {runId}`
	end
	local s = stateOf(runId)
	if s.live[eventId] then
		return false, `{eventId} already running in {runId}`
	end
	local anchor, centre = siteFrame(root)
	local model = Instance.new("Model")
	model.Name = `{eventId}_{runId}`
	model.Parent = folder()
	local ctx: Ctx = {
		runId = runId,
		root = root,
		anchor = anchor,
		centre = centre,
		model = model,
		alive = function(): boolean
			return state[runId] == s and root.Parent ~= nil
		end,
		players = function(): { Player }
			return playersOf(runId)
		end,
	}
	local ok, stop = pcall(fn, ctx)
	if not ok then
		model:Destroy()
		warn(`[EventService] {eventId} in {runId} failed: {stop}`)
		return false, tostring(stop)
	end
	if not stop then
		model:Destroy()
		return false, `{eventId} can't run here right now`
	end
	s.live[eventId] = stop
	model.Destroying:Once(function()
		if s.live[eventId] == stop then
			s.live[eventId] = nil
		end
	end)
	count("crazy_events")
	count(`crazy_{eventId}`)
	EventService.EventStarted:Fire(runId, eventId)
	print(`[EventService] {runId}: {eventId}`)
	return true, eventId
end

-- weighted pick among enabled events, skipping `tried`
local function roll(tried: { [string]: boolean }): string?
	local total = 0
	for _, id in EventService.Ids do
		if not tried[id] then
			total += math.max(0, tonumber(EventConfig.Weights[id]) or 0)
		end
	end
	if total <= 0 then
		return nil
	end
	local r = rng:NextNumber() * total
	for _, id in EventService.Ids do
		if not tried[id] then
			r -= math.max(0, tonumber(EventConfig.Weights[id]) or 0)
			if r <= 0 then
				return id
			end
		end
	end
	return nil
end

local function tickRuns()
	local Mission = services.MissionService
	if not (Mission and type(Mission.GetMissions) == "function") then
		return
	end
	local seen: { [string]: boolean } = {}
	local now = os.clock()
	for _, m in Mission:GetMissions() do
		local id = m.instanceId
		seen[id] = true
		if rawState(m) ~= "Active" then
			continue
		end
		local s = stateOf(id)
		if not s.rolled then
			s.rolled = true
			if EventConfig.Enabled and rng:NextNumber() < EventConfig.Chance then
				s.nextAt = now + rng:NextNumber(EventConfig.FirstAfter.min, EventConfig.FirstAfter.max)
			end
		end
		if s.nextAt and now >= s.nextAt and EventConfig.Enabled then
			s.nextAt = nil
			local tried: { [string]: boolean } = {}
			for _ = 1, #EventService.Ids do
				local pick = roll(tried)
				if not pick then
					break
				end
				tried[pick] = true
				if start(id, pick) then
					s.fired += 1
					break
				end
			end
			if s.fired < EventConfig.MaxPerMission then
				s.nextAt = now + 60
			end
		end
	end
	for id in state do
		if not seen[id] then
			stopRun(id)
		end
	end
end

---------------------------------------------------------------------------------------------- lifecycle

function EventService:Init(all: { [string]: any })
	services = all
end

function EventService:Start()
	local Mission = services.MissionService
	if Mission and Mission.MissionEnded then
		Mission.MissionEnded:Connect(function(runId: string, _payload: any)
			stopRun(runId)
		end)
	end
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(tickRuns)
			if not ok then
				warn(`[EventService] tick: {err}`)
			end
		end
	end)
end

function EventService:Force(runId: string?, eventId: string): (boolean, string)
	local id = runId
	if not id then
		local Mission = services.MissionService
		local list = if Mission and type(Mission.GetMissions) == "function" then Mission:GetMissions() else {}
		for i = #list, 1, -1 do
			if rawState(list[i]) == "Active" or rawState(list[i]) == "Dispatched" then
				id = list[i].instanceId
				break
			end
		end
	end
	if not id then
		return false, "no running call"
	end
	return start(id, eventId)
end

function EventService:GetActive(runId: string): { string }
	local out = {}
	for id in (state[runId] or { live = {} }).live do
		table.insert(out, id)
	end
	return out
end

function EventService:_force(runId: string?, eventId: string): (boolean, string)
	return self:Force(runId, eventId)
end

function EventService:_selftest(): (boolean, string)
	for _, id in EventService.Ids do
		if not EVENTS[id] then
			return false, `no handler for {id}`
		end
		if EventConfig.Weights[id] == nil then
			return false, `EventConfig.Weights has no {id}`
		end
	end
	local ok = start("__nowhere__", "rainstorm")
	if ok then
		return false, "started an event on a missing run"
	end
	return true, `{#EventService.Ids} crazy events wired`
end

return EventService
