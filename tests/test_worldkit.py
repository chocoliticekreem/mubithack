"""WorldKit (forge/kit/modules/WorldKit.luau): the amusement park an obby is built in. The module runs in the
headless engine here; these tests pin the contract the course builders rely on (anchors, gates, the courses kept
clear and dressed from start to end), how it measures courses from level data, and the size of every piece."""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest

from forge import checks, director, obby

needs_headless = pytest.mark.skipif(not checks.headless_available(), reason="luau CLI not on PATH")
WORLDKIT = director.KIT_MODULES_DIR / "WorldKit.luau"
OBBYKIT = director.KIT_MODULES_DIR / "ObbyKit.luau"
# the courses of the overnight "Funfair Frenzy" game (runs/funfair-frenzy-an-amusement-park-obby-2, its
# ReplicatedStorage/Levels/Zone01-10.luau): start pad to last checkpoint, all straight
FUNFAIR_LENGTHS = [1659, 1382, 2156, 1887, 1978, 1946, 2008, 2152, 2277, 1890]


def _run(tmp_path: Path, body: str, files: dict[str, str] | None = None, timeout: float = 120) -> dict:
    root = tmp_path / "game"
    (root / "ReplicatedStorage/Kit").mkdir(parents=True)
    shutil.copy(WORLDKIT, root / "ReplicatedStorage/Kit/WorldKit.luau")
    for rel, text in (files or {}).items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text, encoding="utf-8")
    res = checks.run_check_offline(root, checks.Check(id="worldkit", title="worldkit", covers="", body=body), timeout=timeout)
    assert res.get("ok"), res
    return json.loads(res["detail"])


