# Forge — architecture and contracts

Forge takes a game idea and builds a Roblox game: it writes Luau, syncs it into a running Roblox
Studio over the Studio MCP, playtests, reads errors, fixes, and iterates. Every LLM call goes through
Mubit, so each role's calls become a Mubit **task** and Mubit trains an adapter for it once it has
enough kept examples. Corrections (from Studio errors, the critic, or a human) are fed back as new
calls in the **same task**, which is how a correction turns into a model update.

Research behind this: `docs/research/mubit.md`, `docs/research/roblox-studio-mcp.md`,
`docs/reference/intofire/` (the earlier project this workflow comes from).

## The loop

```
idea ──designer──▶ spec.json ──coder (per module)──▶ game/*.luau
                                          │
                       luau-compile check ┤◀── fixer (compile errors, ≤3 tries)
                                          ▼
              sync into Studio (execute_luau runs game/tools/pull.luau)
                                          ▼
       playtest: start_stop_play → wait → smoke play → ForgeProbe report + console + screenshot → stop
                                          ▼
                   critic ──▶ {score, issues[]} ──fixer (per issue)──▶ files
                                          ▼
                   reflector ──▶ runs/lessons.md (self-evolving notes)
                                          ▼
                                next iteration (until score ≥ target or N iterations)
```

Human correction: `forge correct <game> <file> "what is wrong"` sends a fixer call with the human's
note. The fixed reply is a recorded call in the fixer task, so Mubit can train on it.

## Mubit rules (they decide how calls become tasks)

1. A task = system prompt + tools + output format + model. **System prompts are fixed files in
   `forge/prompts/<role>.md` and never contain per-call text.** Everything that varies (idea, spec,
   code, errors, lessons) goes in the user message.
2. Session = `metadata.session_id` (OpenAI) / `metadata.user_id` (Anthropic) = the game slug, so
   Mubit's test split is per game.
3. Keep each call under ~8k tokens: one module per coder/fixer call, and only the APIs of the
   modules it depends on.
4. Record the `x-middleware-request-id` response header for every call (`runs/<game>/calls.jsonl`)
   so calls can be found and rated Good/Bad in the Mubit console (Requests page).
5. No feedback API exists; adapters can't be called by model id. The demo shows the task in the
   console going Collecting → Training → Passed, then Try models side by side.

## Layout

