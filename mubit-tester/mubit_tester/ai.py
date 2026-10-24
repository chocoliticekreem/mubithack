"""Mubit-backed AI testers that drive every player through the in-game harness.

- `multi_playtest`: one `player` agent per connected player. Each tick all players are observed,
  every agent decides concurrently (one `player` call per player, run in threads), and the actions
  are dispatched concurrently through `Harness.act`. The `judge` role rules once at the end.
- `explore`: same loop with the `explorer` role (an adversarial QA bot) for N minutes; the judge
  dedupes the suspected bugs.
- `suggest_fix`: a report's bug -> likely Luau file(s) by keyword -> `critic` analysis -> `fixer`
  patched file -> unified diff preview (nothing is written).
- `correct_step`: re-run one player's call at one step with a human note, in the same Mubit task.

System prompts are fixed files (forge/prompts/<role>.md); everything per call goes in the user
message, which stays well under ~8k tokens. Reports: runs/playtests/<run_id>/report.json (+
calls.jsonl), readable with mubit_tester.play.load_report / list_reports.
"""

from __future__ import annotations

import asyncio
import difflib
import json
import re
import time
from contextlib import AsyncExitStack
from pathlib import Path
from typing import Any

from forge import llm as llm_mod
from mubit_tester import play
from mubit_tester import surfaces as ui_surfaces
from forge.config import Settings

for _role in ("player", "judge", "explorer"):
    if _role not in llm_mod.ROLES:
        llm_mod.ROLES = tuple(llm_mod.ROLES) + (_role,)

DEFAULT_ROLES = [
    "nozzle (fight fires)",
    "rescuer (find and carry people/pets to the truck)",
    "support (refill water, open doors with axe)",
    "chaos (try weird things to find bugs)",
]
EXPLORE_GOAL = "Exploratory bug hunt: find as many distinct game bugs as possible."
EXPLORE_ROLES = [
    "boundaries (out-of-bounds, falling, getting stuck, unreachable places)",
    "interactions (prompts that do nothing, double triggers, out-of-range use)",
    "resources (Water, FireLevel, Carrying and HUD values that do not change or change wrongly)",
    "abuse (tool misuse, acting while Downed, spamming, odd orderings)",
]
SQUAD_LABELS = "ABCDEFGH"
# Squads mode guidance. It goes in the USER message: player.md / judge.md are frozen Mubit prompts.
SQUADS_GUIDE = (
    "This run plays the full multiplayer loop: lobby -> squad pad -> countdown -> mission -> results.\n"
    "- lobby: you start in the fire station. Walk onto YOUR squad's pad (a thing tagged SquadPad whose "
    "PadId is your pad; see `pad_path`) with move_to_instance and stay on it.\n"
    "- queued: you are in a squad (world.SquadId). Wait on the pad while the countdown runs; the leader "
    "(first on the pad) may use the MissionBoard prompt. Don't walk off the pad.\n"
    "- mission: world.InstanceId is your squad's own copy of the mission (other squads' instances are "
    "hidden from you). Work toward the co-op goal WITH your squad: split jobs by role, revive Downed "
    "squadmates (interact next to them), never spray a teammate (friendly fire is blamed on you), "
    "carry heavy rescues (the panda) together.\n"
    "- results / returned: the mission is over; wait (action wait) until you are back in the station, "
    "then use done.\n"
    "If the lobby isn't implemented yet the harness puts your squad straight into a mission."
)
# On-screen UI guidance, also in the USER message (player.md / explorer.md are frozen Mubit prompts).
UI_GUIDE = (
    "Your observation's `ui` lists the on-screen buttons you can see (text, path, gui, x/y) and `panels` the "
    "open windows (title). To use one, reply {\"action\": \"press\", \"args\": {\"path\": \"<path from ui>\"}} "
    "(or {\"text\": \"Claim\"}). It is a real mouse click; the result says whether the button fired and what "
    "changed on screen (panels opened or closed, new buttons, HUD text).\n"
    "Test a feature with a menu (shop, pass, inventory, upgrades, settings) through its buttons: open its "
    "panel, press its action buttons (Claim, Buy, Equip, ...), then check the result and the next observation "
    "for the effect. A button that does not fire, or fires and changes nothing, is a bug to report."
)
MACROS = ("go_touch", "go_use", "chase")
REPEAT_MACRO_TIMEOUT = 15.0
EFFECT_CHARS = 600
# Macro guidance, in the USER message (player.md / explorer.md are frozen Mubit prompts).
MACRO_GUIDE = (
    "Every step is ONE decision, so make each one finish a whole interaction. Prefer these macros:\n"
    "- go_use {\"path\": \"<prompt path>\", \"action\": \"<its action text>\"}: walk into range of the ProximityPrompt "
    "on that part (copy `path` and `action` from `prompts`, or a path from `things`) and use it, holding if needed.\n"
    "- go_touch {\"path\": \"<part path>\"}: walk to a part from `touchables` or `things` and stand on it until it "
    "registers a touch (buy pads, buttons, checkpoints, zones).\n"
    "- chase {\"path\": \"<moving part or model>\", \"touches\": 1-5}: follow a moving thing (enemy, drone, NPC, "
    "ball) and touch it that many times.\n"
    "- repeat {\"action\": \"go_use\", \"args\": {...}, \"times\": 2-5}: the same action several times in a row, to "
    "test spam and double use (double buys, spammed claims, double-tapped prompts).\n"
    "Each macro returns `effect`: what changed (leaderstats, your attributes, counters, HUD text, game events). "
    "Judge the feature by that effect; \"nothing changed\" after a buy, claim or touch is a bug to report. Keep "
    "move_to / interact / key / spray for fine positioning and fighting."
)
OBBY_ACTIONS = ("teleport_stage", "obby_try")
# Obby guidance, in the USER message, only when the observation has an `obby` block (frozen Mubit prompts).
OBBY_GUIDE = (
    "This game is an obby: your observation's `obby` shows your stage, the course length (max_stage), the next "
    "checkpoint and the hazards (KillPart) near you. Two macros cover a long course quickly:\n"
    "- teleport_stage {\"stage\": N}: stand on checkpoint N, any stage, without walking there.\n"
    "- obby_try {\"from_stage\": N, \"attempts\": 1-5}: a scripted runner starts on checkpoint N and tries to reach "
    "the next one; the result says reached, fell (where, on which hazard) or stuck (where).\n"
    "Sample the course instead of walking it from stage 1: obby_try stages spread over the whole range (stage 1, then "
    "about every tenth of max_stage, and the last one), then look closer at the stages that fail. A stage the runner "
    "never reaches in several attempts, or a fall with no hazard nearby, is a bug to report with its stage number."
)
UI_PASS_BUTTONS = 50  # buttons read after a scripted press: an opened panel can show many
HISTORY = 4
HISTORY_RESULT_CHARS = 400  # room for a macro's effect
PROBE_EVERY = 5
EVENTS_MAX = 12
TEAM_CHARS = 1200
EVENTS_CHARS = 1500
TRACE_CHARS = 12_000
SQUAD_CHARS = 1500
QUEUE_AFTER = 6     # squads mode assist: ticks a player may idle in the lobby before the harness queues them
LAUNCH_AFTER = 4    # ticks a full squad may wait on its pad before the harness launches it
ACT_TIMEOUT = 60.0
MAX_EXPLORE_TICKS = 200


# --------------------------------------------------------------------------- small helpers

_clip = play._clip
_dumps = play._dumps


def game_context(settings: Settings, game_dir: Path | str | None = None) -> dict:
    """A saved game's own design belongs in user context, never in the fixed task prompts."""
    path = Path(game_dir or settings.base_game_dir).parent / 'spec.json'
    if not path.is_file():
        return {}
    try:
        spec = json.loads(path.read_text())
        return {key: spec.get(key) for key in ('title', 'pitch', 'core_loop', 'acceptance')}
    except (OSError, ValueError, AttributeError):
        return {}


