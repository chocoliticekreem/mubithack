# 18 · Localization

About 51% of players don't speak English (es 15.5%, ru 11.3%, pt 7%, fr 4.2%, id 2.8%, th 2.8%, tr 1.4%,
pl 1.4%, uk 1.4%). English is the source language and the key. Nine languages are hand-translated in
code. Every other language gets Roblox's automatic translation of captured text, once it's enabled on
the dashboard.

## How text gets translated
| Piece | What it does |
|---|---|
| `ReplicatedStorage/Config/Translations/Keys.luau` | every player-facing English string (about 1.7k). `{1} {2}` makes a template |
| `ReplicatedStorage/Config/Translations/<lang>.luau` | `{ [english] = translation }` for es ru pt fr id th tr pl uk |
| `ReplicatedStorage/Lib/LocCore.luau` | pure lookup: exact match, upper-cased English, templates (`"FIRES LEFT  3"` → `"FUEGOS  3"`), nested values, UTF-8 upper |
| `ReplicatedStorage/Lib/Loc.luau` | `Loc.t(text, args?)`, `Loc.translate`, `Loc.lang()`, `Loc.mark`, `Loc.upper`. Detects language from `GetTranslatorForPlayerAsync` |
| `StarterPlayerScripts/Controllers/LocalizationController.luau` | watches every TextLabel/TextButton (PlayerGui + world Billboard/SurfaceGuis) and rewrites English to the player's language as Text changes. Also handles AutoLocalize, fit and fonts (below) |
| `ServerScriptService/Services/LocTableService.luau` | builds LocalizationTable `ForgeStrings` (plain keys) under LocalizationService for Roblox's own AutoLocalize |
| `game/tools/loc_csv.py` | exports the tables as a Creator Dashboard CSV (Localization → upload) |

Most UI code needs nothing: set `label.Text = "SAVE THE PANDA!"` and the watcher translates it. For
dynamic text, never concatenate. Use a template that exists in `Keys.luau`:
`label.Text = Loc.t("FIRES LEFT  {1}", { n })`. Server toasts and popups can keep their backtick
strings, as long as the shape is a key (`"{1} rescued the {2}!"`). The client matches it and
translates the inserted values that are keys themselves.

A template whose fixed text has fewer than 5 letters (`"{1}: {2}"`, `"+{1} XP"`) is strict. It
translates only when every value is a number, a symbol or a key, so a random English sentence never
comes out half-translated.

## AutoLocalize and automatic capture
- Labels the watcher translated get `AutoLocalize = false`, and so do templated English labels like
  `"FIRES LEFT  3"`. That stops one capture entry per number and stops Roblox re-translating our text.
- Everything else keeps `AutoLocalize = true`, so the dashboard's automatic translation covers it
  (map signs we didn't hand-translate, plus every other language).

## Fit and fonts
- When translated text no longer fits a label that isn't TextScaled or AutomaticSize, the label switches
  to `TextScaled` with a `UITextSizeConstraint` capped at its old TextSize. It is rechecked after pop-in
  animations.
- LuckiestGuy, FredokaOne and PermanentMarker have no Cyrillic or Thai. Roblox falls back to a thin sans
  (checked in Studio). For ru/uk those labels switch to Montserrat Heavy/Bold, which has real Cyrillic.
  For th the same family is set to Bold weight, and the fallback follows the weight. Latin languages
  (es pt fr id tr pl) render in the game fonts.

## Testing
- Studio only: set the Player attribute `LocaleOverride = "es"` (or `ru`, `th`, ...) on the server and
  the client switches live.
- `Players.LocalPlayer.LocProbe:Invoke("misses")` (Client datamodel) lists the English text seen on
  screen with no translation. `Invoke("stats")` returns the counts.
- `game/tests/loc.spec.luau` checks that every table key is in `Keys.luau`, and that placeholders,
  line breaks and markup are kept. It also prints coverage.

## Adding a string
Add the English to `Keys.luau` and the translation to each `<lang>.luau`. A missing translation shows
in English (or through Roblox's automatic translation). Keep the keyboard keys, `{n}`, emojis and
`\n`. On-screen button names (DROP, SPRAY, LOCKER, ...) must use the same word everywhere a sentence
mentions them.
