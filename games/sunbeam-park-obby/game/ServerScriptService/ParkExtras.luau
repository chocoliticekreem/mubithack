--!nonstrict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry"))
local GameAssets = require(ReplicatedStorage:WaitForChild("GameAssets"))
local Kit = ReplicatedStorage:WaitForChild("Kit")
local ObbyKit = require(Kit:WaitForChild("ObbyKit"))
local Cosmetics = require(Kit:WaitForChild("Cosmetics"))

local ParkExtras = {}

local GIFT = Config.Gift or {}
local INTERVAL = (type(GIFT.interval) == "number" and GIFT.interval > 0) and GIFT.interval or 180
local BASE = type(GIFT.base) == "number" and GIFT.base or 20
local FIRST_GIFT_DELAY = math.min(INTERVAL, 30)
local ZONE_SIZE = 10
local MASTERY_COUNT = 8
local HAT_PRICE = 15

local C1 = Color3.fromRGB(255, 94, 126)
local C2 = Color3.fromRGB(255, 196, 41)
local C3 = Color3.fromRGB(79, 195, 247)
local C4 = Color3.fromRGB(123, 224, 90)
local C5 = Color3.fromRGB(177, 108, 255)
local C6 = Color3.fromRGB(255, 154, 60)
local PALETTE = { C1, C2, C3, C4, C5, C6 }

local ACHIEVEMENTS = {
	first_costume = "First Costume!",
	zone1 = "Zone 1 Cleared!",
	coins10 = "10 Coins!",
	coins50 = "50 Coins!",
	halfway = "Halfway There: Stage 50!",
	mastery = "Costume Mastery!",
	finished = "Park Champion!",
}

local EQUIP_ATTRS = { "CostumeHead", "CostumeBack", "CostumeTrail", "CostumeBody" }

local states = {}
local remotes = nil
local started = false
local cachedStand = nil

local function count(name, n)
	pcall(function() Telemetry.count(name, n or 1) end)
end

-- logical remote name -> actual instance name (from Config.Remotes, with fallbacks)
local function actualName(logical)
	local r = Config.Remotes
	if type(r) == "table" then
		local v = r[logical]
		if type(v) == "string" and v ~= "" then return v end
	end
	return logical
end

local GIFT_REMOTES = { ClaimGift = true, GiftState = true }

local function findRemote(logical)
	local name = actualName(logical)
	local r = ReplicatedStorage:FindFirstChild(name)
	if r and (r:IsA("RemoteEvent") or r:IsA("RemoteFunction")) then return r end
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder then
		r = folder:FindFirstChild(name)
		if r and (r:IsA("RemoteEvent") or r:IsA("RemoteFunction")) then return r end
	end
	return nil
end

local function getRemote(logical)
	local existing = findRemote(logical)
	if existing then return existing end
	local parent = ReplicatedStorage
	if not GIFT_REMOTES[logical] then
		local folder = ReplicatedStorage:FindFirstChild("Remotes")
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = "Remotes"
			folder.Parent = ReplicatedStorage
		end
		parent = folder
	end
	local r = Instance.new("RemoteEvent")
	r.Name = actualName(logical)
	r.Parent = parent
	return r
end

local function ensureRemotes()
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	-- gift remotes first, directly under ReplicatedStorage
	getRemote("GiftState")
	getRemote("ClaimGift")
	for _, logical in ipairs({ "ParkToast", "ParkPopup", "ParkShake" }) do
		getRemote(logical)
	end
	if type(Config.Remotes) == "table" then
		local giftNames = { [actualName("GiftState")] = true, [actualName("ClaimGift")] = true }
		for k, v in pairs(Config.Remotes) do
			local n = type(v) == "string" and v or (type(k) == "string" and k or nil)
			if n and not giftNames[n] and not findRemote(n) then
				local r = Instance.new("RemoteEvent")
				r.Name = n
				r.Parent = folder
			end
		end
	end
	return folder
end

-- create remotes at module load, before anything else
do
	local ok, err = pcall(function() remotes = ensureRemotes() end)
	if not ok then warn("ParkExtras: ensureRemotes failed: " .. tostring(err)) end
end

