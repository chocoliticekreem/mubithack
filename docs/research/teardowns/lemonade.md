# Lemonade (lemonade.gg) teardown

Date: 2026-10-24. Public evidence only: landing page, terms, privacy policy, 26 page chunks plus 65 lazy webpack chunks (`teardowns/lemonade/js/`), public Roblox economy metadata for the plugin, and web sources. No login.

**Plugin source was NOT read.** `assetdelivery.roblox.com/v1/asset/?id=85716018250741` returns `401 "Authentication required to access Asset."` (Observed, `teardowns/lemonade/plugin/asset.bin`), so per the rules we stopped there. Everything about the plugin protocol below is inferred from the web client.

Evidence tags: **Observed** (file + snippet), **Inferred**, **From web** (URL).

Note: web search also returns "Lemonade", AMD's open-source local LLM server. That is a different product; ignore any result that mentions local subprocess servers.

## Summary

Lemonade is a web-chat **coding agent attached to a live Roblox Studio session through a plugin**. The browser holds the chat, plan and history. The plugin executes changes in Studio, and project files stay on Roblox: "Lemonade acts as a middle-layer agent between Roblox Studio and our implementations. We do not host or store your codebase" (Observed, `pages/lemonade.gg_terms-of-service.txt`).

It is built on a LangGraph-style agent with human-in-the-loop interrupts:
- plan approve, reject or edit
- an automatic post-build playtest that records a GIF and asks "continue or refine?"
- next-move task suggestions
- an **autonomous mode** that drains a queue of tasks on a daily cap

Retention is driven by gamification: daily credit roll, slot-machine animation, prompt cards, a community GIF feed with likes, and a leaderboard.

