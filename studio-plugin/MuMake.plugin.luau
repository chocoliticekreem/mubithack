-- MuMake: a guided playthrough notebook inside Studio.
-- Audience: a first-time teenage creator checking what friends will experience.
-- Domain: spawn, walk, try an item, finish a goal, explain a mistake, play again.
-- Palette: Studio graphite and paper, play green, edit blue, caution amber, error red.
-- Signature: a visible "What we'll try" checklist that becomes evidence after playing.
-- Replace tool tabs with a next step, raw reports with outcomes, IDs with action choices.
-- Intent: calm, readable, one choice at a time; native SourceSans, 8px rhythm,
-- inset fields, softly raised sections, color only for actions and outcomes.
local Http = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local URL = "__MUBIT_SERVICE_URL__"
local TOKEN = "__MUBIT_PAIRING_TOKEN__"
local marker = Http:GenerateGUID(false)
-- Stable internal IDs preserve the previous install's placement and single-panel cleanup.
local previous = CoreGui:FindFirstChild("MubitTesterControl")
if previous then
    local cleanup = previous:FindFirstChild("Dispose")
    if cleanup and cleanup:IsA("BindableFunction") then pcall(function() cleanup:Invoke() end) end
    if previous.Parent then previous:Destroy() end
end
local control = Instance.new("Folder")
control.Name = "MubitTesterControl"
control.Parent = CoreGui
CoreGui:SetAttribute("MubitTesterSession",marker)
local alive,bound,connecting = true,false,false
local snapshot,selectedJob,selectedAction = nil,nil,nil
local savedPreference
pcall(function() savedPreference=plugin:GetSetting("MuMakeLayoutV1") end)
local experience=Experience.new(savedPreference)
local mode,tab,selectedScenario = "quick",experience.route,"smoke.json"
local connections,actionButtons,navButtons,modeButtons = {},{},{},{}
local render,show,connect,displayReport,beginReport,applyExperience,refreshWelcome,refreshGuide,goBack
local continueWelcome,selectPreference,guideAction,welcomeActions,makeActionBar
local submittedActions=0
local toolbar = plugin:CreateToolbar("MuMake")
local toggle = toolbar:CreateButton("MuMake","Open MuMake","","MuMake")
local widget = plugin:CreateDockWidgetPluginGuiAsync("MubitTesterNativeV1",
    DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right,true,false,420,760,320,400))
widget.Title = "MuMake"
widget.Enabled = true
local function theme(name,fallback)
    local ok,value = pcall(function() return settings().Studio.Theme:GetColor(Enum.StudioStyleGuideColor[name]) end)
    return ok and value or fallback
end
local studioBackground=theme("MainBackground",Color3.fromRGB(35,35,35))
local dark=(studioBackground.R+studioBackground.G+studioBackground.B)<1.5
local function shade(light,darkColor) return Color3.fromHex(dark and darkColor or light) end
local palette={canvas=shade("F6F7FC","191D29"),surface=shade("FFFFFF","252B3B"),
    field=shade("ECEFF8","141924"),text=shade("252B42","F2F4FF"),
    secondary=shade("586078","BCC6DC"),border=shade("D9DEEE","414C66"),
    blue=shade("6545CF","B7A5FF"),onAccent=shade("FFFFFF","242039"),
    tint=shade("EEE8FF","35304C"),mint=shade("DDF6E9","253D37"),
    green=shade("246B4A","8ADCB3"),amber=shade("86591B","F0C47C"),red=shade("A23D4D","FAA1AA")}
local fonts={body=Enum.Font.SourceSans,medium=Enum.Font.SourceSansSemibold,bold=Enum.Font.SourceSansBold}
pcall(function() fonts.body=Enum.Font.BuilderSans fonts.medium=Enum.Font.BuilderSansMedium fonts.bold=Enum.Font.BuilderSansBold end)
local function round(el,radius)
    local corner=Instance.new("UICorner") corner.CornerRadius=UDim.new(0,radius or 10) corner.Parent=el
end
local function outline(el,color,width)
    local stroke=Instance.new("UIStroke") stroke.Color=color or palette.border stroke.Thickness=width or 1 stroke.Parent=el
    stroke.ApplyStrokeMode=Enum.ApplyStrokeMode.Border
    return stroke
end
local root = Instance.new("Frame")
root.BackgroundColor3=palette.canvas root.BorderSizePixel=0 root.Size=UDim2.fromScale(1,1) root.Parent=widget
local function stack(parent,padding)
    local list=Instance.new("UIListLayout")
    list.Padding=UDim.new(0,padding or 12) list.SortOrder=Enum.SortOrder.LayoutOrder list.Parent=parent
end
local function section(parent,name)
    local el=Instance.new("Frame")
    el.Name=name or "Section" el.BackgroundTransparency=1
    el.Size=UDim2.new(1,-4,0,0) el.AutomaticSize=Enum.AutomaticSize.Y el.Parent=parent
    stack(el,12)
    return el
end
local function text(parent,value,kind)
    local el=Instance.new("TextLabel")
    el.Size=UDim2.new(1,-4,0,0) el.AutomaticSize=Enum.AutomaticSize.Y
    el.BackgroundTransparency=1 el.TextWrapped=true
    el.TextXAlignment=Enum.TextXAlignment.Left el.TextYAlignment=Enum.TextYAlignment.Top
    el.Font=kind=="heading" and fonts.bold or fonts.body
    el.TextSize=kind=="heading" and 26 or (kind=="small" and 14 or 16)
    if kind=="muted" or kind=="small" then el.TextColor3=palette.secondary else el.TextColor3=palette.text end
    el.Text=value el.Parent=parent
    return el
end
local feedback
local function say(message)
    if feedback then feedback.Text=message end
    control:SetAttribute("Message",message)
end
local function button(parent,label,fn,options)
    options=options or {}
    local el=Instance.new("TextButton")
    el.Name=options.name or label el.Size=UDim2.new(1,-4,0,options.primary and 44 or 36)
    el.BackgroundColor3=options.primary and palette.blue or palette.surface
    el.BorderSizePixel=0 el.Font=fonts.medium el.TextSize=15
    el.TextColor3=options.primary and palette.onAccent or palette.text
    el.TextWrapped=true el.Text=label el.Parent=parent
    round(el,8)
    if not options.primary then outline(el) end
    el.Activated:Connect(function()
        if not el.Active then return end
        if options.action then
            if not bound then say("Open Settings to connect MuMake first.") return end
            if snapshot and snapshot.busy then say("Wait for the current check, or press Stop.") return end
            if options.ai and (not snapshot or not snapshot.has_mubit_key) then say("Connect AI in Settings first. Quick check is available.") return end
        end
        task.spawn(function()
            local ok,err=pcall(fn)
            if not ok and alive then say(tostring(err):sub(1,230)) end
        end)
    end)
    if options.action then table.insert(actionButtons,{el=el,ai=options.ai,needsReady=options.needsReady,base=label,primary=options.primary}) end
    return el
