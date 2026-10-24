-- CashInConfig: pure shared tunables for cash-in and purchase feedback.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CashInConfig = {}

local function normalizeId(value: any): string?
	if type(value) == "number" and value > 0 then
		return "rbxassetid://" .. tostring(math.floor(value))
	elseif type(value) == "string" and value ~= "" then
		if string.match(value, "^%d+$") then
			return "rbxassetid://" .. value
		end
		return value
	elseif typeof(value) == "Instance" and value:IsA("Sound") then
		return normalizeId(value.SoundId)
	end
	return nil
end

local function extractId(entry: any): string?
	if type(entry) == "table" then
		return normalizeId(entry.id or entry.Id or entry.ID or entry.SoundId or entry.soundId or entry.assetId or entry.AssetId or entry[1])
	end
	return normalizeId(entry)
end

-- Case-insensitive key lookup in a table.
local function findEntry(tbl: any, name: string): any
	if type(tbl) ~= "table" then
		return nil
	end
	if tbl[name] ~= nil then
		return tbl[name]
	end
	local lower = string.lower(name)
	for k, v in pairs(tbl) do
		if type(k) == "string" and string.lower(k) == lower then
			return v
		end
	end
	return nil
end

local cachedGa: any = nil
local function getGameAssets(): any
	if cachedGa ~= nil then
		return cachedGa
	end
	local ok, result = pcall(function()
		local moduleScript = ReplicatedStorage:FindFirstChild("GameAssets") or ReplicatedStorage:WaitForChild("GameAssets", 5)
		if not moduleScript then
			return nil
		end
		return require(moduleScript)
	end)
	if ok and type(result) == "table" then
		cachedGa = result
		return result
	end
	return nil
end

-- Resolve a verified sound id from GameAssets.Sounds; fall back (with a warning) if missing.
local function resolveSound(name: string, fallback: string): string
	local resolved: string? = nil
	local ok, err = pcall(function()
		local ga = getGameAssets()
		if not ga then
			return
		end
		local candidates = { ga.Sounds, ga.SOUNDS, ga.sounds, ga.SoundIds, ga.SOUND_IDS, ga.soundIds, ga.SoundIDs }
		for _, tbl in ipairs(candidates) do
			local id = extractId(findEntry(tbl, name))
			if id then
				resolved = id
				return
			end
		end
		-- Direct entry on the module itself.
		local direct = extractId(findEntry(ga, name))
		if direct then
			resolved = direct
			return
		end
		-- Helper function style APIs.
		for _, fnName in ipairs({ "soundId", "getSoundId", "SoundId", "GetSoundId" }) do
			local fn = ga[fnName]
			if type(fn) == "function" then
				local okFn, val = pcall(fn, name)
				if okFn then
					local id = extractId(val)
					if id then
						resolved = id
						return
					end
				end
			end
		end
	end)
	if not ok then
		warn("[CashInConfig] sound lookup error for " .. name .. ": " .. tostring(err))
	end
	if not resolved then
		warn("[CashInConfig] GameAssets sound '" .. name .. "' not found; using fallback " .. fallback)
		return fallback
	end
	return resolved
end

CashInConfig.RING_TAG = "CashInRing"
CashInConfig.MAX_POPUPS_PER_SECOND = 6

-- Verified ids from the GameAssets sound table.
CashInConfig.CASHIN_SOUND_ID = resolveSound("Coin", "rbxasset://sounds/electronicpingshort.wav")
CashInConfig.POP_SOUND_ID = resolveSound("Pop", "rbxasset://sounds/button.wav")
CashInConfig.BUY_SOUND_ID = resolveSound("Buy", "rbxasset://sounds/electronicpingshort.wav")
CashInConfig.ERROR_SOUND_ID = resolveSound("Error", "rbxasset://sounds/button.wav")
CashInConfig.WIN_SOUND_ID = resolveSound("Win", "rbxasset://sounds/electronicpingshort.wav")

CashInConfig.SOUND_IDS = {
	Coin = CashInConfig.CASHIN_SOUND_ID,
	Pop = CashInConfig.POP_SOUND_ID,
	Buy = CashInConfig.BUY_SOUND_ID,
	Error = CashInConfig.ERROR_SOUND_ID,
	Win = CashInConfig.WIN_SOUND_ID,
}

-- Keep cash-in quiet so rapid cash-ins do not spam.
CashInConfig.CASHIN_VOLUME = 0.4
CashInConfig.POP_VOLUME = 0.5

CashInConfig.BASE_PITCH = 1
CashInConfig.PITCH_PER_TIER = 0.06
CashInConfig.MAX_PITCH = 1.5

CashInConfig.TIER_COLORS = {
	Color3.fromRGB(255, 214, 64),  -- tier 1: gold
	Color3.fromRGB(120, 230, 120), -- tier 2: green
	Color3.fromRGB(80, 190, 255),  -- tier 3: blue
	Color3.fromRGB(190, 110, 255), -- tier 4: purple
	Color3.fromRGB(255, 120, 190), -- tier 5: pink
	Color3.fromRGB(255, 130, 60),  -- tier 6: orange
}

CashInConfig.RING_SPIN_DEG_PER_SEC = 45

CashInConfig.LIGHT_BRIGHTNESS = 2
CashInConfig.LIGHT_RANGE = 14
CashInConfig.LIGHT_COLOR = Color3.fromRGB(255, 220, 90)

CashInConfig.CASHIN_REMOTE = "CashIn"
CashInConfig.PURCHASE_REMOTE = "PurchaseFx"

function CashInConfig.colorForTier(tier: number): Color3
	local colors = CashInConfig.TIER_COLORS
	local idx = 1
	if type(tier) == "number" and tier == tier then
		idx = math.clamp(math.floor(tier), 1, #colors)
	end
	return colors[idx]
end

function CashInConfig.pitchForTier(tier: number): number
	local t = 1
	if type(tier) == "number" and tier == tier then
		t = math.max(1, math.floor(tier))
	end
	local pitch = CashInConfig.BASE_PITCH + CashInConfig.PITCH_PER_TIER * (t - 1)
	return math.min(pitch, CashInConfig.MAX_PITCH)
end

return CashInConfig
