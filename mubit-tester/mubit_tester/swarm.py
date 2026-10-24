"""Swarm testing: up to 10 AI testers with different personas play one game at the same time.

- Players. Every connected real player (solo Play = 1, `multiplayer_start` = up to 8) gets a tester;
  the personas that need a screen (UI clicker, accessibility, economy exploiter, ...) take those
  first. The rest are **bot testers**: server-driven NPC bodies spawned by ForgeTest `bot_spawn`
  and addressed like players (negative UserIds, by name). The game sees their bodies (touch,
  physics, blocking) but not a Player, and their prompt says so.
- Concurrency. Each tester runs its own observe -> decide -> act loop until the deadline. LLM calls
  go through Mubit (role `swarm_tester`, one Mubit task) in threads, bounded by a semaphore (`pool`).
- Multiplexing. `MuxHarness` batches the harness calls that arrive within a few milliseconds into
  one ForgeTest `multi` command (one `execute_luau` per batch; the server runs each call in its own
  thread). Acts are batched per action kind so a 1 s jump never waits on a 20 s walk.
- Cameras. `SwarmCamera` takes each tester's screenshots with Studio's capture camera aimed at that
  tester's character (one viewport, so captures are serialized by a lock).
- Aggregation. Reports are clustered by title/evidence similarity, optionally merged by one
  `swarm_triage` call (same root cause), then ranked by severity x frequency (distinct testers).

Report: runs/playtests/<run_id>/report.json (kind "swarm", `bugs` ranked) + shots/*.png, readable
with `report <run_id>` and usable by `suggest_fix`.
"""

from __future__ import annotations

import asyncio
import json
import math
import re
import time
from contextlib import AsyncExitStack
from pathlib import Path
from typing import Any

from forge import llm as llm_mod
from forge.config import Settings
from mubit_tester import play
from mubit_tester.harness import Harness, HarnessError, parse_reply

for _role in ("swarm_tester", "swarm_triage"):
    if _role not in llm_mod.ROLES:
        llm_mod.ROLES = tuple(llm_mod.ROLES) + (_role,)

TESTER_ROLE = "swarm_tester"
TRIAGE_ROLE = "swarm_triage"
DEFAULT_POOL = 6
DEFAULT_MAX_STEPS = 40
MUX_WINDOW = 0.04          # seconds a call waits for others to share its batch
EVENTS_EVERY = 2.0         # shared event poller
PROBE_EVERY = 15.0         # shared ForgeProbe/counters sampler (soak series)
SHOT_EVERY = 5             # a screenshot every N steps per tester (plus one per reported bug)
HISTORY = 4
EVENTS_CHARS = 1200
TEAM_CHARS = 1400
LLM_BACKOFF = 2.0
SEV_WEIGHT = {"high": 3, "medium": 2, "low": 1}
MIN_TOUCH_PX = 44          # touch targets smaller than this are hard to hit on a phone

PERSONAS: list[dict] = [
    {"key": "speedrunner", "label": "Speedrunner", "real_rank": 4, "color": [255, 196, 0],
     "brief": "Reach the game's main goal and progress milestones as fast as possible. Find the fastest "
              "route, skip anything optional, chain actions without waiting. Report what slows progress "
              "for no reason (long waits, dead time, unclear next step) and any skip or exploit that lets "
              "you progress faster than intended."},
    {"key": "griefer", "label": "Griefer", "real_rank": 8, "color": [200, 30, 30],
     "brief": "Ruin other players' fun. Body-block their pads, buttons, conveyors and doors, stand on their "
              "base or plot, crowd and follow them, push into them. Report anything that lets one player "
              "block, hurt, steal from or trap another player, or take over what belongs to someone else."},
    {"key": "newbie", "label": "Confused new player", "real_rank": 3, "color": [120, 200, 255],
     "brief": "You have never played this game and don't know what to do. Wander, read the HUD and signs, "
              "try the obvious-looking thing, try the wrong thing, stop and wait. Report anything that "
              "leaves a newcomer stuck: no hint about what to do, misleading text, a goal you can't find, "
              "feedback that never comes."},
    {"key": "ui_clicker", "label": "UI clicker", "real_rank": 0, "color": [170, 90, 255],
     "brief": "Press every on-screen button, open and close every panel, press twice fast, press buttons "
              "while another panel is open, press things that look disabled. Report buttons that don't "
              "fire, fire but change nothing, overlap or hide each other, or leave the screen in a broken "
              "state. If you have no buttons (or are a bot), read the HUD and report text problems."},
    {"key": "economy", "label": "Economy exploiter", "real_rank": 2, "color": [40, 180, 80],
     "brief": "Break the economy. Find every way to earn and spend: buy without enough money, buy the same "
              "thing twice, touch a buy pad repeatedly or with two bodies at once, look for money that grows "
              "without effort, negative or fractional prices, refunds. Report anything that gives money or "
              "items for free, takes money without delivering, or lets a value go wrong."},
    {"key": "physics", "label": "Physics breaker", "real_rank": 9, "color": [255, 120, 0],
     "brief": "Break the physics. Jump on and into moving parts, ride conveyors, stand inside machines, "
              "wedge yourself between parts, jump on other testers' heads, walk into walls and corners, "
              "fall off edges. Report getting stuck, clipping through parts, being flung, objects piling up "
              "or escaping, and moving parts that a body can jam."},
    {"key": "coop", "label": "Co-op pair", "real_rank": 5, "color": [0, 170, 170],
     "brief": "Play as a pair with your partner tester (named in the user message): stay near them, go "
              "where they go, help them, then both use the same thing at once (the same pad, button, "
              "machine or spot). Report anything that breaks when two players share a space or a feature: "
              "double triggers, one player stealing the other's reward, things that only work for one."},
    {"key": "accessibility", "label": "Accessibility / phone layout", "real_rank": 1, "color": [255, 105, 180],
     "brief": "Judge the screen as a phone player and a player with poor eyesight would. Check text size "
              "and contrast, button sizes for touch (at least 44 px), buttons overlapping or off-screen, "
              "HUD covering the action, and important information shown only by color. Use the layout "
              "facts in the user message. Report each concrete layout or readability problem."},
    {"key": "soak", "label": "Long-session soak", "real_rank": 6, "color": [130, 130, 130],
     "brief": "Play the core loop over and over for the whole session, with waits in between, like a player "
              "who leaves the game running. Watch the soak samples (counters, instance count, errors over "
              "time) and the world: parts that pile up, values that drift or overflow, things that stop "
              "working after a while. Report anything that grows without bound or degrades over time."},
    {"key": "edge", "label": "Edge-case explorer", "real_rank": 7, "color": [90, 60, 200],
     "brief": "Probe the edges: the map's borders and corners, far outside the map, the spawn point, dying "
              "and respawning, doing things in an odd order, standing still for a long time, touching "
              "things at the exact edge of their range. Report out-of-bounds problems, unsafe respawns, "
              "and anything that breaks at a boundary."},
]
PERSONA_KEYS = [p["key"] for p in PERSONAS]

