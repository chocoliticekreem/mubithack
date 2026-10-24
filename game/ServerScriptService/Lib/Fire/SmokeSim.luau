--!strict
-- SmokeSim [owner: Smoke agent]. PURE room smoke / heat / pressure maths for SmokeService (no Roblox
-- APIs, no requires: game/tests/smoke_sim.spec.luau runs it with the `luau` CLI).
--
-- Rooms hold smoke (0 clear .. 1 full to the floor), heat (0..100) and pressure (0..1). Fires in a
-- room add smoke and heat (scaled by RefArea / area: big rooms fill slower). Links join two rooms, or
-- a room and the outside (b = 0): doors, windows, stairwells. Smoke and heat flow down the difference
-- through each link, fast through open ones, a trickle under closed doors (the seep). A room whose
-- whole compartment (rooms joined by open links) has no open link to the outside is SEALED; sealed +
-- heavy smoke + heavy fire builds pressure: stage 1 (warn) at WarnAt, stage 2 (armed) at ArmedAt.
-- Opening a door on an armed room = backdraft; venting a window first relieves it.
--
--   SmokeSim.newRoom(area): Room
--   SmokeSim.newLink(a, b, kind, open): Link        -- kind "door" | "window" | "stair" | "gap"
--   SmokeSim.conductance(kind, open, cfg): number
--   SmokeSim.compartments(rooms, links, cfg)        -- sets room.comp + room.vented
--   SmokeSim.stage(pressure, cfg): number           -- 0 calm, 1 warn, 2 armed
--   SmokeSim.step(rooms, links, dt, cfg): { Event } -- Event = { kind = "warn"|"armed"|"calm"|"spread",
--                                                       room?, link?, from?, to? }
--   SmokeSim.onOpened(rooms, links, li, cfg): (string?, number?)  -- link li just opened:
--       "backdraft" (door onto an armed room), "relief" (any opening on a pressurized compartment),
--       "vent" (a smoky room), or nil; plus the room index it's about. Applies the outcome's effect.
--   SmokeSim.playerHeatRate(smoke, heat, masked, air, cfg): number   -- body heat / s
--   SmokeSim.chokeDps(smoke, cfg): number           -- rescue NPC HP / s
--   SmokeSim.layer(smoke, height, cfg): (number, number)  -- smoke layer depth (studs), transparency
--   SmokeSim.doorState(sa, sb, ha, hb): (number, number, number) -- seep 0..1, seep sign (+1 = a -> b), heat 0..1

local SmokeSim = {}

export type Room = {
	smoke: number,
	heat: number,
	pressure: number,
	fire: number, -- FireLevel points burning in the room (input, set every tick)
	area: number,
	stage: number,
	comp: number,
	vented: boolean,
}
export type Link = {
	a: number,
	b: number, -- 0 = outside
	kind: string,
	open: boolean,
	charge: number, -- fire-spread progress 0..1
	flow: number, -- last smoke flow a -> b per second (negative = b -> a)
}
export type Event = { kind: string, room: number?, link: number?, from: number?, to: number? }
export type Cfg = { [string]: any }

function SmokeSim.newRoom(area: number): Room
	return { smoke = 0, heat = 0, pressure = 0, fire = 0, area = area, stage = 0, comp = 0, vented = false }
end

function SmokeSim.newLink(a: number, b: number, kind: string, open: boolean): Link
	return { a = a, b = b, kind = kind, open = open, charge = 0, flow = 0 }
end

function SmokeSim.conductance(kind: string, open: boolean, cfg: Cfg): number
	if kind == "stair" or kind == "gap" then
		return cfg.StairFlow
	elseif kind == "door" then
		return if open then cfg.OpenDoorFlow else cfg.SeepFlow
	elseif kind == "window" then
		return if open then cfg.OpenWindowFlow else cfg.ClosedWindowFlow
	end
	return 0
end

local function isOpen(l: Link, cfg: Cfg): boolean
	return SmokeSim.conductance(l.kind, l.open, cfg) >= cfg.OpenFlowAt
