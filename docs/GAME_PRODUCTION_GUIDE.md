# Game production guide for Forge and MuMake agents

Version: 1.0. Last reviewed: 2026-10-24.

Use this guide when designing, building, testing, reviewing or improving a Roblox game through Forge, a chat/MCP agent, MuMake or another native Studio surface. Its purpose is to produce complete player experiences and spend effort on consequential improvements. Every AI call in the game-production workflow must go through Mubit.

This is an operating guide, not a claim that every rule below is enforced by the current software. Follow the guide using available tools; report unsupported requirements and missing evidence. Do not invent a tool, execute a documentation example as a supported configuration schema, or label an untested game complete.

## Read the relevant parts before acting

Always read sections 1 through 4. For a new game also read sections 5 through 8. For a change or bug read sections 9 through 11. For model learning read section 12. Read only the game families and capability packages that apply. Sections 13 through 16 cover the existing tools, evidence, examples and handoff.

| Question | Section |
|---|---|
| How must AI calls run? | [1. Non-negotiable operating rules](#1-non-negotiable-operating-rules) |
| What are we building and what does complete mean? | [2. Project profile](#2-project-profile) and [3. Development stages](#3-development-stages) |
| What should we do next? | [4. Priority policy](#4-priority-policy) |
| How should Roblox systems fit together? | [5. Architecture foundations](#5-architecture-foundations) |
| What matters for this genre? | [6. Game-family recipes](#6-game-family-recipes) |
| What checks do trading, saving or purchases add? | [7. Capability packages](#7-capability-packages) |
| How do we build features and levels? | [8. Build procedure](#8-build-procedure) |
| What evidence proves the work? | [9. Testing and evidence](#9-testing-and-evidence) |
| How do we improve and avoid regressions? | [10. Improvement procedure](#10-improvement-procedure) |
| What should the game optimise for? | [11. Game-quality objectives](#11-game-quality-objectives) |
| What should the model learn? | [12. Model learning and evaluation](#12-model-learning-and-evaluation) |
| Which commands and records exist? | [13. Current implementation](#13-current-implementation) and [14. Evidence records](#14-evidence-records) |
| What does this look like in practice? | [15. Worked examples](#15-worked-examples) |
| What should the agent report? | [16. Handoff and stop conditions](#16-handoff-and-stop-conditions) |

## 1. Non-negotiable operating rules

### 1.1 All game-production AI goes through Mubit

This includes the director, designer, architect, feature planner, coder, level designer, patcher, fixer, test planner, AI player, explorer, critic, judge, gap finder, auditor, verifier, anomaly detector and reflector. Asset-generation AI or any future AI worker is subject to the same rule. If no Mubit-backed route exists for an AI operation, mark that operation unavailable and use an authorised non-AI alternative where appropriate.

- Use the existing Forge/Mubit client and tools. Python callers use the shared settings and `forge.llm.make_llm`, rather than constructing a parallel provider client.
- The repository currently supports Anthropic-compatible requests at `https://api.mubit.ai/anthropic` and OpenAI-compatible requests at `https://api.mubit.ai/openai/v1`, using `MUBIT_API_KEY`. Model/provider settings and approved gateway overrides come from `forge/config.py` and the workspace configuration.
- Verify the effective gateway, credentials and model before paid work. SDK compatibility with Anthropic or OpenAI does not authorise requests to those providers' direct endpoints.
- A missing key, unsupported model, gateway failure or exhausted budget must not trigger a direct-provider fallback. Preserve the work, report the blocker, or continue deterministic work that does not require AI.
- Do not substitute the chat assistant's own generated game code, level designs, test judgments or fixes for the Mubit-backed tasks. The assistant should orchestrate those tasks and report their evidence.
- Compilers, deterministic validators, scripts, saved scenarios, Studio input and telemetry are not LLM calls. They can run without Mubit. Clearly label offline test doubles such as `FakeLLM`; their results prove pipeline behaviour, not live AI quality or training.
- An MCP/plugin installation does not reroute its host chat model. If the requirement includes the host's own inference, that host must also be configured for Mubit separately. This guide cannot establish or prove that connection.
- Keep production role prompts stable. Do not edit `forge/prompts/*.md` or tester prompts to insert a game's genre, this guide, a correction or a changing checklist. Supply those in the task's user context through the existing caller. Prompt changes require an explicit task/version migration, not an incidental game fix.
- Preserve Mubit request IDs and call outcomes when the gateway returns them. A logged request proves that a request ran; it does not prove a correct result, accepted training example or improved adapter.

### 1.2 Preserve scope, ownership and the user's Studio

- Respect the current user's instructions, repository rules and authorised budget. This guide does not grant permission to publish, charge purchases, send messages, change credentials or edit another person's place.
- Identify the exact intended Studio window. Reuse an existing window when requested. Never open additional instances as a convenience when the user has prohibited that.
- Do not take over or stop a human-owned playtest. Stop a playtest the workflow owns when its work ends, including after errors and cancellation.
- Follow the repository's shared-place policy. Work in local drafts; syncing a shared published place follows its normal authorised main-branch workflow.
- Use the existing broker/leases where supported. Native and agent surfaces must not concurrently mutate the same game or Studio outside that coordination.
- Keep game code on disk as the source of truth. Use the approved sync/install path and preserve human-owned scripts. Review an unapplied patch as an unapplied patch.
- Never store Mubit keys in generated game scripts, native UI state, public reports or committed documentation.
- UI-only age/experience preferences must remain local presentation choices. Do not add them to game profiles, AI context, telemetry or training records.

### 1.3 Use evidence rather than an agent's confidence

Never claim that a game is complete because scripts compile, a critic likes the code, a button exists, a counter was manually incremented, a model said a fix worked, or an AI task returned successfully. Keep these statements separate:

1. Draft generated.
2. Code compiles.
3. Specific behaviour verified in a named environment.
4. Requested development stage satisfied.
5. Human experience evaluated.
6. A model improvement demonstrated on held-out tasks.

## 2. Project profile

Before substantial building, identify the intended experience. Generate design decisions through the Mubit-backed director/planner. Persist their approved output mechanically. Use `spec.json` and existing records as canonical sources; do not maintain contradictory copies of prices, level counts or mechanics.

For information the existing schema does not represent, a per-game `production-plan.md` may hold the profile, requirement IDs and decisions. This is a proposed documentation artifact, not a configuration file the current runtime automatically reads.

Record:

| Field | Required decision |
|---|---|
| Player promise | Who the player is, what they do, and why the experience is worth playing |
| Primary and secondary families | Select relevant recipes from section 6; hybrid games combine them |
| Core loop | Action -> feedback/reward -> meaningful decision -> next action |
| Session model | Solo, co-op, competitive or mixed; intended minimum and maximum players |
| Content model | Levels, missions, rounds, procedural content or an open world |
| State model | Session-only, saved player progress or persistent shared state |
| Capabilities | Saving, trading, purchases, vehicles, building, UGC and other applicable packages |
| Target devices | Devices/input modes actually supported, with measurable performance budgets |
| Target stage | The stage from section 3 the user actually requested |
| Scope | Required features, optional features, exclusions and constraints |
| Success conditions | Observable player outcomes and the evidence needed to establish them |
| Operating budget | Calls, time, retries, test resources and authorised stopping conditions |

Do not infer that every game needs pets, rebirths, a leaderboard, persistent progression, monetisation or endless replay. Those are design choices. Requirements come from the player's promise, creator's request and applicable integrity obligations.

If a missing decision is reversible and low impact, state an assumption and proceed. Clarify decisions that materially change the requested experience or require ungranted external authority. Do not repeatedly ask about routine implementation choices.

### Feature contract template

Create stable requirement IDs. A feature contract should include:

```yaml
# Illustrative planning format, not a currently supported engine schema.
id: shop.buy_coin_upgrade
player_outcome: Buy one affordable upgrade and immediately see its effect
required_for_stage: complete_loop
owner: server economy system
client_surface: shop panel and upgrade feedback
dependencies: [wallet, upgrade_catalog, shop_interaction]
state: saved_player_progress
invariants:
  - The server owns the price and balance
  - A rejected purchase changes no balance or ownership
  - A once-only upgrade is granted at most once
checks:
  - shop.buy_affordable
  - shop.reject_insufficient
  - shop.reject_repeat
  - shop.real_client_button
evidence_status: unknown
```

Also define inputs, outputs/events, permissions, timing, lifecycle, data migration needs, failure recovery and telemetry where relevant. A feature requiring several systems must name the integration points, not just list files to generate.

## 3. Development stages

Pick a target stage and report it explicitly. A prototype can omit planned release features, provided those omissions are visible and excluded from its readiness claim. Integrity obligations apply whenever the relevant capability is active, including during prototypes.

| Stage | Required outcome | Minimum evidence |
|---|---|---|
| Concept | Coherent player promise, scoped loop, systems and content plan | Structured profile, dependencies and acceptance criteria |
| Playable slice | A player can join, understand a goal, perform the main action, receive feedback and repeat or finish | Real player journey plus focused behaviour checks |
| Complete loop | Required mechanics connect; progression, success/failure and restart work | End-to-end journeys and acceptance checks for required features |
| Reliable game | Relevant state, economy, multiplayer and performance obligations survive adverse cases | Capability-specific integration, edge, recovery and regression tests |
| Release candidate | The requested content, devices, onboarding and optional commercial systems meet their bars | Current-version evidence for all release requirements; human review where needed |
| Live improvement | Changes improve demonstrated player outcomes without harming integrity or existing cohorts | Published analytics or human studies plus release regression evidence |

Do not assume an endless game needs a final level or a narrative game needs indefinite retention. Define completion according to its intended structure.

The current `forge done` implementation supplies a useful readiness bar. Read its actual parts at runtime; do not assume an old document's list is exhaustive. A green bar proves its implemented checks, not unimplemented requirements from this guide. Report stage-specific gaps even when the existing bar is green.

## 4. Priority policy

### 4.1 Assign the band before estimating effort

| Band | Meaning | Examples | Required response |
|---|---|---|---|
| P0 | Integrity, severe reliability or player harm | Lost saves, duplicated items, unauthorised rewards, incorrect paid fulfilment, crashes | Prevent exposure and establish a reproducible check; resolve before claiming the relevant release is safe |
| P1 | Broken core experience or a required stage blocker | Cannot join, objective unclear, required shop button dead, unreachable route, round cannot finish | Fix before adding optional mechanics or decoration |
| P2 | Meaningful depth, pacing or content quality | Repetitive stages, weak choices, missing planned mission, unreasonable upgrade pacing | Improve using genre goals and measured player evidence |
| P3 | Optional polish or extras | Decorative particles, extra idle animations, nonessential cosmetic variations | Schedule after higher bands and within the remaining budget |

A UI issue can be P0 or P1 when it changes a purchase or prevents play. Visual readability is part of functionality. An intentional obstacle or scary moment is not a bug merely because a tester failed it.

An uncertain potentially critical issue gets an investigation/test job in its risk band. Lack of evidence is a reason to seek proof, not to bury a possible save-loss or exploit problem under decorative work.

### 4.2 Order work within a band

1. Honour explicit scope and required-stage dependencies.
2. Resolve a root cause that blocks several features before its symptoms.
3. Prefer substantial player impact, wider affected scope and stronger independent evidence.
4. Prefer the smallest change likely to deliver the intended outcome.
5. Consider effort, paid-call cost, verification cost and reversibility.
6. Recheck previous attempts and rejected proposals before trying again.

Effort and low cost do not promote P3 work above P0/P1 work. Use numerical impact/confidence scores only inside an established band. A high-confidence cosmetic observation must not outrank a confirmed progression blocker.

Current gap-finder/autopilot ranking uses impact, confidence and evidence; strict P0-P3 scheduling is a policy for the orchestrating agent until it is implemented and tested in the scheduler. Do not claim that the existing score alone guarantees this order.

### 4.3 A valid improvement proposal

Every proposal must name the player problem, requirement or desired outcome, affected population, evidence, priority, likely system, minimal change, proof plan and regression risks. For uncertain proposals, name the experiment needed to decide. "Make it more polished" is not an executable improvement brief.

## 5. Architecture foundations

Use proven existing modules before generating new infrastructure. Inspect the game's architecture and the kit catalog first. Keep architecture proportional to the game; the goal is clear ownership and reliable behaviour, not a fixed module count.

| Layer | Responsibilities | Boundaries |
|---|---|---|
| Server systems | Authoritative state, rewards, economy, combat results, permissions, spawning | Validate all client requests; do not trust client prices, balances, hits or ownership |
| Client controllers | Input, camera, HUD, animations, local effects and interaction feedback | Render authoritative results; recover from rejection and delayed replication |
| Shared definitions | Typed contracts, public catalog/configuration, shared pure rules | No credentials or private server-only decisions in replicated modules |
| Persistence and transactions | Profiles, migrations, session ownership, save recovery, item/purchase integrity | Explicit failure and retry behaviour; relevant integration checks |
| Content | Level, mission, item, encounter and reward data | Validate data and references before constructing the world |
| Presentation | UI components, audio, materials, feedback, device adaptation | Accessibility/readability and performance are required outcomes |
| Observability and test seams | Domain events, counters, errors, fixtures, behaviour queries | Observe real outcomes; privileged hooks are Studio/test-only |

For a service/controller game, prefer one server bootstrap and one client bootstrap, modules with clear lifecycle/dependencies, and a single owner per system. Existing Forge consolidation uses `ServerScriptService/Services/*Service.luau`, `StarterPlayerScripts/Controllers/*Controller.luau`, and `Init`/`Start` conventions. Preserve compatible incumbent patterns or a tested template rather than migrating every small game automatically.

Architecture review must inspect:

- Startup order, readiness and partially failed boot. A spawned character does not prove the map or economy finished initialising.
- Event and remote contracts, including payload type, value, permissions, context and rate checks.
- Cleanup on player leave, respawn, round end and module restart; disconnect signals and remove owned objects.
- Bounded loops, spawned-object limits and performance at the expected player/content count.
- Replication, delayed data and interaction feedback under latency.
- One canonical source for prices, progression values and content IDs.
- Save schema versioning and how a failed load avoids overwriting good data with defaults.
- Protected human files, kit/template ownership and the smallest safe edit surface.

Do not create a new remote, acknowledgement script, UI framework or save system for each feature when an existing system can own the behaviour. Use `forge compare` and `forge consolidate` when justified; static similarity to a reference is a diagnostic, not proof of correct architecture.

## 6. Game-family recipes

Choose one or more recipes. For hybrids, combine requirements and resolve conflicting objectives explicitly. The following priorities apply after universal integrity and core-play obligations. These recipes are design guidance, not claims that Forge currently has specialised generators for every family.

| Family | Build in this order | Required proof | Optimise after correctness |
|---|---|---|---|
| Obby/platformer | Movement and recovery -> reachable course -> checkpoints -> completion -> variety | Jump/collision limits, checkpoint ownership and respawn, movers, falls, finish, promised stage count | Difficulty curve, distinct obstacles, retry friction and achievement |
| Racing/vehicles | Handling -> valid route -> checkpoints/laps -> race lifecycle -> competition | Vehicle recovery, checkpoint order, shortcut rejection, timing, network behaviour and results | Control feel, readable routes, competitive alternatives and recovery time |
| Rhythm/timing | Input and audio timing -> scoring windows -> feedback -> content | Calibration, timing windows, device/frame-rate variation and scoring consistency | Chart quality, learnability, satisfying challenge and latency tolerance |
| Competitive combat | Responsive controls -> authoritative combat -> teams/matches -> progression | Valid hits/damage, cooldowns, state permissions, team rules, respawn, latency and exploit attempts | Counterplay, skill expression, viable choices, map balance and match quality |
| Co-op missions/dungeons | Shared goal -> complementary actions -> recovery -> completion/rewards | Dependency chains, shared credit, revives, disconnects, reduced player counts and mission cleanup | Coordination, useful roles, mission variety and readable team state |
| Survival/crafting | Gather -> inventory -> craft -> threats -> recovery/persistence | Recipe costs, caps, resource regeneration, death, ownership, saving and griefing boundaries | Resource pressure, exploration, meaningful choices and recovery fairness |
| Tycoon/management/incremental | Ownership -> income -> purchase -> upgrade -> expansion | Currency accounting, affordability, duplicate actions, plot ownership, income rates and persistence | Time to meaningful upgrades, economic choices and progression pacing |
| Collection/pets/simulator | Acquire -> store -> equip/use -> improve -> unlock | Unique item identity, inventory limits, equip effects, rewards, saving and configured probabilities | Collection variety, understandable value, useful upgrades and rewarding progression |
| RPG/adventure | Core action -> quests -> rewards -> character growth -> world/content | Quest ordering, softlocks, duplicate rewards, equipment, progression and party state | Build variety, exploration, quest quality, readable goals and pacing |
| Strategy/tower defence | Placement -> enemy routes -> targeting/combat -> waves -> victory/defeat | Placement rules, valid targets, damage/economy, wave transitions and entity budgets | Strategic diversity, legible threats, viable strategies and challenge curve |
| Puzzle/story | Goal and clues -> valid solutions -> state transitions -> recovery/conclusion | Solvability, clue availability, out-of-order actions, resets, branches and softlocks | Insight, narrative clarity, discovery and pacing |
| Horror | Atmosphere/navigation -> threat rules -> objectives -> recovery/escape | Unavoidable-death bugs, AI paths, checkpoints, event timing, audio cues and shared state | Tension, anticipation, readability, recovery and human reactions |
| Social/roleplay | Join/share space -> interaction -> expression -> activities | Permissions, interaction visibility, avatar/items, sharing boundaries, disruptive behaviour and saving | Meaningful participation, expression, activities together and discoverability |
| Sandbox/building/UGC | Create -> edit -> undo -> save -> share | Ownership, edit conflicts, undo correctness, invalid data, content limits and persistence | Creative freedom, editing usability, collaboration and discovery |
| Party/round minigames | Lobby -> instructions -> round -> scoring -> replay | Join/leave during rounds, ties, AFK players, player counts, timers and repeated rounds | Fairness, variety, short avoidable downtime and social replayability |
| Educational/training | Accurate material -> practice -> explanation -> transfer | Content correctness, answer validation, progression, accessible interaction and new-case performance | Understanding, useful feedback and transfer of learning |

### Family-specific interpretation rules

- An obby can intentionally have a low success rate on late stages. Test reachability separately from human difficulty and difficulty consistency.
- A racing game should not reward invalid shortcuts to improve apparent completion time.
- Combat balance is conditional on skill, equipment and map. Do not force every measured win rate to 50% without understanding matchmaking and intended asymmetry.
- A tycoon should offer meaningful purchases; rising cash counters alone do not establish a functioning economy.
- A simulator needs an understandable acquisition/use/progression loop. More repetitive clicks or inventory items are not automatically greater depth.
- Horror needs human evaluation of tension. Treat an AI critic's emotional judgment as a hypothesis.
- Social and creative games can be valuable without a conventional win condition or linear progression.
- Educational accuracy and transfer matter more than increasing time spent or reward collection.

## 7. Capability packages

Activate a package because the game contains that capability, not because of its genre label. A package's required checks cannot be waived by choosing a different family.

### 7.1 Persistence

Prove initial load, normal save, rejoin recovery, failed load, failed save, interrupted shutdown, schema migration, concurrent session handling and bounds on stored data. Failed loads must not silently replace an existing profile with new defaults. Use isolated test data and the appropriate integration environment. In-memory Studio behaviour does not prove production DataStore reliability.

### 7.2 Economy, inventory and trading

Check zero, below-cost, exact-cost and large balances; rejected purchases; repeated/spammed actions; capacity; unique item ownership; equipped/locked items; and concurrent operations. Prices and outcomes are server-owned.

For trading, test both participants, offer changes after confirmation, cancellation, one participant leaving, failed persistence and retry. Establish no item creation, loss or duplicate ownership from partial completion. Single-player checks can establish individual rules; they cannot establish a real two-client exchange end to end.

### 7.3 Paid products and entitlements

Only include monetisation when it is part of the authorised scope. Keep paid fulfilment separate from ordinary currency purchases.

For developer products, use server-side receipt processing and durable retry-safe fulfilment. Test duplicate/retried receipts, unavailable player state, incorrect product/player, persistence failure and recovery. A closed purchase prompt is not proof of payment or a successful grant. Game passes have their own ownership/entitlement behaviour; do not treat them as developer-product receipts.

Use appropriate fixtures and authorised test environments. Do not charge a real user to prove a test or mark a mocked purchase as a verified live transaction. Follow the current Roblox documentation linked in section 17.

### 7.4 Multiplayer and shared sessions

Test intended minimum/maximum players, simultaneous actions, join-in-progress, leaving, late replication, team/instance isolation, shared reward credit and repeated rounds. Include latency and adverse timing appropriate to the mechanic. Never claim co-op, competitive or trading readiness solely from a solo playthrough.

### 7.5 Devices, input and accessibility

For every supported device/input mode, verify visible/reachable controls, input mapping, camera behaviour, readable goals/state, safe layout, interaction while moving and meaningful feedback. Set explicit device performance budgets for frame time, memory, entities and network traffic. Test on representative hardware when a simulator cannot establish the result.

### 7.6 Procedural content and levels

Validate seeds, connectivity, spawn safety, reachable objectives, required resources, difficulty constraints and cleanup. Store failing seeds and generation parameters as regression cases. Deterministic geometry validation and real traversal establish different things; use both where needed.

### 7.7 Physics and vehicles

Check ownership transitions, jitter/drift, collision, recovery from falls/flips, death/respawn, latency and stress at intended entity counts. A stationary screenshot cannot verify a moving platform, vehicle or physics puzzle.

### 7.8 Social features, creation and sharing

Test ownership and permissions, input validation, appropriate filtering/sharing rules, modification of another player's content, report/block flows where included, resource limits and save/delete behaviour. Keep the player's ability to participate and recover from disruptive behaviour observable.

### 7.9 External or platform services

Identify dependencies such as assets, badges, persistence, purchases and platform APIs. Define timeout, retry and unavailable-service behaviour. Distinguish a platform/environment failure from a game defect. Never invent asset IDs or claim that a service succeeded because a local stub returned success.

## 8. Build procedure

### 8.1 Before generating a game

1. Read the user's scope, relevant repo instructions, existing code, current tool schemas and this guide's applicable recipes.
2. Establish the project profile, target stage, allowed Studio window and budget.
3. Verify the Mubit path and tool prerequisites. Do not print credentials.
4. Generate the game design through the Mubit-backed director. Include the player's promise, loop, progression, first-session experience and required systems.
5. Map features to owners, dependencies and checks. Reuse kits/templates and existing architecture.
6. Establish the smallest useful playable slice. Build a real path through the main loop before extending optional breadth.

### 8.2 For every feature

1. Inspect the current game and record a baseline. Reuse existing events, data and UI owners.
2. Send the bounded feature contract and relevant source/evidence to the Mubit-backed planner/coder/patcher. Include the project profile and applicable rules in user context.
3. Generate the minimum change required to deliver the player outcome.
4. Compile changed code and validate affected content. Confirm systems actually boot and dependencies resolve.
5. Run focused tests for positive, negative, boundary and recovery cases.
6. Exercise the real player/client path where applicable. A private server hook test alone does not prove a menu, prompt or input works.
7. Run the affected integration and regression checks. Broaden testing when shared systems changed or evidence warrants it.
8. Keep a version and evidence record. Update the feature's status according to proof, not task completion.

If the feature cannot be tested in the available environment, retain a draft or proposal and report what remains unverified. Do not silently remove the requirement or add a test that only checks a new counter created to satisfy itself.

### 8.3 For every level, mission or content unit

Define its purpose, prerequisites, mechanics introduced, intended difficulty, route/objectives, resources, reward, completion/failure conditions and recovery. Teach, test and combine mechanics intentionally rather than repeating the same obstacle with different colours.

Prefer validated content data and tested builders over generating new infrastructure for every level. Check structural validity, reachability, required objects/resources, transitions, checkpoints, difficulty constraints and performance. Then test representative real traversal and human difficulty. Store seeds and content versions.

Do not infer whole-course completion from one reachable stage. Verify the promised content count and connections between content units. Report fallbacks or simplified generated content explicitly.

### 8.4 Bound the context for each Mubit task

Do not paste this entire guide into every call. Select the relevant rules and pass them through the existing task's user message without changing its fixed prompt. Use this compact context structure:

```text
Game and target stage:
Player outcome and requirement IDs:
Relevant families/capabilities:
Current priority and why:
Owning systems and dependencies:
Applicable invariants:
Source excerpts and existing APIs:
Baseline and evidence references:
Requested bounded change or judgment:
Required proof and regression checks:
Budget, protected files and unavailable capabilities:
```

This document is not automatically injected into the native companion's model calls. Discoverability links help the orchestrating agent; runtime callers need explicit, bounded context integration before claiming automatic adoption.

## 9. Testing and evidence

### 9.1 Test layers

| Layer | Establishes | Does not establish alone |
|---|---|---|
| Static/compile | Syntax, references and selected structural rules | Working gameplay or connected player interactions |
| Pure/unit | Deterministic logic, accounting and state transitions | Actual client/server integration |
| Headless integration | Supported boot, system and world behaviour under the harness | Unsupported Roblox services, rendering or device usability |
| Studio/client interaction | A character can perform a specific action through its real interface | All players, devices, seeds or production services |
| Multiplayer/resilience | Specified concurrent and failure/recovery cases | Every possible timing or production-scale condition |
| Human/live experience | Comprehension, challenge, satisfaction and observed cohort behaviour | Causality without an appropriate comparison and sufficient evidence |

Choose layers by the claim and failure mode. Use deterministic tests for precise rules and repeated boundaries, agent players for exploration and adaptive journeys, and human evaluation for experience qualities that automated proxies cannot establish.

### 9.2 Every test record

Record the requirement ID, game/code/content version, test/seed, environment, fixture state, action sequence, expected result, actual measured result, status and evidence paths. Record relevant tool/harness/model/prompt-policy versions for reproducibility.

Use these reporting statuses:

- **Passed:** the stated assertion was exercised and observed.
- **Failed:** the assertion was validly exercised and contradicted.
- **Unknown / not checked:** setup failed, evidence is insufficient or the required environment is unavailable.
- **Not applicable:** the capability is intentionally absent and the reason is recorded.

Map underlying tools' skip/partial/inconclusive states to an honest claim. A broken test can be corrected or retired with evidence and a replacement/coverage decision. Removing it does not prove that the game requirement passed.

### 9.3 Required test design rules

- Derive tests from intended requirements and existing contracts, not only from what the latest generated implementation happens to do.
- Include negative and boundary cases, not just the happy path.
- Observe meaningful state changes. Do not call a private grant function and claim the full client purchase flow worked.
- Reset fixtures and undo reversible changes. Use isolated fresh sessions for irreversible cases.
- A setup failure, timeout or unsupported environment is not proof of a game bug or a pass.
- Verify the player's result as well as telemetry. A reward counter can increment while no reward appears.
- For a fix, first reproduce the defect when feasible, then run the same case after the change.
- For regressions, compare like-for-like conditions and preserve previously passing important behaviours.
- Keep saved test cases distinct from training examples and held-out model evaluation cases.
- Do not weaken a test, lower a target, hide an error or alter the evidence merely to obtain a green result.

### 9.4 Failure attribution

Before choosing a fix or learning label, classify the evidence:

| Classification | Next action |
|---|---|
| Game defect | Reproduce, identify the responsible system, fix and rerun |
| Model decision error | Correct the responsible task with observation, intended behaviour and outcome |
| Test/harness defect | Correct the test/harness, then rerun the original game requirement |
| Environment/platform failure | Diagnose prerequisites or service availability; preserve unknown status |
| Design uncertainty | State the hypothesis and run an appropriate player/design experiment |

Mixed failures can require several actions. Keep their records separate so an environment outage does not become a false example that teaches the model to rewrite healthy game code.

## 10. Improvement procedure

Use the existing improvement/autopilot tools where they meet the scope. The workflow is:

```text
Observe current version and requirements
  -> identify defects, missing requirements and experience hypotheses
  -> attribute failures and cite evidence
  -> assign priority bands and resolve dependencies
  -> choose bounded work within budget
  -> reproduce or establish a baseline
  -> generate the change through Mubit
  -> rerun focused and affected regression checks
  -> keep, roll back or retain as an unverified draft
  -> update evidence and send the appropriate correction/learning context
```

For each candidate, record why it was selected and why competing candidates were deferred. Avoid spending repeated rounds on easy cosmetic changes while required gameplay remains incomplete.

Accept a game-code fix only when the intended defect is resolved by suitable evidence and the relevant regression checks pass. A verifier's explanation supports the decision; it cannot override a valid failing deterministic or player-journey check without first establishing that the check is wrong.

For an experience hypothesis, predefine the intended metric, guardrails and comparison. A pacing change can be inconclusive even when technically correct. Keep sample size and uncertainty visible. Separate the result from aesthetic preferences.

On a regression, preserve the failed attempt and its evidence, restore a known-good version when the workflow permits it, and correct the relevant Mubit task. Do not silently keep a new regression because the original bug disappeared.

Stop at the authorised target, budget, explicit user stop, repeated unchanged readiness/evidence, or a dependency that truly requires external input. Report the best verified state and remaining consequential work. Do not keep polishing after agreed checks pass merely because some budget remains.

## 11. Game-quality objectives

Use a profile of outcomes rather than one universal score. Separate hard constraints from experience objectives and operational cost.

| Dimension | Examples of useful measures | Interpretation |
|---|---|---|
| Integrity | Incorrect grants, lost profiles, duplicated items, forbidden state changes | Required invariants; a low observed count is bounded evidence, not proof that no defect exists |
| Core usability | Successful joins, first meaningful action, understood objective, journey completion | Diagnose drop-off and friction at specific steps |
| Progression | Time to useful upgrades, stage transitions, unlocked choices, stalled players | Evaluate against the intended genre and difficulty |
| Content quality | Distinct mechanics, reachable content, mission/route variety, human assessments | More objects or levels alone do not imply greater depth |
| Fairness | Outcomes conditioned on skill, equipment, teams and network conditions | Avoid treating intentional asymmetry as a defect |
| Performance | Frame time, memory, network and object budgets on target devices | Measure representative scale and sustained play |
| Human experience | Comprehension, satisfaction, perceived fairness, tension or creative agency | Use relevant human evidence and disclose uncertainty |
| Live health | Return visits, progression funnels, meaningful activity with others | Compare cohorts and changes appropriately; Studio bots cannot establish human retention |

Longer sessions can mean enjoyment or confusion. Higher completion can mean better clarity or insufficient challenge. Rising currency can mean progress or an economy exploit. Interpret metrics together with the intended experience and guardrails.

Published analytics and human playtests are separate from automated Studio proof. Roblox funnel events require a published game/server environment; local test counters are not a substitute for measured real-player behaviour. Do not introduce unrelated personal data collection to populate a quality scorecard.

## 12. Model learning and evaluation

### 12.1 Separate the two improvement loops

**Game improvement** changes one game's code, content or parameters and checks the result.

**Model improvement** changes the model/adapter or the task's available learned guidance and demonstrates better task performance on comparable, unseen cases. A game getting better through repeated calls does not prove that the underlying model improved.

The reflector's lessons and playbooks are context improvement. Mubit adapter training is a different mechanism. Track which changed when evaluating a result.

### 12.2 Evaluate tasks separately

| Task | Primary evaluation | Important guardrails |
|---|---|---|
| Director/planner | Required-system coverage, coherent progression, scope and dependency correctness | Avoid unsupported mechanics and invented requirements |
| Architect | Clear ownership, valid boot/dependencies and integration boundaries | Preserve behaviour, protected files and proportional complexity |
| Coder/patcher | Behavioural correctness and integration success | Compile/runtime health, security boundaries and unrelated regressions |
| Level designer | Valid routes, intended difficulty and meaningful variety | Failing seeds, unreachable content and unreported fallbacks |
| Tester/detector | Recall of known faults, useful coverage and reproducible evidence | False alarms, missed critical faults and invalid setup assumptions |
| Priority planner | Consequential tasks selected before optional work | P0/P1 misses, repeated rejected jobs and unjustified scope expansion |
| Fixer | Demonstrated defect resolved and change retained after regressions | New defects, weakened tests and unnecessary edits |
| Judge/verifier | Agreement with independently established outcomes and calibrated uncertainty | False passes, unsupported certainty and self-confirming evidence |
| Reflector | Useful, generalisable lessons that improve later held-out work | Overfitting, stale rules and contamination from unverified outcomes |
| Every task | Cost and latency per accepted, verified result | Never trade required quality away to reduce raw calls/tokens |

### 12.3 Keep a useful outcome record

Retain the task/role, relevant game families/capabilities, requirement, initial version, decision/input, proposed output, evidence, verified outcome, correction, Mubit request IDs when available, and cost/latency. Preserve the effective model and task/policy version identifiers available from the tooling.

Label outcomes as verified success, verified failure, regression, inconclusive or environment failure. Keep unsuccessful attempts for diagnosis and corrections; do not present them as successful targets. Redact secrets and avoid copying unrelated private data into learning material.

Use existing correction workflows for the responsible task. Put verified observations and the desired behaviour into the same task's user context. Do not change the fixed prompt to disguise a new example as the old task. Keep a local verified outcome dataset alongside traces; do not assume that a particular label or feedback API exists in Mubit unless it is actually supported.

Mubit recording a call, keeping an example, completing training, passing its adapter tests and serving that adapter are distinct events. Check the console/current supported integration for the relevant claim. This guide does not add adapter selection or training-status APIs.

### 12.4 Evaluation and promotion protocol

1. Freeze the evaluation task definitions and relevant game/fixture versions. Record the engine/harness, tool and policy versions.
2. Split by game/project and content/template family where appropriate, not just random calls. Related levels, corrections or near-identical generated games must not leak across training and evaluation splits.
3. Include representative supported families, hybrids, difficult edge cases, adversarial inputs and deliberately planted faults. Keep known fault truth separate from detector inputs.
4. Compare candidates on the same starting conditions, seeds, budgets and scoring rules. Use repeated trials when inference or play is variable.
5. Measure per-task and per-family results. Aggregate averages must not hide critical failures or a badly regressed family.
6. Independently review ambiguous cases. Use deterministic checks and human judgments where appropriate; avoid letting the model be the sole judge of its own outputs.
7. Adopt a candidate only with demonstrated benefit and acceptable guardrails. State the evidence limits and keep a rollback path. Use an adapter only through an available, verified serving path that preserves the Mubit routing requirement.
8. Keep hold-outs held out. Once a case is used as a training correction, replace it in the held-out evaluation set and retain the old result's provenance.

Do not change game code, lessons, prompts, fixtures and model version together and attribute the whole improvement to the model. Evaluate controlled changes, or explicitly report the result as an improvement to the overall system.

Existing `forge bench` is a regression/build benchmark with a fixed idea suite. Preserve its existing idea IDs/text for comparability. Expand with new IDs and separate held-out coverage rather than rewriting old benchmarks to make current models look better. Fake mode is useful for pipeline checks and cannot establish model progress.

## 13. Current implementation

Consult actual tool schemas/help and [ARCHITECTURE.md](ARCHITECTURE.md) before use. The following maps this guide to existing implementation; names and flags can evolve.

| Need | Existing component | Current boundary |
|---|---|---|
| Design and first build | `forge/director.py`, `forge/loop.py`; MCP `build_game` | Default director has solo Studio/prototype assumptions, including no monetisation; detect conflicts with the requested profile |
| Shared kits/templates | `forge/kit`, `forge/template.py`, `forge/ui_library` | Reuse actual documented APIs; specialised templates do not cover every genre |
| Obby levels | `forge/levels.py`, `forge/obby.py` | Geometry and content rules are specialised; other families need their own recipes/validators |
| Feature generation | `forge/feature.py`; MCP `feature` | Verify the feature's own outcome and integration, not only its job status |
| Generated executable checks | `forge/scenarios.py`, `forge/checks.py` | Headless and Studio have different capabilities; check coverage and test validity |
| Real interactions | `forge/journey.py`, `forge/interactions.py`, mubit-tester `test_feature` | Static findings and supported journeys do not establish every arbitrary game flow |
| Bugs and verified fixes | `forge/improve.py`, `forge/repro.py`; MCP `improve_game` | Preserve ownership and review verifier/test evidence |
| Ranked work | `forge/gaps.py`, `forge/orchestrator.py`, `forge/autopilot.py` | Strict priority bands and the full taxonomy here are not yet a universal implemented registry |
| Readiness | `forge/done.py`; MCP `done` | Implemented evidence bar, not automatic proof of every release requirement in this guide |
| Architecture diagnosis/consolidation | `forge/compare.py`, `forge/consolidate.py` | Reference scores are diagnostic; consolidation needs behavioural verification |
| Model/build comparison | `forge/bench.py`, Mubit task/call records | Current fixed suite is not broad held-out coverage of every listed family |
| MuMake native creation UI | `studio-plugin/MuMake.plugin.luau`, `mubit_tester.studio_service` | Draft readiness is code-only; explicit install, solo checks and selected revisions are not the whole readiness pipeline |
| ForgeBridge native status/actions | `studio-plugin/ForgeBridge.plugin.luau`, `forge/bridge.py` | A bridge/status surface; do not assume it has MuMake's creation flow or every MCP capability |

Useful CLI entry points, after confirming local help and selecting the authorised environment:

```bash
.venv/bin/forge doctor
.venv/bin/forge done <slug> --json
.venv/bin/forge checks <slug> --plan --run --headless-first --studio <bound-studio>
.venv/bin/forge journey <slug> --studio <bound-studio>
.venv/bin/forge gaps <slug> --find
.venv/bin/forge levels <slug> --zones <range>
.venv/bin/forge bench --list
```

Planning checks, finding gaps, designing levels and many build/test operations make paid Mubit calls. A command appearing here does not grant a new budget. Use their current help and the approved workflow rather than copying commands into an unattended run blindly.

The chat and native plugins must apply the same requirements and evidence meanings. A surface that cannot execute a required test must expose the gap or route the work through an available authorised tool. Do not silently downgrade multiplayer/persistence requirements to what the native panel can currently test.

## 14. Evidence records

Reuse existing records under the game's run directory. Do not invent a parallel database or assume every path below exists for every game:

```text
runs/<slug>/
  spec.json                    game design and feature/content metadata
  state.json                   build iterations and corrections
  game/                        source of truth for generated game code
  calls.jsonl                  recorded AI call metadata, where produced
  traces/                      full call traces, where produced
  checks/                      executable checks and their recorded results
  journey/                     recorded player journeys
  improve/                     fix cycles, reports, patches and verification evidence
  orchestrator/                gap lists, job decisions and orchestration records
  autopilot/                   measurements, decisions, outcomes and learning records
  production-plan.md           optional guide-level profile/contracts; not a runtime schema
```

Other testers/native jobs can store evidence elsewhere; link their real IDs/paths rather than moving or fabricating records. Reports must identify the current code/content version and environment. Historic evidence is a baseline, not automatically proof of the changed game.

Do not post raw traces or credentials to external systems as part of a routine game report. Follow the user's sharing instructions and the repository's artifact/archive rules.

## 15. Worked examples

All cases below are illustrative requirements, not actual test results.

### 15.1 A coin shop

Player promise: spend earned coins on an upgrade that changes play.

| Case | Expected observation |
|---|---|
| Balance 10, price 5, first purchase | Balance becomes 5; exactly one intended upgrade is granted; feedback and its effect appear |
| Balance 4, price 5 | Purchase rejected; balance and ownership unchanged; useful feedback |
| Balance exactly 5 | Purchase succeeds once; balance becomes 0 |
| Spam/repeat a once-only upgrade | No repeated charge or duplicated grant |
| Client sends a different price or another player's item | Server rejects or resolves from its own valid catalog and permissions |
| Player leaves during an applicable saved transaction | Recovery preserves the defined balance/ownership invariant |
| Real client clicks Buy | The actual UI and server flow lead to the same outcome |

A duplication exploit is P0; an unclickable required Buy button is P1; poor time-to-upgrade can be P2; an extra sparkle is normally P3. Paid products add the separate receipt requirements.

### 15.2 A co-op pet dungeon

Profile: co-op missions + RPG + collection; capabilities: saved inventory, shared rewards, mobile; trading only if explicitly included.

Build one join -> encounter -> teamwork -> reward -> next-attempt slice. Define reduced-player behaviour before adding many rooms. Test simultaneous reward claims, departure during completion, inventory capacity, respawn and mobile interaction. Add trading's two-party integrity suite if that feature enters scope.

If a player can lose an earned pet on rejoin, resolve that before adding another pet tier. If a room cannot be completed without a missing teammate, determine whether the design promises recovery or a minimum team size and test that rule. Human playtests then assess whether roles are useful and rewards feel worthwhile.

### 15.3 An obby with generated zones

Plan zone identities, mechanic introductions, stage count, difficulty curve and recovery. Generate data through the Mubit-backed level designer, using existing validators/builders. Preserve bad seeds and unreachable jumps as regression cases.

Prove complete-course connectivity and checkpoints before extending cosmetic dressing. A physically reachable jump is not automatically readable or enjoyable; test traversal and human difficulty separately. Record simplified/fallback stages so the course is not reported as fully generated to the original design without qualification.

## 16. Handoff and stop conditions

Before ending an authorised work cycle, report:

```text
Game / code version / target stage:
What changed for the player:
Highest-priority requirement addressed and why:
Evidence: tests, environments, seeds, jobs and relevant Mubit request IDs
Result: passed / failed / unknown / not applicable
Regressions checked; version kept or rolled back:
Remaining P0/P1 issues and required but untested capabilities:
Budget/cost evidence available; any running job and how to stop it:
Most consequential next action:
```

Use plain language in the UI/report and keep detailed evidence accessible. Do not turn the native interface into a dump of internal IDs or model roles. Do not claim training, readiness, deployment or a verified fix unless the corresponding evidence exists.

For a plateau, name what stayed unchanged and the next hypothesis or missing capability. For a missing Mubit connection, explain which AI work could not run and preserve completed deterministic work. For a budget limit or user stop, stop new work, clean up owned sessions and report the current state without relabelling it complete.

## 17. References and precedence

Repository/user instructions take precedence over this guide. Actual source, current tool schemas and recorded results take precedence over stale command examples or historical claims. When a workflow document has an outdated tool name, fixed list of readiness parts or a contradictory AI-routing suggestion, follow the current implementation and the Mubit-only rule; fix the documentation in an appropriately scoped change.

Repository references:

- [Architecture and contracts](ARCHITECTURE.md)
- [MuMake and native Studio surfaces](STUDIO_PLUGIN.md)
- [Tester contracts](TESTER.md)
- [Benchmark usage and historical results](BENCH.md)
- [Mubit loop design and historical integration findings](MUBIT_LOOP.md)
- [Existing genre lessons](../forge/lessons_library/)
- [Fixed role prompts](../forge/prompts/)

Primary external references, reviewed for this guide:

- [Roblox: securing the client-server boundary](https://create.roblox.com/docs/scripting/security/client-server-boundary)
- [Roblox: developer products and receipt handling](https://create.roblox.com/docs/production/monetization/developer-products)
- [Roblox: funnel events and environment limits](https://create.roblox.com/docs/production/analytics/funnel-events)
- [Mubit: gateway and task concepts](https://docs.mubit.ai/)
- [Mubit: training, testing and comparing an adapter](https://docs.mubit.ai/guides/first-adapter)

Refresh external API/service details when implementing them. The guide deliberately does not hardcode training thresholds, training times, model prices, supported starter-credit models or universal retention targets.
