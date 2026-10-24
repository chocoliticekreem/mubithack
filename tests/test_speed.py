"""Speed: concurrent coder/fixer calls over the spec's dependency DAG, background reflector, reply cache,
streaming early abort, shared 429 backoff, and runs/<slug>/timings.json. All offline (FakeLLM)."""

from __future__ import annotations

import dataclasses
import io
import json
import re
import shutil
import threading
import time

import pytest

from forge import llm as fllm
from forge.config import load_settings
from forge.llm import CachedLLM, FakeLLM, LLMResult, MubitLLM, fake_default_reply, stream_verdict
from forge.loop import UI, Run, new_game
from forge.memory import RunStore

needs_luau = pytest.mark.skipif(shutil.which("luau-compile") is None, reason="luau-compile not on PATH")


@pytest.fixture
def settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


def _path_of(user: str) -> str:
    m = re.search(r"^path:\s*(\S+)", user, re.MULTILINE)
    return m.group(1) if m else ""


class Clocked(FakeLLM):
    """FakeLLM that records when each call starts and ends (by role and file path)."""

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.spans: dict[tuple[str, str], tuple[float, float]] = {}

    def complete(self, role, user, *, session_id, max_tokens=4096):
        t0 = time.monotonic()
        res = super().complete(role, user, session_id=session_id, max_tokens=max_tokens)
        self.spans[(role, _path_of(user))] = (t0, time.monotonic())
        return res


def _run(settings, llm, slug="speed", jobs=8) -> Run:
    store = RunStore(settings, slug)
    store.ensure()
    store.save_state(store.new_state("x"))
    store.game_dir.mkdir(parents=True, exist_ok=True)
    return Run(settings, store, llm, UI(io.StringIO()), jobs=jobs)


DAG = [  # A, E independent; B and C need A; D needs B and C
    {"path": "ReplicatedStorage/A.luau", "purpose": "a", "depends": []},
    {"path": "ReplicatedStorage/B.luau", "purpose": "b", "depends": ["ReplicatedStorage/A.luau"]},
    {"path": "ReplicatedStorage/C.luau", "purpose": "c", "depends": ["ReplicatedStorage/A.luau"]},
    {"path": "ServerScriptService/D.server.luau", "purpose": "d",
     "depends": ["ReplicatedStorage/B.luau", "ReplicatedStorage/C.luau"]},
    {"path": "ReplicatedStorage/E.luau", "purpose": "e", "depends": []},
]


def _coder_reply(role, user):
    path = _path_of(user)
    name = path.rsplit("/", 1)[-1].split(".")[0]
    return f"```luau\nlocal {name} = {{}}\nfunction {name}.hello() return 1 end\nreturn {name}\n```"


@needs_luau
async def test_build_runs_the_dependency_dag_concurrently(settings):
    llm = Clocked({}, default=_coder_reply, latency=0.2)
    run = _run(settings, llm)
    run.spec = {"title": "t", "modules": DAG}
    t0 = time.monotonic()
    built, failed = await run.build_modules(DAG)
    wall = time.monotonic() - t0

    assert failed == [] and set(built) == {m["path"] for m in DAG}
    assert built.index("ReplicatedStorage/A.luau") < built.index("ReplicatedStorage/B.luau")
    # returned in dependency order, whatever finished first
    assert built.index("ServerScriptService/D.server.luau") > max(built.index("ReplicatedStorage/B.luau"),
                                                                   built.index("ReplicatedStorage/C.luau"))
    s = {p: llm.spans[("coder", p)] for p in (m["path"] for m in DAG)}
    a, b, c, d, e = (s[m["path"]] for m in DAG)
    # ordering: a module starts only after every module it depends on is written
    assert b[0] >= a[1] and c[0] >= a[1]
    assert d[0] >= b[1] and d[0] >= c[1]
    # concurrency: independent modules overlap (A with E, B with C)
    assert e[0] < a[1] and c[0] < b[1]
    assert llm.peak_concurrency >= 2
    # critical path A -> B|C -> D is 3 calls; serial would be 5 (loose bound: CI machines are busy)
    assert wall < 5 * 0.2 + 2.0
    # D was written with its dependencies' real code
    d_user = next(c.user for c in llm.calls if c.role == "coder" and _path_of(c.user).endswith("D.server.luau"))
    assert "function B.hello()" in d_user and "function C.hello()" in d_user


