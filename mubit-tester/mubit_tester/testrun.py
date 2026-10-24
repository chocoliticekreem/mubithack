"""One-shot feature tests (`test_feature`), their saved records, and run-to-run diffs.

A feature test is: sync -> play -> plan -> run (scenarios, executable checks, an AI playtest) ->
errors -> screenshot -> stop. Every run is saved under runs/tests/<id>/ (record.json, report.md,
shot.png) so `diff_since_last_run` can say what changed between two runs of the same feature:
verdict, checks and scenarios that flipped, errors and bugs that appeared or went away, and which
game files changed in between (a sha1 manifest of the game folder is part of every record).

The pipeline takes its I/O as arguments (`studio`, `harness`, `settings`, an `ai` module), so the
tests drive it with a fake Studio and no LLM.
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import re
import time
from pathlib import Path
from typing import Any, Awaitable, Callable

Progress = Callable[[str], Awaitable[None]]

# verdicts, worst first
FAIL, BROKEN, INCONCLUSIVE, PASS = "FAIL", "ERRORS", "INCONCLUSIVE", "PASS"
_STOP = {"the", "a", "an", "and", "or", "to", "of", "in", "on", "is", "it", "that", "when", "with",
         "for", "can", "be", "player", "players", "should", "after", "into", "from", "their", "they",
         "test", "check", "works", "work", "game", "feature", "new", "does", "each", "every", "at"}


# ---------------------------------------------------------------- records

def tests_dir(settings: Any) -> Path:
    d = Path(settings.runs_dir) / "tests"
    d.mkdir(parents=True, exist_ok=True)
    return d


def new_test_id(description: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", description.lower()).strip("-")[:32] or "feature"
    return f"t-{time.strftime('%Y%m%d-%H%M%S')}-{slug}"


def feature_key(description: str, game: str | None) -> str:
    """Runs of 'the same test': same game and same description (case/space-insensitive)."""
    return f"{game or 'game'}::{' '.join(description.lower().split())}"


def manifest(root: Path) -> dict[str, str]:
    """{relative path: sha1[:12]} of every .luau file under the game folder."""
    root = Path(root)
    if not root.exists():
        return {}
    return {p.relative_to(root).as_posix(): hashlib.sha1(p.read_bytes()).hexdigest()[:12]
            for p in sorted(root.rglob("*.luau")) if ".git" not in p.parts}


def save_record(settings: Any, rec: dict, text: str | None = None) -> Path:
    d = tests_dir(settings) / rec["id"]
    d.mkdir(parents=True, exist_ok=True)
    (d / "record.json").write_text(json.dumps(rec, indent=1, default=str), encoding="utf-8")
    if text is not None:
        (d / "report.md").write_text(text, encoding="utf-8")
    return d


def load_records(settings: Any) -> list[dict]:
    """Every saved feature test, oldest first."""
    out = []
    for p in sorted(tests_dir(settings).glob("*/record.json")):
        with contextlib.suppress(OSError, ValueError):
            out.append(json.loads(p.read_text(encoding="utf-8")))
    return sorted(out, key=lambda r: r.get("started", ""))


def load_record(settings: Any, test_id: str) -> dict:
    p = tests_dir(settings) / test_id / "record.json"
    if not p.exists():
        have = ", ".join(r["id"] for r in load_records(settings)[-5:]) or "none"
        raise FileNotFoundError(f"no test run {test_id!r} (latest: {have})")
    return json.loads(p.read_text(encoding="utf-8"))


# ---------------------------------------------------------------- planning

def _words(text: str) -> set[str]:
    return {w for w in re.findall(r"[a-z0-9]+", text.lower()) if len(w) > 2 and w not in _STOP}


def _stems(words: set[str]) -> set[str]:
    return {w[:5] for w in words}


def relevance(description: str, *texts: str) -> int:
    """How many (5-letter-stem) words of the description appear in the texts."""
    want = _stems(_words(description))
    have = _stems(_words(" ".join(t or "" for t in texts)))
    return len(want & have)


def plan(description: str, scenarios: list[dict], checks: list[Any], *, playtest: bool = True,
         only_scenarios: list[str] | None = None, max_scenarios: int = 2) -> dict:
    """Pick what to run: smoke first, the scenarios that best match the description (or exactly
    `only_scenarios`), every saved executable check of the game, then an AI playtest toward the
    description. Returns {scenarios: [...], checks: [...], playtest: goal|None, why: {...}}."""
    names = {s["name"] for s in scenarios if not s.get("error")}
    why: dict[str, str] = {}
    if only_scenarios is not None:
        chosen = [n for n in only_scenarios if n in names or n.strip().startswith("{")]
        for n in chosen:
            why[n] = "asked for"
        missing = [n for n in only_scenarios if n not in chosen]
        if missing:
            why["missing"] = ", ".join(missing)
    else:
        chosen = ["smoke"] if "smoke" in names else []
        if chosen:
            why["smoke"] = "always: every player spawns and moves, no errors"
        scored = sorted(((relevance(description, s["name"].replace("_", " "), s.get("description", "")), s["name"])
                         for s in scenarios if s["name"] in names and s["name"] != "smoke"), reverse=True)
        # one shared word ("hose") is noise for a long description; ask for two then
        need = 2 if len(_words(description)) >= 4 else 1
        for score, name in scored[:max_scenarios]:
            if score >= need:
                chosen.append(name)
                why[name] = f"matches {score} word(s) of the description"
    return {"scenarios": chosen,
            "checks": [c.id for c in checks],
            "playtest": description if playtest else None,
            "why": why}


# ---------------------------------------------------------------- verdict + formatting

def verdict(rec: dict) -> tuple[str, str]:
    """(verdict, one-line reason) from a record's results."""
    sc = rec.get("scenarios") or []
    ck = rec.get("checks") or []
    pt = rec.get("playtest")
    errs = (rec.get("errors") or {}).get("errors") or []
    failed = [f"scenario {s['name']}" for s in sc if s.get("passed") is False]
    failed += [f"check {c['id']}" for c in ck if not c.get("ok")]
    if pt and pt.get("goal_met") is False:
        failed.append("AI playtest goal not met")
    if failed:
        return FAIL, "failed: " + ", ".join(failed[:6])
    if errs:
        return BROKEN, f"everything passed but the server logged {len(errs)} script error(s)"
    ran = [s for s in sc if s.get("passed")] + [c for c in ck if c.get("ok")]
    if pt and pt.get("goal_met") is True:
        ran.append(pt)
    if not ran:
        return INCONCLUSIVE, "nothing ran to a result (all skipped, or no checks/scenarios/playtest)"
    if pt and pt.get("goal_met") is None and not [s for s in sc if s.get("passed")] and not ck:
        return INCONCLUSIVE, "only the AI playtest ran and its judge couldn't decide"
    return PASS, f"{len(ran)} thing(s) passed, no script errors"


