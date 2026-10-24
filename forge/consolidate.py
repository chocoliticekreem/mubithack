"""`forge consolidate <slug>`: one architect pass over a game that grew feature by feature.

Features built one at a time each add their own files. Overnight that left a 200-stage obby with five
overlapping juice modules, one *Ack server script per client effect (each with its own RemoteEvent and rate
limiter, only to bump a counter) and no Init/Start bootstrap. This pass merges what overlaps and folds loose
scripts into the reference game's shape (game/: ServerScriptService/Main.server.luau boots
Services/*Service, its client twin boots Controllers/*Controller), behind a gate.

    module_map(game_dir, protected) -> rows       every file the plan may touch: path, type, lines, chars,
                                                  first comment line, game modules it requires and is
                                                  required by, remotes it creates / fires / handles, counters
    make_plan(...)                                Mubit task `architect` (forge/prompts/architect.md): the map,
                                                  compare's architecture gaps, the spec, the prebuilt list and
                                                  the limits in the user message -> JSON plan -> validate();
                                                  one correction call in the same task with the problems
    validate(raw, game_dir, protected, rows, max_merges) -> (plan, problems)
                                                  kit / level / runtime / GameAssets / bootstrap paths refused,
                                                  sides never mixed, one owner per file, MERGE_SOURCE_CHARS per
                                                  merge, at most max_merges units; every remaining file that
                                                  requires a removed module is rewired (added when missing)
    execute(run, plan, ...)                       coder per unit (the originals' full source + their callers'
                                                  call sites + every move of the pass), prebuilt bootstraps
                                                  (forge/kit/bootstrap), deletes, rewires (patcher above
                                                  PATCH_ABOVE_LINES, else fixer + destructive guard), compile +
                                                  fixer, then new dangling requires -> one fixer pass
    measure(...) / findings(before, after, ...)   the gate in Studio, before vs after: the saved checks (a pass
                                                  that turns into a fail, confirmed by a rerun), and a probe
                                                  playtest (new server or client errors, new warnings naming a
                                                  changed module, a counter that was > 0 and is gone; probe
                                                  findings are confirmed by a second probe)
    consolidate(settings, slug, *, plan_only, max_merges, ...) -> record
                                                  runs/<slug>/consolidate/<n>.json; a failed gate restores the
                                                  version before (GameVersions, saved as a new version) and
                                                  resyncs Studio. Kept: spec modules updated, compare after.

Never touched: ReplicatedStorage/Kit/*, ReplicatedStorage/Levels/*, GameAssets, the Forge runtime, tools/,
spec base_files and prebuilt modules.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import re
from collections.abc import Callable
from pathlib import Path
from typing import Any

from forge.config import Settings, load_settings
from forge.memory import RunStore, now_iso
from forge.versions import GameVersions

ROLE = "architect"
PLAN_KEYS = ["summary", "merges"]
PLAN_MAX_TOKENS = 8000
MAX_MERGES = 6  # coder-written files per pass: merges and scripts folded into a bootstrap, together
MAX_REWIRES = 10
MERGE_SOURCE_CHARS = 18_000  # originals one coder call reads in full (the fixer's source cap, roles.fix_file)
MAP_CHARS = 14_000
CALLERS_CHARS = 2600
PROBE_SECONDS = 12.0
SERVER_BOOT = "ServerScriptService/Main.server.luau"
CLIENT_BOOT = "StarterPlayerScripts/Main.client.luau"
SERVICES = "ServerScriptService/Services/"
CONTROLLERS = "StarterPlayerScripts/Controllers/"
BOOT_DIR = Path(__file__).resolve().parent / "kit" / "bootstrap"
BOOT_MARKS = ("Forge's server bootstrap", "Forge's client bootstrap")
PROTECTED_PREFIXES = ("ReplicatedStorage/Kit/", "ReplicatedStorage/Levels/", "tools/", "tests/")
SIDES = {"ServerScriptService": "server", "StarterPlayerScripts": "client", "ReplicatedStorage": "shared"}
# Children of PlayerScripts that Roblox adds itself (a lookup of them is never dangling)
ROBLOX_CHILDREN = {"PlayerModule", "RbxCharacterSounds", "ChatScript", "BubbleChat", "PlayerScriptsLoader"}

CLIENT_LOG_LUAU = r"""
local LogService = game:GetService("LogService")
local HttpService = game:GetService("HttpService")
local start = os.time() - math.floor(time()) - 2
local out = { errors = {}, warnings = {} }
for _, e in LogService:GetLogHistory() do
	if e.timestamp >= start then
		if e.messageType == Enum.MessageType.MessageError then
			table.insert(out.errors, e.message)
		elseif e.messageType == Enum.MessageType.MessageWarning then
			table.insert(out.warnings, e.message)
		end
	end
end
return HttpService:JSONEncode(out)
"""


# ------------------------------------------------------------------------------- paths


def instance_name(rel: str) -> str:
    name = rel.rsplit("/", 1)[-1]
    for suffix in (".server.luau", ".client.luau", ".luau"):
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return name


def folder_of(rel: str) -> str:
    return rel.rsplit("/", 1)[0] if "/" in rel else ""


def kind_of(rel: str) -> str:
    return "Script" if rel.endswith(".server.luau") else "LocalScript" if rel.endswith(".client.luau") else "ModuleScript"


def side_of(rel: str) -> str:
    return SIDES.get(rel.split("/", 1)[0], "other")


def booted(rel: str) -> str | None:
    """"service" / "controller" for a module the prebuilt bootstraps boot, else None."""
    name = rel.rsplit("/", 1)[-1]
    if rel.startswith(SERVICES) and "/" not in rel[len(SERVICES):] and re.fullmatch(r"\w+Service\.luau", name):
        return "service"
    if rel.startswith(CONTROLLERS) and "/" not in rel[len(CONTROLLERS):] and re.fullmatch(r"\w+Controller\.luau", name):
        return "controller"
    return None


def _valid_path(rel: str) -> bool:
    return (rel.endswith(".luau") and rel.split("/", 1)[0] in SIDES and ".." not in rel.split("/")
            and re.fullmatch(r"[\w./-]+", rel) is not None)


def protected_paths(spec: dict, game_dir: Path) -> set[str]:
    """Files no consolidation touches: the runtime, kit modules and level data, GameAssets, spec base_files and
    prebuilt modules, and Forge's own bootstraps from an earlier pass."""
    from forge import director
    from forge.loop import RUNTIME_FILES

    out = set(RUNTIME_FILES) | director.protected_paths(spec, game_dir) | {director.GAME_ASSETS}
    out |= {p for p in spec.get("base_files") or [] if isinstance(p, str)}
    out |= {m["path"] for m in spec.get("modules") or [] if isinstance(m, dict) and m.get("prebuilt") and m.get("path")}
    for boot in (SERVER_BOOT, CLIENT_BOOT):
        p = Path(game_dir) / boot
        if p.is_file() and any(mark in p.read_text(encoding="utf-8", errors="replace") for mark in BOOT_MARKS):
            out.add(boot)
    return out


def is_protected(rel: str, protected: set[str]) -> bool:
    from forge.gaps import RUNTIME_FILES as RUNTIME_NAMES

    return (rel in protected or rel.startswith(PROTECTED_PREFIXES)
            or rel.rsplit("/", 1)[-1].startswith(RUNTIME_NAMES))


def game_files(game_dir: Path) -> list[str]:
    return sorted(p.relative_to(game_dir).as_posix() for p in Path(game_dir).rglob("*.luau")
                  if "/." not in p.relative_to(game_dir).as_posix())


# ------------------------------------------------------------------------------- module references

