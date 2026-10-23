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


def is_shared(name: str) -> bool:
    """A published place (Team Create) shows its placeId in the studio name."""
    return "placeId" in name


async def sync_once(settings: Settings, root: Path, studio_name: str | None = None,
                    prune: bool = False) -> str:
    """One-shot push (used to update the shared published place from main)."""
    root = root.resolve()
    errors = fsync.check(root)
    if errors:
        raise SystemExit("not synced, luau-compile errors:\n" + "\n".join(f"  {p}: {m.strip()}" for p, m in errors))
    async with Studio(settings) as studio:
        await studio.select(studio_name)
        return await studio.sync(root, settings.sync_port, prune=prune)


async def watch(settings: Settings, root: Path, studio_name: str | None = None,
                interval: float = 0.5, debounce: float = 0.3, shared_ok: bool = False) -> None:
    root = root.resolve()
    async with Studio(settings) as studio:
        sid = await studio.select(studio_name)
        name = next((str(s.get("name", "")) for s in await studio.list_studios() if s.get("id") == sid), "")
        if is_shared(name) and not shared_ok:
            raise SystemExit(
                f"'{name}' is a published (Team Create) place. Watching it would overwrite teammates' "
                "scripts. Develop in your own local place (forge place --open) and update the shared "
                "place from main with `forge sync --studio <name>`. Pass --shared to override.")
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
                        result = await studio.sync(root, settings.sync_port, prune=not shared_ok)
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
