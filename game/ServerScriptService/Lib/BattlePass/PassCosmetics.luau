--!strict
-- PassCosmetics [owner: BattlePass]. Puts equipped battle pass rewards on the world, server side, so
-- every player sees them. BattlePassService calls it; reward defs come from BattlePassConfig.Rewards.
--   PassCosmetics.helmet(character, def?)   -- recolour the Costume helmet (HelmetDome/Brim/HelmetComb/Shield);
--                                           -- nil restores the original look. Chief adds a gold star + sparkles,
--                                           -- Glow a soft light in the helmet colour.
--   PassCosmetics.title(character, def?)    -- BillboardGui "PassTitle" above the helmet number tag
--   PassCosmetics.tool(tool, hoseDef?, nozzleDef?)   -- the Hose tool's Handle (hose colour) and Tip (nozzle)
--   PassCosmetics.truck(truck, def?)        -- neon underglow welded under the Chassis ("PassUnderglow"); def.Paint
--                                           -- also repaints the truck's red body panels (restored on change)
-- Every part it adds is Massless, CanCollide/CanQuery/CanTouch false and welded, so physics, ragdoll
-- and first-person transparency behave as with the rest of the costume.
local TweenService = game:GetService("TweenService")

local PassCosmetics = {}

local INK = Color3.fromHex("#2A1410")

local function hex(v: any, fallback: Color3): Color3
	if type(v) == "string" then
		local ok, c = pcall(Color3.fromHex, v)
		if ok then
			return c
		end
	end
	return fallback
end

local function prep(p: BasePart)
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = false
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = b
end

-- Remember a part's original colour/material the first time we touch it, so unequip can restore it.
local function remember(p: BasePart)
	if p:GetAttribute("PassBaseColor") == nil then
		p:SetAttribute("PassBaseColor", p.Color)
		p:SetAttribute("PassBaseMaterial", p.Material.Name)
	end
end

local function restore(p: BasePart)
	local c = p:GetAttribute("PassBaseColor")
	if typeof(c) == "Color3" then
		p.Color = c
	end
	local m = p:GetAttribute("PassBaseMaterial")
	if type(m) == "string" then
		local ok, mat = pcall(function()
			return (Enum.Material :: any)[m]
		end)
		if ok and mat then
			p.Material = mat
		end
	end
end

local function paint(p: BasePart, color: Color3, material: Enum.Material)
	remember(p)
	p.Color = color
	p.Material = material
end

local function clearFx(costume: Instance)
	for _, d in costume:GetDescendants() do
		if d:GetAttribute("PassFx") == true then
			d:Destroy()
		end
	end
end

