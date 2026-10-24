"""Forge quality brain, part 1: the game director and the art/asset pass.

idea -> director (Mubit task `director`, forge/prompts/director.md) -> design doc
     -> designer (existing frozen task) with the doc in its USER message -> richer spec
     -> art pass: ReplicatedStorage/GameAssets.luau (palette, verified sounds, particles, juice helpers)
        written into the game before the coder runs, so every module can require real sounds and effects.

All per-call text (idea, genre lessons, doc, scope) lives in user messages; the prompt files are fixed.

    genre_lessons(text) -> str                         curated forge/lessons_library/*.md that fit the idea
    direct(llm, idea, lessons, *, session_id) -> dict  the design doc (normalized)
    design_from_doc(llm, idea, doc, lessons, *, session_id) -> dict   spec with spec["director"], ["first_60s"]
    plan(llm, idea, lessons, *, session_id) -> dict    direct + design_from_doc
    coder_notes(spec, lessons) -> str                  style + juice block prepended to coder/fixer lessons
    install_kit(spec, game_dir) -> list[str]           writes the prebuilt kit files (GameAssets.luau + kit modules)
    spec_stats(spec) -> dict                           module/juice/beat counts for before/after reports

Kit modules (forge/kit/modules/index.json + <Name>.luau): prebuilt, tested modules a game gets by genre or
keyword (match_kit_modules). The designer learns they exist (scope block), the spec lists them as prebuilt
modules with "kit": <name>, install_kit copies them into the game (and their genre's checks from
forge/genre_checks/<genre>/ into runs/<slug>/checks/), and every coder call lists their API
(kit_api_block). Adding a module = its file + one index entry.
"""

from __future__ import annotations

import functools
import json
import re
from pathlib import Path

from forge import roles, ui_kit
from forge.llm import LLM, LLMError
from forge.obby import LEVELS_DIR

LIBRARY = Path(__file__).parent / "lessons_library"
KIT_DIR = Path(__file__).parent / "kit"
KIT_MODULES_DIR = KIT_DIR / "modules"
GENRE_CHECKS_DIR = Path(__file__).parent / "genre_checks"
GAME_ASSETS = "ReplicatedStorage/GameAssets.luau"
DOC_KEYS = ["fantasy", "core_loop", "systems", "juice", "first_60_seconds", "visual_style", "module_budget"]
MIN_MODULES, MAX_MODULES = 4, 12
TEMPLATE_EXTRA_MODULES = 2  # coder-written modules a template game may add
PLAN_MAX_TOKENS = 16_000  # doc and spec are long, and the model reasons first (6000 was cut off)

# genre -> words in the idea that pick it
GENRES = {
    "tycoon": ("tycoon", "dropper", "conveyor", "factory", "plot", "idle", "business", "rebirth"),
    "obby": ("obby", "obstacle", "parkour", "checkpoint", "tower", "jump", "stages", "climb"),
    "simulator": ("simulator", "sim", "backpack", "clicker", "click", "gather", "mine", "mining", "pets",
                  "zones", "sell"),
}


# ------------------------------------------------------------------------------- genre lessons


@functools.cache
def _lesson_file(name: str) -> str:
    p = LIBRARY / f"{name}.md"
    return p.read_text(encoding="utf-8").strip() if p.exists() else ""


def genres(text: str) -> list[str]:
    words = set(re.findall(r"[a-z]+", (text or "").lower()))
    return [g for g, kws in GENRES.items() if words & set(kws)]


def genre_lessons(text: str) -> str:
    """Curated lessons for this idea: the genre files it matches, then the fun rules every game gets."""
    parts = [_lesson_file(g) for g in genres(text)] + [_lesson_file("fun")]
    return "\n\n".join(p for p in parts if p)


def _merge_lessons(curated: str, learned: str) -> str:
    learned = (learned or "").strip()
    return curated + ("\n\n# Lessons from past builds\n" + learned if learned else "")