_SERVICE_VAR = re.compile(r"\blocal\s+(\w+)\s*(?::[^=\n]+)?=\s*game:GetService\(\s*[\"'](\w+)[\"']\s*\)")
_PARENT_VAR = re.compile(r"\blocal\s+(\w+)\s*(?::[^=\n]+)?=\s*script((?:\.Parent)+)\s*(?:;|$)")
_PLAYERSCRIPTS_VAR = re.compile(r"\blocal\s+(\w+)\s*(?::[^=\n]+)?=\s*[^\n]*\bPlayerScripts[\"']?\s*\)?\s*(?:;|$)")
_ASSIGN = re.compile(r"^\s*local\s+(\w+)\s*(?::[^=\n]+)?=")
_LOOKUP = re.compile(
    r"(?P<base>game:GetService\(\s*[\"']\w+[\"']\s*\)|game\.\w+|script(?:\.Parent)+|\b[A-Za-z_]\w*)"
    r"(?:\s*:\s*(?:WaitForChild|FindFirstChild)\(\s*[\"'](?P<call>\w+)[\"']|\.(?P<dot>[A-Z]\w*))")
_SERVICE_ROOTS = {"ServerScriptService", "ReplicatedStorage", "ServerStorage", "Workspace", "StarterGui",
                  "ReplicatedFirst", "StarterPlayer", "StarterPlayerScripts"}
REQUIRE_WINDOW = 6


def _service_root(name: str) -> str | None:
    if name == "workspace":
        return "Workspace"
    return name if name in _SERVICE_ROOTS else None


def _parent_dir(here: str, ups: int) -> str | None:
    parts = here.split("/") if here else []
    if ups - 1 > len(parts):
        return None
    keep = parts[: len(parts) - (ups - 1)]
    return "/".join(keep) if keep else None


def _container(base: str, aliases: dict[str, str], here: str) -> str | None:
    m = re.match(r"game:GetService\(\s*[\"'](\w+)", base)
    if m:
        return _service_root(m.group(1))
    if base.startswith("game."):
        return _service_root(base[5:])
    if base.startswith("script"):
        return _parent_dir(here, base.count(".Parent"))
    if base == "workspace":
        return "Workspace"
    return aliases.get(base)


def _normalize(target: str) -> str:
    return target.replace("StarterPlayer/StarterPlayerScripts", "StarterPlayerScripts")


def module_refs(rel: str, text: str) -> list[dict]:
    """Where a file looks up a module it requires: [{file, line, target, text}], target = "<folder>/<Name>" in
    the game tree (ServerScriptService:WaitForChild("Progress") -> ServerScriptService/Progress). Resolves
    GetService locals, script.Parent chains and their locals, PlayerScripts locals and one level of folder
    locals; a lookup counts when its line requires, or the local it is assigned to is required within
    REQUIRE_WINDOW lines. Comments are ignored."""
    from forge.compare import strip_comments

    lines = strip_comments(text).split("\n")
    here = folder_of(rel)
    aliases: dict[str, str] = {}
    out = []
    for i, line in enumerate(lines):
        for m in _SERVICE_VAR.finditer(line):
            root = _service_root(m.group(2))
            if root:
                aliases[m.group(1)] = root
        m = _PARENT_VAR.search(line)
        if m:
            target = _parent_dir(here, m.group(2).count(".Parent"))
            if target:
                aliases[m.group(1)] = target
        m = _PLAYERSCRIPTS_VAR.search(line)
        if m:
            aliases[m.group(1)] = "StarterPlayerScripts"
        for lk in _LOOKUP.finditer(line):
            name = lk.group("call") or lk.group("dot")
            if not name or name == "Parent":
                continue
            container = _container(lk.group("base"), aliases, here)
            if container is None:
                continue
            target = _normalize(f"{container}/{name}")
            assigned = _ASSIGN.match(line)
            if assigned and "require" not in line and lk.end() >= len(line.rstrip()) - 8:
                aliases.setdefault(assigned.group(1), target)  # `local kit = RS:WaitForChild("Kit", 10)`
            used = "require" in line or bool(assigned and any(
                "require" in later and re.search(rf"\b{re.escape(assigned.group(1))}\b", later)
                for later in lines[i + 1: i + 1 + REQUIRE_WINDOW]))
            if used:
                out.append({"file": rel, "line": i + 1, "target": target, "text": line.strip()[:160]})
    return out


def tree_index(paths: list[str]) -> set[str]:
    """Every instance path the synced files make: '<folder>/<Name>' per file plus every folder."""
    out: set[str] = set()
    for rel in paths:
        folder = folder_of(rel)
        out.add(_normalize(f"{folder}/{instance_name(rel)}" if folder else instance_name(rel)))
        parts = folder.split("/") if folder else []
        for k in range(1, len(parts) + 1):
            out.add("/".join(parts[:k]))
    return out


def resolves(target: str, index: set[str]) -> bool:
    if target in index or target.split("/", 1)[0] == target:
        return True
    return target.startswith("StarterPlayerScripts/") and target.rsplit("/", 1)[-1] in ROBLOX_CHILDREN


def dangling(game_dir: Path, protected: set[str]) -> list[dict]:
    """Module lookups in the game's own files whose target is not in the tree (a removed or moved module)."""
    files = game_files(game_dir)
    index = tree_index(files)
    out = []
    for rel in files:
        if is_protected(rel, protected):
            continue
        text = (Path(game_dir) / rel).read_text(encoding="utf-8", errors="replace")
        out += [r for r in module_refs(rel, text) if not resolves(r["target"], index)]
    return out


def _ref_key(r: dict) -> tuple[str, str, str]:
    return r["file"], r["target"], r["text"]


# ------------------------------------------------------------------------------- module map

_REMOTE_NEW = re.compile(r"Instance\.new\(\s*\"(?:RemoteEvent|RemoteFunction|UnreliableRemoteEvent)\"")
_NAME_SET = re.compile(r"\.Name\s*=\s*\"(\w+)\"")
_REMOTE_LITERAL = re.compile(r"(?i)\b\w*remote\w*\s*(?::[^=\n]+)?=\s*[^\n]*?\"(\w+)\"")
_FIRES = re.compile(r":(FireServer|FireClient|FireAllClients|InvokeServer|InvokeClient)\(")
_HANDLES = re.compile(r"\.(OnServerEvent|OnClientEvent|OnServerInvoke|OnClientInvoke)\b")
_COUNTER = re.compile(r"\bcount\(\s*\"(\w+)\"")
_PUBLIC_FN = re.compile(r"^\s*function\s+(\w+)[.:](\w+)\s*\(|^\s*(\w+)\.(\w+)\s*=\s*function\b", re.M)


_NOT_REMOTE_NAMES = {"RemoteEvent", "RemoteFunction", "UnreliableRemoteEvent", "BindableEvent", "BindableFunction",
                     "Remotes", "Folder"}


def remote_names(text: str) -> list[str]:
    lines = text.splitlines()
    names: list[str] = []
    for i, line in enumerate(lines):
        if _REMOTE_NEW.search(line):
            names += [m.group(1) for ln in lines[i: i + 7] for m in _NAME_SET.finditer(ln)]
        names += [m.group(1) for m in _REMOTE_LITERAL.finditer(line)]
    return [n for n in dict.fromkeys(names) if n not in _NOT_REMOTE_NAMES]


def _head(text: str) -> str:
    for ln in text.splitlines()[:6]:
        s = ln.strip()
        if s.startswith("--") and not s.startswith("--!"):
            return s.lstrip("-").strip()[:140]
    return ""


