# Nilo (nilo.io / play.nilo.io) teardown

Captured 2026-10-24. Public evidence only: landing, /about, /pricing, /llms.txt, the Featurebase changelog (public `__NEXT_DATA__`), and the play.nilo.io SPA bundles served without login (entry `index-C6_FKjeY.js`, 12 MB, plus 18 lazy chunks). Nothing was called that needs auth.
Raw files: `teardowns/nilo/` (`index.txt`, `pages/*`, `js/*.js`).

Tags: **[O]** Observed (file + snippet) · **[I]** Inferred · **[W]** From web (URL).

## Summary

Nilo is **not a Studio agent**. It is a browser-native, multiplayer 3D creation engine of its own (three.js) with a strong AI asset pipeline: text, sketch or image to 3D, auto-rig, text or video to animation, asset packs, Roblox avatar and UGC. Roblox is its export target: .fbx, .glb, .stl or .rbxmx, or a push into a Roblox place through the user's own Open Cloud key. On top sits a **World Agent** with about 59 tools. It builds playable worlds inside Nilo using TypeScript "Behaviors" and a "Brain" node graph. It keeps a shared, versioned **Game Design Document**, reads **playtest logs**, loads **skills**, and calls **`report_frustration`** to log user anger for the team. It has 100k+ creators, 300k+ models, a $4M seed led by Supercell plus a16z speedrun, and a team of 20+ from Epic, Fortnite, UE5 and Fable.

Its main difference from Forge: Nilo owns the runtime and the art pipeline. Forge owns Roblox gameplay code and testing. Nilo does not write Luau for Studio and has no swarm testers. Forge has no 3D asset generation.

## Stack

- **[O]** Marketing site on Next.js (`/_next/static/...` in `index.html`). The app is a Vite SPA at play.nilo.io (`assets/index-*.js`, comment: "advertisingPixelsEntry in vite.config.js").
- **[O]** three.js renderer (`three-DMdaKZZZ.js`), a Monaco code editor, and rrweb session recording (`rrweb-Cs2gEXW5.js`). Sentry release `v0.38.0` and PostHog chunk ids appear in every chunk.
- **[O]** Firebase/Firestore. `ReplayArchitectViewer` queries the `ReplaySessions` collection and storage paths `replaySystem/users/${uid}/replay-sessions/${id}/frames/...`. GDD versions sit in collections `gameDesignDocument` / `gameDesignDocumentVersions`.
- **[O]** Realtime collaboration runs on Liveblocks and Yjs: 77 `liveblocks` refs, "The liveblocks room id" schema, and the GDD editor binds Monaco to a Yjs awareness provider (`GameDesignDocumentEditor-*.js`). Game servers are dedicated, chosen by region (`preferredRegion`, `serverUrl`, `region` schema with a `"local"` option).
- **[O]** 3D providers enum: `Tripo, Meshy, Fal-Trellis, Uthana, Datameister, Fal-Rodin`. Model ids: `tripo_p2, tripo3_1, meshy7_1, meshy_t2, trellis2…`. Animation sources: `Mixamo, Uthana, Cartwheel, Datameister`. Skeletons: `Humanoid, Quadruped, R15, Custom`.
- **[O]** LLM picker for the agent: `claude-opus-5-5`, `claude-sonnet-5-5`, `GPT-6 Astra`, `gpt-6.1-sol`, `gemini-4-argon`, `gemini-3.8-flash`… (`EVi` array in index bundle). The changelog adds Gemini 3.5 for code generation (2026-06-11), GPT Image 2.5 Flare as the default image model, and Nano Banana Lite.
- **[O]** Internal admin pages ship in the public bundle, lazily loaded: `LLMCompletions`, `WorldAgentFrustrationReportsPage`, `WorldAgentAnalytics`, `ReplaySessionsViewer`, `IdeaForgeDoodlePromptTester`, `LowPolyLab`, `PuppetBuilder`, `ModerationChecks`, `Ledger`. Every LLM call is logged with `source ∈ {behavior, code, primitives, world-agent, compaction}`, provider, model, prompt preview and completion preview (`LLMCompletions-*.js`).

## Pipeline into the game

- **[O]** The asset path is export only. FAQ: "Is Nilo a Roblox plugin? No… export directly to Roblox Studio. No plugin needed." Export formats are .fbx/.glb/.stl, plus RBXMX for Roblox characters with attachments and animations (schema `outputFormat: "rbxmx"`, `socketAttachments`, `animations`; errors `mesh_unavailable | mesh_unresolved | texture_missing`).
- **[O]** Direct push to a Roblox place uses Open Cloud. The setup wizard asks for Roblox OAuth (`apis.roblox.com/oauth/v1/authorize`), then an API key with "read and write access to 'assets' and 'luau-execution-sessions'", then a Place ID (index bundle, `roblox-open-cloud-api-key`). Changelog 2026-08-10: "export your creations straight to your Roblox experience using your own API key."
- **[I]** The key scopes suggest the push uploads the mesh as an asset, then runs a **Luau Execution Session** on the place to insert it. That is server-side placement with no plugin. Forge could copy this to deploy headlessly.
- **[O]** The gameplay path stays inside Nilo. Worlds run in Nilo's own engine (modes `creator | sandbox | playtest | game`) and are published to the Nilo community. Behaviors are TypeScript, not Luau.

