-- ForgeProbe: playtest error/telemetry collector for forge (Studio only).
--
-- ServerStorage.ForgeProbe (BindableFunction)
--   :Invoke("report") -> JSON string
--     {"uptime": 12.3, "errors": [{"message", "trace", "script", "count"}], "warnings": ["..."],
--      "players": 1, "joins": 1, "counters": {"coins_collected": 3}, "instances": 412}
--   :Invoke("reset")  -> clears errors/warnings, returns "ok"
--   :Invoke("hotreload", liveModule, cloneWithNewSource) -> "reloaded N" | "error: ..."
--     copies the clone's functions into the live module table (forge Studio.hot_reload)
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
