--!strict
-- DispatchService [owner: Dispatch]. The free-roam DISPATCH radio. Driving around the city with no call,
-- you still get work: every DispatchConfig.OfferMin..MaxSeconds an INCOMING CALL rolls in ("House fire on
-- 27 Maple St, 450 m: ACCEPT / DECLINE"), and the DISPATCH button lists what's open right now (one call per
-- mission type, "busy" when every site for it is taken). ACCEPT from anywhere: MissionService:StartMission
-- dispatches you, anyone riding in your truck (or the truck you ride in) and your free squad mates to that
-- exact site, the GPS routes you there from where you are, and the call plays like a pad launch. After the
-- results you stay where you are (free roam); BACK TO STATION (the DISPATCH panel, or the results screen)
-- drives your truck home with you in it, or walks you to the station pads.
-- Small jobs (DispatchConfig.MiniChance of the incoming calls): a bin fire on a nearby street corner
-- (Lib/Dispatch/RoamFire), no timer; everyone who sprays it out gets MiniXp.
-- Pads keep working: a player queued on a pad, in a call or in the first-fire tutorial is not "free"
-- (Lib/Dispatch/DispatchLogic.isFree), so the radio stays quiet for them; ACCEPT is refused the same way.
-- Server-authoritative: an accept must name a call this server offered that player (unexpired), is
-- rate-limited (remote + AcceptCooldown) and needs the player free; one call per player at a time.
-- Respects MissionService's site limits: calls only point at free IncidentSites (MissionService:FreeSites),
-- the exact site is re-checked on accept (taken -> "another crew took it" + a fresh list), never the
-- v1.5 instance fallback (opts.noFallback).
--
-- Public API:
--   DispatchService:GoHome(player): boolean      -- BACK TO STATION (MissionService's Lobby/BackToStation too)
--   DispatchService:IsFree(player): boolean
-- Remotes (Dispatch/*): Offer (S->C: Payload? = nil clears the card), Calls (S->C: { Payload }),
--   Open (C->S: ask for the list), Accept (C->S: id), Decline (C->S: id), Home (C->S),
--   Next (C->S: NEXT CALL! on the results screen: leave the results, take a fresh call at once)
--   Payload = { id, kind = "call"|"mini", call, address, distText, busy, seconds }
-- Player attr DispatchOffer (string id, "" = none) mirrors the card for tests.
-- Counters: dispatch_next, dispatch_offers, dispatch_accepted, dispatch_declined, dispatch_expired, dispatch_taken,
--   dispatch_lists, dispatch_mini_started, dispatch_mini_done, dispatch_home
-- Test hooks (DevHook only): _offer(player, kind?) -> id?, _accept(player, id), _decline(player, id),
--   _list(player) -> JSON, _state(player) -> JSON, _selftest()
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local ConfigDir = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigDir:WaitForChild("DispatchConfig") :: ModuleScript) :: any
local MissionCatalog = require(ConfigDir:WaitForChild("MissionCatalog") :: ModuleScript) :: { any }
local GameConfig = require(ConfigDir:WaitForChild("GameConfig") :: ModuleScript) :: any
local FirstFireConfig = require(ConfigDir:WaitForChild("FirstFireConfig") :: ModuleScript) :: any
local Lib = ServerScriptService:WaitForChild("Lib")
local DispatchLogic = require(Lib:WaitForChild("Dispatch"):WaitForChild("DispatchLogic") :: ModuleScript)
local RoamFire = require(Lib:WaitForChild("Dispatch"):WaitForChild("RoamFire") :: ModuleScript)
local MissionFlow = require(Lib:WaitForChild("Mission"):WaitForChild("MissionFlow") :: ModuleScript)

local DispatchService = {}
DispatchService.Priority = 70 -- after MissionService (60), LobbyService (55), VehicleService (50)

type Offer = {
	id: string,
	kind: "call" | "mini",
	missionId: string?,
	siteId: string?,
	call: string,
	address: string,
	dist: number,
	distText: string,
	busy: boolean,
	pos: Vector3,
	ground: CFrame?, -- mini: where the bin goes
	expiresAt: number,
}

type Mini = {
	id: string,
	model: Model,
	locationId: string,
	crew: { Player },
	helpers: { [Player]: boolean },
	label: string,
	startedAt: number,
	outAt: number?,
}

type St = {
	offer: Offer?,
	list: { [string]: Offer },
	nextAt: number,
	lastAccept: number,
	calls: number, -- calls finished this session (newbies get auto-offers after their first)
}

local services: { [string]: any } = {}
local states: { [Player]: St } = {}
local minis: { [string]: Mini } = {}
local remotes: { [string]: RemoteEvent } = {}
local rng = Random.new()
local seq = 0
local miniFolder: Folder? = nil

local STREETS = { "Maple St", "Oak Ave", "Elm St", "Birch Rd", "Cedar Ln", "Pine St", "Willow Way", "Main St", "Ash Ct", "Juniper Dr" }

local function count(name: string, n: number?)
	pcall(Telemetry.count, name, n or 1)
end

local function now(): number
	return os.clock()
end

local function roll(n: number): number
	return rng:NextInteger(1, math.max(1, n))
end

local function state(p: Player): St
	local s = states[p]
	if not s then
		s = { offer = nil, list = {}, nextAt = now() + Cfg.FirstOfferSeconds, lastAccept = -math.huge, calls = 0 }
		states[p] = s
	end
	return s :: St
end

local function call(service: string, method: string, ...: any): (boolean, any)
	local svc = services[service]
	if not svc or type(svc[method]) ~= "function" then
		return false, nil
	end
	return pcall(svc[method], svc, ...)
end

local function rootOf(p: Player): BasePart?
	local char = p.Character
	local r = char and char:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function posOf(p: Player): Vector3?
	local r = rootOf(p)
	return r and r.Position
end

-- on a lobby pad (forming / launching), not yet in the mission
local function queued(p: Player): boolean
	local ok, squads = call("LobbyService", "GetSquads")
	if not ok or type(squads) ~= "table" then
		return false
	end
	for _, s in squads do
		if s.state ~= "InMission" and type(s.members) == "table" and table.find(s.members, p.UserId) then
			return true
		end
	end
	return false
end

local function isFree(p: Player): boolean
	if p.Parent ~= Players then
		return false
	end
	local ff = p:GetAttribute("FirstFire")
	return DispatchLogic.isFree({
		instanceId = p:GetAttribute(Names.Attr.InstanceId) :: string?,
		queued = queued(p),
		tutorial = ff == "burning" or ff == "queued",
		downed = p:GetAttribute(Names.Attr.Downed) == true,
	})
end

-- incoming calls roll in on their own only for players who've had their first call (newbies get the
-- FirstFire tutorial call instead); the DISPATCH list works for everyone
-- Player attr DispatchOff = true: "unavailable", no incoming calls (the DISPATCH list still works)
local function wantsAuto(p: Player, st: St): boolean
	return Cfg.Enabled == true and p:GetAttribute("DispatchOff") ~= true and (p:GetAttribute("Onboarded") == true or st.calls > 0)
end

local function streetOf(pos: Vector3): string
	local h = (math.floor(pos.X / 40) * 73856093 + math.floor(pos.Z / 40) * 19349663) % 1000003
	h = math.abs(h)
	return STREETS[h % #STREETS + 1]
end

local function payload(o: Offer): { [string]: any }
	return {
		id = o.id,
		kind = o.kind,
		call = o.call,
		address = o.address,
		distText = o.distText,
		busy = o.busy,
		seconds = math.max(0, math.floor(o.expiresAt - now())),
	}
end

local function newId(): string
	seq += 1
	return `D{seq}`
end

local function opts(): any
	return { near = Cfg.NearStuds, far = Cfg.FarStuds, exclude = Cfg.Exclude, size = Cfg.ListSize }
end

local function freeSites(): { any }
	local ok, list = call("MissionService", "FreeSites")
	return if ok and type(list) == "table" then list else {}
end

local function offerOf(c: any, origin: Vector3, ttl: number): Offer
	local site = c.site
	return {
		id = newId(),
		kind = "call",
		missionId = c.missionId,
		siteId = site and site.siteId,
		call = c.call,
		address = if site then site.address else "",
		dist = c.dist,
		distText = if site then DispatchLogic.meters(c.dist, Cfg.MetersPerStud) else "",
		busy = c.busy,
		pos = if site then site.pos else origin,
		ground = nil,
		expiresAt = now() + ttl,
	}
end

---------------------------------------------------------------------------- small jobs (bin fires)

local roadCache: { key: string, nodes: { Vector3 }, heads: { Vector3 } } = { key = "", nodes = {}, heads = {} }
local function roadNodes(): ({ Vector3 }, { Vector3 })
	local map = workspace:FindFirstChild("Map")
	local city = map and map:FindFirstChild("City")
	local js = city and city:FindFirstChild("RoadGraphJson")
	if not (js and js:IsA("StringValue") and js.Value ~= "") then
		return {}, {}
	end
	local key = `{#js.Value}:{string.sub(js.Value, 1, 32)}`
	if key == roadCache.key then
		return roadCache.nodes, roadCache.heads
	end
	local ok, data = pcall(HttpService.JSONDecode, HttpService, js.Value)
	local pos: { [string]: Vector3 } = {}
	local nbr: { [string]: string } = {}
	if ok and type(data) == "table" and type(data.nodes) == "table" then
		for id, v in data.nodes do
			if type(v) == "table" then
				local x = tonumber(v[1] or v.x or v.X)
				local y = tonumber(v[2] or v.y or v.Y) or 0
				local z = tonumber(v[3] or v.z or v.Z)
				if x and z then
					pos[tostring(id)] = Vector3.new(x, y, z)
				end
			end
		end
		for _, e in (if type(data.edges) == "table" then data.edges else {}) do
			if type(e) == "table" then
				local a, b = tostring(e.a or e[1]), tostring(e.b or e[2])
				nbr[a] = nbr[a] or b
				nbr[b] = nbr[b] or a
			end
		end
	end
	local nodes, heads = {}, {}
	for id, p in pos do
		local other = nbr[id] and pos[nbr[id]]
		table.insert(nodes, p)
		table.insert(heads, if other and (other - p).Magnitude > 0.1 then other - p else Vector3.new(0, 0, -1))
	end
	roadCache = { key = key, nodes = nodes, heads = heads }
	return nodes, heads
end

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.RespectCanCollide = true

-- ground under cf, and nothing solid in a bin-sized box there (walls, cars, props)
local function clearSpot(cf: CFrame): CFrame?
	local ignore: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(cf.Position + Vector3.new(0, 30, 0), Vector3.new(0, -80, 0), rp)
	if not hit or hit.Normal.Y < 0.8 then
		return nil
	end
	local ground = CFrame.lookAt(hit.Position, hit.Position + cf.LookVector * Vector3.new(1, 0, 1))
	overlap.FilterDescendantsInstances = ignore
	local parts = workspace:GetPartBoundsInBox(ground * CFrame.new(0, 3.5, 0), Vector3.new(9, 5, 9), overlap)
	for _, p in parts do
		if p.CanCollide and p.Transparency < 0.95 then
			return nil
		end
	end
	return ground
end

local function miniOffer(p: Player, origin: Vector3): Offer?
	local nodes, heads = roadNodes()
	if #nodes == 0 then
		return nil
	end
	local ground = RoamFire.findSpot(nodes, heads, origin, Cfg.MiniMinStuds, Cfg.MiniMaxStuds, clearSpot, roll)
	if not ground then
		return nil
	end
	local names = Cfg.MiniCalls :: { string }
	local d = Vector3.new(ground.X - origin.X, 0, ground.Z - origin.Z).Magnitude
	return {
		id = newId(),
		kind = "mini",
		missionId = nil,
		siteId = nil,
		call = names[roll(#names)],
		address = streetOf(ground.Position),
		dist = d,
		distText = DispatchLogic.meters(d, Cfg.MetersPerStud),
		busy = false,
		pos = ground.Position,
		ground = ground,
		expiresAt = now() + Cfg.OfferSeconds,
	}
end

local function clearMini(m: Mini, delaySeconds: number)
	minis[m.id] = nil
	task.delay(delaySeconds, function()
		call("FireService", "ClearInstance", m.locationId)
		call("FireService", "ExtinguishAll", m.locationId)
		if m.model.Parent then
			m.model:Destroy()
		end
	end)
	for _, p in m.crew do
		if p.Parent == Players then
			local ok, _, label = call("NavigationService", "GetWaypoint", p)
			if ok and label == m.label then
				call("NavigationService", "ClearWaypoint", p)
			end
		end
	end
end

local function miniOf(p: Player): Mini?
	for _, m in minis do
		if table.find(m.crew, p) then
			return m
		end
	end
	return nil
end

local function startMini(o: Offer, crew: { Player }): boolean
	local ground = o.ground
	if not ground then
		return false
	end
	if not miniFolder or not miniFolder.Parent then
		local f = Instance.new("Folder")
		f.Name = "RoamFires"
		f.Parent = workspace
		miniFolder = f
	end
	local model = RoamFire.build(ground, Cfg.MiniFuel)
	model.Name = `RoamFire_{o.id}`
	model.Parent = miniFolder
	local loc = `roam:{o.id}`
	call("FireService", "IndexLocation", model, loc)
	local lit = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and CollectionService:HasTag(d, Names.Tag.Flammable) then
			local ok, res = call("FireService", "Ignite", d, nil)
			if ok and res == true then
				lit += 1
			end
		end
	end
	if lit == 0 then
		model:Destroy()
		return false
	end
	local label = `{o.call} on {o.address}`
	local m: Mini = {
		id = o.id,
		model = model,
		locationId = loc,
		crew = crew,
		helpers = {},
		label = label,
		startedAt = now(),
		outAt = nil,
	}
	minis[o.id] = m
	call("NavigationService", "SetWaypoint", crew, model, label)
	for _, p in crew do
		Net.notify(p, `{label}: put it out for +{Cfg.MiniXp} XP!`, "info")
	end
	count("dispatch_mini_started")
	return true
end

local function miniTick(t: number)
	for _, m in minis do
		if not m.model.Parent then
			clearMini(m, 0)
			continue
		end
		local ok, burning = call("FireService", "CountBurning", m.locationId)
		local lit = if ok and type(burning) == "number" then burning else 0
		if lit == 0 then
			local any = false
			for p in m.helpers do
				if p.Parent == Players then
					any = true
					local okXp, gave = call("DataService", "AddXp", p, Cfg.MiniXp, "Dispatch")
					local xp = if okXp and type(gave) == "number" then gave else Cfg.MiniXp
					Popup.show(p, `{m.label}: OUT! +{xp} XP`, "good", p)
				end
			end
			if any then
				count("dispatch_mini_done")
			end
			clearMini(m, 6)
		elseif t - m.startedAt > Cfg.MiniSeconds then
			for _, p in m.crew do
				if p.Parent == Players then
					Net.notify(p, `{m.label} burned itself out.`, "info")
				end
			end
			clearMini(m, 0)
		end
	end
end

---------------------------------------------------------------------------- crews

local function truckOfSeat(p: Player): Model?
	local char = p.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	local m = seat and seat:FindFirstAncestorWhichIsA("Model")
	while m and not m:HasTag(Names.Tag.Truck) do
		m = m:FindFirstAncestorWhichIsA("Model")
	end
	return m
end

local function riders(truck: Model?): { Player }
	local out: { Player } = {}
	if not truck then
		return out
	end
	for _, d in truck:GetDescendants() do
		if d:IsA("Seat") or d:IsA("VehicleSeat") then
			local occ = (d :: Seat).Occupant
			local p = occ and Players:GetPlayerFromCharacter(occ.Parent)
			if p then
				table.insert(out, p)
			end
		end
	end
	return out
end

-- who rolls out with `p`: p, everyone in p's truck or the truck p rides in, and p's free squad mates
local function crewOf(p: Player): { Player }
	local out: { Player } = { p }
	local function add(q: Player)
		if not table.find(out, q) and isFree(q) then
			table.insert(out, q)
		end
	end
	local ok, own = call("VehicleService", "GetTruck", p)
	for _, q in riders(if ok and typeof(own) == "Instance" then own :: Model else nil) do
		add(q)
	end
	for _, q in riders(truckOfSeat(p)) do
		add(q)
	end
	local sid = p:GetAttribute(Names.Attr.SquadId)
	if type(sid) == "string" and sid ~= "" then
		for _, q in Players:GetPlayers() do
			if q:GetAttribute(Names.Attr.SquadId) == sid then
				add(q)
			end
		end
	end
	return out
end

---------------------------------------------------------------------------- offers

local function send(p: Player, o: Offer?)
	p:SetAttribute("DispatchOffer", if o then o.id else "")
	local r = remotes.Offer
	if r then
		r:FireClient(p, if o then payload(o) else nil)
	end
end

local function clearOffer(p: Player, st: St, reschedule: boolean)
	if st.offer then
		st.offer = nil
		send(p, nil)
	end
	if reschedule then
		st.nextAt = now() + DispatchLogic.delay(Cfg.OfferMinSeconds, Cfg.OfferMaxSeconds, rng:NextNumber())
	end
end

local function makeOffer(p: Player, kind: string?): Offer?
	local origin = posOf(p)
	if not origin then
		return nil
	end
	local o: Offer? = nil
	if kind == "mini" or (kind == nil and rng:NextNumber() < Cfg.MiniChance) then
		o = miniOffer(p, origin)
	end
	if not o and kind ~= "mini" then
		local c = DispatchLogic.offer(freeSites(), MissionCatalog :: any, origin, opts(), MissionFlow.siteSupports, roll)
		if c then
			o = offerOf(c, origin, Cfg.OfferSeconds)
		end
	end
	return o
end

local function sendList(p: Player)
	local st = state(p)
	local origin = posOf(p) or Vector3.zero
	table.clear(st.list)
	local out = {}
	local calls = DispatchLogic.list(freeSites(), MissionCatalog :: any, origin, opts(), MissionFlow.siteSupports, roll)
	for _, c in calls do
		local o = offerOf(c, origin, Cfg.ListSeconds)
		if not o.busy then
			st.list[o.id] = o
		end
		table.insert(out, payload(o))
	end
	-- a small job at the end, when there's a spot for one
	if not miniOf(p) then
		local m = miniOffer(p, origin)
		if m then
			m.expiresAt = now() + Cfg.ListSeconds
			st.list[m.id] = m
			table.insert(out, payload(m))
		end
	end
	local r = remotes.Calls
	if r then
		r:FireClient(p, out)
	end
	count("dispatch_lists")
end

local function accept(p: Player, id: any): boolean
	if type(id) ~= "string" or #id > 16 then
		return false
	end
	local st = state(p)
	local o = if st.offer and st.offer.id == id then st.offer else st.list[id]
	if not o or o.expiresAt < now() then
		Net.notify(p, "That call's gone cold. Open DISPATCH for what's on now.", "info")
		clearOffer(p, st, false)
		return false
	end
	if now() - st.lastAccept < Cfg.AcceptCooldown then
		return false
	end
	if not isFree(p) then
		Net.notify(p, "Finish your current call first!", "bad")
		return false
	end
	st.lastAccept = now()
	if o.kind == "mini" then
		local cur = miniOf(p)
		if cur then
			Net.notify(p, `Finish the {cur.label} first!`, "bad")
			return false
		end
		local crew = crewOf(p)
		clearOffer(p, st, true)
		st.list[o.id] = nil
		if not startMini(o, crew) then
			Net.notify(p, "False alarm: that fire's already out.", "info")
			return false
		end
		count("dispatch_accepted")
		return true
	end
	local crew = crewOf(p)
	local origin = posOf(p)
	local ok, runId = call("MissionService", "StartMission", crew, o.missionId, nil, {
		siteId = o.siteId,
		origin = origin,
		noFallback = true,
	})
	if not ok or type(runId) ~= "string" or runId == "" then
		count("dispatch_taken")
		Net.notify(p, "Another crew took that call! Here's what's open:", "info")
		clearOffer(p, st, false)
		sendList(p)
		return false
	end
	for _, q in crew do
		local qs = state(q)
		table.clear(qs.list)
		clearOffer(q, qs, false)
		local m = miniOf(q)
		if m then
			clearMini(m, 0)
		end
		if q ~= p then
			Net.notify(q, `{p.DisplayName} took the call: {o.call} on {o.address}. Roll out!`, "info")
		end
	end
	count("dispatch_accepted")
	print(`[DispatchService] {p.Name} accepted {o.missionId} at {o.siteId} ({#crew} player(s)) -> {runId}`)
	return true
end

-- NEXT CALL! (the results screen): straight into a fresh call from where you are. Steps you out of the
-- finished run's results (MissionService:LeaveResults), picks a real call (never a bin fire) and accepts
-- it for you: one tap from MISSION COMPLETE to driving again. Nothing free: the DISPATCH list instead.
local function nextCall(p: Player): boolean
	local runBefore = p:GetAttribute(Names.Attr.InstanceId)
	local okLeave, left = call("MissionService", "LeaveResults", p)
	if okLeave and left == false then
		Net.notify(p, "Finish your current call first!", "bad")
		return false
	end
	-- keep the squad together (the results' NEXT CALL IN 5 fires on every member's screen at once): squad
	-- mates still on the same finished call's results come along, unless they picked STAY AT STATION
	-- (Player attr ResultsStay, ResultsFlowService)
	local sid = p:GetAttribute(Names.Attr.SquadId)
	if type(runBefore) == "string" and runBefore ~= "" and type(sid) == "string" and sid ~= "" then
		for _, q in Players:GetPlayers() do
			if q ~= p and q:GetAttribute(Names.Attr.SquadId) == sid and q:GetAttribute(Names.Attr.InstanceId) == runBefore
				and q:GetAttribute("ResultsStay") ~= true then
				call("MissionService", "LeaveResults", q)
			end
		end
	end
	if not isFree(p) then
		return false
	end
	local st = state(p)
	clearOffer(p, st, false)
	local o: Offer? = nil
	-- still a rookie (GameConfig.Rookie.Calls): the plain house fire again, not a gas leak or a dam
	local rookieCfg = GameConfig.Rookie
	local okProfile, profile = call("DataService", "GetProfile", p)
	local played = if okProfile and type(profile) == "table" then (tonumber(profile.missionsPlayed) or 0) else 0
	if type(rookieCfg) == "table" and played < (tonumber(rookieCfg.Calls) or 0) then
		local origin = posOf(p)
		local plain = {}
		for _, def in MissionCatalog do
			if def.id == FirstFireConfig.FirstCall then
				table.insert(plain, def)
			end
		end
		local c = if origin and #plain > 0
			then DispatchLogic.offer(freeSites(), plain :: any, origin, opts(), MissionFlow.siteSupports, roll)
			else nil
		if c and origin then
			o = offerOf(c, origin, Cfg.OfferSeconds)
		end
	end
	o = o or makeOffer(p, "call")
	if not o then
		Net.notify(p, "Quiet right now... here's what's open:", "info")
		sendList(p)
		return false
	end
	st.offer = o
	st.lastAccept = 0 -- the tap IS the accept
	count("dispatch_next")
	if accept(p, o.id) then
		return true
	end
	return false
end

local function decline(p: Player, id: any)
	local st = state(p)
	if st.offer and st.offer.id == id then
		clearOffer(p, st, true)
		count("dispatch_declined")
	end
end

local function tick()
	local t = now()
	for _, p in Players:GetPlayers() do
		local st = state(p)
		local free = isFree(p)
		local o = st.offer
		if o and (not free or o.expiresAt < t) then
			if free then
				count("dispatch_expired")
			end
			clearOffer(p, st, true)
		elseif not o and free and wantsAuto(p, st) and t >= st.nextAt and not miniOf(p) then
			local made = makeOffer(p, nil)
			if made then
				st.offer = made
				send(p, made)
				count("dispatch_offers")
			else
				st.nextAt = t + 15 -- nothing free right now: try again soon
			end
		end
	end
	miniTick(t)
end

---------------------------------------------------------------------------- back to station

function DispatchService:IsFree(player: Player): boolean
	return isFree(player)
end

function DispatchService:GoHome(player: Player): boolean
	local id = player:GetAttribute(Names.Attr.InstanceId)
	if type(id) == "string" and id ~= "" then
		local ok, run = call("MissionService", "GetMission", id)
		local st = ok and type(run) == "table" and run.state
		if st ~= "Results" and st ~= "Done" then
			Net.notify(player, "Finish the call first!", "bad")
			return false
		end
	end
	local m = miniOf(player)
	if m then
		clearMini(m, 0)
	end
	count("dispatch_home")
	local okT, truck = call("VehicleService", "GetTruck", player)
	local own = if okT and typeof(truck) == "Instance" then truck :: Model else nil
	local seat = own and own:FindFirstChild("DriveSeat")
	local driving = seat and seat:IsA("VehicleSeat") and seat.Occupant ~= nil and seat.Occupant.Parent == player.Character
	if driving then
		-- you and whoever rides with you, home in the truck
		call("VehicleService", "ParkAt", player)
		Net.notify(player, "Back at the station!", "good")
		return true
	end
	-- on foot (or riding someone else's truck): out of the seat, onto the station pads
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum and hum.SeatPart then
		local w = hum.SeatPart:FindFirstChild("SeatWeld")
		if w then
			w:Destroy()
		end
		hum.Sit = false
		task.wait()
	end
	call("LobbyService", "ReturnToLobby", { player })
	-- an empty truck left out in the city comes home too
	if own and #riders(own) == 0 then
		call("VehicleService", "ParkAt", player)
	end
	return true
end

---------------------------------------------------------------------------- lifecycle

function DispatchService:Init(all: { [string]: any })
	services = all
end

function DispatchService:Start()
	remotes.Offer = Net.event("Dispatch", "Offer")
	remotes.Calls = Net.event("Dispatch", "Calls")
	Net.onServer(Net.event("Dispatch", "Open"), { rate = 1, burst = 2 }, function(p: Player)
		if Cfg.Enabled then
			sendList(p)
		end
	end)
	Net.onServer(Net.event("Dispatch", "Accept"), { rate = 1, burst = 2 }, function(p: Player, id: any)
		accept(p, id)
	end)
	Net.onServer(Net.event("Dispatch", "Decline"), { rate = 2, burst = 2 }, function(p: Player, id: any)
		decline(p, id)
	end)
	Net.onServer(Net.event("Dispatch", "Next"), { rate = 0.5, burst = 1 }, function(p: Player)
		if Cfg.Enabled then
			nextCall(p)
		end
	end)
	Net.onServer(Net.event("Dispatch", "Home"), { rate = 0.5, burst = 1 }, function(p: Player)
		DispatchService:GoHome(p)
	end)
	-- available / unavailable for incoming calls
	Net.onServer(Net.event("Dispatch", "Available"), { rate = 1, burst = 3 }, function(p: Player, on: any)
		if type(on) ~= "boolean" then
			return
		end
		p:SetAttribute("DispatchOff", not on)
		local st = state(p)
		if not on and st.offer then
			clearOffer(p, st, true)
		elseif on then
			st.nextAt = math.min(st.nextAt, now() + 10)
		end
	end)

	local Fire = services.FireService
	if Fire and Fire.Extinguished then
		Fire.Extinguished:Connect(function(part: BasePart, by: Player?)
			if not by then
				return
			end
			for _, m in minis do
				if part:IsDescendantOf(m.model) then
					m.helpers[by] = true
					return
				end
			end
		end)
	end
	local Mission = services.MissionService
	if Mission and Mission.MissionEnded then
		Mission.MissionEnded:Connect(function(instanceId: string, _results: any)
			for _, p in Players:GetPlayers() do
				if p:GetAttribute(Names.Attr.InstanceId) == instanceId then
					local st = state(p)
					st.calls += 1
					-- results screen first, then the radio comes back to life
					st.nextAt = now() + Cfg.FirstOfferSeconds + 15
				end
			end
		end)
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		states[p] = nil
		for _, m in minis do
			local i = table.find(m.crew, p)
			if i then
				table.remove(m.crew, i)
				if #m.crew == 0 then
					clearMini(m, 0)
				end
			end
			m.helpers[p] = nil
		end
	end)
	for _, p in Players:GetPlayers() do
		state(p)
	end
	Players.PlayerAdded:Connect(function(p: Player)
		state(p)
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(tick)
			if not ok then
				warn(`[DispatchService] tick: {err}`)
			end
		end
	end)
end

---------------------------------------------------------------------------- test hooks

function DispatchService:_offer(player: Player, kind: string?): string?
	local st = state(player)
	clearOffer(player, st, false)
	local o = makeOffer(player, kind)
	if o then
		st.offer = o
		send(player, o)
		count("dispatch_offers")
		return o.id
	end
	return nil
end

function DispatchService:_accept(player: Player, id: string): boolean
	state(player).lastAccept = -math.huge
	return accept(player, id)
end

function DispatchService:_decline(player: Player, id: string)
	decline(player, id)
end

function DispatchService:_list(player: Player): string
	sendList(player)
	local out = {}
	for id, o in state(player).list do
		table.insert(out, { id = id, kind = o.kind, call = o.call, missionId = o.missionId, siteId = o.siteId, distText = o.distText })
	end
	return HttpService:JSONEncode(out)
end

function DispatchService:_state(player: Player): string
	local st = state(player)
	local m = miniOf(player)
	return HttpService:JSONEncode({
		free = isFree(player),
		offer = if st.offer then payload(st.offer) else nil,
		nextIn = math.floor(st.nextAt - now()),
		calls = st.calls,
		mini = if m then { id = m.id, label = m.label } else nil,
	})
end

function DispatchService:_selftest(): (boolean, string)
	if not remotes.Offer then
		return false, "remotes not created"
	end
	return true, `{#freeSites()} free site(s), {#Players:GetPlayers()} player(s)`
end

return DispatchService
