# Rosebud AI (rosebud.ai) teardown

Date: 2026-10-24. Method: public HTML and JS only, fetched with curl (no login, no POSTs). Evidence is in
`teardowns/rosebud/` (`*.html`, `js/*.js` with 70 Next.js/Turbopack chunks, `canvas/*.js` with 5 preview-runtime scripts).
Tags: **[O]** Observed (file + snippet), **[I]** Inferred, **[W]** From web (URL).

## Summary
Rosebud is a browser game builder. You chat with "Rosie", and an agentic coding model writes JavaScript games
(Phaser, Three.js, Babylon, voxel/noa, React, multi-file). The game runs live in an iframe on a sandbox subdomain.
Generation is asynchronous: send a message, poll the chat status every 2 s, and get back a git-like **commit**
holding a **revision** of the files. The most interesting part is the **server-requested runtime check**. In the
middle of a turn the backend agent asks the user's browser to load a given revision, collect console output for N ms,
optionally take a screenshot, and POST the result back. The agent tests its own code in the user's browser.
Around that core sit asset generators (sprites, sprite animations, sound, music, 360° skyboxes including a Roblox
exporter, 3D), a public feed with likes, comments, remix ("clone") and creator tips, X/Discord playables, Windows/Steam
export, and a CLI plus agent-publishing flow for Claude Code and Codex users.

## Stack
- Next.js App Router with Turbopack chunks on rosebud.ai, Sentry, Hotjar, TikTok/Meta pixels. **[O]** `rosebud.ai.html`, `2w6rbchy6hcy8.js` (`@sentry/nextjs`).
- REST API on Google Cloud Run: `playground-gateway-v2-…-uc.a.run.app`, axios with `baseURL` set to that host. Django-style trailing-slash routes. **[O]** `3so7496t7v5q5.js`: `t.f.create({baseURL:"https://playground-gateway-v2-snduoq54tq-uc.a.run.app"…`
- Feature flags: self-hosted Flipt on Cloud Run (`flipt-v2-…/evaluate/v1/boolean`). **[O]** `173x3fzl2kd_f.js`.
- Auth: Firebase Identity Toolkit (`/v1/accounts:signInWithIdp` and others), then the backend's own JWT pair stored as `rosebud_auth_token` (`/api/token/sign-in/`, `/api/token/refresh/`). Anonymous sign-in exists (`/api/token/sign-in-anonymous/`). **[O]** `1pfdwyzgqx4sk.js`, `3so7496t7v5q5.js`.
- LLM observability: Langfuse (us.cloud.langfuse.com), whose public key ships in the client. I did not record the value. **[O]** `2n5c6dujk98v6.js` (`baseUrl:"https://us.cloud.langfuse.com"`).
- Engine CDN: `canvas.play.rosebud.ai/canvas/scripts/{phaser/phaser.min.js, three-js/three.module.js, three-js/cannon.min.js, three-js/jsm/}`. **[O]** grep across chunks.

## Generation pipeline
**Request.** `POST /api/chats/{chatId}/send_message/` with body **[O]** `2n5c6dujk98v6.js@~294800`:
```
{ message_type: "USER_CHAT_MESSAGE", model_name, content,
  image_data?, image_data_list?, dimension_preference?, platform_preference?, multiplayer_preference?,
  console_entries?: [{level, kind, message, source, line_number, column_number, stack, error_name,
                      full_error, count, first_seen_at, last_seen_at}],
  direction_suggestion_id?, my_asset_references? }
```
- The "Setup" panel sets three preferences before a build: Dimension, Platform, and Single-player/Multiplayer. **[O]** `173x3fzl2kd_f.js@169688` (Zustand stores), plus the setup radiogroup `["Single-player","Multiplayer"]`.
- "Attach to prompt" toggles whether the preview's deduplicated console entries ride along with the message. **[O]** string `"Attach to prompt"`; `isAttachToPromptEnabled(m.id)` in `2n5c6dujk98v6.js`.
- Message types on the wire: `LEGACY, USER_CHAT_MESSAGE, ASSISTANT_CHAT_MESSAGE, INTENT_ASSIGNMENT, CODE_GENERATION_MESSAGE, MULTIFILE_CODE_GENERATION_MESSAGE, TOOL_CALL_MESSAGE, ENGAGEMENT_QUESTIONS`. Tool calls move through `streaming → complete → executing → executed | error`. Chat modes are `ASSET | CHAT | EDIT`, and agent modes are `STANDARD | TOOL_CALLING`. **[O]** `3so7496t7v5q5.js@64840`.
- Optimistic UI: the client inserts a fake commit with a USER message and an empty TOOL_CALL message, then swaps it for the server's commit. **[O]** `2n5c6dujk98v6.js@~295000`.

