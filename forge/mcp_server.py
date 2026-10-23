"""`forge server`: the `forge` stdio MCP server. Make a Roblox game with Forge from any MCP client.

Setup:   setup (guided first run: Mubit key, model, luau, Roblox Studio, MCP toggle)
Build:   doctor, new_game, iterate, correct, improve, fix, tester_report (long ones start a background job)
Jobs:    job, jobs, cancel_job
Read:    games, game, read_file, scores, playbook, lessons, calls
Ship:    seed, promote, sync

Long work (designing, coding, playtesting, improve cycles) takes minutes, so it runs as a `forge`
CLI subprocess with its own log under runs/jobs/. A tool returns the job id at once; `job` shows
progress. The process survives client timeouts and writes `__exit <code>` as its last log line.

Playing and inspecting the game in Studio is the `mubit-tester` server's job (docs/TESTER.md).
Every LLM call goes through Mubit (MUBIT_API_KEY in .env), one Mubit task per role.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import urllib.error
import urllib.request
import shlex
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError

from forge.config import Settings, load_settings
from forge.memory import RunStore

INSTRUCTIONS = (
    "forge builds Roblox games from an idea and improves them, with every LLM call going through "
    "Mubit so corrections become model updates. ALWAYS call setup first in a new session and walk the "
    "user through every step it marks as missing (it can save their Mubit key, install luau and open "
    "a Studio place for them); only build once it says ready. new_game(idea) designs, codes and "
    "playtests a game in the connected Roblox Studio; it returns a job id, so poll job(id) until it "
    "says finished. iterate(slug) keeps improving it, correct(slug, path, note) applies a human "
    "correction (a Mubit training example), improve(slug) runs the anomaly loop (planted faults, "
    "auditor, verifier). Read results with games, game, read_file, scores, playbook and calls. "
    "Use the mubit-tester server to play and inspect the game in Studio."
)

mcp = MCPServer("forge", instructions=INSTRUCTIONS)

CONSOLE_URL = "https://app.mubit.ai/console/"
MAX_TEXT = 20000
EXIT_MARK = "__exit "


def _settings() -> Settings:
    return load_settings()


def _clip(text: str, n: int = MAX_TEXT) -> str:
    return text if len(text) <= n else text[:n] + f"\n...[{len(text) - n} chars omitted]"


def _store(slug: str) -> RunStore:
    store = RunStore(_settings(), slug)
    if not store.exists():
        games = ", ".join(RunStore.list_games(_settings())) or "none yet"
        raise ToolError(f"no game {slug!r}. Games: {games}")
    return store


# ---------------------------------------------------------------- jobs


def _jobs_dir() -> Path:
    d = _settings().runs_dir / "jobs"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _forge_argv(args: list[str]) -> list[str]:
    return [sys.executable, "-c", "import sys; from forge.cli import main; sys.exit(main(sys.argv[1:]))",
            *args]


def start_job(kind: str, args: list[str], env: dict[str, str] | None = None,
              argv: list[str] | None = None) -> dict:
    """Run `forge <args>` (or `argv`) detached; its stdout and stderr go to runs/jobs/<id>.log."""
    job_id = f"{kind}-{time.strftime('%H%M%S')}-{uuid.uuid4().hex[:4]}"
    d = _jobs_dir()
    log = d / f"{job_id}.log"
    cmd = shlex.join(argv or _forge_argv(args))
    shell = f'{cmd} > {shlex.quote(str(log))} 2>&1; echo "{EXIT_MARK}$?" >> {shlex.quote(str(log))}'
    proc = subprocess.Popen(["/bin/sh", "-c", shell], cwd=_settings().repo_root,
                            env={**os.environ, "PYTHONUNBUFFERED": "1", **(env or {})}, start_new_session=True,
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    meta = {"id": job_id, "kind": kind, "args": args, "pid": proc.pid, "log": str(log),
            "started": time.strftime("%Y-%m-%dT%H:%M:%S")}
    (d / f"{job_id}.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")
    return meta


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def job_state(job_id: str, tail: int = 60) -> dict:
    meta_path = _jobs_dir() / f"{job_id}.json"
    if not meta_path.exists():
        raise ToolError(f"no job {job_id!r}; see jobs()")
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    log = Path(meta["log"])
    lines = log.read_text(encoding="utf-8", errors="replace").splitlines() if log.exists() else []
    code = next((ln[len(EXIT_MARK):].strip() for ln in reversed(lines) if ln.startswith(EXIT_MARK)), None)
    lines = [ln for ln in lines if not ln.startswith(EXIT_MARK)]
    if code is not None:
        status = "finished" if code == "0" else f"failed (exit {code})"
    elif meta.get("cancelled"):
        status = "cancelled"
    else:
        status = "running" if _alive(meta["pid"]) else "stopped (no exit code)"
    return {**meta, "status": status, "tail": lines[-tail:]}


def _job_reply(meta: dict, what: str) -> str:
    return (f"Started {what}: job `{meta['id']}`.\n"
            f"Poll with job(\"{meta['id']}\") every minute or so; it takes several minutes.")


# ---------------------------------------------------------------- setup (guided first run)

STARTER_MODELS = ("claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-4-5")
STUDIO_APP = Path("/Applications/RobloxStudio.app")
SETUP_PLACE = "place/Forge.rbxlx"


def check_key(base_url: str, key: str) -> tuple[bool, str]:
    """Ask Mubit to list models with this key: no task, no charge. Returns (ok, detail)."""
    req = urllib.request.Request(base_url.rstrip("/") + "/v1/models",
                                 headers={"x-api-key": key, "anthropic-version": "2023-06-01"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status == 200, f"HTTP {r.status}"
    except urllib.error.HTTPError as e:
        body = e.read()[:300].decode("utf-8", "replace")
        code = re.search(r'"code":\s*"([^"]+)"', body)
        return False, f"HTTP {e.code} {code.group(1) if code else ''}".strip()
    except OSError as e:
        return False, f"{type(e).__name__}: {e}"


def save_key(repo_root: Path, key: str) -> None:
    """Write MUBIT_API_KEY into the checkout's .env (created from .env.example if missing)."""
    env = repo_root / ".env"
    if not env.exists():
        example = repo_root / ".env.example"
        env.write_text(example.read_text(encoding="utf-8") if example.exists() else "", encoding="utf-8")
    text = env.read_text(encoding="utf-8")
    line = f"MUBIT_API_KEY={key}"
    text, n = re.subn(r"(?m)^MUBIT_API_KEY=.*$", line, text)
    env.write_text(text if n else text.rstrip("\n") + ("\n" if text.strip() else "") + line + "\n",
                   encoding="utf-8")
    os.environ["MUBIT_API_KEY"] = key


