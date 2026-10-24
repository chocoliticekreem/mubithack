--!strict
-- MapVariant [owner: CityBuilder]. Per-server map variation, so the city doesn't look the same every
-- time. MapService rolls one seed per server (Workspace attr MapSeed, settable before Play to
-- reproduce a server); the seed drives the city plan (Districts.planCity: which lots hold which
-- buildings and which of them are incident sites), every builder's Random (house colours, roofs, shop
-- names, tower heights, parked cars, trees, plaza statues) and the look picked here:
--   season   Summer | Autumn | Spring | Winter     recolours foliage + grass after the build (0 parts)
--   sky      Golden | Noon | Sunset | Night        time of day for the open city (client overlay,
--                                                  AtmosphereConfig.Sky; mission presets keep theirs)
--   weather  Clear | Overcast | Fog | Rain         client overlay (AtmosphereConfig.Weather) + rain fx
-- PURE: no Roblox APIs at require time; recolour() works on plain numbers so the spec can test it.
-- Only apply() (server) touches Instances.
--
--   MapVariant.rng(seed): Rng                     -- same LCG as Districts.rng
--   MapVariant.pick(seed, overrides?): Variant    -- { seed, season, sky, weather }; overrides =
--       { season?, sky?, weather? } (Workspace attrs MapSeason / MapSky / MapWeather when set)
--   MapVariant.role(name, material, sx, sy, sz, r, g, b): "foliage" | "evergreen" | "ground" | nil
--   MapVariant.recolour(season, role, r, g, b, h): (r, g, b, snow: boolean)   -- 0..1 channels
--   MapVariant.apply(root, season): number        -- recolours root's parts; returns parts changed
local MapVariant = {}

export type Variant = { seed: number, season: string, sky: string, weather: string }

-- { name, weight }
MapVariant.Seasons = { { "Summer", 35 }, { "Autumn", 25 }, { "Spring", 20 }, { "Winter", 20 } }
MapVariant.Skies = { { "Golden", 35 }, { "Noon", 30 }, { "Sunset", 20 }, { "Night", 15 } }
MapVariant.Weathers = { { "Clear", 50 }, { "Overcast", 20 }, { "Fog", 15 }, { "Rain", 15 } }

function MapVariant.rng(seed: number)
	local state = math.floor(math.abs(seed)) % 2147483647
	if state == 0 then
		state = 1
	end
	return function(): number
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
end