## Agent loop & self-testing

World Agent tool list, extracted from the `{name, executionSide, description}` table in `js/index-C6_FKjeY.js`, 59 capability names under `id:"world"`. Highlights:

- **[O] Clarify with `ask_question`.** "Ask one blocking design question and wait for the user's answer. Provide one to three concise suggested answers… Use this instead of asking clarification in assistant prose."
- **[O] GDD as shared memory: `read_game_design_document` / `edit_game_design_document`.** "the short markdown record of intended design shared by every chat and collaborator. The current text is already in your instructions." Edits come as `patch` (exact oldText snippets), `replace` ("only for a first draft"), or `restore` a version. Each edit carries a `summary` "shown to users in version history". Authors are tagged `user` or `agent` (with `streamId`, `toolCallId`). Limits: 40,000 chars, 50 versions per batch.
- **[O] Read before you act.** `read_world_state` reads in two steps ("find, then inspect"). `read_entity_brain` reads behavior graphs. `get_scripting_api_reference` must be called "before writing behavior source". The code-gen prompt embeds the API typings: the regex `User request:\n…\n\nScripting API d.ts:` in `LLMCompletions-*.js`.
- **[O] Line-hash edits.** `read_world_behavior_source` returns "lines tagged N:hh|content… copy N:hh anchors into edit_world_behavior_source". These are hash-anchored edits that cannot hit the wrong line.
- **[O] Arbitrary procedures.** `execute_world_procedure` will "Compile and execute one synchronous no-import TypeScript function against the current World and UserEntity APIs" (gated by `procedureToolCallsEnabled`). `create_game_rules` makes invisible rule entities (PlayerSpawner, match phases, scoring) with `replacedByProcedure: true`.
- **[O] Playtest logs.** `list_playtest_sessions` / `read_playtest_logs` (server side): "entries grouped by kind, level, message, phase, behavior, behaviorInstanceId, assetId", with `includesYou` and an incremental `readThrough`/`since` cursor. Playtests are human-run sessions; the agent reads their logs afterwards.
- **[O] Skills.** `load_skill` loads guidance by name. It must be called alone or with reads: "mutation, authoring, and question calls issued in the same turn are rejected… then plan the affected work in your next turn." Skills referenced: "game-design-document skill template", "the low-poly skill, section 'Objects with moving parts'".
- **[O] Context compaction plus `recover_entries`.** Compaction is a logged LLM source. `recover_entries` re-reads full transcript entries by number when only a summary remains.
- **[O] Undo.** `undo_world_action` / `redo_world_action`: "Prefer this over recreating an entity after an accidental mutation." Every mutating tool is "one undoable transaction". Tools carry `batchGroup` (authoring, question, report, skill_load), and the runner bars mixing groups.
- **[O] Frustration telemetry: `report_frustration`.** "Record user frustration for the Nilo team to learn from… one entry per distinct grievance in the latest user message", with severity "low: annoyed but carrying on; medium: clearly frustrated, complaining or repeating a request; high: angry, swearing, or giving up." It is on by default (`frustrationReportsEnabled: default(true)`), and an internal `WorldAgentFrustrationReportsPage` links each report back to its transcript (`worldAgentTranscriptAnchor`).
- **[O] Asset critic loop.** `generate_low_poly_model` works "through a sandboxed Three.js builder with vision critique". It uses three prompts: "You are a low-poly 3D art director planning a build for a junior modeller. Output a node plan…" → "You are a low-poly 3D model builder. Convert the user's description into ONE self-contained JavaScript ES module… export default function build({ THREE, BufferGeometryUtils })" → "You are a low-poly 3D art critic reviewing captioned renders of a build from **four fixed cameras** and its measured stats against the description and the design document." The critic must start with an exact pass/fail token, and the triangle budget is enforced ("under 20% for a detailed description means under-built"). `edit_low_poly_model` re-edits the stored builder module: palette and params need no LLM, while parts and flip edit named sub-meshes.
- **[O] Session replay.** rrweb plus canvas frame archives per session (`ReplaySessionsViewer`, `ReplayArchitectViewer` polls the newest N sessions).
- **[I]** There are no automated playtest bots or AI players. Verification is a vision critic for assets plus logs from human playtests. "Fun" is judged by humans in multiplayer worlds.

