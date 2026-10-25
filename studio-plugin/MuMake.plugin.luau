-- MuMake: a guided playthrough notebook inside Studio.
-- Audience: a first-time teenage creator checking what friends will experience.
-- Domain: spawn, walk, try an item, finish a goal, explain a mistake, play again.
-- Palette: the MuHack dashboard's cream paper, ink text, leaf and peach pills, butter for live work.
-- Signature: a visible "What we'll try" checklist that becomes evidence after playing.
-- Replace tool tabs with a next step, raw reports with outcomes, IDs with action choices.
-- Intent: calm, readable, one choice at a time; Fredoka headings, Nunito body, 8px rhythm,
-- borderless rounded cards on cream, color only for actions and outcomes.
local Http = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local URL = "__MUBIT_SERVICE_URL__"
local TOKEN = "__MUBIT_PAIRING_TOKEN__"
local marker = Http:GenerateGUID(false)
local transferred
-- Stable internal IDs preserve the previous install's placement and single-panel cleanup.
local previous = CoreGui:FindFirstChild("MubitTesterControl")
if previous then
    local export=previous:FindFirstChild("ExportState")
    if export and export:IsA("BindableFunction") then
        local ok,value=pcall(function() return export:Invoke() end)
        if ok and type(value)=="table" and value.version==1 then transferred=value end
    end
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
if transferred and type(transferred.experience)=="table" then experience=transferred.experience end
local mode,tab,selectedScenario = "quick",experience.route,"smoke.json"
local connections,actionButtons,navButtons,modeButtons = {},{},{},{}
local render,show,connect,displayReport,beginReport,applyExperience,refreshWelcome,refreshGuide,goBack
local continueWelcome,selectPreference,guideAction,welcomeActions,makeActionBar
local submittedActions=0
local selectedDraftJob,selectedDraftPath
local stepBudget=8
local draftOperations={make_game=true,open_game=true,iterate_game=true,correct_game=true}
local toolbar = plugin:CreateToolbar("MuMake")
local toggle = toolbar:CreateButton("MuMake","Open MuMake","","MuMake")
local widget = plugin:CreateDockWidgetPluginGuiAsync("MubitTesterNativeV1",
    DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right,true,false,Layout.defaultWidth,760,Layout.minWidth,400))
widget.Title = "MuMake"
widget.Enabled = true
-- Same tokens as forge/dashboard.html :root, in every Studio theme, so the panel and the dashboard match.
local hex=Color3.fromHex
local palette={canvas=hex("FBF4E4"),surface=hex("FFFDF8"),field=hex("F7EFDD"),text=hex("4B3B2F"),
    secondary=hex("8A7766"),border=hex("ECDFC6"),edge=hex("E4D4B4"),
    blue=hex("7FB069"),onAccent=hex("FFFFFF"),accentText=hex("5F9E4A"),
    tint=hex("FDF0C4"),selected=hex("F2E6CC"),peach=hex("F4A685"),butter=hex("F9D56E"),sky=hex("84C5E3"),
    green=hex("5F9E4A"),amber=hex("B8693F"),red=hex("D9534F"),dash=hex("EFDCA0")}
local fonts
local fontsOk=pcall(function()
    local nunito=Font.fromEnum(Enum.Font.Nunito).Family
    fonts={body=Font.new(nunito,Enum.FontWeight.SemiBold),medium=Font.new(nunito,Enum.FontWeight.Bold),
        bold=Font.fromEnum(Enum.Font.FredokaOne)}
end)
if not fontsOk then
    fonts={body=Font.fromEnum(Enum.Font.BuilderSans),medium=Font.fromEnum(Enum.Font.BuilderSansMedium),
        bold=Font.fromEnum(Enum.Font.BuilderSansBold)}
end
local function round(el,radius)
    local corner=Instance.new("UICorner") corner.CornerRadius=UDim.new(0,radius or 10) corner.Parent=el
end
local function outline(el,color,width)
    local stroke=Instance.new("UIStroke") stroke.Color=color or palette.border stroke.Thickness=width or 1 stroke.Parent=el
    stroke.ApplyStrokeMode=Enum.ApplyStrokeMode.Border
    return stroke
