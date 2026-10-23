--!strict
-- LobbyController [owner: G3]. STUB from K0 (v1.5): does nothing until G3 replaces this file.
-- Will render: the Mission Board UI (opens on the MissionBoard ProximityPrompt; reads
-- ReplicatedStorage.Config.MissionCatalog, greys out enabled = false), the squad roster over each
-- SquadPad from Lobby/Board, and the leader's Choose/Launch buttons (Lobby/Choose, Lobby/Launch).
-- Hidden while the local Player's InstanceId ~= "" (in a mission).
local LobbyController = {}
LobbyController.Priority = 100

function LobbyController:Init(_controllers: { [string]: any }) end

function LobbyController:Start() end

return LobbyController
