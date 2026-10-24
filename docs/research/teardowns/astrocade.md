# Astrocade (astrocade.com) teardown

Date: 2026-10-24. Method: public HTML and JS only, fetched with curl (no login, no POSTs). Evidence is in
`teardowns/astrocade/` (`*.html` for 13 public pages; `js/*.js` with 346 Next.js chunks from `d2oir5eh8rty2e.cloudfront.net`,
including 210 lazily loaded editor chunks). Tags: **[O]** Observed (file + snippet), **[I]** Inferred, **[W]** From web (URL).

## Summary
Astrocade (legal entity Astroblox, Inc.) is a TikTok-style feed of short AI-made browser games plus a creator tool.
In the creator tool every edit is a **"wish"**: a natural-language request sent to an "astroBrain" backend and queued
with an ETA. The output is a single HTML game. The examples are Three.js r160 from jsdelivr, with an injected
`window.lib` runtime that serves assets, tunable parameters, leaderboards, cloud saves and LLM calls. The standout idea
is that every game carries a **`game_config` JSON of tunables**, and the game declares slider, colour and dropdown
metadata for them with `lib.showGameParameters`. Creators and remixers can retune gravity, speed and colours with no
LLM call. On the business side there is a pay-per-"significant play" creator fund paid through PayPal or Stripe,
bi-weekly competitions, a personalised feed, and an internal human QA/curation pipeline that feeds model training.
They also run a remote MCP server so Claude Code, ChatGPT, Codex, Cursor and Gemini CLI can build and publish.
Backers include Sequoia, Sea, NVIDIA and Google. They report 20M+ users and 75,000 games. **[W]**

## Stack
- Next.js with Turbopack, static files on CloudFront. API at `astrocade-api-prod.com`, proxied as `/api` when served from astrocade.com. axios with a 30 s default timeout. **[O]** `b420f937ab57bb18.js@26325` (`"https://astrocade-api-prod.com".includes("astrocade.com")?"/api":…`).
- Asset CDNs: `dstpt0i8yrnxz.cloudfront.net` holds game context and suggestions (prod); `dfxnayggey4hd` is stage. **[O]** `92e5dccc30275d73.js@8808`.
- Analytics: Amplitude, Amplitude Experiment (`BEAM_WEB_EXPERIMENT`), New Relic, Meta pixel, and their own `/v3/client-events` and `/v3/analytics`. Auth: Auth.js (NextAuth). Mobile: an Android TWA plus a NativeBridge, and an iOS app (`app-id=6786137532`). **[O]** `7d3ff79357dd63c3.js`, `0f4501f593c6c8b6.js`, `create_earn.html`.
- MCP: `https://mcp.astrocade.com/mcp` (streamable HTTP, OAuth). Setup cards exist for Claude Code (`claude mcp add --transport http --scope user astrocade …`), ChatGPT, Claude, Codex, Cursor and Gemini CLI. **[O]** `create_mcp.html`.

## Generation pipeline
**Request: a "wish".** **[O]** `77a036dcd3ab57e1.js@~77900` (`sendWish`):
```
POST /v1/context   (or a configured editor GCM API URL)
{ astroBrainRequest: JSON.stringify({
    request_id, session_id, user_id, game_id,
    user_input: {text} | object,
    game_context,                  // with workspace_url, the inline workspace is stripped
    request_type,                  // "brainstorming" | "fluff" | "create" | "direct_asset_edit"
    user_selected_model?,          // ModelType "fast" | "smart"
    task_plan_mode_enabled?,       // only for create
    supports_game_context_url: true, supports_brainstorm_channel?,
    client_capabilities: ["capacity_refusal"],
    direct_asset_edit_payload? }),
  isJsRequest: true, userId, title?, description?, thumbnailUrl?, gameVersionId? }
```
- Response: `{game, wishRequest:{requestId, status, estimatedTimeLeft, totalTime, gameId, userId, gameVersionId, wish, isInitialCreation, attachments}}`. The wish is appended to `game.pendingWishRequests`. Brainstorming and direct asset edits return nothing (handled on a separate channel). **[O]** same.
- Chat message types: `multimodal, options, game_design, inspire_me, loading`. Tabs: `home, media, code`. **[O]** `77a036dcd3ab57e1.js` (`REQUEST_TYPES`, `MessageType`, `ModelType`).
- Brainstorm mode keeps its state in `astro:brainstorm_session`, with events `brainstorm_inspire_me`, `brainstorm_options_presented` and `brainstorm_game_idea_presented`. **[O]** string counts.

