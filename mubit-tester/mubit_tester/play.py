"""AI playtester: a Mubit-backed agent that plays the Roblox game in Studio toward a goal.

Each step: OBSERVE (execute_luau in the Client datamodel -> compact JSON; ForgeProbe report merged
every 5th step) -> DECIDE (`player` role, fixed system prompt forge/prompts/player.md) -> ACT
(StudioMCP input tools). At the end the `judge` role turns the trace into {goal_met, summary, bugs}.

A human can correct one step later with `correct_step`: it re-runs the `player` call for that step
with the same observation plus a "## Correction from a human tester" section, so the corrected reply
is a recorded call in the same Mubit task (that is how a correction becomes training data).

Reports: runs/playtests/<run_id>/report.json (+ calls.jsonl).
"""

from __future__ import annotations

import asyncio
import json
import re
import secrets
import time
from contextlib import AsyncExitStack
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from forge import llm as llm_mod
from forge.config import Settings

# The player/judge roles are owned by this module; register them so load_prompt/FakeLLM accept
# them even if forge.llm.ROLES does not list them yet (module global, read at call time).
for _role in ("player", "judge"):
    if _role not in llm_mod.ROLES:
        llm_mod.ROLES = tuple(llm_mod.ROLES) + (_role,)

ACTIONS = ("move_to", "move_to_instance", "interact", "key", "spray", "equip", "wait", "done")
OBS_MAX_CHARS = 4000  # room for `ui` (on-screen buttons) next to things/prompts/hud
UI_KEEP = 4
PROBE_EVERY = 5
HISTORY = 5
LLM_TIMEOUT = 180.0
STUDIO_TIMEOUT = 60.0
NAV_TIMEOUT = 45.0
RESULT_CHARS = 300
SLOT_KEYS = ("One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine")

