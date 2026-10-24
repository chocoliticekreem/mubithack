---
name: improving-games-until-done
description: Use when an existing Forge game (runs/<slug>) should keep improving until it is ready ("keep improving until forge done is green", "the tycoon is scuffed, fix it", "make it good"), or when deciding whether a Forge game is finished.
---

# Improving a Forge game until `done` is READY

## Overview
Read the [shared game production guide](../../../docs/GAME_PRODUCTION_GUIDE.md) from the mubithack checkout. Apply its priority bands, relevant genre/capability checks and verified-outcome rules. All AI decisions and generated fixes/checks must use Mubit-backed tasks.

`done(slug)` is the implemented readiness bar. Read its current parts rather than assuming this list is exhaustive. They include:
- **checks:** every executable check passes;
- **features:** every agent-added feature is verified;
- **open:** the last fix cycle left nothing high or medium;
- **critic:** the latest score is ≥ 8 (n/a for seeded games).

Choose the lever for the missing evidence. Repeating `improve_game` blindly can leave feature and coverage gaps.
The current bar also includes experience and interaction evidence. A green bar does not waive additional requirements for the user's target stage in the shared guide.

## The loop
1. `done(slug)`: write down the missing parts. That is your baseline.
2. Per missing part:
   | Part | Lever |
   |---|---|
   | checks: "no check run yet" | mubit-tester `test_feature("<core loop>", game=slug, playtest=false)` runs every saved check and records the results that `done` reads |
   | checks: failing ids | `improve_game(slug)`, or fix that file. Then `test_feature(..., game=slug)` again |
   | checks: no checks exist | use the Mubit-backed scenario planner: `.venv/bin/forge checks <slug> --plan --run --studio <bound-studio>`, then inspect coverage and results |
   | features: not verified | `test_feature("<that feature>", game=slug)` until PASS |
   | open | `improve_game(slug, studio=...)`. It follows the job and ends with the `done` bar |
   | critic < 8 | `iterate(slug, iterations=2, studio=...)`, or `feature(slug, request)` for what the critic says is missing |
3. After each lever, `done(slug)` again. Compare it with your baseline.
4. **Stop when:**
   - READY;
   - the `[ ]` lines of `done` (part + detail) are word-for-word the same **twice in a row** (a
     plateau): report what's stuck and the evidence;
   - you've done 6 rounds.

   "Don't stop to ask" means don't ask. It doesn't mean loop forever.
5. If a round made things worse (a check went PASS → FAIL): `diff_since_last_run` (mubit-tester),
   then `bisect_versions(slug, check)`, then `rollback(slug, version)`.

## Rules
- Pass `studio="<your local place>"` to `improve_game`, `iterate` and `feature`. Never use a
  `placeId` window.
- Run one job per Studio window at a time.
- Human-owned files get patches, not edits (`runs/<slug>/improve/patches/`): show them, don't
  claim they're applied.

## Report format
```
<slug>: READY after <n> rounds | NOT READY (plateau | budget): <parts missing + details>
Baseline → now: checks a/b → c/d, open x → y, critic s → t
Rounds: 1) <lever> → <effect> 2) ...
Evidence: job ids, test ids, versions kept
```

## Common mistakes
| Mistake | Fix |
|---|---|
| Re-running `improve_game` without inspecting missing checks | Use `test_feature(game=slug)` or the check workflow and inspect results; a fix cycle alone may leave coverage gaps |
| Claiming READY from a job log | Only `done(slug)` decides |
| No plateau rule | Stop after two identical `done` results and report |
| Building without `studio=` | It goes to the first connected window, maybe the shared place |
