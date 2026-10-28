--!strict
-- HudConfig [owner: G3]. Data only: the decluttered HUD (docs/game/22-declutter.md).
--   HideKeys   PC keys that hide / show the whole game HUD (Controllers/HideUiController). F1 is the one the
--              👁 button and HELP show; ` (Backquote) also works (Mac keyboards send F1 only with fn).
--              Gamepad: D-pad left (HUD buttons) lands on 👁, A presses. Touch: tap 👁 (top left).
--   HiddenAttr Player attr mirrored from the hide state (tests, analytics); the choice lasts the session.
--   PillSeconds  the lobby 🎁 chest pill (RetentionController) opens its full card for this long, then folds
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	HideKeys = { "F1", "Backquote" },
	HiddenAttr = "HudHidden",
	PillSeconds = 5,
})