_clip = play._clip
_dumps = play._dumps


# --------------------------------------------------------------------------- multiplexed harness


class MuxHarness(Harness):
    """A Harness whose calls are multiplexed: calls arriving within `window` seconds share one
    ForgeTest `multi` command (one execute_luau). Reads share a lane; acts share a lane per action
    name. Falls back to one call each if the in-game harness has no `multi` yet."""

    def __init__(self, studio: Any, *, window: float = MUX_WINDOW, **kwargs: Any) -> None:
        super().__init__(studio, **kwargs)
        self.window = window
        self.multi_ok: bool | None = None
        self._pending: dict[str, list[tuple[str, dict, asyncio.Future]]] = {}
        self.stats = {"calls": 0, "batches": 0, "round_trips": 0, "max_batch": 0}

    @staticmethod
    def lane(cmd: str, args: dict) -> str:
        return f"act:{args.get('action')}" if cmd == "act" else "read"

    async def call(self, cmd: str, **args: Any) -> Any:
        if cmd == "multi" or self.multi_ok is False:
            self.stats["round_trips"] += cmd != "multi"
            return await super().call(cmd, **args)
        self.stats["calls"] += 1
        lane = self.lane(cmd, args)
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        queue = self._pending.setdefault(lane, [])
        queue.append((cmd, args, fut))
        if len(queue) == 1:
            asyncio.get_running_loop().call_later(self.window, lambda: asyncio.ensure_future(self._flush(lane)))
        return await fut

    async def _direct(self, batch: list) -> None:
        async def one(cmd: str, args: dict, fut: asyncio.Future) -> None:
            try:
                res = await Harness.call(self, cmd, **args)
                if not fut.done():
                    fut.set_result(res)
            except BaseException as e:  # noqa: BLE001
                if not fut.done():
                    fut.set_exception(e)
        self.stats["round_trips"] += len(batch)
        await asyncio.gather(*(one(c, a, f) for c, a, f in batch))

    async def _flush(self, lane: str) -> None:
        batch = self._pending.pop(lane, [])
        if not batch:
            return
        self.stats["batches"] += 1
        self.stats["max_batch"] = max(self.stats["max_batch"], len(batch))
        if len(batch) == 1 or self.multi_ok is False:
            await self._direct(batch)
            return
        calls = [{"cmd": c, "args": a} for c, a, _ in batch]
        try:
            self.stats["round_trips"] += 1
            replies = await Harness.call(self, "multi", calls=calls, timeout=max(5, int(self.timeout) - 5))
            self.multi_ok = True
        except HarnessError as e:
            if "unknown command 'multi'" in str(e):
                self.multi_ok = False  # an older in-game harness: one call each from now on
                await self._direct(batch)
                return
            for _, _, fut in batch:
                if not fut.done():
                    fut.set_exception(HarnessError(str(e)))
            return
        except BaseException as e:  # noqa: BLE001
            for _, _, fut in batch:
                if not fut.done():
                    fut.set_exception(e)
            return
        replies = replies if isinstance(replies, list) else []
        for i, (cmd, _, fut) in enumerate(batch):
            if fut.done():
                continue
            rep = replies[i] if i < len(replies) else {"ok": False, "error": "missing reply in multi"}
            try:
                fut.set_result(parse_reply(rep, cmd))
            except HarnessError as e:
                fut.set_exception(e)


