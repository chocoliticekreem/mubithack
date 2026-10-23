# v2: the city, dispatch, trucks, navigation and inventory (contract)

This replaces "teleport the squad to a mission copy". Every system below codes against these names.
Owners are in brackets. Contracts in `docs/game/03` §10 still apply unless this file overrides them.

## Flow
1. Players spawn in the **big fire station** (4 bays, 4 trucks, alarm sirens and lights). The
   lobby, queue pads and countdown stay as they are.
2. When a squad's pad hits 0, **MissionService dispatches** instead of teleporting. It picks a free
   **incident site** in the city for the mission type, lights the station sirens, and sends the
   squad a dispatch alert.
3. Each squad member runs to **their own truck** (bay = helmet number). They hop in and drive
   with the siren on, following the **waypoint, minimap and GPS route** to the site. The timer
   starts on dispatch and the site's fires start burning straight away.
4. On arrival (truck or player inside the site radius), the mission goes to Active. Players grab
   gear from the **truck compartments** (not the Roblox backpack). The hose comes off the truck reel
   and stays attached to the truck by a physical HoseLine.
5. The squad puts out fires and rescues people into the truck's RescueDropoff, gets the results
   screen, and drives back (or presses "Return to station" after the results).
Squads run in parallel at **different sites** in the same city. No map copies are needed.

## City [owner: CityBuilder agent]
- `Lib/Map/Locations/CityBuilder.luau` (Id "City", Slot 0; `CityConfig.Enabled` makes MapService skip
  the standalone slots of the builders it absorbs). **~3000 x 3000 studs** (`CityConfig.Bounds`, +Z =
  south): a 3x3 grid of 900-stud cells. The **fire station hub** is the centre cell (StationBuilder at
  `CityConfig.StationOrigin`, bays facing south onto the hub loop, 4-lane avenues radiating out); the 8
  other cells each hold one neighbourhood, clearly apart (~280 studs of greenbelt + road between):
  Farm (NW), Maple Street/Town (N), Mill Creek Dam (NE), Storage (W), Forest (E), School (SW),
  Apartment (S), Zoo (SE). Highway 67 is the outer ring, 4-lane avenues the ring road round the hub.
- Each neighbourhood: its location builder called as `XBuilder.Build(model, origin, rng)` at the cell
  centre (400 x 400 core; procedural core if the builder is missing), a 2-lane loop street round it, a
  themed band of lots (some are extra incident sites), gate streets out to the road between cells,
  a welcome arch + name boards, a landmark, its own road style. Mill Creek runs from the dam's river
  down the east greenbelt (bridges) and widens into **Mill Pond** (`CityConfig.MillPond`, refill water).
  Signposts at junctions point to every neighbourhood.
- **Avenue corridors** (`Districts.corridors`): every neighbourhood's strip between its edge and the
  avenue ring has a row of frontage lots facing the avenue, themed like its band (low-detail 2-4
  part facades; downtown rises into a skyline near the hub) plus a few incident sites (houses, shops,
  apartments, storage, and a whole-run school campus or apartment block via `CorridorBigSites`).
  A corridor site's `RoadNode` is a kerb node `A<x>_<z>` split into the avenue in front of it.
- **Greenbelt** (`Lib/Map/City/Greenbelt.luau`): pocket parks where corridors meet, Highway 67
  hedgerows + pine clumps, crop fields beyond the highway. **Highway** (`Lib/Map/City/Highway.luau`):
  Ridge Tunnel on the west highway (`CityConfig.Tunnel`, 22 studs clearance), exit gantries, corner
  billboards, and service stops beyond it (`CityConfig.HighwaySites`: a gas station + a diner, both
  incident sites with a kerb node on the highway). Downtown has Blazeville City Hall (`Districts.CorridorFeature`) and a skyline that rises
  toward the hub; signalised junctions have stop lines. Budget: ~29.5k parts / ~280 lights (mock build).
- **Street furniture**: a refill hydrant (`MapKit.hydrant`: tag `Hydrant` + Refill prompt) on every
  corridor run and band side, bus shelters downtown/suburb, `Knockable`-tagged `TrashCan` / `Bench`
  models at the lot fronts. Only every `LampLightEvery`-th street lamp carries a PointLight.
  Landmarks carry a neon beacon + a floating district-name BillboardGui.
- `MapService:GetLocation("Town")` etc. return the district Model inside the city.
- **Incident sites**: every building that can host a mission is a Model tagged `IncidentSite` with:
  - attributes `SiteId` (string), `MissionTypes` (comma-separated MissionCatalog ids, e.g.
    `"house_fire"`), `Busy` (bool)
  - children: `FireStart` and `RescueSpawn` markers (as before), a `TruckSpot` part where a truck
    parks, and an `ArrivalZone` part (invisible, about 40 studs) that counts as "arrived".
