"""Live proof for the ObbyThemes kit module (forge/kit/modules/ObbyThemes.luau).

    .venv/bin/python scripts/obby_themes_demo.py --studio <studio id> [--gallery] [--play] [--keep] [--no-shots]

In the Edit datamodel of ONE Studio window (pinned by id) it installs ObbyKit + ObbyThemes under
ServerStorage.ObbyThemesDemo and, for every theme side by side, builds two stages the way ObbyKit v2 does (each
piece dressed as it is built, then the stage's decor; the second stage turns on the first one's checkpoint), a log
and a ramp built like v2's platform shapes, over a grass ground so legs reach it, and one stage far off the ground
(brackets instead of legs). The ground is Terrain filled just before the build, as WorldKit does (a grass part
when the place has Terrain of its own). Every piece is in a palette like the level designer's. It checks that no
decoration can be touched, queried or stood on, that every unanchored decoration is jointed and that every leg ends
on the ground, writes the counts to demo-report.json, and saves JPEG screenshots: an overview, a 3/4, a player's-eye and a ground view per theme and,
with --gallery, every kind of each theme. --play starts a playtest, builds the moving kinds of every theme next to
the player and measures for six seconds how far decorations drift from the part they ride, how far carousel horses
bob and how closely a vanishing tile's decorations follow its transparency; the result goes to <out>/play-proof.json
and the playtest is always stopped. Without --keep it removes everything it added.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import anyio

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from forge import sync as fsync  # noqa: E402
from forge.studio import Studio, extract_json  # noqa: E402

MODULES = ROOT / "forge" / "kit" / "modules"
SPACING = 150
HEIGHT = 40
GALLERY_AT = (3000, 120, 0)

INSTALL = """
local SS = game:GetService("ServerStorage")
local old = SS:FindFirstChild("ObbyThemesDemo")
if old then old:Destroy() end
local f = Instance.new("Folder")
f.Name = "ObbyThemesDemo"
for name, src in { ObbyKit = __KIT__, ObbyThemes = __THEMES__ } do
	local m = Instance.new("ModuleScript")
	m.Name = name
	m.Source = src
	m.Parent = f
end
f.Parent = SS
return "installed"
"""

# Zone palettes like the ones the level designer picked for Funfair Frenzy (runs/.../levels/zone-NN.json).
COMMON = """
local CS = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local kit = game:GetService("ServerStorage"):WaitForChild("ObbyThemesDemo")
local ObbyKit = require(kit.ObbyKit)
local Themes = require(kit.ObbyThemes)
local PAL = {
	entrance = { { "#FF4F6D", "#FFC429", "#FFF4E0" }, "SmoothPlastic" },
	carousel = { { "#FF8FC7", "#FFD36E", "#FFF4E0" }, "SmoothPlastic" },
	bumper = { { "#3EC9F5", "#FFC429", "#FFF4E0" }, "Metal" },
	teacups = { { "#9B5CFF", "#FFC429", "#FFF4E0" }, "SmoothPlastic" },
	ferris = { { "#FF8A3D", "#FFC429", "#FFF4E0" }, "Metal" },
	flume = { { "#58D65C", "#3EC9F5", "#FFF4E0" }, "WoodPlanks" },
	haunted = { { "#2B2D6E", "#FF8A3D", "#FFF4E0" }, "Slate" },
	pirate = { { "#B5651D", "#E63946", "#F4E1C1" }, "WoodPlanks" },
	coaster = { { "#2B6CB0", "#FF4F6D", "#FFF4E0" }, "Metal" },
	finale = { { "#2B2D6E", "#FFC429", "#FF4F6D" }, "Foil" },
}
local function look(theme)
	local p = PAL[theme]
	return { main = Color3.fromHex(p[1][1]), accent = Color3.fromHex(p[1][2]), highlight = Color3.fromHex(p[1][3]),
		material = (Enum.Material :: any)[p[2]] }
end
local function sample(kind, k)
	return if kind == "moving" then { move = { 6, 0, 0 } } elseif kind == "checkpoint" then { stage = k } else nil
end
-- Build one stage the way ObbyKit v2 does: each piece dressed as it is built (the pieces after it do not exist
-- yet), then the stage's decor, then the stage goes into the world.
local function buildStage(st, frame, theme, parent)
	local model, cp = ObbyKit.LevelBuilder.build(st, frame, { parent = parent, validate = false,
		palette = PAL[theme][1], material = PAL[theme][2], zoneName = theme })
	model.Parent = nil
	local pieces = {}
	for _, m in model:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("Kind") then
			table.insert(pieces, m)
		end
	end
	table.sort(pieces, function(a, b)
		return a:GetAttribute("Piece") < b:GetAttribute("Piece")
	end)
	for _, m in pieces do
		m.Parent = nil
	end
	local rng = Random.new(st.stage * 7919 + 17)
	for _, m in pieces do
		m.Parent = model
		Themes.dress(m:GetAttribute("Kind"), m, st.pieces[m:GetAttribute("Piece")], theme, rng)
	end
	Themes.stageDecor(model, theme, rng, st.stage)
	model.Parent = parent
	return model, cp
