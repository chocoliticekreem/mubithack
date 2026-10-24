"""Shared scarce resources and the job queue for `forge orchestrate`.

Three pieces, all plain JSON files guarded by an exclusive file lock, so several orchestrators (and the
`scripts/studio-slot.sh` shell users) can share one machine without double-booking anything:

- StudioSlots: the machine-wide cap on agent Studio windows. It uses the same directory and semantics as
  scripts/studio-slot.sh (/tmp/forge-studio-slots/slotN/owner = place name, at most STUDIO_SLOTS=4), so a
  shell agent and an orchestrator never both think they own slot 2.
- Broker: leases on named pools of slots. Pools used by the orchestrator: "studio" (place names, each also
  needs a machine-wide StudioSlot), "llm" (the Mubit concurrency pool, llm-1..N), "sync" (sync ports, one
  Studio sync server per port) and "game" (one writer per game folder). A job asks for all its pools at once
  and gets every lease or none (no partial holds, so no deadlock). A lease whose holder process died, or
  whose heartbeat is older than its ttl, is reclaimed by the next acquire.
- JobQueue: runs/<slug>/orchestrator/queue.json. Jobs have a priority (higher first) and dependencies;
  a worker claims the best ready job whose leases it can get right now, so a Studio job waits for a Studio
  window while LLM-only jobs keep flowing. A claimed job whose worker died is put back (crash recovery).
"""

from __future__ import annotations

import fcntl
import json
import os
import shutil
import subprocess
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Iterator

STUDIO_SLOT_DIR = Path(os.environ.get("FORGE_STUDIO_SLOT_DIR", "/tmp/forge-studio-slots"))
BROKER_DIR = Path(os.environ.get("FORGE_BROKER_DIR", "/tmp/forge-broker"))
LEASE_TTL = 180.0          # seconds without a heartbeat before a lease is reclaimed
STUDIO_RECLAIM_AFTER = 120  # seconds, as in scripts/studio-slot.sh (find -mmin +2)

_THREAD_LOCKS: dict[str, threading.Lock] = {}
_THREAD_LOCKS_GUARD = threading.Lock()


def pid_alive(pid: int | None) -> bool:
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except (OSError, ValueError):
        return False
    return True


