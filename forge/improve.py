"""The self-improving loop on top of mubit-tester (docs/MUBIT_LOOP.md).

One cycle:
    plant known faults (live config) -> N playtest rounds -> auditor finds anomalies
    -> score against the planted faults -> missed faults become corrected auditor calls
    -> detected faults are fixed (config restored) -> one more round -> verifier judges each fix
    -> runs/<slug>/improve/<cycle>.json + scores.json, playbook.md updated for the next cycle

Every LLM call goes through Mubit under the fixed `auditor` / `verifier` prompts, so each one is an
example in that role's Mubit task. Corrections are new calls in the same task. Faults are planted
through ForgeTest's `config` command, which only lasts while play runs, so a cycle keeps one play
session open from planting to the last round.
"""

from __future__ import annotations

import asyncio
import json
from collections import Counter
from pathlib import Path
from typing import Any, Awaitable, Callable

from forge.config import Settings
from forge.llm import LLM
from forge.memory import RunStore, now_iso

AUDIT_KEYS = ["summary", "anomalies"]
VERIFY_KEYS = ["verdict", "evidence"]
VERDICTS = ("fixed", "not_fixed", "regression", "inconclusive")
FAULTS_DIR = Path(__file__).parent / "faults"
MAX_ROUND_ERRORS = 3

Playtest = Callable[..., Awaitable[dict]]


# ---------------------------------------------------------------- digests


def round_digest(report: dict, n: int) -> dict:
    """The compact, code-free view of one playtest report that the auditor and verifier read."""
    probe = report.get("probe") or {}
    errors = [e for e in (probe.get("errors") or []) if e]
    messages = [str(e.get("message", e) if isinstance(e, dict) else e)[:200] for e in errors]
    kinds = Counter(str(e.get("kind")) for e in (report.get("events") or []) if isinstance(e, dict))
    return {
        "round": n,
        "goal": report.get("goal", ""),
        "goal_met": report.get("goal_met"),
        "players": len(report.get("players") or []),
        "counters": report.get("counters") or probe.get("counters") or {},
        "errors": {"count": len(errors), "first": messages[:MAX_ROUND_ERRORS]},
        "bugs": [{"title": b.get("title", ""), "severity": b.get("severity", "")}
                 for b in (report.get("bugs") or []) if isinstance(b, dict)],
        "events": dict(kinds),
    }


def _digests_block(title: str, digests: list[dict]) -> str:
    lines = [f"## {title}"] + [json.dumps(d, ensure_ascii=False) for d in digests]
    return "\n".join(lines)


# ---------------------------------------------------------------- auditor / verifier calls


def _game_block(spec: dict) -> str:
    return f"## Game\n{spec.get('pitch', '')}\nCore loop: {spec.get('core_loop', '')}"


def audit_message(spec: dict, playbook: str, digests: list[dict], verified: list[str] | None = None) -> str:
    parts = [_game_block(spec), "## Playbook\n" + (playbook.strip() or "(empty)"),
             _digests_block("Rounds", digests)]
    if verified:
        parts.append("## Verified outcome\n" + "\n".join(f"- {v}" for v in verified))
    parts.append("Return only the audit JSON object.")
    return "\n\n".join(parts)


def _norm_anomaly(a: Any) -> dict | None:
    if not isinstance(a, dict) or not a.get("title"):
        return None
    sev = str(a.get("severity") or "medium").lower()
    return {
        "kind": str(a.get("kind") or ""), "system": str(a.get("system") or "").lower(),
        "title": str(a["title"]), "expected": str(a.get("expected") or ""),
        "observed": str(a.get("observed") or ""),
        "severity": sev if sev in ("high", "medium", "low") else "medium",
    }


def audit(llm: LLM, spec: dict, playbook: str, digests: list[dict], *, session_id: str,
          verified: list[str] | None = None) -> dict:
    obj, res = llm.complete_json("auditor", audit_message(spec, playbook, digests, verified),
                                 session_id=session_id, required=AUDIT_KEYS, max_tokens=2048)
    anomalies = [a for a in (_norm_anomaly(x) for x in obj.get("anomalies") or []) if a]
    return {"summary": str(obj.get("summary") or ""), "anomalies": anomalies,
            "request_id": res.request_id}


