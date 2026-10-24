"""Executable checks: a game's behaviour as small Luau tests run against the live game during play.

A check is one file, runs/<slug>/checks/<id>.luau (beside the game, never synced into it):

    -- check: Buying the second dropper costs 25 cash and adds a dropper
    -- covers: acceptance: "a second dropper for 25 cash"
    local Players = game:GetService("Players")
    local p = Players:GetPlayers()[1]
    ...
    return { ok = owned == true, detail = "cash " .. before .. " -> " .. after }

The body runs in the Server datamodel of a running playtest (Studio MCP execute_luau) inside a
function, so it may use locals, task.wait (keep it under CHECK_TIMEOUT seconds) and early returns.
It must return { ok = boolean, detail = string } and undo what it set up (cash, spawned parts).
A check that errors counts as failed, with the error as its detail.

The wrapper gives every body a small `forge` helper table (HELPERS / HELPERS_DOC): `forge.waitFor`,
`forge.startRound`, `forge.endRound`. The round helpers go through the ForgeTest harness's `round`
command (ServerStorage.ForgeTest, the same one `forge fix --start-round` uses), so a round-based game
can be tested inside its round; without the harness they raise a "setup: ..." error.

Checks cost no LLM calls to run and give an exact pass/fail, so they are how Forge proves a bug
(a failing check), proves a fix (the check now passes), and guards against regressions (every
saved check keeps passing).

Headless (no Studio): game/tools/headless.luau fakes enough of the Roblox engine to run a game's
server code with the plain `luau` CLI on a simulated clock. `boot_offline(game_dir)` boots every
server Script, joins a player and returns a ForgeProbe-shaped report (errors, warnings, counters)
in well under a second; `run_checks_offline(game_dir, checks)` runs checks against that booted fake
server in parallel. A check that passes offline needs no Studio round trip (`triage`); anything that
fails or errors offline still goes to Studio, which stays the judge. A check that can only mean
something in a real engine (physics, rendering, replication) says so with `-- needs: studio`.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any

CHECKS_DIR = "checks"
CHECK_TIMEOUT = 30.0
_ID_RE = re.compile(r"[^a-z0-9]+")


@dataclass
class Check:
    id: str
    title: str
    covers: str
    body: str
    path: Path | None = None
    needs: str = ""  # "studio": never trust a headless run of this check


def check_id(title: str) -> str:
    return _ID_RE.sub("-", title.lower()).strip("-")[:60] or "check"


def parse(text: str, id: str = "check", path: Path | None = None) -> Check:
    title = covers = needs = ""
    for line in text.splitlines()[:6]:
        m = re.match(r"\s*--\s*(check|covers|needs):\s*(.*)", line)
        if m and m.group(1) == "check":
            title = m.group(2).strip()
        elif m and m.group(1) == "needs":
            needs = m.group(2).strip().lower()
        elif m:
            covers = m.group(2).strip()
    return Check(id=id, title=title or id, covers=covers, body=text, path=path, needs=needs)


def render(check: Check) -> str:
    body = "\n".join(ln for ln in check.body.splitlines()
                     if not re.match(r"\s*--\s*(check|covers|needs):", ln)).strip("\n")
    needs = f"-- needs: {check.needs}\n" if check.needs else ""
    return f"-- check: {check.title}\n-- covers: {check.covers}\n{needs}{body}\n"


def checks_dir(run_dir: Path) -> Path:
    return run_dir / CHECKS_DIR


def load_checks(run_dir: Path) -> list[Check]:
    d = checks_dir(run_dir)
    return [parse(p.read_text(encoding="utf-8"), p.stem, p) for p in sorted(d.glob("*.luau"))] if d.exists() else []


def save_check(run_dir: Path, check: Check) -> Path:
    d = checks_dir(run_dir)
    d.mkdir(parents=True, exist_ok=True)
    path = d / f"{check.id}.luau"
    path.write_text(render(check), encoding="utf-8")
    check.path = path
    return path


HELPERS = """local forge = {}
function forge.waitFor(fn, timeout)
	local t0 = os.clock()
	repeat
		local ok, v = pcall(fn)
		if ok and v then return v end
		task.wait(0.2)
	until os.clock() - t0 >= (timeout or 10)
	return nil
end
function forge.harness(cmd, args)
	local f = game:GetService("ServerStorage"):FindFirstChild("ForgeTest")
	if not f then error("setup: no ForgeTest harness in ServerStorage, cannot run " .. cmd, 0) end
	local reply = __http:JSONDecode(f:Invoke(cmd, __http:JSONEncode(args or {})))
	if not reply.ok then error("setup: ForgeTest " .. cmd .. " failed: " .. tostring(reply.error), 0) end
	return reply.result