def _cell(v: Any, n: int = 120) -> str:
    s = " ".join(str(v if v is not None else "").split()).replace("|", "\\|")
    return s if len(s) <= n else s[: n - 1] + "…"


def format_record(rec: dict) -> str:
    """Summary first (verdict, why, next step), then a results table, then details."""
    v, why = rec.get("verdict") or verdict(rec)
    secs = rec.get("seconds")
    out = [f"## {v}: {rec.get('description')}",
           f"{why}. Test `{rec['id']}`" + (f", {secs:.0f}s" if isinstance(secs, (int, float)) else "")
           + (f", game `{rec['game']}`" if rec.get("game") else "") + "."]
    nxt = next_step(rec, v)
    if nxt:
        out.append(f"**Next:** {nxt}")
    out.append("")
    rows = []
    for s in rec.get("scenarios") or []:
        mark = "SKIP" if s.get("skipped") else "PASS" if s.get("passed") else "FAIL"
        detail = s.get("reason") or s.get("partial") or next(
            (st.get("detail") for st in s.get("steps") or [] if not st.get("ok")), "") or f"{len(s.get('steps') or [])} steps"
        rows.append(("scenario", s.get("name"), mark, detail))
    for c in rec.get("checks") or []:
        rows.append(("check", c.get("id"), "PASS" if c.get("ok") else "FAIL", c.get("error") or c.get("detail")))
    pt = rec.get("playtest")
    if pt:
        met = pt.get("goal_met")
        mark = "PASS" if met is True else "FAIL" if met is False else "?"
        rows.append(("AI playtest", pt.get("run_id"), mark, pt.get("summary") or ""))
    errs = (rec.get("errors") or {}).get("errors") or []
    rows.append(("errors", "ForgeProbe", "PASS" if not errs else f"{len(errs)}",
                 "; ".join(_cell(e.get("message") if isinstance(e, dict) else e, 80) for e in errs[:3]) or "none"))
    out += ["| kind | name | result | detail |", "|---|---|---|---|"]
    out += [f"| {k} | {_cell(n, 40)} | {r} | {_cell(d)} |" for k, n, r, d in rows]
    bugs = (pt or {}).get("bugs") or []
    if bugs:
        out += ["", f"### Bugs the AI players found ({len(bugs)})"]
        for i, b in enumerate(bugs):
            if isinstance(b, dict):
                out.append(f"- #{i} [{b.get('severity', '?')}] **{_cell(b.get('title'), 100)}**: {_cell(b.get('evidence'), 200)}")
            else:
                out.append(f"- #{i} {_cell(b, 200)}")
    if errs:
        out += ["", "### Script errors"]
        for e in errs[:8]:
            if isinstance(e, dict):
                out.append(f"- **{_cell(e.get('message'), 200)}** x{e.get('count', 1)} ({_cell(e.get('script'), 60)})")
            else:
                out.append(f"- {_cell(e, 200)}")
    p = rec.get("plan") or {}
    out += ["", "### Plan", f"- scenarios: {', '.join(p.get('scenarios') or []) or 'none'}"
            + (f" ({'; '.join(f'{k}: {w}' for k, w in (p.get('why') or {}).items())})" if p.get("why") else ""),
            f"- checks: {len(p.get('checks') or [])} saved executable check(s)",
            f"- AI playtest: {'yes' if p.get('playtest') else 'no'}"]
    stages = rec.get("stages") or []
    if stages:
        out.append("- timings: " + ", ".join(f"{s['stage']} {s['seconds']:.0f}s" for s in stages))
    notes = rec.get("notes") or []
    if notes:
        out += ["", "### Notes"] + [f"- {_cell(n, 300)}" for n in notes]
    if rec.get("screenshot"):
        out += ["", f"Screenshot: `{rec['screenshot']}`"]
    out.append(f"Saved: `{rec.get('dir', '')}`. Compare with the previous run: `diff_since_last_run`.")
    return "\n".join(out)


