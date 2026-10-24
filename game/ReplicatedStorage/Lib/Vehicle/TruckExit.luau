--!strict
-- TruckExit [owner: Vehicle agent]. Where you stand when you get OUT of a fire truck: instantly beside it
-- (no doors to open), on a spot that is actually free. Used by VehicleController (the local hop-out) and
-- VehicleService (the server fallback when the client didn't place you).
--   TruckExit.spot(truck: Model, seat: BasePart?, ignore: { Instance }) -> CFrame
--     Candidates in the chassis frame, nearest to your seat first: your side of the cab, the other side,
--     beside the body further back, behind the tailgate, in front of the bumper. The first one whose
--     character-sized box (3 x 4.6 x 3) hits nothing solid (other trucks, walls, props; `ignore` = your
--     own character) and has ground under it wins. All blocked: on the roof (always free).
local TruckExit = {}

local BOX = Vector3.new(3, 4.6, 3)

-- chassis-space offsets (X right, Z back); y = 1.5 puts the root ~3.9 studs above the road
local CAB_SIDE = { Vector3.new(7.6, 1.5, -4.2), Vector3.new(7.6, 1.5, 3), Vector3.new(7.6, 1.5, 10) }
local REAR = Vector3.new(0, 1.5, 17.5)
local FRONT = Vector3.new(0, 1.5, -17.5)
local ROOF = Vector3.new(0, 9, 2)

local function candidates(sideSign: number, cab: boolean): { Vector3 }
	local out: { Vector3 } = {}
	local function sideList(sgn: number)
		for _, v in CAB_SIDE do
			table.insert(out, Vector3.new(v.X * sgn, v.Y, v.Z))
		end
	end
	if cab then
		sideList(sideSign)
		sideList(-sideSign)
		table.insert(out, REAR)
	else
		table.insert(out, Vector3.new(3 * sideSign, 1.5, 17.5))
		table.insert(out, REAR)
		sideList(sideSign)
		sideList(-sideSign)
	end
	table.insert(out, FRONT)
	return out
end

function TruckExit.spot(truck: Model, seat: BasePart?, ignore: { Instance }): CFrame
	local chassis = truck.PrimaryPart
	if not chassis then
		return truck:GetPivot()
	end
	local c = chassis.CFrame
	local rel = if seat then c:PointToObjectSpace(seat.Position) else Vector3.new(-1, 0, -6)
	local sideSign = if rel.X < 0 then -1 else 1
	local cab = rel.Z < -4
	local filter = table.clone(ignore)
	table.insert(filter, truck)
	local op = OverlapParams.new()
	op.FilterType = Enum.RaycastFilterType.Exclude
	op.FilterDescendantsInstances = filter
	op.RespectCanCollide = true
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = filter
	for _, off in candidates(sideSign, cab) do
		local pos = c * off
		-- flat, upright: never tilted with a truck that's on a slope or on its side
		local face = (pos - c.Position) * Vector3.new(1, 0, 1)
		local cf = if face.Magnitude > 0.1 then CFrame.lookAt(pos, pos + face.Unit) else CFrame.new(pos)
		local blocked = #workspace:GetPartBoundsInBox(cf * CFrame.new(0, 0.6, 0), BOX, op) > 0
		if not blocked then
			local ground = workspace:Raycast(pos, Vector3.new(0, -12, 0), rp)
			if ground then
				return cf
			end
		end
	end
	local top = c * ROOF
	return CFrame.new(top)
end

return TruckExit
