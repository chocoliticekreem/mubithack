"""Test this checkout's mubit_tester, not whatever copy the venv's editable install points at
(worktrees share one venv with the main checkout)."""

import sys
from pathlib import Path

_PKG_ROOT = str(Path(__file__).resolve().parent.parent)
if sys.path[:1] != [_PKG_ROOT]:
    sys.path.insert(0, _PKG_ROOT)
for _name in [m for m in sys.modules if m == "mubit_tester" or m.startswith("mubit_tester.")]:
    if not str(getattr(sys.modules[_name], "__file__", "") or "").startswith(_PKG_ROOT):
        del sys.modules[_name]