def _pid(p: dict) -> Any:
    return p.get("userId", p.get("user_id", p.get("name")))


def _matches(p: dict, who: Any) -> bool:
    w = str(who).strip().lower()
    return any(str(p.get(k, "")).strip().lower() == w for k in ("userId", "user_id", "name", "helmet")
               if p.get(k) is not None)


def _select_players(all_players: list[dict], players: Any) -> list[dict]:
    if players is None:
        return list(all_players)
    if isinstance(players, int) and not isinstance(players, bool):
        return list(all_players[: max(0, players)])
    if isinstance(players, (str, bytes)):
        players = [players]
    out = []
    for who in players:
        hit = next((p for p in all_players if _matches(p, who)), None)
        if hit is None:
            raise ValueError(f"no connected player matches {who!r}")
        if hit not in out:
            out.append(hit)
    return out


def assign_roles(players: list[dict], roles: list[str] | None = None) -> list[dict]:
    """[{userId, name, helmet, role}] cycling through `roles` (DEFAULT_ROLES if empty)."""
    pool = [r for r in (roles or []) if str(r).strip()] or DEFAULT_ROLES
    return [
        {"userId": _pid(p), "name": p.get("name") or str(_pid(p)), "helmet": p.get("helmet"),
         "role": str(pool[i % len(pool)])}
        for i, p in enumerate(players)
    ]


def _num(v: Any, default: float) -> float:
    return play._num(v, default)


def _xyz(args: dict) -> list | None:
    x, y, z = (args.get(k) for k in ("x", "y", "z"))
    if None not in (x, y, z):
        return [float(x), float(y), float(z)]
    pos = args.get("pos")
    if isinstance(pos, (list, tuple)) and len(pos) == 3:
        return [float(v) for v in pos]
    return None


def map_action(action: dict) -> tuple[str, dict] | str:
    """player.md / explorer.md action -> (harness action, args), or a result string if not dispatched."""
    name = str(action.get("action") or "")
    args = action.get("args") if isinstance(action.get("args"), dict) else {}
    if name in ("move_to", "walk_to"):
        pos = _xyz(args)
        if pos is not None:
            return "walk_to", {"pos": pos}
        if name == "walk_to" and args.get("path"):
            return "walk_to", {"path": str(args["path"])}
        return f"error: {name} needs x, y, z"
    if name == "move_to_instance":
        path = args.get("path") or args.get("instance_path")
        return ("walk_to", {"path": str(path)}) if path else "error: move_to_instance needs path"
    if name == "interact":
        return "interact", ({"path": str(args["path"])} if args.get("path") else {})
    if name == "key":
        key = str(args.get("key") or "").strip().lower()
        if key in ("space", " "):
            return "jump", {}
        return f"unsupported: key {args.get('key')!r} (the harness has no raw key presses)"
    if name in ("spray", "use"):
        if name == "spray":
            secs = _num(args.get("ms"), 1500) / 1000.0
        else:
            secs = _num(args.get("seconds"), 1.5)
        out: dict = {"seconds": max(0.2, min(secs, 8.0))}
        aim = args.get("aim") or args.get("target") or args.get("path")
        if aim is not None:
            out["aim"] = aim
        return "use", out
    if name == "equip":
        if args.get("name"):
            return "equip", {"name": str(args["name"])}
        slot = int(_num(args.get("slot"), 1))
        if not 1 <= slot <= 9:
            return f"error: slot {slot} out of range 1-9"
        return "equip", {"slot": slot}
    if name == "unequip":
        return "unequip", {}
    if name == "look_at":
        pos = _xyz(args)
        if pos is not None:
            return "look_at", {"pos": pos}
        return ("look_at", {"path": str(args["path"])}) if args.get("path") else "error: look_at needs pos or path"
    if name == "jump":
        return "jump", {}
    if name == "say":
        return "say", {"text": _clip(str(args.get("text") or ""), 120)}
    if name in ("press", "click"):
        out = {k: str(args[k]) for k in ("path", "text") if args.get(k)}
        return ("press", out) if out else f"error: {name} needs path or text (from the observation's `ui`)"
    if name in MACROS:
        path = args.get("path") or args.get("instance_path") or args.get("target")
        if not path:
            return f"error: {name} needs path (copy it from touchables, things or prompts)"
        out = {"path": str(path)}
        if args.get("timeout") is not None:
            out["timeout"] = max(2.0, min(_num(args.get("timeout"), 20), 60.0))
        if name == "chase":
            out["touches"] = int(max(1, min(_num(args.get("touches"), 3), 5)))
        if name == "go_use" and args.get("action"):
            out["action"] = str(args["action"])  # which prompt on the part: its `action` text from `prompts`
        return name, out
    if name == "repeat":
        return _map_repeat(args)
    if name in OBBY_ACTIONS:
        return _map_obby(name, args)
    if name == "wait":
        return "wait", {"seconds": max(0.0, min(_num(args.get("seconds"), 2.0), 10.0))}
    if name == "done":
        return "done"
    return f"error: unknown action {name!r}"


def _map_repeat(args: dict) -> tuple[str, dict] | str:
    inner = args.get("action")
    if not inner:
        return "error: repeat needs args.action (the action to repeat), args.args and times (2-5)"
    mapped = map_action({"action": inner, "args": args.get("args") if isinstance(args.get("args"), dict) else {}})
    if isinstance(mapped, str):
        return f"error: repeat of {inner!r}: {mapped}"
    name, inner_args = mapped
    if name in ("wait", "repeat"):
        return f"error: repeat can't repeat {name}"
    if name in OBBY_ACTIONS:
        return f"error: repeat can't repeat {name} (obby_try takes attempts)"
    if name in MACROS:  # N walks have to fit in one Studio call
        inner_args["timeout"] = min(inner_args.get("timeout", REPEAT_MACRO_TIMEOUT), REPEAT_MACRO_TIMEOUT)
    times = int(max(1, min(_num(args.get("times"), 2), 5)))
    return "repeat", {"action": name, "args": inner_args, "times": times}


def _map_obby(name: str, args: dict) -> tuple[str, dict] | str:
    """teleport_stage {stage} / obby_try {from_stage?, to_stage?, attempts?, timeout?} (ForgeTest commands)."""
    out: dict = {}
    keys = ("stage",) if name == "teleport_stage" else ("from_stage", "to_stage")
    for k in keys:
        if args.get(k) is not None:
            try:
                out[k] = int(float(args[k]))
            except (TypeError, ValueError):
                return f"error: {name} {k} must be a stage number, got {args[k]!r}"
    if name == "teleport_stage":
        return (name, out) if "stage" in out else "error: teleport_stage needs stage (a checkpoint's Stage number)"
    out["attempts"] = int(max(1, min(_num(args.get("attempts"), 1), 5)))
    if args.get("timeout") is not None:
        out["timeout"] = max(3.0, min(_num(args.get("timeout"), 20), 60.0))
    return name, out


async def dispatch(harness, user_id: Any, action: dict) -> str:
    from mubit_tester.harness import act_budget

    mapped = map_action(action)
    if isinstance(mapped, str):
        return mapped
    name, args = mapped
    if name == "wait":
        await asyncio.sleep(args["seconds"])
        return f"waited {args['seconds']:.1f}s"
    timeout = max(ACT_TIMEOUT + float(args.get("seconds", 0) or 0), act_budget(name, args) + 10)
    try:
        res = await asyncio.wait_for(harness.act(user_id, name, **args), timeout)
    except Exception as e:  # noqa: BLE001
        return f"error: {name}: {type(e).__name__}: {_clip(str(e), 200)}"
    if isinstance(res, dict):
        detail = res.get("detail")
        ok = res.get("done")
        text = f"{name} {_dumps(args)} -> done={ok} {_clip(detail if detail is not None else '', play.RESULT_CHARS)}".rstrip()
        if "effect" in res:  # macros: what the one decision changed, so the tester (and judge) can tell
            text += " | effect: " + (_clip(_dumps(res["effect"]), EFFECT_CHARS) if res["effect"] else "nothing changed")
        return text
    return f"{name} {_dumps(args)} -> {_clip(res, play.RESULT_CHARS)}"


