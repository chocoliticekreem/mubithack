"""UI kit selection: picks the rules + the few forge/ui_library snippets that fit a module, for the
user message of coder/fixer/patcher calls (never the system prompt, which Mubit keys tasks on).

block(path, text, budget) -> "## UI kit ..." or "" when the work is not UI.
designer_block() -> a short catalog so the designer names components in module purposes.
"""

from __future__ import annotations

import functools
import json
import re
from pathlib import Path

LIBRARY_DIR = Path(__file__).parent / "ui_library"
HEADER = "## UI kit"
MAX_CHARS = 9000
MAX_SNIPPETS = 4
FALLBACK = ("ChunkyText", "StyledButton")

# Words that mean "this is screen UI" on a client (or a UI module in ReplicatedStorage).
SCREEN_WORDS = ("gui", "screengui", "hud", "ui", "popup", "pop-up", "toast", "interface", "menu",
                "notification", "scoreboard")
# Weaker words that only count on the client side.
CLIENT_WORDS = ("button", "shop", "panel", "label", "display", "displays", "show", "shows", "reward",
                "progress", "bar", "counter", "tween", "window", "inventory", "text", "leaderboard",
                "coins", "cash", "currency", "timer")
# World UI a server Script may build itself.
WORLD_WORDS = ("billboard", "billboardgui", "surfacegui", "price tag", "price tags", "nameplate",
               "overhead")

_CLIENT_ROOTS = ("StarterPlayerScripts", "StarterGui", "StarterCharacterScripts")
_SERVER_ROOTS = ("ServerScriptService", "ServerStorage")


@functools.lru_cache(maxsize=1)
def load_index() -> tuple[dict, ...]:
    entries = json.loads((LIBRARY_DIR / "index.json").read_text())
    return tuple(entries)


@functools.cache
def snippet(file: str) -> str:
    return (LIBRARY_DIR / file).read_text().strip("\n")


@functools.lru_cache(maxsize=1)
def rules() -> str:
    text = (LIBRARY_DIR / "README.md").read_text()
    m = re.search(r"^## Rules\n(.*?)(?=^## |\Z)", text, re.DOTALL | re.MULTILINE)
    return m.group(1).strip() if m else ""


def _words(text: str) -> str:
    """Lowercase text with camelCase and path separators split: 'ShopUI.client.luau' -> 'shop ui client luau'."""
    text = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", text or "")
    text = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", text)
    return re.sub(r"[/_.\-]+", " ", text).lower()


def _has(words: str, kw: str) -> bool:
    return re.search(r"(?<![\w+])" + re.escape(kw.lower()) + r"(?!\w)", words) is not None


def _any(words: str, kws) -> bool:
    return any(_has(words, k) for k in kws)


def side(path: str) -> str:
    """client | server | shared, from the file mapping in docs/ARCHITECTURE.md."""
    root = (path or "").split("/", 1)[0]
    if path.endswith(".client.luau") or root in _CLIENT_ROOTS:
        return "client"
    if path.endswith(".server.luau") or root in _SERVER_ROOTS:
        return "server"
    return "shared"


def kind(path: str, text: str, *, path_words: bool = True) -> str | None:
    """'screen' (full kit), 'world' (server-safe snippets only) or None (not UI work).
    path_words=False ignores the file name, for fixes where only the problem says whether it is UI."""
    words = _words(f"{path if path_words else ''} {text}")
    s = side(path)
    if s == "client" and (_any(words, SCREEN_WORDS) or _any(words, CLIENT_WORDS) or _any(words, WORLD_WORDS)):
        return "screen"
    if s == "shared" and _any(words, SCREEN_WORDS):
        return "screen"
    if _any(words, WORLD_WORDS):
        return "world"
    return None


def select(path: str, text: str, *, path_words: bool = True, limit: int = MAX_SNIPPETS) -> list[dict]:
    """Ranked entries for this work: Theme first when anything needs it, then by keyword hits."""
    k = kind(path, text, path_words=path_words)
    if k is None:
        return []
    words = _words(f"{path if path_words else ''} {text}")
    pool = [e for e in load_index() if not e.get("always")]
    if k == "world":
        pool = [e for e in pool if not e.get("needs_theme")]
    scored = []
    for i, e in enumerate(pool):
        score = sum(1 for kw in e["keywords"] if _has(words, kw))
        if _has(words, e["name"]) or _has(words, _words(e["name"])):
            score += 3
        if score:
            scored.append((-score, i, e))
    picks = [e for _, _, e in sorted(scored, key=lambda t: t[:2])][: max(0, limit - 1)]
    if not picks and k == "screen":
        picks = [e for e in pool if e["name"] in FALLBACK]
    if not picks:
        return []
    if any(e.get("needs_theme") for e in picks):
        picks = [e for e in load_index() if e.get("always")] + picks
    return picks


def _entry_text(e: dict) -> str:
    return f"### {e['file']} ({e['when_to_use']})\n```luau\n{snippet(e['file'])}\n```\n"


def block(path: str, text: str, budget: int = MAX_CHARS, *, path_words: bool = True) -> str:
    """The '## UI kit' user-message block, at most `budget` chars, or '' when not UI work / no room."""
    picks = select(path, text, path_words=path_words)
    if not picks:
        return ""
    head = (f"{HEADER} (house style for all UI: paste the snippets you use, Theme first, and adapt;"
            " plain Luau, not modules)\n"
            f"{rules()}\n\n")
    if len(head) > budget:
        return ""
    out, used, has_theme = [head], len(head), False
    for e in picks:
        if e.get("needs_theme") and not has_theme:
            continue
        part = _entry_text(e)
        if used + len(part) > budget:
            continue
        out.append(part)
        used += len(part)
        has_theme = has_theme or bool(e.get("always"))
    return "".join(out)  # a tight budget degrades to rules only, never to snippets missing Theme


def designer_block() -> str:
    lines = [f"{HEADER} the coder gets (name the ones a client module needs in its purpose)"]
    lines += [f"- {e['name']}: {e['when_to_use']}" for e in load_index() if not e.get("always")]
    return "\n".join(lines) + "\n"