end
local function field(parent,placeholder,height)
    local el=Instance.new("TextBox")
    el.Size=UDim2.new(1,-4,0,height or 88) el.BackgroundColor3=palette.field el.BorderSizePixel=0
    el.TextColor3=palette.text el.PlaceholderColor3=palette.secondary el.Font=fonts.body
    el.TextSize=16 el.TextXAlignment=Enum.TextXAlignment.Left el.TextYAlignment=Enum.TextYAlignment.Top
    el.TextWrapped=true el.MultiLine=true el.ClearTextOnFocus=false el.Text="" el.PlaceholderText=placeholder el.Parent=parent
    local padding=Instance.new("UIPadding") padding.PaddingLeft=UDim.new(0,8) padding.PaddingRight=UDim.new(0,8)
    padding.PaddingTop=UDim.new(0,8) padding.PaddingBottom=UDim.new(0,8) padding.Parent=el
    round(el,10) outline(el)
    local stroke=el:FindFirstChildOfClass("UIStroke")
    el.Focused:Connect(function() stroke.Color=palette.blue stroke.Thickness=2 end)
    el.FocusLost:Connect(function() stroke.Color=palette.border stroke.Thickness=1 end)
    return el
end
local function clear(parent)
    for _,child in parent:GetChildren() do if child:IsA("GuiObject") then child:Destroy() end end
end
local function request(method,path,payload)
    if path=="/jobs" then submittedActions+=1 end
    local options={Url=URL..path,Method=method,Headers={Authorization="Bearer "..TOKEN,["X-Mubit-Session"]=marker}}
    if payload then options.Headers["Content-Type"]="application/json" options.Body=Http:JSONEncode(payload) end
    local response=Http:RequestAsync(options)
    local data=Http:JSONDecode(response.Body)
    if not response.Success then error(data.error or "Could not connect. Open Settings and try again.",0) end
    return data
end
local function start(operation,args)
    if not bound then error("Open Settings to connect MuMake first.",0) end
    if snapshot and snapshot.busy then error("Wait for the current check, or press Stop.",0) end
    local job=request("POST","/jobs",{operation=operation,args=args or {}})
    selectedJob=job.id selectedAction=nil
    if beginReport then beginReport(job) end
    say("Getting started…")
    if show then show("Results") end
end
local header=Instance.new("Frame") header.Name="Header" header.BackgroundTransparency=1
header.Position=UDim2.fromOffset(20,16) header.Size=UDim2.new(1,-40,0,60) header.Parent=root
local brandMark=Instance.new("Frame") brandMark.Size=UDim2.fromOffset(32,32)
brandMark.BackgroundColor3=palette.blue brandMark.BorderSizePixel=0 brandMark.Parent=header round(brandMark,10)
local brandLetter=text(brandMark,"M") brandLetter.AutomaticSize=Enum.AutomaticSize.None
brandLetter.Size=UDim2.fromScale(1,1) brandLetter.TextXAlignment=Enum.TextXAlignment.Center
brandLetter.TextYAlignment=Enum.TextYAlignment.Center brandLetter.Font=fonts.bold brandLetter.TextSize=22 brandLetter.TextColor3=palette.onAccent
local brandTitle=text(header,"MuMake","heading") brandTitle.Position=UDim2.fromOffset(42,2)
brandTitle.Size=UDim2.new(1,-176,0,30) brandTitle.TextSize=22
local status=text(header,"Connecting to your game…","small") status.Position=UDim2.fromOffset(0,42)
local guideLink=button(header,"Guide",function() show("Guide") end)
guideLink.Position=UDim2.new(1,-116,0,0) guideLink.Size=UDim2.fromOffset(50,32) guideLink.TextSize=13
local settingsLink=button(header,"Settings",function() show("Settings") end)
settingsLink.Position=UDim2.new(1,-60,0,0) settingsLink.Size=UDim2.fromOffset(60,32) settingsLink.TextSize=13
local wayfinding=Instance.new("Frame") wayfinding.BackgroundTransparency=1 wayfinding.Position=UDim2.fromOffset(20,84)
wayfinding.Size=UDim2.new(1,-40,0,28) wayfinding.Parent=root
local backButton=button(wayfinding,"Back",function() goBack() end)
backButton.Size=UDim2.fromOffset(54,28) backButton.TextSize=13
local layoutLabel=text(wayfinding,"Your workspace","small") layoutLabel.Position=UDim2.fromOffset(68,5)
layoutLabel.Size=UDim2.new(1,-196,0,24)
local controlsToggle=button(wayfinding,"More controls",function()
    experience.moreControls=not Experience.config(experience).controls
    -- A temporary toggle never changes the saved age or experience preference.
    applyExperience()
end)
controlsToggle.Size=UDim2.fromOffset(120,28) controlsToggle.Position=UDim2.new(1,-120,0,0) controlsToggle.TextSize=13
local nav=Instance.new("Frame") nav.BackgroundTransparency=1 nav.Position=UDim2.fromOffset(20,124)
nav.Size=UDim2.new(1,-40,0,36) nav.Parent=root
local body=Instance.new("ScrollingFrame") body.Name="Content" body.BackgroundTransparency=1 body.BorderSizePixel=0
body.Position=UDim2.fromOffset(20,176) body.Size=UDim2.new(1,-36,1,-236)
body.ScrollBarThickness=3 body.ScrollBarImageColor3=palette.border body.AutomaticCanvasSize=Enum.AutomaticSize.Y
body.CanvasSize=UDim2.new() body.Parent=root stack(body,20)
local footer=section(root,"Footer") footer.Position=UDim2.new(0,20,1,-48) footer.Size=UDim2.new(1,-40,0,0)
feedback=text(footer,"Start with an idea for your game.","small")
feedback.AutomaticSize=Enum.AutomaticSize.None feedback.Size=UDim2.new(1,-4,0,32)
local stopButton=button(footer,"Stop MuMake",function()
    request("POST","/cancel",{}) say("Stopping MuMake…")
end)
local pages={}
for _,name in {"Welcome","Guide","Make game","Check game","Results","Settings"} do
    pages[name]=section(body,name) pages[name].Visible=name==tab
