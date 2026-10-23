-- Native Studio front end. The installer supplies only a localhost pairing token.
local Http = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local URL = "__MUBIT_SERVICE_URL__"
local TOKEN = "__MUBIT_PAIRING_TOKEN__"
local marker = Http:GenerateGUID(false)
local previous = CoreGui:FindFirstChild("MubitTesterControl")
if previous then
    local cleanup = previous:FindFirstChild("Dispose")
    if cleanup and cleanup:IsA("BindableFunction") then pcall(function() cleanup:Invoke() end) end
    if previous.Parent then previous:Destroy() end
end
local control = Instance.new("Folder")
control.Name = "MubitTesterControl"
control.Parent = CoreGui
CoreGui:SetAttribute("MubitTesterSession", marker)
local alive, bound, connecting = true, false, false
local snapshot = nil
local selectedScenario, selectedJob = "smoke.json", nil
local tab = "Test"
local eventConnections = {}
local toolbar = plugin:CreateToolbar("Mubit Tester")
local toggle = toolbar:CreateButton("MubitTester", "Open Mubit Tester", "", "Mubit Tester")
local widget = plugin:CreateDockWidgetPluginGuiAsync("MubitTesterNativeV1",
    DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, true, false, 380, 700, 320, 400))
widget.Title = "Mubit Tester"
widget.Enabled = true
local function color(name, fallback)
    local ok, value = pcall(function() return settings().Studio.Theme:GetColor(Enum.StudioStyleGuideColor[name]) end)
    return ok and value or fallback
end
local bg = color("MainBackground", Color3.fromRGB(35,35,35))
local panel = color("InputFieldBackground", Color3.fromRGB(48,48,48))
local fg = color("MainText", Color3.fromRGB(235,235,235))
local muted = color("DimmedText", Color3.fromRGB(167,167,167))
local accent = Color3.fromRGB(51,145,233)
local root = Instance.new("Frame")
root.Size = UDim2.fromScale(1,1)
root.BackgroundColor3 = bg
root.BorderSizePixel = 0
root.Parent = widget
local function label(parent, text, height, tint)
    local el = Instance.new("TextLabel")
    el.Size = UDim2.new(1,0,0,height or 24)
    el.BackgroundTransparency = 1
    el.Font = Enum.Font.SourceSans
    el.TextSize = 15
    el.TextColor3 = tint or fg
    el.TextXAlignment = Enum.TextXAlignment.Left
    el.TextYAlignment = Enum.TextYAlignment.Center
    el.TextWrapped = true
    el.Text = text
    el.Parent = parent
    return el
end
local header = Instance.new("Frame")
header.BackgroundTransparency = 1
header.Position = UDim2.fromOffset(14,10)
header.Size = UDim2.new(1,-28,0,60)
header.Parent = root
local title = label(header,"MUBIT TESTER",24)
title.Font = Enum.Font.SourceSansBold
title.TextSize = 18
local status = label(header,"Connecting to local companion…",32,muted)
status.Position = UDim2.fromOffset(0,26)
local nav = Instance.new("Frame")
nav.BackgroundTransparency = 1
nav.Position = UDim2.fromOffset(14,76)
nav.Size = UDim2.new(1,-28,0,32)
nav.Parent = root
local body = Instance.new("ScrollingFrame")
body.Name = "Content"
body.Position = UDim2.fromOffset(14,120)
body.Size = UDim2.new(1,-28,1,-206)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = 4
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.CanvasSize = UDim2.new()
body.Parent = root
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0,10)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = body
local footer = Instance.new("Frame")
footer.Position = UDim2.new(0,14,1,-76)
footer.Size = UDim2.new(1,-28,0,64)
footer.BackgroundTransparency = 1
footer.Parent = root
local feedback = label(footer,"Ready when connected",25,muted)
local buttons = {}
local function button(parent, text, fn, jobButton)
    local el = Instance.new("TextButton")
    el.Size = UDim2.new(1,0,0,32)
    el.BackgroundColor3 = panel
    el.BorderSizePixel = 0
    el.Font = Enum.Font.SourceSansSemibold
    el.TextSize = 15
    el.TextColor3 = fg
    el.Text = text
    el.AutoButtonColor = true
    el.Parent = parent
    el.Activated:Connect(function()
        if jobButton and (not bound or (snapshot and snapshot.busy)) then return end
        task.spawn(function()
            local ok, err = pcall(fn)
            if not ok and alive then feedback.Text = tostring(err):sub(1,180) end
        end)
    end)
    if jobButton then table.insert(buttons,el) end
    return el
