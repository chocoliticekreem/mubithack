# RoCode (rocode.app) teardown

Captured 2026-10-24. Public evidence only: landing page, /docs, /changelog, /llms.txt, /info, compare pages, the chat page's public JS (served without login), the Creator Store listing (economy API, public). The plugin .rbxm needs a Roblox login (`assetdelivery` returned 401), so its Lua was **not** read.
Raw files: `teardowns/rocode/` (`index.txt`, `pages/*.txt`, `js/*.js`).

Tags: **[O]** Observed (file + snippet) · **[I]** Inferred · **[W]** From web (URL).

## Summary

RoCode is a web chat plus a Creator Store Studio plugin. Its agent edits the place you have open in Studio through 27 plugin tools. It says it has 46,000 accounts, 34k opening prompts and 25k applied runs. Its quality loop is shallow but tightly enforced. Each script is compile-checked in Studio. A playtest of up to 30 seconds reads server and client errors. A "test character" robot walks, clicks and presses keys, then reports PASS/FAIL. A vision "look check" screenshots the build from 2 corners and reviews it. Relay-side completion gates stop the model from finishing early. It ships premium UI kits, themed islands, a curated model library and 12 part-built prefabs. It runs no model of its own: everything goes through OpenRouter, from DeepSeek V4 Flash (free) up to Claude Opus 5.5 and GPT-6 Astra. Growth runs on SEO: 14+ "RoCode vs X" pages, guides, free tools, an affiliate program and a Discord gate on the free tier.

Its main difference from Forge: RoCode is a **single-feature-per-prompt editor for a place the user already has**. It has no players, no swarm, no autopilot, no versions beyond Studio Ctrl+Z, no learning loop, and it states outright that it "cannot tell whether the game is fun."

## Stack

- **[O]** Static site plus vanilla JS. `js/app.js` is 920 KB of unminified code. Its first line is `// i wrote this file with the machine half packed.` It looks like a solo or very small team.
- **[O]** Supabase for auth and DB. `index.html` loads `@supabase/supabase-js@2.117.2`. The `/api/public-config` response has the keys `supabaseUrl, supabaseAnonKey, stripePublishableKey, relayPublicUrl, quota` (values not recorded).
- **[O]** The agent runs on Railway, and the site's own functions on Vercel. Changelog v3.7.0: "Chat now starts agent jobs on Railway with your session JWT by default, no Vercel `/api/agent-session` hop".
- **[O]** All models go through OpenRouter. Docs: "Every call to the model goes through OpenRouter to a hosting provider… RoCode has no models of its own."
- **[O]** Payments moved from Stripe to Paddle on 2026-09-25 (`pages/llms.txt.raw`). Microsoft Clarity is loaded (`lib/clarity.js`), plus its own telemetry (`lib/rc-telemetry.js`).
- **[O]** Tools are defined once in a manifest. Changelog: "Tool definitions moved to a manifest with auto-generated schemas". The completion logic is shared between browser and relay: `agent-job-completion.js` header reads "Browser UMD + relay CJS are generated from this file".

## Pipeline into the game

1. **[O] Pairing.** The plugin shows a one-time 8-character code, valid 15 minutes, that the user types into the web chat. Since plugin 3.9.13 it auto-connects when Studio is signed in to the same Roblox account (changelog 2026-10-16). Earlier "auto-pair by same network IP" was removed for security (v4.0.1: "someone else's Studio could take your connection").
2. **[O] Transport.** The plugin holds a **WebSocket to `relay.rocode.app`**. Docs: "It keeps a WebSocket connection to the relay, and the relay is the only server it talks to." The user must allow HTTP requests and Script Injection. The plugin creates and removes a temp script in ServerStorage every 30 s to probe the Script Injection permission (landing privacy section).
3. **[O] Job API.** The browser sends `POST ${relayUrl}/agent-job` with `{apiKey, modelChoice, clientOptions, prompt, images, clientRequestId, history:[] , skipUserTurn, conversationId, continueFromCheckpoint?, priorJobId?, recoveryBrief?}` (`js/app.js`, near `fetch(\`${relayUrl}/agent-job\``). Results stream over SSE `/agent-job-result/stream?jobId=` as step deltas. Studio presence comes from `/plugin-state/stream`, and the browser can run `/studio-search?q=` for "/" mentions. Other relay paths seen: `/studio-undo-job`, `/studio-script-injection/check`, `/plugin-connect/approve|deny|pending`, `/plugin-pair/confirm`, `/warm`.
4. **[O] Context sent per run.** Docs: "each run starts with your camera position and up to 8 selected objects, so 'this' can mean your selection." There is no place upload and no background sync. Reads are lazy and trimmed: 4,000 chars per read, 6,000 for checks, 12,000 for script source.
5. **[O] Tools (27).** Names from `js/tools-ui.js`: `create_script, edit_script, read_script, grep_scripts, check_script, check_output, run_playtest, create_instance, set_property, set_attribute, add_tag, remove_tag, clone_instance, delete_instance, group_selection, ungroup_model, pivot_to, place_prefab, build_structure, insert_model, insert_kit, create_ui, list_children, get_descendants, find_first_child, get_properties, inspect_model, manage_selection`. Hidden server-side tools are `complete_task, think, update_checklist` (`agent-job-completion.js`: `HIDDEN_AGENT_TOOL_ACTIONS`).
6. **[O] Edits.** `edit_script` does exact-substring replacement with an `old_string` arg, and has "whitespace/CRLF-tolerant edit_script recovery (unique matches only, with re-read hints)" (changelog v3.8.0). Create and full rewrites prepend a "Generated by RoCode AI" comment.
7. **[O] Undo.** Studio ChangeHistory waypoints are set before and after each batch. Deletes are soft: they go to `ServerStorage.RoCodeTrash`, which keeps the last 30 runs. Deletion is limited to objects RoCode created in this chat, and anything else is refused and asked about. A new "Undo this build" button calls `POST /studio-undo-job` (`js/undo-build.js` header: "Two people asked for an undo button").