# --------------------------------------------------------------------------- cameras


def camera_for(pos: list | tuple, index: int, distance: float = 16.0, height: float = 9.0) -> tuple[list, list]:
    """A capture camera for one tester: `distance` studs away at an angle unique to the tester,
    `height` above, looking at the character's chest."""
    x, y, z = (float(v) for v in pos[:3])
    a = index * 2 * math.pi / 10 + math.pi / 4
    cam = [round(x + math.cos(a) * distance, 2), round(y + height, 2), round(z + math.sin(a) * distance, 2)]
    return cam, [round(x, 2), round(y + 1.5, 2), round(z, 2)]


class SwarmCamera:
    """Per-tester screenshots from one Studio viewport: aim the capture camera at that tester's
    character, capture, repeat for the next (serialized)."""

    def __init__(self, studio: Any, out_dir: Path) -> None:
        self.studio = studio
        self.out_dir = Path(out_dir)
        self.lock = asyncio.Lock()
        self.shots: list[dict] = []

    async def capture(self, tester: dict, pos: Any, label: str) -> str | None:
        if self.studio is None or not hasattr(self.studio, "screenshot"):
            return None
        if not (isinstance(pos, (list, tuple)) and len(pos) >= 3):
            return None
        cam, look = camera_for(pos, tester["index"])
        name = re.sub(r"[^A-Za-z0-9_-]+", "-", f"{tester['key']}-{label}")[:60] + ".png"
        async with self.lock:
            try:
                saved = await asyncio.wait_for(self.studio.screenshot(self.out_dir / name, cam, look), 45)
            except Exception:  # noqa: BLE001
                saved = None
        if not saved:
            return None
        rel = f"shots/{name}"
        self.shots.append({"tester": tester["name"], "persona": tester["key"], "label": label, "path": rel,
                           "camera": cam, "look_at": look})
        return rel


# --------------------------------------------------------------------------- roster


def pick_personas(n: int, personas: list[str] | None = None) -> list[dict]:
    """`n` personas: the named ones (in order) or all ten, cycling with #2, #3 ... past ten."""
    pool = PERSONAS
    if personas:
        by_key = {p["key"]: p for p in PERSONAS}
        unknown = [k for k in personas if k not in by_key]
        if unknown:
            raise ValueError(f"unknown persona(s) {unknown}; choose from {PERSONA_KEYS}")
        pool = [by_key[k] for k in personas]
    out = []
    for i in range(max(1, int(n))):
        base = pool[i % len(pool)]
        lap = i // len(pool)
        p = dict(base)
        if lap:
            p["key"] = f"{base['key']}{lap + 1}"
            p["label"] = f"{base['label']} #{lap + 1}"
        out.append(p)
    return out


def bot_name(persona: dict) -> str:
    return "Swarm_" + re.sub(r"[^A-Za-z0-9]", "", persona["key"].title())


def assign_testers(personas: list[dict], real_players: list[dict]) -> list[dict]:
    """Real players go to the personas that need a screen most (lowest real_rank); the rest are
    bots. Returns testers in persona order: {index, key, label, brief, color, real, name, userId}."""
    order = sorted(range(len(personas)), key=lambda i: (personas[i].get("real_rank", 99), i))
    real_for: dict[int, dict] = {}
    for i, p in zip(order, real_players):
        real_for[i] = p
    testers = []
    for i, persona in enumerate(personas):
        t = {"index": i, "key": persona["key"], "label": persona["label"], "brief": persona["brief"],
             "color": persona.get("color")}
        if i in real_for:
            rp = real_for[i]
            t.update(real=True, name=rp.get("name") or str(rp.get("userId")), userId=rp.get("userId"))
        else:
            t.update(real=False, name=bot_name(persona), userId=None)
        testers.append(t)
    keys = [t["key"] for t in testers]
    for t in testers:  # the co-op pair plays with the nearest other persona in the list
        if t["key"].startswith("coop") and len(testers) > 1:
            j = keys.index(t["key"])
            t["partner"] = testers[j - 1 if j > 0 else 1]["name"]
    return testers


# --------------------------------------------------------------------------- persona extras