async def connected_studios(settings: Settings, tries: int = 4) -> list[dict]:
    """Studio windows with the MCP toggle on. The first call after a restart is often empty."""
    from forge.studio import Studio

    async with Studio(settings) as studio:
        for _ in range(tries):
            found = await studio.list_studios()
            if found:
                return found
            await asyncio.sleep(1.5)
    return []


def _open_place(settings: Settings) -> str:
    empty = settings.repo_root / "place" / "empty"
    empty.mkdir(parents=True, exist_ok=True)
    out = settings.repo_root / SETUP_PLACE
    subprocess.run([sys.executable, str(settings.base_game_dir / "tools" / "make_place.py"),
                    "--root", str(empty), "--out", str(out)], check=True, capture_output=True)
    subprocess.run(["open", "-a", str(STUDIO_APP), str(out)], check=False, capture_output=True)
    return str(out)


@mcp.tool()
async def setup(mubit_api_key: str | None = None, install_luau: bool = False,
                open_place: bool = False) -> str:
    """Guided first run. Checks everything Forge needs and says exactly what to do next.

    Call it with no arguments first. Then, as it asks: `mubit_api_key="mbt_..."` (checked against
    Mubit, then saved to .env), `install_luau=True` (brew install luau), `open_place=True` (builds
    an empty Forge place and opens it in Roblox Studio). Call it again until it says ready."""
    s = _settings()
    steps: list[str] = []
    todo: list[str] = []

    def ok(msg: str) -> None:
        steps.append(f"- ✓ {msg}")

    def need(msg: str, how: str) -> None:
        steps.append(f"- ✗ {msg}")
        todo.append(how)

    ok(f"Forge checkout: `{s.repo_root}` (games are saved under `runs/`)")

    if mubit_api_key:
        good, detail = check_key(s.base_url, mubit_api_key.strip())
        if not good:
            raise ToolError(f"Mubit rejected that key ({detail}). Copy it again from "
                            f"{CONSOLE_URL} → Mubit keys; it starts with mbt_.")
        save_key(s.repo_root, mubit_api_key.strip())
        s = _settings()
    if not s.mubit_api_key:
        need("Mubit API key", f"Create a key at {CONSOLE_URL} (Mubit keys), then call "
             "`setup(mubit_api_key=\"mbt_...\")`. Every Forge call goes through Mubit, so this is required.")
    else:
        good, detail = check_key(s.base_url, s.mubit_api_key)
        if good:
            ok("Mubit key works")
        else:
            need(f"Mubit key rejected ({detail})", "Paste a fresh key: `setup(mubit_api_key=\"mbt_...\")`.")

    if s.model in STARTER_MODELS:
        ok(f"model `{s.model}`")
    else:
        steps.append(f"- ! model `{s.model}`: Mubit's starter credit only serves {', '.join(STARTER_MODELS)}. "
                     "Fine if your workspace has its own provider key; otherwise set FORGE_MODEL.")

    luau = shutil.which("luau-compile")
    if not luau and install_luau:
        if shutil.which("brew"):
            subprocess.run(["brew", "install", "luau"], capture_output=True, timeout=600)
            luau = shutil.which("luau-compile") or (
                "/opt/homebrew/bin/luau-compile" if Path("/opt/homebrew/bin/luau-compile").exists() else None)
        else:
            raise ToolError("Homebrew isn't installed. Install luau from "
                            "https://github.com/luau-lang/luau/releases and put luau-compile on PATH.")
    if luau:
        ok("luau-compile (Luau syntax checks)")
    else:
        need("luau-compile", "Call `setup(install_luau=True)` (uses Homebrew).")

    if not STUDIO_APP.exists():
        need("Roblox Studio", "Install Roblox Studio from https://create.roblox.com/ and sign in, "
             "then call setup again.")
    else:
        ok("Roblox Studio installed")
        opened = _open_place(s) if open_place else None
        try:
            studios = await connected_studios(s)
        except Exception as e:  # noqa: BLE001
            studios = []
            steps.append(f"- ! could not reach StudioMCP: {type(e).__name__}: {e}")
        if studios:
            names = ", ".join(f"`{x.get('name')}` (id `{x.get('id')}`)" for x in studios)
            ok(f"Studio connected: {names}")
        else:
            how = ("In the Studio window that just opened" if opened else
                   "Open a place in Roblox Studio (or call `setup(open_place=True)` to make one), then in it")
            need("No Studio window connected to MCP",
                 f"{how}: Assistant → ⋯ → Manage MCP Servers → turn on **Enable Studio as MCP server**. "
                 "The toggle is per window. Then call setup again. (Without Studio, Forge still builds "
                 "with `use_studio=False`, compile-only.)")

    head = "## Forge setup: ready" if not todo else f"## Forge setup: {len(todo)} step(s) left"
    out = [head, "", *steps]
    if todo:
        out += ["", "### Next", *[f"{i}. {t}" for i, t in enumerate(todo, 1)]]
    else:
        out += ["", "Try: `new_game(\"co-op lava escape where you carry friends\", iterations=2)`, then "
                "`job(<id>)`. Later: `fix(slug)` to let it find and fix problems, and "
                f"`calls(slug)` to see the Mubit requests ({CONSOLE_URL})."]
    return "\n".join(out)


