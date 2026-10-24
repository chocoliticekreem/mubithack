"""`forge compare <slug>`: is this game's code as good as our best human code yet, and what is missing?

    compare(game_dir, ref_dir, *, spec=None, run_dir=None, name=None, ref_name=None) -> report
        Static, cheap and deterministic: no Studio, no LLM. Both trees are read the same way (Forge's
        runtime and tools/ via gaps.game_sources, the prebuilt GameAssets kit left out so only the game's
        calls into it count, comments stripped so prose never counts as code) and scored per category
        0-10 RELATIVE to the reference (default: the human-built Flame and Blame in game/, which scores
        10 against itself): architecture, robustness, data, ui, juice, content, observability.
        Metrics are presence, shares, kind coverage and per-1k-line densities, never raw size, so a
        small genre is not punished for being small. Genre depth (content) is scored against the genre
        checklists (forge/gaps.py) and forge/lessons_library targets, because the reference is a
        different genre. Every metric keeps file:line evidence; every category lists its top 3 gaps
        ("the reference does X, this game doesn't") with a pointer to the reference file that does it
        well, so a coder can copy the pattern.
    judge(llm, report, *, session_id) -> dict
        Optional (--llm), Mubit task `code_judge` (forge/prompts/code_judge.md): the static report plus
        the weakest areas' code side by side with the reference's -> ranked improvements. One call.
    save(report, out_dir) -> Path       out_dir/<n>.json + <n>.md (runs/<slug>/compare/)
    done_summary(settings, slug)        category scores for `forge done` (informational, never blocks)

CLI: forge compare <slug|folder> [--against game|<slug>|<folder>] [--llm] [--json]
"""

from __future__ import annotations

import json
import re
from bisect import bisect_right
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from forge.config import Settings, load_settings
from forge.gaps import CHECKLISTS, detect_genre, game_sources
from forge.memory import RunStore, now_iso

ROLE = "code_judge"
CATEGORIES = (("architecture", "Architecture"), ("robustness", "Robustness"), ("data", "Data"),
              ("ui", "UI/UX"), ("juice", "Juice/audio"), ("content", "Content"),
              ("observability", "Observability/tests"))
CATEGORY_IDS = tuple(c for c, _ in CATEGORIES)
KIT_FILES = ("GameAssets.luau",)
CLIENT_ROOTS = ("StarterPlayerScripts/", "StarterGui/", "StarterCharacterScripts/", "StarterPlayer/",
                "ReplicatedFirst/")
GOD_LINES = 1000
THIN_SCRIPT = 100  # code lines a Script may hold before its logic counts as "not in modules"
GAPS_PER_CATEGORY = 3
MAX_USER_CHARS = 24_000
REPO_ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Hit:
    file: str
    line: int
    text: str

    def as_dict(self) -> dict:
        return {"file": self.file, "line": self.line, "text": self.text}


# ------------------------------------------------------------------------------- reading a tree

_TOKEN = re.compile(r"--|\[=*\[|[\"'`]")
_LONG = re.compile(r"\[(=*)\[")
_STRING = {q: re.compile(q + r"(?:\\.|[^" + q + r"\\\n])*" + q + "?") for q in "\"'`"}


def strip_comments(text: str) -> str:
    """Luau source with every comment removed and line numbers kept. Strings stay: they hold the
    instance class names and counter names the metrics look for."""
    out: list[str] = []
    i, n = 0, len(text)
    while True:
        m = _TOKEN.search(text, i)
        if m is None:
            out.append(text[i:])
            return "".join(out)
        start, tok = m.start(), m.group(0)
        out.append(text[i:start])
        if tok == "--":
            long = _LONG.match(text, start + 2)
            if long:
                end = text.find("]" + long.group(1) + "]", long.end())
                end = n if end < 0 else end + len(long.group(1)) + 2
                out.append("\n" * text.count("\n", start, end))
            else:
                end = text.find("\n", start)
                end = n if end < 0 else end
        elif tok[0] == "[":
            close = "]" + tok[1:-1] + "]"
            end = text.find(close, m.end())
            end = n if end < 0 else end + len(close)
            out.append(text[start:end])
        else:
            end = _STRING[tok].match(text, start).end()
            out.append(text[start:end])
        i = end


def _side(path: str) -> str:
    if path.startswith("tests/") or path.endswith(".spec.luau"):
        return "test"
    if path.endswith(".client.luau") or path.startswith(CLIENT_ROOTS):
        return "client"
    if path.endswith(".server.luau") or not path.startswith("ReplicatedStorage/"):
        return "server"
    return "shared"


@dataclass(eq=False)
class File:
    path: str
    raw: list[str]
    lines: list[str]  # comment-stripped, same numbering as raw
    code: str
    starts: list[int]
    sloc: int
    side: str  # server | client | shared | test
    script: bool  # X.server.luau / X.client.luau (Script, LocalScript), else a ModuleScript

    @classmethod
    def make(cls, path: str, text: str) -> File:
        code = strip_comments(text)
        starts = [0] + [m.end() for m in re.finditer("\n", code)]
        lines = code.split("\n")
        return cls(path, text.split("\n"), lines, code, starts, sum(1 for ln in lines if ln.strip()),
                   _side(path), path.endswith((".server.luau", ".client.luau")))

    @property
    def name(self) -> str:
        return self.path.rsplit("/", 1)[-1].split(".", 1)[0]

    def hit(self, line: int, text: str | None = None) -> Hit:
        if text is None:
            text = self.raw[line - 1].strip() if 0 < line <= len(self.raw) else ""
        return Hit(self.path, line, text[:140])

    def summary(self, what: str = "") -> Hit:
        return self.hit(1, f"{self.sloc} code lines" + (f", {what}" if what else ""))

    def find(self, pattern: re.Pattern) -> list[Hit]:
        return [self.hit(bisect_right(self.starts, m.start())) for m in pattern.finditer(self.code)]

    def window(self, line: int, before: int = 0, after: int = 12) -> str:
        return "\n".join(self.lines[max(0, line - 1 - before): line + after])


class Corpus:
    """One game tree, read for comparison."""

    def __init__(self, sources: dict[str, str], *, genre: str = "generic", run_dir: Path | None = None):
        self.files = [File.make(p, s) for p, s in sorted(sources.items())
                      if p.rsplit("/", 1)[-1] not in KIT_FILES]
        self.code = [f for f in self.files if f.side != "test"]
        self.tests = [f for f in self.files if f.side == "test"]
        self.sloc = sum(f.sloc for f in self.code)
        self.genre, self.run_dir = genre, run_dir
        self._by_path = {f.path: f for f in self.files}

    @classmethod
    def load(cls, game_dir: Path, **kw: Any) -> Corpus:
        return cls(game_sources(Path(game_dir)), **kw)

    def side(self, *sides: str) -> list[File]:
        return [f for f in self.code if f.side in sides]

    def find(self, pattern: re.Pattern, files: list[File] | None = None) -> list[Hit]:
        return [h for f in (self.code if files is None else files) for h in f.find(pattern)]

    def having(self, pattern: re.Pattern, files: list[File] | None = None) -> list[File]:
        return [f for f in (self.code if files is None else files) if pattern.search(f.code)]

    def file(self, path: str) -> File | None:
        return self._by_path.get(path)


def _kloc(files: list[File]) -> float:
    return sum(f.sloc for f in files) / 1000


def _largest(files: list[File], n: int = 3) -> list[File]:
    return sorted(files, key=lambda f: -f.sloc)[:n]


# ------------------------------------------------------------------------------- patterns


def rx(pattern: str) -> re.Pattern:
    return re.compile(pattern)


REQUIRE = rx(r"\brequire\b")
LIFECYCLE = rx(r"function\s+[\w.]+[:.](?:Init|Start)\s*\(|[.:](?:Init|Start)\s*=\s*function")
CHILD_LOOP = rx(r":Get(?:Children|Descendants)\(\)")
CONFIG_NAME = rx(r"(?i)config|settings|constants|tuning|balance")
REMOTE_NEW = rx(r'Instance\.new\(\s*"(?:RemoteEvent|RemoteFunction|UnreliableRemoteEvent)"')
REMOTE_HELPER = rx(r"function\s+\w+\.(?:event|func|remote\w*)\s*\(")
HANDLER = rx(r"OnServerEvent:Connect\s*\(|OnServerInvoke\s*=|\bNet\.onServer\s*\(")
VALIDATE = rx(r"\btypeof\s*\(|\btype\s*\(\s*\w+\s*\)\s*[~=]=|\btonumber\s*\(|\bNet\.(?:unit|tagged|near)\s*\("
              r"|:IsA\s*\(|math\.clamp\s*\(|\bassert\s*\(|[Vv]alid")
RATE = rx(r"\bNet\.onServer\s*\(|os\.clock\s*\(|\btick\s*\(\s*\)|os\.time\s*\(|[Cc]ooldown|[Dd]ebounce|[Tt]hrottle"
          r"|\b[Rr]ate\b|\b[Ll]ast\w*\s*\[")
RATE_HELPER = rx(r"function\s+\w+\.onServer\s*\(")
DEPRECATED = rx(r"(?<![\w.:])(?:wait|spawn|delay)\s*\(|(?<![\w.:])_G\b|(?<![\w.:])shared\s*[.\[]")
TASK_LIB = rx(r"\btask\.(?:wait|spawn|delay|defer)\s*\(")
ASYNC = rx(r":\w+Async\s*\(|:GetDataStore\s*\(|:GetOrderedDataStore\s*\(|:AwardBadge\s*\(")
PCALL = rx(r"\bx?pcall\s*\(")
PLAYER_ADDED = rx(r"PlayerAdded:Connect\s*\(")
GET_PLAYERS = rx(r":GetPlayers\s*\(\s*\)")
PLAYER_KEYED = rx(r"\[\s*(?:player|plr|p|pl|who|owner|target)\s*\]\s*=(?!=)")
REMOVING = rx(r"PlayerRemoving|\.Destroying:Connect|AncestryChanged")
CLEANUP_FN = rx(r"(?i)function\s+(?:\w+[.:])?(\w*(?:stop|clean|remov|releas|destroy|teardown|unload|forget|drop"
                r"|reset|leav|unclaim|despawn|dispose)\w*)\s*\(")