end
local function field(parent, placeholder, height, multiline)
    local el = Instance.new("TextBox")
    el.Size = UDim2.new(1,-4,0,height or 32)
    el.BackgroundColor3 = panel
    el.BorderSizePixel = 0
    el.TextColor3 = fg
    el.PlaceholderColor3 = muted
    el.Font = Enum.Font.SourceSans
    el.TextSize = 15
    el.TextXAlignment = Enum.TextXAlignment.Left
    el.TextYAlignment = multiline and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center
    el.ClearTextOnFocus = false
    el.MultiLine = multiline or false
    el.TextWrapped = true
    el.PlaceholderText = placeholder
    el.Text = ""
    el.Parent = parent
    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0,8)
    padding.PaddingTop = UDim.new(0,5)
    padding.PaddingRight = UDim.new(0,8)
    padding.Parent = el
    return el
end
local function request(method, path, payload)
    local options = {Url=URL..path, Method=method, Headers={
        ["Authorization"]="Bearer "..TOKEN, ["X-Mubit-Session"]=marker}}
    if payload then
        options.Headers["Content-Type"] = "application/json"
        options.Body = Http:JSONEncode(payload)
    end
    local response = Http:RequestAsync(options)
    local data = Http:JSONDecode(response.Body)
    if not response.Success then error(data.error or ("HTTP "..response.StatusCode),0) end
    return data
end
local function start(operation,args)
    if not bound then error("Reconnect in Setup first",0) end
    local job = request("POST","/jobs",{operation=operation,args=args or {}})
    selectedJob = job.id
    feedback.Text = "Job queued"
end
local stop = button(footer,"Stop test",function()
    request("POST","/cancel",{})
    feedback.Text = "Stopping and returning to Edit…"
end)
stop.Position = UDim2.fromOffset(0,30)
local pages = {}
for _, name in {"Test","AI","Reports","Setup"} do
    local page = Instance.new("Frame")
    page.Name = name
    page.BackgroundTransparency = 1
    page.Size = UDim2.new(1,-6,0,0)
    page.AutomaticSize = Enum.AutomaticSize.Y
    page.Visible = name==tab
    page.Parent = body
    local list = Instance.new("UIListLayout")
    list.Padding = UDim.new(0,10)
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Parent = page
    pages[name] = page
end
local navButtons = {}
local function show(name)
    tab = name
    for key,page in pages do page.Visible = key==name end
    for key,b in navButtons do b.BackgroundColor3 = key==name and accent or panel end
    body.CanvasPosition = Vector2.zero
end
for index,name in {"Test","AI","Reports","Setup"} do
    local b = button(nav,name,function() show(name) end)
    b.Size = UDim2.new(0.25,-5,1,0)
    b.Position = UDim2.new((index-1)*0.25,0,0,0)
    navButtons[name] = b
