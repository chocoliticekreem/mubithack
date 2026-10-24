"""`forge levels`: the level_designer Mubit task writes an obby's stages as data, one zone per call.

    forge levels <slug> [--zones a-b] [--stages-per-zone 20] [--total-zones N]

Zone z holds stages (z-1)*S+1 .. z*S. Per zone: one level_designer call (forge/prompts/level_designer.md; the
game, the zone, a difficulty target per stage, the mechanics to introduce, the kinds and the jump limits all
go in the user message) -> forge/obby.py validates every jump -> the exact errors go back to the SAME Mubit
task as a correction, up to CORRECTIONS times (each one a training example) -> a stage still invalid after
that becomes obby.fallback_stage (reported, never silent) -> written as runs/<slug>/levels/zone-NN.json (the
record) and game/ReplicatedStorage/Levels/ZoneNN.luau (the data module ObbyKit builds).

Resumable: a zone whose JSON exists and validates is skipped (its .luau re-rendered when stale). Every run
installs the latest ObbyKit into the game (director.ensure_kit) and the obby genre checks with the spec's
stage count. spec["levels"] = {"zones", "stages_per_zone", "plan": [{zone, name, theme, kinds, stages,
written, request_ids, corrections, fallback}]}; a plan entry written by hand ({zone, name, theme}) is kept.
"""

from __future__ import annotations

import json
import math
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from forge import director, obby
from forge.config import Settings
from forge.llm import LLMError
from forge.memory import RunStore

ROLE = "level_designer"
CORRECTIONS = 2
# Measured on Mubit (claude-sonnet-5-5): a 10-stage zone is ~5.5k chars of JSON but ~10.7k output tokens, as the
# model reasons first; a 20-stage zone needs about twice that. Replies stream (MubitLLM), so a high cap is safe.
MAX_TOKENS = 32_000
DEFAULT_STAGES_PER_ZONE = 20
MAX_ERRORS_SHOWN = 60
PREVIOUS_CHARS = 9000

# Mechanics in the order a course introduces them (a new one every few stages), with the kinds they use.
MECHANICS: list[tuple[str, str, tuple[str, ...]]] = [
    ("platform", "plain platforms with comfortable gaps", ("platform",)),
    ("zigzag", "platforms zigzagging left and right with side offsets", ("platform",)),
    ("lava", "lava strips to jump over between platforms", ("lava",)),
    ("climb", "rises of 3-5 studs in a row", ("platform",)),
    ("moving", "moving platforms that ferry you across a long gap", ("moving",)),
    ("narrow beams", "narrow 2-3 stud beams", ("platform",)),
    ("disappearing", "disappearing tiles", ("disappearing",)),
    ("drop", "drops of 6-15 studs onto smaller platforms", ("platform",)),
    ("jumppad", "jump pads launching you up to high platforms", ("jumppad",)),
    ("round platforms", "round platforms", ("platform",)),
    ("conveyor", "conveyors (forward first, later back and sideways)", ("conveyor",)),
    ("elevator", "moving platforms going up and down", ("moving",)),
    ("trampoline", "trampolines", ("trampoline",)),
    ("tile wave", "disappearing tiles in a staggered wave", ("disappearing",)),
    ("spinner", "spinners: jump the spinning bar", ("spinner",)),
    ("sideways mover", "moving platforms sliding sideways", ("moving",)),
    ("turntable", "turntables", ("turntable",)),
    ("bounce chain", "chains of trampolines", ("trampoline",)),
    ("pendulum", "pendulum bridges", ("pendulum",)),
    ("gauntlet", "gauntlets combining three or more mechanics", ()),
]


def zone_range(zone: int, per_zone: int) -> tuple[int, int]:
    return (zone - 1) * per_zone + 1, per_zone


