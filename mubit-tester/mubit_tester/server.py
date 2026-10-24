"""`forge mcp`: the `mubit-tester` stdio MCP server (contract: docs/TESTER.md).

Session: status, studios, play_start, play_stop, multiplayer_start, sync, preview.
World:   players, observe, query, inspect, counters, events, errors, console, screenshot.
Control: act, act_all, teleport, ignite, extinguish, set_attr, config, reset, round.
Squads:  squads, instances, queue, launch, mission_start, mission_end (lobby, pads, mission instances).
Testing: scenario_run, scenario_list.
AI:      playtest, explore, playtest_correct, suggest_fix, report, reports (every LLM call via Mubit).

Multiplayer routing: harness calls run in the Server datamodel of the selected Studio window. A
"Clients and Servers" test opens separate Server/Client windows; `multiplayer_start` picks the
server window, and if a call still lands on a window without a Server datamodel `_relocate` finds
the one that has it. In a Team Test with real friends the server is in the cloud, so calls are
relayed from a Client datamodel (Harness mode "client").

stdout is the MCP wire. Everything else goes to stderr: tool bodies run under
`redirect_stdout(sys.stderr)` so progress prints never corrupt the protocol stream. (The mcp SDK
also points fd 1 at stderr while serving, which covers subprocesses.)

Each tool opens its own short-lived StudioMCP connection (`open_studio`), so nothing crosses
request task groups. The chosen Studio (by `studios(select=...)` or `multiplayer_start`) is
remembered in `STATE` for the life of the server.
"""

from __future__ import annotations

import builtins
import contextlib
import io
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, AsyncIterator

import anyio
from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.server.mcpserver.utilities.types import Image

from forge.config import load_settings
from mubit_tester.harness import Harness, HarnessError

INSTRUCTIONS = (
    "mubit-tester drives the Roblox game open in Studio through an in-game harness (ForgeTest) that "
    "controls EVERY player (Studio test clients or real Team Test friends) and knows the game's tags "
    "and attributes. Typical loop after a code change: sync -> play_start (or multiplayer_start) -> "
    "scenario_run smoke (and any scenario for the feature) -> errors -> play_stop. Use players/observe/"
    "query/events to look, act/act_all/teleport/ignite/... to poke. For open-ended checks use playtest "
    "(Mubit AI players + judge) or explore (bug hunt); if an AI player chose wrong, playtest_correct "
    "records the right choice as a Mubit training example. Players are addressed by name, UserId or "
    "helmet number '1'..'4'. Multiplayer: multiplayer_start(players=N) (or a Team Test with friends), "
    "then squads/queue/launch for the station lobby, instances/mission_start/mission_end for parallel "
    "mission instances, and instance_id on players/observe/query/events to look at one instance; "
    "playtest(mode='squads', squads=2) runs AI squads through lobby -> mission -> results."
)

mcp = MCPServer("mubit-tester", instructions=INSTRUCTIONS)

STATE: dict[str, Any] = {"studio_id": None, "hint": os.environ.get("FORGE_STUDIO") or None,
                         "mode": "server", "clients": []}
MAX_TEXT = 20000
MULTIPLAYER_WAIT = 90.0
MULTIPLAYER_POLL = 2.0
MULTIPLAYER_JOIN_WAIT = 45.0

# StudioTestService:ExecuteMultiplayerTestAsync(numPlayers: int (1-8), args: Variant): Variant
# (PluginSecurity, yields until the test ends, so it runs in its own thread; errors if a test is
# already running). Verified against create.roblox.com/docs/reference/engine/classes/StudioTestService.
# The Edit datamodel of execute_luau runs with plugin security. We wait briefly so an immediate error
# (no permission, test already running) is reported instead of a silent "started".
MULTIPLAYER_LUAU = r"""
local STS = game:GetService("StudioTestService")
local ok, fn = pcall(function() return STS.ExecuteMultiplayerTestAsync end)
if not ok or fn == nil then return "unsupported: StudioTestService.ExecuteMultiplayerTestAsync not available" end
local err = nil
task.spawn(function()
	local okRun, e = pcall(function() return STS:ExecuteMultiplayerTestAsync(%d, "mubit-tester") end)
	if not okRun then err = tostring(e) end
end)
task.wait(1.5)
if err then return "error: " .. err end
return "started"
"""

# StudioTestService:AddPlayers(numPlayers) must run in the Server datamodel of a running test.
ADD_PLAYERS_LUAU = 'game:GetService("StudioTestService"):AddPlayers(%d) return "added"'

MANUAL_MULTIPLAYER = (
    "Start it by hand: Studio → Test tab → Clients and Servers → set Players to {n} → Start. "
    "Studio opens a server window plus {n} client windows. Then call `studios` to see them and "
    "`studios(select=\"<server id or name>\")` if the server isn't picked automatically, and "
    "`players` to check everyone joined. For real friends: Team Create the place, then Test tab → "
    "Team Test → Start; every tool still works (calls are relayed through a client) and players "
    "are addressed by name or helmet. Outside local Studio tests, add a BoolValue "
    "ServerStorage.ForgeTestEnabled = true (remove before publishing)."
)


# ---------------------------------------------------------------- formatting helpers

def _cell(v: Any, n: int = 60) -> str:
    if v is None:
        return ""
    if not isinstance(v, str):
        v = json.dumps(v, ensure_ascii=False, separators=(",", ":"), default=str)
    v = " ".join(v.split()).replace("|", "\\|")
    return v if len(v) <= n else v[: n - 1] + "…"


def _j(obj: Any, title: str | None = None) -> str:
    """Compact-but-readable JSON (with an optional markdown heading), capped for the LLM reader."""
    body = json.dumps(obj, ensure_ascii=False, indent=1, default=str)
    if len(body) > MAX_TEXT:
        body = body[:MAX_TEXT] + f"\n… (truncated, {len(body)} chars)"
    return f"## {title}\n```json\n{body}\n```" if title else body


