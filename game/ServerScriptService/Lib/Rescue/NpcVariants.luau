-- NpcVariants: the trailer cast beyond the original five (docs/game/05 §4 + shot list), in the
-- same chunky googly-eyed style as NpcBuilder's firefighter and panda. Loaded by NpcBuilder:
--   NpcVariants.install(kit) -> { [kind]: Def }   (kit = NpcBuilder._kit; Def as in NpcBuilder)
-- People share one parametric body (`person`) so every pose works for all of them:
--   Farmer (straw hat, overalls, lit cigarette), Grandma, Kid, FloatGuy (pink donut float),
--   RainbowGuy (paint-splattered), Teacher, Hiker.
-- Animals: Duck, Duckling, Chicken, Deer, Raccoon.
-- Local coordinates are unscaled studs, ground at y = 0, facing -Z; NpcBuilder applies scale/pose.
local NpcVariants = {}

function NpcVariants.install(K)
	local C = K.C
	local hex = K.hex
	local box, ball, blob, ecyl, cyl, zcyl = K.box, K.ball, K.blob, K.ecyl, K.cyl, K.zcyl
	local triangle, eye, mouth, armAngles, poseFx, ellR = K.triangle, K.eye, K.mouth, K.armAngles, K.poseFx, K.ellR

	local P = {
		Denim = hex("#4E6C9C"),
		DenimDark = hex("#3C5680"),
		Straw = hex("#E3C26A"),
		StrawDark = hex("#C9A24A"),
		BootBrown = hex("#5A3A24"),
		Brass = hex("#C89A3C"),
		GreyHair = hex("#C9C6CF"),
		Silver = hex("#B9B4AE"),
		Cardigan = hex("#9B6BB0"),
		Dress = hex("#F2B5C8"),
		DressHem = hex("#E58FAE"),
		Stocking = hex("#D9B48F"),
		Slipper = hex("#F2A0B8"),
		Frame = hex("#6B3A6E"),
		Handbag = hex("#CD5528"),
		CaneWood = hex("#7A4A2A"),
		KidSkin = hex("#F2B88E"),
		Teal = hex("#2A9D8F"),
		Terracotta = hex("#E76F51"),
		Sunny = hex("#F6D743"),
		Blue = hex("#3A7BD5"),
		Freckle = hex("#B4561E"),
		Trunks = hex("#CF442B"),
		Sunburn = hex("#F07A6A"),
		Dough = hex("#E8B26A"),
		Frosting = hex("#F48FB1"),
		Shades = hex("#1E3A5F"),
		ChestHair = hex("#6B4A32"),
		TeachSkin = hex("#C68B59"),
		ShirtBlue = hex("#A8C8E8"),
		Vest = hex("#E9C46A"),
		Tie = hex("#9A2A2A"),
		Slacks = hex("#6B4A32"),
		Pencil = hex("#F2C14E"),
		Jacket = hex("#3F7A4A"),
		JacketDark = hex("#2F5E39"),
		Khaki = hex("#C2A878"),
		SockRed = hex("#CF442B"),
		HikeBoot = hex("#6B4428"),
		Beard = hex("#9A5A2E"),
		Olive = hex("#6F7A3A"),
		Pack = hex("#E8873A"),
		PackDark = hex("#B4561E"),
		Stick = hex("#8A5A32"),
		Moustache = hex("#8A6A4A"),
		Nose = hex("#E89A80"),
	}
	local Rainbow = { hex("#E63946"), hex("#F4A261"), hex("#F6D743"), hex("#6CC24A"), hex("#3A86FF"), hex("#8E5BD0") }

	------------------------------------------------------------------------ person
	-- Parametric chunky person. spec fields (unscaled studs):
	--   skin, shirt, pants, shoe, legH (ground->hip), legW, hipX, torso (Vector3), belly?, bellyColor?,
	--   headD, eyeD, armL, armW, sleeveL (0 = bare arms; >= armL = long sleeves), shorts?, socks?,
	--   feet ("shoe" | "boot" | "flipflop" | "slipper"), stoop (deg)?, stand ({L, R} deg)?,
	--   lookL/lookR (Vector2), mouth ("o" | "smile" | "grin"), nose (Color3?), stripes ({Color3}?),
	--   legColors ({Color3, Color3}?), sleeveColors ({Color3, Color3}?).
	-- Returns the anchors decorations hang off: U(x, y, z) maps standing-local coords onto the
	-- (possibly sitting/stooped) upper body; hy/hd = head centre height/diameter; hands = {L, R}.
	local function person(ctx, sp)
		local pose = ctx.pose
		local sitting = pose == "sitting"
		local hipY = sp.legH
		local shoeH = if sp.feet == "boot" then 0.65 elseif sp.feet == "flipflop" then 0.22 else 0.45
		local legW = sp.legW
		local up = if sitting then legW - hipY else 0
		local tw, th, td = sp.torso.X, sp.torso.Y, sp.torso.Z
		local stoop = math.rad(sp.stoop or 0)
		local hipCf = CFrame.new(0, hipY + up, 0) * CFrame.Angles(-stoop, 0, 0)
		local function U(x, y, z)
			return hipCf * CFrame.new(x, y - hipY, z)
		end

		-- Legs: built down the local -Y of legBase (standing) or forward along -Z (sitting).
		local L = hipY - shoeH
		for i, side in { -1, 1 } do
			local x = side * sp.hipX
			local legBase
			if sitting then
				legBase = CFrame.new(x, legW / 2 + 0.06, 0.1) * CFrame.Angles(math.rad(90), 0, 0)
			else
				local spread = if ctx.ko then side * 12 elseif pose == "panicking" then side * 8 else 0
				legBase = CFrame.new(x, hipY, 0) * CFrame.Angles(0, 0, math.rad(spread))
			end
			local pantsCol = if sp.legColors then sp.legColors[i] else sp.pants
			if sp.shorts then
				local pl = L * 0.42
				box(ctx, `Short{i}`, legBase * CFrame.new(0, -pl / 2, 0), Vector3.new(legW + 0.1, pl, legW + 0.1), pantsCol)
				box(ctx, `Leg{i}`, legBase * CFrame.new(0, -(pl + (L - pl) / 2), 0), Vector3.new(legW * 0.82, L - pl + 0.05, legW * 0.82), sp.skin)
				if sp.socks then
					box(ctx, `Sock{i}`, legBase * CFrame.new(0, -(L - 0.22), 0), Vector3.new(legW * 0.9, 0.45, legW * 0.9), sp.socks)
				end
			else
				box(ctx, `Leg{i}`, legBase * CFrame.new(0, -L / 2, 0), Vector3.new(legW, L + 0.05, legW), pantsCol)
			end
			local foot = legBase * CFrame.new(0, -(L + shoeH / 2), -0.12)
			if sp.feet == "flipflop" then
				blob(ctx, `Foot{i}`, foot * CFrame.new(0, 0.12, -0.05), Vector3.new(legW * 0.85, 0.4, legW + 0.25), sp.skin)
				box(ctx, `Sole{i}`, foot * CFrame.new(0, -0.03, 0), Vector3.new(legW + 0.1, 0.16, legW + 0.5), sp.shoe)
				box(ctx, `Strap{i}`, foot * CFrame.new(0, 0.2, -0.15), Vector3.new(legW * 0.9, 0.08, 0.12), sp.shoe:Lerp(C.EyeWhite, 0.3))
			elseif sp.feet == "slipper" then
				blob(ctx, `Shoe{i}`, foot * CFrame.new(0, 0.02, -0.05), Vector3.new(legW + 0.2, shoeH + 0.15, legW + 0.55), sp.shoe)
				ball(ctx, `Pom{i}`, foot * CFrame.new(0, shoeH * 0.45, -(legW + 0.35) / 2), 0.32, C.EyeWhite)
			else
				box(ctx, `Shoe{i}`, foot, Vector3.new(legW + 0.08, shoeH, legW + 0.4), sp.shoe)
				blob(ctx, `Toe{i}`, foot * CFrame.new(0, -0.02, -(legW + 0.3) / 2), Vector3.new(legW + 0.08, shoeH * 1.05, 0.6), sp.shoe)
				if sp.feet == "boot" then
					box(ctx, `BootCuff{i}`, foot * CFrame.new(0, shoeH / 2, 0.06), Vector3.new(legW + 0.14, 0.14, legW + 0.2), sp.shoe:Lerp(C.NumberInk, 0.35))
				end
			end
		end

		-- Torso (box, or stacked colour stripes) + soft belly + belt line
		if sp.stripes then
			local n = #sp.stripes
			for i, col in sp.stripes do
				local sh = th / n
				box(ctx, `Torso{i}`, U(0, hipY + th - sh * (i - 0.5), 0), Vector3.new(tw, sh + 0.01, td), col)
			end
		else
			box(ctx, "Torso", U(0, hipY + th / 2, 0), Vector3.new(tw, th, td), sp.shirt)
		end
		if sp.belly then
			blob(ctx, "Belly", U(0, hipY + th * 0.4, -td / 2 + 0.15), Vector3.new(tw * 0.83, th * 0.74, sp.belly), sp.bellyColor or sp.shirt)
		end
		if not sp.noBelt then
			box(ctx, "Belt", U(0, hipY + 0.06, 0), Vector3.new(tw + 0.02, 0.18, td + 0.02), sp.pants:Lerp(C.NumberInk, 0.35))
		end

		-- Arms
		local stand = sp.stand or { 14, 12 }
		local angL, angR = armAngles(pose, stand[1], stand[2])
		local aw, armL = sp.armW, sp.armL
		local sleeveL = math.min(sp.sleeveL, armL)
		local hands = {}
		for i, side in { -1, 1 } do
			local ang = if side == 1 then angR else angL
			local pivot = U(side * tw / 2, hipY + th - 0.15, 0) * CFrame.Angles(0, 0, math.rad(side * ang))
			local ox = side * aw * 0.5
			local sleeveCol = if sp.sleeveColors then sp.sleeveColors[i] else sp.shirt
			if sleeveL > 0 then
				box(ctx, `Sleeve{i}`, pivot * CFrame.new(ox, -sleeveL / 2, 0), Vector3.new(aw + 0.14, sleeveL, aw + 0.14), sleeveCol)
			end
			if armL - sleeveL > 0.05 then
				box(ctx, `Arm{i}`, pivot * CFrame.new(ox, -(sleeveL + (armL - sleeveL) / 2), 0), Vector3.new(aw, armL - sleeveL + 0.04, aw), sp.skin)
			end
			local hand = pivot * CFrame.new(ox, -armL - 0.08, 0)
			ball(ctx, `Hand{i}`, hand, aw + 0.12, sp.skin)
			hands[i] = hand
		end

		-- Head: ears, blush, googly eyes, nose, mouth
		local hd = sp.headD
		local hy = hipY + th + hd * 0.45
		local hr = hd / 2
		blob(ctx, "Head", U(0, hy, 0), Vector3.new(hd, hd, hd * 0.95), sp.skin)
		for i, side in { -1, 1 } do
			blob(ctx, `Ear{i}`, U(side * hr, hy - 0.05, 0.1), Vector3.new(0.3, hd * 0.28, 0.4), sp.skin)
			blob(ctx, `Blush{i}`, U(side * hd * 0.31, hy - hd * 0.21, -hd * 0.37) * CFrame.Angles(0, math.rad(side * 30), 0), Vector3.new(0.38, 0.2, 0.08), C.Blush)
		end
		local eyeY, eyeZ = hy + hd * 0.075, -hd * 0.46
		local eyeX = sp.eyeD * 0.5
		eye(ctx, "EyeL", U(-eyeX, eyeY, eyeZ), sp.eyeD, sp.lookL or Vector2.new(-0.5, 0.3))
		eye(ctx, "EyeR", U(eyeX, eyeY, eyeZ), sp.eyeD, sp.lookR or Vector2.new(0.5, -0.3))
		if sp.nose then
			blob(ctx, "Nose", U(0, hy - hd * 0.1, -hd * 0.49), Vector3.new(0.38, 0.34, 0.34), sp.nose)
		end
		local mouthCf = U(0, hy - hd * 0.275, -ellR(hd * 0.475, hy, hr, hy - hd * 0.275) - 0.02)
		mouth(ctx, "Mouth", mouthCf, 0.14 * hd, sp.mouth)
		poseFx(ctx, U(0, hy + hr, 0).Position, hands)

		return {
			U = U,
			hipY = hipY,
			top = hipY + th,
			hy = hy,
			hd = hd,
			hr = hr,
			tw = tw,
			th = th,
			td = td,
			hands = hands,
			up = up,
			sitting = sitting,
			eyeY = eyeY,
			eyeZ = eyeZ,
			eyeX = eyeX,
			mouthCf = mouthCf,
			L = L,
			shoeH = shoeH,
		}
	end

	local function personDims(p, extraTop, back)
		return {
			w = p.tw + 1.2,
			h = p.hy + p.hr + extraTop + p.up,
			d = if p.sitting then p.L + 1.4 else p.td + back,
			back = p.td / 2 + back,
			head = Vector3.new(0, p.hy + p.hr + extraTop + 0.2 + p.up, 0),
		}
	end

	-- Round glasses: rim discs behind each googly eye + bridge + temples.
	local function glasses(ctx, p, color, rimScale)
		local U = p.U
		local d = p.eyeX * 2 * rimScale
		for i, side in { -1, 1 } do
			zcyl(ctx, `Rim{i}`, U(side * p.eyeX, p.eyeY, p.eyeZ + 0.02), 0.08, d, color)
			box(ctx, `Temple{i}`, U(side * (p.eyeX + d * 0.48), p.eyeY + 0.05, p.eyeZ + 0.5), Vector3.new(0.08, 0.08, 1.0), color)
		end
		box(ctx, "Bridge", U(0, p.eyeY + 0.08, p.eyeZ - p.eyeX * 0.55), Vector3.new(0.3, 0.08, 0.08), color)
	end

	-- Flat paint/soot splat on a surface: lcf faces outward along its -Z.
	local function splat(ctx, name, lcf, d, color)
		blob(ctx, name, lcf, Vector3.new(d, d * 0.8, 0.08), color)
		ball(ctx, name .. "A", lcf * CFrame.new(d * 0.6, d * 0.25, 0), d * 0.22, color)
		ball(ctx, name .. "B", lcf * CFrame.new(-d * 0.45, -d * 0.5, 0), d * 0.16, color)
	end

	-- Point on the head surface along `dir` (standing-local), oriented to face outward.
	local function onHead(p, dir)
		local u = dir.Unit
		local c = p.U(0, p.hy, 0)
		local pos = (c * CFrame.new(u * p.hr * 0.97)).Position
		local out = (c * CFrame.new(u * (p.hr + 1))).Position
		return CFrame.lookAt(pos, out)
	end

	------------------------------------------------------------------------ Farmer
	local FarmerSpec = {
		skin = C.SkinPale,
		shirt = C.CivTeeWhite,
		pants = P.Denim,
		shoe = P.BootBrown,
		feet = "boot",
		legH = 2.0,
		legW = 0.9,
		hipX = 0.52,
		torso = Vector3.new(2.5, 2.0, 1.35),
		belly = 0.95,
		bellyColor = P.Denim,
		headD = 2.05,
		eyeD = 0.86,
		armL = 1.9,
		armW = 0.66,
		sleeveL = 0.75,
		stand = { 16, 16 },
		lookL = Vector2.new(-0.7, 0.5),
		lookR = Vector2.new(0.6, -0.6),
		mouth = "smile",
		nose = P.Nose,
	}
	local function buildFarmer(ctx, _opts)
		local p = person(ctx, FarmerSpec)
		local U, hipY, top, td, hy, hd = p.U, p.hipY, p.top, p.td, p.hy, p.hd
		-- Overalls: waist, bib with pocket + brass buttons, straps over the shoulders
		box(ctx, "OverallsWaist", U(0, hipY + 0.32, 0), Vector3.new(p.tw + 0.05, 0.7, td + 0.05), P.Denim)
		box(ctx, "Bib", U(0, hipY + 1.42, -0.76), Vector3.new(1.3, 0.95, 0.32), P.Denim)
		box(ctx, "BibPocket", U(0, hipY + 1.32, -0.935), Vector3.new(0.6, 0.42, 0.04), P.DenimDark)
		for i, side in { -1, 1 } do
			ball(ctx, `Button{i}`, U(side * 0.5, hipY + 1.78, -0.93), 0.2, P.Brass)
			box(ctx, `StrapTop{i}`, U(side * 0.52, top + 0.04, -0.1), Vector3.new(0.3, 0.12, td + 0.05), P.Denim)
			box(ctx, `StrapBack{i}`, U(side * 0.52, hipY + 1.2, td / 2 + 0.03), Vector3.new(0.3, 1.6, 0.08), P.Denim)
			box(ctx, `Stitch{i}`, U(side * 0.62, hipY + 0.95, -0.95), Vector3.new(0.06, 0.06, 0.04), P.Straw)
		end
		-- Hay poking out of the bib pocket
		for i, a in { -18, 4, 22 } do
			box(ctx, `PocketHay{i}`, U(-0.1 + i * 0.1, hipY + 1.62, -0.95) * CFrame.Angles(0, 0, math.rad(a)), Vector3.new(0.05, 0.45, 0.05), P.Straw)
		end
		-- Red neckerchief
		blob(ctx, "Kerchief", U(0, top + 0.02, -0.38), Vector3.new(1.45, 0.38, 0.7), C.CivShirtRed)
		blob(ctx, "KerchiefTip", U(0, top - 0.22, -0.7) * CFrame.Angles(math.rad(-10), 0, 0), Vector3.new(0.55, 0.5, 0.14), C.CivShirtRed)
		-- Bushy eyebrows + walrus moustache
		for i, side in { -1, 1 } do
			blob(ctx, `Brow{i}`, U(side * 0.45, hy + hd * 0.29, -hd * 0.42) * CFrame.Angles(0, 0, math.rad(side * -12)), Vector3.new(0.6, 0.2, 0.18), P.Moustache)
			blob(ctx, `Moustache{i}`, U(side * 0.27, hy - hd * 0.19, -hd * 0.475) * CFrame.Angles(0, 0, math.rad(side * -18)), Vector3.new(0.62, 0.26, 0.24), P.Moustache)
		end
		-- Straw hat, tipped back and to one side
		-- (knocked off and lying on the ground beside him when KO)
		local hat = if ctx.ko
			then CFrame.new(2.6, hy + 0.4, ctx.lieBack - 0.08) * CFrame.Angles(-math.pi / 2, 0.5, 0)
			else U(0, hy + hd * 0.3, 0.06) * CFrame.Angles(math.rad(9), 0, math.rad(-6))
		ecyl(ctx, "HatBrim", hat, 0.14, 3.7, 3.5, P.Straw)
		ecyl(ctx, "HatWeave", hat * CFrame.new(0, 0.02, 0), 0.14, 2.9, 2.75, P.StrawDark)
		ecyl(ctx, "HatCrown", hat * CFrame.new(0, 0.45, 0), 0.82, 1.9, 1.8, P.Straw)
		blob(ctx, "HatTop", hat * CFrame.new(0, 0.86, 0), Vector3.new(1.9, 0.32, 1.8), P.Straw)
		ecyl(ctx, "HatBand", hat * CFrame.new(0, 0.2, 0), 0.24, 1.96, 1.86, C.CivShirtRed)
		for i = 1, 8 do
			local a = (i - 0.5) * math.pi * 2 / 8
			box(ctx, `BrimFray{i}`, hat * CFrame.Angles(0, a, 0) * CFrame.new(0, -0.02, -1.78) * CFrame.Angles(0, math.rad(15 * ((i % 3) - 1)), 0), Vector3.new(0.08, 0.06, 0.4), P.StrawDark)
		end
		for i, a in { -25, 18 } do
			box(ctx, `HatStraw{i}`, hat * CFrame.new(0.2 * i - 0.3, 1.0, 0.1) * CFrame.Angles(0, 0, math.rad(a)), Vector3.new(0.05, 0.5, 0.05), P.StrawDark)
		end
		-- Cigarette in the corner of the mouth, tip glowing, smoke curling up
		local cig = p.mouthCf * CFrame.new(0.22, 0.02, 0) * CFrame.Angles(0, math.rad(-35), math.rad(-8))
		box(ctx, "CigFilter", cig * CFrame.new(0, 0, -0.06), Vector3.new(0.14, 0.14, 0.18), hex("#D9A060"))
		box(ctx, "Cigarette", cig * CFrame.new(0, 0, -0.38), Vector3.new(0.13, 0.13, 0.5), C.CivTeeWhite)
		local tip = box(ctx, "CigTip", cig * CFrame.new(0, 0, -0.67), Vector3.new(0.14, 0.14, 0.1), C.Ember, { neon = true })
		box(ctx, "CigAsh", cig * CFrame.new(0, 0, -0.73), Vector3.new(0.12, 0.12, 0.05), C.SmokeGrey)
		local light = Instance.new("PointLight")
		light.Color = C.Ember
		light.Brightness = 1.5
		light.Range = 4 * ctx.s
		light.Parent = tip
		local smoke = Instance.new("ParticleEmitter")
		smoke.Name = "CigSmoke"
		smoke.Rate = 3
		smoke.Lifetime = NumberRange.new(1.2, 2)
		smoke.Speed = NumberRange.new(0.8, 1.4)
		smoke.SpreadAngle = Vector2.new(12, 12)
		smoke.EmissionDirection = Enum.NormalId.Top
		smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.12 * ctx.s), NumberSequenceKeypoint.new(1, 0.7 * ctx.s) })
		smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
		smoke.Color = ColorSequence.new(C.SmokeWhite)
		smoke.Parent = tip
		return personDims(p, 0.6, 0.1)
	end

	------------------------------------------------------------------------ Grandma
	local GrandmaSpec = {
		skin = C.SkinPale,
		shirt = P.Cardigan,
		pants = P.Stocking,
		shoe = P.Slipper,
		feet = "slipper",
		legH = 1.7,
		legW = 0.72,
		hipX = 0.42,
		torso = Vector3.new(2.3, 1.75, 1.4),
		belly = 0.9,
		bellyColor = P.Dress,
		headD = 1.95,
		eyeD = 0.9,
		armL = 1.7,
		armW = 0.6,
		sleeveL = 1.7,
		stoop = 12,
		stand = { 12, 24 },
		lookL = Vector2.new(0.4, 0.2),
		lookR = Vector2.new(-0.4, 0.2),
		mouth = "smile",
		noBelt = true,
	}
	local function buildGrandma(ctx, _opts)
		local p = person(ctx, GrandmaSpec)
		local U, hipY, top, td, tw, hy, hd = p.U, p.hipY, p.top, p.td, p.tw, p.hy, p.hd
		-- Flared floral skirt (drapes over the lap when sitting)
		if p.sitting then
			blob(ctx, "Skirt", U(0, hipY - 0.12, -0.75), Vector3.new(tw + 0.3, 0.95, 2.3), P.Dress)
		else
			local rx, rz = (tw + 0.55) / 2, (td + 0.6) / 2
			ecyl(ctx, "Skirt", U(0, hipY - 0.45, 0), 1.1, rx * 2, rz * 2, P.Dress)
			ecyl(ctx, "SkirtHem", U(0, hipY - 0.98, 0), 0.14, rx * 2 + 0.07, rz * 2 + 0.07, P.DressHem)
			for i, a in { -55, -18, 22, 60, -38, 40 } do
				local y = hipY - (if i <= 4 then 0.3 else 0.7)
				local r = math.rad(a)
				ball(ctx, `Flower{i}`, U(math.sin(r) * rx, y, -math.cos(r) * rz), 0.2, if i % 2 == 0 then C.EyeWhite else P.Sunny)
			end
		end
		-- Cardigan buttons + pearl necklace
		for i = 1, 3 do
			ball(ctx, `Button{i}`, U(-0.55, top - 0.35 - i * 0.38, -td / 2 - 0.02), 0.16, P.Brass)
		end
		for i = 1, 9 do
			local a = math.rad(-64 + (i - 1) * 16)
			ball(ctx, `Pearl{i}`, U(math.sin(a) * 0.72, top - 0.12 - 0.28 * math.cos(a), -td / 2 - 0.04 + (1 - math.cos(a)) * 0.25), 0.18, C.EyeWhite)
		end
		-- Silver hair cap, bun with a pin, side curls
		blob(ctx, "Hair", U(0, hy + hd * 0.22, 0.2), Vector3.new(hd * 1.05, hd * 0.66, hd * 0.98), P.GreyHair)
		ball(ctx, "Bun", U(0, hy + hd * 0.55, 0.38), 0.95, P.GreyHair)
		cyl(ctx, "HairPin", U(0, hy + hd * 0.6, 0.38) * CFrame.Angles(0, 0, math.rad(70)), 1.2, 0.08, P.Brass)
		for i, side in { -1, 1 } do
			ball(ctx, `Curl{i}a`, U(side * hd * 0.47, hy + 0.05, 0.12), 0.48, P.GreyHair)
			ball(ctx, `Curl{i}b`, U(side * hd * 0.43, hy + 0.42, 0.02), 0.5, P.GreyHair)
		end
		glasses(ctx, p, P.Frame, 1.22)
		-- Handbag on the left hand
		local hl = p.hands[1]
		box(ctx, "Handbag", CFrame.new(hl.Position + Vector3.new(-0.1, -0.55, 0)), Vector3.new(0.85, 0.62, 0.38), P.Handbag)
		box(ctx, "BagFlap", CFrame.new(hl.Position + Vector3.new(-0.1, -0.33, -0.05)), Vector3.new(0.88, 0.22, 0.4), P.Handbag:Lerp(C.NumberInk, 0.25))
		ball(ctx, "BagClasp", CFrame.new(hl.Position + Vector3.new(-0.1, -0.42, -0.25)), 0.14, P.Brass)
		box(ctx, "BagHandle", CFrame.new(hl.Position + Vector3.new(-0.1, -0.08, 0)), Vector3.new(0.6, 0.08, 0.08), P.Handbag:Lerp(C.NumberInk, 0.25))
		-- Walking cane in the right hand (standing only)
		if ctx.pose == "stand" then
			local hr = p.hands[2].Position
			cyl(ctx, "Cane", CFrame.new(hr.X, hr.Y / 2, hr.Z), hr.Y + 0.1, 0.18, P.CaneWood)
			cyl(ctx, "CaneCrook", CFrame.new(hr.X - 0.18, hr.Y + 0.12, hr.Z) * CFrame.Angles(0, 0, math.rad(90)), 0.45, 0.18, P.CaneWood)
			ball(ctx, "CaneTip", CFrame.new(hr.X, 0.06, hr.Z), 0.22, C.Boot)
		end
		return personDims(p, 0.55, 0.15)
	end

	------------------------------------------------------------------------ Kid
	local KidSpec = {
		skin = P.KidSkin,
		shirt = P.Teal,
		pants = P.Terracotta,
		shorts = true,
		socks = C.EyeWhite,
		shoe = C.TruckRed,
		feet = "shoe",
		legH = 1.5,
		legW = 0.72,
		hipX = 0.4,
		torso = Vector3.new(1.9, 1.45, 1.1),
		headD = 2.35,
		eyeD = 1.0,
		armL = 1.45,
		armW = 0.55,
		sleeveL = 0.65,
		stand = { 18, 14 },
		lookL = Vector2.new(-0.2, 0.6),
		lookR = Vector2.new(0.5, 0.2),
		mouth = "grin",
	}
	local function buildKid(ctx, _opts)
		local p = person(ctx, KidSpec)
		local U, hipY, td, tw, hy, hd = p.U, p.hipY, p.td, p.tw, p.hy, p.hd
		box(ctx, "ShirtStripe", U(0, hipY + p.th * 0.55, 0), Vector3.new(tw + 0.04, 0.3, td + 0.04), P.Sunny)
		-- Propeller beanie with a visor
		local cap = U(0, hy + hd * 0.3, 0.05)
		blob(ctx, "Beanie", cap, Vector3.new(hd * 0.94, hd * 0.56, hd * 0.92), C.TruckRed)
		ecyl(ctx, "BeanieBand", cap * CFrame.new(0, -hd * 0.06, 0), 0.2, hd * 0.95, hd * 0.93, P.Sunny)
		blob(ctx, "Visor", cap * CFrame.new(0, -hd * 0.08, -hd * 0.46) * CFrame.Angles(math.rad(-8), 0, 0), Vector3.new(1.3, 0.14, 0.9), P.Blue)
		cyl(ctx, "PropStem", cap * CFrame.new(0, hd * 0.3, 0), 0.35, 0.12, P.Sunny)
		ball(ctx, "PropHub", cap * CFrame.new(0, hd * 0.3 + 0.2, 0), 0.24, C.TruckRed)
		box(ctx, "PropBladeA", cap * CFrame.new(0, hd * 0.3 + 0.2, 0) * CFrame.Angles(0, math.rad(25), math.rad(8)), Vector3.new(1.5, 0.06, 0.3), P.Blue)
		box(ctx, "PropBladeB", cap * CFrame.new(0, hd * 0.3 + 0.2, 0) * CFrame.Angles(0, math.rad(25), math.rad(-8)) * CFrame.new(0, 0, 0), Vector3.new(0.3, 0.06, 1.5), P.Sunny)
		-- Freckles
		for i, side in { -1, 1 } do
			for j, o in { Vector2.new(0, 0), Vector2.new(0.16, 0.1), Vector2.new(-0.12, 0.12) } do
				ball(ctx, `Freckle{i}{j}`, U(side * (hd * 0.3 + o.X), hy - hd * 0.13 + o.Y, -hd * 0.43), 0.09, P.Freckle)
			end
		end
		-- Gap-toothed grin
		if not ctx.ko and ctx.pose ~= "panicking" then
			box(ctx, "ToothGap", p.mouthCf * CFrame.new(0.07, 0.14 * hd * 0.24, -0.06), Vector3.new(0.09, 0.1, 0.05), C.MouthIn)
		end
		-- School backpack
		local by = hipY + p.th * 0.55
		box(ctx, "Backpack", U(0, by, td / 2 + 0.35), Vector3.new(1.5, 1.35, 0.7), P.Sunny)
		blob(ctx, "PackFlap", U(0, by + 0.62, td / 2 + 0.38), Vector3.new(1.52, 0.45, 0.76), P.Terracotta)
		box(ctx, "PackPocket", U(0, by - 0.25, td / 2 + 0.74), Vector3.new(1.0, 0.55, 0.12), P.Terracotta)
		for i, side in { -1, 1 } do
			box(ctx, `PackStrap{i}`, U(side * 0.5, p.top + 0.03, 0), Vector3.new(0.24, 0.1, td + 0.1), P.Terracotta)
			box(ctx, `PackStrapF{i}`, U(side * 0.5, p.top - 0.5, -td / 2 - 0.03), Vector3.new(0.22, 0.95, 0.06), P.Terracotta)
		end
		-- Plaster on the knee
		if not p.sitting then
			box(ctx, "Plaster", CFrame.new(-0.4, p.shoeH + p.L * 0.42, -0.31) * CFrame.Angles(0, 0, math.rad(20)), Vector3.new(0.38, 0.15, 0.05), hex("#E8C9A0"))
		end
		return personDims(p, 0.95, 0.75)
	end

	------------------------------------------------------------------------ FloatGuy
	local FloatSpec = {
		skin = C.SkinPale,
		shirt = C.SkinPale,
		pants = P.Trunks,
		shorts = true,
		shoe = P.Blue,
		feet = "flipflop",
		legH = 1.95,
		legW = 0.88,
		hipX = 0.5,
		torso = Vector3.new(2.4, 1.9, 1.3),
		belly = 1.05,
		headD = 2.0,
		eyeD = 0.88,
		armL = 1.85,
		armW = 0.66,
		sleeveL = 0,
		stand = { 28, 28 },
		lookL = Vector2.new(0.4, 0.5),
		lookR = Vector2.new(-0.5, 0.3),
		mouth = "grin",
		nose = P.Sunburn,
		noBelt = true,
	}
	local Sprinkles = { C.EyeWhite, P.Sunny, P.Blue, hex("#6CC24A"), hex("#8E5BD0") }
	local function buildFloatGuy(ctx, _opts)
		local p = person(ctx, FloatSpec)
		local U, hipY, top, td, tw, hy, hd = p.U, p.hipY, p.top, p.td, p.tw, p.hy, p.hd
		-- Swim trunks waistband + drawstring, belly button, chest hair, sunburnt shoulders
		box(ctx, "Waistband", U(0, hipY + 0.1, 0), Vector3.new(tw + 0.04, 0.3, td + 0.04), P.Trunks)
		for i, side in { -1, 1 } do
			box(ctx, `Drawstring{i}`, U(side * 0.08, hipY - 0.05, -td / 2 - 0.04) * CFrame.Angles(0, 0, math.rad(side * 12)), Vector3.new(0.06, 0.4, 0.04), C.EyeWhite)
			blob(ctx, `Sunburn{i}`, U(side * (tw / 2 - 0.25), top + 0.01, 0), Vector3.new(0.75, 0.16, 1.0), P.Sunburn)
			if not p.sitting then
				box(ctx, `TrunkStripe{i}`, CFrame.new(side * 1.0, hipY - p.L * 0.21, 0), Vector3.new(0.05, p.L * 0.42, 0.35), C.EyeWhite)
			end
		end
		blob(ctx, "BellyButton", U(0, hipY + p.th * 0.32, -1.02), Vector3.new(0.16, 0.16, 0.06), P.Sunburn:Lerp(C.NumberInk, 0.3))
		for i, x in { -0.25, 0, 0.25 } do
			blob(ctx, `ChestHair{i}`, U(x, top - 0.42 - math.abs(x) * 0.3, -td / 2 - 0.03), Vector3.new(0.2, 0.26, 0.06), P.ChestHair)
		end
		-- Sunglasses pushed up on the forehead
		local sg = U(0, hy + hd * 0.32, -hd * 0.38) * CFrame.Angles(math.rad(28), 0, 0)
		for i, side in { -1, 1 } do
			box(ctx, `Lens{i}`, sg * CFrame.new(side * 0.36, 0, 0), Vector3.new(0.6, 0.34, 0.1), P.Shades)
			box(ctx, `LensShine{i}`, sg * CFrame.new(side * 0.36 - 0.12, 0.06, -0.06) * CFrame.Angles(0, 0, math.rad(35)), Vector3.new(0.08, 0.26, 0.03), C.EyeWhite)
		end
		box(ctx, "ShadesBridge", sg, Vector3.new(0.2, 0.08, 0.08), P.Shades)
		-- Pink-frosted donut float round the waist (12 dough segments + frosting + sprinkles)
		local R, tube = tw / 2 + 0.55, 1.0
		local ringY = hipY + 0.15
		-- KO: the float lies flat on the ground round his waist
		local ring = if ctx.ko then CFrame.new(0, ringY, ctx.lieBack - 0.5) * CFrame.Angles(-math.pi / 2, 0, 0) else U(0, ringY, 0)
		local segLen = 2 * math.pi * R / 12 * 1.45
		for i = 1, 12 do
			local a = (i - 1) * math.pi * 2 / 12
			local seg = ring * CFrame.Angles(0, a, 0) * CFrame.new(0, 0, -R)
			blob(ctx, `Dough{i}`, seg * CFrame.new(0, -0.08, 0), Vector3.new(segLen, tube * 0.85, tube), P.Dough)
			blob(ctx, `Frosting{i}`, seg * CFrame.new(0, 0.14, 0), Vector3.new(segLen * 1.02, tube * 0.7, tube * 1.06), P.Frosting)
			if i % 2 == 0 then
				blob(ctx, `Drip{i}`, seg * CFrame.new(0.15, -0.12, -tube * 0.47), Vector3.new(0.32, 0.5, 0.18), P.Frosting)
			end
			for j, o in { Vector3.new(-0.28, 0, 0.14), Vector3.new(0.3, 0, -0.18) } do
				box(ctx, `Sprinkle{i}{j}`, seg * CFrame.new(o.X, 0.14 + tube * 0.34, o.Z) * CFrame.Angles(0, math.rad(i * 37 + j * 70), 0), Vector3.new(0.28, 0.08, 0.08), Sprinkles[((i + j) % #Sprinkles) + 1])
			end
		end
		-- Rubber duck riding the float
		local duck = ring * CFrame.new(-0.95, 0.62, -R * 0.82) * CFrame.Angles(0, math.rad(20), 0)
		blob(ctx, "DuckyBody", duck, Vector3.new(0.5, 0.4, 0.62), P.Sunny)
		ball(ctx, "DuckyHead", duck * CFrame.new(0, 0.32, -0.16), 0.34, P.Sunny)
		blob(ctx, "DuckyBeak", duck * CFrame.new(0, 0.29, -0.36), Vector3.new(0.18, 0.08, 0.16), C.CatOrange)
		eye(ctx, "DuckyEyeL", duck * CFrame.new(-0.08, 0.38, -0.3), 0.13, Vector2.new(0.4, 0.3))
		eye(ctx, "DuckyEyeR", duck * CFrame.new(0.08, 0.38, -0.3), 0.13, Vector2.new(-0.4, 0.4))
		local dims = personDims(p, 0.1, 0.4)
		dims.w = (R + tube / 2) * 2
		dims.d = if p.sitting then dims.d else (R + tube / 2) * 2
		return dims
	end

	------------------------------------------------------------------------ RainbowGuy
	local RainbowSpec = {
		skin = C.SkinPale,
		shirt = C.CivTeeWhite,
		pants = C.Jeans,
		stripes = Rainbow,
		legColors = { Rainbow[5], Rainbow[6] },
		sleeveColors = { Rainbow[1], Rainbow[4] },
		shoe = C.Shoe,
		feet = "shoe",
		legH = 1.95,
		legW = 0.85,
		hipX = 0.5,
		torso = Vector3.new(2.3, 1.9, 1.2),
		headD = 2.0,
		eyeD = 0.88,
		armL = 1.8,
		armW = 0.62,
		sleeveL = 0.9,
		stand = { 30, 34 },
		lookL = Vector2.new(0.3, 0.5),
		lookR = Vector2.new(-0.4, 0.6),
		mouth = "grin",
	}
	local function buildRainbowGuy(ctx, _opts)
		local p = person(ctx, RainbowSpec)
		local U, hipY, td = p.U, p.hipY, p.td
		-- Paint splats on the head
		for i, dir in { Vector3.new(-0.6, 0.6, -0.5), Vector3.new(0.75, 0.15, -0.55), Vector3.new(0.05, 1, 0.15), Vector3.new(0.5, 0.65, 0.45), Vector3.new(-0.8, 0.1, 0.4) } do
			splat(ctx, `HeadSplat{i}`, onHead(p, dir), 0.6, Rainbow[((i * 2) % 6) + 1])
		end
		-- Drips running down from the crown
		for i, x in { -0.55, 0.15, 0.6 } do
			local c = Rainbow[((i + 2) % 6) + 1]
			local dir = Vector3.new(x, 0.55, -0.6)
			local cf = onHead(p, dir)
			blob(ctx, `HeadDrip{i}`, cf * CFrame.new(0, -0.25, 0), Vector3.new(0.18, 0.55, 0.08), c)
			ball(ctx, `HeadDripEnd{i}`, cf * CFrame.new(0, -0.52, 0), 0.2, c)
		end
		-- Splats on the shirt front and back, and on the jeans
		for i, s in { Vector3.new(-0.55, 1.45, -1), Vector3.new(0.6, 0.6, -1), Vector3.new(0.2, 1.1, 1), Vector3.new(-0.5, 0.4, 1) } do
			local face = if s.Z < 0 then U(s.X, hipY + s.Y, -td / 2 - 0.03) else U(s.X, hipY + s.Y, td / 2 + 0.03) * CFrame.Angles(0, math.pi, 0)
			splat(ctx, `ShirtSplat{i}`, face, 0.55, Rainbow[((i * 3) % 6) + 1])
		end
		if not p.sitting then
			for i, side in { -1, 1 } do
				splat(ctx, `LegSplat{i}`, CFrame.new(side * 0.5, 1.0 + i * 0.25, -0.46), 0.45, Rainbow[i + 1])
			end
		end
		-- Puddles of paint where he stands
		ecyl(ctx, "PuddleA", CFrame.new(-0.6, 0.03, -0.9), 0.05, 1.3, 0.9, Rainbow[3])
		ecyl(ctx, "PuddleB", CFrame.new(0.7, 0.04, -0.5), 0.05, 0.9, 0.7, Rainbow[5])
		-- Sparkles
		for i, o in { Vector3.new(-1.8, 4.6, -0.3), Vector3.new(1.9, 5.3, -0.2), Vector3.new(-1.5, 2.6, -0.6), Vector3.new(1.6, 2.2, -0.5) } do
			local cf = U(o.X, o.Y, o.Z)
			box(ctx, `Sparkle{i}`, cf * CFrame.Angles(0, 0, math.rad(45)), Vector3.new(0.3, 0.3, 0.08), if i % 2 == 0 then C.Star else C.EyeWhite, { neon = true })
			box(ctx, `SparkleV{i}`, cf, Vector3.new(0.08, 0.6, 0.08), if i % 2 == 0 then C.Star else C.EyeWhite, { neon = true })
		end
		return personDims(p, 0.2, 0.1)
	end

	------------------------------------------------------------------------ Teacher
	local TeacherSpec = {
		skin = P.TeachSkin,
		shirt = P.ShirtBlue,
		pants = P.Slacks,
		shoe = C.Boot,
		feet = "shoe",
		legH = 2.0,
		legW = 0.85,
		hipX = 0.5,
		torso = Vector3.new(2.3, 2.0, 1.25),
		belly = 0.5,
		bellyColor = P.Vest,
		headD = 2.0,
		eyeD = 0.8,
		armL = 1.95,
		armW = 0.62,
		sleeveL = 1.95,
		stand = { 20, 12 },
		lookL = Vector2.new(0.15, 0.35),
		lookR = Vector2.new(0.15, 0.35),
		mouth = "smile",
	}
	local function buildTeacher(ctx, _opts)
		local p = person(ctx, TeacherSpec)
		local U, hipY, top, td, tw, hy, hd = p.U, p.hipY, p.top, p.td, p.tw, p.hy, p.hd
		-- Sweater vest, shirt collar, tie
		box(ctx, "Vest", U(0, hipY + p.th * 0.39, 0), Vector3.new(tw + 0.06, p.th * 0.78, td + 0.06), P.Vest)
		box(ctx, "VestRib", U(0, hipY + 0.12, 0), Vector3.new(tw + 0.08, 0.2, td + 0.08), P.Vest:Lerp(C.NumberInk, 0.15))
		for i, side in { -1, 1 } do
			box(ctx, `Collar{i}`, U(side * 0.28, top - 0.06, -td / 2 - 0.05) * CFrame.Angles(0, 0, math.rad(side * -32)), Vector3.new(0.5, 0.2, 0.08), C.CivTeeWhite)
		end
		box(ctx, "TieKnot", U(0, top - 0.14, -td / 2 - 0.06), Vector3.new(0.3, 0.24, 0.1), P.Tie)
		box(ctx, "Tie", U(0, top - 0.6, -0.72), Vector3.new(0.3, 0.75, 0.1), P.Tie)
		box(ctx, "TieStripe", U(0, top - 0.55, -0.775), Vector3.new(0.3, 0.08, 0.02), P.Vest)
		-- Grey side hair (bald on top), moustache, round glasses, pencil behind the ear
		for i, side in { -1, 1 } do
			blob(ctx, `SideHair{i}`, U(side * hd * 0.47, hy + 0.08, 0.15), Vector3.new(0.5, 0.8, 1.15), P.Silver)
		end
		blob(ctx, "BackHair", U(0, hy - 0.02, hd * 0.42), Vector3.new(1.7, 0.75, 0.5), P.Silver)
		blob(ctx, "Moustache", U(0, hy - hd * 0.19, -hd * 0.47), Vector3.new(0.9, 0.26, 0.26), P.Silver)
		blob(ctx, "Shine", U(-0.3, hy + hd * 0.43, -0.3) * CFrame.Angles(math.rad(-20), 0, math.rad(15)), Vector3.new(0.45, 0.12, 0.28), C.EyeWhite, { transparency = 0.25 })
		glasses(ctx, p, C.NumberInk, 1.16)
		local pen = U(hd * 0.5 + 0.08, hy + 0.3, 0.05) * CFrame.Angles(math.rad(75), 0, math.rad(-10))
		cyl(ctx, "Pencil", pen, 1.0, 0.13, P.Pencil)
		cyl(ctx, "Eraser", pen * CFrame.new(0, 0.55, 0), 0.14, 0.14, C.CatPink)
		cyl(ctx, "PencilTip", pen * CFrame.new(0, -0.55, 0), 0.12, 0.08, C.NumberInk)
		-- Coffee mug in the left hand
		local h = p.hands[1].Position + Vector3.new(0, 0.18, -0.3)
		cyl(ctx, "Mug", CFrame.new(h), 0.6, 0.52, C.EyeWhite)
		ecyl(ctx, "Coffee", CFrame.new(h + Vector3.new(0, 0.29, 0)), 0.04, 0.42, 0.42, hex("#5A3A24"))
		box(ctx, "MugHandle", CFrame.new(h + Vector3.new(-0.32, 0, 0)), Vector3.new(0.12, 0.34, 0.12), C.EyeWhite)
		ball(ctx, "MugHeart", CFrame.new(h + Vector3.new(0, 0, -0.25)), 0.18, C.CivShirtRed)
		return personDims(p, 0.1, 0.1)
	end

	------------------------------------------------------------------------ Hiker
	local HikerSpec = {
		skin = C.SkinPale,
		shirt = P.Jacket,
		pants = P.Khaki,
		shorts = true,
		socks = P.SockRed,
		shoe = P.HikeBoot,
		feet = "boot",
		legH = 2.0,
		legW = 0.88,
		hipX = 0.5,
		torso = Vector3.new(2.4, 2.0, 1.35),
		belly = 0.6,
		headD = 2.0,
		eyeD = 0.85,
		armL = 1.9,
		armW = 0.66,
		sleeveL = 1.9,
		stand = { 14, 22 },
		lookL = Vector2.new(0.6, 0.4),
		lookR = Vector2.new(0.6, 0.4),
		mouth = "o",
	}
	local function buildHiker(ctx, _opts)
		local p = person(ctx, HikerSpec)
		local U, hipY, top, td, hy, hd = p.U, p.hipY, p.top, p.td, p.hy, p.hd
		-- Jacket details
		ecyl(ctx, "JacketCollar", U(0, top + 0.06, 0), 0.32, 1.6, 1.3, P.JacketDark)
		box(ctx, "Zip", U(0, top - 0.4, -td / 2 - 0.03), Vector3.new(0.09, 0.7, 0.04), C.ReflectSilver)
		for i, side in { -1, 1 } do
			box(ctx, `ChestPocket{i}`, U(side * 0.55, top - 0.55, -td / 2 - 0.03), Vector3.new(0.5, 0.45, 0.05), P.JacketDark)
		end
		-- Big ginger beard + moustache + sideburns
		blob(ctx, "Beard", U(0, hy - hd * 0.3, -hd * 0.3), Vector3.new(hd * 0.82, hd * 0.52, hd * 0.5), P.Beard)
		for i, side in { -1, 1 } do
			blob(ctx, `Moustache{i}`, U(side * 0.25, hy - hd * 0.18, -hd * 0.47) * CFrame.Angles(0, 0, math.rad(side * -15)), Vector3.new(0.55, 0.22, 0.22), P.Beard)
			blob(ctx, `Sideburn{i}`, U(side * hd * 0.45, hy - 0.15, -0.1), Vector3.new(0.3, 0.8, 0.55), P.Beard)
		end
		mouth(ctx, "Mouth2", p.mouthCf * CFrame.new(0, 0, -0.18), 0.22, "o")
		-- Bucket hat
		ecyl(ctx, "HatBrim", U(0, hy + hd * 0.28, 0.02), 0.12, 2.9, 2.85, P.Olive)
		ecyl(ctx, "HatCrown", U(0, hy + hd * 0.42, 0.02), 0.62, 1.95, 1.9, P.Olive)
		blob(ctx, "HatTop", U(0, hy + hd * 0.57, 0.02), Vector3.new(1.95, 0.32, 1.9), P.Olive)
		ecyl(ctx, "HatBand", U(0, hy + hd * 0.33, 0.02), 0.16, 2.0, 1.95, P.HikeBoot)
		ball(ctx, "HatPin", U(0.55, hy + hd * 0.38, -0.85), 0.2, C.CivShirtRed)
		-- Huge backpack with a bedroll on top and a tin mug hanging off
		local by = hipY + p.th * 0.6
		local bz = td / 2 + 0.5
		box(ctx, "Backpack", U(0, by, bz), Vector3.new(1.9, 2.3, 1.0), P.Pack)
		blob(ctx, "PackLid", U(0, by + 1.1, bz), Vector3.new(1.95, 0.5, 1.05), P.PackDark)
		box(ctx, "PackPocket", U(0, by - 0.45, bz + 0.52), Vector3.new(1.3, 0.8, 0.14), P.PackDark)
		local roll = U(0, by + 1.55, bz) * CFrame.Angles(0, 0, math.pi / 2)
		cyl(ctx, "Bedroll", roll, 2.2, 0.8, P.Blue)
		for i, o in { -0.6, 0.6 } do
			cyl(ctx, `RollStrap{i}`, roll * CFrame.new(0, o, 0), 0.12, 0.84, P.JacketDark)
		end
		cyl(ctx, "TinMug", U(0.98, by - 0.7, bz), 0.4, 0.4, C.Chrome)
		for i, side in { -1, 1 } do
			box(ctx, `PackStrap{i}`, U(side * 0.6, top + 0.05, 0), Vector3.new(0.3, 0.14, td + 0.1), P.PackDark)
			box(ctx, `PackStrapF{i}`, U(side * 0.6, top - 0.65, -td / 2 - 0.04), Vector3.new(0.26, 1.3, 0.06), P.PackDark)
		end
		-- Walking stick in the right hand (standing only)
		if ctx.pose == "stand" then
			local hr = p.hands[2].Position
			cyl(ctx, "Stick", CFrame.new(hr.X, (hr.Y + 0.7) / 2, hr.Z), hr.Y + 0.7, 0.2, P.Stick)
			ball(ctx, "StickKnob", CFrame.new(hr.X, hr.Y + 0.72, hr.Z), 0.3, P.Stick:Lerp(C.NumberInk, 0.2))
		end
		return personDims(p, 0.4, 1.0)
	end

	------------------------------------------------------------------------ Animal helpers
	local function wingsUp(ctx)
		return ctx.pose == "waving" or ctx.pose == "panicking"
	end

	-- Bird beak at lcf (pointing -Z): closed, or open with a red mouth when panicking/waving.
	local function beak(ctx, lcf, size, color)
		if (ctx.pose == "panicking" or ctx.pose == "waving") and not ctx.ko then
			blob(ctx, "BeakTop", lcf * CFrame.new(0, size.Y * 0.35, 0) * CFrame.Angles(math.rad(14), 0, 0), Vector3.new(size.X, size.Y * 0.7, size.Z), color)
			blob(ctx, "BeakBottom", lcf * CFrame.new(0, -size.Y * 0.45, 0.04) * CFrame.Angles(math.rad(-18), 0, 0), Vector3.new(size.X * 0.9, size.Y * 0.55, size.Z * 0.9), color)
			blob(ctx, "BeakMouth", lcf * CFrame.new(0, -size.Y * 0.05, 0.08), Vector3.new(size.X * 0.7, size.Y * 0.7, size.Z * 0.6), C.MouthIn)
		else
			blob(ctx, "Beak", lcf, size, color)
		end
	end

	-- Loose feathers flying when a bird panics.
	local function feathers(ctx, around, color)
		if ctx.pose ~= "panicking" then
			return
		end
		for i, o in { Vector3.new(-1.3, 0.6, -0.4), Vector3.new(1.4, 1.1, 0.2), Vector3.new(-0.9, 1.6, 0.6), Vector3.new(1.0, 0.2, -0.8) } do
			blob(ctx, `Feather{i}`, CFrame.new(around + o) * CFrame.Angles(math.rad(i * 30), math.rad(i * 50), math.rad(i * 70)), Vector3.new(0.18, 0.5, 0.06), color)
		end
	end

	------------------------------------------------------------------------ Duck
	local Duck = {
		Body = hex("#BDB6AA"),
		Back = hex("#7E7062"),
		Breast = hex("#7A3E2A"),
		Head = hex("#1F6B3A"),
		Beak = hex("#E8C23A"),
		Feet = hex("#F08A2A"),
		Speculum = hex("#3A5FD0"),
		Under = hex("#EDE7DA"),
	}
	local function buildDuck(ctx, _opts)
		local sitting = ctx.pose == "sitting"
		local up = if sitting then -0.45 else 0
		local function V(x, y, z)
			return CFrame.new(x, y + up, z)
		end
		if not sitting then
			for i, side in { -1, 1 } do
				cyl(ctx, `Leg{i}`, CFrame.new(side * 0.35, 0.3, 0.05), 0.5, 0.16, Duck.Feet)
				blob(ctx, `Foot{i}`, CFrame.new(side * 0.38, 0.05, -0.2) * CFrame.Angles(0, math.rad(side * -12), 0), Vector3.new(0.6, 0.1, 0.75), Duck.Feet)
			end
		end
		blob(ctx, "Body", V(0, 1.0, 0.1), Vector3.new(1.6, 1.25, 2.3), Duck.Body)
		blob(ctx, "Under", V(0, 0.68, 0.15), Vector3.new(1.35, 0.6, 1.9), Duck.Under)
		blob(ctx, "Breast", V(0, 1.12, -0.72), Vector3.new(1.35, 1.05, 0.95), Duck.Breast)
		blob(ctx, "Tail", V(0, 1.25, 1.15) * CFrame.Angles(math.rad(-25), 0, 0), Vector3.new(0.95, 0.5, 0.85), Duck.Under)
		ball(ctx, "TailBlack", V(0, 1.45, 1.42), 0.42, C.PandaBlack)
		blob(ctx, "TailCurl", V(0, 1.72, 1.4) * CFrame.Angles(math.rad(-30), 0, 0), Vector3.new(0.12, 0.38, 0.22), C.PandaBlack)
		for i, side in { -1, 1 } do
			local pivot = V(side * 0.72, 1.45, 0.15) * CFrame.Angles(0, 0, math.rad(side * (if wingsUp(ctx) then 115 else 8)))
			blob(ctx, `Wing{i}`, pivot * CFrame.new(0, -0.4, 0.15), Vector3.new(0.3, 0.95, 1.7), Duck.Back)
			box(ctx, `Speculum{i}`, pivot * CFrame.new(side * 0.14, -0.55, 0.45), Vector3.new(0.06, 0.24, 0.5), Duck.Speculum)
			box(ctx, `SpecEdge{i}`, pivot * CFrame.new(side * 0.15, -0.69, 0.45), Vector3.new(0.05, 0.05, 0.52), C.EyeWhite)
		end
		ecyl(ctx, "NeckRing", V(0, 1.68, -0.8), 0.14, 0.95, 0.95, C.EyeWhite)
		local H = V(0, 2.25, -0.85)
		blob(ctx, "Neck", V(0, 1.85, -0.82), Vector3.new(0.85, 0.75, 0.85), Duck.Head)
		blob(ctx, "Head", H, Vector3.new(1.15, 1.1, 1.2), Duck.Head)
		beak(ctx, H * CFrame.new(0, -0.18, -0.72), Vector3.new(0.62, 0.24, 0.8), Duck.Beak)
		eye(ctx, "EyeL", H * CFrame.new(-0.3, 0.2, -0.45), 0.55, Vector2.new(0.5, 0.3))
		eye(ctx, "EyeR", H * CFrame.new(0.3, 0.2, -0.45), 0.55, Vector2.new(-0.4, 0.5))
		feathers(ctx, V(0, 1.2, 0).Position, Duck.Body)
		poseFx(ctx, (H * CFrame.new(0, 0.55, 0)).Position, nil)
		return { w = 2.0, h = 2.85 + up, d = 2.9, back = 0.9, head = (H * CFrame.new(0, 0.8, 0)).Position }
	end

	------------------------------------------------------------------------ Duckling
	local Chick = { Body = hex("#F6D743"), Light = hex("#FBE88A"), Beak = hex("#F08A2A") }
	local function buildDuckling(ctx, _opts)
		local sitting = ctx.pose == "sitting"
		local up = if sitting then -0.3 else 0
		local function V(x, y, z)
			return CFrame.new(x, y + up, z)
		end
		if not sitting then
			for i, side in { -1, 1 } do
				cyl(ctx, `Leg{i}`, CFrame.new(side * 0.3, 0.25, 0), 0.4, 0.16, Chick.Beak)
				blob(ctx, `Foot{i}`, CFrame.new(side * 0.32, 0.05, -0.2), Vector3.new(0.5, 0.1, 0.6), Chick.Beak)
			end
		end
		blob(ctx, "Body", V(0, 0.9, 0.1), Vector3.new(1.5, 1.3, 1.75), Chick.Body)
		blob(ctx, "Belly", V(0, 0.8, -0.4), Vector3.new(1.05, 0.9, 0.7), Chick.Light)
		blob(ctx, "Tail", V(0, 1.15, 0.92) * CFrame.Angles(math.rad(-35), 0, 0), Vector3.new(0.45, 0.3, 0.45), Chick.Body)
		for i, side in { -1, 1 } do
			local pivot = V(side * 0.7, 1.2, 0.1) * CFrame.Angles(0, 0, math.rad(side * (if wingsUp(ctx) then 120 else 12)))
			blob(ctx, `Wing{i}`, pivot * CFrame.new(0, -0.3, 0), Vector3.new(0.25, 0.7, 0.9), Chick.Body)
		end
		local H = V(0, 2.0, -0.4)
		blob(ctx, "Head", H, Vector3.new(1.25, 1.2, 1.2), Chick.Body)
		for i, a in { -22, 0, 22 } do
			blob(ctx, `Fluff{i}`, H * CFrame.new(0, 0.62, 0.05) * CFrame.Angles(0, 0, math.rad(a)) * CFrame.new(0, 0.18, 0), Vector3.new(0.14, 0.42, 0.14), Chick.Body)
		end
		beak(ctx, H * CFrame.new(0, -0.15, -0.62), Vector3.new(0.55, 0.2, 0.55), Chick.Beak)
		eye(ctx, "EyeL", H * CFrame.new(-0.3, 0.13, -0.5), 0.6, Vector2.new(0.5, 0.4))
		eye(ctx, "EyeR", H * CFrame.new(0.3, 0.13, -0.5), 0.6, Vector2.new(0.2, 0.6))
		feathers(ctx, V(0, 1.0, 0).Position, Chick.Light)
		poseFx(ctx, (H * CFrame.new(0, 0.7, 0)).Position, nil)
		return { w = 1.7, h = 2.85 + up, d = 1.9, back = 0.8, head = (H * CFrame.new(0, 0.9, 0)).Position }
	end

	------------------------------------------------------------------------ Chicken
	local Hen = {
		Body = hex("#F6F0E4"),
		Tip = hex("#D8D2C6"),
		Comb = hex("#D93A2A"),
		Beak = hex("#E8B83A"),
		Leg = hex("#E8A23A"),
		Egg = hex("#F3E3C3"),
	}
	local function buildChicken(ctx, _opts)
		local sitting = ctx.pose == "sitting"
		local up = if sitting then -0.7 else 0
		local function V(x, y, z)
			return CFrame.new(x, y + up, z)
		end
		if sitting then
			-- Nesting on straw with an egg rolled out beside her
			ecyl(ctx, "Nest", CFrame.new(0, 0.18, 0.1), 0.36, 2.5, 2.5, P.Straw)
			ecyl(ctx, "NestRim", CFrame.new(0, 0.3, 0.1), 0.14, 2.6, 2.6, P.StrawDark)
			blob(ctx, "Egg", CFrame.new(1.05, 0.32, -0.9) * CFrame.Angles(0, 0, math.rad(20)), Vector3.new(0.5, 0.65, 0.5), Hen.Egg)
		else
			for i, side in { -1, 1 } do
				cyl(ctx, `Leg{i}`, CFrame.new(side * 0.35, 0.38, 0.05), 0.76, 0.16, Hen.Leg)
				for j, a in { -28, 0, 28 } do
					box(ctx, `Toe{i}{j}`, CFrame.new(side * 0.35, 0.04, 0.05) * CFrame.Angles(0, math.rad(a), 0) * CFrame.new(0, 0, -0.22), Vector3.new(0.09, 0.07, 0.45), Hen.Leg)
				end
				box(ctx, `ToeBack{i}`, CFrame.new(side * 0.35, 0.04, 0.2), Vector3.new(0.09, 0.07, 0.3), Hen.Leg)
			end
		end
		blob(ctx, "Body", V(0, 1.45, 0.1), Vector3.new(1.75, 1.6, 2.15), Hen.Body)
		blob(ctx, "Breast", V(0, 1.62, -0.7), Vector3.new(1.4, 1.3, 1.0), Hen.Body)
		for i, x in { -0.3, 0, 0.3 } do
			blob(ctx, `TailFeather{i}`, V(x, 2.1, 0.95) * CFrame.Angles(math.rad(-35), 0, math.rad(-x * 60)), Vector3.new(0.32, 1.1, 0.55), if i == 2 then Hen.Tip else Hen.Body)
		end
		for i, side in { -1, 1 } do
			local pivot = V(side * 0.82, 1.85, 0.15) * CFrame.Angles(0, 0, math.rad(side * (if wingsUp(ctx) then 115 else 5)))
			blob(ctx, `Wing{i}`, pivot * CFrame.new(0, -0.45, 0), Vector3.new(0.3, 1.1, 1.5), Hen.Body)
			blob(ctx, `WingTip{i}`, pivot * CFrame.new(0, -0.82, 0.5), Vector3.new(0.32, 0.42, 0.6), Hen.Tip)
		end
		local H = V(0, 2.65, -0.75)
		blob(ctx, "Head", H, Vector3.new(1.0, 1.05, 1.05), Hen.Body)
		for i, z in { -0.25, 0, 0.25 } do
			ball(ctx, `Comb{i}`, H * CFrame.new(0, 0.58 - math.abs(z) * 0.4, z), if i == 2 then 0.46 else 0.38, Hen.Comb)
		end
		blob(ctx, "Wattle", H * CFrame.new(0, -0.45, -0.48), Vector3.new(0.26, 0.46, 0.24), Hen.Comb)
		beak(ctx, H * CFrame.new(0, -0.08, -0.6), Vector3.new(0.36, 0.26, 0.5), Hen.Beak)
		eye(ctx, "EyeL", H * CFrame.new(-0.28, 0.15, -0.42), 0.5, Vector2.new(-0.5, 0.2))
		eye(ctx, "EyeR", H * CFrame.new(0.28, 0.15, -0.42), 0.5, Vector2.new(0.3, 0.6))
		feathers(ctx, V(0, 1.6, 0).Position, Hen.Body)
		poseFx(ctx, (H * CFrame.new(0, 0.8, 0)).Position, nil)
		return { w = 2.2, h = 3.4 + up, d = 2.7, back = 1.0, head = (H * CFrame.new(0, 1.0, 0)).Position }
	end

	------------------------------------------------------------------------ Deer
	local Deer = {
		Coat = hex("#A86B3C"),
		Cream = hex("#F3E3C3"),
		Hoof = hex("#2B2522"),
		Muzzle = hex("#6B4428"),
		Antler = hex("#E3D3B0"),
	}
	local function buildDeer(ctx, _opts)
		local pose = ctx.pose
		local sitting = pose == "sitting"
		local up = if sitting then -1.35 else 0
		local function V(x, y, z)
			return CFrame.new(x, y + up, z)
		end
		if sitting then
			-- Lying down with legs folded underneath
			for i, o in { Vector3.new(-0.62, 0.22, -0.75), Vector3.new(0.62, 0.22, -0.95), Vector3.new(-0.7, 0.25, 0.85), Vector3.new(0.7, 0.25, 0.85) } do
				blob(ctx, `FoldLeg{i}`, CFrame.new(o), Vector3.new(0.42, 0.4, 1.1), Deer.Coat)
				if i <= 2 then
					box(ctx, `Hoof{i}`, CFrame.new(o + Vector3.new(0, -0.05, -0.55)), Vector3.new(0.34, 0.24, 0.3), Deer.Hoof)
				end
			end
		else
			for i, p in { Vector2.new(-0.45, -1.0), Vector2.new(0.45, -1.0), Vector2.new(-0.45, 1.0), Vector2.new(0.45, 1.0) } do
				local hip = CFrame.new(p.X, 1.8, p.Y)
				if pose == "waving" and i == 2 then
					hip = hip * CFrame.Angles(math.rad(75), 0, 0)
				end
				box(ctx, `Leg{i}`, hip * CFrame.new(0, -0.85, 0), Vector3.new(0.32, 1.7, 0.32), Deer.Coat)
				box(ctx, `Hoof{i}`, hip * CFrame.new(0, -1.68, 0), Vector3.new(0.38, 0.25, 0.42), Deer.Hoof)
			end
		end
		blob(ctx, "Body", V(0, 2.35, 0.1), Vector3.new(1.45, 1.4, 3.1), Deer.Coat)
		blob(ctx, "Belly", V(0, 2.0, 0.1), Vector3.new(1.15, 0.8, 2.5), Deer.Cream)
		blob(ctx, "Rump", V(0, 2.5, 1.5), Vector3.new(1.05, 0.95, 0.45), Deer.Cream)
		blob(ctx, "Tail", V(0, 2.9, 1.68) * CFrame.Angles(math.rad(-30), 0, 0), Vector3.new(0.35, 0.6, 0.25), Deer.Cream)
		ball(ctx, "TailTop", V(0, 3.12, 1.7), 0.25, Deer.Coat)
		blob(ctx, "Neck", V(0, 3.25, -1.2) * CFrame.Angles(math.rad(-28), 0, 0), Vector3.new(0.8, 1.7, 0.85), Deer.Coat)
		blob(ctx, "Throat", V(0, 3.35, -1.55) * CFrame.Angles(math.rad(-28), 0, 0), Vector3.new(0.5, 0.7, 0.3), Deer.Cream)
		local H = V(0, 4.05 + (if pose == "panicking" then 0.15 else 0), -1.65)
		blob(ctx, "Head", H, Vector3.new(0.95, 0.9, 1.35), Deer.Coat)
		blob(ctx, "Muzzle", H * CFrame.new(0, -0.12, -0.7), Vector3.new(0.65, 0.55, 0.65), Deer.Muzzle)
		ball(ctx, "Nose", H * CFrame.new(0, -0.02, -1.02), 0.28, C.PandaBlack)
		if pose == "panicking" and not ctx.ko then
			blob(ctx, "MouthOpen", H * CFrame.new(0, -0.38, -0.85), Vector3.new(0.4, 0.3, 0.2), C.MouthIn)
		elseif ctx.ko then
			blob(ctx, "Tongue", H * CFrame.new(0.1, -0.42, -0.85), Vector3.new(0.18, 0.35, 0.1), C.Tongue)
		end
		for i, side in { -1, 1 } do
			local ear = H * CFrame.new(side * 0.42, 0.32, 0.15) * CFrame.Angles(0, 0, math.rad(-side * (if pose == "panicking" then 18 else 58)))
			blob(ctx, `Ear{i}`, ear * CFrame.new(0, 0.4, 0), Vector3.new(0.5, 0.85, 0.2), Deer.Coat)
			blob(ctx, `EarIn{i}`, ear * CFrame.new(0, 0.4, -0.07), Vector3.new(0.32, 0.6, 0.08), Deer.Cream)
			-- Antlers: beam out and back, one forward tine, one inward crown tine
			local beam = H * CFrame.new(side * 0.25, 0.4, 0.05) * CFrame.Angles(math.rad(15), 0, math.rad(-side * 30))
			cyl(ctx, `Antler{i}`, beam * CFrame.new(0, 0.6, 0), 1.2, 0.17, Deer.Antler)
			local t1 = beam * CFrame.new(0, 0.45, 0) * CFrame.Angles(math.rad(-55), 0, 0)
			cyl(ctx, `Tine{i}a`, t1 * CFrame.new(0, 0.3, 0), 0.6, 0.13, Deer.Antler)
			local t2 = beam * CFrame.new(0, 1.1, 0) * CFrame.Angles(0, 0, math.rad(side * 40))
			cyl(ctx, `Tine{i}b`, t2 * CFrame.new(0, 0.3, 0), 0.6, 0.13, Deer.Antler)
			local t3 = beam * CFrame.new(0, 1.1, 0) * CFrame.Angles(0, 0, math.rad(-side * 25))
			cyl(ctx, `Tine{i}c`, t3 * CFrame.new(0, 0.32, 0), 0.65, 0.13, Deer.Antler)
		end
		eye(ctx, "EyeL", H * CFrame.new(-0.33, 0.2, -0.55), 0.55, Vector2.new(-0.4, 0.5))
		eye(ctx, "EyeR", H * CFrame.new(0.33, 0.2, -0.55), 0.55, Vector2.new(0.5, -0.2))
		poseFx(ctx, (H * CFrame.new(0, 1.5, 0)).Position, nil)
		return { w = 1.9, h = 5.6 + up, d = 4.4, back = 0.9, head = (H * CFrame.new(0, 1.6, 0)).Position }
	end

	------------------------------------------------------------------------ Raccoon
	local Coon = {
		Fur = hex("#8D8A86"),
		Dark = hex("#3A3634"),
		Light = hex("#E0DBD2"),
		Cheese = hex("#F2C14E"),
		Crust = hex("#C68B59"),
		Pepperoni = hex("#B83A2E"),
	}
	local function buildRaccoon(ctx, _opts)
		local pose = ctx.pose
		local sitting = pose == "sitting"
		local up = if sitting then -0.55 else 0
		local function V(x, y, z)
			return CFrame.new(x, y + up, z)
		end
		if sitting then
			for i, side in { -1, 1 } do
				blob(ctx, `Leg{i}`, CFrame.new(side * 0.55, 0.3, -0.7), Vector3.new(0.6, 0.55, 1.0), Coon.Fur)
				blob(ctx, `Foot{i}`, CFrame.new(side * 0.55, 0.4, -1.25), Vector3.new(0.55, 0.7, 0.3), Coon.Dark)
			end
		else
			for i, side in { -1, 1 } do
				blob(ctx, `Leg{i}`, CFrame.new(side * 0.48, 0.55, 0), Vector3.new(0.65, 0.95, 0.7), Coon.Fur)
				blob(ctx, `Foot{i}`, CFrame.new(side * 0.5, 0.15, -0.2), Vector3.new(0.6, 0.3, 0.85), Coon.Dark)
			end
		end
		blob(ctx, "Body", V(0, 1.95, 0.05), Vector3.new(2.0, 2.2, 1.75), Coon.Fur)
		blob(ctx, "Belly", V(0, 1.85, -0.62), Vector3.new(1.3, 1.6, 0.5), Coon.Light)
		-- Ringed tail curling up behind
		for i = 1, 7 do
			local a = i / 7
			local pos = Vector3.new(0.55 * a, 0.4 + 1.7 * a * a, 0.95 + 0.85 * math.sin(a * 2.4))
			ball(ctx, `Tail{i}`, CFrame.new(pos), 0.85 - 0.05 * i, if i % 2 == 0 or i == 7 then Coon.Dark else Coon.Fur)
		end
		-- Little arms: holding a pizza slice, or up in the air
		local armsUp = pose == "waving" or pose == "panicking"
		for i, side in { -1, 1 } do
			local pivot = V(side * 0.92, 2.6, -0.25)
			if armsUp or ctx.ko then
				local ang = if ctx.ko then 20 elseif side == 1 then (if pose == "waving" then 146 else 166) else (if pose == "waving" then 158 else 140)
				pivot = pivot * CFrame.Angles(0, 0, math.rad(side * ang))
			else
				pivot = pivot * CFrame.Angles(math.rad(62), 0, math.rad(side * -18))
			end
			blob(ctx, `Arm{i}`, pivot * CFrame.new(0, -0.45, 0), Vector3.new(0.45, 1.05, 0.45), Coon.Fur)
			ball(ctx, `Paw{i}`, pivot * CFrame.new(0, -0.95, 0), 0.42, Coon.Dark)
		end
		if not armsUp and not ctx.ko then
			local slice = V(0, 1.85, -1.3) * CFrame.Angles(math.rad(-15), 0, math.pi)
			triangle(ctx, "Pizza", slice, 1.0, 1.0, 0.1, Coon.Cheese)
			box(ctx, "Crust", slice * CFrame.new(0, -0.55, 0), Vector3.new(1.05, 0.2, 0.18), Coon.Crust)
			for i, o in { Vector2.new(-0.18, -0.25), Vector2.new(0.15, -0.05) } do
				zcyl(ctx, `Pepperoni{i}`, slice * CFrame.new(o.X, o.Y, 0.07), 0.04, 0.24, Coon.Pepperoni)
			end
		end
		-- Head: cheek tufts, bandit mask, white brows, muzzle, round ears
		local H = V(0, 3.65, -0.15)
		blob(ctx, "Head", H, Vector3.new(2.0, 1.6, 1.7), Coon.Fur)
		for i, side in { -1, 1 } do
			blob(ctx, `Cheek{i}`, H * CFrame.new(side * 0.95, -0.25, -0.15) * CFrame.Angles(0, 0, math.rad(side * -25)), Vector3.new(0.7, 0.55, 0.7), Coon.Light)
			blob(ctx, `Brow{i}`, H * CFrame.new(side * 0.42, 0.45, -0.72) * CFrame.Angles(0, 0, math.rad(side * -15)), Vector3.new(0.55, 0.18, 0.2), Coon.Light)
			local ear = H * CFrame.new(side * 0.62, 0.72, 0.1) * CFrame.Angles(0, 0, math.rad(side * -20))
			blob(ctx, `EarRim{i}`, ear * CFrame.new(0, 0, 0.04), Vector3.new(0.68, 0.7, 0.2), Coon.Light)
			blob(ctx, `Ear{i}`, ear, Vector3.new(0.55, 0.58, 0.24), Coon.Dark)
		end
		blob(ctx, "Mask", H * CFrame.new(0, 0.08, -0.6), Vector3.new(2.0, 0.6, 0.6), Coon.Dark)
		blob(ctx, "Muzzle", H * CFrame.new(0, -0.35, -0.68), Vector3.new(0.95, 0.6, 0.65), Coon.Light)
		ball(ctx, "Nose", H * CFrame.new(0, -0.2, -1.02), 0.3, Coon.Dark)
		mouth(ctx, "Mouth", H * CFrame.new(0, -0.52, -0.98), 0.2, "smile")
		eye(ctx, "EyeL", H * CFrame.new(-0.42, 0.1, -0.85), 0.62, Vector2.new(-0.5, 0.3))
		eye(ctx, "EyeR", H * CFrame.new(0.42, 0.1, -0.85), 0.62, Vector2.new(0.4, 0.4))
		poseFx(ctx, (H * CFrame.new(0, 1.0, 0)).Position, nil)
		return { w = 2.6, h = 4.8 + up, d = 2.7, back = 1.1, head = (H * CFrame.new(0, 1.2, 0)).Position }
	end

	------------------------------------------------------------------------ Registry
	-- height: standing height for the lying offset (unscaled); back: lying lift.
	return {
		Farmer = { build = buildFarmer, scale = 0.9, height = 6.4, back = 1.0 },
		Grandma = { build = buildGrandma, scale = 0.85, height = 5.6, back = 0.8 },
		Kid = { build = buildKid, scale = 0.72, height = 5.9, back = 1.3 },
		FloatGuy = { build = buildFloatGuy, scale = 0.9, height = 5.8, back = 1.0 },
		RainbowGuy = { build = buildRainbowGuy, scale = 0.9, height = 5.9, back = 1.0 },
		Teacher = { build = buildTeacher, scale = 0.9, height = 5.95, back = 1.1 },
		Hiker = { build = buildHiker, scale = 0.9, height = 6.2, back = 1.7 },
		Duck = { build = buildDuck, scale = 0.9, height = 2.85, back = 0.9, pet = true },
		Duckling = { build = buildDuckling, scale = 0.5, height = 2.85, back = 0.8, pet = true },
		Chicken = { build = buildChicken, scale = 0.85, height = 3.4, back = 1.0, pet = true },
		Deer = { build = buildDeer, scale = 1.0, height = 5.6, back = 1.15, pet = true },
		Raccoon = { build = buildRaccoon, scale = 0.8, height = 4.8, back = 1.45, pet = true },
	}
end

return NpcVariants
