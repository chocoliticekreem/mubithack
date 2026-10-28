--!strict
-- CallRamp [owner: G3 mission]. PURE: which size a player's early call gets (Config/CallRampConfig). No Roblox
-- APIs, no requires, so game/tests/callramp.spec.luau runs it (shared: the client objective chip uses CallRamp.chip) with the `luau` CLI.
--   CallRamp.index(played)            -> call index for a squad: min(missionsPlayed) + 1 (newest player wins)
--   CallRamp.tier(cfg, index)         -> the tier table for that call, or nil (catalog call)
--   CallRamp.phases(tier, phases)     -> the escalation phases a tier call keeps (first Waves, WaveFires each,
--                                        the first at WaveAt, no extra rescues, set pieces only with SetPieces)
--   CallRamp.cap(tier, players, per)  -> FireCap for the squad (nil = no cap)
--   CallRamp.bucket(index)            -> analytics field: "1".."5", "6-10", "11+"
--   CallRamp.chip(o)                  -> objective chip state: "done" | "fires" | "rescue" | "wave" | "none"

local CallRamp = {}

function CallRamp.index(played: { number }): number
	local least = math.huge
	for _, n in played do
		least = math.min(least, math.max(0, math.floor(tonumber(n) or 0)))
	end
	if least == math.huge then
		least = 0
	end
	return least + 1
end

function CallRamp.tier(cfg: any, index: number): any?
	local tiers = type(cfg) == "table" and cfg.Tiers or nil
	if type(tiers) ~= "table" or index < 1 then
		return nil
	end
	return tiers[math.floor(index)]
end

function CallRamp.phases(tier: any, phases: { any }): { any }
	local keep = math.max(0, math.floor(tonumber(tier.Waves) or 0))
	local out: { any } = {}
	for i = 1, math.min(keep, #phases) do
		local src = phases[i]
		local p: { [string]: any } = {}
		for k, v in src do
			p[k] = v
		end
		if tonumber(tier.WaveFires) then
			p.fires = math.min(tonumber(src.fires) or tier.WaveFires, tier.WaveFires)
		end
		if i == 1 and tonumber(tier.WaveAt) then
			p.at = tier.WaveAt
		elseif tonumber(tier.WaveAt) then
			p.at = math.max(tonumber(src.at) or 0, tier.WaveAt + 30 * (i - 1))
		end
		p.rescue = nil -- tier calls cap the rescues: no surprise person in a wave
		p.rescueText = nil
		if tier.SetPieces ~= true then
			p.setPiece = nil
			p.radius = nil
		end
		table.insert(out, p)
	end
	return out
end

function CallRamp.cap(tier: any, players: number, perExtra: number?): number?
	local cap = tonumber(tier.FireCap)
	if not cap then
		return nil
	end
	return cap + math.max(0, math.floor(players) - 1) * math.max(0, perExtra or 0)
end

function CallRamp.bucket(index: number): string
	local i = math.max(1, math.floor(index))
	if i <= 5 then
		return tostring(i)
	elseif i <= 10 then
		return "6-10"
	end
	return "11+"
end

-- What the one objective chip says. o: fires (burning), rescues (still to carry out), wave (a follow-up wave is
-- still to come), doneAt (server time the call completes, 0 = not yet), now (server time).
export type ChipObs = { fires: number, rescues: number, wave: boolean, doneAt: number, now: number }
function CallRamp.chip(o: ChipObs): (string, number)
	if o.doneAt > 0 then
		return "done", math.max(0, math.ceil(o.doneAt - o.now))
	elseif o.fires > 0 then
		return "fires", o.fires
	elseif o.rescues > 0 then
		return "rescue", o.rescues
	elseif o.wave then
		return "wave", 0
	end
	return "none", 0
end

return CallRamp
