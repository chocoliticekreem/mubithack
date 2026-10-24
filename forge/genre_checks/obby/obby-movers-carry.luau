-- check: A player standing on a sliding platform or a turntable is carried along and stays on it
-- covers: genre obby: moving platforms and turntables carry the player (the kit's single Heartbeat driver moves them and sets their velocity)
-- needs: studio
-- consumer: ReplicatedStorage/Kit/ObbyKit.luau:"part.AssemblyLinearVelocity = move * (math.pi / period * math.sin(a))"
local Players = game:GetService("Players")
local CS = game:GetService("CollectionService")
local best, bestScore
for _, m in CS:GetTagged("Obstacle") do
	local kind = m:GetAttribute("Kind")
	for _, d in (if kind == "moving" or kind == "turntable" then m:GetDescendants() else {}) do
		if d:IsA("BasePart") and CS:HasTag(d, "ObbyStandable") then
			local mv = d:GetAttribute("Move")
			local slide = if typeof(mv) == "Vector3" then math.abs(mv.X) + math.abs(mv.Z) else 0
			local score = if slide >= 4 then 3 elseif kind == "turntable" then 2 else 1
			if not bestScore or score > bestScore then
				best, bestScore = d, score
			end
		end
	end
end
if not best then
	return { ok = true, detail = "the course has no moving platforms or turntables" }
end
local ride = best
local p = forge.waitFor(function()
	local pl = Players:GetPlayers()[1]
	return pl and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart") and pl
end, 5)
if not p then
	error("setup: no player character within 5 s")
end
local kind = ride:FindFirstAncestorOfClass("Model"):GetAttribute("Kind")
local round = ride:IsA("Part") and ride.Shape == Enum.PartType.Cylinder
local up = if round then ride.Size.X / 2 else ride.Size.Y / 2
local half = if round then ride.Size.Y / 2 else math.min(ride.Size.X, ride.Size.Z) / 2
local function horizontal(pos: Vector3): number
	local rel = ride.CFrame:PointToObjectSpace(pos)
	return if round then math.sqrt(rel.Y ^ 2 + rel.Z ^ 2) else math.max(math.abs(rel.X), math.abs(rel.Z))
end
local char = p.Character
local hrp = char.HumanoidRootPart
local home = char:GetPivot()
local start = Vector3.new(if round then half / 2 else 0, up + 3, 0)
char:PivotTo(CFrame.new(ride.Position + start))
task.wait(1)
char:PivotTo(CFrame.new(ride.Position + start))
task.wait(0.3)
local from = ride.CFrame
local worst, fell, moved, turned = 0, false, 0, 0
for _ = 1, 20 do
	task.wait(0.2)
	worst = math.max(worst, horizontal(hrp.Position) / half)
	moved = math.max(moved, (ride.Position - from.Position).Magnitude)
	turned = math.max(turned, math.deg(math.acos(math.clamp(ride.CFrame.LookVector:Dot(from.LookVector), -1, 1))))
	if hrp.Position.Y < ride.Position.Y then
		fell = true
	end
end
char:PivotTo(home)
local motion = moved >= 1 or turned >= 15
return {
	ok = motion and not fell and worst < 1,
	detail = string.format("rode the %s for 4 s (it moved %.1f studs, turned %.0f deg): the player stayed within %.0f%% of its edge, fell: %s",
		tostring(kind), moved, turned, worst * 100, tostring(fell)),
}
