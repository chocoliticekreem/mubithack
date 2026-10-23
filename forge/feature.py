"""`forge feature <slug> "<request>"`: the agent adds a feature to an existing game, end to end.

    planner (Mubit task)  -> new modules + small hook-in edits + telemetry + acceptance
    coder                 -> writes each new module (agent-owned files)
    patcher / fixer       -> each hook-in edit (exact edits for big files; destructive guard applies)
    compile check + fixer -> then a saved version "feature: <request>"
    iterate (optional)    -> playtest, critic, fixer, reflector, auto-rollback on a score drop
    verified              -> the feature's telemetry counters appear in the last playtest

Everything happens in runs/<slug>/game, versioned (forge versions / forge rollback).
"""

from __future__ import annotations

import json
from typing import Any, Callable

from forge.config import Settings
from forge.llm import LLMError
from forge.memory import RunStore, now_iso, read_lessons
from forge.versions import GameVersions

PLAN_KEYS = ["summary", "new_modules"]
MAX_NEW_MODULES = 3
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
                      iterations: int = 1, use_studio: bool = True,
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
    run = Run(settings, store, llm, ui)
    spec = store.load_spec()
    run.spec = spec
    versions = GameVersions(store.game_dir)
    before = versions.snapshot(f"before feature: {request.strip()[:120]}")
    session = f"feature-{slug}"
    lessons = read_lessons(settings)

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

    built, edited, skipped = [], [], []
    for m in topo_order(plan["new_modules"]):
        deps = {d: run.read(d) for d in m["depends"] if run.read(d)}
        try:
            src = await run.call("coder", m["path"], roles.code_module, spec, m, deps, lessons, session_id=session)
            run.write(m["path"], src)
            built.append(m["path"])
        except Exception as e:  # noqa: BLE001 - logged by run.call; the iteration's critic will see the gap
            skipped.append({"path": m["path"], "error": str(e)[:200]})

    for e in plan["edits"]:
        old = run.read(e["path"])
        rewrite = roles.patch_file if len(old.splitlines()) > PATCH_ABOVE_LINES else roles.fix_file
        problem = (f"Feature to add: {request.strip()}\nChange needed in this file: {e['change']}\n"
                   f"New feature files: {', '.join(built) or '(none)'}.{telemetry_note}")
        try:
            new = await run.call("patcher" if rewrite is roles.patch_file else "fixer", f"{e['path']} (feature)",
                                 rewrite, e["path"], old, problem, spec.get("pitch", ""), lessons, session_id=session)
        except (LLMError, Exception) as err:  # noqa: BLE001
            skipped.append({"path": e["path"], "error": str(err)[:200]})
            continue
        why = destructive(old, new)
        if why:
            skipped.append({"path": e["path"], "error": why})
            continue
        run.write(e["path"], new)
        edited.append(e["path"])

    remaining = await run.compile_fix({"fixes": [], "steps": []}, only=set(built + edited) or None)
    version = versions.snapshot(f"feature: {request.strip()[:120]} ({len(built)} new, {len(edited)} edited)")
    log(f"[feature] built {built}, edited {edited}, skipped {len(skipped)}, compile errors {len(remaining)} "
        f"-> {version}")

    verified = None
    if iterations > 0:
        await run.iterate(iterations, use_studio)
        last = store.last_iteration(store.load_state())
        report = store.load_iteration_json(last, "report.json", {}) if last is not None else {}
        counters = (report or {}).get("counters") or {}
        if plan["telemetry"] and use_studio:
            verified = all((counters.get(t) or 0) > 0 for t in plan["telemetry"])
            log(f"[feature] telemetry {dict((t, counters.get(t)) for t in plan['telemetry'])} -> "
                f"{'verified' if verified else 'not seen in the playtest'}")
    result = {"request": request.strip(), "plan": plan, "built": built, "edited": edited, "skipped": skipped,
              "compile_errors": [list(x) for x in remaining], "version": version, "before": before,
              "verified": verified, "ts": now_iso()}
    with (store.dir / "features.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(result) + "\n")
    return result