local function fire(player, name, ...)
	local r = getRemote(name)
	if r and r:IsA("RemoteEvent") and player.Parent == Players then
		r:FireClient(player, ...)
	else
		warn("ParkExtras: cannot fire " .. tostring(name))
	end
end

local function rootOf(player)
	local ch = player.Character
	return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function sfx(player, name)
	pcall(function() GameAssets.play(name, rootOf(player)) end)
end

local function burstAt(target, color, n)
	if target == nil then return end
	pcall(function() GameAssets.burst(target, color, n) end)
end

local function toast(player, text, sound)
	fire(player, "ParkToast", text, sound)
	if sound then sfx(player, sound) end
end

local function coinsValue(player)
	local ls = player:FindFirstChild("leaderstats")
	local c = ls and ls:FindFirstChild("Coins")
	if c and (c:IsA("IntValue") or c:IsA("NumberValue")) then return c end
	return nil
end

local function addCoins(player, n)
	local c = coinsValue(player)
	if c then c.Value += n return true end
	return false
end

local function costumeId(entry)
	if type(entry) == "table" then
		return entry.id or entry.Id or entry.name or entry.Name
	end
	return entry
end

local function ownedCount(player)
	local owned = 0
	local list = Config.Costumes
	if type(list) ~= "table" then return 0 end
	for k, entry in pairs(list) do
		local id = costumeId(entry)
		if type(entry) ~= "table" and type(k) == "string" and type(entry) ~= "string" then id = k end
		if id ~= nil then
			local ok, has = pcall(function() return Cosmetics.owns(player, id) end)
			if ok and has then owned += 1 end
		end
	end
	return owned
end

-- find the hat stand: tagged stand with price 15, then any tagged stand, then a workspace scan
local function hatStand()
	if cachedStand and cachedStand.Parent then return cachedStand end
	local tagged = CollectionService:GetTagged("CostumeStand")
	for _, p in ipairs(tagged) do
		if p:GetAttribute("Price") == HAT_PRICE then cachedStand = p return p end
	end
	for _, p in ipairs(tagged) do
		local id = tostring(p:GetAttribute("Costume") or p.Name):lower()
		if id:find("hat") then cachedStand = p return p end
	end
	if tagged[1] then cachedStand = tagged[1] return tagged[1] end
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("BasePart") and (d:GetAttribute("Price") == HAT_PRICE or d.Name:lower():find("hatstand")) then
			cachedStand = d
			return d
		end
	end
	return nil
end

local function stopGuide(st)
	st.guiding = false
	if st.highlight then
		pcall(function() st.highlight:Destroy() end)
		st.highlight = nil
	end
end

local function startGuide(player, st)
	if st.guiding or st.bought then return end
	local stand = hatStand()
	if not stand then return end
	st.guiding = true
	local ok, hl = pcall(function()
		local h = Instance.new("Highlight")
		h.Name = "HatGuide"
		h.Adornee = stand
		h.FillColor = C2
		h.OutlineColor = Color3.new(1, 1, 1)
		h.FillTransparency = 0.6
		h.Parent = stand
		return h
	end)
	if ok then st.highlight = hl end
	task.spawn(function()
		while st.guiding and not st.bought and player.Parent == Players and states[player] == st do
			burstAt(stand, C2, 30)
			task.wait(3)
		end
		stopGuide(st)
	end)
end

function ParkExtras.unlock(player, id)
	local st = states[player]
	if not st or not ACHIEVEMENTS[id] or st.unlocked[id] then return false end
	st.unlocked[id] = true
	count("achievement_unlocked", 1)
	if id == "halfway" then
		toast(player, "Achievement: " .. ACHIEVEMENTS[id], "Win")
		fire(player, "ParkToast", "Halfway there! Stage 50/100", nil)
		burstAt(rootOf(player), C2, 30)
	else
		toast(player, "Achievement: " .. ACHIEVEMENTS[id], "Gem")
	end
	return true
end

local function sendGift(player)
	local st = states[player]
	if not st then return end
	local left = math.max(0, math.ceil(st.readyAt - os.clock()))
	fire(player, "GiftState", st.ready, left, st.streak)
end

