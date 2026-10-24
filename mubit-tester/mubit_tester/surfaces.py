"""UI surfaces a playtest round must press, and how much of them the testers actually covered.

A surface is one on-screen feature entry (a HUD button such as "Pass", "Shop", "HELP") with the action
buttons behind it ("Claim", "Get Premium Pass"). They come from three places, all of the game itself:
- the game's client scripts (TextButton/ImageButton texts and their ScreenGui, by regex),
- the live `ui` of the first observation (what a player can see and press right now),
- the spec (title, pitch, core loop, acceptance) to rank surfaces the design names first.
A script surface is kept only when the live UI or the spec confirms it, so a stale or foreign script
never adds work. At most MAX_SURFACES per round.
"""

from __future__ import annotations

import re
from pathlib import Path

MAX_SURFACES = 5
MAX_ACTIONS = 3
CLIENT_DIRS = ("StarterPlayerScripts", "StarterGui", "StarterPlayer")
SKIP_SCRIPTS = ("ForgeTest", "ForgeProbe")
_NEW = re.compile(r'local\s+(\w+)\s*=\s*Instance\.new\(\s*"(TextButton|ImageButton|ScreenGui)"\s*\)')
_PROP = re.compile(r'\b(\w+)\.(Text|Name)\s*=\s*"([^"\n]*)"')
_WORDS = re.compile(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])")
_NOISE = {"gui", "button", "btn", "panel", "frame", "screen", "main", "hud", "ui", "the", "and", "get"}


def _meaningful(text: str) -> bool:
    t = text.strip()
    return bool(re.search(r"[A-Za-z]{2,}", t)) and t.lower() not in ("x", "close", "ok")


def _is_state(text: str) -> bool:
    """'Claimed', 'Locked', 'Owned': a button's state label, not something to press."""
    w = text.strip().split()
    return len(w) == 1 and w[0].lower().endswith("ed")


def script_surfaces(game_dir: Path | str | None) -> list[dict]:
    """One surface per client script with buttons: name = its first button text, actions = the rest."""
    root = Path(game_dir) if game_dir else None
    if not root or not root.is_dir():
        return []
    out = []
    files = sorted(f for d in CLIENT_DIRS if (root / d).is_dir() for f in (root / d).rglob("*.luau"))
    for f in files:
        if any(s in f.name for s in SKIP_SCRIPTS):
            continue
        try:
            src = f.read_text(errors="replace")
        except OSError:
            continue
        kinds = {m.group(1): m.group(2) for m in _NEW.finditer(src)}
        gui, texts = "", []
        for m in _PROP.finditer(src):
            var, prop, val = m.groups()
            if kinds.get(var) == "ScreenGui" and prop == "Name" and not gui:
                gui = val
            elif kinds.get(var) in ("TextButton", "ImageButton") and prop == "Text" and _meaningful(val) \
                    and not _is_state(val) and val not in texts:
                texts.append(val)
        if texts:
            out.append({"name": texts[0], "gui": gui, "actions": texts[1:1 + MAX_ACTIONS],
                        "script": str(f.relative_to(root))})
    return out


def live_surfaces(observations: list[dict]) -> list[dict]:
    """Buttons visible in the first observations' `ui` (one surface per button text)."""
    out, seen = [], set()
    for obs in observations or []:
        for b in (obs or {}).get("ui") or []:
            if not isinstance(b, dict):
                continue
            path = str(b.get("path") or "")
            name = str(b.get("text") or "").strip() or path.rsplit(".", 1)[-1]
            if not _meaningful(name) or name.lower() in seen:
                continue
            seen.add(name.lower())
            out.append({"name": name, "gui": str(b.get("gui") or path.split(".", 1)[0]), "path": path})
    return out


def _tokens(*texts: str) -> set[str]:
    words = set()
    for t in texts:
        words |= {w.lower() for w in _WORDS.findall(t or "")}
    return {w for w in words if len(w) >= 3 and w not in _NOISE}


def _spec_text(spec: dict | None) -> str:
    spec = spec or {}
    parts = [str(spec.get(k) or "") for k in ("title", "pitch", "core_loop")]
    parts += [str(a) for a in spec.get("acceptance") or []]
    parts += [str(f) for f in spec.get("features") or []]
    return " ".join(parts).lower()


