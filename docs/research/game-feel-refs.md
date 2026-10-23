# Game feel, graphics and lobby research (Roblox "Flame and Blame")

Last researched: 23 Oct 2026. Companion to `docs/TARGET_GAME.md` and `docs/game/04-market-and-hooks.md`.
Every section gives: **what the reference games do**, **how to build it in Roblox**, **numbers to start
with**, and **sources**. **[S]** = sourced, **[O]** = our design inference or starting value to tune.

---

## 0. TL;DR build order for v1

1. Hose = client-side raycast + Beam + 2 ParticleEmitters, server validates hits at 10 Hz. Recoil = LinearVelocity
   on own HumanoidRootPart (client owns its character, so it feels instant).
2. Ragdoll = swap Motor6D for BallSocketConstraint (or AJU AnimationConstraints) for 1.5–3 s on knockback, then
   GettingUp. Used for: electrocution, explosions, hose to the face, slaps.
3. Carry NPC/pet = AlignPosition + AlignOrientation to an attachment in front of the camera, ReactionForce off,
   carried thing Massless, network owner = carrier.
4. First person = `CameraMode = LockFirstPerson`, own arms visible via LocalTransparencyModifier, viewmodel
   tool sway/bob via springs, FOV kick on spray/sprint.
5. Look = LightingStyle Realistic, dusk ClockTime ~17.8, Atmosphere + Bloom + ColorCorrection warm grade,
   fire as 3–4 layered flipbook emitters + 1 PointLight per fire cluster (not per fire part).
6. Lobby = fire station is the lobby; one mission instance at a time in-server for the hackathon; reserved
   servers only if we split places later.
7. Juice = spring camera shake, 50–80 ms hit-stop on axe/slap, PowerWash-style "ding + flash" when a room's
   fire hits 0, blame popups.

---

## 1. Funky physics feel

### 1.1 What the reference games do

| Game | Physics trick that makes it funny | Steal for Roblox |
|---|---|---|
| Gang Beasts / Human Fall Flat | *Active ragdoll*: a physics body whose joints apply torques to try to stay upright; any force wins over the "muscles", so characters wobble, flop and grab | Short timed ragdolls on hits; we don't need full active ragdoll [O] |
| Totally Reliable Delivery Service | Arms flail with physics; grab targets the object nearest the camera, which often grabs the wrong thing (players find it funny and annoying) [S] | Grab nearest to the **crosshair ray**, not the camera, to avoid frustration [O] |
| R.E.P.O. | Every valuable is a physics object; a "Phys Grabber" beam holds it; bumping it costs money, friends bump you [S] | Carried panda/cat take "stress" from impacts; teammates can knock it out of your arms [O] |
| Lethal Company | Clumsy deaths + proximity voice = clips [S] | Roblox has proximity voice (VoiceChatService) for 13+; also add text bubbles [O] |
| Overcooked | Too many tasks for the number of players, simple verbs, chaotic level gimmicks [S] | 3–5 fires + 2 rescues + 1 hazard per 3 players per round [O] |
| PowerWash Sim | Huge contrast between dirty and clean; each segment has its own meter and a flash + "Ding!" on completion [S] | Per-room "fire %" meter, flash + ding when a room reaches 0 [O] |
| Firefighting Simulator: The Squad | Real hose pressure/aim indicators; reviewers criticise **no heat feedback** on screen [S] | Our heat vignette fills that gap (section 5) |
| Flame and Blame | "Hoses with real recoil", "water that ruins as much as it saves", axes through doors and walls [S] (04-market doc) | Recoil, water knockback on teammates, wet-floor electrocution |

### 1.2 Hose recoil (and water knockback)

- **Own character is client-owned**, so apply forces from the **LocalScript** of the holder; server-side
  `ApplyImpulse` on a player character does nothing visible because the client owns it [S].
- Recommended: one `LinearVelocity` on HumanoidRootPart, `RelativeTo = World`, `VelocityConstraintMode =
  Plane` (horizontal only), `MaxForce ≈ 4000–8000`, set `PlaneVelocity = -lookXZ * 6` while spraying [O].
  Toggle `Enabled` instead of creating/destroying each frame. Alternative: `VectorForce` with
  `ApplyAtCenterOfMass = true`, Force ≈ `mass * 25` opposite the aim [O].
- High-pressure mode (hold right click): stronger push (`*12`) plus a 3–5° random camera wobble so aiming is
  a skill [O].
