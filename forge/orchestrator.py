"""`forge orchestrate <slug> --goal "..."`: run Forge like a team lead until the game is good.

    round r:  gap finder (Mubit task gap_finder) reads every record of the game -> ranked gaps
              accepted gaps -> jobs in the queue (priority = gap rank), each a real Forge command:
                 fix with a file     -> forge correct <slug> <path> "<what is wrong>" --no-studio
                 feature / visual    -> forge feature <slug> "<brief>" -n 1 --polish 1 (Studio; else -n 0 --no-studio)
                 fix without a file  -> forge feature <slug> "Fix this bug: ..." -n 0 --no-studio
              verify  (after all builds)  : luau-compile every game file (no LLM, no Studio)
              playtest (after verify)     : forge run <slug> -n 1   (Studio: playtest, critic, fixer, screenshot)
              checks offline (after playtest): plan checks if none, run them headless (checks.triage, ~20 ms)
              checks (deps: offline)      : forge checks <slug> --run --headless-first (Studio, only if some
                                            check failed headless or needs Studio; otherwise marked done)
              fix cycle (after checks)    : forge fix <slug> --cycles 1 (Studio: AI testers, auditor, repro, verify)
              re-score: forge done + latest critic score + the next gap list
    until `forge done` is green and the critic score >= 8, or --max-calls / --minutes / --rounds run out.

Workers (threads) claim jobs from forge.broker.JobQueue and lease what they need from forge.broker.Broker:
"llm" (Mubit pool: forge processes doing LLM work; each runs FORGE_JOBS concurrent calls, forge/llm.py),
"game" (GAME_SLOTS shared slots per game folder: fixes to *different* files run in parallel, each also
holding "lock:<file>"; whole-game writers take "game:all"), "studio" (a place window, also holding a
machine-wide slot of scripts/studio-slot.sh) and "sync" (a sync port). A job whose leases are busy waits in
the queue, and lower-priority jobs never take a pool a higher-priority job is waiting for. Jobs run as
`forge` subprocesses logged like MCP jobs (runs/jobs/<id>.{json,log}), so `forge dashboard` shows each one
live; the orchestrator's own timeline is a forge.timings.Timeline (runs/<slug>/orchestrator/timings.json:
one stage per round, one call per job, lanes per role), next to status.json and rounds.json.
"""

from __future__ import annotations

import json
import os
import shlex
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from forge import gaps as gapmod
from forge.broker import Broker, JobQueue, StudioSlots, file_lock, studio_window_running
from forge.config import Settings
from forge.memory import RunStore
from forge.timings import Timeline

EXIT_MARK = "__exit "
CRITIC_BAR = 8.0
SYNC_PORTS = [str(p) for p in range(34901, 34909)]  # never the default 34873 other agents use
LLM_SLOTS = int(os.environ.get("FORGE_LLM_SLOTS") or 6)
GAME_SLOTS = int(os.environ.get("FORGE_GAME_SLOTS") or 4)  # parallel single-file fixes per game
HEARTBEAT_S = 10.0
POLL_S = 1.0

# kind -> (pools it leases, dashboard role). "game:all" = exclusive writer of the whole game folder.
KINDS: dict[str, tuple[list[str], str]] = {
    "gaps": (["llm"], "gap_finder"),
    "fix": (["llm", "game"], "fixer"),   # + lock:<file> (job_needs); without a file it is a feature
    "feature": (["studio", "sync", "llm", "game:all"], "coder"),
    "visual": (["studio", "sync", "llm", "game:all"], "coder"),
    "verify": ([], "verifier"),
    "playtest": (["studio", "sync", "llm", "game:all"], "critic"),
    "checks_offline": (["llm"], "tester"),
    "checks": (["studio", "sync", "llm"], "tester"),
    "fix_cycle": (["studio", "sync", "llm", "game:all"], "auditor"),
}
STUDIO_KINDS = ("playtest", "fix_cycle", "checks")


