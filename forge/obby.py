"""Obby levels as data: the obstacle kinds, the layout of a stage along the course, and the reachability
validator for the default Roblox character. ObbyKit's LevelBuilder (forge/kit/modules/ObbyKit.luau)
runs the same layout and the same rules in Luau, so a check can assert them live; tests/test_obby.py
keeps the two in step (same error messages for the same data).

Course frame: x = sideways (right +), y = up, z = forward along the course. A stage starts on the
previous checkpoint (or the start pad): a PAD_SIZE square pad whose top center is the stage origin.
A stage's `turn` (degrees, -90..90, right +) turns its frame on that pad, so the course curves; under
a turn that is not a multiple of 90 the pad is judged as its inscribed disc (jumps) and its rotated
bounding box (movers), which the real pad always contains / is contained by.
Each piece is placed after the previous piece: `gap` studs forward from its far edge (edge to edge),
`rise` studs up from its top, `side` studs off the stage's center line. A moving platform is placed at
its rest position and moves by `move` (x, y, z) and back, eased, once per `period` seconds.
Platform shapes: block, round (a disc), cylinder (a log across the course: only its top strip, half
the diameter long, is standable; its edges sit LOG_DROP of the radius under the crown) and wedge-ramp
(you land on its low near edge, size height under its top, and leave from its high far end).

Zone rules (Python only, design time; zone_rules): variety (plain-platform share, an obstacle per stage,
no repeated kind sequence, kinds per zone, the theme's signature kinds, turns), the climb (and at most
RUN_CLIMB_MAX per run of the route: the corners lift the levels), the zone staying
inside its plot (PLOT_*: the corridor WorldKit keeps clear beside the zone's ride) and the course never
crossing itself once the turns are laid out in the zone frame (course_layout). Forge owns the turns:
route_plan(count) is a switchback (runs out and back, short corners that turn left and lift a level) and
apply_route writes its turns into the level designer's stages.

Jump physics (measured live in Studio with an R15 character, jump height 7.2, walk 16, gravity 196.2,
jumping 0.75 studs before the edge: lands 10.0 at rise 0, 9.0 at rise 3, 8.0 at rise 6, 11.5 at a 6
stud drop): reach(rise) = walk * airtime(rise) + EDGE_SLACK, capped; a rise is at most 6.

    layout(stage) -> (surfaces, problems)        geometry of one stage
    validate_stage(stage, number) -> [str]       every problem, as "stage N ...: ..." text
    validate_zone(zone, first, count) -> [str]   a zone's stages (numbers first..first+count-1)
    normalize_zone(obj, zone, first, count)      the level designer's JSON -> clean data
    fallback_stage(number, difficulty)           a simple stage that always validates
    render_zone_luau(zone) -> str                ReplicatedStorage/Levels/ZoneNN.luau (data, not code)
"""

from __future__ import annotations

import itertools
import math
import re
from dataclasses import dataclass
from typing import Any, Callable

