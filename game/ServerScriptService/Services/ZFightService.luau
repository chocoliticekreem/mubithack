--!strict
-- ZFightService. Kills z-fighting (flickering ground / trim) across the whole map. The builders lay
-- lots of faces on exactly the same plane: road tops level with the station lawn, garden paths level
-- with the training yard, sidewalks with walks, window sills flush with walls, gate trims flush with
-- their pillars. Two different-looking faces on one plane flicker as the camera moves.
-- Once the map is built (MapReady) this walks every anchored, axis-aligned part in Workspace.Map,
-- finds same-facing faces that share a plane and overlap, and pushes the SMALLER part's face out by
-- NUDGE studs (its far face stays put), so the small one always draws on top. Runs once (a few passes); nothing
-- else to call. Test hooks: _scan() -> number of coplanar pairs left, _fixed() -> parts nudged.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript) :: any

local ZFightService = {}
ZFightService.Priority = 90

local NUDGE = 0.03 -- studs: invisible to players, enough for the depth buffer
local PLANE_EPS = 0.012 -- faces closer than this count as the same plane
local MIN_OVERLAP = 0.05 -- studs of overlap on both in-plane axes before it can flicker
local MIN_FACE = 0.5 -- faces smaller than this (studs^2) never read as flicker
local MAX_PASSES = 8
local SKIP_MODELS = { StreetLamp = true } -- these restore their own CFrames

type Face = {
	part: BasePart,
	axis: number, -- 1 X, 2 Y, 3 Z (world)
	sign: number, -- +1 / -1: which way the face points
	plane: number,
	lo: Vector3,
	hi: Vector3,
	area: number,
	localAxis: Vector3, -- unit local axis of the part that maps to this world axis
}

local fixedCount = 0

local function axisAligned(cf: CFrame): boolean
	local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
	for _, v in { r, u, l } do
		local m = math.max(math.abs(v.X), math.abs(v.Y), math.abs(v.Z))
		if m < 0.9995 then
			return false
		end
	end
	return true
end

local function comp(v: Vector3, i: number): number
	return if i == 1 then v.X elseif i == 2 then v.Y else v.Z
end

local WORLD = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }

local function skip(p: BasePart): boolean
	if not p.Anchored or p.Transparency >= 0.95 or p:IsA("Terrain") then
		return true
	end
	local m = p:FindFirstAncestorOfClass("Model")
	while m do
		if SKIP_MODELS[m.Name] or m:HasTag(Names.Tag.Truck or "Truck") then
			return true
		end
		m = m:FindFirstAncestorOfClass("Model")
	end
	return false
end

-- the 6 faces of an axis-aligned part, in world space
local function faces(p: BasePart, out: { Face })
	local cf, size = p.CFrame, p.Size
	local locals = { cf.RightVector, cf.UpVector, -cf.LookVector }
	local sizes = { size.X, size.Y, size.Z }
	local half = Vector3.zero
	local map: { [number]: number } = {} -- world axis -> local index
	for li = 1, 3 do
		local v = locals[li]
		local wi = if math.abs(v.X) > 0.9 then 1 elseif math.abs(v.Y) > 0.9 then 2 else 3
		map[wi] = li
	end
	half = Vector3.new(sizes[map[1]] / 2, sizes[map[2]] / 2, sizes[map[3]] / 2)
	local lo, hi = p.Position - half, p.Position + half
	for wi = 1, 3 do
		local a, b = (wi % 3) + 1, ((wi + 1) % 3) + 1
		local area = (comp(hi, a) - comp(lo, a)) * (comp(hi, b) - comp(lo, b))
		if area >= MIN_FACE then
			local la = locals[map[wi]]
			local laUnit = if comp(la, wi) > 0 then la else -la -- local axis pointing along +world axis
			table.insert(out, { part = p, axis = wi, sign = 1, plane = comp(hi, wi), lo = lo, hi = hi, area = area, localAxis = laUnit })
			table.insert(out, { part = p, axis = wi, sign = -1, plane = comp(lo, wi), lo = lo, hi = hi, area = area, localAxis = laUnit })
		end
	end
end

local function overlaps(f: Face, g: Face): boolean
	local a, b = (f.axis % 3) + 1, ((f.axis + 1) % 3) + 1
	return comp(f.lo, a) < comp(g.hi, a) - MIN_OVERLAP
		and comp(g.lo, a) < comp(f.hi, a) - MIN_OVERLAP
		and comp(f.lo, b) < comp(g.hi, b) - MIN_OVERLAP
		and comp(g.lo, b) < comp(f.hi, b) - MIN_OVERLAP
