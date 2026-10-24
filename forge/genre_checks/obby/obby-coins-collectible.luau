-- check: Touching a coin adds it to the player's Coins and hides it until it respawns
-- covers: genre obby: coins (if any) are collectible (irreversible: adds a coin)
-- needs: studio
-- consumer: ReplicatedStorage/Kit/ObbyKit.luau:"d.coins += trunc(num(part:GetAttribute"
local Players = game:GetService("Players")
local CS = game:GetService("CollectionService")
local coins = CS:GetTagged("Coin")
if #coins == 0 then
	return { ok = true, detail = "the course has no coins (nothing to collect)" }
end
local p = forge.waitFor(function()
	local pl = Players:GetPlayers()[1]
	return pl and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart") and pl
end, 5)
if not p then
	error("setup: no player character within 5 s")
end
local ls = p:FindFirstChild("leaderstats")
local cv = ls and ls:FindFirstChild("Coins")
if not cv then
	return { ok = false, detail = string.format("%d coins in the course but the player has no leaderstats.Coins", #coins) }
end
local coin
for _, c in coins do
	if c:GetAttribute("Available") ~= false then
		coin = c
		break
	end
end
if not coin then
	error("setup: every coin is collected already")
end
local before = cv.Value
local char = p.Character
local home = char:GetPivot()
char:PivotTo(CFrame.new(coin.Position))
local got = forge.waitFor(function()
	return cv.Value > before
end, 4)
char:PivotTo(home)
return {
	ok = got ~= nil and coin:GetAttribute("Available") == false,
	detail = string.format("Coins %d -> %d; the coin is now Available=%s (of %d coins)", before, cv.Value,
		tostring(coin:GetAttribute("Available")), #coins),
}
