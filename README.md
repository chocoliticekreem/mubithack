# Forge

Give it a game idea. Forge builds a Roblox game, playtests it in Roblox Studio, finds what is broken
or badly balanced, fixes it, checks the fix worked, and gets better at all of it every run.

Every LLM call goes through [Mubit](https://mubit.ai). Each of Forge's roles has one fixed system
prompt, so Mubit sees each role as a recurring **task** and trains a model for it. Every correction,
whether from Studio errors, the critic, the auditor, the verifier, a tester or you, is sent back as a
new call in the same task. That is how a correction turns into a model update.

## Quick start (Claude Code plugin)

```
/plugin marketplace add chocoliticekreem/mubithack
/plugin install forge@mubithack
```

Start a new Claude Code session and say **"set up Forge"**. Claude calls the `setup` tool, which
checks each requirement and fixes it or tells you the next step:

1. **Mubit key:** paste it; `setup` checks it against Mubit and saves it.
2. **Model:** it must be one Mubit's starter credit serves.
3. **`luau-compile`:** installed for you with Homebrew.
4. **Roblox Studio:** installed and signed in.
5. **Studio connected:** it opens a Forge place and shows you the MCP toggle (Assistant → ⋯ →
   Manage MCP Servers → Enable Studio as MCP server).

When it says **ready**, ask for a game: *"make a co-op lava escape and keep improving it until it's
solid"*. Add `/plugin install mubit-tester@mubithack` too, to play and inspect the game in Studio.

On first launch the plugin finds a mubithack checkout (its *mubithack checkout* option, the current
project, or the marketplace's own copy) and creates the Python environment with `uv`.

## How it works

```
BUILD    idea → designer → spec → coder → Luau → compile check → fixer
              → sync into Studio → playtest → critic → fixer → reflector (lessons) → next iteration

IMPROVE  game → AI playtest rounds → auditor (anomalies across rounds) + tester reports (triage)
              → fixer rewrites the file behind each anomaly → resync → replay
              → verifier: fixed → keep, otherwise → roll back
              → repeat until nothing high or medium is left

LEARN    every call above is an example in its role's Mubit task; corrections (missed anomalies,
         human fixes, rejected fixes) are re-sent in the same task, so the models improve too
```

| Role (Mubit task) | Job |
|---|---|
| designer, coder | Idea to spec, spec to Luau, one module per call |
| fixer | Repairs a file: compile errors, critic issues, anomalies, human corrections |
| critic, reflector | Scores each playtest; keeps the cross-game lessons |
| auditor | Finds anomalies across rounds: economy, balance, broken links between systems, conflicts |
| verifier | Before/after evidence: `fixed`, `not_fixed`, `regression` or `inconclusive` |
| triage | Turns a human tester's words into anomalies backed by telemetry |
| player, judge, explorer | mubit-tester's AI playtesters and their judge |

### UI kit

Agent-built UI follows a house style: chunky stroked text, one palette, glossy gradient buttons with
press squish, Back-eased pops, ticking currency counters, toasts and reward popups. The rules and 10
paste-in Luau snippets live in `forge/ui_library/` (sources in its README). For UI work (client HUD,
shop, popup, BillboardGui) `forge/ui_kit.py` adds a `## UI kit` block with the rules and the 2 to 4
matching snippets to the coder, fixer or patcher **user message**, under a size budget. Server data
modules get nothing. Add a snippet: drop the `.luau` in, add it to `index.json`, run
`.venv/bin/python -m pytest -q tests/test_ui_kit.py`.

### Kit modules and obbies

Prebuilt, tested Luau modules a game gets by genre or keyword: `forge/kit/modules/<Name>.luau` plus one
entry in `forge/kit/modules/index.json` (`name, path_in_game, genres, keywords, describe, api`). The
designer is told they exist, the spec lists them as prebuilt, the art pass copies them into the game and
every coder call lists their API; the fixer never edits them. Add a module by adding its file and entry.

**ObbyKit** (obby games): checkpoints with a saved `Stage`, respawn, kill parts, falls back to the
checkpoint, ten obstacle kinds on one Heartbeat loop, and `LevelBuilder`, which builds stages from level data.
The data comes from the `level_designer` Mubit task:

```bash
forge levels <slug> --zones 1-10 --stages-per-zone 20   # one call per zone; resumable
```

`forge/obby.py` checks every jump against the default character (walk 16, jump height 7.2: 10 studs flat,
7.4 when rising 6, calibrated against a live runner). Broken stages go back to the same Mubit task as a
correction with the exact errors (up to 2 times), and the zone lands as `ReplicatedStorage/Levels/ZoneNN.luau`.
The obby checks (`forge/genre_checks/obby/`) are copied into `runs/<slug>/checks/` for `forge checks --run`.

## Using it from Claude Code

The `forge` plugin's tools:

| Group | Tools |
|---|---|
| Setup | `setup`, `doctor` |
| Build | `build_game`, `iterate`, `correct`, `feature` |
| Improve | `improve_game`, `done`, `fault_drill`, `tester_report`, `tester_reports` |
| Versions | `versions`, `rollback` |
| Watch | `dashboard` |
| Jobs | `job`, `jobs`, `cancel_job` |
| Read | `games`, `game`, `read_file`, `scores`, `playbook`, `lessons`, `calls` |
| Ship | `seed`, `promote`, `sync` |

Building and improving take minutes, so they run as a background job (log in `runs/jobs/`).
`build_game` and `improve_game` follow the job for a few minutes, streaming progress, and return a
summary first; `job(id, wait_seconds=300)` keeps following it. A typical session:

1. `setup` until it says ready.
2. `build_game("lava obby with checkpoints", iterations=2)`, then `job(id, wait_seconds=300)` until finished.
3. `game(slug)` and `read_file(slug, path)` to see what it made.
4. `improve_game(slug)`: playtest, find anomalies, fix, verify; repeat until `done(slug)` says READY.
5. `correct(slug, "ServerScriptService/Round.server.luau", "rounds never end")`: a human correction,
   recorded in the fixer's Mubit task. The job log ends with the request id to rate Good.
6. `tester_report(slug, "the hose feels useless")` after real people play, then `improve_game(slug)` again.
7. `scores(slug)` and `calls(slug)` for the numbers and the Mubit request ids.

Other servers that work alongside it:

| Server | What it does |
|---|---|
| `mubit-tester` (plugin) | Plays and inspects the game in Studio: every player, scenarios, AI playtests, `playtest_correct` (`docs/TESTER.md`). |
| `Roblox_Studio` | Studio's own MCP: `execute_luau`, play/stop, console, screenshots. |

## Adding a feature to an existing game

Ask in plain words; the Mubit agent does the rest:

```bash
forge feature flame-and-blame-feat "game passes, like a battle pass" --iterations 2 --polish 3
```

(MCP tool: `feature(slug, request, iterations, polish)`.) What happens:

1. **Rollback point.** The game is saved as a version first (`before feature: ...`); the command prints
   the exact `forge rollback` to undo everything.
2. **Plan** (Mubit task `planner`). The planner reads the game's spec and a map of every file (first
   comment line each), and returns:
   - up to 5 **new modules** for the feature (agent-owned files, following the game's own architecture,
     e.g. a new `*Service` in an auto-discovered folder);
   - a few **hook-in edits** to existing files, only where the feature cannot work otherwise;
   - the **telemetry counters** the feature must bump (e.g. `battlepass_xp_awarded`);
   - **acceptance checks** a tester can observe.

   Unsafe parts are dropped: paths outside the Roblox roots, `..`, a "new" file that already exists, or
   an edit to a file that doesn't exist.
3. **Build.** The coder writes each new module. The patcher makes each hook-in edit (exact edits for
   big files, so nothing gets shortened); the destructive guard rejects rewrites. Then a compile check,
   the fixer on errors, and a version `feature: ...`. The new modules and acceptance checks join the
   game's spec, so every later run knows about them.
4. **Iterate** (`--iterations N`). Playtest, critic, fixer and reflector, with auto-rollback on a score
   drop. When the spec has `"playtest": {"start_round": true}`, each playtest starts a round first, so
   the feature runs in play instead of the lobby.
5. **Polish end to end** (`--polish N`). AI testers play inside a round. The auditor judges the whole game
   against its acceptance list (the feature's checks included), not one symptom at a time, so missing
   pieces like a UI that never shows or XP that is never awarded become anomalies. Then the loop runs
   investigate, fix or patch, and verify, keeping or rolling back each fix, cycle after cycle, until
   nothing high or medium is open.
6. **Verified** when every planned counter shows up above zero in a playtest. The result is logged in
   `runs/<slug>/features.jsonl`, and all calls are traced.

Proof from night 1: `flame-and-blame-feat` got **FlareUpService** (one new 135-line file, no human file
touched). In a mission playtest it ran **8 flare-ups with 0 server errors**, and the critic's score went
5, 5, then 7 over its iterations (`evidence/flame-and-blame-feat/`).

## Watching the runs

`forge dashboard --open` (tool: `dashboard`) serves a live page at http://127.0.0.1:8765. It
refreshes every 3 seconds and reads `runs/`. Pick a game at the top. It shows:
- **The team:** one builder per Mubit role (Planner, Designer, Coder, Tester, Critic, Inspector,
  Investigator, Bug Fixer, Patcher, Checker, Coach). While a run is building the game, the role in
  its latest log line hammers away, with what it is doing in plain words.
- **Chest + pop-up:** every new version is a finished mission. A chest drops, opens, and says what
  improved ("Fixed cube drop rate", "Added game passes"), worded from the version message, kept
  fixes and the critic's issues (no LLM call). "Replay the build" plays the whole story.
- **Goal track:** critic score toward 10/10 and rounds done toward the run's target.
- **Mission control:** one swimlane per agent (designer, coder #1..#N, fixers, each tester in the
  swarm, critic, verifier, ...) with its current step, its thought in one line, the latency of its
  latest call and a strip of every call on the run's timeline, so parallel work is visible.
- **What the testers see:** the newest step screenshots per tester with each step's assertions
  (pass/fail); tap one to enlarge, arrow keys step through. Critic playtest shots per round too.
- **Mubit learning:** per role (Mubit task) calls toward the 25 a task trains on, corrections fed
  and kept examples, the latest "correction -> model update" moments, and a link to the console.
- **Version timeline + speed:** critic and fun score per version with the change and diff size;
  wall clock per stage against one-call-at-a-time, and the overall speed-up.
- **Final report:** when nothing is building the game, "Your game is ready" with what changed.
- **Treasure map:** one chest per version. Tap one for its message, changed files and kept fixes,
  and "Go back to vN". A rollback runs `forge rollback --no-sync` (saved as a new version, nothing
  is lost); it only works from 127.0.0.1 and not while a run is building that game. `forge watch`
  syncs the restored files into Studio.
- **Nerd view:** everything the old page had. Running jobs and logs with tails, AI playtests,
  Mubit calls per role against the 25 a task needs to train, iterations, fix cycles with every
  verdict, versions, features and tester reports.

`--host 0.0.0.0` shares it on your network, for example on a teammate's screen or a projector.

## The self-improving loop

**`forge fix <slug>`** (tool: `fix`) improves the real game:

1. Play a few rounds with mubit-tester's AI players.
2. The **auditor** reads a compact digest of each round (counters, events, errors, the judge's bugs;
   never the code) and lists anomalies. With `--reports`, anomalies from tester reports filed since
   the last cycle are added.
3. For each high or medium anomaly, Forge finds the most likely file and the **fixer** rewrites it.
4. The file is compile-checked, Studio is resynced and a round is replayed.
5. The **verifier** compares before and after: `fixed` keeps the change; anything else rolls it back
   and resyncs.
6. Repeat until no high or medium anomaly is left (the quality bar) or `--cycles` run out.

Human-owned files (a seeded game's `base_files`) are never edited: the fixer's patch is saved to
`runs/<slug>/improve/patches/` for a person to review.

**`forge improve <slug>`** (tool: `improve`) measures how good the auditor is. It plants known faults
from `forge/faults/<slug>.json` through the ForgeTest harness (for example a hose tank that empties
in one spray), plays rounds, and scores the auditor against them. Every fault it missed is re-sent
to the auditor as a verified outcome (a correction in its Mubit task) and becomes a lesson in
`runs/<slug>/improve/playbook.md`, which the next audit reads. Detected faults are restored and the
verifier checks them. `--fix` also fixes the real anomalies afterwards, on a clean baseline round.

**`forge report <slug> "<text>"`** (tool: `tester_report`) is for real testers. The **triage** role
turns their words into anomalies backed by the round telemetry (`--run <playtest id>` names the
rounds). Anything the auditor had not flagged is re-sent to the auditor as a correction, so real
players teach the auditor.

### Versions and rollback

Every game folder (`runs/<slug>/game`) is its own git repo with versions `v1`, `v2`, .... A new
version is saved:
- when a game is seeded;
- for each iteration's tested code (with its critic score);
- before each fix cycle;
- for every kept fix (with the anomaly and the verifier's request id).

The agent rolls back by itself in two places:
- **Build loop:** an iteration that scores at least 1 point below the best version is restored to
  that version. Its fixes are skipped and the reflector is told why.
- **Fix loop:** a fix the verifier rejects is retried once with the verifier's evidence (a
  correction in the fixer's Mubit task). If that fails too, the file is restored and Studio
  resynced.

You can roll back by hand: `forge versions <slug>` and `forge rollback <slug> v3` (tools:
`versions`, `rollback`). A rollback is saved as a new version, so it can be undone too.

### Make an existing game playable (with a fallback)

```bash
forge seed flame-and-blame                       # copy game/ into runs/flame-and-blame/game (version v1)
forge fix flame-and-blame --edit-human-files --cycles 5 --studio Forge.rbxlx
forge versions flame-and-blame                   # what changed, version by version
forge rollback flame-and-blame v1                # back to the seeded game, resynced into Studio
forge promote flame-and-blame <path>             # copy a fixed file back into game/ for a PR
```

`--edit-human-files` lets the fixer change the team's files, but only in the run copy. `game/`
changes only when you promote a file and merge the PR.

`forge scores <slug>` shows, per cycle: faults planted, detected and missed, fixes verified, open
anomalies, and code fixes kept out of tried.

Faults only work when the game's services read those config keys at use time, and when the
ForgeTest harness (`game/ServerScriptService/ForgeTest.server.luau`) is in the place.

## Using it from the shell

```bash
forge new "co-op lava floor escape where you carry friends" --iterations 3
forge run lava-escape --iterations 2         # more iterations
forge correct lava-escape ServerScriptService/Round.server.luau "rounds never end when everyone dies"
forge fix lava-escape --cycles 5 --reports   # find anomalies, fix, verify, until clean
forge feature lava-escape "a double-jump power-up" --iterations 2 --polish 3   # add a feature
forge report lava-escape "the hose feels useless" --by sam
forge improve flame-and-blame --cycles 3     # planted-fault benchmark; --only <fault id>, --fix
forge scores lava-escape                     # per-cycle numbers; forge reports <slug>
forge versions lava-escape                   # saved versions; forge rollback lava-escape v3
forge dashboard --open                       # live view of all runs at http://127.0.0.1:8765
forge status                                 # every game: iterations, scores, calls per role
forge new "..." --no-studio                  # compile-only, no Studio needed
forge place --open                           # build place/Forge.rbxlx and open it in Studio
forge watch --studio Forge.rbxlx             # auto-sync game/ into Studio on every save
forge play "<goal>"                          # AI playtest (mubit-tester); play-correct, play-list
forge server                                 # the forge MCP server over stdio
```

## Developer setup (working on Forge itself)

```bash
uv venv && uv pip install -e ".[dev]"
cp .env.example .env        # put your mbt_ key in MUBIT_API_KEY
brew install luau           # luau-compile for syntax checks
.venv/bin/forge doctor      # every line should be ✓
.venv/bin/python -m pytest -q
```

Inside this repo both plugins are enabled by `.claude/settings.json`.

- **Model:** the default is `claude-sonnet-5-5`. Mubit's starter credit only serves
  `claude-opus-5-5`, `claude-sonnet-5-5` and `claude-haiku-4-5`; anything else fails with
  `400 starter_credit_model`. Keep the same model across the team: the model is part of a Mubit
  task's identity, so different models split the training examples.
- **Studio:** the MCP toggle is per window and resets when the window closes. Forge starts Studio's
  built-in `StudioMCP` itself. The first `list_roblox_studios` after a restart is often empty;
  retry.
- **Two Studio windows:** give Forge its own place so it never touches yours:
  `python3 game/tools/make_place.py --root place/empty --out place/Forge-ai.rbxlx`, open it, enable
  MCP, and run Forge with `FORGE_STUDIO=Forge-ai FORGE_SYNC_PORT=34874`. `--studio`/`FORGE_STUDIO`
  takes a name part or an exact studio id (`forge doctor` lists them).
- **Prompts are frozen:** never edit `forge/prompts/*.md` or `mubit-tester/prompts/*.md` once calls
  have been made. Mubit groups calls into tasks by the exact system prompt; an edit starts a new
  task at zero examples.

## Mubit console

[app.mubit.ai/console](https://app.mubit.ai/console/):
- **Tasks:** each role collecting examples and training. A task first trains at 25 kept examples,
  and an admin must switch training on in Settings.
- **Requests:** rate calls Good or Bad (`calls(slug)` lists the request ids).
- **Try models:** compares an adapter with the base model side by side.

## Layout

- `forge/`: the agent (Python). Contracts are in `docs/ARCHITECTURE.md`.
  - `prompts/`: one fixed system prompt per role.
  - `improve.py`, `faults/`: the self-improving loop. `mcp_server.py`: the `forge` MCP server.
- `forge-plugin/`: the Claude Code plugin (manifest, MCP launcher, `forge` skill).
- `mubit-tester/`: the game tester plugin (MCP server, ForgeTest harness, AI players, judge, explorer).
- `game/`: the human-built Flame and Blame game plus the Forge runtime (ForgeProbe,
  ForgeTelemetry, sync tools). `forge new` copies only the runtime; `forge seed` copies everything.
- `runs/<game>/`: generated games, specs, iterations, improve cycles and call logs (gitignored).
  `runs/jobs/`: background job logs.
- `docs/MUBIT_LOOP.md`: the self-improving loop design. `docs/research/`: Mubit and Studio MCP facts.
- `docs/TEAM.md`: how the team works in parallel (lanes, branches, PRs). The repo's Stop hook
  (`scripts/git-sync.sh`) pushes local commits on your current branch after every Claude turn, so
  keep work on branches.

## Hall of fame!!!

**Christopher White** was here!!!

> Why is the game called *Flame and Blame*? Because that's every codebase: something's on fire, and
> `git blame` says it was you!!!
