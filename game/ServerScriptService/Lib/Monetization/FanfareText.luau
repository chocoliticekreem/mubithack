--!strict
-- FanfareText [owner: Monetization]. PURE: the words of the big server-wide gift / purchase / donation
-- moment (FanfareService sends them, FanfareController shows them). No Roblox APIs, so
-- game/tests/admin.spec.luau runs it with the `luau` CLI.
--
--   FanfareText.build(info: Info, passes: { PassDef }): Text
--     info.kind "gift"   -> "🎁 GIVER GIFTED RECEIVER THE PREMIUM PASS!"
--     info.kind "pass"   -> "⭐ RECEIVER JUST GOT UNLIMITED FOAM!"
--     info.kind "donate" -> "💖 RECEIVER DONATED R$ 100 TO STATION 67!"
--   Text = { banner (everyone, big), sub (everyone, small), chat (system chat line),
--            title + body (the receiver's own "what did I get" card) }

local FanfareText = {}

export type PassDef = { key: string, name: string, perk: string?, blurb: string? }
export type Info = { kind: string, receiver: string, giver: string?, pass: string?, robux: number? }
export type Text = { banner: string, sub: string, chat: string, title: string, body: string }

local function passDef(passes: { PassDef }, key: string?): PassDef?
	for _, p in passes do
		if p.key == key then
			return p
		end
	end
	return nil
end

-- "UNLIMITED FOAM" -> "Unlimited Foam"
function FanfareText.titleCase(s: string): string
	return (string.gsub(string.lower(s), "(%a)([%w']*)", function(a: string, b: string)
		return string.upper(a) .. b
	end))
end

local function clean(name: string?): string
	local s = string.match(name or "", "^%s*(.-)%s*$") or ""
	s = string.gsub(s, "[\r\n\t]", " ")
	if s == "" then
		return "Someone"
	end
	return string.sub(s, 1, 30)
end

function FanfareText.build(info: Info, passes: { PassDef }): Text
	local who = clean(info.receiver)
	local WHO = string.upper(who)
	if info.kind == "donate" then
		local r = math.max(0, math.floor(tonumber(info.robux) or 0))
		return {
			banner = `💖 {WHO} DONATED R$ {r} TO STATION 67!`,
			sub = "Thank you for keeping the trucks rolling!",
			chat = `[Station 67] {who} donated R$ {r}. Thank you!`,
			title = "THANK YOU!",
			body = `You donated R$ {r} to Station 67. Your name is on the Donation Board in the lobby!`,
		}
	end
	local def = passDef(passes, info.pass)
	local NAME = if def then string.upper(def.name) else string.upper(info.pass or "A GAME PASS")
	local nice = FanfareText.titleCase(NAME)
	local perk = if def and def.perk then def.perk elseif def and def.blurb then `{nice}: {def.blurb}` else nice
	if info.kind == "gift" then
		local giver = clean(info.giver)
		return {
			banner = `🎁 {string.upper(giver)} GIFTED {WHO} THE {NAME}!`,
			sub = `What a generous firefighter!`,
			chat = `[Station 67] {giver} gifted {who} the {nice}!`,
			title = "YOU GOT A GIFT!",
			body = `{giver} gifted you something! You now have {perk}`,
		}
	end
	return {
		banner = `⭐ {WHO} JUST GOT {NAME}!`,
		sub = "Thank you for supporting Station 67!",
		chat = `[Station 67] {who} just got the {nice}!`,
		title = "IT'S YOURS!",
		body = `You now have {perk}`,
	}
end

return FanfareText
