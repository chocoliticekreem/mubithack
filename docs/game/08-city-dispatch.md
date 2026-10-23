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
- `Lib/Map/Locations/CityBuilder.luau` (Id "City", Slot 0, replaces the separate Station/Town slots
  in v2). A street grid of roughly **1200 x 1200 studs**: a 6x6 block grid, 24-stud two-lane roads,
  sidewalks, intersections with traffic lights, and districts:
  - downtown (apartments, shops)
  - suburbs (houses like Maple Street)
  - a school campus
  - an industrial area with storage units
  - a park and zoo
  - a farm edge
  - a forest edge
  - the dam on the outskirts
- It reuses the existing location builders where it can, by calling `XBuilder.Build(model, origin,
  rng)` at a district origin (Town, Apartment, School, Storage, Farm, Forest, Dam, Zoo), plus
  procedural filler blocks.
- The **station** is placed by StationBuilder at the city's north edge, facing the main avenue.
- **Incident sites**: every building that can host a mission is a Model tagged `IncidentSite` with:
  - attributes `SiteId` (string), `MissionTypes` (comma-separated MissionCatalog ids, e.g.
    `"house_fire"`), `Busy` (bool)
  - children: `FireStart` and `RescueSpawn` markers (as before), a `TruckSpot` part where a truck
    parks, and an `ArrivalZone` part (invisible, about 40 studs) that counts as "arrived".
- **Road graph** for GPS: a Folder `Workspace.Map.City.RoadGraph` holding `RoadNode` parts
  (attribute `NodeId`) and `RoadEdge` ObjectValues (`A`, `B`). Alternatively the builder exports
  `CityBuilder.Graph = {nodes = {[id] = Vector3}, edges = {{a, b}}}` and writes it as a JSON
  StringValue `Workspace.Map.City.RoadGraphJson`.

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
