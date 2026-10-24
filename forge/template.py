"""Template games: a kit module that is the whole game's wiring (ParkObby). Forge renders the template's
content files from the spec, so no LLM writes plumbing and every table has one source:

    rendered_files(spec) -> {game path: text}      Config.luau + the two bootstraps, for a template game
    render(spec, game_dir) -> list[str]             writes them (install_kit and `forge levels` call it)
    template_of(spec) -> dict | None                the template kit's index entry, if the game has one

The zone table comes from spec["levels"]["plan"] (written by `forge levels`), so ParkObby's zones always match
the level data one to one. A template kit's index entry carries "template": {"files": [...]}: the game paths
rendered here, which the coder never writes and the fixer never edits.
"""
from __future__ import annotations

import json
import math
import re
from pathlib import Path

from forge import director

PARK_THEMES = ("entrance", "carousel", "bumper", "teacups", "ferris", "flume", "haunted", "pirate", "coaster",
               "finale")
# words in a zone's name or theme text that pick a park theme; the first theme in this order that matches
# and isn't taken by an earlier zone wins
THEME_WORDS = {
    "carousel": ("carousel", "merry-go-round", "pony", "ponies", "horses"),
    "bumper": ("bumper", "dodgem"),
    "teacups": ("teacup", "tea cup", "tea party", "saucer"),
    "ferris": ("ferris", "big wheel", "wheel"),
    "flume": ("flume", "log ride", "splash", "lagoon", "river", "raft", "water"),
    "haunted": ("haunted", "ghost", "spooky", "horror", "pumpkin", "creepy"),
    "pirate": ("pirate", "ship", "treasure", "buccaneer"),
    "coaster": ("coaster", "loop", "rails", "track"),
    "finale": ("finale", "firework", "rocket", "grand finish"),
    "entrance": ("entrance", "front gate", "gate", "ticket", "welcome", "plaza"),
}
# WorldKit's default palette per landmark (WorldKit.luau KINDS), so the HUD colour matches the ride
PALETTES = {
    "entrance": ("#E63946", "#FFC23D", "#3A86FF"), "carousel": ("#FF5FA8", "#FFC23D", "#6EC6FF"),
    "bumper": ("#22B8EE", "#FFD23F", "#FF4F6D"), "teacups": ("#A77BFF", "#5ED6B4", "#FF8EC2"),
    "ferris": ("#FF7A2F", "#3FB8F5", "#FFE066"), "flume": ("#1FA896", "#2F7BFF", "#F4D06F"),
    "haunted": ("#6A3FB5", "#7CFF6B", "#FF8A3D"), "pirate": ("#D7263D", "#F2C14E", "#24407A"),
    "coaster": ("#E63946", "#FFD23F", "#1D3557"), "finale": ("#3A2E8F", "#FFC23D", "#FF4FA3"),
}
MOODS = {"entrance": "carnival", "carousel": "carnival", "bumper": "pop", "teacups": "carnival", "ferris": "pop",
         "flume": "water", "haunted": "spooky", "pirate": "pirate", "coaster": "intense", "finale": "victory"}
# Cosmetics.luau CATALOG ids that fit a funfair, in panel order (catalog prices); the cape is the finish reward
PARK_COSTUMES = ("MouseEars", "BalloonHat", "PartyCone", "ClownWig", "HeroCape", "TopHat", "StarCape", "FireTrail",
                 "RainbowTrail", "Crown", "ChampionCape")
PARK_REWARD = "ChampionCape"
PARK_ZONES, PARK_STAGES_PER_ZONE = 6, 10
# WorldKit's park (size 1600) keeps its rides clear of the courses up to 12 zones; at 13 rides stand on course 2
MAX_ZONES = 12
MAX_STAGES = MAX_ZONES * PARK_STAGES_PER_ZONE
PER_ZONE_CHOICES = (10, 9, 11, 8, 12)  # zone sizes the level designer handles well, closest to 10 first
_UNITS = {w: i for i, w in enumerate("zero one two three four five six seven eight nine ten eleven twelve thirteen "
                                     "fourteen fifteen sixteen seventeen eighteen nineteen".split())}
