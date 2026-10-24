# mubit-tester: the Mubit-powered game tester for Claude Code

One MCP server, `mubit-tester`, that Claude Code (or a person, through `forge test ...`) uses to
test the Roblox game. It goes beyond the built-in Roblox Studio MCP in three ways:

1. **Every player, not one.** An in-game harness drives *all* players: simulated Studio test clients
   or real friends in a Team Test session. Roblox's MCP can only drive the single local client.
2. **Game-aware.** It knows our tags, attributes, signals and counters, so it can say "the fire in
   House2 went out after 3 s of spraying" rather than "something changed".
3. **AI through Mubit.** Every LLM call (player agents, judge, explorer, fix suggestions) goes through
   Mubit with fixed system prompts. Each role is a Mubit task, and human corrections become
   training data.

## Layers

```
Claude Code ──MCP──▶ mubit-tester (forge/mcp_server.py)
                       ├─ forge/tester/harness.py   talks to ServerStorage.ForgeTest through Studio MCP
                       │                            (execute_luau in the Server datamodel)
                       ├─ forge/tester/ai.py        multi-agent playtests, explore, judge, fix suggestions (Mubit)
                       ├─ forge/tester/scenario.py  scripted scenarios with assertions (no LLM)
                       └─ forge/studio.py           raw Studio MCP: play/stop, console, screenshot, sync
Roblox (Studio only):
  ServerScriptService/ForgeTest.server.luau         command router, event log, server-side queries
  StarterPlayerScripts/ForgeTestAgent.client.luau   per-client actuator (walk, interact, equip, use, aim)
```

## In-game harness contract (Luau)

Active only when `RunService:IsStudio()`. The server creates:
- `ServerStorage.ForgeTest` (BindableFunction): `Invoke(cmd: string, argsJson: string) -> string`
  (JSON). It always returns `{"ok": bool, "result": any, "error": string?}`.
- `ReplicatedStorage.ForgeTestRemote` (RemoteFunction): server → client actuator calls. The client
  agent answers only `ForgeTest` requests and validates the command name.

Commands (args are a JSON object):

