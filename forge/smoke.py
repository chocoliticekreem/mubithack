"""Smoke play: a deterministic, no-LLM player inside the scoring playtest, so the critic scores a game somebody
played. Before it, the player stood idle: the core-loop counters stayed absent (funfair obby: "coin_collected,
checkpoint_reached, player_died, zone_entered, item_bought are absent", scored 6, then 4 blind, and the score drop
rolled the iteration back).

Run.playtest calls smoke_play right after the game is ready and before the ForgeProbe report is read, so the
counters in the report include what was played; report["smoke"] says what that was. Only the ForgeTest harness
(Server datamodel, mubit_tester.harness) and its macros are used. Each step runs only when the game has the thing:
  1. players  the player and one observation (things, touchables, prompts, ui, obby);
  2. ui       the main visible UI surfaces pressed once with real clicks (mubit_tester.ai.ui_pass); skipped, with
              the reason, when the game view is not rendering or no Studio window drives the player;
  3. pickups  walk to the nearest Coin-tagged parts (else touchable parts that are not hazards);
  4. obby     (Checkpoint tags) the player runs stage 0 -> 1 from spawn while one bot tester per sampled stage
              (stage 1, about every tenth of the course, the last but one) runs that stage to the next checkpoint,
              all in one `multi` call; then the player touches one KillPart: death, respawn at their checkpoint;
  5. other    games without checkpoints: go_use the nearest prompt, else go_touch the nearest touchable.
Never raises: a failure is a recorded step. Budget: FORGE_SMOKE_SECONDS (default 45 s, 0 = off).
"""

from __future__ import annotations

import asyncio
import math
import os
import re
import time
from pathlib import Path
from typing import Any

DEFAULT_SECONDS = 45.0
OVERRUN = 20.0          # a macro started near the deadline may finish; past budget + this the smoke is cut
CALL_TIMEOUT = 20.0     # one quick harness command (players, observe, query, counters)
UI_SURFACES = 3
UI_MAX = 12.0           # most of the budget is for the core loop, not the menus
PICKUPS = 3
PICKUP_TIMEOUT = 6.0    # one walk to a pickup
PICKUP_RANGE = 90.0     # studs: about what a player walks in PICKUP_TIMEOUT
PICKUPS_MAX = 14.0
OBBY_RESERVE = 20.0     # an obby keeps this much of the budget for its runs and the kill-part check
SAMPLES = 11
RUN_TIMEOUT = 12.0      # one obby_try attempt: a checkpoint to the next one
ATTEMPTS = 2            # one random fall does not fail a stage
RESPAWN_WAIT = 8.0
POLL = 0.4              # seconds between `players` reads while waiting for a death / a respawn
SETTLE = 1.0            # after a respawn: the game moves the fresh character to its checkpoint
PROMPT_TIMEOUT = 10.0
HAZARD = re.compile(r"kill|lava|death|hazard|damage|spike|void|acid", re.IGNORECASE)
NO_STAGE_0 = "no checkpoint with Stage 0"  # a game's harness copy from before stage 0 = the course start


def smoke_seconds() -> float:
    """FORGE_SMOKE_SECONDS: the smoke play's budget inside a scoring playtest (0 turns it off)."""
    try:
        return max(0.0, float(os.environ.get("FORGE_SMOKE_SECONDS", DEFAULT_SECONDS)))
    except ValueError:
        return DEFAULT_SECONDS


def sample_stages(max_stage: int, n: int = SAMPLES) -> list[int]:
    """Start stages for the course sample: 1, about every tenth of the course, and the last but one."""
    if max_stage < 2:
        return []
    step = max(1, round(max_stage / max(1, n - 1)))
    picks = {1, max_stage - 1} | set(range(step, max_stage - 1, step))
    return sorted(s for s in picks if 1 <= s < max_stage)[:n]


def _clip(v: Any, n: int) -> str:
    s = " ".join(str(v).split())
    return s if len(s) <= n else s[: n - 3] + "..."


def _err(e: BaseException) -> str:
    return _clip(f"{type(e).__name__}: {e}", 200)


def _tail(path: Any, parts: int = 3) -> str:
    return ".".join(str(path or "?").split(".")[-parts:])


