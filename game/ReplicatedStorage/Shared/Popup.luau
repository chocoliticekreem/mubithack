--!strict
-- Popup [owner: Feedback]. Server side of the subtle world-text feedback (ClientLib/WorldPopup renders).
-- Use for minor juice (slaps, bonks, honks, blame callouts, jokes); keep Net.notify for important events.
--
--   Popup.show(subject: Player | Instance | Vector3, text: string, kind: string?, actor: Player?)
--     Sends Shared/Popup to players within FeedbackConfig.SendRadius of the subject, plus the subject
--     player and the actor (so Minimal mode can show "your" popups). kind = "info"|"good"|"bad"|"blame".
--   Popup.position(subject): Vector3?                     -- head-ish point of a subject
-- Remote: Shared/Popup (S->C: subject: Instance | false, position: Vector3, text, kind, actorUserId,
--   subjectUserId) - declared by Main.server next to Shared/Notify. Counter: popups_sent.
-- Server-only (no-op on the client: call ClientLib/WorldPopup.show directly there).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = require(script.Parent:WaitForChild("Net") :: ModuleScript)
local FeedbackConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("FeedbackConfig") :: ModuleScript) :: any

local Popup = {}

local function resolve(subject: any): (Instance?, Player?)
	if typeof(subject) ~= "Instance" then
		return nil, nil
	end
	local inst = subject :: Instance
	if inst:IsA("Player") then
		return (inst :: Player).Character, inst :: Player
	end
	local model = if inst:IsA("Model") then inst else inst:FindFirstAncestorOfClass("Model")
	local owner = if model then Players:GetPlayerFromCharacter(model) else nil
	return inst, owner
end

function Popup.position(subject: any): Vector3?
	if typeof(subject) == "Vector3" then
		return subject
	end
	local inst = resolve(subject)
	if not inst then
		return nil
	end
	if inst:IsA("BasePart") then
		return (inst :: BasePart).Position
	elseif inst:IsA("Model") then
		local m = inst :: Model
		local head = m:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			return head.Position
		end
		if m.PrimaryPart then
			return m.PrimaryPart.Position
		end
		local ok, pivot = pcall(m.GetPivot, m)
		return if ok then pivot.Position else nil
	elseif inst:IsA("Attachment") then
		return (inst :: Attachment).WorldPosition
	end
	return nil
end

function Popup.show(subject: any, text: string, kind: string?, actor: Player?)
	if not RunService:IsServer() or type(text) ~= "string" or text == "" then
		return
	end
	local ok, err = pcall(function()
		local pos = Popup.position(subject)
		if not pos then
			return
		end
		local inst, subjectPlayer = resolve(subject)
		local remote = Net.event("Shared", "Popup")
		local radius = tonumber(FeedbackConfig.SendRadius) or 70
		local actorId = if actor and typeof(actor) == "Instance" and actor:IsA("Player") then actor.UserId else 0
		local subjectId = if subjectPlayer then subjectPlayer.UserId else 0
		local sent = false
		for _, p in Players:GetPlayers() do
			if p == subjectPlayer or p.UserId == actorId or Net.near(p, pos, radius) then
				remote:FireClient(p, inst or false, pos, text, kind or "info", actorId, subjectId)
				sent = true
			end
		end
		if sent then
			local T = ReplicatedStorage:FindFirstChild("ForgeTelemetry")
			if T then
				(require(T :: ModuleScript) :: any).count("popups_sent")
			end
		end
	end)
	if not ok then
		warn(`[Popup] {err}`)
	end
end

return Popup
