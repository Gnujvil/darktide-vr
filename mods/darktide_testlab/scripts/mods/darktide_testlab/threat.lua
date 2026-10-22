-- Temporary local-range attack episode. Native perception/combat remain in
-- charge; this never synthesizes damage or edits perception components.
local Threat={}
local visibility='tg_player_unperceivable'
local flags={'cs_enable_training_grounds_invisibility','cs_enable_training_grounds_invulnerability'}
local function same(a,b) return a and b and a.unit and a.unit==b.unit and a.session==b.session end
function Threat.new(deps)
    local state={phase='idle'}
    local api={}
    local function emit(kind,detail,s) pcall(deps.emit,kind,detail,s and s.id) end
    function api.status() return state.phase end
    function api.restore(reason)
        local s=state.snapshot
        if not s then return true end
        state.phase='restoring'
        local failures={}
        local function attempt(label,fn)
            local ok,err=pcall(fn)
            if not ok then failures[#failures+1]=label..':'..tostring(err) end
        end
        -- Restore the persistent in-memory cache even after owner/level loss.
        -- No mod:set or account/backend operation is used.
        for _,key in ipairs(flags) do s.settings[key]=s.flags[key] end
        if same(s.context,deps.world()) and deps.alive(s.context.unit) then
            attempt('invulnerability',function()
                s.health:set_invulnerable(s.invulnerable)
                assert(s.health._is_invulnerable==s.invulnerable,'invulnerability_restore_unverified')
            end)
            if deps.scenario()==s.scenario and s.scenario._current_scenario==s.scenario_token then
                attempt('visibility',function()
                    local present=not not s.scenario:has_scenario_buff(s.context.unit,visibility)
                    if s.hidden and not present then s.scenario:add_scenario_buff(s.context.unit,visibility,deps.game_time())
                    elseif not s.hidden and present then s.scenario:remove_scenario_buff(s.context.unit,visibility) end
                    assert((not not s.scenario:has_scenario_buff(s.context.unit,visibility))==s.hidden,'visibility_restore_unverified')
                end)
            else emit('threat_context_retired','scenario owns old visibility teardown',s) end
        else emit('threat_context_retired','old player/level owns native teardown',s) end
        attempt('owned_attacker_cleanup',function() local ok,why=deps.cleanup();assert(ok,why) end)
        if #failures>0 then
            state.phase='restore_failed';state.retry=deps.now()+.25
            emit('threat_restore_error',table.concat(failures,';'),s);return false,'threat_restoration_pending'
        end
        state.snapshot=nil;state.phase='idle'
        emit('threat_restored','reason='..tostring(reason)..' run='..s.context.run..
            ' visibility_original='..tostring(s.flags[flags[1]])..' visibility_restored='..tostring(s.settings[flags[1]])..
            ' invulnerability_original='..tostring(s.flags[flags[2]])..' invulnerability_restored='..tostring(s.settings[flags[2]])..
            ' native_invulnerability_original='..tostring(s.invulnerable)..' scenario_hidden_original='..tostring(s.hidden),s)
        return true
    end
    function api.begin(seconds,id)
        assert(state.phase=='idle','threat_busy')
        local context=assert(deps.context(),'active_physical_run_required')
        assert(type(seconds)=='number' and seconds>=1 and seconds<=(context.manual and 120 or 12),'threat_duration_out_of_range')
        local owned=deps.owned()
        assert(#owned==1 and owned[1].breed=='chaos_poxwalker','one_owned_poxwalker_required')
        local unit=owned[1].unit;assert(unit and deps.alive(unit),'owned_attacker_missing')
        local minions=assert(deps.minions(),'native_minion_inventory_unavailable')
        local count,found=0,false
        for _,other in pairs(minions) do
            count=count+1;assert(count<=128,'native_minion_inventory_limit')
            local allied=other~=unit and deps.allied and deps.allied(context.unit,other)==true
            if other~=unit and deps.alive(other) and deps.describe then
                local ok,detail=pcall(deps.describe,other)
                emit(allied and 'threat_allied_minion' or 'threat_foreign_minion',ok and detail or tostring(detail),{id=id})
            end
            assert(other==unit or allied or not deps.alive(other),'foreign_minions_prevent_isolated_episode')
            if other==unit then found=true end
        end
        assert(found,'owned_attacker_not_in_native_inventory')
        local health=assert(deps.health(context.unit),'native_health_unavailable')
        assert(type(health._is_invulnerable)=='boolean' and type(health.set_invulnerable)=='function' and
            type(health.is_invulnerable)=='function' and type(health.current_health)=='function','native_health_capability_missing')
        local scenario=assert(deps.scenario(),'native_scenario_unavailable')
        assert(scenario._current_scenario and type(scenario.has_scenario_buff)=='function' and
            type(scenario.add_scenario_buff)=='function' and type(scenario.remove_scenario_buff)=='function','native_scenario_capability_missing')
        local creature=assert(deps.creature(),'creature_spawner_unavailable')
        local settings=assert(creature.settings,'creature_settings_unavailable')
        local perception=assert(deps.perception(unit),'native_perception_unavailable')
        assert(type(perception.alert)=='function' and type(perception.aggro)=='function' and
            type(perception.force_new_target_attempt)=='function' and type(perception.aggro_state)=='function' and
            type(perception.is_perception_disabled)=='function','native_perception_capability_missing')
        assert(not perception:is_perception_disabled(),'native_perception_disabled')
        local s={context=context,id=id,settings=settings,flags={},health=health,invulnerable=health._is_invulnerable,
            scenario=scenario,scenario_token=scenario._current_scenario,hidden=not not scenario:has_scenario_buff(context.unit,visibility),
            health_start=health:current_health(),perception=perception,attacker=unit,attacker_health=deps.health(unit),deadline=deps.now()+seconds}
        assert(s.health_start>0,'player_health_unavailable')
        for _,key in ipairs(flags) do s.flags[key]=settings[key] end
        state.snapshot=s;state.phase='arming'
        local ok,err=pcall(function()
            for _,key in ipairs(flags) do settings[key]=false end
            health:set_invulnerable(false)
            assert(not health:is_invulnerable(),'effective_invulnerability_remaining')
            if s.hidden then scenario:remove_scenario_buff(context.unit,visibility) end
            assert(not scenario:has_scenario_buff(context.unit,visibility),'player_still_unperceivable')
            perception:alert(context.unit,true);perception:aggro();perception:force_new_target_attempt()
            assert(perception:aggro_state()=='aggroed','native_aggro_unverified')
        end)
        if not ok then api.restore('arm_failed');error(err,0) end
        state.phase='active'
        emit('threat_armed','run='..context.run..' seconds='..seconds..' target='..owned[1].id..' aggro=aggroed health_start='..s.health_start,s)
    end
    function api.update()
        local s=state.snapshot
        if not s then return end
        if state.phase=='restore_failed' then if deps.now()>=state.retry then api.restore('retry') end;return end
        local current=deps.context()
        local reason
        if not same(s.context,current) or current.run~=s.context.run then reason='context_changed'
        elseif deps.scenario()~=s.scenario or s.scenario._current_scenario~=s.scenario_token then reason='scenario_changed'
        elseif not deps.alive(current.unit) or s.health:current_health()<=s.health_start*.5 then reason='health_budget'
        elseif not deps.alive(s.attacker) or s.attacker_health and s.attacker_health:current_health()<=0 then reason='attacker_removed'
        elseif deps.now()>=s.deadline then reason='timeout' end
        if reason then
            -- Retire replay and record its final target state before destroying
            -- the owned attacker. Always restore even if final reporting fails.
            pcall(deps.finish,s.context,reason)
            if state.snapshot==s then api.restore(reason) end
        end
    end
    return api
end
return Threat
