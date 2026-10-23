"""`forge archive`: copy the record of how Forge improved a game into a folder that is committed.

runs/ is gitignored and local. For a game this keeps, under <out>/<slug>/:
- improve/: every cycle (<n>.json: anomalies, investigations, fix attempts, verdicts), scores.json,
  playbook.md, reports.jsonl, calls.jsonl and traces/ (full prompt + reply of every Mubit call)
- calls.jsonl and traces/ from the build loop, state.json, spec.json, iterations/
- versions.md: every saved version with its message and the files it changed
- playtests/: the AI playtest reports from the same time window
plus <out>/logs/ (runs/*.log) and <out>/INDEX.md, a one-page summary per game.
Running it again refreshes the copy. Game source files are not copied: versions.md names them.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

from forge.config import Settings
from forge.memory import RunStore
from forge.versions import GameVersions, VersionError

GAME_FILES = ("state.json", "spec.json", "calls.jsonl")
GAME_DIRS = ("iterations", "traces", "improve")


def _versions_md(game_dir: Path) -> str:
    v = GameVersions(game_dir)
    try:
        rows = v.log()
    except (VersionError, OSError):
        rows = []
    if not rows:
        return "No saved versions.\n"
    out = ["# Versions", ""]
    prev = None
    for r in rows:
        out.append(f"## {r['version']}  ({r['date'][:19]})")
        out.append(r["message"])
        if prev:
            try:
                changed = v._git("diff", "--stat", prev, r["version"]).splitlines()
            except VersionError:
                changed = []
            if changed:
                out += ["", "```", *changed[-25:], "```"]
        out.append("")
        prev = r["version"]
    return "\n".join(out)


def _playtest_window(settings: Settings, start: float, end: float) -> list[Path]:
    root = settings.runs_dir / "playtests"
    if not root.exists():
        return []
    return [d for d in sorted(root.iterdir())
            if (d / "report.json").exists() and start - 60 <= (d / "report.json").stat().st_mtime <= end + 60]


def archive_game(settings: Settings, slug: str, out: Path) -> dict:
    store = RunStore(settings, slug)
    if not store.exists():
        raise FileNotFoundError(f"no game {slug!r} in {settings.runs_dir}")
    dest = out / slug
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    for name in GAME_FILES:
        if (store.dir / name).exists():
            shutil.copy2(store.dir / name, dest / name)
    for name in GAME_DIRS:
        if (store.dir / name).is_dir():
            shutil.copytree(store.dir / name, dest / name,
                            ignore=shutil.ignore_patterns("patches", "*.rbxlx"))
    (dest / "versions.md").write_text(_versions_md(store.game_dir), encoding="utf-8")

    times = [p.stat().st_mtime for p in store.dir.rglob("*") if p.is_file() and ".git" not in p.parts]
    playtests = _playtest_window(settings, min(times), max(times)) if times else []
    for d in playtests:
        shutil.copytree(d, dest / "playtests" / d.name)

    cycles = json.loads((store.dir / "improve" / "scores.json").read_text()) \
        if (store.dir / "improve" / "scores.json").exists() else []
    traces = sum(1 for _ in dest.rglob("traces/*.json"))
    calls = sum(1 for f in dest.rglob("calls.jsonl") for ln in f.read_text().splitlines() if ln.strip())
    return {"slug": slug, "cycles": cycles, "playtests": len(playtests), "traces": traces, "calls": calls,
            "versions": len(GameVersions(store.game_dir).tags()) if store.game_dir.exists() else 0}


def write_index(out: Path, games: list[dict]) -> Path:
    lines = ["# Forge evidence", "",
             "What Forge and its Mubit tasks did to each game. Each folder holds the cycles, versions,",
             "AI playtests and the full trace of every Mubit call (see forge/archive.py).", ""]
    for g in games:
        lines += [f"## {g['slug']}", "",
                  f"- {g['versions']} saved versions (see versions.md), {len(g['cycles'])} improve cycles, "
                  f"{g['playtests']} AI playtests, {g['calls']} Mubit calls, {g['traces']} full traces"]
        for c in g["cycles"]:
            lines.append(f"- cycle {c['cycle']} ({c['ts']}): open anomalies {c.get('open', '-')}, "
                         f"code fixes kept {c.get('code_kept', 0)}/{c.get('code_tried', 0)}, "
                         f"planted faults detected {c['detected']}/{c['planted']}")
        lines.append("")
    path = out / "INDEX.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def archive(settings: Settings, slugs: list[str], out: Path) -> list[dict]:
    out.mkdir(parents=True, exist_ok=True)
    games = [archive_game(settings, s, out) for s in slugs]
    logs = out / "logs"
    for log in settings.runs_dir.glob("*.log"):
        logs.mkdir(exist_ok=True)
        shutil.copy2(log, logs / log.name)
    write_index(out, games)
    return games
