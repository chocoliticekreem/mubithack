# MuMake: reflection and next fixes after the demo night

Oct 25, 2026 · Anson. Live doc: https://claude.ai/artifact/6F4UziXrk2CPy3AARtthat

## Summary

MuMake turns one prompt into a playable 100-stage park obby in Studio in about 6 minutes, then improves it in rounds. But the critic score plateaus at 6/10, because our playtests cannot exercise half of the game's own features.

What works end to end today:

- **Build:** the stage count in the prompt is honoured (100 stages becomes 10 zones of 10), and the zones are designed in parallel: about 3.5 minutes for all 10, with 0 jump errors.
- **Install:** the game goes into the open Studio window by itself, in several small commands under Studio's 200k-character limit, with no HTTP.
- **Rounds:** each round runs a headless playtest, the critic and the fixer, then reinstalls in Studio, relaunches, runs 6 QA bots in parallel and a scripted journey (ride gate, next zone, finish line).
- **Screens:** the same live % in the MuMake panel and on the dashboard, agent levels with green arrows only on real gains, a "What Mubit learned" footer, and a pop-up when the game is ready.

The gap: the score goes up only when the game's features show up in a playtest, and our playtests miss costumes, gifts and achievements.

## What the final demo run showed

The final run ("i want a 100 stage obby", runs/i-want-a-100-stage-obby) held 6/10 with 0 errors for 4 rounds. The missing checks fell from 9 to 5 after round 1, then stopped moving.

| Round | Score | Game errors | Acceptance checks still at 0 |
| --- | --- | --- | --- |
| 1 | 6/10 | 0 | 9: costume_buy, costume_equip, trampoline_bounce, zone_cleared, obby_finished, park_finished, gift_ready, gift_claimed, achievement_unlocked |
| 2 | 6/10 | 0 | 5: costume_buy, costume_equip, gift_ready, gift_claimed, achievement_unlocked |
| 3 | 6/10 | 0 | the same 5 |
| 4 | 6/10 | 0 | the same 5 |

- The Studio journey worked every round: ride gate after stage 10, the next zone's entrance and the finish line at stage 100 all fired their counters in Studio.
- The 5 checks left need a player to buy a costume through the shop UI, wait for the gift balloon, or earn an achievement. No test player does any of these.
- We stopped the run by hand during round 5 so the demo could end on a playable game. Its "Ready for review" status on the dashboard was written by hand at that point, not by the system.

Earlier runs the same night, before the Studio journey existed, sat at 5/10 for 4, 6 and 12 rounds.

## Why the score plateaus at 5-6

The critic's rubric caps a game at 5-6 while any acceptance check reads 0 (forge/prompts/critic.md: "5-6: … missing acceptance criteria"; "Do not give 7+ while there are runtime errors"). So the score measures what our playtests can trigger, not how good the game is.

1. **The headless engine fires no touch events.** Kill parts, ride gates and the finish line are touch pads, so the headless smoke test reported "touched lava: did NOT die" every round. In Studio, the same kill part killed the player in 0.2 s. The critic punished a test limitation as a game bug.
2. **The director promises checks that no tester can reach.** costume_buy needs a click in the shop UI, gift_claimed needs about 45 s of waiting, and achievement_unlocked needs whole sessions. They stay 0 whatever the code does.
3. **Rounds did not learn from each other** (fixed tonight). The fixer rewrote the same 3 files 21 times in one 7-round run and was never told a fix had changed nothing. The critic re-raised the same issue every round.
4. **Our own test harness counted as a game error** (fixed tonight). ForgeTest.server.luau:2151 read workspace.FallenPartsDestroyHeight, which is nil in the headless engine. That error alone blocks 7+ under the rubric.
5. **A check could be impossible.** zone_cleared was promised, but only the read-only kit could count it; the kit now counts it at a ride gate.

What the evidence rules out: the games are not broken. All 100 stages build, there are 0 game errors, and checkpoints, coins, jump pads and trampolines fire, as do the ride gates and the finish in Studio.

## What changed tonight

Nine PRs merged to main, all with CI green. Newest first:

