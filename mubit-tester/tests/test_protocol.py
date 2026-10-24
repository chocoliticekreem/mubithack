"""Tests for mubit_tester.protocol: the 5-phase QA protocol (understand, plan, execute, investigate,
report) with screenshots and vision, driven by FakeLLM and a fake Studio/harness."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from forge import llm as llm_mod
from forge.config import Settings
from forge.llm import FakeLLM, load_prompt
from mubit_tester import ai, play, protocol

PNG = (b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89"
       b"\x00\x00\x00\rIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82")


def _settings(tmp_path: Path) -> Settings:
    return Settings(
        mubit_api_key=None, provider="anthropic", base_url="https://api.mubit.ai/anthropic",
        model="claude-sonnet-5", studio_mcp_path="", sync_port=34873, repo_root=tmp_path,
        runs_dir=tmp_path / "runs", base_game_dir=tmp_path / "game",
    )


def _game(tmp_path: Path) -> Path:
    root = tmp_path / "games" / "demo"
    gd = root / "game"
    for rel, src in {
        "ServerScriptService/Tycoon.luau": "-- buy pads: dropperButton Touched, dropper_bought\nreturn {}",
        "StarterPlayerScripts/Hud.client.luau": "-- Cash label HUD\n",
        "ServerScriptService/ForgeTest.server.luau": "-- harness",
        "tools/sync.py": "",
    }.items():
        (gd / rel).parent.mkdir(parents=True, exist_ok=True)
        (gd / rel).write_text(src)
    (root / "spec.json").write_text(json.dumps({
        "title": "Demo Tycoon", "pitch": "Cubes make cash.", "core_loop": "Droppers drop cubes; buy pads upgrade.",
        "acceptance": ["The map is built (map_built is 1)", "Cash rises over time",
                       "Touching the dropper pad with enough cash buys a dropper", "The HUD shows Cash"],
    }))
    return gd


class FakeStudio:
    studio_id = "fake-studio"

    def __init__(self):
        self.cash = 0
        self.shots: list[Path] = []
        self.luau: list[tuple[str, str]] = []
        self.stopped = 0
        self.errors: list[dict] = []
        self.log = "boot\n"

    async def execute_luau(self, code, datamodel="Edit"):
        self.luau.append((code, datamodel))
        if "GetAllTags" in code:
            self.cash += 5
            return json.dumps({"world": {"tags": {"BuyPad": 2, "Cube": 3}, "attrs": {}},
                               "players": [{"userId": 1, "name": "Tester", "attrs": {},
                                            "leaderstats": {"Cash": self.cash}, "pos": [0, 3, 0], "health": 100}]})
        if "GetPivot" in code:
            return json.dumps([{"path": "Workspace.Plot1.DropperPad", "class": "Part", "pos": [10, 1, 0], "dist": 10}])
        if "SetAttribute" in code:
            return json.dumps({"ok": True})
        return "{}"

    async def screenshot(self, out, camera=None, look_at=None):
        out = Path(out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(PNG)
        self.shots.append(out)
        return out

    async def console(self):
        self.log += f"tick {len(self.shots)}\n"
        return self.log

    async def probe_report(self):
        return {"errors": list(self.errors)}

    async def stop(self):
        self.stopped += 1


class FakeHarness:
    def __init__(self, studio):
        self.studio = studio
        self.started_play = True
        self.acts: list = []
        self.calls: list = []
        self.t = 0

    async def ensure_ready(self, timeout=30):
        return {"ok": True}

    async def players(self):
        return [{"userId": 1, "name": "Tester", "helmet": 1}]

    async def observe(self, user_id):
        return {"me": {"pos": [0, 3, 0], "attrs": {}}, "hud": [f"Cash: {self.studio.cash}"],
                "ui": [{"text": "Shop", "path": "Hud.Shop"}], "things": [], "prompts": []}

    async def act(self, user_id, action, **args):
        self.acts.append((user_id, action, args))
        return {"done": True, "detail": f"{action} ok"}

    async def call(self, cmd, **args):
        self.calls.append((cmd, args))
        if cmd == "inspect":
            return {"class": "Part", "name": "DropperPad", "attrs": {}, "touch": "no Touched listener"}
        return True

    async def events(self, since=None):
        self.t += 1
        return {"now": self.t, "events": [{"t": self.t, "kind": "touched", "data": {}}] if since else []}

    async def counters(self):
        return {"map_built": 1, "dropper_bought": 0}


PLAN = {
    "understanding": "A tycoon: droppers make cash, pads buy upgrades.",
    "risks": ["buy pads may not register touches"],
    "hypotheses": ["H1: the map builds", "H2: cash rises", "H3: the dropper pad buys", "H4: HUD shows cash"],
    "steps": [
        {"n": 1, "intent": "baseline", "hypothesis": "H1", "acceptance": [1], "action": {"action": "observe"},
         "settle": 0, "expect": "map_built is 1", "checks": [{"path": "counters.map_built", "op": "==", "value": 1},
                                                              {"path": "errors.new", "op": "==", "value": 0}],
         "screenshot_key": True},
        {"n": 2, "intent": "cash rises", "acceptance": [2], "action": {"action": "wait", "args": {"seconds": 0}},
         "settle": 0, "expect": "Cash goes up", "checks": [{"path": "player.leaderstats.Cash", "op": "increased"}]},
        {"n": 3, "intent": "buy a dropper", "acceptance": [3],
         "action": {"action": "walk_to", "args": {"path": "Workspace.Plot1.DropperPad"}}, "settle": 0,
         "expect": "dropper_bought goes up", "checks": [{"path": "counters.dropper_bought", "op": "increased"}]},
        {"n": 4, "intent": "HUD shows cash", "acceptance": [4], "action": "observe", "settle": 0,
         "expect": "a Cash label", "checks": [{"path": "obs.hud", "op": "contains", "value": "Cash"}],
         "visual": True},
    ],
}
JUDGE_FAIL = {"verdict": "fail", "actual": "dropper_bought stayed 0", "reason": "counter did not move",
              "probes": [{"cmd": "inspect", "args": {"path": "Workspace.Plot1.DropperPad"}},
                         {"cmd": "set_attr", "args": {"path": "x", "key": "y", "value": 1}}], "bug": None}
JUDGE_INVESTIGATED = {"verdict": "fail", "actual": "reproduced: dropper_bought 0 -> 0", "reason": "pad has no listener",
                      "probes": [], "bug": {"title": "Dropper pad never buys", "severity": "high",
                                            "repro": ["1. spawn", "2. walk onto DropperPad with 30 cash"],
                                            "expected": "dropper_bought +1", "actual": "stays 0",
                                            "root_cause": "Touched is not connected", "fix_target": "Tycoon.luau"}}
JUDGE_VISUAL = {"verdict": "pass", "actual": "HUD reads Cash: 25", "reason": "label visible", "probes": [], "bug": None}
VISUAL = {"summary": "Bright but the HUD overlaps the shop button.", "score": 5,
          "issues": [{"title": "Cash label overlaps Shop button", "screenshot": "step-04.png", "kind": "ui_overlap",
                      "severity": "medium", "detail": "top-left", "suggestion": "move the Shop button down"}]}


def _llm(**extra):
    return FakeLLM({"test_planner": [json.dumps(PLAN)],
                    "step_judge": [json.dumps(JUDGE_FAIL), json.dumps(JUDGE_INVESTIGATED), json.dumps(JUDGE_VISUAL)],
                    "visual_judge": [json.dumps(VISUAL)], **extra})


def _run(tmp_path, llm=None, **kw):
    settings = _settings(tmp_path)
    studio = FakeStudio()
    harness = FakeHarness(studio)
    llm = llm or _llm()
    rep = asyncio.run(protocol.qa_test(settings, game_dir=_game(tmp_path), llm=llm, studio=studio,
                                       harness=harness, **kw))
    return settings, studio, harness, llm, rep


def test_prompts_exist_and_roles_registered():
    for role in protocol.ROLES:
        assert role in llm_mod.ROLES
        text = load_prompt(role)
        assert "Reply with ONLY one JSON object" in text
        assert "{" in text  # output schema documented in the fixed prompt


def test_full_protocol_run(tmp_path):
    settings, studio, harness, llm, rep = _run(tmp_path)
    assert not rep["errors"], rep["errors"]
    test_dir = Path(rep["test_dir"])
    assert test_dir == settings.runs_dir / "demo" / "tests" / rep["run_id"]

    # 1. understand: spec + census + a first screenshot
    und = rep["understand"]
    assert und["spec"]["title"] == "Demo Tycoon"
    assert und["census"]["tags"] == {"BuyPad": 2, "Cube": 3}
    assert und["files"] == ["ServerScriptService/Tycoon.luau", "StarterPlayerScripts/Hud.client.luau"]
    assert (test_dir / "step-00.png").read_bytes() == PNG

    # 2. plan: the planner saw the acceptance list and the census
    plan_call = next(c for c in llm.calls if c.role == "test_planner")
    assert "1. The map is built" in plan_call.user and '"BuyPad":2' in plan_call.user
    assert '"path":"Workspace.Plot1.DropperPad"' in plan_call.user  # landmarks: real paths, no guessing
    assert [s["n"] for s in rep["plan"]["steps"]] == [1, 2, 3, 4]
    assert rep["plan"]["steps"][3]["action"] == {"action": "observe", "args": {}}  # "observe" string normalized

    # 3. execute: one screenshot per step, machine checks decide the easy steps without an LLM call
    for n in (1, 2, 3, 4):
        assert (test_dir / f"step-{n:02d}.png").exists()
    s1, s2, s3, s4 = rep["steps"]
    assert s1["final"]["verdict"] == "pass" and s1["final"]["decided_by"] == "checks"
    assert s2["final"]["verdict"] == "pass" and s2["checks"][0]["before"] < s2["checks"][0]["actual"]
    assert s1["console"]  # new console lines are captured per step
    assert (1, "walk_to", {"path": "Workspace.Plot1.DropperPad"}) in harness.acts

    # 4. investigate: reproduce (the step ran twice), only read-only probes ran, then a ruling
    assert s3["verdict"]["verdict"] == "fail"
    inv = s3["investigation"]
    assert inv["reproduce"]["reproduced"] is True
    assert (test_dir / "step-03-repro.png").exists()
    assert [e["cmd"] for e in inv["evidence"]] == ["inspect", "set_attr"]
    assert inv["evidence"][1]["result"].startswith("refused")
    assert ("inspect", {"path": "Workspace.Plot1.DropperPad"}) in harness.calls
    assert not any(c[0] == "set_attr" for c in harness.calls)
    inv_call = [c for c in llm.calls if c.role == "step_judge"][1]
    assert "## Mode\ninvestigate" in inv_call.user and "## Reproduction" in inv_call.user
    assert "no Touched listener" in inv_call.user

    # visual step: the judge got the screenshot attached (FakeLLM has no vision: names in the text)
    vis_step_call = [c for c in llm.calls if c.role == "step_judge"][2]
    assert "## Attached screenshots\n- step-04.png" in vis_step_call.user
    assert s4["final"]["verdict"] == "pass"

    # 5. report: acceptance, bugs with repro/severity/screenshots/fix target, visual review
    status = {a["n"]: a["status"] for a in rep["acceptance"]}
    assert status == {1: "pass", 2: "pass", 3: "fail", 4: "pass"}
    assert rep["goal_met"] is False
    bug = rep["bugs"][0]
    assert bug["title"] == "Dropper pad never buys" and bug["severity"] == "high"
    assert bug["fix_target"] == "ServerScriptService/Tycoon.luau"
    assert bug["repro"] == ["1. spawn", "2. walk onto DropperPad with 30 cash"]
    assert bug["reproduced"] is True and any(p.endswith("step-03.png") for p in bug["screenshots"])
    vbug = next(b for b in rep["bugs"] if b["category"] == "visual")
    assert vbug["title"].startswith("Visual: Cash label overlaps") and vbug["screenshots"][0].endswith("step-04.png")
    vcall = next(c for c in llm.calls if c.role == "visual_judge")
    assert "## Attached screenshots" in vcall.user and "step-00.png" in vcall.user and "step-03.png" in vcall.user
    assert rep["visual"]["score"] == 5

    md = (test_dir / "report.md").read_text()
    for section in ("## 1. Understand", "## 2. Plan", "## 3. Execute", "## 4. Investigate", "## 5. Report"):
        assert section in md
    assert "Dropper pad never buys" in md and "step-03.png" in md
    # mirrored so report / reports / suggest_fix / playtest_correct find it
    assert play.load_report(settings, rep["run_id"])["kind"] == "protocol"
    assert any(r["run_id"] == rep["run_id"] for r in play.list_reports(settings))
    assert studio.stopped == 1  # the harness started play, so the tester stops it
    assert set(rep["timings"]) >= {"understand_ms", "plan_ms", "execute_ms", "visual_ms", "total_ms"}
    assert all(c.session_id == rep["session_id"] for c in llm.calls)


def test_plan_failure_falls_back_to_a_baseline_look(tmp_path):
    llm = FakeLLM({"test_planner": ["not json"] * 3, "step_judge": [json.dumps(JUDGE_VISUAL)],
                   "visual_judge": [json.dumps({"summary": "ok", "score": 7, "issues": []})]})
    _, _, _, _, rep = _run(tmp_path, llm=llm)
    assert rep["plan"]["fallback"] is True
    assert any(e.startswith("plan:") for e in rep["errors"])
    assert len(rep["steps"]) == 1 and rep["steps"][0]["final"]["verdict"] == "pass"


def test_corrections_go_to_the_same_task_and_session(tmp_path):
    settings, _, _, _, rep = _run(tmp_path)
    fix = FakeLLM({
        "step_judge": [json.dumps({"verdict": "inconclusive", "actual": "x", "reason": "the pad needs 25 cash first"})],
        "test_planner": [json.dumps(PLAN)],
        "visual_judge": [json.dumps({"summary": "fine", "score": 8, "issues": []})],
    })
    out = asyncio.run(ai.correct_step(settings, rep["run_id"], 3, "you never had 25 cash; inconclusive", llm=fix))
    assert out["role"] == "step_judge" and out["before"]["verdict"] == "fail"
    assert out["after"]["verdict"] == "inconclusive"
    call = fix.calls[0]
    assert call.session_id == rep["session_id"]
    assert "## Mode\ninvestigate" in call.user  # the last judgement of that step is the one corrected
    assert call.user.endswith("## Correction from a human tester\nyou never had 25 cash; inconclusive")

    asyncio.run(ai.correct_step(settings, rep["run_id"], 0, "give cash with set_attr before buying", llm=fix))
    assert fix.calls[1].role == "test_planner" and "## Acceptance (numbered)" in fix.calls[1].user
    asyncio.run(ai.correct_step(settings, rep["run_id"], -1, "the overlap is fine", llm=fix))
    assert fix.calls[2].role == "visual_judge" and "## Attached screenshots" in fix.calls[2].user
    saved = play.load_report(settings, rep["run_id"])
    assert [c["role"] for c in saved["corrections"]] == ["step_judge", "test_planner", "visual_judge"]
    with pytest.raises(ValueError):
        asyncio.run(ai.correct_step(settings, rep["run_id"], 99, "x", llm=fix))


@pytest.mark.parametrize("check,before,after,ok", [
    ({"path": "counters.a", "op": "==", "value": 1}, {}, {"counters": {"a": 1}}, True),
    ({"path": "counters.a", "op": ">=", "value": 2}, {}, {"counters": {"a": 1}}, False),
    ({"path": "counters.a", "op": "increased"}, {"counters": {"a": 1}}, {"counters": {"a": 3}}, True),
    ({"path": "counters.a", "op": "decreased"}, {"counters": {"a": 1}}, {"counters": {"a": 3}}, False),
    ({"path": "counters.a", "op": "unchanged"}, {"counters": {"a": 1}}, {"counters": {"a": 1}}, True),
    ({"path": "counters.a", "op": "changed"}, {"counters": {"a": 1}}, {"counters": {"a": 1}}, False),
    ({"path": "counters.zz", "op": "exists"}, {}, {"counters": {}}, False),
    ({"path": "counters.zz", "op": "missing"}, {}, {"counters": {}}, True),
    ({"path": "counters.zz", "op": "=="}, {}, {"counters": {}}, False),
    ({"path": "obs.hud", "op": "contains", "value": "cash"}, {}, {"obs": {"hud": ["Cash: 5"]}}, True),
    ({"path": "obs.ui.0.text", "op": "==", "value": "Buy"}, {}, {"obs": {"ui": [{"text": "Buy"}]}}, True),
    ({"path": "player.pos", "op": "near", "value": {"pos": [0, 0, 0], "radius": 5}}, {}, {"player": {"pos": [3, 0, 0]}}, True),
    ({"path": "player.pos", "op": "near", "value": {"pos": [0, 0, 0], "radius": 2}}, {}, {"player": {"pos": [3, 0, 0]}}, False),
    ({"path": "world.attrs.State", "op": "==", "value": "Active"}, {}, {"world": {"attrs": {"State": "Active"}}}, True),
])
def test_evaluate_check(check, before, after, ok):
    assert protocol.evaluate_check(check, before, after)["ok"] is ok


def test_unknown_op_is_not_a_pass_or_fail():
    assert protocol.evaluate_check({"path": "a", "op": "~="}, {}, {"a": 1})["ok"] is None


def test_new_errors_and_diff():
    before = [{"message": "a", "count": 1}]
    after = [{"message": "a", "count": 2}, {"message": "b"}, "c"]
    assert [e["message"] for e in protocol.new_errors(before, after)] == ["a", "b", "c"]
    assert protocol.new_errors(after, after) == []
    d = protocol.snapshot_diff({"counters": {"x": 1}, "obs": {"hud": ["Cash: 1"]}},
                               {"counters": {"x": 2}, "obs": {"hud": ["Cash: 2"], "ui": [{"text": "Buy"}]}})
    assert d["changed"] == {"counters.x": [1, 2]}
    assert d["hud_new"] == ["Cash: 2"] and d["buttons_new"] == ["Buy"]


def test_server_errors_become_bugs_with_the_script_as_target(tmp_path):
    gd = _game(tmp_path)
    rep = {"understand": {"spec": {"acceptance": ["no errors"]}, "files": protocol.game_files(gd)},
           "steps": [{"n": 1, "intent": "baseline", "action": {"action": "observe"}, "acceptance": [1],
                      "final": {"verdict": "pass", "actual": "ok"}, "screenshot": "x/step-01.png",
                      "new_errors": [{"message": "Tycoon.luau:12: attempt to index nil", "script": "ServerScriptService.Tycoon"}]}],
           "visual": {}}
    protocol.build_findings(_settings(tmp_path), rep, gd)
    bug = rep["bugs"][0]
    assert bug["category"] == "error" and bug["severity"] == "high"
    assert bug["fix_target"] == "ServerScriptService/Tycoon.luau"
    assert rep["goal_met"] is True and rep["acceptance"][0]["status"] == "pass"


def test_pick_key_shots_prefers_failures_and_caps():
    rep = {"understand": {"screenshot": "d/step-00.png"},
           "steps": [{"n": i, "screenshot": f"d/step-{i:02d}.png", "intent": "", "expect": "",
                      "final": {"verdict": "fail" if i == 5 else "pass"}, "screenshot_key": i == 2}
                     for i in range(1, 8)]}
    shots = protocol.pick_key_shots(rep, 4)
    assert [s["n"] for s in shots] == [0, 2, 5, 7]


def test_slug_for(tmp_path):
    gd = _game(tmp_path)
    assert protocol.slug_for(gd) == "demo"
    assert protocol.slug_for(tmp_path / "game") == "game"


class _Raw:
    def __init__(self, text):
        self.headers = {"x-middleware-request-id": "req-vision-1"}
        self._text = text

    def parse(self):
        return SimpleNamespace(content=[SimpleNamespace(type="text", text=self._text)],
                               usage=SimpleNamespace(input_tokens=900, output_tokens=40), model="claude-sonnet-5")


def test_mubit_vision_call_sends_image_blocks(tmp_path):
    sent = {}

    def create(**kw):
        sent.update(kw)
        return _Raw(json.dumps(VISUAL))

    llm = object.__new__(llm_mod.MubitLLM)
    llm.provider, llm.model, llm.log_path = "anthropic", "claude-sonnet-5", tmp_path / "calls.jsonl"
    llm._log_lock = __import__("threading").Lock()
    llm.sleep = lambda s: None
    llm._client = SimpleNamespace(messages=SimpleNamespace(with_raw_response=SimpleNamespace(create=create)))
    img = tmp_path / "step-01.png"
    img.write_bytes(PNG)
    obj, res, seen = protocol.complete_json_images(llm, "visual_judge", "## Game\nx", [img, tmp_path / "missing.png"],
                                                   session_id="qa-1", required=["summary", "issues"])
    assert seen == 1 and res.request_id == "req-vision-1" and obj["score"] == 5
    content = sent["messages"][0]["content"]
    assert content[0]["type"] == "image" and content[0]["source"]["media_type"] == "image/png"
    assert content[-1] == {"type": "text", "text": "## Game\nx"}
    assert sent["system"] == load_prompt("visual_judge") and sent["metadata"] == {"user_id": "qa-1"}
    log = [json.loads(x) for x in (tmp_path / "calls.jsonl").read_text().splitlines()]
    assert log[0]["images"] == 1 and log[0]["request_id"] == "req-vision-1"
    trace = next((tmp_path / "traces").glob("*-visual_judge-req-vision-1.json"))
    assert "[attached images: step-01.png]" in json.loads(trace.read_text())["user"]


def test_vision_hook_on_llm_is_preferred(tmp_path):
    class VisionLLM(FakeLLM):
        def complete_images(self, role, user, images, *, session_id, max_tokens=2048):
            self.seen = [n for n, _, _ in images]
            return self.complete(role, user, session_id=session_id, max_tokens=max_tokens)

    img = tmp_path / "a.png"
    img.write_bytes(PNG)
    llm = VisionLLM({"visual_judge": [json.dumps(VISUAL)]})
    _, _, seen = protocol.complete_json_images(llm, "visual_judge", "u", [img], session_id="s",
                                               required=["summary", "issues"])
    assert seen == 1 and llm.seen == ["a.png"] and "Attached screenshots" not in llm.calls[0].user


def test_acceptance_passes_only_when_every_covering_step_passes(tmp_path):
    gd = _game(tmp_path)
    rep = {"understand": {"spec": {"acceptance": ["a", "b"]}, "files": protocol.game_files(gd)},
           "steps": [{"n": 1, "acceptance": [1, 2], "final": {"verdict": "pass", "actual": ""}},
                     {"n": 2, "acceptance": [2], "final": {"verdict": "inconclusive", "actual": ""}}],
           "visual": {"issues": [
               {"title": "Pads blend into the floor", "kind": "ugly", "severity": "medium", "detail": "dropper pad"},
               {"title": "Label clipped", "kind": "unreadable", "severity": "low", "detail": "cash"}]}}
    protocol.build_findings(_settings(tmp_path), rep, gd)
    assert [a["status"] for a in rep["acceptance"]] == ["pass", "inconclusive"]
    assert rep["goal_met"] is None
    targets = {b["title"]: b["fix_target"] for b in rep["bugs"]}
    assert targets["Visual: Pads blend into the floor"] == "ServerScriptService/Tycoon.luau"
    assert targets["Visual: Label clipped"] == "StarterPlayerScripts/Hud.client.luau"
