-- Bounded, session-owned native minions. Never deletes unrelated range units.
local Targets={}
function Targets.new(deps)
    local entries,context={},nil
    local api={}
    local function same(a,b) return a and b and a.unit and b.unit and a.unit==b.unit and a.session==b.session end
    function api.entries() return entries end
    function api.owns(unit)
        if not unit then return nil end
        for _,entry in ipairs(entries) do if entry.unit==unit then return entry end end
    end
    function api.clear(current)
        local retained={}
        for _,entry in ipairs(entries) do
            local same_world=context and current and context.session==current.session
            if same_world and entry.unit and deps.alive(entry.unit) then
                local ok,err=pcall(deps.destroy,entry.unit)
                if not ok then
                    retained[#retained+1]=entry
                    deps.emit('target_cleanup_error',entry.id..':'..tostring(err))
                end
            elseif not same_world then
                deps.emit('target_context_retired',entry.id..':level_owns_teardown')
            end
        end
        entries=retained
        if #entries==0 then context=nil;return true end
        return false,'owned_target_cleanup_pending'
    end
    function api.replace(specs,current)
        assert(current and current.unit and current.session,'target_context_required')
        assert(type(specs)=='table' and #specs>=1 and #specs<=5,'target_count_limit')
        local seen={}
        for _,spec in ipairs(specs) do
            assert(type(spec.id)=='string' and spec.id~='' and not seen[spec.id],'target_identity_required')
            seen[spec.id]=true
        end
        local ok,why=api.clear(current);assert(ok,why)
        context=current
        for _,spec in ipairs(specs) do
            local success,unit=pcall(deps.spawn,spec)
            if not success or not unit then
                api.clear(current)
                error('target_spawn_failed:'..tostring(unit),0)
            end
            if api.owns(unit) then api.clear(current);error('duplicate_native_target',0) end
            entries[#entries+1]={unit=unit,id=spec.id,generation=spec.generation,breed=spec.breed}
        end
        return entries
    end
    function api.capture(current)
        assert(same(context,current),'target_context_changed')
        local snapshots={}
        for _,entry in ipairs(entries) do
            snapshots[#snapshots+1]={unit=entry.unit,id=entry.id,generation=entry.generation,breed=entry.breed,
                context=context,before=deps.health(entry.unit),native_damage=0,hits=0}
        end
        return snapshots
    end
    function api.find(snapshots,unit)
        if not unit then return nil end
        for _,entry in ipairs(snapshots or {}) do if entry.unit==unit then return entry end end
    end
    function api.outcome(snapshot,current)
        local identity=false
        if same(snapshot.context,current) and same(context,current) then
            for _,entry in ipairs(entries) do
                if entry.id==snapshot.id and entry.generation==snapshot.generation and entry.unit==snapshot.unit then identity=true;break end
            end
        end
        local after,source=-1,'unavailable'
        if identity then
            if snapshot.unit and deps.alive(snapshot.unit) then after=deps.health(snapshot.unit) end
            if after>=0 then source='health_extension'
            elseif snapshot.confirmed_native_kill or snapshot.confirmed_zero then
                after=0;source=snapshot.confirmed_native_kill and 'native_kill' or 'observed_zero_before_removal'
            end
        end
        local valid=after>=0 and snapshot.before>=0
        return {before=snapshot.before,after=valid and after or -1,delta=valid and snapshot.before-after or -1,
            valid=valid,source=valid and source or 'unavailable'}
    end
    return api
end
return Targets
