-- Engine fixture, NOT a headset readiness or worn-visual acceptance test.
local root=assert(arg[1])
local native_require=require
require=function(name)
    if name=='scripts/settings/equipment/action_sweep_settings' then return {sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1} end
    return native_require(name)
end
local mt={}
local function vector(x,y,z) return setmetatable({x=x,y=y,z=z},mt) end
mt.__add=function(a,b) return vector(a.x+b.x,a.y+b.y,a.z+b.z) end
Vector3=setmetatable({x=function(v) return v.x end,y=function(v) return v.y end,z=function(v) return v.z end}, {__call=function(_,...) return vector(...) end})
Quaternion={from_elements=function(...) return {...} end,rotate=function(_,v) return v end,
    multiply=function(_,q) return q end,to_elements=function(q) return unpack(q) end}
Unit={alive=function(unit) return unit~=nil end}
local unit,session={},{}
local clock,range,service,flag=0,true,true,'hammer'
local component={current_action_name='none',start_t=0,time_scale=1}
local template={name='fixture_melee',weapon_box={.15,.65,.15},actions={
    windup={kind='windup',start_input='start_attack',allowed_chain_actions={
        light_attack={action_name='light'},heavy_attack={action_name='heavy',chain_time=.4}}},
    light={kind='sweep',sweeps={{}},damage_window_start=.316,allowed_chain_actions={start_attack={action_name='windup',chain_time=.6}}},
    heavy={kind='sweep'}},action_inputs={heavy_attack={input_sequence={
        {input='action_one_hold',value=true,duration=.35},{input='action_one_hold',value=false}}}}}
local weapon={weapon_template=template,actions={}}
local actor,api,cancels,queries,restores,last_endpoint= nil,nil,0,0,0,nil
local extension={_weapons={slot_primary=weapon},_weapon_action_component=component,_inventory_component={wielded_slot='slot_primary'},
    _action_handler={_calculate_time_scale=function() return 1 end,_validate_action=function() return true end},
    condition_func_params=function() return {} end,
    stop_action=function(_,_,_,t)
        cancels=cancels+1; component.current_action_name='none'
        if api and actor then api.on_finish(actor,t) end
    end}
Managers={time={time=function() return clock end},state={game_session={is_server=function() return true end}},
    player={local_player=function() return {player_unit=unit} end}}
ScriptUnit={has_extension=function(_,name) if name=='weapon_system' then return extension end end}
Mods={lua={io={open=function(path)
    if path:find('physical_melee.flag',1,true) and flag then return {read=function() return flag end,close=function() end} end
end}}}
local tracking={gameplay_input_active=true,body_anchor_x=0,body_anchor_y=0,body_anchor_z=0,
    body_anchor_qx=0,body_anchor_qy=0,body_anchor_qz=0,body_anchor_qw=1,head_recenter_generation=1,last_transport_generation=1}
local presentation={mode=1,hand_side=function(role) return role=='support' and 'left' or 'right' end,
    controllers_suppressed=function() return false end,calibrated_character_scale=function() return 2 end,
    gameplay_context={ui_blocks_gameplay=function() return false end,input_service_enabled=function() return service end,
        local_input_unit=function() return unit end}}