def next_step(rec: dict, v: str) -> str:
    pt = rec.get("playtest") or {}
    if v == FAIL:
        if pt.get("bugs"):
            return (f"`suggest_fix(run_id=\"{pt.get('run_id')}\", bug=0)` for a patch, fix the code, then "
                    "run this test again and `diff_since_last_run`.")
        return "read the failing rows below, fix the code, run this test again, then `diff_since_last_run`."
    if v == BROKEN:
        return "the feature works but scripts error: read Script errors and fix them before calling it done."
    if v == INCONCLUSIVE:
        return ("nothing proved the feature: add an executable check (runs/<slug>/checks/<id>.luau) or a "
                "scenario for it, or pass `scenarios=[...]`, then rerun.")
    return ""


# ---------------------------------------------------------------- diff

def _status_map(rec: dict) -> dict[str, str]:
    out = {}
    for s in rec.get("scenarios") or []:
        out[f"scenario {s.get('name')}"] = "SKIP" if s.get("skipped") else "PASS" if s.get("passed") else "FAIL"
    for c in rec.get("checks") or []:
        out[f"check {c.get('id')}"] = "PASS" if c.get("ok") else "FAIL"
    pt = rec.get("playtest")
    if pt:
        met = pt.get("goal_met")
        out["AI playtest"] = "PASS" if met is True else "FAIL" if met is False else "?"
    return out


def _err_set(rec: dict) -> set[str]:
    return {" ".join(str(e.get("message") if isinstance(e, dict) else e).split())[:160]
            for e in (rec.get("errors") or {}).get("errors") or []}


def _bug_set(rec: dict) -> set[str]:
    return {str(b.get("title") if isinstance(b, dict) else b)[:120] for b in (rec.get("playtest") or {}).get("bugs") or []}


def previous_record(records: list[dict], rec: dict) -> dict | None:
    """The latest earlier run of the same feature test, else the latest earlier run of anything."""
    earlier = [r for r in records if r.get("started", "") < rec.get("started", "") and r["id"] != rec["id"]]
    same = [r for r in earlier if r.get("key") == rec.get("key")]
    return (same or earlier or [None])[-1]