**Job model.**
- The client receives `estimatedTimeLeft` and `totalTime` and counts the ETA down locally once a second while `status==="inProgress"`. Other statuses include `clientAcknowledged`. **[O]** `02765fd5044456cd.js@9283`.
- Updates come from react-query polling (`refetchInterval:3e4` in several places, plus dynamic intervals) and `/v3/notifications`. No app-level WebSocket or SSE was found. The only WebSocket reference is a proxy inside the game runtime that records which hosts a game contacts. **[O]** `7631c1d24d0941e0.js@75088`. **[I]** The exact poll interval for an in-flight wish is not confirmed.
- Capacity: `wish_capacity_rejected`, `wish_capacity_retry_clicked` and `client_capabilities:["capacity_refusal"]` mean the server can refuse when GPUs or models are saturated, and the client offers a retry. **[O]**
- Quota: `GET /v3/quota` returns `dimensions[{dimKey, used, budget}]`, and a negative budget means unlimited. **[O]** `87b9f803bb82e05c.js@444878`.

**Versioning.**
- `GET /v3/game-versions?gameId&showAllVersions&pageSize=20`. The UI offers "Undo Wish" ("Undo game to before this wish?") plus wish history with preview and restore buttons. **[O]** `87b9f803bb82e05c.js@48595`, strings.
- `POST /v3/update-workspace {gameId, baseWorkspaceUrl, modified}` stores a code workspace, with a 5 MiB cap per file and per payload (HTTP 413 names the file path). **[O]** `87b9f803bb82e05c.js@36206`.
- Publishing goes through `POST /v3/games/{id}/submit-for-review`, and the game record has a `reviewStatus`. **[O]**

**Preview and runtime.**
- Feed games run in `<iframe sandbox="allow-scripts allow-pointer-lock">` (no allow-same-origin) on a hashed `game-shell.<fnv1a>.html` page. The shell posts `SHELL_READY`, receives `LOAD_GAME_HTML`, and runs `document.write(html)` in its own task. A same-origin https page is used rather than a data: URL because Android WebView hosts mishandle the latter. **[O]** `454251eb0d735d3e.js@35389`.
- Parent to game: `RUN_WITH_CONFIG {gameConfig, mode, gameMetadata, hideClickToPlayOverlay, runId}` and `AUDIO_STATE`. **[O]** `4e6e6b0e39552cb7.js` (`sendRunWithConfig`).
- `createIframeSrcDoc` injects `astrocade-lib.js` with `{{ASSET_MAP}}` and then **verifies** that the lib script, the `IFRAME_READY` signal and the `GAME_ERROR` handlers are all present. If any is missing it throws before running. **[O]** `7631c1d24d0941e0.js` (end of file).
- Game to parent messages: `LOG, GAME_ERROR, GAME_FPS_UPDATE, GAME_EXTERNAL_REQUESTS, RUN_COMPLETED, IFRAME_READY, IFRAME_ACK, IFRAME_COMMIT_STATE, IFRAME_LIVE_UPDATE, SHOW_INFO_UI, HIDE_INFO_UI, LLM_REQUEST, LEADERBOARD_ADD_SCORE, LEADERBOARD_GET_ENTRIES, USER_GAME_STATE_GET, USER_GAME_STATE_SET, USER_GAME_STATE_DELETE, ANALYTICS_MESSAGE, DEVICE_*, ASSET_DOWNLOAD_COMPLETE`. **[O]** same file.
- FPS telemetry: a 5 s warm-up, then every 1 s it posts `{fps, fpsStd, fpsSamples, durationMs}` (Welford running mean and standard deviation), resetting on focus. **[O]** same file (`GAME_FPS_UPDATE`).

