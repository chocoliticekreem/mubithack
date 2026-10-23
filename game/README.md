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
