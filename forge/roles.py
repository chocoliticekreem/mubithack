"""Typed wrappers around the LLM roles. All per-call text is built here, in the user message.

System prompts (forge/prompts/<role>.md) are fixed; never put anything that varies into them.
User messages are kept compact (< ~24k chars) so each call stays under Mubit's ~8k-token run size
and remains trainable.
"""

from __future__ import annotations

import json
import re

from forge import ui_kit
from forge.llm import LLM, LLMError
from forge.smoke import format_smoke

MAX_USER_CHARS = 24_000
# Luau and JSON run ~2 chars per token (measured on real Mubit calls), so 24k chars is ~12k tokens.
# Optional context (the UI kit) only gets room up to this many chars, which keeps a call with its system
# prompt near the ~8k-token run size. Required text (the file being fixed, deps) is never cut for it.
INPUT_BUDGET_CHARS = 15_000
LESSONS_HEADER = "## Lessons from past builds"

SPEC_KEYS = ["title", "slug", "pitch", "core_loop", "modules", "acceptance"]
# "done" is not required: it defaults to false (and the loop also stops on the score), so a reply that
# leaves it out is used as is instead of paying for a ~15s JSON repair call (seen on real Mubit runs).
CRITIQUE_KEYS = ["score", "summary", "issues"]
ROOTS = ("ServerScriptService", "ReplicatedStorage", "StarterPlayerScripts")
RUNTIME_MODULES = {"ReplicatedStorage/ForgeTelemetry.luau", "ServerScriptService/ForgeProbe.server.luau"}
MAX_MODULES = 7
# The frozen coder prompt still calls ForgeTelemetry a no-op on the client, and planners asked for counters
# "on the server" wrote one *Ack remote + script per client effect. The runtime now forwards client counts
# itself (game/ReplicatedStorage/ForgeTelemetry.luau), so the user message says so.
CLIENT_TELEMETRY_NOTE = (
    "## Telemetry from client code\n"
    "ForgeTelemetry.count(name, n) works in LocalScripts and client modules too: the module forwards client "
    "counts to the server over its own shared, rate-limited remote (this replaces any rule that it is a no-op "
    "on the client). Count a client-side moment (an effect shown, a panel opened, a button pressed) right where "
    "it happens, with `require(ReplicatedStorage:WaitForChild(\"ForgeTelemetry\")).count(\"name\", 1)`. Never "
    "create a RemoteEvent, an *Ack script or a server handler only to bump a counter.\n"
)
_TELEMETRY_WORDS = re.compile(r"(?i)telemetry|counter")


def telemetry_note(problem: str) -> str:
    """CLIENT_TELEMETRY_NOTE for a fix or patch about counters (never for a compile error)."""
    text = problem or ""
    if text.lstrip().startswith("luau-compile") or not _TELEMETRY_WORDS.search(text):
        return ""
    return CLIENT_TELEMETRY_NOTE


# ---------------------------------------------------------------------------------------------
# helpers


def _truncate(text: str, limit: int, *, keep: str = "head", label: str = "text") -> str:
    """Trim text to about `limit` chars with an explicit note. keep: head | tail | both."""
    text = text or ""
    if len(text) <= limit:
        return text
    cut = len(text) - limit
    note = f"\n...[{label} truncated: {cut} chars omitted]...\n"
    if keep == "tail":
        return note.lstrip("\n") + text[-limit:]
    if keep == "both":
        half = limit // 2
        return text[:half] + note + text[-half:]
    return text[:limit] + note.rstrip("\n")


def _lessons_block(lessons: str, limit: int = 5000) -> str:
    lessons = (lessons or "").strip()
    if not lessons:
        return ""
    return f"{LESSONS_HEADER}\n{_truncate(lessons, limit, label='lessons')}\n"


def _compact_spec(spec: dict, limit: int = 4000) -> str:
    keep = {k: spec.get(k) for k in ("title", "pitch", "core_loop", "acceptance") if k in spec}
    keep["modules"] = [
        {"path": m.get("path"), "purpose": m.get("purpose"), "depends": m.get("depends", [])}
        for m in spec.get("modules", [])
        if isinstance(m, dict)
    ]
    return _truncate(json.dumps(keep, indent=1, ensure_ascii=False), limit, label="spec")