## Artifact and engine
- Game context per version: `{asset_map, game_code, game_config, game_design_document, persistent_storage_config, game_metadata, task_plan, chat_history}`. It is published to the CDN as `…/{gameId}/{versionId}/{ts}/context/full.json.gz` and a smaller `play.json.gz` for players. **[O]** `games_swing-hero_….html@1944374`, `77a036dcd3ab57e1.js` (`l()` default context).
- `game_code` is one HTML document. The sample ("Swing Hero", 907,896 plays) is about 1.7 MB (`31:T1a369f`) and modulepreloads `three@0.160.0`. The bundled `src/city.js` suggests esbuild output, possibly built through the MCP or code tab. **[O]** same file. **[I]** on how it was built.
- `game_config` holds tunables, for example `{hero:{style,suitColor…}, physics:{gravity:32, swingPower, releaseBoost, webLength, steering}, world:{…}, audio:{…}, camera:{…}, debug:{startBoss, unlockSuits}}`. The code calls `lib.showGameParameters({name, params:{"Gravity":{key:"physics.gravity", type:"slider", min:12, max:60, step:1}, "Suit color":{type:"color"}, "Hero":{type:"dropdown", options:[…]}, …}})`. **[O]** same file @1008035.
- `window.lib` API: `log, getAsset(id), getAnimationPlayer, preloadAnimation, editMenu.open/close` (click-an-object, with copy/delete callbacks), `showGameParameters, commitState, startDrag/endDrag, batch, addPlayerScoreToLeaderboard`, plus LLM requests and user-game-state (cloud save). **[O]** `7631c1d24d0941e0.js` (`Zn=(()=>{…})`).
- `asset_map` entries: `{url, type, prompt, description, subtype, aspect_ratio, compression_suggestion, duration_secs, loop, opus_url, animation:{frames, fps, loop}}`. **[O]** game page @1933838.

## Asset generation
- Asset kinds seen in maps: audio (music loops and SFX with text descriptions), textures, 3D models (`model_reaper`), and sprite animations with frames and fps. Opus transcodes (`opus_url`, `probeOpusSupport`). **[O]**
- Direct asset edit: the `direct_asset_edit` request type plus `uploadEditedAssetBytes` (`/v3/image/upload` presign) means users can repaint or replace an asset without a code wish. **[O]** `77a036dcd3ab57e1.js`.
- Avatar system: rigged 3D heads and bodies (`bones, armature, meshes, eyeScale, masculinize`) for profiles and in games. **[O]** key counts in the game page. **[I]** on purpose.
- Image and audio model names were not exposed in the client. **[O]** (absence).

## Social, retention and monetisation
- Feed: `/v3/feed` (GET), or POST with `sessionHistoryBody()` for the personalised "BEAM" arm. Filters are `combined_feed` and `categorized_feed`. Games support like, bookmark, pin, share, a play counter (`playsToAdd`), recently played, visibility, `disableRemix`, `remixLocked`, `remixCount`, `remixRootGameId`, and leaderboards. **[O]** `2a9f7271625d818f.js@50764`.
- Remix: `POST /v3/remix`. Draft: `POST /v3/games-draft`. Follow graph: `/v3/user-follow`. Referrals: `/v3/referrals/{me,lookup}` ("Refer a creator and earn"). Push tokens and notifications. **[O]**
- Creator earnings: "Estimated earnings this month (significant plays × base rate × bonus). Finalized at month end." The rate is shown "/ 1K significant plays with a current Nx bonus multiplier". There is a `QUALIFICATION_THRESHOLD_PLAYS` gate with a progress bar, enrolment through `/v3/users/earnings/{enroll,status}`, and payouts through `/v1/creator-payouts/{onboard, paypal/connect-start, paypal/connect}` (Stripe or PayPal). **[O]** `6c8b1b549cbcd541.js@53092`, `@5741`. The constants live in a chunk I did not fetch.
- Funding and numbers: $56M Series A+B (Sequoia, Sea, NVIDIA, Google AI Futures Fund) in May 2026; 20M+ users in 8 months; 75K games; a $10M creator fund. **[W]** https://fortune.com/2026/05/05/astrocade-raises-56-million-series-b-sequoia-video-games-platform-ali-amir-sadeghian/ , https://pulse2.com/astrocade-56-million-raised-to-build-ai-powered-interactive-entertainment-platform/
- Competitions: "Go up against 100+ creators every other week for rewards and a week in the spotlight." Astro Academy has 8 lessons (game mechanics such as merging, launching and power-washing). **[O]** `creators.html`, `create_academy.html`.
- Retention instrumentation: `WishMilestoneTracker` (`wish_5_milestone`, `wish_10_milestone`, `d1_retention_wish_conversion`), `SessionMilestoneTracker`, and `GameLoadMetricsTracker`. **[O]** `7d3ff79357dd63c3.js@18172`.
- Internal tooling routes (UI shells are public, data is behind auth): `/qa/benchmark-annotation/experiments/:id/annotate`, `/qa/benchmark-results`, `/qa/game-curation[-training|-qa-calibration|-final-review]`, `/qa/game-tag-annotation`, `/internal/ugc-pipeline/{reviews, reviewer-accuracy, training-results, games-queue, daily-rates, t-plus-x, retire}`, `/internal/surfacing/playtesting`, `/internal/minibot`, `/internal/payouts`. **[O]** route list from chunks. **[I]** These are human raters labelling games for curation and for model benchmarks and training, with reviewer-accuracy calibration.

