# game/

The base Roblox place, file-mapped like Script Sync. It holds the runtime every generated game
gets (ForgeProbe, DevHook, ForgeTelemetry) and the sync tool. Generated games live in
`runs/<slug>/game/` with the same layout; the base files are copied into each one.

## File → instance mapping

| On disk | In Studio |
|---|---|
| `ServerScriptService/…` | `ServerScriptService` |
| `ReplicatedStorage/…` | `ReplicatedStorage` |
| `StarterPlayerScripts/…` | `StarterPlayer.StarterPlayerScripts` |
| `ServerStorage/…`, `StarterGui/…`, `Workspace/…` | the service with that name (only if the folder exists) |
| `X.server.luau` / `X.client.luau` / `X.luau` | `Script X` / `LocalScript X` / `ModuleScript X` |
| a directory | a `Folder` |

## Sync (`tools/sync.py`, stdlib only)

```
python3 game/tools/sync.py check    --root DIR            # luau-compile --null each file, exit 1 on failure
python3 game/tools/sync.py manifest --root DIR            # DIR/tools/manifest.json
python3 game/tools/sync.py serve    --root DIR --port 34873
python3 game/tools/sync.py pull     [--port P] [--no-prune] [--out FILE]
```

Studio pulls the files instead of having them pushed. `serve` runs a file server for DIR on 127.0.0.1,
and the Luau from `pull` (`tools/pull.luau` is the default-port copy, regenerate it with
`sync.py pull --out game/tools/pull.luau`) runs through the Studio MCP `execute_luau` in the **Edit**
datamodel. That Luau:

- switches `HttpService.HttpEnabled` on and restores it afterwards,
- fetches `tools/manifest.json` and every file with cache-busting query strings,
- creates Folders for directories, replaces a script whose class changed, and sets `Source` only
  when it differs,
- tags every synced script with the CollectionService tag `ForgeManaged`,
- with prune on, deletes `ForgeManaged` scripts under the synced roots that are no longer in the
  manifest (scripts you made by hand in Studio are never tagged, so they are left alone),
- returns `OK n files, changed: <paths|none>[; pruned: …]` or `ERROR <message>`.

As a library: `check(root)`, `write_manifest(root)`, `serve_in_thread(root, port)`,
`pull_luau(port, prune=True)` (used by `forge/sync.py` / `Studio.sync`).

## Runtime (Studio playtests only)

`ServerScriptService/ForgeProbe.server.luau` does nothing outside Studio. During a playtest, from the
**Server** datamodel:

```lua
game.ServerStorage.ForgeProbe:Invoke("report")
-- {"uptime":12.3,"errors":[{"message","trace","script","count"}],"warnings":["... (x3)"],
--  "players":1,"joins":1,"counters":{"coins_collected":3},"instances":412}
game.ServerStorage.ForgeProbe:Invoke("reset")   -- clear errors and warnings
```

It records `ScriptContext.Error` and LogService warnings/errors (including ones logged before it
started), merges repeats with a count, and keeps at most 50 distinct entries of each kind.

Counters: games call `require(ReplicatedStorage.ForgeTelemetry).count("coins_collected", n)`
(server only, no-op on the client). Values are attributes on `ServerStorage.ForgeCounters`.

DevHook: `execute_luau` runs in its own VM, so `require` there gives fresh module copies. To reach
the live ones:

```lua
game.ServerStorage.DevHook:Invoke("RoundService", "StartRound", 30)  -- RoundService:StartRound(30)
game.ServerStorage.DevHook:Invoke("Config", ".Get", "speed")         -- Config.Get("speed")
game.ServerStorage.DevHook:Invoke("RoundService", "State")           -- a non-function field's value
game.ServerStorage.DevHook:Invoke("RoundService", "")                -- the module's keys
```

It returns `true, results...` or `false, err`. Modules are found by name under
ServerScriptService, then ServerStorage, then ReplicatedStorage.

## ForgeTest harness (Studio playtests only)

The in-game half of the `mubit-tester` MCP server (contract: `docs/TESTER.md`). Two scripts, both
inert outside `RunService:IsStudio()`:

- `ServerScriptService/ForgeTest.server.luau` creates `ServerStorage.ForgeTest` (BindableFunction),
  `ReplicatedStorage.ForgeTestRemote` (RemoteFunction), and an event log.
- `StarterPlayerScripts/ForgeTestAgent.client.luau` is the per-client actuator. It answers
  `ForgeTestRemote` calls tagged `"ForgeTest"` and says `hello` to the server when it starts
  (`players[].agent`, `ping.agents`).

From the **Server** datamodel:

```lua
local T = game.ServerStorage.ForgeTest
T:Invoke("ping")                                       -- {"ok":true,"result":{"version","players","agents","studio","time","clock","mapReady"}}
T:Invoke("players")
T:Invoke("observe", '{"userId":"1"}')                   -- me/world/things/prompts (play.py OBSERVE shape) + hud from that client
T:Invoke("act", '{"userId":"1","action":"walk_to","args":{"path":"Workspace.Map.Station.Interior.Hydrant.Body"}}')
T:Invoke("act", '{"userId":"1","action":"use","args":{"seconds":2,"aim":[9,4,-27]}}')
T:Invoke("events", '{"since":12.5}')                   -- {"now", "events":[{t, kind, data}]}
```

Every call returns JSON `{"ok": bool, "result": any, "error": string?}`. Errors are caught per command
and never throw. Commands: `ping players observe act query inspect set_attr ignite extinguish
teleport config counters events reset round`. `act` actions: `walk_to jump interact equip unequip
use look_at say wait` (`wait` runs on the server; the rest run on the player's client).

- **Players** (`userId`, or `player`): a UserId, a helmet number (`"1"`..`"4"`, falling back to join
  order when helmets aren't assigned), or a name/display name (case-insensitive, prefix ok). With one
  player in the game it can be omitted.
- **Paths** are `GetFullName()` strings (`Workspace.Map.Station.FireTruck67.Reel`, optional `game.`).
- **Client calls** use `InvokeClient` in a separate thread with a timeout (walk: `timeout`+5 s, use:
  `seconds`+5 s, interact 20 s, others 10 s, hud 3 s). This is the one sanctioned `InvokeClient`
  (§6 bans it in gameplay code); it exists only in Studio.
- **walk_to** uses PathfindingService (retrying to a spot beside a solid target), then straight
  `MoveTo` for the rest, jumping when stuck. It reports `done`, `dist` and `pos`.
- **interact** calls `InputHoldBegin` on the prompt, waits `HoldDuration + 0.1`, then
  `InputHoldEnd`. `done` means the prompt's `Triggered` fired. **use** calls `Tool:Activate()`,
  which the server's `Tool.Activated` sees, and fires `Net.Tool.Spray` at 10/s while held if that
  remote exists. **say** shows a bubble (TextChatService `DisplayBubble`, else legacy `Chat:Chat`).
  It's local to that client; `{"chat":true}` also sends to RBXGeneral.
- **Event log** (ring buffer, 500): `player_added/removed`, `character_added`, `player_died`,
  `agent_ready`, `tool_equipped/unequipped/activated/deactivated`, `prompt_triggered`,
  `tag_added/removed` (Burning, Rescuable), `attr` (player/character Water, Carrying, Downed,
  Helmet; Rescuable RescueState; Workspace RoundState, MissionId), `count` (every ForgeTelemetry
  count, seen through `ServerStorage.ForgeCounters` attribute changes), `teleport`, `config`,
  `reset`. Bursts of the same attr/counter within 1 s merge into one entry. `t` uses the same clock
  as `events.now` / `ping.clock`.
- **ignite / extinguish** go through the live `FireService:Ignite` / `:Extinguish` /
  `:ExtinguishAll` when present. Otherwise they fall back to the `Burning` tag + `FireLevel`.
  `{near, radius}` picks the nearest Flammable (or burning) part; `extinguish {"all":true}` clears
  every fire.
- **config** reads a module (`{module}`), or reads/sets a key, through `Config.Set` (live server copy).
  **reset** rebuilds one or all locations via `MapService:RebuildLocation` and clears the log.
  **round** reads RoundState/RoundEndsAt/MissionId; `{state:"Active"|"Results"}` goes through
  MissionService when present, other states set the attribute.
