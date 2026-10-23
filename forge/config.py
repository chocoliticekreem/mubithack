"""Settings for forge, read from the environment (and .env at the repo root)."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

# FORGE_PROJECT_DIR lets an installed copy (e.g. the mubit-tester plugin via uvx) work on a checkout.
REPO_ROOT = Path(os.environ.get("FORGE_PROJECT_DIR") or Path(__file__).resolve().parent.parent).resolve()

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


# The starter credit only serves claude-opus-5-5, claude-sonnet-5-5 and claude-haiku-4-5.
DEFAULT_MODEL = "claude-sonnet-5-5"


def load_settings() -> Settings:
    # The mubit-tester plugin passes unset user config as empty strings; let .env fill those in.
    for key in [k for k, v in os.environ.items() if v == "" and k.startswith(("MUBIT_", "FORGE_"))]:
        del os.environ[key]
    load_dotenv(REPO_ROOT / ".env")
    provider = os.environ.get("FORGE_PROVIDER", "anthropic").lower()
    if provider not in DEFAULT_BASE_URLS:
        raise ValueError(f"FORGE_PROVIDER must be anthropic or openai, got {provider!r}")
    return Settings(
        mubit_api_key=os.environ.get("MUBIT_API_KEY") or None,
        provider=provider,
        base_url=os.environ.get("MUBIT_BASE_URL") or DEFAULT_BASE_URLS[provider],
        model=os.environ.get("FORGE_MODEL", DEFAULT_MODEL),
        studio_mcp_path=os.environ.get(
            "STUDIO_MCP_PATH", "/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP"
        ),
        sync_port=int(os.environ.get("FORGE_SYNC_PORT", "34873")),
        repo_root=REPO_ROOT,
        runs_dir=REPO_ROOT / "runs",
        base_game_dir=REPO_ROOT / "game",
    )
