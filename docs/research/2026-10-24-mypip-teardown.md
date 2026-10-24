---
title: "myPip teardown: how mypip.dev builds games, and what Forge should take from it"
date: 2026-10-24
tags: [research, competitor, mypip, reverse-engineering]
---

# myPip teardown

myPip (mypipdev.com, app at mypip.dev) is an AI game builder: you type a prompt and get a playable game.
This doc takes it apart from its public client code. It records how it works, what it ships, and
which ideas are worth bringing into Forge before the demo.

## How this was done

- **Evidence:** the public landing page (`https://mypipdev.com/`), the app shell (`https://mypip.dev/`) and
  its single production bundle `assets/main-C_QOMKg7.js` (about 4 MB, Vite build), plus `clerk-*.js` and
  `main-*.css`. Fetched on 2026-10-24 with a plain browser user agent.
- **Tooling:** REA (`rea-agents@6.7.0`, `analyze-javascript-application`) inventoried the app. Its parse
  worker ran out of heap on the 4 MB minified bundle (REA evidence
  `ev_3dc342dff8c677d22dff4a290b323a69a5c1bc0aa7e07c2bc878de631c390e3c`, `parsed_javascript_files: 0`), so
  the detail below comes from targeted string and context reads of the same bundle.
- **Scope:** client code only. No calls were made to their backend, no login, nothing behind auth. Every
  line below is marked **Observed** (seen in code or page) or **Inferred** (a reasoned guess). The server
  side (which models, which prompts, how code is validated) is **unknown**.
- Local copies are in the session scratchpad and are not committed.

## 1. Product in one paragraph

The landing page pitches "Vibe code a video game, make money online": describe a game, myPip generates it,
you preview it on your phone, then publish to app stores, consoles or social media and earn from in-game
purchases and playable ads. It compares itself to Rork, Roam and Spawn and claims a "performance score" of
400 against their 220 (a marketing number with no method behind it). It names Claude, OpenAI, Gemini, Tripo
(3D generation) and "Jev" (a typesafe.ai model) as parts of its orchestration. The home page also claims
the current model is "Sonnet 5.5".

**Pricing (Observed, landing page):**

| Plan | Price | Build credits | Remixes | Publishing |
|---|---|---|---|---|
| Pro | $20 / month | 200 | 20 / month | Mobile stores |
| Pro+ | $33 / month | 500 | 100 / month | Mobile and console |
| Premium | $199 / month | 1,000 | Unlimited | All stores incl. social media, 1:1 support |

## 2. Stack

| Layer | What they use | Evidence |
|---|---|---|
| Frontend | React SPA, Vite, React Router 6, TanStack Query, Tailwind/shadcn-style UI | Observed: `VITE_*` env block, `@remix-run/router v1.23.4` banner |
| Scaffolding | Originally built with Lovable | Observed: assets under `/lovable-uploads/` |
| Auth | Clerk (`pk_live_…`, domain `mypip.dev`), plus Web3 wallet login (Phantom, Solana) | Observed |
| Database | Supabase (Postgres + edge functions) | Observed: `lrkimhssimcmzvhliqbp.supabase.co` |
| Main API | `https://api.mypip.dev` (`VITE_API_ORIGIN`), Clerk bearer token on every call | Observed |
| Side service | `https://mypip-aikaro.fly.dev` used by the "Rebuild" / export dialog | Observed (purpose partly inferred) |
| MCP server | `https://mcp.mypip.dev/mcp` with OAuth | Observed |
| Payments | Lemon Squeezy (subscriptions), Stripe Connect (creator payouts) | Observed |
| Bot protection | Cloudflare Turnstile on generate | Observed: `X-Turnstile-Token` header |
| Realtime | Phoenix-style socket with `/api/broadcast` (Supabase Realtime client) | Observed |
| Tracking | Google Analytics, Google Ads, TikTok Pixel, Microsoft Clarity; all disabled on `/hive/*` pages because the URL is a private invite | Observed: inline comment in `index.html` |

Their own code comment cites `docs/HIVE_SESSIONS.md`, so they keep design docs in their repo the way we do.

## 3. The generation pipeline

### 3.1 Request

**Observed.** The builder calls `POST {api}/generate` with this body (built by `MYe` in the bundle):

