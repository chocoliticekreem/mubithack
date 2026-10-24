# PromptBlox (promptblox.ai) teardown

Date: 2026-10-24. Public evidence only: landing/marketing HTML, sitemap pages, patch notes, and 57 public Next.js chunks referenced from public pages. No login. `/create` (robots-disallowed) was not fetched. Raw files: `teardowns/promptblox/` (`pages/*.txt`, `js/*.js`).

Evidence tags: **Observed** (file + snippet), **Inferred**, **From web** (URL).

## Summary

PromptBlox is a browser-first "prompt to whole Roblox place" generator for teens 13+. You don't need Studio until you playtest. It plans a world, builds terrain, geometry, assets and Luau scripts into a JSON `GameState`, shows it in a three.js preview, lets you refine it in chat with versioned history, and exports a `.rbxlx`. It has **no Studio plugin and no live sync**. It also never runs the game in the real engine; Studio playtesting is left to the user. Its moat is a heavy harness:
- 10+ models and 60+ tools (From web: their own blog).
- A ~1,100-entry native asset catalog with LLM-readable manifests (Observed).
- Rendered-view visual review, walkability checks, executed state-machine assertions and per-build USD budgets (Observed).

They claim 80,000+ creators (Observed, landing) and were nearing 50,000 users on 2026-08-22 (From web, https://promptblox.ai/blog/the-story-of-promptblox). Founders: Kelvin Li (CEO), Leo Wang (CPO, ex-Microsoft FDE), Benny Chinvanich (CTO, ex-Amazon SDE) (Observed, `pages/promptblox.ai_about.txt`). v1.0 shipped on 2026-05-05 and v2.0 on 2026-09-25 (Observed, patch notes).

## Stack

| Item | Evidence |
|---|---|
| Next.js with Turbopack chunks | Observed: `index.html` loads `/_next/static/chunks/turbopack-30pa7vqh0793s.js` |
| Auth: NextAuth (Google, Discord, Roblox sign-in) | Observed: `32y26uqevku5v.js` `new BroadcastChannel("next-auth")`. Providers from `blog_promptblox-vs-lemonade-gg.txt` ("A Google, Discord or Roblox account") |
| Payments: Stripe | Observed: `/api/stripe/checkout`, `/api/stripe/extra-credits`; Stripe SDK paths in `24mqxdu2pxtbx.js` |
| Error tracking: Sentry 10.49.0 | Observed: `1spxyp1q3yu9m.js` `let r="10.49.0"... __SENTRY__` |
| Schemas: Zod everywhere, with `.describe()` strings that double as LLM tool docs | Observed: `14jrmeq1wd44a.js` (7.8 MB shared schema chunk), 49 describe strings, e.g. `"Semantic query to find a mesh, e.g. 'nature:pine tree'... Resolved to real Roblox asset ID automatically."` |
| LLM gateway: OpenRouter, streamed over SSE | Observed: `'A role provider is "standard" or an exact OpenRouter provider slug'`; tags `openrouter-sse/v1`, `openrouter-sse-bounded-evidence/v1` |
| Models | Observed in `14jrmeq1wd44a.js`: `openai/gpt-6-astra` (planner, effort high), `openai/gpt-6-sol` (effort medium/xhigh), `openai/gpt-6-luna`, `openai/gpt-5.6-luna` (legacy), `z-ai/glm-5.3-flash` (cheap implementer, effort low to max). GLM routes through upstream providers: tags `coreweave-zai-crusoe-baseten-gmicloud/v1` and `zai-crusoe-baseten-coreweave/v1` |
| Concept image: Google AI Studio Gemini image models | Observed: `scene-concept/v1` schema `provider:"google-ai-studio", model: ["gemini-3.1-flash-image-preview","gemini-3.1-flash-image","gemini-3.1-flash-lite-image"], maxRequests:1` |
| Preview: React Three Fiber, GLB meshes | Observed: describe `"Drives BOTH the runtime terrain-generation Luau snippet and the R3F <TerrainMesh> preview"`; `1j-fexxhqkpkq.js` decodes `e.glbData` into `model/gltf-binary` blobs |
| Storage: Postgres-like rows with a GLB mesh cache | Observed: `"UUID of the mesh_cache row holding the GLB. When set, persistProject strips inline glbData before INSERT"` |

Model routing presets (Observed, `14jrmeq1wd44a.js`): `astra-high-plan-low-implementation/v1`, `astra-plan-glm-implementation/v1`, `astra-plan-sol-implementation/v1`, `light-luna/v1`, `all-luna-max/v1`, `twenty-minute/v1`. **Inferred:** each build level picks a planner model and effort plus an implementer model and effort. A strong model plans, and a cheaper one (GLM flash or Luna) implements. Light builds probably use `light-luna/v1`.

## Web-to-Studio pipeline

- **There is no live pipeline.** The output is a downloadable `.rbxlx` (also `.rbxm` from the editor). Observed: the pricing table rows `".rbxlx export" Included` and `".rbxm export" Available in editor` (`pages/promptblox.ai_pricing.txt`). The FAQ says: "download the .rbxlx place file and open it in Roblox Studio" (`index.txt`).
- **Changes don't round-trip.** "Edits you later make by hand in Studio do not sync back into PromptBlox" (Observed, `blog_promptblox-vs-lemonade-gg.txt`).
- **Intermediate representation: a flat JSON `GameState`.** Observed describe strings:
  - "Flat list of all instances. Hierarchy built via parentId references."
  - `Script` nodes with "Where script lives: ServerScriptService, StarterPlayerScripts" and "Luau source code".
  - `Layout` nodes that call macro functions: "'enclosed-room', 'road-with-houses', 'obby-course', 'perimeter-walls', 'scatter-props', 'arena-ring'".
  - Tool grips, terrain config, StarterPack.
  - "Native model placement bindings. Preview Parts are replaced by their complete native hierarchy on export."
- **Scene program DSL.** Observed: `pipeline: "scene-program"` with AST limits `maxAstNodes, maxRepeatCount, maxExpansionDepth, maxExpandedNodes, maxParts`. **Inferred:** the LLM writes a compact procedural scene program (with repeat and expand) that compiles into instances, not thousands of raw parts.
- **Import goes the other way.** You can upload an `.rbxlx` of up to 25 MB, and unknown items survive verbatim. Observed describe strings: "The entire <Item>...</Item> block from the source rbxlx, verbatim." and "Count of Roblox classes the importer did not recognize at all (logged + dropped)".
- **Optimistic concurrency.** Observed in `21us0sssgudam.js`:
  - `PUT /api/projects/${id}/rules` with `{expectedVersion, expectedRevisionHash, changes, operationKey}`; a 409 means `stale_revision`.
  - `POST /api/projects/${t}/versions/${e}/restore` with `{expectedVersion}`.
  - Pending operations are kept in sessionStorage under `promptblox:gen-v2:pending-operation:v1`.

## Agent loop & self-testing

PromptBlox validates heavily **without** running Roblox. Pipeline stage tags (Observed; 273 versioned tags in `14jrmeq1wd44a.js`):

- **Plan:** `scene-design/v1`, `scene-construction-plan/v1`, `scene-gameplay-plan/v1`, `scene-shared-contract/v2` (a contract between the world and gameplay agents) and `planned-spawn/v1`.
- **Player journeys schema.** Observed: `player-journeys/v1` has `{firstAction, coreLoop[], progression, failureRecovery, replay}`. Each field is `{intent, actionIds[], entityIds[], stateIds[]}`. **Inferred:** the planner must name the first action, core loop, fail and recover, and replay, and tie each to concrete entities and actions that later checks reference.
- **Executed assertions.** Observed: scenario kinds are:
  - `module-transition`: `scriptId, exportName, initialState, steps[{input, expectedState}]` (1 to 16 steps).
  - `roblox-engine`: `procedure[] (text), expected (text)`.

  Results are `interaction-evidence/v1` with status `observed|failed|untested` and scope `pure-module-transition|roblox-engine`. **Inferred:** pure Luau ModuleScript state machines run in a sandboxed Luau VM server-side and are diffed against the expected state. Engine-level scenarios are written down but often stay `untested`, because they don't run Roblox. Their own docs say "A scene preview shows the layout; it does not prove that the gameplay works" (Observed, `guides_fix-broken-game.txt`).
- **Luau compile gate.** Observed: `gameplaySyntax: "luau-compile/v1"`, `scene-syntax-only-recovery/v1`, `one-shot-validation-repair/v1`.
- **Walkability and playability.** Observed: `scene-playability/v1..v3`, `WALKABILITY_METHOD: "voxel-walk/v1"|"voxel-walk/v2"`, spawn roles `["player","spawn","anchor","point","checkpoint"]` and an agent box `[6,1,6]`. **Inferred:** they voxelise the scene and flood-fill from spawn to check that objectives are reachable on foot.
- **Visual critic with targeted views.** Observed:
  - `scene-review-observation-request/v1 {revisionHash, reason, intents}` with "Request at least one explicit view".
  - `TargetedViewSchema` has `cutaway {mode: "none"|"above-plane", removedPartIds}`, `svg`, and `image {mimeType, base64}`.
  - `three-scene-observation/v1 {status: "rendered", viewId, sceneDigest, rendererBundleDigest, imageDigest}`.

  **Inferred:** the reviewer model asks for specific camera views (including cut-away roofs and SVG plans), a headless three.js renderer produces them, and the reviewer critiques what it sees (`scene-construction-critique/v1`, `scene-construction-correction-plan/v1`, `scene-construction-gameplay-correction/v1`).
- **Review cadence.** Observed: `FINAL_REVIEW_ONCE: "final-once/v1"`, `NO_MODEL_REVIEW: "none/v1"`. Cheaper levels skip the model review.
- **Refinement.** Observed: the "coherent refinement profile requires graph context, touched review, design ledger, adaptive gates and bounded schema repair together". That means:
  - `game-graph/v1` retrieval of the relevant subgraph
  - `graph-touched/v1` review that only checks touched nodes
  - `design-ledger/v1` memory of decisions
  - `request-scale/v1` intent sizing
  - `refinementReadRounds` capped at 0 to 4

  This matches the patch note v1.2.0: "make the candy shop bigger resizes the shop. It no longer repaints the entire map" (Observed).
- **Budget-aware pausing.** Observed: `scene-authoring-budget/v1 {incrementMicrousd: 5e6, initialMicrousd: 75e5}`, with pause reasons `insufficient_budget|unconfirmed_cost`. **Inferred:** each build starts with a $7.50 LLM-cost budget and pauses in $5 steps. That pause is the "Continue build" UX in the v2 notes.
- **Live steering.** "You can send notes in chat while the build runs" (Observed, `ai-roblox-game-generator.txt`).

## Asset generation

- **Curated native asset catalog.** It has 1,142 `integrationGuide` entries (Observed count). Each entry is a `native-asset-package/v1` manifest with:
  - `bounds`, `partCount` and a `placement.origin` rule
  - a `scale` parameter
  - `capabilities` such as `interactive-door` (164), `native-audio` (162), `click-operated` (118), `human-driving` (14) and `spawn` (14)
  - a prose `integrationGuide` for the LLM, e.g. "Do not recreate the asset or add a competing controller. Only documented capabilities and operations are supplied"

  Example: `wooden-door-02` "Openable Wooden Door with Deadbolt ... native open/close prompt, deadbolt lock prompt and five action sounds" (Observed, `14jrmeq1wd44a.js`).
- **Semantic mesh lookup.** Observed: "'nature:pine tree' ... Resolved to real Roblox asset ID automatically", with `asset-discovery/v1..v7` and `scene-asset-library/v1..v19` (19 revisions).
- **AI textures.** Observed: "Natural language description of the texture to generate. E.g. 'worn brick wall with moss'", with the URL "Filled in after image generation".
- **Concept image first.** A single Gemini image anchors the build visually (Observed, schema; About page: "One concept image guides construction").
- **Procedural terrain.** Real voxel terrain from noise parameters (octaves, persistence, lacunarity, hillIntensity); Observed in `14jrmeq1wd44a.js`.
- **v2 assets.** v2 added 84 assets (trees, rocks, 4 cars) (Observed, v2 notes). v1.3.0 "No more trees" fixed the decoration agent using trees as filler "in the middle of concrete roads, inside buildings" (Observed, patch notes).

## Pricing/community

- **Plans** (Observed, `pages/promptblox.ai_pricing.txt`). Allowances reset every week, even on yearly plans:

  | Plan | Price | Usage | Build levels |
  |---|---|---|---|
  | Free | $0 | small weekly allowance | Light |
  | Lite | $9.99/mo | 1× | Light |
  | Pro | $15.99/mo | 2× | Light, Medium |
  | Max | $35.99/mo | 5× | Light to High |
  | Ultra | — | 15× | all levels incl. Ultra |
  | Ultra+ | $200/mo | 30× | all levels incl. Ultra |

- **Credit packs** never expire: 400 for $10, 1,100 for $25, 2,400 for $50, 5,000 for $100.
- **Discord bonus:** 50 extra credits for posting your username in `#usernames-for-credit-bonus`.
- **Queue priority by tier.** "Standard / Priority / Front of the build queue" (Observed). "Free access also has shared capacity limits" (Observed, v2 notes).
- **Upsell plumbing.** `/api/offers/build-upgrade`, `/api/offers/subscription`, `/api/user/usage-reset-reminder` and `/api/pricing/track` (Observed, chunks).
- **Community.**
  - An Explore gallery of opt-in shared games. The concept image passes an automated check before it is listed (Observed, landing FAQ).
  - A mods/remix surface: `/api/mods/${id}?fields=metadata` (Observed, `2fzf6knk34-6c.js`).
  - In-app feature-request and bug-report endpoints.
  - Discord with roughly 1,400 members (From web, https://discord.com/servers/promptblox-ai-1499260814815920228; the number is unverified and looks stale next to the 80k claim).
- **SEO.** Over 80 sitemap pages: "X maker" per genre, comparisons against every competitor including Lemonade, and monetisation guides (Observed, `sitemap.xml`).

## Notable UX

- **Build levels** (Light, Medium, High, Ultra) are separate from plans. The user picks quality per build (Observed, v2 notes).
- **Build timeline and "Animate the Build"** replay construction. A live Activity feed shows parallel "Environment / Structures / Gameplay" agent lanes, and the landing shows per-lane task lists like "Shape the desert ruins" (Observed, `index.txt`).
- **Game Graph** shows areas, objects and systems as a graph, both for the user and for edit retrieval (Observed, v2 notes).
- **History.** One-click undo of refinements, and memory of earlier versions ("Add in the buildings from before") (Observed, v1.3.2).
- **Prompt hygiene.**
  - A copyable Prompt Guide in Markdown for ChatGPT or Claude.
  - An 800-character prompt limit.
  - The repair prompt template "Where / Observed behavior / Expected behavior / Preserve" (Observed, `guides_fix-broken-game.txt`).
  - "If it can't understand what you meant, it asks instead of doing nothing" (Observed, v1.2.0).
- **3D inspector** in the browser preview: drag to orbit, plus 9 showcase scenes (Observed).

## Weak spots & user complaints

- **No engine-verified gameplay.** Their own docs push all real testing onto the user in Studio ("Can I play the game in the browser preview? ... Use Roblox Studio to test avatar movement, collisions, scripts and multiplayer") (Observed, `ai-roblox-game-generator.txt`). `roblox-engine` scenarios can end up `untested` (Observed).
- **One-way export.** Studio edits never come back (Observed). Teams that iterate in Studio fall out of sync.
- **Visual and prompt fidelity were the top complaints.**
  - "the generated game did not always match the concept image" (Observed, v2 notes).
  - Trees spawned inside buildings (Observed, v1.3.0).
  - Refines repainted the whole map (Observed, v1.2.0).
  - Big-world refines "silently failing" (Observed, v1.2.0).
- **Cost opacity.** v2 moved from fixed per-build credits to a usage-based allowance with "no fixed price per game". Builds can pause for budget (Observed). Free capacity can be "temporarily unavailable" (Observed).
- **No multiplayer validation, no live ops, no players or analytics loop.** Analytics is only a guide page (Observed, sitemap).
- **Thin public complaint record.** Web search found no Reddit or DevForum threads (From web; searches returned only SEO pages). Testimonials are kid Discord quotes (Observed, landing).

## How Forge differs

| Axis | PromptBlox | Forge |
|---|---|---|
| Where code lands | JSON GameState, exported as `.rbxlx`; no plugin | Live in Studio via our plugin, bridge and file sync |
| Runtime verification | Luau compile, pure-module assertions, voxel walkability, rendered-view critic; **no engine run** | Headless engine plus real Studio playtests, 10 AI persona swarm testers, gap finder |
| Learning | Fixed harness; pipeline versions bumped by hand (build-fast v1..v27) | Every LLM call goes through Mubit; human corrections become model updates |
| Assets | ~1.1k curated native packages with capability manifests, AI textures, Gemini concept image | Prebuilt kit modules, GameAssets |
| Live ops | None (export and leave) | Battle pass, cosmetics, monetisation, autopilot, versions and rollback |
| Audience | Teens with no Studio, browser-only, even on Chromebook and phone | Builders with Studio |

## Cherry-picks for Forge

1. **Player-journeys contract**
   - **What:** make the designer emit `player_journeys = {firstAction, coreLoop[], progression, failureRecovery, replay}`, with each step naming entity, action and state ids.
   - **Why:** it gives the swarm testers and the gap finder a typed checklist. Each journey step becomes a tester goal plus a counter that must move.
   - **Smallest version:** add the block to the designer's user message (not the system prompt, to avoid a Mubit task reset). Have autopilot assert that every `stateId` maps to an existing attribute or counter, and have each persona tester try `firstAction` within N seconds.
   - **Works without real players:** yes.
2. **Executed module-transition assertions**
   - **What:** for each pure ModuleScript, the coder writes `{exportName, initialState, steps[{input, expectedState}]}`, and we run it headless.
   - **Why:** it catches logic bugs before a playtest, cheaply, and the result is deterministic Mubit training signal.
   - **Smallest version:** we already have a headless engine and `luau`. Add a `forge check-modules` step that runs the scenarios from a JSON next to each module and feeds failures to the fix loop.
   - **Works without real players:** yes.
3. **Targeted-view visual critic**
   - **What:** let the critic ask for named camera views (spawn POV, top-down, cut-away roof, objective close-up) instead of one screenshot.
   - **Why:** it is their main fix for the "doesn't match the concept" complaint, and our critic reads screenshots too.
   - **Smallest version:** add a `request_views([{name, cframe, hideTag}])` tool backed by our Studio screenshot path (Studio only for screenshots, per #146). Cap it at 4 views per round.
   - **Works without real players:** yes.
4. **Voxel walkability pre-check**
   - **What:** flood-fill from spawn over the walkable surface to prove that every objective and checkpoint is reachable before a swarm run.
   - **Why:** it is cheaper than burning 10 AI testers on an unreachable objective, and it gives the gap finder a hard signal.
   - **Smallest version:** use a headless-engine script with `PathfindingService:CreatePath` from the spawn to each tagged objective, and report unreachable tags.
   - **Works without real players:** yes.
5. **Asset manifests with capabilities and an integration guide**
   - **What:** give each kit module and asset a manifest: bounds, origin, scale param, capabilities, and a "do not add a competing controller" guide.
   - **Why:** it stops the LLM from rewriting door or vehicle logic that the kit already provides, which matches #147 "forge fix never edits prebuilt kit modules".
   - **Smallest version:** write a `kit/manifest.json` per module and inject only the matched manifests into the coder's user message.
   - **Works without real players:** yes.
6. **Per-build USD budget with pause and continue**
   - **What:** set a micro-USD budget per job, pause on overrun, and continue from the retained state.
   - **Why:** autopilot and orchestrate can run away. Mubit call logs already have cost.
   - **Smallest version:** add `--budget-usd` to autopilot. Sum the cost of Mubit calls and stop with a resumable checkpoint.
   - **Works without real players:** yes.
7. **Repair-prompt template for `forge correct`**
   - **What:** structure corrections as Where / Observed / Expected / Preserve.
   - **Why:** cleaner correction notes make better Mubit training examples, and "Preserve" prevents collateral edits.
   - **Smallest version:** add optional `--where --expected --preserve` flags on `forge correct` and pack them into the note.
   - **Works without real players:** yes.
8. **Game Graph scoped refinement**
   - **What:** retrieve only the touched subgraph and review only the touched nodes for a feature or fix request.
   - **Why:** it fixes the "make the shop bigger repaints the map" class of bug and cuts tokens.
   - **Smallest version:** build a tag/folder/file graph from `game/`, select the files whose names or tags match the request, and pass only those to the coder.
   - **Works without real players:** yes.
