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
