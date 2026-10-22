local Bridge=dofile(assert(arg[1]))
local bridge=Bridge.new()
local queries,exits,procs=0,0,0
local action={_is_server=true,_action_settings={},_action_sweep_component={},_num_hit_enemies=0,
    _unit_data_extension={is_resimulating=false},aborted=false,
    _is_sweep_aborted=function(self) return self.aborted end,
    _any_sweep_aborted=function(self) return self.aborted end,
    _do_overlap=function() queries=queries+1 end,
    _exit_damage_window=function() exits=exits+1 end,
    _handle_exit_procs=function() procs=procs+1 end}
local request={time=1,frame=10,active=true,stroke_id=1,position={},rotation={},from_position={},from_rotation={}}
assert(bridge.bind(action,1))
assert(not bridge.bind(action,2),'second stroke bound same live action')
assert(bridge.step(action,request) and queries==1)
assert(not bridge.step(action,request) and queries==1,'same frame queried twice')
assert(not bridge.forget(action),'forgot active proc lifecycle')
request.active=false; request.frame=11
assert(not bridge.step(action,request) and exits==1 and procs==1)
assert(not bridge.finish(action,1.1) and exits==1 and procs==1,'native finish duplicated proc')
assert(bridge.forget(action))
assert(bridge.bind(action,2)); action.aborted=true
request.active=true; request.stroke_id=2
assert(not bridge.step(action,request) and queries==1 and exits==2,'native cleave abort ignored')
assert(bridge.forget(action)); action.aborted=false
assert(bridge.bind(action,3)); action._unit_data_extension.is_resimulating=true
request.stroke_id=3
assert(not bridge.step(action,request) and queries==1 and exits==3,'resimulation repeated damage')
assert(bridge.forget(action)); action._unit_data_extension.is_resimulating=false
action._action_settings.hit_stickyness_settings={}
assert(not bridge.bind(action,4),'unsupported sticky context accepted')
action._action_settings={hit_stickyness_settings_special_active={}}
assert(not bridge.bind(action,4),'unknown special state assumed safe')
action._weapon_action_component={special_active_at_start=true}
assert(not bridge.bind(action,4),'active special sticky context accepted')
action._weapon_action_component.special_active_at_start=false
assert(bridge.bind(action,4),'inactive special-only sticky configuration blocked an ordinary sweep')
bridge.finish(action,1.2);bridge.forget(action)
do
    local Planner=dofile(arg[1]:gsub('action_bridge.lua$','sweep_plan.lua'))
    -- A 60-degree tracked turn between 32Hz frames, with the stock maul's
    -- long collision radius, needs more than the old twelve queries.
    local plan=Planner.make({current_valid=true,previous_valid=true,dt=1/32,
        translation=.1,angle=math.pi/3,radius=2.3},
        {max_gap=.1,max_translation=.5,arc_step=.06,max_segments=Bridge.max_segments})
    assert(not plan.reset and plan.segments>12 and plan.segments<=64)
    assert(2.3*(math.pi/3)/plan.segments<=.06,'fast swing was silently undersampled')
    local segments={};for i=1,plan.segments do segments[i]={} end
    action._action_settings={};action._weapon_action_component=nil
    assert(bridge.bind(action,5));local before=queries
    local fast={time=2,frame=20,active=true,stroke_id=5,segments=segments}
    assert(bridge.step(action,fast) and queries-before==plan.segments,'realistic turn lost native collision queries')
    assert(not bridge.step(action,fast) and queries-before==plan.segments,'same simulation frame repeated queries')
    bridge.finish(action,2);bridge.forget(action)
    for i=#segments+1,65 do segments[i]={} end
    assert(bridge.bind(action,6));fast.frame=21;fast.stroke_id=6;before=queries
    local ok,reason=bridge.step(action,fast)
    assert(not ok and reason=='query_budget' and queries==before,'hard query cap was bypassed')
    bridge.forget(action)
