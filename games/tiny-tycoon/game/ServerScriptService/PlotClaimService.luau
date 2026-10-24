--!nonstrict
-- PlotClaimService: themed plot claiming, auto-claim after timeout, release on leave.
--
-- Plot-table shape (normalized once in init, used everywhere afterwards):
--   index        number
--   theme        theme table
--   origin       CFrame   (plot center / spawn point)
--   spawnCFrame  CFrame   (where claimed players are teleported)
--   gate         Instance? (claim gate model/part)
--   plot         table    (the table handed to Tycoon.new)
--   Owner        Player?  (nil while free)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlotThemes = require(ReplicatedStorage:WaitForChild("PlotThemes"))
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry"))
local PlazaBuilder = require(ServerScriptService:WaitForChild("PlazaBuilder"))
local Tycoon = require(ServerScriptService:WaitForChild("Tycoon"))

local PlotClaimService = {}

local entries = {} -- list of plot entries
local claimedBy = {} -- [Player] = entry
local tycoons = {} -- [entry] = tycoon
local gateState = {} -- [entry] = { {inst, prop, value}, ... }
local busy = {} -- [Player] = true while claiming
local claimTimers = {} -- [Player] = auto-claim timer thread
local initialized = false

-- RebirthService is required lazily (it may depend on this module) to avoid
-- a circular require at load time.
local rebirthService = nil
local rebirthTried = false

local function getRebirthService()
	if rebirthService or rebirthTried then
		return rebirthService
	end
	local module = ServerScriptService:FindFirstChild("RebirthService")
	if not module then
		return nil -- not available yet; try again next time
	end
	rebirthTried = true
	local ok, result = pcall(require, module)
	if ok then
		rebirthService = result
	else
		warn("[PlotClaimService] RebirthService require failed: " .. tostring(result))
	end
	return rebirthService
end

local function count(name, n)
	Telemetry.count(name, n or 1)
end

local function isFree(entry)
	return entry.Owner == nil
end

-- Normalize an incoming plot table into the single shared shape (done once).
local function normalize(p, i)
	p.index = p.index or i
	p.theme = p.theme or p.Theme or PlotThemes.getTheme(i)
	if typeof(p.origin) ~= "CFrame" then
		p.origin = (typeof(p.spawnCFrame) == "CFrame") and p.spawnCFrame or PlotThemes.getSlotCFrame(i)
	end
	if typeof(p.spawnCFrame) ~= "CFrame" then
		p.spawnCFrame = p.origin
	end
	p.gate = p.gate or p.Gate
	if not p.gate then
		local ok, g = pcall(PlazaBuilder.buildClaimGate, p.origin, p.theme)
		if ok then
			p.gate = g
		end
	end
	p.plot = p.plot or p.data or p.plotData or p
	p.Owner = nil
	return p
end

-- Gate hide / restore -------------------------------------------------------
local function gateInstances(gate)
	local list = {}
	if not gate or not gate.Parent then
		return list
	end
	table.insert(list, gate)
	for _, d in gate:GetDescendants() do
		table.insert(list, d)
	end
	return list
end

local function hideGate(entry)
	local saved = {}
	for _, inst in gateInstances(entry.gate) do
		if inst:IsA("BasePart") then
			table.insert(saved, { inst, "Transparency", inst.Transparency })
			table.insert(saved, { inst, "CanTouch", inst.CanTouch })
			inst.Transparency = 1
			inst.CanTouch = false
		elseif inst:IsA("BillboardGui") or inst:IsA("ParticleEmitter") or inst:IsA("Light") then
			table.insert(saved, { inst, "Enabled", inst.Enabled })
			inst.Enabled = false
		end
	end
	gateState[entry] = saved
end

local function showGate(entry)
	local saved = gateState[entry]
	gateState[entry] = nil
	if not saved then
		return
	end
	for _, rec in saved do
		local inst = rec[1]
		if inst and inst.Parent then
			inst[rec[2]] = rec[3]
		end
	end
end

-- Claim / release -----------------------------------------------------------
local function teleportToPlot(player, entry)
	local char = player.Character
	if not char then
		return
	end
	char:PivotTo(entry.spawnCFrame + Vector3.new(0, 4, 0))
end

