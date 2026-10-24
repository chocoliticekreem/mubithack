-- check: The course has every stage the spec plans: one checkpoint per stage, numbered 1 to N
-- covers: genre obby: stage count matches the spec (spec levels: zones x stages per zone)
-- consumer: ReplicatedStorage/Kit/ObbyKit.luau:"course.stages = math.max(course.stages, n)"
local CS = game:GetService("CollectionService")
local RS = game:GetService("ReplicatedStorage")
local expected = __EXPECTED_STAGES__
if not workspace:FindFirstChild("Obby") then
	return { ok = false, detail = "no workspace.Obby: ObbyKit.start() never built the course" }
end
local stages = {}
for _, cp in CS:GetTagged("Checkpoint") do
	local n = cp:GetAttribute("Stage")
	if type(n) == "number" then
		stages[n] = true
	end
end
local built, top = 0, 0
for n in stages do
	built += 1
	top = math.max(top, n)
end
local data = 0
local levels = RS:FindFirstChild("Levels")
for _, m in (if levels then levels:GetChildren() else {}) do
	if m:IsA("ModuleScript") then
		local ok, z = pcall(require, m)
		if ok and type(z) == "table" and type(z.stages) == "table" then
			data += #z.stages
		end
	end
end
local want = if expected > 0 then expected else data
return {
	ok = want > 0 and built == want and top == want and data == want,
	detail = string.format("checkpoints for %d stages (highest %d), level data has %d stages, the spec plans %s",
		built, top, data, if expected > 0 then tostring(expected) else "(not set)"),
}
