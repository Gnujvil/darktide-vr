-- Native API lifecycle fixture. Tick effects below are counters, not native
-- game damage; live target/proc/visual acceptance remains a separate gate.
local Bridge=dofile(assert(arg[1]))
for _,mode in ipairs({'natural','cancel','resim','stroke_changed','stop_error','tick_error','buffered'}) do
    local bridge=Bridge.new({native_events=true})
    local overlaps,ticks,exits,procs,stops=0,0,0,0,0
    local settings={hit_stickyness_settings={duration=.2}}
    local action={_is_server=true,_unit_data_extension={is_resimulating=false},_action_settings=settings,
        _action_sweep_component={is_sticky=false},_movement_state_component={can_jump=true},_num_hit_enemies=1}
    local function event(name,func)
        return function(self,...)
            if bridge.native_event(self,name,func,...) then return end
            return func(self,...)
        end
    end
    action._exit_damage_window=event('_exit_damage_window',function() exits=exits+1 end)
    action._handle_exit_procs=event('_handle_exit_procs',function() procs=procs+1 end)
    action._is_sweep_aborted=function(self) return self._action_sweep_component.is_sticky end
    action._any_sweep_aborted=action._is_sweep_aborted
    action._is_currently_sticky=function(self) return self._action_sweep_component.is_sticky end
    action._stop_hit_stickyness=function(self,actual,aborted)
        assert(actual==settings.hit_stickyness_settings)
        stops=stops+1;self:_handle_exit_procs()
        if mode=='stop_error' then error('injected sticky stop failure') end
        self._action_sweep_component.is_sticky=false;self._movement_state_component.can_jump=true
    end
    action._update_hit_stickyness=function(self,dt,t,component,actual)
        assert(dt==.02 and component==self._action_sweep_component and actual==settings.hit_stickyness_settings)
        ticks=ticks+1
        if mode=='tick_error' and ticks==2 then error('injected sticky tick failure') end
        if ticks==3 then self:_stop_hit_stickyness(actual,false) end
    end
    local function stick(self)
        self._action_sweep_component.is_sticky=true;self._movement_state_component.can_jump=false
        self:_exit_damage_window(1,1,true)
    end
    action._do_overlap=function(self)
        overlaps=overlaps+1
        if mode=='buffered' then self._num_saved_entries=1;self._saved_entries={{}}
        else stick(self) end
    end
    if mode=='buffered' then
        settings.num_frames_before_process=2
        action._merge_saved_entries=function(self,none,count,saved,total) assert(count==0 and total==1);return saved,total end
        action._process_sweep_results=function(self) stick(self) end
    end
    assert(bridge.bind(action,1))
    local request={time=1,dt=.02,frame=1,active=true,stroke_id=1,segments={{},{}},before_query=function() return {1,0,0} end}
    assert(bridge.step(action,request))
    if mode=='buffered' then
        request.frame=2;request.active=false;request.natural_end=true
        bridge.step(action,request)
        assert(bridge.holds_contact(action),'final admitted contact prematurely closed its sticky effect')
        assert(overlaps==2,'buffer drain ran another query')
    else
        assert(overlaps==1 and ticks==1 and exits==1 and procs==0,'sticky contact repeated overlap or prematurely finished proc')
        assert(bridge.holds_contact(action) and not bridge.claim(action,{}),'sticky effect admitted a new physical target')
        assert(not bridge.step(action,request) and ticks==1,'same simulation frame ticked sticky effect twice')
    end
    if mode=='cancel' or mode=='stop_error' then
        local ok=pcall(bridge.finish,action,1.02)
        assert(ok==(mode~='stop_error'))
    else
        for frame=3,8 do
            request.frame=frame;request.time=1+frame*.02;request.active=false
            if mode=='resim' then action._unit_data_extension.is_resimulating=true end
            if mode=='stroke_changed' then request.stroke_id=2 end
            local ok=pcall(bridge.step,action,request)
            if not ok then
                assert(mode=='tick_error');bridge.finish(action,request.time);break
            end
        end
    end
    assert(not bridge.holds_contact(action) and not action._action_sweep_component.is_sticky and action._movement_state_component.can_jump)
    assert(exits==1 and procs==1 and stops==1,'native sticky exit/proc/stop duplicated: '..mode)
    local expected_ticks=(mode=='natural' or mode=='buffered') and 3 or mode=='tick_error' and 2 or 1
    assert(ticks==expected_ticks,'extra native sticky ticks: '..mode)
    -- Keep event suppression through the original native finish, then forget.
    action:_exit_damage_window(2,1,true);action:_handle_exit_procs()
    assert(exits==1 and procs==1)
    assert(bridge.forget(action))
end
print('melee_sticky=pass native_timed_phase no_new_overlaps once_per_frame native_exit_proc_once cancel resim stop_tick_errors final_buffer_contact')
