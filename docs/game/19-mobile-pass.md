# 19. Mobile pass: the game on a phone

Date: 2026-10-27. Live report from a phone: "click on truck and puts [you] in, can't pull hose or easily
select items, [hard] to get off truck ... also when first join way too many pop ups at once, hella
confusing."

How it was checked: a local place (`MobileFix.rbxlx`, built with `forge place`, no Team Create). The
Studio window was resized so the 3D viewport was exactly **667x375** (iPhone SE landscape), touch forced
with the Player attributes `InputHintsMode = "touch"` and `ForceTouchUI = true`. Taps were driven with
`Players.LocalPlayer.TapUseTest:Invoke(x, y)` (TapUseController) and thumb / hotbar buttons with real
Studio mouse presses on the button (`user_mouse_input`, which goes through the same InputBegan path as a
touch). A brand-new profile each run (Studio uses in-memory profiles), the tutorial skipped with the
`FirstFireService._douse` / `_savePanda` DevHooks, the call ended with `forge test mission_end --reason
allOut`. Screenshots: `scratchpad/tycoon-shots/mobile-pass/` (session scratchpad, not in git).
Not checked on a real phone (Roblox's real jump button and thumbstick only exist on a touch device).

## 1. Tapping the truck seated you

| Problem | Root cause | Fix | Verified how |
|---|---|---|---|
| Tapping anywhere on a truck sat you in the driver's seat, even when reaching for the hose | `TapUseController.tapAt` treated the whole truck as an IN target, and the truck's hose prompt (`TruckHosePrompt`) lives at the **centre of the chassis**, so a tap on the reel measured 8-15 studs to it and fell through to "get in" (#240 only widened the radius) | The truck body, cab, doors and seats are never a way in. The only way in on touch is a **green IN bubble** (`TapBubbleIn`) pinned to the door you'd use (driver door while the driver seat is free, else the nearest free crew seat; over the middle of the truck if the door is off screen). Tap near the reel / a locker = that thing (measured to the **reel**, not the chassis centre). Anywhere else on the truck: a small "Tap IN to get in" hint | Every visible part of the truck tapped from both sides at three spots along it (see "Truck tap sweep" below): **0 seated** (before: 1 seated through a crew seat, every body tap seated before #240) |
| Getting in needed a tap that also meant other things | one bubble at a time: IN and HOSE fought for it | two bubbles: the cream use bubble (HOSE / GRAB / ...) and the green IN bubble, never on top of each other, and never up in the top HUD band (timer, call cards) | `TapBubble` and `TapBubbleIn` both visible beside the truck, 56 px each |

## 2. The hose on a phone

| Problem | Root cause | Fix | Verified how |
|---|---|---|---|
| The hose couldn't be grabbed from half the truck's sides, and right after getting out | Roblox only treats a ProximityPrompt as shown (and only accepts `InputHoldBegin` on it) when the **prompt's spot is on screen**. `TruckHosePrompt` sits at the chassis centre, which is behind the camera when you stand on one side or at one end (measured: shown at +X / +Z, never at -X / -Z with the follow camera). So the HOSE bubble never appeared and a tap did nothing | New remote `Inventory/Reel` (InventoryService, 3/s): the touch HOSE bubble / button sends the hose prompt and the server runs the same `onReel` (reach checked by `nearSource`, as for the prompt). TapUse also lists the nearest truck's own gear itself instead of trusting PromptShown | HOSE thumb pressed after OUT: `InvHand` Extinguisher -> **Hose**, counters `inv_hose_tap 1`, `inv_hose_out 1` |
| No T-key equivalent on touch | | **HOSE thumb button** (ThumbLayout slot `upfar`) whenever a "Grab Hose" prompt (truck or hydrant) is in reach | Button shows at 52 px beside the cluster after getting out, hides once the hose is in hand |
| Spraying the hose | | SPRAY (ToolController) unchanged | Holding SPRAY 1.5 s with the hose: `water_used` 0 -> 19.2 |
| Hose on your back (#266) | | unchanged | SWAP: hand Hose -> back Hose; tap the BACK tile: back in hand |
| (found on the way) `hoseSource` lookups failing | an Instance used as a key in a weak table can be collected while the Instance lives | strong keys, cleared on Destroying | the remote grabs the hose |

## 3. Picking items: the hotbar

| Problem | Root cause | Fix | Verified how |
|---|---|---|---|
| Tiles were ~40 px on phones | UiKit's viewport scale bottoms out at 0.55 (72 design px x 0.55) | On touch the hotbar gets its own `TouchScale` so a tile is at least `InventoryConfig.TouchTilePx` (60) screen px; keyboard / gamepad unchanged | 667x375: HAND / BACK tiles **60x60** |
| The row could sit under THROW / the thumb cluster | centred row, cluster on the right | The row slides left until it ends 10 px before `ThumbLayout.clusterLeft()`; the empty CARRY tile hides on touch (shows when carrying) | 667x375: tiles x 265-402, cluster starts at 416 |
| "Tap a slot to equip it" | | already: tapping HAND / BACK swaps; tapping the BACK tile puts that item in your hand | Hand tap: hand Extinguisher -> back; Back tap: back -> hand |
| SPRAY stuck small after a drive, SWAP in the big slot | ThumbLayout kept the overflow slot a button got while the truck's HONK held "primary" | Slots are re-laid out on every place / forget (newest wins a contested slot, the rest go back to the slot they asked for) | after OUT: SPRAY 84 px primary, SWAP 52 px above, HOSE 52 px upfar |
| Edge arrows ("!" 41 m) drawn over SWAP | thumb buttons were never `HudLayout.reserve`d (doc 16 H13) | reserved in `makeButton` | |

## 4. Getting out of the truck

| Problem | Root cause | Fix | Verified how |
|---|---|---|---|
| Passengers had a small "OFF" button above the jump button, plus Roblox's jump also threw them out | #253 only moved the **driver's** OUT to the jump spot | Riders get the same big OUT on the jump button's spot, and Roblox's jump hides while they ride (it comes back the moment they're out, however they got out). One word, OUT, for both | Rider in CrewSeat_2: OUT 70 px at the jump spot, Jumping off; pressing OUT: seat nil, Jumping back on |
| A rider who took the wheel lost their OUT | `updateSeated` unbound "TruckExit" when the rider seat went away, after `enterDrive` had bound the driver's OUT under the same name | don't unbind when moving straight to the wheel; hand the jump-off over to the driver | code only |
| Driver OUT | | unchanged (jump spot) | Pressing OUT as driver: seat nil, Jumping back on |
| After OUT the screen was your helmet | the camera came back 3 studs behind the head with the truck behind it | touch: look along the truck at 12+ studs | camera distance after OUT: 3.0 -> **12.5** |
| Truck hint bar ran under SIREN | centred bar, full width | touch: bottom-left, ending before the thumb cluster; riders' hint no longer names a SPRAY button while practice fires are off ("HONK  SIREN  OUT") | screenshot |
| Onboarding said "Tap the truck to hop in" | | "Tap the green IN button to hop in" | |

## 5. First join: one pop-up gate

New `ClientLib/PopupGate` (rules: `Lib/PopupGateRules`, spec `game/tests/popup_gate.spec.luau`).
Pop-ups that open **by themselves** ask it first; things the player opens never do.

1. Until the first call is done (`FirstCallDone == false`, or unknown): only the onboarding flow. Celebration
   cards (LEVEL UP, NEW GEAR, TIER UP), achievement toasts, other players' pass fanfare and every auto
   modal are **dropped**, not queued (a queue would dump them all on the screen when the call ends). What
   they announce is still saved (XP bar, gear, TROPHIES / NEWS dots).
2. After that, one auto modal at a time, and only `Gap` (8) s after the last pop-up or card went away.
3. At most `SessionCap` (2) auto modals a session; in the session a player was new in, `NewbieCap` (1) and
   only the like-ask. (Since doc 21: `NewbieCap` 2, the like-ask and the remind-me ask `notify`.) WHAT'S NEW and the lobby pass offer wait for the next session (the NEWS dot stays).

First join, measured (a screen sampler logging every gui that appears, 667x375, touch):

| Seconds | Before | After |
|---|---|---|
| 0-5 | cold open (+ HELI button for pass owners) | cold open |
| 5 | SPRAY THE FIRE card, SPRAY, hotbar | same |
| panda saved (+0-3 s) | DROP + SWAP + THROW buttons, XP bar, HELP chip, **LEVEL 2!** card, **LEVEL 2: NEW GEAR!** banner, **🏆 ACHIEVEMENT! FIRST RESCUE** toast, first-call card with its countdown, NOT YET, big **3-2-1**, ROLLING OUT banner, GO NOW, pad strip, CALLS bubble | SWAP, XP bar, HELP chip, first-call card with its countdown, NOT YET, GO NOW, pad strip (gate log: `drop celebrate`, `drop achievement`) |
| first call | alarm, arriving bar, guide card, minimap, timer... (the call itself) | same |
| results -> station, still the first session | NEWS / like-ask / lobby offer free to open one after another | one auto modal at most (like-ask); WHAT'S NEW deferred (gate log: `defer news`), the NEWS dot stays |

| Pop-up | Before | Now |
|---|---|---|
| Cold open, tutorial card, SKIP | onboarding | unchanged |
| HELI summon button (pass owners) | over the cold open | HudGate `store` (after the first call) |
| DROP / THROW thumb buttons | appeared the second the panda was saved | touch: from the first finished call |
| LEVEL 2! card + LEVEL 2: NEW GEAR! banner | on top of the first-call card | dropped until the first call is done (HudLayout.celebrate) |
| 🏆 ACHIEVEMENT! FIRST RESCUE toast | same second | dropped until the first call is done (HudController) |
| Big 3-2-1 + ROLLING OUT banner | behind the first-call card's own countdown | hidden for the first call (LobbyController) |
| CALLS bubble from the board | on the first-call pad | hidden while FirstFire is "queued" (TapUseController) |
| Someone else's pass fanfare banner | any time | dropped until your first call is done (FanfareController); your own purchase always shows |
| WHAT'S NEW (UpdateLogController) | after the first call | gate `news`: never in a new player's first session; one at a time, spaced |
| "Having fun? 👍" (SocialAskController) | after a happy moment | gate `like` |
| Lobby pass offer (OfferController) | after a level-up call | gate `offer`: not in a new player's first session |

## 6. The drive on a phone (2026-10-28)

Live, 7 days: Mission funnel In Truck -> Arrived On Scene lost **21.5% on phones** (470 -> 369) vs 8.7% on PC
(46 -> 42), and tablets logged TruckStuck about as often as DriveStart. No autopilot: the kid's push is
always what moves the truck.

Checked in a local place (`DrivePhone.rbxlx`, Studio's iPhone emulator at 750x381, touch forced with
`InputHintsMode = "touch"`, `ForceTouchUI`, `DevTouch`). A scripted "phone kid" (Studio attr `DevDrive`,
through the touch stick shaping): full forward push, coarse thumb steering (0 / ±0.8, full lock + small
push past 70°) toward a point 18 or 30 studs ahead on the GPS route, 0.3 s reaction delay.

| Root cause | Evidence | Fix |
|---|---|---|
| The station car park: the DonationBoard stands right in front of bay 1, and tree **canopies** hang over the kerb across the exit T-junction | Before: the rookie run (look-ahead 18) wedged on `Map.Station.DonationBoard.Board` at 6 s and never moved again (150 s); look-ahead 30 and the long route both wedged on `City.Roads.Tree.Canopy` at (34, 229) at 6 s, 129+ s stopped | Collision group `TruckPass` (VehicleService; `VehicleConfig.TruckPassModels` / `TruckPassParts`): trucks drive through the board and canopies, people still bump into them (1,053 parts) |
| The "Truck reset!" net never fired on a phone | `needsRescue` needed `seat.ThrottleFloat >= 0.5`; a thumb pushing sideways (`TruckDrive.touchStick` cruise) reports 0.15 | Client **AUTO-UNSTICK** (below). The server net also counts a touch push (throttle >= 0.15 or steer >= 0.5 on Phone / Tablet) |
| TruckStuck ~ DriveStart was partly a measuring artefact | LobbyService seats the squad at launch, so a kid reading the call card for 5 s logged TruckStuck `idle` every call | New cause `notstarted` (the truck hasn't rolled since DriveStart). A call that ends while still driving is logged as a quit, not an arrival |
| A rookie's 2nd call could be across town | DispatchService offers (NEXT CALL, radio) used the 250-1,600 stud band; the radio also offered any mission type | Rookies (`GameConfig.Rookie.Calls`): the plain house fire within `Rookie.NearStuds` (150) of them, else the nearest. MissionService's first-call pick was already the nearest (`Rookie.NearestSite`; 284 studs / 407 road studs on one seed, 42 m on another: no site is closer) |

**AUTO-UNSTICK** (VehicleController, any device, `DriveConfig.Unstick*`): pushing 3 s without getting
2.5 studs = stuck. Tries `DriveMath.unstickTries()` spots 5-14 studs behind the truck (away from the push),
a little to each side, nose swung toward the route. A spot counts only with anchored ground within 3 studs of
the ground it stands on, the whole truck box free (things that don't collide with the truck ignored) and a
clear blockcast sweep from here to there, so it never goes through a wall or the map. Small **UNSTUCK!**
toast; `Drive/Unstuck` -> DriveService -> **UnstuckApplied** (value metres left, F2 role, F3 call | free).
No free spot: nothing moves and the "Truck reset!" net stays.

**Route on the phone**: the turn card is bigger, sits in the TopCentre stack right under the ARRIVING bar
and never hides on a call (TURN LEFT / RIGHT, STRAIGHT ON + metres between turns, TURN kept at the corner);
WRONG WAY! shows an arrow that points back along the route. **Route assist** (touch only, on a call,
`DriveConfig.Assist*`): while the kid pushes forward with the stick near centre the turn bends toward a point
26 studs along the GPS line, fading out by 0.35 stick steer, never when the route is more than 50° off the
nose or 40 studs away. The glowing ribbon (#268) shows under the truck on 750x381 (screenshots).

**Phone HUD**: the truck hint is one short line ("Push the stick to drive!") above the thumbstick zone and
left of the thumb buttons, for the first 5 s only; the tutorial card / arrow hide while seated in a truck.

| Run (phone kid) | Before | After |
|---|---|---|
| Rookie first call, look-ahead 18 (407 road studs) | wedged on the DonationBoard at 6 s, **never arrived** (150 s) | **arrived 49 s** (another run 67 s), 3-5 unsticks |
| Rookie first call, look-ahead 30 | wedged on a tree canopy at 6 s, **never arrived** | (same route, see above) |
| Long call, look-ahead 30 (1,995 road studs) | wedged on the same canopy at 6 s, **never arrived** | **arrived 102 s**, 7 unsticks, longest stop 2.9 s |
| Rookie first call on another seed (42 m) | | arrived 6.4 s |
| TruckStuck causes (server) | 3 drives: 6 x `idle` (incl. waiting at launch) | 4 drives: 4 `notstarted`, 5 `wrongway`, 3 `idle`, **0 `blocked`**; 18 UnstuckApplied |
| Rookie NEXT CALL / radio offer | any mission, 250-1,600 studs (seen: "School fire 260 m") | 6/6 offers: house fire, 70 m |

Screenshots (session scratchpad only): `tycoon-shots/drive-phone/` 01 seated hint + turn card,
02 driving with STRAIGHT ON + ribbon, 03 WRONG WAY with the back arrow, 04 UNSTUCK! toast, 05 rookie first
call seated (tutorial card hidden). Not checked on a real phone, or at 667x375 / 844x390 (the emulator
sat at 750x381); the bot is a model of a kid, not a kid.

## Truck tap sweep

Client script: stand 4 studs off each side of the truck at three points along it (front, middle, back),
put the camera 18 studs out, and tap the screen point of every truck part the camera can see
(`TapUseTest:Invoke`), then check `Humanoid.SeatPart`.

| Build | Taps | Seated | What the taps did |
|---|---|---|---|
| Before (#240 code) | 260 | **1** (a crew seat by the reel) | truck=99 (seat-in path), GRAB 94, HOSE 20, STOW 19, no target 24 |
| After | 261 | **0** | "Tap IN" hint 103, GRAB 51, LOCKER 21, HOSE 13, STOW 13 (reel taps from both sides now reach the hose), no target 45 (the ray went past the truck) |

Then the IN bubble itself: pressing `TapBubbleIn` at 844x390 sat the player in the DriveSeat; OUT got
them out again.

## Phone sizes

| | 667x375 | 844x390 |
|---|---|---|
| Hotbar tiles | 60x60, x 265-402 | 60x60, x 353-490 |
| Thumb cluster starts at | 416 | 593 |
| Driver: OUT / HONK / SIREN | 70 / 84 / 52 px | same |
| Rider: OUT at the jump spot | yes, Jumping off while riding | |
| Truck hint bar | ends before SIREN | ends before SIREN (screenshot) |
| Bubbles | 56 px, kept under the top HUD band | IN and GRAB side by side under the call card |

ForgeProbe on the final build: 0 errors.

## Not done / next

- Real-phone check (Roblox's jump button and thumbstick only exist on a touch device).
- The like-ask did not open in 4 minutes back at the station in the test session (its own calm rules:
  `AskRules.calm`); the gate itself is spec-tested and logged `defer news` in the same session.
- The NEWS chip can overlap the objectives card on a call (SKIP TUTORIAL: fixed, see below).
- With nothing in the big "primary" slot (an oxygen tank in hand), the cluster has a gap there.

## Device Emulator pass (750x381, 667x375)

| Problem | Cause | Fix | Measured (Studio, iPhone emulator 750x381, forced touch) |
|---|---|---|---|
| Your own head filled the screen next to a truck / wall | Zoom occlusion pulls the camera in to ~2 studs; Roblox only fades your body under ~1.5 studs. `Player.DevCameraOcclusionMode` is server-only, so the client can't switch to Invisicam | `FirstPersonController`: third person on foot, the camera within `FadeFar` (6) studs of your head / torso fades your body (`LocalTransparencyModifier`, up to 0.9 at `FadeNear` 2.5); back to 0 once the camera is away again. Not while seated (VehicleController owns that) | camera 2.19 studs from the head: body 0.90; 8 studs: 0.00 |
| HOSE thumb button didn't give the hose | The button lived only while the truck was within the IN range (21 studs from the chassis) but the hose prompt reaches 24: right behind the reel it was missing, and at the edge it flickered on / off every refresh, so a tap hit a button being destroyed | Truck gear is looked for out to `GEAR_RANGE` (26); the button lingers 0.8 s past reach and a press re-picks the hose (never re-uses the lingering one while you hold the hose, so a double tap can't stow it). Every thumb button also fires on `GuiButton.Activated` when no Begin went out (emulator / stylus input). Test hook `Player.ThumbTest:Invoke(action)` | 21.5 studs behind the truck: HOSE shown 10/10 samples; press: Extinguisher -> Hose (server `inv_hose_tap`, `inv_hose_swapped`) |
| Locker GRAB bubble did nothing | `use()` called `InputHoldBegin` on a prompt Roblox wasn't showing (off screen / picked from the truck's own list) | Lockers and gear racks go straight to the server, `Inventory/Take` (like `Inventory/Reel`); the server re-checks stock, Enabled, distance, not seated | facing away from Locker_L2: tap -> Extinguisher in hand, locker unstocked, `inv_take_tap` 1 |
| Thumb buttons / bubbles 48-52 px | small slot = 0.75 x the 70 px jump button | `ThumbLayout.MinSmall` 64 px; bubbles 64 px | HOSE 64 px, ToolUse 84 px, GRAB / IN bubbles 64 px |
| Card subtitle ~9 px | `TextScaled` in a 24-unit row at UiKit's 0.55 floor | Small screens: sub line at 15 real px, wrapped (1-3 lines, the card grows), card up to 600 units wide | sub 15.4 px, card 330x48 px |
| SKIP TUTORIAL ~16 px tall | 30 design units x 0.55 | at least 46 real px tall on small screens | 120x46 px |
| GRAB YOUR GEAR stayed up in the truck / forever | the card had no "applies" check | lobby tutorial cards hide while seated and when the step's target is gone (arrow too); a lobby step (gear / board / pad) up `StaleCardSeconds` (120) with no progress hides its card (arrow stays). A card hidden and shown again re-pops (it used to stay hidden for the same step) | DriveSeat: card + arrow hidden; out of the truck: card back |
| HELP chip vs the top card | | measured clear: chip x 7-72, card x 210-540 (750) / 168-498 (667), SKIP x 314-435 | |