# Runs in the Client datamodel during play. Returns one JSON string.
OBSERVE_LUAU = r'''
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local lp = Players.LocalPlayer
local function r1(n) return math.floor(n * 10 + 0.5) / 10 end
local function v3(v) return { math.floor(v.X + 0.5), math.floor(v.Y + 0.5), math.floor(v.Z + 0.5) } end
local function val(v)
	local t = typeof(v)
	if t == "number" then return r1(v) end
	if t == "boolean" or t == "string" then return v end
	return tostring(v)
end
local function posOf(inst)
	if not inst then return nil end
	if inst:IsA("BasePart") then return inst.Position end
	if inst:IsA("Attachment") then return inst.WorldPosition end
	if inst:IsA("Model") then
		local ok, cf = pcall(inst.GetPivot, inst)
		if ok then return cf.Position end
	end
	local part = inst:FindFirstAncestorWhichIsA("BasePart")
	return part and part.Position or nil
end

local out = { me = {}, world = {}, things = {}, prompts = {}, hud = {} }
local char = lp and lp.Character
local root = char and char:FindFirstChild("HumanoidRootPart")
local hum = char and char:FindFirstChildOfClass("Humanoid")
local origin = root and root.Position
if origin then out.me.pos = v3(origin) end
if hum then
	out.me.health = math.floor(hum.Health + 0.5)
	out.me.max_health = math.floor(hum.MaxHealth + 0.5)
end
if not char then out.me.no_character = true end
local attrs = {}
for _, k in { "Water", "TankSize", "Carrying", "Helmet", "Downed" } do
	local v = lp and lp:GetAttribute(k)
	if v == nil and char then v = char:GetAttribute(k) end
	if v ~= nil then attrs[k] = val(v) end
end
out.me.attrs = attrs
local tool = char and char:FindFirstChildOfClass("Tool")
out.me.tool = tool and tool.Name or nil
local bp = {}
local backpack = lp and lp:FindFirstChildOfClass("Backpack")
if backpack then
	for _, t in backpack:GetChildren() do
		if t:IsA("Tool") then table.insert(bp, t.Name) end
	end
end
out.me.backpack = bp
for _, k in { "RoundState", "RoundEndsAt", "MissionId" } do
	local v = workspace:GetAttribute(k)
	if v ~= nil then out.world[k] = val(v) end
end
out.world.now = math.floor(workspace:GetServerTimeNow())

local TAGS = { "Burning", "Flammable", "Door", "Hydrant", "TruckRefill", "RescueDropoff", "Rescuable", "Truck", "StationSpawn" }
local seen = {}
local things = {}
for _, tag in TAGS do
	for _, inst in CollectionService:GetTagged(tag) do
		if not seen[inst] and inst:IsDescendantOf(workspace) then
			local burning = CollectionService:HasTag(inst, "Burning") or (tonumber(inst:GetAttribute("FireLevel")) or 0) > 0
			if tag ~= "Flammable" or burning then
				local p = posOf(inst)
				if p then
					local d = origin and (p - origin).Magnitude or 0
					if d <= 120 then
						seen[inst] = true
						local e = { name = inst.Name, path = inst:GetFullName(), tag = tag, dist = math.floor(d + 0.5), pos = v3(p) }
						for _, a in { "Locked", "Broken", "FireLevel", "RescueState", "Kind" } do
							local v = inst:GetAttribute(a)
							if v ~= nil then e[a] = val(v) end
						end
						table.insert(things, e)
					end
				end
			end
		end
	end
end
table.sort(things, function(a, b) return a.dist < b.dist end)
for i = 1, math.min(12, #things) do table.insert(out.things, things[i]) end

local prompts = {}
for _, d in workspace:GetDescendants() do
	if d:IsA("ProximityPrompt") and d.Enabled then
		local p = posOf(d.Parent)
		if p then
			local dist = origin and (p - origin).Magnitude or 0
			if dist <= 60 then
				table.insert(prompts, {
					action = d.ActionText, object = d.ObjectText, dist = math.floor(dist + 0.5),
					range = d.MaxActivationDistance, in_range = dist <= d.MaxActivationDistance,
					hold = r1(d.HoldDuration), key = d.KeyboardKeyCode.Name, path = d.Parent:GetFullName(),
				})
			end
		end
	end
end
table.sort(prompts, function(a, b) return a.dist < b.dist end)
for i = 1, math.min(6, #prompts) do table.insert(out.prompts, prompts[i]) end

local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
local function shown(g)
	local cur = g
	while cur and cur ~= pg do
		if cur:IsA("GuiObject") and not cur.Visible then return false end
		if cur:IsA("LayerCollector") and not cur.Enabled then return false end
		cur = cur.Parent
	end
	return true
end
if pg then
	for _, g in pg:GetDescendants() do
		if #out.hud >= 10 then break end
		if (g:IsA("TextLabel") or g:IsA("TextButton")) and g.TextTransparency < 1 and shown(g) then
			local t = g.ContentText ~= "" and g.ContentText or g.Text
			t = (string.gsub(t, "%s+", " "))
			t = string.match(t, "^%s*(.-)%s*$") or ""
			if t ~= "" then table.insert(out.hud, string.sub(t, 1, 80)) end
		end
	end
end
return HttpService:JSONEncode(out)
'''


# --------------------------------------------------------------------------- paths / io


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _new_run_id() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + secrets.token_hex(2)


def _playtests_dir(settings: Settings) -> Path:
    return Path(settings.runs_dir) / "playtests"


