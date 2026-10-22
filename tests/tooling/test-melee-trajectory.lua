local root=assert(arg[1])
local prefix=root..'/mods/darktidevr/scripts/mods/darktidevr/darktidevr_melee_'
local Timing=dofile(prefix..'timing.lua')
local vectors={left={-1,0,0},right={1,0,0},up={0,0,1},down={0,0,-1},stab={0,1,0},diagonal={1,0,1}}
local data,actions={},{}
local template={name='trajectory_fixture',weapon_box={.1,.1,.4},actions=actions,action_inputs={heavy_attack={input_sequence={
    {input='action_one_hold',value=true,duration=.35},{input='action_one_hold',value=false}}}}}
local function path(vector,origin,scale)
    local result={}
    for index=0,7 do result[#result+1]={origin[1]+vector[1]*scale*index/7,
        origin[2]+vector[2]*scale*index/7,origin[3]+vector[3]*scale*index/7} end
    return result
end
for name,vector in pairs(vectors) do
    local location='fixture-melee-trajectory/'..name
    data[location]={}
    for index,point in ipairs(path(vector,{0,0,0},1)) do
        data[location][(index-1)/7]={1,0,0,0,0,1,0,0,0,0,1,0,point[1],point[2],point[3],1}
    end
    actions['wind_'..name]={kind='windup',start_input=name=='left' and 'start_attack' or nil,allowed_chain_actions={
        light_attack={action_name='light_'..name},heavy_attack={action_name='heavy_'..name,chain_time=name=='up' and .8 or .4}}}
    for _,kind in ipairs({'light','heavy'}) do
        actions[kind..'_'..name]={kind='sweep',damage_window_start=0,damage_window_end=1,
            sweeps={{matrices_data_location=location}},damage_profile={name=kind..'_'..name},
            allowed_chain_actions={start_attack={action_name='wind_left',chain_time=kind=='heavy' and .9 or .6}}}
    end
end
local weapon={weapon_template=template,actions={}}
actions.light_right.allowed_chain_actions.start_attack.chain_time=.85
actions.heavy_up.allowed_chain_actions.start_attack.chain_time=1.1
local component={current_action_name='wind_left',start_t=0,time_scale=1}
local denied={}
local handler={_action_kinds_with_inverted_timescale={},_calculate_time_scale=function() return 1 end,
    _validate_action=function(_,settings) return not denied[settings] end}
local extension={_weapons={slot_primary=weapon},_weapon_action_component=component,_action_handler=handler,
    condition_func_params=function() return {} end}
local reads=0
local function loader(location) reads=reads+1;return assert(data[location]) end
for name,vector in pairs(vectors) do
    for _,heavy in ipairs({false,true}) do
        local selected=assert(Timing.match_trajectory(extension,'slot_primary',2,path(vector,{3,-5,7},.5),heavy,2,loader))
        assert(selected.action==(heavy and 'heavy_' or 'light_')..name,'wrong authored direction or attack class')
        assert(not selected.mirrored,'mirrored fallback displaced an exact native direction')
        assert(selected.settings==actions[selected.action] and selected.score<1e-10,'stock settings identity changed')
    end
end
assert(reads==6,'authored animation data reloaded every stroke')
local _,reason=Timing.match_trajectory(extension,'slot_primary',2,path(vectors.up,{0,0,0},1),true,.5,loader)
assert(reason=='selected_heavy_not_charged','native minimum charge of selected heavy was bypassed')
denied[actions.light_up]=true
assert(Timing.match_trajectory(extension,'slot_primary',2,path(vectors.up,{0,0,0},1),false,0,loader).action~='light_up')
denied[actions.light_up]=nil
denied[actions.wind_up]=true
assert(Timing.match_trajectory(extension,'slot_primary',2,path(vectors.up,{0,0,0},1),false,0,loader).action~='light_up',
    'special/conditional windup gate bypassed by trajectory selection')
denied[actions.wind_up]=nil
actions.heavy_up.attack_direction_override='push'
local ordinary=assert(Timing.match_trajectory(extension,'slot_primary',2,path(vectors.up,{0,0,0},1),true,2,loader))
assert(ordinary.action~='heavy_up','native shield slam selected for a weapon-hand swing')
actions.heavy_up.attack_direction_override=nil
for _,heavy in ipairs({false,true}) do
    local kind=heavy and 'heavy_' or 'light_'
    denied[actions[kind..'right']]=true
    local mirrored=assert(Timing.match_trajectory(extension,'slot_primary',2,path(vectors.right,{4,-3,2},.7),heavy,2,loader))
    assert(mirrored.action==kind..'left' and mirrored.mirrored and mirrored.score<1e-10,
        'missing horizontal direction did not use opposite native profile')
    denied[actions[kind..'right']]=nil
