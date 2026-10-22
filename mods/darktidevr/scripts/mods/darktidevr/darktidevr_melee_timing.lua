-- Offline timing for an explicitly selected stock attack route. The adapter
-- chooses/validates the route and supplies ActionHandler's effective scale.
local Timing = {}
local function finite(value)
    return type(value) == "number" and value == value and
        value > -math.huge and value < math.huge
end

function Timing.resolve(actions, route, scale_for, inverted_kinds)
    if type(actions) ~= "table" or type(route) ~= "table" or #route == 0 or
            type(scale_for) ~= "function" then
        return nil, "invalid_route"
    end
    local elapsed, destination = 0, nil
    for index, step in ipairs(route) do
        if type(step) ~= "table" then return nil, "invalid_route" end
        local action = actions[step.action]
        local chain = type(action) == "table" and action.allowed_chain_actions and
            action.allowed_chain_actions[step.input]
        if type(chain) ~= "table" or not chain.action_name or not actions[chain.action_name] or
                (index > 1 and destination ~= step.action) then
            return nil, "disconnected_route"
        end
        -- Stock chain_until permits an alternative early window; conditions
        -- and running-state gates require the live handler's own validation.
        if chain.chain_until ~= nil or chain.running_action_state_requirement then
            return nil, "conditional_timing"
        end
        local threshold = chain.chain_time
        if threshold == nil then threshold = 0 end
        -- Relative to this action's entry, accounting for already-held input.
        local input_ready = step.input_ready_after
        if input_ready == nil then input_ready = 0 end
        local scale = scale_for(action)
        if not finite(threshold) or threshold < 0 or not finite(input_ready) or
                input_ready < 0 or not finite(scale) or scale <= 0 then
            return nil, "invalid_timing"
        end
        if scale < 1 and inverted_kinds and inverted_kinds[action.kind] then
            threshold = threshold * scale
        else
            threshold = threshold / scale
        end
        elapsed = elapsed + math.max(threshold, input_ready)
        if not finite(elapsed) then return nil, "invalid_timing" end
        destination = chain.action_name
    end
    if elapsed <= 0 then return nil, "zero_interval" end
    return elapsed, destination
end

-- Resolve a normal cycle from an explicitly observed/validated stock windup.
-- This intentionally rejects chain alternatives and unknown input parsers;
-- callers cannot silently substitute a block cancel or heavy recovery time.
function Timing.from_windup(template, windup_name, scale_for, inverted_kinds, validate)
    local actions = type(template) == "table" and template.actions
    local windup = actions and actions[windup_name]
    if not windup or windup.kind ~= "windup" or type(validate) ~= "function" then
        return nil, "invalid_windup"
    end
    local function destination(name, input, kind)
        local action = actions[name]
        local chain = action and action.allowed_chain_actions and action.allowed_chain_actions[input]
        local target = chain and chain.action_name and actions[chain.action_name]
        if not target or target.kind ~= kind or #chain > 0 or chain.chain_until or
                chain.running_action_state_requirement or not validate(target) then return nil end
        return chain.action_name
    end
    if not validate(windup) then return nil, "unavailable_windup" end
    local light = destination(windup_name,"light_attack","sweep")
    local heavy = destination(windup_name,"heavy_attack","sweep")
    local next_windup = light and destination(light,"start_attack","windup")
    local next_light = next_windup and destination(next_windup,"light_attack","sweep")
    if not light or not heavy or not next_light then return nil, "unsupported_route" end
    local interval, reason = Timing.resolve(actions,{
        {action=light,input="start_attack"},{action=next_windup,input="light_attack"}},
        scale_for,inverted_kinds)
    if not interval then return nil, reason end
    local input = template.action_inputs and template.action_inputs.heavy_attack
    local sequence = input and input.input_sequence
    local hold, release = sequence and sequence[1], sequence and sequence[2]
    if not sequence or #sequence ~= 2 or not hold or not release or
            hold.input ~= "action_one_hold" or hold.value ~= true or
            release.input ~= "action_one_hold" or release.value ~= false or
            not finite(hold.duration) or hold.duration < 0 then
        return nil, "unsupported_heavy_input"
    end
    local charge, charge_reason = Timing.resolve(actions,{
        {action=windup_name,input="heavy_attack",input_ready_after=hold.duration}},
        scale_for,inverted_kinds)
    if not charge then return nil, charge_reason end
    -- Auto-completion is a separate input-parser deadline, not the minimum
    -- heavy threshold or a continuously increasing melee damage multiplier.
    -- This is a fresh-hold lower bound; fixed-step evaluation occurs after it.
    local auto_complete_after
    if release.auto_complete == true and finite(release.time_window) and
            release.time_window >= 0 then
        auto_complete_after = math.max(charge, hold.duration + release.time_window)
    end
    local heavy_windup=destination(heavy,"start_attack","windup")
    local heavy_interval=heavy_windup and Timing.resolve(actions,{
        {action=heavy,input="start_attack"},{action=heavy_windup,input="light_attack"}},scale_for,inverted_kinds)
    return {light_action=light,heavy_action=heavy,next_light_action=next_light,
        next_windup_action=next_windup,
        light_interval=interval,heavy_interval=heavy_interval,heavy_charge=charge,
        heavy_auto_complete_after=auto_complete_after,
        heavy_damage_charge=actions[heavy].use_charge and "module" or "constant_one"}
