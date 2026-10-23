# 09 · Graphics Ultra ("shader pack")

Roblox has no custom shaders. What RoShade-style packs and "realistic graphics" games do is stack the
engine's own post effects, grade with layered ColorCorrections, and fake the rest (light shafts, film
grain, lens dirt, wet reflections) with Beams, UI overlays and material tweaks. This doc covers how
Flame and Blame does that in code, and the few settings that have to be set by hand in Studio.

| File | Role |
|---|---|
| `game/StarterPlayerScripts/Controllers/ShaderController.luau` | Client. Picks the tier, grades the screen, overlays, shafts, wet roads, drive FOV, lobby toggle |
| `game/StarterPlayerScripts/ClientLib/PostFx.luau` | Pure maths: tier detection and adaptation, preset modifiers, grade blending, weights, grain (spec: `game/tests/shader.spec.luau`) |
| `game/ReplicatedStorage/Config/ShaderConfig.luau` | Every number: budgets, tier modifiers, grades per preset, overlay strengths |
| `game/ReplicatedStorage/Config/AtmosphereConfig.luau` | The per-location presets (unchanged contract). They are the **High** look |
| `scripts/studio_graphics_setup.luau` | One-time Studio Edit snippet for the settings scripts can't change |

## How it layers

```
AtmosphereService (server)  → lobby baseline on Lighting (Forge_* effects)
GraphicsController (client) → blends to the player's location preset + smoke overlay
   └─ SetPostHook(ShaderController) → ShaderConfig.TierMods[tier] + motion DoF pulse  → written
ShaderController (client)   → Shader_Lift + Shader_Filmic CC (grade per preset)
                              Shader_FireGlow CC (follows FireFx light flicker)
                              Shader_Haze Blur (heat shimmer), ScreenGui "ShaderFx", shaft Beams
```

Cross-lane hooks (kept minimal):
- `GraphicsController:SetPostHook(fn)` and `:MarkDirty()`. The hook edits the composed values just
  before they are written.
- `ProfileSchema.Settings.graphicsQuality` (number 0..3), saved through the existing `Data/Setting`
  remote.
- `DataService` mirrors that setting to the Player attribute `GraphicsQuality`.

## Quality tiers

| | Low | High | Ultra |
|---|---|---|---|
| Global shadows | off | preset | preset (softness x0.8) |
| Bloom / SunRays / DoF | off | preset | Bloom x1.3, Size +8, Threshold −0.15 (fire glows); SunRays x1.6; far DoF +0.06 |
| Atmosphere / Clouds | Clouds density x0.8 | preset | Haze x1.15, Glare +0.15, Density +0.03; Clouds +0.08 |
| Layered grade (Lift + Filmic CC) | off | 60% | 100% |
| Vignette + chromatic fringe | off | on | on |
| Lens dirt / film grain | off | off | on |
| Heat shimmer near fires | off | off | on |
| Fire-glow grade | off | on | on |
| Motion DoF pulse | off | off | on |
| Driving FOV kick | 0 | +8 | +12 |
| Wet roads (night grades) | off | on | on |
| Light shafts | 0 | 0 | 3 (2 Beams each) |

**Auto-detect** (`PostFx.detectTier`):
1. Start from the Roblox graphics slider (`UserGameSettings.SavedQualityLevel`). 1–3 is Low, 4–7 is
   High, 8–10 is Ultra. Automatic gives Ultra on desktop and High on phones and consoles.
2. Phones never auto-pick Ultra.
3. After `Detect.SampleSeconds` (4 s), the measured fps caps the tier: under 30 is Low, under 50 is at
   most High.
4. While in Auto, `PostFx.adaptTier` keeps checking. Below 38 fps for 8 s drops one tier. Above 58 fps
   for 30 s goes back up, but never above what detection allowed.
5. Moving the Roblox slider re-runs detection.

**Toggle:** in the lobby, the `GRAPHICS: AUTO (ULTRA)` button under the XP panel cycles
AUTO → LOW → HIGH → ULTRA. The choice is saved to the profile and restored on join. A forced tier
never adapts. The effective tier is on the local Player attribute `GraphicsTier`, and
`ShaderController:_stats()` shows fps, glow, haze, motion, shafts and wet roads.

## The effects

- **Cinematic grade per location:** `ShaderConfig.Grades[<preset>]`. *Lift* (negative contrast, a bit
  of brightness, a shadow tint) runs first, then *Filmic* (S-curve contrast, saturation, warm highlight
  tint). Together they approximate lift/gamma/gain. Stacked CCs multiply, so tints are global rather
  than shadows-only, which is why they stay subtle. Grades blend over 2.5 s, in step with the lighting.
- **Fire glow:** every frame the controller reads the `Brightness` of FireFxController's own PointLights
  (under each `FireFx` attachment, up to 6 nearest). It turns their falloff-weighted sum into a warm
  tint and brightness. The screen flickers in sync with the real fire lights, and **no lights are
  added**.