```json
{
  "prompt": "<user text>",
  "currentCode": "<the whole current game, or omitted on first build>",
  "frame": "phone-portrait | phone-landscape | widescreen",
  "renderMode": "2d | 3d",
  "integrations": ["..."],
  "multiplayer": true,
  "generationTime": "<selected speed/length tier>",
  "useAstra": false,
  "project": {
    "id": "<project id or null>",
    "expectedVersionId": "<version the edit is based on>",
    "format": { "platform": "mobile", "orientation": "portrait", "render_mode": "3d" }
  }
}
```

Headers: `Authorization: Bearer <Clerk token>`, `Idempotency-Key: <uuid>` and `X-Turnstile-Token` for
signed-out or unverified users.

Things to notice:

- **Edits resend the full current code.** Every follow-up prompt carries `currentCode`, so the server
  regenerates or patches against the whole file. (Inferred: the game fits in one model context.)
- **Optimistic concurrency:** `expectedVersionId` stops two tabs or two Hive voters from overwriting each
  other's version.
- **Idempotency key:** a double click or a retry after a network drop can't charge two prompts.
- **Format is a first-class input**, not part of the prompt. The platform list is
  `mobile | desktop | console | handheld`, the orientation is forced to landscape for anything but mobile,
  and the default is `mobile / portrait / 3d`.

### 3.2 Job and polling

**Observed.** `/generate` returns a job. The client polls `GET {api}/generate-status/{jobId}`:

