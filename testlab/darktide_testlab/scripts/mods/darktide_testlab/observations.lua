-- Read-only native attack/proc boundaries. Returned damage may be prediction;
-- only valid health/toughness samples describe an observed resource change.
local Observations={}
local function pack(...) return {n=select('#',...),...} end
local function delta(a,b,key)
    local first,last=a and a[key],b and b[key]
    if type(first)=='number' and type(last)=='number' and first>=0 and last>=0 and
            first<math.huge and last<math.huge then return first-last,true end
    return -1,false
end
function Observations.new(deps)
    local api={}
    local proc_inflight=setmetatable({}, {__mode='k'})
    local buff_inflight=setmetatable({}, {__mode='k'})
    local function seed(random)
        local ok,value=pcall(function() return random and random.seed and random:seed() end)
        return ok and value or 'unavailable'
    end
    local function read(context,unit)
        local ok,value=pcall(deps.read,context,unit)
        return ok and type(value)=='table' and value or {}
    end
    local function identity(context,unit)
        local ok,value=pcall(deps.identity,context,unit)
        return ok and value or 'unavailable'
    end
    function api.attack(invoke,context,target,profile,...)
        local args=pack(...)
        local metadata,attacker={}
        for i=1,args.n,2 do
            local key,value=args[i],args[i+1]
            if key=='attacking_unit' then attacker=value end
            if key=='attack_type' or key=='damage_type' or key=='is_critical_strike' or key=='target_index' or
                    key=='target_number' or key=='hit_zone_name' or key=='power_level' or key=='charge_level' then metadata[key]=value end
        end
        local record={kind='native_attack',target=identity(context,target),attacker=identity(context,attacker),
            incoming=target==context.unit,before=read(context,target),metadata=metadata,
            profile=type(profile)=='table' and (profile.name or 'unnamed_native_profile') or tostring(profile)}
        local result=pack(invoke(target,profile,...)) -- exact original args, exactly once
        record.after=read(context,target);record.damage_return=result[1];record.result=result[2]
        record.stagger=result[4];record.weakspot=result[5]
        record.health_delta,record.health_valid=delta(record.before,record.after,'health')
        record.toughness_delta,record.toughness_valid=delta(record.before,record.after,'toughness')
        record.stamina_delta,record.stamina_valid=delta(record.before,record.after,'stamina')
        pcall(deps.report,context,record)
        return unpack(result,1,result.n)
    end
    function api.proc(invoke,context,extension,event,params,...)
        local previous=proc_inflight[extension]
        local pending=previous
        while pending do
            if pending.event==event and pending.params==params then return invoke(extension,event,params,...) end
            pending=pending.previous
        end
        local record={kind='native_proc_queue',event=tostring(event),owner=identity(context,extension._unit),
            extension_class=tostring(extension.__class_name or 'unavailable'),
            attacker=identity(context,params and params.attacking_unit),target=identity(context,params and params.attacked_unit),
            result=params and params.attack_result,damage=params and params.damage,actual_damage=params and params.actual_damage_dealt,
            critical=params and params.is_critical_strike,before_count=extension._num_proc_events}
        proc_inflight[extension]={event=event,params=params,previous=previous}
        local result=pack(pcall(invoke,extension,event,params,...))
        proc_inflight[extension]=previous
        if not result[1] then error(result[2],0) end
        record.after_count=extension._num_proc_events
        record.queued=type(record.before_count)=='number' and type(record.after_count)=='number' and record.after_count>record.before_count
        pcall(deps.report,context,record)
        return unpack(result,2,result.n)
    end
    function api.buff_proc(invoke,context,buff,t,events,count,random,local_random,...)
        if buff_inflight[buff] then return invoke(buff,t,events,count,random,local_random,...) end
        local record={kind='native_buff_proc',owner=identity(context,buff._unit),
            template=tostring(buff._template and buff._template.name or 'unavailable'),
            buff_class=tostring(buff.__class_name or 'unavailable'),time=t,event_count=count,
            seed_before=seed(random),local_seed_before=seed(local_random)}
        buff_inflight[buff]=true
        local result=pack(pcall(invoke,buff,t,events,count,random,local_random,...))
        buff_inflight[buff]=nil
        if not result[1] then error(result[2],0) end
        record.activated=result[2]==true;record.events={};record.total=0;record.truncated=false
        record.events_known=type(result[3])=='table'
        -- Native ProcBuff reuses this map. Snapshot scalars before the next
        -- buff clears it, and return the original map without alteration.
        if record.events_known then
            local copied=0
            for name,number in pairs(result[3]) do
                if copied>=64 then record.truncated=true;break end
                copied=copied+1
                if type(name)=='string' and type(number)=='number' and number>0 and number<math.huge then
                    record.events[name]=number;record.total=record.total+number
                end
            end
        end
        record.seed_after=seed(random);record.local_seed_after=seed(local_random)
        if record.activated or record.total>0 then pcall(deps.report,context,record) end
        return unpack(result,2,result.n)
    end
    return api
end
return Observations
