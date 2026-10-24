--!strict
-- RebirthConfig: shared tunables and pure helpers for the Rebirth feature (server and client).

local RebirthConfig = {
	baseCost = 5000,
	costGrowth = 2,
	multPerRebirth = 0.5,
	requestCooldown = 1.5, -- seconds between rebirth requests per player
	altarColor = Color3.fromRGB(255, 205, 40),
	altarGlowColor = Color3.fromRGB(255, 240, 150),
	altarSize = Vector3.new(4, 5, 4),
	flashDuration = 1.2, -- seconds for the full-screen golden flash
	bannerDuration = 2.5, -- seconds the 'REBIRTH x<mult>!' banner stays up
	flashColor = Color3.fromRGB(255, 215, 60),
}

-- Cash required for the next rebirth, given how many rebirths were already done.
function RebirthConfig.costFor(rebirths: number): number
	local n = math.max(0, math.floor(rebirths))
	return math.floor(RebirthConfig.baseCost * RebirthConfig.costGrowth ^ n)
end

-- Permanent cash multiplier for a given number of rebirths.
function RebirthConfig.multiplierFor(rebirths: number): number
	local n = math.max(0, math.floor(rebirths))
	return 1 + RebirthConfig.multPerRebirth * n
end

-- Formats a multiplier for display, e.g. 1.5 -> "1.5", 2 -> "2.0".
function RebirthConfig.formatMultiplier(mult: number): string
	return string.format("%.1f", mult)
end

-- Banner text, e.g. "REBIRTH x1.5!".
function RebirthConfig.bannerText(rebirths: number): string
	return "REBIRTH x" .. RebirthConfig.formatMultiplier(RebirthConfig.multiplierFor(rebirths)) .. "!"
end

-- Rounded payout for a cube value after applying the multiplier.
function RebirthConfig.applyMultiplier(value: number, rebirths: number): number
	return math.floor(value * RebirthConfig.multiplierFor(rebirths) + 0.5)
end

-- Whether a player may rebirth: enough cash, or every upgrade bought.
function RebirthConfig.canRebirth(cash: number, rebirths: number, allUpgradesBought: boolean): boolean
	return allUpgradesBought or cash >= RebirthConfig.costFor(rebirths)
end

return RebirthConfig