end
action._action_settings={}; action._is_server=false
assert(not bridge.bind(action,4),'remote authority accepted')
-- Buffer finalization may process ONLY previously admitted contacts, using
-- the native merge/process methods and the last physical world direction.
for _,mode in ipairs({'end','direction_lifetime','cancel','wrong_stroke','resim','abort','process_error','exit_error'}) do
    local temporary={}
    local lifecycle=Bridge.new({direction_value=mode=='direction_lifetime' and function(value)
        temporary.x=value[1];temporary.y=value[2];temporary.z=value[3];return temporary
    end or nil})
    local target,already_hit={},{}
    local overlap,merges,processes,hits,closed,finished=0,0,0,0,0,0
    local direction={1,0,0}
    local buffered={_is_server=true,_unit_data_extension={is_resimulating=false},_action_sweep_component={},
        _num_hit_enemies=0,_action_settings={num_frames_before_process=3},
        _is_sweep_aborted=function() return mode=='abort' end,_any_sweep_aborted=function() return mode=='abort' end,
        _do_overlap=function(self)
            overlap=overlap+1;self._saved_entries={target,already_hit};self._num_saved_entries=2
        end,
        _merge_saved_entries=function(self,new,count,saved,total)
            assert(#new==0 and count==0 and total==2 and self._num_saved_entries==0,'drain added contacts or retained reentrant queue')
            merges=merges+1;return saved,total
        end,
        _process_sweep_results=function(self,t,results,total,settings,actual,index)
            processes=processes+1
            assert((mode=='direction_lifetime' and actual.x==1 and actual.y==0 and actual.z==0 or actual==direction) and
                settings==self._action_settings and index==1 and total==2)
            assert(lifecycle.flushing(self),'saved contacts not scoped to final drain')
            if lifecycle.claim(self,results[1]) then hits=hits+1 end
            assert(not lifecycle.claim(self,results[1]) and not lifecycle.claim(self,results[2]),'saved contacts repeated a target')
            if mode=='process_error' then error('injected delayed processing failure') end
        end,
        _exit_damage_window=function() closed=closed+1;if mode=='exit_error' then error('injected exit failure') end end,
        _handle_exit_procs=function() finished=finished+1 end}
    assert(lifecycle.bind(buffered,1))
    assert(lifecycle.claim(buffered,already_hit))
    if mode=='abort' then
        -- Populate an existing native queue without allowing another query.
        buffered._saved_entries={target,already_hit};buffered._num_saved_entries=2
    else
        assert(lifecycle.step(buffered,{time=1,frame=1,active=true,stroke_id=1,segments={{}},before_query=function() return direction end}))
    end
    local before=overlap
    if mode=='direction_lifetime' then lifecycle.direction(buffered).x=999 end -- engine temporary pool reuse
    if mode=='resim' then buffered._unit_data_extension.is_resimulating=true end
    local ok=pcall(function()
        if mode=='cancel' then lifecycle.finish(buffered,1.02)
        else lifecycle.step(buffered,{time=1.02,frame=2,active=false,natural_end=true,stroke_id=mode=='wrong_stroke' and 2 or 1}) end
    end)
    local drains=mode=='end' or mode=='direction_lifetime' or mode=='process_error' or mode=='exit_error'
    assert(merges==(drains and 1 or 0) and processes==merges and hits==merges,'invalid drain mode '..mode)
    assert(ok==(mode~='process_error' and mode~='exit_error'))
    assert(overlap==before and buffered._num_saved_entries==0,'finalization queried stationary geometry or kept contacts')
    assert(not lifecycle.flushing(buffered) and not lifecycle.claim(buffered,{}),'closed delayed stroke admitted new hits')
    assert(closed==1 and finished==1,'native exit/proc not closed once after error')
    assert(not lifecycle.finish(buffered,1.03) and closed==1 and finished==1)
end
print('melee_action_bridge=pass native_queries once_per_frame stroke_binding native_cleave_abort proc_lifetime resimulation special_refusal local_authority')
