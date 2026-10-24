"""Reproduce first: an anomaly becomes a failing executable check (forge/checks.py) before any fix.

The `reproducer` (Mubit task) writes one check that must FAIL while the bug exists. Forge runs it in
the live playtest: a failing check proves the bug, the fixer is then judged by that check (it must
pass after the fix) and by the saved suite (every check that passed before must still pass).

Checks live in runs/<slug>/checks/:
    <id>.luau          the suite: checks that passed after a kept fix (regression guards)
    pending/<id>.luau  proven bugs not fixed yet; they fail by design, so they are not in the suite
"""

from __future__ import annotations

import asyncio
import dataclasses
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Callable

from forge import checks as fchecks
from forge.checks import Check
from forge.config import Settings
from forge.llm import LLM, LLMError

PENDING = "pending"
REPRO_RETRIES = 1
REPRO_MAX_TOKENS = 3000
EXCERPT_FILES = 3
EXCERPT_CHARS = 5000
INDEX_CHARS = 5000
PROBE_STEPS = 4
CHECK_IN_PROBLEM_CHARS = 1600

CONTRACT = """The check body runs in the Server datamodel of the running playtest (Studio execute_luau), wrapped
in a function, so it may use locals, early returns and task.wait (stay under 20 seconds in total).
It must return { ok = boolean, detail = string }. ok = true means the game behaves correctly.
A Luau error or a missing return counts as a failed run, but it does NOT prove the bug: only a clean
ok = false does. The playtest has the Studio player (Players:GetPlayers()[1]) once they have joined.
Live server modules can be reached with require(<ModuleScript>) or
game:GetService("ServerStorage").DevHook:Invoke(moduleName, method, ...).
Undo what the check sets up (cash, positions, spawned parts) before every return.
ok = false must mean "the game did the wrong thing". When the check cannot set up its situation (no player,
no plot, a part or module missing), call error("setup: <what is missing>") instead: that is a broken check,
not a proven bug, and an ok = false for it makes every fix look like a failure.
"Correct" is what the anomaly and the game's spec expect. Never redefine it just to get a failing check."""

EXAMPLES = """```luau
-- check: Touching an affordable buy pad takes its price and marks it bought
-- covers: anomaly: buy pads never unlock
local Players = game:GetService("Players")
local p = Players:GetPlayers()[1]
local t0 = os.clock()
while not (p and p.Character and p.Character:FindFirstChild("HumanoidRootPart")) and os.clock() - t0 < 10 do
	task.wait(0.5)
	p = Players:GetPlayers()[1]
end
if not p or not p.Character then error("setup: no player character within 10s") end
local cash = p.leaderstats.Cash
local pad = workspace:FindFirstChild("BuyPad_dropper2", true)
if not pad then error("setup: no BuyPad_dropper2 in workspace") end
local hrp = p.Character.HumanoidRootPart
local oldCash, oldCF = cash.Value, hrp.CFrame
cash.Value = 1000
hrp.CFrame = pad.CFrame + Vector3.new(0, 3, 0)
local t1 = os.clock()
while cash.Value == 1000 and os.clock() - t1 < 3 do task.wait(0.1) end
local spent = 1000 - cash.Value
cash.Value, hrp.CFrame = oldCash, oldCF
return { ok = spent == 25, detail = "pad took " .. spent .. " cash, expected 25" }
```

```luau
-- check: Buying an item without enough cash keeps the cash and grants nothing
-- covers: anomaly: shop sells items to players who cannot afford them
local Players = game:GetService("Players")
local p = Players:GetPlayers()[1]
if not p then error("setup: no player") end
local Shop = require(game:GetService("ServerScriptService"):WaitForChild("ShopService"))
local cash = p.leaderstats.Cash
local oldCash = cash.Value
cash.Value = 3
local bought = Shop.buy(p, "Sword")
local after = cash.Value
local owns = p:FindFirstChild("Backpack") and p.Backpack:FindFirstChild("Sword")
if owns then owns:Destroy() end
cash.Value = oldCash
return { ok = not bought and after == 3 and not owns,
         detail = "buy returned " .. tostring(bought) .. ", cash 3 -> " .. after .. ", owns " .. tostring(owns ~= nil) }
```"""


# ---------------------------------------------------------------- storage


def pending_dir(run_dir: Path) -> Path:
    return fchecks.checks_dir(run_dir) / PENDING


def load_pending(run_dir: Path) -> list[Check]:
    d = pending_dir(run_dir)
    return [fchecks.parse(p.read_text(encoding="utf-8"), p.stem, p) for p in sorted(d.glob("*.luau"))] if d.exists() else []