ECON = r"(?i:cash|coins?|money|gold|gems?|points|score|stage|level|xp|wins|rebirths?|stars)"
CLIENT_WRITE = rx(rf"{ECON}\w*\.Value\s*[-+*/]?=(?!=)|:SetAttribute\(\s*\"\w*{ECON}\w*\""
                  r"|leaderstats[^\n]*\.Value\s*[-+*/]?=(?!=)"
                  r"|:FireServer\([^)\n]*(?i:cash|coin|money|reward|points|stage|xp|amount)")
TOUCHED = rx(r"\.Touched:Connect\s*\(")
DEBOUNCE = rx(r"[Bb]usy|[Dd]ebounce|[Cc]ooldown|os\.clock\s*\(|\btick\s*\(\s*\)|os\.time\s*\(|[Ll]ast\w*\s*\["
              r"|[Tt]ouch\w*\s*\[|[Cc]ollected|[Cc]laimed|\b(?:done|fired|used|stopped|handled|locked)\b"
              r"|\w+\[\s*\w+\s*\]\s+then")

PERSIST = rx(r"DataStoreService|:GetDataStore\s*\(|:GetOrderedDataStore\s*\(|ProfileStore|ProfileService")
DATA_NAME = rx(r"(?i)data|profile|schema|save")
STUDIO_FALLBACK = rx(r"IsStudio\s*\(\s*\)|[Mm]emory\w*|[Ff]allback")
SCHEMA = rx(r"\b[Vv]ersion\s*=|[Ss]chema[Vv]ersion|[Mm]igrat\w*|\bversion\s*:")
SAFE_WRITE = rx(r":UpdateAsync\s*\(|[Tt]ryLock|[Ss]ession\w*[Ll]ock|ProfileStore|ProfileService")
BIND_CLOSE = rx(r"BindToClose")
PLAYER_REMOVING = rx(r"PlayerRemoving")
RETRY = rx(r"GetRequestBudgetForRequestType|[Rr]etr(?:y|ies)|[Aa]ttempts?\b|[Bb]ackoff")

GUI_NEW = rx(r'Instance\.new\(\s*"(?:ScreenGui|Frame|TextLabel|TextButton|ImageLabel|ImageButton|ScrollingFrame'
             r'|TextBox|CanvasGroup|BillboardGui|SurfaceGui|ViewportFrame)"'
             r"|\b(?:UiKit|Theme)\.(?:screen|panel|label|button|badge)\s*\(")
SCREEN = rx(r'Instance\.new\(\s*"ScreenGui"\s*\)|\b(?:UiKit|Theme)\.screen\s*\(')
UI_HELPER_DEF = rx(r"function\s+\w+\.(?:screen|panel|label|button|pop|punch|corner|stroke|tween|toast)\s*\(")
UI_STYLE = {
    "stroke": rx(r'"UIStroke"|\b(?:UiKit|Theme)\.stroke\s*\('),
    "corner": rx(r'"UICorner"|\b(?:UiKit|Theme)\.corner\s*\('),
    "gradient": rx(r'"UIGradient"|\b(?:UiKit|Theme)\.gradient\s*\('),
    "scale": rx(r'"UIScale"'),
    "padding": rx(r'"UIPadding"'),
    "layout": rx(r'"UI(?:List|Grid|Table|Page)Layout"'),
    "constraint": rx(r'"UI(?:AspectRatio|Size|TextSize)Constraint"'),
}
TWEEN = rx(r"TweenService:Create\s*\(|:Tween(?:Size|Position|SizeAndPosition)\s*\(|\b(?:UiKit|Theme)\.(?:tween|pop"
           r"|punch|shake)\s*\(|GameAssets\.popIn\s*\(|\btween\w*\s*\(")
FEEDBACK = rx(r"(?:[Tt]oast|[Nn]otify|[Pp]opup|[Ff]loatingText|[Aa]nnounce|[Aa]lert|[Bb]anner|[Ss]howMessage)\w*\s*"
              r"(?:\(|:\w|\.\w+\s*\()")
MOBILE = {
    "viewport_scale": rx(r'"UIScale"|"UIAspectRatioConstraint"|"UISizeConstraint"|ViewportSize'),
    "text_fit": rx(r'TextScaled\s*=\s*true|"UITextSizeConstraint"'),
    "safe_area": rx(r"ScreenInsets|IgnoreGuiInset|GetGuiInset|SafeArea"),
    "touch_input": rx(r"TouchEnabled|ContextActionService|TouchTap|TouchStarted|TouchEnded|PreferredInput"),
}
UDIM_SCALE = rx(r"UDim2\.fromScale\s*\(")
UDIM_OFFSET = rx(r"UDim2\.fromOffset\s*\(")
UDIM_NEW = rx(r"UDim2\.new\s*\(\s*([^,()]+),\s*([^,()]+),\s*([^,()]+),\s*([^,()]+)\)")

SOUND = rx(r'Instance\.new\(\s*"Sound"\s*\)|\bSoundId\s*=|:PlayLocalSound\s*\(|GameAssets\.(?:play|music)\s*\('
           r"|[Ss](?:ound|fx)\w*\s*\(")
PARTICLE = rx(r'"(?:ParticleEmitter|Sparkles|Smoke|Trail|Beam)"|Instance\.new\(\s*"Fire"\s*\)|:Emit\s*\('
              r"|GameAssets\.burst\s*\(")
SHAKE = rx(r"CameraOffset|GameAssets\.shake\s*\(|[Ss]hake\w*\s*\(")
MUSIC = rx(r"[Mm]usic")
LIGHTING = rx(r'"(?:Bloom|ColorCorrection|SunRays|DepthOfField|Blur)Effect"|"Atmosphere"|"Sky"'
              r"|GameAssets\.styleLighting\s*\(|\bLighting\.(?:ClockTime|Brightness|Ambient|OutdoorAmbient"
              r"|ExposureCompensation|EnvironmentDiffuseScale|EnvironmentSpecularScale|FogEnd|FogColor"
              r"|GlobalShadows)\s*=")
LIGHT_FX = rx(r'"(?:Point|Spot|Surface)Light"|"Highlight"|"SelectionBox"')
JUICE = {"sound": SOUND, "particles": PARTICLE, "tween": TWEEN, "camera_shake": SHAKE, "music": MUSIC,
         "lighting": LIGHTING, "light_fx": LIGHT_FX}

INTERACTIONS = {
    "touch": rx(r"\.Touched:Connect"),
    "prompt": rx(r'"ProximityPrompt"|\.Triggered:Connect|PromptTriggered'),
    "click": rx(r'"ClickDetector"|MouseClick'),
    "tool": rx(r'Instance\.new\(\s*"Tool"\s*\)|\bBackpack\b|\.Equipped:Connect'),
    "gui_button": rx(r"MouseButton1Click|\.Activated:Connect"),
    "vehicle": rx(r'VehicleSeat|"Seat"|:Sit\s*\('),
    "input": rx(r"UserInputService|ContextActionService|InputBegan"),
    "physics": rx(r":ApplyImpulse\s*\(|LinearVelocity|BodyVelocity|AssemblyLinearVelocity\s*=|VectorForce"
                  r"|AlignPosition"),
    "npc": rx(r"PathfindingService|:MoveTo\s*\("),
    "damage": rx(r":TakeDamage\s*\(|\.Health\s*[-+]?=(?!=)"),
    "rounds": rx(r"[Ii]ntermission|[Cc]ountdown|[Rr]ound\w*\s*="),
    "teams": rx(r'\bTeams\b|"Team"|TeamColor'),
}
PROGRESSION = {
    "currency": rx(r"(?i:leaderstats|cash|coins?|money|gems?|gold)\b|[Pp]oints"),
    "xp_levels": rx(r"\b[Xx][Pp]\b|\bxp\w*|[Ll]evel[Uu]p|levelFor|\b[Ll]evel\s*[=+]"),
    "unlocks": rx(r"[Uu]nlock"),
    "upgrades": rx(r"[Uu]pgrade"),
    "rebirth": rx(r"[Rr]ebirth|[Pp]restige"),
    "missions": rx(r"[Mm]ission|[Qq]uest|[Oo]bjective|[Cc]hallenge"),
    "inventory": rx(r"[Ii]nventory|[Ll]oadout|[Ee]quip"),
    "awards": rx(r"[Aa]ward|[Bb]adge|[Aa]chievement"),
    "cosmetics_shop": rx(r"[Cc]osmetic|\b[Ss]kin\b|\b[Ss]hop|\b[Ss]tore\b"),
    "leaderboard": rx(r"[Ll]eaderboard|OrderedDataStore|leaderstats"),
    "daily": rx(r"[Dd]aily|[Ww]eekly|[Ss]treak"),
    "monetization": rx(r"MarketplaceService|GamePass|ProcessReceipt|DeveloperProduct"),
}
PRICED = rx(r"\b(?:price|cost|Price|Cost)\s*=\s*\d|\b[A-Z_]*(?:COST|PRICE)\w*\s*=\s*\d")
STAGE_COUNT = rx(r"(?i)\b(?:(?:num|total|max)_?(?:stage|checkpoint)s?|(?:stage|checkpoint)(?:s|_?count|_?total))"
                 r"\s*=\s*(\d+)\b")