end

local function looksDifferent(a: BasePart, b: BasePart): boolean
	return a.Color ~= b.Color or a.Material ~= b.Material or a.Transparency ~= b.Transparency
end

-- every same-facing coplanar overlapping pair, as { small, big } faces
local function findPairs(root: Instance): { { Face } }
	local all: { Face } = {}
	local n = 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and not skip(d) and axisAligned(d.CFrame) then
			faces(d, all)
		end
		n += 1
		if n % 4000 == 0 then
			task.wait()
		end
	end
	-- bucket by (axis, sign, rounded plane); compare within a bucket and its neighbour
	local buckets: { [string]: { Face } } = {}
	local function key(f: Face, k: number): string
		return `{f.axis}{f.sign}:{k}`
	end
	for _, f in all do
		local k = math.floor(f.plane / PLANE_EPS + 0.5)
		local id = key(f, k)
		local list = buckets[id]
		if not list then
			list = {}
			buckets[id] = list
		end
		table.insert(list, f)
	end
	local found: { { Face } } = {}
	local seen: { [BasePart]: { [BasePart]: boolean } } = {}
	local checks = 0
	for id, list in buckets do
		local axisSign, kStr = string.match(id, "^(.-):(.-)$")
		local nextList = buckets[`{axisSign}:{(tonumber(kStr) :: number) + 1}`] or {}
		local pool = table.clone(list)
		for _, f in nextList do
			table.insert(pool, f)
		end
		for i = 1, #list do
			local f = list[i]
			for j = i + 1, #pool do
				local g = pool[j]
				if f.part ~= g.part and math.abs(f.plane - g.plane) < PLANE_EPS and overlaps(f, g) and looksDifferent(f.part, g.part) then
					local s = seen[f.part]
					if not (s and s[g.part]) then
						seen[f.part] = seen[f.part] or {}
						seen[f.part][g.part] = true
						table.insert(found, if f.area <= g.area then { f, g } else { g, f })
					end
				end
				checks += 1
				if checks % 20000 == 0 then
					task.wait()
				end
			end
		end
	end
	return found
end

-- grow the part by NUDGE through face f, keeping the opposite face where it was
local function nudge(f: Face)
	local p = f.part
	local la = f.localAxis
	local cf = p.CFrame
	local lx, ly = math.abs(cf.RightVector:Dot(la)), math.abs(cf.UpVector:Dot(la))
	local add = if lx > 0.9 then Vector3.new(NUDGE, 0, 0) elseif ly > 0.9 then Vector3.new(0, NUDGE, 0) else Vector3.new(0, 0, NUDGE)
	p.Size += add
	p.CFrame = cf + WORLD[f.axis] * (f.sign * NUDGE / 2)
end

local function run()
	local map = workspace:FindFirstChild("Map")
	if not map then
		return
	end
	-- three faces on one plane need more than one pass (the nudged one can land on the next), so
	-- repeat until it's clean; each pass only moves one face per part per direction
	for _ = 1, MAX_PASSES do
		local list = findPairs(map)
		if #list == 0 then
			break
		end
		local nudged: { [BasePart]: { [string]: boolean } } = {}
		for _, pair in list do
			local small = pair[1]
			local tag = `{small.axis}{small.sign}`
			local done = nudged[small.part]
			if not (done and done[tag]) then
				nudged[small.part] = done or {}
				nudged[small.part][tag] = true
				nudge(small)
				fixedCount += 1
			end
		end
	end
	local Tel = ReplicatedStorage:FindFirstChild("ForgeTelemetry")
	if Tel then
		pcall(function()
			(require(Tel :: ModuleScript) :: any).count("zfight_nudged", fixedCount)
		end)
	end
end

function ZFightService:Init(_all: { [string]: any }) end

function ZFightService:Start()
	task.spawn(function()
		while workspace:GetAttribute(Names.Attr.MapReady or "MapReady") ~= true do
			task.wait(0.5)
		end
		task.wait(2) -- let late props (lamps, signs) land first
		local ok, err = pcall(run)
		if not ok then
			warn(`[ZFightService] {err}`)
		end
	end)
end

function ZFightService:_scan(): number
	local map = workspace:FindFirstChild("Map")
	return if map then #findPairs(map) else 0
end

function ZFightService:_fixed(): number
	return fixedCount
end

return ZFightService
