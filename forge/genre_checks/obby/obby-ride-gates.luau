-- check: Every ride gate is wired (touch pad + prompt), riding it saves the zone's last stage and lands the player on the next zone's start pad, and the ride entrance on the park's ground opens only once that zone is finished
-- covers: genre obby: ride gates at each zone's last checkpoint lead to the next zone's start (irreversible: advances the stage)
-- needs: studio
-- consumer: ReplicatedStorage/Kit/ObbyKit.luau:"teleport(player, spawnFrame(last))"
local Players = game:GetService("Players")
local CS = game:GetService("CollectionService")
local gates = CS:GetTagged("RideGate")
local starts, nStarts = {}, 0
for _, s in CS:GetTagged("ObbyZoneStart") do
	starts[s:GetAttribute("Zone")] = s
	nStarts += 1
end
if #gates == 0 then
	return {
		ok = nStarts == 0,
		detail = if nStarts == 0 then "no ride gates: the course is one continuous run"
			else nStarts .. " zone start pads but no ride gate leads to them",
	}
end
local bad, first = {}, nil
for _, g in gates do
	local zone = tostring(g:GetAttribute("Zone"))
	local pad = g:FindFirstChild("RidePad")
	local prompt = pad and pad:FindFirstChildWhichIsA("ProximityPrompt")
	local target = starts[g:GetAttribute("NextZone")]
	if not (pad and CS:HasTag(pad, "RideGatePad")) then
		table.insert(bad, "zone " .. zone .. "'s gate has no pad tagged RideGatePad")
	elseif not (prompt and prompt.Enabled) then
		table.insert(bad, "zone " .. zone .. "'s gate has no enabled prompt")
	elseif not target then
		table.insert(bad, "zone " .. zone .. "'s gate leads to zone " .. tostring(g:GetAttribute("NextZone")) .. ", which has no start pad")
	elseif target:GetAttribute("AfterStage") ~= g:GetAttribute("Stage") then
		table.insert(bad, "zone " .. zone .. "'s gate ends stage " .. tostring(g:GetAttribute("Stage")) .. " but the next start pad follows stage "
			.. tostring(target:GetAttribute("AfterStage")))
	end
	if pad and target and (first == nil or g:GetAttribute("Stage") < first:GetAttribute("Stage")) then
		first = g
	end
end
if not first then
	return { ok = false, detail = table.concat(bad, "; ") }
end
local p = forge.waitFor(function()
	local pl = Players:GetPlayers()[1]
	return pl and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart") and pl
end, 5)
if not p then
	error("setup: no player character within 5 s")
end
local last = first:GetAttribute("Stage")
forge.harness("teleport_stage", { userId = p.UserId, stage = last - 1 })
local ls = p:FindFirstChild("leaderstats")
local sv = ls and ls:FindFirstChild("Stage")
if not (sv and sv.Value == last - 1) then
	error("setup: could not put the player on stage " .. (last - 1) .. " (Stage is " .. tostring(sv and sv.Value) .. ")")
end
local target = starts[first:GetAttribute("NextZone")]
p.Character:PivotTo(first.RidePad.CFrame * CFrame.new(0, 3, 0))
local arrived = forge.waitFor(function()
	local hrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
	return hrp and sv.Value == last and (hrp.Position - target.Position).Magnitude < 8
end, 4)
local saved = forge.waitFor(function()
	return p:GetAttribute("SavedStage") == last
end, 3)
local hrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
local detail = string.format("%d ride gates; rode zone %s's gate from stage %d: Stage %d, SavedStage %s, %.1f studs from zone %s's start pad",
	#gates, tostring(first:GetAttribute("Zone")), last - 1, sv.Value, tostring(p:GetAttribute("SavedStage")),
	if hrp then (hrp.Position - target.Position).Magnitude else -1, tostring(first:GetAttribute("NextZone")))
-- the same zone's entrance on the park's ground (WorldKit's gates): shut one stage short, open at the zone's last stage
local entrance
for _, e in CS:GetTagged("RideEntrance") do
	if e:GetAttribute("Zone") == first:GetAttribute("NextZone") then
		entrance = e
	end
end
local ground = true
if entrance and entrance:FindFirstChild("EntrancePad") then
	local pad = entrance.EntrancePad
	forge.harness("teleport_stage", { userId = p.UserId, stage = last - 1 })
	p:SetAttribute("RideNotice", nil)
	p.Character:PivotTo(pad.CFrame * CFrame.new(0, 3, 0))
	task.wait(1.6)
	hrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
	local shut = hrp and (hrp.Position - pad.Position).Magnitude < 8 and p:GetAttribute("RideNotice") ~= nil
	forge.harness("teleport_stage", { userId = p.UserId, stage = last })
	p.Character:PivotTo(pad.CFrame * CFrame.new(0, 3, 0))
	local rode = forge.waitFor(function()
		local h = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		return h and (h.Position - target.Position).Magnitude < 8
	end, 4)
	ground = shut and rode ~= nil
	detail ..= string.format("; ground entrance to zone %s: %s at stage %d (notice %q), %s at stage %d", tostring(entrance:GetAttribute("Zone")),
		if shut then "shut" else "NOT shut", last - 1, tostring(p:GetAttribute("RideNotice")), if rode then "rode up" else "did NOT ride",
		last)
end
return {
	ok = arrived ~= nil and saved ~= nil and ground and #bad == 0,
	detail = detail .. (if #bad > 0 then "; " .. table.concat(bad, "; ") else ""),
}