## Asset generation

- **[O]** Idea Forge (2D concept: text, sketch or image, with style and drop zones) → Make 3D → Workbench. Edit 3D re-prompts the concept and regenerates (2026-06-18).
- **[O]** Polycount control: a LOD slider, with ranges per model (Meshy T2 100–15k, Tripo P2 48–50k, Meshy 7 100–300k). A 4,000-poly preset was added "for Roblox-specific models" (2026-09-10).
- **[O]** Rigging is one click, including creatures (2026-09-24). Animation comes from text, or from "reference video or capture your own with a webcam" (2026-08-27).
- **[O]** Asset packs come "from a single image… Every prop in the pack shares the same style" (about page). Composable Puppets are rigged humanoids built from primitives (`create_puppet`).
- **[O]** Roblox avatar and UGC: clothing textures in Roblox format, separate torso and legs uploads, RBXMX character export with attached accessories (2026-08-10).

## Pricing/community

- **[O]** Starter $0 (1,500 Bits). Builder $14.99 (50% off $29.99, "over 1.5x more usage"). Pro $37.49 (50% off $74.99, "over 4x"). The discount is a milestone promo: "cutting all subscription prices in half until we hit 250,000 models" (changelog 2026-07-16).
- **[O]** The Bits Battery (2026-09-24) replaced the monthly reset: "refills continuously… recharges to full every week". Bonus Bits are the overflow. **[W]** https://nilo.io/blog/introducing-bits-battery says it recharges fully in a week for all tiers and higher tiers get up to 4x capacity.
- **[O]** Nilo Rewards: Bits for referrals, daily login and building. At least 250 Bits for linking Discord (2026-06-18). Many core features cost no Bits, and the image model GPT Image 2.5 Flare is "completely Free".
- **[O]** Community loop: publish worlds in one click, an Explore page (All/Featured/New), custom thumbnails, profiles, favorites, reporting and moderation, and "Made with Nilo" carousels on the landing page. Join a world with a shared link to "build and play with you".
- **[O]** Scale: "More than 100,000 creators have made over 300,000 models" (about page). **[W]** $4M seed led by Supercell, Sept 2025: https://gamesbeat.com/nilo-raises-4-million-for-browser-based-ai-powered-collaborative-3d-game-creation-platform/
- **[O]** Onboarding uses "Missions": a tracked task framework (`MissionsDemo-*.js`). Each task's `activateTracking` subscribes to an editor event, e.g. "Create five blue objects".
- **[W]** An SEO article farm on competitors (nilo.io/articles/hypehype-ai-game-builder-shutdown, /plutusgg-vs-rosebud-ai-3d, /make-roblox-game-without-coding).

## Notable UX

- **[O]** "Make It" router on the home page: one prompt goes "straight to the feature where it's made" (2026-07-02).
- **[O]** Builder Bag: a personal inventory of assets and groups that carries across worlds with "layout, rotation, and names all intact" (2026-07-30).
- **[O]** Runs in the browser on any device, mobile included (several iOS/mobile fixes in the changelog). "No sketchy installs."
- **[O]** Collaboration with live cursors and colors in the GDD editor and world, and smooth authority hand-off "when a player's tab goes inactive" (2026-08-27).
- **[O]** A stats overlay with per-asset file size, so creators see each object's performance cost (2026-10-08).

## Weak spots & user complaints

- **[O]** It does not produce Roblox gameplay. Behaviors are Nilo TypeScript on Nilo's runtime. "We'll be adding more and more features to allow you to create 3D games entirely in Nilo very soon" (FAQ). A Roblox dev still has to script in Studio.
- **[O]** Its changelog repeatedly fixes black or white screens on low-end devices (2026-07-16, 2026-09-24), rigging lean, broken invite links (twice), and RBXMX export failures ("RBMX exporting fails less now").
- **[O]** Pricing opacity: plans state "1.5x / 4x more usage" with no absolute Bits capacity per tier, plus a "special offer" that has run since July.
- **[W]** No independent Reddit or DevForum complaints surfaced. The only sentiment found is Nilo's own survey ("93% would recommend") on nilo.io pages (https://nilo.io/articles/vibe-coding-roblox-performance). Treat public complaint evidence as unknown.
- **[I]** AI meshes on Roblox carry polycount, texture-memory and moderation risk for UGC. The LOD slider shows Nilo knows this.

## How Forge differs

