-- ForgeTestAgent: per-client actuator for the ForgeTest harness (Studio only). docs/TESTER.md.
--
-- Answers ReplicatedStorage.ForgeTestRemote.OnClientInvoke("ForgeTest", cmd, args) for its own
-- player and returns {ok, result, error}. Commands:
--   act {action, args}  walk_to {pos|path, timeout?}, jump, interact {path?}, equip {name|slot},
--                       unequip, use {seconds?, aim?}, look_at {pos|path}, say {text, chat?},
--                       wait {seconds}
--   hud {}              visible HUD text (same rules as forge/play.py OBSERVE_LUAU), max 10
--   ping {}             {userId, name}
-- On start it calls InvokeServer("ForgeTest", "hello") so the server knows the agent is ready.

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local lp = Players.LocalPlayer
local ARRIVE = 4 -- studs from the target that count as arrived (plus the target's half size)
local SPRAY_HZ = 10 -- Tool/Spray is limited to 12/s on the server

------------------------------------------------------------------------------- helpers

local function r1(n: number): number
	return math.floor(n * 10 + 0.5) / 10
end

local function posOf(inst: Instance?): Vector3?
	if not inst then
		return nil
	end
	if inst:IsA("BasePart") then
		return inst.Position
	end
	if inst:IsA("Attachment") then
		return inst.WorldPosition
	end
	if inst:IsA("Model") then
		local ok, cf = pcall(inst.GetPivot, inst)
		if ok then
			return cf.Position
		end
	end
	if inst:IsA("Player") then
		local root = inst.Character and inst.Character:FindFirstChild("HumanoidRootPart")
		return root and root.Position or nil
	end
	local part = inst:FindFirstAncestorWhichIsA("BasePart")
	return part and part.Position or nil
end

local function halfSize(inst: Instance?): number
	if not inst then
		return 0
	end
	if inst:IsA("BasePart") then
		local s = inst.Size
		return math.max(s.X, s.Z) / 2
	end
	if inst:IsA("Model") then
		local ok, _, size = pcall(inst.GetBoundingBox, inst)
		if ok then
			return math.min(math.max(size.X, size.Z) / 2, 20)
		end
	end
	return 0
end

-- Same path rules as the server: GetFullName form, optional "game.", names may contain dots.
local function resolvePath(path: any): Instance?
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local segs = string.split(path, ".")
	local first = if segs[1] == "game" then 2 else 1
	local function walk(node: Instance, i: number): Instance?
		if i > #segs then
			return node
		end
		local name = segs[i]
		for j = i, #segs do
			if j > i then
				name = name .. "." .. segs[j]
			end
			local child = node:FindFirstChild(name)
			if not child and node == game then
				local ok, svc = pcall(game.GetService, game, name)
				if ok then
					child = svc
				end
			end
			if child then
				local found = walk(child, j + 1)
				if found then
					return found
				end
			end
		end
		return nil
	end
	return walk(game, first)
end

local function toVec(v: any): Vector3?
	if type(v) == "table" and tonumber(v[1]) and tonumber(v[2]) and tonumber(v[3]) then
		return Vector3.new(tonumber(v[1]), tonumber(v[2]), tonumber(v[3]))
	end
	if type(v) == "table" and tonumber(v.x or v.X) then
		return Vector3.new(tonumber(v.x or v.X), tonumber(v.y or v.Y) or 0, tonumber(v.z or v.Z) or 0)
	end
	return nil
end

-- {pos} or {path} (also a raw [x,y,z] or path string) -> position, instance
local function target(args: any, posKey: string?): (Vector3, Instance?)
	local raw = args[posKey or "pos"]
	local v = toVec(raw)
	if v then
		return v, nil
	end
	local path = args.path or (if type(raw) == "string" then raw else nil)
	if path then
		local inst = resolvePath(path)
		if not inst then
			error("no instance at path " .. tostring(path))
		end
		local p = posOf(inst)
		if not p then
			error("instance has no position: " .. tostring(path))
		end
		return p, inst
	end
	error("pos [x,y,z] or path required")
end

local function body(): (Model, Humanoid, BasePart)
	local char = lp.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not char or not hum or not root then
		error("no character")
	end
	if hum.Health <= 0 then
		error("character is dead")
	end
	return char, hum, root
end

local function flatDist(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

------------------------------------------------------------------------------- actions

local function faceTo(root: BasePart, pos: Vector3)
	local flat = Vector3.new(pos.X, root.Position.Y, pos.Z)
	if (flat - root.Position).Magnitude > 0.1 then
		root.CFrame = CFrame.lookAt(root.Position, flat)
	end
end

-- The default camera scripts derive the next frame from Camera.CFrame's look vector, so setting
-- the CFrame here turns the view without switching to a Scriptable camera.
local function aimCamera(pos: Vector3)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local focus = cam.Focus.Position
	local zoom = math.max((cam.CFrame.Position - focus).Magnitude, 0.5)
	local dir = pos - focus
	if dir.Magnitude < 0.1 then
		return
	end
	cam.CFrame = CFrame.lookAt(focus - dir.Unit * zoom, focus)
end

local function moveStep(hum: Humanoid, root: BasePart, pos: Vector3, limit: number): boolean
	local reached = false
	local conn = hum.MoveToFinished:Connect(function(ok)
		reached = ok
	end)
	hum:MoveTo(pos)
	local t0 = os.clock()
	local lastPos, lastMove = root.Position, os.clock()
	while os.clock() - t0 < limit do
		task.wait(0.1)
		if reached or flatDist(root.Position, pos) < 2.5 then
			reached = true
			break
		end
		if (root.Position - lastPos).Magnitude > 0.5 then
			lastPos, lastMove = root.Position, os.clock()
		elseif os.clock() - lastMove > 1 then
			hum.Jump = true -- stuck on a lip or prop
			lastMove = os.clock()
		end
		if hum.Health <= 0 then
			break
		end
	end
	conn:Disconnect()
	return reached
end

local function walkTo(args)
	local _, hum, root = body()
	local goal, inst = target(args)
	local timeout = math.clamp(tonumber(args.timeout) or 20, 1, 120)
	local deadline = os.clock() + timeout
	local arrive = ARRIVE + halfSize(inst)
	if hum.Sit then
		hum.Sit = false
		hum.Jump = true
		task.wait(0.2)
	end
	local how = "path"
	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 6 })
	local ok = pcall(path.ComputeAsync, path, root.Position, goal)
	if inst and not (ok and path.Status == Enum.PathStatus.Success) then
		-- the target part is solid: aim for a spot beside it, on our side
		local away = Vector3.new(root.Position.X - goal.X, 0, root.Position.Z - goal.Z)
		if away.Magnitude > 0.1 then
			local beside = goal + away.Unit * (halfSize(inst) + 3)
			ok = pcall(path.ComputeAsync, path, root.Position, Vector3.new(beside.X, root.Position.Y, beside.Z))
		end
	end
	local waypoints = if ok and path.Status == Enum.PathStatus.Success then path:GetWaypoints() else nil
	if waypoints and #waypoints > 1 then
		for i = 2, #waypoints do
			if os.clock() > deadline or flatDist(root.Position, goal) <= arrive then
				break
			end
			local wp = waypoints[i]
			if wp.Action == Enum.PathWaypointAction.Jump then
				hum.Jump = true
			end
			if not moveStep(hum, root, wp.Position, math.min(4, deadline - os.clock())) then
				how = "path, then straight"
				break
			end
		end
	else
		how = "straight (no path: " .. (if ok then path.Status.Name else "ComputeAsync failed") .. ")"
	end
	-- straight-line fallback / last stretch (path ends at the nearest walkable point)
	while os.clock() < deadline and flatDist(root.Position, goal) > arrive and hum.Health > 0 do
		moveStep(hum, root, goal, math.min(4, deadline - os.clock()))
	end
	hum:MoveTo(root.Position) -- stop
	local d = flatDist(root.Position, goal)
	local done = d <= arrive
	return {
		done = done,
		detail = string.format("%s %.1f studs from target via %s%s", if done then "arrived" else "stopped", d, how, if done then "" else " (timeout)"),
		dist = r1(d),
		pos = { r1(root.Position.X), r1(root.Position.Y), r1(root.Position.Z) },
	}
