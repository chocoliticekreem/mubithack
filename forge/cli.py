"""`forge doctor | new | run | correct | status | watch | sync | place | play | play-correct | play-list |
assets <list|generate|search|upload|sync> | test <tool> | mcp`.

`forge test <tool> ...` mirrors every `mubit-tester` MCP tool (docs/TESTER.md): the subcommands and
their options are generated from the tools' input schemas, and run through the same code path.
"""

from __future__ import annotations

import argparse
import contextlib
import asyncio
import json
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


def cmd_versions(args) -> int:
    from forge.versions import GameVersions
    rows = GameVersions(RunStore(load_settings(), args.slug).game_dir).log()
    if not rows:
        print(f"no versions for {args.slug} yet")
    for r in rows:
        print(f"{r['version']:>5}  {r['date'][:19]}  {r['message'].splitlines()[0][:100]}")
    return 0


def cmd_rollback(args) -> int:
    from forge.versions import GameVersions
    from forge.watch import sync_once
    s = load_settings()
    store = RunStore(s, args.slug)
    tag = GameVersions(store.game_dir).restore(args.version, args.reason or "by hand")
    print(f"restored {args.version} as {tag}")
    if not args.no_sync:
        print(asyncio.run(sync_once(s, store.game_dir, args.studio or os.environ.get("FORGE_STUDIO"),
                                    prune=True)))
    return 0


def cmd_dashboard(args) -> int:
    import webbrowser

    from forge.dashboard import serve
    server = serve(args.host, args.port)
    url = f"http://{'127.0.0.1' if args.host in ('0.0.0.0', '') else args.host}:{args.port}"
    print(f"forge dashboard: {url}  (Ctrl-C to stop)")
    if args.open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


def cmd_archive(args) -> int:
    from forge.archive import archive
    s = load_settings()
    slugs = args.slugs or [g for g in RunStore.list_games(s) if (s.runs_dir / g / "improve").exists()]
    out = Path(args.out) if args.out else s.repo_root / "evidence"
    for g in archive(s, slugs, out):
        print(f"{g['slug']}: {g['versions']} versions, {len(g['cycles'])} cycles, {g['playtests']} playtests, "
              f"{g['calls']} Mubit calls, {g['traces']} traces")
    print(f"-> {out} (commit it on a branch to keep it)")
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
    from mubit_tester.server import run_playtest
    print(asyncio.run(run_playtest(args.goal, args.steps, args.studio)))
    return 0


def cmd_play_correct(args) -> int:
    from mubit_tester.server import run_correct
    print(asyncio.run(run_correct(args.run_id, args.step, args.note)))
    return 0


def cmd_play_list(args) -> int:
    from mubit_tester.server import get_list
    print(get_list())
    return 0


# ---------------------------------------------------------------- forge test <tool> (mubit-tester)

def _tester_tools() -> list:
    from mubit_tester.server import mcp
    return mcp._tool_manager.list_tools()


def _schema_types(prop: dict) -> set[str]:
    types = {prop.get("type")} if prop.get("type") else set()
    for alt in prop.get("anyOf") or []:
        if alt.get("type"):
            types.add(alt["type"])
    types.discard("null")
    return types or {"any"}


def _cli_value(raw: str, types: set[str]):
    """Parse a CLI string for a schema property: JSON for numbers/arrays/objects/any, else text."""
    if types == {"string"}:
        return raw
    if types == {"boolean"}:
        return raw.lower() in ("1", "true", "yes", "y", "on")
    try:
        val = json.loads(raw)
    except ValueError:
        if "string" in types or "any" in types:
            return raw
        raise argparse.ArgumentTypeError(f"expected JSON ({'/'.join(sorted(types))}), got {raw!r}")
    if "string" in types and not isinstance(val, (list, dict)) and not ({"number", "integer"} & types):
        return raw  # e.g. --near 1 is helmet "1", not the number 1
    return val