**Job model: polling, not streaming.** **[O]** `2n5c6dujk98v6.js@278334`:
- `GET /api/chats/{id}/status/` through react-query `refetchInterval`, default `pollingIntervalMs = 2000`. After 10 minutes (`6e5` ms) it backs off to `max(interval, 10000)`. `refetchIntervalInBackground: true`, `retry: 3`.
- Statuses: `pending | processing | compacting | completed | failed | cancelled | idle`. `compacting` drives the "history compaction" message, so they summarise long chats server-side. **[O]**
- On completion the response carries `operation.commit_id`, `active_revision_id` and `working_revision_id`. The client invalidates commits, credit entitlements and subscriptions. **[O]**
- Cancel: `POST /api/chats/{id}/cancel/`. Only one turn runs per user. If you send from a second tab you get "Rosie's busy crafting! She's already working on something in another tab". **[O]**
- No EventSource or WebSocket in the app code. The only `text/event-stream` hit is Sentry's list of instrumented content types. **[O]**

**Server-requested runtime check (the self-test loop).** **[O]** `2n5c6dujk98v6.js@~289600`:
- The status payload can include `pending_runtime_check` with `request_payload: {collect_ms (clamped 500–8000, default 2500), max_events (1–100, default 40), include_screenshot, preview_revision_id, content_hash, restart_preview}` plus `timeout_seconds`.
- The client loads that revision into the preview (or a shadow preview), waits until `lastLoad` matches `{projectId, revisionId, contentHash}` with a timeout of at most 8 s, sleeps `collect_ms`, and optionally screenshots the canvas.
- It then calls `POST /api/chats/{chatId}/runtime-checks/{checkId}/complete/` with `{result: {entries, collectedMs, maxEvents, screenshot, preview_reloaded, loaded_content_hash, status?, message?}}`.
- Guard rails: if the preview did not load before the deadline the status is `client_error`, and if the preview changed during collection the result is marked stale. Each check ID is processed only once.

**Preview.** **[O]** `canvas/ScriptsLoader.js`:
- The iframe page is `/canvas/{phaser|threejs|babylon|noa|react|esm-react|phaser_webkit}` on `canvas.play.rosebud.ai`, which preloads the engine.
- The parent sends `postMessage({action:'update', content: <game JS>})`. The loader checks the origin is `*.rosebud.ai` or localhost:5170, waits for React hydration, wraps the script in a **Blob URL** inside a `<script>` tag (not srcdoc), and replaces the previous `#game-script`. Only the latest queued update runs.
- Iframe to parent messages: `codeError` (window.onerror with message, source, line, column, stack), `runtimeConsole`, `scriptsLoaded`, `logProgress`, `requestLLM`, `ogpSubmitPoints`, `localStorageChanged`, `canvasScreenshotResponse`. **[O]** `3ny6l5a12u_xn.js@13955`.
- Error-storm guard: more than 10 `codeError` events within 1 s sets a flag. **[O]** `3ny6l5a12u_xn.js@18569` (`eo.current>10&&ec(!0)`).
- `CanvasCapture.js` records the canvas as PNG (`toDataURL`) or as 30 fps / 2.5 Mbps WebM via MediaRecorder for share clips. **[O]**

