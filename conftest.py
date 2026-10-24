"""Repo-wide test defaults. Real runs use the game director, the fun critic, the smoke play and the journey gates
(forge/director.py, forge/fun.py, forge/smoke.py, forge/journey.py); scripted FakeLLM tests and fake Studios
written before them don't script those, so they're off here unless a test turns them on (monkeypatch.setenv or
new_game(use_director=True))."""

import os

os.environ.setdefault("FORGE_DIRECTOR", "0")
os.environ.setdefault("FORGE_FUN_CRITIC", "0")
os.environ.setdefault("FORGE_SMOKE_SECONDS", "0")
os.environ.setdefault("FORGE_JOURNEY", "0")