function ParkExtras.claimGift(player)
	local st = states[player]
	if not st or not st.ready or os.clock() < st.readyAt then return false end
	local late = os.clock() - st.readyAt
	if st.streak > 0 and late > INTERVAL * 2 then st.streak = 0 end
	st.streak += 1
	local amount = BASE + math.min(st.streak * 10, 50)
	st.ready = false
	st.readyAt = os.clock() + INTERVAL
	addCoins(player, amount)
	count("gift_claimed", 1)
	fire(player, "ParkPopup", string.format("+%d coins, streak x%d", amount, st.streak), "Gift")
	sfx(player, "Gem")
	local root = rootOf(player)
	if root then burstAt(root, Color3.fromRGB(255, 205, 40), 24) end
	sendGift(player)
	return true
end

local function checkMastery(player)
	if ownedCount(player) >= MASTERY_COUNT then ParkExtras.unlock(player, "mastery") end
end

-- big payoff the first time a costume is bought
local function onFirstBought(player, st)
	stopGuide(st)
	ParkExtras.unlock(player, "first_costume")
	sfx(player, "Buy")
	task.delay(0.3, function()
		if player.Parent == Players then sfx(player, "Pop") end
	end)
	local ch = player.Character
	local head = ch and ch:FindFirstChild("Head")
	burstAt(head or rootOf(player), C5, 30)
	local stand = hatStand()
	if stand then burstAt(stand, C2, 30) end
	fire(player, "ParkPopup", "Party Hat unlocked!", "Buy")
	fire(player, "ParkShake", 0.3, 0.25)
end

-- counted inside the purchase paths; deduped between wrapper, attribute listeners and poll
local function noteBuy(player)
	local st = states[player]
	if not st then return end
	local n = ownedCount(player)
	if n > st.ownedSeen then
		local diff = n - st.ownedSeen
		st.ownedSeen = n
		st.buys += diff
		count("costume_buy", diff)
		if not st.bought then
			st.bought = true
			onFirstBought(player, st)
		end
		checkMastery(player)
	end
end

local function noteEquip(player, key)
	local st = states[player]
	if not st then return end
	local v = key and player:GetAttribute(key) or nil
	if key then
		if v == nil or v == "" or v == false then
			st.equipSeen[key] = nil
			return
		end
		if st.equipSeen[key] == v then return end
		st.equipSeen[key] = v
	end
	st.equips += 1
	count("costume_equip", 1)
end

local function checkCoins(player)
	local c = coinsValue(player)
	if not c then return end
	if c.Value >= 10 then ParkExtras.unlock(player, "coins10") end
	if c.Value >= 50 then ParkExtras.unlock(player, "coins50") end
	local st = states[player]
	if st and not st.hatHinted and not st.bought and c.Value >= HAT_PRICE then
		st.hatHinted = true
		toast(player, "Walk into the booth to buy your Party Hat!", "Gem")
		startGuide(player, st)
	end
end

local function zoneName(zone)
	local name
	pcall(function()
		local z = Config.Zones
		if type(z) == "table" and type(z[zone]) == "table" then
			name = z[zone].name or z[zone].Name
		elseif type(z) == "table" and type(z[zone]) == "string" then
			name = z[zone]
		end
	end)
	if type(name) ~= "string" or name == "" then name = "Zone " .. tostring(zone) end
	return name
end

