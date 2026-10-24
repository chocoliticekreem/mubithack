"""Plugin packaging: every skill and agent has valid frontmatter, skills only name tools that
exist, and the marketplace versions match each plugin.json."""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent.parent
SKILLS = sorted((REPO / "mubit-tester" / "skills").glob("*/SKILL.md")) + \
    sorted((REPO / "forge-plugin" / "skills").glob("*/SKILL.md"))
AGENTS = sorted((REPO / "mubit-tester" / "agents").glob("*.md"))


def _front(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    assert m, f"{path} has no frontmatter"
    out = {}
    for line in m.group(1).splitlines():
        k, _, v = line.partition(":")
        out[k.strip()] = v.strip()
    return out


def test_expected_skills_ship():
    names = {p.parent.name for p in SKILLS}
    assert {"testing-roblox-features", "triaging-tester-reports", "training-mubit-from-corrections",
            "swarm-testing", "building-games-with-forge", "improving-games-until-done"} <= names
    assert "qa-lead" in {p.stem for p in AGENTS}


@pytest.mark.parametrize("path", SKILLS + AGENTS, ids=lambda p: f"{p.parent.parent.name}/{p.parent.name}/{p.name}")
def test_frontmatter(path):
    fm = _front(path)
    name = fm.get("name", "")
    assert re.fullmatch(r"[a-z0-9-]+", name), name
    if path.name == "SKILL.md":
        assert name == path.parent.name
        assert fm["description"].startswith("Use when"), "skill descriptions say when to use, not what it does"
        assert len(fm["description"]) <= 500
        if name not in ("mubit-tester", "forge"):  # the two tool references may be longer
            assert len(path.read_text(encoding="utf-8").split()) < 700, "keep workflow skills short"


async def test_skills_only_name_real_tools():
    from forge import mcp_server as fm
    from mubit_tester import server as ms
    tools = {t.name for t in await ms.mcp.list_tools()} | {t.name for t in await fm.mcp.list_tools()}
    retired = {"new_game", "fix", "improve"}  # renamed: build_game, improve_game, fault_drill
    for path in SKILLS + AGENTS:
        text = path.read_text(encoding="utf-8")
        called = set(re.findall(r"`([a-z_]+)\(", text))
        assert not (called & retired), f"{path}: retired tool names {called & retired}"
        unknown = {c for c in called if c not in tools and c not in {"register"}}
        assert not unknown, f"{path} calls unknown tools {unknown}"


def test_marketplace_versions_match_plugins():
    market = json.loads((REPO / ".claude-plugin" / "marketplace.json").read_text())
    for entry in market["plugins"]:
        plugin = json.loads((REPO / entry["source"] / ".claude-plugin" / "plugin.json").read_text())
        assert entry["name"] == plugin["name"] and entry["version"] == plugin["version"]
