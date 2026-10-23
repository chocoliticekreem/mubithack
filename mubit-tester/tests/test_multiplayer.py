"""Multiplayer / co-op / squads: a fake game world behind the harness, the shipped multiplayer
scenarios (pass on a working game, SKIP on stubs), runner features, harness routing, the new MCP
tools and the AI squads mode."""

from __future__ import annotations

import asyncio
import contextlib
import copy
import json
import math
import re
import time
from pathlib import Path

import pytest

from forge.llm import FakeLLM
from mubit_tester import ai, play
from mubit_tester import harness as hm
from mubit_tester import scenario as sm
from mubit_tester import server as ms
from mubit_tester.harness import Harness, HarnessError, build_relay_luau, is_unsupported
from mubit_tester.scenario import load_scenario, run_scenario
from test_harness import FakeStudio, decode_call
from test_tester_ai import JUDGE, ScriptedLLM, _a, _settings

REPO = Path(__file__).resolve().parent.parent.parent
MULTI = ["lobby_countdown", "squad_parallel", "coop_panda", "friendly_fire_blame", "heat_overheat", "hose_tether"]
LIVE = {"LobbyService", "MissionService", "SquadService", "ToolService", "RescueService", "BlameService",
        "HeatService", "FireService", "MapService", "Ragdoll", "HoseLine"}


def unsupported(msg: str) -> Exception:
    return RuntimeError("unsupported: " + msg)


