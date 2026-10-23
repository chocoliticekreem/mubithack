"""`forge correct` on a large file goes through the patcher, so a human correction never shortens it."""

from __future__ import annotations

import io
import json

from forge.llm import FakeLLM
from forge.loop import UI, correct
from forge.memory import RunStore
from test_fix_loop import HOSE_FILE, settings  # noqa: F401
from test_patcher import BIG


async def test_human_correction_on_a_big_file_uses_the_patcher(settings):
    store = RunStore(settings, "big")
    store.ensure()
    store.save_spec({"title": "T", "pitch": "p", "modules": [{"path": HOSE_FILE, "purpose": "x"}]})
    store.save_state(store.new_state("idea"))
    (store.game_dir / HOSE_FILE).parent.mkdir(parents=True, exist_ok=True)
    (store.game_dir / HOSE_FILE).write_text(BIG)
    edit = {"find": "\tif water <= 0 then", "replace": "\tif (water or 0) <= 0 then"}
    llm = FakeLLM({"patcher": [json.dumps({"summary": "s", "edits": [edit]})]})
    out = await correct("big", HOSE_FILE, "spraying with no water attribute errors", use_studio=False,
                        settings=settings, llm=llm, ui=UI(io.StringIO()))
    text = (store.game_dir / HOSE_FILE).read_text()
    assert "(water or 0)" in text and len(text.splitlines()) == len(BIG.splitlines())
    assert [c.role for c in llm.calls] == ["patcher"] and "Human playtester correction" in llm.calls[0].user
    assert out["compile_ok"] is True
