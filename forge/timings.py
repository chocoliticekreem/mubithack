"""Per-run timeline: stage timings and per-call latency, saved live to runs/<slug>/timings.json.

The format is the one `forge dashboard` reads (docs/ARCHITECTURE.md, dashboard.read_timings):
    {command, started, jobs, running, total_secs,
     stages:   [{name, start, end, secs, before_secs, parallel, start_s, end_s}],
     calls:    [{role, lane, lane_label, label, step, start, end, latency_ms, cached, ok, error,
                 request_id, start_s, end_s, secs}],
     speedups: [{stage, before_secs, after_secs}],
     by_role:  {role: {n, cached, sum_s, max_s}}, llm_busy_s, parallelism, history: [...]}
start/end are epoch seconds (end is null while a stage or call is still running, so the dashboard
shows it live); start_s/end_s are seconds since the command started. Concurrent calls of one role
get their own lane (coder-1, coder-2, ...). before_secs is the serial equivalent: the summed time of
the LLM calls inside the stage, i.e. how long the stage would take one call at a time.
parallelism = (sum of call seconds) / wall seconds. A later command on the same game replaces the
record and moves the old one's summary (no calls) into history.
"""

from __future__ import annotations

import contextlib
import json
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

SAVE_EVERY_S = 0.25  # live saves on call start/end are throttled; stage edges always save
HISTORY = 10


def _union(spans: list[tuple[float, float]]) -> float:
    total, cur_s, cur_e = 0.0, None, None
    for s, e in sorted(spans):
        if cur_e is None or s > cur_e:
            if cur_e is not None:
                total += cur_e - cur_s
            cur_s, cur_e = s, e
        else:
            cur_e = max(cur_e, e)
    return total + ((cur_e - cur_s) if cur_e is not None else 0.0)


