--!strict
-- FROZEN (kickoff). Cross-system types. See docs/game/03-tech-architecture.md §10.
-- K0 additions to the §10 draft: RescueState, EndReason, NotifyKind, PlayerStats.name and
-- .teammateSprayed, Award.blame, ResultsPayload.burningAtEnd/.stars/.reason.
-- v1.5 additions are at the bottom of this file.
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
	missionId: string?, -- v1.5: set when the round ran as a MissionCatalog mission
	instanceId: string?, -- v1.5: set when the round ran in its own location instance
}

-- v1.5 additions: lobby, squads, parallel mission instances, hazards (docs/game/03 §10 "v1.5 additions").
export type SquadState = "Forming" | "Launching" | "InMission"
export type Squad = {
	id: string, -- "S1", "S2", ...
	padId: number, -- SquadPad the squad queued on
	leader: number, -- UserId; only the leader chooses and launches
	members: { number }, -- UserIds, 1..4
	missionId: string?, -- chosen MissionCatalog id
	instanceId: string?, -- set once launched
	state: SquadState,
}
export type HazardId = "electrocution" | "fire_tornado" | "explosion" | "tidal_wave" | "cigarette"
export type MissionRun = {
	instanceId: string,
	missionId: string,
	locationId: string,
	squadId: string?,
	players: { number }, -- UserIds
	state: RoundState,
	endsAt: number, -- workspace:GetServerTimeNow() time
}
-- One entry of ReplicatedStorage/Config/MissionCatalog.luau (data only; validated by game/tests).
export type MissionObjective = { kind: "extinguish" | "rescue" | "survive" | "custom", count: number?, text: string }
export type MissionRescue = { kind: RescueKind, count: number, variant: string? }
export type StarRule = { id: "finish" | "allOut" | "allRescued" | "underTime" | "noDowns", text: string, seconds: number? }
export type MissionDef = {
	id: string,
	title: string,
	blurb: string,
	locationId: string, -- MapService builder Id
	enabled: boolean, -- false until its builder exists
	players: { min: number, max: number },
	seconds: number,
	atmosphere: string, -- AtmosphereConfig preset name
	objectives: { MissionObjective },
	fires: { count: number, starts: "FireStart" | "Random" | "Scripted" },
	rescues: { MissionRescue },
	hazards: { HazardId },
	tools: { string }, -- extra loadout beyond Hose + Axe (e.g. "Walkie", "Detonator")
	stars: { StarRule },
}
return {}