STAGES_TABLE = rx(r"(?i)\b(?:stages|checkpoints|levels)\s*=\s*\{")
ZONES_TABLE = rx(r"(?i)\b(?:zones|worlds|biomes|areas|sections|realms)\s*=\s*\{")
ZONE_WORD = rx(r"(?i)\bzone\b|\bworld\s*\d|\bbiome\b|\brealm\b")
OBSTACLES = {
    "kill_brick": rx(r"(?i)kill\w*|\blava\b|TakeDamage|Health\s*=\s*0|BreakJoints"),
    "moving": rx(r"(?i)\bmoving\b|PrismaticConstraint|AlignPosition|moveplatform"),
    "spinner": rx(r"(?i)\bspin\w*|rotat\w*|HingeConstraint|AngularVelocity"),
    "disappearing": rx(r"(?i)disappear\w*|\bfad(?:e|ing)\w*|vanish\w*"),
    "jump_pad": rx(r"(?i)jump\s*_?pad|trampoline|bounce\w*|launch\w*"),
    "conveyor": rx(r"(?i)conveyor"),
    "swing": rx(r"(?i)\bswing\w*|pendulum"),
    "laser": rx(r"(?i)laser"),
    "climb": rx(r"TrussPart|(?i:ladder|climb\w*)"),
    "slippery": rx(r"(?i)\bice\b|slipp\w*|CustomPhysicalProperties"),
    "wind": rx(r"(?i)\bwind\b|\bfan\b|VectorForce"),
    "falling": rx(r"(?i)\bfalling\b|crumbl\w*|collaps\w*"),
    "rising_hazard": rx(r"(?i)\brising\b|\bflood\w*"),
}
OBBY_CHECKLIST = [
    {"id": "checkpoints", "label": "checkpoints that save the stage (respawn at the latest)",
     "signals": [[r"[Cc]heckpoint", r"[Ss]tage"]]},
    {"id": "stage_counter", "label": "stage counter (leaderstat Stage / HUD)", "signals": [[r"leaderstats", r"[Ss]tage"]]},
    {"id": "kill_bricks", "label": "kill bricks / hazards that reset the player",
     "signals": [[r"[Kk]ill|[Ll]ava|TakeDamage|Health\s*=\s*0|BreakJoints"]]},
    {"id": "moving_obstacles", "label": "moving or spinning obstacles",
     "signals": [[r"[Mm]oving|[Ss]pin|[Rr]otat|HingeConstraint|PrismaticConstraint|AlignPosition|AngularVelocity"]]},
    {"id": "obstacle_variety", "label": "several obstacle types (jump pads, disappearing tiles, conveyors...)",
     "signals": [[r"[Jj]ump\s*_?[Pp]ad|[Tt]rampoline|[Dd]isappear|[Ff]ad(?:e|ing)|[Cc]onveyor|[Ss]wing|[Ll]aser"]]},
    {"id": "difficulty_curve", "label": "difficulty curve (stages get harder)",
     "signals": [[r"[Dd]ifficult|[Hh]arder|[Tt]ier"]]},
    {"id": "coins", "label": "coins / collectibles along the path", "signals": [[r"[Cc]oin|[Cc]ollectible|[Gg]em\b"]]},
    {"id": "timer", "label": "timer / speedrun / best time", "signals": [[r"[Tt]imer|[Bb]est\s*_?[Tt]ime|[Ss]peedrun"]]},
    {"id": "skip_or_reset", "label": "skip stage / reset button", "signals": [[r"[Ss]kip|[Rr]eset"]]},
    {"id": "saving", "label": "saving the reached stage (DataStore)", "signals": [[r"DataStoreService|GetDataStore"]]},
    {"id": "finish", "label": "finish line with a reward popup", "signals": [[r"[Ff]inish|[Vv]ictory|[Cc]omplete"]]},
    {"id": "juice_sound", "label": "juice: sounds (checkpoint ding, death, finish)",
     "signals": [[r"Instance\.new\(\s*\"Sound\"|SoundId|GameAssets\.play"]]},
    {"id": "juice_particles", "label": "juice: particles (checkpoint sparkles, jump pad puffs)",
     "signals": [[r"ParticleEmitter|Sparkles|GameAssets\.burst"]]},
    {"id": "tutorial", "label": "first 10 seconds: an easy first stage and a hint",
     "signals": [[r"[Tt]utorial|[Hh]int|[Gg]uide|[Aa]rrow"]]},
]
CHECKLIST_ITEMS = {"tycoon": CHECKLISTS["tycoon"], "obby": OBBY_CHECKLIST, "generic": CHECKLISTS["generic"]}
# Genre mechanics the reference (another genre) can't show: point at the Forge UI kit snippet or the genre
# lessons instead. Generic concerns (saving, sounds, tutorial...) point at the reference.
KIT_POINTERS = {
    "rebirth": "forge/ui_library/RebirthPanel.luau", "shop_ui": "forge/ui_library/ShopGrid.luau",
    "upgrade_tree": "forge/ui_library/ShopGrid.luau", "leaderboard": "forge/ui_library/Leaderboard.luau",
    "number_popups": "forge/ui_library/FloatingText.luau", "finish": "forge/ui_library/RewardPopup.luau",
    "stage_counter": "forge/ui_library/ProgressBar.luau",
}
GENRE_SPECIFIC = {"plot_claiming", "droppers_tiers", "conveyor_collector", "upgrade_tree", "rebirth", "number_popups",
                  "checkpoints", "stage_counter", "kill_bricks", "moving_obstacles", "obstacle_variety",
                  "difficulty_curve", "coins", "timer", "skip_or_reset", "finish", *OBSTACLES}
LESSONS = {"tycoon": "forge/lessons_library/tycoon.md", "obby": "forge/lessons_library/obby.md",
           "generic": "forge/lessons_library/fun.md"}
# Pointer choice: among reference files doing a kind, prefer the one whose name says it owns the concern.
UI_OWNER = rx(r"UiKit|Theme|Hud")
PREFER = {"sound": rx(r"Audio|Sound"), "music": rx(r"Audio|Music"), "particles": rx(r"Fx|Particle|Effect"),
          "camera_shake": rx(r"FirstPerson|Camera|Shake"), "lighting": rx(r"Atmosphere|Lighting|PostFx"),
          "light_fx": rx(r"Fx|Light|Alarm"), "tween": rx(r"UiKit|Tween|Popup"), "saving": rx(r"Data"),
          "tutorial": rx(r"Onboard|Guide|Tutorial"), "leaderboard": rx(r"Leaderboard"), "shop_ui": rx(r"Store|Shop"),
          "juice_sound": rx(r"Audio|Sound"), "juice_particles": rx(r"Fx|Particle|Effect"),
          "juice_tweens": rx(r"UiKit|Tween|Popup"),
          **{k: UI_OWNER for k in ("stroke", "corner", "gradient", "scale", "padding", "layout", "constraint",
                                   "viewport_scale", "text_fit", "safe_area")}}
TELEMETRY = rx(r"[Tt]elemetry\.count\s*\(\s*\"([\w.:-]+)\"")
SELFTEST = rx(r"\b_selftest\b")
SITES = {"data": rx(r"leaderstats|PlayerAdded"), "robustness": PLAYER_ADDED, "ui": SCREEN,
         "juice": rx(r"\.Touched:Connect|\.Triggered:Connect|[Tt]elemetry\.count"),
         "content": rx(r"[Tt]elemetry\.count"), "observability": rx(r"[Tt]elemetry\.count|PlayerAdded")}


# ------------------------------------------------------------------------------- metrics


@dataclass
class Val:
    value: float | None  # None: not applicable to this tree (e.g. no remotes to validate)
    good: list[Hit] = field(default_factory=list)  # evidence that it does it
    bad: list[Hit] = field(default_factory=list)  # evidence that it doesn't (violations, misses)
    note: str = ""
    kinds: dict[str, list[Hit]] | None = None  # coverage / checklist metrics: kind -> hits


@dataclass(frozen=True)
class Metric:
    id: str
    category: str
    label: str
    does: str  # what the reference (or the genre bar) does, for gap lines
    kind: str  # presence | ratio | density | coverage | lower | target
    fn: Callable[[Corpus], Val]
    weight: float = 1.0
    smooth: float = 0.5  # lower: score = (ref + smooth) / (game + smooth)
    target: float = 1.0  # target: score = game / target (the genre bar, not the reference)
    genres: tuple[str, ...] = ()  # content metrics: only for these genres
    pointer: str = "dense"  # reference pointer: file with the most hits ("dense") or the first hit
    exemplar: Callable[[Corpus], list[Hit]] | None = None  # reference sites to point at (default: good)
    prefer: re.Pattern | None = None  # prefer reference files whose name matches (the concern's owner)
    kit: str | None = None  # repo file to copy from instead of the reference (genre targets)


def _kinds(c: Corpus, table: dict[str, re.Pattern], files: list[File] | None = None) -> Val:
    kinds = {k: c.find(p, files) for k, p in table.items()}
    present = [k for k, hits in kinds.items() if hits]
    return Val(float(len(present)), good=[kinds[k][0] for k in present][:4], kinds=kinds,
               note=", ".join(present) or "none")


def _density(c: Corpus, pattern: re.Pattern, files: list[File] | None = None, what: str = "sites") -> Val:
    files = c.code if files is None else files
    kloc = _kloc(files)
    if kloc <= 0:
        return Val(None, note="no code")
    hits = c.find(pattern, files)
    return Val(len(hits) / kloc, good=hits, note=f"{len(hits)} {what} in {kloc * 1000:,.0f} lines")


def _presence(hits: list[Hit], what: str) -> Val:
    return Val(1.0 if hits else 0.0, good=hits, note=what if hits else "none found")


def _boot_hits(c: Corpus, side: str) -> list[Hit]:
    """A bootstrap: an entry Script that loops over a folder's children and requires each one."""
    out = []
    for f in c.side(side):
        if f.script:
            out += [h for h in f.find(CHILD_LOOP) if REQUIRE.search(f.window(h.line, after=12))]
    return out


def m_split(side: str) -> Callable[[Corpus], Val]:
    """Share of the side's code that is not stuck in Scripts. The first THIN_SCRIPT lines of each Script
    are free (a bootstrap, or a small game's whole HUD), so being small is never the problem."""
    def fn(c: Corpus) -> Val:
        files = c.side(side)
        total = sum(f.sloc for f in files)
        if not total:
            return Val(None, note=f"no {side} code")
        mods, scripts = [f for f in files if not f.script], [f for f in files if f.script]
        fat = [f for f in scripts if f.sloc > THIN_SCRIPT]
        v = 1 - sum(f.sloc - THIN_SCRIPT for f in fat) / total
        return Val(v, good=[f.summary("ModuleScript") for f in _largest(mods)],
                   bad=[f.summary(f"logic in a Script (over {THIN_SCRIPT} lines)") for f in _largest(fat)],
                   note=f"{len(mods)} modules, {len(scripts)} scripts ({len(fat)} over {THIN_SCRIPT} lines)")
    return fn


def m_lifecycle(c: Corpus) -> Val:
    life = c.find(LIFECYCLE)
    boot = _boot_hits(c, "server") + _boot_hits(c, "client")
    v = (0.5 if life else 0.0) + (0.5 if boot else 0.0)
    return Val(v, good=boot[:2] + life[:2],
               note=f"{len(life)} Init/Start functions, {'a' if boot else 'no'} bootstrap that requires each module")


