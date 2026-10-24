--!strict
-- UpdateLogService [owner: UpdateLog]. Server half of the WHAT'S NEW panel (Controllers/UpdateLogController
-- draws it; the list is Config/UpdateLog). It only remembers, in the DataService profile (v8 `updates`),
-- which version each player has seen, so the panel pops up once per new update and never again:
--   * Player attrs, set once the profile is loaded: LastSeenUpdate (string, "" = never) and
--     NotifyPromptedFor (the version the opt-in prompt last opened for), then UpdateLogReady = true.
--   * UpdateLog/Seen (C->S, version: string, 2/s): the player closed the panel -> updates.lastSeen.
--     Only a version that is in Config/UpdateLog is accepted.
--   * UpdateLog/Event (C->S, name: string, how: number?, 4/s): funnel / custom events through
--     FunnelService:LogCustom (CustomField01 = the newest version). Names: UpdateLogShown (how 1 = popped up
--     on join, 2 = NEWS chip), NotifyPrompted (also -> updates.prompted), NotifyAccepted, FavoritePrompted,
--     FavoriteAccepted. Each name is logged at most MaxPerEvent times per player per session.
-- Public API: UpdateLogService:LastSeen(player): string?
-- Counters: update_log_shown, update_log_seen, update_notify_prompted, update_favorite_prompted
-- Test hooks (DevHook only): _reset(player) (the panel shows again: lastSeen = "")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local UpdateLog = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("UpdateLog") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local Schema = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Data"):WaitForChild("ProfileSchema") :: ModuleScript)

local UpdateLogService = {}
UpdateLogService.Priority = 96 -- after DataService (20) and FunnelService (95)

local ATTR_SEEN = "LastSeenUpdate"
local ATTR_PROMPTED = "NotifyPromptedFor"
local ATTR_READY = "UpdateLogReady"
local MAX_PER_EVENT = 3

local EVENTS = {
	UpdateLogShown = "update_log_shown",
	NotifyPrompted = "update_notify_prompted",
	NotifyAccepted = "update_notify_accepted",
	FavoritePrompted = "update_favorite_prompted",
	FavoriteAccepted = "update_favorite_accepted",
}

local services: { [string]: any } = {}
local logged: { [Player]: { [string]: number } } = {}

local function count(name: string)
	pcall(Telemetry.count, name, 1)
end

local function newest(): string
	local e = UpdateLog.latest()
	return if e then e.version else ""
end

local function update(player: Player, fn: (any) -> ()): boolean
	local Data = services.DataService
	if not Data or type(Data.Update) ~= "function" then
		return false
	end
	local ok, res = pcall(Data.Update, Data, player, fn)
	return ok and res == true
end

local function mirror(player: Player, p: any)
	local u = type(p) == "table" and type(p.updates) == "table" and p.updates or {}
	player:SetAttribute(ATTR_SEEN, if type(u.lastSeen) == "string" then u.lastSeen else "")
	player:SetAttribute(ATTR_PROMPTED, if type(u.prompted) == "string" then u.prompted else "")
	player:SetAttribute(ATTR_READY, true)
end

local function onPlayer(player: Player)
	logged[player] = {}
	task.spawn(function()
		local Data = services.DataService
		local p: any = nil
		if Data and type(Data.WaitForProfile) == "function" then
			local ok, res = pcall(Data.WaitForProfile, Data, player, 30)
			p = if ok then res else nil
		end
		if player.Parent ~= Players then
			return
		end
		-- no profile (DataService down): still let the panel show; it just won't be remembered
		mirror(player, p)
	end)
end

function UpdateLogService:LastSeen(player: Player): string?
	local v = player:GetAttribute(ATTR_SEEN)
	return if type(v) == "string" then v else nil
end

function UpdateLogService:Init(all: { [string]: any })
	services = all
end

function UpdateLogService:Start()
	local seen = Net.event("UpdateLog", "Seen")
	Net.onServer(seen, { rate = 2, burst = 2 }, function(player: Player, version: any)
		if not UpdateLog.isKnown(version) or version ~= newest() then
			return
		end
		player:SetAttribute(ATTR_SEEN, version)
		update(player, function(p)
			if Schema.markUpdateSeen(p, version) then
				count("update_log_seen")
			end
		end)
	end)

	local event = Net.event("UpdateLog", "Event")
	Net.onServer(event, { rate = 4, burst = 4 }, function(player: Player, name: any, how: any)
		if type(name) ~= "string" or EVENTS[name] == nil then
			return
		end
		local mine = logged[player]
		if not mine then
			return
		end
		local n = (mine[name] or 0) + 1
		if n > MAX_PER_EVENT then
			return
		end
		mine[name] = n
		count(EVENTS[name])
		local version = newest()
		if name == "NotifyPrompted" then
			player:SetAttribute(ATTR_PROMPTED, version)
			update(player, function(p)
				Schema.markNotifyPrompted(p, version)
			end)
		end
		local value = if name == "UpdateLogShown" and how == 2 then 2 else 1
		local Funnel = services.FunnelService
		if Funnel and type(Funnel.LogCustom) == "function" then
			pcall(Funnel.LogCustom, Funnel, player, name, value, version)
		end
	end)

	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		if not logged[player] then
			onPlayer(player)
		end
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		logged[player] = nil
	end)
end

----------------------------------------------------------------------------------- test hooks

function UpdateLogService:_reset(player: Player): boolean
	update(player, function(p)
		p.updates = { lastSeen = "", prompted = "" }
	end)
	player:SetAttribute(ATTR_SEEN, "")
	player:SetAttribute(ATTR_PROMPTED, "")
	logged[player] = {}
	return true
end

return UpdateLogService