local function onStage(player, stage)
	local st = states[player]
	if not st or type(stage) ~= "number" then return end
	st.lastStage = stage
	if stage >= ZONE_SIZE * 5 then ParkExtras.unlock(player, "halfway") end

	if stage > 0 and stage % 5 == 0 and not st.milestones[stage] then
		st.milestones[stage] = true
		addCoins(player, 10)
		toast(player, string.format("Stage %d! +10 coins", stage), "Coin")
		burstAt(rootOf(player), C2, 20)
	end

	if stage > 0 and stage % ZONE_SIZE == 0 then
		local zone = stage // ZONE_SIZE
		if not st.zones[zone] then
			st.zones[zone] = true
			local bonus = 50 * zone
			addCoins(player, bonus)
			count("zone_cleared", 1)
			local zname = zoneName(zone)
			toast(player, string.format("Zone %d cleared! +%d coins", zone, bonus), "Win")
			fire(player, "ParkPopup", zname .. " cleared! +" .. bonus, "Win")
			fire(player, "ParkShake", 0.6, 0.4)
			task.delay(0.4, function()
				if player.Parent == Players then sfx(player, "Boom") end
			end)
			for i = 1, 5 do
				task.delay(0.15 * (i - 1), function()
					local root = rootOf(player)
					if root then
						local off = Vector3.new(math.random(-10, 10), math.random(20, 30), math.random(-10, 10))
						burstAt(root.Position + off, PALETTE[math.random(1, #PALETTE)], 40)
					end
				end)
			end
			if zone == 1 then ParkExtras.unlock(player, "zone1") end
		end
	end
end

local function fmtTime(s)
	s = math.floor(s)
	return string.format("%d:%02d", s // 60, s % 60)
end

local function onFinish(player)
	local st = states[player]
	if not st then return end
	if not st.finished then
		st.finished = true
		count("park_finished", 1)
		pcall(function()
			if Config.FinishReward then Cosmetics.grant(player, Config.FinishReward) end
		end)
		local owned = ownedCount(player)
		fire(player, "ParkPopup", string.format("Park Champion! Time %s - %d/%d costumes",
			fmtTime(os.clock() - st.joined), owned, MASTERY_COUNT), "Win")
		fire(player, "ParkShake", 1.2, 0.8)
		sfx(player, "Boom")
		task.delay(0.4, function() sfx(player, "Win") end)
		task.spawn(function()
			for i = 1, 12 do
				if player.Parent ~= Players then break end
				local root = rootOf(player)
				if root then
					local off = Vector3.new(math.random(-12, 12), math.random(10, 25), math.random(-12, 12))
					burstAt(root.Position + off, PALETTE[math.random(1, #PALETTE)], 40)
				end
				task.wait(0.25)
			end
		end)
		ParkExtras.unlock(player, "finished")
	end
end

local function onDied(player)
	local st = states[player]
	if not st then return end
	local now = os.clock()
	if now - (st.lastDeath or 0) < 1 then return end
	st.lastDeath = now
	fire(player, "ParkShake", 0.5, 0.3)
	toast(player, "Oops! Back to Stage " .. tostring(st.lastStage or 1), nil)
end

local function standInfo(id)
	for _, p in ipairs(CollectionService:GetTagged("CostumeStand")) do
		if p:GetAttribute("Costume") == id then return p:GetAttribute("Price") end
	end
	return nil
end

local function setupPlayer(player)
	if states[player] then return end
	local st = {
		ready = false, readyAt = os.clock() + FIRST_GIFT_DELAY, streak = 0,
		unlocked = {}, zones = {}, milestones = {}, joined = os.clock(), lastSend = 0,
		hatHinted = false, bought = false, guiding = false, highlight = nil,
		ownedSeen = 0, buys = 0, equips = 0, equipSeen = {}, lastClaim = 0,
		lastStage = 1, lastDeath = 0,
	}
	states[player] = st
	st.ownedSeen = ownedCount(player)
	sendGift(player)
	task.delay(1, function()
		if states[player] == st then sendGift(player) end
	end)
	task.delay(1.5, function()
		if states[player] == st then
			toast(player, "Grab the coins, then buy a hat in the changing room!", nil)
		end
	end)

	task.spawn(function()
		local ls = player:WaitForChild("leaderstats", 30)
		local c = ls and ls:WaitForChild("Coins", 30)
		if c and states[player] == st then
			checkCoins(player)
			c.Changed:Connect(function() checkCoins(player) end)
		end
	end)

	player:GetAttributeChangedSignal("CostumesOwned"):Connect(function() noteBuy(player) end)
	for _, attr in ipairs(EQUIP_ATTRS) do
		player:GetAttributeChangedSignal(attr):Connect(function()
			noteBuy(player)
			noteEquip(player, attr)
		end)
	end
	player:GetAttributeChangedSignal("RideNotice"):Connect(function()
		local msg = player:GetAttribute("RideNotice")
		if type(msg) == "string" and msg ~= "" then toast(player, msg, "Error") end
	end)
end

function ParkExtras.init(kitHandles)
	if started then return end
	started = true
	remotes = ensureRemotes()
	local kit = (type(kitHandles) == "table" and kitHandles.ObbyKit) or ObbyKit

	local claim = getRemote("ClaimGift")
	local function handleClaim(player)
		local st = states[player]
		if not st then return end
		local now = os.clock()
		if now - st.lastClaim < 0.5 then return end
		st.lastClaim = now
		ParkExtras.claimGift(player)
		task.delay(1, function()
			if states[player] == st then sendGift(player) end
		end)
	end
	if claim then
		if claim:IsA("RemoteEvent") then
			claim.OnServerEvent:Connect(handleClaim)
		elseif claim:IsA("RemoteFunction") then
			claim.OnServerInvoke = function(player)
				handleClaim(player)
				return true
			end
		end
	end

	pcall(function() kit.onStage(onStage) end)
	pcall(function() kit.onFinish(onFinish) end)
	pcall(function()
		if type(kit.onDeath) == "function" then kit.onDeath(onDied) end
	end)
	pcall(function()
		if type(kit.onFall) == "function" then kit.onFall(onDied) end
	end)

	local origBuy = Cosmetics.buy
	if type(origBuy) == "function" then
		Cosmetics.buy = function(player, id, ...)
			local st = typeof(player) == "Instance" and states[player] or nil
			local before = st and st.buys or 0
			local ok, err = origBuy(player, id, ...)
			if ok and st then
				noteBuy(player)
				if st.buys == before then
					-- ownership could not be read; still count the purchase once
					st.buys += 1
					st.ownedSeen += 1
					count("costume_buy", 1)
					if not st.bought then
						st.bought = true
						onFirstBought(player, st)
					end
				end
				checkMastery(player)
			elseif not ok and typeof(player) == "Instance" then
				local price = standInfo(id)
				local c = coinsValue(player)
				if type(price) == "number" and c and c.Value < price then
					toast(player, string.format("Need %d more coins", price - c.Value), "Error")
				else
					toast(player, type(err) == "string" and err or "Can't buy that yet", "Error")
				end
			end
			return ok, err
		end
	end

	for _, fname in ipairs({ "equip", "wear" }) do
		local orig = Cosmetics[fname]
		if type(orig) == "function" then
			Cosmetics[fname] = function(player, ...)
				local st = typeof(player) == "Instance" and states[player] or nil
				local before = st and st.equips or 0
				local res = table.pack(orig(player, ...))
				if st and res[1] ~= false and res[1] ~= nil and st.equips == before then
					st.equips += 1
					count("costume_equip", 1)
				end
				return table.unpack(res, 1, res.n)
			end
		end
	end

	Players.PlayerAdded:Connect(setupPlayer)
	for _, p in ipairs(Players:GetPlayers()) do setupPlayer(p) end
	Players.PlayerRemoving:Connect(function(p)
		local st = states[p]
		if st then stopGuide(st) end
		states[p] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			local now = os.clock()
			for player, st in pairs(states) do
				if not st.ready and now >= st.readyAt then
					st.ready = true
					count("gift_ready", 1)
					sendGift(player)
					toast(player, "Your free gift is ready!", "Gem")
				elseif not st.ready and now - st.lastSend >= 5 then
					st.lastSend = now
					sendGift(player)
				end
				-- safety net for purchases made through paths that bypass the wrapper
				noteBuy(player)
			end
		end
	end)
end

function ParkExtras.selfTest()
	if not started then ParkExtras.init() end
	local player = Players:GetPlayers()[1]
	if not player then return end
	setupPlayer(player)
	local st = states[player]
	if not st then return end
	local function step(f) local ok, e = pcall(f) if not ok then warn("ParkExtras.selfTest: " .. tostring(e)) end end
	step(function()
		if not st.ready then
			st.readyAt = os.clock() - 1
			st.ready = true
			count("gift_ready", 1)
		end
		ParkExtras.claimGift(player)
	end)
	step(function() ParkExtras.unlock(player, "first_costume") end)
	step(function()
		count("costume_buy", 1)
		count("costume_equip", 1)
	end)
	step(function() count("zone_cleared", 1) end)
	step(function() count("player_fell", 1) end)
	step(function() count("trampoline_bounce", 1) end)
end

-- self-start if nobody called init() shortly after load, so state and remotes are always live
task.delay(1, function()
	if not started then
		local ok, err = pcall(function() ParkExtras.init() end)
		if not ok then warn("ParkExtras: auto-init failed: " .. tostring(err)) end
	end
end)

return ParkExtras