_TENS = {w: 10 * i for i, w in enumerate("_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()) if i > 1}
_WORD_NUM = re.compile(r"\b(?:(a|an|one|two|three|four|five|six|seven|eight|nine|\d+)[\s-]+)?hundred\b"
                       r"|\b(" + "|".join(_TENS) + r")(?:[\s-]+(" + "|".join(list(_UNITS)[1:10]) + r"))?\b"
                       r"|\b(" + "|".join(_UNITS) + r")\b")
_AREA = r"(?:zones?|worlds?|areas?|sections?|parts?|chapters?)"
_STAGE = r"(?:stages?|levels?)"
_GRID = re.compile(rf"\b(\d+)\s*{_AREA}\s*(?:(?:of|x|×)\s*(\d+)\s*-?\s*{_STAGE}|with\s*(\d+)\s*{_STAGE}\s*each)")
_PER_AREA = re.compile(rf"\b(\d+)\s*-?\s*{_STAGE}\s*(?:per|each|in each|a|an|for each)\s*(?:zone|world|area|section|part|chapter)")
_AREAS = re.compile(rf"\b(\d+)\s*{_AREA}\b")
_STAGES = re.compile(r"\b(\d+)\s*-?\s*(?:[a-z]+\s+)?stages?\b|\bstages?\s*[:=]\s*(\d+)")
# "a 3-level castle", "3 levels of difficulty": a level count that is not the course's length
_LEVELS = re.compile(r"\b(\d+)\s*-?\s*levels?\b(?!\s*(?:of\s+(?:difficulty|challenge)|high|tall|"
                     r"house|castle|tower|building|mansion|home|school|mall|hotel|dungeon|maze))")

SERVER_BOOT = """-- Rendered by Forge (forge/template.py): the {name} template's server bootstrap. Do not edit.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local {name} = require(ReplicatedStorage:WaitForChild("Kit"):WaitForChild("{name}"))
{name}.startServer(require(ReplicatedStorage:WaitForChild("Config")))
"""
CLIENT_BOOT = """-- Rendered by Forge (forge/template.py): the {name} template's client bootstrap. Do not edit.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local {name} = require(ReplicatedStorage:WaitForChild("Kit"):WaitForChild("{name}"))
{name}.startClient(require(ReplicatedStorage:WaitForChild("Config")))
"""


def _digits(text: str) -> str:
    """Thousands separators and number words as digits: "1,000" -> 1000, "a hundred" -> 100, "twenty-five" -> 25."""
    text = re.sub(r"\b(\d{1,3}(?:,\d{3})+)\b", lambda m: m.group(1).replace(",", ""), text.lower())

    def num(m: re.Match) -> str:
        if m.group(0).endswith("hundred"):
            k = m.group(1) or "one"
            return str(100 * (int(k) if k.isdigit() else _UNITS.get(k, 1)))
        if m.group(2):
            return str(_TENS[m.group(2)] + (_UNITS[m.group(3)] if m.group(3) else 0))
        return str(_UNITS[m.group(4)])

    return _WORD_NUM.sub(num, text)


def requested_stages(idea: str) -> int | None:
    """The course length the idea asks for: "100 stages", "a 100-stage obby", "a hundred levels", "100 obby stages",
    "stages: 100", "5 zones of 20 stages" (100), "10 levels per world, 8 worlds" (80). A stage count wins over a
    level count, and a level count that is a building's floors or a difficulty scale is not one."""
    text = _digits(str(idea or ""))
    m = _GRID.search(text)
    if m:
        return int(m.group(1)) * int(m.group(2) or m.group(3))
    per, areas = _PER_AREA.search(text), _AREAS.search(text)
    if per and areas:
        return int(per.group(1)) * int(areas.group(1))
    m = _STAGES.search(text) or _LEVELS.search(text)
    if not m:
        return None
    return int(next(g for g in m.groups() if g is not None))


def scope_from_idea(idea: str, levels_spec: dict | None) -> tuple[int, int, str | None]:
    """(zones, stages per zone, note) for a template obby: the idea's own stage count wins, then the director's
    spec["levels"], then PARK_ZONES x PARK_STAGES_PER_ZONE. The note says when the course differs from what was
    asked (no exact split into 8-12 stage zones, the 1-200 clamp, themes repeating past 10 zones): reported,
    never silent (docs/GAME_PRODUCTION_GUIDE.md 8.3)."""
    asked = requested_stages(idea)
    lv = levels_spec or {}
    if asked is None:
        try:
            zones, per = int(lv.get("zones") or 0), int(lv.get("stages_per_zone") or 0)
        except (TypeError, ValueError):
            zones = per = 0
        zones, per = (zones, per) if zones > 0 and per > 0 else (PARK_ZONES, PARK_STAGES_PER_ZONE)
        return zones, per, None
    notes = []
    n = min(MAX_STAGES, max(1, asked))
    if n != asked:
        notes.append(f"You asked for {asked} stages; Forge builds 1 to {MAX_STAGES}, so the course aims for {n}.")
    try:
        planned = int(lv.get("zones") or 0) * int(lv.get("stages_per_zone") or 0)
    except (TypeError, ValueError):
        planned = 0
    if planned > n:
        notes.append(f"The plan had {planned} stages; the idea asks for {asked}, so the course follows the idea.")
    per = next((p for p in PER_ZONE_CHOICES if n % p == 0 and n // p <= MAX_ZONES), None)
    zones = n // per if per else math.ceil(n / PARK_STAGES_PER_ZONE)
    per = per or PARK_STAGES_PER_ZONE
    if zones * per != n:
        notes.append(f"{n} stages do not split into zones of 8-12, so the course has {zones * per} stages "
                     f"({zones} zone{'s' if zones > 1 else ''} x {per}) instead of {n}.")
    if zones > len(PARK_THEMES):
        notes.append(f"{zones} zones is more than the {len(PARK_THEMES)} park themes, so some themes repeat.")
    return zones, per, " ".join(notes) or None


def scope_block(zones: int, per: int) -> str:
    return (f"## Course scope (Forge builds exactly this)\nIf this game is a stage course: {zones} zones of {per} stages, "
            f"{zones * per} stages in all. Use these numbers wherever acceptance, systems or progression count zones "
            "or stages.")


_SCOPE_SAID = re.compile(rf"\b(\d+)\s*{_AREA}\s*(?:of|x|×)\s*(\d+)\s*-?\s*stages?\b"
                         rf"|\b(\d+)\s+(\d+)\s*-\s*stages?\s*{_AREA}")


def align_scope(spec: dict, zones: int, per: int) -> bool:
    """The director's prose keeps its own course numbers ("5 zones of 20 stages") after the idea's count overrides
    spec["levels"], and the critics grade against acceptance: rewrite its zone and stage counts to the course
    Forge builds, in acceptance and the director's systems. True when anything changed."""
    doc = spec.get("director") or {}
    systems = [x for x in doc.get("systems") or [] if isinstance(x, dict)]
    texts = [str(a) for a in spec.get("acceptance") or []] + [str(x.get("what") or "") for x in systems]
    said = next((m for t in texts for m in [_SCOPE_SAID.search(_digits(t))] if m), None)
    if not said:
        return False
    a, b = (int(g) for g in (said.groups()[:2] if said.group(1) else said.groups()[2:]))
    if (a, b) == (zones, per):
        return False
    words = {v: k for k, v in _UNITS.items()}
    subs = [(rf"\b(?:{a}|{words.get(a, '_')})(\s+(?:\d+\s*-\s*stages?\s+)?{_AREA})", rf"{zones}\1"),
            (rf"\b(?:{b}|{words.get(b, '_')})(\s*-?\s*stages?\s+(?:each|per|zones?|worlds?|areas?)\b)", rf"{per}\1"),
            (rf"(\b{_AREA}\s*(?:of|x|×)\s*){b}\b", rf"\g<1>{per}"),
            (rf"\b(every\s+){b}(\s+stages)\b", rf"\g<1>{per}\2"),
            (rf"\b{b}(st|nd|rd|th)\s+stage\b", f"{per}th stage")]

    def fix(text: str) -> str:
        for pat, to in subs:
            text = re.sub(pat, to, text, flags=re.IGNORECASE)
        return text

    spec["acceptance"] = [fix(str(t)) for t in spec.get("acceptance") or []]
    for x in systems:
        x["what"] = fix(str(x.get("what") or ""))
    return True


def template_of(spec: dict) -> dict | None:
    return next((e for e in director.kit_modules_in(spec) if e.get("template")), None)


def template_files(spec: dict) -> list[str]:
    entry = template_of(spec)
    return list((entry or {}).get("template", {}).get("files") or [])


def park_themes(plan: list[dict]) -> list[str]:
    """One park theme per zone. The level designer's theme_id (the theme its level data was built with) is used
    as is, so the ride WorldKit builds and the dressing ObbyThemes adds always agree; a zone without one gets the
    first theme its name or theme text names, else the first theme not taken yet."""
    taken: list[str] = []
    for z in plan:
        own = str(z.get("theme_id") or z.get("theme") or "").strip().lower()
        text = f" {z.get('name') or ''} {z.get('theme') or ''} ".lower()
        pick = own if own in PARK_THEMES and (z.get("theme_id") or own not in taken) else None
        if pick is None:
            pick = next((t for t, words in THEME_WORDS.items()
                         if t not in taken and any(w in text for w in words)), None)
        if pick is None:
            pick = next((t for t in PARK_THEMES if t not in taken), PARK_THEMES[len(taken) % len(PARK_THEMES)])
        taken.append(pick)
    return taken


def _lua(s: str) -> str:
    return json.dumps(str(s), ensure_ascii=False)


def park_config(spec: dict) -> str:
    plan = (spec.get("levels") or {}).get("plan") or []
    themes = park_themes(plan)
    lines = ["-- Rendered by Forge (forge/template.py) from spec.json: do not edit. The zones are the level designer's",
             "-- (`forge levels`), so they match the level data one to one.",
             "return {",
             f"\tTitle = {_lua(spec.get('title') or 'Park Obby')},",
             "\tZones = {"]
    for z, theme in zip(plan, themes):
        palette = ", ".join(_lua(c) for c in PALETTES[theme])
        lines.append(f"\t\t{{ name = {_lua(z.get('name') or theme.title())}, theme = {_lua(theme)}, "
                     f"palette = {{ {palette} }}, mood = {_lua(MOODS[theme])} }},")
    lines += ["\t},",
              f"\tCostumes = {{ {', '.join(_lua(c) for c in PARK_COSTUMES)} }},",
              f"\tRewards = {{ {_lua(PARK_REWARD)} }},",
              f"\tAutoEquip = {_lua(PARK_COSTUMES[0])},",
              f"\tFinishReward = {_lua(PARK_REWARD)},",
              "\tSeed = 7,",
              "}",
              ""]
    return "\n".join(lines)


def rendered_files(spec: dict) -> dict[str, str]:
    entry = template_of(spec)
    if not entry:
        return {}
    name = entry["name"]
    files = template_files(spec)
    out = {}
    for path in files:
        if path.endswith("Config.luau"):
            out[path] = park_config(spec)
        elif path.endswith(".server.luau"):
            out[path] = SERVER_BOOT.format(name=name)
        elif path.endswith(".client.luau"):
            out[path] = CLIENT_BOOT.format(name=name)
        else:
            raise ValueError(f"{name} template file {path!r}: no renderer for it")
    return out


def render(spec: dict, game_dir: Path) -> list[str]:
    written = []
    for path, text in rendered_files(spec).items():
        out = Path(game_dir) / path
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding="utf-8")
        written.append(path)
    return written
