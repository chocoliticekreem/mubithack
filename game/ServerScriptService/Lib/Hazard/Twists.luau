--!strict
-- Twists [owner: GF]. The v3 "crazy call" mechanics HazardService arms per mission (MissionCatalog
-- `hazards`). Each twist builds its props INSIDE the bound IncidentSite (MapService:RebuildSite swaps in
-- the pristine copy afterwards, so nothing leaks) and registers its cleanup through the ctx.
--
--   grease_fire  diner: a burning deep fryer. Extinguisher spray or the "Slam the lid" prompt puts it out;
--                HOSE water on it = a grease fireball (explosion, relights the kitchen, fryer back to full).
--   gas_leak     gas station: every Pump (attr Pump) sprays fuel; a tanker parks behind them with a
--                countdown (LeakSeconds from arrival). Hold "Shut valve" on each pump. Time out = the
--                tanker blows and the fuel puddles catch fire.
--   pileup       rest stop: a crumpled car is built round every Civilian rescue of the run; the driver is
--                pinned (ProximityPrompt off, attr Pinned) until someone holding a pry tool (ItemDefs
--                `pry`: Halligan, Crowbar) or an axe holds "Pry door".
--   cat_tree     house: a tree by the apron with a Cat (RescueService:SpawnAt) on its branch; ladder up.
--                The cat makes puns, and hisses at anyone who hoses it.
--
-- Scripted fires: a twist fire is a part with the Burning tag + FireLevel attr but NO FireService cell,
-- so the client FX, HeatService, RescueService panic and MissionService's burning count all see it, while
-- only the spray rules here put it out. Spray input: a second listener on Tool/Spray (C->S aim, owned by
-- ToolService) with the same "which tool is in the hand" rule as ToolService.equipped.
--
--   Twists.start()                                   -- once (HazardService:Start): the spray listener
--   Twists.arm(kind, ctx): boolean                    -- ctx below; false = unknown kind / nothing to do
--   Twists.clear(instanceId)                          -- drop every target of the run (HazardService:Clear)
--   Twists.douse(instanceId, pos, radius, amount): number  -- rain/geyser (EventService): cools "cool"
--                                                       scripted fires within radius; returns how many
--   Twists.targets(instanceId): { any }               -- test/debug view
-- ctx = { instanceId, root: Model, services, conn(c), thread(t), prompt(p), alive(): boolean,
--         explode(pos, radius?, culprit?), players(): { Player } }
-- Counters: twist_fires_out, grease_flares, grease_lid, grease_out, gas_valves_shut, gas_leak_stopped,
--   gas_tanker_blown, pileup_wrecks, pileup_doors_pried, pileup_wrong_tool, cat_tree_spawned, cat_hosed,
--   cat_puns
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local HazardConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("HazardConfig") :: ModuleScript) :: any
local ItemDefs = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Items"):WaitForChild("ItemDefs") :: ModuleScript) :: any

local Twists = {}

type Target = {
	part: BasePart,
	fire: boolean, -- a scripted fire (Burning + FireLevel) vs a plain spray target (the cat)
	hp: number,
	max: number,
	water: string, -- what HOSE water does: "cool" | "flare" (onWater) | "hiss" (onWater, no damage)
	foam: boolean, -- the extinguisher cools it
	out: boolean,
	onWater: ((Player) -> ())?,
	onOut: ((Player?) -> ())?,
}

local targets: { [string]: { Target } } = {}
local lastSpray: { [Player]: number } = {}
local started = false

local V = Vector3.new
local CF = CFrame.new

local function count(name: string, n: number?)
	Telemetry.count(name, n or 1)
end

local function part(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, o: { [string]: any }?): Part
	local opts = o or {}
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Anchored = true
	p.CanTouch = false
	p.CanCollide = opts.collide ~= false
	p.CanQuery = opts.query ~= false
	p.CastShadow = opts.shadow ~= false
	p.Material = opts.material or Enum.Material.SmoothPlastic
	p.Transparency = opts.transparency or 0
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if opts.shape then
		p.Shape = opts.shape
	end
	p.Parent = parent
	return p
end

local function makePrompt(ctx: any, parent: BasePart, action: string, object: string, hold: number, dist: number?): ProximityPrompt
	local p = Instance.new("ProximityPrompt")
	p.Name = "TwistPrompt"
	p.ActionText = action
	p.ObjectText = object
	p.HoldDuration = hold
	p.MaxActivationDistance = dist or 9
	p.RequiresLineOfSight = false
	p.Parent = parent
	ctx.prompt(p)
	return p
