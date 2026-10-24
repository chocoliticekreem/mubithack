"""`forge bench-io`: time every Studio round trip Forge makes, the old way vs the fast way.

Works on a throwaway copy of the game folder (your files are never edited) and prints one table:

  step                         before      after   speedup
  sync, nothing changed        271 ms      70 ms     3.9x
  ...

"before" is the original I/O path (a fresh StudioMCP session per call, every file fetched over HTTP
on every sync, play/stop polled once a second, stop -> sync -> play to try a code change, Studio for
every check). "after" is the current one (one session, hashed incremental sync in a single call,
in-Studio readiness wait, hot reload, headless boot and checks). With --offline only the headless
rows run (no Studio needed).
"""

from __future__ import annotations

import asyncio
import json
import shutil
import statistics
import tempfile
import time
from pathlib import Path
from typing import Any, Awaitable, Callable

from forge import checks as fchecks
from forge import sync as fsync
from forge.config import Settings, load_settings

ROW_ORDER = [
    "StudioMCP session per call",
    "sync, nothing changed",
    "sync, one file changed",
    "play until game ready",
    "stop until back in Edit",
    "try a server code change",
    "boot smoke test (errors after start)",
    "run one logic check",
]

READY_POLL_LUAU = """
local Players = game:GetService("Players")
local char = false
for _, p in Players:GetPlayers() do
	if p.Character and p.Character:FindFirstChild("HumanoidRootPart") then char = true end
end
local probe = game:GetService("ServerStorage"):FindFirstChild("ForgeProbe") ~= nil
return tostring(probe and (workspace:GetAttribute("ServerBooted") == true or char))
"""

SMOKE_CHECK = """-- check: a player joined and the server is up
-- covers: bench-io smoke
local Players = game:GetService("Players")
return { ok = #Players:GetPlayers() >= 1, detail = "players " .. #Players:GetPlayers() }
"""


async def _time(fn: Callable[[], Awaitable[Any]]) -> tuple[float, Any]:
    t = time.perf_counter()
    out = await fn()
    return time.perf_counter() - t, out


def _ms(x: float | None) -> str:
    return "-" if x is None else (f"{x * 1000:.0f} ms" if x < 10 else f"{x:.1f} s")


def table(rows: dict[str, dict]) -> str:
    """rows: {step: {"before": s|None, "after": s|None, "note": str}} -> aligned text table."""
    lines = [f"{'step':38s} {'before':>10s} {'after':>10s} {'speedup':>9s}  note"]
    lines.append("-" * 90)
    for name in ROW_ORDER + [k for k in rows if k not in ROW_ORDER]:
        r = rows.get(name)
        if not r:
            continue
        b, a = r.get("before"), r.get("after")
        sp = f"{b / a:.1f}x" if b and a else "-"
        lines.append(f"{name:38s} {_ms(b):>10s} {_ms(a):>10s} {sp:>9s}  {r.get('note', '')}")
    return "\n".join(lines)


def _median(xs: list[float]) -> float:
    return statistics.median(xs) if xs else 0.0


def _pick_module(root: Path) -> str | None:
    """A server ModuleScript that hot reload accepts (for the edit rows)."""
    from forge.studio import hot_reload_plan

    entries = fsync.manifest_entries(root)
    paths = [e["path"] for e in entries]
    sources = {p: (root / p).read_text(encoding="utf-8", errors="replace") for p in paths}
    plan = hot_reload_plan(entries, paths, sources)
    return plan["reload"][0]["path"] if plan["reload"] else None


def _touch(root: Path, rel: str, n: int) -> None:
    p = root / rel
    p.write_text(p.read_text(encoding="utf-8") + f"\n-- bench-io edit {n}\n", encoding="utf-8")


