--!strict
-- RescueRules [owner: G3]. Pure rescue maths shared by RescueService (and game/tests/rescue.spec.luau).
-- No Roblox APIs here (no game, Instance, Vector3, task) so the `luau` CLI can run the spec.
--   RescueRules.kind(raw: any): string                        -- "Civilian" | "Dog" | "Cat" | "Panda"
--   RescueRules.pose(raw: any): string                        -- "stand" | "sitting" | "lying"
--   RescueRules.initialState(pose: string): string            -- lying = KO = "Downed", else "Trapped"
--   RescueRules.canPick(state: string): boolean
--   RescueRules.speed(kind, carriers, cfg): number            -- carrier WalkSpeed
--   RescueRules.throwSpeed(charge, kind, cfg): (number, number)  -- forward, up (studs/s)
--   RescueRules.landing(peakSpeed, cfg): "Downed" | "Trapped"
--   RescueRules.fireDamage(dist, level, dt, cfg): number      -- HP lost this tick
--   RescueRules.panicPoint(t, radius, speed): (number, number, number)  -- x, z offset, facing angle
--   RescueRules.pair(pending, now, window, need): { any }     -- the first `need` recent grabbers
--   RescueRules.inBox(px, py, pz, hx, hy, hz, pad): boolean   -- point in a box's local space
--   RescueRules.culprit(rec, now, window): any?               -- who to blame for a toasting
--   RescueRules.line(kind, mood, n): string                   -- shout bubble text

local RescueRules = {}

local KINDS: { [string]: string } = {
	civilian = "Civilian",
	floatguy = "Civilian", -- v2 pool-float guy: a civilian for now
	kid = "Civilian",
	dog = "Dog",
	cat = "Cat",
	panda = "Panda",
}

function RescueRules.kind(raw: any): string
	if type(raw) ~= "string" then
		return "Civilian"
	end
	return KINDS[string.lower(raw)] or "Civilian"
end

function RescueRules.pose(raw: any): string
	if raw == "lying" or raw == "sitting" or raw == "stand" then
		return raw
	end
	return "stand"
end

function RescueRules.initialState(pose: string): string
	return if pose == "lying" then "Downed" else "Trapped"
end

function RescueRules.canPick(state: any): boolean
	return state == "Trapped" or state == "Downed"
end

-- cfg: WalkSpeed, Speed<Kind>, SpeedPandaPair
function RescueRules.speed(kind: string, carriers: number, cfg: any): number
	local mult = cfg[`Speed{kind}`]
	if kind == "Panda" and carriers >= 2 then
		mult = cfg.SpeedPandaPair
	end
	if type(mult) ~= "number" then
		mult = 0.75
	end
	return cfg.WalkSpeed * mult
end

-- charge 0..1 (how long Q was held). cfg: ThrowMin, ThrowMax, ThrowUp, ThrowPandaMult
function RescueRules.throwSpeed(charge: number, kind: string, cfg: any): (number, number)
	local c = math.clamp(if charge == charge then charge else 0, 0, 1)
	local forward = cfg.ThrowMin + (cfg.ThrowMax - cfg.ThrowMin) * c
	local up = cfg.ThrowUp * (0.6 + 0.4 * c)
	if kind == "Panda" then
		forward *= cfg.ThrowPandaMult
		up *= cfg.ThrowPandaMult
	end
	return forward, up
end

-- peakSpeed: fastest the NPC moved while airborne. cfg: DownedImpact
function RescueRules.landing(peakSpeed: number, cfg: any): string
	return if peakSpeed >= cfg.DownedImpact then "Downed" else "Trapped"
end

-- dist: studs to the nearest Burning part; level: its FireLevel 1..3.
-- cfg: FireHurtRadius, FireDps
function RescueRules.fireDamage(dist: number, level: number, dt: number, cfg: any): number
	if dist > cfg.FireHurtRadius then
		return 0
	end
	local closeness = 1 - math.clamp(dist / cfg.FireHurtRadius, 0, 1) * 0.5 -- 0.5 at the edge, 1 inside
	return cfg.FireDps * dt * closeness * math.clamp(level, 1, 3) / 2 -- level 1/2/3 = x0.5/x1/x1.5