_API_LINE = re.compile(
    r"^\s*(?:export\s+type\b|type\b|local\s+function\b|function\b|return\b|local\s+\w+\s*=\s*\{\s*\}?\s*$"
    r"|[A-Z][\w]*\.[A-Za-z_]\w*\s*=)"
)


def api_summary(source: str, limit: int) -> str:
    """Full source if it fits; otherwise the module's public surface (types, functions, fields)."""
    if len(source) <= limit:
        return source
    lines = [ln.rstrip() for ln in source.splitlines() if _API_LINE.match(ln)]
    summary = "-- [API summary: only declarations shown]\n" + "\n".join(lines)
    return _truncate(summary, limit, label="API summary")


def _clip_block(text: str) -> str:
    """Prevent embedded ``` from breaking our own fences."""
    return (text or "").replace("```", "` ` `")


def _fit(msg: str) -> str:
    return _truncate(msg, MAX_USER_CHARS, keep="head", label="message")


# UI kit share per role (coder: ui_kit.MAX_CHARS). Fixes carry the whole file; the patcher's
# code excerpt matters more than style.
FIX_UI_KIT_CHARS = 6000
PATCH_UI_KIT_CHARS = 3500


def _with_ui_kit(msg: str, tail: str, path: str, problem: str, cap: int) -> str:
    """Append the UI kit block when the problem is UI work. Only the problem decides (not the file
    name), and compile errors never get it: the fix there is syntax, not style."""
    if (problem or "").lstrip().startswith("luau-compile"):
        return msg
    room = min(cap, INPUT_BUDGET_CHARS - len(msg) - len(tail) - 2)
    kit = ui_kit.block(path, problem or "", room, path_words=False)
    return msg + (kit + "\n" if kit else "")


# ---------------------------------------------------------------------------------------------
# Luau extraction

_LUAU_FENCE = re.compile(r"```[ \t]*(luau|lua)?[ \t]*\r?\n(.*?)\r?\n?```", re.DOTALL | re.IGNORECASE)


def extract_luau(text: str) -> str:
    """Return the body of the ```luau block in a reply (longest luau/lua block, else any block)."""
    blocks = [(m.group(1), m.group(2)) for m in _LUAU_FENCE.finditer(text or "")]
    tagged = [b for lang, b in blocks if lang]
    pool = tagged or [b for _, b in blocks]
    if not pool:
        raise LLMError("reply has no ```luau code block")
    body = max(pool, key=len).strip("\n")
    if not body.strip():
        raise LLMError("reply has an empty ```luau code block")
    return body + "\n"


# A whole Luau file per reply. Large game files (2k+ lines) need far more than 8k tokens; above ~21k the
# Anthropic SDK requires streaming, so stay under that.
LUAU_MAX_TOKENS = 20_000


def _check_complete(res) -> None:
    if res.output_tokens is not None and res.output_tokens >= LUAU_MAX_TOKENS:
        raise LLMError(f"reply cut off at the {LUAU_MAX_TOKENS}-token output limit (file too long to rewrite whole)")


def _complete_luau(llm: LLM, role: str, user: str, *, session_id: str) -> str:
    res = llm.complete(role, user, session_id=session_id, max_tokens=LUAU_MAX_TOKENS)
    _check_complete(res)
    try:
        return extract_luau(res.text)
    except LLMError as e:
        retry = (
            f"{user}\n\n## Your previous reply could not be used\nError: {e}.\n"
            "Reply with the complete file in exactly one ```luau fenced block."
        )
        res = llm.complete(role, retry, session_id=session_id, max_tokens=LUAU_MAX_TOKENS)
        _check_complete(res)
        return extract_luau(res.text)


# ---------------------------------------------------------------------------------------------
# designer


def _slugify(s: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (s or "").lower()).strip("-")
    return s[:48].strip("-") or "game"


