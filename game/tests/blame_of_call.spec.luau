--!strict
-- BlameOfCall: the results screen's BLAME OF THE CALL pick.
local Spec = require("./Spec")
local B = require("../StarterPlayerScripts/Lib/BlameOfCall")

local function row(userId: number, name: string, over: { [string]: any }?): any
	local r: { [string]: any } = { userId = userId, helmet = 1, name = name, pairs = {} }
	for k, v in over or {} do
		r[k] = v
	end
	return r
end

Spec.test("a knock-out beats a few hose sprays and names both players", function()
	local p = B.pick({
		row(1, "Bob", { pairs = { ["hose:2"] = 5 } }),
		row(2, "Alice", { pairs = { ["down:1"] = 1 } }),
	}, {})
	Spec.eq(p and p.userId, 2)
	Spec.eq(p and p.kind, "down")
	Spec.eq(p and p.story, "Alice knocked out Bob. Oops.")
end)

Spec.test("lots of spraying wins when nothing else happened", function()
	local p = B.pick({ row(1, "Bob", { pairs = { ["hose:2"] = 3 } }), row(2, "Alice") }, {})
	Spec.eq(p and p.kind, "hose")
	Spec.eq(p and p.story, "Bob sprayed Alice 3 times. Alice is very clean now.")
end)

Spec.test("two sprays are not enough to be a story", function()
	local p = B.pick({ row(1, "Bob", { pairs = { ["hose:2"] = 2 } }), row(2, "Alice") }, {})
	Spec.eq(p, nil)
end)

Spec.test("a backdraft you caused is the top story", function()
	local p = B.pick({
		row(1, "Bob", { backdraftsCaused = 1 }),
		row(2, "Alice", { pairs = { ["slap:1"] = 2 } }),
	}, {})
	Spec.eq(p and p.kind, "backdraftsCaused")
	Spec.eq(p and p.title, "Opened The Wrong Door")
end)

Spec.test("Studio test players (negative ids) and players who left", function()
	local p = B.pick({ row(-1, "Player1", { pairs = { ["slap:-2"] = 1, ["zap:999"] = 0 } }) }, {})
	Spec.eq(p and p.story, "Player1 slapped a teammate right in the helmet.")
end)

Spec.test("solo yeets", function()
	local p = B.pick({ row(7, "Kim", { yeets = 3 }) }, {})
	Spec.eq(p and p.story, "Kim YEETED 3 people to safety!")
end)

Spec.test("ties go to the lower userId", function()
	local p = B.pick({ row(5, "E", { yeets = 1 }), row(3, "C", { yeets = 1 }) }, {})
	Spec.eq(p and p.userId, 3)
end)

Spec.test("nothing between people: first roast award (not the scapegoat line)", function()
	local awards = {
		{ id = "panda", title = "Panda Whisperer", userId = 1, value = 1, blurb = "Carried the panda.", blame = false },
		{ id = "arsonist", title = "Accidental Arsonist", userId = 1, value = 3, blurb = "Started 3 fires.", blame = true },
		{ id = "scapegoat", title = "Scapegoat", userId = 1, value = 0, blurb = "You are to blame.", blame = true },
	}
	local p = B.pick({ row(1, "Bob") }, awards)
	Spec.eq(p and p.kind, "award")
	Spec.eq(p and p.title, "Accidental Arsonist")
	Spec.eq(p and p.story, "Bob: Started 3 fires.")
	Spec.eq(B.pick({ row(1, "Bob") }, { awards[3] }), nil)
	Spec.eq(B.pick(nil, nil), nil)
end)

return Spec.finish()
