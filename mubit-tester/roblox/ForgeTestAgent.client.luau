-- ForgeTestAgent: per-client actuator for the ForgeTest harness (Studio only). docs/TESTER.md.
--
-- Answers ReplicatedStorage.ForgeTestRemote.OnClientInvoke("ForgeTest", cmd, args) for its own
-- player and returns {ok, result, error}. Commands:
--   act {action, args}  walk_to {pos|path, timeout?, arrive_radius?=1}, jump, interact {path?}, equip {name|slot},
--                       unequip, use {seconds?, aim?}, look_at {pos|path}, say {text, chat?},
--                       wait {seconds}; macros (one decision = one whole interaction, HUD diff
--                       included): go_touch {path}, go_use {path}, chase {path, touches<=5}
--   hud {}              visible HUD text (same rules as forge/play.py OBSERVE_LUAU), max 10
--   ui {max?}           {buttons, panels}: visible, interactable GuiButtons in PlayerGui (text, path
--                       below PlayerGui, gui, center x/y in MCP mouse coordinates, w/h) and open panels
--   ui_target {path|text}  find one button, arm a listener on it, return where to click it
--   ui_effect {}        after the real click: did the button fire, and what changed on screen
-- A LocalScript can't fake a click, so `press` is a real mouse click from Studio MCP (Python
-- Harness.press) between ui_target and ui_effect.
--   ping {}             {userId, name}
-- On start it calls InvokeServer("ForgeTest", "hello") so the server knows the agent is ready.

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local TextChatService = game:GetService("TextChatService")

local lp = Players.LocalPlayer
-- Prompts Roblox currently shows this player. InputHoldBegin only triggers a SHOWN prompt, and with
-- several prompts on one rack only the nearest one per key is shown.
local shownPrompts: { [ProximityPrompt]: boolean } = {}
local ProximityPromptService = game:GetService("ProximityPromptService")
ProximityPromptService.PromptShown:Connect(function(p)
	shownPrompts[p] = true
end)
ProximityPromptService.PromptHidden:Connect(function(p)
	shownPrompts[p] = nil
end)
local ARRIVE = 1 -- walk_to: horizontal studs from the target point that count as arrived (arrive_radius)
local WAYPOINT_NEAR = 2.5 -- a path waypoint counts as reached this close (keeps the walk smooth)
local STALLS = 2 -- last stretch: give up after this many 2 s pushes that gain < 0.3 studs (blocked)
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