@contextmanager
def file_lock(path: Path) -> Iterator[None]:
    """Exclusive lock across processes (flock) and threads (a per-path threading.Lock)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with _THREAD_LOCKS_GUARD:
        tl = _THREAD_LOCKS.setdefault(str(path), threading.Lock())
    with tl:
        with open(path, "a+") as fh:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


def _read(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def _write(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    tmp.write_text(json.dumps(data, indent=1, ensure_ascii=False, default=str), encoding="utf-8")
    tmp.replace(path)


# ---------------------------------------------------------------- Studio windows (machine-wide)


def studio_window_running(name: str) -> bool:
    """True if a Studio process has place/<name>.rbxlx open (same test as scripts/studio-slot.sh)."""
    try:
        out = subprocess.run(["ps", "-axo", "args"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return True  # can't tell: never reclaim on a guess
    return any("localPlaceFile" in ln and f"place/{name}.rbxlx" in ln for ln in out.splitlines())


class StudioSlots:
    """Python twin of scripts/studio-slot.sh: at most `max_slots` agent Studio windows machine-wide."""

    def __init__(self, root: Path | None = None, max_slots: int | None = None,
                 running: Callable[[str], bool] = studio_window_running, clock: Callable[[], float] = time.time):
        self.root = Path(root or STUDIO_SLOT_DIR)
        self.max = int(max_slots or os.environ.get("STUDIO_SLOTS") or 4)
        self.running = running
        self.clock = clock

    def _slots(self) -> list[Path]:
        return sorted(p for p in self.root.glob("slot*") if p.is_dir())

    def owners(self) -> dict[str, str]:
        out = {}
        for s in self._slots():
            try:
                out[s.name] = (s / "owner").read_text().strip()
            except OSError:
                out[s.name] = ""
        return out

    def held_by(self, name: str) -> str | None:
        return next((slot for slot, owner in self.owners().items() if owner == name), None)

    def reclaim(self) -> list[str]:
        """Free slots whose window is gone and that are older than 2 minutes (as the shell script)."""
        freed = []
        for s in self._slots():
            try:
                owner = (s / "owner").read_text().strip()
                age = self.clock() - s.stat().st_mtime
            except OSError:
                continue
            if owner and age > STUDIO_RECLAIM_AFTER and not self.running(owner):
                shutil.rmtree(s, ignore_errors=True)
                freed.append(s.name)
        return freed

    def try_acquire(self, name: str) -> str | None:
        """Take a slot for place `name` without waiting. Returns the slot name, or None if all are busy."""
        self.root.mkdir(parents=True, exist_ok=True)
        held = self.held_by(name)
        if held:
            return held
        self.reclaim()
        for i in range(1, self.max + 1):
            slot = self.root / f"slot{i}"
            try:
                slot.mkdir()
            except FileExistsError:
                continue
            (slot / "owner").write_text(name + "\n")
            return slot.name
        return None

    def release(self, name: str) -> bool:
        freed = False
        for s in self._slots():
            try:
                if (s / "owner").read_text().strip() == name:
                    shutil.rmtree(s, ignore_errors=True)
                    freed = True
            except OSError:
                continue
        return freed


# ---------------------------------------------------------------- leases


class Broker:
    """All-or-nothing leases on named pools. State: <dir>/leases.json, lock: <dir>/leases.lock."""

    def __init__(self, root: Path | None = None, pools: dict[str, list[str]] | None = None, *,
                 ttl: float = LEASE_TTL, alive: Callable[[int | None], bool] = pid_alive,
                 clock: Callable[[], float] = time.time, studio_slots: StudioSlots | None = None):
        self.root = Path(root or BROKER_DIR)
        self.pools = {k: list(v) for k, v in (pools or {}).items()}
        self.ttl = ttl
        self.alive = alive
        self.clock = clock
        self.studio_slots = studio_slots
        self.last_blocked: str | None = None
        self.path = self.root / "leases.json"
        self.lock = self.root / "leases.lock"

    def _load(self) -> list[dict]:
        return list((_read(self.path, {}) or {}).get("leases") or [])

    def _save(self, leases: list[dict]) -> None:
        _write(self.path, {"leases": leases})

    def _stale(self, lease: dict, now: float) -> bool:
        if not self.alive(lease.get("pid")):
            return True
        return now - float(lease.get("heartbeat") or 0) > float(lease.get("ttl") or self.ttl)

    def _reclaim(self, leases: list[dict], now: float) -> tuple[list[dict], list[dict]]:
        keep, gone = [], []
        for ls in leases:
            (gone if self._stale(ls, now) else keep).append(ls)
        return keep, gone

    def reclaim(self) -> list[dict]:
        with file_lock(self.lock):
            keep, gone = self._reclaim(self._load(), self.clock())
            if gone:
                self._save(keep)
            return gone

    @staticmethod
    def pool_of(need: str) -> str:
        """'game:all' -> 'game'; 'lock:<name>' -> 'lock:<name>'; 'llm' -> 'llm'."""
        return need[:-4] if need.endswith(":all") else need

    def try_acquire(self, needs: list[str], holder: str, *, pid: int | None = None,
                    ttl: float | None = None) -> list[dict] | None:
        """Lease what `needs` asks for, all of it or nothing:
        - "<pool>": one free slot of that pool (unknown pools never grant);
        - "<pool>:all": every slot of the pool (an exclusive hold, e.g. a whole-game writer);
        - "lock:<name>": a mutex made on demand (e.g. one writer per file).
        On None, `self.last_blocked` names the pool that was busy (claim uses it to avoid starvation)."""
        pid = pid or os.getpid()
        self.last_blocked = None
        with file_lock(self.lock):
            now = self.clock()
            leases, gone = self._reclaim(self._load(), now)
            taken = {(ls["pool"], ls["slot"]) for ls in leases}
            got: list[dict] = []
            studio_taken: list[str] = []

            def lease(pool: str, slot: str) -> dict:
                return {"id": uuid.uuid4().hex[:10], "pool": pool, "slot": slot, "holder": holder,
                        "pid": pid, "acquired": now, "heartbeat": now, "ttl": ttl or self.ttl}

            for need in dict.fromkeys(needs):  # unique, in order
                pool = self.pool_of(need)
                if need.startswith("lock:"):
                    slots = [] if (pool, "held") in taken else ["held"]
                elif need.endswith(":all"):
                    every = self.pools.get(pool) or []
                    slots = every if every and not any((pool, s) in taken for s in every) else []
                else:
                    slots = []
                    for cand in self.pools.get(pool) or []:
                        if (pool, cand) in taken:
                            continue
                        if pool == "studio" and self.studio_slots is not None:
                            already = self.studio_slots.held_by(cand)
                            if not already and not self.studio_slots.try_acquire(cand):
                                continue
                            if not already:
                                studio_taken.append(cand)
                        slots = [cand]
                        break
                if not slots:
                    for cand in studio_taken:  # don't keep a window slot for a job that can't start
                        self.studio_slots.release(cand)  # type: ignore[union-attr]
                    if gone:
                        self._save(leases)
                    self.last_blocked = pool
                    return None
                for s in slots:
                    got.append(lease(pool, s))
                    taken.add((pool, s))
            self._save(leases + got)
            return got

    def renew(self, holder: str) -> int:
        with file_lock(self.lock):
            leases = self._load()
            n = 0
            for ls in leases:
                if ls.get("holder") == holder:
                    ls["heartbeat"] = self.clock()
                    n += 1
            if n:
                self._save(leases)
            return n

    def release(self, holder: str) -> list[dict]:
        """Drop every lease `holder` has. The machine-wide Studio slot is kept (the window stays open
        for the next Studio job); close it with StudioSlots.release / scripts/studio-slot.sh release."""
        with file_lock(self.lock):
            leases = self._load()
            mine = [ls for ls in leases if ls.get("holder") == holder]
            if mine:
                self._save([ls for ls in leases if ls.get("holder") != holder])
            return mine

    def held(self, pool: str | None = None) -> list[dict]:
        with file_lock(self.lock):
            leases, _ = self._reclaim(self._load(), self.clock())
        return [ls for ls in leases if pool is None or ls["pool"] == pool]

    def status(self) -> dict:
        held = self.held()
        return {pool: {"slots": slots, "busy": {ls["slot"]: ls["holder"] for ls in held if ls["pool"] == pool}}
                for pool, slots in self.pools.items()}


# ---------------------------------------------------------------- job queue

JOB_STATES = ("queued", "running", "done", "failed", "skipped", "cancelled")
FINAL = ("done", "failed", "skipped", "cancelled")


class JobQueue:
    """Persistent priority queue with dependencies. State: <dir>/queue.json, lock: <dir>/queue.lock."""

    def __init__(self, root: Path, *, clock: Callable[[], float] = time.time,
                 alive: Callable[[int | None], bool] = pid_alive, stale_after: float = LEASE_TTL):
        self.root = Path(root)
        self.path = self.root / "queue.json"
        self.lock = self.root / "queue.lock"
        self.clock = clock
        self.alive = alive
        self.stale_after = stale_after

    def _load(self) -> list[dict]:
        return list((_read(self.path, {}) or {}).get("jobs") or [])

    def _save(self, jobs: list[dict]) -> None:
        _write(self.path, {"jobs": jobs, "updated": self.clock()})

    def jobs(self) -> list[dict]:
        with file_lock(self.lock):
            return self._load()

    def get(self, job_id: str) -> dict | None:
        return next((j for j in self.jobs() if j["id"] == job_id), None)

    def add(self, kind: str, title: str, *, priority: float = 5, deps: list[str] | None = None,
            args: dict | None = None, needs: list[str] | None = None, gap: str | None = None,
            round: int | None = None, max_attempts: int = 2, after: list[str] | None = None) -> dict:
        """deps must finish *successfully* first (else this job is skipped); `after` jobs only need to
        have finished, in any state (e.g. compile-check after all builds, whether or not each succeeded)."""
        with file_lock(self.lock):
            jobs = self._load()
            job = {"id": f"{kind}-{len(jobs) + 1:03d}-{uuid.uuid4().hex[:4]}", "kind": kind, "title": title,
                   "priority": float(priority), "deps": list(deps or []), "after": list(after or []), "args": dict(args or {}),
                   "needs": list(needs or []), "gap": gap, "round": round, "status": "queued",
                   "attempts": 0, "max_attempts": max_attempts, "created": self.clock(), "seq": len(jobs),
                   "worker": None, "pid": None, "leases": [], "started": None, "ended": None,
                   "heartbeat": None, "result": None, "error": None}
            jobs.append(job)
            self._save(jobs)
            return job

    @staticmethod
    def _dep_state(job: dict, by_id: dict[str, dict]) -> str:
        """'ready' | 'wait' | 'broken' (a dependency failed, was skipped, cancelled or doesn't exist)."""
        for d in job.get("deps") or []:
            dep = by_id.get(d)
            if dep is None or dep["status"] in ("failed", "skipped", "cancelled"):
                return "broken"
            if dep["status"] != "done":
                return "wait"
        for d in job.get("after") or []:
            dep = by_id.get(d)
            if dep is not None and dep["status"] not in FINAL:
                return "wait"
        return "ready"

    def _settle(self, jobs: list[dict]) -> bool:
        """Skip queued jobs whose dependencies broke (repeat: skips cascade). Returns True if any changed."""
        changed, again = False, True
        while again:
            again = False
            by_id = {j["id"]: j for j in jobs}
            for j in jobs:
                if j["status"] == "queued" and self._dep_state(j, by_id) == "broken":
                    j.update(status="skipped", ended=self.clock(), error="a dependency did not finish")
                    changed = again = True
        return changed

    @staticmethod
    def _order(j: dict) -> tuple:
        return (-float(j.get("priority") or 0), j.get("seq", 0))

    def ready(self) -> list[dict]:
        with file_lock(self.lock):
            jobs = self._load()
            if self._settle(jobs):
                self._save(jobs)
        by_id = {j["id"]: j for j in jobs}
        return sorted((j for j in jobs if j["status"] == "queued" and self._dep_state(j, by_id) == "ready"),
                      key=self._order)

    def claim(self, worker: str, broker: Broker | None = None, *, pid: int | None = None,
              accept: Callable[[dict], bool] | None = None) -> tuple[dict, list[dict]] | None:
        """Atomically take the best ready job whose leases are free right now (all of them, or skip it)."""
        pid = pid or os.getpid()
        with file_lock(self.lock):
            jobs = self._load()
            self._settle(jobs)
            by_id = {j["id"]: j for j in jobs}
            reserved: set[str] = set()  # pools a higher-priority ready job is waiting for
            for j in sorted(jobs, key=self._order):
                if j["status"] != "queued" or self._dep_state(j, by_id) != "ready":
                    continue
                if accept is not None and not accept(j):
                    continue
                leases: list[dict] = []
                if j.get("needs") and broker is not None:
                    pools = {Broker.pool_of(n) for n in j["needs"]}
                    if pools & reserved:
                        continue  # no starvation: lower priority never takes what a waiting job needs
                    got = broker.try_acquire(j["needs"], holder=j["id"], pid=pid)
                    if got is None:
                        if broker.last_blocked and not broker.last_blocked.startswith("lock:"):
                            reserved.add(broker.last_blocked)
                        continue
                    leases = got
                now = self.clock()
                j.update(status="running", worker=worker, pid=pid, started=now, heartbeat=now,
                         attempts=int(j.get("attempts") or 0) + 1, error=None,
                         leases=[{"pool": ls["pool"], "slot": ls["slot"]} for ls in leases])
                self._save(jobs)
                return dict(j), leases
            self._save(jobs)
            return None

    def update_args(self, job_id: str, **args) -> None:
        with file_lock(self.lock):
            jobs = self._load()
            for j in jobs:
                if j["id"] == job_id:
                    j["args"] = {**(j.get("args") or {}), **args}
            self._save(jobs)

    def heartbeat(self, job_id: str, **fields) -> None:
        with file_lock(self.lock):
            jobs = self._load()
            for j in jobs:
                if j["id"] == job_id:
                    j["heartbeat"] = self.clock()
                    j.update(fields)
            self._save(jobs)

    def finish(self, job_id: str, ok: bool, result: Any = None, error: str | None = None,
               broker: Broker | None = None, also_done: dict[str, Any] | None = None) -> dict | None:
        """Mark a running job done/failed. `also_done` {job id: result} marks queued jobs done in the
        same atomic step (a job that made a follow-up unnecessary, e.g. every check passed headless)."""
        with file_lock(self.lock):
            jobs = self._load()
            out = None
            for j in jobs:
                if j["id"] == job_id and j["status"] == "running":
                    j.update(status="done" if ok else "failed", ended=self.clock(), result=result,
                             error=None if ok else (error or "failed"))
                    out = dict(j)
                elif ok and j["id"] in (also_done or {}) and j["status"] == "queued":
                    j.update(status="done", ended=self.clock(), result=(also_done or {})[j["id"]],
                             attempts=0)
            self._settle(jobs)
            self._save(jobs)
        if broker is not None:
            broker.release(job_id)
        return out

    def retry_or_fail(self, job_id: str, error: str, broker: Broker | None = None) -> dict | None:
        """A job that failed for a transient reason goes back in the queue until max_attempts."""
        with file_lock(self.lock):
            jobs = self._load()
            out = None
            for j in jobs:
                if j["id"] == job_id and j["status"] == "running":
                    if int(j.get("attempts") or 0) < int(j.get("max_attempts") or 1):
                        j.update(status="queued", worker=None, pid=None, leases=[], error=error)
                    else:
                        j.update(status="failed", ended=self.clock(), error=error)
                    out = dict(j)
            self._settle(jobs)
            self._save(jobs)
        if broker is not None:
            broker.release(job_id)
        return out

    def recover(self, broker: Broker | None = None) -> list[dict]:
        """Running jobs whose worker process died, or that stopped heartbeating, go back to the queue
        (or fail after max_attempts). Their leases are released. Returns the recovered jobs."""
        now = self.clock()
        with file_lock(self.lock):
            jobs = self._load()
            lost = []
            for j in jobs:
                if j["status"] != "running":
                    continue
                stale = now - float(j.get("heartbeat") or j.get("started") or 0) > self.stale_after
                if not self.alive(j.get("pid")) or stale:
                    why = "worker died" if not self.alive(j.get("pid")) else "no heartbeat"
                    if int(j.get("attempts") or 0) < int(j.get("max_attempts") or 1):
                        j.update(status="queued", worker=None, pid=None, leases=[], error=f"recovered: {why}")
                    else:
                        j.update(status="failed", ended=now, error=f"lost: {why}")
                    lost.append(dict(j))
            if lost:
                self._settle(jobs)
                self._save(jobs)
        if broker is not None:
            for j in lost:
                broker.release(j["id"])
        return lost

    def cancel_pending(self, why: str = "cancelled") -> int:
        with file_lock(self.lock):
            jobs = self._load()
            n = 0
            for j in jobs:
                if j["status"] == "queued":
                    j.update(status="cancelled", ended=self.clock(), error=why)
                    n += 1
            self._save(jobs)
            return n

    def summary(self) -> dict:
        jobs = self.jobs()
        counts = {s: 0 for s in JOB_STATES}
        for j in jobs:
            counts[j["status"]] = counts.get(j["status"], 0) + 1
        return {"total": len(jobs), **counts}

    def idle(self) -> bool:
        """Nothing queued that could still run, and nothing running."""
        jobs = self.jobs()
        return not any(j["status"] in ("queued", "running") for j in jobs)
