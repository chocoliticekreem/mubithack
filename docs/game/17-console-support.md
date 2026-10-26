# 17. Console support: the whole game on a gamepad

Date: 2026-10-25. Ask: "make the game fully playable on console (Xbox / PlayStation) with a gamepad".
Console was already switched on in the dashboard, so this is code only. PC and touch behave exactly as
before. Everything new only runs when the last input was a gamepad (`InputHints.mode() == "gamepad"`).

How it works:

- **`ClientLib/GamepadNav`** plus **`Controllers/GamepadController`**. Each menu registers once.
  `HudLayout.modal()` registers its panels automatically, and the results screen and big map register
  themselves. When a menu opens, the cursor (`GuiService.SelectedObject`, drawn as a thick yellow
  outline) lands on its default button: an explicit `GamepadDefault = true`, otherwise the first button
  that isn't a close button, reading from the top left. The panel is a SelectionGroup, so the D-pad
  can't leave it. **B** closes the top menu (the same function as a backdrop click). When the menu
  closes, the cursor goes back to where it was, which usually means nowhere, so **A** jumps again.
  Roblox moves a cursor whose button has just hidden onto the nearest other button. GamepadNav
  overrides that move.
- **D-pad left = MENU.** With no menu open and nothing selected, it puts the cursor on the HUD buttons
  (ACCEPT / GO NOW first, then DISPATCH, STORE, then top-left). A presses the button and B leaves. A
  small "D-PAD ◄ MENU ▼ MAP" reminder sits bottom-left while a gamepad is in use.
- **Prompts:** `PromptConfig.GamepadKeys` (E → X, F → Y, T → R1, anything else → X). PromptController
  sets every prompt's `GamepadKeyCode` from its keyboard key on each client, so builders only choose the
  keyboard key. They need three different buttons because Roblox shows one prompt per button: at the
  truck, the door (E), the seat (F) and the hose (T) all show at once. Before this change the seat and
  door were both X and the hose was Y.
- **Hint text:** `Lib/HintText` maps every key the hints mention to its gamepad button (the table below).
  It also rewrites "W/S" as "R2/L2", "A/D" as "stick" and "SPACE" as "A" for the gamepad.

## Gamepad control map

