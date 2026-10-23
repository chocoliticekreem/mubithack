--!strict
-- Pathfind: road graph decoding, nearest node / road snap, A*, route polylines, turn hints, minimap maths.
local Spec = require("./Spec")
local Pathfind = require("../StarterPlayerScripts/ClientLib/Pathfind")

-- A 3x3 street grid, 100 studs apart:
--   a1 - a2 - a3      (z = 0)
--   |    |    |
--   b1 - b2 - b3      (z = 100)
--   |         |
--   c1 - c2 - c3      (z = 200)       (b2 - c2 is missing: a dead end at b2's south)
local function grid()
	local nodes = {}
	for r, row in { "a", "b", "c" } do
		for c = 1, 3 do
			nodes[row .. c] = { (c - 1) * 100, 0, (r - 1) * 100 }
		end
	end
	local edges = {
		{ "a1", "a2" }, { "a2", "a3" }, { "b1", "b2" }, { "b2", "b3" }, { "c1", "c2" }, { "c2", "c3" },
		{ "a1", "b1" }, { "b1", "c1" }, { "a2", "b2" }, { "a3", "b3" }, { "b3", "c3" },
	}
	return Pathfind.build(nodes, edges)
end

Spec.test("build keeps nodes and undirected edges, drops junk", function()
	local g = Pathfind.build({ a = { 0, 0, 0 }, b = { x = 10, y = 0, z = 0 }, c = { X = 0, Y = 0, Z = 10 } }, {
		{ "a", "b" },
		{ a = "b", b = "a" }, -- duplicate
		{ A = "a", B = "c" },
		{ "a", "zzz" }, -- unknown
		{ "a", "a" }, -- self loop
	})
	Spec.eq(#g.ids, 3)
	Spec.eq(#g.edges, 2)
	Spec.eq(#g.adj.a, 2)
	Spec.eq(#g.adj.b, 1)
end)

Spec.test("decode handles numeric ids, arrays and 0-based edges", function()
	local g = Pathfind.decode({ nodes = { { 0, 0, 0 }, { 10, 0, 0 }, { 20, 0, 0 } }, edges = { { 0, 1 }, { 1, 2 } } })
	Spec.truthy(g)
	local gg = g :: Pathfind.Graph
	Spec.eq(#gg.edges, 2)
	Spec.eq(#gg.adj["2"], 2)
	local g2 = Pathfind.decode({ nodes = { { id = 7, pos = { 1, 2, 3 } } }, edges = {} }) :: Pathfind.Graph
	Spec.eq(g2.pos["7"].z, 3)
	Spec.eq(Pathfind.decode({ nodes = {}, edges = {} }), nil)
	Spec.eq(Pathfind.decode("nope"), nil)
end)

Spec.test("nearestNode picks the closest node in the XZ plane", function()
	local g = grid()
	local id, d = Pathfind.nearestNode(g, 190, 95)
	Spec.eq(id, "b3")
	Spec.near(d, math.sqrt(10 * 10 + 5 * 5))
	local id2 = Pathfind.nearestNode(g, -50, 260)
	Spec.eq(id2, "c1")
end)

Spec.test("nearestOnEdge snaps onto the closest road segment", function()
	local g = grid()
	local s = Pathfind.nearestOnEdge(g, 40, 8) :: Pathfind.Snap
	Spec.truthy(s)
	Spec.near(s.x, 40)
	Spec.near(s.z, 0)
	Spec.near(s.dist, 8)
	Spec.truthy((s.a == "a1" and s.b == "a2") or (s.a == "a2" and s.b == "a1"))
end)

Spec.test("astar finds the shortest path and respects missing roads", function()
	local g = grid()
	local path, cost = Pathfind.astar(g, "a1", "c3")
	Spec.truthy(path)
	Spec.near(cost, 400)
	-- b2 to c2: no direct road, must go around (b2-b1-c1-c2 = 300, or b2-b3-c3-c2 = 300)
	local p2, c2 = Pathfind.astar(g, "b2", "c2")
	Spec.truthy(p2)
	Spec.near(c2, 300)
	Spec.eq((p2 :: { string })[1], "b2")
	Spec.eq((p2 :: { string })[#(p2 :: { string })], "c2")
	local same, c0 = Pathfind.astar(g, "a1", "a1")
	Spec.eq(#(same :: { string }), 1)
	Spec.eq(c0, 0)
end)

Spec.test("astar returns nil when the goal is unreachable or unknown", function()
	local g = Pathfind.build({ a = { 0, 0, 0 }, b = { 10, 0, 0 }, c = { 50, 0, 0 } }, { { "a", "b" } })
	local p, c = Pathfind.astar(g, "a", "c")
	Spec.eq(p, nil)
	Spec.eq(c, math.huge)
	Spec.eq((Pathfind.astar(g, "a", "nope")), nil)
end)

Spec.test("route snaps both ends onto roads and returns a polyline", function()
	local g = grid()
	local poly, cost = Pathfind.route(g, { x = 50, y = 0, z = -6 }, { x = 200, y = 0, z = 150 })
	Spec.truthy(poly)
	local pl = poly :: { Pathfind.P }
	Spec.near(pl[1].x, 50)
	Spec.near(pl[1].z, 0)
	Spec.near(pl[#pl].x, 200)
	Spec.near(pl[#pl].z, 150)
	-- 50 to a3 along the top (150) then down to z=150 (150)
	Spec.near(cost, 300)
	Spec.near(Pathfind.length(pl), 300)
end)

Spec.test("route on a single road segment is a straight line", function()
	local g = grid()
	local poly, cost = Pathfind.route(g, { x = 10, y = 0, z = 0 }, { x = 90, y = 0, z = 0 })
	Spec.eq(#(poly :: { Pathfind.P }), 2)
	Spec.near(cost, 80)
end)

Spec.test("project and samples walk along the polyline", function()
	local poly = { { x = 0, y = 0, z = 0 }, { x = 100, y = 0, z = 0 }, { x = 100, y = 0, z = 100 } }
	local along, d = Pathfind.project(poly, 40, 5)
	Spec.near(along, 40)
	Spec.near(d, 5)
	local along2 = Pathfind.project(poly, 105, 50)
	Spec.near(along2, 150)
	local s = Pathfind.samples(poly, 35, 20, 100)
	Spec.near(s[1].along, 40)
	Spec.near(s[1].dx, 1)
	Spec.eq(#s, 8) -- 40, 60, ... 180
	Spec.near(s[#s].dz, 1)
	Spec.eq(#Pathfind.samples(poly, 0, 20, 3), 3)
end)

Spec.test("nextTurn reports left / right with the distance to the corner", function()
	-- heading east (+X) then turning to +Z: looking east, +Z (south) is on the right
	local right = { { x = 0, y = 0, z = 0 }, { x = 100, y = 0, z = 0 }, { x = 100, y = 0, z = 100 } }
	local kind, dist = Pathfind.nextTurn(right, 20)
	Spec.eq(kind, "right")
	Spec.near(dist, 80)
	local left = { { x = 0, y = 0, z = 0 }, { x = 100, y = 0, z = 0 }, { x = 100, y = 0, z = -100 } }
	Spec.eq((Pathfind.nextTurn(left, 0)), "left")
	-- past the corner: no more turns, distance to the end
	local none, rest = Pathfind.nextTurn(right, 150)
	Spec.eq(none, nil)
	Spec.near(rest, 50)
	-- a gentle bend is not a turn
	local bend = { { x = 0, y = 0, z = 0 }, { x = 100, y = 0, z = 0 }, { x = 200, y = 0, z = 20 } }
	Spec.eq((Pathfind.nextTurn(bend, 0)), nil)
end)

Spec.test("minimap maths: heading-up rotation and rim clamp", function()
	Spec.near(Pathfind.heading(0, -1), 0)
	Spec.near(Pathfind.heading(1, 0), math.pi / 2)
	-- facing north: a point 10 studs north is straight up
	local x, y = Pathfind.toMap(0, -10, 0, 2)
	Spec.near(x, 0)
	Spec.near(y, -20)
	-- facing east: east is up, south is right
	local ex, ey = Pathfind.toMap(10, 0, math.pi / 2, 1)
	Spec.near(ex, 0)
	Spec.near(ey, -10)
	local sx, sy = Pathfind.toMap(0, 10, math.pi / 2, 1)
	Spec.near(sx, 10)
	Spec.near(sy, 0)
	local cx, cy, clamped = Pathfind.clampRadius(30, 40, 10)
	Spec.near(cx, 6)
	Spec.near(cy, 8)
	Spec.eq(clamped, true)
	Spec.eq(select(3, Pathfind.clampRadius(3, 4, 10)), false)
	Spec.eq(Pathfind.compass(0, -5), "N")
	Spec.eq(Pathfind.compass(5, 5), "SE")
end)

return Spec.finish()
