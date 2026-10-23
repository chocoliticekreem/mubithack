--!strict
-- FROZEN (kickoff PR). Client twin of Main.server: boots every ModuleScript directly under
-- StarterPlayerScripts/Controllers whose name ends in "Controller". Same Priority / Enabled /
-- Init(self, controllers) / Start(self) contract. Controllers never trust themselves: they render
-- what the server replicated (attributes, tags) and send intents through Net.

local Controllers = script.Parent:WaitForChild("Controllers")

type Entry = { name: string, mod: any, priority: number, ok: boolean }

local controllers: { [string]: any } = {}
local entries: { Entry } = {}

for _, child in Controllers:GetChildren() do
	if not child:IsA("ModuleScript") or not string.match(child.Name, "Controller$") then
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
	controllers[child.Name] = mod
	table.insert(entries, { name = child.Name, mod = mod, priority = tonumber((mod :: any).Priority) or 100, ok = true })
end

table.sort(entries, function(a: Entry, b: Entry): boolean
	if a.priority ~= b.priority then
		return a.priority < b.priority
	end
	return a.name < b.name
end)

for _, e in entries do
	if type(e.mod.Init) == "function" then
		local ok, err = pcall(e.mod.Init, e.mod, controllers)
		if not ok then
			warn(`[Boot] {e.name}:Init failed: {err}`)
			e.ok = false
			controllers[e.name] = nil
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
