-- Shared physical melee owner. Producers supply body-local device OR replay
-- poses; presentation reads snapshots. Only native action instances can query
-- combat. The adapter owns world mapping, readiness and native cancellation.
local Runtime={}
-- DMF may load this file under different mod aliases. Share the lease through
-- Mods so a replay and the device adapter cannot author the same player.
local root=Mods or _G
root.darktidevr_physical_owners=root.darktidevr_physical_owners or setmetatable({}, {__mode="k"})
local owners=root.darktidevr_physical_owners
function Runtime.owner(unit) return owners[unit] end
function Runtime.claim_source(unit,token)
    assert(unit and token and not owners[unit],"another melee pose producer owns this player")
    owners[unit]=token
end
function Runtime.release_source(unit,token) if owners[unit]==token then owners[unit]=nil end end
function Runtime.is_followup_chain(extension,weapon,handler,chain)
    if not extension or handler~=extension._action_handler then return false end
    local component=extension._weapon_action_component
    local settings=component and weapon.weapon_template.actions[component.current_action_name]
    local native=settings and settings.kind=="push" and settings.allowed_chain_actions and settings.allowed_chain_actions.push_follow_up
    if not native then return false end
    if native==chain then return true end
    for _,entry in ipairs(native) do if entry==chain then return true end end
    return false
end
local function tip(pose,offset)
    local p,q=pose.position,pose.rotation
    local x,y,z=offset[1]*2,offset[2]*2,offset[3]*2
    local tx=2*(q[2]*z-q[3]*y)
    local ty=2*(q[3]*x-q[1]*z)
    local tz=2*(q[1]*y-q[2]*x)
    return {p[1]+x+q[4]*tx+q[2]*tz-q[3]*ty,
        p[2]+y+q[4]*ty+q[3]*tx-q[1]*tz,p[3]+z+q[4]*tz+q[1]*ty-q[2]*tx}