def _me_brief(obs: dict) -> dict:
    me = (obs or {}).get("me") or {}
    attrs = me.get("attrs") or {}
    out = {"pos": me.get("pos"), "health": me.get("health"), "tool": me.get("tool")}
    for k in ("Water", "Carrying", "Downed"):
        if k in attrs:
            out[k] = attrs[k]
    if (obs or {}).get("error"):
        out["obs_error"] = _clip(obs["error"], 80)
    return {k: v for k, v in out.items() if v is not None}


def team_summary(me: dict, roster: list[dict], observations: dict, last_actions: dict) -> list[dict]:
    """Compact view of the other players: name, role, pos, Water, Carrying, last action."""
    out = []
    for p in roster:
        if p["userId"] == me["userId"]:
            continue
        item = {"name": p["name"], "role": p["role"], **_me_brief(observations.get(p["userId"]) or {})}
        if p.get("squad"):
            item["squad"] = p["squad"]
            if me.get("squad"):
                item["squadmate"] = p["squad"] == me["squad"]
        la = last_actions.get(p["userId"])
        if la:
            item["last"] = la
        out.append(item)
    return out


def _compact_events(events: list) -> list:
    out = []
    for e in (events or [])[-EVENTS_MAX:]:
        if isinstance(e, dict):
            out.append({"t": e.get("t"), "kind": e.get("kind"), "data": e.get("data")})
        else:
            out.append(e)
    return out


def agent_user_message(goal: str, me: dict, n: int, total: int | None, team: list[dict],
                       observation: dict, history: list[dict], events: list,
                       squad: dict | None = None, pressers: list[str] | None = None,
                       ui_tasks: list[dict] | None = None) -> str:
    team_text = _clip(_dumps(team), TEAM_CHARS) if team else "none (you are the only test player)"
    who = f"{me['name']} (helmet {me.get('helmet')}); role: {me['role']}"
    if me.get("squad"):
        who += f"; squad {me['squad']} (pad {me.get('pad')})"
    lines = [
        "## Goal", goal.strip(), "",
        "## You", who, "",
    ]
    if "ui" in (observation or {}):
        guide = UI_GUIDE
        if not me.get("can_press"):
            guide += ("\nYou can NOT press UI in this run: presses are real clicks and no Studio window drives "
                      f"your player. Players who can: {', '.join(pressers or []) or 'none'}. Read `ui` and leave "
                      "presses to them (say what you see if it helps).")
        lines += ["## On-screen UI", guide, ""]
    if ui_tasks:
        lines += ["## UI features assigned to you", ui_surfaces.tasks_text(ui_tasks), ""]
    if (observation or {}).get("obby"):
        lines += ["## Obby", OBBY_GUIDE, ""]
    lines += [
        "## Macro actions", MACRO_GUIDE, "",
        "## Step", (f"{n} of {total}" if total else str(n)) + " (decisions)", "",
        "## Team", team_text, "",
        "## Observation", _dumps(observation), "",
        "## Recent actions (oldest first)",
    ]
    if history:
        for h in history:
            a = h.get("action") or {}
            lines.append(f"- step {h['n']}: {a.get('action', '?')} {_dumps(a.get('args') or {})} -> "
                         f"{_clip(h.get('result', ''), HISTORY_RESULT_CHARS)}")
    else:
        lines.append("- none yet")
    lines += ["", "## New game events", _clip(_dumps(events), EVENTS_CHARS) if events else "none"]
    if squad:
        lines += ["", "## Squads mode", SQUADS_GUIDE, "", "## Your squad now", _clip(_dumps(squad), SQUAD_CHARS)]
    return "\n".join(lines)


def _history(steps: list[dict], user_id: Any, n: int) -> list[dict]:
    return [s for s in steps if s.get("player") == user_id and s.get("n", 0) < n][-HISTORY:]


def _bug_from(action: dict, key: str) -> dict | None:
    return play._norm_bug(action.get(key))


