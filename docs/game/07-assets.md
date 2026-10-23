# 07 — Custom assets pipeline

How Flame and Blame gets meshes, textures, icons and sounds that code can't build, and how their
ids end up in the repo so a fresh place still works. No LLM calls are involved (generation is
Roblox's own tooling, not ours), so nothing here touches Mubit.

```
assets/manifest.json ──► forge assets generate  (Studio MCP generate_mesh / generate_material /
        ▲                                           generate_procedural_model, async + wait_job_finished)
        │                forge assets search    (Studio MCP search_asset, Creator Store, free)
        │                forge assets upload    (Open Cloud Assets API, assets/<file>)
        └── ids ◄────────┘
                         forge assets sync  ──► game/ReplicatedStorage/Config/AssetIds.luau
```

## Manifest (`assets/manifest.json`, committed)

One entry per asset. `id` is a Luau identifier and becomes the `AssetIds` key.

| Field | Meaning |
|---|---|
| `kind` | `mesh` · `texture` · `decal` · `audio` · `model` |
| `source` | `generate` (Studio MCP) · `marketplace` (search_asset) · `upload` / `file` (Open Cloud from `assets/<file>`) |
| `prompt` / `params` | generation prompt; `params.size [x,y,z]`, `maxTriangles`, `segmentation`, `partNames`, `texturePrompt` (re-texture after generating with `generate_texture`); `params.tool = "material"` + `baseMaterial`/`materialPattern` for MaterialVariants; `params.tool = "procedural"` for `model` |
| `query` | Creator Store search terms |
| `file` | path under `assets/` for uploads (e.g. `images/fire_icon.png`) |
| `assetId` | the Roblox asset id (published generation, picked store asset, or uploaded asset) |
| `contentId` | the id game code should use when it isn't `rbxassetid://<assetId>` (a mesh's `MeshId`, a material's `ColorMap`) |
| `extra` | more content ids, emitted as `X_<Key>`: meshes get `Texture` (TextureID) and `Model` (published model) |
| `status` | `todo` · `candidates` (search ran, nothing picked) · `done` · `failed` · `skip` |
| `candidates`, `creator`, `license` | search results and the chosen one's creator / licence note |
| `generation`, `uploaded`, `notes`, `error` | provenance and history |

The seed has 28 entries taken from `02-art-feel-ui.md` §5–§13: helmet, googly eyes, glove, nozzle,
axe, body shell, three pets, truck light bar / ladder / hose reel, the procedural fire truck, charred
wood and station brick materials, fire and smoke flipbooks, four HUD icons, and seven sounds/music.

## Commands

```bash
.venv/bin/forge assets list [--status todo] [--kind mesh]
.venv/bin/forge assets generate PetPanda FireAxe --studio Firefighter   # spends generation quota
.venv/bin/forge assets generate --all --dry-run                          # what --all would spend
.venv/bin/forge assets search SfxSiren [--query "siren loop"] [--max 10]
.venv/bin/forge assets search SfxSiren --pick 2        # accept candidate 2 (or --pick-id 123)
.venv/bin/forge assets upload IconFire                 # needs ROBLOX_API_KEY + creator env
.venv/bin/forge assets sync [--check]                  # write / verify AssetIds.luau
```

`generate`, `upload` and `search --pick` re-write `AssetIds.luau` themselves. The manifest is saved
after every generation, so if a batch dies halfway you keep the ids you already paid for.
`generate` refuses to run during a playtest, because it needs the Edit DataModel.

## Game code contract

```lua
local AssetIds = require(ReplicatedStorage.Config.AssetIds)
if AssetIds.FirefighterHelmet ~= "" then
    -- MeshPart: AssetService:CreateMeshPartAsync(AssetIds.FirefighterHelmet), TextureID = AssetIds.FirefighterHelmet_Texture
else
    -- part-built helmet from 02 §5 (always works)
end
Sfx.register("Siren", AssetIds.SfxSiren ~= "" and AssetIds.SfxSiren or "rbxasset://sounds/electronicpingshort.wav")
```

Every key always exists (`""` until the asset is `done`), so `--!strict` code can index it. Like the
other configs, it uses `Config.define`, so you can try a different id live:
`DevHook:Invoke("AssetIds", ".Set", "SfxSiren", "rbxassetid://...")`.

## Persistence: what's actually kept, and the limits

- **Studio can't save files from Luau.** No `.rbxm` export is possible over MCP, and `place/*.rbxlx`
  is gitignored. A generated mesh is therefore kept **as ids, not geometry**.
- **Generated meshes are published assets.** In the 2026-10-23 trial ("cartoon red fire helmet with
  gold badge, low poly", 4,000 tris, segmentation none), `wait_job_finished` returned
  `{generationId, publishedAssetId: 113550565774556, tag: "Assistant-…"}`. The inserted Model carried
  attributes `RBX_AI_GENERATED`, `RBX_AI_GENERATION_ID` and the `Assistant-…` CollectionService tag, and
  had one MeshPart `body_geom` with `MeshId rbxassetid://120869843818437` and `TextureID
  rbxassetid://125367091703714` (size 2.71×2.0×3.04). Those ids are recorded under
  `FirefighterHelmet`, and the Studio copy was deleted. `forge assets generate` does the same thing:
  it finds the instance by `RBX_AI_GENERATION_ID` (falling back to the tag), renames it `Forge_<id>`,
  records the largest MeshPart's MeshId/TextureID plus `publishedAssetId`, then deletes it (pass `--keep` to leave it).
- **Not verified yet:** whether the MeshId/TextureID load at runtime in a live server. Expect yes for
  the place owner's experiences, because the generation was published under the Studio user (user
  2757580371 owns the Firefighter Mubit place). `AssetService:CreateMeshPartAsync(meshId)` or
  `InsertService:LoadAsset(publishedAssetId)` only work for assets the experience owner can use.
  **Test one in a playtest before relying on it.** If it fails, the code-built fallback still runs.
- **Multi-part meshes** (`segmentation` auto/explicit) record every MeshPart under
  `generation.meshParts`. Only the largest becomes `X`/`X_Texture`. For the rest, read
  `generation.meshParts` or use `X_Model` with `InsertService`.
- **MaterialVariants** (`generate_material`) live in the place's `MaterialService`. We record their
  ColorMap/NormalMap ids, but a variant only exists in the place where it was generated or saved.
  Re-creating one at runtime from ids is not verified (its map properties may be Studio/plugin-only),
  so keep the place saved, or treat a missing variant as "use the base material".
- **Procedural models** (`generate_procedural_model`, 50/day) are made of Parts. If the job doesn't
  return a `publishedAssetId`, nothing can be persisted: the entry is marked `failed`, the model is
  left in Studio, and you have to save it as a package by hand.
- **Flipbooks** can't be generated: `generate_texture` only re-textures an existing mesh. They come
  from the Creator Store (`search`) or a drawn PNG (`upload`). Until then, the fallback is the built-in
  `rbxasset://textures/particles/*.dds`.
- **Quota:** procedural models are capped at 50 per 24 h, and `generate_mesh` is rate-limited per
  minute. `--all` only covers `todo` entries, so run `--dry-run` first.

## Creator Store search and licences

`search` uses `scope=creator_store` and `priceFilter=free`. It records each candidate's `assetId`,
name, `creatorName`, price and store URL, plus a licence note. Creator Store assets have no separate
licence: you use them under the Roblox Terms of Use. **Audio** from third parties is often blocked by
audio privacy outside the owner's experiences, so test-play before `--pick`. Prefer Roblox-uploaded
or licensed-library tracks, or upload our own. Strip any `Script`s from models you insert (02 §13).

## Open Cloud upload

This was checked against create.roblox.com/docs/cloud/guides/usage-assets and the Assets API
reference on 2026-10-23.

- `POST https://apis.roblox.com/assets/v1/assets` with `x-api-key: $ROBLOX_API_KEY`, sent as
  `multipart/form-data` with two fields:
  - `request`: JSON `{assetType, displayName, description (≤1000), creationContext: {creator: {userId | groupId}}}`
  - `fileContent`: the file, with its content type
- Types: Decal (`png/jpeg/bmp/tga`), Audio (`mp3/ogg/wav/flac`), Model (`fbx/gltf/glb/rbxm`).
- The response is an Operation `{path: "operations/{id}", done, error?, response?}`. Poll
  `GET https://apis.roblox.com/assets/v1/operations/{id}` until `done` is true, then read `response.assetId`.
- The key needs the `asset:read` and `asset:write` scopes. Rate limits are 120 creates per minute and
  300 operation reads per minute.
- Env vars: `ROBLOX_API_KEY`, and `ROBLOX_CREATOR_GROUP_ID` (used if set) or `ROBLOX_CREATOR_USER_ID`.
  They're read from `.env`.
- **Caveat:** for a Decal upload, check that the returned id renders in an `ImageLabel`. If it shows
  blank, it's the decal wrapper and not the image. In that case, insert it in Studio, copy the
  `Decal.Texture` id into `contentId`, and run `forge assets sync`.
- The Studio MCP `upload_image` tool is an alternative for images. It takes http(s) URLs, not local
  paths, and it isn't wired into the CLI.

Tests: `tests/test_assets.py` (fake Studio, mocked HTTP; no quota or network).