class GameWorld:
    """A small simulation of the v1.5 game as the ForgeTest harness reports it."""

    def __init__(self, n_players: int = 2, stubs: set[str] = frozenset(), auto_launch: bool = True,
                 catalog: tuple = ("house_fire",), leak: bool = False):
        self.players = [{"userId": 100 + i, "name": f"Player{i}", "helmet": i, "pos": [i * 4.0, 3.0, 0.0],
                         "health": 100, "maxHealth": 100, "attrs": {}, "squadId": None, "instanceId": None,
                         "heat": 0, "downed": False, "ragdolled": False, "carrying": None, "agent": True,
                         "tool": None, "character": f"Workspace.Player{i}"} for i in range(1, n_players + 1)]
        self.stubs = set(stubs)
        self.auto_launch = auto_launch
        self.catalog = list(catalog)
        self.leak = leak  # bug switch: query/observe show other instances' fires
        self.t = 1.0
        self.log: list[dict] = []
        self.squads: dict[str, dict] = {}
        self.instances: dict[str, dict] = {}
        self.things: list[dict] = []  # {path, tags, attrs, instanceId, pos}
        self.counters: dict = {}
        self.blame_stats: dict = {}
        self.hoses: dict = {}
        self.holding: dict = {}
        self.calls: list[tuple[str, dict]] = []

    # ---- helpers
    def live(self, svc: str) -> bool:
        return svc not in self.stubs

    def p(self, who) -> dict:
        for p in self.players:
            if str(who) in (str(p["userId"]), p["name"], str(p["helmet"])):
                return p
        raise RuntimeError(f"no player {who}")

    def ev(self, kind: str, **data):
        self.t += 0.1
        p = None
        if "userId" in data:
            p = self.p(data["userId"])
            data.setdefault("name", p["name"])
        if p and "instanceId" not in data and p["instanceId"]:
            data["instanceId"] = p["instanceId"]
        if p and "squadId" not in data and p["squadId"]:
            data["squadId"] = p["squadId"]
        self.log.append({"t": round(self.t, 2), "kind": kind, "data": data})

    def start_instance(self, uids: list, mission: str, squad: str | None = None) -> str:
        iid = f"M{len(self.instances) + 1}"
        self.instances[iid] = {"instanceId": iid, "missionId": mission, "squadId": squad, "state": "Active",
                               "endsAt": 999, "players": [{"userId": u, "name": self.p(u)["name"]} for u in uids]}
        base = [len(self.instances) * 400.0, 3.0, 0.0]
        for k in range(3):
            self.things.append({"path": f"Workspace.Instances.{iid}.House.Wall{k}", "tags": ["Flammable"],
                                "attrs": {}, "instanceId": iid, "pos": [base[0] + k, 3.0, 0.0]})
        self.things.append({"path": f"Workspace.Instances.{iid}.Panda", "tags": ["Rescuable"], "instanceId": iid,
                            "attrs": {"Kind": "Panda", "RescueState": "Trapped"}, "pos": [base[0] + 5, 3.0, 0.0]})
        for u in uids:
            p = self.p(u)
            p["instanceId"] = iid
            p["pos"] = list(base)
            self.ev("entered_instance", userId=u, instanceId=iid)
        self.ev("mission_started", instanceId=iid, args=[iid, mission])
        return iid

    def thing(self, path: str) -> dict:
        return next(t for t in self.things if t["path"] == path)

    def scoped(self, t: dict, iid: str | None, strict: bool) -> bool:
        if not iid or self.leak:
            return True
        return t["instanceId"] == iid if strict else t["instanceId"] in (None, iid)

    def tick_heat(self):
        for p in self.players:
            if not self.live("HeatService"):
                continue
            hot = any("Burning" in t["tags"] and math.dist(t["pos"], p["pos"]) < 8 for t in self.things)
            if hot and p["heat"] < 100:
                p["heat"] = min(100, p["heat"] + 40)
                if p["heat"] >= 100:
                    self.ev("overheated", userId=p["userId"])
                    if self.live("SquadService"):
                        p["downed"] = True
                        self.ev("downed", userId=p["userId"], via="attr")

    # ---- harness commands
    def handlers(self) -> dict:
        names = ("ping caps players observe act query teleport ignite extinguish config counters events squads "
                 "instances queue launch mission_start mission_end blame hook").split()
        return {n: (lambda a, n=n: self.dispatch(n, a)) for n in names}

    def dispatch(self, cmd: str, a: dict):
        self.calls.append((cmd, a))
        return getattr(self, "c_" + cmd)(a)

    def c_ping(self, a):
        return {"version": "2", "players": len(self.players)}

    def c_caps(self, a):
        services = {s: {"status": "stub" if s in self.stubs else "live",
                        "methods": ["StartMission", "EndMission", "GetMissions", "Join", "Launch", "GetSquads",
                                    "GetStats", "_attachTest", "detach"]} for s in LIVE}
        return {"version": "2", "players": len(self.players), "services": services,
                "tags": {"SquadPad": 0 if "LobbyService" in self.stubs else 4},
                "catalog": self.catalog, "instanceModels": list(self.instances)}

    def c_players(self, a):
        self.tick_heat()
        out = self.players
        if a.get("userIds"):
            out = [self.p(u) for u in a["userIds"]]
        if a.get("instanceId"):
            out = [p for p in out if p["instanceId"] == a["instanceId"]]
        out = copy.deepcopy(out)
        for p in out:
            p["attrs"].update({k: v for k, v in (("SquadId", p["squadId"]), ("InstanceId", p["instanceId"]),
                                                    ("Heat", p["heat"])) if v})
        return out

    def c_observe(self, a):
        p = self.p(a["userId"])
        iid = a.get("instanceId") or p["instanceId"]
        things = [{"path": t["path"], "tag": t["tags"][0], "dist": 5} for t in self.things
                  if self.scoped(t, iid, False) and ("Burning" in t["tags"] or "Rescuable" in t["tags"])]
        world = {"RoundState": "Active"}
        if p["squadId"]:
            world["SquadId"] = p["squadId"]
        if p["instanceId"]:
            world["InstanceId"] = p["instanceId"]
            world["instance"] = {"state": self.instances[p["instanceId"]]["state"]}
        return {"me": {"pos": p["pos"], "health": 100, "attrs": {"SquadId": p["squadId"], "InstanceId": p["instanceId"],
                                                                 "Heat": p["heat"], "Downed": p["downed"]}},
                "world": world, "things": things, "prompts": [], "hud": []}

    def c_query(self, a):
        rows = []
        for t in self.things:
            if a.get("tag") and a["tag"] not in t["tags"]:
                continue
            if not self.scoped(t, a.get("instanceId"), True):
                continue
            if any(t["attrs"].get(k) != v for k, v in (a.get("where") or {}).items()):
                continue
            rows.append({"path": t["path"], "tags": t["tags"], "attrs": dict(t["attrs"]), "instanceId": t["instanceId"],
                         "pos": t["pos"]})
        return rows[: a.get("limit", 25)]

    def c_teleport(self, a):
        p = self.p(a["userId"])
        if a.get("pos"):
            pos = list(a["pos"])
        elif a.get("path"):
            pos = list(self.thing(a["path"])["pos"])
        else:
            pos = list(self.p(a["to"])["pos"])
        off = a.get("offset") or [0, 0, 0]
        p["pos"] = [pos[i] + off[i] for i in range(3)]
        return True

    def c_ignite(self, a):
        p = self.p(a["near"])
        cands = [t for t in self.things if "Flammable" in t["tags"] and "Burning" not in t["tags"]
                 and (not a.get("instanceId") or t["instanceId"] == a["instanceId"])]
        cands.sort(key=lambda t: math.dist(t["pos"], p["pos"]))
        if not cands:
            raise RuntimeError("no unburnt Flammable part")
        cands[0]["tags"].append("Burning")
        self.ev("tag_added", tag="Burning", path=cands[0]["path"], instanceId=cands[0]["instanceId"])
        return {"path": cands[0]["path"], "burning": True}

    def c_extinguish(self, a):
        for t in self.things:
            if "Burning" in t["tags"]:
                t["tags"].remove("Burning")
        return {"all": True}

    def c_config(self, a):
        if a["module"] == "HoseLineConfig":
            return {"module": a["module"], "key": a["key"], "value": 60}
        return {"module": a["module"], "key": a["key"], "value": a.get("value")}

    def c_counters(self, a):
        return dict(self.counters)

    def c_events(self, a):
        since = a.get("since") or 0
        kinds = a.get("kinds")
        iid, strict = a.get("instanceId"), a.get("strict")
        out = []
        for e in self.log:
            if e["t"] <= since or (kinds and e["kind"] not in kinds):
                continue
            eid = e["data"].get("instanceId")
            if iid and not self.leak and not (eid == iid or (eid is None and not strict and not e["data"].get("squadId"))):
                continue
            out.append(e)
        self.t += 0.1
        return {"now": round(self.t, 2), "events": out}

    def c_squads(self, a):
        squads = list(self.squads.values())
        if self.auto_launch:
            for s in squads:
                if s.get("countdown") is not None and not s.get("instanceId"):
                    s["countdown"] -= 5
                    self.ev("countdown", padId=s["padId"], value=s["countdown"])
                    if s["countdown"] <= 0:
                        self.launch(s, s.get("missionId") or self.catalog[0])
        if a.get("squadId"):
            squads = [s for s in squads if s["id"] == a["squadId"]]
        return {"service": "stub" if "LobbyService" in self.stubs else "live", "squads": copy.deepcopy(squads),
                "pads": [] if "LobbyService" in self.stubs else
                [{"padId": i, "path": f"Workspace.Station.Pad{i}"} for i in range(1, 5)],
                "catalog": self.catalog, "lobby": [p for p in self.players if not p["instanceId"]]}

    def c_instances(self, a):
        rows = [dict(r, fires=sum(1 for t in self.things if t["instanceId"] == r["instanceId"] and "Burning" in t["tags"]))
                for r in self.instances.values()]
        if a.get("instanceId"):
            rows = [r for r in rows if r["instanceId"] == a["instanceId"]]
        return rows

    def c_queue(self, a):
        if not self.live("LobbyService"):
            raise unsupported("no SquadPad in the world (station lobby not built yet)")
        p = self.p(a["userId"])
        sid = f"S{a.get('pad', 1)}"
        s = self.squads.setdefault(sid, {"id": sid, "padId": a.get("pad", 1), "members": [], "state": "Forming"})
        s["members"].append({"userId": p["userId"], "name": p["name"]})
        if len(s["members"]) >= 2 or self.auto_launch:
            s["countdown"] = 15
        p["squadId"] = sid
        self.ev("joined_pad", userId=p["userId"], squadId=sid)
        return {"squadId": sid, "joined": True}

    def launch(self, s: dict, mission: str):
        iid = self.start_instance([m["userId"] for m in s["members"]], mission, s["id"])
        s["instanceId"], s["state"] = iid, "InMission"
        self.ev("launched", args=[s["id"], mission, iid], instanceId=iid)
        return iid

    def c_launch(self, a):
        if not self.live("LobbyService"):
            raise unsupported("LobbyService is a K0 stub")
        s = self.squads.get(a.get("squadId")) or next(s for s in self.squads.values() if s["padId"] == a.get("pad"))
        if s.get("instanceId"):
            raise RuntimeError("already launched")
        return {"squadId": s["id"], "instanceId": self.launch(s, a.get("missionId") or self.catalog[0])}

    def c_mission_start(self, a):
        if not self.live("MissionService"):
            raise unsupported("MissionService:StartMission not available (stub)")
        uids = [self.p(u)["userId"] for u in a.get("players") or [p["userId"] for p in self.players]]
        return {"instanceId": self.start_instance(uids, a.get("missionId") or self.catalog[0])}

    def c_mission_end(self, a):
        iid = a.get("instanceId") or self.p(a["player"])["instanceId"]
        self.instances[iid]["state"] = "Results"
        for p in self.players:
            if p["instanceId"] == iid:
                p["instanceId"] = None
        return {"instanceId": iid, "state": "Results"}

    def c_blame(self, a):
        if not self.live("BlameService"):
            raise unsupported("BlameService:GetStats not available (stub)")
        ps = [self.p(u) for u in a["userIds"]] if a.get("userIds") else self.players
        return {"service": "live", "stats": [{"name": p["name"], "userId": p["userId"],
                                              **self.blame_stats.get(p["name"], {"teammateSprayed": 0})} for p in ps]}

    def c_hook(self, a):
        if a["module"] != "HoseLine" or not self.live("HoseLine"):
            raise unsupported("no module")
        p = self.p(a["args"][0]["player"])
        if a["fn"] == "._attachTest":
            self.hoses[p["name"]] = [p["pos"][0], p["pos"][1], p["pos"][2] + a["args"][1]]
            p["attrs"]["HoseKind"] = "truck"
            return {"result": True}
        self.hoses.pop(p["name"], None)
        return {"result": "nil"}

    def c_act(self, a):
        p = self.p(a["userId"])
        action, args = a["action"], a.get("args") or {}
        if action == "walk_to":
            target = args.get("pos") or self.thing(args["path"])["pos"]
            reel = self.hoses.get(p["name"])
            if reel and math.dist(target, reel) > 66:  # yanked back at the end of the hose
                d = math.dist(target, reel)
                p["pos"] = [reel[i] + (target[i] - reel[i]) * 60 / d for i in range(3)]
                self.counters["hose_yanks"] = self.counters.get("hose_yanks", 0) + 1
                self.ev("count", name="hose_yanks", delta=1)
                return {"done": False, "detail": "stopped short"}
            p["pos"] = list(target)
            return {"done": True}
        if action == "equip":
            p["tool"] = args.get("name")
            return {"done": True}
        if action == "use":
            victim = args.get("target_player")
            if victim is not None and self.live("ToolService"):
                v = self.p(victim)
                self.ev("hose_hit", userId=p["userId"], other={"userId": v["userId"], "name": v["name"]},
                        args=[{"name": p["name"]}, {"name": v["name"]}])
                if self.live("Ragdoll"):
                    v["ragdolled"] = True
                    self.ev("ragdolled", userId=v["userId"])
                st = self.blame_stats.setdefault(p["name"], {"teammateSprayed": 0})
                st["teammateSprayed"] += 1
            return {"done": True}
        if action == "interact":
            target = args.get("path")
            if args.get("target_player") is not None:
                v = self.p(args["target_player"])
                if v["downed"]:
                    v["downed"] = False
                    self.ev("revived", userId=v["userId"])
                    return {"done": True}
                return {"done": False}
            t = self.thing(target)
            if t["attrs"].get("Kind") == "Panda":
                holders = self.holding.setdefault(target, set())
                holders.add(p["name"])
                self.ev("prompt_triggered", userId=p["userId"], prompt=target)
                if len(holders) >= 2:
                    t["attrs"]["RescueState"] = "Carried"
                    for h in holders:
                        self.p(h)["carrying"] = "panda"
                return {"done": True}
            return {"done": False}
        return {"done": True}


