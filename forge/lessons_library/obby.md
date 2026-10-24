# Roblox obby best practices
- Spawn on a bright start pad facing the first jump; stage 1 is trivially easy so the player reaches the first checkpoint within 10 seconds.
- Checkpoints: big glowing pads with the stage number; touching one saves the stage (leaderstat Stage, DataStore), plays a ding, bursts sparkles and toasts "Stage 3!"; respawn on the latest checkpoint within 1-2 s.
- Kill bricks are clearly red Neon; hazards are telegraphed (tiles flash before vanishing). Never punish with invisible hazards or long falls: a fall returns you to your checkpoint.
- Coins along the path give a second goal (coin sound, "+1"); they buy trails, speed or gravity coils.
- HUD: "Stage 47/200", the zone's name, a progress bar, coins, a reset button.
- Juice: jump pads whoosh with particles; finishing shows confetti, a big sound, a title or badge and the finish time.
- Telemetry counters: checkpoint_reached, coin_collected, player_died, jump_pad_used.
## A great long obby (100-200 stages)
- Stages are level data (one module per zone), validated jump by jump, never parts hand-placed in code.
- Zones of ~20 stages, each a themed section with its own name, palette, gate sign and music.
- Difficulty is a sawtooth rising across the course: each zone ramps up, every 5th stage is a breather, its last stage is the finale.
- A new mechanic or variation every few stages (zigzags, climbs, drops, beams, ferries, elevators, tile waves, back conveyors, spinners, pendulums), first alone in an easy stage, then combined.
- Fair jumps only: about 10 studs flat, 7 when rising 6 (walk 16, jump height 7.2).
- Lobby around the start: title, leaderboard of the highest stages, a trail shop. Optional: skip stage (Robux), rebirth.
