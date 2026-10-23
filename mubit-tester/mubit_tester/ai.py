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
HISTORY = 4
PROBE_EVERY = 5
EVENTS_MAX = 12
TEAM_CHARS = 1200
EVENTS_CHARS = 1500
TRACE_CHARS = 12_000
ACT_TIMEOUT = 60.0
MAX_EXPLORE_TICKS = 200


# --------------------------------------------------------------------------- small helpers

_clip = play._clip
_dumps = play._dumps


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
    if name == "wait":
        return "wait", {"seconds": max(0.0, min(_num(args.get("seconds"), 2.0), 10.0))}
    if name == "done":
        return "done"
    return f"error: unknown action {name!r}"


async def dispatch(harness, user_id: Any, action: dict) -> str:
    mapped = map_action(action)
    if isinstance(mapped, str):
        return mapped
    name, args = mapped
    if name == "wait":
        await asyncio.sleep(args["seconds"])
        return f"waited {args['seconds']:.1f}s"
    timeout = ACT_TIMEOUT + float(args.get("seconds", 0) or 0)
    try:
        res = await asyncio.wait_for(harness.act(user_id, name, **args), timeout)
    except Exception as e:  # noqa: BLE001
        return f"error: {name}: {type(e).__name__}: {_clip(str(e), 200)}"
    if isinstance(res, dict):
        detail = res.get("detail")
        ok = res.get("done")
        return f"{name} {_dumps(args)} -> done={ok} {_clip(detail if detail is not None else '', play.RESULT_CHARS)}".rstrip()
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
                       observation: dict, history: list[dict], events: list) -> str:
    team_text = _clip(_dumps(team), TEAM_CHARS) if team else "none (you are the only test player)"
    lines = [
        "## Goal", goal.strip(), "",
        "## You", f"{me['name']} (helmet {me.get('helmet')}); role: {me['role']}", "",
        "## Step", f"{n} of {total}" if total else str(n), "",
        "## Team", team_text, "",
        "## Observation", _dumps(observation), "",
        "## Recent actions (oldest first)",
    ]
    if history:
        for h in history:
            a = h.get("action") or {}
            lines.append(f"- step {h['n']}: {a.get('action', '?')} {_dumps(a.get('args') or {})} -> "
                         f"{_clip(h.get('result', ''), 200)}")
    else:
        lines.append("- none yet")
    lines += ["", "## New game events", _clip(_dumps(events), EVENTS_CHARS) if events else "none"]
    return "\n".join(lines)


def _history(steps: list[dict], user_id: Any, n: int) -> list[dict]:
    return [s for s in steps if s.get("player") == user_id and s.get("n", 0) < n][-HISTORY:]


def _bug_from(action: dict, key: str) -> dict | None:
    return play._norm_bug(action.get(key))


def judge_message(goal: str, roster: list[dict], steps: list[dict], events: list, probe: dict,
                  counters: Any, hints: list[dict], errors: list[str]) -> str:
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
    return "\n".join([
        "## Goal", goal.strip(), "",
        "## Players", _dumps([{"name": p["name"], "role": p["role"]} for p in roster]), "",
        "## Trace (step.player: action args | reason | -> result | obs)", text or "(no steps ran)", "",
        "## Game events (most recent)", _clip(_dumps(_compact_events(events)[-20:]), 3000) if events else "none", "",
        "## ForgeProbe (server)", _dumps(play.summarize_probe(probe or {})), "",
        "## Counters", _clip(_dumps(counters or {}), 800), "",
        "## Tool errors", _clip(_dumps(errors[-8:]), 1000) if errors else "none", "",
        "## Bugs flagged by the playtesters", _clip(_dumps(hints), 4000) if hints else "none",
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


# --------------------------------------------------------------------------- the session loop


async def _session(settings: Settings, *, kind: str, agent_role: str, goal: str, players, roles,
                   max_ticks: int, deadline: float | None, llm, studio, harness, studio_name,
                   step_seconds: float, bug_key: str) -> dict:
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
        "corrections": [], "errors": [],
    }
    play._save_report(settings, report)

    all_events: list = []
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
            report["players"] = roster
            if not roster:
                raise RuntimeError("no players connected")

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
                if (n - 1) % PROBE_EVERY == 0:
                    probe, counters = await asyncio.gather(_probe(harness), _counters(harness))
                    report["counters"] = counters
                    if probe:
                        summary = play.summarize_probe(probe)
                        for o in observations.values():
                            o["probe"] = summary
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
                    try:
                        user = agent_user_message(goal, p, n, max_ticks if deadline is None else None, team,
                                                  observations[uid], _history(report["steps"], uid, n), events)
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
                if step_seconds > 0 and active:
                    await asyncio.sleep(step_seconds)

            report["probe"] = await _probe(harness)
            report["counters"] = await _counters(harness)
            tail, since = await _events(harness, since)
            all_events.extend(tail)
        except Exception as e:  # noqa: BLE001
            report["errors"].append(f"{type(e).__name__}: {_clip(str(e), 500)}")
    report["events"] = _compact_events(all_events)[-50:]

    try:
        user = judge_message(goal, report["players"], report["steps"], all_events, report["probe"],
                             report["counters"], report["bug_hints"], report["errors"])
        verdict, res = await play._to_thread(
            llm.complete_json, "judge", user, session_id=session_id,
            required=["goal_met", "bugs", "summary"], max_tokens=2048,
        )
        gm = verdict.get("goal_met")
        report["goal_met"] = gm if isinstance(gm, bool) else None
        report["summary"] = str(verdict.get("summary") or "")
        report["bugs"] = [b for b in (play._norm_bug(x) for x in verdict.get("bugs") or []) if b]
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
                         studio_name: str | None = None, step_seconds: float = 1.0) -> dict:
    """One `player` agent per connected player (or the first N / the named ones), acting concurrently."""
    return await _session(settings, kind="multi_playtest", agent_role="player", goal=goal, players=players,
                          roles=roles, max_ticks=max(1, int(steps)), deadline=None, llm=llm, studio=studio,
                          harness=harness, studio_name=studio_name, step_seconds=step_seconds, bug_key="bug")


async def explore(settings: Settings, minutes: float = 3, players: int | list | None = None, *, llm=None,
                  studio=None, harness=None, roles: list[str] | None = None, studio_name: str | None = None,
                  max_ticks: int = MAX_EXPLORE_TICKS, step_seconds: float = 0.5) -> dict:
    """Bug hunt with the `explorer` role for `minutes` across players; the judge dedupes the bugs."""
    deadline = time.monotonic() + max(0.0, float(minutes)) * 60.0
    rep = await _session(settings, kind="explore", agent_role="explorer", goal=EXPLORE_GOAL, players=players,
                         roles=roles or EXPLORE_ROLES, max_ticks=max(1, int(max_ticks)), deadline=deadline,
                         llm=llm, studio=studio, harness=harness, studio_name=studio_name,
                         step_seconds=step_seconds, bug_key="suspected_bug")
    rep["suspected_bugs"] = list(rep.get("bug_hints") or [])
    play._save_report(settings, rep)
    return rep


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
                              target.get("events") or [])
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
