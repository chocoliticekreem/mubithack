---
name: roblox-studio-dev
description: Use when writing, changing, debugging or playtesting Luau game code in this repo (game/ or runs/<slug>/game), when Roblox Studio or mcp__Roblox_Studio__* tools are involved, or when a change has to be checked inside a running Roblox game.
---

# Developing the Roblox game with Studio MCP

## Overview
Game code lives on disk as `.luau` files and is pushed into Roblox Studio automatically. You edit
files, never scripts inside Studio. You check your work with a real playtest driven over the Studio
MCP, then commit. The loop is: **edit file → it syncs → playtest → read the report → fix → commit.**

## File → Studio mapping
| On disk (`game/…`) | In Studio |
|---|---|
| `ServerScriptService/X.server.luau` | Script (server) |
| `StarterPlayerScripts/X.client.luau` | LocalScript (under StarterPlayer) |
| `…/X.luau` | ModuleScript |
| directories | Folders |

Only scripts sync. Build parts, maps, UI and remotes **from code** (`Instance.new`), never by hand in
Studio, because hand-made objects aren't in git. The game's file layout per system is in
`docs/game/03-tech-architecture.md`. Make each new system its own file so nobody else's file changes.

## Setup check (once per session)
```bash
.venv/bin/forge doctor            # Studio ✓ needed; if none: forge place --open, then enable MCP
.venv/bin/forge watch --studio Forge   # run in background; every save → luau-compile → Studio
```
If `forge watch` can't run, push once with `.venv/bin/forge sync --studio <name>`. It checks the
files, rebuilds the manifest, serves them and pulls them in, and it never deletes anything.

## Playtest over MCP (do it yourself, never ask the human to press Play)
1. `list_roblox_studios` → `studio_id`. Pick by id; the name is just a label. A local file shows as
   `Forge.rbxlx`. A name with `placeId` is the **shared** published place (Firefighter Mubit, Team
   Create), which may hold teammates' live work. In the shared place, only playtest or read, and
   push only with `forge sync` from `main`.
2. `start_stop_play {is_start: true}`. Then poll `get_studio_state` until `Server` is listed.
3. Wait a few seconds, then read **the ForgeProbe report** with `execute_luau` (datamodel `Server`):
   `return game:GetService("ServerStorage").ForgeProbe:Invoke("report")`. It returns JSON with
   errors (with traces), warnings, players, counters and instance count.
4. `get_console_output` for prints. Use `screen_capture` when the change is visual.
5. Use `character_navigation`, `user_keyboard_input` or `user_mouse_input` (datamodel `Client`) to
   act like a player.
6. **Always** `start_stop_play {is_start: false}` before you finish, even after a failure.

## Testing with mubit-tester (MCP)
`mcp__mubit-tester__*` drives **every** player through the in-game harness (`ServerStorage.ForgeTest`,
Studio only) and knows our tags/attributes. Contract: `docs/TESTER.md`. Players are addressed by
name, UserId or helmet `"1"`..`"4"`. Same tools from the shell: `forge test <tool> ...` (`-h` lists them).

**How to test a change (6 lines):**
1. `sync` (or keep `forge watch` running) → `status` shows harness ready after step 2.
2. `play_start` (solo) or `multiplayer_start {players: 2}` (if it can't, it prints the Test-tab steps).
3. `scenario_run {scenario: "smoke"}`, then a scenario for your feature (`scenario_list`; add JSON to `scenarios/`).
4. Poke it: `players`, `query {tag}`, `act {player, action, args}`, `ignite`, `events {since}`, `counters`.
5. `errors` (ForgeProbe) must be empty; for open-ended checks `playtest {goal, roles}` or `explore {minutes}`.
6. `play_stop`, always, even after a failure.

AI tools go through Mubit. If an AI player chose wrong at step n, call
`playtest_correct {run_id, step, note: "it should have ...", player}`: that is a training example in
the player's Mubit task. `suggest_fix {run_id, bug}` proposes a patch; `report`/`reports` show runs.
Scenario steps: `call`, `act` (`player: "all"`, `offset`), `wait_until`/`assert` (`cmd`, `path`,
`op`, `value`, `from`, `timeout`, `any`), `wait`; `save` + `"$var.path"` reuse results
(see `forge/tester/scenario.py`).

## Gotchas
| Symptom | Cause, and the fix |
|---|---|
| Edit tool rejected during play | Edit datamodel is locked while playing. Stop first, or use Server/Client. |
| `require` in `execute_luau` returns a fresh, empty module | `execute_luau` runs in its own VM. Reach live modules through `ServerStorage.DevHook:Invoke("Module", "Method", ...)`. |
| Studio freezes or MCP drops | Long loops without yielding. Add `task.wait()` in loops and chunk big builds. |
| Change didn't show up | `forge watch` printed ✗ (syntax error), or a playtest was running (the change is queued until Stop). |
| `forge watch` refuses: "published (Team Create) place" | You picked the shared place. Open your local one: `forge place --open`, then `--studio Forge`. |
| Second start/stop fails | A known Studio bug. Retry once and check `get_studio_state`. |
| A new file didn't arrive with a manual `sync.py pull` | The manifest was stale. Use `forge sync`, or run `sync.py manifest --root game` first. |
| A deleted file is still in Studio | A no-prune sync never deletes. In your local place `forge watch` prunes. In the shared place, delete just that instance with `execute_luau` (Edit). |
| Errors about sound or asset permissions in the report | The place uses assets it isn't allowed to load. They're unrelated to your change, so ignore them unless you added that asset. |
| Counters missing from the report | Call `require(game.ReplicatedStorage.ForgeTelemetry).count("name", 1)` on the server. |

## Luau rules
`task.wait`/`task.spawn` (never `wait`/`spawn`). Server-authoritative logic; clients only send
intent through RemoteEvents that the server creates and validates. Handle `Players.PlayerAdded`
**and** players already in the game. No `_G`. Keep each module small and owned by one system.

## Finish
1. `python3 game/tools/sync.py check --root game` passes.
2. `scenario_run smoke` passes, `errors` is empty, and your feature's scenario or `playtest` meets its goal.
3. Studio is back in Edit, and the Workspace has no leftover test objects.
4. Commit on your branch, then open a PR (`docs/TEAM.md`).
