-- Offline: every testlab scenario parses, and the failure-case scenarios
-- (tools/stereo/generate-testlab-scenarios.py) have the shape they document.
-- arg[1]: mods/darktide_testlab
local base=assert(arg[1])
local Replay=dofile(base..'/scripts/mods/darktide_testlab/trajectory.lua')
local function read(name)
    local file=assert(io.open(base..'/'..name,'r'),name);local text=file:read('*a');file:close();return text
end
local function load(name)
    local text=read(name)
    local keys,why=Replay.parse(text)
    assert(keys,name..': '..tostring(why))
    assert(keys.grip=='touch',name..': must declare # grip=touch')
    assert(text:find('# t left_xyz left_xyzw right_xyz right_xyzw primary block left_grip right_grip special',1,true),name..': column header')
    return keys,text
end
local function x(sample) return sample.right.position[1] end
-- Swing reversals: local extremes of x over a fine resampling, and whether
-- the hand ever stays still at one (a dwell) while the swings run.
local function reversals(keys,from,to)
    local turns,dwell,previous_dx={},0,nil
    local step=.005
    local t=from
    while t+step<=to do
        local dx=x(Replay.sample(keys,t+step))-x(Replay.sample(keys,t))
        if math.abs(dx)<1e-9 then dwell=dwell+step
        elseif previous_dx and (dx>0)~=(previous_dx>0) then turns[#turns+1]=t end
        if math.abs(dx)>=1e-9 then previous_dx=dx end
        t=t+step
    end
    return turns,dwell
end
local function edges(keys,button)
    local out,held={},false
    for _,key in ipairs(keys) do
        if key.buttons[button]~=held then out[#out+1]={t=key.t,down=key.buttons[button]};held=key.buttons[button] end
    end
    return out
end
-- Continuous swings: eight swings, seven reversals, no stillness between them.
for _,case in ipairs({{'touch_continuous.tsv',.35},{'touch_switch_continuous.tsv',.1},{'touch_special_continuous.tsv',.8}}) do
    local keys=load(case[1])
    local start,finish=case[2],case[2]+8*.35
    local turns,dwell=reversals(keys,start,finish)
    assert(#turns==7,case[1]..': reversals '..#turns)
    assert(dwell<.011,case[1]..': the hand rests between swings for '..dwell..' s')
    for i,turn in ipairs(turns) do assert(math.abs(turn-(start+i*.35))<.015,case[1]..': reversal timing') end
    assert(math.abs(x(Replay.sample(keys,start+.35/2)))<.01,case[1]..': mid-swing crosses the centre')
    local peak=0
    for t=start,finish-.01,.01 do peak=math.max(peak,math.abs(x(Replay.sample(keys,t+.01))-x(Replay.sample(keys,t)))/.01) end
    assert(peak>5 and peak<5.6,case[1]..': peak speed '..peak)
    assert(keys[#keys].t-finish>=1.5,case[1]..': no rest for the last attack to finish')
    assert(#edges(keys,1)==0,case[1]..': trigger used')
end
-- The special scenario presses the special once, before the swings.
do
    local keys=load('touch_special_continuous.tsv')
    local special=edges(keys,5)
    assert(#special==2 and special[1].down and special[1].t<.8 and not special[2].down and special[2].t<=.8,'special pulse')
    local pulse=Replay.transitions(keys,.39,.41)[5]
    assert(pulse.pressed and pulse.held,'special press edge')
end
-- Heavy release: three charges, each released by a swing while still held.
do
    local keys=load('touch_heavy_release.tsv')
    local trigger=edges(keys,1)
    assert(#trigger==6,'heavy: three trigger holds')
    for i=1,5,2 do
        local down,up=trigger[i].t,trigger[i+1].t
        local still=x(Replay.sample(keys,down))==x(Replay.sample(keys,down+.99))
        local swung=math.abs(x(Replay.sample(keys,up-.01))-x(Replay.sample(keys,down)))>1
        assert(still and swung and up-down>=1.35,'heavy: charge still, then a swing before the trigger is let go')
    end
end
-- Trigger release: three holds with no motion, then two ordinary swings.
do
    local keys=load('touch_trigger_release.tsv')
    local trigger=edges(keys,1)
    assert(#trigger==6,'release: three trigger holds')
    local lengths={}
    for i=1,5,2 do
        lengths[#lengths+1]=trigger[i+1].t-trigger[i].t
        for t=trigger[i].t,trigger[i+1].t+1.4,.05 do
            assert(x(Replay.sample(keys,t))==x(keys[1]),'release: the hand moved during or after a cancelled charge')
        end
    end
    assert(math.abs(lengths[1]-.25)<1e-9 and math.abs(lengths[2]-.8)<1e-9 and math.abs(lengths[3]-1.6)<1e-9,'release: hold lengths')
    local turns=reversals(keys,trigger[6].t,keys[#keys].t)
    assert(#turns==1,'release: two swings after the holds')
end
-- Every scenario the testlab ships still parses (format compatibility).
local names={}
local listing=io.popen('dir /b "'..base:gsub('/','\\')..'\\*.tsv" 2>nul')
if listing then for name in listing:lines() do names[#names+1]=name end;listing:close() end
if #names==0 then
    listing=io.popen('ls "'..base..'"/*.tsv 2>/dev/null')
    if listing then for path in listing:lines() do names[#names+1]=path:match('[^/\\]+$') end;listing:close() end
end
assert(#names>=45,'scenario listing unavailable: '..#names)
for _,name in ipairs(names) do assert(Replay.parse(read(name)),name) end
print('testlab_scenarios=pass continuous_no_dwell reversal_timing peak_speed special_pulse heavy_release trigger_release all_parse='..#names)
