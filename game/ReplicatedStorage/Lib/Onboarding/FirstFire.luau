--!strict
-- FirstFire [owner: Onboarding]. Pure logic for the first-30-seconds hook (no Roblox APIs: spec-tested
-- in game/tests/first_fire.spec.luau). FirstFireService / SessionService / OnboardingController use it.
--
--   FirstFire.shouldRun(onboarded: boolean?, inMission: boolean, enabled: boolean) -> boolean
--       a brand-new player (Onboarded == false, not nil = unknown) in the lobby gets the training fire
--   FirstFire.slotFor(n: number, slots: number) -> number      -- 1..slots, round robin
--   FirstFire.pickPad(pads: { { padId, members, capacity } }) -> number?
--       the pad for the auto-queued first call: an empty pad first (your own squad, your call), else
--       the pad with the most people that still has room (ride with strangers), nil if all full
--   FirstFire.bucket(seconds: number) -> string    -- session length bucket for the counters
--   FirstFire.Buckets                               -- { { name, max } } ascending (max = nil: open)
--   FirstFire.card(phase: string?, sinceDone: number, celebrateSeconds: number) -> string?
--       which first-fire card the client shows: "fire" (put it out), "done" (the reward pop: until the
--       auto-queue lands, then at most celebrateSeconds after the fire went out), or nil
local FirstFire = {}

function FirstFire.shouldRun(onboarded: boolean?, inMission: boolean, enabled: boolean): boolean
	return enabled and onboarded == false and not inMission
end

function FirstFire.slotFor(n: number, slots: number): number
	local s = math.max(1, math.floor(slots))
	return ((math.max(1, math.floor(n)) - 1) % s) + 1
end

export type PadInfo = { padId: number, members: number, capacity: number }

function FirstFire.pickPad(pads: { PadInfo }): number?
	local best: PadInfo? = nil
	for _, p in pads do
		if p.members == 0 then
			if not best or best.members ~= 0 or p.padId < best.padId then
				best = p
			end
		end
	end
	if best then
		return best.padId
	end
	for _, p in pads do
		if p.members < p.capacity then
			if not best or p.members > best.members or (p.members == best.members and p.padId < best.padId) then
				best = p
			end
		end
	end
	return if best then best.padId else nil
end

FirstFire.Buckets = table.freeze({
	table.freeze({ name = "lt1m", max = 60 }),
	table.freeze({ name = "1to5m", max = 300 }),
	table.freeze({ name = "5to15m", max = 900 }),
	table.freeze({ name = "15to30m", max = 1800 }),
	table.freeze({ name = "30to60m", max = 3600 }),
	table.freeze({ name = "ge60m" }),
})

function FirstFire.bucket(seconds: number): string
	for _, b in FirstFire.Buckets do
		local max = (b :: any).max
		if max == nil or seconds < max then
			return b.name
		end
	end
	return "ge60m"
end

function FirstFire.card(phase: string?, sinceDone: number, celebrateSeconds: number): string?
	if phase == "burning" then
		return "fire"
	end
	if phase == "done" then
		return "done" -- until the auto-queue lands (a few seconds)
	end
	if phase == "queued" then
		return if sinceDone < celebrateSeconds then "done" else nil
	end
	return nil
end

return FirstFire
