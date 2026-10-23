---
name: mubit-tester
description: Use when checking that a Roblox game change actually works in play, reproducing a gameplay bug, testing multiplayer, co-op or squad behaviour (lobby, pads, countdown, parallel mission instances, friendly fire, revive, hose tether), or running playtests/scenarios against Roblox Studio with the mubit-tester MCP tools.
---

# Testing a Roblox game with mubit-tester

mubit-tester drives a **real Studio playtest**: every player, not just the local one. It can act as
any player, read the world through game tags, attributes and an event log, run scripted scenarios,
and run AI playtesters whose LLM calls go through Mubit. Tools are `mcp__plugin_mubit-tester_mubit-tester__*`.

## Before you start
- `status`: Studio connection, play state, harness version, and which game services are live or
  still K0 stubs (plus SquadPads, running instances, enabled missions). If the harness is missing,
  run `sync`. The game needs `ForgeTest.server.luau` and `ForgeTestAgent.client.luau` (in `game/`,
  symlinked from `mubit-tester/roblox/`).
- Use a **local** place. A Studio name containing `placeId` is a shared Team Create place, which
  you only read or playtest. Never sync a branch into a shared place.

## Test a change (the loop)
1. `sync`, so your files are in Studio.
2. `scenario_run smoke`. Every player spawns and moves, with no errors.
3. Write or run a focused scenario: `act` a player, then `wait_until` or `assert` on `observe`,
   `query`, `counters` or `events`.
4. For fuzzy goals use `playtest(goal, players?)`, and to hunt bugs use `explore(minutes)`.
5. Read `errors` (the ForgeProbe report) and `events`. Fix the code and repeat from step 1.
6. Use `play_stop` when you're done, unless the session belongs to a human.

## Multiplayer sessions
- `multiplayer_start(players=N)` (1-8) runs `StudioTestService:ExecuteMultiplayerTestAsync(N, args)`
  from the Edit datamodel, finds the new **Server** and **Client** windows with
  `list_roblox_studios`, routes every harness call to the Server window and waits until N players
  joined. `multiplayer_start(players=2, add=true)` adds clients to a running test (`AddPlayers`).
- If that fails it returns the manual way: Test tab → Clients and Servers → Players N → Start.
  Then `studios` / `players`; calls find the Server window by themselves.
- **Real friends (Team Test):** Team Create the place, Test tab → Team Test. The server runs in
  the cloud, so the harness relays every call through a client (`status` shows `via client`).
  Outside a local Studio test add a BoolValue `ServerStorage.ForgeTestEnabled = true` (attribute
  `AllowUserIds = "id1,id2"` for non-creators) and remove it before publishing.
- Address players by name, UserId or helmet "1"–"4" everywhere: `act`, `teleport(to=...)`,
  `act ... args={"target_player": "2"}` (aim / walk / interact at another player).

## Squads, lobby and parallel missions
| Need | Tool |
|---|---|
| Who is on which pad / squad, countdowns, enabled missions | `squads` |
| Running mission instances (state, time left, fires, rescues, players) | `instances` |
| Put player 2 on pad 1 | `queue player="2" pad=1` (teleport; `walk=true` to walk) |
| Skip the board + countdown | `launch pad=1 mission_id="house_fire"` |
| Start a mission for some players directly | `mission_start mission_id=... players=["1","2"]` |
| End an instance | `mission_end instance_id="M1"` |
| Look at one instance only | `players/observe/query/events(instance_id="M1")` |

`observe` already hides things inside *other* instances (what that player can really see).
`events(instance_id=..., kinds=[...])` scopes the log; kinds include `joined_pad`, `left_pad`,
`countdown`, `launched`, `mission_started`, `mission_state`, `entered_instance`, `delivered`,
`overheated`, `downed`, `revived`, `ragdolled`, `hose_hit`, `kinked`.

## Scenarios (scripted, no LLM)
Shipped: `smoke` (all players), `lobby_countdown`, `squad_parallel`, `coop_panda`,
`friendly_fire_blame`, `heat_overheat`, `hose_tether`, `hydrant_refill`. `scenario_list` shows what
each requires. A scenario whose service is still a K0 stub, or that needs more players than are
connected, reports **SKIP (reason)**, not FAIL; a `require` step mid-scenario gives
**PASS (partial: reason)**. Step kinds: `call`, `act` (player, list or "all"), `wait_until`,
`assert`, `wait`, `parallel` (two players hold one prompt), `require`; flags `soft`, `allow_fail`,
`unless`; ops include `within` and `!contains`. Harness command `hook {module, fn, args}` calls a
module's test hooks (e.g. `HoseLine._attachTest`).

## AI playtests (Mubit)
- `playtest(goal, players?)`: one Mubit `player` agent per player, acting concurrently, then a judge.
- `playtest(goal, mode="squads", squads=2)`: the full loop lobby → pad → countdown → mission →
  results with the players split into squads, one `player` call per player per tick, a co-op goal.
  The harness queues idle players, launches squads stuck on their pad, and starts missions directly
  while the lobby is a stub. The report adds phases, instances and **per-player blame/credit**.
- `explore(minutes)`, `suggest_fix(run_id, bug)`.

`playtest`, `explore`, `suggest_fix` and the judge each use a fixed system prompt, so each is a
Mubit task. When an AI player made the wrong call, `playtest_correct(run_id, step, note, player?)`
re-asks it with your note. The corrected reply is a recorded call in the same task: a model update
in the making. Every report lists its Mubit request ids.

## Quick reference
| Need | Tool |
|---|---|
| What's around player 2? | `observe player="2"` |
| Where are the fires in M1? | `query tag="Burning" instance_id="M1"` |
| The panda in M1 | `query tag="Rescuable" instance_id="M1" where={"Kind": "Panda"}` |
| Make player 1 refill | `act player="1" action="walk_to" args={"path": "<hydrant path>"}`, then `act ... "interact"` |
| Player 1 hoses player 2 | `act player="1" action="use" args={"seconds": 3, "target_player": "2"}` |
| Revive player 1 | `teleport player="2" to="1" offset=[3,0,0]`, `act player="2" action="interact" args={"target_player": "1"}` |
| Start a fire | `ignite near="1"` (or `near=[x,y,z]`) |
| Tune live | `config module="FireConfig" key="SpreadHeatPerSecond" value=25` |
| What happened? | `events since=<t>`, `counters`, `errors` |
| Picture | `screenshot camera=[...] look_at=[...]` |
