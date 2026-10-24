--!strict
-- FlareUpService: periodically ignites a random flammable part during an Active round.
-- Primary path: every INTERVAL seconds pick via MapService:RandomFlammable(id, rng), call FireService:Ignite, count("flareups", 1).
-- Proximity to players is a strong preference: near-player candidates are tried first,
-- far parts are only accepted after every near candidate fails.
-- A full fire cap is not a fault: the cycle is skipped silently (throttled print at most).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names"))

local INTERVAL = 8
local FIRST_DELAY = 2
local MAX_ATTEMPTS = 10 -- max ignite attempts on near candidates
local FAR_ATTEMPTS = 2 -- max ignite attempts on far candidates (fallback only)
local SAMPLE_COUNT = 40 -- random picks gathered per cycle
local MAX_PLAYER_DISTANCE = 140
local MAX_BACKOFF = 8
local CAP_MARGIN = 1
local MAX_IGNITE_LOGS = 3
local INFO_LOG_COOLDOWN = 30

local FlareUpService = {}
FlareUpService.Priority = 60
FlareUpService._services = nil :: any
FlareUpService._started = false
FlareUpService._thread = nil :: thread?
FlareUpService._telemetry = nil :: any
FlareUpService._telemetryTried = false
FlareUpService._warned = {} :: { [string]: boolean }
FlareUpService._loggedActive = false
FlareUpService._failStreak = 0
FlareUpService._igniteLogs = 0
FlareUpService._lastInfoLog = {} :: { [string]: number }

function FlareUpService.Init(self: any, services: any)
	self._services = services
end

local function warnOnce(self: any, key: string, msg: string)
	if self._warned[key] then
		return
	end
	self._warned[key] = true
	warn("[FlareUpService] " .. msg)
end

-- Throttled non-warning log for expected conditions (cap full, no candidates).
local function infoThrottled(self: any, key: string, msg: string)
	local now = os.clock()
	local last = self._lastInfoLog[key]
	if last ~= nil and now - last < INFO_LOG_COOLDOWN then
		return
	end
	self._lastInfoLog[key] = now
	print("[FlareUpService] " .. msg)
end

local function loadTelemetry(self: any): any?
	if self._telemetry ~= nil then
		return self._telemetry
	end
	if self._telemetryTried then
		return nil
	end
	self._telemetryTried = true
	local mod = ReplicatedStorage:FindFirstChild("ForgeTelemetry")
	if not mod then
		mod = ReplicatedStorage:WaitForChild("ForgeTelemetry", 5)
	end
	if mod and mod:IsA("ModuleScript") then
		local ok, result = pcall(require, mod)
		if ok then
			self._telemetry = result
			return result
		end
		warnOnce(self, "telemetryRequire", "ForgeTelemetry require failed: " .. tostring(result))
		return nil
	end
	warnOnce(self, "telemetryMissing", "ForgeTelemetry module not found")
	return nil
end

local function getPlayerPositions(): { Vector3 }
	local list = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		if char then
			local root = char:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				table.insert(list, root.Position)
			end
		end
	end
	return list
end

local function isNearPlayer(part: any, positions: { Vector3 }): boolean
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		return false
	end
	local pos = part.Position
	for _, p in ipairs(positions) do
		if (p - pos).Magnitude <= MAX_PLAYER_DISTANCE then
			return true
		end
	end
	return false
end

-- Returns true when the fire system looks saturated (best effort, depends on what FireService exposes).
local function fireSystemSaturated(fireService: any): boolean
	local getCount = fireService.GetActiveCount
	if type(getCount) ~= "function" then
		return false
	end
	local okCount, count = pcall(function()
		return fireService:GetActiveCount()
	end)
	if not okCount or type(count) ~= "number" then
		return false
	end
	local cap: any = fireService.MAX_FIRES or fireService.MaxFires
	if type(cap) ~= "number" then
		local getMax = fireService.GetMaxFires
		if type(getMax) == "function" then
			local okMax, m = pcall(function()
				return fireService:GetMaxFires()
			end)
			if okMax then
				cap = m
			end
		end
	end
	if type(cap) ~= "number" then
		return false
	end
	return count >= cap - CAP_MARGIN