| Where | Button | Does | Code |
|---|---|---|---|
| On foot | Left stick / right stick | Move / camera (Roblox) | PlayerModule |
| On foot | A | Jump | PlayerModule |
| On foot | R2 | Use the tool in hand (spray, foam, axe, stand the ladder up). With no tool, the left hand | Roblox Tool activation, PhysicsHands |
| On foot | L2 | Free (right) hand: grab or push | PhysicsHands |
| On foot | X | Use the prompt (E): doors, lockers, the mission board, pick up a person, open the truck door | PromptConfig.GamepadKeys |
| On foot | Y | The second prompt (F): kick, slap, feel the door, change call, **drive or ride the truck** | PromptConfig.GamepadKeys |
| On foot | R1 | Grab or stow the hose at the truck or a hydrant (T) | PromptConfig.GamepadKeys |
| On foot | B | Drop what you hold, or put a person down (G) | InvDrop, RescueDrop |
| On foot | L1 (hold) | Throw / YEET (Q). The same button for items and people | InvThrow, RescueThrow (was X: clashed with prompts) |
| On foot | D-pad up | Swap hand ↔ back (1 / 2) | InvSwap |
| Anywhere | D-pad down | Big map (M). Right stick pans it, the cursor is on + / - / centre / X, B closes it | NavBigMap, Minimap |
| Anywhere | D-pad left | MENU: cursor on the HUD buttons (STORE, PASS, NEWS, HELP, DISPATCH, SKIP, GO NOW, ADMIN, settings) | GamepadController |
| A call is ringing | D-pad right | ACCEPT the dispatch call. To DECLINE or pick NO CALLS: D-pad left (lands on ACCEPT), then right | DispatchController |
| At the station / in the truck | D-pad right | RESPAWN / unflip the truck (R), when its button shows | TruckRespawn |
| On foot | R3 | First ↔ third person (V) | FirstPersonController |
| Station | L3 | Emote: wave → facepalm → BLAME (Z / X / C) | SquadController |
| Truck (driver) | R2 / L2 / left stick | Gas / brake and reverse / steer (Roblox vehicle controls into the PR #253 arcade drive, unchanged) | PlayerModule, VehicleController |
| Truck | Right stick | Look around. It is read every frame now: a held stick keeps turning, and the view eases back 0.8 s after you let go | VehicleController padLook |
| Truck | X / Y / R3 | Siren / horn / chase ↔ cab camera | TruckSiren, TruckHorn, TruckCam |
| Truck | A or B | Hop out | TruckExit (jump is off in the seat) |
| Fire heli (pilot, pass) | Left stick / right stick | Fly (camera-relative) / look | HeliController |
| Fire heli (pilot) | R2 or A / L2 | Up / down (keyboard SPACE / Q or SHIFT; touch UP / DOWN) | HeliUp, HeliDown |
| Fire heli (pilot) | X or R1 | DROP the bucket (keyboard CLICK or G; touch DROP) | HeliDrop |
| Fire heli (pilot or rider) | B | Out: the pilot's heli lands itself first (keyboard F; touch OUT; riders also A / SPACE) | HeliExit |
| On foot (heli owners) | D-pad left → SUMMON | Call your heli (keyboard U) | HeliController SummonHeli |
| Any menu | D-pad / left stick, A, B | Move the cursor, press, close (and give focus back) | GamepadNav |
| Any menu | Right stick | Scroll the menu's list | GamepadNav.scroll |

Not used: **Start / Select** (Roblox menus; Select still toggles Roblox's own UI cursor), the
touchpad / Back.

## Screens and flows

| Screen / flow | Gamepad | Status |
|---|---|---|
| Spawn → tutorial card "PUT OUT THE FIRE!" | Reads "Hold R2 to spray your extinguisher at it". SKIP TUTORIAL through D-pad left | OK, seen in playtest |
| Training fire | R2 sprays (Roblox Tool activation) | Code only (needs a real trigger) |
| Locker (X at a locker) | The cursor opens on the first item you can take (not the hose, which lives on the truck). B closes it and the cursor is cleared | FIXED, verified |
| PICK A MISSION board (X) | The cursor opens on the squad's call (`GamepadDefault`). COMING SOON rows are skipped. B closes | FIXED, verified (open, default, B) |
| Mission pads / GO NOW / NOT YET | Walk onto the pad. GO NOW and NOT YET through D-pad left (GO NOW first) | FIXED |
| Dispatch radio: INCOMING CALL card | D-pad right accepts. D-pad left → ACCEPT / DECLINE / NO CALLS. The label reads "ACCEPT ►" | FIXED, verified (accept reached the server) |
| DISPATCH list (CALLS ON/OFF, BACK TO STATION) | D-pad left → DISPATCH chip → A. It is a modal: the cursor goes inside and B closes it | FIXED (modal, code path verified with STORE) |
| Truck: enter, drive, honk, siren, exit | Y drive, R2 / L2 / stick, Y horn, X siren, B or A out | Verified: Y seated you, R2 throttle 1.0, L2 -1.0, X turned the siren on, B hopped out |
| Truck camera, right stick | Polled per frame | Code only (an analog stick can't be simulated) |
| Hose / tools / swap / throw / drop | R1 / R2 / D-pad up / L1 / B | Prompt keys verified (E→X, F→Y, T→R1 on all 427 prompts). Hold-throw is code only |
| Rescues (pick up X, drop B, YEET L1) | RescueThrow moved from X to L1 | FIXED, code only |
| Results: NEXT CALL!, BACK TO STATION | The cursor opens on NEXT CALL! when it shows. The D-pad reaches BACK TO STATION and the offer card. B closes the screen | FIXED, verified (default, B) |
| Pass offer card (#252), BUY / No thanks | Inside the results menu. In the lobby it is a HUD card, reached with D-pad left | FIXED. The D-pad move onto it is code only |
| STORE | Opens on the first BUY (Roblox asks to confirm any purchase). B closes it and the cursor goes back to the STORE chip | FIXED, verified |
| PASS (battle pass) | Opens on the REWARDS tab, on the page of your next tier. L1 / R1 change the page (10 tiers each, the arrows read L1 / R1). Right stick scrolls. B closes. The PASS chip is first in the left chip column (D-pad left) | FIXED, verified (open, default, L1 / R1 paging, B) |
| NEWS / update log | Opens on OK!, not on the notify / favourite buttons. B closes | FIXED, verified (B), default after the fix: code |
| HELP | Opens on GOT IT (never REPLAY). The keycaps show pad buttons (X, Y, R1, HOLD L1, D-PAD...). The GRAPHICS / POP-UPS / EFFECTS settings beside it can be reached (companion guis) | FIXED, verified |
| Settings (GRAPHICS, POP-UPS, EFFECTS) | Buttons beside HELP, reached with the D-pad | OK |
| ADMIN console | Opens on the first tab. B closes it even while the text box has focus. Typing is PC-only | OK, verified |
| Big map | D-pad down. The cursor is on +. Right stick pans. B closes. The help line reads "right stick to pan · + / - to zoom · B to close" | FIXED, verified (open, default, B) |
| Level-up / tier-up cards | Close on their own (no input needed) | OK |

## TV-safe UI

- HUD ScreenGuis use `ScreenInsets.CoreUISafeInsets` (UiKit.screen), which stays inside the
  top-bar and device safe insets.
- On a 10-foot interface (`GuiService:IsTenFootInterface()`): UiKit's viewport scale may go up to 1.5
  (a 1080p TV shows the 1280x720 design at full size, 1.4 before), the top-bar box is 1.15x, and the
  full-bleed results frame shrinks to 90% so NEXT CALL / BACK TO STATION sit inside the TV-safe area.
- No information appears only on hover. The only MouseEnter is the minimap's outline glow.
- Not done: a sweep for small text (labels sized 12-14 that are not TextScaled are about 18-21 px on a
  1080p TV). The LobbyUI strip and the truck hint keep their own 1.4 cap.

## What was verified, and how

Local place `ConsoleTest.rbxlx` (built with make_place, no Team Create) with `InputHintsMode =
"gamepad"`. Gamepad buttons were sent with Studio MCP `user_keyboard_input` (ButtonX/Y/B/R2/L2,
DPadLeft/Right/Down). Those go through ContextActionService and ProximityPrompt input exactly like a
pad. The results screen, dispatch call and pass offer were fired from the server.

Not verified without a real controller: Roblox's own D-pad navigation between buttons and **A**
pressing the selected button (the simulated presses don't drive GuiService navigation), analog sticks
(truck right-stick look, big-map pan, menu scroll) and triggers on Tools. All of these use stock Roblox
behaviour or one line of polling code, but test them once on an Xbox or PlayStation before calling it
done. ForgeProbe: 0 errors.