end
local mirrored_diagonal=assert(Timing.match_trajectory(extension,'slot_primary',2,path({-1,0,1},{0,0,0},1),false,0,loader))
assert(mirrored_diagonal.action=='light_diagonal' and mirrored_diagonal.mirrored,
    'horizontal mirroring reversed the vertical component')
assert(not Timing.match_trajectory(extension,'slot_primary',2,{{0,0,0},{0,0,0}},false,0,loader),'idle selected an attack')
local saved=actions.light_down.sweeps
actions.light_down.sweeps={{matrices_data_location='fixture-melee-trajectory/missing'}}
assert(not Timing.match_trajectory(extension,'slot_primary',2,path(vectors.right,{0,0,0},1),false,0,loader),
    'missing candidate geometry silently invented a closest animation')
actions.light_down.sweeps=saved
local function extra(name,matrices)
    local location='fixture-melee-trajectory/'..name
    data[location]=matrices
    actions['wind_'..name]={kind='windup',allowed_chain_actions={light_attack={action_name='light_'..name},
        heavy_attack={action_name='heavy_'..name,chain_time=.4}}}
    for _,kind in ipairs({'light','heavy'}) do
        actions[kind..'_'..name]={kind='sweep',damage_window_start=0,damage_window_end=1,
            damage_profile={name=kind..'_'..name},sweeps={{matrices_data_location=location}},
            allowed_chain_actions={start_attack={action_name='wind_left',chain_time=.6}}}
    end
