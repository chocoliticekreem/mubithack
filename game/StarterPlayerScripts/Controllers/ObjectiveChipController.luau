--!strict
-- ObjectiveChipController [owner: G3 mission]. The ONE always-visible objective chip on a call (docs/game/15
-- "Mobile-first HUD": "one objective chip"), top centre under the timer (HudLayout stack TopCentre, 21):
--   🔥 3 FIRES LEFT   ->   🐶 SAVE 1 MORE   ->   ⚠️ MORE FIRE COMING!   ->   ✅ ALL DONE! 3..2..1   -> results
-- Renders only what MissionService publishes on the run's Workspace.Runs.<id> (or Instances.<id>) folder while
-- it is on scene (RoundState Active): ObjFires, ObjRescues, ObjRescueKind, ObjWave, DoneAt (server time).
-- Yellow = the objective, green = done (docs/game/16 colour rule). Text sizes are design units at 1280x720:
-- UiKit's ViewportScale bottoms out at 0.55, so the 40 pt text is 22 px on a 667x375 phone.
-- Shared logic: ReplicatedStorage/Lib/Mission/CallRamp.chip (spec-tested).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local Loc = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Loc") :: ModuleScript)
local CallRamp = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Mission"):WaitForChild("CallRamp") :: ModuleScript)
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript)
local HudLayout = require(ClientLib:WaitForChild("HudLayout") :: ModuleScript)

local ObjectiveChipController = {}
ObjectiveChipController.Priority = 55 -- after HudController (50): the timer pill is already in the stack

local player = Players.LocalPlayer

local ICONS: { [string]: string } = {
	Civilian = "🧑",
	Cat = "🐱",
	Dog = "🐶",
	Panda = "🐼",
	Penguin = "🐧",
}

local function runFolder(): Instance?
	local id = player:GetAttribute(Names.Attr.InstanceId)
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local runs = workspace:FindFirstChild("Runs")
	local f = runs and runs:FindFirstChild(id)
	if f then
		return f
	end
	local inst = workspace:FindFirstChild("Instances")
	return inst and inst:FindFirstChild(id)
end

-- (icon, text, colour) for a chip state; nil = hide.
local function look(kind: string, n: number, rescueKind: string): (string?, string?, Color3?)
	if kind == "done" then
		return "✅", if n > 0 then Loc.t("ALL DONE! {1}", { n }) else Loc.t("ALL DONE!"), Palette.UiGood
	elseif kind == "fires" then
		return "🔥", if n == 1 then Loc.t("1 FIRE LEFT") else Loc.t("{1} FIRES LEFT", { n }), Palette.UiWarn
	elseif kind == "rescue" then
		return ICONS[rescueKind] or "🧑", Loc.t("SAVE {1} MORE", { n }), Palette.UiWarn
	elseif kind == "wave" then
		return "⚠️", Loc.t("MORE FIRE COMING!"), Palette.UiWarn
	end
	return nil, nil, nil
end

function ObjectiveChipController:Start()
	local gui = UiKit.screen("ObjectiveChip", 2)
	local chip = UiKit.panel(gui, "Chip", UDim2.fromOffset(400, 64), UDim2.new(0.5, 0, 0, 74), Vector2.new(0.5, 0))
	chip.BackgroundColor3 = Palette.UiWarn
	chip.Visible = false
	local icon = UiKit.label(chip, "Icon", "", UDim2.fromOffset(56, 56), UDim2.fromOffset(8, 4), { textSize = 40 })
	local text = UiKit.label(chip, "Text", "", UDim2.new(1, -76, 1, -10), UDim2.fromOffset(66, 5), {
		font = UiKit.Header,
		textSize = 40,
		color = Palette.UiInk,
		align = Enum.TextXAlignment.Left,
		scaled = true,
	})
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = 40
	limit.Parent = text
	HudLayout.add("TopCentre", chip, 21)
	HudLayout.reserve(chip)

	local lastKey = ""
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < 0.1 then
			return
		end
		acc = 0
		local f = runFolder()
		local on = f ~= nil and f:GetAttribute(Names.Attr.RoundState) == "Active" and f:GetAttribute("ObjFires") ~= nil
		if not (on and f) then
			chip.Visible = false
			lastKey = ""
			return
		end
		local kind, n = CallRamp.chip({
			fires = tonumber(f:GetAttribute("ObjFires")) or 0,
			rescues = tonumber(f:GetAttribute("ObjRescues")) or 0,
			wave = f:GetAttribute("ObjWave") == true,
			doneAt = tonumber(f:GetAttribute("DoneAt")) or 0,
			now = workspace:GetServerTimeNow(),
		})
		local rescueKind = tostring(f:GetAttribute("ObjRescueKind") or "")
		local i, t, colour = look(kind, n, rescueKind)
		if not (i and t and colour) then
			chip.Visible = false
			lastKey = ""
			return
		end
		chip.Visible = true
		icon.Text = i
		text.Text = Loc.upper(t)
		chip.BackgroundColor3 = colour
		local key = `{kind}:{n}`
		if key ~= lastKey then
			lastKey = key
			UiKit.pop(chip, if kind == "done" then 0.35 else 0.25)
		end
	end)
end

return ObjectiveChipController