def harness_for(world: GameWorld) -> Harness:
    st = FakeStudio(world.handlers())

    async def probe_report():
        return {"errors": [], "warnings": []}
    st.probe_report = probe_report
    return Harness(st)


def _fast(sc: dict) -> dict:
    """Shrink every timeout so failing conditions don't make the suite slow."""
    sc = copy.deepcopy(sc)
    for st in sc["steps"]:
        for k in ("wait_until", "assert"):
            if k in st:
                st[k]["timeout"] = min(float(st[k].get("timeout", 10)), 0.3)
                st[k]["interval"] = 0.01
        for sub in st.get("parallel") or []:
            for k in ("wait_until", "assert"):
                if k in sub:
                    sub[k]["timeout"], sub[k]["interval"] = 0.3, 0.01
        if "wait" in st:
            st["wait"] = 0
    return sc


# ---------------------------------------------------------------- shipped scenarios

def test_multiplayer_scenarios_ship_and_load():
    names = {s["name"]: s for s in sm.list_scenarios(REPO)}
    for n in MULTI + ["smoke"]:
        assert n in names, n
        load_scenario(n, REPO)
    for n in MULTI:
        assert names[n]["requires"], f"{n} must declare requires so it can SKIP"


@pytest.mark.parametrize("name", MULTI + ["smoke"])
async def test_scenario_passes_on_working_game(name):
    w = GameWorld()
    res = await run_scenario(harness_for(w), _fast(load_scenario(name, REPO)))
    assert res["passed"] is True, sm.format_result(res)
    assert not res.get("partial")


