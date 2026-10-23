"""Tests for forge.assets: manifest, AssetIds.luau, generation via a fake Studio, search, Open Cloud upload
with mocked HTTP. Nothing here talks to Studio or Roblox."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
from pathlib import Path

import pytest
from mcp.types import TextContent

from forge import assets as A
from forge.cli import build_parser


def entry(**kw) -> dict:
    e = {"id": "Thing", "kind": "mesh", "source": "generate", "prompt": "a thing", "assetId": None,
         "status": "todo", "notes": ""}
    e.update(kw)
    return e


class FakeResult:
    def __init__(self, text: str, structured: dict | None = None):
        self.content = [TextContent(text=text)]
        self.structured_content = structured
        self.is_error = False


class FakeStudio:
    """Records calls; replies from a {tool: reply | callable(args)} map; luau replies are a FIFO list."""

    def __init__(self, replies: dict, luau: list[str] | None = None):
        self.replies = replies
        self.luau = list(luau or [])
        self.calls: list[tuple[str, dict]] = []
        self.codes: list[str] = []

    async def call_result(self, tool, timeout=None, **args):
        self.calls.append((tool, args))
        r = self.replies[tool]
        r = r(args) if callable(r) else r
        return r if isinstance(r, FakeResult) else FakeResult(json.dumps(r))

    async def execute_luau(self, code, datamodel="Edit", timeout=None):
        self.codes.append(code)
        return self.luau.pop(0) if self.luau else "missing"

    async def state(self):
        return {"playing": False}


# ---------------------------------------------------------------- manifest / AssetIds


def test_seed_manifest_is_valid_and_in_sync():
    data = A.load_manifest()
    assert len(data["assets"]) >= 25
    kinds = {e["kind"] for e in data["assets"]}
    assert kinds == set(A.KINDS)
    assert A.sync_ids(data, A.ASSET_IDS_LUAU, check=True) is False, "run `forge assets sync`"


def test_validate_rejects_bad_ids_and_duplicates():
    with pytest.raises(A.AssetError, match="Luau identifier"):
        A.validate({"assets": [entry(id="fire-axe")]})
    with pytest.raises(A.AssetError, match="duplicate"):
        A.validate({"assets": [entry(), entry()]})
    with pytest.raises(A.AssetError, match="kind"):
        A.validate({"assets": [entry(kind="sprite")]})


def test_rbx():
    assert A.rbx(None) == "" and A.rbx("") == ""
    assert A.rbx(123) == "rbxassetid://123"
    assert A.rbx("rbxassetid://9") == "rbxassetid://9"
    with pytest.raises(A.AssetError):
        A.rbx("nope")


def test_render_asset_ids_empty_until_done(tmp_path):
    data = {"assets": [
        entry(id="Helmet", status="done", assetId="111", contentId="rbxassetid://222",
              extra={"Texture": "rbxassetid://333", "Model": "rbxassetid://111"}),
        entry(id="Glove"),
        entry(id="Siren", kind="audio", source="marketplace", status="candidates", assetId=None),
        entry(id="Bell", kind="audio", source="marketplace", status="done", assetId="444"),
    ]}
    text = A.render_asset_ids(data)
    assert 'Helmet = "rbxassetid://222"' in text
    assert 'Helmet_Texture = "rbxassetid://333"' in text
    assert 'Helmet_Model = "rbxassetid://111"' in text
    assert 'Glove = ""' in text and 'Glove_Texture = ""' in text and 'Glove_Model = ""' in text
    assert 'Siren = ""' in text and 'Bell = "rbxassetid://444"' in text
    out = tmp_path / "AssetIds.luau"
    assert A.sync_ids(data, out) is True
    assert A.sync_ids(data, out) is False
    assert A.sync_ids(data, out, check=True) is False


@pytest.mark.skipif(not shutil.which("luau-compile"), reason="luau-compile missing")
def test_generated_luau_compiles(tmp_path):
    out = tmp_path / "AssetIds.luau"
    A.sync_ids(A.load_manifest(), out)
    r = subprocess.run(["luau-compile", "--null", str(out)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


# ---------------------------------------------------------------- generate


def _gen_replies(published="555"):
    return {
        "generate_mesh": {"jobId": "job-1", "status": "Running"},
        "wait_job_finished": {"status": "Completed", "jobResult": {"structuredContent": {
            "generationId": "gen-1", "publishedAssetId": published, "tag": "Assistant-x"}}},
    }


FOUND = json.dumps({"found": True, "path": "Workspace.Forge_Thing", "class": "Model", "parts": [
    {"name": "small", "meshId": "rbxassetid://1", "textureId": "rbxassetid://2", "size": [1, 1, 1]},
    {"name": "body_geom", "meshId": "rbxassetid://10", "textureId": "rbxassetid://20", "size": [3, 2, 3]},
]})


async def test_generate_mesh_records_ids_and_cleans_up():
    studio = FakeStudio(_gen_replies(), luau=[FOUND, "destroyed"])
    e = entry(params={"size": [3, 2, 3.4], "maxTriangles": 4000, "segmentation": "none"})
    await A.generate_entry(studio, e, log=lambda _: None)

    tool, args = studio.calls[0]
    assert tool == "generate_mesh" and args["async"] is True
    assert args["size"] == {"x": 3, "y": 2, "z": 3.4} and args["maxTriangles"] == 4000
    assert studio.calls[1] == ("wait_job_finished", {"jobId": "job-1"})
    assert '"gen-1"' in studio.codes[0] and '"Forge_Thing"' in studio.codes[0]
    assert "Destroy" in studio.codes[1] and "Workspace.Forge_Thing" in studio.codes[1]
    assert e["status"] == "done" and e["assetId"] == "555"
    assert e["contentId"] == "rbxassetid://10"  # biggest MeshPart
    assert e["extra"] == {"Model": "rbxassetid://555", "Texture": "rbxassetid://20"}
    assert e["generation"]["id"] == "gen-1" and len(e["generation"]["meshParts"]) == 2


async def test_generate_keep_and_unpersisted_stay_in_studio():
    studio = FakeStudio(_gen_replies(), luau=[FOUND])
    await A.generate_entry(studio, entry(), keep=True, log=lambda _: None)
    assert len(studio.codes) == 1  # no destroy

    empty = json.dumps({"found": True, "path": "Workspace.Forge_Thing", "parts": []})
    studio = FakeStudio(_gen_replies(published=None), luau=[empty])
    e = await A.generate_entry(studio, entry(), log=lambda _: None)
    assert e["status"] == "failed" and len(studio.codes) == 1


async def test_generate_job_failure_raises():
    replies = _gen_replies()
    replies["wait_job_finished"] = {"status": "Failed", "error": "quota"}
    with pytest.raises(A.AssetError, match="Failed"):
        await A.generate_entry(FakeStudio(replies), entry(), log=lambda _: None)


async def test_generate_material_reads_variant():
    studio = FakeStudio({"generate_material": {"BaseMaterial": "Wood", "Name": "CharredWood"}},
                        luau=[json.dumps({"found": True, "name": "CharredWood", "baseMaterial": "Wood",
                                          "colorMap": "rbxassetid://7", "normalMap": "rbxassetid://8",
                                          "roughnessMap": "", "metalnessMap": ""})])
    e = entry(id="CharredWood", kind="texture", params={"tool": "material", "baseMaterial": "Wood",
                                                          "materialPattern": "Organic"})
    await A.generate_entry(studio, e, log=lambda _: None)
    assert studio.calls[0] == ("generate_material", {"materialId": "CharredWood", "baseMaterial": "Wood",
                                                     "materialPattern": "Organic", "materialDescription": "a thing"})
    assert e["status"] == "done" and e["contentId"] == "rbxassetid://7" and e["extra"] == {"Normal": "rbxassetid://8"}


async def test_generate_rejects_plain_texture():
    with pytest.raises(A.AssetError, match="can't generate"):
        await A.generate_entry(FakeStudio({}), entry(kind="audio"), log=lambda _: None)


# ---------------------------------------------------------------- search / pick

SEARCH = {"status": "success", "results": [
    {"assetId": "317455930", "name": "Fire Truck Siren", "creatorName": "BeFUZZled", "isFree": True,
     "priceCents": 0, "assetType": "Audio", "source": "creator_store",
     "creatorStoreUrl": "https://create.roblox.com/store/asset/317455930"},
    {"assetId": "200252683", "name": "Siren 2", "creatorName": "Someone", "isFree": True, "source": "creator_store"},
]}


async def test_search_records_candidates_and_pick():
    studio = FakeStudio({"search_asset": SEARCH})
    e = entry(id="SfxSiren", kind="audio", source="marketplace", query="fire truck siren")
    cands = await A.search_entry(studio, e, max_results=50)
    args = studio.calls[0][1]
    assert args["assetType"] == "Audio" and args["scope"] == "creator_store" and args["maxResults"] == 20
    assert args["priceFilter"] == "free" and args["query"] == "fire truck siren"
    assert [c["assetId"] for c in cands] == ["317455930", "200252683"]
    assert "BeFUZZled" in cands[0]["license"] and "audio privacy" in cands[0]["license"]
    assert e["status"] == "candidates"

    A.pick(e, 2)
    assert e["assetId"] == "200252683" and e["creator"] == "Someone" and e["status"] == "done"
    assert A.asset_id_keys(e) == {"SfxSiren": "rbxassetid://200252683"}
    with pytest.raises(A.AssetError):
        A.pick(e, 9)
    A.pick(e, asset_id="42")
    assert e["contentId"] == "rbxassetid://42"


# ---------------------------------------------------------------- upload (mocked Open Cloud)

ENV = {"ROBLOX_API_KEY": "k", "ROBLOX_CREATOR_USER_ID": "2757580371"}


def test_upload_multipart_and_poll(tmp_path):
    (tmp_path / "images").mkdir()
    (tmp_path / "images" / "fire_icon.png").write_bytes(b"\x89PNGfake")
    seen = []

    def http(method, url, headers, body):
        seen.append((method, url, headers, body))
        if method == "POST":
            return 200, json.dumps({"path": "operations/op-9", "done": False}).encode()
        if len(seen) == 2:
            return 200, json.dumps({"path": "operations/op-9", "done": False}).encode()
        return 200, json.dumps({"path": "operations/op-9", "done": True,
                                "response": {"assetId": "987", "assetType": "Decal"}}).encode()

    e = entry(id="IconFire", kind="decal", source="upload", file="images/fire_icon.png", notes="HUD icon")
    A.upload_entry(e, tmp_path, env=ENV, http=http, sleep=lambda _: None)

    method, url, headers, body = seen[0]
    assert (method, url) == ("POST", "https://apis.roblox.com/assets/v1/assets")
    assert headers["x-api-key"] == "k" and headers["Content-Type"].startswith("multipart/form-data; boundary=")
    assert b'name="request"' in body and b'name="fileContent"; filename="fire_icon.png"' in body
    assert b"Content-Type: image/png" in body and b"\x89PNGfake" in body
    req = json.loads(body.split(b'name="request"\r\n\r\n')[1].split(b"\r\n")[0])
    assert req == {"assetType": "Decal", "displayName": "IconFire", "description": "HUD icon",
                   "creationContext": {"creator": {"userId": "2757580371"}}}
    assert seen[1][:2] == ("GET", "https://apis.roblox.com/assets/v1/operations/op-9")
    assert seen[1][2] == {"x-api-key": "k"}
    assert e["status"] == "done" and e["assetId"] == "987" and e["contentId"] == "rbxassetid://987"


def test_upload_group_creator_audio_and_errors(tmp_path):
    (tmp_path / "s.mp3").write_bytes(b"ID3")
    calls = []

    def http(method, url, headers, body):
        calls.append(body)
        return 200, json.dumps({"done": True, "response": {"assetId": 5}}).encode()

    e = entry(id="Snd", kind="audio", source="upload", file="s.mp3")
    A.upload_entry(e, tmp_path, env={"ROBLOX_API_KEY": "k", "ROBLOX_CREATOR_GROUP_ID": "77",
                                     "ROBLOX_CREATOR_USER_ID": "1"}, http=http)
    assert b'"groupId": "77"' in calls[0] and b'"assetType": "Audio"' in calls[0] and b"audio/mpeg" in calls[0]
    assert e["assetId"] == "5" and len(calls) == 1  # done immediately, no poll

    with pytest.raises(A.AssetError, match="ROBLOX_API_KEY"):
        A.upload_entry(entry(file="s.mp3"), tmp_path, env={}, http=http)
    with pytest.raises(A.AssetError, match="CREATOR"):
        A.upload_entry(entry(kind="audio", file="s.mp3"), tmp_path, env={"ROBLOX_API_KEY": "k"}, http=http)
    with pytest.raises(A.AssetError, match="not found"):
        A.upload_entry(entry(kind="audio", file="nope.mp3"), tmp_path, env=ENV, http=http)
    with pytest.raises(A.AssetError, match="HTTP 401"):
        A.upload_entry(entry(kind="audio", file="s.mp3"), tmp_path, env=ENV,
                       http=lambda *a: (401, b'{"message":"Invalid API Key"}'))
    with pytest.raises(A.AssetError, match="upload failed"):
        A.upload_entry(entry(kind="audio", file="s.mp3"), tmp_path, env=ENV,
                       http=lambda *a: (200, b'{"done": true, "error": {"code": 3, "message": "moderated"}}'))


# ---------------------------------------------------------------- CLI


def test_cli_parses_assets_subcommands():
    p = build_parser()
    a = p.parse_args(["assets", "generate", "PetPanda", "--keep", "--studio", "Fire"])
    assert (a.cmd, a.assets_cmd, a.ids, a.keep, a.studio) == ("assets", "generate", ["PetPanda"], True, "Fire")
    a = p.parse_args(["assets", "search", "SfxSiren", "--pick", "2"])
    assert (a.id, a.pick) == ("SfxSiren", 2)
    assert p.parse_args(["assets", "sync", "--check"]).check is True


def test_cli_sync_list_and_pick(tmp_path, capsys):
    man = tmp_path / "manifest.json"
    out = tmp_path / "AssetIds.luau"
    data = {"version": 1, "assets": [entry(id="SfxSiren", kind="audio", source="marketplace", status="candidates",
                                           candidates=[{"assetId": "317455930", "creator": "BeFUZZled",
                                                        "license": "free"}])]}
    man.write_text(json.dumps(data))
    ns = lambda **kw: argparse.Namespace(**kw)
    assert A.cmd_assets(ns(assets_cmd="sync", check=True), man, out) == 1
    assert A.cmd_assets(ns(assets_cmd="sync", check=False), man, out) == 0
    assert 'SfxSiren = ""' in out.read_text()
    assert A.cmd_assets(ns(assets_cmd="search", id="SfxSiren", pick=1, pick_id=None, query=None, max=5,
                           studio=None), man, out) == 0
    assert 'SfxSiren = "rbxassetid://317455930"' in out.read_text()
    assert json.loads(man.read_text())["assets"][0]["status"] == "done"
    assert A.cmd_assets(ns(assets_cmd="list", status="done", kind=None), man, out) == 0
    assert "SfxSiren" in capsys.readouterr().out
    assert A.cmd_assets(ns(assets_cmd="upload", ids=["SfxSiren"], all=False, dry_run=True), man, out) == 0