# Builds the default ten-zone park (optionally with course lengths) and checks it the way a player would meet it:
# every course starts on its tower facing along the ring, nothing taller than 6 studs stands within 40 studs of any
# course from 24 studs behind its start to 40 past its end, and wherever a player is on a course (every 40 studs)
# a piece of the park (dressing, a ride, a tree) stands within 80 studs.
PARK = """
local WorldKit = require(game.ReplicatedStorage.Kit.WorldKit)
local LENGTHS = __LENGTHS__
local zones = {}
for i, t in WorldKit.Themes do
	zones[i] = { name = "Zone " .. i, theme = t, palette = { "#FF4F6D", "#FFC429", "#FFF4E0" },
		length = if LENGTHS then LENGTHS[i] else nil }
end
local park = WorldKit.buildPark({ zones = zones, seed = 3, title = "Test Park" })
local ground = park.spawn.Position.Y - 1
local rC = 0.64 * 800
local out = { parts = park.parts, anchors = 0, gates = 0, problems = {}, tall = 0, lengths = {}, samples = 0, bare = 0,
	spawn = typeof(park.spawn), lobby = typeof(park.lobby), reach = workspace.Park:GetAttribute("Reach"),
	ground = workspace.Park:GetAttribute("Ground") }
local function bad(s)
	if #out.problems < 25 then
		table.insert(out.problems, s)
	end
end
local function flat(v) return Vector3.new(v.X, 0, v.Z) end
-- every course's clearance stretch as 2D segments
local stretch = {}
for i = 1, #zones do
	local a, g, c = park.anchors[i], park.gates[i], park.courses[i]
	if typeof(a) == "CFrame" and typeof(g) == "CFrame" and type(c) == "table" and #c >= 2 then
		out.anchors += 1
		out.gates += 1
		local p = a.Position
		local toCenter = Vector3.new(-p.X, 0, -p.Z).Unit
		if math.abs(math.sqrt(p.X ^ 2 + p.Z ^ 2) - rC) > 0.5 then bad("zone " .. i .. " starts off the course circle") end
		if math.abs(a.LookVector.Y) > 1e-3 then bad("zone " .. i .. " start is not level") end
		if math.abs(a.LookVector:Dot(toCenter)) > 1e-3 then bad("zone " .. i .. " course is not along the tangent") end
		if a.RightVector:Dot(toCenter) < 0.99 then bad("zone " .. i .. " has the park on its left") end
		if p.Y - ground < 30 then bad(string.format("zone %d starts only %.1f above the ground", i, p.Y - ground)) end
		if math.abs(g.Position.Y - ground) > 1.5 then bad("zone " .. i .. " gate is not on the ground") end
		if (flat(c[1]) - flat(p)).Magnitude > 0.01 then bad("zone " .. i .. " course does not start at its anchor") end
		local len = 0
		for k = 1, #c - 1 do len += (flat(c[k + 1]) - flat(c[k])).Magnitude end
		out.lengths[i] = math.floor(len + 0.5)
		local d0 = (flat(c[2]) - flat(c[1])).Unit
		local d1 = (flat(c[#c]) - flat(c[#c - 1])).Unit
		local pts = { flat(c[1]) - d0 * 24 }
		for _, q in c do table.insert(pts, flat(q)) end
		table.insert(pts, flat(c[#c]) + d1 * 40)
		stretch[i] = { pts = pts, start = flat(p), look = flat(a.LookVector).Unit }
	end
end
for i, a in stretch do
	for j, b in stretch do
		if i < j then
			for k = 2, #a.pts - 2 do
				for l = 2, #b.pts - 2 do
					local p, r, q, s = a.pts[k], a.pts[k + 1] - a.pts[k], b.pts[l], b.pts[l + 1] - b.pts[l]
					local den = r.X * s.Z - r.Z * s.X
					if math.abs(den) > 1e-9 then
						local t = ((q.X - p.X) * s.Z - (q.Z - p.Z) * s.X) / den
						local u = ((q.X - p.X) * r.Z - (q.Z - p.Z) * r.X) / den
						if t >= 0 and t <= 1 and u >= 0 and u <= 1 then bad(string.format("courses %d and %d cross", i, j)) end
					end
				end
			end
		end
	end
end
-- the XZ footprint of a part: the convex hull of its eight corners seen from above
local function footprint(cf, size)
	local pts = {}
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				table.insert(pts, flat((cf * CFrame.new(sx * size.X / 2, sy * size.Y / 2, sz * size.Z / 2)).Position))
			end
		end
	end
	table.sort(pts, function(a, b) return a.X < b.X or (a.X == b.X and a.Z < b.Z) end)
	local function cross(o, a, b) return (a.X - o.X) * (b.Z - o.Z) - (a.Z - o.Z) * (b.X - o.X) end
	local hull = {}
	for _, pass in { 1, 2 } do
		local from, to, step = 1, #pts, 1
		if pass == 2 then from, to, step = #pts, 1, -1 end
		local base = #hull
		for i = from, to, step do
			local p = pts[i]
			while #hull >= base + 2 and cross(hull[#hull - 1], hull[#hull], p) <= 0 do
				table.remove(hull)
			end
			table.insert(hull, p)
		end
		table.remove(hull)
	end
	return hull
end
local function pointSeg(p, a, b)
	local ab = b - a
	local t = math.clamp((p - a):Dot(ab) / math.max(ab:Dot(ab), 1e-9), 0, 1)
	return (a + ab * t - p).Magnitude
end
local function segsCross(p, p2, q, q2)
	local function o(a, b, c) return (b.X - a.X) * (c.Z - a.Z) - (b.Z - a.Z) * (c.X - a.X) end
	return (o(p, p2, q) > 0) ~= (o(p, p2, q2) > 0) and (o(q, q2, p) > 0) ~= (o(q, q2, p2) > 0)
end
-- exact XZ distance from a convex hull (counterclockwise) to the segment a-b (0 when they overlap)
local function hullDist(hull, a, b)
	local n = #hull
	if n < 3 then
		local best = math.huge
		for _, p in hull do best = math.min(best, pointSeg(p, a, b)) end
		return best
	end
	local inside = function(p)
		for i = 1, n do
			local u, v = hull[i], hull[i % n + 1]
			if (v.X - u.X) * (p.Z - u.Z) - (v.Z - u.Z) * (p.X - u.X) < 0 then return false end
		end
		return true
	end
	if inside(a) or inside(b) then return 0 end
	local best = math.huge
	for i = 1, n do
		local u, v = hull[i], hull[i % n + 1]
		if segsCross(a, b, u, v) then return 0 end
		best = math.min(best, pointSeg(u, a, b), pointSeg(a, u, v), pointSeg(b, u, v))
	end
	return best
end
local dressed = {}
local CELL = 80
for _, part in workspace.Park:GetDescendants() do
	if part:IsA("BasePart") then
		local cf, size = part.CFrame, part.Size
		local function reach(axis)
			return math.abs(cf.RightVector[axis]) * size.X / 2 + math.abs(cf.UpVector[axis]) * size.Y / 2
				+ math.abs(cf.LookVector[axis]) * size.Z / 2
		end
		local top = cf.Position.Y + reach("Y") - ground
		local r = math.sqrt(cf.Position.X ^ 2 + cf.Position.Z ^ 2)
		local landmark = part:FindFirstAncestorWhichIsA("Model")
		if landmark and string.match(landmark.Name, "^Zone%d") and r + math.max(reach("X"), reach("Z")) > rC then
			bad(part:GetFullName() .. " sticks out past the course circle")
		end
		local folder = part:FindFirstAncestorWhichIsA("Folder")
		if folder and (folder.Name == "Dressing" or folder.Name == "Rides" or folder.Name == "Nature") then
			local key = math.floor(cf.Position.X / CELL) .. ":" .. math.floor(cf.Position.Z / CELL)
			dressed[key] = dressed[key] or {}
			table.insert(dressed[key], flat(cf.Position))
		end
		if top > 6 then
			out.tall += 1
			for k, st in stretch do
				local rel = flat(cf.Position) - st.start
				-- the start's own tower under its pad, and the stairs up to it behind it
				if not (rel.Magnitude < 9 or rel.Magnitude < 70 and rel:Dot(st.look) <= 2) then
					local hull = footprint(cf, size)
					for s = 1, #st.pts - 1 do
						local d = hullDist(hull, st.pts[s], st.pts[s + 1])
						if d < 40 then
							bad(string.format("%s (%.0f tall) stands %.0f studs beside course %d", part:GetFullName(), top, d, k))
							break
						end
					end
				end
			end
		end
	end
end
for i, st in stretch do
	local c = park.courses[i]
	for k = 1, #c - 1 do
		local a, b = flat(c[k]), flat(c[k + 1])
		local len = (b - a).Magnitude
		for s = 0, len, 40 do
			local p = a + (b - a) * (s / math.max(len, 1e-9))
			out.samples += 1
			local found = false
			for dx = -1, 1 do
				for dz = -1, 1 do
					for _, q in dressed[(math.floor(p.X / CELL) + dx) .. ":" .. (math.floor(p.Z / CELL) + dz)] or {} do
						if (q - p).Magnitude <= 80 then
							found = true
							break
						end
					end
					if found then break end
				end
				if found then break end
			end
			if not found then
				out.bare += 1
				bad(string.format("course %d has no park within 80 studs %.0f studs in", i, s))
			end
		end
	end
end
-- the flat underlay that stands in for the Terrain on a client until it arrives: under every pond and lake, as far
-- as the ground goes
out.underlay = { area = 0, top = -math.huge }
for _, p in workspace.Park.Ground:GetChildren() do
	out.underlay.area += p.Size.X * p.Size.Z
	out.underlay.top = math.max(out.underlay.top, p.Position.Y + p.Size.Y / 2 - ground)
end
return { ok = true, detail = game:GetService("HttpService"):JSONEncode(out) }
"""