| cmd | args | result |
|---|---|---|
| `ping` | `{}` | `{version, players, studio, time}` |
| `players` | `{}` | `[{userId, name, helmet, pos, health, maxHealth, attrs, tool, backpack, carrying, downed}]` |
| `observe` | `{userId, radius?=120, max?=12}` | same shape as play.py's OBSERVE (`me`, `world`, `things`, `prompts`, plus `hud`, `ui` and `panels` fetched from that client by remote; `ui_error` when the game view is not rendering; `obby` in games with checkpoints, see Obbies) |
| `ui` | `{userId, max?=10}` | `{buttons: [{text, path, gui, x, y, w, h}], panels: [{gui, path, title}], total, viewport: [w, h], not_rendering?}`: visible, interactable GuiButtons in PlayerGui (path below PlayerGui, `[n]` for same-named siblings; x/y = center in Studio MCP mouse coordinates). `not_rendering`: the viewport is under 50 px (a minimized or hidden Studio window shows no game view during play, so no button has a size and no click lands) |
| `ui_target` / `ui_effect` | `{userId, path? \| text?}` / `{userId}` | arm a listener on one button and return where to click / after the click: `{fired, changed, effect}` (panels and GUIs opened/closed, buttons new/gone, HUD text new/gone); logs a `ui_press` event |
| `act` | `{userId, action, args}` | `{done, detail}`; actions below |
| `query` | `{tag?, near?: [x,y,z] \| userId, radius?, attrs?: [..], limit?=25}` | `[{path, name, tags, pos, dist, attrs}]` |
| `inspect` | `{path}` | `{class, name, pos, size, attrs, tags, children: [names]}` |
| `set_attr` | `{path, key, value}` | `true` |
| `ignite` | `{path}` (or `{near, radius}` for nearest Flammable) | path set Burning via FireService if present, else tags `Burning` + `FireLevel=1` |
| `extinguish` | `{path}` | as above, reversed |
| `teleport` | `{userId, pos \| path}` | `true` |
| `config` | `{module, key, value?}` | read, or set through `Config.Set` (live tuning) |
| `counters` | `{}` | ForgeTelemetry counters |
| `events` | `{since?: number}` | `{now, events: [{t, kind, data}]}` from a ring buffer (500), see below |
| `reset` | `{location?}` | `MapService:RebuildLocation` or all, plus clearing the event log |
| `round` | `{state?, wait?=30}` | read or force `Workspace.RoundState` via MissionService if present. `state: "Active"` while the last round is still finishing (RoundState not Active and not Lobby/Waiting/Intermission/Idle, e.g. `Results`) first waits up to `wait` s for it to end, then 1 s (MissionService frees its players only back in the lobby; a start during Results did nothing, run 2); `waited` in the result. Without MissionService the attribute is set at once |
| `teleport_stage` | `{userId, stage}` | stand the player on top of the checkpoint tagged `Checkpoint` with `Stage = stage` (waits out a respawn, re-teleports if the game's own spawn code moved the body) -> `{stage, path, pos, player_stage, stages, next}` |
| `obby_try` | `{userId, from_stage?, to_stage?, attempts?=1 (<=5), timeout?=20}` | a deterministic runner (no LLM): from checkpoint `from_stage` (default: the player's stage) toward the next one, up to `attempts` times -> `{done, reached, from_stage, to_stage, attempts: [{result: reached \| fell \| stuck, at, dist, secs, jumps, via, hazard?, last_floor?, detail}], detail}` |
| `bot_spawn` | `{names: [..] \| n, colors?: [[r,g,b]], near?: pos \| player, radius?=10}` | swarm bot testers: server-driven R15 NPCs in `Workspace.ForgeTestBots`, in a ring around `near`; returns their `players` info (`bot: true`, UserIds -1001, -1002, ...) |
| `bots` / `bot_clear` | `{}` | list the bots / destroy them all |
| `multi` | `{calls: [{cmd, args}], timeout?=90}` | run several commands concurrently (one thread each) in ONE call; returns `[{ok, result?, error?}]` in order |

Client `act` actions (run on that player's client by the agent):
`walk_to {pos | path, timeout?, arrive_radius?=1}` (PathfindingService, then a straight last
stretch; done when within `arrive_radius` studs of the target point horizontally, so a walk to a
pad's path ends standing on it; a solid target that blocks the way counts once beside it; returns
`dist` and `pos`; scenario `walk_arrive`), `jump`, `interact {path?}` (nearest enabled ProximityPrompt, or the one on that part:
`InputHoldBegin`, wait HoldDuration + 0.1, `InputHoldEnd`), `equip {name | slot}`, `unequip`,
`use {seconds?, aim?: [x,y,z] | path}` (faces the target, `Tool:Activate()`, holds for `seconds`,
also fires `Net.Tool.Spray` with the aim direction while held if that remote exists), `look_at
{pos | path}`, `say {text}` (bubble chat, for demo readability), `wait {seconds}`.

Macros (one tester decision = one whole interaction; `timeout` 2-60 s, default 20):
`go_touch {path}` (walk to the part, step onto it and hop until our character's Touched fires),
`go_use {path}` (walk into the prompt's MaxActivationDistance, then `interact`), `chase {path,
touches<=5}` (follow a moving part/model and count touches, 0.5 s apart), `repeat {action, args,
times<=5}` (any other action N times; `repeat` of `press` loops in Python). Each returns
`effect`: `{leaderstats, attrs, counters: {key: [old, new]}, hud_new, hud_gone, events}` with only
what changed (empty = nothing happened). Python waits per action (`harness.act_budget`), capped
under the 120 s MCP call limit.

`press {path | text}` is handled in Python (`Harness.press`), because a LocalScript can't fake a
click and firing the game's remotes would skip the UI under test: `ui_target` → a real
`user_mouse_input` click (instance path, else x/y) in the Studio window that drives that player →
`ui_effect`. Only players with a window can press: the harness's own window and the client
windows it was given (`Harness(studio, client_windows=[...])`), matched by UserId and the
`ForgeTestRemote` `Session` attribute, so another Studio's playtest is never clicked. Other players
get `{done: false, pressable: false}`.

Event log (server): player added/removed/died, tool equipped/activated, ProximityPrompt triggered
(prompt path + player), tag added/removed for `Burning`/`Rescuable`, attribute changes for
`RoundState`, `Water`, `Carrying`, `Downed`, `RescueState`, and every `ForgeTelemetry.count`.

## Python contract

```python
# forge/tester/harness.py
class Harness:                                   # wraps a forge.studio.Studio
    def __init__(self, studio, *, client_windows=None): ...   # client_windows: Client studio ids of a multiplayer test
    async def press(self, user_id, path=None, text=None) -> dict  # real GUI click: {done, fired, changed, effect, detail}
    async def call(self, cmd: str, **args) -> Any        # raises HarnessError on ok=false
    async def teleport_stage(self, user_id, stage) -> dict  # obbies; act() routes these two commands too
    async def obby_try(self, user_id, from_stage=None, attempts=1, timeout=None) -> dict
    async def ensure_ready(self, timeout=30) -> dict      # play running + ping ok (starts solo play if not playing)
    # thin helpers: players(), observe(user_id), act(user_id, action, **args), query(...), events(since), counters()

# forge/tester/scenario.py
async def run_scenario(harness, scenario: dict) -> dict   # {"name", "steps": [{"act"|"wait_until"|"assert"|"call": ...}]}
    # wait_until/assert: {"cmd": "...", "args": {...}, "path": "result.0.attrs.Water", "op": "<"|">"|"=="|"exists"|"changed", "value": ..., "timeout": s}
    # returns {name, passed, steps: [{n, ok, detail, ms}], events}

# forge/tester/ai.py   (every LLM call through forge.llm via Mubit)
async def multi_playtest(settings, goal: str, players: int | None = None, steps: int = 20, roles: list[str] | None = None, *, llm=None, studio=None, game_dir=None) -> dict
    # one `player` agent per connected player, acting concurrently each tick; shared goal plus a per-player role
    # (e.g. "nozzle", "rescuer", "chaos"); judge at the end. Report saved to runs/playtests/<run_id>/report.json
    # (same shape as forge.play reports, plus players: [...] and per-step player ids)
async def explore(settings, minutes: float = 3, players=None, *, llm=None, studio=None) -> dict   # bug hunt: role `explorer`
async def ui_pass(harness, surfaces, roster) -> list[dict]   # scripted press of the assigned surfaces before free play
# mubit_tester/surfaces.py   (no LLM)
def derive_surfaces(spec, game_dir, observations, limit=5) -> list[dict]   # [{name, gui, actions, source}]
def coverage(surfaces, presses, scripted=None) -> dict   # {surfaces: [{name, gui, assigned, presses, fired, changed,
    # actions_pressed, scripted?}], pressed, total, gaps, scripted_presses}
def pick_button(buttons, text, path=None) / order_actions(actions) / close_button(buttons, gui) / new_buttons(effect)
def pass_note(rec) -> str                 # 'PASS: fired, opened a panel; Claim: fired, changed the screen; ...'
# mubit_tester/swarm.py
async def run_swarm(settings, players: int = 10, minutes: float = 3, *, personas=None, pool=6, max_steps=40,
                    llm=None, studio=None, harness=None, studio_name=None, screenshots=True, shot_every=5,
                    triage=True, stop_play=True, keep_bots=False, slug=None, lanes=True, goal=None,
                    progress=None) -> dict
    # `players` persona testers at once (speedrunner, griefer, newbie, ui_clicker, economy, physics, coop,
    # accessibility, soak, edge). Connected real players take the screen personas first (ui_clicker,
    # accessibility, economy, ...); the rest are bot testers (bot_spawn). Each tester loops observe -> one
    # `swarm_tester` call (Mubit, bounded by `pool`) -> act until the deadline. Screenshots: Studio's capture
    # camera aimed at that tester's character (serialized). Bugs: clustered, merged by one `swarm_triage`
    # call, ranked by severity (high 3, medium 2, low 1) x frequency (distinct testers).
    # Report: runs/playtests/<run_id>/report.json (kind "swarm"); dashboard lanes: one per tester in
    # runs/<slug>/tests/<run_id>-NN-<persona>/{report.json, step-NN.png}.
class MuxHarness(Harness)   # calls within 40 ms share one `multi` (reads in one lane, acts per action name)
async def suggest_fix(settings, run_id: str, bug_index: int, *, llm=None) -> dict   # critic+fixer roles → {path, problem, patch_preview}
```

New fixed prompts (Mubit tasks): `forge/prompts/explorer.md`. `player` and `judge` are reused.
Swarm: `mubit-tester/prompts/swarm_tester.md` (persona in the user message) and `swarm_triage.md`.

Bot testers are bodies, not Players: the game's touch/physics/collision code sees them, but Player-keyed
features (leaderstats, ownership, GUIs, ProximityPrompts, tools) don't, and their prompt says so. `act` for
a bot runs on the server: `walk_to` (PathfindingService, else MoveTo), `go_touch`/`chase` (walk onto the
part), `jump`, `look_at`, `say`; `interact`/`go_use`/tools answer `done: false`. A bot that dies or falls
out of the world respawns at its spawn after 3 s (`player_died` with `bot: true`).

## UI coverage (every UI feature gets a press)

A round goal rarely names the menus, so testers skipped them (Flame and Blame run 1: 0 presses, the
battle pass Claim never exercised). Each playtest now derives up to 5 **UI surfaces** at tick 1
(`mubit_tester/surfaces.py`, generic for any game):
- client scripts under `game_dir` (`StarterPlayerScripts`, `StarterGui`): per script, the first
  TextButton/ImageButton text is the surface (`Pass`), the other texts its actions (`Get Premium
  Pass`, `Claim`; state labels ending in -ed and `X`/`Close` are skipped), the ScreenGui name its `gui`;
- the live `ui` of the first observations (buttons a player can press now);
- the spec (title, pitch, core loop, acceptance, features) to rank design-named surfaces first.
A script surface is kept only when the live UI or the spec confirms it, so a foreign or stale script
never adds work. Surfaces are assigned round-robin to players who can press (`can_press`); each
presser's user message gets `## UI features assigned to you` (never the frozen prompts). The report
gets `ui_surfaces` and `ui_coverage` (`pressed`/`total`, per surface presses, fired, actions pressed,
and `gaps` such as `"Pass (BattlePassGui): never pressed, its panel was never opened"` or
`"... opened, but Claim never pressed"`). The judge sees the gaps and `round_digest` carries
`ui_coverage`, so the auditor sees an unproven menu. `forge fix` passes the run's own `game_dir`.

**Scripted pass before free play** (`ai.ui_pass`, no LLM; run 2: PASS and GO NOW! were assigned and pressed 0
times). Right after the surfaces are assigned at tick 1, every assigned surface is pressed once by its presser
with a real click (`Harness.press`), then each of its actions that is on screen once it is open ("where enabled":
a battle pass shows Claim only on a claimable tier; state labels such as Claimed are never pressed), purchase-like
actions (buy, premium, robux, unlock, gift) last because a purchase prompt can cover the next clicks, then what it
opened is closed again (an X / Close / Back button of that GUI, else the entry button). A live-only surface's actions
are the buttons its press made appear. Then the players are observed again and free play starts. The presses land
in the event log like a tester's (`ui_presses`); `report["ui_pass"]` keeps `[{surface, gui, player, presses: [{kind
entry|action|close, button, path, fired, changed, effect, detail}], skipped, blocked?}]`; `ui_coverage` gets
`scripted_presses` and, per surface, `scripted` (one line, also in the presser's `## UI features assigned to you`
and in the judge's UI coverage block as `scripted_pass`). When the presser's game view is not rendering (`ui`
`not_rendering`), nothing is clicked and the surface is `blocked` with that reason, which the coverage gap repeats.

