--!strict
-- FROZEN (kickoff). Every cross-system tag and attribute name (docs/game/03-tech-architecture.md §10).
-- Use Names.Tag.Flammable, never the string literal, so a typo is a nil error, not a silent miss.

local Names = {}

Names.Tag = table.freeze({
	Flammable = "Flammable", -- BasePart <= 8 studs; MapService builders -> FireService
	Burning = "Burning", -- Flammable part on fire; FireService -> FireFx, Squad, Blame
	Door = "Door", -- door panel with a ProximityPrompt; MapKit.door -> ToolService
	Hydrant = "Hydrant", -- refill part with a ProximityPrompt; MapKit.hydrant -> ToolService
	TruckRefill = "TruckRefill", -- refill part on the truck with a ProximityPrompt; TruckBuilder -> ToolService
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
})

return table.freeze(Names)