def diff(old: dict, new: dict) -> dict:
    a, b = _status_map(old), _status_map(new)
    flips = [(k, a.get(k, "not run"), b.get(k, "not run")) for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)]
    ea, eb = _err_set(old), _err_set(new)
    ba, bb = _bug_set(old), _bug_set(new)
    ma, mb = old.get("manifest") or {}, new.get("manifest") or {}
    files = {"changed": sorted(k for k in set(ma) & set(mb) if ma[k] != mb[k]),
             "added": sorted(set(mb) - set(ma)), "removed": sorted(set(ma) - set(mb))}
    return {"old": old["id"], "new": new["id"], "same_test": old.get("key") == new.get("key"),
            "verdict": (old.get("verdict", ["?"])[0], new.get("verdict", ["?"])[0]),
            "flips": flips, "new_errors": sorted(eb - ea), "fixed_errors": sorted(ea - eb),
            "new_bugs": sorted(bb - ba), "gone_bugs": sorted(ba - bb), "files": files}


def format_diff(d: dict) -> str:
    va, vb = d["verdict"]
    better = {FAIL: 0, BROKEN: 1, INCONCLUSIVE: 1, PASS: 2}
    trend = ("better" if better.get(vb, 1) > better.get(va, 1) else
             "worse" if better.get(vb, 1) < better.get(va, 1) else "same verdict")
    nfiles = sum(len(v) for v in d["files"].values())
    regress = [f for f in d["flips"] if f[1] == "PASS" and f[2] == "FAIL"]
    fixed = [f for f in d["flips"] if f[1] == "FAIL" and f[2] == "PASS"]
    out = [f"## {va} -> {vb} ({trend}): {len(fixed)} fixed, {len(regress)} regressed, "
           f"{len(d['new_errors'])} new error(s), {nfiles} file(s) changed",
           f"`{d['old']}` -> `{d['new']}`" + ("" if d["same_test"] else " (different tests: compared with the latest run)"),
           ""]
    if d["flips"]:
        out += ["| what | before | after |", "|---|---|---|"] + [f"| {k} | {x} | {y} |" for k, x, y in d["flips"]]
    else:
        out.append("No check, scenario or playtest result changed.")
    for title, key in (("New errors", "new_errors"), ("Errors gone", "fixed_errors"),
                       ("New bugs", "new_bugs"), ("Bugs gone", "gone_bugs")):
        if d[key]:
            out += ["", f"### {title} ({len(d[key])})"] + [f"- {_cell(x, 200)}" for x in d[key][:10]]
    f = d["files"]
    if nfiles:
        out += ["", "### Files between the runs"]
        out += [f"- changed `{p}`" for p in f["changed"][:20]] + [f"- added `{p}`" for p in f["added"][:10]] \
            + [f"- removed `{p}`" for p in f["removed"][:10]]
    if regress and nfiles:
        out += ["", "A regression with files changed: `bisect_versions` finds the version that broke it "
                    "(for a Forge game)."]
    return "\n".join(out)


# ---------------------------------------------------------------- pipeline

async def _stage(rec: dict, name: str, progress: Progress | None, coro_fn, *args, **kwargs) -> Any:
    if progress:
        await progress(name)
    t0 = time.monotonic()
    try:
        return await coro_fn(*args, **kwargs)
    finally:
        rec.setdefault("stages", []).append({"stage": name, "seconds": time.monotonic() - t0})