## Physics probe (jitter and drift)

ForgeProbe samples, every 0.5 s, the root parts of unanchored assemblies that should be at rest: mass
>= 2, no Humanoid in their models (characters, NPCs), no occupied Seat/VehicleSeat in their model
(being driven); at most 150 roots, rescanned every 5 s, a new root is ignored for 3 s while it settles.
Over a window of 8 samples (4 s): **jitter** = speed > 1 stud/s or spin > 1 rad/s in >= 4 samples
while it stays within 3 studs; **drift** = moving in >= 6 samples, >= 3 studs net, under 12 stud/s.
Each newly flagged assembly bumps counter `physics_jitter` / `physics_drift`. It shows up in the
ForgeProbe report (`physics`), in testers' observations (`probe.physics`), the report's `physics`, the
judge's ForgeProbe section and `round_digest.physics`. Anchored parts moved by script (`PivotTo`) are
not sampled.

## Obbies (teleport_stage, obby_try)

Contract, shared with the ObbyKit: a checkpoint is a part (or model) tagged `Checkpoint` with a number attribute
`Stage` (1..N); a hazard is tagged `KillPart`; a player's stage is their `Stage` attribute, else `leaderstats.Stage`.
In games with checkpoints `observe` adds `obby: {stage, stages, max_stage, nearest: {stage, dist}, next: {stage,
path, pos, dist}, hazards: [{name, path, dist, pos}]}` (hazards within 60 studs, at most 6).

