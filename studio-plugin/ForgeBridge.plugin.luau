--!nocheck
-- ForgeBridge: a two-way link between Roblox Studio and Forge (docs/STUDIO_PLUGIN.md).
--
-- Streams Studio events to the local Forge bridge (output, errors, play state, selection, script
-- tree changes, dock-widget buttons) and runs Forge's queued commands (run Luau, play/stop, state,
-- tree) the moment they arrive, over an HttpService long-poll on 127.0.0.1.
--
-- No-op by default: in a place not baked into PLACES it returns at once (no HTTP, nothing touched).
-- In a listed place it only binds (creates UI, connects signals, accepts commands) when the bridge
-- is running, the token below matches, and the bridge lists this place too. Built by
-- `forge plugin install --place NAME`, which bakes in the URL, token and places and embeds the pure
-- studio-plugin/Activity.luau module as `Activity`; the Mubit key is never in this file.
local URL = "__FORGE_BRIDGE_URL__"
local TOKEN = "__FORGE_BRIDGE_TOKEN__"
local PLACES = "__FORGE_BRIDGE_PLACES__" -- comma list of place keys (name, lower case, no .rbxlx)
local PROTOCOL = 1
local POLL_WAIT = 15
local ACTIVITY_EVERY = 4 -- seconds between Runs panel refreshes while the widget is open
local MAX_OUTBOX = 1000
local TAG = "[ForgeBridge]"

local Http = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

local dm = if RunService:IsEdit() then "Edit" elseif RunService:IsServer() then "Server" else "Client"
local session = Http:GenerateGUID(false)
local alive, bound, online = true, false, false
local connections = {}
local outbox, dropped = {}, 0
local forge = {}
local fv = -1
local stats = { sent = 0, cmds = 0, lastMs = nil }
local lastError = nil -- {message, script, trace}
local errorsByScript = {}
local ui = nil

-- Not one of our places: do nothing at all (no HTTP, no settings touched, no UI).
local function placeKey(name)
	local s = string.lower(tostring(name or ""))
	s = string.gsub(s, "%.rbxlx$", "")
	s = string.gsub(s, "%.rbxl$", "")
	return s
end
-- In a playtest every datamodel is called "Game", so the Edit copy stamps the place name on
-- Workspace (attribute ForgeBridgePlace) and the Server/Client copies read it from their clone.
local PLACE_ATTR = "ForgeBridgePlace"
local function placeName()
	if dm == "Edit" then return game.Name end
	local ok, v = pcall(function() return workspace:GetAttribute(PLACE_ATTR) end)
	return if ok and type(v) == "string" then v else game.Name
end
local listed = false
for key in string.gmatch(PLACES, "[^,]+") do
	if key == placeKey(placeName()) then listed = true end
end
if not listed then
	return
end

-- Local places ship with HttpService off, and that blocks plugin requests too. This is one of the
-- places Forge was told to bind, so keep it on (as `forge sync` does while it pulls). It is not
-- switched back off on unload: a reloaded copy would lose its connection.
local function ensureHttp()
	if not Http.HttpEnabled then
		pcall(function() Http.HttpEnabled = true end)
	end
end
ensureHttp()

-- One live copy per datamodel: a reload (or a second live-load) disposes the old one first.
local guardParent = nil
pcall(function() guardParent = game:GetService("CoreGui") end)
if guardParent then
	local old = guardParent:FindFirstChild("ForgeBridgeControl")
	if old then
		local d = old:FindFirstChild("Dispose")
		if d then pcall(function() d:Invoke() end) end
		if old.Parent then old:Destroy() end
	end
end

local function request(method, path, body)
	ensureHttp()
	local ok, res = pcall(function()
		return Http:RequestAsync({
			Url = URL .. path,
			Method = method,
			Headers = { ["X-Forge-Token"] = TOKEN, ["Content-Type"] = "application/json" },
			Body = if body ~= nil then Http:JSONEncode(body) else nil,
		})
	end)
	if not ok or not res or not res.Success then
		return nil
	end
	local ok2, obj = pcall(function() return Http:JSONDecode(res.Body) end)
	return if ok2 then obj else nil
end

local function push(ev)
	if not bound then return end
	if #outbox >= MAX_OUTBOX then
		table.remove(outbox, 1)
		dropped += 1
	end
	table.insert(outbox, ev)
end