GRAVITY = 196.2
WALK_SPEED = 16.0
JUMP_HEIGHT = 7.2
JUMP_SPEED = math.sqrt(2 * GRAVITY * JUMP_HEIGHT)
EDGE_SLACK = 1.3       # feet leave from and land on edges, not the character's center
MAX_RISE = 6.0         # normal jump: JUMP_HEIGHT minus a margin
RISE_MARGIN = 1.2      # the same margin under a launch's apex
MIN_RISE = -20.0
MAX_GAP = 12.0         # a normal jump, even off a drop
MAX_LAUNCH_GAP = 20.0  # off a jump pad or trampoline
LAUNCH_HOLD = 0.12     # seconds ObbyKit holds a launch velocity on the character
PAD_SIZE = 10.0        # checkpoints and the start pad (square, PAD_THICK thick)
PAD_THICK = 1.0
MAX_SIDE = 16.0
MAX_STAGE_LENGTH = 200.0
MIN_PIECES, MAX_PIECES = 2, 11  # per stage, the checkpoint included
SAMPLE_DT = 0.1        # movers: jumps are checked at every 0.1 s over SAMPLES steps
SAMPLES = 240
MIN_RUN = 3            # ... and must stay in reach for 3 samples (0.3 s) in a row
HOP_TIME = 0.6         # disappearing tiles: one hop takes this long
CRUSH_HEIGHT = 5.0     # a mover may not pass within this height of another standable piece
BALL_CLEARANCE = 3.0   # pendulum: ball radius (2) + half a character (1)
MAX_TURN = 90.0        # a stage turns at most this much (degrees) on its start pad
SHAPES = ("block", "round", "cylinder", "wedge-ramp")
LOG_MAX_DIAMETER = 8.0
LOG_STRIP = 0.5        # a log's standable strip: half its diameter (the slope stays under 30 degrees)
LOG_DROP = 1 - math.sqrt(3) / 2  # ... whose edges sit this fraction of the radius under the crown
RAMP_MAX_CLIMB = 8.0   # a wedge-ramp climbs at most this (and at most its length: 45 degrees)
CLEARANCE = 13.0       # course crossing: head room over a piece for a jumping player (7.2 jump + 5 body)
CROSS_MARGIN = 1.0     # ... and footprints of different stages stay this far apart
CLIMB_PER_STAGE = 1.0  # a zone ends at least this many studs per stage above its start
VARIETY_SHARE = 0.3    # signature kinds and turns: in at least this share of a zone's stages (6 of 20)
MAX_PLAIN_SHARE = 0.5  # plain (block) platforms: at most half of a stage's pieces
MIN_ZONE_KINDS = 4
MIX_KINDS = 6          # a "mix" zone (the finale) uses at least this many kinds
# A zone's plot, in the zone frame (x right of the start line, z forward from the start pad's center). WorldKit's
# default park (1600 studs) keeps nothing taller than 6 studs within 40 of a course line (ObbyThemes' lamps stand
# 1-2 studs outside a piece), dresses that corridor out to ~480 studs and its fence crosses it at ~529.
PLOT_HALF_WIDTH = 38.0
PLOT_BACK = 10.0
PLOT_LENGTH = 450.0
# Forge's route (route_plan): runs out and back in two lanes, joined by short corner stages that turn left (turning
# right steers a park course into the rides) and lift the course a level, so the runs stack instead of crossing.
CORNER_TURN = -90.0
RUN_LENGTH = (50.0, 80.0)     # a run stage, start pad center to checkpoint center
CORNER_LENGTH = (20.0, 26.0)  # ... a corner: the lanes sit this far apart
CORNER_LIFT = (15.0, 20.0)    # a corner's checkpoint over its start pad (CLEARANCE plus a body, with margin)
RUN_CLIMB_MAX = 12.0          # a run's own net climb: the corners lift the levels, so the stacked runs stay one structure
LANE_HALF_WIDTH = 12.0        # |side| + half a piece's width
MAX_RUN_STAGES = int((PLOT_LENGTH - PAD_SIZE / 2) // RUN_LENGTH[1])  # run stages out from the start, at most (5)
# Park themes (WorldKit landmarks, ObbyThemes decor): one per zone, in the park's order.
THEMES = ("entrance", "carousel", "bumper", "teacups", "ferris", "flume", "haunted", "pirate", "coaster", "finale")
# Each theme's course colours (platforms, accents, highlights), from its WorldKit landmark's palette; mains kept
# apart (CIE76 delta E >= 25 between any two themes) so no two zones read as the same course.
THEME_PALETTES = {
    "entrance": ("#FFC23D", "#E63946", "#3A86FF"), "carousel": ("#FF5FA8", "#FFC23D", "#6EC6FF"),
    "bumper": ("#22B8EE", "#FFD23F", "#FF4F6D"), "teacups": ("#C09CFF", "#5ED6B4", "#FF8EC2"),
    "ferris": ("#FF7A2F", "#3FB8F5", "#FFE066"), "flume": ("#1FA896", "#2F7BFF", "#F4D06F"),
    "haunted": ("#6A3FB5", "#7CFF6B", "#FF8A3D"), "pirate": ("#9C6B3C", "#F2C14E", "#24407A"),
    "coaster": ("#E63946", "#FFD23F", "#1D3557"), "finale": ("#2B2D6E", "#FFC23D", "#FF4FA3"),
}
LEVELS_DIR = "ReplicatedStorage/Levels"  # in the game: one ZoneNN.luau data module per zone
MATERIALS = ("SmoothPlastic", "Plastic", "Wood", "WoodPlanks", "Concrete", "Brick", "Metal", "DiamondPlate",
             "Grass", "Sand", "Marble", "Granite", "Slate", "Fabric", "Foil", "Neon", "Cobblestone", "Pebble")

# Every kind: what it is, whether players stand on it, its round-ness, size default/min/max (w, h, l),
# and its own parameters: name -> (default, min, max) for numbers or (default, [choices]) for strings.
KINDS: dict[str, dict[str, Any]] = {
    "platform": {"describe": "static platform; shape block (a slab), round (a disc: size width is its diameter), "
                             "cylinder (a log lying across the course: size length is its diameter, 2 to 8; only "
                             "its top strip, half the diameter long, counts as standable), wedge-ramp (a ramp you "
                             "walk up: you land on its low near edge, size height under its top, and jump off its "
                             "high far end, which is its top; height up to 8 and at most its length)",
                 "size": (8, 1, 8), "min": (2, 0.5, 2), "max": (40, 4, 40),
                 "params": {"shape": ("block", list(SHAPES))}},
    "checkpoint": {"describe": "the stage's end: saves the stage, players respawn here (fixed 10x1x10 pad)",
                   "size": (PAD_SIZE, PAD_THICK, PAD_SIZE), "min": (PAD_SIZE, PAD_THICK, PAD_SIZE),
                   "max": (PAD_SIZE, PAD_THICK, PAD_SIZE), "params": {}},
    "moving": {"describe": "platform moving from rest to rest+move and back, eased; players ride it",
               "size": (7, 1, 7), "min": (5, 0.5, 5), "max": (16, 2, 16),
               "params": {"move": ((0, 0, 8), -20, 20), "period": (4, 2, 12), "phase": (0, 0, 1)}},
    "spinner": {"describe": "round platform with a kill bar spinning across it at bar_height; jump the bar",
                "round": True, "size": (14, 1, 14), "min": (10, 0.5, 10), "max": (20, 2, 20),
                "params": {"speed": (90, 30, 180), "bar_height": (2, 1, 3)}},
    "turntable": {"describe": "round platform rotating around its center (degrees per second); players ride it",
                  "round": True, "size": (12, 1, 12), "min": (8, 0.5, 8), "max": (20, 2, 20),
                  "params": {"speed": (45, 15, 120)}},
    "disappearing": {"describe": "a row of `count` tiles `spacing` apart; each is solid `on` s (flashing at the "
                                 "end), gone `off` s; tile i runs `stagger` s after tile i-1",
                     "size": (5, 1, 5), "min": (4, 0.5, 4), "max": (10, 2, 10),
                     "params": {"count": (3, 2, 6), "spacing": (3, 0, 10), "on": (2.5, 1.5, 6),
                                "off": (1.5, 0.5, 3), "stagger": (0.6, 0, 2)}},
    "jumppad": {"describe": "pad that launches players up (power, studs/s) with a small forward push",
                "size": (6, 1, 6), "min": (4, 0.5, 4), "max": (10, 2, 10),
                "params": {"power": (90, 60, 130), "forward": (20, 0, 40)}},
    "trampoline": {"describe": "bouncy pad that throws players straight up (bounce, studs/s)",
                   "size": (8, 1, 8), "min": (5, 0.5, 5), "max": (12, 2, 12),
                   "params": {"bounce": (70, 50, 110)}},
    "conveyor": {"describe": "belt that pushes players (speed studs/s, dir forward|back|left|right)",
                 "size": (6, 1, 16), "min": (4, 0.5, 8), "max": (12, 2, 30),
                 "params": {"speed": (8, 2, 12), "dir": ("forward", ["forward", "back", "left", "right"])}},
    "pendulum": {"describe": "bridge with a kill ball swinging across it (swing degrees, period s, rod length)",
                 "size": (6, 1, 14), "min": (4, 0.5, 10), "max": (10, 2, 24),
                 "params": {"swing": (60, 20, 75), "period": (3, 2, 6), "length": (10, 6, 16), "phase": (0, 0, 1)}},
    "lava": {"describe": "kill strip at floor level that must be jumped over (not standable)",
             "standable": False, "size": (8, 1, 4), "min": (2, 0.5, 1), "max": (30, 2, 8), "params": {}},
}
KIND_ORDER = ("platform", "lava", "moving", "disappearing", "jumppad", "conveyor", "trampoline", "spinner",
              "turntable", "pendulum")
COMMON = {"gap": (6, 0, 30), "rise": (0, MIN_RISE, 20), "side": (0, -MAX_SIDE, MAX_SIDE), "coins": (0, 0, 3)}


def _f(v: Any, default: float) -> float:
    try:
        x = float(v)
    except (TypeError, ValueError):
        return float(default)
    return x if math.isfinite(x) else float(default)


def _fmt(x: float) -> str:
    return f"{x:.1f}"


def _range(lo: float, hi: float) -> str:
    return f"[{lo:g}, {hi:g}]"


# ------------------------------------------------------------------------------- normalizing


def normalize_piece(raw: Any) -> dict:
    """One piece with every parameter filled in (defaults), numbers as numbers. Unknown keys dropped;
    an unknown kind is kept so the validator can name it."""
    raw = raw if isinstance(raw, dict) else {}
    kind = str(raw.get("kind") or "").strip().lower()
    spec = KINDS.get(kind)
    out: dict[str, Any] = {"kind": kind}
    for k, (d, _, _) in COMMON.items():
        if k == "coins" and not (spec or {}).get("standable", True):
            continue
        out[k] = _f(raw.get(k), d)
    if spec is None:
        return out
    if kind != "checkpoint":
        size = raw.get("size") if isinstance(raw.get("size"), (list, tuple)) else []
        out["size"] = [_f(size[i] if i < len(size) else None, spec["size"][i]) for i in range(3)]
    for name, p in spec["params"].items():
        if isinstance(p[1], list):
            v = str(raw.get(name) if raw.get(name) is not None else p[0]).strip().lower()
            out[name] = v
        elif isinstance(p[0], tuple):
            v = raw.get(name) if isinstance(raw.get(name), (list, tuple)) else []
            out[name] = [_f(v[i] if i < len(v) else None, p[0][i]) for i in range(3)]
        else:
            out[name] = _f(raw.get(name), p[0])
    if spec.get("round") or out.get("shape") == "round":
        out["size"][2] = out["size"][0]
    elif out.get("shape") == "cylinder":
        out["size"][1] = out["size"][2]
    return out


def normalize_stage(raw: Any, number: int) -> dict:
    raw = raw if isinstance(raw, dict) else {}
    pieces = raw.get("pieces") if isinstance(raw.get("pieces"), list) else []
    out: dict[str, Any] = {"stage": int(_f(raw.get("stage"), number)), "name": str(raw.get("name") or "").strip()[:60],
                           "turn": _f(raw.get("turn"), 0)}
    if raw.get("fallback") is True:
        out["fallback"] = True
    out["pieces"] = [normalize_piece(p) for p in pieces]
    return out


_HEX = re.compile(r"^#?([0-9a-fA-F]{6})$")


def normalize_zone(obj: Any, zone: int, first: int, count: int, theme_id: str | None = None) -> dict:
    """The level designer's reply -> {zone, name, theme, theme_id, palette, material, stages}. Stages are
    matched by their stage number (a missing one stays missing, so the validator names it). theme_id is
    the park theme Forge chose for the zone (THEMES), not the model's."""
    obj = obj if isinstance(obj, dict) else {}
    palette = [("#" + m.group(1).upper()) for m in (_HEX.match(str(c).strip()) for c in obj.get("palette") or [])
               if m][:4]
    material = str(obj.get("material") or "SmoothPlastic")
    material = next((m for m in MATERIALS if m.lower() == material.lower()), "SmoothPlastic")
    stages = []
    for i, raw in enumerate(s for s in obj.get("stages") or [] if isinstance(s, dict)):
        stages.append(normalize_stage(raw, first + i))
    by_n = {s["stage"]: s for s in stages}
    ordered = [by_n[n] for n in range(first, first + count) if n in by_n]
    extra = [s for s in stages if not first <= s["stage"] < first + count]
    out = {"zone": zone, "name": str(obj.get("name") or f"Zone {zone}").strip()[:60],
           "theme": str(obj.get("theme") or "").strip()[:200], "palette": palette, "material": material,
           "stages": ordered + extra}
    if theme_id in THEMES:
        out["theme_id"] = theme_id
    return out


def merge_stages(zone: dict, obj: Any) -> dict:
    """A correction reply (only the corrected stages) merged into the zone by stage number."""
    obj = obj if isinstance(obj, dict) else {}
    out = dict(zone)
    by_n = {s["stage"]: s for s in zone["stages"]}
    for raw in obj.get("stages") or []:
        if isinstance(raw, dict) and raw.get("stage") is not None:
            st = normalize_stage(raw, int(_f(raw.get("stage"), 0)))
            by_n[st["stage"]] = st
    out["stages"] = [by_n[n] for n in sorted(by_n)]
    return out


# ------------------------------------------------------------------------------- layout


@dataclass
class Surface:
    piece: int          # 1-based piece index in the stage; 0 = the pad the stage starts on
    kind: str
    x: float
    z: float
    top: float
    w: float            # footprint width (x) and length (z); a round footprint has w == l == diameter
    l: float
    round: bool = False
    standable: bool = True
    tile: int = -1      # disappearing tiles: index in the row
    move: tuple[float, float, float] | None = None
    period: float = 0.0
    phase: float = 0.0
    launch: float = JUMP_SPEED  # take-off vertical speed from this surface
    walk: float = WALK_SPEED    # take-off horizontal speed (a back conveyor slows it)
    launched: bool = False
    land_drop: float = 0.0      # where a jump lands sits this far under `top` (a ramp's low edge, a log's strip)
    off_drop: float = 0.0       # where a jump takes off sits this far under `top`
    h: float = 0.0              # body thickness under `top` (movers may not pass through it)
    bw: float = -1.0            # body footprint, when wider than the standable one (a log, a turned pad)
    bl: float = -1.0

    def __post_init__(self) -> None:
        self.bw = self.w if self.bw < 0 else self.bw
        self.bl = self.l if self.bl < 0 else self.bl

    def label(self) -> str:
        if self.piece == 0:
            return "the start pad"
        if self.tile >= 0:
            return f"piece {self.piece} ({self.kind} tile {self.tile + 1})"
        return f"piece {self.piece} ({self.kind})"

    def at(self, t: float) -> tuple[float, float, float]:
        if self.move is None:
            return self.x, self.top, self.z
        f = (1 - math.cos(2 * math.pi * (t / self.period + self.phase))) / 2
        return self.x + self.move[0] * f, self.top + self.move[1] * f, self.z + self.move[2] * f


def launch_speed(v: float) -> float:
    """Take-off speed of a launch held LAUNCH_HOLD seconds at v (measured: v 90 -> apex ~32 studs)."""
    return math.sqrt(v * v + 2 * GRAVITY * v * LAUNCH_HOLD)


def _problem(stage: int, piece: int, code: str, text: str) -> dict:
    return {"stage": stage, "piece": piece, "code": code, "text": f"stage {stage} {text}"}


def size_limits(p: dict) -> list[tuple[float, float] | None]:
    """(min, max) per size axis (width, height, length); None = not checked (a log's height is its diameter)."""
    spec = KINDS[p["kind"]]
    lim: list[tuple[float, float] | None] = [(spec["min"][a], spec["max"][a]) for a in range(3)]
    if p.get("shape") == "cylinder":
        lim[1], lim[2] = None, (spec["min"][2], LOG_MAX_DIAMETER)
    elif p.get("shape") == "wedge-ramp":
        lim[1] = (spec["min"][1], RAMP_MAX_CLIMB)
    return lim


def pad_surface(turn: float) -> Surface:
    """The pad a stage starts on, in the stage's (turned) frame."""
    if abs(turn) % 90 < 1e-9:
        return Surface(0, "pad", 0.0, 0.0, 0.0, PAD_SIZE, PAD_SIZE, h=PAD_THICK)
    a = math.radians(turn)
    box = PAD_SIZE * (abs(math.cos(a)) + abs(math.sin(a)))
    return Surface(0, "pad", 0.0, 0.0, 0.0, PAD_SIZE, PAD_SIZE, round=True, h=PAD_THICK, bw=box, bl=box)


def _pad_overlaps(n: int, surfaces: list[Surface], turn: float) -> list[dict]:
    """Under a turn that is not a multiple of 90 the start pad's corners reach past PAD_SIZE / 2: a still piece whose
    body is level with the pad must not start inside it (separating axes: the stage's x/z, then the pad's own)."""
    a = math.radians(turn)
    c, s = math.cos(a), math.sin(a)
    half = PAD_SIZE / 2
    reach = half * (abs(c) + abs(s))
    out, seen = [], set()
    for sf in surfaces[1:]:
        if sf.move is not None or sf.piece in seen or not (sf.top - sf.h < 0 and sf.top > -PAD_THICK):
            continue
        hx, hz = sf.bw / 2, sf.bl / 2
        if abs(sf.x) >= reach + hx or abs(sf.z) >= reach + hz:
            continue
        if abs(sf.x * c + sf.z * s) >= half + hx * abs(c) + hz * abs(s):
            continue
        if abs(-sf.x * s + sf.z * c) >= half + hx * abs(s) + hz * abs(c):
            continue
        seen.add(sf.piece)
        out.append(_problem(n, sf.piece, "param", f"{sf.label()} overlaps the start pad, whose corners reach "
                                                  f"{_fmt(reach)} studs forward after the turn of {turn:g}: start it "
                                                  "further out"))
    return out


def _check_params(n: int, i: int, p: dict) -> list[dict]:
    kind = p["kind"]
    spec = KINDS[kind]
    where = f"piece {i} ({kind}):"
    out = []
    for k, (_, lo, hi) in COMMON.items():
        if k in p and not lo <= p[k] <= hi:
            out.append(_problem(n, i, "param", f"{where} {k} {p[k]:g} out of range {_range(lo, hi)}"))
    if kind != "checkpoint":
        for axis, name in enumerate(("width", "height", "length")):
            lim = size_limits(p)[axis]
            if lim is not None and not lim[0] <= p["size"][axis] <= lim[1]:
                out.append(_problem(n, i, "param", f"{where} size {name} {p['size'][axis]:g} out of range "
                                                   f"{_range(*lim)}"))
    if p.get("shape") == "wedge-ramp" and p["size"][1] > p["size"][2]:
        out.append(_problem(n, i, "param", f"{where} wedge-ramp climbs {p['size'][1]:g} over length "
                                           f"{p['size'][2]:g}; keep its height at most its length (45 degrees)"))
    for name, d in spec["params"].items():
        if isinstance(d[1], list):
            if p[name] not in d[1]:
                out.append(_problem(n, i, "param", f"{where} {name} {p[name]!r} must be one of {', '.join(d[1])}"))
        elif isinstance(d[0], tuple):
            for axis, v in enumerate(p[name]):
                if not d[1] <= v <= d[2]:
                    out.append(_problem(n, i, "param", f"{where} {name}[{axis + 1}] {v:g} out of range "
                                                       f"{_range(d[1], d[2])}"))
        elif not d[1] <= p[name] <= d[2]:
            out.append(_problem(n, i, "param", f"{where} {name} {p[name]:g} out of range {_range(d[1], d[2])}"))
    if kind == "moving":
        m = p["move"]
        if math.sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]) < 2:
            out.append(_problem(n, i, "param", f"{where} move must be at least 2 studs long"))
    if kind == "pendulum":
        reach = p["length"] * math.sin(math.radians(p["swing"]))
        need = p["size"][0] / 2 + BALL_CLEARANCE
        if reach < need:
            out.append(_problem(n, i, "pendulum", f"{where} the ball never clears the bridge "
                                                  f"(length*sin(swing) {_fmt(reach)} < {_fmt(need)})"))
    if kind == "disappearing":
        out += _tile_timing(n, i, p)
    return out


