"""Custom assets pipeline: assets/manifest.json -> Studio MCP generation / Creator Store search /
Open Cloud upload -> game/ReplicatedStorage/Config/AssetIds.luau.

  forge assets list     [--status S] [--kind K]
  forge assets generate <id...> | --all   [--keep] [--dry-run] [--studio NAME]
  forge assets search   <id> [--query Q] [--max N] [--pick N | --pick-id ASSETID]
  forge assets upload   <id...> | --all   [--dry-run]
  forge assets sync     [--check]

No LLM calls happen here. Generation spends Roblox quota (generate_mesh, generate_material,
generate_procedural_model), so it only runs for ids you name (or --all over status "todo").

Persistence: Studio can't write files from Luau, so a generated mesh is kept as its content ids
(MeshId/TextureID of the generated MeshPart, plus the publishedAssetId the job returns). Those ids
live in the manifest and AssetIds.luau; the Studio copy is deleted unless --keep. docs/game/07-assets.md.
"""

from __future__ import annotations

import json
import mimetypes
import os
import re
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Callable

from forge.config import REPO_ROOT

MANIFEST = REPO_ROOT / "assets" / "manifest.json"
ASSET_IDS_LUAU = REPO_ROOT / "game" / "ReplicatedStorage" / "Config" / "AssetIds.luau"

KINDS = ("mesh", "texture", "decal", "audio", "model")
SOURCES = ("generate", "upload", "marketplace", "file")
STATUSES = ("todo", "candidates", "done", "failed", "skip")
ID_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

# Extra AssetIds keys always emitted per kind (X_<suffix>), so --!strict game code can index them.
EXTRA_KEYS: dict[str, tuple[str, ...]] = {"mesh": ("Texture", "Model"), "texture": ("Normal",)}

# search_asset assetType per manifest kind.
SEARCH_TYPES = {"audio": "Audio", "texture": "Image", "decal": "Image", "mesh": "MeshPart", "model": "Model"}

# Open Cloud Assets API (create.roblox.com/docs/cloud/guides/usage-assets, checked 2026-10-23).
OPEN_CLOUD = "https://apis.roblox.com/assets/v1"
UPLOAD_TYPES = {"texture": "Decal", "decal": "Decal", "audio": "Audio", "model": "Model", "mesh": "Model"}
UPLOAD_MIME = {
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".bmp": "image/bmp", ".tga": "image/tga",
    ".mp3": "audio/mpeg", ".ogg": "audio/ogg", ".wav": "audio/wav", ".flac": "audio/flac",
    ".fbx": "model/fbx", ".gltf": "model/gltf+json", ".glb": "model/gltf-binary",
    ".rbxm": "model/x-rbxm", ".rbxmx": "model/x-rbxm",
}

GENERATE_CLIENT_TIMEOUT = 660.0  # wait_job_finished waits up to 600 s server-side
SYNC_GENERATE_TIMEOUT = 600.0


class AssetError(RuntimeError):
    pass


# --------------------------------------------------------------------------- manifest


def rbx(asset_id: Any) -> str:
    """'123' / 123 / 'rbxassetid://123' -> 'rbxassetid://123'; falsy -> ''."""
    if asset_id in (None, "", 0):
        return ""
    s = str(asset_id).strip()
    if s.startswith(("rbxassetid://", "rbxasset://", "rbxthumb://", "http")):
        return s
    if s.isdigit():
        return f"rbxassetid://{s}"
    raise AssetError(f"not an asset id: {asset_id!r}")


def load_manifest(path: Path = MANIFEST) -> dict:
    data = json.loads(Path(path).read_text())
    validate(data)
    return data


def save_manifest(data: dict, path: Path = MANIFEST) -> None:
    validate(data)
    Path(path).write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def validate(data: dict) -> None:
    seen: set[str] = set()
    for e in data.get("assets", []):
        aid = e.get("id", "")
        if not ID_RE.match(aid):
            raise AssetError(f"asset id {aid!r} must be a Luau identifier")
        if aid in seen:
            raise AssetError(f"duplicate asset id {aid!r}")
        seen.add(aid)
        if e.get("kind") not in KINDS:
            raise AssetError(f"{aid}: kind must be one of {KINDS}")
        if e.get("source") not in SOURCES:
            raise AssetError(f"{aid}: source must be one of {SOURCES}")
        if e.get("status", "todo") not in STATUSES:
            raise AssetError(f"{aid}: status must be one of {STATUSES}")


