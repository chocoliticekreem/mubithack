---
name: testing-roblox-features
description: Use when asked to check, verify or prove that a Roblox gameplay change or feature works in Studio ("does the hydrant refill work now?", "check my change", "test X before the demo"), or before saying a game change is done.
---

# Testing a Roblox feature end to end

## Overview
`test_feature` (mubit-tester) does the whole loop in one call: sync, play, plan, run, errors,
screenshot, stop. **A PASS proves only what its rows tested.** Smoke passing proves players
spawn, not that your change works. The job is to make some row exercise the exact claim.

## Steps
1. **Window.** `studios`. The `*` row must be your own local place. If it is a `(shared)` place,
   run `studios(select="<your place>")` first. Never test in a shared Team Create place.
2. **State the claim as something measurable.** "Twice as fast" means a number:
   *Water goes 0 → full in ≤ N s at a hydrant*. If you don't know the old number, measure the new
   one and report it with "not compared with before".
3. **Run it:** `test_feature(description="<the measurable claim>", game=<slug if it's a Forge game>)`.
   If you're short on time, `playtest=false` skips the LLM (about 1 minute).
4. **Read the Plan section and the rows. Does any row test the claim itself?**
   - Yes, and the verdict is PASS: done. Report it (below).
   - No (only smoke, or unrelated scenarios): the verdict does not count. Add a check that
     measures the claim, then rerun:
     - First look for a shipped scenario in `scenario_list` (e.g. `hydrant_refill`,
       `friendly_fire_blame`, `lobby_countdown`). Pass it with `scenarios=["smoke", "<name>"]`.
       `scenarios` replaces the automatic pick, so name smoke as well.
     - For a timing claim, copy the closest one (`mubit-tester/scenarios/<name>.json`) and set
       its final `wait_until` `timeout` to the claimed seconds. Passing then proves the speed.
       Pass it inline: `scenarios=["smoke", "<the JSON as one string>"]`.
     - In a Forge game you can also add `runs/<slug>/checks/<id>.luau` returning
       `{ ok = ..., detail = "<measured numbers>" }`.
   - An AI playtest row is supporting evidence. A scenario or check row is proof.
5. **FAIL or ERRORS:** fix the code, run the same `test_feature` again, then `diff_since_last_run`
   to show what flipped and which files changed. If it used to pass in a Forge game, use
   `bisect_versions(game, check)`.
6. **INCONCLUSIVE:** nothing proved anything. Treat it as not working yet: go to step 4.

## Reporting format (always)
```
<VERDICT>: <claim>  (test <id>)
Proved by: <row(s) that test the claim, with their measured detail>
Not covered: <what no row tested>, or "nothing"
Errors: <ForgeProbe summary>   Screenshot: <path>
```
Never write "works" without a "Proved by" row that tests the claim.

## Quick reference
| Need | Tool |
|---|---|
| Full check, verdict first | `test_feature(description, game?, scenarios?, playtest?)` |
| What changed since the last run | `diff_since_last_run()` |
| Past runs | `test_runs()` |
| Errors while you poke by hand | `play_start`, then `watch_errors(seconds=60)` while you `act` |
| Which version broke it (Forge game) | `bisect_versions(game, check)` |
| A picture of something specific | `screenshot(focus="2")` or `focus="<instance path>"` |

## Common mistakes
| Mistake | Fix |
|---|---|
| Reporting PASS from smoke and unrelated scenarios | Step 4: a row must test the claim |
| "Quick, so skip testing the actual change" | `playtest=false` is quick. A missing check is not |
| Testing in whatever window is selected | Step 1: check the `*` row |
| Leaving play running after hands-on poking | `play_stop` (`test_feature` stops by itself) |
| Re-running without comparing | `diff_since_last_run` after every fix |