end
function forge.startRound(timeout)
	if workspace:GetAttribute("RoundState") == "Active" then return true end
	local res = forge.harness("round", { state = "Active" })
	local active = forge.waitFor(function() return workspace:GetAttribute("RoundState") == "Active" end, timeout or 15)
	if not active then
		error("setup: round did not start (RoundState=" .. tostring(workspace:GetAttribute("RoundState"))
			.. ", via " .. tostring(type(res) == "table" and res.via) .. ")", 0)
	end
	return true
end
function forge.endRound()
	pcall(forge.harness, "round", { state = "Results" })
end
"""

HELPERS_DOC = """Every check body can use a `forge` helper table (defined by the wrapper, no require needed):
- forge.waitFor(fn, timeout) -> the first truthy value fn() returns within timeout seconds (default 10), else nil.
- forge.startRound(timeout) -> starts a round through the ForgeTest harness (no-op if workspace RoundState is
  already "Active") and waits until RoundState is "Active"; raises "setup: ..." when it cannot.
- forge.endRound() -> ends the round (call it before returning when the check started one).
A check never waits for a lobby countdown or a player to pick a mission: it calls forge.startRound()."""

ROUND_RULE = ("This game starts in a lobby (spec playtest.start_round): a check about anything that happens "
              "during a round MUST call forge.startRound() first and forge.endRound() before returning. "
              "\"inconclusive: round not Active\" is never an acceptable result.")


def helpers_doc(spec: dict | None) -> str:
    """The helper docs for a scenarist/reproducer/reviewer user message, plus the round rule when the game
    starts in a lobby."""
    return HELPERS_DOC + ("\n" + ROUND_RULE if ((spec or {}).get("playtest") or {}).get("start_round") else "")


def wrap(body: str) -> str:
    """The Luau sent to execute_luau: runs the body in a function and returns one JSON line."""
    return (
        'local __http = game:GetService("HttpService")\n'
        + HELPERS +
        "local __ok, __res = pcall(function()\n"
        f"{body}\n"
        "end)\n"
        "if not __ok then return __http:JSONEncode({ ok = false, error = tostring(__res) }) end\n"
        'if type(__res) ~= "table" then\n'
        '  return __http:JSONEncode({ ok = false, error = "check must return { ok = bool, detail = string }" })\n'
        "end\n"
        'return __http:JSONEncode({ ok = __res.ok == true, detail = tostring(__res.detail or "") })\n'
    )


# ---------------------------------------------------------------- premise: does the game read it?

CONSUMER_RULE = """A failing check proves a game bug only if the game itself depends on what the check asserts.
Name the consumer: the game code path (client or server) that reads or uses the asserted thing, as
<file>:<line> from the line-numbered code shown. A config value or the code that creates the thing is not a
consumer. If no game code reads it (the check expects an object in a place nothing looks, a name nothing
uses), the check's premise is wrong: it is a check bug, not a game bug."""

_LITERAL = re.compile(r"""(["'])([A-Za-z_][\w.]{2,60})\1""")
_SERVICE_ARG = re.compile(r"""GetService\(\s*["'](\w+)["']""")
_COMMON = {"Players", "Workspace", "HumanoidRootPart", "Humanoid", "Character", "Backpack", "leaderstats",
           "ForgeTest", "DevHook", "Server", "Client", "Active", "Results", "Lobby", "Part", "Model",
           "Folder", "string", "number", "table", "boolean", "function", "setup", "inconclusive",
           "RemoteEvent", "RemoteFunction", "BindableEvent", "BindableFunction", "BasePart", "Tool",
           "ScreenGui", "Frame", "TextLabel", "TextButton", "Sound", "Attachment", "IntValue", "NumberValue",
           "StringValue", "BoolValue", "ObjectValue", "ModuleScript", "Script", "LocalScript"}
HITS_PER_NAME = 6
HITS_CHARS = 2500
_SKIP_PREFIXES = ("tools/", "tests/")


def asserted_names(body: str) -> list[str]:
    """Identifier-like string literals in a check body: the names it looks up or asserts on."""
    services = set(_SERVICE_ARG.findall(body))
    out: list[str] = []
    for _, name in _LITERAL.findall(body):
        if name not in services and name not in _COMMON and name not in out:
            out.append(name)
    return out


def game_sources(game_dir: Path) -> dict[str, list[str]]:
    """Every game Luau file (client and server; the Forge runtime, tools and tests skipped) -> its lines."""
    out = {}
    for p in sorted(game_dir.rglob("*.luau")):
        rel = p.relative_to(game_dir).as_posix()
        name = rel.rsplit("/", 1)[-1]
        if rel.startswith(_SKIP_PREFIXES) or name.startswith("Forge") or "/." in rel or rel.startswith("."):
            continue
        out[rel] = p.read_text(encoding="utf-8", errors="replace").splitlines()
    return out