end

local function jump()
	local _, hum = body()
	hum.Jump = true
	pcall(hum.ChangeState, hum, Enum.HumanoidStateType.Jumping)
	return { done = true, detail = "jumped" }
end

local function findPrompt(args, root: BasePart): ProximityPrompt?
	if args.path then
		local inst = resolvePath(args.path)
		if not inst then
			error("no instance at path " .. tostring(args.path))
		end
		if inst:IsA("ProximityPrompt") then
			return inst
		end
		-- the part itself, then its parent (a prompt on a sibling) - but never a whole Workspace,
		-- so interact on a player's character (revive, co-carry) can't pick a random prompt
		local scopes = { inst }
		if inst:IsA("BasePart") and inst.Parent and inst.Parent ~= workspace then
			table.insert(scopes, inst.Parent)
		end
		for _, scope in scopes do
			if scope then
				for _, d in scope:GetDescendants() do
					if d:IsA("ProximityPrompt") and d.Enabled then
						return d
					end
				end
			end
		end
		error("no enabled ProximityPrompt on " .. tostring(args.path))
	end
	local best, bestD = nil, math.huge
	for _, d in workspace:GetDescendants() do
		if d:IsA("ProximityPrompt") and d.Enabled then
			local p = posOf(d.Parent)
			if p then
				local dist = (p - root.Position).Magnitude
				if dist < bestD then
					best, bestD = d, dist
				end
			end
		end
	end
	return best
