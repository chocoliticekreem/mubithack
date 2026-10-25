-- Rendered by Forge (forge/template.py) from spec.json: do not edit. The zones are the level designer's
-- (`forge levels`), so they match the level data one to one.
return {
	Title = "Sunbeam Park Obby",
	Zones = {
		{ name = "Sunbeam Gate Plaza", theme = "entrance", palette = { "#E63946", "#FFC23D", "#3A86FF" }, mood = "carnival" },
		{ name = "Carousel Canter", theme = "carousel", palette = { "#FF5FA8", "#FFC23D", "#6EC6FF" }, mood = "carnival" },
		{ name = "Bumper Blast Arena", theme = "bumper", palette = { "#22B8EE", "#FFD23F", "#FF4F6D" }, mood = "pop" },
		{ name = "Teacup Twirl", theme = "teacups", palette = { "#A77BFF", "#5ED6B4", "#FF8EC2" }, mood = "carnival" },
		{ name = "Skywheel Heights", theme = "ferris", palette = { "#FF7A2F", "#3FB8F5", "#FFE066" }, mood = "pop" },
		{ name = "Log Flume Falls", theme = "flume", palette = { "#1FA896", "#2F7BFF", "#F4D06F" }, mood = "water" },
		{ name = "Boo Manor", theme = "haunted", palette = { "#6A3FB5", "#7CFF6B", "#FF8A3D" }, mood = "spooky" },
		{ name = "Buccaneer Bay", theme = "pirate", palette = { "#D7263D", "#F2C14E", "#24407A" }, mood = "pirate" },
		{ name = "Thunder Rail Coaster", theme = "coaster", palette = { "#E63946", "#FFD23F", "#1D3557" }, mood = "intense" },
		{ name = "Fireworks Finale", theme = "finale", palette = { "#3A2E8F", "#FFC23D", "#FF4FA3" }, mood = "victory" },
	},
	Costumes = { "MouseEars", "BalloonHat", "PartyCone", "ClownWig", "HeroCape", "TopHat", "StarCape", "FireTrail", "RainbowTrail", "Crown", "ChampionCape" },
	Rewards = { "ChampionCape" },
	AutoEquip = "MouseEars",
	FinishReward = "ChampionCape",
	Seed = 7,
}