@pytest.mark.parametrize("name,stub", [
    ("lobby_countdown", "LobbyService"), ("squad_parallel", "LobbyService"), ("coop_panda", "MissionService"),
    ("friendly_fire_blame", "ToolService"), ("heat_overheat", "HeatService"), ("hose_tether", "HoseLine"),
])
async def test_scenario_skips_when_service_is_a_stub(name, stub):
    w = GameWorld(stubs={stub})
    res = await run_scenario(harness_for(w), load_scenario(name, REPO))
    assert res["passed"] is None and res["skipped"], res
    assert stub in res["reason"] and "stub" in res["reason"]
    assert "SKIP" in sm.format_result(res)
    assert not [c for c, _ in w.calls if c in ("queue", "launch", "mission_start", "act")]  # nothing ran


@pytest.mark.parametrize("name", [n for n in MULTI if n != "hose_tether"])
async def test_scenario_skips_with_one_player(name):
    res = await run_scenario(harness_for(GameWorld(n_players=1)), load_scenario(name, REPO))
    assert res["skipped"] and "multiplayer_start players=2" in res["reason"]


async def test_lobby_countdown_forces_launch_only_when_needed():
    w = GameWorld(auto_launch=False)
    res = await run_scenario(harness_for(w), _fast(load_scenario("lobby_countdown", REPO)))
    assert res["passed"], sm.format_result(res)
    assert [c for c, _ in w.calls].count("launch") == 1
    assert any("countdown" in x for x in res["warnings"])  # no countdown: only warnings
    w2 = GameWorld(auto_launch=True)
    res2 = await run_scenario(harness_for(w2), _fast(load_scenario("lobby_countdown", REPO)))
    assert res2["passed"] and "launch" not in [c for c, _ in w2.calls]
    launch_step = next(s for s in res2["steps"] if s.get("label") == "launch if nobody did")
    assert launch_step["detail"].startswith("not needed")


async def test_squad_parallel_catches_leaking_instances():
    w = GameWorld(leak=True)
    res = await run_scenario(harness_for(w), _fast(load_scenario("squad_parallel", REPO)))
    assert res["passed"] is False
    assert res["steps"][-1]["label"] == "B's query can't see it" and not res["steps"][-1]["ok"]


async def test_squad_parallel_uses_two_missions_when_enabled():
    w = GameWorld(catalog=("farm_haystack", "house_fire"))
    res = await run_scenario(harness_for(w), _fast(load_scenario("squad_parallel", REPO)))
    assert res["passed"] and not res["warnings"]
    assert sorted(r["missionId"] for r in w.instances.values()) == ["farm_haystack", "house_fire"]


async def test_partial_when_downed_and_revive_are_stubs():
    w = GameWorld(stubs={"SquadService", "Ragdoll", "BlameService"})
    res = await run_scenario(harness_for(w), _fast(load_scenario("heat_overheat", REPO)))
    assert res["passed"] is True and "SquadService" in res["partial"]
    assert "partial" in sm.format_result(res)
    res = await run_scenario(harness_for(w), _fast(load_scenario("friendly_fire_blame", REPO)))
    assert res["passed"] is True and "Ragdoll" in res["partial"]


# ---------------------------------------------------------------- runner features

