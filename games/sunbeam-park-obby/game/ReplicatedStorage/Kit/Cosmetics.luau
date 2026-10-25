--!nonstrict
-- Cosmetics (Forge kit, server): costumes built from parts in code (no catalog asset ids): hats, capes,
-- trails and body colours. Buy / equip / unequip go through one RemoteFunction the server checks;
-- owned + equipped are saved (DataStore, in memory when it is unavailable, e.g. Studio).
-- buildChangingRoom() places mannequin stands with "Try on" prompts. Pair with CosmeticsClient.
-- Do not rewrite; require it.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Cosmetics = {}

local C = {
	Ink = Color3.fromRGB(28, 22, 38), Cream = Color3.fromRGB(255, 248, 232), White = Color3.fromRGB(248, 248, 252),
	Black = Color3.fromRGB(30, 28, 36), Red = Color3.fromRGB(235, 52, 64), Orange = Color3.fromRGB(255, 140, 40),
	Yellow = Color3.fromRGB(255, 214, 50), Green = Color3.fromRGB(88, 214, 92), Blue = Color3.fromRGB(64, 150, 255),
	Purple = Color3.fromRGB(150, 70, 230), Pink = Color3.fromRGB(255, 110, 190), Gold = Color3.fromRGB(255, 196, 41),
	Glass = Color3.fromRGB(190, 225, 255), Ice = Color3.fromRGB(150, 225, 255), Mint = Color3.fromRGB(120, 240, 200),
}
local RAINBOW = { C.Red, C.Orange, C.Yellow, C.Green, C.Blue, C.Purple }
local BALL, CYL = Enum.PartType.Ball, Enum.PartType.Cylinder
local UP = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis (X) -> vertical
local FACE = CFrame.Angles(0, math.rad(90), 0) -- cylinder axis (X) -> front/back: a disc facing forward
local SLOTS = { head = "CostumeHead", back = "CostumeBack", trail = "CostumeTrail", body = "CostumeBody" }

-- ------------------------------------------------------------------ builders
-- r = rig: head, torso, root, top (CFrame on top of the head), back (top of the upper back), s (head
-- scale), ts (torso scale), faceZ. add(anchor, cframe, size, color, shape?, material?) makes a welded part.

local function cape(r, add, color: Color3, trim: Color3?)
	local w, h = 1.9 * r.ts, 2.5 * r.ts
	local cf = r.back * CFrame.Angles(math.rad(-9), 0, 0) * CFrame.new(0, -h / 2, 0.09)
	add(r.torso, cf, Vector3.new(w, h, 0.08), color, nil, Enum.Material.Fabric)
	add(r.torso, r.back * CFrame.new(0, -0.05, 0.05), Vector3.new(w * 0.95, 0.2, 0.25), trim or color, nil,
		Enum.Material.Fabric)
	return cf, w, h
end

