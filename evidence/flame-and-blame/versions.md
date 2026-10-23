# Versions

## v1  (2026-10-23T21:50:02)
seeded from /Users/sonionring/orca/mubithack/game (158 human files)

## v2  (2026-10-23T21:51:23)
before fixes (improve-flame-and-blame-1)

```
tools/manifest.json | 1228 +++++++++++++++++++++++++++++++++++++++++++++++++++
 1 file changed, 1228 insertions(+)
```

## v3  (2026-10-23T21:59:58)
rollback to v2: fix cycle crashed mid-attempt

## v4  (2026-10-23T22:26:11)
seeded from /Users/sonionring/orca/mubithack/game (166 human files)

```
 ServerScriptService/Services/RescueService.luau    |  11 +-
 ServerScriptService/Services/SquadService.luau     |  15 +-
 ServerScriptService/Services/StructureService.luau |   8 +-
 ServerScriptService/Services/ToolService.luau      |  15 +-
 ServerScriptService/Services/TrafficService.luau   |  21 +-
 ServerScriptService/Services/VehicleService.luau   |   5 +-
 .../Services/WorldBoundsService.luau               |   3 +-
 StarterPlayerScripts/ClientLib/PhysicsHands.luau   | 256 +++++++------
 StarterPlayerScripts/ClientLib/Viewmodel.luau      | 402 ++++++++++++++++-----
 StarterPlayerScripts/ClientLib/WorldPopup.luau     | 353 ++++++++++++++++++
 .../Controllers/FireFxController.luau              |  38 +-
 .../Controllers/FirstPersonController.luau         |  46 ++-
 .../Controllers/HudController.luau                 | 114 +++---
 .../Controllers/InventoryController.luau           |  33 +-
 .../Controllers/LobbyController.luau               |   4 +-
 .../Controllers/PhysicsFxController.luau           |  67 +---
 .../Controllers/RescueController.luau              |  27 +-
 .../Controllers/SquadController.luau               |  50 +--
 .../Controllers/ToolController.luau                |  60 +--
 .../Controllers/TrafficController.luau             |  37 +-
 .../Controllers/VehicleController.luau             | 150 ++++++--
 StarterPlayerScripts/Lib/PopupLogic.luau           | 126 +++++++
 tests/mesh_skin.spec.luau                          | 102 ++++++
 tests/popup.spec.luau                              |  93 +++++
 44 files changed, 2101 insertions(+), 728 deletions(-)
```

## v5  (2026-10-23T22:30:14)
before fixes (improve-flame-and-blame-1)

```
tools/manifest.json | 56 +++++++++++++++++++++++++++++++++++++++++++++++++++++
 1 file changed, 56 insertions(+)
```

## v6  (2026-10-23T22:40:37)
before fixes (improve-flame-and-blame-2)

## v7  (2026-10-23T22:49:56)
fix: Pathfinding returns NoPath in the lobby and walks stop short of targets in ServerScriptService/Lib/Map/Locations/StationBuilder.luau (verifier: fixed, mreq_01a16abded2670f0a2b542975e35d6b8)

```
.../Lib/Map/Locations/StationBuilder.luau          | 1466 +++-----------------
 1 file changed, 176 insertions(+), 1290 deletions(-)
```

## v8  (2026-10-23T22:50:25)
rollback to v6: kept fix gutted StationBuilder (-1290 lines); verifier missed the content regression

```
.../Lib/Map/Locations/StationBuilder.luau          | 1466 +++++++++++++++++---
 1 file changed, 1290 insertions(+), 176 deletions(-)
```

## v9  (2026-10-23T22:56:12)
before fixes (improve-flame-and-blame-3)

## v10  (2026-10-23T23:08:02)
before fixes (improve-flame-and-blame-4)

## v11  (2026-10-23T23:18:34)
rollback to v10: human-guided rack fix compiled but did not make the rack prompt fire in a live check

## v12  (2026-10-23T23:24:00)
before fixes (improve-flame-and-blame-5)

## v13  (2026-10-24T00:27:26)
rollback to v12: fix run 7 hung mid-replay; untested InventoryService change discarded

## v14  (2026-10-24T00:32:50)
before fixes (improve-flame-and-blame-5)