end

-- Snapshot the explicit ordinary combo graph without inventing an idle entry
-- or a global attack clock. Re-evaluate effective scales when the context changes.
function Timing.light_combo(template, windup_name, scale_for, inverted_kinds, validate, limit)
    limit = limit or 32
    if not finite(limit) or limit < 1 or limit > 128 or limit ~= math.floor(limit) then
        return nil, "invalid_combo_limit"
    end
    local steps, seen, elapsed = {}, {}, 0
    local current = windup_name
    for _=1,limit do
        local previous = seen[current]
        if previous then
            return {steps=steps,cycle_start=previous.index,
                entry_duration=previous.elapsed,cycle_duration=elapsed-previous.elapsed}
        end
        local timing, reason = Timing.from_windup(template,current,scale_for,inverted_kinds,validate)
        if not timing then return nil, reason, current end
        seen[current] = {index=#steps+1,elapsed=elapsed}
        steps[#steps+1] = {windup_action=current,light_action=timing.light_action,
            next_windup_action=timing.next_windup_action,
            next_light_action=timing.next_light_action,interval=timing.light_interval}
        elapsed = elapsed + timing.light_interval
        if not finite(elapsed) then return nil, "invalid_combo_duration", current end
        current = timing.next_windup_action
    end
    local previous = seen[current]
    if previous then
        return {steps=steps,cycle_start=previous.index,
            entry_duration=previous.elapsed,cycle_duration=elapsed-previous.elapsed}
    end
    return nil, "combo_limit", current
end

-- Live native route adapter, shared by the tracked runtime and desktop replay.
-- Does not create actions, cancel animations or relax native conditions.
function Timing.live(extension,slot,t,committed_action)
    local weapon=extension and extension._weapons and extension._weapons[slot]
    local template=weapon and weapon.weapon_template
    local handler=extension and extension._action_handler
    local component=extension and extension._weapon_action_component
    if not finite(t) or not template or not template.actions or not handler or not component or
            type(handler._calculate_time_scale)~="function" or type(handler._validate_action)~="function" or
            type(extension.condition_func_params)~="function" then
        return nil,"native_context_unavailable"
    end
    local name=component.current_action_name
    local current=template.actions[name]
    local windup=current and current.kind=="windup" and name
    if not windup then
        local chain=current and current.allowed_chain_actions and current.allowed_chain_actions.start_attack
        windup=chain and chain.action_name
    end
    if not windup and not current then
        for candidate,settings in pairs(template.actions) do
            if settings.kind=="windup" and settings.start_input=="start_attack" then
                if windup then return nil,"ambiguous_entry" end
                windup=candidate
            end
        end
    end
    local function scale(settings) return handler:_calculate_time_scale(settings) end
    local inverted=handler._action_kinds_with_inverted_timescale
    local result,reason=Timing.from_windup(template,windup,scale,inverted,function() return true end)
    if not result then return nil,reason end
    local params=extension:condition_func_params(slot)
    local time_in_action=t-(component.start_t or t)
    result.ready=handler:_validate_action(template.actions[windup],params,t,time_in_action,nil) and
        handler:_validate_action(template.actions[result.light_action],params,t,time_in_action,nil)
    -- Seconds until the chain window opens (0 when ready), nil when unknown.
    result.ready_in=result.ready and 0 or nil
    if current and current.kind~="windup" then
        local chain=current.allowed_chain_actions and current.allowed_chain_actions.start_attack
        if not chain or chain.chain_until or chain.running_action_state_requirement or #chain>0 then result.ready=false;result.ready_in=nil
        else
            local factor=scale(current)
            if not finite(factor) or factor<=0 then return nil,"invalid_timing" end
            local threshold=chain.chain_time or 0
            if not finite(threshold) or threshold<0 then return nil,"invalid_timing" end
            threshold=factor<1 and inverted and inverted[current.kind] and threshold*factor or threshold/factor
            result.ready_in=result.ready_in and math.max(0,threshold-time_in_action)
            result.ready=result.ready and time_in_action>=threshold
        end
    end
    local instance=weapon.actions and weapon.actions[result.light_action]
    local settings=template.actions[result.light_action]
    local uses_matrix=instance and instance._uses_matrix_data
    if uses_matrix==nil then uses_matrix=type(settings.sweeps)=="table" and #settings.sweeps>0 end
    result.uses_matrix_data=uses_matrix
    result.windup_action=windup
    result.heavy_ready=result.heavy_interval~=nil and current and current.kind=="windup" and
        time_in_action>=result.heavy_charge and
        handler:_validate_action(template.actions[result.heavy_action],params,t,time_in_action,nil) or false
    if committed_action then
        local committed=template.actions[committed_action]
        local chain=committed and committed.allowed_chain_actions and committed.allowed_chain_actions.start_attack
        if chain then
            result.recovery_interval=Timing.resolve(template.actions,{
                {action=committed_action,input="start_attack"},{action=chain.action_name,input="light_attack"}},scale,inverted)
        end
    end
    return result
end

-- Only recognize the inspected stock parser shape. Never synthesize a named
-- action directly; its own validation and stamina check still run afterward.
function Timing.defense(extension,slot,t)
    local weapon=extension._weapons and extension._weapons[slot]
    local template=weapon and weapon.weapon_template
    local inputs=template and template.action_inputs or {}
    local block=inputs.block and inputs.block.input_sequence
    local push=inputs.push and inputs.push.input_sequence
    if not block or #block~=1 or block[1].input~="action_two_hold" or block[1].value~=true then
        return {supported=false,push_ready=false}
    end
    local component=extension._weapon_action_component
    local current=component and template.actions[component.current_action_name]
    local chain=current and current.kind=="block" and current.allowed_chain_actions and current.allowed_chain_actions.push
    local target=chain and template.actions[chain.action_name]
    local ready=push and #push==1 and push[1].input=="action_one_pressed" and
        push[1].hold_input=="action_two_hold" and push[1].value==true and
        target and target.kind=="push" and not chain.chain_until and not chain.running_action_state_requirement and #chain==0
    if ready then
        local handler=extension._action_handler
        local factor=handler:_calculate_time_scale(current)
        local threshold=chain.chain_time or 0
        if not finite(factor) or factor<=0 or not finite(threshold) or threshold<0 then ready=false
        else
            local inverted=handler._action_kinds_with_inverted_timescale
            threshold=factor<1 and inverted and inverted[current.kind] and threshold*factor or threshold/factor
            ready=t-(component.start_t or t)>=threshold and
                handler:_validate_action(target,extension:condition_func_params(slot),t,t-(component.start_t or t),nil)
        end
    end
    return {supported=true,push_ready=ready==true,push_action=target and chain.action_name}
end
-- Resolve the native push chord and recovery, without starting its action or
-- overriding validation. Unknown conditional/parser shapes remain unavailable.
function Timing.follow_up(extension,slot,t,push_name)
    local weapon=extension._weapons and extension._weapons[slot]
    local template=weapon and weapon.weapon_template
    local actions=template and template.actions
    local push=actions and actions[push_name]
    local chain=push and push.kind=="push" and push.allowed_chain_actions and push.allowed_chain_actions.push_follow_up
    local target=chain and actions[chain.action_name]
    local input=template and template.action_inputs and template.action_inputs.push_follow_up
    local sequence=input and input.input_sequence
    local step=sequence and sequence[1]
    if not target or target.kind~="sweep" or #chain>0 or chain.chain_until or chain.running_action_state_requirement or
            not sequence or #sequence~=1 or step.input~="action_one_hold" or step.hold_input~="action_two_hold" or
            step.value~=true or not finite(step.duration) or step.duration<0 then return nil,"unsupported_push_followup" end
    local handler=extension._action_handler
    local inverted=handler._action_kinds_with_inverted_timescale
    local component=extension._weapon_action_component
    local parser=handler._action_input_extension
    if not parser or type(parser.peek_next_input)~="function" then return nil,"native_push_parser_unavailable" end
    local queued=parser:peek_next_input("weapon_action")=="push_follow_up"
    local function scale(settings)
        if settings==push and component.current_action_name==push_name and component.time_scale then return component.time_scale end
        return handler:_calculate_time_scale(settings)
    end
    local open,reason=Timing.resolve(actions,{{action=push_name,input="push_follow_up",input_ready_after=step.duration}},scale,inverted)
    if not open then return nil,reason end
    local factor=scale(push)
    local total=push.total_time
    if not finite(total) or total<=0 or not finite(factor) or factor<=0 then return nil,"invalid_push_duration" end
    local close=factor<1 and inverted and inverted[push.kind] and total*factor or total/factor
    local next_chain=target.allowed_chain_actions and target.allowed_chain_actions.start_attack
    local interval=next_chain and Timing.resolve(actions,{{action=chain.action_name,input="start_attack"},
        {action=next_chain.action_name,input="light_attack"}},scale,inverted)
    if not interval or open>=close then return nil,"unsupported_push_recovery" end
    local elapsed=t-(component.start_t or t)
    return {push_action=push_name,chain=chain,action=chain.action_name,settings=target,
        open_after=open,close_after=close,interval=interval,input_queued=queued,
        ready=component.current_action_name==push_name and elapsed>=open and elapsed<close and
            queued and handler:_validate_action(target,extension:condition_func_params(slot),t,elapsed,nil) or false}
end
local animation_cache={}
local shape_cache=setmetatable({}, {__mode="k"})
local function normalized_path(points)
    if type(points)~="table" or #points<2 then return nil end
    local distances,total={0},0
    for index,point in ipairs(points) do
        if type(point)~="table" or not finite(point[1]) or not finite(point[2]) or not finite(point[3]) then return nil end
        if index>1 then
            local previous=points[index-1]
            total=total+math.sqrt((point[1]-previous[1])^2+(point[2]-previous[2])^2+(point[3]-previous[3])^2)
            distances[index]=total
        end
    end
    if not finite(total) or total<1e-6 then return nil end
    local result,segment={},2
    for sample=0,7 do
        local distance=total*sample/7
        while segment<#points and distances[segment]<distance do segment=segment+1 end
        local before,after=points[segment-1],points[segment]
        local span=distances[segment]-distances[segment-1]
        local alpha=span>0 and (distance-distances[segment-1])/span or 0
        local point={}
        for axis=1,3 do point[axis]=(before[axis]+(after[axis]-before[axis])*alpha-points[1][axis])/total end
        result[#result+1]=point
    end
    return result
end
local function animation_path(template,settings,loader)
    local sweeps=settings.sweeps
    if type(sweeps)~="table" or #sweeps~=1 then return nil end
    local path=sweeps[1].matrices_data_location
    if type(path)~="string" then return nil end
    local box=settings.weapon_box or template.weapon_box
    if type(box)~="table" or not finite(box[3]) or box[3]<=0 then return nil end
    local cached=shape_cache[settings]
    if cached and cached.path==path and cached.start==settings.damage_window_start and
            cached.stop==settings.damage_window_end and cached.length==box[3] then return cached.points,cached.reach,cached.bounds end
    local data=animation_cache[path]
    if data==nil then
        local ok,value=pcall(loader,path)
        data=ok and type(value)=="table" and value or false
        animation_cache[path]=data
    end
    if not data then return nil end
    local times={}
    for time in pairs(data) do if not finite(time) then return nil end;times[#times+1]=time end
    if #times<2 then return nil end
    table.sort(times)
    local start,stop=settings.damage_window_start,settings.damage_window_end
    if not finite(start) or not finite(stop) or stop<=start then return nil end
    local function nearest(time)
        local result=1
        for index=2,#times do if math.abs(times[index]-time)<math.abs(times[result]-time) then result=index end end
        return result
    end
    local first,last=nearest(start),nearest(stop)
    local offset=box[3]*2
    local points={}
    for index=first,last do
        local matrix=data[times[index]]
        if type(matrix)~="table" then return nil end
        for _,slot in ipairs({9,10,11,13,14,15}) do if not finite(matrix[slot]) then return nil end end
        points[#points+1]={matrix[13]+matrix[9]*offset,matrix[14]+matrix[10]*offset,matrix[15]+matrix[11]*offset}
    end
    local normalized=normalized_path(points)
    -- The furthest the authored tip gets from the first-person origin, and
    -- the tip's bounds over the damage window (x right, y forward, z up).
    local reach=0
    local bounds={math.huge,-math.huge,math.huge,-math.huge,math.huge,-math.huge}
    for _,point in ipairs(points) do
        reach=math.max(reach,math.sqrt(point[1]^2+point[2]^2+point[3]^2))
        for axis=1,3 do
            bounds[axis*2-1]=math.min(bounds[axis*2-1],point[axis]);bounds[axis*2]=math.max(bounds[axis*2],point[axis])
        end
    end
    if normalized then shape_cache[settings]={path=path,start=start,stop=stop,length=box[3],points=normalized,reach=reach,bounds=bounds} end
    return normalized,normalized and reach or nil,normalized and bounds or nil
end
-- The authored tip path of one sweep action, 8 points from the origin over
-- unit length in its first-person axes, the tip's furthest distance from the
-- first-person origin (the attack's reach), and the tip's bounds
-- {xmin,xmax,ymin,ymax,zmin,zmax} over the damage window, or nil.
function Timing.authored_path(template,settings,loader)
    if type(template)~="table" or type(settings)~="table" then return nil end
    return animation_path(template,settings,loader or dofile)
end
-- A weapon input the stock parser has queued and not yet consumed. Pressing
-- again while one waits would only replace or drop it.
function Timing.input_queued(extension)
    local handler=extension and extension._action_handler
    local parser=handler and handler._action_input_extension
    if not parser or type(parser.peek_next_input)~="function" then return false end
    local ok,queued=pcall(parser.peek_next_input,parser,"weapon_action")
    return ok and queued~=nil
end
-- Match authored weapon-tip paths in the same body-local axes as the weighted
-- stroke. Translation, reach and sampling rate do not bias damage selection.
-- Only ordinary stock light/heavy routes enter this set; never special/push.
function Timing.match_trajectory(extension,slot,t,points,heavy,held_for,loader)
    local weapon=extension._weapons and extension._weapons[slot]
    local template=weapon and weapon.weapon_template
    local handler=extension._action_handler
    local observed=normalized_path(points)
    if not observed or not template or type(template.actions)~="table" or not handler then return nil,"invalid_trajectory" end
    local plans,seen={},{}
    local params=extension:condition_func_params(slot)
    local elapsed=t-(extension._weapon_action_component.start_t or t)
    for windup,settings in pairs(template.actions) do
        if settings.kind=="windup" then
            local plan=Timing.from_windup(template,windup,function(action) return handler:_calculate_time_scale(action) end,
                handler._action_kinds_with_inverted_timescale,function() return true end)
            local name=plan and (heavy and plan.heavy_action or plan.light_action)
            local target=name and template.actions[name]
            -- Native shield slams are sweep actions but explicitly push-directed.
            -- They belong to the shield shove, not a weapon-hand swing match.
            if target and target.attack_direction_override~="push" and not seen[name] and handler:_validate_action(settings,params,t,elapsed,nil) and
                    handler:_validate_action(target,params,t,elapsed,nil) then
                seen[name]=true
                plans[#plans+1]={action=name,settings=target,interval=heavy and plan.heavy_interval or plan.light_interval,
                    charge=heavy and plan.heavy_charge or 0}
            end
        end
    end
    table.sort(plans,function(a,b) return a.action<b.action end)
    local selected,best
    for _,plan in ipairs(plans) do
        if not finite(plan.interval) or plan.interval<=0 then return nil,"unsupported_selected_recovery" end
        local authored=animation_path(template,plan.settings,loader or dofile)
        -- With one legal attack there is no trajectory choice to disambiguate.
        if not authored and #plans>1 then return nil,"animation_trajectory_unavailable" end
        local score,mirror_score=0,0
        if authored then
            for index=1,8 do for axis=1,3 do
                score=score+(observed[index][axis]-authored[index][axis])^2
                local mirrored=axis==1 and -authored[index][axis] or authored[index][axis]
                mirror_score=mirror_score+(observed[index][axis]-mirrored)^2
            end end
        end
        plan.mirrored=mirror_score+1e-9<score
        if plan.mirrored then score=mirror_score end
        -- Prefer an equally close actual animation over a mirrored fallback.
        if not best or score+1e-9<best or math.abs(score-best)<=1e-9 and selected.mirrored and not plan.mirrored then
            selected=plan;best=score
        end
    end
    if not selected then return nil,"no_native_trajectory_candidate" end
    if heavy and (not finite(held_for) or held_for<selected.charge) then return nil,"selected_heavy_not_charged" end
    selected.score=best;selected.kind=heavy and "heavy" or "light"
    return selected
end
return Timing