def _tile_timing(n: int, i: int, p: dict) -> list[dict]:
    """Tile j is solid during [j*stagger + k*cycle, ... + on). A player lands on tile 0 as it appears,
    then hops on (HOP_TIME per hop, waiting on a tile while it is solid): every hop must take off
    before the tile under the player vanishes."""
    on, stagger = p["on"], p["stagger"]
    cycle = on + p["off"]
    land, close = 0.0, on
    for j in range(1, int(p["count"])):
        t = land + HOP_TIME
        start = j * stagger + math.floor((t - j * stagger) / cycle) * cycle
        if t < start + on:
            land, end = t, start + on
        else:
            land, end = start + cycle, start + cycle + on
        if land - HOP_TIME > close:
            return [_problem(n, i, "tiles", f"piece {i} (disappearing): tile {j + 1} is not solid in time to hop "
                                            f"onto it from tile {j} (on {on:g}, off {p['off']:g}, stagger "
                                            f"{stagger:g})")]
        close = end
    return []


def layout(stage: dict) -> tuple[list[Surface], list[dict]]:
    """Surfaces of a normalized stage, in course order (the start pad first), plus structure and
    parameter problems. Coordinates are relative to the stage origin (the start pad's top center)."""
    n = int(stage.get("stage") or 0)
    pieces = stage.get("pieces") or []
    problems: list[dict] = []
    if not MIN_PIECES <= len(pieces) <= MAX_PIECES:
        problems.append(_problem(n, 0, "structure", f"has {len(pieces)} pieces; use {MIN_PIECES} to {MAX_PIECES} "
                                                    "(the checkpoint included)"))
    turn = _f(stage.get("turn"), 0)
    if not -MAX_TURN <= turn <= MAX_TURN:
        problems.append(_problem(n, 0, "param", f"turn {turn:g} out of range {_range(-MAX_TURN, MAX_TURN)}"))
    surfaces = [pad_surface(turn)]
    cursor_z, cursor_top = PAD_SIZE / 2, 0.0
    checkpoints = 0
    for i, p in enumerate(pieces, 1):
        kind = p.get("kind")
        spec = KINDS.get(kind)
        if spec is None:
            problems.append(_problem(n, i, "param", f"piece {i}: unknown kind {kind!r} (kinds: {', '.join(KINDS)})"))
            continue
        problems += _check_params(n, i, p)
        if kind == "checkpoint":
            checkpoints += 1
            w, l = PAD_SIZE, PAD_SIZE
        else:
            w, l = p["size"][0], p["size"][2]
        rnd = bool(spec.get("round")) or p.get("shape") == "round"
        top = cursor_top + p["rise"]
        near = cursor_z + p["gap"]
        base = {"kind": kind, "top": top, "w": w, "l": l, "round": rnd,
                "standable": spec.get("standable", True), "h": PAD_THICK if kind == "checkpoint" else p["size"][1]}
        if p.get("shape") == "cylinder":
            base.update(l=l * LOG_STRIP, bl=l, land_drop=l / 2 * LOG_DROP, off_drop=l / 2 * LOG_DROP)
        elif p.get("shape") == "wedge-ramp":
            base.update(land_drop=p["size"][1])
        if kind == "disappearing":
            for j in range(int(p["count"])):
                surfaces.append(Surface(i, x=p["side"], z=near + l / 2, tile=j, **base))
                near = near + l + p["spacing"]
            cursor_z = near - p["spacing"]
        else:
            s = Surface(i, x=p["side"], z=near + l / 2, **base)
            if kind == "moving":
                s.move, s.period, s.phase = tuple(p["move"]), p["period"], p["phase"]
            elif kind == "jumppad":
                s.launch, s.launched = max(JUMP_SPEED, launch_speed(p["power"])), True
            elif kind == "trampoline":
                s.launch, s.launched = max(JUMP_SPEED, launch_speed(p["bounce"])), True
            elif kind == "conveyor" and p["dir"] == "back":
                s.walk = WALK_SPEED - p["speed"]
            surfaces.append(s)
            cursor_z = near + l
        cursor_top = top
    if not pieces or (pieces[-1].get("kind") != "checkpoint"):
        problems.append(_problem(n, len(pieces), "structure", "must end with a checkpoint piece"))
    if checkpoints > 1:
        problems.append(_problem(n, 0, "structure", f"has {checkpoints} checkpoints; only the last piece may be one"))
    if cursor_z > MAX_STAGE_LENGTH:
        problems.append(_problem(n, 0, "length", f"is {_fmt(cursor_z)} studs long; keep it under "
                                                 f"{MAX_STAGE_LENGTH:g}"))
    if abs(turn) % 90 >= 1e-9:
        problems += _pad_overlaps(n, surfaces, turn)
    return surfaces, problems