`obby_try` runs on the server: it takes physics ownership of a real player's character for the run (restored
after; a bot is server-owned anyway). Route: PathfindingService waypoints (AgentCanJump) followed with
Humanoid:MoveTo, jumping at each Jump waypoint (its take-off point); a platform edge (no floor 1.5 studs ahead),
a step up and a stall (1.2 s without getting closer) also jump. Outcomes: **reached** = standing on the next
checkpoint (grounded, over its top face), or the player's stage rose to it during this run (a stage reached
earlier says nothing, obbies only count up); **fell** = died, touched a KillPart, or dropped 12 studs below the
lower checkpoint (`hazard`, `at`, and `last_floor`: the last part it stood on); **stuck** = 4 s without getting
closer, or the timeout. A run never starts off its checkpoint: when the game kills or moves the body right after
the teleport, it teleports once more, else the attempt is `stuck: could not start`. One call answers within 100 s
(attempts that would not fit are skipped); Python waits `attempts * (timeout + 15) + 5` s, at most 115.

Testers get both as macros (`OBBY_GUIDE`, only when the observation has `obby`): sample the course
(stage 1, about every tenth of `max_stage`, the last one) instead of walking it from stage 1, then look closer at
the stages that fail. MCP: `act(player, "obby_try", {from_stage, attempts})`; Python: `Harness.teleport_stage`,
`Harness.obby_try`.

