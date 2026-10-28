--!strict
-- ComeBack [owner: Retention]. The reasons to come back, as short phone-readable lines (docs/game/21-retention.md).
-- Read-only: Player attrs the server writes (ResultsFlowService: DailyNextWhen / DailyNextDay / DailyNextXp /
-- DailyNextCosmetic / DailyStreakNow; DataService: Level; BattlePassService: PassTier) + DataConfig, the gear
-- unlocks (Lib/Items/Progression) and BattlePassConfig. Used by the results screen (ResultsController) and the
-- lobby card (RetentionController). Every line is a Loc template (Translations/Keys).
--   ComeBack.unlock(player) -> string?    "⭐ NEXT: NEW HELMET AT LEVEL 3!" (the nearest level unlock, or the
--                                          battle pass's next free tier when no level unlock is 1 level away)
--   ComeBack.chest(player) -> string?     "🎁 TOMORROW: DAY 2 CHEST +35 XP" (+ NEW HELMET / NEW HOSE on days 3/5/7)
--                                          or "🎁 TODAY: DAY 1 CHEST +25 XP" (not opened yet: finish a call)
--   ComeBack.streak(player) -> string?    "🔥 2-DAY STREAK" (nil = no streak)
--   ComeBack.card(parent, player, opts?) -> Frame?   the "TOMORROW 🎁 +35 XP" sticker: band (TOMORROW / TODAY +
--       streak), the XP big, the extra (NEW HELMET / the next unlock) under it. opts.width (default 270),
--       opts.unlock (also show the next unlock line), opts.position / opts.anchor. nil = nothing to show yet.
--       Sized for phones: its text is drawn at 26-44 design px (the results screen scales ~0.45 on 667x375).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loc = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Loc") :: ModuleScript)
local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript) :: any
local UiKit = require(script.Parent:WaitForChild("UiKit") :: ModuleScript) :: any

local ComeBack = {}

local function req(path: { string }): any
	local ok, m = pcall(function()
		local cur: Instance = ReplicatedStorage
		for _, name in path do
			cur = cur:WaitForChild(name, 5) :: Instance
		end
		return require(cur :: ModuleScript)
	end)
	return if ok then m else nil
end

function ComeBack.unlock(me: Player): string?
	local level = tonumber(me:GetAttribute("Level")) or 1
	local bestText: string?, bestLevel = nil, math.huge
	local DataConfig = req({ "Config", "DataConfig" })
	if type(DataConfig) == "table" and type(DataConfig.Cosmetics) == "table" then
		for _, c in DataConfig.Cosmetics do
			local at = tonumber(c.level) or 0
			if at > level and at < bestLevel then
				bestLevel = at
				bestText = Loc.t("⭐ NEXT: {1} AT LEVEL {2}!", { if c.slot == "hose" then "NEW HOSE" else "NEW HELMET", at })
			end
		end
	end
	local Progression = req({ "Lib", "Items", "Progression" })
	local ItemDefs = req({ "Lib", "Items", "ItemDefs" })
	if type(Progression) == "table" and type(Progression.nextUnlock) == "function" then
		local id, at = Progression.nextUnlock(level)
		if id and at and at < bestLevel then
			local def = type(ItemDefs) == "table" and type(ItemDefs.get) == "function" and ItemDefs.get(id) or nil
			local name = if type(def) == "table" and type(def.name) == "string" then def.name else tostring(id)
			bestLevel = at
			bestText = Loc.t("⭐ NEXT: {1} AT LEVEL {2}!", { string.upper(name), at })
		end
	end
	-- a level more than one away: the pass's next free tier is usually closer
	if bestLevel > level + 1 then
		local Pass = req({ "Config", "BattlePassConfig" })
		local tier = tonumber(me:GetAttribute("PassTier")) or 0
		local tiers = type(Pass) == "table" and Pass.Tiers
		local nextTier = type(tiers) == "table" and tiers[tier + 1]
		local id = type(nextTier) == "table" and nextTier.Free
		local reward = type(id) == "string" and type(Pass.Rewards) == "table" and Pass.Rewards[id]
		if type(reward) == "table" and type(reward.Name) == "string" then
			bestText = Loc.t("⭐ NEXT: {1} AT PASS TIER {2}!", { string.upper(reward.Name), tier + 1 })
		end
	end
	return bestText
end