end
-- Dashboard cards: filled, borderless, 18-22px corners, 14-18px padding.
local function card(el,color,radius,padding)
    el.BackgroundTransparency=0 el.BackgroundColor3=color or palette.surface el.BorderSizePixel=0
    round(el,radius or 22)
    local inset=Instance.new("UIPadding") inset.Name="CardPadding"
    for _,side in {"PaddingTop","PaddingBottom","PaddingLeft","PaddingRight"} do inset[side]=UDim.new(0,padding or 16) end
    inset.Parent=el
    return el
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
    el.FontFace=kind=="heading" and fonts.bold or fonts.body
    el.TextSize=kind=="heading" and 24 or (kind=="small" and 14 or 16)
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
    el.AutomaticSize=Enum.AutomaticSize.Y
    el.BackgroundColor3=options.primary and palette.blue or palette.surface
    el.BorderSizePixel=0 el.FontFace=fonts.medium el.TextSize=15
    el.TextColor3=options.primary and palette.onAccent or palette.text
    el.TextWrapped=true el.Text=label el.Parent=parent
    -- Pills, as on the dashboard; the soft edge stands in for its 0 2px 0 #e4d4b4 shadow.
    round(el,options.primary and 23 or 18)
    if not options.primary then outline(el,palette.edge) end
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
local fieldShells={}
local function field(parent,placeholder,height)
    local shell=Instance.new("Frame") shell.Name="InputFrame"
    shell.Size=UDim2.new(1,-4,0,height or 88) shell.BackgroundColor3=palette.field
    shell.BorderSizePixel=0 shell.Parent=parent round(shell,14)
    local stroke=outline(shell)
    local el=Instance.new("TextBox")
    el.Size=UDim2.fromScale(1,1) el.BackgroundTransparency=1 el.BorderSizePixel=0
    el.TextColor3=palette.text el.PlaceholderColor3=palette.secondary el.FontFace=fonts.body
    el.TextStrokeTransparency=1 el.RichText=false
    el.TextSize=16 el.TextXAlignment=Enum.TextXAlignment.Left el.TextYAlignment=Enum.TextYAlignment.Top
    el.TextWrapped=true el.MultiLine=true el.ClearTextOnFocus=false el.Text="" el.PlaceholderText=placeholder el.Parent=shell
    local padding=Instance.new("UIPadding") padding.PaddingLeft=UDim.new(0,8) padding.PaddingRight=UDim.new(0,8)
    padding.PaddingTop=UDim.new(0,8) padding.PaddingBottom=UDim.new(0,8) padding.Parent=el
    el.Focused:Connect(function() stroke.Color=palette.peach stroke.Thickness=2 end)
    el.FocusLost:Connect(function() stroke.Color=palette.border stroke.Thickness=1 end)
    fieldShells[el]=shell
    return el
end
local function setFieldHeight(el,height)
    fieldShells[el].Size=UDim2.new(1,-4,0,height)
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
brandMark.BackgroundColor3=palette.peach brandMark.BorderSizePixel=0 brandMark.Parent=header round(brandMark,10)
local brandLetter=text(brandMark,"M") brandLetter.AutomaticSize=Enum.AutomaticSize.None
brandLetter.Size=UDim2.fromScale(1,1) brandLetter.TextXAlignment=Enum.TextXAlignment.Center
brandLetter.TextYAlignment=Enum.TextYAlignment.Center brandLetter.FontFace=fonts.bold brandLetter.TextSize=22 brandLetter.TextColor3=palette.onAccent
local brandTitle=text(header,"MuMake","heading") brandTitle.Position=UDim2.fromOffset(42,2)
brandTitle.Size=UDim2.new(1,-176,0,30) brandTitle.TextSize=26
local status=text(header,"Connecting to your game…","small") status.Position=UDim2.fromOffset(0,42)
local guideLink=button(header,"Guide",function() show("Guide") end)
guideLink.Position=UDim2.new(1,-116,0,0) guideLink.Size=UDim2.fromOffset(50,32) guideLink.TextSize=13
local settingsLink=button(header,"Settings",function() show("Settings") end)
settingsLink.Position=UDim2.new(1,-60,0,0) settingsLink.Size=UDim2.fromOffset(60,32) settingsLink.TextSize=13
local wayfinding=Instance.new("Frame") wayfinding.Name="Wayfinding" wayfinding.BackgroundTransparency=1 wayfinding.Position=UDim2.fromOffset(20,84)
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
local nav=Instance.new("Frame") nav.Name="Navigation" nav.BackgroundTransparency=1 nav.Position=UDim2.fromOffset(20,124)
nav.Size=UDim2.new(1,-40,0,36) nav.Parent=root
local body=Instance.new("ScrollingFrame") body.Name="Content" body.BackgroundTransparency=1 body.BorderSizePixel=0
body.Position=UDim2.fromOffset(16,176) body.Size=UDim2.new(1,-28,1,-236)
body.ScrollBarThickness=3 body.ScrollBarImageColor3=palette.border body.AutomaticCanvasSize=Enum.AutomaticSize.Y
body.ScrollingDirection=Enum.ScrollingDirection.Y
-- Keep card outlines inside the clipping area while preserving the content's alignment.
local contentPadding=Instance.new("UIPadding")
contentPadding.PaddingLeft=UDim.new(0,4) contentPadding.PaddingRight=UDim.new(0,4)
contentPadding.PaddingTop=UDim.new(0,4) contentPadding.PaddingBottom=UDim.new(0,4) contentPadding.Parent=body
body.CanvasSize=UDim2.new() body.Parent=root stack(body,20)
local footer=section(root,"Footer") footer.Position=UDim2.new(0,20,1,-48) footer.Size=UDim2.new(1,-40,0,0)
feedback=text(footer,"Start with an idea for your game.","small")
feedback.Size=UDim2.new(1,-4,0,0)
local stopButton=button(footer,"Stop MuMake",function()
    request("POST","/cancel",{}) say("Stopping MuMake…")
end)
stopButton.BackgroundColor3=palette.peach
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
    end
    if makeActionBar then makeActionBar.Visible=tab=="Make game" and not active end
    footer.Visible=(not special and tab~="Make game") or active stopButton.Visible=active
    Layout.apply(root,{header=header,status=status,wayfinding=wayfinding,nav=nav,body=body,
        layoutLabel=layoutLabel,back=backButton,controls=controlsToggle,footer=footer,
        welcomeActions=welcomeActions,makeAction=makeActionBar})
