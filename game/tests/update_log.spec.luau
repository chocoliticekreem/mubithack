--!strict
-- Config/UpdateLog: the WHAT'S NEW list stays well-formed as entries get added (newest first).
local Spec = require("./Spec")
local UpdateLog = require("../ReplicatedStorage/Config/UpdateLog")

Spec.test("every entry has a unique version, a date, a title and short items", function()
	Spec.truthy(#UpdateLog.Entries >= 1, "at least one entry")
	local seen: { [string]: boolean } = {}
	for i, e in UpdateLog.Entries do
		Spec.eq(type(e.version), "string")
		Spec.truthy(string.match(e.version, "^%d%d%d%d%.%d%d%.%d%d") ~= nil, `entry {i}: version is YYYY.MM.DD`)
		Spec.truthy(#e.version <= 32, "fits the profile field")
		Spec.eq(seen[e.version], nil, `duplicate version {e.version}`)
		seen[e.version] = true
		Spec.truthy(type(e.date) == "string" and e.date ~= "", "date")
		Spec.truthy(type(e.title) == "string" and e.title ~= "", "title")
		Spec.truthy(#e.items >= 1, "items")
		for _, line in e.items do
			Spec.eq(type(line), "string")
			Spec.truthy(#line <= 120, `item too long: {line}`)
			Spec.truthy((string.byte(line, 1) or 0) >= 0xE2, `item should start with an emoji: {line}`)
		end
	end
end)

Spec.test("entries are newest first", function()
	for i = 2, #UpdateLog.Entries do
		Spec.truthy(UpdateLog.Entries[i - 1].version > UpdateLog.Entries[i].version, "newest first")
	end
end)

Spec.test("latest / find / unseen", function()
	local newest = UpdateLog.latest() :: any
	Spec.eq(newest, UpdateLog.Entries[1])
	Spec.eq(UpdateLog.find(newest.version), newest)
	Spec.eq(UpdateLog.isKnown(newest.version), true)
	Spec.eq(UpdateLog.isKnown("1999.01.01"), false)
	Spec.eq(UpdateLog.isKnown(5), false)
	Spec.eq(UpdateLog.unseen(""), true)
	Spec.eq(UpdateLog.unseen(nil), true)
	Spec.eq(UpdateLog.unseen(newest.version), false)
end)

return Spec.finish()
