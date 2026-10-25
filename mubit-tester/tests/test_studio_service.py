"""Native companion ownership, cancellation, and request-boundary tests."""
import asyncio
from dataclasses import replace
import json
from pathlib import Path
import threading
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest

from forge.config import load_settings
from mubit_tester import studio_service as mod

ROOT = Path(__file__).resolve().parents[2]


class FakeStudio:
    playing = False
    stopped = 0
    identities = {'other': 'other-marker', 'chosen': 'test-marker'}
    codes = []
    synced = []
    def __init__(self, *args, studio_id=None, **kwargs):
        self.studio_id = studio_id
    async def __aenter__(self): return self
    async def __aexit__(self, *args): pass
    async def list_studios(self):
        return [{'id': key, 'name': key} for key in self.identities]
    async def execute_luau(self, code):
        FakeStudio.codes.append(code)
        if code == mod.MARKER_CODE:
            return json.dumps({'marker': self.identities[self.studio_id], 'name': 'Local', 'placeId': 0})
        if '-- MuMakePreflight' in code:
            return json.dumps({'ok': True})
        if '-- MuMakeMark' in code:
            return '1'
        return 'installed'
    async def sync(self, root):
        FakeStudio.synced.append(Path(root))
        return 'OK 1 files, changed: ServerScriptService/Coins.server.luau; skipped 0, fetched 0'
    async def state(self): return {'playing': self.playing}
    async def play(self): FakeStudio.playing = True
    async def stop(self):
        FakeStudio.playing = False
        FakeStudio.stopped += 1
    async def probe_report(self): return {'errors': []}


@pytest.fixture
def service(tmp_path):
    FakeStudio.playing = False
    FakeStudio.stopped = 0
    FakeStudio.codes, FakeStudio.synced = [], []
    settings = replace(load_settings(), mubit_api_key=None, repo_root=ROOT, runs_dir=tmp_path)
    c = mod.Companion(settings, FakeStudio, tmp_path)
    c.sessions['test-marker'] = {'studio_id': 'chosen', 'name': 'Local', 'marker': 'test-marker'}
    return c


def submit(service, operation='scenario', **args):
    return service.submit({'session': 'test-marker', 'operation': operation,
                           'args': args or {'scenario': 'smoke.json'}})


async def test_binds_exact_marker_instead_of_first_window(service):
    result = await service.bind('test-marker')
    assert result['studio_id'] == 'chosen'


async def test_refuses_human_playtest_without_stopping_it(service):
    FakeStudio.playing = True
    job = submit(service)
    await service.task
    assert job['state'] == 'failed'
    assert 'already running' in job['error']
    assert FakeStudio.stopped == 0
    assert FakeStudio.playing


async def test_cleanup_after_scenario_failure(service, monkeypatch):
    class Harness:
        def __init__(self, *args): pass
        async def ensure_ready(self): pass
        async def players(self): return [{'name': 'one'}]
    async def fail(*args): raise RuntimeError('scenario broke')
    monkeypatch.setattr(mod, 'ProgressHarness', Harness)
    monkeypatch.setattr(mod, 'run_scenario', fail)
    job = submit(service)
    await service.task
    assert job['state'] == 'failed'
    assert FakeStudio.stopped == 1
    assert not FakeStudio.playing
    assert service.active is None


async def test_stop_before_job_started_clears_busy(service):
    job = submit(service)
    task = service.task
    await service.stop('test-marker')
    await asyncio.gather(task, return_exceptions=True)
    await asyncio.sleep(0)
    assert job['state'] == 'cancelled'
    assert service.active is None


async def test_cancel_in_flight_stops_owned_test(service, monkeypatch):
    started = asyncio.Event()
    class Harness:
        def __init__(self, *args): pass
        async def ensure_ready(self):
            started.set()
            await asyncio.Event().wait()
    monkeypatch.setattr(mod, 'ProgressHarness', Harness)
    job = submit(service)
    task = service.task
    await started.wait()
    await service.stop('test-marker')
    await task
    assert job['state'] == 'cancelled'
    assert FakeStudio.stopped == 1
    assert not FakeStudio.playing