## Agent loop & self-testing

- **[O] Compile gate.** "After every Create Script or Edit Script, the agent is told to run Check Script… If a check fails, RoCode can't finish the run until a later check passes. After two tries it can finish" (docs). The check also lints `wait/spawn/delay`, `loadstring`, bad `require`, modules that return nothing, and bad `GetService` names.
- **[O] Relay-synthesized completion.** "After successful Studio mutations without complete_task, the relay synthesizes a one-shot finish" (changelog v3.8.0).
- **[O] Semantic completion gate.** `js/agent-job-completion.js` uses `GAME_WITHOUT_SCRIPTS_NOTE`. When the prompt matches a multilingual "make a game" regex and the run made ≥2 changes but 0 scripts, `complete_task` is rejected with: "Add the core gameplay scripts for this round now (for a shooter: teams and spawns, a gun Tool… for an obby: checkpoints, fall reset, finish; for a tycoon: droppers…), check_script them, playtest, then call complete_task and end with 'Next I can add: ...'". The trigger was a real failure: "'zbuduj mi cs2' (build me CS2) from a ChatGPT visitor" (2026-10-20 comment).
- **[O] Playtest.** `run_playtest` lasts 3–30 s (15 by default). It runs at most twice a run plus once to verify its own fix, never during edits, and only in Build mode (docs "The short playtest").
- **[O] Test character.** "With plugin 3.9.11 or newer, the test character walks, jumps and steps on parts, and with plugin 3.9.15 or newer it also presses keys, clicks on-screen buttons and types. It then checks that things happened, such as damage, values or parts, and reports each check as passed or failed… it cannot tell whether the game is fun." The Creator Store listing: "Test the game with a robot that walks, clicks buttons and presses keys, then reports PASS or FAIL."
- **[O] Look check (vision critic).** Since plugin 3.9.14 (2026-10-19), a Build run screenshots its build in edit mode, at most once per run: "usually two, from opposite corners, plus one of the screen UI". GLM 5.3 Flash reviews them, with DeepSeek V4.1 Flash as backup, and "lists clear problems, such as parts floating or sunk into the ground, gaps or the wrong scale". Screenshots are not stored.
- **[O] Output reading.** `check_output` reads the Server and Client lines of the last playtest even after Stop. Code filters out output that predates the change (`agent-job-completion.js`, `oldByTime`/`playedSinceChange`).
- **[O] Build checklist.** The `update_checklist` tool is "shown as the checklist, never as a step" (2026-10-17).
- **[O] Limits.** Up to 80 model turns or 5 hours per run, 3 concurrent runs, and a queued next prompt. A run pauses after a set credit amount and asks before it goes on.
- **[O] Modes.** Build and Ask. Ask uses only the 10 read tools. A "Plan for complex tasks" mode was **removed** in v3.4.13 (2026-07-26).
- **[O] Outcome labelling.** `js/build-check.js` adds "Did it work?" (Yes/Partly/No) under the last build. Comment: "technical completion is agent_runs.status, verified gameplay is the relay's playtest check (verification_methods 'playtest_run'), and this is user-reported success (product event build_check_answer)."
- **[O] Telemetry.** `agent_llm_turns`, `tool_invocations` (path, turn, recovery, soft-skip, error detail), `finish_reason`, and `check_script` findings tracked separately from transport failures (v3.8.0).
- **[I]** There is no cross-run learning. Prompts and tools are fixed, and corrections do not feed back into a model. The loop is per run.

## Asset generation

