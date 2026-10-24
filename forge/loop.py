"""The forge loop: idea -> spec -> Luau modules -> compile/fix -> playtest -> critique -> fix -> reflect.

Every LLM call goes through `forge.roles` (and so through Mubit). Calls are wrapped in a tracer so
each one prints a demo-friendly progress line with its Mubit request id and latency.
"""

from __future__ import annotations

import asyncio
import contextlib
import contextvars
import functools
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Callable

from forge import director
from forge.config import Settings, load_settings
from forge.fun import FUN_BAR
from forge.llm import _JSONMixin, jobs_from_env
from forge.patch import PATCH_ABOVE_LINES
from forge.timings import Timeline
from forge.versions import GameVersions
from forge.memory import (
    RunStore,
    now_iso,
    read_lessons,
    slugify,
    unique_slug,
    write_lessons,
)

MAX_FIX_ATTEMPTS = 3          # per file, for compile errors
TARGET_SCORE = 8              # stop iterating once the critic scores this high
MAX_FILE_CHARS = 6000         # per file in critic input (keep calls under ~8k tokens)
LUAU_SUFFIX = ".luau"
SCRIPT_ROOTS = ("ServerScriptService", "ReplicatedStorage", "StarterPlayerScripts",
                "ServerStorage", "StarterGui", "Workspace")


def play_seconds() -> float:
    try:
        return float(os.environ.get("FORGE_PLAY_SECONDS", "8"))
    except ValueError:
        return 8.0


def observe_seconds() -> float:
    """After the server booted: how long the playtest watches the game so the core loop bumps counters."""
    try:
        return max(0.0, float(os.environ.get("FORGE_OBSERVE_SECONDS", "4")))
    except ValueError:
        return 4.0


async def wait_for_game(studio: Any, wait: float) -> dict:
    """Event-based playtest wait instead of a fixed sleep: studio.wait_ready() returns once ForgeProbe exists
    and the server booted, then the game is watched for observe_seconds(). FORGE_PLAY_SECONDS set explicitly
    (or a Studio client without wait_ready) keeps the old fixed sleep; if wait_ready can't tell, the rest of
    `wait` is slept out. -> {mode: ready|fallback|fixed, secs, boot_secs?, error?}"""
    t0 = time.monotonic()
    if "FORGE_PLAY_SECONDS" in os.environ or not callable(getattr(studio, "wait_ready", None)):
        await asyncio.sleep(wait)
        return {"mode": "fixed", "secs": round(time.monotonic() - t0, 2)}
    try:
        res = await studio.wait_ready(timeout=max(wait, 10.0))
    except Exception as e:  # noqa: BLE001 - never fail a playtest over the wait
        res = {"ready": False, "error": f"{type(e).__name__}: {e}"}
    boot = round(time.monotonic() - t0, 2)
    if not (isinstance(res, dict) and res.get("ready")):
        await asyncio.sleep(max(0.0, wait - boot))
        return {"mode": "fallback", "secs": round(time.monotonic() - t0, 2),
                "error": str((res or {}).get("error") if isinstance(res, dict) else res)[:200]}
    await asyncio.sleep(observe_seconds())
    return {"mode": "ready", "secs": round(time.monotonic() - t0, 2), "boot_secs": boot}


# ================================================================ terminal output

class UI:
    def __init__(self, stream=None):
        self.stream = stream or sys.stdout
        self.color = hasattr(self.stream, "isatty") and self.stream.isatty() and not os.environ.get("NO_COLOR")

    def _c(self, code: str, text: str) -> str:
        return f"\033[{code}m{text}\033[0m" if self.color else text

    def dim(self, t: str) -> str: return self._c("2", t)
    def bold(self, t: str) -> str: return self._c("1", t)
    def green(self, t: str) -> str: return self._c("32", t)
    def red(self, t: str) -> str: return self._c("31", t)
    def yellow(self, t: str) -> str: return self._c("33", t)
    def cyan(self, t: str) -> str: return self._c("36", t)
    def magenta(self, t: str) -> str: return self._c("35", t)

    def print(self, line: str = "") -> None:
        print(line, file=self.stream, flush=True)

    def header(self, text: str) -> None:
        self.print()
        self.print(self.bold(self.cyan(f"━━ {text} ")) + self.dim("━" * max(0, 60 - len(text))))

    def line(self, tag: str, label: str, ok: bool | None = None, detail: str = "") -> None:
        mark = {True: self.green("✓"), False: self.red("✗"), None: self.dim("·")}[ok]
        tag_s = self.magenta(f"[{tag}]".ljust(11))
        self.print(f"  {tag_s} {label:<46} {mark} {detail}".rstrip())

    def call(self, role: str, label: str, ok: bool, secs: float, rid: str | None,
             n_calls: int = 1, err: str = "") -> None:
        rid_s = short_rid(rid)
        extra = f" ×{n_calls}" if n_calls > 1 else ""
        if ok:
            detail = f"{secs:4.1f}s  {self.dim(rid_s)}{self.dim(extra)}"
        else:
            detail = f"{secs:4.1f}s  {self.red(err[:80])}"
        self.line(role, label, ok, detail)


def short_rid(rid: str | None) -> str:
    if not rid:
        return "-"
    if rid.startswith("mreq_") and len(rid) > 11:
        return rid[:11] + "…"
    return rid if len(rid) <= 12 else rid[:12] + "…"


# ================================================================ LLM tracing

# Calls run concurrently, so per-call bookkeeping lives in context variables (copied into the worker
# thread), not in "whatever was appended last".
_CALL_BUCKET: contextvars.ContextVar[list | None] = contextvars.ContextVar("forge_call_bucket", default=None)
_LAST_RID: contextvars.ContextVar[str | None] = contextvars.ContextVar("forge_last_rid", default=None)
_CALLS_SINK: contextvars.ContextVar[list | None] = contextvars.ContextVar("forge_calls_sink", default=None)


