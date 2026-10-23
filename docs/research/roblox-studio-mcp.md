# Roblox Studio MCP, Script Sync, headless testing — research notes (2026-10-23)

Note: intofire proved Edit-mode execute_luau CAN reach a 127.0.0.1 file server via HttpService (that is how forge sync works).

I checked the docs (creator-docs cloned at today's commit 46be165), the DevForum announcements, the old open-source MCP repo, the live tool schemas, and the local StudioMCP binary (Studio 0.744). I could not run any tool against a live Studio: `list_roblox_studios` returned `{"studios":[]}` because the MCP server isn't enabled in an open Studio right now. So anything about runtime behaviour is marked **[I]** (inferred); **[D]** means a primary source states it.

## Bottom line for the agent loop

- **Studio MCP is the only official way to playtest with a player character.** It needs a running Studio GUI with a place open.
- **Script Sync cannot be started from code.** A human links the folders once by right-clicking; after that it resumes automatically. Writing files to disk is the cleanest way for an agent to edit scripts.
- **Open Cloud Luau Execution is truly headless.** It suits unit tests in CI, but it has no players, no physics, and the place's scripts don't run.
- **No official source gives an `execute_luau` timeout, maximum code size, or return format.** Build defensively: wrap results in `HttpService:JSONEncode` and yield with `task.wait()` regularly.

## 1. Studio MCP (built in)

Main doc: https://create.roblox.com/docs/studio/mcp (repo file `content/en-us/studio/mcp.md`).

**Setup [D]**
- In Studio: Assistant → … → Manage MCP Servers → turn on "Enable Studio as MCP server". A green indicator shows how many clients are connected.
- The macOS command is `/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP` with no arguments. On Windows it's `cmd.exe /c %LOCALAPPDATA%\Roblox\mcp.bat`.
- Transport is stdio, and "any client that supports stdio transport" works. A custom Python or TypeScript client is fine.

**Multiple Studios and `studio_id` [D]**
- Since 19 Aug 2026 every tool call requires `studio_id`, and `set_active_studio` was removed.
- `list_roblox_studios` returns the name, instance id and place id (no place id for unsaved local places). Universe ID is planned.
- Source: https://devforum.roblox.com/t/studio-mcp-multi-agent-improvements-and-connected-ai-clients/4820583
- Staff said in that thread: "Play/Testing mode takes over the whole Studio and blocks Edit datamodel tools." Several agents can share one Studio, but only one playtest runs at a time. Crashes under heavy workflows and start/stop failures after the first run are still under investigation.
- Restart your client after Studio auto-updates.

**Auth and permissions**
- [D] The docs only say to connect trusted clients. Approval for script edits can be set per session or per prompt (that setting is in Assistant).
- [I] From strings in the binary: StudioMCP is a proxy ("studio_mcp_proxy 1.0.0") that talks to Studio over `ws://127.0.0.1:<port>`. It uses an `auth.token` file under a `RobloxStudioMCP` folder and creates one if none exists. Your client doesn't handle any credentials.
- [I] The binary references MCP protocol version `2026-07-28` and "input_required" multi-round results. Older SDKs will probably negotiate a lower version and simply not get those results.
- [I] It sends tools-updated notifications, so handle `tools/list_changed` and fetch the tool list again.

**Tool semantics from the live schemas [D, from tool descriptions]**
- **`execute_luau(code, datamodel_type: Edit|Client|Server)`**
  - Runs on Studio's main thread. Until the code yields, Studio is frozen, the script can't be stopped, and the MCP connection may drop.
  - Split heavy work into chunks of about 1,000 items with one `task.wait()` per chunk.
  - Build each chunk outside the DataModel, then parent it. The cost of setting `.Parent` scales with the size of the subtree.
  - Any polling loop must call `task.wait()`.
  - Return value: the docs only say "Returns either the result or an error". No format, timeout or size limit is documented.
  - [I] The old open-source version captured print/warn/error output and returned `[OUTPUT]`, `[WARNING]`, `[ERROR]`, `[RETURNED RESULTS]` and `[UNEXPECTED ERROR]` lines, with tables JSON-encoded and userdata passed through `tostring`. Expect something similar, but return JSON strings yourself.
  - [I] It has plugin-level security: Roblox's own tutorial has the agent call `InstanceFileSyncService:GetStatus` (PluginSecurity) through MCP.
- **Datamodel during play [D]:** "Edit is rejected while playing." Use Client or Server instead. `multi_edit` is Edit-only. `character_navigation` and the keyboard/mouse input tools are Client-only. `get_studio_state` returns the play state and which datamodel types are available.
- **`start_stop_play(is_start: bool)`** starts one solo Play Client session [D, StudioTestService docs]. [I] The old implementation cleared the console buffer on start and waited 1 s on stop.
- **`get_console_output(studio_id)`** "Retrieves output from the Studio output log." No paging or cursor is documented. [I] The old version kept a buffer reset on each play start and capped at about 10,000 characters, so poll often and diff the results.
- **`screen_capture(capture_id, camera_position?[3], look_at_position?[3])`** "Capture current edit-time screen, return the image data." Assistant docs say the viewport can be captured in both Edit and Play.
- **`multi_edit(file_path, edits[{old_string,new_string,replace_all?}], className?, datamodel_type="Edit")`**
  - Uses dot paths, e.g. `game.ServerScriptService.X`.
  - Edits apply in order and atomically. `old_string` must match exactly.
  - It creates the script if it's missing (pass `className` and an empty `old_string` for the first edit).
- **Inspection:** `search_game_tree` has default depth 3, max 10, and `head_limit` 200. `inspect_instance` returns up to 20 matches. `script_grep` caps at 50 matches and `script_search` at 10.
- **Keyboard/mouse input:** actions run in order, `wait_time_ms` is 0–10,000, and you can target UI by `instance_path` (e.g. `LocalPlayer.PlayerGui.X`).
- **`character_navigation`:** `speed_multiplier` 0.1–10. It pathfinds and bypasses input.
- **Generation tools** (`generate_mesh`, `generate_procedural_model`, `generate_material`) accept `async: true`, which returns a jobId. `wait_job_finished` waits up to 600 s by default.
- **`http_get`** only reaches allowlisted create.roblox.com docs URLs (`.md` or `llms.txt`).
- **`store_image`** takes local png/jpg up to 5 MB.
- **`subagent`** lists types `explore`, `screen_capture` and `unit_test` in this build. The docs list `explore` and `playtest`.
- **Skills on this build:** rbx-create-skill, rbx-debug, rbx-device-simulator-lua, rbx-docs-search, rbx-perf-profiling, rbx-scene-analysis, rbx-unit-test.

**Limits [D]**
- Playtest agent (beta): 50 turns per test, a daily usage cap, no multiplayer, and possible false passes. Source: https://devforum.roblox.com/t/studio-beta-studio-assistant-mcp-playtest-agent/4566767
- Procedural models: 50 per rolling 24 hours (assistant/guide.md).
- `generate_mesh`: 12–20,000 triangles.

**Multi-client tests [D]:** `StudioTestService` is plugin-only (reference/engine/classes/StudioTestService.yaml).
- `ExecuteMultiplayerTestAsync(n, args)` supports up to 8 simulated clients and one session per Studio.
- Also available: `ExecutePlayModeAsync`, `ExecuteRunModeAsync`, `EndTest(result)` (server only), `AddPlayers`, `GetTestArgs`.
- [I] It should work from Edit-mode `execute_luau` because that has plugin security, but it yields until the test ends. Run it inside `task.spawn` so the call doesn't block.

**Python client sketch [I]:**
```python
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
p = StdioServerParameters(command="/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP")
async with stdio_client(p) as (r, w), ClientSession(r, w) as s:
    await s.initialize()
    studios = await s.call_tool("list_roblox_studios", {})
    sid = ...  # pick by name/placeId
    await s.call_tool("start_stop_play", {"is_start": True, "studio_id": sid})
    await s.call_tool("execute_luau", {"studio_id": sid, "datamodel_type": "Server",
        "code": 'return game:GetService("HttpService"):JSONEncode({players=#game.Players:GetPlayers()})'})
    log = await s.call_tool("get_console_output", {"studio_id": sid})
    img = await s.call_tool("screen_capture", {"studio_id": sid, "capture_id": "ScreenCapture_1"})
```

## 2. Script Sync

Sources: https://create.roblox.com/docs/scripting/sync and `reference/engine/classes/InstanceFileSyncService.yaml`.

**Status:** fully released 17 Jun 2026 (https://devforum.roblox.com/t/full-release-studio-script-sync/4688454). The coding-harness page and the WaveSurvival `SETUP.md` still say to enable it under File → Beta Features. [I] That step may no longer exist.

**File naming [D]:**
| On disk | Becomes in Studio |
|---|---|
| `x.luau` | ModuleScript |
| `x.server.luau` | Script, RunContext=Server |
| `x.client.luau` | Script, RunContext=Client |
| `x.local.luau` | LocalScript |
| `x.legacy.luau` | Script, RunContext=Legacy |
| `x.plugin.luau` | Script, RunContext=Plugin |
| `dir/` | Folder |
| `dir/init.<type>.luau` | Script with children |

The extension can be `.lua` or `.luau` (setting `DefaultScriptSyncFileType`). Note that `MAKING_A_CLAUDE_FILE.md` in the starter zip says `.server.lua`/`.client.lua`, which contradicts its own `SETUP.md` and the docs.

**Setup is manual [D]:** right-click → Sync to… → pick a directory. If you pick a parent folder, subfolders that match service names are linked automatically. Sync resumes on place open.

**Programmatic API [D]:** `InstanceFileSyncService` (PluginSecurity) has only read methods: `GetAllInstances()`, `GetStatus(inst)`, `GetSyncedInstance(absPath)`, and the `StatusChanged` event. Status values are NotSynced, Errored, SyncedAsRoot, SyncedAsDescendant and AncestorErrored. There is no way to start or stop sync from code ([I] no such API exists in the docs or the release post).

**Limitations [D]:**
- Only Script, LocalScript, ModuleScript and Folder are synced. Attributes and tags on scripts are lost.
- No duplicate names or characters the filesystem rejects (e.g. "Day/Night Cycle").
- Limits: 10,000 scripts per root and 128 roots.
- Deleting a root on disk causes errors.
- Conflicts while Studio is closed open a dialog that blocks until someone resolves it. Default: "Do not resume".
- The WaveSurvival troubleshooting section says only ServerScriptService, ReplicatedStorage and StarterPlayerScripts are supported. StarterGui, StarterPack and Workspace need MCP.

## 3. Headless / CI options

| Option | Status | Players or physics? |
|---|---|---|
| Open Cloud Luau Execution `POST /cloud/v2/universes/{u}/places/{p}[/versions/{v}]/luau-execution-session-tasks` [D, openapi.json] | GA in the spec, needs a published place | **No.** No physics, the place's scripts don't run, no players, and DataModel changes aren't saved. |
| Place publishing `POST https://apis.roblox.com/universes/v1/{u}/places/{p}/versions?versionType=Saved\|Published` with the file body and `x-api-key` (scope `universe-places:write`) [D] | GA | n/a. Can't publish EditableImage/EditableMesh/PartOperation/SurfaceAppearance/BaseWrap. |
| run-in-roblox (rojo-rbx) | Community tool; opens the Studio GUI | [I] Studio edit context only, no players |
| Lune `@lune/roblox` | Community; reads and writes rbxl/rbxm with an Instance API | No runtime, physics or script execution |
| Jest-Lua (jsdotlua, forked from Roblox) / TestEZ | "Can currently only run inside of Roblox" | Runs inside Luau Execution or Studio |
| rbx-unit-test skill [D, assistant/skills.md] | Detects Jest-Lua or TestEZ, with a built-in fallback harness; tests run in Play | Inside Studio |

**Luau Execution details [D]:**
- Scopes: `universe.place.luau-execution-session:write`/`:read`.
- Rate limits: create 5/min per key owner, get 200/min, logs 45/min.
- At most 10 incomplete tasks per place, otherwise HTTP 429. The `place-ci-cd-demo` README says 2 per universe; the openapi says 10 per place.
- Script up to 4 MB. `timeout` defaults to 5 min, which is also the maximum.
- Return values come back as JSON in `output.results`, up to 4 MB. Instances come back as null.
- Logs keep 450 KB. Task info is kept 24 h.
- `state` is QUEUED, PROCESSING, COMPLETE, FAILED or CANCELLED. `error.code` is SCRIPT_ERROR, DEADLINE_EXCEEDED, OUTPUT_SIZE_LIMIT_EXCEEDED or INTERNAL_ERROR.
- Binary input up to 100 MiB (arrives as `({...})[1].BinaryInput`). Binary output up to 256 MiB.
- Reference pipeline: https://github.com/Roblox/place-ci-cd-demo (Rojo build, upload, then execute). Announcement: https://devforum.roblox.com/t/beta-open-cloud-engine-api-for-executing-luau/3172185

**Playtests with players:** only Studio does this, via MCP `start_stop_play`, StudioTestService multi-client tests, or the playtest subagent. Nothing headless supports players.

## 4. Roblox's guidance for AI agents

**WaveSurvival starter** (`assets/solutions/WaveSurvival.zip`, linked from https://create.roblox.com/docs/ai/coding-harness). I read the zip already in your scratchpad, because the folder in the repo clone was empty. It contains SETUP.md, WAVE_SURVIVAL.md, MAKING_A_CLAUDE_FILE.md and folders for ServerScriptService, ReplicatedStorage and StarterPlayerScripts.

- **Recommended CLAUDE.md contents:**
  - which folders sync and which areas need MCP;
  - file-extension rules;
  - "Bias to action… Make the change, run a Play test, read the console, move on. Never ask the user to press Play — drive it yourself via MCP. No warmup steps";
  - strict typing, RemoteEvents instead of `_G`, minimal comments.
- **ARCHITECTURE.md as the map of what exists:** "Read it instead of querying Studio. Update it in the same turn whenever anything is added, moved, or deleted."
- **Loop:**
  1. Plan small phases that can each be tested on their own.
  2. Implement one phase.
  3. "Use MCP to start a play test and check the output console for errors".
  4. Commit to git.
  5. When stuck: "Read through all the scripts involved and explain step by step… identify where it's going wrong."
- **Cheap checks first:** most troubleshooting entries are existence checks (Tool in StarterPack, ScreenGui in StarterGui, `require` paths, the `.server.luau` suffix). Run these via MCP before reaching for vision.

**Assistant [D]** (assistant/guide.md, ai/build-with-assistant.md):
- Planning Mode (`/plan`) creates an editable Markdown plan that only runs when the user clicks Build.
- "Continue" handles hitting the maximum output length.
- BYOK supports Anthropic, OpenAI and Gemini.
- Skills are Markdown with `name`/`description`/`enabled` frontmatter; the `rbx-` prefix is reserved.

**Generation [D]:**
- Cube is the model behind `GenerationService:GenerateModelAsync(inputs, schema)`. Predefined schemas are `Car5` and `Body1`, or you can pass a custom `SchemaDefinition`. `GenerateMeshAsync` is rate-limited per minute.
- `ProceduralModel` uses a generator ModuleScript with `OnGenerate(params, container)` and is driven by attributes (parts/procedural-models.md).

## 5. Limits that matter for the loop

- **`execute_luau`:** no documented timeout or source-size limit [D: absent]. Blocking the main thread can drop the connection [D]. [I] Keep each call short, return JSON-encoded strings, and add your own client-side timeout.
- **Play transitions:** Edit tools are blocked during play [D], so the flow is stop → edit (or write files) → start. [I] Avoid relying on Script Sync file writes landing during play. Call `get_studio_state` before choosing a datamodel. Retry start/stop, because staff confirmed failures after the first run.
- **HttpService [D]:** must be enabled (`HttpService.HttpEnabled = true`). Limits are 500 external requests/min and 2,500 Open Cloud requests/min. The docs say only *plugins* may call `localhost`/`127.0.0.1` (cloud-services/http-service.md). [I] Game scripts in Play probably can't reach your localhost loop, but Edit-mode `execute_luau` probably can.
- **Generation quotas:** procedural models 50 per 24 h. The playtest agent has a daily cap and 50 turns per test.
- **Old open-source server** (https://github.com/Roblox/studio-rust-mcp-server): no longer developed. Its `run_script_in_play_mode` (timeout default 100 s, structured `{success,value,error,logs,errors,duration,isTimeout}`) is not in the built-in tool set. Rebuild that behaviour yourself from `start_stop_play`, Server-side `execute_luau` and `get_console_output`.

**Other sources:**
- Built-in MCP launch, 5 Mar 2026: https://devforum.roblox.com/t/assistant-updates-studio-built-in-mcp-server-and-playtest-automation/4474643
- External LLM support, 21 Feb 2026: https://devforum.roblox.com/t/studio-mcp-server-updates-and-external-llm-support-for-assistant/4415631
- Lune API status: https://lune-org.github.io/docs/roblox/4-api-status
- Jest-Lua: https://github.com/jsdotlua/jest-lua
- run-in-roblox: https://github.com/rojo-rbx/run-in-roblox

**Local files** (I wrote nothing in the repo):
- Docs clone: `/private/tmp/claude-501/-Users-arvin-orca-mubithack/9f166624-9a81-4d4e-ad65-0200f1e52a40/scratchpad/creator-docs`
- Old MCP server clone: `/private/tmp/claude-501/-Users-arvin-orca-mubithack/9f166624-9a81-4d4e-ad65-0200f1e52a40/scratchpad/studio-rust-mcp-server`
- Unzipped starter: `/private/tmp/claude-501/-Users-arvin-orca-mubithack/9f166624-9a81-4d4e-ad65-0200f1e52a40/scratchpad/ws/WaveSurvival`