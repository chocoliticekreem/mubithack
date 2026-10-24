-- ForgeProbe: playtest error/telemetry collector for forge (Studio only).
--
-- ServerStorage.ForgeProbe (BindableFunction)
--   :Invoke("report") -> JSON string
--     {"uptime": 12.3, "errors": [{"message", "trace", "script", "count"}], "warnings": ["..."],
--      "players": 1, "joins": 1, "counters": {"coins_collected": 3}, "instances": 412}
--   :Invoke("reset")  -> clears errors/warnings, returns "ok"
--   :Invoke("hotreload", liveModule, cloneWithNewSource) -> "reloaded N" | "error: ..."
--     copies the clone's functions into the live module table (forge Studio.hot_reload)
--   :Invoke("physics") -> JSON {"flagged": [...], "watched", "loudest": [...]} (also "physics" in "report")
--
-- Physics sampler: every 0.5 s it samples the root parts of unanchored assemblies that should be at
-- rest (no Humanoid in their model, no occupied Seat/VehicleSeat) and flags the ones that keep moving
-- over a 4 s window: "jitter" (speed or spin keeps going but it stays in place) or "drift" (slow steady
-- creep). Each newly flagged assembly bumps the physics_jitter / physics_drift counter.
--
-- ServerStorage.DevHook (BindableFunction)
--   :Invoke(moduleName, method, ...) -> (true, results...) | (false, err)
--   Finds a ModuleScript by name (ServerScriptService first, then ServerStorage, ReplicatedStorage),
--   requires it in the live game VM and calls module:method(...). Prefix the method with "." for a
--   plain call, module.method(...). If the field is not a function its value is returned; an empty
--   method returns the module's sorted key list.
--
-- Counters come from ServerStorage.ForgeCounters attributes (see ReplicatedStorage/ForgeTelemetry).

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end

local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ScriptContext = game:GetService("ScriptContext")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MAX_ITEMS = 50
local MAX_MSG = 500
local MAX_TRACE = 1000

local started = os.clock()
-- wall-clock second the server started, used to keep log history from before this script ran
local startEpoch = os.time() - math.floor(time()) - 2

type ErrorEntry = { message: string, trace: string, script: string, count: number, ctx: number, log: number }

local errors: { ErrorEntry } = {}
local errorIndex: { [string]: ErrorEntry } = {}
local warnings: { string } = {}
local warningCounts: { [string]: number } = {}
local droppedErrors, droppedWarnings = 0, 0
local joins = 0

local function clip(s: any, n: number): string
	local str = tostring(s or "")
	if #str > n then
		return string.sub(str, 1, n) .. "..."
	end
	return str
end

-- A script error usually arrives twice: ScriptContext.Error (with trace/script) and LogService
-- (MessageError). Count each source separately and report the max, so one error counts once.
local function addError(fromCtx: boolean, message: string, trace: string?, scriptName: string?)
	local msg = clip(message, MAX_MSG)
	local e = errorIndex[msg]
	if not e then
		if #errors >= MAX_ITEMS then
			droppedErrors += 1
			return
		end
		e = { message = msg, trace = "", script = "", count = 0, ctx = 0, log = 0 }
		errorIndex[msg] = e
		table.insert(errors, e)
	end
	if fromCtx then
		e.ctx += 1
	else
		e.log += 1
	end
	e.count = math.max(e.ctx, e.log)
	if e.trace == "" and trace and trace ~= "" then
		e.trace = clip(trace, MAX_TRACE)
	end
	if e.script == "" and scriptName and scriptName ~= "" then
		e.script = scriptName
	end
end

local function addWarning(message: string)
	local msg = clip(message, MAX_MSG)
	local c = warningCounts[msg]
	if c then
		warningCounts[msg] = c + 1
		return
	end
	if #warnings >= MAX_ITEMS then
		droppedWarnings += 1
		return
	end
	warningCounts[msg] = 1
	table.insert(warnings, msg)
end

local function onMessage(message: string, messageType: Enum.MessageType)
	if messageType == Enum.MessageType.MessageError then
		addError(false, message, nil, nil)
	elseif messageType == Enum.MessageType.MessageWarning then
		addWarning(message)
	end