## Checks: a setup failure is unknown, not a pass or a bug

A check that never reaches its situation errors with `setup: ...` (or returns a detail built from one, such as
`startRound failed: setup: ...`). `forge.checks.setup_failure(result)` detects both. `run_check` reruns such a
check once in a fresh playtest (stop, play, wait for a player); still failing to set up, it is marked `setup: true`
and counts as unknown everywhere: not a regression for a fix's guards, not an anomaly at a cycle's start
(`run_suite(...)["unknown"]`), not a proof for the reproducer (status `setup`, retried), never an anomaly from the
plan (`as_anomalies`). In a batch, restarts stop once a fresh playtest did not help. `forge.startRound` first waits
out a round still in its Results phase when the game has a MissionService (so round checks run back to back).
Writers (scenarist, reproducer, reviewer) get `checks.SETUP_RULE` in the user message: assert the situation
happened before the behaviour (`assert(tierAfter > tierBefore, "setup: no tier-up")`), and reach live modules
through `ServerStorage.DevHook` (a `require()` in a check is a separate copy with empty state). `lint_setup` flags
a body with no `setup:` assertion at all: the reproducer and the scenarist ask once for a correction.

## QA protocol (`forge qa`, `mubit_tester.protocol`)

The disciplined tester: every run follows the same five phases a senior engineer would, with a
screenshot at every step.

1. **Understand.** Read `../spec.json` (title, pitch, core loop, acceptance list), census the live
   game (CollectionService tags with counts, Workspace attributes, the player's attributes and
   leaderstats, counters, first observation) and take `step-00.png`.
2. **Plan.** `test_planner` (Mubit) writes a numbered plan: hypotheses, then per step an action, a
   settle time, the expected observable and machine checks (`{path, op, value}` into the snapshot:
   `counters.*`, `player.leaderstats.*`, `player.attrs.*`, `world.tags.*`, `obs.hud`, `errors.new`, ...;
   ops `== != > >= < <= exists missing increased decreased changed unchanged contains near`).
3. **Execute.** Per step: snapshot → act → settle → snapshot + `step-NN.png` + new console lines +
   new ForgeProbe errors + game events → checks. `step_judge` (Mubit) rules when a check fails, an
   error appears, a step has no checks, or the step is visual (then it sees the screenshot).
4. **Investigate.** On a mismatch (at most 3 per run): reproduce (run the step again,
   `step-NN-repro.png`), narrow down (the judge's read-only probes: `query`, `inspect`, `counters`,
   `events`, `observe`, `console`, `screenshot`, `config`), then `step_judge` in investigate mode writes
   the bug: minimal repro, expected/actual, root cause, severity and a fix target file.
5. **Report.** Pass/fail per acceptance item, bugs (behaviour, server error, visual) sorted by
   severity with screenshots and fix target, and `visual_judge` (Mubit, key screenshots attached as
   images) for UI overlap, missing visuals and ugliness. `report.md` + `report.json` in
   `runs/<slug>/tests/<run_id>/`, mirrored to `runs/playtests/<run_id>/` so `report`, `suggest_fix`
   and `playtest_correct` work on it.

