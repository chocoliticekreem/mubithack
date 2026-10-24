"""Live build progress for the screens that watch a build (the MuMake plugin, the dashboard):
runs/<slug>/progress.json, rewritten atomically on every change and once a second by a ticker so it never sits
still while a long call is out.

    {"slug", "command", "running", "pct" 0..100, "phase": design|levels|build|playtest|done|failed, "step",
     "items": {"label", "done", "total"} | null, "started", "updated", "eta_s", "events": [{"t", "text", "ok"}]}

pct bands: design 0-15, then plan() splits 15-98 over the phases the build will run, by WEIGHTS (a template obby:
levels 15-70, build 70-85, playtest 85-98; a game without levels: build 15-60, playtest 60-98), done 100. Without
plan() the bands are BANDS. Inside a band pct moves by items done, plus a creep for each item in flight, timed from
when that item started, that stays below the step it would complete; with no items it creeps toward the band's top
by the phase's expected seconds. pct never goes down while running.
"""
from __future__ import annotations

import json
import math
import os
import threading
import time
from pathlib import Path
from typing import Callable

BANDS = {"design": (0, 15), "levels": (15, 80), "build": (80, 98)}
WEIGHTS = {"levels": 55, "build": 15, "playtest": 13}
EXPECTED_S = {"design": 75.0, "levels": 130.0, "build": 60.0, "playtest": 150.0}  # a phase without items; else per item
MAX_EVENTS = 40
TICK_S = 1.0


class Progress:
    def __init__(self, path: Path, slug: str, command: str = "new", *, clock: Callable[[], float] = time.time):
        self.path = Path(path)
        self.clock = clock
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        now = clock()
        self.state = {"slug": slug, "command": command, "running": True, "pct": 0, "phase": "design",
                      "step": "Starting", "items": None, "started": now, "updated": now, "eta_s": None,
                      "events": []}
        self.bands = dict(BANDS)
        self._phase_t = now
        self._starts: list[float] = [now]  # when each item in flight started, oldest first
        self._inflight = 1
        self._est = EXPECTED_S["design"]
        self._write()

    def plan(self, phases: list[str]) -> None:
        """The phases after design this build will run, in order: their bands share 15-98 by WEIGHTS, so a build
        without levels does not jump to 80 and the playtest has room to move."""
        with self._lock:
            lo, top = BANDS["design"][1], BANDS["build"][1]
            total = sum(WEIGHTS[p] for p in phases) or 1
            for p in phases:
                hi = lo + (top - BANDS["design"][1]) * WEIGHTS[p] / total
                self.bands[p] = (lo, hi)
                lo = hi

    # ------------------------------------------------------------ updates (any thread)
    def phase(self, name: str, step: str, *, items: tuple[str, int] | None = None, expected_s: float | None = None):
        with self._lock:
            now = self.clock()
            self.state.update(phase=name, step=step,
                              items={"label": items[0], "done": 0, "total": int(items[1])} if items else None)
            self._phase_t = now
            self._starts = [now]
            self._inflight = 1
            self._est = float(expected_s or EXPECTED_S.get(name, 60.0))
            self._refresh(now)

    def step(self, text: str, *, inflight: int | None = None) -> None:
        with self._lock:
            self.state["step"] = text
            now = self.clock()
            if inflight is not None:
                self._inflight = max(1, int(inflight))
                del self._starts[self._inflight:]
                self._fill(now)
            self._refresh(now)

    def item_done(self, n: int = 1) -> None:
        with self._lock:
            it = self.state["items"]
            now = self.clock()
            if it:
                it["done"] = min(it["total"], it["done"] + n)
                del self._starts[:n]  # the oldest in flight finished; the rest keep their head start
                self._fill(now)
            self._refresh(now)

    def event(self, text: str, ok: bool | None = None) -> None:
        with self._lock:
            ev = self.state["events"]
            ev.append({"t": self.clock(), "text": str(text), "ok": ok})
            del ev[:-MAX_EVENTS]
            self._refresh(self.clock())

    def tick(self) -> None:
        with self._lock:
            if self.state["running"]:
                self._refresh(self.clock())

    def done(self, text: str) -> None:
        with self._lock:
            self.state.update(running=False, pct=100, phase="done", step=text, eta_s=0)
            self.state["events"].append({"t": self.clock(), "text": text, "ok": True})
            del self.state["events"][:-MAX_EVENTS]
            self._refresh(self.clock(), keep_pct=True)
        self.stop()

    def fail(self, exc: BaseException) -> None:
        with self._lock:
            text = f"Build stopped: {type(exc).__name__}" + (f": {str(exc)[:160]}" if str(exc) else "")
            self.state.update(running=False, phase="failed", step=text, eta_s=None)
            self.state["events"].append({"t": self.clock(), "text": text, "ok": False})
            del self.state["events"][:-MAX_EVENTS]
            self._refresh(self.clock(), keep_pct=True)
        self.stop()

    # ------------------------------------------------------------ ticker
    def start(self) -> "Progress":
        if self._thread is None:
            self._thread = threading.Thread(target=self._run, name="forge-progress", daemon=True)
            self._thread.start()
        return self

    def stop(self) -> None:
        self._stop.set()
        t = self._thread
        if t is not None and t is not threading.current_thread():
            t.join(timeout=2)

    def _run(self) -> None:
        while not self._stop.wait(TICK_S):
            self.tick()

    def __enter__(self) -> "Progress":
        return self.start()

    def __exit__(self, exc_type, exc, tb) -> None:
        if exc is not None and self.state["running"]:
            self.fail(exc)
        self.stop()

    # ------------------------------------------------------------ internals (lock held)
    def _fill(self, now: float) -> None:
        it = self.state["items"]
        left = it["total"] - it["done"] if it else 1
        while len(self._starts) < min(self._inflight, left):
            self._starts.append(now)

    def _pct(self, now: float) -> float:
        lo, hi = self.bands.get(self.state["phase"], (0, 100))
        it = self.state["items"]
        if it and it["total"] > 0:
            step = (hi - lo) / it["total"]
            left = it["total"] - it["done"]
            if left <= 0:
                return hi
            # 1 - e^-t never reaches 1: each in-flight item's creep stays below the step it would complete
            creep = sum(0.95 * step * (1 - math.exp(-(now - t) / self._est)) for t in self._starts[:left])
            return lo + step * it["done"] + creep
        return lo + 0.95 * (hi - lo) * (1 - math.exp(-(now - self._phase_t) / self._est))

    def _refresh(self, now: float, keep_pct: bool = False) -> None:
        s = self.state
        if not keep_pct:
            s["pct"] = max(int(s["pct"]), min(99, int(self._pct(now))))
            elapsed = now - s["started"]
            s["eta_s"] = int(elapsed * (100 - s["pct"]) / s["pct"]) if s["pct"] >= 5 else None
        s["updated"] = now
        self._write()

    def _write(self) -> None:
        tmp = self.path.with_name(f".{self.path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp.write_text(json.dumps(self.state, ensure_ascii=False), encoding="utf-8")
            os.replace(tmp, self.path)
        except OSError:  # a screen losing one update must never stop the build
            tmp.unlink(missing_ok=True)