# ------------------------------------------------------------------------------- sound kit


@functools.cache
def sound_kit() -> dict:
    """forge/kit/sounds.json: {name: {id, describe, keywords, volume}}; ids are verified to play in Studio."""
    return json.loads((KIT_DIR / "sounds.json").read_text(encoding="utf-8"))["sounds"]


def match_sound(text: str) -> str:
    """Best kit sound for a description like 'short bright coin ding'."""
    words = set(re.findall(r"[a-z]+", (text or "").lower()))
    best, score = "Pop", 0
    for name, s in sound_kit().items():
        hits = len(words & set(s["keywords"])) + (3 if name.lower() in words else 0)
        if hits > score:
            best, score = name, hits
    return best


def sound_table_block() -> str:
    lines = ["## Sound table (ReplicatedStorage/GameAssets.luau: GameAssets.play(name, parentOrNil))"]
    lines += [f"- {n}: {s['describe']}" for n, s in sound_kit().items()]
    return "\n".join(lines) + "\n"


# ------------------------------------------------------------------------------- kit modules


@functools.cache
def kit_index() -> tuple[dict, ...]:
    """forge/kit/modules/index.json entries: {name, path_in_game, genres, keywords, describe, api}."""
    path = KIT_MODULES_DIR / "index.json"
    if not path.exists():
        return ()
    return tuple(json.loads(path.read_text(encoding="utf-8")).get("modules") or [])


def kit_paths() -> set[str]:
    return {e["path_in_game"] for e in kit_index()}


def match_kit_modules(text: str) -> list[dict]:
    """Kit modules for a game described by `text`: its genre (gaps.detect_genre) is one of the module's
    genres ("*" = every game), or one of the module's keywords appears in it. A module with `genres_only`
    matches only games of those genres, and a matched module brings every module it `requires`."""
    from forge.gaps import detect_genre

    low = " " + " ".join(re.findall(r"[a-z0-9]+", (text or "").lower())) + " "
    genre = detect_genre({"title": text})
    picked = set()
    for e in kit_index():
        genres = e.get("genres") or []
        words = [" " + " ".join(re.findall(r"[a-z0-9]+", k.lower())) + " " for k in e.get("keywords") or []]
        if e.get("genres_only") and genre not in e["genres_only"]:
            continue
        if "*" in genres or genre in genres or any(w in low for w in words if w.strip()):
            picked.add(e["name"])
    by_name = {e["name"]: e for e in kit_index()}
    todo = list(picked)
    while todo:
        for need in by_name.get(todo.pop(), {}).get("requires") or []:
            if need not in picked and need in by_name:
                picked.add(need)
                todo.append(need)
    return [e for e in kit_index() if e["name"] in picked]


def kit_module(entry: dict) -> dict:
    """The spec module for a kit entry: prebuilt, never written by the coder or edited by the fixer."""
    return {"path": entry["path_in_game"], "prebuilt": True, "kit": entry["name"], "depends": [],
            "purpose": f"PREBUILT kit module {entry['name']} (do not rewrite): {entry['describe']}"}


def kit_modules_in(spec: dict) -> list[dict]:
    """Index entries of the kit modules a spec lists."""
    names = {m.get("kit") for m in spec.get("modules") or [] if isinstance(m, dict) and m.get("kit")}
    return [e for e in kit_index() if e["name"] in names]


def kit_api_block(spec: dict) -> str:
    """'## Prebuilt kit modules' for coder user messages: every kit module the game has, with its API."""
    entries = kit_modules_in(spec)
    if not entries:
        return ""
    lines = ["## Prebuilt kit modules (already in the game: require them, never rewrite or re-implement them)"]
    for e in entries:
        lines.append(f"### {e['name']}: {e['path_in_game']}\n{e['describe']}")
        lines += [f"- {a}" for a in e.get("api") or []]
    return "\n".join(lines) + "\n"


