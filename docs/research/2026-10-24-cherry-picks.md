---
title: "Cherry-picks for Forge from 9 AI game builders"
date: 2026-10-24
tags: [research, competitor, forge, backlog]
---

# Cherry-picks for Forge

Ranked ideas taken from public teardowns of nine AI game builders. Written for the agent building Forge:
each item is a task with what to build, where it lands, the smallest version, and how we know it's done.

**Read first:**
- Every pick here works **without real players**. We have none yet (AI persona testers, headless runs and
  Studio playtests only). Ideas that need real players are parked at the end.
- **Build from chat already exists** through Lu Min's Roblox Studio plugin. Nothing here replaces it.
- **Do not edit `forge/prompts/*.md`.** Mubit groups calls by exact system prompt, so an edit resets that
  task. Put per-call instructions in the user message. A brand-new role gets a brand-new prompt file.
- Update `docs/ARCHITECTURE.md` in the same commit when a signature changes.
- Source teardowns are in `docs/research/teardowns/` and `docs/research/2026-10-24-mypip-teardown.md`.
  Every claim there is tagged Observed, Inferred or From web.

## Sources at a glance

| Tool | What it is | Teardown |
|---|---|---|
| myPip | Prompt to a single-file HTML game; Hive crowd voting | `../2026-10-24-mypip-teardown.md` |
| Rosebud AI | Browser game builder with an agent that runs the game mid-turn | `teardowns/rosebud.md` |
| Astrocade | Social prompt-to-game platform, ~5M monthly users | `teardowns/astrocade.md` |
| Google Playground | Google Labs prompt-to-browser-game (sign-in gated; web sources only) | `teardowns/playground.md` |
| Rork | AI mobile app builder with parallel store-rule reviewers | `teardowns/rork.md` |
| Lemonade | Roblox Studio chat agent with auto playtest + GIF | `teardowns/lemonade.md` |
| PromptBlox | Builds a whole Roblox place in the browser, exports `.rbxlx` | `teardowns/promptblox.md` |
| RoCode | Roblox Studio agent over a WebSocket relay, ~46k accounts | `teardowns/rocode.md` |
| Nilo | Browser 3D engine with a 59-tool world agent, exports to Roblox | `teardowns/nilo.md` |
| Market map | 23 Roblox AI tools compared | `teardowns/market-map.md` |

## The gap nobody fills

More than 16 of the 23 Roblox AI tools do the same thing: a chat agent edits your open place. None of
them runs AI player swarms, takes a game to ready on its own, or learns from corrections. Several check
whether code *runs*; none checks whether the game is *fun or finishable* with players. That's Forge's lane,
and the picks below are chosen to widen it, not to copy the crowded part.

## What we already have (don't rebuild)

