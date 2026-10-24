-- check: Every stage has exactly one checkpoint, and its Stage attribute is the stage's number
-- covers: genre obby: every stage has exactly one checkpoint with the right Stage attribute
-- consumer: ReplicatedStorage/Kit/ObbyKit.luau:"if n == d.stage + 1 or opts0.allowSkip then"
local CS = game:GetService("CollectionService")
local models = CS:GetTagged("ObbyStage")
if #models == 0 then
	return { ok = false, detail = "no ObbyStage models: the course was never built" }
end
local bad, seen = {}, {}
for _, m in models do
	local n = m:GetAttribute("Stage")
	local cps = {}
	for _, d in m:GetDescendants() do
		if CS:HasTag(d, "Checkpoint") then
			table.insert(cps, d)
		end
	end
	if #cps ~= 1 then
		table.insert(bad, string.format("%s has %d checkpoints", m.Name, #cps))
	elseif cps[1]:GetAttribute("Stage") ~= n then
		table.insert(bad, string.format("%s: its checkpoint says Stage %s", m.Name, tostring(cps[1]:GetAttribute("Stage"))))
	end
	if n ~= nil and seen[n] then
		table.insert(bad, "stage " .. tostring(n) .. " is built twice")
	end
	if n ~= nil then
		seen[n] = true
	end
end
for n = 1, #models do
	if not seen[n] then
		table.insert(bad, "stage " .. n .. " is missing")
	end
end
return {
	ok = #bad == 0,
	detail = string.format("%d stages: %s", #models, if #bad == 0 then "one checkpoint each, Stage attributes match"
		else table.concat(bad, "; ", 1, math.min(#bad, 8))),
}
