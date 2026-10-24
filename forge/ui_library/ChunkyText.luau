-- ChunkyText: big outlined game text (titles, numbers, labels). Use for any TextLabel players must read.
local function chunkyText(parent: Instance, text: string, size: UDim2, pos: UDim2, color: Color3?, header: boolean?): TextLabel
	local l = Instance.new("TextLabel")
	l.Text, l.Size, l.Position = text, size, pos
	l.BackgroundTransparency = 1
	l.Font = if header then Theme.Header else Theme.Body
	l.TextColor3 = color or Theme.Cream
	l.TextScaled = true
	local cap = Instance.new("UITextSizeConstraint") -- TextScaled fills the box; cap it so it stays even
	cap.MinTextSize, cap.MaxTextSize = 14, 72
	cap.Parent = l
	Theme.stroke(l, if header then 4 else 3) -- the thick dark outline is what makes text read as "game"
	l.ZIndex = 3
	l.Parent = parent
	return l
end
