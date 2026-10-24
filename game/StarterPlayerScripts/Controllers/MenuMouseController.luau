--!strict
-- MenuMouseController. In first person Roblox locks the mouse to the screen centre, so an open menu
-- (mission picker, help, results, locker, profile, graphics...) can't be clicked. Roblox frees the
-- mouse while any visible GuiButton has Modal = true, so this keeps one invisible modal button and
-- shows it whenever a menu is open:
--   * any GuiObject with attribute Menu = true that is visible on screen, or
--   * any big visible panel (>= 25% of the screen each way, mostly opaque) that holds a button.
-- Big HUD overlays (vignettes, heat haze) have no buttons, so they never count.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

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

local function menuOpen(pg: PlayerGui): boolean
	local cam = workspace.CurrentCamera
	local view = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	for _, sg in pg:GetChildren() do
		if not sg:IsA("ScreenGui") or not sg.Enabled or sg.Name == "MenuMouse" then
			continue
		end
		for _, d in sg:GetDescendants() do
			if not d:IsA("GuiObject") then
				continue
			end
			if d:GetAttribute("Menu") == true then
				if shown(d) then
					return true
				end
				continue
			end
			if d:IsA("Frame") or d:IsA("ScrollingFrame") or d:IsA("ImageLabel") then
				local s = d.AbsoluteSize
				if s.X >= view.X * MIN_FRACTION and s.Y >= view.Y * MIN_FRACTION and d.BackgroundTransparency < 0.6 and shown(d) and hasButton(d) then
					return true
				end
			end
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
		end
	end)
	task.spawn(function()
		local pg = player:WaitForChild("PlayerGui") :: PlayerGui
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
