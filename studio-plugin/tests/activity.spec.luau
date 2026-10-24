local A=require("../Activity")
local function equal(a,b,message) assert(a==b,message or (tostring(a).." ~= "..tostring(b))) end
-- Ages are short and never negative.
equal(A.age(0),"now") equal(A.age(4.9),"now") equal(A.age(-3),"now") equal(A.age(nil),"now")
equal(A.age(12),"12s") equal(A.age(59),"59s") equal(A.age(60),"1m") equal(A.age(3599),"59m")
equal(A.age(3600),"1h") equal(A.age(86399),"23h") equal(A.age(86400*3),"3d")
-- Clipping counts characters and never splits one.
equal(A.clip("abc",5),"abc")
equal(A.clip("abcdef",3),"abc…")
equal(A.clip("ééééé",2),"éé…")
assert(utf8.len(A.clip(string.rep("●",200),10))==11,"clip keeps whole multi-byte characters")
equal(A.clip(nil,4),"")
equal(A.clip("a\255b",5),"a?b","invalid UTF-8 is made printable instead of failing")
-- One event, one line: status mark and text on the left, the age in its own right-hand column so
-- truncating a long action at the default 320 px dock width never hides it.
equal(A.line({status="ok",text="coder wrote ServerScriptService/X.luau",age_s=12}),
    "· coder wrote ServerScriptService/X.luau")
equal(A.line({status="fail",text="playtest round 2: 3 errors",age_s=200}),"! playtest round 2: 3 errors")
equal(A.line({status="running",text="coder: Shop.luau",age_s=1}),"● coder: Shop.luau")
equal(A.line({status="weird",text="x",age_s=7}),"· x")
assert(utf8.len(A.line({status="ok",text=string.rep("a",300),age_s=0}))<A.maxText+4,"long text is clipped")
-- Status colours: known statuses get one, info and unknown use the theme text.
equal(A.color("ok")[1],46) equal(A.color("fail")[1],215) equal(A.color("running")[3],204)
equal(A.color("info"),nil) equal(A.color(nil),nil)
-- Run header: the slug on the left (clipped), status and age in the right-hand column.
equal(A.header({slug="obby-3",title="Funfair Frenzy",status="running",age_s=30}),"obby-3")
equal(A.header({slug="funfair-frenzy-an-amusement-park-obby-3-and-then-some-more-words",age_s=7200}),
    "funfair-frenzy-an-amusement-park-obby-3-and-then…")
equal(A.headerAside({status="running",age_s=30}),"running · 30s")
equal(A.headerAside({age_s=7200}),"idle · 2h")
local run={slug="obby-3"}
equal(A.detail(run,{text="coder wrote X.luau",age_s=5,detail="took 4.0s\nrequest mreq_1",request_id="mreq_1"}),
    "[obby-3] coder wrote X.luau (5s ago)\ntook 4.0s\nrequest mreq_1")
equal(A.detail(run,{text="autopilot round 1: kept",age_s=0,request_id="mreq_2"}),
    "[obby-3] autopilot round 1: kept (just now)\nrequest mreq_2")
-- Rows: header per run, then its events; empty and missing feeds say so.
local rows=A.rows({runs={
    {slug="a",status="running",age_s=1,events={{status="ok",text="coder wrote A.luau",age_s=1},
        {status="fail",text="playtest round 1: 2 errors",age_s=9}}},
    {slug="b",status="idle",age_s=900,events={}},
}})
equal(#rows,5)
equal(rows[1].kind,"run") equal(rows[1].status,"running")
equal(rows[1].text,"a") equal(rows[1].aside,"running · now")
equal(rows[2].kind,"event") equal(rows[2].event.text,"coder wrote A.luau") equal(rows[3].status,"fail")
equal(rows[2].text,"· coder wrote A.luau") equal(rows[2].aside,"now") equal(rows[3].aside,"9s")
equal(rows[4].kind,"run") equal(rows[4].status,nil,"an idle run header uses the dimmed theme colour")
equal(rows[4].aside,"idle · 15m")
equal(rows[5].kind,"note") equal(rows[5].aside,nil)
equal(A.rows({runs={}})[1].text,"no Forge runs yet")
equal(A.rows(nil)[1].kind,"note")
print("ForgeBridge Runs panel: all checks passed")