local function trail(r, add, colors: { Color3 }, sparkle: boolean?)
	local holder = add(r.root, r.root.CFrame * CFrame.new(0, 0, 0.45), Vector3.new(0.2, 0.2, 0.2), colors[1])
	holder.Transparency = 1
	local a0, a1 = Instance.new("Attachment"), Instance.new("Attachment")
	a0.Position, a1.Position = Vector3.new(0, 0.9 * r.ts, 0), Vector3.new(0, -0.9 * r.ts, 0)
	a0.Parent, a1.Parent = holder, holder
	local keys = {}
	for i, c in colors do
		table.insert(keys, ColorSequenceKeypoint.new((i - 1) / math.max(#colors - 1, 1), c))
	end
	local t = Instance.new("Trail")
	t.Attachment0, t.Attachment1 = a0, a1
	t.Color = ColorSequence.new(keys)
	t.Lifetime, t.MinLength, t.LightEmission = 0.7, 0.05, 0.6
	t.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	t.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.3) })
	t.Parent = holder
	if sparkle then
		local p = Instance.new("ParticleEmitter")
		p.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		p.Color = ColorSequence.new(colors[1], colors[#colors])
		p.Rate, p.Lifetime, p.Speed, p.LightEmission = 14, NumberRange.new(0.5, 0.9), NumberRange.new(0.5, 1.5), 1
		p.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
		p.Parent = holder
	end
end

local CATALOG = {
	{ id = "MouseEars", name = "Mouse Ears", slot = "head", price = 0, icon = "🐭", color = C.Black,
		build = function(r, add)
			add(r.head, r.top * CFrame.new(0, -0.08 * r.s, 0), Vector3.new(1.3, 0.14, 0.3) * r.s, C.Black)
			for _, side in { -1, 1 } do
				add(r.head, r.top * CFrame.new(side * 0.5 * r.s, 0.35 * r.s, 0) * CFrame.Angles(0, 0, math.rad(-side * 18))
					* FACE, Vector3.new(0.12, 0.8, 0.8) * r.s, C.Black, CYL)
			end
			add(r.head, r.top * CFrame.new(0, 0.05 * r.s, -0.2 * r.s), Vector3.new(0.5, 0.25, 0.12) * r.s, C.Red)
		end },
	{ id = "BalloonHat", name = "Balloon Hat", slot = "head", price = 0, icon = "🎈", color = C.Red,
		build = function(r, add)
			add(r.head, r.top * CFrame.new(0, -0.08 * r.s, 0), Vector3.new(1.3, 0.14, 0.3) * r.s, C.White)
			for i, color in { C.Red, C.Blue, C.Yellow } do
				local x, h = (i - 2) * 0.5 * r.s, (if i == 2 then 1.9 else 1.5) * r.s
				local len = math.sqrt(x * x + h * h)
				add(r.head, r.top * CFrame.new(x / 2, h / 2, 0) * CFrame.Angles(0, 0, -math.atan2(x, h)),
					Vector3.new(0.05, len, 0.05), C.White)
				local b = add(r.head, r.top * CFrame.new(x, h + 0.45 * r.s, 0), Vector3.new(0.85, 1.05, 0.85) * r.s, color)
				local mesh = Instance.new("SpecialMesh")
				mesh.MeshType = Enum.MeshType.Sphere
				mesh.Parent = b
				b.Reflectance = 0.15
			end
		end },
	{ id = "PartyCone", name = "Party Cone", slot = "head", price = 10, icon = "🎉", color = C.Pink,
		build = function(r, add)
			local base = r.top * CFrame.new(0.1 * r.s, -0.1 * r.s, 0) * CFrame.Angles(0, 0, math.rad(-12))
			for i = 1, 6 do
				local d = (1.0 - (i - 1) * 0.15) * r.s
				add(r.head, base * CFrame.new(0, (i - 0.5) * 0.22 * r.s, 0) * UP, Vector3.new(0.22 * r.s, d, d),
					if i % 2 == 0 then C.White else C.Pink, CYL)
			end
			add(r.head, base * CFrame.new(0, 1.45 * r.s, 0), Vector3.one * 0.32 * r.s, C.Yellow, BALL)
		end },
	{ id = "ClownWig", name = "Clown Wig", slot = "head", price = 15, icon = "🤡", color = C.Orange,
		build = function(r, add)
			local spots = { { -0.62, -0.25, 0.15, 0.85 }, { 0.62, -0.25, 0.15, 0.85 }, { -0.42, 0.12, 0.2, 0.8 },
				{ 0.42, 0.12, 0.2, 0.8 }, { 0, 0.2, 0.05, 0.85 }, { 0, -0.15, 0.55, 0.85 } }
			for i, p in spots do
				add(r.head, r.top * CFrame.new(p[1] * r.s, p[2] * r.s, p[3] * r.s), Vector3.one * p[4] * r.s,
					RAINBOW[(i - 1) % #RAINBOW + 1], BALL)
			end
			add(r.head, r.head.CFrame * CFrame.new(0, -0.05 * r.s, -r.faceZ - 0.05), Vector3.one * 0.38 * r.s, C.Red, BALL)
		end },
	{ id = "TopHat", name = "Top Hat", slot = "head", price = 40, icon = "🎩", color = C.Black,
		build = function(r, add)
			add(r.head, r.top * CFrame.new(0, -0.12 * r.s, 0) * UP, Vector3.new(0.1, 1.9, 1.9) * r.s, C.Black, CYL)
			add(r.head, r.top * CFrame.new(0, 0.5 * r.s, 0) * UP, Vector3.new(1.15, 1.2, 1.2) * r.s, C.Black, CYL)
			add(r.head, r.top * CFrame.new(0, 0.08 * r.s, 0) * UP, Vector3.new(0.24, 1.23, 1.23) * r.s, C.Red, CYL)
		end },
	{ id = "Crown", name = "Royal Crown", slot = "head", price = 120, icon = "👑", color = C.Gold,
		build = function(r, add)
			add(r.head, r.top * CFrame.new(0, -0.02 * r.s, 0) * UP, Vector3.new(0.38, 1.25, 1.25) * r.s, C.Gold, CYL,
				Enum.Material.Metal)
			for i = 0, 5 do
				local a = i * math.pi / 3
				local tip = r.top * CFrame.new(math.cos(a) * 0.48 * r.s, 0.3 * r.s, math.sin(a) * 0.48 * r.s)
					* CFrame.Angles(0, -a, 0)
				add(r.head, tip * CFrame.Angles(0, 0, math.rad(45)), Vector3.new(0.3, 0.3, 0.12) * r.s, C.Gold, nil,
					Enum.Material.Metal)
				add(r.head, tip * CFrame.new(0, 0.24 * r.s, 0), Vector3.one * 0.16 * r.s, if i % 2 == 0 then C.Red else C.Blue,
					BALL, Enum.Material.Neon)
			end
		end },
	{ id = "AstronautHelmet", name = "Astronaut Helmet", slot = "head", price = 180, icon = "🚀", color = C.Glass,
		build = function(r, add)
			local dome = add(r.head, r.head.CFrame, Vector3.one * 2.05 * r.s, C.Glass, BALL, Enum.Material.Glass)
			dome.Transparency = 0.6
			add(r.head, r.head.CFrame * CFrame.new(0, -0.9 * r.s, 0) * UP, Vector3.new(0.35, 1.75, 1.75) * r.s, C.White, CYL)
			add(r.head, r.head.CFrame * CFrame.new(0.45 * r.s, 1.15 * r.s, 0), Vector3.new(0.06, 0.5, 0.06) * r.s, C.White)
			add(r.head, r.head.CFrame * CFrame.new(0.45 * r.s, 1.45 * r.s, 0), Vector3.one * 0.2 * r.s, C.Red, BALL,
				Enum.Material.Neon)
		end },
	{ id = "HeroCape", name = "Hero Cape", slot = "back", price = 30, icon = "⚡", color = C.Red,
		build = function(r, add)
			cape(r, add, C.Red, C.Gold)
		end },
	{ id = "StarCape", name = "Star Cape", slot = "back", price = 80, icon = "⭐", color = C.Blue,
		build = function(r, add)
			local cf, w = cape(r, add, C.Blue, C.Yellow)
			add(r.torso, cf * CFrame.new(0, 0.25, 0.06) * CFrame.Angles(0, 0, math.rad(45)), Vector3.new(0.3, 0.3, 0.04) * w * 2,
				C.Yellow, nil, Enum.Material.Neon)
		end },
	{ id = "RainbowCape", name = "Rainbow Cape", slot = "back", price = 250, icon = "🌈", color = C.Purple,
		build = function(r, add)
			local cf, w, h = cape(r, add, C.White, C.White)
			for i, color in RAINBOW do
				add(r.torso, cf * CFrame.new(0, h / 2 - (i - 0.5) * h / #RAINBOW, 0.05), Vector3.new(w, h / #RAINBOW, 0.04),
					color, nil, Enum.Material.Fabric)
			end
		end },
	{ id = "ChampionCape", name = "Champion Cape", slot = "back", price = 500, reward = true, icon = "🏆", color = C.Purple,
		build = function(r, add)
			local cf, w, h = cape(r, add, C.Purple, C.Gold)
			for _, side in { -1, 1 } do
				add(r.torso, cf * CFrame.new(side * (w / 2 - 0.08), 0, 0.05), Vector3.new(0.16, h, 0.04), C.Gold, nil,
					Enum.Material.Metal)
			end
			add(r.torso, cf * CFrame.new(0, -h / 2 + 0.08, 0.05), Vector3.new(w, 0.16, 0.04), C.Gold, nil, Enum.Material.Metal)
			add(r.torso, cf * CFrame.new(0, 0.3, 0.07), Vector3.new(0.12, 0.6, 0.6), C.Gold, CYL, Enum.Material.Metal)
		end },
	{ id = "RainbowTrail", name = "Rainbow Trail", slot = "trail", price = 120, icon = "🌈", color = C.Green,
		build = function(r, add)
			trail(r, add, RAINBOW)
		end },
	{ id = "FireTrail", name = "Fire Trail", slot = "trail", price = 90, icon = "🔥", color = C.Orange,
		build = function(r, add)
			trail(r, add, { C.Yellow, C.Orange, C.Red })
		end },
	{ id = "StarTrail", name = "Star Trail", slot = "trail", price = 150, icon = "✨", color = C.Mint,
		build = function(r, add)
			trail(r, add, { C.White, C.Mint, C.Blue }, true)
		end },
	{ id = "GoldBody", name = "Golden Statue", slot = "body", price = 300, icon = "🥇", color = C.Gold, paint = C.Gold },
	{ id = "BubblegumBody", name = "Bubblegum", slot = "body", price = 60, icon = "🍬", color = C.Pink, paint = C.Pink },
	{ id = "IceBody", name = "Ice Cold", slot = "body", price = 60, icon = "❄", color = C.Ice, paint = C.Ice },
}
local BY_ID = {}
for _, def in CATALOG do
	BY_ID[def.id] = def
end
Cosmetics.Catalog = CATALOG

-- ------------------------------------------------------------------ wearing

local BODY_PARTS = { "Head", "LeftArm", "RightArm", "LeftLeg", "RightLeg", "Torso" }

local function rigOf(model: Model)
	local head = model:FindFirstChild("Head")
	local torso = model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso")
	if not (head and head:IsA("BasePart") and torso and torso:IsA("BasePart")) then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart") or torso
	local hat = head:FindFirstChild("HatAttachment")
	local mesh = head:FindFirstChildOfClass("SpecialMesh")
	local depth = head.Size.Z * (if mesh then mesh.Scale.Z else 1)
	return {
		head = head, torso = torso, root = root,
		top = if hat then head.CFrame * hat.CFrame else head.CFrame * CFrame.new(0, head.Size.Y / 2, 0),
		back = torso.CFrame * CFrame.new(0, torso.Size.Y / 2, torso.Size.Z / 2),
		s = math.max(head.Size.Y, 0.8) / 1.2, ts = torso.Size.X / 2, faceZ = depth / 2,
	}
end

local function newAdder(model: Instance)
	return function(anchor: BasePart, cf: CFrame, size: Vector3, color: Color3, shape, material)
		local p = Instance.new("Part")
		p.Shape = shape or Enum.PartType.Block
		p.Size, p.CFrame, p.Color = size, cf, color
		p.Material = material or Enum.Material.SmoothPlastic
		p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
		p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery, p.Massless = false, false, false, false, true
		local w = Instance.new("WeldConstraint")
		w.Part0, w.Part1 = anchor, p
		w.Parent = p
		p.Parent = model
		return p
	end
end

local function hideHats(char: Model, hide: boolean)
	for _, acc in char:GetChildren() do
		local h = acc:IsA("Accessory") and acc:FindFirstChild("Handle")
		if h and h:IsA("BasePart") and (h:FindFirstChild("HatAttachment") or h:FindFirstChild("HairAttachment")) then
			if hide and h:GetAttribute("CostumeHidden") == nil then
				h:SetAttribute("CostumeHidden", h.Transparency)
				h.Transparency = 1
			elseif not hide and h:GetAttribute("CostumeHidden") ~= nil then
				h.Transparency = h:GetAttribute("CostumeHidden")
				h:SetAttribute("CostumeHidden", nil)
			end
		end
	end
end

-- color = nil puts the original colours back (kept in attributes while painted). Parts go first:
-- changing BodyColors recolours the parts at once, so reading them afterwards would save our colour.
local function paint(model: Model, color: Color3?)
	for _, p in model:GetChildren() do
		if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
			if color then
				if p:GetAttribute("CostumeColor") == nil then
					p:SetAttribute("CostumeColor", p.Color)
				end
				p.Color = color
			elseif p:GetAttribute("CostumeColor") ~= nil then
				p.Color = p:GetAttribute("CostumeColor")
				p:SetAttribute("CostumeColor", nil)
			end
		end
	end
	local bc = model:FindFirstChildOfClass("BodyColors")
	if bc then
		for _, prop in BODY_PARTS do
			local key, orig = prop .. "Color3", "Orig" .. prop
			if color and bc:GetAttribute(orig) == nil then
				bc:SetAttribute(orig, bc[key])
			end
			local value = color or bc:GetAttribute(orig)
			if value then
				bc[key] = value
			end
			if not color then
				bc:SetAttribute(orig, nil)
			end
		end
	end
end

-- After the avatar (re)applies its look, a painted part that no longer shows our colour shows the
-- avatar's: that is the original to restore later (whichever order spawn and appearance ran in).
local function refreshOriginals(model: Model, color: Color3)
	local bc = model:FindFirstChildOfClass("BodyColors")
	if bc then
		for _, prop in BODY_PARTS do
			if bc[prop .. "Color3"] ~= color then
				bc:SetAttribute("Orig" .. prop, bc[prop .. "Color3"])
			end
		end
	end
	for _, p in model:GetChildren() do
		if p:IsA("BasePart") and p:GetAttribute("CostumeColor") ~= nil and p.Color ~= color then
			p:SetAttribute("CostumeColor", p.Color)
		end
	end
end

local function remove(model: Model, slot: string)
	local old = model:FindFirstChild("Costume_" .. slot)
	if old then
		old:Destroy()
	end
	if slot == "head" then
		hideHats(model, false)
	elseif slot == "body" then
		paint(model, nil)
	end
end

-- Put costume `id` on a character or mannequin (replaces whatever it wore in that slot).
local function wear(model: Model, id: string): Model?
	local def = BY_ID[id]
	local r = def and rigOf(model)
	if not r then
		return nil
	end
	remove(model, def.slot)
	local holder = Instance.new("Model")
	holder.Name = "Costume_" .. def.slot
	holder:SetAttribute("Costume", id)
	holder:SetAttribute("Slot", def.slot)
	if def.build then
		def.build(r, newAdder(holder))
	end
	if def.paint then
		paint(model, def.paint)
	end
	if def.slot == "head" then
		hideHats(model, true)
	end
	holder.Parent = model
	CollectionService:AddTag(holder, "Costume")
	return holder
end
Cosmetics.wear = wear

-- ------------------------------------------------------------------ players

local cfg = { currency = "Coins" }
local sold, soldList, started = {}, {}, false
local profiles, memory, lastAsk = {}, {}, {}
local store = nil
local remotes = nil

local function count(name: string)
	local t = ReplicatedStorage:FindFirstChild("ForgeTelemetry")
	if t and t:IsA("ModuleScript") then
		pcall(function()
			require(t).count(name, 1)
		end)
	end
end

local function balance(player: Player): number
	if cfg.balance then
		return tonumber(cfg.balance(player)) or 0
	end
	local ls = player:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild(cfg.currency)
	if v and v:IsA("ValueBase") then
		return tonumber((v :: any).Value) or 0
	end
	return tonumber(player:GetAttribute(cfg.currency)) or 0
end

local function spend(player: Player, amount: number): boolean
	if cfg.spend then
		return cfg.spend(player, amount) == true
	end
	local have = balance(player)
	if have < amount then
		return false
	end
	local ls = player:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild(cfg.currency)
	if v and v:IsA("ValueBase") then
		(v :: any).Value = have - amount
	else
		player:SetAttribute(cfg.currency, have - amount)
	end
	return true
end

local function stateOf(player: Player)
	local p = profiles[player]
	local owned = {}
	for id in (p and p.owned or {}) do
		table.insert(owned, id)
	end
	return { currency = cfg.currency, balance = balance(player), owned = owned,
		equipped = p and p.equipped or {}, costumes = soldList, loading = p == nil }
end

local function push(player: Player)
	local p = profiles[player]
	if p then
		local n = 0
		for _ in p.owned do
			n += 1
		end
		player:SetAttribute("CostumesOwned", n)
		for slot, attr in SLOTS do
			player:SetAttribute(attr, p.equipped[slot])
		end
	end
	if remotes then
		remotes.State:FireClient(player, stateOf(player))
	end
end

local function load(player: Player)
	local data = nil
	if store then
		local ok, res = pcall(store.GetAsync, store, "u" .. player.UserId)
		if ok then
			data = res
		else
			warn("[Cosmetics] DataStore unavailable, keeping costumes in memory:", res)
			store = nil
		end
	end
	data = data or memory[player.UserId]
	local p = { owned = {}, equipped = {}, dirty = false }
	for _, id in (data and data.owned or {}) do
		if sold[id] then
			p.owned[id] = true
		end
	end
	for _, def in soldList do
		if def.price == 0 and not def.reward then
			p.owned[def.id] = true
		end
	end
	for slot, id in (data and data.equipped or {}) do
		if p.owned[id] and sold[id].slot == slot then
			p.equipped[slot] = id
		end
	end
	local auto = cfg.autoEquip and sold[cfg.autoEquip]
	if not data and auto and p.owned[auto.id] then
		p.equipped[auto.slot] = auto.id
	end
	if player.Parent then
		profiles[player] = p
	end
end

local function save(player: Player)
	local p = profiles[player]
	if not (p and p.dirty) then
		return
	end
	p.dirty = false
	local owned = {}
	for id in p.owned do
		table.insert(owned, id)
	end
	local data = { owned = owned, equipped = table.clone(p.equipped) }
	memory[player.UserId] = data
	if store then
		local ok, err = pcall(store.SetAsync, store, "u" .. player.UserId, data)
		if not ok then
			p.dirty = true
			warn("[Cosmetics] save failed for", player.Name, err)
		end
	end
end

local function dress(player: Player, char: Model, appearanceLoaded: boolean?)
	char:WaitForChild("Head", 10)
	local p = profiles[player]
	if not p or player.Character ~= char then
		return
	end
	local body = p.equipped.body and BY_ID[p.equipped.body]
	if appearanceLoaded and body then
		refreshOriginals(char, body.paint)
	end
	for _, id in p.equipped do
		wear(char, id)
	end
end

local function unknown(id: any): string?
	if typeof(id) ~= "string" or not sold[id] then
		return "Unknown costume"
	end
	return nil
end

function Cosmetics.equip(player: Player, id: string): (boolean, string?)
	local bad = unknown(id)
	local p = profiles[player]
	if bad or not p then
		return false, bad or "Still loading"
	end
	if not p.owned[id] then
		return false, "Buy it first"
	end
	p.equipped[sold[id].slot] = id
	p.dirty = true
	if player.Character then
		wear(player.Character, id)
	end
	count("costume_equip")
	push(player)
	return true
end

function Cosmetics.unequip(player: Player, idOrSlot: string): (boolean, string?)
	local slot = if SLOTS[idOrSlot] then idOrSlot else (sold[idOrSlot] and sold[idOrSlot].slot)
	local p = profiles[player]
	if not slot or not p then
		return false, if p then "Unknown costume" else "Still loading"
	end
	p.equipped[slot] = nil
	p.dirty = true
	if player.Character then
		remove(player.Character, slot)
	end
	push(player)
	return true
end

function Cosmetics.buy(player: Player, id: string): (boolean, string?)
	local bad = unknown(id)
	local p = profiles[player]
	if bad or not p then
		return false, bad or "Still loading"
	end
	if p.owned[id] then
		return Cosmetics.equip(player, id)
	end
	local def = sold[id]
	if def.reward then
		return false, "Earn it to unlock"
	end
	if not spend(player, def.price) then
		return false, "Need " .. def.price .. " " .. cfg.currency
	end
	p.owned[id] = true
	p.dirty = true
	count("costume_buy")
	return Cosmetics.equip(player, id)
end

-- Give a costume for free (rewards, codes, badges).
function Cosmetics.grant(player: Player, id: string): (boolean, string?)
	local bad = unknown(id)
	local p = profiles[player]
	if bad or not p then
		return false, bad or "Still loading"
	end
	p.owned[id] = true
	p.dirty = true
	push(player)
	return true
end

function Cosmetics.owns(player: Player, id: string): boolean
	local p = profiles[player]
	return p ~= nil and p.owned[id] == true
end

function Cosmetics.equipped(player: Player): { [string]: string }
	local p = profiles[player]
	return if p then table.clone(p.equipped) else {}
end

-- config: currency (leaderstat or player attribute, "Coins"), costumes {ids in panel order, default all},
-- prices {[id] = n} (0 = free), rewards {ids not for sale}, autoEquip (id worn on first join),
-- store (DataStore name), balance(player) -> number and spend(player, n) -> bool for a custom economy.
function Cosmetics.start(config: { [string]: any }?)
	assert(RunService:IsServer(), "Cosmetics.start runs on the server; use CosmeticsClient on the client")
	if started then
		return Cosmetics
	end
	started = true
	config = config or {}
	cfg = config
	cfg.currency = config.currency or "Coins"
	local rewards = {}
	for _, id in config.rewards or {} do
		rewards[id] = true
	end
	local ids = config.costumes
	if not ids then
		ids = {}
		for _, def in CATALOG do
			table.insert(ids, def.id)
		end
	end
	for _, id in ids do
		local def = BY_ID[id]
		if def and not sold[id] then
			local price = (config.prices or {})[id]
			local entry = { id = id, name = def.name, slot = def.slot, icon = def.icon, color = def.color,
				price = if price ~= nil then price else def.price, reward = rewards[id] or def.reward == true }
			sold[id] = entry
			table.insert(soldList, entry)
		elseif not def then
			warn("[Cosmetics] unknown costume id in config:", id)
		end
	end
	if game.PlaceId ~= 0 then -- an unpublished Studio place has no DataStores: memory only
		local ok, ds = pcall(DataStoreService.GetDataStore, DataStoreService, config.store or "ForgeCosmetics")
		store = if ok then ds else nil
	end

	local folder = Instance.new("Folder")
	folder.Name = "CosmeticsRemotes"
	local request = Instance.new("RemoteFunction")
	request.Name = "Request"
	request.Parent = folder
	local stateEv = Instance.new("RemoteEvent")
	stateEv.Name = "State"
	stateEv.Parent = folder
	local openEv = Instance.new("RemoteEvent")
	openEv.Name = "Open"
	openEv.Parent = folder
	folder.Parent = ReplicatedStorage
	remotes = { State = stateEv, Open = openEv }

	request.OnServerInvoke = function(player: Player, action: any, id: any)
		local now = os.clock()
		if action ~= "state" and now - (lastAsk[player] or 0) < 0.15 then
			return { ok = false, err = "Slow down", state = stateOf(player) }
		end
		lastAsk[player] = now
		local okay, err = true, nil
		if action == "buy" then
			okay, err = Cosmetics.buy(player, id)
		elseif action == "equip" then
			okay, err = Cosmetics.equip(player, id)
		elseif action == "unequip" then
			okay, err = Cosmetics.unequip(player, id)
		elseif action ~= "state" then
			okay, err = false, "Unknown action"
		end
		return { ok = okay, err = err, state = stateOf(player) }
	end

	local function join(player: Player)
		load(player)
		player.CharacterAdded:Connect(function(char)
			dress(player, char)
		end)
		player.CharacterAppearanceLoaded:Connect(function(char)
			dress(player, char, true) -- the avatar can swap the head and recolour the body after spawn
		end)
		if player.Character then
			task.spawn(dress, player, player.Character)
		end
		push(player)
	end
	Players.PlayerAdded:Connect(join)
	for _, player in Players:GetPlayers() do
		task.spawn(join, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		save(player)
		profiles[player], lastAsk[player] = nil, nil
	end)
	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			save(player)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(30)
			for player in profiles do
				task.spawn(save, player)
			end
		end
	end)
	return Cosmetics
end

-- ------------------------------------------------------------------ changing room

local function mannequin(at: CFrame, parent: Instance): Model
	local m = Instance.new("Model")
	m.Name = "Mannequin"
	m:SetAttribute("Mannequin", true)
	local function limb(name: string, offset: Vector3, size: Vector3)
		local p = Instance.new("Part")
		p.Name, p.Size, p.CFrame = name, size, at * CFrame.new(offset)
		p.Anchored, p.CanCollide, p.Color, p.Material = true, false, C.Cream, Enum.Material.SmoothPlastic
		p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
		p.Parent = m
		return p
	end
	limb("LeftLeg", Vector3.new(-0.5, 1, 0), Vector3.new(1, 2, 1))
	limb("RightLeg", Vector3.new(0.5, 1, 0), Vector3.new(1, 2, 1))
	limb("Torso", Vector3.new(0, 3, 0), Vector3.new(2, 2, 1))
	limb("LeftArm", Vector3.new(-1.5, 3, 0), Vector3.new(1, 2, 1))
	limb("RightArm", Vector3.new(1.5, 3, 0), Vector3.new(1, 2, 1))
	local head = limb("Head", Vector3.new(0, 4.6, 0), Vector3.new(1.2, 1.2, 1.2))
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Head
	mesh.Scale = Vector3.new(1, 1, 1)
	mesh.Parent = head
	m.PrimaryPart = m.Torso
	m.Parent = parent
	return m
end

local function label(parent: Instance, text: string, color: Color3, y: number)
	local bb = Instance.new("BillboardGui")
	bb.Size, bb.StudsOffset, bb.AlwaysOnTop, bb.MaxDistance = UDim2.fromScale(6, 1.5), Vector3.new(0, y, 0), false, 70
	local t = Instance.new("TextLabel")
	t.Size, t.BackgroundTransparency, t.Text, t.TextScaled = UDim2.fromScale(1, 1), 1, text, true
	t.Font, t.TextColor3 = Enum.Font.LuckiestGuy, color
	local s = Instance.new("UIStroke")
	s.Thickness, s.Color = 3, C.Ink
	s.Parent = t
	t.Parent = bb
	bb.Parent = parent
	return bb
end

-- Builds mannequin stands on a ring around `cframe` (floor centre; the open side faces its LookVector).
-- opts: cframe, ids (default: every costume this game sells), parent (workspace), title ("CHANGING ROOM").
-- Each stand: tag "CostumeStand", attributes Costume / Price / Slot, a ProximityPrompt "Try on".
function Cosmetics.buildChangingRoom(opts: { [string]: any }?): Model
	assert(started, "call Cosmetics.start(config) before buildChangingRoom")
	opts = opts or {}
	local origin = opts.cframe or CFrame.new(0, 0, 0)
	local ids = opts.ids
	if not ids then
		ids = {}
		for _, def in soldList do
			table.insert(ids, def.id)
		end
	end
	local room = Instance.new("Model")
	room.Name = "ChangingRoom"
	CollectionService:AddTag(room, "ChangingRoom")
	local n = #ids
	local radius = math.max(9, n * 4.2 / math.rad(280))
	local floor = Instance.new("Part")
	floor.Name, floor.Shape, floor.Anchored = "Floor", CYL, true
	floor.Size = Vector3.new(0.6, radius * 2 + 9, radius * 2 + 9)
	floor.CFrame, floor.Color, floor.Material = origin * CFrame.new(0, 0.3, 0) * UP, C.Purple, Enum.Material.SmoothPlastic
	floor.Parent = room
	local sign = Instance.new("Part")
	sign.Name, sign.Anchored, sign.CanCollide, sign.Transparency = "Sign", true, false, 1
	sign.Size, sign.CFrame = Vector3.new(1, 1, 1), origin * CFrame.new(0, 11, 0)
	sign.Parent = room
	label(sign, opts.title or "👕 CHANGING ROOM", C.Yellow, 0).Size = UDim2.fromScale(22, 4)
	local orbs = {}
	for i, id in ids do
		local def = sold[id]
		if def then
			local a = math.rad(-140 + (i - 0.5) * 280 / n)
			local pos = (origin * CFrame.new(math.sin(a) * radius, 0, math.cos(a) * radius)).Position
			local face = CFrame.lookAt(pos, origin.Position * Vector3.new(1, 0, 1) + Vector3.new(0, pos.Y, 0))
			local stand = Instance.new("Model")
			stand.Name = "Stand_" .. id
			local base = Instance.new("Part")
			base.Name, base.Shape, base.Anchored = "Base", CYL, true
			base.Size, base.CFrame = Vector3.new(1, 3.6, 3.6), face * CFrame.new(0, 1.1, 0) * UP
			base.Color, base.Material = RAINBOW[(i - 1) % #RAINBOW + 1], Enum.Material.SmoothPlastic
			base.Parent = stand
			local m = mannequin(face * CFrame.new(0, 1.6, 0), stand)
			wear(m, id)
			if def.slot == "trail" then
				local orb = Instance.new("Part")
				orb.Name, orb.Shape, orb.Anchored, orb.CanCollide = "TrailOrb", BALL, true, false
				orb.Size, orb.Color, orb.Material = Vector3.one * 0.6, def.color, Enum.Material.Neon
				orb.Parent = stand
				local fx = m:FindFirstChild("Costume_trail")
				local holder = fx and fx:FindFirstChildWhichIsA("BasePart")
				if holder then -- the trail circles the stand so it shows while standing still
					holder:FindFirstChildOfClass("WeldConstraint"):Destroy()
					holder.Anchored = true
					holder.Parent = orb
				end
				table.insert(orbs, { orb = orb, holder = holder, centre = face * CFrame.new(0, 4, 0), phase = i })
			end
			local price = if def.reward then "🏆 REWARD" elseif def.price == 0 then "FREE" else def.price .. " " .. cfg.currency
			label(m.Head, def.name .. "\n" .. price, C.Cream, 2.6)
			local prompt = Instance.new("ProximityPrompt")
			prompt.ActionText, prompt.ObjectText = "Try on", def.name
			prompt.HoldDuration, prompt.MaxActivationDistance, prompt.RequiresLineOfSight = 0, 10, false
			prompt.Parent = base
			prompt.Triggered:Connect(function(player)
				if Cosmetics.owns(player, id) then
					Cosmetics.equip(player, id)
				end
				remotes.Open:FireClient(player, id)
			end)
			stand:SetAttribute("Costume", id)
			stand:SetAttribute("Price", def.price)
			stand:SetAttribute("Slot", def.slot)
			CollectionService:AddTag(stand, "CostumeStand")
			stand.Parent = room
		end
	end
	room.Parent = opts.parent or workspace
	if #orbs > 0 then
		local conn
		conn = RunService.Heartbeat:Connect(function()
			if not room.Parent then
				conn:Disconnect()
				return
			end
			local t = os.clock() * 2.2
			for _, o in orbs do
				local cf = o.centre * CFrame.Angles(0, t + o.phase, 0) * CFrame.new(2.4, math.sin(t * 2) * 0.4, 0)
				o.orb.CFrame = cf
				if o.holder then
					o.holder.CFrame = cf
				end
			end
		end)
	end
	return room
end

return Cosmetics