async def test_skip_never_becomes_pass(service, monkeypatch):
    class Harness:
        def __init__(self, *args): pass
        async def ensure_ready(self): pass
        async def players(self): return [{'name': 'one'}]
    async def skipped(*args): return {'passed': None, 'skipped': True, 'reason': 'requires two players'}
    monkeypatch.setattr(mod, 'ProgressHarness', Harness)
    monkeypatch.setattr(mod, 'run_scenario', skipped)
    job = submit(service)
    await service.task
    assert job['state'] == 'skipped'
    assert FakeStudio.stopped == 1


async def test_cannot_cancel_other_window_job(service):
    job = submit(service)
    service.sessions['another-marker'] = {'studio_id': 'other'}
    with pytest.raises(ValueError, match='another Studio'):
        await service.stop('another-marker')
    await service.stop('test-marker')
    await asyncio.gather(service.task, return_exceptions=True)


async def test_rejects_paths_unpaired_ai_and_busy(service):
    with pytest.raises(ValueError, match='bundled'):
        submit(service, scenario='/tmp/smoke.json')
    with pytest.raises(ValueError, match='MUBIT_API_KEY'):
        submit(service, 'playtest', goal='walk')
    job = submit(service, 'install_harness')
    with pytest.raises(ValueError, match='already running'):
        submit(service)
    await service.task
    assert job['state'] == 'passed'


def test_restart_marks_jobs_interrupted(service):
    service.save({'id': 'stale', 'state': 'running'})
    restarted = mod.Companion(service.settings, FakeStudio, service.store)
    assert restarted.jobs['stale']['state'] == 'interrupted'


async def test_http_requires_token_and_limits_bodies(service):
    loop = asyncio.get_running_loop()
    server = ThreadingHTTPServer(('127.0.0.1', 0), mod.handler_for(service, loop, 'pairing'))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f'http://127.0.0.1:{server.server_port}'
    def call(path, token='', data=None):
        req = Request(url+path, data=data, headers={'Authorization': f'Bearer {token}'})
        with urlopen(req, timeout=3) as response: return json.load(response)
    try:
        with pytest.raises(HTTPError) as unauthorized:
            await asyncio.to_thread(call, '/health')
        assert unauthorized.value.code == 401
        health = await asyncio.to_thread(call, '/health', 'pairing')
        assert 'mubit_api_key' not in health
        assert health['session'] is None
        with pytest.raises(HTTPError) as oversized:
            await asyncio.to_thread(call, '/jobs', 'pairing', b'x'*16385)
        assert oversized.value.code == 413
    finally:
        await asyncio.to_thread(server.shutdown)
        server.server_close()


async def test_roblox_empty_table_arguments(service):
    job = service.submit({'session': 'test-marker', 'operation': 'install_harness', 'args': []})
    await service.task
    assert job['state'] == 'passed'


@pytest.mark.parametrize('verdict', [None, False, True])
async def test_ai_uses_existing_runner_and_requires_a_positive_verdict(service, monkeypatch, verdict):
    from mubit_tester import ai
    service.settings = replace(service.settings, mubit_api_key='test-only')
    class Harness:
        def __init__(self, *args): pass
        async def ensure_ready(self): pass
        async def players(self): return [{'name': 'one'}]
    async def playtest(settings, goal, **kwargs):
        assert goal == 'walk'
        assert kwargs['players'] == 1
        assert kwargs['steps'] == 20
        assert isinstance(kwargs['harness'], Harness)
        return {'run_id': 'test', 'goal_met': verdict, 'errors': [], 'bugs': []}
    monkeypatch.setattr(mod, 'ProgressHarness', Harness)
    monkeypatch.setattr(ai, 'multi_playtest', playtest)
    job = submit(service, 'playtest', goal='walk', steps=1000)
    await service.task
    assert job['state'] == ('passed' if verdict else 'failed')
    assert FakeStudio.stopped == 1


async def test_creation_requires_key_and_nonempty_idea(service):
    with pytest.raises(ValueError, match='MUBIT_API_KEY'):
        submit(service, 'make_game', idea='an obby')
    service.settings = replace(service.settings, mubit_api_key='test-only')
    with pytest.raises(ValueError, match='Describe your game'):
        submit(service, 'make_game', idea='   ')