def layout_facts(obs: dict) -> dict:
    """What the accessibility persona needs about the on-screen buttons: tiny touch targets,
    overlaps and buttons partly off-screen (from `ui` x/y/w/h)."""
    buttons = [b for b in (obs or {}).get("ui") or [] if isinstance(b, dict)]
    small, overlaps, offscreen = [], [], []
    rects = []
    for b in buttons:
        try:
            x, y, w, h = (float(b.get(k)) for k in ("x", "y", "w", "h"))
        except (TypeError, ValueError):
            continue
        label = b.get("text") or b.get("path")
        if min(w, h) < MIN_TOUCH_PX:
            small.append({"button": label, "w": round(w), "h": round(h)})
        if x - w / 2 < 0 or y - h / 2 < 0:
            offscreen.append(label)
        rects.append((label, x - w / 2, y - h / 2, x + w / 2, y + h / 2))
    for i in range(len(rects)):
        for j in range(i + 1, len(rects)):
            a, b = rects[i], rects[j]
            if a[1] < b[3] and b[1] < a[3] and a[2] < b[4] and b[2] < a[4]:
                overlaps.append([a[0], b[0]])
    return {"buttons": len(buttons), "small_touch_targets": small[:8], "overlapping": overlaps[:6],
            "partly_offscreen": offscreen[:6], "hud_lines": len((obs or {}).get("hud") or []),
            "min_touch_px": MIN_TOUCH_PX}