end

local function interact(args)
	local _, _, root = body()
	local prompt = findPrompt(args, root)
	if not prompt then
		return { done = false, detail = "no enabled ProximityPrompt in the workspace" }
	end
	local p = posOf(prompt.Parent) or root.Position
	local dist = (p - root.Position).Magnitude
	local label = string.format("%s %s", prompt.ActionText, prompt.ObjectText)
	local triggered = false
	local conn = prompt.Triggered:Connect(function()
		triggered = true
	end)
	prompt:InputHoldBegin()
	task.wait(prompt.HoldDuration + 0.1)
	prompt:InputHoldEnd()
	local t0 = os.clock()
	while not triggered and os.clock() - t0 < 0.5 do
		task.wait(0.05)
	end
	conn:Disconnect()
	local inRange = dist <= prompt.MaxActivationDistance
	return {
		done = triggered,
		detail = string.format("%s '%s' on %s at %.1f studs (range %.0f)%s", if triggered then "triggered" else "held, not triggered:", label, prompt.Parent:GetFullName(), dist, prompt.MaxActivationDistance, if inRange then "" else ", OUT OF RANGE"),
		prompt = prompt.Parent:GetFullName(),
		dist = r1(dist),
		in_range = inRange,
	}
end

local function backpackTools(): { Tool }
	local out = {}
	local bp = lp:FindFirstChildOfClass("Backpack")
	if bp then
		for _, t in bp:GetChildren() do
			if t:IsA("Tool") then
				table.insert(out, t)
			end
		end
	end
	return out
end

