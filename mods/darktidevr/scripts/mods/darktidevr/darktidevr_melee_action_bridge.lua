-- A local-authority prototype. Bind ONLY after the native action handler has
-- validated and started a sweep for a committed stroke. Reuses native hit
-- selection, damage profiles, cleave and procs; no direct damage calls.
local Bridge={max_segments=64}
function Bridge.new(options)
    options=options or {}
    local bindings=setmetatable({}, {__mode="k"})
    local api={}
    function api.bind(action,stroke_id)
        local settings=action._action_settings
        if not action._is_server or action._unit_data_extension.is_resimulating or not settings or not stroke_id or stroke_id<1 then
            return false,"invalid_context"
        end
        -- Sticky effects run only through the native lifecycle event hooks.
        local special=action._weapon_action_component and action._weapon_action_component.special_active_at_start
        local sticky=special and settings.hit_stickyness_settings_special_active or settings.hit_stickyness_settings
        if special==nil and settings.hit_stickyness_settings_special_active then
            return false,"unsupported_special_sweep"
        end
        -- Native _process_hit starts the chain once; native finish owns node
        -- removal. Closing the physical query window must not reset that tree.
        if settings.weapon_chain_lightning_template then
            local chain=action._chain_lightning_action_data
            if not options.native_events or action._do_chain_lightning_on_sweep~=true or
                    type(action._try_make_chain_from_sweep_hit)~="function" or type(action.finish)~="function" or
                    type(chain)~="table" or chain.is_server~=true or not chain.chain_root_node or
                    type(chain.chain_lightning_hit_units)~="table" or type(chain.chain_lightning_temp_targets)~="table" or
                    type(chain.on_chain_node_remove_func)~="function" or type(chain.targeting_module_component)~="table" then
                return false,"native_lightning_lifecycle_unavailable"
            end
        end
        if sticky and (not options.native_events or type(action._is_currently_sticky)~="function" or
                type(action._update_hit_stickyness)~="function" or type(action._stop_hit_stickyness)~="function") then
            return false,"native_sticky_lifecycle_unavailable"
        end
        if (settings.num_frames_before_process or 0)>0 and
                (type(action._merge_saved_entries)~="function" or type(action._process_sweep_results)~="function") then
            return false,"native_saved_hit_api_unavailable"
        end
        if bindings[action] then return false,"already_bound" end
        bindings[action]={stroke=stroke_id,open=true,targets={},sticky_settings=sticky}
        action._action_sweep_component.sweep_state="during_damage_window"
        return true
    end
    function api.claim(action,target)
        local binding=bindings[action]
        if not binding or binding.sticky or not (binding.open or binding.flushing) or not target or binding.targets[target] or
                not action._is_server or action._unit_data_extension.is_resimulating then return false end
        binding.targets[target]=true; return true
    end
    function api.flushing(action) local binding=bindings[action];return binding and binding.flushing==true end
    function api.native_event(action,name,invoke,...)
        local binding=bindings[action]
        if not binding then return false end
        local key=name=="_exit_damage_window" and "exited" or name=="_handle_exit_procs" and "procs"
        if not key then return false end
        if not binding[key] then binding[key]=true;invoke(action,...) end
        return true
    end
    function api.holds_contact(action)
        local binding=bindings[action]
        return binding and binding.open and binding.sticky_settings and action:_is_currently_sticky() or false
    end
    function api.direction(action)
        local binding=bindings[action]
        if binding and (binding.open or binding.flushing) and binding.direction then
            -- Runtime retains scalar world direction, never an engine temporary
            -- vector across frames (including the final saved-contact drain).
            return options.direction_value and options.direction_value(binding.direction) or binding.direction
        end
    end
    function api.finish(action,t,drain)
        local binding=bindings[action]
        if not binding or not binding.open then return false end
        -- Retire first, including if a native callback raises an exception.
        binding.open=false
        local failure
        if drain and action._is_server and not action._unit_data_extension.is_resimulating and
                not action:_is_sweep_aborted(1) and (action._num_saved_entries or 0)>0 then
            local count=action._num_saved_entries
            action._num_saved_entries=0
            binding.flushing=true
            local ok,err=pcall(function()
                assert(binding.direction,"saved physical hits require actual swing direction")
                local results,total=action:_merge_saved_entries({},0,action._saved_entries,count)
                if total>0 then action:_process_sweep_results(t,results,total,action._action_settings,api.direction(action),1) end
            end)
            binding.flushing=false
            if not ok then failure=err end
        end
        -- Cancellation discards queued contacts. A final drain only processes
        -- contacts previously admitted by the moving stroke; no new overlap.
        action._num_saved_entries=0; action._time_before_processing_saved_entries=0
        action._action_sweep_component.sweep_state="after_damage_window"
        -- The final admitted contact may have started a native sticky effect.
        -- Its timed effect continues; it never reopens physical overlap queries.
        if drain and not failure and bindings[action]==binding and action._is_server and
                not action._unit_data_extension.is_resimulating and binding.sticky_settings and action:_is_currently_sticky() then
            binding.open=true;binding.sticky=true;return false,"sticky_continues"
        end
        if binding.sticky_settings and action:_is_currently_sticky() then
            local ok,err=pcall(action._stop_hit_stickyness,action,binding.sticky_settings,true)
            -- Native stop mutates these after its proc callback, which can fail.
            action._action_sweep_component.is_sticky=false;action._current_sticky_armor_type=nil
            if action._movement_state_component then action._movement_state_component.can_jump=true end
            if not ok and not failure then failure=err end
        end
        local ok,err=pcall(function() action:_exit_damage_window(t,action._num_hit_enemies,action:_any_sweep_aborted()) end)
        if not ok and not failure then failure=err end
        ok,err=pcall(function() action:_handle_exit_procs() end)
        if not ok and not failure then failure=err end
        if failure then error(failure,0) end
        return true
    end
    function api.step(action,request)
        local binding=bindings[action]
        if not binding or not binding.open then return false,"unbound" end
        if action._unit_data_extension.is_resimulating or not action._is_server then
            api.finish(action,request.time); return false,"authority_changed"
        end
        if request.stroke_id~=binding.stroke then api.finish(action,request.time);return false,"stroke_changed" end
        if binding.frame==request.frame then return false,"repeated" end
        binding.frame=request.frame
        local function update_sticky()
            binding.sticky=true;action._num_saved_entries=0
            action._action_sweep_component.sweep_state="after_damage_window"
            local dt=request.dt
            if type(dt)~="number" or dt~=dt or dt<=0 or dt>.1 then
                api.finish(action,request.time);return false,"invalid_sticky_step"
            end
            action:_update_hit_stickyness(dt,request.time,action._action_sweep_component,binding.sticky_settings)
            if not action:_is_currently_sticky() then api.finish(action,request.time) end
            return true,"native_sticky"
        end
        if binding.sticky_settings and action:_is_currently_sticky() then return update_sticky() end
        if request.stroke_id~=binding.stroke or not request.active then
            api.finish(action,request.time,request.stroke_id==binding.stroke and request.natural_end==true)
            return false,"stroke_ended"
        end
        if action:_is_sweep_aborted(1) then
            api.finish(action,request.time); return false,"native_abort"
        end
        local segments=request.segments or {request}
        if #segments<1 or #segments>Bridge.max_segments then api.finish(action,request.time); return false,"query_budget" end
        for _,segment in ipairs(segments) do
            if request.before_query then binding.direction=request.before_query(segment) or binding.direction end
            action:_do_overlap(request.time,segment.from_position,segment.from_rotation,
                segment.position,segment.rotation,false,action._action_settings,1)
            if binding.sticky_settings and action:_is_currently_sticky() then return update_sticky() end
            if action:_is_sweep_aborted(1) then api.finish(action,request.time); break end
        end
        return true
    end
    function api.forget(action)
        local binding=bindings[action]
        if binding and binding.open then return false,"finish_before_forget" end
        bindings[action]=nil
        return true
    end
    return api
end
return Bridge
