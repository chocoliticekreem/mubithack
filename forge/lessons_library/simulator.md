# Roblox simulator best practices
- Core loop: click or swing a tool to gather -> backpack fills (capacity bar) -> sell at a sell pad -> buy bigger tools and backpacks -> unlock new zones behind priced gates.
- The first upgrade is affordable after ~20 seconds of gathering.
- Every click: tool swing tween, a sound with a slight random pitch, "+N" floating text, counter punch.
- Full backpack: the capacity bar flashes red with a toast "Backpack full! Sell at the pad".
- Zones: 3+ zones with rising value and distinct colour themes; gates show a price billboard.
- Pets or boosts as free rewards (timed gifts, eggs bought with in-game currency), with the multiplier shown on the HUD.
- Rebirth for a permanent multiplier; a leaderboard of top gatherers.
- Telemetry counters: click, item_gathered, sold, upgrade_bought, zone_unlocked, rebirth.