@needs_luau
async def test_jobs_bounds_concurrency(settings):
    mods = [{"path": f"ReplicatedStorage/M{i}.luau", "purpose": "m", "depends": []} for i in range(6)]
    llm = FakeLLM({}, default=_coder_reply, latency=0.1)
    run = _run(settings, llm, jobs=2)
    run.spec = {"modules": mods}
    await run.build_modules(mods)
    assert llm.peak_concurrency == 2
    llm1 = FakeLLM({}, default=_coder_reply, latency=0.05)
    run1 = _run(settings, llm1, slug="speed1", jobs=1)
    run1.spec = {"modules": mods}
    await run1.build_modules(mods)
    assert llm1.peak_concurrency == 1


@needs_luau
async def test_dependency_cycle_does_not_deadlock(settings):
    mods = [{"path": "ReplicatedStorage/X.luau", "purpose": "x", "depends": ["ReplicatedStorage/Y.luau"]},
            {"path": "ReplicatedStorage/Y.luau", "purpose": "y", "depends": ["ReplicatedStorage/X.luau"]}]
    run = _run(settings, FakeLLM({}, default=_coder_reply))
    run.spec = {"modules": mods}
    import asyncio
    built, _ = await asyncio.wait_for(run.build_modules(mods), 5)
    assert sorted(built) == sorted(m["path"] for m in mods)


@needs_luau
async def test_compile_errors_are_fixed_per_file_in_parallel_while_building(settings):
    mods = [{"path": f"ReplicatedStorage/Bad{i}.luau", "purpose": "b", "depends": []} for i in range(3)]
    broken = "```luau\nlocal x = (\nreturn x\n```"
    llm = FakeLLM({"coder": [broken] * 3}, default=_coder_reply, latency=0.15)
    run = _run(settings, llm)
    run.spec = {"modules": mods}
    await run.build_modules(mods)
    fixes = [c for c in llm.calls if c.role == "fixer"]
    assert len(fixes) == 3 and all("luau-compile failed" in c.user for c in fixes)
    assert run.check() == []
    assert llm.peak_concurrency == 3  # three fixers at once
    # the pipelined compile fixes reach the next iteration's record (the reflector learns from them)
    assert [f["kind"] for f in run.build_rec["fixes"]] == ["compile"] * 3


@needs_luau
async def test_parallel_fixes_keep_their_own_request_ids(settings):
    files = ["ReplicatedStorage/F1.luau", "ReplicatedStorage/F2.luau", "ReplicatedStorage/F3.luau"]
    llm = FakeLLM({}, default=_coder_reply, latency={"fixer": 0.1})
    run = _run(settings, llm)
    run.spec = {"modules": [{"path": p, "purpose": "", "depends": []} for p in files]}
    for p in files:
        run.write(p, "return {}\n")
    rec = {"issues": [{"path": p, "problem": f"broken {p}"} for p in files], "fixes": [], "steps": []}
    await run.fix_issues(rec, {})
    assert llm.peak_concurrency == 3
    by_rid = {f"fake-{i + 1}": _path_of(c.user) for i, c in enumerate(llm.calls)}
    assert sorted(f["path"] for f in rec["fixes"]) == files
    for f in rec["fixes"]:
        assert by_rid[f["request_id"]] == f["path"]


