# mubit-tester: the Mubit-powered game tester for Claude Code

One MCP server, `mubit-tester`, that Claude Code (or a person, through `forge test ...`) uses to
test the Roblox game. It goes beyond the built-in Roblox Studio MCP in three ways:

1. **Every player, not one.** An in-game harness drives *all* players: simulated Studio test clients
   or real friends in a Team Test session. Roblox's MCP can only drive the single local client.
2. **Game-aware.** It knows our tags, attributes, signals and counters, so it can say "the fire in
   House2 went out after 3 s of spraying" rather than "something changed".
3. **AI through Mubit.** Every LLM call (player agents, judge, explorer, fix suggestions) goes through
   Mubit with fixed system prompts. Each role is a Mubit task, and human corrections become
   training data.

## Layers

```
Claude Code ──MCP──▶ mubit-tester (forge/mcp_server.py)
                       ├─ forge/tester/harness.py   talks to ServerStorage.ForgeTest through Studio MCP
                       │                            (execute_luau in the Server datamodel)
                       ├─ forge/tester/ai.py        multi-agent playtests, explore, judge, fix suggestions (Mubit)
                       ├─ forge/tester/scenario.py  scripted scenarios with assertions (no LLM)
                       └─ forge/studio.py           raw Studio MCP: play/stop, console, screenshot, sync
Roblox (Studio only):
  ServerScriptService/ForgeTest.server.luau         command router, event log, server-side queries
  StarterPlayerScripts/ForgeTestAgent.client.luau   per-client actuator (walk, interact, equip, use, aim)
```

## In-game harness contract (Luau)

Active only when `RunService:IsStudio()`. The server creates:
- `ServerStorage.ForgeTest` (BindableFunction): `Invoke(cmd: string, argsJson: string) -> string`
  (JSON). It always returns `{"ok": bool, "result": any, "error": string?}`.
- `ReplicatedStorage.ForgeTestRemote` (RemoteFunction): server → client actuator calls. The client
  agent answers only `ForgeTest` requests and validates the command name.

Commands (args are a JSON object):

| cmd | args | result |
|---|---|---|
| `ping` | `{}` | `{version, players, studio, time}` |
| `players` | `{}` | `[{userId, name, helmet, pos, health, maxHealth, attrs, tool, backpack, carrying, downed}]` |
| `observe` | `{userId, radius?=120, max?=12}` | same shape as play.py's OBSERVE (`me`, `world`, `things`, `prompts`, plus `hud`, `ui` and `panels` fetched from that client by remote) |
| `ui` | `{userId, max?=10}` | `{buttons: [{text, path, gui, x, y, w, h}], panels: [{gui, path, title}], total}`: visible, interactable GuiButtons in PlayerGui (path below PlayerGui, `[n]` for same-named siblings; x/y = center in Studio MCP mouse coordinates) |
| `ui_target` / `ui_effect` | `{userId, path? \| text?}` / `{userId}` | arm a listener on one button and return where to click / after the click: `{fired, changed, effect}` (panels and GUIs opened/closed, buttons new/gone, HUD text new/gone); logs a `ui_press` event |
| `act` | `{userId, action, args}` | `{done, detail}`; actions below |
| `query` | `{tag?, near?: [x,y,z] \| userId, radius?, attrs?: [..], limit?=25}` | `[{path, name, tags, pos, dist, attrs}]` |
| `inspect` | `{path}` | `{class, name, pos, size, attrs, tags, children: [names]}` |
| `set_attr` | `{path, key, value}` | `true` |
| `ignite` | `{path}` (or `{near, radius}` for nearest Flammable) | path set Burning via FireService if present, else tags `Burning` + `FireLevel=1` |
| `extinguish` | `{path}` | as above, reversed |
| `teleport` | `{userId, pos \| path}` | `true` |
| `config` | `{module, key, value?}` | read, or set through `Config.Set` (live tuning) |
| `counters` | `{}` | ForgeTelemetry counters |
| `events` | `{since?: number}` | `{now, events: [{t, kind, data}]}` from a ring buffer (500), see below |
| `reset` | `{location?}` | `MapService:RebuildLocation` or all, plus clearing the event log |
| `round` | `{state?}` | read or force `Workspace.RoundState` via MissionService if present |

