---
name: triaging-tester-reports
description: Use when a playtester, teammate or AI tester report describes bugs in a Roblox game in loose words ("hose sometimes doesn't spray", "my buddy got blamed", "horn too quiet") and has to become fixes, or when a test_feature/playtest/swarm report lists several bugs.
---

# Triaging a tester report into fixes

## Overview
One report usually holds several unrelated problems written as feelings. Split it into separate
problems, **reproduce each one before touching code**, fix one at a time, and prove each fix with
the same test.

## Steps
1. **Split.** Write one line per problem, in this form: *observed / expected / where*. Then sort
   each one:
   - **bug**: wrong behaviour;
   - **tuning**: a number feels wrong (volume, speed, damage); it's a Config value;
   - **unclear**: you can't tell what they mean. Ask, or note it.
2. **Find the code.** Is it the human game in `game/`, or a Forge game? The paths the user names
   tell you (`game/...` vs `runs/<slug>/...`), and forge `games()` lists the Forge slugs. If
   unsure, it's `game/`. That decides step 5.
3. **Reproduce each bug:** look in `scenario_list` for a shipped scenario first (e.g.
   `friendly_fire_blame`, `hydrant_refill`, `hose_tether`). Then run
   `test_feature(description="<observed→expected>", scenarios=["smoke", "<name>"], playtest=false)`,
   or without `scenarios` and let it pick. "Sometimes" means run it 2-3 times or use `players=2`. Not
   reproduced = not fixed: report it as *could not reproduce* with what you tried. Don't guess-fix.
4. **Tuning:** `config(module, key, value)` lets you try values live; then change the Config file.
5. **Fix:**
   - **game/ (human code):** edit the one file behind the bug (stay in that system's file).
   - **A Forge game:** `tester_report(slug, text=<the original words>, run_ids=[<playtest run ids>])`.
     Triage turns them into anomalies, and anything the auditor missed becomes an auditor
     correction (Mubit training). Then `improve_game(slug)`, which fixes and verifies.
   - For one specific known bug, `suggest_fix(run_id, bug)` gives a candidate patch to read
     before you apply anything.
6. **Prove it:** rerun the exact `test_feature` from step 3, then `diff_since_last_run`. The row
   must go FAIL → PASS with no new errors.

## Report format
| # | problem (observed → expected) | kind | reproduced? (test id) | fix (file) | verified (diff) |
|---|---|---|---|---|---|

End with what is still open and why.

## Common mistakes
| Mistake | Fix |
|---|---|
| Filing the whole message as one issue | Step 1: one line per problem |
| Fixing from the description alone | Step 3: reproduce first, or say you couldn't |
| `tester_report` on human `game/` code | It is for Forge games (`runs/<slug>`). For game/, fix by hand |
| Treating "too quiet" as a code bug | Tuning: change Config, check live with `config` |
| "Fixed" without rerunning the same test | Step 6: same test, `diff_since_last_run` |
