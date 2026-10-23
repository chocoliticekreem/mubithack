"""Scripted, LLM-free scenarios with assertions, run through the in-game harness (docs/TESTER.md).

A scenario is JSON:

    {"name": "smoke", "description": "...", "stop_on_fail": true,
     "steps": [
       {"call": {"cmd": "players"}, "save": "start"},
       {"act": {"player": "all", "action": "walk_to", "offset": [10, 0, 0]}},
       {"wait_until": {"cmd": "players", "path": "result.*.pos", "op": "moved",
                       "from": "$start.*.pos", "value": 8, "timeout": 15}},
       {"assert": {"cmd": "probe", "path": "result.errors", "op": "len==", "value": 0}},
       {"wait": 1}
     ]}

Step kinds:
- `call`  {cmd, args?}: run a harness command (or `probe` for the ForgeProbe report); fails on error.
- `act`   {player | "all", action, args?, offset?}: client action; `offset` [dx,dy,dz] walks/aims
  relative to that player's current position (fills args.pos). Fails if the reply has done=false.
- `wait_until` / `assert` {cmd, args?, path, op, value?, from?, timeout?, interval?}: poll the
  command (wait_until, default 10 s) or check it once (assert). `any: [cond, ...]` passes when any
  of the sub-conditions holds.
- `wait` seconds.
Any step may have `"save": "<var>"` (stores the step's result) and `"label"`.

Paths are dotted (`result.0.attrs.Water`); `*` maps over a list (the condition must hold for every
element). Strings `"$var.path"` anywhere in args/value/from are replaced by saved values.

Ops: `<` `>` `<=` `>=` `==` `!=` `exists` `missing` `truthy` `falsy` `contains` (list element,
substring, or substring of the JSON), `len==` `len>=` `len<=` `len>` `len<`, `changed` / `increased`
/ `decreased` (versus `from`, or the first polled value), `moved` (vector distance from `from` >=
value studs).
"""

from __future__ import annotations

import asyncio
import copy
import json
import math
import time
from pathlib import Path
from typing import Any

from mubit_tester.harness import HarnessError

DEFAULT_WAIT_TIMEOUT = 10.0
DEFAULT_INTERVAL = 0.5
STEP_KINDS = ("call", "act", "wait_until", "assert", "wait")
_MISSING = object()


class ScenarioError(ValueError):
    pass


# ---------------------------------------------------------------- loading

def scenarios_dir(repo_root: Path) -> Path:
    return Path(repo_root) / "mubit-tester" / "scenarios"


def list_scenarios(repo_root: Path) -> list[dict]:
    out = []
    for p in sorted(scenarios_dir(repo_root).glob("*.json")):
        try:
            sc = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            out.append({"name": p.stem, "file": p.name, "error": str(e)})
            continue
        out.append({"name": sc.get("name") or p.stem, "file": p.name,
                    "description": sc.get("description", ""), "steps": len(sc.get("steps") or [])})
    return out


def load_scenario(spec: str | dict, repo_root: Path) -> dict:
    """A dict, a JSON string, a path, or a name in scenarios/ (with or without .json)."""
    if isinstance(spec, dict):
        sc = spec
    else:
        s = spec.strip()
        if s.startswith("{"):
            sc = json.loads(s)
        else:
            cands = [Path(s), scenarios_dir(repo_root) / s, scenarios_dir(repo_root) / f"{s}.json"]
            path = next((c for c in cands if c.is_file()), None)
            if path is None:
                names = ", ".join(x["name"] for x in list_scenarios(repo_root)) or "none"
                raise ScenarioError(f"no scenario {spec!r} (available: {names})")
            sc = json.loads(path.read_text(encoding="utf-8"))
            sc.setdefault("name", path.stem)
    validate(sc)
    return sc


