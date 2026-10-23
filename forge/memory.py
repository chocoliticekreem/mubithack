"""Per-game run state on disk, plus the shared lessons file.

Layout (see docs/ARCHITECTURE.md):
    runs/<slug>/spec.json  state.json  calls.jsonl  game/  iterations/<n>/...
    runs/lessons.md        shared lessons, injected into every coder/fixer user message
"""

from __future__ import annotations

import json
import re
import unicodedata
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from forge.config import Settings

STARTER_LESSONS = """\
# Forge lessons

Short, concrete rules learned from earlier builds. Follow them unless the spec says otherwise.

- The base place is empty: build the map from code (Instance.new Parts, Anchored = true, parented to Workspace).
- Get services with game:GetService("Players") etc.; use task.wait / task.spawn / task.delay, never wait / spawn / delay.
- Players.PlayerAdded can fire before your script connects in a playtest: also loop over Players:GetPlayers() once at startup.
- Wait for characters with player.CharacterAdded (and player.Character if already present); use WaitForChild with a timeout across the client/server boundary.
- ModuleScripts must return exactly one value (usually a table); require them by path, e.g. require(ReplicatedStorage:WaitForChild("Config")).
- Create RemoteEvents on the server in one place; clients only WaitForChild them.
- Bump counters for key gameplay events with require(ReplicatedStorage.ForgeTelemetry).count("name", 1) (server only) so playtests can verify the core loop.
"""


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def slugify(text: str, max_words: int = 6, max_len: int = 48) -> str:
    """'A coin-collecting obby with lava!' -> 'a-coin-collecting-obby-with-lava'."""
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    words = re.findall(r"[a-z0-9]+", text.lower())
    slug = "-".join(words[:max_words])[:max_len].strip("-")
    return slug or "game"


def unique_slug(settings: Settings, base: str) -> str:
    slug = slugify(base) if not re.fullmatch(r"[a-z0-9-]+", base or "") else base
    slug = slug or "game"
    candidate, i = slug, 2
    while (settings.runs_dir / candidate).exists():
        candidate = f"{slug}-{i}"
        i += 1
    return candidate


def _read_json(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def _write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False, default=str) + "\n")
    tmp.replace(path)


# ---------------------------------------------------------------- lessons

def lessons_path(settings: Settings) -> Path:
    return settings.runs_dir / "lessons.md"


def read_lessons(settings: Settings) -> str:
    path = lessons_path(settings)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(STARTER_LESSONS)
    return path.read_text()


def write_lessons(settings: Settings, text: str) -> None:
    path = lessons_path(settings)
    path.parent.mkdir(parents=True, exist_ok=True)
    text = text.strip()
    if not text:
        return
    if path.exists():  # keep one backup so a bad reflection can be undone by hand
        (path.parent / "lessons.prev.md").write_text(path.read_text())
    path.write_text(text + "\n")


# ---------------------------------------------------------------- per-game store

class RunStore:
    def __init__(self, settings: Settings, slug: str):
        self.settings = settings
        self.slug = slug
        self.dir = settings.runs_dir / slug
        self.game_dir = self.dir / "game"
        self.spec_path = self.dir / "spec.json"
        self.state_path = self.dir / "state.json"
        self.calls_log = self.dir / "calls.jsonl"
        self.iterations_dir = self.dir / "iterations"
        self.corrections_dir = self.dir / "corrections"

    # -- basics
    def exists(self) -> bool:
        return self.state_path.exists() or self.spec_path.exists()

    def ensure(self) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        self.iterations_dir.mkdir(parents=True, exist_ok=True)

    def iteration_dir(self, n: int) -> Path:
        path = self.iterations_dir / str(n)
        path.mkdir(parents=True, exist_ok=True)
        return path

    # -- spec
    def load_spec(self) -> dict:
        spec = _read_json(self.spec_path)
        if spec is None:
            raise FileNotFoundError(f"no spec for {self.slug!r} at {self.spec_path}")
        return spec

    def save_spec(self, spec: dict) -> None:
        _write_json(self.spec_path, spec)

    # -- state
    def new_state(self, idea: str) -> dict:
        ts = now_iso()
        return {"slug": self.slug, "idea": idea, "iterations": [], "corrections": [],
                "created": ts, "updated": ts}

    def load_state(self) -> dict:
        state = _read_json(self.state_path)
        if state is None:
            state = self.new_state("")
        state.setdefault("iterations", [])
        state.setdefault("corrections", [])
        return state

    def save_state(self, state: dict) -> None:
        state["updated"] = now_iso()
        _write_json(self.state_path, state)

    def next_iteration(self, state: dict | None = None) -> int:
        state = state or self.load_state()
        ns = [it.get("n", 0) for it in state.get("iterations", [])]
        return (max(ns) if ns else 0) + 1

    def last_iteration(self, state: dict | None = None) -> int | None:
        state = state or self.load_state()
        ns = [it.get("n", 0) for it in state.get("iterations", [])]
        return max(ns) if ns else None

    # -- iteration artifacts
    def save_iteration_json(self, n: int, name: str, data: Any) -> Path:
        path = self.iteration_dir(n) / name
        _write_json(path, data)
        return path

    def load_iteration_json(self, n: int, name: str, default: Any = None) -> Any:
        return _read_json(self.iterations_dir / str(n) / name, default)

    def save_correction(self, data: dict) -> Path:
        self.corrections_dir.mkdir(parents=True, exist_ok=True)
        k = len(list(self.corrections_dir.glob("*.json"))) + 1
        path = self.corrections_dir / f"{k}.json"
        _write_json(path, data)
        return path

    # -- calls log (written by MubitLLM)
    def read_calls(self) -> list[dict]:
        if not self.calls_log.exists():
            return []
        out = []
        for line in self.calls_log.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        return out

    # -- listing
    @staticmethod
    def list_games(settings: Settings) -> list[str]:
        if not settings.runs_dir.exists():
            return []
        return sorted(
            p.name for p in settings.runs_dir.iterdir()
            if p.is_dir() and ((p / "state.json").exists() or (p / "spec.json").exists())
        )
