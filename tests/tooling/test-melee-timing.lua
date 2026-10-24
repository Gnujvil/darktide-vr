local Timing = dofile(arg[1])
local actions = {
    light = {kind="sweep", allowed_chain_actions={
        start_attack={action_name="windup",chain_time=.55},
        block={action_name="block",chain_time=.45}}},
    windup = {kind="windup", allowed_chain_actions={
        light_attack={action_name="light",chain_time=0},
        heavy_attack={action_name="heavy",chain_time=.5}}},
    heavy = {}, block = {},
}
local normal = {{action="light",input="start_attack"},
    {action="windup",input="light_attack"}}
local function scale(value) return function() return value end end
local seconds, target = Timing.resolve(actions,normal,scale(1))
assert(seconds == .55 and target == "light") -- Not the earlier block chain.
assert(Timing.resolve(actions,normal,scale(2)) == .275)
assert(Timing.resolve(actions,normal,scale(.5)) == 1.1)
assert(Timing.resolve(actions,normal,scale(.5),{sweep=true}) == .275)
local heavy = {{action="windup",input="heavy_attack",input_ready_after=.35}}
assert(Timing.resolve(actions,heavy,scale(1)) == .5)
assert(Timing.resolve(actions,heavy,scale(2)) == .35) -- Unscaled input hold floor.
assert(Timing.resolve(actions,heavy,scale(.5)) == 1)
actions.windup.allowed_chain_actions.light_attack.chain_time = .1
assert(Timing.resolve(actions,normal,scale(1)) == .65) -- Include intermediate action.
normal[2].action = "light"
assert(not Timing.resolve(actions,normal,scale(1)))
normal[2].action = "windup"
actions.light.allowed_chain_actions.start_attack.chain_until = .2
assert(not Timing.resolve(actions,normal,scale(1)))
actions.light.allowed_chain_actions.start_attack.chain_until = nil
assert(not Timing.resolve(actions,normal,scale(0)))
assert(not Timing.resolve(actions,normal,scale(0/0)))
actions.heavy.kind = "sweep"
local template = {actions=actions,action_inputs={heavy_attack={input_sequence={
    {input="action_one_hold",value=true,duration=.35},{input="action_one_hold",value=false}}}}}
local cycle = assert(Timing.from_windup(template,"windup",scale(2),nil,function() return true end))
assert(cycle.light_action == "light" and cycle.heavy_action == "heavy")
assert(cycle.light_interval == .325 and cycle.heavy_charge == .35)
assert(cycle.heavy_auto_complete_after == nil and cycle.heavy_damage_charge == "constant_one")
local release = template.action_inputs.heavy_attack.input_sequence[2]
release.auto_complete, release.time_window = true, 1
cycle = assert(Timing.from_windup(template,"windup",scale(2),nil,function() return true end))
assert(cycle.heavy_auto_complete_after == 1.35 and cycle.heavy_charge == .35)
actions.heavy.use_charge = true
cycle = assert(Timing.from_windup(template,"windup",scale(.25),nil,function() return true end))
assert(cycle.heavy_auto_complete_after == 2 and cycle.heavy_damage_charge == "module")
release.time_window = math.huge
cycle = assert(Timing.from_windup(template,"windup",scale(1),nil,function() return true end))
assert(cycle.heavy_auto_complete_after == nil)
assert(not Timing.from_windup(template,"windup",scale(1),nil,function(a) return a ~= actions.heavy end))
template.action_inputs.heavy_attack.input_sequence[1].input = "unknown_input"
local missing, why = Timing.from_windup(template,"windup",scale(1),nil,function() return true end)
assert(not missing and why == "unsupported_heavy_input")
template.action_inputs.heavy_attack.input_sequence[1].input = "action_one_hold"
-- A one-entry list of alternatives is the same chain (stock walks the list).
actions.light.allowed_chain_actions.start_attack = {{action_name="windup",chain_time=.55}}
local listed = assert(Timing.from_windup(template,"windup",scale(1),nil,function() return true end))
assert(math.abs(listed.light_interval - .65) < 1e-9 and listed.next_windup_action == "windup")
actions.light.allowed_chain_actions.start_attack = {{action_name="missing",chain_time=.55}}
assert(not Timing.from_windup(template,"windup",scale(1),nil,function() return true end),"an unknown alternative resolved")
-- Chainsword p1 m1's ordinary light loop, from the inspected stock template.
-- Keeping all four transitions catches accidental reuse of the opening timing.
local combo = {actions={}, action_inputs={heavy_attack={input_sequence={
    {input="action_one_hold",value=true,duration=.35},
    {input="action_one_hold",value=false,auto_complete=true,time_window=1}}}}}