end
show=function(name,replace)
    if not pages[name] then return end
    if replace then experience.route=name else Experience.navigate(experience,name) end
    tab=name
    for key,page in pages do page.Visible=key==name end
    for key,b in navButtons do
        b.BackgroundColor3=key==name and palette.tint or palette.surface
        b.TextColor3=key==name and palette.text or palette.secondary
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
welcomeArt.Size=UDim2.new(1,-4,0,72) welcomeArt.BorderSizePixel=0 welcomeArt.Parent=welcome round(welcomeArt,22)
for index=1,5 do
    local tile=Instance.new("Frame") tile.Name="BuildingBlock" tile.Size=UDim2.fromOffset(42,24)
    tile.Position=UDim2.new(.12+(index-1)*.15,-8,0,48-(index-1)*8)
    tile.Rotation=-12 tile.BorderSizePixel=0
    tile.BackgroundColor3=({palette.peach,palette.butter,palette.blue,palette.sky,palette.peach})[index]
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
    row:FindFirstChildOfClass("UICorner").CornerRadius=UDim.new(0,18)
    local heading=text(row,title) heading.FontFace=fonts.medium heading.Position=UDim2.fromOffset(16,12)
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
        row.row.BackgroundColor3=chosen and palette.selected or palette.surface
        row.stroke.Color=chosen and palette.peach or palette.edge row.stroke.Thickness=chosen and 2 or 1
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
pathText.TextColor3=palette.accentText
local idea=field(makePage,"Example: an obby where players collect coins and avoid rising lava.",136)
local starters=section(makePage,"IdeaStarters")
text(starters,"Pick a starting point, or write your own.","small")
for _,example in {"An obby with coins and checkpoints","A race through a disappearing maze","A tiny island with a treasure hunt"} do
    button(starters,example,function()
        idea.Text=example idea:CaptureFocus()
        idea.CursorPosition=#idea.Text+1 idea.SelectionStart=-1
    end)