local logged={}
local pose_block_setting=false
local mod={info=function(_,format,...) logged[#logged+1]=string.format(format,...) end,
    get=function(_,key) assert(key=='vr_pose_block');return pose_block_setting end,
    io_dofile=function(_,path)
        if path:match('melee_visual$') then return {new=function() return {restore=function() restores=restores+1 end} end} end
        return dofile(root..'/mods/'..path..'.lua')
    end}
local Tracking=dofile(root..'/mods/darktidevr/scripts/mods/darktidevr/darktidevr_melee_tracking.lua')
api=Tracking.install(mod,presentation,tracking,function() return range and 'shooting_range' or 'mission' end,
    {library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'})
api.update()
local claim=assert(api.support_request(unit,true))
assert(claim.control=='left_grip' and claim.action=='unbound','support grip leaked combat-ability binding')
local Replay=dofile(root..'/mods/darktide_testlab/scripts/mods/darktide_testlab/trajectory.lua')
local file=assert(io.open(root..'/mods/darktide_testlab/horizontal.tsv'))
local keys=assert(Replay.parse(file:read('*a'))); file:close()
local handler={_action_lookup={action_one_pressed=1,action_one_hold=2,action_one_release=3,action_two_hold=4},
    _input_cache={{},{},{},{}},_buffer_index=function(_,frame) return frame+1 end}
local commits=0
for frame=0,60 do
    clock=frame/52
    local sample=Replay.sample(keys,clock)
    for _,side in ipairs({'right','left'}) do
        local p,q=sample[side].position,sample[side].rotation
        for index,axis in ipairs({'x','y','z'}) do tracking[side..'_grip_'..axis]=p[index] end
        for index,axis in ipairs({'qx','qy','qz','qw'}) do tracking[side..'_grip_'..axis]=q[index] end
        tracking[side..'_grip_tracking_live']=true
    end
    handler._input_cache[4][frame+1]=false
    api.pre_fixed(handler,1/52,clock,frame,{})
    api.fixed_update(handler,1/52,clock,frame,{})
    assert(tracking.right_grip_x==sample.right.position[1],'weighted output overwrote real bridge raw pose')
    if handler._input_cache[1][frame+1] then
        commits=commits+1
        component.current_action_name='light'; component.start_t=clock
        actor={_player_unit=unit,_weapon=weapon,_is_server=true,_unit_data_extension={is_resimulating=false},
            _weapon_action_component=component,_action_sweep_component={},_action_settings=template.actions.light,
            _uses_matrix_data=true,_num_hit_enemies=0,_is_sweep_aborted=function() return false end,
            _any_sweep_aborted=function() return false end,_exit_damage_window=function() end,_handle_exit_procs=function() end,
            _do_overlap=function(_,t,a,ar,b)
                queries=queries+1
                last_endpoint=b
            end}
        assert(api.on_start(actor,actor._action_settings,clock))
    end
    if actor then
        assert(api.update_sweep(actor,1/52,clock,0,actor._action_settings))
        if queries>0 then
            local grip=assert(api.world_grip('right'))
            assert(math.abs(last_endpoint.x-grip.x)<1e-10 and math.abs(last_endpoint.z-grip.z)<1e-10,
                'render and collision diverged from the shared world mapping')
            local support=assert(api.world_grip('left'))
            tracking.body_anchor_x=tracking.body_anchor_x+10
            local held=assert(api.world_grip('right'))
            local held_support=assert(api.world_grip('left'))
            assert(held.x==grip.x and held_support.x==support.x,'render remapped sampled hands through a later body anchor')
            tracking.body_anchor_x=tracking.body_anchor_x-10
            assert(math.abs(grip.x-sample.right.position[1]*2)>.001,'bridge grip ignored the native weighted pose')
            local direction=assert(api.hit_direction(actor))
            assert(direction.x>0,'native authored attack direction replaced actual swing travel')
            local target={}
            assert(api.before_hit(actor,target)==true and api.before_hit(actor,target)==false)
            service=false; api.pre_fixed(handler,1/52,clock,frame,{})
            assert(not api.active() and not api.world_grip('right') and component.current_action_name=='none')
            break
        end
    end
end
assert(commits==1 and queries>0 and cancels>=2 and restores>0)
assert(table.concat(logged,'\n'):find('hardware_verified=false',1,true),'fixture tracking falsely claimed hardware acceptance')
service=true; tracking.right_grip_tracking_live=false; clock=clock+.02
handler._input_cache[1][101]=true; handler._input_cache[2][101]=true
api.pre_fixed(handler,.02,clock,100,{})
api.fixed_update(handler,.02,clock,100,{})
assert(not handler._input_cache[1][101] and not handler._input_cache[2][101],
    'tracking loss fell back to an unqualified stock attack input')
assert(api.on_start(actor,actor._action_settings,clock))
local before=queries
assert(api.update_sweep(actor,.02,clock,0,actor._action_settings) and queries==before and api.before_hit(actor,{})==false,
    'unavailable tracking permitted an authored damage window')
api.on_finish(actor,clock)
range=false; service=true
assert(not api.support_request(unit,true),'private physical mechanics leaked to remote mission')
api.fixed_update(handler,.02,clock+.02,100,{})
assert(not api.active())
-- A failure while adopting a weapon must not escape the protected adapter or
-- leave either offensive or defensive raw inputs in the native cache.
range=true; tracking.right_grip_tracking_live=true
local replacement={weapon_template=template,actions={}}
extension._weapons.slot_primary=replacement
extension.stop_action=function() error('injected native cancellation failure') end
handler._input_cache[1][202]=true; handler._input_cache[2][202]=true; handler._input_cache[4][202]=true
assert(pcall(api.fixed_update,handler,.02,clock+.04,201,{}),'adoption failure escaped protection')
assert(not api.active() and not handler._input_cache[1][202] and not handler._input_cache[2][202] and
    not handler._input_cache[4][202],'adoption failure leaked native combat input')
assert(table.concat(logged,'\n'):find('injected native cancellation failure',1,true))
template.actions.push={kind='push',allowed_chain_actions={push_follow_up={action_name='follow'}}}
component.current_action_name='push'
assert(not api.allow_chain(extension._action_handler,template.actions.push.allowed_chain_actions.push_follow_up,clock+.04),
    'failed source adoption allowed a previously queued native follow-up')
api.stop('fixture_reset');actor=nil
extension.stop_action=function() component.current_action_name='none' end
api=Tracking.install(mod,presentation,tracking,function() return 'shooting_range' end,
    {library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'})
flag='auto';clock=clock+2;template.name='thunderhammer_2h_p1_m1';component.current_action_name='none'
api.update();api.fixed_update(handler,.02,clock,300,{})
assert(api.active(),'mapped automatic tracking source failed to acquire native inertia owner')
assert(table.concat(logged,'\n'):find('inertia_id=thunderhammer_2h_p1_m1',1,true),'automatic weapon identity missing')
local raw_world=api.world_grip('right')
assert(raw_world,'mapped source did not supply shared render pose')
template.actions.block={kind='block',allowed_chain_actions={push={action_name='push'}}}
template.action_inputs.block={input_sequence={{input='action_two_hold',value=true}}}
template.action_inputs.push={input_sequence={{input='action_one_pressed',hold_input='action_two_hold',value=true}}}
for _,side in ipairs({'left','right'}) do
    tracking[side..'_grip_x']=.2;tracking[side..'_grip_y']=.3;tracking[side..'_grip_z']=-.3
    tracking[side..'_grip_qx']=0;tracking[side..'_grip_qy']=0;tracking[side..'_grip_qz']=0;tracking[side..'_grip_qw']=1
end
local auto_held=0
for frame=301,340 do
    pose_block_setting=frame>=311 and frame<340
    clock=clock+.02;handler._input_cache[4][frame+1]=false
    api.pre_fixed(handler,.02,clock,frame,{})
    api.fixed_update(handler,.02,clock,frame,{})
    local held=handler._input_cache[4][frame+1]
    if not pose_block_setting then assert(not held,'disabled pose setting held native block')
    elseif held then auto_held=auto_held+1 end
end
assert(auto_held>0,'setting was not routed through tracking to native block input')
extension._weapons.slot_primary={weapon_template={name='unmapped',actions=template.actions},actions={}}
clock=clock+.02
api.pre_fixed(handler,.02,clock,341,{})
api.fixed_update(handler,.02,clock,341,{})
assert(not api.active(),'unmapped weapon retained previous weighted body')
api.stop('fixture_end')
print('melee_tracking=pass real_native_runtime raw_separation shared_world_mapping primary_motion grip_claim actual_direction cancel_service private_authority no_hardware_claim')
