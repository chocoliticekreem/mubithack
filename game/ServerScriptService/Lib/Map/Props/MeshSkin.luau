--!strict
-- MeshSkin [owner: Assets/visuals lane]. Puts a generated mesh (Config/AssetIds) over part-built
-- geometry as a non-colliding, massless MeshPart, fitted by Config/VisualConfig.Meshes[key].
-- Pure (spec-tested in game/tests/mesh_skin.spec.luau, no Roblox APIs):
--   MeshSkin.resolve(key, ids, cfg) -> Spec?      nil = keep the part-built look (fallback)
--   MeshSkin.place(spec, side?) -> (offset {x,y,z}, rot {x,y,z} degrees) for side "L" | "R" | nil
--   MeshSkin.matches(name, prefixes) -> boolean    prefix match (VisualConfig.Truck.Hide)
-- Roblox (server; yields the first time per mesh, then clones a cached template):
--   MeshSkin.spec(key) -> Spec?                    resolve() against the live AssetIds / VisualConfig
--   MeshSkin.make(spec, name, cf, side?) -> MeshPart?  cf = the frame offset/rot are relative to;
--     anchored, CanCollide/CanQuery/CanTouch false, Massless, RenderFidelity from VisualConfig.
--     Not parented. nil when the mesh can't load (the caller keeps its parts).
--   MeshSkin.hide(parts)                           Transparency 1 + SurfaceGuis/Decals off; still collide
-- Nothing runs at require time.

local MeshSkin = {}

export type Vec = { number }
export type Spec = {
	key: string,
	meshId: string,
	textureId: string,
	size: Vec,
	offset: Vec,
	rot: Vec,
	mirrorL: boolean,
	sided: boolean,
}

local ZERO = { 0, 0, 0 }

local function vec(v: any, default: Vec): Vec
	if type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" and type(v[3]) == "number" then
		return { v[1], v[2], v[3] }
	end
	return { default[1], default[2], default[3] }
end

-- The fitted mesh for `key`, or nil when the part-built look should stay.
function MeshSkin.resolve(key: string, ids: any, cfg: any): Spec?
	if type(cfg) ~= "table" or cfg.UseHeroMeshes ~= true then
		return nil
	end
	local entry = type(cfg.Meshes) == "table" and cfg.Meshes[key] or nil
	if type(entry) ~= "table" or entry.enabled == false then
		return nil
	end
	local id = type(ids) == "table" and ids[key] or nil
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local size = vec(entry.size, ZERO)
	if size[1] <= 0 or size[2] <= 0 or size[3] <= 0 then
		return nil
	end
	local tex = ids[`{key}_Texture`]
	return {
		key = key,
		meshId = id,
		textureId = if type(tex) == "string" then tex else "",
		size = size,
		offset = vec(entry.offset, ZERO),
		rot = vec(entry.rot, ZERO),
		mirrorL = entry.mirrorL == true,
		sided = entry.sided == true,
	}
end

-- Offset and rotation for one side: sided specs mirror offset.x on the left, mirrorL specs turn 180
-- degrees about Y on the left (the outer face of a one-sided mesh then faces -X).
function MeshSkin.place(spec: Spec, side: string?): (Vec, Vec)
	local o = { spec.offset[1], spec.offset[2], spec.offset[3] }
	local r = { spec.rot[1], spec.rot[2], spec.rot[3] }
	if side == "L" then
		if spec.sided then
			o[1] = -o[1]
		end
		if spec.mirrorL then
			r[2] = (r[2] + 180 + 180) % 360 - 180
		end
	end
	return o, r
end

function MeshSkin.matches(name: string, prefixes: { string }?): boolean
	for _, p in prefixes or {} do
		if string.sub(name, 1, #p) == p then
			return true
		end
	end
	return false
end

-- Roblox side ------------------------------------------------------------------------------------

local templates: { [string]: any } = {} -- meshId -> MeshPart template | false (failed)
local failedAt: { [string]: number } = {}
local RETRY_SECONDS = 60

local function configs(): (any, any)
	local RS = game:GetService("ReplicatedStorage")
	local folder = RS:WaitForChild("Config")
	local okA, ids = pcall(require, folder:WaitForChild("AssetIds") :: ModuleScript)
	local okV, cfg = pcall(require, folder:WaitForChild("VisualConfig") :: ModuleScript)
	return (if okA then ids else nil), (if okV then cfg else nil)
end

function MeshSkin.config(): any
	local _, cfg = configs()
	return cfg
end

function MeshSkin.spec(key: string): Spec?
	local ids, cfg = configs()
	return MeshSkin.resolve(key, ids, cfg)
end

local function enumOr(enum: any, name: any, default: any): any
	local ok, v = pcall(function()
		return enum[name]
	end)
	return if ok and v then v else default
end

local function template(meshId: string): MeshPart?
	local t = templates[meshId]
	if t then
		return t
	end
	if t == false and os.clock() - (failedAt[meshId] or 0) < RETRY_SECONDS then
		return nil
	end
	local cfg = MeshSkin.config() or {}
	local render = enumOr(Enum.RenderFidelity, cfg.RenderFidelity, Enum.RenderFidelity.Automatic)
	local coll = enumOr(Enum.CollisionFidelity, cfg.CollisionFidelity, Enum.CollisionFidelity.Box)
	local ok, mp = pcall(function()
		return game:GetService("InsertService"):CreateMeshPartAsync(meshId, coll, render)
	end)
	if not (ok and mp) then
		ok, mp = pcall(function()
			return (game:GetService("AssetService") :: any):CreateMeshPartAsync(Content.fromUri(meshId), { CollisionFidelity = coll, RenderFidelity = render })
		end)
	end
	if not (ok and mp and (mp :: Instance):IsA("MeshPart")) then
		warn(`[MeshSkin] {meshId} failed to load: {mp}`)
		templates[meshId] = false
		failedAt[meshId] = os.clock()
		return nil
	end
	templates[meshId] = mp
	return mp :: MeshPart
end

function MeshSkin.make(spec: Spec, name: string, cf: CFrame, side: string?): MeshPart?
	local t = template(spec.meshId)
	if not t then
		return nil
	end
	local skin = t:Clone()
	local o, r = MeshSkin.place(spec, side)
	skin.Name = name
	skin.Size = Vector3.new(spec.size[1], spec.size[2], spec.size[3])
	skin.CFrame = cf * CFrame.new(o[1], o[2], o[3]) * CFrame.Angles(math.rad(r[1]), math.rad(r[2]), math.rad(r[3]))
	if spec.textureId ~= "" then
		skin.TextureID = spec.textureId
	end
	skin.Anchored = true
	skin.CanCollide = false
	skin.CanQuery = false
	skin.CanTouch = false
	skin.Massless = true
	skin.CastShadow = true
	skin:SetAttribute("MeshSkin", spec.key)
	return skin
end

function MeshSkin.hide(parts: { Instance })
	for _, p in parts do
		if p:IsA("BasePart") and p:GetAttribute("MeshSkin") == nil then
			p.Transparency = 1
			p.CastShadow = false
			for _, g in p:GetChildren() do
				if g:IsA("SurfaceGui") then
					g.Enabled = false
				elseif g:IsA("Decal") or g:IsA("Texture") then
					g.Transparency = 1
				end
			end
		end
	end
end

return MeshSkin