end
-- ObbyKit v2's platform shapes (a log across the course, a wedge-ramp climbing along it), built the way v2 does.
local function v2platform(parent, cf, shape, size, theme)
	local m = Instance.new("Model")
	m.Name = "platform"
	m:SetAttribute("Kind", "platform")
	CS:AddTag(m, "Obstacle")
	m.Parent = parent
	local part
	if shape == "cylinder" then
		part = Instance.new("Part")
		part.Shape = Enum.PartType.Cylinder
		part.Size = Vector3.new(size[1], size[3], size[3])
		part.CFrame = cf * CFrame.new(0, -size[3] / 2, 0)
	else
		part = Instance.new("WedgePart")
		part.Size = Vector3.new(size[1], size[2], size[3])
		part.CFrame = cf * CFrame.new(0, -size[2] / 2, 0) * CFrame.Angles(0, math.pi, 0)
	end
	part.Name = "Platform"
	part.Anchored = true
	part.Color = look(theme).main
	part:SetAttribute("Shape", shape)
	CS:AddTag(part, "ObbyStandable")
	part.Parent = m
	return m
end
"""

BUILD = COMMON + """
for _, name in { "ObbyThemesDemo", "ObbyThemesGround" } do
	local old = workspace:FindFirstChild(name)
	if old then old:Destroy() end
end
-- the ground legs stand on: Terrain like WorldKit's (filled just before the course is built, as in a game), or a
-- grass part when the place already has Terrain of its own
if workspace.Terrain:CountCells() == 0 then
	workspace.Terrain:FillBlock(CFrame.new(__SPACING__ * 4.5, -2, -120), Vector3.new(__SPACING__ * 10 + 300, 4, 420),
		Enum.Material.Grass)
	workspace:SetAttribute("ObbyThemesTerrain", true)
else
	local ground = Instance.new("Part")
	ground.Name = "ObbyThemesGround"
	ground.Anchored = true
	ground.Size = Vector3.new(__SPACING__ * 10 + 300, 1, 420)
	ground.CFrame = CFrame.new(__SPACING__ * 4.5, 0.55, -120)
	ground.Color = Color3.fromRGB(96, 178, 84)
	ground.Material = Enum.Material.Grass
	ground.Parent = workspace
end
local groundTop = if workspace:GetAttribute("ObbyThemesTerrain") then 0 else 1.05
local root = Instance.new("Folder")
root.Name = "ObbyThemesDemo"
root.Parent = workspace
-- the theme's signature pieces (ObbyKit v2 SIGNATURES) in each of the two stages
local SIG = {
	entrance = { { kind = "jumppad", power = 90, forward = 20, gap = 4 }, { kind = "platform", shape = "round", size = { 10, 1, 10 }, gap = 4 } },
	carousel = { { kind = "turntable", size = { 14, 1, 14 }, speed = 30, gap = 4 }, { kind = "moving", move = { 0, 0, 6 }, gap = 3 } },
	bumper = { { kind = "conveyor", size = { 6, 1, 16 }, speed = 6, gap = 4 }, { kind = "moving", move = { 6, 0, 0 }, gap = 4 } },
	teacups = { { kind = "spinner", size = { 14, 1, 14 }, speed = 60, gap = 4 }, { kind = "turntable", size = { 12, 1, 12 }, speed = 30, gap = 4 } },
	ferris = { { kind = "moving", move = { 0, 6, 0 }, gap = 4 }, { kind = "trampoline", gap = 4 } },
	flume = { { kind = "conveyor", size = { 6, 1, 16 }, speed = 6, gap = 4 }, { kind = "platform", size = { 8, 1, 8 }, gap = 4 } },
	haunted = { { kind = "disappearing", size = { 5, 1, 5 }, count = 3, spacing = 3, gap = 4 }, { kind = "pendulum", size = { 6, 1, 14 }, gap = 4 } },
	pirate = { { kind = "pendulum", size = { 6, 1, 14 }, swing = 60, length = 10, gap = 4 }, { kind = "moving", move = { 6, 0, 0 }, gap = 4 } },
	coaster = { { kind = "moving", move = { 0, 0, 7 }, gap = 3 }, { kind = "jumppad", power = 90, forward = 20, gap = 10 } },
	finale = { { kind = "spinner", size = { 14, 1, 14 }, speed = 60, gap = 4 }, { kind = "turntable", size = { 12, 1, 12 }, speed = 30, gap = 4 } },
}
local function audit(rec, dressing)
	for _, d in (if dressing then dressing:GetDescendants() else {}) do
		if d:IsA("BasePart") then
			if d.CanCollide or d.CanTouch or d.CanQuery or not d.Massless or #CS:GetTags(d) > 0 then
				rec.bad += 1
				rec.badSample = rec.badSample or d:GetFullName()
			end
			if not d.Anchored and not (d:FindFirstChildWhichIsA("WeldConstraint") or d:FindFirstChildWhichIsA("JointInstance")) then
				rec.unwelded += 1
			end
		end
	end