async def test_parallel_runs_concurrently_and_saves():
    class Slow:
        def __init__(self):
            self.active = self.peak = 0

        async def call(self, cmd, **a):
            self.active += 1
            self.peak = max(self.peak, self.active)
            await asyncio.sleep(0.05)
            self.active -= 1
            if cmd == "caps":
                return {}
            return {"cmd": cmd, **a}

        async def events(self, since=None):
            return {"now": 0, "events": []}

    h = Slow()
    sc = {"steps": [
        {"parallel": [{"call": {"cmd": "queue", "args": {"pad": 1}}, "save": "a"},
                      {"call": {"cmd": "queue", "args": {"pad": 2}}, "save": "b"}]},
        {"assert": {"cmd": "ping", "path": "result.x", "op": "==", "value": "$b.args"}, "label": "unused"},
    ], "stop_on_fail": False}
    res = await run_scenario(h, sc)
    assert h.peak == 2
    assert "[1 call: ok]" in res["steps"][0]["detail"] and "[2 call: ok]" in res["steps"][0]["detail"]


async def test_unsupported_mid_scenario_skips_and_soft_steps_continue():
    w = GameWorld(stubs={"MissionService"})
    h = harness_for(w)
    sc = {"name": "x", "steps": [
        {"call": {"cmd": "mission_start"}, "soft": True, "label": "optional mission"},
        {"call": {"cmd": "players"}},
        {"call": {"cmd": "mission_start"}},
        {"call": {"cmd": "players"}},
    ]}
    res = await run_scenario(h, sc)
    assert res["skipped"] and res["reason"].startswith("unsupported: MissionService")
    assert res["steps"][0]["warning"] and len(res["steps"]) == 3
    assert "SKIP" in res["steps"][-1]["detail"]


async def test_require_step_condition_and_unknown_service():
    w = GameWorld()
    sc = {"steps": [
        {"require": ["NotAService", "players>=2", {"cmd": "players", "path": "result", "op": "len>=", "value": 5,
                                                   "reason": "needs a full lobby"}]},
        {"call": {"cmd": "players"}},
    ]}
    res = await run_scenario(harness_for(w), sc)
    assert res["passed"] and res["partial"] == "needs a full lobby" and len(res["steps"]) == 1


async def test_requires_tag_and_old_harness_without_caps():
    w = GameWorld(stubs={"LobbyService"})
    res = await run_scenario(harness_for(w), {"requires": ["tag:SquadPad"], "steps": [{"wait": 0}]})
    assert res["skipped"] and "SquadPad" in res["reason"]
    # a harness without `caps` (older ForgeTest) can't tell: don't skip
    st = FakeStudio({"players": lambda a: []})
    res = await run_scenario(Harness(st), {"requires": ["LobbyService", "players>=4"], "steps": [{"wait": 0}]})
    assert res["passed"] is True


def test_new_ops():
    M = sm._MISSING
    assert sm.compare("within", [1, 0, 0], 5, [0, 0, 0]) and not sm.compare("within", [9, 0, 0], 5, [0, 0, 0])
    assert sm.compare("!contains", [{"path": "A"}], {"path": "B"}) and not sm.compare("!contains", ["a"], "a")
    assert sm.compare("!contains", M, "x")
    with pytest.raises(sm.ScenarioError, match="parallel"):
        sm.validate({"steps": [{"parallel": []}]})
    with pytest.raises(sm.ScenarioError, match="exactly one"):
        sm.validate({"steps": [{"parallel": [{"require": []}]}]})


# ---------------------------------------------------------------- harness

def test_relay_luau_and_unsupported():
    code = build_relay_luau("squads", {"pad": 1})
    assert 'WaitForChild("ForgeTestRemote", 5)' in code and 'InvokeServer("ForgeTest", "call", "squads", ' in code
    assert json.loads(re.search(r'"squads", \[(=+)\[(.*)\]\1\]\)\s*$', code, re.S).group(2)) == {"pad": 1}
    with pytest.raises(ValueError):
        build_relay_luau("x y")
    assert is_unsupported(HarnessError("launch: unsupported: LobbyService is a K0 stub"))
    assert not is_unsupported(HarnessError("launch: no squad"))


async def test_harness_squad_helpers_send_contract_args():
    w = GameWorld()
    h = harness_for(w)
    st = h.studio
    q = await h.queue(101, pad=2)
    assert q["squadId"] == "S2" and st.calls[-1] == ("queue", {"userId": 101, "pad": 2})
    await h.queue(102, pad=2, walk=True, join=True, wait=1)
    assert st.calls[-1][1] == {"userId": 102, "pad": 2, "walk": True, "join": True, "wait": 1}
    la = await h.launch(pad=2, mission_id="house_fire")
    assert st.calls[-1] == ("launch", {"pad": 2, "missionId": "house_fire"}) and la["instanceId"] == "M1"
    assert (await h.instances("M1"))[0]["missionId"] == "house_fire"
    assert st.calls[-1] == ("instances", {"instanceId": "M1"})
    assert (await h.squads(squad_id="S2"))["squads"][0]["instanceId"] == "M1"
    ms_ = await h.mission_start("house_fire", players=["Player1"])
    assert st.calls[-1] == ("mission_start", {"missionId": "house_fire", "players": ["Player1"]})
    await h.mission_end(ms_["instanceId"], wait=2)
    assert st.calls[-1] == ("mission_end", {"instanceId": "M2", "reason": "forced", "wait": 2})
    await h.events(3, instance_id="M1", kinds=["hose_hit"])
    assert st.calls[-1] == ("events", {"since": 3, "instanceId": "M1", "kinds": ["hose_hit"]})
    await h.players(instance_id="M1")
    assert st.calls[-1] == ("players", {"instanceId": "M1"})
    await h.observe(101, instance_id="M1")
    assert st.calls[-1] == ("observe", {"userId": 101, "instanceId": "M1"})
    assert (await h.caps())["services"]["LobbyService"]["status"] == "live"


