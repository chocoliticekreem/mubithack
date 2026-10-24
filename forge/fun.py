"""Forge quality brain, part 2: the fun critic and the scene census.

    census(studio) -> dict              during play: parts, default-grey parts, materials, colours, lights,
                                        particles, sounds (server) + ScreenGuis, sounds, tweens (client)
    static_census(files) -> dict        the same signals read from source, when there was no playtest
    fun_critique(llm, spec, files, report, *, census, visual, session_id) -> dict
        Mubit task `fun_critic` (forge/prompts/fun_critic.md). Returns
        {score, scores{fun,juice,clarity,visuals}, summary, first_60_seconds[], missing_juice[], issues[]}
        score = mean of the four, computed here (not trusted from the model).
    FunStore(settings, slug): runs/<slug>/fun/<n>.json + latest.json
    pending_fun_anomalies(settings, slug, since) -> auditor-format anomalies for the improve loop
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from forge import roles
from forge.config import Settings
from forge.llm import LLM
from forge.memory import RunStore, now_iso
from forge.smoke import headline

FUN_KEYS = ["scores", "summary", "issues"]
AXES = ("fun", "juice", "clarity", "visuals")
FUN_BAR = 8.0
GREY_MAX = 0.15  # at most this share of world parts may be default grey
# Sound evidence: live Sound instances (not character sounds) and GameAssets.play counts (they outlive
# the Sounds, which Debris removes after ~6 s).
SOUND_KEYS = ("sounds", "client_sounds", "sounds_played", "client_sounds_played")

# Server DM: the world. Characters, the ForgeTest/Forge runtime and invisible parts are not "the world".
CENSUS_SERVER = r"""-- forge census (server)
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local chars = {}
for _, p in Players:GetPlayers() do if p.Character then chars[p.Character] = true end end
local function inChar(i)
	local m = i:FindFirstAncestorOfClass("Model")
	while m do if chars[m] then return true end m = m:FindFirstAncestorOfClass("Model") end
	return false
end
local GREY = { [Color3.fromRGB(163, 162, 165):ToHex()] = true, [Color3.fromRGB(99, 95, 98):ToHex()] = true,
	[Color3.fromRGB(161, 165, 162):ToHex()] = true }
local out = { parts = 0, grey = 0, materials = {}, colors = 0, lights = 0, particles = 0, sounds = 0,
	billboards = 0, beams = 0, highlights = 0, lighting_effects = 0 }
local colors = {}
for _, i in workspace:GetDescendants() do
	if i:IsA("BasePart") and not i:IsA("Terrain") and i.Transparency < 0.95 and not inChar(i) then
		out.parts += 1
		local hex = i.Color:ToHex()
		if GREY[hex] and (i.Material == Enum.Material.Plastic or i.Material == Enum.Material.SmoothPlastic) then
			out.grey += 1
		end
		colors[hex] = true
		local m = i.Material.Name
		out.materials[m] = (out.materials[m] or 0) + 1
	elseif i:IsA("Light") then out.lights += 1
	elseif i:IsA("ParticleEmitter") or i:IsA("Fire") or i:IsA("Sparkles") or i:IsA("Smoke") then out.particles += 1
	elseif i:IsA("BillboardGui") or i:IsA("SurfaceGui") then out.billboards += 1
	elseif i:IsA("Beam") or i:IsA("Trail") then out.beams += 1
	elseif i:IsA("Highlight") then out.highlights += 1 end
end
for _ in colors do out.colors += 1 end
for _, root in { workspace, game:GetService("SoundService"), game:GetService("ReplicatedStorage") } do
	for _, i in root:GetDescendants() do if i:IsA("Sound") and not inChar(i) then out.sounds += 1 end end
end
local SS = game:GetService("SoundService")
out.sounds_played = SS:GetAttribute("ForgeSoundsPlayed") or 0
out.bursts = workspace:GetAttribute("ForgeBursts") or 0
for _, i in game:GetService("Lighting"):GetChildren() do
	if i:IsA("PostEffect") or i:IsA("Atmosphere") or i:IsA("Sky") then out.lighting_effects += 1 end