def validate_spec(spec: dict) -> list[str]:
    """Return a list of problems with a designer Spec (empty = OK)."""
    problems: list[str] = []
    mods = spec.get("modules")
    if not isinstance(mods, list) or not mods:
        return ["modules must be a non-empty list"]
    if len(mods) > MAX_MODULES:
        problems.append(f"too many modules ({len(mods)}); use at most {MAX_MODULES}")
    seen = set()
    for m in mods:
        if not isinstance(m, dict) or not isinstance(m.get("path"), str):
            problems.append(f"module entry {m!r} needs a string 'path'")
            continue
        p = m["path"]
        root = p.split("/", 1)[0]
        if root not in ROOTS:
            problems.append(f"{p}: path must start with one of {', '.join(ROOTS)}")
        if not p.endswith(".luau"):
            problems.append(f"{p}: path must end in .server.luau, .client.luau or .luau")
        if root == "StarterPlayerScripts" and p.endswith(".server.luau"):
            problems.append(f"{p}: server Scripts do not run in StarterPlayerScripts")
        if root == "ServerScriptService" and p.endswith(".client.luau"):
            problems.append(f"{p}: LocalScripts do not run in ServerScriptService")
        if p in seen:
            problems.append(f"{p}: duplicate path")
        seen.add(p)
    if not isinstance(spec.get("acceptance"), list):
        problems.append("acceptance must be a list of strings")
    return problems


def _normalize_spec(spec: dict) -> dict:
    spec["slug"] = _slugify(spec.get("slug") or spec.get("title") or "")
    mods = []
    for m in spec.get("modules", []):
        if not isinstance(m, dict) or m.get("path") in RUNTIME_MODULES:
            continue  # the runtime (ForgeProbe, ForgeTelemetry) is always present
        m.setdefault("purpose", "")
        deps = m.get("depends") or []
        m["depends"] = [d for d in deps if isinstance(d, str)]
        mods.append(m)
    known = {m["path"] for m in mods} | RUNTIME_MODULES
    for m in mods:
        m["depends"] = [d for d in m["depends"] if d in known and d != m["path"]]
    spec["modules"] = mods
    spec["acceptance"] = [str(a) for a in spec.get("acceptance") or []]
    return spec


def design(llm: LLM, idea: str, lessons: str, *, session_id: str) -> dict:
    user = _fit(
        "## Game idea\n"
        f"{_truncate(idea.strip(), 3000, label='idea')}\n\n"
        f"{_lessons_block(lessons, 6000)}\n"
        f"{ui_kit.designer_block()}\n"
        "Return only the Spec JSON object."
    )
    spec, _ = llm.complete_json("designer", user, session_id=session_id, required=SPEC_KEYS)
    problems = validate_spec(spec)
    if problems:
        retry = (
            f"{user}\n\n## Your previous spec has problems\n"
            + "\n".join(f"- {p}" for p in problems)
            + "\n\nPrevious spec:\n"
            + _truncate(json.dumps(spec, ensure_ascii=False), 6000, label="spec")
            + "\n\nReturn only the corrected Spec JSON object."
        )
        spec, _ = llm.complete_json("designer", retry, session_id=session_id, required=SPEC_KEYS)
        problems = validate_spec(spec)
        if problems:
            raise LLMError("designer spec invalid: " + "; ".join(problems))
    return _normalize_spec(spec)


# ---------------------------------------------------------------------------------------------
# coder


