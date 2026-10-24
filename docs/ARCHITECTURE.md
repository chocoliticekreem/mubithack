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
       playtest: start_stop_play → wait → ForgeProbe report + console + screenshot → stop
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
                       wrap() gives every body a `forge` table (HELPERS): waitFor(fn, t), startRound(t),
                       endRound() via ServerStorage.ForgeTest `round` ("setup: ..." error without it);
                       helpers_doc(spec) for user messages (+ round rule when spec playtest.start_round);
                       premise: consumer_hits(game_dir, body) (line-numbered game lines naming what a check
                       asserts), valid_consumer(game_dir, "<file>:<line>") -> normalised ref | None
  repro.py             reproduce(settings, slug, anomaly, investigation, *, llm, studio, session_id) ->
                       {proven, check, result, attempts}; run_suite(studio, run_dir) -> {results, anomalies};
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
  done.py              `forge done`: readiness(settings, slug) -> {ready, parts[{part, ok, detail}]}: checks all pass
                       (latest checks/results.json, dropped ignored),
                       features verified (UI needs a real press), nothing high/medium open, critic >= 8 (n/a if seeded),
                       fun critic >= 8, visuals (<= 15% default-grey parts), hud (a ScreenGui), sounds (>= 1),
                       first60 (every director beat's counter reached its min); census from the playtest, else source
  director.py          quality brain 1 (`forge direct "<idea>" [--compare]`): genre_lessons(text) (forge/lessons_library),
                       direct(llm, idea, lessons, *, session_id) -> design doc (Mubit task `director`),
                       design_from_doc(llm, idea, doc, lessons, *, session_id) -> spec (frozen designer, doc in the user
                       message, module budget 4-12 overrides the old cap of 7), plan() = both; spec["director"] = doc,
                       spec["first_60s"] = [{t, beat, counter, min}]; art pass install_kit(spec, game_dir) writes the
                       prebuilt ReplicatedStorage/GameAssets.luau (forge/kit: palette, sounds.json, play/burst/shake/
                       styleLighting/part); coder_notes(spec, lessons) puts style + juice ahead of coder/fixer lessons
  fun.py               quality brain 2 (`forge fun <slug>`): census(studio) (server + client scene census during play,
                       stored as report["census"]), static_census(files), fun_critique(llm, spec, files, report, *,
                       census, visual, session_id) -> {score = mean(fun, juice, clarity, visuals), scores, summary,
                       first_60_seconds, missing_juice, issues, census, checks} (Mubit task `fun_critic`),
                       FunStore -> runs/<slug>/fun/<n>.json + latest.json, pending_fun_anomalies() for run_cycle(fix=True)
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
                       find_gaps / correct_gaps / latest / render; genre CHECKLISTS (tycoon, generic)
  prompts/gap_finder.md  Mubit task: everything recorded about a game -> ranked gaps {title, kind, impact,
                       confidence, evidence[refs], job{kind fix|feature|visual, request, path?}}
  orchestrator.py      `forge orchestrate`: Orchestrator(settings, slug, Options, *, llm, runner, broker, queue,
                       keeper, slots).run() -> {before, after, rounds, stop_reason, budget, queue}
  faults/<slug>.json   planted faults (live ForgeTest config) the auditor is scored against
  prompts/auditor.md, prompts/verifier.md, prompts/triage.md   Mubit tasks: anomaly detection,
                       fix verification, tester-report triage (improve.file_report)
  play.py              AI playtester (observe → act → report)           [owner: play]
  mcp_server.py        stdio MCP server "forge" (`forge server`): build/iterate/correct/improve as jobs [owner: GF]
game/                  the Roblox place, file-mapped like Script Sync
  ServerScriptService/ X.server.luau → Script, X.luau → ModuleScript, dirs → Folders
  ReplicatedStorage/
  StarterPlayerScripts/ (under StarterPlayer)
  tools/sync.py        check / manifest / serve                         [owner: game]
  tools/pull.luau      run via execute_luau (Edit DM) to pull files from the local server
  ServerScriptService/ForgeProbe.server.luau  playtest error/telemetry collector (runtime contract)
runs/<game>/           per-game state, gitignored
  spec.json  state.json  calls.jsonl  iterations/<n>/{report.json,critique.json,screenshot.png}
runs/lessons.md        shared lessons, injected into every coder/fixer user message
forge/ui_kit.py        picks UI kit rules + snippets for UI work (user message only)        [owner: llm]
forge/ui_library/      the UI kit: README.md (rules + sources), index.json, *.luau snippets
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
        # parses the first JSON object in the reply; on failure sends up to 2 repair calls in the
        # same role (user msg = original user + error + previous output). Raises LLMError after.

class MubitLLM(LLM):  # __init__(settings, log_path: Path | None)
    # system prompt = (prompts/<role>.md). Appends one JSON line per call to log_path:
    # {ts, role, session_id, model, request_id, latency_ms, input_tokens, output_tokens,
    #  user_chars, reply_chars}
class FakeLLM(LLM):   # __init__(responses, default=None, log_path=None, latency=None) — pops scripted
                      # replies per role; latency (s, or {role: s}) simulates Mubit; peak_concurrency = peak concurrency
class CachedLLM(LLM): # __init__(inner, cache_dir) — runs/.cache/llm/<role>/<sha256>.json for CACHE_ROLES
                      # (designer, coder, planner, critic, reflector) and compile-error fixes only (a critic,
                      # improve or human fix always reaches Mubit); key = (role, sha256(system prompt), model,
                      # max_tokens, user msg); hit -> cached=True, no call; aborted / cut-off replies not stored
def make_llm(settings, log_path) -> LLM   # FakeLLM if FORGE_FAKE_LLM=1 (FORGE_FAKE_LATENCY) else
                                          # CachedLLM(MubitLLM) (FORGE_NO_CACHE=1: bare MubitLLM); raises if no key
def jobs_from_env() -> int                # FORGE_JOBS or DEFAULT_JOBS (8)
def stream_verdict(role, text) -> "abort" | "done" | "more"   # streaming early abort / early finish
```
LLMResult also has `cached: bool = False` and `aborted: bool = False`. MubitLLM streams (anthropic;
FORGE_STREAM=0 turns it off): a code role that writes 1500 chars of prose with no fence (or a JSON role with
no `{`) is cut short and returned with aborted=True, so the role's own repair/retry path takes over; a code
reply stops reading once its ```luau block closes. A 429 gets RATE_LIMIT_TRIES (6) attempts with
retry-after or exponential backoff with jitter, and every thread waits out the cooldown together.
Roles: `designer`, `coder`, `fixer`, `critic`, `reflector`, `player`, `judge`, ..., `scenarist`
(test plan of executable checks), `check_reviewer` (failing check: game bug or check bug).
Roles: `designer`, `coder`, `fixer`, `critic`, `reflector`, `player`, `judge`, `auditor`, `verifier`,
`triage`, `investigator`, `patcher`, `planner`, `reproducer`, `director`, `fun_critic`, `gap_finder`
(ranked gaps, forge/gaps.py).

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
per anomaly: investigator (as before, its conclusion is a hint)
             -> reproducer writes a check -> luau-compile -> run in the live playtest
                ok=false, no error : PROVEN if its `-- consumer:` names a real game line, saved to
                                     checks/pending/<id>.luau; no real consumer -> no_consumer
                passed / errored /
                no_consumer        : one retry, the outcome in the user message (same Mubit task); for
                                     no_consumer the outcome lists the game lines naming what it asserts
                still not failing  : unproven (improve/unproven.json), no fix attempted
             (an anomaly that names a saved check reuses it if it still fails cleanly)
             -> fixer/patcher, problem includes the failing check + its output (and: duplicate/parallel
                objects added only so the check finds them are rejected)
             -> compile -> resync -> run the repro check + every guard (checks that passed at fix start)
                repro still fails  : check_failed, retry with the output, no playtest spent
                a guard fails      : check_regression, retry with the broken checks
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
 "warnings": ["..."], "players": 1, "counters": {"coins_collected": 3}, "instances": 412}
```
Games may call `require(ReplicatedStorage.ForgeTelemetry).count(name, n)` to bump counters
(ReplicatedStorage/ForgeTelemetry.luau, server side only). Also `ServerStorage.DevHook`
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
def hot_reload_plan(entries, changed, sources, added=()) -> {"reload": [...], "restart": [(path, why)]}
```

### checks.py: headless runs (no Studio)
```python
def boot_offline(game_dir, boot=2.0, play=3.0, players=1) -> dict   # ForgeProbe-shaped report + "misses"
def run_check_offline(game_dir, check, timeout=30.0) -> dict         # run_check's shape + where="offline"
def run_checks_offline(game_dir, checks, timeout=30.0, workers=8) -> list[dict]
def triage(game_dir, checks) -> (offline_passes, checks_needing_studio)  # only passes are trusted offline
def run_specs(spec_dir) -> list[dict]                                # *.spec.luau with the luau CLI
# a check file may say `-- needs: studio` (physics, rendering, replication): never run offline
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
forge new "<idea>" [--iterations N] [--no-studio] [--jobs N] [--no-cache]   # design + build + playtest loop
forge run <slug> [--iterations N] [--no-studio] [--jobs N] [--no-cache]     # continue iterating an existing game
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
forge checks <slug> [--plan [--max N]] [--run] [--studio S]  # scenario designer; no flag: list checks
forge orchestrate <slug> --goal G [--studio P1,P2 | --no-studio] [--workers 4] [--max-calls 300] [--minutes 120]
                  [--rounds 3] [--per-round 4] [--min-rank 2] [--no-checks] [--no-fix-cycle]   # team lead loop
forge gaps <slug> [--find] [--goal G] [--correct NOTE [--reject ID ...]] [--json]  # ranked gap list
forge queue <slug>                                   # orchestrator jobs, leases, budget
```

### Orchestrator (forge/orchestrator.py, forge/broker.py, forge/gaps.py)
```
round r:  gaps job (gap_finder, lease llm) -> gaps/<n>.json
          top --per-round gaps with rank >= --min-rank (max 2 tries per gap id) -> build jobs, priority = rank:
             fix + path -> forge correct <slug> <path> <request> --no-studio            leases llm, game
             feature | visual (| fix without path) -> forge feature <slug> <brief> -n 1 --polish 1
                                                      (--no-studio: -n 0 --no-studio)  leases studio, sync, llm, game
          verify (after: all builds; luau-compile, in-process)
          playtest (deps: verify)      forge run <slug> -n 1      leases studio, sync, llm, game
          checks (after: playtest)     forge checks --plan --run  leases studio, sync, llm
          fix_cycle (after: checks)    forge fix --cycles 1       leases studio, sync, llm, game
          score(): forge done parts + latest critic (+ fun); stop when ready and critic >= 8
stop: target met | no gap above the bar | --rounds done | budget (--max-calls: calls.jsonl lines under runs/<slug>/
      since start; --minutes) -> queued jobs cancelled, running ones SIGTERM
```
- Leases (Broker, state in $FORGE_BROKER_DIR=/tmp/forge-broker/leases.json, flock): pools `llm` (llm-1..
  $FORGE_LLM_SLOTS, default 6), `game` (one writer per runs/<slug>), `sync` (ports 34901-34908, passed as
  FORGE_SYNC_PORT), `studio` (--studio places; granting one also takes a machine-wide slot in
  /tmp/forge-studio-slots like scripts/studio-slot.sh; the job gets FORGE_STUDIO=<studio id>). A job gets all
  its leases or none and waits in the queue meanwhile. Leases whose pid died or whose heartbeat is older
  than 180 s are reclaimed. The Studio window is opened (place built from runs/<slug>/game) when a Studio
  lease is first used and closed, freeing the slot, when no queued/running job needs Studio.
- Queue (runs/<slug>/orchestrator/queue.json): job {id, kind, title, priority, deps (must be done), after
  (must be final), args, needs, gap, round, status queued|running|done|failed|skipped|cancelled, worker,
  pid, attempts, max_attempts (2), leases, heartbeat, result, error}. recover(): running jobs whose pid died
  or that stopped heartbeating go back to queued (or failed after max_attempts); run() calls it first, so
  restarting `forge orchestrate` resumes.
- Each subprocess job is also an MCP-style job (runs/jobs/orch-<job>-<attempt>.{json,log}, `__exit <code>`).
- Files: orchestrator/{status.json (state, budget, queue, jobs, rounds, before/after), timings.json
  (dashboard lanes: one per worker; calls: one per job run; stages: one per round), rounds.json, gaps/<n>.json,
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
async def run_plan(studio, slug, *, settings, llm=None, session_id=None, log=print) -> list[dict]
    # reversible checks share one playtest; each check whose covers says "irreversible" gets a
    # fresh one. Play is always stopped. A detail containing "inconclusive" is a failure.
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
