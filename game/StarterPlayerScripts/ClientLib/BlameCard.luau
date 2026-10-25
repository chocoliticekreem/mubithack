--!strict
-- BlameCard [owner: Clippable]. The results screen's "BLAME OF THE CALL" sticker (Tizyz rule #5: worth a
-- screenshot): the funniest thing of the call (Lib/BlameOfCall) with the player's avatar headshot, a silly
-- title and a one-line story. Drawn top-right of ResultsController's 1280x720 design frame, right of the
-- stars and above the team strip, so it never covers NEXT CALL!, the pass offer card (bottom-left) or the
-- invite line (top-left). Display only: no buttons, so gamepad / touch navigation is unchanged.
--
--   BlameCard.build(root: Frame, payload: ResultsPayload) -> Frame?   nil when nothing to show
-- Counter: blame_card_shown.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local UiKit = require(script.Parent:WaitForChild("UiKit") :: ModuleScript)
local BlameOfCall = require(script.Parent.Parent:WaitForChild("Lib"):WaitForChild("BlameOfCall") :: ModuleScript)

local BlameCard = {}

BlameCard.Size = Vector2.new(250, 156)
BlameCard.Position = UDim2.fromOffset(1022, 4) -- top-right; the stars end at x 1020, the team strip starts at y 166

function BlameCard.build(root: Frame, payload: any): Frame?
	if type(payload) ~= "table" then
		return nil
	end
	local pick = BlameOfCall.pick(payload.stats, payload.awards)
	if not pick then
		return nil
	end
	local w, h = BlameCard.Size.X, BlameCard.Size.Y
	local card = UiKit.panel(root, "BlameOfTheCall", UDim2.fromOffset(w, h), BlameCard.Position)
	card.Rotation = 3
	card.ZIndex = 3
	card:SetAttribute("Kind", pick.kind)
	card:SetAttribute("UserId", pick.userId)

	local band = Instance.new("Frame")
	band.Name = "Band"
	band.Size = UDim2.new(1, 0, 0, 30)
	band.BackgroundColor3 = Palette.UiRed
	band.BorderSizePixel = 0
	band.ZIndex = 3
	UiKit.corner(band, 12)
	band.Parent = card
	local head = UiKit.label(band, "Header", "BLAME OF THE CALL", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 0), {
		font = UiKit.Header,
		textSize = 20,
		color = Palette.UiCream,
	})
	head.ZIndex = 4

	local shot = Instance.new("ImageLabel")
	shot.Name = "Headshot"
	shot.Size = UDim2.fromOffset(72, 72)
	shot.Position = UDim2.fromOffset(10, 38)
	shot.BackgroundColor3 = Palette.UiWarn
	shot.BorderSizePixel = 0
	shot.ZIndex = 4
	-- rbxthumb loads without a yield; Studio test players (negative ids) just show the yellow tile
	shot.Image = if pick.userId > 0 then `rbxthumb://type=AvatarHeadShot&id={pick.userId}&w=150&h=150` else ""
	UiKit.corner(shot, 36)
	UiKit.stroke(shot, 3)
	shot.Parent = card

	local who = Players:GetPlayerByUserId(pick.userId)
	local name = who and who.DisplayName or ""
	if name == "" then
		for _, s in payload.stats or {} do
			if type(s) == "table" and s.userId == pick.userId and type(s.name) == "string" then
				name = s.name
			end
		end
	end
	local title = UiKit.label(card, "Title", string.upper(pick.title), UDim2.fromOffset(w - 98, 44), UDim2.fromOffset(90, 34), {
		font = UiKit.Header,
		textSize = 19,
		color = Palette.UiRed,
	})
	title.TextWrapped = true
	title.ZIndex = 4
	local nm = UiKit.label(card, "Name", name, UDim2.fromOffset(w - 98, 20), UDim2.fromOffset(90, 82), {
		textSize = 16,
		color = Palette.CoatShadow,
	})
	nm.ZIndex = 4
	local story = UiKit.label(card, "Story", pick.story, UDim2.new(1, -16, 0, 38), UDim2.fromOffset(8, 114), {
		textSize = 14,
	})
	story.TextWrapped = true
	story.ZIndex = 4
	Telemetry.count("blame_card_shown")
	return card
end

return BlameCard