SPEC = {"title": "Coin", "slug": "coin", "pitch": "p", "core_loop": "c", "acceptance": ["a"],
        "modules": [{"path": "ReplicatedStorage/Config.luau", "purpose": "cfg", "depends": []},
                    {"path": "ServerScriptService/Game.server.luau", "purpose": "g",
                     "depends": ["ReplicatedStorage/Config.luau"]}]}
CRIT = {"score": 5, "summary": "s", "issues": [{"path": "ServerScriptService/Game.server.luau",
                                               "problem": "p", "fix_hint": "h"}], "done": False}


@needs_luau
async def test_reflector_runs_in_background_and_timings_are_saved(settings, monkeypatch):
    monkeypatch.setenv("FORGE_FUN_CRITIC", "1")
    def reply(role, user):
        if role == "designer":
            return json.dumps(SPEC)
        if role == "critic":
            return json.dumps(CRIT)
        if role == "reflector":
            return "# Lessons\n- learned\n"
        return fake_default_reply(role, user)

    llm = FakeLLM({}, default=reply, latency={"reflector": 0.5, "critic": 0.3, "fun_critic": 0.3,
                                              "coder": 0.05, "fixer": 0.05})
    slug = await new_game("coin game", iterations=2, use_studio=False, settings=settings, llm=llm,
                          ui=UI(io.StringIO()), jobs=4)
    store = RunStore(settings, slug)
    rec = json.loads((store.dir / "timings.json").read_text())
    assert rec["command"] == "new" and rec["jobs"] == 4 and rec["total_secs"] > 0 and rec["running"] is False
    # the dashboard's reader understands it: epoch stage times, per-call lanes, speedups
    from forge.dashboard import read_timings
    t = read_timings(store.dir / "timings.json")
    assert t["total_secs"] == rec["total_secs"] and len(t["calls"]) == len(rec["calls"])
    assert all(s["start"] > 1e9 and s["end"] >= s["start"] for s in t["stages"])
    assert {"role", "lane", "start", "end", "latency_ms", "step"} <= set(rec["calls"][0])
    assert any(s["stage"] == "total" and s["before_secs"] > s["after_secs"] for s in t["speedups"])
    st = {s["name"]: s for s in rec["stages"]}
    for name in ("design", "build", "iteration 1: critic", "iteration 1: fix", "iteration 2: critic"):
        assert name in st, name
    refl, crit2 = st["iteration 1: reflect (background)"], st["iteration 2: critic"]
    assert crit2["start_s"] < refl["end_s"]  # the next critic did not wait for the reflector
    # but the next fixer did (it reads lessons)
    fixers2 = [c for c in rec["calls"] if c["role"] == "fixer" and c["start_s"] >= crit2["end_s"]]
    assert fixers2 and all(c["start_s"] >= refl["end_s"] for c in fixers2)
    assert {c["role"] for c in rec["calls"]} >= {"designer", "coder", "critic", "fixer", "reflector"}
    # the fun critic (same inputs as the critic) runs alongside it, not after it
    crit = [c for c in rec["calls"] if c["role"] == "critic"]
    fun = [c for c in rec["calls"] if c["role"] == "fun_critic"]
    assert fun and all(f["start_s"] < c["end_s"] and c["start_s"] < f["end_s"] for c, f in zip(crit, fun))
    assert all(c["end_s"] >= c["start_s"] for c in rec["calls"])
    # each iteration's record keeps its own reflector call and lessons flag
    for n in (1, 2):
        r = store.load_iteration_json(n, "record.json")
        assert r["lessons_updated"] is True
        assert [c["role"] for c in r["calls"]].count("reflector") == 1
    assert "learned" in (settings.runs_dir / "lessons.md").read_text()


