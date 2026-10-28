--!strict
-- CallRampConfig [owner: G3 mission]. How long and how big a player's early calls are (MissionService through
-- Lib/Mission/CallRamp). Live data (7 days): First Fire Out -> Mission Complete lost 24% on every device and
-- sessions were 4.7-7.4 min, because call 3 was a full 5-7 minute call (6+ fires, 5 rescues, two escalation
-- waves that held "all clear", a far site) and calls 1-2 could still spread to 10 burning parts.
-- A call's index is the squad's NEWEST player's lifetime calls + 1 (profile missionsPlayed + 1). Calls 1..#Tiers
-- use their tier; later calls use the mission catalog as written. Every tier field is optional:
--   Seconds       on-scene timer (the drive allowance is added on top); time running out on a tier call is
--                 CALL COMPLETE with the stars earned (at least 1), never TIME'S UP (TimeoutIsWin)
--   ArrivalFires  fires burning when the squad arrives (squad-scaled like the catalog's)
--   FireCap       burning parts the site may hold at once (FireService:SetAreaCap), + CapPerExtraPlayer
--   MaxRescues    people / pets to carry out (round robin over the catalog's kinds)
--   Waves         follow-up waves (the first N of the catalog's escalation phases), WaveFires fires each,
--                 the first one WaveAt s after arrival (or early, once the scene is quiet; GameConfig.Escalation)
--   SetPieces     keep the waves' flashover / explosion / collapse set pieces
--   NearestSite   the nearest free site (a short drive), not one MinDispatchStuds away
return table.freeze({
	Tiers = table.freeze({
		-- call 1: 3 fires (at most 4 burning), 1 rescue, no wave: ~1:30 for a normal kid
		table.freeze({ Seconds = 75, ArrivalFires = 3, FireCap = 4, MaxRescues = 1, Waves = 0, TimeoutIsWin = true, NearestSite = true }),
		-- call 2: + one short wave of 2 fires
		table.freeze({ Seconds = 90, ArrivalFires = 3, FireCap = 5, MaxRescues = 1, Waves = 1, WaveFires = 2, WaveAt = 35, TimeoutIsWin = true, NearestSite = true }),
		-- call 3: 4 fires, one wave of 2
		table.freeze({ Seconds = 100, ArrivalFires = 4, FireCap = 5, MaxRescues = 1, Waves = 1, WaveFires = 2, WaveAt = 40, TimeoutIsWin = true, NearestSite = true }),
		-- calls 4-5 ramp toward the full call (6+ fires, every rescue, 2+ waves with set pieces, 5-7 min)
		table.freeze({ Seconds = 150, ArrivalFires = 4, FireCap = 7, MaxRescues = 2, Waves = 1, WaveFires = 3, WaveAt = 60, TimeoutIsWin = true }),
		table.freeze({ Seconds = 200, ArrivalFires = 5, FireCap = 9, MaxRescues = 2, Waves = 2, WaveFires = 3, WaveAt = 70, SetPieces = true, TimeoutIsWin = true }),
	}),
	CapPerExtraPlayer = 2, -- FireCap + this per extra squad member
	-- every call: once nothing is burning and nobody is left to carry, "ALL DONE! 3..2..1" on the objective
	-- chip, then the results (a fire that flares up in between cancels it)
	AllDoneSeconds = 3,
})