function PassCosmetics.helmet(character: Model, def: { [string]: any }?)
	local costume = character:FindFirstChild("Costume")
	if not costume then
		return
	end
	clearFx(costume)
	local dome = costume:FindFirstChild("HelmetDome") :: BasePart?
	local parts: { [string]: BasePart } = {}
	for _, n in { "HelmetDome", "Brim", "HelmetComb", "Shield" } do
		local p = costume:FindFirstChild(n)
		if p and p:IsA("BasePart") then
			parts[n] = p
		end
	end
	if not def then
		for _, p in parts do
			restore(p)
		end
		costume:SetAttribute("PassHelmet", nil)
		return
	end
	local main = hex(def.Color, Color3.fromHex("#C0301E"))
	local trim = hex(def.Trim, main:Lerp(Color3.new(0, 0, 0), 0.35))
	local mat = if def.Neon then Enum.Material.Neon elseif def.Metal then Enum.Material.Metal else Enum.Material.SmoothPlastic
	if parts.HelmetDome then
		paint(parts.HelmetDome, main, mat)
	end
	if parts.Brim then
		paint(parts.Brim, trim, if def.Neon then Enum.Material.SmoothPlastic else mat)
	end
	if parts.HelmetComb then
		paint(parts.HelmetComb, trim, if def.Neon then Enum.Material.Neon else mat)
	end
	if def.Chief and parts.Shield then
		paint(parts.Shield, Color3.fromHex("#FFC21F"), Enum.Material.SmoothPlastic)
	elseif parts.Shield then
		restore(parts.Shield)
	end
	if dome and def.Sparkle then
		local sp = Instance.new("ParticleEmitter")
		sp.Name = "PassSparkle"
		sp:SetAttribute("PassFx", true)
		sp.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		sp.Color = ColorSequence.new(trim, Color3.new(1, 1, 1))
		sp.LightEmission = 1
		sp.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
		sp.Lifetime = NumberRange.new(0.5, 0.9)
		sp.Rate = 6
		sp.Speed = NumberRange.new(0.5, 1.2)
		sp.SpreadAngle = Vector2.new(180, 180)
		sp.Parent = dome
	end
	if dome and def.Glow then
		local light = Instance.new("PointLight")
		light.Name = "PassGlow"
		light:SetAttribute("PassFx", true)
		light.Color = main
		light.Range = 7
		light.Brightness = 0.9
		light.Parent = dome
	end
	if dome and def.Chief then
		-- a gold star on top of the Fire Chief's helmet
		local star = Instance.new("Part")
		star.Name = "ChiefStar"
		star:SetAttribute("PassFx", true)
		star.Shape = Enum.PartType.Ball
		star.Size = Vector3.new(0.55, 0.55, 0.55)
		star.Color = Color3.fromHex("#FFC21F")
		star.Material = Enum.Material.Neon
		star.CFrame = dome.CFrame * CFrame.new(0, dome.Size.Y * 0.5 + 0.15, 0)
		prep(star)
		weld(dome, star)
		local light = Instance.new("PointLight")
		light.Color = Color3.fromHex("#FFD84A")
		light.Range = 6
		light.Brightness = 1.2
		light.Parent = star
		star.Parent = costume
	end
	costume:SetAttribute("PassHelmet", def.Name)
end

function PassCosmetics.title(character: Model, def: { [string]: any }?)
	local head = character:FindFirstChild("Head") :: BasePart?
	local old = character:FindFirstChild("PassTitle", true)
	if old and old:IsA("BillboardGui") then
		old:Destroy()
	end
	if not def or not head then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "PassTitle"
	-- sized in studs (it shrinks with distance like a name tag, instead of a fixed 240 px banner that
	-- filled a phone screen), and hidden from its own wearer: you never need your own title over your head
	gui.Size = UDim2.new(5, 0, 0.7, 0)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 4.2, 0) -- just above the helmet number tag (3.4)
	gui.AlwaysOnTop = false -- walls hide it (and it shows in Studio screen captures)
	gui.MaxDistance = 70
	local owner = game:GetService("Players"):GetPlayerFromCharacter(character)
	if owner then
		gui.PlayerToHideFrom = owner
	end
	gui.LightInfluence = 0
	gui.Adornee = head
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.LuckiestGuy
	label.TextScaled = true
	label.Text = string.upper(tostring(def.Name or ""))
	label.TextColor3 = hex(def.Color, Color3.fromHex("#FFF1D6"))
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = INK
	stroke.Parent = label
	if def.Shine then
		label.TextColor3 = Color3.new(1, 1, 1)
		local g = Instance.new("UIGradient")
		g.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromHex("#FFF1A8")),
			ColorSequenceKeypoint.new(0.5, Color3.fromHex("#FFC21F")),
			ColorSequenceKeypoint.new(1, Color3.fromHex("#FF8A1F")),
		})
		g.Rotation = 90
		g.Parent = label
	end
	label.Parent = gui
	gui.Parent = head -- a BillboardGui only renders under a part (not in the Costume Folder)
end