def find(data: dict, aid: str) -> dict:
    for e in data["assets"]:
        if e["id"] == aid:
            return e
    raise AssetError(f"no asset {aid!r} in manifest (forge assets list)")


def select(data: dict, ids: list[str], all_: bool, source: tuple[str, ...]) -> list[dict]:
    if ids:
        return [find(data, i) for i in ids]
    if all_:
        return [e for e in data["assets"] if e["source"] in source and e.get("status", "todo") == "todo"]
    raise AssetError("name asset ids or pass --all")


# --------------------------------------------------------------------------- AssetIds.luau


def asset_id_keys(e: dict) -> dict[str, str]:
    """AssetIds entries for one manifest entry: X plus X_<extra>; '' when missing."""
    extra = dict(e.get("extra") or {})
    primary = e.get("contentId") or (rbx(e.get("assetId")) if e.get("status") == "done" else "")
    out = {e["id"]: primary if e.get("status") == "done" else ""}
    for k in sorted(set(EXTRA_KEYS.get(e["kind"], ())) | set(extra)):
        out[f"{e['id']}_{k}"] = rbx(extra.get(k)) if e.get("status") == "done" else ""
    return out


def render_asset_ids(data: dict) -> str:
    lines = [
        "--!strict",
        "-- GENERATED by `forge assets sync` from assets/manifest.json. Do not edit by hand.",
        '-- AssetIds.X is "rbxassetid://..." or "" when the asset isn\'t ready; game code must fall back to',
        "-- part-built visuals / built-in rbxasset:// sounds when it is \"\". Meshes also have X_Texture (TextureID)",
        "-- and X_Model (published model asset, for InsertService:LoadAsset). docs/game/07-assets.md.",
        'local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)',
        "",
        "return Config.define({",
    ]
    for e in sorted(data["assets"], key=lambda x: (x["kind"], x["id"])):
        for k, v in asset_id_keys(e).items():
            lines.append(f"\t{k} = {json.dumps(v)}, -- {e['kind']}/{e['source']}/{e.get('status', 'todo')}")
    lines.append("})")
    return "\n".join(lines) + "\n"


def sync_ids(data: dict, out: Path = ASSET_IDS_LUAU, check: bool = False) -> bool:
    """Write AssetIds.luau. Returns True if the file changed (or would change with check=True)."""
    text = render_asset_ids(data)
    out = Path(out)
    current = out.read_text() if out.exists() else None
    if current == text:
        return False
    if not check:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
    return True


# --------------------------------------------------------------------------- Studio MCP helpers


def _result_json(result: Any) -> dict:
    """Merge structured content and JSON text of an MCP CallToolResult into one dict."""
    from forge.studio import content_text, extract_json

    out: dict = {}
    sc = getattr(result, "structured_content", None) or getattr(result, "structuredContent", None)
    if isinstance(sc, dict):
        out.update(sc)
    obj = extract_json(content_text(getattr(result, "content", None)))
    if isinstance(obj, dict):
        for k, v in obj.items():
            out.setdefault(k, v)
    return out


def _dig(obj: Any, key: str) -> Any:
    """First value for `key` anywhere in nested dicts/lists (e.g. publishedAssetId under jobResult)."""
    if isinstance(obj, dict):
        if obj.get(key) not in (None, ""):
            return obj[key]
        for v in obj.values():
            found = _dig(v, key)
            if found not in (None, ""):
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = _dig(v, key)
            if found not in (None, ""):
                return found
    elif isinstance(obj, str) and key in obj:
        from forge.studio import extract_json

        inner = extract_json(obj)
        return _dig(inner, key) if isinstance(inner, (dict, list)) else None
    return None


async def _call(studio: Any, tool: str, timeout: float, **args: Any) -> dict:
    return _result_json(await studio.call_result(tool, timeout=timeout, **args))