end
local extraBuild=card(section(makePage,"DraftControls"))
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
text(makePage,"Creating a game uses paid AI calls. MuMake adds it to this Studio window, so use an empty local game.","small")
local savedLibrary=card(section(makePage,"SavedGames")) savedLibrary.LayoutOrder=80
text(savedLibrary,"Your saved games","heading")
text(savedLibrary,"Reopen a draft made here or with the agent tool. Opening it does not change Studio or use AI.","small")
local savedGameRows=section(savedLibrary,"Games")
local checkPage=pages["Check game"]
local checkTitle=text(checkPage,"Will it work for your friends?","heading")
local checkIntro=text(checkPage,"Let MuMake try your game, then see what happened.","muted")
local preparation=card(section(checkPage,"Preparation"),palette.tint,18)
text(preparation,"First, prepare this game")
text(preparation,"Add small helper scripts so MuMake can play and spot problems. You can undo this in Studio.","muted")
button(preparation,"Prepare this game",function() start("install_harness") end,{action=true})
local choose=Instance.new("Frame") choose.BackgroundTransparency=1 choose.Size=UDim2.new(1,-4,0,36) choose.Parent=checkPage
local modePanel=section(checkPage,"Plan")
local quick=card(section(modePanel,"Quick"))
text(quick,"What we’ll try","heading")
text(quick,"1. Join your game\n2. Walk to a new spot\n3. Look for game errors")
text(quick,"A built-in check. No AI calls needed.","small")
local goalPanel=card(section(modePanel,"Goal")) goalPanel.Visible=false
text(goalPanel,"What should a player be able to do?","heading")
local goal=field(goalPanel,"Example: pick up a hose and put out a fire.",96)
text(goalPanel,"MuMake will join, choose actions to try your goal, and check what actually happened.","muted")
local aiAccess=text(goalPanel,"Checking whether AI play is ready…","small")
local checkOptions=section(checkPage,"CheckOptions") checkOptions.Visible=false
text(checkOptions,"How long should MuMake try?","small")
local budgetLabel=text(checkOptions,"Up to 8 moves, then a review. Each AI move uses a paid call.","small")
local budgetButtons={}
local function setStepBudget(value)
    if value~=4 and value~=8 and value~=16 then return false end
    stepBudget=value budgetLabel.Text="Up to "..value.." moves, then a review. Each AI move uses a paid call."
    for amount,entry in budgetButtons do entry.BackgroundColor3=amount==value and palette.tint or palette.surface end
    return true
end
local budgetRow=Instance.new("Frame") budgetRow.BackgroundTransparency=1 budgetRow.Size=UDim2.new(1,-4,0,36) budgetRow.Parent=checkOptions
for index,value in {4,8,16} do
    local b=button(budgetRow,tostring(value).." moves",function()
        setStepBudget(value)
    end)
    b.Size=UDim2.new(1/3,-4,1,0) b.Position=UDim2.new((index-1)/3,0,0,0) budgetButtons[value]=b
end
budgetButtons[8].BackgroundColor3=palette.tint
local go
local function setMode(value)
    mode=value quick.Visible=value=="quick" goalPanel.Visible=value=="goal"
    for key,b in modeButtons do
        b.BackgroundColor3=key==value and palette.tint or palette.surface
        b.TextColor3=key==value and palette.text or palette.secondary
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
        start("playtest",{goal=goal.Text,steps=stepBudget})
    end
end,{primary=true})
text(checkPage,"MuMake plays with one character in this window, then stops. It does not change your game code.","small")
local explanation=card(section(checkPage,"HowItWorks")) explanation.Visible=false
button(checkPage,"How does this work?",function() explanation.Visible=not explanation.Visible end)
-- Keep the explanation below its toggle in layout order.
explanation.LayoutOrder=100
text(explanation,"You give the goal. MuMake tries it. You see the evidence.","heading")
text(explanation,"Quick check follows a ready-made checklist. Try a goal uses AI to pick a move, look at what changed, and pick the next move. A second AI reviews the playthrough.","muted")
text(explanation,"Trying the same goal again gives another playthrough. It is not a newly generated, fixed test script.","small")
local results=pages.Results
text(results,"What happened?","heading")
local resultSummary=card(section(results,"Summary"))
local resultTitle=text(resultSummary,"Your first draft starts with an idea.")
local resultStatus=text(resultSummary,"Make a game first, or check the game you already have. Your drafts and playthroughs will appear here.","muted")
local resultDetail=text(resultSummary,"","muted")
-- Live build view: built once and updated in place on every poll so it never flickers.
-- Styled as the dashboard's progress card: big %, step, peach-to-butter bar, dashed rule, ✓/✗ feed.
local buildProgress=section(results,"BuildProgress") buildProgress.Visible=false
card(buildProgress,palette.tint,18,16)
buildProgress:FindFirstChildOfClass("UIListLayout").Padding=UDim.new(0,6)
local barPercent=text(buildProgress,"0%") barPercent.LayoutOrder=1 barPercent.RichText=true
barPercent.FontFace=fonts.bold barPercent.TextSize=52 barPercent.TextColor3=palette.text
local progressStep=text(buildProgress,"") progressStep.FontFace=fonts.medium progressStep.TextSize=17 progressStep.LayoutOrder=2
local progressItems=text(buildProgress,"","small") progressItems.LayoutOrder=3
local progressEta=text(buildProgress,"","small") progressEta.LayoutOrder=4
local barRow=Instance.new("Frame") barRow.Name="Bar" barRow.BackgroundTransparency=1 barRow.LayoutOrder=5
barRow.Size=UDim2.new(1,-4,0,26) barRow.Parent=buildProgress
local barTrack=Instance.new("Frame") barTrack.Name="Track" barTrack.BackgroundColor3=palette.surface barTrack.BorderSizePixel=0
barTrack.AnchorPoint=Vector2.new(0,0.5) barTrack.Position=UDim2.fromScale(0,0.5) barTrack.Size=UDim2.new(1,0,0,14)
barTrack.ClipsDescendants=true barTrack.Parent=barRow round(barTrack,7) outline(barTrack,palette.border)
local barFill=Instance.new("Frame") barFill.Name="Fill" barFill.BackgroundColor3=Color3.new(1,1,1) barFill.BorderSizePixel=0
barFill.Size=UDim2.fromScale(0,1) barFill.Parent=barTrack round(barFill,7)
local barGradient=Instance.new("UIGradient") barGradient.Color=ColorSequence.new(palette.peach,palette.butter) barGradient.Parent=barFill
local divider=Instance.new("Frame") divider.Name="Dashes" divider.BackgroundTransparency=1 divider.LayoutOrder=6
divider.Size=UDim2.new(1,-4,0,2) divider.ClipsDescendants=true divider.Parent=buildProgress
local dashes=Instance.new("UIListLayout") dashes.FillDirection=Enum.FillDirection.Horizontal dashes.Padding=UDim.new(0,4) dashes.Parent=divider
for _=1,90 do
    local dash=Instance.new("Frame") dash.BackgroundColor3=palette.dash dash.BorderSizePixel=0
    dash.Size=UDim2.fromOffset(6,2) dash.Parent=divider
