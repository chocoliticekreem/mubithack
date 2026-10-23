"""Tests for forge.studio: live StudioMCP tool listing (if installed) + result-parsing helpers."""

from __future__ import annotations

import base64
from pathlib import Path

import pytest
from mcp.types import BlobResourceContents, EmbeddedResource, ImageContent, TextContent

from forge import studio as st
from forge.config import load_settings

BINARY = Path(load_settings().studio_mcp_path)


@pytest.mark.skipif(not BINARY.exists(), reason=f"StudioMCP binary missing at {BINARY}")
async def test_studio_mcp_lists_tools():
    async with st.Studio() as s:
        assert "execute_luau" in s.tools
        assert {"list_roblox_studios", "get_studio_state", "start_stop_play", "screen_capture"} <= set(s.tools)
        studios = await s.list_studios()
        assert isinstance(studios, list)
        # select() retries, so an empty first list can still pick a window that appears a moment later
        try:
            sid = await s.select()
        except st.StudioError as e:
            assert "Manage MCP Servers" in str(e)
        else:
            assert sid


def test_content_text_joins_text_blocks():
    blocks = [TextContent(text="a"), ImageContent(data="eA==", mime_type="image/png"), TextContent(text="b")]
    assert st.content_text(blocks) == "a\nb"
    assert st.content_text([{"type": "text", "text": "x"}]) == "x"
    assert st.content_text(None) == ""


def test_extract_image_from_image_block_and_blob():
    png = b"\x89PNG\r\n\x1a\nfake"
    b64 = base64.b64encode(png).decode()
    assert st.extract_image([TextContent(text="hi"), ImageContent(data=b64, mime_type="image/png")]) == (png, "image/png")
    res = EmbeddedResource(resource=BlobResourceContents(uri="file:///x.png", blob=b64, mime_type="image/png"))
    assert st.extract_image([res]) == (png, "image/png")
    assert st.extract_image([TextContent(text="no image")]) is None


def test_extract_json_variants():
    assert st.extract_json('{"studios":[]}') == {"studios": []}
    assert st.extract_json('"{\\"a\\": 1}"') == {"a": 1}  # double-encoded
    assert st.extract_json('[OUTPUT] hi\n[RETURNED RESULTS]\n{"uptime": 1.5, "errors": []}') == {
        "uptime": 1.5,
        "errors": [],
    }
    assert st.extract_json("Place1") is None
    assert st.extract_json("") is None


def test_parse_studios():
    assert st.parse_studios('{"studios":[]}') == []
    got = st.parse_studios({"studios": [{"id": 7, "name": "Place1 (local)"}]})
    assert got == [{"id": "7", "name": "Place1 (local)"}]
    assert st.parse_studios(["abc"]) == [{"id": "abc", "name": "abc"}]


@pytest.mark.parametrize(
    "state,dms,playing",
    [
        ({"available_datamodel_types": ["Edit"], "play_state": "Edit"}, {"Edit"}, False),
        ({"availableDataModelTypes": ["Client", "Server"]}, {"Client", "Server"}, True),
        ("Play state: Running. Available datamodel types: Client, Server", {"Client", "Server"}, True),
        ({"isPlaying": False}, set(), False),
        ({"something": 1}, set(), None),
    ],
)
def test_datamodels_and_playing(state, dms, playing):
    assert st.available_datamodels(state) == dms
    if isinstance(state, str):
        state = {"raw": state}
    assert st.is_playing(state) is playing


class FakeResult:
    def __init__(self, content, is_error=False):
        self.content = content
        self.is_error = is_error
        self.structured_content = None


class FakeSession:
    def __init__(self, replies):
        self.replies = replies
        self.calls = []

    async def call_tool(self, name, args, read_timeout_seconds=None):
        self.calls.append((name, dict(args)))
        reply = self.replies[name]
        return reply(args) if callable(reply) else reply


def _fake_studio(replies) -> st.Studio:
    s = st.Studio()
    s._session = FakeSession(replies)  # type: ignore[assignment]
    return s


async def test_select_no_studios_raises_helpful_error(monkeypatch):
    monkeypatch.setattr(st, "SELECT_RETRY_SECONDS", 0)
    s = _fake_studio({"list_roblox_studios": FakeResult([TextContent(text='{"studios":[]}')])})
    with pytest.raises(st.StudioError, match="Manage MCP Servers"):
        await s.execute_luau("return 1")