local function weighted(list: { { any } }, x: number): string
	local total = 0
	for _, e in list do
		total += e[2]
	end
	local at = x * total
	for _, e in list do
		at -= e[2]
		if at < 0 then
			return e[1]
		end
	end
	return list[#list][1]
end

local function valid(list: { { any } }, name: any): boolean
	for _, e in list do
		if e[1] == name then
			return true
		end
	end
	return false
end

function MapVariant.pick(seed: number, overrides: { [string]: any }?): Variant
	-- its own stream (seed scrambled), so adding a field here never reshuffles the city plan
	local nextNum = MapVariant.rng(seed * 7 + 1013)
	nextNum()
	local v: Variant = {
		seed = seed,
		season = weighted(MapVariant.Seasons, nextNum()),
		sky = weighted(MapVariant.Skies, nextNum()),
		weather = weighted(MapVariant.Weathers, nextNum()),
	}
	-- no fog or rain on a night map: it reads as a black screen on low-end phones
	if v.sky == "Night" and (v.weather == "Fog" or v.weather == "Rain") then
		v.weather = "Clear"
	end
	-- rain in winter falls as... rain on snow. Make it overcast instead.
	if v.season == "Winter" and v.weather == "Rain" then
		v.weather = "Overcast"
	end
	local o = overrides or {}
	if valid(MapVariant.Seasons, o.season) then
		v.season = o.season
	end
	if valid(MapVariant.Skies, o.sky) then
		v.sky = o.sky
	end
	if valid(MapVariant.Weathers, o.weather) then
		v.weather = o.weather
	end
	return v
end

---------------------------------------------------------------------------------------------------
-- seasonal recolour
---------------------------------------------------------------------------------------------------
local FOLIAGE = { "Canopy", "Leaves", "Leaf", "Crown", "Bush", "Hedge", "Shrub", "Foliage", "Topiary", "GrassTuft", "Ivy" }
local EVERGREEN = { "Pine", "Fir", "Spruce", "Conifer" }
local GROUND = { "Grass", "Lawn", "ParkLawn", "GrassPatch", "Verge", "Meadow" }

local function hasPrefix(name: string, list: { string }): boolean
	for _, p in list do
		if string.sub(name, 1, #p) == p then
			return true
		end
	end
	return false
end

-- green enough to be a plant (walls in sage green are excluded by name/material, not by this)
local function greenish(r: number, g: number, b: number): boolean
	return g >= r and g >= b and g - math.min(r, b) > 0.06
end

-- material: the Enum.Material name ("Grass", "LeafyGrass", ...)
function MapVariant.role(name: string, material: string, sx: number, sy: number, sz: number, r: number, g: number, b: number): string?
	if not greenish(r, g, b) then
		return nil
	end
	if hasPrefix(name, EVERGREEN) then
		return "evergreen"
	end
	local grassy = material == "Grass" or material == "LeafyGrass"
	local flat = sy <= 0.3 * math.min(sx, sz)
	if hasPrefix(name, GROUND) and (flat or grassy) then
		return "ground"
	end
	if hasPrefix(name, FOLIAGE) then
		return "foliage"
	end
	if grassy then
		return if flat then "ground" else "foliage"
	end
	return nil
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function hexrgb(h: string): (number, number, number)
	return tonumber(string.sub(h, 1, 2), 16) / 255, tonumber(string.sub(h, 3, 4), 16) / 255, tonumber(string.sub(h, 5, 6), 16) / 255
end

local AUTUMN = { "D9822B", "C8502A", "E3B23C", "B5651D", "D96B3A", "9E9A3A" }
local SPRING_BLOSSOM = { "F4B6C9", "F7D6E0", "F2EEF5", "E9A3C0" }

-- h: any integer (a stable per-part hash) to vary the palette. Returns new channels + whether the
-- part should turn to Snow material.
function MapVariant.recolour(season: string, role: string, r: number, g: number, b: number, h: number): (number, number, number, boolean)
	h = math.abs(math.floor(h))
	if season == "Autumn" then
		if role == "foliage" then
			if h % 7 == 0 then
				return r, g, b, false -- the odd tree is still green
			end
			local cr, cg, cb = hexrgb(AUTUMN[h % #AUTUMN + 1])
			return lerp(r, cr, 0.85), lerp(g, cg, 0.85), lerp(b, cb, 0.85), false
		elseif role == "ground" then
			return lerp(r, 0.62, 0.45), lerp(g, 0.60, 0.45), lerp(b, 0.30, 0.45), false
		elseif role == "evergreen" then
			return lerp(r, 0.25, 0.2), lerp(g, 0.38, 0.2), lerp(b, 0.25, 0.2), false
		end
	elseif season == "Spring" then
		if role == "foliage" then
			if h % 3 == 0 then
				local cr, cg, cb = hexrgb(SPRING_BLOSSOM[(h // 3) % #SPRING_BLOSSOM + 1])
				return cr, cg, cb, false
			end
			return lerp(r, 0.55, 0.35), lerp(g, 0.82, 0.35), lerp(b, 0.35, 0.35), false
		elseif role == "ground" then
			return lerp(r, 0.49, 0.35), lerp(g, 0.76, 0.35), lerp(b, 0.31, 0.35), false
		end
	elseif season == "Winter" then
		if role == "ground" then
			return 0.91, 0.93, 0.95, true
		elseif role == "foliage" then
			-- frosted canopies; hedges and topiaries read as snow-capped
			return lerp(r, 0.86, 0.75), lerp(g, 0.9, 0.75), lerp(b, 0.93, 0.75), false
		elseif role == "evergreen" then
			return lerp(r, 0.85, 0.3), lerp(g, 0.9, 0.3), lerp(b, 0.92, 0.3), false
		end
	end
	return r, g, b, false
end

-- Roblox side (server): recolour every plant / lawn part under root for the season. Summer = no-op.
function MapVariant.apply(root: Instance, season: string): number
	if season == "Summer" or season == "" then
		return 0
	end
	local changed = 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 0.95 then
			local c = d.Color
			local s = d.Size
			local role = MapVariant.role(d.Name, d.Material.Name, s.X, s.Y, s.Z, c.R, c.G, c.B)
			if role then
				local p = d.Position
				local h = math.floor(p.X * 0.37) * 31 + math.floor(p.Z * 0.37) * 17 + math.floor(p.Y)
				local r, g, b, snow = MapVariant.recolour(season, role, c.R, c.G, c.B, h)
				d.Color = Color3.new(r, g, b)
				if snow then
					d.Material = Enum.Material.Snow
				end
				changed += 1
			end
		end
	end
	return changed
end

return MapVariant