# ------------------------------------------------------------------------------- jumps


def footprint_gap(a: Surface, pa: tuple[float, float, float], b: Surface, pb: tuple[float, float, float]) -> float:
    """Horizontal edge-to-edge distance between two footprints (0 when they overlap)."""
    dx = abs(pa[0] - pb[0])
    dz = abs(pa[2] - pb[2])
    if a.round and b.round:
        return max(0.0, math.sqrt(dx * dx + dz * dz) - a.w / 2 - b.w / 2)
    if a.round or b.round:
        c, r = (a, b) if a.round else (b, a)
        ex = max(0.0, dx - r.w / 2)
        ez = max(0.0, dz - r.l / 2)
        return max(0.0, math.sqrt(ex * ex + ez * ez) - c.w / 2)
    ex = max(0.0, dx - (a.w + b.w) / 2)
    ez = max(0.0, dz - (a.l + b.l) / 2)
    return math.sqrt(ex * ex + ez * ez)


def max_rise(a: Surface) -> float:
    if not a.launched:
        return MAX_RISE
    return a.launch * a.launch / (2 * GRAVITY) - RISE_MARGIN


def reach(a: Surface, rise: float) -> float | None:
    """Longest gap a jump off `a` clears at this rise, or None if the rise is out of reach."""
    if rise > max_rise(a):
        return None
    v = a.launch
    disc = v * v - 2 * GRAVITY * rise
    if disc < 0:
        return None
    t = (v + math.sqrt(disc)) / GRAVITY
    return min(MAX_LAUNCH_GAP if a.launched else MAX_GAP, max(0.0, a.walk) * t + EDGE_SLACK)


def _jump_at(a: Surface, b: Surface, t: float) -> tuple[bool, float, float, float | None]:
    pa, pb = a.at(t), b.at(t)
    gap = footprint_gap(a, pa, b, pb)
    rise = (pb[1] - b.land_drop) - (pa[1] - a.off_drop)
    lim = reach(a, rise) if rise >= MIN_RISE else None
    return (lim is not None and gap <= lim), gap, rise, lim


def _why(a: Surface, gap: float, rise: float, lim: float | None, sep: str) -> str:
    if rise < MIN_RISE:
        return f"drop {_fmt(-rise)} > max {_fmt(-MIN_RISE)}"
    if lim is None:
        return f"rise {_fmt(rise)} > max {_fmt(max_rise(a))}"
    return f"gap {_fmt(gap)} at rise {_fmt(rise)}{sep}max {_fmt(lim)}"


def _jump_problem(n: int, a: Surface, b: Surface) -> dict | None:
    head = f"jump from {a.label()} to {b.label()}:"
    if a.move is None and b.move is None:
        ok, gap, rise, lim = _jump_at(a, b, 0.0)
        if ok:
            return None
        return _problem(n, b.piece, "jump" if lim is not None else "rise", f"{head} {_why(a, gap, rise, lim, ' > ')}")
    run = best_run = 0
    best = None
    for k in range(SAMPLES):
        ok, gap, rise, lim = _jump_at(a, b, k * SAMPLE_DT)
        run = run + 1 if ok else 0
        best_run = max(best_run, run)
        excess = (gap - lim) if lim is not None else 1000 + abs(rise)
        if best is None or excess < best[0]:
            best = (excess, gap, rise, lim)
    if best_run >= MIN_RUN:
        return None
    _, gap, rise, lim = best
    return _problem(n, b.piece, "jump", f"{head} never in reach for {MIN_RUN * SAMPLE_DT:.1f}s "
                                        f"(closest: {_why(a, gap, rise, lim, ', ')})")


