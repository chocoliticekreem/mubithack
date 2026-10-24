"""`forge mcp`: the `mubit-tester` stdio MCP server (contract: docs/TESTER.md).

One shot: test_feature (sync, play, plan, run, errors, screenshot, stop -> verdict first),
         diff_since_last_run, test_runs, bisect_versions, watch_errors, swarm.
Session: status, studios, play_start, play_stop, multiplayer_start, sync, preview.
World:   players, observe, query, inspect, counters, events, errors, console, screenshot.
Control: act, act_all, teleport, ignite, extinguish, set_attr, config, reset, round.
Squads:  squads, instances, queue, launch, mission_start, mission_end (lobby, pads, mission instances).
Testing: scenario_run, scenario_list.
AI:      playtest, qa_test, explore, playtest_correct, suggest_fix, report, reports (every LLM call via Mubit).

Extensions: other modules add tools with `register(mcp)` (see `EXTENSIONS` / `load_extensions`),
e.g. `mubit_tester.studio_bridge.register(mcp)` for the Studio plugin bridge. They may use the
helpers here (`open_studio`, `harness_for`, `progress_reporter`, `tool_errors`).

Multiplayer routing: harness calls run in the Server datamodel of the selected Studio window. A
"Clients and Servers" test opens separate Server/Client windows; `multiplayer_start` picks the
server window, and if a call still lands on a window without a Server datamodel `_relocate` finds
the one that has it. In a Team Test with real friends the server is in the cloud, so calls are
relayed from a Client datamodel (Harness mode "client").

stdout is the MCP wire. Everything else goes to stderr: tool bodies run under
`redirect_stdout(sys.stderr)` so progress prints never corrupt the protocol stream. (The mcp SDK
also points fd 1 at stderr while serving, which covers subprocesses.)

One StudioMCP session lives as long as the server (`_lifespan` starts an owner task that holds
`async with Studio()`; about 67 ms per call instead of about 220 ms for a fresh connection). Every
tool borrows it through `open_studio`. The owner task enters and exits the session, so no task-group
scope crosses request tasks. The Studio object also keeps its sync state (incremental pushes, the
file server) between calls. Outside a running server (tests, the `forge test` CLI mirror)
`open_studio` falls back to one connection per call. The chosen Studio (by `studios(select=...)` or
`multiplayer_start`) is remembered in `STATE` for the life of the server.
"""

from __future__ import annotations

import builtins
import contextlib
import importlib
import io
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, AsyncIterator

import anyio
from mcp.server.mcpserver import Context, MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.server.mcpserver.utilities.types import Image

from forge.config import load_settings
from mubit_tester.harness import Harness, HarnessError

INSTRUCTIONS = (
    "mubit-tester drives the Roblox game open in Studio through an in-game harness (ForgeTest) that "
    "controls EVERY player and knows the game's tags and attributes. To check that a feature works, "
    "call test_feature(description) first: it syncs, plays, plans (smoke + matching scenarios + the "
    "game's executable checks + an AI playtest), runs, collects errors and a screenshot, stops play and "
    "returns a verdict (PASS / FAIL / ERRORS / INCONCLUSIVE) with the next step. After a fix run it "
    "again and diff_since_last_run; bisect_versions finds the Forge game version that broke a check. "
    "For hands-on work: sync -> play_start (or multiplayer_start) -> players/observe/query/events to "
    "look, act/act_all/teleport/ignite/... to poke, watch_errors while poking -> play_stop. AI tools "
    "(playtest, explore, suggest_fix, playtest_correct) call Mubit; playtest_correct turns a wrong AI "
    "choice into a Mubit training example. Players are addressed by name, UserId or helmet '1'..'8'. "
    "Multiplayer: multiplayer_start(players=N), then squads/queue/launch/instances/mission_start/"
    "mission_end, instance_id on players/observe/query/events. Always end with play_stop."
)

# ---------------------------------------------------------------- the persistent Studio session

_SHARED: dict[str, Any] = {"tg": None, "studio": None}
_SHARED_LOCK = anyio.Lock()


@contextlib.asynccontextmanager
async def _lifespan(_server: Any) -> AsyncIterator[dict]:
    """While the server runs: a task group that owns the shared Studio session (started lazily)."""
    async with anyio.create_task_group() as tg:
        _SHARED["tg"] = tg
        try:
            yield {}
        finally:
            _SHARED["tg"] = _SHARED["studio"] = None
            tg.cancel_scope.cancel()


async def _studio_owner(*, task_status: Any = anyio.TASK_STATUS_IGNORED) -> None:
    from forge.studio import Studio
    try:
        async with Studio(load_settings()) as st:
            _SHARED["studio"] = st
            task_status.started(st)
            await anyio.sleep_forever()
    finally:
        _SHARED["studio"] = None