def validate(sc: Any) -> None:
    if not isinstance(sc, dict):
        raise ScenarioError("scenario must be a JSON object")
    steps = sc.get("steps")
    if not isinstance(steps, list) or not steps:
        raise ScenarioError("scenario needs a non-empty 'steps' list")
    for i, st in enumerate(steps, 1):
        kinds = [k for k in STEP_KINDS if isinstance(st, dict) and k in st]
        if len(kinds) != 1:
            raise ScenarioError(f"step {i}: needs exactly one of {', '.join(STEP_KINDS)}")


# ---------------------------------------------------------------- paths and variables

def get_path(obj: Any, path: str | None) -> Any:
    """Dotted path lookup; `*` maps over a list. Returns _MISSING when absent."""
    if not path:
        return obj
    parts = str(path).split(".")
    cur = obj
    for i, part in enumerate(parts):
        if part == "*":
            if not isinstance(cur, list):
                return _MISSING
            rest = ".".join(parts[i + 1:])
            return [get_path(x, rest) for x in cur]
        if isinstance(cur, dict):
            if part not in cur:
                return _MISSING
            cur = cur[part]
        elif isinstance(cur, list):
            try:
                cur = cur[int(part)]
            except (ValueError, IndexError):
                return _MISSING
        else:
            return _MISSING
    return cur


def resolve(value: Any, vars: dict) -> Any:
    """Replace "$var.path" strings (recursively) with saved values."""
    if isinstance(value, str) and value.startswith("$") and len(value) > 1:
        name, _, rest = value[1:].partition(".")
        if name not in vars:
            raise ScenarioError(f"unknown variable ${name}")
        got = get_path(vars[name], rest)
        if got is _MISSING:
            raise ScenarioError(f"{value}: path not found")
        return copy.deepcopy(got)
    if isinstance(value, dict):
        return {k: resolve(v, vars) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve(v, vars) for v in value]
    return value


# ---------------------------------------------------------------- ops

def _vec(v: Any) -> list[float] | None:
    if isinstance(v, dict):
        v = [v.get("x", v.get("X")), v.get("y", v.get("Y")), v.get("z", v.get("Z"))]
    if isinstance(v, (list, tuple)) and len(v) >= 3 and all(isinstance(x, (int, float)) for x in v[:3]):
        return [float(x) for x in v[:3]]
    return None


def _num(v: Any) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def compare(op: str, got: Any, value: Any = None, base: Any = _MISSING) -> bool:
    """One scalar comparison (no `*` mapping here)."""
    if op == "exists":
        return got is not _MISSING and got is not None
    if op == "missing":
        return got is _MISSING or got is None
    if got is _MISSING:
        return False
    if op == "truthy":
        return bool(got)
    if op == "falsy":
        return not got
    if op == "==":
        return got == value or (_num(got) is not None and _num(value) is not None and _num(got) == _num(value))
    if op == "!=":
        return not compare("==", got, value)
    if op in ("<", ">", "<=", ">="):
        a, b = _num(got), _num(value)
        if a is None or b is None:
            return False
        return {"<": a < b, ">": a > b, "<=": a <= b, ">=": a >= b}[op]
    if op.startswith("len"):
        if not hasattr(got, "__len__"):
            return False
        return compare(op[3:], len(got), value)
    if op == "contains":
        if isinstance(got, str):
            return str(value) in got
        if isinstance(got, list) and any(compare("==", x, value) for x in got):
            return True
        if isinstance(value, dict) and isinstance(got, list):
            return any(isinstance(x, dict) and all(x.get(k) == v for k, v in value.items()) for x in got)
        return isinstance(value, str) and value in json.dumps(got, ensure_ascii=False, default=str)
    if op in ("changed", "increased", "decreased"):
        if base is _MISSING:
            return False
        if op == "changed":
            return got != base
        a, b = _num(got), _num(base if base is not None else 0)
        if a is None or b is None:
            return False
        return a > b if op == "increased" else a < b
    if op == "moved":
        a, b = _vec(got), _vec(base)
        if a is None or b is None:
            return False
        return math.dist(a, b) >= float(value if value is not None else 1)
    raise ScenarioError(f"unknown op {op!r}")


