# 05 — Content: levels, missions, characters, onboarding

Aspect owner: content. This file covers what is in the world and why the player is there. Mechanics
(fire spread, hose physics, networking) belong to the other `docs/game/*` files. Where this file
needs a mechanic, it names the contract (attribute, tag, counter) and nothing more.

Tags used everywhere below:

- **[v1]**: must work in a solo Studio playtest before code freeze. Parts only, no meshes, no
  vehicle driving.
- **[v2]**: later Forge iterations. Do not block v1 on these.

Units: studs. A Roblox R15 character is about 5 studs tall and 2 wide, and walks at 16 studs/s.
Shared building constants (use these so the agent and devs build to the same grid):

| Constant | Value | Notes |
|---|---|---|
| `FLOOR_H` | 12 | One storey, floor to floor. |
| `WALL_T` | 1 | Wall thickness. |
| `DOOR` | 4 W x 7 H | Locked doors are the same size and carry the `Locked=true` attribute. |
| `WINDOW` | 4 W x 4 H, sill at 3 | Upper-floor windows tagged `JumpWindow` are trampoline points [v2]. |
| `GRID` | 4 | Snap every room and door to a 4-stud grid. |
| Fire point | 2x2x2 invisible Part tagged `FireStart` | Holds a `Fire` instance when lit. The ID goes in the `FireId` attribute. |
| Rescue spawn | 2x2x2 invisible Part tagged `RescueSpawn` | The `Kind` attribute holds `civilian`, `cat`, `dog`, `panda` or `floatguy`. |

---

## 1. Trailer shot list

Source: 70 s trailer, sampled at 1 fps (`sheet_01`–`sheet_08`, 3x3 row-major,
sheet N = seconds 9(N-1)…9N-1). Every frame carries the caption "mix of in-game cinematic and
gameplay". FP means first person, with gloved hands visible.