def _add_test_parsers(sub) -> None:
    t = sub.add_parser("test", help="mubit-tester tools from the shell (forge test <tool> -h)")
    tsub = t.add_subparsers(dest="tool", required=True, metavar="<tool>")
    for tool in _tester_tools():
        schema = tool.parameters or {}
        props = schema.get("properties") or {}
        required = set(schema.get("required") or [])
        flat = " ".join((tool.description or "").split())
        first_line = flat.split(". ")[0].rstrip(".")
        alias = tool.name.replace("_", "-")
        tp = tsub.add_parser(tool.name, help=first_line, description=tool.description,
                             aliases=[alias] if alias != tool.name else [])
        tp.set_defaults(tool=tool.name, _props=props)
        for name, prop in props.items():
            types = _schema_types(prop)
            hint = "/".join(sorted(types))
            if name in required:
                tp.add_argument(name, metavar=name, help=f"{hint}")
            elif types == {"boolean"}:
                tp.add_argument(f"--{name.replace('_', '-')}", dest=name, action="store_true",
                                default=None, help=f"(default {prop.get('default')})")
            else:
                tp.add_argument(f"--{name.replace('_', '-')}", dest=name, metavar=hint.upper(),
                                default=None, help=f"{hint} (default {prop.get('default')})")


def test_tool_args(args) -> dict:
    """argparse Namespace -> MCP tool arguments (only the ones given)."""
    out = {}
    for name, prop in (getattr(args, "_props", None) or {}).items():
        raw = getattr(args, name, None)
        if raw is None:
            continue
        out[name] = raw if isinstance(raw, bool) else _cli_value(raw, _schema_types(prop))
    return out


async def run_tester_tool(name: str, arguments: dict) -> tuple[str, bool]:
    """Call a mubit-tester tool in-process; returns (text, ok)."""
    from mcp.server.mcpserver.exceptions import ToolError

    from mubit_tester.server import mcp
    try:
        res = await mcp.call_tool(name, arguments)
    except ToolError as e:
        return f"error: {e}", False
    parts = []
    for c in getattr(res, "content", None) or []:
        if getattr(c, "type", None) == "text":
            parts.append(c.text)
        elif getattr(c, "type", None) == "image":
            parts.append("(image returned)")
    return "\n".join(parts), not getattr(res, "is_error", False)


def cmd_test(args) -> int:
    text, ok = asyncio.run(run_tester_tool(args.tool, test_tool_args(args)))
    print(text)
    return 0 if ok else 1


def cmd_assets(args) -> int:
    from forge.assets import cmd_assets as run
    return run(args)


def cmd_mcp(args) -> int:
    from mubit_tester.server import main as mcp_main
    mcp_main()
    return 0


# ---------------------------------------------------------------- improve (docs/MUBIT_LOOP.md)

async def _improve(args, *, faults_on: bool = True, fix: bool = False) -> None:
    from forge.improve import ImproveStore, default_faults, load_faults, pending_report_anomalies, run_cycle
    from forge.llm import make_llm
    from forge.studio import Studio
    from mubit_tester.ai import multi_playtest
    from mubit_tester.harness import Harness

    s = load_settings()
    faults = []
    if faults_on:
        faults = default_faults(load_faults(args.slug, Path(args.faults_file) if args.faults_file else None),
                                args.only.split(",") if args.only else None)
    store = ImproveStore(s, args.slug)
    llm = make_llm(s, log_path=store.dir / "calls.jsonl")
    async with Studio(s) as studio:
        await studio.select(args.studio or os.environ.get("FORGE_STUDIO") or None)
        harness = Harness(studio)
        for n in range(args.cycles):
            extra = pending_report_anomalies(store) if getattr(args, "reports", False) else []
            cycle = await run_cycle(s, args.slug, llm=llm, harness=harness, playtest=multi_playtest,
                                    faults=faults, goal=args.goal, rounds=args.rounds,
                                    players=args.players, steps=args.steps, fix=fix,
                                    max_fixes=getattr(args, "max_fixes", 3), extra_anomalies=extra,
                                    edit_human=getattr(args, "edit_human_files", False))
            if fix and cycle["open"] == 0:
                print(f"quality bar met after {n + 1} cycle(s): no high or medium anomalies left")
                break


def cmd_fix(args) -> int:
    asyncio.run(_improve(args, faults_on=False, fix=True))
    return cmd_scores(args)


