"""ObbyThemes (forge/kit/modules/ObbyThemes.luau) in the headless engine (forge/headless.py).

What every test checks with its own geometry (CHECKER below, not the module's): the body space over a walkable top
(footprint + 0.5, from 0.12 to 7 studs over it, over a mover's whole path) holds no decoration; nothing that reads as
floor lies within 0.7 under a top and reaches more than 0.5 past its edge; decorations on moving parts are welded to
them and the rest anchored; kill parts glow in a colour far from every walkable and pad; legs reach the ground.
Cases: every theme x every kind, sample stages, the real Funfair Frenzy levels (tests/fixtures/funfair_levels.json)
built on turned stages in ObbyKit v2's order, the v2 platform shapes (log, ramp), and ground for legs.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

from forge import checks, director
from forge.config import load_settings

KIT_DIR = director.KIT_MODULES_DIR
LUAU = shutil.which("luau-compile")
FIXTURE = Path(__file__).parent / "fixtures" / "funfair_levels.json"
needs_headless = pytest.mark.skipif(not checks.headless_available(), reason="luau CLI not on PATH")
THEMES = ["entrance", "carousel", "bumper", "teacups", "ferris", "flume", "haunted", "pirate", "coaster", "finale"]


def _game(tmp_path: Path) -> Path:
    root = tmp_path / "game"
    (root / "ReplicatedStorage/Kit").mkdir(parents=True)
    for name in ("ObbyKit", "ObbyThemes"):
        shutil.copy(KIT_DIR / f"{name}.luau", root / f"ReplicatedStorage/Kit/{name}.luau")
    shutil.copy(load_settings().base_game_dir / "ReplicatedStorage/ForgeTelemetry.luau",
                root / "ReplicatedStorage/ForgeTelemetry.luau")
    return root


def _offline(root: Path, body: str) -> dict:
    res = checks.run_check_offline(root, checks.Check(id="t", title="t", covers="", body=CHECKER + body), timeout=300)
    assert res.get("ok"), res
    return json.loads(res["detail"])


# The test's own geometry. A walkable's body space is an oriented box (a disc's a vertical cylinder); a decoration's
# host is found through its welds; a moving decoration is tried at every place it reaches.
CHECKER = r"""
local CS = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local K = require(game.ReplicatedStorage.Kit.ObbyKit)
local T = require(game.ReplicatedStorage.Kit.ObbyThemes)
local CLEAR, MARGIN, FLUSH = 7, 0.5, 0.12
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

local function restCF(p)
	local r = p:GetAttribute("Rest")
	return if typeof(r) == "CFrame" then r else p.CFrame
end

local function surface(p)
	local cf, s = restCF(p), p.Size
	if p:GetAttribute("Shape") == "cylinder" then
		return cf * CFrame.new(0, s.Y / 2, 0), s.X, s.Y, "log", 0
	elseif p:IsA("WedgePart") then
		return cf * CFrame.Angles(0, math.pi, 0) * CFrame.new(0, s.Y / 2, 0), s.X, s.Z, "ramp", s.Y
	elseif p:IsA("Part") and p.Shape == Enum.PartType.Cylinder then
		return cf * UPRIGHT:Inverse() * CFrame.new(0, s.X / 2, 0), s.Y, s.Y, "disc", 0
	end
	return cf * CFrame.new(0, s.Y / 2, 0), s.X, s.Z, "block", 0
end

local function column(p, piece)
	local top, w, l, kind, rise = surface(p)
	local frame, len = top, l
	if kind == "ramp" then
		frame = top * CFrame.new(0, -rise / 2, 0) * CFrame.Angles(math.atan2(rise, l), 0, 0)
		len = math.sqrt(l * l + rise * rise)
	end
	local c = { part = p, piece = piece, kind = kind, frame = frame, w = w, len = len,
		cf = frame * CFrame.new(0, (CLEAR + FLUSH) / 2, 0), half = Vector3.new(w / 2 + MARGIN, (CLEAR - FLUSH) / 2, len / 2 + MARGIN) }
	if kind == "disc" then
		c.r = w / 2 + MARGIN
	end
	local mv = p:GetAttribute("Move")
	if typeof(mv) == "Vector3" then
		c.move = restCF(p):VectorToWorldSpace(Vector3.new(mv.X, mv.Y, -mv.Z))
	end
	return c
end

local function columnsIn(root)
	local cols = {}
	for _, p in root:GetDescendants() do
		if p:IsA("BasePart") and CS:HasTag(p, "ObbyStandable") then
			table.insert(cols, column(p, p.Parent))
		end
	end
	return cols
end

-- Do two oriented boxes overlap by more than a hair? (separating axes)
local function sat(acf, ah, bcf, bh)
	local ax, ay, az, a00, a01, a02, a10, a11, a12, a20, a21, a22 = acf:GetComponents()
	local bx, by, bz, b00, b01, b02, b10, b11, b12, b20, b21, b22 = bcf:GetComponents()
	local A = { { a00, a10, a20 }, { a01, a11, a21 }, { a02, a12, a22 } }
	local B = { { b00, b10, b20 }, { b01, b11, b21 }, { b02, b12, b22 } }
	local ea, eb = { ah.X, ah.Y, ah.Z }, { bh.X, bh.Y, bh.Z }
	local tx, ty, tz = bx - ax, by - ay, bz - az
	local function sep(nx, ny, nz)
		local len = math.sqrt(nx * nx + ny * ny + nz * nz)
		if len < 1e-6 then
			return false
		end
		nx, ny, nz = nx / len, ny / len, nz / len
		local ra, rb = 0, 0
		for i = 1, 3 do
			local a, b = A[i], B[i]
			ra += ea[i] * math.abs(a[1] * nx + a[2] * ny + a[3] * nz)
			rb += eb[i] * math.abs(b[1] * nx + b[2] * ny + b[3] * nz)
		end
		return math.abs(tx * nx + ty * ny + tz * nz) >= ra + rb - 1e-3
	end
	for i = 1, 3 do
		if sep(A[i][1], A[i][2], A[i][3]) or sep(B[i][1], B[i][2], B[i][3]) then
			return false
		end
	end
	for i = 1, 3 do
		for j = 1, 3 do
			local a, b = A[i], B[j]
			if sep(a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1]) then
				return false
			end
		end
	end
	return true
