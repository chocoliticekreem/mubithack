--!strict
-- FROZEN (kickoff). Cross-system types. See docs/game/03-tech-architecture.md §10.
-- K0 additions to the §10 draft: RescueState, EndReason, NotifyKind, PlayerStats.name and
-- .teammateSprayed, Award.blame, ResultsPayload.burningAtEnd/.stars/.reason.
export type RoundState = "Lobby" | "Alarm" | "Active" | "Results"
export type RescueKind = "Civilian" | "Dog" | "Cat" | "Panda"
export type RescueState = "Trapped" | "Carried" | "Downed" | "Rescued"
export type EndReason = "time" | "allOut" | "forced"
export type NotifyKind = "info" | "good" | "bad" | "blame"
export type PlayerStats = {
	userId: number,
	helmet: number,
	name: string,
	firesOut: number,
	firesStarted: number,
	water: number,
	doors: number,
	rescued: number,
	pandas: number,
	downedOthers: number,
	timesDowned: number,
	teammateSprayed: number,
}
export type Award = { id: string, title: string, userId: number, value: number, blurb: string, blame: boolean }
export type ResultsPayload = {
	locationId: string,
	seconds: number,
	firesOut: number,
	burnedParts: number,
	rescued: number,
	trapped: number,
	burningAtEnd: number,
	stars: number,
	reason: EndReason,
	awards: { Award },
	stats: { PlayerStats },
}
return {}