**Scale.**
- "Join +500K Creators" (Observed, landing `index.txt`).
- "almost 100,000 monthly active creators" and 50k+ Discord as of 2026-04-21 (From web, https://naavik.co/podcast/building-ai-tools-for-roblox-creators/).
- Founder Nicolas Vizioli; company Lemonade Labs, Inc., Delaware (Observed, landing footer).
- The plugin was created on 2025-08-03 and updated on 2026-09-26 (Observed, `economy.roblox.com/v2/assets/85716018250741/details`).

## Stack

| Item | Evidence |
|---|---|
| Next.js (webpack build) on Vercel (`?dpl=dpl_...`) | Observed: `index.html` chunk URLs |
| Auth: Clerk, with "Sign in with Roblox" OAuth (scopes: user ID and profile only) | Observed: `index.html` `src="https://clerk.lemonade.gg/npm/@clerk/clerk-js@5/..."`; `pages/lemonade.gg_sign-in.txt` "Read User ID ... Read User Profile" |
| Backend data: Convex (a public `*.convex.cloud` deployment, plus a Clerk JWT with the `convex` template) | Observed: `lazy_2596...js` `new j.ConvexHttpClient("https://<deployment>.convex.cloud")`, `g({template:"convex"})` |
| Agent runtime: LangChain/LangGraph message shape and interrupts | Observed: `additional_kwargs.threadId/runId/graphId`, `f.interruptData{graphId, playtestStep, question}`, `"[useAIExecution] HITL resume attempt"` |
| Models via OpenRouter, user-selectable with per-model availability and credits | Observed: `eK({chatId, openRouterModel:e})`; model ids `anthropic/claude-opus-4.6`, `google/gemini-3-flash-preview`, `composer-2.5`, `gpt-5.6-luna`; `modelAvailability.getAll` |
| BYO ChatGPT/Codex plan: route prompts through the user's own ChatGPT subscription (OAuth device code) | Observed: `users.setChatgptSubEnabled`, `/api/chatgpt/models`, errors `chatgpt_plan_exhausted`, `codex_overloaded`, and "This model only runs on a connected ChatGPT Codex plan (Pro). Your prompt wasn't run and nothing was billed." |
| Payments: Polar | Observed: terms "Payments are handled by Polar Software Inc." |
| Voice input: `/api/audio/transcribe` (multipart audio, 429 rate limit) | Observed: `lazy_2596...js` |
| Model evals per release | From web (Naavik): "fully model-agnostic ... evaluation pipelines testing new models immediately upon release" |

Convex function surface (Observed, `.FH.<module>.<fn>` across chunks):
- **Agent and chat:** `agentMemory.*` (chats, messages, session ids), `executionState.getExecutionState`
- **Playtests:** `playtestGifs.listAccepted|getByHumanMessageId`, `likedPlaytestGifs.toggleLike`
- **Game memory:** `gameMemories.getByProject|moveMechanic|savePositions|startImport`, `gameMemoryIdeas.generate`, `memoryBank.generateMemory|updateMemoryContent`
- **Autonomous mode:** `autonomousAgent.getSettings|getDailyUsage|queueMechanicTasks|updateSettings`
- **Remix and onboarding:** `remixRoadmaps.advanceStep|generateThumbnail`, `projects.*Onboarding*`
- **UI builder:** `uiThemes.setProjectTheme`, `uiBuilderScripts.*`
- **Gamification and billing:** `dailyRoll.claimDailyRoll`, `cardsDeck.logInteraction`, `userCredits.getCreditBalance`, `agentRatings.submitRating`
- **Restore and telemetry:** `archiving.restoreFlow.restoreProject`, `frontendErrors.insertFrontendError`

## Web-to-Studio pipeline

- **Plugin.** Asset 85716018250741 "Lemonade AI", group creator "Lemonade Labs", AssetTypeId 38 (Plugin), free (Observed, economy API). The web app links to `https://create.roblox.com/store/asset/85716018250741/Lemonade-AI` (Observed, `lazy_2596...js`).
- **Connection.**
  - The web UI gates on a `pluginConnected` flag, with a modal walking through `installState` and then `connectState` (Observed).
  - The input is hard-disabled when the plugin is disconnected: `hardDisabled = controlsDisabled || isGeneratingMemory || !pluginConnected || internalLimitReached` (Observed).
  - User flow: install from Toolbox, sign in with the same Roblox account, click Connect in the plugin, approve "allow the Lemonade plugin to access actions on lemonade.gg" (From web, https://nilo.io/articles/lemonade-ai-for-roblox).
- **Transport (Inferred).** That approval prompt is Roblox's plugin HttpService permission. The plugin almost certainly **polls Lemonade's HTTPS backend** (Convex or Next API) for queued actions and posts results back. Studio plugins can't open inbound ports, and nothing in the web bundle uses a websocket or localhost. Evidence:
  - There are no `wss://` or `localhost` strings in any chunk (Observed, grep).
  - The server-side endpoint `POST /api/ui-builder/studio-action {projectId, action:"studioAction", toolName, params}` returns `{success, result}` and throws `"Studio action ${toolName} failed"` (Observed). That implies a server-mediated RPC to the plugin.
  - `/api/roblox/onboarding-map` is retried at 0, 1.5, 3 and 4.5 s and logs "Map glow-up **run-code** did not complete" with `r.status, r.error, r.output` (Observed). That implies the backend can execute arbitrary Luau in Studio and read the output.
- **Request shape.** `POST /api/agent` with `{message, projectId, chatId, userId, humanMessageId, sessionId, model, requestId, mode, themeName, selectedUI{templateName}, enableRunCode, autoApprove, capturePlaytestGif, disablePlaytest, disableSuggestions, promptOrigin, isContinuation}`. HITL resumes use `{approvalAction, message, sessionId, ...}`. Cancel is `POST /api/agent/cancel {sessionId, chatId, projectId}`, delayed so a request has run at least 10 s before cancel (Observed, `lazy_2596...js`: `Math.max(0,1e4-(s-a))`).
- **Rollback.** `POST /api/rollback {projectId, messageId, chatId}`, with a 504 surfaced as "Rollback timed out" (Observed). **Inferred:** a per-message snapshot or inverse ops replayed through the plugin. Undo is per chat message.
- **Context.** `@mentions` of files, instances and UI templates (`robloxClass:"UITemplate"`), `filesSearch.search`, image upload (Observed).

## Agent loop & self-testing

1. **Plan, then HITL approval.** A plan todo list appears with `onPlanApprove / onPlanReject / onPlanEdit` (Observed). `autoApprove` skips it.
2. **Build in Studio.** The agent edits through the plugin. A status ticker cycles "thinking, reading, searching, writing, deleting, editing" (Observed).
3. **Auto playtest.**
   - Messages carry `playtestStep:true` plus `executionSessionId`, and the UI offers `onPlaytestContinue / onPlaytestRefine` (Observed).
   - "an automatic 15-second playtest after each generation to check for errors" (From web, nilo.io).
   - `capturePlaytestGif` records a GIF of the playtest. Users can turn off `autoPlaytestEnabled` and `captureGifEnabled` (Observed).
   - **Inferred:** the plugin starts a play session, collects output and errors for about 15 s and captures frames. The agent sees errors, and the human judges feel from the GIF.
4. **Next-move suggestions.** `additional_kwargs.taskSuggestions.tasks` are rendered as chips; picking one sends the next prompt (Observed).
5. **Ratings.** `agentRatings.submitRating` per chat (Observed). **Inferred:** this feeds their model evals.
6. **Autonomous mode.**
   - `autonomousAgent` has `enabled`, `dailyLimit` (default 5, `maxDailyLimit`), `queuedTasks`, `nextAutonomousRunAt` and a countdown "Starting in N minutes…" (Observed).
   - Queued tasks come from the game-memory mechanics board.
   - Unlocking requires joining Discord: `S?.hasJoinedDiscord ? a7(!0)` (Observed).
   - The canned autonomous instruction is: "Visually refine the "${t}" mechanic in a loop: particles, VFX, SFX, camera effects, lighting and shadows — small touches that add taste ... Never change models, textures or module scripts, and no backend or logic-only work." (Observed). **They restrict autonomy to safe, cosmetic "juice" passes.**
7. **Onboarding flow.**
   - Idea → `/api/roblox/expand-tasks` turns a task list into prompts ("Build this task for my simple game called ${name}: ${task}") → "map glow-up" run-code.
   - Model overrides per step: `gemini-3-flash-preview` with `disablePlaytest` for the first step, then `composer-2.5` with `forceCapturePlaytestGif` (Observed).
   - "promptFirstPlayable" auto-sends the first prompt (Observed).

## Asset generation

- The main focus is code and UI. "Current focus stays on coding and UI generation", and "asset generation remains on the roadmap" (From web, nilo.io). A later nilo article says it "can generate textured 3D models from prompts using the Trellis model" (From web, https://nilo.io/articles/lemonade-ai-roblox-3d-models). That source is SEO content from a competitor and is unverified.
- **UI builder:** themes (`uiThemes.getPickerState/setProjectTheme`), generated UI templates you can `@mention`, a "UI strength" setting (standard or high, gated by credits), and a "low-cost UI mode" (Observed).
- **Thumbnails:** `remixRoadmaps.generateThumbnail({gameName, mechanics})` (Observed).
- No terrain or asset catalog is visible in the client (Observed absence; only the client was examined).

## Pricing/community

- **Opaque pricing.** `/pricing` redirects to sign-in (Observed: every unknown route renders the Roblox sign-in page).
  - Terms: "a paid subscription tier, which provides increased prompt limits", billed monthly through Polar, **no refunds**, aggressive anti-chargeback language (Observed, ToS).
  - "$20 for 100 prompts" (From web, https://nilo.io/articles/lemonade-ai-for-roblox; unverified).
- **Credits.** A credit balance, per-model costs, a "Buy credits" flow, `onOpenStorePurchases`, discount badges per model, free-model reset timers (`freeModelResetAt`) and a rate-limit modal (Observed).
- **BYO compute.** Connect a ChatGPT plan so prompts bill to OpenAI, not Lemonade (Observed). This lowers their COGS.
- **Gamification.**
  - `dailyRoll` daily credit roll with a slot-machine reveal ("today N credits", "tomorrow ..."); `slotMachineEnabled` (Observed).
  - A prompt "cards deck" you drag into chat (`cardsDeck.getUserDragCount`), plus a "cards-leaderboard" panel (Observed).
  - A community feed of accepted playtest GIFs with prompt and owner, which you can like and reuse as a card (Observed: `"No liked GIFs yet. Tap the heart on a community card to save it here."`).
  - `publicPromptsEnabled`: your prompts and GIFs feed the community (Observed).
  - A completion sound (`/sounds/generation-completion.mp3`) (Observed).
- **Discord gating.** `/api/unlock/discord` verifies Discord membership through Clerk OAuth to unlock features (Observed).
- **Positioning.** The landing pitches "Your First Business Starts Here" with genre chips (dodge, shooter, lemonade stand, murder mystery, prison, aura, bedwars, survival, fish, farm, pet, brainrot) (Observed, `index.txt`). On Naavik they talk about teens "make their first dollar online", with one user making $20k in a month (From web, Naavik).

## Notable UX

- **Game Memory board.** A spatial canvas of mechanics with drag positions (`savePositions`, `moveMechanic`), per-mechanic AI idea generation, "tag mechanic" into a prompt as `<user_tagged_mechanics>` context, and "Send to Auto Tasks". It can import an existing game into memory once (`startImport`, `importUsed`) (Observed).
- **Memory Bank.** An editable, generated project memory document (Observed).
- **Remix roadmaps.** Start from a remix: a stepwise roadmap of mechanics, where each step is "Build the "${mechanicName}" mechanic for the game. Details: ..." (Observed).
- **Prompt queue.** Queue prompts while the agent runs (`promptQueueEnabled`, `promptOrigin:"queued_auto"`) (Observed).
- **Stale-client handling.** "A new Lemonade update is available. Please refresh" when `imageOutdated` (Observed).
- **Restore archived projects.** Free users get one active project: `setActiveProjectAndArchiveOthers`, `reactivateProjectForFreeUser` (Observed).

## Weak spots & user complaints

- **Requires Studio and a connected plugin.** No plugin means no prompt (Observed gate). There is no Chromebook or phone path, which is PromptBlox's main attack (From web, https://promptblox.ai/blog/promptblox-vs-lemonade-gg).
- **Opaque, non-refundable pricing.** Prices only appear after login, and the ToS forbids refunds and threatens "potential legal action" over chargebacks (Observed). **Inferred:** the anti-chargeback text exists because chargebacks from minors have been a real problem.
- **Shallow verification.** The playtest is a fixed ~15 s run, and the human judges the GIF (From web plus Observed HITL). No persona testers, multiplayer checks, reachability or economy checks are visible in the client.
- **Prompt-quality dependence.** "Vague prompts cause AI guess instance names and folder layouts" and "Missing object references cause script failures" (From web, nilo.io).
- **Provider fragility.** Error codes like `codex_overloaded` ("OpenAI's servers are congested right now") show the BYO-ChatGPT path fails visibly (Observed).
- **Thin public complaint record.** No Reddit or DevForum complaint threads surfaced in search (From web; results were off-topic).

## How Forge differs

| Axis | Lemonade | Forge |
|---|---|---|
| Studio link | Cloud agent plus a plugin that polls (Inferred); project lives only in Studio | Our plugin plus a Studio bridge plus file sync; source of truth on disk/git (`game/`, `runs/`) |
| Testing | One ~15 s auto playtest, GIF, human "continue/refine" | Headless engine plus real Studio, 10 persona swarm testers, gap finder, autopilot anomaly checks |
| Autonomy | Daily-capped autonomous queue limited to cosmetic VFX/SFX "juice" | Autopilot and orchestrate take an idea all the way to ready, including logic |
| Learning | Model-agnostic evals, chat ratings | Every LLM call goes through Mubit; corrections become model updates |
| Versioning | Per-message rollback through the backend | Versions and rollback per game, plus git |
| Monetisation of the *game* | Not visible | Battle pass, cosmetics, monetisation kits |
| Retention of the *creator* | Strong: daily roll, cards, GIF feed, leaderboard, Discord unlocks | None yet |

## Cherry-picks for Forge

1. **Playtest GIF on every build and fix**
   - **What:** record a short GIF or clip of each playtest and attach it to the job and version.
   - **Why:** it is the cheapest way to make a correction concrete for both humans and Mubit, and it is great demo material for the "correction turns into a model update" beat.
   - **Smallest version:** during the Studio screenshot step, capture N frames at a fixed interval, stitch them with ffmpeg, and save to `runs/<slug>/versions/<v>/playtest.gif`. Show it in the dashboard and in the `forge correct` prompt.
   - **Works without real players:** yes.
2. **HITL interrupt at the playtest step ("continue / refine: <note>")**
   - **What:** after each auto playtest, pause with a question. "Refine" text goes straight into `forge correct`.
   - **Why:** it turns every human glance into a Mubit training example with zero extra UI.
   - **Smallest version:** add an `--ask` flag on improve/iterate that blocks on stdin or an MCP reply after each round, and maps the reply to a `correct()` call.
   - **Works without real players:** yes.
3. **Cosmetic-only autonomous "juice" loop**
   - **What:** a safe autopilot mode limited to particles, SFX, camera and lighting that never touches models, modules or logic.
   - **Why:** low risk of regressions, high perceived quality, and it can run nightly.
   - **Smallest version:** add `forge autopilot --mode juice` with a file allowlist (VFX/SFX client scripts only). Reject any diff outside it and verify with an existing swarm smoke run.
   - **Works without real players:** yes.
4. **Next-move suggestions after each job**
   - **What:** end every build or fix with 3 clickable next tasks taken from the gap finder.
   - **Why:** it keeps the creator in the loop and gives free labels: which suggestion the human picks is a preference signal for Mubit.
   - **Smallest version:** print the top 3 `forge gaps` items as `forge feature <slug> "<task>"` one-liners at the end of a job, and log which one is chosen.
   - **Works without real players:** yes.
5. **Mechanics board as game memory**
   - **What:** a per-game list of mechanics (id, title, status, notes) that prompts can `@tag` and autopilot can queue.
   - **Why:** it gives orchestrate and gaps a stable unit of work, the "mechanic", and context injection per mechanic.
   - **Smallest version:** write `runs/<slug>/mechanics.json` from the designer output. Allow `@mechanic` in `forge feature`, which injects that entry into the user message.
   - **Works without real players:** yes.
6. **Prompt queue while a job runs**
   - **What:** accept follow-up requests during a running job and drain them afterwards.
   - **Why:** fewer idle humans during long jobs.
   - **Smallest version:** we already have `forge queue`. Expose `enqueue` from the Studio plugin chat.
   - **Works without real players:** yes.
7. **Per-message rollback in Studio chat**
   - **What:** an undo button on each chat turn in our Studio plugin that maps to a Forge version.
   - **Why:** it lowers the fear of bad generations, and a rejected turn is also a negative signal for Mubit.
   - **Smallest version:** tag each chat turn with the version id it created. Undo calls `rollback(slug, version)` and records `correct(..., "rejected")`.
   - **Works without real players:** yes.
8. **Creator-retention gamification (later)**
   - **What:** a daily credit roll, a liked-GIF community feed, prompt cards.
   - **Why:** it is Lemonade's engagement engine.
   - **Smallest version:** skip for the hackathon. Note it as a post-event growth lever.
   - **Works without real players:** no (it needs creators).
