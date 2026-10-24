--!strict
-- SmokeConfig [owner: Smoke agent]. Every room smoke / heat / backdraft number (SmokeService server,
-- SmokeController client). Read at use time (SmokeConfig.X) so
-- DevHook:Invoke("SmokeConfig", ".Set", key, value) live-tunes the server copy.
-- Maths: ServerScriptService/Lib/Fire/SmokeSim (pure) + Lib/Fire/Rooms (room finding), specs in
-- game/tests/smoke_sim.spec.luau and game/tests/rooms.spec.luau.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Enabled = true,
	TickHz = 3, -- simulation steps per second (only active mission sites simulate)
	TickBudgetMs = 2, -- a tick slower than this bumps smoke_tick_over_budget
	-- room finding (Lib/Fire/Rooms): a grid over each building, walls / doors / windows rasterized at
	-- SliceHeight above every storey floor, flood fill -> rooms
	Cell = 1.5, -- studs per grid cell
	WallPad = 0.75, -- blockers are fattened by this so a 1-stud wall never leaks between cell centres
	SliceHeight = 4, -- studs above a storey floor where walls / doors / windows are sampled
	MinWallHeight = 6, -- Wall/Partition parts at least this tall define the storey levels
	MinRoomCells = 8, -- smaller pockets are ignored (wall gaps, cupboards)
	MaxBuildingsPerSite = 4,
	MaxRoomsPerSite = 24,
	MaxRectsPerRoom = 4, -- smoke layer boxes per (non-rectangular) room
	-- smoke + heat sources (per FireLevel point burning in the room, scaled by RefArea / room area)
	RefArea = 300, -- sq studs
	MinArea = 60,
	FireCap = 24, -- FireLevel points that count per room
	SmokePerLevel = 0.012, -- smoke fraction / s per FireLevel point (0 = clear, 1 = full to the floor)
	HeatPerLevel = 1.4, -- room heat (0..100) / s per FireLevel point
	Leak = 0.012, -- every room loses this fraction of its smoke / s through cracks
	HeatLoss = 0.03, -- and this fraction of its heat
	-- flows between rooms / outside (fraction of the smoke difference per second)
	OpenDoorFlow = 0.6,
	SeepFlow = 0.012, -- a closed door: smoke seeps under it
	OpenWindowFlow = 0.7, -- broken / open window
	ClosedWindowFlow = 0.003,
	StairFlow = 0.5, -- stairwell / floor hole between storeys (smoke rises)
	SinkFactor = 0.25, -- smoke flowing DOWN a stairwell moves this much slower
	HeatFlowFactor = 0.6, -- heat flows like smoke, a bit slower
	OpenFlowAt = 0.2, -- a link with at least this conductance counts as "open" (vents / joins rooms)
	-- backdraft (a sealed room with heavy fire + smoke builds pressure)
	PressureSmoke = 0.4, -- smoke needed to build pressure
	PressureFire = 3, -- FireLevel points needed in the room
	PressureRate = 0.04, -- pressure / s while sealed (0 -> WarnAt in 10 s, ArmedAt in 19 s; faster for big fires)
	PressureFireBoost = 2, -- a roaring sealed room (>= 2 x 3 x PressureFire points) pressurizes up to 2x faster
	PressureDecay = 0.02, -- pressure / s lost when the fire or smoke drops
	VentRelief = 0.25, -- pressure / s lost while the room is vented
	WarnAt = 0.4, -- stage 1: doors rattle, puffs from the gaps, creaks, "Something's building up in there..."
	ArmedAt = 0.75, -- stage 2: opening a door into it = BACKDRAFT
	BackdraftSmokeKeep = 0.3, -- smoke left after the fireball
	BackdraftHeat = 25, -- room heat added by the fireball
	BackdraftRadius = 16, -- studs from the door: knockback + heat
	BackdraftPush = 75, -- studs/s along the doorway
	BackdraftLift = 35,
	BackdraftRagdoll = 2.5, -- seconds
	BackdraftPlayerHeat = 30,
	BackdraftIgnite = 3, -- extra parts set alight in the room (+ 2 just outside the door if it is a room)
	WarnPuffEvery = 3, -- seconds between warning puffs / creaks for a pressurized room
	VentPuffSmoke = 0.25, -- opening something on a room this smoky gives a "vent" plume burst
	-- fire seeping through doors (spread charge per second x room heat / 100; fires at 1)
	SpreadHeat = 45, -- room heat needed before fire creeps into the next room
	SpreadOpenRate = 0.08, -- through an open door / stairwell (~15 s at heat 80)
	SpreadSeepRate = 0.025, -- under a closed door (~50 s at heat 80)
	SpreadSkipFire = 6, -- the next room already has this many FireLevel points: no seep spread
	-- players
	SmokeHurtsAt = 0.2, -- below this smoke fraction it's just atmosphere
	SmokeHeatPerSecond = 8, -- body heat / s at full smoke (HeatService cools 6 / s on its own): ~50 s to drop maskless
	RoomHeatAt = 30, -- room heat above this warms players too
	RoomHeatPerSecond = 5, -- body heat / s at room heat 100
	MaskFactor = 0.2, -- gas mask (Player attr GasMask): smoke heat x this
	MaskAirFactor = 0.08, -- gas mask + oxygen air
	HotDoorAt = 0.5, -- DoorHeat (0..1) above this burns your hand when you grab it
	JoltHeat = 18, -- body heat from grabbing a hot door handle
	JoltPush = 18, -- studs/s backwards
	FeelKey = Enum.KeyCode.T, -- "Feel door" prompt
	-- rescue NPCs
	ChokeAt = 0.45, -- smoke fraction where NPCs start choking
	ChokeDps = 0.4, -- HP / s at full smoke (NPC Health 100: ~4 min in thick smoke; was dying too fast)
	CoughEvery = 7, -- seconds between "*cough*" popups per NPC
	-- client visuals (SmokeController)
	FxDistance = 220, -- rooms / doors farther than this from the camera aren't drawn
	MaxLayerEmitters = 8, -- nearest smoke layers that get a billowing underside
	MaxLinkFx = 16, -- nearest doors / windows with seep / vent / glow effects
	LayerMaxFill = 0.9, -- full smoke still leaves a crawl gap at the floor
	LayerClear = 0.6, -- layer transparency at smoke 0+
	LayerThick = 0.04, -- layer transparency at smoke 1
	LayerColor = Color3.fromRGB(30, 28, 30),
	ScreenDarkMax = 0.72, -- screen overlay opacity with your head in full smoke (no mask)
	GlowColor = Color3.fromRGB(255, 120, 40),
	RattleDegrees = 2.2, -- door wiggle at stage 1 (x2 when armed)
})
