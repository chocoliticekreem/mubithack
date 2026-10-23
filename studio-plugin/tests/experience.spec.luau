local E=require("../Experience")
local function equal(a,b,message) assert(a==b,message or (tostring(a).." ~= "..tostring(b))) end
local new=E.new(nil)
equal(new.route,"Welcome")
equal(E.new({version=1,audience="adult",level="explore"}).route,"Make game")
equal(E.new({version=1,audience="unknown",level="explore"}).route,"Welcome")
-- Age changes presentation. Experience and the user's toggle control density.
for _,audience in E.audiences do
    for _,level in E.levels do
        local s=E.new(nil)
        assert(E.chooseAudience(s,audience.id))
        assert(E.chooseLevel(s,level.id))
        E.accept(s)
        local config=E.config(s)
        equal(config.controls,level.id=="explore")
        equal(s.route,"Make game")
        local pref=E.preference(s)
        equal(pref.audience,audience.id) equal(pref.level,level.id)
        local count=0 for _ in pref do count+=1 end equal(count,3)
    end
end
local s=E.new(nil)
E.chooseAudience(s,"younger") E.chooseLevel(s,"explore") E.accept(s)
equal(E.config(s).controls,true,"A younger experienced creator keeps full controls")
E.chooseAudience(s,"adult") E.chooseLevel(s,"guided") E.accept(s)
equal(E.config(s).stepByStep,true,"An adult beginner can keep guidance")
s.moreControls=true equal(E.config(s).controls,true)
-- Going back preserves committed preferences and does not submit anything.
E.reopen(s) s.onboardingStep=2 E.back(s)
equal(s.route,"Welcome") equal(s.onboardingStep,1)
E.back(s) equal(s.route,"Make game") equal(s.level,"guided")
E.navigate(s,"Guide") E.navigate(s,"Check game") E.back(s) equal(s.route,"Guide")
E.back(s) equal(s.route,"Make game")
local skipped=E.new(nil) E.skip(skipped)
equal(skipped.route,"Make game") equal(skipped.remember,false)
assert(not E.chooseAudience(skipped,"1999-01-01"))
assert(not E.chooseLevel(skipped,"admin"))
print("MuMake UI preferences: all checks passed")
