-- Local UI preferences only. This module has no networking, identity or analytics.
local Experience = {}
Experience.audiences = {
    {id="younger",title="13–15",description="A playful place to build your ideas."},
    {id="teen",title="16–17",description="A creative workspace with room to explore."},
    {id="adult",title="18+",description="A focused workspace with a little more detail."},
}
Experience.levels = {
    {id="guided",title="I’m just starting",description="Walk me through it. Keep the real tools close."},
    {id="balanced",title="I’ve made a few things",description="Give me useful tips and space to work."},
    {id="explore",title="I know my way around",description="Show more controls. Keep explanations short."},
}
local function valid(items, id)
    for _,item in items do if item.id==id then return true end end
    return false
end
function Experience.new(saved)
    local hasSaved=type(saved)=="table" and saved.version==1
        and valid(Experience.audiences,saved.audience) and valid(Experience.levels,saved.level)
    local audience=hasSaved and saved.audience or "teen"
    local level=hasSaved and saved.level or "guided"
    return {audience=audience,level=level,pendingAudience=audience,pendingLevel=level,
        route=hasSaved and "Make game" or "Welcome",history={},onboardingStep=1,guideStep=1,
        moreControls=level=="explore",remember=hasSaved,hasSaved=hasSaved}
end
function Experience.navigate(state,route)
    if state.route==route then return end
    table.insert(state.history,state.route)
    state.route=route
end
function Experience.back(state)
    if state.route=="Welcome" and state.onboardingStep==2 then
        state.onboardingStep=1
        return
    end
    local prior=table.remove(state.history)
    if prior then state.route=prior end
end
function Experience.chooseAudience(state,id)
    if not valid(Experience.audiences,id) then return false end
    state.pendingAudience=id
    return true
end
function Experience.chooseLevel(state,id)
    if not valid(Experience.levels,id) then return false end
    state.pendingLevel=id
    return true
end
function Experience.accept(state)
    state.audience=state.pendingAudience
    state.level=state.pendingLevel
    state.moreControls=state.level=="explore"
    Experience.navigate(state,"Make game")
end
function Experience.skip(state)
    state.pendingAudience="teen"
    state.pendingLevel="balanced"
    state.remember=false
    Experience.accept(state)
end
function Experience.reopen(state)
    state.pendingAudience=state.audience
    state.pendingLevel=state.level
    state.onboardingStep=1
    Experience.navigate(state,"Welcome")
end
function Experience.preference(state)
    -- Persist these three fields locally, never a name, birth date or user ID.
    return {version=1,audience=state.audience,level=state.level}
end
function Experience.config(state)
    return {playful=state.audience=="younger",focused=state.audience=="adult",
        hints=state.level~="explore",stepByStep=state.level=="guided",
        controls=state.moreControls,
        rowHeight=state.level=="guided" and 44 or (state.level=="balanced" and 40 or 36)}
end
return Experience