def _xyz(v: Any) -> str:
    if isinstance(v, (list, tuple)) and len(v) == 3:
        return "[" + ", ".join(f"{float(x):.0f}" for x in v) + "]"
    return "?"


def _num(v: Any) -> float | None:
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def delta(before: dict, after: dict) -> dict:
    """{counter: change} for the counters that changed between two `counters` reads."""
    out = {}
    for k, v in (after or {}).items():
        new, old = _num(v), _num((before or {}).get(k, 0))
        if new is not None and old is not None and new != old:
            out[k] = round(new - old, 2)
    return out


def _effect(res: Any) -> str:
    """' (coin_collected 0->1, Coins 0->1)': what a macro changed, from its `effect`."""
    eff = (res or {}).get("effect") if isinstance(res, dict) else None
    if not isinstance(eff, dict):
        return ""
    parts = []
    for key in ("counters", "leaderstats"):
        for k, v in (eff.get(key) or {}).items():
            if isinstance(v, list) and len(v) == 2:
                parts.append(f"{k} {v[0]}->{v[1]}")
    return f" ({', '.join(parts[:6])})" if parts else ""


def _available(row: dict) -> bool:
    attrs = row.get("attrs") or {}
    return attrs.get("Available") is not False and not attrs.get("Collected")


def _where(attempt: dict, to: Any) -> str:
    """Where a sampled run ended: the hazard it fell on, the ground it stood on last, or where it got stuck."""
    at = _xyz(attempt.get("at"))
    if attempt.get("result") == "reached":
        return f"on checkpoint {to}"
    if attempt.get("hazard"):
        return f"hazard {_tail(attempt['hazard'])} at {at}"
    floor = f", last ground {_tail(attempt['last_floor'])}" if attempt.get("last_floor") else ""
    short = f", {attempt['dist']:.0f} studs short" if _num(attempt.get("dist")) is not None else ""
    return f"at {at}{floor}{short}"


def _zone_list(runs: list[dict]) -> list:
    return sorted({r["zone"] for r in runs if "zone" in r}, key=lambda z: (_num(z) is None, _num(z) or 0, str(z)))


def spec_first(counters: dict, spec: dict) -> dict:
    """The same counters, the ones the spec names (acceptance, core loop) first: they are the evidence."""
    text = " ".join([str(spec.get("core_loop") or "")] + [str(a) for a in spec.get("acceptance") or []])
    named = {k for k in counters if re.search(rf"\b{re.escape(k)}\b", text)}
    return {k: counters[k] for k in sorted(counters, key=lambda k: k not in named)}


def _sample(reply: Any, start: int, by: str, zones: dict[int, Any]) -> dict:
    """One obby_try reply (a `multi` item {ok, result | error}) -> {from, to, by, result, where, secs, zone}."""
    if not isinstance(reply, dict) or not reply.get("ok"):
        err = reply.get("error") if isinstance(reply, dict) else reply
        return {"from": start, "to": None, "by": by, "result": "error", "where": _clip(err, 160), "secs": None}
    r = reply.get("result") or {}
    tries = [a for a in r.get("attempts") or [] if isinstance(a, dict)]
    last = tries[-1] if tries else {}
    to = r.get("to_stage")
    result = "reached" if r.get("reached") else str(last.get("result") or "stuck")
    out = {"from": r.get("from_stage", start), "to": to, "by": by, "result": result,
           "where": _where({**last, "result": result}, to), "secs": last.get("secs"), "attempts": len(tries)}
    if to in zones:
        out["zone"] = zones[to]
    return out


