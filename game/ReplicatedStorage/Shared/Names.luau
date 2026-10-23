--!strict
-- FROZEN (kickoff). Every cross-system tag and attribute name (docs/game/03-tech-architecture.md §10).
-- Use Names.Tag.Flammable, never the string literal, so a typo is a nil error, not a silent miss.

local Names = {}

Names.Tag = table.freeze({
	Flammable = "Flammable",
	Burning = "Burning",
	Door = "Door",
	Hydrant = "Hydrant",
	TruckRefill = "TruckRefill",
	RescueDropoff = "RescueDropoff",
	Rescuable = "Rescuable",
	StationSpawn = "StationSpawn",
	Window = "Window",
	WetFloor = "WetFloor",
	FuseBox = "FuseBox",
	Truck = "Truck",
	FireStart = "FireStart",
	RescueSpawn = "RescueSpawn",
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
})

return table.freeze(Names)
