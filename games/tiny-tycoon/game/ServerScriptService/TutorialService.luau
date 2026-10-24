--!strict
-- TutorialService: thin compatibility shim.
-- TutorialFlow is the single owner of tutorial state, banner text, beam, target and
-- stuck re-show. This module keeps its public API (start, notify, onPlotClaimed) so callers
-- do not change, but only forwards to TutorialFlow. It fires no step events of its own
-- and does not bump 'tutorial_steps'.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TutorialService = {}

-- Lazy require so a require cycle between the two modules can never deadlock at load time.
local flowModule: any = nil

local function getFlow(): any
	if flowModule == nil then
		flowModule = require((script.Parent :: any):WaitForChild("TutorialFlow", 10))
	end
	return flowModule
end

local started = false

function TutorialService.start()
	if started then
		return
	end
	started = true
	local flow = getFlow()
	if flow and type(flow.start) == "function" then
		flow.start()
	end
end

function TutorialService.notify(player: Player, eventName: string)
	local flow = getFlow()
	if flow and type(flow.notify) == "function" then
		flow.notify(player, eventName)
	end
end

-- Called when a player's plot is claimed (manual or auto). Forwarded to TutorialFlow.
function TutorialService.onPlotClaimed(player: Player)
	local flow = getFlow()
	if not flow then
		return
	end
	if type(flow.onPlotClaimed) == "function" then
		flow.onPlotClaimed(player)
		return
	end
	if type(flow.notify) == "function" then
		local eventName = "CLAIMED"
		local cfgModule = ReplicatedStorage:FindFirstChild("TutorialConfig")
		if cfgModule and cfgModule:IsA("ModuleScript") then
			local ok, cfg = pcall(require, cfgModule)
			if ok and type(cfg) == "table" then
				local events = (cfg :: any).EVENTS
				if type(events) == "table" and type(events.CLAIMED) == "string" then
					eventName = events.CLAIMED
				end
			end
		end
		flow.notify(player, eventName)
	end
end

return TutorialService