def _deps_block(deps: dict[str, str], budget: int) -> str:
    if not deps:
        return "## Dependencies\n(none)\n"
    per = max(1500, budget // max(1, len(deps)))
    parts = ["## Dependencies (already written; require them, do not redefine them)"]
    used = 0
    for path, src in deps.items():
        body = api_summary(src or "", min(per, max(0, budget - used)) or 1500)
        used += len(body)
        parts.append(f"### {path}\n```luau\n{_clip_block(body)}\n```")
    return "\n".join(parts) + "\n"


def code_module(
    llm: LLM, spec: dict, module: dict, deps: dict[str, str], lessons: str, *, session_id: str
) -> str:
    from forge.director import kit_api_block, kit_paths

    path = module.get("path", "")
    kit = kit_api_block(spec)
    if kit:  # a kit module's API is listed in full below; its 1000-line source would only crowd the deps
        deps = {p: s for p, s in deps.items() if p not in kit_paths()}
    head = (
        "## Game spec\n"
        f"{_compact_spec(spec)}\n\n"
        "## Module to write\n"
        f"path: {path}\n"
        f"purpose: {module.get('purpose', '')}\n"
        f"depends: {', '.join(module.get('depends') or []) or '(none)'}\n\n"
        f"{_deps_block(deps, 10_000)}\n"
        f"{kit + chr(10) if kit else ''}"
        f"{CLIENT_TELEMETRY_NOTE}\n"
        f"{_lessons_block(lessons, 5000)}\n"
    )
    tail = f"Write the complete file {path} in one ```luau block."
    room = min(ui_kit.MAX_CHARS, INPUT_BUDGET_CHARS - len(head) - len(tail) - 2)
    kit = ui_kit.block(path, module.get("purpose", "") or "", room)
    user = _fit(head + (kit + "\n" if kit else "") + tail)
    return _complete_luau(llm, "coder", user, session_id=session_id)


# ---------------------------------------------------------------------------------------------
# fixer


def fix_file(
    llm: LLM, path: str, source: str, problem: str, context: str, lessons: str, *, session_id: str
) -> str:
    # The fixer must return the whole file, so the source is never cut unless it is huge;
    # problem/context/lessons shrink to make room for it instead.
    src = _truncate(source, 18_000, keep="both", label="source")
    spare = max(0, MAX_USER_CHARS - 1000 - len(src))
    user = (
        "## File\n"
        f"path: {path}\n"
        f"```luau\n{_clip_block(src)}\n```\n\n"
        "## Problem\n"
        f"{_truncate(problem.strip(), max(1200, min(3000, spare * 3 // 10)), keep='both', label='problem')}\n\n"
        "## Context\n"
        f"{_truncate((context or '').strip() or '(none)', max(800, min(3500, spare * 3 // 10)), keep='both', label='context')}\n\n"
        f"{telemetry_note(problem)}"
        f"{_lessons_block(lessons, max(800, min(4000, spare * 4 // 10)))}\n"
    )
    tail = f"Return the full corrected {path} in one ```luau block."
    user = _fit(_with_ui_kit(user, tail, path, problem, FIX_UI_KIT_CHARS) + tail)
    return _complete_luau(llm, "fixer", user, session_id=session_id)



def patch_file(
    llm: LLM, path: str, source: str, problem: str, context: str, lessons: str, *, session_id: str
) -> str:
    """Large files: the `patcher` role returns exact find/replace edits (forge/patch.py), applied here.
    Returns the patched source; an edit that does not apply raises LLMError with the reason."""
    from forge.patch import PatchError, apply_edits, outline, relevant_excerpt

    n = len(source.splitlines())
    # The problem comes before the code, so a long excerpt can never push it out of the message.
    head = (
        "## File\n"
        f"path: {path} ({n} lines)\nOutline (line: function):\n{_truncate(outline(source), 2000, label='outline')}\n\n"
        "## Problem\n"
        f"{_truncate(problem.strip(), 3000, keep='both', label='problem')}\n\n"
        "## Context\n"
        f"{_truncate((context or '').strip() or '(none)', 2000, keep='both', label='context')}\n\n"
        f"{telemetry_note(problem)}"
        f"{_lessons_block(lessons, 2500)}\n"
    )
    head = _with_ui_kit(head, "", path, problem, PATCH_UI_KIT_CHARS)
    room = max(2000, MAX_USER_CHARS - len(head) - 200)
    user = (head + "## Relevant code\n"
            f"```\n{relevant_excerpt(source, problem, budget=room)}\n```\n\n"
            "Return only the patch JSON object.")
    obj, _ = llm.complete_json("patcher", user, session_id=session_id, required=["edits"], max_tokens=4096)
    try:
        return apply_edits(source, obj.get("edits"))
    except PatchError as e:
        raise LLMError(f"patch could not be applied: {e}") from e

# ---------------------------------------------------------------------------------------------
# critic


def _compact_report(report: dict, limit: int = 5000) -> str:
    r = dict(report or {})
    r.pop("smoke", None)  # the critic gets it as its own section (_smoke_block)
    errs = r.get("errors") or []
    if isinstance(errs, list) and len(errs) > 12:
        r["errors"] = errs[:12] + [{"message": f"...{len(errs) - 12} more errors omitted"}]
    warns = r.get("warnings") or []
    if isinstance(warns, list) and len(warns) > 10:
        r["warnings"] = warns[:10] + [f"...{len(warns) - 10} more warnings omitted"]
    return _truncate(json.dumps(r, indent=1, ensure_ascii=False), limit, label="report")


def _files_block(files: dict[str, str], budget: int) -> str:
    if not files:
        return "## Files\n(none)\n"
    per = max(1200, budget // len(files))
    parts = ["## Files"]
    for path, src in files.items():
        parts.append(
            f"### {path}\n```luau\n{_clip_block(_truncate(src or '', per, keep='both', label='file'))}\n```"
        )
    return "\n".join(parts) + "\n"


def _normalize_critique(c: dict, known_paths: set[str]) -> dict:
    try:
        score = float(c.get("score", 0))
    except (TypeError, ValueError):
        score = 0.0
    score = max(0.0, min(10.0, score))
    issues = []
    for it in c.get("issues") or []:
        if not isinstance(it, dict):
            continue
        issues.append({
            "path": str(it.get("path") or ""),
            "problem": str(it.get("problem") or ""),
            "fix_hint": str(it.get("fix_hint") or ""),
        })
    done = c.get("done")
    if isinstance(done, str):
        done = done.strip().lower() in ("true", "yes", "1")
    return {
        "score": int(score) if score.is_integer() else score,
        "summary": str(c.get("summary") or ""),
        "issues": issues,
        "done": bool(done),
    }


def _smoke_block(report: dict) -> str:
    """'## Smoke play': what the scripted player did before the report was read (forge/smoke.py), if it ran."""
    text = format_smoke((report or {}).get("smoke"))
    return f"## Smoke play\n{text}\n\n" if text else ""


def critique(
    llm: LLM, spec: dict, report: dict, console: str, files: dict[str, str], *, session_id: str,
    history: str = "",
) -> dict:
    """history: forge.rounds.critic_block, what earlier rounds scored and fixed (empty on the first round)."""
    user = _fit(
        "## Game spec\n"
        f"{_compact_spec(spec, 3000)}\n\n"
        "## ForgeProbe report\n"
        f"{_compact_report(report)}\n\n"
        f"{_smoke_block(report)}"
        "## Console output (most recent last)\n"
        f"```\n{_clip_block(_truncate((console or '').strip() or '(empty)', 3500, keep='tail', label='console'))}\n```\n\n"
        f"{_truncate(history, 2500, keep='both', label='history')}"
        f"{_files_block(files, 10_500)}\n"
        "Return only the critique JSON object."
    )
    c, _ = llm.complete_json("critic", user, session_id=session_id, required=CRITIQUE_KEYS)
    return _normalize_critique(c, set(files))


# ---------------------------------------------------------------------------------------------
# reflector

_MD_FENCE = re.compile(r"^\s*```[ \t]*(?:markdown|md)?[ \t]*\n(.*?)\n```\s*$", re.DOTALL | re.IGNORECASE)


def reflect(llm: LLM, lessons: str, iteration_summary: str, *, session_id: str) -> str:
    user = _fit(
        "## Current lessons\n"
        f"{_truncate((lessons or '').strip() or '(none yet)', 8000, label='lessons')}\n\n"
        "## What happened this iteration\n"
        f"{_truncate(iteration_summary.strip(), 12_000, keep='both', label='summary')}\n\n"
        "Return the full new lessons markdown."
    )
    res = llm.complete("reflector", user, session_id=session_id, max_tokens=4096)
    text = res.text.strip()
    m = _MD_FENCE.match(text)
    if m:
        text = m.group(1).strip()
    if not text:
        raise LLMError("reflector returned empty lessons")
    return text + "\n"


# ---------------------------------------------------------------------------------------------
# investigator context (its message is put together in forge/improve.py)
#
# Every investigator call re-sends the game's file index and every earlier step. On real runs the step
# history was 57% of the investigator's input and the index 38%, and the old 12k-char index cut dropped
# 91 of a seeded game's 175 files (every ServerScriptService/Services module among them).

INDEX_CHARS = 6000
STEPS_BUDGET = 9000
STEPS_KEEP = 2          # the newest steps always stay whole: they are what the next action reacts to
OLD_READ_CHARS = 2000
OLD_PROBE_CHARS = 700
OLD_CODE_CHARS = 500
STEP_ACTION_CHARS = 1500


def _step_text(i: int, action: dict, result: str) -> str:
    return f"{i + 1}. {json.dumps(action, ensure_ascii=False)[:STEP_ACTION_CHARS]}\nResult: {result}"


def _cut_step(i: int, step: dict, focus: str) -> str:
    from forge.patch import relevant_excerpt

    act = dict(step.get("action") or {})
    result = str(step.get("result", ""))
    kind = str(act.get("action", "")).lower()
    if kind == "read" and len(result) > OLD_READ_CHARS:
        result = (f"[the file read at step {i + 1}, cut to its lines that match the anomaly; read it again "
                  f"for the rest]\n{relevant_excerpt(result, focus, budget=OLD_READ_CHARS)}")
    elif kind == "probe":
        if len(result) > OLD_PROBE_CHARS:
            result = result[:OLD_PROBE_CHARS] + " ...[cut]"
        if len(str(act.get("code", ""))) > OLD_CODE_CHARS:
            act["code"] = str(act["code"])[:OLD_CODE_CHARS] + " ...[cut]"
    return _step_text(i, act, result)


def steps_block(steps: list[dict], focus: str, budget: int = STEPS_BUDGET) -> str:
    """The investigator's "## Steps so far": every step, oldest first, as before while it fits `budget`. Over
    it, the oldest steps are cut down one by one until it fits or only the newest STEPS_KEEP (never cut) are
    left: a file read to its lines that match `focus` (the anomaly), a probe's code and result to their
    first lines."""
    rows = [_step_text(i, s.get("action") or {}, str(s.get("result", ""))) for i, s in enumerate(steps)]
    for i in range(max(0, len(steps) - STEPS_KEEP)):
        if sum(map(len, rows)) + 2 * (len(rows) - 1) <= budget:
            break
        rows[i] = _cut_step(i, steps[i], focus)
    return "\n\n".join(rows)


def _index_score(words: set[str], rel: str, head: str, text: str) -> int:
    stem, head, text = rel.rsplit("/", 1)[-1].lower(), head.lower(), text.lower()
    return sum(3 * (w in stem) + 2 * (w in head) + (w in text) for w in words)


def compact_index(rows: list[tuple[str, str, str]], focus: str = "", budget: int = INDEX_CHARS) -> str:
    """A file index for a game too big to list with every file's first comment line (rows: path, first
    comment line, source). Every file is still named, grouped by folder; the files that best match `focus`
    (the anomaly, or a feature request) get their comment line too, while the budget lasts."""
    from forge.patch import _STOP, _WORD

    folders: dict[str, list[str]] = {}
    for rel, _, _ in rows:
        folder, _, name = rel.rpartition("/")
        folders.setdefault(folder, []).append(name)
    listing = [f"Every file ({len(rows)}), by folder (a path is the folder + the file name):"]
    listing += [f"{folder or '.'}/: {', '.join(names)}" for folder, names in sorted(folders.items())]
    tail = "\n".join(listing)
    if len(tail) > budget:
        return _truncate(tail, budget, label="file list")
    words = {w.lower() for w in _WORD.findall(focus or "")} - _STOP
    ranked = sorted(((_index_score(words, rel, head, text), rel, head) for rel, head, text in rows if head),
                    key=lambda t: (-t[0], t[1]))
    heads = ["Files that best match this task (path  -- first comment line):"]
    used = len(tail) + len(heads[0]) + 2
    for score, rel, head in ranked:
        if score <= 0:
            break
        line = f"{rel}  -- {head}"
        if used + len(line) + 1 > budget:
            continue
        heads.append(line)
        used += len(line) + 1
    return ("\n".join(heads) + "\n\n" + tail) if len(heads) > 1 else tail
