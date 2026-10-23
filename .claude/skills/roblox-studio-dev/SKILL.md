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
If `forge watch` isn't running, push manually: `mcp__Roblox_Studio__execute_luau` (Edit) with
the output of `python3 game/tools/sync.py pull` after starting `sync.py serve --root game`.

## Playtest over MCP (do it yourself, never ask the human to press Play)
1. `list_roblox_studios` → `studio_id`. Use your **local** place (`Forge.rbxlx`). A name with
   `placeId` is the shared published place (Firefighter Mubit). Only playtest or read there; never
   push files except `forge sync` from `main`.
2. `start_stop_play {is_start: true}`. Then poll `get_studio_state` until `Server` is listed.
3. Wait a few seconds, then read **the ForgeProbe report** with `execute_luau` (datamodel `Server`):
   `return game:GetService("ServerStorage").ForgeProbe:Invoke("report")`. It returns JSON with
   errors (with traces), warnings, players, counters and instance count.
4. `get_console_output` for prints. Use `screen_capture` when the change is visual.
5. Use `character_navigation`, `user_keyboard_input` or `user_mouse_input` (datamodel `Client`) to
   act like a player.
6. **Always** `start_stop_play {is_start: false}` before you finish, even after a failure.

## Gotchas
| Symptom | Cause, and the fix |
|---|---|
| Edit tool rejected during play | Edit datamodel is locked while playing. Stop first, or use Server/Client. |
| `require` in `execute_luau` returns a fresh, empty module | `execute_luau` runs in its own VM. Reach live modules through `ServerStorage.DevHook:Invoke("Module", "Method", ...)`. |
| Studio freezes or MCP drops | Long loops without yielding. Add `task.wait()` in loops and chunk big builds. |
| Change didn't show up | `forge watch` printed ✗ (syntax error), or a playtest was running (the change is queued until Stop). |
| `forge watch` refuses: "published (Team Create) place" | You picked the shared place. Open your local one: `forge place --open`, then `--studio Forge`. |
| Second start/stop fails | A known Studio bug. Retry once and check `get_studio_state`. |
| Counters missing from the report | Call `require(game.ReplicatedStorage.ForgeTelemetry).count("name", 1)` on the server. |

## Luau rules
`task.wait`/`task.spawn` (never `wait`/`spawn`). Server-authoritative logic; clients only send
intent through RemoteEvents that the server creates and validates. Handle `Players.PlayerAdded`
**and** players already in the game. No `_G`. Keep each module small and owned by one system.

## Finish
1. `python3 game/tools/sync.py check --root game` passes.
2. The playtest has no errors in the ForgeProbe report.
3. Studio is back in Edit, and the Workspace has no leftover test objects.
4. Commit on your branch, then open a PR (`docs/TEAM.md`).
