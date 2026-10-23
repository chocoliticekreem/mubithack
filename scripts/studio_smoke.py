"""Manual smoke test for the Studio MCP client.

    .venv/bin/python scripts/studio_smoke.py

Connects to StudioMCP, lists tools and studios, and if a Studio is connected runs
`return game.Name` in the Edit datamodel and prints the studio state.
"""

from __future__ import annotations

import sys
from pathlib import Path

import anyio

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from forge.studio import OPEN_STUDIO_HINT, Studio, StudioError  # noqa: E402


async def main() -> int:
    async with Studio() as s:
        print(f"tools ({len(s.tools)}): {', '.join(sorted(s.tools))}")
        studios = await s.list_studios()
        print(f"studios: {studios}")
        if not studios:
            print(f"No Studio connected. {OPEN_STUDIO_HINT}")
            return 0
        sid = await s.select()
        print(f"selected: {sid}")
        state = await s.state()
        print(f"state: datamodels={state['datamodels']} playing={state['playing']}\n  raw: {state['raw']}")
        dm = "Server" if state["playing"] else "Edit"
        print(f"execute_luau ({dm}) `return game.Name` -> {await s.execute_luau('return game.Name', dm)!r}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(anyio.run(main))
    except StudioError as e:
        print(f"StudioError: {e}")
        sys.exit(1)
