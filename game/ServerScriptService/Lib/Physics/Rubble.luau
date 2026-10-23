--!strict
-- Rubble [owner: Structure]. Server-side watchdog for collapsing building pieces (StructureService
-- collapses, HazardService ceiling_collapse). Before this, a burning house "bounced off the plot": roof
-- slabs released together overlapped each other and the walls, the solver shoved them apart, and they
-- landed 40-80 studs away. Every released piece now:
--   * starts with ZERO linear velocity and a tiny spin, server network owner, heavy/grippy/no-bounce
--     physics (StructureConfig.RubbleDensity/Friction, elasticity 0);
--   * is in collision group "RubbleFresh" for RubbleFreshSeconds (doesn't collide with other rubble, so
--     overlapping chunks can't explode apart), then "Rubble" (piles up on rubble, collides with the world);
--   * has its velocity clamped every frame (RubbleMaxHorizontal / RubbleMaxUp / RubbleMaxDown, spin
--     RubbleMaxSpin) and leashed: past RubbleLeash (+ half its size) from where it let go it loses any
--     outward speed; past RubbleMaxDrift it crumbles to dust (invisible, no collision, anchored);
--   * re-anchors once still (SettleMinSeconds / SettleSpeed) or at SettleMaxSeconds regardless.
-- The maths is RubbleMath (pure, spec-tested).
--
--   Rubble.release(part, onDone: ((BasePart, string) -> ())?): boolean  -- unanchor + watch it. false: already loose
--   Rubble.adopt(part, onDone?): boolean          -- someone else unanchored it: zero it and watch it
--                                                    (already watched without a callback: just takes onDone)
--   Rubble.crumble(part)                            -- dust: Transparency 1, no collision, anchored
--   Rubble.forget(part)                             -- stop watching (no callback)
--   Rubble.count(): number                          -- pieces loose right now
-- onDone(part, how) fires once with how = "settled" | "crumbled" | "gone".
-- Counters: rubble_released, rubble_settled, rubble_crumbled, rubble_clamped
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RubbleMath = require(script.Parent:WaitForChild("RubbleMath") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("StructureConfig") :: ModuleScript) :: any

local Rubble = {}

local FRESH, SETTLED = "RubbleFresh", "Rubble"

type Piece = {
	part: BasePart,
	origin: Vector3,
	at: number,
	leash: number,
	group: string,
	onDone: ((BasePart, string) -> ())?,
}

local pieces: { Piece } = {}
local byPart: { [BasePart]: Piece } = {}
local conn: RBXScriptConnection? = nil
local groupsReady = false
local rng = Random.new()

local function count(name: string, n: number?)
	pcall(Telemetry.count, name, n or 1)
end

local function ensureGroups()
	if groupsReady then
		return
	end
	groupsReady = true
	pcall(function()
		for _, g in { FRESH, SETTLED } do
			if not PhysicsService:IsCollisionGroupRegistered(g) then
				PhysicsService:RegisterCollisionGroup(g)
			end
		end
		PhysicsService:CollisionGroupSetCollidable(FRESH, FRESH, false)
		PhysicsService:CollisionGroupSetCollidable(FRESH, SETTLED, false)
		PhysicsService:CollisionGroupSetCollidable(SETTLED, SETTLED, true)
	end)
end

local function setGroup(p: BasePart, g: string)
	if p.CollisionGroup ~= g then
		pcall(function()
			p.CollisionGroup = g
		end)
	end
end

local function finish(i: number, how: string)
	local pc = pieces[i]
	table.remove(pieces, i)
	if byPart[pc.part] == pc then
		byPart[pc.part] = nil
	end
	if pc.part.Parent then
		setGroup(pc.part, SETTLED)
	end
	count(if how == "crumbled" then "rubble_crumbled" else "rubble_settled")
	if pc.onDone then
		task.spawn(pc.onDone, pc.part, how)
	end
end

function Rubble.crumble(p: BasePart)
	p.Anchored = true
	p.Transparency = 1
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
end

local function step(_dt: number)
	local now = os.clock()
	local maxH, maxUp, maxDown, maxSpin = Cfg.RubbleMaxHorizontal, Cfg.RubbleMaxUp, Cfg.RubbleMaxDown, Cfg.RubbleMaxSpin
	local voidY = workspace.FallenPartsDestroyHeight + 50
	local vcfg = {
		VoidY = voidY,
		RubbleMaxDrift = Cfg.RubbleMaxDrift,
		SettleMinSeconds = Cfg.SettleMinSeconds,
		SettleMaxSeconds = Cfg.SettleMaxSeconds,
		SettleSpeed = Cfg.SettleSpeed,
		RubbleFreshSeconds = Cfg.RubbleFreshSeconds,
	}
	local clamped = 0
	for i = #pieces, 1, -1 do
		local pc = pieces[i]
		local p = pc.part
		if not p.Parent then
			finish(i, "gone")
			continue
		end
		if p.Anchored then
			finish(i, "settled") -- someone (reset, PhysicsFx sleep) anchored it already
			continue
		end
		local age = now - pc.at
		local pos = p.Position
		local dx, dz = pos.X - pc.origin.X, pos.Z - pc.origin.Z
		local v = p.AssemblyLinearVelocity
		local verdict = RubbleMath.verdict(age, v.Magnitude, math.sqrt(dx * dx + dz * dz), pos.Y, vcfg)
		if verdict == "crumble" then
			Rubble.crumble(p)
			finish(i, "crumbled")
			continue
		elseif verdict == "settle" then
			p.AssemblyLinearVelocity = Vector3.zero
			p.AssemblyAngularVelocity = Vector3.zero
			p.Anchored = true
			finish(i, "settled")
			continue
		end
		local g = RubbleMath.group(age, vcfg)
		if g ~= pc.group then
			pc.group = g
			setGroup(p, g)
		end
		local x, y, z = RubbleMath.clampVelocity(v.X, v.Y, v.Z, maxH, maxUp, maxDown)
		x, z = RubbleMath.leash(dx, dz, x, z, pc.leash)
		if x ~= v.X or y ~= v.Y or z ~= v.Z then
			p.AssemblyLinearVelocity = Vector3.new(x, y, z)
			clamped += 1
		end
		local w = p.AssemblyAngularVelocity
		local wx, wy, wz = RubbleMath.clampSpin(w.X, w.Y, w.Z, maxSpin)
		if wx ~= w.X or wy ~= w.Y or wz ~= w.Z then
			p.AssemblyAngularVelocity = Vector3.new(wx, wy, wz)
		end
	end
	if clamped > 0 then
		count("rubble_clamped", clamped)
	end
	if #pieces == 0 and conn then
		conn:Disconnect()
		conn = nil
	end
end

local function watch(p: BasePart, onDone: ((BasePart, string) -> ())?)
	local size = p.Size
	local pc: Piece = {
		part = p,
		origin = p.Position,
		at = os.clock(),
		leash = Cfg.RubbleLeash + math.max(size.X, size.Z) * 0.5,
		group = FRESH,
		onDone = onDone,
	}
	byPart[p] = pc
	table.insert(pieces, pc)
	if not conn then
		conn = RunService.Heartbeat:Connect(step)
	end
end

local function prime(p: BasePart)
	ensureGroups()
	setGroup(p, FRESH)
	p.CustomPhysicalProperties = PhysicalProperties.new(Cfg.RubbleDensity, Cfg.RubbleFriction, 0, 50, 50)
	p.AssemblyLinearVelocity = Vector3.zero
	local k = Cfg.FallKick
	p.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-k, k), rng:NextNumber(-k / 2, k / 2), rng:NextNumber(-k, k))
	pcall(function()
		p:SetNetworkOwner(nil) -- server simulates rubble: nobody can fling it at the squad
	end)
end

function Rubble.release(p: BasePart, onDone: ((BasePart, string) -> ())?): boolean
	if byPart[p] or not p.Parent then
		return false
	end
	p.CanCollide = true
	p.Anchored = false
	prime(p)
	watch(p, onDone)
	count("rubble_released")
	return true
end

function Rubble.adopt(p: BasePart, onDone: ((BasePart, string) -> ())?): boolean
	local pc = byPart[p]
	if pc then
		if pc.onDone == nil and onDone then
			pc.onDone = onDone -- released by HazardService, now also owned by StructureService's budget
			return true
		end
		return false
	end
	if not p.Parent or p.Anchored then
		return false
	end
	prime(p)
	watch(p, onDone)
	count("rubble_released")
	return true
end

function Rubble.watching(p: BasePart): boolean
	return byPart[p] ~= nil
end

function Rubble.forget(p: BasePart)
	local pc = byPart[p]
	if not pc then
		return
	end
	byPart[p] = nil
	for i = #pieces, 1, -1 do
		if pieces[i] == pc then
			table.remove(pieces, i)
		end
	end
end

function Rubble.count(): number
	return #pieces
end

return Rubble
