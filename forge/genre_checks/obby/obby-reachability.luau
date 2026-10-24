-- check: Every stage passes the reachability rules, both in the level data and in the built course
-- covers: genre obby: every stage passes the live reachability rules (LevelBuilder.validate on the data, audit on the parts)
-- consumer: ReplicatedStorage/Kit/ObbyKit.luau:"local errors = LevelBuilder.validate(st, n)"
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local kit = RS:FindFirstChild("Kit") and RS.Kit:FindFirstChild("ObbyKit")
if not kit then
	error("setup: no ReplicatedStorage.Kit.ObbyKit")
end
local K = require(kit)
local errors, stages = {}, 0
local levels = RS:FindFirstChild("Levels")
for _, m in (if levels then levels:GetChildren() else {}) do
	if m:IsA("ModuleScript") then
		local ok, z = pcall(require, m)
		if not ok or type(z) ~= "table" then
			table.insert(errors, m.Name .. " does not load: " .. tostring(z))
		else
			stages += #(z.stages or {})
			for _, e in K.LevelBuilder.validateZone(z) do
				table.insert(errors, "data: " .. e)
			end
		end
	end
end
if stages == 0 then
	return { ok = false, detail = "no level data in ReplicatedStorage.Levels" }
end
for _, e in K.LevelBuilder.audit() do
	table.insert(errors, "built: " .. e)
end
local invalid = 0
for _, m in CS:GetTagged("ObbyStage") do
	if m:GetAttribute("Valid") == false then
		invalid += 1
	end
end
return {
	ok = #errors == 0 and invalid == 0 and #CS:GetTagged("ObbyStage") == stages,
	detail = string.format("%d stages in the data, %d built; %d reachability problems, %d stages flagged at build%s", stages,
		#CS:GetTagged("ObbyStage"), #errors, invalid, if #errors > 0 then ": " .. table.concat(errors, " | ", 1, math.min(#errors, 5)) else ""),
}
