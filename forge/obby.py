"""Obby levels as data: the obstacle kinds, the layout of a stage along the course, and the reachability
validator for the default Roblox character. ObbyKit's LevelBuilder (forge/kit/modules/ObbyKit.luau)
runs the same layout and the same rules in Luau, so a check can assert them live; tests/test_obby.py
keeps the two in step (same error messages for the same data).

Course frame: x = sideways (right +), y = up, z = forward along the course. A stage starts on the
previous checkpoint (or the start pad): a PAD_SIZE square pad whose top center is the stage origin.
Each piece is placed after the previous piece: `gap` studs forward from its far edge (edge to edge),
`rise` studs up from its top, `side` studs off the stage's center line. A moving platform is placed at
its rest position and moves by `move` (x, y, z) and back, eased, once per `period` seconds.

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

import math
import re
from dataclasses import dataclass
from typing import Any

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
LEVELS_DIR = "ReplicatedStorage/Levels"  # in the game: one ZoneNN.luau data module per zone
MATERIALS = ("SmoothPlastic", "Plastic", "Wood", "WoodPlanks", "Concrete", "Brick", "Metal", "DiamondPlate",
             "Grass", "Sand", "Marble", "Granite", "Slate", "Fabric", "Foil", "Neon", "Cobblestone", "Pebble")

# Every kind: what it is, whether players stand on it, its round-ness, size default/min/max (w, h, l),
# and its own parameters: name -> (default, min, max) for numbers or (default, [choices]) for strings.
KINDS: dict[str, dict[str, Any]] = {
    "platform": {"describe": "static platform; shape block or round (round: size[0] is the diameter)",
                 "size": (8, 1, 8), "min": (2, 0.5, 2), "max": (40, 4, 40),
                 "params": {"shape": ("block", ["block", "round"])}},
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
    return out


def normalize_stage(raw: Any, number: int) -> dict:
    raw = raw if isinstance(raw, dict) else {}
    pieces = raw.get("pieces") if isinstance(raw.get("pieces"), list) else []
    out: dict[str, Any] = {"stage": int(_f(raw.get("stage"), number)), "name": str(raw.get("name") or "").strip()[:60]}
    if raw.get("fallback") is True:
        out["fallback"] = True
    out["pieces"] = [normalize_piece(p) for p in pieces]
    return out


_HEX = re.compile(r"^#?([0-9a-fA-F]{6})$")


def normalize_zone(obj: Any, zone: int, first: int, count: int) -> dict:
    """The level designer's reply -> {zone, name, theme, palette, material, stages}. Stages are matched
    by their stage number (a missing one stays missing, so the validator names it)."""
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
    return {"zone": zone, "name": str(obj.get("name") or f"Zone {zone}").strip()[:60],
            "theme": str(obj.get("theme") or "").strip()[:200], "palette": palette, "material": material,
            "stages": ordered + extra}


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
            v, lo, hi = p["size"][axis], spec["min"][axis], spec["max"][axis]
            if not lo <= v <= hi:
                out.append(_problem(n, i, "param", f"{where} size {name} {v:g} out of range {_range(lo, hi)}"))
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
    surfaces = [Surface(0, "pad", 0.0, 0.0, 0.0, PAD_SIZE, PAD_SIZE)]
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
                "standable": spec.get("standable", True)}
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
    rise = pb[1] - pa[1]
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
                dx = abs(pm[0] - po[0]) - (m.w + o.w) / 2
                dz = abs(pm[2] - po[2]) - (m.l + o.l) / 2
                if dx < 0 and dz < 0 and abs(pm[1] - po[1]) < CRUSH_HEIGHT:
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
        floor = min(x.top for x in (prev, nxt) if x is not None) if (prev or nxt) else s.top
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


# ------------------------------------------------------------------------------- fallback


def fallback_stage(number: int, difficulty: int = 3) -> dict:
    """A plain platform run that always validates, used only when the level designer could not fix a
    stage in its retries. Harder stages get longer gaps, rises and a lava strip."""
    d = max(1, min(10, int(difficulty)))
    gap = 4 + d * 0.35
    pieces = [
        {"kind": "platform", "gap": gap, "rise": 0, "side": 0, "size": [8, 1, 8]},
        {"kind": "platform", "gap": gap, "rise": min(3, d * 0.3), "side": 4, "size": [7, 1, 7]},
    ]
    if d >= 5:
        pieces.append({"kind": "lava", "gap": 0, "rise": -0.5, "side": 4, "size": [7, 1, 3]})
        pieces.append({"kind": "platform", "gap": 0, "rise": 0.5, "side": 4, "size": [7, 1, 7]})
    pieces += [{"kind": "platform", "gap": gap, "rise": 0, "side": 0, "size": [6, 1, 6]},
               {"kind": "checkpoint", "gap": 5, "rise": 0, "side": 0}]
    return {"stage": number, "name": f"Stage {number}", "fallback": True,
            "pieces": [normalize_piece(p) for p in pieces]}


# ------------------------------------------------------------------------------- docs for the user message


def kinds_doc() -> str:
    """Every kind with its parameters' defaults and ranges (the level designer's user message)."""
    common = ", ".join(f"{k} {d[0]:g} {_range(d[1], d[2])}" for k, d in COMMON.items())
    lines = [f"Every piece: kind, {common} (coins only on standable pieces)."]
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
    head = {k: zone.get(k) for k in ("zone", "name", "theme", "palette", "material")}
    lines = [f"-- Zone {zone['zone']}: {str(zone.get('name') or '').replace(chr(10), ' ')} (stages {first}-{last}). "
             "Level data written by `forge levels` (Mubit level_designer), built by ObbyKit. Data, not code.",
             "return {"]
    for k, v in head.items():
        if v not in (None, "", []):
            lines.append(f"\t{k} = {_lua(v)},")
    lines.append("\tstages = {")
    for s in zone.get("stages") or []:
        meta = ", ".join(f"{k} = {_lua(s[k])}" for k in ("stage", "name", "fallback") if s.get(k) not in (None, ""))
        lines.append(f"\t\t{{ {meta}, pieces = {{")
        for p in s.get("pieces") or []:
            lines.append(f"\t\t\t{_lua(p)},")
        lines.append("\t\t} },")
    lines.append("\t},")
    lines.append("}")
    return "\n".join(lines) + "\n"