def module_map(game_dir: Path, protected: set[str]) -> list[dict]:
    """One row per file the plan may change (everything but the protected files), with its references
    resolved against the whole tree."""
    game_dir = Path(game_dir)
    files = game_files(game_dir)
    by_target = {_normalize(f"{folder_of(p)}/{instance_name(p)}"): p for p in files}
    texts = {p: (game_dir / p).read_text(encoding="utf-8", errors="replace") for p in files}
    rows: dict[str, dict] = {}
    required_by: dict[str, set[str]] = {}
    for rel in files:
        if is_protected(rel, protected):
            continue
        text = texts[rel]
        requires = sorted({by_target[r["target"]] for r in module_refs(rel, text)
                           if r["target"] in by_target and by_target[r["target"]] != rel})
        for dep in requires:
            required_by.setdefault(dep, set()).add(rel)
        rows[rel] = {"path": rel, "kind": kind_of(rel), "side": side_of(rel), "lines": len(text.splitlines()),
                     "chars": len(text), "head": _head(text), "requires": requires,
                     "remotes": {"creates": remote_names(text) if _REMOTE_NEW.search(text) else [],
                                 "fires": sorted({m.group(1) for m in _FIRES.finditer(text)}),
                                 "handles": sorted({m.group(1) for m in _HANDLES.finditer(text)})},
                     "counters": sorted(set(_COUNTER.findall(text))),
                     "functions": sorted({f"{a or c}.{b or d}" for a, b, c, d in _PUBLIC_FN.findall(text)})[:24]}
    for rel, row in rows.items():
        row["required_by"] = sorted(required_by.get(rel, set()) - {rel})
        # a module nothing requires and no file even names (a dynamic require names it in quotes) never runs
        literal = f'"{instance_name(rel)}"'
        row["unused"] = (row["kind"] == "ModuleScript" and not row["required_by"]
                         and not any(literal in t for p, t in texts.items() if p != rel))
    return [rows[p] for p in sorted(rows)]


def _short(rel: str) -> str:
    return rel.replace("ServerScriptService/", "SSS/").replace("StarterPlayerScripts/", "SPS/").replace(
        "ReplicatedStorage/", "RS/")


def map_text(rows: list[dict], limit: int = MAP_CHARS) -> str:
    from forge.roles import _truncate

    out = ["(SSS = ServerScriptService, SPS = StarterPlayerScripts, RS = ReplicatedStorage)"]
    for r in rows:
        line = f"- {r['path']} ({r['kind']}, {r['lines']} lines, {r['chars']} chars)" + (
            f" -- {r['head']}" if r["head"] else "")
        bits = []
        if r["requires"]:
            bits.append("requires " + ", ".join(map(_short, r["requires"])))
        if r["required_by"]:
            bits.append("required by " + ", ".join(map(_short, r["required_by"])))
        elif r.get("unused"):
            bits.append("NOTHING requires or names it: it never runs")
        rem = r["remotes"]
        if rem["creates"]:
            bits.append("creates remotes " + ", ".join(rem["creates"]))
        if rem["fires"] or rem["handles"]:
            bits.append("uses " + ", ".join(rem["fires"] + rem["handles"]))
        if r["counters"]:
            bits.append("counters " + ", ".join(r["counters"][:8]) + (" ..." if len(r["counters"]) > 8 else ""))
        out.append(line + ("\n    " + "; ".join(bits) if bits else ""))
    return _truncate("\n".join(out), limit, label="module map")


# ------------------------------------------------------------------------------- the architect's message


def spec_text(spec: dict) -> str:
    feats = [str(f.get("request") or "")[:130] for f in spec.get("features") or [] if isinstance(f, dict)]
    lines = [f"title: {spec.get('title', '')}", f"pitch: {spec.get('pitch', '')}",
             f"core loop: {str(spec.get('core_loop', ''))[:400]}"]
    if feats:
        lines.append("features built one at a time:\n" + "\n".join(f"- {f}" for f in feats[-12:]))
    return "\n".join(lines)


def gaps_text(report: dict) -> str:
    arch = next((c for c in report.get("categories") or [] if c.get("id") == "architecture"), None)
    if not arch:
        return "(no comparison)"
    lines = [f"Architecture {arch.get('score')}/10 against the reference (overall {report.get('overall')}/10)."]
    for m in arch.get("metrics") or []:
        if m.get("score") is not None and m["score"] < 0.999:
            lines.append(f"- {m['label']}: this game {m['game']}; reference {m['reference']}")
    for g in arch.get("gaps") or []:
        lines.append(f"- gap: {g['text']}" + (f" Reference: {g['pointer']}." if g.get("pointer") else ""))
    return "\n".join(lines)


def prebuilt_text(spec: dict, game_dir: Path, protected: set[str]) -> str:
    from forge import director

    lines = [f"- {e['path_in_game']}: kit module {e['name']}, {e['describe'][:220]}"
             for e in director.kit_modules_in(spec)]
    if (Path(game_dir) / director.GAME_ASSETS).exists():
        lines.append(f"- {director.GAME_ASSETS}: the art kit (palette, sounds, GameAssets.play/burst/shake/part)")
    levels = sorted((Path(game_dir) / "ReplicatedStorage" / "Levels").glob("*.luau"))
    if levels:
        lines.append(f"- ReplicatedStorage/Levels/ ({len(levels)} level data modules written by `forge levels`)")
    lines.append("- Forge runtime: ReplicatedStorage/ForgeTelemetry.luau (count(name, n) on the server AND the "
                 "client), ServerScriptService/ForgeProbe.server.luau, ServerScriptService/ForgeTest.server.luau, "
                 "StarterPlayerScripts/ForgeTestAgent.client.luau")
    shown = {e["path_in_game"] for e in director.kit_modules_in(spec)} | {director.GAME_ASSETS}
    other = sorted(p for p in protected if p not in shown and not p.startswith(PROTECTED_PREFIXES)
                   and "Forge" not in p.rsplit("/", 1)[-1] and (Path(game_dir) / p).exists())
    if other:
        lines.append("- also prebuilt or human-owned: " + ", ".join(other[:30]))
    return "\n".join(lines)


def limits_text(max_merges: int, game_dir: Path, protected: set[str]) -> str:
    boots = []
    for boot, what in ((SERVER_BOOT, "server"), (CLIENT_BOOT, "client")):
        if boot in protected:
            boots.append(f"{boot} is already Forge's {what} bootstrap: add {what} modules to its folder.")
        elif (Path(game_dir) / boot).exists():
            boots.append(f"{boot} exists and is NOT a bootstrap: fold it into a "
                         f"{'service' if what == 'server' else 'controller'} if this pass boots any.")
    return "\n".join([
        f"- At most {max_merges} new files in this pass (merges and scripts folded into a bootstrap, together).",
        f"- One merge or fold reads its originals in full: at most {MERGE_SOURCE_CHARS} chars of originals per "
        "entry (the map gives each file's chars). Split a bigger group, or leave it.",
        f"- At most {MAX_REWIRES} rewired files.",
        *(f"- {b}" for b in boots),
    ])


def last_pass_text(out_dir: Path) -> str:
    """The previous pass, when it was rolled back: what it tried and why the gate refused it (a correction
    for this call, in the same Mubit task)."""
    recs = sorted((p for p in out_dir.glob("*.json") if p.stem.isdigit()), key=lambda p: int(p.stem))
    for p in reversed(recs):
        rec = _read(p) or {}
        if rec.get("plan_only"):
            continue
        if rec.get("outcome") != "rolled_back":
            return ""
        plan = rec.get("plan") or {}
        lines = [f"## The last consolidation pass was rolled back\nIt planned: {plan.get('summary', '')}"]
        lines += [f"- {u['kind']}: {', '.join(u['from'])} -> {u['into']}" for u in plan.get("units") or []][:8]
        lines.append("The gate refused it because:")
        lines += [f"- {f}" for f in (rec.get("why") or [])[:8]]
        lines.append("Plan a pass that avoids these failures (smaller, or different groups).")
        return "\n".join(lines)[:2500]
    return ""


def plan_message(spec: dict, rows: list[dict], report: dict, prebuilt: str, limits: str, last: str = "") -> str:
    from forge.roles import _fit

    parts = ["## Game\n" + spec_text(spec), "## Module map\n" + map_text(rows),
             "## Architecture gaps\n" + gaps_text(report), "## Prebuilt\n" + prebuilt, "## Limits\n" + limits]
    if last:
        parts.append(last)
    parts.append("Return only the plan JSON object.")
    return _fit("\n\n".join(parts))


# ------------------------------------------------------------------------------- plan validation


def _str(v: Any) -> str:
    return str(v or "").strip()


def _paths(v: Any) -> list[str]:
    items = v if isinstance(v, list) else [v] if isinstance(v, str) else []
    return list(dict.fromkeys(_str(p).lstrip("/") for p in items if _str(p)))


