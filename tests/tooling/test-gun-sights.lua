local Sights=dofile(assert(arg[1]))
local function near(a,b,tol,m) assert(math.abs(a-b)<(tol or 1e-9),m or 'mismatch') end
local function mul(a,b)
    return {a[4]*b[1]+a[1]*b[4]+a[2]*b[3]-a[3]*b[2],a[4]*b[2]-a[1]*b[3]+a[2]*b[4]+a[3]*b[1],
        a[4]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[4],a[4]*b[4]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3]}
end
local function rot(q,v) local r=mul(mul(q,{v[1],v[2],v[3],0}),{-q[1],-q[2],-q[3],q[4]}) return {r[1],r[2],r[3]} end
-- Pure offset: eye minus grip in the muzzle frame.
local o=assert(Sights.offset({x=-.008,z=.032},{x=-.007,z=-.086}))
near(o.x,-.001); near(o.z,.118)
assert(Sights.offset(nil,{x=0,z=0})==nil and Sights.offset({x=0,z=0},nil)==nil,'missing half')
assert(Sights.offset({x=0,z=.5},{x=0,z=0})==nil and Sights.offset({x=0,z=0},{x=0,z=.4})==nil,'implausible')
-- Zeroing: the sight line (11.8 cm above the grip) passes through the point.
local function sight_miss(grip,aim,offset,point,q)
    local drawn=mul(q,aim)
    local s=rot(drawn,{offset.x,0,offset.z}); s={grip[1]+s[1],grip[2]+s[2],grip[3]+s[3]}
    local f=rot(drawn,{0,1,0})
    local d={point[1]-s[1],point[2]-s[2],point[3]-s[3]}
    local along=d[1]*f[1]+d[2]*f[2]+d[3]*f[3]
    local c={d[1]-along*f[1],d[2]-along*f[2],d[3]-along*f[3]}
    return math.sqrt(c[1]^2+c[2]^2+c[3]^2), f
end
local identity={0,0,0,1}
local q=assert(Sights.zeroing({0,0,0},identity,{x=0,z=.118},{0,10,0}))
local miss,f=sight_miss({0,0,0},identity,{x=0,z=.118},{0,10,0},q)
assert(miss<.001,'sight line misses the point by '..miss)
near(math.deg(math.asin(-f[3])),math.deg(math.atan(.118/10)),.02,'pitch down by the parallax angle')
-- Any aim, any place: yawed and pitched gun away from the origin.
local yaw={0,0,math.sin(.6),math.cos(.6)}
local pitch={math.sin(-.1),0,0,math.cos(-.1)}
local aim=mul(yaw,pitch)
local grip={3,-2,1.4}
local fwd=rot(aim,{0,1,0})
local up=rot(aim,{0,0,-.05})
local point={grip[1]+fwd[1]*7+up[1],grip[2]+fwd[2]*7+up[2],grip[3]+fwd[3]*7+up[3]}
q=assert(Sights.zeroing(grip,aim,{x=-.001,z=.118},point))
assert(sight_miss(grip,aim,{x=-.001,z=.118},point,q)<.001,'general pose')
-- Too near, or too large a correction: none.
assert(Sights.zeroing({0,0,0},identity,{x=0,z=.118},{0,.5,0})==nil,'too near')
local capped=assert(Sights.zeroing({0,0,0},identity,{x=0,z=.118},{0,1,0}),'over the cap is clamped, not dropped')
near(math.deg(2*math.acos(math.abs(capped[4]))),Sights.MAX_CORRECTION_DEGREES,1e-6,'clamped to the cap')
local _,capped_forward=sight_miss({0,0,0},identity,{x=0,z=.118},{0,1,0},capped)
assert(capped_forward[3]<0,'clamped correction still turns toward the point')
-- A reticle up and to the left of the sights (head above-left of the gun):
-- the sights turn up and left.
local up_left=assert(Sights.zeroing({.15,0,-.3},identity,{x=0,z=.118},{0,10,0}))
local _,turned=sight_miss({.15,0,-.3},identity,{x=0,z=.118},{0,10,0},up_left)
assert(turned[1]<0 and turned[3]>0,'turned toward the up-left reticle')
assert(Sights.zeroing({0,0,0},identity,nil,{0,10,0})==nil,'no offset')
-- Adapter: eases toward the correction, returns aim when nothing is known.
Quaternion={to_elements=function(q) return q[1],q[2],q[3],q[4] end,from_elements=function(...) return {...} end,multiply=mul}
Vector3={x=function(v) return v[1] end,y=function(v) return v[2] end,z=function(v) return v[3] end}
local lines={}
local reticle={0,10,0}
local unit={}
local presentation={controller_aim={reticle_point_owner=unit,reticle_world_point={unbox=function() return reticle end}}}
local reticle_fresh=true
presentation.controller_aim.cached_reticle_target=function()
    if reticle_fresh then return presentation.controller_aim.reticle_world_point end