end
return HttpService:JSONEncode(out)
"""

# Client DM: what the player sees and hears. GameAssets.play leaves Sounds behind for ~6 s.
CENSUS_CLIENT = r"""-- forge census (client)
local HttpService = game:GetService("HttpService")
local lp = game:GetService("Players").LocalPlayer
local out = { screen_guis = 0, gui_objects = 0, buttons = 0, text_labels = 0, strokes = 0, corners = 0,
	client_sounds = 0, client_particles = 0, names = {} }
local CORE = { BubbleChat = true, Chat = true, Freecam = true, TouchGui = true, ControlGui = true,
	PlayerList = true, RbxCameraUI = true }
local pg = lp and lp:FindFirstChild("PlayerGui")
if pg then
	for _, g in pg:GetChildren() do
		if g:IsA("ScreenGui") and g.Enabled and not CORE[g.Name] and not string.match(g.Name, "^Forge") then
			out.screen_guis += 1
			table.insert(out.names, g.Name)
			for _, i in g:GetDescendants() do
				if i:IsA("GuiObject") then out.gui_objects += 1 end
				if i:IsA("GuiButton") then out.buttons += 1 end
				if i:IsA("TextLabel") then out.text_labels += 1 end
				if i:IsA("UIStroke") then out.strokes += 1 end
				if i:IsA("UICorner") then out.corners += 1 end
			end
		end
	end
end
-- game sounds only: the default character sounds (Running, Jumping...) are not juice
local chars = {}
for _, p in game:GetService("Players"):GetPlayers() do if p.Character then table.insert(chars, p.Character) end end
local function inChar(i)
	for _, c in chars do if i:IsDescendantOf(c) then return true end end
	return false
end
for _, root in { workspace, game:GetService("SoundService"), pg } do
	for _, i in root:GetDescendants() do
		if inChar(i) then continue end
		if i:IsA("Sound") then out.client_sounds += 1 end
		if i:IsA("ParticleEmitter") then out.client_particles += 1 end
	end
