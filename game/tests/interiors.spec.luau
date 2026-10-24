--!strict
-- Interiors/Plan: rect maths, the placer, room splitting and the procedural school plan.
local Spec = require("./Spec")
local Plan = require("../ServerScriptService/Lib/Map/Interiors/Plan")

Spec.test("overlap: touching rects don't overlap, pad makes them", function()
	local a = Plan.span(0, 0, 2, 2)
	local b = Plan.span(2, 0, 4, 2)
	Spec.eq(Plan.overlap(a, b), false, "touching")
	Spec.eq(Plan.overlap(a, b, 0.1), true, "padded")
	Spec.eq(Plan.overlap(a, Plan.rect(1, 1, 0.5, 0.5)), true, "inside")
end)

Spec.test("placer refuses keep-outs and anything already taken", function()
	local p = Plan.placer({ Plan.span(0, 0, 4, 4) })
	Spec.eq(p:take(Plan.span(1, 1, 2, 2)), false, "in keep-out")
	Spec.eq(p:take(Plan.span(5, 0, 7, 2)), true, "clear")
	Spec.eq(p:take(Plan.span(6, 1, 8, 3)), false, "overlaps taken")
	p:keep(Plan.span(10, 0, 12, 2))
	Spec.eq(p:fits(Plan.span(11, 1, 13, 3)), false, "new keep-out")
end)

Spec.test("split fills the span, honours minimums and drops what can't fit", function()
	local rooms = Plan.split(0, 50, {
		{ kind = "a", weight = 1, min = 20, keep = true },
		{ kind = "b", weight = 1, min = 20 },
		{ kind = "c", weight = 1, min = 20, keep = true },
	}, nil)
	Spec.eq(#rooms, 2, "one dropped")
	Spec.eq(rooms[1].kind, "a")
	Spec.eq(rooms[2].kind, "c")
	Spec.near(rooms[1].x0, 0)
	Spec.near(rooms[2].x1, 50)
	Spec.near(rooms[1].x1, rooms[2].x0)
end)

Spec.test("split nudges walls off windows", function()
	local rooms = Plan.split(0, 40, { { kind = "a", weight = 1, min = 10 }, { kind = "b", weight = 1, min = 10 } }, { { 18, 22 } })
	local wall = rooms[1].x1
	Spec.eq(wall <= 15.5 or wall >= 24.5, true, `wall at {wall} sits on the window`)
end)

Spec.test("grid centres cells inside the area", function()
	local cells = Plan.grid(0, 10, 0, 10, 3, 4)
	Spec.eq(#cells, 6, "3 x 2")
	for _, c in cells do
		Spec.eq(c[1] > 0 and c[1] < 10 and c[2] > 0 and c[2] < 10, true, "inside")
	end
end)

for _, w in { 90, 110, 130 } do
	Spec.test(`school plan w={w}: rooms tile each floor, walls clear windows and stairs`, function()
		local d = 40
		local p = Plan.school(w, d, 2)
		Spec.eq(#p.floors, 2, "floors")
		local windows = Plan.schoolWindows(w)
		for s, f in p.floors do
			local rooms = f.rooms
			Spec.eq(#rooms >= 3, true, `floor {s} rooms`)
			Spec.near(rooms[1].x0, p.stairEdge, 1e-6, "starts at the stair hall")
			Spec.near(rooms[#rooms].x1, w / 2 - 0.5, 1e-6, "ends at the east wall")
			for i, r in rooms do
				Spec.eq(r.x1 - r.x0 >= 9.99, true, `{r.kind} too narrow`)
				Spec.eq(r.z1 <= f.wallZ - 0.5 + 1e-6, true, "rooms stop at the corridor wall")
				if i > 1 then
					Spec.near(r.x0, rooms[i - 1].x1, 1e-6, "contiguous")
					for _, win in windows do
						Spec.eq(r.x0 <= win[1] - 0.5 or r.x0 >= win[2] + 0.5, true, `wall at {r.x0} on a window`)
					end
				end
				if r.kind ~= "lobby" then
					Spec.eq(r.door ~= nil and r.door > r.x0 + 2.5 and r.door < r.x1 - 2.5, true, `{r.kind} doorway`)
				end
			end
		end
		-- the lobby holds both front doors (BlockFiller: at 0.47 w and 0.53 w)
		local lobby
		for _, r in p.floors[1].rooms do
			if r.kind == "lobby" then
				lobby = r
			end
		end
		Spec.eq(lobby ~= nil, true, "lobby")
		Spec.eq(lobby.x0 < -0.03 * w - 2 and lobby.x1 > 0.03 * w + 2, true, "front doors in the lobby")
		Spec.eq(#p.fires, 8, "8 fire starts (school_alarm fires.count)")
		local kids, teachers = 0, 0
		local seen = {}
		for _, r in p.rescues do
			Spec.eq(seen[r.id], nil, `duplicate {r.id}`)
			seen[r.id] = true
			if r.variant == "Kid" then
				kids += 1
			elseif r.variant == "Teacher" then
				teachers += 1
			end
			Spec.eq(r.x > p.stairEdge and r.x < w / 2 - 0.5 and r.z > 0.5 and r.z < d - 0.5, true, `{r.id} inside, off the stairs`)
		end
		Spec.eq(kids >= 10, true, `8 kids + 2 spares, got {kids}`)
		Spec.eq(teachers, 1, "teacher")
		local science = false
		for _, r in p.floors[2].rooms do
			science = science or r.kind == "science"
		end
		Spec.eq(science, true, "a science lab upstairs for the gas tank")
		-- hero furniture goes on every fire spot: no rescue spot (or the gas tank) underneath one
		for _, f in p.fires do
			for _, r in p.rescues do
				if r.floor == f.floor then
					local d = math.sqrt((r.x - f.x) ^ 2 + (r.z - f.z) ^ 2)
					Spec.eq(d >= 3.5, true, `{r.id} {d} studs from fire {f.id} ({f.room})`)
				end
			end
			if p.gasTank.floor == f.floor then
				Spec.eq(math.abs(p.gasTank.x - f.x) + math.abs(p.gasTank.z - f.z) >= 4, true, `gas tank on fire {f.id}`)
			end
		end
	end)
end

return Spec.finish()
