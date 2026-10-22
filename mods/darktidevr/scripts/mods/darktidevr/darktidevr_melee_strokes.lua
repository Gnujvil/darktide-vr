-- Motion intent and cadence only. Native actions still own damage, cleave,
-- stamina and procs. Keep one owner across weapon/mode/reference changes;
-- replacing this owner is reserved for a new player/session.
local Strokes={}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function length(v) return math.sqrt(v[1]^2+v[2]^2+v[3]^2) end
local function delta(a,b) return {a[1]-b[1],a[2]-b[2],a[3]-b[3]} end
local function copy(v) return {v[1],v[2],v[3]} end
local function dot(a,b) return a[1]*b[1]+a[2]*b[2]+a[3]*b[3] end
local function unit(v,n) return {v[1]/n,v[2]/n,v[3]/n} end
function Strokes.new(options)
    options=options or {}
    local config={travel=options.travel or .18,speed=options.speed or 1.2,
        raw_travel=options.raw_travel or .12,raw_speed=options.raw_speed or .7,
        duration=options.duration or .045,coherence=options.coherence or .8,
        stop_speed=options.stop_speed or .35,settle=options.settle or .06,
        max_active=options.max_active or .6,max_gap=options.max_gap or .1}
    for _,n in pairs(config) do assert(finite(n) and n>0,"invalid stroke configuration") end
    assert(config.coherence<=1 and config.stop_speed<config.speed,"invalid stroke thresholds")
    local state={debt=0,serial=0,phase="settling"}
    local api={}
    local function reset_motion()
        state.point=nil; state.raw_point=nil; state.raw_support=nil; state.candidate=nil; state.active=nil; state.quiet=0; state.spent_direction=nil
        state.ended=nil
        state.phase="settling"
    end
    -- A committed stroke can stop before its native action binds a frame
    -- later. Its record lets the owner sweep the path it already travelled,
    -- once; the stroke itself is no longer active or claimable.
    local function ended_stroke()
        local ended=state.ended
        return ended and ended.serial==state.serial and state.active==nil and ended or nil
    end
    local function remaining()
        return state.frozen or state.debt*(state.interval or 0)
    end
    local function recovery()
        if state.frozen then return math.max(0,1-state.frozen/state.frozen_total) end
        return math.max(0,1-state.debt)
    end
    local function snapshot(reason,committed)
        return {reason=reason,committed=committed==true,stroke_id=state.serial,
            phase=state.phase,recovery=recovery(),remaining=remaining(),
            collision_allowed=state.active~=nil,intent_hand=state.active and state.active.intent_hand,
            trajectory=state.active and state.active.trajectory,
            onset=state.active and state.active.onset or ended_stroke() and state.ended.onset or nil,
            ended=ended_stroke()~=nil}
    end
    function api.update(request)
        request=request or {}
        local time,frame=request.time,request.frame
        if not finite(time) or not finite(frame) or frame<0 or frame~=math.floor(frame) then
            reset_motion(); state.output=snapshot("invalid_clock"); return state.output
        end
        local dt=state.time and time-state.time or 0
        if state.frame==frame and dt~=0 then
            reset_motion(); state.output=snapshot("frame_time_conflict"); return state.output
        end
        if dt<0 or (state.frame and frame<state.frame) then
            reset_motion(); state.time=time; state.frame=frame
            state.output=snapshot("clock_rewind"); return state.output
        end
        local changed=state.weapon~=request.weapon or state.mode~=request.mode
        if changed and remaining()>0 and not state.frozen then
            state.frozen=remaining(); state.frozen_total=state.frozen; state.debt=0
        end
        if dt>0 then
            if state.frozen then
                state.frozen=math.max(0,state.frozen-dt)
                if state.frozen==0 then state.frozen=nil; state.frozen_total=nil end
            elseif state.interval then
                local interval=not changed and request.interval or state.interval
                if not finite(interval) or interval<=0 then interval=state.interval end
                state.debt=math.max(0,state.debt-dt/interval)
            end
        end
        local point=request.point
        local raw=request.raw_point
        local support=request.raw_support_point
        local valid=request.tracking_valid==true and request.reference~=nil and
            request.weapon~=nil and request.mode~=nil and finite(request.interval) and request.interval>0 and
            type(point)=="table" and finite(point[1]) and finite(point[2]) and finite(point[3]) and
            type(raw)=="table" and finite(raw[1]) and finite(raw[2]) and finite(raw[3]) and
            (support==nil or type(support)=="table" and finite(support[1]) and finite(support[2]) and finite(support[3]))
        if not valid then
            reset_motion(); state.time=time; state.frame=frame
            state.output=snapshot("unavailable"); return state.output
        end
        local reference_changed=state.reference~=request.reference
        local grip_changed=(support~=nil)~=(state.raw_support~=nil)
        if state.frame==frame and not changed and not reference_changed and not grip_changed then
            if request.intent~=true or request.guarding==true then
                reset_motion(); state.output=snapshot("no_attack_intent"); return state.output
            end
            return snapshot("repeated")
        end
        state.time=time; state.frame=frame; state.interval=request.interval
        state.weapon=request.weapon; state.mode=request.mode; state.reference=request.reference
        if changed or reference_changed or grip_changed or dt>config.max_gap or not state.point then
            reset_motion(); state.point=copy(point); state.raw_point=copy(raw)
            state.raw_support=support and copy(support)
            state.output=snapshot(grip_changed and "grip_source_changed" or "motion_reset"); return state.output
        end
        local movement=delta(point,state.point)
        local raw_movement=delta(raw,state.raw_point)
        local raw_distance=length(raw_movement)
        local support_movement=support and delta(support,state.raw_support)
        local support_distance=support_movement and length(support_movement) or 0
        local raw_speed=dt>0 and math.max(raw_distance,support_distance)/dt or 0
        -- Settling watches the weapon hand only: a shield or free hand moving
        -- through a fight must not keep the weapon from arming.
        local hand_speed=dt>0 and raw_distance/dt or 0
        local distance=length(movement)
        local speed=dt>0 and distance/dt or 0
        local direction=distance>0 and unit(movement,distance) or nil
        state.point=copy(point); state.raw_point=copy(raw)
        state.raw_support=support and copy(support)
        if request.intent~=true or request.guarding==true then
            reset_motion(); state.point=copy(point); state.raw_point=copy(raw)
            state.raw_support=support and copy(support)
            state.output=snapshot("no_attack_intent"); return state.output
        end
        local committed=false
        -- Recovery is not a gate. It weakens the weapon's muscles (inertia),
        -- so reaching stroke speed again soon takes a real swing, and more
        -- of one the heavier the weapon. Only the native action decides.
        local ready=request.native_ready==true
        local function candidate()
            return {origin={point[1]-movement[1],point[2]-movement[2],point[3]-movement[3]},
                raw_origin={raw[1]-raw_movement[1],raw[2]-raw_movement[2],raw[3]-raw_movement[3]},raw_path=raw_distance,
                support_origin=support and {support[1]-support_movement[1],support[2]-support_movement[2],support[3]-support_movement[3]},
                support_path=support_distance,
                trajectory={{point[1]-movement[1],point[2]-movement[2],point[3]-movement[3]},copy(point)},
                start=time-dt,path=distance,allowed=ready}
        end
        -- A motion begun during recovery counts from the sample where the
        -- weapon became ready. Nothing travelled before it is swept or
        -- banked, and a motion that ends first never fires.
        local function rebase(value)
            value.origin=copy(point); value.raw_origin=copy(raw); value.raw_path=0
            value.support_origin=support and copy(support); value.support_path=0
            value.trajectory={copy(point)}; value.start=time; value.path=0; value.allowed=true
        end
        -- A sharp turn or a stop separates swings; the next one may start in
        -- any new direction at least 60 degrees from the last, not only back.
        local function next_swing(previous)
            return direction and speed>=config.speed and raw_speed>=config.raw_speed and previous and dot(direction,previous)<.5
        end
        if state.active then
            local active=state.active
            local alignment=direction and dot(direction,active.direction) or 1
            -- A big swing is an arc: its heading keeps turning, past 75 degrees
            -- from the committed direction well before the weapon comes round
            -- to a target, and a 150 degree arc ends about 135 degrees from
            -- it. Follow the turn frame to frame; a sharp turn, or heading back
            -- against the committed direction, still ends the stroke.
            local turn=direction and dot(direction,active.heading or active.direction) or 1
            if not direction or speed<config.stop_speed or turn<.25 or alignment<-.9 or
                    time-active.start>config.max_active then
                state.active=nil; state.phase="spent"; state.quiet=0
                state.ended={serial=state.serial,onset=active.onset}
                state.spent_direction=direction or active.direction
                if next_swing(active.heading or active.direction) then
                    state.candidate=candidate(); state.phase="candidate"
                end
            else active.heading=direction end
        elseif state.phase=="spent" then
            state.quiet=hand_speed<config.stop_speed and state.quiet+dt or 0
            if state.quiet>=config.settle then state.phase="armed"
            elseif next_swing(state.spent_direction) then
                state.candidate=candidate(); state.phase="candidate"
            end
        elseif state.phase=="settling" then
            state.quiet=hand_speed<config.stop_speed and state.quiet+dt or 0
            if state.quiet>=config.settle then state.phase="armed" end
        elseif state.phase=="armed" and speed>=config.speed and raw_speed>=config.raw_speed then
            -- Capture readiness at motion onset. A rejected motion cannot be
            -- banked and released as an attack when its cooldown expires.
            state.candidate=candidate()
            state.phase="candidate"
        elseif state.phase=="candidate" and ready and not state.candidate.allowed then
            rebase(state.candidate)
        elseif state.phase=="candidate" then
            local candidate=state.candidate
            candidate.trajectory[#candidate.trajectory+1]=copy(point)
            if #candidate.trajectory>32 then table.remove(candidate.trajectory,2) end
            candidate.path=candidate.path+distance
            candidate.raw_path=candidate.raw_path+raw_distance
            candidate.support_path=candidate.support_path+support_distance
            candidate.allowed=candidate.allowed and ready
            local net=delta(point,candidate.origin)
            local travel=length(net)
            local coherent=travel/math.max(candidate.path,1e-12)
            local raw_travel=length(delta(raw,candidate.raw_origin))
            local support_travel=support and length(delta(support,candidate.support_origin)) or 0
            -- Each hand must qualify independently. Alternating tiny movement
            -- between hands cannot accumulate into one coherent raw stroke.
            local dominant_qualified=raw_travel>=config.raw_travel and raw_travel/math.max(candidate.raw_path,1e-12)>=config.coherence
            local support_qualified=support_travel>=config.raw_travel and support_travel/math.max(candidate.support_path,1e-12)>=config.coherence
            local raw_qualified=dominant_qualified or support_qualified
            if speed<config.stop_speed or coherent<config.coherence then
                state.candidate=nil; state.phase="spent"; state.quiet=0
                state.spent_direction=direction or state.spent_direction
            elseif travel>=config.travel and raw_qualified and
                    time-candidate.start>=config.duration and speed>=config.speed and
                    (candidate.allowed or not candidate.reported) then
                if candidate.allowed then
                    state.candidate=nil
                    state.serial=state.serial+1; state.debt=1
                    -- onset: the sample the qualifying motion started from. The
                    -- stroke commits only after it has travelled, so the
                    -- runtime queries the path back to here once native binds.
                    state.active={start=time,onset=candidate.start,direction=unit(net,travel),targets={},
                        trajectory=candidate.trajectory,
                        intent_hand=dominant_qualified and (support_qualified and "both" or "dominant") or "support"}
                    state.phase="active"; committed=true
                else
                    -- Reported once; the motion stays a candidate in case the
                    -- weapon becomes ready before it ends.
                    candidate.reported=true
                    state.output=snapshot("suppressed_candidate")
                    state.output.suppressed_candidate={time=time,duration=time-candidate.start,speed=speed,
                        travel=travel,raw_travel=raw_travel,coherence=coherent,
                        native_ready=request.native_ready==true,candidate_allowed=candidate.allowed,
                        remaining=remaining(),direction_x=direction and direction[1],
                        direction_y=direction and direction[2],direction_z=direction and direction[3]}
                    return state.output
                end
            end
        end
        state.output=snapshot(committed and "committed" or "sample",committed)
        return state.output
    end
    function api.claim(target,stroke_id)
        local active=state.active
        if not active or stroke_id~=state.serial or target==nil or active.targets[target] then return false end
        active.targets[target]=true
        return true
    end
    function api.reserve_interval(interval)
        if not finite(interval) or interval<=0 or not state.active or state.debt~=1 then return false end
        state.interval=interval
        return true
    end
    function api.invalidate()
        reset_motion(); state.output=snapshot("invalidated")
        return state.output
    end
    function api.status() return snapshot("status") end
    return api
end
return Strokes
