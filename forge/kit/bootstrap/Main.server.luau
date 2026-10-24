--!strict
-- Main: Forge's server bootstrap (prebuilt, installed by `forge consolidate`; the contract of the
-- reference game's ServerScriptService/Main.server.luau). Boots every ModuleScript directly under
-- ServerScriptService/Services whose name ends in "Service". Adding a service = adding a file.
--   1. require all (sorted by Priority, then name)   - no yields, no Instances at module top level
--   2. Init(self, services) on each                  - keep the peers table; no cross-calls, no yields
--   3. Start(self) on each, each on its own thread   - remotes, loops, cross-service calls
--      (BlocksBoot = true runs Start on the boot thread, so later services wait for it)
-- A service that errors in require/Init is dropped (warned, ForgeProbe records it); the rest run.
-- `Enabled = false` skips a service. No ServerBooted attribute: a service may still be building the
-- world in its Start, so a playtest's readiness stays "a player spawned".

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
		local function run()
			local ok, err = pcall(e.mod.Start, e.mod)
			if not ok then
				warn(`[Boot] {e.name}:Start failed: {err}`)
			end
		end
		if e.mod.BlocksBoot == true then
			run()
		else
			task.spawn(run)
		end
	end
end

print(`[Boot] server: {#entries} services`)
