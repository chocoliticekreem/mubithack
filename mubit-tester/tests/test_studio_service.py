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
    def __init__(self, *args, studio_id=None, **kwargs):
        self.studio_id = studio_id
    async def __aenter__(self): return self
    async def __aexit__(self, *args): pass
    async def list_studios(self):
        return [{'id': key, 'name': key} for key in self.identities]
    async def execute_luau(self, code):
        if code == mod.MARKER_CODE:
            return json.dumps({'marker': self.identities[self.studio_id], 'name': 'Local', 'placeId': 0})
        return 'installed'
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


async def test_create_draft_does_not_start_or_change_studio(service, monkeypatch):
    from mubit_tester import studio_builder
    service.settings = replace(service.settings, mubit_api_key='test-only')
    async def build(settings, idea, emit):
        assert idea == 'an obby'
        emit('Writing your game code…')
        return {'slug': 'obby', 'title': 'Obby', 'ready': True, 'errors': [], 'files': ['Game.server.luau']}
    monkeypatch.setattr(studio_builder, 'build_draft', build)
    job = submit(service, 'make_game', idea='an obby')
    await service.task
    assert job['state'] == 'passed'
    assert job['result']['ready']
    assert not FakeStudio.playing and FakeStudio.stopped == 0
    view = service.snapshot('test-marker')['history'][0]['presentation']
    assert view['status'] == 'Your first draft is ready'
    assert 'not been played' in view['summary']


async def test_incomplete_draft_is_not_ready_to_load(service, monkeypatch):
    from mubit_tester import studio_builder
    service.settings = replace(service.settings, mubit_api_key='test-only')
    async def build(*args):
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
    from forge import sync
    from mubit_tester import studio_builder
    service.jobs['draft'] = {'id': 'draft', 'operation': 'make_game', 'state': 'passed',
        'studio_id': 'chosen', 'result': {'ready': True, 'slug': 'obby', 'title': 'Obby'}}
    monkeypatch.setattr(sync, 'check', lambda root: [])
    def code(settings, slug):
        assert slug == 'obby'
        return 'return "add draft"'
    monkeypatch.setattr(studio_builder, 'draft_install_code', code)
    job = submit(service, 'load_game', source_job='draft')
    await service.task
    assert job['state'] == 'passed'
    assert job['result']['runtime_checked'] is False
    assert not FakeStudio.playing and FakeStudio.stopped == 0
