## Curated genre lessons (forge/lessons_library)
# Roblox tycoon best practices
- Give the player their own plot instantly on join (auto-claim, or a big glowing CLAIM pad beside spawn) and teleport them onto it.
- Core loop: droppers spawn ore parts that roll along a conveyor into a collector that pays cash; the player walks onto buy pads to unlock the next item. The first dropper is FREE or costs what the player earns in ~5 seconds.
- Use 3+ dropper tiers (different colours and values), conveyor speed upgrades, a collector multiplier and decorative unlocks (walls, floor, lamps, sign) so the plot visibly grows from bare to busy.
- Buy pads: a Neon pad with a PriceBillboard, green when affordable and red when not; only the next 1-3 pads are visible so the path is obvious. On purchase the pad vanishes with a pop, the unlocked model rises/scales in with a Back tween, sparkles burst, a purchase sound plays and the cash counter punches.
- Rebirth: at a cash threshold, reset cash and unlocks for a permanent multiplier (x1.5, x2, ...); show the requirement as a progress bar and celebrate with a RewardPopup plus a camera shake.
- Upgrade tree: 3 branches (income, speed, luck), each with 3-5 levels and growing costs, shown in a Panel with StyledButtons.
- Leaderboard: leaderstats Cash and Rebirths, plus a top-players board (HUD or in-world).
- Economy pacing: the next purchase is reachable in 15-40 s early on; costs x1.4 per step; income per second is visible on the HUD ("+$12/s").
- Collector feedback: each ore collected flashes the collector, plays a soft tick and shows "+$N" floating text; batch client updates (at most ~10 remote events per second).
- Server-authoritative cash; buy pads check cash and plot ownership on the server; ore parts are destroyed on collection and capped (e.g. 60 live ores per plot) so the server never lags.
- Telemetry counters: plot_claimed, ore_spawned, ore_collected, cash_earned, item_bought, upgrade_bought, rebirth.

# Fun-first rules (every game)
- The first 10 seconds decide everything: the player spawns facing the core action, sees one glowing obvious thing to do, and gets a reward for doing it within 5 seconds.
- Every player action gets layered feedback: a sound, a particle burst or flash, a UI punch/tween, and a number change. Big moments (unlock, level up, rebirth, win) add a camera shake and a centre RewardPopup.
- Numbers go up visibly: leaderstats plus a HUD counter that ticks up and pops; show "+N" floating text where the reward happened.
- Always show the next goal: a progress bar or a price tag that turns green when affordable, so the player always knows what to save for.
- Pace: a new unlock or upgrade every 20-40 seconds in the first 3 minutes, then slower; costs grow ~1.3-1.6x per step and income grows with them.
- No placeholder grey: every part sets Color and Material from one bright palette (SmoothPlastic, Neon accents, Wood/Grass/Brick/Slate for ground and walls). Set Lighting (ClockTime ~14, Brightness 2-3, an Atmosphere, Bloom and a ColorCorrection with Saturation ~0.15) so the world pops.
- Sounds: one short sound per action (collect, buy, error, unlock, jump pad) and soft looping music at low volume. UI sounds play on the client (SoundService:PlayLocalSound); world sounds are parented to the part. Use the game's sound table, never invented asset ids.
- Rewards without monetisation: a free timed gift every few minutes, streak multipliers, cosmetic unlocks (trails, colours), a rebirth multiplier, achievements shown as toasts.
- Readable world: a sign or BillboardGui on every interactive object; interactive things glow (Neon or a Highlight) or bob/spin with a tween.
- Solo-playable: everything works with one player; a leaderboard still shows the solo player.

