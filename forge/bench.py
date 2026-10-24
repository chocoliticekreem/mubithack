"""`forge bench`: a fixed suite of small game ideas, built end to end, measured the same way every time.

It answers "did Forge get faster and smarter?" with numbers (docs/BENCH.md):

    forge bench --fake                         # cheap: FakeLLM, no Studio (CI)
    forge bench --ideas tycoon,obby -n 2       # real: every LLM call through Mubit, compile-only
    forge bench --studio Forge-agents-29       # real + a Studio playtest in that window
    forge bench --compare A B                  # deltas between two saved results

Each idea runs `forge.loop.new_game` (designer -> coders -> iterations of compile/fix, playtest,
critic, fixer, reflector), then optionally `improve.run_cycle(fix=True)` cycles (Studio only), then
`forge done`. Bench never changes how a game is built: it times the stages by wrapping `loop.Run`
methods for the duration of the run, and reads every other number from the run's own records
(calls.jsonl, iteration records, critique.json, checks/results.json, improve/scores.json, state.json).

Every idea gets its own runs dir, runs/bench/<stamp>/<idea>/, so ideas don't share lessons and
results never mix with real games. Results: runs/bench/<stamp>.json and runs/bench/<stamp>.md.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import dataclasses
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from forge.config import Settings, load_settings
from forge.memory import STARTER_LESSONS, slugify

SCHEMA = 1

SUITE: list[dict] = [
    {"id": "tycoon",
     "idea": "A tiny tycoon: a dropper spawns cubes, a conveyor carries them to a collector that pays cash, "
             "and players buy a second dropper and a faster conveyor with that cash."},
    {"id": "obby",
     "idea": "A short obby: eight platforms with gaps, two lava strips and one moving platform, checkpoints "
             "that respawn you, and a finish pad that shows your time."},
    {"id": "minigame",
     "idea": "A round-based minigame: a lobby with an intermission countdown, then a 60 second round where "
             "floor tiles fall a few seconds after being stepped on; the last players standing win a point."},
    {"id": "simulator",
     "idea": "A clicking simulator: click to gain strength, sell strength on a pad for coins, and buy "
             "heavier weights that multiply strength per click."},
    {"id": "defence",
     "idea": "A co-op tower defence: waves of enemies walk a path toward the base, players earn coins from "
             "kills and place turrets beside the path, and the base has health that ends the game at zero."},
]
SUITE_IDS = [s["id"] for s in SUITE]


def bench_dir(settings: Settings) -> Path:
    return settings.runs_dir / "bench"


def stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _git(settings: Settings, *args: str) -> str | None:
    try:
        out = subprocess.run(["git", *args], cwd=settings.repo_root, capture_output=True, text=True, timeout=10)
        return out.stdout.strip() or None if out.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def _read(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _lines(path: Path) -> list[dict]:
    out = []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return out
    for ln in text.splitlines():
        with contextlib.suppress(ValueError):
            if ln.strip():
                out.append(json.loads(ln))
    return out


# ================================================================ cheap mode

def fake_reply(role: str, user: str) -> str:
    """FakeLLM replies for the cheap mode: the stock offline replies, except that the first coder reply
    for a server script does not compile, so the compile-check -> fixer path and the first-try metric
    are exercised without spending a token."""
    from forge.llm import fake_default_reply

    if role == "coder" and re.search(r"^path:\s*\S+\.server\.luau", user, re.MULTILINE):
        return "```luau\nlocal broken = \n```"
    if role == "critic":
        return json.dumps({"score": 6, "fun": 5, "summary": "fake critique", "issues": [], "done": False})
    if role in ("auditor", "verifier", "triage", "investigator", "patcher", "planner", "player", "judge"):
        raise RuntimeError(f"cheap bench has no fake reply for {role!r}")
    return fake_default_reply(role, user)


# ================================================================ stage timing

@contextlib.contextmanager
def instrument(rec: dict):
    """Time loop.Run stages for one idea by wrapping its methods, and run one compile check right after
    the first build (the first-try compile metric). Restores the originals on exit. A method that no
    longer exists is simply not timed."""
    from forge import loop

    stages = rec.setdefault("stages", {})
    marks = rec.setdefault("marks", {})
    saved: dict[str, Any] = {}

    def wrap(name: str, key: str, after: Callable[[Any], None] | None = None) -> None:
        fn = getattr(loop.Run, name, None)
        if fn is None or not asyncio.iscoroutinefunction(fn):
            return
        saved[name] = fn

        async def timed(self, *a, **k):
            t0 = time.monotonic()
            marks.setdefault(f"{key}_start", t0)
            try:
                return await fn(self, *a, **k)
            finally:
                stages[key] = round(stages.get(key, 0.0) + time.monotonic() - t0, 2)
                if after is not None:
                    after(self)

        setattr(loop.Run, name, timed)

    def first_check(run: Any) -> None:
        if "compile_first" in rec:
            return
        t0 = time.monotonic()
        modules = [m["path"] for m in (run.spec.get("modules") or []) if isinstance(m, dict) and m.get("path")]
        written = [p for p in modules if (run.game_dir / p).exists()]
        try:
            errors = run.check()
        except Exception as e:  # no luau-compile: unknown, not a pass
            rec["compile_first"] = {"modules": len(modules), "written": len(written), "failing": None,
                                    "pass_rate": None, "error": str(e)[:200]}
            return
        failing = sorted({p for p, _ in errors if p in modules})
        # the build compiles and fixes each module as it is written (pipelined): use its first-try results
        first = getattr(run, "compile_first", None) or {}
        if first:
            failing = sorted(set(failing) | {p for p, err in first.items() if err and p in modules})
        missing = len(modules) - len(written)
        ok = len(modules) - len(failing) - missing
        rec["compile_first"] = {"modules": len(modules), "written": len(written), "failing": failing,
                                "pass_rate": round(ok / len(modules), 3) if modules else None}
        rec.setdefault("overhead_s", 0.0)
        rec["overhead_s"] = round(rec["overhead_s"] + time.monotonic() - t0, 2)

    wrap("build_all", "build", after=first_check)
    wrap("iterate", "iterate")
    wrap("compile_fix", "compile_fix")
    wrap("playtest", "playtest")
    try:
        yield rec
    finally:
        for name, fn in saved.items():
            setattr(loop.Run, name, fn)


# ================================================================ metrics from a run's records

def llm_stats(run_dir: Path) -> dict:
    calls = []
    for path in sorted(run_dir.rglob("calls.jsonl")):
        calls += _lines(path)
    by_role: dict[str, int] = {}
    for c in calls:
        by_role[str(c.get("role"))] = by_role.get(str(c.get("role")), 0) + 1
    return {
        "calls": len(calls),
        "input_tokens": sum(int(c.get("input_tokens") or 0) for c in calls),
        "output_tokens": sum(int(c.get("output_tokens") or 0) for c in calls),
        "latency_s": round(sum(int(c.get("latency_ms") or 0) for c in calls) / 1000, 1),
        "by_role": dict(sorted(by_role.items())),
        "request_ids": [c.get("request_id") for c in calls if c.get("request_id")],
    }


def _iteration_records(run_dir: Path) -> list[dict]:
    its = run_dir / "iterations"
    out = []
    if its.is_dir():
        for d in sorted((p for p in its.iterdir() if p.name.isdigit()), key=lambda p: int(p.name)):
            rec = _read(d / "record.json")
            if isinstance(rec, dict):
                rec["_critique"] = _read(d / "critique.json") or {}
                out.append(rec)
    return out


def _num(v: Any) -> float | None:
    try:
        return None if v is None or isinstance(v, bool) else float(v)
    except (TypeError, ValueError):
        return None


def _fun(critique: dict) -> float | None:
    for v in (critique.get("fun"), critique.get("fun_score"), (critique.get("scores") or {}).get("fun")
              if isinstance(critique.get("scores"), dict) else None):
        if _num(v) is not None:
            return _num(v)
    return None


def run_metrics(settings: Settings, slug: str) -> dict:
    """Every non-timing number for one built game, read from its records."""
    from forge.done import readiness

    run_dir = settings.runs_dir / slug
    spec = _read(run_dir / "spec.json") or {}
    state = _read(run_dir / "state.json") or {}
    recs = _iteration_records(run_dir)

    fixes = [f for r in recs for f in r.get("fixes") or []]
    compile_fixes = sum(1 for f in fixes if f.get("kind") == "compile")
    scores = [_num(r.get("score")) for r in recs if _num(r.get("score")) is not None]
    funs = [f for f in (_fun(r["_critique"]) for r in recs) if f is not None]
    last = recs[-1] if recs else {}
    left = last.get("compile_errors_after_fix") or last.get("compile_errors") or []

    checks = _read(run_dir / "checks" / "results.json")
    if isinstance(checks, dict):
        checks = checks.get("results")
    checks = checks if isinstance(checks, list) else []
    improve = _read(run_dir / "improve" / "scores.json")
    improve = improve if isinstance(improve, list) else []

    r = readiness(settings, slug)
    return {
        "title": spec.get("title"),
        "modules": len(spec.get("modules") or []),
        "iterations": len(recs),
        "fixes": {"compile": compile_fixes, "critic": len(fixes) - compile_fixes, "total": len(fixes)},
        "compile_errors_left": len(left),
        "runtime_errors": sum(len(r.get("runtime_errors") or []) for r in recs),
        "acceptance": {"criteria": len(spec.get("acceptance") or []),
                       "checks": len(checks), "passed": sum(1 for c in checks if c.get("ok"))},
        "critic": {"scores": scores, "first": scores[0] if scores else None,
                   "final": scores[-1] if scores else None, "best": max(scores) if scores else None},
        "fun": {"scores": funs, "final": funs[-1] if funs else None},
        "improve": {"cycles": len(improve), "open": (improve[-1].get("open") if improve else None)},
        "done": {"ready": r["ready"], "ok": sum(1 for p in r["parts"] if p["ok"]), "of": len(r["parts"]),
                 "parts": {p["part"]: p["ok"] for p in r["parts"]}},
        "corrections": len(state.get("corrections") or []),
    }


# ================================================================ one idea

async def _improve(settings: Settings, slug: str, cycles: int, studio_name: str | None, llm_factory) -> list[dict]:
    from forge.cli import default_goal
    from forge.improve import ImproveStore, run_cycle
    from forge.studio import Studio
    from mubit_tester.ai import multi_playtest
    from mubit_tester.harness import Harness

    store = ImproveStore(settings, slug)
    store.dir.mkdir(parents=True, exist_ok=True)
    llm = llm_factory(store.dir / "calls.jsonl")
    goal = default_goal(store.run.load_spec())
    out = []
    async with Studio(settings) as studio:
        await studio.select(studio_name)
        harness = Harness(studio)
        for _ in range(cycles):
            cycle = await run_cycle(settings, slug, llm=llm, harness=harness, playtest=multi_playtest,
                                    faults=[], goal=goal, rounds=1, players=None, steps=10, fix=True)
            out.append(cycle)
            if cycle.get("open") == 0:
                break
    return out


async def bench_idea(item: dict, root: Path, base: Settings, *, iterations: int, studio: str | None,
                     improve: int, fake: bool, lessons: str, ui: Any = None) -> dict:
    from forge.llm import FakeLLM, make_llm
    from forge.loop import new_game

    settings = dataclasses.replace(base, runs_dir=root / item["id"])
    settings.runs_dir.mkdir(parents=True, exist_ok=True)
    src = base.runs_dir / "lessons.md"
    (settings.runs_dir / "lessons.md").write_text(
        src.read_text(encoding="utf-8") if lessons == "current" and src.exists() else STARTER_LESSONS)
    slug = slugify(item["idea"])  # what new_game picks in an empty runs dir

    def llm_factory(log_path: Path):  # (both LLMs create the log's folder on their first call)
        if fake:
            return FakeLLM({}, default=fake_reply, log_path=log_path)
        return make_llm(settings, log_path)

    rec: dict = {"id": item["id"], "idea": item["idea"], "slug": slug, "ok": True, "error": None}
    old_env = os.environ.get("FORGE_STUDIO")
    if studio:
        os.environ["FORGE_STUDIO"] = studio
    t0 = time.monotonic()
    try:
        with instrument(rec):
            got = await new_game(item["idea"], iterations, bool(studio), settings=settings,
                                 llm=llm_factory(settings.runs_dir / slug / "calls.jsonl"), ui=ui)
            rec["slug"] = got
            if improve and studio:
                t1 = time.monotonic()
                await _improve(settings, got, improve, studio, llm_factory)
                rec["stages"]["improve"] = round(time.monotonic() - t1, 2)
    except Exception as e:  # one broken idea must not lose the others' numbers
        rec["ok"] = False
        rec["error"] = f"{type(e).__name__}: {e}"[:500]
    finally:
        if studio:
            if old_env is None:
                os.environ.pop("FORGE_STUDIO", None)
            else:
                os.environ["FORGE_STUDIO"] = old_env
    rec["wall_s"] = round(time.monotonic() - t0 - rec.get("overhead_s", 0.0), 2)
    marks = rec.pop("marks", {})
    if "build_start" in marks:
        rec["stages"]["design"] = round(marks["build_start"] - t0, 2)
    run_dir = settings.runs_dir / rec["slug"]
    rec["llm"] = llm_stats(run_dir)
    if (run_dir / "spec.json").exists():
        rec.update(run_metrics(settings, rec["slug"]))
    rec["dir"] = str(run_dir)
    return rec


# ================================================================ suite

def totals(ideas: list[dict]) -> dict:
    def mean(vals):
        vals = [v for v in vals if v is not None]
        return round(sum(vals) / len(vals), 3) if vals else None

    return {
        "ideas": len(ideas),
        "built": sum(1 for i in ideas if i.get("ok")),
        "wall_s": round(sum(i.get("wall_s") or 0 for i in ideas), 1),
        "llm_calls": sum((i.get("llm") or {}).get("calls", 0) for i in ideas),
        "input_tokens": sum((i.get("llm") or {}).get("input_tokens", 0) for i in ideas),
        "output_tokens": sum((i.get("llm") or {}).get("output_tokens", 0) for i in ideas),
        "first_try_pass_rate": mean([(i.get("compile_first") or {}).get("pass_rate") for i in ideas]),
        "fixes": sum((i.get("fixes") or {}).get("total", 0) for i in ideas),
        "compile_errors_left": sum(i.get("compile_errors_left") or 0 for i in ideas),
        "critic_final": mean([(i.get("critic") or {}).get("final") for i in ideas]),
        "fun_final": mean([(i.get("fun") or {}).get("final") for i in ideas]),
        "checks_passed": sum((i.get("acceptance") or {}).get("passed", 0) for i in ideas),
        "checks": sum((i.get("acceptance") or {}).get("checks", 0) for i in ideas),
        "done_parts": sum((i.get("done") or {}).get("ok", 0) for i in ideas),
        "done_of": sum((i.get("done") or {}).get("of", 0) for i in ideas),
        "ready": sum(1 for i in ideas if (i.get("done") or {}).get("ready")),
        "corrections": sum(i.get("corrections") or 0 for i in ideas),
    }


async def run_bench(ids: list[str] | None = None, *, iterations: int = 2, studio: str | None = None,
                    improve: int = 0, fake: bool = False, lessons: str = "starter",
                    settings: Settings | None = None, out_dir: Path | None = None, ui: Any = None,
                    label: str | None = None) -> tuple[dict, Path]:
    base = settings or load_settings()
    items = [s for s in SUITE if not ids or s["id"] in ids]
    unknown = sorted(set(ids or []) - set(SUITE_IDS))
    if unknown:
        raise ValueError(f"unknown bench idea(s) {', '.join(unknown)}; choose from {', '.join(SUITE_IDS)}")
    st = stamp()
    out = out_dir or bench_dir(base)
    root = out / st
    root.mkdir(parents=True, exist_ok=True)
    result = {
        "schema": SCHEMA, "stamp": st, "label": label,
        "mode": "fake" if fake else "real", "studio": studio, "model": "fake" if fake else base.model,
        "iterations": iterations, "improve": improve if studio else 0, "lessons": lessons,
        "git": {"sha": _git(base, "rev-parse", "--short", "HEAD"),
                "branch": _git(base, "rev-parse", "--abbrev-ref", "HEAD"),
                "subject": _git(base, "log", "-1", "--format=%s")},
        "ideas": [],
    }
    path = out / f"{st}.json"
    for item in items:
        print(f"\n=== bench {item['id']} ===", flush=True)
        rec = await bench_idea(item, root, base, iterations=iterations, studio=studio, improve=improve,
                               fake=fake, lessons=lessons, ui=ui)
        result["ideas"].append(rec)
        result["totals"] = totals(result["ideas"])
        path.write_text(json.dumps(result, indent=1) + "\n", encoding="utf-8")  # partial results survive
    result["totals"] = totals(result["ideas"])
    path.write_text(json.dumps(result, indent=1) + "\n", encoding="utf-8")
    path.with_suffix(".md").write_text(render(result) + "\n", encoding="utf-8")
    return result, path


# ================================================================ output

def _f(v: Any, fmt: str = "g") -> str:
    if v is None:
        return "-"
    if isinstance(v, float):
        return format(v, fmt)
    return str(v)


def _pct(v: Any) -> str:
    return "-" if v is None else f"{v * 100:.0f}%"


def render(result: dict) -> str:
    g = result.get("git") or {}
    lines = [
        f"# forge bench {result['stamp']}" + (f" ({result['label']})" if result.get("label") else ""),
        "",
        f"mode **{result['mode']}**, model `{result.get('model')}`, studio `{result.get('studio') or 'none'}`, "
        f"{result['iterations']} iteration(s), improve {result.get('improve', 0)}, lessons {result.get('lessons')}, "
        f"git `{g.get('sha')}` on `{g.get('branch')}`",
        "",
        "| idea | ok | wall s | design | build | iterate | compile/fix | playtest | improve | LLM calls | tokens in/out "
        "| 1st-try compile | fixes c/k | left | critic first->final | fun | checks | done | corrections |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---|---:|---|---:|---|---|---:|",
    ]
    for i in result["ideas"]:
        s = i.get("stages") or {}
        llm = i.get("llm") or {}
        c = i.get("critic") or {}
        fx = i.get("fixes") or {}
        acc = i.get("acceptance") or {}
        dn = i.get("done") or {}
        lines.append(
            f"| {i['id']} | {'yes' if i.get('ok') else 'NO'} | {_f(i.get('wall_s'), '.0f')} "
            f"| {_f(s.get('design'), '.0f')} | {_f(s.get('build'), '.0f')} | {_f(s.get('iterate'), '.0f')} "
            f"| {_f(s.get('compile_fix'), '.0f')} | {_f(s.get('playtest'), '.0f')} | {_f(s.get('improve'), '.0f')} "
            f"| {llm.get('calls', 0)} | {llm.get('input_tokens', 0)}/{llm.get('output_tokens', 0)} "
            f"| {_pct((i.get('compile_first') or {}).get('pass_rate'))} | {fx.get('compile', 0)}/{fx.get('critic', 0)} "
            f"| {i.get('compile_errors_left', '-')} | {_f(c.get('first'))} -> {_f(c.get('final'))} "
            f"| {_f((i.get('fun') or {}).get('final'))} | {acc.get('passed', 0)}/{acc.get('checks', 0)} "
            f"| {dn.get('ok', 0)}/{dn.get('of', 0)}{' READY' if dn.get('ready') else ''} | {i.get('corrections', 0)} |")
    t = result.get("totals") or totals(result["ideas"])
    lines += [
        "",
        f"**Totals:** {t['built']}/{t['ideas']} built, {t['wall_s']:.0f}s wall, {t['llm_calls']} LLM calls, "
        f"{t['input_tokens']}/{t['output_tokens']} tokens, first-try compile {_pct(t['first_try_pass_rate'])}, "
        f"{t['fixes']} fixes, {t['compile_errors_left']} compile errors left, critic {_f(t['critic_final'])}, "
        f"fun {_f(t['fun_final'])}, checks {t['checks_passed']}/{t['checks']}, done parts {t['done_parts']}/{t['done_of']} "
        f"({t['ready']} ready), {t['corrections']} human corrections.",
    ]
    errs = [i for i in result["ideas"] if i.get("error")]
    if errs:
        lines += ["", "Errors:"] + [f"- {i['id']}: {i['error']}" for i in errs]
    rids = [(i["id"], (i.get("llm") or {}).get("request_ids") or []) for i in result["ideas"]]
    if any(r for _, r in rids):
        lines += ["", "Mubit request ids (first 3 per idea): "
                  + "; ".join(f"{k}: {', '.join(r[:3])}" for k, r in rids if r)]
    return "\n".join(lines)


# (label, getter, higher_is_better, format)
METRICS: list[tuple[str, Callable[[dict], Any], bool, str]] = [
    ("wall s", lambda i: i.get("wall_s"), False, ".1f"),
    ("design s", lambda i: (i.get("stages") or {}).get("design"), False, ".1f"),
    ("build s", lambda i: (i.get("stages") or {}).get("build"), False, ".1f"),
    ("iterate s", lambda i: (i.get("stages") or {}).get("iterate"), False, ".1f"),
    ("playtest s", lambda i: (i.get("stages") or {}).get("playtest"), False, ".1f"),
    ("LLM calls", lambda i: (i.get("llm") or {}).get("calls"), False, "g"),
    ("LLM s (sum of calls)", lambda i: (i.get("llm") or {}).get("latency_s"), False, ".1f"),
    ("LLM overlap (sum/wall)", lambda i: round(i["llm"]["latency_s"] / i["wall_s"], 2)
     if (i.get("llm") or {}).get("latency_s") and i.get("wall_s") else None, True, ".2f"),
    ("tokens", lambda i: ((i.get("llm") or {}).get("input_tokens", 0) + (i.get("llm") or {}).get("output_tokens", 0))
     if i.get("llm") else None, False, "g"),
    ("1st-try compile", lambda i: (i.get("compile_first") or {}).get("pass_rate"), True, ".2f"),
    ("fixes", lambda i: (i.get("fixes") or {}).get("total"), False, "g"),
    ("compile left", lambda i: i.get("compile_errors_left"), False, "g"),
    ("critic final", lambda i: (i.get("critic") or {}).get("final"), True, "g"),
    ("fun", lambda i: (i.get("fun") or {}).get("final"), True, "g"),
    ("checks passed", lambda i: (i.get("acceptance") or {}).get("passed"), True, "g"),
    ("done parts", lambda i: (i.get("done") or {}).get("ok"), True, "g"),
    ("corrections", lambda i: i.get("corrections"), False, "g"),
]


def resolve(ref: str, settings: Settings | None = None) -> Path:
    p = Path(ref)
    if p.is_file():
        return p
    d = bench_dir(settings or load_settings())
    for cand in (d / ref, d / f"{ref}.json"):
        if cand.is_file():
            return cand
    if ref in ("latest", "prev"):
        files = sorted(d.glob("*.json"))
        k = -1 if ref == "latest" else -2
        if len(files) >= -k:
            return files[k]
    raise FileNotFoundError(f"no bench result {ref!r} (a path, a stamp in {d}, latest or prev)")


def compare(a: dict, b: dict) -> str:
    """A table of B - A per idea and metric, plus the totals. 'better' follows each metric's direction."""
    def row(label, va, vb, hib, fmt):
        if va is None and vb is None:
            return None
        d = "" if va is None or vb is None else vb - va
        verdict = ""
        if isinstance(d, (int, float)) and d != 0:
            verdict = "better" if (d > 0) == hib else "worse"
        ds = "-" if d == "" else (f"+{d:{fmt}}" if d > 0 else f"{d:{fmt}}")
        return f"| {label} | {_f(va, fmt) if isinstance(va, float) else _f(va)} " \
               f"| {_f(vb, fmt) if isinstance(vb, float) else _f(vb)} | {ds} | {verdict} |"

    head = (f"# forge bench compare\n\nA = {a['stamp']} ({a['mode']}, git {(a.get('git') or {}).get('sha')})  \n"
            f"B = {b['stamp']} ({b['mode']}, git {(b.get('git') or {}).get('sha')})\n")
    out = [head]
    ia = {i["id"]: i for i in a["ideas"]}
    ib = {i["id"]: i for i in b["ideas"]}
    common = [k for k in ia if k in ib]
    for k in common:
        out += [f"\n## {k}\n", "| metric | A | B | B-A | |", "|---|---:|---:|---:|---|"]
        for label, get, hib, fmt in METRICS:
            r = row(label, get(ia[k]), get(ib[k]), hib, fmt)
            if r:
                out.append(r)
    if common:
        ta = totals([ia[k] for k in common])
        tb = totals([ib[k] for k in common])
        out += [f"\n## totals over {', '.join(common)}\n", "| metric | A | B | B-A | |", "|---|---:|---:|---:|---|"]
        for label, key, hib, fmt in [("wall s", "wall_s", False, ".1f"), ("LLM calls", "llm_calls", False, "g"),
                                     ("input tokens", "input_tokens", False, "g"),
                                     ("output tokens", "output_tokens", False, "g"),
                                     ("1st-try compile", "first_try_pass_rate", True, ".2f"),
                                     ("fixes", "fixes", False, "g"), ("compile left", "compile_errors_left", False, "g"),
                                     ("critic final", "critic_final", True, ".2f"), ("fun", "fun_final", True, ".2f"),
                                     ("checks passed", "checks_passed", True, "g"),
                                     ("done parts", "done_parts", True, "g"), ("ready", "ready", True, "g"),
                                     ("corrections", "corrections", False, "g")]:
            r = row(label, ta.get(key), tb.get(key), hib, fmt)
            if r:
                out.append(r)
    only = sorted(set(ia) ^ set(ib))
    if only:
        out.append(f"\nIn one run only (not compared): {', '.join(only)}")
    return "\n".join(out)


