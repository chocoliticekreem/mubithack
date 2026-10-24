-- headless.luau: run a game's server code with the plain `luau` CLI, no Roblox Studio.
--
-- A small fake of the Roblox engine: an Instance tree with properties, attributes, tags and signals,
-- the common services (Players, RunService, TweenService, HttpService, DataStoreService, ...), the
-- datatypes (Vector3, CFrame, Color3, UDim2, Enum, ...) and a task scheduler on a simulated clock.
-- forge/checks.py bundles this file with a game's sources and calls H.main:
--   mode "boot":  run every server Script, let the simulated server run, join one player, report
--                 errors/warnings like ForgeProbe does.
--   mode "check": boot, then run one executable check body and report { ok, detail, error }.
-- It is a fake: anything it doesn't model reads as nil and is listed under "misses", so an error
-- next to a miss may be the shim's fault. Only trust it for logic; Studio stays the judge for
-- physics, rendering, replication and UI.

local H = {}

local realPrint = print
local OUT_MARK = "@@HEADLESS@@"

-- ============================================================================ report state

local errors: { any } = {}
local errorIndex: { [string]: any } = {}
local warnings: { string } = {}
local misses: { [string]: number } = {}
local prints = 0
local MAX_ITEMS = 50

local function clip(s: any, n: number): string
	local str = tostring(s)
	if #str > n then
		return string.sub(str, 1, n) .. "..."
	end
	return str
end

local function addError(message: any, trace: string?, scriptName: string?)
	local msg = clip(message, 500)
	local e = errorIndex[msg]
	if e then
		e.count += 1
		return
	end
	if #errors >= MAX_ITEMS then
		return
	end
	e = { message = msg, trace = clip(trace or "", 1000), script = scriptName or "", count = 1 }
	errorIndex[msg] = e
	table.insert(errors, e)
end

local function addWarning(msg: any)
	if #warnings < MAX_ITEMS then
		table.insert(warnings, clip(msg, 500))
	end
end

local function miss(what: string)
	misses[what] = (misses[what] or 0) + 1
end

-- ============================================================================ JSON

local function jsonEncode(v: any, seen: { [any]: boolean }?): string
	local t = type(v)
	if t == "nil" then
		return "null"
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return "null"
		end
		if v == math.floor(v) and math.abs(v) < 1e15 then
			return string.format("%d", v)
		end
		return string.format("%.14g", v)
	elseif t == "string" then
		local s = string.gsub(v, '[%c"\\]', function(c)
			local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
			return map[c] or string.format("\\u%04x", string.byte(c))
		end)
		return '"' .. s .. '"'
	elseif t == "table" then
		seen = seen or {}
		if (seen :: any)[v] then
			return "null"
		end
		(seen :: any)[v] = true
		local n = #v
		local isArray = n > 0 or next(v) == nil
		if isArray then
			for k in v do
				if type(k) ~= "number" then
					isArray = false
					break
				end
			end
		end
		local parts = {}
		if isArray then
			for i = 1, n do
				parts[i] = jsonEncode(v[i], seen)
			end
			;(seen :: any)[v] = nil
			return "[" .. table.concat(parts, ",") .. "]"
		end
		for k, val in v do
			table.insert(parts, jsonEncode(tostring(k)) .. ":" .. jsonEncode(val, seen))
		end
		;(seen :: any)[v] = nil
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return jsonEncode(tostring(v))
end

local function jsonDecode(s: string): any
	local i = 1
	local function ws()
		i = string.find(s, "[^ \t\r\n]", i) or (#s + 1)
	end
	local value
	local function str(): string
		i += 1
		local buf = {}
		while true do
			local c = string.sub(s, i, i)
			if c == "" then
				error("JSON: unterminated string")
			elseif c == '"' then
				i += 1
				break
			elseif c == "\\" then
				local e = string.sub(s, i + 1, i + 1)
				local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
				if e == "u" then
					local code = tonumber(string.sub(s, i + 2, i + 5), 16) or 63
					table.insert(buf, utf8.char(code))
					i += 6
				else
					table.insert(buf, map[e] or e)
					i += 2
				end
			else
				table.insert(buf, c)
				i += 1
			end
		end
		return table.concat(buf)
	end
	function value(): any
		ws()
		local c = string.sub(s, i, i)
		if c == "{" then
			i += 1
			local obj = {}
			ws()
			if string.sub(s, i, i) == "}" then
				i += 1
				return obj
			end
			while true do
				ws()
				local k = str()
				ws()
				i += 1 -- :
				obj[k] = value()
				ws()
				local d = string.sub(s, i, i)
				i += 1
				if d == "}" then
					return obj
				end
			end
		elseif c == "[" then
			i += 1
			local arr = {}
			ws()
			if string.sub(s, i, i) == "]" then
				i += 1
				return arr
			end
			while true do
				table.insert(arr, value())
				ws()
				local d = string.sub(s, i, i)
				i += 1
				if d == "]" then
					return arr
				end
			end
		elseif c == '"' then
			return str()
		elseif string.sub(s, i, i + 3) == "true" then
			i += 4
			return true
		elseif string.sub(s, i, i + 4) == "false" then
			i += 5
			return false
		elseif string.sub(s, i, i + 3) == "null" then
			i += 4
			return nil
		end
		local num = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", i)
		if not num or num == "" then
			error("JSON: unexpected '" .. c .. "' at " .. i)
		end
		i += #num
		return tonumber(num)
	end
	return value()
end

H.jsonEncode = jsonEncode
H.jsonDecode = jsonDecode

-- ============================================================================ scheduler

local now = 0
local FRAME = 1 / 30
local queue: { { co: thread, wake: number, args: { any }? } } = {}
local threadScript: { [thread]: string } = setmetatable({}, { __mode = "k" }) :: any

local function scriptOf(co: thread?): string
	return (co and threadScript[co]) or "?"
end

local function resume(co: thread, ...)
	if coroutine.status(co) ~= "suspended" then
		return
	end
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		addError(err, debug.traceback(co), scriptOf(co))
	end
end

local function spawnThread(fn: any, ...): thread
	local co = if type(fn) == "thread" then fn else coroutine.create(fn)
	local parent = coroutine.running()
	if parent and threadScript[parent] then
		threadScript[co] = threadScript[parent]
	end
	resume(co, ...)
	return co
end

local function schedule(co: thread, delay: number, args: { any }?)
	table.insert(queue, { co = co, wake = now + delay, args = args })
end

local function yieldFor(seconds: number?): number
	local co = coroutine.running()
	if not coroutine.isyieldable() then
		error("task.wait called from a non-yieldable thread")
	end
	local start = now
	schedule(co, math.max(seconds or 0, FRAME))
	coroutine.yield()
	return now - start
end

local task = {
	wait = function(s: number?)
		return yieldFor(s)
	end,
	spawn = function(fn: any, ...)
		return spawnThread(fn, ...)
	end,
	defer = function(fn: any, ...)
		local co = if type(fn) == "thread" then fn else coroutine.create(fn)
		local parent = coroutine.running()
		if parent and threadScript[parent] then
			threadScript[co] = threadScript[parent]
		end
		schedule(co, 0, table.pack(...))
		return co
	end,
	delay = function(t: number?, fn: any, ...)
		local co = if type(fn) == "thread" then fn else coroutine.create(fn)
		local parent = coroutine.running()
		if parent and threadScript[parent] then
			threadScript[co] = threadScript[parent]
		end
		schedule(co, t or 0, table.pack(...))
		return co
	end,
	cancel = function(co: thread)
		for i = #queue, 1, -1 do
			if queue[i].co == co then
				table.remove(queue, i)
			end
		end
		pcall(coroutine.close, co)
	end,
	synchronize = function() end,
	desynchronize = function() end,
}

-- ============================================================================ signals

local Signal = {}
Signal.__index = Signal
Signal.__type = "RBXScriptSignal"

local function newSignal(name: string?)
	return setmetatable({ name = name, conns = {}, waiting = {} }, Signal)
end

local Connection = {}
Connection.__index = Connection
Connection.__type = "RBXScriptConnection"

function Signal:Connect(fn)
	local running = coroutine.running()
	local c = setmetatable({ fn = fn, Connected = true, signal = self, owner = running and threadScript[running] }, Connection)
	table.insert(self.conns, c)
	return c
end
Signal.connect = Signal.Connect

function Signal:Once(fn)
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		fn(...)
	end)
	return c
end

function Signal:ConnectParallel(fn)
	return self:Connect(fn)
end

function Signal:Wait()
	local co = coroutine.running()
	table.insert(self.waiting, co)
	return coroutine.yield()
end

function Signal:Fire(...)
	for _, c in table.clone(self.conns) do
		if c.Connected then
			local co = coroutine.create(c.fn)
			local parent = coroutine.running()
			-- the callback belongs to the script that connected it
			threadScript[co] = c.owner or (parent and threadScript[parent]) or nil
			resume(co, ...)
		end
	end
	local waiting = self.waiting
	self.waiting = {}
	for _, co in waiting do
		resume(co, ...)
	end
end

function Connection:Disconnect()
	self.Connected = false
	local list = self.signal.conns
	for i, c in list do
		if c == self then
			table.remove(list, i)
			break
		end
	end
end
Connection.disconnect = Connection.Disconnect

-- ============================================================================ datatypes

local function typed(name: string, index: any)
	local mt = { __type = name }
	return mt
end

-- Vector3 -------------------------------------------------------------------
local V3 = typed("Vector3")
local Vector3: any = {}
local function v3(x: number?, y: number?, z: number?)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3)
end
Vector3.new = v3
Vector3.zero = v3(0, 0, 0)
Vector3.one = v3(1, 1, 1)
Vector3.xAxis = v3(1, 0, 0)
Vector3.yAxis = v3(0, 1, 0)
Vector3.zAxis = v3(0, 0, 1)
local V3methods = {}
V3.__index = function(v, k)
	if k == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	elseif k == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		if m == 0 then
			return v3(0 / 0, 0 / 0, 0 / 0)
		end
		return v3(v.X / m, v.Y / m, v.Z / m)
	elseif k == "x" then
		return v.X
	elseif k == "y" then
		return v.Y
	elseif k == "z" then
		return v.Z
	end
	return V3methods[k]
