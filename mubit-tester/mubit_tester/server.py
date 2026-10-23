"""`forge mcp`: the `mubit-tester` stdio MCP server (contract: docs/TESTER.md).

Session: status, studios, play_start, play_stop, multiplayer_start, sync, preview.
World:   players, observe, query, inspect, counters, events, errors, console, screenshot.
Control: act, act_all, teleport, ignite, extinguish, set_attr, config, reset, round.
Testing: scenario_run, scenario_list.
AI:      playtest, explore, playtest_correct, suggest_fix, report, reports (every LLM call via Mubit).

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
    "helmet number '1'..'4'."
)

mcp = MCPServer("mubit-tester", instructions=INSTRUCTIONS)

STATE: dict[str, Any] = {"studio_id": None, "hint": os.environ.get("FORGE_STUDIO") or None}
MAX_TEXT = 20000
MULTIPLAYER_WAIT = 90.0
MULTIPLAYER_POLL = 2.0

MULTIPLAYER_LUAU = r"""
local STS = game:GetService("StudioTestService")
local ok, fn = pcall(function() return STS.ExecuteMultiplayerTestAsync end)
if not ok or fn == nil then return "unsupported: StudioTestService.ExecuteMultiplayerTestAsync not available" end
task.spawn(function() STS:ExecuteMultiplayerTestAsync(%d, {}) end)
return "started"
"""

MANUAL_MULTIPLAYER = (
    "Start it by hand: Studio → Test tab → Clients and Servers → set Players to {n} → Start. "
    "Studio opens a server window plus {n} client windows. Then call `studios` to see them and "
    "`studios(select=\"<server id or name>\")` if the server isn't picked automatically, and "
    "`players` to check everyone joined. For real friends: Team Test in the shared place instead."
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
    out.append("")
    if report.get("summary"):
        out += [str(report["summary"]).strip(), ""]

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
    out = [f"## Players ({len(players)})", "", "| helmet | name | userId | pos | health | tool | carrying | downed | attrs |",
           "|---|---|---|---|---|---|---|---|---|"]
    for p in players:
        pos = p.get("pos")
        if isinstance(pos, list):
            pos = [builtins.round(x, 1) if isinstance(x, (int, float)) else x for x in pos]
        hp = f"{p.get('health')}/{p.get('maxHealth')}" if p.get("maxHealth") is not None else p.get("health")
        out.append(f"| {_cell(p.get('helmet'), 6)} | {_cell(p.get('name'), 20)} | {_cell(p.get('userId'), 14)} | "
                   f"{_cell(pos, 30)} | {_cell(hp, 10)} | {_cell(p.get('tool'), 16)} | {_cell(p.get('carrying'), 16)} | "
                   f"{_cell(p.get('downed'), 6)} | {_cell(p.get('attrs'), 80)} |")
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


@contextlib.asynccontextmanager
async def _harness() -> AsyncIterator[Harness]:
    async with open_studio() as studio:
        yield Harness(studio)


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
                       players: int | None = None, roles: list[str] | None = None) -> str:
    with _stdout_to_stderr():
        if studio:
            STATE["hint"] = studio
            STATE["studio_id"] = None
        s = load_settings()
        ai = _ai()
        async with open_studio() as st:
            if ai is not None and hasattr(ai, "multi_playtest"):
                report = await ai.multi_playtest(s, goal, players=players, steps=steps, roles=roles, studio=st)
            else:
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
                if state.get("playing"):
                    try:
                        ping = await Harness(st).call("ping")
                        lines.append(f"- harness: ok {_cell(ping, 200)}")
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
        async with _harness() as h:
            ping = await h.ensure_ready(timeout=45)
            return f"play running (started now: {h.started_play}). ping: {_cell(ping, 400)}"


@mcp.tool()
async def play_stop() -> str:
    """Stop the playtest and return to Edit (always call this before finishing)."""
    with _tool_errors():
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


@mcp.tool()
async def multiplayer_start(players: int = 2) -> str:
    """Start a local multiplayer test (1 server + N simulated clients), best effort via
    StudioTestService; picks the server window for later tools. If Studio can't do it from code,
    returns the manual steps (Test tab → Clients and Servers)."""
    with _tool_errors():
        n = max(1, min(int(players), 8))
        manual = MANUAL_MULTIPLAYER.format(n=n)
        from forge.studio import available_datamodels
        async with open_studio() as st:
            if (await st.state()).get("playing"):
                return "A playtest is already running; `play_stop` first, then multiplayer_start."
            before = {x["id"] for x in await st.list_studios()}
            try:
                out = await st.execute_luau(MULTIPLAYER_LUAU % n, "Edit")
            except Exception as e:  # noqa: BLE001
                return f"Could not start multiplayer from code ({e}).\n\n{manual}"
            if "started" not in str(out):
                return f"Could not start multiplayer from code ({_cell(out, 200)}).\n\n{manual}"
            deadline = time.monotonic() + MULTIPLAYER_WAIT
            while time.monotonic() < deadline:
                await anyio.sleep(MULTIPLAYER_POLL)
                try:
                    items = await st.list_studios()
                except Exception:  # noqa: BLE001
                    continue
                for x in sorted(items, key=lambda x: x["id"] in before):  # new windows first
                    try:
                        state = await st.call("get_studio_state", studio_id=x["id"])
                    except Exception:  # noqa: BLE001
                        continue
                    if "Server" in available_datamodels(state):
                        STATE["studio_id"] = x["id"]
                        return (f"multiplayer test with {n} player(s) started; server window `{x['id']}` "
                                f"({_cell(x.get('name'), 60)}) selected. Call `players` to check everyone joined.")
            return f"Started the test but no Server datamodel showed up within {MULTIPLAYER_WAIT:.0f}s.\n\n{manual}"


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
async def players() -> str:
    """Every connected player: helmet, name, userId, position, health, tool, carrying, downed, attrs."""
    with _tool_errors():
        async with _harness() as h:
            return format_players(await h.players())


@mcp.tool()
async def observe(player: str, radius: float = 120, max: int = 12) -> str:
    """What one player sees: self, nearby world things, prompts and their HUD (from their client)."""
    with _tool_errors():
        async with _harness() as h:
            return _j(await h.observe(player, radius, max), f"observe {player}")


@mcp.tool()
async def query(tag: str | None = None, near: str | list[float] | None = None, radius: float | None = None,
                attrs: list[str] | None = None, limit: int = 25) -> str:
    """Find instances by CollectionService tag, optionally near a position [x,y,z] or a player
    (name/userId/helmet), returning path, name, tags, pos, dist and the requested attrs."""
    with _tool_errors():
        async with _harness() as h:
            res = await h.query(tag=tag, near=near, radius=radius, attrs=attrs, limit=limit)
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
async def events(since: float | None = None, limit: int = 60) -> str:
    """Server event log (players, tools, prompts, Burning/Rescuable tags, key attributes, counters)
    since server time `since` (use `now` from a previous call). Shows the last `limit` events."""
    with _tool_errors():
        async with _harness() as h:
            res = await h.events(since)
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
    look_at {pos|path}, say {text}, wait {seconds}. Returns {done, detail}."""
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
async def teleport(player: str, pos: list[float] | None = None, path: str | None = None) -> str:
    """Teleport a player to a position [x,y,z] or next to the instance at `path`."""
    with _tool_errors():
        if pos is None and not path:
            raise ToolError("give pos or path")
        async with _harness() as h:
            args = {"userId": player, **({"pos": pos} if pos is not None else {"path": path})}
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
        return "\n".join(["| name | steps | description |", "|---|---|---|"] + [
            f"| {x['name']} | {x.get('steps', '?')} | {_cell(x.get('description') or x.get('error'), 120)} |"
            for x in items])


# ================================================================ MCP tools: AI (Mubit)

@mcp.tool()
async def playtest(goal: str, players: int | None = None, steps: int = 20, roles: list[str] | None = None) -> str:
    """AI-playtest toward a concrete goal: one Mubit `player` agent per connected player (roles like
    "nozzle", "rescuer", "chaos"), acting each tick, then a `judge`. Returns goal met, bugs (#i),
    a step table and the run_id. Start multiplayer first for several players."""
    with _tool_errors():
        return await run_playtest(goal, steps, None, players, roles)


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
    "scenario_run", "scenario_list",
    "playtest", "explore", "playtest_correct", "suggest_fix", "report", "reports",
)


def main() -> None:
    mcp.run("stdio")


if __name__ == "__main__":
    main()