local function clip(s, n)
	s = tostring(s or "")
	n = n or 4000
	return if #s > n then string.sub(s, 1, n) .. "…" else s
end

local function fullName(inst)
	local ok, name = pcall(function() return inst:GetFullName() end)
	return if ok then name else "?"
end

local function resolve(path)
	local node = game
	if path == nil or path == "" or path == "game" then return node end
	for part in string.gmatch(path, "[^%.]+") do
		if node == game then
			local ok, svc = pcall(function() return game:GetService(part) end)
			node = if ok and svc then svc else game:FindFirstChild(part)
		else
			node = node:FindFirstChild(part)
		end
		if not node then return nil end
	end
	return node
end

local function encodeValue(v)
	if v == nil then return "" end
	if type(v) == "string" then return v end
	if type(v) == "table" then
		local ok, s = pcall(function() return Http:JSONEncode(v) end)
		if ok then return s end
	end
	return tostring(v)
end

-- ---------------------------------------------------------------- commands

local function selectionPaths()
	local out = {}
	local ok, sel = pcall(function() return game:GetService("Selection"):Get() end)
	if ok then
		for i, inst in sel do
			if i > 20 then break end
			table.insert(out, fullName(inst))
		end
	end
	return out
end

local ops = {}

function ops.ping()
	return { dm = dm, place = placeName(), clock = os.clock() }
end

function ops.state()
	return { dm = dm, place = placeName(), running = RunService:IsRunning(),
		selection = if dm == "Edit" then selectionPaths() else {} }
end