end

-- Distance from the origin to the convex hull of 2D points (0 when inside).
local function hullDistance(pts)
	table.sort(pts, function(a, b)
		return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
	end)
	local function cross(o, a, b)
		return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])
	end
	local hull = {}
	for _, pass in { 1, -1 } do
		local chain = {}
		local first, last = if pass == 1 then 1 else #pts, if pass == 1 then #pts else 1
		for i = first, last, pass do
			while #chain >= 2 and cross(chain[#chain - 1], chain[#chain], pts[i]) <= 0 do
				table.remove(chain)
			end
			table.insert(chain, pts[i])
		end
		table.remove(chain)
		for _, p in chain do
			table.insert(hull, p)
		end
	end
	local inside, best = #hull >= 3, math.huge
	for i = 1, #hull do
		local a, b = hull[i], hull[i % #hull + 1]
		local dx, dy = b[1] - a[1], b[2] - a[2]
		local dd = dx * dx + dy * dy
		local t = if dd > 1e-12 then math.clamp(-(a[1] * dx + a[2] * dy) / dd, 0, 1) else 0
		local px, py = a[1] + dx * t, a[2] + dy * t
		best = math.min(best, math.sqrt(px * px + py * py))
		if dx * (-a[2]) - dy * (-a[1]) < 0 then
			inside = false
		end
	end
	return if inside then 0 else best
end

local function discHits(c, ccf, cf, size)
	local rel = ccf:ToObjectSpace(cf)
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = rel:GetComponents()
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local ey = math.abs(r10) * hx + math.abs(r11) * hy + math.abs(r12) * hz
	if math.abs(y) >= c.half.Y + ey - 1e-3 then
		return false
	end
	local pts = {}
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local px, py, pz = sx * hx, sy * hy, sz * hz
				table.insert(pts, { x + r00 * px + r01 * py + r02 * pz, z + r20 * px + r21 * py + r22 * pz })
			end
		end
	end
	return hullDistance(pts) < c.r - 1e-3
end

local function hits(c, cf, size, shift)
	local ccf = if shift then c.cf + shift else c.cf
	if c.r then
		return discHits(c, ccf, cf, size)
	end
	return sat(ccf, c.half, cf, size / 2)
end

-- The part a decoration hangs on, through its welds (nil: anchored).
local function hostOf(p, root)
	local cur = p
	for _ = 1, 8 do
		local j = cur:FindFirstChildWhichIsA("WeldConstraint") or cur:FindFirstChildWhichIsA("JointInstance")
		if not j then
			return nil
		end
		local other = if j.Part1 == cur then j.Part0 else j.Part1
		if not other then
			return nil
		end
		if not other:IsDescendantOf(root) then
			return other
		end
		cur = other
	end
	return nil
end

-- Every place a decoration reaches as its host moves, and where it sits on the host at rest.
local function poses(p, host)
	if not host then
		return { p.CFrame }, p.CFrame
	end
	local mv = host:GetAttribute("Move")
	if typeof(mv) == "Vector3" then
		local rest = restCF(host) * host.CFrame:ToObjectSpace(p.CFrame)
		local move = restCF(host):VectorToWorldSpace(Vector3.new(mv.X, mv.Y, -mv.Z))
		local out = {}
		for _, t in { 0, 0.25, 0.5, 0.75, 1 } do
			table.insert(out, rest + move * t)
		end
		return out, rest
	end
	if host.Name == "Turntable" or host.Name == "Bar" then
		local axis = host.Position
		local out = {}
		for a = 0, 345, 15 do
			table.insert(out, CFrame.new(axis) * CFrame.Angles(0, math.rad(a), 0) * CFrame.new(-axis) * p.CFrame)
		end
		return out, p.CFrame
	end
	if host.Name == "Ball" then
		local beam = host.Parent and host.Parent:FindFirstChild("Beam")
		if beam then
			local pivot = beam.CFrame * CFrame.new(0, -0.6, 0)
			local b = pivot:PointToObjectSpace(host.Position)
			local theta0 = math.atan2(b.X, -b.Y)
			local rel = pivot:ToObjectSpace(p.CFrame)
			local out = {}
			for a = -75, 75, 15 do
				table.insert(out, pivot * CFrame.Angles(0, 0, math.rad(a) - theta0) * rel)
			end
			return out, p.CFrame
		end
	end
	return { p.CFrame }, p.CFrame
end

local function where(p)
	local names, cur = {}, p
	for _ = 1, 4 do
		if not cur.Parent or cur.Parent == workspace then
			break
		end
		cur = cur.Parent
		table.insert(names, 1, cur.Name)
	end
	return table.concat(names, "/")
end

-- Decorations (list of { root, piece }) reaching into any body space in `cols`: appended to `out`.
local function clearance(decos, cols, out, label)
	for _, entry in decos do
		local root, piece = entry[1], entry[2]
		for _, p in root:GetDescendants() do
			if not p:IsA("BasePart") then
				continue
			end
			local host = hostOf(p, root)
			local all, rest = poses(p, host)
			local hazard = host ~= nil and CS:HasTag(host, "KillPart")
			local reach = p.Size.Magnitude + (if host then (p.Position - host.Position).Magnitude + 2 * host.Size.Magnitude else 0)
			for _, c in cols do
				if hazard and c.piece == piece then
					continue
				end
				local far = c.half.Magnitude + reach + (if c.move then c.move.Magnitude else 0) + 2
				if (c.cf.Position - p.Position).Magnitude > far then
					continue
				end
				local bad = false
				if host and host == c.part then
					bad = hits(c, rest, p.Size)
				else
					local shifts = if c.move then { 0, 0.25, 0.5, 0.75, 1 } else { 0 }
					for _, cf in all do
						for _, t in shifts do
							if hits(c, cf, p.Size, if c.move then c.move * t else nil) then
								bad = true
								break
							end
						end
						if bad then
							break
						end
					end
				end
				if bad then
					local rel = c.frame:PointToObjectSpace(rest.Position)
					table.insert(out, string.format("%s %s %s (%.1f x %.1f x %.1f at %.2f, %.2f, %.2f) over %s %s", label, where(p),
						p.Name, p.Size.X, p.Size.Y, p.Size.Z, rel.X, rel.Y, rel.Z, c.piece and c.piece.Name or "?", c.part.Name))
					break
				end
			end
		end
	end
end

-- Does a part (at `rel` in a walkable's frame) offer a surface you could stand on: a ball a stud wide, a cylinder whose
-- top is half a stud wide both ways, a box whose upward face is?
local function floorLike(p, rel)
	local _, _, _, _, _, _, r10, r11, r12 = rel:GetComponents()
	if p:IsA("Part") and p.Shape == Enum.PartType.Ball then
		return p.Size.X >= 1
	end
	if p:IsA("Part") and p.Shape == Enum.PartType.Cylinder then
		return if math.abs(r10) > 0.7 then p.Size.Y >= 0.5 else math.min(p.Size.X, p.Size.Y) >= 0.5
	end
	local ups, s = { math.abs(r10), math.abs(r11), math.abs(r12) }, { p.Size.X, p.Size.Y, p.Size.Z }
	local k = 1
	if ups[2] > ups[k] then
		k = 2
	end
	if ups[3] > ups[k] then
		k = 3
	end
	return math.min(s[k % 3 + 1], s[(k + 1) % 3 + 1]) >= 0.5
end

-- Decorations of a walkable's own piece that read as floor (floorLike, top within 0.7 under the walkable's top) and
-- reach more than 0.5 past its edge: appended to `out`.
local function floorProblems(c, dressing, out, label)
	for _, p in dressing:GetDescendants() do
		if not p:IsA("BasePart") then
			continue
		end
		local host = hostOf(p, dressing)
		local _, rest = poses(p, host)
		local frame = c.frame
		if c.r then -- a disc looks the same from every side: face the part
			local q = c.frame:PointToObjectSpace(rest.Position)
			if q.X * q.X + q.Z * q.Z > 1e-6 then
				frame = c.frame * CFrame.Angles(0, math.atan2(-q.X, -q.Z), 0)
			end
		end
		local rel = frame:ToObjectSpace(rest)
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = rel:GetComponents()
		local h = p.Size / 2
		local ex = math.abs(r00) * h.X + math.abs(r01) * h.Y + math.abs(r02) * h.Z
		local ey = math.abs(r10) * h.X + math.abs(r11) * h.Y + math.abs(r12) * h.Z
		local ez = math.abs(r20) * h.X + math.abs(r21) * h.Y + math.abs(r22) * h.Z
		if not floorLike(p, rel) or y + ey > FLUSH or y + ey < -0.7 then
			continue
		end
		local over
		if c.r then
			local rr = c.w / 2
			local far = math.sqrt(math.max((x - ex) ^ 2, (x + ex) ^ 2) + math.max((z - ez) ^ 2, (z + ez) ^ 2))
			if p:IsA("Part") and p.Shape == Enum.PartType.Cylinder and math.abs(r10) > 0.7 then
				far = math.sqrt(x * x + z * z) + p.Size.Y / 2
			end
			local nx, nz = math.clamp(0, x - ex, x + ex), math.clamp(0, z - ez, z + ez)
			if math.sqrt(nx * nx + nz * nz) < rr + 0.5 then
				over = far - rr
			end
		else
			local hw, hl = c.w / 2, c.len / 2
			if x + ex > -hw - 0.5 and x - ex < hw + 0.5 and z + ez > -hl - 0.5 and z - ez < hl + 0.5 then
				over = math.max(x + ex - hw, -hw - (x - ex), z + ez - hl, -hl - (z - ez))
			end
		end
		if over and over > 0.51 then
			table.insert(out, string.format("%s %s %s reaches %.2f past the edge of %s", label, where(p), p.Name, over, c.part.Name))
		end
	end
end

-- Every part under Dressing.Rides is unanchored and joined (welds, through other decoration) to its Host; every other
-- decoration is anchored.
local function jointProblems(m, d, out, label)
	local rides = d:FindFirstChild("Rides")
	if rides then
		local host = m:FindFirstChild(rides:GetAttribute("Host") or "")
		local adj = {}
		for _, j in d:GetDescendants() do
			if (j:IsA("WeldConstraint") or j:IsA("JointInstance")) and j.Part0 and j.Part1 then
				adj[j.Part0] = adj[j.Part0] or {}
				adj[j.Part1] = adj[j.Part1] or {}
				table.insert(adj[j.Part0], j.Part1)
				table.insert(adj[j.Part1], j.Part0)
			end
		end
		local seen, queue = {}, {}
		if host then
			seen[host] = true
			queue = { host }
		end
		while #queue > 0 do
			local a = table.remove(queue)
			for _, b in adj[a] or {} do
				if not seen[b] then
					seen[b] = true
					table.insert(queue, b)
				end
			end
		end
		for _, p in rides:GetDescendants() do
			if p:IsA("BasePart") and (p.Anchored or not seen[p]) then
				table.insert(out, label .. " not joined to " .. tostring(rides:GetAttribute("Host")) .. ": " .. where(p))
			end
		end
	end
	for _, c in d:GetChildren() do
		if c.Name ~= "Rides" then
			for _, p in c:GetDescendants() do
				if p:IsA("BasePart") and not p.Anchored then
					table.insert(out, label .. " loose: " .. where(p))
				end
			end
		end
	end
end

local function flags(root, out, label)
	for _, p in root:GetDescendants() do
		if p:IsA("BasePart") and (p.CanCollide or p.CanTouch or p.CanQuery or not p.Massless or #CS:GetTags(p) > 0) then
			table.insert(out, label .. " " .. where(p))
		end
	end
end

local function sample(kind, k)
	return if kind == "moving" then { move = { 6, 0, 0 } } elseif kind == "checkpoint" then { stage = k } else nil
end
"""


DRESS_ALL = """
local root = Instance.new("Folder")
root.Parent = workspace
local out = { flags = {}, changed = {}, joints = {}, clear = {}, floor = {}, counts = {}, rides = {}, stage = {}, audit = {} }
for i, theme in T.THEMES do
	for k, kind in K.KindNames do
		local raw = sample(kind, k)
		local m = K.Obstacles[kind](root, CFrame.new(i * 80, 80, -k * 50), raw, nil)
		local snap = {}
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				snap[d] = { d.Size, d.Position, d.CanCollide, d.CanTouch, d.CanQuery }
			end
		end
		local d = T.dress(kind, m, raw, theme, Random.new(k))
		local label = theme .. "/" .. kind
		out.counts[label] = d and d:GetAttribute("Parts") or 0
		flags(d, out.flags, label)
		jointProblems(m, d, out.joints, label)
		local rides = d:FindFirstChild("Rides")
		out.rides[label] = rides and rides:GetAttribute("Host") or false
		local cols = columnsIn(m)
		clearance({ { d, m } }, cols, out.clear, label)
		for _, c in cols do
			floorProblems(c, d, out.floor, label)
		end
		for p, s in snap do
			if p.Size ~= s[1] or (p.Position - s[2]).Magnitude > 1e-4 or p.CanCollide ~= s[3] or p.CanTouch ~= s[4] or p.CanQuery ~= s[5] then
				table.insert(out.changed, label .. " " .. p.Name)
			end
		end
	end
	-- movers may be long one way (ObbyKit allows 5..16 a side): nothing may reach past them either
	for k, size in { { 5, 1, 16 }, { 16, 1, 5 } } do
		local raw = { move = { 0, 0, 6 }, size = size }
		local m = K.Obstacles.moving(root, CFrame.new(i * 80, 140, -k * 60), raw, nil)
		local d = T.dress("moving", m, raw, theme, Random.new(k))
		local label = theme .. "/moving " .. size[1] .. "x" .. size[3]
		jointProblems(m, d, out.joints, label)
		local cols = columnsIn(m)
		clearance({ { d, m } }, cols, out.clear, label)
		for _, c in cols do
			floorProblems(c, d, out.floor, label)
		end
	end
	local stage = { stage = i, name = "Sample " .. theme, pieces = {
		{ kind = "platform", gap = 5 },
		{ kind = "moving", gap = 5, move = { 6, 0, 0 } },
		{ kind = "spinner", gap = 5 },
		{ kind = "disappearing", gap = 5 },
		{ kind = "pendulum", gap = 5 },
		{ kind = "checkpoint", gap = 5 },
	} }
	local model = K.LevelBuilder.build(stage, CFrame.new(i * 80, 300, 0), { parent = root, validate = false })
	local before = K.LevelBuilder.audit(model)
	local decos = {}
	for _, m in model:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("Kind") then
			table.insert(decos, { T.dress(m:GetAttribute("Kind"), m, stage.pieces[m:GetAttribute("Piece")], theme, nil), m })
		end
	end
	local decor = T.stageDecor(model, theme, Random.new(i), i)
	table.insert(decos, { decor, nil })
	flags(decor, out.flags, theme .. "/stage")
	clearance(decos, columnsIn(model), out.clear, theme .. "/stage")
	out.stage[theme] = decor:GetAttribute("Parts")
	out.audit[theme] = HttpService:JSONEncode(before) == HttpService:JSONEncode(K.LevelBuilder.audit(model))
end
return { ok = true, detail = HttpService:JSONEncode(out) }
"""


@needs_headless
def test_every_theme_dresses_every_kind_clear_of_the_body_space(tmp_path):
    got = _offline(_game(tmp_path), DRESS_ALL)
    assert got["flags"] == [], got["flags"][:10]
    assert got["changed"] == [], got["changed"][:10]
    assert got["joints"] == [], got["joints"][:10]
    assert got["clear"] == [], got["clear"][:10]
    assert got["floor"] == [], got["floor"][:10]
    assert len(got["counts"]) == 10 * 11
    for where, n in got["counts"].items():
        assert 1 <= n <= 90, (where, n)
    for theme in THEMES:
        assert got["rides"][f"{theme}/moving"] == "Mover" and got["rides"][f"{theme}/turntable"] == "Turntable"
        assert got["rides"][f"{theme}/spinner"] == "Bar" and got["rides"][f"{theme}/pendulum"] == "Ball"
        assert 1 <= got["stage"][theme] <= 60, (theme, got["stage"][theme])
        assert got["audit"][theme] is True, theme


KIT_PARTS = """
local root = Instance.new("Folder")
root.Parent = workspace
local out = {}
local function emitters(m)
	local n = 0
	for _, e in m:GetDescendants() do
		if e:IsA("ParticleEmitter") and e.Name == "ThemeFx" then
			n += 1
		end
	end
	return n
end
local lava = K.Obstacles.lava(root, CFrame.new(0, 50, 0), nil, nil)
local slab = lava.Lava
local kit = { slab.Color, slab.Material }
T.dress("lava", lava, nil, "haunted", 1)
local haunted = slab.Color
T.dress("lava", lava, nil, "teacups", 1)
out.lavaChanged = slab.Color ~= haunted
out.lavaNeon = slab.Material == Enum.Material.Neon
out.lavaFx = emitters(lava)
out.undressed = T.dress("lava", lava, nil, nil, 1) == nil
out.lavaBack = slab.Color == kit[1] and slab.Material == kit[2] and lava:FindFirstChild("Dressing") == nil and emitters(lava) == 0
local pad = K.Obstacles.jumppad(root, CFrame.new(40, 50, 0), nil, nil)
T.dress("jumppad", pad, nil, "bumper", 1)
T.dress("jumppad", pad, nil, "flume", 1)
T.dress("jumppad", pad, nil, "finale", 1)
out.padFx = emitters(pad)
local cp = K.Obstacles.checkpoint(root, CFrame.new(80, 50, 0), { stage = 3 }, nil)
T.dress("checkpoint", cp, nil, "carousel", 1)
out.flagHidden = cp.Flag.Transparency == 1
T.dress("checkpoint", cp, nil, "")
out.flagBack = cp.Flag.Transparency == 0 and cp.Flag:GetAttribute("ThemeOrig_Transparency") == nil
-- carousel horses bob straight up and down on the ride each time ObbyKit moves it
local ride = K.Obstacles.moving(root, CFrame.new(160, 50, 0), { move = { 6, 0, 0 } }, nil)
T.dress("moving", ride, { move = { 6, 0, 0 } }, "carousel", 1)
local welds = {}
for _, weld in ride.Dressing.Rides:GetDescendants() do
	if weld:IsA("Weld") then
		table.insert(welds, { weld = weld, c0 = weld.C0, up = 0, side = 0 })
	end
end
for _ = 1, 6 do -- the bob follows os.clock(): sample it at a few moments
	task.wait(0.35)
	ride.Mover.CFrame = ride.Mover.CFrame + Vector3.new(0.05, 0, 0)
	for _, e in welds do
		local d = e.weld.C0.Position - e.c0.Position
		e.up = math.max(e.up, math.abs(d.Y))
		e.side = math.max(e.side, math.abs(d.X) + math.abs(d.Z))
	end
end
out.bob = {}
for _, e in welds do
	table.insert(out.bob, { up = e.up, side = e.side })
end
local m = K.Obstacles.platform(root, CFrame.new(120, 50, 0), nil, nil)
T.dress("platform", m, nil, "carousel", 1)
T.dress("platform", m, nil, "pirate", 1)
local n = 0
for _, c in m:GetChildren() do
	if c.Name == "Dressing" then
		n += 1
	end
end
out.redressed = n
out.unknownKind = T.dress("nope", m, nil, "carousel", 1) == nil
out.resolve = {}
for _, text in { "haunted", "Ghost Train Gulch", "Log Flume Lagoon", "Roller Coaster Ridge", "Grand Finale Fireworks",
	"Candy Carousel", "Teacup Twirl", "Ferris Wheel Heights", "Bumper Car Circuit", "Grand Entrance", "Midway Arcade Mile",
	"Pirate Cove", "volcano" } do
	out.resolve[text] = T.resolve(text)
end
out.blank = T.resolve("") == nil and T.resolve(nil) == nil and T.resolve("  ") == nil
return { ok = true, detail = HttpService:JSONEncode(out) }
"""


@needs_headless
def test_dress_owns_kit_parts_and_puts_them_back(tmp_path):
    got = _offline(_game(tmp_path), KIT_PARTS)
    assert got["lavaChanged"] and got["lavaNeon"], got
    assert got["lavaFx"] == 0, got  # the haunted smoke went when teacups (no lava emitter) dressed it
    assert got["undressed"] and got["lavaBack"], got
    assert got["padFx"] == 1, got
    assert got["flagHidden"] and got["flagBack"], got
    assert len(got["bob"]) == 2, got["bob"]
    for b in got["bob"]:
        assert b["side"] < 1e-6 and b["up"] > 0.05, got["bob"]
    assert got["redressed"] == 1 and got["unknownKind"] is True
    assert got["blank"] is True
    assert got["resolve"] == {
        "haunted": "haunted", "Ghost Train Gulch": "haunted", "Log Flume Lagoon": "flume",
        "Roller Coaster Ridge": "coaster", "Grand Finale Fireworks": "finale", "Candy Carousel": "carousel",
        "Teacup Twirl": "teacups", "Ferris Wheel Heights": "ferris", "Bumper Car Circuit": "bumper",
        "Grand Entrance": "entrance", "Midway Arcade Mile": "bumper", "Pirate Cove": "pirate", "volcano": "entrance",
    }


KILL = """
local root = Instance.new("Folder")
root.Parent = workspace
local PAD, TRAMP, CHECK = Color3.fromRGB(64, 225, 255), Color3.fromRGB(255, 92, 200), Color3.fromRGB(88, 214, 92)
local WARN = Color3.fromRGB(255, 236, 140)
-- redmean colour distance, 0..~765
local function dist(a, b)
	local r1, g1, b1 = a.R * 255, a.G * 255, a.B * 255
	local r2, g2, b2 = b.R * 255, b.G * 255, b.B * 255
	local rm = (r1 + r2) / 2
	return math.sqrt((2 + rm / 256) * (r1 - r2) ^ 2 + 4 * (g1 - g2) ^ 2 + (2 + (255 - rm) / 256) * (b1 - b2) ^ 2)
end
local PAL = __PALETTES__
local out = {}
for i, theme in T.THEMES do
	local p = PAL[theme]
	local look = { main = Color3.fromHex(p[1]), accent = Color3.fromHex(p[2]), highlight = Color3.fromHex(p[3]),
		material = Enum.Material.SmoothPlastic }
	local rec = { kill = {}, walk = {}, unowned = {}, closest = 1e9 }
	local kills, walks = {}, {}
	for k, kind in K.KindNames do
		local m = K.Obstacles[kind](root, CFrame.new(i * 80, 80, -k * 50), sample(kind, k), look)
		T.dress(kind, m, sample(kind, k), theme, Random.new(k))
		for _, d in m:GetChildren() do
			if d:IsA("BasePart") and CS:HasTag(d, "KillPart") then
				table.insert(kills, d)
			elseif d:IsA("BasePart") and CS:HasTag(d, "ObbyStandable") then
				table.insert(walks, d)
				local fn = kind == "checkpoint" or kind == "jumppad" or kind == "trampoline"
				if not fn and d:GetAttribute("ThemeOrig_Color") == nil then
					table.insert(rec.unowned, kind .. "/" .. d.Name)
				end
			end
		end
	end
	local kill = kills[1].Color
	for _, kp in kills do
		if kp.Color ~= kill or kp.Material ~= Enum.Material.Neon then
			table.insert(rec.kill, kp.Name .. " " .. tostring(kp.Color) .. " " .. kp.Material.Name)
		end
	end
	for _, other in { PAD, TRAMP, CHECK } do
		rec.closest = math.min(rec.closest, dist(kill, other))
	end
	for _, wp in walks do
		if wp.Color ~= WARN then
			local dd = dist(kill, wp.Color)
			rec.closest = math.min(rec.closest, dd)
			if dd < 120 then
				table.insert(rec.walk, wp.Parent.Name .. "/" .. wp.Name .. " " .. tostring(wp.Color))
			end
		end
	end
	out[theme] = rec
end
return { ok = true, detail = HttpService:JSONEncode(out) }
"""


@needs_headless
def test_kill_parts_glow_in_a_colour_no_walkable_or_pad_uses(tmp_path):
    zones = json.loads(FIXTURE.read_text())["zones"]
    palettes = {
        "entrance": zones[0]["palette"], "carousel": zones[1]["palette"], "bumper": zones[2]["palette"],
        "teacups": zones[3]["palette"], "ferris": zones[4]["palette"], "flume": zones[5]["palette"],
        "haunted": zones[6]["palette"], "pirate": ["#B5651D", "#E63946", "#F4E1C1"], "coaster": zones[7]["palette"],
        "finale": zones[9]["palette"],
    }
    lua = "{" + ", ".join(f'{k} = {{ "{v[0]}", "{v[1]}", "{v[2]}" }}' for k, v in palettes.items()) + "}"
    got = _offline(_game(tmp_path), KILL.replace("__PALETTES__", lua))
    for theme in THEMES:
        rec = got[theme]
        assert rec["kill"] == [], (theme, rec["kill"])
        assert rec["walk"] == [], (theme, rec["walk"])
        assert rec["unowned"] == [], (theme, rec["unowned"])
        assert rec["closest"] >= 120, (theme, rec["closest"])


FUNFAIR = """
local zones = HttpService:JSONDecode(__FIXTURE__).zones
local root = Instance.new("Folder")
root.Name = "Funfair"
root.Parent = workspace
local TURNS = { 0, 30, -45, 90, -90, 15, -30, 45 }
local out = { clear = {}, lights = {}, floor = {}, joints = {}, zones = {}, decor = {} }
for zi, zone in zones do
	local theme = T.resolve(zone.name)
	local cursor = CFrame.new(zi * 700, 60, 0)
	local stages = {}
	local rec = { theme = theme, stages = 0, parts = 0, max = 0, lamps = 0, lit = 0, swept = 0 }
	for i, st in zone.stages do
		local frame = cursor * CFrame.Angles(0, -math.rad(TURNS[(i - 1) % #TURNS + 1]), 0)
		local model, cp = K.LevelBuilder.build(st, frame, { parent = root, zone = zone.zone, zoneName = zone.name,
			palette = zone.palette, material = zone.material, validate = false })
		model.Parent = nil
		-- ObbyKit v2's order: each piece is dressed as it is built, before the pieces after it exist
		local pieces = {}
		for _, m in model:GetChildren() do
			if m:IsA("Model") and m:GetAttribute("Kind") then
				table.insert(pieces, m)
			end
		end
		table.sort(pieces, function(a, b)
			return a:GetAttribute("Piece") < b:GetAttribute("Piece")
		end)
		for _, m in pieces do
			m.Parent = nil
		end
		local rng = Random.new(st.stage * 7919 + 17)
		for _, m in pieces do
			m.Parent = model
			T.dress(m:GetAttribute("Kind"), m, st.pieces[m:GetAttribute("Piece")], theme, rng)
		end
		local decor = T.stageDecor(model, theme, rng, st.stage)
		model.Parent = root
		table.insert(stages, model)
		local n = 0
		for _, m in pieces do
			local d = m:FindFirstChild("Dressing")
			for _, p in d:GetDescendants() do
				if p:IsA("BasePart") then
					n += 1
				end
			end
			jointProblems(m, d, out.joints, zone.name .. " stage " .. st.stage)
			for _, p in m:GetChildren() do
				if p:IsA("BasePart") and CS:HasTag(p, "ObbyStandable") then
					floorProblems(column(p, m), d, out.floor, zone.name .. " stage " .. st.stage)
				end
			end
		end
		local dp = decor:GetAttribute("Parts")
		n += dp
		table.insert(out.decor, dp)
		rec.stages += 1
		rec.parts += n
		rec.max = math.max(rec.max, n)
		rec.swept += decor:GetAttribute("Swept") or 0
		local lamps = 0
		for _, g in decor:GetDescendants() do
			if g:IsA("Model") and g.Name == "Lamp" then
				lamps += 1
			end
		end
		rec.lamps += lamps
		rec.lit += if lamps > 0 then 1 else 0
		if cp then
			cursor = CFrame.new((cp.CFrame * CFrame.new(0, cp.Size.Y / 2, 0)).Position) * frame.Rotation
		end
	end
	-- every decoration of the zone against every body space of the zone
	local cols = columnsIn(root)
	for _, model in stages do
		local decos = {}
		for _, m in model:GetChildren() do
			local d = m:FindFirstChild("Dressing")
			if d then
				table.insert(decos, { d, m })
			end
		end
		clearance(decos, cols, out.clear, zone.name)
		local lights = {}
		clearance({ { model.StageDecor, nil } }, cols, lights, zone.name)
		for _, s in lights do
			table.insert(out.lights, s)
		end
	end
	out.zones[zone.name] = rec
	root:ClearAllChildren()
end
return { ok = true, detail = HttpService:JSONEncode(out) }
"""


@needs_headless
def test_the_funfair_levels_on_turned_stages_keep_every_body_space_clear(tmp_path):
    body = FUNFAIR.replace("__FIXTURE__", "[==[" + FIXTURE.read_text() + "]==]")
    got = _offline(_game(tmp_path), body)
    assert got["clear"] == [], got["clear"][:10]
    assert got["lights"] == [], got["lights"][:10]
    assert got["floor"] == [], got["floor"][:10]
    assert got["joints"] == [], got["joints"][:10]
    assert max(got["decor"]) <= 60
    for name, rec in got["zones"].items():
        assert rec["stages"] == 12, (name, rec)
        assert rec["lit"] >= 9, (name, rec)  # string lights and lamps survive the clearance rules on most stages
        assert rec["max"] <= 330, (name, rec)


SWEEP = """
-- Stage 2 turns hard right on stage 1's last checkpoint and starts half a stud from it: the checkpoint's arch post
-- stands where players on stage 2's first platform are. In stage 3 a platform comes a stud after a turntable, inside
-- the ring a carousel's horses ride. Built in ObbyKit v2's order: each piece is dressed before the next one exists.
local root = Instance.new("Folder")
root.Parent = workspace
local out = { clear = {}, loose = {}, swept = {}, arch = {} }
local DATA = {
	{ stage = 1, name = "Run Up", turn = 0, pieces = { { kind = "platform", gap = 4 }, { kind = "platform", gap = 4 },
		{ kind = "checkpoint", gap = 4 } } },
	{ stage = 2, name = "Hard Right", turn = 90, pieces = { { kind = "platform", gap = 0.5, size = { 10, 1, 10 } },
		{ kind = "platform", gap = 4 }, { kind = "checkpoint", gap = 4 } } },
	{ stage = 3, name = "Close Call", turn = 0, pieces = { { kind = "turntable", gap = 4, size = { 14, 1, 14 } },
		{ kind = "platform", gap = 1, size = { 10, 1, 10 } }, { kind = "checkpoint", gap = 4 } } },
}
for i, theme in T.THEMES do
	local cursor = CFrame.new(i * 150, 60, 400)
	local stages = {}
	for _, st in DATA do
		local frame = cursor * CFrame.Angles(0, -math.rad(st.turn), 0)
		local model, cp = K.LevelBuilder.build(st, frame, { parent = root, validate = false })
		model.Parent = nil
		local pieces = {}
		for _, m in model:GetChildren() do
			if m:IsA("Model") and m:GetAttribute("Kind") then
				table.insert(pieces, m)
			end
		end
		table.sort(pieces, function(a, b)
			return a:GetAttribute("Piece") < b:GetAttribute("Piece")
		end)
		for _, m in pieces do
			m.Parent = nil
		end
		local rng = Random.new(st.stage)
		for _, m in pieces do
			m.Parent = model
			T.dress(m:GetAttribute("Kind"), m, st.pieces[m:GetAttribute("Piece")], theme, rng)
		end
		T.stageDecor(model, theme, rng, st.stage)
		model.Parent = root
		table.insert(stages, model)
		cursor = CFrame.new((cp.CFrame * CFrame.new(0, cp.Size.Y / 2, 0)).Position) * frame.Rotation
	end
	out.swept[theme] = stages[2].StageDecor:GetAttribute("Swept")
	local cols = columnsIn(root)
	for _, model in stages do
		local decos = { { model.StageDecor, nil } }
		for _, m in model:GetChildren() do
			if m:FindFirstChild("Dressing") then
				table.insert(decos, { m.Dressing, m })
			end
		end
		clearance(decos, cols, out.clear, theme)
	end
	local cpDressing = stages[1]["03_checkpoint"].Dressing
	out.arch[theme] = cpDressing:FindFirstChild("Arch", true) ~= nil
	for _, p in cpDressing:GetDescendants() do
		if p:IsA("BasePart") and p.Parent.Parent == cpDressing then
			table.insert(out.loose, theme .. " " .. where(p))
		end
	end
	root:ClearAllChildren()
end
return { ok = true, detail = HttpService:JSONEncode(out) }
"""


@needs_headless
def test_a_later_stage_sweeps_decorations_out_of_its_way(tmp_path):
    got = _offline(_game(tmp_path), SWEEP)
    assert got["clear"] == [], got["clear"][:10]
    assert got["loose"] == [], got["loose"][:10]
    for theme in THEMES:
        assert got["swept"][theme] >= 1, (theme, got["swept"])
        assert got["arch"][theme] is False, theme  # the whole arch went, not a post with its beam left floating


SHAPES = """
-- ObbyKit v2's platform shapes, built the way v2's Obstacles.platform builds them: a log lying across the course and
-- a wedge-ramp climbing along it, each with a Shape attribute.
local function v2platform(parent, cf, shape, size)
	local m = Instance.new("Model")
	m.Name = "platform"
	m:SetAttribute("Kind", "platform")
	CS:AddTag(m, "Obstacle")
	m.Parent = parent
	local part
	if shape == "cylinder" then
		part = Instance.new("Part")
		part.Shape = Enum.PartType.Cylinder
		part.Size = Vector3.new(size[1], size[3], size[3])
		part.CFrame = cf * CFrame.new(0, -size[3] / 2, 0)
	else
		part = Instance.new("WedgePart")
		part.Size = Vector3.new(size[1], size[2], size[3])
		part.CFrame = cf * CFrame.new(0, -size[2] / 2, 0) * CFrame.Angles(0, math.pi, 0)
	end
	part.Name = "Platform"
	part.Anchored = true
	part:SetAttribute("Shape", shape)
	CS:AddTag(part, "ObbyStandable")
	part.Parent = m
	return m, part
end
local root = Instance.new("Folder")
root.Parent = workspace
local out = { clear = {}, floor = {}, span = {}, flags = {} }
for i, theme in T.THEMES do
	for k, case in { { "cylinder", { 10, 4, 4 } }, { "cylinder", { 8, 3, 3 } }, { "wedge-ramp", { 8, 3, 10 } }, { "wedge-ramp", { 6, 6, 8 } } } do
		local cf = CFrame.new(i * 80, 80, -k * 40) * CFrame.Angles(0, math.rad(25 * k), 0)
		local m, part = v2platform(root, cf, case[1], case[2])
		local d = T.dress("platform", m, nil, theme, Random.new(k))
		local label = theme .. "/" .. case[1] .. k
		flags(d, out.flags, label)
		local c = column(part, m)
		clearance({ { d, m } }, { c }, out.clear, label)
		floorProblems(c, d, out.floor, label)
		if case[1] == "cylinder" then
			local lo, hi = math.huge, -math.huge
			for _, p in d:GetDescendants() do
				if p:IsA("BasePart") then
					local x = c.frame:PointToObjectSpace(p.Position).X
					lo, hi = math.min(lo, x), math.max(hi, x)
				end
			end
			if not (lo <= -0.4 * case[2][1] and hi >= 0.4 * case[2][1]) then
				table.insert(out.span, string.format("%s dressed from x %.1f to %.1f on a %g-stud log", label, lo, hi, case[2][1]))
			end
		end
	end
end
return { ok = true, detail = HttpService:JSONEncode(out) }
"""


@needs_headless
def test_v2_logs_and_ramps_are_dressed_along_their_shape(tmp_path):
    got = _offline(_game(tmp_path), SHAPES)
    assert got["flags"] == [], got["flags"][:10]
    assert got["clear"] == [], got["clear"][:10]
    assert got["floor"] == [], got["floor"][:10]
    assert got["span"] == [], got["span"][:10]


LEGS = """
local root = Instance.new("Folder")
root.Parent = workspace
local ground = Instance.new("Part")
ground.Name = "Ground"
ground.Anchored = true
ground.Size = Vector3.new(1400, 2, 300)
ground.CFrame = CFrame.new(700, -1, 0)
ground.Parent = workspace
local out = { grounded = {}, floating = {}, short = {}, clear = {}, legs = {}, brackets = {} }
local stage = { stage = 1, name = "Legs", pieces = {
	{ kind = "platform", gap = 4, size = { 10, 1, 10 } },
	{ kind = "conveyor", gap = 4 },
	{ kind = "jumppad", gap = 4, rise = 2 },
	{ kind = "pendulum", gap = 5 },
	{ kind = "turntable", gap = 4 },
	{ kind = "checkpoint", gap = 4 },
} }
local function bottomOf(p)
	local _, y, _, _, _, _, r10, r11, r12 = p.CFrame:GetComponents()
	local h = p.Size / 2
	return y - (math.abs(r10) * h.X + math.abs(r11) * h.Y + math.abs(r12) * h.Z)
end
for i, theme in T.THEMES do
	for _, case in { { "over", 40 }, { "off", 4000 } } do
		local origin = CFrame.new(i * 120 + case[2] - 40, 40, 100)
		local model = K.LevelBuilder.build(stage, origin, { parent = root, validate = false })
		-- a walkable under the first platform: no leg may go through it or its body space
		local under = K.Obstacles.platform(root, origin * CFrame.new(0, -18, -(5 + 4 + 5)), { size = { 12, 1, 12 } }, nil)
		local decos = {}
		for _, m in model:GetChildren() do
			if m:IsA("Model") and m:GetAttribute("Kind") then
				local d = T.dress(m:GetAttribute("Kind"), m, stage.pieces[m:GetAttribute("Piece")], theme, Random.new(3))
				table.insert(decos, { d, m })
				for _, g in d:GetDescendants() do
					if g:IsA("Model") and g.Name == "Leg" then
						out.legs[theme] = (out.legs[theme] or 0) + 1
						local bottom = math.huge
						for _, p in g:GetDescendants() do
							if p:IsA("BasePart") then
								bottom = math.min(bottom, bottomOf(p))
							end
						end
						if case[1] == "off" then
							table.insert(out.floating, theme .. " " .. m.Name .. " has a leg with no ground under it")
						elseif bottom > 0.6 or bottom < -0.6 then
							table.insert(out.grounded, string.format("%s %s leg ends at y %.2f, ground at 0", theme, m.Name, bottom))
						end
					elseif g:IsA("Model") and g.Name == "Bracket" then
						out.brackets[theme] = (out.brackets[theme] or 0) + 1
						for _, p in g:GetDescendants() do
							if p:IsA("BasePart") and p.Position.Y < 40 - 6 then
								table.insert(out.short, theme .. " " .. m.Name .. " bracket reaches y " .. p.Position.Y)
							end
						end
					end
				end
			end
		end
		local cols = columnsIn(model)
		for _, c in columnsIn(under) do
			table.insert(cols, c)
		end
		clearance(decos, cols, out.clear, theme .. "/" .. case[1])
	end
end
return { ok = true, detail = HttpService:JSONEncode(out) }
"""


@needs_headless
def test_legs_reach_the_ground_or_become_brackets(tmp_path):
    got = _offline(_game(tmp_path), LEGS)
    assert got["clear"] == [], got["clear"][:10]
    assert got["grounded"] == [], got["grounded"][:10]
    assert got["floating"] == [], got["floating"][:10]
    assert got["short"] == [], got["short"][:10]
    for theme in ("flume", "pirate", "coaster"):
        assert got["legs"].get(theme, 0) >= 4, (theme, got["legs"])
    for theme in ("flume", "coaster"):
        assert got["brackets"].get(theme, 0) >= 4, (theme, got["brackets"])


def test_the_index_entry_is_an_obby_module_with_the_contract():
    entry = next(e for e in director.kit_index() if e["name"] == "ObbyThemes")
    assert entry["genres"] == ["obby"] and entry["path_in_game"] == "ReplicatedStorage/Kit/ObbyThemes.luau"
    api = "\n".join(entry["api"])
    for name in ("ObbyThemes.dress(kind, model, params, theme, rng)", "ObbyThemes.stageDecor(stageModel, theme, rng, stage)",
                 "ObbyThemes.THEMES", "ObbyThemes.resolve(text)", "Rides", "ThemeOrig_", *THEMES):
        assert name in api, name
    src = (KIT_DIR / "ObbyThemes.luau").read_text(encoding="utf-8")
    assert '"' + '", "'.join(THEMES) + '"' in src
    assert "rbxassetid" not in src and "MeshId" not in src
    assert "Enum.Material.Fabric" not in src  # knitted Fabric reads as mud from the player's camera


@pytest.mark.skipif(LUAU is None, reason="luau-compile not on PATH")
def test_obby_themes_compiles():
    r = subprocess.run([LUAU, "--null", str(KIT_DIR / "ObbyThemes.luau")], capture_output=True, text=True, check=False)
    assert r.returncode == 0, r.stdout + r.stderr
