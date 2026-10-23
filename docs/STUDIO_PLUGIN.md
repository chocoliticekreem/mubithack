# MuMake in Roblox Studio

MuMake is a native Studio dock panel backed by the existing Python game builder and tester. The panel reuses the builder's design and coding loop and the tester's scenarios, AI players, explorer, judge, corrections and fix suggestions. It does not introduce new AI prompts or bypass Mubit.

## Install into an open Studio window

From the checkout, after installing its Python dependencies:

```bash
.venv/bin/python scripts/install-studio-plugin.py --load-existing
```

The installer starts a local companion and writes `~/Documents/Roblox/Plugins/MuMake.lua`. It loads the panel through the MCP connection in an already open Studio window. It never launches, closes or restarts Studio. With multiple connected windows, pass `--studio-id <exact-id>`. The installer refuses to live-load during a playtest. Use `--plugins-dir` for a custom local plugin directory.

Enable **Studio as MCP server** under Assistant's MCP settings in that window. If Studio blocks HTTP, use **Settings → Allow MuMake to connect in this local game**, then reconnect. Published places require their normal Experience Settings and repository sync workflow. Studio may also request plugin permission to contact `127.0.0.1`.

Open the panel with **Plugins → MuMake**. Files installed while Studio is running may need local plugin reload on a later session; `--load-existing` displays the panel immediately without a restart. Immediate loading uses Studio's deprecated `PluginManager():CreatePlugin()` compatibility API. The on-disk plugin uses the ordinary `plugin` object on future Studio starts.

## A workspace that fits the creator

On first use, MuMake shows an optional two-step welcome flow. A coarse age range (13–15, 16–17, 18+) changes the visual treatment. Experience changes the density and help: starting out, made a few things, or confident. There is no name, date of birth, account survey or remote profile.

Age never locks capabilities. A younger experienced creator can expose all the controls, and an adult beginner can choose step-by-step help. Every layout retains game creation, draft review, adding scripts to Studio, character checks, AI goals, evidence and feedback. **More controls** is available within the workspace without changing the saved preference.

- The guided workspace includes an idea → draft → play path, examples and explanatory copy.
- The middle workspace keeps useful tips with a more compact presentation.
- The experienced workspace exposes optional include/avoid instructions and direct tool navigation, with fewer explanations.
- Younger styling is more playful; adult styling is more restrained. Both follow Studio's light or dark setting at load, with the same accessible controls.

**Back** returns to the previous screen, including the previous welcome step. It preserves the current idea, extra build instructions and feedback fields. **Guide** opens a replayable four-step guide linked to the actual creation, checking and result screens. Navigating the guide never starts a paid request or changes the game. **Settings → Change my layout** reopens the choices. Both welcome steps can be skipped.

### Privacy of UI preferences

The choice is held in plugin memory by default. **Remember this layout on this device** is off by default. If enabled, only a version, coarse age-band enum and experience enum are written with Studio's `plugin:SetSetting("MuMakeLayoutV1", ...)`. **Forget my saved layout** removes that local setting. No preference fields are attached to helper requests, AI prompts, game context, saved jobs or analytics. The game descriptions and feedback that a creator deliberately submits still follow the existing Mubit workflow; the privacy statement applies to these UI preferences.

The installer embeds the pure `studio-plugin/Experience.luau` module into the installed single-file plugin. Offline navigation and preference checks run with:

```bash
luau studio-plugin/tests/experience.spec.luau
```

## The creator's flow

The panel is for a first-time creator, including a 13-year-old who has never written a test. It opens on **Make game**, followed by **Check game**, **Results** and **Settings**. There are no run IDs, step numbers, model names or JSON dumps in the main flow.

The default **Make game** screen asks “What do you want to make?”, offers example ideas, and calls the existing `forge.loop.new_game` builder through Mubit. It makes one design/code/review iteration into an isolated `runs/<slug>/game` draft, without choosing a different Studio or touching the place. Source files must exist and compile before it is marked ready. It has not been playtested yet.

**Add draft to Studio** is a separate action on a finished draft. It only works in the same unpublished local Studio window. The installer preflights every destination before changing anything, refuses to overwrite different human-owned scripts, adds an undo recording, and does not delete unrelated content. It never opens another Studio instance. Use an empty local game if names conflict with existing scripts. Press Studio Play to try the draft, then use Check game to run checks.

