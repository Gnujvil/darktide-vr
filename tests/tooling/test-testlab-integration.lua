local base=assert(arg[1])
local Replay=dofile(base..'/scripts/mods/darktide_testlab/trajectory.lua')
local f=assert(io.open(base..'/horizontal.tsv')); local scenario=f:read('*a'); f:close()
local hooks,safe,files={},{},{['horizontal.tsv']=scenario}
local require_hooks={}
local safe_classes={}
local results_appends=0
local clock=0
local vecmt={}
local function vector(x,y,z) return setmetatable({x=x,y=y,z=z},vecmt) end
vecmt.__add=function(a,b) return vector(a.x+b.x,a.y+b.y,a.z+b.z) end
vecmt.__sub=function(a,b) return vector(a.x-b.x,a.y-b.y,a.z-b.z) end
vecmt.__mul=function(a,b) return vector(a.x*b,a.y*b,a.z*b) end
vecmt.__unm=function(a) return vector(-a.x,-a.y,-a.z) end
Vector3=setmetatable({normalize=function(v) return v end,x=function(v) return v.x end,
    y=function(v) return v.y end,z=function(v) return v.z end},{__call=function(_,...) return vector(...) end})
Vector3Box=function(v) return {unbox=function() return v end} end
QuaternionBox=Vector3Box
Quaternion={rotate=function(_,v) return v end,from_elements=function(...) return {...} end,
    multiply=function(_,q) return q end,to_elements=function(q) return unpack(q) end,
    forward=function() return vector(0,1,0) end,look=function() return {} end}
Actor={unit=function(actor) return actor.unit end}
local unit,target={},{}
-- The breed table the testlab captures at load; blocks below add breeds to it.
local breeds_fixture={chaos_poxwalker={}}
local player_position=vector(0,0,0)
local target_removed=false
local target_health_missing=false
local group_mode=false
local group_units={}
local unit_health={}
local p={player_unit=unit,viewport_name='player',character_id=function() return 'fixture_character' end}
local inventory={wielded_slot='slot_primary'}
local profile={archetype={name='fixture_class',breed='human'},loadout={}}
p.profile=function() return profile end
local mode='shooting_range'
local target_health=100
local weapon={weapon_template={name='fixture_melee'}}
local weapon_extension={_weapons={slot_primary=weapon}}
weapon_extension._inventory_component=inventory
local original_item={gear_id='original_gear',name='original_item',resource_dependencies={original_model=true}}
weapon.item=original_item;profile.loadout.slot_primary=original_item
local package_ready,equip_calls=false,0
local despawns=0
Unit={alive=function(u) return u~=nil and not (u==target and target_removed) end,world_position=function(u) return u==unit and player_position or vector(0,0,0) end}
POSITION_LOOKUP={[unit]=vector(0,0,0)}
World={get_data=function() return {} end}
PhysicsWorld={immediate_raycast=function() return true,vector(0,1.5,0) end}
ScriptUnit={extension=function(_,system)
        if system=='weapon_system' then return weapon_extension end
        if system=='visual_loadout_system' then return {item_in_slot=function() return weapon.item end,
            _equipment={slot_primary={item=weapon.item,equipped=true,wieldable=true}},_static_profile_properties={breed='human'}} end
        return {read_component=function() return inventory end}
    end,
    has_extension=function(owner,system)
        if system=='weapon_system' then return weapon_extension end
        if system=='health_system' and target_health_missing then return nil end
        return {current_health=function() return unit_health[owner] or target_health end}
    end}
