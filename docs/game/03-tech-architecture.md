# Flame and Blame: Roblox technical architecture for parallel development

This doc covers how three developers and Forge build one Roblox game at the same time without
editing the same files. The game itself is described in `docs/TARGET_GAME.md`, the Forge pipeline
in `docs/ARCHITECTURE.md`, and the Forge lanes (A Brain, B Studio, C Demo) in `docs/TEAM.md`. This
doc adds a second axis: **game lanes** (G1, G2, G3 and GF, the Forge lane) for the Luau under
`game/`.

The design is mostly the one that worked for intofire (`docs/reference/intofire/`: services with
`Init`/`Start`, Config, DevHook, pull sync). It changes the three things that caused conflicts
there:

1. **No hand-maintained service list.** intofire's `Main.server.luau` had an `ORDER` table that
   everyone edited. Here the bootstrap auto-discovers services.
2. **No shared `Remotes.luau`.** Each service declares its own remotes through a frozen `Net`
   helper.
3. **No single `Config.luau`.** Each system has its own config file.

After the kickoff PR (§10), adding a feature means **adding files**, not editing shared ones.

---

## 1. Folder and file layout

Each file has exactly one owner. `[K]` marks frozen kickoff files: they change only through a
small PR that every lane sees. `[RT]` is the Forge runtime (lane B), which the game never edits.

```
game/
  README.md                                   [RT]
  tools/  sync.py  make_place.py  pull.luau   [RT]  (not synced into Studio)
  tests/                                      pure-Luau unit tests run by `luau` in CI (§7), not synced
    Spec.luau  run.sh  config.spec.luau       [K]   tiny spec runner: `bash game/tests/run.sh`
    fire_sim.spec.luau                        [G1]
    awards.spec.luau                          [G3]
    mission_catalog.spec.luau                 [G3]  v1.5: MissionCatalog shape

  ServerScriptService/
    ForgeProbe.server.luau                    [RT]  error/counter collector + ServerStorage.DevHook
    Main.server.luau                          [K]   bootstrap: auto-discovers Services/*Service
    Services/                                 ONLY *Service modules here; one file per system
      MapService.luau                         [G2]  builds Workspace.Map from Lib/Map/Locations
      VehicleService.luau                     [G2]  fire truck (VehicleSeat), refill point, crew seats
      FireService.luau                        [G1]  fire simulation (§5)
      ToolService.luau                        [G1]  loadout, water tank, hose spray, axe/doors, refill
      MissionService.luau                     [G3]  round state machine, alarm, picks location + fires
      RescueService.luau                      [G3]  civilians/pets: spawn, carry, deliver, revive
      SquadService.luau                       [G3]  helmet numbers 1-4, spawn at station, first-person, downed
      BlameService.luau                       [G3]  listens to every signal, builds awards
      AtmosphereService.luau                  [G2]  Lighting presets (per location / mission in v1.5)
      LobbyService.luau                       [G3]  v1.5: station lobby, Mission Board, squads, launch
      HeatService.luau                        [G1]  v1.5: per-player Heat 0-100 near fire -> Downed
      HazardService.luau                      [GF]  v1.5 contract: electrocution, fire tornado, explosion, tidal wave
      FinaleService.luau                      [GF]  v2: dam detonator + tidal wave
    Lib/                                      helper modules, one folder per owning system
      Fire/FireSim.luau                       [G1]  pure step function (unit-testable)
      Map/MapKit.luau                         [G2]  part helpers: slab, wall, house, door, hydrant
      Map/Locations/StationBuilder.luau       [G2]  one builder per location (§4)
      Map/Locations/TownBuilder.luau          [G2]
      Map/Locations/ForestBuilder.luau        [GF]  v2
      Map/Locations/DamBuilder.luau           [GF]  v2
      Map/Props/TruckBuilder.luau             [G2]
      Rescue/NpcBuilder.luau                  [G3]  blocky civilians, dog, cat, panda, googly eyes
      Blame/Awards.luau                       [G3]  pure scoring (unit-testable)

  ReplicatedStorage/
    ForgeTelemetry.luau                       [RT]
    Shared/                                   [K]   all frozen after kickoff
      Net.luau                                      remote helper, rate limits, validators (§2, §6)
      Signal.luau                                   pure-Luau signal for service-to-service events
      Config.luau                                   Config.define helper (§3)
      Names.luau                                    every cross-system tag and attribute name
      Types.luau                                    cross-system types (RoundState, Award, ...)
      Ragdoll.luau                                  v1.5: Ragdoll.enable/knockback (contract [K], body [G1])
      Palette.luau                                  colour tokens from docs/game/02 §1
    Config/                                   one file per system, owned by that system's lane
      GameConfig.luau                         [G3]  round length, max players, phases
      MapConfig.luau                          [G2]  seed, slot size, location slots
      VehicleConfig.luau                      [G2]
      FireConfig.luau                         [G1]
      ToolConfig.luau                         [G1]
      RescueConfig.luau                       [G3]
      BlameConfig.luau                        [G3]
      HazardConfig.luau                       [GF]
      AtmosphereConfig.luau                   [G2]  presets + LocationPresets (v1.5)
      MissionCatalog.luau                     [G3]  v1.5: data-only list of the trailer missions
      LobbyConfig.luau                        [G3]  v1.5
      HeatConfig.luau                         [G1]  v1.5
      PhysicsConfig.luau                      [G1]  v1.5: first person, ragdoll, knockback

  StarterPlayerScripts/
    Main.client.luau                          [K]   bootstrap: auto-discovers Controllers/*Controller
    Controllers/
      HudController.luau                      [G3]  water gauge, timer, Notify toasts
      ResultsController.luau                  [G3]  Blame awards screen
      RescueController.luau                   [G3]  carry prompt hints, drop key
      FireFxController.luau                   [G1]  Burning tag -> local particles/lights (§5)
      ToolController.luau                     [G1]  hose aim + spray input, water beam, axe feel
      VehicleController.luau                  [G2]  truck camera, siren light, horn
      AlarmController.luau                    [G2]  station alarm light + screen flash
      HazardController.luau                   [GF]  v1.5 contract: zap flash, tornado/explosion/wave fx
      LobbyController.luau                    [G3]  v1.5: Mission Board UI, squad roster, launch
      FirstPersonController.luau              [G1]  v1.5: camera lock, viewmodel gloves, head bob, shake
      PhysicsFxController.luau                [G1]  v1.5: applies Shared/Ragdoll + hose recoil locally
    ClientLib/
      UiKit.luau                              [G3]  shared UI builders (frames, labels, tweens)
```

**Lanes.** Each lane owns a whole vertical slice (server service, its config, its controller and
its helpers), so one feature usually touches one lane only.

| Lane | Systems | Demo goal (v1, `TARGET_GAME.md`) |
|---|---|---|
| **G1 Fire & tools** | FireService, ToolService, FireConfig, ToolConfig, FireFxController, ToolController, Lib/Fire; v1.5: HeatService, HeatConfig, PhysicsConfig, `Shared/Ragdoll` body, FirstPerson/PhysicsFxController | Fires spread; hose with a tank that refills; axe breaks locked doors |
| **G2 World & truck** | MapService (+ v1.5 instances), VehicleService, AtmosphereService, Map builders, MapConfig, VehicleConfig, AtmosphereConfig, VehicleController, AlarmController | Station plus a town block of 3-5 houses, built from code; truck at the station |
| **G3 Loop & people** | MissionService, RescueService, SquadService, BlameService, configs, Hud/Results/Rescue controllers, UiKit; v1.5: LobbyService, LobbyController, LobbyConfig, MissionCatalog | 3-minute round, carry civilians and pets to the truck, Blame results screen |
| **GF Forge** | New files only: HazardService (v1.5 contract), FinaleService, Forest/Dam builders, HazardController, HazardConfig | v2 chaos features, each landing as new files |

Naming rules, which tooling relies on:
- **Every ModuleScript name is unique across the whole game.** DevHook (`ForgeProbe`) finds
  modules by name across all descendants of ServerScriptService, ServerStorage and
  ReplicatedStorage, and returns the first match. Suffixes make this easy: `*Service`,
  `*Controller`, `*Config`, `*Builder`.
- File name = instance name: PascalCase, no spaces, `.luau` only (`sync.py` only reads `*.luau`).
- No `init.luau`. `sync.py` has no init-script support (a folder is always a Folder), so `init`
  would become a module named "init".
- Only scripts sync, so **everything else is built from code**: the map, the tools (`Tool`
  instances made by ToolService), the UI (made by controllers into `PlayerGui`), the NPCs and the
  truck. Nothing needs to exist in the `.rbxlx` except what `make_place.py` creates (baseplate
  and spawn).

