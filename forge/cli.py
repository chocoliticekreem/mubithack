"""`forge doctor | new | run | correct | status | watch | sync | place | play | play-correct | play-list | mcp`."""

from __future__ import annotations

import argparse
import asyncio
import os
import shutil
import sys
from collections import Counter
from pathlib import Path

from forge.config import load_settings
from forge.memory import RunStore

CONSOLE_URL = "https://app.mubit.ai/console/"


def _mask(key: str) -> str:
    if len(key) <= 10:
        return key[:3] + "…"
    return f"{key[:6]}…{key[-4:]}"


# ---------------------------------------------------------------- doctor

def cmd_doctor(args) -> int:
    from forge.loop import UI
    ui = UI()
    s = load_settings()
    ok_all = True
    ui.header("forge doctor")

    if s.mubit_api_key:
        ui.line("mubit", f"MUBIT_API_KEY {_mask(s.mubit_api_key)}", True,
                ui.dim("" if s.mubit_api_key.startswith("mbt_") else "(expected mbt_ prefix)"))
    else:
        ok_all = False
        ui.line("mubit", "MUBIT_API_KEY not set", False, ui.dim("add it to .env"))
    ui.line("mubit", f"{s.provider} via {s.base_url}", None, ui.dim(f"model {s.model}"))
    if os.environ.get("FORGE_FAKE_LLM") == "1":
        ui.line("mubit", "FORGE_FAKE_LLM=1 (calls will NOT reach Mubit)", False)

    luau = shutil.which("luau-compile")
    ui.line("luau", "luau-compile on PATH", bool(luau), ui.dim(luau or "brew install luau"))
    ok_all &= bool(luau)

    mcp = Path(s.studio_mcp_path)
    ui.line("studio", "StudioMCP binary", mcp.exists(), ui.dim(str(mcp)))
    ok_all &= mcp.exists()

    if mcp.exists():
        try:
            studios = asyncio.run(asyncio.wait_for(_list_studios(s), timeout=20))
            names = ", ".join(str(x.get("name", x.get("id", "?"))) for x in studios) or "none open"
            ui.line("studio", f"{len(studios)} studio(s) connected", bool(studios), ui.dim(names[:60]))
            ok_all &= bool(studios)
        except Exception as e:
            ok_all = False
            ui.line("studio", "list studios", False, ui.red(f"{type(e).__name__}: {e}"[:70]))

    base = s.base_game_dir
    probe = base / "ServerScriptService" / "ForgeProbe.server.luau"
    ui.line("game", "base runtime (ForgeProbe)", probe.exists(), ui.dim(str(probe.relative_to(s.repo_root))))
    ui.print()
    ui.print(f"  Mubit console: {ui.cyan(CONSOLE_URL)}")
    return 0 if ok_all else 1


async def _list_studios(settings) -> list[dict]:
    from forge.studio import Studio
    async with Studio(settings) as studio:
        return await studio.list_studios()


# ---------------------------------------------------------------- new / run / correct

def cmd_new(args) -> int:
    from forge.loop import new_game
    slug = asyncio.run(new_game(args.idea, args.iterations, not args.no_studio))
    print(f"\nslug: {slug}   (continue with: forge run {slug})")
    return 0


def cmd_run(args) -> int:
    from forge.loop import run_game
    asyncio.run(run_game(args.slug, args.iterations, not args.no_studio))
    return 0


def cmd_correct(args) -> int:
    from forge.loop import correct
    asyncio.run(correct(args.slug, args.path, args.note, not args.no_studio))
    return 0


# ---------------------------------------------------------------- status

def _fmt_score(v) -> str:
    return "-" if v is None else f"{v:g}"


def cmd_status(args) -> int:
    s = load_settings()
    slugs = [args.slug] if args.slug else RunStore.list_games(s)
    if not slugs:
        print(f"no games in {s.runs_dir}")
        return 0
    roles = ["designer", "coder", "fixer", "critic", "reflector"]
    header = f"{'game':<34} {'iters':>5} {'last':>5} {'best':>5} {'human':>5}  " + " ".join(f"{r[:6]:>6}" for r in roles)
    print(header)
    print("-" * len(header))
    for slug in slugs:
        store = RunStore(s, slug)
        if not store.exists():
            print(f"{slug:<34} (not found)")
            continue
        state = store.load_state()
        its = state.get("iterations", [])
        scores = [it.get("score") for it in its if it.get("score") is not None]
        last = its[-1].get("score") if its else None
        by_role = Counter(c.get("role") for c in store.read_calls())
        print(f"{slug[:34]:<34} {len(its):>5} {_fmt_score(last):>5} {_fmt_score(max(scores) if scores else None):>5} "
              f"{len(state.get('corrections', [])):>5}  " + " ".join(f"{by_role.get(r, 0):>6}" for r in roles))
    if args.slug:
        store = RunStore(s, args.slug)
        state = store.load_state()
        print()
        for it in state.get("iterations", []):
            print(f"  #{it['n']}: score {_fmt_score(it.get('score'))}  issues {len(it.get('issues') or [])}"
                  f"  errors {len(it.get('errors') or [])}  {str(it.get('summary', ''))[:70]}")
        for c in state.get("corrections", []):
            print(f"  human: {c['path']}  {c.get('request_id') or '-'}  \"{c['note'][:50]}\"")
        calls = store.read_calls()
        if calls:
            print(f"\n  last request: {calls[-1].get('request_id')}   console: {CONSOLE_URL}")
    return 0