Managers={player={local_player=function() return p end},world={world=function() return {} end},state={
    game_mode={game_mode_name=function() return mode end},game_session={is_server=function() return true end},
    extension={system=function() return {get_nav_world=function() return {} end} end},
    camera={camera_position=function() return vector(0,0,1.6) end,camera_rotation=function() return {} end},
    minion_spawn={spawn_minion=function()
        if group_mode then local u={};group_units[#group_units+1]=u;unit_health[u]=100;return u end
        return target
    end,despawn_minion=function() despawns=despawns+1 end}}}
Mods={lua={io={open=function(path,mode)
    local name=path:match('[^/]+$')
    if name=='results.tsv' and mode=='a' then results_appends=results_appends+1 end
    if mode=='r' and not files[name] then return nil end
    return {read=function() return files[name] end,write=function(_,s)
        files[name]=mode=='a' and (files[name] or '')..s or s end,close=function() end}
end}}}
local inertia_updates=0
local fake_inertia={new=function()
    local first=true
    return {reset=function() first=true end,close=function() end,contact=function() return true end,
        update=function(request)
            inertia_updates=inertia_updates+1
            local raw=request.dominant
            local result={position={raw.position[1]-.05,raw.position[2],raw.position[3]},rotation=raw.rotation,
                linear_velocity={0,0,0},angular_velocity={0,0,0},time=request.time,reset=first,
                position_lag=.05,angular_lag=0,mass=1.4,support_engaged=false}
            first=false;return result
        end}
end}
local mod={io_dofile=function(_,path)
        if path:match('/range_isolation$') then return dofile(base..'/scripts/mods/darktide_testlab/range_isolation.lua') end
        if path:match('/combat_controls$') then return dofile(base..'/scripts/mods/darktide_testlab/combat_controls.lua') end
        if path:match('/buff_snapshot$') then return dofile(base..'/scripts/mods/darktide_testlab/buff_snapshot.lua') end
        if path:match('/threat$') then return dofile(base..'/scripts/mods/darktide_testlab/threat.lua') end
        if path:match('/observations$') then return dofile(base..'/scripts/mods/darktide_testlab/observations.lua') end
        if path:match('/damage_ledger$') then return dofile(base..'/scripts/mods/darktide_testlab/damage_ledger.lua') end
        if path:match('/anchor$') then return dofile(base..'/scripts/mods/darktide_testlab/anchor.lua') end
        if path:match('/ranged_pose$') then return dofile(base..'/scripts/mods/darktide_testlab/ranged_pose.lua') end
        if path:match('/ranged_sweep$') then return dofile(base..'/scripts/mods/darktide_testlab/ranged_sweep.lua') end
        if path:match('/targets$') then return dofile(base..'/scripts/mods/darktide_testlab/targets.lua') end
        if path:match('/inventory$') then return dofile(base..'/scripts/mods/darktide_testlab/inventory.lua') end
        if path:match('/loadout$') then return dofile(base..'/scripts/mods/darktide_testlab/loadout.lua') end
        if path:match('/resources$') then return dofile(base..'/scripts/mods/darktide_testlab/resources.lua') end
        if path:match('/startup$') then return dofile(base..'/scripts/mods/darktide_testlab/startup.lua') end
        if path:match('/debug_view$') then return dofile(base..'/scripts/mods/darktide_testlab/debug_view.lua') end
        if path:match('/melee_inertia$') then return fake_inertia end
        if path:match('/melee_pose$') then return dofile(base..'/../../mods/darktidevr/scripts/mods/darktidevr/darktidevr_melee_pose.lua') end
        local suffix=path:match('/melee_(%w+_?%w*)$')
        if suffix then return dofile(base..'/../../mods/darktidevr/scripts/mods/darktidevr/darktidevr_melee_'..suffix..'.lua') end
        return Replay
    end,info=function() end,
    hook=function(_,class,name,fn) hooks[name]=fn end,
    hook_safe=function(_,class,name,fn)
        safe[name]=fn
        if type(class)=='string' then safe_classes[class..'.'..name]=fn end
    end,
    hook_require=function(_,path,fn) require_hooks[path]=fn end}
get_mod=function() return mod end
local native_require=require
require=function(name)
    if name=='scripts/extension_systems/visual_loadout/equipment_component' then return {resolve_profile_properties=function(equipment,slot,static)
        assert(slot=='slot_primary' and static.breed=='human');return {wielded_weapon_template=equipment[slot].item.weapon_template}
    end} end
    if name=='scripts/settings/particles/player_character_particles' then return {find_relevant_particles=function() return {special_smoke=true} end} end
    if name=='scripts/settings/sound/player_character_sounds' then return {find_relevant_events=function() return {special_sound=true} end} end
    if name=='scripts/settings/decal/player_character_decals' then return {find_relevant_decals=function() return {special_decal=true} end} end
    if name=='scripts/backend/master_items' then return {get_cached=function() return {} end} end
    if name=='scripts/managers/ui/ui_character_profile_package_loader' then return {new=function()
        return {load_slot_item=function(_,slot,item)
            assert(item.resource_dependencies.special_smoke and item.resource_dependencies.special_sound and item.resource_dependencies.special_decal,
                'gameplay profile FX missing from native package loader')
        end,is_slot_loaded=function() return package_ready end,destroy=function() end}
    end} end
    if name=='scripts/extension_systems/visual_loadout/utilities/player_unit_visual_loadout' then return {equip_item_to_slot=function(owner,item,slot,existing,time)
        assert(owner==unit and slot=='slot_primary' and existing==nil and type(time)=='number')
        equip_calls=equip_calls+1;weapon.item=item
    end} end
    if name=='scripts/utilities/weapon/weapon_template' then return {weapon_template_from_item=function(item) return item.weapon_template end} end
    if name:find('action_sweep_settings') then return {sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1} end
    if name:find('buff_templates') then return {havoc_no_stagger={keywords={'no_stagger'}}} end
    if name:find('breeds') then return breeds_fixture end
    if name:find('nav_queries') then return {position_on_mesh=function(_,p) return p end} end
    return {}
end
local game_require=require
-- These checks read per-frame diagnostics, which are written only verbose.
files['verbose.flag']='enabled'
dofile(base..'/scripts/mods/darktide_testlab/darktide_testlab.lua')
require=native_require
local function command(s) files['command.txt']=s; mod.update(.11) end
do
    local session,lookup=Managers.state.game_session,Managers.player.local_player
    Managers.state.game_session=nil
    Managers.player.local_player=function() error('native peer lookup before session') end
    command('early_status status')
    assert(files['ack.tsv']:find('accepted'),'early status reached unsafe native peer lookup')
    Managers.state.game_session=session;Managers.player.local_player=lookup
end
command('s spawn chaos_poxwalker 1.5')
assert(files['ack.tsv']:find('accepted'),files['ack.tsv'])
command('r run horizontal.tsv')
assert(files['ack.tsv']:find('accepted'),files['ack.tsv'])
local self={_player=p,_action_lookup={action_one_pressed=1,action_one_hold=2,action_one_release=3}}
local previous_tick
local function tick(t)
    if previous_tick then
        while t-previous_tick>.025 do
            previous_tick=previous_tick+.02
            hooks.fixed_update(function() end,self,.02,previous_tick,math.floor(previous_tick*10000+.5),{})
            local intermediate={{},{},{}}; safe._parse_input(self,intermediate,{},1)
        end
    end
    hooks.fixed_update(function() end,self,.016,t,math.floor(t*10000+.5),{})
    previous_tick=t
    local cache={{},{},{}}; safe._parse_input(self,cache,{},1); return cache
end
tick(10)
assert(tick(10.16)[1][1]==true,'press edge missing')
assert(tick(10.18)[1][1]==false,'press repeated')
assert(tick(10.26)[3][1]==true,'release edge missing')
local action={_player_unit=unit,_unit_data_extension={is_resimulating=false},
    _weapon_action_component={time_scale=1,current_action_name='light'}}
local stock_called=0
local function native(_,t,a,aq,b,bq,final,settings,index)
    stock_called=stock_called+1
    assert(a.x~='stock' and b.x~='stock')
    target_health=75
    return 'native-result'
end
tick(10.525)
assert(hooks._do_overlap(native,action,10.525,'stock',{},'stock',{},false,{},1)=='native-result')
assert(stock_called==1)
hooks._process_hit(function() return false,false end,action,10.525,target,nil,{}, {},nil,nil,'torso')
tick(12)
mod.update(.016)
assert(files['results.tsv']:find('health_delta=25.000'),'health telemetry missing')
assert(select(2,files['results.tsv']:gsub('\tr\tresult\t',''))==1,'completed result duplicated')
command('reset reset')
assert(despawns==1,'reset did not despawn owned target')
command('bad run ../escape.tsv')
assert(files['ack.tsv']:find('error'),'path traversal accepted')
local passed=false
hooks._do_overlap(function(_,t,a) passed=a=='original' end,action,12,'original',{},'original',{},false,{},1)
assert(passed,'inactive hook altered native path')
command('s2 spawn chaos_poxwalker 1.5')
command('r2 run horizontal.tsv')
hooks.fixed_update(function() end,self,.02,20,200000,{})
assert(mod.replayed_hand('left'))
hooks.fixed_update(function() end,self,.02,19,190000,{})
assert(not mod.replayed_hand('left') and files['results.tsv']:find('simulation_rewind'),'rewind did not cancel replay')
assert(files['results.tsv']:find('outcome=aborted reason=simulation_rewind health_valid=true',1,true),'rewind missing structured outcome')
command('r3 run horizontal.tsv')
hooks.fixed_update(function() end,self,.02,30,300000,{})
mod.update(.6)
assert(not mod.replayed_hand('right') and files['results.tsv']:find('simulation_stalled'),'stalled input left test poses active')
command('r4 run horizontal.tsv')
hooks.fixed_update(function() end,self,.02,40,400000,{})
inventory.wielded_slot='slot_secondary'
mod.update(.01)
assert(not mod.replayed_hand('right') and files['results.tsv']:find('weapon_changed'))
inventory.wielded_slot='slot_primary'
command('r5 run horizontal.tsv')
hooks.fixed_update(function() end,self,.02,50,500000,{})
weapon_extension._weapons.slot_primary={weapon_template={name='replacement'}}
mod.update(.01)
assert(not mod.replayed_hand('right'),'same-slot replacement retained replay')
weapon_extension._weapons.slot_primary=weapon
command('r5b run horizontal.tsv')
hooks.fixed_update(function() end,self,.02,51,510000,{})
mode='hub'; mod.update(.01)
assert(not mod.replayed_hand('right') and files['results.tsv']:find('context_changed'))
mode='shooting_range'
command('lost run horizontal.tsv')
hooks.fixed_update(function() end,self,.02,55,550000,{})
local original_session=Managers.state.game_session
Managers.state.game_session={is_server=function() return true end}
mod.update(.01)
assert(files['results.tsv']:find('outcome=aborted reason=context_changed health_valid=false',1,true),'lost session fabricated final health')
Managers.state.game_session=original_session
command('r6 run horizontal.tsv')
hooks.fixed_update(function() end,self,.02,60,600000,{})
mod.on_unload()
assert(not mod.replayed_hand('right'),'unload retained test poses')
command('sw spawn chaos_poxwalker 1.5')
command('rw run horizontal.tsv hammer')
assert(files['ack.tsv']:find('accepted'),files['ack.tsv'])
hooks.fixed_update(function() end,self,.02,70,700000,{})
hooks.fixed_update(function() end,self,.02,70.02,700200,{})
hooks.fixed_update(function() end,self,.02,70.02,700200,{})
assert(inertia_updates==2,'repeated simulation frame reintegrated inertia')
local weighted_called=false
hooks._do_overlap(function(_,t,a,ar,b)
    assert(math.abs(a.x+.65)<1e-10 and math.abs(b.x+.65)<1e-10,'collision used raw controller pose')
    weighted_called=true
end,action,70.02,'original',{},'original',{},false,{},1)
assert(weighted_called)
local native_results={{actor={unit=target},position=vector(0,1,0)},{actor={unit={}},position=vector(0,2,0)}}
local reads=0
for _,name in ipairs({'_run_sweeps','_run_sphere_sweeps'}) do
    local result,count=hooks[name](function() reads=reads+1;return native_results,2 end,action)
    assert(result==native_results and count==2,'diagnostics replaced native contact table or count')
end
local native_best,native_actors={[target]=1},{}
action._first_person_extension={is_within_default_view=function(_,p) assert(p==native_results[1].position);return false end}
local best,actors=hooks._pick_best_sweep_result_per_unit(function(_,results,count,hits)
    reads=reads+1;assert(results==native_results and count==2 and hits[target]);return native_best,native_actors
end,action,native_results,2,{[target]=true})
assert(reads==3 and best==native_best and actors==native_actors,'observing native selection changed its result')
assert(files['results.tsv']:find('owned_target_actors=1',1,true) and files['results.tsv']:find('last_actor_in_view=false',1,true),
    'native contact and view-filter diagnostics missing')
command('weighted_stop stop')
assert(not mod.replayed_hand('right'))
weapon.weapon_template.actions={
    windup={kind='windup',start_input='start_attack',allowed_chain_actions={
        light_attack={action_name='light'},heavy_attack={action_name='heavy',chain_time=.35}}},
    light={kind='sweep',sweeps={{}},allowed_chain_actions={start_attack={action_name='windup',chain_time=.6}}},
    heavy={kind='sweep'}}
weapon.weapon_template.weapon_box={.1,.1,.5}
weapon.weapon_template.action_inputs={heavy_attack={input_sequence={
    {input='action_one_hold',value=true,duration=.35},{input='action_one_hold',value=false}}}}
weapon.actions={} -- Native action instances do not exist until first use.
weapon_extension._weapon_action_component={current_action_name='none',start_t=80}
weapon_extension._action_handler={_calculate_time_scale=function() return 1 end,_validate_action=function() return true end}
weapon_extension.condition_func_params=function() return {} end
local cancels=0
weapon_extension.stop_action=function(_,reason,data,t,allow_chain)
    assert(reason=='unwield' and data==nil and type(t)=='number' and allow_chain==false)
    cancels=cancels+1
end
require=game_require; command('physical run horizontal.tsv hammer physical'); require=native_require
assert(files['ack.tsv']:find('accepted'),files['ack.tsv'])
local commit_t
for i=0,50 do
    local t=80+i*.01
    hooks.fixed_update(function() end,self,.01,t,800000+i,{})
    local cache={{},{},{}}; safe._parse_input(self,cache,{},1)
    if i==16 then assert(not cache[1][1],'physical run replayed authored stock attack input') end
    if cache[1][1] then commit_t=t; break end
end
assert(commit_t and files['results.tsv']:find('physical_local_prototype'),'motion did not create a native input pulse')
local exits,procs,physical_queries,contacts=0,0,0,0
action._is_server=true; action._action_settings=weapon.weapon_template.actions.light
action._weapon=weapon
action._weapon_action_component.current_action_name='light'
action._uses_matrix_data=true
action._action_sweep_component={}; action._num_hit_enemies=0
action._is_sweep_aborted=function() return false end
action._any_sweep_aborted=function() return false end
action._exit_damage_window=function(self) return hooks._exit_damage_window(function() exits=exits+1 end,self) end
action._handle_exit_procs=function(self) return hooks._handle_exit_procs(function() procs=procs+1 end,self) end
action._do_overlap=function(...)
    return hooks._do_overlap(function() physical_queries=physical_queries+1 end,...)
end
safe.start(action,action._action_settings,commit_t)
do
    local component={is_sticky=true}
    local first,last=hooks._update_hit_stickyness(function(_,dt,t,c,s)
        assert(dt==.01 and t==commit_t and c==component and s==action._action_settings)
        return 'native',17
    end,action,.01,commit_t,component,action._action_settings)
    assert(first=='native' and last==17 and files['results.tsv']:find('sticky_native_update',1,true),'sticky observer changed native call/returns')
end
hooks._update_sweep(function() error('physical run used authored collision window') end,action,.01,commit_t,0,action._action_settings)
-- The binding frame also sweeps the stroke's motion since its onset; a
-- duplicate native update in the same frame adds nothing.
local binding_queries=physical_queries
hooks._update_sweep(function() error('duplicate native update') end,action,.01,commit_t,0,action._action_settings)
assert(binding_queries>=1 and physical_queries==binding_queries,'production collision was not driven exactly once by motion')
assert(files['results.tsv']:find('backfill',1,true),'binding did not sweep the stroke since its onset')
local function contact() contacts=contacts+1; return false,false end
hooks._process_hit(contact,action,commit_t,target,nil,{}, {},nil,nil,'torso')
hooks._process_hit(contact,action,commit_t,target,nil,{}, {},nil,nil,'head')
assert(contacts==1,'duplicate hurtbox bypassed physical stroke ledger')
command('physical_stop stop')
assert(exits==1 and procs==1,'cleanup did not close native proc lifetime')
assert(files['results.tsv']:find('exit_entered=1 exit_completed=1 proc_entered=1 proc_completed=1',1,true),
    'actual native lifecycle dispatch was not recorded through cleanup')
assert(cancels==2,'adoption/cleanup retained a native action that could hit after hooks unload')
hooks._update_sweep(function() error('stopped scenario leaked a stock hit') end,action,.01,commit_t+.01,0,action._action_settings)
hooks.finish(function() end,action,'stopped',nil,commit_t+.01)
assert(exits==1 and procs==1,'native finish doubled proc events')
local restored=false
hooks._update_sweep(function() restored=true end,action,.01,commit_t+.02,0,action._action_settings)
assert(restored,'completed action retained suppression')
local idle=assert(io.open(base..'/idle.tsv')); files['idle.tsv']=idle:read('*a'); idle:close()
require=game_require; command('geometry_idle run idle.tsv hammer physical'); require=native_require
assert(files['ack.tsv']:find('accepted'),files['ack.tsv'])
for i=0,100 do
    -- Native reach/profile changes must not masquerade as raw hand motion.
    weapon.weapon_template.actions.light.range_mod=1+math.max(0,math.min(20,i-10))*.1
    hooks.fixed_update(function() end,self,.01,82+i*.01,820000+i,{})
    local cache={{},{},{}}; safe._parse_input(self,cache,{},1)
    assert(not cache[1][1],'native geometry changes created a stationary-hand attack')
end
command('geometry_stop stop')
command('scaled run horizontal.tsv hammer stock 2')
assert(files['ack.tsv']:find('accepted'),files['ack.tsv'])
for i=0,7 do
    hooks.fixed_update(function() end,self,.05,90+i*.05,900000+i,{})
    local cache={{},{},{}}; safe._parse_input(self,cache,{},1)
    if i==3 then assert(not cache[2][1],'duration scaling left input on original clock') end
    if i==7 then assert(cache[2][1],'scaled synchronized input was lost') end
end
assert(files['tracking.tsv']:find('synthetic_raw\tright\tbody') and files['tracking.tsv']:find('inertia_virtual\tright\tbody'),
    'raw and virtual trajectory sources were not recorded distinctly')
assert(files['results.tsv']:find('duration_scale=2.000000') and files['results.tsv']:find('config=poly131_'),
    'replay configuration identity was missing')
command('bad_scale run horizontal.tsv hammer physical 0')
assert(files['ack.tsv']:find('error') and not mod.replayed_hand('right'),'invalid duration accepted or left replay armed')
command('fixed_guard run horizontal.tsv hammer')
hooks.fixed_update(function() end,self,.02,100,1000000,{})
weapon_extension._weapons.slot_primary={}
hooks.fixed_update(function() end,self,.02,100.02,1000001,{})
assert(not mod.replayed_hand('right'),'fixed-step weapon replacement waited for a later render callback')
weapon_extension._weapons.slot_primary=weapon
weapon.weapon_template.name='thunderhammer_2h_p1_m1'
Managers.data_service={gear={fetch_inventory=function(_,character,slots)
    assert(character=='fixture_character' and #slots==2 and
        slots[1]=='slot_primary' and slots[2]=='slot_secondary')
    local promise={}
    function promise:next(fn)
        fn({owned_gear={gear_id='owned_gear',name='owned_stock_weapon',resource_dependencies={candidate_model=true},slots={'slot_primary'},breeds={'human'},archetypes={'fixture_class'},weapon_template={name='forcesword_p1_m1',actions={
            special={kind='sweep',hit_stickyness_settings_special_active={},num_frames_before_process=3},
            lightning={kind='sweep',weapon_chain_lightning_template='native'}}}}})
        return self
    end
    function promise:catch() return self end
    return promise
end}}
command('owned_catalog inventory')
assert(files['ack.tsv']:find('accepted') and files['results.tsv']:find('template=forcesword_p1_m1',1,true) and
    files['results.tsv']:find('sticky_actions=1 lightning_actions=1 delayed_actions=1',1,true),'owned catalog did not use native inventory/template APIs')
Managers.time={time=function(_,name) assert(name=='gameplay');return 100 end}
command('owned_swap weapon owned_gear')
assert(files['ack.tsv']:find('accepted') and equip_calls==0,'owned swap skipped package readiness')
command('busy_swap weapon owned_gear')
assert(files['ack.tsv']:find('error'),'overlapping temporary equip accepted')
mod.update(.01);assert(equip_calls==0)
package_ready=true;mod.update(.01)
assert(equip_calls==1 and weapon.item.gear_id=='owned_gear' and profile.loadout.slot_primary==original_item)
assert(files['results.tsv']:find('owned_swap\tweapon_ready',1,true),'weapon readiness lost command identity')
command('owned_restore weapon restore')
assert(files['ack.tsv']:find('accepted') and equip_calls==2 and weapon.item==original_item and profile.loadout.slot_primary==original_item)
assert(files['results.tsv']:find('weapon_packages_retained',1,true),'shared gameplay packages not retained through process lifetime')
command('unsafe_reload reload')
assert(files['ack.tsv']:find('error'),'hot reload released ownership of shared gameplay packages')
command('unowned_swap weapon unowned_gear')
assert(files['ack.tsv']:find('error') and equip_calls==2,'unowned item reached equip API')
require=game_require;command('stock_auto run horizontal.tsv auto physical');require=native_require
assert(files['ack.tsv']:find('accepted'),files['ack.tsv'])
assert(files['results.tsv']:find('id=thunderhammer_2h_p1_m1 source=stock_template_tuning_v1 estimated=true mass=2.1',1,true),
    'automatic replay configuration was not identified')
command('stock_auto_stop stop')
weapon.weapon_template.name='unmapped_stock'
require=game_require;command('stock_unknown run horizontal.tsv auto physical');require=native_require
assert(files['ack.tsv']:find('error') and not mod.replayed_hand('right'),'unmapped auto weapon armed replay')
do
    files['dodge.tsv']=scenario:gsub('([^\r\n]+)',function(line)
        if line:match('^#') then return line end
        return line..(line:match('^0.15') and ' 0 1' or ' 0 0')
    end)
    command('dodge_run run dodge.tsv')
    self._action_lookup.dodge=4
    for _,t in ipairs({80,80.08,80.16}) do hooks.fixed_update(function() end,self,.08,t,math.floor(t*1000),{}) end
    local cache={{},{},{},{}}
    safe._parse_input(self,cache,{},1)
    assert(cache[4][1]==true,'programmed native dodge edge was not authored')
    hooks.fixed_update(function() end,self,.02,80.18,80180,{})
    safe._parse_input(self,cache,{},1)
    assert(cache[4][1]==false,'native dodge edge repeated')
    command('dodge_stop stop')
end
do
    local first=assert(Replay.parse(scenario))[1]
    local rows={}
    for _,key in ipairs(assert(Replay.parse(scenario))) do
        local fields={key.t}
        for _,side in ipairs({'left','right'}) do
            for _,v in ipairs(first[side].position) do fields[#fields+1]=v end
            for _,v in ipairs(first[side].rotation) do fields[#fields+1]=v end
        end
        for i=1,4 do fields[#fields+1]=0 end
        rows[#rows+1]=table.concat(fields,' ')
    end
    files['anchor_idle.tsv']=table.concat(rows,'\n')
    require=game_require;command('anchor_idle run anchor_idle.tsv hammer physical 1 player');require=native_require
    assert(files['ack.tsv']:find('accepted'),files['ack.tsv'])
    for frame=0,15 do
        player_position=vector(frame*.01,0,0)
        hooks.fixed_update(function() end,self,.02,90+frame*.02,90000+frame,{})
    end
    assert(files['results.tsv']:find('mode=player_translation offset=0.150000,0.000000,0.000000',1,true),
        'player-follow anchor did not observe native root translation')
    assert(not files['results.tsv']:match('anchor_idle\tstroke\t'),'player locomotion fabricated stroke intent')
    player_position=vector(6,0,0)
    hooks.fixed_update(function() end,self,.02,90.32,90016,{})
    assert(not mod.replayed_hand('right') and files['results.tsv']:find('outcome=aborted reason=anchor_bounds',1,true),
        'unsafe root displacement did not terminate replay')
    player_position=vector(0,0,0)
end
do
    local old_health=target_health;target_health=100
    command('kill_confirmed run horizontal.tsv')
    action._is_server=true
    hooks._do_damage_to_unit(function() return 200,'died',1,nil,false end,action,{},target)
    target_removed=true;command('kill_confirmed_stop stop')
    assert(files['results.tsv']:find('health_source=native_kill',1,true),'confirmed native kill lost terminal health')
    target_removed=false;target_health=100
    command('kill_corpse run horizontal.tsv')
    hooks._do_damage_to_unit(function() return 200,'died',1,nil,false end,action,{},target)
    target_health_missing=true;command('kill_corpse_stop stop')
    local corpse=assert(files['results.tsv']:match('[^\n]*\tkill_corpse\tresult\t[^\n]*'))
    assert(corpse:find('health_valid=true',1,true) and corpse:find('health_source=native_kill',1,true),
        'live corpse without health extension lost confirmed native kill')
    target_health_missing=false
    target_removed=false;target_health=100
    command('kill_unknown run horizontal.tsv')
    action._is_server=false
    hooks._do_damage_to_unit(function() return 200,'died',1,nil,false end,action,{},target)
    target_removed=true;command('kill_unknown_stop stop')
    local row=assert(files['results.tsv']:match('[^\n]*\tkill_unknown\tresult\t[^\n]*'))
    assert(row:find('health_valid=false',1,true) and row:find('health_source=unavailable',1,true),'client prediction fabricated confirmed kill')
    target_removed=false;target_health=old_health
end
do
    -- Damage ledger: what the run pressed, the native attacks that started,
    -- and every hit the player's own attacks dealt (owned target or not).
    target_health=100;target_removed=false
    command('ledger_spawn spawn chaos_poxwalker 1.5')
    command('ledger_run run horizontal.tsv')
    assert(files['ack.tsv']:find('accepted'),files['ack.tsv'])
    for i=0,8 do
        hooks.fixed_update(function() end,self,.05,300+i*.05,3000000+i,{})
        local cache={{},{},{}};safe._parse_input(self,cache,{},1)
        safe._parse_input(self,cache,{},1) -- a second parse in one frame is not a second press
    end
    local swing={_player_unit=unit,_unit_data_extension={is_resimulating=false},
        _weapon_action_component={current_action_name='light_attack_left'}}
    safe.start(swing,{kind='sweep'},300.4)
    local calls=0
    local values={hooks.execute(function(attacked,profile,...)
        calls=calls+1;assert(attacked==target and select('#',...)==8,'ledger changed native arguments')
        target_health=60;return 40,'damaged',1,nil,true
    end,target,{name='fixture_light'},'attacking_unit',unit,'attack_type','melee','hit_zone_name','head','is_critical_strike',false)}
    assert(calls==1 and values[1]==40 and values[2]=='damaged' and values[4]==nil and values[5]==true,'ledger altered native attack returns')
    local foreign={}
    hooks.execute(function() calls=calls+1;return 0,'blocked' end,foreign,{name='fixture_light'},
        'attacking_unit',unit,'attack_type','melee','hit_zone_name','torso')
    assert(calls==2,'foreign hit was not passed to native exactly once')
    hooks.execute(function() calls=calls+1;return 5,'damaged' end,target,{name='enemy_profile'},'attacking_unit',foreign)
    hooks.finish(function() end,swing,'action_complete',nil,300.5)
    safe.start(swing,{kind='sweep'},301.9) -- no press: a weapon special or an unprompted chain
    hooks.finish(function() end,swing,'action_complete',nil,302)
    command('ledger_stop stop')
    local log=files['results.tsv']
    local summary=assert(log:match('[^\n]*\tledger_run\tdamage_summary\t[^\n]*'),'damage summary missing')
    assert(summary:find('presses=1 light=0 heavy=0 scripted=1 specials=0 pushes=0 cancelled=0 cancelled_attacked=0 attacks=2 attacks_pressed=1 attacks_unpressed=1 attacks_damaged=1 hits=2 damaging_hits=1 head_hits=1 weakspot_hits=1 critical_hits=0 kills=0 damage=40.000 presses_damaged=1 presses_no_damage=0',1,true),summary)
    assert(log:find('ledger_run\tdamage_hit\thit=1 t=0.400 attack=1 action=light_attack_left target=ledger_spawn breed=nil',1,true) and
        log:find('zone=head damage=40 result=damaged killed=false weakspot=true',1,true),'owned hit row missing')
    assert(log:find('ledger_run\tdamage_hit\thit=2 t=0.400 attack=1 action=light_attack_left target=foreign',1,true),'foreign hit not ledgered')
    assert(log:find('ledger_run\tdamage_press\tpress=1 t=0.200 kind=scripted released=0.250 attack=1 action=light_attack_left',1,true),'press row missing its attack')
    assert(log:find('ledger_run\tdamage_attack\tattack=2 t=1.900 action=light_attack_left kind=sweep press=none',1,true),'unpressed attack row missing')
    assert(select(2,log:gsub('\tledger_run\tdamage_hit\t',''))==2,'enemy attack on the target entered the player ledger')
    command('ledger_reset reset')
end
do
    -- wield: one stock wield press, delivered once, never during a replay.
    command('wield_bad wield sideways')
    assert(files['ack.tsv']:find('error'),'unknown wield slot accepted')
    command('wield_ranged wield secondary')
    assert(files['ack.tsv']:find('accepted'),files['ack.tsv'])
    self._action_lookup.wield_2=5
    local cache={{},{},{},{},{}};safe._parse_input(self,cache,{},1)
    assert(cache[5][1]==true,'wield input not delivered')
    local again={{},{},{},{},{}};safe._parse_input(self,again,{},1)
    assert(again[5][1]==nil,'wield input repeated')
    assert(files['results.tsv']:find('wield_ranged\twield_input\tinput=wield_2 delivered=true',1,true))
    inventory.wielded_slot='slot_secondary';mod.update(.01)
    assert(files['results.tsv']:find('wield_ranged\twield_complete\tslot=slot_secondary',1,true),'wield completion not observed')
    inventory.wielded_slot='slot_primary'
    command('sweep_primary rangedsweep')
    assert(files['ack.tsv']:find('error') and files['ack.tsv']:find('wield the ranged slot first',1,true),'sweep ran from the melee slot')
    require=game_require;command('sweep_list rangedsweep list');require=native_require
    assert(files['ack.tsv']:find('accepted') and files['results.tsv']:find('sweep_list\tranged_template_count\ttemplates=0',1,true),
        'read-only template listing failed')
    command('sweep_cancel rangedsweep cancel')
    assert(files['ack.tsv']:find('accepted'),'idle sweep cancel refused')
end
do
    group_mode=true
    command('group_spawn group chaos_poxwalker 3 1.5 0.6')
    assert(files['ack.tsv']:find('accepted') and #group_units==3,'bounded native group spawn failed')
    command('group_run run horizontal.tsv')
    action._is_server=true
    action._amount_of_mass_hit=0
    local reads=0
    for index,u in ipairs(group_units) do
        local value=index*10
        local max,empty,tag=hooks._current_max_hit_mass(function() reads=reads+1;return 12,nil,'native' end,action,{})
        assert(max==12 and empty==nil and tag=='native','native cleave getter returns changed')
        hooks._do_damage_to_unit(function() unit_health[u]=100-value;return value,'damaged',1,nil,false end,action,{},u)
        hooks._process_hit(function()
            action._amount_of_mass_hit=action._amount_of_mass_hit+1
            action._target_index=index;action._num_hit_enemies=index
            return index==3,false
        end,action,1,u,nil,{}, {},nil,nil,'torso')
    end
    assert(reads==3,'cleave observer ran extra native queries')
    command('group_stop stop')
    local count=0
    for line in files['results.tsv']:gmatch('[^\n]+') do
        if line:find('\tgroup_run\ttarget_result\t',1,true) then
            count=count+1;assert(line:find('native_damage=',1,true) and line:find('hits=1',1,true))
        end
    end
    assert(count==3 and files['results.tsv']:find('targets=3 health_valid=true health_delta=60.00000',1,true),
        'per-owned-target native outcomes lost identities or health')
    assert(files['results.tsv']:find('mass_before=2 mass_after=3 max_mass=12 target_index=3 hit_count=3 aborted=true armour_aborted=false',1,true),
        'native cleave budget/abort telemetry missing')
    local before=despawns;command('group_reset reset')
    assert(despawns-before==3,'reset did not remove exactly the owned group')
    local created=#group_units;command('group_bad group chaos_poxwalker 6 1.5 0.6')
    assert(files['ack.tsv']:find('error') and #group_units==created,'unbounded group reached native spawn')
    group_mode=false
end
do
    local old_extension,old_get_mod,old_system=ScriptUnit.has_extension,get_mod,Managers.state.extension.system
    local player_health,player_toughness,player_stamina=100,50,1
    local native_health={_is_invulnerable=true,current_health=function() return player_health end,
        set_invulnerable=function(self,value) self._is_invulnerable=value end,
        is_invulnerable=function(self) return self._is_invulnerable end,is_unkillable=function() return false end}
    local visibility=true
    local scenario_system={_current_scenario={},has_scenario_buff=function() return visibility and {} or false end,
        add_scenario_buff=function() visibility=true end,remove_scenario_buff=function() visibility=false end}
    local settings={cs_enable_training_grounds_invisibility=true,cs_enable_training_grounds_invulnerability=true}
    local perception={alert=function() end,aggro=function() end,force_new_target_attempt=function() end,
        aggro_state=function() return 'aggroed' end,is_perception_disabled=function() return false end}
    local buff_stats={melee_attack_speed=.1};local buff_stack=1
    local buff_extension={_unit=unit,buffs=function() return {{_template={name='owned_fixture_buff'},_instance_id=9,
        __class_name='ProcBuff',stack_count=function() return buff_stack end}} end,
        stat_buffs=function() return buff_stats end,keywords=function() return {blocking=true} end}
    get_mod=function(name) if name=='creature_spawner' then return {settings=settings} end;return old_get_mod(name) end
    Managers.state.extension.system=function(self,name)
        if name=='scripted_scenario_system' then return scenario_system end
        return old_system(self,name)
    end
    Managers.state.minion_spawn._spawned_minions={target}
    Managers.time={time=function() return 123 end}
    ScriptUnit.has_extension=function(owner,name)
        if name=='perception_system' then return perception end
        if owner==unit then
            if name=='buff_system' then return buff_extension end
            if name=='health_system' then return native_health end
            if name=='toughness_system' then return {remaining_toughness=function() return player_toughness end} end
            if name=='unit_data_system' then return {read_component=function(_,component)
                if component=='stamina' then return {current_fraction=player_stamina} end
                if component=='block' then return {is_blocking=true} end
            end} end
        end
        return old_extension(owner,name)
    end
    local native_spawn=Managers.state.minion_spawn.spawn_minion
    Managers.state.minion_spawn.spawn_minion=function()
        assert(hooks.should_disable_minion_perception(function() return true end,Managers.state.game_mode)==false,
            'owned attacker did not use native perception initializer gate')
        error('native spawn failure')
    end
    command('incoming_spawn_failure attacker 1.5')
    assert(files['ack.tsv']:find('error') and hooks.should_disable_minion_perception(function() return true end,Managers.state.game_mode)==true,
        'failed spawn left global native perception override active')
    Managers.state.minion_spawn.spawn_minion=function(...)
        assert(hooks.should_disable_minion_perception(function() return true end,Managers.state.game_mode)==false)
        return native_spawn(...)
    end
    command('incoming_spawn attacker 1.5')
    assert(files['ack.tsv']:find('accepted') and hooks.should_disable_minion_perception(function() return true end,Managers.state.game_mode)==true)
    Managers.state.minion_spawn.spawn_minion=native_spawn
    require=game_require;command('incoming_run run horizontal.tsv hammer physical');require=native_require
    assert(files['ack.tsv']:find('accepted'),files['ack.tsv'])
    command('incoming_arm threat 3')
    assert(files['ack.tsv']:find('accepted') and not visibility and not native_health._is_invulnerable,files['ack.tsv'])
    local buff_fixed=safe_classes['PlayerUnitBuffExtension.fixed_update']
    local appends_before=results_appends
    buff_fixed(buff_extension,unit,.02,12,900)
    assert(results_appends-appends_before==3,'full buff snapshot did not batch its data into one append plus summary/cost')
    assert(files['results.tsv']:find('phase=begin frame=900 time=12',1,true) and
        files['results.tsv']:find('name=melee_attack_speed value=0.1',1,true),'initial post-native buff snapshot missing')
    local native_calls=0
    local result,empty,tag=hooks.execute(function(attacked,profile,...)
        native_calls=native_calls+1;assert(attacked==unit and select('#',...)==4)
        player_stamina=.8;return 0,nil,'native'
    end,unit,{name='native_melee'},'attacking_unit',target,'attack_type','melee')
    assert(result==0 and empty==nil and tag=='native' and native_calls==1)
    hooks.execute(function() player_health=90;player_toughness=40;return 999,'damaged' end,unit,{name='native_melee'})
    hooks.execute(function() return 0,'blocked' end,unit,{name='native_melee'})
    hooks.add_proc_event(function(self) self._num_proc_events=self._num_proc_events+2 end,
        {_unit=unit,_num_proc_events=0},'on_block',{attacking_unit=target,attacked_unit=unit})
    local native_map={on_hit=1}
    local buff_class={update_proc_events=function() return true,native_map,nil end}
    local install=require_hooks['scripts/settings/buff/buff_classes']
    install({first=buff_class,alias=buff_class});local hook=hooks.update_proc_events
    install({again=buff_class});assert(hooks.update_proc_events==hook,'duplicate buff-class alias rehooked')
    local active,map,extra=hook(buff_class.update_proc_events,
        {_unit=unit,_template={name='fixture_native_buff'},__class_name='ProcBuff'},12,{},1,nil,nil)
    assert(active and map==native_map and extra==nil and files['results.tsv']:find('native_event_counts=on_hit:1',1,true),
        'native buff result observer altered returns or missed template/event metadata')
    buff_stats.melee_attack_speed=.2;buff_stack=2
    local function snapshots() return select(2,files['results.tsv']:gsub('\tbuff_snapshot\t','')) end
    local previous=snapshots()
    buff_fixed(buff_extension,unit,.02,12.1,901)
    assert(snapshots()==previous,'post-proc snapshot rate limit failed')
    buff_fixed(buff_extension,unit,.02,12.3,902)
    assert(snapshots()==previous+1 and files['results.tsv']:find('name=melee_attack_speed value=0.2',1,true),
        'native computed stat change was not captured after fixed_update')
    hook(buff_class.update_proc_events,{_unit=unit,_template={name='fixture_native_buff'}},12.35,{},1,nil,nil)
    local stat_rows=select(2,files['results.tsv']:gsub('\tbuff_stat\t',''))
    appends_before=results_appends
    buff_fixed(buff_extension,unit,.02,12.6,903)
    assert(results_appends-appends_before==2,'unchanged buff snapshot wrote duplicate data')
    assert(snapshots()==previous+2 and select(2,files['results.tsv']:gsub('\tbuff_stat\t',''))==stat_rows and
        files['results.tsv']:match('phase=post_proc[^\n]+unchanged_from=%d+'),'unchanged snapshot recopied rows or lost full-state reference')
    local before=despawns;command('incoming_stop stop')
    assert(visibility and native_health._is_invulnerable and settings.cs_enable_training_grounds_invisibility and
        settings.cs_enable_training_grounds_invulnerability and despawns==before+1,'command stop failed to restore native range state')
    local log=files['results.tsv']
    assert(log:find('attacks=3 blocked=1 protected=0 resource_unknown=0 health_delta=10.00000 toughness_delta=10.00000 native_proc_queued=1',1,true),
        'incoming/proc observer lost native result vs observed resource distinction')
    assert(log:find('threat_restored',1,true) and log:find('threat_armed',1,true))
    command('manual_buffs buffs')
    assert(files['ack.tsv']:find('accepted') and files['results.tsv']:match('manual_buffs\tbuff_snapshot\t[^\n]+complete=true'),
        'read-only buff command did not return a complete native snapshot')
    command('invalid_buffs buffs extra')
    assert(files['ack.tsv']:find('error'),'buff command accepted arbitrary arguments')
    mode='hub';settings.cs_enable_training_grounds_respawn=true
    command('empty_range enter Platforma --empty-range')
    assert(files['ack.tsv']:find('accepted') and settings.cs_enable_training_grounds_respawn==false,
        'empty startup profile failed to suppress future native range spawns')
    command('empty_reload reload')
    assert(files['ack.tsv']:find('error') and settings.cs_enable_training_grounds_respawn==false,
        'reload lost isolated range setting ownership')
    mod.on_unload()
    assert(settings.cs_enable_training_grounds_respawn==true,'isolated range unload did not restore original respawn setting')
    ScriptUnit.has_extension,get_mod,Managers.state.extension.system=old_extension,old_get_mod,old_system
end
do
    local saved_mode=mode;mode='shooting_range'
    command('live_trace_target spawn chaos_poxwalker 2')
    local previous_owners=Mods.darktidevr_physical_owners
    local observed={_player_unit=unit,_unit_data_extension={is_resimulating=false},
        _first_person_extension={is_within_default_view=function() return false end}}
    Mods.darktidevr_physical_owners={[unit]={owns=function(a) return a==observed end}}
    local raw={{actor={unit=target},position=vector(0,1,1)}}
    local origin,rotation=vector(0,1,1),{0,0,0,1}
    local result,count=hooks._run_sweeps(function(_,a,ar,b,br)
        assert(a==origin and b==origin and ar==rotation and br==rotation,'live geometry trace changed native query')
        return raw,1
    end,observed,origin,rotation,origin,rotation,{})
    assert(result==raw and count==1,'live observer changed native broad contacts')
    local best,map={},{}
    local selected,mapped=hooks._pick_best_sweep_result_per_unit(function() return best,map end,observed,raw,1,{})
    assert(selected==best and mapped==map and next(best)==nil,'live observer admitted a native-filtered contact')
    local a,b=hooks._process_hit(function() return false,true end,observed,0,target,nil,{}, {},nil,nil,'torso')
    assert(a==false and b==true,'live observer changed native hit result')
    local damage,outcome,eff,stagger,weak=hooks._do_damage_to_unit(function() return 12,'damaged',.5,'light',true end,observed,{},target)
    assert(damage==12 and outcome=='damaged' and eff==.5 and stagger=='light' and weak==true)
    assert(hooks.finish(function() return 'native-finish' end,observed,'complete',nil,1)=='native-finish')
    assert(files['results.tsv']:find('live_contact_summary') and
        files['results.tsv']:find('queries=1 raw_actors=1 owned_actors=1 selected=0 hit_callbacks=1 damage_calls=1') and
        files['results.tsv']:find('owned_in_view=false'),
        'unscripted physical contact stages were not distinguished')
    command('live_trace_reset reset')
    Mods.darktidevr_physical_owners=previous_owners;mode=saved_mode
end
do
    local saved_session=Managers.state.game_session
    local saved_get_mod=get_mod
    local combat_settings={cs_enable_training_grounds_respawn=true}
    get_mod=function(name)
        if name=='creature_spawner' then return {settings=combat_settings} end
        return saved_get_mod(name)
    end
    files['combat_on_start.flag']='enabled'
    Managers.state.game_session=nil
    mod.get=function(_,key) return key=='testlab_auto_enter' or key=='testlab_controller_chord' end
    local prior_ack=files['ack.tsv']
    require=game_require
    dofile(base..'/scripts/mods/darktide_testlab/darktide_testlab.lua')
    require=native_require
    assert(combat_settings.cs_enable_training_grounds_respawn==false,'combat startup loaded default mobs before isolation')
    mod.on_game_state_changed('exit','StateGameplay') -- hub-to-range handoff must keep the startup gate armed
    local default_spawns=0
    local native_steps={enemies_loop={start_func=function()default_spawns=default_spawns+1 end,
        condition_func=function()default_spawns=default_spawns+1 end}}
    require_hooks['scripts/extension_systems/training_grounds/shooting_range_steps'](native_steps)
    local empty_data={};native_steps.enemies_loop.start_func(nil,nil,nil,empty_data,0)
    for i=1,100 do native_steps.enemies_loop.condition_func() end
    assert(default_spawns==0 and next(empty_data.units)==nil,'actual startup hook allowed initial native spawns')
    native_steps.enemies_loop.name='enemies_loop'
    native_steps.enemies_loop.start_func=function()default_spawns=default_spawns+1 end -- late mod replacement
    hooks._start_step(function(_,_,step,player,scenario,data,t)step.start_func(nil,player,scenario,data,t)end,
        {},{},native_steps.enemies_loop,nil,{},empty_data,0)
    assert(default_spawns==0,'late Creature Spawner replacement bypassed engine start boundary gate')
    assert(files['ack.tsv']==prior_ack,'auto startup replaced mailbox acknowledgement and could replay stale requests')
    local title={_continue=function(self) self.called=(self.called or 0)+1 end}
    local input={is_null_service=function() return false end}
    safe_classes['TitleView.update'](title,0,0,input)
    safe_classes['TitleView.update'](title,0,2,input)
    safe_classes['TitleView.update'](title,0,3,input)
    assert(title.called==1,'startup option failed to arm one stock title continuation')
    mod.toggle_combat() -- Not yet in the range: failed start must restore cache.
    assert(combat_settings.cs_enable_training_grounds_respawn==true,'failed combat startup did not restore original respawn')
    native_steps.enemies_loop.start_func();native_steps.enemies_loop.condition_func()
    assert(default_spawns==2,'default spawn hook remained suppressed after combat cancellation')
    files['combat_on_start.flag']=nil
    get_mod=saved_get_mod
    Managers.state.game_session=saved_session
end
do
    -- Persistent sessions: quiet by default, readiness probe, module refresh.
    mode='shooting_range';target_health=100;target_removed=false
    command('quiet verbose off')
    assert(files['ack.tsv']:find('accepted') and files['results.tsv']:find('quiet\tverbose\tenabled=false',1,true),'verbose verb')
    command('quiet_spawn spawn chaos_poxwalker 1.5')
    command('quiet_run run horizontal.tsv')
    local before=files['tracking.tsv'] or ''
    for i=0,6 do hooks.fixed_update(function() end,self,.05,400+i*.05,4000000+i,{});safe._parse_input(self,{{},{},{}},{},1) end
    local probe={_player_unit=unit,_unit_data_extension={is_resimulating=false},
        _weapon_action_component={time_scale=1,current_action_name='light'}}
    hooks._do_overlap(function() return 'native' end,probe,400.3,vector(0,0,0),{},vector(0,1,0),{},false,{},1)
    hooks._process_hit(function() return false,false end,probe,400.3,target,nil,{},{},nil,nil,'head')
    command('quiet_stop stop')
    local log=files['results.tsv']
    local function rows(kind) return select(2,log:gsub('\tquiet_run\t'..kind..'\t','')) end
    assert(rows('sweep')==0 and rows('query_geometry')==0 and rows('target_state')==0,'quiet run wrote per-frame rows')
    assert((files['tracking.tsv'] or '')==before,'quiet run wrote tracking.tsv')
    assert(rows('hit')==1 and rows('result')==1 and rows('damage_summary')==1,'quiet run lost per-hit or per-case rows')
    command('ready_probe ping')
    local pong=assert(files['results.tsv']:match('ready_probe\tpong\t([^\n]*)'),'ping did not answer')
    assert(pong:find('range=true player=true',1,true) and pong:find('pinned_loaders=',1,true) and
        pong:find('verbose=false',1,true) and pong:find('milestones=loaded:',1,true),pong)
    files['melee_timing.lua']='abc'
    command('refresh modules')
    local want=string.format('poly131_%08x',((97*131+98)*131+99)%4294967296)
    assert(files['results.tsv']:find('refresh\tmodule\tname=melee_timing refresh=live bytes=3 checksum='..want,1,true),'module checksum')
    assert(files['results.tsv']:find('refresh\tmodule\tname=damage_ledger refresh=reload',1,true) and
        files['results.tsv']:find('refresh\tmodules_refreshed\t',1,true),'module refresh report')
    command('verbose_bad verbose loud')
    assert(files['ack.tsv']:find('error'),'verbose accepted an unknown value')
    command('quiet_reset reset')
end
do
    -- Anchored, immortal, unstaggerable targets and the breed choice.
    mode='shooting_range';group_mode=true;Managers.time={time=function() return 200 end}
    breeds_fixture.chaos_plague_ogryn={breed_type='minion',base_unit='content/characters/enemy/chaos_plague_ogryn/third_person/base'}
    breeds_fixture.renegade_captain={breed_type='minion',base_unit='content/characters/enemy/chaos_traitor_guard_captain/third_person/base'}
    breeds_fixture.human={breed_type='player'}
    local loaded={['content/characters/enemy/chaos_plague_ogryn/third_person/base']=true}
    Application={can_get_resource=function(kind,name) assert(kind=='unit');return loaded[name]==true end}
    local native={}
    local spawned={}
    local old_extension,old_position,old_rotation=ScriptUnit.has_extension,Unit.world_position,Unit.world_rotation
    local old_spawn=Managers.state.minion_spawn.spawn_minion
    Managers.state.minion_spawn.spawn_minion=function(_,breed,pos,rot)
        local u={breed=breed}
        local n={pos=pos,rot={},max=100,damage=0,buffs={},keyword_reads=0,teleports=0}
        n.health={current_health=function() return math.max(0,n.max-n.damage) end,max_health=function() return n.max end,
            set_unkillable=function(_,v) n.unkillable=v end,is_unkillable=function() return n.unkillable==true end,
            set_health_instant=function(_,h) n.damage=n.max-h end}
        n.buff={add_externally_controlled_buff=function(_,name,t) assert(t==200);n.buffs[name]=true;return false,1 end,
            has_keyword=function(_,k) n.keyword_reads=n.keyword_reads+1;return k=='no_stagger' and n.buffs.havoc_no_stagger==true and n.keyword_reads>1 end}
        n.locomotion={teleport_to=function(_,p,q) n.pos=p;n.teleports=n.teleports+1 end}
        native[u]=n;spawned[#spawned+1]=u
        return u
    end
    ScriptUnit.has_extension=function(owner,system)
        local n=native[owner]
        if n then
            if system=='health_system' then return n.health end
            if system=='buff_system' then return n.buff end
            if system=='locomotion_system' then return n.locomotion end
            if system=='unit_data_system' then return {breed=function() return {name=owner.breed} end} end
        end
        return old_extension(owner,system)
    end
    Unit.world_position=function(u) if native[u] then return native[u].pos end;return old_position(u) end
    Unit.world_rotation=function(u) if native[u] then return native[u].rot end;return old_rotation and old_rotation(u) or {} end
    local function ack() return files['ack.tsv'] end
    command('breed_typo spawn chaos_plague_ogrin 2')
    assert(ack():find('error') and ack():find('unknown_breed:chaos_plague_ogrin',1,true) and ack():find('renegade_captain',1,true),ack())
    command('breed_player spawn human 2')
    assert(ack():find('not_a_minion_breed:human',1,true),ack())
    command('breed_unloaded spawn renegade_captain 2')
    assert(ack():find('breed_not_loaded:renegade_captain',1,true) and ack():find('add force',1,true),ack())
    command('breed_flag spawn chaos_poxwalker 2 glued')
    assert(ack():find('spawn options are anchored and force, not glued',1,true),ack())
    command('breed_attacker attacker 2 anchored')
    assert(ack():find('error'),'attacker accepted extra words')
    command('breed_forced spawn renegade_captain 2 force')
    assert(ack():find('accepted') and spawned[#spawned].breed=='renegade_captain','force did not spawn the unloaded breed')
    assert(not native[spawned[#spawned]].unkillable,'a plain spawn was made unkillable')
    -- A boss, anchored.
    require=game_require;command('boss spawn chaos_plague_ogryn 1.5 anchored');require=native_require
    assert(ack():find('accepted'),ack())
    local boss=spawned[#spawned];local n=native[boss]
    assert(n.unkillable and n.buffs.havoc_no_stagger,'anchored boss not made unkillable and unstaggerable')
    local log=files['results.tsv']
    assert(log:find('boss\tspawn\ttarget=boss generation=',1,true) and log:find('breed=chaos_plague_ogryn',1,true) and log:find('anchored=true',1,true),'spawn row')
    assert(log:find('anchor_adopted\ttarget=boss position=0.000,1.500,0.000 unkillable=true no_stagger_buff=true',1,true),'adoption row')
    mod.update(.01);mod.update(.01)
    assert(files['results.tsv']:find('anchor_ready\ttarget=boss unkillable=true no_stagger=true',1,true),'stagger guard not confirmed')
    -- Pushed away: back at its spawn point within one update.
    n.pos=vector(.6,2.4,0);mod.update(.01)
    assert(n.teleports==1 and n.pos.x==0 and n.pos.y==1.5,'pushed boss not returned')
    n.pos=vector(.02,1.5,0);mod.update(.01)
    assert(n.teleports==1,'teleported inside the dead band')
    -- A run: every hit lands in the ledger with its damage, then health returns.
    command('boss_run run horizontal.tsv')
    assert(ack():find('accepted'),ack())
    for i=0,4 do hooks.fixed_update(function() end,self,.05,500+i*.05,5000000+i,{});safe._parse_input(self,{{},{},{}},{},1) end
    local swing={_player_unit=unit,_unit_data_extension={is_resimulating=false},_weapon_action_component={current_action_name='light_attack_left'}}
    safe.start(swing,{kind='sweep'},500.2)
    local values={hooks.execute(function() n.damage=n.damage+60;return 60,'damaged',1,nil,false end,
        boss,{name='fixture'},'attacking_unit',unit,'attack_type','melee','hit_zone_name','torso')}
    assert(values[1]==60 and values[2]=='damaged','native returns changed')
    assert(n.damage==0,'health not restored right after the hit')
    hooks.execute(function() n.damage=n.damage+500;return 100,'died',1,nil,true end,
        boss,{name='fixture'},'attacking_unit',unit,'attack_type','melee','hit_zone_name','head')
    assert(n.damage==0 and Unit.alive(boss),'an over-health hit left the boss damaged or dead')
    hooks.finish(function() end,swing,'action_complete',nil,500.4)
    command('boss_stop stop')
    log=files['results.tsv']
    assert(log:find('boss_run\tdamage_hit\thit=1 t=',1,true) and log:find('target=boss breed=chaos_plague_ogryn',1,true) and
        log:find('zone=torso damage=60 result=damaged killed=false weakspot=false critical=nil attack_type=melee damage_type=nil health_after=40',1,true),'ledger lost the damage')
    assert(log:find('boss_run\tdamage_summary\t',1,true) and log:find('hits=2 damaging_hits=2 head_hits=1 weakspot_hits=1 critical_hits=0 kills=1 damage=160.000',1,true),'damage summary')
    assert(log:find('boss_run\tanchor_result\ttarget=boss teleports=0 max_offset=0.020 max_angle=0.0 health_restores=2 health_restored=160.000 unkillable=true no_stagger=true',1,true),
        'anchor share of the run')
    -- A group, anchored; reset releases all of them.
    require=game_require;command('pack group chaos_poxwalker 3 1.3 0.6 anchored');require=native_require
    assert(ack():find('accepted'),ack())
    command('pack_probe ping')
    assert(files['results.tsv']:find('pack_probe\tpong\t[^\n]*anchored=3',1),'ping anchored count')
    local first=native[spawned[#spawned-2]];first.pos=vector(3,3,0);first.damage=30;mod.update(.01)
    assert(first.teleports==1 and first.damage==0,'group member not held')
    command('pack_plain group chaos_poxwalker 3 1.3 0.6')
    assert(ack():find('accepted') and not native[spawned[#spawned]].unkillable,'plain group anchored')
    command('pack_probe2 ping')
    assert(files['results.tsv']:find('pack_probe2\tpong\t[^\n]*anchored=0',1),'old anchors survived a new spawn')
    command('anchored_close spawn chaos_poxwalker 0.9 anchored')
    command('anchored_reset reset')
    command('pack_probe3 ping')
    assert(files['results.tsv']:find('pack_probe3\tpong\t[^\n]*anchored=0',1),'reset kept anchors')
    ScriptUnit.has_extension,Unit.world_position,Unit.world_rotation=old_extension,old_position,old_rotation
    Managers.state.minion_spawn.spawn_minion=old_spawn
    Application=nil;group_mode=false
end
print('testlab_integration=pass native_input_sweep group_identity per_target_cleave incoming_attack_resource_proc_observation native_threat_command stop_restores_exact_cache_and_owned_cleanup damage_ledger wield_input ranged_sweep_guards quiet_mode ping modules anchored_targets breed_choice')