class TracingLLM:
    """Wraps any LLM (MubitLLM / FakeLLM) and keeps every LLMResult so the loop can show request ids.
    Each Run.call also collects its own results (thread-safe, per call) for its timing line."""

    def __init__(self, inner: Any):
        self.inner = inner
        self.results: list[Any] = []
        self._lock = threading.Lock()

    def _record(self, res) -> None:
        with self._lock:
            self.results.append(res)
        bucket = _CALL_BUCKET.get()
        if bucket is not None:
            bucket.append(res)

    def complete(self, role, user, *args, **kwargs):
        res = self.inner.complete(role, user, *args, **kwargs)
        self._record(res)
        return res

    def complete_json(self, role, user, *args, **kwargs):
        # JSON repair calls go through self.complete too, so each one is counted (and timed)
        if isinstance(self.inner, _JSONMixin):
            return _JSONMixin.complete_json(self, role, user, *args, **kwargs)
        data, res = self.inner.complete_json(role, user, *args, **kwargs)
        self._record(res)
        return data, res

    def __getattr__(self, name):
        return getattr(self.inner, name)


# ================================================================ helpers

def _rel(path: Path | str, root: Path) -> str:
    p = Path(path)
    if p.is_absolute():
        try:
            p = p.resolve().relative_to(root.resolve())
        except ValueError:
            pass
    return p.as_posix()


def clean_rel_path(path: str) -> str | None:
    """Normalise a module path from the model; None if it's unsafe or not a Luau file."""
    p = (path or "").strip().strip("`").replace("\\", "/").lstrip("./")
    if p.startswith("game/"):
        p = p[len("game/"):]
    parts = [x for x in p.split("/") if x]
    if not parts or any(x == ".." for x in parts) or not parts[-1].endswith(LUAU_SUFFIX):
        return None
    return "/".join(parts)


def topo_order(modules: list[dict]) -> list[dict]:
    by_path = {m["path"]: m for m in modules}
    done: set[str] = set()
    order: list[dict] = []
    remaining = list(modules)
    while remaining:
        progressed = False
        for m in list(remaining):
            deps = [d for d in m.get("depends", []) if d in by_path and d != m["path"]]
            if all(d in done for d in deps):
                order.append(m)
                done.add(m["path"])
                remaining.remove(m)
                progressed = True
        if not progressed:  # cycle: keep the designer's order for the rest
            order.extend(remaining)
            break
    return order


def normalize_spec(spec: dict, slug: str) -> dict:
    spec = dict(spec)
    spec["slug"] = slug
    modules = []
    seen = set()
    for m in spec.get("modules") or []:
        if not isinstance(m, dict):
            continue
        path = clean_rel_path(str(m.get("path", "")))
        if not path or path in seen:
            continue
        seen.add(path)
        deps = [d for d in (clean_rel_path(str(x)) for x in m.get("depends") or []) if d]
        modules.append({**m, "path": path, "depends": deps})
    spec["modules"] = modules
    spec.setdefault("acceptance", [])
    return spec


def spec_summary(spec: dict) -> str:
    lines = [f"Game: {spec.get('title', spec.get('slug', ''))} - {spec.get('pitch', '')}"]
    if spec.get("core_loop"):
        lines.append(f"Core loop: {spec['core_loop']}")
    if spec.get("acceptance"):
        lines.append("Acceptance: " + "; ".join(map(str, spec["acceptance"])))
    lines.append("Modules: " + ", ".join(m["path"] for m in spec.get("modules", [])))
    return "\n".join(lines)