- **[O]** No meshes, animations or terrain. `place_prefab` has 12 part-built structures (Wall … Arena, Obstacle course). `build_structure` builds a part list in one call.
- **[O]** `insert_model` (plugin 3.9.14) pulls from "RoCode's own library of hand-picked free Creator Store models… scales each one to the height it needs, and the plugin removes any script inside."
- **[O]** `create_ui` offers 7 layouts (shop, inventory, HUD, dialog, leaderboard, notification, settings) and styles `simulator|blocky|clean|dark|auto`. `auto` "matches the GUIs already in your game".
- **[O]** `insert_kit` gives premium UI kits (2026-10-23): "ten ready-made game screens… HUD with coins and gems… pet inventory, store with game passes and codes, daily rewards, item shop, egg hatching, rebirth, settings, daily quests and a loading screen; five themes (candy, neon, gold, blocky, pastel); animated", each with working server scripts (`pages/llms.txt.raw`).
- **[O]** Themed islands (volcano, desert canyon, jungle, snow) are built "in one call" (alternatives page and Creator Store listing).

## Pricing/community

- **[O]** Starter is free: 1 credit a day (2 on signup day and on Discord-join day) on DeepSeek V4 Flash. "After a few builds, free accounts are asked to join the RoCode Discord to keep getting free credits."
- **[O]** Pro is $9.99 for 150 credits (Sonnet 5.5, GLM 5.3 Flash). Studio is $19.99 for 320 (adds Opus 5.5). Ultra is $29.99 for 500 (adds GPT-6 Astra). Annual billing saves 30%. Packs range from $4.99 for 50 credits to $99.99 for 1,200. BYOK OpenRouter is available on any paid plan. A 14-day full refund applies.
- **[O]** "An advanced task uses about 4 credits: the median of 83 finished tasks on GLM 5.3". Medians: 51 s on Starter, 83 s on paid.
- **[O]** Model fallback: "If a paid model is slow to start, RoCode first tries the same model through another provider… an equal or stronger model can finish the run, and you never pay more."
- **[O] Scale.** `GET /api/user-count` returns `{"count":46000}`. The landing page cites "34,000+ opening prompts" (Dec 2025 to Sep 2026) and "25,000+ runs finished with changes applied" (31 Jul to 29 Sep 2026). The Creator Store listing was created 2026-02-11 and updated 2026-10-24T03:43Z, so plugin releases are near-daily.
- **[O] Prompt mix** (landing): UI/HUD/menus 17.0%, combat 8.1%, movement 7.4%, shops 6.5%, fixing errors 5.3%, sim/tycoon 4.0%, inventories 3.6%, leaderboards 3.5%.
- **[O] Growth.** 14 head-to-head pages, a "23 options compared" page, guides, free tools (Luau playground, idea generator, DevEx calculator), a 20% affiliate program and lifecycle emails (welcome, unpaired, connected-no-build, dormant winback, cancellation rescue; v3.5.0).

## Notable UX

- **[O]** A Found → Changes → Result write-up for every example, and an Explorer diff tagged `new / edited / reused` (landing "Existing projects"), with "What it didn't do: start a second coin system…".
- **[O]** Next-prompt chips: 2–3 one-click follow-ups made from the turn summary (`/api/generate-next-prompts`, v3.6.0).
- **[O]** A completion card with "up to six human lines from tool steps". Every reply shows the credits used, the model that ran, the step count and the time.
- **[O]** Voice input, image attachments (4 per message) and "/" mentions that attach an exact Explorer object.
- **[O]** Continue from checkpoint with a `recoveryBrief`. A run that fails on RoCode's side refunds its credits automatically.

## Weak spots & user complaints

