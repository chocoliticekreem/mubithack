"""forge promote-game: an agent-built game gets its own games/<slug>/ folder."""

import dataclasses
import json

from forge.config import load_settings
from forge.games import promote_game
from forge.memory import RunStore
from forge.versions import GameVersions


def test_promote_game_copies_code_spec_and_writes_a_readme(tmp_path):
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs", repo_root=tmp_path)
    store = RunStore(s, "tiny-tycoon")
    store.ensure()
    store.save_spec({"title": "Tiny Tycoon", "pitch": "droppers and cash", "core_loop": "collect, buy, grow",
                     "modules": [{"path": "ServerScriptService/Game.server.luau", "purpose": "the loop"}],
                     "acceptance": ["cash rises"]})
    state = store.new_state("idea")
    state["iterations"] = [{"n": 1, "score": 7}, {"n": 2, "score": 7}]
    store.save_state(state)
    f = store.game_dir / "ServerScriptService/Game.server.luau"
    f.parent.mkdir(parents=True)
    f.write_text("print('tycoon')\n")
    (store.game_dir / "tools").mkdir()
    (store.game_dir / "tools" / "manifest.json").write_text("{}")
    GameVersions(store.game_dir).snapshot("v")
    dest = promote_game(s, "tiny-tycoon")
    assert (dest / "game/ServerScriptService/Game.server.luau").read_text() == "print('tycoon')\n"
    assert not (dest / "game/.git").exists() and not (dest / "game/tools/manifest.json").exists()
    assert json.loads((dest / "spec.json").read_text())["title"] == "Tiny Tycoon"
    readme = (dest / "README.md").read_text()
    assert "# Tiny Tycoon" in readme and "collect, buy, grow" in readme and "critic scores: 7, 7" in readme
    assert "forge place --root games/tiny-tycoon/game" in readme
