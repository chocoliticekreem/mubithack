--!strict
-- FROZEN (kickoff). Every cross-system tag and attribute name (docs/game/03-tech-architecture.md §10).
-- Use Names.Tag.Flammable, never the string literal, so a typo is a nil error, not a silent miss.

local Names = {}

Names.Tag = table.freeze({
	Flammable = "Flammable", -- BasePart <= 8 studs; MapService builders -> FireService
	Burning = "Burning", -- Flammable part on fire; FireService -> FireFx, Squad, Blame
	Door = "Door", -- door panel with a ProximityPrompt; MapKit.door -> ToolService
	Hydrant = "Hydrant", -- hydrant / pond / pool water: decoration (no prompt); MapKit.hydrant -> EventService geyser
	TruckRefill = "TruckRefill", -- the truck's hose reel (Grab Hose prompt, endless water); TruckBuilder -> InventoryService
	RescueDropoff = "RescueDropoff", -- invisible volume at the truck; TruckBuilder -> RescueService
	Rescuable = "Rescuable", -- NPC Model; RescueService -> RescueController, Hud
	StationSpawn = "StationSpawn", -- 4 spawn pads, attr Slot 1..4; StationBuilder -> MapService/SquadService
	Window = "Window",
	WetFloor = "WetFloor", -- v2
	FuseBox = "FuseBox", -- v2
	Truck = "Truck", -- truck Model; VehicleService -> MissionService, VehicleController
	FireStart = "FireStart", -- Flammable parts that light at round start; builders -> MissionService
	RescueSpawn = "RescueSpawn", -- invisible marker, attr Kind; builders -> RescueService
	TruckSpot = "TruckSpot", -- invisible marker where the truck parks, attr LocationId; builders -> VehicleService
	AlarmLamp = "AlarmLamp", -- Neon lamp part at the station; StationBuilder -> AlarmController
	-- v1.5 additions (docs/game/03 §10 "v1.5 additions")
	MissionBoard = "MissionBoard", -- station board part (SurfaceGui + ProximityPrompt); StationBuilder -> LobbyService, LobbyController
	SquadPad = "SquadPad", -- squad queue pad in the station, attr PadId; StationBuilder -> LobbyService
	Hazard = "Hazard", -- hazard source part/Model (fuse box lever, gas tank, detonator), attr HazardId; builders -> HazardService
})

Names.Attr = table.freeze({
	Fuel = "Fuel",
	FireLevel = "FireLevel",
	Charred = "Charred",
	LocationId = "LocationId",
	BuildingId = "BuildingId",
	Locked = "Locked",
	Broken = "Broken",
	RescueId = "RescueId",
	Kind = "Kind",
	RescueState = "RescueState",
	CarriedBy = "CarriedBy",
	Water = "Water",
	TankSize = "TankSize",
	Spraying = "Spraying",
	Helmet = "Helmet",
	Carrying = "Carrying",
	Downed = "Downed",
	RoundState = "RoundState",
	RoundEndsAt = "RoundEndsAt",
	MissionId = "MissionId",
	ServerBooted = "ServerBooted",
	MapReady = "MapReady",
	Slot = "Slot", -- StationSpawn pad number 1..4
	-- v1.5 additions (docs/game/03 §10 "v1.5 additions")
	SquadId = "SquadId", -- Player: string, "" = not in a squad; LobbyService
	InstanceId = "InstanceId", -- Player ("" = in the lobby) and mission instance Model: string; MissionService / MapService
	PadId = "PadId", -- SquadPad: number 1..N; StationBuilder
	Heat = "Heat", -- Player: number 0..100; HeatService
	LocationPreset = "LocationPreset", -- Lighting: string, locationId whose look is applied; AtmosphereService
	HazardId = "HazardId", -- Hazard part/Model: string (Types.HazardId); builders
	Power = "Power", -- FuseBox: boolean (true = live); builders (initial), HazardService
	Ragdolled = "Ragdolled", -- character Model: boolean while ragdolled; Ragdoll / PhysicsFxController
})

return table.freeze(Names)