# ---------------------------------------------------------------- build


def _studio_env(studio: str | None) -> dict[str, str]:
    return {"FORGE_STUDIO": studio} if studio else {}


@mcp.tool()
def doctor() -> str:
    """Check the Mubit key, luau-compile, StudioMCP and which Roblox Studio windows are connected."""
    res = subprocess.run(_forge_argv(["doctor"]), cwd=_settings().repo_root, capture_output=True,
                         text=True, timeout=180)
    out = "\n".join(ln for ln in (res.stdout + res.stderr).splitlines()
                    if " WARN " not in ln and " ERROR studio_mcp" not in ln)
    return _clip(out.strip() or f"doctor exited {res.returncode}")


@mcp.tool()
def new_game(idea: str, iterations: int = 3, use_studio: bool = True, studio: str | None = None) -> str:
    """Design, code and playtest a new Roblox game from an idea (background job).

    `iterations` playtest-critique-fix rounds after the first build. `studio` picks the Studio
    window by name part or id (default: FORGE_STUDIO, else the first connected one)."""
    if not idea.strip():
        raise ToolError("idea is empty")
    args = ["new", idea, "--iterations", str(max(0, iterations))] + ([] if use_studio else ["--no-studio"])
    return _job_reply(start_job("new", args, _studio_env(studio)), "a new game")


