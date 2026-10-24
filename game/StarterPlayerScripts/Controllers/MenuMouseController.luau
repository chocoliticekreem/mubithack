--!strict
-- MenuMouseController. In first person Roblox locks the mouse to the screen centre, so an open menu
-- (mission picker, help, results, locker, profile, graphics...) can't be clicked. Roblox frees the
-- mouse while any visible GuiButton has Modal = true, so this keeps one invisible modal button and
-- shows it whenever a menu is open:
--   * any GuiObject with attribute Menu = true that is visible on screen, or
--   * any HudLayout.modal panel that is open,
--   * any big visible panel (>= 25% of the screen each way, mostly opaque) that holds a button.
--     (A full-screen backdrop beside its buttons, like the results screen's, needs Menu = true.)
-- Outside menus it also un-sticks a mouse left in LockCurrentPosition (no right button held) and keeps
-- the cursor icon on.
-- Big HUD overlays (vignettes, heat haze) have no buttons, so they never count.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript) :: any

local MenuMouseController = {}
MenuMouseController.Priority = 100

local CHECK_HZ = 6
local MIN_FRACTION = 0.25

local player = Players.LocalPlayer
local modal: TextButton? = nil
local open = false

local function ensureModal(): TextButton
	if modal and modal.Parent and modal.Parent.Parent then
		return modal
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "MenuMouse"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = -100
	gui.Parent = player:WaitForChild("PlayerGui")
	local b = Instance.new("TextButton")
	b.Name = "FreeMouse"
	b.Modal = true
	b.Text = ""
	b.BackgroundTransparency = 1
	b.Size = UDim2.fromOffset(0, 0)
	b.Selectable = false
	b.Visible = false
	b.Parent = gui
	modal = b
	return b
end

local function shown(g: GuiObject): boolean
	if not g.Visible then
		return false
	end
	local p = g.Parent
	while p do
		if p:IsA("GuiObject") then
			if not p.Visible then
				return false
			end
		elseif p:IsA("LayerCollector") then
			return p.Enabled
		end
		p = p.Parent
	end
	return false
end

local function hasButton(g: Instance): boolean
	for _, d in g:GetDescendants() do
		if d:IsA("GuiButton") and d.Visible and d ~= modal then
			return true
		end
	end
	return false
end

-- PlayerGui index, kept up to date by DescendantAdded/Removing: walking PlayerGui with GetDescendants six
-- times a second (and reading an attribute on every UICorner/label) was this client's top Lua cost in
-- the lobby. `panels` = Frame/ScrollingFrame/ImageLabel (big-panel test), `menus` = attribute Menu = true
-- (checked a frame after it's added, since builders set the attribute after parenting).
local panels: { [GuiObject]: true } = {}
local menus: { [GuiObject]: true } = {}

-- Menus are top-level panels (ScreenGui > Panel, at most a wrapper or two deep). The minimap's ~1,300
-- road/label frames sit deeper and never count, so they're left out of the index.
local MAX_DEPTH = 3
local function depth(g: Instance): number
	local n = 0
	local p = g.Parent
	while p and not p:IsA("LayerCollector") do
		n += 1
		p = p.Parent
	end
	return n
end

local function add(d: Instance)
	if not d:IsA("GuiObject") then
		return
	end
	local g = d :: GuiObject
	if (g:IsA("Frame") or g:IsA("ScrollingFrame") or g:IsA("ImageLabel")) and depth(g) <= MAX_DEPTH then
		panels[g] = true
	end
	task.defer(function()
		if g.Parent and g:GetAttribute("Menu") == true then
			menus[g] = true
		end
	end)
end

local function track(pg: PlayerGui)
	for _, d in pg:GetDescendants() do
		add(d)
	end
	pg.DescendantAdded:Connect(add)
	pg.DescendantRemoving:Connect(function(d)
		panels[d :: any] = nil
		menus[d :: any] = nil
	end)
end

local function inScreenGui(d: Instance): boolean
	local lc = d:FindFirstAncestorWhichIsA("LayerCollector")
	return lc ~= nil and lc:IsA("ScreenGui") and lc.Name ~= "MenuMouse"
end

local function menuOpen(_pg: PlayerGui): boolean
	if HudLayout.modalOpen() then
		return true
	end
	for d in menus do
		if d.Visible and shown(d) and inScreenGui(d) then
			return true
		end
	end
	local cam = workspace.CurrentCamera
	local view = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local minX, minY = view.X * MIN_FRACTION, view.Y * MIN_FRACTION
	for d in panels do
		if not d.Visible or d.BackgroundTransparency >= 0.6 then
			continue
		end
		local s = d.AbsoluteSize
		if s.X >= minX and s.Y >= minY and shown(d) and inScreenGui(d) and hasButton(d) then
			return true
		end
	end
	return false
end

function MenuMouseController:Init(_all) end

function MenuMouseController:Start()
	-- belt and braces: after the camera locks the mouse each frame, unlock it again while a menu is up
	RunService:BindToRenderStep("MenuMouseFree", Enum.RenderPriority.Camera.Value + 1, function()
		if open then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
			return
		end
		-- never leave the mouse held: a right-drag look that ended outside its controller (truck exit,
		-- mission end, respawn mid-drag) left LockCurrentPosition behind with the cursor hidden
		local cam = workspace.CurrentCamera
		if
			UserInputService.MouseBehavior == Enum.MouseBehavior.LockCurrentPosition
			and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
			and cam ~= nil
			and cam.CameraType ~= Enum.CameraType.Scriptable
		then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
		if not UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = true
		end
	end)
	task.spawn(function()
		local pg = player:WaitForChild("PlayerGui") :: PlayerGui
		track(pg)
		while true do
			local b = ensureModal()
			local ok, isOpen = pcall(menuOpen, pg)
			open = ok and isOpen == true
			b.Visible = open
			task.wait(1 / CHECK_HZ)
		end
	end)
end

return MenuMouseController
