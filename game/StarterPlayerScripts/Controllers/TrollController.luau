--!strict
-- TrollController [owner: Admin]. The two troll effects that only make sense on the victim's own client
-- (TrollService decides, this only draws / steers):
--   * :fakeban (Troll/Fx "fakeban", seconds, by): a scary full-screen "YOU HAVE BEEN BANNED" for a moment,
--     then "...jk! 😜 (a prank by <by>)" and it fades away. Nothing is banned; input is untouched.
--   * :invert (Player attr TrollInverted, AdminConfig.Attr.Inverted, set and cleared by the server):
--     every frame after the control scripts run, the walk direction is flipped (keyboard, gamepad and
--     the touch thumbstick alike), with a small "CONTROLS FLIPPED!" tag on screen.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("AdminConfig") :: ModuleScript) :: any
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript)

local TrollController = {}
TrollController.Priority = 135

local player = Players.LocalPlayer
local STEP = "TrollInvert"

local gui: ScreenGui? = nil
local banScreen: Frame? = nil
local banTitle: TextLabel? = nil
local banSub: TextLabel? = nil
local invertTag: TextLabel? = nil
local banSeq = 0
local inverting = false

local function build()
	local g = UiKit.screen("TrollGui", 90, true)
	gui = g
	local f = Instance.new("Frame")
	f.Name = "FakeBan"
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = Color3.fromHex("#120C0E")
	f.BorderSizePixel = 0
	f.Visible = false
	f.ZIndex = 50
	f.Parent = g
	local t = UiKit.label(f, "Title", "", UDim2.new(0.9, 0, 0.22, 0), UDim2.fromScale(0.05, 0.28), {
		font = UiKit.Header,
		color = Palette.UiRed,
		stroke = true,
	})
	t.TextScaled = true
	t.ZIndex = 51
	local s = UiKit.label(f, "Sub", "", UDim2.new(0.8, 0, 0.12, 0), UDim2.fromScale(0.1, 0.54), {
		font = UiKit.Body,
		color = Palette.UiCream,
	})
	s.TextScaled = true
	s.ZIndex = 51
	banScreen, banTitle, banSub = f, t, s

	local tag = UiKit.label(g, "Inverted", "CONTROLS FLIPPED!", UDim2.fromOffset(320, 40), UDim2.new(0.5, -160, 0.72, 0), {
		font = UiKit.Header,
		textSize = 30,
		color = Palette.UiWarn,
		stroke = true,
	})
	tag.Visible = false
	invertTag = tag
end

local function fakeBan(seconds: number, by: string)
	local f, t, s = banScreen, banTitle, banSub
	if not (f and t and s) then
		return
	end
	banSeq += 1
	local seq = banSeq
	f.BackgroundTransparency = 0
	t.Text = "YOU HAVE BEEN BANNED"
	t.TextColor3 = Palette.UiRed
	s.Text = "Reason: being too awesome at firefighting..."
	f.Visible = true
	UiKit.shake(t, 0.4, 8)
	task.delay(math.clamp(seconds, 1, 6), function()
		if banSeq ~= seq then
			return
		end
		t.Text = "...JK! 😜"
		t.TextColor3 = Palette.UiGood
		s.Text = `It's a prank by {by}. Nobody got banned!`
		UiKit.pop(t, 0.25)
		task.wait(1.6)
		if banSeq ~= seq then
			return
		end
		UiKit.tween(f, 0.4, { BackgroundTransparency = 1 })
		task.wait(0.4)
		if banSeq == seq then
			f.Visible = false
		end
	end)
end

local function setInvert(on: boolean)
	if on == inverting then
		return
	end
	inverting = on
	if invertTag then
		invertTag.Visible = on
	end
	if on then
		-- after the control scripts' Humanoid:Move (RenderPriority.Input), before the character steps
		RunService:BindToRenderStep(STEP, Enum.RenderPriority.Input.Value + 1, function()
			local c = player.Character
			local hum = c and c:FindFirstChildOfClass("Humanoid")
			if hum then
				local dir = hum.MoveDirection
				if dir.Magnitude > 0.01 then
					hum:Move(-dir, false)
				end
			end
		end)
	else
		pcall(function()
			RunService:UnbindFromRenderStep(STEP)
		end)
	end
end

function TrollController:Init(_all) end

function TrollController:Start()
	build()
	local attr = Cfg.Attr.Inverted
	player:GetAttributeChangedSignal(attr):Connect(function()
		setInvert(player:GetAttribute(attr) == true)
	end)
	setInvert(player:GetAttribute(attr) == true)
	local fx = Net.event("Troll", "Fx")
	fx.OnClientEvent:Connect(function(kind: any, seconds: any, by: any)
		if kind == "fakeban" then
			fakeBan(tonumber(seconds) or 3, if type(by) == "string" then by else "an admin")
		end
	end)
end

-- test hooks (execute_luau on the Client)
function TrollController:_state(): string
	local f = banScreen
	return `inverting={inverting} fakeban={f ~= nil and f.Visible}`
end

return TrollController