| Axis | Nilo | Forge |
|---|---|---|
| Where the game runs | Nilo's own three.js engine, Nilo servers | Roblox (headless engine + real Studio) |
| Code | TypeScript Behaviors + Brain graph | Luau, prebuilt kit modules |
| Assets | Core strength: mesh, rig, anim, UGC, asset packs | None generated (kits, parts) |
| Agent memory | Shared versioned GDD, skills, compaction | Mubit model updates from corrections |
| Testing | Vision critic on assets; human playtest logs | AI persona swarm, gap finder, autopilot |
| Feedback signal | `report_frustration` from chat tone | Explicit human corrections → Mubit |
| Roblox delivery | Export file or Open Cloud push | Studio plugin + file sync |

## Cherry-picks for Forge

1. **`report_frustration` as an implicit correction channel**
   - What: an agent tool that, on each user message, logs distinct grievances (≤60 words, severity low/medium/high) for the team, without changing anything.
   - Why: Forge's Mubit learning needs corrections, and most users vent instead of typing a formal `forge correct`. This turns venting into labelled training data.
   - Smallest version: a "frustration" Mubit task on build-from-chat messages in the Studio plugin chat. When severity ≥ medium, auto-create a draft `correct` entry tied to the last tool call for a human to confirm.
   - Works without real players: **yes** (the builder is the user).
2. **A versioned Game Design Document as the agent's shared memory**
   - What: a markdown GDD that is always in the system context, edited by patch with a one-line summary per version, authored by `user` or `agent`, and restorable.
   - Why: Forge's critic and gap finder lack a written statement of intent. "Gap" means gap against the GDD, and the AI persona testers can be briefed from it.
   - Smallest version: `runs/<slug>/GDD.md`, written by the architect role and patched by `feature` / `consolidate`. Its version ties to Forge's versions and rollback. Feed the GDD into the user message, not the system prompt, to keep Mubit tasks stable.
   - Works without real players: **yes**.
3. **Planner → builder → critic with fixed cameras plus measured stats**
   - What: the critic sees renders from 4 fixed cameras plus numeric stats (triangles, sizes) and must answer with an exact PASS/FAIL token first. Failure is defined numerically ("under 20% of budget = under-built").
   - Why: Forge's critic can drift. Fixed viewpoints make screenshots comparable across versions, and a first-token verdict is easy to train in Mubit.
   - Smallest version: in Forge's Studio screenshot step, use 4 fixed camera CFrames around the map bounds plus stats (part count, script count, unanchored parts), and require a PASS/FAIL first line.
   - Works without real players: **yes**.
4. **`ask_question` with 1–3 suggested answers, never prose questions**
   - What: blocking clarifications as a tool with clickable answers.
   - Why: answers become structured labels for Mubit, and the autopilot can auto-answer with the default when no human is present.
   - Smallest version: one tool in the architect role, rendered as buttons in the Studio plugin chat. Autopilot picks option 1 after a timeout and logs it.
   - Works without real players: **yes**.
5. **`load_skill` gating: reads only in the same turn, then plan**
   - What: genre or system skills (e.g. "tycoon economy", "round system") loaded on demand, and the runner rejects mutations in the same turn.
   - Why: smaller system prompts. Mubit groups tasks by exact system prompt, so skills belong in the user message, which matches Forge's rule against editing `forge/prompts/*.md`.
   - Smallest version: put skill markdown files in `forge/skills/`. The orchestrator injects them into the user message when a gap names a system.
   - Works without real players: **yes**.
6. **Hash-anchored line edits (`N:hh|content`)**
   - What: reads return line numbers plus a 2-char hash, and edits must cite anchors.
   - Why: they prevent stale or wrong-line patches when the fixer edits files that changed under it, for example after autopilot or human edits.
   - Smallest version: in `forge fix`, have the read_file tool emit `N:hh|`, and validate anchors before applying.
   - Works without real players: **yes**.
7. **Playtest log reads with a `since`/`readThrough` cursor and `includesYou`**
   - What: incremental, grouped log reads per session.
   - Why: Forge's swarm produces lots of logs, and grouped, deduplicated, incremental reads cut critic tokens.
   - Smallest version: group the tester-report log output by (level, message, script) with counts, plus a cursor.
   - Works without real players: **yes**.
8. **Open Cloud push (assets + luau-execution-sessions) for headless deploy**
   - What: BYO Open Cloud key and Place ID, then insert or upload without Studio.
   - Why: Forge's "Studio only for screenshots/UI/final verify" direction could publish to a test place headlessly, and run Luau smoke checks on the real place through Luau Execution.
   - Smallest version: a `forge deploy --place <id>` that uploads `place/Forge.rbxlx` through the Open Cloud Place Publishing API, then runs one luau-execution smoke script. The key comes from the env, never logged.
   - Works without real players: **yes**.
9. **Onboarding Missions with tracked events**
   - What: tasks that complete when an editor event fires.
   - Why: the same pattern can verify that a game's tutorial actually works, by having AI testers complete missions.
   - Smallest version: have the kit's tutorial module emit events and have the swarm assert mission completion.
   - Works without real players: **yes**.
