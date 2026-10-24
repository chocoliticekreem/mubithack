# Cube Cash Tycoon

Watch cubes roll down your conveyor, cash in, and buy droppers and speed upgrades to grow your tiny factory!

Built by Forge's Mubit agent (designer, coder, AI playtests, critic, fixer, verifier).

## How it plays

Each player gets a bright plot with a dropper that spawns a 1-cash cube every 2 seconds onto a conveyor. The conveyor carries cubes to a collector at the end, and the server adds each cube's value to the player's Cash leaderstat and destroys the cube. Two buy pads sit off to the side of the walking area: a second dropper for 25 cash and a faster conveyor for 50 cash. Touching a pad with enough cash buys the upgrade once, so income climbs and the numbers go up.

## Modules

- `ReplicatedStorage/Config.luau`: Shared constants. Returns a table with: DROP_INTERVAL=2, CUBE_VALUE=1, CUBE_SIZE=Vector3.new(1.5,1.5,1.5), CONVEYOR_SPEED=8, FAST_CONVEYOR_SPEED=16, DROPPER_COST=25, CONVEYOR_COST=50, PLOT_SIZE=Vector
- `ServerScriptService/PlotBuilder.luau`: Builds the world from parts at runtime (baseplate, one plot per slot index) with a small part count (about 15 per plot, 8 plots max). Returns {buildBase(): Part, buildPlot(index:number): Plot} where P
- `ServerScriptService/Tycoon.luau`: Server-side tycoon logic. Returns {new(player:Player, plot:Plot): Tycoon, Tycoon:destroy()}. On new: starts a drop loop that spawns an unanchored-or-velocity-driven Cube (value Config.CUBE_VALUE, stor
- `ServerScriptService/Game.server.luau`: Entry point. Creates the remotes folder and the Notify RemoteEvent in ReplicatedStorage. Calls PlotBuilder.buildBase() and counts 'map_built'. On PlayerAdded (and for players already in game) creates 
- `StarterPlayerScripts/Hud.client.luau`: Creates a ScreenGui at runtime showing a big 'Cash: N' label that reads player.leaderstats.Cash (waiting with a timeout), a small hint line 'Touch the green pads to buy: Dropper 25 / Fast Belt 50', an

## Acceptance checks

- The map (baseplate and the player's plot with dropper, conveyor, collector and two buy pads) is built from parts at startup and the 'map_built' counter is 1
- The player spawns on their plot within a few seconds, and 'plot_assigned' is 1
- 'cubes_dropped' increases within the first 2 seconds and keeps increasing roughly every 2 seconds
- 'cubes_collected' increases as cubes reach the collector, and the Cash leaderstat rises
- Touching a buy pad with insufficient cash does nothing; with enough cash it deducts the cost once and increments 'dropper_bought' or 'conveyor_bought'
- The HUD shows the current Cash and updates as it changes
- Walking from spawn does not trigger the buy pads accidentally, and the cube count stays under the cap
- No errors or warnings appear in the output

## How it was built

- 2 build iterations (critic scores: 7.0, 7.0), 7 saved versions, 0 human corrections.
- Working copy, versions and traces: `runs/tiny-tycoon-each-player-gets-a/` (local); record: `evidence/tiny-tycoon-each-player-gets-a/` (`forge archive`).

## Play it

```bash
.venv/bin/forge place --root games/tiny-tycoon/game --out place/tiny-tycoon.rbxlx --open
```
Then press Play in Studio, or File > Publish to Roblox to make it a real experience.