**Versioning.** `/api/commits/`, `/api/revisions/{id}/`, `/api/revisions/{id}/copy/`, `/api/projects/{id}/set_current_revision/`, `publish_revision/`, `deploy_revision/`, `/api/commits/bulk_delete/`. History preview is an `isPreviewingHistory` mode. **[O]** `3so7496t7v5q5.js`, `1pfdwyzgqx4sk.js`.

## Artifact and engine
- Templates enum: `Phaser, Babylon, Voxel, ThreeJS, React, Multifile, Universal`. **[O]** `3so7496t7v5q5.js@64840`.
- Files are stored per revision (`/api/files/bulk_create/`, `bulk_update/`). The asset reference mode is `legacy_lookup` or `path_v2` (manifest plus `preview_asset_base_url`). **[O]** `2l1yyalq76g-o.js@15745`.
- Coding models and credits per turn (edit vs one-shot tables) **[O]** `3so7496t7v5q5.js@~65000`:
  - `rosie-agentic` 1,100 (8,000 cap noted). Rosie is described as "Rosebud balanced model".
  - `gpt-sol-agentic` 17,100 / 13,600.
  - `claude-opus-agentic` 15,600 / 12,000, tagged "Best".
  - `gemini-3-flash-agentic` 7,000 / 5,000.
  - `gpt-luna-agentic` 1,100.
  - `grok-4.5-agentic` 6,000.
  - A second table (`v`) of 400–1,600 per model is probably minimum or estimated cost. **[I]**
- Export: code download, and a Windows build job (`/windows-build/jobs/`, `readiness/`, `settings/`) for Steam. **[O]** endpoints; plan gating **[W]** https://rosebud.ai/pricing (fetched as `pricing.html`).

## Asset generation
- Images and sprites: costs keyed by model. "Nano Banana 2" 1,700, with background removal 1,750; "Flux 2 Flash" 250, with background removal 300; "3D Asset" 1,000. Kinds: `sprite, vfx_sprite, icon, ui_element, background, character_portrait, texture_tile`. **[O]** `3so7496t7v5q5.js@65590`.
- Audio: `sound_effect` 250 and `background_music` 1,550. **[O]** same file.
- Sprite animations: `/api/sprite-animations/{capabilities,quotes,references,jobs,characters}`. A reference PNG is uploaded with `purpose=animation`. **[O]**
- Model tools with a quote-then-job pattern: `/api/model-tools/{capabilities,quotes,jobs,images,images/preview,uploads,assets}`. A public developer asset API also exists (`/api/v1/asset-models/`, `/api/v1/asset-jobs/`, `/api/v1/developer/keys/`, `/usage/`). **[O]**
- Skyboxes: `revision-media/previews` with `generation_kind:"skybox"`, 150 s timeout. Public page `/skyboxes/roblox` exports the 6 faces Roblox expects (SkyboxBk/Dn/Ft/Lf/Rt/Up) as a "Roblox ZIP", from 4096×2048 sources, at 2,000 credits each, with a free library. **[O]** `skyboxes_roblox.html`.

