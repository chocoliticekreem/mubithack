---
title: "Teardown: Rork (rork.com)"
date: 2026-10-24
type: competitor-teardown
method: public HTML + 135 public JS chunks from rork.com (no login), public docs at docs.rork.com (llms.txt index + 20 .md pages), web search
---

# Rork teardown

Evidence tags: **[O]** Observed in public client artifacts (file + snippet), **[I]** Inferred, **[W]** From web (URL).
Raw artifacts: `teardowns/rork/` (`index.html`, `js/` 135 chunks, `keys_en.txt` = 5,506 English i18n keys extracted from a locale bundle, `docs/` 20 doc pages, `games.html`, `asr.html`).
Scope note: only the signed-out landing bundle and public pages were fetched. The editor route (`/p/...`) is disallowed in robots.txt and requires auth, so editor-only chunks (tool renderers) were not read. The i18n catalog and a dev feature-flag registry ship in the landing bundle anyway, which exposes most of the editor surface.

## Summary

- Rork is a chat-to-app builder: native iOS (SwiftUI, "Rork Max"), Android (Kotlin/Compose), and web (React + Vite). Games are a marketed vertical: SpriteKit / RealityKit on iOS, HTML canvas or three.js + React Three Fiber + Rapier in the browser. [W docs.rork.com/games/build-a-game.md]
- Each project is a Cloudflare Agents SDK Durable Object (`agent:"project-do"`) reached over a WebSocket at `api.rork.com/project/{id}/ws`. The agent runs in a per-project sandbox with headless Chromium, a "project desktop", and a cloud iOS simulator it can drive. [O]
- Every agent turn is a git commit plus chat history. "One answer = one version". Undo, revert, edit-and-retry, and per-turn diff all come from that. [O + W docs/features/undo-and-history.md]
- Their differentiator for 2026 is **post-build verification**: Browser QA (`verifyWebApp`, `webTest`), "Simulator Use" (the agent drives the simulator), an **AI App Store Reviewer** made of 5 parallel rule-scoped reviewers, and a vision-model art reviewer that repaints once on failure. [O]
- Money: $15M seed (Left Lane, Peak XV, True, Goodwater, a16z Speedrun). [W https://pulse2.com/rork-15-million-raised-for-ai-mobile-app-creation-platform] Pro $20/mo (100 credits), Max from $200/mo (1k to 10k credits). [W docs/introduction/subscriptions.md]

## Stack

| Layer | Finding | Tag |
|---|---|---|
| Frontend | Next.js with Turbopack (`/_next/static/immutable/chunks/turbopack-2_04ewhudzrza.js`), React compiler memo cache (`Symbol.for("react.memo_cache_sentinel")`), Radix / Base UI, nuqs | [O index.html, chunks] |
| Hosting | Vercel (`dpl_7JsWnwqSzAs6NmunkVfkNFoBX2bL` in image URLs, `va.vercel-scripts.com`) | [O index.html] |
| API | tRPC over `/cf-api/trpc` with `methodOverride:"POST"` and bearer token | [O 0y3rw-ju306kq.js: `url:"/cf-api/trpc",transformer:d.f,methodOverride:"POST"`] |
| Second tRPC client | `${base}/trpc` with a special batch link for `git.bundles.restore` (maxItems 1) | [O 2w_usdp_j_8zu.js: `condition:e=>"git.bundles.restore"===e.path`] |
| Hono RPC | `g.api.models.$get()` = public model catalog, staleTime 300 s | [O 1on_ehosqpsap.js: `queryKey:["models","list"],queryFn:v,staleTime:3e5`] |
| Realtime | Cloudflare Agents SDK (`cf_agent_state`, `type:"rpc"` frames over partysocket) | [O 1on_ehosqpsap.js@68788] |
| Git / storage | `git.rork.com`, `r2-pub.rork.com`, `rork-git-router.rork-direct.workers.dev` (Cloudflare Worker + R2), images via `/cdn-cgi/image/` | [O 21o7cfkzb6vgn.js@65718] |
| Auth / DB | Supabase (`*.supabase.co` project host present; user ids called `supabaseUserId`) | [O 1on_ehosqpsap.js `t.data.supabaseUserId`] |
| Simulators | Limrun (cloud iOS sim + Xcode sandboxes); preview "real iOS Simulator running on a Mac in our cloud, streaming ... over the same low-latency protocol behind FaceTime" | [O flag `limrun-swift-builds-enabled`; keys_en.txt] |
| Analytics | PostHog proxied via `toolkit.rork.com/relay-GnBZ/`, Amplitude via `amp.rork.com`, Plausible, Sentry, GTM, Meta/TikTok/Snap pixels, Tolt affiliates, Intercom | [O 2xhykuzevmfk8.js@7858, @191948] |
| Payments | Stripe; RevenueCat integration inside generated apps | [O hosts; keys_en.txt] |
| Docs | Mintlify, exposes `llms.txt` | [W docs.rork.com/llms.txt] |
| Public keys | PostHog and Amplitude project keys are in the bundle (values not recorded) | [O] |

## Generation pipeline

1. **Create**: tRPC `projects.create`, `projects.getUploadUrl` (attachments), `projects.getGitToken`. [O procedure names grepped from chunks]
2. **Send a turn**: `project.chat.sendMessage.mutate({projectId, requestId, options:{isMobile, preferredModelName, planMode, designMode, designDirectionSelection, exitDesignProposal, testDesignProposalCheckout, selectedAppPath, interfaceLanguage}, inputMessage:{message, attachments}, consumeFollowUpSuggestion...})`. [O 0stmdgrrbdub0.js@13197]
   - `preferredModelName` is `undefined` when the picker says "auto". Auto "picks the model and the reasoning effort for each message". [O + W docs/features/agent-modes.md]
   - Voice: `project.chat.transcribeAudio` writes text into the composer, never sends audio straight to the agent. [O + W]
3. **Queue + steer while the agent runs**: `project.chat.queueMessage`; agent RPCs `removeFromQueue`, `reorderQueue`, `resumeQueue`, `updateQueuedMessage`, `steerQueuedMessage`. Steer = "send one into the RUNNING agent turn at its next step boundary". A failed turn sets the queue to **Paused** "so nothing runs on top of broken work". [O 0stmdgrrbdub0.js@14860, flag `steering-enabled`; W agent-modes.md]
4. **Stream model**: WebSocket per project. Server frames: `mtv:state` (full serialized store slice), `mtv:patches` (patch list, batched client-side in a 50 ms window), `finish` (carries `snapshotId`, `stopped`, `withError`, `resolvedModelName`), `chat-recovery`, `refetch-messages`, `asset:updated`, `simulator-auth-completed`, `app-auth:open-popup`. [O 1on_ehosqpsap.js@13604: `new f.x({windowMs:50,onFlush:...applyAuthoritativeMessageStatePatches`]
   - Other agent RPCs: `getRuntimeLogs(100, cursorId)`, `fetchAgentLogs`, `recoverChat`, `stopMessage`, `clearFailedInput`, `clearLastFailedMessage`, `storeWebPushSubscription` (push notify when a turn finishes). [O]
5. **Turn UI**: progress lines "Explored 7 files", "Made 9 actions", "Running checks", "Building app", "Ran web tests". [W agent-modes.md; O keys_en.txt]
6. **Modes**: Build (default), Plan (read-only tools, max 2 rounds of batched Questions cards, then a plan with screens, Features, Design, Flow, and **Goals = what done looks like for hard parts**, saved to `.rork/plans/`), Design (3-4 drawn screens, contract in `.rork/DESIGN.md`). [W docs/features/plan-mode.md, agent-modes.md]
7. **Sandbox**: one per project, cold start mitigated by "Sandbox Warm-Up: resume the project's saved sandbox ... if it sat idle for over an hour". Context compaction at 150k ("instead of the 100k target and 80% of the model's real limit"). [O flags in 30hti4hvxr6j_.js]
8. **Verify** (flags in 30hti4hvxr6j_.js) [O]:
   - `web-testing-enabled` "Browser QA": "After building a web app, the agent checks it in the sandbox's headless Chromium with verifyWebApp, and webTest runs project tests."
   - `simulator-use-enabled`: "Let the agent drive the simulator preview you have open to check a native app."
   - `desktop-use-enabled`: "Give the agent its browser and computer tools on the project's own desktop, with the Desktop tab (watch or take control)".
   - `screenshots-v2-enabled`: "Capture App Store screenshots with compiled accessibility programs and deterministic replay instead of model-driven clicking."
9. **Error repair**: runtime error dialog → "Fix with Rork" / "Fix all with Rork" / "Fix {n} with Rork"; setting "Auto-send error fixes" (on by default); TypeScript problems get a "Fix errors" button; "Build errors have been sent to the AI agent for fixing." [O keys_en.txt; W undo-and-history.md]
10. **Error-loop doctrine** in docs: revert first, then narrow scope, force the model to "Quote the line that fixes the error", switch models. [W docs/introduction/introduction/agent-loops.md]

Timings [O/W]: patch flush 50 ms; model catalog cache 300 s; simulator 0.2 build credits/minute; screen recordings capped at 60 s; "A screenshot will be generated in a few minutes". No published end-to-end generation latency.

Models: catalog is fetched live; the client shows "+{modelCount} more", "Light models only, picked automatically" (India plan), "first message" model availability, and "Plug your app into 280+ models from every major lab" for in-app AI (Rork AI Cloud). Specific model ids were not in the landing bundle. [O keys_en.txt; W subscriptions.md]

## Artifact & engine

- Artifact is a real multi-app repo per project (one folder per platform), committed each turn, syncable to GitHub ("one commit per agent turn"), openable in Xcode. Hidden `.rork/` holds plans, design contract, chat history (`historyPath`). [W docs/features/code-and-logs.md; O "For this first version, Rork will commit {historyPath} into the selected repository."]
- Games: iOS = SpriteKit (2D) / RealityKit (3D) + ARKit + Game Center; web = HTML canvas or three.js/R3F + Rapier. Web multiplayer = generated Cloudflare Worker + Durable Object + WebSockets. Budget guidance: "roughly a thousand moving things, a few hundred thousand triangles". [W build-a-game.md]
- Preview: web preview iframe, Expo web preview, Android emulator, streamed cloud iOS simulator, Rork Max iPhone app, Rork Companion desktop app for USB install. [O keys_en.txt]
- Element Selection: click an element in any preview; Rork attaches "the element's name and where it lives in your code", not a screenshot. [W docs/features/element-selection.md]
- Runtime logs panel with levels `[log] [info] [warn] [error] [debug]`, paged 100 at a time over the agent socket. [O `u.call("getRuntimeLogs",[100,n.id])`; W code-and-logs.md]
- Crons: `rork.json.crons`, staged by "message-finish + Cloudflare deploy hooks". [O flag `user-crons-enabled`]

## Asset generation

- 3D model (about 3 credits), low poly (about 1.5), rigging (about 0.5), each animation clip (about 0.3); sprites, music, SFX, voices priced by size/length. Preview and price shown **before** spending: "Generate this 3D model?", "Add {animationCount} animations · {creditAmount} cr", "Approved {approvedCount}/{totalCount} for 3D generation". [W build-a-game.md; O keys_en.txt]
- Rig guard: "Model has too many faces for rigging. Ask the agent in chat for a lower-poly version of this model." [O]
- Output formats: USDZ on iOS, GLB on web. [W]
- Art QA: "Every hook is reviewed by a vision model and repainted once if it fails. If it still has an issue, the card shows the reviewer's note so you can judge it yourself" and "A vision model inspects every hook for the things generated art gets wrong: a misspelled headline, invented interface, a phone clipped at the wrong edge." [O keys_en.txt, Screenshot Studio]
- Screenshot Studio: reads the listing, writes a campaign brief (concept, palette, materials, typeface); "Compositions measured across 20,923 App Store screenshots". [O]
- Design references via bundled MCP connectors: Mobbin ("600K+ screens"), Appllama ("53K+ paywalls"), Google Maps; Linear, Notion, GitHub connectors behind a flag. [O 1j9zzgsi248n2.js@29447]

## Social / retention / monetisation

- Credits: build credits (agent, builds, assets, simulator minutes) vs Cloud credits (USD, the generated app's own AI/cloud usage, "at cost", auto top-up, spending limit, low-balance email). [W billing/build-credits-vs-cloud-credits.md; O]
- Free = Design mode only (5 credits/day, 35/month in major markets, 5 elsewhere); building needs Pro. Classic "see it before you pay" funnel. [W subscriptions.md]
- Referral: credits when a friend starts a paid plan; RevenueCat link "earn up to 1,000 free credits based on your app revenue"; "$100 free for App Store Search Ads"; affiliates via Tolt. [O keys_en.txt]
- "Rork Stars Leaderboard", "STREAK", "Founders" showcase, "Games people built in Rork", Discord tester pool ("Find testers on Discord"). [O keys_en.txt; games.html]
- Collaboration: Editor/Viewer, comments, presence, "only one message runs at a time"; Clone project (incl. "Experimental clone", "Admin-only cache-based clone path"). [W collaborate/share-a-project.md; O]
- Publishing: App Store (TestFlight invites, submission tracking, App Store Connect analytics), Google Play (internal → closed → open → production with staged rollout), web publish + custom domains. [O keys_en.txt]
- Post-launch: App Store Connect analytics, crash rate, "Auto-summarize long user reviews into a few highlight bullets", "Started fixing App Store rejection", "Started fixing TestFlight feedback". [O]

## Notable UX

- Chat **is** the version list; Undo (last), Revert (earlier, confirmed, irreversible), Edit message = revert + retry; per-answer `⋯` shows model that ran, credits used, context size; full-screen per-turn diff. [W undo-and-history.md]
- Stop mid-turn saves partial work, "A build that never finished is not charged". [W]
- Questions arrive as one batched card with visual options (palettes as swatches); at most two rounds. [W plan-mode.md]
- Price-before-spend cards for every expensive asset. [O/W]
- Reviewer coverage honesty: "Reviewer coverage is incomplete for this run. This area is unverified." and "Some deterministic checks could not be verified for this run." [O keys_en.txt]
- AI App Store Reviewer: five reviewers (Safety 1.x, Performance 2.x, Business 3.x, Design 4.x, Legal 5.x), "each one knows only its own rules", reads code plus live App Store Connect data, cites file paths ("app/(tabs)/insights.tsx renders hard-coded sample numbers"), outputs rejections / warnings / passed / fixed and "Estimated outcome: Likely to pass". Advisory, never blocks. [W https://rork.com/app-store-reviewer, docs/ai-app-store-reviewer.md]

## Weak spots

- Their own docs admit the agent loops and hallucinates, and push revert plus model-switch to the user. [W agent-loops.md]
- Multiplayer is "no multiplayer product that you switch on"; real-time online "expect a few rounds of iteration". [W build-a-game.md]
- Verification is mostly web-first (Browser QA). Native checking depends on simulator minutes billed to the user (0.2 credits/min). [O/W]
- No player-behaviour testing: checks are compile, runtime errors, web tests, store-policy review. Nothing simulates players or judges fun. [I from absence in flags and i18n]
- Revert is irreversible and env vars are not versioned. [W undo-and-history.md]
- Android games "not a documented path". No engine import (Unity/Unreal). [W]

## Cherry-picks for Forge

| # | What | Why it helps Forge | Smallest version on top of Forge | Works without real players? |
|---|---|---|---|---|
| 1 | **Rule-scoped parallel policy reviewers** (their AI App Store Reviewer) | Roblox moderation and Experience Guidelines are Forge's version of App Store rejection. One reviewer per rulebook beats one generic critic, and every finding cites a file. | New Mubit task per section (Community Standards content, Maturity/Content questionnaire, monetization rules for paid items/loot-box style mechanics, DataStore/HTTP limits, copyrighted IP). Run in parallel over `runs/<slug>/game` and output rejection/warning/pass with file:line. Feed findings to the existing fixer. Advisory only. | Yes |
| 2 | **"Coverage incomplete = unverified" reporting** | Forge's done bar can over-claim when a tester or check didn't run. Rork labels gaps explicitly. | In `done.py`, each area reports `verified / unverified (why)` and READY requires zero unverified critical areas. | Yes |
| 3 | **Steer a running turn at the next step boundary + pause queue on failure** | Long autopilot/orchestrate jobs; a human correction mid-run is today either a cancel or a wait. Steering at step boundaries is also a clean Mubit correction event. | In `orchestrator`/`loop`, check an inbox file between steps and append it to the next role's user message; on a failed step set the job queue to paused instead of running the next job. | Yes |
| 4 | **Element selection → code location** | Lets a human point at an in-Studio Part/GUI and get an edit scoped to the script that owns it. The edit lands on the right file, not a look-alike. | Studio plugin: on selection, send `instance.GetFullName()` plus tagged attributes and the owning script path (from CollectionService tags / kit map) as a chip in the chat message. No screenshot needed. | Yes |
| 5 | **Per-turn version = commit + chat, with "Edit message = revert + retry"** | Forge has versions/rollback; tying each version to the exact prompt/turn makes corrections replayable and gives Mubit cleaner before/after pairs. | Store the triggering message and role-call ids in the version record; add `forge retry <version> "<new wording>"` = rollback to parent + rerun. | Yes |
| 6 | **Per-turn receipt: model, credits/tokens, context size, diff** | Makes cost and drift visible on the dashboard; useful for the demo ("this correction cost X and changed Y files"). | Dashboard row per version: Mubit task, tokens, files changed, link to diff. Data already in `calls`/`versions`. | Yes |
| 7 | **Vision reviewer that repaints/regenerates once, then shows the note** | Forge's screenshots from Studio can be checked for obvious visual failures (UI clipped, text overflow, empty scene) with a bounded retry so it cannot loop. | After Studio screenshot: one vision-model check with a fixed checklist; on fail, one fix attempt; if still failing, attach the reviewer note to the gap list instead of retrying. | Yes |
| 8 | **Price-before-spend cards for expensive generation** | Mesh/texture generation via Studio MCP and long swarm runs cost time; previewing cost keeps autopilot from burning budget. | Before `generate_mesh` or a 10-persona swarm, autopilot logs estimated cost/time and requires the budget gate in `ledger.py` to approve. | Yes |
| 9 | **Plan mode "Goals = what done looks like for hard parts"** | Gives each feature an explicit acceptance check that the swarm testers can verify. | Planner output gets a `goals:` list per hard feature; each goal compiles into a scenario/check that `done` runs. | Yes |
| 10 | **Error-loop doctrine as an automatic policy** | Rork tells users to revert, narrow scope, switch model after repeated failed fixes. Forge can do it itself. | In the fix loop: if the same check fails 2 times after "fixes", roll back to last green version, rerun the fixer with a narrowed file allow-list, and on the third failure switch the Mubit model/route. | Yes |