## Notable UX
- A wish ETA countdown plus "Undo Wish", which keeps the cost of a bad wish near zero. **[O]**
- In-game parameter panel and an `editMenu` on clicked objects (copy, delete, sliders) that commits state back without the LLM. **[O]**
- "Tap to play!" overlay and click-to-play analytics. "Challenge your friends to beat your score!" share prompt after playtime (`share-prompt-after-playtime`). **[O]**
- MCP-first onboarding for people already living in coding agents. **[O]**

## Weak spots
- The single-HTML artifact caps complexity. Big games become 1.7 MB inline documents, and file and payload caps are 5 MiB. **[O]**/**[I]**
- No real multiplayer runtime: the shared state is leaderboards plus per-user cloud saves. **[O]** (message list)
- Quality depends on human curation queues (ugc-pipeline, game-curation), which is costly to run at 75K+ games. **[I]**
- Press coverage calls much of the catalogue low-effort "AI slop". **[W]** https://mezha.ua/en/news/ai-slop-games-is-popular-315954/

## Cherry-picks for Forge

1. **Tunables manifest plus a slider panel (`game_config` + `showGameParameters`)**
   - **What:** Gameplay numbers live in config with min, max and step metadata, and a UI edits them live with no LLM call.
   - **Why it helps Forge:** Balancing is most of the remaining "make it fun" work. Persona testers can sweep values (gravity, spawn rate, fire spread) and the critic proposes deltas instead of code rewrites. Edits are cheap, safe and reversible, and each human slider correction is a clean Mubit label ("value X → Y").
   - **Smallest version:** Forge emits a `ReplicatedStorage.GameConfig` ModuleScript plus a `Tunables` table `{key, min, max, step, type}`. The Studio plugin renders sliders and writes Attributes. Add `forge tune <slug> key=value`, and let autopilot try ±1 step on the knob tied to the worst tester metric.
   - **Works without real players?** Yes. It is designed for AI testers.

2. **Typed request router (brainstorm / fluff / create / direct_asset_edit, fast / smart)**
   - **What:** A cheap classifier decides whether a message needs the coder at all.
   - **Why it helps Forge:** Chit-chat and "make the button red" shouldn't burn a full coder plus critic loop. Each route is its own Mubit task, so router corrections train separately.
   - **Smallest version:** A new `router` prompt (new Mubit task; this does not edit existing prompts) returns `{type, model_tier}` in front of `forge feature` and plugin chat. `direct_asset_edit` writes the Attribute or asset ID directly.
   - **Works without real players?** Yes.

3. **Wish queue with ETA plus one-click "Undo this wish"**
   - **What:** Each request is a versioned unit with `estimatedTimeLeft`/`totalTime`, and revert means going back to the version before that request.
   - **Why it helps Forge:** Forge has versions and rollback, but they are not tied to the request that caused them. Per-request undo is the most natural correction gesture, and "undone" is a strong negative label for Mubit.
   - **Smallest version:** Store `request_id → (version_before, version_after)` in the job record. The plugin shows a history list with "Undo" that calls `forge rollback` to `version_before` and logs a Mubit negative on that request's coder call. Estimate the ETA from the median of past job durations per request type.
   - **Works without real players?** Yes.

4. **Injection verification before any playtest**
   - **What:** The harness asserts that lib, the ready signal and the error handlers were injected, or the run fails fast.
   - **Why it helps Forge:** It prevents "tester found nothing" when the test harness silently didn't load (counters that never move).
   - **Smallest version:** Before `test_feature` or a swarm run, check that the ForgeTest harness and telemetry channel posted `READY` within N seconds. Otherwise mark the run `INCONCLUSIVE: harness_missing` instead of PASS.
   - **Works without real players?** Yes.

5. **FPS mean plus standard deviation telemetry after warm-up, plus RUN_COMPLETED**
   - **What:** Performance as a first-class signal: 5 s warm-up, 1 s windows, Welford statistics.
   - **Why it helps Forge:** The critic currently judges function, not feel. Frame-time variance catches spawn storms and part leaks that AI testers otherwise miss.
   - **Smallest version:** The client telemetry channel (#148) adds `fps` and `fps_std` every 1 s after 5 s, and the server adds `Workspace` part count. A critic rule: if the 10th-percentile FPS falls below 30 or the part count grows, file a gap.
   - **Works without real players?** Yes (simulated players).

6. **Versioned "game context" bundle (full vs play)**
   - **What:** One JSON per version holding code, config, asset map with descriptions, design doc, task plan and chat history.
   - **Why it helps Forge:** Every Forge role (architect, coder, critic, gap finder) reads the same snapshot, which makes corrections reproducible and replayable for Mubit.
   - **Smallest version:** Write `runs/<slug>/versions/<v>/context.json` at each version, including the GDD, tunables, asset IDs with text descriptions and the last N requests. Pass its path or a summary in the user message.
   - **Works without real players?** Yes.

7. **Asset map entries with text descriptions**
   - **What:** Every asset carries a human description ("Pumpkin bomb explosion"), loop and duration.
   - **Why it helps Forge:** The coder can pick assets by meaning, and the critic can say "wrong sound for event X". It also enables swapping assets without code edits.
   - **Smallest version:** `GameAssets` entries get `description` and `kind` fields, and the coder prompt (user message) lists them.
   - **Works without real players?** Yes.

8. **Human calibration pipeline for corrections (curation + reviewer accuracy)**
   - **What:** Raters label games and tags, and the pipeline tracks inter-rater accuracy and training results.
   - **Why it helps Forge:** Mubit training is only as good as the corrections. A tiny calibration set keeps the team's corrections consistent.
   - **Smallest version:** `forge lessons` adds a "review" mode: two teammates label the same 10 tester reports, agreement is shown, and only agreed corrections are promoted to Mubit.
   - **Works without real players?** Yes (team as raters).

9. **Remote MCP with OAuth for any agent**
   - **What:** A single `https://…/mcp` URL that works in Claude Code, ChatGPT, Cursor and Gemini CLI.
   - **Why it helps Forge:** Forge already has a local MCP plugin. A hosted endpoint would let judges and testers drive Forge from ChatGPT without a local install. This is low priority for the hackathon.
   - **Smallest version:** Expose the existing forge MCP tools over streamable HTTP behind a token.
   - **Works without real players?** Yes.

10. **Significant-play payouts plus competitions**
    - **What:** Pay per 1K "significant plays" after a qualification threshold, with bi-weekly competitions.
    - **Why it helps Forge:** It only matters with players. Note it for the pitch deck, not the build.
    - **Smallest version:** None for now.
    - **Works without real players?** No.

Sources: https://www.astrocade.com/create/mcp · https://www.astrocade.com/creators · https://fortune.com/2026/05/05/astrocade-raises-56-million-series-b-sequoia-video-games-platform-ali-amir-sadeghian/ · https://pulse2.com/astrocade-56-million-raised-to-build-ai-powered-interactive-entertainment-platform/ · https://pocketgamer.biz/astrocade-raises-56m-to-expand-ai-powered-games-creation-platform/ · https://mezha.ua/en/news/ai-slop-games-is-popular-315954/