@mcp.tool()
def iterate(slug: str, iterations: int = 1, use_studio: bool = True, studio: str | None = None) -> str:
    """Keep improving an existing game: playtest, critic, fixer, reflector (background job)."""
    _store(slug)
    args = ["run", slug, "--iterations", str(max(1, iterations))] + ([] if use_studio else ["--no-studio"])
    return _job_reply(start_job("run", args, _studio_env(studio)), f"{iterations} more iteration(s) of {slug}")


@mcp.tool()
def correct(slug: str, path: str, note: str, use_studio: bool = True, studio: str | None = None) -> str:
    """Human correction to one file: a fixer call in the same Mubit task, then resync (background job).

    `path` is relative to the game, e.g. ServerScriptService/Round.server.luau. The job log ends
    with the Mubit request id to rate Good in the console."""
    _store(slug)
    if not note.strip():
        raise ToolError("note is empty: say what is wrong and what it should do")
    args = ["correct", slug, path, note] + ([] if use_studio else ["--no-studio"])
    return _job_reply(start_job("correct", args, _studio_env(studio)), f"a correction to {slug}/{path}")


@mcp.tool()
def improve(slug: str, cycles: int = 1, rounds: int = 3, steps: int = 15, only: str | None = None,
            studio: str | None = None) -> str:
    """Self-improving loop (docs/MUBIT_LOOP.md): plant faults, playtest, auditor, fix, verifier.

    Needs a game whose services read the faulted config keys (forge/faults/<slug>.json) and the
    ForgeTest harness in Studio. `only` is a comma-separated list of fault ids."""
    args = ["improve", slug, "--cycles", str(max(1, cycles)), "--rounds", str(max(1, rounds)),
            "--steps", str(max(1, steps))]
    if only:
        args += ["--only", only]
    if studio:
        args += ["--studio", studio]
    return _job_reply(start_job("improve", args), f"{cycles} improve cycle(s) on {slug}")


@mcp.tool()
def fix(slug: str, cycles: int = 3, rounds: int = 2, steps: int = 15, max_fixes: int = 3,
        reports: bool = True, studio: str | None = None, edit_human_files: bool = False,
        start_round: bool = False) -> str:
    """The self-improving loop on the real game (background job): playtest rounds, the auditor
    finds anomalies (plus new tester reports), the fixer rewrites the file behind each one, the game
    is resynced and replayed, and the verifier keeps the fix or rolls it back. Repeats until no high
    or medium anomaly is left or `cycles` run out. Each kept fix is a saved version (see
    versions/rollback); a rejected fix is retried once with the verifier's evidence, then undone.
    Human-owned files only get a saved patch unless `edit_human_files` (the edits stay in
    runs/<slug>/game until promoted)."""
    args = ["fix", slug, "--cycles", str(max(1, cycles)), "--rounds", str(max(1, rounds)),
            "--steps", str(max(1, steps)), "--max-fixes", str(max(1, max_fixes))]
    if reports:
        args.append("--reports")
    if edit_human_files:
        args.append("--edit-human-files")
    if start_round:
        args.append("--start-round")
    if studio:
        args += ["--studio", studio]
    return _job_reply(start_job("fix", args), f"up to {cycles} fix cycle(s) on {slug}")


DASHBOARD_PORT = 8765


def _port_open(port: int) -> bool:
    import socket

    with socket.socket() as sock:
        sock.settimeout(0.5)
        return sock.connect_ex(("127.0.0.1", port)) == 0


@mcp.tool()
def dashboard(port: int = DASHBOARD_PORT) -> str:
    """Start (if needed) the live Forge dashboard and return its URL: running jobs with live logs,
    every game's iterations, versions and rollbacks, fix cycles with verifier verdicts, tester
    reports, and Mubit calls per role toward training. Give the user the link."""
    url = f"http://127.0.0.1:{port}"
    if _port_open(port):
        return f"Forge dashboard: {url}"
    meta = start_job("dashboard", ["dashboard", "--port", str(port)])
    for _ in range(20):
        if _port_open(port):
            return f"Forge dashboard: {url} (job `{meta['id']}`; it keeps running in the background)"
        time.sleep(0.25)
    raise ToolError(f"the dashboard did not start; see job({meta['id']!r})")