def judge_message(goal: str, roster: list[dict], steps: list[dict], events: list, probe: dict,
                  counters: Any, hints: list[dict], errors: list[str], squads: dict | None = None,
                  ui_coverage: dict | None = None) -> str:
    names = {p["userId"]: p["name"] for p in roster}
    trace = []
    for s in steps:
        a = s.get("action") or {}
        trace.append(
            f"{s['n']}.{names.get(s.get('player'), s.get('player'))}: {a.get('action', '?')} "
            f"{_dumps(a.get('args') or {})} | {_clip(a.get('reason', ''), 90)} | "
            f"-> {_clip(s.get('result', ''), 140)} | obs: {_clip(play._obs_brief(s.get('observation') or {}), 160)}"
        )
    text = "\n".join(trace)
    if len(text) > TRACE_CHARS:
        text = text[: TRACE_CHARS // 3] + "\n...[middle steps omitted]...\n" + text[-(TRACE_CHARS * 2 // 3):]
    extra: list[str] = []
    if squads:
        extra = [
            "", "## Squads mode",
            "This was a multiplayer squads run (lobby -> pad -> countdown -> mission -> results). Judge the "
            "co-op goal for the whole team, and treat lobby/launch/instance problems (a squad that never "
            "launched, players in the wrong instance, another squad's things visible) as game bugs.",
            "", "## Phases per player (tick: phase)", _clip(_dumps(squads.get("phases") or {}), 2000),
            "", "## Mission instances seen", _clip(_dumps(squads.get("instances") or []), 1500),
            "", "## Harness assists (the harness queued/launched for stuck players)",
            _clip(_dumps(squads.get("assists") or []), 1000) if squads.get("assists") else "none",
            "", "## Per-player stats (from game events and BlameService)", _clip(_dumps(squads.get("stats") or {}), 3000),
            "", "## Per-player blame",
            "In addition to goal_met, summary and bugs, add the key \"players\": one entry per player, "
            "{\"name\": \"...\", \"blame\": \"what went wrong because of them (friendly fire, downs caused, "
            "kinked hoses, left the squad), or empty\", \"credit\": \"what they did for the team\"}. "
            "Base it on the stats and the trace, not on the players' own claims.",
        ]
    if ui_coverage and ui_coverage.get("total"):
        scripted = {s["name"]: s["scripted"] for s in ui_coverage.get("surfaces") or [] if s.get("scripted")}
        extra += ["", "## UI coverage (features with on-screen buttons; a gap means the round did not prove it)",
                  _clip(_dumps({"pressed": f"{ui_coverage['pressed']}/{ui_coverage['total']}",
                                "gaps": ui_coverage.get("gaps") or [],
                                **({"scripted_pass": scripted} if scripted else {})}), 2000)]
    return "\n".join([
        "## Goal", goal.strip(), "",
        "## Players", _dumps([{"name": p["name"], "role": p["role"], **({"squad": p["squad"]} if p.get("squad") else {})}
                              for p in roster]), "",
        "## Trace (step.player: action args | reason | -> result | obs)", text or "(no steps ran)", "",
        "## Game events (most recent)", _clip(_dumps(_compact_events(events)[-20:]), 3000) if events else "none", "",
        "## ForgeProbe (server)", _dumps(play.summarize_probe(probe or {})), "",
        "## Counters", _clip(_dumps(counters or {}), 800), "",
        "## Tool errors", _clip(_dumps(errors[-8:]), 1000) if errors else "none", "",
        "## Bugs flagged by the playtesters", _clip(_dumps(hints), 4000) if hints else "none",
        *extra,
    ])


# --------------------------------------------------------------------------- harness setup


def _is_harness(obj) -> bool:
    return obj is not None and all(hasattr(obj, a) for a in ("observe", "act", "players"))


async def _probe(harness) -> dict:
    studio = getattr(harness, "studio", None)
    if studio is not None and hasattr(studio, "probe_report"):
        try:
            return await asyncio.wait_for(studio.probe_report(), play.STUDIO_TIMEOUT)
        except Exception as e:  # noqa: BLE001
            return {"error": f"{type(e).__name__}: {e}"}
    return {}


async def _counters(harness) -> Any:
    try:
        return await asyncio.wait_for(harness.counters(), play.STUDIO_TIMEOUT)
    except Exception as e:  # noqa: BLE001
        return {"error": f"{type(e).__name__}: {_clip(str(e), 200)}"}


async def _events(harness, since) -> tuple[list, Any]:
    try:
        res = await asyncio.wait_for(harness.events(since), play.STUDIO_TIMEOUT)
    except Exception:  # noqa: BLE001
        return [], since
    if isinstance(res, dict):
        return list(res.get("events") or []), res.get("now", since)
    if isinstance(res, list):
        return res, since
    return [], since


async def _observe(harness, user_id) -> dict:
    try:
        obs = await asyncio.wait_for(harness.observe(user_id), play.STUDIO_TIMEOUT)
        if not isinstance(obs, dict):
            obs = {"error": f"unexpected observation: {_clip(obs, 200)}"}
    except Exception as e:  # noqa: BLE001
        obs = {"error": f"{type(e).__name__}: {_clip(str(e), 300)}"}
    return obs


# --------------------------------------------------------------------------- squads mode


def assign_squads(roster: list[dict], squads: int = 1) -> list[dict]:
    """Split the roster into `squads` contiguous squads A, B, ... on pads 1, 2, ... (in place)."""
    n = len(roster)
    k = max(1, min(int(squads or 1), n or 1, len(SQUAD_LABELS)))
    for i, p in enumerate(roster):
        s = i * k // max(1, n)
        p["squad"], p["pad"] = SQUAD_LABELS[s], s + 1
    return roster


async def _safe(coro_fn, *args, **kwargs) -> Any:
    """Call a harness helper; errors (incl. a harness that lacks it) come back as {"error": ...}."""
    try:
        return await asyncio.wait_for(coro_fn(*args, **kwargs), play.STUDIO_TIMEOUT)
    except Exception as e:  # noqa: BLE001
        return {"error": f"{type(e).__name__}: {_clip(str(e), 300)}"}


def _err(res: Any) -> str | None:
    return res.get("error") if isinstance(res, dict) and res.get("error") else None


def player_phase(obs: dict, prev: str | None, instances: dict) -> str:
    """lobby | queued | mission | results | returned, from the raw observation."""
    me = (obs or {}).get("me") or {}
    attrs = me.get("attrs") or {}
    world = (obs or {}).get("world") or {}
    iid = attrs.get("InstanceId") or world.get("InstanceId")
    if iid:
        st = (instances.get(iid) or {}).get("state") or (world.get("instance") or {}).get("state")
        return "results" if st == "Results" else "mission"
    if prev in ("mission", "results", "returned"):
        return "returned"
    return "queued" if (attrs.get("SquadId") or world.get("SquadId")) else "lobby"


def squad_context(p: dict, phase: str, lobby: dict, instances: dict, obs: dict) -> dict:
    """What one agent is told about its squad / instance this tick."""
    me = (obs or {}).get("me") or {}
    attrs = me.get("attrs") or {}
    ctx: dict = {"phase": phase, "squad": p.get("squad"), "pad": p.get("pad")}
    pad = next((x for x in (lobby.get("pads") or []) if str(x.get("padId")) == str(p.get("pad"))), None)
    if pad:
        ctx["pad_path"] = pad.get("path")
    sid = attrs.get("SquadId")
    sq = next((s for s in (lobby.get("squads") or []) if sid and str(s.get("id")) == str(sid)), None)
    if sq:
        ctx["lobby_squad"] = {k: sq.get(k) for k in ("id", "padId", "missionId", "state", "countdown") if sq.get(k) is not None}
        ctx["lobby_squad"]["members"] = [m.get("name") for m in sq.get("members") or [] if isinstance(m, dict)]
    iid = attrs.get("InstanceId")
    if iid and instances.get(iid):
        run = instances[iid]
        ctx["instance"] = {k: run.get(k) for k in ("instanceId", "missionId", "state", "secondsLeft", "fires", "rescues")
                           if run.get(k) is not None}
        ctx["instance"]["players"] = [m.get("name") for m in run.get("players") or [] if isinstance(m, dict)]
    if lobby.get("error"):
        ctx["lobby_error"] = _clip(lobby["error"], 160)
    return ctx


def blame_from_events(events: list, roster: list[dict]) -> dict:
    """Per-player friendly-fire / downs / heat / rescue tallies from the harness event log."""
    by_id = {str(p["userId"]): p["name"] for p in roster}
    stats = {p["name"]: {"teammates_hosed": 0, "hosed_by_teammates": 0, "downed": 0, "downs_caused": 0,
                         "overheated": 0, "ragdolled": 0, "kinked_others": 0, "delivered": 0} for p in roster}

    def name_of(d: Any) -> str | None:
        if isinstance(d, dict):
            if d.get("name") in stats:
                return d["name"]
            return by_id.get(str(d.get("userId")))
        return None

    seen: set = set()
    for e in events or []:
        if not isinstance(e, dict):
            continue
        kind, d = e.get("kind"), e.get("data") or {}
        if not isinstance(d, dict):
            continue
        actor, other = name_of(d), name_of(d.get("other"))
        args = d.get("args") if isinstance(d.get("args"), list) else []
        key = (kind, actor, round(float(e.get("t") or 0)))  # attr + signal duplicates within a second
        if kind in ("downed", "overheated", "ragdolled", "delivered") and key in seen:
            continue
        seen.add(key)
        if kind == "hose_hit" and actor:
            stats[actor]["teammates_hosed"] += 1
            if other:
                stats[other]["hosed_by_teammates"] += 1
        elif kind == "downed" and actor:
            stats[actor]["downed"] += 1
            culprit = name_of(args[2]) if len(args) > 2 else None
            if culprit and culprit != actor:
                stats[culprit]["downs_caused"] += 1
        elif kind == "overheated" and actor:
            stats[actor]["overheated"] += 1
        elif kind == "ragdolled" and actor:
            stats[actor]["ragdolled"] += 1
        elif kind == "kinked" and other and other != actor:
            stats[other]["kinked_others"] += 1
        elif kind == "delivered":
            who = actor or by_id.get(str(d.get("by")))
            if who:
                stats[who]["delivered"] += 1
    return stats


def ui_presses(events: list) -> list[dict]:
    """Real GUI clicks from the harness event log (kind ui_press): who pressed what, and did it work."""
    out = []
    for e in events or []:
        d = e.get("data") if isinstance(e, dict) and e.get("kind") == "ui_press" else None
        if isinstance(d, dict):
            out.append({"t": e.get("t"), "player": d.get("name") or d.get("userId"), "text": d.get("text") or "",
                        "path": d.get("path") or "", "gui": d.get("gui") or "", "fired": d.get("fired") is True,
                        "changed": d.get("changed") is True,
                        "effect": {k: v for k, v in (d.get("effect") or {}).items() if v}})
    return out


async def _ui_view(harness, user_id) -> dict:
    """The player's screen now: {buttons, not_rendering?} (the harness's `ui`, else an observation's `ui`)."""
    if hasattr(harness, "ui"):
        got = await _safe(harness.ui, user_id, max=UI_PASS_BUTTONS)
        if isinstance(got, dict) and not _err(got):
            return {"buttons": [b for b in got.get("buttons") or [] if isinstance(b, dict)],
                    "not_rendering": got.get("not_rendering")}
    obs = await _observe(harness, user_id)
    return {"buttons": [b for b in obs.get("ui") or [] if isinstance(b, dict)], "not_rendering": None}


async def _ui_buttons(harness, user_id) -> list[dict]:
    return (await _ui_view(harness, user_id))["buttons"]


async def _ui_press(harness, user_id, kind: str, label: str, button: dict | None) -> dict:
    args = {"path": button["path"]} if button and button.get("path") else {"text": label}
    try:
        res = await asyncio.wait_for(harness.act(user_id, "press", **args), ACT_TIMEOUT)
    except Exception as e:  # noqa: BLE001 - recorded, the pass goes on
        res = {"done": False, "detail": f"error: {type(e).__name__}: {_clip(str(e), 200)}"}
    res = res if isinstance(res, dict) else {"done": False, "detail": _clip(res, 200)}
    return {"kind": kind, "button": label, "path": res.get("path") or args.get("path"),
            "fired": bool(res.get("fired", res.get("done"))), "changed": bool(res.get("changed")),
            "effect": {k: v for k, v in (res.get("effect") or {}).items() if v},
            "detail": _clip(res.get("detail") or "", 300)}


async def ui_pass(harness, surfaces: list[dict], roster: list[dict]) -> list[dict]:
    """Before free play, no LLM: every assigned UI surface is pressed once with a real click (its presser's
    Studio window), then each of its actions that is on screen once it is open (a Claim only shows on a
    claimable tier: "where enabled"), purchase-like actions last, then whatever it opened is closed again.
    Every press is a real Harness.press, so it also lands in the event log (ui_presses) like a tester's.
    -> [{surface, gui, player, presses: [{kind: entry|action|close, button, path, fired, changed, effect,
    detail}], skipped: [actions not on screen]}]; each surface gets `scripted` (ui_surfaces.pass_note)."""
    ids = {p["name"]: p["userId"] for p in roster if p.get("can_press")}
    out = []
    for s in surfaces or []:
        uid = ids.get(s.get("assigned"))
        if uid is None:
            continue
        rec: dict = {"surface": s["name"], "gui": s.get("gui", ""), "player": s["assigned"], "presses": [],
                     "skipped": []}
        view = await _ui_view(harness, uid)
        if view["not_rendering"]:  # a minimized Studio window: say so instead of "no visible button"
            rec["blocked"] = str(view["not_rendering"])
            s["scripted"] = ui_surfaces.pass_note(rec)
            out.append(rec)
            continue
        entry_btn = ui_surfaces.pick_button(view["buttons"], s["name"], s.get("path"))
        entry = await _ui_press(harness, uid, "entry", s["name"], entry_btn)
        rec["presses"].append(entry)
        if entry["fired"]:
            now = await _ui_buttons(harness, uid)
            for action in ui_surfaces.order_actions(s.get("actions") or ui_surfaces.new_buttons(entry["effect"])):
                btn = ui_surfaces.pick_button(now, action)
                if btn is None:
                    rec["skipped"].append(action)
                    continue
                rec["presses"].append(await _ui_press(harness, uid, "action", action, btn))
                now = await _ui_buttons(harness, uid)  # a press can re-render the panel
            if ui_surfaces.opened(entry["effect"]):
                close = ui_surfaces.close_button(now, s.get("gui")) or ui_surfaces.pick_button(
                    now, s["name"], (entry_btn or {}).get("path"))
                if close is not None:
                    rec["presses"].append(await _ui_press(harness, uid, "close",
                                                          str(close.get("text") or close.get("path")), close))
        s["scripted"] = ui_surfaces.pass_note(rec)
        out.append(rec)
    return out


async def _squads_tick(harness, n: int, roster: list[dict], tick_players: list[dict], observations: dict,
                       phases: dict, lobby_ticks: dict, queued_ticks: dict, started_direct: set,
                       lobby_unsupported: bool, seen_mission: bool, report: dict, contexts: dict,
                       assist: bool) -> tuple[bool, bool]:
    """Read lobby + instances, update every player's phase, nudge stuck squads, build contexts."""
    lobby = await _safe(harness.squads) if hasattr(harness, "squads") else {"error": "harness has no squads"}
    lobby = lobby if isinstance(lobby, dict) else {}
    if not lobby_unsupported and (lobby.get("service") in ("stub", "missing") or not lobby.get("pads")):
        lobby_unsupported = True
        report["assists"].append({"n": n, "who": "harness", "action": "lobby unavailable",
                                  "result": _clip(lobby.get("error") or f"LobbyService {lobby.get('service')}, "
                                                  f"{len(lobby.get('pads') or [])} pads", 200)})
    inst_list = await _safe(harness.instances) if hasattr(harness, "instances") else []
    inst_list = inst_list if isinstance(inst_list, list) else []
    instances = {str(i.get("instanceId")): i for i in inst_list if isinstance(i, dict) and i.get("instanceId")}
    for iid, run in instances.items():
        if iid not in {x.get("instanceId") for x in report["instances"]}:
            report["instances"].append({k: run.get(k) for k in ("instanceId", "missionId", "squadId")}
                                       | {"first_seen": n,
                                          "players": [m.get("name") for m in run.get("players") or [] if isinstance(m, dict)]})
    for p in tick_players:
        uid = p["userId"]
        ph = player_phase(observations.get(uid) or {}, phases.get(uid), instances)
        if ph != phases.get(uid):
            report["phases"].setdefault(p["name"], []).append(f"{n}:{ph}")
        phases[uid] = ph
        if ph in ("mission", "results"):
            seen_mission = True

    def note(action: str, who: str, res: Any) -> None:
        report["assists"].append({"n": n, "who": who, "action": action, "result": _clip(res, 200)})

    if assist:
        by_squad: dict[str, list[dict]] = {}
        for p in roster:
            by_squad.setdefault(p["squad"], []).append(p)
        for label, members in by_squad.items():
            uids = [m["userId"] for m in members]
            pad = members[0]["pad"]
            if lobby_unsupported and label not in started_direct and all(phases.get(u) == "lobby" for u in uids):
                # no lobby yet: put the squad straight into a mission (MissionService:StartMission)
                res = await _safe(harness.mission_start, players=uids) if hasattr(harness, "mission_start") \
                    else {"error": "harness has no mission_start"}
                started_direct.add(label)
                note("mission_start (lobby not implemented)", f"squad {label}", res)
                continue
            for m in members:
                u = m["userId"]
                lobby_ticks[u] = lobby_ticks.get(u, 0) + 1 if phases.get(u) == "lobby" else 0
                if not lobby_unsupported and lobby_ticks[u] >= QUEUE_AFTER and hasattr(harness, "queue"):
                    res = await _safe(harness.queue, u, pad=m["pad"])
                    note(f"queue pad {m['pad']}", m["name"], res)
                    lobby_ticks[u] = 0
                    if "unsupported" in str(_err(res) or ""):
                        lobby_unsupported = True
            queued_ticks[label] = queued_ticks.get(label, 0) + 1 if all(phases.get(u) == "queued" for u in uids) else 0
            if queued_ticks[label] >= LAUNCH_AFTER and hasattr(harness, "launch"):
                res = await _safe(harness.launch, pad=pad)
                note(f"launch pad {pad}", f"squad {label}", res)
                queued_ticks[label] = 0
    for p in tick_players:
        contexts[p["userId"]] = squad_context(p, phases[p["userId"]], lobby, instances,
                                              observations.get(p["userId"]) or {})
    return lobby_unsupported, seen_mission


# --------------------------------------------------------------------------- the session loop


async def _session(settings: Settings, *, kind: str, agent_role: str, goal: str, players, roles,
                   max_ticks: int, deadline: float | None, llm, studio, harness, studio_name,
                   step_seconds: float, bug_key: str, mode: str = "free", squads: int = 1,
                   assist: bool = True, game_dir: Path | str | None = None) -> dict:
    context = game_context(settings)
    surface_spec = game_context(settings, game_dir) if game_dir else context
    if context:
        goal += '\n\nSaved game design:\n' + json.dumps(context, ensure_ascii=False)[:4000]
        goal += '\nTest this game and the features you observe. Firefighter mechanics may not exist in this game.'
    squads_mode = mode == "squads"
    run_id = play._new_run_id()
    run_dir = play._run_dir(settings, run_id)
    run_dir.mkdir(parents=True, exist_ok=True)
    if llm is None:
        llm = llm_mod.make_llm(settings, log_path=run_dir / "calls.jsonl")
    session_id = "playtest-" + run_id
    report: dict = {
        "run_id": run_id, "kind": kind, "agent_role": agent_role, "session_id": session_id,
        "goal": goal, "studio": None, "started": play._now_iso(), "ended": None,
        "max_steps": max_ticks, "goal_met": None, "summary": "", "bugs": [], "steps": [],
        "players": [], "probe": {}, "counters": {}, "events": [], "request_ids": [], "bug_hints": [],
        "corrections": [], "errors": [], "mode": mode,
    }
    if squads_mode:
        report.update({"squads": max(1, int(squads or 1)), "assists": [], "phases": {}, "instances": [],
                       "per_player": []})
    play._save_report(settings, report)

    all_events: list = []
    phases: dict = {}          # userId -> current phase
    lobby_ticks: dict = {}     # userId -> ticks idle in the lobby
    queued_ticks: dict = {}    # squad label -> ticks the whole squad waited on its pad
    started_direct: set = set()  # squads put straight into a mission (lobby unsupported)
    lobby_unsupported = False
    seen_mission = False
    surfaces: list[dict] | None = None  # UI features this round must press, from the first observations
    async with AsyncExitStack() as stack:
        try:
            if harness is None and _is_harness(studio):
                harness, studio = studio, getattr(studio, "studio", None)
            if harness is None:
                if studio is None:
                    from forge.studio import Studio

                    studio = await stack.enter_async_context(Studio(settings))
                    await studio.select(studio_name)
                elif studio_name:
                    await studio.select(studio_name)
                from mubit_tester.harness import Harness

                harness = Harness(studio)
            report["studio"] = getattr(getattr(harness, "studio", None), "studio_id", None) or studio_name
            if hasattr(harness, "ensure_ready"):
                report["ready"] = await harness.ensure_ready()

            connected = await harness.players()
            roster = assign_roles(_select_players(list(connected or []), players), roles)
            if squads_mode:
                assign_squads(roster, squads)
            report["players"] = roster
            if not roster:
                raise RuntimeError("no players connected")
            windows = await _safe(harness.ui_windows) if hasattr(harness, "ui_windows") else {}
            windows = windows if isinstance(windows, dict) and not _err(windows) else {}
            for p in roster:
                p["can_press"] = str(p["userId"]) in windows
            report["ui_pressers"] = [p["name"] for p in roster if p["can_press"]]

            _, since = await _events(harness, None)  # start the event cursor at "now"
            active = {p["userId"] for p in roster}
            last_actions: dict = {}
            for n in range(1, max_ticks + 1):
                if not active or (deadline is not None and time.monotonic() >= deadline):
                    break
                t0 = time.monotonic()
                tick_players = [p for p in roster if p["userId"] in active]
                obs_list = await asyncio.gather(*(_observe(harness, p["userId"]) for p in tick_players))
                observations = {p["userId"]: o for p, o in zip(tick_players, obs_list)}
                if surfaces is None:
                    surfaces = ui_surfaces.assign_surfaces(ui_surfaces.derive_surfaces(
                        surface_spec, game_dir or settings.base_game_dir, list(observations.values())), roster)
                    report["ui_surfaces"] = surfaces
                    if any(s.get("assigned") for s in surfaces):
                        # a scripted pass presses every assigned surface before free play, so no menu goes
                        # unproven (run 2: PASS and GO NOW! assigned, 0 presses); then fresh observations
                        report["ui_pass"] = await ui_pass(harness, surfaces, roster)
                        obs_list = await asyncio.gather(*(_observe(harness, p["userId"]) for p in tick_players))
                        observations = {p["userId"]: o for p, o in zip(tick_players, obs_list)}
                if (n - 1) % PROBE_EVERY == 0:
                    probe, counters = await asyncio.gather(_probe(harness), _counters(harness))
                    report["counters"] = counters
                    if probe:
                        summary = play.summarize_probe(probe)
                        for o in observations.values():
                            o["probe"] = summary
                contexts: dict = {}
                if squads_mode:
                    lobby_unsupported, seen_mission = await _squads_tick(
                        harness, n, roster, tick_players, observations, phases, lobby_ticks, queued_ticks,
                        started_direct, lobby_unsupported, seen_mission, report, contexts, assist)
                observations = {k: play.compact_observation(v) for k, v in observations.items()}
                new_events, since = await _events(harness, since)
                all_events.extend(new_events)
                events = _compact_events(new_events)

                async def decide(p: dict) -> dict:
                    uid = p["userId"]
                    team = team_summary(p, roster, observations, last_actions)
                    step: dict = {"n": n, "player": uid, "player_name": p["name"], "role": p["role"],
                                  "observation": observations[uid], "team": team, "events": events,
                                  "action": {}, "result": "", "request_id": None, "latency_ms": 0}
                    if uid in contexts:
                        step["squad"] = contexts[uid]
                    try:
                        user = agent_user_message(goal, p, n, max_ticks if deadline is None else None, team,
                                                  observations[uid], _history(report["steps"], uid, n), events,
                                                  squad=contexts.get(uid), pressers=report["ui_pressers"],
                                                  ui_tasks=ui_surfaces.tasks_for(surfaces, p["name"]))
                        action, res = await play._to_thread(
                            llm.complete_json, agent_role, user, session_id=session_id,
                            required=["action", "reason"], max_tokens=1024,
                        )
                        step["request_id"] = res.request_id
                        step["latency_ms"] = res.latency_ms
                        if not isinstance(action.get("args"), dict):
                            action["args"] = {}
                        step["action"] = action
                    except Exception as e:  # noqa: BLE001
                        step["result"] = f"error: {type(e).__name__}: {_clip(str(e), 300)}"
                    return step

                decided = await asyncio.gather(*(decide(p) for p in tick_players))

                async def run(step: dict) -> dict:
                    if step["action"]:
                        step["result"] = await dispatch(harness, step["player"], step["action"])
                    return step

                done_steps = await asyncio.gather(*(run(s) for s in decided))
                for s in done_steps:
                    s["step_ms"] = int((time.monotonic() - t0) * 1000)
                    if s["request_id"]:
                        report["request_ids"].append(s["request_id"])
                    bug = _bug_from(s["action"], bug_key) if s["action"] else None
                    if bug:
                        bug.update(step=n, player=s["player_name"])
                        report["bug_hints"].append(bug)
                    a = s["action"].get("action") if s["action"] else None
                    last_actions[s["player"]] = f"{a or '?'}: {_clip(s['result'], 80)}"
                    if a == "done":
                        active.discard(s["player"])
                    if str(s["result"]).startswith("error: ") and "LLMError" not in s["result"]:
                        report["errors"].append(f"step {n} {s['player_name']}: {_clip(s['result'], 200)}")
                    report["steps"].append(s)
                play._save_report(settings, report)
                if squads_mode and seen_mission and all(phases.get(p["userId"]) in ("results", "returned")
                                                        for p in roster):
                    break  # every squad finished its mission
                if step_seconds > 0 and active:
                    await asyncio.sleep(step_seconds)

            report["probe"] = await _probe(harness)
            report["physics"] = play.physics_flags(report["probe"])
            report["counters"] = await _counters(harness)
            tail, since = await _events(harness, since)
            all_events.extend(tail)
            if squads_mode and hasattr(harness, "blame"):
                report["_blame_service"] = await _safe(harness.blame)
        except Exception as e:  # noqa: BLE001
            report["errors"].append(f"{type(e).__name__}: {_clip(str(e), 500)}")
    report["events"] = _compact_events(all_events)[-50:]
    report["ui_presses"] = ui_presses(all_events)
    report["ui_coverage"] = ui_surfaces.coverage(report.get("ui_surfaces") or [], report["ui_presses"],
                                                 report.get("ui_pass"))
    decided = [s["action"].get("action") for s in report["steps"] if s.get("action")]
    report["decisions"] = len(decided)  # one LLM call each
    report["macro_decisions"] = sum(1 for a in decided if a in MACROS or a == "repeat")

    squads_info = None
    if squads_mode:
        ev_stats = blame_from_events(all_events, report["players"])
        service = report.pop("_blame_service", None) or {}
        svc_stats = {}
        for s in (service.get("stats") or []) if isinstance(service, dict) else []:
            if isinstance(s, dict) and s.get("name"):
                svc_stats[s["name"]] = {k: v for k, v in s.items() if k not in ("name", "userId", "helmet")}
        report["per_player"] = [
            {"name": p["name"], "squad": p.get("squad"), "role": p["role"],
             "phases": report["phases"].get(p["name"], []), "events": ev_stats.get(p["name"], {}),
             **({"blame_service": svc_stats[p["name"]]} if p["name"] in svc_stats else {})}
            for p in report["players"]
        ]
        squads_info = {"phases": report["phases"], "instances": report["instances"], "assists": report["assists"],
                       "stats": {x["name"]: {"events": x["events"], **({"blame_service": x["blame_service"]}
                                                                       if "blame_service" in x else {})}
                                 for x in report["per_player"]}}

    try:
        user = judge_message(goal, report["players"], report["steps"], all_events, report["probe"],
                             report["counters"], report["bug_hints"], report["errors"], squads=squads_info,
                             ui_coverage=report["ui_coverage"])
        verdict, res = await play._to_thread(
            llm.complete_json, "judge", user, session_id=session_id,
            required=["goal_met", "bugs", "summary"], max_tokens=2048,
        )
        gm = verdict.get("goal_met")
        report["goal_met"] = gm if isinstance(gm, bool) else None
        report["summary"] = str(verdict.get("summary") or "")
        report["bugs"] = [b for b in (play._norm_bug(x) for x in verdict.get("bugs") or []) if b]
        if squads_mode and isinstance(verdict.get("players"), list):
            judged = {str(x.get("name")): x for x in verdict["players"] if isinstance(x, dict)}
            for pp in report["per_player"]:
                j = judged.get(pp["name"])
                if j:
                    pp["blame"] = str(j.get("blame") or "")
                    pp["credit"] = str(j.get("credit") or "")
        report["judge_request_id"] = res.request_id
        if res.request_id:
            report["request_ids"].append(res.request_id)
    except Exception as e:  # noqa: BLE001
        report["errors"].append(f"judge: {type(e).__name__}: {_clip(str(e), 300)}")
        report["summary"] = "judge failed; bugs are the testers' own flags"
        report["bugs"] = [{k: b[k] for k in ("title", "evidence", "severity")} for b in report["bug_hints"]]

    report["ended"] = play._now_iso()
    play._save_report(settings, report)
    return report


async def multi_playtest(settings: Settings, goal: str, players: int | list | None = None, steps: int = 20,
                         roles: list[str] | None = None, *, llm=None, studio=None, harness=None,
                         studio_name: str | None = None, step_seconds: float = 1.0, mode: str = "free",
                         squads: int = 1, assist: bool = True, game_dir: Path | str | None = None) -> dict:
    """One `player` agent per connected player (or the first N / the named ones), acting concurrently.

    mode="squads": the full multiplayer loop lobby -> pad -> countdown -> mission -> results. Players
    are split into `squads` squads (A on pad 1, B on pad 2, ...); every agent is told its phase,
    squad and instance each tick (in the user message). With `assist`, the harness queues players
    idle in the lobby, launches squads stuck on their pad, and starts missions directly when the
    lobby isn't implemented yet. The judge also gets per-player stats and reports per-player blame.

    game_dir: the game's files (default settings.base_game_dir); its client scripts and ../spec.json
    give the UI surfaces each presser must cover, reported as `ui_coverage`.
    """
    if mode not in ("free", "squads"):
        raise ValueError(f"mode must be 'free' or 'squads', got {mode!r}")
    return await _session(settings, kind="multi_playtest", agent_role="player", goal=goal, players=players,
                          roles=roles, max_ticks=max(1, int(steps)), deadline=None, llm=llm, studio=studio,
                          harness=harness, studio_name=studio_name, step_seconds=step_seconds, bug_key="bug",
                          mode=mode, squads=squads, assist=assist, game_dir=game_dir)


async def explore(settings: Settings, minutes: float = 3, players: int | list | None = None, *, llm=None,
                  studio=None, harness=None, roles: list[str] | None = None, studio_name: str | None = None,
                  max_ticks: int = MAX_EXPLORE_TICKS, step_seconds: float = 0.5,
                  game_dir: Path | str | None = None) -> dict:
    """Bug hunt with the `explorer` role for `minutes` across players; the judge dedupes the bugs."""
    deadline = time.monotonic() + max(0.0, float(minutes)) * 60.0
    rep = await _session(settings, kind="explore", agent_role="explorer", goal=EXPLORE_GOAL, players=players,
                         roles=roles or EXPLORE_ROLES, max_ticks=max(1, int(max_ticks)), deadline=deadline,
                         llm=llm, studio=studio, harness=harness, studio_name=studio_name,
                         step_seconds=step_seconds, bug_key="suspected_bug", game_dir=game_dir)
    rep["suspected_bugs"] = list(rep.get("bug_hints") or [])
    play._save_report(settings, rep)
    return rep


async def qa_test(settings: Settings, focus: str | None = None, **kw) -> dict:
    """The 5-phase QA protocol (understand, plan, execute, investigate, report) with screenshots and
    vision; see mubit_tester.protocol.qa_test for the arguments."""
    from mubit_tester import protocol

    return await protocol.qa_test(settings, focus, **kw)


# --------------------------------------------------------------------------- corrections


def _find_step(report: dict, step: int, player: Any) -> dict:
    hits = [s for s in report.get("steps") or [] if s.get("n") == step]
    if not hits:
        raise ValueError(f"run {report.get('run_id')} has no step {step}")
    if player is not None:
        w = str(player).strip().lower()
        roster = report.get("players") or []
        ids = {str(p.get("userId")) for p in roster
               if any(str(p.get(k, "")).strip().lower() == w for k in ("userId", "name", "helmet")
                      if p.get(k) is not None)}
        for s in hits:
            if str(s.get("player")) in ids or str(s.get("player_name", "")).lower() == w or str(s.get("player")).lower() == w:
                return s
        raise ValueError(f"step {step} has no record for player {player!r}")
    if len(hits) > 1:
        names = ", ".join(str(s.get("player_name") or s.get("player")) for s in hits)
        raise ValueError(f"step {step} has several players ({names}); pass player=")
    return hits[0]


async def correct_step(settings: Settings, run_id: str, step: int, note: str, player: Any = None, *,
                       llm=None) -> dict:
    """Re-run one player's agent call at `step` with a human correction (same Mubit task + session)."""
    report = play.load_report(settings, run_id)
    if report.get("kind") == "protocol":  # QA protocol run: step 0 = plan, n = step judge, -1 = visual
        from mubit_tester import protocol

        return await protocol.correct(settings, run_id, step, note, llm=llm)
    if not report.get("players"):
        return await play.correct_step(settings, run_id, step, note, llm=llm)
    if not note or not note.strip():
        raise ValueError("correction note is empty")
    target = _find_step(report, step, player)
    roster = report["players"]
    me = next((p for p in roster if p.get("userId") == target.get("player")),
              {"userId": target.get("player"), "name": target.get("player_name") or str(target.get("player")),
               "role": target.get("role") or "", "helmet": None})
    if llm is None:
        llm = llm_mod.make_llm(settings, log_path=play._run_dir(settings, run_id) / "calls.jsonl")
    role = report.get("agent_role") or "player"
    total = report.get("max_steps") if report.get("kind") != "explore" else None
    user = agent_user_message(report.get("goal", ""), me, step, total, target.get("team") or [],
                              target.get("observation") or {},
                              _history(report.get("steps") or [], target.get("player"), step),
                              target.get("events") or [], squad=target.get("squad"),
                              pressers=report.get("ui_pressers"),
                              ui_tasks=ui_surfaces.tasks_for(report.get("ui_surfaces") or [], me.get("name")))
    user += "\n\n## Correction from a human tester\n" + note.strip()
    after, res = await play._to_thread(
        llm.complete_json, role, user, session_id=report.get("session_id") or "playtest-" + run_id,
        required=["action", "reason"], max_tokens=1024,
    )
    out = {"run_id": run_id, "step": step, "player": target.get("player"),
           "player_name": target.get("player_name"), "before": target.get("action") or {}, "after": after,
           "request_id": res.request_id}
    report.setdefault("corrections", []).append({**out, "note": note.strip(), "ts": play._now_iso()})
    if res.request_id:
        report.setdefault("request_ids", []).append(res.request_id)
    play._save_report(settings, report)
    return out


# --------------------------------------------------------------------------- fix suggestions

_STOP = set("""the and for with that this from when what were was are not but did does into then than
have has had out off its it's after before while still should would could they them their there here
player players game step steps value values water fire fires never always only same just like also
true false null none error errors bug bugs evidence severity medium high low prompt prompts""".split())
_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]{3,}")


