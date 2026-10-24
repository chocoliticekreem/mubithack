--!strict
-- TutorialService: server owner of first-60-seconds tutorial state.
-- Creates the 'TutorialStep' RemoteEvent at require time; other services call notify().
-- Steps (in order): claim plot -> first cash-in -> buy Dropper 2 -> open shop -> buy tier upgrade.
-- Each step fires at most once and only in order, and increments 'tutorial_steps'.
-- If a step is stuck for STUCK_SECONDS, its hint is re-sent to the client (no counter bump).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TutorialConfig = require(ReplicatedStorage:WaitForChild("TutorialConfig"))
local ForgeTelemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry"))

local EVENTS = (TutorialConfig.EVENTS :: any) :: { [string]: string }

local STUCK_SECONDS = 15

-- One place that creates the remote.
local remote: RemoteEvent
do
	local existing = ReplicatedStorage:FindFirstChild(TutorialConfig.REMOTE_NAME)
	if existing and existing:IsA("RemoteEvent") then
		remote = existing
	else
		remote = Instance.new("RemoteEvent")
		remote.Name = TutorialConfig.REMOTE_NAME
		remote.Parent = ReplicatedStorage
	end
end

type State = {
	fired: { [string]: boolean },
	done: boolean,
	startedAt: number,
	lastEvent: string?,
	lastAt: number,
}

local states: { [Player]: State } = {}

-- Ordered events the server drives; each fires at most once and only in order.
-- Keys that do not exist in the shared config are skipped.
local ORDER: { string } = {}
do
	local keys = { "CLAIMED", "CASHED", "BOUGHT", "SHOP", "TIER", "UPGRADED" }
	for _, key in keys do
		local value = EVENTS[key]
		if type(value) == "string" then
			local dup = false
			for _, existingName in ORDER do
				if existingName == value then
					dup = true
					break
				end
			end
			if not dup then
				table.insert(ORDER, value)
			end
		end
	end
end

local TutorialService = {}

local function numberFrom(inst: Instance?): number
	if inst and (inst:IsA("IntValue") or inst:IsA("NumberValue")) then
		return (inst :: IntValue).Value
	end
	return 0
end

-- Rebirths are stored in the 'Rebirths' leaderstat; owned upgrades are tracked
-- on the player as the 'UpgradesOwned' attribute (0 if nothing is recorded yet).
local function hasRebirthed(player: Player): boolean
	local stats = player:FindFirstChild("leaderstats")
	if stats and numberFrom(stats:FindFirstChild("Rebirths")) > 0 then
		return true
	end
	local attr = player:GetAttribute("Rebirths")
	return type(attr) == "number" and attr > 0
end

local function ownedUpgrades(player: Player): number
	local attr = player:GetAttribute("UpgradesOwned")
	if type(attr) == "number" then
		return attr
	end
	return 0
end

local function isActive(player: Player, state: State?): boolean
	if not state or state.done then
		return false
	end
	if os.clock() - state.startedAt > TutorialConfig.TOTAL_SECONDS then
		state.done = true
		return false
	end
	return player.Parent == Players
end

function TutorialService.notify(player: Player, eventName: string)
	local state = states[player]
	if not state or not isActive(player, state) then
		return
	end
	local nextEvent: string? = nil
	for _, name in ORDER do
		if not state.fired[name] then
			nextEvent = name
			break
		end
	end
	if nextEvent == nil or eventName ~= nextEvent then
		return
	end
	state.fired[eventName] = true
	state.lastEvent = eventName
	state.lastAt = os.clock()
	ForgeTelemetry.count("tutorial_steps", 1)
	remote:FireClient(player, eventName)

	-- all server-driven steps finished
	local allDone = true
	for _, name in ORDER do
		if not state.fired[name] then
			allDone = false
			break
		end
	end
	if allDone then
		state.done = true
	end
end

-- The client may report steps only it can observe (e.g. opening the shop).
-- Only the in-order next step is accepted, so spoofing gains nothing.
remote.OnServerEvent:Connect(function(player: Player, eventName: any)
	if type(eventName) ~= "string" then
		return
	end
	if eventName ~= EVENTS.SHOP then
		return
	end
	TutorialService.notify(player, eventName)
end)

local function setup(player: Player)
	if states[player] then
		return
	end
	local state: State = {
		fired = {},
		done = false,
		startedAt = os.clock(),
		lastEvent = nil,
		lastAt = os.clock(),
	}
	states[player] = state

	task.spawn(function()
		-- leaderstats may not exist yet; wait briefly, then give the client time to load.
		player:WaitForChild("leaderstats", 5)
		task.wait(1.5)
		if states[player] ~= state or player.Parent ~= Players then
			return
		end
		if hasRebirthed(player) or ownedUpgrades(player) >= TutorialConfig.SKIP_UPGRADES then
			state.done = true
			remote:FireClient(player, EVENTS.SKIP)
			return
		end
		remote:FireClient(player, EVENTS.START)
		-- The plot is auto-claimed shortly after joining, so the "walk to a CLAIM gate"
		-- step would contradict the game. Advance right away via the claimed event.
		-- notify() counts tutorial_steps and is ignored if a manual claim already advanced.
		if ORDER[1] then
			TutorialService.notify(player, ORDER[1])
		end
		state.lastAt = os.clock()

		-- Stuck-step fallback: re-show the current hint if nothing advanced in 15s.
		while states[player] == state and isActive(player, state) do
			task.wait(1)
			if states[player] ~= state then
				break
			end
			local last = state.lastEvent
			if last and not state.done and os.clock() - state.lastAt >= STUCK_SECONDS then
				state.lastAt = os.clock()
				remote:FireClient(player, last)
			end
		end
	end)

	task.delay(TutorialConfig.TOTAL_SECONDS + 2, function()
		if states[player] == state then
			state.done = true
		end
	end)
end

local started = false

function TutorialService.start()
	if started then
		return
	end
	started = true
	Players.PlayerAdded:Connect(setup)
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		setup(player)
	end
end

return TutorialService