def m_config(c: Corpus) -> Val:
    configs = [f for f in c.code if not f.script and CONFIG_NAME.search(f.name)]
    users = [f for f in c.code if f not in configs and f.sloc >= 20]
    if not users:
        return Val(None, note="no code")
    if not configs:
        return Val(0.0, bad=[f.summary("no config module to read") for f in _largest(users)], note="no config module")
    names = "|".join(re.escape(f.name) for f in configs)
    reads = re.compile(r"require\s*\([^\n]*\b(?:" + names + r")\b")
    reading = [f for f in users if reads.search(f.code)]
    return Val(len(reading) / len(users), good=[f.summary("config module") for f in configs[:2]]
               + [h for f in reading[:2] for h in f.find(reads)[:1]],
               bad=[f.summary("reads no config module") for f in _largest([f for f in users if f not in reading])],
               note=f"{len(configs)} config modules, read by {len(reading)}/{len(users)} files")


def m_module_size(c: Corpus) -> Val:
    if not c.code:
        return Val(None, note="no code")
    return Val(c.sloc / len(c.code), bad=[f.summary() for f in _largest(c.code)],
               note=f"{c.sloc:,} lines in {len(c.code)} files")


def m_god_files(c: Corpus) -> Val:
    if not c.sloc:
        return Val(None, note="no code")
    gods = [f for f in c.code if f.sloc > GOD_LINES]
    return Val(sum(f.sloc for f in gods) / c.sloc, bad=[f.summary(f"over {GOD_LINES}") for f in _largest(gods)],
               note=f"{len(gods)} files over {GOD_LINES} lines")


def m_remotes_central(c: Corpus) -> Val:
    hits = c.find(REMOTE_NEW)
    files = sorted({h.file for h in hits})
    if not files:
        return Val(None, note="creates no remotes")
    return Val(1 / len(files), good=hits[:2], bad=hits if len(files) > 1 else [],
               note=f"{len(hits)} remote creations in {len(files)} files")


_PARAMS = re.compile(r"function\s*\w*\s*\(([^)]*)\)")
_NAMED = re.compile(r"(?:Connect\s*\(|,)\s*([A-Za-z_]\w*)\s*\)\s*$|OnServerInvoke\s*=\s*([A-Za-z_]\w*)\s*$")
_CALLEE = re.compile(r"\b([A-Za-z_]\w*)\s*[(,]")
_NOT_CALLEES = {"function", "if", "then", "not", "and", "or", "return", "local", "pcall", "xpcall", "print", "warn",
                "typeof", "type", "tostring", "tonumber", "require", "ipairs", "pairs", "select", "error", "assert",
                "Connect", "insert", "FindFirstChild", "WaitForChild", "IsA", "GetAttribute", "SetAttribute"}


def _function_at(f: File, name: str) -> int | None:
    m = re.search(rf"(?:local\s+)?function\s+(?:\w+[.:])?{re.escape(name)}\s*\(|\b{re.escape(name)}\s*=\s*function\s*\(",
                  f.code)
    return bisect_right(f.starts, m.start()) if m else None


def _body(f: File, start: int, after: int = 20) -> str:
    """Code from `start` on, plus the bodies of the file's own functions it calls (one level), so a guard
    that lives in a helper (tryBuy's busy flag, onSpray's typeof) still counts."""
    body = f.window(start, after=after)
    followed = 0
    for callee in dict.fromkeys(_CALLEE.findall(f.window(start, after=min(after, 12)))):
        if callee in _NOT_CALLEES or followed >= 4:
            continue
        at = _function_at(f, callee)
        if at is not None and at != start:
            body += "\n" + f.window(at, after=after)
            followed += 1
    return body


def _handlers(c: Corpus) -> list[tuple[Hit, bool, bool]]:
    """Client -> server remote handlers: (site, validated, rate_limited). A handler that takes no client
    arguments needs no validation; a pure forwarder `function(player, ...)` (the Net helper) is skipped."""
    out = []
    for f in c.code:
        if RATE_HELPER.search(f.code) and REMOTE_HELPER.search(f.code):
            continue  # the remote helper module itself (Net.onServer forwards to the real handlers)
        for h in f.find(HANDLER):
            line = f.lines[h.line - 1]
            start = h.line
            m = _PARAMS.search(line)
            if m is None:
                named = _NAMED.search(line.strip())
                at = _function_at(f, next(g for g in named.groups() if g)) if named else None
                if at is None:
                    continue
                start, m = at, _PARAMS.search(f.lines[at - 1])
                if m is None:
                    continue
            params = [p.split(":")[0].strip() for p in m.group(1).split(",") if p.strip()]
            if params[1:] == ["..."]:
                continue
            body = _body(f, start)
            out.append((h, len(params) <= 1 or bool(VALIDATE.search(body)),
                        bool(RATE.search(line)) or bool(RATE.search(body))))
    return out


def m_remote_validation(c: Corpus) -> Val:
    hs = _handlers(c)
    if not hs:
        return Val(None, note="no client-to-server remotes")
    ok = [h for h, v, _ in hs if v]
    return Val(len(ok) / len(hs), good=ok, bad=[h for h, v, _ in hs if not v],
               note=f"{len(ok)}/{len(hs)} handlers check their arguments")


def m_remote_rate(c: Corpus) -> Val:
    hs = _handlers(c)
    if not hs:
        return Val(None, note="no client-to-server remotes")
    ok = [h for h, _, lim in hs if lim]
    return Val(len(ok) / len(hs), good=ok, bad=[h for h, _, lim in hs if not lim],
               note=f"{len(ok)}/{len(hs)} handlers rate-limited")


def m_modern_api(c: Corpus) -> Val:
    v = _density(c, DEPRECATED, what="wait/spawn/delay/_G/shared uses")
    v.bad, v.good = v.good, c.find(TASK_LIB)[:2]
    return v


def m_pcall_io(c: Corpus) -> Val:
    wrapped, bare = [], []
    for f in c.code:
        for h in f.find(ASYNC):
            (wrapped if PCALL.search(f.window(h.line, before=4, after=0)) else bare).append(h)
    if not wrapped and not bare:
        return Val(None, note="no DataStore/HTTP/Async calls")
    return Val(len(wrapped) / (len(wrapped) + len(bare)), good=wrapped, bad=bare,
               note=f"{len(wrapped)}/{len(wrapped) + len(bare)} Async calls in pcall")


def m_existing_players(c: Corpus) -> Val:
    files = c.having(PLAYER_ADDED)
    if not files:
        return Val(None, note="no PlayerAdded handlers")
    ok = c.having(GET_PLAYERS, files)
    return Val(len(ok) / len(files), good=c.find(GET_PLAYERS, ok)[:3],
               bad=[f.find(PLAYER_ADDED)[0] for f in files if f not in ok],
               note=f"{len(ok)}/{len(files)} PlayerAdded files also loop Players:GetPlayers()")


def m_player_cleanup(c: Corpus) -> Val:
    stateful = [f for f in c.code if PLAYER_ADDED.search(f.code) or PLAYER_KEYED.search(f.code)]
    if not stateful:
        return Val(None, note="no per-player state")
    leaving = "\n".join(f.code for f in c.having(REMOVING))

    def cleaned(f: File) -> bool:
        if REMOVING.search(f.code):
            return True
        names = {m.group(1) for m in CLEANUP_FN.finditer(f.code)}
        return any(re.search(rf"[.:]{re.escape(n)}\s*\(", leaving) for n in names)

    ok = [f for f in stateful if cleaned(f)]
    bad = [(f.find(PLAYER_KEYED) or f.find(PLAYER_ADDED))[0] for f in stateful if f not in ok]
    return Val(len(ok) / len(stateful), good=c.find(REMOVING, ok)[:3], bad=bad,
               note=f"{len(ok)}/{len(stateful)} files with per-player state clean up on leave")


def m_server_authority(c: Corpus) -> Val:
    client = c.side("client")
    if not client:
        return Val(0.0, note="no client code")
    hits = c.find(CLIENT_WRITE, client)
    return Val(len(hits) / max(_kloc(client), 0.001), bad=hits,
               note=f"{len(hits)} client-side writes to currency/progress")


def m_touch_debounce(c: Corpus) -> Val:
    ok, bad = [], []
    for f in c.code:
        for h in f.find(TOUCHED):
            (ok if DEBOUNCE.search(_body(f, h.line, after=12)) else bad).append(h)
    if not ok and not bad:
        return Val(None, note="no Touched handlers")
    return Val(len(ok) / (len(ok) + len(bad)), good=ok, bad=bad, note=f"{len(ok)}/{len(ok) + len(bad)} debounced")


def _data_files(c: Corpus) -> list[File]:
    return c.having(PERSIST)


def _data_ish(c: Corpus) -> list[File]:
    data = _data_files(c)
    return data + [f for f in c.code if f not in data and DATA_NAME.search(f.name)] if data else []


def m_persistence(c: Corpus) -> Val:
    return _presence(c.find(PERSIST, _data_files(c)), "DataStoreService")


def m_in_data(pattern: re.Pattern, what: str, wide: bool = False) -> Callable[[Corpus], Val]:
    def fn(c: Corpus) -> Val:
        return _presence(c.find(pattern, _data_ish(c) if wide else _data_files(c)), what)
    return fn


def m_save_on_exit(c: Corpus) -> Val:
    files = _data_files(c)
    leave, close = c.find(PLAYER_REMOVING, files), c.find(BIND_CLOSE, files)
    return Val((0.5 if leave else 0.0) + (0.5 if close else 0.0), good=leave[:1] + close[:1],
               note=f"PlayerRemoving {'yes' if leave else 'no'}, BindToClose {'yes' if close else 'no'}")


def _ui_files(c: Corpus) -> list[File]:
    return [f for f in c.side("client", "shared") if GUI_NEW.search(f.code)]


def m_hud(c: Corpus) -> Val:
    client = c.side("client")
    if not client:
        return Val(0.0, note="no client code")
    return _density(c, SCREEN, client, what="ScreenGui sites")


def m_ui_kit(c: Corpus) -> Val:
    mods = [f for f in _ui_files(c) if not f.script]
    shared = []
    for f in mods:
        user = re.compile(r"require\s*\([^\n]*\b" + re.escape(f.name) + r"\b")
        if any(user.search(o.code) for o in c.code if o is not f):
            shared.append(f)
    helpers = c.find(UI_HELPER_DEF, c.side("client", "shared"))
    v = 1.0 if shared else 0.5 if len(helpers) >= 3 else 0.0
    return Val(v, good=[f.summary("UI module required by other files") for f in shared[:2]] + helpers[:2],
               note=(f"shared UI modules: {', '.join(f.name for f in shared[:3])}" if shared
                     else f"{len(helpers)} local UI helper functions, no shared UI module"))