def _action_and_reason(step: dict) -> tuple[Any, Any]:
    action = step.get("action")
    reason = step.get("reason")
    if isinstance(action, dict):
        action = dict(action)
        reason = reason or action.pop("reason", None)
    return action, reason


def format_report(report: dict) -> str:
    """Concise markdown for a playtest report (mubit_tester.play / mubit_tester.ai shape)."""
    run_id = report.get("run_id", "?")
    met = report.get("goal_met")
    met_s = "yes" if met is True else "no" if met is False else "unknown"
    out = [f"## Playtest `{run_id}`", "",
           f"**Goal:** {report.get('goal', '')}",
           f"**Goal met:** {met_s}"]
    players = report.get("players")
    if players:
        names = [p.get("name") or p.get("userId") if isinstance(p, dict) else p for p in players]
        roles = [p.get("role") for p in players if isinstance(p, dict) and p.get("role")]
        out.append(f"**Players:** {', '.join(map(str, names))}" + (f" (roles: {', '.join(roles)})" if roles else ""))
    if report.get("mode") == "squads":
        out.append(f"**Mode:** squads ({report.get('squads', 1)} squad(s)); instances: "
                   + (", ".join(f"{i.get('instanceId')} ({i.get('missionId')})" for i in report.get("instances") or [])
                      or "none reached"))
    out.append("")
    if report.get("summary"):
        out += [str(report["summary"]).strip(), ""]
    per = report.get("per_player") or []
    if per:
        out += ["### Per player", "", "| player | squad | phases | blame | credit | stats |", "|---|---|---|---|---|---|"]
        for p in per:
            stats = {k: v for k, v in (p.get("events") or {}).items() if v}
            out.append(f"| {_cell(p.get('name'), 20)} | {_cell(p.get('squad'), 4)} | {_cell(' '.join(p.get('phases') or []), 50)} | "
                       f"{_cell(p.get('blame'), 80)} | {_cell(p.get('credit'), 80)} | {_cell(stats or '', 80)} |")
        out.append("")
    assists = report.get("assists") or []
    if assists:
        out.append(f"Harness assists ({len(assists)}): " + "; ".join(
            f"t{a.get('n')} {a.get('who')}: {a.get('action')}" for a in assists[:8]))
        out.append("")

    bugs = report.get("bugs") or []
    out.append(f"### Bugs ({len(bugs)})")
    if bugs:
        for i, b in enumerate(bugs):
            if isinstance(b, dict):
                sev = b.get("severity") or "?"
                out.append(f"- #{i} **[{sev}] {b.get('title', '')}**: {_cell(b.get('evidence'), 200)}")
            else:
                out.append(f"- #{i} {_cell(b, 200)}")
    else:
        out.append("- none reported")
    out.append("")

    steps = report.get("steps") or []
    if steps:
        multi = any("player" in s for s in steps)
        head = "| n | player | action | reason | result |" if multi else "| n | action | reason | result |"
        out += [f"### Steps ({len(steps)})", "", head, "|---" * (5 if multi else 4) + "|"]
        for i, st in enumerate(steps, 1):
            action, reason = _action_and_reason(st)
            who = f" {_cell(st.get('player'), 20)} |" if multi else ""
            out.append(f"| {st.get('n', i)} |{who} {_cell(action, 50)} | {_cell(reason, 50)} | {_cell(st.get('result'), 60)} |")
        out.append("")

    errs = report.get("errors") or []
    if errs:
        out += [f"Run errors: {_cell(errs, 300)}", ""]
    rids = report.get("request_ids")
    if rids is None:
        rids = [s.get("request_id") for s in steps if s.get("request_id")]
    out.append(f"Mubit requests: {len(rids or [])}")
    out.append("")
    out.append(f"To correct a wrong choice: `playtest_correct(run_id=\"{run_id}\", step=<n>, "
               "note=\"what it should have done\")`; to get a fix for bug #i: "
               f"`suggest_fix(run_id=\"{run_id}\", bug=<i>)`.")
    return "\n".join(out)


def format_correction(res: dict) -> str:
    return "\n".join([
        f"## Correction recorded: `{res.get('run_id')}` step {res.get('step')}"
        + (f" (player {res['player']})" if res.get("player") else ""), "",
        f"**Before:** {_cell(res.get('before'), 300)}",
        f"**After:** {_cell(res.get('after'), 300)}", "",
        f"Mubit request id: `{res.get('request_id') or '-'}` (same player task, so it counts as a "
        "training example).",
    ])


def format_list(reports: list[dict]) -> str:
    if not reports:
        return "No playtest reports yet. Run `playtest` first."
    out = ["| run_id | goal met | bugs | steps | goal |", "|---|---|---|---|---|"]
    for r in reports:
        met = r.get("goal_met")
        met_s = "yes" if met is True else "no" if met is False else "?"
        bugs = r.get("bugs")
        steps = r.get("steps")
        nb = len(bugs) if isinstance(bugs, list) else (bugs if bugs is not None else r.get("n_bugs", ""))
        ns = len(steps) if isinstance(steps, list) else (steps if steps is not None else r.get("n_steps", ""))
        out.append(f"| `{r.get('run_id', '?')}` | {met_s} | {nb} | {ns} | {_cell(r.get('goal'), 60)} |")
    return "\n".join(out)