def _crush_problems(n: int, surfaces: list[Surface]) -> list[dict]:
    """A moving platform must not pass through (or right over) another piece someone stands on."""
    out = []
    for m in surfaces:
        if m.move is None:
            continue
        for o in surfaces:
            if o is m or not o.standable:
                continue
            for k in range(0, SAMPLES, 2):
                pm, po = m.at(k * SAMPLE_DT), o.at(k * SAMPLE_DT)
                dx = abs(pm[0] - po[0]) - (m.bw + o.bw) / 2
                dz = abs(pm[2] - po[2]) - (m.bl + o.bl) / 2
                if dx < 0 and dz < 0 and pm[1] - m.h < po[1] + CRUSH_HEIGHT and po[1] - o.h < pm[1] + CRUSH_HEIGHT:
                    out.append(_problem(n, m.piece, "mover", f"piece {m.piece} (moving) passes through "
                                                             f"{o.label()}"))
                    break
    return out


def _lava_problems(n: int, surfaces: list[Surface]) -> list[dict]:
    out = []
    for i, s in enumerate(surfaces):
        if s.standable:
            continue
        prev = next((x for x in reversed(surfaces[:i]) if x.standable), None)
        nxt = next((x for x in surfaces[i + 1:] if x.standable), None)
        around = ([prev.top - prev.off_drop] if prev else []) + ([nxt.top - nxt.land_drop] if nxt else [])
        floor = min(around) if around else s.top
        if s.top > floor + 0.5:
            out.append(_problem(n, s.piece, "lava", f"piece {s.piece} (lava): top {_fmt(s.top)} is above the floor "
                                                    f"around it ({_fmt(floor)}); kill parts lie at floor level"))
    return out


def stage_problems(stage: dict, number: int | None = None) -> list[dict]:
    surfaces, problems = layout(stage)
    n = int(stage.get("stage") or 0)
    if number is not None and n != number:
        problems.insert(0, _problem(n, 0, "structure", f"should be stage {number}"))
    standable = [s for s in surfaces if s.standable]
    for a, b in zip(standable, standable[1:]):
        p = _jump_problem(n, a, b)
        if p:
            problems.append(p)
    problems += _lava_problems(n, surfaces)
    problems += _crush_problems(n, surfaces)
    return problems


def validate_stage(stage: dict, number: int | None = None) -> list[str]:
    return [p["text"] for p in stage_problems(stage, number)]


def validate_zone(zone: dict, first: int, count: int) -> list[str]:
    """Every problem of a normalized zone that should hold stages first..first+count-1."""
    stages = zone.get("stages") or []
    have = {s.get("stage") for s in stages}
    errors = [f"stage {n} is missing" for n in range(first, first + count) if n not in have]
    errors += [f"stage {s.get('stage')} is outside this zone's range {first}-{first + count - 1}"
               for s in stages if not first <= int(s.get("stage") or 0) < first + count]
    for s in stages:
        if first <= int(s.get("stage") or 0) < first + count:
            errors += validate_stage(s, int(s["stage"]))
    return errors


def bad_stages(zone: dict, first: int, count: int) -> list[int]:
    """Stage numbers in the range that are missing or have a problem."""
    by_n = {s.get("stage"): s for s in zone.get("stages") or []}
    return [n for n in range(first, first + count) if n not in by_n or validate_stage(by_n[n], n)]


# ------------------------------------------------------------------------------- zone rules (design time)


OBSTACLES = tuple(k for k in KIND_ORDER if k != "platform")


def is_plain(p: dict) -> bool:
    return p.get("kind") == "platform" and p.get("shape", "block") == "block"


def _vertical_mover(p: dict) -> bool:
    m = p.get("move") or (0, 0, 0)
    return p.get("kind") == "moving" and abs(m[1]) >= 4 and abs(m[1]) >= math.hypot(m[0], m[2])


def _sig(kind: str, label: str = "", test: Callable[[dict], bool] | None = None) -> tuple:
    return label or kind, kind, test or (lambda p: p.get("kind") == kind)


# theme -> (label, kind, test) per signature kind; each must appear in VARIETY_SHARE of the zone's stages.
# The finale has none: it must mix at least MIX_KINDS kinds instead.
SIGNATURES: dict[str, tuple[tuple[str, str, Callable[[dict], bool]], ...]] = {
    "entrance": (_sig("platform", "shaped platforms (round, cylinder or wedge-ramp)",
                      lambda p: p.get("kind") == "platform" and not is_plain(p)), _sig("jumppad")),
    "carousel": (_sig("turntable"), _sig("moving")),
    "bumper": (_sig("moving"), _sig("conveyor")),
    "teacups": (_sig("spinner"), _sig("turntable")),
    "ferris": (_sig("moving", "vertical moving platforms (move y at least 4 and more than sideways)", _vertical_mover),
               _sig("trampoline")),
    "flume": (_sig("conveyor"), _sig("lava", "lava (built as water)")),
    "haunted": (_sig("disappearing"), _sig("lava")),
    "pirate": (_sig("pendulum"), _sig("moving")),
    "coaster": (_sig("moving"), _sig("jumppad")),
    "finale": (),
}


def share_need(count: int) -> int:
    """Stages that must carry a signature kind or a turn: VARIETY_SHARE of the zone, at least 1 (6 of 20)."""
    return max(1, math.ceil(round(count * VARIETY_SHARE, 9)))


def _numbers(ns: list[int]) -> str:
    return ", ".join(map(str, ns[:-1])) + f" and {ns[-1]}" if len(ns) > 1 else str(ns[0]) if ns else "none"


def stages_in_range(zone: dict, first: int, count: int) -> list[dict]:
    return sorted((s for s in zone.get("stages") or [] if first <= int(s.get("stage") or 0) < first + count),
                  key=lambda s: int(s["stage"]))


def _body(stage: dict) -> list[dict]:
    return [p for p in stage.get("pieces") or [] if p.get("kind") != "checkpoint"]


@dataclass
class Region:
    """A piece (or the gap a jump crosses) laid out in the zone frame, for the course-crossing rule."""
    stage: int
    piece: int
    kind: str
    gap: bool
    cx: float
    cz: float
    heading: float      # radians, right +; the region's x/z half extents are along this heading
    hx: float
    hz: float
    lo: float
    hi: float

    def own(self) -> str:
        head = f"piece {self.piece} ({self.kind})"
        return f"jump to {head}" if self.gap else head

    def label(self) -> str:
        if self.piece == 0:
            return "the zone's start pad"
        head = f"stage {self.stage} piece {self.piece} ({self.kind})"
        return f"the jump to {head}" if self.gap else head


def _to_zone(frame: tuple[float, float, float, float], x: float, y: float, z: float) -> tuple[float, float, float]:
    ox, oy, oz, a = frame
    return ox + x * math.cos(a) + z * math.sin(a), oy + y, oz - x * math.sin(a) + z * math.cos(a)


def _stage_regions(n: int, surfaces: list[Surface], frame: tuple[float, float, float, float]) -> list[Region]:
    out = []

    def add(piece, kind, gap, x, z, hx, hz, lo, hi):
        cx, _, cz = _to_zone(frame, x, 0.0, z)
        out.append(Region(n, piece, kind, gap, cx, cz, frame[3], hx, hz, frame[1] + lo, frame[1] + hi))

    for s in surfaces[1:]:
        m = s.move or (0.0, 0.0, 0.0)
        add(s.piece, s.kind, False, s.x + m[0] / 2, s.z + m[2] / 2, s.bw / 2 + abs(m[0]) / 2, s.bl / 2 + abs(m[2]) / 2,
            s.top - s.h + min(0.0, m[1]), s.top + max(0.0, m[1]) + CLEARANCE)
    standable = [s for s in surfaces if s.standable]
    for a, b in zip(standable, standable[1:]):
        z0, z1 = a.z + a.bl / 2, b.z - b.bl / 2
        if z1 - z0 < 0.5 or (a.piece == b.piece and a.tile >= 0):
            continue
        x0, x1 = min(a.x - a.bw / 2, b.x - b.bw / 2), max(a.x + a.bw / 2, b.x + b.bw / 2)
        add(b.piece, b.kind, True, (x0 + x1) / 2, (z0 + z1) / 2, (x1 - x0) / 2, (z1 - z0) / 2,
            min(a.top, b.top), max(a.top, b.top) + CLEARANCE)
    return out