class Timeline:
    def __init__(self, command: str, path: Path | None, jobs: int = 1):
        self.command = command
        self.path = path
        self.jobs = jobs
        self.started = datetime.now(timezone.utc).isoformat(timespec="seconds")
        self.t0 = time.monotonic()
        self.e0 = time.time()
        self.stages: list[dict] = []
        self.calls: list[dict] = []
        self.done = False
        self._lock = threading.RLock()
        self._busy: dict[str, set[int]] = {}  # role -> lane slots in use
        self._last_save = 0.0
        self._history: list | None = None

    def now(self) -> float:
        return round(time.monotonic() - self.t0, 3)

    def _epoch(self, rel: float) -> float:
        return round(self.e0 + rel, 3)

    # ---------------------------------------------------------- stages
    @contextlib.contextmanager
    def stage(self, name: str):
        start = self.now()
        st = {"name": name, "start": self._epoch(start), "end": None, "secs": None, "start_s": start, "end_s": None}
        with self._lock:
            self.stages.append(st)
        self.save(force=True)
        try:
            yield st
        finally:
            end = self.now()
            with self._lock:
                st.update(end=self._epoch(end), end_s=end, secs=round(end - start, 3))
                inside = [c for c in self.calls if c["end_s"] is not None
                          and c["start_s"] >= start - 0.01 and c["end_s"] <= end + 0.01]
                serial = round(sum(c["secs"] for c in inside), 3)
                if inside:
                    st["before_secs"] = max(serial, st["secs"])
                    st["parallel"] = self._peak(inside)
            self.save(force=True)

    @staticmethod
    def _peak(calls: list[dict]) -> int:
        ev = sorted([(c["start_s"], 1) for c in calls] + [(c["end_s"], -1) for c in calls], key=lambda x: (x[0], x[1]))
        cur = best = 0
        for _, d in ev:
            cur += d
            best = max(best, cur)
        return best

    # ---------------------------------------------------------- calls
    def start_call(self, role: str, label: str) -> dict:
        """A call begins running (on its worker thread): it takes the lowest free lane of its role."""
        start = self.now()
        with self._lock:
            busy = self._busy.setdefault(role, set())
            slot = next(i for i in range(1, len(busy) + 2) if i not in busy)
            busy.add(slot)
            c = {"role": role, "lane": f"{role}-{slot}", "lane_label": role if slot == 1 else f"{role} #{slot}",
                 "label": label, "step": label, "start": self._epoch(start), "end": None, "latency_ms": None,
                 "cached": False, "ok": None, "request_id": None, "start_s": start, "end_s": None, "secs": None,
                 "_slot": slot}
            self.calls.append(c)
        self.save()
        return c

    def end_call(self, c: dict, *, ok: bool, latency_ms: int | None = None, request_id: str | None = None,
                 cached: bool = False, n_calls: int = 1, error: str | None = None) -> None:
        end = self.now()
        with self._lock:
            c.update(end=self._epoch(end), end_s=end, secs=round(end - c["start_s"], 3), ok=ok,
                     latency_ms=latency_ms if latency_ms is not None else int((end - c["start_s"]) * 1000),
                     request_id=request_id, cached=cached, n_calls=n_calls)
            if error:
                c["error"] = error[:300]
            self._busy.get(c["role"], set()).discard(c.pop("_slot", 0))
        self.save()

    def add_call(self, *, role: str, label: str, start_s: float, end_s: float, ok: bool, **kw) -> None:
        """Record a finished call after the fact (start_s/end_s relative to the command start)."""
        c = {"role": role, "lane": f"{role}-1", "lane_label": role, "label": label, "step": label,
             "start": self._epoch(start_s), "end": self._epoch(end_s), "start_s": start_s, "end_s": end_s,
             "secs": round(end_s - start_s, 3), "ok": ok, "cached": bool(kw.get("cached")),
             "latency_ms": kw.get("latency_ms"), "request_id": kw.get("request_id")}
        with self._lock:
            self.calls.append(c)

    # ---------------------------------------------------------- summary / file
    def summary(self) -> dict:
        with self._lock:
            wall = self.now()
            calls = [{k: v for k, v in c.items() if not k.startswith("_")} for c in self.calls]
            stages = [dict(s) for s in self.stages]
        finished = [c for c in calls if c["end_s"] is not None]
        by_role: dict[str, dict] = {}
        for c in finished:
            r = by_role.setdefault(c["role"], {"n": 0, "cached": 0, "sum_s": 0.0, "max_s": 0.0})
            r["n"] += 1
            r["cached"] += int(bool(c.get("cached")))
            r["sum_s"] = round(r["sum_s"] + c["secs"], 3)
            r["max_s"] = max(r["max_s"], c["secs"])
        busy = round(sum(c["secs"] for c in finished), 3)
        union = _union([(c["start_s"], c["end_s"]) for c in finished])
        speedups = [{"stage": s["name"], "before_secs": s["before_secs"], "after_secs": s["secs"]}
                    for s in stages if s.get("before_secs") and s.get("secs") and s["before_secs"] > s["secs"] * 1.05]
        if busy - union > max(0.05, 0.02 * wall):  # one call at a time would add the overlapped seconds back
            speedups.append({"stage": "total", "before_secs": round(wall + busy - union, 2), "after_secs": round(wall, 2)})
        return {"command": self.command, "started": self.started, "jobs": self.jobs, "running": not self.done,
                "total_secs": round(wall, 3), "wall_s": round(wall, 3), "stages": stages, "calls": calls,
                "speedups": speedups, "by_role": by_role, "llm_busy_s": busy,
                "parallelism": round(busy / wall, 2) if wall > 0 else 0.0}

    def save(self, force: bool = False) -> dict | None:
        """Write the record to timings.json (throttled unless force). Never raises on a disk error."""
        if self.path is None:
            return self.summary() if force else None
        now = time.monotonic()
        with self._lock:
            if not force and now - self._last_save < SAVE_EVERY_S:
                return None
            self._last_save = now
            rec = self.summary()
            if self._history is None:  # the previous command's record becomes history (without its calls)
                self._history = []
                with contextlib.suppress(OSError, ValueError):
                    old = json.loads(self.path.read_text(encoding="utf-8"))
                    if isinstance(old, dict):
                        self._history = list(old.get("history") or [])
                        if old.get("stages") or old.get("calls"):
                            self._history.append({k: old.get(k) for k in (
                                "command", "started", "jobs", "total_secs", "llm_busy_s", "parallelism",
                                "by_role", "speedups") if k in old})
                        self._history = self._history[-HISTORY:]
            rec["history"] = self._history
            try:
                self.path.parent.mkdir(parents=True, exist_ok=True)
                tmp = self.path.with_suffix(f".{threading.get_ident()}.tmp")
                tmp.write_text(json.dumps(rec, indent=1), encoding="utf-8")
                tmp.replace(self.path)
            except OSError:
                pass
        return rec

    def finish(self) -> dict:
        self.done = True
        return self.save(force=True) or self.summary()
