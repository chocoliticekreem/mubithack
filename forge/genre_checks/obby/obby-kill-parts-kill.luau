-- check: Touching a KillPart kills the player, who then respawns on their own checkpoint
-- covers: genre obby: kill parts kill (a temporary part tagged KillPart, wired by the kit's tag handler)
-- needs: studio
-- consumer: ReplicatedStorage/Kit/ObbyKit.luau:"hum.Health = 0"
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
local inCourse = #CS:GetTagged("KillPart")
local kp = Instance.new("Part")
kp.Name = "ForgeCheckKillPart"
kp.Anchored, kp.Size = true, Vector3.new(8, 1, 8)
kp.Color, kp.Material = Color3.fromRGB(255, 45, 45), Enum.Material.Neon
kp.CFrame = home.CFrame * CFrame.new(0, 40, 0)
kp.Parent = workspace
CS:AddTag(kp, "KillPart")
local old = p.Character
local hum = old:FindFirstChildOfClass("Humanoid")
old:PivotTo(kp.CFrame * CFrame.new(0, 3, 0))
local died = forge.waitFor(function()
	return hum.Health <= 0
end, 4)
kp:Destroy()
if not died then
	old:PivotTo(home.CFrame * CFrame.new(0, 4, 0))
	return { ok = false, detail = "stood on a KillPart for 4 s and did not die" }
end
local char = forge.waitFor(function()
	local c = p.Character
	return c ~= old and c and c:FindFirstChild("HumanoidRootPart") and c
end, 9)
if not char then
	return { ok = false, detail = "died, but no respawn within 9 s" }
end
task.wait(1)
local dist = (char.HumanoidRootPart.Position - home.Position).Magnitude
return {
	ok = dist < 12,
	detail = string.format("died on the KillPart and respawned %.1f studs from checkpoint %d (the course has %d kill parts)",
		dist, stage, inCourse),
}
