---
name: swarm-testing
description: Use when many testers should hit a Roblox game at once ("throw 10 testers at it", "stress the lobby", "parallel AI testers", load or concurrency bugs in squads, pads, countdowns or mission instances).
---

# Swarm testing

## Overview
`swarm(goal, testers, minutes)` runs many AI testers in parallel and merges their bugs into one
report. Swarms cost Studio windows: the machine allows **4 agent Studios at once**, and one
local multiplayer test holds **at most 8 players**. Plan around both, and a swarm report is a list
of *leads* to reproduce, not of facts.

## Steps
1. **Window and slot.** `studios`: the `*` row must be your own local place, never a `(shared)`
   one. Only if your place isn't open yet: `sh scripts/studio-slot.sh acquire <place>`, then open
   it (an open window already holds its slot).
2. **A sharp goal.** "Join a squad pad with 3 others, ride the countdown, launch, and all arrive
   in the same mission instance". Not "test the lobby".
3. **Run:**
   - `swarm(goal, testers=N, minutes=5)`.
   - If it says swarm isn't in this checkout: `multiplayer_start(players=min(N, 8))`, then
     `playtest(goal, mode="squads", squads=2)` for lobby/mission goals, or `playtest(goal,
     players=min(N, 8))` otherwise. Tell the user how many testers really ran.
   - Asked for more than 8? Run batches of 8 and say so. Never claim 10 ran when 8 did.
4. **Always** `play_stop` when it's over, and `studio-slot.sh release <place>` if you took a slot.
5. **Leads → facts.** Merge duplicates. For each bug that matters, reproduce it the
   testing-roblox-features way: `test_feature(description, players=2, playtest=false)` with a
   scenario that tests it (`lobby_countdown`, `squad_parallel`). Only reproduced bugs go in
   "what breaks".
6. Hand off the reproduced bugs with the triaging-tester-reports skill.

Cost: each AI tester makes about one Mubit call per tick. 10 testers × 5 min is hundreds of
calls, so for a quick look use fewer testers or fewer minutes.

## Report format
```
Swarm: <N actually run> testers × <minutes> min on "<goal>"  (via swarm | multiplayer fallback)
Reproduced: <bug> (test <id>) ...
Unconfirmed leads: <bug> (seen by k testers) ...
Play stopped: yes
```

## Common mistakes
| Mistake | Fix |
|---|---|
| Asking for 10 players in one multiplayer test | 8 is the maximum: run batches |
| Reporting raw swarm bugs as confirmed | Step 5: reproduce, or list as a lead |
| Running a swarm beside other Studio work | Run it alone. It is heavy |
| Forgetting `play_stop` / the slot | Step 4, every time, including after a failure |
