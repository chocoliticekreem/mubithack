"""UI surfaces a playtest round must press, and how much of them the testers actually covered.

A surface is one on-screen feature entry (a HUD button such as "Pass", "Shop", "HELP") with the action
buttons behind it ("Claim", "Get Premium Pass"). They come from three places, all of the game itself:
- the game's client scripts (TextButton/ImageButton texts and their ScreenGui, by regex),
- the live `ui` of the first observation (what a player can see and press right now),
- the spec (title, pitch, core loop, acceptance) to rank surfaces the design names first.
A script surface is kept only when the live UI or the spec confirms it, so a stale or foreign script
never adds work. At most MAX_SURFACES per round.

Before free play a scripted pass (mubit_tester.ai.ui_pass, no LLM) presses every assigned surface once and
each of its actions that is on screen once it is open; the helpers here pick those buttons (pick_button,
order_actions, close_button, new_buttons) and pass_note tells the presser what it already did.
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
CLOSE_TEXTS = {"x", "close", "back", "×", "✕", "✖"}
# a purchase prompt can cover the screen for the clicks after it, so these actions go last
_PURCHASE = re.compile(r"\b(buy|purchase|premium|robux|unlock|gift)\b", re.IGNORECASE)


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
        if s.get("scripted"):
            line += f" [already pressed by the scripted UI pass: {s['scripted']}]"
        lines.append(line)
    return "\n".join(lines)


# ---------------------------------------------------------------- the scripted UI pass (ai.ui_pass)


def pick_button(buttons: list[dict], text: str | None, path: str | None = None) -> dict | None:
    """The on-screen button (from `ui`) for a surface or action: same path, else same text, else a text
    that contains it. None when it is not on screen (or not interactable) right now."""
    if path:
        hit = next((b for b in buttons if b.get("path") == path), None)
        if hit is not None:
            return hit
    want = (text or "").strip().lower()
    if not want:
        return None
    texts = [(b, str(b.get("text") or "").strip().lower()) for b in buttons]
    # a state label ("Claimed") contains its action's word but is not the action
    return (next((b for b, t in texts if t == want), None)
            or next((b for b, t in texts if t and want in t and not _is_state(t)), None))


def order_actions(actions: list[str]) -> list[str]:
    """The surface's actions, purchase-like ones last (stable)."""
    return sorted(actions or [], key=lambda a: bool(_PURCHASE.search(a)))


def close_button(buttons: list[dict], gui: str | None) -> dict | None:
    """A close button (X, Close, Back) in that ScreenGui."""
    return next((b for b in buttons if (not gui or str(b.get("gui") or "") == gui)
                 and str(b.get("text") or "").strip().lower() in CLOSE_TEXTS), None)


def opened(effect: dict) -> bool:
    """A press's effect opened a panel or a GUI (so the pass closes it again)."""
    return bool((effect or {}).get("panels_opened") or (effect or {}).get("guis_opened"))


def new_buttons(effect: dict, limit: int = MAX_ACTIONS) -> list[str]:
    """Texts of the buttons a press made appear ("text @ path" in its effect): a live surface's actions."""
    out: list[str] = []
    for item in (effect or {}).get("buttons_new") or []:
        text = str(item).split(" @ ", 1)[0].strip()
        if text != "?" and _meaningful(text) and not _is_state(text) and text not in out:
            out.append(text)
    return out[:limit]


def pass_note(rec: dict) -> str:
    """One line of what the scripted pass did on a surface: 'PASS: fired, opened a panel; Claim: ...'."""
    if rec.get("blocked"):
        return "not pressed: " + str(rec["blocked"])
    parts = []
    for p in rec.get("presses") or []:
        if not p.get("fired"):
            state = "did NOT fire"
        elif opened(p.get("effect") or {}):
            state = "fired, opened a panel"
        else:
            state = "fired, " + ("changed the screen" if p.get("changed") else "changed nothing on screen")
        parts.append(f"{p.get('button')}: {state}")
    if rec.get("skipped"):
        parts.append("not on screen to press: " + ", ".join(rec["skipped"]))
    return "; ".join(parts)


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


def coverage(surfaces: list[dict], presses: list[dict], scripted: list[dict] | None = None) -> dict:
    """{surfaces: [...pressed, fired, actions_pressed, scripted?], pressed, total, gaps: ["Pass: never pressed ..."],
    scripted_presses}. `presses` are every real click of the round (the event log's ui_press, the scripted pass
    included); `scripted` is ai.ui_pass's record, summarised per surface."""
    by_surface = {r.get("surface"): r for r in scripted or [] if isinstance(r, dict)}
    out, gaps = [], []
    for s in surfaces or []:
        hits = [(h, p) for p in presses or [] if isinstance(p, dict) for h in [_hits(s, p)] if h]
        fired = [p for _, p in hits if p.get("fired")]
        actions = sorted({str(p.get("text") or p.get("path")) for h, p in hits if h == "action"})
        item = {"name": s["name"], "gui": s.get("gui", ""), "assigned": s.get("assigned"),
                "presses": len(hits), "fired": len(fired),
                "changed": sum(1 for p in fired if p.get("changed")), "actions_pressed": actions,
                "actions": s.get("actions") or []}
        if s["name"] in by_surface:
            item["scripted"] = pass_note(by_surface[s["name"]])
        out.append(item)
        label = s["name"] + (f" ({s['gui']})" if s.get("gui") else "")
        if not hits:
            blocked = (by_surface.get(s["name"]) or {}).get("blocked")
            why = f"; {blocked}" if blocked else "" if s.get("assigned") else "; no tester could press UI this run"
            gaps.append(f"{label}: never pressed, its panel was never opened{why}")
        elif not fired:
            gaps.append(f"{label}: pressed {len(hits)}x but the button never fired")
        else:
            done = {a.lower() for a in actions}
            missing = [a for a in s.get("actions") or [] if a.lower() not in done]
            if missing:
                gaps.append(f"{label}: opened, but {', '.join(missing)} never pressed")
    return {"surfaces": out, "pressed": sum(1 for x in out if x["presses"]), "total": len(out), "gaps": gaps,
            "scripted_presses": sum(len(r.get("presses") or []) for r in by_surface.values())}