local function claim(player, entry, auto)
	if not player or player.Parent ~= Players or not entry then
		return false
	end
	-- Owner check and assignment happen with no yield in between, so
	-- simultaneous Touched events cannot double-claim a plot.
	if claimedBy[player] then
		return false
	end
	if busy[player] or not isFree(entry) then
		return false
	end
	local timer = claimTimers[player]
	if timer then
		claimTimers[player] = nil
		if not auto then
			pcall(task.cancel, timer)
		end
	end
	busy[player] = true
	entry.Owner = player
	claimedBy[player] = entry
	if entry.gate then
		entry.gate:SetAttribute("Owner", player.Name)
	end
	player:SetAttribute("PlotIndex", entry.index)

	pcall(PlazaBuilder.setSign, entry, player.Name, auto == true)
	hideGate(entry)

	-- Tycoon starts only after the claim is registered.
	local ok, t = pcall(Tycoon.startPlot, player, entry.plot)
	if ok then
		tycoons[entry] = t or true
	else
		warn("[PlotClaimService] Tycoon.startPlot failed: " .. tostring(t))
	end
	teleportToPlot(player, entry)

	-- Notify the rebirth feature (plot entry in this module's shape).
	local rebirth = getRebirthService()
	if rebirth and rebirth.onPlotClaimed then
		local rok, rerr = pcall(rebirth.onPlotClaimed, player, entry)
		if not rok then
			warn("[PlotClaimService] RebirthService.onPlotClaimed failed: " .. tostring(rerr))
		end
	end

	-- Counters: exactly once per successful claim.
	count("plots_claimed")
	count("plot_assigned")
	if auto then
		count("auto_claims")
	end

	-- Tutorial hook: once per successful claim.
	local tutorialModule = script.Parent:FindFirstChild("TutorialService")
	if tutorialModule then
		local tok, terr = pcall(function()
			require(tutorialModule).notify(player, "claimed")
		end)
		if not tok then
			warn("[PlotClaimService] TutorialService.notify failed: " .. tostring(terr))
		end
	end
	pcall(function()
		require(script.Parent.TutorialFlow).notify(player, "claimed")
	end)
	busy[player] = nil
	return true
end

local function release(player)
	local entry = claimedBy[player]
	claimedBy[player] = nil
	busy[player] = nil
	local pendingTimer = claimTimers[player]
	claimTimers[player] = nil
	if pendingTimer then
		pcall(task.cancel, pendingTimer)
	end
	if not entry then
		return
	end
	local t = tycoons[entry]
	tycoons[entry] = nil
	if t then
		pcall(function()
			Tycoon.stopPlot(entry.plot)
		end)
	end

	local rebirth = getRebirthService()
	if rebirth and rebirth.onPlotReleased then
		local rok, rerr = pcall(rebirth.onPlotReleased, player)
		if not rok then
			warn("[PlotClaimService] RebirthService.onPlotReleased failed: " .. tostring(rerr))
		end
	end

	pcall(PlazaBuilder.setSign, entry, nil)
	showGate(entry)
	if entry.gate then
		entry.gate:SetAttribute("Owner", nil)
	end
	entry.Owner = nil
	count("plots_released")
end

local function nearestFree(player)
	local pos
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp then
		pos = hrp.Position
	end
	local best, bestDist
	for _, entry in entries do
		if isFree(entry) then
			if not pos then
				return entry
			end
			local d = (entry.origin.Position - pos).Magnitude
			if not bestDist or d < bestDist then
				best, bestDist = entry, d
			end
		end
	end
	return best
end

local function watchPlayer(player)
	if claimTimers[player] or claimedBy[player] then
		return
	end
	claimTimers[player] = task.delay(math.min(PlotThemes.CLAIM_TIMEOUT or 4, 4), function()
		claimTimers[player] = nil
		if player.Parent == Players and not claimedBy[player] then
			local entry = nearestFree(player)
			if entry then
				claim(player, entry, true)
			end
		end
	end)
end

local function connectGate(entry)
	local gate = entry.gate
	if not gate then
		return
	end
	local function hook(part)
		part.Touched:Connect(function(hit)
			if not isFree(entry) then
				return
			end
			local model = hit:FindFirstAncestorOfClass("Model")
			local player = model and Players:GetPlayerFromCharacter(model)
			if player then
				claim(player, entry, false)
			end
		end)
	end
	if gate:IsA("BasePart") then
		hook(gate)
	end
	for _, d in gate:GetDescendants() do
		if d:IsA("BasePart") then
			hook(d)
		end
	end
end

-- Public API ----------------------------------------------------------------
function PlotClaimService.init(plots)
	if initialized then
		return
	end
	initialized = true

	for i, p in ipairs(plots or {}) do
		normalize(p, i)
		table.insert(entries, p)
		connectGate(p)
	end

	-- 'plaza_built' and 'themes_built' are counted by PlazaBuilder only.

	Players.PlayerRemoving:Connect(release)
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
end

function PlotClaimService.claim(player, plot)
	return claim(player, plot, false)
end

function PlotClaimService.getPlotOf(player)
	return claimedBy[player]
end

function PlotClaimService.isOwner(player, plot)
	if not player or not plot then
		return false
	end
	return claimedBy[player] == plot or plot.Owner == player
end

return PlotClaimService