class _Smoke:
    def __init__(self, studio: Any, spec: dict, game_dir: Path | str | None, budget: float, out: dict):
        self.studio, self.spec, self.game_dir, self.out = studio, spec or {}, game_dir, out
        self.deadline = time.monotonic() + budget
        self.h: Any = None
        self.uid: Any = None
        self.name = ""
        self.spawn: Any = None
        self.c0: dict | None = None
        self.bots_spawned = False

    def left(self) -> float:
        return self.deadline - time.monotonic()

    def step(self, what: str, ok: bool, detail: str, t0: float) -> None:
        self.out["steps"].append({"what": what, "ok": bool(ok), "detail": _clip(detail, 600),
                                  "secs": round(time.monotonic() - t0, 1)})

    def skip(self, what: str, why: str) -> None:
        self.out["steps"].append({"what": what, "ok": False, "skipped": True, "detail": _clip("skipped: " + why, 400),
                                  "secs": 0.0})

    async def counters(self) -> dict | None:
        try:
            got = await self.h.counters()
            return got if isinstance(got, dict) else None
        except Exception:  # noqa: BLE001 - counters are evidence, not a step
            return None

    async def player(self) -> dict | None:
        """The smoke player's current `players` row (pos, health, attrs such as Stage), or None."""
        try:
            rows = await self.h.players()
        except Exception:  # noqa: BLE001
            return None
        return next((p for p in rows or [] if isinstance(p, dict) and p.get("userId") == self.uid), None)

    async def alive(self, timeout: float) -> dict | None:
        """The player's row once they have a living character (a respawn takes a few seconds), else None."""
        end = time.monotonic() + max(0.0, min(timeout, self.left()))
        while True:
            me = await self.player()
            if me is not None and me.get("hasCharacter", True) and (_num(me.get("health")) or 0) > 0:
                return me
            if time.monotonic() >= end:
                return None
            await asyncio.sleep(POLL)

    async def act(self, action: str, /, **args: Any) -> dict:
        try:
            res = await self.h.act(self.uid, action, **args)
            return res if isinstance(res, dict) else {"done": False, "detail": _clip(res, 200)}
        except Exception as e:  # noqa: BLE001 - recorded on the step
            return {"done": False, "detail": "error: " + _err(e)}

    # ------------------------------------------------------------------ the run

    async def run(self) -> None:
        from mubit_tester.harness import Harness

        self.h = Harness(self.studio, timeout=CALL_TIMEOUT)
        self.c0 = await self.counters()
        obs = await self.find_player()
        if obs is None:
            return
        obby = obs.get("obby") if isinstance(obs.get("obby"), dict) else None
        reserve = OBBY_RESERVE if obby else PROMPT_TIMEOUT
        await self.guard("ui", self.ui(obs, reserve + PICKUP_TIMEOUT))
        await self.guard("pickups", self.pickups(obs, reserve))
        if obby:
            await self.guard("obby", self.obby(obby))
            await self.guard("kill part", self.kill_part())
        else:
            await self.guard("core loop", self.other(obs))

    async def guard(self, what: str, coro: Any) -> None:
        """One step's own failure is that step's result; the next steps still run."""
        t0 = time.monotonic()
        try:
            await coro
        except Exception as e:  # noqa: BLE001
            self.step(what, False, "error: " + _err(e), t0)

    async def finish(self) -> None:
        if self.h is None:
            return
        if self.bots_spawned:
            try:
                await self.h.call("bot_clear")
            except Exception as e:  # noqa: BLE001
                self.out["bot_clear_error"] = _err(e)
        c1 = await self.counters()
        if self.c0 is not None and c1 is not None:
            self.out["counters_delta"] = spec_first(delta(self.c0, c1), self.spec)

    async def find_player(self) -> dict | None:
        t0 = time.monotonic()
        try:
            rows = await self.h.players()
        except Exception as e:  # noqa: BLE001
            self.step("players", False, "players failed: " + _err(e), t0)
            return None
        real = [p for p in rows or [] if isinstance(p, dict) and not p.get("bot") and p.get("userId") is not None]
        if not real:
            self.step("players", False, "no player in the game", t0)
            return None
        me = real[0]
        self.uid, self.name, self.spawn = me["userId"], str(me.get("name") or me["userId"]), me.get("pos")
        try:
            obs = await self.h.observe(self.uid)
        except Exception as e:  # noqa: BLE001
            obs = {"error": _err(e)}
        obs = obs if isinstance(obs, dict) else {}
        sees = []
        if isinstance(obs.get("obby"), dict):
            sees.append(f"an obby of {obs['obby'].get('max_stage')} stages")
        for key in ("prompts", "touchables", "ui"):
            if obs.get(key):
                sees.append(f"{len(obs[key])} {'buttons' if key == 'ui' else key}")
        self.step("players", True, f"{len(real)} player(s); {self.name} at {_xyz(self.spawn)}; sees "
                  + (", ".join(sees) or "nothing to use nearby") + (f"; observe: {obs['error']}" if obs.get("error") else ""),
                  t0)
        return obs

    async def ui(self, obs: dict, reserve: float) -> None:
        """Press the main visible UI surfaces once (scripted, real clicks), then close what they opened."""
        from mubit_tester import ai
        from mubit_tester import surfaces as ui_surfaces

        t0 = time.monotonic()
        buttons = [b for b in obs.get("ui") or [] if isinstance(b, dict)]
        if obs.get("ui_error"):
            return self.skip("ui", "no clicks can land: " + str(obs["ui_error"]))
        if not buttons:
            return self.skip("ui", "no on-screen buttons")
        try:
            windows = await self.h.ui_windows()
        except Exception as e:  # noqa: BLE001
            windows = {}
            self.out.setdefault("notes", []).append("ui_windows: " + _err(e))
        if str(self.uid) not in (windows or {}):
            return self.skip("ui", "no Studio window drives this player, so a real click can't land")
        roster = [{"name": self.name, "userId": self.uid, "can_press": True}]
        found = ui_surfaces.assign_surfaces(
            ui_surfaces.derive_surfaces(self.spec, self.game_dir, [obs], limit=UI_SURFACES), roster)
        if not found:
            return self.skip("ui", f"{len(buttons)} buttons, but none is a UI surface")
        end = time.monotonic() + max(0.0, min(UI_MAX, self.left() - reserve))
        recs, notes = [], []
        for s in found:
            room = end - time.monotonic()
            if room < 3:
                notes.append(f"{s['name']}: not pressed (budget)")
                continue
            try:
                recs += await asyncio.wait_for(ai.ui_pass(self.h, [s], roster), timeout=room)
            except Exception as e:  # noqa: BLE001 - incl. the cap's TimeoutError
                notes.append(f"{s['name']}: {_err(e)}")
        fired = sum(1 for r in recs for p in r.get("presses") or [] if p.get("fired"))
        lines = [f"{r['surface']}: {ui_surfaces.pass_note(r)}" for r in recs] + notes
        self.step("ui", fired > 0, f"{fired} press(es) fired; " + "; ".join(lines), t0)

    async def pickups(self, obs: dict, reserve: float) -> None:
        """Walk to the nearest Coin-tagged parts (by position: same-named coins share a path), else go_touch the
        nearest touchables that are not hazards."""
        t0 = time.monotonic()
        try:
            rows = await self.h.query(tag="Coin", near=self.uid, limit=PICKUPS * 3, attrs=["Available", "Collected"])
        except Exception:  # noqa: BLE001
            rows = []
        coins = [r for r in rows or [] if isinstance(r, dict) and r.get("pos") and _available(r)
                 and (_num(r.get("dist")) or 0) <= PICKUP_RANGE][:PICKUPS]
        hazards = {h.get("path") for h in ((obs.get("obby") or {}).get("hazards") or []) if isinstance(h, dict)}
        touch = [x for x in obs.get("touchables") or [] if isinstance(x, dict) and x.get("touch") and x.get("path")
                 and x["path"] not in hazards and not HAZARD.search(str(x.get("name") or ""))][:PICKUPS]
        targets, kind = (coins, "Coin") if coins else (touch, "touchable")
        if not targets:
            return self.skip("pickups", f"no Coin-tagged part (within {PICKUP_RANGE:.0f} studs) or touchable pickup "
                             "near the player")
        end = time.monotonic() + max(0.0, min(PICKUPS_MAX, self.left() - reserve))
        hits, notes = 0, []
        for x in targets:
            room = min(PICKUP_TIMEOUT, end - time.monotonic())
            if room < 2:
                notes.append(f"{_tail(x['path'])}: not tried (budget)")
                continue
            if kind == "Coin":
                # walk_to by position inside repeat x1: the repeat macro adds the effect diff (counters, leaderstats);
                # a coin counts when the game registered it, even if the walk stopped short
                res = await self.act("repeat", action="walk_to", times=1,
                                     args={"pos": x["pos"], "timeout": room, "arrive_radius": 0.5})
                ok = bool(_effect(res))
            else:
                res = await self.act("go_touch", path=x["path"], timeout=room)
                ok = bool(res.get("done"))
            hits += ok
            notes.append(f"{_tail(x['path'])} ({x.get('dist')} studs): {'collected' if ok else 'missed'}{_effect(res)}"
                         + ("" if ok else f" - {_clip(res.get('detail'), 120)}"))
        self.step("pickups", hits > 0, f"{hits}/{len(targets)} {kind} parts: " + "; ".join(notes), t0)

    async def zones(self) -> dict[int, Any]:
        """{stage: zone} from ObbyKit's stage models (tag ObbyStage, attributes Stage and Zone); {} without them."""
        try:
            rows = await self.h.query(tag="ObbyStage", attrs=["Stage", "Zone"], limit=1000)
        except Exception:  # noqa: BLE001
            return {}
        out = {}
        for r in rows or []:
            a = (r or {}).get("attrs") or {}
            if _num(a.get("Stage")) is not None and a.get("Zone") is not None:
                out[int(a["Stage"])] = a["Zone"]
        return out

    async def obby(self, ob: dict) -> None:
        t0 = time.monotonic()
        if self.left() < 10:
            return self.skip("obby", "budget")
        samples = sample_stages(int(_num(ob.get("max_stage")) or 0))
        zones = await self.zones()
        per = max(3.0, min(RUN_TIMEOUT, (self.left() - 10) / ATTEMPTS))
        bots: list[dict] = []
        if samples:
            try:
                bots = [b for b in await self.h.call("bot_spawn", n=len(samples), near=self.uid, radius=3) or []
                        if isinstance(b, dict) and b.get("userId") is not None]
                self.bots_spawned = bool(bots)
            except Exception as e:  # noqa: BLE001
                self.out.setdefault("notes", []).append("bot_spawn: " + _err(e))
        tries = {"attempts": ATTEMPTS, "timeout": per}
        calls = [{"cmd": "obby_try", "args": {"userId": self.uid, "from_stage": 0, **tries}}]
        calls += [{"cmd": "obby_try", "args": {"userId": b["userId"], "from_stage": s, **tries}}
                  for b, s in zip(bots, samples)]
        wait = ATTEMPTS * (per + 10) + 5  # an attempt is a teleport (a respawn at worst) and one run
        try:
            replies = await self.h.call("multi", calls=calls, timeout=wait, _timeout=wait + 15)
        except Exception as e:  # noqa: BLE001
            replies = [{"ok": False, "error": _err(e)}] * len(calls)
        replies = replies if isinstance(replies, list) else []
        replies += [{"ok": False, "error": "no reply"}] * max(0, len(calls) - len(replies))
        first, start = replies[0], 0
        if NO_STAGE_0 in str(first.get("error") if isinstance(first, dict) else ""):
            start = 1  # this game's harness copy predates stage 0: the player runs 1 -> 2 instead
            try:
                first = {"ok": True, "result": await self.h.obby_try(self.uid, from_stage=1, attempts=ATTEMPTS,
                                                                     timeout=per)}
            except Exception as e:  # noqa: BLE001
                first = {"ok": False, "error": _err(e)}
        runs = [_sample(first, start, "player", zones)]
        runs += [_sample(r, s, "bot", zones) for r, s in zip(replies[1:], samples)]
        me = await self.player()
        reached = [r for r in runs if r["result"] == "reached"]
        self.out["obby"] = {"max_stage": ob.get("max_stage"), "samples": runs, "reached": len(reached),
                            "total": len(runs), "player_stage": ((me or {}).get("attrs") or {}).get("Stage"),
                            "zones_sampled": _zone_list(runs), "zones_reached": _zone_list(reached)}
        if not bots and samples:
            self.out["obby"]["note"] = "no bot testers: only the player's run"
        self.step("obby", bool(reached), f"{len(reached)}/{len(runs)} runs reached the next checkpoint; the player's "
                  f"{runs[0]['from']}->{runs[0]['to']}: {runs[0]['result']} ({runs[0]['where']}); Stage now "
                  f"{self.out['obby']['player_stage']}", t0)

    async def kill_part(self) -> None:
        """Touch one KillPart (teleport onto it): the player should die and respawn at their checkpoint."""
        t0 = time.monotonic()
        if self.left() < 4:
            return self.skip("kill part", "budget")
        await self.alive(RESPAWN_WAIT / 2)  # `near` needs a body: the last obby run may have just died
        try:
            rows = await self.h.query(tag="KillPart", near=self.uid, limit=1)
        except Exception:  # noqa: BLE001
            rows = []
        if not rows:
            return self.skip("kill part", "no KillPart-tagged part")
        kill = rows[0]
        before = await self.alive(RESPAWN_WAIT / 2) or {}
        stage = int(_num((before.get("attrs") or {}).get("Stage")) or 0)
        c0 = await self.counters()
        try:
            await self.h.call("teleport", userId=self.uid, path=kill["path"])
        except Exception as e:  # noqa: BLE001
            return self.step("kill part", False, f"teleport onto {_tail(kill['path'])} failed: {_err(e)}", t0)
        died, back = await self._death_and_respawn()
        deaths = delta(c0 or {}, await self.counters() or {}).get("player_died")
        home, where = await self._respawn_check(back, stage)
        self.step("kill part", died and home, f"touched {_tail(kill['path'])}: " + ("died" if died else "did NOT die")
                  + (f" (player_died +{deaths:g})" if deaths else "") + "; "
                  + (f"respawned {where}" if back is not None else "no respawn seen"), t0)

    async def _death_and_respawn(self) -> tuple[bool, dict | None]:
        died, end = False, time.monotonic() + max(2.0, min(RESPAWN_WAIT, self.left()))
        while time.monotonic() < end:
            await asyncio.sleep(POLL)
            me = await self.player()
            if me is None or not me.get("hasCharacter", True) or (_num(me.get("health")) or 0) <= 0:
                died = True
            elif died:
                await asyncio.sleep(SETTLE)
                return True, await self.player() or me
        return died, None

    async def _respawn_check(self, back: dict | None, stage: int) -> tuple[bool, str]:
        """(came back where their Stage says, 'at checkpoint 3 (2 studs)' | where they are instead)."""
        if back is None:
            return False, ""
        if stage >= 1:
            try:
                near = (((await self.h.observe(self.uid)) or {}).get("obby") or {}).get("nearest") or {}
            except Exception:  # noqa: BLE001
                near = {}
            if near.get("stage") == stage and (_num(near.get("dist")) or 99) <= 15:
                return True, f"at checkpoint {stage} ({near.get('dist')} studs)"
            return False, f"NOT at checkpoint {stage}: at {_xyz(back.get('pos'))}, nearest checkpoint {near.get('stage')}"
        pos, spawn = back.get("pos"), self.spawn
        if isinstance(pos, list) and isinstance(spawn, list) and len(pos) == len(spawn) == 3:
            d = math.dist(pos, spawn)
            if d <= 15:
                return True, f"at the spawn ({d:.0f} studs)"
            return False, f"NOT at the spawn: at {_xyz(pos)}, {d:.0f} studs away"
        return False, f"at {_xyz(pos)} (no spawn position to compare)"

    async def other(self, obs: dict) -> None:
        """Games without checkpoints: use the nearest prompt, else touch the nearest touchable."""
        t0 = time.monotonic()
        room = min(PROMPT_TIMEOUT, self.left() - 1)
        if room < 2:
            return self.skip("core loop", "budget")
        prompts = [p for p in obs.get("prompts") or [] if isinstance(p, dict) and p.get("path")]
        if prompts:
            p = prompts[0]
            res = await self.act("go_use", path=p["path"], action=p.get("action"), timeout=room)
            return self.step("prompt", bool(res.get("done")), f"go_use '{p.get('action')}' on {_tail(p['path'])}: "
                             f"{_clip(res.get('detail'), 200)}{_effect(res)}", t0)
        touch = [x for x in obs.get("touchables") or [] if isinstance(x, dict) and x.get("touch") and x.get("path")
                 and not HAZARD.search(str(x.get("name") or ""))]
        if not touch:
            return self.skip("core loop", "no prompt or touchable near the player")
        res = await self.act("go_touch", path=touch[0]["path"], timeout=room)
        self.step("touch", bool(res.get("done")), f"go_touch {_tail(touch[0]['path'])}: "
                  f"{_clip(res.get('detail'), 200)}{_effect(res)}", t0)


