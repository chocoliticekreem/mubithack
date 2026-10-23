"""Settings for forge, read from the environment (and .env at the repo root)."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

REPO_ROOT = Path(__file__).resolve().parent.parent

DEFAULT_BASE_URLS = {
    "anthropic": "https://api.mubit.ai/anthropic",
    "openai": "https://api.mubit.ai/openai/v1",
}


@dataclass(frozen=True)
class Settings:
    mubit_api_key: str | None
    provider: str
    base_url: str
    model: str
    studio_mcp_path: str
    sync_port: int
    repo_root: Path
    runs_dir: Path
    base_game_dir: Path


def load_settings() -> Settings:
    load_dotenv(REPO_ROOT / ".env")
    provider = os.environ.get("FORGE_PROVIDER", "anthropic").lower()
    if provider not in DEFAULT_BASE_URLS:
        raise ValueError(f"FORGE_PROVIDER must be anthropic or openai, got {provider!r}")
    return Settings(
        mubit_api_key=os.environ.get("MUBIT_API_KEY") or None,
        provider=provider,
        base_url=os.environ.get("MUBIT_BASE_URL") or DEFAULT_BASE_URLS[provider],
        model=os.environ.get("FORGE_MODEL", "claude-sonnet-5"),
        studio_mcp_path=os.environ.get(
            "STUDIO_MCP_PATH", "/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP"
        ),
        sync_port=int(os.environ.get("FORGE_SYNC_PORT", "34873")),
        repo_root=REPO_ROOT,
        runs_dir=REPO_ROOT / "runs",
        base_game_dir=REPO_ROOT / "game",
    )