def bench_offline(root: Path, rows: dict[str, dict], repeat: int = 3) -> None:
    if not fchecks.headless_available():
        rows["boot smoke test (errors after start)"] = {"note": "luau CLI missing: skipped"}
        return
    boots = []
    rep: dict = {}
    for _ in range(repeat):
        t = time.perf_counter()
        rep = fchecks.boot_offline(root, boot=2, play=3)
        boots.append(time.perf_counter() - t)
    rows.setdefault("boot smoke test (errors after start)", {}).update(
        after=_median(boots), note=f"headless: {len(rep.get('errors') or [])} errors, "
                                   f"{len(rep.get('misses') or [])} fake-engine gaps")
    check = fchecks.parse(SMOKE_CHECK, "bench-smoke")
    runs = []
    res: dict = {}
    for _ in range(repeat):
        t = time.perf_counter()
        res = fchecks.run_check_offline(root, check)
        runs.append(time.perf_counter() - t)
    rows.setdefault("run one logic check", {}).update(
        after=_median(runs), note=f"headless check {'passed' if res.get('ok') else 'FAILED: ' + str(res.get('error') or res.get('detail'))[:40]}")


async def bench_studio(settings: Settings, root: Path, studio_name: str | None, rows: dict[str, dict],
                       repeat: int = 3, play_seconds: float = 3.0) -> None:
    from forge.studio import Studio

    port = 0  # a free port: never collide with another agent's sync server
    # ---- session per call vs one session
    fresh = []
    for _ in range(repeat):
        t = time.perf_counter()
        async with Studio(settings) as s:
            await s.select(studio_name)
            await s.execute_luau("return 1", "Edit")
        fresh.append(time.perf_counter() - t)
    async with Studio(settings) as studio:
        sid = await studio.select(studio_name)
        reuse = []
        for _ in range(repeat):
            dt, _ = await _time(lambda: studio.execute_luau("return 1", "Edit"))
            reuse.append(dt)
        rows["StudioMCP session per call"] = {"before": _median(fresh), "after": _median(reuse),
                                              "note": "spawn+init+select+call vs call on a kept session"}
        await studio.stop()

        # ---- sync
        await studio.sync(root, port, prune=True)  # warm: both paths start from an up-to-date place
        full, inc = [], []
        for _ in range(repeat):
            dt, out = await _time(lambda: studio.sync(root, port, prune=True, incremental=False))
            full.append(dt)
            dt, out_inc = await _time(lambda: studio.sync(root, port, prune=True))
            inc.append(dt)
        n_files = len(fsync.manifest_entries(root))
        rows["sync, nothing changed"] = {"before": _median(full), "after": _median(inc),
                                         "note": f"{n_files} files; {str(out_inc).split(';')[-1].strip()}"}
        target = _pick_module(root) or fsync.manifest_entries(root)[0]["path"]
        full, inc = [], []
        for i in range(repeat):
            _touch(root, target, i * 2)
            dt, _ = await _time(lambda: studio.sync(root, port, prune=True, incremental=False))
            full.append(dt)
            # the legacy sync didn't record what it pushed; re-push to resync the incremental record
            await studio.sync(root, port, prune=True)
            _touch(root, target, i * 2 + 1)
            dt, _ = await _time(lambda: studio.sync(root, port, prune=True))
            inc.append(dt)
        rows["sync, one file changed"] = {"before": _median(full), "after": _median(inc),
                                          "note": f"edited {Path(target).name}"}

        # ---- play / stop
        legacy_play, fast_play, legacy_stop, fast_stop = [], [], [], []
        ready: dict = {}

        async def legacy_play_until_ready() -> None:
            # the old way: play(), then ask "is the game up?" from Python once a second
            await studio.play(ready=False)
            for _ in range(60):
                if "true" in await studio.execute_luau(READY_POLL_LUAU, "Server"):
                    return
                await asyncio.sleep(1.0)

        for _ in range(max(1, repeat - 1)):
            studio.poll_interval = 1.0
            dt, _ = await _time(legacy_play_until_ready)
            legacy_play.append(dt)
            dt, _ = await _time(studio.stop)
            legacy_stop.append(dt)
            studio.poll_interval = None
            dt, ready = await _time(lambda: studio.play(ready=True))
            fast_play.append(dt)
            dt, _ = await _time(studio.stop)
            fast_stop.append(dt)
        rows["play until game ready"] = {
            "before": _median(legacy_play), "after": _median(fast_play),
            "note": f"1 s polls vs one in-Studio wait ({ready.get('reason', '?')}); start_stop_play alone ~2 s"}
        rows["stop until back in Edit"] = {"before": _median(legacy_stop), "after": _median(fast_stop),
                                           "note": "1 s vs 0.1 s state polls; start_stop_play alone ~1 s"}

        # ---- try a code change: stop -> sync -> play vs hot reload
        await studio.sync(root, port, prune=True)
        await studio.play(ready=True)
        cycle, hot = [], []
        hot_note = ""
        for i in range(repeat):
            _touch(root, target, 100 + i)
            dt, res = await _time(lambda: studio.hot_reload(root))
            if res.get("reloaded") and not res.get("restart"):
                hot.append(dt)
                hot_note = f"reloaded {Path(target).name}"
            else:
                hot_note = "hot reload FAILED: " + json.dumps(res.get("restart"))[:60]
        await studio.stop()
        for i in range(max(1, repeat - 1)):
            _touch(root, target, 200 + i)
            studio.poll_interval = 1.0

            async def old_cycle() -> None:
                await studio.stop()
                await studio.sync(root, port, prune=True, incremental=False)
                await studio.play(ready=False)

            dt, _ = await _time(old_cycle)
            cycle.append(dt)
            studio.poll_interval = None
            await studio.stop()
        rows["try a server code change"] = {"before": _median(cycle), "after": _median(hot) if hot else None,
                                            "note": f"stop+sync+play vs hot_reload: {hot_note}"}

        # ---- smoke test and one check in Studio (the "before" of the headless rows)
        smoke, check_runs = [], []
        check = fchecks.parse(SMOKE_CHECK, "bench-smoke")
        for _ in range(max(1, repeat - 1)):
            studio.poll_interval = 1.0

            async def studio_smoke() -> Any:
                await studio.sync(root, port, prune=True, incremental=False)
                await studio.play(ready=False)
                await asyncio.sleep(play_seconds)  # the loop's fixed wait (FORGE_PLAY_SECONDS)
                rep = await studio.probe_report()
                await studio.stop()
                return rep

            dt, _ = await _time(studio_smoke)
            smoke.append(dt)

            async def studio_check() -> Any:
                await studio.sync(root, port, prune=True, incremental=False)
                await studio.play(ready=False)
                await asyncio.sleep(play_seconds)
                res = await fchecks.run_check(studio, check)
                await studio.stop()
                return res

            dt, _ = await _time(studio_check)
            check_runs.append(dt)
            studio.poll_interval = None
        rows.setdefault("boot smoke test (errors after start)", {})["before"] = _median(smoke)
        rows.setdefault("run one logic check", {})["before"] = _median(check_runs)
        await studio.stop()
        rows["_studio"] = {"note": str(sid)}


def bench(game_root: Path, studio_name: str | None = None, offline: bool = False, repeat: int = 3,
          settings: Settings | None = None, out_json: Path | None = None) -> str:
    settings = settings or load_settings()
    rows: dict[str, dict] = {}
    with tempfile.TemporaryDirectory(prefix="forge-bench-io-") as tmp:
        root = Path(tmp) / "game"
        shutil.copytree(Path(game_root), root, ignore=shutil.ignore_patterns("manifest.json", ".*"))
        # the current Forge runtime, as copy_base_game gives every generated game (hot reload needs it)
        probe = settings.base_game_dir / "ServerScriptService" / "ForgeProbe.server.luau"
        if probe.exists() and (root / "ServerScriptService").is_dir():
            shutil.copy2(probe, root / "ServerScriptService" / "ForgeProbe.server.luau")
        if not offline:
            asyncio.run(bench_studio(settings, root, studio_name, rows, repeat))
        bench_offline(root, rows, repeat)
    rows.pop("_studio", None)
    if out_json:
        Path(out_json).write_text(json.dumps(rows, indent=1))
    return table(rows)