async def smoke_play(studio: Any, spec: dict, game_dir: Path | str | None, *, budget_s: float = DEFAULT_SECONDS) -> dict:
    """Play the running game for at most ~budget_s seconds with the ForgeTest harness, no LLM. Never raises.
    -> {budget_s, secs, steps: [{what, ok, detail, secs, skipped?}], obby: {samples: [{from, to, by, result, where,
    secs, zone?}], reached, total, player_stage, zones_sampled, zones_reached} | None, counters_delta, error?}"""
    t0 = time.monotonic()
    out: dict = {"budget_s": budget_s, "steps": [], "obby": None, "counters_delta": {}}
    if budget_s <= 0:
        out["skipped"] = "off (FORGE_SMOKE_SECONDS=0)"
        return out
    s = _Smoke(studio, spec, game_dir, budget_s, out)
    try:
        await asyncio.wait_for(s.run(), timeout=budget_s + OVERRUN)
    except asyncio.TimeoutError:
        out["error"] = f"cut after {budget_s + OVERRUN:.0f}s (budget {budget_s:g}s)"
    except Exception as e:  # noqa: BLE001 - never fail the playtest
        out["error"] = _err(e)
    try:
        await asyncio.wait_for(s.finish(), timeout=CALL_TIMEOUT)
    except Exception as e:  # noqa: BLE001
        out.setdefault("notes", []).append("finish: " + _err(e))
    out["secs"] = round(time.monotonic() - t0, 1)
    return out


