"""Build the map in Studio's Edit datamodel so models are visible without pressing Play.

Syncs the game folder (no prune), then runs MapService:BuildAll() and the default atmosphere preset
in Edit. MapService rebuilds the same locations at server start (it replaces Workspace.Map.<Id>), so
the preview never duplicates in play.
"""

from __future__ import annotations

from pathlib import Path

from forge import sync as fsync
from forge.config import Settings
from forge.studio import Studio

PREVIEW_LUAU = r"""
local SSS = game:GetService("ServerScriptService")
local out = {}
local ok, MapService = pcall(require, SSS.Services.MapService)
if not ok then return "ERROR require MapService: " .. tostring(MapService) end
local okB, ms = pcall(function() return MapService:BuildAll() end)
if not okB then return "ERROR BuildAll: " .. tostring(ms) end
local map = workspace:FindFirstChild("Map")
for _, loc in (map and map:GetChildren() or {}) do
	table.insert(out, loc.Name .. "=" .. #loc:GetDescendants())
end
local atm = SSS.Services:FindFirstChild("AtmosphereService")
if atm then
	local okA, A = pcall(require, atm)
	if okA and type(A) == "table" and type(A.ApplyPreset) == "function" then
		pcall(A.ApplyPreset, "DuskSuburb")
		table.insert(out, "atmosphere=DuskSuburb")
	end
end
return "OK built " .. ms .. "ms: " .. table.concat(out, ", ")
"""


async def preview(settings: Settings, root: Path, studio_name: str | None = None,
                  shot: Path | None = None, camera: tuple | None = None, look_at: tuple | None = None) -> str:
    root = root.resolve()
    errors = fsync.check(root)
    if errors:
        raise SystemExit("luau-compile errors:\n" + "\n".join(f"  {p}: {m.strip()}" for p, m in errors))
    async with Studio(settings) as studio:
        await studio.select(studio_name)
        synced = await studio.sync(root, settings.sync_port, prune=False)
        built = await studio.execute_luau(PREVIEW_LUAU, "Edit")
        lines = [f"sync: {str(synced).strip()}", f"preview: {str(built).strip()}"]
        if shot:
            saved = await studio.screenshot(shot, camera, look_at)
            lines.append(f"screenshot: {saved or 'none returned'}")
        return "\n".join(lines)