@needs_headless
def test_park_keeps_the_contract_the_courses_rely_on(tmp_path):
    got = _run(tmp_path, PARK.replace("__LENGTHS__", "nil"))
    assert got["problems"] == []
    assert got["anchors"] == 10 and got["gates"] == 10 and got["spawn"] == "CFrame" and got["lobby"] == "CFrame"
    assert got["lengths"] == [460] * 10  # no level data: each zone's course is its plot, straight ahead
    assert 8000 <= got["parts"] <= 30000
    assert got["tall"] > 2000  # the check above really looked at the rides, trees and lamps
    assert got["samples"] >= 100 and got["bare"] == 0
    assert got["underlay"]["top"] <= -10.5 and got["underlay"]["area"] >= (2 * got["ground"]) ** 2 * 0.999


@needs_headless
def test_long_courses_carry_the_park_to_their_ends(tmp_path):
    # the overnight game's zones are 1,382-2,277 studs of straight course: the park goes all the way with them,
    # and the ground runs at least 1,500 studs past the farthest of them
    got = _run(tmp_path, PARK.replace("__LENGTHS__", "{ " + ", ".join(map(str, FUNFAIR_LENGTHS)) + " }"), timeout=240)
    assert got["problems"] == []
    assert got["lengths"] == FUNFAIR_LENGTHS
    assert got["samples"] >= 480 and got["bare"] == 0
    assert got["ground"] >= got["reach"] - 118 + 1500
    assert got["parts"] <= 45000


# Level data in ReplicatedStorage.Levels is measured with the game's ObbyKit: here a stand-in ObbyKit whose stages
# are straight runs `len` studs long, so the course WorldKit lays out can be checked point by point. A version-2
# ObbyKit turns each stage by its `turn` on its start pad (right +); a version-1 one never turns.
STUB_OBBYKIT = """
return { VERSION = __VERSION__, LevelBuilder = { layout = function(stage)
	return { { kind = "pad", x = 0, z = 0, top = 0, piece = 0 },
		{ kind = "checkpoint", x = stage.side or 0, z = stage.len, top = stage.rise or 0, piece = 1 } }
end } }
"""

