local Strokes=dofile(assert(arg[1]))
local function fixture()
    local owner=Strokes.new()
    local request={time=0,frame=0,point={0,0,0},interval=.6,weapon={},mode='physical',reference={},
        tracking_valid=true,intent=true,native_ready=true}
    local commits=0
    local function step(x,dt)
        request.time=request.time+(dt or .01); request.frame=request.frame+1
        if x then request.point={x,0,0} end
        request.raw_point=request.raw_override or request.point
        local result=owner.update(request)
        if result.committed then commits=commits+1 end
        return result
    end
    local function settle(n) for _=1,n or 10 do step() end end
    local function swing(distance,n)
        local x=request.point[1]
        local result
        for i=1,n or 8 do result=step(x+distance*i/(n or 8)) end
        return result
    end
    return owner,request,step,settle,swing,function() return commits end
end
do
    local owner,request,step,settle,swing,count=fixture()
    settle(); request.raw_override={0,0,0}
    swing(.5)
    assert(count()==0,'gravity/solver motion without raw hand intent committed a stroke')
end
do
    local owner,request,step,settle,swing,count=fixture()
    settle(); swing(.4)
    assert(count()==1 and owner.status().collision_allowed)
    local target={}
    assert(owner.claim(target,1) and not owner.claim(target,1),'duplicate hurtbox/target got another claim')
    assert(not owner.claim({},0),'stale stroke accepted')
    local debt=owner.status().remaining
    assert(debt>0,'whiff did not incur recovery')
    local duplicate=owner.update(request)
    assert(not duplicate.committed and owner.status().remaining==debt,'duplicate frame advanced cadence')
    step(); assert(not owner.claim({},1),'stationary overlap retained collision permission')
    settle(8); swing(.4,8)
    settle(70)
    assert(count()==1,'early motion was banked across recovery')
    swing(.4)
    assert(count()==2,'deliberate rearmed stroke did not commit')
end
do
    local owner,request,step,settle,swing,count=fixture()
    settle()
    for i=1,2000 do step((i%4<2 and .015 or -.015),.005) end
    assert(count()==0,'50Hz weapon jiggle committed attacks')
    settle(); swing(.4)
    assert(count()==1)
    for _=1,2000 do step(nil,.005) end
    assert(count()==1 and not owner.status().collision_allowed,'stationary overlap retriggered after cooldown')
end
do
    local owner,request,step,settle,swing,count=fixture()
    settle(); swing(.4)
    local debt=owner.status().remaining
    request.weapon={}; request.interval=.1; step(nil,.01)
    assert(math.abs(owner.status().remaining-(debt-.01))<1e-9,'weapon switch erased heavy recovery')
    request.mode='stock'; step(nil,.01); request.mode='physical'; step(nil,.01)
    assert(math.abs(owner.status().remaining-(debt-.03))<1e-9,'mode switch erased recovery')
    request.reference={}; step(nil,.01)
    assert(owner.status().remaining>0 and not owner.status().collision_allowed)
    request.tracking_valid=false; step(nil,.01)
    request.tracking_valid=true; settle(10); swing(.4)
    assert(count()==1,'tracking/recenter reset erased debt')
end
do
    local owner,request,step,settle,swing,count=fixture()
    settle(); swing(.4)
    local debt=owner.status().remaining
    request.interval=.3; step(nil,.01)
    assert(math.abs(owner.status().remaining-(debt*.5-.01))<1e-9,'attack speed failed to scale recovery work')
    local before=owner.status().remaining
    request.time=request.time+1
    assert(owner.update(request).reason=='frame_time_conflict')
    assert(owner.status().remaining==before,'conflicting duplicate erased recovery')
    request.time=request.time-2; request.frame=request.frame+1
    assert(owner.update(request).reason=='clock_rewind' and owner.status().remaining==before)
    request.tracking_valid=false
    assert(not owner.update(request).collision_allowed,'same-frame tracking loss retained active stroke')