| Seen in | Idea | Forge today |
|---|---|---|
| myPip, Nilo, RoCode | Build from a chat | Lu Min's Studio plugin |
| Astrocade | Check the harness before a playtest | Testers prove their setup (#142) |
| Astrocade, Rosebud | Versions with restore | `forge/versions.py`, `forge rollback` |
| Lemonade, PromptBlox | Don't let the AI rewrite kit code | Kit protection in the fix loop (#147) |
| Rork | "Unknown is never ready" | `forge/done.py` line 19 |
| PromptBlox | Reachability check | Obbies only, in `forge/obby.py` |
| RoCode, Nilo | Screenshot review | Screenshots in `forge/preview.py`, `forge/studio.py` |
| Rork, PromptBlox | Per-job budget | Call budgets per candidate in `forge/autopilot.py` |

## Ranked picks

Effort: **S** = under 2 hours, **M** = half a day, **L** = more than a day.
Demo value: how much it helps the 3-minute video and the "correction becomes a model update" beat.

### 1. Human verdict on every version — S, demo value high

- **Seen in:** RoCode ("Did it work? Yes / Partly / No" under each build), Lemonade (continue / refine
  pause after each playtest).
- **What:** after each version finishes its playtest, record a one-click verdict: Yes, Partly or No, plus
  optional text. "Partly" and "No" with text go straight into `forge correct`. "Yes" is a positive label.
- **Why:** it's the cheapest possible way to turn every glance at a game into Mubit training data, and it
  keeps three signals apart that are easy to conflate: the model finished, the checks passed, a human says
  it works.
- **Smallest version:** a `forge verdict <slug> <version> yes|partly|no ["note"]` command and an MCP tool.
  Stores the verdict next to the version and, for partly/no with a note, calls the existing correct path.
- **Lands in:** `forge/cli.py`, `forge/versions.py`, `forge/mcp_server.py`; a button in the Studio plugin
  dock later.
- **Done when:** a "No: the panda is too easy to find" verdict on a version produces a Mubit correction
  that shows in `forge ledger`, and `forge versions <slug>` shows the verdict column.

### 2. Tunable game settings with ranges — M, demo value high

- **Seen in:** Astrocade (every game ships a config of numbers with min, max and step; creators retune it
  with no LLM call). Astrocade's strongest idea.
- **What:** our Config modules (`game/ReplicatedStorage/Config/*.luau`) already hold the tunables. Add range
  metadata for the important numbers (min, max, step, label). Then:
  - autopilot and AI testers can propose one-step nudges ("fire spread interval +1 step") as a candidate
    kind, cheaper and safer than a code fix;
  - a human changing a value is recorded as a correction with a precise before/after, the cleanest Mubit
    label we can produce.
- **Smallest version:** one `Tunables` table per Config module for 5–10 numbers in `FireConfig`,
  `RescueConfig` and `MissionCatalog`; a `forge tune <slug> <Config.key> <value>` command that edits the
  value, versions it and logs the change.
- **Lands in:** `game/ReplicatedStorage/Config/*.luau` (data only), a new `forge/tune.py`,
  `forge/autopilot.py` (new candidate kind `tune`), `docs/ARCHITECTURE.md`.
- **Done when:** autopilot proposes and applies a `tune` candidate, the gate keeps or rolls it back like a
  fix, and a manual `forge tune` shows up as a Mubit correction.

### 3. Fixed camera set per version, critic answers PASS/FAIL first — M, demo value high

- **Seen in:** Nilo (4 fixed camera views plus measured stats; critic must answer PASS or FAIL on its first
  line), PromptBlox (critic picks views: spawn, top-down, roof cut away, objective close-up), RoCode (2
  screenshots from opposite corners; a cheap vision model lists only clear problems), Lemonade (GIF of every
  playtest).
- **What:** every version gets the same 4 screenshots: spawn view, top-down, objective close-up, and one
  view the critic asks for. They're saved with the version so a correction can point at a picture.
- **Smallest version:** a `capture_views(slug, version)` helper that reuses the existing screenshot code
  and writes `views/<version>/{spawn,top,objective,ask}.png`. The PASS/FAIL-first rule goes in the critic's
  **user message**, not its prompt file.
- **Lands in:** `forge/preview.py` or `forge/studio.py`, `forge/loop.py`, `forge/dashboard.py`.
- **Done when:** two consecutive versions show side by side in the dashboard with the same 4 angles, and
  the critic reply parses as PASS or FAIL from its first line.

### 4. Synthetic Hive: persona testers propose and vote on the next feature — M, demo value high

- **Seen in:** myPip Hive (crowd suggests ideas, votes in rounds, winner gets built), Rosebud and
  Lemonade (clickable next-move suggestions, with picked / edited / ignored logged).
- **What:** after a swarm round, each of the 10 persona testers proposes one idea grounded in its report.
  They vote, with ideas backed by run evidence (counters, errors) weighted above taste. The winner goes to
  `forge feature`. The result labels the idea in Mubit: shipped clean and raised the score = positive;
  broke checks or lowered the score = correction.
- **Smallest version:** a `forge hive <slug>` command: read the latest tester reports, ask one new Mubit
  role (`hive_voter`, its own prompt file) to propose and rank, write the round to `hive/<round>.json`, and
  queue the winner as a feature. Show the top 3 in the dashboard as clickable chips; a human click counts
  as an extra vote and is logged as picked / edited / ignored.
- **Lands in:** new `forge/hive.py`, new `forge/prompts/hive_voter.md`, `forge/orchestrator.py` (queue),
  `forge/dashboard.py`.
- **Done when:** one round runs end to end on a real game: ideas, votes, a built winner, and a Mubit label
  on the outcome. Real players can be added later as one more voter type.

### 5. Player-journey contract — M, demo value medium

- **Seen in:** PromptBlox (the designer must name first action, core loop, progression, fail-and-recover
  and replay, each tied to real ids).
- **What:** the design spec gets a required `journey` block with those five steps, each pointing at a
  tag, attribute or remote that exists in the game. Testers and the gap finder check each step instead of
  guessing what the game is about.
- **Smallest version:** ask for the block in the designer's user message, validate it in Python (every id
  must exist after the build), and add one generated check per step.
- **Lands in:** `forge/loop.py` (spec validation), `forge/checks.py`, `forge/gaps.py`.
- **Done when:** a spec without a `fail_and_recover` step is rejected, and `forge checks` lists five
  journey checks for Flame and Blame.

### 6. Reachability before a swarm run, for every genre — M, demo value medium

- **Seen in:** PromptBlox (pathfind from spawn to every objective before export).
- **What:** before spending 10 AI testers, pathfind headless from spawn to every tagged objective (fires,
  rescue spawns, checkpoints, pads). Unreachable objectives fail fast with their position.
- **Smallest version:** lift the reachability idea from `forge/obby.py` into a general check that reads
  objective tags from the spec and uses the headless engine's spatial grid.
- **Lands in:** `forge/headless.py` or a new check in `forge/checks.py`; call it from `forge/smoke.py`.
- **Done when:** moving a rescue spawn inside a sealed room fails the check before any tester starts.