| t (s) | On screen | Game element it implies |
|---|---|---|
| 0–1 | Desert road at dusk, an RV drives past a wooden fence and dry grass. | Cold open. Rural road and sunset palette. |
| 2 | The RV is gone and a small campfire flickers by the fence post. | **Fire start from a careless civilian.** Fires begin at a point and grow. |
| 3 | FP inside the fire station: truck **67**, hose coils on a red brick wall, a cartoon dog lunging into frame. | **Fire station hub**, station dog (mascot NPC), truck number 67. |
| 4 | School hallway with lockers. A bald NPC pulls the wall **FIRE** alarm while kids walk away. | **Alarm trigger**: an NPC calls it in. The school is a location [v2]. |
| 5 | The same hallway lit red, alarm active. | Alarm state: the whole map goes red/strobe. |
| 6–7 | Close-up of a red ceiling alarm beacon spinning. | **Station alarm beacon** that starts every round. |
| 8 | FP at a workbench: picking up an **axe**, a flashlight and a hose coil. Shelves and an extinguisher behind. | **Tool pickup bench** in the hub (axe, hose, extinguisher). |
| 9–10 | Firefighters **02** and **01** at lockers. 02 packs a bag and 01 looks shocked (googly eyes). Hose coils on the bench. | **Locker room**, helmet numbers, gear-up moment, co-op crew. |
| 11 | Seen from a vehicle window, a guy in a **donut pool float** dangles from a claw over a swimming pool. | **Pool float guy** NPC, a backyard pool. Silly rescue. |
| 12 | FP grabbing a helmet off a shelf stacked with helmets and hose rolls. Red alarm light on the wall. | Helmet rack as the "join crew" interaction. |
| 13 | Motion blur as the player pulls on the yellow turnout coat. | Gear-up transition before the run out. |
| 14–15 | FP connecting a yellow hose to a **red hydrant**. Truck 67 on a suburban street, a house burning behind. | **Hydrant refill**, suburban street, house fire. The core v1 loop. |
| 16 | Night. FP holding the rim of a **rescue trampoline** with two crew. Burning brick apartment block, truck behind. | **Apartment block**, trampoline catch [v2]. |
| 17 | FP climbing a **ladder** up the brick facade at night, fire in a window. | Ladder to upper floors, upper-window entry. |
| 18–20 | A ginger cat in a window, tongue out and **drooling** a puddle onto the sill. Kitchen behind. | **Drooling cat** stuck in a window. Pet rescue. |
| 21–22 | FP at sunset in a **bamboo enclosure**. The player grabs a huge **panda** and the camera tumbles. | **Panda** (zoo/jungle pen). Heavy carry and ragdoll comedy. |
| 23 | Smoky living room. FP spraying the hose while 02 stands in the doorway with a second hose. | Co-op indoor firefight, smoke volume. |
| 24 | The spray hits **02 in the face**. | **Friendly fire with water**: a Blame award. |
| 25–26 | Burning living room (bookshelves, sofa). FP calmly waters a potted flower with a **watering can** while the **ceiling collapses**. | **Wrong-tool joke** (watering can) and **ceiling collapse** hazard. |
| 27 | FP hand inside a huge white puffy smoke/foam cloud. | Extinguisher foam, low visibility. |
| 28 | FP **axe smashing a wooden door**, splinters and smoke. | **Axe breaks a locked door** [v1]. |
| 29–30 | Night city street. The player carries a bald civilian and hands him to firefighter **67**. Hydrant on the kerb. | **Carry and hand-off** between players. Rescued go to the truck. |
| 31–32 | On a lawn in front of a burning house, an **unconscious** NPC with **spiral eyes** gets an **oxygen mask** and wakes up. | **Unconscious civilian, oxygen revive** [v2]. In v1, carrying them is enough. |
| 33–35 | Charred hall (chairs, EXIT sign, embers). Soot-black NPCs sit frozen. One lies on the floor and the player pats him. | **Burnt/soot NPC**: the failure state of a late rescue. |
| 36–37 | A blast knocks soot off and a **rainbow-coloured** NPC stands up. | Joke reveal and cosmetic skin [v2]. |
| 38 | Farm. A farmer leans on a **haystack** smoking. The player plucks the cigarette out. | **Farm and haystack**. The farmer is the fire cause. Remove the ignition source. |
| 39–40 | The farmer stares dazed and the player **slaps** him. | **Slap to wake a dazed NPC** [v2]. |
| 41 | FP **driving** the truck. Ducklings cross a zebra crossing, smoke rising over the suburb ahead. | **Drivable truck** [v2], road hazards (ducks), Blame for running them over. |
| 42–44 | Burning forest. A **walkie-talkie** glows green in hand and is then tossed away. | **Radio** for mission comms. Forest fire. |
| 45–46 | Burning bedroom: a **dog** sits on the bed next to a **guy in a pink donut float** who waves. Fire at the door. | **Dog** and **float guy** rescue targets in one room. |
| 47 | Suburb street. The player's **arm is on fire** and teammate 67 hoses him with an extinguisher. | **Players can catch fire**. Teammates put each other out. |
| 48–49 | Storage units with roll-up doors. A **fuse box with a lever** and a warning sign. 67 stands in a **puddle** with a hose. The lever goes down and 67 is **electrocuted**. | **Storage/garage** location, **wet floor + fuse box** [v2]. Blame. |
| 50–51 | FP gripping a bar overhead with the town far below and a bird flying past. | Launched skyward or hanging from the ladder. Ragdoll/launch comedy [v2]. |
| 52–53 | Burnt field at dusk. A **fire tornado** spins behind a panicking **02**, with truck 67 to the right. | **Fire tornado** event [v2], field/farm map. |
| 54 | Pine forest at dusk, burning logs and grass. | **Forest** location. |
| 55 | FP **crawling** through red smoke past a burning log. | Crouch/crawl under smoke (less damage low down). |
| 56 | FP holding a **detonator** on a dam walkway, a burning city below. | **Dam** location, detonator objective. |
| 57–59 | FP walks the curved dam road with the detonator and throws/presses it. | Finale trigger. |
| 60–62 | A **tidal wave** pours over the dam and floods the burning city. | **Dam + city finale** [v2]: a map-wide extinguish. |
| 63–65 | The crew (helmets 67…) sits in the back of the truck with a **panda** and a **dog** in a flooded town, waving. | Mission-complete scene and rescued pets on the truck. |
| 66–69 | Title card **FLAME AND BLAME**. Two firefighters by a truck hose the burning letters until all are out. | Title screen and results-screen style (hose out the text). |

Recurring details that matter for content:

- Truck number **67** appears on the truck, the bumper plate and a helmet. Helmets **01**, **02** and **67**
  appear on characters. Use 01–04 for players and keep 67 as the truck and station number.
- Every civilian has huge googly eyes, a bald or simple head, and a white tee. Simple shapes suit
  parts.
- Lighting moods: dusk orange (suburb, farm), night blue (apartment, dam), red alarm.

---

## 2. Locations (level specs)

World layout (top view). +X is east and +Z is south. All maps live in one place file and are
separated so streaming is not needed.

```
                Z=-400  forest [v2]
                          |
 farm [v2] ----- STATION (0,0) ----- suburban block [v1]  (X 0..+260, Z +80..+240)
 X=-400                   |
                    storage/garage [v2] (X -160, Z +160)
                          |
   apartment block [v2] (X +400, Z 0)    school [v2] (X +400, Z +300)
                          |
              dam + city finale [v2] (Z +700, separate island)
```

v1 ships only the **Station** and the **Suburban block**, about 100 studs apart, so a run takes
about 6 s.

### 2.1 Fire Station 67 (hub) [v1]

Role: spawn, lobby, gear-up, tool bench, the alarm, and where rescued NPCs are delivered (the
truck parks here in v1).

Footprint 80 x 60, two zones: an **apparatus bay** (truck) and a **locker room**.