# ---------------------------------------------------------------- watch / place

def cmd_watch(args) -> int:
    from forge.watch import watch
    s = load_settings()
    root = Path(args.root) if args.root else s.base_game_dir
    if args.slug:
        root = RunStore(s, args.slug).game_dir
    asyncio.run(watch(s, root, args.studio, shared_ok=args.shared))
    return 0


def cmd_sync(args) -> int:
    from forge.watch import sync_once
    s = load_settings()
    root = Path(args.root) if args.root else s.base_game_dir
    if args.slug:
        root = RunStore(s, args.slug).game_dir
    print(asyncio.run(sync_once(s, root, args.studio, prune=args.prune)))
    return 0


def cmd_place(args) -> int:
    import subprocess
    s = load_settings()
    root = Path(args.root) if args.root else s.base_game_dir
    out = Path(args.out)
    tool = s.base_game_dir / "tools" / "make_place.py"
    subprocess.run([sys.executable, str(tool), "--root", str(root), "--out", str(out)], check=True)
    if args.open:
        subprocess.run(["open", "-a", "/Applications/RobloxStudio.app", str(out)], check=False)
    return 0


# ---------------------------------------------------------------- AI playtester

def cmd_play(args) -> int:
    from forge.mcp_server import run_playtest
    print(asyncio.run(run_playtest(args.goal, args.steps, args.studio)))
    return 0


def cmd_play_correct(args) -> int:
    from forge.mcp_server import run_correct
    print(asyncio.run(run_correct(args.run_id, args.step, args.note)))
    return 0


def cmd_play_list(args) -> int:
    from forge.mcp_server import get_list
    print(get_list())
    return 0


def cmd_mcp(args) -> int:
    from forge.mcp_server import main as mcp_main
    mcp_main()
    return 0


# ---------------------------------------------------------------- main

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="forge", description="Idea -> Roblox game, every LLM call through Mubit.")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("doctor", help="check key, luau-compile, StudioMCP, studios")

    n = sub.add_parser("new", help="design + build + playtest loop")
    n.add_argument("idea")
    n.add_argument("--iterations", "-n", type=int, default=3)
    n.add_argument("--no-studio", action="store_true", help="compile-check only, no Studio MCP")

    r = sub.add_parser("run", help="continue iterating an existing game")
    r.add_argument("slug")
    r.add_argument("--iterations", "-n", type=int, default=3)
    r.add_argument("--no-studio", action="store_true")

    c = sub.add_parser("correct", help="human correction -> fixer call -> resync")
    c.add_argument("slug")
    c.add_argument("path", help="file in the game, e.g. ServerScriptService/Game.server.luau (or just Game)")
    c.add_argument("note", help="what is wrong")
    c.add_argument("--no-studio", action="store_true")

    st = sub.add_parser("status", help="iterations, scores, call counts per role")
    st.add_argument("slug", nargs="?")

    w = sub.add_parser("watch", help="auto-sync a game folder into the open Studio on every save")
    w.add_argument("slug", nargs="?", help="a generated game (runs/<slug>/game); default: --root or game/")
    w.add_argument("--root", help="game folder to watch (default game/)")
    w.add_argument("--studio", help="pick the Studio whose name contains this (e.g. Forge.rbxlx)")
    w.add_argument("--shared", action="store_true", help="allow watching a published Team Create place (no prune)")

    sy = sub.add_parser("sync", help="one-shot push of a game folder into Studio (e.g. main -> shared place)")
    sy.add_argument("slug", nargs="?")
    sy.add_argument("--root", help="game folder (default game/)")
    sy.add_argument("--studio", help="pick the Studio whose name contains this")
    sy.add_argument("--prune", action="store_true", help="also delete synced scripts that no longer exist on disk")

    pl = sub.add_parser("place", help="build a .rbxlx from a game folder (baseplate + spawn + scripts)")
    pl.add_argument("--root", help="game folder (default game/)")
    pl.add_argument("--out", default="place/Forge.rbxlx")
    pl.add_argument("--open", action="store_true", help="open it in Roblox Studio")

    py = sub.add_parser("play", help="AI playtest the open Studio game toward a goal (markdown report)")
    py.add_argument("goal")
    py.add_argument("--steps", type=int, default=20)
    py.add_argument("--studio", help="pick the Studio whose name contains this")

    pc = sub.add_parser("play-correct", help="correct the playtester's choice at one step (Mubit signal)")
    pc.add_argument("run_id")
    pc.add_argument("step", type=int)
    pc.add_argument("note", help="what it should have done")

    sub.add_parser("play-list", help="list past playtest runs")
    sub.add_parser("mcp", help="run the forge MCP server over stdio (for Claude Code)")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    handler = {"doctor": cmd_doctor, "new": cmd_new, "run": cmd_run,
               "correct": cmd_correct, "status": cmd_status, "watch": cmd_watch, "sync": cmd_sync,
               "place": cmd_place, "play": cmd_play, "play-correct": cmd_play_correct,
               "play-list": cmd_play_list, "mcp": cmd_mcp}[args.cmd]
    try:
        return handler(args) or 0
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        return 130
    except FileNotFoundError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
