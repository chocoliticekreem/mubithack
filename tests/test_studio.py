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
            assert "Manage MCP Servers" in str(e) or "Pin one by id" in str(e)  # several open: never guess
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
    with pytest.raises(st.StudioError, match="2 Studios match 'Forge.rbxlx'.*a1.*b2"):
        await s.select("Forge.rbxlx")  # ambiguous: never pick the first one


async def test_select_never_guesses_between_several_studios(monkeypatch):
    monkeypatch.setattr(st, "SELECT_RETRY_SECONDS", 0)
    monkeypatch.delenv("FORGE_STUDIO", raising=False)
    studios = '{"studios":[{"id":"a1","name":"Forge.rbxlx"},{"id":"t9","name":"tiny-tycoon.rbxlx"}]}'
    s = _fake_studio({"list_roblox_studios": FakeResult([TextContent(text=studios)])})
    with pytest.raises(st.StudioError, match="2 Studios are connected and none is pinned.*FORGE_STUDIO"):
        await s.select()
    assert await s.select("tiny") == "t9" and await s.select("forge.rbxlx") == "a1"
    monkeypatch.setenv("FORGE_STUDIO", "a1")
    assert await s.select() == "a1"
    monkeypatch.setenv("FORGE_STUDIO", "gone")
    with pytest.raises(st.StudioError, match="No connected Studio matches 'gone'"):
        await s.select()


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


def _studios(*names):
    body = ",".join(f'{{"id":"id-{n}","name":"{n}.rbxlx"}}' for n in names)
    return FakeResult([TextContent(text=f'{{"studios":[{body}]}}')])


async def test_select_prefers_an_exact_name_over_a_prefix():
    s = _fake_studio({"list_roblox_studios": _studios("Forge-agents-21", "Forge-agents-2", "Forge-agents-22")})
    assert await s.select("Forge-agents-2") == "id-Forge-agents-2"
    assert await s.select("forge-agents-21.rbxlx") == "id-Forge-agents-21"
    assert await s.select("agents-22") == "id-Forge-agents-22"


def _sync_studio(tmp_path, pulls):
    def execute(args):
        pulls.append(args["code"])
        return FakeResult([TextContent(text="OK 2 files, changed: x; skipped 0, fetched 0")])
    s = _fake_studio({
        "get_studio_state": FakeResult([TextContent(text='{"datamodels":["Edit"]}')]),
        "execute_luau": execute,
    })
    s.studio_id = "s1"
    return s


def _game(tmp_path):
    root = tmp_path / "game"
    (root / "ReplicatedStorage").mkdir(parents=True)
    (root / "ServerScriptService").mkdir()
    (root / "ReplicatedStorage" / "Config.luau").write_text("return { A = 1 }\n")
    (root / "ServerScriptService" / "Main.server.luau").write_text("print('main')\n")
    return root


async def test_incremental_sync_inlines_only_changed_files(tmp_path):
    root = _game(tmp_path)
    pulls: list[str] = []
    s = _sync_studio(tmp_path, pulls)
    try:
        await s.sync(root, 0)
        assert "return { A = 1 }" in pulls[-1] and "print('main')" in pulls[-1]  # cold: everything inline
        assert "local INLINE_JSON: string? = nil" not in pulls[-1]
        assert s.pushed(root) is not None and len(s.pushed(root)) == 2

        await s.sync(root, 0)  # nothing changed: manifest only, no sources
        assert "local INLINE_JSON: string? = nil" in pulls[-1]
        assert "local MANIFEST_JSON: string? = nil" not in pulls[-1]

        (root / "ReplicatedStorage" / "Config.luau").write_text("return { A = 2 }\n")
        await s.sync(root, 0)
        assert "return { A = 2 }" in pulls[-1] and "print('main')" not in pulls[-1]
        assert len(s._servers) == 1  # one long-lived file server, not one per sync

        await s.sync(root, 0, incremental=False)  # the original path: manifest + files over HTTP
        assert "local MANIFEST_JSON: string? = nil" in pulls[-1]
    finally:
        await s.__aexit__(None, None, None)


async def test_failed_sync_forgets_what_was_pushed(tmp_path):
    root = _game(tmp_path)
    s = _fake_studio({
        "get_studio_state": FakeResult([TextContent(text='{"datamodels":["Edit"]}')]),
        "execute_luau": FakeResult([TextContent(text="ERROR HttpService is not allowed")]),
    })
    s.studio_id = "s1"
    try:
        assert (await s.sync(root, 0)).startswith("ERROR")
        assert s.pushed(root) is None
    finally:
        await s.__aexit__(None, None, None)


async def test_sync_falls_back_to_a_free_port_when_taken(tmp_path):
    import socket
    root = _game(tmp_path)
    blocker = socket.socket()
    blocker.bind(("127.0.0.1", 0))
    blocker.listen(1)
    taken = blocker.getsockname()[1]
    pulls: list[str] = []
    s = _sync_studio(tmp_path, pulls)
    try:
        await s.sync(root, taken)
        (port,) = s._servers
        assert port != taken and f"127.0.0.1:{port}/" in pulls[-1]
    finally:
        blocker.close()
        await s.__aexit__(None, None, None)


def test_module_state_vars():
    src = "local M = {}\nlocal cache = {}\nlocal count = 0\nlocal CONST = { a = 1 }\n" \
          "local function f() local inner = {} end\nreturn M\n"
    assert st.module_state_vars(src) == ["cache", "count"]
    assert st.module_state_vars("local M = {}\nfunction M.f() end\nreturn M\n") == []


