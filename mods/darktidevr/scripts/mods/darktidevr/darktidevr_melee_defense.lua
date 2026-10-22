-- Body-local guard/shove recognition. This only authors native input edges;
-- the stock block/push actions retain stamina, radius and chain authority.
local Defense={}
function Defense.guard_role(template)
    -- The supported stock shield family carries this native keyword. Keep
    -- anatomical sides out of this policy: support follows the equipped roles.
    for _,keyword in ipairs(type(template)=="table" and template.keywords or {}) do
        if keyword=="powermaul_shield" then return "support" end
    end
    local name=type(template)=="table" and template.name
    if name=="powermaul_shield_p1_m1" or name=="powermaul_shield_p1_m2" then return "support" end
    return "dominant"
end
-- margin widens every limit for a guard already held, so a shield at the
-- edge of the box does not restart the native block each time it crosses.
local function guard(pose,margin)
    if not pose then return false end
    local p,q=pose.position,pose.rotation
    -- Body origin is the recentered head; +Y is forward, +Z is up.
    local shaft_y=2*(q[2]*q[3]-q[4]*q[1])
    return math.abs(p[1])<=.85+margin and p[2]>=.15-margin and p[2]<=.95+margin and
        p[3]>=-.70-margin and p[3]<=.15+margin and math.abs(shaft_y)<=.70+margin
end
local function copy(p) return {p[1],p[2],p[3]} end
local function distance(a,b)
    return math.sqrt((a[1]-b[1])^2+(a[2]-b[2])^2+(a[3]-b[3])^2)
end
function Defense.new()
    local state={quiet=0}
    local api={}
    function api.reset() state={quiet=0} end
    function api.update(request)
        if state.frame==request.frame and state.time==request.time then return state.output end
        local dt=state.time and request.time-state.time
        local margin=state.blocking==true and .15 or 0
        local blocking=request.intent==true and guard(request.raw,margin) and guard(request.virtual,margin)
        local pose_only=request.pose_only==true
        if pose_only then
            local continuous=dt and dt>0 and dt<=.1 and state.pose_only==true
            local settled=continuous and state.pose_raw and state.pose_virtual and request.raw and request.virtual and
                distance(request.raw.position,state.pose_raw)/dt<.25 and
                distance(request.virtual.position,state.pose_virtual)/dt<.25
            state.pose_quiet=blocking and settled and (state.pose_quiet or 0)+dt or 0
            -- Deliberately settle into guard; passing through it during an
            -- attack must not block. Once held, allow the existing shove.
            blocking=blocking and continuous and (state.blocking==true or state.pose_quiet>=.12) or false
        else state.pose_quiet=0 end
        state.pose_only=pose_only
        state.pose_raw=request.raw and copy(request.raw.position)
        state.pose_virtual=request.virtual and copy(request.virtual.position)
        local output={blocking=blocking,pressed=blocking and not state.blocking,
            released=state.blocking==true and not blocking,push=false}
        if not blocking then
            state.quiet=0; state.armed=false; state.candidate=nil
            state.raw=nil; state.virtual=nil; state.blocking=false
            state.frame=request.frame; state.time=request.time; state.output=output
            return output
        end
        local raw,virtual=request.raw.position,request.virtual.position
        if not dt or dt<=0 or dt>.1 or not blocking or not state.blocking then
            state.quiet=0; state.armed=false; state.candidate=nil
        else
            local travel=distance(raw,state.raw)
            local speed=travel/dt
            state.quiet=speed<.25 and state.quiet+dt or 0
            if state.quiet>=.08 then state.armed=true end
            if not request.push_ready then state.candidate=nil; state.armed=false
            elseif state.candidate then
                local candidate=state.candidate
                candidate.path=candidate.path+travel
                local forward=raw[2]-candidate.raw[2]
                local actual_forward=virtual[2]-candidate.virtual[2]
                if speed<.25 or forward/math.max(candidate.path,1e-9)<.85 then
                    state.candidate=nil; state.armed=false
                elseif forward>=.18 and actual_forward>=.10 and
                        request.time-candidate.time>=.06 and (raw[2]-state.raw[2])/dt>=.8 then
                    output.push=true; state.candidate=nil; state.armed=false; state.quiet=0
                end
            elseif state.armed and (raw[2]-state.raw[2])/dt>=.8 then
                state.candidate={raw=copy(state.raw),virtual=copy(state.virtual),time=state.time,path=travel}
                state.armed=false
            end
        end
        state.raw=copy(raw); state.virtual=copy(virtual); state.blocking=blocking
        state.frame=request.frame; state.time=request.time; state.output=output
        return output
    end
    return api
end
return Defense