## Social, retention and monetisation
- Feed: `/play` with categories (Showcase, New, Multiplayer, Clicker, Horror and others) and SEO landing pages `/play/c/{anime,clicker,…}`. **[O]**
- Published projects support like/unlike, threaded comments with reactions, mentions and reports, a report reason enum including "Broken / unplayable", and `clone` (remix). **[O]** `1pfdwyzgqx4sk.js@137328`.
- Creator tips through Stripe Connect-style onboarding: `/api/creators/onboard`, `dashboard-link`, `{id}/tip`, `/profile/my-plan/tip-complete`. **[O]**
- Engagement: `ENGAGEMENT_QUESTIONS` messages, `/api/engagement/scratch-questions/` (clarifying questions from a prompt), `create-flow-turn/` and `create-flow-image/` (guided create wizard). **[O]**
- "Next moves": `GET /api/projects/{id}/next-moves/` returns suggestions. Picking one sends `direction_suggestion_id`, and the client logs the category and whether the user edited the text before sending (`R.eH(T.category, e!==T.insertedText)`). **[O]** `3so7496t7v5q5.js@53512`, `2n5c6dujk98v6.js@11632`.
- Visuals-first onboarding: `/api/visuals-first/game-types/`, then `theme-manifest?theme_id`, then `create-project/`, which redirects to `/edit/{id}`. **[O]** `2l1yyalq76g-o.js@27298`.
- Distribution: X playables (`/x-playables`), Discord play preview (`/discord-play/preview/`), embeds (`/embed/:gameId`), and "OGP" points (`RosebudOGP.submitPoints`, which looks like a points/rewards integration). **[O]** **[I]** for OGP's purpose.
- In-game LLM: `ChatManager.getCharacterResponse()` posts `requestLLM {character, messages, maxTokens:384, operation}` to the parent, which calls `/api/in-game/call-llm`. This gives games NPC chat at runtime. **[O]** `canvas/ChatManager.js`, `3so7496t7v5q5.js@51967`.
- Pricing: credits. The free plan has 8,000 credits that refill weekly in eligible regions. Paid plans add daily refresh credits, and monthly credits roll over once. The editor shows each turn's cost. A Rosie edit is about 2,000 credits and a premium model edit about 20,000. Pro and above get code download plus Windows/Steam export, and 10x Dev and above get commercial rights at 0% commission. **[W]** https://rosebud.ai/pricing, https://www.summerengine.com/blog/rosebud-ai-pricing

## Notable UX
- A CLI and agent publishing flow with no account needed. `npx @rosebudai/cli publish --directory ./dist` returns a `play_url` plus a private `claim_url` that expires after 1 hour. `rosebud connect` grants a 90-day token scoped to one game. `update --expected-version` refuses to overwrite web edits. `--agent-client claude-code|codex|cursor|gemini-cli`. There is also an AGENTS.md for coding agents. **[O]** `developers_agent-publishing_docs.html`.
- Model picker with per-turn cost, and a "busy in another tab" single-flight lock. **[O]**
- "Universal" template: anything that isn't Universal gets engine-specific handling (`"j",0,e=>"Universal"!==e`). **[O]**