def soak_brief(samples: list[dict]) -> list[dict]:
    """The soak series, trimmed: first, middle and the last few samples."""
    if len(samples) <= 5:
        return samples
    return [samples[0], samples[len(samples) // 2], *samples[-3:]]


# --------------------------------------------------------------------------- messages


def tester_message(tester: dict, step: int, seconds_left: float, observation: dict, team: list[dict],
                   history: list[dict], events: list, game: dict, extras: dict | None = None) -> str:
    me = f"{tester['name']} ({'real player' if tester.get('real') else 'bot tester'})"
    if tester.get("partner"):
        me += f"; your co-op partner is {tester['partner']}"
    if tester.get("real") and not tester.get("can_press"):
        me += "; you can NOT press on-screen buttons this run (no Studio window drives you)"
    lines = ["## Persona", f"{tester['label']}: {tester['brief']}", "",
             "## Game", _dumps(game) if game else "unknown: find out by looking around", "",
             "## You", me, "",
             "## Step", f"{step} ({int(max(0, seconds_left))} s left in the session)", "",
             "## Observation", _dumps(observation), "",
             "## Other testers", _clip(_dumps(team), TEAM_CHARS) if team else "none", "",
             "## Recent actions (oldest first)"]
    if history:
        for h in history:
            a = h.get("action") or {}
            lines.append(f"- step {h['n']}: {a.get('action', '?')} {_dumps(a.get('args') or {})} -> "
                         f"{_clip(h.get('result', ''), 200)}")
    else:
        lines.append("- none yet")
    lines += ["", "## New game events", _clip(_dumps(events), EVENTS_CHARS) if events else "none"]
    for title, value in (extras or {}).items():
        lines += ["", f"## {title}", _clip(_dumps(value), 1500)]
    return "\n".join(lines)


# --------------------------------------------------------------------------- aggregation

_STOP = set("""the a an and or of to in on at is it its was were be been for with when after before
not no does did do doesn't didn't cant can't can cannot from by as that this then than into onto
player players tester bot bug issue game while""".split())


def _tokens(text: str) -> set[str]:
    words = re.findall(r"[a-z0-9_]+", str(text).lower())
    out = set()
    for w in words:
        if w in _STOP or len(w) < 3:
            continue
        out.add(w[:-1] if len(w) > 4 and w.endswith("s") else w)
    return out


def _paths(text: str) -> set[str]:
    return {m.lower() for m in re.findall(r"\b(?:Workspace|workspace|game)\.[\w.]+", str(text))}


def _jaccard(a: set, b: set) -> float:
    return len(a & b) / len(a | b) if a and b else 0.0


def same_bug(a: dict, b: dict) -> bool:
    """Heuristic: near-identical titles, or similar titles about the same instance path."""
    ta, tb = _tokens(a.get("title", "")), _tokens(b.get("title", ""))
    j = _jaccard(ta, tb)
    if j >= 0.5:
        return True
    shared_path = _paths(a.get("title", "") + " " + a.get("evidence", "")) & \
        _paths(b.get("title", "") + " " + b.get("evidence", ""))
    return j >= 0.25 and bool(shared_path)


def cluster_reports(reports: list[dict]) -> list[dict]:
    """Group raw reports (each {title, evidence, severity, tester, persona, real, step, shot?})."""
    groups: list[dict] = []
    for r in reports:
        hit = next((g for g in groups if any(same_bug(r, x) for x in g["reports"])), None)
        if hit is None:
            groups.append({"reports": [r]})
        else:
            hit["reports"].append(r)
    for i, g in enumerate(groups, 1):
        g["id"] = i
        _summarize_group(g)
    return groups


def _summarize_group(g: dict) -> None:
    reps = g["reports"]
    sev = max((r.get("severity", "medium") for r in reps), key=lambda s: SEV_WEIGHT.get(s, 2))
    g.setdefault("title", reps[0].get("title", ""))
    g["severity"] = g.get("severity_override") or sev
    testers = []
    for r in reps:
        if r.get("tester") not in testers:
            testers.append(r.get("tester"))
    g["testers"] = testers
    g["personas"] = sorted({r.get("persona") for r in reps if r.get("persona")})
    g["frequency"] = len(testers)
    g["reports_n"] = len(reps)
    g["only_bots"] = all(not r.get("real") for r in reps)
    g["shots"] = [r["shot"] for r in reps if r.get("shot")]


def triage_message(groups: list[dict], game: dict) -> str:
    items = [{"id": g["id"], "title": g["title"], "severity": g["severity"],
              "testers": [f"{r.get('tester')} ({r.get('persona')}, {'real' if r.get('real') else 'bot'})"
                          for r in g["reports"]][:6],
              "evidence": [_clip(r.get("evidence", ""), 220) for r in g["reports"]][:3]} for g in groups]
    return "\n".join(["## Game", _dumps(game) if game else "unknown", "",
                      "## Bug groups", json.dumps(items, ensure_ascii=False, indent=1)])


def apply_triage(groups: list[dict], verdict: dict) -> list[dict]:
    """Merge groups as the triage call says. Ids it skips stay as they are; bad output is ignored."""
    by_id = {g["id"]: g for g in groups}
    used: set[int] = set()
    out: list[dict] = []
    for item in (verdict or {}).get("groups") or []:
        if not isinstance(item, dict):
            continue
        ids = []
        for x in item.get("ids") or []:
            try:
                x = int(x)
            except (TypeError, ValueError):
                continue
            if x in by_id and x not in used and x not in ids:
                ids.append(x)
        if not ids:
            continue
        used.update(ids)
        merged = {"id": ids[0], "reports": [r for i in ids for r in by_id[i]["reports"]], "merged_ids": ids}
        merged["title"] = str(item.get("title") or by_id[ids[0]]["title"])
        sev = str(item.get("severity") or "").lower()
        if sev in SEV_WEIGHT:
            merged["severity_override"] = sev
        if item.get("real") is False:
            merged["real"] = False
        if item.get("why"):
            merged["why"] = str(item["why"])
        _summarize_group(merged)
        out.append(merged)
    out += [g for g in groups if g["id"] not in used]
    return out


def rank_bugs(groups: list[dict]) -> list[dict]:
    """Severity x frequency (distinct testers); not-real groups go last and are flagged."""
    bugs = []
    for g in groups:
        real = g.get("real", True) is not False
        score = SEV_WEIGHT.get(g["severity"], 2) * g["frequency"]
        best = max(g["reports"], key=lambda r: (SEV_WEIGHT.get(r.get("severity"), 2), len(r.get("evidence", ""))))
        bugs.append({
            "title": g["title"], "severity": g["severity"], "evidence": best.get("evidence", ""),
            "frequency": g["frequency"], "reports": g["reports_n"], "score": score if real else 0,
            "testers": g["testers"], "personas": g["personas"], "only_bots": g["only_bots"], "real": real,
            "first_step": min(r.get("step", 0) for r in g["reports"]), "shots": g["shots"][:3],
            **({"why": g["why"]} if g.get("why") else {}),
            "raw": [{k: r.get(k) for k in ("tester", "persona", "step", "title", "severity")} for r in g["reports"]],
        })
    bugs.sort(key=lambda b: (-b["score"], -SEV_WEIGHT.get(b["severity"], 2), -b["reports"], b["first_step"]))
    return bugs


# --------------------------------------------------------------------------- the swarm


class _Shared:
    """State the testers share: latest briefs, the event log and the soak series."""

    def __init__(self) -> None:
        self.events: list = []
        self.cursor: Any = None
        self.briefs: dict[str, dict] = {}
        self.soak: list[dict] = []
        self.probe_summary: dict = {}


def _brief(obs: dict) -> dict:
    me = (obs or {}).get("me") or {}
    out = {"pos": me.get("pos"), "health": me.get("health")}
    if (obs or {}).get("error"):
        out["obs_error"] = _clip(obs["error"], 80)
    return {k: v for k, v in out.items() if v is not None}


async def _events_loop(harness, shared: _Shared, stop: asyncio.Event) -> None:
    while not stop.is_set():
        try:
            res = await asyncio.wait_for(harness.events(shared.cursor), play.STUDIO_TIMEOUT)
            if isinstance(res, dict):
                shared.events.extend(res.get("events") or [])
                shared.cursor = res.get("now", shared.cursor)
        except Exception:  # noqa: BLE001
            pass
        try:
            await asyncio.wait_for(stop.wait(), EVENTS_EVERY)
        except asyncio.TimeoutError:
            pass


async def _probe_loop(harness, shared: _Shared, stop: asyncio.Event, t0: float) -> None:
    studio = getattr(harness, "studio", None)
    while not stop.is_set():
        sample: dict = {"t": round(time.monotonic() - t0, 1)}
        try:
            sample["counters"] = await asyncio.wait_for(harness.counters(), play.STUDIO_TIMEOUT)
        except Exception as e:  # noqa: BLE001
            sample["counters_error"] = _clip(str(e), 120)
        if studio is not None and hasattr(studio, "probe_report"):
            try:
                probe = await asyncio.wait_for(studio.probe_report(), play.STUDIO_TIMEOUT)
                summary = play.summarize_probe(probe or {})
                shared.probe_summary = summary
                sample["errors"] = len((probe or {}).get("errors") or [])
                if (probe or {}).get("instances") is not None:
                    sample["instances"] = probe.get("instances")
            except Exception:  # noqa: BLE001
                pass
        shared.soak.append(sample)
        try:
            await asyncio.wait_for(stop.wait(), PROBE_EVERY)
        except asyncio.TimeoutError:
            pass


def _team(tester: dict, testers: list[dict], shared: _Shared, last: dict) -> list[dict]:
    out = []
    for t in testers:
        if t is tester:
            continue
        item = {"name": t["name"], "persona": t["label"], "real": t.get("real", False),
                **shared.briefs.get(t["name"], {})}
        if last.get(t["name"]):
            item["last"] = last[t["name"]]
        out.append(item)
    return out


async def _run_tester(tester: dict, *, harness, llm, sem: asyncio.Semaphore, camera: SwarmCamera | None,
                      shared: _Shared, testers: list[dict], last: dict, deadline: float, max_steps: int,
                      game: dict, session_id: str, report: dict, shot_every: int) -> None:
    from mubit_tester import ai  # dispatch / action mapping shared with multi_playtest

    uid = tester["userId"]
    ev_seen = len(shared.events)
    tester["steps"] = 0
    for n in range(1, max_steps + 1):
        if time.monotonic() >= deadline:
            break
        t0 = time.monotonic()
        try:
            obs = await asyncio.wait_for(harness.observe(uid), play.STUDIO_TIMEOUT)
            obs = obs if isinstance(obs, dict) else {"error": f"unexpected observation: {_clip(obs, 200)}"}
        except Exception as e:  # noqa: BLE001
            obs = {"error": f"{type(e).__name__}: {_clip(str(e), 300)}"}
        if shared.probe_summary and (n == 1 or n % 4 == 0):
            obs["probe"] = shared.probe_summary
        shared.briefs[tester["name"]] = _brief(obs)
        extras: dict = {}
        if tester["key"].startswith("accessibility"):
            extras["Layout facts (from ui x/y/w/h, Studio pixels)"] = layout_facts(obs)
        if tester["key"].startswith("soak"):
            extras["Soak samples (t = seconds since start)"] = soak_brief(shared.soak)
        compact = play.compact_observation(obs)
        new_events = shared.events[ev_seen:]
        ev_seen = len(shared.events)
        history = [s for s in report["steps"] if s["tester"] == tester["name"]][-HISTORY:]
        step: dict = {"n": n, "tester": tester["name"], "persona": tester["key"], "real": tester["real"],
                      "action": {}, "result": "", "request_id": None, "latency_ms": 0,
                      "pos": (obs.get("me") or {}).get("pos")}
        user = tester_message(tester, n, deadline - time.monotonic(), compact,
                              _team(tester, testers, shared, last), history,
                              ai._compact_events(new_events)[-10:], game, extras)
        try:
            async with sem:
                action, res = await play._to_thread(llm.complete_json, TESTER_ROLE, user, session_id=session_id,
                                                    required=["action", "reason"], max_tokens=1024)
            step["request_id"], step["latency_ms"] = res.request_id, res.latency_ms
            if not isinstance(action.get("args"), dict):
                action["args"] = {}
            step["action"] = action
        except Exception as e:  # noqa: BLE001
            step["result"] = f"error: {type(e).__name__}: {_clip(str(e), 300)}"
            report["errors"].append(f"{tester['name']} step {n}: {_clip(step['result'], 200)}")
            report["steps"].append(step)
            await asyncio.sleep(LLM_BACKOFF)
            continue
        if step["action"].get("action") == "done":
            step["result"] = "done"
            report["steps"].append(step)
            tester["steps"] = n
            break
        step["result"] = await ai.dispatch(harness, uid, step["action"])
        step["ms"] = int((time.monotonic() - t0) * 1000)
        last[tester["name"]] = f"{step['action'].get('action', '?')}: {_clip(step['result'], 80)}"
        bug = play._norm_bug(step["action"].get("bug") or step["action"].get("suspected_bug"))
        shot = None
        if camera is not None and (bug or n == 1 or (shot_every and n % shot_every == 0)):
            pos = step["pos"]
            try:
                info = await asyncio.wait_for(harness.observe(uid, radius=1, max=1), play.STUDIO_TIMEOUT)
                pos = ((info or {}).get("me") or {}).get("pos") or pos
            except Exception:  # noqa: BLE001
                pass
            shot = await camera.capture(tester, pos, f"step{n}" + ("-bug" if bug else ""))
            if shot:
                step["shot"] = shot
        if bug:
            bug.update(tester=tester["name"], persona=tester["key"], real=tester["real"], step=n)
            if shot:
                bug["shot"] = shot
            report["bug_reports"].append(bug)
        report["steps"].append(step)
        tester["steps"] = n


async def _spawn_bots(harness, testers: list[dict], near: Any) -> None:
    bots = [t for t in testers if not t["real"]]
    if not bots:
        return
    args: dict = {"names": [t["name"] for t in bots], "colors": [t["color"] for t in bots]}
    if near is not None:
        args["near"] = near
    try:
        made = await harness.call("bot_spawn", **args)
    except HarnessError as e:
        if "already exists" in str(e):
            await harness.call("bot_clear")
            made = await harness.call("bot_spawn", **args)
        elif "unknown command" in str(e):
            raise HarnessError("the in-game harness has no bot_spawn: sync the latest "
                               "mubit-tester/roblox/ForgeTest.server.luau into the place") from e
        else:
            raise
    by_name = {m.get("name"): m for m in made or [] if isinstance(m, dict)}
    for t in bots:
        t["userId"] = (by_name.get(t["name"]) or {}).get("userId", t["name"])


async def run_swarm(settings: Settings, players: int = 10, minutes: float = 3.0, *, personas: list[str] | None = None,
                    pool: int = DEFAULT_POOL, max_steps: int = DEFAULT_MAX_STEPS, llm=None, studio=None,
                    harness=None, studio_name: str | None = None, screenshots: bool = True,
                    shot_every: int = SHOT_EVERY, triage: bool = True, stop_play: bool = True,
                    keep_bots: bool = False) -> dict:
    """Run `players` persona testers at once for `minutes`; returns the swarm report."""
    from mubit_tester import ai

    wall0 = time.monotonic()
    run_id = play._new_run_id()
    run_dir = play._run_dir(settings, run_id)
    run_dir.mkdir(parents=True, exist_ok=True)
    if llm is None:
        llm = llm_mod.make_llm(settings, log_path=run_dir / "calls.jsonl")
    session_id = "swarm-" + run_id
    game = ai.game_context(settings)
    goal = f"Swarm test: {players} persona testers for {minutes:g} min"
    report: dict = {
        "run_id": run_id, "kind": "swarm", "agent_role": TESTER_ROLE, "session_id": session_id, "goal": goal,
        "studio": None, "started": play._now_iso(), "ended": None, "minutes": minutes, "pool": pool,
        "goal_met": None, "summary": "", "players": [], "testers": [], "steps": [], "bug_reports": [],
        "bugs": [], "errors": [], "request_ids": [], "soak": [], "shots": [], "mux": {}, "timing": {},
    }
    play._save_report(settings, report)
    shared = _Shared()
    stop = asyncio.Event()
    camera: SwarmCamera | None = None
    started_play = False
    async with AsyncExitStack() as stack:
        try:
            if harness is None:
                if studio is None:
                    from forge.studio import Studio

                    studio = await stack.enter_async_context(Studio(settings))
                    await studio.select(studio_name)
                elif studio_name:
                    await studio.select(studio_name)
                harness = MuxHarness(studio)
            studio = getattr(harness, "studio", studio)
            report["studio"] = getattr(studio, "studio_id", None) or studio_name
            if hasattr(harness, "ensure_ready"):
                await harness.ensure_ready(timeout=60)
                started_play = bool(getattr(harness, "started_play", False))
            real = [p for p in (await harness.players() or []) if isinstance(p, dict)]
            testers = assign_testers(pick_personas(players, personas), real)
            windows = {}
            if hasattr(harness, "ui_windows"):
                try:
                    windows = await harness.ui_windows() or {}
                except Exception:  # noqa: BLE001
                    windows = {}
            for t in testers:
                t["can_press"] = bool(t["real"] and str(t["userId"]) in windows)
            near = real[0].get("userId") if real else None
            await _spawn_bots(harness, testers, near)
            report["testers"] = [{k: t.get(k) for k in ("name", "key", "label", "real", "userId", "partner", "can_press")}
                                 for t in testers]
            report["players"] = [{"userId": t["userId"], "name": t["name"], "role": t["label"]} for t in testers]
            if screenshots:
                camera = SwarmCamera(studio, run_dir)
            await asyncio.sleep(1.0)  # let bots settle on the ground
            t_start = time.monotonic()
            report["timing"]["setup_s"] = round(t_start - wall0, 1)
            deadline = t_start + max(0.1, float(minutes)) * 60.0
            sem = asyncio.Semaphore(max(1, int(pool)))
            last: dict = {}
            helpers = [asyncio.create_task(_events_loop(harness, shared, stop)),
                       asyncio.create_task(_probe_loop(harness, shared, stop, t_start))]
            try:
                results = await asyncio.gather(*(
                    _run_tester(t, harness=harness, llm=llm, sem=sem, camera=camera, shared=shared, testers=testers,
                                last=last, deadline=deadline, max_steps=max_steps, game=game, session_id=session_id,
                                report=report, shot_every=shot_every) for t in testers), return_exceptions=True)
                for t, r in zip(testers, results):
                    if isinstance(r, BaseException):
                        report["errors"].append(f"{t['name']}: {type(r).__name__}: {_clip(str(r), 300)}")
            finally:
                stop.set()
                await asyncio.gather(*helpers, return_exceptions=True)
            report["timing"]["play_s"] = round(time.monotonic() - t_start, 1)
            for t in testers:
                for rt in report["testers"]:
                    if rt["name"] == t["name"]:
                        rt["steps"] = t.get("steps", 0)
            if not keep_bots:
                try:
                    await harness.call("bot_clear")
                except Exception:  # noqa: BLE001
                    pass
        except Exception as e:  # noqa: BLE001
            report["errors"].append(f"{type(e).__name__}: {_clip(str(e), 500)}")
        finally:
            stop.set()
            if started_play and stop_play and studio is not None and hasattr(studio, "stop"):
                try:
                    await studio.stop()
                except Exception as e:  # noqa: BLE001
                    report["errors"].append(f"stop play: {_clip(str(e), 200)}")
    report["soak"] = shared.soak
    report["shots"] = camera.shots if camera else []
    report["events"] = ai._compact_events(shared.events)[-50:]
    report["mux"] = dict(getattr(harness, "stats", {}) or {})
    report["request_ids"] = [s["request_id"] for s in report["steps"] if s.get("request_id")]

    groups = cluster_reports(report["bug_reports"])
    report["clusters"] = len(groups)
    if triage and len(groups) > 1:
        try:
            verdict, res = await play._to_thread(llm.complete_json, TRIAGE_ROLE, triage_message(groups, game),
                                                 session_id=session_id, required=["groups"], max_tokens=2048)
            groups = apply_triage(groups, verdict)
            report["triage_request_id"] = res.request_id
            if res.request_id:
                report["request_ids"].append(res.request_id)
        except Exception as e:  # noqa: BLE001
            report["errors"].append(f"triage: {type(e).__name__}: {_clip(str(e), 300)}")
    report["bugs"] = rank_bugs(groups)
    real_bugs = [b for b in report["bugs"] if b["real"]]
    report["timing"]["wall_s"] = round(time.monotonic() - wall0, 1)
    steps = [s for s in report["steps"] if s.get("action")]
    lat = sorted(s["latency_ms"] for s in steps if s.get("latency_ms"))
    report["timing"].update(steps=len(steps), llm_calls=len(report["request_ids"]),
                            llm_p50_ms=lat[len(lat) // 2] if lat else None)
    report["summary"] = (f"{len(report['testers'])} testers ({sum(t['real'] for t in report['testers'])} real, "
                         f"{sum(not t['real'] for t in report['testers'])} bots), {len(steps)} actions in "
                         f"{report['timing'].get('play_s', 0)} s; {len(report['bug_reports'])} bug reports -> "
                         f"{len(real_bugs)} distinct bugs")
    report["ended"] = play._now_iso()
    play._save_report(settings, report)
    return report


# --------------------------------------------------------------------------- formatting


def format_swarm(report: dict) -> str:
    t = report.get("timing") or {}
    out = [f"## Swarm `{report.get('run_id')}`", "", report.get("summary", ""), "",
           f"**Wall clock:** {t.get('wall_s')} s (setup {t.get('setup_s')} s, play {t.get('play_s')} s); "
           f"LLM calls {t.get('llm_calls')}, p50 {t.get('llm_p50_ms')} ms, pool {report.get('pool')}",
           ]
    mux = report.get("mux") or {}
    if mux:
        out.append(f"**Harness mux:** {mux.get('calls')} calls in {mux.get('round_trips')} round trips "
                   f"(largest batch {mux.get('max_batch')})")
    out += ["", "| tester | persona | real | steps |", "|---|---|---|---|"]
    for x in report.get("testers") or []:
        out.append(f"| {x.get('name')} | {x.get('label')} | {'yes' if x.get('real') else 'bot'} | {x.get('steps', 0)} |")
    bugs = report.get("bugs") or []
    out += ["", f"### Bugs, ranked by severity x frequency ({len(bugs)})", ""]
    if bugs:
        out += ["| # | score | severity | found by | title |", "|---|---|---|---|---|"]
        for i, b in enumerate(bugs):
            flag = "" if b.get("real", True) else " (not a real bug)"
            out.append(f"| {i} | {b['score']} | {b['severity']} | {b['frequency']} ({', '.join(b['personas'])}) | "
                       f"{_clip(b['title'], 90)}{flag} |")
        out.append("")
        for i, b in enumerate(bugs[:8]):
            out.append(f"- **#{i} {b['title']}**: {_clip(b['evidence'], 300)}"
                       + (f" [shots: {', '.join(b['shots'])}]" if b.get("shots") else ""))
    else:
        out.append("No bugs reported.")
    shots = report.get("shots") or []
    if shots:
        out += ["", f"**Screenshots:** {len(shots)} in runs/playtests/{report.get('run_id')}/shots/"]
    if report.get("errors"):
        out += ["", "**Errors:** " + "; ".join(_clip(e, 160) for e in report["errors"][:6])]
    return "\n".join(out)
