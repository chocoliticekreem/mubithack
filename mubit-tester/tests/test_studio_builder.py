"""Exercise the real creation pipeline with a fake model, without paid calls or Studio writes."""
import json
from dataclasses import replace
from pathlib import Path

from forge.config import load_settings
from forge.llm import FakeLLM
from mubit_tester.studio_builder import build_draft, draft_install_code
import pytest


async def test_real_builder_produces_a_separate_compiled_draft(tmp_path):
    settings = replace(load_settings(), runs_dir=tmp_path/'runs')
    spec = {'title': 'Coin game', 'slug': 'coin-game', 'pitch': 'Find coins', 'core_loop': 'Walk and collect coins', 'modules': [
        {'path': 'ServerScriptService/Game.server.luau', 'purpose': 'make a coin', 'depends': []}],
        'acceptance': ['A coin appears']}
    llm = FakeLLM(responses={
        'designer': [json.dumps(spec)],
        'coder': ['```luau\nlocal coin=Instance.new("Part")\ncoin.Name="Coin"\ncoin.Parent=workspace\n```'],
        'critic': [json.dumps({'score': 8, 'done': True, 'issues': [], 'summary': 'Code draft ready'})],
        'reflector': ['Keep the first game small.'],
    })
    events = []
    result = await build_draft(settings, 'make a coin game', lambda m, ok=None: events.append(m), llm=llm)
    assert result['ready'] and not result['errors']
    assert result['runtime_checked'] is False
    game = settings.runs_dir/result['slug']/'game'
    assert (game/'ServerScriptService/Game.server.luau').is_file()
    assert result['acceptance'] == ['A coin appears']
    assert events
    # Compilable installation code is emitted from that saved draft only.
    code = draft_install_code(settings, result['slug'])
    (tmp_path/'install.luau').write_text(code)
    import subprocess
    subprocess.run(['luau-compile', str(tmp_path/'install.luau')], stdout=subprocess.DEVNULL, check=True)


def saved_game(settings, slug='agent-game'):
    from forge.memory import RunStore
    store = RunStore(settings, slug)
    store.ensure()
    store.save_spec({'title': 'Agent game', 'pitch': 'Collect coins', 'modules': [
        {'path': 'ServerScriptService/Coins.server.luau', 'purpose': 'coins', 'depends': []}], 'acceptance': ['A coin appears']})
    store.save_state(store.new_state('coins'))
    path = store.game_dir/'ServerScriptService/Coins.server.luau'
    path.parent.mkdir(parents=True)
    path.write_text('local coins = 1\n')
    return store, path


async def test_revision_uses_real_fixer_and_leaves_original_unchanged(tmp_path):
    from mubit_tester.studio_builder import revise_draft, saved_games
    settings = replace(load_settings(), runs_dir=tmp_path/'runs')
    store, path = saved_game(settings)
    original = path.read_text()
    llm = FakeLLM(responses={'fixer': ['```luau\nlocal coins = 3\n```']})
    result = await revise_draft(settings, store.slug, lambda _: None,
                                path='ServerScriptService/Coins.server.luau', note='Make three coins', llm=llm)
    assert result['ready'] and result['runtime_checked'] is False
    assert result['slug'] != store.slug and result['source_slug'] == store.slug
    assert result['project_slug'] == store.slug
    assert path.read_text() == original
    revised = settings.runs_dir/result['slug']
    assert 'coins = 3' in (revised/'game/ServerScriptService/Coins.server.luau').read_text()
    state = json.loads((revised/'state.json').read_text())
    assert state['corrections'][-1]['note'] == 'Make three coins'
    assert {g['slug'] for g in saved_games(settings)} == {store.slug, result['slug']}


async def test_revision_rejects_protected_or_escaping_paths(tmp_path):
    from mubit_tester.studio_builder import revise_draft, draft_store
    settings = replace(load_settings(), runs_dir=tmp_path/'runs')
    store, _ = saved_game(settings)
    with pytest.raises(ValueError, match='Choose a generated'):
        await revise_draft(settings, store.slug, print, path='../secret.luau', note='change')
    spec = store.load_spec()
    spec['base_files'] = ['ServerScriptService/Coins.server.luau']
    store.save_spec(spec)
    with pytest.raises(ValueError, match='Choose a generated'):
        await revise_draft(settings, store.slug, print, path=spec['base_files'][0], note='change')
    (store.game_dir/'linked.luau').symlink_to(tmp_path/'outside')
    with pytest.raises(ValueError, match='linked files'):
        draft_store(settings, store.slug)
    with pytest.raises(ValueError, match='Choose a saved'):
        draft_store(settings, '../outside')


