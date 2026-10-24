# Forge UI kit

Reference UI for Forge's coder, fixer, patcher and designer. Forge pastes the rules below plus the 2 to 4
snippets that match the module into the **user message** of UI work (`forge/ui_kit.py`). System prompts
stay frozen. The snippets are self-contained Luau: paste `Theme.luau` once, then any other snippet. They
compile with `luau-compile` (tests/test_ui_kit.py). `PriceBillboard` needs no Theme, so server Scripts
can use it.

| File | Use it for |
|---|---|
| `Theme.luau` | palette, fonts, `corner/stroke/gradient/shadow/tween/pop/punch/screen` |
| `ChunkyText.luau` | any label players must read |
| `StyledButton.luau` | every clickable |
| `Panel.luau` | shop / inventory / upgrade windows |
| `Toast.luau` | short notifications |
| `CurrencyCounter.luau` | coins / gems / cash HUD pill that ticks up |
| `ProgressBar.luau` | XP, level, health, timer, capacity |
| `RewardPopup.luau` | level up, chest, unlock, win |
| `PriceBillboard.luau` | world price tags that turn green when affordable |
| `FloatingText.luau` | "+1" over a world point |

`index.json` holds `name, file, when_to_use, keywords, needs_theme` for selection. When you add a
snippet: one-line header comment, generic (no game-specific names), under ~2.5k chars, add it to the
index, run the tests.

## Rules
- Chunky text: every label gets a dark UIStroke (2.5-4 px). LuckiestGuy for titles/numbers, FredokaOne for body. Never default or thin fonts.
- One palette everywhere: yellow Primary = main action, green Good = affordable/claim, red Bad = close/can't, blue Info = secondary, dark Ink outlines.
- Depth: UICorner 12-18 px, UIStroke border, light-top UIGradient fill, hard drop shadow 4-6 px below.
- Everything moves: appear with a Back-eased UIScale pop (0 -> 1), react with a punch (1.2 -> 1), press squish to 0.9. Tween UIScale, not Size; 0.1-0.4 s, never linear.
- Numbers tick up and pop on change, big values short ("12.5K"); gains flash green, losses red.
- Every action gives feedback: toast, floating "+N" or reward popup. Max 3 toasts.
- Mobile first: 1280x720 offsets under a viewport UIScale (`Theme.screen`), safe insets, buttons >= 44 px, nothing key in the top-left (Roblox menu).
- HUD hugs the edges, centre stays clear; windows open over a dim backdrop with a close X.
- World prices on BillboardGuis: green when affordable, red when not.
- UI is built in code with Instance.new, no image asset ids (emoji/letters for icons), ResetOnSpawn = false.

## Sources
Patterns only; no art or assets from any game.
- Flame and Blame `game/StarterPlayerScripts/ClientLib/UiKit.luau` (viewport UIScale, safe insets, contextual vs border stroke, pop/punch, press squish), `ResultsController.luau` (Back-eased card reveal, gradient backdrop), `BattlePassController.client.luau` (tiered reward cards, toast).
- Roblox Creator Docs, UI appearance modifiers (UICorner, UIStroke, UIGradient, UIPadding, scale vs offset): https://create.roblox.com/docs/ui/layout-and-appearance
- Roblox Creator Docs, UI animation/tweens: https://create.roblox.com/docs/ui/animation
- Roblox DevForum, UIStroke announcement (text vs border stroke, gradient strokes): https://devforum.roblox.com/t/uistroke-studio-beta/1116289
- Roblox DevForum, UI Design Guide (one font family, neutral base + bright accents on interactive elements, stroked buttons, consistency): https://devforum.roblox.com/t/ui-design-guide/2975811
- Roblox DevForum, recreating simulator-style UI (stacked strokes + gradients on buttons): https://devforum.roblox.com/t/how-to-recreate-such-ui-style/1943553
- Roblox DevForum, smooth UI tweening (UIScale over TweenSize for popups): https://devforum.roblox.com/t/smooth-ui-tweening/994529
- Clash Royale UX breakdown (yellow primary button, one-level menu depth, reward presentation): https://www.therookies.co/blog/game-design-ux-best-practices-detailed-breakdown-of-clash-royale/
- Brawl Stars design critique (one big bright Play button): https://ixd.prattsi.org/2025/02/design-critique-brawl-stars/
- Juice / game feel (eased motion, overshoot pop, layered feedback; "Juice it or lose it", Jonasson and Purho): https://gamedeveloper.com/design/squeezing-more-juice-out-of-your-game-design-
- Mobile-first: 70%+ of Roblox players are on phones, 44 px minimum touch target: https://playbooks.com/skills/taozhuo/game-dev-skills/ui-ux
