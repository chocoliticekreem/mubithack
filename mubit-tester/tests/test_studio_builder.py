"""Exercise the real creation pipeline with a fake model, without paid calls or Studio writes."""
import json
from dataclasses import replace
from pathlib import Path

from forge.config import load_settings
from forge.llm import FakeLLM
from mubit_tester.studio_builder import build_draft, draft_install_code


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
