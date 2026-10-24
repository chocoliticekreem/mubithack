--!strict
-- FootstepController [owner: AV lane / polish]. Footstep variety without new assets: every character's
-- default "Running" Sound (made by Roblox's RbxCharacterSounds) gets a PitchShiftSoundEffect and an
-- EqualizerSoundEffect, retuned by the floor material under that character (heavy boots on concrete,
-- dull thuds on grass, a bright clank on metal, hollow wood) plus a small per-step wobble, so walking
-- around never sounds like one looped clip. Characters farther than Radius from the camera are skipped.
-- Cheap: one 6 Hz loop, no new Sounds, nothing sent to the server.
local Players = game:GetService("Players")

local FootstepController = {}
FootstepController.Priority = 120

-- material -> { octave, lowGain dB, highGain dB }
type Tone = { octave: number, low: number, high: number }
local DEFAULT: Tone = { octave = 0.92, low = 2, high = -2 } -- turnout boots: a touch heavier than stock
local TONES: { [Enum.Material]: Tone } = {
	[Enum.Material.Grass] = { octave = 0.78, low = 3, high = -14 },
	[Enum.Material.LeafyGrass] = { octave = 0.78, low = 3, high = -14 },
	[Enum.Material.Ground] = { octave = 0.8, low = 3, high = -12 },
	[Enum.Material.Mud] = { octave = 0.72, low = 4, high = -16 },
	[Enum.Material.Sand] = { octave = 0.82, low = 0, high = -12 },
	[Enum.Material.Snow] = { octave = 0.85, low = 0, high = -14 },
	[Enum.Material.Wood] = { octave = 0.9, low = 5, high = -4 },
	[Enum.Material.WoodPlanks] = { octave = 0.9, low = 5, high = -4 },
	[Enum.Material.Metal] = { octave = 1.22, low = -4, high = 4 },
	[Enum.Material.DiamondPlate] = { octave = 1.25, low = -4, high = 5 },
	[Enum.Material.CorrodedMetal] = { octave = 1.15, low = -2, high = 3 },
	[Enum.Material.Concrete] = { octave = 0.95, low = 1, high = 0 },
	[Enum.Material.Asphalt] = { octave = 0.93, low = 1, high = -1 },
	[Enum.Material.Pavement] = { octave = 0.95, low = 1, high = 0 },
	[Enum.Material.Brick] = { octave = 0.97, low = 0, high = 0 },
	[Enum.Material.Cobblestone] = { octave = 0.98, low = 0, high = 1 },
	[Enum.Material.Slate] = { octave = 1.0, low = 0, high = 1 },
	[Enum.Material.Marble] = { octave = 1.08, low = -1, high = 3 },
	[Enum.Material.Glass] = { octave = 1.12, low = -2, high = 4 },
	[Enum.Material.Fabric] = { octave = 0.82, low = 0, high = -12 },
}

local Hz = 6
local Radius = 90
local Wobble = 0.035 -- +/- octave jitter per tick (reads as step-to-step variety)

type Rig = { sound: Sound, pitch: PitchShiftSoundEffect, eq: EqualizerSoundEffect }
local rigs: { [Model]: Rig } = setmetatable({}, { __mode = "k" }) :: any
local rng = Random.new()

local function rigFor(char: Model): Rig?
	local r = rigs[char]
	if r and r.sound.Parent then
		return r
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	local s = root and root:FindFirstChild("Running")
	if not s or not s:IsA("Sound") then
		return nil
	end
	local pitch = Instance.new("PitchShiftSoundEffect")
	pitch.Name = "Forge_StepPitch"
	pitch.Octave = DEFAULT.octave
	pitch.Parent = s
	local eq = Instance.new("EqualizerSoundEffect")
	eq.Name = "Forge_StepEq"
	eq.LowGain = DEFAULT.low
	eq.MidGain = 0
	eq.HighGain = DEFAULT.high
	eq.Parent = s
	local rig: Rig = { sound = s :: Sound, pitch = pitch, eq = eq }
	rigs[char] = rig
	return rig
end

local function tick()
	local cam = workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position or Vector3.zero
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not char or not hum or not root then
			continue
		end
		if (root.Position - camPos).Magnitude > Radius then
			continue
		end
		local rig = rigFor(char)
		if not rig or not rig.sound.IsPlaying then
			continue
		end
		local tone = TONES[hum.FloorMaterial] or DEFAULT
		rig.pitch.Octave = math.clamp(tone.octave + rng:NextNumber(-Wobble, Wobble), 0.5, 2)
		rig.eq.LowGain = tone.low
		rig.eq.HighGain = tone.high
	end
end

function FootstepController:Init(_controllers: { [string]: any }) end

function FootstepController:Start()
	task.spawn(function()
		while true do
			task.wait(1 / Hz)
			local ok, err = pcall(tick)
			if not ok then
				warn(`[FootstepController] {err}`)
				task.wait(5)
			end
		end
	end)
end

return FootstepController