local function equip(args)
	local char, hum = body()
	local held = char:FindFirstChildOfClass("Tool")
	local tools = backpackTools()
	local tool: Tool? = nil
	if args.name then
		local want = string.lower(tostring(args.name))
		if held and string.lower(held.Name) == want then
			return { done = true, detail = "already holding " .. held.Name }
		end
		for _, t in tools do
			if string.lower(t.Name) == want then
				tool = t
				break
			end
		end
	elseif tonumber(args.slot) then
		tool = tools[tonumber(args.slot)]
	else
		error("name or slot required")
	end
	if not tool then
		local names = {}
		for _, t in tools do
			table.insert(names, t.Name)
		end
		return { done = false, detail = "no such tool in backpack: [" .. table.concat(names, ", ") .. "]" .. (if held then " holding " .. held.Name else "") }
	end
	hum:EquipTool(tool)
	task.wait(0.2)
	local ok = tool.Parent == char
	return { done = ok, detail = (if ok then "equipped " else "tried to equip ") .. tool.Name }
end

local function unequip()
	local char, hum = body()
	local held = char:FindFirstChildOfClass("Tool")
	hum:UnequipTools()
	return { done = true, detail = if held then "unequipped " .. held.Name else "nothing held" }
end

local function lookAt(args)
	local _, _, root = body()
	local pos = target(args)
	faceTo(root, pos)
	aimCamera(pos)
	return { done = true, detail = string.format("facing %d, %d, %d", math.floor(pos.X), math.floor(pos.Y), math.floor(pos.Z)) }
end

local function use(args)
	local char, _, root = body()
	local tool = char:FindFirstChildOfClass("Tool")
	if not tool then
		return { done = false, detail = "no tool equipped (equip first)" }
	end
	local seconds = math.clamp(tonumber(args.seconds) or 0, 0, 30)
	local aimPos: Vector3? = nil
	if args.aim ~= nil then
		aimPos = toVec(args.aim)
		if not aimPos then
			aimPos = target({ path = args.aim })
		end
	end
	local function aimDir(): Vector3
		local head = char:FindFirstChild("Head") :: BasePart?
		local from = if head then head.Position else root.Position
		if aimPos and (aimPos - from).Magnitude > 0.1 then
			return (aimPos - from).Unit
		end
		return root.CFrame.LookVector
	end
	if aimPos then
		faceTo(root, aimPos)
		aimCamera(aimPos)
	end
	local net = ReplicatedStorage:FindFirstChild("Net")
	local tf = net and net:FindFirstChild("Tool")
	local spray = tf and tf:FindFirstChild("Spray")
	if spray and not spray:IsA("RemoteEvent") then
		spray = nil
	end
	tool:Activate()
	local sprays = 0
	if spray then
		spray:FireServer(aimDir())
		sprays += 1
	end
	local t0 = os.clock()
	while os.clock() - t0 < seconds do
		task.wait(1 / SPRAY_HZ)
		if tool.Parent ~= char then
			break
		end
		if aimPos then
			faceTo(root, aimPos)
		end
		if spray then
			spray:FireServer(aimDir())
			sprays += 1
		end
	end
	if tool.Parent == char then
		pcall(tool.Deactivate, tool)
	end
	return {
		done = true,
		detail = string.format("used %s for %.1fs%s", tool.Name, os.clock() - t0, if spray then string.format(" (%d Tool/Spray events)", sprays) else ""),
		sprays = sprays,
	}
end

local function say(args)
	local text = string.sub(tostring(args.text or ""), 1, 200)
	if text == "" then
		error("text required")
	end
	local char = lp.Character
	local head = char and char:FindFirstChild("Head")
	local how = "none"
	if head and TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
		if pcall(TextChatService.DisplayBubble, TextChatService, head, text) then
			how = "bubble"
		end
	end
	if how == "none" and head then
		if pcall(function()
			game:GetService("Chat"):Chat(head, text)
		end) then
			how = "legacy bubble"
		end
	end
	if args.chat then
		local ok = pcall(function()
			local channels = TextChatService:FindFirstChild("TextChannels")
			local general = channels and channels:FindFirstChild("RBXGeneral")
			if not general then
				error("no RBXGeneral")
			end
			general:SendAsync(text)
		end)
		how ..= if ok then " + chat" else " (chat failed)"
	end
	return { done = how ~= "none", detail = "said '" .. text .. "' via " .. how }
