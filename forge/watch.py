"""`forge watch`: auto-sync a game folder into the open Roblox Studio on every file change.

Polls .luau files under the synced roots. On a change it runs the luau-compile check; if that
passes it pulls the files into Studio over the MCP (Edit datamodel). Edits never interrupt a
running playtest: they are queued and pushed once you stop playing.
"""

from __future__ import annotations

import asyncio
import time
from pathlib import Path

from forge import sync as fsync
from forge.config import Settings
from forge.studio import Studio, StudioError

ROOTS = ("ServerScriptService", "ReplicatedStorage", "StarterPlayerScripts",
         "ServerStorage", "StarterGui", "Workspace")


def snapshot(root: Path) -> dict[str, float]:
    out: dict[str, float] = {}
    for r in ROOTS:
        d = root / r
        if d.is_dir():
            for f in d.rglob("*.luau"):
                try:
                    out[str(f.relative_to(root))] = f.stat().st_mtime
                except FileNotFoundError:
                    pass
    return out


def diff(old: dict[str, float], new: dict[str, float]) -> list[str]:
    changed = [p for p, m in new.items() if old.get(p) != m]
    removed = [f"-{p}" for p in old if p not in new]
    return sorted(changed) + sorted(removed)


def _ts() -> str:
    return time.strftime("%H:%M:%S")


async def watch(settings: Settings, root: Path, studio_name: str | None = None,
                interval: float = 0.5, debounce: float = 0.3) -> None:
    root = root.resolve()
    async with Studio(settings) as studio:
        sid = await studio.select(studio_name)
        print(f"[{_ts()}] watching {root} -> studio {sid} (port {settings.sync_port}); Ctrl-C to stop", flush=True)
        last = snapshot(root)
        pending = ["(initial sync)"]
        while True:
            if pending:
                await asyncio.sleep(debounce)
                last = snapshot(root)  # settle: pick up files saved in the same burst
                errors = fsync.check(root)
                if errors:
                    for path, msg in errors:
                        print(f"[{_ts()}] ✗ {path}: {msg.strip().splitlines()[0] if msg.strip() else 'error'}", flush=True)
                    print(f"[{_ts()}]   not synced; fix the errors above", flush=True)
                    pending = []
                else:
                    try:
                        st = await studio.state()
                        if st.get("playing"):
                            await asyncio.sleep(1.0)
                            continue  # keep pending until the playtest stops
                        result = await studio.sync(root, settings.sync_port)
                        print(f"[{_ts()}] ✓ {', '.join(pending)[:100]}  ->  {str(result).strip()[:120]}", flush=True)
                        pending = []
                    except StudioError as e:
                        print(f"[{_ts()}] ✗ studio: {e}", flush=True)
                        await asyncio.sleep(2.0)
            await asyncio.sleep(interval)
            now = snapshot(root)
            changes = diff(last, now)
            if changes:
                pending = changes
                last = now