def test_hot_reload_plan():
    entries = [
        {"path": "ServerScriptService/Logic.luau", "service": "ServerScriptService", "class": "ModuleScript"},
        {"path": "ServerScriptService/Stateful.luau", "service": "ServerScriptService", "class": "ModuleScript"},
        {"path": "ServerScriptService/Main.server.luau", "service": "ServerScriptService", "class": "Script"},
        {"path": "ReplicatedStorage/Shared.luau", "service": "ReplicatedStorage", "class": "ModuleScript"},
        {"path": "ServerStorage/New.luau", "service": "ServerStorage", "class": "ModuleScript"},
    ]
    sources = {"ServerScriptService/Logic.luau": "local M = {}\nreturn M\n",
               "ServerScriptService/Stateful.luau": "local M = {}\nlocal plots = {}\nreturn M\n"}
    plan = st.hot_reload_plan(entries, [e["path"] for e in entries] + ["ServerScriptService/Gone.luau"],
                              sources, added=["ServerStorage/New.luau"])
    assert [e["path"] for e in plan["reload"]] == ["ServerScriptService/Logic.luau"]
    why = dict(plan["restart"])
    assert set(why) == {"ServerScriptService/Stateful.luau", "ServerScriptService/Main.server.luau",
                        "ReplicatedStorage/Shared.luau", "ServerStorage/New.luau", "ServerScriptService/Gone.luau"}
    assert "plots" in why["ServerScriptService/Stateful.luau"]


async def test_hot_reload_sends_only_reloadable_modules(tmp_path):
    root = tmp_path / "game"
    (root / "ServerScriptService").mkdir(parents=True)
    logic = root / "ServerScriptService" / "Logic.luau"
    logic.write_text("local M = {}\nfunction M.f() return 1 end\nreturn M\n")
    pulls: list[str] = []
    s = _sync_studio(tmp_path, pulls)
    try:
        assert (await s.hot_reload(root))["restart"]  # nothing synced yet
        await s.sync(root, 0)
        logic.write_text("local M = {}\nfunction M.f() return 2 end\nreturn M\n")
        s._session.replies["execute_luau"] = lambda a: (pulls.append(a["code"]), FakeResult(
            [TextContent(text='{"ServerScriptService/Logic.luau":"reloaded 1"}')]))[1]
        res = await s.hot_reload(root)
        assert res["restart"] == [] and res["reloaded"] == {"ServerScriptService/Logic.luau": "reloaded 1"}
        assert "return 2" in pulls[-1] and s._session.calls[-1][1]["datamodel_type"] == "Server"
        # an old ForgeProbe without "hotreload" (or a module that fails to load) means restart
        logic.write_text("local M = {}\nfunction M.f() return 3 end\nreturn M\n")
        s._session.replies["execute_luau"] = FakeResult(
            [TextContent(text='{"ServerScriptService/Logic.luau":"{\\"error\\":\\"unknown command: hotreload\\"}"}')])
        res = await s.hot_reload(root)
        assert res["reloaded"] == {} and res["restart"][0][0] == "ServerScriptService/Logic.luau"
        assert "unknown command" in res["restart"][0][1]
        (root / "ServerScriptService" / "Main.server.luau").write_text("print(1)\n")
        res = await s.hot_reload(root)
        assert res["reloaded"] == {} and res["restart"]
    finally:
        await s.__aexit__(None, None, None)


async def test_wait_ready_parses_and_never_raises(monkeypatch):
    s = _fake_studio({"execute_luau": FakeResult([TextContent(text='{"ready":true,"reason":"ServerBooted"}')])})
    s.studio_id = "s1"
    assert (await s.wait_ready(5))["ready"] is True
    assert s._session.calls[-1][1]["datamodel_type"] == "Server"
    s._session.replies["execute_luau"] = FakeResult([TextContent(text="no server")], is_error=True)
    res = await s.wait_ready(1)
    assert res["ready"] is False and "no server" in res["error"]


async def test_transport_loss_reconnects_once(monkeypatch):
    import anyio
    calls = {"n": 0}

    def flaky(args):
        calls["n"] += 1
        if calls["n"] == 1:
            raise anyio.ClosedResourceError()
        return FakeResult([TextContent(text="ok")])
    s = _fake_studio({"execute_luau": flaky})
    s.studio_id = "s1"
    s._stack = object()  # pretend we own a connection

    async def fake_reconnect():
        s.reconnects += 1
    monkeypatch.setattr(s, "reconnect", fake_reconnect)
    assert await s.execute_luau("return 1") == "ok"
    assert s.reconnects == 1
    assert [t for t, _ in s.timings] == ["execute_luau", "execute_luau"]


async def test_a_real_error_is_not_retried(monkeypatch):
    monkeypatch.setattr(st, "DROPOUT_WAIT_SECONDS", 0)
    s = _fake_studio({
        "list_roblox_studios": FakeResult([TextContent(text='{"studios":[{"id":"s1","name":"P"}]}')]),
        "execute_luau": FakeResult([TextContent(text="syntax error")], is_error=True),
    })
    with pytest.raises(st.StudioError, match="syntax error"):
        await s.execute_luau("bad")
    assert [c[0] for c in s._session.calls].count("execute_luau") == 1
