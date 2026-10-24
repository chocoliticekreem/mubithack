"""The scenario designer: a broad plan of executable checks derived from a game's own spec and code.

    plan_checks  spec + file map + key server code -> scenarist (Mubit task) -> checks that compile
                 -> runs/<slug>/checks/<id>.luau (an existing same-id check is never overwritten)
    run_plan     play -> run every check (reversible ones share a playtest, each `irreversible` one
                 gets a fresh playtest) -> one batched check_reviewer call (Mubit task) splits the
                 failures into game bugs and check bugs -> check bugs are rewritten once and re-run
                 (still failing: moved to checks/dropped/) -> stop -> checks/results.json
    as_anomalies game-bug failures in the auditor's anomaly shape, for the fix loop's extra_anomalies

Nothing here is specific to one game: what to test comes from the spec's acceptance list and
mechanics, and the names come from the game's own code.
"""

from __future__ import annotations

import asyncio
import json
import re
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path
from typing import Any, Callable

from forge.checks import (CONSUMER_RULE, Check, check_id, checks_dir, consumer_hits, game_sources, helpers_doc,
                          lint_setup, load_checks, run_check, save_check, setup_failure, summary, valid_consumer,
                          wrap)
from forge.config import Settings
from forge.llm import LLM, LLMError
from forge.memory import RunStore, now_iso
from forge.roles import MAX_USER_CHARS, _clip_block, _truncate

PLAN_KEYS = ["checks"]
REVIEW_KEYS = ["reviews"]
RESULTS_FILE = "results.json"
DROPPED_DIR = "dropped"
EXCERPT_CHARS = 12_000
INDEX_CHARS = 3_000
SPEC_CHARS = 5_000
PLAN_MAX_TOKENS = 16_000
REVIEW_MAX_TOKENS = 12_000
PLAYER_WAIT_S = 30.0
SETTLE_S = 3.0
SKIP_DIRS = ("tools/", "tests/")
KINDS = {"economy", "balance", "broken_link", "conflict", "error"}
SEVERITIES = {"high", "medium", "low"}


# ---------------------------------------------------------------------------------------------
# message parts


def spec_block(spec: dict, limit: int = SPEC_CHARS) -> str:
    keep: dict[str, Any] = {k: spec.get(k) for k in ("title", "pitch", "core_loop", "acceptance") if k in spec}
    keep["modules"] = [{"path": m.get("path"), "purpose": m.get("purpose")}
                       for m in spec.get("modules") or [] if isinstance(m, dict)]
    feats = [{"request": f.get("request"), "summary": (f.get("plan") or {}).get("summary")}
             for f in spec.get("features") or [] if isinstance(f, dict)]
    if feats:
        keep["features"] = feats
    return _truncate(json.dumps(keep, indent=1, ensure_ascii=False), limit, label="spec")


def _game_files(game_dir: Path) -> list[tuple[str, Path]]:
    out = []
    for p in sorted(game_dir.rglob("*.luau")):
        rel = p.relative_to(game_dir).as_posix()
        if not rel.startswith(SKIP_DIRS) and "/." not in rel and not rel.startswith("."):
            out.append((rel, p))
    return out


def file_map(game_dir: Path, limit: int = INDEX_CHARS) -> str:
    rows = []
    for rel, p in _game_files(game_dir):
        head = next((ln.strip().lstrip("-").strip()[:110] for ln in
                     p.read_text(encoding="utf-8", errors="replace").splitlines()[:6]
                     if ln.strip().startswith("--") and not ln.strip().startswith("--!")), "")
        rows.append(rel + (f"  -- {head}" if head else ""))
    return _truncate("\n".join(rows), limit, label="file map")


def _is_server_side(rel: str) -> bool:
    name = rel.rsplit("/", 1)[-1]
    return rel.startswith(("ServerScriptService/", "ReplicatedStorage/")) and not name.startswith("Forge")


def _compact_source(src: str) -> str:
    return "\n".join(ln.rstrip() for ln in src.splitlines() if ln.strip() and not ln.strip().startswith("--"))


