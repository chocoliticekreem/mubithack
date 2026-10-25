-- Rendered by Forge (forge/template.py): the ParkObby template's server bootstrap. Do not edit.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ParkObby = require(ReplicatedStorage:WaitForChild("Kit"):WaitForChild("ParkObby"))
ParkObby.startServer(require(ReplicatedStorage:WaitForChild("Config")))
