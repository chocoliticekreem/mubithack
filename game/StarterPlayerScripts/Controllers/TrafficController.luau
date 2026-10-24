--!strict
-- TrafficController [owner: Traffic]. Renders TrafficService's kinematic cars smoothly.
-- The server publishes each car's pose as attributes (Pose: CFrame, Speed, State) at ~10 Hz and never
-- moves the parts; here every frame we interpolate between the last snapshots (InterpDelay in the past,
-- short extrapolation when they run out) and set the anchored Hitbox's CFrame locally (the welded body
-- follows). Plus: a little suspension bob, a hop + "HONK!" + horn on Traffic/Honk, "AAAH!" popups (ClientLib/WorldPopup) for
-- panicking drivers, and local collisions (you bump into cars you see; off while you drive a truck so
-- the server's ram check flings them instead of your truck stopping dead).
-- Brake lamps glow on attr Brake; indicators (BlinkerL/BlinkerR) blink on attr Blink "L"/"R".
-- State "Wrecked" = server physics owns the car: hands off.
-- Reads: tag TrafficCar + attrs Pose/Speed/State/RootY/Blink/Brake; remote Traffic/Honk; AudioController:Play (nil-guarded).
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("TrafficConfig") :: ModuleScript) :: any
local WorldPopup = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("WorldPopup") :: ModuleScript)

local TrafficController = {}
TrafficController.Priority = 120

local CAR_TAG = "TrafficCar"
local MAX_SNAPS = 6

type Snap = { t: number, cf: CFrame, v: number }
type Rec = {
	model: Model,
	root: BasePart?,
	rootY: number,
	snaps: { Snap },
	state: string,
	phase: number,
	hopAt: number,
	bubble: BillboardGui?,
	bubbleUntil: number,
	conns: { RBXScriptConnection },
	brakeLamps: { BasePart },
	blinkL: { BasePart },
	blinkR: { BasePart },
	brake: boolean,
	blink: string,
	litBrake: boolean,
	litL: boolean,
	litR: boolean,
}

local BRAKE_ON = Color3.fromHex("#FF2A1A")
local BRAKE_OFF = Color3.fromHex("#5A1E1A")
local BLINK_ON = Color3.fromHex("#FFB020")
local BLINK_OFF = Color3.fromHex("#6B4A1A")

local function setLit(parts: { BasePart }, on: boolean, onColor: Color3, offColor: Color3)
	for _, p in parts do
		p.Color = if on then onColor else offColor
		p.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
	end
end

local function findLamps(rec: Rec)
	rec.brakeLamps, rec.blinkL, rec.blinkR = {}, {}, {}
	for _, d in rec.model:GetDescendants() do
		if d:IsA("BasePart") then
			if string.sub(d.Name, 1, 9) == "BrakeLamp" then
				table.insert(rec.brakeLamps, d)
			elseif d.Name == "BlinkerL" then
				table.insert(rec.blinkL, d)
			elseif d.Name == "BlinkerR" then
				table.insert(rec.blinkR, d)
			end
		end
	end
end

-- lamps follow Brake / Blink; indicators flash at ~1.4 Hz, all cars in step (looks deliberate)
local function lamps(rec: Rec, now: number)
	local flash = (now * 1.4) % 1 < 0.55
	local wantBrake = rec.brake
	local wantL = flash and rec.blink == "L"
	local wantR = flash and rec.blink == "R"
	if wantBrake ~= rec.litBrake then
		rec.litBrake = wantBrake
		setLit(rec.brakeLamps, wantBrake, BRAKE_ON, BRAKE_OFF)
	end
	if wantL ~= rec.litL then
		rec.litL = wantL
		setLit(rec.blinkL, wantL, BLINK_ON, BLINK_OFF)
	end
	if wantR ~= rec.litR then
		rec.litR = wantR
		setLit(rec.blinkR, wantR, BLINK_ON, BLINK_OFF)
	end
end

local controllers: { [string]: any } = {}
local recs: { [Model]: Rec } = {}
local driving = false

local function say(rec: Rec, text: string, seconds: number)
	local root = rec.root
	if not root then
		return
	end
	-- subtle world text over the car (ClientLib/WorldPopup: caps, dedupe, feedback setting)
	WorldPopup.show(root, text, {
		color = Color3.fromHex("#FFC531"),
		height = rec.rootY + 2.5,
		seconds = math.min(seconds, 1.4),
	})
end

local function pushSnap(rec: Rec)
	local pose = rec.model:GetAttribute("Pose")
	if typeof(pose) ~= "CFrame" then
		return
	end
	local v = rec.model:GetAttribute("Speed")
	table.insert(rec.snaps, { t = os.clock(), cf = pose :: CFrame, v = if type(v) == "number" then v else 0 })
	if #rec.snaps > MAX_SNAPS then
		table.remove(rec.snaps, 1)
	end
end

local function untrack(model: Model)
	local rec = recs[model]
	if not rec then
		return
	end
	for _, c in rec.conns do
		c:Disconnect()
	end
	recs[model] = nil
end