def validate(raw: dict, game_dir: Path, protected: set[str], rows: list[dict],
             max_merges: int = MAX_MERGES) -> tuple[dict, list[str]]:
    """Keep only what can be built safely; every refusal is a problem line the architect can act on."""
    game_dir = Path(game_dir)
    by_path = {r["path"]: r for r in rows}
    problems: list[str] = []
    taken: set[str] = set()
    intos: set[str] = set()
    units: list[dict] = []

    def source_problem(p: str) -> str | None:
        if is_protected(p, protected) or (game_dir / p).exists() and p not in by_path:
            return f"{p} is prebuilt (kit, level data, art kit, Forge runtime or a bootstrap): never merge, move or delete it"
        if p not in by_path:
            return f"{p} is not a file of this game"
        if p in taken:
            return f"{p} is already used by another entry: each file goes to one place"
        return None

    def into_problem(into: str, sources: list[str]) -> str | None:
        if not _valid_path(into):
            return f"{into!r} is not a valid game path (ServerScriptService/, StarterPlayerScripts/ or ReplicatedStorage/, .luau)"
        if into in (SERVER_BOOT, CLIENT_BOOT):
            return f"{into} is the bootstrap path: Forge installs it; target a service or controller instead"
        if is_protected(into, protected):
            return f"{into} is prebuilt: never write it"
        if into in intos:
            return f"{into} is the target of two entries"
        if (game_dir / into).exists() and into not in sources:
            return f"{into} already exists and is not one of the files merged into it"
        sides = {side_of(p) for p in sources} | {side_of(into)}
        if len(sides) > 1:
            return f"{into}: merges server, client and shared code together ({', '.join(sorted(sides))}); keep one side"
        if into.endswith((".server.luau", ".client.luau")) and booted(into) is None and len(sources) > 1:
            return f"{into}: merge modules into a ModuleScript, a service or a controller, not a new Script"
        return None

    def add(kind: str, into: str, sources: list[str], purpose: str, why: str) -> None:
        bad = [s for p in sources if (s := source_problem(p))]
        if bad:
            problems.extend(bad)
            return
        if kind == "merge" and len(sources) < 2 and booted(into) is None:
            problems.append(f"merge into {into}: a merge needs two or more files (or a service/controller path)")
            return
        if (bad_into := into_problem(into, sources)) is not None:
            problems.append(bad_into)
            return
        size = sum(by_path[p]["chars"] for p in sources)
        if size > MERGE_SOURCE_CHARS:
            problems.append(f"{into}: its originals are {size} chars, over the {MERGE_SOURCE_CHARS}-char budget of "
                            "one merge; split the group or leave it")
            return
        if len(units) >= max_merges:
            problems.append(f"{into}: over the limit of {max_merges} new files in one pass (dropped)")
            return
        taken.update(sources)
        intos.add(into)
        units.append({"kind": booted(into) or kind, "into": into, "from": sources, "purpose": purpose[:900],
                      "why": why[:400]})

    for e in raw.get("merges") or []:
        if isinstance(e, dict):
            add("merge", _str(e.get("into")).lstrip("/"), _paths(e.get("from")), _str(e.get("purpose")),
                _str(e.get("why")))
    for key, script, folder in (("server_bootstrap", ".server.luau", SERVICES),
                                ("client_bootstrap", ".client.luau", CONTROLLERS)):
        for e in raw.get(key) or []:
            if not isinstance(e, dict):
                continue
            src, into = _paths(e.get("from"))[:1], _str(e.get("into")).lstrip("/")
            if not src or not src[0].endswith(script):
                problems.append(f"{key}: {src[0] if src else '(no file)'} is not a {script} script to fold")
                continue
            if booted(into) is None or not into.startswith(folder):
                problems.append(f"{key}: {into!r} must be {folder}<Name>{'Service' if script == '.server.luau' else 'Controller'}.luau")
                continue
            add("fold", into, src, _str(e.get("purpose")), "")

    deletes: list[dict] = []
    for e in raw.get("delete") or []:
        p = _str((e or {}).get("path") if isinstance(e, dict) else e).lstrip("/")
        if not p:
            continue
        bad = source_problem(p)
        if bad:
            problems.append(f"delete: {bad}")
            continue
        taken.add(p)
        deletes.append({"path": p, "why": _str(e.get("why") if isinstance(e, dict) else "")[:300]})

    rewires: dict[str, str] = {}
    for e in raw.get("rewire") or []:
        if not isinstance(e, dict):
            continue
        p, change = _str(e.get("path")).lstrip("/"), _str(e.get("change"))
        if p in taken:
            continue  # merged, folded or deleted: the unit that owns it rewrites it
        if p not in by_path:
            problems.append(f"rewire: {p} is not a file this pass may change")
            continue
        rewires[p] = (rewires[p] + "; " + change) if p in rewires else change

    # every remaining file that requires a removed module needs a rewire (no dangling requires)
    moved = {p: u["into"] for u in units for p in u["from"] if p != u["into"]}
    removed = set(moved) | {d["path"] for d in deletes}
    auto = []
    for p in sorted(removed):
        for caller in by_path[p]["required_by"]:
            if caller in taken or caller in rewires:
                continue
            where = f"merged into {moved[p]}" if p in moved else "deleted"
            rewires[caller] = f"it requires {p}, which this pass {where}: " + (
                f"require {moved[p]} instead and call the same functions" if p in moved else "remove that use")
            auto.append(caller)
    if len(rewires) > MAX_REWIRES:
        problems.append(f"{len(rewires)} files need rewiring, over the limit of {MAX_REWIRES}: plan a smaller pass")
    # a deleted file's remote is gone: whoever still names it must be rewired
    texts: dict[str, str] = {}
    for d in deletes:
        for name in by_path[d["path"]]["remotes"]["creates"]:
            for rel in by_path:
                if rel in taken or rel in rewires:
                    continue
                text = texts.setdefault(rel, (game_dir / rel).read_text(encoding="utf-8", errors="replace"))
                if f'"{name}"' in text:
                    problems.append(f"{rel} names the remote {name} that {d['path']} creates, and this plan deletes "
                                    f"{d['path']}: rewire {rel} (or the client code that fires {name}) to count with "
                                    "ForgeTelemetry.count directly, or keep the file")
    sides = {u["kind"] for u in units}
    for boot, kind, side in ((SERVER_BOOT, "service", "server"), (CLIENT_BOOT, "controller", "client")):
        if kind in sides and boot not in protected and (game_dir / boot).exists() and boot not in taken:
            problems.append(f"{boot} exists and is not a bootstrap: fold it into a {kind} too, or boot no {side} "
                            f"{kind}s in this pass ({kind} entries dropped)")
            for u in [u for u in units if u["kind"] == kind]:
                units.remove(u)
                taken.difference_update(u["from"])
    plan = {"summary": _str(raw.get("summary"))[:300], "units": units, "delete": deletes,
            "rewire": [{"path": p, "change": c[:600]} for p, c in rewires.items()], "auto_rewire": auto}
    return plan, list(dict.fromkeys(problems))


def is_empty(plan: dict) -> bool:
    return not (plan.get("units") or plan.get("delete"))


def render_plan(plan: dict, problems: list[str]) -> str:
    lines = [f"[architect] {plan.get('summary') or '(no summary)'}"]
    for u in plan.get("units") or []:
        lines.append(f"  {u['kind']:<10} {' + '.join(u['from'])} -> {u['into']}" + (f"  ({u['why']})" if u["why"] else ""))
    for d in plan.get("delete") or []:
        lines.append(f"  {'delete':<10} {d['path']}" + (f"  ({d['why']})" if d["why"] else ""))
    for r in plan.get("rewire") or []:
        auto = " [added: requires a removed module]" if r["path"] in (plan.get("auto_rewire") or []) else ""
        lines.append(f"  {'rewire':<10} {r['path']}: {r['change'][:160]}{auto}")
    if problems:
        lines.append("  problems:")
        lines += [f"    - {p[:220]}" for p in problems]
    return "\n".join(lines)