end

-- Attempts one ignition; returns true if a fire started.
local function tryIgnite(self: any, fireService: any, part: any): boolean
	local okIgnite, ignited = pcall(function()
		return fireService:Ignite(part, nil)
	end)
	if not okIgnite then
		warnOnce(self, "igniteErr", "Ignite error: " .. tostring(ignited))
		return false
	end
	if ignited ~= true then
		return false
	end
	if self._igniteLogs < MAX_IGNITE_LOGS then
		self._igniteLogs += 1
		local name = "?"
		if typeof(part) == "Instance" then
			name = part:GetFullName()
		end
		print("[FlareUpService] ignited " .. name)
	end
	local telemetry = loadTelemetry(self)
	if telemetry and type(telemetry.count) == "function" then
		telemetry.count("flareups", 1)
	end
	return true
end

-- Returns "ignited", "failed" or "skipped".
function FlareUpService._tick(self: any, rng: Random): string
	if workspace:GetAttribute(Names.Attr.RoundState) ~= "Active" then
		self._loggedActive = false
		self._failStreak = 0
		return "skipped"
	end
	local id = workspace:GetAttribute(Names.Attr.MissionId)
	if not self._loggedActive then
		self._loggedActive = true
		self._igniteLogs = 0
		print("[FlareUpService] RoundState is Active, MissionId=" .. tostring(id)) -- status, not a warning
	end
	local services = self._services
	if type(services) ~= "table" then
		warnOnce(self, "noServices", "services table missing")
		return "skipped"
	end
	local mapService = services.MapService
	local fireService = services.FireService
	if mapService == nil or fireService == nil then
		warnOnce(self, "noDeps", "MapService or FireService is nil")
		return "skipped"
	end
	if fireSystemSaturated(fireService) then
		return "skipped"
	end

	local positions = getPlayerPositions()
	local hasPlayers = #positions > 0

	-- Gather distinct candidates, split into near-player and far.
	local near: { any } = {}
	local far: { any } = {}
	local seen: { [any]: boolean } = {}
	for _ = 1, SAMPLE_COUNT do
		local okPick, part = pcall(function()
			return mapService:RandomFlammable(id, rng)
		end)
		if not okPick then
			warnOnce(self, "pickErr", "RandomFlammable error: " .. tostring(part))
			break
		elseif part ~= nil and not seen[part] then
			seen[part] = true
			if (not hasPlayers) or isNearPlayer(part, positions) then
				table.insert(near, part)
			else
				table.insert(far, part)
			end
		end
	end

	if #near == 0 and #far == 0 then
		infoThrottled(self, "noCandidates", "RandomFlammable gave no candidates (MissionId=" .. tostring(id) .. ")")
		return "skipped"
	end

	-- Near candidates first.
	for i = 1, math.min(#near, MAX_ATTEMPTS) do
		if tryIgnite(self, fireService, near[i]) then
			return "ignited"
		end
	end
	-- Far candidates only after every near one failed.
	for i = 1, math.min(#far, FAR_ATTEMPTS) do
		if tryIgnite(self, fireService, far[i]) then
			return "ignited"
		end
	end

	-- Most likely the global fire cap is full or parts are already burning: not a fault.
	infoThrottled(self, "noIgnite", "no ignition this cycle (fire cap likely full), skipping")
	return "skipped"
end

function FlareUpService.Start(self: any)
	if self._started then
		return
	end
	self._started = true
	local rng = Random.new(os.time())
	self._thread = task.spawn(function()
		task.wait(FIRST_DELAY)
		while true do
			local result = "skipped"
			local ok, err = pcall(function()
				result = self:_tick(rng)
			end)
			if not ok then
				warn("[FlareUpService] tick error: " .. tostring(err))
				result = "failed"
			end
			if result == "ignited" then
				self._failStreak = 0
			elseif result == "failed" then
				self._failStreak = math.min(self._failStreak + 1, 4)
			end
			local wait = math.min(INTERVAL * (2 ^ self._failStreak), MAX_BACKOFF)
			task.wait(wait)
		end
	end)
end

function FlareUpService._selftest(self: any): (boolean, string)
	return true, "ok"
end

return FlareUpService