end

-- Triggered handlers by prompt, so the DevHook test hook can press a prompt without a client.
local handlers: { [ProximityPrompt]: (Player) -> () } = {}
local function onTrigger(pr: ProximityPrompt, fn: (Player) -> ())
	handlers[pr] = fn
	pr.Triggered:Connect(fn)
	pr.Destroying:Once(function()
		handlers[pr] = nil
	end)
end

local function billboard(parent: BasePart, text: string, color: Color3, offset: number, size: Vector2?): TextLabel
	local gui = Instance.new("BillboardGui")
	gui.Name = "TwistLabel"
	local s = size or Vector2.new(220, 50)
	gui.Size = UDim2.fromOffset(s.X, s.Y)
	gui.StudsOffset = V(0, offset, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 350
	gui.LightInfluence = 0
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.TextColor3 = color
	t.TextStrokeTransparency = 0.2
	t.Text = text
	t.Parent = gui
	gui.Parent = parent
	return t
end

-- First surface below pos (cast from `up` studs above it: keep that under any roof/canopy overhead).
local function groundBelow(pos: Vector3, ignore: { Instance }, up: number?): Vector3
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = ignore
	local u = up or 30
	local hit = workspace:Raycast(pos + V(0, u, 0), V(0, -(u + 60), 0), rp)
	return if hit then hit.Position else pos
end

local function characters(): { Instance }
	local out: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(out, p.Character)
		end
	end
	local r = workspace:FindFirstChild("Rescuables")
	if r then
		table.insert(out, r)
	end
	return out
end

-- every player in the run (attr InstanceId), for banners
local function squad(ctx: any): { Player }
	local out = {}
	for _, p in Players:GetPlayers() do
		if p:GetAttribute(Names.Attr.InstanceId) == ctx.instanceId then
			table.insert(out, p)
		end
	end
	if #out == 0 then
		return ctx.players()
	end
	return out
end

local function tell(ctx: any, text: string, kind: string)
	for _, p in squad(ctx) do
		Net.notify(p, text, kind)
	end
end

-- Runs fn once the squad is on scene (the run folder's RoundState turns Active); right away (after 3 s)
-- for a v1.5 instance run, which has no Runs folder and teleports in.
local function onArrive(ctx: any, fn: () -> ())
	local runs = workspace:FindFirstChild("Runs")
	local folder = runs and runs:FindFirstChild(ctx.instanceId)
	if not folder then
		ctx.thread(task.delay(3, function()
			if ctx.alive() then
				fn()
			end
		end))
		return
	end
	local fired = false
	local function check()
		if not fired and folder:GetAttribute("RoundState") == "Active" and ctx.alive() then
			fired = true
			task.spawn(fn)
		end
	end
	ctx.conn(folder:GetAttributeChangedSignal("RoundState"):Connect(check))
	check()
end

---------------------------------------------------------------------------------------------- targets

local function setLevel(t: Target)
	if t.fire and not t.out then
		t.part:SetAttribute(Names.Attr.FireLevel, math.clamp(math.ceil(3 * t.hp / t.max), 1, 3))
	end
end

local function light(t: Target)
	t.out = false
	t.hp = t.max
	if t.fire then
		CollectionService:AddTag(t.part, Names.Tag.Burning)
		setLevel(t)
	end
end

local function putOut(t: Target, by: Player?)
	if t.out then
		return
	end
	t.out = true
	t.hp = 0
	if t.fire then
		CollectionService:RemoveTag(t.part, Names.Tag.Burning)
		t.part:SetAttribute(Names.Attr.FireLevel, nil)
		count("twist_fires_out")
	end
	if t.onOut then
		task.spawn(t.onOut, by)
	end
end

local function addTarget(instanceId: string, t: Target): Target
	local list = targets[instanceId]
	if not list then
		list = {}
		targets[instanceId] = list
	end
	table.insert(list, t)
	return t
end

local function newTarget(p: BasePart, fire: boolean, hp: number, water: string, foam: boolean): Target
	return { part = p, fire = fire, hp = hp, max = hp, water = water, foam = foam, out = not fire, onWater = nil, onOut = nil }
end

local function hit(t: Target, player: Player, kind: string)
	if kind == "hose" and (t.water == "flare" or t.water == "hiss") then
		if t.onWater then
			t.onWater(player)
		end
		return
	end
	if not t.fire or t.out then
		return
	end
	if kind == "foam" and not t.foam then
		return
	end
	t.hp -= if kind == "hose" then HazardConfig.TwistHoseHit else HazardConfig.TwistFoamHit
	if t.hp <= 0 then
		putOut(t, player)
	else
		setLevel(t)
	end
end

local function onSpray(player: Player, aimArg: any)
	local aim = Net.unit(aimArg)
	if not aim then
		return
	end
	local id = player:GetAttribute(Names.Attr.InstanceId)
	local list = if type(id) == "string" then targets[id] else nil
	if not list or #list == 0 then
		return
	end
	local now = os.clock()
	if now - (lastSpray[player] or 0) < 0.08 then
		return
	end
	lastSpray[player] = now
	local char = player.Character
	local head = char and char:FindFirstChild("Head") :: BasePart?
	if not (char and head) then
		return
	end
	-- the same rule as ToolService.equipped: whichever Tool is in the hand, and it must have something left
	local kind: string? = nil
	if char:FindFirstChild("Hose") then
		kind = if ((player:GetAttribute(Names.Attr.Water) :: number?) or 0) > 0 then "hose" else nil
	elseif char:FindFirstChild("Extinguisher") then
		kind = if ((player:GetAttribute("Foam") :: number?) or 0) > 0 then "foam" else nil
	end
	if not kind then
		return
	end
	for _, t in list do
		if not t.part.Parent then
			continue
		end
		local d = t.part.Position - head.Position
		local dist = d.Magnitude
		if dist <= HazardConfig.TwistSprayRange and (dist < 6 or d.Unit:Dot(aim) >= HazardConfig.TwistSprayCos) then
			hit(t, player, kind)
		end
	end
end

function Twists.start()
	if started then
		return
	end
	started = true
	Net.event("Tool", "Spray").OnServerEvent:Connect(function(player: Player, aim: any)
		local ok, err = pcall(onSpray, player, aim)
		if not ok then
			warn(`[Twists] spray: {err}`)
		end
	end)
	Players.PlayerRemoving:Connect(function(p: Player)
		lastSpray[p] = nil
	end)
end

function Twists.clear(instanceId: string)
	targets[instanceId] = nil
end

function Twists.targets(instanceId: string): { any }
	return targets[instanceId] or {}
end

-- Test hooks (via HazardService DevHook): press the first live twist prompt with this ActionText in the
-- run's site; spray every live target of the run as `player` with "hose" | "foam".
function Twists.testPrompt(root: Instance, action: string, player: Player): boolean
	for pr, fn in handlers do
		if pr.Parent and pr:IsDescendantOf(root) and pr.ActionText == action and pr.Enabled then
			fn(player)
			return true
		end
	end
	return false
end

function Twists.testSpray(instanceId: string, player: Player, kind: string): number
	local n = 0
	for _, t in targets[instanceId] or {} do
		if t.part.Parent then
			n += 1
			hit(t, player, kind)
		end
	end
	return n
end

function Twists.douse(instanceId: string, pos: Vector3, radius: number, amount: number): number
	local n = 0
	for _, t in targets[instanceId] or {} do
		if t.fire and not t.out and t.water == "cool" and (t.part.Position - pos).Magnitude <= radius then
			n += 1
			t.hp -= amount
			if t.hp <= 0 then
				putOut(t, nil)
			else
				setLevel(t)
			end
		end
	end
	return n
end

---------------------------------------------------------------------------------------------- grease_fire

local function greaseFire(ctx: any): boolean
	local root: Model = ctx.root
	local counter = root:FindFirstChild("Counter", true)
	local base: CFrame
	if counter and counter:IsA("BasePart") then
		base = counter.CFrame * CF(-6.5, 0, 0)
	else
		local marker: BasePart? = nil
		for _, m in CollectionService:GetTagged(Names.Tag.FireStart) do
			if m:IsA("BasePart") and m:IsDescendantOf(root) then
				marker = m
				break
			end
		end
		base = if marker then marker.CFrame else root:GetPivot() * CF(0, 0, 10)
	end
	local floor = groundBelow(base.Position, characters(), 1) -- under the diner roof
	local yaw = base - base.Position
	local at = CF(floor) * yaw
	local m = Instance.new("Model")
	m.Name = "DeepFryer"
	local body = part(m, "Fryer", at * CF(0, 1.7, 0), V(3.2, 3.4, 3), Color3.fromHex("#9AA0A6"), { material = Enum.Material.Metal })
	local vat = part(m, "GreaseVat", at * CF(0, 3.55, 0), V(2.6, 0.3, 2.4), Color3.fromHex("#D9A23A"), { collide = false })
	local lid = part(m, "FryerLid", at * CF(0, 4.6, 1.7) * CFrame.Angles(math.rad(75), 0, 0), V(3, 0.25, 2.8), Color3.fromHex("#6E747A"), {
		material = Enum.Material.Metal,
		collide = false,
	})
	m.Parent = root
	local label = billboard(body, "DEEP FRYER: NO WATER!", Color3.fromRGB(255, 200, 60), 5, Vector2.new(200, 40))

	local t = addTarget(ctx.instanceId, newTarget(vat, true, HazardConfig.GreaseHp, "flare", true))
	local lastFlare = 0
	local prompt: ProximityPrompt? = nil
	t.onWater = function(player: Player)
		local now = os.clock()
		if t.out or now - lastFlare < HazardConfig.GreaseFlareCooldown then
			return
		end
		lastFlare = now
		t.hp = t.max
		setLevel(t)
		count("grease_flares")
		Popup.show(vat, `{player.DisplayName} HOSED THE GREASE! KA-WHOOSH!`, "blame", player)
		ctx.explode(vat.Position + V(0, 2, 0), HazardConfig.GreaseFlareRadius, nil)
	end
	t.onOut = function(by: Player?)
		count("grease_out")
		label.Text = "FRYER: SMOTHERED"
		label.TextColor3 = Color3.fromRGB(120, 230, 120)
		if prompt then
			prompt:Destroy()
		end
		tell(ctx, "Grease fire out! Now hose the rest of the diner.", "good")
		if by then
			Popup.show(body, `{by.DisplayName} smothered the fryer!`, "good", by)
		end
	end
	prompt = makePrompt(ctx, body, "Slam the lid", "Deep Fryer", HazardConfig.GreaseLidHold, 8)
	onTrigger(prompt :: ProximityPrompt, function(player: Player)
		if t.out then
			return
		end
		count("grease_lid")
		TweenService:Create(lid, TweenInfo.new(0.25, Enum.EasingStyle.Back), { CFrame = at * CF(0, 3.85, 0) }):Play()
		Popup.show(body, "LID ON! Smothered. Science!", "good", player)
		putOut(t, player)
	end)
	light(t)
	onArrive(ctx, function()
		tell(ctx, "GREASE FIRE! Water makes it EXPLODE. Use the extinguisher or slam the lid.", "bad")
	end)
	return true
end

---------------------------------------------------------------------------------------------- gas_leak

local function buildTanker(parent: Instance, cf: CFrame): (Model, BasePart)
	local m = Instance.new("Model")
	m.Name = "FuelTanker"
	local red = Color3.fromHex("#C8232B")
	local steel = Color3.fromHex("#C9CCD0")
	part(m, "Chassis", cf * CF(0, 1.6, 0), V(17, 1, 4.6), Color3.fromHex("#3B3940"))
	part(m, "Cab", cf * CF(6.6, 3.9, 0), V(4, 4.2, 4.8), red)
	part(m, "Windshield", cf * CF(8.65, 4.6, 0), V(0.2, 1.8, 4.2), Color3.fromHex("#3E5866"), { material = Enum.Material.Glass, collide = false })
	local tank = part(m, "Tank", cf * CF(-2.2, 4.4, 0), V(12, 5, 5), steel, { shape = Enum.PartType.Cylinder, material = Enum.Material.Metal })
	local stripe = part(m, "TankStripe", cf * CF(-2.2, 4.4, -2.45), V(9, 1.6, 0.2), red, { collide = false })
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	local txt = Instance.new("TextLabel")
	txt.Size = UDim2.fromScale(1, 1)
	txt.BackgroundTransparency = 1
	txt.Font = Enum.Font.FredokaOne
	txt.TextScaled = true
	txt.TextColor3 = Color3.new(1, 1, 1)
	txt.Text = "FLAMMABLE (VERY)"
	txt.Parent = gui
	gui.Parent = stripe
	for _, w in { { 5.5, -2.4 }, { 5.5, 2.4 }, { -5, -2.4 }, { -5, 2.4 } } do
		part(m, "Wheel", cf * CF(w[1], 1.2, w[2]) * CFrame.Angles(0, math.pi / 2, 0), V(0.9, 2.4, 2.4), Color3.fromHex("#2B2B2E"), {
			shape = Enum.PartType.Cylinder,
			collide = false,
		})
	end
	m.Parent = parent
	return m, tank
end

local function gasLeak(ctx: any): boolean
	local root: Model = ctx.root
	local pumps: { BasePart } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("Pump") == true then
			table.insert(pumps, d)
		end
	end
	local F = root:GetPivot()
	if #pumps == 0 then
		-- not a gas site (fallback instance): two pumps on the apron
		for _, x in { -8, 8 } do
			local g = groundBelow((F * CF(x, 0, 9)).Position, characters())
			local p = part(root, "Pump", CF(g) * (F - F.Position) * CF(0, 2.5, 0), V(2.4, 5, 1.6), Color3.fromHex("#C8232B"))
			table.insert(pumps, p)
		end
	end
	local centre = Vector3.zero
	for _, p in pumps do
		centre += p.Position
	end
	centre /= #pumps
	local back = -V(F.LookVector.X, 0, F.LookVector.Z).Unit -- +Z of the site frame: away from the street
	local g = groundBelow(centre + back * 6.5, characters(), 2) -- under the canopy
	local tcf = CFrame.fromMatrix(g, F.RightVector, Vector3.yAxis)
	local tanker, tank = buildTanker(root, tcf)
	local label = billboard(tank, "FUEL LEAK", Color3.fromRGB(255, 220, 80), 6, Vector2.new(260, 60))

	local leaking = 0
	local blown = false
	local puddles: { BasePart } = {}
	local valves: { [BasePart]: ProximityPrompt } = {}
	for _, pump in pumps do
		leaking += 1
		local att = Instance.new("Attachment")
		att.Name = "LeakFx"
		att.Position = V(0, pump.Size.Y / 2, 0)
		att.Parent = pump
		local spray = Instance.new("ParticleEmitter")
		spray.Name = "FuelSpray"
		spray.Color = ColorSequence.new(Color3.fromHex("#C9D84A"), Color3.fromHex("#8FA83A"))
		spray.Size = NumberSequence.new(0.5, 1.8)
		spray.Transparency = NumberSequence.new(0.15, 1)
		spray.Speed = NumberRange.new(9, 15)
		spray.SpreadAngle = Vector2.new(25, 25)
		spray.Lifetime = NumberRange.new(0.6, 1.1)
		spray.Acceleration = V(0, -30, 0)
		spray.Rate = 35
		spray.EmissionDirection = Enum.NormalId.Top
		spray.Parent = att
		local foot = pump.Position - V(0, pump.Size.Y / 2, 0)
		local puddle = part(root, "FuelPuddle", CF(foot + V(0, 0.06, 0)) * CFrame.Angles(0, 0, math.pi / 2), V(0.1, 8, 8), Color3.fromHex("#B5C94A"), {
			shape = Enum.PartType.Cylinder,
			collide = false,
			query = false,
			transparency = 0.35,
			shadow = false,
		})
		table.insert(puddles, puddle)
		local valve = part(root, "ValveWheel", pump.CFrame * CF(pump.Size.X / 2 + 0.25, -0.4, 0), V(0.3, 1.8, 1.8), Color3.fromHex("#E03A2E"), {
			shape = Enum.PartType.Cylinder,
			collide = false,
		})
		local pr = makePrompt(ctx, valve, "Shut valve", "Leaking pump", HazardConfig.ValveHoldSeconds, 9)
		valves[valve] = pr
		onTrigger(pr, function(player: Player)
			if not valves[valve] then
				return
			end
			valves[valve] = nil
			pr:Destroy()
			spray.Enabled = false
			valve.Color = Color3.fromHex("#4CAF50")
			TweenService:Create(puddle, TweenInfo.new(1.5), { Transparency = 0.85 }):Play()
			leaking -= 1
			count("gas_valves_shut")
			Popup.show(valve, if leaking > 0 then `Valve shut! {leaking} still leaking` else "Last valve shut!", "good", player)
			if leaking <= 0 and not blown then
				count("gas_leak_stopped")
				label.Text = "TANKER SAFE :)"
				label.TextColor3 = Color3.fromRGB(120, 230, 120)
				tell(ctx, "Every pump shut! The tanker lives. Now the fires.", "good")
			end
		end)
	end

	local function blow()
		blown = true
		count("gas_tanker_blown")
		label.Text = "KABOOM"
		label.TextColor3 = Color3.fromRGB(255, 90, 60)
		for _, d in tanker:GetDescendants() do
			if d:IsA("BasePart") then
				d.Color = Color3.fromHex("#2E2A28")
				d.Material = Enum.Material.Slate
			end
		end
		ctx.explode(tank.Position, HazardConfig.TankerBlastRadius, nil)
		-- the fuel still on the ground goes up: each live puddle becomes a scripted fire (water cools it)
		for _, pud in puddles do
			if pud.Transparency < 0.6 then
				pud.Color = Color3.fromHex("#3A2A1A")
				local t = addTarget(ctx.instanceId, newTarget(pud, true, 2.5, "cool", true))
				light(t)
			end
		end
		tell(ctx, "KABOOM! The tanker went up. Put out the forecourt!", "bad")
	end

	onArrive(ctx, function()
		local seconds = HazardConfig.LeakSeconds
		tell(ctx, `GAS LEAK! Hold E on every pump valve before the tanker blows ({seconds}s).`, "bad")
		local endsAt = os.clock() + seconds
		local warned: { [number]: boolean } = {}
		while ctx.alive() and leaking > 0 and not blown do
			local left = math.max(0, math.ceil(endsAt - os.clock()))
			label.Text = string.format("TANKER BLOWS IN %d:%02d", left // 60, left % 60)
			for _, mark in { 30, 10 } do
				if left <= mark and not warned[mark] then
					warned[mark] = true
					tell(ctx, `{mark} SECONDS! {leaking} pump(s) still leaking!`, "bad")
				end
			end
			if left <= 0 then
				blow()
				break
			end
			task.wait(0.5)
		end
	end)
	return true
end

---------------------------------------------------------------------------------------------- pileup

local AXES = { Axe = true, FireAxe = true, GoldenAxe = true, Sledgehammer = true }
local WRECK_COLORS = { "#3D5A80", "#E9C46A", "#2A9D8F", "#E76F51", "#8E5572", "#C9CCD0" }

local function canPry(player: Player): boolean
	local hand = player:GetAttribute("InvHand")
	if type(hand) == "string" and hand ~= "" then
		local def = ItemDefs.get(hand)
		if (def and def.pry) or AXES[hand] then
			return true
		end
	end
	-- v1 loadout (no InventoryService): the Axe Tool in the hand counts
	local char = player.Character
	return char ~= nil and char:FindFirstChild("Axe") ~= nil
end

local function wreck(ctx: any, npc: Model, n: number)
	local root: Model = ctx.root
	local cf = npc:GetPivot()
	local look = V(cf.LookVector.X, 0, cf.LookVector.Z)
	look = if look.Magnitude > 0.05 then look.Unit else V(0, 0, -1)
	local g = groundBelow(cf.Position, characters(), 3)
	-- the driver sits on the car's left: car centre 1.7 studs to the driver's right
	local C = CFrame.lookAt(g, g + look) * CF(1.7, 0, 0)
	local color = Color3.fromHex(WRECK_COLORS[(n - 1) % #WRECK_COLORS + 1])
	local m = Instance.new("Model")
	m.Name = "Wreck"
	local hood = part(m, "Hood", C * CF(0, 1.6, -3.9) * CFrame.Angles(math.rad(14), 0, math.rad(5)), V(6.2, 1.9, 3.6), color)
	part(m, "Trunk", C * CF(0, 1.7, 4.1), V(6.2, 2.2, 3.4), color)
	part(m, "Sill", C * CF(0, 0.9, 0.2), V(6.2, 0.5, 5), color, { collide = false })
	part(m, "Roof", C * CF(0.3, 4, 0.2) * CFrame.Angles(0, 0, math.rad(9)), V(5.6, 0.35, 5), color, { collide = false })
	part(m, "Glass", C * CF(0, 3, -2.2) * CFrame.Angles(math.rad(-30), 0, 0), V(5.4, 2, 0.2), Color3.fromHex("#3E5866"), {
		material = Enum.Material.Glass,
		transparency = 0.5,
		collide = false,
		query = false,
	})
	part(m, "SidePanel", C * CF(3.05, 2.1, 0.2), V(0.3, 2.4, 5), color)
	local door = part(m, "JammedDoor", C * CF(-3.2, 2.1, 0.2) * CFrame.Angles(0, math.rad(4), 0), V(0.35, 2.6, 4.4), color)
	for _, w in { { -3.1, -3.4 }, { 3.1, -3.4 }, { -3.1, 3.6 }, { 3.1, 3.6 } } do
		part(m, "Wheel", C * CF(w[1], 1.1, w[2]), V(1.1, 2.2, 2.2), Color3.fromHex("#2B2B2E"), { shape = Enum.PartType.Cylinder, collide = false })
	end
	local smoke = Instance.new("Smoke")
	smoke.Color = Color3.fromRGB(110, 106, 100)
	smoke.Opacity = 0.3
	smoke.RiseVelocity = 5
	smoke.Size = 2.5
	smoke.Parent = hood
	m.Parent = root
	count("pileup_wrecks")

	-- pin the driver
	npc:SetAttribute("Pinned", true)
	local carry = npc:FindFirstChildWhichIsA("ProximityPrompt", true)
	if carry then
		carry.Enabled = false
	end
	local pr = makePrompt(ctx, door, "Pry door", "Jammed door", HazardConfig.PryHoldSeconds, 8)
	pr.PromptButtonHoldBegan:Connect(function(player: Player)
		if not canPry(player) then
			Popup.show(door, "Jammed! Hold a Halligan, crowbar or axe", "bad", player)
		end
	end)
	onTrigger(pr, function(player: Player)
		if not canPry(player) then
			count("pileup_wrong_tool")
			Popup.show(door, "Bare hands won't do it. Grab a Halligan, crowbar or axe!", "bad", player)
			return
		end
		pr:Destroy()
		count("pileup_doors_pried")
		door.Anchored = false
		door.CanCollide = false
		door.AssemblyLinearVelocity = -C.RightVector * 28 + V(0, 22, 0)
		door.AssemblyAngularVelocity = V(0, 6, 4)
		Debris:AddItem(door, 4)
		npc:SetAttribute("Pinned", false)
		local c = npc:FindFirstChildWhichIsA("ProximityPrompt", true)
		if c then
			c.Enabled = true
		end
		Popup.show(npc, "POP! I'm free! Carry me to the truck!", "good", player)
	end)
end

local function pileup(ctx: any): boolean
	local done: { [Model]: boolean } = {}
	local n = 0
	local function scan()
		for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
			if m:IsA("Model") and not done[m] and m:GetAttribute(Names.Attr.InstanceId) == ctx.instanceId and m:GetAttribute(Names.Attr.Kind) == "Civilian" then
				done[m] = true
				n += 1
				local ok, err = pcall(wreck, ctx, m, n)
				if not ok then
					warn(`[Twists] pileup wreck failed: {err}`)
				end
			end
		end
	end
	scan()
	if n == 0 then
		-- rescues spawn right before MissionStarted; give a late spawn a few tries
		ctx.thread(task.spawn(function()
			for _ = 1, 6 do
				task.wait(1)
				if not ctx.alive() then
					return
				end
				scan()
				if n > 0 then
					return
				end
			end
		end))
	end
	onArrive(ctx, function()
		tell(ctx, "PILE-UP! The drivers are pinned: pry the doors (Halligan, crowbar or axe).", "bad")
	end)
	return true
end

---------------------------------------------------------------------------------------------- cat_tree

local PUNS = {
	"I'm feline fine up here, thanks.",
	"This is a total cat-astrophe!",
	"Paws for thought: a LADDER?",
	"Purr-haps you could hurry up?",
	"I've got nine lives. Not nine HOURS.",
	"Me-WOW, you are slow.",
	"Hiss-terical service so far.",
	"Fur real, I can't get down.",
	"Claw-some view though.",
	"Don't make me paws the mission.",
}

local function catTree(ctx: any): boolean
	local root: Model = ctx.root
	local anchor: BasePart? = nil
	for _, name in { "ArrivalZone", "TruckSpot" } do
		local a = root:FindFirstChild(name, true)
		if a and a:IsA("BasePart") then
			anchor = a
			break
		end
	end
	local base = if anchor then anchor.CFrame else root:GetPivot()
	local yaw = base - base.Position
	local spot = (base * CF(-22, 0, 8)).Position
	local g = groundBelow(spot, characters())
	local H = HazardConfig.CatTreeHeight
	local m = Instance.new("Model")
	m.Name = "CatTree"
	local at = CF(g) * yaw
	part(m, "Trunk", at * CF(0, H / 2, 0) * CFrame.Angles(0, 0, math.pi / 2), V(H, 3.4, 3.4), Color3.fromHex("#6B4A2F"), {
		shape = Enum.PartType.Cylinder,
		material = Enum.Material.Wood,
	})
	local branch = part(m, "Branch", at * CF(0, H + 0.4, 0), V(9, 0.8, 9), Color3.fromHex("#5E8C3E"), { material = Enum.Material.Grass })
	for i, b in { { 0, 6, 0, 11 }, { 4, 4.5, 2, 7 }, { -4, 5, -2, 7.5 } } do
		part(m, `Leaves{i}`, at * CF(b[1], H + b[2], b[3]), V(b[4], b[4], b[4]), Color3.fromHex(if i == 1 then "#77B04A" else "#5E9E3E"), {
			shape = Enum.PartType.Ball,
			collide = false,
			query = false,
		})
	end
	local sign = part(m, "TreeSign", at * CF(0, 4, -1.8), V(3, 1.4, 0.2), Color3.fromHex("#F2EDE4"), { collide = false })
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	local txt = Instance.new("TextLabel")
	txt.Size = UDim2.fromScale(1, 1)
	txt.BackgroundTransparency = 1
	txt.Font = Enum.Font.FredokaOne
	txt.TextScaled = true
	txt.Text = "LOST: MR. WHISKERS (UP HERE)"
	txt.TextColor3 = Color3.fromHex("#5A3A32")
	txt.Parent = gui
	gui.Parent = sign
	m.Parent = root
	local marker = part(m, "CatSpawn", at * CF(1.5, H + 0.8 + 1, 1.5), V(2, 2, 2), Color3.new(1, 0, 0), {
		collide = false,
		query = false,
		transparency = 1,
		shadow = false,
	})
	marker:SetAttribute("Pose", "sitting")
	local Rescue = ctx.services.RescueService
	if not (Rescue and type(Rescue.SpawnAt) == "function") then
		return true -- the tree still stands; nothing to rescue
	end
	local ok, rid = pcall(Rescue.SpawnAt, Rescue, ctx.instanceId, marker, "Cat")
	local folder = workspace:FindFirstChild("Rescuables")
	local cat = if ok and type(rid) == "string" and folder then folder:FindFirstChild(rid) else nil
	if not (cat and cat:IsA("Model")) then
		warn(`[Twists] cat_tree: cat spawn failed ({rid})`)
		return true
	end
	count("cat_tree_spawned")
	cat:SetAttribute("Variant", "TreeCat")
	local catPart = cat.PrimaryPart or cat:FindFirstChildWhichIsA("BasePart")
	if catPart then
		local t = addTarget(ctx.instanceId, newTarget(catPart, false, 1, "hiss", false))
		local lastHiss = 0
		t.onWater = function(player: Player)
			local now = os.clock()
			if now - lastHiss < 4 then
				return
			end
			lastHiss = now
			count("cat_hosed")
			Popup.show(cat, "HISSSS! Cats. Hate. Water. Use the LADDER.", "blame", player)
		end
	end
	ctx.conn(cat:GetAttributeChangedSignal(Names.Attr.RescueState):Connect(function()
		local st = cat:GetAttribute(Names.Attr.RescueState)
		if st == "Carried" then
			Popup.show(cat, "Finally. A purr-fessional.", "good")
		elseif st == "Rescued" then
			tell(ctx, "Mr. Whiskers is safe! (He says thanks. Sort of.)", "good")
		end
	end))
	ctx.thread(task.spawn(function()
		local i = 0
		while ctx.alive() and cat.Parent do
			task.wait(HazardConfig.CatPunEvery)
			local st = cat:GetAttribute(Names.Attr.RescueState)
			if st == "Rescued" or st == "Toasted" or not cat.Parent then
				break
			end
			i += 1
			count("cat_puns")
			Popup.show(cat, PUNS[(i - 1) % #PUNS + 1], "info")
		end
	end))
	onArrive(ctx, function()
		tell(ctx, "A cat is stuck up the tree out front! Ladder up (and don't hose it).", "info")
		Popup.show(cat, PUNS[1], "info")
	end)
	return branch ~= nil
end

local ARMERS: { [string]: (any) -> boolean } = {
	grease_fire = greaseFire,
	gas_leak = gasLeak,
	pileup = pileup,
	cat_tree = catTree,
}
Twists.Kinds = { "grease_fire", "gas_leak", "pileup", "cat_tree" }

function Twists.arm(kind: string, ctx: any): boolean
	local fn = ARMERS[kind]
	if not fn then
		return false
	end
	local ok, res = pcall(fn, ctx)
	if not ok then
		warn(`[Twists] {kind} in {ctx.instanceId} failed: {res}`)
		return false
	end
	return res == true
end

return Twists
