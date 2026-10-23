--!strict
-- NavigationService [owner: Navigation]. Per-player waypoints for the GPS (docs/game/08 "Navigation").
-- The server only says WHERE each player should go; NavigationController draws the minimap, big map,
-- beacon, edge arrow and road route from these attributes. Parallel squads just get different
-- waypoints (it's per player), so nothing here is global.
--
-- Public API (contract, docs/game/08):
--   NavigationService:SetWaypoint(players: {Player} | Player, target: Vector3 | BasePart | Model, label: string)
--   NavigationService:ClearWaypoint(players: {Player} | Player)
--   NavigationService:GetWaypoint(player): (Vector3?, string?)
-- A BasePart / Model target is tracked: WaypointPos follows it (NavigationConfig.TrackInterval) until
-- it is destroyed (then the last position stays) or the waypoint is replaced/cleared.
-- Signals: WaypointChanged(player: Player, pos: Vector3?, label: string?)
-- Writes: Player attrs WaypointPos (Vector3), WaypointLabel (string); both nil when cleared.
-- Telemetry: nav_waypoints_set, nav_waypoints_cleared
-- Test hooks (DevHook only): _selftest()
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local NavigationConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("NavigationConfig") :: ModuleScript) :: any

local ATTR_POS = "WaypointPos"
local ATTR_LABEL = "WaypointLabel"

local NavigationService = {}
NavigationService.Priority = 40
NavigationService.WaypointChanged = Signal.new() :: Signal.Signal<Player, Vector3?, string?>

-- player -> the Instance whose position the waypoint follows
local tracked: { [Player]: Instance } = {}

local function positionOf(target: any): Vector3?
	if typeof(target) == "Vector3" then
		return target
	end
	if typeof(target) == "Instance" then
		if target:IsA("BasePart") then
			return target.Position
		elseif target:IsA("Model") then
			local ok, pivot = pcall(function()
				return (target :: Model):GetPivot()
			end)
			return if ok then pivot.Position else nil
		elseif target:IsA("Attachment") then
			return target.WorldPosition
		end
	end
	return nil
end

local function playerList(players: any): { Player }
	local out: { Player } = {}
	if typeof(players) == "Instance" and players:IsA("Player") then
		table.insert(out, players)
	elseif type(players) == "table" then
		for _, p in players do
			if typeof(p) == "Instance" and p:IsA("Player") and p.Parent == Players then
				table.insert(out, p)
			end
		end
	end
	return out
end

local function write(player: Player, pos: Vector3?, label: string?)
	player:SetAttribute(ATTR_POS, pos)
	player:SetAttribute(ATTR_LABEL, label)
	NavigationService.WaypointChanged:Fire(player, pos, label)
end

function NavigationService:SetWaypoint(players: any, target: any, label: string?): number
	local pos = positionOf(target)
	if not pos then
		warn(`[Navigation] SetWaypoint: bad target {tostring(target)}`)
		return 0
	end
	local text = if type(label) == "string" and label ~= "" then label else "DESTINATION"
	local n = 0
	for _, p in playerList(players) do
		write(p, pos, text)
		if typeof(target) == "Instance" then
			tracked[p] = target
		else
			tracked[p] = nil
		end
		n += 1
	end
	if n > 0 then
		Telemetry.count("nav_waypoints_set", n)
	end
	return n
end

function NavigationService:ClearWaypoint(players: any): number
	local n = 0
	for _, p in playerList(players) do
		tracked[p] = nil
		if p:GetAttribute(ATTR_POS) ~= nil or p:GetAttribute(ATTR_LABEL) ~= nil then
			write(p, nil, nil)
			n += 1
		end
	end
	if n > 0 then
		Telemetry.count("nav_waypoints_cleared", n)
	end
	return n
end

function NavigationService:GetWaypoint(player: Player): (Vector3?, string?)
	return player:GetAttribute(ATTR_POS) :: Vector3?, player:GetAttribute(ATTR_LABEL) :: string?
end

function NavigationService:Init(_services: { [string]: any }) end

function NavigationService:Start()
	Players.PlayerRemoving:Connect(function(p: Player)
		tracked[p] = nil
	end)
	-- follow moving targets (a truck, an NPC); cheap: one position read per tracked player
	task.spawn(function()
		while true do
			task.wait(tonumber(NavigationConfig.TrackInterval) or 0.5)
			for p, target in tracked do
				if p.Parent ~= Players then
					tracked[p] = nil
					continue
				end
				if not target.Parent then
					tracked[p] = nil -- destroyed: keep the last position
					continue
				end
				local pos = positionOf(target)
				local cur = p:GetAttribute(ATTR_POS)
				if pos and (typeof(cur) ~= "Vector3" or (cur - pos).Magnitude >= (tonumber(NavigationConfig.TrackMinMove) or 2)) then
					p:SetAttribute(ATTR_POS, pos)
				end
			end
		end
	end)
end

function NavigationService:_selftest(): (boolean, string)
	if NavigationService:SetWaypoint({}, Vector3.zero, "x") ~= 0 then
		return false, "empty player list set something"
	end
	if NavigationService:SetWaypoint({}, "nope" :: any, "x") ~= 0 then
		return false, "bad target accepted"
	end
	local p = Players:GetPlayers()[1]
	if not p then
		return true, "no players; API wired"
	end
	local oldPos, oldLabel = NavigationService:GetWaypoint(p)
	NavigationService:SetWaypoint({ p }, Vector3.new(1, 2, 3), "TEST")
	local pos, label = NavigationService:GetWaypoint(p)
	local ok = pos == Vector3.new(1, 2, 3) and label == "TEST"
	if oldPos then
		NavigationService:SetWaypoint({ p }, oldPos, oldLabel or "")
	else
		NavigationService:ClearWaypoint({ p })
	end
	return ok, if ok then "waypoint round-trip ok" else "attributes not written"
end

return NavigationService
