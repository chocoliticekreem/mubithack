--!strict
-- FROZEN. Helper for the per-system config modules in ReplicatedStorage/Config/*Config.luau.
--   return Config.define({ SpreadChance = 0.35, TickHz = 5 })
-- Adds Set(key, value) so a live playtest can be tuned without a resync:
--   ServerStorage.DevHook:Invoke("FireConfig", ".Set", "SpreadChance", 0.6)
-- (server copy only; client copies are separate). Read values at use time
-- (FireConfig.SpreadChance), never copy them into module-level locals, or tuning won't apply.

local Config = {}

function Config.define<T>(values: T): T
	local t = values :: any
	t.Set = function(key: string, value: any)
		if t[key] == nil then
			error(`[Config] unknown key {key}`)
		end
		t[key] = value
	end
	return values
end

return Config
