--!strict
-- PromptConfig [owner: G3]. The one set of rules every ProximityPrompt follows, so a kid learns it once
-- (docs/game/16-predictability-audit.md):
--   * Reach: hand-sized things (items, doors, ladders, alarms, people) all work from Reach studs.
--     Big things (the truck, the mission board) may reach further, never less.
--   * Keys: E = use it, F = the second thing on the same object (kick, slap, change call), T = the hose
--     (truck / hydrant only). Gamepad: E -> X, F -> Y, T -> R1 (GamepadKeys below). PromptController sets
--     every prompt's GamepadKeyCode from its KeyboardKeyCode on each client, so a builder only ever
--     picks the keyboard key. Three different buttons, because Roblox shows ONE prompt per button
--     (Exclusivity OnePerButton): at the truck the door (E), the seat (F) and the hose (T) all show at
--     once. Any other key (H honk) -> X. Never A (jump), B (drop), Start / Select (Roblox menus).
--   * Hold: taking, opening and using are instant (0). Only careful jobs hold, and they hold long enough
--     to read (>= HoldMin s) with a filling bar: reviving, splinting, prying, shutting a valve, a hatch.
--   * Look: one cream "[E] Verb" sticker plus a yellow outline on the thing (PromptController); on
--     touch one round verb bubble (TapUseController). Never Roblox's grey default card.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Reach = 10,
	HoldMin = 1,
	UseKey = Enum.KeyCode.E,
	SecondKey = Enum.KeyCode.F,
	HoseKey = Enum.KeyCode.T,
	-- keyboard key name -> gamepad button (docs/game/17-console-support.md)
	GamepadKeys = {
		E = Enum.KeyCode.ButtonX,
		F = Enum.KeyCode.ButtonY,
		T = Enum.KeyCode.ButtonR1,
	},
	GamepadDefault = Enum.KeyCode.ButtonX,
	HighlightColor = Color3.fromHex("#FFE15A"), -- the same yellow as InventoryConfig.HighlightColor
	StickerMaxDistance = 40, -- studs: the sticker fades out past this (Roblox culls the prompt anyway)
})
