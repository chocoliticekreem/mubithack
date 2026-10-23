"""`forge mcp`: a stdio MCP server that exposes the AI playtester to Claude Code.

Tools: playtest, playtest_correct, playtest_report, playtest_list, forge_doctor.

stdout is the MCP wire. Everything else goes to stderr: tool bodies run under
`redirect_stdout(sys.stderr)` so progress prints from forge.play (or anything it calls) never
corrupt the protocol stream. (The mcp SDK also points fd 1 at stderr while serving, which covers
subprocesses.)
"""

from __future__ import annotations

import contextlib
import io
import json
import sys
from typing import Any

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError

from forge.config import load_settings

INSTRUCTIONS = (
    "Forge AI playtester for the Roblox game open in Studio. After changing gameplay code, call "
    "playtest with a concrete goal (e.g. 'spawn, walk to the fire truck, pick up the hose'). Read the "
    "bugs, fix the code, re-run. If the playtester made a wrong choice at some step, call "
    "playtest_correct with what it should have done: that becomes a Mubit training example."
)

mcp = MCPServer("forge", instructions=INSTRUCTIONS)


# ---------------------------------------------------------------- formatting helpers

def _cell(v: Any, n: int = 60) -> str:
    if v is None:
        return ""
    if not isinstance(v, str):
        v = json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    v = " ".join(v.split()).replace("|", "\\|")
    return v if len(v) <= n else v[: n - 1] + "…"


def _action_and_reason(step: dict) -> tuple[Any, Any]:
    action = step.get("action")
    reason = step.get("reason")
    if isinstance(action, dict):
        action = dict(action)
        reason = reason or action.pop("reason", None)
    return action, reason


def format_report(report: dict) -> str:
    """Concise markdown for a playtest report (see forge.play.playtest)."""
    run_id = report.get("run_id", "?")
    met = report.get("goal_met")
    met_s = "yes" if met is True else "no" if met is False else "unknown"
    out = [f"## Playtest `{run_id}`", "",
           f"**Goal:** {report.get('goal', '')}",
           f"**Goal met:** {met_s}", ""]
    if report.get("summary"):
        out += [str(report["summary"]).strip(), ""]

    bugs = report.get("bugs") or []
    out.append(f"### Bugs ({len(bugs)})")
    if bugs:
        for b in bugs:
            if isinstance(b, dict):
                sev = b.get("severity") or "?"
                out.append(f"- **[{sev}] {b.get('title', '')}**: {_cell(b.get('evidence'), 200)}")
            else:
                out.append(f"- {_cell(b, 200)}")
    else:
        out.append("- none reported")
    out.append("")

    steps = report.get("steps") or []
    if steps:
        out += [f"### Steps ({len(steps)})", "", "| n | action | reason | result |", "|---|---|---|---|"]
        for i, st in enumerate(steps, 1):
            action, reason = _action_and_reason(st)
            out.append(f"| {st.get('n', i)} | {_cell(action, 50)} | {_cell(reason, 50)} | {_cell(st.get('result'), 60)} |")
        out.append("")

    rids = report.get("request_ids")
    if rids is None:
        rids = [s.get("request_id") for s in steps if s.get("request_id")]
    out.append(f"Mubit requests: {len(rids or [])}")
    out.append("")
    out.append(f"To correct a wrong choice: `playtest_correct(run_id=\"{run_id}\", step=<n>, "
               "note=\"what it should have done\")` (CLI: `forge play-correct "
               f"{run_id} <n> \"<note>\"`).")
    return "\n".join(out)


def format_correction(res: dict) -> str:
    return "\n".join([
        f"## Correction recorded: `{res.get('run_id')}` step {res.get('step')}", "",
        f"**Before:** {_cell(res.get('before'), 300)}",
        f"**After:** {_cell(res.get('after'), 300)}", "",
        f"Mubit request id: `{res.get('request_id') or '-'}` (same playtester task, so it counts as a "
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


@contextlib.contextmanager
def _stdout_to_stderr():
    with contextlib.redirect_stdout(sys.stderr):
        yield


@contextlib.contextmanager
def _tool_errors():
    """Surface the real cause to the MCP client (the SDK otherwise hides unexpected exceptions)."""
    try:
        yield
    except ToolError:
        raise
    except Exception as e:
        print(f"forge mcp: {type(e).__name__}: {e}", file=sys.stderr)
        raise ToolError(f"{type(e).__name__}: {e}") from e


def _play():
    from forge import play  # lazy: written in parallel, and heavy imports stay off server start
    return play


# ---------------------------------------------------------------- core (shared with the CLI)

async def run_playtest(goal: str, steps: int = 20, studio: str | None = None) -> str:
    with _stdout_to_stderr():
        report = await _play().playtest(load_settings(), goal, steps, studio)
    return format_report(report)


async def run_correct(run_id: str, step: int, note: str) -> str:
    with _stdout_to_stderr():
        res = await _play().correct_step(load_settings(), run_id, step, note)
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


# ---------------------------------------------------------------- MCP tools

@mcp.tool()
async def playtest(goal: str, steps: int = 20, studio: str | None = None) -> str:
    """AI-playtest the game open in Roblox Studio toward a concrete goal.

    Starts play mode, lets the Mubit-backed playtester act like a player for up to `steps` steps,
    stops play, and returns a markdown report: goal met, summary, bugs, a step table and the run_id.
    `studio` picks the Studio whose name contains this text (default: the only/first one).
    """
    with _tool_errors():
        return await run_playtest(goal, steps, studio)


@mcp.tool()
async def playtest_correct(run_id: str, step: int, note: str) -> str:
    """Correct the playtester's choice at one step of a run ("it should have ...").

    Sends the correction as a new call in the playtester's Mubit task (a training signal).
    """
    with _tool_errors():
        return await run_correct(run_id, step, note)


@mcp.tool()
def playtest_report(run_id: str) -> str:
    """Show the saved report of a past playtest run as markdown."""
    with _tool_errors():
        return get_report(run_id)


@mcp.tool()
def playtest_list() -> str:
    """List past playtest runs (run_id, goal met, bugs, steps, goal)."""
    with _tool_errors():
        return get_list()


@mcp.tool()
def forge_doctor() -> str:
    """Check the Mubit key, luau-compile, the StudioMCP binary and connected Studios."""
    return doctor_text()


def main() -> None:
    mcp.run("stdio")


if __name__ == "__main__":
    main()