end
label(pages.Test,"Run a repeatable game check",28).Font=Enum.Font.SourceSansBold
label(pages.Test,"Runs in this window with one player. Each owned test returns to Edit when it finishes.",52,muted)
local scenarioSelect = button(pages.Test,"Scenario: smoke",function() end)
local scenarioList = Instance.new("Frame")
scenarioList.Size = UDim2.new(1,0,0,0)
scenarioList.AutomaticSize = Enum.AutomaticSize.Y
scenarioList.BackgroundTransparency=1
scenarioList.Visible=false
scenarioList.Parent=pages.Test
local sl = Instance.new("UIListLayout")
sl.Padding=UDim.new(0,4)
sl.Parent=scenarioList
scenarioSelect.Activated:Connect(function() scenarioList.Visible=not scenarioList.Visible end)
local description = label(pages.Test,"Choose a bundled scenario. Multiplayer checks report skipped in solo mode.",64,muted)
button(pages.Test,"Run scenario",function() start("scenario",{scenario=selectedScenario}) end,true)
button(pages.Test,"Read current playtest",function() start("inspect") end,true)
label(pages.Test,"Latest activity",24).Font=Enum.Font.SourceSansBold
local activity=label(pages.Test,"No test has run yet.",160,muted)
activity.TextYAlignment=Enum.TextYAlignment.Top
label(pages.AI,"Give the AI a goal",28).Font=Enum.Font.SourceSansBold
label(pages.AI,"AI actions and judging go through Mubit using the companion’s API key. These runs use paid API calls.",64,muted)
local goal=field(pages.AI,"Example: pick up a hose and extinguish a fire",100,true)
local budget=field(pages.AI,"Maximum ticks: 1 to 20",32)
budget.Text="8"
local keyStatus=label(pages.AI,"Checking Mubit configuration…",42,muted)
button(pages.AI,"Playtest goal",function() start("playtest",{goal=goal.Text,steps=tonumber(budget.Text) or 8}) end,true)
button(pages.AI,"Explore for up to one minute",function() start("explore",{steps=tonumber(budget.Text) or 8}) end,true)
label(pages.AI,"One player in the current window. A tick can make multiple API calls; this is a step limit, not a price cap.",72,muted)
label(pages.Reports,"Saved runs",28).Font=Enum.Font.SourceSansBold
local reportList=Instance.new("Frame")
reportList.Size=UDim2.new(1,0,0,0)
reportList.AutomaticSize=Enum.AutomaticSize.Y
reportList.BackgroundTransparency=1
reportList.Parent=pages.Reports
local rl=Instance.new("UIListLayout") rl.Padding=UDim.new(0,4) rl.Parent=reportList
local report=field(pages.Reports,"Reports appear here",260,true)
report.TextEditable=false
local runId=field(pages.Reports,"AI run ID (filled when you select an AI report)",32)
button(pages.Reports,"Suggest a fix for bug 1",function() start("suggest_fix",{run_id=runId.Text,bug=0}) end,true)
label(pages.Reports,"Suggestions are previews. Review the patch before changing game source.",42,muted)
local step=field(pages.Reports,"Decision step number",32)
local player=field(pages.Reports,"Player name (optional)",32)
local note=field(pages.Reports,"What should the AI have done instead?",64,true)
button(pages.Reports,"Send correction to Mubit",function()
    if note.Text=="" then error("Describe the correction first",0) end
    start("correct",{run_id=runId.Text,step=tonumber(step.Text) or 1,player=player.Text,note=note.Text})
end,true)
label(pages.Setup,"Local connection",28).Font=Enum.Font.SourceSansBold
label(pages.Setup,"The native panel talks to a local Python companion. Keep the companion running and Studio MCP enabled in Assistant settings.",78,muted)
local connect
button(pages.Setup,"Reconnect this window",function() connect() end)
button(pages.Setup,"Enable HTTP for this local place",function()
    if game.PlaceId~=0 then error("Use Experience Settings for a published place",0) end
    Http.HttpEnabled=true
    connect()
end)
button(pages.Setup,"Install test harness in this local place",function() start("install_harness") end,true)
label(pages.Setup,"Harness setup adds four Studio-only test scripts with an undo record. Published places use the repository’s normal sync workflow.",82,muted)
label(pages.Setup,"Start or reinstall from the repository:\n.venv/bin/python scripts/install-studio-plugin.py\n\nAI key: MUBIT_API_KEY in .env\nThe key stays in Python, outside the plugin.",116,muted)
local connectionDetail=label(pages.Setup,URL,70,muted)
connectionDetail.TextYAlignment=Enum.TextYAlignment.Top
connect=function()
    if connecting then return end
    connecting=true
    status.Text="Connecting this Studio window…"
    local ok,result=pcall(function() return request("POST","/bind",{marker=marker}) end)
    if alive then
        bound=ok
        control:SetAttribute("Connected",ok)
        control:SetAttribute("ConnectionDetail",ok and "Paired" or tostring(result):sub(1,500))
        status.Text=ok and ("Connected · "..(result.name or "Studio")) or "Companion unavailable · open Setup"
        connectionDetail.Text=ok and (URL.."\nBound to this Studio window") or tostring(result):sub(1,500)
    end
    connecting=false
end
local historyKey, scenarioKey = "", ""
local function readable(value, depth)
    depth=depth or 0
    if type(value)~="table" then return tostring(value) end
    if depth>6 then return Http:JSONEncode(value) end
    local keys={}
    for key in value do table.insert(keys,key) end
    table.sort(keys,function(a,b)
        if type(a)=="number" and type(b)=="number" then return a<b end
        return tostring(a)<tostring(b)
    end)
    local lines={}
    for _,key in keys do
        local v=value[key]
        table.insert(lines,string.rep("  ",depth)..tostring(key)..": "..(type(v)=="table" and "\n"..readable(v,depth+1) or tostring(v)))
    end
    return table.concat(lines,"\n")