def consumer_hits(game_dir: Path, body: str, limit: int = HITS_CHARS,
                  sources: dict[str, list[str]] | None = None) -> str:
    """Line-numbered game lines that mention the names a check asserts on, for naming its consumer."""
    sources = sources if sources is not None else game_sources(game_dir)
    rows: list[str] = []
    for name in asserted_names(body):
        hits = [f"{rel}:{i + 1}: {ln.strip()[:140]}" for rel, lines in sources.items()
                for i, ln in enumerate(lines) if name in ln and not ln.lstrip().startswith("--")]
        rows.append(f'"{name}": ' + (f"{len(hits)} line(s)" if hits else "no game code mentions it"))
        rows += ["  " + h for h in hits[:HITS_PER_NAME]]
        if len(hits) > HITS_PER_NAME:
            rows.append(f"  ...{len(hits) - HITS_PER_NAME} more")
    text = "\n".join(rows) or "(the check names nothing to look up)"
    return text if len(text) <= limit else text[:limit] + "\n...[more]"


_REF = re.compile(r"([\w./-]+\.luau):(\d+)")


def valid_consumer(game_dir: Path, ref: Any, sources: dict[str, list[str]] | None = None) -> str | None:
    """`ref` normalised to "<file>:<line>" when it names a real line of game code, else None."""
    m = _REF.search(str(ref or ""))
    if not m:
        return None
    sources = sources if sources is not None else game_sources(game_dir)
    rel, line = m.group(1).lstrip("./"), int(m.group(2))
    lines = sources.get(rel)
    if lines is None:
        rel = next((r for r in sources if r.endswith("/" + rel)), "")
        lines = sources.get(rel)
    return f"{rel}:{line}" if lines is not None and 1 <= line <= len(lines) else None


def result_from(text: str) -> dict:
    from forge.studio import extract_json

    obj = extract_json(text)
    if not isinstance(obj, dict) or "ok" not in obj:
        return {"ok": False, "error": f"unreadable check output: {str(text)[:300]}"}
    out: dict[str, Any] = {"ok": obj.get("ok") is True, "detail": str(obj.get("detail") or "")}
    if obj.get("error"):
        out["error"] = str(obj["error"])[:500]
    return out


async def run_check(studio: Any, check: Check, timeout: float = CHECK_TIMEOUT) -> dict:
    """Run one check in the Server datamodel of the current playtest -> {id, title, ok, detail, error?}."""
    try:
        text = await studio.execute_luau(wrap(check.body), "Server", timeout=timeout)
        res = result_from(text)
    except Exception as e:  # Studio dropping or a timeout is a failed run, reported, not raised
        res = {"ok": False, "error": f"{type(e).__name__}: {str(e)[:300]}"}
    return {"id": check.id, "title": check.title, **res}


async def run_checks(studio: Any, checks: list[Check], timeout: float = CHECK_TIMEOUT) -> list[dict]:
    return [await run_check(studio, c, timeout) for c in checks]


def summary(results: list[dict]) -> str:
    passed = sum(1 for r in results if r.get("ok"))
    lines = [f"checks: {passed}/{len(results)} pass"]
    for r in results:
        if not r.get("ok"):
            lines.append(f"- FAIL {r['id']}: {r.get('error') or r.get('detail', '')}"[:300])
    return "\n".join(lines)


def to_json(results: list[dict]) -> str:
    return json.dumps(results, ensure_ascii=False)


# ================================================================ headless (no Studio)

OUT_MARK = "@@HEADLESS@@"
HEADLESS_TIMEOUT = 30.0  # wall seconds per luau process (an infinite loop without task.wait hangs)


def headless_available() -> bool:
    return shutil.which("luau") is not None


def _headless_source() -> str:
    from forge.config import load_settings
    return (load_settings().base_game_dir / "tools" / "headless.luau").read_text(encoding="utf-8")


def bundle(game_dir: Path, opts: dict) -> str:
    """One self-contained Luau program: the headless engine, every synced file of the game, and
    H.main(opts). Runs with `luau <file>` (the CLI has no file I/O, so sources are embedded)."""
    from forge import sync as fsync

    game_dir = Path(game_dir)
    lines = ["local H = (function()", _headless_source(), "end)()"]
    for e in fsync.manifest_entries(game_dir):
        src = (game_dir / e["path"]).read_text(encoding="utf-8", errors="replace")
        lines.append(f"H.add({json.dumps(e['path'])}, {json.dumps(e['class'])}, {fsync.long_string(src)})")
    o = dict(opts)
    check_body = o.pop("check", None)
    fields = [f"{k} = {json.dumps(v)}" for k, v in sorted(o.items()) if isinstance(v, (int, float, str))]
    if check_body is not None:
        fields.append(f"check = {fsync.long_string(check_body)}")
    lines.append("H.main({ " + ", ".join(fields) + " })")
    return "\n".join(lines) + "\n"