end
local function layoutSurface()
    local special=tab=="Welcome" or tab=="Guide"
    local active=snapshot and snapshot.active~=nil
    nav.Visible=not special wayfinding.Visible=tab~="Welcome" or experience.onboardingStep==2 or #experience.history>0
    backButton.Visible=#experience.history>0 or (tab=="Welcome" and experience.onboardingStep==2)
    guideLink.Visible=tab~="Welcome" settingsLink.Visible=tab~="Welcome"
    controlsToggle.Visible=not special
    if welcomeActions then
        welcomeActions.Visible=tab=="Welcome"
        welcomeActions.Position=UDim2.new(0,20,1,active and -220 or -112)
    end
    if makeActionBar then makeActionBar.Visible=tab=="Make game" and not active end
    footer.Visible=(not special and tab~="Make game") or active stopButton.Visible=active
    footer.Position=UDim2.new(0,20,1,active and -100 or -48)
    local top=tab=="Welcome" and (wayfinding.Visible and 124 or 88) or (tab=="Guide" and 124 or 176)
    local bottom=tab=="Welcome" and (active and 236 or 128)
        or (makeActionBar and makeActionBar.Visible and math.max(120,makeActionBar.AbsoluteSize.Y+32))
        or (footer.Visible and (active and 116 or 64) or 16)
    body.Position=UDim2.fromOffset(20,top) body.Size=UDim2.new(1,-36,1,-top-bottom)
end
show=function(name,replace)
    if not pages[name] then return end
    if replace then experience.route=name else Experience.navigate(experience,name) end
    tab=name
    for key,page in pages do page.Visible=key==name end
    for key,b in navButtons do
        b.BackgroundColor3=key==name and palette.tint or palette.canvas
        b.TextColor3=key==name and palette.blue or palette.secondary
    end
    layoutSurface() body.CanvasPosition=Vector2.zero
    if name=="Welcome" and refreshWelcome then refreshWelcome() end
    if name=="Guide" and refreshGuide then refreshGuide() end
end
goBack=function()
    Experience.back(experience)
    show(experience.route,true)
end
for index,item in {{id="Make game",title="Make game"},{id="Check game",title="Check game"},{id="Results",title="Results"}} do
    local b=button(nav,item.title,function() show(item.id) end)
    b.Size=UDim2.new(1/3,-6,1,0) b.Position=UDim2.new((index-1)/3,0,0,0)
    navButtons[item.id]=b
end
-- Onboarding is a presentation preference. Never attach it to a request payload.
local welcome=pages.Welcome
local welcomeArt=Instance.new("Frame") welcomeArt.Name="BuildIllustration" welcomeArt.BackgroundColor3=palette.tint
welcomeArt.Size=UDim2.new(1,-4,0,72) welcomeArt.BorderSizePixel=0 welcomeArt.Parent=welcome round(welcomeArt,16)
for index=1,5 do
    local tile=Instance.new("Frame") tile.Name="BuildingBlock" tile.Size=UDim2.fromOffset(42,24)
    tile.Position=UDim2.new(.12+(index-1)*.15,-8,0,48-(index-1)*8)
    tile.Rotation=-12 tile.BorderSizePixel=0 tile.BackgroundColor3=index%2==0 and palette.blue or palette.green
    tile.Parent=welcomeArt round(tile,5)
    local top=Instance.new("Frame") top.BackgroundTransparency=.65 top.BackgroundColor3=Color3.new(1,1,1)
    top.BorderSizePixel=0 top.Size=UDim2.new(1,-8,0,4) top.Position=UDim2.fromOffset(4,4) top.Parent=tile round(top,2)
end
local welcomeTitle=text(welcome,"Make this space yours.","heading")
local welcomeBody=text(welcome,"Choose a visual style for your age range. Next, choose how much help you’d like.","muted")
local welcomeChoices=section(welcome,"Choices")
local choiceButtons={}
local function choice(parent,title,description,onChoose)
    local row=button(parent,"",onChoose)
    row.Size=UDim2.new(1,-4,0,76) row.Text="" row.AutoButtonColor=false
    local heading=text(row,title) heading.Font=fonts.medium heading.Position=UDim2.fromOffset(16,12)
    heading.Size=UDim2.new(1,-64,0,24)
    local descriptionText=text(row,description,"small") descriptionText.Position=UDim2.fromOffset(16,38)
    descriptionText.Size=UDim2.new(1,-56,0,36)
    local dot=Instance.new("Frame") dot.Size=UDim2.fromOffset(18,18) dot.Position=UDim2.new(1,-34,.5,-9)
    dot.BackgroundColor3=palette.surface dot.BorderSizePixel=0 dot.Parent=row round(dot,9) outline(dot,palette.border)
    return {row=row,heading=heading,dot=dot,stroke=row:FindFirstChildOfClass("UIStroke")}
end
local rememberButton=button(welcome,"Remember this layout on this device: off",function()
    experience.remember=not experience.remember refreshWelcome()
end)
rememberButton.TextSize=13
local privacy=text(welcome,"Optional. No name or birthday. Your choices only change this interface and are not sent to our server or AI requests.","small")
welcomeActions=section(root,"WelcomeActions") welcomeActions.Position=UDim2.new(0,20,1,-112) welcomeActions.Size=UDim2.new(1,-40,0,0)
continueWelcome=function()
    if experience.onboardingStep==1 then
        experience.onboardingStep=2 refreshWelcome() layoutSurface() body.CanvasPosition=Vector2.zero
    else
        Experience.accept(experience)
        if experience.remember then pcall(function() plugin:SetSetting("MuMakeLayoutV1",Experience.preference(experience)) end)
        else pcall(function() plugin:SetSetting("MuMakeLayoutV1",nil) end) end
        applyExperience() show("Make game",true)
    end
