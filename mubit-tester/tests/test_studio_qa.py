"""The Studio QA scripts MuMake runs at every launch compile, and the shop step buys only what it can afford."""
import shutil
import subprocess

import pytest

from mubit_tester import studio_service

LUAU = shutil.which("luau-compile")


@pytest.mark.skipif(not LUAU, reason="luau-compile not on PATH")
@pytest.mark.parametrize("name", ["QA_COINS", "QA_SHOP", "QA_JOURNEY", "QA_START", "QA_WHERE"])
def test_studio_qa_scripts_compile(name, tmp_path):
    src = getattr(studio_service, name).replace("__PLAN__", '"[]"').replace("__TIMEOUT__", "14") \
        .replace("__ATTEMPTS__", "2").replace("__NAMES__", '"[]"')
    path = tmp_path / f"{name}.luau"
    path.write_text(src)
    out = subprocess.run([LUAU, str(path)], capture_output=True, text=True)
    assert out.returncode == 0, out.stderr


def test_the_shop_step_buys_a_priced_affordable_costume_through_the_shop_remote():
    shop = studio_service.QA_SHOP
    assert 'CosmeticsRemotes' in shop and 'InvokeServer("buy", pick.id)' in shop and 'InvokeServer("equip", pick.id)' in shop
    assert "c.price > 0 and c.price <= (st.balance or 0)" in shop  # a real purchase, never a free or reward item
