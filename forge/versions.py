"""Version control for a Forge game: runs/<slug>/game is its own git repo, one tag per version.

Every build, iteration and kept fix is a commit tagged v1, v2, ... with the reason in the message
(score, anomaly, verifier verdict, Mubit request id). A rollback restores an old version's files as
a new commit, so nothing is ever lost and a rollback can itself be rolled back.

runs/ is gitignored in the main repo, so these nested repos never reach GitHub.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

_ENV = {"GIT_AUTHOR_NAME": "forge", "GIT_AUTHOR_EMAIL": "forge@localhost",
        "GIT_COMMITTER_NAME": "forge", "GIT_COMMITTER_EMAIL": "forge@localhost"}
_IGNORE = "tools/manifest.json\n__pycache__/\n*.pyc\n.DS_Store\n"


class VersionError(RuntimeError):
    pass


class GameVersions:
    def __init__(self, game_dir: Path):
        self.dir = Path(game_dir)

    def _git(self, *args: str, check: bool = True) -> str:
        res = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", *args],
                             cwd=self.dir, capture_output=True, text=True, env={**os.environ, **_ENV})
        if check and res.returncode != 0:
            raise VersionError(f"git {' '.join(args)}: {res.stderr.strip() or res.stdout.strip()}")
        return res.stdout.strip()

    def exists(self) -> bool:
        return (self.dir / ".git").exists()

    def ensure(self) -> None:
        if self.exists():
            return
        self.dir.mkdir(parents=True, exist_ok=True)
        self._git("init", "-q", "-b", "main")
        ignore = self.dir / ".gitignore"
        if not ignore.exists():
            ignore.write_text(_IGNORE, encoding="utf-8")

    def tags(self) -> list[str]:
        if not self.exists():
            return []
        tags = [t for t in self._git("tag", "--list", "v*").splitlines() if t[1:].isdigit()]
        return sorted(tags, key=lambda t: int(t[1:]))

    def current(self) -> str | None:
        tags = self.tags()
        return tags[-1] if tags else None

    def snapshot(self, message: str) -> str:
        """Commit the current files as the next version and return its tag (v1, v2, ...)."""
        self.ensure()
        self._git("add", "-A")
        self._git("commit", "-q", "--allow-empty", "-m", message)
        tags = self.tags()
        tag = f"v{int(tags[-1][1:]) + 1 if tags else 1}"
        self._git("tag", tag)
        return tag

    def log(self) -> list[dict]:
        """Versions oldest first: [{version, date, message}]."""
        out = []
        for tag in self.tags():
            date, _, msg = self._git("log", "-1", "--format=%cI%x00%B", tag).partition("\x00")
            out.append({"version": tag, "date": date, "message": msg.strip()})
        return out

    def restore(self, version: str, reason: str) -> str:
        """Put `version`'s files back (adds, edits and deletes) and record that as a new version."""
        if version not in self.tags():
            raise VersionError(f"no version {version!r}; have {', '.join(self.tags()) or 'none'}")
        self._git("add", "-A")  # so files written since the last version are removed too
        self._git("read-tree", "-u", "--reset", version)
        return self.snapshot(f"rollback to {version}: {reason}")

    def changed_files(self, since: str) -> list[str]:
        return [p for p in self._git("diff", "--name-only", since, "HEAD").splitlines() if p.endswith(".luau")]