_COUNT_RX = re.compile(r'\b(?:count|telemetry)\("([a-z0-9_]+)"')


def kit_counters(entries: list[dict]) -> list[str]:
    """Telemetry counters these kit modules fire (count("x") / telemetry("x") in their source), sorted."""
    names = set()
    for e in entries:
        path = KIT_MODULES_DIR / f"{e['name']}.luau"
        if path.exists():
            names |= set(_COUNT_RX.findall(path.read_text(encoding="utf-8")))
    return sorted(names)


def template_block(kits: list[dict]) -> str:
    """'## Prebuilt template' for director and designer user messages when the game is built on a template kit
    (an index entry with "template"): what is already built, and the counters a design may name."""
    tpl = next((e for e in kits if e.get("template")), None)
    if not tpl:
        return ""
    return (f"## Prebuilt template: {tpl['name']} (this game is built on it)\n"
            f"- Already built and tested: {tpl['describe']}\n"
            f"- Forge renders {', '.join(tpl['template']['files'])} from the spec. Design the content (the zones, "
            "their rides and the signature moments of each), not the systems the template already has.\n"
            f"- Plan at most {TEMPLATE_EXTRA_MODULES} extra modules, only for features the template does not do; "
            "each one hooks the kits' APIs.\n"
            f"- first_60_seconds counters must be ones the kits fire: {', '.join(kit_counters(kits))}.\n")


def protected_paths(spec: dict, game_dir: Path) -> set[str]:
    """Game files only Forge's own tools write: kit modules, files a template renders, and the level data
    modules (`forge levels`)."""
    out = {e["path_in_game"] for e in kit_modules_in(spec)}
    out |= {f for e in kit_modules_in(spec) for f in (e.get("template") or {}).get("files") or []}
    levels = Path(game_dir) / LEVELS_DIR
    if levels.is_dir():
        out |= {p.relative_to(game_dir).as_posix() for p in levels.glob("*.luau")}
    return out


_CONSUMER_REF = re.compile(r'^(\s*--\s*consumer:\s*[\w./-]+\.luau):"([^"]+)"\s*$', re.MULTILINE)


def resolve_consumers(body: str, game_dir: Path) -> str:
    """`-- consumer: <file>:"<text>"` -> `-- consumer: <file>:<line>` (the first line of that game file containing
    the text), so a genre check names the kit line it depends on even after the kit changes."""
    def line_of(m: re.Match) -> str:
        head, text = m.group(1), m.group(2)
        rel = head.split(":", 1)[1].strip()
        lines = (Path(game_dir) / rel).read_text(encoding="utf-8").splitlines()
        n = next((i + 1 for i, ln in enumerate(lines) if text in ln), None)
        if n is None:
            raise ValueError(f"genre check consumer {text!r} not found in {rel}")
        return f"{head}:{n}"
    return _CONSUMER_REF.sub(line_of, body)


def expected_stages(spec: dict) -> int:
    lv = spec.get("levels") or {}
    try:
        return max(0, int(lv.get("zones") or 0) * int(lv.get("stages_per_zone") or 0))
    except (TypeError, ValueError):
        return 0


def install_genre_checks(spec: dict, game_dir: Path) -> list[Path]:
    """Copy forge/genre_checks/<genre>/*.luau for the game's kit modules into runs/<slug>/checks/ (beside the
    game folder), with the spec's stage count and the kit's consumer lines filled in. Overwrites them: they
    are Forge's, not the scenarist's. A check whose consumer file is not in this game (it tests a kit module
    the game does not have) is skipped."""
    run_dir = Path(game_dir).parent
    written = []
    genres = sorted({g for e in kit_modules_in(spec) for g in e.get("genres") or [] if g != "*"})
    for genre in genres:
        for src in sorted((GENRE_CHECKS_DIR / genre).glob("*.luau")):
            body = src.read_text(encoding="utf-8").replace("__EXPECTED_STAGES__", str(expected_stages(spec)))
            files = [m.group(1).split(":", 1)[1].strip() for m in _CONSUMER_REF.finditer(body)]
            if not all((Path(game_dir) / f).exists() for f in files):
                continue
            out = run_dir / "checks" / src.name
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(resolve_consumers(body, game_dir), encoding="utf-8")
            written.append(out)
    return written