end

function SmokeSim.compartments(rooms: { Room }, links: { Link }, cfg: Cfg)
	local parent: { number } = {}
	for i in rooms do
		parent[i] = i
	end
	local function find(i: number): number
		while parent[i] ~= i do
			parent[i] = parent[parent[i]]
			i = parent[i]
		end
		return i
	end
	for _, l in links do
		if l.b > 0 and isOpen(l, cfg) and rooms[l.a] and rooms[l.b] then
			parent[find(l.a)] = find(l.b)
		end
	end
	local vented: { [number]: boolean } = {}
	for _, l in links do
		if l.b == 0 and rooms[l.a] and isOpen(l, cfg) then
			vented[find(l.a)] = true
		end
	end
	for i, r in rooms do
		r.comp = find(i)
		r.vented = vented[r.comp] == true
	end
end

function SmokeSim.stage(pressure: number, cfg: Cfg): number
	if pressure >= cfg.ArmedAt then
		return 2
	elseif pressure >= cfg.WarnAt then
		return 1
	end
	return 0
end

function SmokeSim.step(rooms: { Room }, links: { Link }, dt: number, cfg: Cfg): { Event }
	local events: { Event } = {}
	SmokeSim.compartments(rooms, links, cfg)
	-- sources
	for _, r in rooms do
		local f = math.min(r.fire, cfg.FireCap)
		local k = cfg.RefArea / math.max(r.area, cfg.MinArea)
		r.smoke += f * cfg.SmokePerLevel * k * dt
		r.heat += f * cfg.HeatPerLevel * k * dt
	end
	-- flows: every delta from the same starting state, then applied together
	local ds: { number } = {}
	local dh: { number } = {}
	for i in rooms do
		ds[i], dh[i] = 0, 0
	end
	for _, l in links do
		local ra = rooms[l.a]
		if not ra then
			continue
		end
		local rb = if l.b > 0 then rooms[l.b] else nil
		local sb = if rb then rb.smoke else 0
		local hb = if rb then rb.heat else 0
		local g = SmokeSim.conductance(l.kind, l.open, cfg)
		local diff = ra.smoke - sb
		local gs = g
		if l.kind == "stair" and diff < 0 then
			gs *= cfg.SinkFactor -- smoke rises: the upper floor pushes down only weakly
		end
		local t = math.min(gs * dt, 0.45) * diff
		local th = math.min(g * cfg.HeatFlowFactor * dt, 0.45) * (ra.heat - hb)
		l.flow = t / dt
		ds[l.a] -= t
		dh[l.a] -= th
		if rb then
			ds[l.b] += t
			dh[l.b] += th
		end
	end
	for i, r in rooms do
		r.smoke = math.clamp(r.smoke + ds[i] - cfg.Leak * r.smoke * dt, 0, 1)
		r.heat = math.clamp(r.heat + dh[i] - cfg.HeatLoss * r.heat * dt, 0, 100)
	end
	-- pressure (backdraft build-up)
	for i, r in rooms do
		local old = r.stage
		if not r.vented and r.smoke >= cfg.PressureSmoke and r.fire >= cfg.PressureFire then
			-- a bigger fire in a sealed room pressurizes faster (up to PressureFireBoost x)
			local boost = math.clamp(r.fire / (cfg.PressureFire * 3), 1, cfg.PressureFireBoost)
			r.pressure += cfg.PressureRate * boost * dt
		elseif r.vented then
			r.pressure -= cfg.VentRelief * dt
		else
			r.pressure -= cfg.PressureDecay * dt
		end
		r.pressure = math.clamp(r.pressure, 0, 1)
		r.stage = SmokeSim.stage(r.pressure, cfg)
		if r.stage > old then
			table.insert(events, { kind = if r.stage == 2 then "armed" else "warn", room = i })
		elseif r.stage == 0 and old > 0 then
			table.insert(events, { kind = "calm", room = i })
		end
	end
	-- fire creeping into the next room (under closed doors, faster through open ones)
	for li, l in links do
		if l.b <= 0 or not rooms[l.a] or not rooms[l.b] then
			continue
		end
		local a, b = rooms[l.a], rooms[l.b]
		local from, to = l.a, l.b
		if b.heat > a.heat then
			from, to = l.b, l.a
		end
		local src, dst = rooms[from], rooms[to]
		local rate = if isOpen(l, cfg) then cfg.SpreadOpenRate else cfg.SpreadSeepRate
		if src.heat >= cfg.SpreadHeat and src.fire >= 1 and dst.fire < cfg.SpreadSkipFire then
			l.charge += rate * dt * src.heat / 100
			if l.charge >= 1 then
				l.charge = 0
				table.insert(events, { kind = "spread", link = li, from = from, to = to })
			end
		else
			l.charge = math.max(0, l.charge - rate * dt * 0.5)
		end
	end
	return events
