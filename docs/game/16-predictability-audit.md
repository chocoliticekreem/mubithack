# 16. Predictability audit: the same thing always looks, sounds and works the same

Date: 2026-10-25. Ask: "making the game feel predictable is key in the ui and how things work". A kid
should learn each thing once: one prompt look, one key per job, one reach, one place on screen per
widget, one meaning per colour, and a reason every time an action does nothing.

How this was checked: a code sweep of every `ProximityPrompt`, toast, HUD widget, colour and camera
write (client and server), then a playtest in a local place (`Predictable.rbxlx`, desktop viewport
609x653, plus touch forced with `InputHintsMode = "touch"` / `ForceTouchUI`). Studio's `screen_capture`
does not draw BillboardGuis (a plain magenta test billboard did not show either), so the prompt
stickers were verified by reading the live PlayerGui and pressing keys, not from screenshots.
Not checked on a real phone.

Lanes left alone (other agents were working there): VehicleController / VehicleService / VehicleConfig,
the in-truck ThumbLayout buttons, ResultsController and store / monetization. Their findings are NOTE.

Status: FIXED (PR), PROPOSAL (bigger, needs review), NOTE (another lane owns it).

## The rules (Config/PromptConfig)

| Rule | Value |
|---|---|
| Look | One cream `[E] Verb` sticker over the thing plus a yellow outline (keyboard / gamepad). One round verb bubble on touch (TapUseController). Never Roblox's grey card. |
| Keys | **E** = use it. **F** = the second thing on the same object (kick, slap, change call, feel door). **T** = the hose, only at the truck and hydrants. |
| Reach | 10 studs for anything hand-sized. Big things (truck, mission board) may reach further, never less. |
| Hold | Taking, opening and using are instant. Only careful jobs hold, with a fill bar: revive 3 s, splint 2 s, hatch 2.5 s, hazard valves / lids / pry. |
| Fail | If your action does nothing, a small popup over you says why ("Too far! Get closer", "Locked! Use the axe or kick it", "Empty! Grab the hose at the truck"). Kind `hint`: shown even with POP-UPS: OFF. |
| Colour | Green = good / go. Red = danger. Yellow = the objective / what to do next. |

## 1. Interactions

Before (measured in the playtest place, 427 prompts):

- **Reach:** 7, 8, 9, 10, 12, 13, 14, 18 or 24 studs, with no pattern. The ladder, kick and feel-door
  prompts were 7, doors and alarms 8, items 9.
- **Hold:** 0, 0.1, 0.2, 0.3, 0.35, 0.4 or 0.5 s on simple actions. A 0.3 s hold feels like lag, not a
  hold.
- **Look:** two looks on PC.

| # | Issue | Where | Fix | Status |
|---|---|---|---|---|
| I1 | **Two prompt looks on PC.** Items and the hose had our cream "[E] Grab Axe" sticker with a yellow outline. Doors, ladders, lockers, people, alarms, the pole and hazards had Roblox's dark default card, with different size, text and position, and no outline. | InventoryService (Style Custom) vs everything else | New `PromptController`: every prompt is Style Custom and gets the same sticker plus outline. Hold prompts fill the sticker, two prompts on one thing stack (Open + Kick on a locked door), the label follows ActionText (Grab / Stow Hose, Open / Close), and a click with a free mouse uses it. The sticker moved out of InventoryController. | FIXED #250 |
| I2 | **Reach differs per object** (7-9 studs on doors, ladder, kick, climb, feel door, alarm, pole, hatch, splint, rescue, revive, items, hydrant, hazards). | MapKit, GearService, SmokeService, SchoolBuilder, LobbyService, PhysicsFxService, Twists, RescueConfig, SquadConfig, InventoryConfig | All set to 10. Every server-side check already allows 10 or more (kick Reach+3 = 12, climb +4, carry 12, revive +2, items +4/+6). | FIXED #250 |
| I3 | **Tiny holds on simple actions:** ladder 0.4, alarm 0.3, sundae 0.3, climb 0.35, feel door 0.35, hose reel 0.2-0.5, rescue pick-up 0.5. | same | Set to 0. Holds stay only on careful jobs (revive, splint, hatch, hazard twists). | FIXED #250 |
| I4 | **T meant two things.** T is the hose key, but "Feel door" also used T, so near a truck or hydrant one of them hid the other. Its warning said "Feel the door first! (T)" on phones too. | SmokeConfig.FeelKey | Feel door is F (and gamepad Y, not DPadUp, which is SWAP). The warning drops the key. | FIXED #250 |
| I5 | Leaving touch mode put Roblox's grey card back. | TapUseController.styleFor | Restores Exclusivity only; Style stays Custom. | FIXED #250 |
| I6 | Locked door with smoke: Kick and Feel door are both F, so Roblox shows only the nearer one. | GearService KickPrompt, SmokeService FeelPrompt | Rare (a locked door in a smoke site). Make Feel door a hold on E, or hide Kick while Feel is unread. | PROPOSAL |
| I7 | Truck seat prompts are 8-9 studs with a 0.1 s hold, and the donation board is 7. | VehicleService, MonetizationService | Set them to 10 / instant. | NOTE (vehicle, store lanes) |
| I8 | **Tap bubble verbs** come from ActionText. "Break (axe)" shows BREAK, while the brief's verb set says CHOP. | TapUseController VERBS | Keep BREAK, since it matches the PC sticker. Revisit if the guide text changes to "chop". | NOTE |
| I9 | Locked-door prompt did not show from the street side of one diner door (hip height y 2.9, 6.4 studs away). The same door works from the other side. | diner-Station-1 | Probably a step or curb. Check other city doors with a ForgeTest scan. | PROPOSAL |

