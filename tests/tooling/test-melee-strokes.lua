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
    -- No cooldown: a deliberate follow-up commits at once. Recovery is still
    -- owed, as weaker muscles in the inertial weapon.
    settle(8); swing(.4,8)
    assert(count()==2 and owner.status().recovery<1,'follow-up waited for a cooldown')
    settle(70); swing(.4)
    assert(count()==3,'deliberate rearmed stroke did not commit')
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
    request.tracking_valid=true; step(nil,.01)
    assert(owner.status().remaining>0,'tracking/recenter reset erased recovery')
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
    -- A swing that finishes while the weapon is not ready never fires later.
    settle(); request.native_ready=false; swing(.4); request.native_ready=true
    settle(70)
    assert(count()==0,'native denial became delayed attack')
    -- One still moving when the weapon becomes ready counts from that sample;
    -- the path it travelled before is neither swept nor banked.
    request.native_ready=false; swing(.2,4)
    local ready_at=request.time
    request.native_ready=true
    for _=1,10 do step(request.point[1]+.03) end
    assert(count()==1 and owner.status().onset>ready_at,'motion past readiness was lost or kept its denied path')
    settle(); request.guarding=true; swing(.4)
    assert(count()==1,'guarding produced a strike')
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
-- Real fights are erratic: the shield hand keeps moving, and the next swing
-- turns away from the last one without the weapon ever stopping.
do
    local owner,request,step,settle,swing,count=fixture()
    request.interval=.1
    for i=1,12 do request.raw_support_point={.04*math.sin(i*.9),.04*math.cos(i*.9),0}; step() end
    swing(.4)
    assert(count()==1,'a moving shield hand kept the weapon from arming')
    for _=1,20 do request.point={request.point[1],request.point[2]+.03,0}; step() end
    assert(count()==2,'a swing turning away without stopping was lost')
end
-- Speed-sensitive arming (user, 22 October: a fast swing's hit lagged its
-- contact). A fast swing qualifies after less travel than a slow one, so its
-- attack is pressed sooner; a slow swing keeps the full travel.
do
    local function travel_at_commit(step_m)
        local owner,request,step,settle,swing,count=fixture()
        settle()
        local start=request.point[1]
        for i=1,40 do
            step(start+step_m*i)
            if count()>0 then return request.point[1]-start end
        end
    end
    local fast,slow=travel_at_commit(.03),travel_at_commit(.013)
    assert(slow and slow>=.18,'a slow swing committed early: '..tostring(slow))
    assert(fast and fast<=.12,'a fast swing (3 m/s) needed the full travel: '..tostring(fast))