def ensure_kit(spec: dict, game_dir: Path, names: list[str]) -> list[str]:
    """Add these kit modules to the spec (prebuilt entries, after GameAssets) if missing and install the kit.
    Used by `forge levels` on games built before the kit existed. Returns the game files written."""
    have = {m.get("kit") for m in spec.get("modules") or [] if isinstance(m, dict)}
    add = [kit_module(e) for e in kit_index() if e["name"] in names and e["name"] not in have]
    if add:
        mods = [m for m in spec.get("modules") or [] if isinstance(m, dict)]
        n = 1 if mods and mods[0].get("path") == GAME_ASSETS else 0
        spec["modules"] = mods[:n] + add + mods[n:]
    return install_kit(spec, game_dir)


# ------------------------------------------------------------------------------- director


def _as_list(v) -> list:
    return v if isinstance(v, list) else []


def normalize_doc(doc: dict) -> dict:
    out = dict(doc)
    for k in ("progression", "systems", "juice", "first_60_seconds", "rewards", "sounds", "acceptance"):
        out[k] = _as_list(doc.get(k))
    beats = []
    for b in out["first_60_seconds"]:
        if not isinstance(b, dict) or not b.get("beat"):
            continue
        counter = re.sub(r"[^a-z0-9_]+", "_", str(b.get("counter") or "").lower()).strip("_")
        try:
            t = float(b.get("t") or 0)
        except (TypeError, ValueError):
            t = 0.0
        try:
            mn = max(1, int(b.get("min") or 1))
        except (TypeError, ValueError):
            mn = 1
        beats.append({"t": t, "beat": str(b["beat"]), "counter": counter, "min": mn})
    out["first_60_seconds"] = sorted(beats, key=lambda b: b["t"])
    try:
        budget = int(doc.get("module_budget") or 7)
    except (TypeError, ValueError):
        budget = 7
    out["module_budget"] = max(MIN_MODULES, min(MAX_MODULES, budget))
    vs = doc.get("visual_style")
    out["visual_style"] = vs if isinstance(vs, dict) else {}
    out["sounds"] = [s for s in out["sounds"] if isinstance(s, dict) and s.get("id")]
    for s in out["sounds"]:
        s["id"] = re.sub(r"[^A-Za-z0-9_]", "", str(s["id"])) or "Sound"
        s["kit"] = match_sound(f"{s.get('id')} {s.get('for', '')} {s.get('describe', '')}")
    return out


def direct(llm: LLM, idea: str, lessons: str, *, session_id: str) -> dict:
    curated = genre_lessons(idea)
    user = roles._fit(
        "## Game idea\n"
        f"{roles._truncate(idea.strip(), 3000, label='idea')}\n\n"
        "## Curated genre lessons\n"
        f"{roles._truncate(curated, 6000, label='genre lessons')}\n\n"
        f"{roles._lessons_block(lessons, 4000)}\n"
        f"{sound_table_block()}\n"
        f"{template_block(match_kit_modules(idea))}"
        f"{ui_kit.designer_block()}\n"
        "Return only the design doc JSON object."
    )
    doc, _ = llm.complete_json("director", user, session_id=session_id, required=DOC_KEYS, max_tokens=PLAN_MAX_TOKENS)
    return normalize_doc(doc)


# ------------------------------------------------------------------------------- designer with the doc