def derive_surfaces(spec: dict | None, game_dir: Path | str | None, observations: list[dict],
                    limit: int = MAX_SURFACES) -> list[dict]:
    """Merge script + live + spec into at most `limit` surfaces, design-named and on-screen ones first."""
    spec_text = _spec_text(spec)
    live = live_surfaces(observations)
    live_names = {s["name"].lower() for s in live}
    live_guis = {s["gui"] for s in live if s["gui"]}
    merged: dict[str, dict] = {}
    for s in script_surfaces(game_dir):
        on_screen = (s["gui"] and s["gui"] in live_guis) or s["name"].lower() in live_names
        named = bool(_tokens(s["name"], s["gui"]) & set(re.findall(r"[a-z]+", spec_text)))
        if not (on_screen or named):
            continue
        key = s["gui"] or s["name"].lower()
        merged[key] = {"name": s["name"], "gui": s["gui"], "actions": s["actions"],
                       "source": ["script"] + (["live"] if on_screen else []) + (["spec"] if named else [])}
    for s in live:
        key = s["gui"] if s["gui"] in merged else s["name"].lower()
        if key in merged:
            if "live" not in merged[key]["source"]:
                merged[key]["source"].append("live")
            continue
        named = bool(_tokens(s["name"], s["gui"]) & set(re.findall(r"[a-z]+", spec_text)))
        merged[key] = {"name": s["name"], "gui": s["gui"], "actions": [],
                       "source": ["live"] + (["spec"] if named else [])}

    def rank(s: dict) -> tuple:
        live, named = "live" in s["source"], "spec" in s["source"]
        return (-(live and named), -live, -named, -len(s["actions"]))

    return sorted(merged.values(), key=rank)[:limit]


def assign_surfaces(surfaces: list[dict], roster: list[dict]) -> list[dict]:
    """Round-robin the surfaces over players who can press (sets `assigned`, None when nobody can)."""
    pressers = [p["name"] for p in roster if p.get("can_press")]
    for i, s in enumerate(surfaces):
        s["assigned"] = pressers[i % len(pressers)] if pressers else None
    return surfaces


def tasks_for(surfaces: list[dict], name: str) -> list[dict]:
    return [s for s in surfaces or [] if s.get("assigned") == name]


def tasks_text(tasks: list[dict]) -> str:
    lines = ["Press each of these UI features at least once this round: open it with its button, then press "
             "its action buttons and check the effect. A button that does not fire, or a panel that opens but "
             "whose actions change nothing, is a bug to report."]
    for s in tasks:
        line = f"- {s['name']}" + (f" (gui {s['gui']})" if s.get("gui") else "")
        if s.get("actions"):
            line += f", then: {', '.join(s['actions'])}"
        lines.append(line)
    return "\n".join(lines)


def _hits(s: dict, p: dict) -> str | None:
    """'entry' (its own button), 'action' (one of its action buttons) or 'other' (e.g. its close button)."""
    text = str(p.get("text") or "").strip().lower()
    path = str(p.get("path") or "")
    gui = str(p.get("gui") or path.split(".", 1)[0])
    if text == s["name"].lower() or path.rsplit(".", 1)[-1].lower() == s["name"].lower():
        return "entry"
    if text and text in {a.lower() for a in s.get("actions") or []}:
        return "action"
    if s.get("gui") and gui == s["gui"]:
        return "action" if text and _meaningful(text) else "other"
    return None


def coverage(surfaces: list[dict], presses: list[dict]) -> dict:
    """{surfaces: [...pressed, fired, actions_pressed], pressed, total, gaps: ["Pass: never pressed ..."]}"""
    out, gaps = [], []
    for s in surfaces or []:
        hits = [(h, p) for p in presses or [] if isinstance(p, dict) for h in [_hits(s, p)] if h]
        fired = [p for _, p in hits if p.get("fired")]
        actions = sorted({str(p.get("text") or p.get("path")) for h, p in hits if h == "action"})
        item = {"name": s["name"], "gui": s.get("gui", ""), "assigned": s.get("assigned"),
                "presses": len(hits), "fired": len(fired),
                "changed": sum(1 for p in fired if p.get("changed")), "actions_pressed": actions,
                "actions": s.get("actions") or []}
        out.append(item)
        label = s["name"] + (f" ({s['gui']})" if s.get("gui") else "")
        if not hits:
            why = "" if s.get("assigned") else "; no tester could press UI this run"
            gaps.append(f"{label}: never pressed, its panel was never opened{why}")
        elif not fired:
            gaps.append(f"{label}: pressed {len(hits)}x but the button never fired")
        else:
            done = {a.lower() for a in actions}
            missing = [a for a in s.get("actions") or [] if a.lower() not in done]
            if missing:
                gaps.append(f"{label}: opened, but {', '.join(missing)} never pressed")
    return {"surfaces": out, "pressed": sum(1 for x in out if x["presses"]), "total": len(out), "gaps": gaps}