- **Road graph** for GPS and traffic: a Folder `Workspace.Map.City.RoadGraph` holding `RoadNode` parts
  (attribute `NodeId`) and `RoadEdge` ObjectValues (attrs `A`, `B`, `Kind`, `Style`, `Width`,
  `SpeedLimit`, `Lanes`). `CityBuilder.Graph = {nodes = {[id] = Vector3}, edges = {...}}` and the JSON
  StringValue `Workspace.Map.City.RoadGraphJson`: `{nodes = {[id] = {x, y, z}}, pairs = {{a, b}},
  edges = {{a, b, kind, style, width, speedLimit, laneCount, length, drawn, lanes = {{offset, dir,
  width}}}}}`. Right-hand traffic: lane `offset` is measured to the right of a -> b, `dir` 1 drives
  a -> b, -1 drives b -> a. Kinds: highway, avenue (4 lanes), street, spur (2 lanes), builder (a
  location's own road, not drawn by the city). The City model's `TrafficPhase` attr ("XGreen",
  "XAmber", "ZGreen", "ZAmber") + `TrafficPhaseEndsAt` mirror the traffic lights.

## Station v2 [owner: Station agent]
- `StationBuilder.luau` is rebuilt as a big station: **4 bays** (`TruckBay` parts tagged `TruckBay`,
  attribute `Bay` = 1–4), a locker room, the lobby area (board and pads stay with LobbyService), a
  pole, and **station alarm sirens**: `AlarmLight` models (spinning beacons) plus `AlarmSpeaker`
  parts tagged `StationAlarm`. `AlarmController` and `Lobby/Fx` drive them on dispatch.

## Vehicles [owner: Vehicle agent]
- `VehicleService` spawns **one truck per player**:
  - on join, in bay `Helmet` (1–4), or a reserve spot if busy
  - model `FireTruck_<UserId>`, attribute `OwnerUserId`
  - built by `TruckBuilder`, made drivable (VehicleSeat plus a goofy, bouncy custom suspension)
- Siren (F), horn (H), lights. Its `TruckRefill` reel prompt is where the hose comes from.
- API: `GetTruck(player): Model?`, `RespawnTruck(player)`, `ParkAt(player, cframe)`, signals
  `Entered(player, truck)`, `Exited(player, truck)`, `SirenChanged(truck, on)`.
- `MissionService` no longer parks trucks. Players drive them.

## Navigation [owner: Navigation agent]
- `NavigationService` (server) + `NavigationController` (client) + `ClientLib/Minimap.luau`.
- API: `NavigationService:SetWaypoint(players: {Player}, target: Vector3 | BasePart, label: string)`,
  `ClearWaypoint(players)`. It sets attributes `WaypointPos` (Vector3) and `WaypointLabel` on Player.
- Client:
  - minimap (top-right, rotating with the camera, showing roads from the road graph, the player
    arrow, teammates, trucks, the waypoint and active incidents)
  - a 3D beacon beam at the target, a distance readout, a GPS route line on roads (Beams or
    neon parts along the shortest path) and an off-screen arrow
  - a big map on M

## Dispatch missions [owner: Dispatch agent]
- `MissionService:StartMission(squad, missionId)` (same signature) now:
  - picks a free `IncidentSite` whose `MissionTypes` includes the mission, sets `Busy`
  - ignites its `FireStart` markers and spawns rescues at its `RescueSpawn` markers (tagged with
    `InstanceId` = the run id, as before)
  - calls `NavigationService:SetWaypoint` and fires the dispatch alert (station alarm, the
    `Mission/Alarm` remote, HUD "DISPATCH: House fire at 12 Maple St")
  - sets `RoundState` Dispatched → Active (on arrival) → Results
  - clears the site and resets it with `MapService:RebuildSite(siteId)`, or the per-site reset
- `Player.InstanceId` = run id, as before. The HUD and the rest read the run state from
  `Workspace.Runs.<runId>` (a Folder with the attributes the instance Model used to have:
  `MissionId`, `RoundState`, `RoundEndsAt`, `SiteId`, `LocationId`).

## Inventory [owner: Inventory agent]
- `InventoryService` + `InventoryController` replace the Roblox backpack for gear
  (`StarterGui:SetCoreGuiEnabled(Backpack, false)`).
- **Slots:** 1 hand item, 1 back item (oxygen tank), and carry (NPC or physics prop).
- Gear is **physical**: equipment racks in the station and compartments on every truck
  (ProximityPrompt "Grab Axe" etc.). Items can be dropped (G) or thrown (hold Q) as physics objects
  others can pick up, and fumbling under ragdoll drops them.
- **Hose:** grabbing the nozzle from your truck's reel calls `HoseLine.attach(player, reelPart)`.
  You can't wander farther than the hose length from the truck, and dropping the nozzle leaves it
  on the ground still attached.
- API: `InventoryService:Give(player, itemId)`, `Drop(player)`, `GetHand(player): string?`, signal
  `Changed(player)`. Tools stay `Tool` instances under the character while held, so ToolService keeps
  working. Inventory owns where they come from.
- Custom hotbar UI (big chunky slots), plus a pickup prompt and "E to grab" world highlights.

## Goofy physics [owner: Physics agent]
- `PhysicsFxService` + `PhysicsFxController`:
  - light city props are unanchored and knockable: trash cans, cones, mailboxes, benches, hydrant
    caps, ducks
  - a truck hitting a prop sends it flying; a truck bumping a player ragdolls them with a cartoon
    "boing"
  - slipping on puddles, a ragdoll on hard landings, and wobbly carry
  - knockback from explosions and the hose, applied to props too
- Budgeted: an unanchored-props cap per area, and props sleep when far away.