async def make_plan(run: Any, spec: dict, rows: list[dict], report: dict, *, protected: set[str],
                    max_merges: int, session: str, last: str = "", log: Callable[[str], None] = print
                    ) -> tuple[dict, list[str], list[str | None]]:
    """The architect's plan, validated; one correction call (same Mubit task) when it had problems."""
    game_dir = run.game_dir
    user = plan_message(spec, rows, report, prebuilt_text(spec, game_dir, protected),
                        limits_text(max_merges, game_dir, protected), last)

    def ask(llm, msg):
        return llm.complete_json(ROLE, msg, session_id=session, required=PLAN_KEYS, max_tokens=PLAN_MAX_TOKENS)[0]

    raw = await run.call(ROLE, "consolidation plan", ask, user)
    ids = [run.last_request_id]
    plan, problems = validate(raw, game_dir, protected, rows, max_merges)
    if problems:
        log(render_plan(plan, problems))
        from forge.roles import _truncate
        retry = (f"{user}\n\n## Your previous plan had problems\n" + "\n".join(f"- {p}" for p in problems)
                 + "\n\nPrevious plan:\n" + _truncate(json.dumps(raw, ensure_ascii=False), 5000, label="plan")
                 + "\n\nReturn only the corrected plan JSON object.")
        raw = await run.call(ROLE, "consolidation plan (correction)", ask, retry)
        ids.append(run.last_request_id)
        plan, problems = validate(raw, game_dir, protected, rows, max_merges)
    return plan, problems, ids


# ------------------------------------------------------------------------------- execution

BOOT_RULES = {
    "service": (
        "## How this file boots (ServerScriptService/Main.server.luau is prebuilt; copy this shape)\n"
        "- A ModuleScript directly under ServerScriptService/Services named <Name>Service; it returns one table.\n"
        "- Top level: only GetService calls, requires, constants and local state. No yields, no Instances, no "
        "connections there.\n"
        "- `function <Name>Service:Init(services)`: keep `services` (name -> every other service's table); no "
        "calls into other services, no yields.\n"
        "- `function <Name>Service:Start()`: everything the originals did when they started (build, create "
        "remotes, connect events, loops), in the same order. It runs on its own thread after every Init. Set "
        "`<Name>Service.BlocksBoot = true` only if later services need what Start builds before they start.\n"
        "- `script` is now this ModuleScript inside the Services folder: `script.Parent` is "
        "ServerScriptService.Services, so an original's `script.Parent` lookup must become `ServerScriptService` "
        "(or `script.Parent.Parent`).\n"),
    "controller": (
        "## How this file boots (StarterPlayerScripts/Main.client.luau is prebuilt; copy this shape)\n"
        "- A ModuleScript directly under StarterPlayerScripts/Controllers named <Name>Controller; it returns one "
        "table.\n"
        "- Top level: only GetService calls, requires, constants and local state. No yields, no Instances, no "
        "connections there.\n"
        "- `function <Name>Controller:Init(controllers)`: keep `controllers`; no calls into others, no yields.\n"
        "- `function <Name>Controller:Start()`: everything the originals did when they started (build the UI, "
        "connect events, loops), in the same order. It runs on its own thread after every Init.\n"
        "- `script` is now this ModuleScript inside the Controllers folder: `script.Parent` is the Controllers "
        "folder, so an original's `script.Parent:WaitForChild(\"X\")` for a module beside it in "
        "StarterPlayerScripts must become `script.Parent.Parent:WaitForChild(\"X\")`.\n"),
}


def moves_text(plan: dict) -> str:
    lines = ["## Every change in this pass (require the new paths; other files are rewired the same way)"]
    for u in plan.get("units") or []:
        what = {"service": "a service the server bootstrap boots", "controller": "a controller the client "
                "bootstrap boots"}.get(u["kind"], "a module")
        lines.append(f"- {', '.join(u['from'])} -> {u['into']} ({what})")
    lines += [f"- deleted: {d['path']}" + (f" ({d['why']})" if d["why"] else "") for d in plan.get("delete") or []]
    lines.append("- A service or controller is booted by its bootstrap: never call its Init/Start or setup yourself; "
                 "other code may still require it and call its functions.")
    return "\n".join(lines) + "\n"


def callers_text(unit: dict, rows_by: dict[str, dict], texts: dict[str, str], taken: set[str]) -> str:
    """Call sites of the unit's originals in files that stay, so the merged module keeps that API."""
    out = []
    for src in unit["from"]:
        name = instance_name(src)
        for caller in rows_by.get(src, {}).get("required_by") or []:
            if caller in unit["from"]:
                continue
            lines = texts[caller].splitlines()
            hits = [i for i, ln in enumerate(lines) if re.search(rf"\b{re.escape(name)}\b", ln)]
            # the lines before a require show how the caller found what it hands over (a remote, a gui)
            keep = sorted({j for i in hits for j in range(max(0, i - 6), min(len(lines), i + 5))})[:40]
            moved = " (moves in this pass too)" if caller in taken else ""
            out.append(f"### {caller} uses {name}{moved}\n" + "\n".join(f"{j + 1:>5}| {lines[j]}" for j in keep))
    if not out:
        return ""
    from forge.roles import _truncate
    return _truncate("## Callers that stay (keep the functions they call: same names, arguments, results)\n"
                     + "\n".join(out), CALLERS_CHARS, label="callers") + "\n"


def unit_message(spec: dict, plan: dict, unit: dict, texts: dict[str, str], rows_by: dict[str, dict],
                 taken: set[str]) -> str:
    from forge import director
    from forge.roles import CLIENT_TELEMETRY_NOTE, _clip_block, _truncate

    src_text = "\n".join(texts[p] for p in unit["from"])
    kit = director.kit_api_block(spec)
    kit = _truncate(kit, 1800, label="kit API") + "\n" if kit and re.search(r"\bKit\b", src_text) else ""
    functions = sorted({f for p in unit["from"] for f in rows_by.get(p, {}).get("functions") or []})
    head = (
        "## Consolidation: write ONE file that replaces existing ones (forge consolidate)\n"
        f"path: {unit['into']}\n"
        f"purpose: {unit['purpose'] or '(the originals together)'}\n"
        + (f"why: {unit['why']}\n" if unit["why"] else "")
        + f"replaces: {', '.join(unit['from'])} (deleted once this file is written)\n"
        + (f"their public functions: {', '.join(functions)}\n" if functions else "")
        + "\n## Rules\n"
        "- The same behaviour as the originals together: every remote name that stays, attribute, tag, sound, "
        "number, timing and telemetry counter is kept.\n"
        "- Where the originals do the same thing twice (two banners, two flashes for one death, two remotes for "
        "one job), keep it once.\n"
        "- Require kit modules, GameAssets, Config modules and ForgeTelemetry as the originals do; never copy "
        "their code.\n"
        "- Keep each original's pcall/nil guards: a failure in one part must never stop the others.\n\n"
        + BOOT_RULES.get(unit["kind"], "")
        + moves_text(plan)
        + callers_text(unit, rows_by, texts, taken)
        + CLIENT_TELEMETRY_NOTE
        + kit
    )
    body = "\n## Originals (full source)\n" + "\n".join(
        f"### {p} ({len(texts[p].splitlines())} lines)\n```luau\n{_clip_block(texts[p])}\n```" for p in unit["from"])
    tail = f"\nWrite the complete file {unit['into']} in one ```luau block."
    return _truncate(head, 7000, label="instructions") + body + tail


def _mentions(text: str, rel: str, remotes: list[str] = ()) -> bool:
    names = [rel, instance_name(rel), *remotes]
    return any(re.search(rf"(?<![\w/]){re.escape(n)}(?![\w])", text) for n in names if n)