end
V3.__add = function(a, b)
	return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V3.__sub = function(a, b)
	return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V3.__mul = function(a, b)
	if type(a) == "number" then
		return v3(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return v3(a.X * b, a.Y * b, a.Z * b)
	end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3.__div = function(a, b)
	if type(b) == "number" then
		return v3(a.X / b, a.Y / b, a.Z / b)
	elseif type(a) == "number" then
		return v3(a / b.X, a / b.Y, a / b.Z)
	end
	return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
V3.__idiv = function(a, b)
	return v3(a.X // b, a.Y // b, a.Z // b)
end
V3.__unm = function(a)
	return v3(-a.X, -a.Y, -a.Z)
end
V3.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
V3.__tostring = function(a)
	return string.format("%g, %g, %g", a.X, a.Y, a.Z)
end
function V3methods.Dot(a, b)
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end
function V3methods.Cross(a, b)
	return v3(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
end
function V3methods.Lerp(a, b, t)
	return a + (b - a) * t
end
function V3methods.FuzzyEq(a, b, eps)
	return (a - b).Magnitude <= (eps or 1e-5)
end
function V3methods.Abs(a)
	return v3(math.abs(a.X), math.abs(a.Y), math.abs(a.Z))
end
function V3methods.Floor(a)
	return v3(math.floor(a.X), math.floor(a.Y), math.floor(a.Z))
end
function V3methods.Ceil(a)
	return v3(math.ceil(a.X), math.ceil(a.Y), math.ceil(a.Z))
end
function V3methods.Sign(a)
	return v3(math.sign(a.X), math.sign(a.Y), math.sign(a.Z))
end
function V3methods.Min(a, b)
	return v3(math.min(a.X, b.X), math.min(a.Y, b.Y), math.min(a.Z, b.Z))
end
function V3methods.Max(a, b)
	return v3(math.max(a.X, b.X), math.max(a.Y, b.Y), math.max(a.Z, b.Z))
end
function V3methods.Angle(a, b)
	local d = a:Dot(b) / math.max(a.Magnitude * b.Magnitude, 1e-12)
	return math.acos(math.clamp(d, -1, 1))
end
Vector3.FromNormalId = function()
	return v3(0, 1, 0)
end
Vector3.FromAxis = Vector3.FromNormalId

-- Vector2 -------------------------------------------------------------------
local V2 = typed("Vector2")
local Vector2: any = {}
local function v2(x: number?, y: number?)
	return setmetatable({ X = x or 0, Y = y or 0 }, V2)
end
Vector2.new = v2
Vector2.zero = v2(0, 0)
Vector2.one = v2(1, 1)
Vector2.xAxis = v2(1, 0)
Vector2.yAxis = v2(0, 1)
V2.__index = function(v, k)
	if k == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y)
	elseif k == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y)
		return v2(v.X / m, v.Y / m)
	elseif k == "Dot" then
		return function(a, b)
			return a.X * b.X + a.Y * b.Y
		end
	elseif k == "Lerp" then
		return function(a, b, t)
			return v2(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t)
		end
	elseif k == "Cross" then
		return function(a, b)
			return a.X * b.Y - a.Y * b.X
		end
	end
	return nil
end
V2.__add = function(a, b)
	return v2(a.X + b.X, a.Y + b.Y)
end
V2.__sub = function(a, b)
	return v2(a.X - b.X, a.Y - b.Y)
end
V2.__mul = function(a, b)
	if type(a) == "number" then
		return v2(a * b.X, a * b.Y)
	elseif type(b) == "number" then
		return v2(a.X * b, a.Y * b)
	end
	return v2(a.X * b.X, a.Y * b.Y)
end
V2.__div = function(a, b)
	if type(b) == "number" then
		return v2(a.X / b, a.Y / b)
	end
	return v2(a.X / b.X, a.Y / b.Y)
end
V2.__unm = function(a)
	return v2(-a.X, -a.Y)
end
V2.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y
end
V2.__tostring = function(a)
	return string.format("%g, %g", a.X, a.Y)
end

-- CFrame (position + 3x3 rotation, rows) -----------------------------------
local CF = typed("CFrame")
local CFrame: any = {}
local function cf(px, py, pz, r00, r01, r02, r10, r11, r12, r20, r21, r22)
	return setmetatable({
		p = v3(px, py, pz),
		r = { r00 or 1, r01 or 0, r02 or 0, r10 or 0, r11 or 1, r12 or 0, r20 or 0, r21 or 0, r22 or 1 },
	}, CF)
end
local function cfRot(c, x, y, z) -- rotation applied to a vector
	local r = c.r
	return r[1] * x + r[2] * y + r[3] * z, r[4] * x + r[5] * y + r[6] * z, r[7] * x + r[8] * y + r[9] * z
end
local function mulRot(a, b)
	local A, B = a, b
	local o = {}
	for i = 0, 2 do
		for j = 0, 2 do
			o[i * 3 + j + 1] = A[i * 3 + 1] * B[j + 1] + A[i * 3 + 2] * B[3 + j + 1] + A[i * 3 + 3] * B[6 + j + 1]
		end
	end
	return o
end
local function fromRot(p, r)
	return cf(p.X, p.Y, p.Z, r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9])
end
local function rotX(a)
	local c, s = math.cos(a), math.sin(a)
	return { 1, 0, 0, 0, c, -s, 0, s, c }
end
local function rotY(a)
	local c, s = math.cos(a), math.sin(a)
	return { c, 0, s, 0, 1, 0, -s, 0, c }
end
local function rotZ(a)
	local c, s = math.cos(a), math.sin(a)
	return { c, -s, 0, s, c, 0, 0, 0, 1 }
end
local function lookAt(pos, target, up)
	local f = (target - pos)
	if f.Magnitude < 1e-9 then
		return fromRot(pos, { 1, 0, 0, 0, 1, 0, 0, 0, 1 })
	end
	f = f.Unit
	up = up or v3(0, 1, 0)
	local r = f:Cross(up)
	if r.Magnitude < 1e-9 then
		r = v3(1, 0, 0)
	end
	r = r.Unit
	local u = r:Cross(f)
	-- columns are Right, Up, Back (-Look)
	return fromRot(pos, { r.X, u.X, -f.X, r.Y, u.Y, -f.Y, r.Z, u.Z, -f.Z })
end
CFrame.new = function(a, b, c, ...)
	if a == nil then
		return cf(0, 0, 0)
	elseif type(a) == "table" then
		if b ~= nil then
			return lookAt(a, b)
		end
		return cf(a.X, a.Y, a.Z)
	end
	local rest = { ... }
	if #rest == 9 then
		return cf(a, b, c, table.unpack(rest))
	end
	return cf(a, b or 0, c or 0)
end
CFrame.identity = cf(0, 0, 0)
CFrame.lookAt = function(p, t, up)
	return lookAt(p, t, up)
end
CFrame.Angles = function(x, y, z)
	return fromRot(Vector3.zero, mulRot(mulRot(rotX(x or 0), rotY(y or 0)), rotZ(z or 0)))
end
CFrame.fromEulerAnglesXYZ = CFrame.Angles
CFrame.fromEulerAnglesYXZ = function(x, y, z)
	return fromRot(Vector3.zero, mulRot(mulRot(rotY(y or 0), rotX(x or 0)), rotZ(z or 0)))
end
CFrame.fromOrientation = CFrame.fromEulerAnglesYXZ
CFrame.fromAxisAngle = function(axis, angle)
	local u = axis.Unit
	local c, s = math.cos(angle), math.sin(angle)
	local t = 1 - c
	local x, y, z = u.X, u.Y, u.Z
	return fromRot(Vector3.zero, {
		t * x * x + c, t * x * y - s * z, t * x * z + s * y,
		t * x * y + s * z, t * y * y + c, t * y * z - s * x,
		t * x * z - s * y, t * y * z + s * x, t * z * z + c,
	})
end
CFrame.fromMatrix = function(pos, rx, ry, rz)
	rz = rz or rx:Cross(ry)
	return fromRot(pos, { rx.X, ry.X, rz.X, rx.Y, ry.Y, rz.Y, rx.Z, ry.Z, rz.Z })
end
local CFmethods = {}
CF.__index = function(c, k)
	if k == "Position" or k == "p" then
		return rawget(c, "p")
	elseif k == "X" then
		return c.p.X
	elseif k == "Y" then
		return c.p.Y
	elseif k == "Z" then
		return c.p.Z
	elseif k == "LookVector" then
		return v3(-c.r[3], -c.r[6], -c.r[9])
	elseif k == "RightVector" or k == "XVector" then
		return v3(c.r[1], c.r[4], c.r[7])
	elseif k == "UpVector" or k == "YVector" then
		return v3(c.r[2], c.r[5], c.r[8])
	elseif k == "ZVector" then
		return v3(c.r[3], c.r[6], c.r[9])
	elseif k == "Rotation" then
		return fromRot(Vector3.zero, c.r)
	end
	return CFmethods[k]
end
local function transpose(r)
	return { r[1], r[4], r[7], r[2], r[5], r[8], r[3], r[6], r[9] }
end
CF.__mul = function(a, b)
	if getmetatable(b) == V3 then
		local x, y, z = cfRot(a, b.X, b.Y, b.Z)
		return v3(a.p.X + x, a.p.Y + y, a.p.Z + z)
	end
	local x, y, z = cfRot(a, b.p.X, b.p.Y, b.p.Z)
	return fromRot(v3(a.p.X + x, a.p.Y + y, a.p.Z + z), mulRot(a.r, b.r))
end
CF.__add = function(a, b)
	return fromRot(a.p + b, a.r)
end
CF.__sub = function(a, b)
	return fromRot(a.p - b, a.r)
end
CF.__eq = function(a, b)
	if a.p ~= b.p then
		return false
	end
	for i = 1, 9 do
		if a.r[i] ~= b.r[i] then
			return false
		end
	end
	return true
end
CF.__tostring = function(c)
	return tostring(c.p) .. ", " .. table.concat(c.r, ", ")
end
function CFmethods.Inverse(c)
	local rt = transpose(c.r)
	local inv = fromRot(Vector3.zero, rt)
	local x, y, z = cfRot(inv, -c.p.X, -c.p.Y, -c.p.Z)
	return fromRot(v3(x, y, z), rt)
end
function CFmethods.ToWorldSpace(a, b)
	return a * b
end
function CFmethods.ToObjectSpace(a, b)
	return a:Inverse() * b
end
function CFmethods.PointToWorldSpace(a, v)
	return a * v
end
function CFmethods.PointToObjectSpace(a, v)
	return a:Inverse() * v
end
function CFmethods.VectorToWorldSpace(a, v)
	return v3(cfRot(a, v.X, v.Y, v.Z))
end
function CFmethods.VectorToObjectSpace(a, v)
	return v3(cfRot(fromRot(Vector3.zero, transpose(a.r)), v.X, v.Y, v.Z))
end
function CFmethods.Lerp(a, b, t)
	return fromRot(a.p:Lerp(b.p, t), if t < 0.5 then a.r else b.r)
end
function CFmethods.GetComponents(c)
	return c.p.X, c.p.Y, c.p.Z, table.unpack(c.r)
end
CFmethods.components = CFmethods.GetComponents
function CFmethods.ToEulerAnglesXYZ(c)
	local r = c.r
	local y = math.asin(math.clamp(r[3], -1, 1))
	local x = math.atan2(-r[6], r[9])
	local z = math.atan2(-r[2], r[1])
	return x, y, z
end
function CFmethods.ToOrientation(c)
	local r = c.r
	local x = math.asin(math.clamp(-r[6], -1, 1))
	local y = math.atan2(r[3], r[9])
	local z = math.atan2(r[4], r[5])
	return x, y, z
end
CFmethods.ToEulerAnglesYXZ = CFmethods.ToOrientation
function CFmethods.ToAxisAngle(c)
	return v3(0, 1, 0), 0
end
function CFmethods.Orthonormalize(c)
	return c
end
function CFmethods.FuzzyEq(a, b, eps)
	return (a.p - b.p).Magnitude <= (eps or 1e-5)
end

-- Color3 --------------------------------------------------------------------
local C3 = typed("Color3")
local Color3: any = {}
local function c3(r, g, b)
	return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, C3)
