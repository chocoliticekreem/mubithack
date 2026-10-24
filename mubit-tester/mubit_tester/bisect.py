"""`bisect_versions`: find the Forge game version (forge.versions.GameVersions tag) that broke a check.

Each version is exported (git archive, no change to the game's own HEAD or files) into a scratch
folder, synced into Studio, played, and the check run against it. Binary search between a version
where the check passes (`good`, default the first) and one where it fails (`bad`, default the
latest), so 16 versions cost about 4 playtests. Afterwards the caller re-syncs the current game.

`run_at(folder) -> (ok, detail)` is injected, so tests use a fake runner and no Studio.
"""

from __future__ import annotations

import io
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path
from typing import Awaitable, Callable

Runner = Callable[[Path], Awaitable[tuple[bool, str]]]
Progress = Callable[[str], Awaitable[None]]


class BisectError(RuntimeError):
    pass


def export_version(game_dir: Path, tag: str, dest: Path) -> Path:
    """Write version `tag`'s files into `dest` (emptied first)."""
    res = subprocess.run(["git", "archive", "--format=tar", tag], cwd=game_dir, capture_output=True)
    if res.returncode != 0:
        raise BisectError(f"git archive {tag}: {res.stderr.decode(errors='replace').strip()}")
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(res.stdout)) as tar:
        tar.extractall(dest, filter="data")
    return dest


def _num(tag: str) -> int:
    return int(tag[1:])


async def bisect(game_dir: Path, tags: list[str], run_at: Runner, good: str | None = None,
                 bad: str | None = None, progress: Progress | None = None,
                 verify_ends: bool = True) -> dict:
    """-> {first_bad, last_good, tested: [{version, ok, detail}], steps}."""
    if len(tags) < 2:
        raise BisectError(f"need at least 2 versions to bisect, have {len(tags)} ({', '.join(tags) or 'none'})")
    tags = sorted(tags, key=_num)
    good = good or tags[0]
    bad = bad or tags[-1]
    for t in (good, bad):
        if t not in tags:
            raise BisectError(f"no version {t!r}; have {', '.join(tags)}")
    lo, hi = tags.index(good), tags.index(bad)
    if lo >= hi:
        raise BisectError(f"good ({good}) must be older than bad ({bad})")
    tested: dict[str, dict] = {}

    async def test(tag: str) -> bool:
        if tag in tested:
            return tested[tag]["ok"]
        if progress:
            await progress(f"testing {tag} ({len(tested) + 1} so far)")
        with tempfile.TemporaryDirectory(prefix=f"bisect-{tag}-") as tmp:
            folder = export_version(game_dir, tag, Path(tmp) / "game")
            ok, detail = await run_at(folder)
        tested[tag] = {"version": tag, "ok": bool(ok), "detail": str(detail)[:300]}
        return bool(ok)

    if verify_ends:
        if await test(tags[hi]):
            return {"first_bad": None, "last_good": tags[hi], "tested": list(tested.values()),
                    "note": f"the check passes at {tags[hi]} (the 'bad' end): nothing to bisect"}
        if not await test(tags[lo]):
            return {"first_bad": None, "last_good": None, "tested": list(tested.values()),
                    "note": f"the check already fails at {tags[lo]} (the 'good' end): pick an older good version"}
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if await test(tags[mid]):
            lo = mid
        else:
            hi = mid
    return {"first_bad": tags[hi], "last_good": tags[lo], "tested": sorted(tested.values(), key=lambda r: _num(r["version"]))}


def format_bisect(res: dict, log: list[dict], changed: list[str]) -> str:
    msgs = {r["version"]: r["message"] for r in log}
    if not res.get("first_bad"):
        out = [f"## No culprit: {res.get('note', 'inconclusive')}"]
    else:
        fb = res["first_bad"]
        first = (msgs.get(fb) or "").splitlines()[0][:160] if msgs.get(fb) else ""
        out = [f"## {fb} broke it (last good {res['last_good']})",
               f"{fb}: {first}" if first else ""]
        if changed:
            out.append("Files changed in " + fb + ": " + ", ".join(f"`{c}`" for c in changed[:12]))
        out.append(f"**Next:** read those files' diff (`git -C runs/<slug>/game diff {res['last_good']} {fb}`), "
                   f"or `rollback(slug, \"{res['last_good']}\")` with the forge tools.")
    out += ["", "| version | check | detail |", "|---|---|---|"]
    out += [f"| {r['version']} | {'PASS' if r['ok'] else 'FAIL'} | {' '.join(r['detail'].split())[:140]} |"
            for r in res.get("tested") or []]
    return "\n".join(x for x in out if x is not None)
