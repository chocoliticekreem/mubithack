"""One evidence store per autopilot round, plus a cheap statistical pre-filter (forge/autopilot.py).

Every signal Forge has about a game version becomes an `Item` with a stable reference id that the Mubit
anomaly detector and gap finder must cite:

    err:<hash> / warn:<hash>   ForgeProbe errors and warnings (deduplicated by message)
    metric:<name>              a counter (or errors, instances, critic, fun, ...) over versions
    physics:<i>                ForgeProbe jitter / drift flags
    bridge:<i>                 live ForgeBridge events from Studio (errors, warnings, play state)
    test:<run>[#bugN]          AI tester sessions (QA protocol, persona lanes) and their bugs
    swarm:<run>[#i]            swarm reports (ranked bugs) with their screenshots
    stuck:<run>@<step>         a tester that stayed in one place / repeated one action (behaviour)
    untouched:<counter>        a counter the game declares that never moved (a feature nobody used)
    ttfr:<run>                 time to the first reward
    check:<id>                 executable check results
    score:critic|fun, census:latest, calls:<role>, report:<file>#<i>

`Measurement` is the shape of one version's numbers (`measure` in autopilot.py writes it). The pre-filter
compares the current measurement with the previous version and with the metric history (z-scores), so the
LLM only sees what moved, what never moved and what got worse.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

Z_LIMIT = 2.5          # |z| at or above this is a spike / drop
MIN_HISTORY = 3        # points before the latest one needed for a z-score
DROP_RATIO = 0.5       # a counter that fell by half or more vs the previous version
LEAK_GROWTH = 0.25     # instances grew by a quarter or more across one soak run, never falling
TTFR_SLOW_S = 60.0     # first reward later than this is slow
STUCK_STEPS = 3        # this many steps in one place (or one repeated action) = stuck
STUCK_STUDS = 3.0
MAX_CANDIDATES = 20

# reward words as whole name parts: "coins_collected" yes, "checkpoint_placement_fixed" no
REWARD_RX = re.compile(r"(?:^|_)(?:cash|coins?|money|rewards?|xp|earn(?:ed|s)?|collect(?:ed|s)?|gems?|points?|score|"
                       r"sold|paid|payouts?|loot)(?:_|$)", re.I)
PERF_RX = re.compile(r"over_budget|overrun|budget_exceeded|lag|slow|throttl|timeout", re.I)
SETUP_RX = re.compile(r"(^|_)(built|loaded|indexed|registered|parts|sites|graph|ms|rebuilt|init|ready)(_|$)", re.I)
# counters of bad events: 0 is the good value, so never "untouched", and falling to 0 is no regression
BAD_EVENT_RX = re.compile(r"fail|error|lost|afk|crash|reject|denied|died|death|kick_fail|net_dropped|exploit|"
                          r"desync|timeout|over_budget|overrun|stuck", re.I)
UNTOUCHED_SHOWN = 5    # more untouched counters than this are summarised in one candidate
DECLARED_RX = re.compile(r"""(?:ForgeTelemetry|Telemetry)\s*[.:]\s*count\(\s*["']([A-Za-z0-9_]+)["']""")
PASSIVE_ACTIONS = ("wait", "observe", "look", "report", "done", "idle", "screenshot")
# what the LLM reads first when the evidence does not fit its budget
KIND_ORDER = ("stat", "error", "bug", "stuck", "untouched", "ttfr", "physics", "bridge", "check", "score", "audit",
              "report", "qa", "test", "swarm", "warning", "census", "screenshot", "fix", "metric", "calls", "genre", "code")


def _clip(text: Any, n: int = 240) -> str:
    s = " ".join(str(text or "").split())
    return s if len(s) <= n else s[: n - 1] + "…"


def norm_error(msg: Any) -> str:
    """An error message without the numbers that change between runs (line numbers, ids, positions)."""
    return re.sub(r"\d+(\.\d+)?", "#", str(msg or "")).strip()


def _hash(text: str) -> str:
    return hashlib.sha1(norm_error(text).encode("utf-8", "replace")).hexdigest()[:6]


def _read(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def _num(v: Any) -> float | None:
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    return x if math.isfinite(x) else None


# ---------------------------------------------------------------- the store


@dataclass
class Item:
    id: str
    kind: str
    source: str
    text: str
    data: dict = field(default_factory=dict)


class EvidenceStore:
    """Items (id -> Item) and metric series (name -> [{label, value}]) for one round, saved as JSON."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = Path(path) if path else None
        self.items: dict[str, Item] = {}
        self.series: dict[str, list[dict]] = {}

    # -- items
    def add(self, ref: str, kind: str, source: str, text: str, **data: Any) -> str:
        if ref in self.items:  # same signal from two sources: keep the first, note the second
            self.items[ref].data.setdefault("also", []).append(source)
            return ref
        self.items[ref] = Item(ref, kind, source, _clip(text, 400), data)
        return ref

    def refs(self) -> dict[str, str]:
        return {i.id: i.text for i in self.items.values()}

    def of_kind(self, *kinds: str) -> list[Item]:
        return [i for i in self.items.values() if i.kind in kinds]

    def counts(self) -> dict[str, int]:
        out: dict[str, int] = {}
        for i in self.items.values():
            out[i.kind] = out.get(i.kind, 0) + 1
        return dict(sorted(out.items()))

    # -- series
    def point(self, metric: str, label: str, value: Any) -> None:
        x = _num(value)
        if x is None:
            return
        pts = self.series.setdefault(metric, [])
        pts[:] = [p for p in pts if p["label"] != label]
        pts.append({"label": label, "value": x})

    def values(self, metric: str) -> list[float]:
        return [p["value"] for p in self.series.get(metric) or []]

    # -- persistence + rendering
    def to_dict(self) -> dict:
        return {"items": [asdict(i) for i in self.items.values()], "series": self.series, "counts": self.counts()}

    def save(self, path: Path | None = None) -> Path:
        p = Path(path or self.path)  # type: ignore[arg-type]
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.to_dict(), indent=1, ensure_ascii=False, default=str), encoding="utf-8")
        tmp.replace(p)
        return p

    @classmethod
    def load(cls, path: Path) -> "EvidenceStore":
        st = cls(path)
        raw = _read(path, {}) or {}
        for i in raw.get("items") or []:
            st.items[i["id"]] = Item(i["id"], i.get("kind", ""), i.get("source", ""), i.get("text", ""),
                                     i.get("data") or {})
        st.series = {k: list(v) for k, v in (raw.get("series") or {}).items()}
        return st

    def render(self, budget: int = 12_000, kinds: tuple[str, ...] | None = None) -> str:
        groups: dict[str, list[Item]] = {}
        for i in self.items.values():
            if kinds is None or i.kind in kinds:
                groups.setdefault(i.kind, []).append(i)
        out: list[str] = []
        used = 0
        order = {k: i for i, k in enumerate(KIND_ORDER)}
        for kind, items in sorted(groups.items(), key=lambda kv: order.get(kv[0], len(order))):
            head = f"### {kind} ({len(items)})"
            if used + len(head) > budget:
                break
            out.append(head)
            used += len(head) + 1
            for i in items:
                ln = f"- [{i.id}] {i.text}"
                if used + len(ln) + 1 > budget:
                    out.append("- (more omitted)")
                    return "\n".join(out)
                out.append(ln)
                used += len(ln) + 1
        return "\n".join(out)


# ---------------------------------------------------------------- measurements and collectors


def measurement_from_probe(report: dict, *, label: str, version: str | None = None, **extra: Any) -> dict:
    """A ForgeProbe report (Studio or headless) -> the Measurement shape the pre-filter compares."""
    report = report if isinstance(report, dict) else {}
    errs = []
    for e in report.get("errors") or []:
        if isinstance(e, dict):
            errs.append({"message": _clip(e.get("message"), 300), "script": e.get("script")})
        elif e:
            errs.append({"message": _clip(e, 300), "script": None})
    phys = report.get("physics") if isinstance(report.get("physics"), dict) else {}
    return {"label": label, "version": version, "counters": dict(report.get("counters") or {}),
            "errors": errs, "warnings": [_clip(w, 300) for w in report.get("warnings") or []],
            "instances": report.get("instances"), "players": report.get("players"),
            "physics": {"flagged": list(phys.get("flagged") or []), "watched": phys.get("watched")},
            "census": report.get("census") or {}, **extra}


def add_measurement(st: EvidenceStore, m: dict, *, source: str) -> None:
    """Errors, warnings, physics flags and counters of one measurement -> items + series points."""
    label = m.get("label") or source
    for e in m.get("errors") or []:
        msg = str(e.get("message") or "")
        st.add(f"err:{_hash(msg)}", "error", source, f"{e.get('script') or '?'}: {msg}", label=label,
               script=e.get("script"))
    warns: dict[str, int] = {}
    for w in m.get("warnings") or []:
        warns[str(w)] = warns.get(str(w), 0) + 1
    for w, n in list(warns.items())[:12]:
        st.add(f"warn:{_hash(w)}", "warning", source, f"{w}" + (f" (x{n})" if n > 1 else ""), label=label)
    for i, f in enumerate((m.get("physics") or {}).get("flagged") or [], 1):
        if isinstance(f, dict):
            st.add(f"physics:{label}#{i}", "physics", source,
                   f"{f.get('kind')} {f.get('path') or f.get('model')}: max speed {f.get('max_speed')}, "
                   f"max angvel {f.get('max_angvel')}, moved {f.get('moved_studs')} studs", label=label)
    st.point("errors", label, len(m.get("errors") or []))
    st.point("warnings", label, len(m.get("warnings") or []))
    st.point("physics_flagged", label, len((m.get("physics") or {}).get("flagged") or []))
    if m.get("instances") is not None:
        st.point("instances", label, m["instances"])
    for k, v in (m.get("counters") or {}).items():
        st.point(f"counter:{k}", label, v)
    for key in ("critic", "fun", "boot_errors", "checks_pass", "checks_fail", "swarm_high", "ttfr_s"):
        if m.get(key) is not None:
            st.point(key, label, m[key])
    census = m.get("census") or {}
    if census:
        st.add("census:latest", "census", source, ", ".join(f"{k} {v}" for k, v in list(census.items())[:14]
                                                             if not isinstance(v, (dict, list))), label=label)


def history(run_dir: Path) -> list[dict]:
    """Earlier versions' measurements, oldest first: build iterations and fix-cycle rounds."""
    out: list[tuple[float, dict]] = []
    its = run_dir / "iterations"
    for p in its.glob("*/report.json") if its.is_dir() else []:
        if not p.parent.name.isdigit():
            continue
        rep = _read(p, {}) or {}
        if str(rep.get("source") or "").startswith("autopilot"):
            continue  # autopilot measurements come from autopilot/rounds (kept versions only)
        crit = _read(p.parent / "critique.json", {}) or {}
        m = measurement_from_probe(rep, label=f"it{p.parent.name}", critic=_num(crit.get("score")),
                                   fun=_num(((crit.get("fun") or {}) if isinstance(crit.get("fun"), dict)
                                             else {}).get("score")))
        out.append((round(p.stat().st_mtime, -1), 0, int(p.parent.name), 0, m))
    for p in (run_dir / "improve").glob("[0-9]*.json") if (run_dir / "improve").is_dir() else []:
        cyc = _read(p, {}) or {}
        for d in cyc.get("before") or []:
            if not isinstance(d, dict):
                continue
            errs = d.get("errors") or {}
            first = errs.get("first") if isinstance(errs, dict) else errs
            m = {"label": f"cycle{p.stem}.{d.get('round', 1)}", "counters": dict(d.get("counters") or {}),
                 "errors": [{"message": _clip(e if not isinstance(e, dict) else e.get("message"), 300)}
                            for e in (first or [])],
                 "warnings": [], "physics": {"flagged": []}}
            if isinstance(errs, dict) and errs.get("count") and not m["errors"]:
                m["errors"] = [{"message": "error"}] * int(errs["count"])
            out.append((round(p.stat().st_mtime, -1), 1, int(p.stem), int(d.get("round") or 1), m))
    return [t[-1] for t in sorted(out, key=lambda t: t[:4])]


def declared_counters(sources: dict[str, str], spec: dict | None = None) -> list[str]:
    """Counters the game says it bumps (ForgeTelemetry.count("x") in code, director beats in the spec)."""
    names: list[str] = []
    for text in sources.values():
        names += DECLARED_RX.findall(text)
    for b in (spec or {}).get("first_60s") or []:
        if isinstance(b, dict) and b.get("counter"):
            names.append(str(b["counter"]))
    return list(dict.fromkeys(names))


def stuck_spans(steps: list[dict], *, studs: float = STUCK_STUDS, min_steps: int = STUCK_STEPS) -> list[dict]:
    """Where a tester got stuck: >= min_steps active steps within `studs` of one spot, or one action
    repeated with the same result. steps: [{n, tester?, action: {action, args} | str, result, pos?}]."""
    by: dict[str, list[dict]] = {}
    for s in steps or []:
        if isinstance(s, dict):
            by.setdefault(str(s.get("tester") or s.get("persona") or "tester"), []).append(s)
    out = []
    for tester, ss in by.items():
        run: list[dict] = []

        def flush() -> None:
            if len(run) >= min_steps:
                a = run[0].get("action")
                out.append({"tester": tester, "from": run[0].get("n"), "to": run[-1].get("n"), "steps": len(run),
                            "pos": run[0].get("pos"), "action": a.get("action") if isinstance(a, dict) else a,
                            "result": _clip(run[-1].get("result"), 160)})

        for s in ss:
            a = s.get("action")
            name = str((a.get("action") if isinstance(a, dict) else a) or "").lower()
            if not name or any(name.startswith(p) for p in PASSIVE_ACTIONS):
                flush()
                run = []
                continue
            if run and _same_spot(run[0], s, studs):
                run.append(s)
                continue
            flush()
            run = [s]
        flush()
    return out


def _same_spot(a: dict, b: dict, studs: float) -> bool:
    pa, pb = _pos(a.get("pos")), _pos(b.get("pos"))
    if pa and pb:
        return math.dist(pa, pb) <= studs
    act_a, act_b = a.get("action"), b.get("action")  # no positions: the same action with the same result
    return json.dumps(act_a, sort_keys=True, default=str) == json.dumps(act_b, sort_keys=True, default=str) \
        and _clip(a.get("result"), 80) == _clip(b.get("result"), 80)


def _pos(p: Any) -> tuple[float, ...] | None:
    if isinstance(p, dict):
        p = [p.get("x"), p.get("y"), p.get("z")]
    if isinstance(p, (list, tuple)) and len(p) >= 3:
        xs = [_num(v) for v in p[:3]]
        if all(x is not None for x in xs):
            return tuple(xs)  # type: ignore[arg-type]
    return None


def first_reward(soak: list[dict]) -> float | None:
    """Seconds until any reward-like counter first went above zero in a soak series (None: never)."""
    for s in soak or []:
        for k, v in (s.get("counters") or {}).items() if isinstance(s.get("counters"), dict) else []:
            if REWARD_RX.search(k) and (_num(v) or 0) > 0:
                return _num(s.get("t")) or 0.0
    return None


def add_tests(st: EvidenceStore, run_dir: Path, *, since: float = 0.0, until: float | None = None,
              limit: int = 6) -> list[dict]:
    """AI tester runs under runs/<slug>/tests/<run>/report.json (QA protocol + swarm persona lanes)."""
    reps = []
    tests = run_dir / "tests"
    for p in tests.glob("*/report.json") if tests.is_dir() else []:
        if p.stat().st_mtime >= since and (until is None or p.stat().st_mtime <= until):
            reps.append(p)
    reps.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    stuck_all: list[dict] = []
    for p in reps[:limit]:
        rep = _read(p, {}) or {}
        rid = p.parent.name
        kind = "qa" if rep.get("kind") == "protocol" else "test"
        shots = sorted(x.name for x in p.parent.glob("*.png"))
        st.add(f"test:{rid}", kind, "tests", f"{rep.get('tester') or rep.get('kind') or 'tester'} goal "
               f"\"{_clip(rep.get('goal'), 100)}\": goal_met={rep.get('goal_met')}, {len(rep.get('steps') or [])} "
               f"steps, {len(shots)} screenshots. {_clip(rep.get('summary'), 220)}", run=rid, shots=shots[:6])
        for i, b in enumerate((rep.get("bugs") or [])[:5], 1):
            if isinstance(b, dict):
                st.add(f"test:{rid}#bug{i}", "bug", "tests", f"[{b.get('severity')}] {_clip(b.get('title'), 120)}: "
                       f"{_clip(b.get('evidence') or b.get('actual'), 180)}", run=rid, severity=b.get("severity"))
        for sp in stuck_spans(rep.get("steps") or []):
            stuck_all.append({**sp, "run": rid})
            st.add(f"stuck:{rid}@{sp['from']}", "stuck", "tests",
                   f"{sp['tester']} stuck for {sp['steps']} steps (steps {sp['from']}-{sp['to']}) doing "
                   f"{sp['action']} near {sp['pos']}: last result {sp['result']}", run=rid)
    return stuck_all


def add_swarm(st: EvidenceStore, playtests_dir: Path, slug: str, *, since: float = 0.0, until: float | None = None,
              limit: int = 3) -> list[dict]:
    """Swarm reports (runs/playtests/<run>/report.json, kind swarm) for this game: ranked bugs, soak, stuck."""
    found = []
    for p in playtests_dir.glob("*/report.json") if playtests_dir.is_dir() else []:
        if p.stat().st_mtime < since or (until is not None and p.stat().st_mtime > until):
            continue
        rep = _read(p, {}) or {}
        if rep.get("kind") == "swarm" and (not slug or rep.get("slug") == slug):
            found.append((p.stat().st_mtime, p.parent.name, rep))
    found.sort(reverse=True)
    stuck_all: list[dict] = []
    for _, rid, rep in found[:limit]:
        bugs = [b for b in rep.get("bugs") or [] if isinstance(b, dict)]
        st.add(f"swarm:{rid}", "swarm", "swarm", f"{len(rep.get('testers') or [])} testers, {len(bugs)} bug groups: "
               f"{_clip(rep.get('summary'), 220)}", run=rid, shots=[s.get("path") if isinstance(s, dict) else s
                                                                    for s in (rep.get("shots") or [])][:6])
        for i, b in enumerate(bugs[:6], 1):
            st.add(f"swarm:{rid}#{i}", "bug", "swarm", f"[{b.get('severity')} x{b.get('frequency')} testers"
                   f"{', bots only' if b.get('only_bots') else ''}] {_clip(b.get('title'), 120)}: "
                   f"{_clip(b.get('evidence'), 180)}", run=rid, severity=b.get("severity"), real=b.get("real"))
        for sp in stuck_spans(rep.get("steps") or []):
            stuck_all.append({**sp, "run": rid})
            st.add(f"stuck:{rid}@{sp['tester']}:{sp['from']}", "stuck", "swarm",
                   f"{sp['tester']} stuck for {sp['steps']} steps ({sp['from']}-{sp['to']}) doing {sp['action']} "
                   f"near {sp['pos']}: {sp['result']}", run=rid)
        soak = [s for s in rep.get("soak") or [] if isinstance(s, dict)]
        for s in soak:
            for k, v in (s.get("counters") or {}).items() if isinstance(s.get("counters"), dict) else []:
                st.point(f"soak:{k}", f"t{s.get('t')}", v)
            if s.get("instances") is not None:
                st.point("soak:instances", f"t{s.get('t')}", s["instances"])
            if s.get("errors") is not None:
                st.point("soak:errors", f"t{s.get('t')}", s["errors"])
        t = first_reward(soak)
        if soak:
            st.add(f"ttfr:{rid}", "ttfr", "swarm", "first reward after " + (f"{t:g} s" if t is not None else
                   f"never (in {soak[-1].get('t')} s of play)"), run=rid, seconds=t)
    return stuck_all


def add_checks(st: EvidenceStore, run_dir: Path) -> dict:
    res = _read(run_dir / "checks" / "results.json")
    if isinstance(res, dict):
        res = res.get("results")
    rows = [r for r in res or [] if isinstance(r, dict) and r.get("verdict") != "dropped"]
    for r in rows[:24]:
        st.add(f"check:{r.get('id')}", "check", "checks", f"{'PASS' if r.get('ok') else 'FAIL'} "
               f"{_clip(r.get('title'), 90)}" + ("" if r.get("ok") else f": {_clip(r.get('detail'), 160)}"),
               ok=bool(r.get("ok")))
    return {"pass": sum(1 for r in rows if r.get("ok")), "fail": sum(1 for r in rows if not r.get("ok")),
            "passing": [r.get("id") for r in rows if r.get("ok")], "failing": [r.get("id") for r in rows if not r.get("ok")]}


def add_calls(st: EvidenceStore, run_dir: Path) -> None:
    """Mubit call health per role from every calls.jsonl under the run (count, failures, median latency)."""
    by: dict[str, list[dict]] = {}
    for p in run_dir.rglob("calls.jsonl"):
        try:
            lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for ln in lines:
            try:
                c = json.loads(ln)
            except ValueError:
                continue
            if isinstance(c, dict):
                by.setdefault(str(c.get("role") or "?"), []).append(c)
    for role, cs in sorted(by.items(), key=lambda kv: -len(kv[1])):
        lat = sorted(int(c.get("latency_ms") or 0) for c in cs)
        bad = sum(1 for c in cs if c.get("error"))
        st.add(f"calls:{role}", "calls", "calls.jsonl", f"{role}: {len(cs)} calls, {bad} failed, median "
               f"{lat[len(lat) // 2] if lat else 0} ms", calls=len(cs), failed=bad)


def add_bridge(st: EvidenceStore, events: list[dict], *, place: str | None = None, limit: int = 12) -> dict:
    """Live ForgeBridge events (forge/bridge.py ring): errors and warnings from Studio, play starts/stops."""
    evs = [e for e in events or [] if isinstance(e, dict)]
    if place:  # log/error events carry no place: attribute them to our place's play windows (approximate)
        windows: list[list[float]] = []
        for e in evs:
            if e.get("type") == "play" and place in str(e.get("place")):
                t = float(e.get("time") or 0)
                if e.get("state") == "started":
                    windows.append([t, float("inf")])
                elif windows and windows[-1][1] == float("inf"):
                    windows[-1][1] = t
        evs = [e for e in evs if place in str(e.get("place") or "") or (
            not e.get("place") and e.get("type") in ("log", "error")
            and any(a <= float(e.get("time") or 0) <= b for a, b in windows))]
    counts: dict[str, int] = {}
    shown = 0
    seen: set[str] = set()
    for e in evs:
        t = str(e.get("type") or "?")
        kind = str(e.get("kind") or "")
        key = t + ("/" + kind if kind else "")
        counts[key] = counts.get(key, 0) + 1
        msg = str(e.get("message") or "")
        if (t == "error" or kind in ("warning", "error")) and msg and msg not in seen and shown < limit:
            seen.add(msg)
            shown += 1
            st.add(f"bridge:{e.get('seq', shown)}", "bridge", "forgebridge", f"[{e.get('dm')}] {key}: {msg}")
    if evs:
        st.add("bridge:summary", "bridge", "forgebridge", ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    return counts


def bridge_events(port: int | None = None, place: str | None = None) -> list[dict]:
    """Events from a running ForgeBridge (empty when no bridge runs). Never raises."""
    try:
        from forge.bridge import BridgeClient, DEFAULT_PORT
        c = BridgeClient(port or DEFAULT_PORT, timeout=2.0)
        if not c.health():
            return []
        return list((c.events(0, None, 500, 0) or {}).get("events") or [])
    except Exception:  # noqa: BLE001
        return []


# ---------------------------------------------------------------- the statistical pre-filter


def zscore(values: list[float]) -> float | None:
    """z of the last value against the ones before it (None with too little history). The spread has a
    floor (10% of the mean, at least 1) so a perfectly flat history does not make every wiggle infinite."""
    if len(values) < MIN_HISTORY + 1:
        return None
    hist, last = values[:-1], values[-1]
    mean = sum(hist) / len(hist)
    sd = math.sqrt(sum((x - mean) ** 2 for x in hist) / len(hist))
    sd = max(sd, 0.1 * abs(mean), 1.0)
    return round((last - mean) / sd, 2)


def _cand(kind: str, metric: str, severity: str, text: str, evidence: list[str], **data: Any) -> dict:
    return {"id": f"stat:{kind}:{metric}" if metric else f"stat:{kind}", "kind": kind, "metric": metric,
            "severity": severity, "text": text, "evidence": [e for e in evidence if e], **data}


def prefilter(current: dict, previous: dict | None, st: EvidenceStore, *, declared: list[str] | None = None,
              stuck: list[dict] | None = None, ttfr: float | None = None, ttfr_known: bool = False,
              max_candidates: int = MAX_CANDIDATES) -> list[dict]:
    """Cheap, deterministic anomaly candidates for the LLM (most severe first):
    error_spike, regression (vs the previous version), spike/drop (z-score vs history), flat (an expected
    counter that never moved), leak (instances only grow), perf (over-budget counters), physics, stuck
    (testers), untouched (declared counters at zero), ttfr (first reward slow or never)."""
    out: list[dict] = []
    cur_c = {k: _num(v) or 0.0 for k, v in (current.get("counters") or {}).items()}
    prev_c = {k: _num(v) or 0.0 for k, v in ((previous or {}).get("counters") or {}).items()}
    label = current.get("label") or "now"

    # errors: anything new vs the previous version, or more of them
    cur_err = {norm_error(e.get("message")) for e in current.get("errors") or []}
    prev_err = {norm_error(e.get("message")) for e in (previous or {}).get("errors") or []}
    new_err = sorted(cur_err - prev_err)
    if new_err or len(current.get("errors") or []) > len((previous or {}).get("errors") or []):
        out.append(_cand("error_spike", "", "high", f"{len(current.get('errors') or [])} errors now vs "
                         f"{len((previous or {}).get('errors') or [])} in the previous version; "
                         f"{len(new_err)} new: {_clip('; '.join(new_err), 300)}",
                         ["metric:errors"] + [f"err:{_hash(m)}" for m in new_err[:4]],
                         value=len(current.get("errors") or []), baseline=len((previous or {}).get("errors") or [])))
    elif cur_err:
        out.append(_cand("errors", "", "medium", f"{len(cur_err)} distinct errors still fire (not new)",
                         [f"err:{_hash(m)}" for m in sorted(cur_err)[:4]], value=len(cur_err)))

    # regressions vs the previous version
    if previous:
        for k, before in prev_c.items():
            now = cur_c.get(k, 0.0)
            if BAD_EVENT_RX.search(k):
                continue
            if before > 0 and now == 0 and not SETUP_RX.search(k):
                out.append(_cand("regression", k, "high", f"{k} was {before:g} in the previous version, now 0",
                                 [f"metric:counter:{k}"], value=now, baseline=before))
            elif before >= 4 and now <= before * (1 - DROP_RATIO) and not SETUP_RX.search(k) and not PERF_RX.search(k):
                out.append(_cand("regression", k, "medium", f"{k} fell {before:g} -> {now:g} vs the previous version",
                                 [f"metric:counter:{k}"], value=now, baseline=before))
        for key, name in (("critic", "critic score"), ("fun", "fun score")):
            a, b = _num((previous or {}).get(key)), _num(current.get(key))
            if a is not None and b is not None and b <= a - 1.0:
                out.append(_cand("regression", key, "high", f"{name} fell {a:g} -> {b:g}", [f"score:{key}"],
                                 value=b, baseline=a))
        lost = sorted(set(((previous or {}).get("checks") or {}).get("passing") or [])
                      & set((current.get("checks") or {}).get("failing") or []))
        if lost:
            out.append(_cand("regression", "checks", "high", f"checks passing before now fail: {', '.join(lost[:6])}",
                             [f"check:{c}" for c in lost[:6]], value=len(lost)))

    # z-scores of each counter against its history (the latest point is the current version)
    for metric, pts in st.series.items():
        if not metric.startswith("counter:") and metric not in ("errors", "warnings", "instances", "physics_flagged"):
            continue
        vals = [p["value"] for p in pts]
        if not pts or pts[-1]["label"] != label:
            continue
        z = zscore(vals)
        name = metric.split(":", 1)[-1]
        if z is not None and abs(z) >= Z_LIMIT and not SETUP_RX.search(name):
            bad = z > 0 if (PERF_RX.search(name) or metric in ("errors", "warnings", "instances", "physics_flagged")) else z < 0
            out.append(_cand("spike" if z > 0 else "drop", name, "high" if bad else "low",
                             f"{name} = {vals[-1]:g}, z {z:+g} vs {len(vals) - 1} earlier versions "
                             f"(mean {sum(vals[:-1]) / (len(vals) - 1):.3g})", [f"metric:{metric}"],
                             value=vals[-1], z=z, bad=bad))

    # performance counters that fire at all
    for k, v in cur_c.items():
        if PERF_RX.search(k) and v > 0:
            before = prev_c.get(k)
            sev = "high" if before is not None and v > before * 1.5 + 1 else "medium"
            out.append(_cand("perf", k, sev, f"{k} = {v:g}" + (f" (was {before:g})" if before is not None else ""),
                             [f"metric:counter:{k}"], value=v, baseline=before))

    # instance leak across the soak run: grew by a quarter and never fell
    inst = st.values("soak:instances")
    if len(inst) >= 3 and inst[0] > 0 and inst[-1] >= inst[0] * (1 + LEAK_GROWTH) \
            and all(b >= a for a, b in zip(inst, inst[1:])):
        out.append(_cand("leak", "instances", "medium", f"instances only grew during play: {inst[0]:g} -> {inst[-1]:g} "
                         f"over {len(inst)} samples", ["metric:soak:instances"], value=inst[-1], baseline=inst[0]))

    flagged = (current.get("physics") or {}).get("flagged") or []
    if flagged:
        out.append(_cand("physics", "", "medium", f"{len(flagged)} assemblies flagged for jitter/drift",
                         [f"physics:{label}#{i}" for i in range(1, min(len(flagged), 4) + 1)], value=len(flagged)))

    # flat / untouched: counters the game declares that never moved
    soak_moved = {m.split(":", 1)[1] for m, pts in st.series.items() if m.startswith("soak:")
                  and len({p["value"] for p in pts}) > 1}
    quiet: list[dict] = []
    for k in declared or []:
        if cur_c.get(k, 0.0) == 0 and k not in soak_moved and not SETUP_RX.search(k) and not BAD_EVENT_RX.search(k):
            moved_before = any(v > 0 for v in st.values(f"counter:{k}")[:-1])
            kind = "flat" if moved_before else "untouched"
            quiet.append(_cand(kind, k, "high" if (REWARD_RX.search(k) or moved_before) else "medium",
                               f"{k} is declared by the game but stayed 0 this version"
                               + (" (it moved in an earlier version)" if moved_before else " (no tester or player ever "
                                                                                           "triggered it)"),
                               [f"metric:counter:{k}", f"untouched:{k}"], value=0))
    quiet.sort(key=lambda c: (c["kind"] != "flat", c["severity"] != "high"))
    out += quiet[:UNTOUCHED_SHOWN]
    if len(quiet) > UNTOUCHED_SHOWN:
        rest = quiet[UNTOUCHED_SHOWN:]
        out.append(_cand("untouched", f"+{len(rest)}", "medium", f"{len(rest)} more declared counters never moved: "
                         + ", ".join(c["metric"] for c in rest[:30]), [f"untouched:{c['metric']}" for c in rest[:6]],
                         value=len(rest)))

    for sp in stuck or []:
        out.append(_cand("stuck", f"{sp.get('run')}@{sp.get('from')}", "medium",
                         f"{sp.get('tester')} stuck for {sp.get('steps')} steps doing {sp.get('action')} near "
                         f"{sp.get('pos')}", [f"stuck:{sp.get('run')}@{sp.get('from')}",
                                              f"stuck:{sp.get('run')}@{sp.get('tester')}:{sp.get('from')}"]))
    if ttfr_known and (ttfr is None or ttfr > TTFR_SLOW_S):
        out.append(_cand("ttfr", "", "high" if ttfr is None else "medium",
                         "no reward in the whole play session" if ttfr is None else f"first reward after {ttfr:g} s",
                         [i.id for i in st.of_kind("ttfr")][:2], value=ttfr))

    known = set(st.items) | {f"metric:{m}" for m in st.series}
    for c in out:  # cite only ids that exist (a hashed err id always exists when it came from this store)
        c["evidence"] = [e for e in c["evidence"] if e in known] or c["evidence"][:1]
    rank = {"high": 0, "medium": 1, "low": 2}
    out.sort(key=lambda c: (rank.get(c["severity"], 3), -abs(c.get("z") or 0)))
    seen: set[str] = set()
    uniq = []
    for c in out:
        if c["id"] not in seen:
            seen.add(c["id"])
            uniq.append(c)
    return uniq[:max_candidates]


def metric_items(st: EvidenceStore, names: list[str] | None = None, limit: int = 30) -> None:
    """A citable `metric:<name>` item per series (values per version), for the metrics the LLM needs."""
    for metric, pts in list(st.series.items()):
        if names is not None and metric not in names:
            continue
        if f"metric:{metric}" in st.items:
            continue
        if len([i for i in st.items if i.startswith("metric:")]) >= limit:
            break
        st.add(f"metric:{metric}", "metric", "series", f"{metric}: " + ", ".join(
            f"{p['label']}={p['value']:g}" for p in pts[-8:]))