@pytest.mark.parametrize('kind', ['harness', 'draft'])
def test_install_preflight_keeps_human_scripts_before_any_writes(tmp_path, kind):
    from mubit_tester.studio_service import install_code
    import subprocess
    settings = replace(load_settings(), runs_dir=tmp_path/'runs')
    store, _ = saved_game(settings)
    code = install_code(settings.repo_root) if kind == 'harness' else draft_install_code(settings, store.slug)
    # Execute the actual installer against a minimal Studio API stub: the second
    # destination conflicts, so even the first destination must remain untouched.
    prelude = '''
local writes,recordings=0,0
local files={
 {service="ServerScriptService",name="First",class="Script",source="new",dirs={},path="First.server.luau"},
 {service="ServerScriptService",name="Human",class="Script",source="new",dirs={},path="Human.server.luau"},
}
local human={ClassName="Script",GetAttribute=function() return nil end}
local folder={FindFirstChild=function(_,name) return name=="Human" and human or nil end}
local editor={GetEditorSource=function() return "human code" end,UpdateSourceAsync=function() writes+=1 end}
local history={IsRecordingInProgress=function() return false end,TryBeginRecording=function() recordings+=1 return "record" end}
game={GetService=function(_,name)
 if name=="HttpService" then return {JSONDecode=function() return files end} end
 if name=="ScriptEditorService" then return editor end
 if name=="ChangeHistoryService" then return history end
 return folder
end}
'''
    script = prelude+'\nlocal ok,err=pcall(function()\n'+code+'\nend)\nassert(not ok and tostring(err):find("Keep your existing script"),tostring(err))\nassert(writes==0 and recordings==0,"Conflict changed Studio")\n'
    path = tmp_path/'preflight.luau'
    path.write_text(script)
    subprocess.run(['luau', str(path)], capture_output=True, text=True, check=True)


def write_progress(settings, slug, pct, phase, step, events, items=None):
    from forge.memory import RunStore
    path = RunStore(settings, slug).dir / 'progress.json'
    path.write_text(json.dumps({'slug': slug, 'command': 'new', 'running': phase not in {'done', 'failed'},
                                'pct': pct, 'phase': phase, 'step': step, 'items': items, 'started': 1.0,
                                'updated': 2.0, 'eta_s': None if phase == 'done' else 120,
                                'events': [{'t': float(i), 'text': text, 'ok': ok} for i, (text, ok) in enumerate(events)]}))


def fake_forge(monkeypatch, steps, *, header=True, fail=None):
    """A stand-in for forge.new_game that writes progress.json in steps, like the real writer."""
    import asyncio
    from forge.memory import RunStore
    from mubit_tester import studio_builder
    monkeypatch.setattr(studio_builder, 'POLL_S', 0.01)
    async def describe(settings, slug):
        return {'slug': slug}
    monkeypatch.setattr(studio_builder, 'describe_draft', describe)
    async def new_game(idea, iterations, use_studio, *, settings, llm, ui):
        store = RunStore(settings, 'funfair')
        store.ensure()
        store.save_state(store.new_state(idea))
        if header:
            ui.header('forge new  funfair')
        for step in steps:
            write_progress(settings, 'funfair', *step)
            await asyncio.sleep(0.05)
        if fail:
            raise fail
        return 'funfair'
    monkeypatch.setattr(studio_builder, 'new_game', new_game)


PLAN = ('Game plan ready: Funfair Frenzy, 10 zones x 10 stages', True)
PLANNING = ('Planning your game…', None)
STEPS = [(5, 'design', 'Designing the game', [PLANNING, ('Started', None)]),
         (40, 'levels', 'Designing zones 3, 4, 5 of 10', [PLANNING, ('Started', None), PLAN],
          {'label': 'zones', 'done': 2, 'total': 10}),
         (100, 'done', 'Finished', [PLANNING, ('Started', None), PLAN, ('Build finished: 100 stages, 0 compile errors', True)])]


