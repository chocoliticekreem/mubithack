--!strict
-- FROZEN (kickoff). Cross-system types. See docs/game/03-tech-architecture.md §10.
export type RoundState = "Lobby" | "Alarm" | "Active" | "Results"
export type RescueKind = "Civilian" | "Dog" | "Cat" | "Panda"
export type PlayerStats = {
	userId: number, helmet: number,
	firesOut: number, firesStarted: number, water: number, doors: number,
	rescued: number, pandas: number, downedOthers: number, timesDowned: number,
}
export type Award = { id: string, title: string, userId: number, value: number, blurb: string }
export type ResultsPayload = {
	locationId: string, seconds: number, firesOut: number, burnedParts: number,
	rescued: number, trapped: number, awards: { Award }, stats: { PlayerStats },
}
return {}