function PassCosmetics.tool(tool: Tool, hose: { [string]: any }?, nozzle: { [string]: any }?)
	if tool.Name ~= "Hose" then
		return
	end
	local handle = tool:FindFirstChild("Handle") :: BasePart?
	local tip = tool:FindFirstChild("Tip") :: BasePart?
	if handle then
		if hose then
			paint(handle, hex(hose.Color, handle.Color), Enum.Material.SmoothPlastic)
		else
			restore(handle)
		end
	end
	if tip then
		local old = tip:FindFirstChild("PassSparkle")
		if old then
			old:Destroy()
		end
		if nozzle then
			paint(tip, hex(nozzle.Color, tip.Color), Enum.Material.SmoothPlastic)
			if nozzle.Sparkle then
				local sp = Instance.new("Sparkles")
				sp.Name = "PassSparkle"
				sp.SparkleColor = hex(nozzle.Color, tip.Color)
				sp.Parent = tip
			end
		else
			restore(tip)
		end
	end
end

local pulses: { [Model]: Tween } = {}

-- TruckBuilder's TruckRed / TruckRedDark: the body panels a paint job recolours
local TRUCK_RED = Color3.fromRGB(200, 35, 43)
local TRUCK_RED_DARK = Color3.fromRGB(150, 24, 30)

local function near(a: Color3, b: Color3): boolean
	return math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B) < 0.06
end

local function paintTruck(truck: Model, def: { [string]: any }?)
	local paintHex = def and def.Paint
	local main = if type(paintHex) == "string" then hex(paintHex, TRUCK_RED) else nil
	local mat = if def and def.PaintMetal then Enum.Material.Metal else Enum.Material.SmoothPlastic
	for _, d in truck:GetDescendants() do
		if not d:IsA("BasePart") or d:GetAttribute("MeshSkin") ~= nil or d.Name == "PassUnderglow" then
			continue
		end
		local painted = d:GetAttribute("PassPaint")
		if main then
			local base = d:GetAttribute("PassBaseColor")
			local orig = if typeof(base) == "Color3" then base else d.Color
			if painted == "dark" or (painted == nil and near(orig, TRUCK_RED_DARK)) then
				paint(d, main:Lerp(Color3.new(0, 0, 0), 0.3), mat)
				d:SetAttribute("PassPaint", "dark")
			elseif painted == "main" or (painted == nil and near(orig, TRUCK_RED)) then
				paint(d, main, mat)
				d:SetAttribute("PassPaint", "main")
			end
		elseif painted ~= nil then
			restore(d)
			d:SetAttribute("PassPaint", nil)
		end
	end
end

function PassCosmetics.truck(truck: Model, def: { [string]: any }?)
	local old = truck:FindFirstChild("PassUnderglow")
	if old then
		old:Destroy()
	end
	local tw = pulses[truck]
	if tw then
		tw:Cancel()
		pulses[truck] = nil
	end
	pcall(paintTruck, truck, def)
	local chassis = truck:FindFirstChild("Chassis") :: BasePart?
	if not def or not chassis then
		return
	end
	local color = hex(def.Color, Color3.fromHex("#2FA8FF"))
	local glow = Instance.new("Part")
	glow.Name = "PassUnderglow"
	glow.Size = Vector3.new(chassis.Size.X + 0.4, 0.12, chassis.Size.Z + 0.4)
	glow.CFrame = chassis.CFrame * CFrame.new(0, -chassis.Size.Y / 2 - 0.12, 0)
	glow.Color = color
	glow.Material = Enum.Material.Neon
	glow.Transparency = 0.15
	prep(glow)
	weld(chassis, glow)
	local light = Instance.new("SurfaceLight")
	light.Face = Enum.NormalId.Bottom
	light.Color = color
	light.Range = 14
	light.Brightness = 4
	light.Angle = 160
	light.Parent = glow
	local side = Instance.new("PointLight")
	side.Color = color
	side.Range = 12
	side.Brightness = 1.5
	side.Parent = glow
	glow.Parent = truck
	if type(def.Pulse) == "string" then
		local to = hex(def.Pulse, color)
		local t = TweenService:Create(glow, TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Color = to })
		t:Play()
		pulses[truck] = t
		truck.Destroying:Once(function()
			pulses[truck] = nil
		end)
	end
end

return PassCosmetics
