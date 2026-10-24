-- Suspend only native shooting-range enemy loops. Keep their native spawner
-- definitions; restarting those loops restores the usual training targets.
local Isolation={}
local names={"enemies_loop","weak_enemies_loop","medium_enemies_loop","heavy_enemies_loop"}
-- Conservative battle-mode workaround: retire one target at a time, then
-- leave a settling gap after native deletion before touching another.
-- No dissolve effect is started; retirement uses native minion cleanup.
-- This does not establish a fix for the independent stereo renderer crash.
local retire_interval,retire_drain=0.25,4
-- Gate native and Creature Spawner entry points before any default unit exists.
-- Keep empty native step containers so isolation can snapshot/stop the loops;
-- the original functions run normally again when combat ends.
function Isolation.guard_defaults(steps,suppressed,emit)
    for _,name in ipairs(names) do
        local step=steps[name]
        if step and (step.start_func~=step._testlab_guard_start or step.condition_func~=step._testlab_guard_condition or
                step.on_event~=step._testlab_guard_event) then
            local start,condition,on_event=step.start_func,step.condition_func,step.on_event
            step.start_func=function(system,player,scenario,data,t,...)
                if suppressed() then
                    data.units={};data.spawn_datas={};data.enemies={}
                    emit("combat_default_suppressed","loop="..name.." phase=start")
                    return
                end
                if start then return start(system,player,scenario,data,t,...) end
            end
            step.condition_func=function(...)
                if suppressed() then return false end
                if condition then return condition(...) end
                return false
            end
            if on_event then step.on_event=function(...)
                if not suppressed() then return on_event(...) end
            end end
            step._testlab_guard_start=step.start_func
            step._testlab_guard_condition=step.condition_func
            step._testlab_guard_event=step.on_event
        end
    end