local intervals, heavy_thresholds = {.55,.6,.45,.55}, {.5,.4,.5,.45}
for i=1,4 do
    combo.actions['w'..i] = {kind="windup",allowed_chain_actions={
        light_attack={action_name='l'..i,chain_time=0},
        heavy_attack={action_name='h'..i,chain_time=heavy_thresholds[i]}}}
    combo.actions['l'..i] = {kind="sweep",allowed_chain_actions={
        start_attack={action_name='w'..(i%4+1),chain_time=intervals[i]}}}
    combo.actions['h'..i] = {kind="sweep"}
end
for i=1,4 do
    local result = assert(Timing.from_windup(combo,'w'..i,scale(1),nil,function() return true end))
    assert(result.light_interval==intervals[i] and result.heavy_charge==heavy_thresholds[i])
    assert(result.heavy_auto_complete_after==1.35 and result.next_light_action=='l'..(i%4+1))
end
local graph=assert(Timing.light_combo(combo,'w1',scale(1),nil,function() return true end,4))
assert(#graph.steps==4 and graph.cycle_start==1 and graph.entry_duration==0)
assert(math.abs(graph.cycle_duration-2.15)<1e-9)
for i,step in ipairs(graph.steps) do
    assert(step.light_action=='l'..i and step.interval==intervals[i])
end
-- A separate opening route can enter a loop without itself recurring.
combo.actions.entry={kind='windup',allowed_chain_actions={
    light_attack={action_name='opening',chain_time=0},heavy_attack={action_name='h1',chain_time=.5}}}
combo.actions.opening={kind='sweep',allowed_chain_actions={
    start_attack={action_name='w1',chain_time=.7}}}
graph=assert(Timing.light_combo(combo,'entry',scale(2),nil,function() return true end))
assert(#graph.steps==5 and graph.cycle_start==2 and graph.entry_duration==.35)
assert(math.abs(graph.cycle_duration-1.075)<1e-9)
-- Each action gets its own live effective scale, rather than the entry's scale.
graph=assert(Timing.light_combo(combo,'w1',function(a)
    return a==combo.actions.l2 and 2 or 1
end,nil,function() return true end))
assert(graph.steps[1].interval==.55 and graph.steps[2].interval==.3)
local failed,reason,at=Timing.light_combo(combo,'w1',scale(1),nil,function() return true end,3)
assert(not failed and reason=='combo_limit' and at=='w4')
assert(not Timing.light_combo(combo,'w1',scale(1),nil,function() return true end,0))
combo.actions.l3.allowed_chain_actions.start_attack.running_action_state_requirement={done=true}
failed,reason,at=Timing.light_combo(combo,'w1',scale(1),nil,function() return true end)
assert(not failed and reason=='unsupported_route' and at=='w3')
-- The refusal names its link and why (PC run fastH: the slab shield's route).
local _,why,detail=Timing.from_windup(combo,'w3',scale(1),nil,function() return true end)
assert(why=='unsupported_route' and detail=='l3>start_attack:state_requirement',tostring(detail))
-- Chain alternatives (a toggle special's combo: crowbar, shovels; PC audit,
-- 22 October): the first stock would take under the live conditions (choose),
-- else the first that fits the route. Before, the whole route was refused.
do
    local toggled={actions={
        w={kind='windup',start_input='start_attack',allowed_chain_actions={
            light_attack={action_name='l'},heavy_attack={action_name='h',chain_time=.35}}},
        ws={kind='windup',allowed_chain_actions={
            light_attack={action_name='ls'},heavy_attack={action_name='h',chain_time=.35}}},
        l={kind='sweep',allowed_chain_actions={start_attack={{action_name='ws',chain_time=.6},{action_name='w',chain_time=.5}}}},
        ls={kind='sweep',allowed_chain_actions={start_attack={action_name='w',chain_time=.4}}},
        h={kind='sweep'}},action_inputs={heavy_attack={input_sequence={
            {input='action_one_hold',value=true,duration=.35},{input='action_one_hold',value=false}}}}}
    local special=false
    local function choose(target) return target~=toggled.actions.ws or special end
    local route=assert(Timing.from_windup(toggled,'w',scale(1),nil,function() return true end,choose),'alternatives refused')
    assert(route.next_windup_action=='w' and math.abs(route.light_interval-.5)<1e-9,'special-off alternative not taken')
    special=true
    route=assert(Timing.from_windup(toggled,'w',scale(1),nil,function() return true end,choose))
    assert(route.next_windup_action=='ws' and route.next_light_action=='ls' and math.abs(route.light_interval-.6)<1e-9,
        'special-on alternative not taken')
    assert(Timing.chain(toggled.actions,'l','start_attack').action_name=='ws','first alternative not the default')
    assert(Timing.chain(toggled.actions,'l','start_attack',function(name) return name=='w' end).action_name=='w')
end
-- A combo continuing through a block_windup (the next swing wound up with the
-- block held, as the ogryn slab shield does) is a windup route.
do
    local shield={actions={
        w={kind='windup',start_input='start_attack',allowed_chain_actions={
            light_attack={action_name='l'},heavy_attack={action_name='h',chain_time=.35}}},
        bw={kind='block_windup',allowed_chain_actions={
            light_attack={action_name='l2'},heavy_attack={action_name='h',chain_time=.4}}},
        l={kind='sweep',allowed_chain_actions={start_attack={action_name='bw',chain_time=.5}}},
        l2={kind='sweep',allowed_chain_actions={start_attack={action_name='w',chain_time=.5}}},
        h={kind='sweep'}},action_inputs={heavy_attack={input_sequence={
            {input='action_one_hold',value=true,duration=.35},{input='action_one_hold',value=false}}}}}
    local route=assert(Timing.from_windup(shield,'w',scale(1),nil,function() return true end),'block_windup route refused')
    assert(route.next_windup_action=='bw' and route.next_light_action=='l2')
    route=assert(Timing.from_windup(shield,'bw',scale(1),nil,function() return true end),'a block_windup could not start a route')
    assert(route.light_action=='l2' and route.heavy_action=='h')
    shield.actions.bw.kind='block'
    _,why,detail=Timing.from_windup(shield,'w',scale(1),nil,function() return true end)
    assert(why=='unsupported_route' and detail=='l>start_attack:kind_block','a plain block passed as a windup')
end
combo.actions.l3.allowed_chain_actions.start_attack.running_action_state_requirement=nil
combo.actions.l2.allowed_chain_actions.start_attack.action_name='missing'
assert(not Timing.light_combo(combo,'w1',scale(1),nil,function() return true end))
do
    local factor,available=1,true
    local template={actions={
        w1={kind='windup',start_input='start_attack',allowed_chain_actions={
            light_attack={action_name='l1'},heavy_attack={action_name='h1',chain_time=.4}}},
        w2={kind='windup',allowed_chain_actions={
            light_attack={action_name='l2'},heavy_attack={action_name='h1',chain_time=.4}}},
        l1={kind='sweep',sweeps={{}},allowed_chain_actions={start_attack={action_name='w2',chain_time=.6}}},
        l2={kind='sweep',sweeps={{}},allowed_chain_actions={start_attack={action_name='w1',chain_time=.4}}},
        h1={kind='sweep'}},action_inputs={heavy_attack={input_sequence={
            {input='action_one_hold',value=true,duration=.35},{input='action_one_hold',value=false}}}}}
    local component={current_action_name='none',start_t=10}
    local handler={_calculate_time_scale=function() return factor end,
        _validate_action=function() return available end,_action_kinds_with_inverted_timescale={sweep=true}}
    local extension={_weapons={slot_primary={weapon_template=template,actions={}}},
        _action_handler=handler,_weapon_action_component=component,condition_func_params=function() return {} end}
    local opening=assert(Timing.live(extension,'slot_primary',10))
    assert(opening.light_action=='l1' and opening.light_interval==.6 and opening.ready and opening.uses_matrix_data,
        'live timing required a lazily uncreated native action')
    component.current_action_name='l1'
    local next_attack=assert(Timing.live(extension,'slot_primary',10.4,'l1'))
    assert(next_attack.light_action=='l2' and next_attack.light_interval==.4 and not next_attack.ready)
    assert(next_attack.recovery_interval==.6,'next combo timing replaced committed stroke debt')
    factor=2
    next_attack=assert(Timing.live(extension,'slot_primary',10.4,'l1'))
    assert(next_attack.ready and next_attack.light_interval==.2 and next_attack.recovery_interval==.3)
    -- Stuck in its target (sawing), the running sweep holds its chain shut.
    extension._weapons.slot_primary.actions.l1={_action_sweep_component={is_sticky=true}}
    local stuck=assert(Timing.live(extension,'slot_primary',10.4,'l1'))
    assert(not stuck.ready and stuck.ready_in==nil,'a press was offered into a sawing attack')
    extension._weapons.slot_primary.actions.l1._action_sweep_component.is_sticky=false
    assert(Timing.live(extension,'slot_primary',10.4,'l1').ready,'an unstuck sweep stayed shut')
    extension._weapons.slot_primary.actions.l1=nil
    factor=.5
    next_attack=assert(Timing.live(extension,'slot_primary',10.4,'l1'))
    assert(next_attack.ready and next_attack.light_interval==.2 and next_attack.recovery_interval==.3,
        'live readiness disagreed with native inverted timescale')
    available=false
    assert(not Timing.live(extension,'slot_primary',100,'l1').ready,'native condition denial was ignored')
    available=true; component.current_action_name='none'; template.actions.w2.start_input='start_attack'
    local result,reason=Timing.live(extension,'slot_primary',100)
    assert(not result and reason=='ambiguous_entry','ambiguous idle entry guessed a route')
    -- As stock picks it: the windup it can start now (a slide-only windup is
    -- denied while standing; PC run fastH: the ogryn pickaxe never swung) ...
    handler._validate_action=function(_,settings) return settings~=template.actions.w2 end
    result=assert(Timing.live(extension,'slot_primary',100))
    assert(result.windup_action=='w1' and result.ready,'idle entry ignored the stock condition')
    -- ... and of those the highest action_priority.
    handler._validate_action=function() return available end
    template.actions.w1.action_priority=1; template.actions.w2.action_priority=2
    result=assert(Timing.live(extension,'slot_primary',100))
    assert(result.windup_action=='w2','idle entry ignored action_priority')
    -- None startable yet (e.g. mid-wield): the old unique-entry rule, not ready.
    template.actions.w2.start_input=nil; template.actions.w1.action_priority=nil
    handler._validate_action=function() return false end
    result=assert(Timing.live(extension,'slot_primary',100))
    assert(result.windup_action=='w1' and not result.ready,'an unstartable idle entry was lost or ready')
    handler._validate_action=function() return available end
    assert(not Timing.live({},'slot_primary',100))
end
-- The authored crosshair point (PC run fastA, 22 October): on a curved arc the
-- bounds' centre lies inside the curve, off the arc; the point aiming lays on
-- a target is the arc's own point nearest the view centre (+y).
do
    local data={}
    for i=0,12 do
        local angle=math.rad(-60+10*i)
        -- Tip only (zero forward column): a level arc of radius 1.5 below the eye.
        data[i*.05]={0,0,0,0, 0,0,0,0, 0,0,0,0, 1.5*math.sin(angle),1.5*math.cos(angle),-.4+.3*math.abs(math.sin(angle)),1}
    end
    local settings={damage_window_start=0,damage_window_end=.6,sweeps={{matrices_data_location="fixture/arc"}}}
    local template={weapon_box={.2,.15,1.15}}
    local points,reach,bounds,crossing=Timing.authored_path(template,settings,function(path) assert(path=="fixture/arc"); return data end)
    assert(points and reach and bounds and crossing,"authored path without its crosshair point")
    assert(math.abs(crossing[1])<1e-9 and math.abs(crossing[2]-1.5)<1e-9 and math.abs(crossing[3]+.4)<1e-9,
        "crosshair point is not the arc's point straight ahead")
    local centre={(bounds[1]+bounds[2])/2,(bounds[3]+bounds[4])/2,(bounds[5]+bounds[6])/2}
    assert(math.abs(centre[2]-1.5)>.3,"fixture arc is not curved enough to tell the two apart")
    local again={Timing.authored_path(template,settings,function() error("cache not used") end)}
    assert(again[4]==crossing or (again[4][2]==crossing[2]),"cached path lost its crosshair point")
    assert(again[5] and again[5].length==2.3,"cached path lost its attack box")
end
-- With the game's own sweep spline supplied (its anchor_point_offset applied;
-- PC audit, 22 October), paths come from it, not the raw matrices; a failing
-- spline falls back to them.
do
    local data={}
    for i=0,4 do data[i*.05]={0,0,0,0, 0,0,0,0, 0,0,1,0, -.6+.3*i,.5,0,1} end
    local settings={damage_window_start=0,damage_window_end=.2,sweeps={{matrices_data_location="fixture/offset"}}}
    local template={weapon_box={.1,.1,.5}}
    local function loader() return data end
    -- The stock spline: the same sweep moved 2 m forward by its anchor offset.
    Timing.use_sampler(function(_,u) return {-.6+1.2*u,2.5,0},{0,0,1} end)
    local _,reach,bounds,crossing,segment=Timing.authored_path(template,settings,loader)
    assert(reach and math.abs(bounds[3]-2.5)<1e-9 and math.abs(crossing[2]-2.5)<1e-9 and segment.base[2]==2.5,
        "the spline's offset sweep was not used")
    Timing.use_sampler(function() error("spline unavailable") end)
    _,_,bounds=Timing.authored_path(template,settings,loader)
    assert(bounds and math.abs(bounds[3]-.5)<1e-9,"a failing spline did not fall back to the matrices")
    Timing.use_sampler(nil)
    assert(Timing.engine_sampler()==nil,"an engine sampler outside the engine")
end
-- The aimed point is the attack box where it is as far away as the target
-- (PC run fastH, 22 October: an ogryn club's far tip laid on a near
-- poxwalker swept beside it). The box runs from the hand at base.
do
    local data={}
    -- A box from a hand low and right of the eyes, reaching 3.7 m ahead.
    -- It sweeps right to left; the middle frame is the one aimed straight ahead.
    for i=0,4 do
        local x=(2-i)*.6
        local d={-.4/3.7+x/3.7,3.65/3.7,.45/3.7}
        local n=math.sqrt(d[1]^2+d[2]^2+d[3]^2)
        data[i*.05]={0,0,0,0, 0,0,0,0, d[1]/n,d[2]/n,d[3]/n,0, .4,.3,-.5,1}
    end
    local settings={damage_window_start=0,damage_window_end=.2,sweeps={{matrices_data_location="fixture/long"}}}
    local template={weapon_box={.2,.15,1.85}}
    local _,_,_,crossing,segment=Timing.authored_path(template,settings,function() return data end)
    assert(crossing and segment and math.abs(segment.length-3.7)<1e-9 and segment.base[3]==-.5,"crosshair box missing")
    local point=Timing.aim_point(crossing,segment,1.5)
    assert(math.abs(math.sqrt(point[1]^2+point[2]^2+point[3]^2)-1.5)<1e-9,"aimed point not at the target's distance")
    local function angle(a,b)
        local d=(a[1]*b[1]+a[2]*b[2]+a[3]*b[3])/math.sqrt((a[1]^2+a[2]^2+a[3]^2)*(b[1]^2+b[2]^2+b[3]^2))
        return math.deg(math.acos(math.min(1,d)))
    end
    assert(angle(point,crossing)>8,"fixture does not show the near-target error it guards against")
    -- Beyond the box, its tip; nearer than the hand, its base; no target, the tip.
    local far=Timing.aim_point(crossing,segment,9)
    assert(math.abs(far[2]-crossing[2])<1e-9,"a target beyond reach was not given the tip")
    local near=Timing.aim_point(crossing,segment,.1)
    assert(math.abs(near[3]+.5)<1e-9,"a target inside the hand was not given the base")
    assert(Timing.aim_point(crossing,segment,nil)==crossing and Timing.aim_point(crossing,nil,1.5)==crossing)
    -- An enemy nearer than the crosshair moment's box (its base 1.7 m out, as
    -- an ogryn's arm holds it) is aimed with a moment whose box spans its
    -- distance, nearest the crosshair (PC overnight battery, 23 October).
    local far_hand={base={0,1.7,0},direction={0,1,0},length=1.5}
    local swept={{base={.9,.4,-.2},direction={0,1,0},length=1.5},{base={.6,.6,-.1},direction={0,1,0},length=1.5},far_hand}
    local near=Timing.aim_point({0,3.2,0},far_hand,1.2,swept)
    assert(math.abs(math.sqrt(near[1]^2+near[2]^2+near[3]^2)-1.2)<1e-9,'a near enemy was aimed past its distance')
    assert(math.abs(near[1]-.6)<1e-9,'the spanning moment nearest the crosshair was not chosen')
    local clamped,spans=Timing.aim_point({0,3.2,0},far_hand,1.2)
    assert(math.abs(clamped[2]-1.7)<1e-9 and spans==false,'without moments the box base is kept, and reported short')
    assert(select(2,Timing.aim_point({0,3.2,0},far_hand,1.2,swept))==true,'a spanning moment was not reported')
    -- No moment's box comes as near as the enemy's chest (an ogryn's maul,
    -- PC overnight battery, 23 October): the attack is laid on its nearest
    -- zone that one reaches (the upper leg; the head is nearer still), not
    -- past the chest.
    local eye={0,0,2}
    local chest={0,1,1.2}
    local zones={{0,1,1.2,zone="torso"},{0,1,1.6,zone="head"},{.1,1.05,.5,zone="upper_left_leg"},{.1,1.1,.15,zone="lower_left_leg"}}
    local only_far={far_hand}
    local aimed,reach,center,moved=Timing.aim_target(eye,chest,{0,3.2,0},far_hand,only_far,zones)
    assert(moved=="upper_left_leg" and aimed==zones[3],'the reachable zone nearest the contact was not chosen: '..tostring(moved))
    assert(math.abs(reach-math.sqrt(.1^2+1.05^2+1.5^2))<1e-9 and math.abs(math.sqrt(center[1]^2+center[2]^2+center[3]^2)-reach)<1e-9,
        'the moved aim is not at the zone distance')
    -- A contact some moment reaches keeps its point, and so does one no zone helps.
    local kept,_,_,unmoved=Timing.aim_target(eye,{0,2.5,2},{0,3.2,0},far_hand,only_far,zones)
    assert(kept[2]==2.5 and unmoved==nil,'a reachable contact was moved')
    local alone,_,_,none=Timing.aim_target(eye,chest,{0,3.2,0},far_hand,only_far,{{0,1,1.3,zone="head"}})
    assert(alone==chest and none==nil,'an unreachable zone replaced the contact')
    assert(Timing.aim_target(nil,chest,{0,3.2,0},far_hand,only_far,zones)==chest,'no eye moved the contact')
    -- The stock sweep drops hits outside the default view (PC run closeO1,
    -- 23 October). A crosshair moment whose point at the enemy's distance
    -- lies far to the side gives way to a moment that keeps it in view.
    assert(Timing.view_share({0,1,0})==0 and Timing.view_share({0,-1,0})==math.huge,'view share of the axis or behind')
    -- The measured limits: 57.8 degrees across, 32.5 degrees of elevation.
    local function at(h,e) return {math.cos(math.rad(e))*math.sin(math.rad(h)),math.cos(math.rad(e))*math.cos(math.rad(h)),math.sin(math.rad(e))} end
    assert(math.abs(Timing.view_share(at(57.8,0))-1)<1e-9 and math.abs(Timing.view_share(at(0,-32.5))-1)<1e-9,'view limits')
    assert(Timing.view_share(at(40,20))<1 and Timing.view_share(at(10,40))>1,'elevation, not the vertical tangent, bounds the view')
    local wide={base={1.2,.2,0},direction={0,1,0},length=1.5}
    local inside={base={.1,.5,-.1},direction={0,1,0},length=1.5}
    local seen,reached,visible=Timing.aim_point({0,3,0},wide,1.3,{wide,inside})
    assert(reached and visible and math.abs(seen[1]-.1)<1e-9,'an out-of-view crosshair point was kept')
    local kept_point,kept_reach,kept_view=Timing.aim_point({0,3,0},wide,1.3)
    assert(kept_reach==true and kept_view==false and math.abs(kept_point[1]-1.2)<1e-9,'with no other moment the reach is kept, out of view')
    -- No moment reaches the contact in view, a zone it does: moved there.
    local side={base={1.2,0,0},direction={0,1,0},length=3}
    local narrow={base={.05,1.5,0},direction={0,1,0},length=1}
    local out_eye={0,0,0}
    local aimed2,_,_,moved2=Timing.aim_target(out_eye,{1.2,.5,0},{0,3,0},side,{side,narrow},{{0,2,0,zone="torso"}})
    assert(moved2=="torso" and aimed2[2]==2,'an out-of-view contact was not moved to a zone in view')
end
print("melee_timing=pass combo=variable graph=bounded heavy_minimum_distinct_from_auto_complete=true live_native lazy_instances buff_scale committed_recovery inverted_readiness native_conditions aim_target_zones")