```
forge/                 Python package (uv), entry point `forge`
  config.py            Settings from env (.env)                         [owner: core]
  llm.py               MubitLLM + FakeLLM                               [owner: llm]
  prompts/*.md         fixed system prompts, one per role               [owner: llm]
  roles.py             typed wrappers: design/code/fix/critique/reflect [owner: llm]
  studio.py            StudioMCP stdio client                           [owner: studio]
  sync.py              thin Python wrapper around game/tools/sync.py    [owner: studio]
  memory.py            run state, lessons                               [owner: loop]
  loop.py              the orchestration above                          [owner: loop]
  cli.py               `forge new|run|correct|status|doctor|play|mcp|seed|promote|assets|improve|scores`   [owner: loop]
  seed.py              seed(settings, slug, spec_path=None) -> RunStore; promote(settings, slug, rel) -> Path
  seeds/<slug>.json    Forge spec for a seeded run (flame-and-blame: FlareUpService)
  assets.py            assets/manifest.json -> generate/search/upload -> Config/AssetIds.luau (no LLM)
  improve.py           self-improving loop (docs/MUBIT_LOOP.md): run_cycle(settings, slug, *, llm, harness,
                       playtest, faults, goal, rounds, players, steps) -> cycle dict; round_digest, audit,
                       verify, plant/clear, score; runs/<slug>/improve/{<n>.json,scores.json,playbook.md}
                       run_cycle(..., fix=True) runs fix_code(): fixer, compile, resync, replay,
                       verifier, then keep or roll back; base_files only get improve/patches/
                       fix_code(..., repro=True): reproduce first, judge by checks (see "Fix loop" below)
  checks.py            executable checks: runs/<slug>/checks/<id>.luau, run in the Server DM during play,
                       return {ok, detail}; load_checks/save_check/run_check/run_checks/summary;
                       wrap() gives every body a `forge` table (HELPERS): waitFor(fn, t), startRound(t) (waits
                       out a round still in Results when the game has a MissionService), endRound() via
                       ServerStorage.ForgeTest `round` ("setup: ..." error without it);
                       helpers_doc(spec) for user messages: helpers + SETUP_RULE (+ round rule when spec
                       playtest.start_round); setup_failure(result) ("setup:" in error or detail = unknown);
                       run_check(studio, check, timeout=90, *, fresh=True, log) reruns a setup failure once in
                       a fresh playtest (fresh_play), then marks it setup: true; run_checks(..., *, log) stops
                       restarting once a restart did not help; lint_setup(body) -> why a body has no setup assertion;
                       premise: consumer_hits(game_dir, body) (line-numbered game lines naming what a check
                       asserts), valid_consumer(game_dir, "<file>:<line>") -> normalised ref | None
  repro.py             reproduce(settings, slug, anomaly, investigation, *, llm, studio, session_id) ->
                       {proven, check, result, attempts} (attempt statuses proven | passed | errored | setup |
                       no_consumer | no_setup | unusable); run_suite(studio, run_dir) -> {results, anomalies,
                       unknown} (setup failures are unknown, not anomalies);
                       save_pending / promote / load_pending / find; problem_block(check, result) for the fixer
  prompts/reproducer.md  Mubit task: anomaly + investigation + code excerpts -> ONE check that fails while the
                       bug exists (```luau block, `-- check:` / `-- covers:` / `-- consumer: <file>:<line>` header)
  dashboard.py         `forge dashboard`: live view of runs/ (collect() -> GET /api/state + dashboard.html);
                       per game: live (role at work), goal, missions (one per version, what_improved()),
                       features; team_view(settings, slug, game) -> game["team"] = {lanes, testers,
                       critic_shots, timeline, speed} and mubit["ledger"] (ledger_view: per role calls,
                       corrections, kept; "correction -> model update" moments). Reads (all optional)
                       runs/<slug>/timings.json {stages[{name,start,end,secs,before_secs}], lanes[...],
                       calls[{role,lane,start,end,latency_ms,step,thought}], speedups[{stage,before_secs,
                       after_secs}]} (else derived from calls.jsonl + traces) and runs/<slug>/tests/<run>/
                       {report.json, step-NN.png[, step-NN.json]} (steps: action, reason, latency_ms,
                       ts, assertions[{text, ok, detail}]). GET /api/shot?slug=&path= serves only .png
                       under runs/<slug>/{tests,iterations}/. POST /api/rollback {slug, version} ->
                       rollback(): GameVersions.restore, 127.0.0.1 only, 409 while a run is building
  feature.py           add_feature(settings, slug, request, *, llm, iterations, use_studio, polish, jobs) -> result:
                       planner plan -> coder (new modules, as a DAG) and patcher/fixer (hook edits, destructive
                       guard; one file's edits in order) all at once ->
                       compile -> version -> iterate -> polish_feature (round_starting AI testers, auditor vs
                       spec acceptance, run_cycle fix=True until open == 0) -> verified by planned counters
  prompts/planner.md   Mubit task: feature request -> {summary, new_modules, edits, telemetry, acceptance}
  ledger.py            `forge ledger`: ledger(settings) -> {total_calls, roles[{role, calls, corrections, verified,
                       rejected}], entries} rebuilt from runs/**/traces + improve/<n>.json + state.json corrections
  reflect.py           `forge reflect <slug> [--llm] | --all`: the reflection log (see "Reflection" below)
  done.py              `forge done`: readiness(settings, slug) -> {ready, parts[{part, ok, detail}]}: checks all pass
                       (latest checks/results.json, dropped ignored),
                       features verified (UI needs a real press), nothing high/medium open, critic >= 8 (n/a if seeded),
                       fun critic >= 8, visuals (<= 15% default-grey parts), hud (a ScreenGui), sounds (>= 1),
                       first60 (every director beat's counter reached its min); census from the playtest, else source;
                       interactions (the static audit finds no dead interaction; its line says what only a generic
                       handler covers and which remote checks were switched off) and journey (the fresh journeys of the
                       current code, Studio's verdict per step where it has one, headless for the rest, passed every
                       step) are hard parts too (see "Interaction gates");
                       readiness(..., compare=True) (what `forge done` prints) adds r["compare"] = compare.done_summary:
                       the compare categories vs game/, informational (an "[i] compare" line, never a part, never blocks)
  compare.py           `forge compare <slug|dir> [--against game|slug|dir] [--llm] [--json]`: is the code as good as our
                       best human code yet? compare(game_dir, ref_dir, *, spec, run_dir, name, ref_name) -> report, static
                       and deterministic (gaps.game_sources, GameAssets kit excluded, comments stripped): categories
                       architecture, robustness, data, ui, juice, content, observability, each 0-10 RELATIVE to the
                       reference (game/ = 10 vs itself) from presence / shares / kind coverage / per-1k-line densities
                       (never raw size); content uses the genre bar (gaps.CHECKLISTS + an obby list, lessons_library
                       targets). report {game, reference, genre, size, overall, verdict, categories[{id, score, metrics[{id,
                       kind, score, game, reference, evidence[file:line], misses, ref}], evidence, gaps (top 3: "reference
                       does X" + pointer file:line to copy, kit/lessons for genre mechanics)}], gaps, llm?};
                       saved runs/<slug>/compare/<n>.json + .md (a folder outside runs/: runs/compare/<name>/, read only);
                       --llm: judge(llm, report, session_id) = ONE `code_judge` call (static report + weakest areas'
                       code side by side with the reference's) -> {summary, verdict, improvements[{rank, title,
                       category, impact, effort, why, how, files, new_files, reference}]} (files/pointers validated)
  prompts/code_judge.md  Mubit task: static comparison + excerpts -> ranked improvements (JSON)
  consolidate.py       `forge consolidate <slug> [--plan-only] [--max-merges 6] [--studio S]`: one architect pass over a game
                       that grew feature by feature (see "Consolidate" below): merge overlapping modules, fold loose
                       Scripts/LocalScripts into Init/Start services and controllers booted by prebuilt bootstraps, delete
                       telemetry-only *Ack scripts; gated in Studio, rolled back (GameVersions) on failure
  prompts/architect.md Mubit task: module map + compare's architecture gaps + spec + prebuilt list -> consolidation plan (JSON)
  director.py          quality brain 1 (`forge direct "<idea>" [--compare]`): genre_lessons(text) (forge/lessons_library),
                       direct(llm, idea, lessons, *, session_id) -> design doc (Mubit task `director`),
                       design_from_doc(llm, idea, doc, lessons, *, session_id) -> spec (frozen designer, doc in the user
                       message, module budget 4-12 overrides the old cap of 7), plan() = both; spec["director"] = doc,
                       spec["first_60s"] = [{t, beat, counter, min}]; art pass install_kit(spec, game_dir) writes the
                       prebuilt ReplicatedStorage/GameAssets.luau (forge/kit: palette, sounds.json, play/burst/shake/
                       styleLighting/part); coder_notes(spec, lessons) puts style + juice ahead of coder/fixer lessons
                       kit modules: forge/kit/modules/<Name>.luau + index.json [{name, path_in_game, genres ("*" = all),
                       keywords, describe, api, genres_only?, requires?, template?}]; match_kit_modules(text) (gaps.detect_genre
                       or a keyword; genres_only limits a keyword match to those genres; a match brings its `requires`);
                       template mode (a matched kit with "template"): template_block(kits) in the director and designer
                       user messages, module budget TEMPLATE_EXTRA_MODULES (2) extra modules, the template's files as
                       RENDERED prebuilt modules, first-60s counters only from kit_counters(kits) (count("x") /
                       telemetry("x") in the kit sources; an invented one is cleared from its beat) -> the designer's
                       scope block says PREBUILT, spec module {path, prebuilt, kit: <name>}, install_kit copies the file and
                       forge/genre_checks/<genre>/*.luau into runs/<slug>/checks/ (resolve_consumers: `-- consumer:
                       <file>:"<text>"` -> <file>:<line>; __EXPECTED_STAGES__ from spec levels), kit_api_block(spec) in every
                       coder user message (roles.code_module), protected_paths (kit + level data) never go to the fixer
                       (Run.base_files), ensure_kit(spec, game_dir, names) for games built before the kit
  obby.py              obby levels as data: KINDS (11 kinds, defaults/limits; platform shape block|round|cylinder|wedge-ramp),
                       layout(stage) -> surfaces in the stage frame (stage `turn` -90..90 on its start pad: a turn that is not
                       a multiple of 90 judges the pad as its inscribed disc for jumps and its rotated box for movers; a
                       cylinder is a log across the course whose standable strip is half its diameter, LOG_DROP of the radius
                       under the crown; a wedge-ramp lands at its low near edge and takes off from its top),
                       validate_stage / validate_zone -> exact "stage N ...: gap 12.0 at rise 0.0 > max 10.0" problems (jump
                       envelope of the default character: walk 16, jump height 7.2, gravity 196.2, reach(rise) = 16 * airtime
                       + 1.3, rise <= 6, calibrated live; jumppad/trampoline launches; movers sampled over 24 s; tile
                       timing; lava at floor level; crush counts body thickness; pendulum clearance), fallback_stage (four
                       varied layouts), kinds_doc, limits_doc, render_zone_luau -> ReplicatedStorage/Levels/ZoneNN.luau
                       (theme_id, turn); a turned stage's piece level with its start pad may not start inside the turned
                       pad's corners (param). ObbyKit's LevelBuilder runs the same rules (tests/test_obby.py: same messages
                       for the same data). Design-time zone rules (Python only): zone_rules(zone, first, count, theme) /
                       rule_problems / rule_stats: a stage at most 50% plain block platforms, an obstacle per stage, no two
                       stages with the same kind sequence, >= 4 kinds a zone (finale: 6), the theme's SIGNATURES (THEMES:
                       entrance, carousel, bumper, teacups, ferris, flume, haunted, pirate, coaster, finale) and turns each in
                       share_need(count) stages (30%: 6 of 20), the zone climbs CLIMB_PER_STAGE per stage and each run of the
                       route at most RUN_CLIMB_MAX 12 (run_climbs / run_climb_problems: the corners lift the levels),
                       footprint_problems:
                       every piece, mover's path and jump inside the zone's plot (PLOT_HALF_WIDTH 38 each side of the start
                       line, PLOT_BACK 10 behind the start pad to PLOT_LENGTH 450 ahead: the corridor WorldKit keeps clear in
                       its 1600-stud park), and course_layout (stage frames in the zone frame) never crosses itself
                       (crossing_problems: pieces and jump gaps of different stages within CLEARANCE). Forge owns the turns:
                       route_plan(count) -> [{role run|corner, turn, run, dir out|back}] is a switchback (runs out and back
                       in two lanes, at most MAX_RUN_STAGES out; between runs a corner stage turns CORNER_TURN -90, left,
                       CORNER_LENGTH long, lifting CORNER_LIFT, and the next run's first stage turns -90 again; the first run
                       out is a stage longer than any run back), apply_route writes its turns into a zone; stage_length,
                       extent; THEME_PALETTES (each theme's landmark colours, mains delta E >= 25 apart); fallback_stage(...,
                       corner=True) is one of three short lifts
  kit/modules/ObbyKit.luau  ObbyKit.start(opts) builds every Levels zone and runs checkpoints (Stage leaderstat, DataStore /
                       Studio memory, SavedStage), respawn, kill parts, falls (per stage frame: FALL_DEPTH under the stage, or
                       standing on anything off the course under it past its start pad, e.g. the park's ground), coins, jump pads, trampolines,
                       conveyors; one Heartbeat loop drives movers near players; Obstacles.<kind>(parent, cf, params; piece k takes
                       the zone's palette rotated by k);
                       LevelBuilder.build/validate/validateZone/audit (turned stages and shapes rebuilt from parts). v2:
                       opts.anchors ({[zone | theme id | name] = CFrame}, WorldKit.buildPark): zone 1 starts at its anchor,
                       later zones on their own start pads (ObbyZoneStart), the zone before ends in a ride gate (RideGate:
                       RidePad touch pad tagged RideGatePad + 'Ride to <zone>' prompt, both connected: save the stage,
                       teleport to the next zone's start; a player at a zone's last stage respawns there); each stage's frame
                       turns by its `turn`; opts.themes (ObbyThemes): dress(kind, model, params, theme, rng) per piece and
                       stageDecor(stage, theme, rng, n) per stage, pcall-guarded, every part they add made non-colliding,
                       non-touching, non-query, massless and untagged; opts.gates (WorldKit's, same keys as anchors): a ride
                       entrance on the ground to every later zone with its own start pad (RideEntrance, attrs Zone, Stage =
                       the stage it needs, LastStage, FromZoneName; EntrancePad tagged RideEntrancePad + prompt: a player who
                       finished the zone before rides to that zone, to their own checkpoint while inside it; others get a
                       3 s "Finish <zone> first" BillboardGui in their PlayerGui and the RideNotice attribute); opts.spawn
                       (the park spawn; with it or with anchors the course is in a world): a player who has not stood on the
                       course yet (start pad, checkpoint, ride gate, a fall off it: player attribute OnCourse) starts and
                       respawns there instead of on the start pad; every pad floating over open ground (raycast from inside
                       it: a pad over the course or on a WorldKit tower gets none) stands on a non-colliding Support column
                       and Footing (workspace.Obby.Supports); start pads are dressed like their zone's checkpoints;
                       ObbyKit.coins(player), spend(player, n) -> bool, addCoins(player, n): the course's coin ledger (a
                       shop spends through it, so the next pickup never refunds a purchase); tags Checkpoint, ObbyStart,
                       ObbyZoneStart, RideGate, RideGatePad,
                       RideEntrance, RideEntrancePad, ObbyStage, KillPart, Obstacle, ObbyStandable, Coin, JumpPad, Trampoline,
                       Conveyor
  kit/modules/WorldKit.luau  WorldKit.buildPark(opts) builds the amusement park an obby runs through, around the courses
                       it measures from the level data, and returns anchors (where each zone's course starts), gates,
                       lots (opts.lots = {changingRoom = true}: a clear plaza spot) and courses; WorldKit.client() runs
                       the rides on each client; see "Kit modules" below
  kit/modules/ParkObby.luau  the park obby template: ParkObby.startServer(Config) builds the park (WorldKit), the course in
                       it (ObbyKit v2 with anchors, gates, spawn = the lobby, ObbyThemes), the changing room on
                       lots.changingRoom with Cosmetics spending ObbyKit's ledger, and the finish reward; startClient(Config)
                       starts WorldKit.client, MusicPlayer (area = Config.Zones[player Zone].name, lobby before stage 1),
                       CosmeticsClient and the HUD. Every kit is required: a missing one stops the boot with its name, as
                       does a Config.Zones count that differs from the level zones
  template.py          template games (a kit entry with "template": {files}): rendered_files(spec) / render(spec, game_dir)
                       write ParkObby's ReplicatedStorage/Config.luau (zones from spec.levels.plan in order, each zone's
                       theme_id as is, costumes, finish reward) and the two bootstraps; install_kit and `forge levels` call
                       render; the files are protected from the fixer. `forge new` on a template obby runs the level
                       designer first (template.PARK_ZONES x PARK_STAGES_PER_ZONE unless the spec sets levels), then renders
  levels.py            `forge levels <slug> [--zones a-b] [--stages-per-zone 20] [--total-zones N]`: per zone one
                       level_designer call (game, zone, park theme (zone_theme: plan theme_id, planned name words, else the
                       park order for an amusement-park game) + THEME_NOTES + signature kinds introduced early, difficulty per
                       stage, mechanics schedule, the zone rules in words, route_doc (obby.route_plan stage by stage, run and
                       corner lengths, lane width, CORNER_EXAMPLE), kinds, limits and one valid EXAMPLES run stage per theme in
                       the user message) -> forge_owned (the route's turns, and THEME_PALETTES[theme] for a park theme) ->
                       validate_zone + zone_rules -> up to CORRECTIONS (2) corrections in the same task with the exact errors
                       (plus a one-line-per-stage zone overview when zone rules fail: route role, turn, heading, length, where
                       its checkpoint ends) -> fallback stages for unreachable ones (a corner's is a short lift) ->
                       runs/<slug>/levels/zone-NN.json (theme_id) + log.jsonl and the
                       Levels module; resumable (zones passing both validators skipped); spec["levels"] = {zones,
                       stages_per_zone, plan[{..., theme_id, rules_left, stats}]}; ok also needs no zone rule left broken
  prompts/level_designer.md  Mubit task: one zone -> {zone, name, theme, palette, material, stages[{stage, name, turn, pieces}]}
  genre_checks/obby/*.luau   prebuilt obby checks: stage count vs spec, one checkpoint per stage, checkpoint saves + respawn,
                       kill parts kill, falls return to the checkpoint, reachability (data + built parts), coins collectible,
                       jump envelope (a live R15 runner), movers carry, ride gates (wired, riding one lands on the next
                       zone's start, and that zone's ground entrance is shut one stage short and rides up at the zone's last
                       stage); each check's waits stay under the 30 s execute_luau limit
  interactions.py      `forge interactions <slug>|--root DIR`: static audit (luau-ast) of interactions that cannot work,
                       file:line per finding: prompts / click detectors / buttons with no handler, remotes fired that
                       nothing listens to (and the reverse), bindables; an object it cannot follow is unknown, never
                       reported (see "Interaction gates")
  journey.py           `forge journey <slug> [--studio S] [--clicks] [--no-sync] [--shots DIR]`: live end-to-end journey of
                       one new player through the ForgeTest harness, no LLM: join, lobby (census, no template baseplate,
                       a WorldKit park in view), every lobby prompt must have an observable effect and what it opens is
                       closed again, costume (worn and visible), stage 1, respawn, layout + buttons (every on-screen
                       button on top and doing something, RESET back to the checkpoint), ride gate -> runs/<slug>/journey/
  fun.py               quality brain 2 (`forge fun <slug>`): census(studio) (server + client scene census during play,
                       stored as report["census"]), static_census(files), fun_critique(llm, spec, files, report, *,
                       census, visual, session_id) -> {score = mean(fun, juice, clarity, visuals), scores, summary,
                       first_60_seconds, missing_juice, issues, census, checks} (Mubit task `fun_critic`),
                       FunStore -> runs/<slug>/fun/<n>.json + latest.json, pending_fun_anomalies() for run_cycle(fix=True)
  smoke.py             smoke play in the scoring playtest (no LLM): smoke_play(studio, spec, game_dir, *, budget_s=45)
                       -> {steps[{what, ok, detail, secs, skipped?}], obby{samples[{from, to, by, result, where, zone?}],
                       reached, total, zones_sampled, zones_reached} | None, counters_delta, secs, error?}; never raises.
                       Steps (ForgeTest harness only): players -> ui (ai.ui_pass, real clicks; skipped when they can't
                       land) -> pickups (walk to Coin-tagged parts) -> obby (player 0 -> 1 from spawn + one bot per
                       sample_stages() stage, one `multi`) + kill part, or the nearest prompt/touchable; format_smoke()
                       = the critic's "## Smoke play" section, headline() = one line (fun critic, terminal)
  lessons_library/*.md curated genre lessons (fun, tycoon, obby, simulator): director + designer + coder user messages,
                       and seeded once at the top of runs/<slug>/improve/playbook.md (ImproveStore.seed_playbook)
  bench.py             `forge bench`: fixed 5-idea suite (tycoon, obby, minigame, simulator, defence) built with
                       loop.new_game (+ optional improve cycles); run_bench(ids, *, iterations, studio, improve, fake,
                       lessons) -> (result, runs/bench/<stamp>.json + .md); compare(a, b) -> markdown deltas (docs/BENCH.md)
  versions.py          GameVersions(game_dir): runs/<slug>/game is a git repo, tags v1..vN;
                       snapshot(msg) -> tag, log(), restore(tag, reason) -> new tag (rollback as a commit)
  broker.py            shared resources + job queue for `forge orchestrate` (see "Orchestrator" below):
                       StudioSlots (same dir/semantics as scripts/studio-slot.sh), Broker (all-or-nothing leases on
                       pools, stale-lease reclaim), JobQueue (priority, deps/after, claim with leases, crash recovery)
  gaps.py              trace-driven gap finder: collect_evidence -> gap_message -> gap_finder (Mubit) -> parse_gaps;
                       find_gaps / correct_gaps / latest / render; genre CHECKLISTS (tycoon, obby, generic); the static
                       scan skips kit modules (it looks for the game using them)
  prompts/gap_finder.md  Mubit task: everything recorded about a game -> ranked gaps {title, kind, impact,
                       confidence, evidence[refs], job{kind fix|feature|visual, request, path?}}
  orchestrator.py      `forge orchestrate`: Orchestrator(settings, slug, Options, *, llm, runner, broker, queue,
                       keeper, slots).run() -> {before, after, rounds, stop_reason, budget, queue}
  evidence.py          one EvidenceStore per autopilot round (items with citable ids + metric series), collectors
                       (ForgeProbe measurements, history, tests, swarm, checks, calls, ForgeBridge) and the statistical
                       pre-filter (z-scores, diffs vs the previous version, flat/untouched counters, leaks, stuck, ttfr)
  autopilot.py         `forge autopilot`: Autopilot(settings, target, AutoOptions, *, llm, runner, measurer, broker,
                       slots, keeper, maker, clock).run() -> {slug, stop_reason, budget, rounds}; advise(); correct()
  prompts/anomaly_detector.md  Mubit task: pre-filter candidates + evidence -> anomalies {title, kind, severity, impact,
                       confidence, evidence[refs], job{kind fix|feature|polish|asset|test, request, path?}}, noise[]
  faults/<slug>.json   planted faults (live ForgeTest config) the auditor is scored against
  prompts/auditor.md, prompts/verifier.md, prompts/triage.md   Mubit tasks: anomaly detection,
                       fix verification, tester-report triage (improve.file_report)
  play.py              AI playtester (observe → act → report)           [owner: play]
  mcp_server.py        stdio MCP server "forge" (`forge server`): build/iterate/correct/improve as jobs [owner: GF]
  bridge.py            ForgeBridge: local bridge to the Studio plugin (studio-plugin/ForgeBridge.plugin.luau),
                       events + fast commands; docs/STUDIO_PLUGIN.md        [owner: plugin bridge]
game/                  the Roblox place, file-mapped like Script Sync
  ServerScriptService/ X.server.luau → Script, X.luau → ModuleScript, dirs → Folders
  ReplicatedStorage/
  StarterPlayerScripts/ (under StarterPlayer)
  tools/sync.py        check / manifest / serve                         [owner: game]
  tools/pull.luau      run via execute_luau (Edit DM) to pull files from the local server
  ServerScriptService/ForgeProbe.server.luau  playtest error/telemetry collector (runtime contract)
runs/<game>/           per-game state, gitignored
  spec.json  state.json  calls.jsonl  iterations/<n>/{report.json,critique.json,screenshot.png}
  skipped.jsonl        (next to each calls.jsonl) Mubit calls not needed: cache hits, JSON repairs parsed locally
  reflection/<n>.md  reflection/reflection.jsonl   forge reflect (one per build, fix run, orchestrate round)
runs/reflection.md     forge reflect --all
runs/lessons.md        shared lessons, injected into every coder/fixer user message
forge/ui_kit.py        picks UI kit rules + snippets for UI work (user message only)        [owner: llm]
forge/ui_library/      the UI kit: README.md (rules + sources), index.json, *.luau snippets
forge/kit/bootstrap/   Main.server.luau / Main.client.luau: Forge's prebuilt bootstraps (the reference's Init/Start
                       contract without its Net lines), installed by `forge consolidate`
forge/kit/             GameAssets.luau template, sounds.json ("sounds" + "music"), modules/ (prebuilt kit
                       modules, installed as ReplicatedStorage/Kit/<Name>.luau; see "Kit modules" below)
```

Generated games live in `runs/<game>/game/` (same layout as `game/`). The base `game/` folder holds
the always-present runtime (ForgeProbe, DevHook) and, since the weekend kickoff, the human-built Flame and
Blame tree. `forge new` copies only the runtime (`RUNTIME_FILES` = ForgeProbe.server.luau, ForgeTelemetry.luau,
plus `tools/`). `forge seed <slug>` copies all of `game/` into `runs/<slug>/game` and records every human
file in `spec["base_files"]`; the fixer never edits those (`Run.base_files` = runtime + `spec["base_files"]`),
only `forge correct` may (a human asked). `forge promote <slug> <path>` copies a Forge-made file back into
`game/` for a PR. `FORGE_STUDIO=<name part>` picks which connected Studio `forge new|run|correct` use.

## Contracts

### config.py
```python
@dataclass(frozen=True)
class Settings:
    mubit_api_key: str | None      # MUBIT_API_KEY
    provider: str                   # FORGE_PROVIDER: "anthropic" | "openai"   (default anthropic)
    base_url: str                   # MUBIT_BASE_URL (default per provider, see .env.example)
    model: str                      # FORGE_MODEL (default "claude-sonnet-5")
    studio_mcp_path: str            # STUDIO_MCP_PATH
    sync_port: int                  # FORGE_SYNC_PORT (34873)
    repo_root: Path
    runs_dir: Path                  # repo_root / "runs"
    base_game_dir: Path             # repo_root / "game"
def load_settings() -> Settings     # loads .env via python-dotenv
```

### llm.py
```python
@dataclass
class LLMResult:
    text: str; role: str; request_id: str | None; model: str
    latency_ms: int; input_tokens: int | None; output_tokens: int | None

class LLM(Protocol):
    def complete(self, role: str, user: str, *, session_id: str, max_tokens: int = 4096) -> LLMResult
    def complete_json(self, role: str, user: str, *, session_id: str, required: list[str],
                      max_tokens: int = 4096) -> tuple[dict, LLMResult]
        # parses the first JSON object in the reply (parse_reply); on failure sends up to 2 repair calls in
        # the same role (user msg = original user + error + previous output). Raises LLMError after.

def parse_reply(text, required=None) -> (dict, how)   # how: "json" | "lenient" (raw tabs/newlines in strings)
        # | "bracket" (one closer too many) | "tool_call" (<invoke name="probe"><parameter name="code">..., with or
        # without a namespace prefix -> {"action": "probe", "code": ...}; first complete call only, a cut-off call
        # is not used). A non-"json" parse saved a repair call and is logged: note_skipped(llm, kind=
        # "repair_avoided", how, role, session_id, request_id, input_tokens) -> skipped.jsonl next to calls.jsonl
        # (42% of real investigator calls were repairs of tool-call-shaped replies; 30% of patcher calls of raw tabs)

class MubitLLM(LLM):  # __init__(settings, log_path: Path | None)
    # system prompt = (prompts/<role>.md). Appends one JSON line per call to log_path:
    # {ts, role, session_id, model, request_id, latency_ms, input_tokens, output_tokens,
    #  user_chars, reply_chars}
class FakeLLM(LLM):   # __init__(responses, default=None, log_path=None, latency=None) — pops scripted
                      # replies per role; latency (s, or {role: s}) simulates Mubit; peak_concurrency = peak concurrency
class CachedLLM(LLM): # __init__(inner, cache_dir) — runs/.cache/llm/<role>/<sha256>.json for CACHE_ROLES
                      # (designer, coder, planner, critic, reflector) and compile-error fixes only (a critic,
                      # improve or human fix always reaches Mubit); key = (role, sha256(system prompt), model,
                      # max_tokens, user msg); hit -> cached=True, no call, a "cache_hit" line in skipped.jsonl;
                      # aborted / cut-off replies not stored. No other role is cached: real traces have 1 exact
                      # repeat in 1,750 calls (playtests, steps and lessons make every input different)
def make_llm(settings, log_path) -> LLM   # FakeLLM if FORGE_FAKE_LLM=1 (FORGE_FAKE_LATENCY) else
                                          # CachedLLM(MubitLLM) (FORGE_NO_CACHE=1: bare MubitLLM); raises if no key
def jobs_from_env() -> int                # FORGE_JOBS or DEFAULT_JOBS (8)
def stream_verdict(role, text) -> "abort" | "done" | "more"   # streaming early abort / early finish
```
LLMResult also has `cached: bool = False` and `aborted: bool = False`. MubitLLM streams (anthropic;
FORGE_STREAM=0 turns it off): a code role that writes 1500 chars of prose with no fence (or a JSON role with
no `{` and no tool-call tag) is cut short and returned with aborted=True, so the role's own repair/retry path takes over; a code
reply stops reading once its ```luau block closes. A 429 gets RATE_LIMIT_TRIES (6) attempts with
retry-after or exponential backoff with jitter, and every thread waits out the cooldown together.
Roles: `designer`, `coder`, `fixer`, `critic`, `reflector`, `player`, `judge`, ..., `scenarist`
(test plan of executable checks), `check_reviewer` (failing check: game bug or check bug).
Roles: `designer`, `coder`, `fixer`, `critic`, `reflector`, `player`, `judge`, `auditor`, `verifier`,
`triage`, `investigator`, `patcher`, `planner`, `reproducer`, `director`, `fun_critic`, `gap_finder`
(ranked gaps, forge/gaps.py), `code_judge` (ranked code improvements vs the reference game, forge/compare.py),
`anomaly_detector` (forge/autopilot.py registers it, like swarm.py its roles), `architect` (consolidation plans,
forge/consolidate.py).
(ranked gaps, forge/gaps.py), `level_designer` (obby zones as data, forge/levels.py).

Build with the quality brain (default; `forge new --no-director` or `FORGE_DIRECTOR=0` skips the director,
`FORGE_FUN_CRITIC=0` skips the fun critic; tests default both off in the root conftest.py):
```
idea -> director (design doc) -> designer (doc in user msg) -> install_kit (GameAssets.luau) -> coder (style notes)
     -> playtest (+ census) -> critic + fun_critic (issues merged, done needs fun >= 8) -> fixer -> reflector
```

### Fix loop: reproduce, fix, prove (improve.fix_code, `forge fix`)
Default with a live Studio; `forge fix --no-repro` (run_cycle(repro=False)) is the old verifier-only loop.
```
cycle start: run_suite(checks/*.luau + checks/pending/*.luau)    # before faults are planted
             failing check -> anomaly {kind regression|proven_bug, system "checks", check: <id>, high}
budget:      max_fixes counts anomalies that reach a fix attempt; unproven / no-file ones are free, but
             at most max_fixes * REPRO_PER_FIX (3) anomalies are investigated + reproduced per cycle
per anomaly: investigator (as before, its conclusion is a hint; its context is budgeted, see roles.py below)
             -> reproducer writes a check -> luau-compile -> lint_setup (no "setup:" assertion: one extra
                correction call before any Studio time, status no_setup) -> run in the live playtest
                ok=false, no error : PROVEN if its `-- consumer:` names a real game line, saved to
                                     checks/pending/<id>.luau; no real consumer -> no_consumer
                setup failure      : status setup (rerun once in a fresh playtest first), never a proof
                passed / errored /
                setup / no_consumer: one retry, the outcome in the user message (same Mubit task); for
                                     no_consumer the outcome lists the game lines naming what it asserts
                still not failing  : unproven (improve/unproven.json), no fix attempted
             (an anomaly that names a saved check reuses it if it still fails cleanly)
             -> fixer/patcher, problem includes the failing check + its output (and: duplicate/parallel
                objects added only so the check finds them are rejected)
             -> compile -> resync -> run the repro check + every guard (checks that passed at fix start)
                repro still fails  : check_failed, retry with the output, no playtest spent
                a guard fails      : check_regression, retry with the broken checks (a guard that only
                                     failed to set up, also in a fresh playtest, is unknown and does not block)
                both hold          : one playtest round + verifier (evidence); kept unless the verifier
                                     says regression or server errors rose (hard_regressions)
             kept -> version snapshot, check moves pending/ -> checks/ (joins the suite as a guard)
             rolled back -> the check stays in pending/, next cycle starts from it
cycle end:   run_suite again (when fixes ran) -> checks/results.json (scenarios.save_suite_results: the
             plan's review fields kept, verdict pass|game_bug, pending, source "fix cycle <n>"), which is
             what `forge done` reads
```
Cycle JSON (`improve/<n>.json`): `repro: bool`, `checks: {start, start_failing, proven, written, unproven,
kept, end}`; each `code_fixes[i].repro = {check, source: reproducer|saved, before, attempts, saved}` and each
attempt may carry `checks: {repro, guards}`. `scores.json` rows add `proven`, `checks_kept` when repro ran.

### roles.py (all go through LLM; user-message builders live here)
```python
def design(llm, idea: str, lessons: str, *, session_id) -> dict          # Spec
def code_module(llm, spec: dict, module: dict, deps: dict[str, str], lessons: str, *, session_id) -> str
def fix_file(llm, path: str, source: str, problem: str, context: str, lessons: str, *, session_id) -> str
def critique(llm, spec: dict, report: dict, console: str, files: dict[str, str], *, session_id) -> dict
def reflect(llm, lessons: str, iteration_summary: str, *, session_id) -> str   # new lessons.md text
# investigator context (message assembled in improve.investigate_message; every call re-sends it):
def steps_block(steps, focus, budget=STEPS_BUDGET (9000)) -> str   # "## Steps so far"; byte-identical while it
    # fits, else the oldest steps are cut (never the newest STEPS_KEEP=2): a read to its lines matching focus
    # (patch.relevant_excerpt, 2000 chars), a probe's code/result to 500/700 chars
def compact_index(rows[(path, first comment, source)], focus="", budget=INDEX_CHARS (6000)) -> str
    # a game whose plain index is over budget: every file named by folder + the comment lines of the files that
    # best match focus. improve.file_index(game_dir, limit=None, focus="") uses it (the old 12k cut dropped 91
    # of a seeded game's 175 files): investigator (6000, focus = the anomaly), reproducer (no focus, cut at
    # 5000 in repro.py), feature planner (limit 12_000, focus = the request); investigate() also resolves a
    # read/conclude path given by file name alone (the one synced file with that name)
```
Code replies: the model returns the full file in one ```luau fenced block; `extract_luau(text)`
returns its body (raise if missing).

### ui_kit.py (forge/ui_library: house UI style for agent-built games)
```python
MAX_CHARS = 9000                       # coder budget; roles.FIX_UI_KIT_CHARS = 6000, PATCH_UI_KIT_CHARS = 3500
def kind(path, text, *, path_words=True) -> "screen" | "world" | None
    # client path + any UI word, or a ReplicatedStorage module + a screen word -> "screen" (full kit);
    # BillboardGui / price tag words anywhere -> "world" (server-safe snippets only); else None
def select(path, text, *, path_words=True, limit=4) -> list[dict]   # Theme first, then by keyword hits
def block(path, text, budget=MAX_CHARS, *, path_words=True) -> str  # "## UI kit ..." or ""
def designer_block() -> str            # one line per snippet, so the designer names them in purposes
```
`index.json`: `[{name, file, when_to_use, keywords, needs_theme, always?}]`. Snippets are paste-in Luau
(Theme first), not modules: they compile alone and concatenated (tests/test_ui_kit.py).
Where it lands, always in the **user message** (system prompts stay frozen for Mubit):
- `code_module`: `block(path, purpose)` before the closing instruction, shrunk to fit `MAX_USER_CHARS`.
- `fix_file` / `patch_file`: `block(path, problem, path_words=False)` only when the problem is UI;
  never for `luau-compile` problems. A tight budget degrades to rules only.
- `design`: `designer_block()` every call.

### Kit modules (forge/kit/modules: prebuilt, generic, required by agent-written code)
`index.json`: `[{name, path_in_game, genres, keywords, describe, api}]`; each `<name>.luau` installs
unchanged as `path_in_game` = `ReplicatedStorage/Kit/<name>.luau`, and `api` is the short contract a coder's
user message lists (tests/test_kit_modules.py).
- `MusicPlayer` (client): `start({areas, attribute = "Area", default = "lobby", volume = 0.35, fade = 1.5,
  muteButton})` plays the area in that LocalPlayer attribute, crossfades on change (at most two Sounds, in
  `SoundService.ForgeMusic`), mute button + `MusicMuted` attribute; `setArea`, `play(mood|track)`, `setMuted`.
  Tracks = `sounds.json` "music": 16 Roblox-licensed APM ids in 8 moods (carnival, pop, lobby, spooky,
  pirate, intense, victory, water), each loaded on Client and Server in a Studio playtest (`checked`).
- `Cosmetics` (server): 17 part-built costumes (7 hats, 4 capes, 3 trails, 3 body colours; no asset ids),
  `start({currency, costumes, prices, rewards, autoEquip, store, balance?, spend?})`, buy/equip/unequip
  through `ReplicatedStorage.CosmeticsRemotes.Request` (server checks ownership, price, rate), saved in a
  DataStore or in memory (unpublished Studio place); `buildChangingRoom({cframe, ids})` puts mannequin
  stands with "Try on" prompts (tag `CostumeStand`, attributes `Costume`/`Price`/`Slot`).
- `CosmeticsClient` (client): the house-style costume panel + HUD button; opens from the stand prompts.
- `ObbyThemes` (server, genre obby; needs ObbyKit v2's `opts.themes`): `dress(kind, model, params, theme, rng) -> Model
  "Dressing"` dresses one `ObbyKit.Obstacles.<kind>` piece (v2 platform shapes `cylinder` and `wedge-ramp` included, by
  their `Shape` attribute) as part of a ride; `stageDecor(stageModel, theme, rng, stage) -> Model "StageDecor"` adds
  lamps on brackets, string lights, balloons and a sign with the stage's name (<= `MAX_STAGE_PARTS` 60). Themes
  (`THEMES`): entrance, carousel, bumper, teacups, ferris, flume, haunted, pirate, coaster, finale; `resolve(text)`
  maps free text to one (nil or blank -> nil: `dress` and `stageDecor` then add nothing). Rules: decoration parts are
  CanCollide/CanTouch/CanQuery false and Massless; `Dressing.Rides` (attribute `Host` = Mover, Turntable, Bar or Ball)
  holds the parts welded to the moving part (carousel horses bob on a Weld in the host's frame), everything else is
  anchored. The body space over every walkable top (footprint + 0.5, 0.12 to 7 studs up, over a mover's whole path)
  stays empty: props stand on brackets past the margin and are built as groups that are dropped whole when they would
  reach in; `stageDecor` sweeps this stage's decorations and those of stages already built around it (found by a
  spatial query) out of every body space. Nothing that reads as floor sits within 0.7 under a top and reaches more than
  0.5 past its edge. Legs are sized by a raycast down (MAX_LEG 90 studs; none across the course: a bracket instead).
  The theme owns walkable tops (Color, Material; vanishing tiles re-coloured on every solid, the kit's warning flash
  kept), kill parts (Neon, `KILL` red-orange per theme), the checkpoint Flag (Transparency 1, a pennant instead), Hub,
  turntable Stripes, conveyor Chevrons and the pendulum Posts/Beam/Rod; each changed property is saved as
  `ThemeOrig_<property>` and restored, and its `ThemeFx` emitters removed, before the next dress. Collision parts are
  never moved or resized, so `LevelBuilder.audit` is unchanged. tests/test_obby_themes.py checks all of it with its own
  geometry, on every theme x kind, turned stages, the Funfair Frenzy levels (tests/fixtures/funfair_levels.json) built
  in v2's order, v2 shapes and ground for legs. Live proof: `scripts/obby_themes_demo.py --studio <id> [--gallery]
  [--play]` (play mode: drift of riding decorations, horse bob, tile fading -> `play-proof.json`).
- `WorldKit` (server + client, picked by park words only: park, amusement, funfair, carnival, theme park,
  fairground): `buildPark({zones = {{name, theme, palette, length?}}, origin, size = 1600, seed, title}) -> {anchors,
  gates, spawn, lobby, courses, parts}` builds the whole amusement park in `workspace.Park`: Terrain ground reaching
  at least 1,500 studs past the farthest course, sky, fence + tree line + hills, the entrance gate with a forecourt
  outside it (the SpawnLocation `ParkSpawn` 44 studs out, facing the gate), a lobby plaza with a fountain and a park
  map, one animated landmark per zone, stalls, balloons, string lights, gardens. Zone 1 starts at the top of the
  START stairs beside the lobby; zone i>1 on a tower on the circle r = 0.64 * size / 2, every `anchors[i]` facing the
  clockwise tangent (park on the course's right). Each zone's course is measured before anything is placed: zone i of
  `ReplicatedStorage.Levels` laid out with the game's ObbyKit (`LevelBuilder.layout` per stage, each stage turned by
  its `turn` when ObbyKit.VERSION >= 2), else `length` studs straight (default 460, the zone plot of forge/obby.py);
  `courses[i]` = its centre line (start pad, then every checkpoint) in world space. The park is built around those
  lines: nothing taller than 6 studs within 40 studs of a course from 24 behind its start to 40 past its end; every
  course is dressed from start to end (lamps strung with lights 46 studs out on both sides, stalls 64 out, a ride,
  booth corner or balloon arch further out, trees, and low gardens, cafe tables, mini golf, queue mazes and kiddie
  rides under it, sparser when the courses are long); a course that runs beyond the circle gets a paved midway under
  it, a corridor 118 studs to each side that the fence and tree line go round, and hills along both sides beyond it;
  a hill and a mountain stand past every course's end. About 25k parts for ten 460-stud courses, 41k (built in about
  2.4 s in Studio) for the ten 1.4-2.3k-stud straight courses of the overnight funfair game (tests/test_worldkit.py
  checks the clearance, the dressing within 80 studs of every 40-stud stretch, measuring with turns, and the ground's
  reach headless). `landmark(theme, cframe, palette)` and
  `dressing(kind, cframe, palette, text?, seed?)` build one piece (dressing seeded by its position unless a seed is
  given). Rides move from data: each moving root carries WK* attributes (`WKMotion` kind, `WKRest`, `WKPivot`, ...)
  and the tag `WorldKitMover`; `WorldKit.client()` (a LocalScript) runs every mover within 900 studs of the camera once
  per rendered frame on the shared server clock and fires the `WorldKitMotion` remote, after which the server stops
  moving them; until then the server moves the movers that have a player within 400 studs, 30 times a second.

Spec (designer output):
```json
{"title": "...", "slug": "kebab-case", "pitch": "one line", "core_loop": "...",
 "modules": [{"path": "ServerScriptService/Game.server.luau", "purpose": "...",
              "depends": ["ReplicatedStorage/Config.luau"]}],
 "acceptance": ["players spawn on the map", "..."]}
```
Critique: `{"score": 0-10, "summary": "...", "issues": [{"path": "...", "problem": "...",
"fix_hint": "..."}], "done": bool}`

### game/tools/sync.py (stdlib only, runnable standalone: `python3 game/tools/sync.py <cmd> --root DIR`)
- `check --root DIR` → exit 0/1; prints `FAIL <file>\n<msg>` per bad file (uses `luau-compile --null`).
  As a library: `check(root: Path) -> list[tuple[str, str]]` (relative path, error).
- `manifest --root DIR` → writes `DIR/tools/manifest.json`: `[{service, dirs, name, class, path, hash, size}]`
  (`hash` = sha1 of the file, 16 hex; `size` = UTF-8 byte length). Library: `manifest_entries(root)`,
  `hashes(entries) -> {path: hash}`, `changed_paths(entries, pushed) -> {changed, added, removed}`,
  `inline_plan(root, entries, pushed, budget) -> {path: source}`, `long_string(text)` (Luau literal).
- `serve --root DIR --port P` → HTTP file server for DIR on 127.0.0.1. As a library:
  `serve_in_thread(root, port) -> ThreadingHTTPServer`.
- `pull_luau(port, prune=True, manifest=None, inline=None, force=False) -> str` → Luau source for
  execute_luau. Incremental: every synced script carries `ForgeHash`/`ForgeLen` attributes and is
  skipped when they match the manifest; only changed files are written. `manifest`/`inline` embed the
  manifest and those sources in the script (one MCP call, no HTTP); anything else that changed is
  fetched from the file server. `force=True` fetches every file (the original behaviour). If prune,
  deletes scripts under the synced roots tagged `ForgeManaged` but no longer in the manifest. Returns
  `OK n files, changed: a, b[; pruned: …]; skipped k, fetched m` or `ERROR ...`.
- `tools/headless.luau`: a fake Roblox engine for the plain `luau` CLI (see checks.py, headless).
- Mapping: `X.server.luau` → Script, `X.client.luau` → LocalScript, `X.luau` → ModuleScript;
  roots ServerScriptService, ReplicatedStorage, StarterPlayerScripts (→ StarterPlayer.StarterPlayerScripts),
  also ServerStorage, StarterGui, Workspace if present.

### ForgeProbe runtime contract (game/ServerScriptService/ForgeProbe.server.luau)
During a playtest it records `ScriptContext.Error` and `LogService.MessageOut` (warnings/errors),
player joins, and any `ForgeProbe` attribute counters games set. It exposes
`ServerStorage.ForgeProbe` (BindableFunction): `Invoke("hotreload", liveModule, clone)` copies the
clone's functions into the live module table (used by `Studio.hot_reload`); `Invoke("report")` returns a JSON string:
```json
{"uptime": 12.3, "errors": [{"message": "...", "trace": "...", "script": "..."}],
 "warnings": ["..."], "players": 1, "counters": {"coins_collected": 3}, "instances": 412,
 "physics": {"flagged": [{"path", "model", "kind": "jitter|drift", "max_speed", "max_angvel", "moved_studs",
             "windows", "last"}], "watched": 3, "loudest": [{"path", "max_speed", "max_angvel"}]}}
```
`physics` comes from a sampler (every 0.5 s, at most 150 unanchored assembly roots, no Humanoid, no
occupied seat; details in docs/TESTER.md). `Invoke("physics")` returns just that object.
Games may call `require(ReplicatedStorage.ForgeTelemetry).count(name, n)` to bump counters
(ReplicatedStorage/ForgeTelemetry.luau), on the server and, in Studio playtests, on the client: a LocalScript's
counts are summed and sent at most every 0.25 s over one RemoteEvent, `ReplicatedStorage.ForgeTelemetryRemote`,
which the server copy creates when first required in a running playtest (ForgeProbe requires it at boot; one
listener per server, marked by the remote's `Listening` attribute, so an execute_luau VM never counts twice). The
server re-validates every message: names `^[%w_]+$`, at most 64 chars, no `RBX` prefix, at most 64 distinct names
per player, 32 names and 1000 per name per message, 8 messages per player per second; drops are counted as
`telemetry_client_dropped`. Server behaviour is unchanged; get() stays server-only. No game needs its own *Ack
remote to count a client moment: the coder (every message), fixer/patcher (problems about counters) and planner
(`forge feature`, which refreshes the game's runtime files first) are told so in their USER messages
(roles.CLIENT_TELEMETRY_NOTE), because coder.md and planner.md are frozen Mubit prompts. Also `ServerStorage.DevHook`
(BindableFunction) `Invoke(moduleName, method, ...)` to reach live server modules from execute_luau.

### studio.py
```python
class Studio:  # async context manager; one StudioMCP session (reconnects once if it dies)
    timings: list[tuple[str, float]]                      # (tool, seconds) of every call
    async def list_studios(self) -> list[dict]            # [{id, name}]
    async def select(self, name_hint: str | None = None) -> str   # id, exact name, then substring
    async def call(self, tool: str, **args) -> str        # raw tool call, returns text content
    async def execute_luau(self, code: str, datamodel: str = "Edit") -> str
    async def state(self) -> dict
    async def play(self, ready: bool = True, ready_timeout: float = 30.0) -> dict  # start, Server DM, then wait_ready
    async def wait_ready(self, timeout=30.0, grace=0.5) -> dict  # one Server call that waits in Studio for
                                                          # ForgeProbe + ServerBooted (or a character): {ready, reason, waited}
    async def stop(self) -> None
    async def console(self) -> str
    async def screenshot(self, out: Path) -> Path | None  # screen_capture; saves image if returned
    async def probe_report(self) -> dict                  # execute_luau in Server DM: ForgeProbe:Invoke("report")
    async def sync(self, root, port=None, prune=True, incremental=True) -> str  # hashed incremental pull in one
                                                          # call; long-lived file server (free port if taken)
    async def hot_reload(self, root: Path) -> dict        # during play: changed server ModuleScripts swapped in
                                                          # place -> {reloaded, restart: [(path, why)], changed}
    async def bridge(self, datamodel: str | None = None) -> BridgeClient | None  # ForgeBridge plugin of THIS
                                                          # window connected? execute_luau / play / stop then
                                                          # go through it (no MCP round trip); FORGE_BRIDGE=0 off
def hot_reload_plan(entries, changed, sources, added=()) -> {"reload": [...], "restart": [(path, why)]}
```

### checks.py: headless runs (no Studio)
```python
def boot_offline(game_dir, boot=2.0, play=3.0, players=1, clients=False) -> dict
    # ForgeProbe-shaped report + misses, needs_studio [{feature, count, script}], approx, client_errors, engine
def verdict(res) -> "pass" | "fail" | "unknown" | "needs_studio"
def run_check_offline(game_dir, check, timeout=90.0, *, clients=True) -> dict
    # runs checks.wrap(body) (forge helpers included) on a fresh server + 1 simulated client; run_check's shape +
    # where="offline", verdict, sim, needs_studio/misses hit while it ran (needs_studio => ok False, never a pass)
def run_checks_offline(game_dir, checks, timeout=90.0, workers=8) -> list[dict]
def triage(game_dir, checks, mode=None) -> (trusted_results, checks_for_studio)
    # mode = headless.studio_mode(): auto trusts headless passes (fail / unknown / needs_studio -> Studio);
    # never trusts every headless verdict (needs_studio -> unknown results, nothing for Studio); always: ([], all)
def run_specs(spec_dir) -> list[dict]                                # *.spec.luau with the luau CLI
# a check file may say `-- needs: studio` (physics, rendering, replication): never run offline
# run_check (Studio or a HeadlessStudio session) counts itself in the usage ledger (headless.record)
```

### headless.py: headless by default (no Studio unless it needs a renderer)
```python
STUDIO_MODES = ("auto", "always", "never")   # --studio MODE on any command (cli.take_studio_mode) -> $FORGE_STUDIO_MODE
def studio_mode(flag=None) -> str            # flag | $FORGE_STUDIO_MODE | "auto"
def wants_studio(*, needs_ui=False, mode=None) -> bool   # always | auto and the job must press real UI
class NeedsStudio(StudioError)               # screenshot / real input / renderer asked of a headless session
class HeadlessStudio(game_dir, players=1, clients=True, boot=2.0, settle=1.0, idle="wall"|float, slug, kind)
    # duck-types studio.Studio: execute_luau(code, "Server"|"Client"|"Client:<n|name>", timeout) / call(
    # "execute_luau"|"get_studio_state") / state / play (fresh server) / stop / wait_ready / probe_report /
    # console / sync(root) / hot_reload / run(seconds) / press(user, path=, text=) ; screenshot -> NeedsStudio ;
    # list_studios -> []. press (Harness.press delegates to it headless): on that player's client, the shown
    # GuiButton by path/text gets MouseButton1Down/Up/Click + Activated, then a screen/leaderstats diff
    # (no layout: a covered button still fires; Harness.ui_windows lists every simulated client)
    # (the `luau -i` REPL over a pty; one H.rpc line per call; the world advances min(wall gap, 10 s) between
    # calls with idle="wall"). Harness, checks.run_check, scenarios, fun.census, qa_test and run_swarm run on it.
async def backend(settings, game_dir, *, needs_ui=False, studio_name=None, players=2, slug, kind)  # ctx manager:
    # Studio when wants_studio(), else a HeadlessStudio (fix cycles: cli._improve; polish: feature.polish_feature)
async def playtest(game_dir, *, play=20.0, players=2, clients=True, slug="", start_round=False) -> dict
    # the build loop's playtest: probe report + fun.census (server and client halves) + engine="headless",
    # wall, simulated, needs_studio, approx
def record(kind, where, seconds, *, slug, n=1, ok=None, note) / usage_stats(since, slug) -> dict
    # runs/_engine_usage.jsonl: every check / playtest / tester session / screenshot, headless or studio
    # (`forge headless --stats`); tests never write it
```
The engine (game/tools/headless.luau) models: server + simulated clients in one Instance tree (threads carry
their side: Players.LocalPlayer, RunService:IsClient, per-side require caches; a client sees nothing in
ServerStorage/ServerScriptService and nobody sees another client's instances); remotes client <-> server a
frame later with copied arguments (FireServer/FireClient/FireAllClients/InvokeServer/InvokeClient, per-client
OnClientInvoke); Humanoid:MoveTo/Move at WalkSpeed (kinematic: no collisions or gravity; MoveToFinished, 8 s
timeout); Touched/TouchEnded from character and moving-part box overlaps; ProximityPrompt shown in range
(PromptShown/Hidden per client, OnePerButton) and InputHoldBegin/End with HoldDuration -> Triggered +
PromptTriggered; AssemblyLinearVelocity integrated; Raycast and Get*Bounds* over part boxes (a lazily kept
uniform grid); the clock is frames/30 exactly (task.wait(60) is 60 s; a minute of game in ~1 s). It reports
`needs_studio` for physics movers/constraints, impulses, camera projection, UI layout (Absolute*), shape casts,
and `approx` for what it rounds off; a check that touches needs_studio is never a headless pass.

### bridge.py (docs/STUDIO_PLUGIN.md)
```python
class Bridge(token, places, ...)        # thread-safe state: sessions per datamodel, command queue, event ring
    hello/poll/result/add_events/bye    # plugin side          run(op, args, dm, timeout) -> {ok, result|error, ms}
    get_events(since, types, limit, wait) -> {events, next, latest}; status() -> dict; set_forge(**fields)
class BridgeClient(port, token)         # status() events() run() luau(code, dm) set_status(job=, role=, last_test=)
def connected_client(place, dm, port) -> BridgeClient | None
def register(mcp) -> ["studio_status", "studio_events", "studio_run"]   # via the mubit_tester.studio_bridge extension
def build_plugin(repo_root, token, port, places) -> str; install_plugin(repo_root, places, plugins_dir, port) -> Path
```
```
forge plugin install --place NAME [--plugins-dir D]   forge plugin serve --place NAME   forge plugin status|events [--follow]
forge plugin load --studio NAME          forge plugin bench --studio NAME [-n 20]
```

### assets.py (docs/game/07-assets.md)
```python
def load_manifest(path=MANIFEST) -> dict; def save_manifest(data, path=MANIFEST) -> None
def render_asset_ids(data) -> str            # AssetIds.luau text: X / X_<extra> -> "rbxassetid://..." or ""
def sync_ids(data, out=ASSET_IDS_LUAU, check=False) -> bool   # True if changed / stale
async def generate_entry(studio, e, keep=False, log=print) -> dict  # generate_mesh | generate_material |
                                                    # generate_procedural_model (async + wait_job_finished)
async def search_entry(studio, e, query=None, max_results=5) -> list[dict]  # search_asset -> e["candidates"]
def pick(e, n=None, asset_id=None) -> dict
def upload_entry(e, root, *, env=None, http=..., poll_interval=1.0, max_polls=60, sleep=time.sleep) -> dict
                                                    # Open Cloud POST assets/v1/assets + poll operations/{id}
```
```
forge assets list [--status S] [--kind K]
forge assets generate <id...>|--all [--keep] [--dry-run] [--studio NAME]
forge assets search <id> [--query Q] [--max N] [--pick N | --pick-id ID] [--studio NAME]
forge assets upload <id...>|--all [--dry-run]
forge assets sync [--check]
```

### loop.py / memory.py / cli.py
```
forge doctor                       # checks key, luau-compile, StudioMCP binary, studios connected
forge <any command> --studio auto|always|never   # Studio policy (forge/headless.py), default auto: playtests,
                                                 # checks, fix cycles and testers run headless; Studio only for
                                                 # screenshots, UI presses, checks that fail headless, final verify
forge new "<idea>" [--iterations N] [--no-studio] [--jobs N] [--no-cache]   # design + build + playtest loop
forge run <slug> [--iterations N] [--no-studio] [--jobs N] [--no-cache]     # continue iterating an existing game
    # each iteration playtests headless (Run.headless_playtest: 2 simulated players, 30 s simulated) and, with
    # FORGE_STUDIO set, one Studio screenshot pass (Run.screenshot_pass) alongside the critic; busy -> skipped
    # with a note. --studio always: the old Studio playtest. --no-studio = never (still a headless playtest)
forge headless [<slug>|--root DIR] [--play S] [--players N] [--no-clients] [--playtest] [--stats [--since H]]
forge correct <slug> <path> "<note>"                # human correction → fixer call → resync
forge status [<slug>]                                # iterations, scores, call counts per role
forge seed <slug> [--spec FILE]                      # runs/<slug>/game <- game/ (+ spec base_files)
forge promote <slug> <path>                          # runs/<slug>/game/<path> -> game/<path>
forge improve <slug> [--cycles N --rounds R --only ids]  # faults -> playtests -> auditor -> fix -> verifier
forge scores <slug>                                  # detected / missed / fixed per improve cycle
forge report <slug> "<text>" [--run ID] [--by NAME]  # tester report -> triage -> auditor correction
forge reports <slug>
forge versions <slug>                                # saved versions (iterations, fixes, rollbacks)
forge rollback <slug> <vN> [--studio S] [--no-sync]  # restore a version, resync Studio
forge fix <slug> [--cycles N --max-fixes M --reports]  # real anomalies: code fix, verify, until clean
forge checks <slug> [--plan [--max N]] [--run [--headless-first]] [--studio S]  # scenario designer; no flag:
                                                     # list checks; --run is headless first by default
                                                     # (checks.triage); Studio runs the rest (--studio always: all)
forge orchestrate <slug> --goal G [--studio P1,P2 | --no-studio] [--workers 4] [--max-calls 300] [--minutes 120]
                  [--rounds 3] [--per-round 4] [--min-rank 2] [--no-checks] [--no-fix-cycle]   # team lead loop
forge gaps <slug> [--find] [--goal G] [--correct NOTE [--reject ID ...]] [--json]  # ranked gap list
forge autopilot <idea|slug> [--studio P] [--max-calls 250] [--minutes 120] [--rounds 4] [--per-round 3]
                [--target 8] [--qa-steps 4] [--swarm-players 2] [--swarm-minutes 1] [--no-critic] [--status]
forge autopilot [<slug>] --correct <id> "<note>"     # correction call in the task that made the finding
forge autopilot --advise [--root game] [--name N] [--evidence DIR ...]   # read-only report, no edits
forge queue <slug>                                   # orchestrator jobs, leases, budget
forge reflect <slug> [--llm]                         # reflection since the last one -> runs/<slug>/reflection/<n>.md
forge reflect --all                                  # every game summed -> runs/reflection.md
forge consolidate <slug> [--plan-only] [--max-merges 6] [--studio S]  # architect pass, gated, rolled back on failure
forge compare <slug|dir> [--against game|slug|dir] [--llm] [--json]  # code vs the reference game: 0-10 per
                                                     # category, evidence, gaps with reference files to copy
forge interactions [<slug>|--root DIR] [--json]      # static audit: dead prompts/buttons/detectors/remotes, exit 1 if any
forge journey <slug> [--studio S] [--clicks] [--no-sync] [--shots DIR] [--json]  # live player journey (headless
                                                     # unless --studio), saved to runs/<slug>/journey/, exit 1 on a fail
```

### Interaction gates (forge/interactions.py, forge/journey.py)
The overnight Funfair Frenzy obby made a "Try on costumes" prompt nothing handled, a RESET button whose remote
nothing listened to, a GIFT button under the Skip Stage button, and a lobby on the grey template baseplate. Two hard
parts of `forge done` catch that class of bug.
```python
# interactions.py (needs luau-ast, shipped with luau; without it the part is unknown, never a pass)
def audit(game_dir) -> {ok, findings[{id, kind, severity, file, line, object, detail, fix, kit}], stats, errors}
    # kinds: prompt_no_handler, click_no_handler (high), button_no_handler (medium), remote_no_listener,
    # remote_no_answer (high), remote_never_fired (medium), bindable_no_answer (high), bindable_no_listener /
    # bindable_never_fired (low). ok = no high/medium finding. Matching: the same value (locals, aliases, helper
    # returns per call site, parameters of local functions with their call sites), the Name (FindFirstChild /
    # WaitForChild / index lookups, Config module constants; a lookup T.k on a table filled as T[k] = r names k or
    # any string a table record maps k to, e.g. Config.Remotes = {Reset = "ResetToCheckpoint"}), a PromptTriggered
    # handler that tests for something the prompt carries. Remotes match by name, not by folder: a listener on a
    # same-named remote in another folder reads as connected (the journey's buttons step catches it live). A generic handler (a class lookup, a loop over GetChildren / GetDescendants / GetTagged, a
    # ChildAdded / DescendantAdded callback, a connection on a value it cannot follow, a catch-all PromptTriggered)
    # reaches only its container (parent links followed up), its tag, or without one its own file; an unknown
    # container reaches anything. Tool.Activated is not a button handler (IsA("Tool") / ClassName == "Tool" on the
    # target, or a Backpack / StarterPack / character source). A zero-size button is not a control (stats.inert).
    # An object whose flow it cannot see (stored in a table, returned to unseen callers, passed to an unknown
    # function) is `unknown`. A remote site with an unknown alternative may be any remote: it suppresses findings
    # (stats.suppressed[{at file:line, site, off, for}]) instead of making one.
    # stats = {files, objects, handled (matched), generic, generic_at {file:line: n}, unknown, inert, senders,
    # receivers, suppressed, tool_connections}. id = kind:file:object (+ #n for identical objects): no line.
    # Skipped: gaps.RUNTIME_FILES, tools/, tests/, kit modules the game never names (kit findings: kit=True)
def as_anomalies(res) -> [{kind dead_interaction, system interactions, severity, title, observed, expected, proof,
                           finding{kind, file, object, count, in_file}, ref ref_of(x), path (not for kit)}]
def ref_of(finding) -> "dead:<file>:<kind>:<object slug>[#n]"   # stable across edits that shift lines
def still_dead(game_dir, finding) -> "" | why     # after a fix: is a finding of its kind, file and object left (or
                                                  # as many of its kind in the file as before: a rename)?
def coverage(stats) / summary(res) / render(res)  # what was matched, generic-only, not followed, suppressed
# journey.py
async def run_journey(studio, *, clicks=False, shots=None, log) -> {ok, engine, clicks, player,
    steps[{step, ok (None = n/a or unknown), detail, evidence, secs, skipped?, shot?}], prompts[...], buttons[...],
    secs}
    # steps: join; lobby (census >= 40 parts, 5 colours, 5 tall parts within 200 studs; the biggest ground part is
    # not the Baseplate nor default-grey plastic and default-grey ground shows on <= 25% of the square around the
    # spawn (headless adds the place's template Baseplate back unless the game's code names it); with the WorldKit
    # kit a Workspace.Park and a Landmark-tagged ride within 600 studs); prompts (each prompt within 150 studs of
    # the spawn, after BOOT_SECONDS since the join and a settled client GUI: walk, settle, a QUIET ambient window,
    # one press, up to EFFECT_LOOKS looks EFFECT_WAIT apart. Each look diffs a server snapshot (attributes,
    # leaderstats, character children, Costume_* models and how they sit on the body, parts near the prompt,
    # position) and a client snapshot (visible GUI objects, same-named siblings indexed) minus ambient change;
    # observable = a panel opened, an attribute / leaderstat / costume / character / part changed, or a move >= 8
    # studs. Then close(): the opened panel's X / Close / Back button (a press: headless or clicks=True), waiting for
    # a toast to go by itself, the prompt again (a toggle), walking away; it must leave the screen before the next
    # before-picture. Nothing closes it: the prompt fails ("cannot be closed"). Studio without clicks: left open, and
    # a later prompt that only reopens it is unknown. A move is undone with a harness teleport); costume (a costume
    # prompt puts a costume on itself, or opens a panel whose WEAR is pressed (Studio without clicks: the kit's
    # CosmeticsRemotes.Request); the costume shows: visible parts within 3 studs of the body (the head for a head
    # costume), an effect, or body colours; the costume shot is taken with the panel closed, or hidden for the shot);
    # stage1 (walk to ObbyStart, obby_try 0 -> 1); respawn (KillPart); layout (every on-screen GuiButton outside
    # the Core / Forge GUIs is the top-most input-sinking object at its centre: Studio PlayerGui:GetGuiObjectsAtPosition,
    # headless rectangles from Size / Position / AnchorPoint / UIPadding / UISizeConstraint ordered by DisplayOrder and
    # Sibling / Global ZIndex, unknown when a layout object, scroll, scale or rotation places it); buttons (each
    # uncovered button pressed once: a panel, a text change, a GUI object gone, an attribute / leaderstat / counter,
    # a move (not a sound: funfair's HUD clicks on every press); a button whose label counts down (GIFT 1:10) and
    # does nothing is on cooldown, reported but not judged; a RESET / respawn button after stage1: the player is teleported off checkpoint N and must be back on
    # it within RESPAWN_WAIT; Studio without clicks: unknown); ride (ObbyKit v2: the first RideGate's checkpoint via
    # the kit fixture teleport_stage, its RidePrompt, then the player within 12 studs of the next zone's
    # ObbyZoneStart with Stage >= the gate's). After every teleport fixture the leftover walk of obby_try is stopped.
def save(run_dir, rec, game_dir=None) -> path  # <n>.json, latest.json, latest-<engine>.json; game_hash = sha1 of the
                                               # .luau files, None without game_dir (forge journey --no-sync: stale)
def latest(run_dir, engine=None) / fresh(rec, game_dir)
def for_done(run_dir, game_dir) -> rec          # fresh latest of each engine merged step by step (merge(): Studio's
                                               # verdict where it has one, else headless), else latest.json
def summary(rec, game_dir) -> (ok, detail)      # stale when game_hash differs or is None
def as_anomalies(rec, findings)                 # a failed step whose every failing prompt / button a static finding
                                               # explains carries `static` and that file as `path`
def still_failing(rec, anomaly, base) -> "" | why  # the fix loop's judge (see Wiring)
def anomalies_for(game_dir, run_dir) / refresh(harness, game_dir, run_dir, force=False) / brief(rec) ->
    {ok, failing, passing} / confirm(first, second) / enabled()  # FORGE_JOURNEY=0 (tests' default): loop off
```
Wiring: `forge done` parts `interactions` + `journey`. Fix loop (improve.run_cycle, fix=True): refresh() before
anything else when the latest journey is missing or stale (always on a fresh server: headless a new session of the
game, Studio a restarted playtest; the cycle's own player has been playtesting); anomalies_for() goes first in the cycle's anomalies (a
journey failure a static finding explains is left out), ahead of the auditor's for the max_fixes budget; after kept
fixes the journey runs again. Anomalies with `proof` skip the reproducer and the investigator's unproven gate
(fix_code); one with `finding` is re-audited after each attempt (still_dead: rejected before any playtest). Then
(fix_code(journey_judge=True), what run_cycle passes when the journey is on) every attempt at a dead interaction or
a failed journey step is judged by the live journey on a fresh server (journey.still_failing(rec, anomaly, base)):
its own evidence must pass (the step; for a prompts / buttons step every item it used before, so a button the fix
uncovered is the next anomaly, not a veto; for a static finding the prompts / buttons it names: a clean audit
while the game still does nothing is a rejection) and no step that passed before may fail; then it is kept unless
the verifier says regression. Autopilot: measurements carry `dead` (count) and `journey` (brief;
run headless in _headless_part, in Studio in _studio_part); the evidence store gets `dead:*` / `journey:*` items;
detect() puts hard_anomaly() of each first (confidence 1, a fix job on the named file; id = slug + sha1 of the ref);
gate() rolls back more dead interactions or a journey step that passed and now fails, but a rollback whose only
reasons are lost journey steps (or dead counters) is confirmed first: a second journey (Autopilot(journeyer=...),
default rerun_journey, headless) or a full re-measure, and a step counts as lost only when it failed both times.

### Consolidate (forge/consolidate.py, `forge consolidate`)
Features built one at a time each add their own files; this pass gives a game the reference's shape. Never touched:
ReplicatedStorage/Kit/*, ReplicatedStorage/Levels/*, GameAssets, the Forge runtime, tools/, spec base_files and
prebuilt modules, and Forge's own bootstraps from an earlier pass (`protected_paths`).
```
map      module_map(game_dir, protected): per file path, type, lines, chars, first comment line, game modules it
         requires and is required by, remotes it creates / fires / handles, counters, public functions; a module
         nothing requires or even names is flagged "never runs". module_refs resolves lookups (GetService locals,
         script.Parent chains and their locals, PlayerScripts locals, one level of folder locals) on lines that
         require, or whose local is required within 6 lines; dangling(game_dir) = lookups whose target is gone
plan     architect (Mubit task, prompts/architect.md) <- user message: spec + features, the map, compare's
         architecture category (metrics below the reference, gaps + reference pointers), the prebuilt list, limits,
         and the last pass's refusal reasons when it was rolled back -> {summary, merges[{into, from, purpose, why}],
         server_bootstrap[{from Script, into Services/<X>Service.luau}], client_bootstrap[{from LocalScript, into
         Controllers/<X>Controller.luau}], delete[{path, why}], rewire[{path, change}]}
validate refused (a problem line each): prebuilt / runtime / bootstrap paths, sides mixed (server, client, shared),
         a file in two entries, an into that exists and is not one of its originals, originals over
         MERGE_SOURCE_CHARS (18k), units over --max-merges (6); callers of every merged or deleted module are added as
         rewires; files that still name a deleted file's remote are reported. Problems -> ONE correction call (same
         task, previous plan + problems); then the clean plan runs. --plan-only stops here, changes nothing
baseline copy_base_game (current runtime: ForgeTelemetry with the client channel), snapshot "before consolidate",
         measure(): sync, the saved checks (scenarios.run_in_sessions, no reviewer), probe(): play, a player, 12 s,
         ForgeProbe report + the Client datamodel's LogService errors/warnings, stop
build    coder per unit, in parallel: the originals' full source, their public functions, the callers' call sites
         (6 lines around each), every move of the pass, the Init/Start contract for a service/controller, kit API,
         client telemetry note -> compile + fixer; originals and deletes removed; Main.server.luau / Main.client.luau
         copied from forge/kit/bootstrap when a service / controller was written; rewires: patcher (over 300 lines) or
         fixer + destructive guard, problem = the moves that concern the file + the change, context = the new
         modules' API + the deleted files' code; compile (touched files) -> new dangling lookups -> one
         fixer/patcher pass
gate     measure() again; a check that passed and fails now is rerun once; probe findings (new server or client
         errors (numbers normalised), new warnings naming a changed module or "[Boot]", a counter that was above 0
         and is gone, no player) must repeat in a second probe
outcome  kept: snapshot "consolidate: ...", spec modules (removed paths out, new files + bootstraps in, so `forge run`
         does not rebuild a merged-away module), spec["consolidations"], state rollback_floor, checks/results.json
         (source "consolidate <n>"), compare before + after saved; rolled back: GameVersions.restore(before) as a new
         version, Studio resynced; record runs/<slug>/consolidate/<n>.json {plan, problems, request_ids, before,
         execute, after, why, outcome, version_before/after, compare_before/after}
```

### Reflection (forge/reflect.py)
`forge new`, `forge fix` (also when it stops early) and every `forge orchestrate` round end with
`maybe_reflect(settings, slug, label=, since=None)`: no LLM call, never fails the command. A reflection covers
everything since the previous one (the first: the whole run; an orchestrate round: since the round started, so
it may overlap its fix job's own reflection). It reads only existing records: every calls.jsonl and skipped.jsonl
under runs/<slug>/, traces (JSON repair calls, fixer retries), improve/<n>.json, state.json + iteration records,
timings.json, features.jsonl.
```python
def reflect(settings, slug, *, label="", since=None, llm=None, log=print) -> rec | None   # None: nothing new
    # rec {n, slug, label, ts, since, until, attempted[str], done{ready, ok, of, failing},
    #      summary{calls, input_tokens, output_tokens, latency_s, errors, cache_hits, repairs_avoided,
    #              saved_input_tokens, by_role{role: {calls, input_tokens, output_tokens, latency_s, errors, aborted,
    #              over_run_size (> 8k tokens), repairs, retries, cache_hits, repairs_avoided}}, by_stage{stage: {calls,
    #              input_tokens, latency_s, share}}, wall_stages, fixes[{cycle, anomaly, path, status, attempts,
    #              investigation_steps, repro}], kept, rolled_back, unproven, failures{cause: n}},
    #      weaknesses[{id, finding, evidence, fix, wasted_calls}], llm?}
    # failures: fix statuses (unproven, no_file, ...), every rejected attempt (check_failed, check_regression,
    #   regression, fixer_error, ...), reproducer_<status>, setup_error (checks that failed in "setup:"),
    #   mubit_rate_limit / mubit_overloaded / mubit_error, step_<name> (failed build-loop steps)
    # weaknesses (heuristics): json_repairs, oversized_calls, aborted_replies, investigator_step_cap,
    #   investigated_then_unproven, guard_setup_rejections, retry_repeated_failure, cycle_kept_nothing,
    #   check_setup_errors, verifier_vetoes, mubit_errors, dominant_stage, score_rollbacks
    # llm (--llm): the findings in the user message of the `reflector` (fixed prompt, session reflect-<slug>-<n>),
    #   which rewrites runs/lessons.md; rec["llm"] = {ok, lessons_updated, request_id}
def reflect_all(settings) -> (summary, markdown)   # per game numbers + weaknesses across games, from the records
forge levels <slug> [--zones a-b] [--stages-per-zone N] [--total-zones N]  # obby stages as data (level_designer)
```

### Orchestrator (forge/orchestrator.py, forge/broker.py, forge/gaps.py)
```
round r:  gaps job (gap_finder, lease llm) -> gaps/<n>.json
          top --per-round gaps with rank >= --min-rank (max 2 tries per gap id) -> build jobs, priority = rank:
             fix + path -> forge correct <slug> <path> <request> --no-studio   leases llm, game, lock:<file>
                                       (fixes to different files run in parallel, up to $FORGE_GAME_SLOTS=4)
             feature | visual -> forge feature <slug> <brief> -n 1 --polish 1     leases studio, sync, llm, game:all
                                 (--no-studio: -n 0 --no-studio)
             fix without path -> forge feature <slug> "Fix this bug: ..." -n 0 --no-studio  leases llm, game:all
          verify (after: all builds; luau-compile, in-process)
          playtest (deps: verify)      forge run <slug> -n 1      leases llm, game:all (headless; studio + sync
                                       only with --studio always: job_needs drops them for HEADLESS_KINDS)
          checks_offline (after: playtest; in-process): plan_checks if none, then checks.triage (headless);
                                       all pass -> results saved (source "headless") and the Studio job is done
          checks (deps: checks_offline) forge checks --run --headless-first  leases studio, sync, llm
          fix_cycle (after: checks)    forge fix --cycles 1       leases llm, game:all (HeadlessStudio testers;
                                       studio + sync only with --studio always)
          score(): forge done parts + latest critic (+ fun); stop when ready and critic >= 8
stop: target met | no gap above the bar | --rounds done | budget (--max-calls: calls.jsonl lines under runs/<slug>/
      since start; --minutes) -> queued jobs cancelled, running ones SIGTERM
```
- Leases (Broker, state in $FORGE_BROKER_DIR=/tmp/forge-broker/leases.json, flock): pools `llm` (llm-1..
  $FORGE_LLM_SLOTS, default 6: forge processes doing LLM work; each runs FORGE_JOBS concurrent calls,
  llm.jobs_from_env), `game` ($FORGE_GAME_SLOTS shared slots per runs/<slug>), `sync` (ports 34901-34908,
  passed as FORGE_SYNC_PORT), `studio` (--studio places; granting one also takes a machine-wide slot in
  /tmp/forge-studio-slots like scripts/studio-slot.sh; the job gets FORGE_STUDIO=<studio id>). A need is
  "<pool>" (one slot), "<pool>:all" (every slot: exclusive) or "lock:<name>" (a mutex made on demand).
  A job gets all its leases or none and waits in the queue meanwhile; try_acquire sets `last_blocked`, and
  claim() never gives a lower-priority job a pool a higher-priority ready job is waiting for (no starvation).
  Leases whose pid died or whose heartbeat is older than 180 s are reclaimed. The Studio window is opened
  (place built from runs/<slug>/game) when a Studio lease is first used and closed, freeing the slot, when no
  queued/running job needs Studio.
- Queue (runs/<slug>/orchestrator/queue.json): job {id, kind, title, priority, deps (must be done), after
  (must be final), args, needs, gap, round, status queued|running|done|failed|skipped|cancelled, worker,
  pid, attempts, max_attempts (2), leases, heartbeat, result, error}. recover(): running jobs whose pid died
  or that stopped heartbeating go back to queued (or failed after max_attempts); run() calls it first, so
  restarting `forge orchestrate` resumes. finish(..., also_done={id: result}) settles a queued follow-up in the
  same locked step; update_args(id, **args).
- Each subprocess job is also an MCP-style job (runs/jobs/orch-<job>-<attempt>.{json,log}, `__exit <code>`).
- Files: orchestrator/{status.json (state, budget, queue, jobs, rounds, before/after), timings.json
  (forge.timings.Timeline: stages "resume" + one per round, one call per job run with role lanes), rounds.json,
  gaps/<n>.json,
  corrections.jsonl, rejected.json, calls.jsonl, traces/}; runs/orchestrate-<slug>.log. dashboard.team_view
  merges orchestrator/timings.json; game_view exposes status.json as game["orchestrator"]; ledger counts
  corrections.jsonl as gap_finder corrections.
```python
# gaps.py
def collect_evidence(settings, slug, goal="") -> {slug, spec, genre, scan, done, evidence: Evidence}
    # evidence refs: critic:<n>[#i], test:<run>[#bugN|/step-NN], check:<id>, cycle:<n>[#aI], feature:<i>,
    # report:<i>, calls:<role>, done:<part>, code:<path>, genre:<checklist id>|genre:grey_scan
def parse_gaps(obj, refs, *, rejected_titles=None, files=None) -> {summary, score, gaps}
    # gap {id (slug of title), title, area, kind broken|missing|polish, impact 1-10, confidence 0-1,
    #      rank = impact*confidence*(1 if any real evidence else 0.5), evidence, unverified, why, job}
def find_gaps(settings, slug, *, llm, goal="", session_id=None, done_jobs=None, correction=None,
              previous=None, round=None) -> rec   # saved as orchestrator/gaps/<n>.json
def correct_gaps(settings, slug, note, *, llm, goal="", reject=None, session_id=None) -> rec
    # same gap_finder task; user msg += previous list + "## Correction from the developer"; rejected ids
    # -> rejected.json (never proposed again); corrections.jsonl {ts, note, rejected, request_id, before, after}
```
MCP (forge server): `orchestrate(slug, goal, max_calls, minutes, rounds, workers, per_round, studio,
use_studio)` (job), `gaps(slug, find, correct, reject, goal)` (job when find/correct, else the latest list),
`orchestrator(slug)` (queue view). Claude Code skill: `.claude/skills/forge-orchestrate/SKILL.md`.

### Autopilot (forge/autopilot.py, forge/evidence.py)
```
make     idea -> loop.new_game (director, compile-only; runs/autopilot-index.json maps idea -> slug, so a rerun
         resumes) -> GameVersions snapshot -> checks.boot_offline; a script erroring at boot -> loop.correct
round r  (every phase writes autopilot/rounds/<r>/<phase>.json atomically; a rerun skips written phases)
observe  current measurement (first round: measure "baseline" and commit it) -> EvidenceStore:
         evidence.history (iterations + fix cycles) + kept autopilot measurements + this one, tests/swarm since
         its t0 (until a rolled-back measurement), checks, calls.jsonl health, ForgeBridge events of our place,
         critic/fun, declared counters (ForgeTelemetry.count("x") + spec first_60s) -> prefilter() candidates
detect   anomaly_detector (detector_message: goal, spec, pre-filter, evidence, outcomes of earlier findings,
         rejected ids, previous list, correction) -> parse_anomalies (unknown refs dropped, rank halved);
         failure -> from_prefilter(). gap_finder with the autopilot evidence inserted first and, when gap jobs
         were rolled back, that outcome as its correction -> orchestrator/gaps/<n>.json
decide   candidates(anomalies, gaps): merged when titles are similar (Jaccard >= .5) or the fix file matches;
         score = impact x confidence x (0.5 without evidence) x (1.25 corroborated: stat:* evidence or both
         detectors); decide(): per_round, min_rank, max 2 tries per id, developer-rejected ids, one test per
         round, COST per kind (fix 4, feature 28, visual 22, test 0) against calls left - verify reserve
act      baseline tag (snapshot) + checks/results.json backup; builds -> Orchestrator workers on JobQueue(autopilot/)
         (fix + path -> forge correct; feature / visual(polish, asset) -> forge feature -n 1 --polish N) + a verify
         (compile) job; test decisions become the focus of the next QA run. A resumed round recovers its jobs.
verify   changed files since the baseline? -> measure "after" (studio_measure: compile, headless boot, checks,
         playtest probe + census, qa_test(focus), run_swarm, bridge, critic + fun_critique). Headless by default
         (_headless_part: headless.playtest, triage(mode="never"), qa_test / run_swarm on HeadlessStudio, no lease);
         _studio_part (lease, Run.playtest + screenshot, Studio checks, testers with the visual judge) only with
         --studio always, or for the final verify (tag "final": Autopilot.final_verify after the last round,
         --studio auto with a place -> autopilot/final.json) -> gate(before, after): rolled_back on compile errors, more boot errors, new
         runtime errors (numbers normalised), a passing check failing, a core counter dying, critic/fun -1,
         physics flags +2 -> GameVersions.restore(baseline) + checks backup restored; else kept -> snapshot +
         commit(): iteration record (report.json, critique.json, screenshot.png, state.json iteration with
         source "autopilot") + fun/latest.json, so forge done / gaps / dashboard read it
learn    per decision {round, id, source, request_id, outcome kept|rolled_back|failed|no_change|tested|skipped,
         why} -> learn.jsonl; rounds.json row (evidence counts, anomalies, gaps, decisions + reasons + outcome,
         kept/rolled back, scores before/after, what_improved, why) + journal.md
stop     forge done ready and critic, fun >= target | budget (calls under runs/<slug>/ - calls_base; minutes
         summed over sessions) | --rounds | nothing picked and nothing changed
```
Files (runs/<slug>/autopilot/): state.json, status.json (dashboard: game["autopilot"] = dashboard.autopilot_view),
rounds/<r>/{observe,detect,decide,act,verify,learn}.json + evidence.json + prefilter.json + measure-<tag>.json +
<tag>/screenshot.png, rounds.json, journal.md, learn.jsonl, corrections.jsonl (role, kind correction|outcome,
request_id: forge ledger counts them), rejected.json, queue.json, calls.jsonl; runs/autopilot-<slug>.log.
`correct(settings, slug, id, note)`: anomaly -> anomaly_detector call with the previous list + CORRECTION_MARK;
gap -> gaps.correct_gaps(reject=[gap]); the id -> rejected.json. `advise(settings, root, *, llm, name, goal,
extra_dirs, fresh=None, fresh_place=None, qa_steps, swarm_players, swarm_minutes)`: read-only over evidence/<name>*,
runs/<name>*, games/<name>/reports/*.md (not its own autopilot reports) and the source ->
runs/autopilot-advise/<name>/<stamp>/{report.md, report.json, evidence.json, calls.jsonl}.
Freshness: every item carries data.ts; evidence.GameVersions(root) (git commits touching root) + tag_versions() give
data.version / behind / stale; old items are marked "(old: game <v>, N commits ago)" in the LLM messages.
`fresh_place` (CLI `--fresh --studio P`) runs fresh_session() first in our own place: a probe on the current build
(a round started through ForgeTest when spec.playtest.start_round; observed_s recorded; compared with history only
when comparable), a focused QA on the old claims and a short swarm, with runs/advise-<name>/{spec.json, game ->
root symlink}. An old claim a fresh observation repeats is `reproduced` (live). Harness failures (evidence.TOOLING_RX:
"held, not triggered", NoPath, navmesh, "no instance at path") are kind `tooling`: kept out of the LLM evidence and
listed in the report's tester-harness fix list (harness_list). classify(candidate, st, live, weak) -> status
verified now (live or current-build evidence; x1) | static (code scan / never-moved counters only; x0.8) |
unverified (old) (x0.3) | tooling (harness list); counter regressions from a probe shorter than SHORT_PROBE_S (60 s)
are weak leads that never verify alone. MCP: `autopilot(target, advise, root, goal, max_calls, minutes, rounds,
per_round, studio, use_studio, swarm_players, qa_steps, correct_id, note, fresh)` (job).
Skill: `.claude/skills/forge-autopilot/SKILL.md`.

### checks.py + scenarios.py (executable checks and the scenario designer)
A check is `runs/<slug>/checks/<id>.luau`: header `-- check: <title>` / `-- covers: <acceptance item
or edge>`, body runs in the Server datamodel during play and returns `{ ok, detail }`, cleaning up
after itself. Results: `runs/<slug>/checks/results.json`.
```python
def plan_checks(settings, slug, *, llm, max_checks=15, session_id=None, log=print) -> list[Check]
    # scenarist (Mubit task): spec + file map + key server code (scenarios.key_code) -> checks;
    # each body must compile after checks.wrap (luau-compile; skipped if not installed), one
    # correction call for the ones that don't, the rest dropped. Saved as NN-<title-id>.luau in plan
    # order; a check whose title id already exists is never overwritten.
async def run_plan(studio, slug, *, settings, llm=None, session_id=None, log=print, only=None, prior=None)
    -> list[dict]   # only: check ids to run (the rest of a headless triage); prior: results kept in front
    # reversible checks share one playtest; each check whose covers says "irreversible" gets a
    # fresh one. Play is always stopped. A detail containing "inconclusive" is a failure. A check that cannot
    # set up its situation is rerun in a fresh playtest (run_check) and otherwise never becomes an anomaly.
    # plan_checks: compile errors and bodies without a setup assertion (lint_setup) share one correction call.
    # Failures -> ONE check_reviewer call (Mubit task): game_bug | check_bug. The user message lists,
    # per check, the line-numbered game lines (client + server) naming what it asserts; a game_bug
    # must carry "consumer": "<file>:<line>" (valid_consumer), else it counts as a check bug (premise
    # not used by the game). Check bugs are rewritten once and re-run (pass -> check_bug_fixed, saved;
    # else dropped -> checks/dropped/).
    # result: {id, title, covers, ok, detail, error?, verdict: pass|game_bug|check_bug_fixed|dropped,
    #          reason?, kind?, system?, severity?, expected?, consumer?, first_run?}
def save_suite_results(run_dir, results, source) -> Path   # a fix cycle's run_suite as results.json
def as_anomalies(results) -> list[dict]
    # game_bug failures in the auditor's shape {title, kind, severity, system, observed, expected,
    # evidence} + check (the id that reproduces it) + consumer?, for run_cycle(extra_anomalies=...)
def load_results(run_dir) -> list[dict]
forge fix <slug> [--cycles N --max-fixes M --reports --no-repro]  # real anomalies: repro check, fix, prove, until clean
```
`--no-studio`: compile-check only (no MCP), so the loop works without Studio open.
Playtest wait (loop.wait_for_game(studio, wait) -> {mode ready|fallback|fixed, secs, boot_secs?}): event-based,
`studio.wait_ready()` returns once the server booted, then the game is watched FORGE_OBSERVE_SECONDS (4 s) so
the core loop bumps its counters. An explicit FORGE_PLAY_SECONDS keeps the old fixed sleep; if wait_ready can't
tell, the rest of the wait is slept out. Games with `playtest.start_round` keep the fixed round wait.
Smoke play (`Run.smoke` -> forge/smoke.py): right after the game is ready (after the wait, or right after the round
start, where it counts toward the round wait) and before probe_report, a scripted no-LLM player plays the game for
up to FORGE_SMOKE_SECONDS (45 s; 0 = off, the test default in conftest.py), so the report's counters show the played
core loop and report["smoke"] says what was played (rec step `smoke`). The critic's user message gets a "## Smoke
play" section (roles._smoke_block; `smoke` is left out of the report JSON), the fun critic's evidence a headline.

Speed (`--jobs N`, default 8 = FORGE_JOBS; also on `feature`, `improve`, `fix`; `--no-cache` = FORGE_NO_CACHE=1):
`Run(settings, store, llm, ui, *, jobs=None, command="run")` runs every LLM call on a bounded thread pool
of `jobs` workers. `Run.build_modules(modules, *, session_id, lessons, spec, compile_check=True) ->
(built, failed)` schedules coders over the spec's `depends` DAG (a module starts once the modules it depends
on are written; a cycle falls back to designer order) and compiles each module as soon as it is written
(`fix_compile_file`, pipelined; those fixes join the next iteration's record). `compile_fix` and
`fix_issues` send every failing / criticised file to the fixer at once. The reflector runs in the
background: the next iteration's compile check, playtest and critic overlap it, and anything that reads
lessons (a fixer) waits for it (`settle_reflection`). `new_game`, `run_game` and `add_feature` take `jobs=`.
Mubit grouping is unchanged: same system prompts, session_id = slug.
`runs/<slug>/timings.json` (forge/timings.py, written live, the format `forge dashboard` reads):
`{command, started, jobs, running, total_secs, stages[{name, start, end, secs, before_secs, parallel,
start_s, end_s}], calls[{role, lane, lane_label, label, step, start, end, latency_ms, cached, ok, error,
request_id, secs}], speedups[{stage, before_secs, after_secs}], by_role, llm_busy_s, parallelism, history}`.
start/end are epoch seconds (end null while running); each role's concurrent calls get lanes coder-1,
coder-2, ...; before_secs is the stage's summed call time (its serial equivalent).
State per game in `runs/<slug>/state.json`: `{slug, idea, iterations: [{n, score, issues, errors}],
created, updated}`.

### Playtester: play.py + mcp_server.py
```python
# forge/play.py
async def playtest(settings, goal: str, steps: int = 20, studio_name: str | None = None, *,
                   llm=None, studio=None, step_seconds: float = 2.0) -> dict
    # report: {run_id, goal, goal_met, summary, bugs: [{title, evidence, severity}],
    #          steps: [{n, observation, action, result, request_id, latency_ms}], probe, request_ids}
def load_report(settings, run_id: str) -> dict
def list_reports(settings) -> list[dict]
async def correct_step(settings, run_id: str, step: int, note: str, *, llm=None) -> dict
    # {run_id, step, before, after, request_id}; a new call in the playtester's Mubit task

# mubit_tester/protocol.py  (QA protocol, docs/TESTER.md; `forge qa`; roles test_planner, step_judge, visual_judge)
async def qa_test(settings, focus: str | None = None, *, game_dir=None, slug=None, max_steps=12, player=None,
                  llm=None, studio=None, harness=None, studio_name=None, max_investigations=3,
                  key_images=4, stop=True) -> dict
    # report (kind "protocol"): {run_id, test_dir, understand, plan, steps: [{n, action, checks, verdict,
    #   investigation?, final, screenshot}], acceptance: [{n, text, status}], bugs: [{id, title, severity,
    #   category, repro, expected, actual, root_cause, screenshots, fix_target}], visual, goal_met, timings}
async def correct(settings, run_id, step: int, note: str, *, llm=None) -> dict   # 0 plan, n judge, -1 visual
def complete_json_images(llm, role, user, images, *, session_id, required, max_tokens=2048) -> (dict, LLMResult, int)

# forge/mcp_server.py  (MCPServer "forge", stdio, `forge server`; shipped as the forge plugin: forge-plugin/)
setup(mubit_api_key=None, install_luau=False, open_place=False) -> str   # guided first run
doctor() -> str
async build_game(idea, iterations=2, use_studio=True, studio=None, wait_seconds=240) -> str
    # starts job "new-..." and follows it for wait_seconds, streaming progress; summary first
iterate(slug, iterations=1, use_studio=True, studio=None) -> str        # forge run
correct(slug, path, note, use_studio=True, studio=None) -> str          # forge correct
fault_drill(slug, cycles=1, rounds=3, steps=15, only=None, studio=None) -> str   # forge improve (was improve)
tester_report(slug, text, run_ids=None, reporter=None) -> str           # forge report (job)
tester_reports(slug) -> str
async improve_game(slug, cycles=3, rounds=2, steps=15, max_fixes=3, reports=True, studio=None,
                   edit_human_files=False, start_round=False, wait_seconds=240) -> str
    # forge fix (was fix); followed like build_game, ends with the done(slug) readiness bar
done(slug) -> str                                                       # forge.done readiness
async job(job_id, wait_seconds=0, tail=25) / jobs() / cancel_job(job_id)   # runs/jobs/<id>.{json,log}
summarize_log(lines) -> {phase, ok, failed, score, fails}               # from forge's UI log lines
games() / game(slug) / read_file(slug, path) / scores(slug) / playbook(slug) / lessons() / calls(slug)
seed(slug) / promote(slug, path) / sync(slug=None, studio=None)
# The playtester tools (playtest, playtest_correct, ...) are the mubit-tester server's now.
```
stdout is the MCP wire: tool bodies run under `redirect_stdout(sys.stderr)`, so progress prints in
play.py are fine. Errors are re-raised as `ToolError(<type>: <message>)` so the client sees them.
Jobs are `forge` CLI subprocesses in their own session: they survive client timeouts, log to
`runs/jobs/<id>.log`, and end the log with `__exit <code>`.
```
forge play "<goal>" [--steps N] [--studio NAME]   # same markdown as the MCP tool
forge play-correct <run_id> <step> "<note>"
forge play-list
forge mcp                                         # the mubit-tester server
forge server                                      # the forge server (or: python -m forge.mcp_server)
```
