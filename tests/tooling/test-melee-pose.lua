local Owner=dofile(assert(arg[1]))
local Inertia=dofile(assert(arg[2]))
local owner=assert(Owner.new(Inertia,{profile='hammer',library_path=assert(arg[3])}))
local pose={position={0,0,1},rotation={-.7071067811865475,0,0,.7071067811865475}}
local request={frame=1,time=0,dominant=pose,tracking_valid=true,reference={}}
local first=assert(owner.update(request))
assert(owner.latest()==first and owner.at(0)==first)
pose.position[1]=.1
assert(first.raw_dominant.position[1]==0,'raw snapshot aliased mutable input')
assert(owner.update(request)==first,'render consumer advanced simulation')
request.frame=2; request.time=.02
local second=assert(owner.update(request))
assert(second.position_lag>0 and owner.at(0)==first)
assert(owner.contact(0))
for i=1,3 do assert(owner.latest().linear_velocity[i]==0) end
request.tracking_valid=false
assert(not owner.update(request) and not owner.latest() and not owner.at(0),'same-frame tracking loss retained collider')
request.tracking_valid=true; request.frame=3; request.time=.04
assert(owner.update(request).reset)
request.reference={}
assert(owner.update(request).reset_reason==2,'same-frame reference change did not reset')
request.time=.041
local result,reason=owner.update(request)
assert(not result and reason=='frame_time_conflict' and not owner.latest())
assert(owner.close() and not owner.close())
assert(not owner.latest())
print('melee_pose_owner=pass single_step immutable_raw history reference_reset tracking_loss contact lifetime')