end
out.client_sounds_played = game:GetService("SoundService"):GetAttribute("ForgeSoundsPlayed") or 0
return HttpService:JSONEncode(out)
"""


async def census(studio: Any) -> dict:
    """Scene census during play. Never raises: missing halves come back as {"error": ...} keys."""
    from forge.studio import extract_json

    out: dict = {"source": "playtest"}
    for dm, code in (("Server", CENSUS_SERVER), ("Client", CENSUS_CLIENT)):
        try:
            obj = extract_json(await studio.execute_luau(code, dm))
            if isinstance(obj, dict):
                out.update(obj)
            else:
                out[f"{dm.lower()}_error"] = "unparseable census"
        except Exception as e:  # noqa: BLE001
            out[f"{dm.lower()}_error"] = f"{type(e).__name__}: {str(e)[:200]}"
    return out


_SOUND = re.compile(r'Instance\.new\(\s*"Sound"\s*\)|GameAssets\.play\(|GameAssets\.music\(|:PlayLocalSound\(')
_PARTICLE = re.compile(r'Instance\.new\(\s*"(ParticleEmitter|Sparkles|Fire|Smoke|Trail|Beam)"\s*\)|GameAssets\.burst\(')
_SCREEN = re.compile(r'Instance\.new\(\s*"ScreenGui"\s*\)|Theme\.screen\(')
_TWEEN = re.compile(r"TweenService|Theme\.(pop|punch|tween)\(|GameAssets\.popIn\(")
_PART = re.compile(r'Instance\.new\(\s*"(Part|WedgePart|MeshPart|TrussPart)"\s*\)|GameAssets\.part\(')
_COLOR = re.compile(r"\.(Color|BrickColor)\s*=|Color\s*=|GameAssets\.part\(")
_SHAKE = re.compile(r"CameraOffset|GameAssets\.shake\(")


def static_census(files: dict[str, str]) -> dict:
    """Juice/visual signals read from source (no playtest). Counts are call sites, not instances.
    The prebuilt kit (GameAssets.luau) and the Forge runtime only count where the game calls them."""
    files = {p: s for p, s in files.items()
             if not p.endswith("GameAssets.luau") and not p.rsplit("/", 1)[-1].startswith("Forge")
             and not p.startswith("tools/")}

    def n(rx: re.Pattern, where: str = "") -> int:
        return sum(len(rx.findall(src)) for p, src in files.items() if where in p)
    parts, coloured = n(_PART), n(_COLOR)
    return {
        "source": "static", "sound_sites": n(_SOUND), "particle_sites": n(_PARTICLE),
        "screen_gui_sites": n(_SCREEN, "StarterPlayerScripts") + n(_SCREEN, "StarterGui"),
        "tween_sites": n(_TWEEN), "part_sites": parts, "colour_sites": coloured, "shake_sites": n(_SHAKE),
        "lighting_styled": any("styleLighting" in s or "ColorCorrectionEffect" in s or "BloomEffect" in s
                               for s in files.values()),
    }


def visual_checks(c: dict) -> dict:
    """{grey_ok, hud_ok, sounds_ok} from a census (playtest or static), each True/False/None (unknown)."""
    if c.get("source") == "playtest" and "parts" in c:
        parts, grey = int(c.get("parts") or 0), int(c.get("grey") or 0)
        grey_ok = parts > 0 and grey / parts <= GREY_MAX
    elif c.get("source") == "static":
        grey_ok = c.get("part_sites", 0) == 0 or c.get("colour_sites", 0) >= c.get("part_sites", 0)
    else:
        grey_ok = None
    if "screen_guis" in c:
        hud_ok = int(c.get("screen_guis") or 0) > 0
    elif c.get("source") == "static":
        hud_ok = c.get("screen_gui_sites", 0) > 0
    else:
        hud_ok = None
    if any(k in c for k in SOUND_KEYS):
        sounds_ok = sum(int(c.get(k) or 0) for k in SOUND_KEYS) > 0
    elif c.get("source") == "static":
        sounds_ok = c.get("sound_sites", 0) > 0
    else:
        sounds_ok = None
    return {"grey_ok": grey_ok, "hud_ok": hud_ok, "sounds_ok": sounds_ok}


# ------------------------------------------------------------------------------- the critic


def _doc_for_critic(spec: dict, limit: int = 5000) -> str:
    doc = spec.get("director") or {}
    if not doc:
        return "(no director doc: judge against genre expectations)"
    keep = {k: doc.get(k) for k in ("fantasy", "core_loop", "juice", "first_60_seconds", "visual_style", "sounds")}
    return roles._truncate(json.dumps(keep, indent=1, ensure_ascii=False), limit, label="design doc")


def fun_message(spec: dict, files: dict[str, str], report: dict, census_: dict, visual: str = "") -> str:
    counters = (report or {}).get("counters") or {}
    errors = [(e.get("message") if isinstance(e, dict) else str(e)) for e in (report or {}).get("errors") or []]
    head = (
        "## Game spec\n" + roles._compact_spec(spec, 3000) + "\n\n"
        "## Director's design doc\n" + _doc_for_critic(spec) + "\n\n"
        "## Playtest evidence\n"
        f"counters: {json.dumps(counters)[:1500]}\n"
        + (f"{headline((report or {})['smoke'])[:600]} (a scripted player, forge smoke play, before these counters "
           "were read)\n" if (report or {}).get("smoke") else "")
        + f"errors ({len(errors)}): {json.dumps(errors[:5])[:1200]}\n"
        f"scene census: {json.dumps(census_ or {}, ensure_ascii=False)[:2000]}\n\n"
        "## Visual judge notes (screenshots)\n" + (roles._truncate(visual.strip(), 2000, label="visual")
                                                  if visual and visual.strip() else "(none)") + "\n\n"
    )
    tail = "Return only the fun critique JSON object."
    budget = max(3000, roles.MAX_USER_CHARS - len(head) - len(tail) - 200)
    return roles._fit(head + roles._files_block(files, budget) + "\n" + tail)


def _num(v: Any) -> float:
    try:
        return max(0.0, min(10.0, float(v)))
    except (TypeError, ValueError):
        return 0.0


def normalize_fun(obj: dict, known_paths: set[str] | None = None) -> dict:
    raw = obj.get("scores") if isinstance(obj.get("scores"), dict) else {}
    scores = {a: _num(raw.get(a)) for a in AXES}
    score = round(sum(scores.values()) / len(AXES), 1)
    issues = []
    for it in obj.get("issues") or []:
        if isinstance(it, dict) and it.get("path") and it.get("problem"):
            if known_paths and str(it["path"]) not in known_paths:
                continue
            issues.append({"path": str(it["path"]), "problem": str(it["problem"]),
                           "fix_hint": str(it.get("fix_hint") or ""), "source": "fun_critic"})
    beats = [{"beat": str(b.get("beat") or ""), "ok": bool(b.get("ok")), "evidence": str(b.get("evidence") or "")}
             for b in obj.get("first_60_seconds") or [] if isinstance(b, dict)]
    return {"score": score, "scores": scores, "summary": str(obj.get("summary") or ""),
            "first_60_seconds": beats, "missing_juice": [str(m) for m in obj.get("missing_juice") or []][:20],
            "issues": issues[:6]}


def fun_critique(llm: LLM, spec: dict, files: dict[str, str], report: dict, *, census: dict | None = None,
                 visual: str = "", session_id: str) -> dict:
    c = census or static_census(files)
    obj, res = llm.complete_json("fun_critic", fun_message(spec, files, report, c, visual),
                                 session_id=session_id, required=FUN_KEYS, max_tokens=8000)
    out = normalize_fun(obj, set(files))
    out.update(census=c, checks=visual_checks(c), request_id=res.request_id)
    return out


# ------------------------------------------------------------------------------- storage + improve loop


class FunStore:
    def __init__(self, settings: Settings, slug: str):
        self.dir = RunStore(settings, slug).dir / "fun"

    def save(self, n: int | str, result: dict) -> Path:
        self.dir.mkdir(parents=True, exist_ok=True)
        rec = {"n": n, "ts": now_iso(), **result}
        text = json.dumps(rec, indent=1, ensure_ascii=False)
        (self.dir / f"{n}.json").write_text(text, encoding="utf-8")
        (self.dir / "latest.json").write_text(text, encoding="utf-8")
        return self.dir / f"{n}.json"

    def latest(self) -> dict | None:
        try:
            return json.loads((self.dir / "latest.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None


def pending_fun_anomalies(settings: Settings, slug: str, since: str = "") -> list[dict]:
    """The latest fun critique's issues (if newer than `since`) as anomalies the improve loop can fix."""
    latest = FunStore(settings, slug).latest()
    if not latest or (since and str(latest.get("ts", "")) <= since):
        return []
    out = []
    for it in latest.get("issues") or []:
        out.append({"kind": "fun", "system": it["path"].lower(), "severity": "medium",
                    "title": f"[{it['path']}] {it['problem']}"[:300],
                    "expected": it.get("fix_hint", ""), "observed": it["problem"], "path": it["path"]})
    return out


def critique_game(settings: Settings, slug: str, *, llm: LLM | None = None, visual: str = "") -> dict:
    """`forge fun <slug>`: fun critic on the game's current files and its latest playtest evidence."""
    from forge.llm import make_llm

    store = RunStore(settings, slug)
    if not store.exists():
        raise FileNotFoundError(f"no game {slug!r} in {settings.runs_dir}")
    spec = store.load_spec()
    files = {}
    for p in sorted(store.game_dir.rglob("*.luau")):
        rel = p.relative_to(store.game_dir).as_posix()
        if rel.startswith("tools/") or any(w in rel for w in ("ForgeProbe", "ForgeTelemetry", "ForgeTest")):
            continue
        files[rel] = p.read_text(encoding="utf-8", errors="replace")
    report: dict = {}
    n = store.last_iteration()
    if n is not None:
        report = store.load_iteration_json(n, "report.json", {}) or {}
    llm = llm or make_llm(settings, store.calls_log)
    res = fun_critique(llm, spec, files, report, census=report.get("census") or None, visual=visual,
                       session_id=slug)
    FunStore(settings, slug).save(f"manual-{n if n is not None else 0}", res)
    return res
