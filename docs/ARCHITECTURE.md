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
                       return {ok, detail}; load_checks/save_check/run_check/run_checks/summary
  repro.py             reproduce(settings, slug, anomaly, investigation, *, llm, studio, session_id) ->
                       {proven, check, result, attempts}; run_suite(studio, run_dir) -> {results, anomalies};
                       save_pending / promote / load_pending / find; problem_block(check, result) for the fixer
  prompts/reproducer.md  Mubit task: anomaly + investigation + code excerpts -> ONE check that fails while the
                       bug exists (```luau block, `-- check:` / `-- covers:` header)
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
  feature.py           add_feature(settings, slug, request, *, llm, iterations, use_studio, polish) -> result:
                       planner plan -> coder (new modules) -> patcher/fixer (hook edits, destructive guard) ->
                       compile -> version -> iterate -> polish_feature (round_starting AI testers, auditor vs
                       spec acceptance, run_cycle fix=True until open == 0) -> verified by planned counters
  prompts/planner.md   Mubit task: feature request -> {summary, new_modules, edits, telemetry, acceptance}
  ledger.py            `forge ledger`: ledger(settings) -> {total_calls, roles[{role, calls, corrections, verified,
                       rejected}], entries} rebuilt from runs/**/traces + improve/<n>.json + state.json corrections
  done.py              `forge done`: readiness(settings, slug) -> {ready, parts[{part, ok, detail}]}: checks all pass,
                       features verified (UI needs a real press), nothing high/medium open, critic >= 8 (n/a if seeded)
  bench.py             `forge bench`: fixed 5-idea suite (tycoon, obby, minigame, simulator, defence) built with
                       loop.new_game (+ optional improve cycles); run_bench(ids, *, iterations, studio, improve, fake,
                       lessons) -> (result, runs/bench/<stamp>.json + .md); compare(a, b) -> markdown deltas (docs/BENCH.md)
  versions.py          GameVersions(game_dir): runs/<slug>/game is a git repo, tags v1..vN;
                       snapshot(msg) -> tag, log(), restore(tag, reason) -> new tag (rollback as a commit)
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
class FakeLLM(LLM):   # __init__(responses: dict[str, list[str]]) — pops scripted replies per role
def make_llm(settings, log_path) -> LLM   # FakeLLM if FORGE_FAKE_LLM=1 else MubitLLM; raises if no key
```
Roles: `designer`, `coder`, `fixer`, `critic`, `reflector`, `player`, `judge`, ..., `scenarist`
(test plan of executable checks), `check_reviewer` (failing check: game bug or check bug).
Roles: `designer`, `coder`, `fixer`, `critic`, `reflector`, `player`, `judge`, `auditor`, `verifier`,
`triage`, `investigator`, `patcher`, `planner`, `reproducer`.

### Fix loop: reproduce, fix, prove (improve.fix_code, `forge fix`)
Default with a live Studio; `forge fix --no-repro` (run_cycle(repro=False)) is the old verifier-only loop.
```
cycle start: run_suite(checks/*.luau + checks/pending/*.luau)    # before faults are planted
             failing check -> anomaly {kind regression|proven_bug, system "checks", check: <id>, high}
per anomaly: investigator (as before, its conclusion is a hint)
             -> reproducer writes a check -> luau-compile -> run in the live playtest
                ok=false, no error : PROVEN, saved to checks/pending/<id>.luau
                passed / errored   : one retry, the outcome in the user message (same Mubit task)
                still not failing  : unproven (improve/unproven.json), no fix attempted
             (an anomaly that names a saved check reuses it if it still fails cleanly)
             -> fixer/patcher, problem includes the failing check + its output
             -> compile -> resync -> run the repro check + every guard (checks that passed at fix start)
                repro still fails  : check_failed, retry with the output, no playtest spent
                a guard fails      : check_regression, retry with the broken checks
                both hold          : one playtest round + verifier (evidence); kept unless the verifier
                                     says regression or server errors rose (hard_regressions)
             kept -> version snapshot, check moves pending/ -> checks/ (joins the suite as a guard)
             rolled back -> the check stays in pending/, next cycle starts from it
```
Cycle JSON (`improve/<n>.json`): `repro: bool`, `checks: {start, start_failing, proven, written, unproven,
kept}`; each `code_fixes[i].repro = {check, source: reproducer|saved, before, attempts, saved}` and each
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
- `manifest --root DIR` → writes `DIR/tools/manifest.json`: `[{service, dirs, name, class, path}]`.
- `serve --root DIR --port P` → HTTP file server for DIR on 127.0.0.1. As a library:
  `serve_in_thread(root, port) -> ThreadingHTTPServer`.
- `pull_luau(port: int, prune: bool = True) -> str` → Luau source for execute_luau that fetches
  the manifest and every file, creates/updates scripts, and (if prune) deletes scripts under the
  synced roots that are tagged `ForgeManaged` but no longer in the manifest. Returns a string like
  `OK n files, changed: a, b` or `ERROR ...`.
- Mapping: `X.server.luau` → Script, `X.client.luau` → LocalScript, `X.luau` → ModuleScript;
  roots ServerScriptService, ReplicatedStorage, StarterPlayerScripts (→ StarterPlayer.StarterPlayerScripts),
  also ServerStorage, StarterGui, Workspace if present.

### ForgeProbe runtime contract (game/ServerScriptService/ForgeProbe.server.luau)
During a playtest it records `ScriptContext.Error` and `LogService.MessageOut` (warnings/errors),
player joins, and any `ForgeProbe` attribute counters games set. It exposes
`ServerStorage.ForgeProbe` (BindableFunction): `Invoke("report")` returns a JSON string:
```json
{"uptime": 12.3, "errors": [{"message": "...", "trace": "...", "script": "..."}],
 "warnings": ["..."], "players": 1, "counters": {"coins_collected": 3}, "instances": 412}
```
Games may call `require(ReplicatedStorage.ForgeTelemetry).count(name, n)` to bump counters
(ReplicatedStorage/ForgeTelemetry.luau, server side only). Also `ServerStorage.DevHook`
(BindableFunction) `Invoke(moduleName, method, ...)` to reach live server modules from execute_luau.

### studio.py
```python
class Studio:  # async context manager; spawns settings.studio_mcp_path over stdio (mcp SDK)
    async def list_studios(self) -> list[dict]            # [{id, name}]
    async def select(self, name_hint: str | None = None) -> str   # picks studio_id (first if one)
    async def call(self, tool: str, **args) -> str        # raw tool call, returns text content
    async def execute_luau(self, code: str, datamodel: str = "Edit") -> str
    async def state(self) -> dict
    async def play(self) -> None                          # start_stop_play(is_start=True), waits for Server DM
    async def stop(self) -> None
    async def console(self) -> str
    async def screenshot(self, out: Path) -> Path | None  # screen_capture; saves image if returned
    async def probe_report(self) -> dict                  # execute_luau in Server DM: ForgeProbe:Invoke("report")
    async def sync(self, root: Path, port: int) -> str    # manifest + serve_in_thread + execute pull_luau
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
forge new "<idea>" [--iterations N] [--no-studio]   # design + build + playtest loop
forge run <slug> [--iterations N] [--no-studio]     # continue iterating an existing game
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
```

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
    # Failures -> ONE check_reviewer call (Mubit task): game_bug | check_bug. Check bugs are rewritten
    # once and re-run (pass -> check_bug_fixed, saved; else dropped -> checks/dropped/).
    # result: {id, title, covers, ok, detail, error?, verdict: pass|game_bug|check_bug_fixed|dropped,
    #          reason?, kind?, system?, severity?, expected?, first_run?}
def as_anomalies(results) -> list[dict]
    # game_bug failures in the auditor's shape {title, kind, severity, system, observed, expected,
    # evidence} + check (the id that reproduces it), for run_cycle(extra_anomalies=...)
def load_results(run_dir) -> list[dict]
forge fix <slug> [--cycles N --max-fixes M --reports --no-repro]  # real anomalies: repro check, fix, prove, until clean
```
`--no-studio`: compile-check only (no MCP), so the loop works without Studio open.
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
new_game(idea, iterations=3, use_studio=True, studio=None) -> str       # starts job "new-..."
iterate(slug, iterations=1, use_studio=True, studio=None) -> str        # forge run
correct(slug, path, note, use_studio=True, studio=None) -> str          # forge correct
improve(slug, cycles=1, rounds=3, steps=15, only=None, studio=None) -> str
tester_report(slug, text, run_ids=None, reporter=None) -> str           # forge report (job)
tester_reports(slug) -> str
fix(slug, cycles=3, rounds=2, steps=15, max_fixes=3, reports=True, studio=None) -> str   # forge fix (job)
job(job_id, tail=60) / jobs() / cancel_job(job_id)                      # runs/jobs/<id>.{json,log}
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
