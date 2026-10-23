--!strict
-- ForgeTelemetry: tiny counter API for generated games. ForgeProbe reports these counters.
--
--   local ForgeTelemetry = require(game:GetService("ReplicatedStorage").ForgeTelemetry)
--   ForgeTelemetry.count("coins_collected")      -- +1
--   ForgeTelemetry.count("damage_dealt", 25)     -- +25
--   ForgeTelemetry.get()                          -- { coins_collected = 1, damage_dealt = 25 }
--
-- Counters live as number attributes on ServerStorage.ForgeCounters (a Folder), so every VM in the
-- server (game scripts, ForgeProbe, execute_luau) sees the same values. Server only: on the client
-- count() is a no-op and get() returns {}.

local RunService = game:GetService("RunService")

local FOLDER_NAME = "ForgeCounters"

local ForgeTelemetry = {}

local function folder(): Instance?
	if not RunService:IsServer() then
		return nil
	end
	local ServerStorage = game:GetService("ServerStorage")
	local f = ServerStorage:FindFirstChild(FOLDER_NAME)
	if not f then
		f = Instance.new("Folder")
		f.Name = FOLDER_NAME
		f.Parent = ServerStorage
	end
	return f
end

-- Attribute names: letters, digits and underscores, max 100 chars, may not start with "RBX".
local function key(name: string): string
	local k = string.gsub(tostring(name), "[^%w_]", "_")
	if k == "" then
		k = "_"
	end
	if string.sub(k, 1, 3) == "RBX" then
		k = "_" .. k
	end
	return string.sub(k, 1, 100)
end

function ForgeTelemetry.count(name: string, n: number?)
	local f = folder()
	if not f then
		return
	end
	local ok = pcall(function()
		local k = key(name)
		local cur = f:GetAttribute(k)
		local add = tonumber(n) or 1
		f:SetAttribute(k, (if type(cur) == "number" then cur else 0) + add)
	end)
	if not ok then
		-- telemetry must never break the game
		return
	end
end

function ForgeTelemetry.get(): { [string]: number }
	local out: { [string]: number } = {}
	if not RunService:IsServer() then
		return out
	end
	local f = game:GetService("ServerStorage"):FindFirstChild(FOLDER_NAME)
	if not f then
		return out
	end
	for k, v in f:GetAttributes() do
		if type(v) == "number" then
			out[k] = v
		end
	end
	return out
end

return ForgeTelemetry
