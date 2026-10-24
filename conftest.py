"""Repo-wide test defaults. Real runs use the game director and the fun critic (forge/director.py,
forge/fun.py); scripted FakeLLM tests written before them don't script those roles, so they're off
here unless a test turns them on (monkeypatch.setenv or new_game(use_director=True))."""

import os

os.environ.setdefault("FORGE_DIRECTOR", "0")
os.environ.setdefault("FORGE_FUN_CRITIC", "0")
