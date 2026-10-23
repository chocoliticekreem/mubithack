# 02 — Art direction, game feel, camera, UI/HUD, audio

Scope: how Flame and Blame on Roblox should **look, sound and feel**. Gameplay rules live in other
`docs/game/*` files; this one covers palette, lighting, characters, environment kits, VFX, camera,
juice, HUD, the Blame screen, audio, and what to generate or source versus build from code.

Source: all 8 trailer contact sheets (`xvid/f1/sheet_01..08.jpg`, 1 fps). Frame refs below use
`sN cK`, meaning sheet N and cell K (0–8, row-major). Second t ≈ 9(N-1)+K.

**Tags:** **[v1]** must ship in the solo-playtest build and is built from Parts in code. **[v2]**
comes later and may use meshes, marketplace assets, a vehicle or cinematics.

---

## 0. The look in one paragraph

Chunky low-poly toy town under a **teal sky with an orange horizon**. Warm, saturated and soft:
flat-shaded SmoothPlastic surfaces, big rounded silhouettes and no fine detail. Fire is the
brightest thing on screen, a yellow-white core with orange body, and it blooms. Characters are
**bean/potato bodies with huge white googly eyes** and tiny pupils. Firefighters wear tan-yellow
coats with lime/silver reflective bands, olive gloves, and red helmets with a big black number
(`01`, `02`, `67`). The camera is always first person with **huge gloved hands** in frame. Comedy
comes from contrast: something calm (watering a flower, a drooling cat) in the middle of a burning
room.

Rules for anything the Forge agent builds. Put these in the **user message or lessons**, never in
`forge/prompts/*.md`; see CLAUDE.md.
1. Use `SmoothPlastic` by default. Use `Neon` only for things that glow (fire, alarm lamps, screens,
   electric water).
2. No part thinner than 0.4 studs. Bevel by layering slightly larger, darker parts behind edges
   rather than using fine trim.
3. Take every colour from the palette module (§1). Don't use `BrickColor.Random()` or grey
   defaults.
4. Build silhouettes from big shapes: round things use `Ball`/`Cylinder` parts, and roofs use
   `WedgePart`.
5. Anything flammable gets attribute `Flammable=true` and a `Charred` colour to swap to.

---

## 1. Colour palette

Sampled from the frames as 5×5 median pixels, then corrected by eye. JPEG compression and bloom
make saturated reds and yellows sample darker than they look, so the **Use** column is the value to
put in code: `Color3.fromHex(...)`.

### Sky / atmosphere

| Token | Sampled | Use | Where |
|---|---|---|---|
| `SkyTealDusk` | #0D434A / #05434E | **#0E4A52** | s1 c0–2 top of desert sky |
| `SkyTealDay` | #61A8AB / #468887 | **#5FA6A8** | s5 c5, s6 c5, s7 c0 |
| `SkyTitleTop` | #407E7B | **#407E7B** | s8 c3 title card |
| `HorizonOrange` | #C07048 / #EC9438 | **#EC9438** | s8 c3 bottom, s1 c0 horizon |
| `SunsetPeach` | #DEA074 | **#F2B07E** | s2 c6 behind trees |
| `NightNavy` | #00245D / #071C3B | **#0A2350** | s2 c7–8, s4 c2 |
| `NightInk` | #010C1C | **#06101F** | deep night shadows |
| `DamNightTeal` | #15232C / #134441 | **#14363A** | s7 c3–5 |
| `CloudCream` | #CB9869 | **#F3D2A8** | s6 c5 (lit clouds) |

### Fire, smoke, water, electric

| Token | Sampled | Use | Where |
|---|---|---|---|
| `FireCore` | #F9FE9F | **#FFF6A0** | s3 c7 flame centre |
| `FireBody` | #EAC576 / #C35F2D | **#FFB12B** | s3 c7–8 |
| `FireEdge` | #A84522 | **#FF5A1F** | flame tips |
| `FireDark` | #87351D | **#7A1F10** | tails / embers dying |
| `HazeOrange` | #A05D33 / #C08045 | **#E0823E** | s5 c6–8 burning-forest haze |
| `SmokeGrey` | #64615A / #5E584C | **#5E5A55** | s3 c5 indoor smoke |
| `SmokeWhite` | #D7B59B (lit) | **#EAE6DF** | s4 c0 steam / white puffs |
| `SmokeBlack` | #262225 | **#2A2826** | building smoke columns s2 c6 |
| `WaterSpray` | #87B3AD / #89B4B4 | **#A9E3F0** | s3 c5–6 hose spray (boost) |
| `WaveDeep` | #357D8D / #438C9B | **#3E8C9E** | s7 c7 |
| `WaveMid` | #61A8B6 | **#61A8B6** | s7 c7 |
| `WaveFoam` | #74B1BD | **#DDF3F5** | crest foam (boost) |
| `PoolTile` | #99BBAA | **#7FC4D0** | s2 c2 pool |
| `ElectricCyan` | #A8C6AB (washed) | **#7FF5F0** | s6 c4 electrified puddle |
| `Charred` | #0F0E0E / #1F1A19 | **#1F1A19** | s4 c6–8 burnt NPC/room |
| `CharredWarm` | #4D3226 | **#3A2A22** | burnt furniture |

### Firefighters and characters

| Token | Sampled | Use | Where |
|---|---|---|---|
| `CoatYellow` | #D49A29 / #CE8841 | **#D9A030** | s2 c0 coats 01/02 |
| `CoatShadow` | #9E693B | **#9A6A30** | coat lower half / creases |
| `SleeveTan` | #876653 / #AC6650 | **#B0804A** | first-person sleeves |
| `ReflectLime` | #BA9832 (in shadow) | **#E8E25A** | wrist/ankle stripe, top band |
| `ReflectSilver` | — by eye | **#C9CCD0** | middle stripe of the 3-band |
| `GloveOlive` | #907734 | **#8C7A3A** | gloves (s5 c6 more green: #6F7A3A) |
| `HelmetRed` | #AF371C | **#C0301E** | helmets |
| `HelmetShield` | by eye | **#E8C24A** | gold front badge plate |
| `NumberInk` | — | **#1A1210** | helmet numbers |
| `SkinWarm` | #C86C22 | **#D98A4E** | firefighter 01 skin |
| `SkinPale` | #E7A778 | **#F0C49C** | civilians, farmer |
| `EyeWhite` | — | **#FFFFFF** | googly eyes (pure white, slight Neon optional) |
| `Pupil` | — | **#111111** | pupils |
| `CivShirtRed` | #CF442B | **#CF442B** | revived civilian hoodie s4 c4 |
| `CivTeeWhite` | — | **#F2EEE6** | farmer/baby tee |

### Vehicles, props, architecture

