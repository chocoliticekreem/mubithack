---
name: forge-orchestrate
description: Use when the user wants Forge to make an existing game much better on its own (for example "make the tycoon 10x better"), to find what a game is missing or what is broken, to queue several Forge jobs that share Studio windows, or to correct the gap list Forge produced. Drives `forge orchestrate`, `forge gaps` and `forge queue` (or the forge MCP tools orchestrate, gaps and orchestrator).
---

# Forge as team lead: `forge orchestrate`

`forge orchestrate <slug> --goal "..."` is a long-running conductor. Each round:
1. The **gap finder** (Mubit task `gap_finder`) reads everything Forge recorded for the game: critic
   scores and issues, AI tester runs with their screenshots, executable checks, fix cycles, failed Mubit
   calls, `forge done`, and a static scan against a genre checklist (for tycoons: plot claiming, dropper
   tiers, conveyor and collector, upgrade tree, rebirth, shop UI, leaderboard, saving, tutorial, juice,
   fairness, no grey art, performance). It returns ranked gaps. Every gap cites evidence ids, has an
   impact score, and names one Forge job.
2. The top gaps become **jobs** in `runs/<slug>/orchestrator/queue.json`: a `fix` with a file runs
   `forge correct`, and a `feature` or `visual` runs `forge feature`. Then come verify (luau-compile),
   playtest (`forge run -n 1`: critic and screenshot), checks (`forge checks --plan --run`) and a fix
   cycle (`forge fix --cycles 1`).
3. **Workers** claim jobs by priority and dependencies. They lease what they need from a broker:
   Studio windows (machine-wide slots shared with `scripts/studio-slot.sh`, max 4), the Mubit pool,
   sync ports (34901+), and the game folder. Fixes to different files run in parallel, each holding
   its file's lock. Whole-game writers (feature, playtest, fix cycle) hold the whole game. A job whose
   lease is busy waits, and a higher-priority job waiting for a pool isn't starved by lower-priority
   ones. Checks run headless first (`checks.triage`); only the ones that still fail or need Studio
   take a Studio lease. Each Forge process runs `FORGE_JOBS` concurrent Mubit calls.
4. **Re-score** with `forge done` and the critic. The loop stops when done is green and the critic is
   at least 8, or when `--max-calls`, `--minutes` or `--rounds` runs out.

## Run it
```bash
.venv/bin/forge gaps <slug> --find --goal "..."      # one Mubit call: see the ranked gap list first
.venv/bin/forge orchestrate <slug> --goal "..." --studio Forge-agents-<N> --max-calls 300 --minutes 120
.venv/bin/forge queue <slug>                          # jobs, states, leases, budget
.venv/bin/forge dashboard                             # orchestrator lanes and each job's log, live
```
- Use your own place (`--studio Forge-agents-<N>`), never the shared "Firefighter Mubit" place. The
  orchestrator opens the window when a Studio job gets its lease, and closes it (freeing the slot)
  when no Studio work is queued. Without `--studio`, it runs compile-only.
- Budget it: `--max-calls` counts every Mubit call recorded under `runs/<slug>/` (all roles). When the
  budget is spent, queued jobs are cancelled and running ones get SIGTERM. Forge restores files on
  SIGTERM.
- It's safe to stop and resume. Run the same command again: jobs whose worker died are put back in
  the queue (up to 2 attempts), and stale leases are reclaimed.

## Correct the gap finder (this is how it learns)
```bash
.venv/bin/forge gaps <slug> --correct "saving can wait; the first 60 seconds are confusing" --reject <gap-id>
```
This is a new call in the same `gap_finder` Mubit task, with the previous list and your note in the
user message. Rejected ids are never proposed again. Corrections are logged in
`runs/<slug>/orchestrator/corrections.jsonl` and show up in `forge ledger`.

## Files (all under runs/<slug>/orchestrator/)
`queue.json` (jobs), `gaps/<n>.json` (each gap list), `rounds.json` (per round: gaps, jobs, score
before and after), `status.json` and `timings.json` (read by the dashboard), `corrections.jsonl`,
`rejected.json`, `calls.jsonl` and `traces/` (gap finder calls). Each job's log is at
`runs/jobs/orch-<job>-<attempt>.log`.

## Rules
- Don't edit `forge/prompts/gap_finder.md` once Mubit has collected calls for it: an edit resets the task.
- Report the before and after: `forge gaps <slug>` (latest list), `rounds.json` scores, and the
  critic screenshots in `runs/<slug>/iterations/<n>/screenshot.png`.