TURNED_ZONE = """
return { zone = __ZONE__, name = "Turns", stages = {
	{ stage = 1, len = 60 }, { stage = 2, len = 30, turn = -90, rise = 15 }, { stage = 3, len = 60, turn = -90 },
	{ stage = 4, len = 30, turn = -90, rise = 15 }, { stage = 5, len = 60, turn = -90 },
} }
"""

MEASURE = """
local WorldKit = require(game.ReplicatedStorage.Kit.WorldKit)
local park = WorldKit.buildPark({ zones = { { theme = "entrance" }, { theme = "carousel" }, { theme = "ferris" } }, seed = 5 })
local out = { courses = {} }
for i, c in park.courses do
	local a = park.anchors[i]
	local pts = {}
	for _, p in c do
		local l = a:PointToObjectSpace(p)
		table.insert(pts, { math.floor(l.X * 100 + 0.5) / 100, math.floor(l.Y * 100 + 0.5) / 100, math.floor(-l.Z * 100 + 0.5) / 100 })
	end
	out.courses[i] = pts
end
return { ok = true, detail = game:GetService("HttpService"):JSONEncode(out) }
"""


@needs_headless
def test_courses_are_measured_from_level_data_with_their_turns(tmp_path):
    files = {"ReplicatedStorage/Kit/ObbyKit.luau": STUB_OBBYKIT.replace("__VERSION__", "2"),
             "ReplicatedStorage/Levels/Zone02.luau": TURNED_ZONE.replace("__ZONE__", "2")}
    got = _run(tmp_path, MEASURE, files)
    # zone frame: x right of the start line, y up from the start pad, z forward. Left turns fold the course back
    # into a second lane 30 studs out and back again, each corner a level up: the switchback forge levels plans
    courses = got["courses"]  # zones 1-3, in order
    assert courses[1] == [[0, 0, 0], [0, 0, 60], [-30, 15, 60], [-30, 15, 0], [0, 30, 0], [0, 30, 60]]
    assert courses[0] == [[0, 0, 0], [0, 0, 460]] and courses[2] == [[0, 0, 0], [0, 0, 460]]
    # the whole park keeps that folded course clear and dressed, as it does a straight one
    park = _run(tmp_path / "park", PARK.replace("__LENGTHS__", "nil"), files)
    assert park["problems"] == [] and park["bare"] == 0
    assert park["lengths"][1] == 240


@needs_headless
def test_an_obbykit_that_does_not_turn_stages_gets_a_straight_course(tmp_path):
    files = {"ReplicatedStorage/Kit/ObbyKit.luau": STUB_OBBYKIT.replace("__VERSION__", "1"),
             "ReplicatedStorage/Levels/Zone02.luau": TURNED_ZONE.replace("__ZONE__", "2")}
    got = _run(tmp_path, MEASURE, files)
    assert got["courses"][1] == [[0, 0, 0], [0, 30, 240]]


@needs_headless
def test_the_real_obbykit_measures_a_zone_like_obby_layout_does(tmp_path):
    stages = [obby.fallback_stage(n, 1 + n % 9) for n in range(1, 13)]
    zone = {"zone": 3, "name": "Fallbacks", "stages": stages}
    want = sum(obby.layout(s)[0][-1].z for s in stages)
    rise = sum(obby.layout(s)[0][-1].top for s in stages)
    files = {"ReplicatedStorage/Kit/ObbyKit.luau": OBBYKIT.read_text(encoding="utf-8"),
             "ReplicatedStorage/Levels/Zone03.luau": obby.render_zone_luau(zone)}
    got = _run(tmp_path, MEASURE, files)
    end = got["courses"][2][-1]
    assert abs(end[2] - want) < 0.05 and abs(end[1] - rise) < 0.05 and abs(end[0]) < 0.05


LANDMARKS = """
local WorldKit = require(game.ReplicatedStorage.Kit.WorldKit)
local out = {}
local themes = table.clone(WorldKit.Themes)
table.insert(themes, "droptower")
table.insert(themes, "space station")
for i, theme in themes do
	local m = WorldKit.landmark(theme, CFrame.new(i * 300, 0, 0), { "#3EC9F5", "#FFC429" })
	local n, movers, complete = 0, 0, true
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			n += 1
			if d:GetAttribute("WKMotion") then
				movers += 1
				complete = complete and typeof(d:GetAttribute("WKRest")) == "CFrame" and d.Anchored
			end
		end
	end
	out[theme] = { parts = n, kind = m:GetAttribute("Landmark"), inWorkspace = m:IsDescendantOf(workspace), movers = movers,
		complete = complete }
end
return { ok = true, detail = game:GetService("HttpService"):JSONEncode(out) }
"""


