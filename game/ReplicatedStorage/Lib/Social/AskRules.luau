--!strict
-- AskRules [owner: Social]. PURE rules for the friendly "Having fun? 👍" card and the INVITE asks
-- (Services/SocialAskService decides, Controllers/SocialAskController draws). No Roblox APIs, so
-- `luau game/tests/social_ask.spec.luau` runs it in CI.
--
-- Roblox has no API to prompt (or detect) a thumbs-up vote, so the card only TELLS the player where the
-- 👍 is, and offers the real prompts: favorite (AvatarEditorService), notify (ExperienceNotificationService)
-- and invite (SocialService). Nothing is ever given in return for any of them (Roblox rules: no rewards for
-- likes, favorites or invites).
--
--   AskRules.Cfg                                     -- the caps and timings (one table, read-only)
--   AskRules.happy(payload, userId, levelledUp) -> boolean
--       a happy moment worth asking after: a call finished with >= MinStars stars, or a level up. Never the
--       rookie call that only counted because time ran out (payload.rookieWin), even if it levelled you up.
--   AskRules.canAsk(state) -> boolean               -- state { loaded, askedThisSession, ever }
--   AskRules.squadmates(payload, userId) -> number  -- other players on this results screen
--   AskRules.inviteNudge(ctx) -> boolean             -- the results-screen "Bring your friends next time!"
--       ctx { squadmates, nudged (this session), offerOnScreen, canInvite }
--   AskRules.calm(ctx) -> boolean                    -- the card may open now (client)
--       ctx { inLobby, onPad, onboarded, tutorial, modal, busy, alive, sinceLobby, sinceOffer, offerUp }
local AskRules = {}

AskRules.Cfg = table.freeze({
	MinStars = 2, -- a call has to go this well to count as a happy moment
	MaxEver = 3, -- the card shows at most this many times per player, ever (profile updates.likeAsks)
	PerSession = 1, -- ...and at most once per session
	LobbySettleSeconds = 8, -- back at the station this long first (level-up / new-gear cards, lobby pass offer)
	ClearSeconds = 3, -- and the screen has been calm this long
	OfferQuietSeconds = 90, -- no pass offer arrived for this long (never the like card and a pass offer together)
	NudgePerSession = 1, -- results-screen invite line, at most this many per session
	EventCap = 8, -- each funnel event is logged at most this many times per player per session
	InviteMessage = "Come fight fires with me!",
})

function AskRules.happy(payload: any, userId: number, levelledUp: boolean): boolean
	if type(payload) == "table" and payload.rookieWin == true then
		return false -- the rookie call that ran out of time: a pity win, not a happy one
	end
	if levelledUp then
		return true
	end
	if type(payload) ~= "table" then
		return false
	end
	local stars = tonumber(payload.stars) or 0
	if stars < AskRules.Cfg.MinStars then
		return false
	end
	-- you have to have been on the call (your stats are on its results)
	if type(payload.stats) == "table" and #payload.stats > 0 then
		for _, s in payload.stats do
			if type(s) == "table" and s.userId == userId then
				return true
			end
		end
		return false
	end
	return true
end

function AskRules.canAsk(state: { loaded: boolean, askedThisSession: number, ever: number }): boolean
	return state.loaded == true
		and (tonumber(state.askedThisSession) or 0) < AskRules.Cfg.PerSession
		and (tonumber(state.ever) or 0) < AskRules.Cfg.MaxEver
end

function AskRules.squadmates(payload: any, userId: number): number
	if type(payload) ~= "table" or type(payload.stats) ~= "table" then
		return 0
	end
	local n = 0
	local me = false
	for _, s in payload.stats do
		if type(s) == "table" then
			if s.userId == userId then
				me = true
			elseif type(s.userId) == "number" then
				n += 1
			end
		end
	end
	return if me then n else 0
end

function AskRules.inviteNudge(ctx: { squadmates: number, nudged: number, offerOnScreen: boolean, canInvite: boolean }): boolean
	return ctx.canInvite == true
		and not ctx.offerOnScreen
		and (tonumber(ctx.squadmates) or 0) >= 1
		and (tonumber(ctx.nudged) or 0) < AskRules.Cfg.NudgePerSession
end

export type CalmCtx = {
	inLobby: boolean,
	onPad: boolean,
	onboarded: boolean,
	tutorial: boolean,
	modal: boolean,
	busy: boolean,
	alive: boolean,
	sinceLobby: number,
	sinceOffer: number,
	offerUp: boolean,
}

function AskRules.calm(ctx: CalmCtx): boolean
	return ctx.inLobby
		and not ctx.onPad
		and ctx.onboarded
		and not ctx.tutorial
		and not ctx.modal
		and not ctx.busy
		and ctx.alive
		and not ctx.offerUp
		and ctx.sinceLobby >= AskRules.Cfg.LobbySettleSeconds
		and ctx.sinceOffer >= AskRules.Cfg.OfferQuietSeconds
end

return AskRules