def doc_block(doc: dict, limit: int = 11_000) -> str:
    """The doc as compact JSON, one top-level key per line (readable, and ~30% smaller than indented)."""
    keep = {k: doc.get(k) for k in ("fantasy", "core_loop", "progression", "systems", "juice",
                                    "first_60_seconds", "rewards", "visual_style") if doc.get(k)}
    keep["sounds"] = [{"id": s["id"], "for": s.get("for", ""), "kit": s["kit"]} for s in doc.get("sounds") or []]
    text = "\n".join(f"{k}: {json.dumps(v, ensure_ascii=False)}" for k, v in keep.items())
    return roles._truncate(text, limit, label="design doc")


def _scope_block(doc: dict, kits: list[dict] | None = None) -> str:
    n = doc["module_budget"]
    tpl = next((e for e in kits or [] if e.get("template")), None)
    count = (f"- List the template's rendered files ({', '.join(tpl['template']['files'])}) and at most {n} extra "
             "modules; each extra module keeps one clear job and stays under ~300 lines.\n" if tpl else
             f"- Use {max(MIN_MODULES, n - 2)} to {n} modules so every system above has a home; each module keeps one "
             "clear job and stays under ~300 lines.\n")
    kit_lines = "".join(
        f"- `{e['path_in_game']}` is PREBUILT ({e['name']}: {e['describe']}). Do NOT list it in modules and do NOT "
        "plan modules that re-implement what it does; add it to `depends` of every module that uses it.\n"
        for e in kits or [])
    return (
        "## Scope (the director's decision; it overrides the 3-7 module guideline)\n"
        f"{count}"
        f"- `{GAME_ASSETS}` is PREBUILT and always present: do NOT list it in modules, but add it to `depends` "
        "of any module that plays sounds or effects. API: GameAssets.Palette {name: Color3}, "
        "GameAssets.Sounds {name: soundId}, GameAssets.play(name, parent?) -> Sound?, "
        "GameAssets.burst(at: BasePart | Vector3, color: Color3?, count: number?), "
        "GameAssets.shake(intensity?, seconds?) (client only), GameAssets.styleLighting() (server), "
        "GameAssets.part(props) -> Part (never default grey).\n"
        f"{kit_lines}"
        "- Every juice moment above must be named in some module's purpose (the sound name, the effect, the tween).\n"
        "- Every first-60-seconds counter must be bumped by the server and named in acceptance.\n"
        "- One client module builds a styled HUD with the UI kit; world builders use the palette, never default grey.\n"
    )


def _prebuilt_module() -> dict:
    return {"path": GAME_ASSETS, "prebuilt": True, "depends": [],
            "purpose": "PREBUILT (do not rewrite): palette, sound ids, play(name, parent?), burst(at, color?, count?), "
                       "shake(intensity?, seconds?) client-only, styleLighting() server, part(props) -> Part."}


def _attach(spec: dict, doc: dict) -> dict:
    """Prebuilt kit module first, the doc saved on the spec, beats appended to acceptance."""
    mods = [m for m in spec.get("modules") or [] if isinstance(m, dict) and m.get("path") != GAME_ASSETS]
    spec["modules"] = [_prebuilt_module()] + mods
    spec["director"] = doc
    spec["first_60s"] = doc.get("first_60_seconds") or []
    acc = list(spec.get("acceptance") or [])
    for b in spec["first_60s"]:
        if b["counter"]:
            line = f"{b['counter']} counter reaches {b['min']} within {b['t']:g}s ({b['beat']})"
            if not any(b["counter"] in a for a in acc):
                acc.append(line)
    spec["acceptance"] = acc
    return spec


def _kit_beats(beats: list[dict], counters: list[str]) -> list[dict]:
    """A template game's first-60-seconds beats keep only counters its kits fire: an invented counter is dead
    by construction and would send the fix loop after working kit code. The beat itself stays."""
    known = set(counters)
    return [b if not b.get("counter") or b["counter"] in known else {**b, "counter": "", "min": 0} for b in beats]


