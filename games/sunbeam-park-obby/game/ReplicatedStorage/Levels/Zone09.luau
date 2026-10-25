-- Zone 9: Thunder Rail Coaster (stages 81-90). Level data written by `forge levels` (Mubit level_designer), built by ObbyKit. Data, not code.
return {
	zone = 9,
	name = "Thunder Rail Coaster",
	theme = "A red-railed roller coaster with lift hills, launch pads and swinging loops high above Sunbeam Park",
	theme_id = "coaster",
	palette = { "#E63946", "#FFD23F", "#1D3557" },
	material = "Metal",
	stages = {
		{ stage = 81, name = "Lift Hill Launch", pieces = {
			{ kind = "platform", gap = 4, rise = 3, side = 0, coins = 0, size = { 8, 3, 10 }, shape = "wedge-ramp" },
			{ kind = "moving", gap = 6, rise = 0, side = 0, coins = 0, size = { 7, 1, 7 }, move = { 0, 0, 10 }, period = 5, phase = 0 },
			{ kind = "jumppad", gap = 12, rise = 0, side = 0, coins = 0, size = { 6, 1, 6 }, power = 90, forward = 20 },
			{ kind = "platform", gap = 8, rise = 10, side = 0, coins = 2, size = { 10, 1, 10 }, shape = "round" },
			{ kind = "checkpoint", gap = 4, rise = -10, side = 0, coins = 0 },
		} },
		{ stage = 82, name = "Rail Rider", pieces = {
			{ kind = "conveyor", gap = 4, rise = 0, side = 0, coins = 0, size = { 8, 1, 12 }, speed = 6, dir = "forward" },
			{ kind = "moving", gap = 6, rise = 0, side = 0, coins = 0, size = { 9, 1, 8 }, move = { 4, 0, 0 }, period = 6, phase = 0 },
			{ kind = "pendulum", gap = 6, rise = 1, side = 0, coins = 0, size = { 6, 1, 12 }, swing = 50, period = 4, length = 11, phase = 0 },
			{ kind = "platform", gap = 6, rise = 1, side = 0, coins = 2, size = { 10, 1, 10 }, shape = "round" },
			{ kind = "checkpoint", gap = 5, rise = -1, side = 0, coins = 0 },
		} },
		{ stage = 83, name = "Loop-de-Loop", pieces = {
			{ kind = "turntable", gap = 4, rise = 0, side = 0, coins = 0, size = { 12, 1, 12 }, speed = 40 },
			{ kind = "jumppad", gap = 6, rise = 0, side = 2, coins = 0, size = { 6, 1, 6 }, power = 90, forward = 20 },
			{ kind = "platform", gap = 8, rise = 8, side = 0, coins = 2, size = { 8, 1, 8 }, shape = "round" },
			{ kind = "disappearing", gap = 6, rise = -8, side = 0, coins = 0, size = { 6, 1, 5 }, count = 2, spacing = 3, on = 3, off = 1.5, stagger = 0.6 },
			{ kind = "checkpoint", gap = 4, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 84, name = "Launch Corner", turn = -90, pieces = {
			{ kind = "jumppad", gap = 4, rise = 0, side = 0, coins = 0, size = { 6, 1, 6 }, power = 90, forward = 20 },
			{ kind = "checkpoint", gap = 6, rise = 16, side = 0, coins = 0 },
		} },
		{ stage = 85, name = "Station Break", turn = -90, pieces = {
			{ kind = "platform", gap = 4, rise = 0, side = 0, coins = 3, size = { 10, 1, 10 }, shape = "round" },
			{ kind = "moving", gap = 6, rise = 1, side = 0, coins = 0, size = { 8, 1, 8 }, move = { 0, 0, 8 }, period = 6, phase = 0 },
			{ kind = "conveyor", gap = 10, rise = 0, side = 0, coins = 0, size = { 8, 1, 12 }, speed = 6, dir = "forward" },
			{ kind = "checkpoint", gap = 5, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 86, name = "Corkscrew Climb", pieces = {
			{ kind = "spinner", gap = 4, rise = 0, side = 0, coins = 0, size = { 14, 1, 14 }, speed = 70, bar_height = 2 },
			{ kind = "jumppad", gap = 5, rise = 0, side = 0, coins = 0, size = { 6, 1, 6 }, power = 90, forward = 20 },
			{ kind = "platform", gap = 9, rise = 10, side = 0, coins = 0, size = { 8, 1, 8 }, shape = "round" },
			{ kind = "moving", gap = 6, rise = -10, side = 0, coins = 0, size = { 7, 1, 7 }, move = { 5, 0, 0 }, period = 5, phase = 0 },
			{ kind = "checkpoint", gap = 7, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 87, name = "Spring Corner", turn = -90, pieces = {
			{ kind = "trampoline", gap = 4, rise = 0, side = 0, coins = 0, size = { 8, 1, 8 }, bounce = 80 },
			{ kind = "checkpoint", gap = 4, rise = 16, side = 0, coins = 0 },
		} },
		{ stage = 88, name = "Rising Rails", turn = -90, pieces = {
			{ kind = "platform", gap = 4, rise = 0, side = 0, coins = 0, size = { 8, 1, 8 }, shape = "round" },
			{ kind = "moving", gap = 6, rise = 0, side = 0, coins = 0, size = { 7, 1, 7 }, move = { 0, 3, 6 }, period = 4, phase = 0 },
			{ kind = "pendulum", gap = 8, rise = 3, side = 0, coins = 0, size = { 6, 1, 14 }, swing = 55, period = 3, length = 10, phase = 0 },
			{ kind = "checkpoint", gap = 8, rise = -3, side = 0, coins = 0 },
		} },
		{ stage = 89, name = "Tilt-a-Track", pieces = {
			{ kind = "disappearing", gap = 4, rise = 0, side = 0, coins = 0, size = { 5, 1, 5 }, count = 3, spacing = 2, on = 2.2, off = 1.5, stagger = 0.6 },
			{ kind = "platform", gap = 6, rise = 2, side = 0, coins = 0, size = { 8, 2, 8 }, shape = "wedge-ramp" },
			{ kind = "spinner", gap = 8, rise = -2, side = 0, coins = 0, size = { 12, 1, 12 }, speed = 100, bar_height = 2 },
			{ kind = "checkpoint", gap = 8, rise = 0, side = 0, coins = 0 },
		} },
		{ stage = 90, name = "Thunder Summit", pieces = {
			{ kind = "turntable", gap = 4, rise = 0, side = 0, coins = 0, size = { 10, 1, 10 }, speed = 60 },
			{ kind = "jumppad", gap = 6, rise = 0, side = 0, coins = 0, size = { 5, 1, 5 }, power = 90, forward = 20 },
			{ kind = "platform", gap = 9, rise = 10, side = 0, coins = 0, size = { 6, 1, 6 }, shape = "round" },
			{ kind = "pendulum", gap = 7, rise = -6, side = 0, coins = 0, size = { 5, 1, 12 }, swing = 60, period = 2.6, length = 10, phase = 0.5 },
			{ kind = "checkpoint", gap = 9, rise = -4, side = 0, coins = 0 },
		} },
	},
}
