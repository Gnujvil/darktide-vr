-- Offline: the testlab damage ledger, replayed from a recorded-shape fixture.
-- arg[1]: damage_ledger.lua, arg[2]: fixtures/testlab-damage-ledger.tsv
local Ledger=dofile(assert(arg[1]))
local file=assert(io.open(assert(arg[2]),'r'));local text=file:read('*a');file:close()
local function words(s) local out={};for w in s:gmatch('%S+') do out[#out+1]=w end;return out end
local function value(s)
    if s=='true' then return true elseif s=='false' then return false elseif s=='none' then return nil end
    return tonumber(s) or s
end
local ledger=Ledger.new()
local keys={}
local expected,press_expectations={},{}
local last_t=-math.huge
for line in text:gmatch('[^\r\n]+') do
    if not line:match('^%s*#') then
        local t,kind,rest=line:match('^([^\t]+)\t([^\t]+)\t?(.*)$')
        assert(kind,'malformed fixture line: '..line)
        local args=words(rest or '')
        if t=='expect' then
            for _,pair in ipairs(words(kind)) do local k,v=pair:match('^([%w_]+)=(.+)$');expected[k]=v end
        elseif t=='expect_press' then
            args=words(kind)
            press_expectations[#press_expectations+1]={index=tonumber(args[1]),outcome=args[2],attack=args[3]}
        else
            t=assert(tonumber(t),'fixture time')
            assert(t>=last_t,'fixture events must be chronological: '..line);last_t=t
            if kind=='press' then assert(ledger.press(t,args[1]))
            elseif kind=='release' then assert(ledger.release(t),'release without a held input')
            elseif kind=='special' then assert(ledger.press(t,'special',t))
            elseif kind=='cancel' then assert(ledger.cancel(t,args[1]),'cancel without a charge')
            elseif kind=='start' then keys[args[1]]={};ledger.attack_start(keys[args[1]],t,args[2],args[3])
            elseif kind=='finish' then ledger.attack_finish(assert(keys[args[1]]),t,args[2])
            elseif kind=='hit' then
                ledger.hit({t=t,action='component_name',target=args[6],zone=args[1],damage=tonumber(args[2]),result=args[3],
                    weakspot=value(args[4]),critical=value(args[5]),attack_type='melee'})
            else error('unknown fixture event '..kind) end
        end
    end
end
-- The summary text carries every expected field with the expected value.
local summary=ledger.summary_text()
for key,want in pairs(expected) do
    local got=summary:match('%f[%w_]'..key..'=([^ ]+)')
    assert(got==want,string.format('%s: expected %s, got %s (%s)',key,want,tostring(got),summary))
end
local s=ledger.summary()
assert(s.presses==s.light+s.heavy+s.scripted,'presses are the attack inputs by kind')
assert(s.presses==s.presses_damaged+s.presses_no_damage and
    s.presses_no_damage==s.presses_no_attack+s.presses_attack_no_damage,'press outcomes do not partition the presses')
assert(s.attacks==s.attacks_pressed+s.attacks_unpressed,'attacks do not partition into pressed and unpressed')
-- One row per input, naming the native attack (if any) that answered it.
local rows=ledger.press_rows()
assert(#rows==#press_expectations,'press rows: '..#rows)
for _,want in ipairs(press_expectations) do
    local row=rows[want.index]
    assert(row:find('^press='..want.index..' '),row)
    assert(row:find(' outcome='..want.outcome..' ',1,true),'press '..want.index..': '..row)
    assert(row:find(' attack='..want.attack..' ',1,true),'press '..want.index..': '..row)
end
-- Hits inside an attack take that attack's name, not whatever runs at report time.
local hits=ledger.hits()
assert(#hits==6 and hits[1].action=='light_attack_left' and hits[1].attack==1,'hit attribution')
assert(hits[6].attack=='none' and hits[6].action=='component_name','orphan hit attribution')
local text_row=Ledger.hit_text(hits[1])
assert(text_row:find('hit=1 t=0.380 attack=1 action=light_attack_left target=poxwalker_1',1,true) and
    text_row:find('zone=head damage=120 result=died killed=true weakspot=true critical=false',1,true),text_row)
-- Engine unit names contain spaces; every field stays one key=value token.
local spaced=Ledger.hit_text({index=7,t=1,attack=1,action='a',target='foreign',unit="[Unit '#ID[abc]']",zone='head',result='died'})
assert(spaced:find("unit=[Unit_'#ID[abc]'] zone=head",1,true) and spaced:find('killed=true',1,true),spaced)
local attack_rows=ledger.attack_rows()
assert(#attack_rows==6 and attack_rows[4]:find('attack=4 t=3.050 action=heavy_attack kind=sweep press=5 press_kind=heavy hits=1 damaging_hits=1 head_hits=1 damage=300.000 kills=0 finished=action_complete',1,true),attack_rows[4])
assert(attack_rows[6]:find('press=none',1,true),attack_rows[6])
-- Native Attack.execute key/value arguments: only the reported keys, by value.
local attacker,actor={},{}
local meta=Ledger.metadata('target_index',2,'attacking_unit',attacker,'hit_zone_name','head','hit_actor',actor,'is_critical_strike',true,'dangling')
assert(meta.attacking_unit==attacker and meta.hit_zone_name=='head' and meta.is_critical_strike==true and meta.target_index==2 and
    meta.hit_actor==nil,'metadata parse')
-- A charge still held when its attack starts is linked; a special never takes a release.
do
    local l=Ledger.new({window=.2})
    l.press(0,'heavy');l.press(.5,'special',.5)
    l.release(1.2)
    local held=l.press_rows()
    assert(held[1]:find('released=1.200',1,true) and held[2]:find('released=0.500',1,true),'special pulse took the attack release')
    local key={}
    l.attack_start(key,.55,'special_attack','sweep')
    l.attack_start({},1.3,'heavy_attack','sweep') -- supersedes the open special
    local rows2=l.attack_rows()
    assert(rows2[1]:find('press=2 press_kind=special',1,true) and rows2[1]:find('finished=superseded',1,true),rows2[1])
    assert(rows2[2]:find('press=1 press_kind=heavy',1,true),rows2[2])
    l.attack_finish(key,1.4) -- a stale key never closes the newer attack
    assert(l.open(),'stale finish closed the running attack')
    -- A press let go longer than the window before its attack is not linked.
    l.press(2,'light');l.release(2.01);l.attack_start({},2.3,'light_attack','sweep')
    assert(l.summary().presses_no_attack==1,'window not applied')
    -- A feint that still produced an attack is surfaced, not hidden.
    l.press(3,'heavy');l.cancel(3.5,'released');l.release(3.55);l.attack_start({},3.6,'heavy_attack','sweep')
    assert(l.summary().cancelled_attacked==1,'feint leak hidden')
end
-- A press the parser dropped is not adopted by a later attack nobody pressed.
do
    local l=Ledger.new()
    l.press(1,'light');l.release(1.02)
    l.press(1.5,'light');l.release(1.52)
    l.attack_start({},1.7,'light_attack','sweep')
    l.attack_start({},1.9,'light_attack','sweep')
    local s2=l.summary()
    assert(s2.presses_no_attack==1 and s2.attacks_unpressed==1 and l.press_rows()[1]:find('outcome=no_attack',1,true),
        'dropped press adopted by an unpressed attack')
end
-- Bounded rows: counts continue past the kept rows.
do
    local saved=Ledger.HIT_ROWS;Ledger.HIT_ROWS=2
    local l=Ledger.new()
    l.press(0,'light');l.attack_start({},.1,'a','sweep')
    for i=1,5 do l.hit({t=.1+i/100,zone='torso',damage=1,result='damaged'}) end
    Ledger.HIT_ROWS=saved
    local summary2=l.summary()
    assert(#l.hits()==2 and summary2.hits==5 and summary2.dropped_rows==3 and summary2.damage==5,'bounded rows lost counts')
    assert(not l.press(0/0,'light'),'non-finite press accepted')
end
print('testlab_damage_ledger=pass fixture_summary press_outcomes partitions attack_attribution orphan_hits metadata special_pulse supersede stale_finish window dropped_not_adopted feint_leak bounded_rows')