| PR | What it does | Problem it fixed |
| --- | --- | --- |
| #227 | MuMake name on every screen | Forge and MuHack names left in empty states and the Studio runs panel |
| #226 | Studio plugins in the dashboard's cream look; MuMake shows the same % | The plugin looked different and showed its own % |
| #225 | Agents level up (Lv, XP, a green arrow only on a real gain) and a "What Mubit learned" footer | Mubit's role was invisible on the dashboard |
| #224 | Ready at 7/10 or "Ready for review" at 20 min; one % everywhere; Studio journey counters reach the critic; a headless kill-part check reports unknown | Abrupt 20-minute ending; plugin and dashboard % differed; touch features never counted |
| #220 | "Go test it" pop-up | Nothing told the user when the game was playable |
| #219 | Dead ends carried to the next build and reflected on by the reflector; the obby recipe from GAME_PRODUCTION_GUIDE.md; required gameplay fixed first; QA bots get 2 tries | Rounds spent fixes on effects and sound while lava did not kill |
| #199 | Auto-install in Studio, rounds until ready, QA bots in parallel, before/after shots, history for the critic, corrections for the fixer | The game never reached Studio; the score stayed flat; screenshots were useless |
| #198 | Riso/village dashboard merged with live progress | Two dashboards with different looks |
| #193 | Live % and events; zones in parallel; stage count from the prompt | A static screen; "100 stages" built 60; 25 min to build |

## Next fixes, in order

Fix 1 alone should move the score past 6; fixes 2 and 3 keep it honest for any game, not just this obby.

1. **Exercise the last 5 checks in Studio.** Add to the Studio QA journey (QA_JOURNEY in mubit-tester/mubit_tester/studio_service.py): open the costume shop, buy and wear one item through the real UI press (ForgeTest `ui` + `press`), wait for the gift balloon and claim it. Done when a 100-stage build reaches 13/13 acceptance in Studio, and its round reaches 7/10 with 0 errors.
2. **Let the director promise only checks something can test.** Extend kit_counters / _kit_beats in forge/director.py so each acceptance counter names how it is exercised (headless smoke, Studio journey or QA bot). Drop or rephrase the rest. Done when no acceptance item in a new spec lacks a test path.
3. **Judge readiness on a profile, not one critic number** (GAME_PRODUCTION_GUIDE.md section 11): acceptance %, QA bot pass rate, game errors and the critic score. Done when Ready uses all four and the dashboard shows them.
4. **Play the round in Studio when a window is free**, instead of headless (run_game use_studio=True on the bound window). Touch features then count in the round itself, not one round late. Done when a round's report needs no Studio QA counters merged in.
5. **Faster rounds.** A round takes about 3 min: the headless playtest, the critic, the fun critic and the fixer, then about 40 s of launch and QA. Run the fun critic and the reflector off the critical path. Done when a round is under 2 min.
6. **The test_worldkit CI flake.** test_long_courses_carry_the_park_to_their_ends times out on CI runners and passes locally (6/6). Raise its timeout or shorten the course. Done when 10 CI reruns pass.

## Mubit learning: what is real and what the screens present

Every agent call goes through Mubit, and corrections do go back into each task. But no game has yet been built by a model that Mubit retrained from those corrections.

| Claim | Real today? | Evidence |
| --- | --- | --- |
| Every agent is a Mubit task | Yes | Each call logs a Mubit request id (runs/<slug>/calls.jsonl); the final run made hundreds of calls |
| A failed fix becomes a correction for the fixer | Yes | Its next call carries "## Your previous fix was rejected", which forge ledger counts as a correction |
| Lessons carry to the next round and build | Yes | The reflector rewrites runs/lessons.md each round; dead ends go to runs/dead_ends.json, which the next build's director and designer read |
| Agents level up (Lv, XP, green arrows) | Derived | Computed from recorded round outcomes. A level is a tally of corrections and wins, not a better model |
| Corrections become a better model | Not shown yet | As of the night of Oct 23-24, two adapters were trained on Qwen3-4B: playtester 60% on 15 tests, investigator 75% on 12 (target 85%). None is called by MuMake |

To make the claim fully real:

- Route a task to its trained adapter once it passes, and show its held-out score before and after (GAME_PRODUCTION_GUIDE.md section 12).
- Count corrections per task against the 25 Mubit needs to train, and run the next training as soon as a task crosses it.

## Debt, risks and open questions

The demo setup works but is fragile. These are worth knowing before anyone runs it again.

- **The demo services run from a worktree, not from main:** a separate checkout runs the MuMake companion, the dashboard on :8770 and the Studio bridge, with its own runs/ folder. An old dashboard on :8765 reads the main checkout and never sees MuMake builds.
- **Studio QA counters arrive one round late.** The journey runs at launch, after a round, and the next round's critic reads them (counters_from_studio_qa). Fix 4 above removes the lag.
- **Large files and HTTP.** Files are sent inline, under 180k characters per command. A single script larger than that falls back to HTTP, which Studio may refuse in a fresh place (lacking capability LocalUser).
- **PR #162** (autopilot learns only from clean labels) is still open, waiting on Arvin's review.

Open questions:

- [ ] Should the acceptance list for template obbies be fixed by the kit, not written by the director?
- [ ] Is a 7/10 critic score the right bar, or the profile in fix 3?
- [ ] Can MuMake call a Mubit-trained adapter today, and how do we show its before/after score on the dashboard?