---

## 2. The service contract

A service is a ModuleScript that returns a table:

| Field | Required | Meaning |
|---|---|---|
| `Init(self, services)` | optional | Store `services` (name → module table). Create Signals. **No calls into other services and no yields.** |
| `Start(self)` | optional | Runs on its own thread after every `Init`. Declare remotes, connect events, start loops, call other services. |
| `Priority: number` | optional (default 100) | Lower numbers Init and Start first. MapService = 0, SquadService = 10, everything else ≥ 50. Use it rarely and wait on readiness instead (below). |
| `Enabled: boolean` | optional | `false` = the bootstrap skips it. Lets half-finished work merge into `main` without breaking it. |
| Signals (`X.Something`) | per contract | Events other services listen to (Signal module, not BindableEvents). |
| `_name(...)` | test hooks | Underscore methods are for DevHook/tests only, never for gameplay code. `_selftest()` is standard (§7). |

**How services find each other.** Through the `services` table passed to `Init`, never through a
top-level `require` of another service, because two services that require each other would form a
cycle. Peers can be missing (WIP lanes, `Enabled = false`, a failed `Init`), so **every
cross-service call is nil-guarded**:

```lua
local Rescue = services.RescueService
if Rescue then Rescue:Deliver(player) end
```

**Readiness.** MapService builds the map in `Start` and then sets
`workspace:SetAttribute("MapReady", true)` and fires `MapService.LocationBuilt(model, id)` for
each location. Services that need the map listen to `LocationBuilt` and also handle locations that
are already built (`MapService:GetLocations()`). Do not rely on `Start` order.

**Events.** Use `Shared/Signal` (pure Luau): `FireService.Extinguished:Connect(fn)`. The emitter
owns the signal and declares it in its header comment and in §10. Listeners (BlameService,
MissionService, ForgeTelemetry counters) subscribe in `Start`. Avoid BindableEvents: they copy
tables (an intofire bug: `ProfileLoaded` handed out stale copies).

**Remotes, declared per service.** No `Remotes.luau`. A service calls `Net.event("Tool", "Spray")`
in `Start`. On the server that creates `ReplicatedStorage.Net.Tool.Spray`; on the client the same
call waits for it. Namespace = the owning system, so two lanes can never collide. The list of
names is the contract in §10. Never create remotes at module top level, because Edit-mode
`require` (Forge's checks, the command bar) must not create Instances.

Prefer, in this order:
1. **Replicated state**: attributes and CollectionService tags, which the server writes and
   clients read.
2. **ProximityPrompts**: `Triggered` fires on the server, so carry, revive, refill and open/break
   door need no remote at all.
3. **`Tool.Activated` on the server**: it fires there too, so the axe needs no remote.
4. A **remote**, only when the server needs client-only data (the hose aim direction) or for
   one-shot UI pushes (results, notify).

### Bootstrap (`ServerScriptService/Main.server.luau`)

```lua
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
```

`DevHook` is not created here. `ForgeProbe.server.luau` already provides
`ServerStorage.DevHook`, and because it `require`s the same ModuleScript in the same VM, it gets
the live service tables that this bootstrap started.

### Client bootstrap (`StarterPlayerScripts/Main.client.luau`)

```lua
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
```

### Signal (`ReplicatedStorage/Shared/Signal.luau`)

```lua
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
```

### Service template (`ServerScriptService/Services/FireService.luau`)

This is a real skeleton for the most complex system, not a placeholder. Copy its shape: a header
comment listing the API, signals, writes and test hooks; peers taken in `Init`; work started in
`Start`; numbers read from its own config; underscore test hooks.

```lua
--!strict
-- FireService [owner: G1]. Fire simulation on parts tagged "Flammable" (built by MapService).
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   FireService:Ignite(part: BasePart, cause: Player?): boolean
--   FireService:ApplyWater(player: Player?, origin: Vector3, aim: Vector3, litres: number): number
--   FireService:IsBurning(part: BasePart): boolean
--   FireService:CountBurning(locationId: string?): number
--   FireService:ExtinguishAll()
-- Signals: Ignited(part, cause: Player?), Spread(from, to), Extinguished(part, by: Player?),
--          Charred(part)
-- Writes: tag "Burning"; attrs FireLevel (1..3), Charred (bool) on Flammable parts.
-- Test hooks (DevHook only): _ignite(pos), _selftest()

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local FireConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("FireConfig") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)

type Cell = {
	part: BasePart,
	heat: number, -- 0..100, server only, never replicated
	fuel: number, -- seconds of burning left
	state: number, -- 0 idle, 1 burning, 2 charred
	level: number, -- last replicated FireLevel (0 = none)
	neighbors: { Cell },
	location: string,
	cause: Player?, -- who lit it (for Blame)
}

local FireService = {}
FireService.Priority = 50
FireService.Ignited = Signal.new() :: Signal.Signal<BasePart, Player?>
FireService.Spread = Signal.new() :: Signal.Signal<BasePart, BasePart>
FireService.Extinguished = Signal.new() :: Signal.Signal<BasePart, Player?>
FireService.Charred = Signal.new() :: Signal.Signal<BasePart>

local services: { [string]: any } = {}
local cells: { [BasePart]: Cell } = {}
local burning: { [Cell]: true } = {}
local burningCount = 0

local function setLevel(c: Cell)
	local level = if c.state ~= 1 then 0 elseif c.heat > 80 then 3 elseif c.heat > 50 then 2 else 1
	if level == c.level then
		return -- replicate transitions only
	end
	c.level = level
	c.part:SetAttribute(Names.Attr.FireLevel, if level > 0 then level else nil)
end

local function startBurning(c: Cell, cause: Player?)
	if c.state ~= 0 or burningCount >= FireConfig.MaxBurning then
		return
	end
	c.state, c.cause = 1, cause
	c.heat = math.max(c.heat, FireConfig.IgniteAt)
	burning[c] = true
	burningCount += 1
	c.part:AddTag(Names.Tag.Burning)
	setLevel(c)
end

local function stopBurning(c: Cell, charred: boolean)
	burning[c] = nil
	burningCount -= 1
	c.part:RemoveTag(Names.Tag.Burning)
	c.state = if charred then 2 else 0
	setLevel(c)
	if charred then
		c.part:SetAttribute(Names.Attr.Charred, true)
		c.part.Color = FireConfig.CharredColor
		FireService.Charred:Fire(c.part)
	end
end

local function step(dt: number)
	local t0 = os.clock()
	local lit: { { from: Cell, to: Cell } } = {} -- never add keys to `burning` while iterating it
	for c in burning do
		c.fuel -= dt
		if c.fuel <= 0 then
			stopBurning(c, true)
			continue
		end
		for _, n in c.neighbors do
			if n.state == 0 then
				n.heat += FireConfig.SpreadHeatPerSecond * dt
				if n.heat >= FireConfig.IgniteAt then
					table.insert(lit, { from = c, to = n })
				end
			end
		end
		c.heat = math.min(100, c.heat + FireConfig.GrowPerSecond * dt)
		setLevel(c)
	end
	for _, e in lit do
		if e.to.state == 0 and burningCount < FireConfig.MaxBurning then
			startBurning(e.to, e.from.cause)
			FireService.Spread:Fire(e.from.part, e.to.part)
			Telemetry.count("fires_spread")
		end
	end
	if (os.clock() - t0) * 1000 > FireConfig.TickBudgetMs then
		Telemetry.count("fire_tick_over_budget")
	end
end

local function index(model: Instance, locationId: string)
	-- neighbors: other Flammable parts within SpreadRadius (spatial hash keeps this O(n))
	local grid: { [string]: { Cell } } = {}
	local size = FireConfig.SpreadRadius
	local list: { Cell } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:HasTag(Names.Tag.Flammable) then
			local c: Cell = {
				part = d, heat = 0, fuel = (d:GetAttribute(Names.Attr.Fuel) :: number?) or FireConfig.DefaultFuel,
				state = 0, level = 0, neighbors = {}, location = locationId, cause = nil,
			}
			cells[d] = c
			table.insert(list, c)
			local key = `{d.Position.X // size},{d.Position.Y // size},{d.Position.Z // size}`
			grid[key] = grid[key] or {}
			table.insert(grid[key], c)
		end
	end
	for _, c in list do
		local p = c.part.Position
		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					local key = `{p.X // size + dx},{p.Y // size + dy},{p.Z // size + dz}`
					for _, n in grid[key] or {} do
						if n ~= c and (n.part.Position - p).Magnitude <= size then
							table.insert(c.neighbors, n)
						end
					end
				end
			end
		end
	end
end

function FireService:Init(all: { [string]: any })
	services = all
end

function FireService:Start()
	local MapService = services.MapService
	if MapService then
		MapService.LocationBuilt:Connect(index) -- (model, locationId), also fires on rebuild
		for id, model in MapService:GetLocations() do
			index(model, id)
		end
	end
	local acc = 0
	game:GetService("RunService").Heartbeat:Connect(function(dt: number)
		acc += dt
		local period = 1 / FireConfig.TickHz
		if acc >= period then
			acc -= period
			step(period)
		end
	end)
end

function FireService:Ignite(part: BasePart, cause: Player?): boolean
	local c = cells[part]
	if not c or c.state ~= 0 then
		return false
	end
	startBurning(c, cause)
	FireService.Ignited:Fire(part, cause)
	return true
end

function FireService:ApplyWater(player: Player?, origin: Vector3, aim: Vector3, litres: number): number
	local hit = 0
	local reach = FireConfig.HoseRange
	for c in burning do
		local to = c.part.Position - origin
		if to.Magnitude <= reach and to.Unit:Dot(aim) >= FireConfig.HoseConeCos then
			c.heat -= FireConfig.CoolPerLitre * litres
			hit += 1
			if c.heat <= FireConfig.ExtinguishAt then
				stopBurning(c, false)
				FireService.Extinguished:Fire(c.part, player)
				Telemetry.count("fires_extinguished")
			else
				setLevel(c)
			end
		end
	end
	return hit
end

function FireService:IsBurning(part: BasePart): boolean
	local c = cells[part]
	return c ~= nil and c.state == 1
end

function FireService:CountBurning(locationId: string?): number
	if not locationId then
		return burningCount
	end
	local n = 0
	for c in burning do
		if c.location == locationId then
			n += 1
		end
	end
	return n
end

function FireService:ExtinguishAll()
	for c in burning do
		stopBurning(c, false)
	end
end

-- test hooks -------------------------------------------------------------------------------
function FireService:_ignite(pos: Vector3): BasePart?
	local best, bestD = nil :: Cell?, math.huge
	for _, c in cells do
		local d = (c.part.Position - pos).Magnitude
		if c.state == 0 and d < bestD then
			best, bestD = c, d
		end
	end
	if best then
		self:Ignite(best.part, nil)
		return best.part
	end
	return nil
end

function FireService:_selftest(): (boolean, string)
	local part = self:_ignite(Vector3.zero)
	if not part then
		return false, "no Flammable parts indexed"
	end
	if not CollectionService:HasTag(part, Names.Tag.Burning) then
		return false, "Ignite did not tag Burning"
	end
	self:ApplyWater(nil, part.Position + Vector3.new(0, 0, 5), Vector3.new(0, 0, -1), 1000)
	if self:IsBurning(part) then
		return false, "ApplyWater did not extinguish"
	end
	return true, "ok"
end

return FireService
```

A minimal service has the same shape with less in it:

```lua
--!strict
-- RescueService [owner: G3]. API: ... Signals: ... Writes: ... Test hooks: ...
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.Shared.Signal)
local RescueConfig = require(ReplicatedStorage.Config.RescueConfig)

local RescueService = {}
RescueService.Rescued = Signal.new() :: Signal.Signal<Player, string, string> -- player, rescueId, kind

local services: { [string]: any } = {}

function RescueService:Init(all: { [string]: any })
	services = all
end

function RescueService:Start()
	-- remotes: local Drop = Net.event("Rescue", "Drop"); Net.onServer(Drop, { rate = 2 }, ...)
	-- prompts, Heartbeat loops, signal subscriptions go here
end

function RescueService:_selftest(): (boolean, string)
	return true, "ok"
end

return RescueService
```

### Controller template (`StarterPlayerScripts/Controllers/FireFxController.luau`)

Controllers render replicated state and send intents. They never decide outcomes.

```lua
--!strict
-- FireFxController [owner: G1]. Client-only fire visuals. The server replicates only the tag
-- "Burning" and the attr FireLevel (1..3); this controller turns them into local ParticleEmitters
-- and PointLights, nearest first, within a budget. Nothing here affects gameplay.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local FireConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("FireConfig") :: ModuleScript)