end
local function displayReport(job)
    local text=job.operation.." · "..job.state.."\n\n"..readable(job.result or {error=job.error or "",state=job.state})
    report.Text=text
    local size=game:GetService("TextService"):GetTextSize(text,report.TextSize,report.Font,Vector2.new(math.max(200,report.AbsoluteSize.X-20),100000))
    report.Size=UDim2.new(1,-4,0,math.clamp(size.Y+24,260,20000))
    runId.Text=(job.result and job.result.run_id) or ""
end
local function render(data)
    snapshot=data
    control:SetAttribute("Connected",bound)
    control:SetAttribute("Busy",data.busy)
    keyStatus.Text=data.has_mubit_key and ("Mubit configured · "..data.model) or "MUBIT_API_KEY missing. Scripted scenarios are available."
    stop.Active=data.active~=nil
    stop.AutoButtonColor=stop.Active
    stop.TextColor3=stop.Active and fg or muted
    for _,b in buttons do
        if b.Parent then
            b.Active=bound and not data.busy
            b.TextColor3=b.Active and fg or muted
        end
    end
    local active=data.active
    if active then
        control:SetAttribute("JobState",active.state)
        control:SetAttribute("JobId",active.id)
        feedback.Text=active.operation.." · "..active.state
        local lines={}
        for i=math.max(1,#active.events-6),#active.events do table.insert(lines,active.events[i].message) end
        activity.Text=table.concat(lines,"\n")
    elseif data.history[1] then
        local latest=data.history[1]
        control:SetAttribute("JobState",latest.state)
        control:SetAttribute("JobId",latest.id)
        feedback.Text=latest.operation.." · "..latest.state
        activity.Text=latest.error or (latest.result and (latest.result.summary or latest.result.reason)) or "Select a saved run in Reports."
    end
    local sk=Http:JSONEncode(data.scenarios)
    if sk~=scenarioKey then
        scenarioKey=sk
        for _,child in scenarioList:GetChildren() do if child:IsA("GuiObject") then child:Destroy() end end
        for _,s in data.scenarios do
            button(scenarioList,s.name,function()
                selectedScenario=s.file
                scenarioSelect.Text="Scenario: "..s.name
                description.Text=s.description or ""
                scenarioList.Visible=false
            end)
        end
    end
    local hk=""
    for _,j in data.history do hk ..= j.id..j.state..tostring(j.ended or "") end
    if hk~=historyKey then
        historyKey=hk
        for _,child in reportList:GetChildren() do if child:IsA("GuiObject") then child:Destroy() end end
        for _,j in data.history do
            button(reportList,j.operation.." · "..j.state,function()
                selectedJob=j.id
                displayReport(j)
            end)
            if selectedJob==j.id then
                displayReport(j)
            end
        end
    end
end
show("Test")
table.insert(eventConnections,toggle.Click:Connect(function() widget.Enabled=not widget.Enabled end))
table.insert(eventConnections,widget:GetPropertyChangedSignal("Enabled"):Connect(function() toggle:SetActive(widget.Enabled) end))
local function dispose()
    if not alive then return end
    alive=false
    if snapshot and snapshot.active then task.spawn(function() pcall(function() request("POST","/cancel",{}) end) end) end
    for _,c in eventConnections do c:Disconnect() end
    widget:Destroy()
    pcall(function() toolbar:Destroy() end)
    if CoreGui:GetAttribute("MubitTesterSession")==marker then CoreGui:SetAttribute("MubitTesterSession",nil) end
    control:Destroy()
end
local disposeHook=Instance.new("BindableFunction")
disposeHook.Name="Dispose"
disposeHook.OnInvoke=dispose
disposeHook.Parent=control
table.insert(eventConnections,plugin.Unloading:Connect(dispose))
-- Local integration diagnostics invoke the same service operations as the buttons.
local command=Instance.new("BindableFunction")
command.Name="Command"
command.OnInvoke=function(operation,args)
    if operation=="diagnostics" then return {status=status.Text,detail=connectionDetail.Text,bound=bound,enabled=widget.Enabled} end
    if operation=="reconnect" then connect() return true end
    if operation=="show" then show(args.tab) return true end
    start(operation,args)
    return true
end
command.Parent=control
task.spawn(function()
    connect()
    while alive do
        if bound then
            local ok,data=pcall(function() return request("GET","/state") end)
            if ok and alive then render(data)
            elseif alive then bound=false status.Text="Companion disconnected · open Setup" connectionDetail.Text=tostring(data):sub(1,500) end
        end
        task.wait(1.5)
    end
end)