def m_ui_motion(c: Corpus) -> Val:
    files = [f for f in _ui_files(c) if f.side == "client"]
    if not files:
        return Val(0.0, note="no client UI")
    ok = c.having(TWEEN, files)
    return Val(len(ok) / len(files), good=c.find(TWEEN, ok)[:3],
               bad=[f.summary("UI without tweens") for f in _largest([f for f in files if f not in ok])],
               note=f"{len(ok)}/{len(files)} UI files animate")


def m_scale_units(c: Corpus) -> Val:
    files = _ui_files(c)
    scale, offset = c.find(UDIM_SCALE, files), c.find(UDIM_OFFSET, files)
    for f in files:
        for m in UDIM_NEW.finditer(f.code):
            args = [a.strip() for a in m.groups()]
            try:
                xs, xo, ys, yo = (float(a) for a in args)
            except ValueError:
                continue
            h = f.hit(bisect_right(f.starts, m.start()))
            if xs or ys:
                scale.append(h)
            elif xo or yo:
                offset.append(h)
    if not scale and not offset:
        return Val(None, note="no UDim2 sizes")
    return Val(len(scale) / (len(scale) + len(offset)), good=scale[:3], bad=offset,
               note=f"{len(scale)} scale vs {len(offset)} offset-only UDim2s")


def m_genre_items(genre: str) -> Callable[[Corpus], Val]:
    compiled = [(item, [[re.compile(p) for p in group] for group in item["signals"]])
                for item in CHECKLIST_ITEMS[genre]]

    def fn(c: Corpus) -> Val:
        kinds: dict[str, list[Hit]] = {}
        for item, groups in compiled:
            hits = []
            for group in groups:
                hits += [f.find(group[0])[0] for f in c.code if all(r.search(f.code) for r in group)]
            kinds[item["id"]] = hits
        present = [k for k, h in kinds.items() if h]
        return Val(len(present) / len(kinds), good=[kinds[k][0] for k in present][:4], kinds=kinds,
                   note=f"{len(present)}/{len(kinds)} items")
    return fn


def m_buyables(c: Corpus) -> Val:
    hits = c.find(PRICED)
    return Val(float(len(hits)), good=hits, note=f"{len(hits)} priced items")


def _table_entries(code: str, name: re.Pattern) -> tuple[int, int]:
    """(entries, offset) of the first table literal assigned to `name`: nested tables, else strings."""
    m = name.search(code)
    if m is None:
        return 0, -1
    depth, i, entries, flat = 1, m.end(), 0, []
    while i < len(code) and depth:
        ch = code[i]
        if ch == "{":
            depth += 1
            entries += depth == 2
        elif ch == "}":
            depth -= 1
        elif depth == 1:
            flat.append(ch)
        i += 1
    return (entries or len(re.findall(r'"[^"\n]*"', "".join(flat)))), m.start()


def _counted(c: Corpus, table: re.Pattern, what: str) -> Val:
    best, where = 0, None
    for f in c.code:
        n, at = _table_entries(f.code, table)
        if n > best:
            best, where = n, f.hit(bisect_right(f.starts, at))
    return Val(float(best), good=[where] if where else [], note=f"{best} {what}")


def m_stages(c: Corpus) -> Val:
    v = _counted(c, STAGES_TABLE, "stages")
    for h in c.find(STAGE_COUNT):
        m = STAGE_COUNT.search(h.text)
        n = int(m.group(1)) if m else 0
        if 0 < n <= 500 and n > (v.value or 0):
            v = Val(float(n), good=[h], note=f"{n} stages")
    return v


def m_zones(c: Corpus) -> Val:
    v = _counted(c, ZONES_TABLE, "zones")
    if not v.value:
        hits = c.find(ZONE_WORD)
        v = Val(1.0 if hits else 0.0, good=hits[:2], note="zones mentioned" if hits else "no zones")
    return v


def m_obstacles(c: Corpus) -> Val:
    v = _kinds(c, OBSTACLES)
    v.note = f"{int(v.value or 0)} obstacle kinds: {v.note}"
    return v


def m_telemetry(c: Corpus) -> Val:
    seen: dict[str, Hit] = {}
    for f in c.code:
        for m in TELEMETRY.finditer(f.code):
            seen.setdefault(m.group(1), f.hit(bisect_right(f.starts, m.start())))
    kloc = _kloc(c.code)
    if kloc <= 0:
        return Val(None, note="no code")
    return Val(len(seen) / kloc, good=list(seen.values()), note=f"{len(seen)} distinct counters")