end
C3.__index = function(c, k)
	if k == "r" then
		return c.R
	elseif k == "g" then
		return c.G
	elseif k == "b" then
		return c.B
	elseif k == "Lerp" then
		return function(a, b, t)
			return c3(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
		end
	elseif k == "ToHSV" then
		return function(a)
			local mx, mn = math.max(a.R, a.G, a.B), math.min(a.R, a.G, a.B)
			local d = mx - mn
			local h = 0
			if d > 0 then
				if mx == a.R then
					h = ((a.G - a.B) / d) % 6
				elseif mx == a.G then
					h = (a.B - a.R) / d + 2
				else
					h = (a.R - a.G) / d + 4
				end
				h /= 6
			end
			return h, if mx > 0 then d / mx else 0, mx
		end
	elseif k == "ToHex" then
		return function(a)
			return string.format("%02x%02x%02x", a.R * 255, a.G * 255, a.B * 255)
		end
	end
	return nil
end
C3.__eq = function(a, b)
	return a.R == b.R and a.G == b.G and a.B == b.B
end
C3.__tostring = function(c)
	return string.format("%g, %g, %g", c.R, c.G, c.B)
end
Color3.new = c3
Color3.fromRGB = function(r, g, b)
	return c3((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
end
Color3.fromHSV = function(h, s, v)
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	local m = i % 6
	if m == 0 then
		return c3(v, t, p)
	elseif m == 1 then
		return c3(q, v, p)
	elseif m == 2 then
		return c3(p, v, t)
	elseif m == 3 then
		return c3(p, q, v)
	elseif m == 4 then
		return c3(t, p, v)
	end
	return c3(v, p, q)
end
Color3.fromHex = function(hex)
	hex = string.gsub(hex, "#", "")
	return Color3.fromRGB(tonumber(string.sub(hex, 1, 2), 16), tonumber(string.sub(hex, 3, 4), 16), tonumber(string.sub(hex, 5, 6), 16))
end
Color3.toHSV = function(c)
	return c:ToHSV()
end

-- UDim / UDim2 -------------------------------------------------------------------
local UD = typed("UDim")
UD.__index = {}
local function udim(s, o)
	return setmetatable({ Scale = s or 0, Offset = o or 0 }, UD)
end
UD.__add = function(a, b)
	return udim(a.Scale + b.Scale, a.Offset + b.Offset)
end
UD.__sub = function(a, b)
	return udim(a.Scale - b.Scale, a.Offset - b.Offset)
end
UD.__eq = function(a, b)
	return a.Scale == b.Scale and a.Offset == b.Offset
end
local UDim: any = { new = udim }
local U2 = typed("UDim2")
local function udim2(xs, xo, ys, yo)
	if type(xs) == "table" then
		return setmetatable({ X = xs, Y = xo }, U2)
	end
	return setmetatable({ X = udim(xs, xo), Y = udim(ys, yo) }, U2)
end
U2.__index = function(u, k)
	if k == "Width" then
		return u.X
	elseif k == "Height" then
		return u.Y
	elseif k == "Lerp" then
		return function(a, b, t)
			return udim2(
				a.X.Scale + (b.X.Scale - a.X.Scale) * t,
				a.X.Offset + (b.X.Offset - a.X.Offset) * t,
				a.Y.Scale + (b.Y.Scale - a.Y.Scale) * t,
				a.Y.Offset + (b.Y.Offset - a.Y.Offset) * t
			)
		end
	end
	return nil
end
U2.__add = function(a, b)
	return udim2(a.X + b.X, a.Y + b.Y)
end
U2.__sub = function(a, b)
	return udim2(a.X - b.X, a.Y - b.Y)
end
U2.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y
end
local UDim2: any = {
	new = udim2,
	fromScale = function(x, y)
		return udim2(x, 0, y, 0)
	end,
	fromOffset = function(x, y)
		return udim2(0, x, 0, y)
	end,
}

-- simple value types --------------------------------------------------------------
local function record(typeName: string, fields: { string })
	local mt = { __type = typeName }
	mt.__index = function()
		return nil
	end
	return function(...)
		local args = { ... }
		local o = {}
		for i, f in fields do
			o[f] = args[i]
		end
		return setmetatable(o, mt)
	end
end
local NumberRange: any = {
	new = function(a, b)
		return setmetatable({ Min = a, Max = b or a }, { __type = "NumberRange" })
	end,
}
local NumberSequenceKeypoint: any = { new = record("NumberSequenceKeypoint", { "Time", "Value", "Envelope" }) }
local ColorSequenceKeypoint: any = { new = record("ColorSequenceKeypoint", { "Time", "Value" }) }
local NumberSequence: any = {
	new = function(a, b)
		local kps = if type(a) == "table" and getmetatable(a) == nil then a
			else { NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, b or a) }
		return setmetatable({ Keypoints = kps }, { __type = "NumberSequence" })
	end,
}
local ColorSequence: any = {
	new = function(a, b)
		local kps = if type(a) == "table" and getmetatable(a) == nil then a
			else { ColorSequenceKeypoint.new(0, a), ColorSequenceKeypoint.new(1, b or a) }
		return setmetatable({ Keypoints = kps }, { __type = "ColorSequence" })
	end,
}
local TweenInfo: any = {
	new = record("TweenInfo", { "Time", "EasingStyle", "EasingDirection", "RepeatCount", "Reverses", "DelayTime" }),
}
local Rect: any = { new = record("Rect", { "MinX", "MinY", "MaxX", "MaxY" }) }
local Ray: any = {
	new = function(o, d)
		return setmetatable({ Origin = o, Direction = d, Unit = nil }, { __type = "Ray" })
	end,
}
local PhysicalProperties: any = { new = record("PhysicalProperties", { "Density", "Friction", "Elasticity" }) }
local Region3: any = {
	new = function(a, b)
		return setmetatable({ CFrame = cf((a.X + b.X) / 2, (a.Y + b.Y) / 2, (a.Z + b.Z) / 2), Size = b - a }, { __type = "Region3" })
	end,
}
local function paramsType(name: string)
	return {
		new = function()
			return setmetatable({ FilterDescendantsInstances = {}, FilterType = nil, IgnoreWater = false, CollisionGroup = "Default", RespectCanCollide = false, MaxParts = 0 }, {
				__type = name,
				__index = {
					AddToFilter = function(self, x)
						table.insert(self.FilterDescendantsInstances, x)
					end,
				},
			})
		end,
	}
end
local RaycastParams: any = paramsType("RaycastParams")
local OverlapParams: any = paramsType("OverlapParams")
local Font: any = {
	new = record("Font", { "Family", "Weight", "Style" }),
	fromEnum = function(e)
		return setmetatable({ Family = tostring(e) }, { __type = "Font" })
	end,
	fromName = function(n)
		return setmetatable({ Family = n }, { __type = "Font" })
	end,
	fromId = function(n)
		return setmetatable({ Family = tostring(n) }, { __type = "Font" })
	end,
}
local BrickColor: any = {}
local function brick(name)
	return setmetatable({ Name = tostring(name), Color = c3(0.5, 0.5, 0.5), Number = 0 }, { __type = "BrickColor", __tostring = function(b)
		return b.Name
	end })
end
BrickColor.new = brick
BrickColor.random = function()
	return brick("Random")
end
for _, n in { "White", "Gray", "DarkGray", "Black", "Red", "Yellow", "Green", "Blue" } do
	BrickColor[n] = function()
		return brick(n)
	end
end
local DateTime: any = {
	now = function()
		local t = os.time() + now
		return setmetatable({ UnixTimestamp = math.floor(t), UnixTimestampMillis = math.floor(t * 1000) }, {
			__type = "DateTime",
			__index = {
				FormatUniversalTime = function()
					return "1970-01-01"
				end,
				FormatLocalTime = function()
					return "1970-01-01"
				end,
				ToIsoDate = function()
					return "1970-01-01T00:00:00Z"
				end,
			},
		})
	end,
}
DateTime.fromUnixTimestamp = function(t)
	return setmetatable({ UnixTimestamp = t, UnixTimestampMillis = t * 1000 }, { __type = "DateTime" })
end
local RandomT = { __type = "Random" }
RandomT.__index = {
	NextNumber = function(self, a, b)
		a, b = a or 0, b or 1
		return a + math.random() * (b - a)
	end,
	NextInteger = function(self, a, b)
		return math.random(a, b)
	end,
	NextUnitVector = function()
		return v3(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5).Unit
	end,
	Shuffle = function(self, t)
		for i = #t, 2, -1 do
			local j = math.random(1, i)
			t[i], t[j] = t[j], t[i]
		end
	end,
	Clone = function(self)
		return self
	end,
}
local Random: any = {
	new = function(seed)
		return setmetatable({}, RandomT)
	end,
}

-- Enum ----------------------------------------------------------------------------
local enumItems: { [string]: { [string]: any } } = {}
local EnumItemMT = { __type = "EnumItem" }
EnumItemMT.__tostring = function(e)
	return "Enum." .. e.EnumType.Name .. "." .. e.Name
end
EnumItemMT.__index = {
	IsA = function(self, t)
		return self.EnumType.Name == t
	end,
}
local EnumTypeMT = { __type = "Enum" }
local function enumType(name: string)
	local items = enumItems[name]
	if not items then
		items = {}
		enumItems[name] = items
	end
	local et = { Name = name }
	return setmetatable(et, {
		__type = "Enum",
		__index = function(_, item)
			if item == "GetEnumItems" then
				return function()
					local out = {}
					for _, v in items do
						table.insert(out, v)
					end
					return out
				end
			elseif item == "FromName" then
				return function(_, n)
					return (et :: any)[n]
				end
			elseif item == "FromValue" then
				return function(_, v)
					for _, it in items do
						if it.Value == v then
							return it
						end
					end
					return nil
				end
			end
			local e = items[item]
			if not e then
				local n = 0
				for _ in items do
					n += 1
				end
				e = setmetatable({ Name = item, Value = n, EnumType = et }, EnumItemMT)
				items[item] = e
			end
			return e
		end,
		__tostring = function()
			return name
		end,
	})
end
local enumTypes: { [string]: any } = {}
local Enum: any = setmetatable({}, {
	__index = function(_, name)
		local t = enumTypes[name]
		if not t then
			t = enumType(name)
			enumTypes[name] = t
		end
		return t
	end,
})

-- ============================================================================ instances

local data: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any
local Inst = { __type = "Instance" }
local Methods: { [string]: any } = {}
local ClassMethods: { [string]: { [string]: any } } = {}
local tagged: { [string]: { [any]: boolean } } = {}
local tagAdded: { [string]: any } = {}
local tagRemoved: { [string]: any } = {}

local SUPER: { [string]: string } = {
	Part = "BasePart", MeshPart = "BasePart", WedgePart = "BasePart", CornerWedgePart = "BasePart",
	TrussPart = "BasePart", SpawnLocation = "Part", Seat = "Part", VehicleSeat = "BasePart",
	UnionOperation = "BasePart", Terrain = "BasePart", BasePart = "PVInstance", Model = "PVInstance",
	PVInstance = "Instance", Workspace = "Model", Actor = "Model",
	Frame = "GuiObject", TextLabel = "GuiObject", TextButton = "GuiButton", ImageLabel = "GuiObject",
	ImageButton = "GuiButton", ScrollingFrame = "GuiObject", TextBox = "GuiObject", ViewportFrame = "GuiObject",
	CanvasGroup = "GuiObject", GuiButton = "GuiObject", GuiObject = "GuiBase2d", GuiBase2d = "Instance",
	ScreenGui = "LayerCollector", SurfaceGui = "LayerCollector", BillboardGui = "LayerCollector",
	LayerCollector = "GuiBase2d",
	IntValue = "ValueBase", NumberValue = "ValueBase", StringValue = "ValueBase", BoolValue = "ValueBase",
	ObjectValue = "ValueBase", Vector3Value = "ValueBase", CFrameValue = "ValueBase", Color3Value = "ValueBase",
	BrickColorValue = "ValueBase", RayValue = "ValueBase",
	Script = "BaseScript", LocalScript = "BaseScript", BaseScript = "LuaSourceContainer",
	ModuleScript = "LuaSourceContainer",
	PointLight = "Light", SpotLight = "Light", SurfaceLight = "Light",
	Weld = "JointInstance", Motor6D = "JointInstance", WeldConstraint = "Instance",
	Tool = "BackpackItem", HopperBin = "BackpackItem",
	Decal = "FaceInstance", Texture = "Decal",
	SpecialMesh = "DataModelMesh", BlockMesh = "DataModelMesh",
}
local function isA(class: string, want: string): boolean
	local c: string? = class
	while c do
		if c == want then
			return true
		end
		c = SUPER[c]
	end
	return want == "Instance"
end

local EVENTS = {}
for _, n in {
	"Changed", "ChildAdded", "ChildRemoved", "DescendantAdded", "DescendantRemoving", "AncestryChanged",
	"Destroying", "AttributeChanged", "Touched", "TouchEnded", "PlayerAdded", "PlayerRemoving",
	"CharacterAdded", "CharacterRemoving", "CharacterAppearanceLoaded", "Heartbeat", "Stepped",
	"RenderStepped", "PreSimulation", "PostSimulation", "PreRender", "PreAnimation", "OnServerEvent",
	"OnClientEvent", "Event", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "MouseButton2Click",
	"MouseEnter", "MouseLeave", "Activated", "Deactivated", "Triggered", "TriggerEnded", "PromptButtonHoldBegan",
	"PromptButtonHoldEnded", "PromptShown", "PromptHidden", "Died", "HealthChanged", "Running", "Jumping",
	"StateChanged", "MoveToFinished", "Seated", "FreeFalling", "InputBegan", "InputEnded", "InputChanged",
	"Equipped", "Unequipped", "Completed", "Played", "Ended", "Stopped", "DidLoop", "Loaded", "FocusLost",
	"Focused", "Chatted", "Idled", "MessageOut", "Error", "PromptProductPurchaseFinished",
	"PromptGamePassPurchaseFinished", "PromptPurchaseFinished", "ChildRemoving", "ReachedTarget",
	"Blocked", "WaypointReached", "OnInvoke_", "KeyframeReached", "LocalToolEquipped", "OnServerInvoke_",
	"TouchTap", "JumpRequest", "WindowFocused", "WindowFocusReleased", "LastInputTypeChanged",
	"ProximityPromptTriggered", "PromptTriggered", "MessageReceived", "SendingMessage",
} do
	EVENTS[n] = true
end

local DEFAULTS: { [string]: any } = {
	Archivable = true, Anchored = false, CanCollide = true, CanTouch = true, CanQuery = true,
	Transparency = 0, Reflectance = 0, Massless = false, Locked = false, CastShadow = true,
	Visible = true, Enabled = true, Active = false, Disabled = false, Health = 100, MaxHealth = 100,
	WalkSpeed = 16, JumpPower = 50, JumpHeight = 7.2, HipHeight = 2, Text = "", TextSize = 14,
	BackgroundTransparency = 0, ImageTransparency = 0, TextTransparency = 0, ZIndex = 1, LayoutOrder = 0,
	Brightness = 1, Range = 8, Volume = 0.5, PlaybackSpeed = 1, Looped = false, IsPlaying = false,
	TimePosition = 0, Rate = 5, Lifetime = nil, MaxActivationDistance = 10, HoldDuration = 0,
	ActionText = "", ObjectText = "", RequiresHandle = true, CanBeDropped = true, Gravity = 196.2,
	DistributedGameTime = 0, RespawnTime = 5, AutoJumpEnabled = true, PlatformStand = false, Sit = false,
	DisplayName = "", Image = "", SoundId = "", AnimationId = "", MeshId = "", TextureID = "", Texture = "",
	ResetOnSpawn = true, IgnoreGuiInset = false, AlwaysOnTop = false, MaxDistance = 1000, Thickness = 1,
	Score = 0, Material = nil, Shape = nil, Style = nil, TeamColor = nil, Neutral = true,
	AutoAssignable = true, ClipsDescendants = false, AutoButtonColor = true, Selectable = false,
	TextWrapped = false, TextScaled = false, RichText = false, Interactable = true,
	AssemblyLinearVelocity = nil, AssemblyAngularVelocity = nil, Velocity = nil, RotVelocity = nil,
	Speed = 0, MaxSpeed = 25, Torque = 0, Throttle = 0, Steer = 0, ThrottleFloat = 0, SteerFloat = 0,
	MaxForce = math.huge, Responsiveness = 10, Attachment0 = nil, Attachment1 = nil,
	CurrentAngle = 0, CurrentPosition = 0, TargetAngle = 0, TargetPosition = 0, AngularSpeed = 0,
	AngularVelocity = 0, ServoMaxTorque = 0, MotorMaxTorque = 0, LowerAngle = -45, UpperAngle = 45,
	LimitsEnabled = false, Restitution = 0, Length = 5, Stiffness = 0, Damping = 0, FreeLength = 1,
}

-- properties whose real default is nil (reading them is not a gap in the fake)
local NIL_PROPS: { [string]: boolean } = {}
for _, n in {
	"Occupant", "SeatPart", "Adornee", "Attachment0", "Attachment1", "Part0", "Part1", "Target",
	"PrimaryPart", "Character", "Team", "LocalPlayer", "Value", "Tool", "RootPart", "Handle",
	"CameraSubject", "SoundGroup", "PlayerGui", "LightingStyle", "PrioritizeLightingQuality",
	"OnInvoke", "OnServerInvoke", "OnClientInvoke", "ProcessReceipt", "Lifetime", "Material", "Shape",
} do
	NIL_PROPS[n] = true
end

local function d(inst: any): any
	return data[inst]
end

local function fireChanged(inst: any, prop: string)
	local dd = d(inst)
	local sigs = dd.signals
	if sigs.Changed then
		sigs.Changed:Fire(prop)
	end
	local ps = dd.propSignals[prop]
	if ps then
		ps:Fire()
	end
end

local function classDefault(dd: any, k: string): any
	local cls = dd.ClassName
	if k == "Value" then
		if cls == "IntValue" or cls == "NumberValue" then
			return 0
		elseif cls == "StringValue" then
			return ""
		elseif cls == "BoolValue" then
			return false
		elseif cls == "Vector3Value" then
			return Vector3.zero
		elseif cls == "CFrameValue" then
			return CFrame.identity
		elseif cls == "Color3Value" then
			return c3(0, 0, 0)
		end
		return nil
	end
	if k == "Size" then
		if isA(cls, "BasePart") then
			return v3(4, 1, 2)
		elseif isA(cls, "GuiObject") then
			return udim2(0, 100, 0, 100)
		end
		return nil
	elseif k == "Position" then
		if isA(cls, "BasePart") then
			return dd.props.CFrame and dd.props.CFrame.p or Vector3.zero
		elseif isA(cls, "GuiObject") then
			return udim2(0, 0, 0, 0)
		elseif cls == "Attachment" then
			return Vector3.zero
		end
		return nil
	elseif k == "CFrame" or k == "WorldCFrame" or k == "PivotOffset" or k == "C0" or k == "C1" then
		if dd.props.Position and isA(cls, "BasePart") then
			local p = dd.props.Position
			return cf(p.X, p.Y, p.Z)
		end
		return CFrame.identity
	elseif k == "Orientation" or k == "Rotation" then
		return if isA(cls, "GuiObject") then 0 else Vector3.zero
	elseif k == "Color" or k == "BackgroundColor3" or k == "TextColor3" or k == "ImageColor3" or k == "Ambient" then
		return c3(0.64, 0.64, 0.64)
	elseif k == "BrickColor" then
		return brick("Medium stone grey")
	elseif k == "AssemblyLinearVelocity" or k == "AssemblyAngularVelocity" or k == "Velocity" or k == "MoveDirection" then
		return Vector3.zero
	elseif k == "AnchorPoint" then
		return Vector2.zero
	elseif k == "AbsoluteSize" or k == "AbsolutePosition" then
		return v2(100, 100)
	elseif (k == "WorldPosition" or k == "WorldCFrame") and cls == "Attachment" then
		local parent = dd.Parent
		local base = if parent and isA(d(parent).ClassName, "BasePart") then Inst.__index(parent, "CFrame") else CFrame.identity
		local local_ = dd.props.CFrame or (if dd.props.Position then CFrame.new(dd.props.Position) else CFrame.identity)
		local w = base * local_
		return if k == "WorldPosition" then w.p else w
	elseif k == "FloorMaterial" then
		return Enum.Material.Air
	end
	return DEFAULTS[k]
end

local newInstance

local function fullName(inst: any): string
	local parts = {}
	local cur = inst
	while cur and d(cur) and d(cur).ClassName ~= "DataModel" do
		table.insert(parts, 1, d(cur).Name)
		cur = d(cur).Parent
	end
	return table.concat(parts, ".")
end

local function descendants(inst: any, out: { any })
	for _, c in d(inst).children do
		table.insert(out, c)
		descendants(c, out)
	end
	return out
end

local function setParent(inst: any, parent: any)
	local dd = d(inst)
	if dd.destroyed and parent ~= nil then
		error("The Parent property of " .. dd.Name .. " is locked, current parent: NULL, new parent " .. tostring(parent))
	end
	local old = dd.Parent
	if old == parent then
		return
	end
	if parent == inst then
		error("Attempt to set " .. dd.Name .. " as its own parent")
	end
	if old then
		local od = d(old)
		local list = od.children
		for i, c in list do
			if c == inst then
				table.remove(list, i)
				break
			end
		end
		if od.signals.ChildRemoved then
			od.signals.ChildRemoved:Fire(inst)
		end
	end
	dd.Parent = parent
	if parent then
		local pd = d(parent)
		table.insert(pd.children, inst)
		if pd.signals.ChildAdded then
			pd.signals.ChildAdded:Fire(inst)
		end
		local a = parent
		while a do
			local ad = d(a)
			if ad.signals.DescendantAdded then
				ad.signals.DescendantAdded:Fire(inst)
			end
			a = ad.Parent
		end
		-- a Script placed in the server tree after boot starts running (like Roblox)
		if H._booted and dd.ClassName == "Script" and dd.source and not dd.ran then
			H._runScript(inst)
		end
	end
	if dd.signals.AncestryChanged then
		dd.signals.AncestryChanged:Fire(inst, parent)
	end
	fireChanged(inst, "Parent")
end

Inst.__index = function(inst, k)
	local dd = data[inst]
	if k == "Parent" then
		return dd.Parent
	elseif k == "Name" then
		return dd.Name
	elseif k == "ClassName" then
		return dd.ClassName
	elseif k == "Source" and isA(dd.ClassName, "LuaSourceContainer") then
		return dd.source or ""
	end
	-- class methods first: CollectionService:AddTag(inst, tag) is not Instance:AddTag(tag)
	local cm = ClassMethods[dd.ClassName]
	if cm and cm[k] ~= nil then
		return cm[k]
	end
	local m = Methods[k]
	if m then
		return m
	end
	local v = dd.props[k]
	if v ~= nil then
		return v
	end
	for _, c in dd.children do
		if d(c).Name == k then
			return c
		end
	end
	if EVENTS[k] then
		local s = dd.signals[k]
		if not s then
			s = newSignal(k)
			dd.signals[k] = s
		end
		return s
	end
	local def = classDefault(dd, k)
	if def ~= nil then
		return def
	end
	if type(k) == "string" and string.match(k, "^%u") and not dd.propsSet[k] and not NIL_PROPS[k] then
		miss(dd.ClassName .. "." .. k)
	end
	return nil
end

Inst.__newindex = function(inst, k, v)
	local dd = data[inst]
	if k == "Parent" then
		setParent(inst, v)
		return
	elseif k == "Name" then
		dd.Name = tostring(v)
		fireChanged(inst, "Name")
		return
	elseif k == "ClassName" then
		error("ClassName is read-only")
	elseif k == "Source" and isA(dd.ClassName, "LuaSourceContainer") then
		dd.source = tostring(v)
		fireChanged(inst, "Source")
		return
	end
	if k == "CFrame" and getmetatable(v) == CF and isA(dd.ClassName, "BasePart") then
		dd.props.Position = v.p
	elseif k == "Position" and getmetatable(v) == V3 and isA(dd.ClassName, "BasePart") then
		local c = dd.props.CFrame
		dd.props.CFrame = if c then fromRot(v, c.r) else cf(v.X, v.Y, v.Z)
	elseif k == "Health" and dd.ClassName == "Humanoid" then
		local maxH = dd.props.MaxHealth or 100
		v = math.clamp(v, 0, maxH)
		local was = dd.props.Health or 100
		dd.props.Health = v
		dd.propsSet[k] = true
		fireChanged(inst, k)
		if dd.signals.HealthChanged then
			dd.signals.HealthChanged:Fire(v)
		end
		if v <= 0 and was > 0 then
			local died = dd.signals.Died or newSignal("Died")
			dd.signals.Died = died
			died:Fire()
		end
		return
	end
	if k == "OnInvoke" or k == "OnServerInvoke" or k == "OnClientInvoke" or k == "ProcessReceipt" then
		dd.props[k] = v
		return
	end
	local old = dd.props[k]
	dd.props[k] = v
	dd.propsSet[k] = true
	if old ~= v then
		fireChanged(inst, k)
	end
end

Inst.__tostring = function(inst)
	return data[inst].Name
end

newInstance = function(className: string, parent: any?): any
	local inst = setmetatable({}, Inst)
	data[inst] = {
		ClassName = className, Name = className, Parent = nil, children = {}, props = {}, propsSet = {},
		attrs = {}, attrSignals = {}, propSignals = {}, signals = {}, tags = {},
	}
	if parent then
		setParent(inst, parent)
	end
	return inst
end

-- Instance methods ------------------------------------------------------------------
function Methods.FindFirstChild(self, name, recursive)
	for _, c in d(self).children do
		if d(c).Name == name then
			return c
		end
	end
	if recursive then
		for _, c in d(self).children do
			local f = Methods.FindFirstChild(c, name, true)
			if f then
				return f
			end
		end
	end
	return nil
end
function Methods.FindFirstChildOfClass(self, cls)
	for _, c in d(self).children do
		if d(c).ClassName == cls then
			return c
		end
	end
	return nil
end
function Methods.FindFirstChildWhichIsA(self, cls, recursive)
	for _, c in (if recursive then descendants(self, {}) else d(self).children) do
		if isA(d(c).ClassName, cls) then
			return c
		end
	end
	return nil
end
function Methods.FindFirstAncestor(self, name)
	local a = d(self).Parent
	while a do
		if d(a).Name == name then
			return a
		end
		a = d(a).Parent
	end
	return nil
end
function Methods.FindFirstAncestorOfClass(self, cls)
	local a = d(self).Parent
	while a do
		if d(a).ClassName == cls then
			return a
		end
		a = d(a).Parent
	end
	return nil
end
function Methods.FindFirstAncestorWhichIsA(self, cls)
	local a = d(self).Parent
	while a do
		if isA(d(a).ClassName, cls) then
			return a
		end
		a = d(a).Parent
	end
	return nil
end
function Methods.FindFirstDescendant(self, name)
	for _, c in descendants(self, {}) do
		if d(c).Name == name then
			return c
		end
	end
	return nil
end
function Methods.WaitForChild(self, name, timeout)
	local found = Methods.FindFirstChild(self, name)
	if found then
		return found
	end
	if not coroutine.isyieldable() then
		error("WaitForChild(" .. tostring(name) .. ") would yield in a non-yieldable thread")
	end
	local start = now
	local warned = false
	while true do
		yieldFor(FRAME)
		found = Methods.FindFirstChild(self, name)
		if found then
			return found
		end
		if timeout and now - start >= timeout then
			return nil
		end
		if not warned and now - start >= 5 then
			warned = true
			addWarning("Infinite yield possible on '" .. fullName(self) .. ":WaitForChild(\"" .. tostring(name) .. "\")'")
		end
	end
end
function Methods.GetChildren(self)
	return table.clone(d(self).children)
end
function Methods.GetDescendants(self)
	return descendants(self, {})
end
function Methods.IsA(self, cls)
	return isA(d(self).ClassName, cls)
end
function Methods.IsDescendantOf(self, other)
	local a = d(self).Parent
	while a do
		if a == other then
			return true
		end
		a = d(a).Parent
	end
	return false
end
function Methods.IsAncestorOf(self, other)
	return Methods.IsDescendantOf(other, self)
end
function Methods.Destroy(self)
	local dd = d(self)
	if dd.destroyed then
		return
	end
	if dd.signals.Destroying then
		dd.signals.Destroying:Fire()
	end
	for _, c in table.clone(dd.children) do
		Methods.Destroy(c)
	end
	setParent(self, nil)
	dd.destroyed = true
	for tag in dd.tags do
		if tagged[tag] then
			tagged[tag][self] = nil
		end
	end
	for _, s in dd.signals do
		s.conns = {}
	end
end
Methods.Remove = Methods.Destroy
function Methods.ClearAllChildren(self)
	for _, c in table.clone(d(self).children) do
		Methods.Destroy(c)
	end
end
function Methods.Clone(self)
	local dd = d(self)
	if dd.props.Archivable == false then
		return nil
	end
	local c = newInstance(dd.ClassName)
	local cd = d(c)
	cd.Name = dd.Name
	for k, v in dd.props do
		cd.props[k] = v
	end
	for k, v in dd.propsSet do
		cd.propsSet[k] = v
	end
	for k, v in dd.attrs do
		cd.attrs[k] = v
	end
	cd.source = dd.source
	cd.path = dd.path
	for tag in dd.tags do
		Methods.AddTag(c, tag)
	end
	for _, ch in dd.children do
		local cc = Methods.Clone(ch)
		if cc then
			setParent(cc, c)
		end
	end
	return c
end
function Methods.GetFullName(self)
	return fullName(self)
end
function Methods.SetAttribute(self, k, v)
	local dd = d(self)
	if dd.attrs[k] == v then
		return
	end
	dd.attrs[k] = v
	local s = dd.attrSignals[k]
	if s then
		s:Fire()
	end
	if dd.signals.AttributeChanged then
		dd.signals.AttributeChanged:Fire(k)
	end
end
function Methods.GetAttribute(self, k)
	return d(self).attrs[k]
end
function Methods.GetAttributes(self)
	return table.clone(d(self).attrs)
end
function Methods.GetAttributeChangedSignal(self, k)
	local dd = d(self)
	local s = dd.attrSignals[k]
	if not s then
		s = newSignal("AttributeChanged:" .. k)
		dd.attrSignals[k] = s
	end
	return s
end
function Methods.GetPropertyChangedSignal(self, k)
	local dd = d(self)
	local s = dd.propSignals[k]
	if not s then
		s = newSignal("Changed:" .. k)
		dd.propSignals[k] = s
	end
	return s
end
function Methods.AddTag(self, tag)
	local dd = d(self)
	if dd.tags[tag] then
		return
	end
	dd.tags[tag] = true
	tagged[tag] = tagged[tag] or {}
	tagged[tag][self] = true
	if tagAdded[tag] then
		tagAdded[tag]:Fire(self)
	end
end
function Methods.RemoveTag(self, tag)
	local dd = d(self)
	if not dd.tags[tag] then
		return
	end
	dd.tags[tag] = nil
	if tagged[tag] then
		tagged[tag][self] = nil
	end
	if tagRemoved[tag] then
		tagRemoved[tag]:Fire(self)
	end
end
function Methods.HasTag(self, tag)
	return d(self).tags[tag] == true
end
function Methods.GetTags(self)
	local out = {}
	for t in d(self).tags do
		table.insert(out, t)
	end
	return out
end
function Methods.GetPivot(self)
	local dd = d(self)
	if isA(dd.ClassName, "BasePart") then
		return Inst.__index(self, "CFrame")
	end
	local pp = dd.props.PrimaryPart
	if pp then
		return Inst.__index(pp, "CFrame")
	end
	for _, c in descendants(self, {}) do
		if isA(d(c).ClassName, "BasePart") then
			return Inst.__index(c, "CFrame")
		end
	end
	return dd.props.WorldPivot or CFrame.identity
end
function Methods.PivotTo(self, target)
	local dd = d(self)
	if isA(dd.ClassName, "BasePart") then
		Inst.__newindex(self, "CFrame", target)
		return
	end
	local from = Methods.GetPivot(self)
	local delta = target * from:Inverse()
	for _, c in descendants(self, {}) do
		if isA(d(c).ClassName, "BasePart") then
			Inst.__newindex(c, "CFrame", delta * Inst.__index(c, "CFrame"))
		end
	end
	dd.props.WorldPivot = target
end
function Methods.SetPrimaryPartCFrame(self, target)
	Methods.PivotTo(self, target)
end
function Methods.GetPrimaryPartCFrame(self)
	return Methods.GetPivot(self)
end
function Methods.MoveTo(self, pos)
	if d(self).ClassName == "Humanoid" then
		local char = d(self).Parent
		task.delay(0.5, function()
			local root = char and Methods.FindFirstChild(char, "HumanoidRootPart")
			if root then
				Inst.__newindex(root, "CFrame", cf(pos.X, pos.Y, pos.Z))
			end
			local s = d(self).signals.MoveToFinished
			if s then
				s:Fire(true)
			end
		end)
		return
	end
	local p = Methods.GetPivot(self)
	Methods.PivotTo(self, fromRot(pos, p.r))
end
function Methods.TranslateBy(self, delta)
	local p = Methods.GetPivot(self)
	Methods.PivotTo(self, p + delta)
end
function Methods.GetBoundingBox(self)
	return Methods.GetPivot(self), v3(4, 4, 4)
end
function Methods.GetExtentsSize()
	return v3(4, 4, 4)
end
function Methods.ScaleTo() end
function Methods.GetScale()
	return 1
end
function Methods.BreakJoints() end
function Methods.MakeJoints() end
function Methods.GetActor()
	return nil
end
function Methods.GetNetworkOwner()
	return nil
end
function Methods.SetNetworkOwner() end
function Methods.SetNetworkOwnershipAuto() end
function Methods.CanSetNetworkOwnership()
	return true
end
function Methods.GetMass()
	return 1
end
function Methods.GetTouchingParts()
	return {}
end
function Methods.GetConnectedParts()
	return {}
end
function Methods.GetJoints()
	return {}
end
function Methods.ApplyImpulse(self, v)
	local cur = Inst.__index(self, "AssemblyLinearVelocity") or Vector3.zero
	d(self).props.AssemblyLinearVelocity = cur + v
end
function Methods.ApplyAngularImpulse() end
function Methods.ApplyImpulseAtPosition() end
function Methods.GetVelocityAtPosition()
	return Vector3.zero
end
function Methods.GetRootPart(self)
	return self
end
function Methods.SubtractAsync(self)
	return Methods.Clone(self)
end
Methods.UnionAsync = Methods.SubtractAsync
Methods.IntersectAsync = Methods.SubtractAsync
-- sounds / effects / tweens / animations
function Methods.Play(self)
	local dd = d(self)
	dd.props.IsPlaying = true
	dd.props.Playing = true
	if dd.signals.Played then
		dd.signals.Played:Fire()
	end
	if dd.ClassName == "Tween" then
		local info = dd.props.TweenInfo
		local goal = dd.props.Goal or {}
		local inst = dd.props.Instance
		task.delay(info and info.Time or 1, function()
			if inst and d(inst) and not d(inst).destroyed then
				for k, v in goal do
					inst[k] = v
				end
			end
			dd.props.PlaybackState = Enum.PlaybackState.Completed
			if dd.signals.Completed then
				dd.signals.Completed:Fire(Enum.PlaybackState.Completed)
			end
		end)
	end
end
function Methods.Stop(self)
	local dd = d(self)
	dd.props.IsPlaying = false
	dd.props.Playing = false
	if dd.signals.Stopped then
		dd.signals.Stopped:Fire()
	end
end
Methods.Pause = Methods.Stop
Methods.Resume = Methods.Play
Methods.Cancel = Methods.Stop
function Methods.Emit() end
function Methods.Clear() end
function Methods.AdjustSpeed() end
function Methods.AdjustWeight() end
function Methods.GetMarkerReachedSignal()
	return newSignal("MarkerReached")
end
function Methods.LoadAnimation(self, anim)
	local t = newInstance("AnimationTrack")
	d(t).props.Animation = anim
	d(t).props.Length = 1
	return t
end
function Methods.GetPlayingAnimationTracks()
	return {}
end
-- bindables / remotes
function Methods.Fire(self, ...)
	local s = d(self).signals.Event or newSignal("Event")
	d(self).signals.Event = s
	s:Fire(...)
end
function Methods.Invoke(self, ...)
	local f = d(self).props.OnInvoke
	if not f then
		error("BindableFunction " .. d(self).Name .. " has no OnInvoke callback")
	end
	return f(...)
end
H.remoteLog = {} :: { any }
local function logRemote(self, kind, ...)
	if #H.remoteLog < 200 then
		table.insert(H.remoteLog, { remote = d(self).Name, kind = kind, n = select("#", ...) })
	end
end
function Methods.FireClient(self, player, ...)
	logRemote(self, "FireClient", ...)
end
function Methods.FireAllClients(self, ...)
	logRemote(self, "FireAllClients", ...)
end
function Methods.FireServer(self, ...)
	logRemote(self, "FireServer", ...)
end
function Methods.InvokeClient(self, ...)
	logRemote(self, "InvokeClient", ...)
	return nil
end
function Methods.InvokeServer(self, ...)
	logRemote(self, "InvokeServer", ...)
	return nil
end
-- humanoid
function Methods.TakeDamage(self, n)
	if d(self).props.ForceField then
		return
	end
	Inst.__newindex(self, "Health", (Inst.__index(self, "Health") or 100) - n)
end
function Methods.GetState()
	return Enum.HumanoidStateType.Running
end
function Methods.ChangeState() end
function Methods.SetStateEnabled() end
function Methods.GetStateEnabled()
	return true
end
function Methods.EquipTool(self, tool)
	local char = d(self).Parent
	if char then
		setParent(tool, char)
		local s = d(tool).signals.Equipped
		if s then
			s:Fire()
		end
	end
end
function Methods.UnequipTools(self)
	local char = d(self).Parent
	if not char then
		return
	end
	local plr = H.Players and Methods.GetPlayerFromCharacter(H.Players, char)
	for _, c in table.clone(d(char).children) do
		if d(c).ClassName == "Tool" then
			setParent(c, plr and Methods.FindFirstChild(plr, "Backpack") or nil)
		end
	end
end
function Methods.ApplyDescription() end
function Methods.GetAppliedDescription()
	return newInstance("HumanoidDescription")
end
function Methods.AddAccessory() end
function Methods.GetAccessories()
	return {}
end
function Methods.BuildRigFromAttachments() end
-- player
function Methods.Kick(self, msg)
	addWarning("Player " .. d(self).Name .. " kicked: " .. tostring(msg))
	if H.Players then
		H.Players:_leave(self)
	end
end
function Methods.GetMouse()
	return newInstance("Mouse")
end
function Methods.GetRankInGroup()
	return 0
end
function Methods.GetRoleInGroup()
	return "Guest"
end
function Methods.IsInGroup()
	return false
end
function Methods.GetFriendsOnline()
	return {}
end
function Methods.IsFriendsWith()
	return false
end
function Methods.HasAppearanceLoaded()
	return true
end
function Methods.GetNetworkPing()
	return 0.05
end
function Methods.RequestStreamAroundAsync() end
function Methods.SetSuperSafeChat() end
function Methods.LoadCharacter(self)
	H.spawnCharacter(self)
end
Methods.LoadCharacterAsync = Methods.LoadCharacter
-- gui
function Methods.TweenPosition()
	return true
end
function Methods.TweenSize()
	return true
end
function Methods.TweenSizeAndPosition()
	return true
end
function Methods.CaptureFocus() end
function Methods.ReleaseFocus() end
function Methods.IsFocused()
	return false
end
-- datastore-ish / misc service methods are per class (below)

-- ============================================================================ services

local game = newInstance("DataModel")
d(game).Name = "Game"
local services: { [string]: any } = {}

local function service(name: string): any
	local s = services[name]
	if s then
		return s
	end
	s = newInstance(name)
	d(s).Name = name
	setParent(s, game)
	services[name] = s
	return s
end

ClassMethods.DataModel = {
	GetService = function(self, name)
		return service(name)
	end,
	FindService = function(self, name)
		return services[name]
	end,
	IsLoaded = function()
		return true
	end,
	BindToClose = function(self, fn)
		H._closeHandlers = H._closeHandlers or {}
		table.insert(H._closeHandlers, fn)
	end,
	GetJobsInfo = function()
		return {}
	end,
	PlaceId = 0,
	GameId = 0,
	JobId = "headless",
	PlaceVersion = 0,
	CreatorId = 0,
	PrivateServerId = "",
	PrivateServerOwnerId = 0,
	Loaded = newSignal("Loaded"),
}
d(game).props.Workspace = nil

local workspace = service("Workspace")
local Players = service("Players")
local RunService = service("RunService")
local ServerStorage = service("ServerStorage")
local ServerScriptService = service("ServerScriptService")
local ReplicatedStorage = service("ReplicatedStorage")
local StarterGui = service("StarterGui")
local StarterPack = service("StarterPack")
local StarterPlayer = service("StarterPlayer")
local Lighting = service("Lighting")
local Teams = service("Teams")
local SoundService = service("SoundService")
d(StarterPlayer).props.StarterPlayerScripts = newInstance("StarterPlayerScripts", StarterPlayer)
d(StarterPlayer).props.StarterCharacterScripts = newInstance("StarterCharacterScripts", StarterPlayer)
H.Players = Players

-- Workspace
d(workspace).props.Gravity = 196.2
d(workspace).props.CurrentCamera = newInstance("Camera", workspace)
d(workspace).props.Terrain = newInstance("Terrain", workspace)
d(d(workspace).props.CurrentCamera).Name = "Camera"
d(d(workspace).props.Terrain).Name = "Terrain"
ClassMethods.Workspace = {
	Raycast = function()
		return nil
	end,
	Blockcast = function()
		return nil
	end,
	Spherecast = function()
		return nil
	end,
	Shapecast = function()
		return nil
	end,
	GetPartBoundsInBox = function()
		return {}
	end,
	GetPartBoundsInRadius = function()
		return {}
	end,
	GetPartsInPart = function()
		return {}
	end,
	FindPartsInRegion3 = function()
		return {}
	end,
	FindPartsInRegion3WithIgnoreList = function()
		return {}
	end,
	FindPartOnRay = function()
		return nil
	end,
	FindPartOnRayWithIgnoreList = function()
		return nil
	end,
	GetServerTimeNow = function()
		return os.time() + now
	end,
	GetRealPhysicsFPS = function()
		return 60
	end,
	ArePartsTouchingOthers = function()
		return false
	end,
	BulkMoveTo = function(self, parts, cfs)
		for i, p in parts do
			Inst.__newindex(p, "CFrame", cfs[i])
		end
	end,
}
ClassMethods.Terrain = {
	FillBlock = function() end,
	FillBall = function() end,
	FillRegion = function() end,
	FillCylinder = function() end,
	FillWedge = function() end,
	Clear = function() end,
	WriteVoxels = function() end,
	ReadVoxels = function()
		return {}, {}
	end,
	SetMaterialColor = function() end,
}

-- Players
local nextUserId = 1
ClassMethods.Players = {
	GetPlayers = function(self)
		local out = {}
		for _, c in d(self).children do
			if d(c).ClassName == "Player" then
				table.insert(out, c)
			end
		end
		return out
	end,
	GetPlayerFromCharacter = function(self, char)
		for _, p in d(self).children do
			if d(p).ClassName == "Player" and d(p).props.Character == char and char ~= nil then
				return p
			end
		end
		return nil
	end,
	GetPlayerByUserId = function(self, id)
		for _, p in d(self).children do
			if d(p).ClassName == "Player" and d(p).props.UserId == id then
				return p
			end
		end
		return nil
	end,
	GetUserIdFromNameAsync = function()
		return 1
	end,
	GetNameFromUserIdAsync = function()
		return "Player"
	end,
	GetUserThumbnailAsync = function()
		return "rbxassetid://0", true
	end,
	GetHumanoidDescriptionFromUserId = function()
		return newInstance("HumanoidDescription")
	end,
	CreateHumanoidModelFromDescription = function()
		return H.makeCharacter("Rig")
	end,
	_leave = function(self, plr)
		local s = d(self).signals.PlayerRemoving
		if s then
			s:Fire(plr)
		end
		setParent(plr, nil)
	end,
}
d(Players).props.MaxPlayers = 8
d(Players).props.CharacterAutoLoads = true
d(Players).props.RespawnTime = 5

function H.makeCharacter(name: string): any
	local char = newInstance("Model")
	d(char).Name = name
	local root = newInstance("Part", char)
	d(root).Name = "HumanoidRootPart"
	Inst.__newindex(root, "CFrame", cf(0, 5, 0))
	local head = newInstance("Part", char)
	d(head).Name = "Head"
	Inst.__newindex(head, "CFrame", cf(0, 6.5, 0))
	local torso = newInstance("Part", char)
	d(torso).Name = "UpperTorso"
	local hum = newInstance("Humanoid", char)
	newInstance("Animator", hum)
	d(char).props.PrimaryPart = root
	return char
end

function H.spawnCharacter(plr: any)
	local pd = d(plr)
	local old = pd.props.Character
	if old then
		if pd.signals.CharacterRemoving then
			pd.signals.CharacterRemoving:Fire(old)
		end
		Methods.Destroy(old)
	end
	local char = H.makeCharacter(pd.Name)
	-- spawn at a SpawnLocation if the game built one
	for _, c in descendants(workspace, {}) do
		if d(c).ClassName == "SpawnLocation" then
			local p = Inst.__index(c, "Position")
			Inst.__newindex(Methods.FindFirstChild(char, "HumanoidRootPart"), "CFrame", cf(p.X, p.Y + 4, p.Z))
			break
		end
	end
	pd.props.Character = char
	setParent(char, workspace)
	if pd.signals.CharacterAdded then
		pd.signals.CharacterAdded:Fire(char)
	end
	if pd.signals.CharacterAppearanceLoaded then
		pd.signals.CharacterAppearanceLoaded:Fire(char)
	end
	local hum = Methods.FindFirstChildOfClass(char, "Humanoid")
	Methods.GetPropertyChangedSignal(hum, "Health")
	local died = Inst.__index(hum, "Died")
	died:Connect(function()
		task.delay(Inst.__index(Players, "RespawnTime") or 5, function()
			if pd.Parent == Players and pd.props.Character == char then
				H.spawnCharacter(plr)
			end
		end)
	end)
	return char
end

function H.join(name: string?): any
	local plr = newInstance("Player")
	local pd = d(plr)
	pd.Name = name or ("Player" .. nextUserId)
	pd.props.UserId = nextUserId
	pd.props.DisplayName = pd.Name
	pd.props.AccountAge = 100
	pd.props.MembershipType = Enum.MembershipType.None
	pd.propsSet.Character = true
	pd.propsSet.Team = true
	nextUserId += 1
	newInstance("Backpack", plr).Name = "Backpack"
	local gui = newInstance("PlayerGui", plr)
	d(gui).Name = "PlayerGui"
	for _, g in d(StarterGui).children do
		local c = Methods.Clone(g)
		if c then
			setParent(c, gui)
		end
	end
	local ps = newInstance("PlayerScripts", plr)
	d(ps).Name = "PlayerScripts"
	setParent(plr, Players)
	local s = d(Players).signals.PlayerAdded
	if s then
		s:Fire(plr)
	end
	if Inst.__index(Players, "CharacterAutoLoads") ~= false then
		H.spawnCharacter(plr)
	end
	return plr
end

-- RunService
ClassMethods.RunService = {
	IsStudio = function()
		return true
	end,
	IsServer = function()
		return true
	end,
	IsClient = function()
		return false
	end,
	IsRunning = function()
		return true
	end,
	IsRunMode = function()
		return false
	end,
	IsEdit = function()
		return false
	end,
	BindToRenderStep = function() end,
	UnbindFromRenderStep = function() end,
}

-- TweenService
ClassMethods.TweenService = {
	Create = function(self, inst, info, goal)
		local t = newInstance("Tween")
		d(t).props.Instance = inst
		d(t).props.TweenInfo = info
		d(t).props.Goal = goal
		d(t).props.PlaybackState = Enum.PlaybackState.Begin
		return t
	end,
	GetValue = function(self, alpha)
		return alpha
	end,
	SmoothDamp = function(self, cur, target)
		return target, 0
	end,
}

-- HttpService
local guid = 0
ClassMethods.HttpService = {
	JSONEncode = function(self, v)
		return jsonEncode(v)
	end,
	JSONDecode = function(self, s)
		return jsonDecode(s)
	end,
	GenerateGUID = function(self, braces)
		guid += 1
		local g = string.format("00000000-0000-4000-8000-%012d", guid)
		return if braces == false then g else "{" .. g .. "}"
	end,
	UrlEncode = function(self, s)
		return (string.gsub(s, "[^%w%-_%.~]", function(c)
			return string.format("%%%02X", string.byte(c))
		end))
	end,
	GetAsync = function()
		error("HttpService requests are not available headless")
	end,
	PostAsync = function()
		error("HttpService requests are not available headless")
	end,
	RequestAsync = function()
		error("HttpService requests are not available headless")
	end,
	GetSecret = function()
		error("secrets are not available headless")
	end,
}

-- DataStoreService (in memory)
local stores: { [string]: any } = {}
local function memStore(name: string)
	if stores[name] then
		return stores[name]
	end
	local values: { [string]: any } = {}
	local st = {}
	function st:GetAsync(k)
		return values[tostring(k)]
	end
	function st:SetAsync(k, v)
		values[tostring(k)] = v
	end
	function st:UpdateAsync(k, fn)
		local nv = fn(values[tostring(k)])
		if nv ~= nil then
			values[tostring(k)] = nv
		end
		return nv
	end
	function st:IncrementAsync(k, n)
		values[tostring(k)] = (values[tostring(k)] or 0) + (n or 1)
		return values[tostring(k)]
	end
	function st:RemoveAsync(k)
		local v = values[tostring(k)]
		values[tostring(k)] = nil
		return v
	end
	function st:GetSortedAsync(asc, size)
		local list = {}
		for k, v in values do
			table.insert(list, { key = k, value = v })
		end
		table.sort(list, function(a, b)
			if asc then
				return (a.value or 0) < (b.value or 0)
			end
			return (a.value or 0) > (b.value or 0)
		end)
		local page = {}
		for i = 1, math.min(size or 50, #list) do
			page[i] = list[i]
		end
		return {
			GetCurrentPage = function()
				return page
			end,
			AdvanceToNextPageAsync = function() end,
			IsFinished = true,
		}
	end
	stores[name] = st
	return st
end
ClassMethods.DataStoreService = {
	GetDataStore = function(self, name, scope)
		return memStore("ds:" .. tostring(name) .. ":" .. tostring(scope or ""))
	end,
	GetOrderedDataStore = function(self, name, scope)
		return memStore("ods:" .. tostring(name) .. ":" .. tostring(scope or ""))
	end,
	GetGlobalDataStore = function()
		return memStore("global")
	end,
	GetRequestBudgetForRequestType = function()
		return 100
	end,
}
ClassMethods.MemoryStoreService = {
	GetSortedMap = function(self, name)
		return memStore("ms:" .. name)
	end,
	GetQueue = function(self, name)
		return memStore("mq:" .. name)
	end,
	GetHashMap = function(self, name)
		return memStore("mh:" .. name)
	end,
}

-- CollectionService
local function tagSignal(map, tag)
	local s = map[tag]
	if not s then
		s = newSignal("Tag:" .. tag)
		map[tag] = s
	end
	return s
end
ClassMethods.CollectionService = {
	AddTag = function(self, inst, tag)
		Methods.AddTag(inst, tag)
	end,
	RemoveTag = function(self, inst, tag)
		Methods.RemoveTag(inst, tag)
	end,
	HasTag = function(self, inst, tag)
		return Methods.HasTag(inst, tag)
	end,
	GetTags = function(self, inst)
		return Methods.GetTags(inst)
	end,
	GetTagged = function(self, tag)
		local out = {}
		for inst in (tagged[tag] or {}) do
			if not d(inst).destroyed then
				table.insert(out, inst)
			end
		end
		return out
	end,
	GetInstanceAddedSignal = function(self, tag)
		return tagSignal(tagAdded, tag)
	end,
	GetInstanceRemovedSignal = function(self, tag)
		return tagSignal(tagRemoved, tag)
	end,
	GetAllTags = function()
		local out = {}
		for t in tagged do
			table.insert(out, t)
		end
		return out
	end,
}

-- Debris
ClassMethods.Debris = {
	AddItem = function(self, inst, life)
		task.delay(life or 10, function()
			if d(inst) and not d(inst).destroyed then
				Methods.Destroy(inst)
			end
		end)
	end,
}

-- MarketplaceService
ClassMethods.MarketplaceService = {
	PromptProductPurchase = function() end,
	PromptGamePassPurchase = function() end,
	PromptPurchase = function() end,
	PromptPremiumPurchase = function() end,
	UserOwnsGamePassAsync = function()
		return false
	end,
	PlayerOwnsAsset = function()
		return false
	end,
	GetProductInfo = function()
		return { Name = "Product", PriceInRobux = 0 }
	end,
	GetDeveloperProductsAsync = function()
		return {
			GetCurrentPage = function()
				return {}
			end,
			IsFinished = true,
		}
	end,
}

-- misc services
ClassMethods.PhysicsService = {
	RegisterCollisionGroup = function() end,
	CreateCollisionGroup = function() end,
	CollisionGroupSetCollidable = function() end,
	CollisionGroupsAreCollidable = function()
		return true
	end,
	SetPartCollisionGroup = function(self, part, g)
		d(part).props.CollisionGroup = g
	end,
	IsCollisionGroupRegistered = function()
		return true
	end,
	GetRegisteredCollisionGroups = function()
		return {}
	end,
	UnregisterCollisionGroup = function() end,
}
ClassMethods.TextService = {
	GetTextSize = function(self, text, size)
		return v2(#tostring(text) * (size or 14) * 0.5, size or 14)
	end,
	FilterStringAsync = function(self, text)
		return {
			GetNonChatStringForBroadcastAsync = function()
				return text
			end,
			GetChatForUserAsync = function()
				return text
			end,
			GetNonChatStringForUserAsync = function()
				return text
			end,
		}
	end,
	GetTextBoundsAsync = function()
		return v2(100, 14)
	end,
}
ClassMethods.PathfindingService = {
	CreatePath = function()
		local p = newInstance("Path")
		d(p).props.Status = Enum.PathStatus.Success
		ClassMethods.Path = ClassMethods.Path
			or {
				ComputeAsync = function(self, a, b)
					d(self).props._a, d(self).props._b = a, b
				end,
				GetWaypoints = function(self)
					local b = d(self).props._b
					if not b then
						return {}
					end
					return { setmetatable({ Position = b, Action = Enum.PathWaypointAction.Walk, Label = "" }, { __type = "PathWaypoint" }) }
				end,
				CheckOcclusionAsync = function()
					return -1
				end,
			}
		return p
	end,
	FindPathAsync = function(self, a, b)
		local p = ClassMethods.PathfindingService.CreatePath()
		p:ComputeAsync(a, b)
		return p
	end,
}
ClassMethods.MessagingService = {
	PublishAsync = function() end,
	SubscribeAsync = function()
		return { Disconnect = function() end }
	end,
}
ClassMethods.BadgeService = {
	AwardBadge = function()
		return true
	end,
	UserHasBadgeAsync = function()
		return false
	end,
	GetBadgeInfoAsync = function()
		return { IsEnabled = true, Name = "Badge" }
	end,
}
ClassMethods.Teams = {
	GetTeams = function(self)
		return Methods.GetChildren(self)
	end,
}
ClassMethods.Team = {
	GetPlayers = function(self)
		local out = {}
		for _, p in ClassMethods.Players.GetPlayers(Players) do
			if d(p).props.Team == self then
				table.insert(out, p)
			end
		end
		return out
	end,
}
ClassMethods.SoundService = {
	PlayLocalSound = function() end,
	SetListener = function() end,
}
ClassMethods.ContentProvider = {
	PreloadAsync = function() end,
}
ClassMethods.InsertService = {
	LoadAsset = function()
		error("InsertService:LoadAsset is not available headless")
	end,
}
ClassMethods.AssetService = {
	CreateEditableMesh = function()
		error("AssetService is not available headless")
	end,
}
ClassMethods.Chat = {
	Chat = function() end,
	FilterStringForBroadcast = function(self, s)
		return s
	end,
}
ClassMethods.TextChatService = {}
ClassMethods.LocalizationService = {
	GetTranslatorForPlayerAsync = function()
		return {
			Translate = function(_, _, s)
				return s
			end,
		}
	end,
}
ClassMethods.GroupService = {
	GetGroupInfoAsync = function()
		return {}
	end,
	GetGroupsAsync = function()
		return {}
	end,
}
ClassMethods.SocialService = {
	CanSendGameInviteAsync = function()
		return false
	end,
	PromptGameInvite = function() end,
}
ClassMethods.PolicyService = {
	GetPolicyInfoForPlayerAsync = function()
		return { AreAdsAllowed = false, ArePaidRandomItemsRestricted = false }
	end,
}
ClassMethods.UserInputService = {
	IsKeyDown = function()
		return false
	end,
	GetMouseLocation = function()
		return v2(0, 0)
	end,
	GetLastInputType = function()
		return Enum.UserInputType.Keyboard
	end,
}
ClassMethods.ContextActionService = {
	BindAction = function() end,
	UnbindAction = function() end,
	BindActionAtPriority = function() end,
	SetTitle = function() end,
	SetImage = function() end,
	SetPosition = function() end,
	GetButton = function()
		return nil
	end,
}
ClassMethods.StarterGui = {
	SetCoreGuiEnabled = function() end,
	SetCore = function() end,
	GetCore = function()
		return nil
	end,
	GetCoreGuiEnabled = function()
		return true
	end,
}
ClassMethods.LogService = {
	GetLogHistory = function()
		return {}
	end,
	ClearOutput = function() end,
}
ClassMethods.ScriptContext = {}
ClassMethods.Animator = {
	LoadAnimation = Methods.LoadAnimation,
}
ClassMethods.AnimationController = ClassMethods.Animator

-- ============================================================================ Instance global

local NO_CREATE = { DataModel = true, Player = true, Workspace = true }
local Instance: any = {
	new = function(className: string, parent: any?)
		if type(className) ~= "string" then
			error("Instance.new expects a class name string")
		end
		if NO_CREATE[className] then
			error("Unable to create an Instance of type \"" .. className .. "\"")
		end
		local inst = newInstance(className)
		if className == "Sound" or className == "Animation" or className == "ParticleEmitter" then
			-- no extra setup
		elseif className == "Model" then
			d(inst).propsSet.PrimaryPart = true
		elseif className == "ObjectValue" then
			d(inst).propsSet.Value = true
		end
		if parent then
			setParent(inst, parent)
		end
		return inst
	end,
	fromExisting = function(inst)
		return Methods.Clone(inst)
	end,
}

-- ============================================================================ typeof / env

local function typeofShim(v: any): string
	local mt = getmetatable(v)
	if type(mt) == "table" and rawget(mt, "__type") then
		return rawget(mt, "__type")
	end
	return typeof(v)
end

local function log(kind: string, ...)
	prints += 1
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	local line = table.concat(parts, " ")
	if kind == "warn" then
		addWarning(line)
	end
	if H.echo then
		realPrint("[" .. kind .. "] " .. line)
	end
end

local fakeOs = setmetatable({
	clock = function()
		return now
	end,
	time = function(t)
		if t then
			return os.time(t)
		end
		return os.time() + math.floor(now)
	end,
}, { __index = os })

local G: { [string]: any } = {
	game = game, Game = game, workspace = workspace, Workspace = workspace,
	Instance = Instance, Vector3 = Vector3, Vector2 = Vector2, CFrame = CFrame, Color3 = Color3,
	UDim = UDim, UDim2 = UDim2, Enum = Enum, NumberRange = NumberRange, NumberSequence = NumberSequence,
	NumberSequenceKeypoint = NumberSequenceKeypoint, ColorSequence = ColorSequence,
	ColorSequenceKeypoint = ColorSequenceKeypoint, TweenInfo = TweenInfo, Rect = Rect, Ray = Ray,
	PhysicalProperties = PhysicalProperties, Region3 = Region3, RaycastParams = RaycastParams,
	OverlapParams = OverlapParams, BrickColor = BrickColor, DateTime = DateTime, Random = Random,
	Font = Font, task = task, os = fakeOs, typeof = typeofShim,
	Axes = { new = function() return {} end }, Faces = { new = function() return {} end },
	Vector3int16 = { new = Vector3.new }, Vector2int16 = { new = Vector2.new },
	print = function(...)
		log("print", ...)
	end,
	warn = function(...)
		log("warn", ...)
	end,
	tick = function()
		return os.time() + now
	end,
	time = function()
		return now
	end,
	elapsedTime = function()
		return now
	end,
	wait = function(s)
		return yieldFor(s), now
	end,
	spawn = function(fn)
		task.defer(fn)
	end,
	delay = function(t, fn)
		task.delay(t, fn)
	end,
	shared = {},
	plugin = nil,
	settings = function()
		return setmetatable({}, { __index = function()
			return {}
		end })
	end,
	UserSettings = function()
		return setmetatable({}, { __index = function()
			return function()
				return {}
			end
		end })
	end,
	version = function()
		return "0.0.0.headless"
	end,
	stats = function()
		return service("Stats")
	end,
}

-- ============================================================================ require / scripts

local cache: { [any]: any } = {}
local loading: { [any]: boolean } = {}

local function envFor(inst: any)
	return setmetatable({ script = inst }, { __index = function(_, k)
		local v = G[k]
		if v ~= nil then
			return v
		end
		return (_G :: any)[k]
	end })
end

local function compile(inst: any)
	local dd = d(inst)
	local fn, err = loadstring(dd.source, "=" .. (dd.path or fullName(inst)))
	if not fn then
		error("syntax error in " .. tostring(dd.path) .. ": " .. tostring(err), 0)
	end
	setfenv(fn, envFor(inst))
	return fn
end

G.require = function(target: any)
	if type(target) ~= "table" or not data[target] then
		if type(target) == "number" then
			error("require(assetId) is not available headless")
		end
		error("Attempted to call require with invalid argument(s).")
	end
	local dd = d(target)
	if dd.ClassName ~= "ModuleScript" then
		error("Attempted to call require with invalid argument(s).")
	end
	if cache[target] ~= nil then
		return cache[target]
	end
	if loading[target] then
		error("Requested module was required recursively: " .. fullName(target))
	end
	if not dd.source then
		error("ModuleScript " .. fullName(target) .. " has no source")
	end
	loading[target] = true
	local ok, res = pcall(compile(target))
	loading[target] = nil
	if not ok then
		addError(res, nil, fullName(target))
		error("Requested module experienced an error while loading: " .. fullName(target) .. ": " .. tostring(res), 0)
	end
	if res == nil then
		error("Module code did not return exactly one value: " .. fullName(target), 0)
	end
	cache[target] = res
	return res
end

function H._runScript(inst: any)
	local dd = d(inst)
	if dd.ran or dd.props.Disabled == true or dd.props.Enabled == false then
		return
	end
	dd.ran = true
	local ok, fn = pcall(compile, inst)
	if not ok then
		addError(fn, nil, fullName(inst))
		return
	end
	local co = coroutine.create(fn)
	threadScript[co] = fullName(inst)
	resume(co)
end

-- ============================================================================ file tree

local SERVICE_FOR = {
	ServerScriptService = function()
		return ServerScriptService
	end,
	ReplicatedStorage = function()
		return ReplicatedStorage
	end,
	ServerStorage = function()
		return ServerStorage
	end,
	StarterGui = function()
		return StarterGui
	end,
	Workspace = function()
		return workspace
	end,
	StarterPlayerScripts = function()
		return d(StarterPlayer).props.StarterPlayerScripts
	end,
}

local scripts: { any } = {}

-- Register one synced file (path like "ServerScriptService/Services/Foo.luau").
function H.add(path: string, class: string, source: string)
	local parts = string.split(path, "/")
	local parent = SERVICE_FOR[parts[1]] and SERVICE_FOR[parts[1]]()
	if not parent then
		return
	end
	for i = 2, #parts - 1 do
		local f = Methods.FindFirstChild(parent, parts[i])
		if not f or d(f).ClassName == "ModuleScript" or d(f).ClassName == "Script" then
			f = newInstance("Folder")
			d(f).Name = parts[i]
			setParent(f, parent)
		end
		parent = f
	end
	local file = parts[#parts]
	local name = string.gsub(string.gsub(string.gsub(file, "%.server%.luau$", ""), "%.client%.luau$", ""), "%.luau$", "")
	local inst = newInstance(class)
	d(inst).Name = name
	d(inst).source = source
	d(inst).path = path
	setParent(inst, parent)
	table.insert(scripts, inst)
	return inst
end

-- ============================================================================ run

local function stepFrame()
	now += FRAME
	local rs = d(RunService).signals
	for _, n in { "Stepped", "PreSimulation" } do
		if rs[n] then
			rs[n]:Fire(now, FRAME)
		end
	end
	for _, n in { "Heartbeat", "PostSimulation" } do
		if rs[n] then
			rs[n]:Fire(FRAME)
		end
	end
	local due = {}
	local keep = {}
	for _, q in queue do
		if q.wake <= now + 1e-9 then
			table.insert(due, q)
		else
			table.insert(keep, q)
		end
	end
	queue = keep
	for _, q in due do
		if q.args then
			resume(q.co, table.unpack(q.args, 1, q.args.n))
		else
			resume(q.co, now)
		end
	end
end

function H.run(seconds: number)
	local target = now + seconds
	while now < target do
		stepFrame()
	end
end

function H.boot(bootSeconds: number?)
	H._booted = true
	for _, inst in scripts do
		if d(inst).ClassName == "Script" and inst:IsDescendantOf(game) then
			local svc = string.split(d(inst).path, "/")[1]
			if svc == "ServerScriptService" or svc == "Workspace" or svc == "ServerStorage" then
				if svc ~= "ServerStorage" then
					H._runScript(inst)
				end
			end
		end
	end
	H.run(bootSeconds or 2)
end

local function counters(): { [string]: number }
	local out = {}
	local f = Methods.FindFirstChild(ServerStorage, "ForgeCounters")
	if f then
		for k, v in d(f).attrs do
			if type(v) == "number" then
				out[k] = v
			end
		end
	end
	return out
end

function H.report(): { [string]: any }
	local missList = {}
	for k, n in misses do
		table.insert(missList, k)
	end
	table.sort(missList)
	return {
		uptime = math.floor(now * 10 + 0.5) / 10,
		errors = errors,
		warnings = warnings,
		players = #ClassMethods.Players.GetPlayers(Players),
		counters = counters(),
		instances = #descendants(workspace, {}),
		misses = missList,
		remotes = #H.remoteLog,
		prints = prints,
	}
end

-- Runs a check body (same contract as runs/<slug>/checks/*.luau) in the booted server.
function H.check(body: string, timeout: number?): { [string]: any }
	local fn, err = loadstring(body, "=check")
	if not fn then
		return { ok = false, error = "check does not compile: " .. tostring(err) }
	end
	local holder = newInstance("Script")
	d(holder).Name = "ForgeCheck"
	setfenv(fn, envFor(holder))
	local done, result, failure = false, nil, nil
	local co = coroutine.create(function()
		local ok, res = pcall(fn)
		done = true
		if ok then
			result = res
		else
			failure = res
		end
	end)
	threadScript[co] = "ForgeCheck"
	resume(co)
	local limit = now + (timeout or 30)
	while not done and now < limit do
		stepFrame()
	end
	if not done then
		return { ok = false, error = "check timed out (simulated " .. tostring(timeout or 30) .. "s)" }
	end
	if failure ~= nil then
		return { ok = false, error = tostring(failure) }
	end
	if type(result) ~= "table" then
		return { ok = false, error = "check must return { ok = bool, detail = string }" }
	end
	return { ok = result.ok == true, detail = tostring(result.detail or "") }
end

-- opts: { mode = "boot"|"check", boot = seconds, play = seconds, players = n, check = body, timeout = s }
function H.main(opts: { [string]: any })
	local out: { [string]: any } = {}
	local ok, err = pcall(function()
		H.boot(opts.boot or 2)
		for i = 1, (opts.players or 1) do
			H.join("HeadlessPlayer" .. i)
		end
		H.run(opts.play or 3)
		if opts.mode == "check" then
			out.check = H.check(opts.check or "", opts.timeout)
		end
	end)
	if not ok then
		addError("headless runner: " .. tostring(err), nil, "headless")
	end
	out.report = H.report()
	realPrint(OUT_MARK .. jsonEncode(out))
end

H.game = game
H.G = G
H.now = function()
	return now
end

return H
