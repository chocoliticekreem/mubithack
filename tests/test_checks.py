import asyncio
import shutil
import subprocess

import pytest

from forge.checks import Check, check_id, load_checks, parse, result_from, run_check, save_check, summary, wrap


class FakeStudio:
    def __init__(self, reply=None, exc=None):
        self.reply, self.exc, self.calls = reply, exc, []

    async def execute_luau(self, code, datamodel="Edit", timeout=None):
        self.calls.append((code, datamodel))
        if self.exc:
            raise self.exc
        return self.reply


def test_save_load_round_trip(tmp_path):
    c = Check(id=check_id("Buy pad: 2nd dropper!"), title="Buy pad works", covers="acceptance: dropper",
              body="return { ok = true, detail = 'x' }")
    save_check(tmp_path, c)
    [got] = load_checks(tmp_path)
    assert got.id == "buy-pad-2nd-dropper" and got.title == "Buy pad works" and got.covers == "acceptance: dropper"
    assert "return { ok = true" in got.body
    assert parse(got.body).title == "Buy pad works"


def test_result_from_reads_json_and_rejects_garbage():
    assert result_from('{"ok":true,"detail":"cash 25 -> 0"}') == {"ok": True, "detail": "cash 25 -> 0"}
    assert result_from('{"ok":false,"error":"boom"}')["error"] == "boom"
    assert result_from("nothing")["ok"] is False


def test_run_check_uses_server_and_reports_errors():
    ok = asyncio.run(run_check(FakeStudio('{"ok":true,"detail":"d"}'), Check("a", "A", "", "return {ok=true}")))
    assert ok == {"id": "a", "title": "A", "ok": True, "detail": "d"}
    bad = asyncio.run(run_check(FakeStudio(exc=TimeoutError("slow")), Check("b", "B", "", "")))
    assert bad["ok"] is False and "TimeoutError" in bad["error"]
    assert "FAIL b" in summary([ok, bad]) and "1/2 pass" in summary([ok, bad])


@pytest.mark.skipif(not shutil.which("luau-compile"), reason="luau-compile not on PATH")
def test_wrapped_check_compiles(tmp_path):
    body = "local x = 1\ntask.wait(0)\nif x == 1 then return { ok = true, detail = 'one' } end\nreturn { ok = false }"
    f = tmp_path / "c.luau"
    f.write_text(wrap(body))
    assert subprocess.run(["luau-compile", "--null", str(f)], capture_output=True).returncode == 0