end
function Isolation.new(deps)
    local snapshot
    local api={}
    function api.active() return snapshot~=nil end
    local function clear(s)
        local t=deps.time()
        if s.retiring then
            if deps.alive(s.retiring) then return false end
            s.retiring=nil
            s.next_retire=t+retire_interval
        end
        local pending=false
        for unit in pairs(s.owned) do
            if deps.alive(unit) then
                pending=true
            end
        end
        if pending then
            s.drained_at=nil
            if t>=s.next_retire then
                for unit in pairs(s.owned) do
                    if not s.removed[unit] and deps.alive(unit) then
                        deps.retire(unit);s.removed[unit]=true
                        s.retiring=unit
                        s.next_retire=t+retire_interval
                        break -- Never catch up a backlog in a single update.
                    end
                end
            end
            return false
        end
        if s.count==0 then return true end
        s.drained_at=s.drained_at or t+retire_drain
        return t>=s.drained_at
    end
    function api.ready()
        local s=assert(snapshot,"combat_range_not_isolated")
        local current=deps.context()
        assert(current and current.unit==s.context.unit and current.session==s.context.session and
            deps.scenario()==s.system and s.system._current_scenario==s.main,"combat_range_context_changed")
        if clear(s) then return true end
        assert(deps.time()<s.clear_deadline,"combat_range_retirement_timeout")
        return false
    end
    function api.begin(require_empty)
        assert(not snapshot,"combat_range_already_isolated")
        local context=assert(deps.context(),"local Psykhanium required")
        local system=assert(deps.scenario(),"range_scenario_missing")
        assert(type(system.stop_parallel_scenario)=="function" and type(system.start_parallel_scenario)=="function",
            "range_scenario_controls_missing")
        local loops=system._parallel_scenarios and system._parallel_scenarios.shooting_range
        assert(loops,"range_enemy_loops_missing")
        local selected,owned={},{}
        for _,name in ipairs(names) do
            local scenario=loops[name]
            if scenario then
                local data=assert(scenario.scenario_data and scenario.scenario_data.step_data,"range_step_data_missing")
                selected[#selected+1]={name=name,token=scenario}
                for unit in pairs(data.units or {}) do
                    if (type(unit)=="userdata" or type(unit)=="table") and deps.alive(unit) then owned[unit]=true end
                end
                for _,spawn in pairs(data.spawn_datas or {}) do if spawn.unit and deps.alive(spawn.unit) then owned[spawn.unit]=true end end
            end
        end
        assert(#selected>0,"range_enemy_loops_missing")
        -- A separate mod's live trial cannot be reconstructed by restarting
        -- the native range. Refuse before touching it, rather than copy units.
        local registered={}
        for _,unit in pairs(deps.minions()) do
            registered[unit]=true
            assert(not deps.alive(unit) or owned[unit] or deps.allied(context.unit,unit),"finish_other_enemy_trials_before_combat")
        end
        -- Locked-spawner VFX and placeholder entries are not minions.
        for unit in pairs(owned) do if not registered[unit] then owned[unit]=nil end end
        local settings=assert(deps.settings(),"range_settings_missing")
        local count=0
        for unit in pairs(owned) do count=count+1 end
        assert(not require_empty or count==0,"Restart into empty combat mode; normal targets are already present")
        snapshot={context=context,system=system,main=system._current_scenario,loops=selected,settings=settings,
            respawn=settings.cs_enable_training_grounds_respawn,stopped={},owned=owned,removed={},
            next_retire=deps.time(),count=count,
            clear_deadline=deps.time()+math.max(45,count*5+retire_drain)}
        settings.cs_enable_training_grounds_respawn=false
        for _,entry in ipairs(selected) do
            snapshot.stopped[#snapshot.stopped+1]=entry
            system:stop_parallel_scenario("shooting_range",entry.name,deps.time(),false)
        end
        clear(snapshot)
        deps.emit("combat_range_clearing","normal_enemies="..count.." retirement=sequential_native_despawn gap_seconds="..retire_interval)
    end
    local function restore(reason)
        local s=snapshot
        if not s then return true end
        local current=deps.context()
        local same=current and current.unit==s.context.unit and current.session==s.context.session and
                deps.scenario()==s.system and s.system._current_scenario==s.main
        s.settings.cs_enable_training_grounds_respawn=s.respawn
        if same then
            if not clear(s) and reason~="unload" then
                s.settings.cs_enable_training_grounds_respawn=false
                return false
            end
            -- Even a range with continuous respawn disabled gets its original
            -- target set back once. Restore that exact option after spawning.
            s.settings.cs_enable_training_grounds_respawn=true
            -- A partial removal must finish before native loops are restarted,
            -- otherwise the surviving original targets would be duplicated.
            while #s.stopped>0 do
                local entry=s.stopped[1]
                local loops=s.system._parallel_scenarios.shooting_range
                assert(not loops[entry.name] or loops[entry.name]==entry.token,"range_loop_replaced_during_combat")
                if not loops[entry.name] then s.system:start_parallel_scenario("shooting_range",entry.name,deps.time()) end
                table.remove(s.stopped,1)
            end
            if s.respawn~=true and s.count>0 and reason~="unload" then
                s.restore_deadline=s.restore_deadline or deps.time()+5
                local count=0
                for _,unit in pairs(deps.minions()) do
                    if deps.alive(unit) and not deps.allied(current.unit,unit) then count=count+1 end
                end
                if count<s.count and deps.time()<s.restore_deadline then return true end
                if count<s.count then
                    s.settings.cs_enable_training_grounds_respawn=s.respawn;snapshot=nil
                    error("normal_enemy_respawn_timeout",0)
                end
            end
        end
        s.settings.cs_enable_training_grounds_respawn=s.respawn
        snapshot=nil
        deps.emit("combat_range_restored","reason="..tostring(reason).." respawn_original="..tostring(s.respawn))
        return true
    end
    function api.restore(reason)
        local ok,result=pcall(restore,reason)
        if not ok then
            if snapshot then snapshot.settings.cs_enable_training_grounds_respawn=snapshot.respawn end
            error(result,0)
        end
        return result
    end
    return api
end
return Isolation
