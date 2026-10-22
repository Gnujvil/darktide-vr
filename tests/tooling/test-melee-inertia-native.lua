local Inertia=dofile(assert(arg[1]))
local library=assert(arg[2])
assert(not Inertia.new({profile='unknown',library_path=library}))
assert(not Inertia.new({library_path='missing-test-inertia-library.dll'}))
local state=assert(Inertia.new({profile='hammer',library_path=library}))
local pose={position={0,0,1},rotation={-.7071067811865475,0,0,.7071067811865475}}
local reference={}
local request={dominant=pose,time=0,tracking_valid=true,reference=reference,recovery=1}
local first=assert(state.update(request))
assert(first.reset and first.mass==1.4 and first.position_lag<1e-12)
pose.position[1]=.1; request.time=.01
local next_pose=assert(state.update(request))
assert(not next_pose.reset and next_pose.position_lag>0 and next_pose.position_lag<=.25)
assert(state.update(request).repeated)
assert(state.contact(0))
local stalled=assert(state.update(request))
for i=1,3 do assert(stalled.linear_velocity[i]==0 and stalled.angular_velocity[i]==0) end
request.reference={}; request.time=.02
assert(state.update(request).reset_reason==2)
request.tracking_valid=false
assert(not state.update(request))
request.tracking_valid=true; request.time=.03
assert(state.update(request).reset)
request.recovery=false
assert(not state.update(request),'nonnumeric recovery accepted')
request.recovery=1
pose.position[1]=0/0; request.time=.04
assert(not state.update(request),'nonfinite pose accepted')
assert(state.reset())
assert(state.close() and not state.close())
local result,reason=state.update(request)
assert(not result and reason=='closed')
local two=assert(Inertia.new({profile='hammer',library_path=library}))
pose={position={0,0,1},rotation={-.7071067811865475,0,0,.7071067811865475}}
local support={position={0,.3,1},rotation={0,0,0,1}}
request={dominant=pose,support=support,support_held=true,time=0,tracking_valid=true,reference={}}
assert(two.update(request).reset)
request.time=.01
local held=assert(two.update(request))
assert(held.support_engaged and held.support and held.mass==1.4)
local p=held.support.position
assert(math.abs(p[2]-.3)<.03 and math.abs(p[3]-1)<.03,'support pose does not follow shaft grip')
support.position[1]=2;request.time=.015
assert(two.update(request).reset_reason==4,'engaged support position jump generated an impulse')
support.position[1]=0;request.time=.016
assert(two.update(request).support_engaged)
support.rotation={1,0,0,0};request.time=.017
assert(two.update(request).reset_reason==4,'engaged support rotation jump generated an impulse')
request.support_held=false; request.time=.02
assert(not two.update(request).support_engaged)
two.close()
print('melee_inertia_luajit_abi=pass profiles poses velocities reset contact validation lifetime')