end

-- Running in a circle (the comedy): position on a circle of `radius` after t seconds at `speed`.
-- Returns x, z (relative to the panic centre) and the yaw (radians) the NPC faces (the tangent).
function RescueRules.panicPoint(t: number, radius: number, speed: number): (number, number, number)
	local r = math.max(radius, 0.5)
	local a = t * speed / r
	local x, z = math.cos(a) * r, math.sin(a) * r
	-- tangent of (cos a, sin a) is (-sin a, cos a); Roblox faces -Z, so yaw = atan2(-dx, -dz)
	local yaw = math.atan2(math.sin(a), -math.cos(a))
	return x, z, yaw
end

-- pending: { [key]: timestamp } of recent "Pick up" triggers. Returns up to `need` keys whose
-- trigger is within `window` of now (oldest first) when at least `need` qualify; else {}.
function RescueRules.pair(pending: { [any]: number }, now: number, window: number, need: number): { any }
	local list: { { k: any, t: number } } = {}
	for k, t in pending do
		if now - t <= window then
			table.insert(list, { k = k, t = t })
		end
	end
	if #list < need then
		return {}
	end
	table.sort(list, function(a, b)
		return a.t < b.t
	end)
	local out = {}
	for i = 1, need do
		out[i] = list[i].k
	end
	return out
end

function RescueRules.inBox(px: number, py: number, pz: number, hx: number, hy: number, hz: number, pad: number): boolean
	return math.abs(px) <= hx + pad and math.abs(py) <= hy + pad and math.abs(pz) <= hz + pad
end

-- rec: { thrower: any?, thrownAt: number?, dropper: any?, droppedAt: number? }
function RescueRules.culprit(rec: any, now: number, window: number): any?
	if rec.thrower ~= nil and rec.thrownAt and now - rec.thrownAt <= window then
		return rec.thrower
	end
	if rec.dropper ~= nil and rec.droppedAt and now - rec.droppedAt <= window then
		return rec.dropper
	end
	return nil
end

local LINES: { [string]: { [string]: { string } } } = {
	Civilian = {
		idle = { "HELP!", "OVER HERE!", "IS IT HOT IN HERE?" },
		panic = { "AAAAAH!", "FIRE FIRE FIRE!", "I LEFT THE OVEN ON!" },
		carried = { "AAAAAH!", "PUT ME DOWN!", "NOT LIKE THIS!", "MIND MY HAIR!", "WHEEE?" },
		flying = { "WHYYYYY", "AAAAAAAAAA", "I CAN FLYYY" },
		downed = { "zzz...", "@_@" },
		rescued = { "MY HERO!", "THANK YOU!", "...again!" },
		toasted = { "...crispy", "well done." },
	},
	Dog = {
		idle = { "WOOF?", "bork" },
		panic = { "WOOF WOOF!", "AWOOOO!" },
		carried = { "WOOF!", "*lick*", "bork bork!" },
		flying = { "YIPYIPYIP", "AWOOOOO" },
		downed = { "*whimper*" },
		rescued = { "*happy bork*", "WOOF!" },
		toasted = { "*sad bork*" },
	},
	Cat = {
		idle = { "mrrp", "meow?" },
		panic = { "MRAOOW!", "HSSSS!" },
		carried = { "MEOW!", "MRAAAOW!", "HSSS!", "*scratch*" },
		flying = { "MRAAAAOOOOW", "nyoooom" },
		downed = { "...mew" },
		rescued = { "purrrr", "mrrp :3" },
		toasted = { "...hiss" },
	},
	Panda = {
		idle = { "???", "*chews bamboo*" },
		panic = { "???!", "*confused panda noises*" },
		carried = { "???", "*heavy breathing*", "bamboo?" },
		flying = { "?!?!?!", "!!!" },
		downed = { "zzz" },
		rescued = { "*happy panda*", "bamboo!" },
		toasted = { "*sad panda*" },
	},
}

function RescueRules.line(kind: string, mood: string, n: number): string
	local byKind = LINES[kind] or LINES.Civilian
	local list = byKind[mood] or byKind.idle
	return list[((math.floor(n) - 1) % #list) + 1]
end

return RescueRules