async def test_harness_relocates_then_relays():
    from forge.studio import StudioError

    class St:
        studio_id = "edit"

        def __init__(self):
            self.ran = []

        async def execute_luau(self, code, dm="Edit", timeout=None):
            self.ran.append((self.studio_id, dm))
            if (self.studio_id, dm) not in (("srv", "Server"), ("cl", "Client")):
                raise StudioError("no datamodel")
            return json.dumps({"ok": True, "result": self.studio_id})

    st = St()

    async def relocate():
        st.studio_id = "srv"
        return "server"
    h = Harness(st, relocate=relocate)
    assert await h.call("ping") == "srv" and h.mode == "server"

    async def to_client():
        st.studio_id = "cl"
        return "client"
    st.studio_id = "edit"
    h2 = Harness(st, relocate=to_client)
    assert await h2.call("ping") == "cl" and h2.mode == "client" and st.ran[-1] == ("cl", "Client")

    async def nothing():
        return None
    st.studio_id = "edit"
    with pytest.raises(HarnessError, match="no datamodel"):
        await Harness(st, relocate=nothing).call("ping")


async def test_ensure_ready_in_client_mode_does_not_start_play(monkeypatch):
    monkeypatch.setattr(hm, "READY_POLL", 0.01)
    st = FakeStudio(playing=False)

    async def execute_luau(code, dm="Edit", timeout=None):
        return json.dumps({"ok": True, "result": {"version": "2", "players": 3}})
    st.execute_luau = execute_luau
    h = Harness(st, mode="client")
    assert (await h.ensure_ready(timeout=1))["players"] == 3 and st.played == 0


# ---------------------------------------------------------------- MCP tools

@pytest.fixture
def world_studio(monkeypatch):
    w = GameWorld(n_players=3)
    st = FakeStudio(w.handlers())

    @contextlib.asynccontextmanager
    async def opener(select: bool = True):
        yield st
    monkeypatch.setattr(ms, "open_studio", opener)
    monkeypatch.setattr(ms, "STATE", {"studio_id": None, "hint": None, "mode": "server", "clients": []})
    return w, st


def _text(result) -> str:
    return "\n".join(getattr(c, "text", "") for c in result.content)


async def test_squad_tools(world_studio, capsys):
    w, st = world_studio
    md = _text(await ms.mcp.call_tool("queue", {"player": "1", "pad": 1}))
    assert '"squadId": "S1"' in md and st.calls[-1] == ("queue", {"userId": "1", "pad": 1})
    await ms.mcp.call_tool("queue", {"player": "Player2", "pad": 1, "walk": True, "join": False})
    assert st.calls[-1][1] == {"userId": "Player2", "pad": 1, "walk": True, "join": False}
    w.auto_launch = False
    md = _text(await ms.mcp.call_tool("squads", {}))
    assert "## Lobby: LobbyService live" in md and "| S1 | 1 |" in md and "Player1, Player2" in md
    assert "| 1 |" in md and "catalog: house_fire" in md
    md = _text(await ms.mcp.call_tool("launch", {"pad": 1, "mission_id": "house_fire"}))
    assert '"instanceId": "M1"' in md and st.calls[-1][1] == {"pad": 1, "missionId": "house_fire", "wait": 20}
    md = _text(await ms.mcp.call_tool("instances", {}))
    assert "## Mission instances (1)" in md and "| M1 | house_fire | S1 |" in md and "Player1, Player2" in md
    md = _text(await ms.mcp.call_tool("mission_start", {"mission_id": "house_fire", "players": ["3"], "seconds": 60}))
    assert '"instanceId": "M2"' in md
    assert st.calls[-1][1] == {"wait": 15, "missionId": "house_fire", "players": ["3"], "seconds": 60}
    md = _text(await ms.mcp.call_tool("mission_end", {"instance_id": "M2"}))
    assert "Results" in md and st.calls[-1][1] == {"instanceId": "M2", "reason": "forced", "wait": 10}
    md = _text(await ms.mcp.call_tool("players", {"instance_id": "M1"}))
    assert "## Players (2)" in md and "| S1 | M1 |" in md
    await ms.mcp.call_tool("events", {"instance_id": "M1", "kinds": ["launched"]})
    assert st.calls[-1][1] == {"instanceId": "M1", "kinds": ["launched"]}
    await ms.mcp.call_tool("query", {"tag": "Rescuable", "instance_id": "M1", "where": {"Kind": "Panda"}})
    assert st.calls[-1][1] == {"tag": "Rescuable", "instanceId": "M1", "where": {"Kind": "Panda"}, "limit": 25}
    await ms.mcp.call_tool("teleport", {"player": "2", "to": "1", "offset": [3, 0, 0]})
    assert st.calls[-1][1] == {"userId": "2", "to": "1", "offset": [3, 0, 0]}
    assert capsys.readouterr().out == ""


async def test_squad_tools_report_unsupported(world_studio):
    w, _ = world_studio
    w.stubs.add("LobbyService")
    from mcp.server.mcpserver.exceptions import ToolError
    with pytest.raises(ToolError, match="unsupported: no SquadPad"):
        await ms.mcp.call_tool("queue", {"player": "1"})
    with pytest.raises(ToolError, match="give pad or squad_id"):
        await ms.mcp.call_tool("launch", {})
    assert "LobbyService stub" in _text(await ms.mcp.call_tool("squads", {}))
    assert "No mission instances" in _text(await ms.mcp.call_tool("instances", {}))