# ---------------------------------------------------------------------------------- for the critics


def _runs_line(ob: dict) -> str:
    runs = []
    for r in ob.get("samples") or []:
        zone = f" z{r['zone']}" if "zone" in r else ""
        runs.append(f"{r.get('from')}->{r.get('to')} {r.get('by')}{zone}: {r.get('result')}"
                    + ("" if r.get("result") == "reached" else f" {r.get('where')}"))
    zones = ob.get("zones_reached") or []
    return (f"Obby runs ({ob.get('reached')}/{ob.get('total')} reached the next checkpoint"
            + (f"; zones reached: {', '.join(map(str, zones))} of {len(ob.get('zones_sampled') or [])} sampled" if zones else "")
            + "): " + "; ".join(runs))


def headline(smoke: dict) -> str:
    """One line: 'smoke play 33s: 4/5 steps ok, obby 11/12 reached; checkpoint_reached +2, coin_collected +3'."""
    if not smoke or smoke.get("skipped"):
        return "smoke play off"
    steps = smoke.get("steps") or []
    ran = [s for s in steps if not s.get("skipped")]
    head = f"smoke play {smoke.get('secs', '?')}s: {sum(1 for s in ran if s.get('ok'))}/{len(ran)} steps ok"
    ob = smoke.get("obby") or {}
    if ob:
        head += f", obby {ob.get('reached')}/{ob.get('total')} reached"
    d = smoke.get("counters_delta") or {}
    if d:
        head += "; " + ", ".join(f"{k} {v:+g}" for k, v in list(d.items())[:10])
    if smoke.get("error"):
        head += f"; error: {smoke['error']}"
    return head