@needs_headless
def test_every_landmark_is_a_real_ride_of_150_to_600_parts(tmp_path):
    got = _run(tmp_path, LANDMARKS)
    assert len(got) == 12
    for theme, info in got.items():
        assert info["inWorkspace"], theme
        assert 150 <= info["parts"] <= 600, (theme, info)
        assert info["movers"] >= 1 and info["complete"], (theme, info)  # every ride moves, on clients, from data
    assert got["entrance"]["kind"] == "circus" and got["finale"]["kind"] == "fireworks"
    assert got["carousel"]["kind"] == "carousel" and got["droptower"]["kind"] == "droptower"
    assert got["space station"]["kind"]  # an unknown theme still gets a ride


DRESSING = """
local WorldKit = require(game.ReplicatedStorage.Kit.WorldKit)
local out = { kinds = {}, tall = {} }
for i, kind in WorldKit.DressingKinds do
	local m = WorldKit.dressing(kind, CFrame.new(i * 40, 0, 0), { "#FF4F6D", "#FFC429" }, "Hot Dogs")
	local n, top = 0, 0
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			n += 1
			local cf, s = d.CFrame, d.Size
			top = math.max(top, cf.Position.Y + math.abs(cf.RightVector.Y) * s.X / 2 + math.abs(cf.UpVector.Y) * s.Y / 2
				+ math.abs(cf.LookVector.Y) * s.Z / 2)
		end
	end
	out.kinds[kind] = n
	out.tall[kind] = top
end
out.unknown = not pcall(WorldKit.dressing, "spaceship", CFrame.new())
return { ok = true, detail = game:GetService("HttpService"):JSONEncode(out) }
"""


@needs_headless
def test_every_dressing_kind_builds_and_unknown_kinds_fail_loudly(tmp_path):
    got = _run(tmp_path, DRESSING)
    for kind in ("stall", "balloon_cluster", "string_lights", "bench", "tree", "lamp", "sign", "fence", "popcorn_cart",
                 "flower_garden", "picnic", "mini_golf", "queue_fence", "kiddie_ride", "balloon_arch"):
        assert got["kinds"].get(kind, 0) >= 3, (kind, got)
    # what goes under a course stays under the 6-stud ceiling
    for kind in ("flower_garden", "picnic", "mini_golf", "queue_fence", "kiddie_ride", "flower_bed", "bench"):
        assert got["tall"][kind] <= 6, (kind, got["tall"][kind])
    assert got["unknown"]


# A game that never calls WorldKit.client(): the server moves the rides a player is near (30 times a second) and
# leaves the far ones still.
FALLBACK = """
local WorldKit = require(game.ReplicatedStorage.Kit.WorldKit)
local Players = game:GetService("Players")
local hrp
for _ = 1, 100 do
	local pl = Players:GetPlayers()[1]
	hrp = pl and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
	if hrp then break end
	task.wait(0.1)
end
local function spinRoot(m)
	for _, d in m:GetDescendants() do
		if d:GetAttribute("WKMotion") == "spin" then return d end
	end
end
local near = spinRoot(WorldKit.landmark("carousel", CFrame.new(hrp.Position + Vector3.new(80, -3, 0))))
local far = spinRoot(WorldKit.landmark("carousel", CFrame.new(hrp.Position + Vector3.new(3000, -3, 0))))
task.wait(1) -- the first steps put a ride where the shared clock says it is
local a, b = near.CFrame, far.CFrame
task.wait(1)
local turned = math.acos(math.clamp(a.LookVector:Dot(near.CFrame.LookVector), -1, 1))
return { ok = true, detail = game:GetService("HttpService"):JSONEncode({ player = hrp ~= nil, nearTurned = turned,
	farStill = far.CFrame == b and far.CFrame == far:GetAttribute("WKRest") }) }
"""


@needs_headless
def test_without_a_client_the_server_moves_only_the_rides_near_players(tmp_path):
    got = _run(tmp_path, FALLBACK)
    assert got["player"]
    assert got["nearTurned"] > 0.1  # the carousel turns 0.32 rad/s (the engine's server clock is whole wall seconds
    # plus the simulated time, so the exact angle can jump a second's worth)
    assert got["farStill"]