```bash
.venv/bin/forge qa [focus] --root games/tiny-tycoon/game --studio Forge-agents-22 --steps 10
.venv/bin/forge play-correct <run_id> <step> "note"   # step 0 = plan, n = step n's judge, -1 = visual review
```
Images go through Mubit's Anthropic-compatible endpoint as image blocks (OpenAI shape for
`FORGE_PROVIDER=openai`); the calls log `images: N`. Prompts: `mubit-tester/prompts/{test_planner,
step_judge,visual_judge}.md` (fixed; everything per call is in the user message).

## MCP tools (`mubit-tester`)

One shot (`mubit_tester/testrun.py`, `mubit_tester/bisect.py`):
- `test_feature(description, game?, scenarios?, checks=True, playtest=True, players?, steps=12,
  sync=True, screenshot=True)`: sync -> play -> plan (smoke + scenarios matching the description +
  the game's executable checks + an AI playtest) -> run -> ForgeProbe errors -> screenshot -> stop.
  Verdict first (`PASS` / `FAIL` / `ERRORS` / `INCONCLUSIVE`, why, next step), then a table. Saved as
  `runs/tests/<id>/{record.json, report.md, shot.png}`; the record holds a sha1 manifest of the game.
  With `game=<slug>` every saved check runs and the results go to `runs/<slug>/checks/results.json`
  (the checks part of `forge done`).
- `test_runs(limit)`, `diff_since_last_run(test_id?, against?)`: verdict trend, flipped results,
  new/vanished errors and bugs, files changed between the two runs.
- `watch_errors(seconds, poll)`: new ForgeProbe errors while you poke the game (streams progress).
- `bisect_versions(game, check, good?, bad?)`: binary search over a Forge game's `GameVersions`
  tags; each version is exported to a scratch folder, synced (prune), played and `check` run
  (saved check id, scenario name or inline Luau); the current version is re-synced afterwards.
- `qa_test(focus?, steps=12, game?)`: wraps `mubit_tester.ai.qa_test` (the QA protocol: understand,
  plan, execute with screenshots, investigate, report). Summary first (QA PASS/FAIL, acceptance
  counts, bugs with fix targets), key screenshot paths (first two as images), the report.md path.
  `playtest_correct` on its run: step 0 = plan, n = step judge, -1 = visual review; the reply names
  the Mubit task (`test_planner` / `step_judge` / `visual_judge` / `player` / `explorer`).
- `swarm(goal, testers=10, minutes=5)`: thin wrapper over `mubit_tester.swarm.run_swarm(settings,
  goal, testers, minutes, progress, ...)` (only the keyword args its signature takes are passed;
  `format_swarm(result)` formats it when present).

Session: `status` (verdict + next step first), `studios` (`*` = window in use), `play_start(timeout)`,
`play_stop`, `multiplayer_start(players)` (best effort via StudioTestService, otherwise
instructions), `sync(game?, prune)` (refuses shared places; moves to a free port when another sync
server holds the default), `preview`.
World: `players`, `observe(player)`, `query` (table), `inspect`, `counters`, `events(since)`,
`errors` (ForgeProbe), `console`, `screenshot(focus?, camera?, look_at?)` (image + saved path).
Control: `act(player, action, args)`, `act_all(action, args)`, `teleport`, `ignite`, `extinguish`,
`set_attr`, `config`, `reset`, `round`.
Testing: `scenario_run(json | name)`, `scenario_list`.
AI (Mubit): `playtest(goal, players?, steps?, roles?)`, `explore(minutes)`, `swarm(players?=10, minutes?=3,
pool?=6, personas?, steps?)` (also `forge test swarm --players 10 --minutes 3`), `playtest_correct(run_id,
step, note, player?)`, `suggest_fix(run_id, bug)`, `report(run_id)`, `reports()`.
Players are addressed by name, UserId or helmet number (`"1"`..`"8"`).

Long tools take an MCP `Context` and send `notifications/progress` when the client gave a progress
token (`progress_reporter(ctx)`); every message also goes to stderr.

Extensions: `load_extensions()` imports each module in `EXTENSIONS` (`mubit_tester.studio_bridge`)
plus `$MUBIT_TESTER_EXTENSIONS` and calls its `register(mcp)`; a missing module is skipped and a
broken one only logs to stderr. Helpers for extension tools: `open_studio`, `harness_for(studio)`,
`progress_reporter(ctx)`, `tool_errors()`, `sync_into(studio, root)`, `game_root(game)`.