def format_smoke(smoke: dict | None, limit: int = 3000) -> str:
    """The critic's '## Smoke play' section (user message: the critic's system prompt is frozen)."""
    if not smoke or smoke.get("skipped"):
        return ""
    lines = [f"A scripted player (forge smoke play, no LLM) played the game for {smoke.get('secs', '?')}s before the "
             "ForgeProbe report above was read, so the report's counters include what it did."]
    if smoke.get("obby"):
        lines[0] += (" Obby runs are a deterministic runner, not a skilled player: bot testers only test whether a "
                     "stage can be reached (the game credits only the real player), and the runner misses some valid "
                     "jumps (moving platforms, conveyors, jump pads, side jumps). So a failed bot run is a lead, not "
                     "proof that the stage is broken: file an issue for it only when the code or level data shows why "
                     "the stage cannot be passed.")
    for s in smoke.get("steps") or []:
        state = "skipped" if s.get("skipped") else ("ok" if s.get("ok") else "FAILED")
        lines.append(f"- {s.get('what')} [{state}]: {_clip(s.get('detail'), 380)}")
    if smoke.get("obby"):
        lines.append(_runs_line(smoke["obby"]))
    d = smoke.get("counters_delta") or {}
    lines.append("Counters the smoke play changed: " + (", ".join(f"{k} {v:+g}" for k, v in d.items()) or "none"))
    if smoke.get("error"):
        lines.append(f"Smoke play error: {smoke['error']}")
    text = "\n".join(lines)
    return text if len(text) <= limit else text[: limit - 40] + "\n...[smoke play truncated]"