```
 N (Z=-30)
 +--------------------------------------------------------------+
 | LOCKERS 01 02 03 04   |  TOOL BENCH (axe, hose, ext.)         |
 | [L][L][L][L]          |  ==========                          |
 |  bench   HELMET RACK  |                    ALARM BEACON (*)   |
 |  ======     [H]       |        APPARATUS BAY                  |
 |                 door  |     +----------------+                |
 |  spawn pads  -->  ||  |     |  TRUCK 67      | (DropZone)     |
 |  (s1..s4)             |     |  22x8x9        |                |
 |                       |     +----------------+                |
 | station dog (o)       |                         HYDRANT (H0)   |
 +-----------------------+---[ BAY DOOR 24 W x 14 H ]------------+
 S (Z=+30) --> road to suburb (16 wide asphalt) heading east/south
 X=-40                                                     X=+40
```

| Item | Position (centre) | Size | Notes |
|---|---|---|---|
| Floor | (0,0,0) | 80 x 1 x 60 | Smooth concrete grey, yellow bay lines. |
| Walls | perimeter | h 16 | Red brick (`Brick` material, 196,90,60). |
| Locker room | X -40..-8 | 32 x 60 | 4 lockers on the north wall, numbered 01–04 by SurfaceGui. |
| Spawn pads s1..s4 | (-30, 0, 10) +4 X each | 3 x 0.2 x 3 | Player spawns. The `SpawnLocation` is neutral. |
| Helmet rack | (-20, 3, -20) | 6 x 4 x 2 | Touch: "Suit up" (sets helmet number, see §5). |
| Tool bench | (+10, 3, -26) | 16 x 3 x 4 | Shows Hose, Axe, (v2: Extinguisher, Watering Can, O2). Proximity prompts. |
| Alarm beacon | (0, 15, 0) | 2 x 2 x 2 neon red | Spins and flashes during `Alarm` state. |
| Truck 67 | (+18, 4.5, 4) | 22 x 9 x 8 | Red body, white stripe, "67" SurfaceGui. The back deck is the **DropZone** (tagged). In v1 it is static, driven in v2. |
| DropZone | truck rear (+30, 3, 4) | 8 x 6 x 8 invisible | Rescued NPC delivered when its carrier enters. |
| Hydrant H0 | (+34, 1.5, 24) | 1.5 x 3 x 1.5 | Refill point. |
| Bay door | south wall, X 6..30 | 24 x 14 | Open during the round, closed in lobby. |
| Station dog | (-30, 0, 24) | dog rig | Wanders. Pettable (cosmetic only). Callback to t=3. |

No fire, hazards or rescues inside the station in v1. [v2] Pole slide from a second floor dorm.

### 2.2 Suburban block (Maple Street) [v1] (main mission map)

Trailer: t=14–15, 41, 47. Dusk palette, white fences, green lawns, hydrant on the kerb.

Footprint 260 x 160. One east–west street with 4 houses (3 used per v1 mission, the 4th is a
decoy/spread target) and one backyard pool.

```
 Z=+80  sidewalk / road from station  ===================================  (16 wide road, Z 88..104)
           H1 hydrant(x=40)                 H2 hydrant(x=140)          H3 hydrant(x=230)
 Z=+108 ---- lawn ---------------------------------------------------------------
        +--------------+     +--------------+     +--------------+     +--------------+
        |  HOUSE A     |     |  HOUSE B     |     |  HOUSE C     |     |  HOUSE D     |
        |  1 storey    |     |  2 storey    |     |  1 storey +  |     |  2 storey    |
        |  "Kitchen"   |     |  "Cat house" |     |  garage      |     |  "Pool house"|
        +--------------+     +--------------+     +--------------+     +--------------+
 Z=+148    x 20..56            x 84..120            x 148..184           x 212..248
                                                                        backyard POOL
                                                                        24x14 x 220..244
 Z=+200 ---- back fence ------------------------------------------------------------
```

Each house lot is 48 W x 72 D with the house at 36 W x 40 D. The front door faces the street
(north).

**House A: "Kitchen fire"**, 1 storey, 36 x 12 x 40

```
 +---------+-----------+        N = street
 | KITCHEN | LIVING    |        D1 front door (unlocked)
 |  F1 *   |  F2 *     |        D2 back door (LOCKED, axe)
 |  stove  |  sofa     |        W1 front window, W2 side window
 +--d--+---+--d--------+
 | BATH |  BEDROOM     |
 |      |  F3 *  R1(o) |
 +------+------D2------+
```

- Fires: F1 at the stove (ignites at t=0). F2 at the sofa (spread target). F3 at the bed
  (spread target).
- Rescue: R1 `civilian` in the bedroom, state **unconscious** (spiral eyes).
- Entry: D1 front (open), D2 back (locked, axe). Interior doors are open.
- Hazards: smoke in the kitchen (reduced visibility, a v1 `ParticleEmitter` only).

**House B: "Cat house"**, 2 storey, 36 x 24 x 40 (trailer t=18–20, 23–26)

```
 GROUND                      UPPER
 +-----------+---------+     +-----------+---------+
 | LIVING    | KITCHEN |     | BEDROOM 1 | BEDROOM2|
 | F4 * sofa | F5 *    |     | F7 *      | W3(cat) |
 | bookshelf |         |     |           |  R2 (c) |
 +---D3--+---+--stair--+     +-----------+---------+
 | HALL  F6 *  | stair |     | landing  F8 *       |
 +-----D4(L)---+-------+     +---------------------+
```