@needs_luau
async def test_feature_edits_run_alongside_coders_and_one_files_edits_stay_in_order(settings):
    from forge.feature import add_feature

    main, hud = "ServerScriptService/Main.server.luau", "StarterPlayerScripts/Hud.client.luau"
    store = RunStore(settings, "feat")
    store.ensure()
    store.save_spec({"title": "F", "pitch": "p", "core_loop": "c", "modules": []})
    store.save_state(store.new_state("idea"))
    for rel in (main, hud):
        (store.game_dir / rel).parent.mkdir(parents=True, exist_ok=True)
        (store.game_dir / rel).write_text(f"-- {rel}\nprint('boot')\n")
    plan = {"summary": "s", "telemetry": [], "acceptance": [],
            "new_modules": [{"path": "ReplicatedStorage/Shop.luau", "purpose": "shop", "depends": []},
                            {"path": "ServerScriptService/ShopService.luau", "purpose": "svc",
                             "depends": ["ReplicatedStorage/Shop.luau"]}],
            "edits": [{"path": main, "change": "first"}, {"path": hud, "change": "hud"},
                      {"path": main, "change": "second"}]}

    def reply(role, user):
        if role == "planner":
            return json.dumps(plan)
        if role == "fixer":  # append the change, keeping the file (the destructive guard stays happy)
            src = re.search(r"```luau\n(.*?)\n```", user, re.DOTALL).group(1)
            change = re.search(r"Change needed in this file: (\w+)", user).group(1)
            return f"```luau\n{src}\nprint('{change}')\n```"
        return _coder_reply(role, user)

    llm = Clocked({}, default=reply, latency={"coder": 0.3, "fixer": 0.2})
    res = await add_feature(settings, "feat", "add a shop", llm=llm, ui=UI(io.StringIO()), iterations=0,
                            jobs=8, log=lambda _: None)
    assert res["built"] == ["ReplicatedStorage/Shop.luau", "ServerScriptService/ShopService.luau"]
    assert res["edited"] == [main, main, hud]
    text = (store.game_dir / main).read_text()
    assert text.index("print('first')") < text.index("print('second')")  # same file: in plan order, both kept
    shop = llm.spans[("coder", "ReplicatedStorage/Shop.luau")]
    hud_edit = llm.spans[("fixer", hud)]
    assert hud_edit[0] < shop[1]  # the hook-in edit did not wait for the coders
    assert json.loads((store.dir / "timings.json").read_text())["command"] == "feature"


# --- cache -----------------------------------------------------------------------------------


def test_cache_hits_on_identical_input_and_misses_on_any_change(tmp_path, monkeypatch):
    inner = FakeLLM({}, default=lambda r, u: "```luau\nreturn 1\n```")
    cache = CachedLLM(inner, tmp_path / "cache")
    a = cache.complete("coder", "module A\nlessons v1", session_id="s1")
    b = cache.complete("coder", "module A\nlessons v1", session_id="other-session")
    assert not a.cached and b.cached and b.text == a.text and b.request_id == a.request_id
    assert len(inner.calls) == 1 and cache.hits == 1
    cache.complete("coder", "module A\nlessons v2", session_id="s1")  # lessons changed
    cache.complete("coder", "module A\nlessons v1", session_id="s1", max_tokens=99)
    assert len(inner.calls) == 3
    # an edited system prompt never reuses a reply made under the old one
    monkeypatch.setitem(fllm._PROMPT_CACHE, "coder", fllm.load_prompt("coder") + "\nedited")
    cache.complete("coder", "module A\nlessons v1", session_id="s1")
    assert len(inner.calls) == 4
    # roles outside CACHE_ROLES always call through
    inner.default = lambda r, u: "{}"
    cache.complete("player", "x", session_id="s")
    cache.complete("player", "x", session_id="s")
    assert [c.role for c in inner.calls].count("player") == 2
    # fixes: only compile-error repairs are cached; a critic/improve fix or a human correction (the Mubit
    # training signal) always makes a real call, so a repeat gets a fresh attempt
    inner.default = lambda r, u: "```luau\nreturn 2\n```"
    for msg in ("## Problem\nluau-compile failed (attempt 1/3):\nx", "## Problem\nHuman playtester correction:\nx",
                "## Problem\nPlaytest critique:\n- x"):
        cache.complete("fixer", msg, session_id="s")
        cache.complete("fixer", msg, session_id="s")
    assert [c.role for c in inner.calls].count("fixer") == 1 + 2 + 2