def job_needs(kind: str, args: dict, game_dir: Path, *, use_studio: bool) -> list[str]:
    """Pools a job leases. A fix of one named file shares the game with other single-file fixes (each holds
    that file's lock); anything else that writes the game holds all of it. No Studio: no studio/sync."""
    needs = list(KINDS[kind][0])
    if kind == "fix":  # a named file: share the game, lock the file; no file: a compile-only feature build
        needs = needs + [f"lock:{game_dir}/{args['path']}"] if args.get("path") else ["llm", "game:all"]
    if not use_studio:
        needs = [n for n in needs if n not in ("studio", "sync")]
    return needs


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def count_calls(run_dir: Path) -> int:
    """Mubit calls recorded for a game: every calls.jsonl line under runs/<slug>/."""
    n = 0
    for p in run_dir.rglob("calls.jsonl"):
        try:
            n += sum(1 for ln in p.read_text(encoding="utf-8", errors="replace").splitlines() if ln.strip())
        except OSError:
            continue
    return n


def _read(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def score(settings: Settings, slug: str) -> dict:
    """The bar the loop stops at: forge done parts plus the latest critic (and fun) score."""
    from forge.done import readiness
    store = RunStore(settings, slug)
    state = _read(store.state_path, {}) or {}
    its = [i for i in state.get("iterations") or [] if i.get("score") is not None]
    critic = float(its[-1]["score"]) if its else None
    fun = (_read(store.dir / "fun" / "latest.json", {}) or {}).get("score")  # forge/fun.py (fun critic)
    if fun is None and its:
        crit = _read(store.dir / "iterations" / str(its[-1].get("n")) / "critique.json", {}) or {}
        fun = crit.get("fun") or (crit.get("scores") or {}).get("fun")
    try:
        r = readiness(settings, slug)
    except Exception as e:  # noqa: BLE001
        r = {"ready": False, "parts": [{"part": "done", "ok": False, "detail": str(e)}]}
    return {"critic": critic, "fun": fun, "ready": bool(r.get("ready")),
            "parts": {p["part"]: p["ok"] for p in r.get("parts") or []},
            "details": {p["part"]: p["detail"] for p in r.get("parts") or []},
            "target_met": bool(r.get("ready")) and critic is not None and critic >= CRITIC_BAR}


# ---------------------------------------------------------------- jobs -> forge commands


def job_argv(job: dict, slug: str, *, use_studio: bool) -> list[str] | None:
    """The `forge ...` arguments a job runs, or None for jobs done in-process (gaps, verify)."""
    kind, a = job["kind"], job.get("args") or {}
    if kind == "fix" and a.get("path"):
        return ["correct", slug, a["path"], a["request"], "--no-studio"]
    if kind in ("fix", "feature", "visual"):
        req = a["request"] if kind != "fix" else f"Fix this bug: {a['request']}"
        if kind == "visual":
            req = f"Visual and feel pass (art, juice, readability; no gameplay rules change): {a['request']}"
        if use_studio and kind != "fix":  # build, playtest once, then one polish cycle proves it in play
            return ["feature", slug, req, "--iterations", "1", "--polish", str(a.get("polish", 1))]
        return ["feature", slug, req, "--iterations", "0", "--no-studio"]
    if kind == "playtest":
        return ["run", slug, "--iterations", "1"] + ([] if use_studio else ["--no-studio"])
    if kind == "fix_cycle":
        return ["fix", slug, "--cycles", "1", "--rounds", "1", "--max-fixes", str(a.get("max_fixes", 3))]
    if kind == "checks":
        return ["checks", slug, "--run", "--headless-first"]
    return None


def _forge_argv(args: list[str]) -> list[str]:
    return [sys.executable, "-c", "import sys; from forge.cli import main; sys.exit(main(sys.argv[1:]))", *args]


@dataclass
class JobRun:
    ok: bool
    result: Any = None
    error: str | None = None
    retry: bool = False


Runner = Callable[[dict, dict, Callable[[], bool], Callable[[], None]], JobRun]


class CliRunner:
    """Runs a job's forge command as a subprocess, logged like an MCP job (runs/jobs/<id>.{json,log})."""

    def __init__(self, settings: Settings, slug: str, use_studio: bool):
        self.settings = settings
        self.slug = slug
        self.use_studio = use_studio

    def __call__(self, job: dict, env: dict, should_stop: Callable[[], bool], beat: Callable[[], None]) -> JobRun:
        args = job_argv(job, self.slug, use_studio=self.use_studio)
        if args is None:
            return JobRun(False, error=f"no command for kind {job['kind']}")
        jobs_dir = self.settings.runs_dir / "jobs"
        jobs_dir.mkdir(parents=True, exist_ok=True)
        jid = f"orch-{job['id']}-{int(job.get('attempts') or 1)}"
        log = jobs_dir / f"{jid}.log"
        cmd = shlex.join(_forge_argv(args))
        shell = f'{cmd} > {shlex.quote(str(log))} 2>&1; echo "{EXIT_MARK}$?" >> {shlex.quote(str(log))}'
        from forge.llm import jobs_from_env  # concurrent LLM calls inside each forge process (#120)
        proc = subprocess.Popen(["/bin/sh", "-c", shell], cwd=self.settings.repo_root,
                                env={**os.environ, "PYTHONUNBUFFERED": "1", "FORGE_JOBS": str(jobs_from_env()),
                                     **env}, start_new_session=True,
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        meta = {"id": jid, "kind": f"orchestrate:{job['kind']}", "args": args, "pid": proc.pid, "log": str(log),
                "started": time.strftime("%Y-%m-%dT%H:%M:%S"), "orchestrator_job": job["id"]}
        (jobs_dir / f"{jid}.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")
        last = 0.0
        stopped = False
        while proc.poll() is None:
            time.sleep(POLL_S)
            if time.monotonic() - last > HEARTBEAT_S:
                beat()
                last = time.monotonic()
            if should_stop() and not stopped:
                stopped = True
                try:
                    os.killpg(proc.pid, signal.SIGTERM)  # forge feature/fix restore their files on SIGTERM
                except OSError:
                    pass
                deadline = time.monotonic() + 60
                while proc.poll() is None and time.monotonic() < deadline:
                    time.sleep(POLL_S)
                if proc.poll() is None:
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except OSError:
                        pass
        lines = log.read_text(encoding="utf-8", errors="replace").splitlines() if log.exists() else []
        code = next((ln[len(EXIT_MARK):].strip() for ln in reversed(lines) if ln.startswith(EXIT_MARK)), "?")
        tail = [ln for ln in lines if not ln.startswith(EXIT_MARK)][-12:]
        res = {"exit": code, "log": str(log), "tail": tail, "command": "forge " + shlex.join(args)}
        if stopped:
            return JobRun(False, res, "stopped: budget or shutdown")
        if code == "0":
            return JobRun(True, res)
        transient = any(w in "\n".join(tail) for w in ("No Roblox Studio", "No connected Studio", "StudioError",
                                                        "overloaded", "429", "Connection", "Timeout"))
        return JobRun(False, res, f"exit {code}: {tail[-1] if tail else ''}"[:300], retry=transient)


# ---------------------------------------------------------------- Studio windows


class StudioKeeper:
    """Opens our place window when a Studio lease is granted, and closes it when no Studio work is left."""

    def __init__(self, settings: Settings, slug: str, slots: StudioSlots, log: Callable[[str], None], *,
                 opener: Callable[[str], None] | None = None, ready: Callable[[str], str | None] | None = None,
                 wait_s: float = 240.0):
        self.settings = settings
        self.slug = slug
        self.slots = slots
        self.log = log
        self.opener = opener or self._open
        self.ready = ready or self._connected
        self.wait_s = wait_s
        self.opened: set[str] = set()
        self.lock = threading.Lock()

    def place_path(self, place: str) -> Path:
        return self.settings.repo_root / "place" / f"{place}.rbxlx"

    def _open(self, place: str) -> None:
        out = self.place_path(place)
        out.parent.mkdir(parents=True, exist_ok=True)
        tool = self.settings.base_game_dir / "tools" / "make_place.py"
        subprocess.run([sys.executable, str(tool), "--root", str(RunStore(self.settings, self.slug).game_dir),
                        "--out", str(out)], check=True, capture_output=True)
        subprocess.run(["open", "-a", "/Applications/RobloxStudio.app", str(out)], check=False)

    def _connected(self, place: str) -> str | None:
        import asyncio

        from forge.studio import Studio

        async def look() -> str | None:
            async with Studio(self.settings) as st:
                for s in await st.list_studios():
                    name = str(s.get("name") or "")
                    if f"{place}.rbxlx" in name or name == place:
                        return str(s.get("id"))
            return None
        try:
            return asyncio.run(look())
        except Exception:  # noqa: BLE001
            return None

    def prepare(self, place: str) -> str | None:
        """Make sure `place` is open and connected to StudioMCP. Returns the Studio id (or None)."""
        with self.lock:
            if not studio_window_running(place):
                self.log(f"[studio] opening {place} for {self.slug}")
                self.opener(place)
                self.opened.add(place)
            deadline = time.monotonic() + self.wait_s
            while True:
                sid = self.ready(place)
                if sid or time.monotonic() > deadline:
                    if not sid:
                        self.log(f"[studio] {place} did not connect to StudioMCP in {self.wait_s:.0f}s "
                                 "(enable Assistant -> Manage MCP Servers in that window)")
                    return sid
                time.sleep(5)

    def release(self, place: str) -> None:
        with self.lock:
            self.slots.release(place)
            if place in self.opened:
                subprocess.run(["sh", str(self.settings.repo_root / "scripts" / "close-agent-studio.sh"), place],
                               check=False, capture_output=True)
                self.opened.discard(place)
                self.log(f"[studio] closed {place} (no Studio work queued)")


# ---------------------------------------------------------------- the conductor


@dataclass
class Options:
    goal: str = ""
    workers: int = 4
    studios: list[str] = field(default_factory=list)
    use_studio: bool = True
    max_calls: int | None = 300
    minutes: float | None = 120.0
    rounds: int = 3
    per_round: int = 4
    min_rank: float = 2.0
    max_tries_per_gap: int = 2
    fix_cycle: bool = True
    checks: bool = True


class Orchestrator:
    def __init__(self, settings: Settings, slug: str, opts: Options, *, llm: Any = None,
                 runner: Runner | None = None, broker: Broker | None = None, queue: JobQueue | None = None,
                 keeper: StudioKeeper | None = None, slots: StudioSlots | None = None,
                 clock: Callable[[], float] = time.time):
        self.s = settings
        self.slug = slug
        self.opts = opts
        self.store = RunStore(settings, slug)
        self.dir = self.store.dir / "orchestrator"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.clock = clock
        self.queue = queue or JobQueue(self.dir)
        self.slots = slots or StudioSlots()
        pools = {"llm": [f"llm-{i}" for i in range(1, LLM_SLOTS + 1)],
                 "game": [f"game:{self.store.dir}#{i}" for i in range(1, GAME_SLOTS + 1)],
                 "sync": SYNC_PORTS, "studio": list(opts.studios) if opts.use_studio else []}
        self.broker = broker or Broker(pools=pools, studio_slots=self.slots)
        self.runner = runner or CliRunner(settings, slug, opts.use_studio)
        self.llm = llm
        self.logf = settings.runs_dir / f"orchestrate-{slug}.log"
        self.keeper = keeper or StudioKeeper(settings, slug, self.slots, self.log)
        self.started = clock()
        self.calls0 = count_calls(self.store.dir)
        self.stop_reason: str | None = None
        self._stop = threading.Event()
        self._tlock = threading.Lock()
        # the dashboard-format timeline (forge/timings.py): one stage per round, one call per job
        self.timeline = Timeline(f"forge orchestrate {slug}", self.dir / "timings.json", jobs=opts.workers)
        self.rounds: list[dict] = _read(self.dir / "rounds.json", []) or []
        self.gap_tries: dict[str, int] = {}
        for j in self.queue.jobs():
            if j.get("gap") and j["kind"] in ("fix", "feature", "visual"):
                self.gap_tries[j["gap"]] = self.gap_tries.get(j["gap"], 0) + 1

    # -- logging and dashboard files

    def log(self, msg: str) -> None:
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        try:
            with self.logf.open("a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass

    def calls_used(self) -> int:
        return count_calls(self.store.dir) - self.calls0

    def budget(self) -> dict:
        return {"calls_used": self.calls_used(), "max_calls": self.opts.max_calls,
                "minutes_used": round((self.clock() - self.started) / 60, 1), "minutes": self.opts.minutes}

    def check_budget(self) -> str | None:
        if self.opts.max_calls is not None and self.calls_used() >= self.opts.max_calls:
            return f"call budget spent ({self.calls_used()}/{self.opts.max_calls} Mubit calls)"
        if self.opts.minutes is not None and (self.clock() - self.started) / 60 >= self.opts.minutes:
            return f"time budget spent ({self.opts.minutes:g} min)"
        return None

    def write_status(self, state: str, **extra) -> None:
        with self._tlock:
            jobs = self.queue.jobs()
            status = {"slug": self.slug, "goal": self.opts.goal, "state": state, "pid": os.getpid(),
                      "updated": now_iso(),
                      "started": datetime.fromtimestamp(self.started, timezone.utc).isoformat(timespec="seconds"),
                      "budget": self.budget(), "round": len(self.rounds) + (1 if state == "running" else 0),
                      "stop_reason": self.stop_reason, "queue": self.queue.summary(),
                      "leases": self.broker.status(),
                      "jobs": [{k: j.get(k) for k in ("id", "kind", "title", "priority", "status", "worker",
                                                       "attempts", "error", "gap", "round", "leases")}
                               for j in jobs[-40:]],
                      "rounds": self.rounds, **extra}
            tmp = self.dir / "status.json.tmp"
            tmp.write_text(json.dumps(status, indent=1, ensure_ascii=False, default=str), encoding="utf-8")
            tmp.replace(self.dir / "status.json")
        self.timeline.save()

    @staticmethod
    def role(job: dict) -> str:
        return KINDS.get(job["kind"], ([], job["kind"]))[1]

    # -- workers

    def _worker(self, name: str) -> None:
        while not self._stop.is_set():
            if self._budget_gate():
                time.sleep(POLL_S)
                continue
            got = self.queue.claim(name, self.broker)
            if not got:
                time.sleep(POLL_S)
                continue
            job, leases = got
            self._run_job(name, job, leases)

    def _run_job(self, worker: str, job: dict, leases: list[dict]) -> None:
        call = self.timeline.start_call(self.role(job), f"{job['kind']}: {job['title']}"[:140])
        shown = [f"{ls['pool']}={ls['slot']}" for ls in leases if ls["pool"] in ("studio", "sync", "llm")]
        self.log(f"[{self.role(job)}] {worker} start {job['id']} ({job['title'][:80]})"
                 + (f" leases {', '.join(shown)}" if shown else ""))
        env: dict[str, str] = {}
        for ls in leases:
            if ls["pool"] == "sync":
                env["FORGE_SYNC_PORT"] = ls["slot"]
            if ls["pool"] == "studio":
                sid = self.keeper.prepare(ls["slot"])
                env["FORGE_STUDIO"] = sid or ls["slot"]
                if not sid:
                    self._done(worker, job, JobRun(False, None, f"Studio {ls['slot']} not connected", retry=True),
                               call)
                    return

        def beat() -> None:
            self.queue.heartbeat(job["id"])
            self.broker.renew(job["id"])
            self.write_status("running")

        try:
            if job["kind"] == "gaps":
                out = self._do_gaps(job)
            elif job["kind"] == "verify":
                out = self._do_verify(job)
            elif job["kind"] == "checks_offline":
                out = self._do_checks_offline(job)
            else:
                out = self.runner(job, env, lambda: self._stop.is_set() or bool(self.stop_reason), beat)
        except Exception as e:  # noqa: BLE001
            out = JobRun(False, None, f"{type(e).__name__}: {e}"[:300])
        self._done(worker, job, out, call)

    def _done(self, worker: str, job: dict, out: JobRun, call: dict) -> None:
        also = (out.result or {}).pop("also_done", None) if isinstance(out.result, dict) else None
        if out.ok:
            self.queue.finish(job["id"], True, out.result, broker=self.broker, also_done=also)
        elif out.retry and not self.stop_reason:
            self.queue.retry_or_fail(job["id"], out.error or "failed", broker=self.broker)
        else:
            self.queue.finish(job["id"], False, out.result, out.error, broker=self.broker)
        self.timeline.end_call(call, ok=out.ok, error=out.error)
        verdict = "done" if out.ok else ("failed" if not out.retry else "retry")
        self.log(f"[{self.role(job)}] {worker} {verdict} {job['id']} in {call.get('secs') or 0:.0f}s"
                 + (f": {out.error}" if out.error else ""))
        self.write_status("running")

    # -- in-process jobs

    def _done_titles(self) -> list[str]:
        return [f"{j['kind']}: {j['title']}" for j in self.queue.jobs()
                if j["status"] == "done" and j["kind"] in ("fix", "feature", "visual")]

    def _llm(self) -> Any:
        if self.llm is None:
            from forge.llm import make_llm
            self.llm = make_llm(self.s, log_path=self.dir / "calls.jsonl")
        return self.llm

    def _do_gaps(self, job: dict) -> JobRun:
        prev = gapmod.latest(self.s, self.slug)
        rec = gapmod.find_gaps(self.s, self.slug, llm=self._llm(), goal=self.opts.goal,
                               done_jobs=self._done_titles(), previous=(prev or {}).get("gaps"),
                               round=job.get("round"))
        self.log(gapmod.render(rec, limit=8))
        return JobRun(True, {"gaps_file": rec["n"], "score": rec.get("score"), "n": len(rec["gaps"])})

    def _do_verify(self, job: dict) -> JobRun:
        from forge.loop import _load_check_fn
        errors = _load_check_fn(self.s)(self.store.game_dir)
        if errors:
            return JobRun(False, {"errors": [list(e) for e in errors[:10]]},
                          f"{len(errors)} files fail luau-compile: {errors[0][0]}")
        return JobRun(True, {"compile": "ok"})

    def _do_checks_offline(self, job: dict) -> JobRun:
        """Plan checks if there are none (scenarist), then run them headless (checks.triage, no Studio).
        If every check passes headless, the round's Studio checks job is marked done without a lease."""
        from forge import checks as chk
        if not chk.load_checks(self.store.dir):
            from forge.scenarios import plan_checks
            plan_checks(self.s, self.slug, llm=self._llm(), max_checks=int((job.get("args") or {}).get("max", 10)),
                        log=self.log)
        checks = chk.load_checks(self.store.dir)
        passed, rest = chk.triage(self.store.game_dir, checks)
        result: dict = {"checks": len(checks), "headless_passed": len(passed), "need_studio": [c.id for c in rest]}
        studio_job = (job.get("args") or {}).get("studio_job")
        if not rest and checks:
            from forge.scenarios import save_results
            save_results(self.store.dir, [{**r, "verdict": "pass", "source": "headless"} for r in passed])
            if studio_job:
                result["also_done"] = {studio_job: {"skipped": f"all {len(checks)} checks passed headless"}}
        self.log(f"[tester] checks headless: {len(passed)}/{len(checks)} pass; "
                 f"{len(rest)} need Studio" + ("" if rest else " (Studio checks job skipped)"))
        return JobRun(True, result)

    # -- planning a round

    def accept(self, gaps: list[dict]) -> list[dict]:
        picked = []
        for g in gaps:
            if g["rank"] < self.opts.min_rank or self.gap_tries.get(g["id"], 0) >= self.opts.max_tries_per_gap:
                continue
            picked.append(g)
            if len(picked) >= self.opts.per_round:
                break
        return picked

    def _needs(self, kind: str, args: dict | None = None) -> list[str]:
        return job_needs(kind, args or {}, self.store.game_dir, use_studio=self.opts.use_studio)

    def enqueue_round(self, r: int, gaps: list[dict]) -> list[dict]:
        builds = []
        for g in self.accept(gaps):
            job = g["job"]
            kind = job["kind"] if job["kind"] in ("fix", "feature", "visual") else "feature"
            args = {"request": job["request"], **({"path": job["path"]} if job.get("path") else {})}
            builds.append(self.queue.add(kind, g["title"], priority=g["rank"], args=args,
                                         needs=self._needs(kind, args), gap=g["id"], round=r))
            self.gap_tries[g["id"]] = self.gap_tries.get(g["id"], 0) + 1
        ids = [b["id"] for b in builds]
        verify = self.queue.add("verify", f"round {r}: compile every file", priority=1, needs=[], round=r, after=ids)
        play = self.queue.add("playtest", f"round {r}: playtest + critic score + screenshot", priority=1,
                              needs=self._needs("playtest"), deps=[verify["id"]], round=r)
        jobs = builds + [verify, play]
        if self.opts.use_studio and self.opts.checks:
            offline = self.queue.add("checks_offline", f"round {r}: checks headless first", priority=0.95,
                                     needs=self._needs("checks_offline"), round=r, after=[play["id"]])
            studio = self.queue.add("checks", f"round {r}: checks that need Studio", priority=0.9,
                                    needs=self._needs("checks"), round=r, deps=[offline["id"]])
            self.queue.update_args(offline["id"], studio_job=studio["id"])
            jobs += [offline, studio]
        if self.opts.use_studio and self.opts.fix_cycle:
            jobs.append(self.queue.add("fix_cycle", f"round {r}: AI testers + auditor + reproduce-first fixes",
                                       priority=0.8, needs=self._needs("fix_cycle"), round=r,
                                       after=[jobs[-1]["id"]]))
        return jobs

    # -- main loop

    def _budget_gate(self) -> bool:
        """True once the budget is spent: queued jobs are cancelled and running ones told to stop."""
        if self.stop_reason:
            return True
        reason = self.check_budget()
        if reason:
            with self._tlock:
                if not self.stop_reason:
                    self.stop_reason = reason
                    self.log(f"[orchestrator] {reason}: cancelling queued jobs, stopping running ones")
                    self.queue.cancel_pending(reason)
            return True
        return False

    def _wait(self, pred: Callable[[], bool]) -> None:
        last = 0.0
        while not pred():
            self._budget_gate()
            self.queue.recover(self.broker)
            self._studio_idle()
            if time.monotonic() - last > 5:
                self.write_status("running")
                last = time.monotonic()
            time.sleep(POLL_S)

    def _studio_idle(self) -> None:
        """Give our Studio window's machine slot back when no queued or running job needs Studio."""
        if not self.opts.use_studio:
            return
        jobs = self.queue.jobs()
        if any(j["status"] in ("queued", "running") and "studio" in (j.get("needs") or []) for j in jobs):
            return
        for place in self.opts.studios:
            if self.slots.held_by(place) and place in self.keeper.opened:
                self.keeper.release(place)

    def _job_done(self, job_id: str) -> bool:
        j = self.queue.get(job_id)
        return j is None or j["status"] in ("done", "failed", "skipped", "cancelled")

    def _round(self, r: int) -> bool:
        """One round. Returns False when the loop should stop (stop_reason says why)."""
        t0 = self.clock()
        round_started = time.time()
        gj = self.queue.add("gaps", f"round {r}: find gaps (Mubit gap_finder)", priority=100,
                            needs=self._needs("gaps"), round=r)
        self._wait(lambda: self._job_done(gj["id"]))
        gj = self.queue.get(gj["id"]) or gj
        if gj["status"] != "done":
            self.stop_reason = self.stop_reason or f"gap finder failed: {gj.get('error')}"
            return False
        rec = gapmod.latest(self.s, self.slug) or {"gaps": []}
        if not self.accept(rec["gaps"]):
            self.stop_reason = "no gaps above the bar"
            return False
        jobs = self.enqueue_round(r, rec["gaps"])
        self.log(f"[orchestrator] round {r}: {len(jobs)} jobs queued from {len(rec['gaps'])} gaps")
        self._wait(self.queue.idle)
        after = score(self.s, self.slug)
        self.rounds.append({"round": r, "gaps_file": rec.get("n"), "gap_score": rec.get("score"),
                            "gaps": [{k: g.get(k) for k in ("id", "title", "impact", "rank", "kind")}
                                     for g in rec["gaps"]],
                            "jobs": [{k: j.get(k) for k in ("id", "kind", "title", "status", "error")}
                                     for j in self.queue.jobs() if j.get("round") == r],
                            "score": after, "budget": self.budget(), "secs": round(self.clock() - t0, 1)})
        (self.dir / "rounds.json").write_text(json.dumps(self.rounds, indent=1, default=str), encoding="utf-8")
        self.log(f"[orchestrator] round {r} done: critic {after['critic']}, ready {after['ready']}, "
                 f"{self.calls_used()} calls used")
        from forge.reflect import maybe_reflect  # the whole round, its jobs' own reflections included
        maybe_reflect(self.s, self.slug, label=f"orchestrate round {r}", since=round_started, log=self.log)
        if after["target_met"]:
            self.stop_reason = "target met: forge done is green and critic >= 8"
            return False
        return True

    def run(self) -> dict:
        self.log(f"[orchestrator] {self.slug}: goal \"{self.opts.goal}\"; {self.opts.workers} workers, "
                 f"studios {self.opts.studios or 'none'}, budget {self.opts.max_calls} calls / {self.opts.minutes} min")
        lost = self.queue.recover(self.broker)
        if lost:
            self.log(f"[orchestrator] recovered {len(lost)} job(s) from a previous run: "
                     + ", ".join(j["id"] for j in lost))
        before = score(self.s, self.slug)
        self.write_status("running", before=before)
        threads = [threading.Thread(target=self._worker, args=(f"w{i + 1}",), daemon=True)
                   for i in range(max(1, self.opts.workers))]
        for t in threads:
            t.start()
        final = before
        try:
            with self.timeline.stage("resume"):  # finish whatever a previous (crashed) run left queued
                self._wait(self.queue.idle)
            start_r = len(self.rounds) + 1
            for r in range(start_r, start_r + self.opts.rounds):
                if self.stop_reason or self.check_budget():
                    self.stop_reason = self.stop_reason or self.check_budget()
                    break
                with self.timeline.stage(f"round {r}"):
                    if not self._round(r):
                        break
            else:
                self.stop_reason = self.stop_reason or f"ran {self.opts.rounds} round(s)"
        finally:
            self._stop.set()
            for t in threads:
                t.join(timeout=120)
            for place in self.opts.studios:
                if place in self.keeper.opened:
                    self.keeper.release(place)
            final = score(self.s, self.slug)
            self.write_status("finished", before=before, after=final)
            self.timeline.finish()
            self.log(f"[orchestrator] finished: {self.stop_reason}; critic {before['critic']} -> {final['critic']}, "
                     f"ready {before['ready']} -> {final['ready']}, {self.calls_used()} Mubit calls")
        return {"before": before, "after": final, "rounds": self.rounds, "stop_reason": self.stop_reason,
                "budget": self.budget(), "queue": self.queue.summary()}


def queue_view(settings: Settings, slug: str) -> str:
    d = RunStore(settings, slug).dir / "orchestrator"
    q = JobQueue(d)
    st = _read(d / "status.json", {}) or {}
    lines = [f"{slug}: {st.get('state', 'never run')}  budget {st.get('budget')}  stop: {st.get('stop_reason')}"]
    for j in q.jobs():
        lines.append(f"  {j['status']:<9} p{j['priority']:<5g} {j['id']:<22} {j['title'][:70]}"
                     + (f"  [{j['error'][:60]}]" if j.get("error") else ""))
    return "\n".join(lines)


__all__ = ["Orchestrator", "Options", "CliRunner", "StudioKeeper", "JobRun", "job_argv", "score", "count_calls",
           "queue_view", "file_lock"]