end
local welcomeContinue=button(welcomeActions,"Next: choose your controls",function() continueWelcome() end,{primary=true})
local skipWelcome=button(welcomeActions,"Skip this. Let me make a game.",function()
    Experience.skip(experience) applyExperience() show("Make game",true)
end)
refreshWelcome=function()
    clear(welcomeChoices) choiceButtons={}
    local isAge=experience.onboardingStep==1
    welcomeArt.Visible=isAge
    welcomeTitle.Text=isAge and "Make this space yours." or "How would you like to build?"
    welcomeBody.Text=isAge and "Choose a visual style for your age range. This is optional and stays here." or "Same real tools. Choose how much guidance and detail you want upfront."
    local options=isAge and Experience.audiences or Experience.levels
    local selected=isAge and experience.pendingAudience or experience.pendingLevel
    for _,option in options do
        local row=choice(welcomeChoices,option.title,option.description,function()
            selectPreference(isAge and "audience" or "level",option.id)
        end)
        local chosen=option.id==selected
        row.row.BackgroundColor3=chosen and palette.tint or palette.surface
        row.stroke.Color=chosen and palette.blue or palette.border row.stroke.Thickness=chosen and 2 or 1
        row.dot.BackgroundColor3=chosen and palette.blue or palette.surface
        choiceButtons[option.id]=row
    end
    rememberButton.Text="Remember this layout on this device: "..(experience.remember and "on" or "off")
    welcomeContinue.Text=isAge and "Next: choose your controls" or "Open my workspace"
end
selectPreference=function(kind,id)
    local ok=kind=="audience" and Experience.chooseAudience(experience,id) or (kind=="level" and Experience.chooseLevel(experience,id))
    if ok then refreshWelcome() end
    return ok
end
local guide=pages.Guide
text(guide,"A little help, when you need it.","heading")
local guidePosition=text(guide,"Step 1 of 4","small")
local guideTitle=text(guide,"Start with one fun idea","heading")
local guideDescription=text(guide,"","muted")
local guideTip=section(guide,"TryIt")
local guideTry=button(guideTip,"Try an idea",function() if guideAction then guideAction() end end,{primary=true})
local guideNext=button(guide,"Next",function()
    if experience.guideStep==4 then show("Make game")
    else experience.guideStep+=1 refreshGuide() end
end)
local guidePrevious=button(guide,"Previous step",function()
    experience.guideStep=math.max(1,experience.guideStep-1) refreshGuide()
end)
button(guide,"Done for now",function()
    if #experience.history>0 then goBack() else show("Make game") end
end)
text(guide,"Opening the guide never starts AI calls, changes your code, or runs your game.","small")
local makePage=pages["Make game"]
local makeTitle=text(makePage,"What do you want to make?","heading")
local makeIntro=text(makePage,"Tell MuMake your idea. Start small; you can try the first version in Studio.","muted")
local makePath=section(makePage,"YourNextSteps")
local pathText=text(makePath,"Your idea   /   First draft   /   Try it in Studio","small")
pathText.TextColor3=palette.blue
local idea=field(makePage,"Example: an obby where players collect coins and avoid rising lava.",136)
local starters=section(makePage,"IdeaStarters")
text(starters,"Pick a starting point, or write your own.","small")
for _,example in {"An obby with coins and checkpoints","A race through a disappearing maze","A tiny island with a treasure hunt"} do
    button(starters,example,function() idea.Text=example idea:CaptureFocus() end)
end
local extraBuild=section(makePage,"DraftControls")
text(extraBuild,"Shape your first draft","heading")
text(extraBuild,"What should it include? (optional)","small")
local mustHave=field(extraBuild,"Example: coins, three checkpoints, and a finish line.",72)
text(extraBuild,"Anything to leave out? (optional)","small")
local avoid=field(extraBuild,"Example: no timer, no enemies.",64)
local buildAccess=text(makePage,"Checking whether game creation is ready…","small")
local makeButton=button(makePage,"Make my game",function()
    if not idea.Text:match("%S") then error("Describe the game you want to make first.",0) end
    local prompt=idea.Text
    if mustHave.Text:match("%S") then prompt ..= "\n\nInclude these features: "..mustHave.Text end
    if avoid.Text:match("%S") then prompt ..= "\n\nLeave these out: "..avoid.Text end
    if #prompt>3000 then error("Keep your idea and extra details under 3000 characters so MuMake can read all of it.",0) end
    start("make_game",{idea=prompt})
end,{primary=true,action=true,ai=true})
makeActionBar=section(root,"MakeAction")
makeActionBar.Size=UDim2.new(1,-40,0,0) makeActionBar.AnchorPoint=Vector2.new(0,1)
makeActionBar.Position=UDim2.new(0,20,1,-16)
buildAccess.Parent=makeActionBar makeButton.Parent=makeActionBar
makeActionBar:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutSurface)
local buildExplanation=text(makePage,"MuMake plans the game, writes its code, and checks the draft for code errors. Then you can add it to this Studio window.","muted")
text(makePage,"Creating a game uses paid AI calls. The draft stays separate from your current game until you add it.","small")
local checkPage=pages["Check game"]
local checkTitle=text(checkPage,"Will it work for your friends?","heading")
local checkIntro=text(checkPage,"Let MuMake try your game, then see what happened.","muted")
local preparation=section(checkPage,"Preparation")
text(preparation,"First, prepare this game")
text(preparation,"Add small helper scripts so MuMake can play and spot problems. You can undo this in Studio.","muted")
button(preparation,"Prepare this game",function() start("install_harness") end,{action=true})
local choose=Instance.new("Frame") choose.BackgroundTransparency=1 choose.Size=UDim2.new(1,-4,0,36) choose.Parent=checkPage
local modePanel=section(checkPage,"Plan")
local quick=section(modePanel,"Quick")
text(quick,"What we’ll try","heading")
text(quick,"1. Join your game\n2. Walk to a new spot\n3. Look for game errors")
text(quick,"A built-in check. No AI calls needed.","small")
local goalPanel=section(modePanel,"Goal") goalPanel.Visible=false
text(goalPanel,"What should a player be able to do?","heading")
local goal=field(goalPanel,"Example: pick up a hose and put out a fire.",96)
text(goalPanel,"MuMake will join, choose actions to try your goal, and check what actually happened.","muted")
local aiAccess=text(goalPanel,"Checking whether AI play is ready…","small")
local go
local function setMode(value)
    mode=value quick.Visible=value=="quick" goalPanel.Visible=value=="goal"
    for key,b in modeButtons do
        b.BackgroundColor3=key==value and palette.tint or palette.surface
        b.TextColor3=key==value and palette.blue or palette.secondary
    end
    if go then go.Text=value=="quick" and "Check my game" or "Try my goal" end
    if snapshot then render(snapshot) end