end
local out = {}
for i, theme in Themes.THEMES do
	local x = (i - 1) * __SPACING__
	local sig = SIG[theme]
	local a = { stage = 1, name = "Opening Act", pieces = {
		{ kind = "platform", gap = 4, size = { 10, 1, 10 } },
		table.clone(sig[1]),
		{ kind = "platform", gap = 4, size = { 8, 1, 8 }, side = 2, rise = 1 },
		{ kind = "moving", gap = 4, size = { 7, 1, 7 }, move = { 6, 0, 0 }, period = 4 },
		{ kind = "checkpoint", gap = 4 },
	} }
	local b = { stage = 2, name = "Second Thrill", pieces = {
		{ kind = "platform", gap = 4, size = { 10, 1, 10 } },
		{ kind = "lava", gap = 0, size = { 10, 1, 4 } },
		{ kind = "platform", gap = 0, size = { 10, 1, 8 } },
		table.clone(sig[2]),
		{ kind = "disappearing", gap = 4, size = { 5, 1, 5 }, count = 2, spacing = 3 },
		{ kind = "checkpoint", gap = 4 },
	} }
	local rec = { theme = theme, total = 0, bad = 0, unwelded = 0, stages = {}, legs = 0, legGap = 0 }
	local start = ObbyKit.Obstacles.checkpoint(root, CFrame.new(x, __HEIGHT__, 0), { stage = 0 }, look(theme))
	start.Name = theme .. "_start"
	Themes.dress("checkpoint", start, nil, theme, Random.new(i))
	local cursor = CFrame.new(x, __HEIGHT__, 0)
	for k, st in { a, b } do
		local frame = cursor * CFrame.Angles(0, if k == 2 then -math.rad(35) else 0, 0)
		local model, cp = buildStage(st, frame, theme, root)
		model.Name = theme .. "_" .. k
		local n = 0
		for _, m in model:GetChildren() do
			local d = m:FindFirstChild("Dressing") or (m.Name == "StageDecor" and m)
			if d then
				audit(rec, d)
				n += d:GetAttribute("Parts") or 0
			end
		end
		table.insert(rec.stages, { parts = n, decor = model.StageDecor:GetAttribute("Parts"), swept = model.StageDecor:GetAttribute("Swept") })
		for _, g in model:GetDescendants() do
			if g:IsA("Model") and g.Name == "Leg" then
				local bottom = math.huge
				for _, p in g:GetDescendants() do
					if p:IsA("BasePart") then
						local _, y, _, _, _, _, r10, r11, r12 = p.CFrame:GetComponents()
						local h = p.Size / 2
						bottom = math.min(bottom, y - (math.abs(r10) * h.X + math.abs(r11) * h.Y + math.abs(r12) * h.Z))
					end
				end
				rec.legs += 1
				rec.legGap = math.max(rec.legGap, math.abs(bottom - groundTop))
			end
		end
		rec.total += n
		cursor = CFrame.new((cp.CFrame * CFrame.new(0, cp.Size.Y / 2, 0)).Position) * frame.Rotation
	end
	-- v2 shapes beside the course: a log and a ramp
	for k, case in { { "cylinder", { 10, 4, 4 } }, { "wedge-ramp", { 8, 3, 10 } } } do
		local m = v2platform(root, CFrame.new(x + 26, __HEIGHT__ - 6, -20 - k * 18), case[1], case[2], theme)
		audit(rec, Themes.dress("platform", m, nil, theme, Random.new(k)))
	end
	-- the same opening stage far off the ground: brackets instead of legs
	local far = buildStage(a, CFrame.new(5000 + x, __HEIGHT__, 0), theme, root)
	far.Name = theme .. "_offground"
	table.insert(out, rec)