# ================================================================ CLI

def add_cli_parser(sub) -> None:
    b = sub.add_parser("bench", help="build a fixed suite of small games and record speed + quality numbers")
    b.add_argument("--ideas", help=f"comma-separated subset of: {', '.join(SUITE_IDS)} (default all)")
    b.add_argument("--iterations", "-n", type=int, default=2, help="build iterations per idea (default 2)")
    b.add_argument("--fake", action="store_true", help="cheap mode: FakeLLM, no Studio, no tokens (CI)")
    b.add_argument("--studio", help="real mode with a Studio playtest in this window (e.g. Forge-agents-29)")
    b.add_argument("--improve", type=int, default=0, help="improve (fix) cycles per idea after the build (Studio only)")
    b.add_argument("--lessons", choices=["starter", "current"], default="starter",
                   help="start each idea from the starter lessons (default, comparable) or runs/lessons.md")
    b.add_argument("--label", help="a note saved with the result (e.g. 'baseline main')")
    b.add_argument("--out", help="results folder (default runs/bench)")
    b.add_argument("--compare", nargs=2, metavar=("A", "B"),
                   help="print deltas between two results (paths, stamps, latest or prev)")
    b.add_argument("--list", action="store_true", help="list the suite and saved results")


def cmd_bench(args) -> int:
    s = load_settings()
    if args.compare:
        a, b = (json.loads(resolve(r, s).read_text(encoding="utf-8")) for r in args.compare)
        print(compare(a, b))
        return 0
    if args.list:
        for item in SUITE:
            print(f"{item['id']:<10} {item['idea']}")
        d = Path(args.out) if args.out else bench_dir(s)
        for p in sorted(d.glob("*.json")):
            r = _read(p) or {}
            t = r.get("totals") or {}
            print(f"{p.stem}  {r.get('mode')}  {len(r.get('ideas') or [])} ideas  {t.get('wall_s')}s  "
                  f"critic {t.get('critic_final')}  {r.get('label') or ''}")
        return 0
    if args.fake and args.studio:
        print("error: --fake runs without Studio; drop --studio", file=sys.stderr)
        return 2
    if not args.fake and not s.mubit_api_key:
        print("error: MUBIT_API_KEY is not set (or use --fake)", file=sys.stderr)
        return 2
    if not args.fake and not shutil.which("luau-compile"):
        print("warning: luau-compile not on PATH; compile numbers will be missing", file=sys.stderr)
    ids = [x.strip() for x in args.ideas.split(",") if x.strip()] if args.ideas else None
    result, path = asyncio.run(run_bench(ids, iterations=args.iterations, studio=args.studio,
                                         improve=args.improve, fake=args.fake, lessons=args.lessons,
                                         settings=s, out_dir=Path(args.out) if args.out else None,
                                         label=args.label))
    print("\n" + render(result))
    print(f"\nsaved {path} and {path.with_suffix('.md')}")
    return 0 if all(i.get("ok") for i in result["ideas"]) else 1
