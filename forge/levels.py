"""`forge levels`: the level_designer Mubit task writes an obby's stages as data, one zone per call.

    forge levels <slug> [--zones a-b] [--stages-per-zone 20] [--total-zones N]

Zone z holds stages (z-1)*S+1 .. z*S. Per zone: one level_designer call (forge/prompts/level_designer.md; the
game, the zone, its park theme and signature kinds, a difficulty target per stage, the mechanics to introduce,
the variety rules, Forge's route (obby.route_plan: which stages run out, run back or are corners, their lengths),
the kinds, the jump limits and one valid example stage all go in the user message) -> Forge writes the route's
turns and, for a park theme, the theme's palette into the reply (forge_owned) -> forge/obby.py validates every
jump (validate_zone) and the zone rules (zone_rules: variety, the theme's signature kinds, turns, the climb, the
zone inside its plot, the course never crossing itself) -> the exact errors go back to the SAME Mubit task as a
correction, up to CORRECTIONS times (each one a training example) -> a stage still unreachable after that
becomes obby.fallback_stage (a corner's is a short lift; reported, never silent) -> written as
runs/<slug>/levels/zone-NN.json (the record) and game/ReplicatedStorage/Levels/ZoneNN.luau (the data module
ObbyKit builds).

A zone's park theme (obby.THEMES, zone_theme): the plan entry's theme_id (or a theme that is one), words in its
planned name/theme, else, for an amusement-park game, its place in the park (entrance first, finale last).
Resumable: a zone whose JSON exists and passes both validators is skipped (its .luau re-rendered when stale).
Every run installs the latest ObbyKit into the game (director.ensure_kit) and the obby genre checks with the
spec's stage count. spec["levels"] = {"zones", "stages_per_zone", "plan": [{zone, name, theme, theme_id, kinds,
stages, written, request_ids, corrections, fallback, rules_left, stats}]}; a plan entry written by hand
({zone, name, theme, theme_id}) is kept.
"""

from __future__ import annotations

import json
import math
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from forge import director, obby, template
from forge.config import Settings
from forge.llm import LLMError
from forge.memory import RunStore

ROLE = "level_designer"
CORRECTIONS = 2
# Measured on Mubit (claude-sonnet-5-5): a 10-stage zone is ~5.5k chars of JSON but ~10.7k output tokens, as the
# model reasons first; a 20-stage zone needs about twice that. With the zone rules in the message a 20-stage zone
# spent all of a 32k cap reasoning and returned no text (2026-10-24), hence 64k and the "Work fast" recipes.
# Replies stream (MubitLLM), so a high cap is safe.
MAX_TOKENS = 64_000
DEFAULT_STAGES_PER_ZONE = 20
MAX_ERRORS_SHOWN = 60
PREVIOUS_CHARS = 9000