async def run_job(studio: Any, tool: str, **args: Any) -> dict:
    """Start a generation tool with async=True and wait_job_finished. Returns the final job JSON."""
    start = await _call(studio, tool, 120.0, **{**args, "async": True})
    job_id = _dig(start, "jobId")
    if not job_id:  # tool finished synchronously
        return start
    final = await _call(studio, "wait_job_finished", GENERATE_CLIENT_TIMEOUT, jobId=str(job_id))
    status = str(final.get("status", "")).lower()
    if status and status not in ("completed", "succeeded", "success"):
        raise AssetError(f"{tool} job {job_id} {final.get('status')}: {json.dumps(final)[:400]}")
    if _dig(final, "isError") is True:
        raise AssetError(f"{tool} job {job_id} failed: {json.dumps(final)[:400]}")
    return final


def _luau_str(s: str) -> str:
    return json.dumps(s)  # JSON string literal is a valid Luau string literal for our inputs


def find_generated_luau(generation_id: str, tag: str | None, rename: str) -> str:
    """Luau: locate the instance a generation inserted (attribute RBX_AI_GENERATION_ID, else the
    Assistant tag), rename it, and report every MeshPart's ids as JSON."""
    return f"""
local HttpService = game:GetService("HttpService")
local CS = game:GetService("CollectionService")
local gid, tag = {_luau_str(generation_id)}, {_luau_str(tag or "")}
local root
for _, d in workspace:GetDescendants() do
	if d:GetAttribute("RBX_AI_GENERATION_ID") == gid then root = d break end
end
if not root and tag ~= "" then root = CS:GetTagged(tag)[1] end
if not root then return HttpService:JSONEncode({{found = false}}) end
root.Name = {_luau_str(rename)}
local parts = {{}}
local list = root:GetDescendants()
table.insert(list, root)
for _, d in list do
	if d:IsA("MeshPart") then
		local sa = d:FindFirstChildOfClass("SurfaceAppearance")
		table.insert(parts, {{name = d.Name, meshId = d.MeshId, textureId = d.TextureID,
			colorMap = sa and sa.ColorMap or "", size = {{d.Size.X, d.Size.Y, d.Size.Z}}}})
	end
end
return HttpService:JSONEncode({{found = true, path = root:GetFullName(), class = root.ClassName, parts = parts}})
"""


def destroy_luau(path: str) -> str:
    return f"""
local inst = game
for seg in string.gmatch({_luau_str(path)}, "[^%.]+") do
	if seg ~= "game" then inst = inst and inst:FindFirstChild(seg) end
end
if inst and inst ~= game and inst ~= workspace then inst:Destroy() return "destroyed" end
return "missing"
"""


def material_luau(name: str) -> str:
    return f"""
local HttpService = game:GetService("HttpService")
local mv = game:GetService("MaterialService"):FindFirstChild({_luau_str(name)}, true)
if not mv then return HttpService:JSONEncode({{found = false}}) end
return HttpService:JSONEncode({{found = true, name = mv.Name, baseMaterial = mv.BaseMaterial.Name,
	colorMap = mv.ColorMap, normalMap = mv.NormalMap, roughnessMap = mv.RoughnessMap, metalnessMap = mv.MetalnessMap}})
"""


def _main_part(parts: list[dict]) -> dict:
    def vol(p: dict) -> float:
        s = p.get("size") or [0, 0, 0]
        return float(s[0]) * float(s[1]) * float(s[2])

    return max(parts, key=vol)


async def _ensure_edit(studio: Any) -> None:
    st = await studio.state()
    if st.get("playing"):
        raise AssetError("Studio is playtesting; stop the playtest first (generation inserts into the Edit DataModel)")