- **Water hitting a teammate**: server tells the *victim's* client (RemoteEvent) to apply
  `HRP:ApplyImpulse(dir * mass * 30)`; if `> threshold` for > 0.6 s → ragdoll 1.5 s. This avoids handing network
  ownership to the attacker (an exploiter could fling the target) [S].
- NPCs/pets (server-owned) can take the impulse directly on the server.

### 1.3 Ragdolls (electrocution, explosions, slaps, falls)

- Classic recipe: for each Motor6D create Attachments at `C0`/`C1`, add `BallSocketConstraint`
  (`LimitsEnabled = true`, `TwistLimitsEnabled = true`, `UpperAngle ≈ 45–90`, `TwistLower/Upper ≈ -45/45`),
  disable the Motor6D; to recover, re-enable Motor6Ds and destroy constraints [S].
- Newer avatars use **Avatar Joint Upgrade (AJU)**: joints are already AnimationConstraints + BallSockets; ragdoll by
  turning off AnimationConstraint kinematic mode/zeroing forces, no Motor6D swap needed (EasyRagdoll does this) [S].
- Humanoid side: `Humanoid.BreakJointsOnDeath = false` (so death ragdolls), `RequiresNeck = false` while ragdolled,
  `ChangeState(Physics)` or set `PlatformStand = true`; disable `GettingUp`/`FallingDown`/`Ragdoll` states while
  the custom ragdoll runs. Note `SetStateEnabled` doesn't replicate, so run it on the **owning client** [S].
- Run the toggle on the owner's client for players (instant), on the server for NPCs. Add a tiny
  `ApplyImpulse` on the torso on entry so they fall *away* from the hazard [O].
- Recovery after 1.5–3 s: snap HRP upright (`CFrame.new(pos) * yawOnly`), restore joints, `ChangeState(GettingUp)` [O].
  Known issue: humanoids trip right after getting up; zero `AssemblyLinearVelocity` first [S].
- Electrocution flavour: before ragdoll, 0.4 s of rapid random `C0` jitter or a looping "shock" pose, blue
  `Highlight` flicker, skeleton-flash texture swap if we want the cartoon gag [O].

### 1.4 Carrying people and pets

- `AlignPosition` (OneAttachment mode or to a "hold" attachment on the camera/HRP) + `AlignOrientation`;
  `MaxForce` high or `RigidityEnabled = true`; `ReactionForceEnabled = false` and `ReactionTorqueEnabled = false` so
  the carrier isn't dragged; carried parts `Massless = true` [S].
- Network owner of the carried assembly = **carrier** (`SetNetworkOwner(player)` on the server) so it doesn't lag
  behind [S]. On drop, set owner back to nil (server) or auto.
- Hold point: `camera.CFrame * CFrame.new(0, -1, -4)` updated on `RenderStepped` for a "R.E.P.O. wobble"
  use `Responsiveness ≈ 15–25` instead of rigid [O].
- Carried NPC: set its Humanoid to `Physics`/PlatformStand + light ragdoll so limbs dangle (funny), and disable
  `CanCollide` with the carrier using a CollisionGroup ("Carried" vs "Players") to stop flinging [O].
- Carrier movement penalty: `WalkSpeed *= 0.7` for adults, 0.9 for pets, panda 0.5 (it's heavy, that's the joke) [O].
- Alternative for objects: **DragDetector** (built-in, drag with mouse/touch, works with physics and replicates).

### 1.5 Friendly fire set pieces

- Wet floor + fuse box: water raycasts leave "Wet" decal parts (puddles with `Attribute Wet = true`, lifetime 30 s);
  a live fuse box electrifies puddles within N studs; any player standing on one ragdolls + blame +1 [O].
- Axe swing hitting a teammate: knockback 40 studs/s + hit-stop + "BONK" sound, no damage [O].
- Slap revive: slap a downed teammate 3× to wake them (trailer gag) [O].
- Keep all friendly fire **non-lethal**: knock down, not kill. That's what keeps Gang Beasts-style chaos funny,
  not punishing [O].

### 1.6 Server Authority (new, Jul 2026)

- `Workspace.AuthorityMode = Server` is fully released (9 Jul 2026). It adds prediction + rollback, forces
  StreamingEnabled, deferred signals, fixed simulation and InputAction input [S].
- Caveats: max 8 playing animation tracks per Animator, custom emotes not in default Animate script, RemoteEvents
  not on the shared timeline; constraint/mover-based gameplay may need reworking [S].
- **Recommendation for the hackathon: leave it off.** Client-owned characters make recoil/ragdoll trivially
  responsive; anti-cheat doesn't matter for a co-op demo [O].