def verify_message(anomaly: dict, change: str, before: list[dict], after: list[dict]) -> str:
    return "\n\n".join([
        "## Anomaly\n" + json.dumps(anomaly, ensure_ascii=False),
        "## Change\n" + change,
        _digests_block("Before", before),
        _digests_block("After", after),
        "Return only the verdict JSON object.",
    ])


def verify(llm: LLM, anomaly: dict, change: str, before: list[dict], after: list[dict], *,
           session_id: str) -> dict:
    obj, res = llm.complete_json("verifier", verify_message(anomaly, change, before, after),
                                 session_id=session_id, required=VERIFY_KEYS, max_tokens=1024)
    verdict = str(obj.get("verdict") or "").lower()
    return {"verdict": verdict if verdict in VERDICTS else "inconclusive",
            "evidence": str(obj.get("evidence") or ""),
            "regressions": [str(r) for r in (obj.get("regressions") or []) if r],
            "request_id": res.request_id}


# ---------------------------------------------------------------- faults


def load_faults(slug: str, path: Path | None = None) -> list[dict]:
    """Faults for a game: forge/faults/<slug>.json unless a path is given."""
    data = json.loads(Path(path or FAULTS_DIR / f"{slug}.json").read_text(encoding="utf-8"))
    faults = data.get("faults") if isinstance(data, dict) else data
    for f in faults:
        missing = [k for k in ("id", "module", "key", "value", "systems", "match", "symptom")
                   if k not in f]
        if missing:
            raise ValueError(f"fault {f.get('id', '?')}: missing {', '.join(missing)}")
    return faults


def default_faults(faults: list[dict], only: list[str] | None = None) -> list[dict]:
    """The faults to plant: the named ones, else every fault not marked "default": false."""
    if only:
        unknown = set(only) - {f["id"] for f in faults}
        if unknown:
            raise ValueError(f"unknown fault ids: {', '.join(sorted(unknown))}")
        return [f for f in faults if f["id"] in only]
    return [f for f in faults if f.get("default", True)]


async def plant(harness, faults: list[dict]) -> dict[str, Any]:
    """Set each fault's config value live; return {fault id: the value it replaced}."""
    keys = [(f["module"], f["key"]) for f in faults]
    if len(keys) != len(set(keys)):
        raise ValueError("two faults set the same config key; plant them in separate cycles")
    old: dict[str, Any] = {}
    for f in faults:
        res = await harness.call("config", module=f["module"], key=f["key"], value=f["value"])
        old[f["id"]] = (res or {}).get("old")
    return old


async def clear(harness, faults: list[dict], old: dict[str, Any]) -> None:
    for f in faults:
        if f["id"] in old and old[f["id"]] is not None:
            await harness.call("config", module=f["module"], key=f["key"], value=old[f["id"]])


def matches(anomaly: dict, fault: dict) -> bool:
    """A fault is detected by an anomaly in one of its systems that names one of its keywords."""
    if anomaly["system"] not in [s.lower() for s in fault["systems"]]:
        return False
    text = " ".join((anomaly["title"], anomaly["expected"], anomaly["observed"])).lower()
    return any(k.lower() in text for k in fault["match"])


def score(anomalies: list[dict], faults: list[dict]) -> dict:
    detected = {f["id"]: next((i for i, a in enumerate(anomalies) if matches(a, f)), None)
                for f in faults}
    used = {i for i in detected.values() if i is not None}
    return {
        "planted": len(faults),
        "detected": sorted(fid for fid, i in detected.items() if i is not None),
        "missed": sorted(fid for fid, i in detected.items() if i is None),
        "anomaly_for": {fid: i for fid, i in detected.items() if i is not None},
        "unmatched_anomalies": [i for i in range(len(anomalies)) if i not in used],
    }


# ---------------------------------------------------------------- run state


