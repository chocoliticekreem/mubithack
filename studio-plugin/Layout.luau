-- Adapt to the actual dock size. Never scale down text or resize Studio's dock.
local Layout = {defaultWidth=440,minWidth=320,maxContentWidth=560}

function Layout.measure(width,height,state)
    local gutter=width<380 and 12 or 20
    local column=math.max(0,math.min(Layout.maxContentWidth,width-gutter*2))
    local left=math.floor((width-column)/2)
    local headerTop=height<600 and 12 or 16
    local headerHeight=math.max(60,42+(state.statusHeight or 14))
    local wayTop=headerTop+headerHeight+12
    local navTop=state.wayfinding and wayTop+40 or headerTop+headerHeight+12
    local bodyTop=state.nav and navTop+52 or navTop
    local bottom=16
    local footerBottom=height-16
    local actionBottom=footerBottom
    if state.footer then bottom=(state.footerHeight or 0)+32 end
    if state.welcomeActions then
        if state.footer then actionBottom=footerBottom-(state.footerHeight or 0)-16 end
        bottom=height-actionBottom+(state.welcomeHeight or 0)+16
    elseif state.makeAction then
        bottom=(state.makeHeight or 0)+32
    end
    return {left=left,width=column,compact=width<380,headerTop=headerTop,headerHeight=headerHeight,
        wayTop=wayTop,navTop=navTop,bodyTop=bodyTop,bodyHeight=math.max(0,height-bodyTop-bottom),
        footerBottom=footerBottom,actionBottom=actionBottom}
end

function Layout.apply(root,parts)
    local view=Layout.measure(root.AbsoluteSize.X,root.AbsoluteSize.Y,{
        statusHeight=parts.status.AbsoluteSize.Y,wayfinding=parts.wayfinding.Visible,nav=parts.nav.Visible,
        footer=parts.footer.Visible,footerHeight=parts.footer.AbsoluteSize.Y,
        welcomeActions=parts.welcomeActions and parts.welcomeActions.Visible,
        welcomeHeight=parts.welcomeActions and parts.welcomeActions.AbsoluteSize.Y,
        makeAction=parts.makeAction and parts.makeAction.Visible,
        makeHeight=parts.makeAction and parts.makeAction.AbsoluteSize.Y,
    })
    local function column(el,y,height)
        el.Position=UDim2.fromOffset(view.left,y)
        el.Size=UDim2.fromOffset(view.width,height)
    end
    column(parts.header,view.headerTop,view.headerHeight)
    column(parts.wayfinding,view.wayTop,28)
    column(parts.nav,view.navTop,36)
    parts.layoutLabel.Visible=not view.compact
    local labelLeft=parts.back.Visible and 68 or 0
    local labelRight=parts.controls.Visible and 128 or 0
    parts.layoutLabel.Position=UDim2.fromOffset(labelLeft,5)
    parts.layoutLabel.Size=UDim2.new(1,-labelLeft-labelRight,0,24)
    parts.body.Position=UDim2.fromOffset(view.left-4,view.bodyTop)
    parts.body.Size=UDim2.fromOffset(view.width+8,view.bodyHeight)
    parts.footer.AnchorPoint=Vector2.new(0,1)
    column(parts.footer,view.footerBottom,0)
    if parts.welcomeActions then
        parts.welcomeActions.AnchorPoint=Vector2.new(0,1)
        column(parts.welcomeActions,view.actionBottom,0)
    end
    if parts.makeAction then
        parts.makeAction.AnchorPoint=Vector2.new(0,1)
        column(parts.makeAction,view.actionBottom,0)
    end
    root:SetAttribute("CompactLayout",view.compact)
end

return Layout
