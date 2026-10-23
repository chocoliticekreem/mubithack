--!strict
-- FROZEN. Pure-Luau signal for server-internal (or client-internal) events between services.
-- Use this, not BindableEvents: Bindables deep-copy tables and drop metatables/functions.
--   FireService.Extinguished = Signal.new() :: Signal.Signal<BasePart, Player?>
--   FireService.Extinguished:Fire(part, player)
--   local conn = FireService.Extinguished:Connect(function(part, player) ... end)
-- Each handler runs on its own thread, so one failing listener cannot break the emitter.

export type Connection = { Disconnect: (self: Connection) -> () }
export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	Wait: (self: Signal<T...>) -> T...,
}

local Signal = {}

function Signal.new(): Signal<...any>
	local handlers: { [number]: (...any) -> () } = {}
	local nextId = 0
	local self = {} :: any

	function self.Connect(_: any, fn: (...any) -> ()): Connection
		nextId += 1
		local id = nextId
		handlers[id] = fn
		local conn = {} :: any
		function conn.Disconnect(_: any)
			handlers[id] = nil
		end
		return conn
	end

	function self.Once(s: any, fn: (...any) -> ()): Connection
		local conn: Connection
		conn = s:Connect(function(...)
			conn:Disconnect()
			fn(...)
		end)
		return conn
	end

	function self.Fire(_: any, ...: any)
		for _, fn in handlers do
			task.spawn(fn, ...)
		end
	end

	function self.Wait(s: any): ...any
		local thread = coroutine.running()
		s:Once(function(...)
			task.spawn(thread, ...)
		end)
		return coroutine.yield()
	end

	return self
end

return Signal