def _read(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _n_errors(v: Any) -> int:
    """A playtest's errors: a list (ForgeProbe report) or {count, first} (fix-cycle round digest)."""
    if isinstance(v, list):
        return len(v)
    if isinstance(v, dict):
        return int(_num(v.get("count"), 0, 1e9, len(v.get("first") or [])))
    return int(_num(v, 0, 1e9, 0))


def probe_errors(run_dir: Path) -> tuple[int | None, str, str]:
    """ForgeProbe errors in the newest playtest record: the latest build iteration's report or the latest
    fix cycle's rounds, whichever was written last -> (errors, file, what). errors is None with no playtest."""
    found: list[tuple[float, int, str, str]] = []
    its = [p for p in (run_dir / "iterations").glob("*/report.json") if p.parent.name.isdigit()]
    if its:
        p = max(its, key=lambda q: int(q.parent.name))
        rep = _read(p)
        if isinstance(rep, dict):
            found.append((p.stat().st_mtime, _n_errors(rep.get("errors")), f"iterations/{p.parent.name}/report.json",
                          "build playtest"))
    cycles = [p for p in (run_dir / "improve").glob("[0-9]*.json") if p.stem.isdigit()]
    if cycles:
        p = max(cycles, key=lambda q: int(q.stem))
        rounds = [d for d in (_read(p) or {}).get("before") or [] if isinstance(d, dict)]
        if rounds:
            n = sum(_n_errors(d.get("errors")) for d in rounds)
            found.append((p.stat().st_mtime, n, f"improve/{p.name}", f"fix cycle, {len(rounds)} rounds"))
    if not found:
        return None, "", "no playtest yet"
    _, n, src, what = max(found)
    return n, src, what


def m_probe(c: Corpus) -> Val:
    if c.run_dir is None:
        return Val(None, note="not a Forge run (no playtest record)")
    n, src, what = probe_errors(c.run_dir)
    if n is None:
        return Val(None, note=what)
    hit = Hit(src, 1, f"{n} ForgeProbe errors ({what})")
    return Val(1 / (1 + n), good=[] if n else [hit], bad=[hit] if n else [], note=f"{n} errors in {src} ({what})")


def _spec_example(c: Corpus) -> list[Hit]:
    """A mid-sized spec (not the runner) to copy from."""
    specs = sorted((f for f in c.tests if f.path.endswith(".spec.luau")), key=lambda f: f.sloc)
    return [specs[len(specs) // 2].summary("spec test, run with the luau CLI")] if specs else []


def m_tests(c: Corpus) -> Val:
    if not c.code:
        return Val(None, note="no code")
    checks = sorted((c.run_dir / "checks").glob("*.luau")) if c.run_dir else []
    good = ([f.summary("spec test") for f in c.tests[:3]]
            + [Hit(f"checks/{p.name}", 1, "Forge executable check") for p in checks[:3]])
    return Val((len(c.tests) + len(checks)) / len(c.code), good=good,
               note=f"{len(c.tests)} spec tests + {len(checks)} Forge checks for {len(c.code)} modules")


def m_selftest(c: Corpus) -> Val:
    mods = [f for f in c.side("server") if not f.script]
    if not mods:
        return Val(None, note="no server modules")
    ok = c.having(SELFTEST, mods)
    return Val(len(ok) / len(mods), good=c.find(SELFTEST, ok)[:3],
               note=f"{len(ok)}/{len(mods)} server modules have _selftest")


def _sites(pattern: re.Pattern) -> Callable[[Corpus], list[Hit]]:
    return lambda c: c.find(pattern)


DATA_OWNER = rx(r"Data")
T = ("tycoon",)
O = ("obby",)
G = ("generic",)
METRICS: tuple[Metric, ...] = (
    # architecture
    Metric("server_split", "architecture", "server code in modules",
           "keeps server logic in one ModuleScript per system, booted by a thin Script", "ratio", m_split("server"),
           exemplar=lambda c: _boot_hits(c, "server"), pointer="first"),
    Metric("client_split", "architecture", "client code in modules",
           "keeps client code in controller ModuleScripts booted by one LocalScript", "ratio", m_split("client"),
           exemplar=lambda c: _boot_hits(c, "client"), pointer="first"),
    Metric("lifecycle", "architecture", "Init/Start lifecycle + bootstrap",
           "boots every service and controller through Init/Start from a bootstrap that discovers them",
           "ratio", m_lifecycle, pointer="first"),
    Metric("config_modules", "architecture", "files reading shared config",
           "reads its tunables from shared Config modules", "ratio", m_config),
    Metric("module_size", "architecture", "average module size",
           "keeps modules focused (small files, one system each)", "lower", m_module_size, smooth=200.0),
    Metric("god_files", "architecture", f"code in {GOD_LINES}+ line files",
           f"keeps most code out of {GOD_LINES}-line god scripts", "lower", m_god_files, smooth=0.05),
    Metric("remotes_central", "architecture", "remotes created in one module",
           "creates every remote in one Net module (Net.event / Net.func)", "ratio", m_remotes_central,
           exemplar=_sites(REMOTE_HELPER), pointer="first"),
    Metric("remote_validation", "architecture", "remote handlers validating args",
           "checks every client argument (typeof, NaN, range, tag, distance) before acting", "ratio",
           m_remote_validation),
    Metric("modern_api", "architecture", "deprecated wait/spawn/_G",
           "uses task.wait / task.spawn / task.delay and no _G or shared globals (modules reach each other "
           "through the services table the bootstrap passes to Init)", "lower", m_modern_api,
           exemplar=lambda c: _boot_hits(c, "server"), pointer="first"),
    # robustness
    Metric("pcall_io", "robustness", "Async calls inside pcall",
           "wraps every DataStore / HTTP / marketplace Async call in pcall", "ratio", m_pcall_io, prefer=DATA_OWNER),
    Metric("existing_players", "robustness", "players already in game handled",
           "also runs its PlayerAdded setup for players already in the server (Players:GetPlayers())", "ratio",
           m_existing_players),
    Metric("player_cleanup", "robustness", "per-player state freed on leave",
           "frees per-player state on PlayerRemoving", "ratio", m_player_cleanup),
    Metric("remote_rate_limit", "robustness", "remote handlers rate-limited",
           "rate-limits every client-to-server remote (Net.onServer token bucket)", "ratio", m_remote_rate,
           exemplar=_sites(RATE_HELPER), pointer="first"),
    Metric("server_authority", "robustness", "client writes to currency/progress",
           "keeps currency and progress on the server: the client only sends intents", "lower",
           m_server_authority, exemplar=_sites(HANDLER)),
    # the reference avoids Touched by design (ProximityPrompts), so the bar here is absolute
    Metric("touch_debounce", "robustness", "Touched handlers debounced", "debounces every Touched handler",
           "target", m_touch_debounce),
    # data
    Metric("persistence", "data", "saves progress (DataStore)", "saves player progress with DataStoreService",
           "presence", m_persistence, weight=2.0, prefer=DATA_OWNER,
           exemplar=_sites(rx(r":(?:GetAsync|SetAsync|UpdateAsync)\s*\(|:GetDataStore\s*\(|BindToClose"))),
    Metric("studio_fallback", "data", "Studio / no-DataStore fallback",
           "falls back to an in-memory store in Studio or when DataStores are unavailable", "presence",
           m_in_data(STUDIO_FALLBACK, "fallback"), prefer=DATA_OWNER),
    Metric("schema_version", "data", "schema version + migration", "versions its save schema and migrates old saves",
           "presence", m_in_data(SCHEMA, "versioned schema", wide=True), prefer=rx(r"Schema|Profile"),
           exemplar=_sites(rx(r"(?i)migrat\w*\s*[=(]"))),
    Metric("safe_writes", "data", "UpdateAsync / session lock", "writes saves with UpdateAsync under a session lock",
           "presence", m_in_data(SAFE_WRITE, "UpdateAsync / lock", wide=True), prefer=DATA_OWNER),
    Metric("save_on_exit", "data", "saves on leave + shutdown", "saves on PlayerRemoving and in BindToClose",
           "ratio", m_save_on_exit, prefer=DATA_OWNER),
    Metric("retries", "data", "retries / request budget", "retries DataStore calls and waits for request budget",
           "presence", m_in_data(RETRY, "retries"), prefer=DATA_OWNER),
    # ui
    Metric("hud", "ui", "ScreenGuis per 1k client lines", "builds its HUD and menus as ScreenGuis", "density",
           m_hud, prefer=rx(r"Hud")),
    Metric("ui_styling", "ui", "UI styling kinds",
           "styles UI with UIStroke, UICorner, UIGradient, UIScale, padding, layouts and constraints",
           "coverage", lambda c: _kinds(c, UI_STYLE, c.side("client", "shared"))),
    Metric("ui_kit", "ui", "shared UI kit module",
           "builds UI through one shared kit module (UiKit) that every screen requires", "ratio", m_ui_kit,
           prefer=UI_OWNER),
    Metric("ui_motion", "ui", "UI files that animate", "animates its UI (pop / punch / tweens) on every screen",
           "ratio", m_ui_motion, prefer=UI_OWNER),
    Metric("feedback", "ui", "toast/popup sites per 1k lines", "tells the player what happened with toasts and popups",
           "density", lambda c: _density(c, FEEDBACK), prefer=rx(r"Popup|Toast|Notify|Hud")),
    Metric("mobile", "ui", "mobile-safe UI kinds",
           "adapts UI to phones (UIScale, text fitting, safe-area insets, touch input)", "coverage",
           lambda c: _kinds(c, MOBILE, c.side("client", "shared"))),
    Metric("scale_units", "ui", "UDim2 in scale units", "sizes and places UI in scale units", "ratio", m_scale_units,
           prefer=UI_OWNER),
    # juice
    Metric("juice_kinds", "juice", "juice kinds",
           "layers sound, particles, tweens, camera shake, music, lighting and light flashes", "coverage",
           lambda c: _kinds(c, JUICE), weight=2.0),
    Metric("sound_density", "juice", "sound sites per 1k lines", "plays sounds for its actions", "density",
           lambda c: _density(c, SOUND), prefer=PREFER["sound"]),
    Metric("particle_density", "juice", "particle sites per 1k lines", "bursts particles on big moments",
           "density", lambda c: _density(c, PARTICLE), prefer=PREFER["particles"]),
    Metric("tween_density", "juice", "tween sites per 1k lines", "tweens what moves and changes", "density",
           lambda c: _density(c, TWEEN), prefer=PREFER["tween"]),
    # content (genre depth: the bar is the genre checklist / lessons_library, not the reference)
    Metric("tycoon_checklist", "content", "tycoon checklist", "covers the tycoon checklist (forge/gaps.py)",
           "target", m_genre_items("tycoon"), weight=2.0, genres=T),
    Metric("buyables", "content", "purchasable upgrades",
           "offers ~10 purchasable upgrades (forge/lessons_library/tycoon.md)", "target", m_buyables,
           target=10, genres=T, kit="forge/ui_library/BuyPad.luau"),
    Metric("obby_checklist", "content", "obby checklist", "covers the obby checklist (forge/compare.py)", "target",
           m_genre_items("obby"), weight=2.0, genres=O),
    Metric("stages", "content", "stages", "has ~15 stages (forge/lessons_library/obby.md)", "target", m_stages,
           target=15, genres=O, kit=LESSONS["obby"]),
    Metric("obstacle_kinds", "content", "obstacle kinds",
           "mixes ~6 obstacle kinds (kill bricks, movers, spinners, jump pads, ...)", "target", m_obstacles,
           target=6, genres=O, kit=LESSONS["obby"]),
    Metric("zones", "content", "zones / worlds", "groups stages into ~3 themed zones", "target", m_zones, target=3,
           genres=O, kit=LESSONS["obby"]),
    Metric("generic_checklist", "content", "game checklist", "covers the generic game checklist (forge/gaps.py)",
           "target", m_genre_items("generic"), weight=2.0, genres=G),
    Metric("interactions", "content", "interaction kinds",
           "gives players many ways to act (prompts, tools, vehicles, input actions, physics, NPCs...)", "coverage",
           lambda c: _kinds(c, INTERACTIONS), genres=G),
    Metric("progression", "content", "progression kinds",
           "layers progression (XP/levels, unlocks, missions, inventory, awards, shop, leaderboards...)",
           "coverage", lambda c: _kinds(c, PROGRESSION), genres=G),
    # observability / tests
    Metric("telemetry", "observability", "distinct counters per 1k lines",
           "counts gameplay events with ForgeTelemetry counters", "density", m_telemetry),
    Metric("probe_clean", "observability", "ForgeProbe errors (last playtest)", "plays with no ForgeProbe errors",
           "target", m_probe),
    Metric("tests", "observability", "tests per module",
           "has pure-Luau spec tests (game/tests) for its logic", "ratio", m_tests, exemplar=_spec_example),
    Metric("selftest", "observability", "server modules with _selftest",
           "gives services a _selftest hook for DevHook checks", "ratio", m_selftest, weight=0.5),
)


# ------------------------------------------------------------------------------- scoring


def metric_score(m: Metric, g: Val, r: Val) -> float | None:
    """0-1 for one metric, or None when it does not apply (the reference doesn't do it either, or the game
    has nothing it applies to, e.g. no remotes to validate)."""
    if g.value is None:
        return None
    if m.kind == "target":
        return max(0.0, min(1.0, g.value / m.target))
    if r.value is None:
        return None
    if m.kind == "coverage":
        want = [k for k, hits in (r.kinds or {}).items() if hits]
        return (sum(1 for k in want if (g.kinds or {}).get(k)) / len(want)) if want else None
    if m.kind == "lower":
        return 1.0 if g.value + m.smooth <= 0 else min(1.0, (r.value + m.smooth) / (g.value + m.smooth))
    return max(0.0, min(1.0, g.value / r.value)) if r.value > 0 else None


def _main(m: Metric, v: Val) -> str:
    """The value alone, with its unit."""
    if v.value is None:
        return "n/a"
    x = v.value
    if m.kind == "presence":
        return "yes" if x else "no"
    if m.kind == "coverage":
        return f"{int(x)}/{len(v.kinds or {})} kinds"
    if m.kind == "ratio" or m.id == "god_files" or (m.kind == "target" and m.target == 1):
        return f"{x:.0%}"
    if m.kind == "target":
        return f"{x:g}/{m.target:g}"
    if m.id == "module_size":
        return f"{x:.0f} lines/file"
    return f"{x:.2f}/1k lines" if x < 10 else f"{x:.1f}/1k lines"


def _fmt(m: Metric, v: Val) -> str:
    main = _main(m, v)
    return f"{main} ({v.note})" if v.note else main


def _best_file(hits: list[Hit], corpus: Corpus, mode: str, prefer: re.Pattern | None = None) -> Hit | None:
    """The reference site to copy from: the first hit, or the file doing it most (ties: the smaller file),
    among files whose name says they own the concern when there are any."""
    hits = [h for h in hits if not h.file.rsplit("/", 1)[-1].split(".")[0].endswith("Config")] or hits
    if prefer is not None:
        hits = [h for h in hits if prefer.search(h.file.rsplit("/", 1)[-1])] or hits
    if not hits:
        return None
    if mode == "first":
        return hits[0]
    by: dict[str, list[Hit]] = {}
    for h in hits:
        by.setdefault(h.file, []).append(h)
    f = corpus.file
    best = max(by, key=lambda p: (len(by[p]), -(f(p).sloc if f(p) else 0)))
    return by[best][0]


def _repo_pointer(path: str, text: str) -> dict | None:
    return {"file": path, "line": 1, "text": text, "source": "kit"} if (REPO_ROOT / path).is_file() else None


def _kind_pointer(kind: str, rv: Val, ref: Corpus) -> dict | None:
    if kind in KIT_POINTERS:
        return _repo_pointer(KIT_POINTERS[kind], "Forge UI kit snippet")
    if kind in GENRE_SPECIFIC:
        return _repo_pointer(LESSONS.get(ref.genre, LESSONS["generic"]), f"{ref.genre} lessons")
    hit = _best_file((rv.kinds or {}).get(kind) or [], ref, "dense", PREFER.get(kind))
    return {**hit.as_dict(), "source": "reference"} if hit else None


def _pointer(m: Metric, rv: Val, ref: Corpus) -> dict | None:
    if m.kit:
        return _repo_pointer(m.kit, "Forge kit")
    hits = (m.exemplar(ref) if m.exemplar else []) or rv.good
    hit = _best_file(hits, ref, m.pointer, m.prefer)
    return {**hit.as_dict(), "source": "reference"} if hit else None


def _row(m: Metric, g: Val, r: Val, ref: Corpus) -> dict:
    s = metric_score(m, g, r)
    target = (f"target {m.target:g}" if m.target != 1 else "target 100%") + f"; reference {_fmt(m, r)}"
    row: dict[str, Any] = {"id": m.id, "label": m.label, "kind": m.kind, "weight": m.weight,
                           "score": None if s is None else round(s, 3), "value": g.value, "ref_value": r.value,
                           "game": _fmt(m, g), "reference": target if m.kind == "target" else _fmt(m, r),
                           "game_main": _main(m, g), "ref_main": (f"{m.target:g}" if m.kind == "target" and m.target != 1
                                                                  else "100%" if m.kind == "target" else _main(m, r)),
                           "evidence": [h.as_dict() for h in g.good[:3]],
                           "misses": [h.as_dict() for h in g.bad[:3]] if s is not None and s < 0.999 else []}
    if g.kinds is not None:
        have = {k for k, hits in g.kinds.items() if hits}
        wanted = [k for k, hits in (r.kinds or {}).items() if hits] if m.kind == "coverage" else list(g.kinds)
        row["kinds"] = sorted(have)
        row["missing"] = [k for k in wanted if k not in have]
        row["kind_pointers"] = {k: p for k in row["missing"][:8] if (p := _kind_pointer(k, r, ref))}
    ptrs = row.get("kind_pointers") or {}
    row["ref"] = next(iter(ptrs.values())) if ptrs else _pointer(m, r, ref)
    return row


def _gap_text(m: Metric, row: dict) -> tuple[str, str]:
    """(sentence, short table cell)."""
    if row.get("missing"):
        miss = [k.replace("_", " ") for k in row["missing"]]
        lead = "Genre bar" if m.kind == "target" else "Reference"
        return (f"{lead}: {m.does}; this game is missing {', '.join(miss[:6])}.",
                f"{m.label}: missing {', '.join(miss[:3])}" + (" ..." if len(miss) > 3 else ""))
    if m.kind == "target":
        return (f"Genre bar: {m.does}; this game: {row['game']}.",
                f"{m.label}: {row['game_main']} (bar {row['ref_main']})")
    return (f"Reference {m.does} ({row['ref_main']}); this game: {row['game']}.",
            f"{m.label}: {row['game_main']} vs {row['ref_main']}")


def _gaps(metrics: list[Metric], rows: list[dict], label: str) -> list[dict]:
    out = []
    for m, row in zip(metrics, rows):
        if row["score"] is None or row["score"] >= 0.999:
            continue
        ptr = row.get("ref")
        text, short = _gap_text(m, row)
        out.append({"metric": m.id, "label": m.label, "category": m.category, "category_label": label,
                    "score": row["score"], "weight": m.weight, "loss": round(m.weight * (1 - row["score"]), 3),
                    "text": text, "short": short, "pointer": f"{ptr['file']}:{ptr['line']}" if ptr else None,
                    "pointer_source": ptr.get("source") if ptr else None,
                    "pointers": {k: f"{p['file']}:{p['line']}" for k, p in (row.get("kind_pointers") or {}).items()},
                    "misses": row["misses"][:2], "missing": row.get("missing", [])[:6]})
    out.sort(key=lambda g: (-g["loss"], g["score"]))
    return out[:GAPS_PER_CATEGORY]


def genre_of(spec: dict) -> str:
    genre = detect_genre(spec or {})
    if genre != "generic":
        return genre
    text = " ".join(str((spec or {}).get(k) or "") for k in ("title", "pitch", "core_loop")).lower()
    return "obby" if re.search(r"\bobby\b|obstacle course|parkour|\bstages?\b.*\bcheckpoints?\b", text) else "generic"


def _size(c: Corpus) -> dict:
    return {"files": len(c.code), "modules": sum(1 for f in c.code if not f.script), "sloc": c.sloc,
            "tests": len(c.tests), "client_sloc": sum(f.sloc for f in c.side("client")),
            "server_sloc": sum(f.sloc for f in c.side("server"))}


def compare(game_dir: Path, ref_dir: Path, *, spec: dict | None = None, run_dir: Path | None = None,
            name: str | None = None, ref_name: str | None = None) -> dict:
    """Static comparison of the game at `game_dir` against the reference at `ref_dir` (see module doc)."""
    game_dir, ref_dir = Path(game_dir), Path(ref_dir)
    if not ref_dir.is_dir():
        raise FileNotFoundError(f"no reference game folder {ref_dir}")
    if not game_dir.is_dir():
        raise FileNotFoundError(f"no game folder {game_dir}")
    genre = genre_of(spec or {})
    game = Corpus.load(game_dir, genre=genre, run_dir=run_dir)
    ref = Corpus.load(ref_dir, genre=genre)
    cats = []
    for cid, label in CATEGORIES:
        metrics = [m for m in METRICS if m.category == cid and (not m.genres or genre in m.genres)]
        rows = [_row(m, m.fn(game), m.fn(ref), ref) for m in metrics]
        scored = [(m.weight, r["score"]) for m, r in zip(metrics, rows) if r["score"] is not None]
        score = round(10 * sum(w * s for w, s in scored) / sum(w for w, _ in scored), 1) if scored else None
        evidence = list({(e["file"], e["line"]): e for r in rows if r["score"] is not None
                         for e in r["misses"][:1] + r["evidence"][:1]}.values())[:8]
        cats.append({"id": cid, "label": label, "score": score, "metrics": rows, "evidence": evidence,
                     "gaps": _gaps(metrics, rows, label)})
    scores = [c["score"] for c in cats if c["score"] is not None]
    overall = round(sum(scores) / len(scores), 1) if scores else 0.0
    # each category's worst gap first, so the top of the list (and the judge's areas) spans categories
    def rank(gs: list[dict]) -> list[dict]:
        return sorted(gs, key=lambda g: (-g["loss"], g["score"]))
    gaps = rank([c["gaps"][0] for c in cats if c["gaps"]]) + rank([g for c in cats for g in c["gaps"][1:]])
    return {"game": name or game_dir.name, "reference": ref_name or ref_dir.name, "game_dir": str(game_dir),
            "ref_dir": str(ref_dir), "genre": genre, "ts": now_iso(),
            "size": {"game": _size(game), "reference": _size(ref)}, "overall": overall,
            "verdict": verdict(overall), "categories": cats, "gaps": gaps[:6]}


def verdict(overall: float) -> str:
    if overall >= 9:
        return "on par with the reference"
    if overall >= 7:
        return "close to the reference"
    if overall >= 4:
        return "partway to the reference"
    return "far from the reference"


# ------------------------------------------------------------------------------- the optional LLM judge


def _clip(text: Any, n: int) -> str:
    s = " ".join(str(text or "").split())
    return s if len(s) <= n else s[: n - 1] + "…"


def _excerpt(corpus: Corpus, path: str, line: int, before: int = 3, after: int = 14) -> str:
    f = corpus.file(path)
    if f is None:
        p = REPO_ROOT / path
        raw = p.read_text(encoding="utf-8", errors="replace").split("\n") if p.is_file() else []
    else:
        raw = f.raw
    lo = max(0, line - 1 - before)
    return "\n".join(f"{i + 1:>5}  {raw[i].rstrip()[:160]}" for i in range(lo, min(len(raw), line + after)))


def _game_site(game: Corpus, gap: dict) -> tuple[str, int] | None:
    for h in gap.get("misses") or []:
        if game.file(h["file"]):
            return h["file"], h["line"]
    site = SITES.get(gap["category"])
    hits = game.find(site) if site is not None else []
    if hits:
        return hits[0].file, hits[0].line
    big = _largest(game.code, 1)
    return (big[0].path, 1) if big else None


def judge_message(report: dict, game: Corpus, ref: Corpus, *, areas: int = 4) -> str:
    sz = report["size"]
    head = [(f"## Game\n{report['game']} (genre {report['genre']}): {sz['game']['sloc']:,} code lines in "
             f"{sz['game']['files']} files; files: ") + ", ".join(f.path for f in game.code[:40]),
            (f"## Reference\n{report['reference']}: {sz['reference']['sloc']:,} code lines in "
             f"{sz['reference']['files']} files (human-built; it scores 10 against itself)"),
            f"## Static comparison: overall {report['overall']}/10 ({report['verdict']})"]
    for c in report["categories"]:
        rows = "; ".join(f"{r['label']}: {_clip(r['game'], 70)} vs {_clip(r['reference'], 50)}"
                         for r in c["metrics"] if r["score"] is not None and r["score"] < 0.999)
        head.append(f"- {c['label']} {c['score'] if c['score'] is not None else 'n/a'}/10" + (f": {rows}" if rows else ""))
    tail = "Return only the JSON object."
    fixed = "\n".join(head) + "\n\n" + tail
    budget = max(4000, MAX_USER_CHARS - len(fixed) - 400)
    blocks = []
    picked = report["gaps"][:areas]
    per = budget // max(1, len(picked))
    for i, g in enumerate(picked, 1):
        site = _game_site(game, g)
        ptr = g.get("pointer")
        title = f"### Area {i}: [{g['category']}] {g['label']} (score {g['score']})\n{g['text']}\n"
        room = max(600, (per - len(title) - 120) // 2)
        mine = _fit_lines(_excerpt(game, *site, before=4, after=24), room) if site else "(no game code)"
        theirs, lang = "(no reference file)", "luau"
        if ptr:
            path, _, line = ptr.rpartition(":")
            theirs = _fit_lines(_excerpt(ref, path, int(line), before=3, after=30), room)
            lang = "luau" if path.endswith(".luau") else ""
        blocks.append(f"{title}#### This game ({site[0] + ':' + str(site[1]) if site else 'none'})\n```luau\n{mine}\n```\n"
                      f"#### Reference ({ptr or 'none'})\n```{lang}\n{theirs}\n```")
    return "\n".join(head) + "\n\n## Weakest areas, side by side\n" + "\n\n".join(blocks) + "\n\n" + tail


def _fit_lines(text: str, limit: int) -> str:
    """Whole lines up to `limit` chars."""
    out, used = [], 0
    for ln in text.split("\n"):
        if used + len(ln) + 1 > limit:
            out.append("  ...")
            break
        out.append(ln)
        used += len(ln) + 1
    return "\n".join(out)


def _num(v: Any, lo: float, hi: float, default: float) -> float:
    try:
        return max(lo, min(hi, float(v)))
    except (TypeError, ValueError):
        return default


def parse_judgement(obj: dict, game_files: set[str], ref_files: set[str]) -> dict:
    """Keep the judge honest: files must exist in the game (new files must sit in a synced root), reference
    pointers must name a real reference file; the model's order is the rank."""
    roots = ("ServerScriptService/", "ReplicatedStorage/", "StarterPlayerScripts/", "StarterGui/", "ServerStorage/")
    out = []
    for it in obj.get("improvements") or []:
        if not isinstance(it, dict) or not str(it.get("title") or "").strip():
            continue
        named = [str(f).strip() for f in it.get("files") or [] if str(f).strip()]
        ref = str(it.get("reference") or "").strip()
        cat = str(it.get("category") or "").strip().lower()
        out.append({"rank": len(out) + 1, "title": _clip(it["title"], 140),
                    "category": cat if cat in CATEGORY_IDS else "other",
                    "impact": _num(it.get("impact"), 1, 10, 5), "effort": _clip(it.get("effort"), 10) or "M",
                    "why": _clip(it.get("why"), 400), "how": _clip(it.get("how"), 900),
                    "files": [f for f in named if f in game_files],
                    "new_files": [f for f in named if f not in game_files and f.startswith(roots) and f.endswith(".luau")],
                    "reference": ref if ref.split(":")[0] in ref_files else None})
    return {"summary": _clip(obj.get("summary"), 600), "verdict": _clip(obj.get("verdict"), 200),
            "improvements": out[:8]}


def judge(llm: Any, report: dict, *, session_id: str) -> dict:
    """One `code_judge` call: the static report + the weakest areas' code next to the reference's."""
    game = Corpus.load(Path(report["game_dir"]))
    ref = Corpus.load(Path(report["ref_dir"]))
    obj, res = llm.complete_json(ROLE, judge_message(report, game, ref), session_id=session_id,
                                 required=["improvements"], max_tokens=4000)
    out = parse_judgement(obj, {f.path for f in game.files}, {f.path for f in ref.files})
    out["request_id"] = res.request_id
    return out


# ------------------------------------------------------------------------------- output


def render(report: dict) -> str:
    """The compact table `forge compare` prints."""
    sz = report["size"]
    lines = [(f"{report['game']} vs {report['reference']}  ({report['genre']}; {sz['game']['sloc']:,} vs "
              f"{sz['reference']['sloc']:,} code lines, {sz['game']['files']} vs {sz['reference']['files']} files)"),
             f"  {'category':<21}{'score':>5}  biggest gap -> reference file to copy"]
    for c in report["categories"]:
        sc = "n/a" if c["score"] is None else f"{c['score']:.1f}"
        g = c["gaps"][0] if c["gaps"] else None
        tail = (_clip(g["short"], 70) + (f" -> {g['pointer']}" if g["pointer"] else "")) if g else "on par"
        lines.append(f"  {c['label']:<21}{sc:>5}  {tail}")
    lines.append(f"  {'overall':<21}{report['overall']:>5.1f}  {report['verdict']} (the reference scores 10)")
    for it in ((report.get("llm") or {}).get("improvements") or [])[:5]:
        lines.append(f"  judge #{it['rank']} [{it['category']}, impact {it['impact']:g}] {_clip(it['title'], 100)}")
    return "\n".join(lines)


def render_md(report: dict) -> str:
    sz = report["size"]
    out = [f"# forge compare: {report['game']} vs {report['reference']}", "",
           (f"{report['ts']} · genre **{report['genre']}** · {sz['game']['sloc']:,} vs {sz['reference']['sloc']:,} "
            f"code lines · {sz['game']['files']} vs {sz['reference']['files']} files · {sz['game']['tests']} vs "
            f"{sz['reference']['tests']} spec tests"), "",
           (f"**Overall {report['overall']}/10**: {report['verdict']} (the reference scores 10 against itself). "
            "Scores compare shares, presence and per-1k-line densities, not size; content is scored "
            "against the genre bar."), "", "| category | score | biggest gap |", "|---|---|---|"]
    for c in report["categories"]:
        g = c["gaps"][0]["text"] if c["gaps"] else "on par"
        out.append(f"| {c['label']} | {c['score'] if c['score'] is not None else 'n/a'} | {g} |")
    for c in report["categories"]:
        out += ["", f"## {c['label']}: {c['score'] if c['score'] is not None else 'n/a'}/10", "",
                "| metric | this game | reference | score |", "|---|---|---|---|"]
        for r in c["metrics"]:
            sc = "n/a" if r["score"] is None else f"{r['score']:.2f}"
            out.append(f"| {r['label']} | {r['game']} | {r['reference']} | {sc} |")
        if c["evidence"]:
            out += ["", "Evidence:"] + [f"- `{e['file']}:{e['line']}` {e['text']}" for e in c["evidence"]]
        if c["gaps"]:
            out += ["", "Gaps (the reference does it, this game doesn't):"]
            for i, g in enumerate(c["gaps"], 1):
                out.append(f"{i}. {g['text']}" + (f" Copy from `{g['pointer']}`." if g["pointer"] else ""))
                if len(g["pointers"]) > 1:
                    out += [f"   - {k.replace('_', ' ')}: `{ptr}`" for k, ptr in g["pointers"].items()]
                for miss in g["misses"]:
                    out.append(f"   - here: `{miss['file']}:{miss['line']}` {miss['text']}")
    llm = report.get("llm")
    if llm:
        out += ["", "## Code judge (Mubit task code_judge)", "", llm.get("summary") or ""]
        for it in llm.get("improvements") or []:
            out.append(f"{it['rank']}. **{it['title']}** [{it['category']}, impact {it['impact']:g}, effort "
                       f"{it['effort']}] {it['why'].rstrip('.')}. How: {it['how'].rstrip('.')}."
                       + (f" Files: {', '.join(it['files'] + it['new_files'])}." if it['files'] or it['new_files'] else "")
                       + (f" Reference: `{it['reference']}`." if it.get("reference") else ""))
    return "\n".join(out) + "\n"


def save(report: dict, out_dir: Path) -> Path:
    """out_dir/<n>.json + <n>.md, n = 1, 2, ... (sets report["n"])."""
    out_dir.mkdir(parents=True, exist_ok=True)
    report["n"] = max((int(p.stem) for p in out_dir.glob("*.json") if p.stem.isdigit()), default=0) + 1
    path = out_dir / f"{report['n']}.json"
    path.write_text(json.dumps(report, indent=1, ensure_ascii=False), encoding="utf-8")
    path.with_suffix(".md").write_text(render_md(report), encoding="utf-8")
    return path


# ------------------------------------------------------------------------------- targets, CLI, forge done


@dataclass
class Target:
    name: str
    dir: Path
    spec: dict
    run_dir: Path | None  # the Forge run (playtest records, checks), read only
    out_dir: Path  # where reports go


def resolve(settings: Settings, name: str) -> Target:
    """`game` (the base game), a slug in runs/, or a game folder. A folder inside another checkout's runs/
    is read only: its reports go to runs/compare/<name>/ here."""
    if name == "game":
        return Target("game", settings.base_game_dir, {}, None, settings.runs_dir / "compare" / "game")
    store = RunStore(settings, name)
    if store.game_dir.is_dir():
        return Target(name, store.game_dir, _read(store.spec_path) or {}, store.dir, store.dir / "compare")
    p = Path(name).expanduser()
    if not p.is_dir():
        raise FileNotFoundError(f"no game {name!r}: not 'game', a slug in {settings.runs_dir} or a folder")
    p = p.resolve()
    run = p.parent if p.name == "game" and any((p.parent / f).exists() for f in ("spec.json", "state.json")) else None
    label = run.name if run else p.name
    local = run is not None and run.parent == settings.runs_dir.resolve()
    out = run / "compare" if local else settings.runs_dir / "compare" / label
    return Target(label, p, (_read(run / "spec.json") or {}) if run else {}, run, out)


def done_summary(settings: Settings, slug: str) -> dict | None:
    """Category scores vs the base game for `forge done` (informational; None when it can't be computed)."""
    try:
        t = resolve(settings, slug)
        ref = settings.base_game_dir
        if not ref.is_dir() or t.dir.resolve() == ref.resolve():
            return None
        rep = compare(t.dir, ref, spec=t.spec, run_dir=t.run_dir, name=t.name, ref_name="game")
    except Exception:  # noqa: BLE001  informational only: `forge done` must never fail because of it
        return None
    return {"slug": slug, "reference": rep["reference"], "overall": rep["overall"],
            "categories": {c["id"]: c["score"] for c in rep["categories"]},
            "top_gap": rep["gaps"][0]["text"] if rep["gaps"] else ""}


def done_line(summary: dict) -> str:
    cats = ", ".join(f"{cid} {'n/a' if s is None else f'{s:g}'}" for cid, s in summary["categories"].items())
    return (f"  [i] compare   {summary['overall']:g}/10 vs {summary['reference']}: {cats} "
            f"(informational; forge compare {summary['slug']} for evidence)")


def add_cli_parser(sub) -> None:
    p = sub.add_parser("compare", help="score a game's code against the reference game (default game/: Flame and "
                                       "Blame): categories, evidence, gaps with reference files to copy")
    p.add_argument("slug", help="a game in runs/, 'game', or a game folder")
    p.add_argument("--against", default="game", help="the reference: game (default), a slug or a folder")
    p.add_argument("--llm", action="store_true", help="also ask Mubit (code_judge) for ranked improvements (1 call)")
    p.add_argument("--json", action="store_true", help="print the full report as JSON")


def cmd_compare(args) -> int:
    s = load_settings()
    t, ref = resolve(s, args.slug), resolve(s, args.against)
    report = compare(t.dir, ref.dir, spec=t.spec, run_dir=t.run_dir, name=t.name, ref_name=ref.name)
    if args.llm:
        from forge.llm import make_llm
        local_run = t.run_dir is not None and t.out_dir == t.run_dir / "compare"
        log = t.run_dir / "calls.jsonl" if local_run else t.out_dir / "calls.jsonl"
        report["llm"] = judge(make_llm(s, log_path=log), report, session_id=t.name)
    path = save(report, t.out_dir)
    if args.json:
        print(json.dumps(report, indent=1, ensure_ascii=False))
    else:
        print(render(report))
        print(f"\nsaved {path} and {path.with_suffix('.md')}")
    return 0