def run_headless(game_dir: Path, opts: dict | None = None, timeout: float = HEADLESS_TIMEOUT) -> dict:
    """Run the headless engine once -> {"report": {...}, "check"?: {...}} or {"error": ...}."""
    exe = shutil.which("luau")
    if not exe:
        return {"error": "luau CLI not on PATH (brew install luau)"}
    src = bundle(game_dir, opts or {})
    with tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False, encoding="utf-8") as f:
        f.write(src)
        path = f.name
    try:
        r = subprocess.run([exe, path], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"error": f"headless run timed out after {timeout:.0f}s (a loop without task.wait?)"}
    finally:
        Path(path).unlink(missing_ok=True)
    for line in reversed(r.stdout.splitlines()):
        if line.startswith(OUT_MARK):
            try:
                return json.loads(line[len(OUT_MARK):])
            except ValueError as e:
                return {"error": f"unreadable headless output: {e}"}
    return {"error": f"headless run failed (exit {r.returncode}): {(r.stderr or r.stdout)[-800:]}"}


def boot_offline(game_dir: Path, boot: float = 2.0, play: float = 3.0, players: int = 1) -> dict:
    """Boot the game's server headless, join `players`, run `play` simulated seconds.
    Returns a ForgeProbe-shaped report plus "misses" (engine members the fake doesn't model)."""
    out = run_headless(game_dir, {"mode": "boot", "boot": boot, "play": play, "players": players})
    if "error" in out:
        return {"error": out["error"], "errors": [], "warnings": []}
    return out.get("report") or {"error": "no report", "errors": [], "warnings": []}


def run_check_offline(game_dir: Path, check: Check, timeout: float = CHECK_TIMEOUT) -> dict:
    """Run one check against a freshly booted headless server -> run_check's shape + where/boot_errors."""
    out = run_headless(game_dir, {"mode": "check", "check": check.body, "timeout": timeout})
    if "error" in out:
        res: dict = {"ok": False, "error": out["error"]}
    else:
        res = dict(out.get("check") or {"ok": False, "error": "no check result"})
        rep = out.get("report") or {}
        res["boot_errors"] = len(rep.get("errors") or [])
        if not res.get("ok") and rep.get("misses"):
            res["misses"] = rep["misses"][:10]
    return {"id": check.id, "title": check.title, "where": "offline", **res}


def run_checks_offline(game_dir: Path, checks: list[Check], timeout: float = CHECK_TIMEOUT,
                       workers: int = 8) -> list[dict]:
    """Every check headless, in parallel processes (each gets its own fresh fake server)."""
    if not checks:
        return []
    with ThreadPoolExecutor(max_workers=max(1, min(workers, len(checks)))) as pool:
        return list(pool.map(lambda c: run_check_offline(game_dir, c, timeout), checks))


def triage(game_dir: Path, checks: list[Check]) -> tuple[list[dict], list[Check]]:
    """Run what can run without Studio. -> (offline passes, checks that still need Studio).
    Only a pass is trusted offline; a failure may be the fake engine's gap, so Studio re-runs it."""
    if not headless_available():
        return [], list(checks)
    candidates = [c for c in checks if c.needs != "studio"]
    results = run_checks_offline(game_dir, candidates)
    passed = [r for r in results if r.get("ok")]
    passed_ids = {r["id"] for r in passed}
    return passed, [c for c in checks if c.id not in passed_ids]


def run_specs(spec_dir: Path, timeout: float = HEADLESS_TIMEOUT) -> list[dict]:
    """Pure-Luau unit specs (*.spec.luau, see game/tests/Spec.luau) with the luau CLI.
    -> [{id, ok, output}]; a spec fails when luau exits non-zero."""
    exe = shutil.which("luau")
    spec_dir = Path(spec_dir)
    if not exe or not spec_dir.is_dir():
        return []

    def one(p: Path) -> dict:
        try:
            r = subprocess.run([exe, p.name], cwd=spec_dir, capture_output=True, text=True, timeout=timeout)
            return {"id": p.stem, "ok": r.returncode == 0, "output": (r.stdout + r.stderr)[-1500:]}
        except subprocess.TimeoutExpired:
            return {"id": p.stem, "ok": False, "output": f"timed out after {timeout:.0f}s"}

    specs = sorted(spec_dir.glob("*.spec.luau"))
    with ThreadPoolExecutor(max_workers=8) as pool:
        return list(pool.map(one, specs))