class _Recorder(llm_mod._JSONMixin):
    """Wraps an LLM to collect request ids of every call (critique/fix_file hide them)."""

    def __init__(self, inner):
        self.inner = inner
        self.request_ids: list[str] = []

    def complete(self, role: str, user: str, *, session_id: str, max_tokens: int = 4096):
        res = self.inner.complete(role, user, session_id=session_id, max_tokens=max_tokens)
        if res.request_id:
            self.request_ids.append(res.request_id)
        return res


def _game_files(settings: Settings) -> dict[str, Path]:
    root = Path(settings.base_game_dir)
    out = {}
    for p in sorted(root.rglob("*.luau")):
        rel = p.relative_to(root).as_posix()
        if rel.startswith(("tools/", ".")) or "/." in rel:
            continue
        out[rel] = p
    return out


def find_candidate_files(settings: Settings, text: str, limit: int = 3) -> list[tuple[str, int]]:
    """Rank game/**/*.luau by how well they match a bug's text: names/paths first, then keywords."""
    files = _game_files(settings)
    low = text.lower()
    words = {w.lower() for w in _IDENT.findall(text)} - _STOP
    # path segments like Workspace.Map.Hydrant1 or ServerScriptService/Services/MapService.luau
    segs = {s.lower() for s in re.split(r"[./\\:\s\"'(),\[\]]+", text) if len(s) >= 3} - _STOP
    scored = []
    for rel, path in files.items():
        stem = path.name.split(".")[0]
        score = 0
        if rel.lower() in low:
            score += 50
        if stem.lower() in segs:
            score += 20
        elif stem.lower() in low:
            score += 8
        stem_l = stem.lower()
        for seg in segs:
            if len(seg) >= 4 and seg != stem_l and seg in stem_l:
                score += 4
        try:
            src = path.read_text(encoding="utf-8", errors="replace").lower()
        except OSError:
            continue
        score += sum(1 for w in words if w in src)
        if score > 0:
            scored.append((rel, score))
    scored.sort(key=lambda t: (-t[1], t[0]))
    return scored[:limit]


