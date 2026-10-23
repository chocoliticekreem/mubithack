"""Settings: empty env vars (unset plugin user config) fall back to .env and the defaults."""

from __future__ import annotations

import forge.config as config


def test_empty_env_vars_fall_back_to_dotenv(tmp_path, monkeypatch):
    (tmp_path / ".env").write_text("MUBIT_API_KEY=mbt_from_dotenv\nFORGE_MODEL=claude-haiku-4-5\n")
    monkeypatch.setattr(config, "REPO_ROOT", tmp_path)
    monkeypatch.setenv("MUBIT_API_KEY", "")
    monkeypatch.setenv("FORGE_MODEL", "")
    s = config.load_settings()
    assert s.mubit_api_key == "mbt_from_dotenv"
    assert s.model == "claude-haiku-4-5"


def test_default_model_is_one_the_starter_credit_serves(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "REPO_ROOT", tmp_path)
    monkeypatch.delenv("FORGE_MODEL", raising=False)
    assert config.load_settings().model == "claude-sonnet-5-5"


def test_real_env_vars_still_win(tmp_path, monkeypatch):
    (tmp_path / ".env").write_text("FORGE_MODEL=claude-haiku-4-5\n")
    monkeypatch.setattr(config, "REPO_ROOT", tmp_path)
    monkeypatch.setenv("FORGE_MODEL", "claude-opus-5-5")
    assert config.load_settings().model == "claude-opus-5-5"
