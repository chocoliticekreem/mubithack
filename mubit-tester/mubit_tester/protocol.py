"""The QA protocol: an AI tester that works like a careful senior engineer, with screenshots.

    1. UNDERSTAND  read the spec + acceptance list, census the live game (tags, attributes,
                   leaderstats, counters, first observation), screenshot step-00.
    2. PLAN        `test_planner` (Mubit) writes a numbered plan: hypothesis, action, settle time,
                   expected observable and machine checks per step.
    3. EXECUTE     per step: snapshot before -> act -> settle -> snapshot after + screenshot
                   (step-NN.png) + new console lines + new server errors + game events -> machine
                   checks -> `step_judge` (Mubit; sees the screenshot when the step is visual) when a
                   check fails, an error appears, there are no checks, or the step is visual.
    4. INVESTIGATE on a mismatch: reproduce (run the step again), narrow down (run the read-only
                   probes the judge asked for), then `step_judge` in investigate mode rules with
                   the evidence and writes the bug (repro, root cause, fix target file).
    5. REPORT      pass/fail per acceptance item, bugs with minimal repro, severity, screenshots
                   and fix target, plus `visual_judge` (Mubit, with the key screenshots attached
                   as images) for UI overlap, missing visuals and ugliness.

Everything lands in runs/<slug>/tests/<run_id>/ (report.json, report.md, step-NN.png,
calls.jsonl, traces/); report.json is mirrored to runs/playtests/<run_id>/ so `report`,
`reports`, `suggest_fix` and `playtest_correct` work on it. `correct()` re-runs one of the
protocol's calls (plan = step 0, a step's judge = step n, visual = step -1) with a human note in the
same Mubit task and session, which is how a correction becomes a training example.

System prompts are fixed files (mubit-tester/prompts/{test_planner,step_judge,visual_judge}.md);
everything per call goes in the user message.
"""

from __future__ import annotations

import asyncio
import base64
import dataclasses
import json
import re
import shutil
import subprocess
import time
from contextlib import AsyncExitStack
from pathlib import Path
from typing import Any

from forge import llm as llm_mod
from forge.config import Settings
from mubit_tester import ai, play

ROLES = ("test_planner", "step_judge", "visual_judge")
for _role in ROLES:
    if _role not in llm_mod.ROLES:
        llm_mod.ROLES = tuple(llm_mod.ROLES) + (_role,)

MAX_STEPS = 12
MAX_INVESTIGATIONS = 3
MAX_PROBES = 4
KEY_IMAGES = 4
SETTLE_MAX = 10.0
IMAGE_MAX_BYTES = 3_500_000
IMAGE_MAX_SIDE = 1568
CONSOLE_LINES = 25
VERDICTS = ("pass", "fail", "inconclusive")
SEVERITIES = ("high", "medium", "low")
OPS = ("exists", "missing", "==", "!=", ">", ">=", "<", "<=", "increased", "decreased", "changed",
       "unchanged", "contains", "near")
HARNESS_FILES = ("ForgeTest", "ForgeTestAgent", "ForgeProbe", "ForgeTelemetry")
READ_ONLY_PROBES = ("query", "inspect", "counters", "events", "observe", "console", "screenshot", "config",
                    "players")

_clip = play._clip
_dumps = play._dumps

# Server datamodel: tags (with counts), Workspace attributes and every player's attrs/leaderstats.
STATE_LUAU = r'''
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local function val(v)
	local t = typeof(v)
	if t == "number" then return math.floor(v * 100 + 0.5) / 100 end
	if t == "boolean" or t == "string" then return v end
	return tostring(v)
end
local out = { world = { tags = {}, attrs = {} }, players = {} }
local n = 0
for _, tag in CollectionService:GetAllTags() do
	n += 1
	if n > 40 then break end
	out.world.tags[tag] = #CollectionService:GetTagged(tag)
end
for k, v in workspace:GetAttributes() do out.world.attrs[k] = val(v) end
for _, p in Players:GetPlayers() do
	local e = { userId = p.UserId, name = p.Name, attrs = {}, leaderstats = {} }
	for k, v in p:GetAttributes() do e.attrs[k] = val(v) end
	local ls = p:FindFirstChild("leaderstats")
	if ls then
		for _, c in ls:GetChildren() do
			if c:IsA("ValueBase") then e.leaderstats[c.Name] = val(c.Value) end
		end
	end
	local char = p.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if root then e.pos = { math.floor(root.Position.X + 0.5), math.floor(root.Position.Y + 0.5), math.floor(root.Position.Z + 0.5) } end
	if hum then e.health = math.floor(hum.Health + 0.5) end
	if char then for k, v in char:GetAttributes() do if e.attrs[k] == nil then e.attrs[k] = val(v) end end end
	table.insert(out.players, e)
end
return HttpService:JSONEncode(out)
'''

# Server datamodel: set an attribute, or a ValueBase's Value when key == "Value".
SET_LUAU = r'''
local HttpService = game:GetService("HttpService")
local args = HttpService:JSONDecode(%s)
local cur = game
for seg in string.gmatch(args.path, "[^%%.]+") do
	if not (cur == game and seg == "game") then
		cur = cur:FindFirstChild(seg)
		if not cur then return HttpService:JSONEncode({ ok = false, error = "no instance at " .. args.path }) end
	end
end
if args.key == "Value" and cur:IsA("ValueBase") then cur.Value = args.value else cur:SetAttribute(args.key, args.value) end
return HttpService:JSONEncode({ ok = true })
'''


# --------------------------------------------------------------------------- small helpers


def _long_bracket(s: str) -> str:
    level = 2
    while f"]{'=' * level}]" in s:
        level += 1
    eq = "=" * level
    return f"[{eq}[{s}]{eq}]"


def slug_for(game_dir: Path) -> str:
    """games/<slug>/game or runs/<slug>/game -> <slug>; the repo's game/ -> "game"."""
    game_dir = Path(game_dir)
    return game_dir.parent.name if game_dir.name == "game" and game_dir.parent.name not in ("", ".") \
        and (game_dir.parent / "spec.json").exists() else game_dir.name


def load_spec(game_dir: Path) -> dict:
    path = Path(game_dir).parent / "spec.json"
    try:
        spec = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {k: spec.get(k) for k in ("title", "pitch", "core_loop", "acceptance") if spec.get(k)}


def game_files(game_dir: Path) -> list[str]:
    root = Path(game_dir)
    out = []
    for p in sorted(root.rglob("*.luau")):
        rel = p.relative_to(root).as_posix()
        if rel.startswith(("tools/", ".")) or "/." in rel or p.name.split(".")[0] in HARNESS_FILES:
            continue
        out.append(rel)
    return out


def get_path(obj: Any, path: str) -> tuple[bool, Any]:
    """Dotted path into dicts/lists ("player.leaderstats.Cash", "obs.ui.0.text"). (found, value)."""
    cur = obj
    for seg in [s for s in str(path or "").split(".") if s != ""]:
        if isinstance(cur, dict):
            if seg not in cur:
                return False, None
            cur = cur[seg]
        elif isinstance(cur, list) and re.fullmatch(r"-?\d+", seg):
            i = int(seg)
            if not -len(cur) <= i < len(cur):
                return False, None
            cur = cur[i]
        else:
            return False, None
    return True, cur


