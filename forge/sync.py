"""Thin wrapper around game/tools/sync.py (stdlib-only, owned by the game side).

The module is imported lazily from settings.base_game_dir / "tools" / "sync.py", so this file
imports fine even before that script exists.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

from forge.config import load_settings

_MODULE_NAME = "forge_game_sync"
_cached: ModuleType | None = None


def sync_script_path() -> Path:
    return load_settings().base_game_dir / "tools" / "sync.py"


def _load() -> ModuleType:
    global _cached
    if _cached is not None:
        return _cached
    path = sync_script_path()
    if not path.exists():
        raise FileNotFoundError(f"game sync tool not found at {path}")
    spec = importlib.util.spec_from_file_location(_MODULE_NAME, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[_MODULE_NAME] = mod
    spec.loader.exec_module(mod)
    _cached = mod
    return mod


def check(root: Path) -> list[tuple[str, str]]:
    """Compile-check every .luau under root. Returns [(relative path, error)]."""
    return _load().check(Path(root))


def write_manifest(root: Path) -> Any:
    """Write root/tools/manifest.json."""
    return _load().write_manifest(Path(root))


def serve_in_thread(root: Path, port: int):
    """Start a 127.0.0.1 file server for root in a daemon thread. Returns the ThreadingHTTPServer."""
    return _load().serve_in_thread(Path(root), int(port))


def pull_luau(port: int, prune: bool = True, manifest: list[dict] | None = None,
              inline: dict[str, str] | None = None) -> str:
    """Luau source to run via execute_luau (Edit DM) that pulls files into Studio. With `manifest`
    and `inline` the manifest and those sources travel inside the script (no HTTP for them)."""
    return _load().pull_luau(int(port), prune=prune, manifest=manifest, inline=inline)


def manifest_entries(root: Path) -> list[dict]:
    """[{service, dirs, name, class, path, hash, size}] for every synced file under root."""
    return _load().manifest_entries(Path(root))


def hashes(entries: list[dict]) -> dict[str, str]:
    """{path: hash} of a manifest."""
    return _load().hashes(entries)


def long_string(text: str) -> str:
    """`text` as a Luau long-bracket string literal."""
    return _load().long_string(text)


def changed_paths(entries: list[dict], pushed: dict[str, str] | None) -> dict[str, list[str]]:
    """{"changed", "added", "removed"} paths between a manifest and the {path: hash} last pushed."""
    return _load().changed_paths(entries, pushed)


def inline_plan(root: Path, entries: list[dict], pushed: dict[str, str] | None,
                budget: int | None = None) -> dict[str, str]:
    """{path: source} of the changed/added files to send inline (smallest first, within budget)."""
    mod = _load()
    return mod.inline_plan(Path(root), entries, pushed, mod.INLINE_BUDGET if budget is None else budget)