function ops.tree(args)
	local node = resolve(args.path)
	if not node then error("no instance at " .. tostring(args.path)) end
	local kids = {}
	for i, c in node:GetChildren() do
		if i > 500 then break end
		table.insert(kids, { name = c.Name, class = c.ClassName, children = #c:GetChildren() })
	end
	return { path = fullName(node), class = node.ClassName, children = kids }
end

-- Luau runs as a fresh ModuleScript required by the plugin (plugins can't loadstring). The body is
-- wrapped in a function so a top-level `return` works the same as with StudioMCP execute_luau.
function ops.run(args)
	local code = tostring(args.code or "")
	local m = Instance.new("ModuleScript")
	m.Name = "ForgeBridgeRun"
	local before = lastError
	m.Source = "return function(...)\n" .. code .. "\nend"
	local ok, fn = pcall(require, m)
	m:Destroy()
	if not ok then
		local detail = if lastError ~= before and lastError then lastError.message else tostring(fn)
		error("compile: " .. detail, 0)
	end
	return encodeValue(fn())
end

function ops.play(args)
	if args.start ~= false then
		if dm ~= "Edit" then error("start play from the Edit datamodel", 0) end
		task.spawn(function()
			pcall(function() game:GetService("StudioTestService"):ExecutePlayModeAsync({}) end)
		end)
		return "starting"
	end
	if dm ~= "Server" then error("stop play from the Server datamodel", 0) end
	-- answer first: ending the test tears this datamodel (and this plugin copy) down
	task.delay(0.2, function()
		pcall(function() game:GetService("StudioTestService"):EndTest("forge") end)
	end)
	return "stopping"
end

local function execute(cmd)
	local t0 = os.clock()
	local fn = ops[cmd.op]
	local ok, res
	if fn then
		ok, res = pcall(fn, cmd.args or {})
	else
		ok, res = false, "unknown op " .. tostring(cmd.op)
	end
	local ms = math.floor((os.clock() - t0) * 10000) / 10
	stats.cmds += 1
	stats.lastMs = ms
	request("POST", "/plugin/result", {
		session = session, id = cmd.id, ok = ok, ms = ms,
		result = if ok then res else nil, error = if ok then nil else clip(res),
	})
	if ui then ui.refresh() end
end

-- ---------------------------------------------------------------- dock widget (Edit only)

local function buildUi()
	local toolbar = plugin:CreateToolbar("MuHack")
	local button = toolbar:CreateButton("ForgeBridgePanel", "Show MuHack status, ask MuHack to fix, run tests", "", "MuHack")
	button.ClickableWhenViewportHidden = true
	local info = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, true, false, 320, 380, 260, 280)
	local widget = plugin:CreateDockWidgetPluginGui("ForgeBridgeStatus", info)
	widget.Title = "MuHack"
	widget.Name = "ForgeBridgeStatus"
	table.insert(connections, button.Click:Connect(function() widget.Enabled = not widget.Enabled end))

	local function color(c)
		local ok, v = pcall(function() return settings().Studio.Theme:GetColor(Enum.StudioStyleGuideColor[c]) end)
		return if ok then v else Color3.fromRGB(46, 46, 46)
	end
	local root = Instance.new("ScrollingFrame")
	root.Size = UDim2.fromScale(1, 1)
	root.BorderSizePixel = 0
	root.ScrollBarThickness = 6
	root.AutomaticCanvasSize = Enum.AutomaticSize.Y
	root.CanvasSize = UDim2.new()
	root.Parent = widget
	local pad = Instance.new("UIPadding")
	for _, k in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do pad[k] = UDim.new(0, 10) end
	pad.Parent = root
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = root

	local order = 0
	local function label(text, size, bold, parent)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Size = UDim2.new(1, -4, 0, 0)
		l.AutomaticSize = Enum.AutomaticSize.Y
		l.TextWrapped = true
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextYAlignment = Enum.TextYAlignment.Top
		l.Font = if bold then Enum.Font.SourceSansBold else Enum.Font.SourceSans
		l.TextSize = size or 15
		l.Text = text
		if not parent then
			order += 1
			l.LayoutOrder = order
		end
		l.Parent = parent or root
		return l
	end
	-- one compact row per field: dim key on the left, wrapping value on the right
	local KEY_W = 96
	local function field(name)
		order += 1
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, -4, 0, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
		row.LayoutOrder = order
		row.Parent = root
		local k = label(name, 14, true, row)
		k.Size = UDim2.new(0, KEY_W - 8, 0, 0)
		local v = label("—", 15, false, row)
		v.Position = UDim2.new(0, KEY_W, 0, 0)
		v.Size = UDim2.new(1, -KEY_W, 0, 0)
		return k, v
	end
	local function buttonRow(specs)
		order += 1
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, -4, 0, 34)
		row.LayoutOrder = order
		row.Parent = root
		local out = {}
		for i, spec in specs do
			local b = Instance.new("TextButton")
			b.Size = UDim2.new(1 / #specs, -4, 1, 0)
			b.Position = UDim2.new((i - 1) / #specs, if i > 1 then 4 else 0, 0, 0)
			b.Font = Enum.Font.SourceSansBold
			b.TextSize = 15
			b.Text = spec
			b.AutoButtonColor = true
			b.BorderSizePixel = 0
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 4)
			corner.Parent = b
			b.Parent = row
			out[i] = b
		end
		return table.unpack(out)
	end

	local title = label("MuHack", 20, true)
	local conn = label("connecting…", 14)
	local fix, tests = buttonRow({ "Ask MuHack to fix this", "Run tests" })
	local labels = {}
	local values = {}
	for _, f in { "Job", "Role at work", "Last test", "Selected", "Last error", "MuHack says" } do
		local k, v = field(f)
		labels[f] = k
		values[f] = v
	end
	local runsTitle = label("Runs", 15, true)
	order += 1
	local runsBox = Instance.new("Frame")
	runsBox.BackgroundTransparency = 1
	runsBox.Size = UDim2.new(1, -4, 0, 0)
	runsBox.AutomaticSize = Enum.AutomaticSize.Y
	runsBox.LayoutOrder = order
	runsBox.Parent = root
	local runsList = Instance.new("UIListLayout")
	runsList.Padding = UDim.new(0, 2)
	runsList.SortOrder = Enum.SortOrder.LayoutOrder
	runsList.Parent = runsBox
	local feed = nil
	local foot = label("", 12)
	local note = nil

	local function selectedScript()
		local ok, sel = pcall(function() return game:GetService("Selection"):Get() end)
		if ok then
			for _, inst in sel do
				if inst:IsA("LuaSourceContainer") then return inst end
			end
		end
		return nil
	end

	-- the widget lives in Edit; errors from a playtest arrive from the bridge as forge.last_error
	local function errorFor(path)
		local remote = type(forge.last_error) == "table" and forge.last_error or nil
		if path and errorsByScript[path] then return errorsByScript[path] end
		if path and remote and remote.script == path then return remote end
		return remote or lastError
	end

	local function paint()
		root.BackgroundColor3 = color("MainBackground")
		for _, l in root:GetDescendants() do
			if l:IsA("TextLabel") then l.TextColor3 = color("MainText") end
		end
		for _, k in labels do k.TextColor3 = color("DimmedText") end
		title.TextColor3 = color("BrightText")
		runsTitle.TextColor3 = color("BrightText")
		foot.TextColor3 = color("DimmedText")
		fix.BackgroundColor3 = Color3.fromRGB(0, 122, 204)
		fix.TextColor3 = Color3.new(1, 1, 1)
		tests.BackgroundColor3 = Color3.fromRGB(46, 160, 67)
		tests.TextColor3 = Color3.new(1, 1, 1)
	end

	local function refresh()
		local sel = selectedScript()
		local path = sel and fullName(sel)
		local err = errorFor(path)
		conn.Text = (if online then "● connected" else "○ bridge offline") .. "  ·  " .. placeName()
		conn.TextColor3 = if online then Color3.fromRGB(46, 160, 67) else Color3.fromRGB(204, 120, 0)
		values["Job"].Text = forge.job or "idle"
		values["Role at work"].Text = forge.role or "—"
		values["Last test"].Text = forge.last_test or "not run yet"
		local lt = tostring(forge.last_test or "")
		values["Last test"].TextColor3 = if string.sub(lt, 1, 4) == "PASS" then Color3.fromRGB(46, 160, 67)
			elseif string.sub(lt, 1, 4) == "FAIL" then Color3.fromRGB(215, 58, 73) else color("MainText")
		values["Selected"].Text = path or "select a script in the Explorer"
		values["Last error"].Text = if err then clip(err.message, 300) else "none seen"
		values["Last error"].TextColor3 = if err then Color3.fromRGB(215, 58, 73) else color("MainText")
		values["MuHack says"].Text = note or forge.message or "—"
		foot.Text = string.format("events sent %d  ·  commands run %d%s", stats.sent, stats.cmds,
			if stats.lastMs then string.format("  ·  last command %.1f ms in Studio", stats.lastMs) else "")
	end

	-- one line per action, rebuilt from the bridge's /activity feed; a click prints the details
	local function renderActivity()
		for _, c in runsBox:GetChildren() do
			if not c:IsA("UIListLayout") then c:Destroy() end
		end
		for i, row in Activity.rows(feed) do
			local rgb = Activity.color(row.status)
			local font = if row.kind == "run" then Enum.Font.SourceSansBold else Enum.Font.SourceSans
			local size = if row.kind == "run" then 15 else 14
			local item = Instance.new(if row.kind == "event" then "TextButton" else "Frame")
			item.BackgroundTransparency = 1
			item.BorderSizePixel = 0
			item.Size = UDim2.new(1, 0, 0, if row.kind == "run" then 22 else 18)
			item.LayoutOrder = i
			if item:IsA("TextButton") then
				item.Text = ""
				item.AutoButtonColor = false
				item.Activated:Connect(function()
					print(TAG .. " " .. Activity.detail(row.run, row.event))
				end)
			end
			-- the age/status column is sized to its own text first, so only the action text can truncate
			local asideW = if row.aside then
				math.ceil(TextService:GetTextSize(row.aside, size, font, Vector2.new(1000, 100)).X) else 0
			local text = Instance.new("TextLabel")
			text.BackgroundTransparency = 1
			text.Size = UDim2.new(1, -(asideW + (if asideW > 0 then 6 else 0)), 1, 0)
			text.TextXAlignment = Enum.TextXAlignment.Left
			text.TextTruncate = Enum.TextTruncate.AtEnd
			text.Font = font
			text.TextSize = size
			text.Text = row.text
			text.TextColor3 = if rgb then Color3.fromRGB(rgb[1], rgb[2], rgb[3])
				elseif row.kind == "event" then color("MainText") else color("DimmedText")
			text.Parent = item
			if row.aside then
				local aside = Instance.new("TextLabel")
				aside.BackgroundTransparency = 1
				aside.AnchorPoint = Vector2.new(1, 0)
				aside.Position = UDim2.new(1, 0, 0, 0)
				aside.Size = UDim2.new(0, asideW, 1, 0)
				aside.TextXAlignment = Enum.TextXAlignment.Right
				aside.Font = font
				aside.TextSize = size
				aside.Text = row.aside
				aside.TextColor3 = if row.kind == "run" then text.TextColor3 else color("DimmedText")
				aside.Parent = item
			end
			item.Parent = runsBox
		end
	end
	local function setActivity(f)
		feed = f
		renderActivity()
	end

	local function askFix()
		local sel = selectedScript()
		if not sel then
			note = "Select the broken script in the Explorer first."
			refresh()
			return false
		end
		local path = fullName(sel)
		local err = errorFor(path)
		push({ type = "fix_request", script = path, class = sel.ClassName, place = placeName(),
			error = err and clip(err.message, 1500) or "", trace = err and clip(err.trace, 1500) or "" })
		note = "Sent " .. sel.Name .. " to Forge."
		refresh()
		return true
	end
	local function runTests()
		push({ type = "run_tests", place = placeName() })
		note = "Asked Forge to run the tests."
		refresh()
		return true
	end
	table.insert(connections, fix.Activated:Connect(askFix))
	table.insert(connections, tests.Activated:Connect(runTests))
	table.insert(connections, settings().Studio.ThemeChanged:Connect(function() paint(); refresh(); renderActivity() end))
	pcall(function()
		table.insert(connections, game:GetService("Selection").SelectionChanged:Connect(function() note = nil; refresh() end))
	end)
	paint()
	refresh()
	renderActivity()
	return { widget = widget, refresh = refresh, setNote = function(t) note = t; refresh() end,
		setActivity = setActivity,
		press = { fix = askFix, tests = runTests } }
end

-- ---------------------------------------------------------------- event sources

local WATCHED = { "ServerScriptService", "ReplicatedStorage", "ServerStorage", "StarterPlayer", "StarterGui", "Workspace" }

local function watchScripts()
	local pending = {}
	local function edited(inst)
		local path = fullName(inst)
		if pending[path] then return end
		pending[path] = true
		task.delay(0.5, function()
			pending[path] = nil
			push({ type = "tree", action = "edited", path = path, class = inst.ClassName })
		end)
	end
	local sourceConns = {}
	local function track(inst)
		if dm ~= "Edit" or sourceConns[inst] then return end
		local ok, c = pcall(function()
			return inst:GetPropertyChangedSignal("Source"):Connect(function() edited(inst) end)
		end)
		if ok then sourceConns[inst] = c; table.insert(connections, c) end
	end
	for _, name in WATCHED do
		local ok, svc = pcall(function() return game:GetService(name) end)
		if ok and svc then
			if name ~= "Workspace" then
				for _, d in svc:GetDescendants() do
					if d:IsA("LuaSourceContainer") then track(d) end
				end
			end
			table.insert(connections, svc.DescendantAdded:Connect(function(d)
				if d:IsA("LuaSourceContainer") and d.Name ~= "ForgeBridgeRun" then
					track(d)
					push({ type = "tree", action = "added", path = fullName(d), class = d.ClassName })
				end
			end))
			table.insert(connections, svc.DescendantRemoving:Connect(function(d)
				if d:IsA("LuaSourceContainer") and d.Name ~= "ForgeBridgeRun" then
					local c = sourceConns[d]
					if c then c:Disconnect(); sourceConns[d] = nil end
					push({ type = "tree", action = "removed", path = fullName(d), class = d.ClassName })
				end
			end))
		end
	end
end

local function connectSources()
	local LogService = game:GetService("LogService")
	local KIND = {
		[Enum.MessageType.MessageOutput] = "output", [Enum.MessageType.MessageInfo] = "info",
		[Enum.MessageType.MessageWarning] = "warning", [Enum.MessageType.MessageError] = "error",
	}
	table.insert(connections, LogService.MessageOut:Connect(function(message, messageType)
		if string.sub(message, 1, #TAG) == TAG then return end
		local kind = KIND[messageType] or "output"
		if kind == "error" then
			lastError = { message = message, trace = "" }
		end
		push({ type = "log", kind = kind, message = clip(message) })
	end))
	pcall(function()
		table.insert(connections, game:GetService("ScriptContext").Error:Connect(function(message, trace, script)
			local path = if script then fullName(script) else nil
			local e = { message = clip(message), trace = clip(trace), script = path }
			lastError = e
			if path then errorsByScript[path] = e end
			push({ type = "error", message = e.message, trace = e.trace, script = path })
			if ui then ui.refresh() end
		end))
	end)
	if dm == "Edit" then
		pcall(function()
			table.insert(connections, game:GetService("Selection").SelectionChanged:Connect(function()
				push({ type = "selection", paths = selectionPaths() })
			end))
		end)
	end
	if dm == "Edit" then
		watchScripts() -- the synced tree; during play, character and runtime scripts would only be noise
	end
end

-- ---------------------------------------------------------------- loops

local function hello()
	local r = request("POST", "/plugin/hello", { place = placeName(), dm = dm, session = session, version = PROTOCOL })
	online = r ~= nil
	if r and r.forge then forge = r.forge end
	return r
end

local function flushLoop()
	while alive do
		if #outbox > 0 and online then
			local batch = {}
			for i = 1, math.min(#outbox, 200) do batch[i] = outbox[i] end
			if dropped > 0 then
				table.insert(batch, { type = "dropped", count = dropped })
			end
			local r = request("POST", "/plugin/events", { session = session, events = batch })
			if r then
				for _ = 1, math.min(#outbox, 200) do table.remove(outbox, 1) end
				dropped = 0
				stats.sent += #batch
			end
		end
		task.wait(0.25)
	end
end

local function pollLoop()
	while alive do
		local r = request("GET", "/plugin/poll?session=" .. session .. "&wait=" .. POLL_WAIT .. "&fv=" .. fv)
		if not alive then break end
		if r == nil then
			if online then online = false; if ui then ui.refresh() end end
			task.wait(3)
			if not alive then break end
			local h = hello()
			if h and not h.bound then online = false end
		elseif r.unknown_session then
			if alive then hello() end
		else
			if not online then online = true end
			if r.forge then
				forge = r.forge
				fv = r.forge.version or fv
				if ui then ui.setNote(nil) end -- Forge's newer word replaces the local note
			end
			for _, cmd in r.commands or {} do
				task.spawn(execute, cmd)
			end
		end
	end
end

local function bind()
	bound = true
	online = true
	if dm == "Edit" and workspace:GetAttribute(PLACE_ATTR) ~= game.Name then
		pcall(function() workspace:SetAttribute(PLACE_ATTR, game.Name) end)
	end
	connectSources()
	if dm == "Edit" then
		local ok, built = pcall(buildUi)
		if ok then ui = built else warn(TAG .. " widget failed: " .. tostring(built)) end
	end
	task.spawn(flushLoop)
	task.spawn(pollLoop)
	if ui then
		task.spawn(function()
			while alive do task.wait(1); ui.refresh() end
		end)
		task.spawn(function()
			while alive do
				if ui.widget.Enabled then
					local r = if online then request("GET", "/activity?runs=3&events=5") else nil
					if alive then ui.setActivity(r) end
				end
				task.wait(ACTIVITY_EVERY)
			end
		end)
	end
	print(TAG .. " connected to Forge (" .. dm .. ")")
end

local function dispose()
	if not alive then return end
	alive = false
	for _, c in connections do pcall(function() c:Disconnect() end) end
	if bound then
		task.spawn(function() request("POST", "/plugin/bye", { session = session }) end)
	end
	if ui and ui.widget then pcall(function() ui.widget:Destroy() end) end
end

if guardParent then
	local folder = Instance.new("Folder")
	folder.Name = "ForgeBridgeControl"
	local d = Instance.new("BindableFunction")
	d.Name = "Dispose"
	d.OnInvoke = function() dispose(); return true end
	d.Parent = folder
	-- Press("fix" | "tests") does exactly what the widget button does (for scripted demos/tests)
	local press = Instance.new("BindableFunction")
	press.Name = "Press"
	press.OnInvoke = function(kind)
		local fn = ui and ui.press[kind]
		return if fn then fn() else false
	end
	press.Parent = folder
	pcall(function() folder.Parent = guardParent end)
end
pcall(function() plugin.Unloading:Connect(dispose) end)
if dm == "Server" then
	-- the test is ending: say bye now and stop, so a late poll can't re-register this copy
	pcall(function() game:BindToClose(function()
		local wasBound = bound
		alive = false
		if wasBound then request("POST", "/plugin/bye", { session = session }) end
	end) end)
end

task.spawn(function()
	local delay = 3
	while alive and not bound do
		local r = hello()
		if r and r.bound then
			bind()
			return
		end
		-- server down: retry soon; server up but this place isn't bound: check rarely
		task.wait(if r then 15 else delay)
		delay = math.min(delay * 2, 30)
	end
end)
