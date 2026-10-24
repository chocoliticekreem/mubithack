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
--   RescueRules.mood(s): string                               -- idle|wave|approach|flee|cower|hide|zoom
--   RescueRules.desire(p): (number, number)                   -- wanted run direction (x, z)
--   RescueRules.pickHeading(cands, dx, dz, need): number?     -- best unblocked heading, nil = boxed in
--   RescueRules.headings(dx, dz): { {x, z} }                  -- 8 headings, nearest to (dx, dz) first
--   RescueRules.stepOk(feetY, groundY?, up, down): boolean    -- floor under the next step?
--   RescueRules.smokeLevel(raw): number                       -- room "Smoke" attribute -> 0..1
--   RescueRules.callForHelp(dist, sees, hearRadius): boolean  -- "HELP! IN HERE!"
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

-- Panic brain (v2: geometry-aware panic; RescueService does the casting, these decide) ----------

-- What an NPC that is free to move (Trapped, not carried/flying) does this tick.
-- s: { kind, fireDist, panicRadius, sees: boolean (a firefighter in line of sight within SeeRadius),
--      playerDist, boxedIn: boolean (no clear heading last tick), hideSpot: boolean (cat found cover),
--      hidden: boolean (cat is already under it), standing: boolean (pose ~= "lying") }
-- Returns "idle" | "wave" | "approach" | "flee" | "cower" | "hide" | "zoom".
function RescueRules.mood(s: any): string
	if not s.standing then
		return "idle"
	end
	local panicking = s.fireDist <= s.panicRadius
	if not panicking then
		return if s.sees then (if s.kind == "Civilian" or s.kind == "Dog" then "approach" else "wave") else "idle"
	end
	if s.kind == "Cat" then
		if s.hidden or s.hideSpot then
			return "hide"
		end
		return if s.boxedIn then "cower" else "zoom"
	end
	if s.kind == "Panda" then
		return if s.boxedIn then "cower" else "flee" -- slow waddle away; sits and flails when stuck
	end
	if s.sees and (s.kind == "Civilian" or s.kind == "Dog") then
		return "approach" -- a firefighter came in: run to them
	end
	if s.boxedIn then
		return "cower"
	end
	return if s.kind == "Dog" then "zoom" else "flee"
end

-- Desired run direction (unnormalised x, z) for a mood. All positions are flat (x, z).
-- p: { x, z, fx, fz (nearest fire), hx, hz (home/leash anchor), leash, t, tx?, tz? (target: player or
--      hide spot), mood }
function RescueRules.desire(p: any): (number, number)
	local dx, dz = 0, 0
	if (p.mood == "approach" or p.mood == "hide") and p.tx then
		dx, dz = p.tx - p.x, p.tz - p.z
	elseif p.mood == "zoom" then
		-- zoomies: loop around home (the old circle, but steered, so walls bend it)
		local ox, oz = p.x - p.hx, p.z - p.hz
		local r = math.sqrt(ox * ox + oz * oz)
		if r < 0.5 then
			ox, oz, r = 1, 0, 1
		end
		dx, dz = -oz / r, ox / r -- tangent
		local pull = (r - p.leash * 0.35) / math.max(p.leash, 1) -- drift back onto a loop of ~1/3 leash
		dx -= ox / r * pull * 2
		dz -= oz / r * pull * 2
	elseif p.mood == "flee" then
		local ax, az = p.x - p.fx, p.z - p.fz
		local m = math.sqrt(ax * ax + az * az)
		if m > 0.01 then
			dx, dz = ax / m, az / m
		end
		-- a little side-to-side wobble so it reads as panicked, not a robot
		local w = math.sin(p.t * 2.3) * 0.45
		dx, dz = dx - dz * w, dz + dx * w
	end
	-- leash: past 70% of the leash the pull home grows until it wins at the edge
	local hx, hz = p.hx - p.x, p.hz - p.z
	local hd = math.sqrt(hx * hx + hz * hz)
	if hd > p.leash * 0.7 and hd > 0.01 then
		local k = (hd - p.leash * 0.7) / math.max(p.leash * 0.3, 0.5) * 1.5
		dx += hx / hd * k
		dz += hz / hd * k
	end
	return dx, dz
end

-- Pick a heading. cands: list of { x, z (unit), clear (studs free that way) }; need: studs that must be
-- free. Prefers the direction closest to (dx, dz), slightly prefers open space, never picks a blocked one.
-- Returns the index or nil when every candidate is blocked (= boxed in).
function RescueRules.pickHeading(cands: { any }, dx: number, dz: number, need: number): number?
	local m = math.sqrt(dx * dx + dz * dz)
	local ux, uz = if m > 1e-3 then dx / m else 0, if m > 1e-3 then dz / m else 0
	local best, bestScore = nil, -math.huge
	for i, c in cands do
		if c.clear >= need then
			local score = c.x * ux + c.z * uz + 0.2 * math.min(c.clear, 8) / 8
			if score > bestScore then
				best, bestScore = i, score
			end
		end
	end
	return best
