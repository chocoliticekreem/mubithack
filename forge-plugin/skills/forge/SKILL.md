---
name: forge
description: Use when driving the forge MCP tools (build_game, improve_game, done, correct, tester_report, versions, rollback, jobs) on Forge-made Roblox games, or checking how Forge's self-improving loop (auditor, fixer, verifier, Mubit training) is doing.
---

# Making and improving Roblox games with Forge

Read the [shared game production guide](../../../docs/GAME_PRODUCTION_GUIDE.md) in the resolved mubithack checkout before planning work. It defines Mubit-only AI routing, game-family/capability requirements, priority bands and evidence standards for both native and chat workflows. Pass relevant rules in task user context; keep frozen role prompts unchanged.

Forge turns an idea into a Roblox game, playtests it in Roblox Studio, and keeps improving it.
Every LLM call goes through Mubit, and each role (designer, coder, fixer, critic, reflector, auditor,
verifier, triage) is one Mubit task, so every correction becomes training data. Tools are
`mcp__plugin_forge_forge__*`.

## Before you start
1. `doctor`. Every line should be ✓. If not:
   - **Mubit key missing or `invalid_key`:** set the plugin's Mubit API key option, or
     `MUBIT_API_KEY` in the checkout's `.env`.
   - **`starter_credit_model`:** the model must be `claude-sonnet-5-5`, `claude-opus-5-5` or
     `claude-haiku-4-5`.
   - **No Studio connected:** the user opens a place in Roblox Studio and turns on Assistant → ⋯ →
     Manage MCP Servers → Enable Studio as MCP server. The toggle is per window. The first check
     after a restart is often empty, so run `doctor` again.
2. Pick the Studio window. Pass `studio` (a name part, or the exact id `doctor` lists) to the build
   tools. Use a local place for Forge, never a shared Team Create place someone is working in.

## Make a game
Full workflow: the **building-games-with-forge** skill.
1. `build_game(idea, iterations=2, studio=...)` starts the job and follows it for a few minutes,
   streaming progress. It returns a summary first and the job id.
2. `job(id, wait_seconds=300)` until it says `finished` (or `failed`: read the log tail).
3. `games()`, then `game(slug)` for the spec, modules, critic scores and files. `read_file(slug,
   path)` to read code.
4. `iterate(slug, iterations=1)` for more playtest, critic and fix rounds.

No Studio? Pass `use_studio=False`: compile-only, which still builds and fixes.

## Fix and improve it (the self-improving loop)
Until-ready workflow: the **improving-games-until-done** skill. `done(slug)` is the finish line.
- `improve_game(slug, cycles=3)` (was `fix`):
  1. plays rounds and the auditor finds anomalies (plus new tester reports);
  2. for each high or medium anomaly the fixer rewrites the likely file;
  3. Studio is resynced and a round replayed;
  4. the verifier keeps the fix or rolls it back.

  It stops when nothing high or medium is left. Human-owned files only get a patch under
  `runs/<slug>/improve/patches/`; show it to the user.
- `correct(slug, path, note)`: the user says what is wrong in one file. The fixer applies it and the
  call is recorded in the fixer's Mubit task. The job log ends with the request id; tell the user to
  rate it Good in the Mubit console (Requests).
- `tester_report(slug, text, run_ids=[...])`: a human tester's words become anomalies (triage), and
  anything the auditor missed becomes an auditor correction. `improve_game(..., reports=True)` then fixes them.
- `fault_drill(slug)` (was `improve`): the planted-fault benchmark (only for games with a `forge/faults/<slug>.json`).
  `scores(slug)` shows detected, missed, open, and code fixes kept per cycle.

## Report back
- Say what was built or fixed, which files changed, and the job's final lines. Don't claim a fix
  worked unless the verifier said `fixed` (`scores` or the job log).
- `calls(slug)` lists Mubit request ids. https://app.mubit.ai/console/ shows each role's task
  collecting examples (it trains at 25) and lets the user rate calls.

## Rules
- Never edit `forge/prompts/*.md`: Mubit groups calls into tasks by the exact system prompt.
- One job at a time per Studio window: two jobs playing in the same window collide.
  `cancel_job(id)` stops one; then stop play in Studio.
- Playing and inspecting the running game (players, scenarios, screenshots) is the `mubit-tester`
  plugin's job.