end

ScriptContext.Error:Connect(function(message: string, trace: string, scr: Instance?)
	local name = ""
	if scr then
		local ok, full = pcall(function()
			return scr:GetFullName()
		end)
		name = if ok then full else tostring(scr)
	end
	addError(true, message, trace, name)
end)

LogService.MessageOut:Connect(onMessage)

-- messages logged before this script started (e.g. errors while other scripts were loading)
pcall(function()
	for _, entry in LogService:GetLogHistory() do
		if entry.timestamp >= startEpoch then
			onMessage(entry.message, entry.messageType)
		end
	end
end)

joins = #Players:GetPlayers()
Players.PlayerAdded:Connect(function()
	joins += 1
end)

local function counters(): { [string]: number }
	local out = {}
	local f = ServerStorage:FindFirstChild("ForgeCounters")
	if f then
		for k, v in f:GetAttributes() do
			if type(v) == "number" then
				out[k] = v
			end
		end
	end
	return out
end

-- ------------------------------------------------------------------ physics sampler

local SAMPLE_EVERY = 0.5
local RESCAN_EVERY = 5
local WINDOW = 8
local MAX_ROOTS = 150
local MIN_MASS = 2
local SETTLE_SECONDS = 3
local ACTIVE_SPEED, ACTIVE_ANGVEL = 1.0, 1.0
local JITTER_ACTIVE, JITTER_MAX_NET = 4, 3
local DRIFT_ACTIVE, DRIFT_MIN_NET, DRIFT_MAX_SPEED = 6, 3, 12
local MAX_FLAGGED = 30

type Watch = { root: BasePart, seats: { Instance }, since: number, samples: { { p: Vector3, v: number, w: number } } }
type Flag = { path: string, model: string, kind: string, max_speed: number, max_angvel: number, moved_studs: number, windows: number, last: number }

local watched: { [BasePart]: Watch } = {}
local watchedCount = 0
local flagged: { [string]: Flag } = {}
local flaggedCount = 0
local loudest: { [BasePart]: { path: string, max_speed: number, max_angvel: number } } = {}

local telemetry: any = nil
pcall(function()
	telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry", 5) :: ModuleScript)
end)

local function r2(x: number): number
	return math.floor(x * 100 + 0.5) / 100
end

local function controlled(part: BasePart): boolean
	local m = part:FindFirstAncestorOfClass("Model")
	local depth = 0
	while m and depth < 4 do
		if m:FindFirstChildOfClass("Humanoid") then
			return true
		end
		m = m:FindFirstAncestorOfClass("Model")
		depth += 1
	end
	return false
end

local function seatsOf(part: BasePart): { Instance }
	local seats = {}
	local m = part:FindFirstAncestorOfClass("Model")
	if m then
		for _, d in m:GetDescendants() do
			if d:IsA("Seat") or d:IsA("VehicleSeat") then
				table.insert(seats, d)
			end
		end
	end
	return seats
end

local function occupied(w: Watch): boolean
	for _, s in w.seats do
		if (s :: any).Occupant ~= nil then
			return true
		end
	end
	return false
end

local function rescan()
	local found: { BasePart } = {}
	for _, d in workspace:GetDescendants() do
		if d:IsA("BasePart") and not d.Anchored and d.AssemblyRootPart == d and d.AssemblyMass >= MIN_MASS then
			table.insert(found, d)
		end
	end
	table.sort(found, function(a, b)
		return a.AssemblyMass > b.AssemblyMass
	end)
	local keep: { [BasePart]: boolean } = {}
	local now = os.clock()
	local n = 0
	for _, part in found do
		if n >= MAX_ROOTS then
			break
		end
		if not controlled(part) then
			n += 1
			keep[part] = true
			if not watched[part] then
				watched[part] = { root = part, seats = seatsOf(part), since = now, samples = {} }
				watchedCount += 1
			end
		end
	end
	for part in watched do
		if not keep[part] then
			watched[part] = nil
			loudest[part] = nil
			watchedCount -= 1
		end
	end