def course_layout(zone: dict, first: int, count: int) -> tuple[list[dict], list[Region]]:
    """Every stage's frame in the zone frame (the zone's start pad: origin, heading 0) once the turns are
    applied, and every piece and jump gap as a Region. -> ([{stage, x, y, z, heading}], regions)."""
    frames, regions = [], []
    x = y = z = heading = 0.0
    regions.append(Region(first, 0, "pad", False, 0.0, 0.0, 0.0, PAD_SIZE / 2, PAD_SIZE / 2, -PAD_THICK, CLEARANCE))
    for st in stages_in_range(zone, first, count):
        heading += math.radians(_f(st.get("turn"), 0))
        frame = (x, y, z, heading)
        surfaces, _ = layout(st)
        n = int(st["stage"])
        frames.append({"stage": n, "x": x, "y": y, "z": z, "heading": math.degrees(heading)})
        regions += _stage_regions(n, surfaces, frame)
        end = surfaces[-1]
        x, y, z = _to_zone(frame, end.x, end.top, end.z)
    frames.append({"stage": None, "x": x, "y": y, "z": z, "heading": math.degrees(heading)})
    return frames, regions


def _separated(a: Region, b: Region) -> bool:
    if math.hypot(a.cx - b.cx, a.cz - b.cz) > math.hypot(a.hx, a.hz) + math.hypot(b.hx, b.hz) + CROSS_MARGIN:
        return True
    dx, dz = b.cx - a.cx, b.cz - a.cz
    for h in (a.heading, b.heading):
        for ux, uz in ((math.cos(h), -math.sin(h)), (math.sin(h), math.cos(h))):
            ra = a.hx * abs(math.cos(a.heading) * ux - math.sin(a.heading) * uz) + \
                a.hz * abs(math.sin(a.heading) * ux + math.cos(a.heading) * uz)
            rb = b.hx * abs(math.cos(b.heading) * ux - math.sin(b.heading) * uz) + \
                b.hz * abs(math.sin(b.heading) * ux + math.cos(b.heading) * uz)
            if abs(dx * ux + dz * uz) >= ra + rb + CROSS_MARGIN:
                return True
    return False


def crossing_problems(zone: dict, first: int, count: int) -> list[dict]:
    """The course may not run into itself: a piece (or a jump gap) of one stage overlapping a piece of another
    within CLEARANCE of height. The pad two stages share (a checkpoint and the next stage's start) is skipped."""
    _, regions = course_layout(zone, first, count)
    last_piece = {}
    for r in regions:
        if not r.gap:
            last_piece[r.stage] = max(last_piece.get(r.stage, 0), r.piece)
    out, seen = [], set()
    for i, a in enumerate(regions):
        for b in regions[i + 1:]:
            if a.stage == b.stage or (a.gap and b.gap) or (a.stage, b.stage) in seen:
                continue
            lo, hi = (a, b) if a.stage < b.stage else (b, a)
            if hi.stage == lo.stage + 1 and not lo.gap and lo.piece == last_piece.get(lo.stage):
                continue
            if a.lo >= b.hi or b.lo >= a.hi or _separated(a, b):
                continue
            seen.add((a.stage, b.stage))
            out.append(_problem(hi.stage, hi.piece, "crossing", f"{hi.own()} runs into {lo.label()}: the course "
                                "crosses itself after its turns; turn the other way, climb higher or shift it sideways"))
    return sorted(out, key=lambda p: p["stage"])


def climb(zone: dict, first: int, count: int) -> float:
    """Height of the zone's last checkpoint over its start."""
    frames, _ = course_layout(zone, first, count)
    return frames[-1]["y"]


def stage_length(stage: dict) -> float:
    """Studs from the start pad's center to the checkpoint's center (where the next stage starts)."""
    surfaces, _ = layout(stage)
    return surfaces[-1].z if len(surfaces) > 1 else 0.0


def _run_sizes(count: int, corners: int) -> list[int]:
    base, extra = divmod(count - corners, corners + 1)
    runs = [base] * (corners + 1)
    if extra == 0 and corners:
        runs[0] += 1
        runs[-1] -= 1
    last_back = corners if corners % 2 else corners - 1
    for k in [*range(0, corners + 1, 2), *range(last_back, 0, -2)][:extra]:
        runs[k] += 1
    return runs


def route_plan(count: int) -> list[dict]:
    """Forge's route for a zone of `count` stages, so it fits its plot: runs of stages going out (+z) and back (-z),
    each U-turn a short corner stage turning CORNER_TURN (and lifting the course a level) plus the next run's first
    stage turning CORNER_TURN again. Enough U-turns for the turn share, and more while the far end would lie over
    MAX_RUN_STAGES run stages out. The first run out is a stage longer than any run back and spare stages go to the
    runs out (then to the last runs back), so every run back ends a stage in front of the start.
    -> [{stage index 0.., role run|corner, turn, run (1..), dir out|back}]."""
    if count <= 0:
        return []
    corners = min(math.ceil(share_need(count) / 2), count - 1)
    runs = _run_sizes(count, corners)
    while corners < (count - 1) // 2 and max(itertools.accumulate((n if k % 2 == 0 else -n for k, n in enumerate(runs)))) \
            > MAX_RUN_STAGES:
        corners += 1
        runs = _run_sizes(count, corners)
    out = []
    for k, size in enumerate(runs):
        way = "out" if k % 2 == 0 else "back"
        for j in range(size):
            out.append({"index": len(out), "role": "run", "turn": CORNER_TURN if k and not j else 0.0, "run": k + 1,
                        "dir": way})
        if k < corners:
            out.append({"index": len(out), "role": "corner", "turn": CORNER_TURN, "run": k + 1, "dir": way})
    return out


def apply_route(zone: dict, first: int, count: int) -> dict:
    """The zone with every stage in first..first+count-1 turned as route_plan says (Forge owns the turns). A turn of
    0 or +-90 keeps the start pad square, so a stage that was reachable stays reachable."""
    plan = route_plan(count)
    out = dict(zone)
    out["stages"] = [dict(s, turn=plan[int(s["stage"]) - first]["turn"]) if first <= int(s.get("stage") or 0) < first + count
                     else s for s in zone.get("stages") or []]
    return out


def _extent(r: Region) -> tuple[float, float]:
    c, s = abs(math.cos(r.heading)), abs(math.sin(r.heading))
    return r.hx * c + r.hz * s, r.hx * s + r.hz * c


def run_climbs(zone: dict, first: int, count: int) -> list[dict]:
    """Per run of the route: {run, stages [a, b], climb} (its last checkpoint over the pad its first stage starts on)."""
    frames, _ = course_layout(zone, first, count)
    at = {f["stage"]: f for f in frames if f["stage"] is not None}
    ends = {f_prev["stage"]: f_next for f_prev, f_next in zip(frames, frames[1:]) if f_prev["stage"] is not None}
    out: list[dict] = []
    for p in route_plan(count):
        n = first + p["index"]
        if p["role"] != "run" or n not in at:
            continue
        if out and out[-1]["run"] == p["run"] and out[-1]["stages"][1] == n - 1:
            out[-1]["stages"][1] = n
        else:
            out.append({"run": p["run"], "stages": [n, n], "start": at[n]["y"]})
        out[-1]["climb"] = round(ends[n]["y"] - out[-1]["start"], 1)
    return [{k: v for k, v in r.items() if k != "start"} for r in out]


def run_climb_problems(zone: dict, first: int, count: int) -> list[dict]:
    """Each run of the route climbs at most RUN_CLIMB_MAX: the corners do the climbing, a level each."""
    out = []
    for r in run_climbs(zone, first, count):
        a, b = r["stages"]
        if r["climb"] > RUN_CLIMB_MAX + 1e-9:
            where = f"stages {a}-{b}" if b > a else f"stage {a}"
            out.append({"stage": a, "piece": 0, "code": "climb", "stages": list(range(a, b + 1)),
                        "text": f"the zone's run {r['run']} ({where}) climbs {_fmt(r['climb'])} studs; a run climbs at most "
                                f"{RUN_CLIMB_MAX:g} (the corners lift the course a level each): after a rise or a jump "
                                "pad's high platform, drop back down"})
    return out


