# 01: Core gameplay systems (Flame and Blame, Roblox)

Scope: every mechanic seen in the trailer or stated by the developer, turned into Roblox systems that
can be built. Each one has rules, numbers, the server/client split, state, remotes, telemetry and a
priority. All numbers live in `ReplicatedStorage/Config.luau` so Forge (or a human) can tune them
without touching the logic.

Priority key: **v1** = must work in a solo Studio playtest by **Sat 18:00 feature freeze** (submission
due Sat midnight). **v1.5** = add it if v1 is green by Sat noon. **v2** = after submission or as a
Forge iteration target.

---

## 0. Evidence

### 0.1 Trailer (t = seconds; sheet N, cell k gives t = 9(N-1) + (k-1))

| t | What's on screen | Mechanic it implies |
|---|---|---|
| 0–2 | An RV on a desert road. At t=2 a campfire flares up by the fence | Ignition sources; a wildfire begins from a campfire |
| 3 | Station garage, truck **67**, a dog plaque bouncing on the wall, first-person gloves | Station hub, first-person view |
| 4–5 | School hallway: an NPC pulls the **fire alarm** and the lights go red | The call (alarm) that starts a mission |
| 6–7 | Red rotating beacon at the station | Alarm phase |
| 8 | Workbench with an **axe**, a flashlight or nozzle, and a hose coil | Gear-up / loadout pickup |
| 9–10 | Firefighters **01** and **02** at their lockers; hose coils and a red bag | Numbered helmets, lockers |
| 11 | From a cab window: a civilian in a pool float, lifted in a net over a pool | Hoist rescue (v2 gag) |
| 12–13 | Grabbing a helmet and jacket off the rack, then running | Gear up is physical and timed |
| 14–15 | **Hose screwed onto a hydrant**; a yellow hose line runs to truck 67; a house burns | Hydrant hookup, a hose line, suburb mission |
| 16 | Night apartment block on fire. Two players hold a **rescue trampoline**; a body lies on the ground | Trampoline needs 2 holders; jumpers |
| 17 | Climbing a **ladder** up to a burning window | Ladder access |
| 18–20 | A **cat** drooling in a window | Pet rescue at a window |
| 21–22 | Grabbing a **panda** in a bamboo enclosure | Panda rescue, heavy carry |
| 23 | Smoky living room: player hoses, 02 holds a second hose behind; big **smoke clouds** | Room smoke, hose stream |
| 24 | Jet stream straight at 02's helmet | **Friendly fire with the hose** |
| 25–26 | **Watering can** on a potted flower in a blazing library; at t=26 the **ceiling collapses** | Wrong-tool joke, houseplant rescue, **collapse** |
| 27 | Arm swinging into a white wall of smoke | Thick smoke blocks vision |
| 28 | **Axe through a door**, splinters, a smoke burst behind it | Breakable doors; backdraft puff |
| 29–31 | Carrying a bald civilian; 67 carries another; hydrant on the sidewalk | Carrying people, team rescue |
| 32–33 | Civilian on the lawn with **spiral eyes** gets an **oxygen mask** and comes round | Unconscious state, oxygen revive |
| 34–36 | Charred room, black **soot-covered NPCs** with googly eyes | Burn outcome ("toasted"), failed or late rescue |
| 37–38 | Debris explosion, then a **rainbow-dyed** character | Explosion; paint/chemical blast gag |
| 39 | Farmer by a **haystack** with a cigarette, hand reaching for it | NPC ignition source; confiscate it |
| 40–41 | **Slapping** the dazed farmer | Slap wakes or calms NPCs |
| 42 | **Driving the truck** from the cab; ducklings on a crosswalk; smoke on the horizon | Drivable truck, road gags |
| 43–45 | **Walkie-talkie** in a burning forest, then thrown away | Radio/ping item, throwable |
| 46–47 | Dog and a man in a donut pool float in a burning bedroom | Multiple targets in one room |
| 48 | Player's **arm on fire**; 67 blasts them with an **extinguisher** | **Players catch fire**; teammates put them out |
| 49–50 | **Fuse-box lever** pulled; 67 standing in water is **electrocuted** | Wet floor + power = friendly fire |
| 51–52 | Hanging from a bar over the town, a bird nearby | Ladder or heli hang (v2 gag) |
| 53–54 | **Fire tornado** over a field next to the truck; 02 panics | Fire tornado event |
| 55 | Forest hillside, burning logs | Forest mission |
| 56 | Low view through red-tinted smoke | **Crawling under smoke**, low-health vignette |
| 57–60 | **Detonator** on a dam over a burning city; button pressed, then thrown | Dam finale |
| 61–63 | **Tidal wave** floods the burning city | Scripted mass extinguish |
| 64–66 | Crew in the back of truck 67 with the **panda** and a dog; flooded town | Extract: return to the truck with rescues |
| 67–70 | Title: **FLAME AND BLAME** gets hosed out | Branding |

### 0.2 Developer text (Steam page, press release, FAQ)

