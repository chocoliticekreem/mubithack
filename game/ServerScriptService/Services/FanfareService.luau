--!strict
-- FanfareService [owner: Monetization]. The BIG server-wide moment when someone gets a game pass (bought
-- or owner-gifted with :giftpass) or donates: every client shows a full-width banner, confetti and
-- fireworks around the receiver, a gold glow on them for GlowSeconds, the Fanfare sound and a system
-- chat line; the receiver also gets a card saying what they got and what it does, with an OK button.
-- All of that is drawn by FanfareController (Calm mode keeps the banner, with fewer particles).
-- Words: Lib/Monetization/FanfareText (pure).
--
-- Public API (MonetizationService calls it nil-guarded):
--   FanfareService:Celebrate(info: { kind: "gift" | "pass" | "donate", receiver: Player,
--     giver: Player? | giverName: string?, pass: string?, robux: number? }): boolean
-- Remotes: Fanfare/Show (S->C all: payload { kind, receiverUserId, banner, sub, chat, title, body,
--   glowSeconds })
-- Counters: fanfares
-- Test hooks (DevHook only): _test(player, kind, pass?, giverName?) -> banner text, _selftest()

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local MonetizationConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MonetizationConfig") :: ModuleScript) :: any
local FanfareText = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Monetization"):WaitForChild("FanfareText") :: ModuleScript)

local FanfareService = {}
FanfareService.Priority = 58

local GLOW_SECONDS = 10

local showRemote: RemoteEvent? = nil
local sent = 0

function FanfareService:Celebrate(info: any): boolean
	if type(info) ~= "table" or typeof(info.receiver) ~= "Instance" or not info.receiver:IsA("Player") then
		return false
	end
	local receiver = info.receiver :: Player
	local giverName: string? = info.giverName
	if typeof(info.giver) == "Instance" and info.giver:IsA("Player") then
		giverName = (info.giver :: Player).DisplayName
	end
	local text = FanfareText.build({
		kind = info.kind,
		receiver = receiver.DisplayName,
		giver = giverName,
		pass = info.pass,
		robux = info.robux,
	}, MonetizationConfig.Passes)
	local r = showRemote
	if not r then
		return false
	end
	r:FireAllClients({
		kind = info.kind,
		receiverUserId = receiver.UserId,
		banner = text.banner,
		sub = text.sub,
		chat = text.chat,
		title = text.title,
		body = text.body,
		glowSeconds = GLOW_SECONDS,
	})
	sent += 1
	Telemetry.count("fanfares")
	return true
end

function FanfareService:Init(_all: { [string]: any }) end

function FanfareService:Start()
	showRemote = Net.event("Fanfare", "Show")
end

function FanfareService:_test(player: Player, kind: string, pass: string?, giverName: string?): string
	local ok = self:Celebrate({ kind = kind, receiver = player, pass = pass or "UnlimitedFoam", giverName = giverName or "Owner", robux = 100 })
	local text = FanfareText.build({ kind = kind, receiver = player.DisplayName, giver = giverName or "Owner", pass = pass or "UnlimitedFoam", robux = 100 }, MonetizationConfig.Passes)
	return `{ok}|{text.banner}`
end

function FanfareService:_selftest(): (boolean, string)
	return showRemote ~= nil, `remote={showRemote ~= nil} sent={sent} players={#Players:GetPlayers()}`
end

return FanfareService
