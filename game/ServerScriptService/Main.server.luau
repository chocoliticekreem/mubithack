--!strict
-- FROZEN (kickoff PR). Boots every ModuleScript directly under ServerScriptService/Services whose
-- name ends in "Service". Adding a service = adding a file; nothing else changes.
--   1. require all (sorted by Priority, then name)   - no yields, no Instances at module top level
--   2. Init(self, services) on each                  - grab peers, create Signals; no cross-calls
--   3. Start(self) on each, each on its own thread   - remotes, loops, cross-service calls
-- A service that errors in require/Init is dropped (warned, ForgeProbe records it); the rest run.
-- A WIP service merged into main sets `Enabled = false` and is skipped.

local ServerScriptService = game:GetService("ServerScriptService")

type Entry = { name: string, mod: any, priority: number, ok: boolean }

local folder = ServerScriptService:WaitForChild("Services")
local services: { [string]: any } = {}
local entries: { Entry } = {}

for _, child in folder:GetChildren() do
	if not child:IsA("ModuleScript") or not string.match(child.Name, "Service$") then
		continue
	end
	local ok, mod = pcall(require, child)
	if not ok then
		warn(`[Boot] require {child.Name} failed: {mod}`)
		continue
	end
	if type(mod) ~= "table" or (mod :: any).Enabled == false then
		continue
	end
	services[child.Name] = mod
	table.insert(entries, {
		name = child.Name,
		mod = mod,
		priority = tonumber((mod :: any).Priority) or 100,
		ok = true,
	})
end

table.sort(entries, function(a: Entry, b: Entry): boolean
	if a.priority ~= b.priority then
		return a.priority < b.priority
	end
	return a.name < b.name
end)

for _, e in entries do
	if type(e.mod.Init) == "function" then
		local ok, err = pcall(e.mod.Init, e.mod, services)
		if not ok then
			warn(`[Boot] {e.name}:Init failed: {err}`)
			e.ok = false
			services[e.name] = nil
		end
	end
end

for _, e in entries do
	if e.ok and type(e.mod.Start) == "function" then
		task.spawn(function()
			local ok, err = pcall(e.mod.Start, e.mod)
			if not ok then
				warn(`[Boot] {e.name}:Start failed: {err}`)
			end
		end)
	end
end

workspace:SetAttribute("ServerBooted", true)
print(`[Boot] server: {#entries} services`)
