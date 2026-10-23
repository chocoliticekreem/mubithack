# Mubit Tester in Roblox Studio

Mubit Tester is a native Studio dock panel backed by the existing Python tester. Forge remains the separate game builder. The panel reuses the tester's scenarios, AI players, explorer, judge, corrections and fix suggestions. It does not introduce new AI prompts or bypass Mubit.

## Install into an open Studio window

From the checkout, after installing its Python dependencies:

```bash
.venv/bin/python scripts/install-studio-plugin.py --load-existing
```

The installer starts a local companion and writes `~/Documents/Roblox/Plugins/MubitTester.lua`. It loads the panel through the MCP connection in an already open Studio window. It never launches, closes or restarts Studio. With multiple connected windows, pass `--studio-id <exact-id>`. The installer refuses to live-load during a playtest. Use `--plugins-dir` for a custom local plugin directory.

Enable **Studio as MCP server** under Assistant's MCP settings in that window. If Studio blocks HTTP, use **Setup → Enable HTTP for this local place**, then reconnect. Published places require their normal Experience Settings and repository sync workflow. Studio may also request plugin permission to contact `127.0.0.1`.

Open the panel with **Plugins → Mubit Tester**. Files installed while Studio is running may need local plugin reload on a later session; `--load-existing` displays the panel immediately without a restart. Immediate loading uses Studio's deprecated `PluginManager():CreatePlugin()` compatibility API. The on-disk plugin uses the ordinary `plugin` object on future Studio starts.

## Panel actions

- **Test:** pick a bundled scenario, run a solo check, or inspect an already running playtest. Scenario assertions, skipped capabilities and runtime errors appear in Reports.
- **AI:** enter a goal or explore the game. Runs use one player in the current window and 1–20 decision ticks. Exploration is bounded to one minute of decisions plus finishing/judging work. A tick can make several API calls, so the limit is not a price cap.
- **Reports:** select a saved native job, read results and Mubit request IDs, request a fix preview for its first bug, or correct a selected AI decision. A correction sends a new example through the existing Mubit task. A fix suggestion does not apply a patch.
- **Setup:** reconnect this exact window or install the four test runtime scripts in an unpublished local place. Existing instances with matching names are updated from the checkout. An undo recording groups the changes; unrelated game scripts are preserved.

AI actions require `MUBIT_API_KEY` in the checkout's `.env`. The companion reads it; the installed plugin only holds a random local pairing token. After changing `.env`, stop and restart the companion. Scripted scenarios need no AI key. This first version does not provide game generation, content changes, automatic patch application, scheduled improvement or multiplayer window creation. Game-specific scenarios use Flame and Blame's existing tags and service contracts; another game needs its own scenarios and instrumentation.

## Ownership and stopping

Jobs bind through an editor-local marker to the exact Studio instance. Native jobs run one at a time. Tests refuse to take over a playtest that was already running. Each owned test starts solo play and returns to Edit on completion, failure or cancellation. **Stop test** stops new actions and cleans up the owned playtest. Closing/unloading the plugin requests cancellation; losing its heartbeat for 45 seconds also requests cancellation. Cleanup failures remain visible in the job report so the user can stop Studio manually. A paid request already sent to Mubit may finish after cancellation.

The companion serializes its own jobs only. Do not run another mutating MCP/CLI client or manually change play mode during a native job. Live inspection reads an existing playtest without taking ownership or stopping it. Restarted companion jobs are marked interrupted and are not replayed; an already running playtest after an abrupt process crash must be stopped in Studio.

## Local processes and data

The server binds only to `127.0.0.1:34874`. Every endpoint requires the pairing bearer token; no browser CORS access is enabled. Use `--port` to choose another port, and reinstall so the plugin matches it. Stop the companion with:

```bash
kill -TERM "$(cat runs/studio-plugin/companion.pid)"
```

Re-run the installer to start it again. It runs for the current login session, with no startup agent installed. Its PID, log, token and native job files live under ignored `runs/studio-plugin/`. AI reports keep the existing tester's report location. Uninstall by removing `MubitTester.lua` from the local Plugins folder and stopping the companion. Keep this checkout and its `.venv` in place; standalone packaged distribution is a future step.

## Verification

```bash
.venv/bin/python -m pytest -q mubit-tester/tests/test_studio_service.py
luau-compile studio-plugin/MubitTester.plugin.luau > /dev/null
```

Ownership tests cover exact-window binding, refusal to take over human playtests, cleanup on failure and cancellation, cancellation before the job starts, busy state, scenario allowlisting, absent AI credentials, skipped outcomes, restart recovery, HTTP authentication and body limits. Live checks must also confirm panel connection, harness installation, a real scenario report and return to Edit in the selected local Studio window.