def test_cache_skips_aborted_and_cut_off_replies(tmp_path):
    class Bad(FakeLLM):
        def complete(self, role, user, *, session_id, max_tokens=4096):
            res = super().complete(role, user, session_id=session_id, max_tokens=max_tokens)
            return dataclasses.replace(res, aborted="abort" in user, output_tokens=max_tokens if "cut" in user else 5)

    inner = Bad({}, default=lambda r, u: "prose")
    cache = CachedLLM(inner, tmp_path / "c")
    for msg in ("abort", "abort", "cut", "cut"):
        cache.complete("coder", msg, session_id="s")
    assert len(inner.calls) == 4 and cache.hits == 0


@needs_luau
async def test_cached_build_makes_no_calls(settings, tmp_path):
    inner = FakeLLM({}, default=_coder_reply)
    for slug in ("first", "second"):
        run = _run(settings, CachedLLM(inner, tmp_path / "cache"), slug=slug)
        run.spec = {"title": "t", "modules": DAG}
        await run.build_modules(DAG)
    assert len([c for c in inner.calls if c.role == "coder"]) == len(DAG)  # second build: all hits
    assert all(c.get("cached") for c in run.calls)


# --- no wasted repair calls ------------------------------------------------------------------


def test_stray_closing_bracket_is_salvaged_without_a_repair_call():
    # a real critic reply from a Mubit run: one `]` too many before "done" cost a whole repair call
    reply = ('{"score": 6, "summary": "s", "issues": [{"path": "a.luau", "problem": "p", '
             '"fix_hint": "spin it"}]], "done": false}')
    assert "score" not in fllm.extract_json_object(reply)  # the old pick: the nested issue object
    llm = FakeLLM({"critic": [reply]})
    obj, _ = llm.complete_json("critic", "x", session_id="s", required=["score", "summary", "issues", "done"])
    assert obj["score"] == 6 and obj["issues"][0]["fix_hint"] == "spin it" and len(llm.calls) == 1
    # the object with the required keys wins over an earlier fenced one
    two = '```json\n{"note": 1}\n```\n{"score": 1, "summary": "", "issues": [], "done": true}'
    assert fllm.extract_json_object(two, ["score"])["score"] == 1


def test_critique_without_done_needs_no_repair_call():
    from forge import roles
    llm = FakeLLM({"critic": [json.dumps({"score": 6, "summary": "s", "issues": []})]})
    c = roles.critique(llm, {"modules": []}, {}, "", {}, session_id="s")
    assert c["done"] is False and c["score"] == 6 and len(llm.calls) == 1


async def test_repair_calls_are_counted_in_the_call_line(settings):
    llm = FakeLLM({"critic": ["not json", json.dumps({"score": 5, "summary": "", "issues": [], "done": False})]})
    run = _run(settings, llm)
    await run.call("critic", "c", lambda l, *a, **k: l.complete_json(*a, **k), "critic", "x",
                   session_id="s", required=["score"])
    assert run.calls[-1]["request_ids"] == ["fake-1", "fake-2"]


# --- streaming / backoff ---------------------------------------------------------------------


def test_stream_verdict():
    assert stream_verdict("coder", "Sure! " * 300) == "abort"
    assert stream_verdict("coder", "```luau\nlocal x = 1\n") == "more"
    assert stream_verdict("coder", "```luau\nlocal x = 1\n```") == "done"
    assert stream_verdict("critic", "I think " * 300) == "abort"
    assert stream_verdict("critic", '{"score": 5') == "more"
    assert stream_verdict("reflector", "# Lessons " * 300) == "more"