end
-- The adapter checks use the shipped eye alone, without recorded lines.
local recorded_lines=Sights.SIGHT_LINES
Sights.SIGHT_LINES={}
local api=Sights.install({info=function(_,f,...) lines[#lines+1]=string.format(f,...) end},presentation)
local out=api.drawn_rotation(unit,'galvanic_rifle_p1_m1',{0,0,0},identity,1/90)
for i=1,4 do near(out[i],identity[i],1e-12,'no grip measured yet: unchanged') end
Matrix4x4={inverse=function(m) return m end,transform=function(m,p) return {p[1]-m[1],p[2]-m[2],p[3]-m[3]} end}
api.observe_grip('galvanic_rifle_p1_m1',{0,1.153,.086},{-.007,0,0})
local function logged(text)
    for _,line in ipairs(lines) do if line:find(text,1,true) then return true end end
end
assert(logged('grip template=galvanic_rifle_p1_m1'),'grip logged')
local first=api.drawn_rotation(unit,'galvanic_rifle_p1_m1',{0,0,0},identity,1/90)
assert(first[1]~=0,'correction starts')
for _=1,60 do out=api.drawn_rotation(unit,'galvanic_rifle_p1_m1',{0,0,0},identity,1/90) end
assert(sight_miss({0,0,0},identity,{x=-.001,z=.118},reticle,{out[1],out[2],out[3],out[4]})<.002,'settled on the reticle')
assert(math.abs(first[1])<math.abs(out[1]),'eased in')
-- The renderer has rejected this sample (transport reset, old session, or
-- stale sequence), even though its raw fields still name the same player.
-- Sight zeroing must use the same validated target as the visible reticle.
reticle_fresh=false
out=api.drawn_rotation(unit,'galvanic_rifle_p1_m1',{0,0,0},identity,1/90)
for i=1,4 do near(out[i],identity[i],1e-12,'rejected reticle must not steer the gun') end
reticle_fresh=true
for _=1,60 do out=api.drawn_rotation(unit,'galvanic_rifle_p1_m1',{0,0,0},identity,1/90) end
-- A weapon with no measured sight line must not inherit another gun's
-- correction for several frames while its own calibration is unavailable.
out=api.drawn_rotation(unit,'autogun_p1_m1',{0,0,0},identity,1/90)
for i=1,4 do near(out[i],identity[i],1e-12,'unknown gun inherited another sight correction') end
-- A valid new transport/session sample also starts a fresh correction;
-- compare with a new consumer rather than carrying the old sight picture.
presentation.controller_aim.reticle_point_generation=1
presentation.controller_aim.reticle_point_session={}
for _=1,60 do out=api.drawn_rotation(unit,'galvanic_rifle_p1_m1',{0,0,0},identity,1/90) end
reticle={.4,10,.2}
presentation.controller_aim.reticle_point_generation=2
presentation.controller_aim.reticle_point_session={}
local fresh_api=Sights.install({info=function() end},presentation)
fresh_api.eyes, fresh_api.grips=api.eyes,api.grips
local fresh_out=fresh_api.drawn_rotation(unit,'galvanic_rifle_p1_m1',{0,0,0},identity,1/90)
out=api.drawn_rotation(unit,'galvanic_rifle_p1_m1',{0,0,0},identity,1/90)
for i=1,4 do near(out[i],fresh_out[i],1e-12,'new session inherited old correction') end
reticle={0,10,0}
-- Another unit's reticle point is ignored: eases back to the bore.
presentation.controller_aim.reticle_point_owner={}
for _=1,90 do out=api.drawn_rotation(unit,'galvanic_rifle_p1_m1',{0,0,0},identity,1/90) end
near(out[4],1,1e-6,'foreign reticle ignored')
-- Unknown template: unchanged.
presentation.controller_aim.reticle_point_owner=unit
out=api.drawn_rotation(unit,'autogun_p1_m1',{0,0,0},identity,1/90)
assert(math.abs(out[1])<1e-6,'unknown template')
-- The zeroing applies only as the sights reach the eye.
local d,b=Sights.eye_distance({0,0,0},identity,{x=0,z=.118},{0,-.3,.118})
near(d,0,1e-9,'eye on the sight line'); near(b,.3,1e-9,'30 cm behind the sight')
d=Sights.eye_distance({0,0,0},identity,{x=0,z=.118},{.1,-.3,.118}); near(d,.1,1e-9,'10 cm off the line')
near(Sights.zeroing_weight(0,.3),1,1e-12,'at the eye: full')
near(Sights.zeroing_weight(Sights.ZEROING_NONE_DISTANCE+.01,.3),0,1e-12,'low ready: none')
local mid=Sights.zeroing_weight((Sights.ZEROING_FULL_DISTANCE+Sights.ZEROING_NONE_DISTANCE)/2,.3)
assert(mid>0 and mid<1,'blends between'); near(mid,.5,1e-9,'smooth midpoint')
assert(Sights.zeroing_weight(0,-.1)==0,'eye in front of the sight')
assert(Sights.zeroing_weight(nil,.3)==0)
-- Adapter with a tracked eye far from the sights: the gun follows the hand.
Quaternion.right=function() return {1,0,0} end
local eye_vec=setmetatable({0,-.3,-.5},{__add=function(a,v) return {a[1]+v[1],a[2]+v[2],a[3]+v[3]} end})
local vmt={__mul=function(v,k) return {v[1]*k,v[2]*k,v[3]*k} end}
Quaternion.right=function() return setmetatable({1,0,0},vmt) end
presentation.eye_pose=function() return eye_vec,identity end
presentation.weapon_hand_roles={physical=function() return 'right' end}
presentation.controller_aim.reticle_point_owner=unit
for _=1,90 do out=api.drawn_rotation(unit,'galvanic_rifle_p1_m1',{0,0,0},identity,1/90) end
near(out[4],1,1e-6,'eye 60 cm below the sights: no zeroing')
-- Sight axis: a sight line tilted from the muzzle is what points at the reticle.
local tilt=math.rad(.5)
local axis={0,math.cos(tilt),math.sin(tilt)} -- sights look 0.5 degrees above the bore
local ax=Sights.axis(axis); near(ax[3],math.sin(tilt),1e-9,'measured axis kept')
local fallback=Sights.axis({0,.9,.4}); assert(fallback[2]==1,'implausible axis falls back to the bore')
assert(Sights.axis(nil)[2]==1)
local tilted={x=0,z=.118,axis=axis}
local tq=assert(Sights.zeroing({0,0,0},identity,tilted,{0,10,0}))
local drawn=mul(tq,identity)
local sight=rot(drawn,{0,0,.118})
local look=rot(drawn,axis)
local d={0-sight[1],10-sight[2],0-sight[3]}
local along=d[1]*look[1]+d[2]*look[2]+d[3]*look[3]
local miss_axis=math.sqrt((d[1]-along*look[1])^2+(d[2]-along*look[2])^2+(d[3]-along*look[3])^2)
assert(miss_axis<.001,'tilted sight line misses the point by '..miss_axis)
local o2=assert(Sights.offset({x=-.008,z=.032,axis=axis},{x=0,z=-.086})); near(o2.axis[3],math.sin(tilt),1e-9,'offset carries the axis')
-- Eye measurement during stock ADS. Every way it can fail logs its reason
-- once per gun: a worn shotgun session (23 October) aimed down the sights for
-- seconds at a time and the eye never arrived, with nothing in the log.
Quaternion.rotate=rot
Quaternion.forward=function(q) return rot(q,{0,1,0}) end
Vector3.distance=function(a,b) return math.sqrt((a[1]-b[1])^2+(a[2]-b[2])^2+(a[3]-b[3])^2) end
local muzzle_1p,camera_unit={},{}
-- The rig's root stays at the head, 4 cm under its animated camera node.
local rig={muzzle={10,20,1.5},camera={10,19.5,1.565},root={10,19.5,1.525},camera_node=true,
    node=7,fx_muzzle='fx_muzzle',first_person_mode=false}
local extensions={
    unit_data_system={read_component=function(_,name)
        if name=='alternate_fire' then return {is_active=true} end
        if name=='inventory' then return {wielded_slot='slot_secondary'} end
    end},
    weapon_system={weapon_template=function() return {name='shotgun_p4_m1',fx_sources={_muzzle=rig.fx_muzzle}} end},
    visual_loadout_system={unit_and_node_from_node_name=function(_,slot,node)
        if slot=='slot_secondary' and node=='fx_muzzle' and rig.node then return muzzle_1p,rig.node end
    end},
    first_person_system={first_person_unit=function() return camera_unit end,
        is_in_first_person_mode=function() return rig.first_person_mode end}}
ScriptUnit={has_extension=function(_,name) return extensions[name] end}
Unit={world_pose=function(u) assert(u==muzzle_1p); return rig.muzzle end,
    has_node=function(u,name) return u==camera_unit and name=='ap_camera_node' and rig.camera_node end,
    node=function(u,name) assert(u==camera_unit and name=='ap_camera_node'); return 3 end,
    world_position=function(u,node) assert(u==camera_unit); return node==3 and rig.camera or rig.root end,
    world_rotation=function() return identity end}
local function measuring(eye_pose)
    local measured_lines={}
    local measured_api=Sights.install({info=function(_,f,...) measured_lines[#measured_lines+1]=string.format(f,...) end},
        {gun_aim={is_gun=function() return true end},eye_pose=eye_pose})
    -- Only what the measurement logs: the recorded lines' install lines aside.
    for i=#measured_lines,1,-1 do measured_lines[i]=nil end
    return measured_api,measured_lines
end
local function count(list,text)
    local n=0
    for _,line in ipairs(list) do if line:find(text,1,true) then n=n+1 end end
    return n
end
-- Stock ADS: the hidden rig's camera node sits behind the sights (its root,
-- 4 cm lower, would put the eye under them).
local m_api,m_lines=measuring()
m_api.update(unit,0); m_api.update(unit,.5)
assert(#m_lines==0 and not m_api.eyes.shotgun_p4_m1,'nothing before the ADS settles')
for i=1,Sights.EYE_SAMPLES-1 do m_api.update(unit,1+i*.01) end
assert(not m_api.eyes.shotgun_p4_m1,'eye taken before the samples were averaged')
m_api.update(unit,2)
local eye=assert(m_api.eyes.shotgun_p4_m1,'stock ADS eye measured')
near(eye.x,0,1e-9); near(eye.z,.065,1e-9); assert(eye.source=='measured')
assert(count(m_lines,'eye template=shotgun_p4_m1 eye_in_muzzle=0.0000,0.0650')==1,'measured eye logged')
assert(count(m_lines,'samples='..Sights.EYE_SAMPLES..' spread_mm=0.0')==1,'sample count and spread logged')
-- The aim animation still swaying (the camera 1 cm up and down every other
-- frame, worn 25 October: the bolter's line moved 7 mm between sessions):
-- nothing is taken until the samples settle, and then their mean is.
do
    local sway_api,sway_lines=measuring()
    sway_api.update(unit,0)
    for i=1,2*Sights.EYE_SAMPLES do
        rig.camera={10,19.5,1.565+(i%2==0 and .01 or -.01)}
        sway_api.update(unit,1+i*.01)
    end
    assert(not sway_api.eyes.shotgun_p4_m1,'a swaying sight line was taken')
    assert(count(sway_lines,'eye_skipped template=shotgun_p4_m1 reason=unsteady')==1,'unsteady logged once')
    for i=1,Sights.EYE_SAMPLES do
        rig.camera={10,19.5,1.565+(i%2==0 and .001 or -.001)}
        sway_api.update(unit,3+i*.01)
    end
    local steady=assert(sway_api.eyes.shotgun_p4_m1,'settled samples not taken')
    near(steady.z,.065,1e-3)
    rig.camera={10,19.5,1.565}
end
local mean,spread,angle=Sights.average({{x=0,z=.06,axis={0,1,0}},{x=.002,z=.07,axis={0,1,0}}})
near(mean.x,.001,1e-12); near(mean.z,.065,1e-12); near(spread,.005,1e-12); near(angle,0,1e-9)
assert(Sights.average({})==nil)
-- A line tilted against the muzzle is offset where it passes the grip, which
-- is 25 cm ahead of the eye; without along positions, as before.
do
    local up=Sights.direction(0,2)
    near(math.deg(math.atan2(up[3],up[2])),2,1e-9); near(up[1],0,1e-12)
    local d=Sights.direction(1,-2)
    near(math.deg(math.atan2(d[1],d[2])),1,1e-9); near(math.deg(math.atan2(d[3],d[2])),-2,1e-9)
    local o=assert(Sights.offset({x=0,y=-.6,z=.1,axis=up},{x=0,y=-.35,z=-.08}))
    near(o.z,.18+.25*math.tan(math.rad(2)),1e-9,'tilted line taken at the grip')
    local flat=assert(Sights.offset({x=0,z=.1,axis=up},{x=0,z=-.08})); near(flat.z,.18,1e-12)
end
-- A recorded sight line is in use from the start, by template or by family
-- (every mark of the bolter takes bolter_p1), and the stock ADS measurement
-- never replaces it.
Sights.SIGHT_LINES=recorded_lines
assert(Sights.family('bolter_p1_m2')=='bolter_p1' and Sights.family('ogryn_thumper_p1_m3')=='ogryn_thumper_p1')
assert(Sights.family('bolter')==nil and Sights.family(nil)==nil)
do
    local b_api,b_lines=measuring()
    Matrix4x4.transform=function(m,p) return {p[1]-m[1],p[2]-m[2],p[3]-m[3]} end
    b_api.observe_grip('bolter_p1_m2',{0,.3468,.0824},{0,0,0})
    local o=assert(b_api.sight_offset('bolter_p1_m2'),'bolter mark 2 takes the family line')
    near(o.z,.0824+.1039+(.642-.3468)*math.tan(math.rad(-.1)),1e-9)
    assert(b_api.eyes.bolter_p1_m2.source=='sighted')
end
do
    local i_lines={}
    Sights.install({info=function(_,f,...) i_lines[#i_lines+1]=string.format(f,...) end},{})
    assert(count(i_lines,'sighted template=bolter_p1 line_in_muzzle=0.0000,0.1039 along=-0.6420')==1,'recorded bolter line logged')
end
do
    Sights.SIGHT_LINES.shotgun_p4_m1={x=0,y=-.5,z=.07,right_degrees=0,up_degrees=-.3}
    local s_api,s_lines=measuring()
    s_api.sight_offset('shotgun_p4_m1')
    local recorded=assert(s_api.eyes.shotgun_p4_m1,'recorded line not taken up')
    assert(recorded.source=='sighted'); near(recorded.z,.07,1e-12); near(recorded.y,-.5,1e-12)
    near(math.deg(math.atan2(recorded.axis[3],recorded.axis[2])),-.3,1e-9)
    s_api.update(unit,0)
    for i=1,2*Sights.EYE_SAMPLES do s_api.update(unit,1+i*.01) end
    assert(s_api.eyes.shotgun_p4_m1==recorded,'stock measurement replaced the recorded line')
    assert(count(s_lines,'eye template=')==0,'recorded gun measured anyway')
    Sights.SIGHT_LINES.shotgun_p4_m1=nil
end
-- The camera far from the sights (head-tracked camera, or a rig left in its
-- hip pose): rejected, and the numbers that were rejected are logged once.
rig.camera={10.2,19.6,1.82}
m_api,m_lines=measuring(function() return {10.2,19.62,1.82},identity end)
m_api.update(unit,0); m_api.update(unit,1); m_api.update(unit,1.1); m_api.update(unit,2)
assert(not m_api.eyes.shotgun_p4_m1,'implausible eye not stored')
assert(count(m_lines,'eye_skipped template=shotgun_p4_m1 reason=implausible')==1,'implausible eye logged once')
local skipped=m_lines[1]
assert(skipped:find('eye_in_muzzle=0.2000,-0.4000,0.3200',1,true),'rejected eye in the muzzle frame: '..skipped)
assert(skipped:find('camera_to_muzzle_m=0.550',1,true),'camera to 1P muzzle distance: '..skipped)
assert(skipped:find('tracked_eye_to_camera_m=0.020',1,true),'tracked eye to camera distance: '..skipped)
assert(skipped:find('first_person_mode=false',1,true),'first-person equipment mode: '..skipped)
-- No first-person muzzle node, no muzzle name: each its own reason.
rig.camera={10,19.5,1.565}; rig.node=nil
m_api,m_lines=measuring()
m_api.update(unit,0); m_api.update(unit,1); m_api.update(unit,2)
assert(count(m_lines,'eye_skipped template=shotgun_p4_m1 reason=no_muzzle_node')==1,'missing 1P muzzle node logged once')
rig.node=7; rig.camera_node=false
m_api,m_lines=measuring()
m_api.update(unit,0); m_api.update(unit,1); m_api.update(unit,2)
assert(not m_api.eyes.shotgun_p4_m1,'eye taken from the rig root')
assert(count(m_lines,'eye_skipped template=shotgun_p4_m1 reason=no_camera_node')==1,'missing camera node logged once')
rig.camera_node=true; rig.fx_muzzle=nil
m_api,m_lines=measuring()
m_api.update(unit,0); m_api.update(unit,1)
assert(count(m_lines,'eye_skipped template=shotgun_p4_m1 reason=no_muzzle_name')==1,'missing muzzle name logged')
print('gun_sights=pass offset zeroing general_pose near cap ease foreign unknown eye_weight sight_axis eye_measure eye_skipped')
