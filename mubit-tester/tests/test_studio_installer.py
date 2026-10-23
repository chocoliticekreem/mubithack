"""Do not replace the installed UI while an incompatible companion is running."""
from pathlib import Path
import runpy
import sys

import pytest


def test_old_helper_leaves_installed_plugin_untouched(tmp_path, monkeypatch):
    root = Path(__file__).resolve().parents[2]
    install = runpy.run_path(str(root/'scripts/install-studio-plugin.py'))
    scope = install['main'].__globals__
    monkeypatch.setitem(scope, 'ROOT', tmp_path)
    monkeypatch.setitem(scope, 'health', lambda *_: {'protocol': 1})
    plugins = tmp_path/'Plugins'
    plugins.mkdir()
    target = plugins/'MuMake.lua'
    target.write_text('existing plugin')
    monkeypatch.setattr(sys, 'argv', ['install-studio-plugin.py', '--plugins-dir', str(plugins)])
    with pytest.raises(SystemExit, match='older version'):
        install['main']()
    assert target.read_text() == 'existing plugin'


def test_active_draft_job_is_not_cancelled_by_live_reload(tmp_path, monkeypatch):
    root = Path(__file__).resolve().parents[2]
    install = runpy.run_path(str(root/'scripts/install-studio-plugin.py'))
    scope = install['main'].__globals__
    monkeypatch.setitem(scope, 'ROOT', tmp_path)
    monkeypatch.setitem(scope, 'health', lambda *_: {'protocol': 2, 'busy': True})
    monkeypatch.setitem(scope, 'load_token', lambda *_: 'test-token')
    monkeypatch.setitem(scope, 'plugin_source', lambda *_: 'updated on disk')
    async def unexpected_reload(*_):
        pytest.fail('An active job must not reload its panel')
    monkeypatch.setitem(scope, 'load_existing', unexpected_reload)
    plugins = tmp_path/'Plugins'
    monkeypatch.setattr(sys, 'argv', ['install-studio-plugin.py', '--plugins-dir', str(plugins), '--load-existing'])
    with pytest.raises(SystemExit, match='active MuMake job'):
        install['main']()
    assert (plugins/'MuMake.lua').read_text() == 'updated on disk'