end
for index,item in {{id="quick",label="Quick check"},{id="goal",label="Try a goal"}} do
    local b=button(choose,item.label,function() setMode(item.id) end)
    b.Size=UDim2.new(.5,-4,1,0) b.Position=UDim2.new((index-1)*.5,0,0,0) modeButtons[item.id]=b
end
local goReason=text(checkPage,"","small")
go=button(checkPage,"Check my game",function()
    if mode=="quick" then start("scenario",{scenario="smoke.json"})
    else
        if not goal.Text:match("%S") then error("Write what you want a player to do first.",0) end
        start("playtest",{goal=goal.Text,steps=8})
    end
end,{primary=true})
text(checkPage,"MuMake plays with one character in this window, then stops. It does not change your game code.","small")
local explanation=section(checkPage,"HowItWorks") explanation.Visible=false
button(checkPage,"How does this work?",function() explanation.Visible=not explanation.Visible end)
-- Keep the explanation below its toggle in layout order.
explanation.LayoutOrder=100
text(explanation,"You give the goal. MuMake tries it. You see the evidence.","heading")
text(explanation,"Quick check follows a ready-made checklist. Try a goal uses AI to pick a move, look at what changed, and pick the next move. A second AI reviews the playthrough.","muted")
text(explanation,"Trying the same goal again gives another playthrough. It is not a newly generated, fixed test script.","small")
local results=pages.Results
text(results,"What happened?","heading")
local resultSummary=section(results,"Summary")
local resultTitle=text(resultSummary,"Your first draft starts with an idea.")
local resultStatus=text(resultSummary,"Make a game first, or check the game you already have. Your drafts and playthroughs will appear here.","muted")
local resultDetail=text(resultSummary,"","muted")
local checkRows=section(results,"CheckedThings")
local issueRows=section(results,"PossibleProblems")
local reportActions=section(results,"NextSteps")
local actionRows=section(results,"PlaythroughActions")
local correction=section(results,"Feedback") correction.Visible=false
text(correction,"What should MuMake have done?","heading")
local correctionContext=text(correction,"","muted")
local correctionNote=field(correction,"Example: use the door beside you instead of walking into the wall.",88)
text(correction,"We send your explanation as another example for Mubit. This does not change your game or instantly teach the AI.","small")
button(correction,"Send feedback",function()
    if not selectedAction or not selectedAction.run_id then error("Choose a move from an AI playthrough first.",0) end
    if not correctionNote.Text:match("%S") then error("Explain what you expected first.",0) end
    start("correct",{run_id=selectedAction.run_id,step=selectedAction.step,player=selectedAction.player,note=correctionNote.Text})
    correction.Visible=false correctionNote.Text=""
end,{action=true,ai=true})
local technical=section(results,"Technical") technical.Visible=false
local details=field(technical,"",200) details.TextEditable=false
local history=section(results,"EarlierChecks")
beginReport=function(job)
    clear(checkRows) clear(issueRows) clear(reportActions) clear(actionRows)
    correction.Visible=false technical.Visible=false
    resultTitle.Text=job.operation=="playtest" and job.args.goal or (job.operation=="make_game" and "Making your game" or "Your next step")
    resultStatus.Text="Getting ready…" resultStatus.TextColor3=palette.blue
    resultDetail.Text="MuMake is finding your game. You can press Stop at any time."
end
local settingsPage=pages.Settings
text(settingsPage,"Make this space yours","heading")
local preferenceText=text(settingsPage,"Change the style or the amount of guidance anytime.","muted")
button(settingsPage,"Change my layout",function()
    Experience.reopen(experience) show("Welcome",true)
end)
button(settingsPage,"Replay the tool guide",function() experience.guideStep=1 show("Guide") end)
button(settingsPage,"Forget my saved layout",function()
    pcall(function() plugin:SetSetting("MuMakeLayoutV1",nil) end)
    experience.remember=false say("Saved layout cleared on this device. Your current workspace stays open.")
end)
text(settingsPage,"Only the layout choice can be saved in Studio. It is never added to game prompts, test reports or requests to the helper.","small")
text(settingsPage,"Connections","heading")
local connectionText=text(settingsPage,"Looking for this Studio window…","muted")
button(settingsPage,"Connect MuMake",function() connect() end)
button(settingsPage,"Allow MuMake to connect in this local game",function()
    if game.PlaceId~=0 then error("Open Experience Settings to allow HTTP for a published game.",0) end
    Http.HttpEnabled=true connect()
end)
text(settingsPage,"AI connection","heading")
local aiSetting=text(settingsPage,"Checking AI connection…","muted")
text(settingsPage,"AI play uses paid calls. You can always use Quick check without an AI key.","small")
local more=section(settingsPage,"MoreChecks")
text(more,"More things to try","heading")
text(more,"These ready-made checks are for the firefighter game. Some need more players and cannot finish in this one-player version.","small")
local moreChoices=section(more,"Choices")
local advanced=section(settingsPage,"DeveloperDetails") advanced.Visible=false advanced.LayoutOrder=100
button(settingsPage,"Technical setup details",function() advanced.Visible=not advanced.Visible end)
text(advanced,"The prototype needs the local Python helper and Studio MCP. Enable Studio as MCP server in Assistant’s settings.","small")
text(advanced,"Start the helper:\n.venv/bin/python scripts/install-studio-plugin.py\n\nAI setup: MUBIT_API_KEY in .env, then restart the helper.","small")
local connectionDetail=text(advanced,URL,"small")
button(advanced,"Prepare this game again",function() start("install_harness") end,{action=true})
button(advanced,"Read the game that is playing now",function() start("inspect") end,{action=true})
button(advanced,"Ask AI to look for problems",function() start("explore",{steps=8}) end,{action=true,ai=true,needsReady=true})
local selectedCheck=text(advanced,"Selected: Quick check","small")
button(advanced,"Run selected check",function() start("scenario",{scenario=selectedScenario}) end,{action=true,needsReady=true})
local controlDock=section(makePage,"WorkspaceTools")
controlDock.LayoutOrder=90
text(controlDock,"Tools at hand","heading")
button(controlDock,"See my drafts and results",function() show("Results") end)
button(controlDock,"Check the character and game errors",function() show("Check game") end)
button(controlDock,"Look for problems with AI",function() start("explore",{steps=8}) end,{action=true,ai=true,needsReady=true})
applyExperience=function()
    local config=Experience.config(experience)
    palette.blue=experience.audience=="adult" and shade("345BC4","A9C0FF") or (experience.audience=="younger" and shade("7042C6","C6AEFF") or shade("6545CF","B7A5FF"))
    palette.tint=experience.audience=="adult" and shade("E8EDFB","2B3449") or (experience.audience=="younger" and shade("EFE5FF","3A2F4F") or shade("EEE8FF","35304C"))
    brandMark.BackgroundColor3=palette.blue
    welcomeArt.BackgroundColor3=palette.tint
    welcomeContinue.BackgroundColor3=palette.blue guideTry.BackgroundColor3=palette.blue
    layoutLabel.Text=experience.level=="guided" and "Guided workspace" or (experience.level=="balanced" and "Your workspace" or "Creator workspace")
    controlsToggle.Text=config.controls and "Fewer controls" or "More controls"
    makeTitle.Text=config.focused and "Build your next game." or (config.playful and "Let’s make something fun." or "What do you want to make?")
    makeIntro.Text=config.stepByStep and "Start with one idea. We’ll turn it into a draft you can try and improve." or "Describe the game. Review the draft. Try it in Studio."
    makeIntro.Visible=config.hints
    makePath.Visible=config.stepByStep or config.playful
    pathText.Text=config.playful and "Your idea    /    Make it real    /    Play & improve" or "Your idea    /    First draft    /    Try it in Studio"
    pathText.TextColor3=palette.blue
    idea.Size=UDim2.new(1,-4,0,config.playful and 148 or (config.focused and 112 or 136))
    starters.Visible=config.hints
    extraBuild.Visible=config.controls controlDock.Visible=config.controls
    buildExplanation.Visible=config.hints
    checkTitle.Text=config.stepByStep and "Will it work for your friends?" or "Check your game."
    checkIntro.Visible=config.hints
    advanced.Visible=config.controls
    preferenceText.Text="Guidance: "..(experience.level=="guided" and "step by step" or (experience.level=="balanced" and "a little help" or "full workspace"))..". You can change it any time."
    for _,entry in actionButtons do
        if entry.el.Parent then entry.el.Size=UDim2.new(1,-4,0,entry.primary and 46 or config.rowHeight) end
    end
    if snapshot then render(snapshot) end
    show(experience.route,true)