end
function Runtime.new(deps,options)
    assert(not Runtime.owner(options.unit),"another melee pose producer owns this player")
    assert(options.source=="synthetic" or options.source=="tracking","explicit pose source required")
    assert(type(options.to_world)=="function" and type(options.cancel_native)=="function","world mapping and native cancellation required")
    local owner,strokes=assert(options.owner),assert(options.strokes)
    local bridge
    local defense=assert(deps.Defense,"shared defense recognizer required").new()
    local state={suppressed=setmetatable({}, {__mode="k"})}
    local api={source=options.source}
    local function emit(kind,data)
        if options.emit then
            local ok,err=pcall(options.emit,kind,data)
            if not ok then state.log_error=tostring(err) end
        end
    end
    local function capture_world(pose)
        local p,q=options.to_world(pose)
        if not p or not q then return nil end
        local value=options.freeze_world and options.freeze_world(p,q) or {position=p,rotation=q}
        local snapshot=deps.Planner.trajectory(value,value)
        return snapshot and snapshot.last
    end
    local function world_components(pose)
        if options.world_components then return options.world_components(pose) end
        return pose.position,pose.rotation
    end
    bridge=deps.Bridge.new({native_events=options.native_events==true,direction_value=function(value)
        return world_components({position=value,rotation={0,0,0,1}})
    end})
    local function finish_action(t)
        local action=state.action
        local authoring=state.authoring or action~=nil or state.pending~=nil or state.heavy~=nil
        state.authoring=false
        state.action=nil; state.pending=nil; state.pulse=nil; state.release=nil; state.push_frame=nil
        state.tether=nil
        state.heavy=nil; state.follow=nil; state.follow_active=nil; state.follow_release=nil
        state.native_entry=nil
        state.native_input=nil
        if action then
            local ok,err=pcall(bridge.finish,action,t)
            if not ok then emit("native_finish_error",{reason=tostring(err)}) end
        end
        if state.time and authoring then
            local ok,err=pcall(options.cancel_native,t)
            if not ok then emit("native_cancel_error",{reason=tostring(err)}) end
        end
    end
    local function constrain_sticky(action,pose)
        if not options.sticky_frame then return pose end
        if not action or not bridge.holds_contact(action) then state.tether=nil;return pose end
        local measurements={}
        local ok,constrained,reason=pcall(function()
            local frame=options.sticky_frame(action)
            if not frame then return nil,"sticky_target_lost" end
            state.tether=state.tether or deps.Tether.attach(frame,pose)
            local target,why=deps.Tether.resolve(state.tether,frame)
            if not target then return nil,why end
            local raw=deps.Planner.trajectory(pose.raw_dominant,target)
            local virtual=deps.Planner.trajectory(pose,target)
            measurements.raw_distance=raw.translation;measurements.raw_angle=raw.angle
            measurements.virtual_distance=virtual.translation;measurements.virtual_angle=virtual.angle
            local result,detail=owner.pin(target)
            if result then emit("sticky_constraint",{target=tostring(frame.target),node=frame.node,frame=pose.frame}) end
            return result,detail
        end)
        if not ok then
            state.failed=true;reason="sticky_constraint_error"
            emit(reason,{reason=tostring(constrained)})
        end
        if not ok or not constrained then
            reason=reason or "sticky_constraint_failed"
            measurements.reason=reason
            api.invalidate(reason);emit("sticky_release",measurements)
            return nil,reason
        end
        return constrained
    end
    function api.invalidate(reason)
        if state.closed then return end
        strokes.invalidate(); state.current=nil; state.frame=nil; state.pose_epoch={}
        state.previous=nil;state.previous_sample=nil;state.previous_body=nil;state.previous_time=nil
        state.world_direction=nil;state.direction=nil
        defense.reset(); state.defense=nil; state.block_output=nil; state.block_held=false
        owner.reset()
        finish_action(state.time)
        emit("invalidate",{reason=reason})
    end
    function api.sample(request)
        if state.closed then return nil,"closed" end
        if state.failed then return nil,"native_query_failed" end
        request=request or {}
        if request.source~=options.source then api.invalidate("source_changed"); return nil,"source_changed" end
        if request.tracking_valid~=true or request.reference==nil or request.active~=true or
                not options.extension._weapons or options.extension._weapons[options.slot]~=options.weapon then
            api.invalidate("context_unavailable"); return nil,"context_unavailable"
        end
        if state.frame==request.frame and state.reference==request.reference and state.time==request.time then
            return state.current,false
        end
        if not state.adopted and options.cancel_on_adopt then
            local ok,err=pcall(options.cancel_native,request.time)
            if not ok then
                emit("native_cancel_error",{reason=tostring(err)}); api.invalidate("native_cancel_failed")
                return nil,"native_cancel_failed"
            end
            state.adopted=true
        end
        local ok,timing,reason=pcall(deps.Timing.live,options.extension,options.slot,request.time,state.committed_action)
        if not ok then reason=tostring(timing); timing=nil end
        if timing and state.action and bridge.holds_contact(state.action) then timing.ready=false;timing.heavy_ready=false end
        local shield_guard=deps.Defense.guard_role(options.weapon.weapon_template)=="support"
        local virtual,why=owner.update({dominant=request.dominant,support=request.support,
            support_held=request.support_held and not shield_guard,tracking_valid=true,reference=request.reference,
            time=request.pose_time or request.time,frame=request.frame,recovery=strokes.status().recovery})
        if not virtual then api.invalidate(why); return nil,why end
        if virtual.reset then
            finish_action(request.time); strokes.invalidate(); state.pose_epoch={}
            defense.reset()
        end
        virtual,why=constrain_sticky(state.action,virtual)
        if not virtual then return nil,why end
        local defensive=deps.Timing.defense(options.extension,options.slot,request.time)
        local component=options.extension._weapon_action_component
        -- Guard uses the same independent shield grip as presentation.
        local guard_raw=shield_guard and request.support or request.dominant
        local guard_virtual=shield_guard and (virtual.support or virtual.raw_support) or virtual
        if shield_guard and not request.support then guard_raw=nil; guard_virtual=nil end
        state.defense=defense.update({raw=guard_raw,virtual=guard_virtual,
            intent=(request.guarding==true or request.pose_block==true and not state.heavy) and defensive.supported,
            pose_only=request.pose_block==true and request.guarding~=true,
            push_ready=defensive.push_ready,frame=request.frame,time=request.time})
        -- A deliberately queued push follow-up must be allowed to leave the
        -- guard pose. Its trigger, native parser and native window still gate it.
        local guarding=request.guarding==true or request.pose_block==true and (state.defense.blocking or state.follow~=nil)
        if state.follow and request.frame>state.follow.frame then
            local follow=state.follow
            local plan=deps.Timing.follow_up(options.extension,options.slot,request.time,follow.plan.push_action)
            if request.followup_intent~=true or not guarding or not plan or
                    component.current_action_name~=plan.push_action or
                    follow.start_t and follow.start_t~=component.start_t or
                    request.time-(component.start_t or request.time)>=plan.close_after then
                state.follow=nil; state.follow_release=request.frame; strokes.invalidate()
                emit("followup_cancel",{time=request.time,reason="input_native_context_or_window"})
            else follow.plan=plan; follow.start_t=component.start_t end
        end
        if state.defense.push then
            state.push_frame=request.frame
            if request.followup_intent==true then
                local plan,detail=deps.Timing.follow_up(options.extension,options.slot,request.time,defensive.push_action)
                if plan then state.follow={plan=plan,frame=request.frame}; state.follow_release=nil
                else emit("followup_unavailable",{reason=detail}) end
            end
            emit("push",{time=request.time,source=options.source,authority="native_input"})
        end
        if timing and not state.offset then
            local volume,detail=deps.Volume.resolve(options.weapon.weapon_template,{},options.defaults,timing.uses_matrix_data)
            if not volume then reason=detail; timing=nil else state.offset=volume.offset end
        end
        local offset=state.offset or {0,0,0}
        local heavy_button=request.heavy_intent==true and not guarding
        if state.heavy and (not heavy_button or not timing or
                timing.heavy_action~=state.heavy.action or
                timing.heavy_auto_complete_after and request.time-state.heavy.start>=timing.heavy_auto_complete_after-.1) then
            finish_action(request.time); strokes.invalidate()
            emit("charge_cancel",{time=request.time,reason="released_context_or_deadline"})
        end
        if heavy_button and not state.heavy_button and timing and timing.ready and timing.heavy_interval and
                strokes.status().remaining<=0 and not virtual.reset then
            state.heavy={start=request.time,frame=request.frame,action=timing.heavy_action}
            emit("charge_start",{time=request.time,action=timing.heavy_action,source=options.source})
        end
        state.heavy_button=heavy_button
        local charged=state.heavy~=nil
        local following=state.follow~=nil
        local interval=timing and (strokes.status().remaining>0 and timing.recovery_interval or
            charged and timing.heavy_interval or timing.light_interval)
        if following and strokes.status().remaining<=0 then interval=state.follow.plan.interval end
        local status=strokes.update({point=tip(virtual,offset),raw_point=tip(request.dominant,offset),
            raw_support_point=virtual.support_engaged and request.support and tip(request.support,offset) or nil,
            time=request.time,frame=request.frame,interval=interval,weapon=options.weapon,mode="physical",
            reference=state.pose_epoch,tracking_valid=true,
            intent=request.intent and (following or charged or not heavy_button or
                not charged and strokes.status().collision_allowed),
            guarding=guarding and not following and not (state.follow_active and strokes.status().collision_allowed),
            native_ready=following and state.follow.plan.ready or not following and timing and
                (charged and timing.heavy_ready or not heavy_button and timing.ready)})
        if status.suppressed_candidate then emit("suppressed_candidate",status.suppressed_candidate) end
        if status.committed then
            local selected,selection_error
            if not following then
                selected,selection_error=deps.Timing.match_trajectory(options.extension,options.slot,request.time,
                    status.trajectory,charged,charged and request.time-state.heavy.start or 0,options.load_animation)
            end
            if not following and not selected then
                finish_action(request.time);strokes.invalidate()
                status=strokes.status()
                emit("trajectory_rejected",{reason=selection_error,time=request.time})
            else
            state.pending=status.stroke_id; state.commit_time=request.time; state.pulse=request.frame; state.release=nil
            state.native_entry=not following and (charged and timing.heavy_action or timing.light_action) or nil
            state.native_input=not following and (charged and "heavy_attack" or "light_attack") or nil
            state.committed_action=following and state.follow.plan.action or selected.action
            if selected then
                assert(strokes.reserve_interval(selected.interval),"selected native recovery reservation failed")
                status=strokes.status()
                status.committed=true
                emit("trajectory_selected",{action=selected.action,kind=selected.kind,score=selected.score,
                    mirrored=selected.mirrored,interval=selected.interval})
            end
            if charged then state.heavy=nil; state.pulse=nil; state.release=request.frame end
            if following then state.pulse=nil end
            emit("stroke",{id=status.stroke_id,interval=interval,action=state.committed_action,intent_hand=status.intent_hand,
                time=request.time,source=options.source})
            end
        end
        if reason~=state.reason then emit("availability",{reason=reason}); state.reason=reason end
        local blocking=state.defense.blocking or state.follow~=nil
        state.block_output={held=blocking,pressed=blocking and not state.block_held,
            released=not blocking and state.block_held==true}
        state.block_held=blocking
        local world=capture_world(virtual)
        if not world then api.invalidate("world_mapping_unavailable");return nil,"world_mapping_unavailable" end
        state.previous_sample=not virtual.reset and state.current or nil
        state.frame=request.frame; state.reference=request.reference; state.time=request.time
        state.authoring=true
        local support=virtual.support or virtual.raw_support
        state.current={pose=virtual,world=world,world_support=support and capture_world(support),stroke=status,timing=timing,offset=offset,source=options.source,
            frame=request.frame,time=request.time,pose_time=request.pose_time or request.time}
        return state.current,true
    end
    function api.inputs(frame)
        if type(frame)~="number" or frame~=frame or frame<0 or frame~=math.floor(frame) then
            return {pressed=false,held=false,released=false}
        end
        if state.heavy then return {pressed=state.heavy.frame==frame,held=true,released=false} end
        if state.follow then return {pressed=state.push_frame==frame,held=true,released=false} end
        local pressed=state.pulse==frame or state.push_frame==frame
        if state.pulse and frame>state.pulse and not state.release then state.release=frame end
        return {pressed=pressed,held=pressed,released=state.release==frame or state.follow_release==frame or
            state.push_frame and frame==state.push_frame+1 or false}
    end
    function api.block_inputs(frame)
        local current=state.current and state.current.frame==frame and state.block_output
        return current or {pressed=false,held=false,released=false}
    end
    function api.allow_chain(handler,chain,t)
        if not Runtime.is_followup_chain(options.extension,options.weapon,handler,chain) then return true end
        return state.current~=nil and state.follow~=nil and state.pending~=nil and state.follow.plan.ready and
            strokes.status().collision_allowed and state.committed_action==chain.action_name and
            t>=state.commit_time and t-state.commit_time<=.15 or false
    end
    function api.select_chain(handler,chain,t,_,_,actions)
        if handler~=options.extension._action_handler or actions~=options.weapon.weapon_template.actions or
                not state.pending or not state.native_input or
                t<state.commit_time or t-state.commit_time>.15 or not strokes.status().collision_allowed then return chain end
        -- The stock combo may have reset or advanced since the stroke was
        -- committed. Admit only the actual live windup's matching input edge,
        -- rather than comparing its destination with a cached combo entry.
        local component=options.extension._weapon_action_component
        local windup=component and actions[component.current_action_name]
        local edge=windup and windup.kind=="windup" and windup.allowed_chain_actions and
            windup.allowed_chain_actions[state.native_input]
        local matches=edge==chain
        if type(edge)=="table" and not matches then
            for _,entry in ipairs(edge) do if entry==chain then matches=true;break end end
        end
        if not matches then return chain end
        local target=actions[state.committed_action]
        local original=actions[chain.action_name]
        if not target or not original or target.kind~="sweep" or original.kind~="sweep" then return chain end
        -- Copy this one transition, never the shared template. The native
        -- validator still checks its timing, state gates and selected action.
        local selected={}
        for key,value in pairs(chain) do selected[key]=value end
        selected.action_name=state.committed_action
        return selected
    end
    function api.latest() return state.current end
    function api.current_action() return state.action end
    function api.owns(action) return state.suppressed[action]~=nil end
    function api.on_start(action,settings,t)
        if not state.current or action._player_unit~=options.unit or action._weapon~=options.weapon or
                action._unit_data_extension.is_resimulating then return false end
        state.suppressed[action]=true
        action._action_sweep_component.sweep_state="during_damage_window"
        local status=strokes.status()
        if state.pending and status.stroke_id==state.pending and status.collision_allowed and
                t>=state.commit_time and t-state.commit_time<=.15 and
                action._weapon_action_component.current_action_name==state.committed_action then
            local ok,reason=bridge.bind(action,state.pending)
            if ok then
                state.action=action; state.pending=nil; state.query_frame=nil
                if state.follow then
                    state.follow=nil; state.follow_active=action; state.follow_release=state.frame+1
                end
                state.direction=nil;state.world_direction=nil
                local previous=state.previous_sample
                state.previous=previous and previous.world;state.previous_body=previous and previous.pose
                state.previous_time=previous and previous.pose_time
            end
            emit("context",{accepted=ok,reason=reason,action=action._weapon_action_component.current_action_name,
                time=t,start_time=action._weapon_action_component.start_t,authored_start=settings.damage_window_start,
                scale=action._weapon_action_component.time_scale,lightning=settings.weapon_chain_lightning_template or false,
                special_at_start=action._weapon_action_component.special_active_at_start})
        else emit("context",{accepted=false,reason="no_live_committed_stroke",
            pending=state.pending,stroke_id=status.stroke_id,collision_allowed=status.collision_allowed,
            committed_action=state.committed_action,native_action=action._weapon_action_component.current_action_name,
            commit_age=state.commit_time and t-state.commit_time}) end
        return true
    end
    local function update_sweep(action,dt,t,settings)
        if not state.suppressed[action] then return false end
        local current=state.current
        if not current or state.action~=action then bridge.finish(action,t); return true end
        if state.query_frame==current.frame then return true end
        state.query_frame=current.frame
        local pose=current.pose
        -- Both endpoints are scalar WORLD snapshots captured in their own
        -- simulation frames. Reprojecting old body poses through today's anchor
        -- erases locomotion and can sweep a path the weapon never occupied.
        local trajectory=deps.Planner.trajectory(state.previous or current.world,current.world)
        local body_trajectory=deps.Planner.trajectory(state.previous_body or pose,pose)
        local volume=deps.Volume.resolve(options.weapon.weapon_template,settings,options.defaults,action._uses_matrix_data)
        local plan=trajectory and volume and deps.Planner.make({current_valid=true,previous_valid=true,
            dt=state.previous_time and current.pose_time-state.previous_time or dt,translation=trajectory.translation,
            angle=trajectory.angle,radius=volume.corner_radius},
            {max_gap=.1,max_translation=.5,arc_step=.06,max_segments=deps.Bridge.max_segments})
        local segments={}
        if plan and plan.reset and plan.reason=="discontinuity" then
            emit("query_rejected",{reason="world_discontinuity"})
            api.invalidate("world_discontinuity");return true
        end
        if plan and not plan.reset then
            for i=1,plan.segments do
                local first=deps.Planner.pose_at(trajectory,(i-1)/plan.segments)
                local last=deps.Planner.pose_at(trajectory,i/plan.segments)
                local a,ar=world_components(first)
                local b,br=world_components(last)
                if not a or not ar or not b or not br then
                    bridge.finish(action,t); emit("query_rejected",{reason="world_mapping_unavailable"}); return true
                end
                local ta,tb=tip(first,current.offset),tip(last,current.offset)
                local delta={tb[1]-ta[1],tb[2]-ta[2],tb[3]-ta[3]}
                local length=math.sqrt(delta[1]^2+delta[2]^2+delta[3]^2)
                local direction=length>1e-8 and {delta[1]/length,delta[2]/length,delta[3]/length} or nil
                local body_first=deps.Planner.pose_at(body_trajectory,(i-1)/plan.segments)
                local body_last=deps.Planner.pose_at(body_trajectory,i/plan.segments)
                local ba,bb=tip(body_first,current.offset),tip(body_last,current.offset)
                local bd={bb[1]-ba[1],bb[2]-ba[2],bb[3]-ba[3]}
                local bl=math.sqrt(bd[1]^2+bd[2]^2+bd[3]^2)
                segments[#segments+1]={from_position=a,from_rotation=ar,position=b,rotation=br,
                    direction=direction,body_direction=bl>1e-8 and {bd[1]/bl,bd[2]/bl,bd[3]/bl} or nil}
            end
        else emit("query_rejected",{reason=plan and plan.reason or "invalid_geometry",
            angle=trajectory and trajectory.angle,radius=volume and volume.corner_radius,
            required_segments=plan and plan.required_segments,max_segments=deps.Bridge.max_segments})
            if plan and plan.reason=="query_budget" then
                -- Drop only the unsafe history, not the live stroke. This is
                -- a stationary overlap at its real current weighted pose,
                -- never a coarsened sweep across the missing arc.
                local p,q=world_components(current.world)
                if p and q then segments[1]={from_position=p,from_rotation=q,position=p,rotation=q} end
            end
        end
        bridge.step(action,{time=t,dt=dt,frame=current.frame,stroke_id=strokes.status().stroke_id,
            active=strokes.status().collision_allowed,natural_end=current.stroke.reason=="sample",segments=segments,before_query=function(segment)
                if segment.body_direction then state.direction=segment.body_direction end
                if segment.direction then
                    state.world_direction=segment.direction
                end
                return state.world_direction
            end})
        if not constrain_sticky(action,pose) then return true end
        -- A contact may pin the shared pose after the query. Ordinary frames
        -- retain the exact world snapshot already used by their segments.
        if pose.constrained then
            local world=capture_world(pose)
            if not world then api.invalidate("world_mapping_unavailable");return true end
            current.world=world
            local support=pose.support or pose.raw_support
            current.world_support=support and capture_world(support)
        end
        state.previous=current.world;state.previous_body=pose;state.previous_time=current.pose_time
        return true
    end
    function api.update_sweep(...)
        local ok,handled=pcall(update_sweep,...)
        if not ok then
            state.failed=true
            api.invalidate("native_query_error");emit("native_query_error",{reason=tostring(handled)})
            return true
        end
        return handled
    end
    function api.claim(action,target)
        return state.action==action and state.current~=nil and
            (strokes.status().collision_allowed or bridge.flushing(action)) and bridge.claim(action,target)
    end
    function api.body_direction(action) if state.action==action and state.current then return state.direction end end
    function api.world_direction(action) if state.action==action and state.current then return bridge.direction(action) end end
    function api.native_event(action,name,invoke,...)
        return bridge.native_event(action,name,function(native,...)
            local data={event=name,stage="entered",time=state.time,
                action=native._weapon_action_component and native._weapon_action_component.current_action_name}
            emit("native_lifecycle",data)
            invoke(native,...)
            emit("native_lifecycle",{event=name,stage="completed",time=state.time,action=data.action})
        end,...)
    end
    function api.impact(aborted)
        local retention=aborted and .1 or .55
        if state.closed or not state.current or not owner.latest() then return false,retention end
        return owner.contact(retention),retention
    end
    function api.on_finish(action,t)
        if not state.suppressed[action] then return false end
        bridge.finish(action,t); state.suppressed[action]=nil
        if state.action==action then state.action=nil end
        if state.follow_active==action then state.follow_active=nil end
        return true
    end
    function api.after_finish(action) bridge.forget(action) end
    function api.close()
        if state.closed then return end
        api.invalidate("closed"); state.closed=true; owner.close()
        Runtime.release_source(options.unit,api)
    end
    Runtime.claim_source(options.unit,api)
    return api
end
return Runtime