def _problems(spec: dict, budget: int, rendered: tuple[str, ...] = ()) -> list[str]:
    probs = [p for p in roles.validate_spec(spec) if not p.startswith("too many modules")]
    prebuilt = {GAME_ASSETS} | kit_paths() | set(rendered)
    n = len([m for m in spec.get("modules") or [] if isinstance(m, dict) and m.get("path") not in prebuilt])
    if n > budget + 1:
        probs.append(f"too many modules ({n}); the director's budget is {budget}")
    return probs


def design_from_doc(llm: LLM, idea: str, doc: dict, lessons: str, *, session_id: str) -> dict:
    curated = genre_lessons(idea)
    kits = match_kit_modules(" ".join([idea, str(doc.get("fantasy") or ""), str(doc.get("core_loop") or "")]))
    tpl = next((e for e in kits if e.get("template")), None)
    if tpl:  # the template is the game's wiring: only extras are coder-written
        doc = {**doc, "module_budget": TEMPLATE_EXTRA_MODULES}
        doc["first_60_seconds"] = _kit_beats(doc.get("first_60_seconds") or [], kit_counters(kits))
    user = roles._fit(
        "## Game idea\n"
        f"{roles._truncate(idea.strip(), 2000, label='idea')}\n\n"
        "## Director's design doc (build this game, not a smaller one)\n"
        f"{doc_block(doc)}\n\n"
        f"{template_block(kits)}{_scope_block(doc, kits)}\n"
        f"{roles._lessons_block(_merge_lessons(curated, lessons), 4000)}\n"
        f"{ui_kit.designer_block()}\n"
        "Return only the Spec JSON object."
    )
    spec, _ = llm.complete_json("designer", user, session_id=session_id, required=roles.SPEC_KEYS, max_tokens=PLAN_MAX_TOKENS)
    rendered = tuple((tpl or {}).get("template", {}).get("files") or [])
    problems = _problems(spec, doc["module_budget"], rendered)
    if problems:
        retry = (f"{user}\n\n## Your previous spec has problems\n" + "\n".join(f"- {p}" for p in problems)
                 + "\n\nPrevious spec:\n" + roles._truncate(json.dumps(spec, ensure_ascii=False), 6000, label="spec")
                 + "\n\nReturn only the corrected Spec JSON object.")
        spec, _ = llm.complete_json("designer", retry, session_id=session_id, required=roles.SPEC_KEYS,
                                    max_tokens=PLAN_MAX_TOKENS)
        problems = _problems(spec, doc["module_budget"], rendered)
        if problems:
            raise LLMError("designer spec invalid: " + "; ".join(problems))
    # the prebuilt modules are known dependencies during normalization, then go first in the module list
    prebuilt = [_prebuilt_module()] + [kit_module(e) for e in kits]
    prebuilt += [{"path": f, "prebuilt": True, "depends": [], "purpose": f"RENDERED by Forge from the spec "
                  f"(the {tpl['name']} template): do not write or edit it"} for f in rendered]
    taken = {m["path"] for m in prebuilt}
    spec["modules"] = prebuilt + [m for m in spec["modules"] if isinstance(m, dict) and m.get("path") not in taken]
    spec = roles._normalize_spec(spec)
    return _attach(spec, doc)


def plan(llm: LLM, idea: str, lessons: str, *, session_id: str) -> dict:
    doc = direct(llm, idea, lessons, session_id=session_id)
    return design_from_doc(llm, idea, doc, lessons, session_id=session_id)


# ------------------------------------------------------------------------------- coder notes


def _kit_note(spec: dict) -> str:
    kits = kit_modules_in(spec)
    if not kits:
        return ""
    return ("- Prebuilt kit modules (require them; never rewrite, edit or re-implement them): "
            + ", ".join(f"{e['name']} ({e['path_in_game']})" for e in kits) + "\n")