type Fx = { emitter: ParticleEmitter, light: PointLight?, attachment: Attachment }

local FireFxController = {}
FireFxController.Priority = 50

local fx: { [BasePart]: Fx } = {}
local burning: { [BasePart]: true } = {}

local function clear(part: BasePart)
	local f = fx[part]
	if f then
		f.attachment:Destroy() -- destroys emitter and light with it
		fx[part] = nil
	end
end

local function apply(part: BasePart, withLight: boolean)
	local level = (part:GetAttribute(Names.Attr.FireLevel) :: number?) or 1
	local f = fx[part]
	if not f then
		local a = Instance.new("Attachment")
		a.Name = "FireFx"
		local e = Instance.new("ParticleEmitter")
		e.LightEmission = 1
		e.Color = ColorSequence.new(Color3.fromRGB(255, 170, 40), Color3.fromRGB(255, 60, 20))
		e.Parent = a
		a.Parent = part
		f = { emitter = e, light = nil, attachment = a }
		fx[part] = f
	end
	local current = f :: Fx
	current.emitter.Rate = 6 * level
	current.emitter.Size = NumberSequence.new(1 + level, 0)
	if withLight and not current.light then
		local l = Instance.new("PointLight")
		l.Color = Color3.fromRGB(255, 140, 50)
		l.Range = 12
		l.Parent = current.attachment
		current.light = l
	elseif not withLight and current.light then
		current.light:Destroy()
		current.light = nil
	end
end

-- Re-rank by distance a few times a second; only the nearest MaxClientFx get effects.
local function refresh()
	local char = Players.LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local list: { { part: BasePart, d: number } } = {}
	for part in burning do
		table.insert(list, { part = part, d = (part.Position - root.Position).Magnitude })
	end
	table.sort(list, function(a, b)
		return a.d < b.d
	end)
	local keep: { [BasePart]: boolean } = {}
	for i, item in list do
		if i > FireConfig.MaxClientFx or item.d > FireConfig.FxDistance then
			break
		end
		keep[item.part] = true
		apply(item.part, i <= FireConfig.MaxClientLights)
	end
	for part in fx do
		if not keep[part] then
			clear(part)
		end
	end
end

function FireFxController:Init(_controllers: { [string]: any }) end

function FireFxController:Start()
	local function added(inst: Instance)
		if inst:IsA("BasePart") then
			burning[inst] = true
		end
	end
	local function removed(inst: Instance)
		if inst:IsA("BasePart") then
			burning[inst] = nil
			clear(inst)
		end
	end
	CollectionService:GetInstanceAddedSignal(Names.Tag.Burning):Connect(added)
	CollectionService:GetInstanceRemovedSignal(Names.Tag.Burning):Connect(removed)
	for _, inst in CollectionService:GetTagged(Names.Tag.Burning) do
		added(inst)
	end
	while true do
		refresh()
		task.wait(0.25)
	end
end