- First-person co-op physics comedy for 1–4 players, online only; solo is supported ("you just won't
  have anyone to blame"). Tags include **Time Management**, Physics, Automobile Sim and Party Game.
- "Suit up at the station, grab your gear, rush to the scene. **Hook your hose up to the nearest
  hydrant**."
- "**Hoses with real recoil** ... wild hoses that **throw you across the room**."
- "Axes that go through **doors and walls**."
- "**Water that ruins as much as it saves**" and "**flood a whole house just to save one lucky
  plant**." Water damage counts as damage.
- Hazards: "**live wires, gas, structural collapse and fire tornadoes**." "The fire is the least of
  your problems."
- "**Drag civilians out of the smoke, slap on an oxygen mask**, and bring them back." Targets:
  **civilians, pets, houseplants, one extremely confused panda**. "**Bounce someone to safety off a
  trampoline**."
- "Share the hose, the axe, and the blame." "Your own crew is the real hazard."
- The developer has published no scoring, progression or blame-UI details. Everything in sections
  10–11 is our own design.

---

## 1. Global architecture

### 1.1 Module map (one Forge coder call per file, each under 8k tokens)

| File | Role |
|---|---|
| `ReplicatedStorage/Config.luau` | Every tunable in this doc, grouped by system |
| `ReplicatedStorage/Net.luau` | Creates or gets `ReplicatedStorage.Remotes/*`, one place for names |
| `ServerScriptService/Main.server.luau` | Boots the services in order |
| `ServerScriptService/MapBuilder.luau` | Builds the station and mission maps from parts, tags everything |
| `ServerScriptService/RoundService.luau` | Mission state machine, timer, objectives, success and failure |
| `ServerScriptService/FireService.luau` | Ignition, spread, intensity, fuel, smoke, re-ignition |
| `ServerScriptService/WaterService.luau` | Tanks, refill, spray resolution, puddles, water damage |
| `ServerScriptService/ToolService.luau` | Axe, extinguisher, oxygen, slap, walkie, watering can, trampoline |
| `ServerScriptService/RescueService.luau` | NPC civilians and pets: states and AI |
| `ServerScriptService/CarryService.luau` | Pick up, carry, drop, throw, deliver |
| `ServerScriptService/PlayerStatus.luau` | HP, Air, OnFire, Downed, Stun, revive |
| `ServerScriptService/HazardService.luau` | Electrocution, gas, backdraft, collapse, tornado, live wires |
| `ServerScriptService/BlameService.luau` | Per-player ledger, awards, blame % |
| `ServerScriptService/ScoreService.luau` | Points, stars, property damage |
| `ServerScriptService/TruckService.luau` | Truck seats, tank, travel (teleport in v1, drive in v2) |
| `StarterPlayerScripts/Input.client.luau` | First-person lock, keybinds, tool input sent to remotes |
| `StarterPlayerScripts/HoseFX.client.luau` | Water stream VFX, recoil camera kick |
| `StarterPlayerScripts/HUD.client.luau` | Timer, objectives, tank, HP/Air, pings, results screen |
| `StarterPlayerScripts/ScreenFX.client.luau` | Smoke tint, low-air vignette, electrocution flash, extinguisher white-out |

### 1.2 General rules

- **The server owns everything that matters:** fire state, water application, health, carry,
  blame and score. The client sends intent only (aim direction, button state) and draws the VFX.
- **State lives in Attributes** so the client, ForgeProbe and `DevHook` can all read it without
  extra remotes. Examples: part `Burning/Intensity/Heat/Fuel/Wet`, character `HP/Air/OnFire/Downed`,
  `ReplicatedStorage.RoundState` with `Phase/TimeLeft/Mission/...`.
- **Tags** (CollectionService): `Flammable`, `Room`, `Door`, `BreakableWall`, `Window`, `Hydrant`,
  `TruckZone`, `Rescuable`, `FuseBox`, `GasTank`, `Support`, `Property`, `Puddle`, `LiveWire`.
- **Server checks on every request:** distance (`≤ Config.Reach + 2`), cooldown, equipped tool,
  and that the player is not Downed or Stunned. A request that fails is ignored and counted
  (`remote_rejected`).
- **Remotes** (`ReplicatedStorage.Remotes`):

| Name | Kind | Direction | Payload |
|---|---|---|---|
| `Spray` | RemoteEvent | C→S | `(on: bool, aim: Vector3, mode: "jet"\|"mist")`, max 10 Hz |
| `ToolUse` | RemoteEvent | C→S | `(tool: string, action: "primary"\|"secondary", target: Instance?)` |
| `Carry` | RemoteEvent | C→S | `("pick"\|"drop"\|"throw", target: Instance?)` |
| `Ping` | RemoteEvent | C→S | `(kind: "fire"\|"victim"\|"water"\|"help", pos: Vector3)` |
| `FX` | RemoteEvent | S→C (all) | `(kind: string, pos: Vector3, data: table?)` for explosions, sparks, splat, slap |
| `Notify` | RemoteEvent | S→C | `(text: string, style: "info"\|"warn"\|"blame")` for the toast feed ("02 electrocuted 01!") |
| `Results` | RemoteEvent | S→C (all) | `(resultsTable)`, see §11 |

Interactions that are not aim-based (lockers, hydrant hookup, fuse lever, gas valve, detonator,
revive) use **ProximityPrompts**, which the server handles natively. They need no custom remotes.

---

## 2. Mission and round flow

### 2.1 Player-facing rules

`Lobby → Alarm → GearUp → Travel → Incident → Extract → Results → (Alarm again | Lobby)`

| Phase | Duration | What happens | Exit condition |
|---|---|---|---|
| Lobby | until ≥1 player is ready (solo: auto after 5 s) | Station hub; free roam; the dog plaque bounces | Ready |
| Alarm | 6 s | Red beacon spins, siren plays, lights go red, the call card shows ("Kitchen fire, 12 Elm St, 1 cat inside") | timer |
| GearUp | 30 s max | Lockers: each player picks **2 tool slots** (§4); hose and slap are always carried. Helmet number assigned | All players have gear and are in the truck zone, or the timer runs out (auto-loadout: hose + axe) |
| Travel | v1: 8 s fade with a cab view; v2: driven, 120 s cap | v1 teleports the truck and players to the mission spawn. v2 has a real drive (§9) | Arrival |
| Incident | Config per mission, default **180 s** | Fires burn, NPCs need saving. Objectives in the HUD | All required objectives done and fires ≤ threshold → Extract early; or time runs out |
| Extract | 20 s | "RETURN TO THE TRUCK!" Rescues count only once dropped in the `TruckZone`. Players outside the zone when the timer ends get "Left Behind" blame | timer, or everyone is in the zone |
| Results | 15 s | Score, stars and blame awards (§10–11) | timer, then the next mission or the lobby |

### 2.2 Objectives (per mission data)

```lua
objectives = {
  { kind = "rescue", tag = "Civilian", need = 2 },        -- required
  { kind = "rescue", id = "Panda", need = 1, critical = true },
  { kind = "extinguish", maxBurningFrac = 0.10 },          -- ≤10% of the flammable parts burning
  { kind = "optional", id = "Houseplant", bonus = 50 },
}
```

### 2.3 Server/client

- **Server:** `RoundService` runs the state machine, writes attributes on `ReplicatedStorage.RoundState`
  (`Phase`, `TimeLeft`, `MissionId`, `ObjectivesJson`, `Tier`), and spawns or cleans the map through
  `MapBuilder.Load(missionId)` / `MapBuilder.Clear()`.
- **Client:** HUD reads the attributes (`GetAttributeChangedSignal`). Alarm lighting and sound are
  driven locally from `Phase`.
- **DevHook:** `RoundService:StartRound(seconds)`, `RoundService:SkipTo(phase)`,
  `RoundService.State` (needed by the Forge playtest harness).

### 2.4 Telemetry

`rounds_started`, `rounds_completed`, `rounds_failed`, `round_fail_<reason>`, `gearup_timeouts`,
`extract_left_behind`.

### 2.5 Priority

v1: Lobby, Alarm, GearUp (prompt lockers), teleport Travel, Incident timer, Extract, Results.
v2: driven Travel, mission select board, multi-mission campaign.

---

## 3. Fire simulation

### 3.1 Model

The unit is a **part tagged `Flammable`**. The forest and farm fields use **grid cells** (§3.7).
Every flammable part carries these attributes:

| Attr | Range | Meaning |
|---|---|---|
| `Mat` | string | Material class (table below) |
| `Heat` | 0–200 | Accumulated heat |
| `Burning` | bool | On fire |
| `Intensity` | 0–1 | Fire strength; drives damage, spread and visuals |
| `Fuel` | 0–max | Burns down; at 0 the part is **Charred** |
| `Wet` | 0–1 | Soaks up incoming heat; dries over time |
| `Value` | $ | Property value, for damage accounting |
| `Charred` | bool | Black, not flammable, may trigger collapse |

### 3.2 Material classes (Config.Fire.Materials)

| Class | Ignite at Heat | Fuel | Intensity growth /s | Spread out × | Examples |
|---|---|---|---|---|---|
| `Paper` | 30 | 15 | 0.20 | 2.5 | bookshelves, newspapers |
| `Fabric` | 40 | 30 | 0.15 | 2.0 | couch, curtains, bed |
| `Hay` | 35 | 25 | 0.25 | 2.5 | haystacks, dry grass cells |
| `Wood` | 100 | 100 | 0.08 | 1.0 | walls, floor, furniture, doors, trees |
| `Plastic` | 80 | 60 | 0.10 | 1.2 | appliances (black smoke ×2) |
| `Gas` | 60 | n/a | n/a | n/a | gas tanks: explode instead (§8.3) |
| `Brick` / `Metal` | never | n/a | n/a | conducts 0.3 | shells, truck, hydrant |

### 3.3 Tick (server, `Config.Fire.Tick = 0.5 s`, only over the burning set and its neighbours)

```
for each burning part P:
  P.Intensity = min(1, P.Intensity + growth[P.Mat] * dt * roomOxygenMult)   -- §3.5
  P.Fuel     -= Intensity * Config.Fire.BurnRate(1.0) * dt
  for each neighbour N of P (precomputed):
    if N not Burning and not Charred:
      gain = Config.Fire.Transfer(12) * P.Intensity * spreadOut[P.Mat] * dirMult(P,N) * (1 - N.Wet) * dt
      N.Heat += gain
      if N.Heat >= igniteAt[N.Mat]: Ignite(N, cause = P)
  if P.Fuel <= 0: Char(P)
for each hot non-burning part: Heat -= Config.Fire.Cooling(4) * dt   (floor 0)
for each wet part: Wet -= Config.Fire.DryRate(0.01) * dt             (≈100 s to dry)
```

- `dirMult`: neighbour **above** ×1.5 (fire climbs), **below** ×0.5, same level ×1.0.
- **Neighbours** are precomputed at map load: `workspace:GetPartBoundsInBox(P.CFrame, P.Size + Vector3.one * Config.Fire.NeighborPad(4))`,
  filtered by `Flammable`, cap 12 per part. They are recomputed when a part breaks or collapses.
- **Why these numbers:** for a full-intensity wood fire touching wood, the net gain is 12 − 4 =
  8 Heat/s, so it spreads in about **12.5 s**. Fabric next to wood reaches 40 Heat in about 4 s.
  A fresh fire (Intensity 0.25) can't spread until its Intensity passes 0.33, about 1 s later.
  A part that isn't fought spreads to 2–4 parts per minute. **Target: an unattended house is fully
  involved in about 150 s.**
- **Ignite(N):** `Burning=true, Intensity=0.25`, add a Roblox `Fire` instance (Size = 2 + 8·I,
  Heat = 5 + 10·I) and a `Smoke` instance when `Mat` is Plastic or Fabric. Counter `fires_spread`.
  The cause chain is kept (`IgnitedBy` attr = a part name, or a player UserId if a player caused
  it) so blame can be traced (§10).
- **Char(P):** `Burning=false, Charred=true`, Color = 30,30,30, Material Slate, flammable tag
  removed, `ScoreService.PropertyLoss(P.Value, "fire")`. If tagged `Support`, call
  `HazardService.CheckCollapse` (§8.5).
- **Budget:** at most `Config.Fire.MaxBurning = 150` burning parts. Once over it, new ignitions
  queue behind it, so the world doesn't run away. At most `Config.Fire.MaxVisibleFX = 60` `Fire`
  instances; past that, the lowest-intensity fires show only an orange `PointLight`.
- **Map size target:** about 300–600 flammable parts per mission. One tick over 150 burning parts
  × 12 neighbours = 1,800 cheap ops at 2 Hz, which is fine.

### 3.4 Extinguish

- Water needed to put out a part = `Config.Fire.LitresPerUnit(15) * Intensity * sizeFactor`, with
  `sizeFactor = clamp(volume / 64, 0.5, 4)`. A chair (0.5) at full fire takes 7.5 L; a wall
  (4) takes 60 L.
- Each litre that lands lowers `Intensity` by `1 / (15 * sizeFactor)` and adds
  `Wet += 0.1 / sizeFactor` (cap 1).
- At `Intensity <= 0`: `Burning=false`, `Heat = 70` (still hot), and the `Fire` instance becomes a
  `Smoke` (steam) for 3 s. Counter `fires_extinguished`. Credit goes to the player whose water
  delivered the last 30% (≥30% of litres in the last 5 s); assists go to anyone else above 20%.
- **Agent efficiency multipliers:** water jet ×1.0, mist ×1.3 per litre (but lower flow), foam
  extinguisher ×3.0, watering can ×1.0 (it only carries 2 L, which is the joke), tidal wave = instant.

### 3.5 Re-ignition and embers

- **Re-ignition:** an extinguished part with `Wet < 0.3` keeps taking heat from neighbours and can
  catch again normally. This is why **pre-wetting** works: Wet 1.0 blocks all incoming heat.
- **Embers (mop-up):** for 20 s after it goes out, a part with `Wet < 0.2` has a
  `Config.Fire.EmberChance(0.15)` chance every 5 s to re-ignite at Intensity 0.2. Counter
  `fires_reignited`. The HUD shows a faint ember glow so players learn to soak things fully.
- **Room oxygen:** `roomOxygenMult` is 1.0 by default, 1.5 in a room that has broken windows or
  doors (vented, so the fire grows), and 0.6 in a sealed room (but pressure builds, §8.4).

### 3.6 Smoke (per `Room` zone, an invisible box part)

- `Room.Smoke` (0–100): `+= Σ(burning Intensity in room) * 3 * dt`, `-= (2 + 4 * openings) * dt`,
  and `-= 5 * dt` per player misting inside.
- `Smoke ≥ 40`: the client shows a grey ColorCorrection plus a short-range `Atmosphere` density
  while the camera is inside the room, and spawns big puffy smoke ParticleEmitters at the ceiling.
  `Smoke ≥ 80` means near-zero visibility (t=27).
- Air drain for everyone inside: `Smoke / 25` per second (4/s at 100). **Crouching halves it**
  (t=56, crawling), and a Downed NPC on the floor gets ×0.5.
- **v1 simplification:** no rooms. Air drains at `2/s` within 10 studs of any burning part with
  Intensity > 0.5. Use `Smoke` instances for the look only.

### 3.7 Grid cells (fields and forest, v2)

- 8×8-stud cells, `Hay` or `Grass` materials, stored in a server array rather than as attributes
  (one part per cell, which only needs a colour change when it burns). The same rules apply, with
  4-neighbour spread plus wind: `Config.Fire.Wind = Vector3(1,0,0) * 0.5` adds ×(1 + dot) to
  spread in the wind's direction.
- **Firebreak:** an axe hit on a grass cell turns it to `Dirt` (not flammable). A tree hit by the
  axe 3 times falls.

### 3.8 Ignition sources (mission start and events)

- Mission start: `Config.Missions[id].startFires` part names or tags, plus a random
  `extraFires = playerCount - 1`.
- Random event every 30–60 s: a new fire at a random `Flammable` part with an `IgnitionHint`
  (stove, outlet, candle, farmer's cigarette, campfire) at Intensity 0.4.
- **Player-caused:** a player on fire (§7.3) heats whatever they touch by +30/s (blame "Human
  Torch"). An explosion adds Heat +100 within its radius. Sparks from a live wire add +50 to parts
  within 4 studs every 3 s.

### 3.9 Server/client, telemetry, priority

- **Server:** all of it. **Client:** reads `Burning/Intensity` to show heat shimmer and a sound
  emitter, and `Room.Smoke` for the screen tint.
- **Remotes:** none. State is attributes; explosions go through `FX`.
- **Telemetry:** `fires_started`, `fires_spread`, `fires_extinguished`, `fires_reignited`,
  `parts_charred`, `peak_burning` (max), `fire_budget_hits`.
- **DevHook:** `FireService:Ignite(name)`, `FireService:Count()` returns `{burning, charred, total}`.
- **Acceptance (for the Forge critic):** "with no players acting, `fires_spread ≥ 3` within 60 s";
  "spraying a burning chair for 2 s puts it out".
- **Priority:** v1 = part model, spread, extinguish, char, re-ignition with the v1 smoke
  simplification. v1.5 = room smoke, embers. v2 = grid cells, wind, room oxygen.

---

## 4. Tools and loadout

Slots: **Hose** (always), **Slap** (empty hand, always), plus **2 locker picks** from Axe,
Extinguisher, Oxygen, Walkie, Watering Can. The trampoline is a world object, not a slot. Tools are
Roblox `Tool` instances with `RequiresHandle=false` and block-built handles. In first person,
show viewmodel arms (two big glove blocks), a cheap version of the trailer's hands.

### 4.1 Hose and water (see §5 for tanks)

| Mode | Cone | Range | Flow | Recoil to self | Push on hit | Notes |
|---|---|---|---|---|---|---|
| **Jet** (LMB) | 6° | 40 studs | 12 L/s | 6 studs/s backwards (2 when crouched) | 25 studs/s to players and NPCs | Ragdolls a target after 1.5 s of continuous hits |
| **Mist** (RMB) | 25° | 15 studs | 6 L/s | 0 | 0 | ×1.3 efficiency, clears smoke 5/s, cools Heat −20/s in cone |

- **Server resolution** every 0.1 s while `on`: `workspace:Spherecast(nozzle, radius = jet 1.5 |
  mist 4, aim * range, params)`. Water is credited to every `Flammable` within 3 studs of the hit
  point, split evenly. Any character hit takes push and extinguish. A miss on the floor spawns or
  grows a `Puddle` (§5.3).
- `aim` comes from the client and is clamped to within 30° of the character's look vector
  (anti-exploit).
- **Recoil (developer: "throws you across the room"):** while jetting, server
  `root.AssemblyLinearVelocity += -aim * Config.Hose.Recoil * dt * 10`, skipped when grounded and
  crouched. **Gag (v1.5):** aim within 20° of straight down for more than 1 s and the player is
  lifted at 15 studs/s ("Hose Rocket" counter).
- **Client:** a Beam or ParticleEmitter stream (the trailer's white-blue spray), a camera shake of
  0.3, a nozzle sound, and a local tank estimate. The server value is the truth.
- **Telemetry:** `water_used` (litres), `water_on_fire`, `water_wasted`, `hose_teammate_hits`.

### 4.2 Axe

- LMB swing: cooldown 0.8 s, reach 6 studs, raycast from the camera.
- Damage: `Door` HP 100 (35 per hit, **3 hits**); `BreakableWall` HP 200 (6 hits); `Window` HP 1
  (vents the room); grass cell to dirt (firebreak); tree HP 3 hits; hydrant: 1 hit makes a
  **geyser** (10 s of 20 L/s soaking a 12-stud radius, water-damage blame).
- **Locked doors** (`Locked=true`) can only be opened by the axe or a kick. A kick is the
  no-tool fallback: 6 kicks of 17 HP.
- Breaking an unlocked door gets blame "Unnecessary Force" (+$50 property).
- Hitting a player: 10 damage, 1.5 s ragdoll, blame "Axe-idental". Hitting a civilian: 0 damage,
  but they panic.
- **Telemetry:** `doors_broken`, `walls_broken`, `windows_broken`, `axe_teammate_hits`.

### 4.3 Extinguisher

- 20 "charges", each worth 1 L × 3.0 efficiency. Cone 15°, range 12, flow 4 charges/s (5 s total
  spray). Refill at the truck only.
- On a burning player: instantly sets `OnFire=false` (t=48). On any player: a 2 s white-out
  screen ("Snowblind" counter).
- **Telemetry:** `extinguisher_used`, `players_extinguished`.

### 4.4 Oxygen tank

- Hold E (or a ProximityPrompt `HoldDuration = 3`) on an Unconscious NPC or a Downed player within
  5 studs.
- 5 uses per tank; refill at the truck.
- NPC: `Unconscious → Conscious` (spiral eyes to normal, t=32–33), Air = 100. Player: revived at 50
  HP.
- Using it on a conscious target: the gag "Recreational Oxygen", blame +1.
- **Telemetry:** `revives_npc`, `revives_player`.

### 4.5 Slap (always available, F or LMB with no tool out)

- Cooldown 1.5 s, reach 5 studs.
- `Dazed` or `Panicking` NPC → `Calm` (follows the slapper for 30 s within 12 studs) (t=40–41).
  Requires 1 slap for Dazed and 2 for Panicking.
- Downed player: 3 slaps within 6 s revives them at 20 HP (the poor man's oxygen).
- Conscious player: 8 studs/s push, 0 damage, blame "Slap Happy". Slapping a farmer who is smoking
  confiscates the cigarette and removes the `IgnitionHint` (t=39).
- **Telemetry:** `slaps`, `slaps_teammate`, `npcs_calmed`.

### 4.6 Walkie-talkie

- LMB: a ping at the aim point (`Ping` remote), kind cycled with R: Fire, Victim, Water, Help. It
  shows to all players as a billboard for 8 s and as an edge-of-screen arrow. Cooldown 2 s.
- RMB: **throw it** (t=45). A physics part at 60 studs/s; hitting a player stuns them for 0.5 s
  (blame "Radio Silence"). It respawns in your slot after 10 s.
- Passive: shows the minimap markers for trapped targets (the "dispatch" intel). Without a walkie,
  trapped NPCs only show within 20 studs.
- **Telemetry:** `pings`, `walkie_throws`.

### 4.7 Watering can (the joke tool)

- 2 L capacity, 0.5 L/s, range 4. Refill at any hydrant, puddle or sink.
- It does put out fires (by the normal water rule), but 2 L only handles a tiny one.
- **Houseplant care:** watering a `Houseplant` target for 2 s gets credit "Green Thumb" (+25) and
  makes the plant fire-immune for 60 s (t=25).
- **Telemetry:** `plants_watered`.

### 4.8 Trampoline (world object, v2; v1.5 if time allows)

- Stored on the truck; ProximityPrompt "Grab trampoline." Players hold it at the edge points. It
  becomes **active only when ≥2 players hold it** (solo: it can be dropped flat as a placed mat at
  50% catch radius).
- While held, holders move at ×0.6 speed and can't use tools.
- **Window jumpers:** a `WindowJumper` NPC at an upper window counts down 15 s (or less if their
  room's Smoke > 60) and then jumps. Landing within 5 studs of an active trampoline centre means they
  bounce to safety and are delivered: they count as rescued at their position, then walk to the
  truck. Otherwise they "splat": Unconscious and Injured (−50% rescue points), and the holders who
  let go in the last 3 s get blame "Butterfingers".
- **Telemetry:** `trampoline_catches`, `trampoline_misses`.

### 4.9 Ladder (v2)

Portable 3-section ladder (24 studs). Placed against a wall with a prompt; it is a `TrussPart`, so
it's climbable. Gives access to upper windows (t=17). A player climbing while carrying moves at
×0.5.

### 4.10 Tool priority

v1: Hose (jet only), Axe, Slap. v1.5: Mist, Extinguisher, Oxygen, Watering can. v2: Walkie,
Trampoline, Ladder.

---

## 5. Water, tanks and refill

### 5.1 Tanks

| Holder | Capacity | Refill |
|---|---|---|
| Player hose backpack (v1 model) | 100 L (about 8 s of jet) | At a `Hydrant` or the truck: hold E within 8 studs, 40 L/s |
| Truck tank (v2) | 2,000 L | Hook the truck to a hydrant (prompt at the truck's side) at 100 L/s. Players refill from the truck at 40 L/s, drawn from the truck tank |
| Hydrant | infinite | n/a |

- **v2 tethered hose (developer: "hook your hose to the nearest hydrant"):** pressing E at a hydrant
  attaches your hose (t=14–15). From then on your tank refills **while spraying** at 15 L/s (above
  the 12 L/s jet, so it is unlimited while tethered), but you're limited to `Config.Hose.Length = 80`
  studs from the hydrant. A `RopeConstraint` from the hydrant to the player draws the yellow hose
  line. Past the length, the player is pulled back. Another player can trip on a taut hose (v2 gag:
  a 0.5 s stumble when crossing a taut segment).

### 5.2 State and remotes

- Character attribute `Tank` (L). The server decrements it every resolved spray tick. The client
  shows a tank bar and a flashing "REFILL!" under 20%.
- Refill is a ProximityPrompt (`Hydrant`, `TruckZone`, `HoldDuration=0` and a held loop on the
  server while `PromptButtonHoldBegan` lasts).

### 5.3 Puddles and water damage (developer: "water that ruins as much as it saves")

- A spray that hits a horizontal surface (normal.Y > 0.7) with no flammable within 3 studs spawns a
  `Puddle` disk (0.2 tall, radius 2) or grows the nearest puddle within 4 studs: radius +0.15 per
  litre, max 10. At most 40 puddles; they evaporate at −0.05 radius/s after 30 s of no water.
- Water landing on a `Property` part that isn't burning: `ScoreService.PropertyLoss(litres * Config.Water.DamagePerL(2), "water", sprayer)`.
  Per-part water damage is capped at its `Value`.
- Puddles are the **conductor** for electrocution (§8.1) and make the floor slippery (×1.3
  WalkSpeed with sliding: lower Friction via `CustomPhysicalProperties`).
- **Telemetry:** `water_used`, `water_damage_dollars`, `puddles_created`.

### 5.4 Priority

v1: backpack tank plus hydrant/truck refill, `water_used`. v1.5: puddles and water damage. v2: truck
tank, tethered hose.

---

## 6. Rescue targets (NPCs)

### 6.1 Types

| Type | Points | Carry speed × | Behaviour | Seen |
|---|---|---|---|---|
| Civilian (adult) | 100 | 0.75 | Panics, can be trapped, unconscious or dazed | t=29–33 |
| Kid (school) | 75 | 0.9 | Panics in groups, follows a calmed adult or a slapper | t=4–5 |
| Farmer | 100 | 0.75 | Dazed by default; smokes (ignition source) | t=39–41 |
| Dog | 75 | 0.9 | Once touched (E), follows you within 10 studs at walk speed; no carry needed | t=46–47 |
| Cat | 75 | 0.95 | Shy: runs (12 studs/s) from any player moving faster than 10 studs/s within 15 studs. Crouch-walk to grab. Sits on window sills (t=18–20) | t=18–20 |
| **Panda** | **500** | **0.5** solo, **0.85** two carriers | "Extremely confused": wanders slowly, sits down for 5 s every 10 s, eats nearby plants. Heavy. Often a critical objective | t=21–22, 64 |
| Houseplant | 25 | 1.0 | Static. Carry it, or water it in place (§4.7) | t=25 |
| Pool-float guy | 100 | 0.6 | Floats in the donut, won't let go; carry them whole | t=11, 46 |

### 6.2 NPC state machine (server, `RescueService`, 4 Hz)

```
Idle ──fire within 20 studs──▶ Panicking ──slap×2──▶ Calm(follow)
Trapped (spawned behind a Locked door; waves and shouts "HELP" every 4 s, billboard)
any ──Air reaches 0──▶ Unconscious (spiral eyes, ragdoll) ──oxygen 3 s──▶ Calm
Unconscious ──60 s more exposure (Air 0 and in smoke/fire)──▶ Toasted (black, googly eyes, t=34–36)
any ──touching Intensity>0.5 fire 3 s──▶ OnFire (5 HP/s, runs randomly) ──water/extinguisher──▶ Panicking
Dazed (farmer, or a civilian hit by debris) ──slap──▶ Calm
Carried, Delivered(terminal), Toasted(terminal)
```

- **NPC Air** follows the same drain as players (§3.6). The NPC `HP` bar is replaced by Air, plus
  an `Exposure` timer once Air is 0.
- **Panicking:** runs at 14 studs/s to random points within 25 studs, with a **30% chance per
  re-path to pick a point toward the fire** (the comedy). Can be carried while panicking but wriggles:
  carrier speed ×0.6 and a 10%/s chance of dropping them.
- **Calm-follow:** `Humanoid:MoveTo` the leader, re-pathed every 0.5 s with `PathfindingService`
  (v1: straight-line MoveTo with a jump-on-stuck retry).
- **Toasted** is a soft failure. They can still be carried to the truck for 25% points ("Well
  Done" blame on the nearest player in the last 30 s). They count as not rescued for the
  objective, unless `Config.Rescue.ToastCounts` is set (default false).
- **Built from parts:** an R15 dummy recoloured, or a blocky Model with a Humanoid, plus 2 white
  sphere eyes with black pupils (googly eyes are the brand). Pets are 4–6 part blocks.

### 6.3 Delivery

- Dropped (or followed) into a `TruckZone` (a 15-stud box at the back of the truck), the target
  becomes `Delivered`. It is removed and shown seated on the truck, which gives the t=64 shot.
  Counter `rescued`, plus `rescued_<type>`.
- Credit goes to the player who carried it last, or who it was following. If someone revived it
  earlier in the mission, that player gets an assist.

### 6.4 Telemetry and priority

`npcs_spawned`, `rescued`, `rescued_panda`, `rescued_pet`, `npcs_unconscious`, `npcs_toasted`,
`npcs_dropped`, `npcs_thrown`.
v1: civilian (Trapped, Unconscious via Air, carry to the truck), dog, cat (no shy AI), panda (heavy).
v1.5: Panicking with slap, Toasted, houseplant. v2: shy cat, kids crowd, farmer smoker, pool-float
guy, pathfinding.

---

## 7. Players: carrying, health, friendly fire

### 7.1 Carry (`CarryService`)

- E within 6 studs on a `Rescuable` (or `GasTank`, `Houseplant`, trampoline) calls
  `Carry:FireServer("pick", target)`.
- **Server:** checks distance and that the player isn't carrying already; sets
  `target.Humanoid.PlatformStand = true`, welds `target.HumanoidRootPart` to the carrier with a
  `WeldConstraint` at `CFrame.new(0, 0.5, -2.5)` (held in front, t=29–31), sets
  `SetNetworkOwner(carrier)`, sets the carrier's `WalkSpeed = 16 * carryMult`, and unequips any
  2-handed tool (hose, axe, extinguisher).
- **Two-carrier (panda, v1.5):** a second player presses E on a carried panda. Both get ×0.85 and
  the weld becomes an `AlignPosition` to the midpoint.
- **Drop (E again or G):** a soft drop 3 studs ahead. **Throw (Q):** impulse `look * 50 + up * 20`.
  Blame "Yeet" +1. A thrown NPC hitting the ground at more than 40 studs/s falls **Unconscious**
  (blame "Air Mail").
- **Forced drop** when the carrier is Downed, Stunned, electrocuted or ragdolled. Blame
  "Butterfingers" goes to whoever caused the stun (or the carrier, if it was self-inflicted).
- **Telemetry:** `carries`, `drops`, `throws`, `forced_drops`.

### 7.2 Health and air (`PlayerStatus`, 4 Hz)

| Attr | Max | Drain | Regen |
|---|---|---|---|
| `HP` | 100 | Near fire: `8 * Intensity`/s within 4 studs; in fire: 20/s; OnFire 5/s; air 0: 10/s | +5/s after 5 s without damage |
| `Air` | 100 | Smoke (§3.6) | +20/s outside smoke |

Roblox `Humanoid.Health` mirrors `HP`, but death is intercepted: `BreakJointsOnDeath=false`, and
at 0 HP the player becomes **Downed** instead of dying.

### 7.3 Player on fire (t=48)

- If the player took ≥25 fire damage within 3 s, or stood in Intensity > 0.8 fire for 2 s, then
  `OnFire = true` (attach a `Fire` to the torso).
- Effects: 5 HP/s; heats any flammable within 3 studs +30/s (they spread fire, blame "Human Torch");
  panic camera shake.
- Out by: being hit with water or the extinguisher, standing in a puddle, or **stop-drop-roll**
  (crouch still for 2 s).

### 7.4 Downed and revive

- **Downed:** ragdoll, spiral-eyes billboard, a 30 s bleed-out timer, can't act. Carryable by
  teammates (×0.7). A carried Downed player can be dropped into the `TruckZone` for a free revive
  at 30 HP.
- **Revive:** oxygen (3 s hold) at 50 HP, or 3 slaps at 20 HP.
- **Bleed-out:** respawn at the truck after 10 s with 100 HP. Blame "Nap Champion" accrues as time
  spent downed.
- **Team wipe:** all players Downed at once means the mission fails (§12).

### 7.5 Friendly fire matrix (always on: "your own crew is the real hazard")

| Source | Effect on a teammate | Blame tag |
|---|---|---|
| Hose jet | 25 studs/s push; ragdoll after 1.5 s continuous; puts out OnFire | Friendly Hose |
| Axe | 10 dmg, 1.5 s ragdoll | Axe-idental |
| Slap | 8 studs/s push | Slap Happy |
| Extinguisher | 2 s white-out | Snowblind |
| Electrocution (§8.1) | 40 dmg, 2 s stun, skeleton flash | Shocking Behavior |
| Explosion triggered (§8.3) | Up to 60 dmg, 80 studs/s knockback | Kaboom |
| Thrown NPC or walkie hits | 0.5 s stun | Air Mail / Radio Silence |
| Truck runs over (v2) | 30 dmg, 3 s ragdoll | Road Rage |
| Backdraft opened (§8.4) | Up to 50 dmg | Door Dasher |

All of these go through `BlameService.Record(attacker, tag, amount, victim)`.

### 7.6 Priority

v1: carry/drop/deliver, HP plus simplified Air, Downed with timed respawn. v1.5: throw, OnFire,
oxygen/slap revive, hose push. v2: two-carrier panda, carrying downed players, the whole friendly
fire matrix.

---

## 8. Hazards (`HazardService`)

### 8.1 Electrocution: wet floor + fuse box (t=49–50)

- Each building has a `FuseBox` (a Model with a lever) with attribute `Power = true` by default, plus
  `LiveZones` (the building's `Room` boxes).
- **Rule:** while `Power == true`, any `Puddle` overlapping a building's LiveZone that also touches
  a `LiveAppliance` (a tagged washing machine, outlet, or TV) or is within 6 studs of the FuseBox is
  **Live**. Live puddles get a cyan glow (Neon edge) and crackle sound; this telegraphs the danger.
- Standing in a Live puddle: 15 dmg per 0.5 s tick, a 2 s stun, a skeleton/flash FX, and any
  carried target is dropped.
- **Lever:** a ProximityPrompt toggles `Power`. Switching it **ON while a player is in a puddle
  connected to that building** gives an instant 40 dmg and 2 s stun to everyone in those puddles.
  Blame "Shocking Behavior" goes to the lever puller (exactly the trailer beat). Switching it **OFF**
  first is the smart play: the building's lights go off, Live puddles go dead, and the
  "Electrician" credit is awarded.
- **Hosing the FuseBox while Power is on:** the sprayer is shocked (25 dmg, 1 s stun). Blame "Self
  Own".
- **Telemetry:** `electrocutions`, `electrocutions_teammate`, `power_cut`.
- **Priority:** v1.5. It is the strongest friendly-fire beat in the trailer, and cheap once puddles
  exist.

### 8.2 Live wires (developer list)

- A `LiveWire` (a thin Neon part that sways via `HingeConstraint`) falls from a pole or ceiling when
  its `Support` chars. Touching it: 30 dmg, 1.5 s stun. It sparks: Heat +50 to flammables within 4
  studs every 3 s. Cutting the building's power kills it. **v2.**

### 8.3 Gas and explosions (developer list; t=37–38)

- A `GasTank` (propane, stove line). Attribute `Pressure` 0–100 rises `+ 10/s × max(0, Heat − 60) / 40`
  when heat reaches it from neighbouring fire. At 100 it **explodes**: radius 15, damage
  `60 × (1 − d/15)`, knockback 80 studs/s, Heat +100 to flammables in radius, breaks windows and doors
  in radius, `FX("explosion")`.
- Counterplay: carry the tank out (×0.7 speed, it explodes if the carrier catches fire), or close
  its `GasValve` prompt (stops pressure gain for stove lines), or hose it (Wet stops heat gain).
- An axe hit on a gas line opens a leak: a 10 s jet that ignites on contact with fire (a 6-stud
  flamethrower). Blame "Gas Leak".
- **Blame for the explosion:** the last player who touched the tank (carried, axed or dropped
  it), otherwise the nearest player within 20 studs in the last 10 s ("Kaboom Club").
- **Gag (v2, school art room):** a `PaintTank` variant with no damage turns everyone in radius
  rainbow for the rest of the mission (t=38). Counter `rainbowed`.
- **Priority:** v1.5 for the propane tank; v2 for the gas line, paint gag and valve.

### 8.4 Backdraft (t=28 smoke burst behind the door)

- A `Room` with every opening closed and burning parts in it for more than 20 s builds `Pressure`
  `+= 3/s` (cap 100). Telegraph: smoke leaks under the door (a ParticleEmitter at its base), and
  the door glows orange when Pressure > 70.
- Opening or breaking a door (or window) with Pressure > 70 makes a **fireball**: a cone 20 studs
  out of the opening, 50 dmg, OnFire for anyone hit, Heat +80 to the corridor. Pressure resets to 0.
  Blame "Door Dasher".
- Counterplay: hose the door for 3 s (Pressure −10/s while it is being hit), or vent through a
  window from outside first.
- **Priority:** v2 (v1.5 for the cheap version: a puff FX and 20 dmg on any door axed while
  burning parts are inside).

### 8.5 Structural collapse (t=26 ceiling falls)

- `Support` tags go on the posts and beams holding a ceiling group (`CollapseGroup` attr).
- When ≥50% of a group's supports are Charred: a 3 s warning (creak sound, dust particles, the
  ceiling shakes ±0.1 stud), then every part in the group is unanchored and given 0 velocity. A part
  hitting a player deals `min(50, mass × speed / 20)` and a 2 s ragdoll.
- Fallen debris blocks paths; the axe clears debris in 2 hits. Counter `collapses`.
- Also by the axe: breaking 2+ `Support` parts by hand triggers the group (blame "Interior
  Decorator").
- **Priority:** v1.5 for the single-room ceiling group; v2 for multi-storey.

### 8.6 Fire tornado (t=53–54, farm or forest)

- Spawns when ≥30 grid cells (or flammable parts) burn within an 80-stud radius on an
  `Outdoor` map, at most 1 at a time, with a 90 s cooldown.
- A spinning cylinder of Neon and particles, radius 12, height 60. It moves at 8 studs/s in a random
  walk biased 40% toward the nearest player, or toward the truck.
- Effects: ignites every cell or part it passes (Heat +200); players inside are lifted at 40
  studs/s, spun, and flung at 100 studs/s after 2 s, set OnFire, and drop whatever they carry.
  Unanchored props are sucked in.
- Dies after 45 s, or once it has absorbed 300 L of water (it shrinks visibly with the water
  absorbed).
- **Telemetry:** `tornadoes`, `tornado_flings`, `tornado_killed_by_water`.
- **Priority:** v2. It's a strong video moment; a scripted version (spawn at t=60 s on the farm
  map) can be v1.5 if someone needs a demo beat.

### 8.7 Traffic (t=42 ducks)

- v2 driving only: a duck family crosses the road on a 20 s loop. Hitting them: feathers FX,
  the ducks respawn, blame "Duck Hunt" goes to the driver, −$25. Parked cars: crash damage to the
  truck's HP.

---

## 9. Truck (`TruckService`)

- **v1:** a static Model built from parts (red body, white stripe, "67" SurfaceGui, ladder on top).
  `TruckZone` is a box at the rear. The extinguisher and oxygen refill there, and the backpack tank
  too. Travel = fade, teleport the truck and players to `Mission.TruckSpawn`.
- **v2 drivable:** a `VehicleSeat` (MaxSpeed 60, Torque 20000, TurnSpeed 1.2) on a 4-wheel chassis
  with `HingeConstraint` motors, plus 3 passenger `Seat`s in the back. A GPS arrow points to the
  incident. Siren toggle (H). Truck HP 500: a collision at more than 30 studs/s costs `speed × 2`
  HP and goes on the driver's blame ("Road Rage"). At 0 HP the truck is "smoking": MaxSpeed 20
  and −$500. Hitting a hydrant makes a geyser.
- **Hose reel (v2):** a prompt on the truck side hooks it to the nearest hydrant within 30 studs to
  fill the truck tank.
- **Telemetry:** `truck_distance`, `truck_crashes`, `ducks_hit`.

---

## 10. Blame system (`BlameService`)

### 10.1 Ledger

`ledger[userId] = { credits = {tag → n}, blames = {tag → n}, events = {{t, tag, amount, victim}} }`
(events capped at 200). `Record(player, tag, amount, victim?)` is called by every system. Each
record also fires `Notify` with style `blame` when the tag is in `Config.Blame.Announce` (kill-feed
style: "**02** electrocuted **01**").

### 10.2 What is tracked

| Tag | Kind | Source | Weight |
|---|---|---|---|
| `fires_out` | credit | FireService last-30% rule | 1 per part (×sizeFactor) |
| `rescues` | credit | delivery | type points / 100 |
| `panda` | credit | panda delivered | special award |
| `revives` | credit | oxygen or slap revive | 1 |
| `power_cut` | credit | fuse OFF before anyone was shocked | 1 |
| `water_used` | neutral | litres | n/a (awards only) |
| `property_fire` | blame | $ burned in parts the player **caused** (`IgnitedBy` chain from a player: Human Torch, explosion, gas leak) | $/100 |
| `property_water` | blame | water damage $ | $/100 |
| `property_axe` | blame | doors, walls, windows, unlocked-door bashing | $/100 |
| `friendly_hose` | blame | seconds spent hosing teammates | 0.5/s |
| `teammate_hits` | blame | axe, slap, throws, walkie | 1 each |
| `electrocuted_others` | blame | lever-on or a live hose | 3 each |
| `explosions` | blame | gas attribution rule | 3 each |
| `npcs_dropped` | blame | forced or careless drops | 1 |
| `npcs_thrown` | blame | Yeet / Air Mail | 1 |
| `npcs_toasted_near` | blame | nearest player within 30 s of the toast | 2 |
| `time_on_fire` | blame | seconds OnFire | 0.2/s |
| `time_downed` | blame | seconds Downed | 0.1/s |
| `left_behind` | blame | outside the TruckZone at the end of Extract | 2 |
| `ducks_hit`, `truck_damage` | blame | driver | 1 per duck, HP/100 |
| `self_owns` | blame | self-electrocuting, setting yourself on fire with a gas leak | 1 |

**Blame score** = Σ blame weights. **Blame %** = a player's score / the team total, shown as a bar
or pie in Results. **Scapegoat** = the highest blame %. **MVP** = the highest credit.

### 10.3 Awards (each player gets ≥1; the 1–2 rarest and funniest are picked first)

| Award | Condition (top of the stat, threshold > 0) |
|---|---|
| **Panda Express** | Delivered the panda |
| **Shocking Behavior** | Most `electrocuted_others` |
| **Friendly Fire Department** | Most `friendly_hose` seconds |
| **Flood Insurance Fraud** | Most `property_water` |
| **Splinter Cell** | Most doors and walls broken |
| **Unnecessary Force** | Axed an unlocked door |
| **Pyromaniac** | Most `property_fire` caused |
| **Human Torch** | Most `time_on_fire` |
| **Kaboom Club** | Most explosions |
| **Nap Champion** | Most `time_downed` |
| **Slap Happy** | Most slaps on teammates |
| **Air Mail** | Most NPCs thrown |
| **Butterfingers** | Most NPCs dropped |
| **Well Done** | An NPC was toasted on their watch |
| **Hydrant Hugger** | Most `water_used` |
| **Lifeguard** | Most rescues |
| **Breath of Fresh Air** | Most revives |
| **Green Thumb** | Saved or watered a houseplant |
| **Electrician** | Cut the power |
| **Road Rage** / **Duck Hunt** | Truck damage / ducks hit |
| **Left Behind** | Missed the truck |
| **Somehow Competent** | Lowest blame % (fallback) |
| **Scapegoat** | Highest blame % (always shown, with a dunce-cap icon) |

Solo: the awards still show ("you just won't have anyone to blame"). Blame % is 100%, so the solo
player is always the Scapegoat, which is the joke.

### 10.4 Blame vote (v2)

During Results, 8 s for each player to click a teammate's card. The most-voted gets the **Dunce
Helmet** cosmetic (a cone on the helmet) for the next mission. Counter `blame_votes`.

### 10.5 Priority

v1: ledger, 8 core tags (fires_out, rescues, panda, water_used, property_axe, friendly_hose,
teammate_hits, time_downed), 10 awards, Scapegoat/MVP, Results UI. v1.5: the full list plus the
kill-feed. v2: vote, dunce cosmetic.

---

## 11. Scoring and results (`ScoreService`)

### 11.1 Points (team score; per-player credit drives the awards)

| Item | Points |
|---|---|
| Rescue | by type (§6.1); conscious on delivery +50; Injured −50%; Toasted 25% |
| Fire part put out | `10 × sizeFactor` |
| Time bonus | `2 × TimeLeft` at Extract start (only if the mission succeeds) |
| Property saved | `PropertySavedFrac × 500` |
| Property loss | −$/10 (fire, water and axe losses together) |
| No-casualty bonus | +200 (no Toasted, no team wipe) |

### 11.2 Stars

★ objectives met. ★★ plus burning ≤10% at the end and property saved ≥60%. ★★★ plus time left ≥30%
and no Toasted NPCs.

### 11.3 Results payload (`Results` remote)

```lua
{ missionId, success, failReason?, stars, teamScore,
  breakdown = {rescues=..., fires=..., time=..., property=..., loss=...},
  players = { [userId] = {name, helmet, credit, blamePct, awards = {"Panda Express", ...}} },
  scapegoat = userId, mvp = userId }
```

Client: a full-screen panel, one card per player (big helmet number, award stickers), a blame-%
bar, then "NEXT CALL" in 15 s.

### 11.4 Telemetry

`score_total`, `stars_<n>`, `property_loss_dollars`, `property_saved_pct` (last value).

---

## 12. Fail states

| Reason id | Condition | Result |
|---|---|---|
| `timeout_quota` | Incident timer reaches 0 with a required rescue objective unmet | Fail ("The town is on fire. Again.") |
| `burned_down` | Charred value ≥ 80% of the mission's total `Property` value at any moment | Immediate fail |
| `critical_lost` | A `critical` target (the panda in its mission) is Toasted | Immediate fail |
| `team_wipe` | All players Downed at the same moment | Immediate fail |
| `truck_destroyed` | v2: truck HP 0 **and** time left < 30 s | Fail |

On failure: skip Extract, show Results with `success=false`. **Blame still runs** (it's funnier).
Counter `round_fail_<reason>`.

---

## 13. Difficulty scaling

### 13.1 Per player count (n = 1..4)

| Param | Formula | n=1 | n=4 |
|---|---|---|---|
| Starting fires | `base + (n − 1)` | 3 | 6 |
| Spread `Transfer` | `12 × (0.8 + 0.1n)` | 10.8 | 14.4 |
| Rescue targets spawned | `base + floor(n/2)` | 3 | 5 |
| Incident timer | `base + 15(n − 1)` | 180 | 225 |
| Random new fire interval | `60 − 7n` s | 53 | 32 |
| Backpack tank | 100 L flat | n/a | n/a |

### 13.2 Per mission tier (campaign order, `Config.Missions[i].tier`)

| Tier | Spread × | Ember chance | Hazards on | Timer base |
|---|---|---|---|---|
| 1 | 0.8 | 0.05 | none | 180 |
| 2 | 1.0 | 0.10 | electrocution, collapse | 200 |
| 3 | 1.1 | 0.15 | + gas, backdraft | 220 |
| 4 | 1.2 | 0.15 | + live wires, tornado | 240 |
| 5 | 1.3 | 0.20 | everything | 300 |

---

## 14. Missions

All of them are built in code by `MapBuilder` from blocks (houses are a floor, 4 walls with a door
gap, a roof slab, a few furniture blocks). Each mission is a Config table:
`{id, tier, buildFn, truckSpawn, startFires, targets, hazards, objectives, timer}`.

| # | Mission | Layout | Targets | Hazards and unique beats | Priority |
|---|---|---|---|---|---|
| 1 | **Elm Street House** (sunset suburb, t=14–15) | A block of 3–5 houses with 1–2 rooms each, a hydrant across the street, a locked front door on house A | 2 civilians (1 Trapped behind the locked door, 1 Unconscious), dog, cat, houseplant, **the confused panda in the living room** (the gag that keeps the store promise in v1) | Kitchen start fire, couch and bookshelf fuel, watering-can joke | **v1** |
| 2 | **Night Apartment** (t=16–20) | 3-storey brick block (non-flammable shell, wooden interiors), 2 rooms per floor, stairwell | 4 civilians, 2 of them **window jumpers**, the cat on a sill, the pool-float guy | Trampoline, ladder, fuse box in the basement laundry (electrocution), backdraft on floor 2 | v1.5 (no trampoline) → v2 |
| 3 | **School** (t=4–5) | Hallway with lockers, 4 classrooms, chem lab, art room; the alarm is pulled by a kid NPC in the intro | 8 kids panicking in groups, 1 teacher Dazed | Gas explosion in the chem lab, rainbow paint blast in the art room, smoke corridor (crawl) | v2 |
| 4 | **Farm** (t=39–41, 53) | Barn, haystacks (Hay), field grid, fences | Farmer (Dazed, smoking), cows/pigs as pets, a dog | Hay spreads ×2.5, the cigarette ignition, **fire tornado** in the field | v2 (v1.5: farm with no grid and a scripted tornado) |
| 5 | **Forest Wildfire** (t=0–2, 43–45, 55–56) | Hillside grid of grass, trees, the RV campsite where the campfire started it | Campers (RV), a lost dog | Wind spread, firebreaks with the axe, walkie dispatch matters (no minimap otherwise), crawl under smoke | v2 |
| 6 | **Zoo** (t=21–22) | Bamboo enclosure, kiosks | **Panda (critical)**, plus other animals | The panda is 2-carrier heavy; bamboo is Paper-class | v2 (or merged into #1 for v1) |
| 7 | **Dam Finale** (t=57–63) | A dam above a city block that is too large to put out (Transfer ×3) | Civilians in the flood path must be moved to high ground (marked zones) **before** the blast | Plant 3 detonator charges (ProximityPrompts on the dam face, 4 s hold each, with a carryable charge from the truck), run to the safe point, press the detonator. A scripted tidal wave (a big blue Part tweened across the city over 6 s) sets every `Flammable` in the city volume to Burning=false and Wet=1, ragdolls any NPC still in the path ("flood casualties" blame), and floods the streets (t=64). Success = the city is out, and ≥70% of civilians were moved | v2 (the trailer's climax; good for the video if time allows) |

---

## 15. Co-op roles and identity

- **Helmet numbers:** 01–04 by join order. A SurfaceGui on the helmet block and on the HUD card;
  the blame UI uses the numbers, not names (as in the trailer). The truck is always 67.
- **Soft roles via lockers (v1):** no forced class; the loadout pick is the role. The suggested
  presets are shown as locker labels:
  - **Nozzle:** Hose + Extinguisher + Walkie
  - **Truckie:** Hose + Axe + Oxygen
  - **Medic:** Oxygen + Extinguisher (carry speed +10%, v2 perk)
  - **Driver** (v2): Walkie + Axe; the only one who can start the truck in "realistic" mode
    (off by default)
- **Shared resources create co-op friction:** one truck tank (v2), one trampoline that needs 2
  people, a panda that needs 2 people, one fuse box lever anyone can flip.
- **Comms:** pings (§4.6) and the kill-feed `Notify` toasts are the co-op glue. Roblox voice chat is
  optional.
- **Priority:** v1 = numbered helmets and lockers; v2 = presets and perks.

---

## 16. Telemetry master list (`ForgeTelemetry.count`)

Required for Forge playtests (TARGET_GAME.md): `fires_extinguished`, `fires_spread`, `rescued`,
`doors_broken`, `water_used`, `rounds_completed`.

Full set: `rounds_started`, `rounds_completed`, `rounds_failed`, `round_fail_<reason>`,
`gearup_timeouts`, `extract_left_behind` · `fires_started`, `fires_spread`, `fires_extinguished`,
`fires_reignited`, `parts_charred`, `peak_burning`, `fire_budget_hits` · `water_used`,
`water_on_fire`, `water_wasted`, `water_damage_dollars`, `puddles_created`, `refills` ·
`doors_broken`, `walls_broken`, `windows_broken`, `extinguisher_used`, `players_extinguished`,
`revives_npc`, `revives_player`, `slaps`, `slaps_teammate`, `npcs_calmed`, `pings`,
`walkie_throws`, `plants_watered`, `trampoline_catches`, `trampoline_misses` · `npcs_spawned`,
`rescued`, `rescued_panda`, `rescued_pet`, `npcs_unconscious`, `npcs_toasted`, `npcs_dropped`,
`npcs_thrown`, `carries`, `throws`, `forced_drops` · `player_downs`, `player_respawns`,
`players_on_fire`, `hose_teammate_hits`, `axe_teammate_hits` · `electrocutions`,
`electrocutions_teammate`, `power_cut`, `explosions`, `backdrafts`, `collapses`, `tornadoes`,
`tornado_flings` · `truck_distance`, `truck_crashes`, `ducks_hit` · `score_total`,
`property_loss_dollars` · `remote_rejected`.

**Playtest health checks** (a cheap critic heuristic): in a 60 s idle playtest, `fires_spread > 0`
and `remote_rejected == 0`. With the scripted bot (DevHook drives the hose at the nearest fire),
`fires_extinguished > 0` and `water_used > 0`.

---

## 17. Prioritized build order

Each step is one or two Forge coder calls (or one human hour) and must leave the game playable.
Cumulative checkpoints in bold.

**P0: the core loop (Fri night to Sat ~10:00)**
1. `Config.luau` + `Net.luau` (all tunables and remote names from this doc).
2. `MapBuilder`: the station (truck 67 block, lockers, alarm beacon) plus **Mission 1 Elm Street**
   (3 houses, hydrant, tagged Flammable/Door/Room/Property/TruckZone).
3. `FireService`: the part model, ignite/spread/char, `Fire` instances, MaxBurning budget,
   re-ignition, simple Air drain near fire.
4. `WaterService` + hose tool (jet only) + `HoseFX.client` + backpack tank + hydrant/truck refill.
5. `RoundService`: Alarm → GearUp (auto-loadout) → teleport → Incident 180 s → Extract → Results stub.
6. `HUD.client`: timer, objective list, tank bar, HP/Air.
   **Checkpoint A: an alarm rings, you spawn at a burning house, fire spreads, the hose puts it out,
   the round ends.** (Telemetry: fires_spread, fires_extinguished, water_used, rounds_completed.)

**P1: rescue and blame (Sat 10:00–14:00)**
7. `RescueService`: civilian (Trapped, Unconscious via Air), dog, cat, panda; googly-eye block
   builds.
8. `CarryService`: pick/drop/deliver to the TruckZone, speed multipliers.
9. Axe tool + locked doors (`doors_broken`).
10. `PlayerStatus`: HP, Downed, timed respawn at the truck; fail states `timeout_quota`,
    `burned_down`, `team_wipe`.
11. `BlameService` (8 core tags, 10 awards, Scapegoat/MVP) + `ScoreService` + the Results UI.
    **Checkpoint B (the demo-able game): a full mission with rescues, axe, failure or success, and a
    funny results screen.** (+ rescued, doors_broken.)

**P1.5: the friendly-fire comedy (Sat 14:00–18:00 freeze)**
12. Slap (calm Panicking or Dazed, push teammates) + the Panicking NPC state.
13. Hose push on teammates and ragdoll + kill-feed `Notify`.
14. Puddles + fuse box electrocution (the strongest trailer beat).
15. Extinguisher + player OnFire + stop-drop-roll.
16. Oxygen revive (NPC and player) + Toasted state.
17. Watering can + houseplant (cheap and on-brand).
18. Mist mode + room smoke + crouch air bonus.
    **Checkpoint C (feature freeze, record the video): co-op chaos visible in one 3-minute run.**

**v2 (after submission, or Forge iteration targets)**
19. Gas tanks and explosions; single-room ceiling collapse; cheap backdraft.
20. Drivable truck (VehicleSeat), sirens, ducks, truck tank, tethered hose with RopeConstraint.
21. Trampoline + window jumpers + ladder → Mission 2 Night Apartment.
22. Throw/Yeet, two-carrier panda, carrying downed players, the full friendly-fire matrix and award
    list.
23. Grid-cell fires + wind + firebreaks → Mission 4 Farm (fire tornado), Mission 5 Forest
    (walkie dispatch).
24. Mission 3 School (kids crowd, chem lab, rainbow blast), Mission 6 Zoo.
25. Mission 7 Dam Finale (detonators, tidal wave, flooded-town ending with the panda in the truck).
26. Blame vote and dunce helmet, role perks, cosmetics, campaign progression.

### Sources
- Trailer frames `scratchpad/xvid/f1/sheet_01..08.jpg` (70 s, mix of cinematic and gameplay).
- Steam page: https://store.steampowered.com/app/4908460/Flame_and_Blame/
- Steam FAQ: https://steamcommunity.com/app/4908460/discussions/0/590691669350957307/
- Press release (Games Press): https://www.gamespress.com/Flame-and-Blame-Announced-a-4-Player-Co-op-Comedy-About-Firefighters-W
- KeenGamer announcement: https://www.keengamer.com/articles/news/retrostyle-games-announces-comical-firefighter-flame-and-blame-game/
