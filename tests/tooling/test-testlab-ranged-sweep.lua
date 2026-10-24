-- Offline: ranged hand/muzzle frame analysis and the sweep sequencer.
-- arg[1]: testlab/darktide_testlab/scripts/mods/darktide_testlab
local base=assert(arg[1])
local Pose=dofile(base..'/ranged_pose.lua')
local Sweep=dofile(base..'/ranged_sweep.lua')
local function near(a,b,eps) return math.abs(a-b)<=(eps or 1e-6) end
-- Euler convention: Rz(yaw)*Rx(pitch)*Ry(roll), roll about forward.
for _,case in ipairs({{0,0,0},{30,0,0},{0,20,0},{0,0,45},{-70,35,-120},{170,-60,15},{12,5,179}}) do
    local y,p,r=Pose.euler(Pose.from_euler(case[1],case[2],case[3]))
    assert(near(y,case[1],1e-6) and near(p,case[2],1e-6) and near(Pose.wrap(r-case[3]),0,1e-6),
        string.format('euler round trip %s,%s,%s -> %s,%s,%s',case[1],case[2],case[3],y,p,r))
end
assert(Pose.wrap(190)==-170 and Pose.wrap(-190)==170 and Pose.wrap(180)==180,'wrap')
-- relative(a,b) is b expressed in a's frame: a*relative == b.
local a,b=Pose.from_euler(40,10,-5),Pose.from_euler(-20,30,60)
assert(Pose.angle(Pose.multiply(a,Pose.relative(a,b)),b)<1e-6,'relative')
-- The VR chain: the attach is turned so the muzzle equals the aim, and the
-- hand keeps its stock attach-frame offset. The drawn hand then sits at
-- aim*hand_in_muzzle: hand_in_muzzle is the roll the user sees.
do
    local attach,muzzle,hand=Pose.from_euler(5,-80,12),Pose.from_euler(8,-75,40),Pose.from_euler(-3,10,95)
    local aim=Pose.from_euler(25,-5,-15)
    local rel=Pose.relative(attach,muzzle)
    local new_attach=Pose.multiply(aim,Pose.inverse(rel))
    local drawn_hand=Pose.multiply(new_attach,Pose.relative(attach,hand))
    assert(Pose.angle(drawn_hand,Pose.multiply(aim,Pose.relative(muzzle,hand)))<1e-6,'hand_in_muzzle does not predict the drawn hand')
end
-- Fixture weapons: same rig and animation, different authored muzzle frames.
local function frame(muzzle_roll,hand_roll,jitter)
    local attach=Pose.from_euler(10,-5,0)
    local muzzle=Pose.multiply(attach,Pose.from_euler(0,0,muzzle_roll))
    local right=Pose.multiply(attach,Pose.from_euler(0,0,hand_roll+(jitter or 0)))
    local left=Pose.multiply(muzzle,Pose.from_euler(0,15,-30))
    return {rig_3p={attach={q=attach,p={0,0,1}},right={q=right,p={0,-.05,1}},left={q=left,p={-.05,.3,1.02}}},
        muzzle_3p={q=muzzle,p={0,.45,1.05}},
        rig_1p={attach={q=attach,p={0,0,1.5}},right={q=right,p={0,-.05,1.5}}},muzzle_1p={q=muzzle,p={0,.5,1.55}}}
end
local function frames(muzzle_roll,hand_roll)
    local list={}
    for i=1,15 do list[i]=frame(muzzle_roll,hand_roll,(i%3-1)*.2) end
    return list
end
local rows={Pose.combine('shotgun_p1_m1',frames(0,4)),Pose.combine('stubrevolver_p1_m1',frames(2,6)),
    Pose.combine('autogun_p1_m1',frames(35,5)),Pose.combine('lasgun_p1_m1',frames(-3,4)),
    Pose.combine('autogun_p2_m1',frames(1,-28))}
local baseline,flags=Pose.flag(rows)
assert(near(baseline.muzzle_in_attach_3p.roll,1,1e-6) and baseline.muzzle_in_attach_3p.count==2,'baseline muzzle roll')
local flagged={}
for _,flag in ipairs(flags) do flagged[flag.template..'/'..flag.metric]=flag.delta end
-- A rolled muzzle frame turns gun and hand together: hand_in_muzzle flags too.
assert(near(flagged['autogun_p1_m1/muzzle_in_attach_3p'],34,1e-6),'rolled muzzle not flagged')
assert(flagged['autogun_p1_m1/hand_in_muzzle_3p'] and flagged['autogun_p1_m1/hand_in_muzzle_1p'],'rolled muzzle missed in hand_in_muzzle')
-- A canted stock grip only shows in the hand.
assert(flagged['autogun_p2_m1/hand_in_muzzle_3p'] and not flagged['autogun_p2_m1/muzzle_in_attach_3p'],'canted grip classification')
assert(not flagged['lasgun_p1_m1/muzzle_in_attach_3p'] and not flagged['lasgun_p1_m1/hand_in_muzzle_3p'],'in-threshold weapon flagged')
for key in pairs(flagged) do assert(not key:find('^shotgun') and not key:find('^stubrevolver'),'baseline flagged against itself') end
local text=Pose.row_text(rows[3])
assert(text:find('template=autogun_p1_m1 samples=15',1,true) and text:find('muzzle_in_attach_3p=ypr:0.0,0.0,35.0',1,true) and
    text:find('roll_delta=34.0',1,true) and text:find('muzzle_length_3p=',1,true),text)