async def run_feature_test(*, settings: Any, description: str, studio: Any, harness: Any,
                           game_root: Path, game: str | None = None, ai: Any = None, play_mod: Any = None,
                           do_sync: Callable[[], Awaitable[str]] | None = None,
                           scenarios: list[str] | None = None, run_checks: bool = True,
                           playtest: bool = True, players: int | None = None, steps: int = 12,
                           screenshot: bool = True, stop: bool = True,
                           progress: Progress | None = None) -> dict:
    """The whole feature test. Never raises for a failing stage: the stage's error goes into
    rec["notes"] and the verdict reflects what could run. Always stops play it started (or any
    play when `stop`)."""
    from forge import checks as fchecks
    from mubit_tester.scenario import list_scenarios, load_scenario, run_scenario

    t0 = time.monotonic()
    rec: dict[str, Any] = {"id": new_test_id(description), "description": description, "game": game,
                           "key": feature_key(description, game), "started": time.strftime("%Y-%m-%dT%H:%M:%S"),
                           "manifest": manifest(game_root), "notes": [], "scenarios": [], "checks": []}
    d = tests_dir(settings) / rec["id"]
    rec["dir"] = str(d)
    try:
        if do_sync is not None:
            try:
                rec["sync"] = str(await _stage(rec, "sync", progress, do_sync)).strip()[:300]
            except BaseException as e:  # noqa: BLE001  SystemExit from compile errors too
                if isinstance(e, (KeyboardInterrupt, GeneratorExit)):
                    raise
                rec["notes"].append(f"sync failed: {e}")
                rec["verdict"] = (FAIL, f"sync failed (compile error?): {str(e)[:200]}")
                return rec
        try:
            await _stage(rec, "play", progress, harness.ensure_ready, timeout=60)
        except Exception as e:  # noqa: BLE001
            rec["notes"].append(f"could not start play / reach the ForgeTest harness: {e}")
            rec["verdict"] = (INCONCLUSIVE, f"play did not start: {str(e)[:200]}")
            return rec

        checks = fchecks.load_checks(Path(settings.runs_dir) / game) if (game and run_checks) else []
        p = plan(description, list_scenarios(settings.repo_root), checks, playtest=playtest,
                 only_scenarios=scenarios)
        if ai is not None and hasattr(ai, "plan_feature_test"):  # tester protocol may refine the plan
            with contextlib.suppress(Exception):
                p = await ai.plan_feature_test(settings, description, p) or p
        rec["plan"] = p
        if progress:
            await progress(f"plan: {len(p['scenarios'])} scenario(s), {len(p['checks'])} check(s), "
                           f"playtest {'yes' if p['playtest'] else 'no'}")

        for name in p["scenarios"]:
            try:
                sc = load_scenario(name, settings.repo_root)
                res = await _stage(rec, f"scenario {sc.get('name', name)}", progress, run_scenario, harness, sc)
                res.pop("events", None)
                rec["scenarios"].append(res)
            except Exception as e:  # noqa: BLE001
                rec["scenarios"].append({"name": name, "passed": False, "skipped": False,
                                         "steps": [{"n": 0, "ok": False, "detail": f"{type(e).__name__}: {e}"}]})
        if checks:
            rec["checks"] = await _stage(rec, "checks", progress, fchecks.run_checks, studio, checks)
            # every saved check ran: this is the game's latest check run (forge done reads it)
            res_path = fchecks.checks_dir(Path(settings.runs_dir) / game) / "results.json"
            with contextlib.suppress(OSError):
                res_path.write_text(json.dumps({"results": rec["checks"], "at": rec["started"],
                                                "by": f"test_feature {rec['id']}"}, indent=1), encoding="utf-8")

        if p.get("playtest"):
            try:
                report = await _stage(rec, "AI playtest", progress, _playtest, settings, p["playtest"],
                                      studio, harness, ai, play_mod, players, steps)
                rec["playtest"] = {k: report.get(k) for k in ("run_id", "goal_met", "summary", "bugs")}
            except Exception as e:  # noqa: BLE001
                rec["notes"].append(f"AI playtest failed: {type(e).__name__}: {e}")

        try:
            rec["errors"] = await _stage(rec, "errors", progress, studio.probe_report)
        except Exception as e:  # noqa: BLE001
            rec["notes"].append(f"ForgeProbe unavailable: {e}")
        if screenshot:
            with contextlib.suppress(Exception):
                shot = await _stage(rec, "screenshot", progress, studio.screenshot, d / "shot.png")
                if shot:
                    rec["screenshot"] = str(shot)
    finally:
        if stop or getattr(harness, "started_play", False):
            with contextlib.suppress(Exception):
                await studio.stop()
                rec["stopped"] = True
        rec["seconds"] = time.monotonic() - t0
        rec["verdict"] = rec.get("verdict") or verdict(rec)
        save_record(settings, rec, format_record(rec))
    return rec


async def _playtest(settings, goal, studio, harness, ai, play_mod, players, steps) -> dict:
    if ai is not None and hasattr(ai, "multi_playtest"):
        return await ai.multi_playtest(settings, goal, players=players, steps=steps, studio=studio, harness=harness)
    if play_mod is None:
        raise RuntimeError("no AI playtester available (mubit_tester.ai / mubit_tester.play)")
    return await play_mod.playtest(settings, goal, steps, studio=studio)
