"""`forge feature <slug> "<request>"`: the agent adds a feature to an existing game, end to end.

    planner (Mubit task)  -> new modules + small hook-in edits + telemetry + acceptance
    coder                 -> writes each new module (agent-owned files)
    patcher / fixer       -> each hook-in edit (exact edits for big files; destructive guard applies)
    compile check + fixer -> then a saved version "feature: <request>"
    iterate (optional)    -> playtest, critic, fixer, reflector, auto-rollback on a score drop
    verified              -> the feature's telemetry counters appear in the last playtest, and (a feature
                             with client UI) a tester really clicked one of its buttons

Everything happens in runs/<slug>/game, versioned (forge versions / forge rollback).
"""

from __future__ import annotations

import asyncio
import json
import re
from typing import Any, Callable

from forge.config import Settings
from forge.llm import LLMError
from forge.memory import RunStore, now_iso, read_lessons
from forge.versions import GameVersions

PLAN_KEYS = ["summary", "new_modules"]
MAX_NEW_MODULES = 5  # a real feature (config, service, data, UI, hook) needs room
MAX_EDITS = 3
ROOTS = ("ServerScriptService/", "ReplicatedStorage/", "StarterPlayerScripts/")


def plan_message(spec: dict, index: str, request: str, lessons: str) -> str:
    from forge.loop import spec_summary
    from forge.roles import _lessons_block, _truncate

    return "\n\n".join([
        "## Game\n" + _truncate(spec_summary(spec), 3000, label="spec"),
        "## Game files\n" + index,
        "## Feature request\n" + request.strip(),
        _lessons_block(lessons, 3000),
        "Return only the plan JSON object.",
    ])


def validate_plan(plan: dict, game_dir) -> dict:
    """Keep only buildable parts: new modules at new, valid paths; edits to existing files."""
    new_modules = []
    for m in (plan.get("new_modules") or [])[:MAX_NEW_MODULES]:
        path = str((m or {}).get("path", "")).strip().lstrip("/")
        if not path.endswith(".luau") or not path.startswith(ROOTS) or ".." in path.split("/"):
            continue
        if (game_dir / path).exists():
            continue
        new_modules.append({"path": path, "purpose": str(m.get("purpose", "")),
                            "depends": [str(d) for d in (m.get("depends") or []) if isinstance(d, str)]})
    edits = []
    for e in (plan.get("edits") or [])[:MAX_EDITS]:
        path = str((e or {}).get("path", "")).strip().lstrip("/")
        if path and (game_dir / path).is_file() and ".." not in path.split("/"):
            edits.append({"path": path, "change": str(e.get("change", ""))})
    return {"summary": str(plan.get("summary", "")), "new_modules": new_modules, "edits": edits,
            "telemetry": [str(t) for t in (plan.get("telemetry") or []) if t][:4],
            "acceptance": [str(a) for a in (plan.get("acceptance") or []) if a][:6]}