def format_players(players: list[dict]) -> str:
    if not players:
        return "No players connected (is play running? `play_start` / `multiplayer_start`)."
    out = [f"## Players ({len(players)})", "",
           "| helmet | name | userId | squad | instance | pos | health | heat | tool | carrying | downed | attrs |",
           "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for p in players:
        pos = p.get("pos")
        if isinstance(pos, list):
            pos = [builtins.round(x, 1) if isinstance(x, (int, float)) else x for x in pos]
        hp = f"{p.get('health')}/{p.get('maxHealth')}" if p.get("maxHealth") is not None else p.get("health")
        out.append(f"| {_cell(p.get('helmet'), 6)} | {_cell(p.get('name'), 20)} | {_cell(p.get('userId'), 14)} | "
                   f"{_cell(p.get('squadId'), 8)} | {_cell(p.get('instanceId'), 10)} | "
                   f"{_cell(pos, 30)} | {_cell(hp, 10)} | {_cell(p.get('heat'), 6)} | {_cell(p.get('tool'), 16)} | "
                   f"{_cell(p.get('carrying'), 16)} | {_cell(p.get('downed'), 6)} | {_cell(p.get('attrs'), 80)} |")
    return "\n".join(out)


def format_squads(res: dict) -> str:
    """Lobby: service status, squads (members, pad, countdown, mission, instance) and pads."""
    if not isinstance(res, dict):
        return _j(res)
    squads = res.get("squads") or []
    pads = res.get("pads") or []
    out = [f"## Lobby: LobbyService {res.get('service', '?')} (via {res.get('via', '?')}); "
           f"{len(squads)} squad(s), {len(pads)} pad(s); catalog: {', '.join(res.get('catalog') or []) or 'none'}", ""]
    if squads:
        out += ["| squad | pad | state | countdown | mission | instance | members |", "|---|---|---|---|---|---|---|"]
        for s in squads:
            members = ", ".join(str(m.get("name") or m.get("userId")) for m in s.get("members") or [] if isinstance(m, dict))
            out.append(f"| {_cell(s.get('id'), 8)} | {_cell(s.get('padId'), 4)} | {_cell(s.get('state'), 12)} | "
                       f"{_cell(s.get('countdown'), 6)} | {_cell(s.get('missionId'), 20)} | {_cell(s.get('instanceId'), 10)} | "
                       f"{_cell(members, 60)} |")
        out.append("")
    if pads:
        out += ["| pad | squad | standing | path |", "|---|---|---|---|"]
        for p in pads:
            standing = ", ".join(str(m.get("name")) for m in p.get("standing") or [] if isinstance(m, dict))
            out.append(f"| {_cell(p.get('padId'), 4)} | {_cell(p.get('squadId'), 8)} | {_cell(standing, 50)} | "
                       f"{_cell(p.get('path'), 60)} |")
        out.append("")
    lobby = res.get("lobby") or []
    out.append(f"In the lobby: {', '.join(str(m.get('name')) for m in lobby if isinstance(m, dict)) or 'nobody'}")
    return "\n".join(out)


def format_instances(rows: list) -> str:
    if not rows:
        return "No mission instances running."
    out = [f"## Mission instances ({len(rows)})", "",
           "| instance | mission | squad | state | ends in | fires | rescues | players |", "|---|---|---|---|---|---|---|---|"]
    for r in rows:
        if not isinstance(r, dict):
            continue
        players = ", ".join(str(m.get("name") or m.get("userId")) for m in r.get("players") or [] if isinstance(m, dict))
        out.append(f"| {_cell(r.get('instanceId'), 10)} | {_cell(r.get('missionId'), 20)} | {_cell(r.get('squadId'), 8)} | "
                   f"{_cell(r.get('state'), 10)} | {_cell(r.get('secondsLeft'), 8)} | {_cell(r.get('fires'), 6)} | "
                   f"{_cell(r.get('rescues'), 50)} | {_cell(players, 60)} |")
    return "\n".join(out)


def format_probe(rep: dict) -> str:
    if rep.get("error") and not rep.get("errors"):
        return f"ForgeProbe unavailable: {rep['error']}"
    errs = rep.get("errors") or []
    warns = rep.get("warnings") or []
    out = [f"## ForgeProbe: {len(errs)} error(s), {len(warns)} warning(s)"]
    for e in errs:
        if isinstance(e, dict):
            out.append(f"- **{_cell(e.get('message'), 300)}** x{e.get('count', 1)} ({_cell(e.get('script'), 80)})")
            if e.get("trace"):
                out.append(f"  trace: {_cell(e.get('trace'), 400)}")
        else:
            out.append(f"- {_cell(e, 300)}")
    if warns:
        out.append("### Warnings")
        out += [f"- {_cell(w, 200)}" for w in warns[:30]]
    extra = {k: v for k, v in rep.items() if k not in ("errors", "warnings")}
    if extra:
        out.append(f"\nother: {_cell(extra, 600)}")
    return "\n".join(out)


# ---------------------------------------------------------------- plumbing

@contextlib.contextmanager
def _stdout_to_stderr():
    with contextlib.redirect_stdout(sys.stderr):
        yield


@contextlib.contextmanager
def _tool_errors():
    """Surface the real cause to the MCP client (the SDK otherwise hides unexpected exceptions)."""
    try:
        with _stdout_to_stderr():
            yield
    except ToolError:
        raise
    except SystemExit as e:  # forge.watch/preview use SystemExit for compile errors
        raise ToolError(str(e.code if e.code is not None else e)) from e
    except Exception as e:
        print(f"mubit-tester: {type(e).__name__}: {e}", file=sys.stderr)
        raise ToolError(f"{type(e).__name__}: {e}") from e


@contextlib.asynccontextmanager
async def _default_open_studio(select: bool = True) -> AsyncIterator[Any]:
    """Connected forge.studio.Studio; with select, pinned to STATE's studio (or the hint/first one)."""
    from forge.studio import Studio
    async with Studio(load_settings()) as studio:
        if not select:
            yield studio
            return
        sid = STATE.get("studio_id")
        if sid and any(s.get("id") == sid for s in await studio.list_studios()):
            studio.studio_id = sid
        else:
            await studio.select(STATE.get("hint"))
        yield studio


# Tests replace this with a factory yielding a fake Studio.
open_studio = _default_open_studio


async def _studio_datamodels(studio: Any, sid: str) -> set[str]:
    from forge.studio import available_datamodels
    try:
        return available_datamodels(await studio.call("get_studio_state", studio_id=sid))
    except Exception:  # noqa: BLE001
        return set()


async def _relocate(studio: Any) -> str | None:
    """Point `studio` at the window with a Server datamodel ("server"), else one with a Client
    datamodel for relay ("client", Team Test), else None. Remembers the choice in STATE."""
    try:
        items = await studio.list_studios()
    except Exception:  # noqa: BLE001
        return None
    clients = []
    for x in items:
        dms = await _studio_datamodels(studio, x["id"])
        if "Server" in dms:
            if x["id"] == studio.studio_id and STATE.get("mode") == "server":
                continue  # the one that just failed
            studio.studio_id = STATE["studio_id"] = x["id"]
            STATE["mode"] = "server"
            return "server"
        if "Client" in dms:
            clients.append(x["id"])
    if clients:
        studio.studio_id = STATE["studio_id"] = clients[0]
        STATE["mode"] = "client"
        print(f"mubit-tester: no Server datamodel in any window; relaying through client {clients[0]}",
              file=sys.stderr)
        return "client"
    return None


@contextlib.asynccontextmanager
async def _harness() -> AsyncIterator[Harness]:
    async with open_studio() as studio:
        yield Harness(studio, relocate=lambda: _relocate(studio), mode=STATE.get("mode") or "server",
                      client_windows=STATE.get("clients"))


def _play():
    from mubit_tester import play  # lazy: heavy imports stay off server start
    return play


def _ai():
    """mubit_tester.ai (multi-player AI) if present, else None."""
    try:
        from mubit_tester import ai
    except ImportError as e:
        print(f"mubit-tester: mubit_tester.ai unavailable ({e}); falling back to mubit_tester.play", file=sys.stderr)
        return None
    return ai


def _root() -> Path:
    return load_settings().base_game_dir


# ---------------------------------------------------------------- core (shared with the CLI)

async def run_playtest(goal: str, steps: int = 20, studio: str | None = None,
                       players: int | None = None, roles: list[str] | None = None,
                       mode: str = "free", squads: int = 1) -> str:
    with _stdout_to_stderr():
        if studio:
            STATE["hint"] = studio
            STATE["studio_id"] = None
        s = load_settings()
        ai = _ai()
        async with open_studio() as st:
            if ai is not None and hasattr(ai, "multi_playtest"):
                h = Harness(st, relocate=lambda: _relocate(st), mode=STATE.get("mode") or "server",
                            client_windows=STATE.get("clients"))
                kw: dict = {"studio": st, "harness": h}
                if mode != "free":
                    kw.update(mode=mode, squads=squads)
                report = await ai.multi_playtest(s, goal, players=players, steps=steps, roles=roles, **kw)
            else:
                if mode != "free":
                    raise ToolError("mode='squads' needs mubit_tester.ai")
                report = await _play().playtest(s, goal, steps, studio=st)
    return format_report(report)


async def run_correct(run_id: str, step: int, note: str, player: str | None = None) -> str:
    with _stdout_to_stderr():
        s = load_settings()
        ai = _ai()
        if ai is not None and hasattr(ai, "correct_step"):
            res = await ai.correct_step(s, run_id, step, note, player=player)
        else:
            res = await _play().correct_step(s, run_id, step, note)
            if player:
                res = {**res, "note": "player ignored: single-player correction"}
    return format_correction(res)


def get_report(run_id: str) -> str:
    with _stdout_to_stderr():
        return format_report(_play().load_report(load_settings(), run_id))


def get_list() -> str:
    with _stdout_to_stderr():
        return format_list(_play().list_reports(load_settings()))


def doctor_text() -> str:
    from forge.cli import cmd_doctor
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        try:
            code = cmd_doctor(None)
        except Exception as e:  # report, don't crash the server
            code = 1
            print(f"doctor failed: {type(e).__name__}: {e}")
    return buf.getvalue().strip() + f"\n\n{'all checks passed' if code == 0 else 'some checks failed'}"


# ================================================================ MCP tools: session

@mcp.tool()
async def status() -> str:
    """One-glance health: Mubit key, selected Studio, play state/datamodels, and whether the in-game
    ForgeTest harness answers (with its player count)."""
    with _tool_errors():
        s = load_settings()
        lines = ["## mubit-tester status",
                 f"- mubit: {'key set' if s.mubit_api_key else 'MUBIT_API_KEY missing (AI tools will fail)'} "
                 f"({s.provider} via {s.base_url}, model {s.model})"]
        try:
            async with open_studio() as st:
                lines.append(f"- studio: `{st.studio_id}` (hint {STATE.get('hint')!r})")
                state = await st.state()
                lines.append(f"- play: {'running' if state.get('playing') else 'stopped'}; "
                             f"datamodels {state.get('datamodels')}")
                if state.get("playing") or STATE.get("mode") == "client":
                    h = Harness(st, relocate=lambda: _relocate(st), mode=STATE.get("mode") or "server",
                                client_windows=STATE.get("clients"))
                    try:
                        ping = await h.call("ping")
                        lines.append(f"- harness: ok via {h.mode} {_cell(ping, 200)}")
                        try:
                            caps = await h.caps()
                            svc = caps.get("services") or {}
                            lines.append("- game services: " + ", ".join(
                                f"{k} {v.get('status')}" for k, v in sorted(svc.items()) if isinstance(v, dict)))
                            tags = caps.get("tags") or {}
                            lines.append(f"- lobby: {tags.get('SquadPad', 0)} SquadPad(s); instances "
                                         f"{caps.get('instanceModels') or []}; catalog {caps.get('catalog') or []}")
                        except HarnessError:
                            lines.append("- game services: unknown (old harness: sync ForgeTest.server.luau)")
                    except HarnessError as e:
                        lines.append(f"- harness: NOT ready ({e})")
                else:
                    lines.append("- harness: needs play (`play_start` or `multiplayer_start`)")
        except Exception as e:  # noqa: BLE001
            lines.append(f"- studio: unavailable ({type(e).__name__}: {e})")
        return "\n".join(lines)


@mcp.tool()
async def studios(select: str | None = None) -> str:
    """List connected Roblox Studio windows (id, name). `select` (id or part of a name) pins which
    one every other tool uses; a name containing `placeId` is the shared Team Create place."""
    with _tool_errors():
        if select:
            STATE["hint"], STATE["studio_id"] = None, None
        async with open_studio(select=False) as st:
            items = await st.list_studios()
            if select:
                hit = next((x for x in items if x["id"] == select), None)
                if hit is None:
                    await st.select(select)
                    hit = next(x for x in items if x["id"] == st.studio_id)
                STATE["studio_id"] = hit["id"]
        rows = [f"| {'*' if x['id'] == STATE.get('studio_id') else ''} | `{x['id']}` | {_cell(x.get('name'), 80)} |"
                for x in items]
        return "\n".join(["| sel | id | name |", "|---|---|---|", *rows]) if rows else "No Studio connected."


@mcp.tool()
async def play_start() -> str:
    """Start a solo playtest (if not already playing) and wait until ForgeTest answers `ping`."""
    with _tool_errors():
        STATE["mode"] = "server"
        async with _harness() as h:
            ping = await h.ensure_ready(timeout=45)
            return f"play running (started now: {h.started_play}). ping: {_cell(ping, 400)}"


@mcp.tool()
async def play_stop() -> str:
    """Stop the playtest and return to Edit (always call this before finishing)."""
    with _tool_errors():
        STATE["mode"], STATE["clients"] = "server", []
        async with open_studio() as st:
            try:
                await st.stop()
                return "stopped; Studio is back in Edit"
            except Exception as e:  # noqa: BLE001  multiplayer server windows: end the test from inside
                try:
                    await st.execute_luau('game:GetService("StudioTestService"):EndTest({}) return "ended"', "Server")
                    return f"start_stop_play failed ({e}); ended the test via StudioTestService:EndTest"
                except Exception as e2:  # noqa: BLE001
                    raise ToolError(f"could not stop: {e}; EndTest also failed: {e2}") from e2


async def _wait_players(st: Any, n: int, timeout: float) -> int:
    """Poll ForgeTest ping on the selected server window until `n` players joined; returns the count."""
    h = Harness(st, timeout=15)
    deadline = time.monotonic() + timeout
    count = 0
    while True:
        try:
            ping = await h.call("ping")
            count = int((ping or {}).get("players") or 0) if isinstance(ping, dict) else 0
        except HarnessError:
            pass
        if count >= n or time.monotonic() >= deadline:
            return count
        await anyio.sleep(MULTIPLAYER_POLL)


@mcp.tool()
async def multiplayer_start(players: int = 2, add: bool = False) -> str:
    """Start a local multiplayer test: 1 server + N (1-8) simulated clients, via
    StudioTestService:ExecuteMultiplayerTestAsync. Finds the spawned Server and Client windows
    (list_roblox_studios), routes every harness call to the Server window and waits until the
    players joined. `add=true` during a running test adds N more clients (StudioTestService:
    AddPlayers). If Studio can't do it from code, returns the manual steps (Test tab → Clients and
    Servers) and how to run a Team Test with real friends."""
    with _tool_errors():
        n = max(1, min(int(players), 8))
        manual = MANUAL_MULTIPLAYER.format(n=n)
        async with open_studio() as st:
            if (await st.state()).get("playing") or (add and STATE.get("clients")):
                if not add:
                    return ("A playtest is already running; `play_stop` first, or "
                            "`multiplayer_start(players=N, add=true)` to add N clients to it.")
                if "Server" not in await _studio_datamodels(st, st.studio_id) and not await _relocate(st):
                    return f"No Server window found to add players to.\n\n{manual}"
                try:
                    out = await st.execute_luau(ADD_PLAYERS_LUAU % n, "Server")
                except Exception as e:  # noqa: BLE001
                    return f"StudioTestService:AddPlayers failed ({e}). Only works in a Clients and Servers test."
                have = await _wait_players(st, 0, 0)
                count = await _wait_players(st, have + n if "added" in str(out) else have, MULTIPLAYER_JOIN_WAIT)
                return f"AddPlayers({n}): {_cell(out, 80)}; {count} player(s) connected now."
            before = {x["id"] for x in await st.list_studios()}
            try:
                out = await st.execute_luau(MULTIPLAYER_LUAU % n, "Edit")
            except Exception as e:  # noqa: BLE001
                return f"Could not start multiplayer from code ({e}).\n\n{manual}"
            if "started" not in str(out):
                return f"Could not start multiplayer from code ({_cell(out, 200)}).\n\n{manual}"
            server: dict | None = None
            clients: list[dict] = []
            deadline = time.monotonic() + MULTIPLAYER_WAIT
            while time.monotonic() < deadline and (server is None or len(clients) < n):
                await anyio.sleep(MULTIPLAYER_POLL)
                try:
                    items = await st.list_studios()
                except Exception:  # noqa: BLE001
                    continue
                for x in sorted(items, key=lambda x: x["id"] in before):  # new windows first
                    if (server and x["id"] == server["id"]) or any(c["id"] == x["id"] for c in clients):
                        continue
                    dms = await _studio_datamodels(st, x["id"])
                    if "Server" in dms and server is None:
                        server = x
                    elif "Client" in dms and x["id"] not in before:
                        clients.append(x)
                if server is not None and not clients and time.monotonic() > deadline - MULTIPLAYER_WAIT / 2:
                    break  # client windows may not be listed separately; the player count decides
            if server is None:
                return f"Started the test but no Server datamodel showed up within {MULTIPLAYER_WAIT:.0f}s.\n\n{manual}"
            st.studio_id = STATE["studio_id"] = server["id"]
            STATE["mode"] = "server"
            STATE["clients"] = [c["id"] for c in clients]
            count = await _wait_players(st, n, MULTIPLAYER_JOIN_WAIT)
            rows = [f"| server | `{server['id']}` | {_cell(server.get('name'), 60)} |"] + \
                [f"| client | `{c['id']}` | {_cell(c.get('name'), 60)} |" for c in clients]
            head = (f"Multiplayer test started: {count}/{n} player(s) joined; harness calls go to the server "
                    f"window `{server['id']}`.")
            if count < n:
                head += " Not everyone joined yet: check `players` in a moment (the harness needs ForgeTest synced)."
            return "\n".join([head, "", "| role | id | name |", "|---|---|---|", *rows])


@mcp.tool()
async def sync(prune: bool = False) -> str:
    """Push game/ into the selected Studio (luau-compile check first; stops play). No prune by default."""
    with _tool_errors():
        from forge.watch import sync_once
        return str(await sync_once(load_settings(), _root(), STATE.get("hint"), prune=prune)).strip()


@mcp.tool()
async def preview(screenshot: bool = False) -> str:
    """Sync and build the map in Edit (no Play needed); optionally save a screenshot."""
    with _tool_errors():
        from forge.preview import preview as do_preview
        s = load_settings()
        shot = s.runs_dir / "screens" / f"preview-{int(time.time())}.png" if screenshot else None
        return await do_preview(s, _root(), STATE.get("hint"), shot=shot)


# ================================================================ MCP tools: world

@mcp.tool()
async def players(instance_id: str | None = None, squad_id: str | None = None) -> str:
    """Every connected player: helmet, name, userId, squad, mission instance, position, health,
    Heat, tool, carrying, downed, attrs. `instance_id` / `squad_id` keep only that instance/squad."""
    with _tool_errors():
        async with _harness() as h:
            return format_players(await h.players(instance_id, squad_id))


@mcp.tool()
async def observe(player: str, radius: float = 120, max: int = 12, instance_id: str | None = None) -> str:
    """What one player sees: self, nearby world things, prompts and their HUD (from their client).
    Things inside OTHER mission instances are hidden (the player's own instance, or `instance_id`)."""
    with _tool_errors():
        async with _harness() as h:
            return _j(await h.observe(player, radius, max, instance_id), f"observe {player}")


@mcp.tool()
async def query(tag: str | None = None, near: str | list[float] | None = None, radius: float | None = None,
                attrs: list[str] | None = None, limit: int = 25, instance_id: str | None = None,
                where: dict | None = None) -> str:
    """Find instances by CollectionService tag, optionally near a position [x,y,z] or a player
    (name/userId/helmet), returning path, name, tags, pos, dist, instanceId and the requested attrs.
    `instance_id` keeps only things inside that mission instance; `where` {attr: value} filters."""
    with _tool_errors():
        async with _harness() as h:
            res = await h.query(tag=tag, near=near, radius=radius, attrs=attrs, limit=limit,
                                instanceId=instance_id, where=where)
            return _j(res, f"query ({len(res)} hit(s))")


@mcp.tool()
async def inspect(path: str) -> str:
    """Class, name, position, size, attributes, tags and child names of the instance at `path`."""
    with _tool_errors():
        async with _harness() as h:
            return _j(await h.inspect(path), path)


@mcp.tool()
async def counters() -> str:
    """ForgeTelemetry counters (gameplay metrics the server counted)."""
    with _tool_errors():
        async with _harness() as h:
            return _j(await h.counters(), "counters")


@mcp.tool()
async def events(since: float | None = None, limit: int = 60, instance_id: str | None = None,
                 squad_id: str | None = None, kinds: list[str] | None = None) -> str:
    """Server event log since server time `since` (use `now` from a previous call), last `limit`.
    Kinds include players/tools/prompts/tags/attrs/counters plus lobby (joined_pad, left_pad,
    countdown, launched) and mission (mission_started, mission_state, entered_instance, delivered,
    overheated, downed, revived, ragdolled, hose_hit, kinked). `instance_id` / `squad_id` scope it
    to one mission instance / squad; `kinds` filters."""
    with _tool_errors():
        async with _harness() as h:
            res = await h.events(since, instance_id, squad_id, kinds)
        evs = (res or {}).get("events") or []
        out = [f"## Events: {len(evs)} (now={res.get('now')}; pass since={res.get('now')} next time)"]
        for e in evs[-limit:]:
            out.append(f"- t={e.get('t')} **{e.get('kind')}** {_cell(e.get('data'), 200)}" if isinstance(e, dict)
                       else f"- {_cell(e, 200)}")
        return "\n".join(out)


@mcp.tool()
async def errors(reset: bool = False) -> str:
    """ForgeProbe report from the running server: script errors (with traces) and warnings.
    `reset` clears them afterwards so the next check only shows new ones."""
    with _tool_errors():
        async with open_studio() as st:
            rep = await st.probe_report()
            text = format_probe(rep)
            if reset:
                await st.execute_luau('return game:GetService("ServerStorage").ForgeProbe:Invoke("reset")', "Server")
                text += "\n\n(probe reset)"
            return text


@mcp.tool()
async def console(tail: int = 80) -> str:
    """Last `tail` lines of Studio's output console."""
    with _tool_errors():
        async with open_studio() as st:
            lines = str(await st.console()).splitlines()
        return "\n".join(lines[-tail:]) or "(console empty)"


@mcp.tool(structured_output=False)
async def screenshot(camera: list[float] | None = None, look_at: list[float] | None = None) -> list:
    """Capture the Studio viewport (optionally from camera [x,y,z] looking at look_at [x,y,z]).
    Returns the image and its saved path under runs/screens/."""
    with _tool_errors():
        s = load_settings()
        out = s.runs_dir / "screens" / f"shot-{time.strftime('%Y%m%d-%H%M%S')}.png"
        async with open_studio() as st:
            saved = await st.screenshot(out, camera, look_at)
        if not saved:
            return ["screen_capture returned no image"]
        return [f"saved {saved}", Image(path=saved)]


# ================================================================ MCP tools: control

@mcp.tool()
async def act(player: str, action: str, args: dict | None = None) -> str:
    """Make one player do something on their own client. Actions: walk_to {pos|path, timeout?},
    jump, interact {path?}, equip {name|slot}, unequip, use {seconds?, aim?: [x,y,z]|path},
    look_at {pos|path}, say {text}, wait {seconds}, press {path|text} (a real mouse click on one of the
    player's GUI buttons from `observe`'s `ui`; only for a player a Studio window drives; returns whether
    the button fired and what changed on screen). Returns {done, detail}."""
    with _tool_errors():
        async with _harness() as h:
            return _j(await h.act(player, action, **(args or {})))


@mcp.tool()
async def act_all(action: str, args: dict | None = None) -> str:
    """Run the same action on every connected player at once (see `act` for actions)."""
    with _tool_errors():
        async with _harness() as h:
            return _j(await h.act_all(action, **(args or {})), f"{action} x all")


@mcp.tool()
async def teleport(player: str, pos: list[float] | None = None, path: str | None = None,
                   to: str | None = None, offset: list[float] | None = None) -> str:
    """Teleport a player to a position [x,y,z], next to the instance at `path`, or next to another
    player `to` (name/userId/helmet); `offset` [dx,dy,dz] shifts the spot."""
    with _tool_errors():
        if pos is None and not path and not to:
            raise ToolError("give pos, path or to")
        async with _harness() as h:
            args: dict = {"userId": player}
            if pos is not None:
                args["pos"] = pos
            elif path:
                args["path"] = path
            else:
                args["to"] = to
            if offset is not None:
                args["offset"] = offset
            return _j(await h.call("teleport", **args))


def _target(path: str | None, near: str | list[float] | None, radius: float | None) -> dict:
    if path:
        return {"path": path}
    if near is None:
        raise ToolError("give path, or near (+radius) for the nearest Flammable")
    return {"near": near, **({"radius": radius} if radius is not None else {})}


@mcp.tool()
async def ignite(path: str | None = None, near: str | list[float] | None = None, radius: float | None = None) -> str:
    """Set something on fire: `path`, or the nearest Flammable near a position/player."""
    with _tool_errors():
        async with _harness() as h:
            return _j(await h.call("ignite", **_target(path, near, radius)))


@mcp.tool()
async def extinguish(path: str | None = None, near: str | list[float] | None = None, radius: float | None = None) -> str:
    """Put out a fire: `path`, or the nearest burning thing near a position/player."""
    with _tool_errors():
        async with _harness() as h:
            return _j(await h.call("extinguish", **_target(path, near, radius)))


@mcp.tool()
async def set_attr(path: str, key: str, value: Any) -> str:
    """Set attribute `key` on the instance at `path` (server side)."""
    with _tool_errors():
        async with _harness() as h:
            return _j(await h.call("set_attr", path=path, key=key, value=value))


@mcp.tool()
async def config(module: str, key: str, value: Any = None) -> str:
    """Read a Config value, or live-tune it when `value` is given (Config.Set, this session only)."""
    with _tool_errors():
        args: dict = {"module": module, "key": key}
        if value is not None:
            args["value"] = value
        async with _harness() as h:
            return _j(await h.call("config", **args))


@mcp.tool()
async def reset(location: str | None = None) -> str:
    """Rebuild one map location (or all) and clear the event log."""
    with _tool_errors():
        async with _harness() as h:
            return _j(await h.call("reset", **({"location": location} if location else {})))


@mcp.tool()
async def round(state: str | None = None) -> str:
    """Read the round state, or force it (e.g. Intermission, Active) via MissionService."""
    with _tool_errors():
        async with _harness() as h:
            return _j(await h.call("round", **({"state": state} if state else {})))


# ================================================================ MCP tools: squads / co-op

@mcp.tool()
async def squads(squad_id: str | None = None, pad: int | None = None) -> str:
    """Station lobby: LobbyService status, squads (pad, leader, members, chosen mission, countdown,
    instance), SquadPads (who stands on each), players still in the lobby, enabled missions."""
    with _tool_errors():
        async with _harness() as h:
            return format_squads(await h.squads(squad_id, pad))


@mcp.tool()
async def instances(instance_id: str | None = None) -> str:
    """Running mission instances (parallel squads): id, mission, squad, state, seconds left, fires
    burning, rescues by state, players."""
    with _tool_errors():
        async with _harness() as h:
            return format_instances(await h.instances(instance_id))


@mcp.tool()
async def queue(player: str, pad: int = 1, walk: bool = False, join: bool | None = None) -> str:
    """Put a player onto squad pad `pad` (teleport, or walk there with walk=true) and wait for
    their SquadId; if the pad doesn't sign them up, LobbyService:Join is called (join=false: never,
    join=true: at once)."""
    with _tool_errors():
        async with _harness() as h:
            args: dict = {"userId": player, "pad": pad}
            if walk:
                args["walk"] = True
            if join is not None:
                args["join"] = join
            return _j(await h.call("queue", **args), f"queue {player} -> pad {pad}")


@mcp.tool()
async def launch(pad: int | None = None, squad_id: str | None = None, mission_id: str | None = None) -> str:
    """Launch a squad now (skip the board and countdown): LobbyService:Launch(squadId, missionId) for
    the squad on `pad` or `squad_id`; waits until its members are in the mission instance."""
    with _tool_errors():
        if pad is None and not squad_id:
            raise ToolError("give pad or squad_id")
        async with _harness() as h:
            return _j(await h.launch(pad=pad, squad_id=squad_id, mission_id=mission_id, wait=20), "launch")


@mcp.tool()
async def mission_start(mission_id: str | None = None, players: list[str] | None = None,
                        seconds: float | None = None) -> str:
    """Start a mission instance directly: MissionService:StartMission(players, missionId, seconds?)
    (players: names/UserIds/helmets, default everyone; mission default: first enabled in the
    catalog). Returns the instanceId and who is in it."""
    with _tool_errors():
        async with _harness() as h:
            args: dict = {"wait": 15}
            if mission_id:
                args["missionId"] = mission_id
            if players:
                args["players"] = players
            if seconds is not None:
                args["seconds"] = seconds
            return _j(await h.call("mission_start", **args), "mission_start")


@mcp.tool()
async def mission_end(instance_id: str, reason: str = "forced") -> str:
    """End one mission instance: MissionService:EndMission(instanceId, reason) ("forced", "time",
    "allOut"); waits for the results state / the squad back in the lobby."""
    with _tool_errors():
        async with _harness() as h:
            return _j(await h.mission_end(instance_id, reason, wait=10), "mission_end")


# ================================================================ MCP tools: testing

@mcp.tool()
async def scenario_run(scenario: str) -> str:
    """Run a scripted scenario (no LLM): a name from scenarios/ (see scenario_list), a file path,
    or inline JSON {"name", "steps": [...]}. Starts play if needed (and stops it again if it did).
    Returns PASS/FAIL, a step table and the events logged meanwhile."""
    with _tool_errors():
        from mubit_tester.scenario import format_result, load_scenario, run_scenario
        sc = load_scenario(scenario, load_settings().repo_root)
        async with _harness() as h:
            await h.ensure_ready(timeout=45)
            try:
                res = await run_scenario(h, sc)
            finally:
                if h.started_play:
                    with contextlib.suppress(Exception):
                        await h.studio.stop()
        return format_result(res)


@mcp.tool()
def scenario_list() -> str:
    """List scenarios in scenarios/*.json (name, steps, description)."""
    with _tool_errors():
        from mubit_tester.scenario import list_scenarios
        items = list_scenarios(load_settings().repo_root)
        if not items:
            return "No scenarios in scenarios/."
        return "\n".join(["| name | steps | requires | description |", "|---|---|---|---|"] + [
            f"| {x['name']} | {x.get('steps', '?')} | "
            f"{_cell(', '.join(r if isinstance(r, str) else str(r.get('reason') or 'condition') for r in x.get('requires') or []), 60)} | "
            f"{_cell(x.get('description') or x.get('error'), 120)} |"
            for x in items])


# ================================================================ MCP tools: AI (Mubit)

@mcp.tool()
async def playtest(goal: str, players: int | None = None, steps: int = 20, roles: list[str] | None = None,
                   mode: str = "free", squads: int = 1) -> str:
    """AI-playtest toward a concrete goal: one Mubit `player` agent per connected player (roles like
    "nozzle", "rescuer", "chaos"), acting each tick, then a `judge`. Returns goal met, bugs (#i),
    a step table and the run_id. Start multiplayer first for several players.
    mode="squads": the full loop lobby -> pad -> countdown -> mission -> results with the players
    split into `squads` squads acting concurrently toward a co-op goal (the harness nudges stuck
    squads); the report adds phases, instances and per-player blame/credit from the judge."""
    with _tool_errors():
        if mode not in ("free", "squads"):
            raise ToolError("mode must be 'free' or 'squads'")
        return await run_playtest(goal, steps, None, players, roles, mode, squads)


@mcp.tool()
async def explore(minutes: float = 3, players: int | None = None) -> str:
    """Unscripted AI bug hunt (Mubit `explorer` role) for `minutes`; returns the bugs it found."""
    with _tool_errors():
        ai = _ai()
        if ai is None or not hasattr(ai, "explore"):
            raise ToolError("explore needs mubit_tester.ai, which isn't available")
        async with open_studio() as st:
            report = await ai.explore(load_settings(), minutes=minutes, players=players, studio=st)
        return format_report(report)


@mcp.tool()
async def playtest_correct(run_id: str, step: int, note: str, player: str | None = None) -> str:
    """Correct an AI player's choice at one step ("it should have ..."): a new call in the same
    Mubit task, i.e. a training example. `player` picks whose step in a multiplayer run."""
    with _tool_errors():
        return await run_correct(run_id, step, note, player)


@mcp.tool()
async def suggest_fix(run_id: str, bug: int = 0) -> str:
    """Critic + fixer (Mubit) propose a code fix for bug #`bug` of a run: file, problem, patch preview."""
    with _tool_errors():
        ai = _ai()
        if ai is None or not hasattr(ai, "suggest_fix"):
            raise ToolError("suggest_fix needs mubit_tester.ai, which isn't available")
        res = await ai.suggest_fix(load_settings(), run_id, bug)
        out = [f"## Suggested fix: `{run_id}` bug #{bug}", "",
               f"**File:** `{res.get('path', '?')}`", f"**Problem:** {res.get('problem', '')}", ""]
        if res.get("patch_preview"):
            out += ["```", str(res["patch_preview"])[:MAX_TEXT], "```"]
        extra = {k: v for k, v in res.items() if k not in ("path", "problem", "patch_preview")}
        if extra:
            out.append(f"\n{_cell(extra, 400)}")
        return "\n".join(out)


@mcp.tool()
def report(run_id: str) -> str:
    """Show the saved report of a past AI run as markdown."""
    with _tool_errors():
        return get_report(run_id)


@mcp.tool()
def reports() -> str:
    """List past AI runs (run_id, goal met, bugs, steps, goal), newest first."""
    with _tool_errors():
        return get_list()


TOOL_NAMES = (
    "status", "studios", "play_start", "play_stop", "multiplayer_start", "sync", "preview",
    "players", "observe", "query", "inspect", "counters", "events", "errors", "console", "screenshot",
    "act", "act_all", "teleport", "ignite", "extinguish", "set_attr", "config", "reset", "round",
    "squads", "instances", "queue", "launch", "mission_start", "mission_end",
    "scenario_run", "scenario_list",
    "playtest", "explore", "playtest_correct", "suggest_fix", "report", "reports",
)


def main() -> None:
    mcp.run("stdio")


if __name__ == "__main__":
    main()
