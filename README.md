# Forge

Give it a game idea. It builds a Roblox game, playtests it in Roblox Studio, reads what broke, fixes
it, and gets better at it every run.

Every LLM call goes through [Mubit](https://mubit.ai). Each of Forge's roles has one fixed system
prompt, so Mubit sees each role as a recurring **task** and trains an adapter for it. Corrections,
whether from Studio errors, the critic, the auditor or you, are sent back as new calls in the same
task. That is how a correction turns into a model update.

```
idea → designer → spec → coder → Luau files → compile check → fixer
     → sync into Studio (MCP) → playtest → ForgeProbe report + console + screenshot
     → critic → fixer → reflector (lessons) → next iteration

game → plant faults → AI playtest rounds → auditor (anomalies) → corrections for what it missed
     → fix → verify (verifier) → scores + playbook → next cycle          (docs/MUBIT_LOOP.md)
```

## Setup

```bash
uv venv && uv pip install -e ".[dev]"
cp .env.example .env        # put your mbt_ key in MUBIT_API_KEY
brew install luau           # luau-compile for syntax checks
.venv/bin/forge doctor      # every line should be ✓
```

- **Model:** the default is `claude-sonnet-5-5`. Mubit's starter credit only serves
  `claude-opus-5-5`, `claude-sonnet-5-5` and `claude-haiku-4-5`; anything else fails with
  `400 starter_credit_model`. Keep the same model across the team: the model is part of a Mubit
  task's identity, so different models split the training examples.
- **Studio:** open a place, then **Assistant → ⋯ → Manage MCP Servers → Enable Studio as MCP
  server**. The toggle is per window and resets when the window closes. Forge starts Studio's
  built-in `StudioMCP` itself. The first `list_roblox_studios` after a restart is often empty;
  retry.
- **Two Studio windows:** give Forge its own place so it never touches yours:
  `python3 game/tools/make_place.py --root place/empty --out place/Forge-ai.rbxlx`, open it, enable
  MCP, and run Forge with `FORGE_STUDIO=Forge-ai FORGE_SYNC_PORT=34874`. `--studio`/`FORGE_STUDIO`
  takes a name part or an exact studio id (`forge doctor` lists them).
- **Mubit console:** an admin must switch training on (Settings). Tasks first train at 25 kept
  examples.

## Quick start: the Forge plugin for Claude Code

In Claude Code:

```
/plugin marketplace add chocoliticekreem/mubithack
/plugin install forge@mubithack
```

Then say "set up Forge". Claude calls the `setup` tool, which walks you through everything:
1. Your Mubit key: it checks the key against Mubit and saves it.
2. The model.
3. Installing `luau-compile`.
4. Roblox Studio.
5. Opening a Forge place and the per-window MCP toggle.

When it says ready, ask for a game ("make a co-op lava escape and keep improving it"). The plugin's
launcher finds a mubithack checkout (the plugin's *mubithack checkout* option, the current project,
or the marketplace's own copy) and creates its venv with `uv` on first launch. Add
`mubit-tester@mubithack` too, to play and inspect the game in Studio. Inside this repo both plugins
are enabled by `.claude/settings.json`.

## Use from Claude Code (MCP)

| Server | What it does |
|---|---|
| `forge` (plugin, `forge server`) | Builds and improves games. Setup: `setup`. Build: `doctor`, `new_game`, `iterate`, `correct`, `improve`, `fix`, `tester_report`, `tester_reports`. Jobs: `job`, `jobs`, `cancel_job`. Read: `games`, `game`, `read_file`, `scores`, `playbook`, `lessons`, `calls`. Ship: `seed`, `promote`, `sync`. |
| `mubit-tester` (plugin) | Plays and inspects the game in Studio: every player, scenarios, AI playtests, `playtest_correct` (`docs/TESTER.md`). |
| `Roblox_Studio` | Studio's own MCP: `execute_luau`, play/stop, console, screenshots. |

Building takes minutes, so `new_game`, `iterate`, `correct` and `improve` start a background job
(log in `runs/jobs/`) and return its id at once; poll `job(id)`. A typical session:

1. `doctor`
2. `new_game("lava obby with checkpoints", iterations=2)` → `job(id)` until finished
3. `game(slug)`, `read_file(slug, path)` to look at what it made
4. `correct(slug, "ServerScriptService/Round.server.luau", "rounds never end")`: a human correction,
   recorded in the fixer's Mubit task (the job log ends with the request id to rate Good)
5. `improve(slug)` → `scores(slug)`, `playbook(slug)`

## Use from the shell

```bash
forge new "co-op lava floor escape where you carry friends" --iterations 3
forge run lava-escape --iterations 2         # keep improving
forge correct lava-escape ServerScriptService/Round.server.luau "rounds never end when everyone dies"
forge status
forge new "..." --no-studio                  # compile-only loop, no Studio needed
forge place --open                           # build place/Forge.rbxlx and open it in Studio
forge watch --studio Forge.rbxlx             # auto-sync game/ into Studio on every save
forge play "<goal>"                          # AI playtest (mubit-tester); play-correct, play-list
forge server                                 # the forge MCP server over stdio
```

## The self-improving loop

`forge improve <slug>` (MCP: `improve`) runs one or more cycles of `docs/MUBIT_LOOP.md`:

1. **Plant faults:** known-bad config values from `forge/faults/<slug>.json`, set live through the
   ForgeTest harness (for example the hose tank emptying in one spray, or fire that never spreads).
2. **Playtest:** N rounds of mubit-tester's AI players.
3. **Auditor** (Mubit task): reads a compact digest of each round (counters, events, errors, the
   judge's bugs; never the code) and reports anomalies across rounds: economy, balance, broken links
   between systems, conflicts.
4. **Score** the anomalies against the planted faults.
5. **Correct:** for each fault it missed, the auditor call is sent again with the verified symptom.
   That reply lands in the same Mubit task as a training example.
6. **Fix and verify:** detected faults are restored, one more round is played, and the **verifier**
   (Mubit task) decides `fixed`, `not_fixed`, `regression` or `inconclusive` from before/after
   evidence.
7. **Learn fast:** lessons from missed faults go into `runs/<slug>/improve/playbook.md`, which the
   next audit reads. Mubit's adapters are the slow learning across runs.

```bash
forge improve flame-and-blame --cycles 3 --rounds 3 --steps 15 --studio Forge-ai
forge improve flame-and-blame --only hose-drains-instantly   # one fault
forge scores flame-and-blame                                  # detected / missed / fixed per cycle
```

**Fixing the game itself:** `forge fix <slug>` (MCP: `fix`) runs the loop on the real game with no
planted faults. It plays a few rounds and collects the auditor's anomalies, plus anomalies from new
tester reports with `--reports`. For each high or medium one, it finds the most likely file, and the
**fixer** rewrites it (a call in the fixer's Mubit task). The file is compile-checked, Studio is
resynced, a round is replayed, and the **verifier** decides. `fixed` keeps the change; anything else
rolls it back and resyncs. It repeats until no high or medium anomaly is left (the quality bar) or
`--cycles` run out. Human-owned files (a seeded game's `base_files`) are never edited: the fixer's
patch is saved to `runs/<slug>/improve/patches/` for a person to review. `forge improve --fix` does
the same after a planted-fault cycle, on a clean baseline round.

```bash
forge fix my-game --cycles 5 --reports --studio Forge-ai
forge scores my-game        # adds open anomalies and code fixes kept/tried per cycle
```

**Real testers:** `forge report <slug> "<what they saw>" [--run <playtest run id>] [--by name]`
(MCP: `tester_report`). The **triage** role (Mubit task) turns the report into anomalies backed by
the round telemetry. For each one the auditor had not flagged, the auditor call is re-sent with
it as a verified outcome (a correction in the auditor's task) and a lesson goes into the playbook,
so real players teach the auditor. `forge reports <slug>` lists them.

Faults only work when the game's services read those config keys at use time, and when the
ForgeTest harness (`game/ServerScriptService/ForgeTest.server.luau`) is in the place.

**Rule:** never edit `forge/prompts/*.md` or `mubit-tester/prompts/*.md` once calls have been made.
Mubit groups calls into tasks by the exact system prompt; an edit starts a new task at zero examples.

## Mubit console

[app.mubit.ai/console](https://app.mubit.ai/console/): **Tasks** shows each role collecting examples
and training. **Requests** lets you rate calls Good/Bad (`calls(slug)` lists request ids). **Try
models** compares an adapter with the base model side by side.

## Layout

- `forge/`: the agent (Python). Contracts are in `docs/ARCHITECTURE.md`.
  - `prompts/`: one fixed system prompt per role (designer, coder, fixer, critic, reflector,
    auditor, verifier, triage).
  - `improve.py`, `faults/`: the self-improving loop. `mcp_server.py`: the `forge` MCP server.
- `mubit-tester/`: the game tester (MCP server, ForgeTest harness, AI players, judge, explorer).
- `game/`: the human-built Flame and Blame game plus the Forge runtime (ForgeProbe,
  ForgeTelemetry, sync tools). `forge new` copies only the runtime; `forge seed` copies everything.
- `runs/<game>/`: generated games, specs, iterations, improve cycles and call logs (gitignored).
  `runs/jobs/`: MCP background job logs.
- `docs/MUBIT_LOOP.md`: the self-improving loop design. `docs/research/`: Mubit and Studio MCP facts.
- `docs/TEAM.md`: how the team works in parallel (lanes, branches, PRs). Note: the repo's Stop hook
  (`scripts/git-sync.sh`) pushes local commits on your current branch after every Claude turn, so
  keep work on branches.