- poll every **3 s** (`xVe=3e3`), each request with a **15 s** timeout (`bVe=15e3`)
- give up after **30 min** (`wVe=30*6e4`) with `JOB_TIMEOUT` ("We stopped waiting for this build. Send
  your prompt again.")
- a 404 maps to `JOB_LOST` ("We lost this build. Send your prompt again.")
- `GET {api}/generate-active` returns the build in flight, so a reload or a second device resumes it
- `POST …/cancel` stops a build

### 3.3 The progress messages are fake

**Observed.** While a build runs, the chat shows six steps: "Analyzing app idea and requirements...",
"Planning React Native component layout...", "Setting up local state and hooks...", "Implementing UI
styles and animations...", "Adding core application logic...", "Finalizing Expo Go configuration...".
These advance on a timer from a seeded random number (`Lgt`/`Dgt`), not from server events. They also
still describe the old React Native/Expo product, not the current HTML game output.

**Takeaway for us:** Forge has *real* phase events (designer → coder → playtest → critic → fixer). Showing
them live is an honest advantage worth making visible in the demo.

### 3.4 Error codes the user sees

**Observed** (`case` labels in the bundle):

| Code | Meaning shown to the user |
|---|---|
| `NO_PROMPTS` | Out of prompts, opens the paywall |
| `GUEST_LIMIT` | Signed-out limit reached |
| `HUMAN_CHECK_FAILED` / `HUMAN_CHECK_UNAVAILABLE` | Turnstile failed: "Turn off your ad blocker or sign in" |
| `GENERATION_BUSY` | A build is already running |
| `BUILD_TOO_LONG` / `GAME_TOO_LONG` | Output exceeded the size limit |
| `BUILD_STOPPED` / `STOPPED_WAITING` | User cancelled or the client stopped waiting |
| `JOB_LOST` / `JOB_TIMEOUT` | See 3.2 |
| `MULTIPLAYER_NOT_MADE` / `MULTIPLAYER_NOT_REMOVED` | The build failed to add or remove multiplayer. "Your prompts were returned." |
| `ASTRA_UNAVAILABLE` | Premium model mode is down |
| `RESET_UNAVAILABLE` | Version reset unavailable |

The pattern is good: each failure is a stable code, a plain-language sentence, the next step to take, and
a refund of the prompt when the failure was theirs.

## 4. What a "game" is and how it's previewed

- **Observed:** the game is **one HTML document**. The preview iframe uses `srcDoc={html}` with a
  `sandbox` attribute and `referrerPolicy="no-referrer"`, and talks to the parent page through
  `postMessage` on a named channel. It also proxies `localStorage`/`sessionStorage`, so saves work inside
  the sandbox.
- **Observed:** a script tag `<script id="mypip-input-kit">` is detected in generated code. Inferred: a
  shared input/controls library injected into every game (touch joystick, keyboard, gamepad), similar to
  our prebuilt kit modules.
- **Observed:** two iframes cross-fade (160 ms opacity) when a new version arrives, so the preview never
  flashes blank.
- **Observed, legacy:** an Expo Snack embed path
  (`snack.expo.dev/embedded/…?preview=true&platform=web`) and the "Scan for instant preview via Expo Go"
  copy remain from the earlier React Native app builder.
- Routes `/play/:projectId`, `/preview` and `/test-device/:projectId` serve the game standalone; a
  `/screenshot` endpoint and `gamermedia.jpg` / `linkmedia.jpg` produce share images.
- `POST /build-web` and `/web-deploys` publish a web build; `/api/integrations/seeker/*` builds an
  Android APK for the Solana Seeker phone (`warmJobId`, `download-apk`).

## 5. Hive: crowd-built games

Hive is **myPip's** feature, read out of their bundle. It is not something we have. It needs a live
audience, which we don't have during development; section 11 has a version that works with no viewers.

This is the most interesting feature. **Observed** from the client and its UI copy:

- A host opens a session for a project: `POST /hive/sessions {projectId}` → an invite code of **12
  characters** from an alphabet without look-alike characters (`^[a-hjkmnp-z2-9]{12}$`). The link
  `/hive/:code` is the private invite.
- Anyone with the link can **watch and play**. Signed-in users can **suggest ideas** (max **200**
  characters), **like** ideas, and **vote** once per round (`PUT …/vote {round, ideaId}`).
- "The idea with the most votes gets built. You can change your vote until time's up." "If your idea
  wins, building it uses 1 of your prompts."
- Idea states: `open → in_vote → won → built`, or `lost`, `skipped`, `failed`, `removed`, `rejected`.
- The host has moderation actions (`POST …/owner`).
- The client polls the session (1.5 s and 5 s intervals, 30 s ceiling) and reconnects with 2 s / 4 s / 8 s
  backoff, showing "reconnecting" from the third attempt.
- `GET …/code` returns the current game, so every watcher plays the latest build.
- A kill switch: `HIVE_OFF` → "Hive coding is off right now."

Inferred: it's built for streamers and Discord groups. Chat suggests, chat votes, the game changes live on
stream. That's a strong viral loop.

## 6. Build from Claude or ChatGPT (MCP connector)

**Observed:** `https://mcp.mypip.dev/mcp` is an OAuth MCP server. The connectors page gives step-by-step
setup for Claude ("Customize → Connectors → Add custom connector") and ChatGPT ("Plugins → Add custom MCP
server"). Users then build and edit myPip games from inside those chats, billed to their myPip account.
There is also a Discord link (`/connect/discord`, `/discord/link`) and a chatbot connector page.

**We already have this.** Lu Min's Roblox Studio plugin builds games from chat inside Studio. That's a
stronger place for it than a third-party chat app, because the game, the playtest and the fix all happen
where the game runs. Nothing to copy here.

## 7. Retention and money features

| Feature | What it does | Evidence |
|---|---|---|
| Astra | A premium model mode branded "GPT-6 Astra", with its own allowance and usage table (`astra_usage`) | Observed |
| Daily streak | `POST /streak/sync`; days pay out bonus Astra credits or prompt multipliers ("2x"); missed days shown | Observed |
| Referrals and affiliate | `/referrals/me`, `/referrals/claim`, `/referrals/qualify`, `/invite/:code`, affiliate page | Observed |
| Gamertag profiles | `/gamertag/@handle` public profile, avatar characters (`/characters/avatar`, `/generate-character`) | Observed |
| Community and showcase | Published projects, a home-page showcase with slots, play counts, high scores | Observed: `published_projects`, `home_showcase_slots`, `game_plays`, `game_high_scores` |
| Contests | Submissions with public pages | Observed: `contest_submissions`, `/contest-submission/:id` |
| Creator payouts | Stripe Connect onboarding (`stripe-create-connect`), per-app deploy licences | Observed |
| Playable ads | "Turn any app into a playable ad" | Landing copy only, implementation not checked |
| Social filters | `/socialfilters`; Snapchat and TikTok are premium publish targets | Observed |
| Asset upload | `POST /upload-asset`, `user_assets` table, AI icon generation (`/generate-icon`) | Observed |

**Integrations catalogue (Observed):** Heap (analytics), AppLovin (ads), RevenueCat (in-app purchases),
OneSignal (push), Photon (multiplayer), PlayFab (identity/backend), LootLocker (LiveOps). Each has setup
instructions and is passed to `/generate` as `integrations`.

**Publish targets (Observed):** Apple, Android, Solana Mobile; Snapchat and TikTok (premium); "Meta
Glasses & Apple Vision" marked coming soon.

## 8. Data model (Supabase tables seen in the client)

`user_profiles`, `user_projects`, `user_sessions`, `user_assets`, `user_activity`, `published_projects`,
`home_showcase_slots`, `game_plays`, `game_high_scores`, `contest_submissions`,
`published_contest_submissions`, `app_deployments`, `app_deploy_licenses`, `social_checkout_media`,
`astra_usage`, `support_tickets`, `ticket_messages`, `admin_whitelist`. Edge functions: `profile-access`,
`project-access`, `stripe-create-connect`.

## 9. Routes

`/`, `/builder` (with `community`, `deployment`, `domain`, `integrations`, `mypips`, `pricing`, `settings`,
`affiliate`), `/play/:projectId`, `/preview`, `/test-device/:projectId`, `/hive/:code`, `/invite/:code`,
`/gamertag/:handle`, `/connectors`, `/connect/chatbot`, `/connect/discord`, `/contest-submission/:id`,
`/stripe/connect`, `/app/:id/privacy`, `/app/:id/terms`, `/socialfilters`, `/features`, `/pricing`,
`/support`, `/admin`, plus login/signup and legal pages.

## 10. Weak spots

- **Shallow output.** One HTML file per game, regenerated from the whole file each edit. No playtest, no
  critic and no automated check is visible in the client. Quality depends on the one model pass.
- **Fake progress** (3.3), with copy left over from the React Native era.
- **Marketing claims run ahead of the product:** consoles, handhelds and Unreal/Unity "graphics stack
  options" appear on the landing page but nowhere in the app's code paths I read.
- **A small surface area per game.** No persistent world, no server authority, and multiplayer only
  through Photon, which their own errors show fails often enough to need dedicated codes.

## 11. What Forge should take

Ranked by value for the demo and the judging criteria (`docs/nightshift.md`). Rule for this list: build
on what we already have, with no real players. Real players come later, once this works on its own.

1. **Synthetic Hive: our AI testers are the crowd.** We have no viewers, but we already have swarm
   testing with 10 persona testers (#128), tester reports, and the gap finder in `forge orchestrate`
   (#119). Run Hive's loop with those instead of people:
   1. After a playtest round, each persona tester proposes one idea grounded in what it just played (its
      report already names what was boring, broken or missing).
   2. The personas vote, weighted by evidence: an idea backed by counters or errors from the run beats an
      idea from taste alone.
   3. The winner goes to `forge feature <slug> "<idea>"`. The checks and the critic score the result.
   4. The outcome becomes a Mubit signal: a winning idea that broke checks or lowered the score is a
      correction, and one that shipped clean and raised the score is a positive example.

   This gives the demo a "the game decides what to build next, and learns which ideas pay off" moment
   with zero audience. Later, real players can join the same vote as one more voter type without changing
   the loop.
2. **Show real phases where they show fake ones.** Stream Forge's actual role events (designer, coder,
   Studio playtest, critic, fixer, Mubit call IDs) in the dashboard. Their timer-driven steps are the
   contrast.
3. **Stable failure codes with a next step.** Map Forge job failures (`STUDIO_UNAVAILABLE`,
   `CHECK_FAILED`, `KIT_PROTECTED`, `MUBIT_TIMEOUT` …) to one plain sentence and an action, instead of
   raw logs. Same idea as their `MULTIPLAYER_NOT_MADE` → "your prompts were returned".
4. **Idempotency key and expected version on every edit.** Forge versions games already. Rejecting an edit
   based on a stale version stops two correctors (or two Hive rounds) from overwriting each other.
5. **Format as structured input.** Platform, orientation and render mode go in as fields, not prose. For
   Roblox: mobile vs desktop controls, solo vs squad, round length. It makes generations more predictable
   and gives Mubit a clean feature to group on.
6. **Retention loops for the game, not the builder.** Streaks, a showcase, play counts and high scores are
   cheap and feed the TikTok angle in `docs/game/04-market-and-hooks.md`. Lower priority: they only pay
   off once real players exist.

Not worth copying: the chat connector (we have build-from-chat in Studio through Lu Min's plugin), Web3 wallets, Solana Seeker APK builds, the playable-ads claims, and the four
third-party trackers.

## 12. Open questions

- Which models and prompts run server-side, and whether they validate or playtest the HTML at all.
- What `generationTime` tiers map to.
- What `mypip-aikaro.fly.dev` does beyond the Rebuild/export dialog.
- How the Hive round timer is set (server config from `/hive/config`).

Answering these would need their backend or a signed-in session, which is out of scope.
