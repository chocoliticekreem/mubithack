import asyncio
from pathlib import Path

import pytest

from forge.cli import build_parser, sync_before_checks


class FakeStudio:
    def __init__(self, reply="OK 12 files, changed: Hud.client.luau"):
        self.reply, self.calls = reply, []

    async def sync(self, root, port=None, prune=True):
        self.calls.append((Path(root), port))
        return self.reply


def test_checks_sync_the_game_on_disk_before_running(tmp_path):
    studio = FakeStudio()
    out = asyncio.run(sync_before_checks(studio, tmp_path / "game", 34999))
    assert studio.calls == [(tmp_path / "game", 34999)] and out.startswith("OK")


def test_a_failed_sync_stops_the_checks_instead_of_testing_old_code(tmp_path):
    with pytest.raises(RuntimeError, match="sync before checks failed"):
        asyncio.run(sync_before_checks(FakeStudio("ERROR: port in use"), tmp_path, 34999))


def test_no_sync_flag_is_available():
    args = build_parser().parse_args(["checks", "g", "--run", "--no-sync"])
    assert args.no_sync and args.run