function ComeBack.chest(me: Player): string?
	local day = tonumber(me:GetAttribute("DailyNextDay"))
	local xp = tonumber(me:GetAttribute("DailyNextXp"))
	if not day or not xp then
		return nil
	end
	if me:GetAttribute("DailyNextWhen") ~= "tomorrow" then
		return Loc.t("🎁 TODAY: DAY {1} CHEST +{2} XP", { day, xp })
	end
	local cos = me:GetAttribute("DailyNextCosmetic")
	if type(cos) == "string" and cos ~= "" then
		if string.find(cos, "^hose") then
			return Loc.t("🎁 TOMORROW: DAY {1} CHEST +{2} XP + NEW HOSE", { day, xp })
		end
		return Loc.t("🎁 TOMORROW: DAY {1} CHEST +{2} XP + NEW HELMET", { day, xp })
	end
	return Loc.t("🎁 TOMORROW: DAY {1} CHEST +{2} XP", { day, xp })
end

function ComeBack.streak(me: Player): string?
	local n = tonumber(me:GetAttribute("DailyStreakNow")) or 0
	if n < 1 then
		return nil
	end
	return Loc.t("🔥 {1}-DAY STREAK", { n })
end

function ComeBack.card(parent: Instance, me: Player, opts: { [string]: any }?): Frame?
	local o = opts or {}
	local day = tonumber(me:GetAttribute("DailyNextDay"))
	local xp = tonumber(me:GetAttribute("DailyNextXp"))
	if not day or not xp then
		return nil
	end
	local tomorrow = me:GetAttribute("DailyNextWhen") == "tomorrow"
	local unlock = if o.unlock then ComeBack.unlock(me) else nil
	local streak = tonumber(me:GetAttribute("DailyStreakNow")) or 0
	local cos = me:GetAttribute("DailyNextCosmetic")
	local extra = if type(cos) == "string" and cos ~= ""
		then (if string.find(cos, "^hose") then "+ NEW HOSE" else "+ NEW HELMET")
		else Loc.t("DAY {1} CHEST", { day })
	local W = tonumber(o.width) or 270
	local H = if unlock then 166 else 128
	local card = UiKit.panel(parent, "ComeBackCard", UDim2.fromOffset(W, H), o.position or UDim2.new(), o.anchor or Vector2.zero)
	card.BackgroundColor3 = Color3.fromHex("#FFE2A8")
	card.ZIndex = 6
	local band = Instance.new("Frame")
	band.Name = "Band"
	band.Size = UDim2.new(1, 0, 0, 38)
	band.BackgroundColor3 = if tomorrow then Palette.UiWater else Palette.UiWarn
	band.BorderSizePixel = 0
	band.ZIndex = 7
	UiKit.corner(band, 12)
	band.Parent = card
	local head = UiKit.label(band, "Head", if tomorrow then "TOMORROW 🎁" else "TODAY 🎁", UDim2.new(1, -12, 1, 0), UDim2.fromOffset(10, 0), {
		font = UiKit.Header,
		textSize = 28,
		color = Palette.UiCream,
		stroke = true,
		strokeThickness = 2,
		align = Enum.TextXAlignment.Left,
	})
	head.ZIndex = 8
	if streak >= 1 then
		local st = UiKit.label(band, "Streak", Loc.t("🔥 {1}", { streak }), UDim2.fromOffset(90, 38), UDim2.new(1, -96, 0, 0), {
			font = UiKit.Header,
			textSize = 28,
			color = Palette.UiCream,
			stroke = true,
			strokeThickness = 2,
			align = Enum.TextXAlignment.Right,
		})
		st.Name = "Streak"
		st.ZIndex = 8
	end
	local big = UiKit.label(card, "Xp", Loc.t("+{1} XP", { xp }), UDim2.new(1, -16, 0, 44), UDim2.fromOffset(8, 42), {
		font = UiKit.Header,
		textSize = 44,
		color = Palette.HelmetShield or Palette.UiWarn,
		stroke = true,
		strokeThickness = 2.5,
	})
	big.ZIndex = 8
	local sub = UiKit.label(card, "Extra", extra, UDim2.new(1, -16, 0, 32), UDim2.fromOffset(8, 88), {
		font = UiKit.Header,
		textSize = 26,
		color = if type(cos) == "string" and cos ~= "" then Palette.UiGood else Palette.UiInk,
	})
	sub.ZIndex = 8
	if unlock then
		local u = UiKit.label(card, "Unlock", unlock, UDim2.new(1, -16, 0, 36), UDim2.fromOffset(8, 124), {
			font = UiKit.Header,
			textSize = 26,
			color = Palette.UiInk,
			scaled = true,
		})
		local cap = Instance.new("UITextSizeConstraint")
		cap.MaxTextSize = 26
		cap.Parent = u
		u.ZIndex = 8
	end
	return card
end

return ComeBack
