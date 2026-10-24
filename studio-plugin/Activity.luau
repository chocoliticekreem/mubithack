-- Pure text and colour rules for the ForgeBridge "Runs" panel (GET /activity on the bridge).
-- No Instances or services here, so tests/activity.spec.luau runs it outside Studio.
local Activity = {maxText=96}

-- RGB per event status; nil means "use the Studio theme's main text colour".
Activity.colors = {
    ok={46,160,67}, fail={215,58,73}, running={0,122,204}, stopped={150,150,150},
}
local MARKS = {ok="·", fail="!", running="●", stopped="○", info="·"}

function Activity.age(seconds)
    local s = math.max(0, math.floor(tonumber(seconds) or 0))
    if s < 5 then return "now" end
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s / 60) .. "m" end
    if s < 86400 then return math.floor(s / 3600) .. "h" end
    return math.floor(s / 86400) .. "d"
end

-- Cut at a character boundary, never inside a multi-byte character.
function Activity.clip(text, n)
    local s = tostring(text or "")
    local ok, len = pcall(utf8.len, s)
    if not ok or len == nil then
        s = string.gsub(s, "[\128-\255]", "?")
        len = #s
    end
    if len <= n then return s end
    return string.sub(s, 1, utf8.offset(s, n + 1) - 1) .. "…"
end

function Activity.color(status)
    return Activity.colors[status]
end

-- Rows put the age (and a run's status) in a separate right-hand column, not at the end of the
-- text, because the plugin truncates the text to fit the dock and would cut them off.
function Activity.line(ev)
    local mark = MARKS[ev.status] or "·"
    return mark .. " " .. Activity.clip(ev.text, Activity.maxText)
end

function Activity.header(run)
    return Activity.clip(run.slug or run.title or "?", 48)
end

function Activity.headerAside(run)
    return (if run.status == "running" then "running" else "idle") .. " · " .. Activity.age(run.age_s)
end

-- A build's progress.json as one line under its run header: "42% Designing zones 3, 4, 5 of 10".
function Activity.progress(p)
    if type(p) ~= "table" then return nil end
    local pct = math.clamp(math.floor(tonumber(p.pct) or 0), 0, 100)
    local step = if p.stalled then "stalled" else tostring(p.step or "")
    return Activity.clip(string.format("%d%% %s", pct, step), Activity.maxText)
end

-- What a click prints to Output.
function Activity.detail(run, ev)
    local age = Activity.age(ev.age_s)
    local out = {string.format("[%s] %s (%s)", tostring(run.slug or "?"), tostring(ev.text or ""),
        if age == "now" then "just now" else age .. " ago")}
    local d = tostring(ev.detail or "")
    if d ~= "" then table.insert(out, d) end
    if ev.request_id and not string.find(d, tostring(ev.request_id), 1, true) then
        table.insert(out, "request " .. tostring(ev.request_id))
    end
    return table.concat(out, "\n")
end

-- The feed's rows in display order: a header per run, then its events.
function Activity.rows(feed)
    local rows = {}
    if type(feed) ~= "table" then
        return {{kind="note", text="runs feed unavailable (bridge offline or too old)"}}
    end
    for _, run in feed.runs or {} do
        table.insert(rows, {kind="run", text=Activity.header(run), aside=Activity.headerAside(run),
            status=if run.status == "running" then "running" else nil, run=run})
        local prog = Activity.progress(run.progress)
        if prog then
            local p = run.progress
            table.insert(rows, {kind="progress", text="  " .. prog, run=run,
                status=if p.phase == "failed" then "fail" elseif p.stalled then "stopped"
                    elseif p.running then "running" else "ok"})
        end
        local events = run.events or {}
        if #events == 0 then
            table.insert(rows, {kind="note", text="  no actions logged yet", run=run})
        end
        for _, ev in events do
            table.insert(rows, {kind="event", text=Activity.line(ev), aside=Activity.age(ev.age_s),
                status=ev.status, run=run, event=ev})
        end
    end
    if #rows == 0 then
        return {{kind="note", text="no Forge runs yet"}}
    end
    return rows
end

return Activity