def cmd_report(args) -> int:
    from forge.improve import ImproveStore, file_report
    from forge.llm import make_llm

    s = load_settings()
    llm = make_llm(s, log_path=ImproveStore(s, args.slug).dir / "calls.jsonl")
    rec = file_report(s, args.slug, args.text, llm=llm, run_ids=args.run or None, reporter=args.by)
    print(f"\n{rec['triage']['summary']}")
    for a in rec["triage"]["anomalies"]:
        print(f"  [{a['severity']}] {a['system']}: {a['title']} - {a['observed'][:120]}")
    if rec["auditor_missed"]:
        print(f"auditor had missed: {', '.join(rec['auditor_missed'])} (correction "
              f"{(rec['correction'] or {}).get('request_id', 'not sent: no rounds')})")
    return 0


def cmd_reports(args) -> int:
    from forge.improve import list_reports
    rows = list_reports(load_settings(), args.slug)
    if not rows:
        print(f"no tester reports for {args.slug} yet")
    for r in rows:
        print(f"{r['ts']}  {r.get('reporter') or '-':<12} {len(r['triage']['anomalies'])} anomalies, "
              f"auditor missed {len(r['auditor_missed'])}  \"{r['text'][:60]}\"")
    return 0


def cmd_server(args) -> int:
    from forge.mcp_server import main as server_main
    server_main()
    return 0


def cmd_improve(args) -> int:
    asyncio.run(_improve(args, fix=args.fix))
    return cmd_scores(args)


def cmd_scores(args) -> int:
    from forge.improve import ImproveStore
    rows = ImproveStore(load_settings(), args.slug).scores()
    if not rows:
        print(f"no improve cycles for {args.slug} yet")
        return 0
    print(f"{'cycle':>5} {'planted':>7} {'detected':>8} {'missed':>6} {'unmatched':>9} {'fixed':>5} "
          f"{'open':>4} {'code kept':>9}  ts")
    for r in rows:
        print(f"{r['cycle']:>5} {r['planted']:>7} {r['detected']:>8} {r['missed']:>6} "
              f"{r['unmatched']:>9} {r['fixed_verified']:>5} {r.get('open', '-'):>4} "
              f"{str(r.get('code_kept', 0)) + '/' + str(r.get('code_tried', 0)):>9}  {r['ts']}")
    return 0


# ---------------------------------------------------------------- seed / promote

def cmd_seed(args) -> int:
    from forge.seed import seed
    s = load_settings()
    store = seed(s, args.slug, Path(args.spec) if args.spec else None)
    spec = store.load_spec()
    mods = ", ".join(m["path"] for m in spec.get("modules", [])) or "(none)"
    print(f"seeded {store.game_dir} from {s.base_game_dir} ({len(spec['base_files'])} human files, fixer-protected)")
    print(f"Forge modules: {mods}")
    print(f"next: FORGE_STUDIO=<your Forge-ai place> forge run {args.slug} -n 1")
    return 0