def _relevant(plan: dict, rel: str, change: str, texts: dict[str, str], rows_by: dict[str, dict]
              ) -> tuple[list[dict], list[dict]]:
    """The units and deletes this file's rewire is about: named in the change, or named in the file itself."""
    text = change + "\n" + texts.get(rel, "")
    units = [u for u in plan.get("units") or [] if _mentions(text, u["into"])
             or any(_mentions(text, p) for p in u["from"])]
    dels = [d for d in plan.get("delete") or []
            if _mentions(text, d["path"], (rows_by.get(d["path"]) or {}).get("remotes", {}).get("creates") or [])]
    return units, dels


def rewire_problem(plan: dict, rel: str, change: str, texts: dict[str, str], rows_by: dict[str, dict]) -> str:
    units, dels = _relevant(plan, rel, change, texts, rows_by)
    moves = [f"- {', '.join(u['from'])} -> {u['into']}"
             + (" (booted by its bootstrap: never call its Init/Start or setup)" if u["kind"] in ("service", "controller")
                else "") for u in units]
    moves += [f"- deleted: {d['path']}" + (f" ({d['why']})" if d["why"] else "") for d in dels]
    return ("Consolidation (forge consolidate) moved or removed modules this file uses:\n"
            + ("\n".join(moves) or "- (see the change)")
            + f"\n\nChange needed in this file: {change}\n"
            "Where this file required an old module, require its new path the same way (a module in "
            "ServerScriptService/Services is ServerScriptService:WaitForChild(\"Services\"):WaitForChild(\"<Name>\"); "
            "one in StarterPlayerScripts/Controllers is <PlayerScripts>:WaitForChild(\"Controllers\"):WaitForChild"
            "(\"<Name>\")) and call the same functions. Keep every counter name, remote name and behaviour. Change "
            "nothing else.")


def rewire_context(plan: dict, rel: str, change: str, texts: dict[str, str], rows_by: dict[str, dict],
                   after: dict[str, str]) -> str:
    """The new modules' API and what each deleted file did (its code, comments stripped), so a rewire keeps
    the same counter and remote names."""
    from forge.compare import strip_comments
    from forge.roles import api_summary

    units, dels = _relevant(plan, rel, change, texts, rows_by)
    parts = [f"API of {u['into']}:\n{api_summary(after.get(u['into'], ''), 1200)}" for u in units]
    for d in dels:
        code = "\n".join(ln for ln in strip_comments(texts.get(d["path"], "")).splitlines() if ln.strip())
        parts.append(f"The deleted {d['path']} did this:\n{code[:1500]}")
    return "\n\n".join(parts)


async def _rewrite(run: Any, rel: str, problem: str, session: str, context: str = "") -> str | None:
    """Patcher (big files) or fixer (+ the destructive guard) for one existing file -> error or None."""
    from forge import roles
    from forge.improve import destructive
    from forge.patch import PATCH_ABOVE_LINES

    old = run.read(rel)
    big = len(old.splitlines()) > PATCH_ABOVE_LINES
    fn = roles.patch_file if big else roles.fix_file
    try:
        new = await run.call("patcher" if big else "fixer", f"{rel} (consolidate)", fn, rel, old, problem,
                             context or run.spec.get("pitch", ""), "", session_id=session)
    except Exception as e:  # noqa: BLE001 - reported on the record; the gate then fails this pass
        return f"{type(e).__name__}: {str(e)[:200]}"
    why = destructive(old, new)
    if why:
        return why
    run.write(rel, new)
    return None


async def execute(run: Any, plan: dict, rows: list[dict], *, protected: set[str], session: str,
                  log: Callable[[str], None] = print) -> dict:
    """Write every unit, delete, install bootstraps, rewire, compile, fix new dangling requires.
    -> {units, deleted, bootstraps, rewired, compile_errors, dangling, failed: [why]}"""
    from forge import roles

    game_dir = run.game_dir
    rows_by = {r["path"]: r for r in rows}
    texts = {p: run.read(p) for p in rows_by}
    taken = {p for u in plan["units"] for p in u["from"]} | {d["path"] for d in plan["delete"]}
    before_refs = {_ref_key(r) for r in dangling(game_dir, protected)}
    rec: dict = {"units": [], "deleted": [], "bootstraps": [], "rewired": [], "compile_errors": [], "dangling": [],
                 "fixes": {"fixes": [], "steps": []}, "failed": []}

    def code(llm, user):
        return roles._complete_luau(llm, "coder", user, session_id=session)

    async def one(unit: dict) -> None:
        r = {"into": unit["into"], "from": unit["from"], "kind": unit["kind"]}
        rec["units"].append(r)
        try:
            src = await run.call("coder", f"{unit['into']} (consolidate)", code,
                                 unit_message(run.spec, plan, unit, texts, rows_by, taken))
        except Exception as e:  # noqa: BLE001
            r["error"] = f"{type(e).__name__}: {str(e)[:200]}"
            return
        run.write(unit["into"], src)
        r["request_id"] = run.last_request_id
        err = await asyncio.to_thread(run.check_file, unit["into"])
        if err:
            err = await run.fix_compile_file(unit["into"], err, rec=rec["fixes"], session_id=session)
        r["lines"] = len(run.read(unit["into"]).splitlines())
        if err:
            r["error"] = f"does not compile: {err[:300]}"

    await asyncio.gather(*(one(u) for u in plan["units"]))
    rec["failed"] += [f"{u['into']}: {u['error']}" for u in rec["units"] if u.get("error")]
    if rec["failed"]:
        return rec

    for u in plan["units"]:
        for p in u["from"]:
            if p != u["into"]:
                (game_dir / p).unlink(missing_ok=True)
                rec["deleted"].append(p)
    for d in plan["delete"]:
        (game_dir / d["path"]).unlink(missing_ok=True)
        rec["deleted"].append(d["path"])
    kinds = {u["kind"] for u in plan["units"]}
    for boot, kind in ((SERVER_BOOT, "service"), (CLIENT_BOOT, "controller")):
        if kind in kinds and boot not in protected:
            run.write(boot, (BOOT_DIR / boot.rsplit("/", 1)[-1]).read_text(encoding="utf-8"))
            rec["bootstraps"].append(boot)

    after = {u["into"]: run.read(u["into"]) for u in plan["units"]}

    async def rewire(item: dict) -> None:
        rel, change = item["path"], item["change"]
        if not (game_dir / rel).exists():
            return
        err = await _rewrite(run, rel, rewire_problem(plan, rel, change, texts, rows_by), session,
                             rewire_context(plan, rel, change, texts, rows_by, after))
        rec["rewired"].append({"path": rel, **({"error": err} if err else {})})

    await asyncio.gather(*(rewire(r) for r in plan["rewire"]))
    rec["failed"] += [f"rewire {r['path']}: {r['error']}" for r in rec["rewired"] if r.get("error")]
    if rec["failed"]:
        return rec

    touched = set(after) | {r["path"] for r in rec["rewired"]} | set(rec["bootstraps"])
    for attempt in range(2):
        remaining = [(p, m) for p, m in await run.compile_fix(rec["fixes"], only=touched) if p in touched]
        rec["compile_errors"] = [{"path": p, "error": m[:300]} for p, m in remaining]
        if remaining:
            rec["failed"].append("does not compile: " + ", ".join(p for p, _ in remaining))
            return rec
        new = [r for r in dangling(game_dir, protected) if _ref_key(r) not in before_refs]
        rec["dangling"] = new
        if not new or attempt:
            break
        index = sorted(tree_index(game_files(game_dir)))
        by_file: dict[str, list[dict]] = {}
        for r in new:
            by_file.setdefault(r["file"], []).append(r)
        log(f"[consolidate] {len(new)} lookups point at modules that are gone; fixing {', '.join(by_file)}")

        async def fix_refs(rel: str, refs: list[dict]) -> None:
            problem = ("These lines look up modules that no longer exist after the consolidation:\n"
                       + "\n".join(f"- line {r['line']}: {r['text']}  (looks for {r['target']})" for r in refs)
                       + "\n\nPoint each lookup at the module that exists now (the context lists them) and change "
                       "nothing else. A file in StarterPlayerScripts/Controllers reaches StarterPlayerScripts with "
                       "script.Parent.Parent; one in ServerScriptService/Services reaches ServerScriptService with "
                       "script.Parent.Parent.")
            context = (moves_text(plan) + "\nModules and folders that exist now: "
                       + ", ".join(p for p in index if p.split("/", 1)[0] in SIDES and "/Levels/" not in p))
            if is_protected(rel, protected):
                rec["failed"].append(f"{rel} (prebuilt) requires a removed module")
                return
            err = await _rewrite(run, rel, problem, session, context)
            touched.add(rel)
            if err:
                rec["failed"].append(f"fixing lookups in {rel}: {err}")

        await asyncio.gather(*(fix_refs(f, rs) for f, rs in by_file.items()))
        if rec["failed"]:
            return rec
    if rec["dangling"]:
        rec["failed"].append("lookups of removed modules left: " + "; ".join(
            f"{r['file']}:{r['line']} -> {r['target']}" for r in rec["dangling"][:6]))
    return rec