end
local happenedTitle=text(buildProgress,"What happened so far","small") happenedTitle.FontFace=fonts.medium happenedTitle.LayoutOrder=7
local happenedRows={}
for index=1,6 do
    local row=text(buildProgress,"","muted") row.LayoutOrder=7+index row.Visible=false row.RichText=true
    row.FontFace=fonts.medium row.TextSize=14 happenedRows[index]=row
end
local checkRows=section(results,"CheckedThings")
local issueRows=section(results,"PossibleProblems")
local reportActions=section(results,"NextSteps")
local draftEditor=card(section(results,"DraftChanges")) draftEditor.Visible=false
text(draftEditor,"What should be different?","heading")
text(draftEditor,"Change one chosen script in a separate saved revision. Your current draft and Studio stay as they are until you add the revision.","small")
local draftScript=text(draftEditor,"Choose a game script","small")
local scriptChoices=section(draftEditor,"ScriptChoices") scriptChoices.Visible=false
button(draftEditor,"Choose a different script",function() scriptChoices.Visible=not scriptChoices.Visible end)
local changeNote=field(draftEditor,"Example: make the coins easier to spot and give players a checkpoint.",88)
button(draftEditor,"Make this change in a new draft",function()
    if not changeNote.Text:match("%S") then error("Tell MuMake what should change first.",0) end
    start("correct_game",{source_job=selectedDraftJob,path=selectedDraftPath,note=changeNote.Text})
end,{action=true,ai=true,primary=true})
button(draftEditor,"Read this script",function()
    start("read_game_file",{source_job=selectedDraftJob,path=selectedDraftPath})
end,{action=true})
local actionRows=section(results,"PlaythroughActions")
local correction=card(section(results,"Feedback")) correction.Visible=false
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
    correction.Visible=false technical.Visible=false draftEditor.Visible=false
    resultTitle.Text=job.operation=="playtest" and job.args.goal or (draftOperations[job.operation] and "Opening your next draft" or "Your next step")
    resultStatus.Text="Getting ready…" resultStatus.TextColor3=palette.accentText
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
button(advanced,"Ask AI to look for problems",function() start("explore",{steps=stepBudget}) end,{action=true,ai=true,needsReady=true})
local selectedCheck=text(advanced,"Selected: Quick check","small")
button(advanced,"Run selected check",function() start("scenario",{scenario=selectedScenario}) end,{action=true,needsReady=true})
local controlDock=card(section(makePage,"WorkspaceTools"))
controlDock.LayoutOrder=90
text(controlDock,"Tools at hand","heading")
button(controlDock,"See my drafts and results",function() show("Results") end)
button(controlDock,"Check the character and game errors",function() show("Check game") end)
button(controlDock,"Look for problems with AI",function() start("explore",{steps=stepBudget}) end,{action=true,ai=true,needsReady=true})
applyExperience=function()
    local config=Experience.config(experience)
    brandMark.BackgroundColor3=palette.peach
    welcomeArt.BackgroundColor3=palette.tint
    welcomeContinue.BackgroundColor3=palette.blue guideTry.BackgroundColor3=palette.blue
    layoutLabel.Text=experience.level=="guided" and "Guided workspace" or (experience.level=="balanced" and "Your workspace" or "Creator workspace")
    controlsToggle.Text=config.controls and "Fewer controls" or "More controls"
    makeTitle.Text=config.focused and "Build your next game." or (config.playful and "Let’s make something fun." or "What do you want to make?")
    makeIntro.Text=config.stepByStep and "Start with one idea. We’ll turn it into a draft you can try and improve." or "Describe the game. Review the draft. Try it in Studio."
    makeIntro.Visible=config.hints
    makePath.Visible=config.stepByStep or config.playful
    pathText.Text=config.playful and "Your idea    /    Make it real    /    Play & improve" or "Your idea    /    First draft    /    Try it in Studio"
    pathText.TextColor3=palette.accentText
    setFieldHeight(idea,config.playful and 148 or (config.focused and 112 or 136))
    starters.Visible=config.hints
    extraBuild.Visible=config.controls controlDock.Visible=config.controls
    checkOptions.Visible=config.controls
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
    {title="Make a draft you can change",body="Make my game uses AI to plan and write your first version. It takes paid AI calls. MuMake adds it to this Studio window, plays it and improves it for up to 3 rounds, then tells you when it is ready.",action="See the creation tools",route="Make game"},
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
    local ok,result=pcall(function()
        local session=request("POST","/bind",{marker=marker})
        local state=request("GET","/state")
        if state.protocol~=2 then error("Update and restart the local MuMake helper, then reconnect.",0) end
        return session
    end)
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
local function updateButton(el,enabled,primary,fill)
    el.Active=enabled el.AutoButtonColor=enabled
    el.TextColor3=enabled and (primary and palette.onAccent or palette.text) or palette.secondary
    el.BackgroundColor3=enabled and (fill or (primary and palette.blue)) or palette.surface