def parse_zones(text: str) -> tuple[int, int]:
    """'3' -> (3, 3); '1-10' -> (1, 10)."""
    a, _, b = str(text).partition("-")
    lo, hi = int(a), int(b or a)
    if lo < 1 or hi < lo:
        raise ValueError(f"bad zone range {text!r}: use a or a-b with 1 <= a <= b")
    return lo, hi


def difficulty(stage: int, total: int, per_zone: int) -> int:
    """1-10: rises across the course and within each zone; every 5th stage of a zone is a breather and the
    zone's last stage is its finale."""
    p = (stage - 1) / max(1, total - 1)
    i = (stage - 1) % per_zone
    q = i / max(1, per_zone - 1)
    d = 2 + 6 * p + 2 * (q - 0.5)
    if i == per_zone - 1:
        d += 1.5
    elif i % 5 == 4:
        d -= 2
    return max(1, min(10, round(d)))


def intro_stages(total: int) -> list[tuple[int, str, str, tuple[str, ...]]]:
    """(first stage, mechanic, hint, kinds) for every mechanic, spread over the first ~70% of the course."""
    n = len(MECHANICS)
    span = max(n, round(0.7 * total))
    return [(1 + (k * span) // n, name, hint, kinds) for k, (name, hint, kinds) in enumerate(MECHANICS)]


def _plan(spec: dict) -> dict[int, dict]:
    return {int(p["zone"]): p for p in (spec.get("levels") or {}).get("plan") or []
            if isinstance(p, dict) and str(p.get("zone", "")).isdigit()}


def zone_message(spec: dict, zone: int, total_zones: int, per_zone: int) -> str:
    first, count = zone_range(zone, per_zone)
    last = first + count - 1
    total = total_zones * per_zone
    doc = spec.get("director") or {}
    style = doc.get("visual_style") or {}
    planned = _plan(spec).get(zone) or {}
    parts = ["## Game\n"
             f"title: {spec.get('title') or spec.get('slug')}\npitch: {str(spec.get('pitch') or '')[:400]}\n"
             f"core loop: {str(spec.get('core_loop') or '')[:600]}"
             + (f"\nfantasy: {str(doc.get('fantasy'))[:300]}" if doc.get("fantasy") else "")
             + (f"\nstyle: {json.dumps({k: style.get(k) for k in ('palette', 'mood', 'materials') if style.get(k)})[:300]}"
                if style else "")
             + f"\nThe course has {total_zones} zones of {per_zone} stages ({total} stages), straight ahead from the lobby; "
               "each zone is a themed section with its own gate."]
    head = f"## Zone to design\nZone {zone} of {total_zones}: stages {first} to {last} ({count} stages)."
    if planned.get("name"):
        head += f"\nPlanned name: {planned['name']}" + (f"; theme: {planned['theme']}" if planned.get("theme") else "")
    else:
        head += "\nChoose a name and theme for this zone that fit the game and differ from the zones before it."
    parts.append(head)
    diffs = " ".join(f"{n}:{difficulty(n, total, per_zone)}" for n in range(first, last + 1))
    parts.append("## Difficulty target per stage (1 = very easy, 10 = expert)\n" + diffs + "\n"
                 "1-3: wide platforms, gaps 3-6, rises 0-2, slow movers, tiles solid 3 s or more. "
                 "4-6: gaps 6-8, rises up to 4, two mechanics per stage. "
                 "7-8: gaps 8-9, rises 4-5, narrow platforms, faster timings. "
                 "9-10: near the limits, three or more mechanics. "
                 f"Stage {last} is the zone's finale; every 5th stage of a zone is a breather.")
    intro = intro_stages(total)
    before = [m for m in intro if m[0] < first]
    new = [m for m in intro if first <= m[0] <= last]
    usable = {k for m in before + new for k in m[3]} | {"platform"}
    if any(not m[3] for m in before + new):  # a gauntlet: every kind
        usable = set(obby.KIND_ORDER)
    allowed = ["checkpoint"] + [k for k in obby.KIND_ORDER if k in usable]
    mech = ["## Mechanics"]
    if before:
        mech.append("Already introduced (use them freely): " + ", ".join(m[1] for m in before) + ".")
    if new:
        mech.append("New in this zone, each first alone in an easy stage at (or near) the stage given:\n"
                    + "\n".join(f"- stage {m[0]}: {m[2]}" for m in new))
    mech.append("Kinds you may use in this zone: " + ", ".join(allowed) + ".")
    parts.append("\n".join(mech))
    done = [p for z, p in sorted(_plan(spec).items()) if z != zone and p.get("written")]
    if done:
        parts.append("## Zones already designed (one course: keep it consistent, never repeat their names)\n"
                     + "\n".join(f"- Zone {p['zone']} \"{p.get('name')}\" (stages {p.get('stages', ['?', '?'])[0]}-"
                                 f"{p.get('stages', ['?', '?'])[-1]}): {str(p.get('theme') or '')[:120]}; kinds: "
                                 f"{', '.join(p.get('kinds') or [])}" for p in done[-12:]))
    parts.append("## Obstacle kinds (parameters: default [min, max])\n" + obby.kinds_doc())
    parts.append("## Jump limits the validator enforces\n" + obby.limits_doc())
    parts.append(f"Return only the zone JSON object with all {count} stages ({first} to {last}).")
    return "\n\n".join(parts)


def correction_message(user: str, zone: dict, errors: list[str], first: int, count: int) -> str:
    bad = obby.bad_stages(zone, first, count)
    shown = errors[:MAX_ERRORS_SHOWN] + ([f"... {len(errors) - MAX_ERRORS_SHOWN} more"]
                                         if len(errors) > MAX_ERRORS_SHOWN else [])
    by_n = {s["stage"]: s for s in zone.get("stages") or []}
    prev = "\n".join(json.dumps(by_n[n], ensure_ascii=False) for n in bad if n in by_n)
    if len(prev) > PREVIOUS_CHARS:
        prev = prev[:PREVIOUS_CHARS] + "\n...[truncated]"
    tail = ("## Your previous level data has errors (the validator's exact messages)\n"
            + "\n".join(f"- {e}" for e in shown)
            + ("\n\n## Your previous version of those stages\n" + prev if prev else "")
            + f"\n\nFix every error above with margin. Reply with the same JSON object shape containing only the "
              f"corrected stages ({', '.join(map(str, bad))}), each with all of its pieces.")
    from forge.roles import MAX_USER_CHARS, _truncate
    return _truncate(user, max(4000, MAX_USER_CHARS - len(tail) - 100), label="message") + "\n\n" + tail


def kinds_used(zone: dict) -> list[str]:
    used = {p.get("kind") for s in zone.get("stages") or [] for p in s.get("pieces") or []}
    return [k for k in obby.KIND_ORDER if k in used]


def design_zone(llm: Any, spec: dict, zone: int, *, total_zones: int, per_zone: int, session_id: str,
                log: Callable[[str], None] = print, corrections: int = CORRECTIONS) -> tuple[dict, dict]:
    """One zone: the level_designer call, up to `corrections` correction calls in the same task, fallbacks
    for what is still broken. -> (zone data, record {zone, first, count, attempts, corrections, fallback})."""
    first, count = zone_range(zone, per_zone)
    user = zone_message(spec, zone, total_zones, per_zone)
    obj, res = llm.complete_json(ROLE, user, session_id=session_id, required=["stages"], max_tokens=MAX_TOKENS)
    data = obby.normalize_zone(obj, zone, first, count)
    errors = obby.validate_zone(data, first, count)
    attempts = [{"request_id": res.request_id, "errors": len(errors), "first_errors": errors[:5]}]
    log(f"[levels] zone {zone} \"{data['name']}\": {len(data['stages'])} stages, {len(errors)} validator errors")
    for _ in range(corrections):
        if not errors:
            break
        obj, res = llm.complete_json(ROLE, correction_message(user, data, errors, first, count), session_id=session_id,
                                     required=["stages"], max_tokens=MAX_TOKENS)
        data = obby.merge_stages(data, obj)
        errors = obby.validate_zone(data, first, count)
        attempts.append({"request_id": res.request_id, "errors": len(errors), "first_errors": errors[:5]})
        log(f"[levels] zone {zone} correction {len(attempts) - 1}: {len(errors)} validator errors left")
    data["stages"] = [s for s in data["stages"] if first <= s["stage"] < first + count]
    total = total_zones * per_zone
    fallback = obby.bad_stages(data, first, count)
    if fallback:
        by_n = {s["stage"]: s for s in data["stages"]}
        for n in fallback:
            by_n[n] = obby.fallback_stage(n, difficulty(n, total, per_zone))
        data["stages"] = [by_n[n] for n in sorted(by_n)]
        log(f"[levels] zone {zone}: stages {', '.join(map(str, fallback))} still invalid after {corrections} "
            "corrections: replaced with fallback stages")
    return data, {"zone": zone, "first": first, "count": count, "attempts": attempts,
                  "corrections": len(attempts) - 1, "fallback": fallback}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _llm_calls(path: Path) -> int:
    try:
        return sum(1 for ln in path.read_text(encoding="utf-8").splitlines() if f'"role": "{ROLE}"' in ln)
    except OSError:
        return 0


def run_levels(settings: Settings, slug: str, *, llm: Any = None, zones: tuple[int, int] | None = None,
               stages_per_zone: int | None = None, total_zones: int | None = None,
               log: Callable[[str], None] = print) -> dict:
    """Design (or skip, when already valid) every zone in `zones` and write the game's level data."""
    store = RunStore(settings, slug)
    if not store.exists():
        raise FileNotFoundError(f"no game {slug!r} in {settings.runs_dir}")
    spec = store.load_spec()
    lv = spec.setdefault("levels", {})
    per_zone = int(stages_per_zone or lv.get("stages_per_zone") or DEFAULT_STAGES_PER_ZONE)
    rec_dir = store.dir / "levels"
    written_before = sorted(rec_dir.glob("zone-*.json"))
    if written_before and lv.get("stages_per_zone") and int(lv["stages_per_zone"]) != per_zone:
        raise SystemExit(f"{slug} already has zones of {lv['stages_per_zone']} stages; keep --stages-per-zone "
                         f"{lv['stages_per_zone']} (or delete {rec_dir})")
    lo, hi = zones or (1, int(lv.get("zones") or 0))
    if hi < 1:
        raise SystemExit("no zones planned yet: pass --zones a-b (and --total-zones for the whole course)")
    total_zones = max(int(total_zones or 0), int(lv.get("zones") or 0), hi)
    lv.update(zones=total_zones, stages_per_zone=per_zone)
    lv.setdefault("plan", [])
    kit_files = director.ensure_kit(spec, store.game_dir, ["ObbyKit"])
    store.save_spec(spec)
    log(f"[levels] {slug}: zones {lo}-{hi} of {total_zones}, {per_zone} stages each; kit: {', '.join(kit_files)}")
    calls_before = _llm_calls(store.calls_log)
    if llm is None:
        from forge.llm import make_llm
        llm = make_llm(settings, store.calls_log)
    out: list[dict] = []
    levels_dir = store.game_dir / obby.LEVELS_DIR
    for zone in range(lo, hi + 1):
        first, count = zone_range(zone, per_zone)
        rec_path = rec_dir / f"zone-{zone:02d}.json"
        luau_path = levels_dir / f"Zone{zone:02d}.luau"
        if rec_path.exists():
            data = json.loads(rec_path.read_text(encoding="utf-8"))
            if not obby.validate_zone(data, first, count):
                text = obby.render_zone_luau(data)
                if not luau_path.exists() or luau_path.read_text(encoding="utf-8") != text:
                    luau_path.parent.mkdir(parents=True, exist_ok=True)
                    luau_path.write_text(text, encoding="utf-8")
                log(f"[levels] zone {zone} \"{data.get('name')}\": already written and valid, skipped")
                out.append({"zone": zone, "status": "skipped", "name": data.get("name"), "first": first, "count": count})
                continue
        try:
            data, rec = design_zone(llm, spec, zone, total_zones=total_zones, per_zone=per_zone, session_id=slug, log=log)
        except LLMError as e:  # one zone's failed call must not lose the others; a re-run retries it
            log(f"[levels] zone {zone} FAILED: {e}")
            out.append({"zone": zone, "status": "failed", "name": "", "first": first, "count": count, "error": str(e)[:300]})
            continue
        rec_dir.mkdir(parents=True, exist_ok=True)
        rec_path.write_text(json.dumps(data, indent=1, ensure_ascii=False), encoding="utf-8")
        luau_path.parent.mkdir(parents=True, exist_ok=True)
        luau_path.write_text(obby.render_zone_luau(data), encoding="utf-8")
        plan = [p for p in lv["plan"] if not (isinstance(p, dict) and p.get("zone") == zone)]
        plan.append({"zone": zone, "name": data["name"], "theme": data.get("theme", ""), "kinds": kinds_used(data),
                     "stages": [first, first + count - 1], "written": _now(),
                     "request_ids": [a["request_id"] for a in rec["attempts"]], "corrections": rec["corrections"],
                     "fallback": rec["fallback"]})
        lv["plan"] = sorted(plan, key=lambda p: int(p.get("zone") or 0))
        store.save_spec(spec)
        with (rec_dir / "log.jsonl").open("a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": _now(), **rec}, ensure_ascii=False) + "\n")
        out.append({"zone": zone, "status": "written", "name": data["name"], "first": first, "count": count,
                    "corrections": rec["corrections"], "fallback": rec["fallback"],
                    "errors": [a["errors"] for a in rec["attempts"]]})
    director.install_genre_checks(spec, store.game_dir)
    compile_errors = _compile(levels_dir)
    stages = sum(len(json.loads(p.read_text(encoding="utf-8")).get("stages") or [])
                 for p in sorted(rec_dir.glob("zone-*.json")))
    return {"slug": slug, "zones": out, "stages": stages, "planned": total_zones * per_zone,
            "calls": _llm_calls(store.calls_log) - calls_before, "compile_errors": compile_errors,
            "ok": not compile_errors and all(not z.get("fallback") and z["status"] != "failed" for z in out)}