end

local function classify(w: Watch): (string?, number, number, number)
	local s = w.samples
	local maxV, maxW, active = 0, 0, 0
	for _, x in s do
		maxV = math.max(maxV, x.v)
		maxW = math.max(maxW, x.w)
		if x.v > ACTIVE_SPEED or x.w > ACTIVE_ANGVEL then
			active += 1
		end
	end
	local net = (s[#s].p - s[1].p).Magnitude
	if active >= JITTER_ACTIVE and net < JITTER_MAX_NET then
		return "jitter", maxV, maxW, net
	end
	if active >= DRIFT_ACTIVE and net >= DRIFT_MIN_NET and maxV < DRIFT_MAX_SPEED then
		return "drift", maxV, maxW, net
	end
	return nil, maxV, maxW, net
end

local function sample()
	local now = os.clock()
	for part, w in watched do
		if not part.Parent or part.Anchored or part.AssemblyRootPart ~= part then
			watched[part] = nil
			loudest[part] = nil
			watchedCount -= 1
			continue
		end
		if occupied(w) or now - w.since < SETTLE_SECONDS then
			table.clear(w.samples)
			continue
		end
		table.insert(w.samples, { p = part.Position, v = part.AssemblyLinearVelocity.Magnitude, w = part.AssemblyAngularVelocity.Magnitude })
		if #w.samples > WINDOW then
			table.remove(w.samples, 1)
		end
		if #w.samples < WINDOW then
			continue
		end
		local kind, maxV, maxW, net = classify(w)
		local l = loudest[part]
		if not l then
			l = { path = part:GetFullName(), max_speed = 0, max_angvel = 0 }
			loudest[part] = l
		end
		l.max_speed = math.max(l.max_speed, r2(maxV))
		l.max_angvel = math.max(l.max_angvel, r2(maxW))
		if kind then
			local path = l.path
			local key = path .. "|" .. kind
			local f = flagged[key]
			if not f then
				if flaggedCount >= MAX_FLAGGED then
					continue
				end
				local m = part:FindFirstAncestorOfClass("Model")
				f = { path = path, model = if m then m:GetFullName() else "", kind = kind, max_speed = 0, max_angvel = 0, moved_studs = 0, windows = 0, last = 0 }
				flagged[key] = f
				flaggedCount += 1
				if telemetry then
					pcall(telemetry.count, "physics_" .. kind)
				end
			end
			f.max_speed = math.max(f.max_speed, r2(maxV))
			f.max_angvel = math.max(f.max_angvel, r2(maxW))
			f.moved_studs = math.max(f.moved_studs, r2(net))
			f.windows += 1
			f.last = r2(now - started)
			table.clear(w.samples) -- next window starts fresh, so `windows` counts distinct 4 s spans
		end
	end
end

local function physics()
	local list = {}
	for _, f in flagged do
		table.insert(list, f)
	end
	table.sort(list, function(a, b)
		return a.max_speed + a.max_angvel > b.max_speed + b.max_angvel
	end)
	local top = {}
	for _, l in loudest do
		table.insert(top, l)
	end
	table.sort(top, function(a, b)
		return a.max_speed + a.max_angvel > b.max_speed + b.max_angvel
	end)
	return {
		flagged = { table.unpack(list, 1, math.min(#list, 10)) },
		watched = watchedCount,
		loudest = { table.unpack(top, 1, math.min(#top, 3)) },
	}
end

task.spawn(function()
	local lastScan = -math.huge
	while true do
		task.wait(SAMPLE_EVERY)
		pcall(function()
			if os.clock() - lastScan >= RESCAN_EVERY then
				lastScan = os.clock()
				rescan()
			end
			sample()
		end)
	end
end)

local function report(): string
	local errs = {}
	for i, e in errors do
		errs[i] = { message = e.message, trace = e.trace, script = e.script, count = e.count }
	end
	local warns = {}
	for i, w in warnings do
		local c = warningCounts[w] or 1
		warns[i] = if c > 1 then w .. " (x" .. c .. ")" else w
	end
	if droppedErrors > 0 then
		table.insert(errs, { message = "(" .. droppedErrors .. " more distinct errors dropped)", trace = "", script = "", count = droppedErrors })
	end
	if droppedWarnings > 0 then
		table.insert(warns, "(" .. droppedWarnings .. " more distinct warnings dropped)")
	end
	local c = counters()
	local data = {
		uptime = math.floor((os.clock() - started) * 10 + 0.5) / 10,
		errors = errs,
		warnings = warns,
		players = #Players:GetPlayers(),
		joins = joins,
		counters = c,
		instances = #workspace:GetDescendants(),
		physics = physics(),
	}
	local json = HttpService:JSONEncode(data)
	if next(c) == nil then
		-- JSONEncode turns an empty table into [], the contract wants an object
		json = string.gsub(json, '"counters":%[%]', '"counters":{}')
	end
	return json
end

local function getOrCreate(name: string): BindableFunction
	local existing = ServerStorage:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local bf = Instance.new("BindableFunction")
	bf.Name = name
	bf.Parent = ServerStorage
	return bf
end

local probe = getOrCreate("ForgeProbe")
probe.OnInvoke = function(cmd: string?, ...)
	cmd = cmd or "report"
	if cmd == "report" then
		local ok, res = pcall(report)
		if ok then
			return res
		end
		return HttpService:JSONEncode({ error = "report failed: " .. tostring(res) })
	elseif cmd == "physics" then
		local ok, res = pcall(physics)
		return HttpService:JSONEncode(if ok then res else { error = tostring(res) })
	elseif cmd == "reset" then
		table.clear(errors)
		table.clear(errorIndex)
		table.clear(warnings)
		table.clear(warningCounts)
		droppedErrors, droppedWarnings = 0, 0
		started = os.clock()
		return "ok"
	elseif cmd == "hotreload" then
		-- (live ModuleScript, clone holding the new source), sent by forge Studio.hot_reload. This
		-- script shares the game's require cache, so the live table is the one every caller holds:
		-- copy the clone's functions into it and the next call runs the new code.
		local live, fresh = ...
		local ok, res = pcall(function()
			local old = require(live) :: any
			local new = require(fresh) :: any
			if type(old) ~= "table" or type(new) ~= "table" then
				error("module did not return a table")
			end
			local n = 0
			for k, v in new do
				if type(v) == "function" or old[k] == nil then
					old[k] = v
					n += 1
				end
			end
			return "reloaded " .. n
		end)
		return if ok then res else "error: " .. tostring(res)
	end
	return HttpService:JSONEncode({ error = "unknown command: " .. tostring(cmd) })
end

local function findModule(name: string): ModuleScript?
	for _, container in { ServerScriptService, ServerStorage, ReplicatedStorage } do
		for _, d in container:GetDescendants() do
			if d.Name == name and d:IsA("ModuleScript") then
				return d
			end
		end
	end
	return nil
end

local devHook = getOrCreate("DevHook")
devHook.OnInvoke = function(moduleName: string, method: string?, ...)
	local args = table.pack(...)
	local result = table.pack(pcall(function()
		local ms = findModule(moduleName)
		if not ms then
			error("DevHook: no ModuleScript named " .. tostring(moduleName))
		end
		local mod = require(ms) :: any
		if method == nil or method == "" then
			local keys = {}
			if type(mod) == "table" then
				for k in mod do
					table.insert(keys, tostring(k))
				end
				table.sort(keys)
			end
			return keys
		end
		local dot = string.sub(method, 1, 1) == "."
		local field = if dot then string.sub(method, 2) else method
		if type(mod) ~= "table" then
			error("DevHook: module " .. moduleName .. " returned a " .. type(mod) .. ", not a table")
		end
		local fn = mod[field]
		if type(fn) ~= "function" then
			return fn
		end
		if dot then
			return fn(table.unpack(args, 1, args.n))
		end
		return fn(mod, table.unpack(args, 1, args.n))
	end))
	if not result[1] then
		return false, tostring(result[2])
	end
	return table.unpack(result, 1, result.n)
end
