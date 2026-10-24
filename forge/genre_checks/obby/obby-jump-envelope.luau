-- check: The game's character physics match the validator's, and a real runner clears its jump limits
-- covers: genre obby: live reachability: an R15 runner with this game's walk speed, jump height and gravity lands a 9.5 stud gap at rise 0 and a 7 stud gap at rise 6
-- needs: studio
-- consumer: ReplicatedStorage/Kit/ObbyKit.luau:"StarterPlayer.CharacterJumpHeight = R.JUMP_HEIGHT"
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SP = game:GetService("StarterPlayer")
local RS = game:GetService("ReplicatedStorage")
local kit = RS:FindFirstChild("Kit") and RS.Kit:FindFirstChild("ObbyKit")
if not kit then
	error("setup: no ReplicatedStorage.Kit.ObbyKit")
end
local R = require(kit).Rules
local physics = string.format("gravity %.1f, walk %g, %s", workspace.Gravity, SP.CharacterWalkSpeed,
	if SP.CharacterUseJumpPower then "jump power " .. SP.CharacterJumpPower else "jump height " .. SP.CharacterJumpHeight)
local matches = math.abs(workspace.Gravity - R.GRAVITY) < 0.5 and SP.CharacterWalkSpeed >= R.WALK_SPEED
	and not SP.CharacterUseJumpPower and SP.CharacterJumpHeight >= R.JUMP_HEIGHT - 0.01
local npc = Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
npc.Name = "ForgeCheckRunner"
local hum = npc:FindFirstChildOfClass("Humanoid")
hum.UseJumpPower, hum.JumpHeight, hum.JumpPower = SP.CharacterUseJumpPower, SP.CharacterJumpHeight, SP.CharacterJumpPower
hum.WalkSpeed = SP.CharacterWalkSpeed
local hrp = npc:FindFirstChild("HumanoidRootPart")
npc.Parent = workspace
pcall(function()
	hrp:SetNetworkOwner(nil)
end)
local Y, X0 = 1500, 3000
local function part(size, cf)
	local q = Instance.new("Part")
	q.Name, q.Anchored, q.Size, q.CFrame = "ForgeCheckJumpRig", true, size, cf
	q.Parent = workspace
	return q
end
local function trial(gap, rise)
	local a = part(Vector3.new(10, 1, 10), CFrame.new(X0, Y, 0))
	local bx = X0 + 5 + gap + 4
	local b = part(Vector3.new(8, 1, 8), CFrame.new(bx, Y + rise, 0))
	npc:PivotTo(CFrame.new(X0 - 3, Y + 3.5, 0) * CFrame.Angles(0, -math.pi / 2, 0))
	task.wait(0.6)
	hum:MoveTo(Vector3.new(bx + 3, Y + rise + 3, 0))
	local jumped = false
	local conn = RunService.Heartbeat:Connect(function()
		if not jumped and hrp.Position.X >= X0 + 5 - 0.75 then
			jumped = true
			hum.Jump = true
		end
	end)
	local t0, landed = os.clock(), false
	while os.clock() - t0 < 3 do
		task.wait(0.05)
		if hrp.Position.Y < Y - 6 then
			break
		end
		if math.abs(hrp.Position.X - bx) <= 4.2 and hrp.Position.Y > Y + rise + 1.5 and hum.FloorMaterial ~= Enum.Material.Air then
			landed = true
			break
		end
	end
	conn:Disconnect()
	a:Destroy()
	b:Destroy()
	return landed
end
local flat = trial(9.5, 0)
local high = trial(7, 6)
npc:Destroy()
return {
	ok = matches and flat and high,
	detail = string.format("physics %s (validator: gravity %g, walk %g, jump height %g); runner landed gap 9.5 at rise 0: %s, gap 7 at rise 6: %s",
		physics, R.GRAVITY, R.WALK_SPEED, R.JUMP_HEIGHT, tostring(flat), tostring(high)),
}