- **[O] Self-admitted:** it "cannot tell whether the game is fun". Its playtests take no runtime screenshots, are 30 s at most, and check "only what the agent chose to test". It has no terrain, meshes or animation, no publishing, and no game passes or dev products. It "builds a finished, balanced game from one sentence" is listed under "Not today".
- **[O]** Its own regex history shows false positives: "five of nine live rejections were edits of existing games" (`agent-job-completion.js`, 2026-10-21).
- **[O]** Reliability history: v3.9.2 "Every Pro job was failing after the Sep 6 model switch". Repeated pricing churn: 4 price changes between 2026-09-20 and 2026-10-17, plus the free tier cut from 3 to 2 to 1 credit a day.
- **[O]** Only one Studio window connects at a time. Brave, VPN and iCloud Private Relay break pairing, and phones are not supported.
- **[W]** No independent Reddit or DevForum reviews surfaced in searches (the DevForum search returned unrelated RoStudio/RoAgent/RobloxAIBuilder posts: https://devforum.roblox.com/t/free-roagent-ai-roblox-studio-agent-claude-codex/4768194). Public complaint evidence is thin, so treat this as unknown, not as "no complaints".

## How Forge differs

| Axis | RoCode | Forge |
|---|---|---|
| Unit of work | One feature per prompt in a place the user already has | Idea → whole game → critic → fix loop, autopilot |
| Testing | 1 robot, ≤30 s, ≤3 playtests a run, PASS/FAIL checks the agent picks | Headless engine plus real Studio, 10 persona swarm testers, gap finder |
| Learning | None: fixed prompts, OpenRouter models | Every call through Mubit; corrections become model updates |
| Versioning | Studio Ctrl+Z per batch, RoCodeTrash, undo last build | Versions plus rollback, bisect |
| Content | UI kits, islands, curated model library, 12 prefabs | Prebuilt kit modules, battle pass, cosmetics, monetisation |
| Vision | 2-corner edit-mode look check | Studio screenshots for UI and final verify |
| Distribution | Creator Store plugin + web chat, SEO machine, 46k accounts | No public users yet |

**[O] Name collision.** RoCode already runs a "RoCode vs Forge" page about **ForgeBlox** (forgeblox.app, a Windows Bridge on Studio MCP, "renamed ForgeBlox in October 2026"). Searches for "Forge Roblox AI" will hit that product, so pick our public naming with this in mind.

## Cherry-picks for Forge

1. **Semantic completion gates on the critic**
   - What: the relay rejects `complete_task` when the prompt asked for a game but the run wrote no scripts, and sends back a genre-specific checklist (shooter, obby, tycoon).
   - Why: this is cheap, deterministic and catches the worst failure ("nothing happens when they press Play"). RoCode built it from a live failure.
   - Smallest version: in Forge's done/readiness bar, add rules from the run diff, e.g. "genre=tycoon AND no dropper/collector script → not done". Return the RoCode-style note to the fixer as the next instruction.
   - Works without real players: **yes**.
2. **Vision look check in edit mode**
   - What: after a build, take 2 screenshots from opposite corners (plus one of the UI). A cheap vision model lists only "clear problems" (floating or sunk parts, gaps, scale) and the agent fixes the real ones. Run it once per run, restore camera and selection, store nothing.
   - Why: it catches spatial bugs that logs and swarm testers never report.
   - Smallest version: one `screen_capture` per corner through the Studio bridge, then a Mubit task "look-critic" with a fixed system prompt and the output fed into the existing gap list. Mubit training then learns which look issues humans accept or reject.
   - Works without real players: **yes**.
3. **"Did it work?" (Yes/Partly/No) as a separate outcome channel**
   - What: three outcome labels kept apart: technical completion, verified-by-playtest, and user-reported.
   - Why: Forge's Mubit training needs labels. A one-click "Partly" on a build is a cheap correction signal, and it separates "the model said done" from "it works".
   - Smallest version: add the three buttons to the Studio plugin's build-from-chat panel and log them as Mubit feedback on that run's calls.
   - Works without real players: **yes** (the builder is the user).
4. **Test-character PASS/FAIL assertions written by the agent**
   - What: the agent writes explicit checks ("damage happened", "value changed", "part exists") that the test robot verifies.
   - Why: Forge's swarm explores, and per-feature asserted checks make regressions bisectable.
   - Smallest version: have the feature builder emit 2–4 assertions in the existing mubit-tester `test_feature` scenario format alongside the code, and gate done on them.
   - Works without real players: **yes**.
5. **Next-prompt chips plus an "end with 'Next I can add: …'" convention**
   - What: 2–3 follow-ups generated from the turn summary.
   - Why: they keep a human in the loop, and each click is a labelled preference for the gap finder.
   - Smallest version: have the gap finder output its top 3 gaps as clickable chips in the plugin panel.
   - Works without real players: **yes**.
6. **Soft delete to a trash folder plus "undo this build"**
   - What: deletes move to `ServerStorage.ForgeTrash` instead of `Destroy`, with one-click undo of the last build through ChangeHistory.
   - Why: it is cheap safety for agent edits in a user's real place.
   - Smallest version: wrap delete in the plugin so it reparents to the trash folder, with a cap of N runs.
   - Works without real players: **yes**.
7. **Premium UI kits as one tool call** (`insert_kit`)
   - What: themed, animated screens wired to server scripts: HUD, pet inventory, egg hatch, rebirth, daily rewards, quests.
   - Why: UI is 17% of RoCode's prompts, the largest category. Forge already has battle pass and cosmetics kits, and the gap is theming.
   - Smallest version: add a `theme` param to the existing kit modules and expose "insert kit X with theme Y" as one Forge tool.
   - Works without real players: **yes**.
8. **Lazy, trimmed reads instead of place upload**
   - What: per-read char caps (4k/6k/12k) and "/"-mention to attach exact objects.
   - Why: it keeps token cost predictable on big places.
   - Smallest version: apply the same caps to Forge's Studio bridge reads.
   - Works without real players: **yes**.
