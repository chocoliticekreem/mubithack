-- Zone 8: Buccaneer Bay (stages 71-80). Level data written by `forge levels` (Mubit level_designer), built by ObbyKit. Data, not code.
return {
	zone = 8,
	name = "Buccaneer Bay",
	theme = "The swinging pirate ship: dodge pendulum cannonballs and ride sliding decks on the way up the mast",
	theme_id = "pirate",
	palette = { "#9C6B3C", "#F2C14E", "#24407A" },
	material = "Wood",
	stages = {
		{ stage = 71, name = "Walk the Plank", pieces = {
			{ kind = "pendulum", gap = 4, rise = 0, side = 0, coins = 0, size = { 6, 1, 14 }, swing = 60, period = 4, length = 10, phase = 0 },
			{ kind = "platform", gap = 5, rise = 0, side = 3, coins = 2, size = { 8, 1, 8 }, shape = "round" },
			{ kind = "moving", gap = 5, rise = 1, side = -2, coins = 0, size = { 7, 1, 7 }, move = { 0, 0, 4 }, period = 5, phase = 0 },
			{ kind = "platform", gap = 6, rise = 0, side = 0, coins = 2, size = { 8, 1, 6 }, shape = "block" },
			{ kind = "checkpoint", gap = 5, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 72, name = "Deck Hands", pieces = {
			{ kind = "conveyor", gap = 4, rise = 0, side = 0, coins = 0, size = { 6, 1, 12 }, speed = 6, dir = "forward" },
			{ kind = "moving", gap = 6, rise = 1, side = -2, coins = 0, size = { 7, 1, 7 }, move = { 0, 0, 5 }, period = 5, phase = 0 },
			{ kind = "pendulum", gap = 7, rise = 0, side = 2, coins = 0, size = { 6, 1, 12 }, swing = 55, period = 3.5, length = 11, phase = 0 },
			{ kind = "platform", gap = 5, rise = 0, side = -3, coins = 2, size = { 8, 1, 8 }, shape = "round" },
			{ kind = "checkpoint", gap = 5, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 73, name = "Crow's Nest Hop", pieces = {
			{ kind = "disappearing", gap = 4, rise = 0, side = 0, coins = 0, size = { 5, 1, 5 }, count = 3, spacing = 3, on = 3, off = 1.5, stagger = 0.6 },
			{ kind = "turntable", gap = 6, rise = 1, side = 2, coins = 0, size = { 12, 1, 12 }, speed = 40 },
			{ kind = "pendulum", gap = 5, rise = 0, side = 0, coins = 0, size = { 6, 1, 12 }, swing = 60, period = 4, length = 10, phase = 0 },
			{ kind = "checkpoint", gap = 5, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 74, name = "Cannon Launch", turn = -90, pieces = {
			{ kind = "jumppad", gap = 4, rise = 0, side = 0, coins = 0, size = { 6, 1, 6 }, power = 90, forward = 20 },
			{ kind = "checkpoint", gap = 6, rise = 16, side = 0, coins = 0 },
		} },
		{ stage = 75, name = "Calm Waters", turn = -90, pieces = {
			{ kind = "conveyor", gap = 4, rise = 0, side = 0, coins = 0, size = { 8, 1, 12 }, speed = 4, dir = "forward" },
			{ kind = "platform", gap = 4, rise = 1, side = 0, coins = 0, size = { 10, 4, 4 }, shape = "cylinder" },
			{ kind = "moving", gap = 5, rise = 0, side = 2, coins = 0, size = { 8, 1, 8 }, move = { 0, 0, 4 }, period = 6, phase = 0 },
			{ kind = "platform", gap = 6, rise = 0, side = 0, coins = 3, size = { 10, 1, 10 }, shape = "block" },
			{ kind = "checkpoint", gap = 4, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 76, name = "Mast Spinner", pieces = {
			{ kind = "spinner", gap = 4, rise = 0, side = 0, coins = 0, size = { 14, 1, 14 }, speed = 70, bar_height = 2 },
			{ kind = "moving", gap = 7, rise = 2, side = -2, coins = 0, size = { 6, 1, 6 }, move = { 0, 0, 5 }, period = 3.5, phase = 0 },
			{ kind = "pendulum", gap = 7, rise = 1, side = 2, coins = 0, size = { 5, 1, 12 }, swing = 65, period = 2.8, length = 10, phase = 0 },
			{ kind = "platform", gap = 6, rise = -2, side = -2, coins = 1, size = { 6, 1, 6 }, shape = "block" },
			{ kind = "checkpoint", gap = 5, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 77, name = "Sail Spring", turn = -90, pieces = {
			{ kind = "trampoline", gap = 4, rise = 0, side = 0, coins = 0, size = { 7, 1, 7 }, bounce = 70 },
			{ kind = "checkpoint", gap = 4, rise = 15, side = 0, coins = 0 },
		} },
		{ stage = 78, name = "Barrel Roll", turn = -90, pieces = {
			{ kind = "moving", gap = 4, rise = 0, side = 0, coins = 0, size = { 6, 1, 6 }, move = { 0, 0, 6 }, period = 3.5, phase = 0 },
			{ kind = "platform", gap = 8, rise = 1, side = 2, coins = 1, size = { 7, 1, 7 }, shape = "round" },
			{ kind = "disappearing", gap = 7, rise = 1, side = -2, coins = 0, size = { 4, 1, 4 }, count = 3, spacing = 3, on = 2.5, off = 1.5, stagger = 0.6 },
			{ kind = "platform", gap = 7, rise = -1, side = 1, coins = 1, size = { 6, 1, 6 }, shape = "block" },
			{ kind = "checkpoint", gap = 5, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 79, name = "Cannonball Alley", pieces = {
			{ kind = "pendulum", gap = 4, rise = 0, side = 0, coins = 0, size = { 5, 1, 12 }, swing = 60, period = 3, length = 10, phase = 0 },
			{ kind = "moving", gap = 7, rise = 2, side = -2, coins = 0, size = { 6, 1, 6 }, move = { 0, 0, 5 }, period = 3, phase = 0 },
			{ kind = "turntable", gap = 7, rise = 2, side = 2, coins = 0, size = { 10, 1, 10 }, speed = 60 },
			{ kind = "platform", gap = 7, rise = 1, side = 0, coins = 0, size = { 8, 4, 4 }, shape = "cylinder" },
			{ kind = "checkpoint", gap = 6, rise = -2, side = 0, coins = 0 },
		} },
		{ stage = 80, name = "Kraken's Crown", pieces = {
			{ kind = "spinner", gap = 4, rise = 0, side = 0, coins = 0, size = { 12, 1, 12 }, speed = 90, bar_height = 2 },
			{ kind = "pendulum", gap = 7, rise = 1, side = 1, coins = 0, size = { 4, 1, 10 }, swing = 70, period = 2.5, length = 10, phase = 0 },
			{ kind = "moving", gap = 7, rise = 2, side = -1, coins = 0, size = { 5, 1, 5 }, move = { 0, 0, 5 }, period = 3, phase = 0 },
			{ kind = "disappearing", gap = 7, rise = 1, side = 1, coins = 0, size = { 4, 1, 4 }, count = 2, spacing = 3, on = 2.2, off = 1.5, stagger = 0.6 },
			{ kind = "checkpoint", gap = 5, rise = 1, side = 0, coins = 0 },
		} },
	},
}