def _as_num(v: Any) -> float | None:
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(str(v).strip())
    except (TypeError, ValueError):
        return None


def evaluate_check(check: dict, before: dict, after: dict) -> dict:
    """One machine check against the after-snapshot (and before, for change ops)."""
    path, op, want = str(check.get("path") or ""), str(check.get("op") or "exists"), check.get("value")
    found, actual = get_path(after, path)
    bfound, prev = get_path(before, path)
    out = {"path": path, "op": op, "value": want, "actual": actual, "before": prev if bfound else None}
    ok: bool | None
    if op not in OPS:
        ok, out["note"] = None, f"unknown op {op!r}"
    elif op == "exists":
        ok = found and actual is not None
    elif op == "missing":
        ok = not found or actual is None
    elif not found:
        ok, out["note"] = False, "path not in snapshot"
    elif op in ("increased", "decreased"):
        a, b = _as_num(actual), _as_num(prev)
        if a is None or b is None:
            ok, out["note"] = False, "not a number before and after"
        else:
            ok = a > b if op == "increased" else a < b
    elif op in ("changed", "unchanged"):
        ok = (actual != prev) if op == "changed" else (actual == prev)
    elif op == "contains":
        if isinstance(actual, list):
            ok = any(want == x or (isinstance(x, (str, dict)) and str(want).lower() in _dumps(x).lower())
                     for x in actual)
        else:
            ok = str(want).lower() in str(actual).lower()
    elif op == "near":
        spec = want if isinstance(want, dict) else {}
        pos, radius = spec.get("pos"), _as_num(spec.get("radius")) or 8.0
        try:
            ok = sum((float(x) - float(y)) ** 2 for x, y in zip(actual, pos)) ** 0.5 <= radius
        except (TypeError, ValueError):
            ok, out["note"] = False, "not a position"
    else:
        a, b = _as_num(actual), _as_num(want)
        if op in ("==", "!=") and (a is None or b is None):
            ok = (actual == want) if op == "==" else (actual != want)
        elif a is None or b is None:
            ok, out["note"] = False, "not a number"
        else:
            ok = {"==": a == b, "!=": a != b, ">": a > b, ">=": a >= b, "<": a < b, "<=": a <= b}[op]
    out["ok"] = ok
    return out


def _flat(prefix: str, obj: Any, out: dict) -> None:
    if isinstance(obj, dict):
        for k, v in obj.items():
            _flat(f"{prefix}.{k}" if prefix else str(k), v, out)
    else:
        out[prefix] = obj


def snapshot_diff(before: dict, after: dict) -> dict:
    """What changed between two snapshots: scalar values, HUD lines and buttons."""
    b, a = {}, {}
    for key in ("counters", "player", "world"):
        _flat(key, (before or {}).get(key) or {}, b)
        _flat(key, (after or {}).get(key) or {}, a)
    changed = {k: [b.get(k), a.get(k)] for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)}
    out: dict = {"changed": changed}
    for key in ("hud",):
        bh = [str(x) for x in ((before or {}).get("obs") or {}).get(key) or []]
        ah = [str(x) for x in ((after or {}).get("obs") or {}).get(key) or []]
        if bh != ah:
            out["hud_new"] = [x for x in ah if x not in bh]
            out["hud_gone"] = [x for x in bh if x not in ah]
    bu = {str(x.get("text") or x.get("path")) for x in ((before or {}).get("obs") or {}).get("ui") or [] if isinstance(x, dict)}
    au = {str(x.get("text") or x.get("path")) for x in ((after or {}).get("obs") or {}).get("ui") or [] if isinstance(x, dict)}
    if bu != au:
        out["buttons_new"], out["buttons_gone"] = sorted(au - bu), sorted(bu - au)
    return out


def _err_key(e: Any) -> str:
    return str(e.get("message") if isinstance(e, dict) else e)[:200]


def new_errors(before: list, after: list) -> list[dict]:
    """Probe errors that appeared (or whose count went up) between two probe reports."""
    seen = {}
    for e in before or []:
        seen[_err_key(e)] = int((e.get("count") if isinstance(e, dict) else 1) or 1)
    out = []
    for e in after or []:
        k = _err_key(e)
        cnt = int((e.get("count") if isinstance(e, dict) else 1) or 1)
        if k not in seen or cnt > seen[k]:
            out.append(e if isinstance(e, dict) else {"message": str(e)})
    return out


def _norm_sev(s: Any) -> str:
    s = str(s or "medium").lower()
    return s if s in SEVERITIES else "medium"


# --------------------------------------------------------------------------- vision calls


def _png_size(data: bytes) -> tuple[int, int] | None:
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    return None


def load_image(path: Path) -> tuple[bytes, str] | None:
    """Image bytes + mime for the LLM, downscaled (macOS sips) when too big for the API."""
    path = Path(path)
    if not path.is_file():
        return None
    data = path.read_bytes()
    mime = "image/png" if data[:4] == b"\x89PNG" else "image/jpeg" if data[:2] == b"\xff\xd8" else "image/png"
    size = _png_size(data)
    if (len(data) > IMAGE_MAX_BYTES or (size and max(size) > IMAGE_MAX_SIDE)) and shutil.which("sips"):
        small = path.with_suffix(".llm.jpg")
        try:
            subprocess.run(["sips", "-Z", str(IMAGE_MAX_SIDE), "-s", "format", "jpeg", str(path), "--out", str(small)],
                           check=True, capture_output=True, timeout=30)
            data, mime = small.read_bytes(), "image/jpeg"
        except (OSError, subprocess.SubprocessError):
            pass
    return data, mime


