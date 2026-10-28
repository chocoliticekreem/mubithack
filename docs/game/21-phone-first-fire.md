# 21. Phones: arrive on scene, put out a fire

Date: 2026-10-28. Live Mission funnel, 7 days, Arrived On Scene -> First Fire Out:

| Device | Arrived | First fire out | Quit between |
|---|---|---|---|
| Phone | 369 | 282 | **23.6%** |
| PC | 42 | 38 | 9.5% |

## Root causes

| # | Cause | Where |
|---|---|---|
| 1 | **No pointer to the fire on arrival.** The HUD fire marker hides within 20 m (70 studs), and trucks park closer than that, so on arrival there was no fire marker at all (measured: `FireMarker.Visible = false` with fires 39-55 studs away). On phones (Calm) it also hid beyond 60 m. Fires sit inside buildings, so nothing on screen said where to go. The only pointer was the rookie guide's small arrow, and only after its "GRAB THE HOSE" step. | HudController.placeMarker |
| 2 | **The touch aim assist was narrow and short.** It covered 40 degrees each side of the camera and 30 studs, measured on the flat. A kid whose camera was 55 degrees off, standing 32 studs back, sprayed the whole extinguisher into the air. | ToolController.sprayAim |
| 3 | **The rookie guide pointed away from the fire first.** Step 1/4, "GRAB THE HOSE", put its arrow on the truck reel for up to 20 s, even for kids already holding a working extinguisher. | MissionGuides.Common.hose |
| 4 | **Arriving without a sprayer meant no SPRAY button.** The button only exists while a hose or extinguisher is in hand. An empty hand, a tank in hand, or an empty extinguisher left no button. | ToolController.bindTouch |
| 5 | The NEWS chip sat on the objectives and guide cards during a call (doc 19's open item). | UpdateLogController |

Note: the Mission funnel's "First Fire Out" step only credits the player whose water put the fire out. If a teammate finishes it, you never log it. Phones lose more of those last hits, so some of the 23.6% may be kids who sprayed but didn't get the credit. The new `ArrivalToFireOut` / `ArrivalNoFireOut` events (below) use the same per-player definition. Locks show whether the phone player was aiming at all.

## Fixes

| Fix | Files |
|---|---|
| **On arrival** (your run goes Active), until **you** put out a fire: a yellow beacon column on the nearest burning part of your site, one huge bouncing arrow over it (BillboardGui, always on top, with the distance), and a huge edge arrow when it's off screen. A top banner reads **SPRAY THE FIRE! 12m**. On touch, a second line says "Hop out first!" while you're seated, then "Hold the SPRAY button to put it out!". The HUD's small fire marker hides meanwhile, so there is one arrow. | Controllers/FireCallController (new), HudController (3 lines) |
| **Touch auto-aim lock.** While SPRAY is held, the aim locks onto the nearest burning part within 40 studs in a **100 degree** flat cone. The aim goes straight at it, the stream bends onto it (the low arc that lands on it; the foam puff stretches to reach), and the part gets a yellow outline. The lock sticks to that part until it's out. `Tool/Spray` gains an optional 2nd arg, the locked part. The server checks it is Burning, within 48 studs (LockRange x 1.2) and that the aim points within 50 degrees of it. Then the water goes at the part's nearest point and lands just in front of it when it's beyond the hose's reach. PC and console are unchanged. | Lib/Fire/SprayAssist (new, spec), ToolController, ToolService |
| **SPRAY is always there.** The first time you're on your feet on scene, ArrivalService makes your kit spray-ready once (`InventoryService:ReadySpray`): empty hands get an extinguisher, a sprayer on your back comes to your hand, an empty extinguisher is refilled. An axe in hand is left alone. It never drops anything. SPRAY sits in ThumbLayout's `primary` slot (84 px). | Services/ArrivalService (new), InventoryService |
| The rookie guide's "GRAB THE HOSE" step also counts an extinguisher in hand. | Config/MissionGuides |
| The NEWS chip hides while you're on a call. | UpdateLogController |
| **Telemetry:** `ArrivalToFireOut` (seconds from arrival to YOUR first fire out; F1 device, F2 rookie / call, F3 lock bucket lock0 / lock1-3 / lock4+). `ArrivalNoFireOut` (seconds on scene; F2 ended / left; F3 locks). Counters: `spray_locks`, `spray_lock_rejected`, `arrival_locks`, `arrival_fire_out`, `arrival_no_fire_out`, `arrival_ready_<keep/swap/give/refill/none>`. | ArrivalService, Lib/Onboarding/Funnel, Lib/Analytics/Schema |

New string: "Hop out first!" (Keys + 9 languages).

## Before / after (local place, touch forced, Studio's iPhone 17 Pro emulator, viewport 750x381)

A scripted touch player (client script): it gets out at the scene and walks at the nearest fire. With the camera 55 degrees off the fire, it holds SPRAY from 32 studs back. Same mission (`apartment_trampoline`), extinguisher, `Pass_UnlimitedFoam` off.

| Run | Before | After |
|---|---|---|
| Extinguisher in hand, 55 degrees off, 32 studs | **no fire out in 30 s**, foam 13.6 -> 0 ("Empty!") | **fire out 3.1 s** after leaving the truck (foam 20 -> 18) |
| Empty hands, same | (no SPRAY button) | extinguisher given 0.4 s after getting out, **fire out 2.0 s**, 1 lock, `ArrivalToFireOut` logged ("PC rookie lock1-3": Studio reports PC) |
| Camera 40 degrees off, 22 studs | 2.4 s | (inside both cones) |
| Fire marker on arrival, fires 39-55 studs away | hidden | beacon + big arrow / edge arrow + banner |
| PC (touch attrs off), 45 degrees off | no lock | no lock (unchanged) |

Stream check: locked at 45 degrees off and 31 studs, the visible stream landed 5.7 studs from the part's centre (on its surface). ForgeProbe: 0 errors.

Screenshots: `scratchpad/tycoon-shots/fire-phone/` (session scratchpad). Studio's `screen_capture` draws neither BillboardGuis nor beams, so the 3D arrow and the stream were checked from the live instances, not the images.

## Not done / next

- The exact 667x375 / 844x390 sizes were not tested. The emulator stayed at 750x381 and its device can't be switched from a script. At 750x381 the banner is 258x40 px under the timer, SPRAY is 84 px in the primary slot, and the NEWS chip is gone on calls. The ADMIN chip (admins only) still overlaps the objectives card.
- Not checked on a real phone.
- Watch `ArrivalToFireOut` / `ArrivalNoFireOut` by device for a few days. If phones still trail, the next suspects are walking into the building and the third-person camera inside rooms.