end
return HttpService:JSONEncode(out)
"""

GALLERY = COMMON + """
local old = workspace:FindFirstChild("ObbyThemesGallery")
if old then old:Destroy() end
local root = Instance.new("Model")
root.Name = "ObbyThemesGallery"
root.Parent = workspace
local theme = "__THEME__"
for k, kind in ObbyKit.KindNames do
	local cf = CFrame.new(__GX__ + ((k - 1) % 4) * 26, __GY__, __GZ__ - math.floor((k - 1) / 4) * 28)
	local raw = sample(kind, k)
	Themes.dress(kind, ObbyKit.Obstacles[kind](root, cf, raw, look(theme)), raw, theme, Random.new(k))
end
return "gallery " .. theme
"""

CLEAN = """
for _, p in { workspace:FindFirstChild("ObbyThemesDemo"), workspace:FindFirstChild("ObbyThemesGallery"),
	workspace:FindFirstChild("ObbyThemesGround"), game:GetService("ServerStorage"):FindFirstChild("ObbyThemesDemo") } do
	if p then p:Destroy() end
end
if workspace:GetAttribute("ObbyThemesTerrain") then
	workspace.Terrain:Clear()
	workspace:SetAttribute("ObbyThemesTerrain", nil)
end
return "clean"
"""

# Play mode (Server datamodel): the moving kinds of every theme next to the player, then six seconds of measuring.
PLAY = COMMON + """
local Players = game:GetService("Players")
local old = workspace:FindFirstChild("ObbyThemesPlay")
if old then old:Destroy() end
local root = Instance.new("Folder")
root.Name = "ObbyThemesPlay"
root.Parent = workspace
local KINDS = {
	{ "moving", { move = { 6, 0, 0 }, period = 3 } }, { "turntable", { speed = 60 } }, { "spinner", { speed = 90 } },
	{ "pendulum", { swing = 60, period = 3 } }, { "disappearing", { count = 3, on = 1.5, off = 1, stagger = 0.4 } },
}
local rides, tiles = {}, {}
for i, theme in Themes.THEMES do
	for k, entry in KINDS do
		local kind, raw = entry[1], entry[2]
		local m = ObbyKit.Obstacles[kind](root, CFrame.new((i - 5.5) * 24, 30, -40 - k * 30), raw, look(theme))
		local d = Themes.dress(kind, m, raw, theme, Random.new(k))
		local r = d:FindFirstChild("Rides")
		if r then
			local host = m:FindFirstChild(r:GetAttribute("Host"))
			for _, p in r:GetDescendants() do
				if p:IsA("BasePart") then
					local horse = p:FindFirstAncestor("Horse") ~= nil
					table.insert(rides, { p = p, host = host, horse = horse, label = theme .. "/" .. kind })
				end
			end
		end
		for _, t in m:GetChildren() do
			if t:IsA("BasePart") and t.Name == "Tile" then
				local box = d:FindFirstChild("Tile" .. tostring(t:GetAttribute("Tile")))
				if box then
					for _, p in box:GetDescendants() do
						if p:IsA("BasePart") then
							table.insert(tiles, { p = p, tile = t })
						end
					end
				end
			end
		end
	end
end
task.wait(1)
local rel, hostStart = {}, {}
for _, r in rides do
	rel[r.p] = r.host.CFrame:ToObjectSpace(r.p.CFrame)
	hostStart[r.host] = hostStart[r.host] or r.host.CFrame
end
local drift, bob, moved, turned = 0, 0, 0, 0
local worst = ""
local tileErr, samples = 0, 0
local t0 = os.clock()
while os.clock() - t0 < 6 do
	task.wait(0.1)
	samples += 1
	for _, r in rides do
		local now = r.host.CFrame:ToObjectSpace(r.p.CFrame)
		local d = (now.Position - rel[r.p].Position)
		if r.horse then
			bob = math.max(bob, math.abs(d.Y))
			if math.abs(d.X) + math.abs(d.Z) > drift then
				drift = math.abs(d.X) + math.abs(d.Z)
				worst = r.label .. " horse"
			end
		elseif d.Magnitude > drift then
			drift = d.Magnitude
			worst = r.label
		end
	end
	for host, cf in hostStart do
		moved = math.max(moved, (host.Position - cf.Position).Magnitude)
		local a = math.deg(math.acos(math.clamp(host.CFrame.LookVector:Dot(cf.LookVector), -1, 1)))
		turned = math.max(turned, a)
	end
