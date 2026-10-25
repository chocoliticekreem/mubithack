# 14. Friction audit: the first 10 minutes as a brand-new kid

Date: 2026-10-25. Played in Studio (own place) as a fresh profile, twice: once on a desktop viewport
(609x653, then 1129x720) and once on a **phone landscape viewport, 844x390**, with touch forced
(`InputHintsMode = "touch"`, `ForceTouchUI`). No help, no admin shortcuts except where noted (teleports
to skip long drives once a measurement was taken). Cross-checked against the live funnel (22 new
players, Creator Dashboard Funnels / FunnelService).

Lens: Tizyz's checklist (`docs/research/marketing/4ms4cp2mrtM.txt`). (1) Copy how a popular Roblox
game already does each system, so a kid knows it on sight. (2) Mobile first, and "death by a thousand
cuts": many small frictions make the game a chore. (3) Pareto: a proven loop plus about 20% fresh.

## Live funnel that set the priorities

| Step | Players | Lost | Churn |
|---|---|---|---|
| In Truck -> Arrived On Scene | 17 -> 12 | 5 | 29% |
| Arrived -> First Mission Fire Out | 12 -> 7 | 5 | 42% |
| First Mission Fire Out -> Mission Complete | | | biggest drop |

Drives took 40-65 s. Arrival to the first fire out took either 2 s or 73-95 s. 2 of the 5 completions
were timer-forced. The most common last step was "After Mission Complete" (3 players).

## Before / after, measured in playtests