## 2. HUD

HudLayout is the layout authority: `stack` (TopCentre: timer 10, objective 20, CALL! 25, alarm 30,
lobby banner 35, toasts 40, lobby toast 45; Left: objectives 10, integrity 20, guide 30), `pin`,
`reserve`, `modal` and `celebrate` (one centre card at a time).

| # | Issue | Where | Fix | Status |
|---|---|---|---|---|
| H1 | **Every level-up showed two centre cards:** "LEVEL N!" (ProfileController), then "LEVEL N!" again (GearController), even with no new gear. | GearController Gear/Unlocked | The gear card only shows when there is new gear. | FIXED #251 |
| H2 | **The lobby toast never hid.** It faded its text but stayed Visible, so the TopCentre stack kept a gap for it. | LobbyController.showToast | Visible = false after the fade. | FIXED #251 |
| H3 | **The guide colour was cyan** (MissionGuides.HighlightColor #5BE0FF). It read as water (UiWater), while the tutorial objective is yellow. | MissionGuides | Yellow #FFC531 (UiWarn), the same as the tutorial. | FIXED #251 |
| H4 | **Red on a neutral button:** the locker CLOSE was red. | GearController | UiPanelDark. | FIXED #251 |
| H5 | **A full throw charge turned red** (reads as danger). | InventoryController | UiGood. | FIXED #251 |
| H6 | **Carrying shows in three places** (HUD card bottom-left, RescueController carry slot, hotbar CARRY slot). The HUD card sits on the phone thumbstick. | HudController carry card | Remove the HUD card and keep the hotbar slot. | PROPOSAL |
| H7 | **Centre cards land at three heights:** level-up 0.62, gear unlock 0.3, tier-up 0.52. | ProfileController, GearController, BattlePassController | One `HudLayout.CentreY` for every celebrate card. | PROPOSAL |
| H8 | **Two toast systems in TopCentre** with different styles (HUD toast: dark pill; lobby toast: bare cream text). | LobbyController | Route lobby toasts through the HUD toast (one queue, dedupe, cap 2). | PROPOSAL |
| H9 | **Widgets shift mid-step:** the integrity bar shows and hides with distance and moves the guide card 60-104 px. The objective card drops 64 px when the timer appears. | StructureFxController, HudLayout | Reserve the slot for the whole run. | PROPOSAL |
| H10 | Left-edge chips (PASS, NEWS, ADMIN, HELP) are placed by hand in separate guis and can overlap the Left stack on short phones. | several | HudLayout stack "Chips": PASS, NEWS, INVITE, HELP, ADMIN in one column, kept clear of the thumbstick / D-pad legend. | FIXED (battle pass 100 PR) |
| H11 | Yellow also means "button" (`UiKit.button` defaults to UiWarn) and blame (`kindColor("blame")`). | UiKit | Default buttons to UiPanelDark; give blame its own orange. Touches every screen, so review first. | PROPOSAL |
| H12 | Six greens (#3B6E4A ACCEPT / GO NOW, #2E9E44 locker, integrity green, the WorldPopup pastel, UiGood). | DispatchController, OnboardingController, GearController, StructureFxController | Keep the dark greens where they are text on cream (contrast). Swap the button greens to UiGood with ink text once contrast is checked. | PROPOSAL |
| H13 | Thumb buttons are never `HudLayout.reserve`d, so edge arrows can sit on SPRAY / JUMP. | ThumbLayout | Reserve in `makeButton`. | NOTE (touch-driving lane is editing ThumbLayout) |
| H14 | The Fanfare banner covers the timer and the CALL! card (outside HudLayout, DisplayOrder 60). | FanfareController | Add it to TopCentre. | NOTE (store lane) |

## 3. Rules and feedback

| # | Issue | Where | Fix | Status |
|---|---|---|---|---|
| R1 | **The hose stream looked longer than it worked.** The visible arc lands about 45 studs out, but water only counted to 30 (FireConfig.HoseRange). Spraying a fire 31-45 studs away looked like a hit and did nothing. | FireConfig | HoseRange 42: if the water reaches it, it counts. | FIXED #251 |
| R2 | **Empty extinguisher: silence.** Both client and server skipped the spray without a word. | ToolController spray loop | "Empty! Grab the hose at the truck" over you, at most every 2.5 s. | FIXED #251 |
| R3 | **Locked door with bare hands: silence** (a push did nothing). The prompt said "Locked! Use the axe" without mentioning the kick. | HandsService PushDoor, ToolService | "Locked! Use the axe or kick it" for both. | FIXED #251 |
| R4 | **Revive failed silently** when too far or on another squad (the reason from SquadRules was dropped). | SquadService._tryRevive | "Too far! Get closer" / "Not your squad!". | FIXED #251 |
| R5 | **Hose reel / hydrant / gear rack out of range: silence.** | InventoryService onReel, onStock | "Too far! Get closer (to the hose)". | FIXED #251 |
| R6 | **Kick too far: silence.** | GearService.kick | "Too far! Get closer". | FIXED #251 |
| R7 | Corrective popups were muted by POP-UPS: OFF. | WorldPopup / PopupLogic | New popup kind `hint`: always shown to the player it's about. R2-R6 use it. | FIXED #251 |
| R8 | **The rescue text didn't match the rule.** The HUD said "Bring to the TRUCK!", but bringing someone outside also counts. The guide said "Walk into the glowing drop zone", but nothing glows (the drop-off is invisible). | HudController, MissionGuides | "Get them OUTSIDE or to the TRUCK!" and "Walk up to the back of the truck." | FIXED #251 |
| R9 | The rescue zone is invisible until after it counts (the green disc only flashes on success). | RescueService / TruckBuilder RescueDropoff | Faint neon disc at the truck while you carry someone. | PROPOSAL |
| R10 | Foam works further than it looks (visual 12 studs, cools to 30): lenient, but not predictable. Water also passes through walls (no line of sight). | ToolService -> FireService:ApplyWater | Pass a range to ApplyWater; optional LOS ray. | PROPOSAL (G1 fire lane) |
| R11 | Fire out has no number. The "poof" text shows 20% of the time; there is no "+1" or "FIRE OUT". | FireFxController | A rate-limited "OUT!" pop for the sprayer. | PROPOSAL |
| R12 | The crosshair ray can hit the invisible RescueDropoff box near the truck and bend the aim. | TruckBuilder | CanQuery = false, after checking that RescueService does not use a spatial query on it. | PROPOSAL |

## 4. Camera and controls

| # | Issue | Where | Fix | Status |
|---|---|---|---|---|
| C1 | **G / Q meant two things while carrying:** InventoryController and RescueController both bind G / Q and both sink, so whichever bound last won. G could drop your axe instead of the person. | InventoryController onDrop / onThrow | With a person in your arms, G / Q always go to the person (inventory passes). | FIXED #251 |
| C2 | A mouse click on a prompt sticker while the mouse is locked would steal the spray click. | PromptController | Clicks count only with a free mouse. | FIXED #250 |
| C3 | Menus vs mouse lock: MenuMouseController frees the mouse while any `Menu=true` panel or HudLayout modal is up and Roblox restores the lock when it closes. Nothing opened without unlocking or closed without restoring. | MenuMouseController | Tag every new menu panel `Menu=true`. | OK |
| C4 | The onboarding snaps the camera to the training fire and sets a shoulder offset. It is intentional, but it is the one surprise camera move outside the truck. | OnboardingController | Ease it in over 0.4 s instead of a cut. | PROPOSAL |
| C5 | A latent bug: revive re-locks first person without the lobby check that spawn has (only matters if PhysicsConfig.FirstPerson is turned on). | SquadService:116 | Reuse the spawn check. | PROPOSAL |
| C6 | The exit camera after OUT, and truck camera changes. | VehicleController | | NOTE (vehicle lane; see doc 14 #10) |

## Playtest evidence (local place, desktop)

- All 427 prompts in the world were Style Custom (0 with Roblox's card). Hold times were 0 (372), 2.5
  (hatch, 49) and 0.1 (truck seats, vehicle lane, 6). Reach was 10 on 400 of them; the rest were the
  truck, the board, pads, the bell, the locker and the vehicle / donation prompts.
- At an unlocked diner door the sticker read "E Open". E opened the door and the sticker flipped to
  "E Close".
- At a locked door it showed two stacked stickers, "F Kick door" and "E Break (axe)" (SizeOffset 0 / 1.2).
- Touch forced: 0 stickers and a BREAK bubble. Back to keyboard: the stickers came back and the style
  stayed Custom.
- With POP-UPS: OFF, pressing E at the locked door without an axe sent "Locked! Use the axe or kick it"
  (kind hint) and the client drew it.
- ForgeProbe: 0 errors.
- Not verified in play: the revive, reel, rack, kick-range and empty-extinguisher hints, the hose range,
  and the G / Q carry fix. These were checked by code and Luau specs only.