class _Stream:
    def __init__(self, chunks):
        self.chunks = chunks
        self.read = 0
        self.response = type("R", (), {"headers": {"x-middleware-request-id": "mreq_s"}})()
        usage = type("U", (), {"input_tokens": 10, "output_tokens": 3})()
        self.current_message_snapshot = type("M", (), {"usage": usage, "model": "m"})()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    @property
    def text_stream(self):
        for c in self.chunks:
            self.read += 1
            yield c

    def get_final_message(self):
        return self.current_message_snapshot


def _settings(tmp_path):
    from forge.config import Settings
    return Settings(mubit_api_key="mbt_x", provider="anthropic", base_url="https://api.mubit.ai/anthropic",
                    model="m", studio_mcp_path="", sync_port=1, repo_root=tmp_path, runs_dir=tmp_path / "runs",
                    base_game_dir=tmp_path / "game")


def test_streaming_aborts_prose_and_stops_at_closed_block(tmp_path):
    llm = MubitLLM(_settings(tmp_path), None)
    prose = _Stream(["blah " * 100] * 10)
    llm._client = type("C", (), {"messages": type("Ms", (), {"stream": lambda self, **k: prose})()})()
    res = llm.complete("coder", "write it", session_id="s")
    assert res.aborted and prose.read < 10 and res.request_id == "mreq_s"
    done = _Stream(["```luau\n", "return 1\n", "```", "\nAnd here is why..." * 50, "x"])
    llm._client = type("C", (), {"messages": type("Ms", (), {"stream": lambda self, **k: done})()})()
    res = llm.complete("coder", "write it", session_id="s")
    assert not res.aborted and res.text.endswith("```") and done.read == 3


class _Err(Exception):
    def __init__(self, status, headers):
        super().__init__(f"status {status}")
        self.status_code = status
        self.response = type("R", (), {"headers": headers})()


def test_429_cooldown_is_shared_across_threads(tmp_path):
    llm = MubitLLM(_settings(tmp_path), None)
    sleeps: dict[str, list[float]] = {"a": [], "b": []}
    who = threading.local()
    llm.sleep = lambda s: sleeps[who.name].append(s)
    n = []

    def call(system, user, sid, mt):
        n.append(user)
        if user == "a" and n.count("a") == 1:
            raise _Err(429, {"retry-after": "5"})
        return "ok", "rid", 1, 1, "m"

    llm._call_anthropic = call

    def go(name):
        who.name = name
        llm.complete("coder", name, session_id="s")

    ta = threading.Thread(target=go, args=("a",))
    ta.start()
    ta.join()
    tb = threading.Thread(target=go, args=("b",))
    tb.start()
    tb.join()
    assert sleeps["a"] == [5.0]
    assert len(sleeps["b"]) == 1 and 4.0 < sleeps["b"][0] <= 5.0  # b waited out a's 429


def test_429_gets_more_attempts_than_other_errors(tmp_path):
    llm = MubitLLM(_settings(tmp_path), None)
    llm.sleep = lambda s: None
    n = []

    def always_429(*a):
        n.append(1)
        raise _Err(429, {"retry-after": "0"})

    llm._call_anthropic = always_429
    with pytest.raises(fllm.LLMError):
        llm.complete("coder", "x", session_id="s")
    assert len(n) == fllm.RATE_LIMIT_TRIES


def test_make_llm_wraps_mubit_in_cache(tmp_path, monkeypatch):
    monkeypatch.delenv("FORGE_FAKE_LLM", raising=False)
    monkeypatch.delenv("FORGE_NO_CACHE", raising=False)
    s = _settings(tmp_path)
    llm = fllm.make_llm(s, None)
    assert isinstance(llm, CachedLLM) and llm.dir == s.runs_dir / ".cache" / "llm"
    monkeypatch.setenv("FORGE_NO_CACHE", "1")
    assert isinstance(fllm.make_llm(s, None), MubitLLM)
    assert isinstance(LLMResult("t", "coder", None, "m", 0, None, None).cached, bool)