async def test_status_lists_game_services(world_studio):
    w, st = world_studio
    w.stubs.add("LobbyService")
    md = _text(await ms.mcp.call_tool("status", {}))
    assert "harness: ok via server" in md and "LobbyService stub" in md and "MissionService live" in md
    assert "0 SquadPad(s)" in md


async def test_scenario_tools_show_requires_and_skip(world_studio, monkeypatch):
    w, _ = world_studio
    monkeypatch.setattr(hm, "READY_POLL", 0.01)
    md = _text(await ms.mcp.call_tool("scenario_list", {}))
    assert "| lobby_countdown |" in md and "players>=2, LobbyService" in md
    w.stubs.add("HoseLine")
    md = _text(await ms.mcp.call_tool("scenario_run", {"scenario": "hose_tether"}))
    assert "SKIP (HoseLine is still a K0 stub)" in md


# ---------------------------------------------------------------- AI squads mode

class SquadsHarness:
    """GameWorld through the Harness helper surface used by ai._session (no Luau round trip)."""

    def __init__(self, world: GameWorld, lobby: bool = True):
        self.w = world
        self.h = harness_for(world)
        self.studio = None
        if not lobby:
            world.stubs.add("LobbyService")

    def __getattr__(self, name):
        return getattr(self.h, name)


def test_assign_squads_and_phase():
    roster = [{"userId": i, "name": f"P{i}"} for i in range(4)]
    ai.assign_squads(roster, 2)
    assert [(p["squad"], p["pad"]) for p in roster] == [("A", 1), ("A", 1), ("B", 2), ("B", 2)]
    assert [p["squad"] for p in ai.assign_squads([{"userId": 1, "name": "x"}], 3)] == ["A"]
    obs = {"me": {"attrs": {"SquadId": "S1"}}, "world": {}}
    assert ai.player_phase(obs, None, {}) == "queued"
    assert ai.player_phase({"me": {"attrs": {"InstanceId": "M1"}}}, "queued", {"M1": {"state": "Active"}}) == "mission"
    assert ai.player_phase({"me": {"attrs": {"InstanceId": "M1"}}}, "mission", {"M1": {"state": "Results"}}) == "results"
    assert ai.player_phase({"me": {"attrs": {}}}, "results", {}) == "returned"
    assert ai.player_phase({"me": {"attrs": {}}}, None, {}) == "lobby"


def test_blame_from_events():
    roster = [{"userId": 1, "name": "A"}, {"userId": 2, "name": "B"}]
    evs = [
        {"t": 1, "kind": "hose_hit", "data": {"userId": 1, "name": "A", "other": {"userId": 2, "name": "B"}}},
        {"t": 2, "kind": "downed", "data": {"userId": 2, "name": "B", "args": [{"name": "B"}, "hose", {"name": "A"}]}},
        {"t": 2.1, "kind": "downed", "data": {"userId": 2, "name": "B", "via": "attr"}},  # same down, attr copy
        {"t": 3, "kind": "kinked", "data": {"userId": 1, "name": "A", "other": {"userId": 2, "name": "B"}}},
        {"t": 4, "kind": "delivered", "data": {"by": 2, "kind": "Panda"}},
        {"t": 5, "kind": "overheated", "data": {"userId": 1}},
    ]
    s = ai.blame_from_events(evs, roster)
    assert s["A"]["teammates_hosed"] == 1 and s["B"]["hosed_by_teammates"] == 1
    assert s["B"]["downed"] == 1 and s["A"]["downs_caused"] == 1
    assert s["B"]["kinked_others"] == 1 and s["B"]["delivered"] == 1 and s["A"]["overheated"] == 1


class SquadsLLM(ScriptedLLM):
    """Players walk to their pad, wait, then act in the mission; the judge adds per-player blame."""

    def __init__(self, judge):
        super().__init__({}, judge=judge, delay=0.01)

    def _reply(self, role, user):
        with self._lock:
            self.in_flight += 1
            self.max_in_flight = max(self.max_in_flight, self.in_flight)
        try:
            time.sleep(self.delay)
            phase = re.search(r'"phase":"(\w+)"', user)
            phase = phase.group(1) if phase else "?"
            if phase == "lobby":
                pad = re.search(r'"pad_path":"([^"]+)"', user)
                return _a("move_to_instance", {"path": pad.group(1) if pad else "Workspace.Station.Pad1"})
            if phase == "mission":
                return _a("spray", {"target": "Workspace.Fire", "ms": 500})
            return _a("wait", {"seconds": 0})
        finally:
            with self._lock:
                self.in_flight -= 1


