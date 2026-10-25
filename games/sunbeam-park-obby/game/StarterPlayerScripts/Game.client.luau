-- Rendered by Forge (forge/template.py): the ParkObby template's client bootstrap. Do not edit.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ParkObby = require(ReplicatedStorage:WaitForChild("Kit"):WaitForChild("ParkObby"))
ParkObby.startClient(require(ReplicatedStorage:WaitForChild("Config")))