def key_code(game_dir: Path, spec: dict, budget: int = EXCERPT_CHARS) -> str:
    """Excerpts of the server-side files (spec modules first; the Forge runtime skipped), comments and
    blank lines stripped, sharing `budget` so small files are whole and big ones keep head and tail."""
    files = {rel: p for rel, p in _game_files(game_dir) if _is_server_side(rel)}
    spec_paths = [m.get("path") for m in spec.get("modules") or [] if isinstance(m, dict)]
    order = [r for r in spec_paths if r in files] + [r for r in files if r not in spec_paths]
    sources = {r: _compact_source(files[r].read_text(encoding="utf-8", errors="replace")) for r in order}
    share: dict[str, int] = {}
    left, n = budget, len(order)
    for r in sorted(order, key=lambda r: len(sources[r])):
        share[r] = min(len(sources[r]), max(800, left // max(1, n)))
        left -= share[r]
        n -= 1
    parts = [f"### {r}\n```luau\n{_clip_block(_truncate(sources[r], share[r], keep='both', label='file'))}\n```"
             for r in order if share.get(r, 0) > 0]
    return "\n".join(parts) or "(no server files)"


def plan_message(spec: dict, index: str, code: str, existing: list[str], max_checks: int) -> str:
    tail = (f"\n\nWrite at most {max_checks} checks. Return only the JSON object.")
    head = (f"## Spec\n{spec_block(spec)}\n\n## Game files\n{index}\n\n"
            f"## Existing checks\n" + ("\n".join(f"- {t}" for t in existing) or "(none)") + "\n\n"
            f"## Check helpers\n{helpers_doc(spec)}\n\n")
    room = max(2000, MAX_USER_CHARS - len(head) - len(tail) - 40)
    return head + "## Key server code\n" + _truncate(code, room, keep="head", label="code") + tail


# ---------------------------------------------------------------------------------------------
# compiling


def luau_compiler() -> str | None:
    return shutil.which("luau-compile") or next(
        (p for p in ("/opt/homebrew/bin/luau-compile",) if Path(p).exists()), None)


def compile_error(body: str) -> str | None:
    """luau-compile's error for the wrapped body, or None if it compiles (or no compiler is installed)."""
    exe = luau_compiler()
    if not exe:
        return None
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / "check.luau"
        f.write_text(wrap(body), encoding="utf-8")
        r = subprocess.run([exe, "--null", str(f)], capture_output=True, text=True, timeout=30)
    if r.returncode == 0:
        return None
    return ((r.stderr or r.stdout).replace(str(f), "check.luau").strip() or f"exit {r.returncode}")[:600]


# ---------------------------------------------------------------------------------------------
# planning


_ORDER = re.compile(r"^(\d+)-")


def _order(cid: str) -> int:
    m = _ORDER.match(cid)
    return int(m.group(1)) if m else 0


def _base_id(cid: str) -> str:
    return _ORDER.sub("", cid, count=1)


def _to_checks(raw: Any) -> list[Check]:
    out = []
    for item in raw if isinstance(raw, list) else []:
        if not isinstance(item, dict):
            continue
        title, body = str(item.get("title") or "").strip(), str(item.get("body") or "")
        if title and "return" in body:
            out.append(Check(id=check_id(title), title=title, covers=str(item.get("covers") or "").strip(),
                             body=body.strip("\n")))
    return out


def _retry_message(user: str, broken: list[tuple[Check, str]], unproven: list[tuple[Check, str]] = ()) -> str:
    def listed_of(items: list[tuple[Check, str]], label: str) -> str:
        return "\n\n".join(f"### {c.title}\ncovers: {c.covers}\n{label}: {err}\n```luau\n{_clip_block(c.body)}\n```"
                           for c, err in items)

    parts = []
    if broken:
        parts.append(f"## Your previous checks did not compile\n{_truncate(listed_of(broken, 'Error'), 9000, label='checks')}")
    if unproven:
        parts.append("## These checks never assert their setup (keep their title, assert the situation first)\n"
                     + _truncate(listed_of(list(unproven), "Problem"), 6000, label="checks"))
    listed = "\n\n".join(parts)
    return (f"{_truncate(user, MAX_USER_CHARS - min(len(listed), 15000) - 300, label='message')}\n\n{listed}\n\n"
            "Return only the JSON object with corrected versions of these checks.")


def plan_checks(settings: Settings, slug: str, *, llm: LLM, max_checks: int = 15,
                session_id: str | None = None, log: Callable[[str], None] = print) -> list[Check]:
    """Ask the scenarist for a test plan; keep the checks that compile (one correction retry) and save
    the new ones under runs/<slug>/checks/. Returns the checks it saved."""
    store = RunStore(settings, slug)
    spec = store.load_spec()
    sid = session_id or f"scenarist-{slug}-{uuid.uuid4().hex[:8]}"
    existing = load_checks(store.dir)
    user = plan_message(spec, file_map(store.game_dir), key_code(store.game_dir, spec),
                        [c.title for c in existing], max_checks)
    obj, _ = llm.complete_json("scenarist", user, session_id=sid, required=PLAN_KEYS, max_tokens=PLAN_MAX_TOKENS)
    planned = _to_checks(obj.get("checks"))[:max_checks]
    good, broken = [], []
    for c in planned:
        err = compile_error(c.body)
        if err:
            broken.append((c, err))
        else:
            good.append(c)
    unproven = [(c, w) for c in good for w in [lint_setup(c.body)] if w]
    if broken or unproven:
        log(f"[scenarist] {len(broken)} check(s) do not compile, {len(unproven)} never assert their setup; "
            "asking for corrections")
        try:
            fixed, _ = llm.complete_json("scenarist", _retry_message(user, broken, unproven), session_id=sid,
                                         required=PLAN_KEYS, max_tokens=PLAN_MAX_TOKENS)
        except LLMError as e:
            log(f"[scenarist] correction failed: {e}")
            fixed = {}
        by_id = {c.id: i for i, c in enumerate(good)}
        for c in _to_checks(fixed.get("checks")):
            err = compile_error(c.body)
            if err:
                log(f"[scenarist] dropped {c.id}: {err.splitlines()[0][:160]}")
            elif c.id in by_id:
                good[by_id[c.id]] = c  # the corrected version of a check that never asserted its setup
            else:
                good.append(c)
        for c in good:
            if lint_setup(c.body):
                log(f"[scenarist] warning: {c.id} still never asserts its setup")
    rank = {c.id: i for i, c in enumerate(planned)}
    good.sort(key=lambda c: rank.get(c.id, len(rank)))
    have = {_base_id(c.id) for c in existing}
    n = max((_order(c.id) for c in existing), default=0)
    saved = []
    for c in good:
        if c.id in have:
            log(f"[scenarist] kept existing {c.id}")
            continue
        have.add(c.id)
        n += 1
        c.id = f"{n:02d}-{c.id}"  # checks run in file-name order, which is the plan's order
        save_check(store.dir, c)
        saved.append(c)
    log(f"[scenarist] planned {len(planned)}, saved {len(saved)} new check(s) in {checks_dir(store.dir)}")
    return saved


# ---------------------------------------------------------------------------------------------
# reviewing failures


def review_message(spec: dict, code: str, failing: list[tuple[Check, dict]],
                   game_dir: Path | None = None) -> str:
    sources = game_sources(game_dir) if game_dir else {}
    listed = "\n\n".join(
        f"### {c.id}\ntitle: {c.title}\ncovers: {c.covers}\nreturned: "
        f"{_truncate(r.get('error') or r.get('detail') or '(nothing)', 600, label='output')}\n"
        f"```luau\n{_clip_block(_truncate(c.body, 3000, keep='both', label='body'))}\n```"
        + (f"\nGame code that mentions what it asserts (line-numbered):\n{consumer_hits(game_dir, c.body, 1500, sources)}"
           if game_dir else "")
        for c, r in failing)
    listed = _truncate(listed, 16_000, label="checks")
    head = (f"## Spec\n{spec_block(spec, 3000)}\n\n## Failing checks\n{listed}\n\n"
            f"## Premise rule\n{CONSUMER_RULE}\nEvery game_bug review MUST add \"consumer\": \"<file>:<line>\" "
            "taken from the lines above; a game_bug without a real consumer is counted as a check bug.\n"
            "A check whose output says \"setup:\" never reached its situation (also in a fresh playtest) and proves "
            "nothing: rewrite it so it reaches the situation, or, when the setup itself shows a game bug (a round "
            "that never starts), rewrite it to assert that as its behaviour.\n\n"
            f"## Check helpers (for rewrites)\n{helpers_doc(spec)}\n\n")
    tail = "Return only the JSON object, one review per failing check."
    room = max(1500, MAX_USER_CHARS - len(head) - len(tail) - 40)
    return head + "## Key server code\n" + _truncate(code, room, label="code") + "\n\n" + tail


def review_failures(llm: LLM, spec: dict, code: str, failing: list[tuple[Check, dict]], *,
                    session_id: str, game_dir: Path | None = None) -> dict[str, dict]:
    """One check_reviewer call for every failing check -> {check id: review}. A failure the reviewer
    skips is treated as a game bug, so a real finding is never silently lost. With `game_dir`, a
    reviewed game_bug must name its consumer (a real <file>:<line> of game code that reads what the
    check asserts); without one the premise is unproven and it counts as a check bug."""
    if not failing:
        return {}
    obj, _ = llm.complete_json("check_reviewer", review_message(spec, code, failing, game_dir),
                               session_id=session_id, required=REVIEW_KEYS, max_tokens=REVIEW_MAX_TOKENS)
    got = {str(r.get("id")): r for r in obj.get("reviews") or [] if isinstance(r, dict)}
    sources = game_sources(game_dir) if game_dir else {}
    out = {}
    for c, _ in failing:
        r = got.get(c.id) or {}
        verdict = "check_bug" if r.get("verdict") == "check_bug" else "game_bug"
        reason = str(r.get("reason") or ("not reviewed" if not r else ""))
        consumer = valid_consumer(game_dir, r.get("consumer"), sources) if game_dir and r else None
        if game_dir and r and verdict == "game_bug" and consumer is None:
            verdict = "check_bug"
            reason = (f"no consumer: the review named no game code that reads what the check asserts "
                      f"({str(r.get('consumer') or 'none given')[:80]}), so its premise is unproven. {reason}")
        out[c.id] = {
            "verdict": verdict,
            "reason": reason,
            "consumer": consumer or "",
            "kind": r.get("kind") if r.get("kind") in KINDS else "error",
            "system": str(r.get("system") or ""),
            "severity": r.get("severity") if r.get("severity") in SEVERITIES else "medium",
            "expected": str(r.get("expected") or c.title),
            "body": str(r.get("body") or "") if verdict == "check_bug" else "",
        }
    return out


def _drop(run_dir: Path, c: Check) -> None:
    d = checks_dir(run_dir) / DROPPED_DIR
    d.mkdir(parents=True, exist_ok=True)
    src = c.path or checks_dir(run_dir) / f"{c.id}.luau"
    if src.exists():
        src.replace(d / src.name)


# ---------------------------------------------------------------------------------------------
# running


async def wait_for_player(studio: Any, timeout: float = PLAYER_WAIT_S) -> bool:
    code = ('local p = game:GetService("Players"):GetPlayers()[1]\n'
            'return (p and p.Character and p.Character:FindFirstChild("HumanoidRootPart")) and "yes" or "no"')
    deadline = asyncio.get_event_loop().time() + timeout
    while asyncio.get_event_loop().time() < deadline:
        try:
            if "yes" in str(await studio.execute_luau(code, "Server", timeout=10)):
                return True
        except Exception:  # noqa: BLE001 - the Server datamodel can lag behind play starting
            pass
        await asyncio.sleep(1.0)
    return False


def is_irreversible(check: Check) -> bool:
    return "irreversible" in check.covers.lower()


def play_sessions(checks: list[Check]) -> list[list[Check]]:
    """Reversible checks share one playtest; a check whose covers says it is irreversible (a one-time
    purchase) gets a fresh playtest of its own, so no check sees another's leftover state."""
    shared = [c for c in checks if not is_irreversible(c)]
    return ([shared] if shared else []) + [[c] for c in checks if is_irreversible(c)]


async def _run_session(studio: Any, checks: list[Check], log: Callable[[str], None]) -> list[dict]:
    await studio.play()
    try:
        if not await wait_for_player(studio):
            log("[checks] no player with a character after 30s; running anyway")
        await asyncio.sleep(SETTLE_S)
        out = []
        for c in checks:
            r = await run_check(studio, c, log=log)
            if r["ok"] and "inconclusive" in r.get("detail", "").lower():
                r["ok"] = False  # a check that could not decide has not shown the game works
            log(f"[checks] {'PASS' if r['ok'] else 'FAIL'} {c.id}: {(r.get('error') or r.get('detail', ''))[:160]}")
            out.append(r)
        return out
    finally:
        try:
            await studio.stop()
        except Exception as e:  # noqa: BLE001 - report, but never hide the results
            log(f"[checks] could not stop play: {e}")


async def run_in_sessions(studio: Any, checks: list[Check], log: Callable[[str], None] = print) -> dict[str, dict]:
    got: dict[str, dict] = {}
    for group in play_sessions(checks):
        for r in await _run_session(studio, group, log):
            got[r["id"]] = r
    return got


async def run_plan(studio: Any, slug: str, *, settings: Settings, llm: LLM | None = None,
                   session_id: str | None = None, log: Callable[[str], None] = print,
                   only: set[str] | None = None, prior: list[dict] | None = None) -> list[dict]:
    """Run every saved check in live playtests (started and always stopped here), review the failures
    with one check_reviewer call when an llm is given, re-run rewritten checks once, and save
    checks/results.json. Each result: {id, title, covers, ok, detail, error?, verdict: pass | game_bug |
    check_bug_fixed | dropped, reason?, kind?, system?, severity?, expected?, first_run?}."""
    store = RunStore(settings, slug)
    checks = load_checks(store.dir)
    if not checks:
        raise SystemExit(f"no checks in {checks_dir(store.dir)}; run `forge checks {slug} --plan` first")
    if only is not None:  # e.g. the checks that did not pass headless (checks.triage); `prior` holds the rest
        checks = [c for c in checks if c.id in only]
    by_id = {c.id: c for c in checks}
    got = await run_in_sessions(studio, checks, log)
    results = [{**got[c.id], "covers": c.covers, "verdict": "pass" if got[c.id]["ok"] else "game_bug"}
               for c in checks]
    failing = [(by_id[r["id"]], r) for r in results if not r["ok"]]
    if failing and llm is not None:
        spec = store.load_spec()
        sid = session_id or f"check-review-{slug}-{uuid.uuid4().hex[:8]}"
        reviews = review_failures(llm, spec, key_code(store.game_dir, spec), failing, session_id=sid,
                                  game_dir=store.game_dir)
        rewrites = _apply_verdicts(store.dir, by_id, results, reviews, log)
        if rewrites:
            reruns = await run_in_sessions(studio, rewrites, log)
            _finish_rewrites(store.dir, rewrites, results, reruns, log)
    results = list(prior or []) + results
    save_results(store.dir, results)
    log(summary(results))
    return results


def _apply_verdicts(run_dir: Path, by_id: dict[str, Check], results: list[dict], reviews: dict[str, dict],
                    log: Callable[[str], None]) -> list[Check]:
    """Record each review on its result; drop check bugs with no usable rewrite. Returns the rewrites."""
    rewrites = []
    for r in results:
        rev = reviews.get(r["id"])
        if not rev:
            continue
        r.update({k: rev[k] for k in ("verdict", "reason", "kind", "system", "severity", "expected", "consumer")})
        if rev["verdict"] != "check_bug":
            log(f"[review] game bug {r['id']}: {rev['reason'][:160]}")
            continue
        old = by_id[r["id"]]
        body = rev["body"].strip("\n")
        if not body or compile_error(body):
            r["verdict"] = "dropped"
            _drop(run_dir, old)
            log(f"[review] dropped {r['id']} (check bug, no usable rewrite): {rev['reason'][:140]}")
            continue
        if lint_setup(body):
            log(f"[review] warning: the rewrite of {r['id']} never asserts its setup")
        rewrites.append(Check(id=old.id, title=old.title, covers=old.covers, body=body, path=old.path))
    return rewrites


def _finish_rewrites(run_dir: Path, rewrites: list[Check], results: list[dict], reruns: dict[str, dict],
                     log: Callable[[str], None]) -> None:
    by_id = {r["id"]: r for r in results}
    for new in rewrites:
        r, rerun = by_id[new.id], reruns[new.id]
        r["first_run"] = {k: r[k] for k in ("ok", "detail", "error") if k in r}
        r.pop("error", None)
        r.update({k: v for k, v in rerun.items() if k in ("ok", "detail", "error")})
        save_check(run_dir, new)
        if rerun["ok"]:
            r["verdict"] = "check_bug_fixed"
            log(f"[review] rewrote {new.id}: now passes")
        else:
            r["verdict"] = "dropped"
            _drop(run_dir, new)
            log(f"[review] dropped {new.id}: rewrite still fails "
                f"({(rerun.get('error') or rerun.get('detail', ''))[:120]})")


def save_results(run_dir: Path, results: list[dict]) -> Path:
    path = checks_dir(run_dir) / RESULTS_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"ts": now_iso(), "results": results}, indent=1, ensure_ascii=False),
                    encoding="utf-8")
    return path


