-- check: A player who falls off the course is put back on their checkpoint within a few seconds
-- covers: genre obby: falling below the stage returns you to your checkpoint (no long falls, no walking back)
-- needs: studio
-- consumer: ReplicatedStorage/Kit/ObbyKit.luau:"if y < info.minTop - FALL_DEPTH and not d.returning then"
local Players = game:GetService("Players")
local CS = game:GetService("CollectionService")
local p = forge.waitFor(function()
	local pl = Players:GetPlayers()[1]
	return pl and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart") and pl
end, 5)
if not p then
	error("setup: no player character within 5 s")
end
local stage = p:GetAttribute("Stage") or 0
local home
for _, cp in CS:GetTagged(if stage > 0 then "Checkpoint" else "ObbyStart") do
	if stage == 0 or cp:GetAttribute("Stage") == stage then
		home = cp
	end
end
if not home then
	error("setup: no checkpoint or start pad for stage " .. stage)
end
local char = p.Character
local hrp = char.HumanoidRootPart
char:PivotTo(home.CFrame * CFrame.new(0, -45, -20))
local back = forge.waitFor(function()
	return (hrp.Position - home.Position).Magnitude < 12 and hrp.Position.Y > home.Position.Y
end, 4)
local dist = (hrp.Position - home.Position).Magnitude
if not back then
	char:PivotTo(home.CFrame * CFrame.new(0, 4, 0))
end
return {
	ok = back ~= nil,
	detail = string.format("dropped 45 studs under the course; %s (%.1f studs from checkpoint %d)",
		if back then "put back on the checkpoint" else "still not back after 4 s", dist, stage),
}