def _run_dir(settings: Settings, run_id: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", run_id or "") or run_id in (".", ".."):
        raise ValueError(f"bad run id {run_id!r}")
    return _playtests_dir(settings) / run_id


def _save_report(settings: Settings, report: dict) -> Path:
    d = _run_dir(settings, report["run_id"])
    d.mkdir(parents=True, exist_ok=True)
    path = d / "report.json"
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp.replace(path)
    return path


def load_report(settings: Settings, run_id: str) -> dict:
    path = _run_dir(settings, run_id) / "report.json"
    if not path.exists():
        raise FileNotFoundError(f"no playtest report for run {run_id!r} at {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def list_reports(settings: Settings) -> list[dict]:
    """Newest first: [{run_id, goal, goal_met, n_steps, bugs}] (bugs = number of bugs)."""
    root = _playtests_dir(settings)
    out: list[tuple[str, dict]] = []
    if not root.exists():
        return []
    for p in root.glob("*/report.json"):
        try:
            rep = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        run_id = rep.get("run_id") or p.parent.name
        out.append((
            str(rep.get("started") or "") + run_id,
            {
                "run_id": run_id,
                "goal": rep.get("goal", ""),
                "goal_met": rep.get("goal_met"),
                "n_steps": len(rep.get("steps") or []),
                "bugs": len(rep.get("bugs") or []),
            },
        ))
    out.sort(key=lambda t: t[0], reverse=True)
    return [d for _, d in out]


# --------------------------------------------------------------------------- helpers


def _clip(s: Any, n: int) -> str:
    s = s if isinstance(s, str) else json.dumps(s, ensure_ascii=False, default=str)
    return s if len(s) <= n else s[: n - 3] + "..."


def _dumps(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"), default=str)


def _parse_json(text: str) -> Any:
    from forge.studio import extract_json  # lazy: keeps this module importable without mcp

    return extract_json(text)


def compact_observation(obs: dict, limit: int = OBS_MAX_CHARS) -> dict:
    """Trim list fields until the JSON is under `limit` characters."""
    obs = dict(obs)
    order = ("hud", "things", "touchables", "prompts")
    while len(_dumps(obs)) >= limit:
        trimmed = False
        for key in order:
            items = obs.get(key)
            if isinstance(items, list) and len(items) > 2:
                obs[key] = items[: max(2, len(items) - 2)]
                trimmed = True
        if not trimmed:
            probe = obs.get("probe")
            if isinstance(probe, dict) and probe:
                obs["probe"] = {"errors": (probe.get("errors") or [])[:2]}
                if len(_dumps(obs)) >= limit:
                    obs.pop("probe", None)
                continue
            # on-screen buttons are how testers reach a feature's UI: trimmed late, never below UI_KEEP
            for key in ("panels", "ui"):
                items = obs.get(key)
                if isinstance(items, list) and len(items) > UI_KEEP:
                    obs[key] = items[:-1]
                    trimmed = True
            if trimmed:
                continue
            for key in order:
                if isinstance(obs.get(key), list) and obs[key]:
                    obs[key] = obs[key][:-1]
                    trimmed = True
            if not trimmed:
                break
    return obs


def summarize_probe(probe: dict) -> dict:
    """Compact ForgeProbe report for the observation."""
    if not isinstance(probe, dict):
        return {"error": _clip(probe, 200)}
    if "error" in probe and "errors" not in probe:
        return {"error": _clip(probe.get("error"), 200)}
    errs = []
    for e in (probe.get("errors") or [])[:5]:
        if isinstance(e, dict):
            item = {"message": _clip(e.get("message", ""), 200)}
            if e.get("script"):
                item["script"] = e["script"]
            if e.get("count", 1) != 1:
                item["count"] = e.get("count")
            errs.append(item)
        else:
            errs.append({"message": _clip(e, 200)})
    out: dict = {"errors": errs, "n_errors": len(probe.get("errors") or [])}
    warns = probe.get("warnings") or []
    if warns:
        out["n_warnings"] = len(warns)
    if probe.get("counters"):
        out["counters"] = probe["counters"]
    return out


def _norm_key(key: Any) -> str:
    k = str(key or "E").strip()
    if not k:
        return "E"
    if k.isdigit() and len(k) == 1:
        return "Zero" if k == "0" else SLOT_KEYS[int(k) - 1]
    if len(k) == 1 and k.isalpha():
        return k.upper()
    aliases = {"space": "Space", "enter": "Return", "return": "Return", "esc": "Escape",
               "escape": "Escape", "tab": "Tab", "shift": "LeftShift", "ctrl": "LeftControl",
               "backspace": "Backspace"}
    return aliases.get(k.lower(), k[0].upper() + k[1:])


def _num(v: Any, default: float) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _norm_bug(b: Any) -> dict | None:
    if not b:
        return None
    if isinstance(b, str):
        return {"title": _clip(b, 120), "evidence": "", "severity": "medium"}
    if not isinstance(b, dict):
        return None
    title = str(b.get("title") or "").strip()
    if not title:
        return None
    sev = str(b.get("severity") or "medium").lower()
    if sev not in ("low", "medium", "high"):
        sev = "medium"
    return {"title": title, "evidence": str(b.get("evidence") or ""), "severity": sev}


def _pick_prompt(obs: dict, path: str | None) -> dict | None:
    prompts = [p for p in (obs.get("prompts") or []) if isinstance(p, dict)]
    if path:
        for p in prompts:
            ppath = str(p.get("path") or "")
            if ppath == path or ppath.endswith(path) or path.endswith(ppath):
                return p
    in_range = [p for p in prompts if p.get("in_range")]
    return (in_range or prompts or [None])[0]


def _norm_path(path: str) -> str:
    p = str(path).strip()
    if p.startswith(("game.", "Workspace", "LocalPlayer")):
        return p
    return "game." + p


async def _to_thread(fn, *args, timeout: float = LLM_TIMEOUT, **kwargs):
    return await asyncio.wait_for(asyncio.to_thread(fn, *args, **kwargs), timeout)


# --------------------------------------------------------------------------- user messages


def player_user_message(goal: str, n: int, total: int, observation: dict, history: list[dict]) -> str:
    lines = [
        "## Goal", goal.strip(), "",
        "## Step", f"{n} of {total}", "",
        "## Observation", _dumps(observation), "",
        "## Recent actions (oldest first)",
    ]
    if history:
        for h in history:
            lines.append(
                f"- step {h['n']}: {h.get('action', {}).get('action', '?')} "
                f"{_dumps(h.get('action', {}).get('args') or {})} -> {_clip(h.get('result', ''), 200)}"
            )
    else:
        lines.append("- none yet")
    return "\n".join(lines)


def _history_for(steps: list[dict], n: int) -> list[dict]:
    prev = [s for s in steps if s.get("n", 0) < n]
    return prev[-HISTORY:]


def _obs_brief(obs: dict) -> str:
    if not isinstance(obs, dict):
        return ""
    if obs.get("error"):
        return "obs error: " + _clip(obs["error"], 120)
    me = obs.get("me") or {}
    parts = []
    if me.get("pos"):
        parts.append(f"pos={me['pos']}")
    if me.get("attrs"):
        parts.append("attrs=" + _dumps(me["attrs"]))
    if me.get("tool"):
        parts.append(f"tool={me['tool']}")
    things = obs.get("things") or []
    if things:
        parts.append("near=" + ",".join(
            f"{t.get('name')}[{t.get('tag')}]@{t.get('dist')}"
            + (f" FL{t['FireLevel']}" if "FireLevel" in t else "")
            for t in things[:4]
        ))
    if obs.get("prompts"):
        parts.append("prompts=" + ",".join(str(p.get("action")) for p in obs["prompts"][:3]))
    if obs.get("touchables"):
        parts.append("touch=" + ",".join(f"{t.get('label') or t.get('name')}@{t.get('dist')}"
                                         for t in obs["touchables"][:3]))
    if obs.get("hud"):
        parts.append("hud=" + _clip(" | ".join(obs["hud"][:4]), 120))
    if obs.get("panels"):
        parts.append("panels=" + ",".join(str(p.get("title") or p.get("path")) for p in obs["panels"][:3]
                                          if isinstance(p, dict)))
    if obs.get("ui"):
        parts.append("ui=" + _clip(",".join(str(b.get("text") or b.get("path")) for b in obs["ui"][:6]
                                            if isinstance(b, dict)), 120))
    return "; ".join(parts)


def judge_user_message(goal: str, steps: list[dict], final_obs: dict, probe: dict, hints: list[dict]) -> str:
    trace = []
    for s in steps:
        a = s.get("action") or {}
        trace.append(
            f"{s['n']}. {a.get('action', '?')} {_dumps(a.get('args') or {})} | reason: "
            f"{_clip(a.get('reason', ''), 120)} | result: {_clip(s.get('result', ''), 160)} | "
            f"obs: {_obs_brief(s.get('observation') or {})}"
        )
    trace_text = "\n".join(trace)
    if len(trace_text) > 12000:
        trace_text = trace_text[:4000] + "\n...[middle steps omitted]...\n" + trace_text[-7000:]
    return "\n".join([
        "## Goal", goal.strip(), "",
        "## Trace", trace_text or "(no steps ran)", "",
        "## Final observation", _dumps(compact_observation(final_obs or {})), "",
        "## ForgeProbe (server)", _dumps(summarize_probe(probe or {})), "",
        "## Bugs flagged by the playtester", _dumps(hints) if hints else "none",
    ])


# --------------------------------------------------------------------------- studio side


async def observe(studio, n: int) -> dict:
    """Client-side observation, plus the ForgeProbe summary every PROBE_EVERY steps."""
    try:
        text = await asyncio.wait_for(studio.execute_luau(OBSERVE_LUAU, "Client"), STUDIO_TIMEOUT)
        obs = _parse_json(text)
        if not isinstance(obs, dict):
            obs = {"error": f"unparseable observation: {_clip(text, 300)}"}
    except Exception as e:  # noqa: BLE001
        obs = {"error": f"{type(e).__name__}: {_clip(str(e), 300)}"}
    if (n - 1) % PROBE_EVERY == 0:
        try:
            probe = await asyncio.wait_for(studio.probe_report(), STUDIO_TIMEOUT)
        except Exception as e:  # noqa: BLE001
            probe = {"error": f"{type(e).__name__}: {e}"}
        obs["probe"] = summarize_probe(probe)
    return compact_observation(obs)


async def _call(studio, tool: str, timeout: float = STUDIO_TIMEOUT, **args) -> str:
    return await asyncio.wait_for(studio.call(tool, **args), timeout)


async def act(studio, action: dict, obs: dict) -> str:
    """Dispatch one player action to StudioMCP. Returns a short result text."""
    name = action.get("action")
    args = action.get("args") or {}
    if not isinstance(args, dict):
        args = {}
    if name == "move_to":
        x, y, z = (args.get(k) for k in ("x", "y", "z"))
        if None in (x, y, z) and isinstance(args.get("pos"), list) and len(args["pos"]) == 3:
            x, y, z = args["pos"]
        if None in (x, y, z):
            return "error: move_to needs x, y, z"
        res = await _call(studio, "character_navigation", NAV_TIMEOUT, datamodel_type="Client",
                          x=float(x), y=float(y), z=float(z))
        return "moved: " + _clip(res, RESULT_CHARS)
    if name == "move_to_instance":
        path = args.get("path") or args.get("instance_path")
        if not path:
            return "error: move_to_instance needs path"
        res = await _call(studio, "character_navigation", NAV_TIMEOUT, datamodel_type="Client",
                          instance_path=_norm_path(path))
        return "moved: " + _clip(res, RESULT_CHARS)
    if name == "interact":
        prompt = _pick_prompt(obs, args.get("path"))
        key = _norm_key(args.get("key") or (prompt or {}).get("key") or "E")
        hold = _num(args.get("hold"), _num((prompt or {}).get("hold"), 0.0))
        if hold > 0:
            ms = int(min(hold + 0.3, 10.0) * 1000)
            actions = [{"action": "keyDown", "key_code": key},
                       {"action": "wait", "wait_time_ms": ms},
                       {"action": "keyUp", "key_code": key}]
        else:
            actions = [{"action": "keyPress", "key_code": key}]
        res = await _call(studio, "user_keyboard_input", datamodel_type="Client", actions=actions)
        what = f" ({prompt.get('action')} {prompt.get('object') or ''})".rstrip() if prompt else " (no prompt in view)"
        return f"pressed {key}" + (f" for {hold:.1f}s" if hold > 0 else "") + what + ": " + _clip(res, 200)
    if name == "key":
        key = _norm_key(args.get("key"))
        res = await _call(studio, "user_keyboard_input", datamodel_type="Client",
                          actions=[{"action": "keyPress", "key_code": key}])
        return f"pressed {key}: " + _clip(res, 200)
    if name == "spray":
        ms = int(max(200, min(_num(args.get("ms"), 1500), 8000)))
        actions: list[dict] = []
        target = args.get("target") or args.get("path")
        if target:
            actions.append({"action": "moveTo", "instance_path": _norm_path(target)})
        actions += [{"action": "mouseButtonDown", "mouse_button": "left"},
                    {"action": "wait", "wait_time_ms": ms},
                    {"action": "mouseButtonUp", "mouse_button": "left"}]
        res = await _call(studio, "user_mouse_input", STUDIO_TIMEOUT + ms / 1000,
                          datamodel_type="Client", actions=actions)
        return f"sprayed {ms}ms" + (f" at {target}" if target else "") + ": " + _clip(res, 200)
    if name == "equip":
        slot = int(_num(args.get("slot"), 1))
        if not 1 <= slot <= 9:
            return f"error: slot {slot} out of range 1-9"
        key = SLOT_KEYS[slot - 1]
        res = await _call(studio, "user_keyboard_input", datamodel_type="Client",
                          actions=[{"action": "keyPress", "key_code": key}])
        return f"pressed {key} (slot {slot}): " + _clip(res, 200)
    if name == "wait":
        secs = max(0.0, min(_num(args.get("seconds"), 2.0), 10.0))
        await asyncio.sleep(secs)
        return f"waited {secs:.1f}s"
    if name == "done":
        return "done"
    return f"error: unknown action {name!r}; expected one of {', '.join(ACTIONS)}"


# --------------------------------------------------------------------------- main loop


async def playtest(
    settings: Settings,
    goal: str,
    steps: int = 20,
    studio_name: str | None = None,
    *,
    llm=None,
    studio=None,
    step_seconds: float = 2.0,
) -> dict:
    """Play the game in Studio toward `goal` for up to `steps` steps; return (and save) the report."""
    run_id = _new_run_id()
    run_dir = _run_dir(settings, run_id)
    run_dir.mkdir(parents=True, exist_ok=True)
    if llm is None:
        llm = llm_mod.make_llm(settings, log_path=run_dir / "calls.jsonl")
    session_id = "playtest-" + run_id

    report: dict = {
        "run_id": run_id, "goal": goal, "studio": None, "started": _now_iso(), "ended": None,
        "max_steps": steps, "goal_met": None, "summary": "", "bugs": [], "steps": [],
        "probe": {}, "request_ids": [], "bug_hints": [], "corrections": [], "errors": [],
    }
    _save_report(settings, report)

    async with AsyncExitStack() as stack:
        if studio is None:
            from forge.studio import Studio

            studio = await stack.enter_async_context(Studio(settings))
            await studio.select(studio_name)
        elif studio_name:
            await studio.select(studio_name)
        report["studio"] = getattr(studio, "studio_id", None) or studio_name

        started_play = False
        final_obs: dict = {}
        try:
            try:
                st = await asyncio.wait_for(studio.state(), STUDIO_TIMEOUT)
                already = st.get("playing") is True
            except Exception as e:  # noqa: BLE001
                report["errors"].append(f"state: {type(e).__name__}: {e}")
                already = False
            if not already:
                await studio.play()
                started_play = True
                await asyncio.sleep(min(step_seconds, 3.0))  # let the client character spawn
            report["started_play"] = started_play

            for n in range(1, steps + 1):
                t0 = time.monotonic()
                obs = await observe(studio, n)
                final_obs = obs
                step: dict = {"n": n, "observation": obs, "action": {}, "result": "",
                              "request_id": None, "latency_ms": 0}
                try:
                    user = player_user_message(goal, n, steps, obs, _history_for(report["steps"], n))
                    action, res = await _to_thread(
                        llm.complete_json, "player", user, session_id=session_id,
                        required=["action", "reason"], max_tokens=1024,
                    )
                    step["request_id"] = res.request_id
                    step["latency_ms"] = res.latency_ms
                    if res.request_id:
                        report["request_ids"].append(res.request_id)
                    if not isinstance(action.get("args"), dict):
                        action["args"] = {}
                    step["action"] = action
                    bug = _norm_bug(action.get("bug"))
                    if bug:
                        bug["step"] = n
                        report["bug_hints"].append(bug)
                    step["result"] = await act(studio, action, obs)
                except Exception as e:  # noqa: BLE001
                    step["result"] = f"error: {type(e).__name__}: {_clip(str(e), 300)}"
                step["step_ms"] = int((time.monotonic() - t0) * 1000)
                report["steps"].append(step)
                _save_report(settings, report)
                if step["action"].get("action") == "done":
                    break
                if step["action"].get("action") != "wait" and step_seconds > 0:
                    await asyncio.sleep(step_seconds)

            try:
                report["probe"] = await asyncio.wait_for(studio.probe_report(), STUDIO_TIMEOUT)
            except Exception as e:  # noqa: BLE001
                report["probe"] = {"error": f"{type(e).__name__}: {e}"}
        except Exception as e:  # noqa: BLE001
            report["errors"].append(f"{type(e).__name__}: {_clip(str(e), 500)}")
        finally:
            if started_play:
                try:
                    await studio.stop()
                except Exception as e:  # noqa: BLE001
                    report["errors"].append(f"stop: {type(e).__name__}: {e}")

    # judge
    try:
        user = judge_user_message(goal, report["steps"], final_obs, report["probe"], report["bug_hints"])
        verdict, res = await _to_thread(
            llm.complete_json, "judge", user, session_id=session_id,
            required=["goal_met", "bugs", "summary"], max_tokens=2048,
        )
        gm = verdict.get("goal_met")
        report["goal_met"] = gm if isinstance(gm, bool) else None
        report["summary"] = str(verdict.get("summary") or "")
        report["bugs"] = [b for b in (_norm_bug(x) for x in verdict.get("bugs") or []) if b]
        report["judge_request_id"] = res.request_id
        if res.request_id:
            report["request_ids"].append(res.request_id)
    except Exception as e:  # noqa: BLE001
        report["errors"].append(f"judge: {type(e).__name__}: {_clip(str(e), 300)}")
        report["summary"] = "judge failed; bugs are the playtester's own flags"
        report["bugs"] = [{k: b[k] for k in ("title", "evidence", "severity")} for b in report["bug_hints"]]

    report["ended"] = _now_iso()
    _save_report(settings, report)
    return report


async def correct_step(settings: Settings, run_id: str, step: int, note: str, *, llm=None) -> dict:
    """Re-run the `player` call for one step with a human correction; record it in the report."""
    report = load_report(settings, run_id)
    steps = report.get("steps") or []
    target = next((s for s in steps if s.get("n") == step), None)
    if target is None:
        raise ValueError(f"run {run_id} has no step {step} (it has {len(steps)} steps)")
    if not note or not note.strip():
        raise ValueError("correction note is empty")
    if llm is None:
        llm = llm_mod.make_llm(settings, log_path=_run_dir(settings, run_id) / "calls.jsonl")
    total = int(report.get("max_steps") or len(steps))
    user = player_user_message(report.get("goal", ""), step, total, target.get("observation") or {},
                               _history_for(steps, step))
    user += "\n\n## Correction from a human tester\n" + note.strip()
    after, res = await _to_thread(
        llm.complete_json, "player", user, session_id="playtest-" + run_id,
        required=["action", "reason"], max_tokens=1024,
    )
    out = {"run_id": run_id, "step": step, "before": target.get("action") or {}, "after": after,
           "request_id": res.request_id}
    report.setdefault("corrections", []).append({**out, "note": note.strip(), "ts": _now_iso()})
    if res.request_id:
        report.setdefault("request_ids", []).append(res.request_id)
    _save_report(settings, report)
    return out