def fake_rounds(monkeypatch, scores, started=None, release=None, lines=None):
    """run_game stand-in: each round appends a scored, headless iteration like forge's own records."""
    from forge.memory import RunStore
    from mubit_tester import studio_builder
    calls = []
    async def run_game(slug, iterations, use_studio, *, settings, llm=None, ui=None):
        assert iterations == 1 and use_studio is False
        calls.append(slug)
        if started:
            started.set()
        if release:
            await release.wait()
        ui.call('critic', '1 files', True, 1.0, 'rid')
        store = RunStore(settings, slug)
        state = store.load_state()
        state['iterations'].append({'n': len(state['iterations']) + 1, 'score': scores[len(calls) - 1], 'errors': [],
                                    'engine': 'headless', 'failed_steps': [], 'fixes': 2,
                                    **({'round_line': lines[len(calls) - 1]} if lines else {})})
        store.save_state(state)
        return slug
    monkeypatch.setattr(studio_builder, 'run_game', run_game)
    return calls


def fake_build(monkeypatch, first_score=5):
    from mubit_tester import studio_builder
    from test_studio_builder import saved_game
    async def build(settings, idea, emit, *, on_progress=None, **kwargs):
        store, _ = saved_game(settings)
        state = store.load_state()
        state['iterations'] = [{'n': 1, 'score': first_score, 'errors': [], 'engine': 'headless', 'failed_steps': [],
                                'fixes': 0}]
        store.save_state(state)
        emit('Writing your game code…')
        on_progress({'pct': 100, 'phase': 'done', 'step': 'Draft ready', 'items': None, 'eta_s': 0})
        return await studio_builder.describe_draft(settings, store.slug)
    monkeypatch.setattr(studio_builder, 'build_draft', build)


async def test_make_game_builds_installs_improves_and_says_ready(service, monkeypatch):
    service.settings = replace(service.settings, mubit_api_key='test-only')
    fake_build(monkeypatch)
    rounds = fake_rounds(monkeypatch, [5, 7, 9])
    seen = []
    set_progress = service.set_progress
    monkeypatch.setattr(service, 'set_progress', lambda job, p: (seen.append(p.get('pct')), set_progress(job, p)))
    job = submit(service, 'make_game', idea='an obby')
    await service.task
    assert job['state'] == 'passed', job.get('error')
    messages = [e['message'] for e in job['events']]
    flow = [m for m in messages if m.startswith(('Writing', 'Installed', 'Round', 'Ready', 'Not '))]
    assert flow == ['Writing your game code…', 'Installed in Studio: 1 script',
                    'Round 1: score 5/10, 0 errors, fixed 2 problems', 'Round 1 in Studio: 1 script changed',
                    'Round 2: score 7/10, 0 errors, fixed 2 problems', 'Round 2 in Studio: 1 script changed',
                    'Ready: score 7/10 after 2 rounds']
    assert len(rounds) == 2
    assert len(FakeStudio.synced) == 3 and all(p.name == 'game' for p in FakeStudio.synced)
    assert all(len(code) < 200_000 for code in FakeStudio.codes)
    assert not FakeStudio.playing and FakeStudio.stopped == 0
    result = job['result']
    assert result['in_studio'] and result['studio_current'] and result['ready']
    assert result['standard'] == {'ready': True, 'review': False, 'reason': 'score 7/10 with 0 errors', 'score': 7, 'errors': 0,
                                  'rounds': 2, 'acceptance': {'met': 0, 'total': 0}, 'qa': {'reached': 0, 'total': 0}}
    assert job['progress']['pct'] == 100
    assert seen[0] == 70 and seen == sorted(seen) and any(70 <= p <= 75 for p in seen[1:3])
    assert service.sessions['test-marker']['game_slug'] == result['slug']
    view = service.snapshot('test-marker')['history'][0]['presentation']
    assert view['status'] == 'Your game is in Studio and ready'
    assert '2 improvement rounds' in view['summary']