def _mubit_images(llm, role: str, user: str, images: list[tuple[str, bytes, str]], session_id: str,
                  max_tokens: int) -> llm_mod.LLMResult:
    """One Mubit call with images attached (Anthropic or OpenAI shape), logged like MubitLLM.complete."""
    system = llm_mod.load_prompt(role)
    t0 = time.monotonic()
    names = ", ".join(n for n, _, _ in images)
    for attempt in range(1, llm_mod.MAX_TRIES + 1):
        try:
            if llm.provider == "anthropic":
                content = [{"type": "image", "source": {"type": "base64", "media_type": mime,
                                                        "data": base64.b64encode(data).decode()}}
                           for _, data, mime in images] + [{"type": "text", "text": user}]
                raw = llm._client.messages.with_raw_response.create(
                    model=llm.model, max_tokens=max_tokens, system=system,
                    messages=[{"role": "user", "content": content}], metadata={"user_id": session_id})
                msg = raw.parse()
                text = "".join(getattr(b, "text", "") for b in msg.content if getattr(b, "type", "") == "text")
                usage = getattr(msg, "usage", None)
                tin, tout = getattr(usage, "input_tokens", None), getattr(usage, "output_tokens", None)
                model = getattr(msg, "model", None) or llm.model
            else:
                content = [{"type": "text", "text": user}] + [
                    {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{base64.b64encode(data).decode()}"}}
                    for _, data, mime in images]
                raw = llm._client.chat.completions.with_raw_response.create(
                    model=llm.model, max_completion_tokens=max_tokens,
                    messages=[{"role": "system", "content": system}, {"role": "user", "content": content}])
                resp = raw.parse()
                text = (resp.choices[0].message.content or "") if resp.choices else ""
                usage = getattr(resp, "usage", None)
                tin, tout = getattr(usage, "prompt_tokens", None), getattr(usage, "completion_tokens", None)
                model = getattr(resp, "model", None) or llm.model
            rid = llm_mod._header(raw.headers, "x-middleware-request-id")
        except Exception as e:  # noqa: BLE001
            retry, wait, rid = llm._is_retryable(e)
            if not retry or attempt == llm_mod.MAX_TRIES:
                llm._log(role=role, session_id=session_id, model=llm.model, request_id=rid, images=len(images),
                         latency_ms=int((time.monotonic() - t0) * 1000), user_chars=len(user),
                         error=f"{type(e).__name__}: {str(e)[:300]}")
                raise llm_mod.LLMError(f"{role} call failed: {type(e).__name__}: {e}") from e
            llm.sleep(min(wait if wait is not None else 2.0 * attempt, llm_mod.MAX_RETRY_WAIT_S))
            continue
        res = llm_mod.LLMResult(text=text, role=role, request_id=rid, model=model,
                                latency_ms=int((time.monotonic() - t0) * 1000), input_tokens=tin, output_tokens=tout)
        llm._log(role=role, session_id=session_id, model=model, request_id=rid, latency_ms=res.latency_ms,
                 input_tokens=tin, output_tokens=tout, user_chars=len(user), reply_chars=len(text),
                 images=len(images))
        llm._trace(role, session_id, system, user + f"\n\n[attached images: {names}]", text, rid=rid, model=model,
                   latency_ms=res.latency_ms, input_tokens=tin, output_tokens=tout)
        return res
    raise llm_mod.LLMError(f"{role} call failed")  # pragma: no cover


def complete_json_images(llm, role: str, user: str, images: list[Path] | None, *, session_id: str,
                         required: list[str], max_tokens: int = 2048) -> tuple[dict, llm_mod.LLMResult, int]:
    """complete_json with screenshots attached as images. Returns (obj, result, images actually seen).

    Real Mubit clients get the images as image blocks; a client without vision (FakeLLM) gets the
    file names in the text instead, so tests can see what would have been attached."""
    loaded = []
    for p in images or []:
        img = load_image(Path(p))
        if img is not None:
            loaded.append((Path(p).name, img[0], img[1]))
    vision = bool(loaded) and (hasattr(llm, "complete_images") or isinstance(llm, llm_mod.MubitLLM))

    def once(msg: str) -> llm_mod.LLMResult:
        if vision and hasattr(llm, "complete_images"):
            return llm.complete_images(role, msg, loaded, session_id=session_id, max_tokens=max_tokens)
        if vision:
            return _mubit_images(llm, role, msg, loaded, session_id, max_tokens)
        if loaded:
            msg += "\n\n## Attached screenshots\n" + "\n".join(f"- {n}" for n, _, _ in loaded)
        return llm.complete(role, msg, session_id=session_id, max_tokens=max_tokens)

    msg = user
    for attempt in range(llm_mod.JSON_REPAIRS + 1):
        res = once(msg)
        try:
            obj = llm_mod.extract_json_object(res.text)
            llm_mod._check_required(obj, required)
            return obj, res, len(loaded) if vision else 0
        except ValueError as e:
            if attempt == llm_mod.JSON_REPAIRS:
                raise llm_mod.LLMError(f"{role}: no valid JSON after {llm_mod.JSON_REPAIRS} repairs: {e}") from e
            msg = llm_mod._repair_message(user, str(e), res.text)
    raise llm_mod.LLMError("unreachable")  # pragma: no cover


# --------------------------------------------------------------------------- user messages

ACCEPT_CHARS = 3000
CENSUS_CHARS = 6000


def planner_message(spec: dict, census: dict, focus: str | None, budget: int) -> str:
    acc = spec.get("acceptance") or []
    return "\n".join([
        "## Game", f"Title: {spec.get('title') or '(unknown)'}", f"Pitch: {spec.get('pitch') or ''}",
        f"Core loop: {spec.get('core_loop') or ''}", "",
        "## Acceptance (numbered)",
        _clip("\n".join(f"{i}. {a}" for i, a in enumerate(acc, 1)), ACCEPT_CHARS) if acc
        else "(none given: derive acceptance items from the core loop and number them yourself)", "",
        "## Census", _clip(_dumps(census), CENSUS_CHARS), "",
        "## Focus", (focus or "").strip() or "none: cover the acceptance list", "",
        "## Budget", f"at most {budget} steps",
    ])


def judge_message(mode: str, spec: dict, step: dict, files: list[str], *, repro: dict | None = None,
                  evidence: list | None = None) -> str:
    acc = spec.get("acceptance") or []
    covered = [f"{i}. {acc[i - 1]}" for i in step.get("acceptance") or [] if isinstance(i, int) and 0 < i <= len(acc)]
    lines = [
        "## Mode", mode, "",
        "## Game", f"{spec.get('title') or ''}: {_clip(spec.get('core_loop') or '', 600)}",
        "Acceptance covered: " + ("; ".join(covered) if covered else "none listed"), "",
        "## Step",
        f"n={step['n']}; intent: {step.get('intent', '')}; hypothesis: {step.get('hypothesis', '')}",
        f"action: {_dumps(step.get('action') or {})} -> result: {_clip(step.get('result', ''), 400)}",
        f"settle: {step.get('settle')}s; expected: {step.get('expect', '')}", "",
        "## Checks", _clip(_dumps(step.get("checks") or []), 2500) if step.get("checks") else "none planned", "",
        "## Before -> After", _clip(_dumps(step.get("diff") or {}), 2500), "",
        "## After snapshot (player, counters, HUD)",
        _clip(_dumps({k: (step.get("after") or {}).get(k) for k in ("player", "counters")}
                     | {"hud": ((step.get("after") or {}).get("obs") or {}).get("hud"),
                        "ui": ((step.get("after") or {}).get("obs") or {}).get("ui")}), 2000), "",
        "## Events", _clip(_dumps(step.get("events") or []), 1200) if step.get("events") else "none", "",
        "## New errors", _clip(_dumps(step.get("new_errors") or []), 1500) if step.get("new_errors") else "none", "",
        "## Console", _clip("\n".join(step.get("console") or []), 1500) if step.get("console") else "no new lines",
    ]
    if repro is not None:
        lines += ["", "## Reproduction (the same step run again)", _clip(_dumps(repro), 2500)]
    if evidence is not None:
        lines += ["", "## Evidence (your probes)", _clip(_dumps(evidence), 4000) if evidence else "none"]
    lines += ["", "## Game files", "\n".join(files) or "(none found)"]
    if step.get("screenshot"):
        lines += ["", "## Screenshot", f"{Path(step['screenshot']).name} (attached when the step is visual)"]
    return "\n".join(lines)


def visual_message(spec: dict, shots: list[dict]) -> str:
    return "\n".join([
        "## Game", f"Title: {spec.get('title') or ''}", f"Pitch: {spec.get('pitch') or ''}",
        f"Core loop: {_clip(spec.get('core_loop') or '', 800)}", "",
        "## Screenshots (attached in this order)",
        *[f"{i}. {Path(s['path']).name} (step {s['n']}): {_clip(s.get('what') or '', 200)}; expected on screen: "
          f"{_clip(s.get('expect') or '', 200)}" for i, s in enumerate(shots, 1)],
    ])


# --------------------------------------------------------------------------- the tester


class _Tester:
    def __init__(self, settings: Settings, harness, studio, llm, report: dict, test_dir: Path, spec: dict,
                 files: list[str], game_dir: Path):
        self.settings, self.harness, self.studio, self.llm = settings, harness, studio, llm
        self.report, self.dir, self.spec, self.files, self.game_dir = report, test_dir, spec, files, game_dir
        self.uid: Any = None
        self.since: Any = None
        self.errors_seen: list = []
        self.console_len = 0

    def save(self) -> None:
        save(self.settings, self.report)

    # ---- observation

    async def state(self) -> dict:
        if self.studio is None or not hasattr(self.studio, "execute_luau"):
            return {}
        try:
            text = await asyncio.wait_for(self.studio.execute_luau(STATE_LUAU, "Server"), play.STUDIO_TIMEOUT)
            obj = play._parse_json(text)
            return obj if isinstance(obj, dict) else {"error": _clip(text, 200)}
        except Exception as e:  # noqa: BLE001
            return {"error": f"{type(e).__name__}: {_clip(str(e), 200)}"}

    async def snapshot(self) -> dict:
        state, obs, counters = await asyncio.gather(self.state(), ai._observe(self.harness, self.uid),
                                                    ai._counters(self.harness))
        me = next((p for p in state.get("players") or [] if str(p.get("userId")) == str(self.uid)), None) \
            or (state.get("players") or [{}])[0]
        player = dict(me or {})
        if not player.get("pos") and isinstance(obs, dict):
            player["pos"] = (obs.get("me") or {}).get("pos")
        snap = {"counters": counters if isinstance(counters, dict) else {}, "player": player,
                "world": state.get("world") or {}, "obs": play.compact_observation(obs or {}),
                "errors": {"new": 0}, "events": {"kinds": []}}
        if state.get("error"):
            snap["state_error"] = state["error"]
        return snap

    async def probe_errors(self) -> list:
        probe = await ai._probe(self.harness)
        return list(probe.get("errors") or []) if isinstance(probe, dict) else []

    async def console_delta(self) -> list[str]:
        if self.studio is None or not hasattr(self.studio, "console"):
            return []
        try:
            text = await asyncio.wait_for(self.studio.console(), play.STUDIO_TIMEOUT)
        except Exception:  # noqa: BLE001
            return []
        text = str(text or "")
        new = text[self.console_len:] if len(text) >= self.console_len else text
        self.console_len = len(text)
        return [ln for ln in new.splitlines() if ln.strip()][-CONSOLE_LINES:]

    async def screenshot(self, name: str) -> str | None:
        if self.studio is None or not hasattr(self.studio, "screenshot"):
            return None
        try:
            path = await asyncio.wait_for(self.studio.screenshot(self.dir / name), play.STUDIO_TIMEOUT)
        except Exception as e:  # noqa: BLE001
            self.report["errors"].append(f"screenshot {name}: {type(e).__name__}: {_clip(str(e), 200)}")
            return None
        if path:
            rel = str(Path(path))
            self.report["screenshots"].append(rel)
            return rel
        return None

    # ---- acting

    async def act(self, action: dict) -> str:
        name = str(action.get("action") or "observe")
        args = action.get("args") if isinstance(action.get("args"), dict) else {}
        if name in ("observe", "none", ""):
            return "observed (no action)"
        if name == "teleport":
            target = {k: args[k] for k in ("pos", "path") if args.get(k) is not None}
            if not target:
                return "error: teleport needs pos or path"
            try:
                res = await asyncio.wait_for(self.harness.call("teleport", userId=self.uid, **target), ai.ACT_TIMEOUT)
                return f"teleport {_dumps(target)} -> {_clip(res, 200)}"
            except Exception as e:  # noqa: BLE001
                return f"error: teleport: {type(e).__name__}: {_clip(str(e), 200)}"
        if name == "set_attr":
            if not args.get("path") or not args.get("key"):
                return "error: set_attr needs path and key"
            code = SET_LUAU % _long_bracket(_dumps({"path": str(args["path"]), "key": str(args["key"]),
                                                     "value": args.get("value")}))
            try:
                res = await asyncio.wait_for(self.studio.execute_luau(code, "Server"), play.STUDIO_TIMEOUT)
                return f"set_attr {_dumps(args)} -> {_clip(res, 200)}"
            except Exception as e:  # noqa: BLE001
                return f"error: set_attr: {type(e).__name__}: {_clip(str(e), 200)}"
        return await ai.dispatch(self.harness, self.uid, {"action": name, "args": args})

    async def run_once(self, step: dict, shot_name: str) -> dict:
        """act -> settle -> observe; returns {before, after, result, diff, checks, events, new_errors, console, screenshot}."""
        before = await self.snapshot()
        errs_before = self.errors_seen
        await self.console_delta()
        _, self.since = await ai._events(self.harness, self.since)
        t0 = time.monotonic()
        result = await self.act(step.get("action") or {})
        settle = float(step.get("settle") or 0)
        if settle > 0:
            await asyncio.sleep(settle)
        events, self.since = await ai._events(self.harness, self.since)
        after, errs_after, console = await asyncio.gather(self.snapshot(), self.probe_errors(), self.console_delta())
        fresh = new_errors(errs_before, errs_after)
        self.errors_seen = errs_after or errs_before
        evs = ai._compact_events(events)
        after["errors"] = {"new": len(fresh)}
        after["events"] = {"kinds": sorted({str(e.get("kind")) for e in evs if isinstance(e, dict)})}
        shot = await self.screenshot(shot_name)
        checks = [evaluate_check(c, before, after) for c in step.get("checks") or [] if isinstance(c, dict)]
        return {"before": before, "after": after, "result": result, "diff": snapshot_diff(before, after),
                "checks": checks, "events": evs, "new_errors": fresh[:6], "console": console,
                "screenshot": shot, "act_ms": int((time.monotonic() - t0) * 1000)}

    # ---- LLM calls

    async def call(self, role: str, user: str, required: list[str], images: list | None = None,
                   max_tokens: int = 2048) -> tuple[dict, Any, int]:
        obj, res, seen = await play._to_thread(
            complete_json_images, self.llm, role, user, images or [], session_id=self.report["session_id"],
            required=required, max_tokens=max_tokens)
        if res.request_id:
            self.report["request_ids"].append(res.request_id)
        return obj, res, seen

    async def judge(self, step: dict, mode: str, repro: dict | None = None, evidence: list | None = None) -> dict:
        user = judge_message(mode, self.spec, step, self.files, repro=repro, evidence=evidence)
        images = [step["screenshot"]] if step.get("visual") and step.get("screenshot") else []
        if repro and repro.get("screenshot") and step.get("visual"):
            images.append(repro["screenshot"])
        verdict, res, seen = await self.call("step_judge", user, ["verdict", "actual", "reason"], images)
        v = str(verdict.get("verdict") or "").lower()
        verdict["verdict"] = v if v in VERDICTS else "inconclusive"
        step.setdefault("judge_calls", []).append({"mode": mode, "user": user, "images": [str(p) for p in images],
                                                   "request_id": res.request_id, "reply": verdict,
                                                   "images_seen": seen})
        return verdict

    async def run_probes(self, probes: list) -> list[dict]:
        out = []
        for p in [p for p in probes or [] if isinstance(p, dict)][:MAX_PROBES]:
            cmd, args = str(p.get("cmd") or ""), p.get("args") if isinstance(p.get("args"), dict) else {}
            item: dict = {"cmd": cmd, "args": args}
            try:
                if cmd not in READ_ONLY_PROBES:
                    item["result"] = f"refused: {cmd!r} is not a read-only probe"
                elif cmd == "observe":
                    item["result"] = play.compact_observation(await ai._observe(self.harness, self.uid), 2500)
                elif cmd == "counters":
                    item["result"] = await ai._counters(self.harness)
                elif cmd == "events":
                    evs, _ = await ai._events(self.harness, None)
                    item["result"] = ai._compact_events(evs)
                elif cmd == "console":
                    text = await asyncio.wait_for(self.studio.console(), play.STUDIO_TIMEOUT)
                    item["result"] = str(text or "").splitlines()[-CONSOLE_LINES:]
                elif cmd == "screenshot":
                    n = len([x for x in self.report["screenshots"] if "-probe" in x]) + 1
                    item["result"] = await self.screenshot(f"probe-{n:02d}.png")
                elif cmd == "players":
                    item["result"] = (await self.state()).get("players")
                else:
                    item["result"] = await asyncio.wait_for(self.harness.call(cmd, **args), play.STUDIO_TIMEOUT)
            except Exception as e:  # noqa: BLE001
                item["result"] = f"error: {type(e).__name__}: {_clip(str(e), 200)}"
            if len(_dumps(item["result"])) > 1500:
                item["result"] = _clip(_dumps(item["result"]), 1500)
            out.append(item)
        return out

    # ---- phases

    async def understand(self, player: Any) -> dict:
        t0 = time.monotonic()
        if hasattr(self.harness, "ensure_ready"):
            self.report["ready"] = await self.harness.ensure_ready()
        roster = list(await self.harness.players() or [])
        if not roster:
            raise RuntimeError("no players connected")
        me = ai._select_players(roster, [player])[0] if player is not None else roster[0]
        self.uid = ai._pid(me)
        self.report["player"] = {"userId": self.uid, "name": me.get("name")}
        _, self.since = await ai._events(self.harness, None)
        self.errors_seen = await self.probe_errors()
        await self.console_delta()
        snap = await self.snapshot()
        shot = await self.screenshot("step-00.png")
        census = {"tags": (snap.get("world") or {}).get("tags"), "workspace_attrs": (snap.get("world") or {}).get("attrs"),
                  "player": snap.get("player"), "counters": snap.get("counters"), "observation": snap.get("obs"),
                  "errors_at_start": [_err_key(e) for e in self.errors_seen][:6]}
        out = {"spec": self.spec, "census": census, "files": self.files, "screenshot": shot,
               "baseline": snap, "ms": int((time.monotonic() - t0) * 1000)}
        self.report["understand"] = out
        self.save()
        return out

    async def plan(self, focus: str | None, budget: int) -> list[dict]:
        t0 = time.monotonic()
        user = planner_message(self.spec, self.report["understand"]["census"], focus, budget)
        entry: dict = {"user": user}
        try:
            plan, res, _ = await self.call("test_planner", user, ["steps"], max_tokens=6000)
            entry.update(request_id=res.request_id, understanding=str(plan.get("understanding") or ""),
                         risks=list(plan.get("risks") or []), hypotheses=list(plan.get("hypotheses") or []))
            steps = normalize_plan(plan.get("steps"), budget)
        except Exception as e:  # noqa: BLE001
            self.report["errors"].append(f"plan: {type(e).__name__}: {_clip(str(e), 300)}")
            steps = fallback_plan(self.spec)
            entry["fallback"] = True
        entry["steps"] = steps
        entry["ms"] = int((time.monotonic() - t0) * 1000)
        self.report["plan"] = entry
        self.save()
        return steps

    async def execute(self, steps: list[dict], max_investigations: int) -> None:
        investigations = 0
        for planned in steps:
            t0 = time.monotonic()
            n = planned["n"]
            step = dict(planned)
            step.update(await self.run_once(planned, f"step-{n:02d}.png"))
            failed = [c for c in step["checks"] if c.get("ok") is False]
            needs_llm = not step["checks"] or failed or step["new_errors"] or step.get("visual") \
                or any(c.get("ok") is None for c in step["checks"])
            if needs_llm:
                try:
                    verdict = await self.judge(step, "judge")
                except Exception as e:  # noqa: BLE001
                    verdict = {"verdict": "fail" if failed or step["new_errors"] else "inconclusive",
                               "actual": "", "reason": f"step_judge failed ({type(e).__name__}); machine checks decide",
                               "probes": [], "bug": None, "decided_by": "checks"}
                    self.report["errors"].append(f"step {n} judge: {type(e).__name__}: {_clip(str(e), 200)}")
                else:
                    verdict["decided_by"] = "step_judge"
            else:
                verdict = {"verdict": "pass", "actual": "; ".join(f"{c['path']}={_clip(c['actual'], 40)}"
                                                                 for c in step["checks"]),
                           "reason": "all machine checks passed, no new errors", "decided_by": "checks",
                           "probes": [], "bug": None}
            step["verdict"] = verdict
            if verdict["verdict"] != "pass" and investigations < max_investigations and \
                    (verdict["verdict"] == "fail" or verdict.get("probes")):
                investigations += 1
                await self.investigate(step)
            step["final"] = step.get("investigation", {}).get("verdict") or verdict
            step["ms"] = int((time.monotonic() - t0) * 1000)
            self.report["steps"].append(step)
            self.save()

    async def investigate(self, step: dict) -> None:
        """Systematic-debugging mini loop: reproduce -> narrow (probes) -> rule with evidence."""
        t0 = time.monotonic()
        n = step["n"]
        rep = await self.run_once(step, f"step-{n:02d}-repro.png")
        failed_again = [c for c in rep["checks"] if c.get("ok") is False]
        repro = {"result": rep["result"], "checks": rep["checks"], "diff": rep["diff"],
                 "new_errors": rep["new_errors"], "events": rep["events"][-8:], "screenshot": rep["screenshot"],
                 "reproduced": bool(failed_again or rep["new_errors"]) if rep["checks"] or rep["new_errors"] else None}
        evidence = await self.run_probes(step["verdict"].get("probes") or [])
        inv: dict = {"reproduce": repro, "evidence": evidence}
        try:
            final = await self.judge(step, "investigate", repro=repro, evidence=evidence)
            final["decided_by"] = "step_judge"
        except Exception as e:  # noqa: BLE001
            final = dict(step["verdict"], reason=step["verdict"].get("reason", "") +
                         f" (investigate judge failed: {type(e).__name__})")
        inv["verdict"] = final
        inv["ms"] = int((time.monotonic() - t0) * 1000)
        step["investigation"] = inv
        self.report["investigations"].append({"step": n, "reproduced": repro["reproduced"],
                                              "verdict": final.get("verdict"), "probes": [e["cmd"] for e in evidence]})

    async def visual(self, key_images: int) -> dict:
        shots = pick_key_shots(self.report, key_images)
        if not shots:
            return {"skipped": "no screenshots"}
        user = visual_message(self.spec, shots)
        try:
            out, res, seen = await self.call("visual_judge", user, ["summary", "issues"],
                                             [s["path"] for s in shots], max_tokens=2500)
        except Exception as e:  # noqa: BLE001
            self.report["errors"].append(f"visual_judge: {type(e).__name__}: {_clip(str(e), 200)}")
            return {"error": str(e)[:200], "screenshots": [s["path"] for s in shots]}
        issues = [i for i in out.get("issues") or [] if isinstance(i, dict) and i.get("title")]
        return {"summary": str(out.get("summary") or ""), "score": out.get("score"), "issues": issues,
                "screenshots": [s["path"] for s in shots], "images_seen": seen, "user": user,
                "request_id": res.request_id}


def normalize_plan(raw: Any, budget: int) -> list[dict]:
    steps = []
    for item in raw if isinstance(raw, list) else []:
        if not isinstance(item, dict):
            continue
        action = item.get("action")
        if isinstance(action, str):
            action = {"action": action, "args": item.get("args") or {}}
        if not isinstance(action, dict):
            action = {"action": "observe"}
        if not isinstance(action.get("args"), dict):
            action["args"] = {}
        checks = [c for c in item.get("checks") or [] if isinstance(c, dict) and c.get("path")]
        acc = [int(a) for a in item.get("acceptance") or [] if str(a).strip().isdigit()]
        steps.append({
            "n": len(steps) + 1, "intent": str(item.get("intent") or ""), "hypothesis": str(item.get("hypothesis") or ""),
            "acceptance": acc, "action": action, "settle": max(0.0, min(play._num(item.get("settle"), 1.0), SETTLE_MAX)),
            "expect": str(item.get("expect") or ""), "checks": checks,
            "screenshot_key": bool(item.get("screenshot_key")), "visual": bool(item.get("visual")),
        })
        if len(steps) >= budget:
            break
    if not steps:
        raise ValueError("the plan has no usable steps")
    return steps


def fallback_plan(spec: dict) -> list[dict]:
    """No plan from the LLM: one baseline look that at least checks errors and takes a screenshot."""
    return [{"n": 1, "intent": "baseline: the game runs without errors", "hypothesis": "H1: the game starts cleanly",
             "acceptance": list(range(1, len(spec.get("acceptance") or []) + 1)), "action": {"action": "observe", "args": {}},
             "settle": 2.0, "expect": "no new server errors", "checks": [{"path": "errors.new", "op": "==", "value": 0}],
             "screenshot_key": True, "visual": True}]


def pick_key_shots(report: dict, limit: int) -> list[dict]:
    """step-00, then failing steps, then key/visual steps, then the last step; at most `limit`."""
    und = report.get("understand") or {}
    cands: list[dict] = []
    if und.get("screenshot"):
        cands.append({"n": 0, "path": und["screenshot"], "what": "first look after spawning",
                      "expect": "the game world and HUD as described in the pitch", "prio": 1})
    steps = report.get("steps") or []
    for s in steps:
        if not s.get("screenshot"):
            continue
        verdict = (s.get("final") or {}).get("verdict")
        prio = 0 if verdict == "fail" else 2 if (s.get("screenshot_key") or s.get("visual")) else 4
        cands.append({"n": s["n"], "path": s["screenshot"], "what": s.get("intent"), "expect": s.get("expect"),
                      "prio": prio})
    if steps and steps[-1].get("screenshot"):
        for c in cands:
            if c["n"] == steps[-1]["n"]:
                c["prio"] = min(c["prio"], 3)
    chosen = sorted(cands, key=lambda c: (c["prio"], c["n"]))[:max(0, limit)]
    return sorted(chosen, key=lambda c: c["n"])


def _fix_target(settings: Settings, game_dir: Path, files: list[str], suggested: Any, text: str) -> str | None:
    s = str(suggested or "").strip().lstrip("/")
    for f in files:
        if s and (s == f or f.endswith(s) or s.endswith(f)):
            return f
    try:
        cands = ai.find_candidate_files(dataclasses.replace(settings, base_game_dir=Path(game_dir)), text, limit=3)
    except Exception:  # noqa: BLE001
        cands = []
    cands = [c for c, _ in cands if c in files]
    return cands[0] if cands else None


def build_findings(settings: Settings, report: dict, game_dir: Path) -> None:
    """Fill report.acceptance, report.bugs, report.goal_met and report.summary from the steps."""
    spec = (report.get("understand") or {}).get("spec") or {}
    files = (report.get("understand") or {}).get("files") or []
    acc = spec.get("acceptance") or []
    steps = report.get("steps") or []
    items = []
    for i, text in enumerate(acc, 1):
        cover = [s for s in steps if i in (s.get("acceptance") or [])]
        verdicts = [(s.get("final") or {}).get("verdict") for s in cover]
        status = "untested" if not cover else "fail" if "fail" in verdicts else \
            "pass" if "pass" in verdicts else "inconclusive"
        items.append({"n": i, "text": text, "status": status, "steps": [s["n"] for s in cover],
                      "evidence": "; ".join(f"step {s['n']}: {_clip((s.get('final') or {}).get('actual') or '', 160)}"
                                            for s in cover)[:600]})
    report["acceptance"] = items

    bugs: list[dict] = []
    seen: set = set()

    def add(bug: dict) -> None:
        key = re.sub(r"\W+", " ", bug["title"].lower()).strip()
        if key in seen:
            return
        seen.add(key)
        bug["id"] = len(bugs) + 1
        bugs.append(bug)

    for s in steps:
        final = s.get("final") or {}
        if final.get("verdict") != "fail":
            continue
        raw = final.get("bug") if isinstance(final.get("bug"), dict) else {}
        failed = [c for c in s.get("checks") or [] if c.get("ok") is False]
        title = str(raw.get("title") or "").strip() or f"Step {s['n']} failed: {_clip(s.get('intent'), 80)}"
        actual = str(raw.get("actual") or final.get("actual") or "")
        shots = [p for p in (s.get("screenshot"), (s.get("investigation") or {}).get("reproduce", {}).get("screenshot")) if p]
        repro = raw.get("repro") if isinstance(raw.get("repro"), list) and raw.get("repro") else [
            f"{s['n']}. {s.get('intent')}: {_dumps(s.get('action'))}, wait {s.get('settle')}s"]
        text = " ".join([title, actual, str(raw.get("root_cause") or ""), " ".join(_err_key(e) for e in s.get("new_errors") or [])])
        add({
            "title": title, "severity": _norm_sev(raw.get("severity") or ("high" if s.get("new_errors") else "medium")),
            "category": "behaviour", "step": s["n"], "acceptance": s.get("acceptance") or [],
            "repro": [str(r) for r in repro], "expected": str(raw.get("expected") or s.get("expect") or ""),
            "actual": actual, "root_cause": str(raw.get("root_cause") or final.get("reason") or ""),
            "failed_checks": failed, "reproduced": (s.get("investigation") or {}).get("reproduce", {}).get("reproduced"),
            "screenshots": shots, "fix_target": _fix_target(settings, game_dir, files, raw.get("fix_target"), text),
            "evidence": _clip(f"step {s['n']}: {actual} | {final.get('reason', '')}", 600),
        })
    for s in steps:  # server errors the judge did not turn into a bug
        for e in s.get("new_errors") or []:
            msg = _err_key(e)
            if any(msg[:60] in (b["actual"] + b["root_cause"] + b["evidence"]) for b in bugs):
                continue
            add({"title": f"Server error: {_clip(msg, 90)}", "severity": "high", "category": "error", "step": s["n"],
                 "acceptance": [], "repro": [f"{s['n']}. {s.get('intent')}: {_dumps(s.get('action'))}"],
                 "expected": "no server errors", "actual": msg, "root_cause": _clip(str(e.get("trace") or ""), 400)
                 if isinstance(e, dict) else "", "failed_checks": [], "reproduced": None,
                 "screenshots": [s["screenshot"]] if s.get("screenshot") else [],
                 "fix_target": _fix_target(settings, game_dir, files, (e.get("script") if isinstance(e, dict) else None), msg),
                 "evidence": _clip(f"step {s['n']}: {msg}", 400)})
    vis = report.get("visual") or {}
    for v in vis.get("issues") or []:
        sev = _norm_sev(v.get("severity"))
        text = f"{v.get('title')} {v.get('detail', '')} {v.get('suggestion', '')} hud gui screen label"
        shot = next((p for p in vis.get("screenshots") or [] if Path(p).name == str(v.get("screenshot") or "")), None)
        add({"title": f"Visual: {v['title']}", "severity": sev, "category": "visual", "kind": v.get("kind"),
             "step": None, "acceptance": [], "repro": [f"look at {v.get('screenshot') or 'the screenshot'}"],
             "expected": str(v.get("suggestion") or ""), "actual": str(v.get("detail") or ""), "root_cause": "",
             "failed_checks": [], "reproduced": None, "screenshots": [shot] if shot else [],
             "fix_target": _fix_target(settings, game_dir, files, None, text),
             "evidence": _clip(f"{v.get('screenshot')}: {v.get('detail', '')}", 400)})
    order = {"high": 0, "medium": 1, "low": 2}
    bugs.sort(key=lambda b: (order[b["severity"]], b["category"] == "visual", b["id"]))
    for i, b in enumerate(bugs, 1):
        b["id"] = i
    report["bugs"] = bugs
    statuses = [a["status"] for a in items]
    report["goal_met"] = False if "fail" in statuses else (True if statuses and all(s == "pass" for s in statuses) else None)
    counts = {k: statuses.count(k) for k in ("pass", "fail", "inconclusive", "untested")}
    report["acceptance_counts"] = counts
    report["summary"] = (f"{counts['pass']}/{len(items)} acceptance items pass, {counts['fail']} fail, "
                         f"{counts['inconclusive']} inconclusive, {counts['untested']} untested; "
                         f"{len(steps)} steps, {len(report.get('investigations') or [])} investigations, "
                         f"{len(bugs)} bugs ({sum(b['category'] == 'visual' for b in bugs)} visual).")
    if vis.get("summary"):
        report["summary"] += f" Visual ({vis.get('score')}/10): {vis['summary']}"


def render_markdown(report: dict) -> str:
    """report.md: what a human reads first."""
    def rel(p: Any) -> str:
        return Path(str(p)).name if p else "-"

    plan = report.get("plan") or {}
    out = [f"# QA report: {(report.get('understand') or {}).get('spec', {}).get('title') or report.get('slug')}",
           "", f"Run `{report['run_id']}`, {report.get('started')} to {report.get('ended')}. "
           f"Player {(report.get('player') or {}).get('name')}. Session `{report.get('session_id')}`.",
           "", f"**Verdict:** {report.get('summary', '')}", "",
           "## 1. Understand", "", plan.get("understanding") or "(no understanding written)", ""]
    if plan.get("risks"):
        out += ["Risks: " + "; ".join(str(r) for r in plan["risks"]), ""]
    out += ["## 2. Plan", ""]
    for h in plan.get("hypotheses") or []:
        out.append(f"- {h}")
    out += ["", "| # | intent | action | expected | checks |", "|---|---|---|---|---|"]
    for s in plan.get("steps") or []:
        out.append(f"| {s['n']} | {_clip(s.get('intent'), 70)} | `{_clip(_dumps(s.get('action')), 60)}` | "
                   f"{_clip(s.get('expect'), 70)} | {len(s.get('checks') or [])} |")
    out += ["", "## 3. Execute", "", "| # | verdict | by | checks | actual | screenshot |", "|---|---|---|---|---|---|"]
    for s in report.get("steps") or []:
        f = s.get("final") or {}
        ok = sum(1 for c in s.get("checks") or [] if c.get("ok"))
        out.append(f"| {s['n']} | **{f.get('verdict')}** | {f.get('decided_by', '')} | {ok}/{len(s.get('checks') or [])} | "
                   f"{_clip(f.get('actual') or '', 90).replace('|', '/')} | {rel(s.get('screenshot'))} |")
    invs = report.get("investigations") or []
    out += ["", "## 4. Investigate", ""]
    if not invs:
        out.append("No mismatches needed investigating.")
    for s in report.get("steps") or []:
        inv = s.get("investigation")
        if inv:
            out.append(f"- Step {s['n']}: reproduced={inv['reproduce'].get('reproduced')}, probes="
                       f"{[e['cmd'] for e in inv.get('evidence') or []]}, verdict **{inv['verdict'].get('verdict')}**: "
                       f"{_clip(inv['verdict'].get('reason'), 240)}")
    out += ["", "## 5. Report", "", "### Acceptance", "", "| # | status | item | steps |", "|---|---|---|---|"]
    for a in report.get("acceptance") or []:
        out.append(f"| {a['n']} | **{a['status']}** | {_clip(a['text'], 110)} | {a['steps']} |")
    out += ["", "### Bugs", ""]
    if not report.get("bugs"):
        out.append("None found.")
    for b in report.get("bugs") or []:
        out += [f"**{b['id']}. [{b['severity']}] {b['title']}** ({b['category']}; fix target `{b.get('fix_target') or '?'}`)",
                "", "Repro: " + " -> ".join(b.get("repro") or []),
                f"Expected: {b.get('expected')}  ", f"Actual: {b.get('actual')}  "]
        if b.get("root_cause"):
            out.append(f"Root cause: {_clip(b['root_cause'], 400)}  ")
        if b.get("screenshots"):
            out.append("Screenshots: " + ", ".join(rel(p) for p in b["screenshots"]))
        out.append("")
    vis = report.get("visual") or {}
    if vis.get("summary"):
        out += ["### Visual review", "", f"Score {vis.get('score')}/10 ({vis.get('images_seen', 0)} screenshots seen): "
                f"{vis['summary']}", ""]
    out += ["### Timings", "", _dumps(report.get("timings") or {}), "",
            "Correct any judgement with `playtest_correct(run_id, step, note)`: step 0 = the plan, n = step n's "
            "judge, -1 = the visual review."]
    return "\n".join(out)


def save(settings: Settings, report: dict) -> None:
    play._save_report(settings, report)
    d = Path(report["test_dir"])
    d.mkdir(parents=True, exist_ok=True)
    tmp = d / "report.json.tmp"
    tmp.write_text(json.dumps(report, indent=2, ensure_ascii=False, default=str), encoding="utf-8")
    tmp.replace(d / "report.json")


# --------------------------------------------------------------------------- entry points


async def qa_test(settings: Settings, focus: str | None = None, *, game_dir: Path | str | None = None,
                  slug: str | None = None, max_steps: int = MAX_STEPS, player: Any = None, llm=None, studio=None,
                  harness=None, studio_name: str | None = None, max_investigations: int = MAX_INVESTIGATIONS,
                  key_images: int = KEY_IMAGES, stop: bool = True) -> dict:
    """Run the 5-phase QA protocol against the game playing in Studio; returns (and saves) the report."""
    game_dir = Path(game_dir) if game_dir else Path(settings.base_game_dir)
    slug = slug or slug_for(game_dir)
    run_id = play._new_run_id()
    test_dir = Path(settings.runs_dir) / slug / "tests" / run_id
    test_dir.mkdir(parents=True, exist_ok=True)
    if llm is None:
        llm = llm_mod.make_llm(settings, log_path=test_dir / "calls.jsonl")
    spec = load_spec(game_dir)
    report: dict = {
        "run_id": run_id, "kind": "protocol", "agent_role": "step_judge", "session_id": "qa-" + run_id,
        "slug": slug, "game_dir": str(game_dir), "test_dir": str(test_dir), "goal": focus or
        f"QA protocol: verify the acceptance list of {spec.get('title') or slug}", "started": play._now_iso(),
        "ended": None, "max_steps": max_steps, "studio": None, "goal_met": None, "summary": "", "player": None,
        "understand": {}, "plan": {}, "steps": [], "investigations": [], "acceptance": [], "bugs": [],
        "visual": {}, "screenshots": [], "request_ids": [], "corrections": [], "errors": [], "timings": {},
    }
    files = game_files(game_dir)
    t_all = time.monotonic()
    async with AsyncExitStack() as stack:
        if harness is None:
            if studio is None:
                from forge.studio import Studio

                studio = await stack.enter_async_context(Studio(settings))
                await studio.select(studio_name)
            elif studio_name:
                await studio.select(studio_name)
            from mubit_tester.harness import Harness

            harness = Harness(studio)
        studio = studio if studio is not None else getattr(harness, "studio", None)
        report["studio"] = getattr(studio, "studio_id", None) or studio_name
        tester = _Tester(settings, harness, studio, llm, report, test_dir, spec, files, game_dir)
        tester.save()
        try:
            t = time.monotonic()
            await tester.understand(player)
            report["timings"]["understand_ms"] = int((time.monotonic() - t) * 1000)
            t = time.monotonic()
            steps = await tester.plan(focus, max(1, int(max_steps)))
            report["timings"]["plan_ms"] = int((time.monotonic() - t) * 1000)
            t = time.monotonic()
            await tester.execute(steps, max_investigations)
            report["timings"]["execute_ms"] = int((time.monotonic() - t) * 1000)
            t = time.monotonic()
            report["visual"] = await tester.visual(key_images)
            report["timings"]["visual_ms"] = int((time.monotonic() - t) * 1000)
        except Exception as e:  # noqa: BLE001
            report["errors"].append(f"{type(e).__name__}: {_clip(str(e), 500)}")
        finally:
            if stop and getattr(harness, "started_play", False) and studio is not None and hasattr(studio, "stop"):
                try:
                    await studio.stop()
                except Exception as e:  # noqa: BLE001
                    report["errors"].append(f"stop: {type(e).__name__}: {e}")
    build_findings(settings, report, game_dir)
    report["timings"]["total_ms"] = int((time.monotonic() - t_all) * 1000)
    report["ended"] = play._now_iso()
    save(settings, report)
    (test_dir / "report.md").write_text(render_markdown(report), encoding="utf-8")
    return report


async def correct(settings: Settings, run_id: str, step: int, note: str, *, llm=None) -> dict:
    """Re-run one protocol call with a human correction, in the same Mubit task and session.

    step 0 = the plan (`test_planner`), step n = step n's last judgement (`step_judge`),
    step -1 = the visual review (`visual_judge`). The corrected reply is recorded in the report."""
    if not note or not note.strip():
        raise ValueError("correction note is empty")
    report = play.load_report(settings, run_id)
    test_dir = Path(report.get("test_dir") or play._run_dir(settings, run_id))
    if llm is None:
        llm = llm_mod.make_llm(settings, log_path=test_dir / "calls.jsonl")
    images: list = []
    if step == 0:
        role, user, required = "test_planner", (report.get("plan") or {}).get("user"), ["steps"]
        before = {k: (report.get("plan") or {}).get(k) for k in ("understanding", "hypotheses", "steps")}
    elif step < 0:
        vis = report.get("visual") or {}
        role, user, required = "visual_judge", vis.get("user"), ["summary", "issues"]
        images = list(vis.get("screenshots") or [])
        before = {k: vis.get(k) for k in ("summary", "score", "issues")}
    else:
        target = next((s for s in report.get("steps") or [] if s.get("n") == step), None)
        if target is None:
            raise ValueError(f"run {run_id} has no step {step}")
        calls = target.get("judge_calls") or []
        if not calls:  # decided by machine checks alone: build the judge message now
            spec = (report.get("understand") or {}).get("spec") or {}
            user = judge_message("judge", spec, target, (report.get("understand") or {}).get("files") or [])
            images = [target["screenshot"]] if target.get("screenshot") else []
        else:
            user, images = calls[-1]["user"], list(calls[-1].get("images") or [])
        role, required = "step_judge", ["verdict", "actual", "reason"]
        before = target.get("final") or {}
    if not user:
        raise ValueError(f"run {run_id} has no recorded {role} call to correct")
    user = user + "\n\n## Correction from a human tester\n" + note.strip()
    after, res, seen = await play._to_thread(
        complete_json_images, llm, role, user, images, session_id=report.get("session_id") or "qa-" + run_id,
        required=required, max_tokens=6000 if role == "test_planner" else 2500)
    out = {"run_id": run_id, "step": step, "role": role, "before": before, "after": after,
           "request_id": res.request_id, "images_seen": seen}
    report.setdefault("corrections", []).append({**out, "note": note.strip(), "ts": play._now_iso()})
    if res.request_id:
        report.setdefault("request_ids", []).append(res.request_id)
    save(settings, report)
    return out