Sources:
[Ragdoll module for all characters](https://devforum.roblox.com/t/ragdoll-module-for-all-character/1747109) ·
[EasyRagdoll (AJU)](https://devforum.roblox.com/t/easyragdoll-easy-to-use-ragdoll-module-r15r6/3803829) ·
[easy-ragdoll GitHub](https://github.com/akmalriyas/easy-ragdoll) ·
[Ragdoll Solution R15](https://devforum.roblox.com/t/ragdoll-solution-r15customizable-ragdolls-for-use-with-layered-clothing/1738685) ·
[Better ragdolls code review](https://devforum.roblox.com/t/better-less-scuffed-way-of-creating-ragdolls/3022365) ·
[Humanoid API](https://robloxapi.github.io/ref/class/Humanoid.html) ·
[Disable getting up](https://devforum.roblox.com/t/how-to-disable-player-getting-up/3819574) ·
[Tripping after ragdoll](https://devforum.roblox.com/t/humanoid-tripping-upon-getting-up-from-ragdoll-even-with-tripfix-code-solution/3891736) ·
[ApplyImpulse on server for characters](https://devforum.roblox.com/t/applyimpulse-doesnt-work-on-the-server-for-player-characters/3186898) ·
[Knockback via network owner](https://devforum.roblox.com/t/how-do-i-apply-knockback-by-changing-setting-network-owner/2645551) ·
[Smooth knockback](https://devforum.roblox.com/t/help-with-creating-a-very-smooth-knockback/3161286) ·
[Grab system with Align*](https://devforum.roblox.com/t/grab-system-using-align-position-and-align-rotation/3143049) ·
[Dragging part to player](https://devforum.roblox.com/t/aligning-dragging-part-to-player/3631835) ·
[Active ragdoll balancing](https://medium.com/@jacasch/balancing-of-active-ragdolls-in-games-367f146b25fb) ·
[TRDS Steam](https://steamcommunity.com/app/1011670) · [R.E.P.O. news](https://steamcommunity.com/app/3241660/allnews/) ·
[Overcooked co-op deep dive](https://www.gamedeveloper.com/design/game-design-deep-dive-building-truly-cooperative-play-in-i-overcooked-i-) ·
[Overcooked post-mortem](https://mcvuk.com/development-news/the-develop-post-mortem-overcooked/) ·
[Lethal Company](https://en.wikipedia.org/wiki/Lethal_Company) ·
[PowerWash interview (TouchArcade)](https://toucharcade.com/2023/03/02/powerwash-simulator-interview-lead-designer-final-fantasy-7-dlc-midgar-next-game-ios-port-switch-gyro-support-ps5-dualsense/) ·
[Embr (PCGamesN)](https://www.pcgamesn.com/embr/early-access-launch) ·
[FF Sim review by a firefighter](https://steamcommunity.com/app/420560/discussions/0/2984159549101428658/) ·
[Server Authority full release](https://devforum.roblox.com/t/full-release-ship-fair-and-competitive-games-with-server-authority/4727993) ·
[Roblox newsroom: Server Authority](https://about.roblox.com/newsroom/2026/07/creating-responsive-cheat-resistant-games-roblox-server-authority)

---

## 2. First person

| Technique | Roblox implementation | Start values [O] |
|---|---|---|
| Force 1st person | `StarterPlayer.CameraMode = LockFirstPerson` (or `player.CameraMaxZoomDistance = 0.5`) | For results screen / cutscenes switch `Camera.CameraType = Scriptable` |
| See own arms/legs | Default camera sets `LocalTransparencyModifier = 1`; override to 0 every frame in `BindToRenderStep(name, Enum.RenderPriority.Camera.Value + 1, fn)` for limbs except Head/Torso/HRP [S] | Push camera forward `Humanoid.CameraOffset = Vector3.new(0,0,-1)` so you don't see inside the neck |
| Viewmodel arms | Client-only Model (arms + held tool) in `workspace.CurrentCamera`, set `PrimaryPart.CFrame = camera.CFrame * offset` on RenderStepped; `CanCollide/CanQuery/CastShadow = false`; animate with its own AnimationController/Animator (EgoMoose FPS tutorial pattern; EasyFirstPerson is drag-and-drop) [S] | Offset `CFrame.new(0.6, -0.7, -1.3)` for hose nozzle |
| Sway | Spring on mouse delta (`UserInputService:GetMouseDelta()`), apply as rotation to viewmodel offset [S] | stiffness 12–18, damping 0.6–0.8, clamp ±6° |
| Head/walk bob | Sine on `tick()*speed` scaled by `HRP.AssemblyLinearVelocity.Magnitude / WalkSpeed`; apply via `Humanoid.CameraOffset` or viewmodel offset [S] | freq 8–10 rad/s walk, amp 0.05–0.12 studs; viewmodel bob 2× camera bob |
| FOV kick | `TweenService` on `Camera.FieldOfView` [S] | base 75–80; spray +3; high-pressure +6; sprint +8 over 0.25 s; explosion −10 then back over 0.4 s |
| "Motion blur" | No native motion blur. Use: brief `BlurEffect.Size` 4–8 on explosions, `DepthOfFieldEffect` only in cutscenes, speed-lines ScreenGui image (alpha by velocity), or radial blur fake [S] | Blur pulses ≤ 0.2 s; never during aiming |
| Big cartoon gloves | Viewmodel arms are cheap: oversized gloves + sleeves of the helmet number colour; this is the trailer's look | Glove scale 1.4× |

Mobile: LockFirstPerson works with the touch thumbstick + drag-to-look; put the spray button bottom-right
(`ContextActionService:BindAction(..., createTouchButton = true)`) [O].

Sources:
[EasyFirstPerson](https://devforum.roblox.com/t/easyfirstperson-drag-and-drop-first-person-view-models/1198782) ·
[Viewmodel sway/bob (Egomoose tutorial thread)](https://devforum.roblox.com/t/viewmodel-bugs-swaybobbing-egos-tutorial/397124) ·
[Viewmodel sway with springs](https://devforum.roblox.com/t/how-could-i-create-viewmodel-sway-in-roblox-like-this/2058067) ·
[Viewmodel bobbing](https://devforum.roblox.com/t/how-would-i-make-viewmodel-bobbing/2127356) ·
[Create & animate viewmodel](https://devforum.roblox.com/t/how-to-create-a-viewmodel-and-animate-them/2532720) ·
[Make body visible in 1st person](https://devforum.roblox.com/t/making-body-visible-in-first-person-mode/3395170) ·
[Arms visible in 1st person](https://devforum.roblox.com/t/make-arms-visible-in-first-person/495259) ·
[Realistic camera w/ bob, blur, sprint](https://devforum.roblox.com/t/creating-a-simple-realistic-camera-with-view-bobbing-dynamic-blur-sprinting/646943) ·
[Tween FOV](https://devforum.roblox.com/t/how-to-tween-field-of-view/375560) ·
[Motion blur via DoF](https://devforum.roblox.com/t/motion-blurdepthoffield/1608963)

---

## 3. Graphics that look good (and still run on phones)

### 3.1 Lighting setup

- **Unified Lighting** (live since early 2025): `Lighting.Technology` is deprecated, replaced by
  `LightingStyle` (`Realistic` vs `Soft`) and `PrioritizeLightingQuality` (true = keep shadows/shader quality
  close up, drop view distance first on weak devices) [S]. Use `Realistic` + `PrioritizeLightingQuality = true`
  for a small town map.
- Future/realistic lighting is now on Android too, but shadow-casting local lights are the main cost; shadow
  cost explodes with many dynamic lights near complex geometry [S].

**Dusk "trailer" preset (start values) [O, based on S presets]:**

| Property | Value |
|---|---|
| ClockTime | 17.8 (sunset); night missions 0.5 with moon + streetlights |
| Brightness / ExposureCompensation | 2.5 / 0.1 |
| Ambient / OutdoorAmbient | (70,55,60) / (130,100,95) |
| EnvironmentDiffuseScale / SpecularScale | 0.6 / 1 |
| ShadowSoftness | 0.25 |
| Atmosphere | Density 0.3, Offset 0.1, Color (255,190,150), Decay (110,70,90), Glare 0.4, Haze 1.5 |
| Clouds (in Terrain) | Cover 0.55, Density 0.6, Color warm grey |
| Bloom | Intensity 0.6, Size 24, Threshold 1.6 (fire glows, walls don't) |
| ColorCorrection | Contrast 0.12, Saturation 0.15, TintColor (255,240,225) |
| SunRays | Intensity 0.05, Spread 0.6 |
| DepthOfField | **off in gameplay**; results screen/cutscene only (FocusDistance ~15, InFocusRadius 10, FarIntensity 0.4) |

A realistic-daylight reference preset: ClockTime 13, Brightness 3, Exposure 0.1, Atmosphere Density 0.25/Haze 1,
Bloom 0.2, Contrast 0.08, Saturation 0.05 [S]. "Bloom subtle; DoF light during movement" [S].

### 3.2 Materials

- `MaterialVariant` in `MaterialService` = tileable PBR (Color/Normal/Metalness/Roughness maps) applied by name to
  parts and terrain, and keeps physical properties; `SurfaceAppearance` = per-mesh PBR with UVs [S].
- For our "built from parts" v1: stick to built-in materials (Brick, WoodPlanks, Concrete, Slate, Metal, Fabric);
  add 1–2 MaterialVariants (`ScorchedWood`, `Soot`) and swap `MaterialVariant` on burnt parts — a cheap "burnt"
  state that reads on screen [O]. Burnt = `Color` lerp to (35,30,28) + `Material = CorrodedMetal/Slate` fallback.
- Reuse materials and mesh IDs: identical mesh + SurfaceAppearance batch into one draw call [S].

### 3.3 Fire and smoke that look good

Layered emitters per fire (campfire recipe = 4 emitters: core, outer flame, smoke, sparks) [S]. Flipbooks:
`FlipbookLayout` Grid2x2/4x4/8x8 (8x8 on a 1024² sheet = 64 frames), up to 30 fps, `FlipbookMode = Loop`
(or OneShot), `FlipbookStartRandom = true`; clients auto-disable flipbooks on low memory, so the fallback must look
OK [S].

| Layer | Texture | Rate | Lifetime | Size seq | Speed | Other [O] |
|---|---|---|---|---|---|---|
| Core flame | flame flipbook 4x4 | 15–25 | 0.5–0.9 | 1.5→3→0.5 | 3–5 up | LightEmission 1, LightInfluence 0, Color yellow→orange→red, Transparency 0.2→1, Squash 0→0.4, ZOffset 0.5 |
| Outer flame | soft flame | 6–10 | 0.8–1.2 | 3→5 | 2–4 | LightEmission 0.6, Transparency 0.5→1, Rotation random, RotSpeed ±30 |
| Smoke | smoke flipbook 8x8 | 4–8 | 3–5 | 3→10 | 2–3 up | LightEmission 0, LightInfluence 1, Color (60,55,50)→(120,115,110), Transparency 0.4→1, Drag 1, Acceleration (wind, 2, 0) |
| Embers | small dot | 3–6 | 1–2 | 0.15 | 6–10 | LightEmission 1, Spread 30°, Acceleration (0,4,0), Drag 2 |
| Light | PointLight on 1 part per *cluster* | — | — | — | — | Range 12–16, Brightness 2–4, Color (255,140,60), Shadows only on the biggest fire; flicker Brightness ±0.5 with noise at 10 Hz on client |

Fire strength (0–1) drives `Rate`, `Size` and light Brightness so water visibly shrinks the fire — that's the
PowerWash "visible change" payoff [O]. Extinguish = stop core, burst white **steam** (OneShot, 20 particles,
LightInfluence 1) + hiss sound.

### 3.4 Water spray

- Visual: 1–2 `Beam`s from nozzle attachment to hit attachment (`CurveSize0/1` for a gravity arc, scrolling
  water texture `TextureSpeed 2–3`, `Width0 0.4 → Width1 1.6`, LightEmission 0.3) + a mist ParticleEmitter at
  the nozzle + a splash emitter at the hit point. Don't spawn parts per drop [S].
- Hit detection: client raycasts every frame for the visual; sends `aim` to the server at ~10 Hz; server
  raycasts (or a short arc of 3–4 segments) and extinguishes. Throttle rays [S].
- Splash puddles: decal/part with `Wet` attribute on the floor hit, max 20 per map (pool them) [O].

### 3.5 Budgets (mobile-safe)

| Budget | Value | Source |
|---|---|---|
| Triangles in scene | ≤ 500 k | [S] Roblox staff |
| Draw calls in scene | ≤ 500 (UI ≤ ~150) | [S] |
| Each ParticleEmitter / Beam | 1 draw call each | [S] |
| Active particles | ~150–300 mobile, 500–800 desktop; emitter max rate 400/s (100/s mobile) | [S] |
| Moving physics assemblies | 40–60 | [S] |
| Client network receive | < 50 KB/s | [S] |
| Client memory | < 1.3 GB (2 GB phones) | [S] |
| Shadow-casting local lights | ≤ 4–6 on screen; `CastShadow = false` on small props | [O] + [S] |
| Fires burning at once | cap 12–16 active emitter clusters; merge neighbours into one cluster | [O] |

Sources:
[Unified Lighting live](https://devforum.roblox.com/t/let-there-be-unified-light-unified-lighting-is-fully-live/3401512) ·
[Global lighting docs](https://create.roblox.com/docs/environment/lighting) ·
[Lighting class](https://create.roblox.com/docs/reference/engine/classes/Lighting) ·
[Customize global lighting tutorial](https://create.roblox.com/docs/tutorials/core/building/customize-global-lighting) ·
[Future vs ShadowMap perf](https://devforum.roblox.com/t/future-vs-shadowmap-performance/3246937) ·
[Future on Android](https://devforum.roblox.com/t/future-is-bright-on-android-is-fully-rolled-out-client-beta/3235808) ·
[Future light instance props request](https://devforum.roblox.com/t/future-lighting-needs-to-expose-more-internal-hardcoded-properties-for-light-instances/2580333) ·
[Lighting & atmosphere guide (presets)](https://gamertagmythras.com/blog/roblox/roblox-lighting-atmosphere-guide) ·
[picoo lighting guide](https://picoo.io/how-to-make/roblox-lighting-atmosphere) ·
[Materials docs](https://create.roblox.com/docs/parts/materials) ·
[MaterialService](https://create.roblox.com/docs/reference/engine/classes/MaterialService) ·
[SurfaceAppearance docs](https://github.com/Roblox/creator-docs/blob/main/content/en-us/art/modeling/surface-appearance.md) ·
[Particle emitters docs](https://create.roblox.com/docs/effects/particle-emitters) ·
[ParticleEmitter API](https://create.roblox.com/docs/reference/engine/classes/ParticleEmitter) ·
[Flipbook release](https://devforum.roblox.com/t/particles%E2%80%99-flipbook-release/2029388?page=2) ·
[Custom flipbook layouts beta](https://devforum.roblox.com/t/client-beta-optimize-your-particle-animations-with-custom-flipbook-layouts/4005128) ·
[Particle deep dive (kitsblox)](https://kitsblox.com/blog/roblox-particle-system-deep-dive) ·
[Recreate classic Fire in emitter](https://devforum.roblox.com/t/recreating-the-classic-fire-object-in-a-particle-emitter/2885322) ·
[Performant fire hose](https://devforum.roblox.com/t/ways-to-make-a-performance-effective-fire-hose/234339) ·
[Semi-physical fire hose](https://devforum.roblox.com/t/better-methods-for-generating-a-semi-physically-accurate-fire-hose/1349234) ·
[Water splash tutorial](https://devforum.roblox.com/t/how-to-make-a-realistic-water-splash-effect/2423822) ·
[Real-world optimization (Roblox staff)](https://devforum.roblox.com/t/real-world-building-and-scripting-optimization-for-roblox/3127146) ·
[Optimization for environments](https://devforum.roblox.com/t/optimization-for-roblox-environments/3844846)

---

## 4. Lobby → mission

### 4.1 Patterns in popular games

| Game | Pattern [S] |
|---|---|
| Doors / Pressure | Lobby place with **elevators/queue rooms**: step in, pick max players, countdown, everyone in the room teleports to a fresh reserved server of the game place |
| Dead Rails | Town lobby (shop, cosmetics); originally a train-platform queue, now a **Party ID** code system (host shares a case-sensitive code, friends join before the train leaves; public/private toggle) |
| Deepwoken / big RPGs | Multiple places in one universe, `TeleportAsync` between them with teleport data |

### 4.2 Two ways to do it in Roblox

**A. Separate places + reserved servers (Doors model)**
- Elevator part: on Touched/ProximityPrompt add player to `queue[padId]`, show BillboardGui count + 15–20 s
  countdown (reset to 5 s when full), remove on leave/`PlayerRemoving` [S].
- On zero: `TeleportService:TeleportAsync(missionPlaceId, players, options)` with
  `TeleportOptions.ShouldReserveServer = true` (or `ReserveServerAsync()` + `ReservedServerAccessCode`);
  `options:SetTeleportData({mission = "apartment", squad = ...})` — teleport data is client-visible, don't
  trust it [S]. `ReserveServer` is deprecated → `ReserveServerAsync` [S].
- Wrap in `pcall` + retry 3× on `TeleportInitFailed`. Show a ScreenGui fade before teleport (`SetTeleportGui`).
- **Doesn't work in Studio playtest** (teleports fail in Studio) → bad for our Forge solo-playtest loop [O].

**B. In-server instancing (recommended for the hackathon) [O]**
- One server = fire station lobby + N mission "slots". Each slot is a copy of the mission map cloned from
  `ServerStorage` and pivoted to its own far-away offset (e.g. `x = 2000 * slotIndex`), so missions run in parallel
  without seeing each other. Destroy on round end.
- With StreamingEnabled, clients only stream what's around their character, so far-apart slots cost the client
  nothing; use `player:RequestStreamAroundAsync(spawnPos)` before teleporting the character. Multiple Replication
  Foci (`Player:AddReplicationFocus(part)`) can keep a focus on e.g. the truck [S].
- Lobby pads: 4 "Truck bays", each a squad (1–4). Countdown 10 s, then `char:PivotTo(slot.Spawn.CFrame)` with a
  black fade + siren. Max players per server 12 = 3 parallel squads of 4 [O].
- Everything in one place keeps Studio playtests working and lets ForgeTelemetry see all rounds [O].
- For the trailer feel: the "alarm → gear up → drive" sequence lives in the lobby station; the truck drive can be a
  short scripted/cutscene transition rather than real driving in v1 [O].

Sources:
[Doors-style lobby teleport](https://devforum.roblox.com/t/how-do-i-make-lobby-teleport-system-like-doors-has/2428201) ·
[Lobby/queue system](https://devforum.roblox.com/t/lobbyqueue-system/3909735) ·
[ReserveServer lobby](https://devforum.roblox.com/t/how-to-use-reserveserver-to-make-a-lobby-system/1637565) ·
[Elevator system](https://devforum.roblox.com/t/help-making-elevator-system/3163937) ·
[Party system thread](https://devforum.roblox.com/t/lobby-systemparty-system/1238427) ·
[Teleport between places docs](https://create.roblox.com/docs/projects/teleport) ·
[TeleportService API](https://robloxapi.github.io/ref/class/TeleportService.html) ·
[TeleportOptions doubts](https://devforum.roblox.com/t/i-still-have-a-little-doubt-about-teleportoptions/2031752) ·
[Dead Rails party](https://deadrails.fandom.com/wiki/Party) · [Dead Rails lobby](https://deadrails.fandom.com/wiki/Lobby) ·
[Dead Rails party/queue tutorial (YouTube)](https://www.youtube.com/watch?v=KTS-9A9DLvY) ·
[Multiple Replication Foci](https://devforum.roblox.com/t/new-instance-streaming-feature-multiple-replication-foci/3848736) ·
[Instance streaming best practices](https://devforum.roblox.com/t/instance-streaming-best-practices-and-techniques/4563685)

---

## 5. Heat / health HUD

What references do: Firefighting Simulator shows aim/hose indicators but reviewers (incl. a real firefighter) say
there's **no screen heat feedback** when you walk into a burning room [S]. Embr is about interconnected material
systems (fire eats oxygen and moisture, gas leaks, shocks, explosions) and upgrades like insulated gloves [S].

Recommended HUD for us [O]:

| Element | Implementation | Values |
|---|---|---|
| Heat (replaces health) | 0–100 per player; +X/s from fires within radius (`heat += 25 * strength / dist`), −15/s when away, −40/s when sprayed by teammate (funny-helpful) | At 100 → "overheated" ragdoll + smoke puff, respawn at truck after 5 s, blame +1 to nobody |
| Screen heat | ScreenGui full-screen ImageLabel vignette (orange→red), `ImageTransparency = 1 - heat/100*0.8`; ColorCorrection TintColor shift and slight `BlurEffect` ≥ 80 | Pulse at 1 Hz above 70; heartbeat SFX above 85 |
| Water tank | Vertical bar next to the crosshair (not in a corner — eyes stay on aim); colour flash + "glug" when < 20% | Refill at hydrant/truck 25%/s |
| Room fire % | World-space BillboardGui over each house: "House 3 · 64% burning" and a top bar "Town 42% on fire" | Flash + ding when a room hits 0 (PowerWash) |
| Objectives | Top-left: icons for civilians/pets left (cat, dog, panda), timer top-centre | Timer turns red + ticks under 30 s |
| Teammate markers | BillboardGui with helmet number above heads, always-on-top, coloured by player | Show heat of teammates as a small ring |
| Blame feed | Right-side kill-feed style: "02 electrocuted 01", "03 sprayed the panda" | 4 lines, 4 s each |
| Damage direction | Edge glow on the side the heat comes from | |

Mobile: big buttons bottom-right (spray, tool switch, interact), keep UI draw calls < 150 [S].

Sources:
[FF Sim firefighter review](https://steamcommunity.com/app/420560/discussions/0/2984159549101428658/) ·
[FF Sim review (Gaming Nexus)](https://www.gamingnexus.com/Article/9752/Firefighting-Simulator---The-Squad/) ·
[FF Sim review (PC Invasion)](https://www.pcinvasion.com/firefighting-simulator-review/) ·
[Embr Steam](https://store.steampowered.com/app/1062830/Embr/) ·
[Embr (PlayStation Blog)](https://blog.playstation.com/2021/09/22/play-firefighters-for-hire-in-frantic-multiplayer-embr-out-tomorrow/) ·
[PowerWash interview](https://toucharcade.com/2023/03/02/powerwash-simulator-interview-lead-designer-final-fantasy-7-dlc-midgar-next-game-ios-port-switch-gyro-support-ps5-dualsense/)

---

## 6. Juice

Base reference: Jan Willem Nijman, "The Art of Screenshake" (~30 tricks: big projectiles, muzzle flash, hit-stop,
camera kick, screen shake scaled to event, permanence) [S].

| Juice | Roblox implementation | Start values [O] |
|---|---|---|
| Screen shake | Spring/oscillator-based shaker on the client (SpringShaker, RbxCameraShaker/EZ Camera Shake port, CameraShakeUpdated); apply after the default camera with `BindToRenderStep(Camera+1)` [S] | Hose: constant micro-shake mag 0.15, rough 8. Axe hit: 1.2 for 0.15 s. Explosion: 3–4, fade 0.8 s, scaled by 1/distance. Electrocution: 2, rough 20 |
| Hit-stop | No global timescale. Freeze locally: `AnimationTrack:AdjustSpeed(0)` on attacker + victim for the stop, anchor/zero velocity on the client, then resume [S] | 50–80 ms axe/door, 100 ms slap, 0 for the hose |
| Camera kick | Add a short pitch impulse to a spring | Axe: 3° up, recover 0.2 s |
| Door break | Unanchor door into 3–6 chunk parts, `ApplyImpulse` along swing, Debris after 8 s; dust burst + "CRACK" | Chunks collide with players = funny |
| Sound | `SoundGroup`s (SFX, Music, UI); random `PlaybackSpeed 0.9–1.1` per play so repeats don't sound robotic; layer (crack + thud + debris); `RollOffMaxDistance` 60–100 for 3D | Hose loop with pitch tied to pressure; fire crackle volume tied to fire strength |
| Success ding | Room extinguished: white screen flash (Frame alpha 0.6→1 over 0.25 s) + "ding" + +score popup | PowerWash pattern [S] |
| Popups | BillboardGui text that tweens up and fades ("+10 SAVED", "BLAME +1") with scale overshoot (Back easing) | 0.6 s |
| Emotes | Built-in `/e` emotes work in 3rd person; for 1st person co-op add a quick "point / thumbs-up / facepalm" radial wheel that plays an anim + speech bubble; also show in results screen | Server Authority's default Animate doesn't support custom emotes [S] |
| Results "Blame" screen | Camera cuts to 3rd-person podium, each player gets an award card with a funny title + stat (Overcooked-style end tally) | 2 s per card, confetti ParticleEmitter |
| Viral hooks | Fast onboarding + social trigger + meme theme makes clips/screenshots travel (Grow a Garden, Steal a Brainrot) [S]; the panda and "Blame" awards are our shareable moments | Big readable award titles = screenshot-able |

Sources:
[Art of Screenshake talk (YouTube)](https://www.youtube.com/watch?v=AJdEqssNZ-U) ·
[Screenshake notes](http://notebook.maryrosecook.com/Theartofscreenshake,JanWillemNijman.html) ·
[Screenshake experiments](https://www.bluetengu.com/2014/12/12/art-of-screenshake-experiments/) ·
[Game feel & juice (valdemird)](https://valdemird.com/blog/game-feel-on-the-web/) ·
[SpringShaker](https://devforum.roblox.com/t/v112-springshaker-easy-camera-shaking-manipulation-using-springs/4379144) ·
[EZ Camera Shake port](https://devforum.roblox.com/t/ez-camera-shake-ported-to-roblox/98482) ·
[CameraShakeUpdated](https://devforum.roblox.com/t/camerashakeupdated-simple-camerascreen-shaking-module/3621709) ·
[How to implement hitstop](https://devforum.roblox.com/t/how-to-implement-hitstop/2133285) ·
[Realistic hitstop](https://www.ahmadmohammadnejad.com/sandbox/a-more-realistic-hitstop) ·
[Grow a Garden](https://en.wikipedia.org/wiki/Grow_a_Garden) · [Steal a Brainrot](https://en.wikipedia.org/wiki/Steal_a_Brainrot) ·
[Roblox game ideas that work](https://game-ace.com/blog/roblox-game-ideas-that-actually-work/)
