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
    result = await build_draft(settings, 'make a coin game', events.append, llm=llm)
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
