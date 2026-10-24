--!strict
-- NumberFormat: pure shared helpers for compact number display (no services, no side effects).

local NumberFormat = {}

-- Ascending list of units.
local UNITS: { { any } } = {
	{ 1e3, "K" },
	{ 1e6, "M" },
	{ 1e9, "B" },
	{ 1e12, "T" },
}

local function roundTenth(x: number): number
	return math.floor(x * 10 + 0.5) / 10
end

local function trim(v: number): string
	local s = string.format("%.1f", v)
	s = s:gsub("%.0$", "")
	return s
end

-- 999 -> "999", 1234 -> "1.2K", 999950 -> "1M", 3400000 -> "3.4M"
function NumberFormat.short(n: any): string
	if type(n) ~= "number" or n ~= n then
		return "0"
	end
	local num: number = n
	if num == math.huge then
		return "∞"
	elseif num == -math.huge then
		return "-∞"
	end
	local neg = num < 0
	local a = math.abs(num)
	local sign = if neg then "-" else ""

	if a < 1000 then
		local r = math.floor(a + 0.5)
		if r < 1000 then
			if r == 0 then
				return "0"
			end
			return sign .. tostring(r)
		end
		a = 1000 -- 999.5+ rounds up into the K range
	end

	local idx = 1
	for i = 1, #UNITS do
		if a >= (UNITS[i][1] :: number) then
			idx = i
		end
	end

	local v = roundTenth(a / (UNITS[idx][1] :: number))
	if v >= 1000 and idx < #UNITS then
		idx += 1
		v = roundTenth(a / (UNITS[idx][1] :: number))
	end
	return sign .. trim(v) .. (UNITS[idx][2] :: string)
end

-- 1234567 -> "1,234,567"
function NumberFormat.withCommas(n: any): string
	if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
		return "0"
	end
	local num: number = n
	local neg = num < 0
	local s = string.format("%.0f", math.abs(num))
	local out = s
	while true do
		local replaced, count = out:gsub("^(%d+)(%d%d%d)", "%1,%2")
		out = replaced
		if count == 0 then
			break
		end
	end
	if out == "0" then
		return "0"
	end
	return (if neg then "-" else "") .. out
end

return NumberFormat