def cmd_promote(args) -> int:
    from forge.seed import promote
    dest = promote(load_settings(), args.slug, args.path)
    print(f"promoted -> {dest}")
    print("next: git switch -c gf/<topic> && git add " + str(dest) + " && gh pr create --fill")
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
    from forge.assets import add_cli_parser as _add_assets_parser
    _add_assets_parser(sub)
    _add_test_parsers(sub)
    sub.add_parser("mcp", help="run the mubit-tester MCP server over stdio (for Claude Code)")

    se = sub.add_parser("seed", help="copy game/ into runs/<slug>/game + spec from forge/seeds/<slug>.json")
    se.add_argument("slug")
    se.add_argument("--spec", help="spec JSON (default forge/seeds/<slug>.json)")

    pr = sub.add_parser("promote", help="copy a Forge-made file from runs/<slug>/game back into game/")
    pr.add_argument("slug")
    pr.add_argument("path", help="e.g. ServerScriptService/Services/FlareUpService.luau")

    im = sub.add_parser("improve", help="plant faults -> playtests -> auditor -> fix -> verifier (Mubit)")
    im.add_argument("slug")
    im.add_argument("--goal", default="Play a full round: put out fires, rescue everyone, refill water")
    im.add_argument("--cycles", type=int, default=1)
    im.add_argument("--rounds", type=int, default=3, help="playtest rounds before the audit")
    im.add_argument("--steps", type=int, default=15, help="AI player steps per round")
    im.add_argument("--players", type=int, default=None)
    im.add_argument("--only", help="comma-separated fault ids (default: every default fault)")
    im.add_argument("--faults-file", help="faults JSON (default forge/faults/<slug>.json)")
    im.add_argument("--studio", help="Studio name part (default FORGE_STUDIO)")
    im.add_argument("--fix", action="store_true", help="also fix real (non-planted) anomalies in code")

    fx = sub.add_parser("fix", help="playtest -> auditor -> fix real anomalies in code -> verify, until clean")
    fx.add_argument("slug")
    fx.add_argument("--goal", default="Play a full round: put out fires, rescue everyone, refill water")
    fx.add_argument("--cycles", type=int, default=3, help="stop early once nothing high/medium is open")
    fx.add_argument("--rounds", type=int, default=2, help="playtest rounds before each audit")
    fx.add_argument("--steps", type=int, default=15)
    fx.add_argument("--players", type=int, default=None)
    fx.add_argument("--max-fixes", type=int, default=3, help="anomalies to fix per cycle")
    fx.add_argument("--reports", action="store_true", help="also fix anomalies from new tester reports")
    fx.add_argument("--studio", help="Studio name part or id (default FORGE_STUDIO)")
    fx.add_argument("--edit-human-files", action="store_true",
                    help="let the fixer edit a seeded game's human files (in runs/<slug>/game only)")

    db = sub.add_parser("dashboard", help="live view of jobs, games, fix cycles, versions and Mubit calls")
    db.add_argument("--port", type=int, default=8765)
    db.add_argument("--host", default="127.0.0.1", help="0.0.0.0 to share on your network")
    db.add_argument("--open", action="store_true", help="open it in the browser")

    ar = sub.add_parser("archive", help="copy the record of a game's improvement (cycles, traces, versions) to evidence/")
    ar.add_argument("slugs", nargs="*", help="games (default: every game with improve cycles)")
    ar.add_argument("--out", help="folder (default evidence/ in the repo)")

    ve = sub.add_parser("versions", help="every saved version of a game (builds, iterations, fixes, rollbacks)")
    ve.add_argument("slug")

    rb = sub.add_parser("rollback", help="restore a saved version of a game and resync it into Studio")
    rb.add_argument("slug")
    rb.add_argument("version", help="e.g. v3 (see forge versions)")
    rb.add_argument("--reason")
    rb.add_argument("--studio", help="Studio name part or id (default FORGE_STUDIO)")
    rb.add_argument("--no-sync", action="store_true", help="only restore the files")

    sub.add_parser("server", help="run the forge MCP server over stdio (build games from any MCP client)")

    rp = sub.add_parser("report", help="a human tester's report -> triage -> auditor correction (Mubit)")
    rp.add_argument("slug")
    rp.add_argument("text")
    rp.add_argument("--run", action="append", help="playtest run id the tester was in (repeatable)")
    rp.add_argument("--by", help="who reported it")

    rps = sub.add_parser("reports", help="tester reports filed for a game")
    rps.add_argument("slug")

    sc = sub.add_parser("scores", help="per-cycle improve scores for a game")
    sc.add_argument("slug")
    return p


def main(argv: list[str] | None = None) -> int:
    # Progress lines reach a piped log (tee, runs/*.log, the dashboard) as they happen.
    with contextlib.suppress(AttributeError, ValueError):
        sys.stdout.reconfigure(line_buffering=True)
    args = build_parser().parse_args(argv)
    handler = {"doctor": cmd_doctor, "new": cmd_new, "run": cmd_run,
               "correct": cmd_correct, "status": cmd_status, "watch": cmd_watch, "sync": cmd_sync,
               "place": cmd_place, "seed": cmd_seed, "promote": cmd_promote,
               "improve": cmd_improve, "scores": cmd_scores, "server": cmd_server, "fix": cmd_fix, "archive": cmd_archive, "dashboard": cmd_dashboard, "versions": cmd_versions,
               "rollback": cmd_rollback, "report": cmd_report,
               "reports": cmd_reports, "play": cmd_play, "play-correct": cmd_play_correct,
               "play-list": cmd_play_list, "assets": cmd_assets, "test": cmd_test, "mcp": cmd_mcp}[args.cmd]
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