- **Heat shimmer:** within 20 studs of burning parts, a BlurEffect oscillates at 7 Hz, together with a
  wavy warm gradient band at the bottom of the screen. This adds to FireFx's world-space `HeatHaze`
  emitters.
- **Vignette + chromatic fringe:** UIGradient edge frames (dark vignette; red left/right and cyan
  top/bottom fringe). They need no assets.
- **Lens dirt:** 7 procedural soft smudges, or a texture if `ShaderConfig.Images.LensDirt` is set. They
  light up when you look toward the sun (`lensWeight`, power 6) or stand near bright fire.
- **Film grain:** two gradient layers (light and dark) re-rolled 24 times a second with random
  keypoints, rotation and offset. Procedural grain shows as a subtle film flicker. For true per-pixel
  grain, put a tileable noise texture in `ShaderConfig.Images.Grain`.
- **Motion feel:** a smoothed camera speed between 16 and 70 studs/s pulses DepthOfField toward
  `MotionDof`, so the far field blurs when sprinting or driving fast. While driving (`DriveSeat`), the
  FOV kick is added *on top of* whatever FirstPersonController and ToolController wrote, using the same
  additive pattern as ToolController.
- **Wet roads:** under grades with `Wet = true` (NightStreet, DamNight, StorageOvercast), road parts in
  `Workspace.Map` get `Reflectance 0.14`. A road part is Asphalt material, or its name contains
  road/street/asphalt/avenue/lane/... (cap 600). The original values are restored when the grade
  changes or the tier drops. The night presets raise `EnvironmentSpecularScale` so the sheen reads.
- **Volumetric light shafts:** on Ultra, fires within 150 studs are clustered every 30 studs. The 3
  nearest clusters each get 2 FaceCamera Beams along the sun direction (the moon direction at night,
  dimmer), with a transparency gradient that fades both ends and the grade's shaft colour. Beams are
  pooled on one local anchor part.

## Performance budgets

- **Low** creates no overlay draws: the ShaderFx gui is disabled, there are no beams, and both blur
  and the fire-glow CC are off. It also turns off global shadows, bloom, sunrays and DoF, which is the
  biggest win on phones.
- **Ultra** costs about 16 small UI frames, at most 6 beams (1 draw call each), 3 extra CCs and 1 blur.
  Fire, light and shaft sampling runs at 4 Hz; the per-frame work is a handful of property writes.
- Vignette and fringe NumberSequences are only rebuilt when their values change. Grain is rebuilt at
  `GrainFps`.

## One-time Studio setup (manual)

Scripts can't set these at runtime. Run `scripts/studio_graphics_setup.luau` once in the **Edit**
datamodel (Command Bar, or StudioMCP `execute_luau`), then save and publish. It returns a report with
`ok`/`FAIL` for each line.

| Setting | Value | Why |
|---|---|---|
| `Lighting.LightingStyle` | `Realistic` (or `Technology = Future` on old Studio) | Shadow-casting fire PointLights, specular |
| `Lighting.PrioritizeLightingQuality` | `true` | Weak devices drop draw distance before lighting quality |
| `MaterialService.Use2022Materials` | `true` | PBR built-in materials: the biggest "not plastic" upgrade |
| `Terrain.Decoration` | `true` | Animated grass |
| Terrain water | reflectance 1, transparency 0.35, small waves | Dam, zoo ponds |
| `Workspace.StreamingEnabled` | **left as-is** (`ENABLE_STREAMING = false`) | Client code assumes the whole map is present. Turn it on only for the v2 city if phones struggle. If enabled, the radii are 192/768 with Opportunistic stream-out |
| Lighting baselines | ShadowSoftness 0.25, Diffuse 0.7, Specular 0.6 | Edit-mode preview only; runtime presets override them |

Not scriptable at all (do these in the Studio UI if wanted):
- **MaterialVariants** (custom PBR textures such as `ScorchedWood` and `Soot`). They need uploaded
  texture ids.
- **SurfaceAppearance** on meshes.

## Third-party shader plugins

You can also install a Creator Store "shader" plugin (for example RoShade) in your own Studio and use
its presets as a reference look. We did **not** install any plugin.

Those plugins only write the same Lighting effects that this code drives, and at runtime
AtmosphereService, GraphicsController and ShaderController overwrite whatever they set on
`Forge_*`/Lighting. To keep a plugin's look:
1. Copy its numbers into `AtmosphereConfig.Presets` and `ShaderConfig.Grades`.
2. Delete any extra effects the plugin added, so they don't double-stack with `Shader_*`.

## Live checks still needed

These haven't been verified in a live playtest yet:
- How the Lift/Filmic CCs stack against the preset CC and the smoke overlay, especially at
  NightStreet.
- That shafts read well at the DuskSuburb sun angle.
- That the grain flicker isn't distracting.
- That the lobby button doesn't overlap the HUD on phones.
- Tuning: everything is in ShaderConfig and can be changed live with
  `require(game.ReplicatedStorage.Config.ShaderConfig).Set(...)` on the client.
