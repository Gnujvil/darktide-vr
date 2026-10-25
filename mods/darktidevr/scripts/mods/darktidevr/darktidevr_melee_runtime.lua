-- Shared physical melee owner. Producers supply body-local device OR replay
-- poses; presentation reads snapshots. Only native action instances can query
-- combat. The adapter owns world mapping, readiness and native cancellation.
local Runtime={}
-- Seconds ahead of a chain window that a stock attack press is still
-- buffered by the native parser rather than dropped.
Runtime.STOCK_BUFFER=.25
-- Stock contact mode: a stroke reaching the same enemy as the previous press,
-- before the server has started that press (the combo has not moved on), is
-- the same swing seen twice, not a second attack (worn 22 October).
Runtime.DUPLICATE_WINDOW=.5
-- A contact found further along the swing than its attack's press-to-damage
-- time waits: pressed at once, the damage would land before the weapon
-- arrives (user, 23 October). PRESS_SLACK: how early a press may still go,
-- one probe slice; ARM_WAIT: how long a swing may wait to arrive.
Runtime.PRESS_SLACK,Runtime.ARM_WAIT=.05,.8
-- Walking with an arm-pump locomotion (VR StrideS; user, 23 October: a jog
-- read as slow swings). While the character moves at STRIDE_WALK m/s or more,
-- a stroke whose weapon hand moves slower than STRIDE_FAST m/s while the other
-- hand swings the opposite way (cosine at most STRIDE_COS) at STRIDE_MATCH or
-- more of its speed is a stride, not an attack. A fast swing always attacks
-- (user: sometimes you swing hard while walking). Measured over STRIDE_WINDOW
-- from samples already taken, so no swing waits for it.
Runtime.STRIDE_WALK,Runtime.STRIDE_FAST,Runtime.STRIDE_COS,Runtime.STRIDE_MATCH,Runtime.STRIDE_WINDOW=.5,2.5,-.5,.5,.08
-- Off (worn-8, 24 October: 63 swings held as strides; user: "too sensitive").
-- Every stroke still logs stride_match, whether the filter would have held it.
Runtime.STRIDE_FILTER=false
-- A native lock-in (a revved chainsword sawing) keeps the weapon in its target
-- for the native sticky time, through a swing's follow-through. Only a pull
-- of the real hand this far from the locked weapon yanks it out early.
Runtime.STICKY_HOLD=.9
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
    -- A second hand's runtime (dual weapons) leases its own key: it presses
    -- stock attacks only and never owns an action, so it may share the player.
    local lease=options.lease or options.unit
    assert(options.lease==nil or options.authority=="stock","only a stock runtime may take a second lease")
    assert(not Runtime.owner(lease),"another melee pose producer owns this player")
    assert(options.source=="synthetic" or options.source=="tracking","explicit pose source required")
    assert(type(options.to_world)=="function" and type(options.cancel_native)=="function","world mapping and native cancellation required")
    local owner,strokes=assert(options.owner),assert(options.strokes)
    -- "stock": a remote (or mission) server runs the attack from stock
    -- input alone. A stroke is one attack press; the stock parser, combo,
    -- timing, sweep and damage decide the rest, so nothing here may own an
    -- action, rewrite a chain or cancel one the server would keep running.
    local stock=options.authority=="stock"
    -- Stock contact mode: a stroke arms, and presses as soon as an enemy lies
    -- on its weapon's way (the look-ahead, deps.Contact); a stroke that
    -- reaches none is a whiff and sends nothing. options.trigger "swing"
    -- presses every stroke instead. Either way a press is aimed at the first
    -- enemy on its way, when there is one.
    local seeking=stock and type(options.contact)=="function"
    local contact_mode=seeking and options.trigger~="swing"
    assert(not seeking or deps.Contact,"contact mode requires the contact look-ahead")
    assert(stock or options.authority==nil or options.authority=="physical","unknown melee authority")
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
        state.armed=nil
        -- Locally the charge is stopped outright. A server's charge ends when
        -- the attack input stops being held, as the stock button's does.
        state.authoring=false
        state.action=nil; state.pending=nil; state.pulse=nil; state.release=nil; state.push_frame=nil
        state.tether=nil
        state.heavy=nil; state.follow=nil; state.follow_active=nil; state.follow_release=nil
        state.native_entry=nil; state.interrupting=nil
        state.native_input=nil
        if action then
            local ok,err=pcall(bridge.finish,action,t)
            if not ok then emit("native_finish_error",{reason=tostring(err)}) end
        end
        if state.time and authoring and not stock then
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
            if not result and detail=="constraint_separation" and raw.translation<=Runtime.STICKY_HOLD then
                -- Past the inertia's lag cap the solver keeps following the
                -- hand; the weapon shown and swept stays in the target.
                local held={}
                for key,value in pairs(pose) do held[key]=value end
                held.position={target.position[1],target.position[2],target.position[3]}
                held.rotation={target.rotation[1],target.rotation[2],target.rotation[3],target.rotation[4]}
                held.constrained=true;held.held=true
                if state.held_action~=action then
                    state.held_action=action
                    emit("sticky_hold",{target=tostring(frame.target),node=frame.node,frame=pose.frame,raw_distance=raw.translation})
                end
                return held
            end
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
        state.history=nil;state.backfill=nil;state.hand_trail=nil;state.stride_hold=nil
        state.world_direction=nil;state.direction=nil
        defense.reset(); state.defense=nil; state.block_output=nil; state.block_held=false
        owner.reset()
        finish_action(state.time)
        emit("invalidate",{reason=reason})
    end
    -- The weapon-tip path a stroke travelled since onset, in the world, and
    -- the attack it starts: the online orientation follows that path.
    local function aim_commit(onset,virtual,offset,data)
        if not options.on_commit then return end
        local points={}
        -- Each sample's hand pose through the current world mapping: the
        -- stroke's path relative to the character, without its locomotion
        -- since the onset (PC run moveA, 24 October: a swing back against a
        -- 4 m/s run left a world path too short to aim; a strafe skewed it).
        for _,sample in ipairs(state.history or {}) do
            if onset and sample.time>=onset then
                points[#points+1]=tip(sample.pose and capture_world(sample.pose) or sample.world,sample.offset)
            end
        end
        local now=capture_world(virtual)
        if now then points[#points+1]=tip(now,offset) end
        data.points=points
        local ok,err=pcall(options.on_commit,data)
        if not ok then emit("gesture_aim_error",{reason=tostring(err)}) end
    end
    -- Both hands' raw positions over the last moments, for the stride check.
    local function track_hands(request)
        local d=request.dominant and request.dominant.position
        local s=request.support and request.support.position
        if type(d)~="table" or type(request.time)~="number" then return end
        local trail=state.hand_trail or {}
        state.hand_trail=trail
        trail[#trail+1]={time=request.time,d={d[1],d[2],d[3]},s=type(s)=="table" and {s[1],s[2],s[3]} or nil}
        while #trail>2 and request.time-trail[1].time>.3 do table.remove(trail,1) end
    end
    -- A stroke's motion: walking speed, weapon-hand speed, and how the other
    -- hand moves against it (cos -1: exactly opposite; ratio: its speed share).
    local function stride(request)
        local trail=state.hand_trail
        local now=trail and trail[#trail]
        local result={walk=tonumber(request.walk_speed) or 0}
        if not now then return result end
        local before
        for index=#trail-1,1,-1 do
            if now.time-trail[index].time>=Runtime.STRIDE_WINDOW then before=trail[index];break end
        end
        if not before then return result end
        local span=now.time-before.time
        local vd={(now.d[1]-before.d[1])/span,(now.d[2]-before.d[2])/span,(now.d[3]-before.d[3])/span}
        result.hand=math.sqrt(vd[1]^2+vd[2]^2+vd[3]^2)
        if not now.s or not before.s or result.hand<1e-6 then return result end
        local vs={(now.s[1]-before.s[1])/span,(now.s[2]-before.s[2])/span,(now.s[3]-before.s[3])/span}
        local other=math.sqrt(vs[1]^2+vs[2]^2+vs[3]^2)
        result.ratio=other/result.hand
        result.cos=other>1e-6 and (vd[1]*vs[1]+vd[2]*vs[2]+vd[3]*vs[3])/(result.hand*other) or 0
        result.stride_match=result.walk>=Runtime.STRIDE_WALK and result.hand<Runtime.STRIDE_FAST and
            result.ratio>=Runtime.STRIDE_MATCH and result.cos<=Runtime.STRIDE_COS
        result.stride=Runtime.STRIDE_FILTER and result.stride_match
        return result
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
        if not state.adopted and options.cancel_on_adopt and not stock then
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
            defense.reset(); state.history=nil
        end
        virtual,why=constrain_sticky(state.action,virtual)
        -- A released contact has already ended its stroke; sampling resumes
        -- next frame. The third value tells the caller the source still works.
        if not virtual then return nil,why,not state.failed end
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
            local template=options.weapon.weapon_template
            local volume,detail=deps.Volume.resolve(template,{},options.defaults,timing.uses_matrix_data)
            -- A template without its own box keeps one per attack (the
            -- crowbar; PC run fastL, 22 October: invalid_box, no swings): the
            -- next light attack's box gives the weapon's tip.
            if not volume and template.actions and template.actions[timing.light_action] then
                volume,detail=deps.Volume.resolve(template,template.actions[timing.light_action],options.defaults,timing.uses_matrix_data)
            end
            if not volume then reason=detail; timing=nil else state.offset=volume.offset end
        end
        local offset=state.offset or {0,0,0}
        local heavy_button=request.heavy_intent==true and not guarding
        if stock and state.heavy and (request.heavy_intent~=true or not timing) then
            -- Stock (user, 22 October): the trigger is the attack button. Let
            -- go and the server's own input rules fire the charge: a heavy
            -- once charged, a light if tapped. A swing only releases sooner.
            -- Block does not let go: held with block the server cancels the
            -- charge itself (stock attack_cancel); a release there would fire.
            state.heavy=nil; state.release=request.frame
            if state.armed and state.armed.charged then state.armed=nil end
            emit("charge_release",{time=request.time,reason=timing and "let_go" or "context"})
        elseif not stock and state.heavy and (not heavy_button or not timing or
                timing.heavy_action~=state.heavy.action or
                timing.heavy_auto_complete_after and request.time-state.heavy.start>=timing.heavy_auto_complete_after-.1) then
            finish_action(request.time); strokes.invalidate()
            emit("charge_cancel",{time=request.time,reason="released_context_or_deadline"})
        end
        if stock and heavy_button and not state.heavy and timing and timing.heavy_interval and
                request.frame>(state.release or -2)+1 and request.frame>(state.pulse or -2)+1 then
            -- A held stock button keeps charging: pressed mid-attack it waits
            -- in the server's buffer, and after a release (a swing, or the
            -- server's auto-complete) it charges again, two frames let go.
            state.heavy={start=request.time,frame=request.frame,action=timing.heavy_action}
            emit("charge_start",{time=request.time,action=timing.heavy_action,source=options.source})
        elseif not stock and heavy_button and not state.heavy_button and timing and timing.ready and timing.heavy_interval and
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
        -- No attack cooldown: a new swing at stroke speed interrupts this
        -- runtime's own light attack, never a block, push, special or charge.
        local interrupt=not stock and not following and not charged and not heavy_button and timing and not timing.ready and
            state.action~=nil and component.current_action_name==state.committed_action
        -- Stock: press while the parser can still buffer it for the next chain
        -- window, and never on top of an input it has not consumed yet.
        local buffered=stock and timing and (timing.ready or timing.ready_in and timing.ready_in<=Runtime.STOCK_BUFFER) and
            not deps.Timing.input_queued(options.extension)
        -- The weapon's way ahead, its attack's press-to-damage time or
        -- Contact.WAY if longer, probed for the first enemy it meets
        -- (deps.Contact); nil when nothing is reached.
        local function look_ahead(action,heavy)
            local now=capture_world(virtual)
            local previous
            -- The motion carried on from 20 ms back: a swing accelerates, and an
            -- older baseline predicts its contact late (user, 22 October:
            -- fast swings' hits lagged the weapon).
            for index=#(state.history or {}),1,-1 do
                local sample=state.history[index]
                if request.time-sample.time>=.02 then previous=sample;break end
            end
            if not now or not previous or not timing or not action then
                state.seek=not previous and "no_history" or not action and "no_action" or "no_pose"; return nil
            end
            local settings=options.weapon.weapon_template.actions[action]
            local ok,scale=pcall(options.extension._action_handler._calculate_time_scale,options.extension._action_handler,settings)
            -- Plus the windup's own wait before the attack may chain.
            local windup=timing.windup_action and options.weapon.weapon_template.actions[timing.windup_action]
            local chain=windup and windup.allowed_chain_actions and windup.allowed_chain_actions[heavy and "heavy_attack" or "light_attack"]
            local wait=(timing.ready_in or 0)+(not heavy and chain and tonumber(chain.chain_time) or 0)/(ok and scale or 1)
            local delay=deps.Contact.horizon(settings,ok and scale or 1,wait)
            local horizon=deps.Contact.way(delay)
            -- The hand's motion carries the weapon as it is held now; the
            -- weapon's own lag spin is not continued (see Contact.path).
            local hand=request.dominant and previous.raw_world and capture_world(request.dominant)
            local poses=hand and deps.Contact.path(previous.raw_world,hand,request.time-previous.time,horizon,now) or
                deps.Contact.path(previous.world,now,request.time-previous.time,horizon)
            local queried,result=pcall(options.contact,{poses=poses or {now},action=action,time=request.time,horizon=horizon})
            if not queried then emit("gesture_contact_error",{reason=tostring(result)});return nil end
            -- Diagnostics: why the latest probe found nothing (see candidate_dropped).
            state.seek=result and "hit" or (poses and "clear" or "no_path")..":"..#(poses or {}).."@"..string.format("%.2f",horizon)
            -- When the weapon gets there (poses are evenly spaced over the way,
            -- the first being now), against when a press now would land. Timed
            -- by the blade as drawn when it reaches the same enemy on this way:
            -- the attack's box can run 0.3-0.5 s of swing past it (pass 7, 23
            -- October: a crowbar's damage before its blade arrived). An enemy
            -- only the box reaches keeps the box's time.
            if type(result)=="table" then
                local count=poses and #poses or 1
                local step=tonumber(result.step) or 1
                if count>1 and result.unit~=nil then
                    local drawn,blade=pcall(options.contact,{poses=poses,action=action,time=request.time,horizon=horizon,visual=true})
                    if drawn and type(blade)=="table" and blade.unit==result.unit and tonumber(blade.step) then
                        step=math.max(step,tonumber(blade.step)); result.blade=true
                    else result.blade=false end
                end
                result.ahead=count>1 and math.max(0,step-1)*horizon/(count-1) or 0
                result.delay=delay
            end
            return result
        end
        track_hands(request)
        -- The grips themselves, for the stroke's hand-travel gate (see Strokes).
        local function grip(pose) return pose and pose.position and {pose.position[1],pose.position[2],pose.position[3]} or nil end
        local status=strokes.update({point=tip(virtual,offset),raw_point=tip(request.dominant,offset),
            hand_point=grip(request.dominant),support_hand_point=virtual.support_engaged and grip(request.support) or nil,
            raw_support_point=virtual.support_engaged and request.support and tip(request.support,offset) or nil,
            time=request.time,frame=request.frame,interval=interval,weapon=options.weapon,mode="physical",
            reference=state.pose_epoch,tracking_valid=true,
            -- A held stock trigger never resets the swing between charges; the
            -- swing simply waits until the charge can be released.
            intent=request.intent and (following or charged or not heavy_button or stock or
                not charged and strokes.status().collision_allowed),
            guarding=guarding and not following and not (state.follow_active and strokes.status().collision_allowed),
            native_ready=following and state.follow.plan.ready or not following and timing and
                (charged and timing.heavy_ready or not heavy_button and (stock and buffered or not stock and (timing.ready or interrupt)))})
        if status.suppressed_candidate then emit("suppressed_candidate",status.suppressed_candidate) end
        if status.dropped and status.dropped~=state.dropped then
            state.dropped=status.dropped
            local d=status.dropped
            emit("candidate_dropped",{speed=string.format("%.2f",d.speed),coherence=string.format("%.2f",d.coherence),
                travel=string.format("%.3f",d.travel),path=string.format("%.3f",d.path),
                duration=string.format("%.3f",d.duration),stop_speed=d.stop_speed,seek=state.seek or "none",restarted=d.restarted==true})
        end
        -- Every stroke's motion is logged; a stride presses nothing (the stroke
        -- still runs out in the detector, so the next real swing is not held up).
        -- A stroke commits as its hand speeds up, before a hard swing is fast:
        -- a held stride that crosses STRIDE_FAST is committed then (PC fixture,
        -- 23 October: hard pumps measured 1.5-2.4 m/s at their commit).
        local motion,late=nil,false
        if status.committed and stock and not following then
            motion=stride(request)
            state.stride_hold=motion.stride and status.stroke_id or nil
        elseif state.stride_hold then
            local current=strokes.status()
            if not stock or following or current.stroke_id~=state.stride_hold or not current.collision_allowed then
                state.stride_hold=nil
            else
                local now=stride(request)
                if now.hand and now.hand>=Runtime.STRIDE_FAST then motion=now;late=true;state.stride_hold=nil end
            end
        end
        local function motion_fields(fields)
            if motion then
                fields.walk=string.format("%.2f",motion.walk); fields.hand=motion.hand and string.format("%.2f",motion.hand) or "nil"
                fields.cos=motion.cos and string.format("%.2f",motion.cos) or "nil"
                fields.ratio=motion.ratio and string.format("%.2f",motion.ratio) or "nil"
                fields.stride_match=motion.stride_match==true
            end
            return fields
        end
        if motion and motion.stride then
            emit("stroke_filtered",motion_fields({id=status.stroke_id,time=request.time,reason="stride"}))
        end
        if late then emit("stroke_released",motion_fields({id=status.stroke_id,time=request.time,reason="fast"})) end
        if status.committed and not (motion and motion.stride) or late then
            local selected,selection_error
            -- The running attack chains straight into this one; see select_chain.
            if interrupt then state.interrupting=true; emit("interrupt",{time=request.time,action=state.committed_action}) end
            if not following and stock then
                -- The server picks the attack by its own combo order.
                selected={action=charged and timing.heavy_action or timing.light_action,
                    interval=charged and timing.heavy_interval or timing.light_interval,kind=charged and "heavy" or "light"}
                if not selected.interval then selected=nil;selection_error="stock_interval_unavailable" end
            elseif not following then
                selected,selection_error=deps.Timing.match_trajectory(options.extension,options.slot,request.time,
                    status.trajectory,charged,charged and request.time-state.heavy.start or 0,options.load_animation)
            end
            if not following and not selected then
                finish_action(request.time);strokes.invalidate()
                status=strokes.status()
                emit("trajectory_rejected",{reason=selection_error,time=request.time})
            else
            local arming=contact_mode and not following
            state.pending=status.stroke_id; state.commit_time=request.time; state.pulse=not arming and request.frame or nil; state.release=nil
            state.native_entry=not following and (charged and timing.heavy_action or timing.light_action) or nil
            state.native_input=not following and (charged and "heavy_attack" or "light_attack") or nil
            state.committed_action=following and state.follow.plan.action or selected.action
            if selected then
                -- A released stride's recovery has already started to run down.
                assert(strokes.reserve_interval(selected.interval) or late,"selected native recovery reservation failed")
                status=strokes.status()
                status.committed=true
                if not stock then
                    emit("trajectory_selected",{action=selected.action,kind=selected.kind,score=selected.score,
                        mirrored=selected.mirrored,interval=selected.interval})
                end
            end
            if charged and not arming then state.heavy=nil; state.pulse=nil; state.release=request.frame end
            if following then state.pulse=nil end
            emit("stroke",motion_fields({id=status.stroke_id,interval=interval,action=state.committed_action,intent_hand=status.intent_hand,
                time=request.time,source=options.source,authority=stock and "stock" or "physical",
                hand_travel=status.hand_travel and string.format("%.3f",status.hand_travel) or nil}))
            if arming then
                local path=status.trajectory
                local direction=type(path)=="table" and #path>=2 and
                    {path[#path][1]-path[1][1],path[#path][2]-path[1][2],path[#path][3]-path[1][3]} or nil
                state.armed={action=state.committed_action,charged=charged,time=request.time,onset=status.onset,active=request.time,
                    direction=direction,start_t=component.start_t}
                emit("gesture_armed",{action=state.committed_action,time=request.time})
            elseif stock then
                local hit=seeking and not following and look_ahead(state.committed_action,charged) or nil
                if hit then
                    state.reach={unit=hit.unit,action=state.committed_action,time=request.time,deadline=request.time+.8,heavy=charged}
                    emit("gesture_contact",{action=state.committed_action,zone=hit.zone,step=hit.step,time=request.time,lead=0})
                end
                aim_commit(status.onset,virtual,offset,{action=state.committed_action,heavy=charged,
                    follow_up=following,time=request.time,target=hit and hit.position,target_unit=hit and hit.unit,
                    delay=hit and hit.delay})
            end
            end
        end
        -- A press buffered behind a running attack that then ended without
        -- starting it was dropped (PC run valH2, 23 October: an activated
        -- thunderhammer's hit ended its swing, and the retry swing was refused
        -- as that press's duplicate). It guards nothing.
        local last_press=state.last_press
        if stock and last_press and last_press.behind then
            local name=component.current_action_name
            if not name or name=="none" then state.last_press=nil
            elseif component.start_t~=last_press.start_t then last_press.behind=nil end
        end
        local armed=state.armed
        if armed then
            local active=strokes.status().collision_allowed
            if active then armed.active=request.time end
            local hit=look_ahead(armed.action,armed.charged)
            -- The same swing seen twice, into the same enemy within the window:
            -- the previous press not yet started by the server (a second press
            -- would queue a second attack), or the swing carrying on the same
            -- way. A back-swing is a new attack (review, 22 October).
            local last=state.last_press
            local d=last and last.direction and armed.direction and
                last.direction[1]*armed.direction[1]+last.direction[2]*armed.direction[2]+last.direction[3]*armed.direction[3]
            local consumed=last and component.start_t~=last.start_t
            local recent=last and request.time-last.time<Runtime.DUPLICATE_WINDOW
            local duplicate=hit and last and hit.unit~=nil and hit.unit==last.unit and
                (not consumed and (recent or armed.duplicate) or consumed and recent and d~=nil and d>0)
            if armed.charged and armed.start_t~=nil and component.start_t~=armed.start_t then
                -- The server auto-completed the charge this swing was to release.
                state.armed=nil
                emit("gesture_whiff",{action=armed.action,time=request.time,armed_for=request.time-armed.time,reason="auto_complete"})
            elseif duplicate then
                -- Skipped, not dropped: the stroke may still press once it is a new attack.
                if not armed.duplicate then
                    armed.duplicate=true
                    emit("gesture_duplicate",{action=armed.action,zone=hit.zone,time=request.time,since=request.time-last.time})
                end
            elseif hit and (armed.charged or buffered) and hit.ahead and hit.delay and hit.ahead>hit.delay+Runtime.PRESS_SLACK then
                -- Still on its way: pressed when it is as far off as its damage,
                -- or given up if it never gets that close.
                if request.time-armed.time<Runtime.ARM_WAIT then
                    armed.active=request.time
                    if not armed.waited then
                        armed.waited=true
                        emit("gesture_wait",{action=armed.action,zone=hit.zone,time=request.time,ahead=hit.ahead,delay=hit.delay,
                            blade=hit.blade})
                    end
                else
                    state.armed=nil
                    emit("gesture_whiff",{action=armed.action,time=request.time,armed_for=request.time-armed.time,reason="never_arrived"})
                end
            elseif hit and (armed.charged or buffered) then
                if armed.charged then state.heavy=nil;state.release=request.frame else state.pulse=request.frame;state.release=nil end
                state.commit_time=request.time;state.armed=nil
                state.last_press={unit=hit.unit,action=armed.action,time=request.time,start_t=component.start_t,direction=armed.direction,
                    behind=component.current_action_name~=nil and component.current_action_name~="none"}
                state.reach={unit=hit.unit,action=armed.action,time=request.time,deadline=request.time+.8,heavy=armed.charged}
                emit("gesture_contact",{action=armed.action,zone=hit.zone,step=hit.step,time=request.time,lead=request.time-armed.time,
                    ahead=hit.ahead,delay=hit.delay,blade=hit.blade})
                aim_commit(armed.onset,virtual,offset,{action=armed.action,heavy=armed.charged,time=request.time,target=hit.position,
                    target_unit=hit.unit,delay=hit.delay})
            elseif not active and request.time-armed.active>.1 then
                state.armed=nil
                if not armed.duplicate then
                    emit("gesture_whiff",{action=armed.action,time=request.time,armed_for=request.time-armed.time})
                end
            end
        end
        -- Evidence: when the weapon itself reaches the enemy a press was aimed
        -- at, to set against when its damage lands (user, 22 October: damage
        -- should land as the weapon arrives, at every swing speed).
        -- visual: probed with the weapon as drawn, not the attack's longer box.
        local reach=state.reach
        if reach and seeking then
            local now=capture_world(virtual)
            local ok,result
            if now then ok,result=pcall(options.contact,{poses={now},action=reach.action,time=request.time,horizon=0,visual=true}) end
            local touching=ok and type(result)=="table" and result.unit==reach.unit
            if touching or request.time>reach.deadline then
                state.reach=nil
                emit("weapon_reach",{action=reach.action,time=request.time,heavy=reach.heavy==true,
                    after_press=touching and string.format("%.3f",request.time-reach.time) or "none"})
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
            raw_world=seeking and request.dominant and capture_world(request.dominant) or nil,
            frame=request.frame,time=request.time,pose_time=request.pose_time or request.time}
        -- The last moments of the WORLD path: a stroke commits only after its
        -- motion has travelled, and binds a native frame later still.
        local history=state.history or {}
        history[#history+1]=state.current
        while #history>32 or history[1].time<request.time-.6 do table.remove(history,1) end
        state.history=history
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
        if stock or not Runtime.is_followup_chain(options.extension,options.weapon,handler,chain) then return true end
        return state.current~=nil and state.follow~=nil and state.pending~=nil and state.follow.plan.ready and
            strokes.status().collision_allowed and state.committed_action==chain.action_name and
            t>=state.commit_time and t-state.commit_time<=.15 or false
    end
    function api.select_chain(handler,chain,t,_,_,actions)
        if stock or handler~=options.extension._action_handler or actions~=options.weapon.weapon_template.actions or
                not state.pending or not state.native_input or
                t<state.commit_time or t-state.commit_time>.15 or
                not (strokes.status().collision_allowed or strokes.status().ended) then return chain end
        local component=options.extension._weapon_action_component
        -- An interrupting stroke: this runtime's own attack chains into the
        -- next windup now, not at its authored chain time. The native handler
        -- still validates everything else and ends the old attack itself.
        local running=component and actions[component.current_action_name]
        if state.interrupting and state.action and running and running.kind=="sweep" and
                running.allowed_chain_actions and running.allowed_chain_actions.start_attack==chain then
            local now={}
            for key,value in pairs(chain) do now[key]=value end
            now.chain_time=nil; now.chain_until=nil
            return now
        end
        -- The stock combo may have reset or advanced since the stroke was
        -- committed. Admit only the actual live windup's matching input edge,
        -- rather than comparing its destination with a cached combo entry.
        local windup=running and deps.Timing.is_windup(running.kind) and running
        local edge=windup and windup.allowed_chain_actions and
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
    -- The enemy the latest press was aimed at, and when (diagnostics).
    function api.last_press() local last=state.last_press; return last and last.unit,last and last.time end
    function api.current_action() return state.action end
    function api.owns(action) return state.suppressed[action]~=nil end
    function api.on_start(action,settings,t)
        if stock or not state.current or action._player_unit~=options.unit or action._weapon~=options.weapon or
                action._unit_data_extension.is_resimulating then return false end
        -- The trigger never starts a sweep here, so one without a recent stroke
        -- or push follow-up is the player's weapon special (an axe uppercut, a
        -- shield bash): it runs as the stock attack instead of being swallowed.
        if not state.follow and not (state.pending and state.commit_time and t>=state.commit_time and t-state.commit_time<=.15) then
            emit("context",{accepted=false,reason="stock_sweep",time=t,
                action=action._weapon_action_component.current_action_name})
            return false
        end
        state.suppressed[action]=true
        action._action_sweep_component.sweep_state="during_damage_window"
        local status=strokes.status()
        -- A quick stroke may stop in the frame before its native action
        -- starts. It still binds, for one pass over the path it travelled.
        if state.pending and status.stroke_id==state.pending and (status.collision_allowed or status.ended) and
                t>=state.commit_time and t-state.commit_time<=.15 and
                action._weapon_action_component.current_action_name==state.committed_action then
            local ok,reason=bridge.bind(action,state.pending)
            if ok then
                state.action=action; state.pending=nil; state.query_frame=nil; state.interrupting=nil
                state.final=not status.collision_allowed and action or nil
                if state.follow then
                    state.follow=nil; state.follow_active=action; state.follow_release=state.frame+1
                end
                state.direction=nil;state.world_direction=nil
                local previous=state.previous_sample
                state.previous=previous and previous.world;state.previous_body=previous and previous.pose
                state.previous_time=previous and previous.pose_time
                -- The committed motion before that previous sample, oldest
                -- first: without it a stroke never queries the opening of
                -- its own swing, often the part that passes through a target.
                state.backfill=nil
                if previous and status.onset then
                    local backfill={}
                    for _,sample in ipairs(state.history or {}) do
                        if sample.time>=status.onset and sample.time<previous.time then backfill[#backfill+1]=sample end
                    end
                    state.backfill=#backfill>0 and backfill or nil
                end
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
        local volume=deps.Volume.resolve(options.weapon.weapon_template,settings,options.defaults,action._uses_matrix_data)
        -- Splits one sampled interval of the WORLD path into native queries.
        -- Returns them, or nil with the plan (or "unmapped") that refused.
        local function interval(first_world,first_body,last_world,last_body,interval_dt)
            local trajectory=deps.Planner.trajectory(first_world,last_world)
            local body_trajectory=deps.Planner.trajectory(first_body,last_body)
            local plan=trajectory and volume and deps.Planner.make({current_valid=true,previous_valid=true,
                dt=interval_dt,translation=trajectory.translation,
                angle=trajectory.angle,radius=volume.corner_radius},
                {max_gap=.1,max_translation=.5,arc_step=.06,max_segments=deps.Bridge.max_segments})
            if not plan or plan.reset then return nil,plan,trajectory end
            local result={}
            for i=1,plan.segments do
                local first=deps.Planner.pose_at(trajectory,(i-1)/plan.segments)
                local last=deps.Planner.pose_at(trajectory,i/plan.segments)
                local a,ar=world_components(first)
                local b,br=world_components(last)
                if not a or not ar or not b or not br then return nil,"unmapped" end
                local ta,tb=tip(first,current.offset),tip(last,current.offset)
                local delta={tb[1]-ta[1],tb[2]-ta[2],tb[3]-ta[3]}
                local length=math.sqrt(delta[1]^2+delta[2]^2+delta[3]^2)
                local direction=length>1e-8 and {delta[1]/length,delta[2]/length,delta[3]/length} or nil
                local body_first=deps.Planner.pose_at(body_trajectory,(i-1)/plan.segments)
                local body_last=deps.Planner.pose_at(body_trajectory,i/plan.segments)
                local ba,bb=tip(body_first,current.offset),tip(body_last,current.offset)
                local bd={bb[1]-ba[1],bb[2]-ba[2],bb[3]-ba[3]}
                local bl=math.sqrt(bd[1]^2+bd[2]^2+bd[3]^2)
                result[#result+1]={from_position=a,from_rotation=ar,position=b,rotation=br,
                    direction=direction,body_direction=bl>1e-8 and {bd[1]/bl,bd[2]/bl,bd[3]/bl} or nil}
            end
            return result
        end
        local segments,plan,trajectory=interval(state.previous or current.world,state.previous_body or pose,
            current.world,pose,state.previous_time and current.pose_time-state.previous_time or dt)
        if plan=="unmapped" then
            bridge.finish(action,t); emit("query_rejected",{reason="world_mapping_unavailable"}); return true
        end
        if plan and plan.reset and plan.reason=="discontinuity" then
            emit("query_rejected",{reason="world_discontinuity"})
            api.invalidate("world_discontinuity");return true
        end
        if not segments then
            segments={}
            emit("query_rejected",{reason=plan and plan.reason or "invalid_geometry",
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
        -- The first query after binding also sweeps the stroke's own motion
        -- from its onset, newest interval first within the shared budget.
        -- An interval that cannot be swept ends the backfill there.
        local backfill=state.backfill;state.backfill=nil
        if backfill and state.previous then
            local earlier,swept,span={},0,0
            local last_world,last_body,last_time=state.previous,state.previous_body,state.previous_time
            for i=#backfill,1,-1 do
                local sample=backfill[i]
                local piece=last_time and interval(sample.world,sample.pose,last_world,last_body,last_time-sample.pose_time)
                if not piece or #segments+swept+#piece>deps.Bridge.max_segments then break end
                table.insert(earlier,1,piece); swept=swept+#piece; span=state.previous_time-sample.pose_time
                last_world,last_body,last_time=sample.world,sample.pose,sample.pose_time
            end
            local chained={}
            for _,piece in ipairs(earlier) do for _,segment in ipairs(piece) do chained[#chained+1]=segment end end
            for _,segment in ipairs(segments) do chained[#chained+1]=segment end
            segments=chained
            emit("backfill",{intervals=#earlier,available=#backfill,segments=swept,seconds=span})
        end
        -- An ended stroke gets exactly this one pass over its recorded path.
        state.final_active=state.final==action and action or nil
        state.final=nil
        bridge.step(action,{time=t,dt=dt,frame=current.frame,stroke_id=strokes.status().stroke_id,
            active=strokes.status().collision_allowed or state.final_active==action,
            natural_end=current.stroke.reason=="sample",segments=segments,before_query=function(segment)
                if segment.body_direction then state.direction=segment.body_direction end
                if segment.direction then
                    state.world_direction=segment.direction
                end
                return state.world_direction
            end})
        state.final_active=nil
        local constrained=constrain_sticky(action,pose)
        if not constrained then return true end
        -- A contact may pin the shared pose after the query. Ordinary frames
        -- retain the exact world snapshot already used by their segments.
        if constrained.constrained then
            pose=constrained;current.pose=constrained
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
            (strokes.status().collision_allowed or state.final_active==action or bridge.flushing(action)) and
            bridge.claim(action,target)
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
        Runtime.release_source(lease,api)
    end
    Runtime.claim_source(lease,api)
    return api
end
return Runtime
