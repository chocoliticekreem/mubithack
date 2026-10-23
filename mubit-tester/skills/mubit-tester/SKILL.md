---
name: mubit-tester
description: Use when checking that a Roblox game change actually works in play, reproducing a gameplay bug, testing multiplayer behaviour, or running playtests/scenarios against Roblox Studio with the mubit-tester MCP tools.
---

# Testing a Roblox game with mubit-tester

mubit-tester drives a **real Studio playtest**: every player, not just the local one. It can act as
any player, read the world through game tags, attributes and an event log, run scripted scenarios,
and run AI playtesters whose LLM calls go through Mubit. Tools are `mcp__plugin_mubit-tester_mubit-tester__*`.

## Before you start
- `status`: shows whether Studio is connected, the play state and the harness version. If the
  harness is missing, run `sync`. The game needs `ForgeTest.server.luau` and
  `ForgeTestAgent.client.luau` (in `game/`, symlinked from `mubit-tester/roblox/`).
- Use a **local** place. A Studio name containing `placeId` is a shared Team Create place, which
  you only read or playtest.

## Test a change (the loop)
1. `sync`, so your files are in Studio.
2. `scenario_run smoke`. Every player spawns and moves, with no errors.
3. Write or run a focused scenario: `act` a player, then `wait_until` or `assert` on `observe`,
   `query`, `counters` or `events`.
4. For fuzzy goals use `playtest(goal, players?)`, and to hunt bugs use `explore(minutes)`.
5. Read `errors` (the ForgeProbe report) and `events`. Fix the code and repeat from step 1.
6. Use `play_stop` when you're done, unless the session belongs to a human.

## Multiplayer
`multiplayer_start(players=N)` starts a Clients-and-Servers test, or gives manual steps if it can't.
`players` lists everyone. Address a player by name, UserId or helmet number "1"–"4". `act_all` makes
every player do the same thing.

## Mubit (why corrections matter)
`playtest`, `explore`, `suggest_fix` and the judge each use a fixed system prompt, so each is a
Mubit task. When an AI player made the wrong call, `playtest_correct(run_id, step, note, player?)`
re-asks it with your note. The corrected reply is a recorded call in the same task: a model update
in the making. Every report lists its Mubit request ids.

## Quick reference
| Need | Tool |
|---|---|
| What's around player 2? | `observe player="2"` |
| Where are the fires? | `query tag="Burning"` |
| Make player 1 refill | `act player="1" action="walk_to" args={"path": "<hydrant path>"}`, then `act ... "interact"` |
| Start a fire | `ignite near=[x,y,z]` |
| Tune live | `config module="FireConfig" key="SpreadHeatPerSecond" value=25` |
| What happened? | `events since=<t>`, `counters`, `errors` |
| Picture | `screenshot camera=[...] look_at=[...]` |