def _load_check_fn(settings: Settings) -> Callable[[Path], list]:
    try:
        from forge import sync as fsync  # type: ignore
        fn = getattr(fsync, "check", None)
        if callable(fn):
            return fn
    except ImportError:
        pass
    path = settings.base_game_dir / "tools" / "sync.py"
    spec = importlib.util.spec_from_file_location("forge_game_tools_sync", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load compile checker from {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.check


# The Forge runtime every generated game gets. Everything else in game/ is the human-built
# Flame and Blame tree, which only `forge seed` copies (forge/seed.py).
RUNTIME_FILES = ("ServerScriptService/ForgeProbe.server.luau", "ReplicatedStorage/ForgeTelemetry.luau",
                 # the mubit-tester harness: lets AI testers drive every player in a Studio playtest
                 "ServerScriptService/ForgeTest.server.luau", "StarterPlayerScripts/ForgeTestAgent.client.luau")
# Seconds after play starts before a spec with playtest.start_round starts its round (services boot first).
START_ROUND_DELAY = 10.0
# An iteration whose critic score is this far below the best version so far is rolled back to it.
ROLLBACK_DROP = 1.0
RUNTIME_DIRS = ("tools",)
_IGNORE = shutil.ignore_patterns("__pycache__", "*.pyc", "manifest.json", ".DS_Store")


def copy_base_game(settings: Settings, dest: Path) -> None:
    """Copy the Forge runtime (ForgeProbe, ForgeTelemetry, tools/) from game/ into a generated game."""
    base = settings.base_game_dir
    for rel in RUNTIME_FILES:
        src = base / rel
        if src.exists():
            (dest / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest / rel)
    for d in RUNTIME_DIRS:
        if (base / d).is_dir():
            shutil.copytree(base / d, dest / d, dirs_exist_ok=True, ignore=_IGNORE)
    for root in ("ServerScriptService", "ReplicatedStorage", "StarterPlayerScripts"):
        (dest / root).mkdir(parents=True, exist_ok=True)


# ================================================================ the run

class Run:
    def __init__(self, settings: Settings, store: RunStore, llm: Any = None, ui: UI | None = None, *,
                 jobs: int | None = None, command: str = "run"):
        self.settings = settings
        self.store = store
        self.ui = ui or UI()
        if llm is None:
            from forge.llm import make_llm
            store.ensure()
            llm = make_llm(settings, store.calls_log)
        self.llm = llm if isinstance(llm, TracingLLM) else TracingLLM(llm)
        self.spec: dict = {}
        self.calls: list[dict] = []          # calls of the current phase (iteration / correction)
        self._check_fn: Callable | None = None
        # LLM calls run on a bounded pool: independent modules / files go out together (--jobs N).
        self.jobs = max(1, int(jobs or jobs_from_env()))
        self._pool = ThreadPoolExecutor(max_workers=self.jobs, thread_name_prefix="forge-llm")
        self.timeline = Timeline(command, store.dir / "timings.json", self.jobs)
        self._reflecting: asyncio.Task | None = None  # the previous iteration's reflector, off the critical path
        # compile fixes made while building (pipelined); the next iteration's record takes them over
        self.build_rec: dict = {"fixes": [], "steps": []}
        self.compile_first: dict[str, str | None] = {}  # path -> first luau-compile error (None = compiled)

    def stage(self, name: str):
        """Time a stage into runs/<slug>/timings.json (written live as it starts and ends)."""
        return self.timeline.stage(name)

    def close(self) -> None:
        """Release the LLM pool's threads (long-lived processes like `forge server` run many Runs)."""
        self._pool.shutdown(wait=False)

    def save_timings(self) -> dict:
        """Final timings.json write plus a one-line summary; the run is over, so its pool is released."""
        self.close()
        rec = self.timeline.finish()
        cache = getattr(self.llm.inner, "hits", None)
        if cache is not None:
            self.ui.line("timing", f"{rec['wall_s']:.1f}s wall, LLM {rec['llm_busy_s']:.1f}s", True,
                         self.ui.dim(f"x{rec['parallelism']} overlap, jobs {self.jobs}, cache hits {cache}"))
        else:
            self.ui.line("timing", f"{rec['wall_s']:.1f}s wall, LLM {rec['llm_busy_s']:.1f}s", True,
                         self.ui.dim(f"x{rec['parallelism']} overlap, jobs {self.jobs}"))
        return rec

    @property
    def slug(self) -> str:
        return self.store.slug

    @property
    def game_dir(self) -> Path:
        return self.store.game_dir

    @property
    def base_files(self) -> set[str]:
        """Files Forge's fixer must not touch: the runtime, plus every human file of a seeded game
        (spec["base_files"], written by `forge seed`)."""
        seeded = {p for p in (self.spec.get("base_files") or []) if isinstance(p, str)}
        return set(RUNTIME_FILES) | seeded

    # ---------------------------------------------------------- LLM calls
    async def call(self, role: str, label: str, fn: Callable, *args, **kwargs) -> Any:
        """Run fn(llm, *args, **kwargs) on the LLM pool. Safe to run many at once (asyncio.gather)."""
        new: list = []
        token = _CALL_BUCKET.set(new)
        sink = _CALLS_SINK.get()
        calls = sink if sink is not None else self.calls
        span: dict = {}
        t0 = time.monotonic()

        def job():
            nonlocal t0
            t0 = time.monotonic()  # timed from when a pool worker picks it up, not while it queues
            span["_c"] = self.timeline.start_call(role, label)
            return fn(self.llm, *args, **kwargs)

        try:
            ctx = contextvars.copy_context()
            out = await asyncio.get_running_loop().run_in_executor(self._pool, functools.partial(ctx.run, job))
        except Exception as e:
            secs = time.monotonic() - t0
            self.ui.call(role, label, False, secs, None, err=f"{type(e).__name__}: {e}")
            calls.append({"role": role, "label": label, "ok": False, "error": str(e),
                          "request_ids": [getattr(r, "request_id", None) for r in new]})
            if span:
                self.timeline.end_call(span["_c"], ok=False, n_calls=len(new), error=f"{type(e).__name__}: {e}")
            raise
        finally:
            _CALL_BUCKET.reset(token)
        cached = bool(new) and all(getattr(r, "cached", False) for r in new)
        secs = (sum((getattr(r, "latency_ms", 0) or 0) for r in new) / 1000) if new else 0.0
        if secs <= 0 and not cached:
            secs = time.monotonic() - t0
        rid = getattr(new[-1], "request_id", None) if new else None
        _LAST_RID.set(rid)
        self.ui.call(role, label + (" (cached)" if cached else ""), True, secs, rid, n_calls=len(new))
        calls.append({"role": role, "label": label, "ok": True, "request_id": rid,
                      "request_ids": [getattr(r, "request_id", None) for r in new],
                      "latency_ms": int(secs * 1000), **({"cached": True} if cached else {})})
        if span:
            self.timeline.end_call(span["_c"], ok=True, latency_ms=int(secs * 1000), request_id=rid,
                                   cached=cached, n_calls=len(new))
        return out

    @property
    def last_request_id(self) -> str | None:
        """Request id of the last call made by this task (concurrent calls each see their own)."""
        rid = _LAST_RID.get()
        if rid:
            return rid
        for c in reversed(self.calls):
            if c.get("request_id"):
                return c["request_id"]
        return None

    # ---------------------------------------------------------- files
    def file_path(self, rel: str) -> Path:
        p = (self.game_dir / rel).resolve()
        if not str(p).startswith(str(self.game_dir.resolve())):
            raise ValueError(f"path escapes game dir: {rel}")
        return p

    def read(self, rel: str) -> str:
        p = self.file_path(rel)
        return p.read_text() if p.exists() else ""

    def write(self, rel: str, source: str) -> None:
        p = self.file_path(rel)
        p.parent.mkdir(parents=True, exist_ok=True)
        if not source.endswith("\n"):
            source += "\n"
        p.write_text(source)

    def game_files(self) -> list[str]:
        """All generated Luau files (spec modules + anything the fixer created), excluding base runtime/tools."""
        out = []
        for p in sorted(self.game_dir.rglob(f"*{LUAU_SUFFIX}")):
            rel = _rel(p, self.game_dir)
            if rel.startswith("tools/") or rel in self.base_files:
                continue
            out.append(rel)
        return out

    def resolve_path(self, path: str) -> str | None:
        """Map a loosely given path (from a human or the critic) to a file in the game."""
        cleaned = clean_rel_path(path) or (path or "").strip().replace("\\", "/")
        if not cleaned:
            return None
        if "runs/" in cleaned and "/game/" in cleaned:
            cleaned = cleaned.split("/game/", 1)[1]
        if clean_rel_path(cleaned):
            with contextlib.suppress(ValueError):
                if self.file_path(cleaned).exists():
                    return cleaned
        candidates = self.game_files() + [m["path"] for m in self.spec.get("modules", [])]
        for c in candidates:  # suffix match: "Game.server.luau" -> "ServerScriptService/Game.server.luau"
            if c == cleaned or c.endswith("/" + cleaned):
                return c
        stem = Path(cleaned).name.split(".")[0].lower()
        for c in candidates:
            if Path(c).name.split(".")[0].lower() == stem:
                return c
        if clean_rel_path(cleaned) and cleaned.split("/")[0] in SCRIPT_ROOTS:
            return cleaned  # a new file the critic/human wants created
        return None

    # ---------------------------------------------------------- compile check
    def check(self) -> list[tuple[str, str]]:
        if self._check_fn is None:
            self._check_fn = _load_check_fn(self.settings)
        result = self._check_fn(self.game_dir) or []
        out = []
        for item in result:
            path, msg = item[0], item[1]
            out.append((_rel(path, self.game_dir), str(msg)))
        return out

    def check_file(self, rel: str) -> str | None:
        """luau-compile one file: its error text, or None if it compiles (or cannot be checked here)."""
        exe = shutil.which("luau-compile")
        p = self.file_path(rel)
        if not exe or not p.exists():
            return None
        r = subprocess.run([exe, "--null", str(p)], capture_output=True, text=True)
        if r.returncode == 0:
            return None
        lines = [ln for ln in (r.stdout + r.stderr).splitlines() if ln.strip() and not ln.startswith("Compiled ")]
        return "\n".join(ln.replace(str(p), p.name) for ln in lines) or f"luau-compile exit {r.returncode}"

    def _fixable(self, path: str) -> bool:
        return path not in self.base_files and not path.startswith("tools/")

    async def fix_compile_file(self, path: str, msg: str | None = None, *, rec: dict | None = None,
                               lessons: str | None = None, session_id: str | None = None) -> str | None:
        """Fixer loop for one file: fix, recompile just this file, up to MAX_FIX_ATTEMPTS. Many files run
        at once. msg=None compiles the file first. Returns the error left, or None if it compiles."""
        from forge import roles

        if msg is None:
            msg = await asyncio.to_thread(self.check_file, path)
        attempt = 0
        while msg and attempt < MAX_FIX_ATTEMPTS and self._fixable(path):
            attempt += 1
            if lessons is None:
                await self.settle_reflection()  # the fixer reads lessons: wait for a pending reflector
                lessons = read_lessons(self.settings)
            module = next((m for m in self.spec.get("modules", []) if m["path"] == path), {})
            context = spec_summary(self.spec)
            if module.get("purpose"):
                context += f"\nThis file: {module['purpose']}"
            problem = f"luau-compile failed (attempt {attempt}/{MAX_FIX_ATTEMPTS}):\n{msg.strip()}"
            try:
                fixed = await self.call("fixer", f"{path} (compile)", roles.fix_file, path,
                                        self.read(path), problem, context, lessons,
                                        session_id=session_id or self.slug)
                self.write(path, fixed)
                if rec is not None:
                    rec["fixes"].append({"path": path, "kind": "compile", "problem": msg.strip()[:500],
                                         "request_id": self.last_request_id})
            except Exception as e:
                if rec is not None:
                    rec["steps"].append({"step": f"fix_compile:{path}", "ok": False, "error": str(e)})
                continue
            msg = await asyncio.to_thread(self.check_file, path)
        return msg or None

    async def compile_fix(self, rec: dict | None = None, only: set[str] | None = None) -> list[tuple[str, str]]:
        """luau-compile everything; every failing file goes to the fixer at once (one loop per file,
        up to MAX_FIX_ATTEMPTS each); then one final check of the whole tree."""

        async def full_check() -> list[tuple[str, str]] | None:
            t0 = time.monotonic()
            try:
                errors = await asyncio.to_thread(self.check)
            except Exception as e:
                self.ui.line("check", "luau-compile", False, self.ui.red(str(e)[:80]))
                if rec is not None:
                    rec["steps"].append({"step": "compile_check", "ok": False, "error": str(e)})
                return None
            n_files = len(self.game_files())
            if not errors:
                self.ui.line("check", f"luau-compile {n_files} files", True, f"{time.monotonic() - t0:4.1f}s")
            else:
                self.ui.line("check", f"luau-compile {len(errors)}/{n_files} failing", False,
                             self.ui.dim(", ".join(Path(p).name for p, _ in errors)[:60]))
            return errors

        errors = await full_check()
        if not errors:
            return []
        fixable = [(p, m) for p, m in errors if self._fixable(p) and (only is None or p in only)]
        if fixable:
            await self.settle_reflection()
            lessons = read_lessons(self.settings)
            await asyncio.gather(*(self.fix_compile_file(p, m, rec=rec, lessons=lessons) for p, m in fixable))
            errors = await full_check()
            if errors is None:
                return []
        if errors and rec is not None:
            rec["compile_errors"] = [{"path": p, "error": m} for p, m in errors]
        return errors

    # ---------------------------------------------------------- build
    async def build_modules(self, modules: list[dict], *, session_id: str | None = None,
                            lessons: str | None = None, spec: dict | None = None,
                            compile_check: bool = True) -> tuple[list[str], list[dict]]:
        """Write modules with the coder, as a DAG: a module starts the moment the modules it depends on
        are written (independent ones go out together, up to --jobs). Each written module is compiled
        right away and sent to the fixer if it fails, while the others are still being written.
        Returns (built paths in dependency order, [{path, error}] for modules that failed)."""
        from forge import roles

        order = topo_order(modules)
        pos = {m["path"]: i for i, m in enumerate(order)}
        written = {m["path"]: asyncio.Event() for m in order}
        spec = spec if spec is not None else self.spec
        if lessons is None:
            lessons = director.coder_notes(spec, read_lessons(self.settings))
        built: set[str] = set()
        failed: list[dict] = []

        async def one(module: dict) -> None:
            path = module["path"]
            if module.get("prebuilt"):  # written by the art pass (director.install_kit), not the coder
                written[path].set()
                return
            try:
                # only deps earlier in topo order: a dependency cycle falls back to the designer's order
                for d in module.get("depends", []):
                    if d in written and pos[d] < pos[path]:
                        await written[d].wait()
                deps = {}
                for d in module.get("depends", []):
                    src = self.read(d) if clean_rel_path(d) else ""
                    if src:
                        deps[d] = src
                try:
                    source = await self.call("coder", path, roles.code_module, spec, module, deps, lessons,
                                             session_id=session_id or self.slug)
                except Exception as e:  # logged by call(); the critic/fixer will see the missing file
                    failed.append({"path": path, "error": str(e)[:200]})
                    return
                self.write(path, source)
                built.add(path)
            finally:
                written[path].set()
            if compile_check:
                first = await asyncio.to_thread(self.check_file, path)
                self.compile_first[path] = first  # the coder's first try, before any fixer (forge bench)
                if first:
                    await self.fix_compile_file(path, first, rec=self.build_rec, lessons=lessons,
                                                session_id=session_id)

        await asyncio.gather(*(one(m) for m in order))
        return [m["path"] for m in order if m["path"] in built], failed

    async def build_all(self) -> None:
        modules = self.spec.get("modules", [])
        self.ui.header(f"build  {len(modules)} modules  (jobs {self.jobs})")
        with self.stage("build"):
            await self.build_modules(modules)

    # ---------------------------------------------------------- studio
    async def playtest(self, studio: Any, rec: dict, it_dir: Path) -> tuple[dict, str]:
        report: dict = {}
        console = ""

        async def step(name: str, coro):
            t0 = time.monotonic()
            try:
                val = await coro
                rec["steps"].append({"step": name, "ok": True})
                return True, val, time.monotonic() - t0
            except Exception as e:
                rec["steps"].append({"step": name, "ok": False, "error": f"{type(e).__name__}: {e}"})
                self.ui.line("studio", name, False, self.ui.red(f"{type(e).__name__}: {e}"[:80]))
                return False, None, time.monotonic() - t0

        ok, out, secs = await step("sync", studio.sync(self.game_dir, self.settings.sync_port))
        if ok:
            out_s = str(out or "")
            if out_s.startswith("ERROR"):
                rec["steps"][-1].update(ok=False, error=out_s)
                self.ui.line("studio", "sync", False, self.ui.red(out_s[:80]))
            else:
                self.ui.line("studio", "sync → Studio", True, f"{secs:4.1f}s  {self.ui.dim(out_s[:50])}")
        try:
            ok, _, secs = await step("play", studio.play())
            if ok:
                wait = play_seconds()
                self.ui.line("studio", f"playtest running ({wait:.0f}s)", True, f"{secs:4.1f}s")
                if (self.spec.get("playtest") or {}).get("start_round"):
                    # games with a lobby: start a round through the ForgeTest harness so the playtest
                    # measures the core loop, not the lobby (per-game setting in the spec)
                    from mubit_tester.harness import build_call_luau

                    args = {"state": "Active"}
                    secs_round = (self.spec.get("playtest") or {}).get("round_seconds")
                    if secs_round:
                        args["seconds"] = int(secs_round)
                    await asyncio.sleep(min(wait, START_ROUND_DELAY))
                    ok2, val2, _ = await step("start_round", studio.execute_luau(build_call_luau("round", args), "Server"))
                    self.ui.line("studio", "start round", ok2, self.ui.dim(str(val2)[:60]))
                    wait = max(0.0, wait - START_ROUND_DELAY)
                    await asyncio.sleep(wait)  # the round is already running: just let it play
                else:
                    waited = await wait_for_game(studio, wait)
                    rec["steps"].append({"step": "wait", "ok": waited["mode"] != "fallback", **waited})
                    self.ui.line("studio", f"game ready ({waited['mode']})", waited["mode"] != "fallback",
                                 f"{waited['secs']:4.1f}s")
                ok, val, _ = await step("probe_report", studio.probe_report())
                if ok and isinstance(val, dict) and val.get("error") and "uptime" not in val:
                    report = val
                    rec["steps"][-1].update(ok=False, error=str(val["error"]))
                    self.ui.line("probe", "ForgeProbe report", False, self.ui.red(str(val["error"])[:80]))
                elif ok and isinstance(val, dict):
                    report = val
                    errs = len(report.get("errors") or [])
                    warns = len(report.get("warnings") or [])
                    counters = report.get("counters") or {}
                    detail = f"{errs} errors, {warns} warnings, players {report.get('players', '?')}"
                    if counters:
                        detail += "  " + self.ui.dim(json.dumps(counters)[:40])
                    self.ui.line("probe", "ForgeProbe report", errs == 0, detail)
                ok, val, _ = await step("console", studio.console())
                if ok:
                    console = str(val or "")
                ok, val, _ = await step("screenshot", studio.screenshot(it_dir / "screenshot.png"))
                if ok and val:
                    self.ui.line("studio", "screenshot", True, self.ui.dim(_rel(val, self.settings.repo_root)))
                from forge import fun  # scene census for the fun critic and `forge done` (forge/fun.py)
                ok, val, _ = await step("census", fun.census(studio))
                if ok and isinstance(val, dict):
                    report["census"] = val
        finally:
            with contextlib.suppress(Exception):
                ok, _, _ = await step("stop", studio.stop())
                if ok:
                    self.ui.line("studio", "stop playtest", True)
        return report, console

    # ---------------------------------------------------------- one iteration
    async def iteration(self, n: int, studio: Any | None) -> tuple[dict, bool]:
        from forge import roles

        self.ui.header(f"iteration {n}  {self.slug}")
        self.calls = []
        rec: dict = {"n": n, "started": now_iso(), "studio": studio is not None, "steps": [],
                     "compile_errors": [], "runtime_errors": [], "fixes": [], "score": None,
                     "issues": [], "summary": "", "done": False}
        it_dir = self.store.iteration_dir(n)
        rec["fixes"] += self.build_rec["fixes"]
        rec["steps"] += self.build_rec["steps"]
        self.build_rec = {"fixes": [], "steps": []}

        # 1. compile check + fixer
        with self.stage(f"iteration {n}: compile"):
            remaining = await self.compile_fix(rec)
        rec["compile_errors"] = [{"path": p, "error": m} for p, m in remaining]
        versions = GameVersions(self.store.game_dir)
        rec["version"] = versions.snapshot(f"iteration {n}: code under test")
        self.ui.line("version", rec["version"], True, self.ui.dim("forge versions / forge rollback"))

        # 2. playtest in Studio
        report: dict = {}
        console = ""
        if studio is not None:
            try:
                with self.stage(f"iteration {n}: playtest"):
                    report, console = await self.playtest(studio, rec, it_dir)
            except Exception as e:
                rec["steps"].append({"step": "playtest", "ok": False, "error": str(e)})
                self.ui.line("studio", "playtest", False, self.ui.red(str(e)[:80]))
        else:
            report = {"runtime": "not run (--no-studio): compile check only"}
            self.ui.line("studio", "skipped (--no-studio)", None)
        report["compile_errors"] = rec["compile_errors"]
        rec["runtime_errors"] = [
            (e.get("message") if isinstance(e, dict) else str(e)) for e in (report.get("errors") or [])
        ]
        self.store.save_iteration_json(n, "report.json", report)
        if console:
            (it_dir / "console.txt").write_text(console)

        # 3. critic
        files = {}
        for rel in self.game_files():
            src = self.read(rel)
            if len(src) > MAX_FILE_CHARS:
                src = src[:MAX_FILE_CHARS] + "\n-- [truncated]\n"
            files[rel] = src
        critique: dict | None = None
        # the fun critic reads the same files and report, so it runs alongside the critic
        fun_task = asyncio.create_task(self.fun_pass(n, files, report))
        try:
            with self.stage(f"iteration {n}: critic"):
                critique = await self.call("critic", f"{len(files)} files", roles.critique, self.spec,
                                           report, console[-4000:], files, session_id=self.slug)
                fun_res = await fun_task
            self.store.save_iteration_json(n, "critique.json", critique)
        except Exception as e:
            rec["steps"].append({"step": "critique", "ok": False, "error": str(e)})
            if not fun_task.done():
                fun_task.cancel()

        stop = False
        if critique:
            try:
                score = float(critique.get("score", 0))
            except (TypeError, ValueError):
                score = 0.0
            rec["score"] = score
            rec["summary"] = str(critique.get("summary", ""))
            rec["issues"] = [i for i in critique.get("issues") or [] if isinstance(i, dict)]
            rec["done"] = bool(critique.get("done")) or score >= TARGET_SCORE
            # fun critic (forge/fun.py): its issues join the critic's, and "done" needs fun >= bar too
            if fun_res is not None:
                rec["fun"] = {k: fun_res.get(k) for k in ("score", "scores", "summary", "missing_juice")}
                rec["issues"] = (rec["issues"] + fun_res["issues"])[:8]
                rec["done"] = rec["done"] and fun_res["score"] >= FUN_BAR
            stop = rec["done"]
            colour = self.ui.green if score >= TARGET_SCORE else (self.ui.yellow if score >= 5 else self.ui.red)
            self.ui.line("score", f"{colour(f'{score:g}/10')}  {len(rec['issues'])} issues", None,
                         self.ui.dim(rec["summary"][:70]))

            best = self.best_version()
            if best and score <= best["score"] - ROLLBACK_DROP:
                versions.restore(best["version"], f"iteration {n} scored {score:g}, below "
                                 f"{best['score']:g} at {best['version']}")
                rec["rolled_back_to"] = best["version"]
                self.ui.line("rollback", f"score {score:g} < best {best['score']:g}", True,
                             self.ui.dim(f"restored {best['version']}"))

            # 4. fix critic issues: one fixer call per file (not on code that was just rolled back)
            if not stop and rec["issues"] and not rec.get("rolled_back_to"):
                with self.stage(f"iteration {n}: fix"):
                    await self.fix_issues(rec, report)
                    remaining = await self.compile_fix(rec)
                rec["compile_errors_after_fix"] = [{"path": p, "error": m} for p, m in remaining]

        # 5. reflect -> lessons, in the background: nothing until the next fixer reads lessons needs it,
        # so it overlaps the next iteration's compile check, playtest and critic (settle_reflection).
        rec["ended"] = now_iso()
        rec["calls"] = self.calls
        self._reflecting = asyncio.create_task(
            self._reflect(n, rec, self.iteration_summary(rec), self._reflecting))

        # 6. save
        self.store.save_iteration_json(n, "record.json", rec)
        state = self.store.load_state()
        state["iterations"] = [it for it in state["iterations"] if it.get("n") != n]
        state["iterations"].append({
            "n": n, "score": rec["score"], "issues": rec["issues"], "summary": rec["summary"],
            "errors": [f"{e['path']}: {e['error']}" for e in rec["compile_errors"]] + rec["runtime_errors"],
            "studio": rec["studio"], "fixes": len(rec["fixes"]), "version": rec.get("version"),
            "rolled_back_to": rec.get("rolled_back_to"),
            "failed_steps": [s["step"] for s in rec["steps"] if not s.get("ok")],
            "request_ids": [c.get("request_id") for c in self.calls if c.get("request_id")],
            "ended": rec["ended"],
        })
        self.store.save_state(state)
        return rec, stop

    async def fun_pass(self, n: int, files: dict[str, str], report: dict) -> dict | None:
        """Fun critic on this iteration (off with FORGE_FUN_CRITIC=0 and for seeded human games)."""
        from forge import fun

        if os.environ.get("FORGE_FUN_CRITIC", "1") == "0" or self.spec.get("base_files"):
            return None
        try:
            res = await self.call("fun_critic", f"{len(files)} files", fun.fun_critique, self.spec, files, report,
                                  census=report.get("census"), session_id=self.slug)
        except Exception as e:
            self.ui.line("fun", "fun critic", False, self.ui.red(str(e)[:80]))
            return None
        fun.FunStore(self.settings, self.slug).save(n, res)
        sc = res["scores"]
        self.ui.line("fun", f"{res['score']:g}/10", res["score"] >= FUN_BAR,
                     self.ui.dim(" ".join(f"{k} {v:g}" for k, v in sc.items())))
        return res

    async def _reflect(self, n: int, rec: dict, summary: str, previous: asyncio.Task | None) -> None:
        """Reflector for iteration n (background task). Waits for the previous one so two reflectors
        never rewrite lessons.md from the same old copy; re-saves record.json when done."""
        from forge import roles

        if previous is not None:
            with contextlib.suppress(Exception):
                await previous
        token = _CALLS_SINK.set(rec["calls"])  # this iteration's call list, not the next one's
        try:
            with self.stage(f"iteration {n}: reflect (background)"):
                lessons = read_lessons(self.settings)
                new_lessons = await self.call("reflector", "runs/lessons.md", roles.reflect, lessons, summary,
                                              session_id=self.slug)
            if isinstance(new_lessons, str) and new_lessons.strip():
                write_lessons(self.settings, new_lessons)
                rec["lessons_updated"] = True
        except Exception as e:
            rec["steps"].append({"step": "reflect", "ok": False, "error": str(e)})
        finally:
            _CALLS_SINK.reset(token)
        with contextlib.suppress(OSError):
            self.store.save_iteration_json(n, "record.json", rec)

    async def settle_reflection(self) -> None:
        """Wait for a background reflector (before anything reads lessons, and before exiting)."""
        task = self._reflecting
        if task is not None and task is not asyncio.current_task():
            with contextlib.suppress(Exception):
                await task

    async def fix_issues(self, rec: dict, report: dict) -> None:
        """One fixer call per file the critic named, all files at once."""
        from forge import roles

        by_path: dict[str, list[dict]] = defaultdict(list)
        for issue in rec["issues"]:
            path = self.resolve_path(str(issue.get("path", "")))
            if path is None:
                # unknown path: attach to the main server script if we have one
                path = next((m["path"] for m in self.spec.get("modules", [])
                             if m["path"].endswith(".server.luau")), None)
            if path and path not in self.base_files:
                by_path[path].append(issue)
        runtime = report.get("errors") or []
        await self.settle_reflection()
        lessons = director.coder_notes(self.spec, read_lessons(self.settings))

        async def fix_one(path: str, issues: list[dict]) -> None:
            problem = "Playtest critique:\n" + "\n".join(
                f"- {i.get('problem', '')}" + (f" (hint: {i['fix_hint']})" if i.get("fix_hint") else "")
                for i in issues)
            context = spec_summary(self.spec)
            name = Path(path).name.split(".")[0]
            related = [e for e in runtime if name and name in json.dumps(e)]
            if related:
                context += "\nRuntime errors in this file:\n" + json.dumps(related, indent=1)[:2000]
            try:
                fixed = await self.call("fixer", path, roles.fix_file, path, self.read(path), problem,
                                        context, lessons, session_id=self.slug)
                self.write(path, fixed)
                rec["fixes"].append({"path": path, "kind": "critic", "problem": problem[:500],
                                     "request_id": self.last_request_id})
            except Exception as e:
                rec["steps"].append({"step": f"fix:{path}", "ok": False, "error": str(e)})

        await asyncio.gather(*(fix_one(p, issues) for p, issues in by_path.items()))

    def best_version(self) -> dict | None:
        """The best-scoring earlier iteration that has a version: {"version", "score"}. Only iterations
        from state["rollback_floor"] on count: a new feature changes the game, so scores from before it
        are not a bar to roll back to (that would undo the feature)."""
        state = self.store.load_state()
        floor = int(state.get("rollback_floor") or 0)
        scored = [it for it in state.get("iterations", [])
                  if it.get("version") and it.get("score") is not None and it.get("n", 0) >= floor]
        if not scored:
            return None
        top = max(scored, key=lambda it: (it["score"], it["n"]))
        return {"version": top["version"], "score": float(top["score"])}

    def iteration_summary(self, rec: dict) -> str:
        lines = [spec_summary(self.spec), f"Iteration {rec['n']} (studio playtest: {rec['studio']})",
                 f"Score: {rec['score']}  {rec['summary']}"]
        if rec["compile_errors"]:
            lines.append("Compile errors left after fixer:")
            lines += [f"- {e['path']}: {e['error'][:300]}" for e in rec["compile_errors"]]
        compile_fixes = [f for f in rec["fixes"] if f["kind"] == "compile"]
        if compile_fixes:
            lines.append("Compile errors that needed the fixer:")
            lines += [f"- {f['path']}: {f['problem'][:300]}" for f in compile_fixes]
        if rec["runtime_errors"]:
            lines.append("Runtime errors in playtest:")
            lines += [f"- {e[:300]}" for e in rec["runtime_errors"][:10]]
        if rec["issues"]:
            lines.append("Critic issues:")
            lines += [f"- {i.get('path', '?')}: {i.get('problem', '')}" for i in rec["issues"]]
        if rec.get("rolled_back_to"):
            lines.append(f"Rolled back to {rec['rolled_back_to']}: this version scored lower than it, "
                         "so the fixes made since then were undone. Learn what made it worse.")
        failed = [s for s in rec["steps"] if not s.get("ok")]
        if failed:
            lines.append("Failed steps: " + ", ".join(f"{s['step']} ({s.get('error', '')[:80]})" for s in failed))
        return "\n".join(lines)

    # ---------------------------------------------------------- iterations
    async def iterate(self, iterations: int, use_studio: bool) -> list[dict]:
        records = []
        async with contextlib.AsyncExitStack() as stack:
            studio = None
            if use_studio:
                studio = await self.open_studio(stack)
            state = self.store.load_state()
            start = self.store.next_iteration(state)
            for n in range(start, start + max(0, iterations)):
                rec, stop = await self.iteration(n, studio)
                records.append(rec)
                if stop:
                    self.ui.line("done", f"target reached at iteration {n}", True)
                    break
        await self.settle_reflection()  # Studio is already released; the last lessons still get written
        return records

    async def open_studio(self, stack: contextlib.AsyncExitStack) -> Any | None:
        try:
            from forge.studio import Studio
            studio = await stack.enter_async_context(Studio(self.settings))
            sid = await studio.select(os.environ.get("FORGE_STUDIO") or None)
            self.ui.line("studio", "connected", True, self.ui.dim(str(sid)))
            return studio
        except Exception as e:
            self.ui.line("studio", "unavailable, continuing compile-only", False,
                         self.ui.red(f"{type(e).__name__}: {e}"[:70]))
            return None


# ================================================================ public API

async def new_game(idea: str, iterations: int = 3, use_studio: bool = True, *,
                   settings: Settings | None = None, llm: Any = None, ui: UI | None = None,
                   use_director: bool | None = None, jobs: int | None = None) -> str:
    """Design, build and iterate a new game. Returns its slug. jobs = concurrent LLM calls."""
    from forge import roles

    settings = settings or load_settings()
    slug = unique_slug(settings, slugify(idea))
    store = RunStore(settings, slug)
    store.ensure()
    store.save_state(store.new_state(idea))
    run = Run(settings, store, llm, ui, jobs=jobs, command="new")
    run.ui.header(f"forge new  {slug}")
    run.ui.print(f"  {run.ui.dim('idea:')} {idea}")

    if use_director is None:
        use_director = os.environ.get("FORGE_DIRECTOR", "1") != "0"
    with run.stage("design"):
        if use_director:  # director design doc -> designer (forge/director.py)
            spec = await run.call("director", "design doc + spec.json", director.plan, idea,
                                  read_lessons(settings), session_id=slug)
        else:
            spec = await run.call("designer", "spec.json", roles.design, idea, read_lessons(settings),
                                  session_id=slug)
    spec = normalize_spec(spec, slug)
    run.spec = spec
    store.save_spec(spec)
    run.ui.print(f"  {run.ui.bold(spec.get('title', slug))} - {run.ui.dim(str(spec.get('pitch', '')))}")
    if spec.get("director"):
        run.ui.print("  " + run.ui.dim(json.dumps(director.spec_stats(spec))))

    copy_base_game(settings, store.game_dir)
    director.install_kit(spec, store.game_dir)  # art pass: GameAssets.luau before the coder runs
    await run.build_all()
    await run.iterate(iterations, use_studio)
    print_summary(run)
    run.save_timings()
    return slug


async def run_game(slug: str, iterations: int = 3, use_studio: bool = True, *,
                   settings: Settings | None = None, llm: Any = None, ui: UI | None = None,
                   jobs: int | None = None) -> str:
    """Continue iterating an existing game."""
    settings = settings or load_settings()
    store = RunStore(settings, slug)
    if not store.exists():
        raise FileNotFoundError(f"no game {slug!r} in {settings.runs_dir}")
    run = Run(settings, store, llm, ui, jobs=jobs, command="run")
    run.spec = store.load_spec()
    run.ui.header(f"forge run  {slug}")
    if not store.game_dir.exists():
        copy_base_game(settings, store.game_dir)
    if not (store.game_dir / director.GAME_ASSETS).exists():
        director.install_kit(run.spec, store.game_dir)
    missing = [m for m in run.spec.get("modules", []) if not run.read(m["path"])]
    if missing:
        spec_all = run.spec
        run.spec = {**spec_all, "modules": missing}
        await run.build_all()
        run.spec = spec_all
    await run.iterate(iterations, use_studio)
    print_summary(run)
    run.save_timings()
    return slug


async def correct(slug: str, path: str, note: str, use_studio: bool = True, *,
                  settings: Settings | None = None, llm: Any = None, ui: UI | None = None) -> dict:
    """Human correction -> fixer call (same Mubit task as every other fix) -> compile check -> resync."""
    from forge import roles

    settings = settings or load_settings()
    store = RunStore(settings, slug)
    if not store.exists():
        raise FileNotFoundError(f"no game {slug!r} in {settings.runs_dir}")
    run = Run(settings, store, llm, ui, command="correct")
    run.spec = store.load_spec()
    run.calls = []
    run.ui.header(f"forge correct  {slug}")
    rel = run.resolve_path(path)
    if rel is None:
        raise FileNotFoundError(f"cannot find {path!r} in {store.game_dir}")
    run.ui.print(f"  {run.ui.dim('human:')} {note}")

    state = store.load_state()
    last = store.last_iteration(state)
    context = spec_summary(run.spec)
    if last is not None:
        report = store.load_iteration_json(last, "report.json", {}) or {}
        context += f"\nLast playtest probe (iteration {last}):\n" + json.dumps(report)[:3000]
    before = run.read(rel)
    problem = f"Human playtester correction:\n{note}"
    # big files get exact edits (patcher) so a correction never shortens the file; small ones a rewrite
    big = len(before.splitlines()) > PATCH_ABOVE_LINES
    role, rewrite = ("patcher", roles.patch_file) if big else ("fixer", roles.fix_file)
    fixed = await run.call(role, f"{rel} (human)", rewrite, rel, before, problem, context,
                           read_lessons(settings), session_id=slug)
    run.write(rel, fixed)
    request_id = run.last_request_id

    rec = {"steps": [], "fixes": [], "compile_errors": []}
    remaining = await run.compile_fix(rec)
    synced = None
    if use_studio:
        async with contextlib.AsyncExitStack() as stack:
            studio = await run.open_studio(stack)
            if studio is not None:
                try:
                    out = str(await studio.sync(store.game_dir, settings.sync_port))
                    synced = not out.startswith("ERROR")
                    run.ui.line("studio", "resync → Studio", synced, run.ui.dim(out[:50]))
                except Exception as e:
                    synced = False
                    run.ui.line("studio", "resync", False, run.ui.red(str(e)[:70]))

    correction = {
        "ts": now_iso(), "kind": "human", "path": rel, "note": note, "request_id": request_id,
        "after_iteration": last, "compile_ok": not remaining,
        "compile_errors": [{"path": p, "error": m} for p, m in remaining],
        "synced": synced, "calls": run.calls,
    }
    store.save_correction({**correction, "before": before, "after": run.read(rel)})
    state = store.load_state()
    state["corrections"].append(correction)
    store.save_state(state)

    run.ui.print()
    run.ui.print(f"  {run.ui.green('●')} correction recorded in the {run.ui.bold('fixer')} task  "
                 f"{run.ui.cyan(request_id or '-')}")
    run.ui.print(f"    {run.ui.dim('rate it Good in the Mubit console → Requests: https://app.mubit.ai/console/')}")
    run.close()
    run.timeline.finish()
    return correction


def print_summary(run: Run) -> None:
    state = run.store.load_state()
    its = state.get("iterations", [])
    run.ui.header("summary")
    for it in its:
        score = it.get("score")
        run.ui.print(f"  iteration {it['n']}: score {'-' if score is None else format(score, 'g')}"
                     f"  issues {len(it.get('issues') or [])}  errors {len(it.get('errors') or [])}")
    run.ui.print(f"  game files: {_rel(run.game_dir, run.settings.repo_root)}")