end
local guideSteps={
    {title="Start with one fun idea",body="Tell MuMake what players do. ‘Collect coins while lava rises’ is a great start. You can choose an example and change it before building.",action="Open Make game",route="Make game"},
    {title="Make a draft you can change",body="Make my game uses AI to plan and write your first version. It takes paid AI calls. The draft stays separate until you choose Add draft to Studio.",action="See the creation tools",route="Make game"},
    {title="Try it before friends do",body="Add your draft to a local Studio game, then press Play to try it. Check game can also move a real character and look for game errors. Stop is always available while MuMake is working.",action="Open Check game",route="Check game"},
    {title="Explain what should be better",body="Read Results to see what happened. If the AI made a wrong move, choose it and explain what you expected. Fix ideas are previews; a fix is only verified after the game is checked again.",action="Open Results",route="Results"},
}
refreshGuide=function()
    local step=guideSteps[experience.guideStep]
    guidePosition.Text="Step "..experience.guideStep.." of "..#guideSteps
    guideTitle.Text=step.title guideDescription.Text=step.body guideTry.Text=step.action
    guideAction=function() show(step.route) end
    guidePrevious.Visible=experience.guideStep>1
    guideNext.Text=experience.guideStep==4 and "Go to my workspace" or "Next step"
end
connect=function()
    if connecting then return end
    connecting=true status.Text="Connecting to your game…"
    local ok,result=pcall(function() return request("POST","/bind",{marker=marker}) end)
    if alive then
        bound=ok control:SetAttribute("Connected",ok)
        control:SetAttribute("ConnectionDetail",ok and "Paired" or tostring(result):sub(1,500))
        status.Text=ok and "Connected to this Studio window" or "Connection needs attention · open Settings"
        connectionText.Text=ok and "MuMake is connected to the game in this window." or "MuMake cannot connect yet. Open Technical setup details below for help with this prototype."
        connectionDetail.Text=ok and URL or tostring(result):sub(1,500)
    end
    connecting=false
end
local function readable(value,depth)
    depth=depth or 0
    if type(value)~="table" then return tostring(value) end
    if depth>5 then return Http:JSONEncode(value) end
    local keys={} for key in value do table.insert(keys,key) end
    table.sort(keys,function(a,b) if type(a)=="number" and type(b)=="number" then return a<b end return tostring(a)<tostring(b) end)
    local out={}
    for _,key in keys do table.insert(out,string.rep("  ",depth)..tostring(key)..": "..readable(value[key],depth+1)) end
    return table.concat(out,"\n")
end
local function updateButton(el,enabled,primary)
    el.Active=enabled el.AutoButtonColor=enabled
    el.TextColor3=enabled and (primary and palette.onAccent or palette.text) or palette.secondary
    el.BackgroundColor3=enabled and primary and palette.blue or palette.surface
end
local function eligibleAI()
    return bound and snapshot and snapshot.has_mubit_key and not snapshot.busy
end
local function showTechnical(value)
    technical.Visible=true details.Text=readable(value)
    local size=game:GetService("TextService"):GetTextSize(details.Text,16,details.Font,Vector2.new(math.max(220,details.AbsoluteSize.X-20),100000))
    details.Size=UDim2.new(1,-4,0,math.clamp(size.Y+24,160,16000))
