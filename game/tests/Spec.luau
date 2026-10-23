--!strict
-- Tiny spec helper for pure-Luau tests run by the `luau` CLI (not synced into Studio).
--   local Spec = require("./Spec")
--   Spec.test("adds", function() Spec.eq(1 + 1, 2) end)
--   return Spec.finish()   -- prints a summary; errors (exit code 1) if anything failed
-- Modules under test must not touch Roblox APIs (game, workspace, Instance, Vector3, task) at all.

local Spec = {}

local passed, failed = 0, 0

function Spec.test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print(`  ok   {name}`)
	else
		failed += 1
		print(`  FAIL {name}: {err}`)
	end
end

function Spec.eq(actual: any, expected: any, label: string?)
	if actual ~= expected then
		error(`{label or "value"}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

function Spec.near(actual: number, expected: number, eps: number?, label: string?)
	if math.abs(actual - expected) > (eps or 1e-6) then
		error(`{label or "value"}: expected ~{expected}, got {actual}`, 2)
	end
end

function Spec.truthy(v: any, label: string?)
	if not v then
		error(`{label or "value"}: expected truthy, got {tostring(v)}`, 2)
	end
end

function Spec.errors(fn: () -> (), pattern: string?)
	local ok, err = pcall(fn)
	if ok then
		error("expected an error, got none", 2)
	end
	if pattern and not string.find(tostring(err), pattern) then
		error(`error "{tostring(err)}" does not match "{pattern}"`, 2)
	end
end

function Spec.finish()
	print(`{passed} passed, {failed} failed`)
	if failed > 0 then
		error(`{failed} spec(s) failed`, 0)
	end
end

return Spec