# Mechanics in the order a course introduces them (a new one every few stages), with the kinds they use.
MECHANICS: list[tuple[str, str, tuple[str, ...]]] = [
    ("platform", "comfortable platforms of every shape (round, cylinder logs, wedge-ramps) around one easy obstacle",
     ("platform",)),
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

# What each park theme (obby.THEMES) is, for the level designer; its signature kinds are obby.SIGNATURES.
THEME_NOTES = {
    "entrance": "the park's front gate and plaza: ticket booths, balloons, striped awnings. Welcoming and easy: teach "
                "the basics on platforms of every shape (round discs, cylinder logs, wedge-ramps) and the first jump "
                "pads.",
    "carousel": "a giant merry-go-round: painted horses, brass poles, a striped canopy. Ride spinning turntables and "
                "gliding movers that circle like the ride.",
    "bumper": "the bumper-car arena: a neon floor, rubber walls, sparks. Dodge sliding movers and ride conveyors like "
              "the cars' tracks.",
    "teacups": "the spinning teacups: giant cups and saucers on a turning floor. Jump the spinners' bars and ride "
               "turntables.",
    "ferris": "the ferris wheel: gondolas rising into the sky. Ride movers that go up and down like gondolas and "
              "bounce on trampolines to climb.",
    "flume": "the log flume: water channels, logs, splashes. Ride conveyors like the current, hop cylinder logs, jump "
             "the water (lava pieces are built as water).",
    "haunted": "the haunted house: dark purple halls, ghosts, creaky boards. Tiles that vanish like ghosts and pits "
               "of ectoplasm (lava).",
    "pirate": "the swinging pirate ship: masts, barrels, sails. Dodge swinging pendulums like the ship and ride "
              "sliding decks.",
    "coaster": "the roller coaster: red rails, loops, lift hills. Ride movers like coaster cars and blast up with jump "
               "pads like a launch.",
    "finale": "the grand finale: a fireworks stage, gold and confetti. A mix of every mechanic: the hardest stages "
              "of the park.",
}
THEME_WORDS = {"entrance": ("entrance", "ticket", "welcome"), "carousel": ("carousel", "merry go round"),
               "bumper": ("bumper", "dodgem"), "teacups": ("teacup", "teacups", "tea cup"), "ferris": ("ferris",),
               "flume": ("flume", "log ride"), "haunted": ("haunted", "ghost", "spooky"), "pirate": ("pirate",),
               "coaster": ("coaster", "rollercoaster"), "finale": ("finale", "fireworks")}
PARK_WORDS = ("amusement", "funfair", "fun fair", "theme park", "carnival", "fairground")

# One valid run stage per theme for the user message (tests/test_levels.py: each passes the validator, the per-stage
# variety rules, shows the theme's signature kinds and keeps the route's run length, lane width and run climb: it
# rises and drops back).
EXAMPLES: dict[str, dict] = {
    "entrance": {"stage": 2, "name": "Ticket Hop", "pieces": [
        {"kind": "platform", "shape": "round", "gap": 4, "rise": 0, "size": [8, 1, 8]},
        {"kind": "platform", "shape": "wedge-ramp", "gap": 5, "rise": 3, "size": [8, 3, 8]},
        {"kind": "jumppad", "gap": 4, "rise": 0},
        {"kind": "platform", "gap": 6, "rise": 9, "side": 3, "size": [8, 1, 8]},
        {"kind": "checkpoint", "gap": 5, "rise": -9, "side": 0}]},
    "carousel": {"stage": 23, "name": "Pony Spin", "pieces": [
        {"kind": "platform", "shape": "round", "gap": 4, "rise": 1, "size": [7, 1, 7]},
        {"kind": "turntable", "gap": 4, "rise": 1, "speed": 40, "size": [14, 1, 14]},
        {"kind": "moving", "gap": 9, "rise": 0, "move": [0, 0, -5], "period": 5},
        {"kind": "platform", "gap": 4, "rise": 2, "side": -2, "size": [6, 1, 6]},
        {"kind": "checkpoint", "gap": 5, "rise": -1}]},
    "bumper": {"stage": 45, "name": "Dodgem Drift", "pieces": [
        {"kind": "conveyor", "gap": 4, "rise": 0, "dir": "right", "speed": 6, "size": [8, 1, 14]},
        {"kind": "moving", "gap": 6, "rise": 1, "move": [8, 0, 0], "period": 4},
        {"kind": "platform", "shape": "cylinder", "gap": 5, "rise": 1, "size": [10, 3, 3]},
        {"kind": "conveyor", "gap": 4, "rise": 0, "dir": "forward", "speed": 8},
        {"kind": "checkpoint", "gap": 4, "rise": 1}]},
    "teacups": {"stage": 64, "name": "Saucer Swirl", "pieces": [
        {"kind": "turntable", "gap": 4, "rise": 0, "speed": 30, "size": [12, 1, 12]},
        {"kind": "spinner", "gap": 4, "rise": 1, "speed": 70, "size": [14, 1, 14]},
        {"kind": "platform", "shape": "round", "gap": 4, "rise": 2, "size": [7, 1, 7]},
        {"kind": "turntable", "gap": 4, "rise": 1, "speed": 50, "size": [12, 1, 12]},
        {"kind": "checkpoint", "gap": 4, "rise": 0}]},
    "ferris": {"stage": 86, "name": "Gondola Lift", "pieces": [
        {"kind": "platform", "shape": "round", "gap": 4, "rise": 0, "size": [8, 1, 8]},
        {"kind": "moving", "gap": 5, "rise": 0, "move": [0, 10, 0], "period": 6, "size": [8, 1, 8]},
        {"kind": "platform", "gap": 4, "rise": 11, "size": [8, 1, 8]},
        {"kind": "trampoline", "gap": 4, "rise": -9},
        {"kind": "platform", "shape": "round", "gap": 6, "rise": 8, "size": [8, 1, 8]},
        {"kind": "checkpoint", "gap": 4, "rise": -7}]},
    "flume": {"stage": 107, "name": "Splash Run", "pieces": [
        {"kind": "conveyor", "gap": 4, "rise": 0, "dir": "forward", "speed": 8, "size": [8, 1, 16]},
        {"kind": "lava", "gap": 0, "rise": -0.5, "size": [8, 1, 4]},
        {"kind": "platform", "shape": "cylinder", "gap": 0, "rise": 1.5, "size": [10, 3, 3]},
        {"kind": "conveyor", "gap": 4, "rise": 0, "dir": "forward", "speed": 6, "size": [6, 1, 12]},
        {"kind": "platform", "shape": "wedge-ramp", "gap": 4, "rise": 3, "size": [8, 2, 8]},
        {"kind": "checkpoint", "gap": 4, "rise": 0}]},
    "haunted": {"stage": 128, "name": "Ghost Steps", "pieces": [
        {"kind": "platform", "shape": "round", "gap": 4, "rise": 0, "size": [7, 1, 7]},
        {"kind": "disappearing", "gap": 4, "rise": 1, "count": 4, "spacing": 2, "on": 2.5, "off": 1.5, "stagger": 0.6},
        {"kind": "lava", "gap": 0, "rise": -0.5, "size": [8, 1, 4]},
        {"kind": "platform", "gap": 0, "rise": 0.5, "size": [7, 1, 7]},
        {"kind": "checkpoint", "gap": 4, "rise": 2}]},
    "pirate": {"stage": 146, "name": "Plank Swing", "pieces": [
        {"kind": "platform", "shape": "cylinder", "gap": 4, "rise": 1, "size": [10, 4, 4]},
        {"kind": "pendulum", "gap": 4, "rise": 0, "swing": 60, "period": 3, "length": 10},
        {"kind": "moving", "gap": 9, "rise": 1, "move": [0, 0, -5], "period": 4},
        {"kind": "platform", "gap": 4, "rise": 2, "size": [7, 1, 7]},
        {"kind": "checkpoint", "gap": 4, "rise": 0}]},
    "coaster": {"stage": 165, "name": "Lift Hill Launch", "pieces": [
        {"kind": "platform", "shape": "wedge-ramp", "gap": 4, "rise": 3, "size": [8, 3, 10]},
        {"kind": "moving", "gap": 6, "rise": 0, "move": [0, 0, 10], "period": 5},
        {"kind": "jumppad", "gap": 12, "rise": 0},
        {"kind": "platform", "shape": "round", "gap": 8, "rise": 12, "size": [9, 1, 9]},
        {"kind": "checkpoint", "gap": 4, "rise": -12}]},
    "finale": {"stage": 196, "name": "Fireworks Gauntlet", "pieces": [
        {"kind": "spinner", "gap": 3, "rise": 0, "speed": 90, "size": [12, 1, 12]},
        {"kind": "disappearing", "gap": 4, "rise": 1, "count": 2, "spacing": 2, "on": 2.2, "stagger": 0.5},
        {"kind": "jumppad", "gap": 3, "rise": 0},
        {"kind": "platform", "shape": "round", "gap": 5, "rise": 10, "size": [8, 1, 8]},
        {"kind": "pendulum", "gap": 3, "rise": -8, "swing": 65, "period": 2.5, "size": [6, 1, 10]},
        {"kind": "checkpoint", "gap": 3, "rise": 0}]},
}


WORK_FAST = """## Work fast: recipes that pass
Do not check every jump or lay out the turns in your head: the validator does both exactly, and anything it finds comes
back to you as a short correction. Design from these recipes and write the JSON:
- Jumps: gaps 3-6 studs at rises -2 to +3 (up to 8 at expert stages), sides within +-5.
- Movers: leave 2 studs between a mover's farthest point and the next piece; ride it toward the next piece.
- Route: give each stage its route role: a run stage 50-80 studs long (add up its length as you write it), a corner
  one lifting piece and the checkpoint. Forge writes the turns.
- Climb: the corners lift the zone a level each; a run climbs at most 12 in all, so after a rise or a jump pad's high
  platform, drop back down.
- Variety: rotate which obstacles a stage uses and in what order, and add or drop one piece, so no two stages repeat."""


def _words(text: str) -> str:
    return " " + " ".join(re.findall(r"[a-z0-9]+", str(text or "").lower())) + " "


def is_park(spec: dict) -> bool:
    doc = spec.get("director") or {}
    text = _words(" ".join(str(spec.get(k) or "") for k in ("title", "pitch", "core_loop")) + " "
                  + str(doc.get("fantasy") or ""))
    return any(f" {w} " in text for w in PARK_WORDS)


def zone_theme(spec: dict, zone: int, total_zones: int) -> str | None:
    """The zone's park theme (obby.THEMES) or None: the plan's theme_id (or a theme that is one), words in the
    planned name/theme, else an amusement-park game's park order (entrance, the rides in turn, finale last)."""
    plan = _plan(spec)
    planned = plan.get(zone) or {}
    for key in ("theme_id", "theme"):
        v = str(planned.get(key) or "").strip().lower()
        if v in obby.THEMES:
            return v
    # a theme an earlier zone already has is never picked again by words or park order: two zones with one ride
    # look the same (WorldKit builds one landmark per zone, ObbyThemes dresses by theme)
    taken = {str(p.get("theme_id") or "") for z, p in plan.items() if z < zone}
    text = _words(f"{planned.get('name') or ''} {planned.get('theme') or ''}")
    for theme, words in THEME_WORDS.items():
        if theme not in taken and any(f" {w} " in text for w in words):
            return theme
    if not is_park(spec):
        return None
    if zone == 1:
        return "entrance"
    if zone == total_zones and total_zones > 1:
        return "finale"
    rides = obby.THEMES[1:-1]
    start = (zone - 2) % len(rides)
    order = rides[start:] + rides[:start]  # the zone's place in the park order, then the next ride nobody has
    return next((t for t in order if t not in taken), order[0])


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


def usable_kinds(total: int, first: int, last: int, theme: str | None,
                 used_before: set[str] | frozenset = frozenset()) -> tuple[list, list, list[str]]:
    """(mechanics introduced before the zone, mechanics new in it, the kinds the zone may use): the schedule's
    kinds so far, kinds earlier zones already use, the theme's signature kinds (introduced early when new), and
    the next scheduled kinds until the zone has room for its variety rules (MIN_ZONE_KINDS, or MIX_KINDS for the
    finale, plus one to choose from)."""
    intro = intro_stages(total)
    before = [m for m in intro if m[0] < first]
    new = [m for m in intro if first <= m[0] <= last]
    later = intro[len(before) + len(new):]
    usable = {k for m in before + new for k in m[3]} | {"platform"} | set(used_before)
    if any(not m[3] for m in before + new):  # a gauntlet: every kind
        usable = set(obby.KIND_ORDER)
    known = {k for m in before for k in m[3]} | {"platform"} | set(used_before)
    sig = [(label, kind) for label, kind, _ in obby.SIGNATURES.get(theme or "", ()) if kind not in known]
    new = sorted(new + [(min(last, first + 1 + j), label, f"{label}: a signature kind of this zone, introduce it early "
                         f"and use it in at least {obby.share_need(last - first + 1)} stages", (kind,))
                        for j, (label, kind) in enumerate(sig)], key=lambda m: m[0])
    usable |= {kind for _, kind, _ in obby.SIGNATURES.get(theme or "", ())}
    want = (obby.MIX_KINDS if theme == "finale" else obby.MIN_ZONE_KINDS) + 1
    for m in later:
        if len(usable) >= want:
            break
        usable |= set(m[3])
    return before, new, ["checkpoint"] + [k for k in obby.KIND_ORDER if k in usable]


def rules_doc(count: int, theme: str | None) -> str:
    """The zone rules (obby.rule_problems) in words, with this zone's numbers."""
    need = obby.share_need(count)
    kinds = obby.MIX_KINDS if theme == "finale" else obby.MIN_ZONE_KINDS
    lines = [
        f"- At most half of a stage's pieces (the checkpoint not counted) are plain block platforms; the rest are "
        "obstacles or shaped platforms (round, cylinder, wedge-ramp). Mix shapes: no zone of identical slabs.",
        "- Every stage has at least one obstacle (a kind other than platform and checkpoint), breathers included.",
        "- No two stages of the zone share the same kind sequence (the kinds of their pieces in order).",
        f"- The zone uses at least {kinds} different kinds" + (" (the finale mixes everything)." if theme == "finale"
                                                                else "."),
        f"- At least {need} of the {count} stages turn (turn -90 to 90 degrees, right +, on the stage's start pad, the "
        "previous checkpoint: its whole stage then runs in the new direction). The route below has the zone's turns, "
        "and Forge writes them into your stages.",
        f"- The zone stays inside its plot beside its ride: every piece, mover's path and jump within x "
        f"-{obby.PLOT_HALF_WIDTH:g} to {obby.PLOT_HALF_WIDTH:g} (sideways, left -) and z -{obby.PLOT_BACK:g} to "
        f"{obby.PLOT_LENGTH:g} (along the start pad's facing) of the zone's start pad. Keep the route's stage lengths "
        "and lanes and it fits.",
        f"- The course never crosses itself: no piece of one stage within {obby.CROSS_MARGIN:g} studs of another "
        f"stage's piece or jump unless {obby.CLEARANCE:g} studs above or below it (the corners' lifts keep the runs "
        "stacked above each other apart).",
        f"- The zone climbs: its last checkpoint ends at least {obby.CLIMB_PER_STAGE * count:g} studs above its start "
        f"({obby.CLIMB_PER_STAGE:g} per stage), and each run of the route climbs at most {obby.RUN_CLIMB_MAX:g} studs: the "
        "corners lift the course a level each, so the stacked runs read as one structure.",
    ]
    if theme and obby.SIGNATURES.get(theme):
        sig = " and ".join(label for label, _, _ in obby.SIGNATURES[theme])
        lines.insert(4, f"- This is the {theme} zone: its signature {sig} each appear in at least {need} of the "
                        f"{count} stages.")
    return "\n".join(lines)


CORNER_EXAMPLE = {"stage": 6, "name": "Big Top Bounce", "pieces": [
    {"kind": "jumppad", "gap": 4}, {"kind": "checkpoint", "gap": 6, "rise": 16}]}


def _stages(first: int, a: int, b: int) -> str:
    return f"stage {first + a}" if a == b else f"stages {first + a}-{first + b}"


def route_doc(first: int, count: int) -> str:
    """Forge's route for the zone (obby.route_plan), stage by stage, with the length and lane recipe that makes it fit
    the plot."""
    plan = obby.route_plan(count)
    turn = f"{obby.CORNER_TURN:g}"
    lines = ["## Route (Forge lays the zone out and sets every stage's turn from it)",
             "The zone fits its plot as a switchback that climbs: runs of stages go out and back in two lanes, and each "
             f"U-turn is a short corner stage that turns left ({turn}) and lifts the course a level, then the next run's "
             f"first stage turns left ({turn}) again, one lane over and above the run before it."]
    i = 0
    while i < len(plan):
        p = plan[i]
        if p["role"] == "corner":
            lines.append(f"- {_stages(first, i, i)}: corner (turn {turn})")
            i += 1
            continue
        j = i
        while j + 1 < len(plan) and plan[j + 1]["role"] == "run":
            j += 1
        way = "out (away from the start)" if p["dir"] == "out" else "back (toward the start)"
        turns = f"{_stages(first, i, i)} turns {turn}, the rest 0" if p["turn"] else "turn 0"
        if p["turn"] and i == j:
            turns = f"turn {turn}"
        lines.append(f"- {_stages(first, i, j)}: run {p['run']}, {way}: {turns}")
        i = j + 1
    lo, hi = obby.RUN_LENGTH
    clo, chi = obby.CORNER_LENGTH
    llo, lhi = obby.CORNER_LIFT
    lines += [
        f"Run stages: {lo:g}-{hi:g} studs long each, and every run back no longer than the run out before it. A stage's "
        "length: 5 (half its start pad) + every piece's gap and length (a row of tiles: count x length + the spacings) "
        "+ the checkpoint's gap + 5. Keep |side| + half a piece's width (a mover: plus its sideways move) within "
        f"{obby.LANE_HALF_WIDTH:g}, so the lanes stay apart: sides within +-5 on pieces up to 14 wide. A run climbs at most "
        f"{obby.RUN_CLIMB_MAX:g} studs from its first start pad to its last checkpoint (the corners do the climbing): after "
        "a rise or a jump pad's high platform, drop back down.",
        f"Corners: {clo:g}-{chi:g} studs long: ONE piece, then the checkpoint {llo:g}-{lhi:g} studs higher: a jump pad "
        "(gap 4, then the checkpoint at gap 6), a trampoline (gap 4, checkpoint gap 4) or an elevator (a moving platform "
        "with move [0, 16, 0], gaps 3). Every corner different. For example "
        + json.dumps(dict(CORNER_EXAMPLE, stage=first + next((k for k, p in enumerate(plan) if p["role"] == "corner"), 0)),
                     ensure_ascii=False) + ".",
    ]
    return "\n".join(lines)


def zone_message(spec: dict, zone: int, total_zones: int, per_zone: int) -> str:
    first, count = zone_range(zone, per_zone)
    last = first + count - 1
    total = total_zones * per_zone
    doc = spec.get("director") or {}
    style = doc.get("visual_style") or {}
    planned = _plan(spec).get(zone) or {}
    theme = zone_theme(spec, zone, total_zones)
    parts = ["## Game\n"
             f"title: {spec.get('title') or spec.get('slug')}\npitch: {str(spec.get('pitch') or '')[:400]}\n"
             f"core loop: {str(spec.get('core_loop') or '')[:600]}"
             + (f"\nfantasy: {str(doc.get('fantasy'))[:300]}" if doc.get("fantasy") else "")
             + (f"\nstyle: {json.dumps({k: style.get(k) for k in ('palette', 'mood', 'materials') if style.get(k)})[:300]}"
                if style else "")
             + f"\nThe course has {total_zones} zones of {per_zone} stages ({total} stages). Each zone is a themed "
               "section of the world: it starts on its own start pad and its last checkpoint has a ride gate to the "
               "next zone."]
    head = f"## Zone to design\nZone {zone} of {total_zones}: stages {first} to {last} ({count} stages)."
    if planned.get("name"):
        head += f"\nPlanned name: {planned['name']}" + (f"; theme: {planned['theme']}" if planned.get("theme") else "")
    else:
        head += "\nChoose a name and theme for this zone that fit the game and differ from the zones before it."
    parts.append(head)
    if theme:
        sig = obby.SIGNATURES.get(theme) or ()
        parts.append(f"## Park theme: {theme}\nThis zone is {THEME_NOTES[theme]}\n"
                     + (f"Signature kinds: {' and '.join(label for label, _, _ in sig)}. They make the zone recognisable "
                        "at a glance: build its stages around them, alone first, then combined with the rest."
                        if sig else "Signature: a mix. Combine every kind of the course, three or more per stage.")
                     + "\nThe kit dresses every piece in this theme (colours, props, signs), so pick shapes and "
                       "obstacles that read as this ride.")
    diffs = " ".join(f"{n}:{difficulty(n, total, per_zone)}" for n in range(first, last + 1))
    parts.append("## Difficulty target per stage (1 = very easy, 10 = expert)\n" + diffs + "\n"
                 "1-3: wide platforms, gaps 3-6, rises 0-2, slow movers, tiles solid 3 s or more. "
                 "4-6: gaps 6-8, rises up to 4, two mechanics per stage. "
                 "7-8: gaps 8-9, rises 4-5, narrow platforms, faster timings. "
                 "9-10: near the limits, three or more mechanics. "
                 f"Stage {last} is the zone's finale; every 5th stage of a zone is a breather.")
    used_before = {k for z, p in _plan(spec).items() if z < zone for k in p.get("kinds") or []}
    before, new, allowed = usable_kinds(total, first, last, theme, used_before)
    mech = ["## Mechanics"]
    if before:
        mech.append("Already introduced (use them freely): " + ", ".join(m[1] for m in before) + ".")
    if new:
        mech.append("New in this zone, each first alone in an easy stage at (or near) the stage given:\n"
                    + "\n".join(f"- stage {m[0]}: {m[2]}" for m in new))
    mech.append("Kinds you may use in this zone: " + ", ".join(allowed) + ".")
    parts.append("\n".join(mech))
    parts.append("## Zone rules (checked like the jump limits; any you break come back as corrections)\n"
                 + rules_doc(count, theme))
    parts.append(route_doc(first, count))
    parts.append(WORK_FAST)
    done = [p for z, p in sorted(_plan(spec).items()) if z != zone and p.get("written")]
    if done:
        parts.append("## Zones already designed (one course: keep it consistent, never repeat their names)\n"
                     + "\n".join(f"- Zone {p['zone']} \"{p.get('name')}\" (stages {p.get('stages', ['?', '?'])[0]}-"
                                 f"{p.get('stages', ['?', '?'])[-1]}): {str(p.get('theme') or '')[:120]}; kinds: "
                                 f"{', '.join(p.get('kinds') or [])}" for p in done[-12:]))
    parts.append("## Obstacle kinds (parameters: default [min, max])\n" + obby.kinds_doc())
    parts.append("## Jump limits the validator enforces\n" + obby.limits_doc())
    example = EXAMPLES[theme or "entrance"]
    parts.append("## One valid run stage (its shape, not its numbers: shaped platforms, the signature kinds, a climb, "
                 f"{obby.RUN_LENGTH[0]:g}-{obby.RUN_LENGTH[1]:g} studs)\n" + json.dumps(example, ensure_ascii=False))
    parts.append(f"Return only the zone JSON object with all {count} stages ({first} to {last}).")
    return "\n\n".join(parts)


def zone_overview(zone: dict, first: int, count: int) -> str:
    """One line per stage (its route role, turn, length, where its checkpoint ends in the zone frame, kinds), so a
    correction can fix the zone-wide rules."""
    frames, _ = obby.course_layout(zone, first, count)
    plan = obby.route_plan(count)
    lines = []
    for st, own, nxt in zip(obby.stages_in_range(zone, first, count), frames, frames[1:]):
        kinds = " > ".join(p["kind"] + (f"({p['shape']})" if p.get("shape") not in (None, "block") else "")
                           for p in st.get("pieces") or [])
        k = int(st["stage"]) - first
        role = plan[k]["role"] if 0 <= k < len(plan) else "?"
        lines.append(f"{st['stage']}: {role}, turn {float(st.get('turn') or 0):g} (heading {own['heading']:.0f}), "
                     f"{obby.stage_length(st):.0f} studs, ends at x {nxt['x']:.0f} z {nxt['z']:.0f} height {nxt['y']:.1f}; "
                     f"{kinds}")
    return "\n".join(lines)


def correction_message(user: str, zone: dict, errors: list[str], first: int, count: int,
                       theme: str | None = None) -> str:
    rules = obby.rule_problems(zone, first, count, theme)
    bad = sorted(set(obby.bad_stages(zone, first, count))
                 | {n for p in rules for n in (p.get("stages") or [p["stage"]]) if n})
    shown = errors[:MAX_ERRORS_SHOWN] + ([f"... {len(errors) - MAX_ERRORS_SHOWN} more"]
                                         if len(errors) > MAX_ERRORS_SHOWN else [])
    by_n = {s["stage"]: s for s in zone.get("stages") or []}
    prev = "\n".join(json.dumps(by_n[n], ensure_ascii=False) for n in bad if n in by_n)
    if len(prev) > PREVIOUS_CHARS:
        prev = prev[:PREVIOUS_CHARS] + "\n...[truncated]"
    which = (f"only the corrected stages ({', '.join(map(str, bad))})" if bad else "only the stages you change")
    if rules:
        which += " and any other stages you change to meet the zone rules"
    tail = ("## Your previous level data has errors (the validator's exact messages)\n"
            + "\n".join(f"- {e}" for e in shown)
            + ("\n\n## Your previous version of those stages\n" + prev if prev else "")
            + ("\n\n## The zone now (stage: route role, turn, heading, length, where its checkpoint ends, kinds)\n"
               + zone_overview(zone, first, count)
               if rules else "")
            + f"\n\nFix every error above with margin. Reply with the same JSON object shape containing {which}, each "
              "with all of its pieces.")
    from forge.roles import MAX_USER_CHARS, _truncate
    return _truncate(user, max(4000, MAX_USER_CHARS - len(tail) - 100), label="message") + "\n\n" + tail


def kinds_used(zone: dict) -> list[str]:
    used = {p.get("kind") for s in zone.get("stages") or [] for p in s.get("pieces") or []}
    return [k for k in obby.KIND_ORDER if k in used]


def forge_owned(data: dict, first: int, count: int, theme: str | None) -> dict:
    """What Forge decides, not the level designer: every stage's turn (the route) and, for a park theme, the zone's
    palette (its landmark's colours, obby.THEME_PALETTES), so neighbouring zones never share a look."""
    out = obby.apply_route(data, first, count)
    if theme in obby.THEME_PALETTES:
        out["palette"] = list(obby.THEME_PALETTES[theme])
    return out


def design_zone(llm: Any, spec: dict, zone: int, *, total_zones: int, per_zone: int, session_id: str,
                log: Callable[[str], None] = print, corrections: int = CORRECTIONS) -> tuple[dict, dict]:
    """One zone: the level_designer call, up to `corrections` correction calls in the same task (jump errors and
    zone-rule errors alike), fallbacks for stages still unreachable. -> (zone data, record {zone, first, count,
    theme_id, attempts, corrections, fallback, rules_left, stats})."""
    first, count = zone_range(zone, per_zone)
    theme = zone_theme(spec, zone, total_zones)
    user = zone_message(spec, zone, total_zones, per_zone)
    obj, res = llm.complete_json(ROLE, user, session_id=session_id, required=["stages"], max_tokens=MAX_TOKENS)
    data = forge_owned(obby.normalize_zone(obj, zone, first, count, theme), first, count, theme)

    def check(data: dict) -> tuple[list[str], list[str]]:
        return obby.validate_zone(data, first, count), obby.zone_rules(data, first, count, theme)

    jumps, rules = check(data)
    errors = jumps + rules
    attempts = [{"request_id": res.request_id, "errors": len(errors), "rules": len(rules), "first_errors": errors[:5]}]
    log(f"[levels] zone {zone} \"{data['name']}\" ({theme or 'no park theme'}): {len(data['stages'])} stages, "
        f"{len(jumps)} jump errors, {len(rules)} zone-rule errors")
    for _ in range(corrections):
        if not errors:
            break
        obj, res = llm.complete_json(ROLE, correction_message(user, data, errors, first, count, theme),
                                     session_id=session_id, required=["stages"], max_tokens=MAX_TOKENS)
        data = forge_owned(obby.merge_stages(data, obj), first, count, theme)
        jumps, rules = check(data)
        errors = jumps + rules
        attempts.append({"request_id": res.request_id, "errors": len(errors), "rules": len(rules),
                         "first_errors": errors[:5]})
        log(f"[levels] zone {zone} correction {len(attempts) - 1}: {len(jumps)} jump errors, {len(rules)} zone-rule "
            "errors left")
    data["stages"] = [s for s in data["stages"] if first <= s["stage"] < first + count]
    total = total_zones * per_zone
    fallback = obby.bad_stages(data, first, count)
    if fallback:
        by_n = {s["stage"]: s for s in data["stages"]}
        plan = obby.route_plan(count)
        for n in fallback:
            by_n[n] = obby.fallback_stage(n, difficulty(n, total, per_zone), corner=plan[n - first]["role"] == "corner")
        data["stages"] = [by_n[n] for n in sorted(by_n)]
        data = forge_owned(data, first, count, theme)
        log(f"[levels] zone {zone}: stages {', '.join(map(str, fallback))} still invalid after {corrections} "
            "corrections: replaced with fallback stages")
    rules_left = obby.zone_rules(data, first, count, theme)
    for e in rules_left[:8]:
        log(f"[levels] zone {zone} zone rule still broken: {e}")
    return data, {"zone": zone, "first": first, "count": count, "theme_id": theme, "attempts": attempts,
                  "corrections": len(attempts) - 1, "fallback": fallback, "rules_left": rules_left,
                  "stats": obby.rule_stats(data, first, count, theme)}


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
            theme = zone_theme(spec, zone, total_zones)
            if not obby.validate_zone(data, first, count) and not obby.zone_rules(data, first, count, theme):
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
        plan.append({"zone": zone, "name": data["name"], "theme": data.get("theme", ""), "theme_id": rec["theme_id"],
                     "kinds": kinds_used(data), "stages": [first, first + count - 1], "written": _now(),
                     "request_ids": [a["request_id"] for a in rec["attempts"]], "corrections": rec["corrections"],
                     "fallback": rec["fallback"], "rules_left": len(rec["rules_left"]), "stats": rec["stats"]})
        lv["plan"] = sorted(plan, key=lambda p: int(p.get("zone") or 0))
        store.save_spec(spec)
        with (rec_dir / "log.jsonl").open("a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": _now(), **rec}, ensure_ascii=False) + "\n")
        out.append({"zone": zone, "status": "written", "name": data["name"], "first": first, "count": count,
                    "theme_id": rec["theme_id"], "corrections": rec["corrections"], "fallback": rec["fallback"],
                    "errors": [a["errors"] for a in rec["attempts"]], "rules_left": rec["rules_left"],
                    "stats": rec["stats"]})
    director.install_genre_checks(spec, store.game_dir)
    template.render(spec, store.game_dir)  # a template game's Config takes its zones from the plan above
    compile_errors = _compile(levels_dir)
    stages = sum(len(json.loads(p.read_text(encoding="utf-8")).get("stages") or [])
                 for p in sorted(rec_dir.glob("zone-*.json")))
    return {"slug": slug, "zones": out, "stages": stages, "planned": total_zones * per_zone,
            "calls": _llm_calls(store.calls_log) - calls_before, "compile_errors": compile_errors,
            "ok": not compile_errors and all(not z.get("fallback") and not z.get("rules_left")
                                             and z["status"] != "failed" for z in out)}


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
        left = f", {len(z['rules_left'])} ZONE-RULE errors left" if z.get("rules_left") else ""
        lines.append(f"  zone {z['zone']:>2} \"{z['name']}\" ({z.get('theme_id') or 'no park theme'}): stages "
                     f"{z['first']}-{z['first'] + z['count'] - 1}{fixes}{fb}{left}")
        st = z.get("stats") or {}
        if st:
            lines.append(f"          plain platforms {st['plain_share']:.0%}, {len(st['kinds'])} kinds, "
                         f"{st['distinct_sequences']}/{st['stages']} distinct sequences, {st['turned']} turns, "
                         f"{st['shaped']} shaped platforms, climb {st['climb']:g}, signature {st['signature']}")
            if st.get("extent"):
                x0, x1, z0, z1 = st["extent"]
                lines.append(f"          plot: x {x0:g} to {x1:g}, z {z0:g} to {z1:g}, {st.get('outside_plot', 0)} "
                             "stages outside it")
        for e in (z.get("rules_left") or [])[:5]:
            lines.append(f"          - {e}")
    for e in res.get("compile_errors") or []:
        lines.append(f"  COMPILE {e}")
    return "\n".join(lines)