end

-- The 8 compass headings (unit x, z), starting at +X and going counter-clockwise; `first` rotates the
-- list so the direction nearest (dx, dz) is tried first (cheap: most ticks need only one cast).
function RescueRules.headings(dx: number, dz: number): { { x: number, z: number } }
	local base = math.atan2(dz, dx)
	local out = {}
	local order = { 0, 1, -1, 2, -2, 3, -3, 4 }
	for i, k in order do
		local a = base + k * math.pi / 4
		out[i] = { x = math.cos(a), z = math.sin(a) }
	end
	return out
end

-- Can a walker step from feetY onto groundY? (stairs/kerbs up to `up`, small drops up to `down`)
function RescueRules.stepOk(feetY: number, groundY: number?, up: number, down: number): boolean
	if groundY == nil then
		return false -- no floor: a hole, a balcony edge, or the floor is missing
	end
	local d = groundY - feetY
	return d <= up and d >= -down
end

-- Smoke on a room/part attribute: true/false, a number 0..1 (or 0..100), or a string level.
function RescueRules.smokeLevel(raw: any): number
	if raw == true then
		return 1
	end
	if type(raw) == "number" and raw == raw then
		return math.clamp(if raw > 1 then raw / 100 else raw, 0, 1)
	end
	if type(raw) == "string" then
		local s = string.lower(raw)
		return if s == "heavy" or s == "thick" then 1 elseif s == "light" or s == "thin" then 0.4 elseif s == "" or s == "none" then 0 else 0.7
	end
	return 0
end

-- Should a trapped NPC shout for help? Somebody is close enough to hear but can't see it.
function RescueRules.callForHelp(playerDist: number, sees: boolean, hearRadius: number): boolean
	return not sees and playerDist <= hearRadius
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
		trapped = { "HELP! IN HERE!", "IN HERE! HELP!", "ANYBODY?! IN HERE!" },
		wave = { "OVER HERE!", "HEY! HERE!", "ME! PICK ME!" },
		cower = { "I'M TRAPPED!", "MOMMY!", "NOT THE FACE!" },
		cough = { "*cough cough*", "*HACK*", "*wheeze*" },
		calm = { "phew...", "is it out?", "...nice." },
	},
	Dog = {
		idle = { "WOOF?", "bork" },
		panic = { "WOOF WOOF!", "AWOOOO!" },
		carried = { "WOOF!", "*lick*", "bork bork!" },
		flying = { "YIPYIPYIP", "AWOOOOO" },
		downed = { "*whimper*" },
		rescued = { "*happy bork*", "WOOF!" },
		toasted = { "*sad bork*" },
		trapped = { "WOOF! WOOF! (in here!)", "AWOO? (help)" },
		wave = { "BORK! BORK!", "*tail wag*" },
		cower = { "*whimper*", "*hides face*" },
		cough = { "*sneeze*", "*hrk*" },
		calm = { "*pant pant*", "bork." },
		zoom = { "ZOOMIES!", "BORKBORKBORK" },
	},
	Cat = {
		idle = { "mrrp", "meow?" },
		panic = { "MRAOOW!", "HSSSS!" },
		carried = { "MEOW!", "MRAAAOW!", "HSSS!", "*scratch*" },
		flying = { "MRAAAAOOOOW", "nyoooom" },
		downed = { "...mew" },
		rescued = { "purrrr", "mrrp :3" },
		toasted = { "...hiss" },
		trapped = { "MEOW! (in here)", "mrrrOW?!" },
		wave = { "mrrp!", "meow." },
		cower = { "HSSSS!", "*puffed up*" },
		cough = { "*hairball noises*", "*hck*" },
		calm = { "...purr", "mrrp" },
		hide = { "*hides*", "...", "(not here)" },
		zoom = { "NYOOOM", "MRAOW!" },
	},
	Panda = {
		idle = { "???", "*chews bamboo*" },
		panic = { "???!", "*confused panda noises*" },
		carried = { "???", "*heavy breathing*", "bamboo?" },
		flying = { "?!?!?!", "!!!" },
		downed = { "zzz" },
		rescued = { "*happy panda*", "bamboo!" },
		toasted = { "*sad panda*" },
		trapped = { "??? (help)", "*panda SOS*" },
		wave = { "*waves bamboo*", "???" },
		cower = { "*sits. refuses.*", "*panda panic*" },
		cough = { "*panda cough*", "*sneeze*" },
		calm = { "*chews bamboo*", "bamboo." },
	},
}

function RescueRules.line(kind: string, mood: string, n: number): string
	local byKind = LINES[kind] or LINES.Civilian
	local list = byKind[mood] or byKind.idle
	return list[((math.floor(n) - 1) % #list) + 1]
end

return RescueRules