end
local arc,arc_points={},{}
local rotation,rotation_points={},{}
for index=0,7 do
    local t=index/7
    local p={t,0,math.sin(t*math.pi)*.5}
    arc[t]={1,0,0,0,0,1,0,0,0,0,1,0,p[1],p[2],p[3],1}
    arc_points[#arc_points+1]=p
    local angle=t*math.pi/2
    rotation[t]={math.cos(angle),0,-math.sin(angle),0,0,1,0,0,math.sin(angle),0,math.cos(angle),0,0,0,0,1}
    rotation_points[#rotation_points+1]={.8*math.sin(angle),0,.8*math.cos(angle)}
end
extra('arc',arc);extra('rotation',rotation)
assert(Timing.match_trajectory(extension,'slot_primary',2,arc_points,false,0,loader).action=='light_arc',
    'curved animation confused with equal-endpoint straight swing')
assert(Timing.match_trajectory(extension,'slot_primary',2,rotation_points,false,0,loader).action=='light_rotation',
    'authored weapon rotation was omitted from tip trajectory')
local arc_settings=actions.light_arc
arc_settings.damage_window_start=.3;arc_settings.damage_window_end=.7
local cropped={}
for index=3,6 do cropped[#cropped+1]=arc_points[index] end
assert(Timing.match_trajectory(extension,'slot_primary',2,cropped,false,0,loader).action=='light_arc',
    'animation scoring ignored native damage-window changes')
arc_settings.damage_window_start=0;arc_settings.damage_window_end=1
if arg[2]=='--matcher-only' then
    print('melee_trajectory_matcher=pass directions_curves_rotation_damage_window native_classes_charge_conditions missing_data')
    return
end

-- Run the cached native validator body rather than a replacement validator.
-- This mirror is a CPU reference, not a certificate for the installed game.
local source_file=assert(io.open(root..'/artifacts/game-reference/action_handler.lua'))
local source=source_file:read('*a');source_file:close()
local body=assert(source:match('(ActionHandler%._validate_single_chain_action = function.-\nend)'))
local env={ActionHandler={}}
setmetatable(env,{__index=_G})
local chunk=assert(loadstring(body));setfenv(chunk,env);chunk()
local native_validate=env.ActionHandler._validate_single_chain_action
local deps={Timing=Timing}
for key,file in pairs({Volume='volume',Planner='sweep_plan',Bridge='action_bridge',Defense='defense',Tether='tether'}) do
    deps[key]=dofile(prefix..file..'.lua')
end
local Runtime,Pose,Inertia,Strokes=dofile(prefix..'runtime.lua'),dofile(prefix..'pose.lua'),dofile(prefix..'inertia.lua'),dofile(prefix..'strokes.lua')
local function replay(name,heavy,mirror_only)
    component.current_action_name='none';component.start_t=0
    local owner=assert(Pose.new(Inertia,{profile='knife',library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'}))
    local unit,reference={},{}
    local selected,queries,actor,commits,selection=nil,0,nil,0,nil
    local expected=(heavy and 'heavy_' or 'light_')..(mirror_only and 'left' or name)
    if mirror_only then denied[actions[(heavy and 'heavy_' or 'light_')..name]]=true end
    local strokes=Strokes.new()
    local runtime=Runtime.new(deps,{source='synthetic',unit=unit,owner=owner,strokes=strokes,
        extension=extension,weapon=weapon,slot='slot_primary',defaults={sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1},
        to_world=function(pose) return pose.position,pose.rotation end,load_animation=loader,
        emit=function(kind,value) if kind=='trajectory_selected' then selection=value end end,
        cancel_native=function() component.current_action_name='none' end})
    for frame=0,100 do
        local t=frame*.02
        local move=math.max(0,math.min(.9,(t-(heavy and 1.2 or .4))*3))
        local v=vectors[name]
        local current=assert(runtime.sample({source='synthetic',active=true,tracking_valid=true,reference=reference,
            frame=frame,time=t,dominant={position={-.4+v[1]*move,.4+v[2]*move,-.3+v[3]*move},rotation={0,0,0,1}},
            intent=true,guarding=false,heavy_intent=heavy and t>=.1}))
        if heavy and runtime.inputs(frame).pressed and not current.stroke.committed then
            component.current_action_name='wind_left';component.start_t=t
        end
        if current.stroke.committed then
            commits=commits+1
            -- Simulate the stock combo advancing/resetting after commit:
            -- destination differs from the entry sampled by Timing earlier.
            component.current_action_name='wind_down'
            local original=actions.wind_down.allowed_chain_actions[heavy and 'heavy_attack' or 'light_attack']
            original.reset_combo=true
            local redirected=runtime.select_chain(handler,original,t,t-component.start_t,1,actions)
            local valid,action,settings,reset=native_validate(handler,redirected,t,t-component.start_t,1,actions,{},nil,nil)
            assert(valid and action==expected and reset)
            assert(settings==actions[action] and original.action_name==(heavy and 'heavy_down' or 'light_down'))
            assert(redirected.chain_time==original.chain_time and redirected.reset_combo==original.reset_combo)
            local wrong=actions.wind_down.allowed_chain_actions[heavy and 'light_attack' or 'heavy_attack']
            assert(runtime.select_chain(handler,wrong,t,1,1,actions)==wrong,'other charge class redirected')
            local foreign={action_name=original.action_name}
            assert(runtime.select_chain(handler,foreign,t,1,1,actions)==foreign,'non-native edge redirected')
            assert(runtime.select_chain({},original,t,1,1,actions)==original,'foreign handler redirected')
            assert(runtime.select_chain(handler,original,t+.16,1,1,actions)==original,'expired commit redirected')
            denied[settings]=true
            assert(not native_validate(handler,redirected,t,t-component.start_t,1,actions,{},nil,nil),
                'selected action bypassed native live condition revalidation')
            denied[settings]=nil
            redirected.chain_time=t-component.start_t+.1
            assert(not native_validate(handler,redirected,t,t-component.start_t,1,actions,{},nil,nil),
                'native chain timing gate was bypassed')
            redirected.chain_time=original.chain_time
            redirected.running_action_state_requirement={ready=true}
            assert(not native_validate(handler,redirected,t,t-component.start_t,1,actions,{},nil,'blocked'),
                'native running-action state gate was bypassed')
            redirected.running_action_state_requirement=nil
            selected=action;component.current_action_name=action;component.start_t=t
            assert(math.abs(current.stroke.remaining-settings.allowed_chain_actions.start_attack.chain_time)<1e-8,
                'selected recovery debt was not reserved')
            actor={_player_unit=unit,_weapon=weapon,_is_server=true,_unit_data_extension={is_resimulating=false},
                _weapon_action_component=component,_action_sweep_component={},_action_settings=settings,_uses_matrix_data=true,_num_hit_enemies=0,
                _is_sweep_aborted=function() return false end,_any_sweep_aborted=function() return false end,
                _exit_damage_window=function() end,_handle_exit_procs=function() end,
                _do_overlap=function(self,_,a,_,b)
                    queries=queries+1;assert(self._action_settings.damage_profile==actions[selected].damage_profile)
                    if name=='right' then assert(b[1]>=a[1]-1e-8,'mirrored profile reversed the actual collision trajectory') end
                end}
            assert(runtime.on_start(actor,settings,t))
        end
        if actor then runtime.update_sweep(actor,.02,t,actor._action_settings) end
    end
    assert(commits==1 and queries>0 and selected==expected)
    assert(selection and selection.mirrored==(mirror_only==true),'mirrored fallback evidence missing')
    local debt=strokes.status().remaining
    runtime.invalidate('tracking_loss')
    assert(strokes.status().remaining==debt,'tracking loss cleared whiff/recovery debt')
    runtime.close()
    if mirror_only then denied[actions[(heavy and 'heavy_' or 'light_')..name]]=nil end
end
replay('right',false);replay('up',false);replay('right',true);replay('up',true)
replay('right',false,true);replay('right',true,true)
print('melee_trajectory=pass authored_6_directions light_heavy_separation selected_charge real_ABI4_runtime native_validator stock_profile_identity recovery_debt no_template_mutation fail_closed_missing_data')