end
displayReport=function(job)
    local view=job.presentation
    if not view then return end
    selectedJob=job.id
    resultTitle.Text=view.title resultStatus.Text=view.status resultDetail.Text=view.summary
    if job.state=="passed" then resultStatus.TextColor3=palette.green
    elseif job.state=="failed" then resultStatus.TextColor3=palette.amber else resultStatus.TextColor3=palette.secondary end
    clear(checkRows) clear(issueRows) clear(reportActions) clear(actionRows)
    correction.Visible=false technical.Visible=false
    if job.operation=="make_game" and job.result then
        if #(job.result.files or {})>0 then
            text(checkRows,"What your draft aims to do","heading")
            for _,item in job.result.acceptance or {} do text(checkRows,tostring(item)) end
            text(checkRows,tostring(#job.result.files).." game scripts written. Not played yet.","small")
        end
        if job.state=="passed" and job.result.ready then
            button(reportActions,"Add draft to Studio",function() start("load_game",{source_job=job.id}) end,{primary=true,action=true})
            text(reportActions,"Adds the draft scripts to this local game with Undo. If a script would replace your own code, MuMake stops and asks you to use an empty game.","small")
        end
    end
    if job.operation=="load_game" and job.state=="passed" then
        button(reportActions,"Check my game",function() show("Check game") end)
    end
    for _,check in view.checks do
        local prefix=check.optional and "Not checked: " or (check.ok and "Worked: " or "Did not pass: ")
        local row=text(checkRows,prefix..check.title)
        row.TextColor3=check.optional and palette.amber or (check.ok and palette.green or palette.red)
    end
    if #view.issues>0 then text(issueRows,"Things to look at","heading") end
    for _,issue in view.issues do
        text(issueRows,issue.title) text(issueRows,issue.evidence,"muted")
        if issue.can_suggest then
            button(issueRows,"Get a fix idea",function() start("suggest_fix",{run_id=view.run_id,bug=issue.index}) end,{action=true,ai=true})
        end
    end
    if view.can_repeat then
        button(reportActions,"Try this check again",function() start(job.operation,job.args) end,{action=true,ai=job.operation~="scenario",needsReady=true})
        text(reportActions,"After changing your game, play again to see if the problem is gone.","small")
    end
    if job.operation=="suggest_fix" and job.result then
        text(reportActions,(job.result.critique or {}).summary or "A code suggestion is ready.","muted")
        button(reportActions,"See the suggested code change",function() showTechnical({file=job.result.path,change=job.result.patch_preview}) end)
        text(reportActions,"Code changes need review. MuMake has not applied this idea.","small")
    end
    if #view.actions>0 then
        text(actionRows,"Moves MuMake tried","heading")
        text(actionRows,"Choose a move if MuMake misunderstood you.","small")
    end
    for _,action in view.actions do
        button(actionRows,action.title,function()
            selectedAction={run_id=view.run_id,step=action.step,player=action.player}
            correction.Visible=true correctionContext.Text=action.title..(action.reason~="" and ": "..action.reason or "")
            say("Explain what MuMake should try instead.")
        end)
    end
    button(reportActions,"Show technical details",function()
        if technical.Visible then technical.Visible=false else showTechnical(job) end
    end)
end
local historyKey,choicesKey="",""
render=function(data)
    snapshot=data
    layoutSurface()
    local ready=data.session and data.session.harness_ready
    preparation.Visible=bound and not ready
    control:SetAttribute("Busy",data.busy)
    control:SetAttribute("Connected",bound)
    local aiReady=bound and data.has_mubit_key
    buildAccess.Text=aiReady and "Ready to make your first draft. This can take a few minutes." or "Game creation needs AI connected in Settings. Your idea can stay here while you set it up."
    aiAccess.Text=aiReady and "AI play is ready. This uses paid AI calls, with up to 8 moves and a review." or "AI play is not connected yet. Quick check is available; open Settings for AI setup."
    aiSetting.Text=aiReady and "Connected. Game creation, goal play and feedback are available." or "Not connected yet. Add a Mubit key in Technical setup details to create games or use AI play."
    local canGo=bound and ready and not data.busy and (mode=="quick" or aiReady)
    updateButton(go,canGo,true)
    if not bound then goReason.Text="Open Settings to connect MuMake."
    elseif not ready then goReason.Text="Prepare this game above, then you can check it."
    elseif data.busy then goReason.Text="A check is already running. You can stop it below."
    elseif mode=="goal" and not aiReady then goReason.Text="AI play needs setup. Switch to Quick check to begin now."
    else goReason.Text=mode=="quick" and "Ready. Let’s try the basics." or "Ready. MuMake will try the goal you wrote." end
    updateButton(stopButton,data.active~=nil,false)
    local liveButtons={}
    for _,item in actionButtons do
        if item.el.Parent then
            table.insert(liveButtons,item)
            updateButton(item.el,bound and not data.busy and (not item.ai or data.has_mubit_key) and (not item.needsReady or ready),item.primary)
        end
    end
    actionButtons=liveButtons
    local active=data.active
    if active then
        control:SetAttribute("JobId",active.id) control:SetAttribute("JobState",active.state)
        local latest=active.events[#active.events]
        local message=latest and latest.message or "Getting ready…"
        if message:find("Connecting") then message="Finding your game…"
        elseif message:find("Starting a solo") then message="Joining your game…"
        elseif message:find("player%(s%) ready") then message="Your character is ready. Trying the check…"
        elseif message:find("act:") then message="Trying a move in your game…"
        elseif message:find("Stopping") then message=active.operation=="make_game" and "Stopping the build. Your draft stays saved." or "Finishing up and stopping play…"
        elseif message:find("Mubit") or message:find("AI decisions") then message="AI is deciding what to try…"
        elseif message:find("Scenario finished") then message="Checking what happened…" end
        say(message)
        if selectedJob==active.id then
            resultTitle.Text=(active.presentation or {}).title or "Checking your game"
            resultStatus.Text=active.state=="cancelling" and "Stopping…" or (active.operation=="make_game" and "Making your first draft…" or "Working on your game…")
            resultStatus.TextColor3=palette.blue resultDetail.Text=message
        end
    elseif data.history[1] then
        local latest=data.history[1] control:SetAttribute("JobId",latest.id) control:SetAttribute("JobState",latest.state)
        say((latest.presentation or {}).status or "Check finished. Open Results.")
    end
    local key=""
    for _,job in data.history do key ..= job.id..job.state..tostring(job.ended or "") end
    if key~=historyKey then
        historyKey=key clear(history)
        if not selectedJob and data.history[1] then selectedJob=data.history[1].id end
        local selected
        for _,job in data.history do if job.id==selectedJob then selected=job end end
        if selected and selected.state~="running" and selected.state~="queued" and selected.state~="cancelling" then displayReport(selected) end
        if #data.history>1 then text(history,"Earlier checks","heading") end
        for _,job in data.history do
            if job.id~=selectedJob then
                local view=job.presentation or {}
                local when=DateTime.fromUnixTimestamp(job.created):FormatLocalTime("HH:mm","en-us")
                button(history,when.." · "..(view.title or "Check"),function() displayReport(job) end)
            end
        end
    end
    local choices=Http:JSONEncode(data.check_choices or {})
    if choices~=choicesKey then
        choicesKey=choices clear(moreChoices)
        for _,choice in data.check_choices or {} do
            if choice.file~="smoke.json" then
                button(moreChoices,choice.title,function()
                    selectedScenario=choice.file selectedCheck.Text="Selected: "..choice.title.."\n"..choice.description
                    advanced.Visible=true
                end)
            end
        end
    end
end
modeButtons.quick.BackgroundColor3=palette.tint
modeButtons.quick.TextColor3=palette.blue
refreshWelcome() refreshGuide() applyExperience()
show(experience.route,true)
table.insert(connections,toggle.Click:Connect(function() widget.Enabled=not widget.Enabled end))
table.insert(connections,widget:GetPropertyChangedSignal("Enabled"):Connect(function() toggle:SetActive(widget.Enabled) end))
local function dispose()
    if not alive then return end
    alive=false
    if snapshot and snapshot.active then task.spawn(function() pcall(function() request("POST","/cancel",{}) end) end) end
    for _,c in connections do c:Disconnect() end
    widget:Destroy() pcall(function() toolbar:Destroy() end)
    if CoreGui:GetAttribute("MubitTesterSession")==marker then CoreGui:SetAttribute("MubitTesterSession",nil) end
    control:Destroy()
end
local cleanup=Instance.new("BindableFunction") cleanup.Name="Dispose" cleanup.OnInvoke=dispose cleanup.Parent=control
table.insert(connections,plugin.Unloading:Connect(dispose))
local command=Instance.new("BindableFunction") command.Name="Command"
command.OnInvoke=function(operation,args)
    args=args or {}
    if operation=="diagnostics" then
        return {title=widget.Title,status=status.Text,detail=connectionDetail.Text,bound=bound,enabled=widget.Enabled,
            tab=tab,mode=mode,can_make=makeButton.Active,make_reason=buildAccess.Text,can_check=go.Active,result_title=resultTitle.Text,result_status=resultStatus.Text,
            result_summary=resultDetail.Text,feedback=say and feedback.Text,visible_checks=#checkRows:GetChildren()-1,
            onboarding_step=experience.onboardingStep,back_visible=backButton.Visible,
            extra_controls=extraBuild.Visible,guide_step=experience.guideStep,submitted_actions=submittedActions,
            draft_chars=#idea.Text,guide_title=guideTitle.Text}
    end
    if operation=="onboard_choose" then return selectPreference(args.kind,args.value) end
    if operation=="onboard_next" then continueWelcome() return true end
    if operation=="onboard_skip" then Experience.skip(experience) applyExperience() show("Make game",true) return true end
    if operation=="open_layout" then Experience.reopen(experience) show("Welcome",true) return true end
    if operation=="back" then goBack() return true end
    if operation=="guide_step" then experience.guideStep=math.clamp(tonumber(args.step) or 1,1,4) refreshGuide() return true end
    if operation=="set_draft" then idea.Text=tostring(args.text or "") return true end
    if operation=="toggle_controls" then experience.moreControls=not experience.moreControls applyExperience() return true end
    if operation=="layout_snapshot" then
        local originalSize=root.Size
        if args.width and args.height then
            root.Size=UDim2.fromOffset(math.clamp(args.width,320,1000),math.clamp(args.height,400,1400))
            task.wait(.15)
        end
        local nodes={}
        local function visible(el)
            local node=el
            while node and node~=widget do
                if node:IsA("GuiObject") and not node.Visible then return false end
                node=node.Parent
            end
            return true
        end
        for _,el in root:GetDescendants() do
            if el:IsA("GuiObject") and visible(el) then
                local pos=el.AbsolutePosition-root.AbsolutePosition
                local item={class=el.ClassName,name=el.Name,x=pos.X,y=pos.Y,w=el.AbsoluteSize.X,h=el.AbsoluteSize.Y,
                    bg={el.BackgroundColor3.R,el.BackgroundColor3.G,el.BackgroundColor3.B},alpha=1-el.BackgroundTransparency,
                    rotation=el.Rotation,z=el.ZIndex}
                local corner=el:FindFirstChildOfClass("UICorner")
                if corner then item.radius=corner.CornerRadius.Offset end
                local stroke=el:FindFirstChildOfClass("UIStroke")
                if stroke then item.stroke={stroke.Color.R,stroke.Color.G,stroke.Color.B,stroke.Thickness} end
                if el:IsA("TextLabel") or el:IsA("TextButton") or el:IsA("TextBox") then
                    item.text=el:IsA("TextBox") and el.Text=="" and el.PlaceholderText or el.Text
                    item.size=el.TextSize item.font=el.Font.Name item.color={el.TextColor3.R,el.TextColor3.G,el.TextColor3.B}
                    item.align=el.TextXAlignment.Name item.valign=el.TextYAlignment.Name item.text_h=el.TextBounds.Y
                end
                local parent=el.Parent
                while parent and parent~=widget do
                    if parent:IsA("ScrollingFrame") then
                        local at=parent.AbsolutePosition-root.AbsolutePosition
                        item.clip={at.X,at.Y,parent.AbsoluteSize.X,parent.AbsoluteSize.Y}
                        break
                    end
                    parent=parent.Parent
                end
                table.insert(nodes,item)
            end
        end
        local output={width=root.AbsoluteSize.X,height=root.AbsoluteSize.Y,nodes=nodes,
            background={palette.canvas.R,palette.canvas.G,palette.canvas.B}}
        root.Size=originalSize
        return output
    end
    if operation=="show" then show(args.tab) return true end
    if operation=="reconnect" then connect() return true end
    if operation=="set_mode" then setMode(args.mode) return true end
    start(operation,args) return true
end
command.Parent=control
task.spawn(function()
    connect()
    while alive do
        if bound then
            local ok,data=pcall(function() return request("GET","/state") end)
            if ok and alive then
                local rendered,err=pcall(function() render(data) end)
                if not rendered then control:SetAttribute("RenderError",tostring(err)) say("The panel could not update. Reconnect in Settings.") end
            elseif alive then
                bound=false status.Text="Connection lost · open Settings"
                connectionText.Text="MuMake lost its connection. Try Connect MuMake."
                connectionDetail.Text=tostring(data):sub(1,500)
                updateButton(go,false,true)
                for _,item in actionButtons do if item.el.Parent then updateButton(item.el,false,item.primary) end end
            end
        end
        task.wait(1.5)
    end
end)