end
-- tiles: decorations fade with their tile (sampled now, against the tile's state)
local tileSeen = {}
for i = 1, 30 do
	task.wait(0.05)
	for _, t in tiles do
		local want = t.tile.Transparency
		tileSeen[want] = true
		if want > 0.95 then
			tileErr = math.max(tileErr, 1 - t.p.Transparency)
		elseif want < 0.1 then
			tileErr = math.max(tileErr, math.max(0, t.p.Transparency - 0.2))
		end
	end
end
local states = {}
for v in tileSeen do
	table.insert(states, math.floor(v * 100 + 0.5) / 100)
end
table.sort(states)
return HttpService:JSONEncode({ rides = #rides, tiles = #tiles, samples = samples, maxDrift = drift, worst = worst,
	horseBob = bob, hostMoved = moved, hostTurnedDeg = turned, tileStatesSeen = states, tileMismatch = tileErr,
	players = #Players:GetPlayers() })
"""


def shots(i: int) -> dict[str, tuple[list[float], list[float]]]:
    x = i * SPACING
    return {"three-quarter": ([x + 34, HEIGHT + 30, 14], [x + 4, HEIGHT, -40]),
            "player": ([x + 1, HEIGHT + 6.5, 9], [x - 2, HEIGHT + 1.5, -30]),
            "ground": ([x + 40, 9, -10], [x + 6, HEIGHT - 6, -45])}


def healthy(rec: dict) -> bool:
    return (rec["bad"] == 0 and rec["unwelded"] == 0 and rec["legGap"] <= 0.6
            and all(s["decor"] <= 60 for s in rec["stages"]))


async def play_proof(s: Studio, out: Path) -> dict:
    await s.play(ready=False)
    try:
        await anyio.sleep(4)
        text = await s.execute_luau(PLAY, "Server", timeout=40)
        res = extract_json(text) or {"error": text[:500]}
    finally:
        await s.stop()
    (out / "play-proof.json").write_text(json.dumps(res, indent=1) + "\n")
    return res


async def main(args: argparse.Namespace) -> int:
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    async with Studio(studio_id=args.studio, call_timeout=180) as s:
        if (await s.state()).get("playing"):
            print("Studio is in a playtest: stop it first (this demo builds in Edit)")
            return 1
        code = INSTALL.replace("__KIT__", fsync.long_string((MODULES / "ObbyKit.luau").read_text()), 1)
        code = code.replace("__THEMES__", fsync.long_string((MODULES / "ObbyThemes.luau").read_text()), 1)
        print(await s.execute_luau(code, "Edit"))
        build = BUILD.replace("__SPACING__", str(SPACING)).replace("__HEIGHT__", str(HEIGHT))
        report = extract_json(await s.execute_luau(build, "Edit", timeout=170)) or []
        print(json.dumps(report, indent=1))
        (out / "demo-report.json").write_text(json.dumps(report, indent=1) + "\n")
        if not args.no_shots:
            mid = SPACING * 1.5
            await s.screenshot(out / "overview.jpg", [mid, HEIGHT + 70, 95], [mid, HEIGHT - 5, -70])
            for i, rec in enumerate(report):
                for name, (cam, at) in shots(i).items():
                    print(await s.screenshot(out / f"{i + 1:02d}-{rec['theme']}-{name}.jpg", cam, at))
        if args.gallery:
            gx, gy, gz = GALLERY_AT
            for i, rec in enumerate(report):
                g = GALLERY.replace("__THEME__", rec["theme"]).replace("__GX__", str(gx)).replace("__GY__", str(gy))
                print(await s.execute_luau(g.replace("__GZ__", str(gz)), "Edit"))
                for n, (cam, at) in enumerate((([gx + 39, gy + 21, gz + 22], [gx + 39, gy - 1, gz - 12]),
                                               ([gx + 39, gy + 21, gz - 4], [gx + 39, gy - 1, gz - 38]))):
                    print(await s.screenshot(out / "gallery" / f"{i + 1:02d}-{rec['theme']}-{n + 1}.jpg", cam, at))
        if args.play:
            print(json.dumps(await play_proof(s, out), indent=1))
        if not args.keep:
            print(await s.execute_luau(CLEAN, "Edit"))
    ok = bool(report) and all(healthy(r) for r in report)
    print("invariants:", "ok" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--studio", required=True, help="Studio id (list_roblox_studios); never guessed")
    ap.add_argument("--out", default=str(ROOT / "docs" / "shots" / "obby-themes"))
    ap.add_argument("--keep", action="store_true", help="leave the demo in the place")
    ap.add_argument("--no-shots", action="store_true")
    ap.add_argument("--gallery", action="store_true", help="also shoot every kind, dressed, for each theme")
    ap.add_argument("--play", action="store_true", help="measure decorations on moving pieces in a playtest")
    sys.exit(anyio.run(main, ap.parse_args()))
