# Roblox obby best practices
- Spawn on a bright start platform facing the first jump; stage 1 is trivially easy so the player reaches the first checkpoint within 10 seconds.
- Checkpoints: big glowing pads with the stage number on a BillboardGui; touching one saves the stage (leaderstat Stage), plays a ding, bursts sparkles and shows a toast "Stage 3!"; the player respawns at the latest checkpoint.
- Difficulty curve: alternate easy and hard stages; introduce one new obstacle type every 2-3 stages (moving platforms, spinning bars, disappearing tiles, jump pads, conveyors, kill bricks).
- Kill bricks are clearly red Neon; safe parts use calm colours. Never punish with invisible hazards.
- Coins along the path (spinning, bobbing gold parts) give a second goal: collecting plays a coin sound and "+1" floating text; coins buy speed/jump boosts or trails.
- HUD: stage counter, coin counter, a progress bar of stages completed, a reset button.
- Juice: jump pads launch with a whoosh and particles; disappearing tiles flash before vanishing; finishing shows a RewardPopup, confetti and the finish time.
- Telemetry counters: checkpoint_reached, coin_collected, player_died, stage_completed, jump_pad_used.