def _compile(levels_dir: Path) -> list[str]:
    from forge.scenarios import luau_compiler
    import subprocess

    exe = luau_compiler()
    if not exe or not levels_dir.is_dir():
        return []
    errors = []
    for p in sorted(levels_dir.glob("*.luau")):
        r = subprocess.run([exe, "--null", str(p)], capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            errors.append(f"{p.name}: {(r.stderr or r.stdout).strip()[:300]}")
    return errors


def render_summary(res: dict) -> str:
    lines = [f"{res['slug']}: {res['stages']}/{res['planned']} stages written, {res['calls']} level_designer calls"]
    for z in res["zones"]:
        if z["status"] == "skipped":
            lines.append(f"  zone {z['zone']:>2} \"{z['name']}\": skipped (already valid)")
            continue
        if z["status"] == "failed":
            lines.append(f"  zone {z['zone']:>2}: FAILED ({z['error']}); run again to retry it")
            continue
        fixes = f", {z['corrections']} correction(s), errors per attempt {z['errors']}" if z.get("corrections") else ""
        fb = f", FALLBACK stages {z['fallback']}" if z.get("fallback") else ""
        lines.append(f"  zone {z['zone']:>2} \"{z['name']}\": stages {z['first']}-{z['first'] + z['count'] - 1}"
                     f"{fixes}{fb}")
    for e in res.get("compile_errors") or []:
        lines.append(f"  COMPILE {e}")
    return "\n".join(lines)
