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


def template_of(spec: dict) -> dict | None:
    return next((e for e in director.kit_modules_in(spec) if e.get("template")), None)


def template_files(spec: dict) -> list[str]:
    entry = template_of(spec)
    return list((entry or {}).get("template", {}).get("files") or [])


def park_themes(plan: list[dict]) -> list[str]:
    """One distinct park theme per zone: the zone's own theme id when it is one, else the first theme its name
    or theme text names, else the first theme not taken yet."""
    taken: list[str] = []
    for z in plan:
        own = str(z.get("theme") or "").strip().lower()
        text = f" {z.get('name') or ''} {z.get('theme') or ''} ".lower()
        pick = own if own in PARK_THEMES and own not in taken else None
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
