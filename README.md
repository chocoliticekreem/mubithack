# MuMake

**From an idea to a playable Roblox game in under 20 minutes. Refine it with a few more runs.**

MuMake helps you make, test and optimise Roblox games through either a **native Roblox Studio
plugin** or an **AI assistant plugin connected to Studio through MCP**. Describe what you want
to make, watch the game take shape, try it, and keep improving it through feedback and repeat runs.
All game-production AI goes through [Mubit](https://mubit.ai).

The under-20-minute goal is for a small playable prototype on an already configured setup. Extra
runs focus on bugs, gameplay, balance and polish. Larger games need more time; a playable first
version is the starting point for iteration, not a guarantee that every feature is finished.

**MuMake is the product name.** `forge`, `forge-plugin` and `mubit-tester` are the existing tool,
package and integration identifiers you will see in this checkout and its install commands.
They are not the product brand; the commands below use their current names so installation works.

## Two ways to create

| | Native Studio plugin | AI assistant plugin |
|---|---|---|
| Where you work | A MuMake panel inside Roblox Studio | Your connected AI coding assistant, currently packaged for Claude Code |
| How you start | Describe your idea in **Make game** | Ask for a game in plain language |
| How you improve | Build/review rounds, goal checks, feedback and saved revisions | Build, playtest, inspect evidence, add features, fix and verify |
| How much detail | Guided steps or more controls, chosen locally | Conversational help plus direct access to the MCP tools |
| What they share | The existing game builder, tester and Mubit-backed AI tasks | The same game builder, tester and Mubit-backed AI tasks |

The agent workflow has the broader automatic fix/verification and multiplayer toolset. The native
panel keeps creation and testing close to the game. The [native plugin guide](docs/STUDIO_PLUGIN.md)
covers installation and layout settings. The current automatic build/install/review loop is
implemented in [the native builder](mubit-tester/mubit_tester/studio_builder.py).

## A workspace that fits the creator

MuMake is designed for younger creators, adult beginners and experienced Roblox developers.
You should not need to know how to write a test case before you can check your game.

The native plugin offers optional age and experience choices. Age changes the visual treatment;
experience changes the amount of guidance and detail. The current age choices are 13–15, 16–17
and 18+, alongside starting out, made a few things, and confident.

- **Starting out:** examples, clear next steps and a replayable guide, with the real tools available.
- **Some experience:** a compact workspace with useful hints.
- **Experienced:** more direct controls and fewer explanations.

Age never locks a feature. Change the layout, show more controls or go back whenever you want.
The panel also adapts to its dock width. These layout choices stay local, are remembered only if
you opt in, and are not sent to Mubit, attached to game context or collected as analytics. Ideas
and feedback you deliberately submit still follow the normal AI workflow. The assistant plugin
uses its host's chat interface rather than the native panel's layouts.

## Make, play, improve

1. **Describe the game.** For example: “an obby where you collect coins, buy a jump upgrade and
   escape rising lava.” Start with a clear, small player experience.
2. **Build a first version.** The AI plans the systems, reuses available modules, generates the
   scripts and level data, checks compilation and repairs errors.
3. **Try it in Studio.** The native creation flow installs into the connected local place and
   runs build/review rounds. The agent workflow can run Studio playtests and inspect their results.
4. **Check what players can do.** Use saved checks or ask the AI player to attempt a goal, such as
   buying an upgrade. It can manipulate the character and interact with the game, with coverage
   depending on the game's instrumentation and available tools. Report what was actually checked.
5. **Run it again with feedback.** Fix blockers first, then improve mechanics, pacing, content and
   presentation. The agent repair workflow replays changes and keeps verified fixes or rolls them back.

The native loop aims to hand over a game for review around the 20-minute mark. It stops earlier
when its current review standard is met, and can report **Ready for review** while issues remain.
This is a soft handoff target: an in-flight build, model request or test can take longer. Its
current standard uses a playtest, no game errors and a critic score of at least 7/10. This is
separate from the broader `done` evidence bar and the requirements of a published game.

More runs are useful when they improve something the player will notice: a broken shop, an
unreachable level, confusing goals, repetitive content or an unfair progression curve. The shared
[game production guide](docs/GAME_PRODUCTION_GUIDE.md) defines priorities for 16 game families,
architecture foundations, feature/level contracts, testing and model evaluation.

## Vanilla development vs plain MCP vs MuMake

| | Vanilla development | Plain MCP-driven development | MuMake-driven development |
|---|---|---|---|
| Building | You design, script and assemble the game | An AI agent edits the game through Studio tools | A production harness coordinates planning, reusable kits, level generation and installation |
| Testing | You playtest and organise checks | The agent can control characters, inspect the game and run tests; the workflow depends on its instructions | Repeatable checks, QA bots, scripted player journeys and recorded outcomes are part of the workflow |
| Improvement | You diagnose, change and retest | You and the agent decide what to change and how to verify it | Review/fix rounds use previous outcomes; the agent repair workflow verifies changes and can roll them back |
| Learning between runs | Your experience and notes | Whatever context or memory the agent maintains | Saved lessons and failed attempts carry forward; corrections go back through the same Mubit tasks |
| Time for a small first prototype | **2–6 hours estimated** | **30–90 minutes estimated** | **Under 20 minutes targeted**, then more runs to refine |

The manual and plain-MCP times are illustrative planning estimates for a small custom game with
setup complete, not a measured comparison. MuMake's target is the first playable handoff; further
refinement adds time. MCP already supports building and playtesting. MuMake packages the production
workflow, reusable systems and evidence around those tools, so creators do not have to assemble
that workflow themselves. These records do not provide a same-brief timing comparison across all three.

### Example: Sunbeam Park Obby

Prompt: **“i want a 100 stage obby”**.

The [committed game](games/sunbeam-park-obby/README.md) and
[demo reflection](docs/research/2026-10-25-mumake-reflection.md) show what the MuMake harness adds:

- **About six minutes to the playable build**, as reported in the demo reflection. It generated
  100 stages across 10 zones, reusing the park, obby, cosmetics and music kits. The level data was
  designed in parallel; the game-specific scripts added gifts and extras.
- **Automatic installation into the existing Studio window**, followed by repeated playtest,
  critic and fixer rounds. The Studio phase ran six QA bots in parallel and a scripted journey.
- **Evidence beyond generated code:** the recorded Studio journey exercised a ride gate, the next
  zone entrance and the stage-100 finish trigger. This does not establish a complete 100-stage
  traversal by a player.
- **A visible testing gap:** four rounds reported 0 game errors but stayed at 6/10. Acceptance
  counters not exercised fell from nine to five, then stopped moving. Costume buying/equipping,
  gift readiness/claiming and achievements remained unexercised by that run's playtests.
- **An explicit handoff:** the demo was stopped during round five, and its “Ready for review”
  dashboard status was set manually. That status is not evidence of autonomous completion.

The example demonstrates the integrated workflow and its remaining coverage gaps. It does not
measure how long the same obby would take through plain MCP. Its Mubit integration records calls
and corrections and carries lessons forward; the reflection does not show a game built using a
Mubit-retrained adapter. The next runs need to prove the missing behaviour rather than just repeat
changes until a score rises. The later shop-journey fix does not retroactively verify this snapshot.

| After round 1 | After round 4 |
|---|---|
| ![Sunbeam Park Obby lobby after the first round](games/sunbeam-park-obby/screenshots/round-1.png) | ![Sunbeam Park Obby lobby after the fourth round](games/sunbeam-park-obby/screenshots/round-4.png) |

For another timed example, the [tycoon benchmark](evidence/bench/20261024T040253Z.md) took
**9.6 minutes**, including a real Studio playtest and **8/8 executable checks passing**, while
passing only 5/9 readiness parts. [Benchmark methods and results](docs/BENCH.md) separate build
speed, test coverage and readiness.

## Why Mubit is part of the loop

MuMake sends game-production AI requests through Mubit: planning, coding, level design, AI players,
critics, auditors, fixers and verifiers. It does not fall back to a direct provider when the Mubit
route fails. Compilers, scripted checks and Studio controls run as ordinary deterministic tools.

Each AI role uses stable instructions so repeated work can be grouped into a recurring task.
Verified mistakes and creator feedback can be sent back as corrections for the relevant task.
Lessons also preserve useful context for future builds. The aim is fewer repeated mistakes and
less time spent retrying the same work as the system gains useful experience.

A recorded correction is not an instant model update. Training depends on accepted examples and
workspace settings; a trained adapter needs evaluation and a verified serving path before claiming
it improves the live workflow. See [Mubit's adapter guide](https://docs.mubit.ai/guides/first-adapter)
and our [production guide](docs/GAME_PRODUCTION_GUIDE.md#12-model-learning-and-evaluation).
These build timings do not isolate a speed benefit from Mubit learning; that needs a controlled
comparison.

The host chat model is configured separately: installing an MCP plugin does not reroute the
assistant's own inference. Use the Mubit-backed tools for game-production tasks; if the host's
inference is also in scope, configure its Mubit connection separately.

## Install the native Studio plugin

The current distribution is a local plugin installed from this checkout, with a Python 3.11+
companion. Keep the checkout and its environment available while using it.

```bash
git clone https://github.com/chocoliticekreem/mubithack.git
cd mubithack
uv venv
uv pip install -e ".[dev]"
cp .env.example .env
brew install luau
```

Set `MUBIT_API_KEY` in `.env` and choose a model your Mubit workspace can serve. Open your intended
local place in Studio, then enable **Assistant → ⋯ → Manage MCP Servers → Enable Studio as MCP server**.
From the checkout:

```bash
.venv/bin/python scripts/install-studio-plugin.py --load-existing
```

The installer loads MuMake into an already open Studio window and writes
`~/Documents/Roblox/Plugins/MuMake.lua`. It never opens or restarts Studio. If several windows are
connected, select one with `--studio-id <exact-id>`. Open **Plugins → MuMake** and start with
**Make game**. Allow the plugin's local connection when Studio asks.

These dependency commands are for macOS; use your platform's Luau installation method and plugin
directory elsewhere. See [native setup, layout privacy and troubleshooting](docs/STUDIO_PLUGIN.md)
for companion details. Use an unpublished local place: installing a game does not publish it.

## Install the AI assistant plugin

The current Claude Code marketplace identifiers still use `forge` and `mubit-tester`:

```text
/plugin marketplace add chocoliticekreem/mubithack
/plugin install forge@mubithack
/plugin install mubit-tester@mubithack
```

Start a new session and ask:

> Set up MuMake using the installed forge and mubit-tester tools. Connect to my existing Studio
> window, then make a small lava obby with checkpoints and a coin shop. Playtest the core loop,
> fix the important problems and show me what passed and what still needs work.

Setup checks the Mubit connection, available model, Luau compiler and Studio connection. Choose
the intended Studio explicitly; do not open another instance when one is already in use.

| Task | Current MCP tools |
|---|---|
| Check setup | `setup`, `doctor` |
| Build and extend | `build_game`, `iterate`, `correct`, `feature` |
| Improve and assess readiness | `improve_game`, `done`, `tester_report`, `tester_reports` |
| Play and inspect | The `mubit-tester` plugin's scenarios, AI players, judge and `test_feature` |
| Keep or restore versions | `versions`, `rollback` |
| Follow work | `job`, `jobs`, `cancel_job`, `dashboard` |

Long operations run as background jobs. Follow `job(id, wait_seconds=300)` until completion and
read the actual evidence before calling a game ready. Avoid concurrent jobs changing the same
game or Studio session.

## Developer tools and documentation

The CLI remains available under its current `forge` identifier:

```bash
.venv/bin/forge doctor
.venv/bin/forge new "a short lava obby with checkpoints" --iterations 2
.venv/bin/forge fix <slug> --cycles 3 --reports
.venv/bin/forge done <slug> --json
.venv/bin/forge versions <slug>
.venv/bin/forge dashboard --open
.venv/bin/python -m pytest -q
```

Commands that build, review or improve games make paid Mubit calls. Set `FORGE_STUDIO` to the
intended Studio ID before building; commands that expose `--studio` can also select it explicitly.
Keep role prompts frozen; put changing game context and guidance in the user message.

| Resource | What it covers |
|---|---|
| [Game production guide](docs/GAME_PRODUCTION_GUIDE.md) | Genre priorities, architecture, levels, features, tests, improvement and evaluation |
| [Native Studio plugin](docs/STUDIO_PLUGIN.md) | Installation, adaptive UI, local preferences and testing controls |
| [Tester guide](docs/TESTER.md) | Harness, scenarios, character controls and AI testing |
| [Architecture](docs/ARCHITECTURE.md) | Tool and runtime contracts |
| [Benchmarks](docs/BENCH.md) | Reproducible timing and quality measurements |
| [Mubit loop](docs/MUBIT_LOOP.md) | Learning-loop design and integration history |
| [Team workflow](docs/TEAM.md) | Branches, ownership and shared-place workflow |

Source layout: `studio-plugin/` contains the native UI; `forge/` contains the existing Python
build/improve tools; `forge-plugin/` exposes the assistant integration; `mubit-tester/` contains
the tester and native companion. Generated games, evidence and call logs live under ignored
`runs/`. `game/` contains the Flame and Blame demo game and shared runtime helpers.

## Hall of fame!!!

**Christopher White** was here!!!

**Min** was here!!

> Why is the game called *Flame and Blame*? Because that's every codebase: something's on fire, and
> `git blame` says it was you!!!