def check(cond: dict, result: Any, base: Any = _MISSING) -> tuple[bool, Any]:
    """Evaluate one condition against a command result. Returns (ok, observed value)."""
    op = cond.get("op", "exists")
    got = get_path({"result": result}, cond.get("path", "result"))
    value = cond.get("value")
    if isinstance(got, list) and "*" in str(cond.get("path", "")):
        if not got:
            return False, got
        bases = base if isinstance(base, list) else [base] * len(got)
        if len(bases) < len(got):
            bases = bases + [_MISSING] * (len(got) - len(bases))
        return all(compare(op, g, value, b) for g, b in zip(got, bases)), got
    return compare(op, got, value, base), got


# ---------------------------------------------------------------- runner

def _short(v: Any, n: int = 200) -> str:
    if v is _MISSING:
        return "<missing>"
    s = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False, default=str)
    return s if len(s) <= n else s[: n - 1] + "…"


async def _run_cmd(h, cmd: str, args: dict) -> Any:
    if cmd == "probe":
        return await h.probe()
    return await h.call(cmd, **args)


async def _player_pos(h, player: Any) -> list[float] | None:
    for p in await h.players():
        if str(player) in (str(p.get("name")), str(p.get("userId")), str(p.get("helmet"))):
            return _vec(p.get("pos"))
    return None


async def _step_act(h, spec: dict) -> tuple[bool, str, Any]:
    action = spec.get("action")
    if not action:
        raise ScenarioError("act needs an 'action'")
    args = dict(spec.get("args") or {})
    player = spec.get("player", "all")
    offset = _vec(spec.get("offset"))
    targets = [player] if str(player) != "all" else [p.get("userId") for p in await h.players()]
    if not targets:
        return False, "no players connected", None

    async def one(pid: Any) -> Any:
        a = dict(args)
        if offset is not None:
            pos = await _player_pos(h, pid)
            if pos is None:
                return {"done": False, "error": f"player {pid} has no position"}
            a.setdefault("pos", [pos[i] + offset[i] for i in range(3)])
        try:
            return await h.act(pid, action, **a)
        except HarnessError as e:
            return {"done": False, "error": str(e)}

    results = await asyncio.gather(*(one(t) for t in targets))
    ok = all(not (isinstance(r, dict) and (r.get("done") is False or r.get("error"))) for r in results)
    result = results[0] if len(results) == 1 and str(player) != "all" else results
    return ok, f"{action} x{len(targets)}: {_short(results)}", result


async def _step_cond(h, spec: dict, vars: dict, poll: bool) -> tuple[bool, str, Any]:
    conds = spec.get("any") or [spec]
    timeout = float(spec.get("timeout", DEFAULT_WAIT_TIMEOUT if poll else 0))
    interval = float(spec.get("interval", DEFAULT_INTERVAL))
    bases: list[Any] = []
    for c in conds:
        if "cmd" not in c:
            raise ScenarioError("condition needs a 'cmd'")
        if "from" in c:
            try:
                bases.append(resolve(c["from"], vars))
            except ScenarioError:  # e.g. an attribute that wasn't set yet: compare against nil
                bases.append(None)
        else:
            bases.append(_MISSING)
    deadline = time.monotonic() + timeout
    last: list[str] = []
    while True:
        last = []
        for i, c in enumerate(conds):
            c = {**c, "value": resolve(c.get("value"), vars)}
            try:
                result = await _run_cmd(h, c["cmd"], resolve(c.get("args") or {}, vars))
            except HarnessError as e:
                last.append(f"{c['cmd']}: {e}")
                continue
            if bases[i] is _MISSING and c.get("op") in ("changed", "increased", "decreased", "moved"):
                bases[i] = get_path({"result": result}, c.get("path", "result"))
                if poll:  # first poll is the baseline
                    last.append(f"{c.get('path')} baseline {_short(bases[i], 80)}")
                    continue
            ok, got = check(c, result, bases[i])
            desc = f"{c.get('path', 'result')} {c.get('op', 'exists')} {_short(c.get('value'), 60)}"
            if ok:
                return True, f"{desc}: got {_short(got, 120)}", result
            last.append(f"{desc}: got {_short(got, 120)}")
        if not poll or time.monotonic() >= deadline:
            break
        await asyncio.sleep(interval)
    suffix = f" (after {timeout:g}s)" if poll else ""
    return False, "; ".join(last) + suffix, None