end
do
    local owner,request,step,settle,swing,count=fixture()
    settle(); request.native_ready=false; swing(.4); request.native_ready=true
    for i=1,100 do step(.4+i*.03) end
    assert(count()==0,'native denial became delayed attack')
    settle(); request.guarding=true; swing(.4)
    assert(count()==0,'guarding produced a strike')
    request.guarding=false; request.interval=0; step()
    assert(not owner.status().collision_allowed,'invalid native interval accepted')
end
do
    local owner,request,step,settle,swing,count=fixture()
    settle(); swing(.4)
    for _=1,70 do step(request.point[1]+.03) end
    swing(-.4)
    assert(count()==2,'meaningful return stroke required an artificial stationary pause')
end
for _,dt in ipairs({1/50,1/90,1/144,1/1000}) do
    local owner=Strokes.new()
    local count=0
    for frame=0,math.ceil(5/dt) do
        local time=frame*dt
        local phase=time%1
        local x=math.min(.6,math.max(0,(phase-.15)*3))
        -- Each cycle has a settled hold and one deliberate path. The reset
        -- at the cycle boundary cannot itself become a damaging sweep.
        local result=owner.update({time=time,frame=frame,point={x,0,0},raw_point={x,0,0},interval=.6,
            weapon='same_weapon',reference='same_reference',mode='physical',tracking_valid=true,intent=true,native_ready=true})
        if result.committed then
            count=count+1
            assert(not owner.update({time=time,frame=frame,point={x,0,0},raw_point={x,0,0},interval=.6,
                weapon='same_weapon',reference='same_reference',mode='physical',tracking_valid=true,intent=true,native_ready=true}).committed,
                'duplicate consumer repeated a commit pulse')
        end
    end
    assert(count==5,'sample rate altered deliberate stroke count: '..dt..' count='..count)
end
-- Support intent is independent of dominant intent, never a sum of two
-- alternating wiggles. Grip changes reset motion but cannot erase debt.
do
    local owner,request,step,settle,swing,count=fixture()
    request.raw_override={0,0,0}; request.raw_support_point={0,0,0}
    settle()
    for i=1,8 do request.raw_support_point={i*.05,0,0};step(i*.05) end
    assert(count()==1,'support-only coherent intent was rejected')
    local debt=owner.status().remaining
    request.raw_support_point=nil
    local cancelled=owner.update(request)
    assert(cancelled.reason=='grip_source_changed' and not cancelled.collision_allowed and owner.status().remaining==debt,
        'same-frame grip release kept collision or erased debt')
    request.raw_support_point={2,0,0}
    assert(not owner.update(request).collision_allowed and owner.status().remaining==debt,'grip reacquisition manufactured a stroke')
end
do
    local owner,request,step,settle,swing,count=fixture()
    request.raw_override={0,0,0};request.raw_support_point={0,0,0};settle()
    for i=1,200 do
        request.raw_override={i%2*.02,0,0};request.raw_support_point={(1-i%2)*.02,0,0}
        step(i*.03,.02)
    end
    assert(count()==0,'alternating tiny hand movements were added into one stroke')
end
do
    local owner,request,step,settle,swing,count=fixture()
    request.raw_override={0,0,0};request.raw_support_point={0,0,0};settle()
    for i=1,40 do
        if i%2==1 then request.raw_support_point=nil else request.raw_support_point={2,0,0} end
        step(i*.04)
    end
    assert(count()==0,'engagement discontinuities manufactured intent')
end
do
    local owner,request,step,settle,_,count=fixture()
    settle();request.native_ready=false
    local reports=0
    for i=1,10 do
        local result=step(i*.05)
        if result.suppressed_candidate then
            reports=reports+1
            assert(not result.committed and not result.collision_allowed and result.remaining==0)
            assert(result.suppressed_candidate.travel>=.18 and not result.suppressed_candidate.native_ready)
        end
    end
    assert(count()==0 and reports==1,'suppressed-candidate observation changed admission or repeated')
end
print('melee_strokes=pass deliberate_motion whiff_recovery per_target 50hz_jitter stationary_overlap no_banking weapon_mode_reference tracking native_readiness live_speed duplicate_clock suppression_observation')
