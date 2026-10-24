"""`forge doctor | new | run | correct | status | watch | sync | place | play | play-correct | play-list |
assets <list|generate|search|upload|sync> | test <tool> | mcp`.

`forge test <tool> ...` mirrors every `mubit-tester` MCP tool (docs/TESTER.md): the subcommands and
their options are generated from the tools' input schemas, and run through the same code path.
"""

from __future__ import annotations

import argparse
import contextlib
import functools
import asyncio
import json
import time
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

def _speed_args(p) -> None:
    from forge.llm import DEFAULT_JOBS
    p.add_argument("--jobs", "-j", type=int, default=None,
                   help=f"concurrent LLM calls (default FORGE_JOBS or {DEFAULT_JOBS}; 1 = one at a time)")
    p.add_argument("--no-cache", action="store_true",
                   help="always call Mubit (skip the reply cache in runs/.cache/llm)")


def _apply_speed_args(args) -> None:
    """--jobs / --no-cache become FORGE_JOBS / FORGE_NO_CACHE, so every LLM client in the process sees them."""
    if getattr(args, "jobs", None):
        os.environ["FORGE_JOBS"] = str(max(1, args.jobs))
    if getattr(args, "no_cache", False):
        os.environ["FORGE_NO_CACHE"] = "1"


def cmd_new(args) -> int:
    from forge.loop import new_game
    from forge.reflect import maybe_reflect
    slug = asyncio.run(new_game(args.idea, args.iterations, not args.no_studio,
                                use_director=False if args.no_director else None, jobs=args.jobs))
    maybe_reflect(load_settings(), slug, label="forge new")
    print(f"\nslug: {slug}   (continue with: forge run {slug})")
    return 0


def cmd_run(args) -> int:
    from forge.loop import run_game
    asyncio.run(run_game(args.slug, args.iterations, not args.no_studio, jobs=args.jobs))
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


def _game_root(args) -> Path:
    s = load_settings()
    root = Path(args.root) if args.root else s.base_game_dir
    if args.slug:
        root = RunStore(s, args.slug).game_dir
    return root


def cmd_bench_io(args) -> int:
    from forge.bench_io import bench
    print(bench(_game_root(args), args.studio, offline=args.offline, repeat=args.repeat,
                out_json=Path(args.json) if args.json else None))
    return 0


def cmd_headless(args) -> int:
    from forge import checks
    from forge import headless as hl
    if args.stats:
        st = hl.usage_stats(since=time.time() - args.since * 3600 if args.since else 0.0, slug=args.slug)
        print(json.dumps(st, indent=1))
        return 0
    root = _game_root(args)
    if args.playtest:
        rep = asyncio.run(hl.playtest(root, play=args.play, players=args.players, clients=not args.no_clients,
                                      slug=args.slug or ""))
    else:
        rep = checks.boot_offline(root, play=args.play, players=args.players, clients=not args.no_clients)
    print(json.dumps(rep, indent=1))
    run_dir = root.parent
    results = checks.run_checks_offline(root, checks.load_checks(run_dir))
    if results:
        print(checks.summary(results))
        need = [r["id"] for r in results if r.get("verdict") == "needs_studio"]
        if need:
            print(f"needs Studio: {', '.join(need)}")
    return 1 if rep.get("error") or rep.get("errors") or any(not r.get("ok") for r in results) else 0


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