async def generate_entry(studio: Any, e: dict, keep: bool = False, log: Callable[[str], None] = print) -> dict:
    """Run one generation for a manifest entry and record its ids in place. Returns the entry."""
    from forge.studio import extract_json

    p = dict(e.get("params") or {})
    tool = p.pop("tool", None)
    today = time.strftime("%Y-%m-%d")

    if e["kind"] == "texture" and tool == "material":
        res = await _call(studio, "generate_material", SYNC_GENERATE_TIMEOUT,
                          materialId=e["id"], baseMaterial=p.get("baseMaterial", "Plastic"),
                          materialPattern=p.get("materialPattern", "Regular"), materialDescription=e["prompt"])
        name = _dig(res, "Name") or _dig(res, "name") or e["id"]
        info = extract_json(await studio.execute_luau(material_luau(str(name)))) or {}
        if not info.get("found"):
            raise AssetError(f"{e['id']}: generate_material returned {json.dumps(res)[:300]} but no MaterialVariant "
                             f"{name!r} in MaterialService")
        e["contentId"] = info.get("colorMap") or ""
        e["extra"] = {k: v for k, v in {"Normal": info.get("normalMap"), "Roughness": info.get("roughnessMap"),
                                        "Metalness": info.get("metalnessMap")}.items() if v}
        e["generation"] = {"tool": "generate_material", "date": today, "variant": info.get("name"),
                           "baseMaterial": info.get("baseMaterial")}
        e["status"] = "done"
        log(f"  {e['id']}: MaterialVariant {info.get('name')} colorMap={e['contentId'] or '-'} (kept in MaterialService)")
        return e

    if e["kind"] == "mesh":
        args: dict = {"textPrompt": e["prompt"]}
        if "maxTriangles" in p:
            args["maxTriangles"] = p["maxTriangles"]
        if "size" in p:
            sx, sy, sz = p["size"]
            args["size"] = {"x": sx, "y": sy, "z": sz}
        if p.get("segmentation"):
            args["segmentation"] = p["segmentation"]
        if p.get("partNames"):
            args["partNames"] = p["partNames"]
        tool_name = "generate_mesh"
    elif e["kind"] == "model":
        args = {"prompt": e["prompt"]}
        if p.get("partNames"):
            args["partNames"] = p["partNames"]
        tool_name = "generate_procedural_model"
    else:
        raise AssetError(f"{e['id']}: can't generate kind {e['kind']!r} (texture needs params.tool=material)")

    log(f"  {e['id']}: {tool_name} {e['prompt']!r} ...")
    final = await run_job(studio, tool_name, **args)
    gen_id = _dig(final, "generationId")
    published = _dig(final, "publishedAssetId")
    tag = _dig(final, "tag")
    found = extract_json(await studio.execute_luau(find_generated_luau(str(gen_id or ""), tag, f"Forge_{e['id']}"))) or {}

    parts = found.get("parts") or []
    if p.get("texturePrompt") and found.get("found"):
        await _call(studio, "generate_texture", SYNC_GENERATE_TIMEOUT,
                    textPrompt=p["texturePrompt"], instance_path=found["path"])
        found = extract_json(await studio.execute_luau(
            find_generated_luau(str(gen_id or ""), tag, f"Forge_{e['id']}"))) or found
        parts = found.get("parts") or parts

    e["generation"] = {"tool": tool_name, "id": gen_id, "date": today, "tag": tag,
                       "meshParts": [{k: v for k, v in mp.items() if v not in ("", None)} for mp in parts]}
    if published:
        e["assetId"] = str(published)
    extra = dict(e.get("extra") or {})
    if published:
        extra["Model"] = rbx(published)
    if parts:
        main = _main_part(parts)
        if e["kind"] == "mesh":
            e["contentId"] = main.get("meshId") or ""
        tex = main.get("textureId") or main.get("colorMap")
        if tex:
            extra["Texture"] = tex
    e["extra"] = extra
    persisted = bool(published or (parts and e.get("contentId")))
    e["status"] = "done" if persisted else "failed"
    if not found.get("found"):
        e["notes"] = (e.get("notes", "") + f" [{today}: job finished but the inserted instance wasn't found]").strip()
    log(f"  {e['id']}: asset {published or '-'} mesh {e.get('contentId') or '-'} "
        f"texture {extra.get('Texture', '-')} ({len(parts)} MeshPart(s))")

    if found.get("found") and not keep:
        if persisted:
            await studio.execute_luau(destroy_luau(found["path"]))
            log(f"  {e['id']}: removed {found['path']} from Studio (ids kept in manifest; --keep to leave it)")
        else:
            log(f"  {e['id']}: nothing persistable came back; left {found['path']} in Studio, save it by hand")
    return e


