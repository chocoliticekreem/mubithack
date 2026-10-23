"""Exact-match edits for large files: the patcher returns find/replace blocks instead of a whole file.

A whole-file rewrite of a 1,000+ line file makes the model shorten it (live runs on Flame and Blame
deleted 600 to 1,500 lines per attempt). Edits keep every untouched line byte-identical, and an edit
whose `find` text is missing or ambiguous is refused instead of guessed.
"""

from __future__ import annotations

import re

# Files with more lines than this are patched; smaller ones are still rewritten whole by the fixer.
PATCH_ABOVE_LINES = 300
EXCERPT_CHARS = 14_000
CONTEXT_LINES = 30

_FUNC = re.compile(r"^\s*(?:local\s+)?function\s+([\w.:]+)|^\s*(?:local\s+)?([\w.]+)\s*=\s*function\b")
_WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]{3,}")
_STOP = {"that", "this", "with", "from", "when", "then", "game", "never", "does", "every", "should",
         "player", "players", "local", "return", "function", "true", "false", "nil", "prompt", "into"}


class PatchError(ValueError):
    pass


def outline(src: str, limit: int = 80) -> str:
    """Every function definition with its line number."""
    rows = []
    for n, line in enumerate(src.splitlines(), 1):
        m = _FUNC.match(line)
        if m:
            rows.append(f"{n}: {m.group(1) or m.group(2)}")
    if len(rows) > limit:
        rows = rows[:limit] + [f"... {len(rows) - limit} more"]
    return "\n".join(rows) or "(no functions found)"


def relevant_excerpt(src: str, text: str, budget: int = EXCERPT_CHARS) -> str:
    """Line-numbered windows around the lines that share the most words with `text` (anomaly + root
    cause), merged and capped at `budget` characters."""
    lines = src.splitlines()
    words = {w.lower() for w in _WORD.findall(text)} - _STOP
    scored = []
    for i, line in enumerate(lines):
        low = line.lower()
        hits = sum(1 for w in words if w in low)
        if hits:
            scored.append((hits, i))
    scored.sort(key=lambda t: (-t[0], t[1]))
    windows: list[list[int]] = []
    used = 0
    for _, i in scored:
        lo, hi = max(0, i - CONTEXT_LINES), min(len(lines), i + CONTEXT_LINES + 1)
        if any(lo < w[1] and hi > w[0] for w in windows):
            for w in windows:
                if lo < w[1] and hi > w[0]:
                    w[0], w[1] = min(w[0], lo), max(w[1], hi)
            continue
        cost = sum(len(ln) + 8 for ln in lines[lo:hi])
        if used + cost > budget:
            continue
        windows.append([lo, hi])
        used += cost
    if not windows:
        windows = [[0, min(len(lines), 120)]]
    windows.sort()
    out = []
    for lo, hi in windows:
        out.append(f"--- lines {lo + 1}-{hi} ---")
        out += [f"{n + 1:>5}| {lines[n]}" for n in range(lo, hi)]
    return "\n".join(out)


def apply_edits(src: str, edits: list) -> str:
    """Apply find/replace edits in order. Every `find` must match exactly once."""
    if not isinstance(edits, list) or not edits:
        raise PatchError("no edits")
    out = src
    for k, e in enumerate(edits, 1):
        if not isinstance(e, dict) or not isinstance(e.get("find"), str) or not isinstance(e.get("replace"), str):
            raise PatchError(f"edit {k} needs string 'find' and 'replace'")
        find = e["find"].strip("\n")
        if not find.strip():
            raise PatchError(f"edit {k} has an empty 'find'")
        count = out.count(find)
        if count == 0:
            raise PatchError(f"edit {k}: 'find' text not found in the file (copy it exactly, without line "
                             f"numbers): {find[:160]!r}")
        if count > 1:
            raise PatchError(f"edit {k}: 'find' text appears {count} times; include more lines to make it unique")
        out = out.replace(find, e["replace"].strip("\n"), 1)
    return out