async def add_feature(settings: Settings, slug: str, request: str, *, llm: Any = None, ui=None,
                      iterations: int = 1, use_studio: bool = True, polish: int = 0, jobs: int | None = None,
                      log: Callable[[str], None] = print) -> dict:
    from forge import roles
    from forge.improve import destructive, file_index
    from forge.loop import Run, topo_order
    from forge.patch import PATCH_ABOVE_LINES

    if not request.strip():
        raise ValueError("the feature request is empty")
    store = RunStore(settings, slug)
    if not store.exists():
        raise FileNotFoundError(f"no game {slug!r}")
    run = Run(settings, store, llm, ui, jobs=jobs, command="feature")
    spec = store.load_spec()
    run.spec = spec
    versions = GameVersions(store.game_dir)
    before = versions.snapshot(f"before feature: {request.strip()[:120]}")
    session = f"feature-{slug}"
    lessons = read_lessons(settings)

    with run.stage("feature: plan"):
        raw = await run.call("planner", "feature plan", lambda llm_, *a, **k: llm_.complete_json(*a, **k)[0],
                             "planner", plan_message(spec, file_index(store.game_dir), request, lessons),
                             session_id=session, required=PLAN_KEYS, max_tokens=4096)
    plan = validate_plan(raw, store.game_dir)
    log(f"[planner] {plan['summary'][:140]} -> {len(plan['new_modules'])} new, {len(plan['edits'])} edits, "
        f"telemetry {plan['telemetry']}")
    if not plan["new_modules"] and not plan["edits"]:
        return {"request": request, "plan": plan, "status": "nothing_to_build", "version": before}

    # the feature's modules become part of the spec, so later iterations and fixes know about them
    telemetry_note = f" Bump ForgeTelemetry counters: {', '.join(plan['telemetry'])}." if plan["telemetry"] else ""
    for m in plan["new_modules"]:
        m["purpose"] = f"Feature: {request.strip()} -- {m['purpose']}{telemetry_note}"
    spec.setdefault("modules", []).extend(plan["new_modules"])
    spec.setdefault("features", []).append({"request": request.strip(), "plan": plan, "ts": now_iso()})
    spec.setdefault("acceptance", []).extend(plan["acceptance"])
    store.save_spec(spec)
    run.spec = spec

    # New modules (as a dependency DAG, each compiled as soon as it is written) and the hook-in edits to
    # existing files all go out at once: an edit only needs the planned file names, not their code.
    planned = [m["path"] for m in topo_order(plan["new_modules"])]
    edited: list[str] = []
    edit_skips: list[dict] = []

    async def edit_one(e: dict) -> None:
        old = run.read(e["path"])
        rewrite = roles.patch_file if len(old.splitlines()) > PATCH_ABOVE_LINES else roles.fix_file
        problem = (f"Feature to add: {request.strip()}\nChange needed in this file: {e['change']}\n"
                   f"New feature files: {', '.join(planned) or '(none)'}.{telemetry_note}")
        try:
            new = await run.call("patcher" if rewrite is roles.patch_file else "fixer", f"{e['path']} (feature)",
                                 rewrite, e["path"], old, problem, spec.get("pitch", ""), lessons, session_id=session)
        except (LLMError, Exception) as err:  # noqa: BLE001
            edit_skips.append({"path": e["path"], "error": str(err)[:200]})
            return
        why = destructive(old, new)
        if why:
            edit_skips.append({"path": e["path"], "error": why})
            return
        run.write(e["path"], new)
        edited.append(e["path"])

    async def edit_file(edits: list[dict]) -> None:
        for e in edits:  # several edits to one file: one after another, each on the last one's result
            await edit_one(e)

    by_file: dict[str, list[dict]] = {}
    for e in plan["edits"]:
        by_file.setdefault(e["path"], []).append(e)
    with run.stage("feature: build + edits"):
        (built, skipped), _ = await asyncio.gather(
            run.build_modules(plan["new_modules"], session_id=session, lessons=lessons, spec=spec),
            asyncio.gather(*(edit_file(es) for es in by_file.values())))
    order = [e["path"] for e in plan["edits"]]
    edited.sort(key=order.index)
    skipped += edit_skips

    with run.stage("feature: compile"):
        remaining = await run.compile_fix({"fixes": [], "steps": []}, only=set(built + edited) or None)
    version = versions.snapshot(f"feature: {request.strip()[:120]} ({len(built)} new, {len(edited)} edited)")
    log(f"[feature] built {built}, edited {edited}, skipped {len(skipped)}, compile errors {len(remaining)} "
        f"-> {version}")

    # the game changed: later rollbacks compare only against iterations from here on
    state = store.load_state()
    state["rollback_floor"] = store.next_iteration(state)
    store.save_state(state)

    verified = None
    if iterations > 0:
        await run.iterate(iterations, use_studio)
        last = store.last_iteration(store.load_state())
        report = store.load_iteration_json(last, "report.json", {}) if last is not None else {}
        counters = (report or {}).get("counters") or {}
        if plan["telemetry"] and use_studio:
            feature = {"request": request, "plan": plan}
            verified = feature_verified(feature, counters, (report or {}).get("ui_presses") or [])
            log(f"[feature] telemetry {dict((t, counters.get(t)) for t in plan['telemetry'])}"
                f"{', needs a tester UI press' if feature_has_ui(feature) else ''} -> "
                f"{'verified' if verified else 'not seen in the playtest'}")
    run.save_timings()
    polished = await polish_feature(settings, slug, cycles=polish, log=log) if polish > 0 and use_studio else []
    if polished:
        verified = polished[-1].get("feature_verified", verified)
    result = {"request": request.strip(), "plan": plan, "built": built, "edited": edited, "skipped": skipped,
              "compile_errors": [list(x) for x in remaining], "version": version, "before": before,
              "verified": verified, "polish": [{k: c.get(k) for k in ("cycle", "open", "code_kept", "code_tried",
                                                                       "feature_verified")} for c in polished],
              "ts": now_iso()}
    with (store.dir / "features.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(result) + "\n")
    return result


async def polish_feature(settings: Settings, slug: str, *, cycles: int, playtest: Any = None, harness: Any = None,
                         llm: Any = None, log: Callable[[str], None] = print) -> list[dict]:
    """End to end after a build: AI testers play inside a round, the auditor checks every acceptance item
    (the feature's included), and investigate -> fix -> verify runs, cycle after cycle, until nothing high
    or medium is open. Each cycle also checks the feature's planned counters."""
    import os

    from forge.improve import ImproveStore, round_starting, run_cycle
    from forge.llm import make_llm

    spec = RunStore(settings, slug).load_spec()
    latest = (spec.get("features") or [{}])[-1]
    telemetry = list((latest.get("plan") or {}).get("telemetry", []))
    focus = feature_focus(latest) if latest else None
    llm = llm or make_llm(settings, log_path=ImproveStore(settings, slug).dir / "calls.jsonl")
    results: list[dict] = []

    needs_ui = bool(latest) and feature_has_ui(latest)

    async def go(h, pt):
        for _ in range(max(0, cycles)):
            goal = (f"Play a full round and use the new feature: {latest.get('request', '')}" if latest
                    else "Play a full round and use every feature of the game")
            if needs_ui:
                goal += (". It has on-screen UI: use it like a player, through its buttons (`ui` + press): open "
                         "its panel and press its action buttons (claim, buy, equip), and check what changed")
            cycle = await run_cycle(settings, slug, llm=llm, harness=h, playtest=pt, faults=[], goal=goal,
                                    rounds=1, steps=12, fix=True, max_fixes=3, edit_human=True, log=log,
                                    focus=focus)
            peaks: dict = {}
            presses: list[dict] = []
            for d in cycle.get("before", []):
                for k, v in (d.get("counters") or {}).items():
                    peaks[k] = max(peaks.get(k, 0), v or 0)
                presses += d.get("ui_presses") or []
            cycle["feature_verified"] = feature_verified(latest, peaks, presses) if latest else False
            cycle["feature_ui_presses"] = len(feature_ui_presses(latest, presses)) if needs_ui else None
            log(f"[feature] polish cycle {cycle['cycle']}: open {cycle['open']}, kept "
                f"{cycle['code_kept']}/{len(cycle.get('code_fixes') or [])}, feature counters "
                f"{dict((t, peaks.get(t)) for t in telemetry)}"
                + (f", feature UI presses that fired {cycle['feature_ui_presses']}" if needs_ui else ""))
            results.append(cycle)
            if cycle["backlog"]:
                log(f"[feature] {len(cycle['backlog'])} anomalies outside this feature left for `forge fix`")
            if cycle["open"] == 0 and (cycle["feature_verified"] or not telemetry):
                log(f"[feature] done in {len(results)} polish round(s): feature verified, nothing open for it")
                break

    if harness is not None:
        await go(harness, playtest)
        return results
    from forge.studio import Studio
    from mubit_tester.ai import multi_playtest
    from mubit_tester.harness import Harness

    async with Studio(settings) as studio:
        await studio.select(os.environ.get("FORGE_STUDIO") or None)
        await go(Harness(studio), playtest or round_starting(multi_playtest, seconds=180))
    return results


def feature_focus(feature: dict) -> Callable[[dict], bool]:
    """Anomalies that belong to a feature: they name one of its files, counters or key request words.
    Generic: built from the feature's own plan, nothing per game."""
    tokens = feature_tokens(feature)

    def belongs(anomaly: dict) -> bool:
        text = " ".join(str(anomaly.get(k, "")) for k in ("title", "system", "observed", "expected")).lower()
        return any(t in text for t in tokens)
    return belongs


_UI_STEM = re.compile(r"(ui|gui|hud|menu|panel|screen|shop|window)", re.IGNORECASE)


def feature_has_ui(feature: dict) -> bool:
    """The feature ships client UI: a new or edited client script, or a module named like UI."""
    plan = feature.get("plan") or {}
    paths = [str(m.get("path", "")) for m in plan.get("new_modules") or []]
    paths += [str(e.get("path", "")) for e in plan.get("edits") or []]
    for path in paths:
        stem = path.rsplit("/", 1)[-1].split(".")[0]
        if path.startswith("StarterPlayerScripts/") or path.startswith("StarterGui/") or _UI_STEM.search(stem):
            return True
    return False


def feature_ui_presses(feature: dict, presses: list[dict]) -> list[dict]:
    """Real GUI clicks (from playtest digests) that fired a button belonging to this feature."""
    tokens = feature_tokens(feature)
    hits = []
    for p in presses or []:
        if not isinstance(p, dict) or p.get("fired") is not True:
            continue
        text = " ".join(str(p.get(k) or "") for k in ("text", "path", "gui")).lower()
        if any(t in text for t in tokens):
            hits.append(p)
    return hits


def feature_verified(feature: dict, counters: dict, presses: list[dict]) -> bool:
    """Counters alone can be bumped by server code no player ever reached. A feature with client UI is
    verified only when its planned counters moved AND a tester really clicked one of its buttons."""
    telemetry = list((feature.get("plan") or {}).get("telemetry") or [])
    if not telemetry or not all((counters.get(t) or 0) > 0 for t in telemetry):
        return False
    return not feature_has_ui(feature) or bool(feature_ui_presses(feature, presses))


def feature_tokens(feature: dict) -> set[str]:
    """Lower-case words that name a feature: its file stems (and their CamelCase words), counters and
    long request words."""
    plan = feature.get("plan") or {}
    tokens = set()
    for m in plan.get("new_modules") or []:
        stem = str(m.get("path", "")).rsplit("/", 1)[-1].split(".")[0]
        if stem:
            tokens.add(stem.lower())
            tokens.update(w.lower() for w in re.findall(r"[A-Z][a-z]{3,}", stem))  # BattlePassService -> battle, pass
    for e in plan.get("edits") or []:
        tokens.add(str(e.get("path", "")).rsplit("/", 1)[-1].split(".")[0].lower())
    tokens.update(str(t).lower() for t in plan.get("telemetry") or [])
    tokens.update(w.lower() for w in re.findall(r"[A-Za-z]{5,}", str(feature.get("request", ""))))
    tokens -= {"service", "controller", "config", "client", "server", "players", "player", "game", "games"}
    return tokens