| Measure | Before | After |
|---|---|---|
| First call distance | 1,035-1,229 studs (funnel: 40-65 s drive) | 245 studs, 20 s travel allowance (#237) |
| Burning parts on a solo first call | climbed to the 120 cap within ~90 s ("FIRES LEFT 120": every city call shares the one City fire location's cap) | 3 on arrival, held at 2-6, hard cap of 10 on the site (#237, #246) |
| Rescues on the first call | 5 | 2 (#237) |
| Arrival -> fire out when holding the extinguisher | GRAB THE HOSE could not be done: `[T]` refilled foam, the step waited 60 s | `[T]` hands over the hose; a stuck hose step moves to SPRAY THE FIRE after 20 s (#239) |
| One overheat, solo | SQUAD WIPED, call over, 0 stars | 6 s nap, respawn at the truck, call goes on (#237) |
| Timer runs out on a first call | TIME'S UP, 0 stars | CALL COMPLETE! with at least 1 star (#237) |
| After the results | BACK TO STATION only | NEXT CALL! -> next call dispatched in under 2 s; next-unlock teaser (#241) |
| Phone buttons during the training fire | 4 (DROP, SWAP, THROW, SPRAY) | 1 (SPRAY) (#242) |
| Phone buttons in the truck | 6 | 3 (HONK, SIREN, OUT) (#242) |
| First-call pad countdown | 12 s, four countdowns stacked | 7 s, one card (#242) |

## Ranked friction list

Impact = how many kids it reaches, times how hard it stops them. "Copy" is the popular Roblox game
whose pattern we should follow. Status: FIXED (PR), PROPOSAL (needs review), or NOTE (another lane owns
it, so it isn't touched here).

| # | Friction | Where | Impact | Copy this | Status |
|---|---|---|---|---|---|
| 1 | **GRAB THE HOSE could not be done.** Everyone arrives holding the extinguisher from the training fire, and `[T]` at the truck refilled its foam instead of giving the hose. The first guide step blocked for 60 s while the fire spread, and the extinguisher holds only 5 s of foam. Matches the 42% Arrived -> Fire Out churn. On phones it was worse: the whole truck is one tap target, so tapping near the reel sat you in the back seat instead (fixed in #240). | InventoryService.onReel, TapUseController | Critical | Jailbreak / ER:LC: one prompt on the vehicle hands you its tool, whatever you hold | FIXED #239 (+ #240 for the tap) |
| 2 | **The first call is far away.** 1,000+ studs on a city route a kid can't read yet (funnel: 40-65 s, 29% lost on the drive). | MissionService.chooseSite (`MinDispatchStuds` 700) | Critical | Natural Disaster Survival: the action comes to you within seconds | FIXED #237 |
| 3 | **The first call is too big.** 6 fires plus spread to the 120-part cap, 5 rescues, two escalation phases including a flashover, and a 0-star TIME'S UP if you don't finish. "FIRES LEFT" counted *up* to 120. | MissionService, FireService | Critical | Doors / Piggy chapter 1: the first room is easy, difficulty ramps later | FIXED #237 |
| 4 | **No hook after a call.** The results screen offered only BACK TO STATION, then a 15 s wait and a drive home. | ResultsController | High | Tower Defense Simulator / Doors: a big PLAY AGAIN on the results | FIXED #241 |
| 5 | **Solo players get "SQUAD WIPED".** One overheat ended the call for a kid playing alone (reproduced in the audit). | MissionFlow / SquadService | High | Brookhaven / every simulator: you respawn, there is no fail screen | FIXED #237 |
| 6 | **Can't find the fire on arrival.** Fires are mostly inside. The GPS beam and arrival point face the street, and the R / F / ! markers stack over the truck in the middle of the screen. Then the guide spends its first step on the hose. | MissionGuides, HudController markers | High | Pet Simulator 99 / Jailbreak: one big bouncing world arrow on the single next thing | Partly FIXED #239 (hose step 20 s, "SPRAY THE FIRE! Follow the arrow"); PROPOSAL P5 |
| 7 | **The results screen sat under the phone thumb buttons.** THROW covered BACK TO STATION and swallowed taps. | ResultsController DisplayOrder 10 < ThumbButtons 20 | High (phones) | any modal results screen | FIXED #241 |
| 8 | **Too many buttons on phone.** 4 buttons on the 10-second training fire and 6 in the truck (DROP / SWAP / THROW are useless in a seat). | InventoryController | Medium-high | Grow a Garden: few, big HUD buttons; Jailbreak: vehicle buttons only in the vehicle | FIXED #242 |
| 9 | **Four countdowns at once on the first-call pad,** plus a 12 s dead wait right after the tutorial fire (where 2 players quit). | LobbyController + OnboardingController | Medium | Natural Disaster Survival: one round timer | FIXED #242 |
| 10 | **The camera clips into the character or a wall after OUT.** The helmet fills the screen on the first moment at the scene. | VehicleController (exit spot / camera) | Medium | Brookhaven: exit beside the door, camera keeps its distance | NOTE (vehicle lane) |
| 11 | **The guide says DROP THEM AT THE TRUCK** although carrying someone outside already counts (#217). | MissionGuides | Medium | | FIXED #239 (GET THEM OUTSIDE!) |
| 12 | **Screen-wide color washes:** the yellow GPS beam at the arrival point and the red station alarm tint drown the HUD and the scene. | NavigationController beam, AlarmController | Medium | Jailbreak: thin beams, no full-screen tint | PROPOSAL (Calm mode already exists; make it the default on phones) |
| 13 | **Duplicate or stale instructions:** a "FIRST HOUSE FIRE! Follow the GPS" card that stays after arrival, an "ON SCENE! Grab your gear from the truck" toast plus a GRAB THE HOSE card, and on foot the turn card ("Turn right in 59 m") disagrees with the marker (22 m). | MissionGuideController, NavigationController | Medium | one instruction at a time (Grow a Garden tutorial) | PROPOSAL |
| 14 | **The hose rope loops** round the player and truck in big yellow and red coils that read as noise. | HoseLine | Low-medium | | NOTE (G1 lane) |
| 15 | **RESPAWN TRUCK** is a big red button at the station even when nothing is wrong. Kids press red buttons. | VehicleController | Low-medium | Brookhaven: a spawn-car menu, not a red panic button | NOTE (vehicle lane) |
| 16 | **Two ways to start a call:** pads and the board, or the 911 / DISPATCH radio. On a narrow top bar the label shrinks to "911". | LobbyService, DispatchController | Low-medium | Natural Disaster Survival: one way in | PROPOSAL (NEXT CALL! now covers the loop; keep pads for squads) |
| 17 | **The phone drive hint bar covers the SIREN button,** and the ALARM banner overlaps the GO card. | VehicleController hint bar, HudLayout stack | Low | | NOTE (vehicle lane) / PROPOSAL |
| 18 | **XP only, nothing to spend.** No upgrade to buy between calls, so there is no reason to run "one more". | Economy | High (retention) | Pet Simulator / Cut Grass: upgrades board with Buy 1 / Max | PROPOSAL P1 (doc 15) |
| 19 | **Unlocks are invisible during play.** The next gear unlock was buried in the locker. | ResultsController | Medium | | FIXED #241 (NEXT UNLOCK teaser) |
| 20 | **The floating truck name** "RetailTycoonLover21's TRUCK #1" sits in the middle of the driving view. | VehicleService billboard | Low | | NOTE (vehicle lane) |

Not reproducible from screenshots: Studio's `screen_capture` does not draw particle emitters, so how
visible the flames are from the street couldn't be judged from images (244 enabled emitters were
around the burning house). Check on a real phone.

## Bigger fixes waiting for approval (not built)

- **P1 Coins + upgrades board** (hose power, truck speed, gear) with Buy 1 / Max. See doc 15.
- **P2 Daily goals** ("put out 10 fires", "rescue 3 pets", "do 3 calls"), reward on the NEXT CALL screen.
- **P3 Session-two hook:** daily streak chest and a first-session "come back tomorrow for the Ladder Truck".
- **P4 One clear objective chip on the HUD** ("2 fires left · 1 person inside") replacing the two-row FIRES LEFT / RESCUED panel and the guide card on phones.
- **P5 Fire beacon on arrival:** smoke column and window glow on the burning building, plus a world arrow to the nearest burning part visible from the truck (FireFxController, G1 lane).
- **P6 Calm effects mode on by default on phones,** with no full-screen beam or alarm tints.
- **P7 Exit camera fix** (vehicle lane): after OUT, keep the camera 10+ studs back, facing the site.
