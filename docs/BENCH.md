# forge bench

`forge bench` measures whether Forge got faster and smarter. It builds the same fixed set of small
games every time and records the same numbers, so two runs on two commits can be compared.

## The suite

| id | idea (exact text in `forge/bench.py` `SUITE`) |
|---|---|
| `tycoon` | dropper -> conveyor -> collector pays cash; buy a second dropper and a faster conveyor |
| `obby` | 8 platforms, gaps, 2 lava strips, a moving platform, checkpoints, a finish pad with your time |
| `minigame` | lobby + intermission countdown, 60 s round, tiles fall after being stepped on, last standing scores |
| `simulator` | click for strength, sell on a pad for coins, buy weights that multiply strength per click |
| `defence` | co-op tower defence: enemy waves on a path, coins from kills, turrets, base health |

Never edit these ideas. Changing one makes older results incomparable, so add a new id instead.

## Running it

```bash
.venv/bin/forge bench --fake                          # cheap: FakeLLM, no Studio, about 2 s (CI runs this)
.venv/bin/forge bench --ideas tycoon,obby -n 2        # real: every call goes through Mubit, compile-only
.venv/bin/forge bench --studio Forge-agents-29 -n 2   # real, plus a Studio playtest in that window
.venv/bin/forge bench --studio Forge-agents-29 --improve 1   # plus fix cycles (AI testers -> auditor -> fixer)
.venv/bin/forge bench --studio Forge-agents-29 --checks 8    # plus the scenario designer: plan 8 executable checks, run them live
.venv/bin/forge bench --compare A B                   # B - A per idea and in total (A, B = path, stamp, latest, prev)
.venv/bin/forge bench --list                          # the suite and the saved results
```

Options: `--iterations/-n` sets the build iterations per idea (default 2). `--lessons starter|current`
sets the starting lessons: `starter` is the default and gives comparable runs, while `current` copies
`runs/lessons.md`. `--label` saves a note with the result, and `--out` changes the results folder.

For the Studio mode, take a slot first (`sh scripts/studio-slot.sh acquire Forge-agents-N`) and
release it afterwards. Never point bench at the user's main place.

## What a run does

Each idea runs `forge.loop.new_game(idea, iterations, use_studio)`. That is the same code path as
`forge new`: designer, coders, then per iteration a compile check with the fixer, an optional Studio
playtest, the critic, the critic-issue fixer and the reflector. If `--improve K` is given with Studio,
it then runs up to K `improve.run_cycle(fix=True)` cycles, followed by `forge done` readiness.

Bench doesn't change how games are built. While the run is going it wraps `loop.Run.build_all`,
`iterate`, `compile_fix` and `playtest` to time them, and reads every other number from the run's own
records. Each idea gets its own runs dir, `runs/bench/<stamp>/<idea>/`, with fresh lessons. This
keeps ideas from affecting each other and keeps bench games apart from real ones.

Results are written to `runs/bench/<stamp>.json` (full record) and `runs/bench/<stamp>.md` (table).
Baselines we want to keep go in `evidence/bench/`.

## Metrics

| metric | source | better |
|---|---|---|
| wall s; design / build / iterate / compile_fix / playtest / improve s | wall clock around each stage (design = start until the build begins). The first-try compile check is left out of the totals | lower |
| LLM calls, tokens in/out, Mubit request ids, calls by role | every `calls.jsonl` under the game (build + improve) | lower |
| 1st-try compile | right after the coders finish, `luau-compile` on every spec module. A missing module counts as a failure | higher |
| fixes (compile / critic) | `iterations/<n>/record.json` `fixes` | lower |
| compile errors left | last iteration, after its fixes | lower |
| critic first -> final | `record.json` score per iteration (0-10) | higher |
| fun | the fun critic (#113, `forge/fun.py`): iteration record `fun.score` (mean of fun, juice, clarity, visuals), or `fun/latest.json`. Runs before #113 show `-` | higher |
| checks passed / total | `checks/results.json` (executable acceptance checks) when a check run happened | higher |
| acceptance criteria | number of spec `acceptance` items (context for checks) | - |
| done parts / share | `forge done` readiness parts passed (x/N, READY when all pass). #113 raised the bar from 4 parts to 9, so compare the share across that change, not the count | higher |
| checks s | `--checks`: scenarist plan + resync + live run + check review | lower |
| corrections | human corrections in `state.json` (bench makes none, so a non-zero value means someone stepped in) | lower |

LLM latency varies a lot between runs (gateway load, retries), so compare wall times over at least 2
ideas, and treat differences under about 15% as noise.

Two derived speed numbers appear in `--compare`. `LLM s (sum of calls)` adds up the latency of every
call. `LLM overlap (sum/wall)` divides that by wall time, so it is about 1.0 when every call runs one
after another and above 1 when calls run concurrently.

## Results

### Baseline: main `910ba38`, real mode, compile-only, 2 iterations (`evidence/bench/20261024T023030Z.*`)

| idea | wall s | design | build | iterate | LLM calls (coder/critic/designer/fixer/reflector) | tokens in/out | LLM s sum | 1st-try compile | fixes c/k | critic | done |
|---|---:|---:|---:|---:|---|---|---:|---:|---|---|---|
| tycoon (Cube Cash Tycoon) | 302 | 16 | 96 | 189 | 15 (4/2/1/6/2) | 89,811 / 50,423 | 300 | 100% (4/4) | 0/6 | 5 -> 5 | 1/4 |
| obby (Lava Hop Dash) | 305 | 13 | 91 | 201 | 15 (4/2/1/6/2) | 88,499 / 50,923 | 305 | 100% (4/4) | 0/6 | 5 -> 5 | 1/4 |

What this shows about where we started:
- **Everything runs one call at a time.** The sum of LLM latencies equals wall time (overlap 0.99),
  and the coders took 91 to 96 s for 4 modules one after another. The fastest speed-up available is
  running independent calls concurrently.
- **About 2/3 of the time goes to iterations** (critic -> 3 fixer calls -> reflector, twice). With no
  playtest those iterations can't move the score: the critic stays at 5/10 and says the playtest
  didn't run. Compile-only mode measures speed and code health. Quality needs `--studio`.
- **Compile health is already good:** every module compiled on the first try, so the compile fixer
  never ran.
- **Not ready:** `forge done` is 1/4 (no checks, no fix cycle, critic below 8). The bench build path
  doesn't plan or run executable checks or fix cycles yet.

### Baseline with Studio: main `a1b0fef`, tycoon, 1 iteration, `--checks 8` (`evidence/bench/20261024T025420Z.*`)

| idea | wall s | design | build | iterate | playtest | checks s | LLM calls | tokens in/out | 1st-try compile | fixes | critic | checks | done |
|---|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---|---|---|
| tycoon (Cube Cash Tycoon) | 411 | 17 | 105 | 121 | 17 | 169 | 13 | 88,882 / 51,249 | 100% | 3 | 7 | 8/8 | 2/4 |

- With a real playtest the critic gives 7/10 (compile-only gives 5): 0 errors, and the counters show
  the map built and cubes spawned and got collected. Screenshot: `evidence/bench/20261024T025420Z-tycoon.png`.
- The scenario designer planned 8 checks and 5 passed on the first run. The reviewer judged the other 3
  to be check bugs (cube payouts landing during the check), rewrote them, and all 3 passed on the re-run.
- Checks are the slowest stage (169 s), mostly play sessions starting and stopping.
- (This run tested checks against the pre-fix code. Bench now resyncs before running checks.)