def save_pending(run_dir: Path, check: Check) -> Path:
    """A proven bug's check, kept out of the suite until a fix makes it pass. Never overwrites a suite check."""
    suite = {c.id for c in fchecks.load_checks(run_dir)}
    base, n = check.id, 2
    while check.id in suite:
        check.id = f"{base}-{n}"
        n += 1
    d = pending_dir(run_dir)
    d.mkdir(parents=True, exist_ok=True)
    path = d / f"{check.id}.luau"
    path.write_text(fchecks.render(check), encoding="utf-8")
    check.path = path
    return path


def promote(run_dir: Path, check: Check) -> Path:
    """The fix was kept: the check joins the suite as a regression guard."""
    old = check.path
    path = fchecks.save_check(run_dir, check)
    if old and old != path and old.exists():
        old.unlink()
    return path


def find(run_dir: Path, check_id: str) -> Check | None:
    return next((c for c in fchecks.load_checks(run_dir) + load_pending(run_dir) if c.id == check_id), None)


def check_anomaly(result: dict, pending: bool) -> dict:
    """A saved check that fails at the start of a cycle is an anomaly that already has its repro."""
    return {"kind": "proven_bug" if pending else "regression", "system": "checks",
            "title": f"Check fails: {result.get('title') or result['id']}",
            "expected": "the check passes",
            "observed": str(result.get("error") or result.get("detail") or "")[:300],
            "severity": "high", "check": result["id"]}


async def run_suite(studio: Any, run_dir: Path, log: Callable[[str], None] = print) -> dict:
    """Every saved check (suite + pending) -> {"results": [...], "anomalies": [...]}."""
    suite, pend = fchecks.load_checks(run_dir), load_pending(run_dir)
    if not suite and not pend:
        return {"results": [], "anomalies": []}
    results = await fchecks.run_checks(studio, suite + pend)
    pending_ids = {c.id for c in pend}
    for r in results:
        r["pending"] = r["id"] in pending_ids
    failing = [r for r in results if not r.get("ok")]
    log(f"[checks] suite {sum(1 for r in results if r['ok'] and not r['pending'])}/{len(suite)} pass, "
        f"pending {sum(1 for r in results if r['pending'] and not r['ok'])}/{len(pend)} still fail")
    return {"results": results, "anomalies": [check_anomaly(r, r["pending"]) for r in failing]}


# ---------------------------------------------------------------- the reproducer call


def compile_error(body: str) -> str | None:
    exe = shutil.which("luau-compile")
    if not exe:
        return None
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / "check.luau"
        f.write_text(fchecks.wrap(body), encoding="utf-8")
        r = subprocess.run([exe, "--null", str(f)], capture_output=True, text=True)
    if r.returncode == 0:
        return None
    lines = [ln.replace(str(f), "check.luau") for ln in (r.stdout + r.stderr).splitlines()
             if ln.strip() and not ln.startswith("Compiled ")]
    return "\n".join(lines)[:500] or f"luau-compile exit {r.returncode}"


def _investigation_block(found: dict | None) -> str:
    if not found:
        return "(no investigation)"
    concl = found.get("conclusion") or {}
    out = []
    if concl:
        out.append("Conclusion: " + json.dumps({k: concl.get(k) for k in ("root_cause", "file", "evidence", "fix_hint")},
                                               ensure_ascii=False)[:1500])
    else:
        out.append("The investigator did not reach a conclusion.")
    probes = [s for s in found.get("steps") or [] if str((s.get("action") or {}).get("action")) == "probe"]
    for s in probes[-PROBE_STEPS:]:
        act = s["action"]
        out.append(f"Probe ({act.get('datamodel', 'Server')}): {str(act.get('why', ''))[:200]}\n"
                   f"```luau\n{str(act.get('code', ''))[:700]}\n```\nResult: {str(s.get('result', ''))[:500]}")
    return "\n\n".join(out)


def excerpt_files(settings: Settings, game_dir: Path, anomaly: dict, found: dict | None) -> list[str]:
    from forge.improve import NOT_IN_STUDIO, _anomaly_text
    from mubit_tester.ai import find_candidate_files

    concl = (found or {}).get("conclusion") or {}
    text = _anomaly_text(anomaly) + " " + str(concl.get("root_cause", ""))
    ranked = find_candidate_files(dataclasses.replace(settings, base_game_dir=game_dir), text, limit=10)
    out = [concl["file"]] if concl.get("file") else []
    out += [rel for rel, _ in ranked if not rel.startswith(NOT_IN_STUDIO) and rel not in out
            and not rel.startswith(("ServerScriptService/ForgeTest", "ServerScriptService/ForgeProbe"))]
    return out[:EXCERPT_FILES]