async def test_build_relays_progress_events_once_and_stops_polling(tmp_path, monkeypatch):
    import asyncio
    settings = replace(load_settings(), runs_dir=tmp_path/'runs')
    fake_forge(monkeypatch, STEPS)
    events, progress = [], []
    result = await build_draft(settings, 'funfair', lambda m, ok=None: events.append((m, ok)), on_progress=progress.append)
    assert result == {'slug': 'funfair'}
    assert events == [('Planning your game…', None), ('Started', None), PLAN,
                      ('Build finished: 100 stages, 0 compile errors', True)]
    assert progress[-1] == {'pct': 100, 'phase': 'done', 'step': 'Finished', 'items': None, 'eta_s': None}
    assert {'pct': 40, 'phase': 'levels', 'step': 'Designing zones 3, 4, 5 of 10',
            'items': {'label': 'zones', 'done': 2, 'total': 10}, 'eta_s': 120} in progress
    assert len(progress) == len({json.dumps(p, sort_keys=True) for p in progress})
    count = len(events)
    write_progress(settings, 'funfair', 100, 'done', 'Finished', [('Written after the build returned', True)])
    await asyncio.sleep(0.05)
    assert len(events) == count


async def test_build_tolerates_missing_and_broken_progress_file(tmp_path, monkeypatch):
    from forge.memory import RunStore
    from mubit_tester.studio_builder import ProgressFeed, BuildProgress
    settings = replace(load_settings(), runs_dir=tmp_path/'runs')
    fake_forge(monkeypatch, [])
    events, progress = [], []
    await build_draft(settings, 'funfair', lambda m, ok=None: events.append(m), on_progress=progress.append)
    assert events == ['Planning your game…'] and progress == []
    (RunStore(settings, 'funfair').dir / 'progress.json').write_text('{"pct": 4')
    ui = BuildProgress(events.append)
    ui.slug = 'funfair'
    ProgressFeed(settings, ui, 'funfair', events.append, progress.append).poll()
    assert progress == [] and events == ['Planning your game…']


async def test_failed_build_reports_the_last_progress_event_without_a_header(tmp_path, monkeypatch):
    settings = replace(load_settings(), runs_dir=tmp_path/'runs')
    fake_forge(monkeypatch, [(30, 'failed', 'Build failed', [('Started', None), ('Build failed: TimeoutError', False)])],
               header=False, fail=TimeoutError('slow'))
    events = []
    with pytest.raises(TimeoutError):
        await build_draft(settings, 'funfair', lambda m, ok=None: events.append((m, ok)))
    assert events == [('Started', None), ('Build failed: TimeoutError', False)]


def test_build_messages_name_the_role_and_file():
    from mubit_tester.studio_builder import BuildProgress
    events = []
    ui = BuildProgress(lambda m, ok=None: events.append((m, ok)))
    ui.header('forge new  funfair-2')
    ui.header('build  4 modules  (jobs 4)')
    ui.call('coder', 'ServerScriptService/FunfairGifts.luau (cached)', True, 1.0, 'r1')
    ui.call('level_designer', '10 zones x 10 stages', True, 1.0, 'r2')
    ui.call('director', 'design doc + spec.json', True, 1.0, 'r3')
    ui.call('coder', 'ServerScriptService/Rides.luau', False, 1.0, None, err='TimeoutError: slow')
    ui.line('check', 'luau-compile 1/4 failing', False)
    assert ui.slug == 'funfair-2'
    assert events == [('Planning your game…', None), ('Writing 4 game scripts…', None),
                      ('Wrote ServerScriptService/FunfairGifts.luau', None),
                      ('Laid out the course: 10 zones x 10 stages', None), ('Game design ready', None),
                      ('Could not finish writing (ServerScriptService/Rides.luau): TimeoutError', False),
                      ('Some game scripts do not compile yet', False)]


async def test_a_course_missing_a_zone_is_not_ready(tmp_path):
    from mubit_tester.studio_builder import describe_draft
    settings = replace(load_settings(), runs_dir=tmp_path/'runs')
    store, _ = saved_game(settings)
    spec = store.load_spec()
    spec['levels'] = {'zones': 3, 'stages_per_zone': 10, 'plan': [
        {'zone': 1, 'name': 'Gate', 'written': 'x'}, {'zone': 3, 'name': 'Finale', 'written': 'x'}]}
    store.save_spec(spec)
    result = await describe_draft(settings, 'agent-game')
    assert not result['ready'] and 'Course has 20/30 stages (zone 2 failed)' in result['errors']
    spec['levels']['plan'].insert(1, {'zone': 2, 'name': 'Middle', 'written': 'x'})
    store.save_spec(spec)
    assert (await describe_draft(settings, 'agent-game'))['ready']
