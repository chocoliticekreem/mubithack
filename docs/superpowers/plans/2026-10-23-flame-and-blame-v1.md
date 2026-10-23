# Flame and Blame v1 on Roblox: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. For every Luau/Studio step also follow the `roblox-studio-dev` skill (`.claude/skills/roblox-studio-dev/SKILL.md`).

**Goal:** Ship the v1 Flame and Blame round on Roblox, built by 3 devs and Forge working in parallel. A round goes: alarm, teleport to a burning town, fire spreads, the hose (tank plus refill) puts it out, the axe breaks locked doors, civilians and pets are carried to truck 67, and Blame awards close it out. Record a demo of 3 minutes or less in which a human correction to Forge becomes a recorded fixer call in Mubit.

**Architecture:** Server-authoritative services auto-discovered by `Main.server.luau` (Init/Start, `Priority`, `Enabled`), one controller per client system auto-discovered by `Main.client.luau`, Signals between services, remotes declared per owner through `Shared/Net`, and one config file per system. The kickoff (Task 0) freezes the shared contracts and stubs every §10 API, so the three lanes only *add or replace their own files*. Forge works on a seeded copy (`runs/flame-and-blame/game`), may only add new files there, and its output is promoted by PR.

**Tech Stack:** Luau (`--!strict`), Roblox Studio + Studio MCP (`mcp__Roblox_Studio__*`), `game/tools/sync.py` / `forge watch` pull sync, the `luau` CLI for pure specs, `luau-compile` for syntax checks, Python 3.12 Forge (`forge/`), pytest, GitHub Actions, and Mubit (every LLM call).

**Spec:** `docs/game/03-tech-architecture.md` (backbone: §1 ownership, §2 service contract, §10 interface contracts and the K0 readiness checklist), together with `docs/TARGET_GAME.md` (v1 scope), `docs/game/01-gameplay-systems.md` (§17 build order), `docs/game/02-art-feel-ui.md` (look, HUD, results), `docs/game/05-content-missions.md` (town, NPCs, awards), `docs/game/04-market-and-hooks.md` §7 (the five demo moments), `docs/TEAM.md`, `docs/ARCHITECTURE.md`.

## Global Constraints

- Every LLM call goes through Mubit (base URL plus `MUBIT_API_KEY`). No direct provider calls anywhere, including scripts.
- **Feature freeze Sat 24 Oct 18:00. Submission Sat 23:59** (MP4/MOV demo of 3 minutes or less, plus a PDF deck, via `/submit`). **Hard code freeze Sun 25 Oct 05:00.** Check-ins via `/checkin`: Sat by 12:00, and again Sat 12:00 to 18:00.
- The demo must show a correction turning into a model update: `forge correct` → a fixer call recorded in Mubit's fixer task → Mubit console (Requests: rated Good; Tasks: fixer task count or status).
- Lane checkpoints: **P0 by Sat 10:00, P1 by Sat 14:00, P1.5 by Sat 18:00** (`docs/game/01` §17).
- Only `forge/prompts/*.md` define system prompts. **Never edit them** (Mubit groups calls into tasks by exact system prompt). Put per-call text in user messages.
- Every Luau file starts with `--!strict`, uses tabs and LF line endings, and has a header comment giving owner, API, signals, writes and test hooks. ModuleScript names are unique game-wide. No `init.luau`. `task.*` only (never `wait`/`spawn`/`delay`). No `_G`. Build everything from code with `Instance.new`.
- Every cross-service call is nil-guarded through the `services` table passed to `Init`. Never `require` another service at module top level. No Instances are created at module top level. Remotes are declared only in `Start`, through `Net.event`. Never `InvokeClient`.
- Read config values at use time (`FireConfig.X`) so `DevHook:Invoke("FireConfig", ".Set", key, value)` live-tuning works.
- Pure modules (`Lib/Fire/FireSim.luau`, `Lib/Blame/Awards.luau`) use **no Roblox APIs** (no `game`, `workspace`, `Instance`, `Vector3`, `CFrame`, `Color3`, `task` or `typeof`), so `luau` can run their specs in CI.
- **Shared place "Firefighter Mubit"** (placeId 130153199199668, Team Create) is updated **only from `main`**: `git switch main && git pull && .venv/bin/forge sync --studio Firefighter`, then File → Publish to Roblox. Devs develop in their own local place: `.venv/bin/forge place --open` and then `.venv/bin/forge watch --studio Forge`. Never `forge watch` the shared place.
- Studio MCP: every tool call needs `studio_id` from `mcp__Roblox_Studio__list_roblox_studios`. Pick your **local** place (its name contains `Forge`, no `placeId`). Always finish with `start_stop_play {"is_start": false}`.
- Git: one short branch per task (`g1/…`, `g2/…`, `g3/…`, `gf/…`, `k0/…`) → PR → squash-merge when CI is green. Rebase on `main` before pushing. Never force-push `main`. Commit and push from worktrees before deleting them. Never commit `place/`, `runs/`, `*.rbxlx` or `game/tools/manifest.json`.
- Edit only your lane's files (`docs/game/03` §1). A cross-lane edit goes in its own small PR titled `… [touches Gx]` and is reviewed by that lane's owner.
- Verification for every task: `python3 game/tools/sync.py check --root game` → `OK: checked N files, 0 failed`; `bash game/tests/run.sh` (pure specs); `.venv/bin/python -m pytest -q` (Python); and a live Studio MCP check that reads `ServerStorage.ForgeProbe:Invoke("report")` (`errors` must be `[]`) plus the counters named in the task.

## Team, lanes and schedule

| Lane | Owner | Owns (all under `game/` unless noted) | v1 goal |
|---|---|---|---|
| **K0 Kickoff** | Dev A (Arvin) | `Shared/*` [K], both bootstraps, every stub, `tests/` runner, CI step | Everyone can call any §10 API and get a harmless default |
| **G1 Fire & tools** | Dev B (Anson) | FireService, ToolService, `Lib/Fire/FireSim`, FireConfig, ToolConfig, FireFxController, ToolController, `tests/fire_sim.spec.luau` | Fire spreads part to part; hose with a tank that refills; axe breaks locked doors |
| **G2 World & truck** | Dev A (Arvin) | MapService, VehicleService, AtmosphereService, `Lib/Map/**`, MapConfig, VehicleConfig, AtmosphereConfig, VehicleController, AlarmController | Station 67 plus a 4-house town built from code; truck 67 parks at the scene |
| **G3 Loop & people** | Dev C (third dev; writes their name into TEAM.md in Task 0) | MissionService, RescueService, SquadService, BlameService, `Lib/Rescue`, `Lib/Squad`, `Lib/Blame`, GameConfig, RescueConfig, BlameConfig, Hud/Results/Rescue controllers, `ClientLib/UiKit`, `tests/awards.spec.luau` | 3-minute round, carry civilians and pets to the truck, Blame results screen |
| **GF Forge + Mubit demo** | Dev B (Anson) | `forge/**`, `tests/test_*.py`, `docs/ARCHITECTURE.md`, `runs/flame-and-blame/` (gitignored), **new** files Forge makes in `game/` | Forge builds `FlareUpService`; a human correction becomes a recorded fixer call; Mubit console moments |

Dev B owns the demo lane because G1 is the lightest game lane, and GF.1 and GF.2 need no game code, so Dev B can do them while Task 0 is in flight. Dev A is integration lead.

```
Fri 20:30 ─ K0 (A) ───────────┐            GF.1 forge fixes (B) ─┐  GF.2 Mubit warm-up runs overnight (B, background)
Fri ~21:45 K0 merged ─────────┴─ lanes start ────────────────────┘
           G1 (B): G1.1 → G1.5 ─────────── P0 ── G1.6 ───── P1 ── G1.7 ───── P1.5
           G2 (A): G2.1 → G2.4 ─────────── P0 ── G2.5/6 ─── P1 ── G2.7 ───── P1.5
           G3 (C): G3.1 → G3.3 ─────────── P0 ── G3.4-8 ── P1 ── G3.9 ───── P1.5
Sat 09:30  I.1 Checkpoint A (P0)   10:30 GF.3 Forge builds FlareUpService   12:00 /checkin 1
Sat 13:30  I.2 Checkpoint B (P1)   14:30 GF.4 the correction moment      16:00 GF.5 Mubit console capture
Sat 17:30  I.3 Feature freeze + shared place + multiplayer clips (/checkin 2 before 18:00)
Sat 18:30  I.4 demo video   21:00 I.5 deck + /submit by 23:59   Sun ≤05:00 bug fixes only, resubmit if needed
```

## File structure (v1)

```
.github/workflows/ci.yml                         [K0] + "Luau unit specs" step
docs/TEAM.md                                     [K0] lane table → game lanes
docs/game/03-tech-architecture.md                [K0] §1 + §10 synced with the kickoff decisions
docs/ARCHITECTURE.md                             [GF] runtime-only copy, seed/promote, FORGE_STUDIO
forge/loop.py  forge/cli.py  forge/seed.py       [GF] seeded runs + fixer guard + studio pick
forge/seeds/flame-and-blame.json                 [GF] Forge's spec: one new module, FlareUpService
tests/test_loop.py  tests/test_seed.py           [GF]
game/
  tests/Spec.luau  tests/run.sh  tests/config.spec.luau        [K0] tiny spec runner (not synced)
  tests/fire_sim.spec.luau                                     [G1]
  tests/awards.spec.luau                                       [G3]
  ServerScriptService/
    Main.server.luau                                           [K]  (+ declares Shared/Notify)
    ForgeProbe.server.luau                                     [RT]
    Services/MapService.luau  VehicleService.luau  AtmosphereService.luau  HintService.luau   [G2]
    Services/FireService.luau  ToolService.luau                                  [G1]
    Services/MissionService.luau  RescueService.luau  SquadService.luau  BlameService.luau  KillFeedService.luau   [G3]
    Services/FlareUpService.luau                               [GF] made by Forge, promoted in GF.4
    Lib/Fire/FireSim.luau                                      [G1] pure
    Lib/Tools/DoorBreaker.luau                                 [G1] door hits/reset helper
    Lib/Map/MapKit.luau  Lib/Map/Props/TruckBuilder.luau  Lib/Map/Locations/{Station,Town}Builder.luau  [G2]
    Lib/Rescue/RescueNpcBuilder.luau  Lib/Squad/CostumeBuilder.luau  Lib/Blame/Awards.luau (pure)   [G3]
  ReplicatedStorage/
    ForgeTelemetry.luau                                        [RT]
    Shared/{Net,Signal,Config,Names,Types,Palette}.luau        [K]
    Config/{Game,Rescue,Blame}Config.luau                      [G3]
    Config/{Fire,Tool}Config.luau                              [G1]
    Config/{Map,Vehicle,Atmosphere}Config.luau                 [G2]
  StarterPlayerScripts/
    Main.client.luau                                           [K]
    Controllers/{Hud,Results,Rescue}Controller.luau            [G3]
    Controllers/{FireFx,Tool}Controller.luau                   [G1]
    Controllers/{Vehicle,Alarm}Controller.luau                 [G2]
    ClientLib/UiKit.luau                                       [G3]
```

## Decisions taken where the docs disagree

These choices are binding for every task. Task 0 writes them into `docs/game/03` §10.

1. **03-tech-architecture is the backbone.** Where 01, 02 or 05 use other names (`Tank`, `Intensity`, `DropZone`, `Refill`, `RoundService`, `Remotes.luau`, one `Config.luau`), the 03 §10 names win: `Water`/`TankSize`, `FireLevel`, `RescueDropoff`, `TruckRefill`, `MissionService`, per-owner `Net`, per-system configs.
2. **Round states:** 03's four states (`Lobby | Alarm | Active | Results`), not 01's seven phases. GearUp becomes an automatic loadout (Hose + Axe) at the end of the alarm. Extract is dropped: a rescue counts as soon as it reaches the truck. Timings: Alarm 6 s (01), round 180 s, results 15 s, lobby auto-start 10 s.
3. **Travel is a teleport and the truck is static** (TARGET_GAME v1, 01 §9). Locations use 03's 400-stud slots (Station = slot 0, Town = slot 1), not 05's adjacent layout. At the end of the alarm the truck is pivoted to the town's `TruckSpot` and players are teleported beside it, so rescues are delivered at the scene. A K0 addition, `VehicleService:ParkAt(locationId): boolean`, makes this possible. `VehicleService.Driven` stays declared but never fires in v1.
4. **Fire model:** 03 §5 (part cells, heat/fuel, `FireLevel` 1–3, client-only VFX), not 01's material classes, Intensity, Wet or rooms. The step maths lives in the pure `Lib/Fire/FireSim` (03 §1) so it can be unit tested.
5. **v1 town:** one mission (`Town`, "12 Maple St"), 4 one-storey houses (2-storey houses are v2), 3 FireStart parts and 5 rescues (2 civilians, cat, dog, **panda**). The panda is v1 even though 05 marks it v2, because it is in TARGET_GAME v1 and in 04's demo moment 3. Every rescue is a carry; the dog does not follow on its own in v1.
6. **Who creates ProximityPrompts:** the builders (`MapKit.door`/`hydrant`, `TruckBuilder`) create one prompt per Door/Hydrant/TruckRefill part, as already on `main`. The behaviour belongs to the system lane (ToolService). RescueService creates its own NPCs and their prompts.
7. **Awards:** the v1 catalog is a merge of 05 §7 and 01 §10.3, limited to what v1 can measure, plus *Panda Whisperer* (moved into v1 with the panda) and an always-present Scapegoat line. Each player gets at most 2 awards and at least 1. Stars: 1, plus 1 if every fire is out, plus 1 if every rescue was delivered. Score points and property value are v2.
8. **Types extensions (K0):** `PlayerStats.name`, `PlayerStats.teammateSprayed`, `Award.blame`, `ResultsPayload.burningAtEnd/stars/reason`, plus the types `RescueState`, `EndReason`, `NotifyKind`. **New signal** `ToolService.HoseHit(sprayer, victim)` for friendly fire. **New tags** `TruckSpot` and `AlarmLamp` (`FireStart` and `RescueSpawn` were already added on `main`), and a new attr `Slot`.
9. **`Shared/Notify` is declared by `Main.server.luau`**, because no single service owns it and clients would otherwise wait on a lazily created remote.
10. **Palette:** 02's tokens live in a frozen `ReplicatedStorage/Shared/Palette.luau` [K], since every lane needs colours (02 §1 suggested `Art/Palette`).
11. **Lighting:** the in-progress `AtmosphereService` + `AtmosphereConfig` (G2, already in the working tree) replace 02's `LightingPresets.luau`. `Lighting.Technology` can't be set from scripts, so it stays a manual Studio setting.
12. **Audio, viewmodel arms, onboarding arrows and the watering can** are cut from v1 (v2 appendix). 02 lists them as v1 polish, but none is needed for the five demo moments, and audio needs vetted asset IDs.
13. **Forge's base-file guard:** `Run._base_files` treated every file in `game/` as off-limits and `copy_base_game` copied all of `game/` into every new game. Once the real game lives in `game/`, that would bolt Flame and Blame onto every `forge new`. It would also stop the fixer from repairing a generated `Main.server.luau`, because a file of that name now exists in `game/`. GF.1 changes it: `forge new` copies only the runtime (ForgeProbe, ForgeTelemetry, `tools/`), and `forge seed` copies the whole tree into `runs/flame-and-blame` and records `spec["base_files"]`, which the fixer must not touch. `forge correct` can still edit any file, because a human asked for it.
14. **Forge's demo module** is a new GF file, `FlareUpService` (v1 content: 05 M2's "it reignited" wave, 01 §3.8 random ignitions). It is contained, uses only §10 APIs, and its effect is measurable through the `flareups` counter, so the human correction shows up as a change in a counter.
15. **Kickoff already on `main`** (PR #1, `6467838`): bootstraps, `Shared/{Net,Signal,Config,Names,Types}`, MapConfig, a partial MapService and MapKit. Task 0 *finishes* the kickoff rather than redoing it. Two bugs in the committed MapKit are fixed in G2.1: `wall` sized each chunk's 1-stud thickness along the wall's length, and the hydrant cylinder's length was 1.4.
16. **Lane additions found while writing the lanes:** a G1 remote `Tool/Pushed` (S→C, victim only, `velocity: Vector3`). The victim's client owns its character physics, so the friendly-fire shove must be applied there. G1.7 adds the row to §10. Lane-internal new files: `Lib/Tools/DoorBreaker` (G1), `HintService` (G2), `KillFeedService` (G3). Test hooks beyond the stubs: `FireService:_forget/_water`, `ToolService:_swing/_doorPrompt`, `RescueService:_deliver/_drop/_spawnAt`, `SquadService:_down`, `BlameService:_bump`. NPCs live in `workspace.Rescuables` (not under Map) so a town rebuild can't orphan a carried NPC.

## Reconcile with `main` before starting a lane task (read first)

`main` moved while this plan was being written. PR #2 (`77e4691`) added TruckBuilder, AtmosphereService and AtmosphereConfig, plus the AI playtester. PR #3 (`1a790f7`) added `Lib/Map/Locations/StationBuilder.luau` (795 lines), `Lib/Map/Props/PropKit.luau` and a display-only `Lib/Rescue/NpcBuilder.luau`. The mubit-tester commits added a ForgeTest harness. A `TownBuilder.luau` is in progress in Dev A's working tree. Task 0's files (`Shared/*`, `Main.server`, MapService) were untouched by those PRs, so Task 0 applies as written. For the colliding tasks, **adapt what is on `main` to the contract; don't overwrite it**:

- **G2.2 StationBuilder:** keep `main`'s builder. Apply these three edits in its spawn-pad loop and alarm-light code, and treat G2.2's code block as a reference:
  1. Also set `pad:SetAttribute(Names.Attr.Slot, i)` (keep `Helmet`).
  2. `CollectionService:AddTag(<each AlarmLight's "Bulb" part>, Names.Tag.AlarmLamp)`.
  3. Add one TruckSpot marker in bay 2, using G2.1's `MapKit.marker`: tag `TruckSpot`, attr `LocationId = "Station"`, LookVector = truck forward.

  G2.2's live check is the acceptance test: 4 pads with Slot 1..4, ≥1 AlarmLamp, 1 TruckSpot, ≥1 Hydrant, 0 Flammable.
- **G2.3 TownBuilder:** finish the in-progress file against the contract, or replace it with G2.3's version, whichever is faster. Either way it must meet the contract:
  - RescueSpawn `Kind` is title case `Civilian|Dog|Cat|Panda`. Add the **Panda** behind a locked interior door in House2. `floatguy` is v2.
  - `FireStart` goes on 3 **Flammable** parts (not on invisible points).
  - There is one TruckSpot (`LocationId = "Town"`), and ≥2 locked `MapKit.door`s.

  G2.3's live check counts are the gate. Exact Flammable/Window counts may differ; the minimums are Flammable ≥ 100, FireStart 3, RescueSpawn 5, locked Door ≥ 2, Hydrant 3, TruckSpot 1.
- **G2.4:** the three files are already merged, so only the review checklist remains (no commit). Re-run `forge sync`/watch and confirm AtmosphereService boots without errors.
- **G2.1 MapKit:** `main`'s StationBuilder, TruckBuilder, PropKit and NpcBuilder all call MapKit. Keep every existing function signature when applying G2.1 (it only adds helpers and fixes `wall` sizing and the hydrant cylinder). Re-run the station preview after G2.1, because walls built with `MapKit.wall` change from fins to real walls.
- **G3.5:** G3's carryable NPCs live in `Lib/Rescue/RescueNpcBuilder.luau` (renamed in this plan). `main`'s display `NpcBuilder` stays as it is, available for a v2 station lineup.
- **GF.1:** `forge/cli.py` and `docs/ARCHITECTURE.md` gained the `play`/`mcp`/tester commands. GF.1's edit scripts are anchored on text that still exists. If an assert fires, apply that hunk by hand.

## Task index

| ID | Task | Owner | Lane | Est. | Due |
|---|---|---|---|---|---|
| K0 | Task 0: Kickoff contracts | Dev A | K0 | 1.25 h | Fri ~21:45 |
| G1.1 | FireSim (pure) + spec | Dev B | G1 | 1.0 h | P0 |
| G1.2 | FireService on FireSim | Dev B | G1 | 1.5 h | P0 |
| G1.3 | FireFxController | Dev B | G1 | 0.75 h | P0 |
| G1.4 | ToolService: hose, tank, spray, refill | Dev B | G1 | 1.5 h | P0 |
| G1.5 | ToolController: spray input + streams | Dev B | G1 | 1.0 h | P0 |
| G1.6 | Axe + locked doors (DoorBreaker) | Dev B | G1 | 1.0 h | P1 |
| G1.7 | Friendly-fire hose (HoseHit, Tool/Pushed) | Dev B | G1 | 1.0 h | P1.5 |
| G2.1 | MapKit fixes + helpers | Dev A | G2 | 1.0 h | P0 |
| G2.2 | StationBuilder | Dev A | G2 | 1.0 h | P0 |
| G2.3 | TownBuilder (4 houses) | Dev A | G2 | 1.5 h | P0 |
| G2.4 | Review + commit TruckBuilder / AtmosphereService | Dev A | G2 | 0.5 h | P0 |
| G2.5 | VehicleService (ParkAt) | Dev A | G2 | 0.75 h | P0 |
| G2.6 | AlarmController + VehicleController | Dev A | G2 | 1.0 h | P1 |
| G2.7 | HintService (world hints) | Dev A | G2 | 0.75 h | P1.5 |
| G3.1 | Awards (pure) + spec | Dev C | G3 | 0.75 h | P0 |
| G3.2 | MissionService state machine | Dev C | G3 | 1.5 h | P0 |
| G3.3 | UiKit + HudController | Dev C | G3 | 1.5 h | P0 |
| G3.4 | SquadService + CostumeBuilder | Dev C | G3 | 1.25 h | P0 |
| G3.5 | RescueNpcBuilder + RescueService + RescueController | Dev C | G3 | 2.0 h | P1 |
| G3.6 | BlameService | Dev C | G3 | 0.75 h | P1 |
| G3.7 | ResultsController (Blame screen) | Dev C | G3 | 1.25 h | P1 |
| G3.8 | Fire damage, Downed, revive | Dev C | G3 | 1.0 h | P1 |
| G3.9 | KillFeedService | Dev C | G3 | 0.5 h | P1.5 |
| GF.1 | Seeded runs, fixer guard, FORGE_STUDIO | Dev B | GF | 1.25 h | Fri 21:45 |
| GF.2 | Forge-ai place + Mubit warm-up | Dev B | GF | 0.5 h | Fri night |
| GF.3 | Forge builds FlareUpService | Dev B | GF | 1.0 h | Sat 11:30 |
| GF.4 | Correction moment + promote | Dev B | GF | 1.25 h | Sat 15:45 |
| GF.5 | Mubit console capture | Dev B | GF | 1.0 h | Sat 17:00 |
| I.1 | Checkpoint A (P0) + shared place + check-in 1 | all (lead A) | Int | 1.0 h | Sat 10:30 |
| I.2 | Checkpoint B (P1) + 2-player test + check-in 2 | all (lead A) | Int | 1.0 h | Sat 14:30 |
| I.3 | Feature freeze + gameplay clips | all (lead A) | Int | 1.0 h | Sat 18:30 |
| I.4 | Demo video (≤3:00) | Dev A | Int | 2.5 h | Sat 21:00 |
| I.5 | Deck PDF + /submit | Dev C, Dev A | Int | 2.5 h | Sat 23:30 |

Load: Dev A ≈ 1.25 + 6.5 + integration lead + video. Dev B ≈ 7.75 + 5.0. Dev C ≈ 10.5 + deck.

---

## Task 0: Kickoff contracts (Dev A, Arvin · K0 · ~1.25 h · Fri 20:30 → merged by ~21:45)

> **Done on `main` (Fri 23 Oct, committed straight to `main` in small commits, no PR).** Adjustments to the steps below:
> MapService keeps `main`'s "rediscover builders on every BuildAll" and `GetSpawnCFrame` also matches a pad's `Helmet`
> attr until G2.2 adds `Slot`. TEAM.md's G3 owner is a placeholder (`_Dev C (add your name)_`). Plus the **v1.5
> contracts** (03 §10 "v1.5 additions"): LobbyService/LobbyController/LobbyConfig, MissionCatalog (+ spec),
> MissionService:StartMission/EndMission + MissionStarted/MissionEnded, MapService:BuildInstance/DestroyInstance,
> HeatService/HeatConfig, `Shared/Ragdoll`, FirstPerson/PhysicsFxController, PhysicsConfig, ToolService.HoseRecoil,
> HazardService/HazardController/HazardConfig, FinaleService, AtmosphereService:ApplyLocation/ApplyMission. So
> Step 12 now expects **13 services** (`[Boot] server: 13 services`), **11 controllers**, `sync.py check` = 56 files,
> and remotes `Hazard/Fx, Hazard/Zapped, Lobby/Board, Lobby/Choose, Lobby/Launch, Mission/Alarm, Mission/Results,
> Rescue/Drop, Shared/Notify, Shared/Ragdoll, Tool/Spray`. The "no Lib.Map.Locations" warning no longer appears
> (Station/Town builders are on `main`). AtmosphereService's `_selftest` is `main`'s (boolean only).

Everything in G1/G2/G3 waits for this PR to merge. (GF.1 and GF.2 don't: they touch only `forge/`.) `main` already has the first half of the kickoff (PR #1): bootstraps, `Shared/{Net,Signal,Config,Names,Types}`, MapConfig, a partial MapService and MapKit. This task finishes it.

**Files:**
- Create: `game/tests/Spec.luau`, `game/tests/run.sh`, `game/tests/config.spec.luau`
- Modify: `.github/workflows/ci.yml` (add one step)
- Modify: `game/ReplicatedStorage/Shared/Names.luau`, `game/ReplicatedStorage/Shared/Types.luau`
- Create: `game/ReplicatedStorage/Shared/Palette.luau`
- Modify: `game/ServerScriptService/Main.server.luau` (declare `Shared/Notify`)
- Modify: `game/ServerScriptService/Services/MapService.luau` (finish the §10 API)
- Create stubs: `game/ServerScriptService/Services/{Vehicle,Fire,Tool,Mission,Rescue,Squad,Blame}Service.luau`
- Create stubs: `game/StarterPlayerScripts/Controllers/{Hud,Results,Rescue,FireFx,Tool,Vehicle,Alarm}Controller.luau`
- Create: `game/ReplicatedStorage/Config/{Game,Vehicle,Fire,Tool,Rescue,Blame}Config.luau`
- Modify: `docs/game/03-tech-architecture.md` (§1, §10), `docs/TEAM.md` (lane table)

**Interfaces:**
- Consumes: `main`'s `Shared/{Net,Signal,Config}` (unchanged), `MapConfig.SlotOrigin(slot)`, `ForgeProbe`/`DevHook`.
- Produces (frozen for the weekend): every name in `Names.Tag`/`Names.Attr`; `Types.{RoundState,RescueKind,RescueState,EndReason,NotifyKind,PlayerStats,Award,ResultsPayload}`; `Palette.<Token>: Color3`; every §10 service API (stubbed) plus the K0 additions `VehicleService:ParkAt(locationId): boolean` and `ToolService.HoseHit: Signal<Player, Player>`; remotes `Tool/Spray`, `Rescue/Drop`, `Mission/Alarm`, `Mission/Results`, `Shared/Notify`; the spec runner `bash game/tests/run.sh` with `require("./Spec")` providing `Spec.test/eq/near/truthy/errors/finish`.

- [ ] **Step 1: Branch and set up your local place**

```bash
git switch main && git pull --rebase
git switch -c k0/finish-kickoff
.venv/bin/forge place --open            # builds place/Forge.rbxlx from game/ and opens it in Studio
.venv/bin/forge watch --studio Forge    # leave running in its own terminal; every save -> luau-compile -> Studio
```

- [ ] **Step 2: Write the spec runner test first (it must fail)**

Create `game/tests/config.spec.luau`:

```lua
--!strict
-- Config.define: Set changes a known key and rejects unknown keys.
local Spec = require("./Spec")
local Config = require("../ReplicatedStorage/Shared/Config")

Spec.test("define keeps values", function()
	local c = Config.define({ TickHz = 5 })
	Spec.eq(c.TickHz, 5)
end)

Spec.test("Set changes a known key", function()
	local c = Config.define({ TickHz = 5 }) :: any
	c.Set("TickHz", 10)
	Spec.eq(c.TickHz, 10)
end)

Spec.test("Set rejects an unknown key", function()
	local c = Config.define({ TickHz = 5 }) :: any
	Spec.errors(function()
		c.Set("TikHz", 10)
	end, "unknown key TikHz")
end)

return Spec.finish()
```

Create `game/tests/run.sh`:

```bash
#!/usr/bin/env bash
# Runs every pure-Luau spec under game/tests with the `luau` CLI. Exit 1 if any spec fails.
#   bash game/tests/run.sh
set -u
cd "$(dirname "$0")"
status=0
shopt -s nullglob
specs=(*.spec.luau)
if [ ${#specs[@]} -eq 0 ]; then
  echo "no specs found"
  exit 1
fi
for f in "${specs[@]}"; do
  echo "== game/tests/$f"
  luau "$f" || status=1
done
exit $status
```

Run: `chmod +x game/tests/run.sh && bash game/tests/run.sh`
Expected: FAIL with `error requiring module "./Spec": could not resolve child component "Spec"`; exit code 1.

- [ ] **Step 3: Add the spec helper**

Create `game/tests/Spec.luau`:

```lua
--!strict
-- Tiny spec helper for pure-Luau tests run by the `luau` CLI (not synced into Studio).
--   local Spec = require("./Spec")
--   Spec.test("adds", function() Spec.eq(1 + 1, 2) end)
--   return Spec.finish()   -- prints a summary; errors (exit code 1) if anything failed
-- Modules under test must not touch Roblox APIs (game, workspace, Instance, Vector3, task) at all.

local Spec = {}

local passed, failed = 0, 0

function Spec.test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print(`  ok   {name}`)
	else
		failed += 1
		print(`  FAIL {name}: {err}`)
	end
end

function Spec.eq(actual: any, expected: any, label: string?)
	if actual ~= expected then
		error(`{label or "value"}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

function Spec.near(actual: number, expected: number, eps: number?, label: string?)
	if math.abs(actual - expected) > (eps or 1e-6) then
		error(`{label or "value"}: expected ~{expected}, got {actual}`, 2)
	end
end

function Spec.truthy(v: any, label: string?)
	if not v then
		error(`{label or "value"}: expected truthy, got {tostring(v)}`, 2)
	end
end

function Spec.errors(fn: () -> (), pattern: string?)
	local ok, err = pcall(fn)
	if ok then
		error("expected an error, got none", 2)
	end
	if pattern and not string.find(tostring(err), pattern) then
		error(`error "{tostring(err)}" does not match "{pattern}"`, 2)
	end
end

function Spec.finish()
	print(`{passed} passed, {failed} failed`)
	if failed > 0 then
		error(`{failed} spec(s) failed`, 0)
	end
end

return Spec
```

Run: `bash game/tests/run.sh`
Expected:
```
== game/tests/config.spec.luau
  ok   define keeps values
  ok   Set changes a known key
  ok   Set rejects an unknown key
3 passed, 0 failed
```

- [ ] **Step 4: Run the specs in CI**

In `.github/workflows/ci.yml`, add this step right after the `Luau syntax check` step (same indentation). The existing `Install luau` step already puts `luau` on PATH, because the release zip ships `luau`, `luau-compile` and `luau-analyze`.

```yaml
      - name: Luau unit specs
        run: bash game/tests/run.sh
```

- [ ] **Step 5: Freeze the shared names, types and palette**

Replace `game/ReplicatedStorage/Shared/Names.luau` with:

```lua
--!strict
-- FROZEN (kickoff). Every cross-system tag and attribute name (docs/game/03-tech-architecture.md §10).
-- Use Names.Tag.Flammable, never the string literal, so a typo is a nil error, not a silent miss.

local Names = {}

Names.Tag = table.freeze({
	Flammable = "Flammable", -- BasePart <= 8 studs; MapService builders -> FireService
	Burning = "Burning", -- Flammable part on fire; FireService -> FireFx, Squad, Blame
	Door = "Door", -- door panel with a ProximityPrompt; MapKit.door -> ToolService
	Hydrant = "Hydrant", -- refill part with a ProximityPrompt; MapKit.hydrant -> ToolService
	TruckRefill = "TruckRefill", -- refill part on the truck with a ProximityPrompt; TruckBuilder -> ToolService
	RescueDropoff = "RescueDropoff", -- invisible volume at the truck; TruckBuilder -> RescueService
	Rescuable = "Rescuable", -- NPC Model; RescueService -> RescueController, Hud
	StationSpawn = "StationSpawn", -- 4 spawn pads, attr Slot 1..4; StationBuilder -> MapService/SquadService
	Window = "Window",
	WetFloor = "WetFloor", -- v2
	FuseBox = "FuseBox", -- v2
	Truck = "Truck", -- truck Model; VehicleService -> MissionService, VehicleController
	FireStart = "FireStart", -- Flammable parts that light at round start; builders -> MissionService
	RescueSpawn = "RescueSpawn", -- invisible marker, attr Kind; builders -> RescueService
	TruckSpot = "TruckSpot", -- invisible marker where the truck parks, attr LocationId; builders -> VehicleService
	AlarmLamp = "AlarmLamp", -- Neon lamp part at the station; StationBuilder -> AlarmController
})

Names.Attr = table.freeze({
	Fuel = "Fuel",
	FireLevel = "FireLevel",
	Charred = "Charred",
	LocationId = "LocationId",
	BuildingId = "BuildingId",
	Locked = "Locked",
	Broken = "Broken",
	RescueId = "RescueId",
	Kind = "Kind",
	RescueState = "RescueState",
	CarriedBy = "CarriedBy",
	Water = "Water",
	TankSize = "TankSize",
	Spraying = "Spraying",
	Helmet = "Helmet",
	Carrying = "Carrying",
	Downed = "Downed",
	RoundState = "RoundState",
	RoundEndsAt = "RoundEndsAt",
	MissionId = "MissionId",
	ServerBooted = "ServerBooted",
	MapReady = "MapReady",
	Slot = "Slot", -- StationSpawn pad number 1..4
})

return table.freeze(Names)
```

Replace `game/ReplicatedStorage/Shared/Types.luau` with:

```lua
--!strict
-- FROZEN (kickoff). Cross-system types. See docs/game/03-tech-architecture.md §10.
-- K0 additions to the §10 draft: RescueState, EndReason, NotifyKind, PlayerStats.name and
-- .teammateSprayed, Award.blame, ResultsPayload.burningAtEnd/.stars/.reason.
export type RoundState = "Lobby" | "Alarm" | "Active" | "Results"
export type RescueKind = "Civilian" | "Dog" | "Cat" | "Panda"
export type RescueState = "Trapped" | "Carried" | "Downed" | "Rescued"
export type EndReason = "time" | "allOut" | "forced"
export type NotifyKind = "info" | "good" | "bad" | "blame"
export type PlayerStats = {
	userId: number,
	helmet: number,
	name: string,
	firesOut: number,
	firesStarted: number,
	water: number,
	doors: number,
	rescued: number,
	pandas: number,
	downedOthers: number,
	timesDowned: number,
	teammateSprayed: number,
}
export type Award = { id: string, title: string, userId: number, value: number, blurb: string, blame: boolean }
export type ResultsPayload = {
	locationId: string,
	seconds: number,
	firesOut: number,
	burnedParts: number,
	rescued: number,
	trapped: number,
	burningAtEnd: number,
	stars: number,
	reason: EndReason,
	awards: { Award },
	stats: { PlayerStats },
}
return {}
```

Create `game/ReplicatedStorage/Shared/Palette.luau`:

```lua
--!strict
-- FROZEN (kickoff). Colour tokens from docs/game/02-art-feel-ui.md §1. Every builder, VFX and UI
-- script takes colours from here (never BrickColor.Random or grey defaults). Adding a token is a
-- one-line PR; renaming one is not.

local Palette = table.freeze({
	-- fire, smoke, water
	FireCore = Color3.fromHex("#FFF6A0"),
	FireBody = Color3.fromHex("#FFB12B"),
	FireEdge = Color3.fromHex("#FF5A1F"),
	FireDark = Color3.fromHex("#7A1F10"),
	SmokeGrey = Color3.fromHex("#5E5A55"),
	SmokeWhite = Color3.fromHex("#EAE6DF"),
	SmokeBlack = Color3.fromHex("#2A2826"),
	WaterSpray = Color3.fromHex("#A9E3F0"),
	Charred = Color3.fromHex("#1F1A19"),
	CharredWarm = Color3.fromHex("#3A2A22"),
	-- firefighters and characters
	CoatYellow = Color3.fromHex("#D9A030"),
	CoatShadow = Color3.fromHex("#9A6A30"),
	ReflectLime = Color3.fromHex("#E8E25A"),
	ReflectSilver = Color3.fromHex("#C9CCD0"),
	GloveOlive = Color3.fromHex("#8C7A3A"),
	HelmetRed = Color3.fromHex("#C0301E"),
	HelmetShield = Color3.fromHex("#E8C24A"),
	NumberInk = Color3.fromHex("#1A1210"),
	SkinWarm = Color3.fromHex("#D98A4E"),
	SkinPale = Color3.fromHex("#F0C49C"),
	EyeWhite = Color3.fromHex("#FFFFFF"),
	Pupil = Color3.fromHex("#111111"),
	CivShirtRed = Color3.fromHex("#CF442B"),
	CivTeeWhite = Color3.fromHex("#F2EEE6"),
	-- vehicles, props, architecture
	TruckRed = Color3.fromHex("#C8232B"),
	TruckChrome = Color3.fromHex("#D6D8DC"),
	HoseYellow = Color3.fromHex("#E8B83A"),
	BrassCoupling = Color3.fromHex("#C89A3C"),
	StationBrick = Color3.fromHex("#BF4835"),
	StationFloor = Color3.fromHex("#8A7470"),
	FloorLineYellow = Color3.fromHex("#E3B23C"),
	LockerGrey = Color3.fromHex("#6E6A6E"),
	WoodFloor = Color3.fromHex("#C8683A"),
	RoomTeal = Color3.fromHex("#4F8A85"),
	BookshelfWood = Color3.fromHex("#8A4A28"),
	SidingCream = Color3.fromHex("#E8D3A8"),
	SidingSalmon = Color3.fromHex("#D98B6F"),
	SidingSage = Color3.fromHex("#9DB38A"),
	SidingBlue = Color3.fromHex("#9EC1CC"),
	RoofBrown = Color3.fromHex("#5A3A32"),
	TrimWhite = Color3.fromHex("#F2EDE4"),
	LawnGreen = Color3.fromHex("#7FAF4A"),
	Asphalt = Color3.fromHex("#4A4650"),
	Sidewalk = Color3.fromHex("#C9B8A8"),
	AlarmRed = Color3.fromHex("#FF2A2A"),
	-- UI
	UiInk = Color3.fromHex("#2A1410"),
	UiCream = Color3.fromHex("#FFF1D6"),
	UiPanelDark = Color3.fromHex("#1E1A22"),
	UiRed = Color3.fromHex("#D9372A"),
	UiWater = Color3.fromHex("#4FB3D9"),
	UiWarn = Color3.fromHex("#FFC531"),
	UiGood = Color3.fromHex("#6BCB5A"),
	UiShock = Color3.fromHex("#7FF5F0"),
	UiFlameTop = Color3.fromHex("#FFE45C"),
	UiFlameMid = Color3.fromHex("#FF8A1F"),
	UiFlameLow = Color3.fromHex("#C8231B"),
	SkyTitleTop = Color3.fromHex("#407E7B"),
	HorizonOrange = Color3.fromHex("#EC9438"),
})

return Palette
```

- [ ] **Step 6: Declare `Shared/Notify` in the server bootstrap**

Replace `game/ServerScriptService/Main.server.luau` with the following. It is identical to `main` except for the 4 lines before the Start loop.

```lua
--!strict
-- FROZEN (kickoff PR). Boots every ModuleScript directly under ServerScriptService/Services whose
-- name ends in "Service". Adding a service = adding a file; nothing else changes.
--   1. require all (sorted by Priority, then name)   - no yields, no Instances at module top level
--   2. Init(self, services) on each                  - grab peers, create Signals; no cross-calls
--   3. Start(self) on each, each on its own thread   - remotes, loops, cross-service calls
-- A service that errors in require/Init is dropped (warned, ForgeProbe records it); the rest run.
-- A WIP service merged into main sets `Enabled = false` and is skipped.

local ServerScriptService = game:GetService("ServerScriptService")

type Entry = { name: string, mod: any, priority: number, ok: boolean }

local folder = ServerScriptService:WaitForChild("Services")
local services: { [string]: any } = {}
local entries: { Entry } = {}

for _, child in folder:GetChildren() do
	if not child:IsA("ModuleScript") or not string.match(child.Name, "Service$") then
		continue
	end
	local ok, mod = pcall(require, child)
	if not ok then
		warn(`[Boot] require {child.Name} failed: {mod}`)
		continue
	end
	if type(mod) ~= "table" or (mod :: any).Enabled == false then
		continue
	end
	services[child.Name] = mod
	table.insert(entries, {
		name = child.Name,
		mod = mod,
		priority = tonumber((mod :: any).Priority) or 100,
		ok = true,
	})
end

table.sort(entries, function(a: Entry, b: Entry): boolean
	if a.priority ~= b.priority then
		return a.priority < b.priority
	end
	return a.name < b.name
end)

for _, e in entries do
	if type(e.mod.Init) == "function" then
		local ok, err = pcall(e.mod.Init, e.mod, services)
		if not ok then
			warn(`[Boot] {e.name}:Init failed: {err}`)
			e.ok = false
			services[e.name] = nil
		end
	end
end

-- Shared/Notify belongs to no single service (anyone calls Net.notify), so the bootstrap declares
-- it before any Start runs. Clients' Net.event("Shared", "Notify") then never waits on a lazy remote.
local Net = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Net") :: ModuleScript)
Net.event("Shared", "Notify")

for _, e in entries do
	if e.ok and type(e.mod.Start) == "function" then
		task.spawn(function()
			local ok, err = pcall(e.mod.Start, e.mod)
			if not ok then
				warn(`[Boot] {e.name}:Start failed: {err}`)
			end
		end)
	end
end

workspace:SetAttribute("ServerBooted", true)
print(`[Boot] server: {#entries} services`)
```

- [ ] **Step 7: Finish MapService's §10 API**

On `main`, `discover()` uses `WaitForChild` on `Lib/Map/Locations`, which yields forever (so `MapReady` is never set) until G2 adds a builder. `RandomFlammable` is missing, `GetSpawnCFrame` ignores the pads, and `_selftest` returns no message. Replace `game/ServerScriptService/Services/MapService.luau` with:

```lua
--!strict
-- MapService [owner: G2]. Builds Workspace.Map from every ServerScriptService/Lib/Map/Locations/*Builder.
-- Builder contract: { Id: string, Slot: number, Build(model: Model, origin: CFrame, rng: Random) }.
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   MapService:GetLocation(id: string): Model?
--   MapService:GetLocations(): { [string]: Model }
--   MapService:RebuildLocation(id: string): Model?       -- round reset; fires LocationBuilt again
--   MapService:GetSpawnCFrame(slot: number): CFrame      -- StationSpawn pad 1..4, 3 studs up
--   MapService:RandomFlammable(id: string, rng: Random): BasePart?
--   MapService:BuildAll(): number                        -- ms taken; also works in Edit (preview)
-- Signals: LocationBuilt(model: Model, locationId: string)
-- Writes: Workspace.Map.<Id> (attr LocationId), Workspace attr MapReady, counter map_build_ms
-- Test hooks (DevHook only): _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local MapConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MapConfig") :: ModuleScript)

local MapService = {}
MapService.Priority = 0
MapService.LocationBuilt = Signal.new() :: Signal.Signal<Model, string>

local locations: { [string]: Model } = {}
local builders: { [string]: any } = {}

local function hash(s: string): number
	local h = 0
	for i = 1, #s do
		h = (h * 31 + string.byte(s, i)) % 1000003
	end
	return h
end

local function mapFolder(): Folder
	local f = workspace:FindFirstChild("Map")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Map"
		f.Parent = workspace
	end
	return f :: Folder
end

local function locationsFolder(): Instance?
	local lib = ServerScriptService:FindFirstChild("Lib")
	local map = lib and lib:FindFirstChild("Map")
	return map and map:FindFirstChild("Locations")
end

local function discover()
	local dir = locationsFolder()
	if not dir then
		warn("[MapService] no ServerScriptService.Lib.Map.Locations yet: the map is empty")
		return
	end
	for _, child in dir:GetChildren() do
		if child:IsA("ModuleScript") and string.match(child.Name, "Builder$") then
			local ok, b = pcall(require, child)
			if ok and type(b) == "table" and type(b.Build) == "function" and b.Enabled ~= false then
				builders[b.Id or child.Name] = b
			else
				warn(`[MapService] skip {child.Name}: {if ok then "bad builder" else b}`)
			end
		end
	end
end

function MapService:BuildLocation(id: string): Model?
	local b = builders[id]
	if not b then
		return nil
	end
	local old = mapFolder():FindFirstChild(id)
	if old then
		old:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = id
	model:SetAttribute(Names.Attr.LocationId, id)
	local rng = Random.new(MapConfig.Seed + hash(id))
	local ok, err = pcall(b.Build, model, MapConfig.SlotOrigin(b.Slot or 0), rng)
	if not ok then
		warn(`[MapService] {id}.Build failed: {err}`)
	end
	model.Parent = mapFolder() -- parent once, after building (fast)
	locations[id] = model
	MapService.LocationBuilt:Fire(model, id)
	return model
end

function MapService:BuildAll(): number
	if next(builders) == nil then
		discover()
	end
	local t0 = os.clock()
	local ids = {}
	for id in builders do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		MapService:BuildLocation(id)
	end
	workspace:SetAttribute(Names.Attr.MapReady, true)
	return math.floor((os.clock() - t0) * 1000)
end

function MapService:GetLocation(id: string): Model?
	return locations[id]
end

function MapService:GetLocations(): { [string]: Model }
	return locations
end

function MapService:RebuildLocation(id: string): Model?
	return MapService:BuildLocation(id)
end

function MapService:GetSpawnCFrame(slot: number): CFrame
	local station = locations.Station
	if station then
		for _, d in station:GetDescendants() do
			if d:IsA("BasePart") and d:HasTag(Names.Tag.StationSpawn) and d:GetAttribute(Names.Attr.Slot) == slot then
				return d.CFrame * CFrame.new(0, 3, 0)
			end
		end
	end
	return MapConfig.SlotOrigin(0) * CFrame.new((slot - 1) * 4, 5, 0)
end

function MapService:RandomFlammable(id: string, rng: Random): BasePart?
	local model = locations[id]
	if not model then
		return nil
	end
	local list: { BasePart } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:HasTag(Names.Tag.Flammable) and d:GetAttribute(Names.Attr.Charred) ~= true then
			table.insert(list, d)
		end
	end
	if #list == 0 then
		return nil
	end
	return list[rng:NextInteger(1, #list)]
end

function MapService:Start()
	local ms = MapService:BuildAll()
	pcall(function()
		require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript).count("map_build_ms", ms)
	end)
	print(`[MapService] built {#mapFolder():GetChildren()} locations in {ms} ms`)
end

function MapService:_selftest(): (boolean, string)
	if workspace:GetAttribute(Names.Attr.MapReady) ~= true then
		return false, "MapReady not set"
	end
	return true, `{#mapFolder():GetChildren()} locations`
end

return MapService
```

- [ ] **Step 8: Stub every other service (exact §10 APIs, harmless defaults, remotes declared)**

Each stub is replaced wholesale by its lane later. Lanes keep the header API block, so it stays the contract.

`game/ServerScriptService/Services/VehicleService.luau`:

```lua
--!strict
-- VehicleService [owner: G2]. STUB from K0: harmless defaults until G2 replaces this file.
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   VehicleService:GetTruck(): Model?
--   VehicleService:ResetTruck()                         -- back to the station bay (= ParkAt("Station"))
--   VehicleService:ParkAt(locationId: string): boolean  -- pivot the truck onto that location's TruckSpot
-- Signals: Driven(driver: Player, studs: number)        -- v2 (drivable truck); never fires in v1
-- Writes: Workspace.Truck67 (tag Truck) with parts tagged TruckRefill and RescueDropoff
-- Test hooks (DevHook only): _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Signal") :: ModuleScript)

local VehicleService = {}
VehicleService.Priority = 50
VehicleService.Driven = Signal.new() :: Signal.Signal<Player, number>

local services: { [string]: any } = {}

function VehicleService:Init(all: { [string]: any })
	services = all
end

function VehicleService:Start() end

function VehicleService:GetTruck(): Model?
	return nil
end

function VehicleService:ResetTruck() end

function VehicleService:ParkAt(_locationId: string): boolean
	return false
end

function VehicleService:_selftest(): (boolean, string)
	return true, "stub"
end

return VehicleService
```

`game/ServerScriptService/Services/FireService.luau`:

```lua
--!strict
-- FireService [owner: G1]. STUB from K0: harmless defaults until G1 replaces this file.
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   FireService:Ignite(part: BasePart, cause: Player?): boolean
--   FireService:ApplyWater(player: Player?, origin: Vector3, aim: Vector3, litres: number): number
--   FireService:IsBurning(part: BasePart): boolean
--   FireService:CountBurning(locationId: string?): number
--   FireService:ExtinguishAll()
-- Signals: Ignited(part, cause: Player?), Spread(from, to), Extinguished(part, by: Player?), Charred(part)
-- Writes: tag Burning; attrs FireLevel (1..3), Charred on Flammable parts
-- Test hooks (DevHook only): _index(model, locationId), _ignite(pos), _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Signal") :: ModuleScript)

local FireService = {}
FireService.Priority = 50
FireService.Ignited = Signal.new() :: Signal.Signal<BasePart, Player?>
FireService.Spread = Signal.new() :: Signal.Signal<BasePart, BasePart>
FireService.Extinguished = Signal.new() :: Signal.Signal<BasePart, Player?>
FireService.Charred = Signal.new() :: Signal.Signal<BasePart>

local services: { [string]: any } = {}

function FireService:Init(all: { [string]: any })
	services = all
end

function FireService:Start() end

function FireService:Ignite(_part: BasePart, _cause: Player?): boolean
	return false
end

function FireService:ApplyWater(_player: Player?, _origin: Vector3, _aim: Vector3, _litres: number): number
	return 0
end

function FireService:IsBurning(_part: BasePart): boolean
	return false
end

function FireService:CountBurning(_locationId: string?): number
	return 0
end

function FireService:ExtinguishAll() end

function FireService:_index(_model: Instance, _locationId: string) end

function FireService:_ignite(_pos: Vector3): BasePart?
	return nil
end

function FireService:_selftest(): (boolean, string)
	return true, "stub"
end

return FireService
```

`game/ServerScriptService/Services/ToolService.luau`:

```lua
--!strict
-- ToolService [owner: G1]. STUB from K0: harmless defaults until G1 replaces this file.
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   ToolService:GiveLoadout(player: Player)              -- Hose + Axe, full tank
--   ToolService:Refill(player: Player, litres: number?)  -- nil = full
--   ToolService:ResetDoors(locationId: string)
-- Signals: DoorBroken(player, door: BasePart), WaterUsed(player, litres: number),
--          HoseHit(sprayer: Player, victim: Player)      -- K0 addition (friendly fire, P1.5)
-- Remotes: Tool/Spray (C->S, aim: Vector3 unit, 12/s burst 4)
-- Writes: Player attrs Water, TankSize, Spraying; Door attrs Locked, Broken
-- Test hooks (DevHook only): _spray(player, aim), _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)

local ToolService = {}
ToolService.Priority = 50
ToolService.DoorBroken = Signal.new() :: Signal.Signal<Player, BasePart>
ToolService.WaterUsed = Signal.new() :: Signal.Signal<Player, number>
ToolService.HoseHit = Signal.new() :: Signal.Signal<Player, Player>

local services: { [string]: any } = {}

function ToolService:Init(all: { [string]: any })
	services = all
end

function ToolService:Start()
	Net.event("Tool", "Spray")
end

function ToolService:GiveLoadout(_player: Player) end

function ToolService:Refill(_player: Player, _litres: number?) end

function ToolService:ResetDoors(_locationId: string) end

function ToolService:_spray(_player: Player, _aim: Vector3) end

function ToolService:_selftest(): (boolean, string)
	return true, "stub"
end

return ToolService
```

`game/ServerScriptService/Services/MissionService.luau`:

```lua
--!strict
-- MissionService [owner: G3]. STUB from K0: harmless defaults until G3 replaces this file.
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   MissionService:StartRound(locationId: string?, seconds: number?)
--   MissionService:EndRound(reason: Types.EndReason)
--   MissionService:GetState(): Types.RoundState
-- Signals: RoundStarted(locationId: string), RoundEnded(payload: Types.ResultsPayload)
-- Remotes: Mission/Alarm (S->C all: missionId, locationName), Mission/Results (S->C all: ResultsPayload)
-- Writes: Workspace attrs RoundState, RoundEndsAt, MissionId; counter rounds_completed
-- Test hooks (DevHook only): _startRound(locationId, seconds), _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Types = require(Shared:WaitForChild("Types") :: ModuleScript)

local MissionService = {}
MissionService.Priority = 60
MissionService.RoundStarted = Signal.new() :: Signal.Signal<string>
MissionService.RoundEnded = Signal.new() :: Signal.Signal<Types.ResultsPayload>

local services: { [string]: any } = {}

function MissionService:Init(all: { [string]: any })
	services = all
end

function MissionService:Start()
	Net.event("Mission", "Alarm")
	Net.event("Mission", "Results")
	workspace:SetAttribute(Names.Attr.RoundState, "Lobby")
end

function MissionService:StartRound(_locationId: string?, _seconds: number?) end

function MissionService:EndRound(_reason: Types.EndReason) end

function MissionService:GetState(): Types.RoundState
	return (workspace:GetAttribute(Names.Attr.RoundState) :: any) or "Lobby"
end

function MissionService:_startRound(locationId: string, seconds: number)
	self:StartRound(locationId, seconds)
end

function MissionService:_selftest(): (boolean, string)
	return true, "stub"
end

return MissionService
```

`game/ServerScriptService/Services/RescueService.luau`:

```lua
--!strict
-- RescueService [owner: G3]. STUB from K0: harmless defaults until G3 replaces this file.
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   RescueService:Spawn(locationId: string, count: number)
--   RescueService:Clear()
--   RescueService:Deliver(player: Player): boolean       -- carrier reached a RescueDropoff volume
-- Signals: Rescued(player, rescueId: string, kind: string), Dropped(player, rescueId: string)
-- Remotes: Rescue/Drop (C->S, no args, 2/s)
-- Writes: Rescuable NPC Models (attrs RescueId, Kind, RescueState, CarriedBy); Player attr Carrying
-- Test hooks (DevHook only): _carry(player, rescueId), _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)

local RescueService = {}
RescueService.Priority = 50
RescueService.Rescued = Signal.new() :: Signal.Signal<Player, string, string>
RescueService.Dropped = Signal.new() :: Signal.Signal<Player, string>

local services: { [string]: any } = {}

function RescueService:Init(all: { [string]: any })
	services = all
end

function RescueService:Start()
	Net.event("Rescue", "Drop")
end

function RescueService:Spawn(_locationId: string, _count: number) end

function RescueService:Clear() end

function RescueService:Deliver(_player: Player): boolean
	return false
end

function RescueService:_carry(_player: Player, _rescueId: string): boolean
	return false
end

function RescueService:_selftest(): (boolean, string)
	return true, "stub"
end

return RescueService
```

`game/ServerScriptService/Services/SquadService.luau`:

```lua
--!strict
-- SquadService [owner: G3]. STUB from K0: harmless defaults until G3 replaces this file.
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   SquadService:GetHelmet(player: Player): number       -- 1..4
--   SquadService:Down(player: Player, cause: string, culprit: Player?)
--   SquadService:Revive(player: Player, by: Player)
--   SquadService:RespawnAll()                            -- everyone back to a StationSpawn pad
-- Signals: Downed(victim: Player, cause: string, culprit: Player?)
-- Writes: Player attrs Helmet, Downed
-- Test hooks (DevHook only): _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)

local SquadService = {}
SquadService.Priority = 10
SquadService.Downed = Signal.new() :: Signal.Signal<Player, string, Player?>

local services: { [string]: any } = {}

function SquadService:Init(all: { [string]: any })
	services = all
end

function SquadService:Start() end

function SquadService:GetHelmet(player: Player): number
	return (player:GetAttribute(Names.Attr.Helmet) :: number?) or 1
end

function SquadService:Down(_player: Player, _cause: string, _culprit: Player?) end

function SquadService:Revive(_player: Player, _by: Player) end

function SquadService:RespawnAll() end

function SquadService:_selftest(): (boolean, string)
	return true, "stub"
end

return SquadService
```

`game/ServerScriptService/Services/BlameService.luau`:

```lua
--!strict
-- BlameService [owner: G3]. STUB from K0: harmless defaults until G3 replaces this file.
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   BlameService:GetStats(player: Player): Types.PlayerStats
--   BlameService:BuildAwards(): { Types.Award }
--   BlameService:Reset()
-- Consumes (in Start, nil-guarded): FireService.Extinguished/.Spread, ToolService.WaterUsed/.DoorBroken/
--   .HoseHit, RescueService.Rescued, SquadService.Downed
-- Test hooks (DevHook only): _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Types") :: ModuleScript)

local BlameService = {}
BlameService.Priority = 70

local services: { [string]: any } = {}

function BlameService:Init(all: { [string]: any })
	services = all
end

function BlameService:Start() end

function BlameService:GetStats(player: Player): Types.PlayerStats
	return {
		userId = player.UserId,
		helmet = 1,
		name = player.Name,
		firesOut = 0,
		firesStarted = 0,
		water = 0,
		doors = 0,
		rescued = 0,
		pandas = 0,
		downedOthers = 0,
		timesDowned = 0,
		teammateSprayed = 0,
	}
end

function BlameService:BuildAwards(): { Types.Award }
	return {}
end

function BlameService:Reset() end

function BlameService:_selftest(): (boolean, string)
	return true, "stub"
end

return BlameService
```

- [ ] **Step 9: Stub the controllers**

`game/StarterPlayerScripts/Controllers/HudController.luau`:

```lua
--!strict
-- HudController [owner: G3]. STUB from K0: does nothing until G3 replaces this file.
-- Will render: round timer, water gauge, objectives, alarm banner, Shared/Notify toasts.
local HudController = {}
HudController.Priority = 100

function HudController:Init(_controllers: { [string]: any }) end

function HudController:Start() end

return HudController
```

`game/StarterPlayerScripts/Controllers/ResultsController.luau`:

```lua
--!strict
-- ResultsController [owner: G3]. STUB from K0: does nothing until G3 replaces this file.
-- Will render: the Blame results screen from Mission/Results (Types.ResultsPayload).
local ResultsController = {}
ResultsController.Priority = 100

function ResultsController:Init(_controllers: { [string]: any }) end

function ResultsController:Start() end

return ResultsController
```

`game/StarterPlayerScripts/Controllers/RescueController.luau`:

```lua
--!strict
-- RescueController [owner: G3]. STUB from K0: does nothing until G3 replaces this file.
-- Will render: carry hint; G key sends Rescue/Drop.
local RescueController = {}
RescueController.Priority = 100

function RescueController:Init(_controllers: { [string]: any }) end

function RescueController:Start() end

return RescueController
```

`game/StarterPlayerScripts/Controllers/FireFxController.luau`:

```lua
--!strict
-- FireFxController [owner: G1]. STUB from K0: does nothing until G1 replaces this file.
-- Will render: Burning tag + FireLevel attr -> local particles and lights (budgeted).
local FireFxController = {}
FireFxController.Priority = 100

function FireFxController:Init(_controllers: { [string]: any }) end

function FireFxController:Start() end

return FireFxController
```

`game/StarterPlayerScripts/Controllers/ToolController.luau`:

```lua
--!strict
-- ToolController [owner: G1]. STUB from K0: does nothing until G1 replaces this file.
-- Will render: hose aim + spray input (Tool/Spray), water stream visuals.
local ToolController = {}
ToolController.Priority = 100

function ToolController:Init(_controllers: { [string]: any }) end

function ToolController:Start() end

return ToolController
```

`game/StarterPlayerScripts/Controllers/VehicleController.luau`:

```lua
--!strict
-- VehicleController [owner: G2]. STUB from K0: does nothing until G2 replaces this file.
-- Will render: truck light bar during Alarm/Active.
local VehicleController = {}
VehicleController.Priority = 100

function VehicleController:Init(_controllers: { [string]: any }) end

function VehicleController:Start() end

return VehicleController
```

`game/StarterPlayerScripts/Controllers/AlarmController.luau`:

```lua
--!strict
-- AlarmController [owner: G2]. STUB from K0: does nothing until G2 replaces this file.
-- Will render: AlarmLamp spin + red screen flash on Mission/Alarm.
local AlarmController = {}
AlarmController.Priority = 100

function AlarmController:Init(_controllers: { [string]: any }) end

function AlarmController:Start() end

return AlarmController
```

- [ ] **Step 10: Per-system configs (each lane owns and extends its own)**

`game/ReplicatedStorage/Config/GameConfig.luau` (G3; other lanes read these keys, never redefine them):

```lua
--!strict
-- GameConfig [owner: G3]. Round flow numbers. Other lanes may read these, never redefine them.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	DefaultMission = "Town", -- location Id the auto round uses
	LocationName = "12 Maple St", -- shown on the alarm banner
	AutoStart = true, -- Lobby -> Alarm automatically when >= 1 player is in
	LobbySeconds = 10,
	AlarmSeconds = 6,
	RoundSeconds = 180,
	ResultsSeconds = 15,
	StartFires = 3, -- FireStart parts first, then random Flammable parts up to this many
	MaxPlayers = 4,
	AllOutGraceSeconds = 10, -- "allOut" (no fires, no trapped) can't end a round in its first N s
})
```

`game/ReplicatedStorage/Config/VehicleConfig.luau`:

```lua
--!strict
-- VehicleConfig [owner: G2]. Truck 67 numbers.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	TruckNumber = 67,
	HomeLocation = "Station", -- ResetTruck() parks here
})
```

`game/ReplicatedStorage/Config/FireConfig.luau`:

```lua
--!strict
-- FireConfig [owner: G1]. Every fire number lives here (docs/game/03-tech-architecture.md §3, §5).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	TickHz = 5, -- simulation steps per second
	TickBudgetMs = 2, -- step() slower than this bumps fire_tick_over_budget
	MaxBurning = 120, -- hard cap; spread pauses at the cap
	SpreadRadius = 8, -- studs; also the spatial-hash cell size
	SpreadHeatPerSecond = 14, -- heat a burning part adds to each idle neighbour
	GrowPerSecond = 6,
	IgniteAt = 40,
	ExtinguishAt = 10,
	DefaultFuel = 45, -- seconds a part burns before it is Charred
	CharredColor = Color3.fromRGB(35, 30, 28),
	HoseRange = 28,
	HoseConeCos = 0.94, -- ~20 degree cone
	CoolPerLitre = 9,
	-- client effects budget
	MaxClientFx = 40,
	MaxClientLights = 10,
	FxDistance = 180,
})
```

`game/ReplicatedStorage/Config/ToolConfig.luau`:

```lua
--!strict
-- ToolConfig [owner: G1]. Hose, tank, axe and door numbers.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	TankSize = 100, -- litres in the backpack tank
	LitresPerSpray = 1.2, -- per Tool/Spray event; the client sends 10/s, so 12 L/s
})
```

`game/ReplicatedStorage/Config/RescueConfig.luau`:

```lua
--!strict
-- RescueConfig [owner: G3]. Civilians and pets.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Count = 5, -- NPCs spawned per round (one per RescueSpawn marker, up to this many)
})
```

`game/ReplicatedStorage/Config/BlameConfig.luau`:

```lua
--!strict
-- BlameConfig [owner: G3]. Award thresholds.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	MaxAwardsPerPlayer = 2,
})
```

- [ ] **Step 11: Compile check, specs, Python tests**

```bash
python3 game/tools/sync.py check --root game
bash game/tests/run.sh
.venv/bin/python -m pytest -q
```
Expected: `OK: checked 33 files, 0 failed`. The count is 3 higher if the in-progress G2 files `AtmosphereService`, `AtmosphereConfig` and `TruckBuilder` are already on `main`. Then `3 passed, 0 failed`, and pytest all green.

- [ ] **Step 12: Live readiness check (03 §10 checklist) via Studio MCP**

`forge watch` should have printed `✓ … -> OK n files`. Then:
1. `mcp__Roblox_Studio__list_roblox_studios` → take the `id` of your local place (name contains `Forge`, no `placeId`).
2. `mcp__Roblox_Studio__start_stop_play {"is_start": true, "studio_id": "<id>"}`. Poll `mcp__Roblox_Studio__get_studio_state` until a `Server` datamodel is listed.
3. `mcp__Roblox_Studio__execute_luau {"datamodel_type": "Server", "studio_id": "<id>", "code": …}` with:

```lua
local HttpService = game:GetService("HttpService")
local t0 = os.clock()
repeat
	task.wait(0.25)
until (workspace:GetAttribute("ServerBooted") and workspace:GetAttribute("MapReady")) or os.clock() - t0 > 15
local selftest = {}
for _, m in game.ServerScriptService.Services:GetChildren() do
	local ok, pass, msg = game.ServerStorage.DevHook:Invoke(m.Name, "_selftest")
	selftest[m.Name] = if ok then { pass = pass, msg = msg } else { pass = false, msg = tostring(pass) }
end
local remotes = {}
for _, ns in game.ReplicatedStorage.Net:GetChildren() do
	for _, r in ns:GetChildren() do
		table.insert(remotes, ns.Name .. "/" .. r.Name)
	end
end
table.sort(remotes)
local report = HttpService:JSONDecode(game.ServerStorage.ForgeProbe:Invoke("report"))
return HttpService:JSONEncode({ selftest = selftest, remotes = remotes, errors = report.errors, warnings = report.warnings })
```

Expected:
- `selftest`: `pass = true` for BlameService, FireService, MissionService, RescueService, SquadService, ToolService and VehicleService (`msg = "stub"`), and for MapService (`msg = "0 locations"`).
- `remotes = ["Mission/Alarm","Mission/Results","Rescue/Drop","Shared/Notify","Tool/Spray"]`
- `errors = []`
- `warnings` contains exactly one item, `[MapService] no ServerScriptService.Lib.Map.Locations yet: the map is empty`, which goes away in G2.2.

4. `mcp__Roblox_Studio__execute_luau {"datamodel_type": "Client", …}` with `return #game.Players.LocalPlayer.PlayerScripts.Controllers:GetChildren()`. Expected: `7`.
5. `mcp__Roblox_Studio__get_console_output`. Expected: it contains `[Boot] server: 8 services` and no `[Boot] … failed` lines.
6. `mcp__Roblox_Studio__start_stop_play {"is_start": false, "studio_id": "<id>"}`.

- [ ] **Step 13: Sync the docs (03 §1/§10 + TEAM.md lane table)**

Run from the repo root, passing the third dev's name:

```bash
python3 - "<Dev C name>" <<'PYEOF'
"""K0: sync docs/game/03 §1/§10 and docs/TEAM.md with the kickoff decisions. Run once from the repo root."""
import sys
from pathlib import Path

dev_c = sys.argv[1]  # the third dev's name, for the G3 row

doc = Path("docs/game/03-tech-architecture.md")
s = doc.read_text()

def put(old: str, new: str) -> None:
    global s
    assert s.count(old) == 1, f"anchor not found exactly once: {old[:60]!r}"
    s = s.replace(old, new)

put("      Types.luau                                    cross-system types (RoundState, Award, ...)\n",
    "      Types.luau                                    cross-system types (RoundState, Award, ...)\n"
    "      Palette.luau                                  colour tokens from docs/game/02 §1\n")
put("| `Truck` | truck Model | VehicleService | MissionService, VehicleController |\n",
    "| `Truck` | truck Model | VehicleService | MissionService, VehicleController |\n"
    "| `FireStart` | Flammable part that lights at round start | MapService builders | MissionService |\n"
    "| `RescueSpawn` | invisible 2x2x2 marker, attrs `Kind`, `BuildingId` (NPC feet at marker Y - 1) | MapService builders | RescueService |\n"
    "| `TruckSpot` | invisible marker, attr `LocationId`; LookVector = truck forward | MapService builders | VehicleService |\n"
    "| `AlarmLamp` | Neon lamp part at the station | StationBuilder | AlarmController |\n")
put("| `ServerBooted`, `MapReady` | Workspace | boolean | Main.server, MapService |\n",
    "| `ServerBooted`, `MapReady` | Workspace | boolean | Main.server, MapService |\n"
    "| `Slot` | StationSpawn pad | number 1-4 | MapService builders |\n")
put("VehicleService:ResetTruck()                            -- back to the station bay\n",
    "VehicleService:ResetTruck()                            -- back to the station bay\n"
    "VehicleService:ParkAt(locationId: string): boolean     -- K0: truck onto that location's TruckSpot (v1 travel = teleport)\n")
put("ToolService.WaterUsed: Signal<Player, number>\n",
    "ToolService.WaterUsed: Signal<Player, number>\n"
    "ToolService.HoseHit: Signal<Player, Player>            -- K0: (sprayer, victim) friendly fire, P1.5\n")
put("Axe swings use server-side `Tool.Activated`.",
    "Axe swings use server-side `Tool.Activated`. The **builders create** the one ProximityPrompt on each\n"
    "Door/Hydrant/TruckRefill part (MapKit, TruckBuilder); the **system lane owns its behaviour** (ToolService).\n"
    "`Shared/Notify` is declared by `Main.server.luau` before any `Start` (it has no single owner).")
start = s.index("export type RoundState")
end = s.index("return {}", start)
s = s[:start] + Path("game/ReplicatedStorage/Shared/Types.luau").read_text().split("-- .teammateSprayed, Award.blame, ResultsPayload.burningAtEnd/.stars/.reason.\n", 1)[1].split("return {}")[0] + s[end:]
put("- [ ] Each lane has written its name in the §1 lane table.",
    "- [ ] Each lane has written its name in the lane table in `docs/TEAM.md`.")
doc.write_text(s)

team = Path("docs/TEAM.md")
t = team.read_text()
a = t.index("| Lane | Owner | Owns | Goal for the demo |")
b = t.index("Shared files changed by anyone")
t = t[:a] + """| Lane | Owner | Owns | Goal for the demo |
|---|---|---|---|
| **K0 Kickoff** (frozen `[K]`) | Arvin | `game/ReplicatedStorage/Shared/*`, `Main.server`/`Main.client`, `game/tests/` runner, CI | Contracts in `docs/game/03` §10; every API stubbed |
| **G1 Fire & tools** | Anson | FireService, ToolService, `Lib/Fire/`, FireConfig, ToolConfig, FireFxController, ToolController | Fire spreads; hose + tank + refill; axe breaks locked doors |
| **G2 World & truck** | Arvin | MapService, VehicleService, AtmosphereService, `Lib/Map/**`, Map/Vehicle/AtmosphereConfig, Vehicle/AlarmController | Station 67 + a 4-house town from code; truck 67 at the scene |
| **G3 Loop & people** | """ + dev_c + """ | Mission/Rescue/Squad/BlameService, `Lib/Rescue/`, `Lib/Squad/`, `Lib/Blame/`, Game/Rescue/BlameConfig, Hud/Results/RescueController, `ClientLib/UiKit` | 3-minute round, carry civilians and pets to the truck, Blame screen |
| **GF Forge + Mubit demo** | Anson | `forge/**`, `tests/test_*.py`, `docs/ARCHITECTURE.md`, `runs/flame-and-blame/`, new Forge-made files in `game/` | Forge builds a v1 module; a human correction becomes a recorded fixer call; Mubit console |

File-level ownership is `docs/game/03-tech-architecture.md` §1. Integration lead (shared place, recordings): Arvin.
The weekend plan: `docs/superpowers/plans/2026-10-23-flame-and-blame-v1.md`.

""" + t[b:]
team.write_text(t)
print("docs synced")
PYEOF
git diff --stat docs/
```
Expected: `docs synced`. Then `docs/game/03-tech-architecture.md` (about 20 lines) and `docs/TEAM.md` (the lane table) show as changed.

- [ ] **Step 14: Commit, PR, merge, announce**

```bash
git add .github/workflows/ci.yml game/tests game/ReplicatedStorage/Shared game/ReplicatedStorage/Config \
  game/ServerScriptService/Main.server.luau game/ServerScriptService/Services game/StarterPlayerScripts/Controllers \
  docs/game/03-tech-architecture.md docs/TEAM.md
git commit -m "game(k0): finish kickoff: stubs for every §10 API, Palette, Types/Names additions, spec runner + CI"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch      # once CI is green (new step "Luau unit specs" must pass)
```
Paste into the team chat: "K0 merged. Pull main; your lane's stub files are yours to replace. `bash game/tests/run.sh` runs the Luau specs."

---

## Lane G1: Fire & tools (Dev B, Anson)

**Owns (docs/game/03 §1):** `ServerScriptService/Services/FireService.luau`, `ServerScriptService/Services/ToolService.luau`,
`ServerScriptService/Lib/Fire/FireSim.luau` (pure), `ServerScriptService/Lib/Tools/DoorBreaker.luau` (new, lane-internal),
`ReplicatedStorage/Config/FireConfig.luau`, `ReplicatedStorage/Config/ToolConfig.luau`,
`StarterPlayerScripts/Controllers/FireFxController.luau`, `StarterPlayerScripts/Controllers/ToolController.luau`,
`tests/fire_sim.spec.luau` (all under `game/`).

**Timeline:** G1.1 and G1.2 Fri 22:00 to Sat 00:30, G1.3 to G1.5 Sat 07:00 to 10:00 (**P0 by Sat 10:00**),
G1.6 by **P1 Sat 14:00**, G1.7 by **P1.5 Sat 18:00**. Dev B also runs lane GF (Forge/Mubit demo). GF.1 and GF.2 happen
Fri 20:30 to 22:00, while Task 0 is in review, so they don't collide with G1.

**Before G2 lands** there are no Flammable parts in the map. Every live check below builds its own test Model inside
`execute_luau`, indexes it with `FireService:_index`, and destroys it at the end, so G1 never waits on G2.
`FireConfig.luau` is complete from Task 0 and does not change in this lane. The numbers used below come from it: TickHz 5,
SpreadHeatPerSecond 14, IgniteAt 40, GrowPerSecond 6, CoolPerLitre 9, HoseRange 28, HoseConeCos 0.94. An 8-stud
neighbour of a fresh fire (heat 40) gains 14 × 0.2 = 2.8 heat per tick, so it ignites on tick 15 (3.0 s). A chain of
cubes 8 studs apart therefore lights one more cube every 3.0 s.

**Live-check boilerplate (every G1 task).** Your local place must be open (`forge place --open`), and
`forge watch --studio Forge` must have printed `✓` for your last save.
1. Call `mcp__Roblox_Studio__list_roblox_studios`. Pick the id whose name contains `Forge`, never one that shows a
   `placeId` (that is the shared place).
2. Call `mcp__Roblox_Studio__start_stop_play {"is_start": true, "studio_id": "<id>"}`. Then poll
   `mcp__Roblox_Studio__get_studio_state {"studio_id": "<id>"}` until it lists the `Server` datamodel.
3. Run the task's code with `mcp__Roblox_Studio__execute_luau {"datamodel_type": "Server" | "Client", "studio_id": "<id>", "code": ...}`.
4. Always finish with `mcp__Roblox_Studio__start_stop_play {"is_start": false, "studio_id": "<id>"}`, even after a failure.

---

### Task G1.1: FireSim, the pure fire maths, plus its spec (Dev B, G1, 1.0 h, P0)

**Files:**
- Create: `game/ServerScriptService/Lib/Fire/FireSim.luau`
- Test: `game/tests/fire_sim.spec.luau`

**Interfaces:**
- Consumes: `game/tests/Spec.luau` (Task 0), FireConfig key names (Task 0)
- Produces (used by FireService in G1.2 and by ToolService in G1.7):
  `FireSim.IDLE = 0`, `FireSim.BURNING = 1`, `FireSim.CHARRED = 2`,
  `FireSim.buildNeighbors(positions: { Pos }, radius: number): { { number } }`,
  `FireSim.step(burning: { [Cell]: true }, dt: number, p: Params): ({ Edge }, { Cell })`,
  `FireSim.cool(cell: Cell, litres: number, p: Params): boolean`,
  `FireSim.levelFor(state: number, heat: number): number`,
  `FireSim.inCone(dx, dy, dz, ax, ay, az, range, cosMin): boolean`,
  types `Pos = {x,y,z}`, `Cell = {heat, fuel, state, neighbors: {Cell}}`, `Edge = {from: Cell, to: Cell}`.

- [ ] **Step 1: Branch and write the failing spec**

```bash
git switch main && git pull --rebase && git switch -c g1/fire-sim
```

Create `game/tests/fire_sim.spec.luau`:

```lua
--!strict
-- FireSim: neighbour hashing, spread timing, charring, cooling, levels, spray cone.
-- Numbers mirror ReplicatedStorage/Config/FireConfig.luau so the timings here are the in-game ones.
local Spec = require("./Spec")
local FireSim = require("../ServerScriptService/Lib/Fire/FireSim")

local P = {
	SpreadRadius = 8,
	SpreadHeatPerSecond = 14,
	GrowPerSecond = 6,
	IgniteAt = 40,
	ExtinguishAt = 10,
	CoolPerLitre = 9,
}

local function cell(state: number, heat: number, fuel: number): FireSim.Cell
	return { heat = heat, fuel = fuel, state = state, neighbors = {} }
end

local function sorted(list: { number }): string
	local copy = table.clone(list)
	table.sort(copy)
	return table.concat(copy, ",")
end

Spec.test("buildNeighbors links parts within the radius only", function()
	local n = FireSim.buildNeighbors({
		{ x = 0, y = 0, z = 0 },
		{ x = 8, y = 0, z = 0 },
		{ x = 20, y = 0, z = 0 },
	}, 8)
	Spec.eq(sorted(n[1]), "2", "neighbours of 1")
	Spec.eq(sorted(n[2]), "1", "neighbours of 2")
	Spec.eq(#n[3], 0, "neighbours of 3")
end)

Spec.test("buildNeighbors works across bucket edges and negative coordinates", function()
	local n = FireSim.buildNeighbors({
		{ x = -1, y = 0, z = 0 },
		{ x = 1, y = 0, z = 0 },
		{ x = -1, y = 7, z = 0 },
		{ x = 0, y = 0, z = -30 },
	}, 8)
	Spec.eq(sorted(n[1]), "2,3", "neighbours of 1")
	Spec.eq(sorted(n[2]), "1,3", "neighbours of 2")
	Spec.eq(#n[4], 0, "far cell")
end)

Spec.test("levelFor buckets heat into 1..3 and 0 when not burning", function()
	Spec.eq(FireSim.levelFor(FireSim.BURNING, 40), 1)
	Spec.eq(FireSim.levelFor(FireSim.BURNING, 51), 2)
	Spec.eq(FireSim.levelFor(FireSim.BURNING, 81), 3)
	Spec.eq(FireSim.levelFor(FireSim.IDLE, 90), 0)
	Spec.eq(FireSim.levelFor(FireSim.CHARRED, 90), 0)
end)

Spec.test("a fresh fire ignites an 8-stud neighbour after 15 ticks at 5 Hz (3.0 s)", function()
	local a = cell(FireSim.BURNING, 40, 45)
	local b = cell(FireSim.IDLE, 0, 45)
	a.neighbors = { b }
	b.neighbors = { a }
	local burning = { [a] = true }
	for tick = 1, 14 do
		local lit = FireSim.step(burning, 0.2, P)
		Spec.eq(#lit, 0, `tick {tick} ignitions`)
	end
	local lit = FireSim.step(burning, 0.2, P)
	Spec.eq(#lit, 1, "tick 15 ignitions")
	Spec.truthy(lit[1].from == a and lit[1].to == b, "edge is a -> b")
	Spec.eq(b.state, FireSim.IDLE, "step never changes state itself")
end)

Spec.test("burning cells grow toward 100 heat", function()
	local a = cell(FireSim.BURNING, 40, 45)
	FireSim.step({ [a] = true }, 1, P)
	Spec.near(a.heat, 46)
	for _ = 1, 20 do
		FireSim.step({ [a] = true }, 1, P)
	end
	Spec.eq(a.heat, 100)
end)

Spec.test("a cell out of fuel is reported charred and does not spread", function()
	local a = cell(FireSim.BURNING, 90, 0.1)
	local b = cell(FireSim.IDLE, 39, 45)
	a.neighbors = { b }
	local lit, charred = FireSim.step({ [a] = true }, 0.2, P)
	Spec.eq(#lit, 0, "ignitions")
	Spec.eq(#charred, 1, "charred")
	Spec.truthy(charred[1] == a, "a charred")
	Spec.eq(b.heat, 39, "b got no heat")
end)

Spec.test("two burning neighbours report an idle cell once", function()
	local a = cell(FireSim.BURNING, 40, 45)
	local c = cell(FireSim.BURNING, 40, 45)
	local b = cell(FireSim.IDLE, 39, 45)
	a.neighbors = { b }
	c.neighbors = { b }
	local lit = FireSim.step({ [a] = true, [c] = true }, 0.2, P)
	Spec.eq(#lit, 1, "deduped ignitions")
end)

Spec.test("cool lowers heat by CoolPerLitre and says when the fire is out", function()
	local a = cell(FireSim.BURNING, 40, 45)
	Spec.eq(FireSim.cool(a, 3, P), false, "27 off -> 13, still burning")
	Spec.near(a.heat, 13)
	Spec.eq(FireSim.cool(a, 1, P), true, "9 off -> 4, out")
end)

Spec.test("inCone: in front within range, not behind, not too far, not off-axis", function()
	Spec.eq(FireSim.inCone(10, 0, 0, 1, 0, 0, 28, 0.94), true, "ahead")
	Spec.eq(FireSim.inCone(-10, 0, 0, 1, 0, 0, 28, 0.94), false, "behind")
	Spec.eq(FireSim.inCone(40, 0, 0, 1, 0, 0, 28, 0.94), false, "out of range")
	Spec.eq(FireSim.inCone(10, 10, 0, 1, 0, 0, 28, 0.94), false, "45 degrees off")
	Spec.eq(FireSim.inCone(0, 0, 0, 1, 0, 0, 28, 0.94), true, "at the nozzle")
end)

return Spec.finish()
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bash game/tests/run.sh`
Expected: FAIL. The output includes `error requiring module "../ServerScriptService/Lib/Fire/FireSim": could not resolve child component "Fire"`, and the exit code is 1.

- [ ] **Step 3: Write the module**

Create `game/ServerScriptService/Lib/Fire/FireSim.luau`:

```lua
--!strict
-- FireSim [owner: G1]. Pure fire maths for FireService: no Roblox APIs, so game/tests/fire_sim.spec.luau
-- runs it under the plain `luau` CLI. FireService owns the Roblox side (tags, attributes, signals).
--
--   FireSim.buildNeighbors(positions: { Pos }, radius: number): { { number } }   -- spatial hash, O(n)
--   FireSim.step(burning: { [Cell]: true }, dt: number, p: Params): ({ Edge }, { Cell })
--       burns fuel, heats idle neighbours, grows heat. Returns (ignitions, charred). It never changes
--       `state` and never adds to `burning`: the caller applies both after the loop.
--   FireSim.cool(cell: Cell, litres: number, p: Params): boolean   -- true = the fire is out now
--   FireSim.levelFor(state: number, heat: number): number          -- 0 (not burning) or 1..3
--   FireSim.inCone(dx, dy, dz, ax, ay, az, range, cosMin): boolean -- is offset d inside the spray cone
--
-- A Cell may carry extra fields (FireService adds part, level, location, cause); FireSim only touches
-- heat, fuel, state and neighbors.

local FireSim = {}

FireSim.IDLE = 0
FireSim.BURNING = 1
FireSim.CHARRED = 2

export type Pos = { x: number, y: number, z: number }
export type Cell = { heat: number, fuel: number, state: number, neighbors: { Cell } }
export type Edge = { from: Cell, to: Cell }
export type Params = {
	SpreadRadius: number,
	SpreadHeatPerSecond: number,
	GrowPerSecond: number,
	IgniteAt: number,
	ExtinguishAt: number,
	CoolPerLitre: number,
}

local function bucket(v: number, size: number): number
	return math.floor(v / size)
end

function FireSim.buildNeighbors(positions: { Pos }, radius: number): { { number } }
	local grid: { [string]: { number } } = {}
	for i, p in positions do
		local key = `{bucket(p.x, radius)},{bucket(p.y, radius)},{bucket(p.z, radius)}`
		local list = grid[key]
		if not list then
			list = {}
			grid[key] = list
		end
		table.insert(list, i)
	end
	local r2 = radius * radius
	local out: { { number } } = {}
	for i, p in positions do
		local mine: { number } = {}
		local bx, by, bz = bucket(p.x, radius), bucket(p.y, radius), bucket(p.z, radius)
		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					for _, j in grid[`{bx + dx},{by + dy},{bz + dz}`] or {} do
						if j ~= i then
							local q = positions[j]
							local ex, ey, ez = q.x - p.x, q.y - p.y, q.z - p.z
							if ex * ex + ey * ey + ez * ez <= r2 then
								table.insert(mine, j)
							end
						end
					end
				end
			end
		end
		out[i] = mine
	end
	return out
end

function FireSim.levelFor(state: number, heat: number): number
	if state ~= FireSim.BURNING then
		return 0
	elseif heat > 80 then
		return 3
	elseif heat > 50 then
		return 2
	end
	return 1
end

function FireSim.step(burning: { [Cell]: true }, dt: number, p: Params): ({ Edge }, { Cell })
	local lit: { Edge } = {}
	local charred: { Cell } = {}
	local seen: { [Cell]: true } = {}
	for c in burning do
		c.fuel -= dt
		if c.fuel <= 0 then
			table.insert(charred, c)
			continue
		end
		for _, n in c.neighbors do
			if n.state == FireSim.IDLE then
				n.heat += p.SpreadHeatPerSecond * dt
				if n.heat >= p.IgniteAt and not seen[n] then
					seen[n] = true
					table.insert(lit, { from = c, to = n })
				end
			end
		end
		c.heat = math.min(100, c.heat + p.GrowPerSecond * dt)
	end
	return lit, charred
end

function FireSim.cool(cell: Cell, litres: number, p: Params): boolean
	cell.heat -= p.CoolPerLitre * litres
	return cell.heat <= p.ExtinguishAt
end

function FireSim.inCone(dx: number, dy: number, dz: number, ax: number, ay: number, az: number, range: number, cosMin: number): boolean
	local m = math.sqrt(dx * dx + dy * dy + dz * dz)
	if m > range then
		return false
	end
	if m < 1e-3 then
		return true
	end
	local am = math.sqrt(ax * ax + ay * ay + az * az)
	if am < 1e-6 then
		return false
	end
	return (dx * ax + dy * ay + dz * az) / (m * am) >= cosMin
end

return FireSim
```

- [ ] **Step 4: Run the specs and the compile check**

Run: `bash game/tests/run.sh`
Expected: `game/tests/fire_sim.spec.luau` prints `9 passed, 0 failed`, `config.spec.luau` still prints `3 passed, 0 failed`, and the exit code is 0.
Run: `python3 game/tools/sync.py check --root game`
Expected: `OK: checked <N> files, 0 failed`.

- [ ] **Step 5: Commit and open the PR** (this task has no live check: FireSim touches no Roblox APIs)

```bash
git add game/ServerScriptService/Lib/Fire/FireSim.luau game/tests/fire_sim.spec.luau
git commit -m "game(fire): FireSim pure step, neighbour hash, cone + spec"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch   # once CI (luau-compile + specs + pytest) is green
```

---

### Task G1.2: FireService on top of FireSim (Dev B, G1, 1.5 h, P0)

**Files:**
- Modify (replace the Task 0 stub): `game/ServerScriptService/Services/FireService.luau`

**Interfaces:**
- Consumes: `FireSim.*` (G1.1); `services.MapService.LocationBuilt: Signal<Model, string>` and
  `MapService:GetLocations()` (Task 0, nil-guarded); `Names.Tag.Flammable/Burning`,
  `Names.Attr.Fuel/FireLevel/Charred`; `FireConfig.*`; `ForgeTelemetry.count`.
- Produces (§10, unchanged names): `FireService:Ignite(part: BasePart, cause: Player?): boolean`,
  `FireService:ApplyWater(player: Player?, origin: Vector3, aim: Vector3, litres: number): number`,
  `FireService:IsBurning(part: BasePart): boolean`, `FireService:CountBurning(locationId: string?): number`,
  `FireService:ExtinguishAll()`, signals `Ignited(part, cause)`, `Spread(from, to)`, `Extinguished(part, by)`,
  `Charred(part)`; tag `Burning`, attrs `FireLevel` and `Charred`; counters `fires_spread`, `fires_extinguished`,
  `parts_charred`, `fire_tick_over_budget`. Test hooks: `_index(model, locationId)`, `_forget(locationId)`,
  `_ignite(pos): BasePart?`, `_water(origin, aim, litres): number`, `_selftest()`.
  (`_water` exists because passing `nil` as the first argument through the DevHook BindableFunction is unreliable.)

- [ ] **Step 1: Branch and write the live check (it fails against the stub)**

```bash
git switch main && git pull --rebase && git switch -c g1/fire-service
```

This is the check code for Step 2 and Step 5 (Server datamodel). It builds a row of five 4-stud cubes 8 studs apart, plus
one lone cube with `Fuel = 2` far from the row:

```lua
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local DevHook = game.ServerStorage.DevHook
local t0 = os.clock()
repeat task.wait(0.25) until workspace:GetAttribute("ServerBooted") or os.clock() - t0 > 15
local m = Instance.new("Model")
m.Name = "G1FireTest"
local function cube(name, pos, fuel)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = Vector3.new(4, 4, 4)
	p.Position = pos
	if fuel then p:SetAttribute("Fuel", fuel) end
	CollectionService:AddTag(p, "Flammable")
	p.Parent = m
	return p
end
for i = 0, 4 do cube("Cell" .. i, Vector3.new(i * 8, 40, 60), nil) end
local lone = cube("Lone", Vector3.new(0, 40, 120), 2)
m.Parent = workspace
DevHook:Invoke("FireService", "_index", m, "G1FireTest")
local _, lit = DevHook:Invoke("FireService", "_ignite", Vector3.new(0, 40, 60))
DevHook:Invoke("FireService", "_ignite", Vector3.new(0, 40, 120))
task.wait(7)
local _, burning7 = DevHook:Invoke("FireService", "CountBurning", "G1FireTest")
local level0 = m.Cell0:GetAttribute("FireLevel")
local _, hit = DevHook:Invoke("FireService", "_water", Vector3.new(-6, 40, 60), Vector3.new(1, 0, 0), 1000)
local _, burningAfter = DevHook:Invoke("FireService", "CountBurning", "G1FireTest")
local _, selfOk, selfMsg = DevHook:Invoke("FireService", "_selftest")
local out = {
	lit = lit and lit.Name, burning7 = burning7, level0 = level0, hit = hit, burningAfter = burningAfter,
	loneCharred = lone:GetAttribute("Charred"), selftest = { selfOk, selfMsg },
}
DevHook:Invoke("FireService", "_forget", "G1FireTest")
m:Destroy()
local r = HttpService:JSONDecode(game.ServerStorage.ForgeProbe:Invoke("report"))
out.counters = r.counters
out.errors = r.errors
return HttpService:JSONEncode(out)
```

- [ ] **Step 2: Run the check against the Task 0 stub and confirm it fails**

Use the live-check boilerplate (Server datamodel).
Expected (FAIL): `"lit":null`, `"burning7":0`, and the counters have no `fires_spread`. The stub's `_selftest` returns `[true,"stub"]`.

- [ ] **Step 3: Replace the stub with the full service**

`game/ServerScriptService/Services/FireService.luau`:

```lua
--!strict
-- FireService [owner: G1]. Fire simulation on parts tagged "Flammable" (built by MapService builders).
-- The maths lives in Lib/Fire/FireSim (pure, unit-tested); this file owns the Roblox side.
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   FireService:Ignite(part: BasePart, cause: Player?): boolean
--   FireService:ApplyWater(player: Player?, origin: Vector3, aim: Vector3, litres: number): number
--   FireService:IsBurning(part: BasePart): boolean
--   FireService:CountBurning(locationId: string?): number
--   FireService:ExtinguishAll()
-- Signals: Ignited(part, cause: Player?), Spread(from, to), Extinguished(part, by: Player?), Charred(part)
-- Writes: tag Burning; attrs FireLevel (1..3, nil when out), Charred (true) + Color on burnt-out parts
-- Counters: fires_spread, fires_extinguished, parts_charred, fire_tick_over_budget
-- Test hooks (DevHook only): _index(model, locationId), _forget(locationId), _ignite(pos),
--   _water(origin, aim, litres), _selftest()

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local FireConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("FireConfig") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local FireSim = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Fire"):WaitForChild("FireSim") :: ModuleScript)

type Cell = {
	part: BasePart,
	heat: number, -- 0..100, server only, never replicated
	fuel: number, -- seconds of burning left
	state: number, -- FireSim.IDLE / BURNING / CHARRED
	level: number, -- last replicated FireLevel (0 = none)
	neighbors: { Cell },
	location: string,
	cause: Player?, -- who lit it (for Blame)
}

local FireService = {}
FireService.Priority = 50
FireService.Ignited = Signal.new() :: Signal.Signal<BasePart, Player?>
FireService.Spread = Signal.new() :: Signal.Signal<BasePart, BasePart>
FireService.Extinguished = Signal.new() :: Signal.Signal<BasePart, Player?>
FireService.Charred = Signal.new() :: Signal.Signal<BasePart>

local services: { [string]: any } = {}
local cells: { [BasePart]: Cell } = {}
local burning: { [Cell]: true } = {}
local burningCount = 0

local function setLevel(c: Cell)
	local level = FireSim.levelFor(c.state, c.heat)
	if level == c.level then
		return -- replicate transitions only
	end
	c.level = level
	c.part:SetAttribute(Names.Attr.FireLevel, if level > 0 then level else nil)
end

local function startBurning(c: Cell, cause: Player?): boolean
	if c.state ~= FireSim.IDLE or burningCount >= FireConfig.MaxBurning then
		return false
	end
	c.state, c.cause = FireSim.BURNING, cause
	c.heat = math.max(c.heat, FireConfig.IgniteAt)
	burning[c] = true
	burningCount += 1
	CollectionService:AddTag(c.part, Names.Tag.Burning)
	setLevel(c)
	return true
end

local function stopBurning(c: Cell, charred: boolean)
	if c.state ~= FireSim.BURNING then
		return
	end
	burning[c] = nil
	burningCount -= 1
	if charred then
		-- set Charred before removing the tag: clients use it to skip the "put out" steam puff
		c.part:SetAttribute(Names.Attr.Charred, true)
		c.part.Color = FireConfig.CharredColor
	end
	CollectionService:RemoveTag(c.part, Names.Tag.Burning)
	c.state = if charred then FireSim.CHARRED else FireSim.IDLE
	setLevel(c)
	if charred then
		Telemetry.count("parts_charred")
		FireService.Charred:Fire(c.part)
	end
end

local function step(dt: number)
	local t0 = os.clock()
	local lit, charred = FireSim.step(burning :: any, dt, FireConfig :: any)
	for _, c in charred :: { any } do
		stopBurning(c :: Cell, true)
	end
	for c in burning do
		setLevel(c)
	end
	for _, e in lit :: { any } do
		local from, to = e.from :: Cell, e.to :: Cell
		if to.state == FireSim.IDLE and startBurning(to, from.cause) then
			FireService.Spread:Fire(from.part, to.part)
			Telemetry.count("fires_spread")
		end
	end
	if (os.clock() - t0) * 1000 > FireConfig.TickBudgetMs then
		Telemetry.count("fire_tick_over_budget")
	end
end

-- Drop every cell of a location (its parts are being destroyed or rebuilt).
local function forget(locationId: string)
	for part, c in cells do
		if c.location == locationId then
			if burning[c] then
				burning[c] = nil
				burningCount -= 1
			end
			cells[part] = nil
		end
	end
end

-- Index every Flammable BasePart under `model` as one location. Re-indexing replaces the old cells.
local function index(model: Instance, locationId: string)
	forget(locationId)
	local list: { Cell } = {}
	local positions: { FireSim.Pos } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and CollectionService:HasTag(d, Names.Tag.Flammable) then
			local c: Cell = {
				part = d,
				heat = 0,
				fuel = (d:GetAttribute(Names.Attr.Fuel) :: number?) or FireConfig.DefaultFuel,
				state = FireSim.IDLE,
				level = 0,
				neighbors = {},
				location = locationId,
				cause = nil,
			}
			cells[d] = c
			table.insert(list, c)
			table.insert(positions, { x = d.Position.X, y = d.Position.Y, z = d.Position.Z })
		end
	end
	local links = FireSim.buildNeighbors(positions, FireConfig.SpreadRadius)
	for i, c in list do
		for _, j in links[i] do
			table.insert(c.neighbors, list[j])
		end
	end
end

function FireService:Init(all: { [string]: any })
	services = all
end

function FireService:Start()
	local MapService = services.MapService
	if MapService then
		MapService.LocationBuilt:Connect(function(model: Model, locationId: string)
			index(model, locationId)
		end)
		for id, model in MapService:GetLocations() do
			index(model, id)
		end
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		local period = 1 / FireConfig.TickHz
		if acc >= period then
			acc -= period
			if acc > period then
				acc = 0 -- after a hitch, skip the backlog instead of burning it all in one frame
			end
			step(period)
		end
	end)
end

function FireService:Ignite(part: BasePart, cause: Player?): boolean
	local c = cells[part]
	if not c or c.state ~= FireSim.IDLE then
		return false
	end
	if not startBurning(c, cause) then
		return false
	end
	FireService.Ignited:Fire(part, cause)
	return true
end

function FireService:ApplyWater(player: Player?, origin: Vector3, aim: Vector3, litres: number): number
	local hit = 0
	for c in burning do
		local d = c.part.Position - origin
		if FireSim.inCone(d.X, d.Y, d.Z, aim.X, aim.Y, aim.Z, FireConfig.HoseRange, FireConfig.HoseConeCos) then
			hit += 1
			if FireSim.cool(c :: any, litres, FireConfig :: any) then
				stopBurning(c, false)
				FireService.Extinguished:Fire(c.part, player)
				Telemetry.count("fires_extinguished")
			else
				setLevel(c)
			end
		end
	end
	return hit
end

function FireService:IsBurning(part: BasePart): boolean
	local c = cells[part]
	return c ~= nil and c.state == FireSim.BURNING
end

function FireService:CountBurning(locationId: string?): number
	if not locationId then
		return burningCount
	end
	local n = 0
	for c in burning do
		if c.location == locationId then
			n += 1
		end
	end
	return n
end

function FireService:ExtinguishAll()
	for c in burning do
		stopBurning(c, false)
	end
end

-- test hooks -------------------------------------------------------------------------------
function FireService:_index(model: Instance, locationId: string)
	index(model, locationId)
end

function FireService:_forget(locationId: string)
	for c in burning do
		if c.location == locationId then
			stopBurning(c, false)
		end
	end
	forget(locationId)
end

function FireService:_ignite(pos: Vector3): BasePart?
	local best, bestD = nil :: Cell?, math.huge
	for _, c in cells do
		local d = (c.part.Position - pos).Magnitude
		if c.state == FireSim.IDLE and d < bestD and c.part:IsDescendantOf(workspace) then
			best, bestD = c, d
		end
	end
	if best and self:Ignite(best.part, nil) then
		return best.part
	end
	return nil
end

function FireService:_water(origin: Vector3, aim: Vector3, litres: number): number
	return self:ApplyWater(nil, origin, aim.Unit, litres)
end

function FireService:_selftest(): (boolean, string)
	-- Self-contained: builds two cells 8 studs apart far above the map, then removes them.
	local model = Instance.new("Model")
	model.Name = "FireSelftest"
	for i = 0, 1 do
		local p = Instance.new("Part")
		p.Name = `Cell{i}`
		p.Anchored = true
		p.CanCollide = false
		p.Size = Vector3.new(4, 4, 4)
		p.Position = Vector3.new(i * 8, 900, 0)
		CollectionService:AddTag(p, Names.Tag.Flammable)
		p.Parent = model
	end
	model.Parent = workspace
	index(model, "_selftest")
	local part = model:FindFirstChild("Cell0") :: BasePart
	local result, message = true, "ok"
	if not self:Ignite(part, nil) then
		result, message = false, "Ignite returned false"
	elseif not CollectionService:HasTag(part, Names.Tag.Burning) then
		result, message = false, "Ignite did not tag Burning"
	else
		self:ApplyWater(nil, part.Position - Vector3.new(0, 0, 5), Vector3.new(0, 0, 1), 1000)
		if self:IsBurning(part) then
			result, message = false, "ApplyWater did not extinguish"
		end
	end
	self:_forget("_selftest")
	model:Destroy()
	return result, message
end

return FireService
```

- [ ] **Step 4: Compile check and specs**

Run: `python3 game/tools/sync.py check --root game` → `OK: checked <N> files, 0 failed`
Run: `bash game/tests/run.sh` → exit code 0

- [ ] **Step 5: Live check (it passes now)**

Run the Step 1 code again.
Expected JSON:
- `"lit":"Cell0"`.
- `"burning7":3`, because Cell0 lit at 0 s, Cell1 at 3.0 s and Cell2 at 6.0 s. The 5 Hz tick phase can shift this by
  one, so 2 is acceptable and 4 is a bug.
- `"level0":3`, because Cell0's heat after 7 s is 40 + 6 × 7 = 82 (above 80).
- `"hit"` equals `burning7`, and `"burningAfter":0`.
- `"loneCharred":true`, because Fuel 2 burns out after 2 s.
- `"selftest":[true,"ok"]`.
- Counters: `fires_spread` = `burning7 - 1` (2), `fires_extinguished` = `burning7 + 1` (4: the row plus the selftest's
  own cube), `parts_charred` = 1, and `fire_tick_over_budget` is absent or 0.
- `"errors":[]`.

Stop the playtest.

**Integration point (G2 TownBuilder merged):** run `return game.ServerStorage.DevHook:Invoke("FireService", "CountBurning", nil)`
after `DevHook:Invoke("FireService", "_ignite", Vector3.new(400, 4, 0))` and a 6 s wait. Expect `true, n` with n ≥ 2: the
Town's walls are now indexed through `MapService.LocationBuilt`.
**Integration point (G3 MissionService merged):** an auto round ignites the Town's `FireStart` parts. Within 60 s of
`RoundState == "Active"`, the probe must show `fires_spread > 0`.

- [ ] **Step 6: Commit and open the PR**

```bash
git add game/ServerScriptService/Services/FireService.luau
git commit -m "game(fire): FireService on FireSim, re-index on LocationBuilt, test hooks"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch   # once CI is green; paste the counters line from Step 5 into the PR body
```

---

### Task G1.3: FireFxController, the client flames, lights and steam puff (Dev B, G1, 0.75 h, P0)

**Files:**
- Modify (replace the Task 0 stub): `game/StarterPlayerScripts/Controllers/FireFxController.luau`

**Interfaces:**
- Consumes: tag `Burning`, attrs `FireLevel` and `Charred` (G1.2); `FireConfig.MaxClientFx/MaxClientLights/FxDistance`;
  `Palette.FireCore/FireBody/FireEdge/FireDark/SmokeWhite` (Task 0).
- Produces: client-only `Attachment "FireFx"` (with a ParticleEmitter, plus a PointLight for the nearest 10) under each
  nearby burning part, and a one-shot `Attachment "SteamFx"` when a part is put out (not when it chars). It produces
  nothing that gameplay reads.

- [ ] **Step 1: Branch and write the live check**

```bash
git switch main && git pull --rebase && git switch -c g1/fire-fx
```

Server part (run first). It builds three cubes 20 studs in front of the player and ignites the middle one:

```lua
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local DevHook = game.ServerStorage.DevHook
local t0 = os.clock()
repeat task.wait(0.25) until (Players:GetPlayers()[1] and Players:GetPlayers()[1].Character) or os.clock() - t0 > 15
local root = Players:GetPlayers()[1].Character:WaitForChild("HumanoidRootPart")
local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit
local m = Instance.new("Model")
m.Name = "G1FxTest"
for i = -1, 1 do
	local p = Instance.new("Part")
	p.Name = "Fx" .. i
	p.Anchored = true
	p.Size = Vector3.new(4, 4, 4)
	p.Position = root.Position + look * 20 + root.CFrame.RightVector * (i * 8) + Vector3.new(0, 2, 0)
	CollectionService:AddTag(p, "Flammable")
	p.Parent = m
end
m.Parent = workspace
DevHook:Invoke("FireService", "_index", m, "G1FxTest")
local _, lit = DevHook:Invoke("FireService", "_ignite", m.Fx0.Position)
return lit and lit.Name
```

Client part (run right after, in the `Client` datamodel):

```lua
task.wait(1)
local fx, lights = 0, 0
for _, d in workspace:GetDescendants() do
	if d:IsA("Attachment") and d.Name == "FireFx" then
		fx += 1
		if d:FindFirstChildOfClass("PointLight") then lights += 1 end
	end
end
return `{fx} fx, {lights} lights`
```

Douse it (Server) and check the steam (Client):

```lua
-- Server
local m = workspace.G1FxTest
local root = game.Players:GetPlayers()[1].Character.HumanoidRootPart
local _, hit = game.ServerStorage.DevHook:Invoke("FireService", "_water", root.Position, (m.Fx0.Position - root.Position).Unit, 1000)
return hit
```

```lua
-- Client (run within 1 s)
local steam = 0
for _, d in workspace:GetDescendants() do
	if d:IsA("Attachment") and d.Name == "SteamFx" then steam += 1 end
end
return steam
```

Cleanup (Server):

```lua
local DevHook = game.ServerStorage.DevHook
DevHook:Invoke("FireService", "_forget", "G1FxTest")
workspace.G1FxTest:Destroy()
return "clean"
```

- [ ] **Step 2: Run against the stub controller and confirm it fails**

Expected (FAIL): the server returns `"Fx0"`, and the client returns `0 fx, 0 lights`.

- [ ] **Step 3: Replace the stub**

`game/StarterPlayerScripts/Controllers/FireFxController.luau`:

```lua
--!strict
-- FireFxController [owner: G1]. Client-only fire visuals. The server replicates only the tag "Burning"
-- and the attr FireLevel (1..3); this controller turns them into local ParticleEmitters and PointLights,
-- nearest first, within FireConfig.MaxClientFx / MaxClientLights / FxDistance. When a part stops
-- burning without being Charred (it was put out) it plays a one-shot steam puff. Nothing here affects
-- gameplay.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local FireConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("FireConfig") :: ModuleScript)

local FLAME_TEXTURE = "rbxasset://textures/particles/fire_main.dds"
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

type Fx = { emitter: ParticleEmitter, light: PointLight?, attachment: Attachment }

local FireFxController = {}
FireFxController.Priority = 50

local fx: { [BasePart]: Fx } = {}
local burning: { [BasePart]: true } = {}

local function clear(part: BasePart)
	local f = fx[part]
	if f then
		f.attachment:Destroy() -- destroys emitter and light with it
		fx[part] = nil
	end
end

local function apply(part: BasePart, withLight: boolean)
	local level = (part:GetAttribute(Names.Attr.FireLevel) :: number?) or 1
	local f = fx[part]
	if not f then
		local a = Instance.new("Attachment")
		a.Name = "FireFx"
		a.Position = Vector3.new(0, part.Size.Y / 2, 0) -- top face
		local e = Instance.new("ParticleEmitter")
		e.Texture = FLAME_TEXTURE
		e.LightEmission = 1
		e.LightInfluence = 0
		e.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Palette.FireCore),
			ColorSequenceKeypoint.new(0.25, Palette.FireBody),
			ColorSequenceKeypoint.new(0.65, Palette.FireEdge),
			ColorSequenceKeypoint.new(1, Palette.FireDark),
		})
		e.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(0.7, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		})
		e.Lifetime = NumberRange.new(0.45, 0.8)
		e.Speed = NumberRange.new(3, 6)
		e.SpreadAngle = Vector2.new(12, 12)
		e.Acceleration = Vector3.new(0, 6, 0)
		e.Drag = 1.5
		e.Rotation = NumberRange.new(-30, 30)
		e.RotSpeed = NumberRange.new(-40, 40)
		e.EmissionDirection = Enum.NormalId.Top
		e.Parent = a
		a.Parent = part
		f = { emitter = e, light = nil, attachment = a }
		fx[part] = f
	end
	local current = f :: Fx
	local s = math.clamp(math.min(part.Size.X, part.Size.Z) / 4, 0.6, 3)
	current.emitter.Rate = 10 + 10 * level
	current.emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, (0.8 + 0.4 * level) * s),
		NumberSequenceKeypoint.new(0.35, (1.6 + 0.8 * level) * s),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	if withLight and not current.light then
		local l = Instance.new("PointLight")
		l.Color = Palette.FireBody
		l.Shadows = false
		l.Parent = current.attachment
		current.light = l
	elseif not withLight and current.light then
		current.light:Destroy()
		current.light = nil
	end
	if current.light then
		current.light.Range = 8 + 4 * level
		current.light.Brightness = 1 + 0.6 * level
	end
end

-- One-shot white puff where a fire was put out (not when it burnt out to Charred).
local function steamPuff(part: BasePart)
	local char = Players.LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or (part.Position - root.Position).Magnitude > FireConfig.FxDistance then
		return
	end
	local a = Instance.new("Attachment")
	a.Name = "SteamFx"
	a.Position = Vector3.new(0, part.Size.Y / 2, 0)
	local e = Instance.new("ParticleEmitter")
	e.Texture = SMOKE_TEXTURE
	e.Enabled = false
	e.Color = ColorSequence.new(Palette.SmokeWhite)
	e.Transparency = NumberSequence.new(0.1, 1)
	e.Size = NumberSequence.new(2, 6)
	e.Lifetime = NumberRange.new(0.8, 1.2)
	e.Speed = NumberRange.new(6, 9)
	e.SpreadAngle = Vector2.new(35, 35)
	e.EmissionDirection = Enum.NormalId.Top
	e.Parent = a
	a.Parent = part
	e:Emit(20)
	Debris:AddItem(a, 2)
end

-- Re-rank by distance a few times a second; only the nearest MaxClientFx get effects.
local function refresh()
	local char = Players.LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local list: { { part: BasePart, d: number } } = {}
	for part in burning do
		table.insert(list, { part = part, d = (part.Position - root.Position).Magnitude })
	end
	table.sort(list, function(a, b)
		return a.d < b.d
	end)
	local keep: { [BasePart]: boolean } = {}
	for i, item in list do
		if i > FireConfig.MaxClientFx or item.d > FireConfig.FxDistance then
			break
		end
		keep[item.part] = true
		apply(item.part, i <= FireConfig.MaxClientLights)
	end
	for part in fx do
		if not keep[part] then
			clear(part)
		end
	end
end

function FireFxController:Init(_controllers: { [string]: any }) end

function FireFxController:Start()
	local function added(inst: Instance)
		if inst:IsA("BasePart") then
			burning[inst] = true
		end
	end
	local function removed(inst: Instance)
		if inst:IsA("BasePart") then
			burning[inst] = nil
			clear(inst)
			if inst:IsDescendantOf(workspace) and inst:GetAttribute(Names.Attr.Charred) ~= true then
				steamPuff(inst)
			end
		end
	end
	CollectionService:GetInstanceAddedSignal(Names.Tag.Burning):Connect(added)
	CollectionService:GetInstanceRemovedSignal(Names.Tag.Burning):Connect(removed)
	for _, inst in CollectionService:GetTagged(Names.Tag.Burning) do
		added(inst)
	end
	while true do
		refresh()
		task.wait(0.25)
	end
end

return FireFxController
```

- [ ] **Step 4: Compile check**

Run: `python3 game/tools/sync.py check --root game` → `OK: checked <N> files, 0 failed`

- [ ] **Step 5: Live check (it passes now)**

Run the four snippets in order.
Expected:
- The server returns `"Fx0"`.
- The client returns between `1 fx, 1 lights` and `3 fx, 3 lights`: Fx-1 and Fx1 light at 3.0 s, so a 1 s wait usually
  shows 1.
- The douse returns `hit` ≥ 1.
- The steam check returns ≥ 1.
- Take `mcp__Roblox_Studio__screen_capture {"studio_id": "<id>"}` while the cube is burning. Flames should rise from its
  top face.
- Cleanup returns `"clean"`, and the probe report shows `"errors":[]`.

Stop the playtest.

- [ ] **Step 6: Commit and open the PR**

```bash
git add game/StarterPlayerScripts/Controllers/FireFxController.luau
git commit -m "game(fire): FireFxController flames, lights, steam puff (client only)"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

---

### Task G1.4: ToolService, the hose, tank, spray and refill prompts (Dev B, G1, 1.5 h, P0)

**Files:**
- Modify (replace the Task 0 stub): `game/ServerScriptService/Services/ToolService.luau`
- Modify: `game/ReplicatedStorage/Config/ToolConfig.luau` (all G1 keys now, so later tasks don't touch it again)

**Interfaces:**
- Consumes: `services.FireService:ApplyWater(player, origin, aim, litres)` (G1.2); `Net.event`, `Net.onServer`,
  `Net.unit`, `Net.notify` (Task 0); tags `Hydrant` and `TruckRefill`, each part carrying exactly one ProximityPrompt made by
  G2 (`MapKit.hydrant` "Body", and TruckBuilder's "Reel"), found **by tag + `FindFirstChildOfClass("ProximityPrompt")`, never by
  part name**; Player attrs `Carrying` (G3 RescueService) and `Downed` (G3 SquadService).
- Produces (§10): `ToolService:GiveLoadout(player)` (Tools named exactly `"Hose"` and `"Axe"`, with `Hose.Handle.Nozzle`
  as an Attachment), `ToolService:Refill(player, litres?)`, `ToolService:ResetDoors(locationId)` (a no-op until G1.6),
  signals `WaterUsed(player, litres)`, `DoorBroken`, `HoseHit` (declared), remote `Tool/Spray`; Player attrs `Water`,
  `TankSize`, `Spraying`; counters `water_used` and `refills`. Test hook: `_spray(player, aim)`.

- [ ] **Step 1: Branch and write the live check**

```bash
git switch main && git pull --rebase && git switch -c g1/hose
```

Check code (Server datamodel). It sets a cube on fire 10 studs in front of the player's head, sprays it 10 times, then refills:

```lua
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local DevHook = game.ServerStorage.DevHook
local t0 = os.clock()
repeat task.wait(0.25) until (Players:GetPlayers()[1] and Players:GetPlayers()[1].Character) or os.clock() - t0 > 15
local player = Players:GetPlayers()[1]
local char = player.Character
DevHook:Invoke("ToolService", "GiveLoadout", player)
local hose = player.Backpack:WaitForChild("Hose", 5)
local axe = player.Backpack:FindFirstChild("Axe")
char:WaitForChild("Humanoid"):EquipTool(hose)
task.wait(0.5)
local head = char.Head
local look = Vector3.new(head.CFrame.LookVector.X, 0, head.CFrame.LookVector.Z).Unit
local m = Instance.new("Model")
m.Name = "G1HoseTest"
local p = Instance.new("Part")
p.Name = "Target"
p.Anchored = true
p.Size = Vector3.new(4, 4, 4)
p.Position = head.Position + look * 10
CollectionService:AddTag(p, "Flammable")
p.Parent = m
m.Parent = workspace
DevHook:Invoke("FireService", "_index", m, "G1HoseTest")
DevHook:Invoke("FireService", "_ignite", p.Position)
local burningBefore = CollectionService:HasTag(p, "Burning")
for _ = 1, 10 do
	DevHook:Invoke("ToolService", "_spray", player, (p.Position - head.Position).Unit)
	task.wait(0.1)
end
local out = {
	hose = hose ~= nil, axe = axe ~= nil, nozzle = hose and hose.Handle:FindFirstChild("Nozzle") ~= nil,
	burningBefore = burningBefore, burningAfter = CollectionService:HasTag(p, "Burning"),
	water = math.floor(player:GetAttribute("Water") + 0.5), spraying = player:GetAttribute("Spraying"),
}
task.wait(0.5)
out.sprayingLater = player:GetAttribute("Spraying")
DevHook:Invoke("ToolService", "Refill", player)
out.waterRefilled = player:GetAttribute("Water")
local _, selfOk, selfMsg = DevHook:Invoke("ToolService", "_selftest")
out.selftest = { selfOk, selfMsg }
DevHook:Invoke("FireService", "_forget", "G1HoseTest")
m:Destroy()
local r = HttpService:JSONDecode(game.ServerStorage.ForgeProbe:Invoke("report"))
out.counters = r.counters
out.errors = r.errors
return HttpService:JSONEncode(out)
```

- [ ] **Step 2: Run it against the stub and confirm it fails**

Expected (FAIL): `WaitForChild("Hose", 5)` returns nil, so the check errors with `attempt to index nil with 'Handle'` or
returns `"hose":false`.

- [ ] **Step 3: Write ToolConfig (complete for the whole lane)**

`game/ReplicatedStorage/Config/ToolConfig.luau`:

```lua
--!strict
-- ToolConfig [owner: G1]. Hose, tank, axe, door and friendly-fire numbers. Read at use time.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	-- hose and tank (G1.4, G1.5)
	TankSize = 100, -- litres in the backpack tank (about 8 s of spraying)
	LitresPerSpray = 1.2, -- per Tool/Spray event; the client sends SprayHz events/s -> 12 L/s
	SprayHz = 10, -- client send rate while the trigger is held
	SprayingClearSeconds = 0.25, -- Player attr Spraying goes false this long after the last spray
	LowWaterFraction = 0.2, -- under this the hose sputters (client) and the HUD warns
	-- axe and doors (G1.6)
	AxeCooldown = 0.6, -- seconds between swings
	AxeReach = 8, -- studs from HumanoidRootPart to the door centre
	DoorHits = 3, -- axe hits to break a locked door
	-- friendly fire (G1.7)
	HoseHitRange = 20, -- studs: teammates inside the spray cone within this range get pushed
	HoseHitCos = 0.9, -- ~25 degree cone for hitting players
	HosePush = 35, -- studs/s added to the victim along the spray (plus a little lift)
	HoseHitCooldown = 0.5, -- per sprayer/victim pair
})
```

- [ ] **Step 4: Replace the ToolService stub**

`game/ServerScriptService/Services/ToolService.luau`:

```lua
--!strict
-- ToolService [owner: G1]. Loadout (Hose, Axe), backpack water tank, hose spray, refills.
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   ToolService:GiveLoadout(player: Player)              -- Hose + Axe, full tank
--   ToolService:Refill(player: Player, litres: number?)  -- nil = full
--   ToolService:ResetDoors(locationId: string)           -- doors arrive in G1.6; no doors yet
-- Signals: DoorBroken(player, door: BasePart), WaterUsed(player, litres: number),
--          HoseHit(sprayer: Player, victim: Player)
-- Remotes: Tool/Spray (C->S, aim: Vector3 unit, 12/s burst 4)
-- Writes: Player attrs Water, TankSize, Spraying
-- Reads: Player attrs Carrying (RescueService), Downed (SquadService); prompts under parts tagged
--        Hydrant / TruckRefill (one ProximityPrompt each, created by the map builders)
-- Counters: water_used, refills
-- Test hooks (DevHook only): _spray(player, aim), _selftest()

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local ToolConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ToolConfig") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)

local ToolService = {}
ToolService.Priority = 50
ToolService.DoorBroken = Signal.new() :: Signal.Signal<Player, BasePart>
ToolService.WaterUsed = Signal.new() :: Signal.Signal<Player, number>
ToolService.HoseHit = Signal.new() :: Signal.Signal<Player, Player>

local services: { [string]: any } = {}
local lastSpray: { [Player]: number } = {}
local hooked: { [ProximityPrompt]: true } = {}

-- tools ------------------------------------------------------------------------------------
local function toolPart(name: string, size: Vector3, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	return p
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = a
end

local function makeHose(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Hose"
	tool.ToolTip = "Hold click to spray"
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	-- handle runs along Z; the nozzle points down -Z (forward from the hand)
	local handle = toolPart("Handle", Vector3.new(0.6, 0.6, 2.4), Palette.HoseYellow)
	handle.Parent = tool
	local tip = toolPart("Tip", Vector3.new(0.75, 0.75, 0.6), Palette.BrassCoupling)
	tip.CFrame = handle.CFrame * CFrame.new(0, 0, -1.5)
	tip.Parent = tool
	weld(handle, tip)
	local nozzle = Instance.new("Attachment")
	nozzle.Name = "Nozzle"
	nozzle.Position = Vector3.new(0, 0, -1.9)
	nozzle.Parent = handle
	-- hand holds the back half; tune this in the screen_capture check if the nozzle doesn't point forward
	tool.Grip = CFrame.new(0, 0, 0.6)
	return tool
end

local function makeAxe(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Axe"
	tool.ToolTip = "Click to break locked doors"
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	local handle = toolPart("Handle", Vector3.new(0.4, 3.2, 0.4), Palette.BookshelfWood)
	handle.Parent = tool
	local head = toolPart("Head", Vector3.new(0.3, 0.9, 1.4), Palette.TruckChrome)
	head.CFrame = handle.CFrame * CFrame.new(0, 1.3, -0.5)
	head.Parent = tool
	weld(handle, head)
	local back = toolPart("Back", Vector3.new(0.35, 0.5, 0.5), Palette.HelmetRed)
	back.CFrame = handle.CFrame * CFrame.new(0, 1.3, 0.35)
	back.Parent = tool
	weld(handle, back)
	tool.Grip = CFrame.new(0, -1, 0)
	return tool
end

local function removeTools(player: Player)
	for _, holder in { player:FindFirstChildOfClass("Backpack"), player.Character } do
		if holder then
			for _, name in { "Hose", "Axe" } do
				local t = holder:FindFirstChild(name)
				if t and t:IsA("Tool") then
					t:Destroy()
				end
			end
		end
	end
end

-- spray ------------------------------------------------------------------------------------
local function blocked(player: Player): boolean
	local carrying = (player:GetAttribute(Names.Attr.Carrying) :: string?) or ""
	return carrying ~= "" or player:GetAttribute(Names.Attr.Downed) == true
end

local function markSpraying(player: Player)
	local now = os.clock()
	lastSpray[player] = now
	player:SetAttribute(Names.Attr.Spraying, true)
	task.delay(ToolConfig.SprayingClearSeconds + 0.05, function()
		if lastSpray[player] == now and player.Parent then
			player:SetAttribute(Names.Attr.Spraying, false)
		end
	end)
end

local function sprayOnce(player: Player, aim: Vector3)
	local char = player.Character
	if not char or not char:FindFirstChild("Hose") or blocked(player) then
		return
	end
	local head = char:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end
	local water = (player:GetAttribute(Names.Attr.Water) :: number?) or 0
	local litres = math.min(water, ToolConfig.LitresPerSpray)
	if litres <= 0 then
		return
	end
	player:SetAttribute(Names.Attr.Water, water - litres)
	Telemetry.count("water_used", litres)
	ToolService.WaterUsed:Fire(player, litres)
	markSpraying(player)
	local Fire = services.FireService
	if Fire then
		Fire:ApplyWater(player, head.Position, aim, litres)
	end
end

-- prompts ----------------------------------------------------------------------------------
-- Every Hydrant / TruckRefill / Door part has exactly one ProximityPrompt made by its builder.
local function hookPrompt(part: Instance, onTrigger: (Player, BasePart) -> ())
	if not part:IsA("BasePart") then
		return
	end
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if not prompt or hooked[prompt] then
		return
	end
	hooked[prompt] = true
	prompt.Triggered:Connect(function(player: Player)
		onTrigger(player, part :: BasePart)
	end)
	prompt.Destroying:Connect(function()
		hooked[prompt] = nil
	end)
end

local function watchTag(tag: string, onTrigger: (Player, BasePart) -> ())
	CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst: Instance)
		task.defer(hookPrompt, inst, onTrigger) -- builders add the prompt right after the tag
	end)
	for _, inst in CollectionService:GetTagged(tag) do
		hookPrompt(inst, onTrigger)
	end
end

-- service ----------------------------------------------------------------------------------
function ToolService:Init(all: { [string]: any })
	services = all
end

function ToolService:Start()
	local Spray = Net.event("Tool", "Spray")
	Net.onServer(Spray, { rate = 12, burst = 4 }, function(player: Player, rawAim: any)
		local aim = Net.unit(rawAim)
		if aim then
			sprayOnce(player, aim)
		end
	end)
	local function refill(player: Player, _part: BasePart)
		ToolService:Refill(player, nil)
	end
	watchTag(Names.Tag.Hydrant, refill)
	watchTag(Names.Tag.TruckRefill, refill)
	Players.PlayerRemoving:Connect(function(player: Player)
		lastSpray[player] = nil
	end)
end

function ToolService:GiveLoadout(player: Player)
	removeTools(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		makeHose().Parent = backpack
		makeAxe().Parent = backpack
	end
	player:SetAttribute(Names.Attr.TankSize, ToolConfig.TankSize)
	player:SetAttribute(Names.Attr.Water, ToolConfig.TankSize)
	player:SetAttribute(Names.Attr.Spraying, false)
end

function ToolService:Refill(player: Player, litres: number?)
	local size = (player:GetAttribute(Names.Attr.TankSize) :: number?) or ToolConfig.TankSize
	local water = (player:GetAttribute(Names.Attr.Water) :: number?) or 0
	local new = math.min(size, water + (litres or size))
	player:SetAttribute(Names.Attr.TankSize, size)
	player:SetAttribute(Names.Attr.Water, new)
	Telemetry.count("refills")
	if new >= size then
		Net.notify(player, "Tank full!", "good")
	end
end

function ToolService:ResetDoors(_locationId: string)
	-- G1.6 adds doors; until then there is nothing to reset.
end

-- test hooks -------------------------------------------------------------------------------
function ToolService:_spray(player: Player, aim: Vector3)
	sprayOnce(player, aim.Unit)
end

function ToolService:_selftest(): (boolean, string)
	local net = ReplicatedStorage:FindFirstChild("Net")
	local ns = net and net:FindFirstChild("Tool")
	if not (ns and ns:FindFirstChild("Spray")) then
		return false, "Tool/Spray remote missing"
	end
	local hose = makeHose()
	local ok = hose:FindFirstChild("Handle") ~= nil and (hose :: any).Handle:FindFirstChild("Nozzle") ~= nil
	hose:Destroy()
	if not ok then
		return false, "Hose has no Handle.Nozzle"
	end
	return true, "ok"
end

return ToolService
```

- [ ] **Step 5: Compile check**

Run: `python3 game/tools/sync.py check --root game` → `OK: checked <N> files, 0 failed`

- [ ] **Step 6: Live check (it passes now)**

Expected JSON:
- `"hose":true`, `"axe":true`, `"nozzle":true`.
- `"burningBefore":true` and `"burningAfter":false`. The fire starts at heat 40 and grows 6/s, and each spray cools it by
  9 × 1.2 = 10.8, so it is out after about 3 sprays.
- `"water":88`, because 10 sprays × 1.2 L = 12 L.
- `"spraying":true`, then `"sprayingLater":false`.
- `"waterRefilled":100` and `"selftest":[true,"ok"]`.
- Counters: `water_used` ≈ 12 (allow float noise), `fires_extinguished` = 1, `refills` = 1.
- `"errors":[]`.

Take `screen_capture` with the Hose equipped. If the nozzle doesn't point forward from the hand, adjust `tool.Grip` in
`makeHose` and re-run. Gameplay does not depend on the grip, because the spray direction comes from the camera.

**Integration point (G2 hydrants and truck merged):** in Play, walk to a hydrant (Town or Station) or the truck reel and
hold E on "Refill". Water returns to 100, a "Tank full!" toast appears once G3's HudController lands, and `refills`
increments.
**Integration point (G3 HudController):** the water gauge reads `Water` and `TankSize` from these Player attributes.

- [ ] **Step 7: Commit and open the PR**

```bash
git add game/ServerScriptService/Services/ToolService.luau game/ReplicatedStorage/Config/ToolConfig.luau
git commit -m "game(tools): hose loadout, backpack tank, Tool/Spray, hydrant/truck refill"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

---

### Task G1.5: ToolController, the spray input and water streams (Dev B, G1, 1.0 h, P0)

**Files:**
- Modify (replace the Task 0 stub): `game/StarterPlayerScripts/Controllers/ToolController.luau`

**Interfaces:**
- Consumes: remote `Tool/Spray` (G1.4), Tool `"Hose"` with `Handle.Nozzle`, Player attrs `Spraying`, `Water`, `TankSize`;
  `ToolConfig.SprayHz/LowWaterFraction/TankSize`; `Palette.WaterSpray`.
- Produces: `Tool/Spray:FireServer(camera LookVector)` at 10 Hz while the Hose is activated; a client-only stream
  `workspace.Terrain.HoseStream_<UserId>` (an Attachment with a ParticleEmitter) for every player who is spraying.

- [ ] **Step 1: Branch and write the live check**

```bash
git switch main && git pull --rebase && git switch -c g1/hose-input
```

Server (equip the hose):

```lua
local Players = game:GetService("Players")
local t0 = os.clock()
repeat task.wait(0.25) until (Players:GetPlayers()[1] and Players:GetPlayers()[1].Character) or os.clock() - t0 > 15
local player = Players:GetPlayers()[1]
game.ServerStorage.DevHook:Invoke("ToolService", "GiveLoadout", player)
player.Character:WaitForChild("Humanoid"):EquipTool(player.Backpack:WaitForChild("Hose", 5))
return player:GetAttribute("Water")
```

Client (hold the trigger for 2 s through the real Tool events):

```lua
local lp = game.Players.LocalPlayer
local hose = lp.Character:WaitForChild("Hose", 5)
hose:Activate()
task.wait(0.3)
local stream = workspace.Terrain:FindFirstChild("HoseStream_" .. lp.UserId)
local on = stream ~= nil and stream:FindFirstChildOfClass("ParticleEmitter").Enabled
task.wait(1.7)
hose:Deactivate()
task.wait(0.5)
local off = stream ~= nil and not stream:FindFirstChildOfClass("ParticleEmitter").Enabled
return `on={on} off={off} water={math.floor(lp:GetAttribute("Water") + 0.5)}`
```

Server (counters):

```lua
local r = game:GetService("HttpService"):JSONDecode(game.ServerStorage.ForgeProbe:Invoke("report"))
return game:GetService("HttpService"):JSONEncode({ counters = r.counters, errors = r.errors })
```

- [ ] **Step 2: Run against the stub controller and confirm it fails**

Expected (FAIL): the client returns `on=false off=false water=100`, because nothing is sent.

- [ ] **Step 3: Replace the stub**

`game/StarterPlayerScripts/Controllers/ToolController.luau`:

```lua
--!strict
-- ToolController [owner: G1]. Hose input and water-stream visuals.
--   Input: while the local Hose is activated (mouse held or touch held), send Tool/Spray with the
--   camera's LookVector ToolConfig.SprayHz times a second. The server decides everything else.
--   Visuals: for EVERY player whose Spraying attr is true (and the local player while the trigger is
--   held), a ParticleEmitter stream from their Hose's Handle.Nozzle, aimed along the camera (local
--   player) or the Head's look (others). Streams live on Attachments under workspace.Terrain named
--   "HoseStream_<UserId>" so they can be re-aimed freely.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local ToolConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ToolConfig") :: ModuleScript)

type Stream = { attachment: Attachment, emitter: ParticleEmitter }

local ToolController = {}
ToolController.Priority = 50

local LocalPlayer = Players.LocalPlayer
local holding = false
local streams: { [Player]: Stream } = {}
local hookedTools: { [Tool]: true } = setmetatable({}, { __mode = "k" }) :: any

local function nozzleOf(player: Player): Attachment?
	local char = player.Character
	local hose = char and char:FindFirstChild("Hose")
	local handle = hose and hose:FindFirstChild("Handle")
	local nozzle = handle and handle:FindFirstChild("Nozzle")
	return if nozzle and nozzle:IsA("Attachment") then nozzle else nil
end

local function water(): number
	return (LocalPlayer:GetAttribute(Names.Attr.Water) :: number?) or 0
end

local function ensureStream(player: Player): Stream
	local s = streams[player]
	if s then
		return s
	end
	local a = Instance.new("Attachment")
	a.Name = `HoseStream_{player.UserId}`
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	e.EmissionDirection = Enum.NormalId.Front
	e.Color = ColorSequence.new(Palette.WaterSpray)
	e.Transparency = NumberSequence.new(0.15, 0.7)
	e.Size = NumberSequence.new(0.5, 1.4)
	e.Lifetime = NumberRange.new(0.5, 0.6)
	e.Rate = 140
	e.Speed = NumberRange.new(65, 75)
	e.SpreadAngle = Vector2.new(2.5, 2.5)
	e.Acceleration = Vector3.new(0, -55, 0)
	e.LightInfluence = 0.6
	e.LightEmission = 0.2
	e.Parent = a
	a.Parent = workspace.Terrain
	s = { attachment = a, emitter = e }
	streams[player] = s
	return s
end

local function dropStream(player: Player)
	local s = streams[player]
	if s then
		s.attachment:Destroy()
		streams[player] = nil
	end
end

-- Under ToolConfig.LowWaterFraction of the tank the stream sputters (thinner), so players look for a refill.
local function lowWater(player: Player): boolean
	local size = (player:GetAttribute(Names.Attr.TankSize) :: number?) or ToolConfig.TankSize
	local left = (player:GetAttribute(Names.Attr.Water) :: number?) or 0
	return left < size * ToolConfig.LowWaterFraction
end

local function aimOf(player: Player): Vector3?
	if player == LocalPlayer then
		local cam = workspace.CurrentCamera
		return cam and cam.CFrame.LookVector
	end
	local char = player.Character
	local head = char and char:FindFirstChild("Head") :: BasePart?
	return head and head.CFrame.LookVector
end

local function render()
	for _, player in Players:GetPlayers() do
		local nozzle = nozzleOf(player)
		local on = player:GetAttribute(Names.Attr.Spraying) == true
		if player == LocalPlayer then
			on = on or (holding and water() > 0)
		end
		local aim = aimOf(player)
		if nozzle and on and aim then
			local s = ensureStream(player)
			local from = nozzle.WorldPosition
			s.attachment.WorldCFrame = CFrame.lookAt(from, from + aim)
			s.emitter.Rate = if lowWater(player) then 50 else 140
			s.emitter.Enabled = true
		elseif streams[player] then
			streams[player].emitter.Enabled = false
		end
	end
end

-- Tool.Activated / Deactivated fire for mouse and touch alike.
local function hookTool(inst: Instance)
	if not inst:IsA("Tool") or inst.Name ~= "Hose" or hookedTools[inst] then
		return
	end
	hookedTools[inst] = true
	inst.Activated:Connect(function()
		holding = true
	end)
	inst.Deactivated:Connect(function()
		holding = false
	end)
	inst.Unequipped:Connect(function()
		holding = false
	end)
end

local function hookCharacter(char: Model)
	holding = false
	char.ChildAdded:Connect(hookTool)
	for _, child in char:GetChildren() do
		hookTool(child)
	end
end

function ToolController:Init(_controllers: { [string]: any }) end

function ToolController:Start()
	local Spray = Net.event("Tool", "Spray")
	LocalPlayer.CharacterAdded:Connect(hookCharacter)
	if LocalPlayer.Character then
		hookCharacter(LocalPlayer.Character)
	end
	Players.PlayerRemoving:Connect(dropStream)
	RunService.RenderStepped:Connect(render)
	while true do
		task.wait(1 / ToolConfig.SprayHz)
		local char = LocalPlayer.Character
		local cam = workspace.CurrentCamera
		if holding and cam and char and char:FindFirstChild("Hose") and water() > 0 then
			Spray:FireServer(cam.CFrame.LookVector)
		end
	end
end

return ToolController
```

- [ ] **Step 4: Compile check**

Run: `python3 game/tools/sync.py check --root game` → `OK: checked <N> files, 0 failed`

- [ ] **Step 5: Live check (it passes now)**

Expected:
- The first server snippet returns `100`.
- The client returns `on=true off=true water=76`: 2 s × 10 Hz × 1.2 L = 24 L, so allow 75 to 78.
- Counters: `water_used` ≈ 24, `net_dropped` absent or 0 (10/s is under the 12/s limit), and `"errors":[]`.
- Take `screen_capture` while repeating the client snippet: a blue-white arcing stream should leave the nozzle.

Stop the playtest.

- [ ] **Step 6: Commit and open the PR**

```bash
git add game/StarterPlayerScripts/Controllers/ToolController.luau
git commit -m "game(tools): ToolController spray input 10 Hz + stream visuals for all players"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

**P0 checkpoint for G1 (Sat 10:00).** With G2's Town and G3's MissionService in main, a solo auto round shows fires
spreading, and the hose puts them out. Counters: `fires_spread > 0`, `fires_extinguished > 0`, `water_used > 0`.

---

### Task G1.6: The axe and locked doors (Dev B, G1, 1.0 h, P1)

**Files:**
- Create: `game/ServerScriptService/Lib/Tools/DoorBreaker.luau`
- Modify: `game/ServerScriptService/Services/ToolService.luau` (full new version below)

**Interfaces:**
- Consumes: tag `Door` with attrs `Locked` and `Broken`, and the one ProximityPrompt that `MapKit.door` creates (G2);
  `services.MapService:GetLocation(id)`; `ToolConfig.AxeCooldown/AxeReach/DoorHits`.
- Produces (§10): `ToolService.DoorBroken: Signal<Player, BasePart>` (BlameService counts `doors`),
  `ToolService:ResetDoors(locationId)`; Door attrs `Broken = true` and `Locked = false` on break; counter `doors_broken`;
  toast `"Locked! Use the axe"`. Test hooks: `_swing(player)`, `_doorPrompt(player, door)`.
  `DoorBreaker.toggle/hit/nearestLocked/reset` are internal to G1.

- [ ] **Step 1: Branch and write the live check**

```bash
git switch main && git pull --rebase && git switch -c g1/axe-doors
```

Check code (Server). It builds two locked doors and one unlocked door with G2's `MapKit.door`, 5 studs in front of the
player:

```lua
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local DevHook = game.ServerStorage.DevHook
local MapKit = require(game.ServerScriptService.Lib.Map.MapKit)
local t0 = os.clock()
repeat task.wait(0.25) until (Players:GetPlayers()[1] and Players:GetPlayers()[1].Character) or os.clock() - t0 > 15
local player = Players:GetPlayers()[1]
local char = player.Character
DevHook:Invoke("ToolService", "GiveLoadout", player)
char:WaitForChild("Humanoid"):EquipTool(player.Backpack:WaitForChild("Axe", 5))
task.wait(0.3)
local root = char.HumanoidRootPart
local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit
local at = root.Position + look * 5 + Vector3.new(0, 0.5, 0)
local m = Instance.new("Model")
m.Name = "G1DoorTest"
local lockedA = MapKit.door(m, "LockedA", CFrame.lookAt(at, at + look), true)
local lockedB = MapKit.door(m, "LockedB", CFrame.new(at + Vector3.new(0, 0, 40)), true)
local open = MapKit.door(m, "Unlocked", CFrame.new(at + Vector3.new(0, 0, 60)), false)
m.Parent = workspace
task.wait(0.3) -- ToolService hooks the prompts on the tag-added signal (deferred)
for _ = 1, 3 do
	DevHook:Invoke("ToolService", "_swing", player)
end
for _ = 1, 3 do
	DevHook:Invoke("ToolService", "_doorPrompt", player, lockedB)
end
DevHook:Invoke("ToolService", "_doorPrompt", player, open)
local out = {
	aBroken = lockedA:GetAttribute("Broken"), aLocked = lockedA:GetAttribute("Locked"), aCollide = lockedA.CanCollide,
	bBroken = lockedB:GetAttribute("Broken"), openCollide = open.CanCollide,
	openText = open:FindFirstChildOfClass("ProximityPrompt").ActionText,
}
m:Destroy()
local r = HttpService:JSONDecode(game.ServerStorage.ForgeProbe:Invoke("report"))
out.counters = r.counters
out.errors = r.errors
return HttpService:JSONEncode(out)
```

- [ ] **Step 2: Run it against G1.4's ToolService and confirm it fails**

Expected (FAIL): `DevHook` returns `false, "...attempt to call a nil value..."` for `_swing`, and
`"aBroken":false`, `"bBroken":false`, `"openCollide":true`.

- [ ] **Step 3: Create DoorBreaker**

`game/ServerScriptService/Lib/Tools/DoorBreaker.luau`:

```lua
--!strict
-- DoorBreaker [owner: G1]. Door state for ToolService: open/close unlocked doors, count axe hits on
-- locked ones, break them, reset them. Doors are parts tagged Door (MapKit.door) with attrs Locked,
-- Broken and one ProximityPrompt. Server only; ToolService is the only caller.
--
--   DoorBreaker.toggle(door: BasePart)                         -- unlocked doors: open <-> closed
--   DoorBreaker.hit(door: BasePart): boolean                   -- one axe hit; true = it just broke
--   DoorBreaker.nearestLocked(root: BasePart, reach: number): BasePart?   -- in front of `root`
--   DoorBreaker.reset(door: BasePart)                          -- back to its first-seen state

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local ToolConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ToolConfig") :: ModuleScript)

type DoorState = { locked: boolean, transparency: number, actionText: string }

local DoorBreaker = {}

local hits: { [BasePart]: number } = setmetatable({}, { __mode = "k" }) :: any
local original: { [BasePart]: DoorState } = setmetatable({}, { __mode = "k" }) :: any

local function prompt(door: BasePart): ProximityPrompt?
	return door:FindFirstChildOfClass("ProximityPrompt")
end

local function remember(door: BasePart)
	if original[door] then
		return
	end
	local p = prompt(door)
	original[door] = {
		locked = door:GetAttribute(Names.Attr.Locked) == true,
		transparency = door.Transparency,
		actionText = if p then p.ActionText else "Open",
	}
end

-- Wood chips: small unanchored blocks that bounce away and vanish after 3 s.
local function chips(door: BasePart)
	local rng = Random.new()
	for _ = 1, 5 do
		local c = Instance.new("Part")
		c.Name = "Chip"
		c.Size = Vector3.new(0.4, 0.4, 0.8) * rng:NextNumber(0.7, 1.2)
		c.Color = door.Color
		c.Material = Enum.Material.SmoothPlastic
		c.CanQuery = false
		c.CanTouch = false
		c.CFrame = door.CFrame * CFrame.new(rng:NextNumber(-1.5, 1.5), rng:NextNumber(-2, 2), 0)
		c.AssemblyLinearVelocity = door.CFrame.LookVector * rng:NextNumber(-12, 12) + Vector3.new(0, rng:NextNumber(6, 14), 0)
		c.Parent = workspace
		Debris:AddItem(c, 3)
	end
end

function DoorBreaker.toggle(door: BasePart)
	remember(door)
	local opening = door.CanCollide
	door.CanCollide = not opening
	door.Transparency = if opening then 0.8 else (original[door] :: DoorState).transparency
	local p = prompt(door)
	if p then
		p.ActionText = if opening then "Close" else "Open"
	end
end

function DoorBreaker.hit(door: BasePart): boolean
	remember(door)
	if door:GetAttribute(Names.Attr.Broken) == true then
		return false
	end
	hits[door] = (hits[door] or 0) + 1
	chips(door)
	if (hits[door] :: number) < ToolConfig.DoorHits then
		return false
	end
	hits[door] = nil
	door:SetAttribute(Names.Attr.Broken, true)
	door:SetAttribute(Names.Attr.Locked, false)
	door.CanCollide = false
	door.CanQuery = false
	door.Transparency = 1
	local p = prompt(door)
	if p then
		p.Enabled = false
	end
	return true
end

function DoorBreaker.nearestLocked(root: BasePart, reach: number): BasePart?
	local best, bestD = nil :: BasePart?, math.huge
	for _, inst in CollectionService:GetTagged(Names.Tag.Door) do
		if
			inst:IsA("BasePart")
			and inst:GetAttribute(Names.Attr.Locked) == true
			and inst:GetAttribute(Names.Attr.Broken) ~= true
			and inst:IsDescendantOf(workspace)
		then
			local to = inst.Position - root.Position
			local d = to.Magnitude
			local facing = d < 1e-3 or root.CFrame.LookVector:Dot(to.Unit) > 0.3
			if d <= reach and facing and d < bestD then
				best, bestD = inst, d
			end
		end
	end
	return best
end

function DoorBreaker.reset(door: BasePart)
	local o = original[door]
	hits[door] = nil
	if not o then
		return
	end
	door:SetAttribute(Names.Attr.Broken, false)
	door:SetAttribute(Names.Attr.Locked, o.locked)
	door.CanCollide = true
	door.CanQuery = true
	door.Transparency = o.transparency
	local p = prompt(door)
	if p then
		p.Enabled = true
		p.ActionText = o.actionText
	end
end

return DoorBreaker
```

- [ ] **Step 4: Replace ToolService (full file, now with the axe and doors)**

`game/ServerScriptService/Services/ToolService.luau`:

```lua
--!strict
-- ToolService [owner: G1]. Loadout (Hose, Axe), backpack water tank, hose spray, refills, doors.
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   ToolService:GiveLoadout(player: Player)              -- Hose + Axe, full tank
--   ToolService:Refill(player: Player, litres: number?)  -- nil = full
--   ToolService:ResetDoors(locationId: string)           -- un-break every door of a location
-- Signals: DoorBroken(player, door: BasePart), WaterUsed(player, litres: number),
--          HoseHit(sprayer: Player, victim: Player)
-- Remotes: Tool/Spray (C->S, aim: Vector3 unit, 12/s burst 4)
-- Writes: Player attrs Water, TankSize, Spraying; Door attrs Locked, Broken (via Lib/Tools/DoorBreaker)
-- Reads: Player attrs Carrying (RescueService), Downed (SquadService); prompts under parts tagged
--        Hydrant / TruckRefill / Door (one ProximityPrompt each, created by the map builders)
-- Counters: water_used, refills, doors_broken
-- Test hooks (DevHook only): _spray(player, aim), _swing(player), _doorPrompt(player, door), _selftest()

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local ToolConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ToolConfig") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local DoorBreaker = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Tools"):WaitForChild("DoorBreaker") :: ModuleScript)

local ToolService = {}
ToolService.Priority = 50
ToolService.DoorBroken = Signal.new() :: Signal.Signal<Player, BasePart>
ToolService.WaterUsed = Signal.new() :: Signal.Signal<Player, number>
ToolService.HoseHit = Signal.new() :: Signal.Signal<Player, Player>

local services: { [string]: any } = {}
local lastSpray: { [Player]: number } = {}
local lastSwing: { [Player]: number } = {}
local hooked: { [ProximityPrompt]: true } = {}

local swing: (player: Player) -> () -- defined in the doors section below; the Axe tool calls it

-- tools ------------------------------------------------------------------------------------
local function toolPart(name: string, size: Vector3, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	return p
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = a
end

local function makeHose(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Hose"
	tool.ToolTip = "Hold click to spray"
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	-- handle runs along Z; the nozzle points down -Z (forward from the hand)
	local handle = toolPart("Handle", Vector3.new(0.6, 0.6, 2.4), Palette.HoseYellow)
	handle.Parent = tool
	local tip = toolPart("Tip", Vector3.new(0.75, 0.75, 0.6), Palette.BrassCoupling)
	tip.CFrame = handle.CFrame * CFrame.new(0, 0, -1.5)
	tip.Parent = tool
	weld(handle, tip)
	local nozzle = Instance.new("Attachment")
	nozzle.Name = "Nozzle"
	nozzle.Position = Vector3.new(0, 0, -1.9)
	nozzle.Parent = handle
	-- hand holds the back half; tune this in the screen_capture check if the nozzle doesn't point forward
	tool.Grip = CFrame.new(0, 0, 0.6)
	return tool
end

local function makeAxe(player: Player): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Axe"
	tool.ToolTip = "Click to break locked doors"
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	local handle = toolPart("Handle", Vector3.new(0.4, 3.2, 0.4), Palette.BookshelfWood)
	handle.Parent = tool
	local head = toolPart("Head", Vector3.new(0.3, 0.9, 1.4), Palette.TruckChrome)
	head.CFrame = handle.CFrame * CFrame.new(0, 1.3, -0.5)
	head.Parent = tool
	weld(handle, head)
	local back = toolPart("Back", Vector3.new(0.35, 0.5, 0.5), Palette.HelmetRed)
	back.CFrame = handle.CFrame * CFrame.new(0, 1.3, 0.35)
	back.Parent = tool
	weld(handle, back)
	tool.Grip = CFrame.new(0, -1, 0)
	-- Tool.Activated fires on the server too, so the axe needs no remote
	tool.Activated:Connect(function()
		swing(player)
	end)
	return tool
end

local function removeTools(player: Player)
	for _, holder in { player:FindFirstChildOfClass("Backpack"), player.Character } do
		if holder then
			for _, name in { "Hose", "Axe" } do
				local t = holder:FindFirstChild(name)
				if t and t:IsA("Tool") then
					t:Destroy()
				end
			end
		end
	end
end

-- spray ------------------------------------------------------------------------------------
local function blocked(player: Player): boolean
	local carrying = (player:GetAttribute(Names.Attr.Carrying) :: string?) or ""
	return carrying ~= "" or player:GetAttribute(Names.Attr.Downed) == true
end

local function markSpraying(player: Player)
	local now = os.clock()
	lastSpray[player] = now
	player:SetAttribute(Names.Attr.Spraying, true)
	task.delay(ToolConfig.SprayingClearSeconds + 0.05, function()
		if lastSpray[player] == now and player.Parent then
			player:SetAttribute(Names.Attr.Spraying, false)
		end
	end)
end

local function sprayOnce(player: Player, aim: Vector3)
	local char = player.Character
	if not char or not char:FindFirstChild("Hose") or blocked(player) then
		return
	end
	local head = char:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end
	local water = (player:GetAttribute(Names.Attr.Water) :: number?) or 0
	local litres = math.min(water, ToolConfig.LitresPerSpray)
	if litres <= 0 then
		return
	end
	player:SetAttribute(Names.Attr.Water, water - litres)
	Telemetry.count("water_used", litres)
	ToolService.WaterUsed:Fire(player, litres)
	markSpraying(player)
	local Fire = services.FireService
	if Fire then
		Fire:ApplyWater(player, head.Position, aim, litres)
	end
end

-- prompts ----------------------------------------------------------------------------------
-- Every Hydrant / TruckRefill / Door part has exactly one ProximityPrompt made by its builder.
local function hookPrompt(part: Instance, onTrigger: (Player, BasePart) -> ())
	if not part:IsA("BasePart") then
		return
	end
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if not prompt or hooked[prompt] then
		return
	end
	hooked[prompt] = true
	prompt.Triggered:Connect(function(player: Player)
		onTrigger(player, part :: BasePart)
	end)
	prompt.Destroying:Connect(function()
		hooked[prompt] = nil
	end)
end

local function watchTag(tag: string, onTrigger: (Player, BasePart) -> ())
	CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst: Instance)
		task.defer(hookPrompt, inst, onTrigger) -- builders add the prompt right after the tag
	end)
	for _, inst in CollectionService:GetTagged(tag) do
		hookPrompt(inst, onTrigger)
	end
end

-- doors ------------------------------------------------------------------------------------
local function breakHit(player: Player, door: BasePart)
	local now = os.clock()
	if now - (lastSwing[player] or 0) < ToolConfig.AxeCooldown then
		return
	end
	lastSwing[player] = now
	if DoorBreaker.hit(door) then
		Telemetry.count("doors_broken")
		ToolService.DoorBroken:Fire(player, door)
		Net.notify(player, "CRACK! Door down", "good")
	end
end

swing = function(player: Player)
	local char = player.Character
	if not char or not char:FindFirstChild("Axe") or blocked(player) then
		return
	end
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local door = root and DoorBreaker.nearestLocked(root, ToolConfig.AxeReach)
	if door then
		breakHit(player, door)
	end
end

local function onDoorPrompt(player: Player, door: BasePart)
	if door:GetAttribute(Names.Attr.Broken) == true then
		return
	end
	if door:GetAttribute(Names.Attr.Locked) ~= true then
		DoorBreaker.toggle(door)
		return
	end
	local char = player.Character
	if char and char:FindFirstChild("Axe") and not blocked(player) then
		breakHit(player, door)
	else
		Net.notify(player, "Locked! Use the axe", "info")
	end
end

-- service ----------------------------------------------------------------------------------
function ToolService:Init(all: { [string]: any })
	services = all
end

function ToolService:Start()
	local Spray = Net.event("Tool", "Spray")
	Net.onServer(Spray, { rate = 12, burst = 4 }, function(player: Player, rawAim: any)
		local aim = Net.unit(rawAim)
		if aim then
			sprayOnce(player, aim)
		end
	end)
	local function refill(player: Player, _part: BasePart)
		ToolService:Refill(player, nil)
	end
	watchTag(Names.Tag.Hydrant, refill)
	watchTag(Names.Tag.TruckRefill, refill)
	watchTag(Names.Tag.Door, onDoorPrompt)
	Players.PlayerRemoving:Connect(function(player: Player)
		lastSpray[player] = nil
		lastSwing[player] = nil
	end)
end

function ToolService:GiveLoadout(player: Player)
	removeTools(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		makeHose().Parent = backpack
		makeAxe(player).Parent = backpack
	end
	player:SetAttribute(Names.Attr.TankSize, ToolConfig.TankSize)
	player:SetAttribute(Names.Attr.Water, ToolConfig.TankSize)
	player:SetAttribute(Names.Attr.Spraying, false)
end

function ToolService:Refill(player: Player, litres: number?)
	local size = (player:GetAttribute(Names.Attr.TankSize) :: number?) or ToolConfig.TankSize
	local water = (player:GetAttribute(Names.Attr.Water) :: number?) or 0
	local new = math.min(size, water + (litres or size))
	player:SetAttribute(Names.Attr.TankSize, size)
	player:SetAttribute(Names.Attr.Water, new)
	Telemetry.count("refills")
	if new >= size then
		Net.notify(player, "Tank full!", "good")
	end
end

function ToolService:ResetDoors(locationId: string)
	local Map = services.MapService
	local model = Map and Map:GetLocation(locationId)
	if not model then
		return
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and CollectionService:HasTag(d, Names.Tag.Door) then
			DoorBreaker.reset(d)
		end
	end
end

-- test hooks -------------------------------------------------------------------------------
function ToolService:_spray(player: Player, aim: Vector3)
	sprayOnce(player, aim.Unit)
end

function ToolService:_swing(player: Player)
	lastSwing[player] = nil -- tests may swing faster than AxeCooldown
	swing(player)
end

function ToolService:_doorPrompt(player: Player, door: BasePart)
	lastSwing[player] = nil
	onDoorPrompt(player, door)
end

function ToolService:_selftest(): (boolean, string)
	local net = ReplicatedStorage:FindFirstChild("Net")
	local ns = net and net:FindFirstChild("Tool")
	if not (ns and ns:FindFirstChild("Spray")) then
		return false, "Tool/Spray remote missing"
	end
	local hose = makeHose()
	local ok = hose:FindFirstChild("Handle") ~= nil and (hose :: any).Handle:FindFirstChild("Nozzle") ~= nil
	hose:Destroy()
	if not ok then
		return false, "Hose has no Handle.Nozzle"
	end
	return true, "ok"
end

return ToolService
```

- [ ] **Step 5: Compile check**

Run: `python3 game/tools/sync.py check --root game` → `OK: checked <N> files, 0 failed`

- [ ] **Step 6: Live check (it passes now)**

Expected JSON:
- `"aBroken":true`, `"aLocked":false`, `"aCollide":false`: three `_swing` hits on the nearest locked door in front.
- `"bBroken":true`: three prompt triggers with the Axe equipped.
- `"openCollide":false` and `"openText":"Close"`: the unlocked door toggled open.
- Counters: `doors_broken` = 2.
- `"errors":[]`.

Then, by hand in Play, unequip the axe (press 2 again) and trigger a locked door's prompt. Once G3's HudController is in,
the toast "Locked! Use the axe" shows.

**Integration point (G2 Town):** House2's interior door (the panda room) and House4's front door are locked
`MapKit.door`s. In a real round, swinging the axe at one (click) breaks it in 3 hits.
**Integration point (G3 BlameService):** `DoorBroken` feeds `PlayerStats.doors`, which drives the "Door Hater" award.

- [ ] **Step 7: Commit and open the PR**

```bash
git add game/ServerScriptService/Lib/Tools/DoorBreaker.luau game/ServerScriptService/Services/ToolService.luau
git commit -m "game(tools): axe breaks locked doors in 3 hits, unlocked doors open/close"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

---

### Task G1.7: Friendly-fire hose, which pushes teammates and fires HoseHit (Dev B, G1, 1.0 h, P1.5)

**Files:**
- Modify: `game/ServerScriptService/Services/ToolService.luau` (full new version below)
- Modify: `game/StarterPlayerScripts/Controllers/ToolController.luau` (full new version below)

**Interfaces:**
- Consumes: `FireSim.inCone` (G1.1); `ToolConfig.HoseHitRange/HoseHitCos/HosePush/HoseHitCooldown`.
- Produces: `ToolService.HoseHit: Signal<Player, Player>` (sprayer, victim), at most once per pair per 0.5 s. G3's
  BlameService counts it into `PlayerStats.teammateSprayed` (the "Friendly Fire Department" award), and G3's kill-feed
  may toast it. Counter `hose_teammate_hits`. New G1-internal remote `Tool/Pushed` (S→C, victim only,
  `velocity: Vector3`): the victim's client owns its physics, so the push is applied in ToolController. **This is a
  contract addition. Add it to the §10 remotes table in the same PR.**

- [ ] **Step 1: Branch and write the checks**

```bash
git switch main && git pull --rebase && git switch -c g1/friendly-hose
```

Solo check (Server): the remote exists and solo spraying never counts a teammate hit:

```lua
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local DevHook = game.ServerStorage.DevHook
local t0 = os.clock()
repeat task.wait(0.25) until (Players:GetPlayers()[1] and Players:GetPlayers()[1].Character) or os.clock() - t0 > 15
local player = Players:GetPlayers()[1]
DevHook:Invoke("ToolService", "GiveLoadout", player)
player.Character:WaitForChild("Humanoid"):EquipTool(player.Backpack:WaitForChild("Hose", 5))
task.wait(0.3)
for _ = 1, 5 do
	DevHook:Invoke("ToolService", "_spray", player, player.Character.Head.CFrame.LookVector)
	task.wait(0.1)
end
local r = HttpService:JSONDecode(game.ServerStorage.ForgeProbe:Invoke("report"))
return HttpService:JSONEncode({
	pushed = game.ReplicatedStorage.Net.Tool:FindFirstChild("Pushed") ~= nil,
	hits = r.counters.hose_teammate_hits or 0, errors = r.errors,
})
```

Two-player check (manual; the MCP `start_stop_play` only runs solo):
1. In Studio, open the Test tab, set Clients and Servers to 2 players, and press Start.
2. In Player1's window, press 1 to equip the Hose, then look at Player2 from about 10 studs and hold the left mouse button
   for 2 s.
3. In the Server window's command bar (or `execute_luau` in the `Server` datamodel of that test session), run
   `return game.ServerStorage.ForgeProbe:Invoke("report")`.

- [ ] **Step 2: Run against G1.6's ToolService and confirm it fails**

Expected (FAIL): the solo check returns `"pushed":false`. In the two-player check, Player2 doesn't move and
`hose_teammate_hits` is absent.

- [ ] **Step 3: Replace ToolService (full file, now with friendly fire)**

`game/ServerScriptService/Services/ToolService.luau`:

```lua
--!strict
-- ToolService [owner: G1]. Loadout (Hose, Axe), backpack water tank, hose spray, refills, doors,
-- friendly fire (the hose pushes teammates and reports HoseHit for the Blame awards).
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   ToolService:GiveLoadout(player: Player)              -- Hose + Axe, full tank
--   ToolService:Refill(player: Player, litres: number?)  -- nil = full
--   ToolService:ResetDoors(locationId: string)           -- un-break every door of a location
-- Signals: DoorBroken(player, door: BasePart), WaterUsed(player, litres: number),
--          HoseHit(sprayer: Player, victim: Player)
-- Remotes: Tool/Spray (C->S, aim: Vector3 unit, 12/s burst 4)
--          Tool/Pushed (S->C victim only, velocity: Vector3) -- the victim's client owns its physics,
--          so the push is applied there (ToolController)
-- Writes: Player attrs Water, TankSize, Spraying; Door attrs Locked, Broken (via Lib/Tools/DoorBreaker)
-- Reads: Player attrs Carrying (RescueService), Downed (SquadService); prompts under parts tagged
--        Hydrant / TruckRefill / Door (one ProximityPrompt each, created by the map builders)
-- Counters: water_used, refills, doors_broken, hose_teammate_hits
-- Test hooks (DevHook only): _spray(player, aim), _swing(player), _doorPrompt(player, door), _selftest()

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local ToolConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ToolConfig") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local DoorBreaker = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Tools"):WaitForChild("DoorBreaker") :: ModuleScript)
local FireSim = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Fire"):WaitForChild("FireSim") :: ModuleScript)

local ToolService = {}
ToolService.Priority = 50
ToolService.DoorBroken = Signal.new() :: Signal.Signal<Player, BasePart>
ToolService.WaterUsed = Signal.new() :: Signal.Signal<Player, number>
ToolService.HoseHit = Signal.new() :: Signal.Signal<Player, Player>

local services: { [string]: any } = {}
local lastSpray: { [Player]: number } = {}
local lastSwing: { [Player]: number } = {}
local lastHit: { [string]: number } = {} -- "<sprayerId>:<victimId>" -> os.clock()
local Pushed: RemoteEvent? = nil
local hooked: { [ProximityPrompt]: true } = {}

local swing: (player: Player) -> () -- defined in the doors section below; the Axe tool calls it

-- tools ------------------------------------------------------------------------------------
local function toolPart(name: string, size: Vector3, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	return p
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = a
end

local function makeHose(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Hose"
	tool.ToolTip = "Hold click to spray"
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	-- handle runs along Z; the nozzle points down -Z (forward from the hand)
	local handle = toolPart("Handle", Vector3.new(0.6, 0.6, 2.4), Palette.HoseYellow)
	handle.Parent = tool
	local tip = toolPart("Tip", Vector3.new(0.75, 0.75, 0.6), Palette.BrassCoupling)
	tip.CFrame = handle.CFrame * CFrame.new(0, 0, -1.5)
	tip.Parent = tool
	weld(handle, tip)
	local nozzle = Instance.new("Attachment")
	nozzle.Name = "Nozzle"
	nozzle.Position = Vector3.new(0, 0, -1.9)
	nozzle.Parent = handle
	-- hand holds the back half; tune this in the screen_capture check if the nozzle doesn't point forward
	tool.Grip = CFrame.new(0, 0, 0.6)
	return tool
end

local function makeAxe(player: Player): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Axe"
	tool.ToolTip = "Click to break locked doors"
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	local handle = toolPart("Handle", Vector3.new(0.4, 3.2, 0.4), Palette.BookshelfWood)
	handle.Parent = tool
	local head = toolPart("Head", Vector3.new(0.3, 0.9, 1.4), Palette.TruckChrome)
	head.CFrame = handle.CFrame * CFrame.new(0, 1.3, -0.5)
	head.Parent = tool
	weld(handle, head)
	local back = toolPart("Back", Vector3.new(0.35, 0.5, 0.5), Palette.HelmetRed)
	back.CFrame = handle.CFrame * CFrame.new(0, 1.3, 0.35)
	back.Parent = tool
	weld(handle, back)
	tool.Grip = CFrame.new(0, -1, 0)
	-- Tool.Activated fires on the server too, so the axe needs no remote
	tool.Activated:Connect(function()
		swing(player)
	end)
	return tool
end

local function removeTools(player: Player)
	for _, holder in { player:FindFirstChildOfClass("Backpack"), player.Character } do
		if holder then
			for _, name in { "Hose", "Axe" } do
				local t = holder:FindFirstChild(name)
				if t and t:IsA("Tool") then
					t:Destroy()
				end
			end
		end
	end
end

-- spray ------------------------------------------------------------------------------------
local function blocked(player: Player): boolean
	local carrying = (player:GetAttribute(Names.Attr.Carrying) :: string?) or ""
	return carrying ~= "" or player:GetAttribute(Names.Attr.Downed) == true
end

local function markSpraying(player: Player)
	local now = os.clock()
	lastSpray[player] = now
	player:SetAttribute(Names.Attr.Spraying, true)
	task.delay(ToolConfig.SprayingClearSeconds + 0.05, function()
		if lastSpray[player] == now and player.Parent then
			player:SetAttribute(Names.Attr.Spraying, false)
		end
	end)
end

-- Teammates inside the (narrower) hit cone get pushed along the spray and reported once per
-- HoseHitCooldown. Same cone maths as fire (FireSim.inCone), no raycasts.
local function hitTeammates(sprayer: Player, origin: Vector3, aim: Vector3)
	local now = os.clock()
	for _, victim in Players:GetPlayers() do
		if victim ~= sprayer then
			local vchar = victim.Character
			local root = vchar and vchar:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				local d = root.Position - origin
				if FireSim.inCone(d.X, d.Y, d.Z, aim.X, aim.Y, aim.Z, ToolConfig.HoseHitRange, ToolConfig.HoseHitCos) then
					local key = `{sprayer.UserId}:{victim.UserId}`
					if now - (lastHit[key] or 0) >= ToolConfig.HoseHitCooldown then
						lastHit[key] = now
						local push = Vector3.new(aim.X, 0, aim.Z)
						if push.Magnitude > 1e-3 then
							push = push.Unit * ToolConfig.HosePush + Vector3.new(0, ToolConfig.HosePush * 0.25, 0)
							if Pushed then
								Pushed:FireClient(victim, push)
							end
						end
						Telemetry.count("hose_teammate_hits")
						ToolService.HoseHit:Fire(sprayer, victim)
					end
				end
			end
		end
	end
end

local function sprayOnce(player: Player, aim: Vector3)
	local char = player.Character
	if not char or not char:FindFirstChild("Hose") or blocked(player) then
		return
	end
	local head = char:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end
	local water = (player:GetAttribute(Names.Attr.Water) :: number?) or 0
	local litres = math.min(water, ToolConfig.LitresPerSpray)
	if litres <= 0 then
		return
	end
	player:SetAttribute(Names.Attr.Water, water - litres)
	Telemetry.count("water_used", litres)
	ToolService.WaterUsed:Fire(player, litres)
	markSpraying(player)
	local Fire = services.FireService
	if Fire then
		Fire:ApplyWater(player, head.Position, aim, litres)
	end
	hitTeammates(player, head.Position, aim)
end

-- prompts ----------------------------------------------------------------------------------
-- Every Hydrant / TruckRefill / Door part has exactly one ProximityPrompt made by its builder.
local function hookPrompt(part: Instance, onTrigger: (Player, BasePart) -> ())
	if not part:IsA("BasePart") then
		return
	end
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if not prompt or hooked[prompt] then
		return
	end
	hooked[prompt] = true
	prompt.Triggered:Connect(function(player: Player)
		onTrigger(player, part :: BasePart)
	end)
	prompt.Destroying:Connect(function()
		hooked[prompt] = nil
	end)
end

local function watchTag(tag: string, onTrigger: (Player, BasePart) -> ())
	CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst: Instance)
		task.defer(hookPrompt, inst, onTrigger) -- builders add the prompt right after the tag
	end)
	for _, inst in CollectionService:GetTagged(tag) do
		hookPrompt(inst, onTrigger)
	end
end

-- doors ------------------------------------------------------------------------------------
local function breakHit(player: Player, door: BasePart)
	local now = os.clock()
	if now - (lastSwing[player] or 0) < ToolConfig.AxeCooldown then
		return
	end
	lastSwing[player] = now
	if DoorBreaker.hit(door) then
		Telemetry.count("doors_broken")
		ToolService.DoorBroken:Fire(player, door)
		Net.notify(player, "CRACK! Door down", "good")
	end
end

swing = function(player: Player)
	local char = player.Character
	if not char or not char:FindFirstChild("Axe") or blocked(player) then
		return
	end
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local door = root and DoorBreaker.nearestLocked(root, ToolConfig.AxeReach)
	if door then
		breakHit(player, door)
	end
end

local function onDoorPrompt(player: Player, door: BasePart)
	if door:GetAttribute(Names.Attr.Broken) == true then
		return
	end
	if door:GetAttribute(Names.Attr.Locked) ~= true then
		DoorBreaker.toggle(door)
		return
	end
	local char = player.Character
	if char and char:FindFirstChild("Axe") and not blocked(player) then
		breakHit(player, door)
	else
		Net.notify(player, "Locked! Use the axe", "info")
	end
end

-- service ----------------------------------------------------------------------------------
function ToolService:Init(all: { [string]: any })
	services = all
end

function ToolService:Start()
	Pushed = Net.event("Tool", "Pushed")
	local Spray = Net.event("Tool", "Spray")
	Net.onServer(Spray, { rate = 12, burst = 4 }, function(player: Player, rawAim: any)
		local aim = Net.unit(rawAim)
		if aim then
			sprayOnce(player, aim)
		end
	end)
	local function refill(player: Player, _part: BasePart)
		ToolService:Refill(player, nil)
	end
	watchTag(Names.Tag.Hydrant, refill)
	watchTag(Names.Tag.TruckRefill, refill)
	watchTag(Names.Tag.Door, onDoorPrompt)
	Players.PlayerRemoving:Connect(function(player: Player)
		lastSpray[player] = nil
		lastSwing[player] = nil
		local id = tostring(player.UserId)
		for key in lastHit do
			local a, b = string.match(key, "^(%d+):(%d+)$")
			if a == id or b == id then
				lastHit[key] = nil
			end
		end
	end)
end

function ToolService:GiveLoadout(player: Player)
	removeTools(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		makeHose().Parent = backpack
		makeAxe(player).Parent = backpack
	end
	player:SetAttribute(Names.Attr.TankSize, ToolConfig.TankSize)
	player:SetAttribute(Names.Attr.Water, ToolConfig.TankSize)
	player:SetAttribute(Names.Attr.Spraying, false)
end

function ToolService:Refill(player: Player, litres: number?)
	local size = (player:GetAttribute(Names.Attr.TankSize) :: number?) or ToolConfig.TankSize
	local water = (player:GetAttribute(Names.Attr.Water) :: number?) or 0
	local new = math.min(size, water + (litres or size))
	player:SetAttribute(Names.Attr.TankSize, size)
	player:SetAttribute(Names.Attr.Water, new)
	Telemetry.count("refills")
	if new >= size then
		Net.notify(player, "Tank full!", "good")
	end
end

function ToolService:ResetDoors(locationId: string)
	local Map = services.MapService
	local model = Map and Map:GetLocation(locationId)
	if not model then
		return
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and CollectionService:HasTag(d, Names.Tag.Door) then
			DoorBreaker.reset(d)
		end
	end
end

-- test hooks -------------------------------------------------------------------------------
function ToolService:_spray(player: Player, aim: Vector3)
	sprayOnce(player, aim.Unit)
end

function ToolService:_swing(player: Player)
	lastSwing[player] = nil -- tests may swing faster than AxeCooldown
	swing(player)
end

function ToolService:_doorPrompt(player: Player, door: BasePart)
	lastSwing[player] = nil
	onDoorPrompt(player, door)
end

function ToolService:_selftest(): (boolean, string)
	local net = ReplicatedStorage:FindFirstChild("Net")
	local ns = net and net:FindFirstChild("Tool")
	if not (ns and ns:FindFirstChild("Spray")) then
		return false, "Tool/Spray remote missing"
	end
	local hose = makeHose()
	local ok = hose:FindFirstChild("Handle") ~= nil and (hose :: any).Handle:FindFirstChild("Nozzle") ~= nil
	hose:Destroy()
	if not ok then
		return false, "Hose has no Handle.Nozzle"
	end
	return true, "ok"
end

return ToolService
```

- [ ] **Step 4: Replace ToolController (full file, now with the push)**

`game/StarterPlayerScripts/Controllers/ToolController.luau`:

```lua
--!strict
-- ToolController [owner: G1]. Hose input and water-stream visuals.
--   Input: while the local Hose is activated (mouse held or touch held), send Tool/Spray with the
--   camera's LookVector ToolConfig.SprayHz times a second. The server decides everything else.
--   Visuals: for EVERY player whose Spraying attr is true (and the local player while the trigger is
--   held), a ParticleEmitter stream from their Hose's Handle.Nozzle, aimed along the camera (local
--   player) or the Head's look (others). Streams live on Attachments under workspace.Terrain named
--   "HoseStream_<UserId>" so they can be re-aimed freely.
--   Pushed: Tool/Pushed (S->C) carries a velocity from a teammate's hose; this client owns its
--   character's physics, so the push is applied here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local ToolConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ToolConfig") :: ModuleScript)

type Stream = { attachment: Attachment, emitter: ParticleEmitter }

local ToolController = {}
ToolController.Priority = 50

local LocalPlayer = Players.LocalPlayer
local holding = false
local streams: { [Player]: Stream } = {}
local hookedTools: { [Tool]: true } = setmetatable({}, { __mode = "k" }) :: any

local function nozzleOf(player: Player): Attachment?
	local char = player.Character
	local hose = char and char:FindFirstChild("Hose")
	local handle = hose and hose:FindFirstChild("Handle")
	local nozzle = handle and handle:FindFirstChild("Nozzle")
	return if nozzle and nozzle:IsA("Attachment") then nozzle else nil
end

local function water(): number
	return (LocalPlayer:GetAttribute(Names.Attr.Water) :: number?) or 0
end

local function ensureStream(player: Player): Stream
	local s = streams[player]
	if s then
		return s
	end
	local a = Instance.new("Attachment")
	a.Name = `HoseStream_{player.UserId}`
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	e.EmissionDirection = Enum.NormalId.Front
	e.Color = ColorSequence.new(Palette.WaterSpray)
	e.Transparency = NumberSequence.new(0.15, 0.7)
	e.Size = NumberSequence.new(0.5, 1.4)
	e.Lifetime = NumberRange.new(0.5, 0.6)
	e.Rate = 140
	e.Speed = NumberRange.new(65, 75)
	e.SpreadAngle = Vector2.new(2.5, 2.5)
	e.Acceleration = Vector3.new(0, -55, 0)
	e.LightInfluence = 0.6
	e.LightEmission = 0.2
	e.Parent = a
	a.Parent = workspace.Terrain
	s = { attachment = a, emitter = e }
	streams[player] = s
	return s
end

local function dropStream(player: Player)
	local s = streams[player]
	if s then
		s.attachment:Destroy()
		streams[player] = nil
	end
end

-- Under ToolConfig.LowWaterFraction of the tank the stream sputters (thinner), so players look for a refill.
local function lowWater(player: Player): boolean
	local size = (player:GetAttribute(Names.Attr.TankSize) :: number?) or ToolConfig.TankSize
	local left = (player:GetAttribute(Names.Attr.Water) :: number?) or 0
	return left < size * ToolConfig.LowWaterFraction
end

local function aimOf(player: Player): Vector3?
	if player == LocalPlayer then
		local cam = workspace.CurrentCamera
		return cam and cam.CFrame.LookVector
	end
	local char = player.Character
	local head = char and char:FindFirstChild("Head") :: BasePart?
	return head and head.CFrame.LookVector
end

local function render()
	for _, player in Players:GetPlayers() do
		local nozzle = nozzleOf(player)
		local on = player:GetAttribute(Names.Attr.Spraying) == true
		if player == LocalPlayer then
			on = on or (holding and water() > 0)
		end
		local aim = aimOf(player)
		if nozzle and on and aim then
			local s = ensureStream(player)
			local from = nozzle.WorldPosition
			s.attachment.WorldCFrame = CFrame.lookAt(from, from + aim)
			s.emitter.Rate = if lowWater(player) then 50 else 140
			s.emitter.Enabled = true
		elseif streams[player] then
			streams[player].emitter.Enabled = false
		end
	end
end

-- Tool.Activated / Deactivated fire for mouse and touch alike.
local function hookTool(inst: Instance)
	if not inst:IsA("Tool") or inst.Name ~= "Hose" or hookedTools[inst] then
		return
	end
	hookedTools[inst] = true
	inst.Activated:Connect(function()
		holding = true
	end)
	inst.Deactivated:Connect(function()
		holding = false
	end)
	inst.Unequipped:Connect(function()
		holding = false
	end)
end

local function hookCharacter(char: Model)
	holding = false
	char.ChildAdded:Connect(hookTool)
	for _, child in char:GetChildren() do
		hookTool(child)
	end
end

function ToolController:Init(_controllers: { [string]: any }) end

function ToolController:Start()
	local Spray = Net.event("Tool", "Spray")
	Net.event("Tool", "Pushed").OnClientEvent:Connect(function(velocity: any)
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and typeof(velocity) == "Vector3" and velocity.Magnitude <= 100 then
			root.AssemblyLinearVelocity += velocity
		end
	end)
	LocalPlayer.CharacterAdded:Connect(hookCharacter)
	if LocalPlayer.Character then
		hookCharacter(LocalPlayer.Character)
	end
	Players.PlayerRemoving:Connect(dropStream)
	RunService.RenderStepped:Connect(render)
	while true do
		task.wait(1 / ToolConfig.SprayHz)
		local char = LocalPlayer.Character
		local cam = workspace.CurrentCamera
		if holding and cam and char and char:FindFirstChild("Hose") and water() > 0 then
			Spray:FireServer(cam.CFrame.LookVector)
		end
	end
end

return ToolController
```

- [ ] **Step 5: Compile check and specs**

Run: `python3 game/tools/sync.py check --root game` → `OK: checked <N> files, 0 failed`
Run: `bash game/tests/run.sh` → exit code 0 (FireSim.inCone is unchanged)

- [ ] **Step 6: Run both checks (they pass now)**

Expected:
- Solo: `{"pushed":true,"hits":0,"errors":[]}`.
- Two players: Player2 slides back about 35 studs/s per hit with a small hop. The Server report shows
  `hose_teammate_hits` ≥ 3: 2 s at one hit per 0.5 s gives about 4. There are no errors in either client's Output.

**Integration point (G3 BlameService plus the kill-feed):** after the two-player test,
`DevHook:Invoke("BlameService", "GetStats", <Player1>)` shows `teammateSprayed` ≥ 3, and the results screen gives
Player1 "Friendly Fire Department" once G3's Awards are in.

- [ ] **Step 7: Commit and open the PR**

```bash
git add game/ServerScriptService/Services/ToolService.luau game/StarterPlayerScripts/Controllers/ToolController.luau docs/game/03-tech-architecture.md
git commit -m "game(tools): friendly-fire hose push + HoseHit signal, Tool/Pushed remote"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

For the §10 doc edit in this PR, add one row under "Remotes":
`| Tool/Pushed | S→C (victim) | velocity: Vector3 | | ToolService | ToolController |`.

---

## Lane G2: World & truck (Dev A, Arvin)

G2 owns everything the players stand on: the map built from code (Station 67 and Maple Street), truck 67,
the lighting, and the client-side alarm and truck lights. Every other lane reads G2's **tags and
markers**, never its geometry: FireService indexes `Flammable`, MissionService lights `FireStart` and
parks the truck on `TruckSpot`, RescueService spawns NPCs on `RescueSpawn`, ToolService wires the
prompts on `Door` / `Hydrant` / `TruckRefill`, SquadService spawns players on `StationSpawn`.
Get those right first (P0). Looks come second.

Dev A starts G2 right after Task 0 merges (Fri ~21:45). Order: G2.1 → G2.2 → G2.3 → G2.4 → G2.5 (P0, by
Sat 10:00), G2.6 (P1, by Sat 14:00), G2.7 (P1.5, by Sat 18:00). Dev A is also integration lead, so the
lane is kept to about 6.5 hours.

**Already in the repo working tree (uncommitted, written by Dev A):**
`game/ServerScriptService/Lib/Map/Props/TruckBuilder.luau`,
`game/ServerScriptService/Services/AtmosphereService.luau` and `game/ReplicatedStorage/Config/AtmosphereConfig.luau`.
This plan does **not** rewrite them. G2.4 reviews and commits them as they are, and VehicleService (G2.5)
calls `TruckBuilder.Build` unchanged. Lighting comes from AtmosphereService, so there is no LightingKit.

Shared conventions for every G2 task:
- Develop in your local place: `forge place --open`, then `forge watch --studio Forge` (leave it running;
  every save is compile-checked and pushed; edits made during a playtest are queued until Stop).
- `<id>` below = the `id` of **your local place** from `mcp__Roblox_Studio__list_roblox_studios` (name contains
  `Forge`, **never** one whose name shows a `placeId`, which is the shared "Firefighter Mubit" place).
- Every live check ends with `mcp__Roblox_Studio__start_stop_play {"is_start": false, "studio_id": "<id>"}`,
  even after a failure. Edit-mode previews always destroy what they built (Edit Workspace must stay clean).
- Compile check: `python3 game/tools/sync.py check --root game` → `OK: checked N files, 0 failed`.
- PR: `git push -u origin HEAD && gh pr create --fill`, then `gh pr merge --squash --delete-branch` once CI is
  green. Paste the probe `counters` line into the PR description.

---

### Task G2.1: MapKit fixes and helpers  (Dev A, G2, 1.0 h, P0)

**Files:**
- Modify: `game/ServerScriptService/Lib/Map/MapKit.luau` (full replacement below)

**Interfaces:**
- Consumes: `Shared/Names` (`Tag.Flammable`, `Tag.Door`, `Tag.Window`, `Tag.Hydrant`, `Attr.Fuel`, `Attr.Locked`,
  `Attr.Broken`), `Shared/Palette` (Task 0).
- Produces (used by G2.2, G2.3, G2.7, TruckBuilder, and any GF builder; G3's NpcBuilder may call
  `MapKit.part` / `MapKit.googlyEyes` read-only):
  `MapKit.part(parent, name, cf, size, opts?): Part`, `MapKit.box(parent, name, cf, size, color, flammable?, fuel?): Part`,
  `MapKit.marker(parent, name, cf, size, tag, attrs?): Part`, `MapKit.slab(...)`,
  `MapKit.wall(parent, name, origin, a, b, h, opts?): { Part }`,
  `MapKit.wallWithDoorway(parent, name, origin, a, b, h, doorAt, doorW, doorH, opts?): ({ Part }, CFrame)`,
  `MapKit.roof(parent, name, origin, w, d, y, opts?): { Part }`, `MapKit.door(parent, name, cf, locked): Part`,
  `MapKit.window(parent, name, cf): Part`, `MapKit.hydrant(parent, cf): Model`, `MapKit.tree(parent, cf): Model`,
  `MapKit.lamp(parent, cf): Model`, `MapKit.label(part, face, text, color?): SurfaceGui`,
  `MapKit.billboard(part, text, color, offsetY?): BillboardGui` (named `"Hint"`), `MapKit.googlyEyes`, `MapKit.pick`,
  `MapKit.hash`, `MapKit.PartOpts` (type).

Two bugs in the committed MapKit:
1. `MapKit.wall` builds `rot = CFrame.lookAt(0, (dir.Z, 0, -dir.X))`. Its LookVector is perpendicular to the
   wall, so its RightVector (local X) is `look × up = (dir.X, 0, dir.Z) = dir`: local X runs **along** the wall.
   The committed size `Vector3.new(t, h, len / n)` puts the 1-stud thickness along the wall and the length
   across it, so every wall renders as a comb of thin fins. Correct size: `Vector3.new(len / n, h, t)`.
2. `MapKit.hydrant` body is a Cylinder, whose length is its X size. `Vector3.new(1.4, 3, 1.4)` gives a
   1.4-stud stub. Correct: `Vector3.new(3, 1.4, 1.4)` rotated 90° about Z (X → up).

- [ ] **Step 1: Branch, start Studio sync**

```bash
git switch main && git pull --rebase && git switch -c g2/mapkit
.venv/bin/forge place --open          # once; then in another terminal:
.venv/bin/forge watch --studio Forge
```

- [ ] **Step 2: Write the failing check (Edit mode, no Play needed)**

`mcp__Roblox_Studio__execute_luau` with `{"datamodel_type": "Edit", "studio_id": "<id>", "code": ...}`:

```lua
local MapKit = require(game.ServerScriptService.Lib.Map.MapKit)
local m = Instance.new("Model") -- never parented: nothing leaks into Edit Workspace
local parts = MapKit.wall(m, "W", CFrame.new(), Vector3.new(0, 0, 0), Vector3.new(24, 0, 0), 11)
local p = parts[1]
local h = MapKit.hydrant(m, CFrame.new())
local out = string.format("chunks=%d size=%s right=%s body=%s flammable=%s",
	#parts, tostring(p.Size), tostring(p.CFrame.RightVector), tostring((h:FindFirstChild("Body") :: BasePart).Size),
	tostring(p:HasTag("Flammable")))
m:Destroy()
return out
```

- [ ] **Step 3: Run it, expect FAIL**

Expected with the committed MapKit: `chunks=3 size=1, 11, 8 right=1, 0, 0 body=1.4, 3, 1.4 flammable=true`. The
wall chunk is 1 stud along its RightVector (1, 0, 0), which is the bug.

- [ ] **Step 4: Replace `game/ServerScriptService/Lib/Map/MapKit.luau` with:**

```lua
--!strict
-- MapKit [owner: G2]. The only part helpers builders use. Everything is Anchored and built under an
-- unparented Model (MapService parents it once). Large flammable surfaces are split into <= 8-stud
-- chunks so fire stays local. Style: chunky low-poly, SmoothPlastic, Palette colours (docs/game/02).
--
-- API (all positions are LOCAL to `origin` unless a full CFrame `cf` is asked for):
--   MapKit.part(parent, name, cf, size, opts?): Part
--   MapKit.box(parent, name, cf, size, color, flammable?, fuel?): Part      furniture / props
--   MapKit.marker(parent, name, cf, size, tag, attrs?): Part                invisible, no collide/query/touch
--   MapKit.slab(parent, name, origin, size, color?): Part                   top surface at origin.Y
--   MapKit.wall(parent, name, origin, a, b, h, opts?): { Part }            <= 8-stud chunks along a->b
--   MapKit.wallWithDoorway(parent, name, origin, a, b, h, doorAt, doorW, doorH, opts?): ({ Part }, CFrame)
--   MapKit.roof(parent, name, origin, w, d, y, opts?): { Part }            flat, <= 8x8 chunks
--   MapKit.door(parent, name, cf, locked): Part                             tag Door + ProximityPrompt
--   MapKit.window(parent, name, cf): Part                                   tag Window
--   MapKit.hydrant(parent, cf): Model                                       Body tagged Hydrant + prompt
--   MapKit.tree(parent, cf): Model    MapKit.lamp(parent, cf): Model
--   MapKit.label(part, face, text, color?): SurfaceGui
--   MapKit.billboard(part, text, color, offsetY?): BillboardGui            name "Hint"
--   MapKit.googlyEyes(parent, cf, size, gap?)    MapKit.pick(rng, list)    MapKit.hash(s)
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)

local MapKit = {}

MapKit.WarmColors = { Palette.SidingCream, Palette.SidingSalmon, Palette.SidingSage, Palette.SidingBlue }
MapKit.Red = Palette.TruckRed
MapKit.White = Palette.TrimWhite
MapKit.Black = Palette.Pupil
MapKit.Wood = Palette.BookshelfWood
MapKit.Grass = Palette.LawnGreen
MapKit.Asphalt = Palette.Asphalt
MapKit.Concrete = Palette.Sidewalk

export type PartOpts = {
	color: Color3?,
	material: Enum.Material?,
	shape: Enum.PartType?,
	transparency: number?,
	collide: boolean?,
	flammable: boolean?,
	fuel: number?,
	tags: { string }?,
	neon: boolean?,
}

-- One anchored part at `cf` with `size`, parented to `parent`.
function MapKit.part(parent: Instance, name: string, cf: CFrame, size: Vector3, opts: PartOpts?): Part
	local o = opts or {} :: PartOpts
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanTouch = false
	if o.shape then
		p.Shape = o.shape
	end
	p.Size = size
	p.CFrame = cf
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = if o.neon then Enum.Material.Neon else (o.material or Enum.Material.SmoothPlastic)
	p.Color = o.color or MapKit.Concrete
	p.Transparency = o.transparency or 0
	p.CanCollide = if o.collide == nil then true else o.collide
	if o.flammable then
		CollectionService:AddTag(p, Names.Tag.Flammable)
		if o.fuel then
			p:SetAttribute(Names.Attr.Fuel, o.fuel)
		end
	end
	for _, t in o.tags or {} do
		CollectionService:AddTag(p, t)
	end
	p.Parent = parent
	return p
end

-- Furniture or prop block. Flammable ones get an optional Fuel (seconds of burning).
function MapKit.box(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, flammable: boolean?, fuel: number?): Part
	return MapKit.part(parent, name, cf, size, { color = color, flammable = flammable == true, fuel = fuel })
end

-- Invisible marker part (spawn points, TruckSpot): no collision, no queries, no touch.
function MapKit.marker(parent: Instance, name: string, cf: CFrame, size: Vector3, tag: string, attrs: { [string]: any }?): Part
	local p = MapKit.part(parent, name, cf, size, { transparency = 1, collide = false, tags = { tag } })
	p.CanQuery = false
	for k, v in attrs or {} do
		p:SetAttribute(k, v)
	end
	return p
end

-- Ground slab: top surface at origin's Y.
function MapKit.slab(parent: Instance, name: string, origin: CFrame, size: Vector3, color: Color3?): Part
	return MapKit.part(parent, name, origin * CFrame.new(0, -size.Y / 2, 0), size, { color = color or MapKit.Grass })
end

-- A wall from local point a to b (on the XZ plane of `origin`, Y = bottom of the wall), height h,
-- thickness 1. Split into <= 8-stud chunks; flammable unless opts.flammable == false.
-- Orientation: rot's LookVector is perpendicular to the wall, so its RightVector (local X) runs ALONG
-- the wall: chunk size is (length, h, thickness).
function MapKit.wall(parent: Instance, name: string, origin: CFrame, a: Vector3, b: Vector3, h: number, opts: PartOpts?): { Part }
	local o = table.clone(opts or {} :: any) :: PartOpts
	if o.flammable == nil then
		o.flammable = true
	end
	local t = 1
	local d = b - a
	local len = d.Magnitude
	local n = math.max(1, math.ceil(len / 8))
	local out = {}
	local dir = d.Unit
	local rot = CFrame.lookAt(Vector3.zero, Vector3.new(dir.Z, 0, -dir.X))
	for i = 1, n do
		local mid = a + dir * ((i - 0.5) * len / n)
		local cf = origin * CFrame.new(mid.X, mid.Y + h / 2, mid.Z) * rot
		table.insert(out, MapKit.part(parent, `{name}_{i}`, cf, Vector3.new(len / n, h, t), o))
	end
	return out
end

-- A wall a->b with one doorway gap centred `doorAt` studs from a (width doorW, height doorH) and a
-- lintel above it. Returns the wall chunks and the CFrame of the gap centre (local X along the wall,
-- Y at doorH/2), which is exactly where MapKit.door(...) goes for a locked/closed door.
function MapKit.wallWithDoorway(
	parent: Instance,
	name: string,
	origin: CFrame,
	a: Vector3,
	b: Vector3,
	h: number,
	doorAt: number,
	doorW: number,
	doorH: number,
	opts: PartOpts?
): ({ Part }, CFrame)
	local d = b - a
	local len = d.Magnitude
	local dir = d.Unit
	local g0 = doorAt - doorW / 2
	local g1 = doorAt + doorW / 2
	local out: { Part } = {}
	local function add(list: { Part })
		for _, p in list do
			table.insert(out, p)
		end
	end
	if g0 > 0.05 then
		add(MapKit.wall(parent, `{name}_A`, origin, a, a + dir * g0, h, opts))
	end
	if len - g1 > 0.05 then
		add(MapKit.wall(parent, `{name}_B`, origin, a + dir * g1, b, h, opts))
	end
	if h - doorH > 0.05 then
		local up = Vector3.new(0, doorH, 0)
		add(MapKit.wall(parent, `{name}_Top`, origin, a + dir * g0 + up, a + dir * g1 + up, h - doorH, opts))
	end
	local mid = a + dir * doorAt
	local rot = CFrame.lookAt(Vector3.zero, Vector3.new(dir.Z, 0, -dir.X))
	return out, origin * CFrame.new(mid.X, mid.Y + doorH / 2, mid.Z) * rot
end

-- Flat roof w (local X) by d (local Z) whose underside is at height y, 1 stud thick, in <= 8x8 chunks.
-- Flammable unless opts.flammable == false.
function MapKit.roof(parent: Instance, name: string, origin: CFrame, w: number, d: number, y: number, opts: PartOpts?): { Part }
	local o = table.clone(opts or {} :: any) :: PartOpts
	if o.flammable == nil then
		o.flammable = true
	end
	o.color = o.color or Palette.RoofBrown
	local nx = math.max(1, math.ceil(w / 8))
	local nz = math.max(1, math.ceil(d / 8))
	local cw, cd = w / nx, d / nz
	local out = {}
	for ix = 1, nx do
		for iz = 1, nz do
			local x = -w / 2 + (ix - 0.5) * cw
			local z = -d / 2 + (iz - 0.5) * cd
			table.insert(out, MapKit.part(parent, `{name}_{ix}_{iz}`, origin * CFrame.new(x, y + 0.5, z), Vector3.new(cw, 1, cd), o))
		end
	end
	return out
end

-- A door panel 4 x 7 x 0.6 (tag Door, attrs Locked/Broken, one ProximityPrompt). cf = centre of the
-- doorway with local X along the wall (MapKit.wallWithDoorway returns it). ToolService (G1) handles the
-- prompt. Locked doors need the axe.
function MapKit.door(parent: Instance, name: string, cf: CFrame, locked: boolean): Part
	local d = MapKit.part(parent, name, cf, Vector3.new(4, 7, 0.6), {
		color = if locked then Palette.CharredWarm else Palette.BookshelfWood,
		flammable = true,
		fuel = 30,
		tags = { Names.Tag.Door },
	})
	d:SetAttribute(Names.Attr.Locked, locked)
	d:SetAttribute(Names.Attr.Broken, false)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = if locked then "Break (axe)" else "Open"
	prompt.ObjectText = "Door"
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = d
	return d
end

-- A 4x4 window pane (tagged Window). cf = pane centre, local X along the wall.
function MapKit.window(parent: Instance, name: string, cf: CFrame): Part
	return MapKit.part(parent, name, cf, Vector3.new(4, 4, 0.3), {
		color = Color3.fromHex("#A8D5E2"),
		material = Enum.Material.Glass,
		transparency = 0.35,
		collide = false,
		tags = { Names.Tag.Window },
	})
end

-- Red fire hydrant with a refill prompt (Body tagged Hydrant). cf = base point on the ground.
-- Cylinder parts run along their local X, so the body is (length 3, diameter 1.4) rotated upright.
function MapKit.hydrant(parent: Instance, cf: CFrame): Model
	local m = Instance.new("Model")
	m.Name = "Hydrant"
	local body = MapKit.part(m, "Body", cf * CFrame.new(0, 1.5, 0) * CFrame.Angles(0, 0, math.rad(90)), Vector3.new(3, 1.4, 1.4), {
		color = Palette.TruckRed,
		shape = Enum.PartType.Cylinder,
		tags = { Names.Tag.Hydrant },
	})
	MapKit.part(m, "Cap", cf * CFrame.new(0, 3.2, 0), Vector3.new(1.6, 1.6, 1.6), {
		color = Palette.TruckRed,
		shape = Enum.PartType.Ball,
	})
	MapKit.part(m, "NozzleL", cf * CFrame.new(-0.9, 2, 0), Vector3.new(0.6, 0.6, 0.6), { color = Palette.BrassCoupling })
	MapKit.part(m, "NozzleR", cf * CFrame.new(0.9, 2, 0), Vector3.new(0.6, 0.6, 0.6), { color = Palette.BrassCoupling })
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Refill"
	prompt.ObjectText = "Hydrant"
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = body
	m.PrimaryPart = body
	m.Parent = parent
	return m
end

-- Low-poly deciduous tree (decor, not flammable). cf = base point on the ground.
function MapKit.tree(parent: Instance, cf: CFrame): Model
	local m = Instance.new("Model")
	m.Name = "Tree"
	MapKit.part(m, "Trunk", cf * CFrame.new(0, 3, 0) * CFrame.Angles(0, 0, math.rad(90)), Vector3.new(6, 1.2, 1.2), {
		color = Color3.fromHex("#7A3A1E"),
		shape = Enum.PartType.Cylinder,
	})
	MapKit.part(m, "Canopy1", cf * CFrame.new(0, 8, 0), Vector3.new(7, 7, 7), {
		color = Color3.fromHex("#6F9A3A"),
		shape = Enum.PartType.Ball,
	})
	MapKit.part(m, "Canopy2", cf * CFrame.new(1.5, 10, 1), Vector3.new(5, 5, 5), {
		color = Color3.fromHex("#8AAF4A"),
		shape = Enum.PartType.Ball,
	})
	m.Parent = parent
	return m
end

-- Street lamp: pole + Neon bulb + warm PointLight. cf = base point on the ground.
function MapKit.lamp(parent: Instance, cf: CFrame): Model
	local m = Instance.new("Model")
	m.Name = "Lamp"
	MapKit.part(m, "Pole", cf * CFrame.new(0, 6, 0), Vector3.new(0.6, 12, 0.6), { color = Palette.LockerGrey })
	local bulb = MapKit.part(m, "Bulb", cf * CFrame.new(0, 12.5, 0), Vector3.new(1.4, 1.4, 1.4), {
		color = Color3.fromHex("#FFC97A"),
		shape = Enum.PartType.Ball,
		neon = true,
		collide = false,
	})
	local light = Instance.new("PointLight")
	light.Color = Color3.fromHex("#FFC97A")
	light.Range = 24
	light.Brightness = 1.5
	light.Parent = bulb
	m.Parent = parent
	return m
end

-- Big text on one face of a part ("67", "STATION 67", locker numbers).
function MapKit.label(part: BasePart, face: Enum.NormalId, text: string, color: Color3?): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Label"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.LuckiestGuy
	t.TextScaled = true
	t.Text = text
	t.TextColor3 = color or Palette.TrimWhite
	local stroke = Instance.new("UIStroke")
	stroke.Color = Palette.UiInk
	stroke.Thickness = 3
	stroke.Parent = t
	t.Parent = gui
	gui.Parent = part
	return gui
end

-- World-space hint above a part (always on top, fades past 120 studs). Named "Hint" so callers can
-- check for an existing one.
function MapKit.billboard(part: BasePart, text: string, color: Color3, offsetY: number?): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "Hint"
	gui.Size = UDim2.fromOffset(220, 44)
	gui.StudsOffset = Vector3.new(0, offsetY or 4, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 120
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.LuckiestGuy
	t.TextScaled = true
	t.Text = text
	t.TextColor3 = color
	local stroke = Instance.new("UIStroke")
	stroke.Color = Palette.UiInk
	stroke.Thickness = 3
	stroke.Parent = t
	t.Parent = gui
	gui.Parent = part
	return gui
end

-- Big googly eyes (white ball + black pupil) at `cf` facing -Z of cf. size = eye diameter.
function MapKit.googlyEyes(parent: Instance, cf: CFrame, size: number, gap: number?)
	local g = gap or size * 0.55
	for i, side in { -1, 1 } do
		local eyeCf = cf * CFrame.new(side * g, 0, 0)
		local eye = MapKit.part(parent, `Eye{i}`, eyeCf, Vector3.one * size, {
			color = Palette.EyeWhite,
			shape = Enum.PartType.Ball,
			collide = false,
		})
		eye.Massless = true
		local pupil = MapKit.part(parent, `Pupil{i}`, eyeCf * CFrame.new(0, -size * 0.08, -size * 0.38), Vector3.one * size * 0.42, {
			color = Palette.Pupil,
			shape = Enum.PartType.Ball,
			collide = false,
		})
		pupil.Massless = true
	end
end

function MapKit.pick<T>(rng: Random, list: { T }): T
	return list[rng:NextInteger(1, #list)]
end

-- Stable string hash (same as MapService) for per-building seeds.
function MapKit.hash(s: string): number
	local h = 0
	for i = 1, #s do
		h = (h * 31 + string.byte(s, i)) % 1000003
	end
	return h
end

return MapKit
```

- [ ] **Step 5: Compile check**

Run: `python3 game/tools/sync.py check --root game`
Expected: `OK: checked N files, 0 failed` (and `forge watch` prints ✓).

- [ ] **Step 6: Re-run the Step 2 check, plus the doorway helper**

Same call as Step 2, now expected: `chunks=3 size=8, 11, 1 right=1, 0, 0 body=3, 1.4, 1.4 flammable=true`.
Then check `wallWithDoorway` (Edit):

```lua
local MapKit = require(game.ServerScriptService.Lib.Map.MapKit)
local m = Instance.new("Model")
local parts, doorCf = MapKit.wallWithDoorway(m, "D", CFrame.new(), Vector3.new(-12, 0, -9), Vector3.new(12, 0, -9), 11, 18, 4, 7)
local door = MapKit.door(m, "Door", doorCf, true)
local roof = MapKit.roof(m, "R", CFrame.new(), 24, 18, 11)
local out = string.format("doorChunks=%d doorPos=%s doorRight=%s locked=%s prompt=%s roof=%d roofSize=%s",
	#parts, tostring(doorCf.Position), tostring(doorCf.RightVector), tostring(door:GetAttribute("Locked")),
	tostring(door:FindFirstChildOfClass("ProximityPrompt") ~= nil), #roof, tostring(roof[1].Size))
m:Destroy()
return out
```

Expected: `doorChunks=4 doorPos=6, 3.5, -9 doorRight=1, 0, 0 locked=true prompt=true roof=9 roofSize=8, 1, 6`
(chunks: 16-stud segment = 2, 4-stud segment = 1, lintel = 1; the gap is X 4..8, so the door centre is X = 6).

- [ ] **Step 7: Commit and PR**

```bash
git add game/ServerScriptService/Lib/Map/MapKit.luau
git commit -m "game(map): MapKit wall/hydrant orientation fixes, doorway/roof/marker/label/billboard helpers"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch   # after CI is green
```

---

### Task G2.2: StationBuilder (Fire Station 67)  (Dev A, G2, 1.0 h, P0)

**Files:**
- Create: `game/ServerScriptService/Lib/Map/Locations/StationBuilder.luau`

**Interfaces:**
- Consumes: `MapKit` (G2.1), `Names.Tag.{StationSpawn, AlarmLamp, TruckSpot, Hydrant}`, `Names.Attr.{Slot, LocationId}`, `Palette`.
- Produces: location `"Station"` (Slot 0) at `workspace.Map.Station`: 4 pads tagged `StationSpawn` with `Slot` 1..4
  (`MapService:GetSpawnCFrame(slot)` returns pad + 3 studs); 3 Neon parts tagged `AlarmLamp`, each with children
  `AlarmLight` (PointLight) and `AlarmSpot` (SpotLight), disabled; 1 `TruckSpot` marker (attr `LocationId = "Station"`,
  ground point (18, 0.2, 0), facing +Z out of the bay door); 1 hydrant. No `Flammable` parts.

**Integration point:** SquadService (G3) spawns players on `GetSpawnCFrame(helmet)`. Before this task lands it
falls back to `SlotOrigin(0) + (slot - 1) * 4, 5, 0`.

- [ ] **Step 1: Branch**

```bash
git switch main && git pull --rebase && git switch -c g2/station
```

- [ ] **Step 2: Write the failing Play check**

`start_stop_play {"is_start": true, "studio_id": "<id>"}`, then `execute_luau` (`"datamodel_type": "Server"`):

```lua
local t0 = os.clock()
repeat task.wait(0.25) until workspace:GetAttribute("MapReady") or os.clock() - t0 > 15
local station = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Station")
local function count(tag: string): number
	local n = 0
	if station then
		for _, d in station:GetDescendants() do
			if d:HasTag(tag) then
				n += 1
			end
		end
	end
	return n
end
local ok, spawn2 = game.ServerStorage.DevHook:Invoke("MapService", "GetSpawnCFrame", 2)
return string.format("station=%s pads=%d lamps=%d truckSpot=%d hydrant=%d flammable=%d spawn2=%s",
	tostring(station ~= nil), count("StationSpawn"), count("AlarmLamp"), count("TruckSpot"), count("Hydrant"),
	count("Flammable"), if ok then tostring(spawn2.Position) else "error")
```

- [ ] **Step 3: Run it, expect FAIL**

Expected before the builder exists: `station=false pads=0 lamps=0 truckSpot=0 hydrant=0 flammable=0 spawn2=4, 5, 0`
(the report shows the MapService warning `no ServerScriptService.Lib.Map.Locations yet`). Stop the playtest.

- [ ] **Step 4: Create `game/ServerScriptService/Lib/Map/Locations/StationBuilder.luau`:**

```lua
--!strict
-- StationBuilder [owner: G2]. Fire Station 67, the hub (docs/game/05 §2.1). Slot 0.
-- Footprint 80 x 60 (local X -40..40, Z -30..30), floor top at y = 0.2 (just above the baseplate).
-- Locker room X -40..-8 (spawn pads, lockers, helmet rack), apparatus bay X -8..40 (truck spot, tool
-- bench, alarm lamps), bay door in the south wall at X 6..30, hydrant H0 outside.
-- Tags written: StationSpawn x4 (attr Slot 1..4), AlarmLamp x3, TruckSpot x1 (attr LocationId "Station"),
-- Hydrant x1. Nothing here is Flammable.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)

local StationBuilder = {}
StationBuilder.Id = "Station"
StationBuilder.Slot = 0

local F = 0.2 -- floor top
local WALL_H = 16

function StationBuilder.Build(model: Model, origin: CFrame, _rng: Random)
	local function at(x: number, y: number, z: number): CFrame
		return origin * CFrame.new(x, y, z)
	end
	local brick: MapKit.PartOpts = { flammable = false, color = Palette.StationBrick }

	-- floor, apron, bay lines
	MapKit.part(model, "Floor", at(0, F - 0.5, 0), Vector3.new(80, 1, 60), { color = Palette.StationFloor })
	MapKit.part(model, "Apron", at(18, F - 0.5, 42), Vector3.new(26, 1, 24), { color = Palette.Sidewalk })
	for i, x in { 12, 24 } do
		MapKit.part(model, `BayLine{i}`, at(x, F + 0.025, 0), Vector3.new(0.4, 0.05, 28), {
			color = Palette.FloorLineYellow,
			collide = false,
		})
	end

	-- walls (brick, never flammable)
	MapKit.wall(model, "WallN", origin, Vector3.new(-40, F, -30), Vector3.new(40, F, -30), WALL_H, brick)
	MapKit.wall(model, "WallW", origin, Vector3.new(-40, F, -30), Vector3.new(-40, F, 30), WALL_H, brick)
	MapKit.wall(model, "WallE", origin, Vector3.new(40, F, -30), Vector3.new(40, F, 30), WALL_H, brick)
	-- south wall with the 24 x 14 bay door opening at X 6..30 (58 studs from the west end)
	MapKit.wallWithDoorway(model, "WallS", origin, Vector3.new(-40, F, 30), Vector3.new(40, F, 30), WALL_H, 58, 24, 14, brick)
	-- locker room / bay divider with a 6-wide doorway at Z = 10 (40 studs from the north end)
	MapKit.wallWithDoorway(model, "Divider", origin, Vector3.new(-8, F, -30), Vector3.new(-8, F, 30), WALL_H, 40, 6, 9, brick)
	MapKit.part(model, "Roof", at(0, F + WALL_H + 0.5, 0), Vector3.new(81, 1, 61), { color = Palette.StationBrick })

	-- ceiling lights (Neon panels + SurfaceLight down)
	for i, p in { Vector3.new(-24, 0, -10), Vector3.new(0, 0, -10), Vector3.new(18, 0, 0), Vector3.new(18, 0, 18) } do
		local panel = MapKit.part(model, `CeilingLight{i}`, at(p.X, F + WALL_H - 0.3, p.Z), Vector3.new(8, 0.3, 2), {
			color = Color3.fromHex("#FFF4D6"),
			neon = true,
			collide = false,
		})
		local light = Instance.new("SurfaceLight")
		light.Face = Enum.NormalId.Bottom
		light.Range = 16
		light.Brightness = 1.2
		light.Color = Color3.fromHex("#FFE2B8")
		light.Parent = panel
	end

	-- locker room: 4 numbered lockers on the north wall (fronts face +Z), bench, helmet rack
	for i = 1, 4 do
		local locker = MapKit.part(model, `Locker{i}`, at(-36 + (i - 1) * 4, F + 3.75, -28.5) * CFrame.Angles(0, math.pi, 0), Vector3.new(3, 7.5, 2), {
			color = Palette.LockerGrey,
		})
		MapKit.label(locker, Enum.NormalId.Front, string.format("%02d", i), Palette.TrimWhite)
	end
	MapKit.box(model, "Bench", at(-24, F + 0.7, -20), Vector3.new(10, 1.4, 2), Palette.BookshelfWood)
	MapKit.box(model, "HelmetRack", at(-20, F + 2, -28.5), Vector3.new(6, 4, 2), Palette.LockerGrey)
	for i = 1, 4 do
		MapKit.part(model, `RackHelmet{i}`, at(-22.25 + (i - 1) * 1.5, F + 4.6, -28.5), Vector3.new(1.3, 1.2, 1.3), {
			color = Palette.HelmetRed,
			shape = Enum.PartType.Ball,
			collide = false,
		})
	end

	-- spawn pads s1..s4 (StationSpawn, attr Slot) with their number on top
	for i = 1, 4 do
		local pad = MapKit.part(model, `Pad{i}`, at(-30 + (i - 1) * 4, F + 0.1, 10), Vector3.new(3, 0.2, 3), {
			color = Palette.FloorLineYellow,
			tags = { Names.Tag.StationSpawn },
		})
		pad:SetAttribute(Names.Attr.Slot, i)
		MapKit.label(pad, Enum.NormalId.Top, string.format("%02d", i), Palette.UiInk)
	end

	-- tool bench with hose coils and an axe (decor; real tools come from ToolService)
	MapKit.box(model, "ToolBench", at(10, F + 1.5, -26), Vector3.new(16, 3, 4), Palette.BookshelfWood)
	for i = 1, 3 do
		MapKit.part(model, `HoseCoil{i}`, at(6, F + 3.2 + (i - 1) * 0.8, -26) * CFrame.Angles(0, 0, math.rad(90)), Vector3.new(0.8, 2.4, 2.4), {
			color = if i == 2 then Palette.HoseYellow else Color3.fromHex("#B83A2E"),
			shape = Enum.PartType.Cylinder,
			collide = false,
		})
	end
	MapKit.part(model, "AxeHandle", at(13, F + 4.5, -27.6), Vector3.new(0.3, 3, 0.3), { color = Palette.BookshelfWood, collide = false })
	MapKit.part(model, "AxeHead", at(13.5, F + 5.7, -27.6), Vector3.new(1.2, 0.8, 0.2), { color = Palette.HelmetRed, collide = false })

	-- alarm lamps (AlarmController spins them and switches the lights on during the Alarm phase)
	for i, p in { Vector3.new(0, 0, 0), Vector3.new(-24, 0, 0), Vector3.new(24, 0, -20) } do
		MapKit.part(model, `LampHousing{i}`, at(p.X, F + WALL_H - 0.6, p.Z), Vector3.new(2, 0.6, 2), {
			color = Palette.LockerGrey,
			collide = false,
		})
		local lamp = MapKit.part(model, `AlarmLamp{i}`, at(p.X, F + WALL_H - 1.5, p.Z), Vector3.new(1.6, 1.2, 1.6), {
			color = Palette.AlarmRed,
			neon = true,
			collide = false,
			tags = { Names.Tag.AlarmLamp },
		})
		local point = Instance.new("PointLight")
		point.Name = "AlarmLight"
		point.Enabled = false
		point.Color = Palette.AlarmRed
		point.Range = 20
		point.Brightness = 3
		point.Parent = lamp
		local spot = Instance.new("SpotLight")
		spot.Name = "AlarmSpot"
		spot.Enabled = false
		spot.Face = Enum.NormalId.Front
		spot.Angle = 45
		spot.Range = 30
		spot.Brightness = 4
		spot.Color = Palette.AlarmRed
		spot.Parent = lamp
	end

	-- where truck 67 parks: centre of the bay, facing out of the bay door (+Z)
	MapKit.marker(model, "TruckSpot", origin * CFrame.lookAt(Vector3.new(18, F, 0), Vector3.new(18, F, 10)), Vector3.new(4, 1, 4), Names.Tag.TruckSpot, {
		[Names.Attr.LocationId] = "Station",
	})

	-- hydrant H0 outside the bay, and the sign over the bay door
	MapKit.hydrant(model, at(34, F, 34))
	local sign = MapKit.part(model, "Sign", at(18, F + 15, 30.7), Vector3.new(16, 1.8, 0.3), { color = Palette.TrimWhite })
	MapKit.label(sign, Enum.NormalId.Back, "STATION 67", Palette.TruckRed)
end

return StationBuilder
```

- [ ] **Step 5: Compile check**

Run: `python3 game/tools/sync.py check --root game` → `OK: checked N files, 0 failed`.

- [ ] **Step 6: Edit-mode preview and screenshot**

`execute_luau` (`"datamodel_type": "Edit"`):

```lua
local B = require(game.ServerScriptService.Lib.Map.Locations.StationBuilder)
local m = Instance.new("Model")
m.Name = "PreviewStation"
B.Build(m, CFrame.new(0, 0, 0), Random.new(1))
local n = #m:GetDescendants()
m.Parent = workspace
workspace.CurrentCamera.CFrame = CFrame.lookAt(Vector3.new(60, 70, 90), Vector3.new(0, 0, 0))
return "descendants=" .. n
```

Expected `descendants=` roughly 120–200. Then `mcp__Roblox_Studio__screen_capture {"studio_id": "<id>"}`. Look for:
continuous brick walls (no fins), a 24-wide bay door gap on the south side, the roof, and the white `STATION 67`
sign above the bay door. Then delete the preview (Edit):

```lua
workspace.PreviewStation:Destroy()
return workspace:FindFirstChild("PreviewStation") == nil
```

Expected `true`.

- [ ] **Step 7: Re-run the Step 2 Play check**

Expected: `station=true pads=4 lamps=3 truckSpot=1 hydrant=1 flammable=0 spawn2=-26, 3.3, 10`. Also read
`game.ServerStorage.ForgeProbe:Invoke("report")`: `errors` is `[]`. Stop the playtest.

- [ ] **Step 8: Commit and PR**

```bash
git add game/ServerScriptService/Lib/Map/Locations/StationBuilder.luau
git commit -m "game(map): Station 67 builder (spawn pads, alarm lamps, truck bay, hydrant)"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

---

### Task G2.3: TownBuilder (Maple Street)  (Dev A, G2, 1.5 h, P0)

**Files:**
- Create: `game/ServerScriptService/Lib/Map/Locations/TownBuilder.luau`

**Interfaces:**
- Consumes: `MapKit` (G2.1), `Names.Tag.{FireStart, RescueSpawn, TruckSpot}`, `Names.Attr.{BuildingId, Kind, LocationId}`, `Palette`.
- Produces: location `"Town"` (Slot 1, origin (400, 0, 0)) at `workspace.Map.Town` with exactly:
  `Flammable` 120 (walls, roof chunks, furniture, 2 locked doors), `FireStart` 3 (House1 `Counter`, House2 `Sofa`,
  House3 `Workbench`), `RescueSpawn` 5 (House1 Civilian, House2 Cat, House2 Panda behind House2's locked `InnerDoor`,
  House3 Dog, House4 Civilian behind House4's locked `FrontDoor`), `Door` 2 (both `Locked = true`), `Hydrant` 3,
  `TruckSpot` 1 (attr `LocationId = "Town"`, ground point (400, 0.2, -32), facing +X), `Window` 12. House Models
  `House1`..`House4` carry `BuildingId` `"Town.House1"`..`"Town.House4"`; RescueSpawn markers carry `Kind` and `BuildingId`.
  Houses are 80 studs apart (56-stud gaps), so fire never jumps between houses.

**Integration points:** FireService (G1) indexes these 120 parts on `LocationBuilt`. MissionService (G3) lights
the 3 `FireStart` parts. RescueService (G3) spawns 5 NPCs on the markers. ToolService (G1) handles the 2 locked
doors' and 3 hydrants' prompts.

- [ ] **Step 1: Branch**

```bash
git switch main && git pull --rebase && git switch -c g2/town
```

- [ ] **Step 2: Write the failing Play check**

`start_stop_play {"is_start": true, "studio_id": "<id>"}`, then `execute_luau` (`Server`):

```lua
local t0 = os.clock()
repeat task.wait(0.25) until workspace:GetAttribute("MapReady") or os.clock() - t0 > 15
local HttpService = game:GetService("HttpService")
local town = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Town")
local function count(tag: string): number
	local n = 0
	if town then
		for _, d in town:GetDescendants() do
			if d:HasTag(tag) then
				n += 1
			end
		end
	end
	return n
end
local kinds = {}
if town then
	for _, d in town:GetDescendants() do
		if d:HasTag("RescueSpawn") then
			table.insert(kinds, `{d:GetAttribute("BuildingId")}:{d:GetAttribute("Kind")}`)
		end
	end
end
table.sort(kinds)
local locked = 0
if town then
	for _, d in town:GetDescendants() do
		if d:HasTag("Door") and d:GetAttribute("Locked") == true then
			locked += 1
		end
	end
end
local report = HttpService:JSONDecode(game.ServerStorage.ForgeProbe:Invoke("report"))
return HttpService:JSONEncode({
	town = town ~= nil,
	parts = if town then #town:GetDescendants() else 0,
	flammable = count("Flammable"), fireStart = count("FireStart"), rescueSpawn = count("RescueSpawn"),
	door = count("Door"), lockedDoors = locked, hydrant = count("Hydrant"), truckSpot = count("TruckSpot"),
	window = count("Window"), kinds = table.concat(kinds, ","),
	map_build_ms = report.counters.map_build_ms, errors = #report.errors,
})
```

- [ ] **Step 3: Run it, expect FAIL**

Expected before TownBuilder exists: `"town":false` and every count `0`. Stop the playtest.

- [ ] **Step 4: Create `game/ServerScriptService/Lib/Map/Locations/TownBuilder.luau`:**

```lua
--!strict
-- TownBuilder [owner: G2]. Maple Street, the v1 mission map (docs/game/05 §2.2). Slot 1.
-- Pure function of (origin, rng): same seed -> same town, so RebuildLocation("Town") resets a round.
-- Layout (local to origin, floor/ground top y = 0.2): an east-west road at Z -40..-24, sidewalks either
-- side, four one-storey houses (24 x 18, walls 11 high) at X -120, -40, 40, 120 centred on Z = 10, front
-- doors facing the street (-Z). Each house: front room (Z -9..1) and back room (Z 1..9) split by an
-- interior wall with a doorway at house-local X = -6; front doorway at house-local X = +6. Furniture is
-- placed so the walk front door -> interior doorway stays clear (>= 2.5 studs everywhere).
--   House1 "Kitchen":  FireStart counter; Civilian in the back room.
--   House2 "Cat house": FireStart sofa; Cat in the front room; Panda in the back room behind a LOCKED door.
--   House3 "Garage":   FireStart workbench; Dog in the back room.
--   House4 "Pool house": LOCKED front door; Civilian in the back room.
-- Counts (checked by the G2.3 preview): Flammable 120, FireStart 3, RescueSpawn 5, Door 2 (both locked),
-- Hydrant 3, TruckSpot 1, Window 12.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)

local TownBuilder = {}
TownBuilder.Id = "Town"
TownBuilder.Slot = 1

local F = 0.2 -- ground top
local FLOOR_TOP = 0.4 -- house floor top, house-local
local WALL_H = 11

type Furniture = { name: string, pos: Vector3, size: Vector3, color: Color3, fireStart: boolean?, fuel: number? }
type Rescue = { kind: string, pos: Vector3 }
type HouseSpec = {
	x: number,
	frontLocked: boolean,
	innerLocked: boolean,
	furniture: { Furniture },
	rescues: { Rescue },
}

-- y of a box standing on the house floor
local function on(h: number): number
	return FLOOR_TOP + h / 2
end

local HOUSES: { HouseSpec } = {
	{
		x = -120,
		frontLocked = false,
		innerLocked = false,
		furniture = {
			{ name = "Counter", pos = Vector3.new(-8, on(3), -6.5), size = Vector3.new(6, 3, 2.5), color = Palette.TrimWhite, fireStart = true, fuel = 60 },
			{ name = "Table", pos = Vector3.new(2, on(2.5), -4), size = Vector3.new(4, 2.5, 3), color = Palette.BookshelfWood },
			{ name = "Bed", pos = Vector3.new(5, on(2), 5.5), size = Vector3.new(6, 2, 4), color = Palette.CivShirtRed },
			{ name = "Dresser", pos = Vector3.new(-9, on(4), 6.5), size = Vector3.new(3, 4, 2), color = Palette.BookshelfWood },
		},
		rescues = { { kind = "Civilian", pos = Vector3.new(-3, FLOOR_TOP + 1, 4) } },
	},
	{
		x = -40,
		frontLocked = false,
		innerLocked = true,
		furniture = {
			{ name = "Sofa", pos = Vector3.new(-2, on(3), -5), size = Vector3.new(8, 3, 3), color = Color3.fromHex("#6E8A6A"), fireStart = true, fuel = 60 },
			{ name = "Bookshelf", pos = Vector3.new(-10.5, on(7), -3), size = Vector3.new(1.4, 7, 4), color = Palette.BookshelfWood },
			{ name = "CoffeeTable", pos = Vector3.new(-1, on(1.5), -1.5), size = Vector3.new(4, 1.5, 2), color = Palette.WoodFloor },
			{ name = "Bed", pos = Vector3.new(5, on(2), 5.5), size = Vector3.new(6, 2, 4), color = Palette.SidingSage },
		},
		rescues = {
			{ kind = "Cat", pos = Vector3.new(-8, FLOOR_TOP + 1, -6) },
			{ kind = "Panda", pos = Vector3.new(-2, FLOOR_TOP + 1, 5) },
		},
	},
	{
		x = 40,
		frontLocked = false,
		innerLocked = false,
		furniture = {
			{ name = "Workbench", pos = Vector3.new(9, on(3), -3.5), size = Vector3.new(2.5, 3, 5), color = Palette.BookshelfWood, fireStart = true, fuel = 60 },
			{ name = "Car", pos = Vector3.new(0, on(4), -5), size = Vector3.new(5, 4, 6), color = Palette.SidingBlue },
			{ name = "Shelf", pos = Vector3.new(-10.5, on(6), 5), size = Vector3.new(1.4, 6, 4), color = Palette.BookshelfWood },
		},
		rescues = { { kind = "Dog", pos = Vector3.new(2, FLOOR_TOP + 1, 5) } },
	},
	{
		x = 120,
		frontLocked = true,
		innerLocked = false,
		furniture = {
			{ name = "Bed", pos = Vector3.new(5, on(2), 5.5), size = Vector3.new(6, 2, 4), color = Palette.CivShirtRed },
			{ name = "Sofa", pos = Vector3.new(9.5, on(3), -3), size = Vector3.new(3, 3, 6), color = Palette.SidingSalmon },
			{ name = "Table", pos = Vector3.new(-9, on(2.5), -6), size = Vector3.new(4, 2.5, 3), color = Palette.BookshelfWood },
		},
		rescues = { { kind = "Civilian", pos = Vector3.new(-4, FLOOR_TOP + 1, 5) } },
	},
}

local function buildHouse(parent: Model, index: number, spec: HouseSpec, hcf: CFrame, siding: Color3)
	local house = Instance.new("Model")
	house.Name = `House{index}`
	local buildingId = `Town.House{index}`
	house:SetAttribute(Names.Attr.BuildingId, buildingId)
	local outer: MapKit.PartOpts = { color = siding }
	local inner: MapKit.PartOpts = { color = Palette.RoomTeal }

	MapKit.part(house, "Floor", hcf * CFrame.new(0, FLOOR_TOP / 2, 0), Vector3.new(24, FLOOR_TOP, 18), { color = Palette.WoodFloor })

	-- outer walls; front doorway centred 18 studs from the west corner (house-local X = +6)
	local _, frontDoorCf = MapKit.wallWithDoorway(house, "WallFront", hcf, Vector3.new(-12, 0, -9), Vector3.new(12, 0, -9), WALL_H, 18, 4, 7, outer)
	MapKit.wall(house, "WallBack", hcf, Vector3.new(-12, 0, 9), Vector3.new(12, 0, 9), WALL_H, outer)
	MapKit.wall(house, "WallLeft", hcf, Vector3.new(-12, 0, -9), Vector3.new(-12, 0, 9), WALL_H, outer)
	MapKit.wall(house, "WallRight", hcf, Vector3.new(12, 0, -9), Vector3.new(12, 0, 9), WALL_H, outer)
	-- interior wall at Z = 1; doorway centred 6 studs from the west end (house-local X = -6)
	local _, innerDoorCf = MapKit.wallWithDoorway(house, "WallInner", hcf, Vector3.new(-12, 0, 1), Vector3.new(12, 0, 1), WALL_H, 6, 4, 7, inner)
	if spec.frontLocked then
		MapKit.door(house, "FrontDoor", frontDoorCf, true)
	end
	if spec.innerLocked then
		MapKit.door(house, "InnerDoor", innerDoorCf, true)
	end

	MapKit.roof(house, "Roof", hcf, 24, 18, WALL_H, { color = Palette.RoofBrown })
	MapKit.part(house, "Chimney", hcf * CFrame.new(8, WALL_H + 2.5, 4), Vector3.new(2, 3, 2), { color = Palette.StationBrick })

	-- windows: one front, one per side (decor; glass is not flammable)
	MapKit.window(house, "WindowFront", hcf * CFrame.new(-6, 5, -9.65))
	MapKit.window(house, "WindowLeft", hcf * CFrame.new(-12.65, 5, -4) * CFrame.Angles(0, math.rad(90), 0))
	MapKit.window(house, "WindowRight", hcf * CFrame.new(12.65, 5, 5) * CFrame.Angles(0, math.rad(90), 0))

	for _, f in spec.furniture do
		local p = MapKit.box(house, f.name, hcf * CFrame.new(f.pos), f.size, f.color, true, f.fuel)
		if f.fireStart then
			p:AddTag(Names.Tag.FireStart)
		end
	end

	for _, r in spec.rescues do
		MapKit.marker(house, `Rescue_{r.kind}`, hcf * CFrame.lookAt(r.pos, r.pos + Vector3.new(0, 0, -1)), Vector3.new(2, 2, 2), Names.Tag.RescueSpawn, {
			[Names.Attr.Kind] = r.kind,
			[Names.Attr.BuildingId] = buildingId,
		})
	end

	house.Parent = parent
end

function TownBuilder.Build(model: Model, origin: CFrame, rng: Random)
	local function at(x: number, y: number, z: number): CFrame
		return origin * CFrame.new(x, y, z)
	end

	-- ground, road, sidewalks, centre dashes
	MapKit.part(model, "Ground", at(0, F - 0.5, 0), Vector3.new(380, 1, 380), { color = Palette.LawnGreen })
	MapKit.part(model, "Road", at(0, F + 0.1, -32), Vector3.new(360, 0.2, 16), { color = Palette.Asphalt })
	MapKit.part(model, "SidewalkSouth", at(0, F + 0.2, -22), Vector3.new(360, 0.4, 4), { color = Palette.Sidewalk })
	MapKit.part(model, "SidewalkNorth", at(0, F + 0.2, -42), Vector3.new(360, 0.4, 4), { color = Palette.Sidewalk })
	for i = 0, 22 do
		MapKit.part(model, `Dash{i}`, at(-176 + i * 16, F + 0.225, -32), Vector3.new(4, 0.05, 0.4), {
			color = Palette.TrimWhite,
			collide = false,
		})
	end

	-- houses with front paths
	for i, spec in HOUSES do
		local siding = MapKit.pick(rng, MapKit.WarmColors)
		buildHouse(model, i, spec, at(spec.x, F, 10), siding)
		MapKit.part(model, `Path{i}`, at(spec.x + 6, F + 0.15, -9.5), Vector3.new(3, 0.3, 21), { color = Palette.Sidewalk })
	end

	-- hydrants on the house-side sidewalk, between the houses
	for _, x in { -80, 0, 80 } do
		MapKit.hydrant(model, at(x, F + 0.4, -21))
	end

	-- where truck 67 parks: middle of the road, facing east (+X)
	MapKit.marker(model, "TruckSpot", origin * CFrame.lookAt(Vector3.new(0, F, -32), Vector3.new(10, F, -32)), Vector3.new(4, 1, 4), Names.Tag.TruckSpot, {
		[Names.Attr.LocationId] = "Town",
	})

	-- street lamps on the north sidewalk, trees behind the houses and across the road
	for i = 0, 8 do
		MapKit.lamp(model, at(-160 + i * 40, F + 0.4, -42))
	end
	for _, x in { -160, -80, 0, 80, 160 } do
		MapKit.tree(model, at(x, F, 36))
	end
	for _, x in { -140, -20, 100 } do
		MapKit.tree(model, at(x, F, -60))
	end
end

return TownBuilder
```

- [ ] **Step 5: Compile check**

Run: `python3 game/tools/sync.py check --root game` → `OK: checked N files, 0 failed`.

- [ ] **Step 6: Edit-mode preview, counts and screenshot**

`execute_luau` (`Edit`):

```lua
local B = require(game.ServerScriptService.Lib.Map.Locations.TownBuilder)
local m = Instance.new("Model")
m.Name = "PreviewTown"
B.Build(m, CFrame.new(400, 0, 0), Random.new(6767))
local function count(tag: string): number
	local n = 0
	for _, d in m:GetDescendants() do
		if d:HasTag(tag) then
			n += 1
		end
	end
	return n
end
local out = string.format("descendants=%d Flammable=%d FireStart=%d RescueSpawn=%d Door=%d Hydrant=%d TruckSpot=%d Window=%d",
	#m:GetDescendants(), count("Flammable"), count("FireStart"), count("RescueSpawn"), count("Door"),
	count("Hydrant"), count("TruckSpot"), count("Window"))
m.Parent = workspace
workspace.CurrentCamera.CFrame = CFrame.lookAt(Vector3.new(400, 110, -170), Vector3.new(400, 0, 0))
return out
```

Expected: `Flammable=120 FireStart=3 RescueSpawn=5 Door=2 Hydrant=3 TruckSpot=1 Window=12`. `descendants` is about
250–350, well under the 3,000-part budget. `screen_capture {"studio_id": "<id>"}`: four houses with solid walls
and flat brown roofs, a road with white dashes, lamps on the far sidewalk, three red hydrants. Then (Edit):

```lua
workspace.PreviewTown:Destroy()
return workspace:FindFirstChild("PreviewTown") == nil
```

- [ ] **Step 7: Re-run the Step 2 Play check, plus determinism after a rebuild**

Expected JSON: `"town":true,"flammable":120,"fireStart":3,"rescueSpawn":5,"door":2,"lockedDoors":2,"hydrant":3,
"truckSpot":1,"window":12,"kinds":"Town.House1:Civilian,Town.House2:Cat,Town.House2:Panda,Town.House3:Dog,Town.House4:Civilian",
"errors":0`, and `map_build_ms` < 2000.
Then, still playing (`Server`):

```lua
local before = #workspace.Map.Town:GetDescendants()
local ok = game.ServerStorage.DevHook:Invoke("MapService", "RebuildLocation", "Town")
local after = #workspace.Map.Town:GetDescendants()
return string.format("ok=%s before=%d after=%d", tostring(ok), before, after)
```

Expected `ok=true` and `before == after` (same seed gives the same town). Stop the playtest.

- [ ] **Step 8: Commit and PR**

```bash
git add game/ServerScriptService/Lib/Map/Locations/TownBuilder.luau
git commit -m "game(map): Maple Street town builder (4 houses, FireStart, RescueSpawn, locked doors, hydrants, TruckSpot)"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

---

### Task G2.4: Review and commit TruckBuilder + AtmosphereService  (Dev A, G2, 0.5 h, P0)

**Files (already written, uncommitted; do not rewrite):**
- Add: `game/ServerScriptService/Lib/Map/Props/TruckBuilder.luau`
- Add: `game/ServerScriptService/Services/AtmosphereService.luau`
- Add: `game/ReplicatedStorage/Config/AtmosphereConfig.luau`

**Interfaces:**
- Produces: `TruckBuilder.Build(parent: Instance, cf: CFrame): Model`. `cf` is the ground point under the truck
  centre; the truck faces -Z of `cf`. Model `"FireTruck67"`, tag `Truck`, PrimaryPart `"Chassis"`; part `"Reel"` tagged
  `TruckRefill` with one ProximityPrompt (`"Refill"`, HoldDuration 0.5); part `"RescueDropoff"` tagged `RescueDropoff`
  (invisible 12 x 7 x 6 box at the open back); parts `LightRed`, `LightBlue`, `LightWhite`, `Siren`, `Deck`, `Bench_L/R`.
  `AtmosphereService` (Priority 1) applies `AtmosphereConfig.Default` (`"DuskSuburb"`) in Start; API
  `Apply(presetName, tweenTime?)`, `.ApplyPreset(...)`, `GetPreset()`.

- [ ] **Step 1: Branch and review checklist**

```bash
git switch main && git pull --rebase && git switch -c g2/truck-atmosphere
git status --short game/   # the three files above show as ?? (untracked)
```

Read the three files and tick each item (no code changes expected):
- [ ] Each file starts with `--!strict`, uses tabs, and has an owner/API header comment.
- [ ] TruckBuilder builds under an unparented Model and sets `m.Parent = parent` once, last.
- [ ] Tags come from `Names.Tag.*` (`Truck`, `TruckRefill`, `RescueDropoff`), never string literals.
- [ ] Known quirk, handled in G2.5 and **not** to be fixed here: the PrimaryPart `Chassis` centre is 2 studs above
      the ground point, so `Model:GetPivot()` is not the ground point. VehicleService stores the offset.
- [ ] `RescueDropoff` has `CanQuery = true` (MapKit default). VehicleService sets it to `false` after building.
- [ ] `SirenSound` has no `SoundId`. Nothing may call `:Play()` on it in v1 (audio is v2).
- [ ] AtmosphereService tries `Lighting.Technology` in a pcall and **warns once per boot** when scripts can't set
      it. That warning in ForgeProbe `warnings` is expected. To set Future once in your local place, run in Edit:
      `game.Lighting.Technology = Enum.Technology.Future`.
- [ ] `AtmosphereService._selftest` is declared with `.` and returns a boolean only. DevHook calls it fine
      (`fn(mod)`); the `_selftest` runner shows `msg = nil`. Acceptable.

- [ ] **Step 2: Write the failing check (Edit preview of the truck)**

`execute_luau` (`Edit`):

```lua
local ok, T = pcall(require, game.ServerScriptService.Lib.Map.Props.TruckBuilder)
if not ok then
	return "FAIL: " .. tostring(T)
end
local holder = Instance.new("Folder")
local m = T.Build(holder, CFrame.new(0, 0.2, 80))
local function tagged(tag: string): number
	local n = 0
	for _, d in m:GetDescendants() do
		if d:HasTag(tag) then
			n += 1
		end
	end
	return n
end
local reel = m:FindFirstChild("Reel")
local out = string.format("name=%s truckTag=%s primary=%s refill=%d dropoff=%d reelPrompt=%s lights=%s pivotY=%.1f",
	m.Name, tostring(m:HasTag("Truck")), tostring(m.PrimaryPart and m.PrimaryPart.Name), tagged("TruckRefill"),
	tagged("RescueDropoff"), tostring(reel ~= nil and reel:FindFirstChildOfClass("ProximityPrompt") ~= nil),
	tostring(m:FindFirstChild("LightRed") ~= nil and m:FindFirstChild("LightBlue") ~= nil and m:FindFirstChild("LightWhite") ~= nil),
	m:GetPivot().Position.Y)
m.Parent = workspace
workspace.CurrentCamera.CFrame = CFrame.lookAt(Vector3.new(25, 15, 60), Vector3.new(0, 4, 80))
return out
```

- [ ] **Step 3: Run it**

If the files are not synced yet (for example `forge watch` was started from a checkout that doesn't have them), expect
`FAIL: ...` and fix the sync. With the files present, expect:
`name=FireTruck67 truckTag=true primary=Chassis refill=1 dropoff=1 reelPrompt=true lights=true pivotY=2.2`.
`screen_capture {"studio_id": "<id>"}` shows the red truck with "67", the light bar and the yellow reel. Then (Edit):

```lua
workspace.FireTruck67:Destroy()
return workspace:FindFirstChild("FireTruck67") == nil
```

- [ ] **Step 4: Check the lighting preset (Edit, then Play)**

Edit:

```lua
local A = require(game.ServerScriptService.Services.AtmosphereService)
local ok = A.ApplyPreset("DuskSuburb")
return string.format("ok=%s preset=%s atmosphere=%s", tostring(ok), tostring(game.Lighting:GetAttribute("AtmospherePreset")),
	tostring(game.Lighting:FindFirstChild("Forge_Atmosphere") ~= nil))
```

Expected `ok=true preset=DuskSuburb atmosphere=true`. Then `start_stop_play {"is_start": true}` and (`Server`):

```lua
task.wait(2)
local HttpService = game:GetService("HttpService")
local r = HttpService:JSONDecode(game.ServerStorage.ForgeProbe:Invoke("report"))
local ok, pass = game.ServerStorage.DevHook:Invoke("AtmosphereService", "_selftest")
return string.format("errors=%d selftest=%s preset=%s", #r.errors, tostring(ok and pass), tostring(game.Lighting:GetAttribute("AtmospherePreset")))
```

Expected `errors=0 selftest=true preset=DuskSuburb`. Stop the playtest.

- [ ] **Step 5: Compile check, commit, PR**

```bash
python3 game/tools/sync.py check --root game     # OK: checked N files, 0 failed
git add game/ServerScriptService/Lib/Map/Props/TruckBuilder.luau \
        game/ServerScriptService/Services/AtmosphereService.luau \
        game/ReplicatedStorage/Config/AtmosphereConfig.luau
git commit -m "game(map): truck 67 builder and dusk lighting presets (AtmosphereService)"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

---

### Task G2.5: VehicleService (park truck 67)  (Dev A, G2, 0.75 h, P0)

**Files:**
- Modify: `game/ServerScriptService/Services/VehicleService.luau` (replace the Task 0 stub)

**Interfaces:**
- Consumes: `TruckBuilder.Build` (G2.4), `MapService:GetLocation(id)`, `MapService.LocationBuilt`, `Names.Tag.TruckSpot`,
  `Names.Attr.MapReady`, `VehicleConfig.HomeLocation` / `.TruckNumber` (Task 0).
- Produces (§10): `VehicleService:GetTruck(): Model?`, `VehicleService:ResetTruck()`,
  `VehicleService:ParkAt(locationId: string): boolean`, signal `VehicleService.Driven: Signal<Player, number>` (v2; never
  fires in v1). `workspace.FireTruck67` exists from boot, parked at the Station.

**Integration points:** MissionService (G3) calls `ParkAt(missionId)` at the end of the Alarm phase and
`ResetTruck()` after Results. ToolService (G1) refills at the `Reel` prompt. RescueService (G3) delivers inside
`RescueDropoff`.

- [ ] **Step 1: Branch**

```bash
git switch main && git pull --rebase && git switch -c g2/vehicle
```

- [ ] **Step 2: Write the failing Play check**

`start_stop_play {"is_start": true, "studio_id": "<id>"}`, then (`Server`):

```lua
local t0 = os.clock()
repeat task.wait(0.25) until workspace:GetAttribute("MapReady") or os.clock() - t0 > 15
task.wait(1)
local CS = game:GetService("CollectionService")
local DevHook = game.ServerStorage.DevHook
local _, truck = DevHook:Invoke("VehicleService", "GetTruck")
if not truck then
	return "FAIL: no truck"
end
local home = truck:GetPivot().Position
local _, parkedTown = DevHook:Invoke("VehicleService", "ParkAt", "Town")
local town = truck:GetPivot().Position
DevHook:Invoke("VehicleService", "ResetTruck")
local back = truck:GetPivot().Position
local _, pass, msg = DevHook:Invoke("VehicleService", "_selftest")
return string.format("home=%s parkTown=%s town=%s back=%s refill=%d dropoff=%d trucks=%d selftest=%s/%s",
	tostring(home), tostring(parkedTown), tostring(town), tostring(back), #CS:GetTagged("TruckRefill"),
	#CS:GetTagged("RescueDropoff"), #CS:GetTagged("Truck"), tostring(pass), tostring(msg))
```

- [ ] **Step 3: Run it, expect FAIL**

Expected with the stub: `FAIL: no truck`. Stop the playtest.

- [ ] **Step 4: Replace `game/ServerScriptService/Services/VehicleService.luau` with:**

```lua
--!strict
-- VehicleService [owner: G2]. Truck 67: built once at boot by Lib/Map/Props/TruckBuilder and parked on
-- a location's TruckSpot marker. Static in v1 (players teleport with it); drivable in v2.
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   VehicleService:GetTruck(): Model?
--   VehicleService:ResetTruck()                         -- ParkAt(VehicleConfig.HomeLocation)
--   VehicleService:ParkAt(locationId: string): boolean  -- truck ground point onto that location's TruckSpot
-- Signals: Driven(driver: Player, studs: number)        -- v2 only; never fires in v1
-- Writes: workspace.FireTruck67 (tag Truck; parts "Reel" tag TruckRefill, "RescueDropoff" tag RescueDropoff)
-- Test hooks (DevHook only): _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local VehicleConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("VehicleConfig") :: ModuleScript)
local TruckBuilder = require(
	ServerScriptService:WaitForChild("Lib"):WaitForChild("Map"):WaitForChild("Props"):WaitForChild("TruckBuilder") :: ModuleScript
)

local VehicleService = {}
VehicleService.Priority = 50
VehicleService.Driven = Signal.new() :: Signal.Signal<Player, number>

local services: { [string]: any } = {}
local truck: Model? = nil
-- TruckBuilder's PrimaryPart (Chassis) sits 2 studs above the ground point it was built on, so the
-- Model pivot is not the ground point. Remember the offset once and apply it on every park.
local groundToPivot = CFrame.identity
local parkedAt: string? = nil

local function findSpot(locationId: string): BasePart?
	local Map = services.MapService
	local location = Map and Map:GetLocation(locationId)
	if not location then
		return nil
	end
	for _, d in location:GetDescendants() do
		if d:IsA("BasePart") and d:HasTag(Names.Tag.TruckSpot) then
			return d
		end
	end
	return nil
end

function VehicleService:Init(all: { [string]: any })
	services = all
end

function VehicleService:Start()
	local t0 = os.clock()
	while workspace:GetAttribute(Names.Attr.MapReady) ~= true and os.clock() - t0 < 10 do
		task.wait(0.1)
	end
	local home = VehicleConfig.HomeLocation
	local spot = findSpot(home)
	local cf = if spot then spot.CFrame else CFrame.new(0, 0.2, 0)
	local m = TruckBuilder.Build(workspace, cf)
	groundToPivot = cf:Inverse() * m:GetPivot()
	local dropoff = m:FindFirstChild("RescueDropoff")
	if dropoff and dropoff:IsA("BasePart") then
		dropoff.CanQuery = false -- invisible volume must not block raycasts
	end
	truck = m
	parkedAt = if spot then home else nil
	local Map = services.MapService
	if Map then
		-- a rebuilt location recreates its TruckSpot (same place, same seed); re-park to be safe
		Map.LocationBuilt:Connect(function(_model: Model, id: string)
			if id == parkedAt then
				VehicleService:ParkAt(id)
			end
		end)
	end
	print(`[VehicleService] truck {VehicleConfig.TruckNumber} parked at {parkedAt or "origin (no TruckSpot)"}`)
end

function VehicleService:GetTruck(): Model?
	return truck
end

function VehicleService:ParkAt(locationId: string): boolean
	local spot = findSpot(locationId)
	if not truck or not spot then
		return false
	end
	truck:PivotTo(spot.CFrame * groundToPivot)
	parkedAt = locationId
	return true
end

function VehicleService:ResetTruck()
	VehicleService:ParkAt(VehicleConfig.HomeLocation)
end

function VehicleService:_selftest(): (boolean, string)
	if not truck then
		return false, "no truck built"
	end
	if not truck:HasTag(Names.Tag.Truck) then
		return false, "truck not tagged Truck"
	end
	if not VehicleService:ParkAt(VehicleConfig.HomeLocation) then
		return false, `no TruckSpot at {VehicleConfig.HomeLocation}`
	end
	return true, `parked at {parkedAt}`
end

return VehicleService
```

- [ ] **Step 5: Compile check**

Run: `python3 game/tools/sync.py check --root game` → `OK: checked N files, 0 failed`.

- [ ] **Step 6: Re-run the Step 2 check**

Expected: `home=18, 2.2, 0 parkTown=true town=400, 2.2, -32 back=18, 2.2, 0 refill=1 dropoff=1 trucks=1
selftest=true/parked at Station`. Pivot Y is 2.2 because the chassis centre is 2 studs above the 0.2 ground; small
float noise is fine. `screen_capture` while parked at the Station shows the truck in the bay facing the bay door.
Read `ForgeProbe:Invoke("report")`: `errors == []`. Stop the playtest.

- [ ] **Step 7: Commit and PR**

```bash
git add game/ServerScriptService/Services/VehicleService.luau
git commit -m "game(vehicle): build truck 67 at boot, ParkAt/ResetTruck on TruckSpot markers"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

**P0 checkpoint for G2 (Sat 10:00):** on `main`, a solo Play gives `workspace.Map.Station` and `workspace.Map.Town`
with the counts above, truck 67 in the station bay, dusk lighting, `errors == []`.

---

### Task G2.6: AlarmController + VehicleController  (Dev A, G2, 1.0 h, P1)

**Files:**
- Modify: `game/StarterPlayerScripts/Controllers/AlarmController.luau` (replace the Task 0 stub)
- Modify: `game/StarterPlayerScripts/Controllers/VehicleController.luau` (replace the Task 0 stub)

**Interfaces:**
- Consumes: remote `Mission/Alarm` (S→C all, `missionId: string, locationName: string`, declared by MissionService),
  `GameConfig.AlarmSeconds` (G3, read-only), tags `AlarmLamp` (G2.2) and `Truck` (G2.5), truck parts
  `LightRed` / `LightBlue` / `LightWhite` (G2.4), Workspace attr `RoundState`.
- Produces: client-only visuals. Nothing replicates and nothing affects gameplay.

**Integration point:** the alarm fires for real once G3's MissionService sends `Mission/Alarm` at round start.
Until then, fire the remote by hand (Step 6).

- [ ] **Step 1: Branch**

```bash
git switch main && git pull --rebase && git switch -c g2/alarm-lights
```

- [ ] **Step 2: Write the failing Client check**

`start_stop_play {"is_start": true}`. Server (`Server`):

```lua
game.ReplicatedStorage:WaitForChild("Net"):WaitForChild("Mission"):WaitForChild("Alarm"):FireAllClients("Town", "12 Maple St")
workspace:SetAttribute("RoundState", "Alarm")
return "fired"
```

Then immediately Client (`"datamodel_type": "Client"`):

```lua
task.wait(0.5)
local CS = game:GetService("CollectionService")
local lamp = CS:GetTagged("AlarmLamp")[1]
local light = lamp and lamp:FindFirstChild("AlarmLight")
local cc = game.Lighting:FindFirstChild("AlarmCC")
local truck = CS:GetTagged("Truck")[1]
local seen = {}
for _ = 1, 8 do
	if truck and truck:FindFirstChild("LightRed") then
		seen[truck.LightRed.Transparency] = true
	end
	task.wait(0.1)
end
local distinct = 0
for _ in seen do
	distinct += 1
end
return string.format("lightOn=%s cc=%s ccEnabled=%s redStates=%d",
	tostring(light ~= nil and light.Enabled), tostring(cc ~= nil), tostring(cc ~= nil and cc.Enabled), distinct)
```

- [ ] **Step 3: Run it, expect FAIL**

Expected with the stubs: `lightOn=false cc=false ccEnabled=false redStates=1`. Stop the playtest.

- [ ] **Step 4: Replace `game/StarterPlayerScripts/Controllers/AlarmController.luau` with:**

```lua
--!strict
-- AlarmController [owner: G2]. Client-only alarm look (docs/game/02 §2 "Alarm" overlay). On
-- Mission/Alarm: the station's AlarmLamp parts spin (local CFrame) with their AlarmLight/AlarmSpot on,
-- and a local ColorCorrection "AlarmCC" pulses white <-> red at 1 Hz for 3 s. Everything is restored
-- after GameConfig.AlarmSeconds. Nothing here affects gameplay.
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local GameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GameConfig") :: ModuleScript)

local AlarmController = {}
AlarmController.Priority = 60

local running = false
local RED = Color3.fromRGB(255, 80, 80)

local function setLights(lamp: BasePart, on: boolean)
	for _, name in { "AlarmLight", "AlarmSpot" } do
		local l = lamp:FindFirstChild(name)
		if l and l:IsA("Light") then
			l.Enabled = on
		end
	end
end

local function runAlarm()
	if running then
		return
	end
	running = true
	local seconds = GameConfig.AlarmSeconds
	local lamps: { BasePart } = {}
	local base: { [BasePart]: CFrame } = {}
	for _, inst in CollectionService:GetTagged(Names.Tag.AlarmLamp) do
		if inst:IsA("BasePart") then
			table.insert(lamps, inst)
			base[inst] = inst.CFrame
			setLights(inst, true)
		end
	end
	local cc = Lighting:FindFirstChild("AlarmCC") :: ColorCorrectionEffect?
	if not cc then
		local made = Instance.new("ColorCorrectionEffect")
		made.Name = "AlarmCC"
		made.Parent = Lighting
		cc = made
	end
	local effect = cc :: ColorCorrectionEffect
	effect.Enabled = true
	local t = 0
	local conn = RunService.RenderStepped:Connect(function(dt: number)
		t += dt
		for _, lamp in lamps do
			if lamp.Parent then
				lamp.CFrame = base[lamp] * CFrame.Angles(0, t * 2 * math.pi, 0) -- 360 degrees per second
			end
		end
		local pulse = if t < 3 then (math.sin(t * 2 * math.pi) + 1) / 2 else 0
		effect.TintColor = Color3.new(1, 1, 1):Lerp(RED, pulse * 0.7)
	end)
	task.wait(seconds)
	conn:Disconnect()
	for _, lamp in lamps do
		if lamp.Parent then
			lamp.CFrame = base[lamp]
			setLights(lamp, false)
		end
	end
	effect.TintColor = Color3.new(1, 1, 1)
	effect.Enabled = false
	running = false
end

function AlarmController:Init(_controllers: { [string]: any }) end

function AlarmController:Start()
	local Alarm = Net.event("Mission", "Alarm")
	Alarm.OnClientEvent:Connect(function(_missionId: string, _locationName: string)
		task.spawn(runAlarm)
	end)
end

return AlarmController
```

- [ ] **Step 5: Replace `game/StarterPlayerScripts/Controllers/VehicleController.luau` with:**

```lua
--!strict
-- VehicleController [owner: G2]. Client-only truck look: while Workspace RoundState is "Alarm" or
-- "Active", truck 67's roof light bar (TruckBuilder parts LightRed / LightBlue / LightWhite) flashes
-- red/blue at ~3 Hz with local PointLights. Otherwise the bar is dimmed. Local changes only.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)

local VehicleController = {}
VehicleController.Priority = 60

local function glow(part: BasePart, color: Color3): PointLight
	local l = part:FindFirstChild("FlashLight") :: PointLight?
	if l then
		return l
	end
	local made = Instance.new("PointLight")
	made.Name = "FlashLight"
	made.Color = color
	made.Range = 18
	made.Brightness = 4
	made.Parent = part
	return made
end

local function bar(truck: Model): (BasePart?, BasePart?, BasePart?)
	local r = truck:FindFirstChild("LightRed")
	local b = truck:FindFirstChild("LightBlue")
	local w = truck:FindFirstChild("LightWhite")
	return if r and r:IsA("BasePart") then r else nil,
		if b and b:IsA("BasePart") then b else nil,
		if w and w:IsA("BasePart") then w else nil
end

function VehicleController:Init(_controllers: { [string]: any }) end

function VehicleController:Start()
	local phase = false
	while true do
		task.wait(0.16)
		local truck = CollectionService:GetTagged(Names.Tag.Truck)[1]
		if truck and truck:IsA("Model") then
			local r, b, w = bar(truck)
			local state = workspace:GetAttribute(Names.Attr.RoundState)
			local flashing = state == "Alarm" or state == "Active"
			phase = not phase
			if r then
				r.Transparency = if flashing and not phase then 0.7 else (if flashing then 0 else 0.5)
				glow(r, Color3.fromRGB(255, 45, 45)).Enabled = flashing and phase
			end
			if b then
				b.Transparency = if flashing and phase then 0.7 else (if flashing then 0 else 0.5)
				glow(b, Color3.fromRGB(45, 120, 255)).Enabled = flashing and not phase
			end
			if w then
				w.Transparency = if flashing then (if math.random() < 0.5 then 0 else 0.6) else 0.5
			end
		end
	end
end

return VehicleController
```

Run: `python3 game/tools/sync.py check --root game` → `OK: checked N files, 0 failed`.

- [ ] **Step 6: Re-run the Step 2 checks**

Expected within the 6 s alarm window: `lightOn=true cc=true ccEnabled=true redStates=2` (or 3). Take a
`screen_capture` during the alarm: red tint, lamps lit. Wait 7 s, then (Client):

```lua
local lamp = game:GetService("CollectionService"):GetTagged("AlarmLamp")[1]
local cc = game.Lighting:FindFirstChild("AlarmCC")
return string.format("lightOn=%s ccEnabled=%s", tostring(lamp.AlarmLight.Enabled), tostring(cc and cc.Enabled))
```

Expected `lightOn=false ccEnabled=false`. Then on the Server set `workspace:SetAttribute("RoundState", "Lobby")` and
check `redStates=1` again (the bar stops flashing). If G3's MissionService has already landed, first stop auto rounds with
`game.ServerStorage.DevHook:Invoke("GameConfig", ".Set", "AutoStart", false)`. Stop the playtest.

- [ ] **Step 7: Commit and PR**

```bash
git add game/StarterPlayerScripts/Controllers/AlarmController.luau game/StarterPlayerScripts/Controllers/VehicleController.luau
git commit -m "game(fx): station alarm lamps + red pulse on Mission/Alarm; truck light bar flashes during rounds"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

---

### Task G2.7: HintService (world hints)  (Dev A, G2, 0.75 h, P1.5)

**Files:**
- Create: `game/ServerScriptService/Services/HintService.luau` (new G2 file, auto-booted; name is unique)

**Interfaces:**
- Consumes: `MapKit.billboard` (G2.1), tags `Hydrant` (Station + Town), `TruckRefill`, `RescueDropoff` (truck).
- Produces: a `BillboardGui` named `"Hint"` on each of those parts: `REFILL` (UiWater) on 4 hydrant bodies and the
  truck reel, `BRING RESCUES HERE` (UiGood) on the truck drop-off. It survives `RebuildLocation("Town")` because it
  listens to `CollectionService:GetInstanceAddedSignal`. Test hook `_count(): number`.
  (Street lamps and trees already ship in G2.3.)

- [ ] **Step 1: Branch**

```bash
git switch main && git pull --rebase && git switch -c g2/hints
```

- [ ] **Step 2: Write the failing Play check**

`start_stop_play {"is_start": true}`, then (`Server`):

```lua
local t0 = os.clock()
repeat task.wait(0.25) until workspace:GetAttribute("MapReady") or os.clock() - t0 > 15
task.wait(1)
local CS = game:GetService("CollectionService")
local function hints(): number
	local n = 0
	for _, tag in { "Hydrant", "TruckRefill", "RescueDropoff" } do
		for _, p in CS:GetTagged(tag) do
			if p:FindFirstChild("Hint") then
				n += 1
			end
		end
	end
	return n
end
local before = hints()
game.ServerStorage.DevHook:Invoke("MapService", "RebuildLocation", "Town")
task.wait(0.5)
return string.format("hints=%d afterRebuild=%d", before, hints())
```

- [ ] **Step 3: Run it, expect FAIL**

Expected without HintService: `hints=0 afterRebuild=0`. Stop the playtest.

- [ ] **Step 4: Create `game/ServerScriptService/Services/HintService.luau`:**

```lua
--!strict
-- HintService [owner: G2]. World-space hints (docs/game/05 §6 onboarding): a BillboardGui "Hint" over
-- every refill point ("REFILL") and over the truck drop-off ("BRING RESCUES HERE"). Driven purely by
-- CollectionService tags, so it covers map rebuilds and the truck without listening to other services.
-- Public API: none. Test hooks (DevHook only): _count(): number, _selftest()
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local MapKit = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Map"):WaitForChild("MapKit") :: ModuleScript)

type Hint = { tag: string, text: string, color: Color3, offsetY: number }

local HINTS: { Hint } = {
	{ tag = Names.Tag.Hydrant, text = "REFILL", color = Palette.UiWater, offsetY = 3 },
	{ tag = Names.Tag.TruckRefill, text = "REFILL", color = Palette.UiWater, offsetY = 3 },
	{ tag = Names.Tag.RescueDropoff, text = "BRING RESCUES HERE", color = Palette.UiGood, offsetY = 5 },
}

local HintService = {}
HintService.Priority = 90

local function add(inst: Instance, h: Hint)
	if inst:IsA("BasePart") and not inst:FindFirstChild("Hint") then
		MapKit.billboard(inst, h.text, h.color, h.offsetY)
	end
end

function HintService:Init(_all: { [string]: any }) end

function HintService:Start()
	for _, h in HINTS do
		CollectionService:GetInstanceAddedSignal(h.tag):Connect(function(inst: Instance)
			add(inst, h)
		end)
		for _, inst in CollectionService:GetTagged(h.tag) do
			add(inst, h)
		end
	end
end

function HintService:_count(): number
	local n = 0
	for _, h in HINTS do
		for _, inst in CollectionService:GetTagged(h.tag) do
			if inst:FindFirstChild("Hint") then
				n += 1
			end
		end
	end
	return n
end

function HintService:_selftest(): (boolean, string)
	local n = HintService:_count()
	return n > 0, `{n} hints`
end

return HintService
```

Run: `python3 game/tools/sync.py check --root game` → `OK: checked N files, 0 failed`.

- [ ] **Step 5: Re-run the Step 2 check**

Expected: `hints=6 afterRebuild=6` (4 hydrants + reel + drop-off). `screen_capture` from the Town street shows the
REFILL labels over the hydrants. ForgeProbe `errors == []`. Stop the playtest.

- [ ] **Step 6: Commit and PR**

```bash
git add game/ServerScriptService/Services/HintService.luau
git commit -m "game(map): world hints over refill points and the truck drop-off"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

**G2 lane total: about 6.5 h** (G2.1 1.0, G2.2 1.0, G2.3 1.5, G2.4 0.5, G2.5 0.75 = 4.75 h of P0; G2.6 1.0 P1;
G2.7 0.75 P1.5).

---

## Lane G3: Loop & people (Dev C)

G3 owns the round and everything that happens to people: the state machine (Lobby → Alarm → Active → Results →
Lobby), the HUD, the crew (helmet numbers, spawn, costume, Downed/revive), the civilians and pets you carry to the
truck, and the Blame screen. Everything here works against the K0 stubs, so you never wait on G1 or G2. When their PRs
land, the **Integration point** checks light up.

**Files you own (and only these):** `game/ServerScriptService/Services/{MissionService,RescueService,SquadService,BlameService,KillFeedService}.luau`,
`game/ServerScriptService/Lib/Blame/Awards.luau`, `game/ServerScriptService/Lib/Rescue/RescueNpcBuilder.luau`,
`game/ServerScriptService/Lib/Squad/CostumeBuilder.luau`, `game/ReplicatedStorage/Config/{GameConfig,RescueConfig,BlameConfig}.luau`,
`game/StarterPlayerScripts/Controllers/{HudController,ResultsController,RescueController}.luau`,
`game/StarterPlayerScripts/ClientLib/UiKit.luau`, `game/tests/awards.spec.luau`.
(`KillFeedService` is a new G3 service, which is lane-internal: auto-discovery boots it and nothing else changes.)

**Order and deadlines.** P0 by **Sat 10:00**: G3.1 Awards, G3.2 MissionService, G3.3 HUD, G3.4 Squad.
P1 by **Sat 14:00**: G3.5 Rescue, G3.6 Blame, G3.7 Results, G3.8 Downed. P1.5 by **Sat 18:00**: G3.9 KillFeed.
Total about 10.5 h.

**Every task's loop.** Keep `.venv/bin/forge watch --studio Forge` running against **your local place**
(`place/Forge.rbxlx`; never the shared "Firefighter Mubit" place). For each live check:
1. `mcp__Roblox_Studio__list_roblox_studios` → take the `id` whose name contains `Forge` (not one showing a `placeId`).
2. `mcp__Roblox_Studio__start_stop_play {"is_start": true, "studio_id": "<id>"}`, then poll
   `mcp__Roblox_Studio__get_studio_state {"studio_id": "<id>"}` until a `Server` datamodel is listed.
3. Run the task's `mcp__Roblox_Studio__execute_luau` blocks **in the order given, within ~10 s of pressing Play**
   (the lobby auto-starts a round after `LobbySeconds = 10`; every check turns `AutoStart` off first).
4. Always finish with `mcp__Roblox_Studio__start_stop_play {"is_start": false, "studio_id": "<id>"}`, even after a failure.

---

### Task G3.1: Awards, pure Blame scoring + spec  (Dev C, G3, 0.75 h, P0)

**Files:**
- Create: `game/ServerScriptService/Lib/Blame/Awards.luau`
- Test: `game/tests/awards.spec.luau`

**Interfaces:**
- Consumes: `game/tests/Spec.luau` (K0), the shape of `Types.PlayerStats` / `Types.Award` (K0, mirrored locally so the module stays pure).
- Produces: `Awards.build(stats: { PlayerStats }, maxPerPlayer: number): { Award }`,
  `Awards.stars(burningAtEnd: number, rescued: number, trapped: number): number`,
  `Awards.blameScore(s: PlayerStats): number`. Used by MissionService (G3.2) and BlameService (G3.6).
  Award ids, in priority order: `panda` "Panda Whisperer", `friendly_hose` "Friendly Fire Department",
  `arsonist` "Arsonist (Probably)", `crispy` "Crispy Critter", `door_hater` "Door Hater", `hero` "Hero of Maple Street",
  `hydrant_hugger` "Hydrant Hugger", `pro` "Professional Firefighter", fallback `moral_support` "Moral Support",
  and always last `scapegoat` ("Firefighter 0X is to blame." / solo "You are to blame.").

- [ ] **Step 1: Branch and write the failing spec**

```bash
git switch main && git pull --rebase && git switch -c g3/awards
```

`game/tests/awards.spec.luau`:

```lua
--!strict
-- Awards: Blame awards and stars (docs/game/05-content-missions.md §7, docs/game/01-gameplay-systems.md §10).
local Spec = require("./Spec")
local Awards = require("../ServerScriptService/Lib/Blame/Awards")

local function stats(userId: number, helmet: number, over: { [string]: number }?): any
	local s: { [string]: any } = {
		userId = userId,
		helmet = helmet,
		name = `P{userId}`,
		firesOut = 0,
		firesStarted = 0,
		water = 0,
		doors = 0,
		rescued = 0,
		pandas = 0,
		downedOthers = 0,
		timesDowned = 0,
		teammateSprayed = 0,
	}
	for k, v in over or {} do
		s[k] = v
	end
	return s
end

local function byUser(awards: { any }, userId: number): { any }
	local out = {}
	for _, a in awards do
		if a.userId == userId and a.id ~= "scapegoat" then
			table.insert(out, a)
		end
	end
	return out
end

local function find(awards: { any }, id: string): any
	for _, a in awards do
		if a.id == id then
			return a
		end
	end
	return nil
end

Spec.test("no players -> no awards", function()
	Spec.eq(#Awards.build({}, 2), 0)
end)

Spec.test("solo idle player gets Moral Support and 'You are to blame.'", function()
	local list = Awards.build({ stats(1, 1) }, 2)
	Spec.eq(#list, 2, "count")
	Spec.eq(list[1].id, "moral_support")
	Spec.eq(list[2].id, "scapegoat")
	Spec.eq(list[2].title, "You are to blame.")
	Spec.eq(list[2].blame, true)
end)

Spec.test("scapegoat names the helmet in multiplayer", function()
	local list = Awards.build({ stats(1, 1), stats(2, 2, { firesStarted = 4 }) }, 2)
	local s = find(list, "scapegoat")
	Spec.eq(s.title, "Firefighter 02 is to blame.")
	Spec.eq(s.userId, 2)
	Spec.eq(list[#list].id, "scapegoat", "scapegoat is last")
end)

Spec.test("panda comes first (funniest first)", function()
	local list = Awards.build({ stats(1, 1, { pandas = 1, rescued = 3, firesOut = 9 }) }, 2)
	Spec.eq(list[1].id, "panda")
	Spec.eq(list[1].title, "Panda Whisperer")
end)

Spec.test("max awards per player (scapegoat not counted)", function()
	local s = stats(1, 1, { pandas = 1, teammateSprayed = 5, firesStarted = 5, timesDowned = 2, doors = 3, rescued = 4, water = 300, firesOut = 9 })
	local list = Awards.build({ s }, 2)
	Spec.eq(#byUser(list, 1), 2, "regular awards")
	Spec.truthy(find(list, "scapegoat"), "scapegoat present")
end)

Spec.test("every player gets at least one award", function()
	local list = Awards.build({ stats(1, 1, { pandas = 1, firesOut = 9 }), stats(2, 2), stats(3, 3) }, 2)
	for _, uid in { 1, 2, 3 } do
		Spec.truthy(#byUser(list, uid) >= 1, `player {uid}`)
	end
	Spec.eq(byUser(list, 2)[1].id, "moral_support")
end)

Spec.test("thresholds: below the minimum gives nothing", function()
	local list = Awards.build({ stats(1, 1, { firesOut = 4, rescued = 1, doors = 1 }) }, 2)
	Spec.eq(find(list, "pro"), nil, "pro needs 5")
	Spec.eq(find(list, "hero"), nil, "hero needs 2")
	Spec.eq(find(list, "door_hater"), nil, "door hater needs 2")
end)

Spec.test("highest wins; ties go to the lower helmet", function()
	local list = Awards.build({ stats(10, 2, { firesOut = 6 }), stats(11, 1, { firesOut = 6 }), stats(12, 3, { firesOut = 9 }) }, 2)
	Spec.eq(find(list, "pro").userId, 12)
	local tie = Awards.build({ stats(10, 2, { rescued = 3 }), stats(11, 1, { rescued = 3 }) }, 2)
	Spec.eq(find(tie, "hero").userId, 11)
end)

Spec.test("blurb includes the value", function()
	local list = Awards.build({ stats(1, 1, { doors = 3 }) }, 2)
	Spec.eq(find(list, "door_hater").blurb, "Broke 3 doors. Some were even locked.")
end)

Spec.test("blame score", function()
	Spec.eq(Awards.blameScore(stats(1, 1, { firesStarted = 2, downedOthers = 1, teammateSprayed = 3, timesDowned = 1 })), 8)
end)

Spec.test("stars", function()
	Spec.eq(Awards.stars(4, 0, 5), 1, "burning and nobody saved")
	Spec.eq(Awards.stars(0, 0, 5), 2, "all fires out")
	Spec.eq(Awards.stars(3, 5, 0), 2, "everyone saved")
	Spec.eq(Awards.stars(0, 5, 0), 3, "perfect")
	Spec.eq(Awards.stars(0, 0, 0), 2, "nothing to save does not earn the rescue star")
end)

return Spec.finish()
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash game/tests/run.sh`
Expected: FAIL, exit 1, with
`error requiring module "../ServerScriptService/Lib/Blame/Awards": could not resolve child component "Awards"`.

- [ ] **Step 3: Write `game/ServerScriptService/Lib/Blame/Awards.luau`**

```lua
--!strict
-- Awards [owner: G3]. Pure Blame-award selection and stars. No Roblox APIs, so the `luau` CLI tests it
-- (game/tests/awards.spec.luau). Sources: docs/game/05-content-missions.md §7, docs/game/01-gameplay-systems.md §10.
--
--   Awards.build(stats: { PlayerStats }, maxPerPlayer: number): { Award }
--       Catalog in priority order (funny first). Each award goes to the player with the highest stat (>= its
--       minimum; ties -> lower helmet, then lower userId), skipping players who already hold maxPerPlayer.
--       Players left with nothing get "Moral Support". The last entry is always the Scapegoat line
--       (highest blameScore): "Firefighter 0X is to blame." or, solo, "You are to blame.".
--   Awards.stars(burningAtEnd: number, rescued: number, trapped: number): number   -- 1..3
--   Awards.blameScore(s: PlayerStats): number
-- Types mirror ReplicatedStorage/Shared/Types.luau (PlayerStats, Award); kept local so this file stays pure.

export type PlayerStats = {
	userId: number,
	helmet: number,
	name: string,
	firesOut: number,
	firesStarted: number,
	water: number,
	doors: number,
	rescued: number,
	pandas: number,
	downedOthers: number,
	timesDowned: number,
	teammateSprayed: number,
}
export type Award = { id: string, title: string, userId: number, value: number, blurb: string, blame: boolean }

type Entry = {
	id: string,
	title: string,
	blame: boolean,
	min: number,
	stat: (PlayerStats) -> number,
	blurb: (number) -> string,
}

local Awards = {}

local CATALOG: { Entry } = {
	{
		id = "panda",
		title = "Panda Whisperer",
		blame = false,
		min = 1,
		stat = function(s)
			return s.pandas
		end,
		blurb = function(_v)
			return "Carried the panda to safety. It is still confused."
		end,
	},
	{
		id = "friendly_hose",
		title = "Friendly Fire Department",
		blame = true,
		min = 3,
		stat = function(s)
			return s.teammateSprayed
		end,
		blurb = function(v)
			return `Hosed a teammate {v} times. On purpose, probably.`
		end,
	},
	{
		id = "arsonist",
		title = "Arsonist (Probably)",
		blame = true,
		min = 3,
		stat = function(s)
			return s.firesStarted
		end,
		blurb = function(v)
			return `Was standing right there when {v} fires spread.`
		end,
	},
	{
		id = "crispy",
		title = "Crispy Critter",
		blame = true,
		min = 1,
		stat = function(s)
			return s.timesDowned
		end,
		blurb = function(v)
			return if v == 1 then "Got toasted once. Medium rare." else `Got toasted {v} times. Well done.`
		end,
	},
	{
		id = "door_hater",
		title = "Door Hater",
		blame = true,
		min = 2,
		stat = function(s)
			return s.doors
		end,
		blurb = function(v)
			return `Broke {v} doors. Some were even locked.`
		end,
	},
	{
		id = "hero",
		title = "Hero of Maple Street",
		blame = false,
		min = 2,
		stat = function(s)
			return s.rescued
		end,
		blurb = function(v)
			return `Carried {v} lives to the truck.`
		end,
	},
	{
		id = "hydrant_hugger",
		title = "Hydrant Hugger",
		blame = false,
		min = 150,
		stat = function(s)
			return math.floor(s.water)
		end,
		blurb = function(v)
			return `Sprayed {v} litres. The lawn has never been greener.`
		end,
	},
	{
		id = "pro",
		title = "Professional Firefighter",
		blame = false,
		min = 5,
		stat = function(s)
			return s.firesOut
		end,
		blurb = function(v)
			return `Put out {v} fires. Technically the job.`
		end,
	},
}

local FALLBACK = { id = "moral_support", title = "Moral Support", blurb = "Was definitely there." }

function Awards.blameScore(s: PlayerStats): number
	return s.firesStarted + 2 * s.downedOthers + s.teammateSprayed + s.timesDowned
end

-- true if a ranks above b: higher value, then lower helmet, then lower userId
local function better(av: number, a: PlayerStats, bv: number, b: PlayerStats): boolean
	if av ~= bv then
		return av > bv
	end
	if a.helmet ~= b.helmet then
		return a.helmet < b.helmet
	end
	return a.userId < b.userId
end

function Awards.build(stats: { PlayerStats }, maxPerPlayer: number): { Award }
	local out: { Award } = {}
	if #stats == 0 then
		return out
	end
	local held: { [number]: number } = {}
	for _, entry in CATALOG do
		local best: PlayerStats? = nil
		local bestV = 0
		for _, s in stats do
			local v = entry.stat(s)
			if v >= entry.min and (held[s.userId] or 0) < maxPerPlayer then
				if best == nil or better(v, s, bestV, best) then
					best, bestV = s, v
				end
			end
		end
		if best then
			held[best.userId] = (held[best.userId] or 0) + 1
			table.insert(out, {
				id = entry.id,
				title = entry.title,
				userId = best.userId,
				value = bestV,
				blurb = entry.blurb(bestV),
				blame = entry.blame,
			})
		end
	end
	for _, s in stats do
		if (held[s.userId] or 0) == 0 then
			table.insert(out, {
				id = FALLBACK.id,
				title = FALLBACK.title,
				userId = s.userId,
				value = 0,
				blurb = FALLBACK.blurb,
				blame = false,
			})
		end
	end
	local goat = stats[1]
	local goatV = Awards.blameScore(goat)
	for i = 2, #stats do
		local v = Awards.blameScore(stats[i])
		if better(v, stats[i], goatV, goat) then
			goat, goatV = stats[i], v
		end
	end
	table.insert(out, {
		id = "scapegoat",
		title = if #stats == 1 then "You are to blame." else string.format("Firefighter %02d is to blame.", goat.helmet),
		userId = goat.userId,
		value = goatV,
		blurb = if goatV == 0 then "Nobody did anything wrong. Suspicious." else `Blame score {goatV}.`,
		blame = true,
	})
	return out
end

function Awards.stars(burningAtEnd: number, rescued: number, trapped: number): number
	local stars = 1
	if burningAtEnd == 0 then
		stars += 1
	end
	if trapped == 0 and rescued > 0 then
		stars += 1
	end
	return stars
end

return Awards
```

- [ ] **Step 4: Run the specs and the compile check**

Run: `bash game/tests/run.sh`
Expected: `11 passed, 0 failed` for `awards.spec.luau`, `3 passed, 0 failed` for `config.spec.luau`, exit 0.
Run: `python3 game/tools/sync.py check --root game`
Expected: `OK: checked N files, 0 failed`.
(No live check: this module is pure and is exercised live through G3.2 and G3.6.)

- [ ] **Step 5: Commit and PR**

```bash
git add game/ServerScriptService/Lib/Blame/Awards.luau game/tests/awards.spec.luau
git commit -m "game(blame): pure Awards.build/stars with luau spec"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch   # once CI (luau-compile, luau specs, pytest) is green
```

---

### Task G3.2: MissionService, the round state machine  (Dev C, G3, 1.5 h, P0)

**Files:**
- Modify (replace the K0 stub): `game/ServerScriptService/Services/MissionService.luau`

**Interfaces:**
- Consumes (all nil-guarded, all fine as K0 stubs): `MapService:GetLocation(id)`, `MapService:RandomFlammable(id, rng)`,
  `MapService:RebuildLocation(id)`, `VehicleService:ParkAt(id)`, `VehicleService:GetTruck()`,
  `VehicleService:ResetTruck()`, `ToolService:GiveLoadout(player)`, `RescueService:Spawn(id, count)`,
  `RescueService:Clear()`, `FireService:Ignite(part, nil)`, `FireService:CountBurning(id)`, `FireService:ExtinguishAll()`,
  `FireService.Extinguished`, `SquadService:RespawnAll()`, `BlameService:Reset()`, `BlameService:GetStats(player)`,
  `BlameService:BuildAwards()`, `Awards.stars` (G3.1), `GameConfig.*`, `RescueConfig.Count`, tags `FireStart`, `Rescuable`,
  attrs `RescueState`, `Charred`.
- Produces: `MissionService:StartRound(locationId: string?, seconds: number?)`, `MissionService:EndRound(reason: Types.EndReason)`,
  `MissionService:GetState(): Types.RoundState`, signals `RoundStarted(locationId)`, `RoundEnded(payload: Types.ResultsPayload)`,
  remotes `Mission/Alarm` (missionId, locationName) and `Mission/Results` (`Types.ResultsPayload`), Workspace attrs
  `RoundState`, `RoundEndsAt`, `MissionId`, counters `rounds_started`, `rounds_completed`, test hook `_startRound(id, seconds)`.

- [ ] **Step 1: Branch and run the live check against the K0 stub (it must fail)**

```bash
git switch main && git pull --rebase && git switch -c g3/mission
```

Start Play (loop above), then `mcp__Roblox_Studio__execute_luau` with `"datamodel_type": "Server"` and this `code`:

```lua
local HttpService = game:GetService("HttpService")
local DevHook = game.ServerStorage.DevHook
local t0 = os.clock()
repeat task.wait(0.25) until workspace:GetAttribute("ServerBooted") or os.clock() - t0 > 15
DevHook:Invoke("GameConfig", ".Set", "AutoStart", false)
DevHook:Invoke("GameConfig", ".Set", "AlarmSeconds", 2)
DevHook:Invoke("GameConfig", ".Set", "ResultsSeconds", 3)
if workspace:GetAttribute("RoundState") ~= "Lobby" then
	DevHook:Invoke("MissionService", "EndRound", "forced")
	repeat task.wait(0.25) until workspace:GetAttribute("RoundState") == "Lobby" or os.clock() - t0 > 20
end
local seen = {}
local conn = workspace:GetAttributeChangedSignal("RoundState"):Connect(function()
	table.insert(seen, tostring(workspace:GetAttribute("RoundState")))
end)
DevHook:Invoke("MissionService", "_startRound", "Town", 5)
repeat task.wait(0.25) until #seen >= 4 or os.clock() - t0 > 25
conn:Disconnect()
local report = HttpService:JSONDecode(game.ServerStorage.ForgeProbe:Invoke("report"))
return HttpService:JSONEncode({
	states = table.concat(seen, ">"),
	rounds_started = report.counters.rounds_started,
	rounds_completed = report.counters.rounds_completed,
	errors = #report.errors,
})
```

Expected with the stub: FAIL, i.e. `{"states":"","errors":0}` (no transitions, no counters). Stop Play.

- [ ] **Step 2: Write `game/ServerScriptService/Services/MissionService.luau`**

```lua
--!strict
-- MissionService [owner: G3]. The round state machine: Lobby -> Alarm -> Active -> Results -> Lobby.
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   MissionService:StartRound(locationId: string?, seconds: number?)   -- only from Lobby
--   MissionService:EndRound(reason: Types.EndReason)                   -- from Alarm or Active
--   MissionService:GetState(): Types.RoundState
-- Signals: RoundStarted(locationId: string), RoundEnded(payload: Types.ResultsPayload)
-- Remotes: Mission/Alarm (S->C all: missionId, locationName), Mission/Results (S->C all: ResultsPayload)
-- Writes: Workspace attrs RoundState, RoundEndsAt, MissionId; counters rounds_started, rounds_completed
-- Consumes (nil-guarded): MapService, VehicleService, ToolService, RescueService, FireService, SquadService,
--   BlameService. Works with K0 stubs: missing peers just mean that step is skipped.
-- Test hooks (DevHook only): _startRound(locationId, seconds), _selftest()
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Types = require(Shared:WaitForChild("Types") :: ModuleScript)
local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local GameConfig = require(ConfigFolder:WaitForChild("GameConfig") :: ModuleScript)
local RescueConfig = require(ConfigFolder:WaitForChild("RescueConfig") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local Awards = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Blame"):WaitForChild("Awards") :: ModuleScript)

local MissionService = {}
MissionService.Priority = 60
MissionService.RoundStarted = Signal.new() :: Signal.Signal<string>
MissionService.RoundEnded = Signal.new() :: Signal.Signal<Types.ResultsPayload>

local services: { [string]: any } = {}
local alarmRemote: RemoteEvent? = nil
local resultsRemote: RemoteEvent? = nil

local current: string? = nil -- mission (location) id of the round in progress
local roundSeconds = 0
local roundEndsAt = 0 -- workspace:GetServerTimeNow() time; 0 until Active
local activeSince = 0 -- os.clock() when the round went Active
local firesOut = 0 -- FireService.Extinguished count during this round

local function setState(state: Types.RoundState)
	workspace:SetAttribute(Names.Attr.RoundState, state)
end

-- Run one step of the round flow; a broken peer warns instead of killing the round.
local function safe(label: string, fn: () -> ())
	local ok, err = pcall(fn)
	if not ok then
		warn(`[MissionService] {label} failed: {err}`)
	end
end

local function location(id: string): Model?
	local Map = services.MapService
	return if Map then Map:GetLocation(id) else nil
end

-- rescued, still trapped (Trapped/Carried/Downed), total
local function rescueCounts(): (number, number, number)
	local rescued, trapped, total = 0, 0, 0
	for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
		total += 1
		local state = m:GetAttribute(Names.Attr.RescueState)
		if state == "Rescued" then
			rescued += 1
		else
			trapped += 1
		end
	end
	return rescued, trapped, total
end

local function charredCount(id: string): number
	local model = location(id)
	if not model then
		return 0
	end
	local n = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute(Names.Attr.Charred) == true then
			n += 1
		end
	end
	return n
end

-- Beside the truck if there is one, else above the location, else above the origin.
local function crewOrigin(id: string): CFrame
	local Vehicle = services.VehicleService
	local truck: Model? = if Vehicle then Vehicle:GetTruck() else nil
	if truck then
		return truck:GetPivot() * CFrame.new(-10, 4, 0)
	end
	local model = location(id)
	if model then
		local cf = model:GetBoundingBox()
		return CFrame.new(cf.Position + Vector3.new(0, 10, 0))
	end
	return CFrame.new(0, 10, 0)
end

local function teleportCrew(id: string)
	local base = crewOrigin(id)
	for i, player in Players:GetPlayers() do
		local char = player.Character
		if char and char:FindFirstChild("HumanoidRootPart") then
			char:PivotTo(base * CFrame.new(0, 0, (i - 2.5) * 4))
		end
	end
end

local function igniteStartFires(id: string): number
	local Fire = services.FireService
	if not Fire then
		return 0
	end
	local lit = 0
	local model = location(id)
	if model then
		for _, d in model:GetDescendants() do
			if lit >= GameConfig.StartFires then
				break
			end
			if d:IsA("BasePart") and d:HasTag(Names.Tag.FireStart) and Fire:Ignite(d, nil) then
				lit += 1
			end
		end
	end
	local Map = services.MapService
	local rng = Random.new(os.time())
	local tries = 0
	while Map and lit < GameConfig.StartFires and tries < 30 do
		tries += 1
		local part = Map:RandomFlammable(id, rng)
		if part and Fire:Ignite(part, nil) then
			lit += 1
		end
	end
	return lit
end

local function buildPayload(id: string, reason: Types.EndReason): Types.ResultsPayload
	local rescued, trapped = rescueCounts()
	local Fire = services.FireService
	local burning = if Fire then Fire:CountBurning(id) else 0
	local stats: { Types.PlayerStats } = {}
	local awards: { Types.Award } = {}
	local Blame = services.BlameService
	if Blame then
		for _, player in Players:GetPlayers() do
			table.insert(stats, Blame:GetStats(player))
		end
		awards = Blame:BuildAwards()
	end
	local played = 0
	if roundEndsAt > 0 then
		played = math.clamp(roundSeconds - (roundEndsAt - workspace:GetServerTimeNow()), 0, roundSeconds)
	end
	return {
		locationId = id,
		seconds = math.floor(played),
		firesOut = firesOut,
		burnedParts = charredCount(id),
		rescued = rescued,
		trapped = trapped,
		burningAtEnd = burning,
		stars = Awards.stars(burning, rescued, trapped),
		reason = reason,
		awards = awards,
		stats = stats,
	}
end

local function resetRound(id: string)
	safe("ExtinguishAll", function()
		local Fire = services.FireService
		if Fire then
			Fire:ExtinguishAll()
		end
	end)
	safe("Rescue:Clear", function()
		local Rescue = services.RescueService
		if Rescue then
			Rescue:Clear()
		end
	end)
	safe("RespawnAll", function()
		local Squad = services.SquadService
		if Squad then
			Squad:RespawnAll()
		end
	end)
	safe("RebuildLocation", function()
		local Map = services.MapService
		if Map then
			Map:RebuildLocation(id)
		end
	end)
	safe("ResetTruck", function()
		local Vehicle = services.VehicleService
		if Vehicle then
			Vehicle:ResetTruck()
		end
	end)
	current = nil
	roundEndsAt = 0
	workspace:SetAttribute(Names.Attr.RoundEndsAt, nil)
	setState("Lobby")
end

local function watchActive(id: string)
	while MissionService:GetState() == "Active" and current == id do
		task.wait(0.5)
		if MissionService:GetState() ~= "Active" or current ~= id then
			return
		end
		if workspace:GetServerTimeNow() >= roundEndsAt then
			MissionService:EndRound("time")
			return
		end
		if os.clock() - activeSince >= GameConfig.AllOutGraceSeconds then
			local Fire = services.FireService
			local burning = if Fire then Fire:CountBurning(id) else 0
			local _, trapped = rescueCounts()
			if burning == 0 and trapped == 0 then
				MissionService:EndRound("allOut")
				return
			end
		end
	end
end

local function runRound(id: string, seconds: number)
	task.wait(GameConfig.AlarmSeconds)
	if MissionService:GetState() ~= "Alarm" or current ~= id then
		return -- ended (forced) during the alarm
	end
	safe("ParkAt", function()
		local Vehicle = services.VehicleService
		if Vehicle then
			Vehicle:ParkAt(id)
		end
	end)
	safe("teleport", function()
		teleportCrew(id)
	end)
	safe("GiveLoadout", function()
		local Tool = services.ToolService
		if Tool then
			for _, player in Players:GetPlayers() do
				Tool:GiveLoadout(player)
			end
		end
	end)
	safe("Rescue:Spawn", function()
		local Rescue = services.RescueService
		if Rescue then
			Rescue:Spawn(id, RescueConfig.Count)
		end
	end)
	safe("start fires", function()
		igniteStartFires(id)
	end)
	roundEndsAt = workspace:GetServerTimeNow() + seconds
	activeSince = os.clock()
	workspace:SetAttribute(Names.Attr.RoundEndsAt, roundEndsAt)
	setState("Active")
	MissionService.RoundStarted:Fire(id)
	Telemetry.count("rounds_started")
	watchActive(id)
end

function MissionService:Init(all: { [string]: any })
	services = all
end

function MissionService:Start()
	alarmRemote = Net.event("Mission", "Alarm")
	resultsRemote = Net.event("Mission", "Results")
	setState("Lobby")

	local Fire = services.FireService
	if Fire then
		Fire.Extinguished:Connect(function(_part: BasePart, _by: Player?)
			if MissionService:GetState() == "Active" then
				firesOut += 1
			end
		end)
	end

	-- Lobby: start a round LobbySeconds after someone is in (solo works).
	task.spawn(function()
		while true do
			task.wait(1)
			if GameConfig.AutoStart and MissionService:GetState() == "Lobby" and #Players:GetPlayers() > 0 then
				local waited = 0
				while waited < GameConfig.LobbySeconds and GameConfig.AutoStart and MissionService:GetState() == "Lobby" do
					task.wait(0.5)
					waited += 0.5
				end
				if GameConfig.AutoStart and MissionService:GetState() == "Lobby" and #Players:GetPlayers() > 0 then
					MissionService:StartRound(GameConfig.DefaultMission, GameConfig.RoundSeconds)
				end
			end
		end
	end)
end

function MissionService:GetState(): Types.RoundState
	return (workspace:GetAttribute(Names.Attr.RoundState) :: any) or "Lobby"
end

function MissionService:StartRound(locationId: string?, seconds: number?)
	if self:GetState() ~= "Lobby" then
		warn(`[MissionService] StartRound ignored: state is {self:GetState()}`)
		return
	end
	local id = locationId or GameConfig.DefaultMission
	local secs = seconds or GameConfig.RoundSeconds
	current = id
	roundSeconds = secs
	roundEndsAt = 0
	firesOut = 0
	safe("Blame:Reset", function()
		local Blame = services.BlameService
		if Blame then
			Blame:Reset()
		end
	end)
	workspace:SetAttribute(Names.Attr.MissionId, id)
	setState("Alarm")
	if alarmRemote then
		alarmRemote:FireAllClients(id, GameConfig.LocationName)
	end
	Net.notify("all", `ALARM! Fire at {GameConfig.LocationName}!`, "bad")
	task.spawn(runRound, id, secs)
end

function MissionService:EndRound(reason: Types.EndReason)
	local state = self:GetState()
	if state ~= "Active" and state ~= "Alarm" then
		return
	end
	local id = current or GameConfig.DefaultMission
	setState("Results") -- first, so watchActive and runRound stop
	local payload = buildPayload(id, reason)
	if resultsRemote then
		resultsRemote:FireAllClients(payload)
	end
	MissionService.RoundEnded:Fire(payload)
	Telemetry.count("rounds_completed")
	print(`[MissionService] round over ({reason}): {payload.rescued} rescued, {payload.burningAtEnd} burning, {payload.stars} stars`)
	task.delay(GameConfig.ResultsSeconds, resetRound, id)
end

-- test hooks -------------------------------------------------------------------------------
function MissionService:_startRound(locationId: string, seconds: number)
	self:StartRound(locationId, seconds)
end

function MissionService:_selftest(): (boolean, string)
	local net = ReplicatedStorage:FindFirstChild("Net")
	local mission = net and net:FindFirstChild("Mission")
	if not (mission and mission:FindFirstChild("Alarm") and mission:FindFirstChild("Results")) then
		return false, "Mission remotes missing"
	end
	local state = self:GetState()
	if state ~= "Lobby" and state ~= "Alarm" and state ~= "Active" and state ~= "Results" then
		return false, `bad RoundState {tostring(state)}`
	end
	return true, `state {state}`
end

return MissionService
```

- [ ] **Step 3: Compile check**

Run: `python3 game/tools/sync.py check --root game`
Expected: `OK: checked N files, 0 failed`. `forge watch` prints `✓ ... MissionService.luau -> OK ...`.

- [ ] **Step 4: Live check again (now passes)**

Run the same Step 1 `execute_luau` block.
Expected: `{"states":"Alarm>Active>Results>Lobby","rounds_started":1,"rounds_completed":1,"errors":0}`
(`rounds_completed` is 2 if an auto round had already started before your check, because it is ended with "forced").
`mcp__Roblox_Studio__get_console_output` shows `[MissionService] round over (time): 0 rescued, 0 burning, 2 stars`
with K0 stubs (stars = 1 + 1 for "nothing burning"; no rescue star when nobody was rescued).
Also run the `_selftest` runner (Server):

```lua
local HttpService = game:GetService("HttpService")
local ok, pass, msg = game.ServerStorage.DevHook:Invoke("MissionService", "_selftest")
return HttpService:JSONEncode({ ok = ok, pass = pass, msg = msg })
```

Expected: `{"ok":true,"pass":true,"msg":"state Lobby"}`. Stop Play.

**Integration point (G2 merged: Town, truck):** start Play, leave `AutoStart` on and wait ~20 s: the alarm fires, you are
teleported beside truck 67 in the Town (not at `(0, 10, 0)`), and `workspace.Map.Town` is rebuilt after Results.
**Integration point (G1 merged):** after `Active`, `FireService:CountBurning("Town")` is 3 (FireStart parts):

```lua
local _, n = game.ServerStorage.DevHook:Invoke("FireService", "CountBurning", "Town")
return n
```

Expected (during `Active`): `3` or more (spread adds more).

- [ ] **Step 5: Commit and PR**

```bash
git add game/ServerScriptService/Services/MissionService.luau
git commit -m "game(mission): round state machine Lobby->Alarm->Active->Results with payload"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

---

### Task G3.3: UiKit + HudController  (Dev C, G3, 1.5 h, P0)

**Files:**
- Create: `game/StarterPlayerScripts/ClientLib/UiKit.luau`
- Modify (replace the K0 stub): `game/StarterPlayerScripts/Controllers/HudController.luau`

**Interfaces:**
- Consumes: Workspace attrs `RoundState`, `RoundEndsAt`, `MissionId` (G3.2); Player attrs `Water`, `TankSize` (G1 ToolService),
  `Downed` (G3.8); tags `Burning` (G1), `Rescuable` + attr `RescueState` (G3.5); remotes `Shared/Notify` (K0 bootstrap) and
  `Mission/Alarm` (G3.2); `Palette` (K0).
- Produces: `UiKit.screen(name, displayOrder?)`, `UiKit.panel(parent, name, size, position, anchor?)`,
  `UiKit.label(parent, name, text, size, position, opts?)`, `UiKit.pop(gui, duration?)`, `UiKit.tween(inst, seconds, props)`,
  `UiKit.clock(seconds): string`, `UiKit.kindColor(kind): Color3`, `UiKit.corner`, `UiKit.stroke`, `UiKit.Header`,
  `UiKit.Body`. Used by RescueController (G3.5) and ResultsController (G3.7). The `Hud` ScreenGui.

- [ ] **Step 1: Branch and run the failing client check**

```bash
git switch main && git pull --rebase && git switch -c g3/hud
```

Start Play. `execute_luau` with `"datamodel_type": "Client"`:

```lua
local HttpService = game:GetService("HttpService")
local pg = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
local hud = pg:WaitForChild("Hud", 5)
local out = { hud = hud ~= nil }
if hud then
	for _, n in { "TimerPill", "Objectives", "Tank", "AlarmBanner", "Toasts", "RefillHint", "Downed" } do
		out[n] = hud:FindFirstChild(n) ~= nil
	end
end
return HttpService:JSONEncode(out)
```

Expected with the stub: FAIL, `{"hud":false}`. Stop Play.

- [ ] **Step 2: Write `game/StarterPlayerScripts/ClientLib/UiKit.luau`**

```lua
--!strict
-- UiKit [owner: G3]. Shared client UI builders in the sticker style of docs/game/02-art-feel-ui.md §9:
-- UiCream panels with a UiInk stroke, LuckiestGuy numbers/headers, FredokaOne body text, UIScale for phones.
-- Lives in StarterPlayerScripts/ClientLib (not booted by Main.client; controllers require it):
--   local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit"))
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript)

local UiKit = {}

UiKit.Header = Enum.Font.LuckiestGuy
UiKit.Body = Enum.Font.FredokaOne

-- A full-screen ScreenGui under PlayerGui with a UIScale that tracks the viewport (1280x720 = 1).
function UiKit.screen(name: string, displayOrder: number?): ScreenGui
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = displayOrder or 0
	local scale = Instance.new("UIScale")
	local function rescale()
		local cam = workspace.CurrentCamera
		if cam then
			local v = cam.ViewportSize
			scale.Scale = math.clamp(math.min(v.X / 1280, v.Y / 720), 0.5, 1.5)
		end
	end
	rescale()
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	end
	scale.Parent = gui
	gui.Parent = playerGui
	return gui
end

function UiKit.corner(parent: Instance, radius: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 12)
	c.Parent = parent
end

function UiKit.stroke(parent: Instance, thickness: number?, color: Color3?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 3
	s.Color = color or Palette.UiInk
	s.ApplyStrokeMode = if parent:IsA("TextLabel") or parent:IsA("TextButton")
		then Enum.ApplyStrokeMode.Contextual
		else Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

-- A sticker panel: UiCream fill, rounded, 3px ink border.
function UiKit.panel(parent: Instance, name: string, size: UDim2, position: UDim2, anchor: Vector2?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = size
	f.Position = position
	f.AnchorPoint = anchor or Vector2.zero
	f.BackgroundColor3 = Palette.UiCream
	f.BorderSizePixel = 0
	UiKit.corner(f, 12)
	local s = Instance.new("UIStroke")
	s.Thickness = 3
	s.Color = Palette.UiInk
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = f
	f.Parent = parent
	return f
end

export type LabelOpts = {
	font: Enum.Font?,
	textSize: number?,
	color: Color3?,
	stroke: boolean?,
	align: Enum.TextXAlignment?,
	scaled: boolean?,
}

function UiKit.label(parent: Instance, name: string, text: string, size: UDim2, position: UDim2, opts: LabelOpts?): TextLabel
	local o = opts or {} :: LabelOpts
	local l = Instance.new("TextLabel")
	l.Name = name
	l.Text = text
	l.Size = size
	l.Position = position
	l.BackgroundTransparency = 1
	l.Font = o.font or UiKit.Body
	l.TextSize = o.textSize or 22
	l.TextScaled = o.scaled == true
	l.TextColor3 = o.color or Palette.UiInk
	l.TextXAlignment = o.align or Enum.TextXAlignment.Center
	l.TextWrapped = true
	if o.stroke then
		local s = Instance.new("UIStroke")
		s.Thickness = 2
		s.Color = Palette.UiInk
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		s.Parent = l
	end
	l.Parent = parent
	return l
end

-- Scale pop 0 -> 1.15 -> 1 (adds a UIScale if the object has none).
function UiKit.pop(gui: GuiObject, duration: number?)
	local scale = gui:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = gui
	local d = duration or 0.25
	local up = TweenService:Create(scale, TweenInfo.new(d * 0.6, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.15 })
	up.Completed:Connect(function()
		TweenService:Create(scale, TweenInfo.new(d * 0.4), { Scale = 1 }):Play()
	end)
	up:Play()
end

function UiKit.tween(inst: Instance, seconds: number, props: { [string]: any })
	TweenService:Create(inst, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

-- 125 -> "2:05"
function UiKit.clock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

-- Colour for a Shared/Notify kind ("info" | "good" | "bad" | "blame").
function UiKit.kindColor(kind: string): Color3
	if kind == "good" then
		return Palette.UiGood
	elseif kind == "bad" then
		return Palette.UiRed
	elseif kind == "blame" then
		return Palette.UiWarn
	end
	return Palette.UiCream
end

return UiKit
```

- [ ] **Step 3: Write `game/StarterPlayerScripts/Controllers/HudController.luau`**

```lua
--!strict
-- HudController [owner: G3]. The in-round HUD (docs/game/02-art-feel-ui.md §9). Renders only replicated state:
--   Workspace RoundState / RoundEndsAt / MissionId      -> timer pill (red + pulse under 30 s)
--   tag Burning under workspace.Map[MissionId]          -> objectives: "Fires n"
--   tag Rescuable + attr RescueState                    -> objectives: "Rescued a / b"
--   LocalPlayer attrs Water / TankSize (ToolService)    -> tank gauge, "REFILL" hint under 20 %
--   LocalPlayer attr Downed (SquadService)              -> "DOWNED" overlay
--   Mission/Alarm (missionId, locationName)             -> alarm banner
--   Shared/Notify (text, kind)                          -> toast stack (max 5, 3.5 s each)
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript)

local HudController = {}
HudController.Priority = 50

local player = Players.LocalPlayer
local MAX_TOASTS = 5

type Ui = {
	gui: ScreenGui,
	timerPill: Frame,
	timer: TextLabel,
	objectives: Frame,
	fires: TextLabel,
	rescued: TextLabel,
	tank: Frame,
	tankFill: Frame,
	tankPct: TextLabel,
	refillHint: TextLabel,
	banner: Frame,
	bannerText: TextLabel,
	toasts: Frame,
	downed: TextLabel,
}

local ui: Ui? = nil

local function build(): Ui
	local gui = UiKit.screen("Hud", 1)

	local timerPill = UiKit.panel(gui, "TimerPill", UDim2.fromOffset(180, 56), UDim2.new(0.5, 0, 0, 12), Vector2.new(0.5, 0))
	local pillScale = Instance.new("UIScale")
	pillScale.Parent = timerPill
	local timer = UiKit.label(timerPill, "Time", "3:00", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
		font = UiKit.Header,
		textSize = 40,
	})

	local objectives = UiKit.panel(gui, "Objectives", UDim2.fromOffset(260, 92), UDim2.fromOffset(16, 12))
	local fires = UiKit.label(objectives, "Fires", "Fires  0", UDim2.new(1, -24, 0, 36), UDim2.fromOffset(12, 8), {
		font = UiKit.Header,
		textSize = 28,
		color = Palette.FireEdge,
		align = Enum.TextXAlignment.Left,
	})
	local rescued = UiKit.label(objectives, "Rescued", "Rescued  0 / 0", UDim2.new(1, -24, 0, 36), UDim2.fromOffset(12, 48), {
		font = UiKit.Header,
		textSize = 28,
		color = Palette.UiGood,
		align = Enum.TextXAlignment.Left,
	})

	local tank = UiKit.panel(gui, "Tank", UDim2.fromOffset(70, 180), UDim2.new(1, -16, 1, -16), Vector2.new(1, 1))
	UiKit.corner(tank, 20)
	tank.ClipsDescendants = true
	local tankFill = Instance.new("Frame")
	tankFill.Name = "Fill"
	tankFill.AnchorPoint = Vector2.new(0, 1)
	tankFill.Position = UDim2.fromScale(0, 1)
	tankFill.Size = UDim2.fromScale(1, 1)
	tankFill.BackgroundColor3 = Palette.UiWater
	tankFill.BorderSizePixel = 0
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(200, 200, 200))
	grad.Parent = tankFill
	tankFill.Parent = tank
	local tankPct = UiKit.label(tank, "Pct", "100%", UDim2.new(1, 0, 0, 30), UDim2.new(0, 0, 0.5, -15), {
		font = UiKit.Header,
		textSize = 22,
		color = Palette.UiCream,
		stroke = true,
	})
	tankPct.ZIndex = 2
	local refillHint = UiKit.label(gui, "RefillHint", "REFILL at hydrant / truck", UDim2.fromOffset(260, 30),
		UDim2.new(1, -96, 1, -16), {
			font = UiKit.Header,
			textSize = 22,
			color = Palette.UiRed,
			stroke = true,
			align = Enum.TextXAlignment.Right,
		})
	refillHint.AnchorPoint = Vector2.new(1, 1)
	refillHint.Visible = false

	local banner = Instance.new("Frame")
	banner.Name = "AlarmBanner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, -90)
	banner.Size = UDim2.new(1, 0, 0, 80)
	banner.BackgroundColor3 = Palette.UiRed
	banner.BorderSizePixel = 0
	banner.Parent = gui
	local bannerText = UiKit.label(banner, "Text", "ALARM!", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
		font = UiKit.Header,
		textSize = 44,
		color = Palette.UiCream,
		stroke = true,
	})

	local toasts = Instance.new("Frame")
	toasts.Name = "Toasts"
	toasts.BackgroundTransparency = 1
	toasts.AnchorPoint = Vector2.new(0.5, 1)
	toasts.Position = UDim2.new(0.5, 0, 1, -110)
	toasts.Size = UDim2.fromOffset(520, 230)
	local layout = Instance.new("UIListLayout")
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = toasts
	toasts.Parent = gui

	local downed = UiKit.label(gui, "Downed", "DOWNED! Hold on, a teammate can revive you", UDim2.fromOffset(700, 60),
		UDim2.new(0.5, 0, 0.4, 0), {
			font = UiKit.Header,
			textSize = 34,
			color = Palette.UiRed,
			stroke = true,
		})
	downed.AnchorPoint = Vector2.new(0.5, 0.5)
	downed.Visible = false

	return {
		gui = gui,
		timerPill = timerPill,
		timer = timer,
		objectives = objectives,
		fires = fires,
		rescued = rescued,
		tank = tank,
		tankFill = tankFill,
		tankPct = tankPct,
		refillHint = refillHint,
		banner = banner,
		bannerText = bannerText,
		toasts = toasts,
		downed = downed,
	}
end

local toastOrder = 0
local function toast(text: string, kind: string)
	local u = ui
	if not u then
		return
	end
	toastOrder += 1
	local frame = UiKit.panel(u.toasts, `Toast{toastOrder}`, UDim2.fromOffset(500, 40), UDim2.fromScale(0, 0))
	frame.LayoutOrder = toastOrder
	frame.BackgroundColor3 = UiKit.kindColor(kind)
	UiKit.label(frame, "Text", text, UDim2.new(1, -16, 1, 0), UDim2.fromOffset(8, 0), {
		font = UiKit.Header,
		textSize = 22,
		color = if kind == "info" then Palette.UiInk else Palette.UiCream,
		stroke = kind ~= "info",
	})
	UiKit.pop(frame, 0.2)
	local frames = {}
	for _, c in u.toasts:GetChildren() do
		if c:IsA("Frame") then
			table.insert(frames, c)
		end
	end
	table.sort(frames, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = 1, #frames - MAX_TOASTS do
		frames[i]:Destroy()
	end
	task.delay(3.5, function()
		if frame.Parent then
			frame:Destroy()
		end
	end)
end

local function showBanner(locationName: string)
	local u = ui
	if not u then
		return
	end
	u.bannerText.Text = `ALARM! FIRE AT {string.upper(locationName)}`
	UiKit.tween(u.banner, 0.3, { Position = UDim2.new(0.5, 0, 0, 80) })
	task.delay(3, function()
		UiKit.tween(u.banner, 0.3, { Position = UDim2.new(0.5, 0, 0, -90) })
	end)
end

local function countFires(missionId: string?): number
	local map = workspace:FindFirstChild("Map")
	local loc = if map and missionId then map:FindFirstChild(missionId) else nil
	if not loc then
		return 0
	end
	local n = 0
	for _, part in CollectionService:GetTagged(Names.Tag.Burning) do
		if part:IsDescendantOf(loc) then
			n += 1
		end
	end
	return n
end

local function countRescues(): (number, number)
	local rescued, total = 0, 0
	for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
		total += 1
		if m:GetAttribute(Names.Attr.RescueState) == "Rescued" then
			rescued += 1
		end
	end
	return rescued, total
end

local function refresh(t: number)
	local u = ui
	if not u then
		return
	end
	local state = workspace:GetAttribute(Names.Attr.RoundState)
	local inRound = state == "Active" or state == "Alarm"

	u.timerPill.Visible = inRound
	if state == "Alarm" then
		u.timer.Text = "ALARM"
		u.timer.TextColor3 = Palette.UiRed
	elseif state == "Active" then
		local endsAt = (workspace:GetAttribute(Names.Attr.RoundEndsAt) :: number?) or 0
		local left = endsAt - workspace:GetServerTimeNow()
		u.timer.Text = UiKit.clock(left)
		local critical = left < 30
		u.timer.TextColor3 = if critical then Palette.UiRed else Palette.UiInk
		local scale = u.timerPill:FindFirstChildOfClass("UIScale")
		if scale then
			scale.Scale = if critical then 1 + 0.06 * (1 + math.sin(t * math.pi * 2)) else 1
		end
	end

	u.objectives.Visible = state == "Active"
	u.fires.Text = `Fires  {countFires(workspace:GetAttribute(Names.Attr.MissionId) :: string?)}`
	local rescued, total = countRescues()
	u.rescued.Text = `Rescued  {rescued} / {total}`

	local size = (player:GetAttribute(Names.Attr.TankSize) :: number?) or 0
	local water = (player:GetAttribute(Names.Attr.Water) :: number?) or 0
	u.tank.Visible = size > 0
	local frac = if size > 0 then math.clamp(water / size, 0, 1) else 0
	u.tankFill.Size = UDim2.fromScale(1, frac)
	u.tankPct.Text = `{math.floor(frac * 100 + 0.5)}%`
	local low = size > 0 and frac < 0.2
	u.refillHint.Visible = low
	u.tankFill.BackgroundColor3 = if low and math.floor(t * 3) % 2 == 0 then Palette.UiRed else Palette.UiWater

	u.downed.Visible = player:GetAttribute(Names.Attr.Downed) == true
end

function HudController:Init(_controllers: { [string]: any }) end

function HudController:Start()
	ui = build()
	Net.event("Shared", "Notify").OnClientEvent:Connect(function(text: string, kind: string?)
		toast(tostring(text), kind or "info")
	end)
	Net.event("Mission", "Alarm").OnClientEvent:Connect(function(_missionId: string, locationName: string)
		showBanner(tostring(locationName))
	end)
	local t0 = os.clock()
	while true do
		refresh(os.clock() - t0)
		task.wait(0.1)
	end
end

return HudController
```

- [ ] **Step 4: Compile check**

Run: `python3 game/tools/sync.py check --root game` → `OK: checked N files, 0 failed`.

- [ ] **Step 5: Live check (Server, then Client)**

Start Play. `execute_luau` (Server). This fakes ToolService's tank attrs so the gauge can be checked before G1 lands:

```lua
local DevHook = game.ServerStorage.DevHook
DevHook:Invoke("GameConfig", ".Set", "AutoStart", false)
DevHook:Invoke("GameConfig", ".Set", "AlarmSeconds", 2)
local p = game.Players:GetPlayers()[1]
p:SetAttribute("TankSize", 100)
p:SetAttribute("Water", 15)
DevHook:Invoke("MissionService", "_startRound", "Town", 60)
task.wait(4)
return workspace:GetAttribute("RoundState")
```

Expected: `Active`. Then `execute_luau` (Client):

```lua
local HttpService = game:GetService("HttpService")
local hud = game:GetService("Players").LocalPlayer.PlayerGui:WaitForChild("Hud", 5)
local toasts = 0
for _, c in hud.Toasts:GetChildren() do
	if c:IsA("Frame") then
		toasts += 1
	end
end
return HttpService:JSONEncode({
	timer = hud.TimerPill.Time.Text,
	timerVisible = hud.TimerPill.Visible,
	tankVisible = hud.Tank.Visible,
	pct = hud.Tank.Pct.Text,
	refillHint = hud.RefillHint.Visible,
	fires = hud.Objectives.Fires.Text,
	toasts = toasts,
})
```

Expected: `timer` between `"0:54"` and `"0:58"`, `timerVisible` true, `tankVisible` true, `pct` `"15%"`, `refillHint` true,
`fires` `"Fires  0"` (stub fire), `toasts` ≥ 1 (the "ALARM! Fire at 12 Maple St!" toast fades after 3.5 s, so run this
right after the Server block). Take `mcp__Roblox_Studio__screen_capture` to eyeball the pill, card and gauge. Stop Play.

**Integration point (G1):** with ToolService merged, the gauge drains while you spray and refills at a hydrant; with
FireService merged, "Fires n" counts the Town's burning parts.

- [ ] **Step 6: Commit and PR**

```bash
git add game/StarterPlayerScripts/ClientLib/UiKit.luau game/StarterPlayerScripts/Controllers/HudController.luau
git commit -m "game(hud): UiKit sticker UI, timer pill, tank gauge, objectives, alarm banner, toasts"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

---

### Task G3.4: SquadService (helmets, pads, first person) + CostumeBuilder  (Dev C, G3, 1.25 h, P0)

**Files:**
- Create: `game/ServerScriptService/Lib/Squad/CostumeBuilder.luau`
- Modify (replace the K0 stub): `game/ServerScriptService/Services/SquadService.luau`

**Interfaces:**
- Consumes: `MapService:GetSpawnCFrame(slot)` (K0: pad with `StationSpawn` + `Slot`, else a fallback near the origin),
  `GameConfig.MaxPlayers`, `Palette`.
- Produces: `SquadService:GetHelmet(player): number`, `SquadService:RespawnAll()`, Player attrs `Helmet` (1..4) and
  `Downed` (false), `CostumeBuilder.dress(character, helmet)`. `Down`/`Revive` stay no-ops until G3.8.

- [ ] **Step 1: Branch and run the failing check**

```bash
git switch main && git pull --rebase && git switch -c g3/squad
```

Start Play, `execute_luau` (Server):

```lua
local HttpService = game:GetService("HttpService")
task.wait(2)
local p = game.Players:GetPlayers()[1]
local char = p.Character
local costume = char and char:FindFirstChild("Costume")
local shield = costume and costume:FindFirstChild("HelmetShield")
local label = shield and shield:FindFirstChild("Number") and shield.Number:FindFirstChildOfClass("TextLabel")
return HttpService:JSONEncode({
	helmet = p:GetAttribute("Helmet"),
	camera = tostring(p.CameraMode),
	costume = costume ~= nil,
	number = label and label.Text or "",
	pos = char and tostring(char:GetPivot().Position) or "",
})
```

Expected with the stub: FAIL, `{"camera":"Enum.CameraMode.Classic","costume":false,"number":"","pos":"..."}` (no helmet).
Stop Play.

- [ ] **Step 2: Write `game/ServerScriptService/Lib/Squad/CostumeBuilder.luau`**

```lua
--!strict
-- CostumeBuilder [owner: G3]. Dresses a player's character as a Station 67 firefighter (docs/game/02-art-feel-ui.md §3):
-- tan-yellow coat colours, red helmet with brim and gold shield showing the helmet number ("01".."04"), and big
-- googly eyes. All costume parts are welded, Massless, non-colliding and kept in a Folder "Costume".
--   CostumeBuilder.dress(character: Model, helmet: number)
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript)

local CostumeBuilder = {}

local COAT_PARTS = { "UpperTorso", "LowerTorso", "Torso", "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm", "Left Arm", "Right Arm" }
local LEG_PARTS = { "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg", "Left Leg", "Right Leg" }
local HAND_PARTS = { "LeftHand", "RightHand" }
local FOOT_PARTS = { "LeftFoot", "RightFoot" }

local function piece(folder: Folder, anchor: BasePart, name: string, cf: CFrame, size: Vector3, color: Color3, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = anchor
	weld.Part1 = p
	weld.Parent = p
	p.Parent = folder
	return p
end

local function recolor(character: Model, names: { string }, color: Color3)
	for _, n in names do
		local part = character:FindFirstChild(n)
		if part and part:IsA("BasePart") then
			part.Color = color
			part.Material = Enum.Material.SmoothPlastic
		end
	end
end

function CostumeBuilder.dress(character: Model, helmet: number)
	local head = character:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end
	local old = character:FindFirstChild("Costume")
	if old then
		old:Destroy()
	end
	-- Avatar clothing and hats would clash with the uniform look.
	for _, d in character:GetChildren() do
		if d:IsA("Accessory") or d:IsA("Shirt") or d:IsA("Pants") or d:IsA("ShirtGraphic") or d:IsA("BodyColors") then
			d:Destroy()
		end
	end
	local face = head:FindFirstChildOfClass("Decal")
	if face then
		face.Transparency = 1
	end
	recolor(character, COAT_PARTS, Palette.CoatYellow)
	recolor(character, LEG_PARTS, Palette.CoatShadow)
	recolor(character, HAND_PARTS, Palette.GloveOlive)
	recolor(character, FOOT_PARTS, Palette.UiPanelDark)
	head.Color = Palette.SkinWarm

	local folder = Instance.new("Folder")
	folder.Name = "Costume"
	local h = head.CFrame
	local top = head.Size.Y / 2

	-- helmet: dome, brim, gold shield with the number
	piece(folder, head, "HelmetDome", h * CFrame.new(0, top + 0.1, 0.05), Vector3.one * 2.5, Palette.HelmetRed, Enum.PartType.Ball)
	piece(folder, head, "HelmetBrim", h * CFrame.new(0, top - 0.15, 0.1) * CFrame.Angles(0, 0, math.rad(90)),
		Vector3.new(0.25, 3.3, 3.3), Palette.HelmetRed, Enum.PartType.Cylinder)
	local shield = piece(folder, head, "HelmetShield", h * CFrame.new(0, top + 0.55, -1.15) * CFrame.Angles(math.rad(-15), 0, 0),
		Vector3.new(1.1, 0.9, 0.15), Palette.HelmetShield)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Number"
	gui.Face = Enum.NormalId.Front
	gui.PixelsPerStud = 100
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.LuckiestGuy
	label.TextScaled = true
	label.TextColor3 = Palette.NumberInk
	label.Text = string.format("%02d", helmet)
	label.Parent = gui
	gui.Parent = shield

	-- googly eyes: white balls bulging out of the face, small black pupils
	for i, side in { -1, 1 } do
		local eyeCf = h * CFrame.new(side * 0.32, 0.15, -head.Size.Z / 2 - 0.05)
		piece(folder, head, `Eye{i}`, eyeCf, Vector3.one * 0.75, Palette.EyeWhite, Enum.PartType.Ball)
		piece(folder, head, `Pupil{i}`, eyeCf * CFrame.new(side * 0.05, -0.08, -0.3), Vector3.one * 0.28, Palette.Pupil, Enum.PartType.Ball)
	end

	-- reflective band on the chest
	local torso = (character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")) :: BasePart?
	if torso then
		piece(folder, torso, "BandLime", torso.CFrame * CFrame.new(0, -0.2, 0), torso.Size + Vector3.new(0.06, -torso.Size.Y + 0.2, 0.06), Palette.ReflectLime)
		piece(folder, torso, "BandSilver", torso.CFrame * CFrame.new(0, -0.4, 0), torso.Size + Vector3.new(0.06, -torso.Size.Y + 0.15, 0.06), Palette.ReflectSilver)
	end

	folder.Parent = character
end

return CostumeBuilder
```

- [ ] **Step 3: Write `game/ServerScriptService/Services/SquadService.luau` (P0 version)**

```lua
--!strict
-- SquadService [owner: G3]. The crew: helmet numbers 1..4, spawning on the station pads, first person, costume.
-- (Downed / revive / fire damage arrive in Task G3.8.)
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   SquadService:GetHelmet(player: Player): number       -- 1..4
--   SquadService:Down(player: Player, cause: string, culprit: Player?)
--   SquadService:Revive(player: Player, by: Player)
--   SquadService:RespawnAll()                            -- everyone back to a StationSpawn pad
-- Signals: Downed(victim: Player, cause: string, culprit: Player?)
-- Writes: Player attrs Helmet, Downed
-- Consumes: MapService:GetSpawnCFrame(slot) (nil-guarded; falls back to the default spawn)
-- Test hooks (DevHook only): _selftest()
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local GameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GameConfig") :: ModuleScript)
local CostumeBuilder = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Squad"):WaitForChild("CostumeBuilder") :: ModuleScript)

local SquadService = {}
SquadService.Priority = 10
SquadService.Downed = Signal.new() :: Signal.Signal<Player, string, Player?>

local services: { [string]: any } = {}
local helmets: { [Player]: number } = {}

local function assignHelmet(player: Player): number
	local taken: { [number]: boolean } = {}
	for _, n in helmets do
		taken[n] = true
	end
	local n = GameConfig.MaxPlayers
	for i = 1, GameConfig.MaxPlayers do
		if not taken[i] then
			n = i
			break
		end
	end
	helmets[player] = n
	player:SetAttribute(Names.Attr.Helmet, n)
	return n
end

local function spawnCFrame(helmet: number): CFrame?
	local Map = services.MapService
	if not Map then
		return nil
	end
	local t0 = os.clock()
	while workspace:GetAttribute(Names.Attr.MapReady) ~= true and os.clock() - t0 < 10 do
		task.wait(0.2)
	end
	return Map:GetSpawnCFrame(helmet)
end

local function onCharacter(player: Player, character: Model)
	player:SetAttribute(Names.Attr.Downed, false)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not root then
		return
	end
	task.wait() -- let the default spawn finish before we move it
	local helmet = SquadService:GetHelmet(player)
	local cf = spawnCFrame(helmet)
	if cf and character.Parent then
		character:PivotTo(cf)
	end
	local ok, err = pcall(CostumeBuilder.dress, character, helmet)
	if not ok then
		warn(`[SquadService] costume failed: {err}`)
	end
end

local function onPlayer(player: Player)
	assignHelmet(player)
	player:SetAttribute(Names.Attr.Downed, false)
	player.CameraMode = Enum.CameraMode.LockFirstPerson
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
end

function SquadService:Init(all: { [string]: any })
	services = all
end

function SquadService:Start()
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		helmets[player] = nil
	end)
end

function SquadService:GetHelmet(player: Player): number
	return helmets[player] or (player:GetAttribute(Names.Attr.Helmet) :: number?) or 1
end

function SquadService:Down(_player: Player, _cause: string, _culprit: Player?) end

function SquadService:Revive(_player: Player, _by: Player) end

function SquadService:RespawnAll()
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			player:LoadCharacter()
		end)
	end
end

function SquadService:_selftest(): (boolean, string)
	for _, player in Players:GetPlayers() do
		local n = player:GetAttribute(Names.Attr.Helmet)
		if type(n) ~= "number" or n < 1 or n > GameConfig.MaxPlayers then
			return false, `{player.Name} has no helmet`
		end
	end
	return true, `{#Players:GetPlayers()} crew`
end

return SquadService
```

- [ ] **Step 4: Compile check**

Run: `python3 game/tools/sync.py check --root game` → `OK: checked N files, 0 failed`.

- [ ] **Step 5: Live check**

Start Play, rerun the Step 1 block.
Expected: `{"helmet":1,"camera":"Enum.CameraMode.LockFirstPerson","costume":true,"number":"01","pos":"..."}`.
With only K0's MapService (no Station builder yet) `pos` is near `0, 5, 0`.
Selftest (Server): `return select(3, game.ServerStorage.DevHook:Invoke("SquadService", "_selftest"))` → `1 crew`.
In Studio's Test tab, start **Clients and Servers** with 2 players: player 2 gets helmet `02`, and each sees the other's
red helmet with its number and googly eyes. Stop.

**Integration point (G2 Station):** with StationBuilder merged, `pos` is on pad 1 inside Station 67 (3 studs above it),
and player 2 spawns on pad 2.

- [ ] **Step 6: Commit and PR**

```bash
git add game/ServerScriptService/Lib/Squad/CostumeBuilder.luau game/ServerScriptService/Services/SquadService.luau
git commit -m "game(squad): helmet numbers, station pads, first person, firefighter costume"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

**Checkpoint P0 (Sat 10:00), G3 part:** with G1 + G2 merged, one solo round runs alarm → Town → timer → results stub →
back to the station, and `rounds_completed` is 1. That's Integration task I-1.

---

### Task G3.5: RescueNpcBuilder + RescueService + RescueController  (Dev C, G3, 2 h, P1)

**Files:**
- Create: `game/ServerScriptService/Lib/Rescue/RescueNpcBuilder.luau`
- Modify (replace stubs): `game/ServerScriptService/Services/RescueService.luau`,
  `game/StarterPlayerScripts/Controllers/RescueController.luau`, `game/ReplicatedStorage/Config/RescueConfig.luau`

**Interfaces:**
- Consumes: `MapService:GetLocation(id)` and its `RescueSpawn` markers (attrs `Kind`, `BuildingId`; G2), parts tagged
  `RescueDropoff` (G2 TruckBuilder "RescueDropoff", 12x7x6), tag `Truck` (G2, for the client highlight),
  `SquadService.Downed` (forced drop), `SquadService:GetHelmet`, `Net.onServer`, `Net.near`, `UiKit` (G3.3).
- Produces: `RescueService:Spawn(locationId, count)`, `RescueService:Clear()`, `RescueService:Deliver(player): boolean`,
  signals `Rescued(player, rescueId, kind)` and `Dropped(player, rescueId)`, remote `Rescue/Drop` (2/s, burst 1),
  NPC Models in `workspace.Rescuables` tagged `Rescuable` with attrs `RescueId` ("R1".."R5"), `Kind`, `RescueState`,
  `CarriedBy`, Player attr `Carrying`, counters `rescued`, `rescued_<kind>`, `npcs_dropped`,
  `NpcBuilder.build(kind, feet): Model`, `NpcBuilder.rootHeight(kind): number`,
  test hooks `_spawnAt(kind, pos): string`, `_carry(player, id)`, `_deliver(player)`, `_drop(player)`.
  Rules other lanes rely on: while `Carrying ~= ""` the carrier's tools are unequipped and G1 ignores spray/axe;
  carry speed = `RescueConfig.WalkSpeed` × `SpeedPanda` 0.5 / `SpeedCivilian` 0.75 / `SpeedDog` and `SpeedCat` 0.95.

- [ ] **Step 1: Branch and run the failing check**

```bash
git switch main && git pull --rebase && git switch -c g3/rescue
```

Start Play, then **within 10 s** `execute_luau` (Server):

```lua
local HttpService = game:GetService("HttpService")
local DevHook = game.ServerStorage.DevHook
DevHook:Invoke("GameConfig", ".Set", "AutoStart", false)
local p = game.Players:GetPlayers()[1]
local root = p.Character:WaitForChild("HumanoidRootPart")
local _, id = DevHook:Invoke("RescueService", "_spawnAt", "Panda", root.Position + Vector3.new(0, -3, -8))
local _, carried = DevHook:Invoke("RescueService", "_carry", p, id)
local speed = p.Character.Humanoid.WalkSpeed
local carrying = p:GetAttribute("Carrying")
local _, delivered = DevHook:Invoke("RescueService", "_deliver", p)
local folder = workspace:FindFirstChild("Rescuables")
local m = folder and id and folder:FindFirstChild(id)
local _, dogId = DevHook:Invoke("RescueService", "_spawnAt", "Dog", root.Position + Vector3.new(4, -3, -8))
DevHook:Invoke("RescueService", "_carry", p, dogId)
local _, dropped = DevHook:Invoke("RescueService", "_drop", p)
local dog = folder and dogId and folder:FindFirstChild(dogId)
local report = HttpService:JSONDecode(game.ServerStorage.ForgeProbe:Invoke("report"))
return HttpService:JSONEncode({
	id = id, carried = carried, speed = speed, carrying = carrying, delivered = delivered,
	state = m and m:GetAttribute("RescueState"), after = p:GetAttribute("Carrying"),
	dropped = dropped, dogState = dog and dog:GetAttribute("RescueState"),
	rescued = report.counters.rescued, rescued_panda = report.counters.rescued_panda,
	npcs_dropped = report.counters.npcs_dropped, errors = #report.errors,
})
```

Expected with the stub: FAIL, `{"carried":false,"speed":16,"delivered":false,...}` (no `id`, no counters). Stop Play.

- [ ] **Step 2: Write `game/ReplicatedStorage/Config/RescueConfig.luau`**

```lua
--!strict
-- RescueConfig [owner: G3]. Civilians and pets.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Count = 5, -- NPCs spawned per round (one per RescueSpawn marker, up to this many)
	CarryReach = 12, -- studs: a Carry prompt trigger further away than this is ignored
	CarryHold = 0.5, -- seconds to hold the Carry prompt
	WalkSpeed = 16, -- normal speed restored after a drop or delivery
	-- carrier speed multiplier per kind (the panda is heavy)
	SpeedCivilian = 0.75,
	SpeedDog = 0.95,
	SpeedCat = 0.95,
	SpeedPanda = 0.5,
	DeliverPad = 2, -- studs added around the RescueDropoff box when checking delivery
})
```

- [ ] **Step 3: Write `game/ServerScriptService/Lib/Rescue/RescueNpcBuilder.luau`**

```lua
--!strict
-- RescueNpcBuilder [owner: G3]. (main's display-only Lib/Rescue/NpcBuilder from PR #3 is left untouched.) Blocky rescue targets with huge googly eyes (docs/game/02-art-feel-ui.md §3,
-- docs/game/05-content-missions.md §4). Every part is welded to an invisible "Root" (the PrimaryPart), all
-- anchored and non-colliding, so RescueService can carry the whole NPC by unanchoring and welding Root.
--   NpcBuilder.build(kind: "Civilian" | "Dog" | "Cat" | "Panda", feet: CFrame): Model
--   NpcBuilder.rootHeight(kind: string): number   -- studs from the feet up to Root (for re-placing an NPC)
--   feet = ground point under the NPC, LookVector = the way it faces.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript)

local NpcBuilder = {}

local JEANS = Color3.fromRGB(90, 110, 140)
local DOG_ORANGE = Color3.fromRGB(214, 140, 70)
local CAT_GINGER = Color3.fromRGB(232, 150, 60)
local TONGUE = Color3.fromRGB(226, 106, 122)

local SHOUT: { [string]: string } = {
	Civilian = "HELP!",
	Dog = "WOOF?",
	Cat = "mrrp",
	Panda = "???",
}

local function part(model: Model, root: BasePart?, name: string, cf: CFrame, size: Vector3, color: Color3, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if root then
		local w = Instance.new("WeldConstraint")
		w.Part0 = root
		w.Part1 = p
		w.Parent = p
	end
	p.Parent = model
	return p
end

local function eyes(model: Model, root: BasePart, headCf: CFrame, size: number, gap: number)
	for i, side in { -1, 1 } do
		local eyeCf = headCf * CFrame.new(side * gap, 0, 0)
		part(model, root, `Eye{i}`, eyeCf, Vector3.one * size, Palette.EyeWhite, Enum.PartType.Ball)
		part(model, root, `Pupil{i}`, eyeCf * CFrame.new(side * size * 0.08, -size * 0.1, -size * 0.38), Vector3.one * size * 0.4, Palette.Pupil, Enum.PartType.Ball)
	end
end

local function civilian(model: Model, root: BasePart)
	local o = root.CFrame -- root sits at hip height 2
	part(model, root, "LegL", o * CFrame.new(-0.5, -1, 0), Vector3.new(0.9, 2, 0.9), JEANS)
	part(model, root, "LegR", o * CFrame.new(0.5, -1, 0), Vector3.new(0.9, 2, 0.9), JEANS)
	part(model, root, "Torso", o * CFrame.new(0, 1, 0), Vector3.new(2, 2, 1), Palette.CivTeeWhite)
	part(model, root, "ArmL", o * CFrame.new(-1.5, 1.6, 0) * CFrame.Angles(0, 0, math.rad(-150)), Vector3.new(0.8, 2, 0.8), Palette.SkinPale)
	part(model, root, "ArmR", o * CFrame.new(1.5, 1.6, 0) * CFrame.Angles(0, 0, math.rad(150)), Vector3.new(0.8, 2, 0.8), Palette.SkinPale)
	local head = o * CFrame.new(0, 3.2, 0)
	part(model, root, "Head", head, Vector3.one * 2.4, Palette.SkinPale, Enum.PartType.Ball)
	eyes(model, root, head * CFrame.new(0, 0.3, -1.05), 1, 0.5)
	part(model, root, "Mouth", head * CFrame.new(0, -0.5, -1.15), Vector3.new(0.4, 0.4, 0.1), Palette.Pupil, Enum.PartType.Ball)
end

local function dog(model: Model, root: BasePart)
	local o = root.CFrame -- root at body height 1.6
	part(model, root, "Body", o, Vector3.new(1.6, 1.4, 3), DOG_ORANGE)
	part(model, root, "Belly", o * CFrame.new(0, -0.3, 0), Vector3.new(1.4, 0.9, 2.6), Palette.CivTeeWhite)
	for i, x in { -0.55, 0.55 } do
		part(model, root, `LegF{i}`, o * CFrame.new(x, -1.1, -1), Vector3.new(0.5, 1, 0.5), DOG_ORANGE)
		part(model, root, `LegB{i}`, o * CFrame.new(x, -1.1, 1), Vector3.new(0.5, 1, 0.5), DOG_ORANGE)
	end
	part(model, root, "Tail", o * CFrame.new(0, 0.6, 1.7) * CFrame.Angles(math.rad(-40), 0, 0), Vector3.new(0.3, 0.3, 1.2), DOG_ORANGE)
	local head = o * CFrame.new(0, 0.9, -1.9)
	part(model, root, "Head", head, Vector3.one * 1.6, DOG_ORANGE, Enum.PartType.Ball)
	part(model, root, "Snout", head * CFrame.new(0, -0.3, -0.8), Vector3.new(0.8, 0.6, 0.6), Palette.CivTeeWhite)
	part(model, root, "Tongue", head * CFrame.new(0, -0.75, -0.9), Vector3.new(0.4, 0.5, 0.15), TONGUE)
	part(model, root, "Collar", o * CFrame.new(0, 0.6, -1.4), Vector3.new(1.2, 0.3, 0.3), Palette.TruckRed)
	eyes(model, root, head * CFrame.new(0, 0.35, -0.65), 0.7, 0.35)
end

local function cat(model: Model, root: BasePart)
	local o = root.CFrame -- root at body height 1
	part(model, root, "Body", o, Vector3.one * 1.8, CAT_GINGER, Enum.PartType.Ball)
	local head = o * CFrame.new(0, 1.2, -0.3)
	part(model, root, "Head", head, Vector3.one * 1.4, CAT_GINGER, Enum.PartType.Ball)
	for i, x in { -0.4, 0.4 } do
		local ear = Instance.new("WedgePart")
		ear.Name = `Ear{i}`
		ear.Size = Vector3.new(0.2, 0.5, 0.4)
		ear.CFrame = head * CFrame.new(x, 0.75, 0)
		ear.Color = CAT_GINGER
		ear.Material = Enum.Material.SmoothPlastic
		ear.Anchored = true
		ear.CanCollide = false
		ear.CanTouch = false
		local w = Instance.new("WeldConstraint")
		w.Part0 = root
		w.Part1 = ear
		w.Parent = ear
		ear.Parent = model
	end
	part(model, root, "Tongue", head * CFrame.new(0, -0.5, -0.6), Vector3.new(0.3, 0.4, 0.1), TONGUE)
	part(model, root, "Tail", o * CFrame.new(0, 0.4, 1) * CFrame.Angles(math.rad(-60), 0, 0), Vector3.new(0.3, 0.3, 1.4), CAT_GINGER)
	eyes(model, root, head * CFrame.new(0, 0.2, -0.6), 0.6, 0.3)
end

local function panda(model: Model, root: BasePart)
	local o = root.CFrame -- root at body height 2.3
	part(model, root, "Body", o, Vector3.one * 4.4, Palette.EyeWhite, Enum.PartType.Ball)
	part(model, root, "Belt", o * CFrame.new(0, 0.2, 0), Vector3.new(4.5, 1.2, 4.5), Palette.Pupil)
	for i, x in { -1.3, 1.3 } do
		part(model, root, `Leg{i}`, o * CFrame.new(x, -1.8, -0.8), Vector3.one * 1.4, Palette.Pupil, Enum.PartType.Ball)
	end
	local head = o * CFrame.new(0, 2.8, -0.4)
	part(model, root, "Head", head, Vector3.one * 3, Palette.EyeWhite, Enum.PartType.Ball)
	for i, x in { -1.1, 1.1 } do
		part(model, root, `Ear{i}`, head * CFrame.new(x, 1.3, 0), Vector3.one * 1, Palette.Pupil, Enum.PartType.Ball)
		part(model, root, `Patch{i}`, head * CFrame.new(x * 0.45, 0.25, -1.2), Vector3.new(0.9, 1.1, 0.4), Palette.Pupil, Enum.PartType.Ball)
	end
	part(model, root, "Nose", head * CFrame.new(0, -0.4, -1.45), Vector3.new(0.5, 0.35, 0.2), Palette.Pupil)
	eyes(model, root, head * CFrame.new(0, 0.35, -1.45), 0.9, 0.5)
end

local ROOT_HEIGHT: { [string]: number } = { Civilian = 2, Dog = 1.6, Cat = 1, Panda = 2.3 }
local BUILD: { [string]: (Model, BasePart) -> () } = { Civilian = civilian, Dog = dog, Cat = cat, Panda = panda }

function NpcBuilder.rootHeight(kind: string): number
	return ROOT_HEIGHT[kind] or 2
end

function NpcBuilder.build(kind: string, feet: CFrame): Model
	local build = BUILD[kind] or civilian
	local model = Instance.new("Model")
	model.Name = kind
	local root = part(model, nil, "Root", feet * CFrame.new(0, NpcBuilder.rootHeight(kind), 0), Vector3.new(2, 2, 2), Palette.EyeWhite)
	root.Transparency = 1
	model.PrimaryPart = root
	build(model, root)

	local bubble = Instance.new("BillboardGui")
	bubble.Name = "Shout"
	bubble.Size = UDim2.fromOffset(110, 40)
	bubble.StudsOffset = Vector3.new(0, if kind == "Panda" then 6 else 4.5, 0)
	bubble.AlwaysOnTop = true
	bubble.MaxDistance = 250
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.LuckiestGuy
	text.TextScaled = true
	text.TextColor3 = Palette.UiCream
	text.Text = SHOUT[kind] or "HELP!"
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Palette.UiInk
	stroke.Parent = text
	text.Parent = bubble
	bubble.Parent = root
	return model
end

return NpcBuilder
```

- [ ] **Step 4: Write `game/ServerScriptService/Services/RescueService.luau`**

```lua
--!strict
-- RescueService [owner: G3]. Civilians and pets: spawn at RescueSpawn markers, carry (prompt), drop (G key via
-- Rescue/Drop), deliver by walking into the truck's RescueDropoff volume.
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   RescueService:Spawn(locationId: string, count: number)
--   RescueService:Clear()
--   RescueService:Deliver(player: Player): boolean       -- carrier reached a RescueDropoff volume
-- Signals: Rescued(player, rescueId: string, kind: string), Dropped(player, rescueId: string)
-- Remotes: Rescue/Drop (C->S, no args, 2/s)
-- Writes: workspace.Rescuables/<RescueId> NPC Models (tag Rescuable; attrs RescueId, Kind, RescueState,
--   CarriedBy); Player attr Carrying; counters rescued, rescued_<kind>, npcs_dropped
-- Consumes: MapService:GetLocation (RescueSpawn markers), tag RescueDropoff (truck), SquadService.Downed
--   (forced drop), SquadService:GetHelmet (toast text). All nil-guarded.
-- Test hooks (DevHook only): _carry(player, rescueId), _deliver(player), _drop(player), _spawnAt(kind, pos), _selftest()
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local RescueConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("RescueConfig") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local NpcBuilder = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Rescue"):WaitForChild("RescueNpcBuilder") :: ModuleScript)

local RescueService = {}
RescueService.Priority = 50
RescueService.Rescued = Signal.new() :: Signal.Signal<Player, string, string>
RescueService.Dropped = Signal.new() :: Signal.Signal<Player, string>

type Npc = { id: string, kind: string, model: Model, root: BasePart, prompt: ProximityPrompt, weld: WeldConstraint? }

local services: { [string]: any } = {}
local npcs: { [string]: Npc } = {}
local nextId = 0
local delivered = 0 -- per round, for seat placement on the truck

local function folder(): Folder
	local f = workspace:FindFirstChild("Rescuables")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Rescuables"
		f.Parent = workspace
	end
	return f :: Folder
end

local function helmetTag(player: Player): string
	local Squad = services.SquadService
	local n = if Squad then Squad:GetHelmet(player) else 1
	return string.format("Firefighter %02d", n)
end

local function humanoid(player: Player): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function rootOf(player: Player): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function setAnchored(npc: Npc, anchored: boolean)
	for _, d in npc.model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = anchored
			d.Massless = not anchored
			d.CanCollide = false
		end
	end
end

local function restoreSpeed(player: Player)
	local hum = humanoid(player)
	if hum and player:GetAttribute(Names.Attr.Downed) ~= true then
		hum.WalkSpeed = RescueConfig.WalkSpeed
	end
end

local function speedFor(kind: string): number
	local mult = (RescueConfig :: any)[`Speed{kind}`]
	return RescueConfig.WalkSpeed * (if type(mult) == "number" then mult else 0.75)
end

local function carry(player: Player, id: string, skipReach: boolean?): boolean
	local npc = npcs[id]
	if not npc then
		return false
	end
	local state = npc.model:GetAttribute(Names.Attr.RescueState)
	if state ~= "Trapped" and state ~= "Downed" then
		return false
	end
	if (player:GetAttribute(Names.Attr.Carrying) or "") ~= "" or player:GetAttribute(Names.Attr.Downed) == true then
		return false
	end
	local hrp = rootOf(player)
	local hum = humanoid(player)
	if not hrp or not hum then
		return false
	end
	if not skipReach and not Net.near(player, npc.root.Position, RescueConfig.CarryReach) then
		return false
	end
	hum:UnequipTools()
	npc.model:PivotTo(hrp.CFrame * CFrame.new(0, 0.5, -3))
	setAnchored(npc, false)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hrp
	weld.Part1 = npc.root
	weld.Parent = npc.root
	npc.weld = weld
	pcall(function()
		npc.root:SetNetworkOwner(player)
	end)
	npc.prompt.Enabled = false
	npc.model:SetAttribute(Names.Attr.RescueState, "Carried")
	npc.model:SetAttribute(Names.Attr.CarriedBy, player.UserId)
	player:SetAttribute(Names.Attr.Carrying, id)
	hum.WalkSpeed = speedFor(npc.kind)
	return true
end

-- Unweld and re-anchor the NPC at `cf` (feet).
local function release(npc: Npc, cf: CFrame)
	if npc.weld then
		npc.weld:Destroy()
		npc.weld = nil
	end
	setAnchored(npc, true)
	npc.model:PivotTo(cf * CFrame.new(0, NpcBuilder.rootHeight(npc.kind), 0))
end

local function drop(player: Player): boolean
	local id = player:GetAttribute(Names.Attr.Carrying) :: string?
	if not id or id == "" then
		return false
	end
	player:SetAttribute(Names.Attr.Carrying, "")
	restoreSpeed(player)
	local npc = npcs[id]
	if not npc then
		return false
	end
	local hrp = rootOf(player)
	local feet = if hrp
		then CFrame.lookAt(hrp.Position + hrp.CFrame.LookVector * 3 - Vector3.new(0, 3, 0), hrp.Position - Vector3.new(0, 3, 0))
		else CFrame.new(npc.root.Position - Vector3.new(0, 2, 0))
	release(npc, feet)
	npc.prompt.Enabled = true
	npc.model:SetAttribute(Names.Attr.RescueState, "Trapped")
	npc.model:SetAttribute(Names.Attr.CarriedBy, 0)
	RescueService.Dropped:Fire(player, id)
	Telemetry.count("npcs_dropped")
	return true
end

local function firstDropoff(): BasePart?
	for _, d in CollectionService:GetTagged(Names.Tag.RescueDropoff) do
		if d:IsA("BasePart") and d:IsDescendantOf(workspace) then
			return d
		end
	end
	return nil
end

local function insideDropoff(pos: Vector3): BasePart?
	for _, d in CollectionService:GetTagged(Names.Tag.RescueDropoff) do
		if d:IsA("BasePart") and d:IsDescendantOf(workspace) then
			local p = d.CFrame:PointToObjectSpace(pos)
			local half = d.Size / 2 + Vector3.one * RescueConfig.DeliverPad
			if math.abs(p.X) <= half.X and math.abs(p.Y) <= half.Y and math.abs(p.Z) <= half.Z then
				return d
			end
		end
	end
	return nil
end

local function deliver(player: Player, dropoff: BasePart?): boolean
	local id = player:GetAttribute(Names.Attr.Carrying) :: string?
	if not id or id == "" then
		return false
	end
	local npc = npcs[id]
	if not npc then
		player:SetAttribute(Names.Attr.Carrying, "")
		return false
	end
	player:SetAttribute(Names.Attr.Carrying, "")
	restoreSpeed(player)
	delivered += 1
	local spot = dropoff or firstDropoff()
	local feet = if spot
		then spot.CFrame * CFrame.new(((delivered - 1) % 3 - 1) * 3, -spot.Size.Y / 2, 0)
		else CFrame.new(npc.root.Position - Vector3.new(0, 2, 0))
	release(npc, feet)
	npc.prompt:Destroy()
	npc.model:SetAttribute(Names.Attr.RescueState, "Rescued")
	npc.model:SetAttribute(Names.Attr.CarriedBy, 0)
	local shout = npc.root:FindFirstChild("Shout")
	if shout then
		shout:Destroy()
	end
	RescueService.Rescued:Fire(player, id, npc.kind)
	Telemetry.count("rescued")
	Telemetry.count(`rescued_{string.lower(npc.kind)}`)
	local text = if npc.kind == "Panda"
		then `{helmetTag(player)} SAVED THE PANDA!`
		else `{helmetTag(player)} rescued the {string.lower(npc.kind)}!`
	Net.notify("all", text, "good")
	return true
end

local function spawnOne(kind: string, feet: CFrame): Npc
	nextId += 1
	local id = `R{nextId}`
	local model = NpcBuilder.build(kind, feet)
	model.Name = id
	local root = model.PrimaryPart :: BasePart
	model:SetAttribute(Names.Attr.RescueId, id)
	model:SetAttribute(Names.Attr.Kind, kind)
	model:SetAttribute(Names.Attr.RescueState, "Trapped")
	model:SetAttribute(Names.Attr.CarriedBy, 0)
	CollectionService:AddTag(model, Names.Tag.Rescuable)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Carry"
	prompt.ActionText = "Carry"
	prompt.ObjectText = kind
	prompt.HoldDuration = RescueConfig.CarryHold
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = root
	local npc: Npc = { id = id, kind = kind, model = model, root = root, prompt = prompt, weld = nil }
	prompt.Triggered:Connect(function(player: Player)
		carry(player, id, false)
	end)
	npcs[id] = npc
	model.Parent = folder()
	return npc
end

function RescueService:Init(all: { [string]: any })
	services = all
end

function RescueService:Start()
	local Drop = Net.event("Rescue", "Drop")
	Net.onServer(Drop, { rate = 2, burst = 1 }, function(player: Player)
		drop(player)
	end)

	local Squad = services.SquadService
	if Squad then
		Squad.Downed:Connect(function(victim: Player)
			drop(victim)
		end)
	end
	Players.PlayerRemoving:Connect(function(player)
		drop(player)
	end)
	Players.PlayerAdded:Connect(function(player)
		player:SetAttribute(Names.Attr.Carrying, "")
	end)
	for _, player in Players:GetPlayers() do
		player:SetAttribute(Names.Attr.Carrying, "")
	end

	-- Delivery: 4 Hz, carrier's HumanoidRootPart inside a RescueDropoff box.
	task.spawn(function()
		while true do
			task.wait(0.25)
			for _, player in Players:GetPlayers() do
				if (player:GetAttribute(Names.Attr.Carrying) or "") ~= "" then
					local hrp = rootOf(player)
					local spot = hrp and insideDropoff(hrp.Position)
					if spot then
						deliver(player, spot)
					end
				end
			end
		end
	end)
end

function RescueService:Spawn(locationId: string, count: number)
	self:Clear()
	local Map = services.MapService
	local model: Model? = if Map then Map:GetLocation(locationId) else nil
	if not model then
		warn(`[RescueService] no location {locationId}: nothing to rescue`)
		return
	end
	local markers: { BasePart } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:HasTag(Names.Tag.RescueSpawn) then
			table.insert(markers, d)
		end
	end
	table.sort(markers, function(a, b)
		local ka = `{a:GetAttribute(Names.Attr.BuildingId) or ""}/{a:GetAttribute(Names.Attr.Kind) or ""}`
		local kb = `{b:GetAttribute(Names.Attr.BuildingId) or ""}/{b:GetAttribute(Names.Attr.Kind) or ""}`
		if ka ~= kb then
			return ka < kb
		end
		return a.Position.X < b.Position.X
	end)
	for i = 1, math.min(count, #markers) do
		local m = markers[i]
		local feet = m.Position - Vector3.new(0, 1, 0)
		local look = Vector3.new(m.CFrame.LookVector.X, 0, m.CFrame.LookVector.Z)
		local cf = if look.Magnitude > 0.01 then CFrame.lookAt(feet, feet + look) else CFrame.new(feet)
		spawnOne((m:GetAttribute(Names.Attr.Kind) :: string?) or "Civilian", cf)
	end
end

function RescueService:Clear()
	for _, player in Players:GetPlayers() do
		if (player:GetAttribute(Names.Attr.Carrying) or "") ~= "" then
			player:SetAttribute(Names.Attr.Carrying, "")
			restoreSpeed(player)
		end
	end
	for _, npc in npcs do
		npc.model:Destroy()
	end
	table.clear(npcs)
	nextId = 0
	delivered = 0
end

function RescueService:Deliver(player: Player): boolean
	local hrp = rootOf(player)
	return deliver(player, if hrp then insideDropoff(hrp.Position) else nil)
end

-- test hooks -------------------------------------------------------------------------------
function RescueService:_carry(player: Player, rescueId: string): boolean
	return carry(player, rescueId, true)
end

function RescueService:_deliver(player: Player): boolean
	return deliver(player, firstDropoff())
end

function RescueService:_drop(player: Player): boolean
	return drop(player)
end

function RescueService:_spawnAt(kind: string, pos: Vector3): string
	return spawnOne(kind, CFrame.new(pos)).id
end

function RescueService:_selftest(): (boolean, string)
	local net = ReplicatedStorage:FindFirstChild("Net")
	local ns = net and net:FindFirstChild("Rescue")
	if not (ns and ns:FindFirstChild("Drop")) then
		return false, "Rescue/Drop missing"
	end
	local n = 0
	for _ in npcs do
		n += 1
	end
	return true, `{n} npcs`
end

return RescueService
```

- [ ] **Step 5: Write `game/StarterPlayerScripts/Controllers/RescueController.luau`**

```lua
--!strict
-- RescueController [owner: G3]. While the local player carries someone (Player attr Carrying ~= ""):
-- shows "Carrying the <kind>  [G] drop  -> bring it to the TRUCK", highlights the Truck-tagged model,
-- and sends Rescue/Drop when G is pressed. All outcomes are decided by RescueService on the server.
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript)

local RescueController = {}
RescueController.Priority = 60

local player = Players.LocalPlayer

local function kindOf(rescueId: string): string
	for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
		if m:GetAttribute(Names.Attr.RescueId) == rescueId then
			return string.lower(tostring(m:GetAttribute(Names.Attr.Kind) or "civilian"))
		end
	end
	return "civilian"
end

function RescueController:Init(_controllers: { [string]: any }) end

function RescueController:Start()
	local Drop = Net.event("Rescue", "Drop")
	local gui = UiKit.screen("Carry", 2)
	local slot = UiKit.panel(gui, "CarrySlot", UDim2.fromOffset(420, 64), UDim2.new(0, 16, 1, -16), Vector2.new(0, 1))
	local label = UiKit.label(slot, "Text", "", UDim2.new(1, -20, 1, 0), UDim2.fromOffset(10, 0), {
		font = UiKit.Header,
		textSize = 22,
		align = Enum.TextXAlignment.Left,
	})
	slot.Visible = false
	local highlight: Highlight? = nil

	local function refresh()
		local id = (player:GetAttribute(Names.Attr.Carrying) :: string?) or ""
		local carrying = id ~= ""
		slot.Visible = carrying
		if carrying then
			label.Text = `Carrying the {kindOf(id)}  [G] drop\nBring it to the TRUCK`
			UiKit.pop(slot, 0.2)
			local truck = CollectionService:GetTagged(Names.Tag.Truck)[1]
			if truck and not highlight then
				local h = Instance.new("Highlight")
				h.FillTransparency = 0.8
				h.FillColor = Palette.UiGood
				h.OutlineColor = Palette.UiGood
				h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				h.Adornee = truck
				h.Parent = gui
				highlight = h
			end
		elseif highlight then
			highlight:Destroy()
			highlight = nil
		end
	end

	player:GetAttributeChangedSignal(Names.Attr.Carrying):Connect(refresh)
	refresh()

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.G and (player:GetAttribute(Names.Attr.Carrying) or "") ~= "" then
			Drop:FireServer()
		end
	end)
end

return RescueController
```

- [ ] **Step 6: Compile check**

Run: `python3 game/tools/sync.py check --root game` → `OK: checked N files, 0 failed`.

- [ ] **Step 7: Live check**

Start Play, rerun the Step 1 block within 10 s.
Expected: `{"id":"R1","carried":true,"speed":8,"carrying":"R1","delivered":true,"state":"Rescued","after":"",
"dropped":true,"dogState":"Trapped","rescued":1,"rescued_panda":1,"npcs_dropped":1,"errors":0}`
(without G2's truck, `_deliver` re-anchors the panda where it is; with the truck it sits in the RescueDropoff box).
Also check the client hint: `_carry` a new `_spawnAt("Cat", ...)`, then `execute_luau` (Client)
`return game.Players.LocalPlayer.PlayerGui.Carry.CarrySlot.Visible` → `true`, press G in the game window, and the cat is
put down (`Carrying` back to `""`). Stop Play.

**Integration point (G2 Town + truck):** start a round (`_startRound("Town", 120)`); then

```lua
local kinds = {}
for _, m in game:GetService("CollectionService"):GetTagged("Rescuable") do
	table.insert(kinds, `{m.Name}:{m:GetAttribute("Kind")}:{m:GetAttribute("RescueState")}`)
end
table.sort(kinds)
return table.concat(kinds, ",")
```

Expected: 5 entries, kinds `Civilian` ×2, `Cat`, `Dog`, `Panda`, all `Trapped`. Walk to the panda (through the locked door
once G1's axe lands), hold E, walk into the back of truck 67: toast "Firefighter 01 SAVED THE PANDA!", `rescued_panda` = 1.

- [ ] **Step 8: Commit and PR**

```bash
git add game/ReplicatedStorage/Config/RescueConfig.luau game/ServerScriptService/Lib/Rescue/RescueNpcBuilder.luau \
  game/ServerScriptService/Services/RescueService.luau game/StarterPlayerScripts/Controllers/RescueController.luau
git commit -m "game(rescue): googly-eyed civilians and pets, carry/drop/deliver to truck 67"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

---

### Task G3.6: BlameService ledger + awards  (Dev C, G3, 0.75 h, P1)

**Files:**
- Modify (replace stubs): `game/ServerScriptService/Services/BlameService.luau`, `game/ReplicatedStorage/Config/BlameConfig.luau`

**Interfaces:**
- Consumes (nil-guarded, in `Start`): `FireService.Extinguished(part, by)`, `FireService.Spread(from, to)`,
  `ToolService.WaterUsed(player, litres)`, `ToolService.DoorBroken(player, door)`, `ToolService.HoseHit(sprayer, victim)`,
  `RescueService.Rescued(player, id, kind)`, `SquadService.Downed(victim, cause, culprit)`, `SquadService:GetHelmet`,
  `Awards.build` (G3.1).
- Produces: `BlameService:GetStats(player): Types.PlayerStats`, `BlameService:BuildAwards(): { Types.Award }`,
  `BlameService:Reset()`, test hook `_bump(player, field, n)`. MissionService (G3.2) already calls these; this task makes
  the payload real. `BlameConfig.KillFeed`/`KillFeedRepeatSeconds` are read by G3.9.
  Arsonist rule: each `FireService.Spread` during `Active` is charged to the nearest player within
  `BlameConfig.ArsonRadius` (30 studs) of the newly lit part; that's the "(Probably)".

- [ ] **Step 1: Branch and run the failing check**

```bash
git switch main && git pull --rebase && git switch -c g3/blame
```

Start Play, `execute_luau` (Server):

```lua
local HttpService = game:GetService("HttpService")
local DevHook = game.ServerStorage.DevHook
DevHook:Invoke("GameConfig", ".Set", "AutoStart", false)
local p = game.Players:GetPlayers()[1]
DevHook:Invoke("BlameService", "Reset")
DevHook:Invoke("BlameService", "_bump", p, "pandas", 1)
DevHook:Invoke("BlameService", "_bump", p, "rescued", 3)
DevHook:Invoke("BlameService", "_bump", p, "firesStarted", 4)
local _, awards = DevHook:Invoke("BlameService", "BuildAwards")
local _, stats = DevHook:Invoke("BlameService", "GetStats", p)
local ids = {}
for _, a in awards or {} do
	table.insert(ids, a.id)
end
return HttpService:JSONEncode({ ids = table.concat(ids, ","), rescued = stats and stats.rescued, last = awards and awards[#awards] })
```

Expected with the stub: FAIL, `{"ids":"","rescued":0}`. Stop Play.

- [ ] **Step 2: Write `game/ReplicatedStorage/Config/BlameConfig.luau`**

```lua
--!strict
-- BlameConfig [owner: G3]. Award thresholds and blame attribution.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	MaxAwardsPerPlayer = 2,
	ArsonRadius = 30, -- studs: a fire that spreads within this distance of a player is "their" fire (Arsonist (Probably))
	KillFeed = true, -- KillFeedService announces blame events as Shared/Notify "blame" toasts
	KillFeedRepeatSeconds = 4, -- the same (actor, event, target) line is not repeated within this many seconds
})
```

- [ ] **Step 3: Write `game/ServerScriptService/Services/BlameService.luau`**

```lua
--!strict
-- BlameService [owner: G3]. The per-round ledger behind the Blame screen. Listens to every gameplay signal,
-- keeps one Types.PlayerStats per player, and turns them into awards with Lib/Blame/Awards.
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   BlameService:GetStats(player: Player): Types.PlayerStats
--   BlameService:BuildAwards(): { Types.Award }       -- players currently in the server
--   BlameService:Reset()                              -- MissionService calls it at StartRound
-- Consumes (in Start, each nil-guarded):
--   FireService.Extinguished(part, by)     -> by.firesOut += 1
--   FireService.Spread(from, to)           -> nearest player within BlameConfig.ArsonRadius of `to`: firesStarted += 1
--   ToolService.WaterUsed(player, litres)  -> water += litres
--   ToolService.DoorBroken(player, door)   -> doors += 1
--   ToolService.HoseHit(sprayer, victim)   -> sprayer.teammateSprayed += 1
--   RescueService.Rescued(player, id, kind)-> rescued += 1 (+ pandas when kind == "Panda")
--   SquadService.Downed(victim, cause, culprit) -> victim.timesDowned += 1; culprit.downedOthers += 1
-- Test hooks (DevHook only): _bump(player, field, n), _selftest()
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Types = require(Shared:WaitForChild("Types") :: ModuleScript)
local BlameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BlameConfig") :: ModuleScript)
local Awards = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Blame"):WaitForChild("Awards") :: ModuleScript)

local BlameService = {}
BlameService.Priority = 70

local services: { [string]: any } = {}
local ledger: { [number]: Types.PlayerStats } = {}

local function helmetOf(player: Player): number
	local Squad = services.SquadService
	return if Squad then Squad:GetHelmet(player) else ((player:GetAttribute(Names.Attr.Helmet) :: number?) or 1)
end

local function entry(player: Player): Types.PlayerStats
	local s = ledger[player.UserId]
	if not s then
		s = {
			userId = player.UserId,
			helmet = helmetOf(player),
			name = player.DisplayName,
			firesOut = 0,
			firesStarted = 0,
			water = 0,
			doors = 0,
			rescued = 0,
			pandas = 0,
			downedOthers = 0,
			timesDowned = 0,
			teammateSprayed = 0,
		}
		ledger[player.UserId] = s
	end
	return s :: Types.PlayerStats
end

local function bump(player: Player?, field: string, n: number?)
	if not player or not player:IsA("Player") then
		return
	end
	local s = entry(player) :: any
	if type(s[field]) ~= "number" then
		warn(`[BlameService] unknown stat {field}`)
		return
	end
	s[field] += (n or 1)
end

local function nearestPlayer(pos: Vector3, radius: number): Player?
	local best: Player? = nil
	local bestD = radius
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local d = (root.Position - pos).Magnitude
			if d <= bestD then
				best, bestD = player, d
			end
		end
	end
	return best
end

function BlameService:Init(all: { [string]: any })
	services = all
end

function BlameService:Start()
	local Fire = services.FireService
	if Fire then
		Fire.Extinguished:Connect(function(_part: BasePart, by: Player?)
			bump(by, "firesOut")
		end)
		Fire.Spread:Connect(function(_from: BasePart, to: BasePart)
			if workspace:GetAttribute(Names.Attr.RoundState) == "Active" then
				bump(nearestPlayer(to.Position, BlameConfig.ArsonRadius), "firesStarted")
			end
		end)
	end
	local Tool = services.ToolService
	if Tool then
		Tool.WaterUsed:Connect(function(player: Player, litres: number)
			bump(player, "water", litres)
		end)
		Tool.DoorBroken:Connect(function(player: Player, _door: BasePart)
			bump(player, "doors")
		end)
		Tool.HoseHit:Connect(function(sprayer: Player, victim: Player)
			if sprayer ~= victim then
				bump(sprayer, "teammateSprayed")
			end
		end)
	end
	local Rescue = services.RescueService
	if Rescue then
		Rescue.Rescued:Connect(function(player: Player, _id: string, kind: string)
			bump(player, "rescued")
			if kind == "Panda" then
				bump(player, "pandas")
			end
		end)
	end
	local Squad = services.SquadService
	if Squad then
		Squad.Downed:Connect(function(victim: Player, _cause: string, culprit: Player?)
			bump(victim, "timesDowned")
			if culprit and culprit ~= victim then
				bump(culprit, "downedOthers")
			end
		end)
	end
end

function BlameService:GetStats(player: Player): Types.PlayerStats
	local s = table.clone(entry(player))
	s.helmet = helmetOf(player)
	s.water = math.floor(s.water)
	return s
end

function BlameService:BuildAwards(): { Types.Award }
	local list: { Types.PlayerStats } = {}
	for _, player in Players:GetPlayers() do
		table.insert(list, self:GetStats(player))
	end
	return Awards.build(list :: any, BlameConfig.MaxAwardsPerPlayer) :: any
end

function BlameService:Reset()
	table.clear(ledger)
end

-- test hooks -------------------------------------------------------------------------------
function BlameService:_bump(player: Player, field: string, n: number?)
	bump(player, field, n)
end

function BlameService:_selftest(): (boolean, string)
	local probe = Awards.build({}, BlameConfig.MaxAwardsPerPlayer)
	if #probe ~= 0 then
		return false, "Awards.build({}) should be empty"
	end
	return true, `{#Players:GetPlayers()} in ledger scope`
end

return BlameService
```

- [ ] **Step 4: Compile check + specs**

Run: `python3 game/tools/sync.py check --root game` → `OK`; `bash game/tests/run.sh` → exit 0.

- [ ] **Step 5: Live check**

Start Play, rerun the Step 1 block.
Expected: `ids` = `"panda,arsonist,scapegoat"` (max 2 awards each, so `hero` is skipped), `rescued` = 3, and `last` =
`{"id":"scapegoat","title":"You are to blame.","value":4,"blame":true,...}`. Stop Play.

**Integration point (G1 + G2, full round):** play one 60 s round, spray fires and break a door. Then (Server, during
Results or right after `EndRound("forced")`):

```lua
local HttpService = game:GetService("HttpService")
local _, stats = game.ServerStorage.DevHook:Invoke("BlameService", "GetStats", game.Players:GetPlayers()[1])
return HttpService:JSONEncode(stats)
```

Expected: `water` > 0 (equals the round's `water_used` counter, floored), `doors` ≥ 1, `firesOut` ≥ 1.

- [ ] **Step 6: Commit and PR**

```bash
git add game/ReplicatedStorage/Config/BlameConfig.luau game/ServerScriptService/Services/BlameService.luau
git commit -m "game(blame): per-round ledger from every signal, awards via Awards.build"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

---

### Task G3.7: ResultsController, the Blame screen  (Dev C, G3, 1.25 h, P1)

**Files:**
- Modify (replace the K0 stub): `game/StarterPlayerScripts/Controllers/ResultsController.luau`

**Interfaces:**
- Consumes: remote `Mission/Results` with `Types.ResultsPayload` (G3.2), Workspace attr `RoundState`, `UiKit` (G3.3), `Palette`.
- Produces: the `Results` ScreenGui (title, headline + stars, team panel with count-ups, award cards with a "BLAME!" stamp on
  blame cards), hidden when `RoundState` leaves `Results`. This is the screenshot for the video and the deck.

- [ ] **Step 1: Branch and run the failing check**

```bash
git switch main && git pull --rebase && git switch -c g3/results
```

Start Play. `execute_luau` (Server):

```lua
local DevHook = game.ServerStorage.DevHook
DevHook:Invoke("GameConfig", ".Set", "AutoStart", false)
DevHook:Invoke("GameConfig", ".Set", "AlarmSeconds", 2)
DevHook:Invoke("GameConfig", ".Set", "ResultsSeconds", 12)
DevHook:Invoke("MissionService", "_startRound", "Town", 4)
return "started"
```

Then immediately `execute_luau` (Client):

```lua
local HttpService = game:GetService("HttpService")
local r = game.Players.LocalPlayer.PlayerGui:WaitForChild("Results", 15)
if not r then
	return HttpService:JSONEncode({ results = false })
end
task.wait(2.5)
local cards = 0
for _, c in r.Cards:GetChildren() do
	if c:IsA("Frame") and c.Visible then
		cards += 1
	end
end
return HttpService:JSONEncode({ results = true, headline = r.Headline.Text, title = r.Title.Text, cards = cards })
```

Expected with the stub: FAIL, `{"results":false}`. Stop Play.

- [ ] **Step 2: Write `game/StarterPlayerScripts/Controllers/ResultsController.luau`**

```lua
--!strict
-- ResultsController [owner: G3]. The Blame screen (docs/game/02-art-feel-ui.md §10, docs/game/04-market-and-hooks.md §3:
-- "the single most important viral asset"). Renders Mission/Results (Types.ResultsPayload) and hides itself when
-- Workspace RoundState leaves "Results".
--   Title "FLAME AND BLAME" with a flame gradient, MISSION COMPLETE / TIME'S UP + stars,
--   team panel with count-ups, then one card per award flipping in 0.5 s apart; blame cards get a "BLAME!" stamp.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local Types = require(Shared:WaitForChild("Types") :: ModuleScript)
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript)

local ResultsController = {}
ResultsController.Priority = 60

local gui: ScreenGui? = nil
local showToken = 0

local function hide()
	showToken += 1
	if gui then
		gui:Destroy()
		gui = nil
	end
end

local function countUp(label: TextLabel, prefix: string, target: number, suffix: string)
	local value = Instance.new("NumberValue")
	value.Value = 0
	value.Changed:Connect(function(v: number)
		label.Text = `{prefix}{math.floor(v + 0.5)}{suffix}`
	end)
	label.Text = `{prefix}0{suffix}`
	local tween = TweenService:Create(value, TweenInfo.new(0.6, Enum.EasingStyle.Quad), { Value = target })
	tween.Completed:Connect(function()
		label.Text = `{prefix}{target}{suffix}`
		value:Destroy()
	end)
	tween:Play()
end

local function helmetOf(payload: Types.ResultsPayload, userId: number): number
	for _, s in payload.stats do
		if s.userId == userId then
			return s.helmet
		end
	end
	return 1
end

local function nameOf(payload: Types.ResultsPayload, userId: number): string
	for _, s in payload.stats do
		if s.userId == userId then
			return s.name
		end
	end
	return "?"
end

local function card(parent: Instance, payload: Types.ResultsPayload, award: Types.Award, order: number): Frame
	local f = UiKit.panel(parent, `Card{order}`, UDim2.fromOffset(200, 250), UDim2.fromScale(0, 0))
	f.LayoutOrder = order
	f.ClipsDescendants = false
	local headerColor = if award.id == "scapegoat" then Palette.UiShock elseif award.blame then Palette.UiRed else Palette.UiWarn
	local band = Instance.new("Frame")
	band.Name = "Band"
	band.Size = UDim2.new(1, 0, 0, 44)
	band.BackgroundColor3 = headerColor
	band.BorderSizePixel = 0
	UiKit.corner(band, 12)
	band.Parent = f
	local helmet = helmetOf(payload, award.userId)
	UiKit.label(band, "Helmet", string.format("%02d", helmet), UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
		font = UiKit.Header,
		textSize = 34,
		color = Palette.UiCream,
		stroke = true,
	})
	UiKit.label(f, "Title", string.upper(award.title), UDim2.new(1, -16, 0, 70), UDim2.fromOffset(8, 50), {
		font = UiKit.Header,
		textSize = 24,
	})
	UiKit.label(f, "Name", nameOf(payload, award.userId), UDim2.new(1, -16, 0, 24), UDim2.fromOffset(8, 122), {
		textSize = 18,
		color = Palette.UiPanelDark,
	})
	UiKit.label(f, "Blurb", award.blurb, UDim2.new(1, -16, 0, 90), UDim2.fromOffset(8, 150), {
		textSize = 17,
	})
	if award.blame then
		local stamp = UiKit.label(f, "Stamp", "BLAME!", UDim2.fromOffset(150, 50), UDim2.new(0.5, 0, 0, 160), {
			font = UiKit.Header,
			textSize = 40,
			color = Palette.UiRed,
			stroke = true,
		})
		stamp.AnchorPoint = Vector2.new(0.5, 0)
		stamp.Rotation = -12
		stamp.TextTransparency = 0.15
		stamp.ZIndex = 3
		stamp.Visible = false
		f:SetAttribute("HasStamp", true)
	end
	f.Visible = false
	return f
end

local function show(payload: Types.ResultsPayload)
	hide()
	local token = showToken
	local screen = UiKit.screen("Results", 10)
	gui = screen

	local bg = Instance.new("Frame")
	bg.Name = "Backdrop"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.new(1, 1, 1)
	bg.BackgroundTransparency = 0.1
	bg.BorderSizePixel = 0
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(Palette.SkyTitleTop, Palette.HorizonOrange)
	grad.Parent = bg
	bg.Parent = screen

	local title = UiKit.label(screen, "Title", "FLAME AND BLAME", UDim2.new(1, 0, 0, 80), UDim2.fromOffset(0, 20), {
		font = UiKit.Header,
		textSize = 72,
		color = Color3.new(1, 1, 1),
		stroke = true,
	})
	local flame = Instance.new("UIGradient")
	flame.Rotation = 90
	flame.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Palette.UiFlameTop),
		ColorSequenceKeypoint.new(0.5, Palette.UiFlameMid),
		ColorSequenceKeypoint.new(1, Palette.UiFlameLow),
	})
	flame.Parent = title

	local headline = if payload.reason == "allOut"
		then "ALL CLEAR!"
		elseif payload.trapped == 0 and payload.burningAtEnd == 0 then "MISSION COMPLETE"
		else "TIME'S UP!"
	local stars = string.rep("★", payload.stars) .. string.rep("☆", 3 - payload.stars)
	UiKit.label(screen, "Headline", `{headline}   {stars}`, UDim2.new(1, 0, 0, 44), UDim2.fromOffset(0, 100), {
		font = UiKit.Header,
		textSize = 36,
		color = Palette.UiCream,
		stroke = true,
	})

	local team = UiKit.panel(screen, "Team", UDim2.fromOffset(360, 190), UDim2.new(0.5, 0, 0, 156), Vector2.new(0.5, 0))
	local rows = {
		{ "Fires out     ", payload.firesOut, "" },
		{ "Rescued       ", payload.rescued, ` / {payload.rescued + payload.trapped}` },
		{ "Still burning ", payload.burningAtEnd, "" },
		{ "Burned parts  ", payload.burnedParts, "" },
	}
	for i, row in rows do
		local l = UiKit.label(team, `Row{i}`, "", UDim2.new(1, -24, 0, 34), UDim2.fromOffset(12, 8 + (i - 1) * 36), {
			font = UiKit.Header,
			textSize = 26,
			align = Enum.TextXAlignment.Left,
		})
		countUp(l, row[1] :: string, row[2] :: number, row[3] :: string)
	end
	UiKit.label(team, "Time", `Time  {UiKit.clock(payload.seconds)}`, UDim2.new(1, -24, 0, 30), UDim2.fromOffset(12, 152), {
		textSize = 20,
		align = Enum.TextXAlignment.Left,
	})

	UiKit.label(screen, "BlameHeader", "THE BLAME", UDim2.new(1, 0, 0, 40), UDim2.fromOffset(0, 356), {
		font = UiKit.Header,
		textSize = 34,
		color = Palette.UiCream,
		stroke = true,
	})

	local strip = Instance.new("ScrollingFrame")
	strip.Name = "Cards"
	strip.BackgroundTransparency = 1
	strip.BorderSizePixel = 0
	strip.AnchorPoint = Vector2.new(0.5, 0)
	strip.Position = UDim2.new(0.5, 0, 0, 404)
	strip.Size = UDim2.new(1, -40, 0, 270)
	strip.ScrollingDirection = Enum.ScrollingDirection.X
	strip.AutomaticCanvasSize = Enum.AutomaticSize.X
	strip.CanvasSize = UDim2.fromScale(0, 0)
	strip.ScrollBarThickness = 6
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 14)
	layout.Parent = strip
	strip.Parent = screen

	local cards: { Frame } = {}
	for i, award in payload.awards do
		table.insert(cards, card(strip, payload, award, i))
	end
	task.spawn(function()
		task.wait(0.8)
		for _, f in cards do
			if token ~= showToken then
				return
			end
			f.Visible = true
			UiKit.pop(f, 0.3)
			if f:GetAttribute("HasStamp") then
				task.delay(0.35, function()
					local stamp = f:FindFirstChild("Stamp") :: TextLabel?
					if stamp then
						stamp.Visible = true
						UiKit.pop(stamp, 0.2)
					end
				end)
			end
			task.wait(0.5)
		end
	end)
end

function ResultsController:Init(_controllers: { [string]: any }) end

function ResultsController:Start()
	Net.event("Mission", "Results").OnClientEvent:Connect(function(payload: Types.ResultsPayload)
		show(payload)
	end)
	workspace:GetAttributeChangedSignal(Names.Attr.RoundState):Connect(function()
		if workspace:GetAttribute(Names.Attr.RoundState) ~= "Results" then
			hide()
		end
	end)
	Players.LocalPlayer.CharacterAdded:Connect(function()
		if workspace:GetAttribute(Names.Attr.RoundState) ~= "Results" then
			hide()
		end
	end)
end

return ResultsController
```

- [ ] **Step 3: Compile check**

Run: `python3 game/tools/sync.py check --root game` → `OK: checked N files, 0 failed`.

- [ ] **Step 4: Live check**

Rerun both Step 1 blocks (Server, then Client).
Expected: `{"results":true,"headline":"MISSION COMPLETE   ★★☆","title":"FLAME AND BLAME","cards":2}` with K0 stubs
(nothing burning, nobody to rescue: Moral Support + "You are to blame."). With G1+G2 merged and fires still burning the
headline is `"TIME'S UP!   ★☆☆"`. `mcp__Roblox_Studio__screen_capture` while it shows: sunset gradient, flame-gradient
title, team panel, cards with a tilted red BLAME! stamp on the scapegoat card. 12 s later `Results` is gone
(`return game.Players.LocalPlayer.PlayerGui:FindFirstChild("Results") == nil` → `true`). Stop Play.

- [ ] **Step 5: Commit and PR**

```bash
git add game/StarterPlayerScripts/Controllers/ResultsController.luau
git commit -m "game(results): Blame screen with count-ups, award cards and BLAME! stamp"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

---

### Task G3.8: Fire damage, Downed and revive  (Dev C, G3, 1 h, P1)

**Files:**
- Modify: `game/ReplicatedStorage/Config/GameConfig.luau` (adds crew-health keys),
  `game/ServerScriptService/Services/SquadService.luau` (full P1 version)

**Interfaces:**
- Consumes: tag `Burning` + attr `FireLevel` (G1 FireService), `MapService:GetSpawnCFrame`, `CostumeBuilder.dress` (G3.4).
- Produces: `SquadService:Down(player, cause, culprit)`, `SquadService:Revive(player, by)`, signal
  `Downed(victim, cause, culprit)` (RescueService force-drops on it, BlameService counts it), Player attr `Downed`
  (HudController shows the DOWNED overlay; G1 ignores spray/axe while true), a "Revive" ProximityPrompt on the downed
  player's HumanoidRootPart, counters `player_downs`, `player_revives`, test hook `_down(player)`.
  New GameConfig keys: `FireDamageRadius` 6, `FireDamagePerSecond` 12, `DownedSeconds` 12, `ReviveHold` 1.5,
  `ReviveHealth` 50, `WalkSpeed` 16, `JumpHeight` 7.2.

- [ ] **Step 1: Branch and run the failing check**

```bash
git switch main && git pull --rebase && git switch -c g3/downed
```

Start Play, `execute_luau` (Server):

```lua
local HttpService = game:GetService("HttpService")
local DevHook = game.ServerStorage.DevHook
DevHook:Invoke("GameConfig", ".Set", "AutoStart", false)
pcall(function()
	DevHook:Invoke("GameConfig", ".Set", "DownedSeconds", 4)
end)
local p = game.Players:GetPlayers()[1]
DevHook:Invoke("SquadService", "_down", p)
local downed = p:GetAttribute("Downed")
local speed = p.Character.Humanoid.WalkSpeed
local prompt = p.Character.HumanoidRootPart:FindFirstChild("Revive") ~= nil
task.wait(6)
local report = HttpService:JSONDecode(game.ServerStorage.ForgeProbe:Invoke("report"))
return HttpService:JSONEncode({
	downed = downed, speed = speed, prompt = prompt,
	after = p:GetAttribute("Downed"), player_downs = report.counters.player_downs,
})
```

Expected with the P0 version: FAIL, `{"downed":false,"speed":16,"prompt":false,"after":false}` (no `_down` hook, so
`DevHook` returns false and nothing happens). Stop Play.

- [ ] **Step 2: Write `game/ReplicatedStorage/Config/GameConfig.luau`**

```lua
--!strict
-- GameConfig [owner: G3]. Round flow and crew numbers. Other lanes may read these, never redefine them.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	DefaultMission = "Town", -- location Id the auto round uses
	LocationName = "12 Maple St", -- shown on the alarm banner
	AutoStart = true, -- Lobby -> Alarm automatically when >= 1 player is in
	LobbySeconds = 10,
	AlarmSeconds = 6,
	RoundSeconds = 180,
	ResultsSeconds = 15,
	StartFires = 3, -- FireStart parts first, then random Flammable parts up to this many
	MaxPlayers = 4,
	AllOutGraceSeconds = 10, -- "allOut" (no fires, no trapped) can't end a round in its first N s
	-- crew health (SquadService)
	FireDamageRadius = 6, -- studs from a Burning part's centre
	FireDamagePerSecond = 12, -- at FireLevel 3; scaled by level / 3
	DownedSeconds = 12, -- auto-respawn at the station after this long downed
	ReviveHold = 1.5, -- seconds a teammate holds the Revive prompt
	ReviveHealth = 50,
	WalkSpeed = 16,
	JumpHeight = 7.2,
})
```

- [ ] **Step 3: Write `game/ServerScriptService/Services/SquadService.luau` (full version)**

```lua
--!strict
-- SquadService [owner: G3]. The crew: helmet numbers 1..4, spawning on the station pads, first person, costume,
-- fire damage, Downed and revive.
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   SquadService:GetHelmet(player: Player): number       -- 1..4
--   SquadService:Down(player: Player, cause: string, culprit: Player?)
--   SquadService:Revive(player: Player, by: Player)
--   SquadService:RespawnAll()                            -- everyone back to a StationSpawn pad
-- Signals: Downed(victim: Player, cause: string, culprit: Player?)
-- Writes: Player attrs Helmet, Downed; counters player_downs, player_revives
-- Consumes: MapService:GetSpawnCFrame(slot) (nil-guarded); tag Burning + attr FireLevel (FireService) for damage
-- Test hooks (DevHook only): _down(player), _selftest()
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local GameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GameConfig") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local CostumeBuilder = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Squad"):WaitForChild("CostumeBuilder") :: ModuleScript)

local SquadService = {}
SquadService.Priority = 10
SquadService.Downed = Signal.new() :: Signal.Signal<Player, string, Player?>

local services: { [string]: any } = {}
local helmets: { [Player]: number } = {}
local downToken: { [Player]: number } = {}

local function tagOf(player: Player): string
	return string.format("Firefighter %02d", SquadService:GetHelmet(player))
end

local function assignHelmet(player: Player): number
	local taken: { [number]: boolean } = {}
	for _, n in helmets do
		taken[n] = true
	end
	local n = GameConfig.MaxPlayers
	for i = 1, GameConfig.MaxPlayers do
		if not taken[i] then
			n = i
			break
		end
	end
	helmets[player] = n
	player:SetAttribute(Names.Attr.Helmet, n)
	return n
end

local function spawnCFrame(helmet: number): CFrame?
	local Map = services.MapService
	if not Map then
		return nil
	end
	local t0 = os.clock()
	while workspace:GetAttribute(Names.Attr.MapReady) ~= true and os.clock() - t0 < 10 do
		task.wait(0.2)
	end
	return Map:GetSpawnCFrame(helmet)
end

local function humanoidOf(player: Player): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function clearRevivePrompt(player: Player)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local prompt = root and root:FindFirstChild("Revive")
	if prompt then
		prompt:Destroy()
	end
end

local function onCharacter(player: Player, character: Model)
	downToken[player] = (downToken[player] or 0) + 1
	player:SetAttribute(Names.Attr.Downed, false)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not root then
		return
	end
	task.wait() -- let the default spawn finish before we move it
	local helmet = SquadService:GetHelmet(player)
	local cf = spawnCFrame(helmet)
	if cf and character.Parent then
		character:PivotTo(cf)
	end
	local ok, err = pcall(CostumeBuilder.dress, character, helmet)
	if not ok then
		warn(`[SquadService] costume failed: {err}`)
	end
end

local function onPlayer(player: Player)
	assignHelmet(player)
	player:SetAttribute(Names.Attr.Downed, false)
	player.CameraMode = Enum.CameraMode.LockFirstPerson
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
end

-- 2 Hz: Burning parts near a character hurt it; at <= 1 HP the player is Downed instead of dying.
local function damageTick(dt: number)
	local burning = CollectionService:GetTagged(Names.Tag.Burning)
	if #burning == 0 then
		return
	end
	for _, player in Players:GetPlayers() do
		if player:GetAttribute(Names.Attr.Downed) == true then
			continue
		end
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not root or not hum or hum.Health <= 0 then
			continue
		end
		local level = 0
		for _, part in burning do
			if part:IsA("BasePart") and (part.Position - root.Position).Magnitude <= GameConfig.FireDamageRadius then
				level = math.max(level, (part:GetAttribute(Names.Attr.FireLevel) :: number?) or 1)
			end
		end
		if level > 0 then
			local dmg = GameConfig.FireDamagePerSecond * (level / 3) * dt
			if hum.Health - dmg <= 1 then
				hum.Health = 1
				SquadService:Down(player, "fire", nil)
			else
				hum.Health -= dmg
			end
		end
	end
end

function SquadService:Init(all: { [string]: any })
	services = all
end

function SquadService:Start()
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		helmets[player] = nil
		downToken[player] = nil
	end)
	task.spawn(function()
		while true do
			local dt = task.wait(0.5)
			local ok, err = pcall(damageTick, dt)
			if not ok then
				warn(`[SquadService] damage tick: {err}`)
			end
		end
	end)
end

function SquadService:GetHelmet(player: Player): number
	return helmets[player] or (player:GetAttribute(Names.Attr.Helmet) :: number?) or 1
end

function SquadService:Down(player: Player, cause: string, culprit: Player?)
	if player:GetAttribute(Names.Attr.Downed) == true then
		return
	end
	local hum = humanoidOf(player)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not root then
		return
	end
	player:SetAttribute(Names.Attr.Downed, true)
	hum:UnequipTools()
	hum.WalkSpeed = 0
	hum.UseJumpPower = false
	hum.JumpHeight = 0
	clearRevivePrompt(player)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Revive"
	prompt.ActionText = "Revive"
	prompt.ObjectText = tagOf(player)
	prompt.HoldDuration = GameConfig.ReviveHold
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Triggered:Connect(function(by: Player)
		if by ~= player and by:GetAttribute(Names.Attr.Downed) ~= true then
			SquadService:Revive(player, by)
		end
	end)
	prompt.Parent = root
	SquadService.Downed:Fire(player, cause, culprit)
	Telemetry.count("player_downs")
	Net.notify("all", `{tagOf(player)} is down!`, "bad")

	downToken[player] = (downToken[player] or 0) + 1
	local token = downToken[player]
	task.delay(GameConfig.DownedSeconds, function()
		if downToken[player] == token and player:GetAttribute(Names.Attr.Downed) == true and player.Parent then
			player:LoadCharacter() -- back to the station pad; CharacterAdded clears Downed
		end
	end)
end

function SquadService:Revive(player: Player, by: Player)
	if player:GetAttribute(Names.Attr.Downed) ~= true then
		return
	end
	downToken[player] = (downToken[player] or 0) + 1
	player:SetAttribute(Names.Attr.Downed, false)
	clearRevivePrompt(player)
	local hum = humanoidOf(player)
	if hum then
		hum.WalkSpeed = GameConfig.WalkSpeed
		hum.JumpHeight = GameConfig.JumpHeight
		hum.Health = math.max(hum.Health, GameConfig.ReviveHealth)
	end
	Telemetry.count("player_revives")
	Net.notify("all", `{tagOf(by)} revived {tagOf(player)}!`, "good")
end

function SquadService:RespawnAll()
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			player:LoadCharacter()
		end)
	end
end

-- test hooks -------------------------------------------------------------------------------
function SquadService:_down(player: Player)
	self:Down(player, "test", nil)
end

function SquadService:_selftest(): (boolean, string)
	for _, player in Players:GetPlayers() do
		local n = player:GetAttribute(Names.Attr.Helmet)
		if type(n) ~= "number" or n < 1 or n > GameConfig.MaxPlayers then
			return false, `{player.Name} has no helmet`
		end
	end
	return true, `{#Players:GetPlayers()} crew`
end

return SquadService
```

- [ ] **Step 4: Compile check**

Run: `python3 game/tools/sync.py check --root game` → `OK: checked N files, 0 failed`.

- [ ] **Step 5: Live check**

Start Play, rerun the Step 1 block.
Expected: `{"downed":true,"speed":0,"prompt":true,"after":false,"player_downs":1}` (`after` is false because the 4 s
auto-respawn reloaded the character at its pad). The HUD showed "DOWNED!" meanwhile and a "Firefighter 01 is down!" toast.
Revive needs a second player: Test → **Clients and Servers**, 2 players; down player 1 with `_down`, walk player 2 over and
hold E on "Revive Firefighter 01" for 1.5 s → toast "Firefighter 02 revived Firefighter 01!", `player_revives` = 1.

**Integration point (G1 fire):** during a round, stand in a burning house and speed it up:

```lua
local DevHook = game.ServerStorage.DevHook
DevHook:Invoke("GameConfig", ".Set", "FireDamagePerSecond", 200)
local p = game.Players:GetPlayers()[1]
DevHook:Invoke("FireService", "_ignite", p.Character.HumanoidRootPart.Position)
task.wait(3)
return p:GetAttribute("Downed")
```

Expected: `true` (a Flammable part within 6 studs must exist, so stand inside a Town house).

- [ ] **Step 6: Commit and PR**

```bash
git add game/ReplicatedStorage/Config/GameConfig.luau game/ServerScriptService/Services/SquadService.luau
git commit -m "game(squad): fire damage, Downed with revive prompt, auto-respawn"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

**Checkpoint P1 (Sat 14:00), G3 part:** a full solo round with rescues, a door, a downed moment and a real Blame screen
(Integration task I-2).

---

### Task G3.9: KillFeedService, blame toasts  (Dev C, G3, 0.5 h, P1.5)

**Files:**
- Create: `game/ServerScriptService/Services/KillFeedService.luau`

**Interfaces:**
- Consumes (nil-guarded): `ToolService.HoseHit(sprayer, victim)` (G1 P1.5), `ToolService.DoorBroken(player, door)`,
  `SquadService.Downed(victim, cause, culprit)`, `RescueService.Dropped(player, rescueId)`, `BlameConfig.KillFeed`,
  `BlameConfig.KillFeedRepeatSeconds` (G3.6), `Net.notify` (kind `"blame"`, rendered gold by HudController).
- Produces: toasts such as "Firefighter 02 hosed Firefighter 01!", "Firefighter 01 dropped the panda!",
  "Firefighter 03 destroyed a door.", test hook `_announce(text)`.

- [ ] **Step 1: Branch and run the failing check**

```bash
git switch main && git pull --rebase && git switch -c g3/killfeed
```

Start Play, `execute_luau` (Server):

```lua
local ok, err = game.ServerStorage.DevHook:Invoke("KillFeedService", "_announce", "Firefighter 02 hosed Firefighter 01!")
return `{ok} {err}`
```

Expected: FAIL, `false ServerScriptService.ForgeProbe:<line>: DevHook: no ModuleScript named KillFeedService`. Stop Play.

- [ ] **Step 2: Write `game/ServerScriptService/Services/KillFeedService.luau`**

```lua
--!strict
-- KillFeedService [owner: G3]. Kill-feed style blame toasts ("Firefighter 02 hosed Firefighter 01!") sent as
-- Shared/Notify kind "blame" (HudController renders them). docs/game/01-gameplay-systems.md §10.1.
-- No public API. Consumes (nil-guarded): ToolService.HoseHit, ToolService.DoorBroken, SquadService.Downed,
-- RescueService.Dropped. Switch off with BlameConfig.KillFeed = false.
-- Test hooks (DevHook only): _announce(text), _selftest()
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local BlameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BlameConfig") :: ModuleScript)

local KillFeedService = {}
KillFeedService.Priority = 80

local services: { [string]: any } = {}
local lastSaid: { [string]: number } = {}

local function tagOf(player: Player): string
	local Squad = services.SquadService
	local n = if Squad then Squad:GetHelmet(player) else ((player:GetAttribute(Names.Attr.Helmet) :: number?) or 1)
	return string.format("Firefighter %02d", n)
end

local function announce(key: string, text: string)
	if not BlameConfig.KillFeed then
		return
	end
	local now = os.clock()
	if lastSaid[key] and now - lastSaid[key] < BlameConfig.KillFeedRepeatSeconds then
		return
	end
	lastSaid[key] = now
	Net.notify("all", text, "blame")
end

local function kindOf(rescueId: string): string
	for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
		if m:GetAttribute(Names.Attr.RescueId) == rescueId then
			return string.lower(tostring(m:GetAttribute(Names.Attr.Kind) or "civilian"))
		end
	end
	return "civilian"
end

function KillFeedService:Init(all: { [string]: any })
	services = all
end

function KillFeedService:Start()
	local Tool = services.ToolService
	if Tool then
		Tool.HoseHit:Connect(function(sprayer: Player, victim: Player)
			announce(`hose:{sprayer.UserId}:{victim.UserId}`, `{tagOf(sprayer)} hosed {tagOf(victim)}!`)
		end)
		Tool.DoorBroken:Connect(function(player: Player, _door: BasePart)
			announce(`door:{player.UserId}`, `{tagOf(player)} destroyed a door.`)
		end)
	end
	local Squad = services.SquadService
	if Squad then
		-- SquadService already toasts "Firefighter 0X is down!"; the feed only adds who is to blame.
		Squad.Downed:Connect(function(victim: Player, _cause: string, culprit: Player?)
			if culprit and culprit ~= victim then
				announce(`down:{culprit.UserId}:{victim.UserId}`, `{tagOf(culprit)} knocked out {tagOf(victim)}!`)
			end
		end)
	end
	local Rescue = services.RescueService
	if Rescue then
		Rescue.Dropped:Connect(function(player: Player, rescueId: string)
			announce(`drop:{player.UserId}:{rescueId}`, `{tagOf(player)} dropped the {kindOf(rescueId)}!`)
		end)
	end
end

-- test hooks -------------------------------------------------------------------------------
function KillFeedService:_announce(text: string)
	announce(`test:{text}`, text)
end

function KillFeedService:_selftest(): (boolean, string)
	return true, if BlameConfig.KillFeed then "on" else "off"
end

return KillFeedService
```

- [ ] **Step 3: Compile check**

Run: `python3 game/tools/sync.py check --root game` → `OK: checked N files, 0 failed`. Output shows
`[Boot] server: N services` with N one higher than before.

- [ ] **Step 4: Live check**

Start Play, rerun the Step 1 Server block → `true nil`. Immediately `execute_luau` (Client):

```lua
local texts = {}
for _, f in game.Players.LocalPlayer.PlayerGui.Hud.Toasts:GetChildren() do
	if f:IsA("Frame") then
		table.insert(texts, f.Text.Text)
	end
end
return table.concat(texts, " | ")
```

Expected: contains `Firefighter 02 hosed Firefighter 01!` (gold toast). Stop Play.

**Integration point (G1 P1.5 HoseHit):** 2-player Clients and Servers test; player 2 sprays player 1 → toast
"Firefighter 02 hosed Firefighter 01!" (at most once per 4 s per pair), and the Blame screen shows
"Friendly Fire Department" for player 2 after 3 hits.

- [ ] **Step 5: Commit and PR**

```bash
git add game/ServerScriptService/Services/KillFeedService.luau
git commit -m "game(blame): kill-feed blame toasts"
git push -u origin HEAD && gh pr create --fill
gh pr merge --squash --delete-branch
```

---

## Lane GF: Forge + Mubit demo (Dev B, Anson)

GF makes the hackathon's required beat real: **a human correction to code Forge wrote becomes a recorded call in Mubit's fixer task**, inside the actual game. GF.1 and GF.2 run on Friday night while Task 0 is in flight (they touch only `forge/`). GF.3 to GF.5 run on Saturday, between Dev B's G1 tasks.

| Task | When | Est. |
|---|---|---|
| GF.1 Seeded runs, fixer guard, studio pick (Python) | Fri 20:30–21:45 | 1.25 h |
| GF.2 Forge-ai place + Mubit warm-up runs (background, overnight) | Fri 22:00 → Sat 08:00 (about 0.5 h hands-on) | 0.5 h |
| GF.3 Forge builds FlareUpService on the real game | Sat 10:30–11:30 | 1 h |
| GF.4 The correction moment + promote PR | Sat 14:30–15:45 | 1.25 h |
| GF.5 Mubit console capture for the video and deck | Sat 16:00–17:00 | 1 h |

### Task GF.1: Seeded runs, fixer guard, studio pick (Dev B · GF · 1.25 h · Fri 21:45, before GF.2)

**Why:** Today `copy_base_game` copies *all* of `game/` into every `forge new` game. `Run._base_files` treats every `game/` path as off-limits, so after Task 0 a generated `ServerScriptService/Main.server.luau` could no longer be fixed. Forge also needs to run on a copy of the real game (`runs/flame-and-blame`) and must never sync into the wrong Studio (it prunes).

**Files:**
- Modify: `forge/loop.py` (`copy_base_game`, `Run.base_files`, `Run.open_studio`)
- Create: `forge/seed.py`, `forge/seeds/flame-and-blame.json`
- Modify: `forge/cli.py` (`seed`, `promote` subcommands)
- Modify: `tests/test_loop.py`; Create: `tests/test_seed.py`
- Modify: `docs/ARCHITECTURE.md`

**Interfaces:**
- Consumes: `RunStore(settings, slug)` (`.game_dir`, `.ensure()`, `.save_spec()`, `.load_spec()`, `.state_path`, `.new_state()`, `.save_state()`), `Settings.base_game_dir`, `Studio.select(name_hint)`.
- Produces: `forge.loop.RUNTIME_FILES: tuple[str, ...]`; `Run.base_files -> set[str]` (property: runtime ∪ `spec["base_files"]`); env `FORGE_STUDIO`; `forge.seed.seed(settings, slug, spec_path=None) -> RunStore`; `forge.seed.promote(settings, slug, rel) -> Path`; CLI `forge seed <slug> [--spec FILE]`, `forge promote <slug> <path>`; spec key `base_files: list[str]`.

- [ ] **Step 1: Branch**

```bash
git switch main && git pull --rebase && git switch -c gf/seeded-runs
```

- [ ] **Step 2: Write the failing tests**

Create `tests/test_seed.py`:

```python
"""forge seed / promote, the seeded-game fixer guard, and FORGE_STUDIO selection."""

from __future__ import annotations

import contextlib
import dataclasses
import io
import json

import pytest

from forge.config import load_settings
from forge.llm import FakeLLM
from forge.loop import RUNTIME_FILES, UI, Run
from forge.memory import RunStore
from forge.seed import SEEDS_DIR, promote, seed

SPEC = {"title": "T", "pitch": "p", "modules": [
    {"path": "ServerScriptService/Services/FlareUpService.luau", "purpose": "x", "depends": []}]}


@pytest.fixture
def settings(tmp_path):
    base = tmp_path / "game"
    for rel, src in {
        "ServerScriptService/ForgeProbe.server.luau": "-- probe\n",
        "ReplicatedStorage/ForgeTelemetry.luau": "return {}\n",
        "ServerScriptService/Main.server.luau": "-- boot\n",
        "ServerScriptService/Services/FireService.luau": "return {}\n",
        "tools/sync.py": "# tool\n",
        "tools/manifest.json": "[]\n",
    }.items():
        (base / rel).parent.mkdir(parents=True, exist_ok=True)
        (base / rel).write_text(src)
    spec_file = tmp_path / "spec.json"
    spec_file.write_text(json.dumps(SPEC))
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs", base_game_dir=base)
    return s, spec_file


def test_seed_copies_human_tree_and_records_base_files(settings):
    s, spec_file = settings
    store = seed(s, "fab", spec_file)
    assert (store.game_dir / "ServerScriptService/Services/FireService.luau").read_text() == "return {}\n"
    assert not (store.game_dir / "tools/manifest.json").exists()
    spec = store.load_spec()
    assert spec["slug"] == "fab"
    assert "ServerScriptService/Services/FireService.luau" in spec["base_files"]
    assert "ServerScriptService/Main.server.luau" in spec["base_files"]
    assert [m["path"] for m in spec["modules"]] == ["ServerScriptService/Services/FlareUpService.luau"]
    assert store.load_state()["idea"] == "p"


def test_reseed_keeps_forge_files_and_state(settings):
    s, spec_file = settings
    store = seed(s, "fab", spec_file)
    forge_file = store.game_dir / "ServerScriptService/Services/FlareUpService.luau"
    forge_file.write_text("-- forge made this\n")
    state = store.load_state()
    state["corrections"].append({"note": "keep me"})
    store.save_state(state)
    (s.base_game_dir / "ServerScriptService/Services/FireService.luau").write_text("-- v2\n")
    seed(s, "fab", spec_file)
    assert forge_file.read_text() == "-- forge made this\n"
    assert (store.game_dir / "ServerScriptService/Services/FireService.luau").read_text() == "-- v2\n"
    assert store.load_state()["corrections"] == [{"note": "keep me"}]


def test_promote_copies_back_and_rejects_bad_paths(settings):
    s, spec_file = settings
    store = seed(s, "fab", spec_file)
    rel = "ServerScriptService/Services/FlareUpService.luau"
    (store.game_dir / rel).write_text("-- flare\n")
    dest = promote(s, "fab", rel)
    assert dest == s.base_game_dir / rel and dest.read_text() == "-- flare\n"
    with pytest.raises(ValueError):
        promote(s, "fab", "../etc/passwd.luau")
    with pytest.raises(FileNotFoundError):
        promote(s, "fab", "ServerScriptService/Nope.luau")


def test_base_files_protect_seeded_human_files(settings):
    s, spec_file = settings
    store = seed(s, "fab", spec_file)
    run = Run(s, store, llm=FakeLLM({}), ui=UI(io.StringIO()))
    assert run.base_files == set(RUNTIME_FILES)
    run.spec = store.load_spec()
    assert "ServerScriptService/Services/FireService.luau" in run.base_files
    assert "ServerScriptService/Services/FlareUpService.luau" not in run.base_files
    assert "ServerScriptService/Services/FireService.luau" not in run.game_files()


def test_flame_and_blame_seed_spec_is_valid():
    spec = json.loads((SEEDS_DIR / "flame-and-blame.json").read_text())
    assert spec["slug"] == "flame-and-blame"
    assert [m["path"] for m in spec["modules"]] == ["ServerScriptService/Services/FlareUpService.luau"]
    assert "flareups" in spec["modules"][0]["purpose"]


async def test_open_studio_uses_forge_studio_env(settings, monkeypatch):
    s, spec_file = settings
    seen = {}

    class FakeStudio:
        def __init__(self, _settings):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        async def select(self, name_hint=None):
            seen["hint"] = name_hint
            return "studio-1"

    monkeypatch.setattr("forge.studio.Studio", FakeStudio)
    monkeypatch.setenv("FORGE_STUDIO", "Forge-ai")
    run = Run(s, RunStore(s, "fab"), llm=FakeLLM({}), ui=UI(io.StringIO()))
    async with contextlib.AsyncExitStack() as stack:
        assert await run.open_studio(stack) is not None
    assert seen["hint"] == "Forge-ai"
```

Create `forge/seeds/flame-and-blame.json` (the test above checks it):

```json
{
  "title": "Flame and Blame",
  "slug": "flame-and-blame",
  "pitch": "Co-op chaotic firefighters on Roblox: alarm, burning town block, hose, axe, rescues, Blame awards.",
  "core_loop": "Lobby at Station 67 -> alarm -> teleport to the Town -> hose spreading fires, axe locked doors, carry civilians and pets to truck 67 -> 3-minute timer -> Blame results -> back to the station.",
  "modules": [
    {
      "path": "ServerScriptService/Services/FlareUpService.luau",
      "purpose": "New server service (ModuleScript) that ServerScriptService/Main.server.luau boots automatically; edit no other file. Return a table FlareUpService with Priority = 60; Init(self, services) only stores the services table (no calls, no yields); Start(self) starts ONE task.spawn loop; _selftest(self): (boolean, string) returns true, \"ok\". Loop: every 8 seconds, while workspace:GetAttribute(\"RoundState\") == \"Active\", take id = workspace:GetAttribute(\"MissionId\"), pick a part with services.MapService:RandomFlammable(id, rng) (rng = Random.new(os.time())) and call services.FireService:Ignite(part, nil); when Ignite returns true, call require(ReplicatedStorage:WaitForChild(\"ForgeTelemetry\")).count(\"flareups\", 1). Nil-guard services.MapService and services.FireService (peers can be missing). Use task.wait, never wait(); create no Instances.",
      "depends": [
        "ReplicatedStorage/Shared/Names.luau"
      ]
    }
  ],
  "acceptance": [
    "During an Active round, flare-ups ignite new fires in the Town (ForgeProbe counter flareups > 0)",
    "No errors or [Boot] warnings in the ForgeProbe report",
    "FlareUpService boots without any other file being edited"
  ]
}
```

Run: `.venv/bin/python -m pytest -q tests/test_seed.py`
Expected: FAIL at collection with `ModuleNotFoundError: No module named 'forge.seed'`.

- [ ] **Step 3: Implement `forge/seed.py`**

```python
"""Seed a Forge run from the human game tree (game/), and promote Forge's new files back.

    forge seed flame-and-blame        # runs/flame-and-blame/game <- game/, spec from forge/seeds/flame-and-blame.json
    forge promote flame-and-blame ServerScriptService/Services/FlareUpService.luau   # -> game/<same path>

A seeded spec records every human .luau file in spec["base_files"]; Forge's fixer never edits those
(only `forge correct` may, because a human asked). Re-seeding refreshes the human files and keeps
Forge's own new files, iterations and corrections.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

from forge.config import Settings
from forge.memory import RunStore

SEEDS_DIR = Path(__file__).parent / "seeds"
_IGNORE = shutil.ignore_patterns("__pycache__", "*.pyc", "manifest.json", ".DS_Store")


def seed(settings: Settings, slug: str, spec_path: Path | None = None) -> RunStore:
    """Copy game/ into runs/<slug>/game and write runs/<slug>/spec.json (+ state.json if new)."""
    spec_path = Path(spec_path) if spec_path else SEEDS_DIR / f"{slug}.json"
    spec = json.loads(spec_path.read_text())
    base = settings.base_game_dir
    store = RunStore(settings, slug)
    store.ensure()
    shutil.copytree(base, store.game_dir, dirs_exist_ok=True, ignore=_IGNORE)
    base_files = sorted(p.relative_to(base).as_posix() for p in base.rglob("*.luau"))
    store.save_spec({**spec, "slug": slug, "base_files": base_files})
    if not store.state_path.exists():
        store.save_state(store.new_state(str(spec.get("pitch", slug))))
    return store


def promote(settings: Settings, slug: str, rel: str) -> Path:
    """Copy one Forge-made file from runs/<slug>/game/<rel> to game/<rel>. Returns the destination."""
    clean = rel.strip().replace("\\", "/").lstrip("/")
    if clean.startswith("game/"):
        clean = clean[len("game/"):]
    if ".." in clean.split("/") or not clean.endswith(".luau"):
        raise ValueError(f"not a game .luau path: {rel!r}")
    src = RunStore(settings, slug).game_dir / clean
    if not src.is_file():
        raise FileNotFoundError(f"{src} does not exist")
    dest = settings.base_game_dir / clean
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    return dest
```

- [ ] **Step 4: Change `forge/loop.py`, `forge/cli.py` and `tests/test_loop.py`**

The edits are anchored on exact current text and assert that each anchor exists exactly once. That way they also apply cleanly on top of the `forge play` work landing in parallel. Run from the repo root:

```bash
python3 - <<'PYEOF'
from pathlib import Path


def edit(path: str, pairs: list[tuple[str, str]]) -> None:
    p = Path(path)
    s = p.read_text()
    for old, new in pairs:
        assert s.count(old) == 1, f"{path}: anchor not found exactly once: {old[:70]!r}"
        s = s.replace(old, new)
    p.write_text(s)


loop = Path("forge/loop.py").read_text()
old_copy = loop[loop.index("def copy_base_game"):loop.index("# ================================================================ the run")]
old_bf = loop[loop.index("    def _base_files(self) -> set[str]:"):loop.index("    # ---------------------------------------------------------- LLM calls")]
edit("forge/loop.py", [
    (old_copy, '''# The Forge runtime every generated game gets. Everything else in game/ is the human-built
# Flame and Blame tree, which only `forge seed` copies (forge/seed.py).
RUNTIME_FILES = ("ServerScriptService/ForgeProbe.server.luau", "ReplicatedStorage/ForgeTelemetry.luau")
RUNTIME_DIRS = ("tools",)
_IGNORE = shutil.ignore_patterns("__pycache__", "*.pyc", "manifest.json", ".DS_Store")


def copy_base_game(settings: Settings, dest: Path) -> None:
    """Copy the Forge runtime (ForgeProbe, ForgeTelemetry, tools/) from game/ into a generated game."""
    base = settings.base_game_dir
    for rel in RUNTIME_FILES:
        src = base / rel
        if src.exists():
            (dest / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest / rel)
    for d in RUNTIME_DIRS:
        if (base / d).is_dir():
            shutil.copytree(base / d, dest / d, dirs_exist_ok=True, ignore=_IGNORE)
    for root in ("ServerScriptService", "ReplicatedStorage", "StarterPlayerScripts"):
        (dest / root).mkdir(parents=True, exist_ok=True)


'''),
    ("        self._check_fn: Callable | None = None\n        self.base_files = self._base_files()\n",
     "        self._check_fn: Callable | None = None\n"),
    (old_bf, '''    @property
    def base_files(self) -> set[str]:
        """Files Forge's fixer must not touch: the runtime, plus every human file of a seeded game
        (spec["base_files"], written by `forge seed`)."""
        seeded = {p for p in (self.spec.get("base_files") or []) if isinstance(p, str)}
        return set(RUNTIME_FILES) | seeded

'''),
    ("            sid = await studio.select()\n",
     "            sid = await studio.select(os.environ.get(\"FORGE_STUDIO\") or None)\n"),
])

cli = Path("forge/cli.py").read_text()
edit("forge/cli.py", [
    ("# ---------------------------------------------------------------- main\n",
     '''# ---------------------------------------------------------------- seed / promote

def cmd_seed(args) -> int:
    from forge.seed import seed
    s = load_settings()
    store = seed(s, args.slug, Path(args.spec) if args.spec else None)
    spec = store.load_spec()
    mods = ", ".join(m["path"] for m in spec.get("modules", [])) or "(none)"
    print(f"seeded {store.game_dir} from {s.base_game_dir} ({len(spec['base_files'])} human files, fixer-protected)")
    print(f"Forge modules: {mods}")
    print(f"next: FORGE_STUDIO=<your Forge-ai place> forge run {args.slug} -n 1")
    return 0


def cmd_promote(args) -> int:
    from forge.seed import promote
    dest = promote(load_settings(), args.slug, args.path)
    print(f"promoted -> {dest}")
    print("next: git switch -c gf/<topic> && git add " + str(dest) + " && gh pr create --fill")
    return 0


# ---------------------------------------------------------------- main
'''),
    ("    return p\n\n\ndef main(",
     '''
    se = sub.add_parser("seed", help="copy game/ into runs/<slug>/game + spec from forge/seeds/<slug>.json")
    se.add_argument("slug")
    se.add_argument("--spec", help="spec JSON (default forge/seeds/<slug>.json)")

    pr = sub.add_parser("promote", help="copy a Forge-made file from runs/<slug>/game back into game/")
    pr.add_argument("slug")
    pr.add_argument("path", help="e.g. ServerScriptService/Services/FlareUpService.luau")
    return p


def main('''),
    ('"place": cmd_place,', '"place": cmd_place, "seed": cmd_seed, "promote": cmd_promote,'),
])

edit("tests/test_loop.py", [
    ("from forge.loop import UI, correct, new_game", "from forge.loop import RUNTIME_FILES, UI, correct, new_game"),
    ('''    # base runtime copied in
    for p in settings.base_game_dir.rglob("*.luau"):
        assert (game / p.relative_to(settings.base_game_dir)).exists(), p
''', '''    # only the Forge runtime is copied in, never the human Flame and Blame tree
    for rel in RUNTIME_FILES:
        assert (game / rel).exists(), rel
    assert not (game / "ServerScriptService/Main.server.luau").exists()
    assert not (game / "ReplicatedStorage/Shared").exists()
'''),
])
print("forge code edited")
PYEOF
```
Expected: `forge code edited`. Result, for review:
- `forge/loop.py`: `copy_base_game` copies only `RUNTIME_FILES` and `tools/`. `Run.base_files` is now a property (runtime ∪ `spec["base_files"]`) and the old `_base_files()` is gone. `open_studio` calls `studio.select(os.environ.get("FORGE_STUDIO") or None)`.
- `forge/cli.py`: `cmd_seed`, `cmd_promote`, two subparsers and two handler entries.
- `tests/test_loop.py`: asserts that only the runtime is copied into a new game.

- [ ] **Step 5: Run all Python tests**

Run: `.venv/bin/python -m pytest -q`
Expected: all pass, including the 6 new tests in `tests/test_seed.py`.

- [ ] **Step 6: Sync `docs/ARCHITECTURE.md`**

```bash
python3 - <<'PYEOF'
from pathlib import Path

p = Path("docs/ARCHITECTURE.md")
s = p.read_text()

def put(old: str, new: str) -> None:
    global s
    assert s.count(old) == 1, f"anchor not found exactly once: {old[:60]!r}"
    s = s.replace(old, new)

put("the always-present runtime (ForgeProbe, DevHook), which is copied into each generated game.",
    "the always-present runtime (ForgeProbe, DevHook) and, since the weekend kickoff, the human-built Flame and\n"
    "Blame tree. `forge new` copies only the runtime (`RUNTIME_FILES` = ForgeProbe.server.luau, ForgeTelemetry.luau,\n"
    "plus `tools/`). `forge seed <slug>` copies all of `game/` into `runs/<slug>/game` and records every human\n"
    "file in `spec[\"base_files\"]`; the fixer never edits those (`Run.base_files` = runtime + `spec[\"base_files\"]`),\n"
    "only `forge correct` may (a human asked). `forge promote <slug> <path>` copies a Forge-made file back into\n"
    "`game/` for a PR. `FORGE_STUDIO=<name part>` picks which connected Studio `forge new|run|correct` use.")
put("  cli.py               `forge new|run|correct|status|doctor|play|mcp`   [owner: loop]\n",
    "  cli.py               `forge new|run|correct|status|doctor|play|mcp|seed|promote`   [owner: loop]\n"
    "  seed.py              seed(settings, slug, spec_path=None) -> RunStore; promote(settings, slug, rel) -> Path\n"
    "  seeds/<slug>.json    Forge spec for a seeded run (flame-and-blame: FlareUpService)\n")
put("forge status [<slug>]                                # iterations, scores, call counts per role\n",
    "forge status [<slug>]                                # iterations, scores, call counts per role\n"
    "forge seed <slug> [--spec FILE]                      # runs/<slug>/game <- game/ (+ spec base_files)\n"
    "forge promote <slug> <path>                          # runs/<slug>/game/<path> -> game/<path>\n")
p.write_text(s)
print("ARCHITECTURE.md synced")
PYEOF
```
Expected: `ARCHITECTURE.md synced`. If an anchor assert fires because the `forge play` PR reworded a line, add the same three facts by hand: the runtime-only copy, seed/promote with `base_files`, and `FORGE_STUDIO`.

- [ ] **Step 7: Smoke-test the CLI**

```bash
.venv/bin/forge seed flame-and-blame
.venv/bin/forge status flame-and-blame
```
Expected: `seeded …/runs/flame-and-blame/game from …/game (N human files, fixer-protected)`, then `Forge modules: ServerScriptService/Services/FlareUpService.luau`. The status row shows `flame-and-blame 0 - - 0 …`. `runs/` is gitignored, so there is nothing to commit from this step.

- [ ] **Step 8: Commit and PR**

```bash
git add forge/loop.py forge/cli.py forge/seed.py forge/seeds/flame-and-blame.json tests/test_loop.py tests/test_seed.py docs/ARCHITECTURE.md
git commit -m "forge: runtime-only base copy, forge seed/promote with base_files guard, FORGE_STUDIO"
git push -u origin HEAD && gh pr create --fill && gh pr merge --squash --delete-branch   # after CI is green
```

### Task GF.2: Forge-ai place + Mubit warm-up runs (Dev B · GF · 0.5 h hands-on · Fri 22:00 → overnight)

**Why:** A Mubit task first trains at **25 kept examples**, and training has a daily cap that resets at 00:00 UTC (01:00 London). Without enough fixer examples in the fixer task, the console shows `Collecting examples (n of 25)` during the demo. Varied games give separate sessions, which Mubit needs for its test split.

**Files:** none in git (`place/` and `runs/` are gitignored).

**Interfaces:**
- Consumes: GF.1 (`forge new` copies only the runtime; `FORGE_STUDIO`).
- Produces: a second Studio window `Forge-ai.rbxlx` that Forge alone uses (port 34874), plus 25 or more recorded calls in each of the `designer`/`coder`/`fixer`/`critic`/`reflector` tasks.

- [ ] **Step 1: Make Forge's own place (empty) and open it**

```bash
mkdir -p place/empty
python3 game/tools/make_place.py --root place/empty --out place/Forge-ai.rbxlx
open -a /Applications/RobloxStudio.app place/Forge-ai.rbxlx
```
In Studio: Assistant → ⋯ → Manage MCP Servers → enable Studio as MCP server. From now on, run your own `forge watch` as `.venv/bin/forge watch --studio Forge.rbxlx` so it never matches `Forge-ai`.

- [ ] **Step 2: Check the wiring**

```bash
export FORGE_STUDIO=Forge-ai FORGE_SYNC_PORT=34874
.venv/bin/forge doctor
```
Expected: every line ✓, and `2 studio(s) connected` (yours and Forge-ai). In the Mubit console (https://app.mubit.ai/console/), Settings → training is **on** for the workspace (an admin switches it on; the Adapters page appears only once it is on).

- [ ] **Step 3: Run the warm-up batch (background, about 2 h)**

```bash
export FORGE_STUDIO=Forge-ai FORGE_SYNC_PORT=34874 FORGE_PLAY_SECONDS=20
for idea in \
  "Flame and Blame: co-op chaotic firefighters. Alarm rings at the fire station, run to a small town block where houses catch fire and fire spreads part to part. Hose tool with a water tank that refills at a hydrant puts fires out; axe tool breaks locked doors; carry trapped civilians and pets (dog, cat, panda) back to the fire truck. 3-minute rounds, then a results screen with funny Blame awards (most fires put out, most damage, panda saver). Chunky low-poly, built from parts." \
  "Lava rising obby: climb floating platforms before the lava reaches you, checkpoints every 10 platforms" \
  "Pizza delivery rush: grab pizzas from the oven, deliver to glowing houses before the timer, tips for speed" \
  "Zombie barricade: board up windows with planks, repair them between waves, last until sunrise" \
  "Garden tycoon: plant seeds, water them, sell vegetables at the stand, buy bigger plots" \
  "Snowball arena: two teams, snowballs knock players back, capture the flag in the middle" \
  "Haunted hotel escape: find 3 keys in dark rooms while a ghost wanders the corridors" \
  "Cat cafe: catch runaway cats and return them to their cushions before customers leave"; do
  .venv/bin/forge new "$idea" -n 3 || echo "run failed: $idea"
done 2>&1 | tee runs/warmup.log
```
Each idea becomes its own slug and Mubit session. Every call is a Mubit call (`MubitLLM`), and request ids are logged in `runs/<slug>/calls.jsonl`.

- [ ] **Step 4: Check the counts before you sleep, and again at 08:00**

```bash
.venv/bin/forge status
```
Expected: one row per warm-up game, with `fixer` totals summing to at least 25 by morning (re-run a few more ideas if not). In the console, **Tasks** lists the five roles. The fixer task reads `Collecting examples (n of 25)`, `Reviewing examples` or `Training`. Write the numbers and the time in the team chat; they go into the deck.

### Task GF.3: Forge builds FlareUpService on the real game (Dev B · GF · 1 h · Sat 10:30, after I.1)

**Why:** This is demo beat "Forge builds a contained v1 module". `FlareUpService` is a new GF file (05 M2's "it reignited" wave). Its seed purpose deliberately says "every 8 seconds", the naive design that the human corrects in GF.4.

**Files:** none in git yet (Forge writes `runs/flame-and-blame/game/ServerScriptService/Services/FlareUpService.luau`).

**Interfaces:**
- Consumes: Checkpoint A on `main` (MissionService rounds, MapService `RandomFlammable`, FireService `Ignite`); GF.1 `forge seed`.
- Produces: `FlareUpService` with `Priority = 60`, `Init(self, services)`, `Start(self)`, `_selftest(self): (boolean, string)`; counter `flareups`.

- [ ] **Step 1: Seed from the current `main` and build the Forge-ai place from it**

```bash
git switch main && git pull --rebase
.venv/bin/forge seed flame-and-blame
```
Expected: `seeded … (N human files, fixer-protected)` and `Forge modules: ServerScriptService/Services/FlareUpService.luau`.

- [ ] **Step 2: Let Forge build and playtest it (record the terminal for the video, e.g. QuickTime screen recording)**

```bash
export FORGE_STUDIO=Forge-ai FORGE_SYNC_PORT=34874 FORGE_PLAY_SECONDS=120
.venv/bin/forge run flame-and-blame -n 1
```
Expected terminal lines: `[coder] ServerScriptService/Services/FlareUpService.luau … <request id>`, then `[check] luau-compile N files ✓`, a Studio sync and playtest, `[critic] … score x/10`, and maybe `[fixer]` lines for FlareUpService only (base files are protected), then `[reflector]`.

- [ ] **Step 3: Read the counters Forge recorded**

```bash
ls runs/flame-and-blame/iterations/
python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(r.get('counters'), len(r.get('errors') or []))" runs/flame-and-blame/iterations/1/report.json
```
Expected: `counters` includes `flareups` of about 10 (one every 8 s, from the round going Active ~16 s in until 120 s), plus `rounds_started: 1` and `fires_spread > 0`; error count `0`. If `flareups` is missing, read `runs/flame-and-blame/game/ServerScriptService/Services/FlareUpService.luau` and `runs/flame-and-blame/iterations/1/console.txt`, then run `forge run flame-and-blame -n 1` once more (the critic and fixer loop).

- [ ] **Step 4: See it yourself in the Forge-ai Studio (the "before" clip)**

`mcp__Roblox_Studio__list_roblox_studios` → the `id` whose name contains `Forge-ai`. Then `start_stop_play {"is_start": true, "studio_id": "<id>"}`, then `execute_luau` (Server):

```lua
local DevHook = game.ServerStorage.DevHook
local t0 = os.clock()
repeat
	task.wait(0.25)
until workspace:GetAttribute("MapReady") or os.clock() - t0 > 15
DevHook:Invoke("GameConfig", ".Set", "AutoStart", false)
DevHook:Invoke("MissionService", "_startRound", "Town", 90)
task.wait(24)
local c = game:GetService("HttpService"):JSONDecode(game.ServerStorage.ForgeProbe:Invoke("report")).counters
return string.format("state=%s flareups=%s burning=%s", tostring(workspace:GetAttribute("RoundState")), tostring(c.flareups), tostring(select(2, DevHook:Invoke("FireService", "CountBurning", "Town"))))
```
Expected: `state=Active flareups=2` (roughly one per 8 s in the ~18 s since the alarm ended), plus a burning count well above the 3 start fires. Take a `mcp__Roblox_Studio__screen_capture` of the town on fire, then `start_stop_play {"is_start": false, …}`.

### Task GF.4: The correction moment + promote (Dev B · GF · 1.25 h · Sat 14:30, after I.2)

**Why:** This is the judged moment. A human correction goes through `forge correct` and becomes a **fixer call in the same Mubit task**. The next playtest shows the counter change. In the console, the call is rated Good.

**Files:**
- Create (promoted): `game/ServerScriptService/Services/FlareUpService.luau`

**Interfaces:**
- Consumes: GF.3's run. `forge correct <slug> <path> "<note>"` prints the request id (`x-middleware-request-id`).
- Produces: the corrected `FlareUpService` (max 2 per round, first ≥45 s after Active, ≥40 s apart, `Net.notify` "It reignited!"); a fixer request id for the console; the `gf/flareups` PR.

- [ ] **Step 1: Re-seed so Forge sees the P1 game (its own file is kept)**

```bash
git switch main && git pull --rebase && .venv/bin/forge seed flame-and-blame
```

- [ ] **Step 2: Record the correction (screen-record terminal + Studio side by side)**

```bash
export FORGE_STUDIO=Forge-ai FORGE_SYNC_PORT=34874 FORGE_PLAY_SECONDS=120
.venv/bin/forge correct flame-and-blame ServerScriptService/Services/FlareUpService.luau \
  "Flare-ups are spamming: about one every 8 seconds, so the Town is fully on fire before the crew gets there. Make them rare: at most 2 per round, the first no earlier than 45 seconds after RoundState becomes Active, at least 40 seconds apart, reset the count when a new round starts, and announce each one with Net.notify(\"all\", \"It reignited!\", \"bad\") using require(ReplicatedStorage.Shared.Net). Keep the flareups counter."
```
Expected: `human: Flare-ups are spamming…`, then `[fixer] ServerScriptService/Services/FlareUpService.luau (human) ✓ <request id>`, `[check] luau-compile … ✓`, `[studio] resync → Studio ✓`, and finally `● correction recorded in the fixer task <request id>`. **Copy the request id.**

Fallback, if GF.3's FlareUpService was already sensible: correct the fire pacing instead (a base file, which `forge correct` may edit because a human asked), then compare `fires_spread`:
`.venv/bin/forge correct flame-and-blame ReplicatedStorage/Config/FireConfig.luau "Fire spreads too fast: a whole house is gone in under a minute. Halve SpreadHeatPerSecond and raise DefaultFuel to 60 so a fire takes about 2 minutes to involve a house."`

- [ ] **Step 3: The "after" playtest, and compare**

```bash
.venv/bin/forge run flame-and-blame -n 1
python3 - <<'PYEOF'
import json, pathlib
its = sorted(pathlib.Path("runs/flame-and-blame/iterations").iterdir(), key=lambda p: int(p.name))
for p in its:
    r = json.loads((p / "report.json").read_text())
    print(p.name, "flareups =", (r.get("counters") or {}).get("flareups"), "errors =", len(r.get("errors") or []))
PYEOF
```
Expected: the GF.3 iteration shows `flareups ≈ 10`, and the new iteration shows `flareups ≤ 2` (2 if the 120 s play window covers 45 s + 40 s after Active), with `errors = 0`. During the GF.3-style live check you see the toast "It reignited!" in the Forge-ai client.

- [ ] **Step 4: Mubit console (record this)**

1. https://app.mubit.ai/console/ → **Requests** → filter Task = the fixer task, Session = `flame-and-blame`. Find the request id from Step 2 and open it: the user message starts with `Human playtester correction:`.
2. Click **Rate this reply: Good**.
3. **Tasks** → the fixer task: note its status and example count (`Collecting examples (n of 25)` / `Training` / `Testing` / `Passed`).
4. `.venv/bin/forge status flame-and-blame`. Expected: `human 1`, with the request id listed under `human:`.

- [ ] **Step 5: Promote and PR (Dev A reviews)**

```bash
git switch -c gf/flareups
.venv/bin/forge promote flame-and-blame ServerScriptService/Services/FlareUpService.luau
python3 game/tools/sync.py check --root game
git add game/ServerScriptService/Services/FlareUpService.luau
git commit -m "game(gf): FlareUpService built by Forge, corrected by a human (fixer call <request id>)"
git push -u origin HEAD && gh pr create --fill
```
Review checklist for Dev A: the header lists the API and counter; there are no top-level Instances; every `services.X` is nil-guarded; it runs only while `RoundState == "Active"`; there is no `wait()`. Merge when CI is green.

### Task GF.5: Mubit console capture for the video and deck (Dev B · GF · 1 h · Sat 16:00)

**Files:** none (screen recordings and screenshots go into the shared drive used for the video).

- [ ] **Step 1: Numbers for the deck**

```bash
.venv/bin/forge status
```
Record, per role, the total calls across all games, plus the number of human corrections. From the console's Tasks page, record each task's kept-example count and status.

- [ ] **Step 2: Try models (only if the fixer task shows `Passed`)**

Console → **Try models**: paste the user message from the GF.4 fixer request (Requests → that call → copy the user message) and run the provider model and the fixer adapter side by side. Screen-record it. If the task hasn't passed yet, record the Tasks page as it stands (`Collecting n of 25` or `Training`) and the rated request. The deck says plainly where training is.

- [ ] **Step 3: Optional second correction beat (only if `forge play` from the in-flight PR is on `main`)**

`.venv/bin/forge play "<goal>"` and then `.venv/bin/forge play-correct <run_id> <step> "<note>"` record a correction in the playtester task. Use it only if GF.4 is already recorded.

---

## Integration and demo (after the lanes)

The integration lead is Dev A. Each checkpoint is a 30–60 minute block that everyone attends. Lanes keep their own PRs small and merge before the checkpoint. The checkpoint itself runs **only from `main`**.

### Task I.1: Checkpoint A, the P0 loop (all · 1 h · Sat 09:30–10:30)

**Files:** none (merges only). Feeds: G1.1–G1.5, G2.1–G2.5, G3.1–G3.4.

**Interfaces:**
- Consumes: `MissionService:_startRound(id, secs)`, `ToolService:_spray(player, aim)`, `FireService:CountBurning(id)`, `VehicleService:GetTruck()`, `GameConfig.Set`, ForgeProbe `report`.
- Produces: a `main` that plays a whole P0 round, the shared place updated, and check-in 1.

- [ ] **Step 1: Merge the P0 PRs in dependency-light order:** G2 (map, truck) → G1 (fire, tools) → G3 (mission, HUD, squad). After each merge everyone runs `git pull --rebase` and CI must be green on `main`.
- [ ] **Step 2: Fresh local place from `main`** (Dev A): `git switch main && git pull && .venv/bin/forge place --open`, then `.venv/bin/forge watch --studio Forge.rbxlx`.
- [ ] **Step 3: Full P0 round over MCP.** Run `list_roblox_studios` → the local `id`, then `start_stop_play {"is_start": true, "studio_id": "<id>"}`, then wait until a Server datamodel exists. Then run `execute_luau` (Server), call **A, start the round**:

```lua
local HttpService = game:GetService("HttpService")
local DevHook = game.ServerStorage.DevHook
local t0 = os.clock()
repeat
	task.wait(0.25)
until workspace:GetAttribute("MapReady") or os.clock() - t0 > 15
DevHook:Invoke("GameConfig", ".Set", "AutoStart", false)
DevHook:Invoke("MissionService", "_startRound", "Town", 60)
task.wait(8) -- AlarmSeconds 6 + setup
local p = game.Players:GetPlayers()[1]
local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
local hose = p.Backpack:FindFirstChild("Hose")
if hum and hose then
	hum:EquipTool(hose)
end
local _, truck = DevHook:Invoke("VehicleService", "GetTruck")
local _, burning = DevHook:Invoke("FireService", "CountBurning", "Town")
return HttpService:JSONEncode({
	state = workspace:GetAttribute("RoundState"),
	mission = workspace:GetAttribute("MissionId"),
	burning = burning,
	water = p:GetAttribute("Water"),
	hose = p.Character and p.Character:FindFirstChild("Hose") ~= nil,
	truckX = truck and math.floor(truck:GetPivot().Position.X),
})
```
Expected: `{"state":"Active","mission":"Town","burning":3,"water":100,"hose":true,"truckX":400}`. `burning` may already be 4–6, because spread starts about 3 s after ignition.

Then call **B, the hose bot** (Server):

```lua
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local DevHook = game.ServerStorage.DevHook
local p = game.Players:GetPlayers()[1]
local town = workspace.Map.Town
local target: BasePart? = nil
for _, part in CollectionService:GetTagged("Burning") do
	if part:IsDescendantOf(town) then
		target = part
		break
	end
end
assert(target, "nothing burning in Town")
local hrp = p.Character.HumanoidRootPart
local stand = target.Position + Vector3.new(0, 0, 10)
hrp.CFrame = CFrame.lookAt(Vector3.new(stand.X, target.Position.Y + 1, stand.Z), target.Position)
task.wait(0.3)
local head = p.Character.Head
for _ = 1, 30 do
	DevHook:Invoke("ToolService", "_spray", p, (target.Position - head.Position).Unit)
	task.wait(0.1)
end
local c = HttpService:JSONDecode(game.ServerStorage.ForgeProbe:Invoke("report")).counters
return HttpService:JSONEncode({ outTarget = not target:HasTag("Burning"), water = p:GetAttribute("Water"), counters = c })
```
Expected: `outTarget = true`, `water = 64` (100 − 30 × 1.2), `counters.fires_extinguished >= 1`, `counters.water_used = 36`, `counters.fires_spread >= 1`, `counters.rounds_started = 1`, `counters.map_build_ms > 0`.

Then call **C, end the round and reset** (Server):

```lua
local HttpService = game:GetService("HttpService")
local DevHook = game.ServerStorage.DevHook
DevHook:Invoke("MissionService", "EndRound", "forced")
task.wait(1)
local mid = workspace:GetAttribute("RoundState")
task.wait(16) -- ResultsSeconds 15
local r = HttpService:JSONDecode(game.ServerStorage.ForgeProbe:Invoke("report"))
return HttpService:JSONEncode({ mid = mid, final = workspace:GetAttribute("RoundState"), rounds = r.counters.rounds_completed, errors = r.errors })
```
Expected: `{"mid":"Results","final":"Lobby","rounds":1,"errors":[]}`. Then run `mcp__Roblox_Studio__screen_capture` once during the round (Client view: the HUD timer pill and the tank gauge), and finally `start_stop_play {"is_start": false, …}`.

- [ ] **Step 4: Update the shared place from `main`** (Dev A). Open "Firefighter Mubit" in Studio (Team Create), then:

```bash
git switch main && git pull && .venv/bin/forge sync --studio Firefighter
```
Expected: `OK n files, changed: …`. In Studio: File → Publish to Roblox. Teammates then join the published game from the Roblox app to sanity-check it.

- [ ] **Step 5: Check-in 1** (by 12:00): Discord `/checkin` with "P0 loop works end to end: alarm → town fire spreads → hose + refill → round ends. Next: rescues, axe, Blame screen, Forge builds FlareUpService. Blockers: …".

### Task I.2: Checkpoint B, the P1 demo-able game (all · 1 h · Sat 13:30–14:30)

**Files:** none (merges only). Feeds: G1.6, G2.6, G3.5–G3.8.

- [ ] **Step 1: Merge the P1 PRs**, then rebuild the local place from `main` (as in I.1 Step 2).
- [ ] **Step 2: Solo round over MCP.** Run call A from I.1 (round 60 s). Then call **D, rescue + axe** (Server):

```lua
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local DevHook = game.ServerStorage.DevHook
local p = game.Players:GetPlayers()[1]
local hum = p.Character:FindFirstChildOfClass("Humanoid")
-- axe: break one locked door in the town
local axe = p.Backpack:FindFirstChild("Axe") or p.Character:FindFirstChild("Axe")
hum:EquipTool(axe)
local door: BasePart? = nil
for _, d in CollectionService:GetTagged("Door") do
	if d:IsDescendantOf(workspace.Map.Town) and d:GetAttribute("Locked") == true then
		door = d
		break
	end
end
assert(door, "no locked door in Town")
for _ = 1, 3 do
	DevHook:Invoke("ToolService", "_doorPrompt", p, door)
	task.wait(0.1)
end
hum:UnequipTools()
-- carry + deliver every rescuable (panda included)
local delivered = 0
for _, npc in CollectionService:GetTagged("Rescuable") do
	local id = npc:GetAttribute("RescueId")
	local _, ok = DevHook:Invoke("RescueService", "_carry", p, id)
	if ok then
		local _, done = DevHook:Invoke("RescueService", "_deliver", p)
		if done then
			delivered += 1
		end
	end
	task.wait(0.1)
end
task.wait(0.5)
local c = HttpService:JSONDecode(game.ServerStorage.ForgeProbe:Invoke("report")).counters
return HttpService:JSONEncode({ broken = door:GetAttribute("Broken"), delivered = delivered, counters = c })
```
Expected: `broken = true`, `delivered = 5`, `counters.doors_broken = 1`, `counters.rescued = 5`, `counters.rescued_panda = 1`. Because every fire is still burning, the round does **not** end as `allOut`.

Then run call C from I.1. Expected: `rounds = 1`, `errors = []`. While in `Results`, run `execute_luau` (Client) with `local g = game.Players.LocalPlayer.PlayerGui:FindFirstChild("Results"); return g ~= nil and g.Enabled`. Expected: `true`. Take a `screen_capture` of the Blame screen; it should show "Panda Whisperer" and "You are to blame.".
- [ ] **Step 3: Two-player test** (manual, about 5 min): Studio Test tab → Clients and Servers → 2 players → Start. Check that both clients see the same fires, helmets `01` and `02` and the same timer, that a rescue by one player shows on both HUDs, and that both see the same results. Close the test session.
- [ ] **Step 4: Shared place from `main`** (as in I.1 Step 4) and publish.
- [ ] **Step 5: Check-in 2** (during 12:00–18:00; do it now): `/checkin` with "Full round: rescues (panda), axe, Blame screen. Forge built FlareUpService on the real game; correction demo next."

### Task I.3: Feature freeze, Checkpoint C and gameplay clips (all · 1 h · Sat 17:30–18:30)

**Files:** none (merges only). Feeds: G1.7, G2.7, G3.9, GF.4's `gf/flareups`.

- [ ] **Step 1: Merge the P1.5 PRs and `gf/flareups` by 18:00.** After 18:00, `main` only takes bug fixes.
- [ ] **Step 2: Gate checks on `main`:**

```bash
python3 game/tools/sync.py check --root game
bash game/tests/run.sh
.venv/bin/python -m pytest -q
```
Expected: `0 failed`, every spec passes, pytest is green. Then run I.1 calls A–C and I.2 call D once more. Expected: `errors = []`, plus `flareups` ≤ 2 in a 60 s round.
- [ ] **Step 3: Shared place from `main`** (I.1 Step 4), then publish.
- [ ] **Step 4: Record raw gameplay** (QuickTime → New Screen Recording, 1080p) in the published game, with 2–4 people (the three devs and a friend), one full round each. Capture the I.4 clips 1–5: the alarm and teleport; fire spreading plus hose plus refill; the axe on the locked door then carrying the panda to truck 67; a teammate hosed and shoved with the "hosed" toast; the Blame screen.

### Task I.4: Record the demo video, 3:00 max (Dev A records and edits, all three appear · 2.5 h · Sat 18:30–21:00)

**Files:** none in git. Raw clips and the export go in the team drive. Name the export `flame-and-blame-forge-demo.mp4`.

The five moments from `docs/game/04-market-and-hooks.md` §7, plus the Mubit beat. Clips come from I.3 (gameplay), GF.3 and GF.4 (Forge terminal and Studio), and GF.5 (console).

| Time | Shot | Source | Voice-over (one line each) |
|---|---|---|---|
| 0:00–0:12 | Trailer still → our Station 67, alarm beacon spinning, red flash, "ALARM! FIRE AT 12 MAPLE ST." banner | I.3 clip 1 | "Flame and Blame was announced last week. We built the Roblox version this weekend, with an AI that learns from our corrections." |
| 0:12–0:35 | Teleport to the town; a part ignites its neighbours; hose spray; tank gauge drains; refill at the hydrant | I.3 clip 2 | "Fire spreads part to part, the hose beats it back, and the tank runs dry at the worst moment." |
| 0:35–0:55 | Axe through the locked door; panda inside; carry it (slow) to truck 67; "+1 RESCUED" toast | I.3 clip 3 | "Locked door, axe. Behind it: one extremely confused panda." |
| 0:55–1:10 | Teammate hosed in the face and shoved; "02 hosed 01!" toast | I.3 clip 4 | "Your own crew is the real hazard." |
| 1:10–1:30 | Blame results: stars, award cards flipping in, "Firefighter 02 is to blame." | I.3 clip 5 | "Every round ends with the Blame Board: the screenshot you send your friends." |
| 1:30–1:55 | Forge terminal: `forge run flame-and-blame`: coder writes FlareUpService, playtest, `flareups = 10`; Studio town engulfed | GF.3 | "Forge writes new game systems itself, runs them in Studio, and reads the playtest numbers. Every call goes through Mubit." |
| 1:55–2:25 | `forge correct …` typed; `[fixer] … (human) ✓ <request id>`; re-run `flareups = 2`; "It reignited!" toast | GF.4 | "Too much fire. We tell it in plain English. The fix is a new call in the same fixer task, and the next playtest proves it." |
| 2:25–2:50 | Mubit console: Requests → that request id, rated Good; Tasks → fixer task count/status; Try models side by side if Passed | GF.5 | "Every correction is a training example. Mubit turns the fixer task into our own adapter." |
| 2:50–3:00 | Title card "FLAME AND BLAME, built by Forge on Mubit" + repo URL | Keynote export | "Idea to game to correction to model update." |

- [ ] **Step 1:** Write the voice-over lines above into a single take (QuickTime → New Audio Recording), or speak live over the clips.
- [ ] **Step 2:** Cut the clips to the time slots (iMovie or QuickTime Edit → Trim). Speed up the Forge terminal 4–8× where it waits on the playtest.
- [ ] **Step 3:** Export 1080p MP4. Check the length:
  ```bash
  ffprobe -v error -show_entries format=duration -of csv=p=0 flame-and-blame-forge-demo.mp4
  ```
  Expected: a number ≤ `180`.

### Task I.5: Deck (PDF) and submission (Dev C writes the slides; Dev A submits · 2.5 h · Sat 21:00–23:30)

**Files:** none in git (the deck lives in Keynote or Google Slides; export to `flame-and-blame-forge.pdf`).

- [ ] **Step 1: Build 10 slides**
  1. **Title:** Flame and Blame on Roblox, built by Forge (team, repo URL).
  2. **The problem:** game ideas move faster than code. A trending trailer (16 Oct) has no playable Roblox version (04 §1).
  3. **What we built:** screenshot of the round (alarm → fire → hose → panda → Blame Board).
  4. **How the game is built:** 3 devs plus Forge in parallel. Lanes, frozen contracts (`docs/game/03` §10), auto-discovered services. Forge adds only new files.
  5. **Forge loop:** idea → designer → coder → luau-compile → Studio playtest (ForgeProbe counters) → critic → fixer → reflector. Five Mubit tasks with fixed system prompts.
  6. **The recurring task:** "fix this Luau file" (compile errors, critic issues, human corrections), all in one fixer task.
  7. **Correction → model update:** the GF.4 before/after (`flareups` 10 → 2), the request id, rated Good, the fixer task's status (screenshot).
  8. **Numbers:** calls per role, kept examples, corrections, latency (from GF.5 and `forge status`).
  9. **Why Roblox:** the market and hooks from 04 §2–4 (friendslop, cute rescues, the blame screenshot).
  10. **Next:** the v2 list (appendix below) and Forge learning the whole roadmap from our corrections.
- [ ] **Step 2:** Export to PDF and check that it opens and has 10 pages: `mdls -name kMDItemNumberOfPages flame-and-blame-forge.pdf` → `10`.
- [ ] **Step 3:** Discord `/submit`, then upload the MP4 and the PDF before **23:59**. Post in the team channel: "submitted <time>".
- [ ] **Step 4:** Until **Sun 05:00**, bug fixes only, from `main` via PR. If the video changes, re-export and resubmit (the latest submission counts).

---

## Appendix: v2 (after submission or as Forge iteration targets; no tasks here)

- Drivable truck 67 (VehicleSeat, siren toggle, ducks crossing, Road Rage blame); a real Travel phase.
- 2-storey houses with stairs and the cat in an upper window; Mission 2 "Block Party" with the 60 s second wave.
- Watering can and houseplant (Green Thumb), extinguisher, oxygen revive, slap, walkie-talkie and pings.
- Puddles + fuse box electrocution ("Shocking Behavior"); gas tanks and explosions; ceiling collapse; backdraft.
- Players catching fire and stop-drop-roll; ragdoll physics hits; throwing NPCs (Air Mail); the 2-carrier panda.
- Trampoline + window jumpers + ladder (apartment block); farm with a fire tornado; forest wildfire with wind; dam finale with a tidal wave (`HazardService`, `FinaleService`, Forest/Dam builders, all in lane GF).
- Room smoke, embers and re-ignition, Wet; material classes for fire.
- Audio: SoundGroups, `Sfx` module, vetted asset ids; music.
- First-person viewmodel gloves, head bob, trauma shake, onboarding arrows and first-round tutorial prompts.
- Score, property damage and a full star formula; blame vote and dunce helmet; cosmetics, progression, pet shelter, DataStore.
- Mesh-generated pets and firefighters (`generate_mesh`), MaterialVariants.