def footprint_problems(zone: dict, first: int, count: int) -> list[dict]:
    """Every piece, mover's path and jump of the zone stays inside its plot (PLOT_*, the zone frame): one problem
    per stage that leaves it, naming its piece that leaves it furthest."""
    _, regions = course_layout(zone, first, count)
    worst: dict[int, tuple] = {}
    for r in regions:
        if r.piece == 0:
            continue
        ex, ez = _extent(r)
        for over, axis, value, edge, limit in (
                (-PLOT_HALF_WIDTH - (r.cx - ex), "x", r.cx - ex, "left edge", -PLOT_HALF_WIDTH),
                (r.cx + ex - PLOT_HALF_WIDTH, "x", r.cx + ex, "right edge", PLOT_HALF_WIDTH),
                (-PLOT_BACK - (r.cz - ez), "z", r.cz - ez, "back edge", -PLOT_BACK),
                (r.cz + ez - PLOT_LENGTH, "z", r.cz + ez, "far end", PLOT_LENGTH)):
            if over > 1e-6 and over > worst.get(r.stage, (0.0,))[0]:
                worst[r.stage] = (over, r, axis, value, edge, limit)
    return [_problem(n, r.piece, "footprint", f"{r.own()} leaves the zone's plot: {axis} {_fmt(value)} is past its {edge} "
                                              f"({limit:g}); keep to the route's turns and stage lengths")
            for n, (_, r, axis, value, edge, limit) in sorted(worst.items())]


def extent(zone: dict, first: int, count: int) -> list[float]:
    """[x min, x max, z min, z max] of everything the zone lays out, in the zone frame."""
    _, regions = course_layout(zone, first, count)
    boxes = [(r.cx, r.cz, *_extent(r)) for r in regions]
    return [round(min(x - ex for x, _, ex, _ in boxes), 1), round(max(x + ex for x, _, ex, _ in boxes), 1),
            round(min(z - ez for _, z, _, ez in boxes), 1), round(max(z + ez for _, z, _, ez in boxes), 1)]


def rule_problems(zone: dict, first: int, count: int, theme: str | None = None) -> list[dict]:
    """The zone rules beyond reachability: variety, the theme's signature kinds, turns, the climb, the zone staying
    inside its plot and the course never crossing itself. Stage problems carry their stage; zone problems stage 0."""
    stages = stages_in_range(zone, first, count)
    out: list[dict] = []
    seqs: dict[tuple[str, ...], list[int]] = {}
    for st in stages:
        n, body = int(st["stage"]), _body(st)
        plain = sum(1 for p in body if is_plain(p))
        if body and plain > MAX_PLAIN_SHARE * len(body):
            out.append(_problem(n, 0, "variety", f"has {plain} plain platforms in its {len(body)} pieces (the "
                                                 "checkpoint not counted); at most half may be plain block platforms: "
                                                 "use round, cylinder or wedge-ramp shapes or obstacles"))
        if body and not any(p.get("kind") in OBSTACLES for p in body):
            out.append(_problem(n, 0, "variety", f"has no obstacle: give it at least one of {', '.join(OBSTACLES)}"))
        seqs.setdefault(tuple(p.get("kind") for p in body), []).append(n)
    for seq, ns in seqs.items():
        if len(ns) > 1:
            out.append(dict(_problem(ns[0], 0, "variety", f"and stage{'s' if len(ns) > 2 else ''} {_numbers(ns[1:])} "
                                     f"share the kind sequence [{', '.join(seq)}]; no two stages of a zone may: change "
                                     "all but one"), stages=ns))
    def zp(text: str) -> dict:
        return {"stage": 0, "piece": 0, "code": "zone", "text": f"the zone {text}"}

    kinds =[k for k in KIND_ORDER if any(p.get("kind") == k for st in stages for p in _body(st))]
    need = MIX_KINDS if theme == "finale" else MIN_ZONE_KINDS
    if stages and len(kinds) < need:
        out.append(zp(f"uses {len(kinds)} kinds ({', '.join(kinds) or 'none'}); use at least {need}"
                      + (" (the finale is a mix of everything)" if theme == "finale" else "")))
    want = share_need(count)
    for label, _, test in SIGNATURES.get(theme or "", ()):
        has = [int(st["stage"]) for st in stages if any(test(p) for p in _body(st))]
        if len(has) < want:
            out.append(zp(f"is the {theme} zone: its signature kind {label} is in {len(has)} of its {count} stages "
                          f"({_numbers(has)}); use it in at least {want}"))
    turned = [int(st["stage"]) for st in stages if abs(_f(st.get("turn"), 0)) > 1e-9]
    if stages and len(turned) < want:
        out.append(zp(f"turns in {len(turned)} of its {count} stages ({_numbers(turned)}); at least {want} need a "
                      f"turn (turn {-MAX_TURN:g} to {MAX_TURN:g} degrees, right +, on the stage's start pad)"))
    if stages:
        up, need_up = climb(zone, first, count), CLIMB_PER_STAGE * count
        if up < need_up:
            out.append(zp(f"climbs {_fmt(up)} studs from its start to its last checkpoint; it must climb at least "
                          f"{need_up:g} ({CLIMB_PER_STAGE:g} per stage): add rises, wedge-ramps or jump pads"))
        out += run_climb_problems(zone, first, count)
        out += footprint_problems(zone, first, count)
        out += crossing_problems(zone, first, count)
    return out


def zone_rules(zone: dict, first: int, count: int, theme: str | None = None) -> list[str]:
    return [p["text"] for p in rule_problems(zone, first, count, theme)]


def rule_stats(zone: dict, first: int, count: int, theme: str | None = None) -> dict:
    """The variety numbers of a zone (forge levels' record and summary)."""
    stages = stages_in_range(zone, first, count)
    body = [p for st in stages for p in _body(st)]
    kinds = [k for k in KIND_ORDER if any(p.get("kind") == k for p in body)]
    want = share_need(count)
    sig = {label: sum(1 for st in stages if any(test(p) for p in _body(st)))
           for label, _, test in SIGNATURES.get(theme or "", ())}
    return {"stages": len(stages), "pieces": len(body),
            "plain_share": round(sum(1 for p in body if is_plain(p)) / len(body), 3) if body else 0.0,
            "kinds": kinds, "distinct_sequences": len({tuple(p.get("kind") for p in _body(st)) for st in stages}),
            "turned": sum(1 for st in stages if abs(_f(st.get("turn"), 0)) > 1e-9), "signature": sig,
            "need": want, "climb": round(climb(zone, first, count), 1) if stages else 0.0,
            "shaped": sum(1 for p in body if p.get("kind") == "platform" and not is_plain(p)),
            "extent": extent(zone, first, count) if stages else [0.0, 0.0, 0.0, 0.0],
            "outside_plot": len(footprint_problems(zone, first, count)) if stages else 0}


# ------------------------------------------------------------------------------- fallback


CORNER_FALLBACKS = (
    [{"kind": "jumppad", "gap": 4}, {"kind": "checkpoint", "gap": 6, "rise": 16}],
    [{"kind": "trampoline", "gap": 4}, {"kind": "checkpoint", "gap": 4, "rise": 16}],
    [{"kind": "moving", "gap": 3, "move": [0, 16, 0], "period": 5}, {"kind": "checkpoint", "gap": 3, "rise": 16}],
)


