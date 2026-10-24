# MuMake in Roblox Studio

This repo has two Studio plugins in `studio-plugin/`: **MuMake** (below), a guided creator panel with its own companion, and **ForgeBridge** ([jump](#forgebridge-the-studio-plugin-bridge)), a live event stream and fast command channel between Studio and Forge / the mubit-tester MCP.

MuMake is a native Studio dock panel backed by the existing Python game builder and tester. The panel reuses the builder's design and coding loop and the tester's scenarios, AI players, explorer, judge, corrections and fix suggestions. It does not introduce new AI prompts or bypass Mubit.

## Install into an open Studio window

From the checkout, after installing its Python dependencies:

```bash
.venv/bin/python scripts/install-studio-plugin.py --load-existing
```

The installer starts a local companion and writes `~/Documents/Roblox/Plugins/MuMake.lua`. It loads the panel through the MCP connection in an already open Studio window. It never launches, closes or restarts Studio. With multiple connected windows, pass `--studio-id <exact-id>`. The installer refuses to live-load during a playtest. Use `--plugins-dir` for a custom local plugin directory.

Enable **Studio as MCP server** under Assistant's MCP settings in that window. If Studio blocks HTTP, use **Settings → Allow MuMake to connect in this local game**, then reconnect. Published places require their normal Experience Settings and repository sync workflow. Studio may also request plugin permission to contact `127.0.0.1`.

Open the panel with **Plugins → MuMake**. Files installed while Studio is running may need local plugin reload on a later session; `--load-existing` displays the panel immediately without a restart. Immediate loading uses Studio's deprecated `PluginManager():CreatePlugin()` compatibility API. The on-disk plugin uses the ordinary `plugin` object on future Studio starts.

Live updates of a panel that supports state handoff preserve typed drafts, navigation, layout choices and test budget directly inside Studio. They do not send those preferences to the companion. The installer leaves an active MuMake job running and defers reloading its panel until the job finishes or is stopped.

## A workspace that fits the creator

The panel adapts to its actual dock width. Narrow docks use compact margins and keep every tool available; wrapped text and buttons grow vertically. Wide panels keep a centered content column capped at 560 pixels. Actions stay above the bottom edge while the page scrolls. The floating width hint is 440 pixels and the minimum width is 320; Studio owns dock sizing and may restore a previous size. No fixed-width canvas or text scaling is used.

**Your saved games** includes drafts created by the agent plugin in the same checkout. Open one to review its acceptance checks, choose a script to change, read its source, inspect review scores and Mubit request IDs, or run another code review. Changes call the existing `forge.loop.correct` and `forge.loop.run_game` functions in a separate saved revision. The original draft and Studio stay unchanged until **Add draft to Studio**. A revision can update scripts owned by the same MuMake project; another project's scripts and human-owned scripts are protected. Local edits to MuMake-owned scripts may be replaced when you explicitly add a revision, so review the saved draft before applying it.

Under **More controls**, Check game offers 4, 8 or 16 AI moves. That budget also applies to looking for problems. The backend caps requests at 20 moves. The budget changes no data until the creator starts a paid AI action.

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

The intended next stage is to derive executable checks from each requested feature, run them against the real game, save reproducible checks for verified bugs, propose changes, and rerun before claiming a fix. For example, a sword shop needs checks for enough coins, insufficient coins, one sword per purchase, and the correct deduction. Feature-specific deterministic test generation and automatic runtime-verified repair are not implemented by this UI.

AI actions require `MUBIT_API_KEY` in the checkout's `.env`. The companion reads it; the installed plugin only holds a random local pairing token. After changing `.env`, stop and restart the companion. Scripted scenarios need no AI key. Draft revision supports a chosen script, rather than redesigning the whole game from a follow-up. The plugin does not apply playtest fix previews automatically, schedule improvement or create multiplayer windows. Game-specific scenarios use Flame and Blame's existing tags and service contracts; another game needs its own scenarios and instrumentation. For a generated game loaded through MuMake, AI play receives the saved design in its user context, and fix suggestions search that report's game source. System prompts remain unchanged.

## Capability parity with the agent tools

| Workflow | Native panel | Shared implementation or remaining boundary |
|---|---|---|
| Create a game | Available | Existing Forge design/build/review, one code-only iteration and explicit Studio installation |
| Resume agent-created games | Available | Same `RunStore` library in this checkout |
| Iterate and correct a script | Available | Existing builder/fixer, in a separate code-only revision |
| Read code, review scores, call IDs | Available | Saved game modules, iteration records and Mubit calls |
| Quick checks, goal play, explore | Available | Same harness, scenarios, AI players and judge, bound to one Studio window |
| Bug fix previews and move corrections | Available | Same suggestion and correction tasks; report-specific game context |
| Automatic fix, replay and verifier rollback | Agent tool only | Native revisions are not runtime-verified fixes |
| Multiplayer, squad and low-level world controls | Agent tool only | Native playtests own one solo session |
| Tester report triage, benchmarks, scores/playbook, seed/promote | Agent tool only | Development and benchmark workflows remain in the agent tools |

Native and agent jobs must not run concurrently against the same game or Studio. Sharing the underlying functions does not create a cross-process job lock.

## Ownership and stopping

Jobs bind through an editor-local marker to the exact Studio instance. Native jobs run one at a time. Tests refuse to take over a playtest that was already running. Each owned test starts solo play and returns to Edit on completion, failure or cancellation. **Stop** stops new actions and cleans up the owned playtest. Closing/unloading the plugin requests cancellation; losing its heartbeat for 45 seconds also requests cancellation. Cleanup failures remain visible in the job report so the user can stop Studio manually. A paid request already sent to Mubit may finish after cancellation.

The companion serializes its own jobs only. Do not run another mutating MCP/CLI client or manually change play mode during a native job. Live inspection reads an existing playtest without taking ownership or stopping it. Restarted companion jobs are marked interrupted and are not replayed; an already running playtest after an abrupt process crash must be stopped in Studio.

## Local processes and data

The server binds only to `127.0.0.1:34874`. Every endpoint requires the pairing bearer token; no browser CORS access is enabled. Use `--port` to choose another port, and reinstall so the plugin matches it. Stop the companion with:

```bash
kill -TERM "$(cat runs/studio-plugin/companion.pid)"
```

Re-run the installer to start it again. It runs for the current login session, with no startup agent installed. Its PID, log, token and native job files live under ignored `runs/studio-plugin/`. AI reports keep the existing tester's report location. Uninstall by removing `MuMake.lua` from the local Plugins folder and stopping the companion. Keep this checkout and its `.venv` in place; standalone packaged distribution is a future step.

The installer checks the companion protocol before replacing the local plugin. If an older helper is running, finish or stop its job, stop that helper using its PID file, and rerun the installer. This prevents installing new controls against an incompatible old process.

## Verification

```bash
.venv/bin/python -m pytest -q mubit-tester/tests/test_studio_service.py mubit-tester/tests/test_studio_presenter.py mubit-tester/tests/test_studio_builder.py
luau-compile studio-plugin/MuMake.plugin.luau > /dev/null
luau studio-plugin/tests/experience.spec.luau
luau studio-plugin/tests/layout.spec.luau
luau studio-plugin/tests/activity.spec.luau   # ForgeBridge Runs panel: line text, ages, colours
```

Ownership tests cover exact-window binding, refusal to take over human playtests, cleanup on failure and cancellation, cancellation before the job starts, busy state, scenario allowlisting, absent AI credentials, skipped outcomes, restart recovery, HTTP authentication and body limits. Live checks must also confirm panel connection, harness installation, a real scenario report and return to Edit in the selected local Studio window.

## ForgeBridge: the Studio plugin bridge

Without the bridge, Forge reaches Studio only through StudioMCP: one `execute_luau`,
`screen_capture` or `start_stop_play` at a time, each going through the StudioMCP proxy process and
JSON-RPC. Nothing comes back unless Forge asks for it.

ForgeBridge adds a second, two-way channel:

```
 Roblox Studio (each datamodel: Edit, and Server/Client while playing)
 └─ ForgeBridge plugin  (studio-plugin/ForgeBridge.plugin.luau)
      │  HttpService long-poll + event batches, 127.0.0.1 only, X-Forge-Token
      ▼
 forge bridge  (forge/bridge.py, `forge plugin serve --place NAME`)
      ▲                      ▲                          ▲
 forge/studio.py        mubit-tester MCP           dock widget buttons
 (fast path, falls      studio_status /            (Actions: run tests,
  back to StudioMCP)    studio_events / studio_run  forge correct)
```

* **Studio → Forge, live:** output and warnings (LogService), runtime errors with script path and
  trace (ScriptContext.Error), play started/stopped, Explorer selection, and script tree changes
  (scripts added, removed or edited under the services Forge syncs).
* **Forge → Studio, fast:** queued commands run as soon as they arrive, because a long-poll is
  always waiting. Ops: `run` (Luau, same contract as `execute_luau`), `play` (start/stop), `state`,
  `tree`, `ping`. File sync rides on `run`: `Studio.sync()` serves the files and runs the same
  `pull_luau` code through the bridge.
* **Dock widget "Forge"** (Edit only). It shows whether the bridge is connected, the current job,
  the role at work, the last test result, the selected script, the last error and what Forge says.
  It has two buttons:
  * **Ask Forge to fix this** sends the selected script and its latest error. If Forge's status
    names a game (`slug`), the bridge runs `forge correct <slug> <file> "<error>"`, which is a fixer
    call in the fixer's Mubit task. Otherwise the request waits in `studio_events` for an MCP client.
  * **Run tests** runs `forge test scenario_run smoke` (choose another with `--scenario`) against
    this window. "Last test" then shows PASS or FAIL and the failing step, and the full report is
    saved to `runs/studio-bridge/last_test.md`.

  Below the fields, **Runs** shows the three Forge runs whose files moved most recently, each with
  its five newest actions on one line: a mark and colour for the status (green ok, red failed, blue
  running, grey stopped) and the action, for example `· coder wrote ServerScriptService/Shop.luau`,
  `· level_designer zone 3: 0 errors after 2 tries`, `! playtest round 2: 1 errors, score 5.0` or
  `· autopilot round 2: kept (kept 1, rolled back 0)`. The age (`2m`), and on a run's header its
  status (`running · 30s`), sit in a right-aligned column, so a long action or slug is cut short at
  narrow dock widths but the age and status are not. A run is "running" while a Forge job or log
  that names it is alive (the same check the web dashboard uses), so a long Mubit call or playtest
  that writes nothing for minutes still counts; without one, it is running while its files moved in
  the last 5 minutes or its autopilot process is alive. An unfinished call of an idle run shows as
  stopped. The panel refreshes
  every 4 s while the widget is open. Click an action to print its details to Output (role, step, time
  taken, error, thought, Mubit request id). It reads `GET /activity` and writes nothing. The text,
  age and colour rules are the pure `studio-plugin/Activity.luau`, which `build_plugin` embeds.

### Use it

```bash
.venv/bin/forge plugin install --place Forge-agents-25  # writes ~/Documents/Roblox/Plugins/ForgeBridge.lua
.venv/bin/forge plugin serve --place Forge-agents-25    # the bridge; binds only the places you name
.venv/bin/forge plugin status                        # connected datamodels, play state, Forge status
.venv/bin/forge plugin events --follow               # watch Studio live
.venv/bin/forge plugin bench --studio Forge-agents-25  # round-trip: bridge vs StudioMCP
```

You run `forge plugin install` yourself, because Studio loads plugins for every place you open.
Nothing installs it automatically. `forge plugin load --studio NAME` live-loads the plugin into
**one** open window over StudioMCP without writing to the Plugins folder (agents use this). A
live-loaded copy runs only in the datamodel it was loaded into, so after play starts, run
`forge plugin load` again to get the Server copy. An installed plugin is in every datamodel
automatically. Studio may ask once for permission to let the plugin reach `127.0.0.1`.

Forge (or anything else) updates the widget through `BridgeClient().set_status(job=..., role=...,
last_test=..., message=..., slug=...)` or `POST /status`.

### Why it is safe to install globally

* **It does nothing in other places.** `install --place` bakes the allowed place names into the
  file. In any other window the script returns on its first lines: it makes no HTTP request,
  changes no setting and creates no UI. The places are compared by `game.Name`, with `.rbxlx`
  dropped and case ignored.
* **In a listed place it still waits for the bridge.** Until a bridge answers and also lists the
  place, the plugin creates no toolbar, widget or signal connection, and it runs no command. It
  asks again with backoff (3 s up to 30 s).
* **What it changes in a listed place.** Local places ship with `HttpService.HttpEnabled = false`,
  which blocks plugin requests too, so the plugin turns it on, as `forge sync` does during a pull.
  It also sets the Workspace attribute `ForgeBridgePlace`, because every playtest datamodel is
  named "Game" and the Server and Client copies read the real place name from their clone of
  Workspace. Both changes are saved only if you save the place.
* **Every request carries a token.** The plugin file holds a random token (from
  `runs/studio-bridge/token`, mode 0600) and the bridge rejects anything else with 401. The Mubit
  key is never in the plugin.
* The bridge listens on 127.0.0.1 only. Commands run with plugin security in the bound window, so
  only bind places you own (never the shared "Firefighter Mubit" place unless you mean to).

### Protocol (v1)

All bodies are JSON. Every route except `/health` needs the `X-Forge-Token` header.

Plugin side:

| Route | Body / query | Reply |
|---|---|---|
| `POST /plugin/hello` | `{place, dm: Edit\|Server\|Client, session, version}` | `{protocol, bound, poll_wait, forge?}`. Only a bound place gets a session. |
| `GET /plugin/poll` | `?session&wait=15&fv=<forge version seen>` | `{commands:[{id, op, args}], forge?}`. Held open until a command for this datamodel is queued or the Forge status changes. `{unknown_session:true}` means say hello again. |
| `POST /plugin/result` | `{session, id, ok, result?, error?, ms}` | `{ok}` |
| `POST /plugin/events` | `{session, events:[{type, ...}]}` (≤200 per batch, flushed every 0.25 s) | `{accepted}` |
| `POST /plugin/bye` | `{session}` | `{ok}`. Also sent on plugin unload and on Server `BindToClose`. |

Forge side:

| Route | Body / query | Reply |
|---|---|---|
| `GET /status` | | `{connected, playing, sessions:[{dm, place, idle_s}], forge, events, queued}` |
| `POST /status` | `{job?, role?, last_test?, message?, slug?}` | the new Forge status (pushed to the widget at once) |
| `GET /events` | `?since=N&types=a,b&limit=200&wait=0` | `{events:[{seq, time, type, dm, ...}], next, latest}` |
| `GET /activity` | `?runs=3&events=5` (runs ≤10, events 1–20) | `{now, runs:[{slug, title, status, age_s, events:[{ts, age_s, role, text, status, detail, request_id}]}]}`, built by `forge/dashboard.py` `activity_view` from `runs/<slug>/` (timings.json calls, calls.jsonl and traces after them, levels/log.jsonl, state.json iterations, autopilot/status.json rounds). 409 if the bridge was started without a feed. |
| `POST /run` | `{op, args, dm, timeout}` | `{ok, result \| error, ms, studio_ms}`. 409 if no plugin is connected in that datamodel. |

Event types: `log {kind: output|info|warning|error, message}`, `error {message, trace, script}`,
`play {state: started|stopped}`, `session {state: up|gone, dm}`, `selection {paths}`,
`tree {action: added|removed|edited, path, class}`, `fix_request {script, error, trace}`,
`run_tests`, `forge` (status changes), and `dropped {count}` if the plugin's outbox overflowed.

How each piece works:

* **Run Luau.** Plugins can't `loadstring`, so the plugin puts the code in a fresh, unparented
  ModuleScript as `return function(...) <code> end`, requires it and calls it. A top-level
  `return` behaves as it does with `execute_luau`. Tables come back JSON-encoded and everything else
  as `tostring`. A compile or runtime error comes back as `ok:false`. `BridgeClient.luau` raises
  `LuauError` for it, and `Studio.execute_luau` turns that into `StudioError`, as StudioMCP does.
* **Play.** `start` goes to the Edit copy, which calls
  `StudioTestService:ExecutePlayModeAsync`. `stop` goes to the Server copy, which answers first and
  then calls `StudioTestService:EndTest`. The bridge waits until the Server session appears or goes
  away. "Playing" means a Server session is live.
* **Liveness.** A session that hasn't polled for 25 s is dropped. Commands it held fail with
  "datamodel went away", and dropping a Server session emits `play stopped`. A reloaded plugin
  replaces its old Edit or Server session for the same place. Client sessions can coexist, one per
  test player.
* **Play errors reach the widget.** Runtime errors happen in the Server datamodel, and the widget
  lives in Edit. The bridge copies the newest `error` event into the Forge status as `last_error`,
  so the widget shows it and "Ask Forge to fix this" sends it.
* **Timing.** Every result carries `pickup_ms` (queued until a poll took it), `return_ms` (delivered
  until the result came back) and `studio_ms` (time spent running in Studio).

### MCP tools (mubit-tester)

`forge/bridge.py:register(mcp)` adds these tools to the mubit-tester server. The server loads it as
the `mubit_tester.studio_bridge` extension, so `server.py` itself is unchanged:

* `studio_status`: the bridge, sessions, play state and widget status.
* `studio_events(since, types, limit, wait)`: the live stream, oldest first. Pass `next` back as
  `since`.
* `studio_run(code, op, datamodel, start, path, timeout)`: run Luau or play/state/tree/ping,
  reporting the round-trip time.

They work from the shell too: `forge test studio_events --since 0`.

### Fallback

`Studio.execute_luau` and `Studio.play/stop` (forge/studio.py) first call `Studio.bridge(dm)`. It
returns a client only if a bridge is up **and** has a plugin session for the same place as the
selected StudioMCP window (and the requested datamodel). Otherwise, and on any transport error,
the call goes through StudioMCP as before. `FORGE_BRIDGE=0` turns the fast path off.

### Measured

Measured in Forge-agents-25 (macOS) with `return 1` in Edit, using the same `Studio` session for
StudioMCP. That StudioMCP session was already connected, which favours it.

| | Bridge | StudioMCP `execute_luau` |
|---|---|---|
| Studio focused, back-to-back (n=20) | **16.8 ms** median, 36.7 max | 66.5 ms median, 119 max |
| Studio in background, back-to-back (n=20) | **16.8 ms** median (every ~8th call waits ~930 ms) | 966 ms median |
| Studio in background, 0.4 s between calls | ~630 ms | ~650 ms |
| List all 76 scripts under ServerScriptService | 17.6 ms | 65.9 ms |
| Server datamodel during play, `#Players` (median) | 16.6 ms | 66.2 ms |
| `Studio.sync(game/)`, 162 files, nothing changed | 2.78 s | 2.82 s |

* **Studio's own HTTP tick.** When the window is in the background, Studio handles HTTP responses
  that weren't ready at once on a grid of about one second. We measured this with a delayed test
  server: 0.1 s → +909 ms, 0.5 s → +547 ms, 1 s → +34 ms. StudioMCP is slowed in the same way. The
  bridge stays fast while commands keep coming, and the first command after a quiet spell pays up
  to about a second. In a focused window every call is fast.
* **Sync is no faster.** `pull_luau` fetches each file with its own GET from inside Studio, so the
  transport saves nothing. Batching the files into one request (a change in `game/tools/sync.py`,
  lane #2) is the next speedup.
* **Play through the bridge.** Start and stop worked, and Studio went back to Edit. A live-loaded
  plugin needs the Server copy loaded by hand, which slows the start; an installed plugin doesn't.

Events seen live during the check: an output line and a warning from Edit; a script added, edited
and removed; a selection change; `session up` then `play started` for Server; a runtime error with
its script (`ServerScriptService.Exploder:3: attempt to index nil with 'amount'`) arriving as both
`error` and `log/error`; the Forge status, now carrying `last_error`; the `fix_request` from the
widget button, carrying that error; `run_tests` from the widget; and `play stopped` after the
Server's `bye`. The Run tests button ran the real smoke scenario against this window. It started
play, ran, stopped play, and the widget showed `FAIL smoke: step 3 everyone moved`. That failure
is real and belongs to the game: the walk check fails in this place too when you run it directly.
The full report goes to `runs/studio-bridge/last_test.md`.

Screenshots: `evidence/studio-plugin/forge-widget.png` (a play error mapped to the selected
script), `evidence/studio-plugin/forge-widget-after-run-tests.png`, and the whole window in
`evidence/studio-plugin/forge-widget-studio.png`.

A background Studio window doesn't repaint, so `screencapture` of it can show a blank or stale
widget. Bring the window to the front before you capture it.