def coder_notes(spec: dict, lessons: str, limit: int = 2600) -> str:
    """Lessons for coder/fixer calls on a directed game: style + juice first (they survive truncation)."""
    doc = spec.get("director") or {}
    if not doc:
        kit = _kit_note(spec)
        return kit + (lessons or "") if kit else lessons
    vs = doc.get("visual_style") or {}
    juice = "; ".join(
        f"{j.get('moment')}: {', '.join(str(j.get(k)) for k in ('sound', 'vfx', 'ui', 'camera') if j.get(k) and j.get(k) != 'none')}"
        for j in doc.get("juice") or [] if isinstance(j, dict))
    sounds = ", ".join(f"{s['id']}->{s['kit']}" for s in doc.get("sounds") or [])
    block = (
        "# This game's style and juice (from the director; apply wherever your module touches it)\n"
        f"- Palette: {', '.join(map(str, vs.get('palette') or []))}; materials: "
        f"{', '.join(map(str, vs.get('materials') or []))}; lighting: {vs.get('lighting', '')}\n"
        f"- Use GameAssets (ReplicatedStorage/GameAssets.luau): play(name), burst(at), shake() on the client, "
        f"part(props) for every world part. Sound names: {', '.join(sound_kit())}. Director sounds: {sounds}\n"
        f"- Juice: {juice}\n"
    )
    block = roles._truncate(block, limit, label="style")
    return block + _kit_note(spec) + "\n" + (lessons or "")


# ------------------------------------------------------------------------------- art pass


def _hex(c: str) -> tuple[int, int, int] | None:
    m = re.fullmatch(r"#?([0-9a-fA-F]{6})", str(c).strip())
    if not m:
        return None
    v = m.group(1)
    return int(v[0:2], 16), int(v[2:4], 16), int(v[4:6], 16)


def render_game_assets(spec: dict) -> str:
    """GameAssets.luau from the kit template, with this game's palette and director sound aliases."""
    doc = spec.get("director") or {}
    palette = [p for p in (_hex(c) for c in (doc.get("visual_style") or {}).get("palette") or []) if p]
    pal_lines = "".join(f"\tC{i + 1} = Color3.fromRGB({r}, {g}, {b}),\n" for i, (r, g, b) in enumerate(palette[:8]))
    snd_lines = "".join(f"\t{n} = \"{s['id']}\",\n" for n, s in sound_kit().items())
    vol_lines = "".join(f"\t{n} = {s.get('volume', 0.5)},\n" for n, s in sound_kit().items())
    pitch_lines = "".join(f"\t{n} = {s.get('pitch', 1)},\n" for n, s in sound_kit().items())
    alias, seen = "", set(sound_kit())
    for s in doc.get("sounds") or []:
        if s["id"] not in seen:
            seen.add(s["id"])
            alias += (f"GameAssets.Sounds.{s['id']} = GameAssets.Sounds.{s['kit']}\n"
                      f"VOLUMES.{s['id']}, PITCHES.{s['id']} = VOLUMES.{s['kit']}, PITCHES.{s['kit']}\n")
    tpl = (KIT_DIR / "GameAssets.luau").read_text(encoding="utf-8")
    return (tpl.replace("--[[PALETTE]]\n", pal_lines)
               .replace("--[[SOUNDS]]\n", snd_lines)
               .replace("--[[VOLUMES]]\n", vol_lines)
               .replace("--[[PITCHES]]\n", pitch_lines)
               .replace("--[[ALIASES]]\n", alias))


def install_kit(spec: dict, game_dir: Path) -> list[str]:
    """Write the prebuilt kit files the spec lists into a game: GameAssets.luau (rendered) and every kit module
    (copied), plus the kit modules' genre checks beside the game. Returns the relative game paths written."""
    written = []
    if any(m.get("path") == GAME_ASSETS for m in spec.get("modules") or []):
        out = Path(game_dir) / GAME_ASSETS
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(render_game_assets(spec), encoding="utf-8")
        written.append(GAME_ASSETS)
    kits = kit_modules_in(spec)
    for e in kits:
        out = Path(game_dir) / e["path_in_game"]
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text((KIT_MODULES_DIR / f"{e['name']}.luau").read_text(encoding="utf-8"), encoding="utf-8")
        written.append(e["path_in_game"])
    if kits:
        from forge import template
        written += template.render(spec, game_dir)
        install_genre_checks(spec, game_dir)
    return written