1. **Prepare this game** appears only if MuMake cannot see all four helper scripts. Setup adds them with an undo record. It never changes unrelated game scripts.
2. **Quick check** shows its checklist before starting: join, walk, and read game errors. It uses the existing hand-written smoke scenario, with no AI calls.
3. **Try a goal** asks “What should a player be able to do?” MuMake uses the existing AI player to choose up to eight moves, then asks the judge to review the evidence. Its AI button stays unavailable with a clear explanation if no key is configured.
4. **Results** separates “These checks worked”, “Not checked”, “Goal not reached” and “Could not finish”. A missing feature or failed connection must not appear as a successful game check. Skipped optional checks are marked unchecked.
5. A possible problem has its own **Get a fix idea** button. This generates a preview, never applies a patch. **Try this check again** reuses the goal or checklist after a source change.
6. **Moves MuMake tried** lets the creator choose the move it misunderstood and explain what should have happened. MuMake supplies the actual report, player and decision IDs. **Send feedback** sends a correction through the existing Mubit task. It does not claim instant learning or modify the game.

Settings contains connection help and other firefighter-specific checks. Raw errors, request IDs, patch previews, environment variables and the local helper instructions are behind explicitly opened technical details. Native reports remain on disk with their original evidence; `studio_presenter.py` creates the readable view without rewriting outcomes.

## Where checks and learning come from

Repeatable checks are currently hand-written JSON in `mubit-tester/scenarios`. An AI goal produces an adaptive playthrough and saved report, not a newly generated deterministic test script. Running it again retries the same goal; its actions may differ. The player and judge prompts currently describe the firefighter game, so this is not yet a general game-making assistant.

Mubit receives model requests and responses, including an extra request when the creator corrects a move. Its training is a separate process, subject to workspace settings, accepted examples and evaluation. A feedback receipt is not evidence that an adapter has trained or that quality improved. The plugin does not fetch training status or switch inference to a newly trained adapter. See [Mubit's training guide](https://docs.mubit.ai/guides/first-adapter).

The intended next stage is to derive visible checks from each requested feature, run them against the real game, save reproducible checks for verified bugs, propose changes, and rerun before claiming a fix. For example, a sword shop needs checks for enough coins, insufficient coins, one sword per purchase, and the correct deduction. None of that feature-specific generation or automatic repair is implemented by this UI change.

AI actions require `MUBIT_API_KEY` in the checkout's `.env`. The companion reads it; the installed plugin only holds a random local pairing token. After changing `.env`, stop and restart the companion. Scripted scenarios need no AI key. This first version does not yet revise a generated game from follow-up instructions, apply fix suggestions automatically, schedule improvement or create multiplayer windows. Game-specific scenarios use Flame and Blame's existing tags and service contracts; another game needs its own scenarios and instrumentation.

## Ownership and stopping

Jobs bind through an editor-local marker to the exact Studio instance. Native jobs run one at a time. Tests refuse to take over a playtest that was already running. Each owned test starts solo play and returns to Edit on completion, failure or cancellation. **Stop** stops new actions and cleans up the owned playtest. Closing/unloading the plugin requests cancellation; losing its heartbeat for 45 seconds also requests cancellation. Cleanup failures remain visible in the job report so the user can stop Studio manually. A paid request already sent to Mubit may finish after cancellation.

The companion serializes its own jobs only. Do not run another mutating MCP/CLI client or manually change play mode during a native job. Live inspection reads an existing playtest without taking ownership or stopping it. Restarted companion jobs are marked interrupted and are not replayed; an already running playtest after an abrupt process crash must be stopped in Studio.

## Local processes and data

The server binds only to `127.0.0.1:34874`. Every endpoint requires the pairing bearer token; no browser CORS access is enabled. Use `--port` to choose another port, and reinstall so the plugin matches it. Stop the companion with:

```bash
kill -TERM "$(cat runs/studio-plugin/companion.pid)"
```

Re-run the installer to start it again. It runs for the current login session, with no startup agent installed. Its PID, log, token and native job files live under ignored `runs/studio-plugin/`. AI reports keep the existing tester's report location. Uninstall by removing `MuMake.lua` from the local Plugins folder and stopping the companion. Keep this checkout and its `.venv` in place; standalone packaged distribution is a future step.

## Verification

```bash
.venv/bin/python -m pytest -q mubit-tester/tests/test_studio_service.py mubit-tester/tests/test_studio_presenter.py mubit-tester/tests/test_studio_builder.py
luau-compile studio-plugin/MuMake.plugin.luau > /dev/null
```

Ownership tests cover exact-window binding, refusal to take over human playtests, cleanup on failure and cancellation, cancellation before the job starts, busy state, scenario allowlisting, absent AI credentials, skipped outcomes, restart recovery, HTTP authentication and body limits. Live checks must also confirm panel connection, harness installation, a real scenario report and return to Edit in the selected local Studio window.
