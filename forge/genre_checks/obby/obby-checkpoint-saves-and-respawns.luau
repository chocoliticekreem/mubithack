-- check: Touching the next checkpoint saves the Stage, and after dying the player respawns on that checkpoint
-- covers: genre obby: touching a checkpoint saves Stage and respawn returns there (irreversible: advances the stage)
-- needs: studio
-- consumer: ReplicatedStorage/Kit/ObbyKit.luau:"local cf = spawnFrame((data[player] and data[player].stage) or 0)"
local Players = game:GetService("Players")
local CS = game:GetService("CollectionService")
local p = forge.waitFor(function()
	local pl = Players:GetPlayers()[1]
	return pl and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart") and pl
end, 5)
if not p then
	error("setup: no player character within 5 s")
end
local ls = p:FindFirstChild("leaderstats")
local sv = ls and ls:FindFirstChild("Stage")
if not sv then
	return { ok = false, detail = "the player has no leaderstats.Stage" }
end
local before = sv.Value
local target
for _, cp in CS:GetTagged("Checkpoint") do
	if cp:GetAttribute("Stage") == before + 1 then
		target = cp
	end
end
if not target then
	error("setup: no checkpoint for stage " .. (before + 1))
end
p.Character:PivotTo(target.CFrame * CFrame.new(0, target.Size.Y / 2 + 3, 0))
local reached = forge.waitFor(function()
	return sv.Value == before + 1
end, 4)
if not reached then
	return { ok = false, detail = string.format("stood on checkpoint %d for 4 s but Stage stayed %d", before + 1, sv.Value) }
end
local saved = forge.waitFor(function()
	return p:GetAttribute("SavedStage") == before + 1
end, 3)
local old = p.Character
old:FindFirstChildOfClass("Humanoid").Health = 0
local char = forge.waitFor(function()
	local c = p.Character
	return c ~= old and c and c:FindFirstChild("HumanoidRootPart") and c
end, 9)
if not char then
	return { ok = false, detail = "no respawn within 9 s of dying" }
end
task.wait(1)
local hrp = char.HumanoidRootPart
local rel = target.CFrame:PointToObjectSpace(hrp.Position)
local onPad = math.abs(rel.X) <= target.Size.X / 2 + 1 and math.abs(rel.Z) <= target.Size.Z / 2 + 1 and rel.Y > 0 and rel.Y < 8
return {
	ok = saved ~= nil and onPad,
	detail = string.format("Stage %d -> %d, SavedStage %s; respawned at (%.1f, %.1f, %.1f) from checkpoint %d's center",
		before, sv.Value, tostring(p:GetAttribute("SavedStage")), rel.X, rel.Y, rel.Z, before + 1),
}