# ------------------------------------------------------------------------------- reporting


def spec_stats(spec: dict) -> dict:
    doc = spec.get("director") or {}
    mods = [m for m in spec.get("modules") or [] if isinstance(m, dict)]
    return {
        "modules": len(mods),
        "written_by_coder": len([m for m in mods if not m.get("prebuilt")]),
        "acceptance": len(spec.get("acceptance") or []),
        "systems": len(doc.get("systems") or []),
        "juice": len(doc.get("juice") or []),
        "first_60s_beats": len(spec.get("first_60s") or []),
        "sounds": len(doc.get("sounds") or []),
        "rewards": len(doc.get("rewards") or []),
        "progression_steps": len(doc.get("progression") or []),
        "purpose_chars": sum(len(m.get("purpose") or "") for m in mods),
        "juice_in_purposes": _juice_in_purposes(spec),
    }


_JUICE_RX = re.compile(r"\b(sound|sfx|play\(|particle|burst|sparkle|tween|pop|punch|shake|flash|glow|confetti)",
                       re.IGNORECASE)


def _juice_in_purposes(spec: dict) -> int:
    """How many coder-written module purposes name a sound/effect/tween (juice the coder will build)."""
    return sum(1 for m in spec.get("modules") or []
               if isinstance(m, dict) and not m.get("prebuilt") and _JUICE_RX.search(m.get("purpose") or ""))


def dry_run(settings, idea: str, *, compare: bool = False, llm: LLM | None = None) -> dict:
    """`forge direct`: director + designer (with compare, also the plain designer) without building.
    Saves runs/plans/<slug>/{doc,spec,spec_plain,stats}.json."""
    from forge.llm import make_llm
    from forge.memory import read_lessons, slugify

    slug = slugify(idea)
    out_dir = settings.runs_dir / "plans" / slug
    out_dir.mkdir(parents=True, exist_ok=True)
    llm = llm or make_llm(settings, out_dir / "calls.jsonl")
    lessons = read_lessons(settings)
    session = f"plan-{slug}"
    after = plan(llm, idea, lessons, session_id=session)
    stats = {"after": spec_stats(after)}
    (out_dir / "doc.json").write_text(json.dumps(after["director"], indent=1, ensure_ascii=False))
    (out_dir / "spec.json").write_text(json.dumps(after, indent=1, ensure_ascii=False))
    before = None
    if compare:
        before = roles.design(llm, idea, lessons, session_id=session)
        stats["before"] = spec_stats(before)
        (out_dir / "spec_plain.json").write_text(json.dumps(before, indent=1, ensure_ascii=False))
    (out_dir / "stats.json").write_text(json.dumps(stats, indent=1))
    return {"slug": slug, "dir": str(out_dir), "stats": stats, "spec": after, "spec_plain": before}


def render_compare(out: dict) -> str:
    st = out["stats"]
    lines = [f"plan: {out['dir']}", f"{'':<20}{'designer only':>14}{'director':>10}"]
    for k in st["after"]:
        b = st.get("before", {}).get(k, "-")
        lines.append(f"{k:<20}{b!s:>14}{st['after'][k]!s:>10}")
    lines.append("\nmodules (director):")
    lines += [f"  {m['path']}" + ("  [prebuilt]" if m.get("prebuilt") else "") for m in out["spec"]["modules"]]
    lines.append("first 60 seconds:")
    lines += [f"  {b['t']:>4g}s  {b['counter'] or '-':<22} {b['beat'][:70]}"
              for b in out["spec"].get("first_60s") or []]
    return "\n".join(lines)