def _bug_list(report: dict) -> list[dict]:
    return list(report.get("bugs") or report.get("suspected_bugs") or report.get("bug_hints") or [])


async def suggest_fix(settings: Settings, run_id: str, bug_index: int, *, llm=None) -> dict:
    """Bug -> likely file -> critic analysis -> fixer patch -> unified diff preview (nothing written)."""
    from forge import roles as roles_mod

    report = play.load_report(settings, run_id)
    bugs = _bug_list(report)
    if not 0 <= bug_index < len(bugs):
        raise ValueError(f"run {run_id} has {len(bugs)} bugs; bug index {bug_index} is out of range")
    bug = bugs[bug_index]
    title = str(bug.get("title") or "")
    evidence = str(bug.get("evidence") or "")
    probe_errs = [e for e in (report.get("probe") or {}).get("errors") or [] if isinstance(e, dict)]
    related = [e for e in probe_errs if any(w in str(e.get("message", "")).lower()
                                            for w in (_IDENT.findall(title + " " + evidence) or [])
                                            if len(w) > 4)]
    search_text = " ".join([title, evidence] + [f"{e.get('script', '')} {e.get('message', '')}" for e in related])
    cands = find_candidate_files(settings, search_text)
    if not cands:
        raise ValueError(f"no game file under {settings.base_game_dir} matches bug {title!r}")
    files_on_disk = _game_files(settings)
    sources = {rel: files_on_disk[rel].read_text(encoding="utf-8") for rel, _ in cands}

    if llm is None:
        llm = llm_mod.make_llm(settings, log_path=play._run_dir(settings, run_id) / "calls.jsonl")
    rec = _Recorder(llm)
    session_id = report.get("session_id") or "playtest-" + run_id
    spec = {
        "title": "Flame and Blame",
        "pitch": "Co-op firefighter game: fight spreading fires, refill water, break doors, rescue people/pets.",
        "core_loop": report.get("goal", ""),
        "acceptance": [f"Fixed: {title}"],
        "modules": [{"path": rel, "purpose": "", "depends": []} for rel in sources],
    }
    context = game_context(settings)
    if context:
        spec.update(context)
        spec['acceptance'] = [f'Fixed: {title}']
    probe_like = {"errors": [{"message": f"[playtest bug] {title}", "trace": evidence}] + related[:4],
                  "counters": report.get("counters") or {}}
    console = "\n".join(f"{e.get('t')} {e.get('kind')} {_dumps(e.get('data'))}"
                        for e in (report.get("events") or [])[-20:] if isinstance(e, dict))
    crit = await play._to_thread(roles_mod.critique, rec, spec, probe_like, console, sources,
                                 session_id=session_id)
    issue = next((i for i in crit.get("issues") or [] if i.get("path") in sources), None)
    path = issue["path"] if issue else cands[0][0]
    problem = f"Playtest bug: {title}\nEvidence: {evidence}"
    if issue:
        problem += f"\nAnalysis: {issue.get('problem', '')}\nFix hint: {issue.get('fix_hint', '')}"
    context = f"Critic summary: {crit.get('summary', '')}\nOther candidate files: " + \
        ", ".join(r for r, _ in cands if r != path)
    lessons_file = Path(settings.runs_dir) / "lessons.md"
    lessons = lessons_file.read_text(encoding="utf-8") if lessons_file.exists() else ""
    source = sources[path]
    fixed = await play._to_thread(roles_mod.fix_file, rec, path, source, problem, context, lessons,
                                  session_id=session_id)
    diff = "".join(difflib.unified_diff(
        source.splitlines(keepends=True), fixed.splitlines(keepends=True),
        fromfile=f"a/game/{path}", tofile=f"b/game/{path}",
    ))
    out = {
        "run_id": run_id, "bug_index": bug_index, "bug": bug, "path": path,
        "file": str(files_on_disk[path]), "problem": problem, "candidates": [r for r, _ in cands],
        "critique": {"summary": crit.get("summary", ""), "issue": issue}, "patch_preview": diff,
        "request_ids": rec.request_ids,
    }
    report.setdefault("fix_suggestions", []).append({**out, "ts": play._now_iso()})
    report.setdefault("request_ids", []).extend(rec.request_ids)
    play._save_report(settings, report)
    return out
