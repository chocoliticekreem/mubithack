--!strict
-- SquadConfig [owner: G3]. Crew numbers: helmets, spawning, Downed / revive, emotes, costume tuning.
-- Read at use time (SquadConfig.X) so DevHook:Invoke("SquadConfig", ".Set", key, value) live-tunes.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	MaxHelmet = 8, -- helmet numbers 01..08 (squads of up to 8)
	-- Downed
	DownAtHealth = 5, -- Humanoid health at or below this downs the player instead of killing them
	BleedOutSeconds = 25, -- downed this long with nobody helping -> respawn at the truck (or a station pad)
	CrawlSpeed = 3, -- WalkSpeed while downed (slow worm crawl on your back)
	FlopSeconds = 1.2, -- Ragdoll.enable on the way down (G1's Shared/Ragdoll), then the lying pose
	DownedHipHeight = 0.3, -- Humanoid.HipHeight while lying
	DownedDrop = 0.6, -- extra studs the body is lowered while lying
	DownedThirdPerson = true, -- unlock the camera while downed so you can see your own spiral eyes
	DownCauses = { -- false = this hazard shoves but doesn't down (unknown causes do down)
		heat = true,
		fire = true,
		explosion = true,
		electrocution = true,
		fire_tornado = false,
		tidal_wave = false,
		hurt = true,
		test = true,
	},
	-- revive
	ReviveHold = 3, -- seconds holding E ("Give oxygen") on a downed teammate
	ReviveHealth = 50,
	SlapReviveHealth = 20, -- F slaps them awake instantly...
	SlapBlame = 1, -- ...but the slapper earns a blame point (Revived signal, method "slap")
	SlapImpulse = 30, -- studs/s shove on the slapped victim (Ragdoll.knockback)
	ReviveDistance = 9,
	WalkSpeed = 16,
	JumpHeight = 7.2,
	-- squad wipe
	-- MissionService (main) already ends a run as "wiped" when every squad member is Downed, so by
	-- default SquadService only fires Wiped + counts squad_wipes. true = also end it here ("forced").
	WipeEndsMission = false,
	WipeMinPlayers = 1,
	WipeGraceSeconds = 2, -- comedic beat before "MISSION FAILED"
	-- emotes (lobby only, number keys 1..3)
	Emotes = { "wave", "facepalm", "blame" },
	EmoteSeconds = 2.2,
	BlameRange = 60, -- studs; the blame emote points at the teammate you look at
	-- client fx
	StarCount = 5,
	StarRadius = 1.4,
	StarSpin = 0.8, -- revolutions per second
	PupilSpin = 3, -- spiral eyes: pupils orbit at this many rev/s (docs/game/02 §3)
	-- costume (borrowed from NpcBuilder's Firefighter; offsets in studs from the character's parts)
	HeadOffset = Vector3.new(0, 0.35, 0), -- where the NPC head blob centre sits relative to Head
	BodyOffset = Vector3.new(0, -0.55, 0.05), -- where the NPC body blob centre sits relative to UpperTorso
	-- sounds (unverified asset ids stay blank; "" = silent)
	SlapSoundId = "",
	DownSoundId = "",
	ReviveSoundId = "",
	EmoteSoundId = "",
	-- attribute names this lane adds (not in Shared/Names; see PR)
	AttrDownedUntil = "DownedUntil", -- Player: number (workspace:GetServerTimeNow() when bleed-out respawns)
})
