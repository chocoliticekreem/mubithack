"""Seed a Forge run from the human game tree (game/), and promote Forge's new files back.

    forge seed flame-and-blame        # runs/flame-and-blame/game <- game/, spec from forge/seeds/flame-and-blame.json
    forge promote flame-and-blame ServerScriptService/Services/FlareUpService.luau   # -> game/<same path>

A seeded spec records every human .luau file in spec["base_files"]; Forge's fixer never edits those
(only `forge correct` may, because a human asked). Re-seeding refreshes the human files and keeps
Forge's own new files, iterations and corrections.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

from forge.config import Settings
from forge.memory import RunStore

SEEDS_DIR = Path(__file__).parent / "seeds"
_IGNORE = shutil.ignore_patterns("__pycache__", "*.pyc", "manifest.json", ".DS_Store")


def seed(settings: Settings, slug: str, spec_path: Path | None = None) -> RunStore:
    """Copy game/ into runs/<slug>/game and write runs/<slug>/spec.json (+ state.json if new)."""
    spec_path = Path(spec_path) if spec_path else SEEDS_DIR / f"{slug}.json"
    spec = json.loads(spec_path.read_text())
    base = settings.base_game_dir
    store = RunStore(settings, slug)
    store.ensure()
    shutil.copytree(base, store.game_dir, dirs_exist_ok=True, ignore=_IGNORE)
    base_files = sorted(p.relative_to(base).as_posix() for p in base.rglob("*.luau"))
    store.save_spec({**spec, "slug": slug, "base_files": base_files})
    from forge.versions import GameVersions

    GameVersions(store.game_dir).snapshot(f"seeded from {base} ({len(base_files)} human files)")
    if not store.state_path.exists():
        store.save_state(store.new_state(str(spec.get("pitch", slug))))
    return store


def promote(settings: Settings, slug: str, rel: str) -> Path:
    """Copy one Forge-made file from runs/<slug>/game/<rel> to game/<rel>. Returns the destination."""
    clean = rel.strip().replace("\\", "/").lstrip("/")
    if clean.startswith("game/"):
        clean = clean[len("game/"):]
    if ".." in clean.split("/") or not clean.endswith(".luau"):
        raise ValueError(f"not a game .luau path: {rel!r}")
    src = RunStore(settings, slug).game_dir / clean
    if not src.is_file():
        raise FileNotFoundError(f"{src} does not exist")
    dest = settings.base_game_dir / clean
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    return dest
