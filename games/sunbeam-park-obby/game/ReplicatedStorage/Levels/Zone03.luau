-- Zone 3: Bumper Blast Arena (stages 21-30). Level data written by `forge levels` (Mubit level_designer), built by ObbyKit. Data, not code.
return {
	zone = 3,
	name = "Bumper Blast Arena",
	theme = "A neon bumper-car arena with rubber walls, flying sparks, sliding movers and conveyor car tracks",
	theme_id = "bumper",
	palette = { "#22B8EE", "#FFD23F", "#FF4F6D" },
	material = "SmoothPlastic",
	stages = {
		{ stage = 21, name = "Fender Bender", pieces = {
			{ kind = "conveyor", gap = 4, rise = 0, side = 0, coins = 0, size = { 8, 1, 16 }, speed = 4, dir = "forward" },
			{ kind = "platform", gap = 4, rise = 0, side = 2, coins = 2, size = { 10, 1, 10 }, shape = "round" },
			{ kind = "conveyor", gap = 4, rise = 0, side = -2, coins = 0, size = { 8, 1, 14 }, speed = 5, dir = "forward" },
			{ kind = "checkpoint", gap = 4, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 22, name = "Flicker Floor", pieces = {
			{ kind = "disappearing", gap = 4, rise = 0, side = 0, coins = 0, size = { 6, 1, 6 }, count = 3, spacing = 3, on = 3.5, off = 1.5, stagger = 0.6 },
			{ kind = "platform", gap = 4, rise = 0, side = 3, coins = 2, size = { 10, 1, 10 }, shape = "round" },
			{ kind = "lava", gap = 1, rise = 0, side = 3, size = { 10, 1, 3 } },
			{ kind = "platform", gap = 2, rise = 0, side = 0, coins = 1, size = { 10, 1, 8 }, shape = "block" },
			{ kind = "checkpoint", gap = 4, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 23, name = "Dodgem Dash", pieces = {
			{ kind = "moving", gap = 4, rise = 0, side = 0, coins = 0, size = { 7, 1, 7 }, move = { 0, 0, 6 }, period = 5, phase = 0 },
			{ kind = "platform", gap = 8, rise = 0, side = 0, coins = 2, size = { 10, 1, 10 }, shape = "round" },
			{ kind = "conveyor", gap = 4, rise = 0, side = 0, coins = 0, size = { 8, 1, 14 }, speed = 4, dir = "right" },
			{ kind = "platform", gap = 4, rise = 0, side = 0, coins = 0, size = { 8, 2, 8 }, shape = "wedge-ramp" },
			{ kind = "checkpoint", gap = 4, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 24, name = "Bounce Back", turn = -90, pieces = {
			{ kind = "jumppad", gap = 4, rise = 0, side = 0, coins = 0, size = { 6, 1, 6 }, power = 90, forward = 20 },
			{ kind = "checkpoint", gap = 6, rise = 16, side = 0, coins = 0 },
		} },
		{ stage = 25, name = "Soft Landing", turn = -90, pieces = {
			{ kind = "conveyor", gap = 4, rise = 0, side = 0, coins = 0, size = { 8, 1, 16 }, speed = 4, dir = "forward" },
			{ kind = "platform", gap = 4, rise = -6, side = 2, coins = 2, size = { 9, 1, 9 }, shape = "round" },
			{ kind = "platform", gap = 4, rise = -6, side = -2, coins = 2, size = { 8, 1, 8 }, shape = "block" },
			{ kind = "checkpoint", gap = 4, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 26, name = "Spark Alley", pieces = {
			{ kind = "moving", gap = 4, rise = 0, side = 0, coins = 0, size = { 8, 1, 8 }, move = { 0, 0, 6 }, period = 5, phase = 0 },
			{ kind = "conveyor", gap = 8, rise = 0, side = 0, coins = 0, size = { 8, 1, 14 }, speed = 4, dir = "back" },
			{ kind = "platform", gap = 4, rise = 0, side = 2, coins = 0, size = { 10, 4, 4 }, shape = "cylinder" },
			{ kind = "disappearing", gap = 5, rise = 0, side = 0, coins = 0, size = { 5, 1, 5 }, count = 2, spacing = 3, on = 3.5, off = 1.5, stagger = 0.6 },
			{ kind = "checkpoint", gap = 4, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 27, name = "Rubber Elevator", turn = -90, pieces = {
			{ kind = "moving", gap = 3, rise = 0, side = 0, coins = 0, size = { 7, 1, 7 }, move = { 0, 16, 0 }, period = 6, phase = 0 },
			{ kind = "checkpoint", gap = 3, rise = 16, side = 0, coins = 0 },
		} },
		{ stage = 28, name = "Crash Course", turn = -90, pieces = {
			{ kind = "conveyor", gap = 4, rise = 0, side = 0, coins = 0, size = { 8, 1, 12 }, speed = 6, dir = "forward" },
			{ kind = "platform", gap = 4, rise = 1, side = 3, coins = 0, size = { 10, 4, 4 }, shape = "cylinder" },
			{ kind = "disappearing", gap = 4, rise = 0, side = -2, coins = 0, size = { 5, 1, 5 }, count = 3, spacing = 2, on = 3.5, off = 1.5, stagger = 0.6 },
			{ kind = "platform", gap = 6, rise = 0, side = 2, coins = 2, size = { 10, 1, 10 }, shape = "round" },
			{ kind = "checkpoint", gap = 4, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 29, name = "Pad Party", pieces = {
			{ kind = "jumppad", gap = 4, rise = 0, side = 0, coins = 0, size = { 6, 1, 6 }, power = 90, forward = 20 },
			{ kind = "platform", gap = 8, rise = 8, side = 0, coins = 3, size = { 10, 1, 10 }, shape = "block" },
			{ kind = "platform", gap = 4, rise = -8, side = 0, coins = 0, size = { 9, 1, 9 }, shape = "round" },
			{ kind = "moving", gap = 4, rise = 0, side = 0, coins = 0, size = { 7, 1, 7 }, move = { 0, 0, 6 }, period = 5, phase = 0 },
			{ kind = "checkpoint", gap = 8, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 30, name = "Grand Prix Pileup", pieces = {
			{ kind = "conveyor", gap = 4, rise = 0, side = 0, coins = 0, size = { 6, 1, 8 }, speed = 8, dir = "forward" },
			{ kind = "platform", gap = 5, rise = 2, side = -2, coins = 2, size = { 8, 1, 8 }, shape = "round" },
			{ kind = "disappearing", gap = 5, rise = 1, side = 2, coins = 0, size = { 4, 1, 4 }, count = 3, spacing = 3, on = 3.5, off = 1.5, stagger = 0.6 },
			{ kind = "moving", gap = 5, rise = 0, side = 0, coins = 0, size = { 6, 1, 6 }, move = { 0, 0, 6 }, period = 4, phase = 0 },
			{ kind = "checkpoint", gap = 8, rise = 1, side = 0, coins = 0 },
		} },
	},
}