- Fires: F4 sofa (t=0), F5 kitchen (t=0), F6 hall. Upper: F7, F8 (spread up via the stair).
- Rescue: R2 **cat** in the upper window W3 (drooling, sits on the sill facing out). Reach it by
  the stairs, or [v2] place the ladder against W3 from outside.
- Entry: D4 front door **LOCKED** (axe required, trailer t=28). D3 garden door open.
- Hazard: **ceiling collapse** in the living room 40 s after F4 lights, if not extinguished.
  Drop 8x1x8 debris (it does 20 dmg and blocks the path). Trailer t=26.
- Joke prop: a potted flower on the coffee table plus a watering can [v2 tool] (t=25).

**House C: "Garage house"**, 1 storey plus an attached garage 16 x 12 x 20

- Fires: F9 garage workbench (t=0), F10 car (spread, **explodes** after 30 s of burning [v2],
  in v1 it only burns).
- Rescue: R3 `dog` in the garage. The garage roll-up door is closed. Enter through the house door
  then the interior door, or axe the side door.
- Entry: front door open. Garage side door locked.

**House D: "Pool house"**, 2 storey (trailer t=11, 45–46)

- Fires: F11 upstairs bedroom door (t=0), F12 bed.
- Rescues: R4 `floatguy` (guy in pink donut float) on the upstairs bed. R5 `dog` next to him.
  Both are in the same room, so it is a two-player rescue moment.
- Entry: front door open. Upstairs bedroom door **LOCKED** (axe).
- Backyard pool 24 x 14 x 4 deep, `Water` blue Part. Free infinite refill (hose dip) [v1] and
  [v2] the slip/electrocution combo if a powered prop falls in.

Hydrants: H1 (40, 1.5, 106), H2 (140, 1.5, 106), H3 (230, 1.5, 106).

### 2.3 Storage units / garage with fuse box [v2]

Trailer t=48–49. A strip of 8 roll-up storage units, concrete floor, one **fuse box**.

```
 +----+----+----+----+----+----+----+----+   each unit 12W x 12D x 10H, red roll-up door
 | U1 | U2 | U3 | U4 | U5 | U6 | U7 | U8 |   doors: U2, U5, U7 LOCKED (axe)
 +----+----+----+----+----+----+----+----+
 ===== concrete apron 96 x 24 ============   wet-floor zones form where water lands (decal 6x6)
 [FUSE BOX]  at west end, lever, ⚡ sign
```

- Footprint 96 x 40. Fires: U3 (paint cans, t=0), U5 (fireworks: random sparks spread to
  neighbours every 10 s), U7.
- Rescue: R `civilian` locked in U5 ("was looking for his fireworks"), R `dog` in U7.
- **Fuse box**: lever ON by default. Any `Wet` floor tile within 20 studs of a live power cable
  shocks players standing on it (40 dmg plus 2 s stun ragdoll) **unless** the fuse box is OFF. Any
  player can flip it. Flipping it ON while a teammate stands on a wet tile triggers the
  "Shocking Development" Blame award.
- Objective twist: flip the fuse box OFF before hosing U3/U5.

### 2.4 Apartment block [v2]

Trailer t=16–17, 29–30. Night. A 4-storey brick block.

```
 FRONT (street side)                      PLAN per floor (40 x 24)
 +--+--+--+--+   roof Z=48                +---------+---------+
 |W |W |W |W |   floor 4  <- JUMPER R6    | APT x01 | APT x02 |
 +--+--+--+--+   floor 3  <- F fire       +--corridor  (4 wide)+
 |W |W |W |W |   floor 2                  | APT x03 | APT x04 |
 +--+--+--+--+   floor 1  lobby D(L)      +----+stairwell+-----+
 |  [ D ]    |                            
 +-----------+   trampoline zone: 12x12 under each JumpWindow
```

- 40 W x 24 D x 48 H (4 x `FLOOR_H`). Stairwell at the centre back, a fire escape ladder on the
  east side.
- Fires: floor 3, apartments 301 and 302 (t=0). They spread up to floor 4 after 45 s and down to
  2 after 90 s.
- Rescues: R6 `panicking runner` on floor 2 (runs around the corridor). R7 `jumper` at the floor 4
  JumpWindow (counts down 20 s, then jumps). R8 `unconscious` in 302.
- Entry: lobby door LOCKED (axe), fire escape ladder (climb), **JumpWindows** for the trampoline.
- **Trampoline**: a 2–4 player carry item, 10 x 1 x 10. A jumper is caught if it lands on the
  trampoline while at least 2 players hold it (solo: 1 player plus the station prop stand). A miss
  means "ouch" ragdoll, rescue still counted at half points, plus Blame.

### 2.5 School [v2]

Trailer t=4–5, 33–37. Long hallway with lockers, gym, and a charred assembly hall.