@mcp.tool()
def versions(slug: str) -> str:
    """Every saved version of a game: builds, iterations (with their tested code), kept fixes and
    rollbacks. Restore one with rollback."""
    from forge.versions import GameVersions

    rows = GameVersions(_store(slug).game_dir).log()
    if not rows:
        return f"No versions for {slug} yet."
    return "\n".join(["| version | date | what |", "|---|---|---|"] + [
        f"| {r['version']} | {r['date'][:19]} | {r['message'].splitlines()[0][:140]} |" for r in rows])


@mcp.tool()
def rollback(slug: str, version: str, reason: str | None = None, studio: str | None = None,
             sync_studio: bool = True) -> str:
    """Restore a saved version of a game (recorded as a new version, so it can be undone) and push
    it into Studio. Use when a change made the game worse."""
    from forge.versions import GameVersions, VersionError

    store = _store(slug)
    try:
        tag = GameVersions(store.game_dir).restore(version, reason or "by hand")
    except VersionError as e:
        raise ToolError(str(e)) from e
    out = f"Restored {version} as {tag}."
    if sync_studio:
        args = ["sync", slug, "--prune"] + (["--studio", studio] if studio else [])
        res = subprocess.run(_forge_argv(args), cwd=_settings().repo_root, capture_output=True, text=True,
                             timeout=300, env={**os.environ, **_studio_env(studio)})
        last = [ln for ln in (res.stdout + res.stderr).splitlines() if "studio_mcp" not in ln][-1:]
        out += f" Studio sync: {'ok' if res.returncode == 0 else 'failed'} {' '.join(last)[:300]}"
    return out


@mcp.tool()
def feature(slug: str, request: str, iterations: int = 1, polish: int = 2, use_studio: bool = True,
            studio: str | None = None) -> str:
    """Add a feature to an existing game (background job): the planner (Mubit) splits the request into
    new modules and small hook-in edits, the coder and patcher build them, then playtests, the critic
    and fixer iterate. Saved as a version first, so `rollback` undoes it. The job log ends with the
    feature's telemetry check."""
    _store(slug)
    if not request.strip():
        raise ToolError("the feature request is empty")
    args = (["feature", slug, request, "--iterations", str(max(0, iterations)), "--polish", str(max(0, polish))]
            + ([] if use_studio else ["--no-studio"]))
    return _job_reply(start_job("feature", args, _studio_env(studio)), f"the feature '{request[:60]}' on {slug}")


@mcp.tool()
def tester_report(slug: str, text: str, run_ids: list[str] | None = None, reporter: str | None = None) -> str:
    """A human tester's report in their own words -> triage (Mubit) -> anomalies, and an auditor
    correction for anything the auditor missed (background job).

    `run_ids` are the mubit-tester playtest runs the tester was in; without them the latest improve
    cycle's rounds are used."""
    if not text.strip():
        raise ToolError("the report is empty")
    args = ["report", slug, text] + [a for rid in (run_ids or []) for a in ("--run", rid)]
    if reporter:
        args += ["--by", reporter]
    return _job_reply(start_job("report", args), f"triage of a tester report on {slug}")


@mcp.tool()
def tester_reports(slug: str) -> str:
    """Tester reports filed for a game: triaged anomalies and what the auditor had missed."""
    from forge.improve import list_reports

    rows = list_reports(_settings(), slug)
    if not rows:
        return f"No tester reports for {slug} yet. File one with tester_report."
    out = []
    for r in rows[-20:]:
        out.append(f"### {r['ts']} {r.get('reporter') or ''}\n> {r['text'][:300]}")
        out += [f"- [{a['severity']}] **{a['title']}** ({a['system']}): {a['observed'][:200]}"
                for a in r["triage"]["anomalies"]]
        if r["auditor_missed"]:
            out.append(f"- auditor had missed: {', '.join(r['auditor_missed'])}")
    return _clip("\n".join(out))


# ---------------------------------------------------------------- jobs tools


