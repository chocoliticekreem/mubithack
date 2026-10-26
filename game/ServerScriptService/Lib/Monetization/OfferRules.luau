--!strict
-- OfferRules [owner: Monetization]. PURE: which game pass (if any) to offer a player, and why.
-- No Roblox APIs (spec-tested in game/tests/offer.spec.luau). Services/OfferService feeds it.
--
--   OfferRules.pick(ctx, cfg) -> (key: string?, reason: string?)
--     ctx.moment      "results" (the Blame screen) | "lobby" (small card after a level up)
--     ctx.passes      { { key, forSale, owned } } in store order
--     ctx.rookie      the call was a rookie call (GameConfig.Rookie): never offer
--     ctx.completed   non-rookie calls finished this session, this one included
--     ctx.shown       offers shown this session (every moment)
--     ctx.lobbyShown  lobby cards shown this session
--     ctx.sinceLast   seconds since the last offer was shown (math.huge = none yet)
--     ctx.declined    { [key] = "No thanks" count this session }
--     ctx.rotation    a counter that moves on after every shown offer (rotates the default pick)
--     ctx.signals     { foamEmpty: boolean, rescued: number, levelUp: boolean, passXp: number, bigFire: boolean }
--     cfg = MonetizationConfig.Offers (ResultsEvery, MaxPerSession, MinGapSeconds, MaxDeclines,
--           LobbyCardsPerSession, RescueHero)
--   Reasons: "foam" (your foam ran out -> Unlimited Foam), "level" (levelled up -> Premium Pass),
--   "rescue" (rescued RescueHero+ -> Premium Pass), "passxp" (earned battle pass XP -> Premium Pass),
--   "bigfire" (a big call: fires out + burnt >= BigFire -> Helicopter, results only),
--   "default" (rotation over the passes you can still buy).
--   OfferRules.field(key, moment) -> string   -- the analytics CustomField01 value ("UnlimitedFoam_results")

export type Pass = { key: string, forSale: boolean, owned: boolean }
export type Signals = { foamEmpty: boolean?, rescued: number?, levelUp: boolean?, passXp: number?, bigFire: boolean? }
export type Ctx = {
	moment: string,
	passes: { Pass },
	rookie: boolean?,
	completed: number,
	shown: number,
	lobbyShown: number?,
	sinceLast: number,
	declined: { [string]: number },
	rotation: number,
	signals: Signals,
}

local OfferRules = {}

local function num(v: any, default: number): number
	return if type(v) == "number" and v == v then v else default
end

-- passes the player could buy right now, in store order
function OfferRules.candidates(ctx: Ctx, cfg: any): { string }
	local maxDeclines = num(cfg.MaxDeclines, 2)
	local out = {}
	for _, p in ctx.passes do
		if p.forSale and not p.owned and num(ctx.declined[p.key], 0) < maxDeclines then
			table.insert(out, p.key)
		end
	end
	return out
end

-- frequency caps: is this moment allowed to show anything at all?
function OfferRules.allowed(ctx: Ctx, cfg: any): boolean
	if ctx.rookie then
		return false
	end
	if ctx.shown >= num(cfg.MaxPerSession, 4) then
		return false
	end
	if ctx.sinceLast < num(cfg.MinGapSeconds, 150) then
		return false
	end
	if ctx.moment == "results" then
		local every = math.max(1, math.floor(num(cfg.ResultsEvery, 2)))
		return ctx.completed > 0 and ctx.completed % every == 0
	elseif ctx.moment == "lobby" then
		return ctx.signals.levelUp == true
			and num(ctx.lobbyShown, 0) < num(cfg.LobbyCardsPerSession, 1)
			and ctx.completed >= 1
	end
	return false
end

function OfferRules.pick(ctx: Ctx, cfg: any): (string?, string?)
	if not OfferRules.allowed(ctx, cfg) then
		return nil, nil
	end
	local list = OfferRules.candidates(ctx, cfg)
	if #list == 0 then
		return nil, nil
	end
	local can: { [string]: boolean } = {}
	for _, k in list do
		can[k] = true
	end
	local s = ctx.signals
	-- relevance first: what just happened on this call
	if s.foamEmpty and can.UnlimitedFoam then
		return "UnlimitedFoam", "foam"
	end
	if s.bigFire and can.Helicopter and ctx.moment == "results" then
		return "Helicopter", "bigfire"
	end
	if can.PremiumPass then
		if s.levelUp then
			return "PremiumPass", "level"
		end
		if num(s.rescued, 0) >= num(cfg.RescueHero, 2) then
			return "PremiumPass", "rescue"
		end
	end
	if ctx.moment == "lobby" then
		return nil, nil -- the lobby card is only for a level up
	end
	-- otherwise rotate over what's left (passxp when Premium comes up and they earned pass XP)
	local key = list[(math.max(0, math.floor(ctx.rotation)) % #list) + 1]
	if key == "PremiumPass" and num(s.passXp, 0) > 0 then
		return key, "passxp"
	end
	return key, "default"
end

function OfferRules.field(key: string, moment: string): string
	return `{key}_{moment}`
end

return OfferRules