```
 +---------------------------------------------------------------+
 | CLASS 1 | CLASS 2 | CLASS 3 |   ASSEMBLY HALL (40x32)          |
 |  F *    |         |  F *    |   rows of chairs, EXIT sign      |
 +--d------+--d------+--d------+   soot NPCs (late-rescue state)  |
 | HALLWAY 80 x 8, lockers both sides, wall FIRE ALARM (pull)     |
 +--D(main)------------------------------------D(fire exit, L)----+
```

- 120 x 48 x 14. Fires: class 1, class 3, assembly hall stage.
- Rescues: 3 `civilian` kids (panicking runners in the hallway) and 1 `unconscious` teacher in
  the hall.
- Hazard: red alarm lighting (low visibility), lockers fall over (8 x 2 x 6) when burned.
- Easter egg: an NPC who wasn't rescued in time turns **soot-black**. Hit them with water and they
  turn **rainbow** (t=36–37).

### 2.6 Farm with haystack [v2]

Trailer t=38–40, 52–53. Dusk, wheat field, wooden fence, haystacks.

```
 +----------------------------------------------------+  160 x 120
 |  WHEAT FIELD (grass parts, flammable, fast spread) |
 |   ~~~~~ fire tornado path (loop, r=30) ~~~~~       |
 |                                                    |
 |  [HAY1] [HAY2]  farmer R9   [BARN 32x20x16]        |
 |  fence ---------------------- D(L) barn door       |
 +-------------------road---------------------+-------+
```

- Fires: HAY1 is lit by the **farmer's cigarette** (t=0). Fire jumps to the field, then the barn.
- Rescues: R9 **dazed farmer** (slap to wake, otherwise he wanders into the fire). R10 `dog` in
  the barn. R11 cow (stretch goal).
- Hazard: **fire tornado** spawns when more than 12 field parts burn at once. It moves along a
  loop path at 8 studs/s, flings players in 6 studs (ragdoll plus 10 dmg) and relights everything it
  passes.

### 2.7 Forest [v2]

Trailer t=42–44, 54–55. Pine forest on a slope.

- 200 x 200, with 40 pine trees (trunk 2x14x2 brown, cone of 3 green wedge tiers).
- Fires: 5 start points on fallen logs. Spread is fast and wind-driven (one direction per round).
- Rescues: R12 lost camper (`civilian`) in a tent at the far end. R13 **panda** escaped from the
  bamboo grove (t=21–22) on the east edge.
- Hazard: **low smoke**. Standing does 2 dmg/s and crouching/crawling does 0 (t=55). The walkie
  radio announces the wind direction.

### 2.8 Dam + burning city (finale) [v2]

Trailer t=56–62. Night. Its own island so it stays separate.

```
     RESERVOIR (water plane, 300 x 200)
 ==========================================  DAM wall 300 W x 60 H x 16 thick, walkway on top (8 W)
   [D1]          [D2]          [D3]          detonator sockets on the walkway
                  |
      spillway ---v--- 60 drop
   +----------------------------------+
   |  CITY: 6x4 grid of blocks         |   each block 20x20, tower heights 16..60
   |  everything burning (24 fires)    |
   +----------------------------------+   250 x 160
```

- Objective: carry 3 detonator charges from the truck to sockets D1–D3 (each one is a heavy
  carry, so walk speed drops 30%), then any player presses the plunger.
- Result: a tidal wave Part (300 x 40 x 20) tweens across the city in 6 s, every fire goes out,
  and NPCs ragdoll-float (no damage). The cinematic plays and the results screen follows.
- Rescue: the **panda** (R14) waits on a rooftop and must be carried to the truck before the
  plunger. If it isn't, the panda surfs the wave and still counts (Blame: "Panda Surfing
  Accident").

---

## 3. Missions

Round contract: lobby, then **Alarm** (5 s), then **Round** (180 s), then **Results** (20 s),
then the lobby. A mission ends early when every fire is out **and** every rescue is delivered
(the "All Clear" bonus).

Score (shared team score, per-player share shown in results):

| Event | Points |
|---|---|
| Fire extinguished (one `FireStart` point fully out) | +50 |
| Rescue delivered to the DropZone | +200 (pets +150, panda +500) |
| Locked door broken | +10 |
| House saved (all of its fires out before the house reaches 100% burn) | +150 |
| All Clear before the timer | + (seconds left x 5) |
| Rescue lost (burned to soot) | −150 |
| Player knocked out | −50 |
| Fire spread event (`fires_spread` +1) | −5 |

Stars use the team score at round end.

### v1 missions (both on Maple Street, about 3 minutes each)

#### M1 "Housewarming" [v1] (tutorial-weight)

- Map: Station plus Maple Street, **House A and House B** active (C and D dark).
- Start fires: F1, F4, F5 lit at t=0. Spread ticks every 8 s (see the fire doc).
- Rescues: R1 unconscious civilian (A), R2 drooling cat (B upper window).
- Locked doors: A-D2 (optional route), B-D4 (front, forces axe use or the garden door detour).
- Objectives (shown in the HUD checklist):
  1. Grab the hose and axe from the bench.
  2. Put out the fires at **House A** (1/1 start points plus any spread).
  3. Rescue the **civilian** from House A and carry them to the truck.
  4. Break into **House B** and save the **cat**.
  5. Optional: save both houses (no house over 75% burned).
