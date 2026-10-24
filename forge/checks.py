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

Checks cost no LLM calls to run and give an exact pass/fail, so they are how Forge proves a bug
(a failing check), proves a fix (the check now passes), and guards against regressions (every
saved check keeps passing).
"""

from __future__ import annotations

import json
import re
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


def check_id(title: str) -> str:
    return _ID_RE.sub("-", title.lower()).strip("-")[:60] or "check"


def parse(text: str, id: str = "check", path: Path | None = None) -> Check:
    title = covers = ""
    for line in text.splitlines()[:6]:
        m = re.match(r"\s*--\s*(check|covers):\s*(.*)", line)
        if m and m.group(1) == "check":
            title = m.group(2).strip()
        elif m:
            covers = m.group(2).strip()
    return Check(id=id, title=title or id, covers=covers, body=text, path=path)


def render(check: Check) -> str:
    body = "\n".join(ln for ln in check.body.splitlines()
                     if not re.match(r"\s*--\s*(check|covers):", ln)).strip("\n")
    return f"-- check: {check.title}\n-- covers: {check.covers}\n{body}\n"


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


def wrap(body: str) -> str:
    """The Luau sent to execute_luau: runs the body in a function and returns one JSON line."""
    return (
        'local __http = game:GetService("HttpService")\n'
        "local __ok, __res = pcall(function()\n"
        f"{body}\n"
        "end)\n"
        "if not __ok then return __http:JSONEncode({ ok = false, error = tostring(__res) }) end\n"
        'if type(__res) ~= "table" then\n'
        '  return __http:JSONEncode({ ok = false, error = "check must return { ok = bool, detail = string }" })\n'
        "end\n"
        'return __http:JSONEncode({ ok = __res.ok == true, detail = tostring(__res.detail or "") })\n'
    )


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