def save_suite_results(run_dir: Path, results: list[dict], source: str) -> Path:
    """A fix cycle's suite run (forge/repro.run_suite: suite + pending checks) as the latest results.json,
    keeping what the plan's review knew about each check (covers, kind, severity, ...). A pending check
    is a proven bug not fixed yet, so it fails here too."""
    prior = {r.get("id"): r for r in load_results(run_dir)}
    out = []
    for r in results:
        old = {k: v for k, v in (prior.get(r["id"]) or {}).items()
               if k in ("covers", "reason", "kind", "system", "severity", "expected", "consumer")}
        out.append({**old, **{k: v for k, v in r.items() if k in ("id", "title", "ok", "detail", "error", "pending")},
                    "verdict": "pass" if r.get("ok") else "game_bug", "source": source})
    return save_results(run_dir, out)


def load_results(run_dir: Path) -> list[dict]:
    path = checks_dir(run_dir) / RESULTS_FILE
    return json.loads(path.read_text(encoding="utf-8")).get("results", []) if path.exists() else []


# ---------------------------------------------------------------------------------------------
# for the fix loop

_ACCEPT = re.compile(r"^\s*acceptance\b", re.IGNORECASE)


def as_anomalies(results: list[dict]) -> list[dict]:
    """Failing game-bug checks as auditor-shaped anomalies (title, kind, severity, system, observed,
    expected, evidence) plus `check`: the id of the check that reproduces it."""
    out = []
    for r in results:
        if r.get("ok") or r.get("verdict") != "game_bug" or setup_failure(r):
            continue  # a check that never reached its situation proves no bug
        observed = r.get("error") or r.get("detail") or "(no detail)"
        sev = r.get("severity") if r.get("severity") in SEVERITIES else (
            "high" if _ACCEPT.match(r.get("covers") or "") else "medium")
        out.append({
            "title": r.get("title") or r["id"],
            "kind": r.get("kind") if r.get("kind") in KINDS else "error",
            "severity": sev,
            "system": r.get("system") or "",
            "observed": observed,
            "expected": r.get("expected") or r.get("title") or "",
            "evidence": f"check {r['id']} ({r.get('covers') or 'no covers'}) failed: {observed}"
                        + (f"; reviewer: {r['reason']}" if r.get("reason") else ""),
            **({"consumer": r["consumer"]} if r.get("consumer") else {}),
            "check": r["id"],
        })
    return out
