"""Acceptance the playtests can test, and the readiness profile built on it.

A real 100-stage park obby promised costume_buy, gift_ready, gift_claimed and achievement_unlocked in its
acceptance. Nothing ever exercised the last three, the critic rubric caps a game at 5-6 while an acceptance
counter reads 0, and the score sat at 6/10 for four rounds. So each acceptance counter names how it is
exercised, the ones with no exerciser leave acceptance (recorded in spec["acceptance_untested"], production
guide 8.3/9.3: an unexercised case is unknown, never silently dropped), and readiness reads a profile
(GAME_PRODUCTION_GUIDE.md section 11), not one critic number.

    exerciser(counter, spec) -> (path, how)       path "" = nothing exercises it, how = why
    testable_block(kits) -> str                   director/designer user-message block
    restrict(spec) -> spec                        acceptance + first_60s keep only testable counters
    game_errors(iteration) -> int                 a round's errors, Forge's own harness left out
    profile(spec, iteration, qa, errors) -> dict  acceptance met/testable, QA bots reached, errors, score
    profile_text(profile) -> str                  "score 6/10, acceptance 12/13, QA 4/6, 0 errors"
No LLM calls here.
"""

from __future__ import annotations

import re

from forge import rounds

HEADLESS = "headless smoke"   # forge/smoke.py: the scripted player in every scoring playtest
JOURNEY = "Studio journey"    # mubit_tester/studio_service.py QA_JOURNEY, after each install
QA_BOTS = "Studio QA bots"    # mubit_tester/studio_service.py qa_swarm: obby_try from each zone's first stage

# counter -> (kit module that fires it, path, how). From the run that plateaued: the smoke met stages_built,
# coins, checkpoints, jump pads and falls in round 1; trampolines, gates and the finish only after Studio play.
KIT_TESTS: dict[str, tuple[str, str, str]] = {
    "stages_built": ("ObbyKit", HEADLESS, "fires when the course builds at startup"),
    "coin_collected": ("ObbyKit", HEADLESS, "the smoke player walks to Coin-tagged parts"),
    "checkpoint_reached": ("ObbyKit", HEADLESS, "the smoke player and bots run stage to stage"),
    "jump_pad_used": ("ObbyKit", HEADLESS, "the smoke's sampled stage runs cross jump pads"),
    "player_fell": ("ObbyKit", HEADLESS, "the smoke's stage runs fall and return to the checkpoint"),
    "player_died": ("ObbyKit", QA_BOTS, "QA bots hit kill parts in Studio (headless fires no touches)"),
    "trampoline_bounce": ("ObbyKit", QA_BOTS, "QA bots run each zone's stages in Studio"),
    "ride_gate_used": ("ObbyKit", JOURNEY, "the journey takes zone 1's ride gate"),
    "zone_cleared": ("ObbyKit", JOURNEY, "the journey's ride gate clears zone 1"),
    "ride_entrance_used": ("ObbyKit", JOURNEY, "the journey takes the next zone's entrance"),
    "obby_finished": ("ObbyKit", JOURNEY, "the journey touches the last stage"),
    "park_finished": ("ParkObby", JOURNEY, "the journey touches the last stage"),
    "costume_buy": ("Cosmetics", JOURNEY, "the journey buys the cheapest costume through CosmeticsRemotes"),
    "costume_equip": ("Cosmetics", JOURNEY, "the journey wears the costume it bought"),
    "ride_entrance_locked": ("ObbyKit", "", "needs a player at a ride entrance before its stage; no tester does"),
    "reset_used": ("ParkObby", "", "needs the HUD reset button pressed; no tester presses it"),
}
# gated on time or whole sessions, coder-written per game: no tester waits for them
UNTESTED = {
    "gift_ready": "the gift is coder-written per game and needs a timed wait; no tester waits for it",
    "gift_claimed": "the gift is coder-written per game and needs a timed wait; no tester claims it",
    "achievement_unlocked": "achievements need whole sessions of play; no tester earns one",
}
GENERIC = "the smoke's generic play: UI presses, pickups, the nearest prompt or touch"
OBBY_NONE = ("no tester does it: the smoke plays the course, the Studio journey takes the gates, the costume shop "
             "and the finish, the QA bots run stages")
CLAUSE_SPLIT = re.compile(r";\s*|,\s*")
HARNESS = re.compile(r"Forge(Test|Probe|TestAgent|Telemetry)\b")
OR_RX = re.compile(r"\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\s+or\s+[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b")


def _kits(spec: dict) -> set[str]:
    return {m.get("kit") for m in spec.get("modules") or [] if isinstance(m, dict) and m.get("kit")}


def exerciser(counter: str, spec: dict) -> tuple[str, str]:
    """(path, how) for one acceptance counter of this game; path "" = nothing exercises it, how says why."""
    if counter in UNTESTED:
        return "", UNTESTED[counter]
    kits = _kits(spec)
    if counter in KIT_TESTS:
        kit, path, how = KIT_TESTS[counter]
        if kit in kits:
            return path, how
        if "ObbyKit" in kits:
            return "", f"the game has no {kit} kit module, and {OBBY_NONE}"
    if "ObbyKit" in kits:
        return "", OBBY_NONE
    return HEADLESS, GENERIC


