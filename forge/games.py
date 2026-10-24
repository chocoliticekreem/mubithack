"""`forge promote-game <slug>`: a finished agent-built game gets its own committed folder, games/<slug>/.

    games/<slug>/
      README.md    what it is, how it plays, its modules, how it was built (generated)
      spec.json    the game's spec (pitch, core loop, modules, acceptance, playtest settings)
      game/        its Luau, file-mapped like game/ (sync it into Studio with `forge sync --root`)

runs/<slug> stays the working copy (versions, traces, cycles). Flame and Blame still lives in game/
until the team moves it (see games/flame-and-blame/README.md).
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

from forge.config import Settings
from forge.memory import RunStore
from forge.versions import GameVersions, VersionError

_IGNORE = shutil.ignore_patterns(".git", ".gitignore", "__pycache__", "*.pyc", "manifest.json", ".DS_Store")


def games_dir(settings: Settings) -> Path:
    return settings.repo_root / "games"


def game_readme(slug: str, spec: dict, state: dict, versions: list[dict]) -> str:
    title = spec.get("title") or slug
    lines = [f"# {title}", "", str(spec.get("pitch", "")).strip(), "",
             "Built by Forge's Mubit agent (designer, coder, AI playtests, critic, fixer, verifier).", "",
             "## How it plays", "", str(spec.get("core_loop", "")).strip() or "(see spec.json)", ""]
    mods = spec.get("modules") or []
    if mods:
        lines += ["## Modules", ""] + [f"- `{m.get('path')}`: {str(m.get('purpose', '')).strip()[:200]}"
                                       for m in mods] + [""]
    acc = spec.get("acceptance") or []
    if acc:
        lines += ["## Acceptance checks", ""] + [f"- {a}" for a in acc] + [""]
    its = state.get("iterations") or []
    scores = [str(it.get("score")) for it in its if it.get("score") is not None]
    lines += ["## How it was built", "",
              f"- {len(its)} build iterations (critic scores: {', '.join(scores) or 'none'}), "
              f"{len(versions)} saved versions, {len(state.get('corrections') or [])} human corrections.",
              f"- Working copy, versions and traces: `runs/{slug}/` (local); record: `evidence/{slug}/` "
              "(`forge archive`).", "",
              "## Play it", "",
              "```bash",
              f".venv/bin/forge place --root games/{slug}/game --out place/{slug}.rbxlx --open",
              "```",
              "Then press Play in Studio, or File > Publish to Roblox to make it a real experience.", ""]
    return "\n".join(lines)


def promote_game(settings: Settings, slug: str) -> Path:
    """Copy runs/<slug>/game + spec into games/<slug>/ and write its README. Returns the folder."""
    store = RunStore(settings, slug)
    if not store.exists() or not store.game_dir.exists():
        raise FileNotFoundError(f"no built game {slug!r} in {settings.runs_dir}")
    dest = games_dir(settings) / slug
    if (dest / "game").exists():
        shutil.rmtree(dest / "game")
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copytree(store.game_dir, dest / "game", ignore=_IGNORE)
    spec = store.load_spec() if store.spec_path.exists() else {}
    (dest / "spec.json").write_text(json.dumps(spec, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    try:
        versions = GameVersions(store.game_dir).log()
    except (VersionError, OSError):
        versions = []
    state = store.load_state() if store.state_path.exists() else {}
    (dest / "README.md").write_text(game_readme(slug, spec, state, versions), encoding="utf-8")
    return dest