async def run_scenario(harness, scenario: dict) -> dict:
    """Run a scenario; returns {name, passed, steps: [{n, kind, ok, detail, ms}], events}."""
    validate(scenario)
    name = scenario.get("name", "scenario")
    stop_on_fail = scenario.get("stop_on_fail", True)
    vars: dict[str, Any] = dict(scenario.get("vars") or {})
    out_steps: list[dict] = []
    t_start = None
    try:
        ev = await harness.events()
        t_start = ev.get("now") if isinstance(ev, dict) else None
    except Exception:  # noqa: BLE001  (event log is a nice-to-have)
        pass

    passed = True
    for n, step in enumerate(scenario["steps"], 1):
        kind = next(k for k in STEP_KINDS if k in step)
        spec = step[kind]
        t0 = time.monotonic()
        result: Any = None
        try:
            if kind == "wait":
                secs = float(spec if not isinstance(spec, dict) else spec.get("seconds", 1))
                await asyncio.sleep(secs)
                ok, detail = True, f"waited {secs:g}s"
            elif kind == "call":
                spec = resolve(spec, vars)
                result = await _run_cmd(harness, spec["cmd"], spec.get("args") or {})
                ok, detail = True, f"{spec['cmd']}: {_short(result)}"
            elif kind == "act":
                ok, detail, result = await _step_act(harness, resolve(spec, vars))
            else:
                ok, detail, result = await _step_cond(harness, spec, vars, poll=(kind == "wait_until"))
        except (HarnessError, ScenarioError, KeyError) as e:
            ok, detail = False, f"{type(e).__name__}: {e}"
        if ok and step.get("save"):
            vars[step["save"]] = result
        rec = {"n": n, "kind": kind, "ok": ok, "detail": detail, "ms": int((time.monotonic() - t0) * 1000)}
        if step.get("label"):
            rec["label"] = step["label"]
        out_steps.append(rec)
        if not ok:
            passed = False
            if stop_on_fail:
                break

    events: list = []
    try:
        ev = await harness.events(t_start)
        events = (ev.get("events") if isinstance(ev, dict) else ev) or []
    except Exception:  # noqa: BLE001
        pass
    return {"name": name, "passed": passed and len(out_steps) == len(scenario["steps"]),
            "steps": out_steps, "events": events}


def format_result(res: dict, max_events: int = 30) -> str:
    mark = "PASS" if res.get("passed") else "FAIL"
    out = [f"## Scenario `{res.get('name')}`: {mark}", "", "| n | step | ok | ms | detail |", "|---|---|---|---|---|"]
    for s in res.get("steps") or []:
        label = s.get("label") or s.get("kind")
        detail = " ".join(str(s.get("detail", "")).split()).replace("|", "\\|")[:220]
        out.append(f"| {s['n']} | {label} | {'ok' if s['ok'] else 'FAIL'} | {s['ms']} | {detail} |")
    evs = res.get("events") or []
    if evs:
        out += ["", f"### Events ({len(evs)}, last {min(len(evs), max_events)})"]
        for e in evs[-max_events:]:
            if isinstance(e, dict):
                out.append(f"- t={e.get('t')} {e.get('kind')} {_short(e.get('data'), 160)}")
            else:
                out.append(f"- {_short(e, 160)}")
    return "\n".join(out)