assert(rows[1].metrics.hand_in_attach_3p.spread>0 and rows[1].metrics.hand_in_attach_3p.spread<.5,'sample spread')
-- Cant: the grip's place around the bore from straight below (what
-- darktidevr_gun_aim uncants). A muzzle frame rolled 45 deg about its bore
-- sees a grip straight below the barrel at 45 deg (the worn autogun_p3).
do
    local muzzle=Pose.from_euler(0,0,-45)
    local below=Pose.rotate(muzzle,{.0557,0,-.0557})
    local canted={rig_3p={attach={q=muzzle,p={below[1],.3+below[2],1+below[3]}}},muzzle_3p={q=muzzle,p={0,.3,1}}}
    assert(near(Pose.relatives(canted).cant_3p,45,1e-6),'cant of a rolled muzzle frame')
    local upright={rig_3p={attach={q=Pose.from_euler(0,0,0),p={0,0,.94}}},muzzle_3p={q=Pose.from_euler(0,0,0),p={0,.3,1}}}
    assert(near(Pose.relatives(upright).cant_3p,0,1e-6),'cant of an upright gun')
    assert(text:find('cant_3p=',1,true),'cant missing from the row text')
end
-- No baseline weapon measured: nothing is flagged, and that is said.
do
    local only={Pose.combine('autogun_p1_m1',frames(35,5))}
    local none,none_flags=Pose.flag(only)
    assert(next(none)==nil and #none_flags==0,'flagged without a baseline')
end
-- The sweep sequencer, against a fake temporary loadout.
local clock,events=0,{}
local status,current='idle'
local pinned=0
local loadout={status=function() return status end,
    begin=function(item) assert(status=='idle');current=item;status='loading' end,
    restore=function() status='idle';pinned=pinned+1 end}
local known={shotgun_p1_m1=true,stubrevolver_p1_m1=true,autogun_p1_m1=true}
local deps={weapon=loadout,clock=function() return clock end,capacity=function() return 16-pinned end,
    item=function(name) if known[name] then return {name=name} end;return nil,'unknown_weapon_template' end,
    idle=function() return true end,template=function() return current and current.name end,
    measure=function()
        local name=current and current.name
        return frame(name=='autogun_p1_m1' and 35 or 0,5)
    end,vr_data=function() return 'vr_sight_eye=none' end,
    emit=function(kind,detail) events[#events+1]=kind..' '..detail end}
local sweep=Sweep.new(Pose,deps)
sweep.begin({'shotgun_p1_m1','missing_p9_m9','stubrevolver_p1_m1','autogun_p1_m1'})
local function run(steps)
    for _=1,steps do
        clock=clock+.05
        if status=='loading' then status='active' end
        sweep.update()
        if sweep.status()=='idle' then return end
    end
end
run(400)
local log=table.concat(events,'\n')
assert(sweep.status()=='idle' and log:find('ranged_sweep_done reason=complete measured=3 skipped=1 flagged=',1,true),log)
assert(log:find('ranged_sweep_skip template=missing_p9_m9 reason=unknown_weapon_template',1,true),'unknown template not skipped')
assert(log:find('ranged_roll_flag template=autogun_p1_m1 metric=muzzle_in_attach_3p',1,true),'sweep did not flag the rolled muzzle')
assert(pinned==3,'each measured weapon restored exactly once')
-- The process equip limit stops the sweep and names what is left.
events={};pinned=15
sweep.begin({'shotgun_p1_m1','autogun_p1_m1'})
run(400)
log=table.concat(events,'\n')
assert(log:find('reason=process_equip_limit_restart_required measured=1 skipped=0 flagged=0 remaining=autogun_p1_m1',1,true),log)
-- A weapon that never becomes ready times out, is restored, and the sweep moves on.
events={};pinned=0
local stuck=Sweep.new(Pose,setmetatable({weapon={status=function() return status end,begin=function() status='loading' end,
    restore=function() status='idle' end}},{__index=deps}))
stuck.begin({'shotgun_p1_m1'})
for _=1,700 do clock=clock+.05;stuck.update() end
log=table.concat(events,'\n')
assert(log:find('ranged_sweep_skip template=shotgun_p1_m1 reason=timeout_loading',1,true) and stuck.status()=='idle',log)
-- Cancel restores a weapon in use.
events={}
sweep.begin({'shotgun_p1_m1'});status='active'
assert(sweep.cancel('test') and status=='idle' and table.concat(events,'\n'):find('ranged_sweep_done reason=test',1,true),'cancel')
print('testlab_ranged_sweep=pass euler_round_trip relative hand_in_muzzle_chain muzzle_and_grip_flags baseline_exclusion no_baseline sequencer skip_unknown process_limit timeout cancel')
