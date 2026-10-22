-- One simulation owner shared by tracked and scripted input. Rendering and
-- collision only read snapshots: neither consumer may integrate the solver.
local Pose={}
local function copy(pose)
    if type(pose)~="table" or type(pose.position)~="table" or type(pose.rotation)~="table" then return nil end
    local result={position={},rotation={}}
    for i=1,3 do result.position[i]=pose.position[i] end
    for i=1,4 do result.rotation[i]=pose.rotation[i] end
    return result
end
function Pose.new(Inertia,options)
    local solver,reason=Inertia.new(options)
    if not solver then return nil,reason end
    local state={history={},revision=0}
    local closed=false
    local api={}
    function api.update(request)
        if closed then return nil,"closed" end
        if request.tracking_valid~=true or request.reference==nil then api.reset(); return nil,"tracking_unavailable" end
        local frame=request.frame
        if type(frame)~="number" or frame~=frame or frame<0 or frame~=math.floor(frame) then
            api.reset(); return nil,"invalid_frame"
        end
        if state.frame==frame and state.reference==request.reference then
            if state.time~=request.time then api.reset(); return nil,"frame_time_conflict" end
            return state.current
        end
        local result,detail=solver.update(request)
        if not result then api.reset(); return nil,detail end
        if result.reset then state.history={}; state.revision=state.revision+1 end
        result.frame=frame
        result.revision=state.revision
        result.raw_dominant=copy(request.dominant)
        result.raw_support=copy(request.support)
        state.current=result; state.frame=frame; state.time=request.time
        state.reference=request.reference
        state.history[#state.history+1]=result
        if #state.history>16 then table.remove(state.history,1) end
        return result
    end
    function api.latest() return state.current end
    function api.at(time)
        for i=#state.history,1,-1 do
            if state.history[i].time==time then return state.history[i] end
        end
        return nil,"pose_not_sampled"
    end
    function api.reset()
        if closed then return false end
        solver.reset(); state.current=nil; state.frame=nil; state.time=nil; state.reference=nil
        state.history={}; state.revision=state.revision+1
        return true
    end
    function api.contact(retention)
        if closed or not solver.contact(retention) then return false end
        local current=state.current
        if current then
            for i=1,3 do
                current.linear_velocity[i]=current.linear_velocity[i]*retention
                current.angular_velocity[i]=current.angular_velocity[i]*retention
            end
        end
        return true
    end
    function api.pin(pose)
        if closed or not state.current then return nil,"pose_unavailable" end
        local ok,reason=solver.pin(pose)
        if not ok then return nil,reason end
        local current=state.current
        current.position={unpack(pose.position)};current.rotation={unpack(pose.rotation)}
        current.linear_velocity={0,0,0};current.angular_velocity={0,0,0}
        -- Refresh the support grip from the constrained native body without
        -- advancing simulation time. update returns the cached timestamp.
        local refreshed=solver.update({dominant=current.raw_dominant,support=current.raw_support,
            support_held=current.support_engaged,tracking_valid=true,reference=state.reference,time=state.time,recovery=current.recovery})
        if refreshed then
            current.support=refreshed.support;current.position_lag=refreshed.position_lag;current.angular_lag=refreshed.angular_lag
        end
        current.constrained=true
        return current
    end
    function api.close()
        if closed then return false end
        api.reset(); closed=true; solver.close()
        return true
    end
    return api
end
return Pose