def cmd_qa(args) -> int:
    """The QA protocol (mubit_tester.protocol): understand -> plan -> execute -> investigate -> report."""
    from mubit_tester.protocol import qa_test

    s = load_settings()
    rep = asyncio.run(qa_test(s, args.focus, game_dir=Path(args.root) if args.root else None,
                              max_steps=args.steps, studio_name=args.studio or os.environ.get("FORGE_STUDIO"),
                              stop=not args.keep_playing))
    print((Path(rep["test_dir"]) / "report.md").read_text(encoding="utf-8"))
    print(f"\nreport: {rep['test_dir']}/report.md  (correct a call: forge play-correct {rep['run_id']} <step> \"...\")")
    return 0 if rep.get("goal_met") is not False else 1


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
                tp.add_argument(f"--{name.replace('_', '-')}", dest=name, action=argparse.BooleanOptionalAction,
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
    from mubit_tester.ai import multi_playtest
    from mubit_tester.harness import Harness

    s = load_settings()
    faults = []
    if faults_on:
        faults = default_faults(load_faults(args.slug, Path(args.faults_file) if args.faults_file else None),
                                args.only.split(",") if args.only else None)
    store = ImproveStore(s, args.slug)
    llm = make_llm(s, log_path=store.dir / "calls.jsonl")
    args.goal = args.goal or default_goal(store.run.load_spec() if store.run.spec_path.exists() else {})
    from forge import headless as hl
    # fix cycles run on the headless engine (simulated players) unless --studio always (forge/headless.py)
    async with hl.backend(s, store.run.game_dir, studio_name=args.studio, players=max(1, args.players or 1),
                          slug=args.slug, kind="fix_cycle") as studio:
        harness = Harness(studio)
        for n in range(args.cycles):
            extra = pending_report_anomalies(store) if getattr(args, "reports", False) else []
            # the run's own files and spec give the UI surfaces testers must press (ui_coverage)
            playtest = functools.partial(multi_playtest, game_dir=store.run.game_dir)
            if getattr(args, "start_round", False):
                from forge.improve import round_starting
                playtest = round_starting(playtest, seconds=getattr(args, "round_seconds", None))
            cycle = await run_cycle(s, args.slug, llm=llm, harness=harness, playtest=playtest,
                                    faults=faults, goal=args.goal, rounds=args.rounds,
                                    players=args.players, steps=args.steps, fix=fix,
                                    max_fixes=getattr(args, "max_fixes", 3), extra_anomalies=extra,
                                    edit_human=getattr(args, "edit_human_files", False),
                                    repro=not getattr(args, "no_repro", False))
            if fix and cycle["open"] == 0:
                print(f"quality bar met after {n + 1} cycle(s): no high or medium anomalies left")
                break


def _sigterm_as_interrupt() -> None:
    import signal

    def handler(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, handler)


def cmd_feature(args) -> int:
    from forge.feature import add_feature
    _sigterm_as_interrupt()
    res = asyncio.run(add_feature(load_settings(), args.slug, args.request, iterations=args.iterations,
                                  use_studio=not args.no_studio, polish=args.polish, jobs=args.jobs))
    print(f"\nfeature: {res.get('status') or ('verified' if res.get('verified') else 'built')}  "
          f"new {res.get('built')}  edited {res.get('edited')}  version {res.get('version')}")
    print(f"roll back with: forge rollback {args.slug} {res.get('before')}")
    return 0


def cmd_polish(args) -> int:
    from forge.feature import polish_feature
    _sigterm_as_interrupt()
    cycles = asyncio.run(polish_feature(load_settings(), args.slug, cycles=args.cycles))
    for c in cycles:
        print(f"cycle {c['cycle']}: open {c['open']}, kept {c['code_kept']}/{len(c.get('code_fixes') or [])}, "
              f"feature counters seen: {c.get('feature_verified')}")
    return 0


def default_goal(spec: dict) -> str:
    """What the AI testers try to do, from the game's own spec (never another game's)."""
    loop = str(spec.get("core_loop") or "").strip()
    pitch = str(spec.get("pitch") or spec.get("title") or "").strip()
    if loop:
        return f"Play the game as a real player would: {loop}"[:400]
    return f"Play the game as a real player would and use its main mechanics: {pitch}"[:400]


def cmd_promote_game(args) -> int:
    from forge.games import promote_game
    dest = promote_game(load_settings(), args.slug)
    print(f"promoted -> {dest}")
    print(f"next: git switch -c gf/game-{args.slug} && git add {dest} && gh pr create --fill")
    return 0


def cmd_fix(args) -> int:
    from forge.reflect import maybe_reflect
    _sigterm_as_interrupt()  # a killed run still restores the file it was testing
    try:
        asyncio.run(_improve(args, faults_on=False, fix=True))
    finally:  # a stopped run's calls are worth a reflection too
        maybe_reflect(load_settings(), args.slug, label=f"forge fix (--cycles {args.cycles})")
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


def cmd_ledger(args) -> int:
    from forge.ledger import ledger, render
    data = ledger(load_settings())
    print(json.dumps(data, indent=1) if args.json else render(data, args.recent))
    return 0


def cmd_reflect(args) -> int:
    from forge import reflect as fr
    s = load_settings()
    if args.all:
        _, text = fr.reflect_all(s)
        print(text + f"\n\nsaved {s.runs_dir / 'reflection.md'}")
        return 0
    if not args.slug:
        print("error: name a game (forge reflect <slug>) or use --all", file=sys.stderr)
        return 2
    if not (s.runs_dir / args.slug).is_dir():
        raise FileNotFoundError(f"no game {args.slug!r} in {s.runs_dir}")
    llm = None
    if args.llm:
        from forge.llm import make_llm
        llm = make_llm(s, log_path=s.runs_dir / args.slug / fr.DIR / "calls.jsonl")
    rec = fr.reflect(s, args.slug, label="forge reflect", llm=llm)
    if rec is not None:
        print("\n" + fr.render(rec))
    return 0


def cmd_direct(args) -> int:
    from forge.director import dry_run, render_compare
    out = dry_run(load_settings(), args.idea, compare=args.compare)
    print(json.dumps(out["stats"], indent=1) if args.json else render_compare(out))
    return 0


def cmd_fun(args) -> int:
    from forge.fun import critique_game
    res = critique_game(load_settings(), args.slug)
    print(json.dumps({k: res[k] for k in ("score", "scores", "summary", "checks", "issues")}, indent=1))
    return 0


def cmd_done(args) -> int:
    from forge.done import readiness, render
    r = readiness(load_settings(), args.slug, compare=True)
    print(json.dumps(r, indent=1) if args.json else render(r))
    return 0 if r["ready"] else 1


async def _checks(args) -> None:
    from forge.llm import make_llm
    from forge.scenarios import plan_checks, run_plan
    from forge.studio import Studio

    s = load_settings()
    llm = make_llm(s, log_path=RunStore(s, args.slug).calls_log)
    if args.plan:
        plan_checks(s, args.slug, llm=llm, max_checks=args.max)
    if args.run:
        from forge import headless as hl

        only, prior = None, None
        mode = hl.studio_mode()
        # headless first by default (--studio auto|never); --studio always runs every check in Studio
        if mode != "always" or getattr(args, "headless_first", False):
            from forge import checks as chk
            store = RunStore(s, args.slug)
            kept, rest = chk.triage(store.game_dir, chk.load_checks(store.dir), mode=mode if mode != "always" else "auto")
            prior = [{**r, "verdict": r.get("verdict") or "pass", "source": "headless"} for r in kept]
            only = {c.id for c in rest}
            print(f"[check] headless: {sum(1 for r in kept if r.get('ok'))} pass, {len(rest)} need Studio"
                  + (f" ({len(kept) - sum(1 for r in kept if r.get('ok'))} not run: --studio never)" if mode == "never" else ""))
            if not rest:
                from forge.scenarios import save_results
                save_results(store.dir, prior)
                return
        async with Studio(s) as studio:
            await studio.select(args.studio or os.environ.get("FORGE_STUDIO") or None)
            if not getattr(args, "no_sync", False):
                await sync_before_checks(studio, RunStore(s, args.slug).game_dir, s.sync_port)
            await run_plan(studio, args.slug, settings=s, llm=llm, only=only, prior=prior)


async def sync_before_checks(studio, game_dir: Path, port: int) -> str:
    """Checks run against whatever is in Studio: push the game on disk first, or they test old code."""
    out = str(await studio.sync(game_dir, port) or "")
    if out.startswith("ERROR"):
        raise RuntimeError(f"sync before checks failed: {out[:300]}")
    print(f"[check] synced the game into Studio: {out[:80]}")
    return out


def cmd_checks(args) -> int:
    from forge.checks import load_checks

    if not (args.plan or args.run):
        for c in load_checks(RunStore(load_settings(), args.slug).dir):
            print(f"{c.id}\n    {c.title}\n    covers: {c.covers}")
        return 0
    asyncio.run(_checks(args))
    return 0


def cmd_levels(args) -> int:
    from forge.levels import parse_zones, render_summary, run_levels
    res = run_levels(load_settings(), args.slug, zones=parse_zones(args.zones) if args.zones else None,
                     stages_per_zone=args.stages_per_zone, total_zones=args.total_zones)
    print(render_summary(res))
    return 0 if res["ok"] else 1


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


# ---------------------------------------------------------------- orchestrate / gaps

def cmd_orchestrate(args) -> int:
    from forge.orchestrator import Options, Orchestrator
    _sigterm_as_interrupt()
    studios = [x.strip() for x in (args.studio or os.environ.get("FORGE_STUDIO") or "").split(",") if x.strip()]
    use_studio = not args.no_studio and bool(studios)
    if not args.no_studio and not studios:
        print("no --studio place given (and FORGE_STUDIO unset): running compile-only (--no-studio)")
    opts = Options(goal=args.goal, workers=args.workers, studios=studios, use_studio=use_studio,
                   max_calls=args.max_calls, minutes=args.minutes, rounds=args.rounds, per_round=args.per_round,
                   min_rank=args.min_rank, checks=not args.no_checks, fix_cycle=not args.no_fix_cycle)
    res = Orchestrator(load_settings(), args.slug, opts).run()
    b, a = res["before"], res["after"]
    print(f"\n{args.slug}: {res['stop_reason']}")
    print(f"  critic {b['critic']} -> {a['critic']}   forge done {b['ready']} -> {a['ready']}   "
          f"{res['budget']['calls_used']} Mubit calls, {res['budget']['minutes_used']} min")
    for r in res["rounds"]:
        print(f"  round {r['round']}: {len(r['jobs'])} jobs "
              f"({sum(1 for j in r['jobs'] if j['status'] == 'done')} done), critic {r['score']['critic']}")
    return 0 if a["target_met"] else 1


def cmd_autopilot(args) -> int:
    """`forge autopilot`: idea -> ready game, one self-driving loop (forge/autopilot.py)."""
    from forge import autopilot as apm
    s = load_settings()
    if args.correct:
        item, note = args.correct
        slug = args.target or apm.find_run_with(s, item)
        if not slug:
            print(f"error: no autopilot run has a decision {item!r} (pass the slug first)", file=sys.stderr)
            return 1
        rec = apm.correct(s, slug, item, note, goal=args.goal)
        print(f"correction on {slug}/{rec['id']} -> Mubit task {rec.get('role')} (request {rec.get('request_id')}); "
              f"{rec['id']} will not be proposed again")
        return 0
    if args.advise:
        root = Path(args.root) if args.root else s.base_game_dir
        place = None
        if args.fresh:
            place = (args.studio or os.environ.get("FORGE_STUDIO") or "").split(",")[0].strip()
            if not place:
                print("error: --fresh needs --studio Forge-agents-<N> (your own place)", file=sys.stderr)
                return 2
        rep = apm.advise(s, root, name=args.name, goal=args.goal, extra_dirs=[Path(p) for p in args.evidence],
                         fresh_place=place, qa_steps=args.qa_steps, swarm_players=args.swarm_players,
                         swarm_minutes=args.swarm_minutes)
        print((Path(rep["out_dir"]) / "report.md").read_text(encoding="utf-8"))
        print(f"report: {rep['out_dir']}/report.md")
        return 0
    if not args.target:
        print("error: give an idea (new game) or a slug, or --advise --root DIR", file=sys.stderr)
        return 2
    if args.status:
        st = apm._read(s.runs_dir / args.target / "autopilot" / "status.json", {}) or {}
        print(json.dumps({k: st.get(k) for k in ("state", "round", "phase", "budget", "stop_reason", "current")},
                         indent=1))
        print(apm.render_rounds(st.get("rounds") or []))
        return 0
    _sigterm_as_interrupt()
    studios = [x.strip() for x in (args.studio or os.environ.get("FORGE_STUDIO") or "").split(",") if x.strip()]
    use_studio = not args.no_studio and bool(studios)
    if not args.no_studio and not studios:
        print("no --studio place given (and FORGE_STUDIO unset): measuring headless only (--no-studio)")
    opts = apm.AutoOptions(goal=args.goal, studios=studios, use_studio=use_studio, max_calls=args.max_calls,
                           minutes=args.minutes, rounds=args.rounds, per_round=args.per_round, min_rank=args.min_rank,
                           target=args.target_score, workers=args.workers, qa_steps=args.qa_steps,
                           swarm_players=args.swarm_players, swarm_minutes=args.swarm_minutes,
                           critic=not args.no_critic, make_iterations=args.make_iterations, polish=args.polish)
    res = apm.Autopilot(s, args.target, opts).run()
    print(f"\n{res['slug']}: {res['stop_reason']}  ({res['budget']['calls_used']} Mubit calls, "
          f"{res['budget']['minutes_used']} min)")
    print(apm.render_rounds(res["rounds"] or []))
    return 0


def cmd_gaps(args) -> int:
    from forge import gaps
    from forge.llm import make_llm
    s = load_settings()
    if args.find or args.correct:
        llm = make_llm(s, log_path=gaps.orch_dir(s, args.slug) / "calls.jsonl")
        if args.correct:
            rec = gaps.correct_gaps(s, args.slug, args.correct, llm=llm, goal=args.goal, reject=args.reject)
        else:
            rec = gaps.find_gaps(s, args.slug, llm=llm, goal=args.goal)
    else:
        rec = gaps.latest(s, args.slug)
        if rec is None:
            print(f"no gap list for {args.slug} yet: forge gaps {args.slug} --find")
            return 0
    print(json.dumps(rec, indent=1) if args.json else gaps.render(rec))
    return 0


def cmd_queue(args) -> int:
    from forge.orchestrator import queue_view
    print(queue_view(load_settings(), args.slug))
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

# ---------------------------------------------------------------- Studio plugin bridge

def cmd_plugin(args) -> int:
    from forge import bridge as fb
    s = load_settings()
    root = s.repo_root
    args.port = args.port or fb.DEFAULT_PORT
    places = args.place or ([os.environ["FORGE_STUDIO"]] if os.environ.get("FORGE_STUDIO") else [])
    if args.action in ("install", "build", "serve") and not places:
        print(f"error: name the place(s) the plugin may bind to: forge plugin {args.action} --place Forge-agents-25",
              file=sys.stderr)
        return 2
    if args.action == "install":
        out = fb.install_plugin(root, places, Path(args.plugins_dir) if args.plugins_dir else None, args.port)
        print(f"installed {out} (binds only: {', '.join(places)})")
        print("It does nothing until `forge plugin serve --place <PlaceName>` is running for that place.")
        return 0
    if args.action == "build":
        out = Path(args.out or fb.store_dir(root) / "ForgeBridge.lua")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(fb.build_plugin(root, fb.load_token(fb.store_dir(root)), args.port, places))
        print(f"built {out}")
        return 0
    if args.action == "serve":
        if not places:
            print("error: name the place(s) to bind: forge plugin serve --place Forge-agents-25", file=sys.stderr)
            return 2
        fb.serve_forever(root, places, args.port, args.scenario)
        return 0
    if args.action == "status":
        try:
            print(json.dumps(fb.BridgeClient(args.port).status(), indent=1))
        except fb.BridgeError as e:
            print(f"bridge not running: {e}")
            return 1
        return 0
    if args.action == "events":
        client, since = fb.BridgeClient(args.port), args.since
        while True:
            res = client.events(since, None, 200, 15 if args.follow else 0)
            for e in res["events"]:
                print(fb._fmt_event(e), flush=True)
            since = res["next"]
            if not args.follow:
                return 0
    if args.action == "load":
        return asyncio.run(_plugin_load(s, args))
    if args.action == "bench":
        return asyncio.run(_plugin_bench(s, args))
    return 2


async def _plugin_load(s, args) -> int:
    """Live-load the plugin into ONE Studio window over StudioMCP (no file in the Plugins folder)."""
    from forge import bridge as fb
    from forge.studio import Studio
    places = args.place or [args.studio]
    src = fb.build_plugin(s.repo_root, fb.load_token(fb.store_dir(s.repo_root)), args.port, places)
    code = "local plugin = PluginManager():CreatePlugin()\n" + src + "\nreturn 'ForgeBridge loaded'"
    async with Studio(s, call_timeout=45) as st:
        await st.select(args.studio)
        state = await st.state()
        dms = ["Server", "Client"] if state.get("playing") else ["Edit"]
        for dm in dms:
            print(f"{dm}: {await st.execute_luau(code, dm)}")
    return 0


async def _plugin_bench(s, args) -> int:
    """Round-trip latency of the same tiny Luau call: bridge vs StudioMCP execute_luau."""
    import statistics
    import time as _t

    from forge import bridge as fb
    from forge.studio import Studio
    client = fb.BridgeClient(args.port)
    code = "return 1 + 1"
    rows = {}
    bridge_ms = []
    for _ in range(args.n):
        t0 = _t.perf_counter()
        client.luau(code, args.datamodel)
        bridge_ms.append((_t.perf_counter() - t0) * 1000)
    rows["bridge"] = bridge_ms
    t0 = _t.perf_counter()
    async with Studio(s, call_timeout=45) as st:
        await st.select(args.studio)
        rows["mcp_connect"] = [(_t.perf_counter() - t0) * 1000]
        mcp_ms = []
        for _ in range(args.n):
            t1 = _t.perf_counter()
            await st.call("execute_luau", code=code, datamodel_type=args.datamodel)
            mcp_ms.append((_t.perf_counter() - t1) * 1000)
        rows["studiomcp"] = mcp_ms
    for name, xs in rows.items():
        print(f"{name:12s} n={len(xs):3d}  median {statistics.median(xs):8.1f} ms  "
              f"min {min(xs):8.1f}  max {max(xs):8.1f}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="forge", description="Idea -> Roblox game, every LLM call through Mubit.")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("doctor", help="check key, luau-compile, StudioMCP, studios")

    n = sub.add_parser("new", help="design + build + playtest loop")
    n.add_argument("idea")
    n.add_argument("--iterations", "-n", type=int, default=3)
    n.add_argument("--no-studio", action="store_true", help="compile-check only, no Studio MCP")
    n.add_argument("--no-director", action="store_true", help="skip the game director (designer only)")
    _speed_args(n)

    di = sub.add_parser("direct", help="dry run: director design doc + designer spec, no build")
    di.add_argument("idea")
    di.add_argument("--compare", action="store_true", help="also run the plain designer and print before/after")
    di.add_argument("--json", action="store_true")

    fu = sub.add_parser("fun", help="fun critic on a game's current code + latest playtest evidence")
    fu.add_argument("slug")

    r = sub.add_parser("run", help="continue iterating an existing game")
    r.add_argument("slug")
    r.add_argument("--iterations", "-n", type=int, default=3)
    r.add_argument("--no-studio", action="store_true")
    _speed_args(r)

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

    bi = sub.add_parser("bench-io", help="time Studio round trips (sync, play, stop, edits, checks): before vs after")
    bi.add_argument("slug", nargs="?")
    bi.add_argument("--root", help="game folder (default game/); benchmarked on a temp copy")
    bi.add_argument("--studio", help="pick the Studio whose name contains this (use your own window)")
    bi.add_argument("--offline", action="store_true", help="only the headless rows (no Studio)")
    bi.add_argument("--repeat", type=int, default=3)
    bi.add_argument("--json", help="also write the raw timings here")

    hl = sub.add_parser("headless", help="boot a game's server with the luau CLI (no Studio) and run its checks")
    hl.add_argument("slug", nargs="?")
    hl.add_argument("--root", help="game folder (default game/)")
    hl.add_argument("--play", type=float, default=3.0, help="simulated seconds after a player joins")
    hl.add_argument("--players", type=int, default=1, help="simulated players (each a client running its LocalScripts)")
    hl.add_argument("--no-clients", action="store_true", help="server only: no LocalScripts")
    hl.add_argument("--playtest", action="store_true",
                    help="the build loop's headless playtest (probe report + scene census) instead of a boot")
    hl.add_argument("--stats", action="store_true",
                    help="how much ran headless vs in Studio (runs/_engine_usage.jsonl), optionally for one slug")
    hl.add_argument("--since", type=float, default=0.0, help="with --stats: only the last N hours")

    pl = sub.add_parser("place", help="build a .rbxlx from a game folder (baseplate + spawn + scripts)")
    pl.add_argument("--root", help="game folder (default game/)")
    pl.add_argument("--out", default="place/Forge.rbxlx")
    pl.add_argument("--open", action="store_true", help="open it in Roblox Studio")

    py = sub.add_parser("play", help="AI playtest the open Studio game toward a goal (markdown report)")
    py.add_argument("goal")
    py.add_argument("--steps", type=int, default=20)
    py.add_argument("--studio", help="pick the Studio whose name contains this")

    qa = sub.add_parser("qa", help="QA protocol: plan, step-by-step checks + screenshots, investigate, report")
    qa.add_argument("focus", nargs="?", help="what to test first (default: the whole acceptance list)")
    qa.add_argument("--root", help="game folder whose ../spec.json is the spec (default game/)")
    qa.add_argument("--steps", type=int, default=12, help="max plan steps")
    qa.add_argument("--studio", help="pick the Studio whose name contains this")
    qa.add_argument("--keep-playing", action="store_true", help="don't stop the playtest at the end")

    pc = sub.add_parser("play-correct", help="correct the playtester's choice at one step (Mubit signal)")
    pc.add_argument("run_id")
    pc.add_argument("step", type=int)
    pc.add_argument("note", help="what it should have done")

    sub.add_parser("play-list", help="list past playtest runs")
    from forge.assets import add_cli_parser as _add_assets_parser
    _add_assets_parser(sub)
    from forge.bench import add_cli_parser as _add_bench_parser
    _add_bench_parser(sub)
    from forge.compare import add_cli_parser as _add_compare_parser
    _add_compare_parser(sub)
    from forge.consolidate import add_cli_parser as _add_consolidate_parser
    _add_consolidate_parser(sub)
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
    im.add_argument("--goal", default=None, help="tester goal (default: built from the game's spec)")
    im.add_argument("--cycles", type=int, default=1)
    im.add_argument("--rounds", type=int, default=3, help="playtest rounds before the audit")
    im.add_argument("--steps", type=int, default=15, help="AI player steps per round")
    im.add_argument("--players", type=int, default=None)
    im.add_argument("--only", help="comma-separated fault ids (default: every default fault)")
    im.add_argument("--faults-file", help="faults JSON (default forge/faults/<slug>.json)")
    im.add_argument("--studio", help="Studio name part (default FORGE_STUDIO)")
    im.add_argument("--fix", action="store_true", help="also fix real (non-planted) anomalies in code")
    _speed_args(im)

    fx = sub.add_parser("fix", help="playtest -> auditor -> fix real anomalies in code -> verify, until clean")
    fx.add_argument("slug")
    fx.add_argument("--goal", default=None, help="tester goal (default: built from the game's spec)")
    fx.add_argument("--cycles", type=int, default=3, help="stop early once nothing high/medium is open")
    fx.add_argument("--rounds", type=int, default=2, help="playtest rounds before each audit")
    fx.add_argument("--steps", type=int, default=15)
    fx.add_argument("--players", type=int, default=None)
    fx.add_argument("--max-fixes", type=int, default=3, help="anomalies to fix per cycle")
    fx.add_argument("--reports", action="store_true", help="also fix anomalies from new tester reports")
    fx.add_argument("--studio", help="Studio name part or id (default FORGE_STUDIO)")
    fx.add_argument("--start-round", action="store_true",
                    help="start each test round inside the game (harness `round` command), not in the lobby")
    fx.add_argument("--round-seconds", type=int, default=None, help="length of the started round")
    fx.add_argument("--edit-human-files", action="store_true",
                    help="let the fixer edit a seeded game's human files (in runs/<slug>/game only)")
    fx.add_argument("--no-repro", action="store_true",
                    help="old loop: no reproducer checks; the verifier alone judges each fix")
    _speed_args(fx)

    db = sub.add_parser("dashboard", help="live view of jobs, games, fix cycles, versions and Mubit calls")
    db.add_argument("--port", type=int, default=8765)
    db.add_argument("--host", default="127.0.0.1", help="0.0.0.0 to share on your network")
    db.add_argument("--open", action="store_true", help="open it in the browser")

    ar = sub.add_parser("archive", help="copy the record of a game's improvement (cycles, traces, versions) to evidence/")
    ar.add_argument("slugs", nargs="*", help="games (default: every game with improve cycles)")
    ar.add_argument("--out", help="folder (default evidence/ in the repo)")

    fe = sub.add_parser("feature", help="the agent adds a feature to an existing game (plan, build, playtest)")
    fe.add_argument("slug")
    fe.add_argument("request", help="the feature, in plain words")
    fe.add_argument("--iterations", "-n", type=int, default=1, help="playtest/critic/fix rounds after building")
    fe.add_argument("--polish", type=int, default=0,
                    help="then N end-to-end cycles: AI testers in a round, auditor vs acceptance, fix, verify")
    fe.add_argument("--no-studio", action="store_true")
    _speed_args(fe)

    po = sub.add_parser("polish", help="end-to-end cycles on a game's latest feature (testers in a round, auditor vs acceptance, fix, verify)")
    po.add_argument("slug")
    po.add_argument("--cycles", type=int, default=3)

    pg = sub.add_parser("promote-game", help="copy a finished agent-built game into games/<slug>/ (code, spec, README)")
    pg.add_argument("slug")

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

    lg = sub.add_parser("ledger", help="what Forge fed Mubit: calls, corrections and proved fixes per task")
    lg.add_argument("--json", action="store_true")
    lg.add_argument("--recent", type=int, default=12)

    rf = sub.add_parser("reflect", help="reflection since the last one: what ran, kept / rolled back, calls, tokens "
                                        "and time by role and stage, cache hits, failures by cause, weaknesses")
    rf.add_argument("slug", nargs="?")
    rf.add_argument("--all", action="store_true", help="every game's whole record, summed into runs/reflection.md")
    rf.add_argument("--llm", action="store_true",
                    help="also send the findings to the reflector (one Mubit call), which updates runs/lessons.md")

    dn = sub.add_parser("done", help="is the game ready? checks pass, features verified, nothing open, critic bar")
    dn.add_argument("slug")
    dn.add_argument("--json", action="store_true")

    ck = sub.add_parser("checks", help="scenario designer: plan executable checks from the spec, run them live")
    ck.add_argument("slug")
    ck.add_argument("--plan", action="store_true", help="generate a test plan (scenarist) into runs/<slug>/checks/")
    ck.add_argument("--run", action="store_true", help="play, run every check, review failures, stop play")
    ck.add_argument("--max", type=int, default=15, help="most checks to plan")
    ck.add_argument("--studio", help="Studio name part or id (default FORGE_STUDIO)")
    ck.add_argument("--no-sync", action="store_true",
                    help="run against what is already in Studio (default: sync the game on disk first)")
    ck.add_argument("--headless-first", action="store_true",
                    help="with --run: run checks headless first (checks.triage); only the rest go to Studio")

    lv = sub.add_parser("levels", help="obby level designer (Mubit): stages as data, zone by zone, every jump validated")
    lv.add_argument("slug")
    lv.add_argument("--zones", help="zones to design, e.g. 1-10 or 3 (default: every planned zone); valid ones are skipped")
    lv.add_argument("--stages-per-zone", type=int, default=None, help="stages per zone (default 20, or the game's)")
    lv.add_argument("--total-zones", type=int, default=None,
                    help="zones the whole course will have, for the difficulty curve (default: the end of --zones)")

    pg_ = sub.add_parser("plugin", help="ForgeBridge Studio plugin: install, serve the bridge, status, events, bench")
    pg_.add_argument("action", choices=["install", "build", "serve", "status", "events", "load", "bench"])
    pg_.add_argument("--port", type=int, default=None, help="bridge port (default 34880 / FORGE_BRIDGE_PORT)")
    pg_.add_argument("--place", action="append", help="install/build/serve: place name the plugin may bind to (repeatable; default FORGE_STUDIO)")
    pg_.add_argument("--plugins-dir", help="install: Studio Plugins folder (default ~/Documents/Roblox/Plugins)")
    pg_.add_argument("--out", help="build: output file")
    pg_.add_argument("--scenario", default="smoke", help="serve: scenario the Run tests button runs")
    pg_.add_argument("--studio", help="load/bench: Studio name part or id")
    pg_.add_argument("--since", type=int, default=0, help="events: start after this seq")
    pg_.add_argument("--follow", action="store_true", help="events: keep streaming")
    pg_.add_argument("-n", type=int, default=20, help="bench: calls per path")
    pg_.add_argument("--datamodel", default="Edit", help="bench: Edit/Server/Client")

    sc = sub.add_parser("scores", help="per-cycle improve scores for a game")
    sc.add_argument("slug")

    oc = sub.add_parser("orchestrate", help="team lead: gap finder (Mubit) -> job queue -> workers with "
                                            "Studio/LLM leases -> verify -> re-score, until forge done + critic >= 8")
    oc.add_argument("slug")
    oc.add_argument("--goal", default="", help="what 'good' means for this game (goes to the gap finder)")
    oc.add_argument("--workers", type=int, default=4, help="parallel workers (LLM jobs run in parallel)")
    oc.add_argument("--studio", help="place window(s) for Studio jobs, comma separated (default FORGE_STUDIO)")
    oc.add_argument("--no-studio", action="store_true", help="compile-only: no Studio jobs")
    oc.add_argument("--max-calls", type=int, default=300, help="Mubit call budget (all roles)")
    oc.add_argument("--minutes", type=float, default=120, help="wall-clock budget")
    oc.add_argument("--rounds", type=int, default=3, help="gap-find -> build -> verify rounds")
    oc.add_argument("--per-round", type=int, default=4, help="gaps turned into build jobs per round")
    oc.add_argument("--min-rank", type=float, default=2.0, help="ignore gaps ranked below this (impact x confidence)")
    oc.add_argument("--no-checks", action="store_true", help="skip the executable-checks job each round")
    oc.add_argument("--no-fix-cycle", action="store_true", help="skip the AI-tester fix cycle each round")

    au = sub.add_parser("autopilot", help="self-driving loop: idea -> forge new -> observe (logs, probes, testers) -> "
                                          "Mubit anomaly detector + gap finder -> jobs -> verify/rollback -> learn")
    au.add_argument("target", nargs="?", help="an idea (builds a new game) or an existing slug")
    au.add_argument("--goal", default="", help="what 'good' means (goes to the detector and gap finder)")
    au.add_argument("--studio", help="place window(s) for Studio work, comma separated (default FORGE_STUDIO)")
    au.add_argument("--no-studio", action="store_true", help="headless measurements only")
    au.add_argument("--max-calls", type=int, default=250, help="Mubit call budget (all roles, all sessions)")
    au.add_argument("--minutes", type=float, default=120, help="wall-clock budget (all sessions)")
    au.add_argument("--rounds", type=int, default=4, help="observe -> act -> verify rounds this session")
    au.add_argument("--per-round", type=int, default=3, help="jobs picked per round")
    au.add_argument("--min-rank", type=float, default=2.0, help="skip candidates scored below this")
    au.add_argument("--target", dest="target_score", type=float, default=8.0, help="critic and fun score to reach")
    au.add_argument("--workers", type=int, default=3)
    au.add_argument("--qa-steps", type=int, default=4, help="steps of the focused QA run per measurement (0: off)")
    au.add_argument("--swarm-players", type=int, default=2, help="testers in the short swarm (0: off)")
    au.add_argument("--swarm-minutes", type=float, default=1.0)
    au.add_argument("--no-critic", action="store_true", help="no critic / fun critic in measurements")
    au.add_argument("--make-iterations", type=int, default=0, help="forge new iterations when building from an idea")
    au.add_argument("--polish", type=int, default=0, help="forge feature --polish N for feature/visual jobs")
    au.add_argument("--status", action="store_true", help="print the run's state and round table")
    au.add_argument("--correct", nargs=2, metavar=("ID", "NOTE"), help="correct one decision (Mubit correction)")
    au.add_argument("--advise", action="store_true", help="read-only report on a human-built game (no edits)")
    au.add_argument("--root", help="--advise: the game folder (default game/)")
    au.add_argument("--name", help="--advise: the game's record name (default from forge/seeds)")
    au.add_argument("--evidence", action="append", default=[], help="--advise: extra record folders to read")
    au.add_argument("--fresh", action="store_true", help="--advise: first a short live session (probe, focused QA on "
                                                          "the old claims, short swarm) on the current build in --studio")

    gp = sub.add_parser("gaps", help="trace-driven gap list (Mubit gap_finder): what is missing or broken, ranked")
    gp.add_argument("slug")
    gp.add_argument("--find", action="store_true", help="run the gap finder now (one Mubit call)")
    gp.add_argument("--goal", default="")
    gp.add_argument("--correct", metavar="NOTE", help="correct the latest list (same Mubit task, so it learns)")
    gp.add_argument("--reject", action="append", default=[], metavar="ID", help="gap id never to propose again")
    gp.add_argument("--json", action="store_true")

    qu = sub.add_parser("queue", help="the orchestrator's job queue and leases for a game")
    qu.add_argument("slug")
    return p


def take_studio_mode(argv: list[str]) -> list[str]:
    """`--studio auto|always|never` (or --studio=MODE), on any command, sets the Studio policy
    (FORGE_STUDIO_MODE, inherited by every subprocess; see forge/headless.py). It is taken out of argv
    here; `--studio <place name>` is left for the commands that pick a Studio window."""
    from forge.headless import STUDIO_MODES

    out, i = [], 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--studio=") and a.split("=", 1)[1].lower() in STUDIO_MODES:
            os.environ["FORGE_STUDIO_MODE"] = a.split("=", 1)[1].lower()
        elif a == "--studio" and i + 1 < len(argv) and argv[i + 1].lower() in STUDIO_MODES:
            os.environ["FORGE_STUDIO_MODE"] = argv[i + 1].lower()
            i += 1
        else:
            out.append(a)
        i += 1
    return out


def main(argv: list[str] | None = None) -> int:
    # Progress lines reach a piped log (tee, runs/*.log, the dashboard) as they happen.
    with contextlib.suppress(AttributeError, ValueError):
        sys.stdout.reconfigure(line_buffering=True)
    argv = take_studio_mode(list(sys.argv[1:] if argv is None else argv))
    args = build_parser().parse_args(argv)
    _apply_speed_args(args)
    from forge.bench import cmd_bench
    from forge.compare import cmd_compare
    from forge.consolidate import cmd_consolidate
    handler = {"doctor": cmd_doctor, "bench": cmd_bench, "compare": cmd_compare, "consolidate": cmd_consolidate,
               "new": cmd_new, "run": cmd_run,
               "correct": cmd_correct, "status": cmd_status, "watch": cmd_watch, "sync": cmd_sync,
               "bench-io": cmd_bench_io, "headless": cmd_headless,
               "place": cmd_place, "seed": cmd_seed, "promote": cmd_promote,
               "improve": cmd_improve, "scores": cmd_scores, "done": cmd_done, "checks": cmd_checks, "direct": cmd_direct, "fun": cmd_fun, "ledger": cmd_ledger, "reflect": cmd_reflect, "server": cmd_server, "fix": cmd_fix, "promote-game": cmd_promote_game, "polish": cmd_polish, "feature": cmd_feature, "archive": cmd_archive, "dashboard": cmd_dashboard, "versions": cmd_versions,
               "rollback": cmd_rollback, "report": cmd_report,
               "reports": cmd_reports, "play": cmd_play, "qa": cmd_qa, "play-correct": cmd_play_correct,
               "play-list": cmd_play_list, "assets": cmd_assets, "test": cmd_test, "mcp": cmd_mcp,
               "orchestrate": cmd_orchestrate, "autopilot": cmd_autopilot, "gaps": cmd_gaps, "queue": cmd_queue,
               "plugin": cmd_plugin, "levels": cmd_levels}[args.cmd]
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