| Token | Sampled | Use | Where |
|---|---|---|---|
| `TruckRed` | #95201C (dark) | **#C8232B** | truck 67, hydrants |
| `TruckChrome` | — | **#D6D8DC** | bumpers, ladder |
| `HoseYellow` | #DEA074 lit | **#E8B83A** | hose line s2 c5–6 |
| `HoseRed` | — by eye | **#B83A2E** | indoor hose s3 c5 |
| `BrassCoupling` | — | **#C89A3C** | nozzle/couplings |
| `StationBrick` | #BF4835 | **#BF4835** | fire station walls |
| `StationBrickLit` | #DD9F75 | **#D98A62** | lit brick |
| `StationFloor` | #7C4F4C | **#8A7470** | bay concrete |
| `FloorLineYellow` | — | **#E3B23C** | bay floor markings |
| `LockerGrey` | #694F3C (warm-lit) | **#6E6A6E** | station lockers |
| `SchoolLocker` | #CD5528 | **#CD5528** | school lockers |
| `SchoolWall` | #A77D44 | **#D2A54A** | mustard lower wall |
| `SchoolPillar` | — by eye | **#2F5F5A** | teal pillars |
| `SchoolFloor` | #925E2E | **#C88A54** | warm floor tile |
| `WoodFloor` | #CD592C | **#C8683A** | living room floor s3 c7 |
| `RoomTeal` | by eye | **#4F8A85** | living-room walls s3 c7 |
| `BookshelfWood` | #803B20 | **#8A4A28** | furniture |
| `SidingCream` | #DEC293 | **#E8D3A8** | suburb house s6 c2 |
| `SidingSalmon` | — | **#D98B6F** | house variant |
| `SidingSage` | — | **#9DB38A** | house variant |
| `RoofBrown` | #4E2D27 | **#5A3A32** | roofs |
| `TrimWhite` | — | **#F2EDE4** | window frames |
| `AptBrick` | #4B271E (night) | **#9C4A36** | apartment block (renders dark at night) |
| `LawnGreen` | #0D2312 night / by eye day | **#7FAF4A** | lawns |
| `Asphalt` | — | **#4A4650** | road |
| `Sidewalk` | — | **#C9B8A8** | pavement |
| `Hay` | #E3AB56 / #D09C52 | **#E3AB56** | haystack/field s5 c2 |
| `FenceWood` | #603928 | **#6B4A35** | farm/desert fence |
| `BarnRed` | — | **#A33A2A** | barn |
| `PineFoliage` | — by eye | **#2F4A3A** | forest canopy |
| `TrunkBrown` | #813818 | **#7A3A1E** | trunks |
| `DryGrass` | #C08045 | **#C9893F** | forest floor s7 c0 |
| `DamConcrete` | #8A5841 lit / #60644B night | **#B89A7E** | dam face |
| `DamWalkway` | #134441 night | **#3D5A58** | dam deck |
| `FuseBoxRed` | #A33021 | **#C0342A** | fuse box s6 c3 |
| `DetonatorRed` | #F12A1F | **#F12A1F** (Neon) | detonator light |
| `AlarmRed` | #8D0006 / glow #FDCDC1 | **#FF2A2A** (Neon) | alarm lamp |
| `DesertRock` | #4A2822 / #753827 | **#8A4A35** | s1 c0 foreground |

### UI palette

| Token | Use | Purpose |
|---|---|---|
| `UiInk` | **#2A1410** | text stroke, outlines (title letters use dark-brown stroke) |
| `UiCream` | **#FFF1D6** | panel fill |
| `UiPanelDark` | **#1E1A22** at 0.25 transparency | HUD backing |
| `UiRed` | **#D9372A** | timer critical, FLAME letters (s8 c3 #A11D0E boosted) |
| `UiFlameGrad` | **#FFE45C → #FF8A1F → #C8231B** | title-card letter gradient |
| `UiWater` | **#4FB3D9** | tank fill |
| `UiWarn` | **#FFC531** | warnings, award gold |
| `UiGood` | **#6BCB5A** | rescue / success |
| `UiShock` | **#7FF5F0** | electrocution awards |

Implement this as a `ReplicatedStorage/Art/Palette.luau` ModuleScript that returns
`{ [token] = Color3 }`. Every kit, VFX and UI script reads from it. **[v1]**

---

## 2. Lighting presets per scene