local function moveStep(hum: Humanoid, root: BasePart, pos: Vector3, limit: number, near: number?): boolean
	local reached = false
	local conn = hum.MoveToFinished:Connect(function(ok)
		reached = ok
	end)
	hum:MoveTo(pos)
	local t0 = os.clock()
	local lastPos, lastMove = root.Position, os.clock()
	local close = near or WAYPOINT_NEAR
	while os.clock() - t0 < limit do
		task.wait(0.05)
		if (reached and flatDist(root.Position, pos) <= math.max(close, 1)) or flatDist(root.Position, pos) <= close then
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
	-- arrived = within arrive_radius of the target point (default 1 stud), so walking to a pad's path
	-- ends standing on it. A solid target can't be reached: then beside it (half size + 1.5) counts.
	local arrive = math.clamp(tonumber(args.arrive_radius) or ARRIVE, 0.5, 50)
	local beside = if inst then halfSize(inst) + 1.5 else nil
	if hum.Sit then
		hum.Sit = false
		hum.Jump = true
		task.wait(0.2)
	end
	local how = "path"
	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 6 })
	local ok = pcall(path.ComputeAsync, path, root.Position, goal)
	if inst and not (ok and path.Status == Enum.PathStatus.Success) then
		-- the target is solid (a wall board, a rack): find floor beside it, on our side first, then in
		-- front, behind and to either side, and walk to the first spot that has a path
		local cf = if inst:IsA("BasePart") then inst.CFrame else CFrame.new(goal)
		local away = Vector3.new(root.Position.X - goal.X, 0, root.Position.Z - goal.Z)
		local dirs = { cf.LookVector, -cf.LookVector, cf.RightVector, -cf.RightVector }
		if away.Magnitude > 0.1 then
			table.insert(dirs, 1, away.Unit)
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { lp.Character :: Instance, inst }
		for _, dir in dirs do
			local flat = Vector3.new(dir.X, 0, dir.Z)
			if flat.Magnitude > 0.1 then
				local probe = goal + flat.Unit * (halfSize(inst) + 3)
				local hit = workspace:Raycast(probe + Vector3.new(0, 4, 0), Vector3.new(0, -40, 0), params)
				local spot = if hit then hit.Position else Vector3.new(probe.X, root.Position.Y, probe.Z)
				ok = pcall(path.ComputeAsync, path, root.Position, spot)
				if ok and path.Status == Enum.PathStatus.Success then
					break
				end
			end
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
	-- straight-line fallback / last stretch (path ends at the nearest walkable point); stop when blocked
	local stalls = 0
	while os.clock() < deadline and flatDist(root.Position, goal) > arrive and hum.Health > 0 and stalls < STALLS do
		local before = flatDist(root.Position, goal)
		moveStep(hum, root, goal, math.min(2, deadline - os.clock()), arrive)
		stalls = if before - flatDist(root.Position, goal) < 0.3 then stalls + 1 else 0
	end
	hum:MoveTo(root.Position) -- stop
	local d = flatDist(root.Position, goal)
	local done = d <= arrive
	local why = if done then "" elseif stalls >= STALLS then " (blocked)" else " (timeout)"
	if not done and beside and d <= beside then
		done, why = true, " (beside it: the target is solid)"
	end
	return {
		done = done,
		detail = string.format("%s %.1f studs from target via %s%s", if done then "arrived" else "stopped", d, how, why),
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
		-- `action` (the prompt's ActionText, from `prompts`) picks one of several prompts on a part;
		-- otherwise a prompt directly on the part wins over one nested deeper (a locker point, a peg)
		local want = if type(args.action) == "string" and args.action ~= "" then string.lower(args.action) else nil
		local function fits(d: Instance): boolean
			return d:IsA("ProximityPrompt") and d.Enabled
				and (want == nil or string.find(string.lower(d.ActionText), want, 1, true) ~= nil)
		end
		for _, d in inst:GetChildren() do
			if fits(d) then
				return d :: ProximityPrompt
			end
		end
		for _, scope in scopes do
			if scope then
				for _, d in scope:GetDescendants() do
					if fits(d) then
						return d :: ProximityPrompt
					end
				end
			end
		end
		error("no enabled ProximityPrompt" .. (if want then " '" .. args.action .. "'" else "") .. " on " .. tostring(args.path))
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

------------------------------------------------------------------------------- macros
-- One tester decision = one whole interaction: walk there AND touch/use/chase, so a single LLM call
-- gets a result worth judging. The server wraps these with an effect diff (stats, attributes, events).

local function macroTimeout(args: any): number
	return math.clamp(tonumber(args.timeout) or 20, 2, 60)
end

-- the part to touch for an instance: itself, a model's PrimaryPart / first part, or its ancestor part
local function partOf(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	end
	if inst:IsA("Model") then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return inst:FindFirstAncestorWhichIsA("BasePart")
end

local function mustInstance(path: any): Instance
	if type(path) ~= "string" or path == "" then
		error("path required (copy it from touchables, things or prompts)")
	end
	local inst = resolvePath(path)
	if not inst then
		error("no instance at path " .. path)
	end
	return inst
end

-- counts touches from our character on every part of `inst`, at most one per `gap` seconds
local function touchCounter(inst: Instance, char: Model, gap: number): (() -> number, () -> ())
	local count, last = 0, -math.huge
	local conns = {}
	local parts = if inst:IsA("BasePart") then { inst } else inst:GetDescendants()
	for _, p in parts do
		if p:IsA("BasePart") then
			table.insert(conns, p.Touched:Connect(function(hit)
				if hit:IsDescendantOf(char) and os.clock() - last >= gap then
					count += 1
					last = os.clock()
				end
			end))
		end
	end
	return function()
		return count
	end, function()
		for _, c in conns do
			c:Disconnect()
		end
	end
end

local function goTouch(args)
	local char, hum, root = body()
	local inst = mustInstance(args.path)
	local part = partOf(inst)
	if not part then
		error("nothing to touch at " .. tostring(args.path))
	end
	local deadline = os.clock() + macroTimeout(args)
	local touches, stop = touchCounter(inst, char, 0.3)
	local walked = walkTo({ path = part:GetFullName(), timeout = math.max(1, deadline - os.clock()) })
	-- walk_to stops beside the part; step onto its top and hop to make a fresh contact
	local hops = 0
	while touches() == 0 and os.clock() < deadline and hum.Health > 0 and part.Parent do
		local top = part.Position + Vector3.new(0, part.Size.Y / 2, 0)
		moveStep(hum, root, top, math.min(1.5, deadline - os.clock()))
		if touches() == 0 and flatDist(root.Position, part.Position) < math.max(part.Size.X, part.Size.Z) / 2 + 2 then
			hum.Jump = true
			hops += 1
			task.wait(0.4)
		end
	end
	task.wait(0.2)
	stop()
	hum:MoveTo(root.Position)
	local n = touches()
	local note = if part.CanTouch then "" else " (the part has CanTouch=false)"
	return {
		done = n > 0,
		detail = string.format("%s %s after %s%s%s", if n > 0 then "touched" else "never touched", part:GetFullName(),
			walked.detail, if hops > 0 then string.format(", %d hop(s)", hops) else "", note),
		touched = n > 0,
	}
end

local function goUse(args)
	local _, hum, root = body()
	mustInstance(args.path)
	local prompt = findPrompt({ path = args.path, action = args.action }, root) :: ProximityPrompt
	local deadline = os.clock() + macroTimeout(args)
	local spot = prompt.Parent :: Instance
	local walked = walkTo({ path = spot:GetFullName(), timeout = math.max(1, deadline - os.clock()) })
	-- walk_to's "arrived" is relative to the part's size; a prompt needs its own activation range
	local range = math.max(prompt.MaxActivationDistance - 1.5, 2)
	while os.clock() < deadline and hum.Health > 0 do
		local p = posOf(spot)
		if not p or (p - root.Position).Magnitude <= range then
			break
		end
		moveStep(hum, root, p, math.min(1.5, deadline - os.clock()))
	end
	-- in range but another prompt nearby is the shown one: close in on ours and face it
	local closeBy = os.clock() + 3
	while not shownPrompts[prompt] and os.clock() < math.min(closeBy, deadline) and hum.Health > 0 do
		local p = posOf(spot)
		if not p then
			break
		end
		if flatDist(root.Position, p) > 2 then
			moveStep(hum, root, p, 0.5)
		end
		faceTo(root, p)
		aimCamera(p)
		task.wait(0.15)
	end
	hum:MoveTo(root.Position)
	local wasShown = shownPrompts[prompt] == true
	local used = interact({ path = prompt:GetFullName() })
	used.detail = "walked (" .. walked.detail .. "), then " .. used.detail
		.. (if wasShown then "" else " [prompt was never shown to the player: another prompt nearby took its place]")
	used.shown = wasShown
	return used
end

local function chase(args)
	local char, hum, root = body()
	local inst = mustInstance(args.path)
	local want = math.clamp(math.floor(tonumber(args.touches) or 1), 1, 5)
	local t0 = os.clock()
	local deadline = t0 + macroTimeout(args)
	local touches, stop = touchCounter(inst, char, 0.5)
	while touches() < want and os.clock() < deadline and hum.Health > 0 and inst:IsDescendantOf(game) do
		local p = posOf(inst)
		if not p then
			break
		end
		hum:MoveTo(p)
		if flatDist(root.Position, p) < 4 and p.Y > root.Position.Y + 2 then
			hum.Jump = true
		end
		task.wait(0.1)
	end
	stop()
	hum:MoveTo(root.Position)
	local n = touches()
	local p = posOf(inst)
	return {
		done = n >= want,
		detail = string.format("touched %s %d/%d times in %.1fs%s", tostring(args.path), n, want, os.clock() - t0,
			if not inst:IsDescendantOf(game) then " (target is gone)" elseif p then string.format(", %.0f studs away now", (p - root.Position).Magnitude) else ""),
		touches = n,
	}
end

local MACROS = { go_touch = true, go_use = true, chase = true }

local ACTIONS = {
	go_touch = goTouch,
	go_use = goUse,
	chase = chase,
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

local function shownIn(pg: Instance, g: Instance): boolean
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
	return cur == pg
end

local function hud(limit: number?): { string }
	local out = {}
	local pg = lp:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return out
	end
	local function shown(g: Instance): boolean
		return shownIn(pg, g)
	end
	for _, g in pg:GetDescendants() do
		if #out >= (limit or 10) then
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

------------------------------------------------------------------------------- ui

local UI_MAX = 10
local PANEL_MAX = 5
local PANEL_SHARE = 0.08 -- a frame covering this share of the screen counts as an open panel

local function clean(t: string, n: number): string
	t = string.gsub(t, "%s+", " ")
	t = string.match(t, "^%s*(.-)%s*$") or ""
	return string.sub(t, 1, n)
end

-- Path below PlayerGui. Same-named siblings get an index ("Panel.TextButton[2]") so every button has
-- its own path; the second result says whether Studio MCP can address it as an instance path.
local function relPath(pg: Instance, g: Instance): (string, boolean)
	local parts = {}
	local plain = true
	local cur: Instance? = g
	while cur and cur ~= pg do
		local name = cur.Name
		plain = plain and string.find(name, ".", 1, true) == nil
		local parent = cur.Parent
		if parent then
			local n, idx = 0, 0
			for _, c in parent:GetChildren() do
				if c.Name == cur.Name then
					n += 1
					if c == cur then
						idx = n
					end
				end
			end
			if n > 1 then
				name ..= "[" .. idx .. "]"
				plain = false
			end
		end
		table.insert(parts, 1, name)
		cur = parent
	end
	return table.concat(parts, "."), plain
end

local function firstText(root: Instance, pg: Instance): string
	for _, d in root:GetDescendants() do
		if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.TextTransparency < 1 and shownIn(pg, d) then
			local t = clean(if d.ContentText ~= "" then d.ContentText else d.Text, 40)
			if t ~= "" then
				return t
			end
		end
	end
	return ""
end

local function buttonText(b: GuiButton, pg: Instance): string
	local t = ""
	if b:IsA("TextButton") then
		t = clean(if b.ContentText ~= "" then b.ContentText else b.Text, 40)
	end
	if t == "" then
		t = firstText(b, pg)
	end
	return t
end

local function interactable(g: GuiObject): boolean
	local ok, v = pcall(function()
		return (g :: any).Interactable
	end)
	return not ok or v ~= false
end

local function viewport(): Vector2
	local cam = workspace.CurrentCamera
	return if cam then cam.ViewportSize else Vector2.new(1920, 1080)
end

-- x/y are the button's center in AbsolutePosition space, which is what Studio MCP's
-- user_mouse_input x/y expect (measured live: it adds the top-bar inset itself).
local function describe(b: GuiButton, pg: Instance)
	local c = b.AbsolutePosition + b.AbsoluteSize / 2
	local sg = b:FindFirstAncestorWhichIsA("LayerCollector")
	return {
		text = buttonText(b, pg),
		path = relPath(pg, b),
		gui = sg and sg.Name or nil,
		x = math.floor(c.X + 0.5),
		y = math.floor(c.Y + 0.5),
		w = math.floor(b.AbsoluteSize.X + 0.5),
		h = math.floor(b.AbsoluteSize.Y + 0.5),
		order = if sg and sg:IsA("ScreenGui") then sg.DisplayOrder else 0,
	}
end

local function visibleButtons(pg: Instance): { GuiButton }
	local vp = viewport()
	local top = GuiService:GetGuiInset()
	local out = {}
	for _, g in pg:GetDescendants() do
		if g:IsA("GuiButton") and g.AbsoluteSize.X > 1 and g.AbsoluteSize.Y > 1 and interactable(g) and shownIn(pg, g) then
			local c = g.AbsolutePosition + g.AbsoluteSize / 2
			if c.X >= 0 and c.Y >= -top.Y and c.X <= vp.X and c.Y <= vp.Y and g:FindFirstAncestorWhichIsA("ScreenGui") then
				table.insert(out, g)
			end
		end
	end
	return out
end

local function panels(pg: Instance): { any }
	local vp = viewport()
	local area = vp.X * vp.Y
	local out = {}
	for _, sg in pg:GetChildren() do
		if sg:IsA("ScreenGui") and sg.Enabled then
			for _, f in sg:GetDescendants() do
				if #out >= PANEL_MAX then
					break
				end
				if (f:IsA("Frame") or f:IsA("ScrollingFrame") or f:IsA("ImageLabel")) and f.BackgroundTransparency < 1
					and f.AbsoluteSize.X * f.AbsoluteSize.Y >= area * PANEL_SHARE and shownIn(pg, f) then
					local parent = f.Parent
					local nested = parent and parent:IsA("GuiObject")
						and parent.AbsoluteSize.X * parent.AbsoluteSize.Y >= area * PANEL_SHARE
					if not nested then
						table.insert(out, { gui = sg.Name, path = relPath(pg, f), title = firstText(f, pg) })
					end
				end
			end
		end
	end
	return out
end

-- A minimized or hidden Studio window renders no game view during play: the viewport is 1x1, every
-- scale-sized button has no size, and real clicks (Studio MCP user_mouse_input) never land.
local MIN_VIEWPORT = 50

local function viewportSize(): { number }
	local vp = viewport()
	return { math.floor(vp.X + 0.5), math.floor(vp.Y + 0.5) }
end

local function notRendering(): string?
	local vp = viewportSize()
	if vp[1] >= MIN_VIEWPORT and vp[2] >= MIN_VIEWPORT then
		return nil
	end
	return string.format("the game view is not rendering (viewport %dx%d): the Studio window that drives this player "
		.. "is minimized or hidden, so no GUI button can be seen or clicked until it is restored", vp[1], vp[2])
end

local function uiView(args: any)
	local pg = lp:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return { buttons = {}, panels = {}, total = 0, viewport = viewportSize(), not_rendering = notRendering() }
	end
	local all = {}
	for _, b in visibleButtons(pg) do
		table.insert(all, describe(b, pg))
	end
	-- top-most GUIs first (an open panel's buttons), then reading order
	table.sort(all, function(a, b)
		if a.order ~= b.order then
			return a.order > b.order
		end
		if math.abs(a.y - b.y) > 4 then
			return a.y < b.y
		end
		return a.x < b.x
	end)
	local max = math.clamp(tonumber(args and args.max) or UI_MAX, 1, 50)
	local buttons = {}
	for i = 1, math.min(max, #all) do
		all[i].order = nil
		table.insert(buttons, all[i])
	end
	return { buttons = buttons, panels = panels(pg), total = #all, viewport = viewportSize(), not_rendering = notRendering() }
end

-- path: below PlayerGui ("BattlePassGui.PassButton"), or a full path through PlayerGui.
-- text: the button's text, case-insensitive; exact match first, then contains, then in the path.
local function findButton(args: any): (GuiButton?, { string })
	local pg = lp:FindFirstChildOfClass("PlayerGui")
	if not pg then
		error("no PlayerGui")
	end
	local buttons = visibleButtons(pg)
	local names = {}
	for _, b in buttons do
		local t = buttonText(b, pg)
		table.insert(names, if t ~= "" then t else relPath(pg, b))
	end
	local path = if type(args.path) == "string" then args.path else nil
	if path and path ~= "" then
		path = string.match(path, "PlayerGui%.(.+)$") or path
		for _, b in buttons do
			if relPath(pg, b) == path then
				return b, names
			end
		end
		for _, b in buttons do
			if string.sub(relPath(pg, b), -#path - 1) == "." .. path then
				return b, names
			end
		end
	end
	local text = if type(args.text) == "string" then string.lower(clean(args.text, 80)) else nil
	if text and text ~= "" then
		for _, b in buttons do
			if string.lower(buttonText(b, pg)) == text then
				return b, names
			end
		end
		for _, b in buttons do
			local bt = string.lower(buttonText(b, pg))
			if bt ~= "" and string.find(bt, text, 1, true) then
				return b, names
			end
		end
		for _, b in buttons do
			if string.find(string.lower((relPath(pg, b))), text, 1, true) then
				return b, names
			end
		end
	end
	return nil, names
end

local pending: any = nil -- {info, conns, fired, before} between ui_target and ui_effect

local function snapshot()
	local pg = lp:FindFirstChildOfClass("PlayerGui")
	local view = uiView({ max = 50 })
	local guis = {}
	if pg then
		for _, sg in pg:GetChildren() do
			if sg:IsA("LayerCollector") and sg.Enabled then
				guis[sg.Name] = true
			end
		end
	end
	return { buttons = view.buttons, panels = view.panels, hud = hud(300), guis = guis }
end

local function disarm()
	if pending then
		for _, c in pending.conns do
			c:Disconnect()
		end
	end
	pending = nil
end

local function uiTarget(args: any)
	disarm()
	local b, names = findButton(args)
	if not b then
		local what = if args.path then "path '" .. tostring(args.path) .. "'" else "text '" .. tostring(args.text) .. "'"
		local blind = notRendering()
		error("no visible button matches " .. what .. "; visible: [" .. table.concat(names, ", ") .. "]"
			.. (if blind then "; " .. blind else ""))
	end
	local pg = lp:FindFirstChildOfClass("PlayerGui") :: PlayerGui
	local info = describe(b, pg)
	info.order = nil
	-- MCP moves the mouse to an instance path's exact center; otherwise Python clicks x/y
	local _, plain = relPath(pg, b)
	info.instance_path = if plain then "LocalPlayer.PlayerGui." .. info.path else nil
	-- the first input-sinking object at that point (another button or Active frame swallows the click)
	for _, hit in pg:GetGuiObjectsAtPosition(info.x, info.y) do
		if hit == b or hit:IsDescendantOf(b) then
			break
		end
		if (hit:IsA("GuiButton") or hit.Active) and interactable(hit) and shownIn(pg, hit) then
			info.covered_by = relPath(pg, hit)
			break
		end
	end
	local fired = {}
	local conns = {
		b.Activated:Connect(function()
			table.insert(fired, "Activated")
		end),
		b.MouseButton1Click:Connect(function()
			table.insert(fired, "MouseButton1Click")
		end),
	}
	pending = { info = info, conns = conns, fired = fired, before = snapshot() }
	return info
end

local function keyed(list: { any }, key: (any) -> string): { [string]: boolean }
	local m = {}
	for _, v in list do
		m[key(v)] = true
	end
	return m
end

local function added(a: { [string]: boolean }, b: { [string]: boolean }, max: number): { string }
	local out = {}
	for k in b do
		if not a[k] then
			table.insert(out, k)
		end
	end
	table.sort(out)
	while #out > max do
		table.remove(out)
	end
	return out
end

local function uiEffect()
	local p = pending
	if not p then
		error("no armed press (call ui_target first)")
	end
	local after = snapshot()
	local before = p.before
	local fired = table.clone(p.fired)
	disarm()
	local function bkey(x): string
		return (if x.text ~= "" then x.text else "?") .. " @ " .. x.path
	end
	local function pkey(x): string
		return x.path .. (if x.title ~= "" then " '" .. x.title .. "'" else "")
	end
	local function same(x): string
		return x
	end
	local bB, bA = keyed(before.buttons, bkey), keyed(after.buttons, bkey)
	local pB, pA = keyed(before.panels, pkey), keyed(after.panels, pkey)
	local hB, hA = keyed(before.hud, same), keyed(after.hud, same)
	local effect = {
		guis_opened = added(before.guis, after.guis, 5),
		guis_closed = added(after.guis, before.guis, 5),
		panels_opened = added(pB, pA, 5),
		panels_closed = added(pA, pB, 5),
		buttons_new = added(bB, bA, 8),
		buttons_gone = added(bA, bB, 8),
		hud_new = added(hB, hA, 6),
		hud_gone = added(hA, hB, 6),
	}
	local changed = false
	for _, v in effect do
		if #v > 0 then
			changed = true
		end
	end
	local out = {
		path = p.info.path,
		text = p.info.text,
		gui = p.info.gui,
		fired = #fired > 0,
		signals = fired,
		changed = changed,
		effect = effect,
	}
	local r = ReplicatedStorage:FindFirstChild("ForgeTestRemote")
	if r and r:IsA("RemoteFunction") then
		task.spawn(pcall, r.InvokeServer, r, "ForgeTest", "event", "ui_press", out)
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
		if not MACROS[action] then
			return fn(a)
		end
		local before = hud(300)
		local res = fn(a)
		task.wait(0.3) -- let the HUD react (server replies, tweens)
		local after = hud(300)
		local function added(x: { string }, y: { string }): { string }
			local seen, out = {}, {}
			for _, t in x do
				seen[t] = true
			end
			for _, t in y do
				if not seen[t] and #out < 6 then
					seen[t] = true
					table.insert(out, t)
				end
			end
			return out
		end
		res.hud_new, res.hud_gone = added(before, after), added(after, before)
		return res
	end,
	hud = function()
		return hud()
	end,
	ui = function(args)
		return uiView(args)
	end,
	ui_target = function(args)
		return uiTarget(args)
	end,
	ui_effect = function()
		return uiEffect()
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
