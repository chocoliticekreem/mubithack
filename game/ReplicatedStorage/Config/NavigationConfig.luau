--!strict
-- NavigationConfig [owner: Navigation]. Numbers for NavigationService (server waypoints) and
-- NavigationController / ClientLib/Minimap (minimap, big map, beacon, GPS route arrows).
-- Read at use time so DevHook ".Set" tuning applies (client copies are separate).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	-- server
	TrackInterval = 0.5, -- seconds between re-reading a BasePart/Model target's position
	TrackMinMove = 2, -- studs a tracked target must move before WaypointPos is rewritten

	-- road graph (CityBuilder): Workspace.Map.City.RoadGraphJson, or the RoadGraph folder
	GraphPollSeconds = 2, -- how often the client looks for / re-reads the graph until it has one
	RoadWidth = 24, -- studs, drawn width on the maps

	-- minimap (top right, under the HUD squad strip)
	MinimapSize = 190, -- px at 1280x720
	MinimapTop = 204, -- px from the top (HudController's squad strip sits above it)
	MinimapRight = 14,
	MinimapScale = 0.42, -- px per stud standing still
	MinimapScaleFast = 0.22, -- px per stud at TruckSpeedForZoom (zooms out while driving)
	TruckSpeedForZoom = 60,

	-- big map (M)
	BigMapKey = Enum.KeyCode.M,
	BigMapMinZoom = 0.25, -- px per stud
	BigMapMaxZoom = 3,

	-- route (GPS)
	RouteRefresh = 1, -- seconds between route recomputes
	OffRouteDistance = 30, -- studs off the line -> recompute right away
	ArriveRadius = 45, -- studs: closer than this the route hides and the hint says "You're here"
	ArrowSpacing = 14, -- studs between arrows on the road
	MaxArrows = 48, -- pooled arrows (spacing * MaxArrows = how far ahead the route is drawn)
	ArrowHover = 0.35, -- studs above the road surface
	ArrowColor = Color3.fromHex("#7FF5F0"),
	ArrowFlowSpeed = 3.5, -- arrows/s the bright pulse runs along the route
	TurnAngle = 35, -- degrees: sharper corners than this get a turn hint
	TurnHintRange = 220, -- studs: farther than this the hint says "Follow the road ..."
	UnitName = "m", -- same unit as the HUD markers (HudController STUDS_PER_M = 3.5)
	StudsPerUnit = 3.5,

	-- 3D beacon
	BeaconHeight = 260,
	BeaconColor = Color3.fromHex("#FFC531"),
	BeaconFadeNear = 30, -- studs: the beam fades out when you're this close
	EdgeArrowMargin = 150, -- px from the screen edge (inside the HUD markers' edge ring, so the two never stack)
})