# ------------------------------------------------------------------------------- the gate


async def probe(studio: Any, *, seconds: float, log: Callable[[str], None] = print) -> dict:
    """One playtest: a player spawns, the game runs `seconds`, then ForgeProbe's server report and the client's
    own log (errors, warnings) are read. Play is always stopped."""
    from forge.scenarios import wait_for_player
    from forge.studio import extract_json

    out: dict = {"player": False, "server": {}, "client": {}}
    await studio.play()
    try:
        out["player"] = await wait_for_player(studio)
        await asyncio.sleep(seconds)
        rep = await studio.probe_report()
        out["server"] = {"errors": [str(e.get("message") if isinstance(e, dict) else e) for e in rep.get("errors") or []],
                         "warnings": [str(w) for w in rep.get("warnings") or []],
                         "counters": rep.get("counters") or {}, **({"error": rep["error"]} if rep.get("error") else {})}
        try:
            obj = extract_json(await studio.execute_luau(CLIENT_LOG_LUAU, "Client"))
            out["client"] = obj if isinstance(obj, dict) else {"error": "unreadable client log"}
        except Exception as e:  # noqa: BLE001 - no Client datamodel: the client side is unknown, not clean
            out["client"] = {"error": f"{type(e).__name__}: {str(e)[:200]}"}
    finally:
        try:
            await studio.stop()
        except Exception as e:  # noqa: BLE001
            log(f"[consolidate] could not stop play: {e}")
    return out


async def measure(studio: Any, game_dir: Path, checks: list, *, port: int, seconds: float,
                  log: Callable[[str], None] = print) -> dict:
    """Sync the game on disk, run the saved checks (no reviewer: a gate never rewrites a check), then probe."""
    from forge.scenarios import run_in_sessions

    synced = str(await studio.sync(game_dir, port) or "")
    if synced.startswith("ERROR"):
        raise RuntimeError(f"sync failed: {synced[:300]}")
    results = await run_in_sessions(studio, checks, log) if checks else {}
    return {"sync": synced[:160],
            "checks": {cid: {k: r.get(k) for k in ("ok", "detail", "error", "setup") if r.get(k) is not None}
                       for cid, r in results.items()},
            "probe": await probe(studio, seconds=seconds, log=log)}


def _messages(p: dict, side: str, kind: str) -> dict[str, str]:
    from forge.evidence import norm_error

    return {norm_error(m): m for m in (p.get(side) or {}).get(kind) or []}


def probe_findings(before: dict, after: dict, touched: set[str]) -> dict[str, str]:
    """{key: finding}: new errors on either side, new warnings naming a changed module (or the bootstrap), a
    counter that was > 0 and is gone, a player that no longer spawns."""
    out: dict[str, str] = {}
    for side in ("server", "client"):
        if (before.get(side) or {}).get("error") or (after.get(side) or {}).get("error"):
            continue  # that side could not be read in one run: unknown, not new errors
        b, a = _messages(before, side, "errors"), _messages(after, side, "errors")
        for k in sorted(a.keys() - b.keys()):
            out[f"{side}-error:{k}"] = f"new {side} error: {a[k][:300]}"
    bw = {**_messages(before, "server", "warnings"), **_messages(before, "client", "warnings")}
    aw = {**_messages(after, "server", "warnings"), **_messages(after, "client", "warnings")}
    names = {n for n in touched if len(n) >= 3}
    for k in sorted(aw.keys() - bw.keys()):
        if "[Boot]" in aw[k] or any(re.search(rf"\b{re.escape(n)}\b", aw[k]) for n in names):
            out[f"warning:{k}"] = f"new warning naming a changed module: {aw[k][:300]}"
    bc = (before.get("server") or {}).get("counters") or {}
    ac = (after.get("server") or {}).get("counters") or {}
    for k, v in sorted(bc.items()):
        if isinstance(v, (int, float)) and v > 0 and not ac.get(k):
            out[f"counter:{k}"] = f"counter {k} was {v:g} before and is {ac.get(k, 'absent')} now"
    if before.get("player") and not after.get("player"):
        out["player"] = "no player spawned in the playtest"
    return out


def check_findings(before: dict, after: dict) -> list[str]:
    """Checks that passed before and fail now (a check that could not set up proves nothing)."""
    from forge.checks import setup_failure

    out = []
    for cid, b in sorted(before.items()):
        a = after.get(cid)
        if b.get("ok") and a is not None and not a.get("ok") and not setup_failure(a):
            out.append(cid)
    return out


async def gate(studio: Any, game_dir: Path, checks: list, before: dict, touched: set[str], *, port: int,
               seconds: float, log: Callable[[str], None] = print) -> tuple[dict, list[str]]:
    """Measure the consolidated game; a check regression is rerun once and a probe finding needs a second probe
    to agree, so one flaky run neither keeps nor refuses a pass. -> (after, findings)"""
    from forge.scenarios import run_in_sessions

    after = await measure(studio, game_dir, checks, port=port, seconds=seconds, log=log)
    failing = check_findings(before["checks"], after["checks"])
    if failing:
        log(f"[consolidate] {len(failing)} check(s) passed before and fail now; running them once more: "
            + ", ".join(failing))
        again = await run_in_sessions(studio, [c for c in checks if c.id in failing], log)
        for cid in failing:
            after["checks"][cid]["rerun"] = {k: again.get(cid, {}).get(k) for k in ("ok", "detail", "error")}
        failing = [cid for cid in failing if not (again.get(cid) or {}).get("ok")]
    found = [f"check {cid} passed before and fails now: "
             f"{str(after['checks'][cid].get('error') or after['checks'][cid].get('detail') or '')[:200]}"
             for cid in failing]
    probe_found = probe_findings(before["probe"], after["probe"], touched)
    if probe_found:
        log("[consolidate] the probe saw: " + "; ".join(probe_found.values())[:400] + " -- probing once more")
        second = await probe(studio, seconds=seconds, log=log)
        after["probe2"] = second
        again = probe_findings(before["probe"], second, touched)
        probe_found = {k: v for k, v in probe_found.items() if k in again}
    return after, found + list(probe_found.values())


# ------------------------------------------------------------------------------- the pass


def _read(path: Path) -> Any:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _arch(report: dict) -> dict:
    cats = {c["id"]: c for c in report.get("categories") or []}
    arch = cats.get("architecture") or {}
    return {"overall": report.get("overall"), "architecture": arch.get("score"),
            "metrics": {m["id"]: m.get("score") for m in arch.get("metrics") or []}}


def update_spec(spec: dict, plan: dict, rec: dict) -> dict:
    """The spec lists modules by path; `forge run` rebuilds a listed module that is missing, so merged-away
    paths leave it and the new files join it."""
    gone = set(rec["deleted"])
    mods = [m for m in spec.get("modules") or [] if not (isinstance(m, dict) and m.get("path") in gone)]
    have = {m.get("path") for m in mods if isinstance(m, dict)}
    for u in plan["units"]:
        if u["into"] not in have:
            mods.append({"path": u["into"], "purpose": u["purpose"] or f"merged from {', '.join(u['from'])}",
                         "depends": [], "consolidated_from": u["from"]})
    for boot in rec["bootstraps"]:
        if boot not in have:
            mods.append({"path": boot, "prebuilt": True, "depends": [],
                         "purpose": "PREBUILT Forge bootstrap (forge/kit/bootstrap): boots Init/Start modules"})
    spec["modules"] = mods
    spec.setdefault("consolidations", []).append({"summary": plan["summary"], "ts": now_iso(),
                                                  "units": [[u["from"], u["into"]] for u in plan["units"]],
                                                  "deleted": rec["deleted"]})
    return spec