async def search_entry(studio: Any, e: dict, query: str | None = None, max_results: int = 5) -> list[dict]:
    """search_asset (Creator Store, free) for an entry; records candidates with creator/license info."""
    args: dict = {"query": query or e.get("query") or e.get("prompt") or e["id"], "scope": "creator_store",
                  "priceFilter": "free", "maxResults": max(1, min(20, max_results))}
    if e["kind"] in SEARCH_TYPES:
        args["assetType"] = SEARCH_TYPES[e["kind"]]
    res = await _call(studio, "search_asset", 120.0, **args)
    cands = []
    for r in res.get("results") or []:
        aid = str(r.get("assetId") or r.get("id") or "")
        if not aid:
            continue
        cands.append({
            "assetId": aid, "name": r.get("name"), "creator": r.get("creatorName"),
            "creatorId": r.get("creatorId"), "assetType": r.get("assetType"),
            "isFree": r.get("isFree"), "priceCents": r.get("priceCents"),
            "url": r.get("creatorStoreUrl") or f"https://create.roblox.com/store/asset/{aid}",
            "license": license_note(r, e["kind"]),
        })
    e["query"] = args["query"]
    e["candidates"] = cands
    if e.get("status") in (None, "todo", "failed", "candidates"):
        e["status"] = "candidates" if cands else e.get("status", "todo")
    return cands


def license_note(r: dict, kind: str) -> str:
    who = r.get("creatorName") or r.get("creatorId") or "unknown creator"
    if r.get("source") == "inventory":
        return f"owned inventory asset ({who})"
    free = "free" if r.get("isFree", True) else f"paid {r.get('priceCents')}c"
    note = f"Creator Store {free}, by {who}; usable under the Roblox Terms of Use (no separate licence)"
    if kind == "audio":
        note += "; third-party audio may be blocked by audio privacy outside its owner's experiences - test-play it"
    return note


def pick(e: dict, n: int | None = None, asset_id: str | None = None) -> dict:
    cands = e.get("candidates") or []
    if asset_id:
        chosen = next((c for c in cands if c["assetId"] == str(asset_id)), {"assetId": str(asset_id)})
    else:
        if n is None or not 1 <= n <= len(cands):
            raise AssetError(f"{e['id']}: --pick must be 1..{len(cands)}")
        chosen = cands[n - 1]
    e["assetId"] = chosen["assetId"]
    e["contentId"] = rbx(chosen["assetId"])
    e["creator"] = chosen.get("creator")
    e["license"] = chosen.get("license") or "chosen by hand"
    e["status"] = "done"
    return e


# --------------------------------------------------------------------------- Open Cloud upload

HttpFn = Callable[[str, str, dict, bytes | None], tuple[int, bytes]]


def _urllib_http(method: str, url: str, headers: dict, body: bytes | None) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as err:
        return err.code, err.read()


def multipart(fields: dict[str, str], file_field: str, filename: str, content: bytes, mime: str) -> tuple[bytes, str]:
    boundary = f"----forge{uuid.uuid4().hex}"
    out = bytearray()
    for k, v in fields.items():
        out += f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
    out += (f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; filename="{filename}"\r\n'
            f"Content-Type: {mime}\r\n\r\n").encode()
    out += content + f"\r\n--{boundary}--\r\n".encode()
    return bytes(out), f"multipart/form-data; boundary={boundary}"


def creator_from_env(env: dict | None = None) -> dict:
    env = os.environ if env is None else env
    if env.get("ROBLOX_CREATOR_GROUP_ID"):
        return {"groupId": str(env["ROBLOX_CREATOR_GROUP_ID"])}
    if env.get("ROBLOX_CREATOR_USER_ID"):
        return {"userId": str(env["ROBLOX_CREATOR_USER_ID"])}
    raise AssetError("set ROBLOX_CREATOR_USER_ID or ROBLOX_CREATOR_GROUP_ID (asset owner)")