def fallback_stage(number: int, difficulty: int = 3, corner: bool = False) -> dict:
    """A short stage that always validates and keeps the per-stage variety rules (one obstacle, at most one
    plain platform in three), used only when the level designer could not fix a stage in its retries. Four
    layouts take turns by stage number, so neighbouring fallbacks differ; harder stages get longer gaps. A route
    corner's fallback is one of three short lifts (CORNER_LENGTH long, CORNER_LIFT up)."""
    if corner:
        return {"stage": number, "name": f"Stage {number}", "turn": CORNER_TURN, "fallback": True,
                "pieces": [normalize_piece(p) for p in CORNER_FALLBACKS[number % len(CORNER_FALLBACKS)]]}
    d = max(1, min(10, int(difficulty)))
    g = 4 + d * 0.35
    rnd = {"kind": "platform", "shape": "round", "gap": g, "rise": 0, "size": [8, 1, 8]}
    block = {"kind": "platform", "gap": g, "rise": 0, "size": [8, 1, 8]}
    middle = [
        [rnd, {"kind": "lava", "gap": 0, "rise": -0.5, "size": [8, 1, 3]}, dict(block, gap=0, rise=0.5)],
        [{"kind": "platform", "shape": "wedge-ramp", "gap": g, "rise": 2, "size": [8, 2, 8]},
         {"kind": "moving", "gap": 10, "move": [0, 0, -6], "period": 4}, dict(rnd, gap=8)],
        [rnd, {"kind": "jumppad", "gap": g}, dict(block, gap=6, rise=8)],
        [{"kind": "platform", "shape": "cylinder", "gap": g, "rise": 1, "size": [10, 4, 4]},
         {"kind": "conveyor", "gap": 4, "dir": "forward"}, block],
    ][number % 4]
    pieces = middle + [{"kind": "checkpoint", "gap": g, "rise": 0, "side": 0}]
    return {"stage": number, "name": f"Stage {number}", "turn": 0.0, "fallback": True,
            "pieces": [normalize_piece(p) for p in pieces]}


# ------------------------------------------------------------------------------- docs for the user message


def kinds_doc() -> str:
    """Every kind with its parameters' defaults and ranges (the level designer's user message)."""
    common = ", ".join(f"{k} {d[0]:g} {_range(d[1], d[2])}" for k, d in COMMON.items())
    lines = [f"Every stage: stage, name, turn 0 {_range(-MAX_TURN, MAX_TURN)} (degrees, right +: the stage's frame "
             "turns on its start pad, so the course curves), pieces.",
             f"Every piece: kind, {common} (coins only on standable pieces)."]
    for kind in ("checkpoint",) + KIND_ORDER:
        spec = KINDS[kind]
        parts = []
        if kind != "checkpoint":
            size = "x".join(f"{v:g}" for v in spec["size"])
            parts.append(f"size [w,h,l] {size} (min {'x'.join(f'{v:g}' for v in spec['min'])}, "
                         f"max {'x'.join(f'{v:g}' for v in spec['max'])})")
        for name, d in spec["params"].items():
            if isinstance(d[1], list):
                parts.append(f"{name} \"{d[0]}\" ({'|'.join(d[1])})")
            elif isinstance(d[0], tuple):
                parts.append(f"{name} [{', '.join(f'{v:g}' for v in d[0])}] (each {_range(d[1], d[2])})")
            else:
                parts.append(f"{name} {d[0]:g} {_range(d[1], d[2])}")
        lines.append(f"- {kind}: {spec['describe']}" + (f". {'; '.join(parts)}" if parts else ""))
    lines.append("Materials: " + ", ".join(MATERIALS))
    return "\n".join(lines)


def _plain(launch: float = JUMP_SPEED, walk: float = WALK_SPEED, launched: bool = False) -> Surface:
    return Surface(0, "x", 0, 0, 0, 1, 1, launch=launch, walk=walk, launched=launched)


def limits_doc() -> str:
    """The jump limits the validator enforces, as numbers the level designer can design against."""
    plain = _plain()
    rows = ", ".join(f"rise {r:g}: {_fmt(reach(plain, r))}" for r in (6, 4, 2, 0, -4, -10))
    pad = _plain(max(JUMP_SPEED, launch_speed(90)), launched=True)
    tramp = _plain(max(JUMP_SPEED, launch_speed(70)), launched=True)
    return "\n".join([
        f"- Character: walk {WALK_SPEED:g} studs/s, jump height {JUMP_HEIGHT:g}, gravity {GRAVITY:g}.",
        f"- A normal jump rises at most {MAX_RISE:g} studs; drops down to {-MIN_RISE:g} studs are fine.",
        f"- Longest gap (edge to edge, horizontal, sideways offset included) by rise: {rows} (cap {MAX_GAP:g}).",
        f"- Off a jumppad the launch is much higher: power 90 rises up to {_fmt(max_rise(pad))}, gap "
        f"{_fmt(reach(pad, 10))} at rise 10; a trampoline bounce 70 rises up to {_fmt(max_rise(tramp))}, gap "
        f"{_fmt(reach(tramp, 5))} at rise 5 (cap {MAX_LAUNCH_GAP:g}).",
        "- Off a conveyor running back at speed s, take-off speed is 16 - s (shorter jumps).",
        f"- Jumps onto or off a moving platform are checked every {SAMPLE_DT:g} s of its motion: it must be in "
        f"reach for {MIN_RUN * SAMPLE_DT:.1f} s in a row. A moving platform may not pass through another piece.",
        f"- Disappearing tiles: a hop takes {HOP_TIME:g} s; each tile must stay solid until it can be left "
        "(stagger <= on - 0.6 is always safe).",
        "- Lava lies at floor level (its top at most 0.5 above the lower platform next to it); the jump over it, "
        "from the last standable piece to the next, must be in reach.",
        f"- Pendulum: length*sin(swing) must be at least half the bridge width + {BALL_CLEARANCE:g}, so the ball clears.",
        f"- A stage has {MIN_PIECES} to {MAX_PIECES} pieces (the final checkpoint included) and is at most "
        f"{MAX_STAGE_LENGTH:g} studs long.",
        "- A turn that is not -90, 0 or 90 judges the first jump from the inscribed circle of the start pad (5 studs "
        "around its center), so keep that jump a little shorter.",
        f"- Cylinder (log): you stand on its top strip, half the diameter long, {LOG_DROP:.3f} of the radius under "
        "its crown, so jumps onto and off it are measured from that strip. Wedge-ramp: a jump onto it lands on the "
        "low near edge (size height under its top); the next jump leaves from its top.",
        f"- A moving platform's whole body (its thickness) must stay {CRUSH_HEIGHT:g} studs clear of every other "
        "piece's body and top.",
    ])


# ------------------------------------------------------------------------------- Luau data module


def _num(v: float) -> str:
    v = float(v)
    return str(int(v)) if v.is_integer() and abs(v) < 1e15 else repr(v)


def _lua_str(s: str) -> str:
    out = []
    for ch in str(s):
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ord(ch) < 32 or ord(ch) == 127:
            out.append(f"\\{ord(ch):03d}")
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def _lua(v: Any) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return _num(v)
    if isinstance(v, str):
        return _lua_str(v)
    if isinstance(v, (list, tuple)):
        return "{ " + ", ".join(_lua(x) for x in v) + " }"
    if isinstance(v, dict):
        items = []
        for k, x in v.items():
            if x is None:
                continue
            key = k if re.fullmatch(r"[A-Za-z_]\w*", str(k)) else f"[{_lua_str(str(k))}]"
            items.append(f"{key} = {_lua(x)}")
        return "{ " + ", ".join(items) + " }"
    raise TypeError(f"cannot render {type(v).__name__} as Luau")


def render_zone_luau(zone: dict) -> str:
    """ReplicatedStorage/Levels/ZoneNN.luau: the zone as a Luau table (one stage per line block)."""
    first = zone["stages"][0]["stage"] if zone.get("stages") else 0
    last = zone["stages"][-1]["stage"] if zone.get("stages") else 0
    head = {k: zone.get(k) for k in ("zone", "name", "theme", "theme_id", "palette", "material")}
    lines = [f"-- Zone {zone['zone']}: {str(zone.get('name') or '').replace(chr(10), ' ')} (stages {first}-{last}). "
             "Level data written by `forge levels` (Mubit level_designer), built by ObbyKit. Data, not code.",
             "return {"]
    for k, v in head.items():
        if v not in (None, "", []):
            lines.append(f"\t{k} = {_lua(v)},")
    lines.append("\tstages = {")
    for s in zone.get("stages") or []:
        meta = ", ".join(f"{k} = {_lua(s[k])}" for k in ("stage", "name", "turn", "fallback")
                         if s.get(k) not in (None, "", 0))
        lines.append(f"\t\t{{ {meta}, pieces = {{")
        for p in s.get("pieces") or []:
            lines.append(f"\t\t\t{_lua(p)},")
        lines.append("\t\t} },")
    lines.append("\t},")
    lines.append("}")
    return "\n".join(lines) + "\n"