- Timer: 180 s. A warning sounds at 60 s and the alarm beeps at 15 s.
- Stars: ★ 500, ★★ 900, ★★★ 1300 (needs both rescues, every fire out, and some time bonus).
- Fail: the timer ends with fewer than 1 rescue delivered. The results still show (Blame always
  plays).

#### M2 "Block Party" [v1] (full chaos)

- Map: Maple Street, **all four houses** active.
- Start fires: F1, F5, F9, F11 at t=0. A **second wave** at t=60 relights F2 or F7 at random
  (the "it reignited!" radio call).
- Rescues: R1 civilian (A, unconscious), R2 cat (B), R3 dog (C garage), R4 float guy plus R5
  dog (D upstairs, locked door).
- Objectives:
  1. Rescue **5 / 5** (counter on the HUD).
  2. Extinguish all fires (counter of active fires).
  3. Optional: no house fully burned.
- Timer: 180 s. Solo players will not finish everything, which is fine because stars scale.
- Stars: ★ 800, ★★ 1500, ★★★ 2300.
- Solo scaling: with 1 player the timer is 210 s and the second wave is skipped.

v1 ships M1 as the default and M2 unlocks after any ★ on M1 (or the dev flag `ForceMission`).

### v2 missions

| ID | Name | Map | Core objective | Timer | Stars (★/★★/★★★) | New element |
|---|---|---|---|---|---|---|
| M3 | Fuse Box Follies | Storage | Flip the fuse OFF, extinguish 3 units, rescue 2 | 180 s | 700/1200/1800 | Wet floor + electrocution |
| M4 | Fourth Floor Leap | Apartment | Rescue 3 (one jumper by trampoline), stop the spread to floor 4 | 210 s | 900/1600/2400 | Trampoline, ladder, unconscious revive with O2 |
| M5 | Fire Drill | School | Pull nothing, rescue 4 runners, extinguish 3 rooms | 180 s | 900/1500/2200 | Panicking runners, soot/rainbow NPC |
| M6 | Hay Now | Farm | Wake the farmer (slap), out-run the fire tornado, save the barn | 180 s | 800/1400/2000 | Slap, fire tornado |
| M7 | Smokey Panda | Forest | Find the panda and camper, crawl under smoke | 240 s | 900/1600/2400 | Wind, crawl, radio |
| M8 | Big Wet Finale | Dam + City | 3 charges to the dam, panda to the truck, then the plunger | 240 s | 1500/2500/3500 | Detonator, tidal wave, driving the truck there |

v2 adds **driving**: each mission starts at the station, and the truck (VehicleSeat, 4 seats)
must be driven to the scene. Duck crossings on the route (t=41): hitting the ducks costs −20 and
gives Blame.

---

## 4. NPC and pet cast

All NPCs are part rigs: head is a 2.5 ball, torso 2x2x1 white tee, limbs 1x2x1, two googly eyes
(white sphere 0.9 with a black sphere 0.4 pupil, offset). Shared attributes: `Kind`,
`RescueState` (`idle` | `carried` | `delivered` | `lost`), `Health` 0–100 (drops 5/s when
touching fire), `Sooty` (bool).

Shared rescue rule [v1]: walk up to the NPC and use the **Pick up** ProximityPrompt (hold 0.5 s).
The NPC welds to the player's front ("bridal carry", t=29). While carrying you can't use tools
and walk speed is ×0.75. Enter the truck's **DropZone** to deliver. Press **Drop** (`G`) to put
the NPC down, which is useful for hand-offs (t=30, another player can pick them up). When an NPC
reaches Health 0 it becomes **soot-black**, `RescueState=lost`, sits down and stops counting.

