--!strict
-- CityConfig [owner: CityBuilder]. The v2 city (docs/game/08 "City"). Read at use time.
--
-- World frame (world studs, MapService Slot 0 = origin): +X east, +Z SOUTH, so NORTH is -Z.
-- A 3 x 3 grid of CellSize (900) cells, ~3000 studs across (Bounds). The FIRE STATION HUB is the
-- centre cell; the other 8 cells hold one neighbourhood each (Lib/Map/City/Districts.luau Layout):
--   NW Farm (Sunny Acres)   N Town (Maple Street)        NE Dam (Mill Creek)
--   W  Storage (industrial) C Station hub + downtown     E  Forest (Pine Ridge)
--   SW School campus        S Apartment (Downtown Heights) SE Zoo
-- Roads between the cells: x / z = -1350 and 1350 are Highway 67 (outer ring, 4 lanes), -450 / 450
-- are 4-lane avenues (the ring road round the hub). Each district: a 400 x 400 core (a v1 location
-- builder's footprint, or a procedural core), a 2-lane loop street round it, a band of neighbourhood
-- lots out to DistrictHalf, and a gate street from each loop side out to the road between cells
-- (~230 studs of driving, welcome arch at the district edge). The hub's gates are 4-lane avenues
-- radiating from the station. Mill Creek runs from the dam down the east greenbelt (bridges).
-- StationBuilder is built at StationOrigin, in the hub core, bay doors facing +Z (south) onto a
-- forecourt that runs down to the hub loop; keep the station inside x -150..150, z -190..60.
-- WorldBoundsService reads Bounds for the world walls.
--
-- Pure numbers + a CFrame + a Vector3. game/tests/city.spec.luau mirrors the layout numbers it needs.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	-- v2 switch. true: MapService builds "City" (Slot 0) and skips the standalone builders it absorbs
	-- (ReplacedLocations); Station is built at StationOrigin. false: the v1/v1.5 slot layout, untouched.
	Enabled = false, -- DRAFT: flips to true once CityBuilder + MapService wiring land

	CellSize = 900, -- 3 x 3 cells; road lines between them at -1350, -450, 450, 1350
	DistrictHalf = 310, -- each neighbourhood is 620 x 620; 280 studs of greenbelt + road between two
	CoreHalf = 200, -- the 400 x 400 core (v1 location builder footprint)
	LoopOffset = 216, -- loop street centreline (its inner edge touches the core)
	SubBlockSize = 184, -- procedural cores: 4 sub-blocks + a cross of streets = 400
	BandLotWidth = 70,
	Bounds = { minX = -1500, maxX = 1500, minZ = -1500, maxZ = 1500 },

	HighwayWidth = 48, -- 4 lanes x 12 (outer ring)
	AvenueWidth = 48, -- 4 lanes x 12 (ring road + hub radials)
	StreetWidth = 32, -- 2 lanes x 14 + shoulders (loops, gates, cores)
	SpurWidth = 32, -- dam road
	HighwaySpeed = 80, -- studs/s speed limits exported with the lanes (RoadGraphJson)
	AvenueSpeed = 60,
	StreetSpeed = 45,
	SpurSpeed = 30,
	SidewalkWidth = 6,
	CornerRadius = 20, -- rounded kerb at every block corner
	ApronDepth = 36, -- paved parking apron in front of every incident site
	RoadY = 0.3, -- road surface top
	SidewalkY = 0.7, -- sidewalk top
	GroundY = -0.1, -- grass top between districts
	RiverWidth = 40, -- Mill Creek
	RiverInset = 80, -- creek centre east of the x = 450 avenue
	SpillwayOffset = 60, -- creek leaves the dam this far east of the dam road
	RiverDepth = 6,

	-- Station (hub core)
	StationOrigin = CFrame.new(0, 0, -40),
	StationDriveway = { x = 0, z = 130 }, -- road-graph node "Station" (forecourt)

	-- Location builders the city absorbs as districts (built inside City, not on their own slot).
	ReplacedLocations = { "Town", "Farm", "Forest", "School", "Storage", "Apartment", "Zoo", "Dam", "Field" },
	-- Builders that are neither City, Station nor replaced keep their slot but move out of the city.
	LegacyOffset = Vector3.new(0, 0, 3200),

	-- Incident sites
	ArrivalSize = Vector3.new(40, 16, 40), -- invisible ArrivalZone part
	SiteTag = "IncidentSite",
	ArrivalTag = "ArrivalZone",
	-- procedural site kind -> MissionCatalog ids (comma-joined into the MissionTypes attribute)
	KindMissions = {
		house = { "house_fire" },
		shop = { "house_fire" },
		diner = { "house_fire" },
		gas = { "house_fire" },
		apartment = { "apartment_trampoline", "house_fire" },
		school = { "school_alarm" },
		storage = { "storage_fusebox" },
		zoo = { "panda_zoo" },
		dam = { "dam_finale" },
	},
	-- builder district (location id) -> extra mission ids beyond those whose locationId matches
	DistrictExtraMissions = {
		Farm = { "tornado_field" },
	},
	SitesPerSuburbBlock = 2, -- per core sub-block; the rest of the houses are cheap LOD shells

	-- Street furniture
	LampSpacing = 90, -- per road edge, alternating sides
	TreeSpacing = 46, -- along roads (highway: x 2.5)
	Crosswalks = true,
	TrafficLights = true,
	TrafficCycle = 7, -- seconds per green phase (amber 1.5 s at the end)

	-- Budget (counter city_parts, attribute PartCount on Workspace.Map.City)
	PartBudget = 25000,
})