class ImproveStore:
    def __init__(self, settings: Settings, slug: str):
        self.run = RunStore(settings, slug)
        self.dir = self.run.dir / "improve"
        self.scores_path = self.dir / "scores.json"
        self.playbook_path = self.dir / "playbook.md"

    def scores(self) -> list[dict]:
        if not self.scores_path.exists():
            return []
        return json.loads(self.scores_path.read_text(encoding="utf-8"))

    def playbook(self) -> str:
        return self.playbook_path.read_text(encoding="utf-8") if self.playbook_path.exists() else ""

    def save_cycle(self, cycle: dict) -> Path:
        self.dir.mkdir(parents=True, exist_ok=True)
        path = self.dir / f"{cycle['cycle']}.json"
        path.write_text(json.dumps(cycle, indent=2, ensure_ascii=False), encoding="utf-8")
        row = {k: cycle[k] for k in ("cycle", "ts", "planted", "detected", "missed",
                                     "unmatched", "fixed_verified")}
        self.scores_path.write_text(json.dumps(self.scores() + [row], indent=2), encoding="utf-8")
        return path

    def learn(self, lessons: list[str]) -> None:
        """Fast learning: lessons from missed faults go into the next audit's playbook."""
        known = self.playbook()
        new = [ln for ln in lessons if ln and ln not in known]
        if new:
            self.dir.mkdir(parents=True, exist_ok=True)
            self.playbook_path.write_text(known + "".join(f"- {ln}\n" for ln in new),
                                          encoding="utf-8")


# ---------------------------------------------------------------- one cycle


async def _rounds(settings, playtest: Playtest, n: int, start: int, *, goal: str, players, steps: int,
                  llm, harness) -> list[dict]:
    out = []
    for i in range(n):
        rep = await playtest(settings, goal, players, steps, llm=llm, harness=harness)
        out.append(round_digest(rep, start + i))
    return out


async def run_cycle(settings: Settings, slug: str, *, llm: LLM, harness, playtest: Playtest,
                    faults: list[dict], goal: str, rounds: int = 3, players=None, steps: int = 15,
                    log: Callable[[str], None] = print) -> dict:
    store = ImproveStore(settings, slug)
    spec = store.run.load_spec() if store.run.spec_path.exists() else {"pitch": slug, "core_loop": ""}
    n = len(store.scores()) + 1
    session_id = f"improve-{slug}-{n}"

    await harness.ensure_ready()
    old = await plant(harness, faults)
    log(f"[cycle {n}] planted {len(faults)} faults: {', '.join(f['id'] for f in faults)}")
    try:
        before = await _rounds(settings, playtest, rounds, 1, goal=goal, players=players,
                               steps=steps, llm=llm, harness=harness)
        found = await asyncio.to_thread(audit, llm, spec, store.playbook(), before,
                                        session_id=session_id)
        sc = score(found["anomalies"], faults)
        log(f"[auditor] {len(found['anomalies'])} anomalies, detected {len(sc['detected'])}/"
            f"{len(faults)} {found['request_id']}")

        by_id = {f["id"]: f for f in faults}
        correction = None
        if sc["missed"]:
            verified = [by_id[fid]["symptom"] for fid in sc["missed"]]
            correction = await asyncio.to_thread(audit, llm, spec, store.playbook(), before,
                                                 session_id=session_id, verified=verified)
            log(f"[auditor] correction for missed {', '.join(sc['missed'])} "
                f"{correction['request_id']}")

        fixed_faults = [by_id[fid] for fid in sc["detected"]]
        await clear(harness, fixed_faults, old)
        verdicts = []
        if fixed_faults:
            after = await _rounds(settings, playtest, 1, rounds + 1, goal=goal, players=players,
                                  steps=steps, llm=llm, harness=harness)
            for f in fixed_faults:
                anomaly = found["anomalies"][sc["anomaly_for"][f["id"]]]
                change = f"{f['module']}.{f['key']} set back to {old.get(f['id'])!r}"
                v = await asyncio.to_thread(verify, llm, anomaly, change, before, after,
                                            session_id=session_id)
                verdicts.append({"fault": f["id"], **v})
                log(f"[verifier] {f['id']}: {v['verdict']} {v['request_id']}")
    finally:
        await clear(harness, faults, old)

    store.learn([by_id[fid].get("lesson", "") for fid in sc["missed"]])
    cycle = {
        "cycle": n, "ts": now_iso(), "session_id": session_id, "goal": goal,
        "planted": len(faults), "detected": len(sc["detected"]), "missed": len(sc["missed"]),
        "unmatched": len(sc["unmatched_anomalies"]),
        "fixed_verified": sum(1 for v in verdicts if v["verdict"] == "fixed"),
        "score": sc, "audit": found, "correction": correction, "verdicts": verdicts,
        "before": before,
    }
    path = store.save_cycle(cycle)
    log(f"[cycle {n}] detected {cycle['detected']}/{cycle['planted']}, unmatched anomalies "
        f"{cycle['unmatched']}, fixed+verified {cycle['fixed_verified']} -> {path}")
    return cycle