def upload_entry(e: dict, root: Path, *, env: dict | None = None, http: HttpFn = _urllib_http,
                 poll_interval: float = 1.0, max_polls: int = 60, sleep: Callable[[float], None] = time.sleep) -> dict:
    """POST assets/v1/assets (multipart: request JSON + fileContent), then poll the operation."""
    env = os.environ if env is None else env
    key = env.get("ROBLOX_API_KEY")
    if not key:
        raise AssetError("ROBLOX_API_KEY not set (Open Cloud key with asset:read + asset:write)")
    if not e.get("file"):
        raise AssetError(f"{e['id']}: no `file` in manifest entry")
    path = (root / e["file"]).resolve()
    if not path.is_file():
        raise AssetError(f"{e['id']}: file not found: {path}")
    ext = path.suffix.lower()
    mime = UPLOAD_MIME.get(ext) or mimetypes.guess_type(path.name)[0]
    if not mime:
        raise AssetError(f"{e['id']}: unsupported file type {ext}")
    request = {
        "assetType": UPLOAD_TYPES[e["kind"]],
        "displayName": e.get("displayName") or e["id"],
        "description": (e.get("notes") or f"Flame and Blame asset {e['id']}")[:1000],
        "creationContext": {"creator": creator_from_env(env)},
    }
    body, ctype = multipart({"request": json.dumps(request)}, "fileContent", path.name, path.read_bytes(), mime)
    status, raw = http("POST", f"{OPEN_CLOUD}/assets", {"x-api-key": key, "Content-Type": ctype}, body)
    op = _json_or_error(status, raw, "create asset")
    for _ in range(max_polls):
        if op.get("done"):
            break
        op_path = op.get("path") or ""
        op_id = op.get("operationId") or op_path.rsplit("/", 1)[-1]
        if not op_id:
            raise AssetError(f"create asset returned no operation: {op}")
        sleep(poll_interval)
        status, raw = http("GET", f"{OPEN_CLOUD}/operations/{op_id}", {"x-api-key": key}, None)
        op = _json_or_error(status, raw, "get operation")
    else:
        raise AssetError(f"{e['id']}: upload still processing after {max_polls} polls: {op}")
    if op.get("error"):
        raise AssetError(f"{e['id']}: upload failed: {op['error']}")
    asset_id = str((op.get("response") or {}).get("assetId") or "")
    if not asset_id:
        raise AssetError(f"{e['id']}: operation done but no assetId: {op}")
    e["assetId"] = asset_id
    e["contentId"] = rbx(asset_id)
    e["uploaded"] = {"date": time.strftime("%Y-%m-%d"), "assetType": request["assetType"],
                     "creator": request["creationContext"]["creator"]}
    e["status"] = "done"
    return e


def _json_or_error(status: int, raw: bytes, what: str) -> dict:
    try:
        obj = json.loads(raw or b"{}")
    except ValueError:
        obj = {"raw": raw[:300].decode(errors="replace")}
    if status >= 400:
        raise AssetError(f"{what}: HTTP {status}: {json.dumps(obj)[:400]}")
    return obj if isinstance(obj, dict) else {"value": obj}


# --------------------------------------------------------------------------- CLI


def add_cli_parser(sub: Any) -> None:
    a = sub.add_parser("assets", help="custom assets: manifest -> generate/search/upload -> AssetIds.luau")
    asub = a.add_subparsers(dest="assets_cmd", required=True)
    ls = asub.add_parser("list", help="show the manifest")
    ls.add_argument("--status", choices=STATUSES)
    ls.add_argument("--kind", choices=KINDS)
    g = asub.add_parser("generate", help="Studio MCP generate_mesh / generate_material / generate_procedural_model")
    g.add_argument("ids", nargs="*")
    g.add_argument("--all", action="store_true", help="every source=generate entry with status todo")
    g.add_argument("--keep", action="store_true", help="leave the generated instance in Studio")
    g.add_argument("--dry-run", action="store_true")
    g.add_argument("--studio", help="pick the Studio whose name contains this")
    s = asub.add_parser("search", help="Creator Store search_asset (free) -> candidates; --pick to accept one")
    s.add_argument("id")
    s.add_argument("--query")
    s.add_argument("--max", type=int, default=5)
    s.add_argument("--pick", type=int, help="accept candidate N (1-based) without searching again")
    s.add_argument("--pick-id", help="accept this asset id")
    s.add_argument("--studio")
    u = asub.add_parser("upload", help="Open Cloud upload of assets/<file> (ROBLOX_API_KEY + creator env)")
    u.add_argument("ids", nargs="*")
    u.add_argument("--all", action="store_true", help="every source=upload/file entry with status todo")
    u.add_argument("--dry-run", action="store_true")
    y = asub.add_parser("sync", help="write game/ReplicatedStorage/Config/AssetIds.luau from the manifest")
    y.add_argument("--check", action="store_true", help="exit 1 if AssetIds.luau is stale")