return FireFxController
```

---

## 3. Config split per system

- `ReplicatedStorage/Shared/Config.luau` [K] is only a helper. `Config.define(table)` adds
  `Set(key, value)` for live tuning.
- One `ReplicatedStorage/Config/<System>Config.luau` per system, edited only by its lane. It lives
  in ReplicatedStorage because client effects read it too (FireFxController reads
  `FireConfig.MaxClientFx`). **Nothing secret goes in it.**
- Cross-system numbers live with the system that **owns the behaviour**, and other lanes read
  them. Round length is in `GameConfig` (G3); FireService reads `GameConfig.RoundSeconds` if it
  needs it, and never redefines it.
- Live tuning during a playtest (server copy):
  `ServerStorage.DevHook:Invoke("FireConfig", ".Set", "SpreadHeatPerSecond", 25)`. This works
  because code reads `FireConfig.X` each time it's used, never as a cached top-level local.

```lua
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
```

```lua
--!strict
-- FireConfig [owner: G1]. Every fire number lives here; nothing else reads or writes it.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	TickHz = 5, -- simulation steps per second
	TickBudgetMs = 2, -- step() slower than this bumps fire_tick_over_budget
	MaxBurning = 120, -- hard cap; spread pauses at the cap
	SpreadRadius = 8, -- studs; also the spatial-hash cell size
	SpreadHeatPerSecond = 14, -- heat a burning part adds to each idle neighbour
	GrowPerSecond = 6,
	IgniteAt = 40,
	ExtinguishAt = 10,
	DefaultFuel = 45, -- seconds a part burns before it is Charred
	CharredColor = Color3.fromRGB(35, 30, 28),
	HoseRange = 28,
	HoseConeCos = 0.94, -- ~20 degree cone
	CoolPerLitre = 9,
	-- client effects budget
	MaxClientFx = 40,
	MaxClientLights = 10,
	FxDistance = 180,
})
```

---

## 4. Map building from code

The map is **generated at server start**, never stored in the place. That keeps `.rbxlx` out of
git and lets G2 and GF add locations in parallel.

- **MapService** [G2] discovers every ModuleScript in `Lib/Map/Locations/` whose name ends in
  `Builder` (the same auto-discovery as the bootstrap). Each builder exports
  `{ Id: string, Slot: number, Build(model, origin, rng) }`.
- **Slots, not coordinates.** `MapConfig.SlotOrigin(slot)` gives each location its own 400×400
  stud square on a grid: Station = slot 0 at the origin, Town = 1, Forest = 2, Dam = 3. Two
  builders can never overlap, and a new location only needs a free slot number.
- **Deterministic seeds.** `rng = Random.new(MapService:GetSeed() + MapKit.hash(Id))`. **No
  `math.random` and no `Random.new()` without a seed in builders.** Each live server rolls its own
  map seed (Workspace attr `MapSeed`) so the city varies from server to server: layout, incident
  sites, colours, season, time of day and weather (`Lib/Map/City/MapVariant`). Set `MapSeed` (and
  optionally `MapSeason` / `MapSky` / `MapWeather`) before Play to reproduce a server; Edit previews
  and the Station always use `MapConfig.Seed`. The same seed always gives the same town, so:
  - a bug report "door at House3 won't break" points at the same door on every machine;
  - **round reset = `MapService:RebuildLocation(id)`**, so no service has to undo its own damage.
    MapService destroys the location model, builds it again, and fires `LocationBuilt`. FireService
    re-indexes, and RescueService respawns.
  - Forge screenshots of iteration N and N+1 are comparable.
- **Building, done quickly:** builders create parts under an **unparented** Model, and MapService
  parents each finished location once (the cost of setting `.Parent` scales with the subtree size).
  A location should be ≤ 3,000 parts and build in < 0.5 s. Everything is `Anchored`, and
  `CanTouch = false` except on trigger volumes.
- **Semantics through tags and attributes, not names.** Builders tag what other systems need
  (`Flammable`, `Door`, `Hydrant`, `TruckRefill`, `RescueDropoff`, `StationSpawn`, `Window`,
  `WetFloor`, `FuseBox`) and set `LocationId` and `BuildingId`. Large flammable surfaces are
  split into chunks ≤ 8 studs (`MapKit.wall` does it) so fire can be local.
- **MapKit** [G2] is the only helper builders use (slab, wall, house, door, window, hydrant,
  `pick(rng, list)`, `WarmColors`). GF builders use MapKit and never edit it; if they need a new
  helper, they ask G2 or keep a local function in their builder.
- **Edit-mode preview for screenshots:** builders are plain functions, so Forge (or a dev) can run
  them from `execute_luau` in the Edit datamodel, take a `screen_capture`, and then **delete the
  preview**. Edit-mode Workspace must stay clean (rule carried over from intofire).

```lua
--!strict
-- TownBuilder [owner: G2]. One location = one builder module in ServerScriptService/Lib/Map/Locations.
-- MapService discovers every *Builder here; adding a location needs no edit anywhere else.
-- Pure function of (origin, rng): same seed -> same town, so a rebuild resets the round exactly.
local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)

local TownBuilder = {}
TownBuilder.Id = "Town"
TownBuilder.Slot = 1 -- MapConfig.SlotOrigin(1): each location gets its own 400x400 stud slot

function TownBuilder.Build(model: Model, origin: CFrame, rng: Random)
	MapKit.slab(model, "Ground", origin, Vector3.new(380, 1, 380), Color3.fromRGB(110, 150, 80))
	for i = 1, 4 do
		local at = origin * CFrame.new(-120 + (i - 1) * 80, 0, rng:NextInteger(-20, 20))
		local house = MapKit.house(model, `House{i}`, at, {
			floors = rng:NextInteger(1, 2),
			color = MapKit.pick(rng, MapKit.WarmColors),
			lockedDoor = rng:NextNumber() < 0.5, -- axe target
		})
		house:SetAttribute("BuildingId", `Town.House{i}`)
	end
	MapKit.hydrant(model, origin * CFrame.new(0, 0, 60))
end

return TownBuilder
```

MapService API: `GetLocation(id): Model?`, `GetLocations(): {[string]: Model}`,
`RebuildLocation(id)`, `GetSpawnCFrame(slot: number): CFrame`, `RandomFlammable(id, rng): BasePart?`,
signal `LocationBuilt(model, id)`, Workspace attribute `MapReady`.

---

## 5. Fire simulation: data model and performance budget

**Unit of fire: the part (a "cell" = one `Flammable` BasePart), not a voxel grid.** Houses are
already made of parts, so a part-level sim needs no extra geometry, maps directly onto what
players see and hit with water, and replicates as attributes on existing instances. Grass and
floors are tiled as 8×8 flammable parts, which gives a grid where one is wanted (the forest in v2)
using the same code.

| | Server-only (FireService table) | Replicated |
|---|---|---|
| per cell | `heat` 0-100, `fuel` seconds, `state` idle/burning/charred, `neighbors` (precomputed), `cause` Player | tag `Burning`; attribute `FireLevel` 1-3 (quantized); attribute `Charred`; `Color` when charred |
| global | burning set, count, per-location index | nothing (clients count tags themselves) |

- **Neighbours are computed once per `LocationBuilt`** with a spatial hash (cell size =
  `SpreadRadius`, 8 studs). Parts are anchored, so this never runs again during a round.
- **Tick: 5 Hz** (`FireConfig.TickHz`), driven by a Heartbeat accumulator. Each step does work for
  the **burning set only**: burning parts × their neighbours (≈ 120 × 8 ≈ 1,000 operations), with
  no `workspace` queries. Ignitions are collected and applied after the loop (Luau must not add
  keys to a table while iterating it).
- **Water:** `ApplyWater` checks only the burning set against the spray cone (dot product plus
  range, no raycasts). ToolService calls it at ≤ 12 Hz per player.
- **Caps:** `MaxBurning = 120` (spread pauses at the cap, which keeps runaway fires playable) and
  ≤ 1,500 Flammable parts per location.
- **Replicate transitions, not values.** Heat changes every tick but never leaves the server.
  Clients see a tag add/remove when a part ignites or goes out, and a `FireLevel` change when the
  bucket changes. Expected traffic is < 50 attribute/tag changes per second at peak.
- **Visuals are client-only.** FireFxController creates particles and lights locally, nearest
  first: at most 40 emitters and 10 PointLights, within 180 studs, re-ranked 4× per second. The
  server never creates `Fire`/`ParticleEmitter` instances for fires, because hundreds of replicated
  instances are the main lag risk. Smoke columns are per `BuildingId` once it has ≥ 3 burning parts.
- **Player damage:** at 2 Hz, the server checks each character against burning cells in its
  spatial-hash bucket (SquadService owns health and `Downed`; FireService reports "hot here").

Budget, checked in playtests through ForgeProbe:

| Metric | Budget | How it's measured |
|---|---|---|
| Fire step time | ≤ 2 ms per step | `fire_tick_over_budget` counter must stay ~0 |
| All server game logic | ≤ 4 ms per frame on average | Studio MicroProfiler during a per-dev playtest |
| Instances in a running game | ≤ 15,000 | `instances` in the ForgeProbe report |
| Map build | ≤ 2 s total | MapService prints the timing; `map_build_ms` counter |
| Client | 60 FPS with 4 players and 120 fires on a laptop | 2-client local test before merging FX changes |
| Remote traffic | client → server ≤ 15 events/s per player | Net rate limits; `net_dropped` counter |

---

## 6. Networking and security

The server is authoritative for everything that scores, damages, rescues or burns. Clients send
**intents**, never outcomes. The server decides, then replicates state (attributes and tags).

- **All client → server remotes go through `Net.onServer(remote, {rate, burst}, handler)`**: a
  per-player token bucket. Excess calls are dropped and counted (`net_dropped`), and handler
  errors are caught and logged. There are no kicks during the hackathon.
- **Validate every argument** with the `Net` validators: type (`typeof`), NaN, magnitude
  (`Net.unit`), the instance is tagged and in Workspace (`Net.tagged`), and distance from the
  character the server knows about (`Net.near`). Then check game state: the right tool is
  equipped, `Water > 0`, and the round is active (where that matters).
- **Positions come from the server's view of the character** (Head/HumanoidRootPart), never from
  an argument. The hose remote sends only an aim direction.
- **No `RemoteFunction:InvokeClient`**, ever (a client can hang the server). Client → server
  RemoteFunctions only for request/response UI (none are needed in v1).
- **Network ownership:** the truck is owned by its driver (the VehicleSeat default). Carried
  NPCs are welded to the carrier, set `Massless`, and their root's network owner is the carrier
  (no jitter). Idle NPCs are anchored.
- **Studio-only surfaces:** `ForgeProbe`, `DevHook` and every `_hook` only run under
  `RunService:IsStudio()` or are reachable only through ServerStorage (which clients can't see).

```lua
--!strict
-- FROZEN. Remotes are declared by the service that owns them, not in a shared Remotes file.
-- They live at ReplicatedStorage.Net.<Namespace>.<Name>. Call these from Init/Start only, never at
-- module top level (Edit-mode requires must not create Instances).
--
--   Server: local Spray = Net.event("Tool", "Spray")                       -- creates it
--           Net.onServer(Spray, { rate = 12, burst = 4 }, function(player, aim) ... end)
--   Client: local Spray = Net.event("Tool", "Spray")                       -- waits for it
--           Spray:FireServer(aim)
--   Either: Net.notify(player | "all", "Panda saved!", "good")             -- Shared/Notify toast

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()
local WAIT_SECONDS = 15