async def test_make_game_not_up_to_standard_still_finishes_in_studio(service, monkeypatch):
    service.settings = replace(service.settings, mubit_api_key='test-only')
    fake_build(monkeypatch)
    rounds = fake_rounds(monkeypatch, [4] + [5] * 11 + [9])
    job = submit(service, 'make_game', idea='an obby')
    await service.task
    assert job['state'] == 'passed'
    assert len(rounds) == 12  # the safety cap: the 9 a 13th round would score never happens
    assert job['result']['standard']['ready'] is False and job['result']['standard']['rounds'] == 12
    assert job['events'][-1]['message'] == 'Not ready after 12 rounds: score 5/10, needs 7'
    assert job['events'][-1]['ok'] is False
    view = service.snapshot('test-marker')['history'][0]['presentation']
    assert view['status'] == 'In Studio, not up to standard yet'


async def test_round_event_says_what_the_round_changed_and_taught(service, monkeypatch):
    service.settings = replace(service.settings, mubit_api_key='test-only')
    fake_build(monkeypatch)
    line = ('score 5 -> 6, acceptance 10/13 -> 11/13 (+ride_gate_used); fixed: StudioSelfTest; '
            'taught the fixer: StudioSelfTest left zone_cleared at 0 after 6 tries, told to try another way')
    fake_rounds(monkeypatch, [6], lines=[line])
    job = submit(service, 'make_game', idea='an obby')
    await service.task
    messages = [e['message'] for e in job['events']]
    tail = 'fixed: StudioSelfTest; taught the fixer: StudioSelfTest left zone_cleared at 0 after 6 tries'
    assert any(m.startswith(f'Round 1: score 6/10, 0 errors; {tail}') for m in messages), messages


async def test_cancel_mid_round_stops_the_job(service, monkeypatch):
    service.settings = replace(service.settings, mubit_api_key='test-only')
    fake_build(monkeypatch)
    started, release = asyncio.Event(), asyncio.Event()
    fake_rounds(monkeypatch, [9], started=started, release=release)
    job = submit(service, 'make_game', idea='an obby')
    task = service.task
    await started.wait()
    await service.stop('test-marker')
    await asyncio.gather(task, return_exceptions=True)
    assert job['state'] == 'cancelled' and service.active is None
    assert not any(e['message'].startswith('Ready') for e in job['events'])
    progress = json.loads((service.settings.runs_dir / 'agent-game' / 'progress.json').read_text())
    assert progress['running'] is False and progress['phase'] == 'failed'


async def test_incomplete_draft_is_not_ready_to_load(service, monkeypatch):
    from mubit_tester import studio_builder
    service.settings = replace(service.settings, mubit_api_key='test-only')
    async def build(*args, **kwargs):
        return {'slug': 'broken', 'ready': False, 'errors': ['Missing game script']}
    monkeypatch.setattr(studio_builder, 'build_draft', build)
    job = submit(service, 'make_game', idea='an obby')
    await service.task
    assert job['state'] == 'failed'
    with pytest.raises(ValueError, match='finished game draft'):
        submit(service, 'load_game', source_job=job['id'])


async def test_loading_draft_rejects_another_window(service):
    service.jobs['other'] = {'id': 'other', 'operation': 'make_game', 'state': 'passed',
                              'studio_id': 'other-window', 'result': {'ready': True}}
    with pytest.raises(ValueError, match='this Studio window'):
        submit(service, 'load_game', source_job='other')


async def test_loads_an_authorized_draft_without_starting_play(service, monkeypatch):
    from test_studio_builder import saved_game
    store, _ = saved_game(service.settings)
    service.jobs['draft'] = {'id': 'draft', 'operation': 'make_game', 'state': 'passed',
        'studio_id': 'chosen', 'result': {'ready': True, 'slug': store.slug, 'title': 'Obby'}}
    job = submit(service, 'load_game', source_job='draft')
    await service.task
    assert job['state'] == 'passed', job.get('error')
    assert job['result']['runtime_checked'] is False
    assert FakeStudio.synced == [store.game_dir.resolve()]  # the chunked sync, not one inline command
    assert any('-- MuMakePreflight' in c for c in FakeStudio.codes) and any('-- MuMakeMark' in c for c in FakeStudio.codes)
    assert 'Installed in Studio: 1 scripts' in [e['message'] for e in job['events']]
    assert not FakeStudio.playing and FakeStudio.stopped == 0