end

function SmokeSim.onOpened(rooms: { Room }, links: { Link }, li: number, cfg: Cfg): (string?, number?)
	local l = links[li]
	if not l then
		return nil, nil
	end
	local sides = { l.a }
	if l.b > 0 then
		table.insert(sides, l.b)
	end
	-- a door straight onto an armed room: FWOOSH
	if l.kind == "door" then
		local worst, wi = -1, nil :: number?
		for _, i in sides do
			local r = rooms[i]
			if r and r.stage >= 2 and r.pressure > worst then
				worst, wi = r.pressure, i
			end
		end
		if wi then
			local r = rooms[wi]
			r.pressure = 0
			r.stage = 0
			r.smoke *= cfg.BackdraftSmokeKeep
			r.heat = math.min(100, r.heat + cfg.BackdraftHeat)
			return "backdraft", wi
		end
	end
	-- any other opening on a pressurized compartment lets it out safely
	SmokeSim.compartments(rooms, links, cfg)
	local relief: number? = nil
	for _, i in sides do
		local r = rooms[i]
		if r then
			for j, o in rooms do
				if o.comp == r.comp and o.stage >= 1 then
					o.pressure = math.min(o.pressure, cfg.WarnAt * 0.5)
					o.stage = 0
					relief = relief or j
				end
			end
		end
	end
	if relief then
		return "relief", relief
	end
	for _, i in sides do
		local r = rooms[i]
		if r and r.smoke >= cfg.VentPuffSmoke then
			return "vent", i
		end
	end
	return nil, nil
end

function SmokeSim.playerHeatRate(smoke: number, heat: number, masked: boolean, air: boolean, cfg: Cfg): number
	local s = 0
	if smoke > cfg.SmokeHurtsAt then
		s = cfg.SmokeHeatPerSecond * smoke ^ 1.5
		if masked then
			s *= if air then cfg.MaskAirFactor else cfg.MaskFactor
		end
	end
	local h = 0
	if heat > cfg.RoomHeatAt then
		h = cfg.RoomHeatPerSecond * (heat - cfg.RoomHeatAt) / (100 - cfg.RoomHeatAt)
	end
	return s + h
end

function SmokeSim.chokeDps(smoke: number, cfg: Cfg): number
	if smoke < cfg.ChokeAt then
		return 0
	end
	return cfg.ChokeDps * smoke
end

function SmokeSim.layer(smoke: number, height: number, cfg: Cfg): (number, number)
	local s = math.clamp(smoke, 0, 1)
	local depth = height * s * cfg.LayerMaxFill
	local transparency = cfg.LayerClear + (cfg.LayerThick - cfg.LayerClear) * s
	return depth, transparency
end

function SmokeSim.doorState(sa: number, sb: number, ha: number, hb: number): (number, number, number)
	local d = sa - sb
	return math.clamp(math.abs(d), 0, 1), if d >= 0 then 1 else -1, math.clamp(math.max(ha, hb) / 100, 0, 1)
end

return SmokeSim