end
local function eligibleAI()
    return bound and snapshot and snapshot.has_mubit_key and not snapshot.busy
end
local function showTechnical(value)
    technical.Visible=true details.Text=readable(value)
    local size=game:GetService("TextService"):GetTextSize(details.Text,16,Enum.Font.Nunito,Vector2.new(math.max(220,details.AbsoluteSize.X-20),100000))
    setFieldHeight(details,math.clamp(size.Y+24,160,16000))
end
displayReport=function(job)
    local view=job.presentation
    if not view then return end
    selectedJob=job.id
    resultTitle.Text=view.title resultStatus.Text=view.status resultDetail.Text=view.summary
    if job.state=="passed" then resultStatus.TextColor3=palette.green
    elseif job.state=="failed" then resultStatus.TextColor3=palette.amber else resultStatus.TextColor3=palette.secondary end
    clear(checkRows) clear(issueRows) clear(reportActions) clear(actionRows)
    correction.Visible=false technical.Visible=false draftEditor.Visible=false
    if draftOperations[job.operation] and job.result then
        selectedDraftJob=job.id selectedDraftPath=job.result.files and job.result.files[1]
        draftEditor.Visible=selectedDraftPath~=nil
        clear(scriptChoices) scriptChoices.Visible=false
        draftScript.Text="Game script: "..tostring(selectedDraftPath or "none yet")
        for _,path in job.result.files or {} do
            button(scriptChoices,path,function()
                selectedDraftPath=path draftScript.Text="Game script: "..path scriptChoices.Visible=false
            end)
        end
        if #(job.result.files or {})>0 then
            text(checkRows,"What your draft aims to do","heading")
            for _,item in job.result.acceptance or {} do text(checkRows,tostring(item)) end
            local standard=type(job.result.standard)=="table" and job.result.standard or nil
            text(checkRows,tostring(#job.result.files).." game scripts written. "..(standard and "Played and reviewed by MuMake ("..tostring(standard.rounds or 0).." improvement rounds)." or "Not played yet."),"small")
        end
        if job.result.in_studio then
            text(reportActions,job.result.studio_current and "This game is in this Studio window now. Press Play to try it." or "An earlier version is in this Studio window. The latest one could not be added.","small")
        end
        if job.state=="passed" and job.result.ready and not job.result.studio_current then
            button(reportActions,"Add draft to Studio",function() start("load_game",{source_job=job.id}) end,{primary=true,action=true})
            text(reportActions,"Adds the draft scripts to this local game with Undo. If a script would replace your own code, MuMake stops and asks you to use an empty game.","small")
        end
        if job.result.slug then
            button(reportActions,"Check and improve this saved draft",function()
                start("iterate_game",{source_job=job.id})
            end,{action=true,ai=true})
            text(reportActions,"Runs another code review and repair round in a new draft. Uses paid AI calls. It does not play the game.","small")
            button(reportActions,"See draft reviews and AI activity",function()
                showTechnical({reviews=job.result.iterations,calls=job.result.calls})
            end)
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
    if job.operation=="read_game_file" and job.result then showTechnical(job.result) end
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
local historyKey,choicesKey,gamesKey="","",""
local shownBuild,shownPercent=nil,-1
local function renderBuild(job)
    local live=job~=nil and job.operation=="make_game" and selectedJob==job.id
    buildProgress.Visible=live
    if not live then return end
    local progress=type(job.progress)=="table" and job.progress or {}
    if job.id~=shownBuild then
        shownBuild,shownPercent=job.id,-1 barFill.Size=UDim2.fromScale(0,1)
    end
    barRow.Visible=type(progress.pct)=="number" barPercent.Visible=barRow.Visible
    if barRow.Visible then
        -- Show the companion's pct exactly as sent: it is the number the dashboard shows.
        local percent=progress.pct
        if percent~=shownPercent then
            shownPercent=percent
            barPercent.Text=tostring(percent)..'<font size="26" color="#8A7766">%</font>'
            game:GetService("TweenService"):Create(barFill,TweenInfo.new(0.6,Enum.EasingStyle.Quad),{Size=UDim2.fromScale(math.clamp(percent/100,0,1),1)}):Play()
        end
    end
    local finished=progress.phase=="done" or progress.phase=="failed" or progress.stalled==true
    buildProgress.BackgroundColor3=finished and palette.field or palette.tint
    barGradient.Enabled=not finished
    barFill.BackgroundColor3=progress.phase=="done" and palette.blue or (progress.phase=="failed" and palette.red or hex("C9BBA3"))
    progressStep.Text=type(progress.step)=="string" and progress.step or ""
    progressStep.Visible=progressStep.Text~=""
    local items=progress.items
    progressItems.Visible=type(items)=="table" and type(items.done)=="number" and type(items.total)=="number" and items.total>0
    if progressItems.Visible then progressItems.Text=items.done.." of "..items.total.." "..tostring(items.label or "parts").." done" end
    local eta=progress.eta_s
    progressEta.Visible=type(eta)=="number" and eta>0
    if progressEta.Visible then progressEta.Text=eta<60 and "Less than a minute left" or "About "..math.ceil(eta/60).." min left" end
    local events=job.events or {}
    happenedTitle.Visible=#events>0
    for index,row in happenedRows do
        local event=events[#events-index+1]
        row.Visible=event~=nil
        if event then
            local message=tostring(event.message):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;")
            local mark=event.ok==false and "✗" or (event.ok==true and '<font color="#5F9E4A">✓</font>' or "·")
            row.Text=mark.."  "..message
            row.TextColor3=event.ok==false and palette.red or (index==1 and palette.text or palette.secondary)
            row.TextTransparency=(index-1)*0.12
        end
    end
end
render=function(data)
    snapshot=data
    layoutSurface()
    local ready=data.session and data.session.harness_ready
    preparation.Visible=bound and not ready
    control:SetAttribute("Busy",data.busy)
    control:SetAttribute("Connected",bound)
    local aiReady=bound and data.has_mubit_key
    buildAccess.Text=aiReady and "Ready to make your first draft. This can take a few minutes." or "Game creation needs AI connected in Settings. Your idea can stay here while you set it up."
    aiAccess.Text=aiReady and "AI play is ready. This uses paid AI calls, with up to "..stepBudget.." moves and a review." or "AI play is not connected yet. Quick check is available; open Settings for AI setup."
    aiSetting.Text=aiReady and "Connected. Game creation, goal play and feedback are available." or "Not connected yet. Add a Mubit key in Technical setup details to create games or use AI play."
    local canGo=bound and ready and not data.busy and (mode=="quick" or aiReady)
    updateButton(go,canGo,true)
    if not bound then goReason.Text="Open Settings to connect MuMake."
    elseif not ready then goReason.Text="Prepare this game above, then you can check it."
    elseif data.busy then goReason.Text="A check is already running. You can stop it below."
    elseif mode=="goal" and not aiReady then goReason.Text="AI play needs setup. Switch to Quick check to begin now."
    else goReason.Text=mode=="quick" and "Ready. Let’s try the basics." or "Ready. MuMake will try the goal you wrote." end
    updateButton(stopButton,data.active~=nil,false,palette.peach)
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
        local progress=active.operation=="make_game" and type(active.progress)=="table" and active.progress or nil
        if progress and active.state~="cancelling" and type(progress.pct)=="number" and type(progress.step)=="string" then
            message=tostring(progress.pct).."% · "..progress.step
        end
        say(message)
        if selectedJob==active.id then
            resultTitle.Text=(active.presentation or {}).title or "Checking your game"
            resultStatus.Text=active.state=="cancelling" and "Stopping…" or (active.operation=="make_game" and "Making your game…" or "Working on your game…")
            resultStatus.TextColor3=palette.accentText
            resultDetail.Text=active.operation=="make_game" and active.state~="cancelling" and "This takes a few minutes. You can press Stop at any time." or message
        end
        renderBuild(active)
    else
        renderBuild(nil)
    end
    if not active and data.history[1] then
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
    local games=Http:JSONEncode(data.games or {})
    if games~=gamesKey then
        gamesKey=games clear(savedGameRows)
        if #(data.games or {})==0 then text(savedGameRows,"Your saved drafts will appear here.","small") end
        for _,saved in data.games or {} do
            button(savedGameRows,saved.title,function() start("open_game",{slug=saved.slug}) end,{action=true})
        end
    end
end
modeButtons.quick.BackgroundColor3=palette.tint
modeButtons.quick.TextColor3=palette.text
if transferred then
    local fields=transferred.fields or {}
    for key,el in {idea=idea,mustHave=mustHave,avoid=avoid,goal=goal,correctionNote=correctionNote,changeNote=changeNote} do
        if type(fields[key])=="string" then el.Text=fields[key] end
    end
    selectedJob=transferred.selectedJob
    submittedActions=transferred.submittedActions or 0
    setStepBudget(transferred.stepBudget or 8)
    setMode(transferred.mode=="goal" and "goal" or "quick")
end
refreshWelcome() refreshGuide() applyExperience()
show(experience.route,true)
if transferred and typeof(transferred.scroll)=="Vector2" then body.CanvasPosition=transferred.scroll end
for _,el in {root,status,footer,welcomeActions} do
    table.insert(connections,el:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutSurface))
end
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
-- A direct local handoff preserves drafts during plugin updates. Preferences never
-- leave Studio or enter the companion's HTTP requests.
local export=Instance.new("BindableFunction") export.Name="ExportState"
export.OnInvoke=function()
    return {version=1,experience=experience,selectedJob=selectedJob,mode=mode,stepBudget=stepBudget,
        scroll=body.CanvasPosition,submittedActions=submittedActions,
        fields={idea=idea.Text,mustHave=mustHave.Text,avoid=avoid.Text,goal=goal.Text,
            correctionNote=correctionNote.Text,changeNote=changeNote.Text}}
end
export.Parent=control
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
            draft_chars=#idea.Text,guide_title=guideTitle.Text,step_budget=stepBudget,
            library_count=#(snapshot and snapshot.games or {})}
    end
    if operation=="onboard_choose" then return selectPreference(args.kind,args.value) end
    if operation=="onboard_next" then continueWelcome() return true end
    if operation=="onboard_skip" then Experience.skip(experience) applyExperience() show("Make game",true) return true end
    if operation=="open_layout" then Experience.reopen(experience) show("Welcome",true) return true end
    if operation=="back" then goBack() return true end
    if operation=="guide_step" then experience.guideStep=math.clamp(tonumber(args.step) or 1,1,4) refreshGuide() return true end
    if operation=="set_draft" then idea.Text=tostring(args.text or "") return true end
    if operation=="toggle_controls" then experience.moreControls=not experience.moreControls applyExperience() return true end
    if operation=="set_budget" then return setStepBudget(args.value) end
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
                    item.size=el.TextSize item.font=el.FontFace.Family:match("([^/]+)%.json$") or el.Font.Name item.color={el.TextColor3.R,el.TextColor3.G,el.TextColor3.B}
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