Client `act` actions (run on that player's client by the agent):
`walk_to {pos | path, timeout?}` (PathfindingService, falling back to MoveTo; returns arrival
distance), `jump`, `interact {path?}` (nearest enabled ProximityPrompt, or the one on that part:
`InputHoldBegin`, wait HoldDuration + 0.1, `InputHoldEnd`), `equip {name | slot}`, `unequip`,
`use {seconds?, aim?: [x,y,z] | path}` (faces the target, `Tool:Activate()`, holds for `seconds`,
also fires `Net.Tool.Spray` with the aim direction while held if that remote exists), `look_at
{pos | path}`, `say {text}` (bubble chat, for demo readability), `wait {seconds}`.

`press {path | text}` is handled in Python (`Harness.press`), because a LocalScript can't fake a
click and firing the game's remotes would skip the UI under test: `ui_target` → a real
`user_mouse_input` click (instance path, else x/y) in the Studio window that drives that player →
`ui_effect`. Only players with a window can press: the harness's own window and the client
windows it was given (`Harness(studio, client_windows=[...])`), matched by UserId and the
`ForgeTestRemote` `Session` attribute, so another Studio's playtest is never clicked. Other players
get `{done: false, pressable: false}`.

Event log (server): player added/removed/died, tool equipped/activated, ProximityPrompt triggered
(prompt path + player), tag added/removed for `Burning`/`Rescuable`, attribute changes for
`RoundState`, `Water`, `Carrying`, `Downed`, `RescueState`, and every `ForgeTelemetry.count`.

## Python contract

```python
# forge/tester/harness.py
class Harness:                                   # wraps a forge.studio.Studio
    def __init__(self, studio, *, client_windows=None): ...   # client_windows: Client studio ids of a multiplayer test
    async def press(self, user_id, path=None, text=None) -> dict  # real GUI click: {done, fired, changed, effect, detail}
    async def call(self, cmd: str, **args) -> Any        # raises HarnessError on ok=false
    async def ensure_ready(self, timeout=30) -> dict      # play running + ping ok (starts solo play if not playing)
    # thin helpers: players(), observe(user_id), act(user_id, action, **args), query(...), events(since), counters()

# forge/tester/scenario.py
async def run_scenario(harness, scenario: dict) -> dict   # {"name", "steps": [{"act"|"wait_until"|"assert"|"call": ...}]}
    # wait_until/assert: {"cmd": "...", "args": {...}, "path": "result.0.attrs.Water", "op": "<"|">"|"=="|"exists"|"changed", "value": ..., "timeout": s}
    # returns {name, passed, steps: [{n, ok, detail, ms}], events}

# forge/tester/ai.py   (every LLM call through forge.llm via Mubit)
async def multi_playtest(settings, goal: str, players: int | None = None, steps: int = 20, roles: list[str] | None = None, *, llm=None, studio=None) -> dict
    # one `player` agent per connected player, acting concurrently each tick; shared goal plus a per-player role
    # (e.g. "nozzle", "rescuer", "chaos"); judge at the end. Report saved to runs/playtests/<run_id>/report.json
    # (same shape as forge.play reports, plus players: [...] and per-step player ids)
async def explore(settings, minutes: float = 3, players=None, *, llm=None, studio=None) -> dict   # bug hunt: role `explorer`
async def suggest_fix(settings, run_id: str, bug_index: int, *, llm=None) -> dict   # critic+fixer roles → {path, problem, patch_preview}
```

New fixed prompts (Mubit tasks): `forge/prompts/explorer.md`. `player` and `judge` are reused.

## MCP tools (`mubit-tester`)

Session: `status`, `studios`, `play_start`, `play_stop`, `multiplayer_start(players)` (best effort
via StudioTestService, otherwise instructions), `sync`, `preview`.
World: `players`, `observe(player)`, `query`, `inspect`, `counters`, `events(since)`, `errors`
(ForgeProbe), `console`, `screenshot(camera?, look_at?)`.
Control: `act(player, action, args)`, `act_all(action, args)`, `teleport`, `ignite`, `extinguish`,
`set_attr`, `config`, `reset`, `round`.
Testing: `scenario_run(json | name)`, `scenario_list`.
AI (Mubit): `playtest(goal, players?, steps?, roles?)`, `explore(minutes)`, `playtest_correct(run_id,
step, note, player?)`, `suggest_fix(run_id, bug)`, `report(run_id)`, `reports()`.
Players are addressed by name, UserId or helmet number (`"1"`..`"4"`).