local function track(inst: Instance)
	if not inst:IsA("Model") or recs[inst] then
		return
	end
	local model = inst :: Model
	local rec: Rec = {
		model = model,
		root = model.PrimaryPart or model:FindFirstChild("Hitbox") :: BasePart?,
		rootY = (model:GetAttribute("RootY") :: number?) or 3,
		snaps = {},
		state = (model:GetAttribute("State") :: string?) or "Drive",
		phase = math.random() * 10,
		hopAt = -10,
		bubble = nil,
		bubbleUntil = 0,
		conns = {},
		brakeLamps = {},
		blinkL = {},
		blinkR = {},
		brake = model:GetAttribute("Brake") == true,
		blink = (model:GetAttribute("Blink") :: string?) or "",
		litBrake = false,
		litL = false,
		litR = false,
	}
	recs[model] = rec
	findLamps(rec)
	pushSnap(rec)
	table.insert(
		rec.conns,
		model:GetAttributeChangedSignal("Brake"):Connect(function()
			rec.brake = model:GetAttribute("Brake") == true
		end)
	)
	table.insert(
		rec.conns,
		model:GetAttributeChangedSignal("Blink"):Connect(function()
			local b = model:GetAttribute("Blink")
			rec.blink = if type(b) == "string" then b else ""
		end)
	)
	table.insert(
		rec.conns,
		model:GetAttributeChangedSignal("Pose"):Connect(function()
			pushSnap(rec)
		end)
	)
	table.insert(
		rec.conns,
		model:GetAttributeChangedSignal("State"):Connect(function()
			local st = (model:GetAttribute("State") :: string?) or "Drive"
			local was = rec.state
			rec.state = st
			if st == "Panic" then
				local lines = { "AAAAH!", "WAAH!", "NOPE!", "EEEK!" }
				say(rec, lines[math.random(1, #lines)], Cfg.PanicSeconds + 0.6)
			elseif st == "Yield" and was == "Drive" then
				say(rec, "!", 1.2)
			end
		end)
	)
	table.insert(
		rec.conns,
		model.ChildAdded:Connect(function()
			if not rec.root then
				rec.root = model.PrimaryPart or model:FindFirstChild("Hitbox") :: BasePart?
			end
			findLamps(rec)
		end)
	)
end

local function onHonk(model: any)
	if typeof(model) ~= "Instance" then
		return
	end
	local rec = recs[model :: Model]
	if not rec or not rec.root then
		return
	end
	rec.hopAt = os.clock()
	say(rec, if math.random() < 0.8 then "HONK!" else "BEEP BEEP!", 0.9)
	local Audio = controllers.AudioController
	if Audio and type(Audio.Play) == "function" then
		pcall(Audio.Play, Audio, Cfg.HonkSound, rec.root, { speed = 1.1 + math.random() * 0.4 })
	end
end

-- Far cars are moved every FAR_EVERY-th frame only (moving a welded car is the client's top Lua cost;
-- at 160+ studs a 20 Hz car is indistinguishable from a 60 Hz one).
local FAR_STUDS2 = 160 * 160
local FAR_EVERY = 3
local frame = 0

local function render()
	frame += 1
	local now = os.clock()
	local renderT = now - Cfg.InterpDelay
	local cam = workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else Vector3.zero
	local radius2 = Cfg.RenderRadius * Cfg.RenderRadius
	for _, rec in recs do
		if rec.bubble and rec.bubbleUntil < now and rec.bubble.Enabled then
			rec.bubble.Enabled = false
		end
		local root = rec.root
		if rec.state == "Wrecked" or not root or not root.Parent or not root.Anchored then
			continue
		end
		local snaps = rec.snaps
		local n = #snaps
		if n == 0 then
			continue
		end
		local last = snaps[n]
		local d = last.cf.Position - camPos
		local dist2 = d.X * d.X + d.Z * d.Z
		if dist2 > radius2 then
			continue
		end
		if dist2 > FAR_STUDS2 and (frame + math.floor(rec.phase * 7)) % FAR_EVERY ~= 0 then
			continue
		end
		lamps(rec, now)
		local cf: CFrame
		local v = last.v
		if renderT <= snaps[1].t then
			cf = snaps[1].cf
		elseif renderT >= last.t then
			local ahead = math.min(renderT - last.t, Cfg.MaxExtrapolate)
			cf = last.cf + last.cf.LookVector * (last.v * ahead)
		else
			cf = last.cf
			for i = n - 1, 1, -1 do
				local a = snaps[i]
				if a.t <= renderT then
					local b = snaps[i + 1]
					local alpha = (renderT - a.t) / math.max(b.t - a.t, 1e-3)
					cf = a.cf:Lerp(b.cf, alpha)
					v = a.v + (b.v - a.v) * alpha
					break
				end
			end
		end
		local bob = math.abs(math.sin(now * (6 + v * 0.25) + rec.phase)) * Cfg.BobAmplitude * math.min(v / 15, 1)
		local hopT = (now - rec.hopAt) / 0.28
		local hop = if hopT < 1 then math.sin(hopT * math.pi) * 0.7 else 0
		local roll = if rec.state == "Panic" then math.sin(now * 17 + rec.phase) * 0.1 else 0
		root.CFrame = cf * CFrame.new(0, rec.rootY + bob + hop, 0) * CFrame.Angles(0, 0, roll)
	end
end

local function refreshCollision()
	local char = Players.LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	driving = seat ~= nil and seat:IsA("VehicleSeat")
	for _, rec in recs do
		local root = rec.root
		if root and root.Anchored and rec.state ~= "Wrecked" then
			root.CanCollide = not driving
		end
	end
end

function TrafficController:Init(all: { [string]: any })
	controllers = all
end

function TrafficController:Start()
	CollectionService:GetInstanceAddedSignal(CAR_TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(CAR_TAG):Connect(function(inst: Instance)
		if inst:IsA("Model") then
			untrack(inst :: Model)
		end
	end)
	for _, inst in CollectionService:GetTagged(CAR_TAG) do
		track(inst)
	end
	RunService.RenderStepped:Connect(render)
	task.spawn(function()
		while true do
			refreshCollision()
			task.wait(0.4)
		end
	end)
	task.spawn(function()
		local ok, remote = pcall(Net.event, "Traffic", "Honk")
		if ok and remote then
			(remote :: RemoteEvent).OnClientEvent:Connect(onHonk)
		end
	end)
end

return TrafficController
