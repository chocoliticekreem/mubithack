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
| fun | critic `fun` (or `scores.fun`) if the critic reports it. Today's critic folds fun into `score`, so this is `-` | higher |
| checks passed / total | `checks/results.json` (executable acceptance checks) when a check run happened | higher |
| acceptance criteria | number of spec `acceptance` items (context for checks) | - |
| done parts | `forge done` readiness: checks, features, open, critic (x/4, READY when all pass) | higher |
| corrections | human corrections in `state.json` (bench makes none, so a non-zero value means someone stepped in) | lower |

LLM latency varies a lot between runs (gateway load, retries), so compare wall times over at least 2
ideas, and treat differences under about 15% as noise.

## Results

See the bottom of this file (filled in from `evidence/bench/`).