### 7. Readiness lists what wasn't checked, and refuses a game with no scripts — S, demo value medium

- **Seen in:** Rork ("Reviewer coverage incomplete, this area is unverified"), RoCode (refuses "done" when
  a game prompt produced parts but no scripts; sends back a genre checklist).
- **What:** `forge done` already treats unknown as not ready. Make the output name the unverified areas
  in their own section, and add a hard gate: zero gameplay scripts means not ready.
- **Lands in:** `forge/done.py`.
- **Done when:** `forge done` on a game with an unrun check prints an "Unverified" section, and a
  parts-only game fails with "no gameplay scripts".

### 8. Free-text feedback becomes graded grievances — S, demo value medium

- **Seen in:** Nilo (`report_frustration` tool logs each grievance from the user's message with a
  severity).
- **What:** a human message like "this is boring and the truck flips constantly" is split into
  grievances with a severity (low / medium / high) and the file or system each points at. Each high one
  becomes a `forge correct`; the rest feed the gap finder.
- **Smallest version:** a new Mubit role `grievance_parser` (own prompt file) behind
  `forge feedback <slug> "<text>"`.
- **Lands in:** new `forge/feedback.py`, new `forge/prompts/grievance_parser.md`, `forge/cli.py`.
- **Done when:** the example sentence produces two grievances, one of them a correction in the ledger.

### 9. Undo is a negative label — S, demo value medium

- **Seen in:** Astrocade (every request is a versioned "wish" with one-click undo).
- **What:** when a human or the gate rolls a version back, record it in Mubit as a negative example for
  the call that produced it.
- **Lands in:** `forge/versions.py` (rollback path), `forge/ledger.py`.
- **Done when:** `forge rollback` writes a negative label that shows in `forge ledger` with the version
  and the reason.

### 10. Parallel rule reviewers for Roblox policy — M, demo value low, ship value high

- **Seen in:** Rork (five reviewers at once, one per section of Apple's store rules; each cites a file and
  returns reject / warn / pass).
- **What:** separate reviewers for Roblox Community Standards, maturity questionnaire, monetisation rules
  and IP. Each is its own Mubit task, so corrections to one don't blur the others.
- **Lands in:** new prompt files under `forge/prompts/`, a `forge review <slug>` command, a line in
  `forge done`.
- **Done when:** a test game selling a paid random item without odds is flagged by the monetisation
  reviewer with the file that does it.

### 11. Smaller picks — S each

| Pick | Seen in | Lands in | Done when |
|---|---|---|---|
| Attach grouped console errors (count, first/last seen) to a correction | Rosebud | `forge/repro.py`, correct path | A correction includes the grouped errors from the last run |
| Error-storm breaker: stop a run above 10 errors per second | Rosebud | `forge/headless.py`, `forge/smoke.py` | A deliberately spammy script stops the run with one summary |
| Juice-only autopilot mode: may touch particles, sound, camera, lighting only | Lemonade | `forge/autopilot.py` (allowed paths) | A night run changes only those files |
| Dollar cap per job that pauses and can resume | PromptBlox | `forge/ledger.py`, `forge/autopilot.py` | A job pauses at its cap and resumes |
| Manifest per kit module: size, origin, what it does, "don't add a competing controller" | PromptBlox | `forge/kit/` | Coder prompts include the manifest; no duplicate controllers in a fresh build |
| Store the prompt that caused each version | Rork | `forge/versions.py` | `forge versions` shows the request per version |
| Unit checks for pure modules, run headless before any playtest | PromptBlox | `forge/checks.py` | `AxeMath`-style modules get input → expected checks |
| FPS and frame variance after a 5 s warm-up | Astrocade | `forge/headless.py` or ForgeProbe | Each playtest report has an FPS line |

## Not now: needs real players

Creator payouts per play (Astrocade), contests, streaks and daily credit rolls (myPip, Lemonade), community
feeds and showcases, myPip's Hive with real people. Pitch-deck material only, until there are players.

## Pitch ammunition

- **Nobody else tests with players.** PromptBlox never runs the real engine. A Google Playground creator:
  "no way to visually verify or test out the game at all." myPip's progress messages are a timer, not real
  steps. Forge plays its games with AI testers and shows the evidence.
- **Nobody else learns.** None of the 23 Roblox tools turns corrections into model updates.

## Naming risk

Another Roblox Studio agent was called "Forge" (forgeblox.app, renamed ForgeBlox this month), and RoCode
has a "RoCode vs Forge" page about it. Judges searching "Forge Roblox AI" will find them. Decide before
the deck goes out whether to keep the name or add a qualifier.

## Suggested order for the build agent

1, 7, 9 first (all small, all feed Mubit labels straight away). Then 3 and 2 (the visible demo beats).
Then 4 (the synthetic Hive, which uses 1–3). 5, 6, 8, 10 and the small picks as time allows.