@mcp.tool()
def job(job_id: str, tail: int = 60) -> str:
    """Status and the last `tail` log lines of a background job."""
    st = job_state(job_id, max(1, min(tail, 400)))
    head = f"## Job `{st['id']}`: {st['status']}\n`forge {shlex.join(st['args'])}`  (started {st['started']})"
    return _clip(head + "\n```\n" + "\n".join(st["tail"]) + "\n```")


@mcp.tool()
def jobs() -> str:
    """Every background job this checkout has run, newest first."""
    metas = sorted(_jobs_dir().glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not metas:
        return "No jobs yet."
    rows = ["| job | status | command |", "|---|---|---|"]
    for p in metas[:30]:
        st = job_state(p.stem, 1)
        rows.append(f"| `{st['id']}` | {st['status']} | `forge {shlex.join(st['args'])[:80]}` |")
    return "\n".join(rows)


@mcp.tool()
def cancel_job(job_id: str) -> str:
    """Stop a running job (and the processes it started)."""
    st = job_state(job_id, 1)
    if st["status"] != "running":
        return f"Job `{job_id}` is not running ({st['status']})."
    try:
        os.killpg(st["pid"], signal.SIGTERM)
    except ProcessLookupError:
        pass
    meta_path = _jobs_dir() / f"{job_id}.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    meta["cancelled"] = True
    meta_path.write_text(json.dumps(meta, indent=1), encoding="utf-8")
    return (f"Cancelled `{job_id}`. If it was mid-playtest, stop play in Studio "
            "(mubit-tester play_stop).")


# ---------------------------------------------------------------- read


@mcp.tool()
def games() -> str:
    """Every game Forge has made: iterations, last and best critic score, human corrections."""
    slugs = RunStore.list_games(_settings())
    if not slugs:
        return "No games yet. Start one with new_game(idea)."
    rows = ["| game | iterations | last | best | corrections |", "|---|---|---|---|---|"]
    for slug in slugs:
        state = RunStore(_settings(), slug).load_state()
        its = state.get("iterations", [])
        scores = [it.get("score") for it in its if it.get("score") is not None]
        last = its[-1].get("score") if its else None
        rows.append(f"| {slug} | {len(its)} | {last if last is not None else '-'} | "
                    f"{max(scores) if scores else '-'} | {len(state.get('corrections', []))} |")
    return "\n".join(rows)


@mcp.tool()
def game(slug: str) -> str:
    """One game: its spec, modules, iterations (score, issues) and corrections."""
    store = _store(slug)
    spec = store.load_spec() if store.spec_path.exists() else {}
    state = store.load_state()
    out = [f"## {spec.get('title', slug)}  (`{slug}`)", str(spec.get("pitch", "")), "",
           f"Core loop: {spec.get('core_loop', '')}", "", "### Modules"]
    out += [f"- `{m.get('path')}`: {str(m.get('purpose', ''))[:160]}" for m in spec.get("modules", [])]
    out += ["", "### Iterations"]
    out += [f"- #{it.get('n')}: score {it.get('score', '-')}, issues {len(it.get('issues') or [])}, "
            f"errors {len(it.get('errors') or [])}. {str(it.get('summary', ''))[:160]}"
            for it in state.get("iterations", [])] or ["(none yet)"]
    if state.get("corrections"):
        out += ["", "### Human corrections"]
        out += [f"- `{c.get('path')}`: {str(c.get('note', ''))[:120]} ({c.get('request_id') or '-'})"
                for c in state["corrections"]]
    files = sorted(p.relative_to(store.game_dir).as_posix() for p in store.game_dir.rglob("*.luau")) \
        if store.game_dir.exists() else []
    out += ["", f"### Files ({len(files)})"] + [f"- `{f}`" for f in files[:80]]
    return _clip("\n".join(out))


@mcp.tool()
def read_file(slug: str, path: str) -> str:
    """The source of one Luau file in a game, e.g. ServerScriptService/Round.server.luau."""
    store = _store(slug)
    clean = path.strip().replace("\\", "/").lstrip("/")
    if ".." in clean.split("/"):
        raise ToolError("path must stay inside the game")
    target = store.game_dir / clean
    if not target.is_file():
        raise ToolError(f"no file {clean!r} in {slug}; see game({slug!r}) for the list")
    return _clip(f"```luau\n{target.read_text(encoding='utf-8')}\n```")


@mcp.tool()
def scores(slug: str) -> str:
    """Improve-loop scores per cycle: faults planted, detected, missed, fixed and verified."""
    from forge.improve import ImproveStore

    rows = ImproveStore(_settings(), slug).scores()
    if not rows:
        return f"No improve cycles for {slug} yet. Run improve({slug!r})."
    out = ["| cycle | planted | detected | missed | unmatched | fixed+verified | open | code kept |",
           "|---|---|---|---|---|---|---|---|"]
    out += [f"| {r['cycle']} | {r['planted']} | {r['detected']} | {r['missed']} | {r['unmatched']} | "
            f"{r['fixed_verified']} | {r.get('open', '-')} | {r.get('code_kept', 0)}/{r.get('code_tried', 0)} |"
            for r in rows]
    return "\n".join(out)


@mcp.tool()
def playbook(slug: str) -> str:
    """What the auditor has learned for a game (fed into every later audit)."""
    from forge.improve import ImproveStore

    return ImproveStore(_settings(), slug).playbook() or "(empty: no faults missed yet)"


@mcp.tool()
def lessons() -> str:
    """Forge's cross-game build lessons (the reflector's notes, fed into every design and build)."""
    path = _settings().runs_dir / "lessons.md"
    return _clip(path.read_text(encoding="utf-8")) if path.exists() else "(no lessons yet)"


@mcp.tool()
def calls(slug: str, role: str | None = None, limit: int = 20) -> str:
    """Recent Mubit calls for a game, with request ids to find and rate in the Mubit console."""
    rows = [c for c in _store(slug).read_calls() if not role or c.get("role") == role]
    if not rows:
        return "No calls recorded."
    out = ["| role | request id | ms |", "|---|---|---|"]
    out += [f"| {c.get('role')} | `{c.get('request_id')}` | {c.get('latency_ms', '-')} |"
            for c in rows[-max(1, limit):]]
    return "\n".join(out) + f"\n\nRate them in Requests: {CONSOLE_URL}"


# ---------------------------------------------------------------- ship


@mcp.tool()
def seed(slug: str = "flame-and-blame") -> str:
    """Copy the human game (game/) into runs/<slug>/game; Forge's fixer may not edit those files."""
    from forge.seed import seed as do_seed

    try:
        store = do_seed(_settings(), slug)
    except FileNotFoundError as e:
        raise ToolError(f"no seed spec for {slug!r}: {e}") from e
    spec = store.load_spec()
    return (f"Seeded `{store.game_dir}` ({len(spec['base_files'])} protected human files). "
            f"Forge modules: {', '.join(m['path'] for m in spec.get('modules', [])) or 'none'}")


@mcp.tool()
def promote(slug: str, path: str) -> str:
    """Copy one Forge-made file from runs/<slug>/game back into game/, ready for a PR."""
    from forge.seed import promote as do_promote

    try:
        dest = do_promote(_settings(), slug, path)
    except (ValueError, FileNotFoundError) as e:
        raise ToolError(str(e)) from e
    return f"Promoted to `{dest}`. Commit it on a branch and open a PR."


@mcp.tool()
def sync(slug: str | None = None, studio: str | None = None) -> str:
    """Push a game's files into a connected Studio once (default: the human game in game/)."""
    args = ["sync"] + ([slug] if slug else []) + (["--studio", studio] if studio else [])
    res = subprocess.run(_forge_argv(args), cwd=_settings().repo_root, capture_output=True, text=True,
                         timeout=300)
    lines = [ln for ln in (res.stdout + res.stderr).splitlines() if " WARN " not in ln and "studio_mcp" not in ln]
    if res.returncode != 0:
        raise ToolError(_clip("\n".join(lines[-15:]) or f"sync exited {res.returncode}", 3000))
    return _clip("\n".join(lines[-5:]))


TOOL_NAMES = ("setup", "doctor", "new_game", "iterate", "correct", "improve", "job", "jobs", "cancel_job",
              "fix", "feature", "dashboard", "versions", "rollback", "tester_report", "tester_reports",
              "games", "game", "read_file", "scores", "playbook", "lessons", "calls",
              "seed", "promote", "sync")


def main() -> None:
    mcp.run("stdio")


if __name__ == "__main__":
    main()
