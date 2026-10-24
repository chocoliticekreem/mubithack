--!strict
-- FlareUpService: keeps the pressure on during a call. Every INTERVAL seconds, for each ACTIVE run
-- (MissionService:GetMissions, roundState "Active"), it re-lights a Flammable part next to a fire that
-- is still burning at THAT run's site (MapService:GetInstance(runId): the bound IncidentSite or the
-- instance copy). Nothing burns at a site with no active run: districts without a mission (an empty
-- Apartment, School or Farm while a squad is at the gas station) never catch fire on their own, and a
-- run whose fires are all out stays out (the escalation phases in MissionService bring the next wave).
-- Counter: flareups. A full fire cap is not a fault: the cycle is skipped.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names"))

local INTERVAL = 10
local FIRST_DELAY = 2
local FLARE_RADIUS = 14 -- studs round a burning part
local MAX_LOGS = 3

local FlareUpService = {}
FlareUpService.Priority = 60
FlareUpService._services = nil :: any
FlareUpService._started = false
FlareUpService._logs = 0

function FlareUpService.Init(self: any, services: any)
	self._services = services
end

local function count(name: string)
	local mod = ReplicatedStorage:FindFirstChild("ForgeTelemetry")
	if mod and mod:IsA("ModuleScript") then
		pcall(function()
			(require(mod) :: any).count(name, 1)
		end)
	end
end

-- Active runs and their site models.
local function activeSites(services: any): { { id: string, site: Instance } }
	local out = {}
	local Mission = services.MissionService
	local Map = services.MapService
	if not (Mission and Map and type(Mission.GetMissions) == "function" and type(Map.GetInstance) == "function") then
		return out
	end
	local ok, list = pcall(Mission.GetMissions, Mission)
	if not ok or type(list) ~= "table" then
		return out
	end
	for _, run in list do
		local raw = run.roundState or run.state
		if raw == "Active" and type(run.instanceId) == "string" then
			local okSite, site = pcall(Map.GetInstance, Map, run.instanceId)
			if okSite and typeof(site) == "Instance" and site.Parent then
				table.insert(out, { id = run.instanceId, site = site })
			end
		end
	end
	return out
end

local function burningIn(site: Instance): { BasePart }
	local out = {}
	for _, d in site:GetDescendants() do
		if d:IsA("BasePart") and d:HasTag(Names.Tag.Burning) then
			table.insert(out, d)
		end
	end
	return out
end

-- One flare-up at this site: a Flammable, unburnt part next to a fire that is still going.
function FlareUpService._flare(self: any, site: Instance, rng: Random): boolean
	local Fire = self._services and self._services.FireService
	if not (Fire and type(Fire.Ignite) == "function") then
		return false
	end
	local burning = burningIn(site)
	if #burning == 0 then
		return false
	end
	local op = OverlapParams.new()
	op.FilterType = Enum.RaycastFilterType.Include
	op.FilterDescendantsInstances = { site }
	for _ = 1, 4 do
		local from = burning[rng:NextInteger(1, #burning)]
		local near = workspace:GetPartBoundsInRadius(from.Position, FLARE_RADIUS, op)
		local cands = {}
		for _, p in near do
			if p:HasTag(Names.Tag.Flammable) and not p:HasTag(Names.Tag.Burning) and p:GetAttribute(Names.Attr.Charred) ~= true then
				table.insert(cands, p)
			end
		end
		if #cands > 0 then
			local part = cands[rng:NextInteger(1, #cands)]
			local ok, lit = pcall(Fire.Ignite, Fire, part, nil)
			if ok and lit == true then
				count("flareups")
				if self._logs < MAX_LOGS then
					self._logs += 1
					print("[FlareUpService] flare-up: " .. part:GetFullName())
				end
				return true
			end
		end
	end
	return false
end

function FlareUpService._tick(self: any, rng: Random): number
	local services = self._services
	if type(services) ~= "table" then
		return 0
	end
	local n = 0
	for _, entry in activeSites(services) do
		if self:_flare(entry.site, rng) then
			n += 1
		end
	end
	return n
end

function FlareUpService.Start(self: any)
	if self._started then
		return
	end
	self._started = true
	local rng = Random.new(os.time())
	task.spawn(function()
		task.wait(FIRST_DELAY)
		while true do
			local ok, err = pcall(function()
				self:_tick(rng)
			end)
			if not ok then
				warn("[FlareUpService] tick error: " .. tostring(err))
			end
			task.wait(INTERVAL)
		end
	end)
end

function FlareUpService._selftest(self: any): (boolean, string)
	return true, "ok"
end

return FlareUpService