async def test_squads_mode_full_loop_with_assists(tmp_path, monkeypatch):
    monkeypatch.setattr(ai, "QUEUE_AFTER", 1)
    monkeypatch.setattr(ai, "LAUNCH_AFTER", 1)
    settings = _settings(tmp_path)
    w = GameWorld(n_players=4, auto_launch=False)
    h = SquadsHarness(w)
    judge = json.dumps({"goal_met": True, "summary": "Both squads finished.", "bugs": [],
                        "players": [{"name": "Player1", "blame": "hosed Player2", "credit": "led squad A"}]})
    llm = SquadsLLM(judge)

    real_squads = h.h.squads
    active_ticks = {"n": 0}

    async def squads_then_end(*a, **k):  # end both missions a tick after both squads are in one
        if len(w.instances) == 2 and all(r["state"] == "Active" for r in w.instances.values()):
            active_ticks["n"] += 1
            if active_ticks["n"] >= 2:
                for iid in list(w.instances):
                    w.c_mission_end({"instanceId": iid})
        return await real_squads(*a, **k)
    h.squads = squads_then_end
    rep = await ai.multi_playtest(settings, "co-op: both squads put out their fire", steps=12, llm=llm,
                                  harness=h, step_seconds=0, mode="squads", squads=2)

    assert rep["mode"] == "squads" and rep["squads"] == 2
    assert [(p["name"], p["squad"], p["pad"]) for p in rep["players"]] == [
        ("Player1", "A", 1), ("Player2", "A", 1), ("Player3", "B", 2), ("Player4", "B", 2)]
    # the harness queued idle players onto their own pad and launched each full squad
    acts = [a["action"] for a in rep["assists"]]
    assert "queue pad 1" in acts and "queue pad 2" in acts and "launch pad 1" in acts and "launch pad 2" in acts
    assert sorted(i["squadId"] for i in rep["instances"]) == ["S1", "S2"]
    # every player went lobby -> queued -> mission -> returned, and the run stopped there
    for name in ("Player1", "Player4"):
        phases = [x.split(":")[1] for x in rep["phases"][name]]
        assert phases[:3] == ["lobby", "queued", "mission"] and phases[-1] in ("returned", "results")
    assert max(s["n"] for s in rep["steps"]) < 12
    # one player call per player per tick, concurrently, with the squads guidance in the user message
    pcalls = [c for c in llm.calls if c.role == "player"]
    assert llm.max_in_flight >= 2
    first_tick = [s for s in rep["steps"] if s["n"] == 1]
    assert len(first_tick) == 4 and all(s["squad"]["phase"] == "lobby" for s in first_tick)
    assert all("## Squads mode" in c.user and "lobby -> squad pad" in c.user for c in pcalls)
    assert any('"pad_path":"Workspace.Station.Pad2"' in c.user and "squad B (pad 2)" in c.user for c in pcalls)
    assert any('"phase":"mission"' in c.user and '"instance":' in c.user for c in pcalls)
    # judge: per-player stats + blame instruction, and its per-player verdict lands in the report
    jcall = next(c for c in llm.calls if c.role == "judge")
    assert "## Per-player blame" in jcall.user and "## Phases per player" in jcall.user
    assert "## Harness assists" in jcall.user
    p1 = next(p for p in rep["per_player"] if p["name"] == "Player1")
    assert p1["blame"] == "hosed Player2" and p1["credit"] == "led squad A" and p1["squad"] == "A"
    assert "events" in p1 and p1["blame_service"] == {"teammateSprayed": 0}
    md = ms.format_report(rep)
    assert "**Mode:** squads (2 squad(s))" in md and "### Per player" in md and "hosed Player2" in md
    assert "Harness assists" in md
    saved = play.load_report(settings, rep["run_id"])
    assert saved["per_player"] == rep["per_player"] and "_blame_service" not in saved


async def test_squads_mode_without_lobby_starts_missions_directly(tmp_path):
    settings = _settings(tmp_path)
    w = GameWorld(n_players=2)
    h = SquadsHarness(w, lobby=False)
    llm = SquadsLLM(JUDGE)
    rep = await ai.multi_playtest(settings, "co-op", steps=3, llm=llm, harness=h, step_seconds=0, mode="squads")
    assert rep["assists"][0]["action"] == "lobby unavailable"
    assert any(a["action"].startswith("mission_start") for a in rep["assists"])
    assert len(w.instances) == 1 and all(p["instanceId"] == "M1" for p in w.players)
    assert [x.split(":")[1] for x in rep["phases"]["Player1"]][:2] == ["lobby", "mission"]


async def test_squads_mode_correction_keeps_squad_context(tmp_path):
    settings = _settings(tmp_path)
    w = GameWorld(n_players=2)
    rep = await ai.multi_playtest(settings, "co-op", steps=1, llm=SquadsLLM(JUDGE), harness=SquadsHarness(w),
                                  step_seconds=0, mode="squads")
    llm2 = FakeLLM({"player": [_a("move_to_instance", {"path": "Workspace.Station.Pad1"})]})
    out = await ai.correct_step(settings, rep["run_id"], 1, "Stand on your pad.", player="Player2", llm=llm2)
    assert out["after"]["action"] == "move_to_instance"
    assert "## Squads mode" in llm2.calls[0].user and "## Correction from a human tester" in llm2.calls[0].user


async def test_free_mode_unchanged_and_bad_mode(tmp_path):
    settings = _settings(tmp_path)
    rep = await ai.multi_playtest(settings, "g", steps=1, llm=SquadsLLM(JUDGE), harness=SquadsHarness(GameWorld()),
                                  step_seconds=0)
    assert rep["mode"] == "free" and "per_player" not in rep and "squad" not in rep["steps"][0]
    with pytest.raises(ValueError, match="mode"):
        await ai.multi_playtest(settings, "g", mode="chaos")


def test_player_and_judge_prompts_unchanged():
    """player.md / judge.md are frozen Mubit prompts: squads guidance lives in the user message."""
    for name in ("player", "judge"):
        text = (REPO / "mubit-tester" / "prompts" / f"{name}.md").read_text()
        assert "squad" not in text.lower() and "SquadPad" not in text
    assert "SquadPad" in ai.SQUADS_GUIDE