def reproduce_message(anomaly: dict, found: dict | None, index: str, excerpts: dict[str, str],
                      previous: tuple[str | None, str] | None = None) -> str:
    parts = ["## Anomaly\n" + json.dumps({k: v for k, v in anomaly.items() if k != "check"}, ensure_ascii=False),
             "## Investigation\n" + _investigation_block(found),
             "## Game files\n" + (index if len(index) <= INDEX_CHARS else index[:INDEX_CHARS] + "\n...[more files]"),
             "## Relevant code\n" + "\n\n".join(f"### {rel}\n```\n{ex}\n```" for rel, ex in excerpts.items()),
             "## Check contract\n" + CONTRACT, "## Example checks\n" + EXAMPLES]
    if previous:
        body, outcome = previous
        parts.append("## Your previous check\n" + (f"```luau\n{body[:3000]}\n```\n" if body else "") + outcome)
    parts.append("Reply with ONE ```luau block: the check.")
    return "\n\n".join(parts)


def _outcome(result: dict) -> str:
    if result.get("error"):
        return (f"When it ran it ERRORED: {result['error'][:600]}\nAn erroring check proves nothing. Fix the error "
                "(read the real names from the code) so it runs cleanly and returns ok = false while the bug exists.")
    return (f"When it ran it PASSED (ok = true, detail: {result.get('detail', '')[:400]}). The bug was not reproduced: "
            "either the check tests the wrong thing or it does not set up the situation where the bug shows. "
            "Assert the expected behaviour in the exact situation the anomaly describes. If the measurement shows "
            "the game already behaves as players and the spec would expect, the anomaly may not be a bug: keep the "
            "same expectation rather than inventing a stricter one, and Forge will mark it unproven.")


async def reproduce(settings: Settings, slug: str, anomaly: dict, found: dict | None, *, llm: LLM, studio: Any,
                    session_id: str, retries: int = REPRO_RETRIES, log: Callable[[str], None] = print) -> dict:
    """Ask the reproducer for a failing check and run it live. A retry (same Mubit task, the outcome as a
    correction in the user message) follows only a check that errored; a passing check ends it, unproven.
    Returns {"proven": bool, "check": Check | None, "result": dict | None, "attempts": [...]}."""
    from forge import roles
    from forge.improve import file_index
    from forge.memory import RunStore
    from forge.patch import relevant_excerpt

    root = RunStore(settings, slug).game_dir
    index = file_index(root)
    concl = (found or {}).get("conclusion") or {}
    words = f"{anomaly['title']} {anomaly.get('expected', '')} {anomaly.get('observed', '')} {concl.get('root_cause', '')}"
    excerpts = {rel: relevant_excerpt((root / rel).read_text(encoding="utf-8", errors="replace"), words,
                                      budget=EXCERPT_CHARS)
                for rel in excerpt_files(settings, root, anomaly, found)}
    attempts: list[dict] = []
    previous: tuple[str | None, str] | None = None
    for _ in range(1 + max(0, retries)):
        msg = reproduce_message(anomaly, found, index, excerpts, previous)
        try:
            res = await asyncio.to_thread(llm.complete, "reproducer", msg, session_id=session_id,
                                          max_tokens=REPRO_MAX_TOKENS)
            body = roles.extract_luau(res.text)
        except LLMError as e:
            attempts.append({"status": "unusable", "error": str(e)[:300]})
            previous = (None, "Your previous reply could not be used: reply with ONE ```luau block, the check.")
            log(f"[reproducer] unusable reply: {str(e)[:100]}")
            continue
        check = fchecks.parse(body)
        check.id = fchecks.check_id(check.title)
        check.covers = check.covers or f"anomaly: {anomaly['title']}"
        err = compile_error(body)
        result = ({"id": check.id, "title": check.title, "ok": False, "error": f"luau-compile: {err}"} if err
                  else await fchecks.run_check(studio, check))
        status = "proven" if not result.get("ok") and not result.get("error") else (
            "passed" if result.get("ok") else "errored")
        attempts.append({"status": status, "check": check.id, "title": check.title, "result": result,
                         "request_id": res.request_id, "body": body})
        log(f"[reproducer] {check.id}: {status} ({str(result.get('error') or result.get('detail', ''))[:120]}) "
            f"{res.request_id}")
        if status == "proven":
            return {"proven": True, "check": check, "result": result, "attempts": attempts}
        if status == "passed":
            # The game measured as expected. A retry here pushed the reproducer to invent a stricter
            # expectation just to fail (a sign showing DisplayName became a "bug"), so stop: unproven.
            break
        previous = (body, _outcome(result))
    return {"proven": False, "check": None, "result": None, "attempts": attempts}


def problem_block(check: Check, result: dict) -> str:
    """The failing check for the fixer/patcher: what 'fixed' means, exactly."""
    out = str(result.get("error") or result.get("detail") or "")[:400]
    body = check.body if len(check.body) <= CHECK_IN_PROBLEM_CHARS else check.body[:CHECK_IN_PROBLEM_CHARS] + "\n...[cut]"
    return (f"## Failing check (proves the bug; your fix is kept only if it passes)\nResult now: FAIL - {out}\n"
            f"```luau\n{body}\n```")