async def test_execute_luau_injects_studio_id_and_raises_on_error():
    s = _fake_studio(
        {
            "list_roblox_studios": FakeResult([TextContent(text='{"studios":[{"id":"s1","name":"P"}]}')]),
            "execute_luau": lambda a: FakeResult([TextContent(text="boom")], is_error=a["code"] == "bad"),
        }
    )
    assert await s.execute_luau("return game.Name") == "boom"
    assert s._session.calls[-1] == (
        "execute_luau",
        {"code": "return game.Name", "datamodel_type": "Edit", "studio_id": "s1"},
    )
    with pytest.raises(st.StudioError, match="boom"):
        await s.execute_luau("bad", "Server")


async def test_probe_report_and_screenshot(tmp_path):
    png = b"\x89PNGdata"
    s = _fake_studio(
        {
            "execute_luau": FakeResult([TextContent(text='{"uptime": 3, "errors": [], "players": 1}')]),
            "screen_capture": FakeResult([ImageContent(data=base64.b64encode(png).decode(), mime_type="image/png")]),
        }
    )
    s.studio_id = "s1"
    assert (await s.probe_report())["players"] == 1
    out = await s.screenshot(tmp_path / "shot.png")
    assert out is not None and out.read_bytes() == png
    s._session.replies["screen_capture"] = FakeResult([TextContent(text="captured")])
    assert await s.screenshot(tmp_path / "none.png") is None
    s._session.replies["execute_luau"] = FakeResult([TextContent(text="ForgeProbe missing")], is_error=True)
    assert "error" in await s.probe_report()


async def test_play_polls_state_until_server(monkeypatch):
    states = iter(['{"datamodels":["Edit"]}', '{"datamodels":["Edit"]}', '{"datamodels":["Client","Server"]}'])
    s = _fake_studio(
        {
            "get_studio_state": lambda a: FakeResult([TextContent(text=next(states))]),
            "start_stop_play": FakeResult([TextContent(text="ok")]),
        }
    )
    s.studio_id = "s1"
    monkeypatch.setattr(st, "POLL_INTERVAL", 0.01)
    await s.play()
    assert [c[0] for c in s._session.calls].count("start_stop_play") == 1


async def test_select_by_id_when_two_studios_share_a_name():
    studios = '{"studios":[{"id":"a1","name":"Forge.rbxlx"},{"id":"b2","name":"Forge.rbxlx"}]}'
    s = _fake_studio({"list_roblox_studios": FakeResult([TextContent(text=studios)])})
    assert await s.select("b2") == "b2"
    assert await s.select("Forge.rbxlx") == "a1"


async def test_select_retries_when_the_first_list_is_empty(monkeypatch):
    monkeypatch.setattr(st, "SELECT_RETRY_SECONDS", 0)
    replies = iter(['{"studios":[]}', '{"studios":[]}', '{"studios":[{"id":"s1","name":"Forge.rbxlx"}]}'])
    s = _fake_studio({"list_roblox_studios": lambda a: FakeResult([TextContent(text=next(replies))])})
    assert await s.select("Forge") == "s1"


async def test_a_brief_studio_dropout_is_retried(monkeypatch):
    monkeypatch.setattr(st, "DROPOUT_WAIT_SECONDS", 0)
    replies = iter([True, True, False])
    s = _fake_studio({
        "list_roblox_studios": FakeResult([TextContent(text='{"studios":[{"id":"s1","name":"P"}]}')]),
        "execute_luau": lambda a: (FakeResult([TextContent(text=st.DROPOUT_TEXT + ". Ask the user...")], is_error=True)
                                   if next(replies) else FakeResult([TextContent(text="ok")])),
    })
    assert await s.execute_luau("return 1") == "ok"


async def test_a_real_error_is_not_retried(monkeypatch):
    monkeypatch.setattr(st, "DROPOUT_WAIT_SECONDS", 0)
    s = _fake_studio({
        "list_roblox_studios": FakeResult([TextContent(text='{"studios":[{"id":"s1","name":"P"}]}')]),
        "execute_luau": FakeResult([TextContent(text="syntax error")], is_error=True),
    })
    with pytest.raises(st.StudioError, match="syntax error"):
        await s.execute_luau("bad")
    assert [c[0] for c in s._session.calls].count("execute_luau") == 1