end

local ACTIONS = {
	walk_to = walkTo,
	jump = jump,
	interact = interact,
	equip = equip,
	unequip = unequip,
	use = use,
	look_at = lookAt,
	say = say,
	wait = function(args)
		local s = math.clamp(tonumber(args.seconds) or 1, 0, 60)
		task.wait(s)
		return { done = true, detail = string.format("waited %.1fs", s) }
	end,
}

------------------------------------------------------------------------------- hud

local function hud(): { string }
	local out = {}
	local pg = lp:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return out
	end
	local function shown(g: Instance): boolean
		local cur: Instance? = g
		while cur and cur ~= pg do
			if cur:IsA("GuiObject") and not cur.Visible then
				return false
			end
			if cur:IsA("LayerCollector") and not cur.Enabled then
				return false
			end
			cur = cur.Parent
		end
		return true
	end
	for _, g in pg:GetDescendants() do
		if #out >= 10 then
			break
		end
		if (g:IsA("TextLabel") or g:IsA("TextButton")) and g.TextTransparency < 1 and shown(g) then
			local t = if g.ContentText ~= "" then g.ContentText else g.Text
			t = string.gsub(t, "%s+", " ")
			t = string.match(t, "^%s*(.-)%s*$") or ""
			if t ~= "" then
				table.insert(out, string.sub(t, 1, 80))
			end
		end
	end
	return out
end

------------------------------------------------------------------------------- remote

local COMMANDS = {
	act = function(args)
		local action = tostring(args.action or "")
		local fn = ACTIONS[action]
		if not fn then
			error("unknown action " .. action)
		end
		local a = if type(args.args) == "table" then args.args else {}
		return fn(a)
	end,
	hud = function()
		return hud()
	end,
	ping = function()
		return { userId = lp.UserId, name = lp.Name }
	end,
}

local remote = ReplicatedStorage:WaitForChild("ForgeTestRemote", 60) :: RemoteFunction?
if not remote then
	warn("[ForgeTestAgent] ReplicatedStorage.ForgeTestRemote never appeared; agent off")
	return
end

remote.OnClientInvoke = function(tag: any, cmd: any, args: any)
	if tag ~= "ForgeTest" then
		return { ok = false, error = "bad tag" }
	end
	local fn = COMMANDS[tostring(cmd)]
	if not fn then
		return { ok = false, error = "unknown agent command " .. tostring(cmd) }
	end
	local ok, res = pcall(fn, if type(args) == "table" then args else {})
	if ok then
		return { ok = true, result = res }
	end
	local msg = string.gsub(tostring(res), "^[%w%.]+:%d+: ", "")
	return { ok = false, error = msg }
end

task.spawn(function()
	for _ = 1, 5 do
		if pcall(remote.InvokeServer, remote, "ForgeTest", "hello") then
			return
		end
		task.wait(2)
	end
end)

-- The lobby countdown only exists on clients (Net.Lobby.Countdown, S->C: padId, seconds (-1 =
-- cancel), title), so forward it to the harness, which logs `countdown` events and shows the
-- remaining seconds in `squads`.
task.spawn(function()
	local net = ReplicatedStorage:WaitForChild("Net", 30)
	local lobby = net and net:WaitForChild("Lobby", 30)
	local countdown = lobby and lobby:WaitForChild("Countdown", 30)
	if not (countdown and countdown:IsA("RemoteEvent")) then
		return
	end
	(countdown :: RemoteEvent).OnClientEvent:Connect(function(padId: any, seconds: any, title: any)
		task.spawn(pcall, remote.InvokeServer, remote, "ForgeTest", "event", "countdown", {
			padId = padId,
			seconds = seconds,
			title = if type(title) == "string" then title else nil,
		})
	end)
end)
