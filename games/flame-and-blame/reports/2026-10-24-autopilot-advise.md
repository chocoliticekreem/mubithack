# Autopilot advice: flame-and-blame (read-only)

2026-10-24T06:20:38+00:00 · root `game` at game version `a3e483f` · 297 evidence items (86 from older builds, 117 live on this build) from 2 record folders + the human run reports + the source + a fresh session (QA `None`, swarm `20261024-061830-3165`) · 7 Mubit calls. No game file was changed.

Evidence: audit 13, bug 14, calls 11, census 1, code 60, fix 8, genre 11, metric 12, report 30, stat 17, stuck 1, swarm 1, test 11, tooling 14, ttfr 1, untouched 91, warning 1

Fresh probe on `a3e483f` (a round started through the test harness), watched 25 s: older playtests ran longer, so rate counters (fires, spreads, flare-ups) read low; treat their regressions as leads to confirm: 0 runtime errors, 0 physics flags. Screenshot: `/Users/arvin/orca/mubithack/.claude/worktrees/agent-a64a42c3817f925e2/runs/autopilot-advise/flame-and-blame/20261024-071737/fresh-screenshot.png`.

## Verified on the current build (1)

| # | score | from | kind | improvement | evidence |
|---|---|---|---|---|---|
| 1 | 12.5 (raw 12.5) | anomaly detector + gap finder + gap finder + gap finder + gap finder | fix | **No fire activity during an Active round (flare-ups dead)**: In an Active round the Town shows flareups=0, fires_spread=0, fires_ignited=1 and instance.fires=0. The previous version had flareups=8, fires_spread=323 and fires_ignited=9. Find why FlareUpService does not ignite new fires and why the in… | stat:regression:flareups, stat:regression:fires_spread, stat:regression:fires_ignited, stat:regression:fire_cap_hit (old builds: 6b442ba, 7dddccd, 9d93c0a) |

## Missing or never exercised (code scan / counters that never moved) (2)