async def shared_studio() -> Any | None:
    """The server-lifetime Studio, connecting on first use; None outside a running server or when
    StudioMCP can't start (callers then open their own connection, which reports the error)."""
    tg = _SHARED["tg"]
    if tg is None:
        return None
    if _SHARED["studio"] is not None:
        return _SHARED["studio"]
    async with _SHARED_LOCK:
        if _SHARED["studio"] is None:
            try:
                return await tg.start(_studio_owner)
            except Exception as e:  # noqa: BLE001
                print(f"mubit-tester: shared StudioMCP session failed to start: {e}", file=sys.stderr)
                return None
        return _SHARED["studio"]


mcp = MCPServer("mubit-tester", instructions=INSTRUCTIONS, lifespan=_lifespan)

STATE: dict[str, Any] = {"studio_id": None, "hint": os.environ.get("FORGE_STUDIO") or None,
                         "mode": "server", "clients": [], "pinned": None, "server_window": None}
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
    """The corrected call went to the same Mubit task as the call it corrects: `player` for a
    playtest step, `explorer`, or `test_planner` / `step_judge` / `visual_judge` for a QA protocol
    run (res["role"]). Name that task so the user rates the right one."""
    role = res.get("role") or "player"
    what = {"test_planner": "the QA plan", "step_judge": f"step {res.get('step')}'s judgement",
            "visual_judge": "the visual review"}.get(role, f"step {res.get('step')}")
    rid = res.get("request_id")
    return "\n".join([
        f"## Correction recorded in the `{role}` task: `{res.get('run_id')}` {what}"
        + (f" (player {res['player']})" if res.get("player") else ""), "",
        f"**Before:** {_cell(res.get('before'), 300)}",
        f"**After:** {_cell(res.get('after'), 300)}", "",
        f"Mubit request id: `{rid or '-'}`: a new call in the same `{role}` task, so it is a training "
        "example once rated Good (Mubit console → Requests"
        + (f" → {rid}" if rid else "") + "; a task trains its adapter at 25 kept examples).",
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
    """Connected forge.studio.Studio (the shared session while the server runs); with select,
    pinned to STATE's studio (or the hint)."""
    shared = await shared_studio()
    if shared is not None:
        if select:
            await _pin(shared)
        yield shared
        return
    from forge.studio import Studio
    async with Studio(load_settings()) as studio:
        if select:
            await _pin(studio)
        yield studio


async def _pin(studio: Any) -> None:
    """Point `studio` at STATE's window: the remembered one if still connected, else the pinned hint."""
    sid = STATE.get("studio_id")
    if sid and sid in _known_windows() and any(s.get("id") == sid for s in await studio.list_studios()):
        studio.studio_id = sid
    else:
        # strict: the pinned Studio (FORGE_STUDIO / studios(select)) or an error, never another window
        STATE["pinned"] = STATE["studio_id"] = await studio.select(STATE.get("hint"))
        STATE["mode"], STATE["clients"], STATE["server_window"] = "server", [], None


def _known_windows() -> list[str]:
    """Windows this server may use: the pinned one and the ones its own multiplayer test spawned."""
    ids = [STATE.get("pinned"), STATE.get("server_window"), *(STATE.get("clients") or [])]
    return [i for i in ids if i]


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
    datamodel for relay ("client", Team Test), else None. Remembers the choice in STATE. Only the
    pinned window and the windows our own multiplayer test spawned are candidates: other open Studios
    (other agents' playtests) also have Server datamodels and must never be adopted."""
    try:
        items = await studio.list_studios()
    except Exception:  # noqa: BLE001
        return None
    known = _known_windows() or [studio.studio_id]
    clients = []
    for x in items:
        if x["id"] not in known:
            continue
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


def harness_for(studio: Any, **kw: Any) -> Harness:
    """A Harness on an open studio, routed like every tool's (server window / client relay)."""
    return Harness(studio, relocate=lambda: _relocate(studio), mode=STATE.get("mode") or "server",
                   client_windows=STATE.get("clients"), **kw)


tool_errors = _tool_errors  # public names for extension modules (register(mcp))


def progress_reporter(ctx: Context | None, total: float | None = None):
    """async say(msg): an MCP progress notification (when the client sent a progress token) and a stderr line.
    Never raises: progress is best effort (the CLI mirror has no request context)."""
    n = [0]

    async def say(msg: str) -> None:
        n[0] += 1
        print(f"mubit-tester: {msg}", file=sys.stderr, flush=True)
        if ctx is None:
            return
        with contextlib.suppress(Exception):
            await ctx.report_progress(n[0], total, msg)
    return say


def game_root(game: str | None) -> tuple[Path, str | None]:
    """(folder, slug): None -> the human game/ folder; a Forge slug -> runs/<slug>/game; else a path."""
    s = load_settings()
    if not game:
        return s.base_game_dir, None
    run = s.runs_dir / game / "game"
    if run.is_dir():
        return run, game
    p = Path(game).expanduser()
    if not p.is_absolute():
        p = s.repo_root / p
    if p.is_dir():
        slug = p.parent.name if p.name == "game" and p.parent.parent == s.runs_dir else None
        return p, slug
    have = ", ".join(sorted(d.parent.name for d in s.runs_dir.glob("*/game"))) or "none"
    raise ToolError(f"no game {game!r}: give a Forge slug (runs/<slug>/game; have: {have}) or a folder")


async def sync_into(studio: Any, root: Path, prune: bool = False, shared_ok: bool = False) -> str:
    """luau-compile check, refuse a shared Team Create place, then push `root` into `studio`.
    Studio.sync keeps one file server per folder and moves to a free port when another agent holds
    the configured one; pushes are incremental against what this session pushed before."""
    from forge import sync as fsync
    from forge.watch import is_shared
    errs = fsync.check(Path(root).resolve())
    if errs:
        raise ToolError("not synced, luau-compile errors:\n" + "\n".join(f"  {p}: {m.strip()}" for p, m in errs[:20]))
    name = next((str(x.get("name", "")) for x in await studio.list_studios() if x.get("id") == studio.studio_id), "")
    if is_shared(name) and not shared_ok:
        raise ToolError(f"'{name}' is a shared Team Create place; syncing would overwrite teammates' scripts. "
                        "Select your own local place with studios(select=...).")
    return str(await studio.sync(Path(root).resolve(), prune=prune)).strip()


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
        if not res.get("role"):  # player / explorer runs: the run's agent role is the task
            with contextlib.suppress(Exception):
                res = {**res, "role": _play().load_report(s, run_id).get("agent_role") or "player"}
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
    """One-glance health, verdict first: Mubit key, selected Studio, play state, whether the in-game
    ForgeTest harness answers, live game services and the next thing to do."""
    with _tool_errors():
        s = load_settings()
        lines = [f"- mubit: {'key set' if s.mubit_api_key else 'MUBIT_API_KEY missing (AI tools will fail)'} "
                 f"({s.provider}, model {s.model})"]
        head, nxt = "NOT READY", ""
        try:
            async with open_studio() as st:
                name = next((x.get("name") for x in await st.list_studios() if x.get("id") == st.studio_id), "?")
                lines.append(f"- studio: {name} `{st.studio_id}` (hint {STATE.get('hint')!r})")
                state = await st.state()
                lines.append(f"- play: {'running' if state.get('playing') else 'stopped'}; "
                             f"datamodels {state.get('datamodels')}")
                if state.get("playing") or STATE.get("mode") == "client":
                    h = harness_for(st)
                    try:
                        ping = await h.call("ping")
                        n = ping.get("players", "?") if isinstance(ping, dict) else "?"
                        head = f"READY: playing, harness ok ({n} player(s))"
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
                        head = "NOT READY: playing but the harness doesn't answer"
                        nxt = "`sync` (ForgeTest missing?) then `play_start`"
                        lines.append(f"- harness: NOT ready ({e})")
                else:
                    head = f"IDLE: {name} connected, not playing"
                    nxt = "`test_feature(description)`, or `play_start` for hands-on work"
                    lines.append("- harness: needs play")
        except Exception as e:  # noqa: BLE001
            head = "NO STUDIO"
            nxt = "open your place in Roblox Studio with Enable Studio as MCP server on, then `studios`"
            lines.append(f"- studio: unavailable ({type(e).__name__}: {e})")
        if not s.mubit_api_key:
            nxt = (nxt + "; " if nxt else "") + "set MUBIT_API_KEY for AI tools"
        return "\n".join([f"## {head}"] + ([f"**Next:** {nxt}"] if nxt else []) + lines)


@mcp.tool()
async def studios(select: str | None = None) -> str:
    """List connected Roblox Studio windows (id, name); `*` marks the one tools use. `select` (id or
    part of a name) pins it. A name containing `placeId` is a shared Team Create place: never sync
    into it."""
    with _tool_errors():
        async with open_studio(select=False) as st:
            if select:
                sid = await st.select(select)  # strict: an ambiguous name is an error, not a guess
                STATE.update(hint=sid, pinned=sid, studio_id=sid, mode="server", clients=[], server_window=None)
            items = await st.list_studios()
            chosen = STATE.get("studio_id")
            if not chosen and items:
                with contextlib.suppress(Exception):
                    chosen = await st.select(STATE.get("hint"))
        rows = [f"| {'*' if x['id'] == chosen else ''} | `{x['id']}` | {_cell(x.get('name'), 80)}"
                f"{' (shared)' if 'placeId' in str(x.get('name')) else ''} |" for x in items]
        if not rows:
            return ("No Studio connected: open a place and turn on Assistant → ⋯ → Manage MCP Servers → "
                    "Enable Studio as MCP server.")
        sel = next((x.get("name") for x in items if x["id"] == chosen), None)
        return "\n".join([f"{len(rows)} Studio window(s); tools use: {sel or 'none matched'}", "",
                          "| sel | id | name |", "|---|---|---|", *rows])


@mcp.tool()
async def play_start(timeout: float = 90) -> str:
    """Start a solo playtest (if not already playing) and wait until ForgeTest answers `ping`
    (up to `timeout` seconds)."""
    with _tool_errors():
        STATE["mode"] = "server"
        t0 = time.monotonic()
        async with _harness() as h:
            try:
                ping = await h.ensure_ready(timeout=timeout)
            except Exception as e:  # noqa: BLE001
                raise ToolError(
                    f"play did not become ready in {time.monotonic() - t0:.0f}s: {e}. Check `status` (right "
                    "window?), a modal dialog open in Studio, or ForgeTest missing (`sync`). Many Studios at "
                    "once start play slowly: retry with a larger timeout.") from e
            return (f"play running ({'started now' if h.started_play else 'already running'}, "
                    f"{time.monotonic() - t0:.0f}s). ping: {_cell(ping, 300)}")


@mcp.tool()
async def play_stop() -> str:
    """Stop the playtest and return to Edit (always call this before finishing)."""
    with _tool_errors():
        async with open_studio() as st:
            STATE["mode"], STATE["clients"], STATE["server_window"] = "server", [], None
            if STATE.get("pinned"):
                STATE["studio_id"] = STATE["pinned"]
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
            pinned = st.studio_id
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
                    if x["id"] in before and x["id"] != pinned:
                        continue  # an older window is someone else's Studio, even when it is playing
                    dms = await _studio_datamodels(st, x["id"])
                    if "Server" in dms and server is None:
                        server = x
                    elif "Client" in dms and x["id"] not in before:
                        clients.append(x)
                if server is not None and not clients and time.monotonic() > deadline - MULTIPLAYER_WAIT / 2:
                    break  # client windows may not be listed separately; the player count decides
            if server is None:
                return f"Started the test but no Server datamodel showed up within {MULTIPLAYER_WAIT:.0f}s.\n\n{manual}"
            st.studio_id = STATE["studio_id"] = STATE["server_window"] = server["id"]
            STATE["pinned"] = STATE.get("pinned") or pinned
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
async def sync(game: str | None = None, prune: bool = False) -> str:
    """Push a game's Luau into the selected Studio (luau-compile check first; stops play). `game`:
    omit for the human game in game/, a Forge slug for runs/<slug>/game, or a folder. `prune`
    deletes synced scripts that no longer exist on disk. Refuses shared Team Create places."""
    with _tool_errors():
        root, _ = game_root(game)
        t0 = time.monotonic()
        async with open_studio() as st:
            out = await sync_into(st, root, prune=prune)
        return f"synced `{root}` in {time.monotonic() - t0:.0f}s: {out}"


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


def format_query(res: Any, attrs: list[str] | None = None) -> str:
    if not isinstance(res, list):
        return _j(res, "query")
    if not res:
        return "query: 0 hits"
    keys = list(attrs or [])
    out = [f"## query: {len(res)} hit(s)", "", "| name | dist | pos | instance | " + " | ".join(keys) + (" |" if keys else "") + " path |",
           "|---|---|---|---|" + "---|" * len(keys) + "---|"]
    for r in res:
        if not isinstance(r, dict):
            out.append(f"| {_cell(r, 80)} |")
            continue
        pos = r.get("pos")
        if isinstance(pos, list):
            pos = [builtins.round(x, 1) if isinstance(x, (int, float)) else x for x in pos]
        dist = r.get("dist")
        dist = builtins.round(dist, 1) if isinstance(dist, (int, float)) else dist
        a = r.get("attrs") or {}
        vals = [_cell(a.get(k, r.get(k)), 24) for k in keys]
        out.append(f"| {_cell(r.get('name'), 24)} | {_cell(dist, 8)} | {_cell(pos, 26)} | {_cell(r.get('instanceId'), 10)} | "
                   + "".join(f"{v} | " for v in vals) + f"{_cell(r.get('path'), 90)} |")
    return "\n".join(out)


@mcp.tool()
async def query(tag: str | None = None, near: str | list[float] | None = None, radius: float | None = None,
                attrs: list[str] | None = None, limit: int = 25, instance_id: str | None = None,
                where: dict | None = None) -> str:
    """Find instances by CollectionService tag, optionally near a position [x,y,z] or a player
    (name/userId/helmet). Table of name, dist, pos, instance, the requested `attrs`, path (nearest
    first when `near`). `instance_id` keeps only things inside that mission instance; `where`
    {attr: value} filters."""
    with _tool_errors():
        async with _harness() as h:
            res = await h.query(tag=tag, near=near, radius=radius, attrs=attrs, limit=limit,
                                instanceId=instance_id, where=where)
            return format_query(res, attrs)


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


async def _focus_camera(focus: str, distance: float = 22) -> tuple[list[float], list[float]]:
    """Camera/look_at framing a player (name/userId/helmet) or an instance path, from above-behind."""
    async with _harness() as h:
        pos = None
        with contextlib.suppress(HarnessError):
            for p in await h.players():
                if focus in (str(p.get("name")), str(p.get("userId")), str(p.get("helmet"))):
                    pos = p.get("pos")
                    break
        if pos is None:
            info = await h.inspect(focus)
            pos = info.get("pos") or info.get("position") if isinstance(info, dict) else None
    if not (isinstance(pos, list) and len(pos) == 3):
        raise ToolError(f"can't find a position for {focus!r} (a player or an instance path while playing)")
    d = distance
    return [pos[0] + d * 0.7, pos[1] + d * 0.6, pos[2] + d * 0.7], list(pos)


@mcp.tool(structured_output=False)
async def screenshot(focus: str | None = None, camera: list[float] | None = None,
                     look_at: list[float] | None = None, distance: float = 22) -> list:
    """Capture the Studio viewport: the image itself plus its saved path (runs/screens/). `focus`
    frames a player (name/userId/helmet) or an instance path from `distance` studs (needs play);
    or give camera [x,y,z] + look_at [x,y,z]; or neither for the current view."""
    with _tool_errors():
        s = load_settings()
        if focus:
            camera, look_at = await _focus_camera(focus, distance)
        label = "".join(c if c.isalnum() else "-" for c in (focus or "view"))[:24]
        out = s.runs_dir / "screens" / f"shot-{time.strftime('%Y%m%d-%H%M%S')}-{label}.png"
        async with open_studio() as st:
            saved = await st.screenshot(out, camera, look_at)
        if not saved:
            raise ToolError("screen_capture returned no image (is the Studio window minimised or covered?)")
        return [f"saved `{saved}`" + (f" (focus {focus})" if focus else ""), Image(path=saved)]


# ================================================================ MCP tools: control

def format_act(res: Any) -> str:
    if isinstance(res, dict) and "done" in res:
        extra = {k: v for k, v in res.items() if k not in ("done", "detail")}
        return (f"{'done' if res.get('done') else 'NOT done'}: {_cell(res.get('detail'), 600)}"
                + (f"\n{_cell(extra, 800)}" if extra else ""))
    return _j(res)


@mcp.tool()
async def act(player: str, action: str, args: dict | None = None) -> str:
    """Make one player do something on their own client. Actions: walk_to {pos|path, timeout?},
    jump, interact {path?}, equip {name|slot}, unequip, use {seconds?, aim?: [x,y,z]|path},
    look_at {pos|path}, say {text}, wait {seconds}; macros with an `effect` diff (leaderstats, attributes,
    counters, HUD text, events): go_touch {path}, go_use {path}, chase {path, touches<=5},
    repeat {action, args, times<=5}; press {path|text} (a real mouse click on one of the
    player's GUI buttons from `observe`'s `ui`; only for a player a Studio window drives; returns whether
    the button fired and what changed on screen). Any action takes `target_player` to aim at another
    player. Returns "done: <detail>" or "NOT done: <why>"."""
    with _tool_errors():
        async with _harness() as h:
            return format_act(await h.act(player, action, **(args or {})))


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


def format_qa(rep: dict, shots: list[dict]) -> str:
    """Summary first: verdict, acceptance counts, bugs, then key screenshots and where it's saved."""
    met = rep.get("goal_met")
    head = "PASS" if met is True else "FAIL" if met is False else "INCONCLUSIVE"
    acc = rep.get("acceptance") or []
    counts: dict[str, int] = {}
    for a in acc:
        counts[str(a.get("status"))] = counts.get(str(a.get("status")), 0) + 1
    out = [f"## QA {head}: {_cell(rep.get('goal'), 120)}",
           f"{_cell(rep.get('summary'), 600)}",
           f"Run `{rep.get('run_id')}`, {len(rep.get('steps') or [])} step(s), "
           f"{((rep.get('timings') or {}).get('total_ms') or 0) / 1000:.0f}s; acceptance: "
           + (", ".join(f"{v} {k}" for k, v in sorted(counts.items())) or "none"), ""]
    bugs = rep.get("bugs") or []
    out.append(f"### Bugs ({len(bugs)})")
    for b in bugs[:8]:
        out.append(f"- **{b.get('id')}. [{b.get('severity')}] {_cell(b.get('title'), 100)}**: "
                   f"expected {_cell(b.get('expected'), 100)}; actual {_cell(b.get('actual'), 100)} "
                   f"(fix target `{b.get('fix_target') or '?'}`)")
    if not bugs:
        out.append("- none found")
    fails = [a for a in acc if a.get("status") == "fail"]
    if fails:
        out += ["", "### Failing acceptance items"] + [f"- {_cell(a.get('text'), 160)} (steps {a.get('steps')})" for a in fails[:8]]
    if rep.get("errors"):
        out += ["", f"Run errors: {_cell(rep['errors'], 300)}"]
    out += ["", "### Key screenshots"] + ([f"- step {c['n']}: `{c['path']}` ({_cell(c.get('what'), 80)})" for c in shots]
                                         or ["- none"])
    out += ["", f"Full report: `{Path(str(rep.get('test_dir', ''))) / 'report.md'}`",
            f"Correct a judgement: `playtest_correct(run_id=\"{rep.get('run_id')}\", step=<n>, note=...)` "
            "(step 0 = the plan, n = step n's judge, -1 = the visual review)."]
    return "\n".join(out)


@mcp.tool(structured_output=False)
async def qa_test(focus: str | None = None, steps: int = 12, game: str | None = None,
                  ctx: Context | None = None) -> list:
    """QA protocol tester (Mubit, with vision): understand the game, plan up to `steps` test steps
    (optionally around `focus`, e.g. "the hydrant refill"), execute them with screenshots, investigate
    mismatches, and report acceptance items and bugs. Returns the summary first, bugs, the key
    screenshot paths (and the first two images), and the report path. `game`: a Forge slug or omit
    for game/. Stops play it started. Several minutes; slower and deeper than test_feature."""
    with _tool_errors():
        ai = _ai()
        if ai is None or not hasattr(ai, "qa_test"):
            raise ToolError("qa_test needs mubit_tester.ai.qa_test (the QA protocol), which isn't available")
        say = progress_reporter(ctx)
        root, slug = game_root(game)
        await say(f"QA protocol on {slug or root.name}" + (f", focus: {focus}" if focus else ""))
        async with open_studio() as st:
            h = harness_for(st)
            kw: dict = {"game_dir": root, "max_steps": max(1, int(steps)), "studio": st, "harness": h, "stop": True}
            if slug:
                kw["slug"] = slug
            rep = await ai.qa_test(load_settings(), focus, **kw)
        from mubit_tester import protocol
        shots = protocol.pick_key_shots(rep, protocol.KEY_IMAGES)
        await say(f"done: {rep.get('summary', '')[:120]}")
        parts: list = [format_qa(rep, shots)]
        for c in shots[:2]:
            if Path(str(c["path"])).exists():
                parts.append(Image(path=c["path"]))
        return parts


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
    """Correct an AI call at one step ("it should have ..."): a new call in the same Mubit task, i.e.
    a training example once rated Good. Playtest runs: step n of `player` (whose step in a
    multiplayer run). QA protocol runs (qa_test): step 0 = the plan (test_planner), n = step n's
    judge (step_judge), -1 = the visual review (visual_judge). The reply names the task."""
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


# ================================================================ MCP tools: one-shot testing

@mcp.tool(structured_output=False)
async def test_feature(description: str, game: str | None = None, scenarios: list[str] | None = None,
                       checks: bool = True, playtest: bool = True, players: int | None = None,
                       steps: int = 12, sync: bool = True, screenshot: bool = True,
                       ctx: Context | None = None) -> list:
    """Test one feature end to end in a single call and get a verdict: sync the code, start play,
    plan (smoke + the scenarios matching `description` + the game's saved executable checks + an AI
    playtest toward `description`), run it all, read ForgeProbe errors, take a screenshot, stop play.
    Returns the verdict first (PASS / FAIL / ERRORS / INCONCLUSIVE, why, next step), then a result
    table, bugs, errors and the plan; saved under runs/tests/<id>/ for `diff_since_last_run`.
    `game`: a Forge slug (runs/<slug>/game, whose checks run) or omit for game/. `scenarios` replaces
    the automatic pick. `playtest=false` skips the LLM (fast, no Mubit). `players` > 1 starts a
    multiplayer test first. Takes ~1-4 min; progress is streamed."""
    with _tool_errors():
        from mubit_tester import testrun
        if not description.strip():
            raise ToolError("describe the feature, e.g. 'refilling the hose at a hydrant restores water'")
        say = progress_reporter(ctx)
        root, slug = game_root(game)
        settings = load_settings()
        if players and players > 1:
            await say(f"starting a {players}-player test")
            await multiplayer_start(players=players)
        ai = _ai() if playtest else None
        play_mod = None
        if playtest and (ai is None or not hasattr(ai, "multi_playtest")):
            play_mod = _play()
        async with open_studio() as st:
            h = harness_for(st)
            rec = await testrun.run_feature_test(
                settings=settings, description=description, studio=st, harness=h, game_root=root, game=slug,
                ai=ai, play_mod=play_mod,
                do_sync=(lambda: sync_into(st, root)) if sync else None,
                scenarios=scenarios, run_checks=checks, playtest=playtest, players=players, steps=steps,
                screenshot=screenshot, stop=True, progress=say)
        if players and players > 1:
            STATE["mode"], STATE["clients"] = "server", []
        text = testrun.format_record(rec)
        await say(f"done: {rec['verdict'][0]}")
        if rec.get("screenshot") and Path(rec["screenshot"]).exists():
            return [text, Image(path=rec["screenshot"])]
        return [text]


@mcp.tool()
def test_runs(limit: int = 15) -> str:
    """Saved `test_feature` runs, newest first: id, verdict, seconds, description."""
    with _tool_errors():
        from mubit_tester import testrun
        recs = testrun.load_records(load_settings())[::-1][:max(1, limit)]
        if not recs:
            return "No feature tests yet: `test_feature(description)`."
        out = ["| test | verdict | s | game | description |", "|---|---|---|---|---|"]
        for r in recs:
            v = (r.get("verdict") or ["?"])[0]
            out.append(f"| `{r['id']}` | {v} | {r.get('seconds', 0):.0f} | {r.get('game') or ''} | {_cell(r.get('description'), 70)} |")
        return "\n".join(out)


@mcp.tool()
def diff_since_last_run(test_id: str | None = None, against: str | None = None) -> str:
    """What changed between two `test_feature` runs: verdict trend, checks/scenarios/playtest that
    flipped (fixed or regressed), new and vanished script errors and AI-found bugs, and the game
    files that changed in between. Default: the latest run vs the previous run of the same test
    (same game + description); `against` picks the older run explicitly."""
    with _tool_errors():
        from mubit_tester import testrun
        s = load_settings()
        recs = testrun.load_records(s)
        if not recs:
            raise ToolError("no feature tests yet: run `test_feature(description)` twice")
        new = testrun.load_record(s, test_id) if test_id else recs[-1]
        old = testrun.load_record(s, against) if against else testrun.previous_record(recs, new)
        if old is None:
            return f"`{new['id']}` is the only run so far: nothing to compare. Run the test again after a change."
        return testrun.format_diff(testrun.diff(old, new))


def _probe_errors(rep: dict) -> dict[str, dict]:
    out = {}
    for e in rep.get("errors") or []:
        if isinstance(e, dict):
            key = " ".join(str(e.get("message")).split())[:200]
            out[key] = {"count": int(e.get("count") or 1), "script": e.get("script"), "trace": e.get("trace")}
        else:
            out[" ".join(str(e).split())[:200]] = {"count": 1}
    return out


@mcp.tool()
async def watch_errors(seconds: float = 30, poll: float = 3, ctx: Context | None = None) -> str:
    """Watch the running game for NEW script errors for `seconds` (while you or AI players poke
    it): polls ForgeProbe every `poll` s, streams each new error as progress, then returns a summary
    (count first) with traces. Errors already logged before the call don't count. Needs play."""
    with _tool_errors():
        say = progress_reporter(ctx, total=None)
        seconds = max(1.0, min(float(seconds), 600.0))
        async with open_studio() as st:
            base = await st.probe_report()
            if base.get("error") and not base.get("errors"):
                raise ToolError(f"ForgeProbe unavailable ({base['error']}): is play running? `play_start` first")
            seen = {k: v["count"] for k, v in _probe_errors(base).items()}
            new: dict[str, dict] = {}
            t0 = time.monotonic()
            polls = 0
            while time.monotonic() - t0 < seconds:
                await anyio.sleep(max(0.5, poll))
                polls += 1
                rep = await st.probe_report()
                for k, v in _probe_errors(rep).items():
                    grew = v["count"] - seen.get(k, 0)
                    if grew > 0:
                        first = k not in new
                        new.setdefault(k, {**v, "new": 0, "t": builtins.round(time.monotonic() - t0, 1)})
                        new[k]["new"] += grew
                        new[k]["trace"] = v.get("trace") or new[k].get("trace")
                        seen[k] = v["count"]
                        if first:
                            await say(f"new error at +{new[k]['t']}s: {k[:160]}")
        took = time.monotonic() - t0
        if not new:
            return f"## 0 new script errors in {took:.0f}s ({polls} polls)"
        out = [f"## {len(new)} new script error(s) in {took:.0f}s ({sum(v['new'] for v in new.values())} occurrences)", ""]
        for k, v in new.items():
            out.append(f"- **{_cell(k, 300)}** x{v['new']} first at +{v['t']}s ({_cell(v.get('script'), 80)})")
            if v.get("trace"):
                out.append(f"  trace: {_cell(v['trace'], 400)}")
        return "\n".join(out)


async def _run_check_spec(st: Any, h: Harness, slug: str, check: str) -> tuple[bool, str]:
    """A saved executable check id, a scenario name, or an inline Luau check body."""
    from forge import checks as fchecks
    from mubit_tester.scenario import load_scenario, run_scenario
    s = load_settings()
    saved = {c.id: c for c in fchecks.load_checks(s.runs_dir / slug)}
    if check in saved:
        r = await fchecks.run_check(st, saved[check])
        return bool(r.get("ok")), r.get("error") or r.get("detail") or ""
    if "return" in check and "\n" in check or check.strip().startswith("local "):
        r = await fchecks.run_check(st, fchecks.parse(check, "inline"))
        return bool(r.get("ok")), r.get("error") or r.get("detail") or ""
    res = await run_scenario(h, load_scenario(check, s.repo_root))
    if res.get("skipped"):
        return False, f"SKIP {res.get('reason')}"
    bad = next((x.get("detail") for x in res.get("steps") or [] if not x.get("ok")), "")
    return bool(res.get("passed")), bad or f"{len(res.get('steps') or [])} steps ok"


@mcp.tool()
async def bisect_versions(game: str, check: str, good: str | None = None, bad: str | None = None,
                          ctx: Context | None = None) -> str:
    """Find the saved version of a Forge game (forge `versions`: v1, v2, ...) that broke a check, by
    binary search: each tested version is exported to a scratch folder, synced into Studio, played,
    and `check` run (a saved executable check id from runs/<game>/checks, a scenario name, or an
    inline Luau check returning {ok=, detail=}). `good` defaults to v1, `bad` to the latest.
    Returns the first bad version, its message and changed files; then re-syncs the current game.
    Each step is one playtest (~30-60 s); progress is streamed."""
    with _tool_errors():
        from forge.versions import GameVersions
        from mubit_tester import bisect as bs
        root, slug = game_root(game)
        if not slug:
            raise ToolError(f"{game!r} is not a Forge game with versions (runs/<slug>/game)")
        gv = GameVersions(root)
        tags = gv.tags()
        say = progress_reporter(ctx, total=None)

        async def run_at(folder: Path) -> tuple[bool, str]:
            async with open_studio() as st:
                await sync_into(st, folder, prune=True)
                h = harness_for(st)
                try:
                    await h.ensure_ready(timeout=90)
                    return await _run_check_spec(st, h, slug, check)
                finally:
                    with contextlib.suppress(Exception):
                        await st.stop()
        try:
            res = await bs.bisect(root, tags, run_at, good=good, bad=bad, progress=say)
        except bs.BisectError as e:
            raise ToolError(str(e)) from e
        finally:
            with contextlib.suppress(Exception):
                async with open_studio() as st:
                    await sync_into(st, root, prune=True)
                await say("re-synced the current version")
        changed: list[str] = []
        if res.get("first_bad") and res.get("last_good"):
            with contextlib.suppress(Exception):
                changed = gv._git("diff", "--name-only", res["last_good"], res["first_bad"]).splitlines()
        return bs.format_bisect(res, gv.log(), changed)


@mcp.tool()
async def swarm(goal: str | None = None, players: int = 10, minutes: float = 3, testers: int | None = None,
                pool: int = 6, personas: list[str] | None = None, steps: int = 40,
                ctx: Context | None = None) -> str:
    """Swarm test: `players` AI testers (default 10) with different personas (speedrunner, griefer,
    newbie, ui_clicker, economy, physics, coop, accessibility, soak, edge) play the game at once for
    `minutes`, optionally toward `goal`. Real players (solo Play or multiplayer_start) take the
    screen personas; the rest are server-driven bot testers. Mubit calls run in parallel (bounded
    by `pool`); every tester gets its own camera screenshots and a dashboard lane. Returns bugs
    deduplicated across testers and ranked by severity x frequency. `testers` is an alias of
    `players`. Heavy on Studio: run it alone."""
    with _tool_errors():
        from mubit_tester.swarm import MuxHarness, format_swarm, run_swarm
        async with open_studio() as st:
            h = harness_for(st)
            mux = MuxHarness(st, relocate=h.relocate, mode=h.mode, client_windows=h.client_windows)
            rep = await run_swarm(load_settings(), players=testers or players, minutes=minutes, goal=goal,
                                  personas=personas,
                                  pool=pool, max_steps=steps, harness=mux, progress=progress_reporter(ctx))
        return format_swarm(rep)


# ================================================================ extensions

# Modules that add their own tools: each exposes register(mcp). Missing ones are skipped, so a
# lane can ship its module later without touching this file. Extra ones: MUBIT_TESTER_EXTENSIONS
# (comma-separated module names).
EXTENSIONS = ("mubit_tester.studio_bridge",)
LOADED_EXTENSIONS: list[str] = []


def load_extensions(names: tuple[str, ...] | list[str] | None = None) -> list[str]:
    names = list(names if names is not None else EXTENSIONS)
    names += [n.strip() for n in os.environ.get("MUBIT_TESTER_EXTENSIONS", "").split(",") if n.strip()]
    for name in names:
        if name in LOADED_EXTENSIONS:
            continue
        try:
            mod = importlib.import_module(name)
        except ModuleNotFoundError as e:
            if e.name == name:
                continue
            print(f"mubit-tester: extension {name} failed to import: {e}", file=sys.stderr)
            continue
        except Exception as e:  # noqa: BLE001  a broken extension must not take the server down
            print(f"mubit-tester: extension {name} failed to import: {type(e).__name__}: {e}", file=sys.stderr)
            continue
        register = getattr(mod, "register", None)
        if register is None:
            continue
        try:
            register(mcp)
            LOADED_EXTENSIONS.append(name)
        except Exception as e:  # noqa: BLE001
            print(f"mubit-tester: extension {name}.register failed: {type(e).__name__}: {e}", file=sys.stderr)
    return LOADED_EXTENSIONS


TOOL_NAMES = (
    "test_feature", "test_runs", "diff_since_last_run", "watch_errors", "bisect_versions", "swarm",
    "status", "studios", "play_start", "play_stop", "multiplayer_start", "sync", "preview",
    "players", "observe", "query", "inspect", "counters", "events", "errors", "console", "screenshot",
    "act", "act_all", "teleport", "ignite", "extinguish", "set_attr", "config", "reset", "round",
    "squads", "instances", "queue", "launch", "mission_start", "mission_end",
    "scenario_run", "scenario_list",
    "playtest", "qa_test", "explore", "playtest_correct", "suggest_fix", "report", "reports",
)

load_extensions()


def main() -> None:
    mcp.run("stdio")


if __name__ == "__main__":
    main()
