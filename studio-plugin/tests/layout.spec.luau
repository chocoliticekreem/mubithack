local Layout=require("../Layout")
-- Resize the same workspace through compact, ordinary and wide docks.
for _,width in {320,379,380,440,560,900} do
    for _,height in {400,600,760} do
        for _,route in {"welcome","welcome-back","guide","make","checks","active","welcome-active"} do
            local welcome=route:find("welcome")~=nil
            local active=route:find("active")~=nil
            local footer=route=="checks" or active
            local view=Layout.measure(width,height,{
                wayfinding=route~="welcome" and route~="welcome-active",
                nav=not welcome and route~="guide",statusHeight=28,
                footer=footer,footerHeight=active and 76 or 28,
                welcomeActions=welcome,welcomeHeight=92,makeAction=route=="make",makeHeight=98,
            })
            assert(view.left>=12 and view.left+view.width<=width-12,"Content must fit inside the dock")
            assert(view.width<=560,"Wide docks must keep a readable content width")
            assert(view.compact==(width<380))
            assert(view.bodyHeight>0,"Every supported size must leave a scrolling viewport")
            local bodyBottom=view.bodyTop+view.bodyHeight
            if welcome then
                assert(bodyBottom<=view.actionBottom-92-16,"Welcome actions must not cover content")
                if footer then assert(view.actionBottom<=view.footerBottom-76-16,"Stop must stay separate from welcome actions") end
            elseif route=="make" then
                assert(bodyBottom<=view.actionBottom-98-16,"Creation actions must stay outside the scroll area")
            elseif footer then
                assert(bodyBottom<=view.footerBottom-(active and 76 or 28)-16,"Results must not cover Stop or feedback")
            end
            assert(view.actionBottom<=height-16,"Pinned actions must fit inside the dock")
        end
    end
end
local short=Layout.measure(320,600,{wayfinding=true,nav=true,statusHeight=14})
local wrapped=Layout.measure(320,600,{wayfinding=true,nav=true,statusHeight=42})
assert(wrapped.bodyTop>short.bodyTop,"A wrapped connection message must move content down")
print("MuMake responsive layout: all checks passed")