| # | score | from | kind | improvement | evidence |
|---|---|---|---|---|---|
| 1 | 4.8 (raw 6) | gap finder | fix | **Core loop counters never move: extinguish, rescue, water, axe**: Make a short scripted path work end to end: obtain hose, spray a burning part (fires_extinguished and water_used rise), refill at the truck (refills rise), axe a locked door (axe_swings, doors_broken), carry a civilian to truck 67 (rescued… | untouched:fires_extinguished, untouched:rescued, untouched:water_used, untouched:axe_swings |
| 2 | 3 (raw 3.75) | gap finder | feature | **Blame results screen and rewards never seen**: Verify that at round end (timer 0 or all fires out) the server builds Blame awards (for example 'Most Water Wasted', 'Top Rescuer'), shows a results UI for about 10s, awards XP (xp_awarded), saves data (data_saved), and returns players to … | untouched:awards_built, untouched:blame_callouts, untouched:xp_awarded, stat:regression:data_saved |

## Unverified (old): from older builds, not reproduced by the fresh session (5)

| # | score | from | kind | improvement | evidence |
|---|---|---|---|---|---|
| 1 | 1.86 (raw 6.19) | anomaly detector + gap finder | test | **Gear and grab pipeline unverified on the current build**: On the current build, walk a real player to the gear rack and truck locker in the lobby and trigger Grab Hose, Grab Axe and Grab Extinguisher. Confirm that the tool lands in the backpack and that inv_grabs and hands_grabs increase. Also co… | test:20261023-234121-d2b8#bug3, untouched:inv_grabs, untouched:hands_grabs, test:20261023-233116-7965#bug2 (old builds: 7dddccd, 8524c85, 9d93c0a) |
| 2 | 1.05 (raw 3.5) | gap finder | fix | **Hose feels useless and carried pets cannot be dropped**: Tune the hose so that spraying a fire for about 2-3s extinguishes it. Spread should be slower than the player's extinguish rate in the first minute. Add a visible water stream and a steam puff on hit. Make a carried civilian or pet droppab… | report:flame-and-blame#1, cycle:flame-and-blame:5#a2, stat:regression:fires_spread (old builds: 9d93c0a, ccd7423) |
| 3 | 0.6 (raw 2) | gap finder | fix | **Fire and structure tick budget overruns**: Amortize the fire and structure ticks. Process a capped number of fires per frame in round-robin, use spatial lookups for spread (not a full part scan), and enforce the fire cap. Target fire_tick_over_budget = 0 with 100+ fires on screen. | test:20261023-233116-7965#bug4, cycle:flame-and-blame:5#a5, report:2026-10-24-run1#18 (old builds: 7dddccd, 9d93c0a, dc17120) |
| 4 | 0.54 (raw 1.8) | gap finder | visual | **Inconsistent truck and Reel prompt labels**: Use one consistent name ('Truck 67') on every truck prompt. The Reel prompt text must reflect state: 'Grab Hose' when empty-handed, 'Refill Water' when holding a hose or extinguisher. Use clear ActionText and ObjectText with matching style… | test:20261023-222227-0f05#bug4, test:20261023-214633-d65c#bug3 (old builds: 353f6d4, 6b442ba) |
| 5 | 0.32 (raw 1.05) | gap finder | fix | **Battle pass auto-claims and prompts on every tier-up without a press**: In the battle pass service, tier-ups should only mark rewards as claimable. Claim should happen on an explicit UI press, and premium purchase prompts should appear only when the player opens the premium UI, never automatically. Keep battle… | report:2026-10-24-run1#9, untouched:battlepass_claims (old builds: 7dddccd) |

## Tester-harness fix list (tooling, not game bugs)

- **ProximityPrompt hold/press never triggers from the harness**: 12 sightings (12 on older builds), e.g. [medium] Hop on seat prompt held but never triggers: Step 1: interact on CrewSeat_4 (in_range, 4.6 studs, hold 0.1) returned 'held, not triggered'. I was not seated and the observ… (test:20261023-234121-d2b8#bug1, test:20261023-234121-d2b8#bug2, test:20261023-234121-d2b8#bug4, test:20261023-233116-7965#bug1)
- **Pathfinding / navmesh: the harness can't path (NoPath)**: 2 sightings (2 on older builds), e.g. [low] No walkable path from the locker room to the Mission Board: Step 5: walk_to MissionBoard stopped 31.7 studs short ('straight (no path: NoPath)'). Step 7: the move to (-46,3.… (test:20261023-215443-af1d#bug3, test:20261023-213840-5034#bug2)

## Anomaly detector summary

The round reaches Active in the fresh session, so the old Mission Board blockers look fixed. But nothing burns: flareups, fires_spread and fires_ignited all collapsed (flareups 8 -> 0, fires_spread 323 -> 0, fires_ignited 9 -> 1), and the world reports instance.fires=0 during Active. The first acceptance criterion (flareups > 0) fails. The tester was also still on the lobby pad during Active, and the HUD fire count contradicts world state.

## Gap finder summary

The game is not yet proven to be fun in the first 5 minutes. In the fresh session the round went Active, but no flare-ups fired (flareups 8 → 0), the fire count was 0, and the tester was still on the lobby pad with a HUD that disagreed with the world. Every core-loop counter (extinguish, rescue, water, axe, Blame awards) is still at 0, and the older tests that failed on gear and board prompts have not been re-proven.

## Statistical pre-filter (no LLM)

- `stat:regression:rubble_settled` high: rubble_settled was 1 in the previous version, now 0
- `stat:regression:flareups` high: flareups was 8 in the previous version, now 0
- `stat:regression:npcs_toasted` high: npcs_toasted was 3 in the previous version, now 0
- `stat:regression:fires_spread` high: fires_spread was 323 in the previous version, now 0
- `stat:regression:data_saved` high: data_saved was 1 in the previous version, now 0
- `stat:regression:structure_collapses` high: structure_collapses was 1 in the previous version, now 0
- `stat:regression:fire_cap_hit` high: fire_cap_hit was 8 in the previous version, now 0
- `stat:regression:windows_shattered` high: windows_shattered was 1 in the previous version, now 0
- `stat:regression:rubble_released` high: rubble_released was 1 in the previous version, now 0
- `stat:untouched:xp_awarded` high: xp_awarded is declared by the game but stayed 0 this version (no tester or player ever triggered it)
- `stat:regression:traffic_despawned` medium: traffic_despawned fell 59 -> 25 vs the previous version
- `stat:regression:fires_ignited` medium: fires_ignited fell 9 -> 1 vs the previous version
- `stat:untouched:battlepass_tier_up` medium: battlepass_tier_up is declared by the game but stayed 0 this version (no tester or player ever triggered it)
- `stat:untouched:battlepass_claims` medium: battlepass_claims is declared by the game but stayed 0 this version (no tester or player ever triggered it)
- `stat:untouched:battlepass_equips` medium: battlepass_equips is declared by the game but stayed 0 this version (no tester or player ever triggered it)
- `stat:untouched:battlepass_emotes` medium: battlepass_emotes is declared by the game but stayed 0 this version (no tester or player ever triggered it)
- `stat:untouched:+77` medium: 77 more declared counters never moved: blame_callouts, data_missions_recorded, fires_extinguished, gear_windows_smashed, gear_breaches, gear_pries, gear_saw_cuts, gear_ladders, gear_kicks, gear_climbs, gear_hatch_drops, gear_peg_grabs, gear_unlocks, gear_loadouts_saved, hands_grabs, hands_slap_revives, hands_doors_pushed, hands_pushes, hands_axe_far, hands_axe_tonks, hands_axe_hits, heat_downs, heat_sweaty, heat_hose_cooled, inv_grabs, inv_props_carried, inv_drops, inv_throws, inv_swaps, inv_fumbles

Fresh QA focus: Re-check on the current build whether these older reports still happen: Grab prompts (Hose, Axe, Extinguisher) don't trigger and the backpack…; Nozzle role starts with no hose or tool; HUD fire count disagrees with world state and mission ID; Fire and structure tick budget overruns; Mission and fire counts disagree between HUD and world state; HUD fire and rescue counters disagree with world state; Mission ID mismatch between world and instance; Inconsistent truck owner labels on prompts; No visible round start after Mission Board 'Pick a call' triggered; Round never starts from Lobby; Reel p…

Mubit request ids: anomaly_detector `mreq_01a16c90a7a17a528b547f583d37ff11`, gap_finder `mreq_01a16c910cf975618a3cae825a4eee39`