def cmd_assets(args: Any, manifest: Path = MANIFEST, out: Path = ASSET_IDS_LUAU) -> int:
    import asyncio

    data = load_manifest(manifest)
    c = args.assets_cmd
    try:
        if c == "list":
            rows = [e for e in data["assets"] if (not args.status or e.get("status") == args.status)
                    and (not args.kind or e["kind"] == args.kind)]
            print(f"{'id':<20} {'kind':<8} {'source':<12} {'status':<11} asset / what")
            for e in rows:
                what = e.get("contentId") or rbx(e.get("assetId")) or e.get("prompt") or e.get("query") or e.get("file") or ""
                print(f"{e['id']:<20} {e['kind']:<8} {e['source']:<12} {e.get('status', 'todo'):<11} {str(what)[:60]}")
            print(f"\n{len(rows)} of {len(data['assets'])} assets")
            return 0
        if c == "sync":
            changed = sync_ids(data, out, check=args.check)
            rel = _rel(out)
            if args.check:
                print(f"{rel} is {'STALE (run forge assets sync)' if changed else 'up to date'}")
                return 1 if changed else 0
            print(f"{'wrote' if changed else 'unchanged'} {rel}")
            return 0
        if c == "upload":
            todo = select(data, args.ids, args.all, ("upload", "file"))
            from forge.config import load_settings

            load_settings()  # loads .env (ROBLOX_API_KEY, ROBLOX_CREATOR_*)
            root = Path(manifest).parent
            failed = 0
            for e in todo:
                if args.dry_run:
                    print(f"  would upload {e['id']}: {root / e.get('file', '?')} as {UPLOAD_TYPES[e['kind']]}")
                    continue
                try:
                    upload_entry(e, root)
                    print(f"  {e['id']}: uploaded -> {e['contentId']}")
                except AssetError as err:
                    failed += 1
                    print(f"  {e['id']}: {err}", file=sys.stderr)
                save_manifest(data, manifest)
            return _finish(data, manifest, out, args.dry_run, failed)
        if c == "generate":
            todo = select(data, args.ids, args.all, ("generate",))
            if args.dry_run:
                for e in todo:
                    print(f"  would generate {e['id']} ({e['kind']}): {e.get('prompt')!r} {e.get('params') or ''}")
                return 0
            failed = asyncio.run(_generate_all(data, todo, manifest, args.keep, args.studio))
            return _finish(data, manifest, out, False, failed)
        if c == "search":
            e = find(data, args.id)
            if args.pick is not None or args.pick_id:
                pick(e, args.pick, args.pick_id)
                print(f"  {e['id']}: picked {e['assetId']} by {e.get('creator') or '?'}")
            else:
                cands = asyncio.run(_search(e, args.query, args.max, args.studio))
                for i, cnd in enumerate(cands, 1):
                    print(f"  {i}. {cnd['assetId']:<16} {str(cnd['name'])[:40]:<40} by {cnd['creator']}  {cnd['url']}")
                if cands:
                    print(f"\n  accept one: forge assets search {e['id']} --pick N")
            save_manifest(data, manifest)
            return _finish(data, manifest, out, False, 0)
    except AssetError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1
    return 2


def _finish(data: dict, manifest: Path, out: Path, dry: bool, failed: int) -> int:
    if not dry:
        save_manifest(data, manifest)
        if sync_ids(data, out):
            print(f"  updated {_rel(out)}")
    return 1 if failed else 0


def _rel(p: Path) -> str:
    try:
        return str(Path(p).resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(p)


async def _generate_all(data: dict, todo: list[dict], manifest: Path, keep: bool, studio_name: str | None) -> int:
    from forge.studio import Studio

    failed = 0
    async with Studio(call_timeout=GENERATE_CLIENT_TIMEOUT) as studio:
        await studio.select(studio_name)
        await _ensure_edit(studio)
        for e in todo:
            try:
                await generate_entry(studio, e, keep=keep)
            except Exception as err:  # keep going; record the failure
                failed += 1
                e["status"] = "failed"
                e["error"] = f"{type(err).__name__}: {err}"[:400]
                print(f"  {e['id']}: FAILED {e['error']}", file=sys.stderr)
            save_manifest(data, manifest)  # after every job: quota is spent, don't lose ids
    return failed


async def _search(e: dict, query: str | None, max_results: int, studio_name: str | None) -> list[dict]:
    from forge.studio import Studio

    async with Studio() as studio:
        await studio.select(studio_name)
        return await search_entry(studio, e, query, max_results)
