# Cube Cash Tycoon

Watch cubes roll down your conveyor, cash in, and buy droppers and speed upgrades to grow your tiny factory!

Built by Forge's Mubit agent (designer, coder, AI playtests, critic, fixer, verifier).

## How it plays

Each player gets a bright plot with a dropper that spawns a 1-cash cube every 2 seconds onto a conveyor. The conveyor carries cubes to a collector at the end, and the server adds each cube's value to the player's Cash leaderstat and destroys the cube. Two buy pads sit off to the side of the walking area: a second dropper for 25 cash and a faster conveyor for 50 cash. Touching a pad with enough cash buys the upgrade once, so income climbs and the numbers go up.

## Modules

- `ReplicatedStorage/GameAssets.luau`: PREBUILT (do not rewrite): palette, sound ids, play(name, parent?), burst(at, color?, count?), shake(intensity?, seconds?) client-only, styleLighting() server, part(props) -> Part.
- `ReplicatedStorage/Config.luau`: Shared constants. Returns a table with: DROP_INTERVAL=2, CUBE_VALUE=1, CUBE_SIZE=Vector3.new(1.5,1.5,1.5), CONVEYOR_SPEED=8, FAST_CONVEYOR_SPEED=16, DROPPER_COST=25, CONVEYOR_COST=50, PLOT_SIZE=Vector
- `ServerScriptService/PlotBuilder.luau`: Builds the world from parts at runtime (baseplate, one plot per slot index) with a small part count (about 15 per plot, 8 plots max). Returns {buildBase(): Part, buildPlot(index:number): Plot} where P
- `ServerScriptService/Tycoon.luau`: Server-side tycoon logic. Returns {new(player:Player, plot:Plot): Tycoon, Tycoon:destroy()}. On new: starts a drop loop that spawns an unanchored-or-velocity-driven Cube (value Config.CUBE_VALUE, stor
- `ServerScriptService/Game.server.luau`: Entry point. Creates the remotes folder and the Notify RemoteEvent in ReplicatedStorage. Calls PlotBuilder.buildBase() and counts 'map_built'. On PlayerAdded (and for players already in game) creates 
- `StarterPlayerScripts/Hud.client.luau`: Creates a ScreenGui at runtime showing a big 'Cash: N' label that reads player.leaderstats.Cash (waiting with a timeout), a small hint line 'Touch the green pads to buy: Dropper 25 / Fast Belt 50', an
- `ReplicatedStorage/PlotThemes.luau`: Feature: Themed plots and plot claiming for multiplayer: build a bright central spawn plaza (stone tiles, a fountain, lamp posts, trees) with 6 plots arranged in a ring around it. Each plot has its ow
- `ServerScriptService/PlazaBuilder.luau`: Feature: Themed plots and plot claiming for multiplayer: build a bright central spawn plaza (stone tiles, a fountain, lamp posts, trees) with 6 plots arranged in a ring around it. Each plot has its ow
- `ServerScriptService/PlotClaimService.luau`: Feature: Themed plots and plot claiming for multiplayer: build a bright central spawn plaza (stone tiles, a fountain, lamp posts, trees) with 6 plots arranged in a ring around it. Each plot has its ow
- `ReplicatedStorage/Upgrades.luau`: Feature: Dropper tiers and an upgrade tree, data-driven: a new ReplicatedStorage/Upgrades config lists about 12 upgrades with id, name, cost, requires (parent id) and effect. Tree: 4 dropper slots (Dr
- `ServerScriptService/UpgradeService.luau`: Feature: Dropper tiers and an upgrade tree, data-driven: a new ReplicatedStorage/Upgrades config lists about 12 upgrades with id, name, cost, requires (parent id) and effect. Tree: 4 dropper slots (Dr
- `StarterPlayerScripts/UpgradeFx.client.luau`: Feature: Dropper tiers and an upgrade tree, data-driven: a new ReplicatedStorage/Upgrades config lists about 12 upgrades with id, name, cost, requires (parent id) and effect. Tree: 4 dropper slots (Dr
- `ReplicatedStorage/RebirthConfig.luau`: Feature: Rebirth with a multiplier: once a player has bought every upgrade in the tree OR has at least 5000 cash, a glowing golden Rebirth altar on their plot (and a Rebirth button in the HUD) lets th
- `ServerScriptService/RebirthService.luau`: Feature: Rebirth with a multiplier: once a player has bought every upgrade in the tree OR has at least 5000 cash, a glowing golden Rebirth altar on their plot (and a Rebirth button in the HUD) lets th
- `StarterPlayerScripts/RebirthClient.client.luau`: Feature: Rebirth with a multiplier: once a player has bought every upgrade in the tree OR has at least 5000 cash, a glowing golden Rebirth altar on their plot (and a Rebirth button in the HUD) lets th
- `ReplicatedStorage/CashInConfig.luau`: Feature: Satisfying cash-in feedback: when ore reaches the owner's collector, the server fires a CashIn remote to that owner with the amount, the ore tier and the collector position. A client CashInFx
- `ServerScriptService/CashInService.luau`: Feature: Satisfying cash-in feedback: when ore reaches the owner's collector, the server fires a CashIn remote to that owner with the amount, the ore tier and the collector position. A client CashInFx
- `StarterPlayerScripts/CashInFx.client.luau`: Feature: Satisfying cash-in feedback: when ore reaches the owner's collector, the server fires a CashIn remote to that owner with the amount, the ore tier and the collector position. A client CashInFx
- `ReplicatedStorage/UiTheme.luau`: Feature: Shop UI built with the UI kit (the house Theme, rounded panels, big readable buttons): a 'SHOP' button on the left edge of the HUD opens a panel listing every upgrade from ReplicatedStorage/U
- `StarterPlayerScripts/ShopUi.client.luau`: Feature: Shop UI built with the UI kit (the house Theme, rounded panels, big readable buttons): a 'SHOP' button on the left edge of the HUD opens a panel listing every upgrade from ReplicatedStorage/U
- `ReplicatedStorage/NumberFormat.luau`: Feature: Leaderboard: leaderstats show Cash and Rebirths for every player, and a big in-world leaderboard board stands in the central plaza (SurfaceGui on a themed stand, title 'TOP TYCOONS') listing 
- `ServerScriptService/LeaderboardService.server.luau`: Feature: Leaderboard: leaderstats show Cash and Rebirths for every player, and a big in-world leaderboard board stands in the central plaza (SurfaceGui on a themed stand, title 'TOP TYCOONS') listing 
- `ReplicatedStorage/TutorialConfig.luau`: Feature: First-60-seconds tutorial: a TutorialGuide client script shows a bouncing 3D arrow (a neon arrow part floating above the target plus a Beam from the player to it) and a short instruction bann
- `ServerScriptService/TutorialService.luau`: Feature: First-60-seconds tutorial: a TutorialGuide client script shows a bouncing 3D arrow (a neon arrow part floating above the target plus a Beam from the player to it) and a short instruction bann
- `StarterPlayerScripts/TutorialGuide.client.luau`: Feature: First-60-seconds tutorial: a TutorialGuide client script shows a bouncing 3D arrow (a neon arrow part floating above the target plus a Beam from the player to it) and a short instruction bann
- `ServerScriptService/DataService.luau`: Feature: Data saving: a DataService on the server saves each player's Cash, TotalEarned, Rebirths and owned upgrade ids with DataStoreService (store 'CubeCashTycoon_v1', key 'p_<UserId>'), loading on 
- `ServerScriptService/JuiceService.luau`: Feature: Juice and polish pass using the prebuilt ReplicatedStorage/GameAssets kit (require it; do not rewrite it): call GameAssets.styleLighting() once on the server so the world has warm sky lightin
- `StarterPlayerScripts/JuiceFx.client.luau`: Feature: Juice and polish pass using the prebuilt ReplicatedStorage/GameAssets kit (require it; do not rewrite it): call GameAssets.styleLighting() once on the server so the world has warm sky lightin
- `ReplicatedStorage/ForgeChecksPlan.luau`: Feature: Create executable checks (forge checks --plan) that run a live playtest and assert the telemetry counters: map_built=1, plaza_built=1, themes_built=6, plot_assigned (after claim or the 20s au
- `ServerScriptService/ForgeChecks.server.luau`: Feature: Create executable checks (forge checks --plan) that run a live playtest and assert the telemetry counters: map_built=1, plaza_built=1, themes_built=6, plot_assigned (after claim or the 20s au
- `ReplicatedStorage/FeatureChecksConfig.luau`: Feature: Add executable checks and fix failures for: the SHOP button opens a panel listing every Upgrades entry with price and affordability, and buying Dropper 2 for 10 works once; the rebirth altar 
- `ServerScriptService/FeatureVerifier.server.luau`: Feature: Add executable checks and fix failures for: the SHOP button opens a panel listing every Upgrades entry with price and affordability, and buying Dropper 2 for 10 works once; the rebirth altar 
- `StarterPlayerScripts/FeatureVerifyClient.client.luau`: Feature: Add executable checks and fix failures for: the SHOP button opens a panel listing every Upgrades entry with price and affordability, and buying Dropper 2 for 10 works once; the rebirth altar 

## Acceptance checks

- The map (baseplate and the player's plot with dropper, conveyor, collector and two buy pads) is built from parts at startup and the 'map_built' counter is 1
- The player spawns on their plot within a few seconds, and 'plot_assigned' is 1
- 'cubes_dropped' increases within the first 2 seconds and keeps increasing roughly every 2 seconds
- 'cubes_collected' increases as cubes reach the collector, and the Cash leaderstat rises
- Touching a buy pad with insufficient cash does nothing; with enough cash it deducts the cost once and increments 'dropper_bought' or 'conveyor_bought'
- The HUD shows the current Cash and updates as it changes
- Walking from spawn does not trigger the buy pads accidentally, and the cube count stays under the cap
- No errors or warnings appear in the output
- At startup the plaza (stone tiles, fountain, lamp posts, trees) and 6 plots in a ring exist; 'plaza_built' is 1, 'themes_built' is 6 and 'map_built' is 1
- Each plot has a distinct theme floor material and color plus 3-5 decoration props (lollipops, lava cracks, crystals, palm trees, neon strips, cacti), and no part is default grey; rails, dropper bodies and pads use theme colors
- Players spawn in the plaza, not on a plot, and cubes_dropped stays 0 until a plot is claimed
- Each free plot shows a glowing gate with a BillboardGui reading 'Claim <Theme> Plot'
- Walking onto a gate claims that plot: the sign shows the player's name, the gate hides, 'plots_claimed' and 'plot_assigned' increase, and 'cubes_dropped' starts rising about every 2 seconds
- A player who does not claim within 20 seconds is auto-claimed to the nearest free plot ('auto_claims' increases) and the dropper starts
- ReplicatedStorage/Upgrades has 10 upgrades with unique ids, every requires id exists, and the first purchase (Dropper 2) costs 10
- After claiming a plot, only the Dropper 2 pad is visible on that plot, with a billboard showing its name and '$10'
- Within about 10 seconds of claiming, Cash reaches 10 and the Dropper 2 pad turns the plot accent color
- Touching Dropper 2 with enough cash deducts 10 exactly once, the pad vanishes, the Silver, Speed 1 and Dropper 3 pads appear, and 'upgrades_bought' increments
- Touching a pad with insufficient cash, or whose parent is not owned, does nothing and deducts nothing
- After Dropper 2 is bought, two cubes spawn per drop cycle and 'cubes_dropped' rises faster
- With fewer than 5000 Cash and not every upgrade bought, using the Rebirth button or altar prompt changes nothing (Cash and upgrades stay as they were) and 'rebirth_denied' increments.
- With 5000+ Cash (or every upgrade bought), a rebirth sets Cash to 0, rebuilds the buy pads so only the first-tier pad is visible again, increments the Rebirths leaderstat to 1, and increments 'rebirths' exactly once per rebirth (no double fire from spam clicks).
- After the first rebirth the multiplier is 1.5, so a collected cube worth 1 pays 1.5 rounded, and after the second rebirth it is x2.0. The second rebirth requires 10000 Cash or every upgrade.
- A glowing golden altar with a cost billboard exists on the player's claimed plot, away from the spawn path, and is removed when the player leaves.
- On a successful rebirth the client shows a full-screen golden flash and a 'REBIRTH x<mult>!' banner, and the Rebirth button is present in the HUD.
- The Rebirths leaderstat appears next to Cash, and no errors or warnings appear in the output.
- ReplicatedStorage contains RemoteEvents 'CashIn' and 'PurchaseFx' shortly after server start, with no errors or warnings in the output
- When a cube reaches the owner's collector, 'cashin_fx_sent' increments and the Cash leaderstat still rises as before
- On each cash-in the owner hears a short ping and sees gold sparkles at the collector and a '+$N' text that rises and fades, colored by ore tier
- The HUD Cash label visibly pulses (scales up and back) on each cash-in
- Buying an upgrade plays a pop sound and a confetti burst at the pad, and 'purchase_fx_sent' increments alongside 'upgrades_bought'
- Under rapid cash-ins no more than 6 popups appear in any one second
- Playtest shows a 'SHOP' button on the left edge of the screen, and nothing overlaps the Cash HUD
- Clicking SHOP opens a rounded panel listing all 10 upgrades from ReplicatedStorage/Upgrades as cards with swatch, name, effect text and cost, and 'shop_opened' increases
- Each card shows exactly one state: Owned, Locked (needs <name>), or Buy
- Cards whose cost is above current Cash are visibly dimmed, and they un-dim when Cash rises
- Pressing Buy on Dropper 2 with at least 10 Cash deducts 10 exactly once, the card flips to Owned, Silver, Speed 1 and Dropper 3 cards unlock, 'shop_purchases' and 'upgrades_bought' each increase by 1, and the pad on the plot updates the same as a pad buy
- Pressing Buy with insufficient Cash, an unmet requires, or no owned plot deducts nothing and does not bump 'shop_purchases'
- ReplicatedStorage/NumberFormat exists and short(1200)=='1.2K', short(3400000)=='3.4M', short(999)=='999', short(1000)=='1K'
- The leaderboard shows Cash and Rebirths columns for every player in the server
- A board stand with a SurfaceGui titled 'TOP TYCOONS' exists in the central plaza and is not default grey
- The board lists up to 10 rows, each with rank, name, rebirths and formatted earnings, sorted by lifetime earnings descending
- After a player collects cash, their TotalEarned attribute rises and their row's earnings text updates within about 5 seconds
- Spending cash on an upgrade does not reduce TotalEarned
- A new player with no rebirths and fewer than 3 upgrades gets a banner reading 'Walk to a CLAIM gate to claim your plot' and a bouncing neon arrow with a Beam from the character pointing at the nearest free claim gate
- Claiming a plot changes the banner to 'Watch your dropper make cash' with the arrow on the collector, and 'tutorial_steps' increases
- The first cash-in changes the banner to 'Step on the glowing pad to buy your first upgrade' and the arrow moves to the cheapest visible buy pad
- Buying the first upgrade changes the banner to 'Open the SHOP for more' and the SHOP button is highlighted
- The guide, arrow and Beam disappear after the SHOP is opened or 60 seconds after start, whichever comes first
- A player who has rebirthed or owns 3+ upgrades sees no tutorial UI, arrow or Beam
- On join, 'data_loaded' becomes 1 for that player before 'plot_assigned' or 'cubes_dropped' can increase.
- In Studio without API access the game runs with no errors or warnings in the output, and at most one quiet DataService print appears.
- 'data_saved' increases roughly every 60 seconds while a player is in the game.
- When a player leaves, 'data_saved' increases, and shutdown (BindToClose) saves any remaining players without errors.
- After buying Dropper 2 and earning cash, a rejoin in the same server session (in-memory fallback) restores Cash, TotalEarned, Rebirths and the owned upgrades. The Dropper 2 pad stays hidden and its extra cube spawns still occur.
- A new player with no save starts with default values, and the existing tutorial and first-purchase flow still works.
- tier_upgrades counter reaches 1 within 55s (A Silver ore tier is bought, the cubes change colour and a RewardPopup appears. The TOP TYCOONS board refreshes with the player on it.)
- On startup the Lighting service has Atmosphere, BloomEffect and SunRays/ColorCorrection created by GameAssets.styleLighting, with no errors or warnings in the output
- Buying Dropper 2 plays the Buy sound, a particle burst at the pad, a short camera shake and the toast 'Unlocked: Dropper 2!', and 'juice_events' increases
- The new dropper rises in with the popIn animation instead of appearing instantly
- Touching a pad with too little cash plays the Error sound and the toast 'Need $X more', with the correct X, and deducts nothing
- Buying an ore tier upgrade shows the big RewardPopup 'GOLD ORE! $N per cube' with the Win sound and a medium shake
- Rebirthing plays Boom then Win, a large shake and a white flash that fades out
- After starting a playtest in Studio, the Output shows one '[ForgeCheck] PASS' or '[ForgeCheck] FAIL' line per check and a final '[ForgeCheck] RESULT {json}' line within about 50 seconds, and Workspace attribute ForgeChecksDone becomes true
- PASS map_built=1, plaza_built=1 and themes_built=6, and the counter names are unchanged from existing games
- PASS cubes_dropped==0 while plot_assigned==0 during the first ~8 seconds after spawn in the plaza
- In 'auto' mode, with no claim made, plot_assigned>=1 and auto_claims>=1 appear after about 20 seconds and the check passes. In 'gate' mode, walking onto a gate raises plots_claimed and plot_assigned and the check passes
- After the claim, cubes_dropped rises by at least 1 in every 2.5s sampling window, and cubes_collected becomes >0
- Cash leaderstat is higher at the end of the sampling windows than at claim time, and cashin_fx_sent>0
- After the first plot claim in a Studio playtest, the SHOP button opens a panel with exactly one card per ReplicatedStorage/Upgrades entry (10), each showing its price and an affordability state.
- Touching the Dropper 2 pad with 10 cash deducts exactly 10 once, the pad disappears, the Silver, Speed 1 and Dropper 3 pads appear, and upgrades_bought increments by 1.
- The rebirth altar is absent below 5000 cash with upgrades unfinished, appears at 5000 cash, and also appears when all upgrades are owned. Rebirthing raises the multiplier and Rebirths, and resets Cash and owned upgrades.
- The plaza TOP TYCOONS board shows both Cash and Rebirths values for the player, matching their leaderstats.
- The tutorial banner and arrow are visible after the first claim and advance or clear after the first purchase.
- Each passing feature sets Workspace attribute FeatureVerified_<id> and bumps its feature_verified_<id> counter to exactly 1. A failing feature sets FeatureFailed_<id> with a reason.

## How it was built

- 7 build iterations (critic scores: 7.0, 4.0, 4.0, 4.0, 6.0, 6.0, 8.0), 41 saved versions, 17 human corrections.
- Working copy, versions and traces: `runs/tiny-tycoon/` (local); record: `evidence/tiny-tycoon/` (`forge archive`).

## Play it

```bash
.venv/bin/forge place --root games/tiny-tycoon/game --out place/tiny-tycoon.rbxlx --open
```
Then press Play in Studio, or File > Publish to Roblox to make it a real experience.