| NPC | Ver | Look | Behaviour | How rescue works |
|---|---|---|---|---|
| **Unconscious civilian** | v1 | Spiral eyes (decal swap), lying flat | Does not move. Health drops only if fire touches them. | v1: pick up and carry. v2: O2 tank revive (hold 2 s, t=31–32) makes them **walk** to the truck by themselves (+50 bonus vs carrying). |
| **Drooling cat** | v1 | Ginger 2x2x2 body, tongue part, drool puddle (thin Part growing on the sill) | Sits in the window, faces outward, meows every 5 s (audio cue). Drool puddle grows (cosmetic). Wet tile [v2]. | Pick up from inside the room (the sill is a ProximityPrompt from inside). v2: also from the top of the ladder outside. Light, so no speed penalty. |
| **Dog** | v1 | Brown/white, 3x2x1.5, red collar, tongue out | Sits until a player comes within 15 studs, then **follows the nearest player** at 12 studs/s. Gets scared by fire within 6 studs (runs back 10 studs). | **Lead it**: the dog counts as delivered when it reaches the DropZone. Pick up is also possible. Trailer t=45–46, 63. |
| **Guy in pool float** | v1 (M2) | Shirtless, pink donut ring (cylinder torus look from 8 wedges) | Sits on the bed, waves (t=45). Refuses to move without the float. | Heavy carry (speed ×0.6). If dropped into the pool he is "rescued" there (counts, −50, Blame "Wrong Kind of Wet"). |
| **Panicking runner** | v2 | Civilian with arms up, open mouth | Runs a random waypoint loop inside the building at 14 studs/s. Ignores exits. Screams. | **Tackle**: touch them while sprinting to stun 3 s, then pick up. Or block them into a corner. |
| **Stuck in window / jumper** | v2 | Civilian on the sill of a JumpWindow, legs out | 20 s countdown bubble above the head, then jumps. | Trampoline catch (≥2 holders), or reach them from inside before the countdown. |
| **Dazed farmer** | v2 | Overalls, cigarette | Smokes by the haystack, and the cigarette starts HAY1. When dazed he walks slowly toward the nearest fire. | **Slap** (E on the face, t=39–40) wakes him, then he walks to the truck on his own. Taking the cigarette (t=38) earns a bonus. |
| **Panda** | v2 | Black/white, 5x5x4, very round | Wanders inside its zone and sits when tired. Eats bamboo. | Heaviest carry: needs **2 players** holding it (speed ×0.5) or 1 player at ×0.3. Worth +500. Is in the end-of-round truck shot. |
| **Station dog** | v1 | Same as the dog, with a 67 bandana | Wanders the hub and jumps at players (t=3). | Not a rescue. Pettable (cosmetic). |
| **Soot NPC** | v1 visual | All black, eyes still white | Sits, sparks drift off. | Not rescuable (lost). v2: spray with water to turn **rainbow** (+1 achievement, no points). |

---

## 5. Firefighter characters

One crew from **Station 67**. Players are numbered by join order. The number is on the front of
the helmet, on the back of the coat and on their locker.

| Helmet | Colour accent | v1 | v2 role (optional loadout, not exclusive) |
|---|---|---|---|
| **01** | Red helmet, yellow stripe | Anyone: hose plus axe | **Nozzle**: hose tank +50%, faster spray |
| **02** | Red helmet, orange stripe | Same | **Breacher**: axe breaks doors in 1 hit (default 3), can carry the ladder |
| **03** | Red helmet, white stripe | Same | **Medic**: O2 tank revive in 1 s (default 2 s), carries without slowdown |
| **04** | Red helmet, blue stripe | Same | **Driver**: drives the truck, fills tanks at the truck 2x faster, holds the trampoline alone |

Look (all parts on a standard R15 humanoid, applied by `CharacterAdded`):

- Coat: torso and arms recoloured to tan-yellow (226,176,74) with two reflective bands (thin neon
  yellow-silver Parts welded on the forearms, matching the trailer gloves).
- Gloves: dark olive (90,90,50). Pants match the coat.
- Helmet: red half-sphere plus a brim disc, with a SurfaceGui front plate showing `01`–`04`.
- Googly eyes on the face (the same rig as the NPCs), so every firefighter is a cartoon.
- v1 has no stats differences. Roles are flavour and the Blame awards use the number ("Firefighter
  02 is to blame").

---

## 6. Onboarding: the first 60 seconds [v1]

Goal: a Roblox kid who never read anything is spraying water at a fire within 25 s and has
rescued something within 60 s. No text walls. A maximum of 6 words per prompt.

| t | What happens | Teach |
|---|---|---|
| 0–3 | Spawn on a pad in the locker room. Camera faces your numbered locker. Title toast: "**STATION 67, you're 0X**". | Identity, crew number. |
| 3–8 | The station dog runs up and barks. A green arrow and a glow on the **helmet rack**: "Suit up!" The touch plays a 1 s gear-up flash (t=13) and the helmet appears. | Proximity prompts exist. |
| 8–14 | The arrow moves to the **tool bench**: "Grab the hose" then "Grab the axe". Tools fill hotbar slots 1 and 2. | Hotbar, `1`/`2` keys. |
| 14–18 | **ALARM**. The beacon spins, the screen tints red and the radio voice line (text bubble) says "**Fire on Maple Street!**". The bay door opens and a road arrow appears on the ground. | Urgency, the timer starts (180 s HUD at the top). |
| 18–25 | Run out (6 s). The first visible fire is the House A kitchen window. A billboard prompt over the hydrant near the first house: "Hose: hold click to spray". | Spray. Fire shrinks visibly when hit. |
| 25–35 | The tank gauge (bottom-right blue bar) drops. When it is under 25%: "Refill at a hydrant!", with a ring on H1. | Resource loop. |
| 35–45 | The fire in the kitchen is out (+50 pop-up). Ghost footprints lead to the bedroom: an icon over the **unconscious civilian**, "Hold E to carry". | Rescue. |
| 45–55 | While carrying, a truck icon appears on the compass/beam: "Bring them to the truck". | DropZone. |
| 55–60 | Delivered: confetti, +200, and the HUD checklist slides in with the remaining objectives (cat in House B, locked door: "Try the axe"). Tutorial prompts stop and the player is free. | Hand-off to the real mission. |

Rules:

- Tutorial prompts show only on a player's **first round** (saved in the DataStore flag
  `seenTutorial`. If the DataStore is unavailable, use per-session).
