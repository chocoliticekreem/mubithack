"""`forge server`: the `forge` stdio MCP server. Make a Roblox game with Forge from any MCP client.

Build:   doctor, new_game, iterate, correct, improve (each long one starts a background job)
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

import json
import os
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
    "Mubit so corrections become model updates. Start with doctor. new_game(idea) designs, codes and "
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
                            env={**os.environ, **(env or {})}, start_new_session=True,
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
    out = ["| cycle | planted | detected | missed | unmatched | fixed+verified |", "|---|---|---|---|---|---|"]
    out += [f"| {r['cycle']} | {r['planted']} | {r['detected']} | {r['missed']} | {r['unmatched']} | "
            f"{r['fixed_verified']} |" for r in rows]
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


TOOL_NAMES = ("doctor", "new_game", "iterate", "correct", "improve", "job", "jobs", "cancel_job",
              "games", "game", "read_file", "scores", "playbook", "lessons", "calls",
              "seed", "promote", "sync")


def main() -> None:
    mcp.run("stdio")


if __name__ == "__main__":
    main()
