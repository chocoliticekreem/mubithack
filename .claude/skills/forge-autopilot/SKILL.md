---
name: forge-autopilot
description: Use when the user wants Forge to take a game from an idea to ready on its own, to keep improving a game driven by its logs and playtest evidence, to find anomalies (error spikes, counters that never move, regressions, stuck testers, features nobody uses), to get a read-only improvement report on the human-built main game, or to correct an autopilot decision. Drives `forge autopilot` (or the forge MCP tool autopilot).
---

# Forge on autopilot: `forge autopilot`

One self-driving loop. Every round is evidence-driven and every decision cites evidence ids:

1. **Make** (idea only): `forge new` with the director, compile-only, versioned, then booted headless
   (a script that errors at boot gets a `forge correct`). An existing slug skips this.
2. **Observe**: measure the current version. That means a Studio playtest (ForgeProbe errors, warnings,
   counters, jitter/drift flags, census, screenshot), checks (headless first, the rest in Studio), a
   focused QA run, a short swarm (stuck testers, time to first reward, soak series), ForgeBridge events
   for our place, and critic + fun critic. Everything goes into one evidence store per round
   (`autopilot/rounds/<r>/evidence.json`), with history from earlier iterations and fix cycles.
3. **Detect**: a statistical pre-filter (z-scores against history, diffs against the previous version,
   declared counters that never move, instance leaks, over-budget counters, stuck testers, slow first
   reward) feeds the new Mubit task **anomaly_detector**. The existing **gap_finder** also runs (genre
   checklist and spec). Unknown evidence ids are dropped.
4. **Decide**: merge the anomalies and gaps (both detectors agreeing raises confidence), then score each
   one as impact x confidence (x0.5 with no evidence, x1.25 when corroborated). Pick up to `--per-round`
   jobs within the call budget. Every candidate gets a reason, picked or skipped.
5. **Act**: the jobs run through the orchestrator's queue, broker and workers (`forge correct`,
   `forge feature`), in parallel where the leases allow.
6. **Verify**: re-measure, then gate the result against the previous version. Any of these rolls the
   round back (`GameVersions.restore`): a compile error, more boot errors, a new runtime error, a check
   that passed now failing, a core counter dying, critic or fun down by 1 or more, or more physics flags.
   Otherwise the round is kept as a new version and an iteration record.
7. **Learn**: each outcome goes into `learn.jsonl`. The next detector and gap-finder calls carry the
   outcomes (same Mubit tasks, logged as corrections). `rounds.json` and `journal.md` record what
   improved and why.

It stops when `forge done` is green and critic and fun reach `--target`, when the budget runs out, when
`--rounds` is used up, or when nothing is above the bar.

## Run it
```bash
.venv/bin/forge autopilot "coin obby with a speed boost" --studio Forge-agents-<N> --max-calls 250 --minutes 120
.venv/bin/forge autopilot <slug> --studio Forge-agents-<N>           # keep improving an existing game
.venv/bin/forge autopilot <slug> --status                            # phase, budget, round table
.venv/bin/forge dashboard                                            # the Autopilot lane, live
```
- Use your own place (`--studio Forge-agents-<N>`, after `scripts/studio-slot.sh acquire Forge-agents-<N>`).
  Never use "Firefighter Mubit". The window opens on the first Studio need and closes at the end.
  Release the slot when you're done.
- The budget covers every Mubit call under `runs/<slug>/` (build, jobs, QA, swarm, detectors) and every
  minute, across sessions. `--swarm-players 0` and `--qa-steps 0` make a round cheaper.
- It's crash-safe: run the same command again. Finished phases are skipped, and queued jobs are
  recovered, not re-run.
- For live ForgeBridge events, a `forge plugin serve` bridge must be running and `FORGE_BRIDGE_TOKEN` (or
  `runs/studio-bridge/token`) must match it.

## Read-only advice on the human-built game
```bash
scripts/studio-slot.sh acquire Forge-agents-<N>
FORGE_BRIDGE=0 .venv/bin/forge autopilot --advise --root game --fresh --studio Forge-agents-<N> \
    --qa-steps 0 --swarm-players 1 --goal "..."          # about 10 Mubit calls
scripts/studio-slot.sh release Forge-agents-<N>
```
This reads `evidence/<name>*`, `runs/<name>*`, `games/<name>/reports/*.md` and the source. It makes one
anomaly_detector call and one gap_finder call, writes `runs/autopilot-advise/<name>/<stamp>/report.md`, and
never edits a game file.

The evidence is version-aware: each item is tagged with the game commit it was recorded on, and older
items are marked old and weighted down.

`--fresh` first re-checks on the current build. It runs a probe with a round started, a short QA run
focused on the old claims, and a short swarm. Each ranked item comes out as one of:
- **verified now**: live or current-build evidence backs it;
- **missing / never exercised**: only the code scan or counters that never moved back it;
- **unverified (old)**: only older builds back it (scored at x0.3).

Tester-harness failures (prompts the harness couldn't press, NoPath) go to a **tester-harness fix list**,
not the game's bug list. Without `--fresh`, runtime claims from older builds stay unverified.

## Correct a decision (this is how it learns)
```bash
.venv/bin/forge autopilot <slug> --correct an-coins-never-collected "coins work; the HUD updates late"
```
The note becomes a correction call in the Mubit task that produced the finding (anomaly_detector, or
gap_finder via `forge gaps --correct`). The id goes into `autopilot/rejected.json` and is never proposed
again. `forge ledger` counts it.

## Files (runs/<slug>/autopilot/)
- `state.json`: round, phase, budget across sessions, current/previous measurement.
- `status.json`: what the dashboard reads.
- `rounds/<r>/`:
  - `observe`, `detect`, `decide`, `act`, `verify`, `learn` (`.json`)
  - `evidence.json`, `prefilter.json`, `measure-baseline|after.json`
  - `<tag>/screenshot.png`
- `rounds.json`, `journal.md`, `learn.jsonl`, `corrections.jsonl`, `rejected.json`, `queue.json`, `calls.jsonl`.

## Rules
- Don't edit `forge/prompts/anomaly_detector.md` or `gap_finder.md` once Mubit has calls for them.
- Report the round table (`forge autopilot <slug> --status`), the screenshots, and the kept or rolled-back
  versions (`forge versions <slug>`).