- Prompts are world-space BillboardGuis anchored to the object, never modal screens.
- In multiplayer, each player sees their own prompts and the alarm is shared. If someone else
  already took the step (for example, the fire is already out), skip ahead.
- Accessibility: every audio cue also has a text bubble. Red alarm tint is at 30% opacity, never
  full red.

---

## 7. Blame awards (results screen)

Results screen: the title card style from t=66–69 (burning letters hosed out), then one award
card per player for 3 s each, then the team score and stars. Each player gets **at most 2**
awards. Pick by priority (lower number first), with ties broken by the larger stat. Every player
is guaranteed at least one award (fallback #16).

Per-player counters tracked on the server (names match ForgeTelemetry where they exist):
`fires_extinguished`, `rescued`, `doors_broken`, `water_used` (studs³ of spray), `fires_spread`
(spreads that started from a part this player was the last to touch/ignite), `teammate_sprayed_s`,
`teammate_ignited`, `knockouts`, `dropped_npc`, `lost_npc_nearby`, `time_carrying`,
`distance_walked`, `hydrant_refills`, `pets_rescued`, `shocked_teammate`, `ducks_hit`,
`doors_broken_unlocked`, `water_on_nothing`.

| # | Award | Ver | Exact trigger |
|---|---|---|---|
| 1 | **Panda Whisperer** | v2 | Delivered the panda (was the carrier, or one of 2 carriers, on DropZone entry). |
| 2 | **Shocking Development** | v2 | Flipped the fuse box ON while ≥1 teammate stood on a wet tile, so `shocked_teammate` ≥ 1. |
| 3 | **Arsonist (Probably)** | v1 | Highest `fires_spread` on the team and ≥ 3. |
| 4 | **Friendly Fire Hose** | v1 | `teammate_sprayed_s` ≥ 5 s total of water hitting teammates (t=24). |
| 5 | **Hot Potato** | v1 | `dropped_npc` ≥ 2 (dropped a carried NPC anywhere that isn't the DropZone, twice). |
| 6 | **Cat Got Your Hose** | v1 | Delivered the drooling cat. |
| 7 | **Door Hater** | v1 | `doors_broken_unlocked` ≥ 1 (axed a door that was **not** locked), or `doors_broken` ≥ 4. |
| 8 | **Hydrant Hugger** | v1 | `hydrant_refills` ≥ 6, or the highest on the team and ≥ 4. |
| 9 | **Gardener of the Year** | v1 | `water_on_nothing` > 60% of `water_used` (spray that hit no fire, NPC or player). v2 alt: watered the flower with the watering can while the room burned (t=25). |
| 10 | **Crispy Critter** | v1 | Personally caught fire ≥ 2 times, or `knockouts` ≥ 1 from fire. |
| 11 | **Hero of Maple Street** | v1 | Highest `rescued` on the team and ≥ 2. |
| 12 | **Professional Firefighter** | v1 | Highest `fires_extinguished` and ≥ 5. Has the lowest priority among the "good" awards, so the funny ones show first. |
| 13 | **It's Fine, It's Insured** | v1 | Was nearest (≤ 30 studs) to a house when it hit 100% burned. |
| 14 | **Bystander** | v1 | `lost_npc_nearby` ≥ 1 (an NPC turned to soot within 20 studs of this player). |
| 15 | **Duck Hunter** | v2 | `ducks_hit` ≥ 1 while driving (t=41). |
| 16 | **Moral Support** | v1 | Fallback. Every other stat is lowest on the team or zero. "Was definitely there." |
| 17 | **Wrong Kind of Wet** | v1 (M2) | Delivered the float guy to the pool instead of the truck. |
| 18 | **Tornado Chaser** | v2 | Flung by the fire tornado ≥ 2 times. |
| 19 | **Rainbow Connection** | v2 | Turned a soot NPC rainbow with water (t=36–37). |
| 20 | **Lift With Your Legs** | v1 | Highest `time_carrying` on the team and ≥ 40 s. |

**Team Blame line** (shown last, picks one player): the player with the highest
`fires_spread + 3*teammate_ignited + 5*shocked_teammate + 2*dropped_npc` gets "**Firefighter 0X
is to blame.**" With 1 player it always reads "**You are to blame.**" (solo joke).

Solo v1 note: awards still fire for a single player. Comparative triggers ("highest on the team")
reduce to the absolute threshold.

---

## Build order checklist for content (v1)

1. Station hub geometry plus truck prop plus DropZone plus H0 (§2.1).
2. Maple Street road, lots and houses A and B with tagged `FireStart`, `RescueSpawn`, `Locked`
   doors (§2.2).
3. Unconscious civilian and cat rigs plus carry/drop prompt (§4).
4. M1 mission definition (fires, rescues, objectives, timer, stars) (§3).
5. Onboarding prompts (§6).
6. Results screen with v1 awards #3–14, #16, #20 (§7).
7. Houses C and D plus dog and float guy, then M2 (§2.2, §3).