local Net = {}

local function child(parent: Instance, name: string, className: string): Instance
	local found = parent:FindFirstChild(name)
	if found then
		return found
	end
	if not IS_SERVER then
		local waited = parent:WaitForChild(name, WAIT_SECONDS)
		if not waited then
			error(`[Net] {parent:GetFullName()}.{name} never appeared (server didn't declare it?)`)
		end
		return waited
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst
end

local function namespace(ns: string): Instance
	return child(child(ReplicatedStorage, "Net", "Folder"), ns, "Folder")
end

function Net.event(ns: string, name: string): RemoteEvent
	return child(namespace(ns), name, "RemoteEvent") :: RemoteEvent
end

-- Client -> server request/response only. Never InvokeClient.
function Net.func(ns: string, name: string): RemoteFunction
	return child(namespace(ns), name, "RemoteFunction") :: RemoteFunction
end

-- Token bucket per player: `rate` events/second sustained, `burst` extra. Excess calls are dropped
-- and counted as ForgeTelemetry "net_dropped". Handler errors are caught and warned.
export type Limit = { rate: number, burst: number? }

function Net.onServer(remote: RemoteEvent, limit: Limit, handler: (Player, ...any) -> ())
	assert(IS_SERVER, "Net.onServer is server-only")
	local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
	local cap = limit.rate + (limit.burst or 0)
	local tokens: { [Player]: number } = {}
	local stamp: { [Player]: number } = {}
	remote.OnServerEvent:Connect(function(player: Player, ...: any)
		local t = os.clock()
		local have = math.min(cap, (tokens[player] or cap) + (t - (stamp[player] or t)) * limit.rate)
		stamp[player] = t
		if have < 1 then
			tokens[player] = have
			Telemetry.count("net_dropped")
			return
		end
		tokens[player] = have - 1
		local ok, err = pcall(handler, player, ...)
		if not ok then
			warn(`[Net] {remote:GetFullName()} handler: {err}`)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		tokens[player] = nil
		stamp[player] = nil
	end)
end

-- Validators: return the value if valid, else nil. Use on every client argument.
function Net.unit(v: any): Vector3?
	if typeof(v) ~= "Vector3" then
		return nil
	end
	local m = (v :: Vector3).Magnitude
	if m ~= m or m < 0.5 or m > 1.5 then -- NaN or not roughly unit length
		return nil
	end
	return (v :: Vector3).Unit
end

function Net.tagged(v: any, tag: string): BasePart?
	if typeof(v) ~= "Instance" or not (v :: Instance):IsA("BasePart") then
		return nil
	end
	if not (v :: Instance):HasTag(tag) or not (v :: Instance):IsDescendantOf(workspace) then
		return nil
	end
	return v :: BasePart
end

function Net.near(player: Player, pos: Vector3, maxStuds: number): boolean
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	return root ~= nil and (root.Position - pos).Magnitude <= maxStuds
end

-- Shared/Notify: server -> client toast; HudController renders it.
function Net.notify(target: Player | string, text: string, kind: string?)
	local remote = Net.event("Shared", "Notify")
	if target == "all" then
		remote:FireAllClients(text, kind or "info")
	elseif typeof(target) == "Instance" then
		remote:FireClient(target :: Player, text, kind or "info")
	end
end