Store these in `ReplicatedStorage/Art/LightingPresets.luau` as plain tables, plus a
`applyPreset(name, tweenTime)` function that sets `Lighting`, then the `Atmosphere`, `Sky`,
`ColorCorrectionEffect` (name `GradeCC`), `BloomEffect`, `SunRaysEffect`, and an optional
`DepthOfFieldEffect` (name them so they're found or created). Clients can change Lighting locally,
so per-player overlays like smoke-inside and alarm-flash run on the client. **[v1]** for Dusk
Suburb, Night Street and Alarm overlay. **[v2]** for the rest.

Global settings: `Lighting.Technology = Future` (fires cast point-light shadows, which makes the
look) and `GlobalShadows = true`. Fall back to `ShadowMap` if frame rate drops below 50 with 10+
fires.

### Dusk Suburb (default mission, s2 c5–6, s6 c2) [v1]
```
Lighting: ClockTime 17.6, GeographicLatitude 30, Brightness 2.2, ExposureCompensation 0.1
          Ambient #3A2A33, OutdoorAmbient #8A6A70
          ColorShift_Top #FFB07A, ColorShift_Bottom #3A5A7A
          EnvironmentDiffuseScale 0.6, EnvironmentSpecularScale 0.25, ShadowSoftness 0.35
Atmosphere: Density 0.30, Offset 0.20, Color #E8A46E, Decay #5A3D52, Glare 0.45, Haze 1.8
Sky: SunAngularSize 16, MoonAngularSize 8, StarCount 0, CelestialBodiesShown true
ColorCorrection: Brightness 0.02, Contrast 0.12, Saturation 0.18, TintColor #FFF0DE
Bloom: Intensity 0.6, Size 28, Threshold 1.6   (only Neon/fire blooms)
SunRays: Intensity 0.08, Spread 0.6
```

### Night Street / Apartment block (s2 c7–8, s4 c2–5) [v1]
```
Lighting: ClockTime 21.5, Brightness 0.8, ExposureCompensation 0.2
          Ambient #1E2236, OutdoorAmbient #2B3558
          ColorShift_Top #6A80C0, ColorShift_Bottom #000000
Atmosphere: Density 0.36, Offset 0.10, Color #2D3E66, Decay #0B1530, Glare 0, Haze 0.8
Sky: StarCount 3000
ColorCorrection: Contrast 0.15, Saturation 0.10, TintColor #DCE4FF
Bloom: Intensity 0.9, Size 32, Threshold 1.2
SunRays: Intensity 0
```
Fires are the key light here. Street lamps: `PointLight` #FFC97A, Range 24, Brightness 1.5, on a
Neon bulb part. Windows of burning rooms: Neon #FFB347 panes plus an orange PointLight inside.

### Golden Farm / Field (s5 c2–4, s6 c7) [v2]
```
Lighting: ClockTime 16.3, Brightness 2.6, Ambient #4A3A2A, OutdoorAmbient #B08A60
Atmosphere: Density 0.28, Offset 0.25, Color #F2C38A, Decay #8A5A3A, Glare 0.6, Haze 1.2
ColorCorrection: Contrast 0.10, Saturation 0.22, TintColor #FFF2D8
Bloom: 0.5 / 24 / 1.8     SunRays: 0.12 / 0.5
```

### Burning Forest (s5 c6–8, s7 c0–1) [v2]
```
Lighting: ClockTime 18.4, Brightness 1.6, Ambient #4A2A20, OutdoorAmbient #8A4A30
Atmosphere: Density 0.48, Offset 0.0, Color #E07A3A, Decay #6A2A1A, Glare 0.2, Haze 3.0
ColorCorrection: Contrast 0.08, Saturation 0.05, TintColor #FFD2A8
Bloom: 1.0 / 36 / 1.1
```

### Dam Night finale (s7 c2–8) [v2]
```
Lighting: ClockTime 20.5, Brightness 0.9, Ambient #1A2A33, OutdoorAmbient #24414A
Atmosphere: Density 0.35, Offset 0.15, Color #1E3A44, Decay #0D1C24, Glare 0, Haze 1.2
ColorCorrection: Contrast 0.18, Saturation 0.05, TintColor #CFEFF0
Bloom: 1.0 / 40 / 1.0   (city fires in the distance glow hard)
```

### Interior overlays (client-side, tweened over 0.4 s)

| Overlay | Trigger | Settings |
|---|---|---|
| **Fire Station interior** [v1] | Always: station is lit by its own lights | Fluorescent panels: Neon #FFF4D6 parts with `SurfaceLight` (Face Bottom, Range 16, Brightness 1.2, Color #FFE2B8). Bay door open lets the dusk light in. |
| **Alarm** [v1] | Round start (s1 c5–7, s2 c3) | `GradeCC.TintColor` pulses #FFFFFF ↔ #FF5050 at 1 Hz for 3 s. Alarm lamps: Neon #FF2A2A + PointLight (Range 20, Brightness 3) + a `SpotLight` (Angle 45, Range 30) rotating 360°/s. |
| **Red Emergency** [v2] | School intro cinematic (s1 c5) | TintColor #FF3B3B, Saturation -0.6, Contrast 0.35. Nearly monochrome red. |
| **Smoke-filled room** [v1] | Camera inside a `BurningRoom` zone part | Atmosphere Density → 0.62, Color #6A645C, Decay #3A3530, Haze 2.5. CC Saturation -0.2, Brightness -0.05. Revert on exit. |
| **Heat** [v1] | Within 8 studs of fire | CC TintColor → #FFD9B0, plus a HUD orange edge vignette (§9). |
| **Electrocuted** [v2] | On zap | 0.08 s CC Brightness +0.6 / TintColor #CFFFFF flash, then 0.6 s Saturation -1 with Contrast 0.4, then back. |

---

## 3. Character style

What the trailer shows (s2 c0–1, s4 c3, s6 c7, s8 c0):
- **Bean body.** Head and torso are one rounded blob with no neck. Short stubby legs, chunky boots.
- **Googly eyes.** Two large white spheres near the top of the head, nearly touching, and they
  bulge out of the silhouette. Pupils are small black dots that drift independently, cross-eyed or
  wall-eyed. When knocked out they become spirals (s4 c4), and when panicking they go wide with
  tiny pupils (s6 c7).
- **Tiny mouth.** A small "o" or a flat line, and no nose on civilians.
- **Firefighter kit.** Tan-yellow coat with a lime/silver/lime 3-band at wrists, ankles and chest.
  Olive gloves, a red helmet with a brim and a gold front shield showing a black two-digit number
  (`01`, `02`, `67`). Soot smudges on the sleeves. Grimy and lived-in.
- **Civilians.** A bald, round, pale head, white tee or red hoodie, grey/blue jeans.
- **Pets.** Cat, dog and panda are all chunky with the same googly eyes and a big tongue.

### v1: a uniform blocky rig dressed with welded Parts
Players' own avatars clash with the look, so give everyone the same base.

1. On server start, build a default blocky R15 with
   `Players:CreateHumanoidModelFromDescription(HumanoidDescription.new(), Enum.HumanoidRigType.R15)`.
   Name it `StarterCharacter` and parent it to `StarterPlayer`. The engine adds the default
   `Animate` script to characters that lack one; **verify in a playtest**, and if it's missing copy
   it from a spawned default character. Set `BodyColors` to `CoatYellow` (torso/arms),
   `CoatShadow` (legs) and `SkinWarm` (head).
2. Run `dressFirefighter(character, number)`. All parts are `CanCollide=false`, `Massless=true`,
   `CanQuery=false`, attached with `WeldConstraint`, and kept in a `Folder "Costume"`.
   - **Head blob:** a Ball part 2.4×2.6×2.3 at Head + (0, 0.2, 0), `SkinWarm`. Hide the real
     head's face decal.
   - **Belly blob:** a Ball part 2.8×2.6×2.2 on UpperTorso, `CoatYellow`, so the outline reads as a
     bean.
   - **Eyes:** 2× Ball 1.0 white at head-front ±0.42 X, +0.35 Y, pushed 0.15 past the surface so
     they bulge. Pupils are Ball 0.32 `Pupil` parts with `Motor6D`s (not welds) so the client can
     jiggle them.
   - **Mouth:** a 0.35×0.1×0.05 dark block, or a small `Cylinder` "o" for panic.
   - **Helmet:** a dome (Ball 2.7×1.6×2.9 `HelmetRed`, sitting on the head top), a brim
     (Cylinder 0.25 tall × 3.4 wide, rotated flat, `HelmetRed`, slightly darker), and a front
     shield (block 1.0×0.9×0.15 `HelmetShield`, tilted 15° back). On the shield, a `SurfaceGui`
     (Face Front, `PixelsPerStud 100`) holds a `TextLabel` with the number: `"%02d"`, Font
     `LuckiestGuy`, `NumberInk`, `TextScaled`.
   - **Reflective bands:** a thin ring on each forearm, shin and chest made of 3 stacked blocks
     (lime 0.15, silver 0.12, lime 0.15). Each is 0.05 larger than the limb so it wraps.
   - **Gloves:** a block 1.15× hand size, `GloveOlive`.
   - **Air tank (back):** a Cylinder 0.9×2.0 `TruckChrome` with a red band. **[v2]**
3. **Numbers.** Players get `01`–`04` by join slot. The truck and the NPC chief are `67`.
4. **Pupil jiggle.** One client LocalScript drives everyone's eye motors. Each pupil keeps a
   spring (stiffness 120, damping 8) toward an offset from the head's look vector, plus impulses
   on jump, land, hit and slap. Random wander: every 1–3 s, nudge one pupil 0.08 studs so they
   go "googly". At ~20 characters this is cheap.

### Civilians, NPCs and pets [v1 build, v2 polish]
- **Civilian:** the same rig built from code (`Humanoid` + parts) with no costume. Use `SkinPale`
  plus a `CivTeeWhite` or `CivShirtRed` torso. When KO'd, use the **dizzy eyes**: pupils orbit in a
  circle (rotate the motor C0 around the eye centre at 3 rev/s). This reads like s4 c4's spirals
  without any texture.
- **Charred state** (s4 c6–8): tween every costume and body part to `Charred` over 0.3 s, keep
  the eyes white (that's the joke), and add 2 thin smoke `ParticleEmitter` wisps on the head. When
  extinguished, play a "poof" (§6).
- **Pets.** All are part-built at about 2×2×3 studs. **Dog:** an orange-and-white box body, Ball
  head, a pink block tongue (`#E26A7A`) hanging out, googly eyes. **Cat:** orange Ball body,
  triangle ears from `WedgePart`s, drool via a white Neon drip particle. **Panda:** black-and-white
  Ball stack with black eye patches behind the googly eyes. v2 swaps in meshes (§13).
- **Rainbow character** (s5 c0–1): v2 cosmetic. Hue-cycle all parts with
  `Color3.fromHSV((t*0.3 + i*0.1) % 1, 0.7, 1)`.

---

## 4. Environment kits (part-built modules)

Scale: a character is ~5.5 studs tall with the costume. Doors are 4 W × 7.5 H. Interior ceiling is
11. Wall thickness 1. Floor slab 1. All kits are functions in
`ServerScriptService/World/Kits.luau` with the shape `Kit.build(cframe: CFrame, opts) -> Model`.
Each returns a Model with a `PrimaryPart` and tags its flammable parts (`CollectionService` tag
`Flammable`) and doors (tag `Door`, attribute `Locked`).

| Kit | Tag | Footprint (W×D×H studs) | Contents |
|---|---|---|---|
| **FireStation** | v1 | 64×44×16 | **Apparatus bay** 32×44 with a 18×14 roll-up door opening (a door block that tweens up on alarm). Floor `StationFloor` with yellow 0.4-wide bay lines. **Locker room** 28×20: 4 lockers (3 W × 2 D × 7.5 H, `LockerGrey`, a darker door slab and a vent slot); a bench (10×1.4×2 wood, s2 c0) with gear on it (hose coil = 3 stacked Cylinders 2.4 Ø, `HoseYellow`/`HoseRed`); a gear shelf with 4 helmets and hanging coats (s2 c3). Pegboard wall with an axe and an extinguisher (s1 c8). **Alarm lamps:** 3 on the ceiling (Cylinder housing #6E6A6E + Neon Ball `AlarmRed`). Brick walls `StationBrick` with a 2-stud darker plinth. A sign "STATION 67" on a SurfaceGui above the door. A fire pole (Cylinder 0.5 Ø × 16, `TruckChrome`). [v2] |
| **FireTruck (static)** | v1 | 10×28×10 | Cab 10×8×8 + body 10×20×7, `TruckRed`. A white 1-stud stripe along the side. 6 wheels (Cylinder 3.6 Ø × 1.6, #222). Light bar (2 Neon red + 1 white). Ladder on top (rails `TruckChrome`). A hose reel on the side as the **refill point** (tag `Refill`). "67" on doors and back via SurfaceGui. The back bench is the **rescue drop zone** (tag `RescueZone`, the s8 c0 framing). |
| **FireTruck (drivable)** | v2 | same | `VehicleSeat` + `HingeConstraint` wheels + a siren toggle. |
| **Hydrant** | v1 | 1.6×1.6×3 | Cylinder body + Ball cap + 2 side nozzles, `TruckRed`, brass caps. Tag `Refill`. (s2 c5–6, s4 c2) |
| **SuburbHouse** | v1 | lot 40×40; house 24×18, walls 11, gable roof +6 | Siding colour is random from {Cream, Salmon, Sage, #9EC1CC}. Roof is 2 `WedgePart`s `RoofBrown` with a 1-stud overhang. A porch (8×4 slab + 2 posts). A front door (tag `Door`, sometimes `Locked=true`). 4 windows 4×3.5 (Glass, transparency 0.35, #A8D5E2) with `TrimWhite` frames. **Interior:** 2 rooms split by a wall with a doorway. The living room (s3 c7) has `RoomTeal` walls, a `WoodFloor` floor, a sofa (8×3×3 #6E8A6A in 3 blocks), 2 bookshelves (4×1.4×7 with coloured book blocks), a coffee table and a ceiling lamp. The bedroom has a bed and a dresser. A lawn slab `LawnGreen`, a picket fence (`TrimWhite` 0.4 posts), and a mailbox. Each room gets a `BurningRoom` zone part (invisible, CanCollide false). |
| **TownBlock** | v1 | 180×120 | A 2-lane road 24 wide (`Asphalt`, dashed `TrimWhite` centre line 0.4×4), sidewalks 6 wide, kerbs. 4 house lots + the station at one end. Street lamps every 30 (pole 0.6 × 12, Neon bulb, PointLight). 2 hydrants. Low-poly trees (§ below). A zebra crossing (s5 c5). |
| **ApartmentBlock** | v2 (v1 stretch) | 40×24, 4 storeys × 12 = 48 H | `AptBrick` walls with a darker 1-stud cornice per floor. A 4×2 window grid per facade, windows 4×5. Neighbouring blocks are just boxes with Neon-lit windows (random 30% lit, #FFC97A). A fire escape on one side (grille slabs + rails). A roof water tank. The street at the base has the trampoline spot (s2 c7). |
| **SchoolHallway** | v2 (intro) | 10 W × 80 L × 11 H | The lower 4 studs of wall `SchoolWall`, upper wall #E8D9B0, `SchoolPillar` teal pilasters every 12. Rows of `SchoolLocker` lockers (2×1.5×6.5 each, with vent lines). Floor `SchoolFloor` with a 2×2 tile pattern alternating ±5% brightness. A fluorescent panel every 10 (Neon + SurfaceLight). A red pull station (s1 c4) and double doors at the end. |
| **Farm** | v2 | 120×120 | A haystack (Cylinder 6 Ø × 5 + Ball top, `Hay`, Material `Fabric` for texture). Hay bales 4×3×3. A wooden post-and-rail fence (`FenceWood`, rails 0.4×0.6). A barn 30×20×16 `BarnRed` with a white X trim. The field ground is `Hay` with a darker stripe pattern. |
| **Forest** | v2 | 200×200 | **Low-poly pine:** a trunk Cylinder 1.2 Ø × 6 `TrunkBrown` plus 3 tiers of 4 `CornerWedgePart`s forming pyramids (8, 6, 4 studs wide), `PineFoliage`, each tier rotated 45°. Ground `DryGrass`. Fallen burning logs (Cylinder 2 Ø × 8). Scatter rocks (rotated blocks `DesertRock`). |
| **Dam** | v2 | 200 L × 40 H | A curved wall from 12 angled segments (each 16×40×10, `DamConcrete`) with buttress fins every segment (s7 c3). A deck 10 wide `DamWalkway` with a rail (posts every 4, 2 rails). A detonator prop (a 2×1×1 box, red Neon light, 3 "dynamite" Cylinders #C0342A). A distant city of 30 boxes with Neon fire windows. |
| **DesertRoad intro** | v2 | — | An RV on a road at dusk (s1 c0–2), low-poly rocks and grass blades (thin wedges `DryGrass`). Cinematic only. |
| **LowPolyTree (deciduous)** | v1 | 6×6×12 | A trunk Cylinder 1.2 Ø + 2–3 overlapping Ball canopies (6–8 Ø) in #6F9A3A / #8AAF4A. (s2 c5) |

Prop list for the house interiors [v1, as boxes]: sofa, armchair, coffee table, bookshelf, TV
stand, lamp, flower pot (for the watering-can joke, s3 c7), bed, dresser, kitchen counter and fuse
box [v2].

---

## 5. Fire VFX

A burning part (tag `Burning`, attribute `Intensity` 0..1) owns an `Attachment "FireAtt"` at its
top face. The server only sets attributes. **All emitters are created and updated on the client**
by a `FireVisuals` LocalScript that listens to `CollectionService:GetInstanceAddedSignal("Burning")`.
This keeps replication cheap. **[v1]**

Built-in textures, so nothing needs uploading (**verify in Studio**; they ship with the client):
`rbxasset://textures/particles/fire_main.dds`, `.../smoke_main.dds`, `.../sparkles_main.dds`.

### Flames: ParticleEmitter "Flame" [v1]
```
Texture rbxasset://textures/particles/fire_main.dds
Color   ColorSequence: 0 #FFF6A0, 0.25 #FFB12B, 0.65 #FF5A1F, 1 #7A1F10
Transparency NumberSequence: 0 0.15, 0.7 0.35, 1 1
Size    NumberSequence: 0 1.2*S, 0.35 2.6*S, 1 0.2      (S = part size factor, ~min(X,Z)/4 clamped 0.6..3)
Lifetime 0.45..0.8   Rate 18 + 30*Intensity   Speed 3..6   SpreadAngle (12, 12)
Acceleration (0, 6, 0)   Drag 1.5   Rotation -30..30   RotSpeed -40..40
LightEmission 1   LightInfluence 0   ZOffset 0.5   EmissionDirection Top
Shape Box, ShapeStyle Volume  (emitter on the part itself so flames cover the surface)
```
Cartoon option (closer to the trailer's stylised tongues): a second emitter using a cartoon flame
sprite sheet (`FlipbookLayout Grid4x4`, `FlipbookMode OneShot`). Generate it with Studio MCP
`generate_texture`, or find one with `search_asset` under "cartoon fire flipbook". **[v2]**

### Fire light [v1]
A `PointLight` on FireAtt with Color #FF8A3D, Range 10 + 10×Intensity, Brightness 1.5 + 1.5×Intensity,
Shadows true. The client flicker updates every frame:
`Brightness = base * (0.85 + 0.15*math.noise(t*6, seed))`.
**Budget:** ≤12 shadowed fire lights active per client. Merge the lights of nearby burning parts
into one per room cluster.

### Smoke: ParticleEmitter "Smoke" [v1]
```
Texture smoke_main.dds   Color 0 #5E5A55 → 1 #2A2826
Transparency 0 0.4, 0.2 0.25, 1 1    Size 0 2, 1 9
Lifetime 3..5  Rate 4 + 6*Intensity  Speed 4..7  SpreadAngle (10,10)
Acceleration (0, 2, 0) + Workspace wind   Drag 0.6   RotSpeed -20..20
LightInfluence 1   LightEmission 0   ZOffset 0
```
Outdoor columns (s2 c6): a larger Size (6→20), darker `SmokeBlack`, Lifetime 6, from roof parts.
Indoor rooms (s3 c5) need **puffy cartoon smoke**: client-spawned Ball parts 3–6 Ø, `SmokeGrey`,
SmoothPlastic, Transparency 0.15, tweened up and outward with a slight scale pulse. Cap at 25 per
room. They look exactly like the trailer's clouds. **[v1 stretch / v2]**

### Embers: ParticleEmitter "Embers" [v1]
```
Texture sparkles_main.dds  Color #FFB347  Size 0.15→0  Lifetime 1..2  Rate 6*Intensity
Speed 4..8  SpreadAngle (35,35)  Acceleration (0, 3, 0)  LightEmission 1
```

### Burning → extinguished transition [v1]
- While water hits it, `Intensity` drops (server). The client scales Rate, Size and light.
- At 0, `Emit(25)` a **steam puff** (`SmokeWhite`, Size 2→6, Lifetime 1, Speed 8, Transparency
  0.1→1), play the hiss, and tween the part colour to its `Charred` attribute (default
  `CharredWarm`), Material → `Slate`.
- Over the next 8 s, a weak wisp emitter (Rate 1.5, Size 0.5→2, white) on charred parts shows
  "recently out" (s4 c6).
- Ignition: a 0.2 s `Emit(15)` flame burst with Speed 10, plus a whoosh sound.

### Legacy fallback [v1, fastest]
If ParticleEmitter tuning eats time, `Instance.new("Fire")` with Size 5–10, Heat 9, Color
#FF7A1F, SecondaryColor #FFE45C, together with `Instance.new("Smoke")` with Color #5E5A55,
Opacity 0.15, RiseVelocity 4, Size 3. It looks worse, but it works in 2 lines. Use it as the
first-pass placeholder the agent emits.

### Fire tornado (s6 c7–8) [v2]
A rotating `Attachment` ring: 8 attachments on a 4-stud radius around a vertical axis at 4 heights.
Each has a Flame emitter (Size ×2, Speed 2, Acceleration (0,20,0)), and the client spins the
parent CFrame at 3 rad/s while the radius widens with height (4 → 12). The core is a Cylinder
#80432A at 0.6 transparency for a dark column of smoke. It sucks in loose parts with `VectorForce`.

---

## 6. Water, hose and other VFX

### Hose stream [v1]
The gameplay hit-test is a server raycast or arc sampler (gameplay doc). The visual is client-side
and cosmetic.
- **Stream particles:** an emitter on the nozzle `Attachment` with Texture `sparkles_main.dds`
  (or none), Color `WaterSpray`, Transparency 0.15→0.7, Size 0.5→1.4, Lifetime 0.55, Rate 140,
  **Speed 70**, SpreadAngle (2.5, 2.5), **Acceleration (0, -55, 0)** (the particles arc naturally
  and roughly match the hit-test arc), LightInfluence 0.6, LightEmission 0.2. Turn `Enabled` on
  and off with the mouse.
- **Core Beam:** `Beam` from the nozzle attachment to an attachment at the predicted apex, and a
  second from apex to impact. Width0 0.35 → Width1 1.2, Color `WaterSpray`, Transparency
  0.25→0.55, Segments 16, FaceCamera true, LightEmission 0.3, TextureSpeed 4 if textured. Set
  `CurveSize0/1` from a Bezier fit of the gravity arc.
- **Nozzle burst** (s3 c6's spiky "splash star"): a 2nd emitter at the nozzle with Rate 60,
  Speed 6–12, SpreadAngle (60,60), Lifetime 0.15, white, Size 0.3. This sells the pressure in first
  person.
- **Impact splash:** an attachment at the raycast hit runs `Emit(6)` each frame for droplets
  (Speed 8–14, Acceleration (0,-60,0), Lifetime 0.4). On burning parts it also emits the steam
  puff (§5).
- **Wet decal:** on floor hits, drop a puddle: a Cylinder 0.05 × 4–6 Ø, #7FC8D8, Glass,
  Transparency 0.45, that fades after 20 s. Puddles are also the **electrocution surface** (v2).

### Watering can (joke tool, s3 c7) [v2]
The same stream emitter with Rate 15, Speed 6 and a narrow spread. It extinguishes at 2% of the
hose rate. On a flower pot it plays the "ding" stinger and the flower `Scale`s up 1.3×.

### Electric water (s6 c3–4) [v2]
The puddle part switches to Neon `ElectricCyan`, Transparency 0.3. Add 3 `Beam`s with
Attachment0/1 scattered on the puddle, Width 0.15, LightEmission 1, Color #CFFFFF, and
re-randomise their endpoints every 0.05 s so it looks like crackling arcs. Add a PointLight
#7FF5F0, Range 14, Brightness 4, flickering. A victim on the puddle shows a **skeleton flash**:
toggle the body part colour to #CFFFFF and back at 12 Hz for 0.6 s.

### Axe door break (s4 c1) [v1]
Each hit runs `Emit(8)` wood chips: small block parts, not particles, so they bounce. Spawn 4–6
debris blocks 0.4–0.8 in the door colour with random velocity, and `Debris:AddItem(…, 3)`. Add a
dust puff (smoke texture, `SmokeWhite`, Size 2→6, Lifetime 0.8). On the break, unanchor the door
segments (cut the door into 3–4 planks beforehand) and give them an impulse along the swing
direction.

### Oxygen revive (s4 c4–5) [v2]
A hiss-cloud emitter at the mask (white, Rate 30, Speed 3). The pupils switch from orbit to
normal, then 2 "!" BillboardGui pops.

### Explosion / detonator (s7) [v2]
An `Explosion` instance with BlastPressure 0 (so it doesn't fling players unless intended) plus
our own: a Ball flash part Neon #FFE45C growing 2→16 studs over 0.15 s and fading, debris blocks,
a smoke ring, and camera shake trauma 0.9.

### Tidal wave (s7 c6–8) [v2]
A stack of 3 long `WedgePart`s (200 W, ramped) coloured `WaveDeep`/`WaveMid` with a `WaveFoam`
crest of Ball parts along the top edge. The model tweens forward across the city at 40 studs/s,
and a foam emitter runs along the crest (white, Size 3→8, Speed 10 up). Each fire it passes is
extinguished. Afterwards, `Terrain:FillBlock` a shallow water layer for the flooded town (s8 c0).

### Trampoline (s2 c7) [v2]
A Cylinder 0.6 × 8 Ø with a blue ring `#3A7FD0` and a dark mat, and 6 leg blocks. On catch: squash
tween (Y scale 0.6 → 1.1 → 1), the "boing" sound, and confetti `Emit(30)`.

---

## 7. First-person camera and viewmodel

### Camera [v1]
- `StarterPlayer.CameraMode = LockFirstPerson`, `Camera.FieldOfView = 78` (sprint 86, tweened
  0.2 s). `CameraMaxZoomDistance = 0.5`.
- The engine hides the local body in first person, which is what we want. Other players see the
  costumed third-person body.
- **Head bob:** with `speed = HumanoidRootPart.AssemblyLinearVelocity.Magnitude`,
  `bob = sin(t*10) * 0.06 * clamp(speed/16, 0, 1)` vertical and `cos(t*5) * 0.04` lateral.
  Apply it to the camera after the default camera script via `RunService:BindToRenderStep("FFCam",
  Enum.RenderPriority.Camera.Value + 1, fn)`.
- **Landing dip:** -0.25 Y over 0.08 s, recovering over 0.2 s.
- **Cinematic cameras [v2]:** alarm intro (lamp close-up s1 c6–7, then gear-up), results lineup.
  Use `CameraType Scriptable` and TweenService on `Camera.CFrame`, then hand back to `Custom`.

### Viewmodel arms and gloves [v1]
The trailer's signature is giant gloves taking up the bottom third of the screen. Build a
**client-only Model** in `workspace.CurrentCamera` (only the local player sees it):

```
Viewmodel (Model, all parts CanCollide/CanQuery/CanTouch false, CastShadow false)
  RightArm   block 0.9×0.9×3.2  SleeveTan, with 3-band stripe blocks near the wrist
  RightGlove block 1.2×0.7×1.2  GloveOlive  + 4 finger blocks 0.25×0.25×0.6 + thumb
  LeftArm / LeftGlove mirrored
  GripR / GripL (Attachments in gloves where tools weld)
```
Each `RenderStepped`:
```lua
local base = cam.CFrame * CFrame.new(0, -1.15, -1.6)          -- arms forward/down
local sway = CFrame.Angles(swayY, swayX, 0)                    -- spring toward -mouseDelta*0.002
local bob  = CFrame.new(bobX*0.6, bobY*0.6, 0)
vm:PivotTo(base * bob * sway * toolPose[currentTool] * recoil)
```
- `toolPose`: per-tool CFrame offsets. **Hose:** both hands forward with the nozzle at centre
  (s3 c5–6). **Axe:** right hand raised, left hand low (s1 c8, s4 c1). **Carry:** both arms out
  and up with the NPC welded between the gloves (s4 c3). **Empty:** relaxed hands low (s8 c0).
- **Swing animation** (axe): tween the pose CFrame through windup (-30° pitch, 0.12 s), strike
  (+50°, 0.08 s) and recover (0.25 s). Hit frame = end of strike. Fire the server remote there.
- **Hose recoil:** while spraying, add a small noise jitter (0.01 studs at 25 Hz) plus 2° pitch up.
  This sells pressure.
- **Interact reach** (slap, s5 c2–4): the left glove lunges -0.8 Z in 0.06 s and returns.
- **Soot:** after being near fire for 10 s, darken the sleeve/glove colour 15% (lerp toward
  #3A2A22). It resets at the station.
- Real `Tool` objects still exist for gameplay. Hide their Handle locally
  (`LocalTransparencyModifier = 1`) and weld a client visual copy to `GripR`.
  Third-person views see the normal tool in the character's hand.

---

## 8. Screen shake and juice

**Trauma-based shake** [v1]: a client `Juice` module with `addTrauma(x)` (clamped 0..1), decay
1.6/s, `shake = trauma^2`. Offset angles are `maxAngle * shake * math.noise(seed, t*25)` per axis
(maxAngle 3° pitch/yaw, 2° roll). Apply it in the same BindToRenderStep as the bob.

| Event | Trauma | Extra juice |
|---|---|---|
| Axe hit | 0.25 | 0.04 s FOV punch -3, wood chips |
| Door breaks | 0.5 | Debris burst, "CRACK" text pop |
| Fire ignites near you (<10 studs) | 0.2 | Whoosh, heat vignette pulse |
| Window shatters | 0.3 | Glass shards (Glass blocks) |
| Explosion / detonator | 0.9 | White flash Frame (0.06 s), 0.3 s low-pass muffle (EqualizerSoundEffect on the SFX group, HighGain -30) |
| Electrocuted (self) | 0.6 | Cyan flash, desaturate, buzz, character ragdoll 1.5 s |
| Slapped / slapping | 0.15 | Pupil impulse on the victim, "SLAP!" comic text |
| Fire tornado nearby | continuous 0.25 | Wind sound, ember density ×2 |
| Rescue drop at truck | 0 | Confetti `Emit(40)`, "+1 RESCUED" pop, rising-pitch ding (pitch +5% per consecutive rescue) |
| Fire extinguished | 0.05 | Steam puff, "+FIRE OUT" pop, tank gauge ripples |
| Tank empty | 0.1 | Sputter: the stream particle Rate drops in pulses, gauge shakes |

More juice:
- **World-space text pops:** a `BillboardGui` with a `TextLabel` (LuckiestGuy, UIStroke 3
  `UiInk`, size spring 0 → 1.25 → 1 over 0.25 s), rising 3 studs and fading over 0.8 s. Reuse a
  pool of 10. **[v1]**
- **Squash and stretch** on NPC pickup/drop: tween the costume parts' Size by 1.2/0.85 for 0.12 s.
  **[v2]**
- **Comedic ragdoll** for any hit-by-hazard: `Humanoid:ChangeState(Physics)` plus
  BallSocketConstraints swapped in for Motor6Ds. **[v2]** (v1 uses `PlatformStand` for 1 s.)
- No hit-stop: timescale isn't controllable on Roblox. Simulate it with a 0.05 s camera freeze
  (skip one bob/sway update) on big hits.

---

## 9. HUD

`StarterGui/HUD` (ScreenGui, `IgnoreGuiInset = true`, `ResetOnSpawn = false`). Fonts are
**`LuckiestGuy`** for numbers and headers (it matches the chunky title letters) and **`FredokaOne`**
for body text. Every text gets a `UIStroke` (Thickness 2–3, `UiInk`). Panels are `UiCream` with
`UICorner` 12 and a 3px `UiInk` stroke, sticker-like. Use `UIScale` from
`min(viewport.X/1280, viewport.Y/720)` so it works on phones. **[v1]**

```
┌────────────────────────────────────────────────────────────────────┐
│ [OBJECTIVES card]            ( 2:47 )                 [SQUAD]       │
│  [F] Fires   4 / 9            timer pill               01 ● YOU      │
│  [R] Rescued 1 / 3            red + pulse <30s          02 ● zapped!   │
│  [P] Panda   not found                                  03 ●          │
│                                                                    │
│      ◀ (edge arrow: fire 32m)                                        │
│                                 +                                   │
│                          (small crosshair)                          │
│                                          [E] Break door  (prompt)   │
│                                                                    │
│ [CARRY slot: Dog]                                  ┌──────┐      │
│                                                       │▓▓▓▓▓▓│ TANK │
│  "+1 RESCUED!" toast stack                             │▓▓▓▓  │ 64%  │
│                                                       └──────┘      │
└────────────────────────────────────────────────────────────────────┘
```
([F]/[R]/[P] stand for icons. Use ImageLabels or simple Frame-built icons, not emoji glyphs,
because emoji rendering on Roblox varies by platform.)

| Element | Tag | Spec |
|---|---|---|
| **Mission timer** | v1 | Top centre. A pill 180×56 in `UiCream` with `mm:ss` in LuckiestGuy 40. Under 30 s: text `UiRed`, scale pulse 1→1.12 at 1 Hz, tick sound each second. At 0: a "TIME'S UP!" banner slides down. |
| **Water tank gauge** | v1 | Bottom right. A vertical tank shape 70×180: an outer Frame with a UICorner 20 `UiInk` stroke, and an inner fill Frame anchored at the bottom whose `Size.Y` is the tank fraction, colour `UiWater` with a `UIGradient` (lighter at the top). A small wave: offset a 2nd fill frame's top by `sin(t*4)*2` px. A % label. Under 20% it blinks `UiRed` and shows the hint "REFILL at hydrant / truck". While refilling it shows a rising bubble effect and a glug sound. |
| **Objectives card** | v1 | Top left, 260 wide. Rows: icon + label + `n / total`. A finished row gets a strike-through and a `UiGood` check, with a 0.2 s scale bump. Rows come from the server (`ReplicatedStorage.RoundState` attributes). |
| **Objective markers + edge arrows** | v1 | Each active target (burning cluster, trapped NPC/pet, truck when carrying) gets a `BillboardGui` (AlwaysOnTop, 40×40, icon + distance in m, where 1 m = 3.5 studs for readability). When off-screen, use `Camera:WorldToViewportPoint`. If behind the camera or outside the viewport, project the direction onto an inset ellipse (90% of screen) and draw an arrow ImageLabel rotated toward the target, colour-coded: fire `FireBody`, rescue `UiGood`, truck/refill `UiWater`. Show at most 3 arrows (nearest per category). |
| **Carry slot** | v1 | Bottom left. While carrying, show the carried thing's name and a hint "Bring to TRUCK" with a truck arrow forced on. |
| **Rescue counter** | v1 | Part of the objectives card, plus a big centre toast on each rescue. |
| **Interaction prompts** | v1 | Use `ProximityPrompt` (Style Default in v1, `Custom` with a sticker style in v2): "Break door [E]", "Pick up [E]", "Refill [E]". HoldDuration 0 for pick up and 0.6 for refill start. |
| **Squad list** | v2 (v1 solo shows only YOU) | Top right. Helmet badge (red circle + number), name, status dot: ok / carrying / downed / zapped. |
| **Hazard vignettes** | v1 | Full-screen ImageLabel-free approach: 4 edge Frames with `UIGradient` transparency ramps. Heat = orange #FF6A1F at max 0.55 opacity when near fire. Smoke = grey #5E5A55 in smoke zones. Low health/oxygen = red pulse. |
| **Crosshair** | v1 | A 6×6 white dot with a 1px `UiInk` stroke. It turns `UiWater` when the hose aim would hit a burning part. |
| **Alarm banner** | v1 | Round start: a full-width red strip "ALARM! FIRE AT 12 MAPLE ST." slides in, with a 3 s flash overlay (§2 Alarm). |
| **Walkie messages** | v2 | Bottom-centre subtitle with a walkie icon, from the "chief" (s5 c6–8): "Somebody save the panda!". Static crackle sound. |

---

## 10. Results / Blame screen

**v1 (full-screen GUI)**. It appears 1.5 s after the round ends, with the camera tweened to a fixed
shot of the truck. The background is a sunset gradient Frame (`UIGradient` #407E7B → #EC9438,
rotation 90) at 0.1 transparency over the world, as in the title card s8 c3.

```
┌───────────────────────────────────────────────────────────────┐
│       FLAME AND BLAME          (title letters w/ flame grad)     │
│            MISSION COMPLETE  ★ ★ ☆                               │
│ ┌──────────── TEAM ─────────────┐                               │
│ │ Fires out      7 / 9           │  counts tick up 0→n, 0.6 s    │
│ │ Rescued        3 / 3  (+panda) │  each with a tick sound       │
│ │ Property dmg   $12,400         │                               │
│ │ Water used     1,820 L         │                               │
│ │ Time           2:13            │                               │
│ └────────────────────────────────┘                               │
│   ── THE BLAME ──                                              │
│ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐                 │
│ │ [01]    │ │ [02]    │ │ [01]    │ │ [03]    │  cards flip in  │
│ │HERO OF  │ │THE      │ │PANDA    │ │SHOCKING │  one by one,    │
│ │THE DAY  │ │ARSONIST │ │WHISPERER│ │BEHAVIOR │  0.7 s apart,   │
│ │ 5 fires │ │ $8k dmg │ │ panda: 1│ │ zapped 2│  stinger each   │
│ └─────────┘ └─────────┘ └─────────┘ └─────────┘                 │
│        [ BACK TO STATION ]        [ PLAY AGAIN ]                 │
└───────────────────────────────────────────────────────────────┘
```
- **Award cards:** 200×260 `UiCream`, a coloured header band per award (gold `UiWarn` = good,
  `UiRed` = blame, `UiShock` = electric), a helmet number badge, player name, stat line, and a
  one-line roast in FredokaOne ("Technically the fire did go out."). Flip-in: rotate via a
  `UIScale` X 0→1 squash plus a stamp sound. Blame cards add a **"BLAME!" rubber stamp** label
  rotated -12°, scaling 3→1 with a thud and trauma 0.2.
- **Solo v1:** the same player wins every award. That's funny on its own, so keep it.
- **Award set** (needs counters from gameplay): Hero of the Day (most fires out), The Arsonist (most
  damage / fires spread while nearby), Panda Whisperer (rescued the panda), Shocking Behavior
  (electrocutions caused, v2), Water Waster (most water on non-burning parts), Door Destroyer (doors
  broken), Slap Happy (slaps, v2).
- **Stars:** 1 = time ran out, 2 = all fires out, 3 = all fires out and all rescued.
- **v2:** a 3D podium lineup next to the truck with characters cloned into a `ViewportFrame`
  (or a real world-space lineup cam, s8 c0), a hose-spray "title wipe" animation like s8 c3–6,
  and a "Vote who to blame" button row whose result gets a final "OFFICIALLY BLAMED" card.

---

## 11. Audio

**Structure** [v1]: in `SoundService`, create `SoundGroup`s `Master > {Music, SFX, Ambience, UI,
Voice}`. Each Sound's `SoundGroup` is set. Make a `ReplicatedStorage/Art/Sfx.luau` module:
```lua
Sfx.play(name, at: BasePart|Attachment|nil, opts?)   -- nil → 2D via SoundService:PlayLocalSound
Sfx.loop(name, at) -> stopFn
```
It holds a table `name → {id, volume, pitchVar, rolloff}`. One-shots randomise
`PlaybackSpeed` by ±`pitchVar` (default 0.08) so repeats don't sound robotic. 3D sounds parent to
an attachment: `RollOffMode InverseTapered`, RollOffMinDistance 8, RollOffMaxDistance 120.

**Asset IDs:** don't invent them. Find each with Studio MCP `search_asset` (audio type), prefer
Roblox-uploaded or our own uploads (audio privacy rules block many third-party sounds in other
experiences), test-play in Studio, and record them in `Sfx.luau`. Until then, use the sounds that
ship with the client as placeholders (**verify each path loads**):
`rbxasset://sounds/impact_water.mp3`, `rbxasset://sounds/action_jump.mp3`,
`rbxasset://sounds/electronicpingshort.wav`, `rbxasset://sounds/swoosh.wav`.

| Sound | Group | 2D/3D | Tag | Notes |
|---|---|---|---|---|
| Station alarm klaxon / bell | SFX | 3D at lamps | v1 | Loops 3 s at round start; also 2D at 0.4 vol so it's heard everywhere |
| School fire-alarm bell | SFX | 3D | v2 | Intro cinematic |
| Truck siren (wail) | SFX | 3D on truck | v1 (static truck plays on depart), v2 (driving toggle) | Doppler: tweak PlaybackSpeed from relative velocity |
| Truck engine + horn | SFX | 3D | v2 | Horn = comedic honk |
| Hose start (valve clunk) | SFX | 3D nozzle | v1 | |
| Hose spray loop | SFX | 3D nozzle | v1 | Volume follows the trigger, pitch +0.1 when the tank is full |
| Hose sputter / empty | SFX | 3D | v1 | |
| Refill glug loop | SFX | 3D | v1 | |
| Water hits fire hiss / steam | SFX | 3D impact | v1 | Rate-limited to 4/s |
| Fire crackle loop | Ambience | 3D per fire cluster | v1 | Volume = Intensity; max 6 playing (nearest) |
| Fire ignite whoosh | SFX | 3D | v1 | |
| Big fire roar (bed) | Ambience | 2D | v1 | Volume scales with total burning count |
| Axe chop (wood thunk) | SFX | 3D | v1 | 3 variants |
| Door break crash | SFX | 3D | v1 | |
| Glass shatter | SFX | 3D | v1 | |
| Footsteps (boots) | SFX | 3D | v2 | Replace default |
| Civilian "Help!" / cough | Voice | 3D | v1 | Loop with random gaps 3–6 s, so trapped NPCs are findable by ear |
| Dog bark, cat meow, panda squeak | Voice | 3D | v1 | Same as above for pets |
| Rescue ding (rising pitch) | UI | 2D | v1 | +5% pitch per consecutive rescue |
| Oxygen mask hiss | SFX | 3D | v2 | |
| Slap | SFX | 3D | v2 | Exaggerated cartoon slap |
| Electric zap + buzz loop | SFX | 3D | v2 | |
| Explosion | SFX | 3D | v2 | With EQ muffle (§8) |
| Wave roar | SFX | 2D | v2 | |
| Walkie static / beep | Voice | 2D | v2 | Bracket chief lines |
| Trampoline boing | SFX | 3D | v2 | |
| **Comedic stingers** | UI | 2D | v1 | Sad trombone (fail / time's up), fanfare + "ta-da" (complete), record scratch (Blame card), slide whistle (fall/ragdoll), "ding!" (watering can on flower), kazoo honk (most-damage award) |
| UI click / hover / count tick / stamp thud | UI | 2D | v1 | |
| **Music** | Music | 2D | v1 (1 track) | Station: upbeat funk-brass loop. Mission: faster percussive brass with a tension layer at <30 s (PlaybackSpeed 1.06). Results: short jingle. Use Roblox's licensed library (search_asset "funk", "brass", "comedy"). |

**Mixing:** Music 0.35, Ambience 0.5, SFX 0.8, UI 0.7, Voice 0.9. **Ducking** [v2]: Music gets a
`CompressorSoundEffect` with `SideChain` set to the SFX group, Threshold -25, Ratio 4, so big
sounds punch through. v1 just tweens Music volume to 0.15 for 1 s on stingers. When the camera is
inside a `BurningRoom` zone [v2], the Ambience group gets a `ReverbSoundEffect` (DecayTime 0.8,
WetLevel -6) and an `EqualizerSoundEffect` (HighGain -8) for a muffled smoke feel.

The newer Audio API (`AudioPlayer`/`AudioEmitter`/`AudioListener`) is more flexible but has more
wiring. Stay on `Sound` for the hackathon.

---

## 12. Performance budget

| Item | Budget (per client) |
|---|---|
| Active fire emitter sets (flame+smoke+embers) | ≤ 40; beyond 150 studs set Rate×0.25, beyond 250 disable |
| Shadowed PointLights | ≤ 12 (cluster per room) |
| Total live particles | ≤ 4,000 |
| Puffy smoke Ball parts | ≤ 25 per room, ≤ 80 total |
| Debris parts | ≤ 60, `Debris:AddItem(3)` |
| Map part count (v1 town) | ≤ 6,000; use `Model:PivotTo` and anchored parts everywhere except debris |
| Sounds playing | ≤ 24 (crackles capped at 6 nearest) |

If frame rate drops below 50 in a Studio playtest: switch `Lighting.Technology` to `ShadowMap`,
halve the flame Rate, and turn `Shadows` off on fire lights except the nearest 4.

---

## 13. Generate or source vs build from code

Persistence warning: `place/*.rbxlx` is gitignored, so anything generated or inserted in Studio is
lost unless it's saved. For every generated or inserted asset, either **(a)** record its asset ID
in `ReplicatedStorage/Art/Assets.luau` and load it at runtime with `InsertService:LoadAsset`
(works for assets the experience owner owns), or **(b)** export the model to `.rbxm` under
`game/assets/` and commit it (the sync tool needs to learn `.rbxm`; that's lane B). Strip all
`Script`s from marketplace models before use.

| Thing | v1 | v2 | How |
|---|---|---|---|
| All architecture kits (station, houses, town, apartment, school, dam) | **Code** | Code + `generate_material` MaterialVariants (brick, wood planks, hay, charred wood) | Kits.luau, palette driven |
| Furniture props | **Code** (boxes) | `generate_procedural_model` (sofa, bookshelf, bed). Parts-based, so it stays flammable and editable | 50/day quota, so batch the props list |
| Fire truck | **Code** (static) | `generate_procedural_model` "cartoon fire truck" or a marketplace truck chassis + our paint | Needs the "67" SurfaceGui on top |
| Hydrant, lamp posts, trees, fences | **Code** | Keep code | Cheap and on-style |
| Firefighter body + googly eyes | **Code** (welded parts on R15) | `generate_mesh` "chubby cartoon firefighter potato body, big googly eyes, red helmet" → `segment_mesh` into head/body/helmet so the helmet can be recoloured | 12–20k tris. Use as an accessory-style shell welded to the rig; keep the part-built pupils on top so the jiggle still works |
| Civilians, farmer | **Code** | `generate_mesh` bean civilians (2–3 variants) | |
| Pets: dog, cat, panda | **Code** (ball/block) | **`generate_mesh`** for all three. They're the stars of the trailer (s3 c0–2, s6 c0–1, s8 c0) and worth the quota | The panda is the most important for the store pitch |
| Tools: axe, nozzle, watering can, oxygen tank, walkie, detonator | **Code** (3–6 parts each) | `generate_mesh` hero versions for the viewmodel | The viewmodel is always on screen, so tool meshes pay off |
| Gloves / arms viewmodel | **Code** | `generate_mesh` "thick firefighter glove, low poly" | A mesh glove with fingers looks far better (s2 c0) |
| Fire/smoke/spark textures | Built-in `rbxasset://textures/particles/*` | `generate_texture` or marketplace cartoon flame flipbook | |
| Puffy cartoon smoke | Ball parts | Same | |
| Sounds, music | **Marketplace** (`search_asset`, Roblox library) | Same | Never hard-code guessed IDs |
| UI icons (fire, rescue, truck, tank) | Frames/text | Uploaded PNGs via `upload_image` | |
| Skybox | Default `Sky` + Atmosphere | A custom dusk-gradient skybox texture (6 faces) via generated images | |
| Fonts | `LuckiestGuy`, `FredokaOne` (built-in) | Same | |

**Rule of thumb:** the Forge agent emits **code-built v1 for everything** so a fresh place always
runs from the repo alone. Studio MCP generation and marketplace inserts are a human-curated v2
polish pass, done once and saved per the persistence warning. Their IDs are loaded by code with a
**code-built fallback** if the load fails.

---

## 14. v1 checklist (art/feel only)

- [ ] `Palette.luau`, `LightingPresets.luau` (Dusk Suburb, Night Street, overlays: Alarm, Smoke, Heat)
- [ ] Kits: FireStation, FireTruck (static), Hydrant, SuburbHouse (2 rooms), TownBlock, LowPolyTree
- [ ] Firefighter costume on a uniform R15 StarterCharacter (helmet with number, googly eyes, bands); civilians and 3 pets part-built
- [ ] Fire VFX (flame, smoke, embers, light flicker, ignite and extinguish transitions, charred swap)
- [ ] Hose stream (particles + beam + nozzle burst + splash + puddle)
- [ ] First-person camera (bob, land dip) and viewmodel arms (hose, axe, carry, empty poses)
- [ ] Juice module (trauma shake, text pops, confetti)
- [ ] HUD: timer, tank gauge, objectives card, markers + edge arrows, carry slot, prompts, vignettes, alarm banner
- [ ] Results/Blame screen with count-ups, award cards, stamp
- [ ] Sfx module + SoundGroups; alarm, siren, hose loop, hiss, crackle, axe, break, help/bark, ding, stingers, 1 music loop
