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

## How much time can it save?

For planning, compare the same small custom prototype: one short course or core loop, basic UI,
an upgrade or checkpoint mechanic, a playthrough and one fix/retest pass. Assume Studio, accounts,
AI access and tools are already configured. These ranges exclude publishing, original asset
production, complex persistence and a commercial release's full testing requirements.

| Approach | Time to budget for that prototype | Where the work goes |
|---|---|---|
| Build manually in Studio | **2–6 hours**, an illustrative planning estimate | Design, scripting, scene/UI work, playtesting, debugging and retesting |
| General AI assistant + Studio MCP | **30–90 minutes**, an illustrative planning estimate | AI can build and playtest; the session still needs its goals, context, checks and iteration decisions |
| MuMake native or AI plugin + Mubit | **Under 20 minutes** is the first-playable target; allow further runs for refinement | A reusable build/test/improve workflow, game context, tested modules, prioritised fixes and task-specific learning |

The manual and general-MCP ranges are our planning assumptions, not measured industry averages or
a controlled competitor benchmark. Experienced creators and existing templates may be much faster;
unfamiliar systems and complex mechanics may take much longer. Our evidence does not establish a
universal speed advantage for either MuMake surface.

The illustrative manual budget is 30–60 minutes for planning, 60–240 for building and 30–60 for
testing/fixing. The general-AI budget is 5–15, 10–30 and 15–45 minutes respectively. These are
work-allocation estimates, not timings reported by the sources below. MuMake's 20-minute target
ends at the first playable handoff; further refinement adds time and must be counted when
comparing equivalent quality.

Useful reference points:

- **Manual learning:** Roblox's [intro to coding and game design lesson](https://create.roblox.com/docs/education/lesson-plans/intro-to-game-and-coding)
  allocates **120 minutes** to an introductory obby workshop, including instruction and independent
  work. This is a learning example with a different scope, not a benchmark for an experienced developer.
- **General MCP already plays games:** Roblox's [Studio MCP announcement](https://devforum.roblox.com/t/assistant-updates-studio-built-in-mcp-server-and-playtest-automation/4474643)
  describes automated play sessions, keyboard/mouse input and character movement. MuMake's intended
  advantage is the repeatable production and learning workflow, not exclusive access to playtesting.
- **Measured local result:** the [2026-10-24 tycoon benchmark](evidence/bench/20261024T040253Z.md)
  took **576 seconds, or 9.6 minutes**, including a real Studio playtest, one iteration and **8/8
  executable checks passing**. It had no compile errors left, critic 7/10 and fun 6.2/10, but passed
  only **5/9 readiness parts**. It supports a fast build-and-check cycle, not a fully finished game
  or a measured result for every plugin interface.
- **Measured pipeline improvement:** across two compile-only builds, elapsed time fell from
  **2,243 to 1,142 seconds, about 2× faster**, after concurrency and related pipeline changes.
  Both used Mubit. This is not a measurement of trained adapters versus a general MCP assistant.
  See [benchmark methods and results](docs/BENCH.md).

To replace the estimates with a fair comparison, run identical briefs through all three workflows,
use the same acceptance checks and starting assets, record total time and human intervention,
and repeat across games and skill levels. Count success only when the agreed gameplay works.

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
The measured speed gains above come from pipeline improvements; an additional speed benefit from
Mubit learning needs a controlled comparison.

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