def _next_n(out_dir: Path) -> int:
    return max((int(p.stem) for p in out_dir.glob("*.json") if p.stem.isdigit()), default=0) + 1


def _save(out_dir: Path, rec: dict) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{rec['n']}.json"
    path.write_text(json.dumps(rec, indent=1, ensure_ascii=False, default=str), encoding="utf-8")
    return path


def touched_names(plan: dict, rec: dict) -> set[str]:
    paths = {p for u in plan["units"] for p in u["from"] + [u["into"]]} | {d["path"] for d in plan["delete"]}
    paths |= {r["path"] for r in rec.get("rewired") or []}
    return {instance_name(p) for p in paths}


@contextlib.asynccontextmanager
async def _studio(settings: Settings, studio: Any, name: str | None):
    if studio is not None:
        yield studio
        return
    from forge.studio import Studio

    async with Studio(settings) as s:
        await s.select(name or os.environ.get("FORGE_STUDIO") or None)
        yield s


async def consolidate(settings: Settings, slug: str, *, llm: Any = None, ui: Any = None, studio: Any = None,
                      studio_name: str | None = None, plan_only: bool = False, max_merges: int = MAX_MERGES,
                      probe_seconds: float = PROBE_SECONDS, jobs: int | None = None,
                      log: Callable[[str], None] = print) -> dict:
    """Plan, build, gate, keep or roll back (see the module doc). Returns the saved record."""
    from forge import compare
    from forge.checks import load_checks
    from forge.loop import Run, copy_base_game
    from forge.scenarios import save_suite_results

    store = RunStore(settings, slug)
    if not store.exists() or not store.game_dir.is_dir():
        raise FileNotFoundError(f"no game {slug!r} in {settings.runs_dir}")
    spec = store.load_spec()
    run = Run(settings, store, llm, ui, jobs=jobs, command="consolidate")
    run.spec = spec
    out_dir = store.dir / "consolidate"
    session = f"consolidate-{slug}"
    protected = protected_paths(spec, store.game_dir)
    report = compare.compare(store.game_dir, settings.base_game_dir, spec=spec, run_dir=store.dir, name=slug,
                             ref_name="game")
    rows = module_map(store.game_dir, protected)
    rec: dict = {"n": _next_n(out_dir), "slug": slug, "ts": now_iso(), "plan_only": plan_only,
                 "max_merges": max_merges, "compare_before": _arch(report)}
    try:
        with run.stage("consolidate: plan"):
            plan, problems, ids = await make_plan(run, spec, rows, report, protected=protected, max_merges=max_merges,
                                                  session=session, last=last_pass_text(out_dir), log=log)
        rec.update(plan=plan, problems=problems, request_ids=ids)
        log(render_plan(plan, problems))
        if plan_only or is_empty(plan):
            rec["outcome"] = "plan_only" if plan_only else "nothing_to_do"
            return rec

        copy_base_game(settings, store.game_dir)  # the current runtime: client code may count (ForgeTelemetry)
        versions = GameVersions(store.game_dir)
        rec["version_before"] = versions.snapshot(f"before consolidate: {plan['summary'][:100]}")
        checks = load_checks(store.dir)
        port = settings.sync_port
        async with _studio(settings, studio, studio_name) as st:
            with run.stage("consolidate: baseline"):
                log(f"[consolidate] baseline: sync, {len(checks)} saved checks, a {probe_seconds:g}s probe")
                before = await measure(st, store.game_dir, checks, port=port, seconds=probe_seconds, log=log)
            rec["before"] = before
            with run.stage("consolidate: build"):
                ex = await execute(run, plan, rows, protected=protected, session=session, log=log)
            rec["execute"] = {k: v for k, v in ex.items() if k != "fixes"}
            rec["execute"]["compile_fixes"] = len(ex["fixes"]["fixes"])
            why = list(ex["failed"])
            if not why:
                with run.stage("consolidate: gate"):
                    after, why = await gate(st, store.game_dir, checks, before, touched_names(plan, ex),
                                            port=port, seconds=probe_seconds, log=log)
                rec["after"] = after
            rec["why"] = why
            if why:
                rec["outcome"] = "rolled_back"
                rec["version_after"] = versions.restore(rec["version_before"], "consolidate gate failed: "
                                                        + "; ".join(why)[:300])
                with contextlib.suppress(Exception):
                    await st.sync(store.game_dir, port)  # leave Studio on the restored game
                log(f"[consolidate] rolled back to {rec['version_before']} ({rec['version_after']}): "
                    + "; ".join(why)[:500])
                return rec
        rec["outcome"] = "kept"
        rec["version_after"] = versions.snapshot(
            f"consolidate: {plan['summary'][:100]} ({len(plan['units'])} written, {len(ex['deleted'])} deleted, "
            f"{len(ex['rewired'])} rewired)")
        store.save_spec(update_spec(spec, plan, ex))
        state = store.load_state()
        state["rollback_floor"] = store.next_iteration(state)  # the game changed: later rollbacks start here
        store.save_state(state)
        if checks:
            save_suite_results(store.dir, [{"id": cid, **r} for cid, r in rec["after"]["checks"].items()],
                               f"consolidate {rec['n']}")
        after_report = compare.compare(store.game_dir, settings.base_game_dir, spec=spec, run_dir=store.dir,
                                       name=slug, ref_name="game")
        compare.save(report, store.dir / "compare")
        compare.save(after_report, store.dir / "compare")
        rec["compare_after"] = _arch(after_report)
        log(f"[consolidate] kept {rec['version_after']}: architecture {rec['compare_before']['architecture']} -> "
            f"{rec['compare_after']['architecture']}, overall {rec['compare_before']['overall']} -> "
            f"{rec['compare_after']['overall']}")
        return rec
    except BaseException as e:  # Studio dropping mid-gate, Ctrl-C: never leave a half-consolidated game behind
        rec["error"] = f"{type(e).__name__}: {str(e)[:300]}"
        if rec.get("version_before") and "outcome" not in rec:
            rec["outcome"], rec["why"] = "rolled_back", [f"the pass stopped: {rec['error']}"]
            with contextlib.suppress(Exception):
                rec["version_after"] = GameVersions(store.game_dir).restore(
                    rec["version_before"], f"consolidate stopped: {rec['error'][:200]}")
        raise
    finally:
        rec.setdefault("outcome", "error")
        path = _save(out_dir, rec)
        log(f"[consolidate] {rec['outcome']}: {path}")
        run.save_timings()


# ------------------------------------------------------------------------------- CLI


def add_cli_parser(sub) -> None:
    p = sub.add_parser("consolidate", help="architect pass: merge overlapping modules, fold scripts into Init/Start "
                                           "bootstraps, delete telemetry-only Ack scripts; gated, rolled back on failure")
    p.add_argument("slug")
    p.add_argument("--plan-only", action="store_true", help="print the architect's validated plan; change nothing")
    p.add_argument("--max-merges", type=int, default=MAX_MERGES,
                   help=f"new files one pass may write (merges + scripts folded into a bootstrap; default {MAX_MERGES})")
    p.add_argument("--studio", help="Studio name part or id (default FORGE_STUDIO)")


def cmd_consolidate(args) -> int:
    rec = asyncio.run(consolidate(load_settings(), args.slug, plan_only=args.plan_only,
                                  max_merges=max(1, args.max_merges), studio_name=args.studio))
    if rec.get("outcome") in ("kept", "plan_only", "nothing_to_do"):
        return 0
    return 1