## Weak spots
- Polling every 2 s with no streaming means you see no progress tokens during long agent turns. Their mitigation is the fake optimistic commit. **[O]**/**[I]**
- The runtime check depends on the user's own browser tab staying open and visible. Turns started on mobile or in a background tab can return `client_error`. **[I]** from the code paths.
- A single game script loaded through a Blob URL makes multi-file games a separate template ("Multifile"). **[I]**
- No real multiplayer runtime turned up in the client (no Playroom or WebSocket game server). "Multiplayer" appears to be only a prompt preference plus a feed category. **[I]**

## Cherry-picks for Forge

1. **Agent-requested runtime check as a tool call**
   - **What:** The coder model can request "load revision X, collect N ms of console, optionally screenshot" mid-turn and gets a structured result guarded by a content hash.
   - **Why it helps Forge:** Today Forge's critic runs after the build. This lets the coder test inside its own turn, and the content-hash guard stops a stale playtest from being blamed on new code.
   - **Smallest version:** Expose `runtime_check(revision, collect_ms=2500, max_events=40, screenshot=false)` to the Forge coder role, backed by the existing headless runner (Studio only when `screenshot=true`). Return entries plus `loaded_content_hash`, and reject the result if the hash differs.
   - **Works without real players?** Yes.

2. **Attach deduplicated console to the next chat message**
   - **What:** Errors are grouped with count, first_seen and last_seen, and sent along with the user's prompt.
   - **Why it helps Forge:** A Studio-plugin user says "fix it" without pasting the Output window. The model gets the actual stack traces.
   - **Smallest version:** The plugin collects LogService errors grouped by (message, script, line). It adds a checkbox "Attach Output (n errors)" and puts `console_entries` in the user message, not the system prompt, so Mubit task grouping holds.
   - **Works without real players?** Yes.

3. **Next-move suggestions with acceptance telemetry**
   - **What:** The server proposes 3–5 next directions. The client logs which one was picked and whether it was edited.
   - **Why it helps Forge:** This turns the gap finder into one-click prompts. "Picked as-is", "picked and edited" and "ignored" are cheap preference labels for Mubit with no players needed.
   - **Smallest version:** The plugin shows the top 3 `forge gaps` items as chips. On send, record `{suggestion_id, category, edited: bool}` and attach it as feedback to the gap-finder Mubit call.
   - **Works without real players?** Yes.

4. **Error-storm breaker**
   - **What:** More than 10 runtime errors per second trips a flag instead of flooding the UI or model.
   - **Why it helps Forge:** Swarm testers on a broken build spam identical errors and eat tokens.
   - **Smallest version:** Rate-limit plus dedupe in the tester-report collector. When the rate passes 10 per second, mark the run `error_storm` and send only the top 3 distinct errors to the critic.
   - **Works without real players?** Yes.

5. **Roblox skybox generator (6 faces)**
   - **What:** Generate a 360° equirect image, cut it into Bk/Dn/Ft/Lf/Rt/Up and assign them to `Lighting.Sky`.
   - **Why it helps Forge:** It is an instant, visible art upgrade for demo screenshots and a cheap asset win.
   - **Smallest version:** A Forge asset step: one image call (through Mubit if image models are allowed, otherwise a library), a Python cubemap split, upload through the Studio MCP `upload_image`, and set the Sky properties.
   - **Works without real players?** Yes.

6. **Setup preferences as structured fields (dimension, platform, single or multiplayer)**
   - **What:** Three radio choices captured before the first build and sent as fields, not prose.
   - **Why it helps Forge:** It removes ambiguity at the cheapest point. For Roblox: mobile or desktop controls, solo or co-op, round length.
   - **Smallest version:** Add `platform`, `players` and `session_minutes` args to `forge new` and the plugin's first-build form, passed in the user message.
   - **Works without real players?** Yes.

7. **Expected-version guard on publish and update**
   - **What:** `update --expected-version` refuses if someone edited on the web since.
   - **Why it helps Forge:** Forge writes files while humans edit in Studio. This prevents autopilot clobbering a human fix.
   - **Smallest version:** `forge promote`/`sync` records the place-file or script hash it last saw and aborts on mismatch unless `--force`.
   - **Works without real players?** Yes.

8. **History compaction status**
   - **What:** A visible `compacting` state when chat history is summarised.
   - **Why it helps Forge:** Long autopilot sessions will overflow context. Making compaction explicit avoids silent quality drops.
   - **Smallest version:** When the conversation passes N tokens, run a summariser Mubit task and show "compacting" in `forge job`.
   - **Works without real players?** Yes.

9. **Visuals-first templates (game type → theme → project)**
   - **What:** Pick a genre template, then a theme with preview art, then a pre-made project to edit.
   - **Why it helps Forge:** It guarantees a working starting point. Forge's kit modules already exist, so this is mostly a picker.
   - **Smallest version:** `forge new --template tycoon --theme lava` copies a kit preset plus a theme palette and asset list. The plugin shows it as 2 dropdowns.
   - **Works without real players?** Yes.

Sources: https://rosebud.ai/pricing · https://rosebud.ai/developers/agent-publishing/docs · https://rosebud.ai/skyboxes/roblox · https://rosebud.ai/x-playables · https://www.summerengine.com/blog/rosebud-ai-pricing