def testable_block(kits: list[dict]) -> str:
    """'## Acceptance a playtest can test' for director/designer user messages ("" for games with no obby kit:
    their counters are played by the smoke's generic pass)."""
    spec = {"modules": [{"kit": e["name"]} for e in kits]}
    if "ObbyKit" not in _kits(spec):
        return ""
    by_path: dict[str, list[str]] = {}
    for c in sorted(KIT_TESTS):
        path, _ = exerciser(c, spec)
        by_path.setdefault(path, []).append(c)
    lines = ["## Acceptance a playtest can test (name only these counters in acceptance and first_60_seconds)"]
    lines += [f"- {p}: {', '.join(cs)}" for p, cs in by_path.items() if p]
    untested = by_path.get("", []) + sorted(UNTESTED)
    lines.append(f"- Nothing exercises: {', '.join(untested)}, nor any counter the kits do not fire. Forge drops "
                 "acceptance criteria that name them.")
    return "\n".join(lines) + "\n"


def _untested_in(text: str, spec: dict) -> list[str]:
    named = rounds.COUNTER_RX.findall(text)
    out = [c for c in named if not exerciser(c, spec)[0]]
    # "player_fell or player_died": one testable alternative keeps the clause
    for alt in OR_RX.findall(text):
        a, b = alt.split(" or ")[0].strip(), alt.split(" or ")[-1].strip()
        if exerciser(a, spec)[0] or exerciser(b, spec)[0]:
            out = [c for c in out if c not in (a, b)]
    return list(dict.fromkeys(out))


def restrict(spec: dict) -> dict:
    """Acceptance keeps only counters a playtest exercises: a criterion naming an untested counter loses that
    clause (or the whole line when nothing testable is left). Each removal goes to spec["acceptance_untested"]
    as {criterion, counters, reason}; a first-60-seconds beat keeps its text but drops an untested counter."""
    dropped = list(spec.get("acceptance_untested") or [])
    kept = []
    for line in spec.get("acceptance") or []:
        text = str(line)
        if not _untested_in(text, spec):
            kept.append(text)
            continue
        clauses = [re.sub(r"^and\s+", "", c.strip()) for c in CLAUSE_SPLIT.split(text) if c.strip()]
        keep = []
        for c in clauses:
            bad = _untested_in(c, spec)
            if bad:
                dropped.append({"criterion": c, "counters": bad,
                                "reason": "; ".join(f"{b}: {exerciser(b, spec)[1]}" for b in bad)})
            else:
                keep.append(c)
        if any(rounds.COUNTER_RX.search(c) for c in keep):
            kept.append(", ".join(keep))
        elif keep:
            dropped.append({"criterion": ", ".join(keep), "counters": [],
                            "reason": "left with no testable counter once the untested clauses were dropped"})
    beats = []
    for b in spec.get("first_60s") or []:
        c = b.get("counter") if isinstance(b, dict) else None
        if c and not exerciser(c, spec)[0]:
            dropped.append({"criterion": f"first 60 seconds: {b.get('beat')}", "counters": [c],
                            "reason": f"{c}: {exerciser(c, spec)[1]}"})
            b = {**b, "counter": "", "min": 0}
        beats.append(b)
    spec["acceptance"] = kept
    if "first_60s" in spec:
        spec["first_60s"] = beats
    if dropped:
        spec["acceptance_untested"] = dropped
    return spec


def game_errors(iteration: dict | None) -> int:
    """Errors in a round's playtest that are the game's: Forge's own test harness is not the game."""
    return len([e for e in (iteration or {}).get("errors") or [] if not HARNESS.search(str(e))])


def profile(spec: dict, iteration: dict | None, qa: dict | None, errors: int) -> dict:
    """The readiness profile of the latest round: acceptance met / testable (counters a playtest exercises),
    Studio QA bots that reached the next checkpoint, game errors, critic score."""
    acc = (iteration or {}).get("acceptance") or {}
    met = [c for c in acc.get("met") or [] if exerciser(c, spec)[0]]
    missing = [c for c in acc.get("missing") or [] if exerciser(c, spec)[0]]
    bots = [b for b in (qa or {}).get("bots") or [] if isinstance(b, dict)]
    return {"score": (iteration or {}).get("score"), "errors": errors,
            "acceptance": {"met": len(met), "total": len(met) + len(missing)},
            "qa": {"reached": sum(1 for b in bots if b.get("reached")), "total": len(bots)}}


def profile_text(p: dict) -> str:
    """'score 6/10, acceptance 12/13, QA 4/6, 0 errors' (parts with no data left out)."""
    score = f"{float(p['score']):g}/10" if p.get("score") is not None else "not scored"
    parts = [f"score {score}"]
    if p["acceptance"]["total"]:
        parts.append(f"acceptance {p['acceptance']['met']}/{p['acceptance']['total']}")
    if p["qa"]["total"]:
        parts.append(f"QA {p['qa']['reached']}/{p['qa']['total']}")
    parts.append(f"{p['errors']} error{'' if p['errors'] == 1 else 's'}")
    return ", ".join(parts)