end
-- A barely moving weapon is not a swing (worn 24 October; user: "barely
-- moving weapon counts as a swing"). Even fast, a motion needs 0.12 m of
-- the drawn weapon and 0.10 m of the held one; it must also start at 1 m/s.
do
    local function commits_for(step_m,steps,dt,raw_step,target_ahead)
        local owner,request,step,settle,swing,count=fixture()
        settle()
        local start=request.point[1]
        request.target_ahead=target_ahead
        for i=1,steps do
            if raw_step then request.raw_override={start+raw_step*i,0,0} end
            step(start+step_m*i,dt)
        end
        request.raw_override=nil
        settle(20)
        return count()
    end
    -- A 9 cm flick at 6 m/s is too short and too brief to count.
    assert(commits_for(.03,3,.005)==0,'a 9 cm flick counted as a swing')
    -- The drawn weapon at 1.5 m/s while the held one drifts at 0.8 m/s (24 cm):
    -- the old 0.7 m/s start counted it.
    assert(commits_for(.015,30,.01,.008)==0,'a held weapon below 1 m/s counted as a swing')
    -- An enemy ahead no longer shortcuts a slow swing to the floors: 9 cm at
    -- 1.3 m/s toward one stays a motion, not an attack.
    assert(commits_for(.013,7,.01,nil,true)==0,'an enemy ahead let a small slow motion count')
    -- A short real swing: 15 cm at 3 m/s still counts.
    assert(commits_for(.03,5)==1,'a short real swing was lost')
    -- A small back-and-forth jiggle (6 cm each way at 2 m/s) never counts.
    local owner,request,step,settle,swing,count=fixture()
    settle()
    for i=1,60 do step(.03*((i%6<3) and (i%6) or (6-i%6))) end
    assert(count()==0,'a jiggle counted as swings: '..count())
end
-- Worn 22 October: a reset during a continuous fight (no pause at any
-- reversal) left the detector settling for 12 s. After a reset the motion it
-- interrupted stays spent, and a swing turning 60 degrees away re-arms, as
-- after any stroke.
do
    local owner,request,step,settle,swing,count=fixture()
    settle()
    local function leg(sign,frames) for _=1,frames do step(request.point[1]+sign*.02) end end
    leg(1,20); leg(-1,20)
    local before=count()
    assert(before>=1,'continuous back-and-forth fixture did not commit')
    leg(1,10)
    local reset_at=count()
    request.reference={}; step(request.point[1]+.02)
    assert(owner.status().reason=='status' and owner.status().phase=='settling','reference change did not reset motion')
    leg(1,10)
    assert(count()==reset_at,'the motion a reset interrupted committed as a new stroke')
    for _=1,3 do leg(-1,20); leg(1,20) end
    assert(count()-reset_at>=4,'continuous swings after a reset stayed unarmed: '..(count()-reset_at))
    local snapshot=owner.status()
    assert(snapshot.last_reset=='reference_changed','reset cause not reported: '..tostring(snapshot.last_reset))
end
-- Review, 22 October. A reset in the middle of one big arc does not turn
-- the rest of that arc into a second stroke: settling follows its heading.
do
    local owner,request,step,settle,swing,count=fixture()
    request.point={.6,0,0}; settle()
    local dt,rate=1/72,5
    local reset_frame
    for i=1,38 do
        local angle=rate*dt*i
        request.point={.6*math.cos(angle),.6*math.sin(angle),0}
        if math.deg(angle)>=40 and not reset_frame then reset_frame=i;request.reference={} end
        step(nil,dt)
    end
    assert(count()==1,'one arc, reset mid-way, committed '..count()..' strokes')
end
-- One glitched sideways frame right after a reset cannot set the heading;
-- the straight motion it interrupted carries on without a second stroke.
do
    local owner,request,step,settle,swing,count=fixture()
    settle()
    for _=1,12 do step(request.point[1]+.02) end
    assert(count()==1)
    request.reference={}; step(request.point[1]+.02)
    request.point={request.point[1]+.02,.05,0}; step(nil)
    request.point={request.point[1]+.02,0,0}; step(nil)
    for _=1,12 do step(request.point[1]+.02) end
    assert(count()==1,'a glitch frame after a reset turned the same motion into a second stroke')
end
-- Block held with a still hand, then let go into an immediate swing: the
-- counter-attack is a new swing, not an interrupted motion.
do
    local owner,request,step,settle,swing,count=fixture()
    settle(); request.guarding=true
    for _=1,30 do step() end
    request.guarding=false
    for _=1,12 do step(request.point[1]+.02) end
    assert(count()==1,'the first swing after a still block was swallowed')
end
-- Two consecutive tracking jumps at 90 Hz are not a fast swing.
do
    local owner,request,step,settle,swing,count=fixture()
    settle(12)
    step(request.point[1]+.05,1/90); step(request.point[1]+.05,1/90)
    for _=1,10 do step(nil,1/90) end
    assert(count()==0,'a two-frame tracking jump committed a stroke')
end
-- An invalidate's renewed reference does not mask its cause.
do
    local owner,request,step,settle,swing,count=fixture()
    settle(); owner.invalidate(); request.reference={}; step(); step()
    assert(owner.status().last_reset=='invalidated','reset cause masked: '..tostring(owner.status().last_reset))
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
            assert(result.suppressed_candidate.travel>=.08 and not result.suppressed_candidate.native_ready)
        end
    end
    assert(count()==0 and reports==1,'suppressed-candidate observation changed admission or repeated')
end
-- A big swing is an arc. Collision must follow it past 75 degrees from the
-- committed direction to where it meets a target; a reversal still ends it.
for _,reverse in ipairs({false,true}) do
    local owner=Strokes.new()
    local request={time=0,frame=0,interval=.6,weapon={},mode='physical',reference={},
        tracking_valid=true,intent=true,native_ready=true}
    local function at(angle)
        request.time=request.time+1/52;request.frame=request.frame+1
        request.point={.7*math.cos(angle),.7*math.sin(angle),0};request.raw_point=request.point
        return owner.update(request)
    end
    for _=1,10 do at(math.rad(150)) end
    local committed,turned
    for i=1,30 do
        local angle=math.rad(150-150*i/30)
        local result=at(angle)
        if result.committed then committed=angle end
        if committed and committed-angle>math.rad(110) and not turned then
            turned=true
            assert(result.collision_allowed,'curved swing lost collision part way round its arc')
            if reverse then
                assert(not at(angle+math.rad(4)).collision_allowed,'reversal kept the stroke active')
                break
            end
        end
    end
    assert(committed and turned,'arc fixture did not commit and turn')
end
-- PC runs 22-23 October: combataxe_p2 at medium speed never struck. Its tip
-- curled as the swing set off (8 cm of path, 6 cm net in 58 ms) and the
-- whole swing was dropped as spent; it carried on in the same direction, so
-- nothing re-armed it. A curl at speed restarts the measure instead.
do
    local owner,request,step,settle,swing,count=fixture()
    settle()
    local raw=0
    local function at(x,y)
        raw=raw+.025; request.raw_override={raw,0,0}
        request.point={x,y,0}; return step()
    end
    at(0,.03); at(.005,.045)
    local curled=at(.03,.045)
    assert(curled.dropped and curled.dropped.restarted and count()==0,'curl fixture did not curl')
    for i=1,10 do at(.03+.025*i,.045) end
    assert(count()==1,'a swing whose start curled was lost')
    -- A stop still ends a motion: nothing restarts below stop speed.
    local owner2,request2,step2,settle2,swing2,count2=fixture()
    settle2(); swing2(.05,4)
    for _=1,3 do step2(request2.point[1]+.001) end
    assert(owner2.status().phase~='candidate','a stopped motion stayed a candidate')
end
print('melee_strokes=pass deliberate_motion whiff_recovery per_target 50hz_jitter stationary_overlap no_banking weapon_mode_reference tracking native_readiness live_speed duplicate_clock suppression_observation curved_arc reversal_ends curl_restart')