async def test_saved_agent_game_reopens_without_ai_or_studio_writes(service):
    from test_studio_builder import saved_game
    store, _ = saved_game(service.settings)
    job = submit(service, 'open_game', slug=store.slug)
    await service.task
    assert job['state'] == 'passed' and job['result']['slug'] == store.slug
    assert not FakeStudio.playing and FakeStudio.stopped == 0
    assert service.snapshot('test-marker')['games'][0]['slug'] == store.slug


async def test_native_iteration_reuses_builder_without_touching_studio(service, monkeypatch):
    from mubit_tester import studio_builder
    service.settings = replace(service.settings, mubit_api_key='test-only')
    service.jobs['draft'] = {'id': 'draft', 'operation': 'open_game', 'state': 'passed',
        'studio_id': 'chosen', 'result': {'slug': 'agent-game'}}
    async def revise(settings, slug, emit, **kwargs):
        assert slug == 'agent-game' and kwargs == {}
        return {'slug': 'revision', 'ready': True, 'errors': []}
    monkeypatch.setattr(studio_builder, 'revise_draft', revise)
    job = submit(service, 'iterate_game', source_job='draft')
    await service.task
    assert job['state'] == 'passed' and job['result']['slug'] == 'revision'
    assert not FakeStudio.playing and FakeStudio.stopped == 0


async def test_correct_draft_validates_note_and_source_session(service):
    service.settings = replace(service.settings, mubit_api_key='test-only')
    service.jobs['draft'] = {'id': 'draft', 'operation': 'make_game', 'state': 'passed',
        'studio_id': 'other', 'result': {'slug': 'obby'}}
    with pytest.raises(ValueError, match='this Studio window'):
        submit(service, 'correct_game', source_job='draft', path='Game.luau', note='change')
    service.jobs['draft']['studio_id'] = 'chosen'
    with pytest.raises(ValueError, match='describe the change'):
        submit(service, 'correct_game', source_job='draft', path='Game.luau', note=' ')


def test_fix_uses_the_report_game_even_after_switching_drafts(service):
    from test_studio_builder import saved_game
    store, _ = saved_game(service.settings)
    service.sessions['test-marker']['game_slug'] = 'some-other-game'
    service.jobs['play'] = {'studio_id': 'chosen', 'result': {'run_id': 'play-1', 'game_slug': store.slug}}
    assert service.report_settings('play-1', 'chosen').base_game_dir == store.game_dir
    assert service.report_settings('play-1', 'other').base_game_dir == service.settings.base_game_dir


async def test_make_game_progress_reaches_the_plugin_state(service, monkeypatch):
    from mubit_tester import studio_builder
    service.settings = replace(service.settings, mubit_api_key='test-only')
    async def build(settings, idea, emit, *, on_progress=None, **kwargs):
        emit('Game plan ready: Funfair Frenzy, 10 zones x 10 stages')
        emit('Zone 3 failed to compile', False)
        on_progress({'pct': 60, 'phase': 'levels', 'step': 'Designing zones 3, 4, 5 of 10',
                     'items': {'label': 'zones', 'done': 2, 'total': 10}, 'eta_s': 180})
        state = service.snapshot('test-marker')
        assert state['active']['progress']['pct'] == 60  # progress.json already holds the job's % (one number everywhere)
        assert state['active']['progress']['eta_s'] is None
        assert state['active']['progress']['items'] == {'label': 'zones', 'done': 2, 'total': 10}
        assert [e.get('ok') for e in state['active']['events'][-2:]] == [None, False]
        assert 'ok' not in state['active']['events'][-2]
        return {'slug': 'obby', 'title': 'Obby', 'ready': True, 'errors': [], 'files': ['Game.server.luau']}
    async def finish(settings, draft, emit, **kwargs):
        return draft
    monkeypatch.setattr(studio_builder, 'build_draft', build)
    monkeypatch.setattr(studio_builder, 'finish_draft', finish)
    job = submit(service, 'make_game', idea='an obby')
    await service.task
    assert job['state'] == 'passed'
    saved = json.loads((service.store / f"job-{job['id']}.json").read_text())
    assert saved['progress']['step'] == 'Designing zones 3, 4, 5 of 10'
    view = service.snapshot('test-marker')['history'][0]
    assert view['progress']['pct'] == 60 and view['presentation']['status'] == 'Your first draft is ready'
    service.set_progress(job, {'pct': 99})
    assert job['progress']['pct'] == 60