return Net
```

Usage in ToolService (G1):

```lua
local Spray = Net.event("Tool", "Spray")
Net.onServer(Spray, { rate = 12, burst = 4 }, function(player: Player, rawAim: any)
	local aim = Net.unit(rawAim)
	local head = player.Character and player.Character:FindFirstChild("Head") :: BasePart?
	if not aim or not head or not player.Character:FindFirstChild("Hose") then
		return
	end
	local water = (player:GetAttribute(Names.Attr.Water) :: number?) or 0
	local litres = math.min(water, ToolConfig.LitresPerSpray)
	if litres <= 0 then
		return
	end
	player:SetAttribute(Names.Attr.Water, water - litres)
	Telemetry.count("water_used", litres)
	local Fire = services.FireService
	if Fire then
		Fire:ApplyWater(player, head.Position, aim, litres)
	end
end)
```

---

## 7. Testing strategy

From cheapest to most expensive. Each layer catches what the previous one can't.

1. **Compile check (CI, already there).** `python3 game/tools/sync.py check --root game` runs
   `luau-compile --null` on every synced file, on every PR. Run it locally before pushing.
2. **Pure-Luau unit tests (CI, proposed for lane B).** Logic that doesn't touch Roblox APIs
   (`Lib/Fire/FireSim`, `Lib/Blame/Awards`, the `Net` validators' maths) lives in modules with no
   `game:`, `workspace`, `Vector3` or `task` at top level. `game/tests/*.spec.luau` require them by
   relative path and run under the plain `luau` CLI (`luau game/tests/fire_sim.spec.luau`; it
   exits non-zero on `assert` failure). The `tests/` folder is outside the synced roots, so it
   never reaches Studio. Add one CI step: `for f in game/tests/*.spec.luau; do luau "$f" || exit 1; done`.
3. **Boot smoke (Studio MCP, every sync).** `start_stop_play(true)` → `execute_luau` (Server DM)
   waits for `workspace:GetAttribute("ServerBooted")` and `MapReady` → returns
   `ServerStorage.ForgeProbe:Invoke("report")` → `errors` must be `[]` → `start_stop_play(false)`.
   A broken service shows up as a `[Boot] X:Init failed` warning in the report.
4. **Service self-tests through DevHook (Studio MCP, Server DM, during play).** Every service
   implements `_selftest(): (boolean, string)`. One runner covers all of them, and new services
   are picked up automatically:
   ```lua
   local HttpService = game:GetService("HttpService")
   local out = {}
   for _, m in game.ServerScriptService.Services:GetChildren() do
   	local ok, pass, msg = game.ServerStorage.DevHook:Invoke(m.Name, "_selftest")
   	out[m.Name] = if ok then { pass = pass, msg = msg } else { pass = false, msg = tostring(pass) }
   end
   return HttpService:JSONEncode(out)
   ```
   Scenario hooks drive real flows without input simulation:
   `DevHook:Invoke("MissionService", "_startRound", "Town", 30)`, `("FireService", "_ignite", pos)`,
   `("RescueService", "_carry", player, rescueId)`, then read counters.
5. **ForgeProbe counters (every playtest, read by Forge's critic too).** Gameplay:
   `fires_extinguished`, `fires_spread`, `rescued`, `doors_broken`, `water_used`,
   `rounds_completed`. Health: `fire_tick_over_budget`, `net_dropped`, `map_build_ms`. A playtest
   where `fires_spread` is 0 after 60 s, or `rounds_completed` is 0 after a 30-second test round,
   is a failing test even without errors.
6. **Per-dev playtest before every PR** (in your own Studio, ~3 minutes):
   - compile check, sync, then a solo Play with one full round: no red in Output and
     `report.errors == []`;
   - `_selftest` for the services you touched passes;
   - **if you touched remotes, attributes or replication:** Test → Clients and Servers with 2
     players and check both see the same state;
   - paste the probe `counters` line into the PR description.
7. **Forge's loop** runs layers 1, 3 and 5 automatically on every iteration
   (`docs/ARCHITECTURE.md`). The `_selftest` runner (layer 4) is a good extra probe for
   `Studio.probe_report` (lane B).

---

## 8. How humans and Forge work on the same tree

### Recommendation: **pull sync (`game/tools/sync.py`) for everyone, not Script Sync.**

| | Pull sync (sync.py + pull.luau) | Script Sync (Studio built-in) |
|---|---|---|
| `X.client.luau` becomes | LocalScript | Script with RunContext=Client |
| Same mapping as Forge and `make_place.py` | yes | **no**: mixing them makes pull.luau replace every client script on each sync |
| Prune deleted files | yes (`ForgeManaged` tag) | yes |
| Roots | SSS, RS, SPS, plus ServerStorage/StarterGui/Workspace | SSS, RS, SPS only |
| Started from code (Forge/MCP) | yes | no, it's a manual right-click per place |
| Failure mode | one clear `OK`/`ERROR` line | blocking conflict dialog if files changed while Studio was closed, which also blocks Forge's MCP calls |
| Live on save | no, you trigger it (below) | yes |

Live-on-save is the only thing Script Sync does better, and it costs a second, inconsistent
mapping. Use one mechanism.

### A dev's loop

```bash
python3 game/tools/make_place.py --root game --out place/Forge.rbxlx && open place/Forge.rbxlx
python3 game/tools/sync.py serve --root game --port ${FORGE_SYNC_PORT:-34873} &   # once, from YOUR checkout
# edit files in your editor, then sync:
python3 game/tools/sync.py manifest --root game
#   then run game/tools/pull.luau in Studio (Edit mode), either way works:
#   - your Claude Code: execute_luau(datamodel_type="Edit", code=<pull.luau>)
#   - Studio command bar: paste pull.luau (verify once that the command bar can reach 127.0.0.1;
#     if it can't, use the MCP route)
# Play (F5), or start_stop_play via MCP
```

Optional upgrade for lane B: a local Studio plugin that polls `manifest.json` every 2 s while in
Edit mode and runs the same pull. That gives live-on-save with the same mapping.

### Rules that make sharing safe

1. **One Studio place = one source tree.** Pull sync prunes every `ForgeManaged` script that
   isn't in the manifest it reads. If two trees sync into one place, each sync deletes the other's
   new files. Each dev syncs only from their own checkout. **Forge gets its own Studio window and
   place** (`place/Forge-ai.rbxlx`, its own `FORGE_SYNC_PORT`); `Studio.select(name_hint)` picks it.
2. **Never edit a synced script inside Studio.** The next pull overwrites it, and it isn't in git.
3. **Forge's tree is a copy, promoted by PR.** `forge run` works in `runs/<slug>/game/` (gitignored),
   seeded from `game/`. Today `forge/loop.py` treats **every file that exists in `game/` as a base
   file Forge must not fix** (`Run._base_files`). That is the right guard here: Forge can't touch
   human-owned files, and it adds new files in the GF lane. The flow:
   ```bash
   rsync -a --exclude tools/manifest.json game/ runs/flame-and-blame/game/   # re-seed before each run
   forge run flame-and-blame --iterations 2
   git switch -c gf/hazards && cp runs/flame-and-blame/game/<new GF files> game/<same paths>
   # PR as usual; the owner of any lane the change touches reviews it
   ```
   Lane follow-ups this needs: (lane B) a `forge` helper for re-seeding and promoting, so it
   isn't done by hand; (lane A) a "feature" mode where the designer adds modules to an existing
   spec instead of designing a whole new game. Auto-discovery means Forge's new
   `HazardService.luau` boots without editing `Main.server.luau`.
4. **Human corrections to Forge's files** (the demo moment) use `forge correct flame-and-blame
   ServerScriptService/Services/HazardService.luau "..."` in the Forge copy, then promote. That
   way the correction is a recorded fixer call in the Mubit task.

---

## 9. Git rules for Luau

- **No place files in git:** `*.rbxl`, `*.rbxlx` and `place/` are gitignored already. The place is
  disposable and rebuilt any time with `make_place.py`. Anything that only exists inside a place
  is lost, which is why everything is built from code (§1).
- **Never commit** `game/tools/manifest.json` (gitignored) or `runs/`.
- **One owner per file** (the §1 table is the CODEOWNERS). To edit another lane's file, open a
  small PR titled `game(<lane>): ... [touches G2]` and get that owner to review it.
- **Frozen `[K]` files** change only in their own PR, merged first and announced. Additions to
  `Names.luau` and `Types.luau` (a new tag, say) are fine as one-line PRs. Renames and removals
  are not.
- **Don't rename files casually.** A rename deletes and recreates the script in Studio, changes
  the DevHook name, and breaks contracts that refer to it.
- **WIP merges are disabled, not commented out:** `MyService.Enabled = false`. `main` must boot.
- **Every file starts with `--!strict`**, uses tabs, LF line endings and a header comment that
  says owner, API, signals, writes and test hooks. Don't reformat other lanes' files.
- Branch names: `g1/hose-refill`, `g2/town-houses`, `gf/hazards`. Commit messages:
  `game(fire): spread pauses at MaxBurning`.
- CI (`luau-compile` + pytest, plus pure-Luau tests once added) must be green before a
  squash-merge. Rebase on `main` before pushing.
- Commit and push from worktrees before deleting them (`CLAUDE.md`; intofire lost its code that
  way).

---

## 10. Interface contracts (agree these before parallel work starts)

**Kickoff PR (K0, one person, ~1 hour):** the `[K]` files (`Main.server`, `Main.client`,
`Shared/{Net,Signal,Config,Names,Types}`), plus a **stub for every service, controller and config
in §1**: header comment, empty `Init`/`Start`, the public methods returning defaults, signals
declared, and `_selftest` returning `true`. After K0, every lane can call any API in this section
and get a harmless default, so nobody waits on anybody.

### Tags (CollectionService), in `Names.Tag`

| Tag | On | Written by | Read by |
|---|---|---|---|
| `Flammable` | BasePart (≤ 8-stud chunks) | MapService builders | FireService |
| `Burning` | Flammable part | FireService | FireFxController, SquadService (damage), BlameService |
| `Door` | door part (has a ProximityPrompt) | MapService | ToolService (axe/open) |
| `Hydrant`, `TruckRefill` | refill part (ProximityPrompt) | MapService, VehicleService | ToolService |
| `RescueDropoff` | invisible volume at the truck | VehicleService | RescueService |
| `Rescuable` | NPC Model | RescueService | RescueController, HazardService |
| `StationSpawn` | spawn pads ×4 | MapService | SquadService |
| `Window` | window part | MapService | RescueService (trampoline, v2) |
| `WetFloor`, `FuseBox` | floor / box part | MapService (FuseBox), ToolService (WetFloor while sprayed) | HazardService (v2) |
| `Truck` | truck Model | VehicleService | MissionService, VehicleController |
| `FireStart` | Flammable part that lights at round start | MapService builders | MissionService |
| `RescueSpawn` | invisible 2x2x2 marker, attrs `Kind`, `BuildingId` (NPC feet at marker Y - 1) | MapService builders | RescueService |
| `TruckSpot` | invisible marker, attr `LocationId`; LookVector = truck forward | MapService builders | VehicleService |
| `AlarmLamp` | Neon lamp part at the station | StationBuilder | AlarmController |

### Attributes, in `Names.Attr`

| Attribute | On | Type | Writer |
|---|---|---|---|
| `Fuel` | Flammable part | number (seconds), optional | MapService builders |
| `FireLevel` | Flammable part | 1-3, nil when not burning | FireService |
| `Charred` | Flammable part | boolean | FireService |
| `LocationId`, `BuildingId` | location Model / building Model | string | MapService |
| `Locked`, `Broken` | Door | boolean | MapService (initial), ToolService |
| `RescueId`, `Kind` | Rescuable | string; `"Civilian" \| "Dog" \| "Cat" \| "Panda"` | RescueService |
| `RescueState` | Rescuable | `"Trapped" \| "Carried" \| "Downed" \| "Rescued"` | RescueService |
| `CarriedBy` | Rescuable | number (UserId, 0 = none) | RescueService |
| `Water`, `TankSize` | Player | number | ToolService |
| `Spraying` | Player | boolean (cleared 0.25 s after last spray) | ToolService |
| `Helmet` | Player | 1-4 | SquadService |
| `Carrying` | Player | string (RescueId, "" = none) | RescueService |
| `Downed` | Player | boolean | SquadService |
| `RoundState` | Workspace | `"Lobby" \| "Alarm" \| "Active" \| "Results"` | MissionService |
| `RoundEndsAt` | Workspace | number (`workspace:GetServerTimeNow()` time) | MissionService |
| `MissionId` | Workspace | string (location Id) | MissionService |
| `ServerBooted`, `MapReady` | Workspace | boolean | Main.server, MapService |
| `Slot` | StationSpawn pad | number 1-4 | MapService builders |

### Remotes (`ReplicatedStorage.Net.<Namespace>.<Name>`), declared by the server owner

| Remote | Direction | Args | Limit | Server owner | Client user |
|---|---|---|---|---|---|
| `Tool/Spray` | C→S | `aim: Vector3` (unit) | 12/s, burst 4 | ToolService | ToolController |
| `Rescue/Drop` | C→S | none | 2/s | RescueService | RescueController |
| `Mission/Alarm` | S→C all | `missionId: string, locationName: string` | | MissionService | AlarmController, HudController |
| `Mission/Results` | S→C all | `ResultsPayload` | | MissionService (awards from BlameService) | ResultsController |
| `Shared/Notify` | S→C | `text: string, kind: "info" \| "good" \| "bad" \| "blame"` | | anyone via `Net.notify` | HudController (important events only: compact, max 2, top-centre) |
| `Shared/Popup` | S→C nearby | `subject: Instance \| false, pos: Vector3, text: string, kind, actorUserId: number, subjectUserId: number` | | anyone via `Shared/Popup.show(subject, text, kind?, actor?)` | ClientLib/WorldPopup (small world text over the subject; minor juice) |
| `Hazard/Zapped` (v2) | S→C all | `victim: number, culprit: number?` (UserIds) | | HazardService | HazardController |

Carry, revive, refill and door interactions are **ProximityPrompts** handled on the server (no
remotes). Axe swings use server-side `Tool.Activated`. The **builders create** the one ProximityPrompt on each
Door/Hydrant/TruckRefill part (MapKit, TruckBuilder); the **system lane owns its behaviour** (ToolService).
`Shared/Notify` and `Shared/Popup` are declared by `Main.server.luau` before any `Start` (no single owner).

### Server service APIs (call through `services.X`, always nil-guarded)

```lua
-- MapService [G2]                    Priority 0
MapService:GetLocation(id: string): Model?
MapService:GetLocations(): { [string]: Model }
MapService:RebuildLocation(id: string)                 -- round reset; fires LocationBuilt again
MapService:GetSpawnCFrame(slot: number): CFrame        -- StationSpawn pad 1..4
MapService:RandomFlammable(id: string, rng: Random): BasePart?
MapService.LocationBuilt: Signal<Model, string>        -- (model, locationId)

-- FireService [G1]                   (full skeleton in §2)
FireService:Ignite(part: BasePart, cause: Player?): boolean
FireService:ApplyWater(player: Player?, origin: Vector3, aim: Vector3, litres: number): number
FireService:IsBurning(part: BasePart): boolean
FireService:CountBurning(locationId: string?): number
FireService:ExtinguishAll()
FireService.Ignited / .Spread / .Extinguished / .Charred   -- (part, Player?) / (from, to) / (part, Player?) / (part)

-- ToolService [G1]
ToolService:GiveLoadout(player: Player)                -- Hose, Axe (+ WateringCan for the joke)
ToolService:Refill(player: Player, litres: number?)    -- nil = full
ToolService:ResetDoors(locationId: string)             -- only if not rebuilt
ToolService.DoorBroken: Signal<Player, BasePart>
ToolService.WaterUsed: Signal<Player, number>
ToolService.HoseHit: Signal<Player, Player>            -- K0: (sprayer, victim) friendly fire, P1.5
ToolService:_spray(player: Player, aim: Vector3)       -- test hook = one Tool/Spray event

-- MissionService [G3]
MissionService:StartRound(locationId: string?, seconds: number?)
MissionService:EndRound(reason: "time" | "allOut" | "forced")
MissionService:GetState(): Types.RoundState
MissionService.RoundStarted: Signal<string>            -- locationId
MissionService.RoundEnded: Signal<Types.ResultsPayload>
MissionService:_startRound(locationId: string, seconds: number)

-- RescueService [G3]
RescueService:Spawn(locationId: string, count: number)
RescueService:Clear()
RescueService:Deliver(player: Player): boolean         -- called when the carrier touches RescueDropoff
RescueService.Rescued: Signal<Player, string, string>  -- (player, rescueId, kind)
RescueService.Dropped: Signal<Player, string>
RescueService:_carry(player: Player, rescueId: string): boolean

-- SquadService [G3]                  Priority 10
SquadService:GetHelmet(player: Player): number
SquadService:Down(player: Player, cause: string, culprit: Player?)
SquadService:Revive(player: Player, by: Player)
SquadService:RespawnAll()                              -- everyone back to StationSpawn
SquadService.Downed: Signal<Player, string, Player?>   -- (victim, cause, culprit)

-- VehicleService [G2]
VehicleService:GetTruck(): Model?
VehicleService:ResetTruck()                            -- back to the station bay
VehicleService:ParkAt(locationId: string): boolean     -- K0: truck onto that location's TruckSpot (v1 travel = teleport)
VehicleService.Driven: Signal<Player, number>          -- (driver, studs) for awards

-- BlameService [G3]                  consumer: subscribes to every signal above
BlameService:GetStats(player: Player): Types.PlayerStats
BlameService:BuildAwards(): { Types.Award }
BlameService:Reset()
```

### Shared types (`ReplicatedStorage/Shared/Types.luau` [K])

```lua
export type RoundState = "Lobby" | "Alarm" | "Active" | "Results"
export type RescueKind = "Civilian" | "Dog" | "Cat" | "Panda"
export type RescueState = "Trapped" | "Carried" | "Downed" | "Rescued"
export type EndReason = "time" | "allOut" | "forced"
export type NotifyKind = "info" | "good" | "bad" | "blame"
export type PlayerStats = {
	userId: number,
	helmet: number,
	name: string,
	firesOut: number,
	firesStarted: number,
	water: number,
	doors: number,
	rescued: number,
	pandas: number,
	downedOthers: number,
	timesDowned: number,
	teammateSprayed: number,
}
export type Award = { id: string, title: string, userId: number, value: number, blurb: string, blame: boolean }
export type ResultsPayload = {
	locationId: string,
	seconds: number,
	firesOut: number,
	burnedParts: number,
	rescued: number,
	trapped: number,
	burningAtEnd: number,
	stars: number,
	reason: EndReason,
	awards: { Award },
	stats: { PlayerStats },
}
return {}
```

### Telemetry counters (`ForgeTelemetry.count`, server only)

| Counter | Bumped by |
|---|---|
| `fires_extinguished`, `fires_spread`, `fire_tick_over_budget` | FireService |
| `water_used`, `doors_broken` | ToolService |
| `rescued` | RescueService |
| `rounds_completed` | MissionService |
| `map_build_ms` | MapService |
| `net_dropped` | Net |

### v1.5 additions (lobby, parallel squads, Heat, first person, physics, hazards)

Contracts added after K0, stubbed in `main` with harmless defaults (every stub `Enabled`, `_selftest`
returns `true, "stub"`). Owners replace the bodies, never the signatures.

**Lobby and parallel missions.** The fire station is the lobby. Players spawn there; the Mission
Board (`MissionBoard` part: SurfaceGui + ProximityPrompt) lists `Config/MissionCatalog`; squads of
1-4 queue on `SquadPad`s; the leader picks a mission and launches; `MissionService:StartMission`
builds that mission's location as its **own instance** (`MapService:BuildInstance`) in a free slot
(`MapConfig.InstanceFirstSlot` .. `+ MaxInstances - 1`, 400-stud slots), so several squads play
different missions at the same time in one server. On `MissionEnded` the squad returns to the
station (`LobbyService:ReturnToLobby`). `LobbyConfig.UseLobby = false` keeps v1's single
auto-round until G3 flips it.

Rules for instances:
- An instance Model lives at `Workspace.Instances.<instanceId>` with attrs `InstanceId`,
  `LocationId`, and (written by MissionService) `RoundState`, `RoundEndsAt`, `MissionId`. The
  Workspace-level round attrs stay for v1's single round.
- APIs that take a `locationId` (`FireService:CountBurning`, `RescueService:Spawn`,
  `ToolService:ResetDoors`, `VehicleService:ParkAt`) also accept an `instanceId`. Services that index
  `LocationBuilt` also index `InstanceBuilt`.
- `Player.InstanceId == ""` means "in the lobby". Every per-mission system filters players by it.
- Lighting is server-global: with parallel squads the server keeps the lobby look; per-instance looks
  are applied client-side (v2) from `AtmosphereConfig`.

| New tag | On | Written by | Read by |
|---|---|---|---|
| `MissionBoard` | station board part (SurfaceGui + ProximityPrompt) | StationBuilder | LobbyService, LobbyController |
| `SquadPad` | squad queue pad, attr `PadId` | StationBuilder | LobbyService |
| `Hazard` | hazard source (fuse box lever, gas tank, detonator), attr `HazardId` | location builders | HazardService |

| New attribute | On | Type | Writer |
|---|---|---|---|
| `SquadId` | Player | string, `""` = none | LobbyService |
| `InstanceId` | Player; instance Model | string, `""` = in the lobby | MissionService; MapService |
| `PadId` | SquadPad | number 1..N | StationBuilder |
| `Heat` | Player | number 0-100 | HeatService |
| `LocationPreset` | Lighting | string (locationId whose look is applied) | AtmosphereService |
| `HazardId` | Hazard part/Model | `Types.HazardId` | builders |
| `Power` | FuseBox | boolean (true = live) | builders (initial), HazardService |
| `Ragdolled` | character Model | boolean | Ragdoll / PhysicsFxController |

| New remote | Direction | Args | Limit | Server owner | Client user |
|---|---|---|---|---|---|
| `Lobby/Board` | S→C all | `squads: { Types.Squad }` | | LobbyService | LobbyController |
| `Lobby/Choose` | C→S | `missionId: string` | 2/s | LobbyService | LobbyController |
| `Lobby/Launch` | C→S | none (leader only) | 1/s | LobbyService | LobbyController |
| `Shared/Ragdoll` | S→C owner | `seconds: number, impulse: Vector3?` | | `Main.server` declares; `Shared/Ragdoll.luau` fires | PhysicsFxController |
| `Hazard/Zapped` | S→C all | `victim: number, culprit: number?` (UserIds) | | HazardService | HazardController |
| `Hazard/Fx` | S→C all | `hazardId: string, position: Vector3, params: table` | | HazardService | HazardController |

```lua
-- MapService [G2] (v1.5)
MapService:BuildInstance(locationId: string, instanceId: string): Model?  -- free slot; nil = no builder/slot
MapService:DestroyInstance(instanceId: string): boolean
MapService:GetInstance(instanceId: string): Model?
MapService:GetInstances(): { [string]: Model }
MapService.InstanceBuilt: Signal<Model, string, string>  -- (model, instanceId, locationId)

-- LobbyService [G3]                  Priority 55
LobbyService:GetSquads(): { Types.Squad }
LobbyService:GetSquad(squadId: string): Types.Squad?
LobbyService:Join(player: Player, padId: number): string?       -- squadId
LobbyService:Leave(player: Player)
LobbyService:Choose(player: Player, missionId: string): boolean  -- leader only, enabled missions only
LobbyService:Launch(squadId: string, missionId: string): string? -- instanceId
LobbyService:ReturnToLobby(players: { Player })
LobbyService.SquadChanged: Signal<string>                        -- squadId
LobbyService.Launched: Signal<string, string, string>            -- (squadId, missionId, instanceId)

-- MissionService [G3] (v1.5; v1's StartRound/EndRound stay for the single auto-round)
MissionService:StartMission(squad: { Player }, missionId: string): string?  -- instanceId
MissionService:EndMission(instanceId: string, reason: Types.EndReason)
MissionService:GetMission(instanceId: string): Types.MissionRun?
MissionService:GetMissions(): { Types.MissionRun }
MissionService.MissionStarted: Signal<string, string>            -- (instanceId, missionId)
MissionService.MissionEnded: Signal<string, Types.ResultsPayload> -- (instanceId, results)

-- HeatService [G1]                   Priority 55
HeatService:GetHeat(player: Player): number
HeatService:AddHeat(player: Player, amount: number, source: string?)
HeatService:Cool(player: Player, amount: number, by: Player?)   -- teammate spray / extinguisher
HeatService:Reset(player: Player?)                              -- nil = everyone
HeatService.Overheated: Signal<Player>                          -- at 100: SquadService:Down(player, "heat")

-- ToolService [G1] (v1.5)
ToolService.HoseRecoil: Signal<Player, Vector3>                 -- (sprayer, impulse) -> Ragdoll.knockback

-- HazardService [GF]                 Priority 70
HazardService:Trigger(instanceId: string, hazardId: Types.HazardId, params: { [string]: any }?): boolean
HazardService:Clear(instanceId: string)
HazardService:GetActive(instanceId: string): { Types.HazardId }
HazardService.Triggered: Signal<string, string>                 -- (instanceId, hazardId)
HazardService.Zapped: Signal<Player, Player?>                   -- (victim, culprit)
HazardService.Flung: Signal<Player, string>                     -- (victim, hazardId)
-- params: electrocution {fuseBox?, culprit?} | fire_tornado {position?, seconds?}
--         explosion {position, radius?, culprit?} | tidal_wave {direction?, seconds?} | cigarette {npc?}

-- FinaleService [GF]                 Priority 75 (dam_finale)
FinaleService:Arm(instanceId: string)
FinaleService:Detonate(instanceId: string, by: Player?): boolean  -- -> HazardService:Trigger(id, "tidal_wave")
FinaleService:GetPlanted(instanceId: string): number
FinaleService.ChargePlanted: Signal<string, Player>
FinaleService.Detonated: Signal<string, Player?>

-- AtmosphereService [G2] (v1.5)
AtmosphereService:ApplyLocation(locationId: string, tweenTime: number?): boolean  -- AtmosphereConfig.LocationPresets
AtmosphereService:ApplyMission(missionId: string, tweenTime: number?): boolean    -- MissionCatalog `atmosphere`
```

```lua
-- ReplicatedStorage/Shared/Ragdoll.luau (contract [K], body [G1]); callable on server or client
Ragdoll.enable(character: Model, seconds: number): boolean       -- server: attr Ragdolled + Shared/Ragdoll to the owner
Ragdoll.knockback(character: Model, impulse: Vector3): boolean   -- studs/s, clamped to PhysicsConfig.MaxImpulse
Ragdoll.isRagdolled(character: Model): boolean
-- Used by: hose friendly fire + recoil (ToolService), explosions, electrocution, tornado, tidal wave
-- (HazardService), slaps, axe hits.

-- Client controllers (v1.5)
FirstPersonController:SetEnabled(on: boolean)        -- camera lock, viewmodel gloves, head bob (PhysicsConfig)
FirstPersonController:Shake(magnitude: number, seconds: number)
FirstPersonController:GetViewmodel(): Model?
-- LobbyController: Mission Board UI + squad roster; PhysicsFxController: applies Shared/Ragdoll and
-- hose recoil locally; HazardController: Hazard/Zapped + Hazard/Fx effects.
```

**MissionCatalog** (`ReplicatedStorage/Config/MissionCatalog.luau` [G3]) is pure data: an array of
`Types.MissionDef` (`id, title, blurb, locationId, enabled, players{min,max}, seconds, atmosphere,
objectives[], fires{count, starts}, rescues[{kind, count, variant?}], hazards[], tools[], stars[]`).
Missions: `house_fire` (Town, the only one enabled in v1), `apartment_trampoline`, `school_alarm`,
`farm_haystack`, `forest_walkie`, `storage_fusebox`, `tornado_field`, `dam_finale`, `panda_zoo`. A
mission is enabled in the PR that ships its location builder. `game/tests/mission_catalog.spec.luau`
validates the shape.

New types in `Shared/Types.luau`: `SquadState`, `Squad`, `HazardId`, `MissionRun`,
`MissionObjective`, `MissionRescue`, `StarRule`, `MissionDef`; `ResultsPayload` gains optional
`missionId` and `instanceId`. New configs: `LobbyConfig` [G3], `HeatConfig` [G1], `PhysicsConfig`
[G1], `HazardConfig` [GF]; `MapConfig.InstanceFirstSlot/MaxInstances`, `ToolConfig.HoseRecoil`,
`AtmosphereConfig.LocationPresets`.

New counters: `map_instances_built` (MapService), `squads_launched` (LobbyService),
`missions_started`, `missions_completed` (MissionService), `heat_downs` (HeatService),
`hazards_triggered`, `electrocutions` (HazardService).

### Readiness checklist for K0

- [ ] `sync.py check --root game` passes with every stub in place.
- [ ] Solo Play: Output shows `[Boot] server: N services` and no warnings; ForgeProbe `errors == []`.
- [ ] The `_selftest` runner (§7) returns `pass = true` for every stub.
- [ ] Each lane has written its name in the lane table in `docs/TEAM.md`.
