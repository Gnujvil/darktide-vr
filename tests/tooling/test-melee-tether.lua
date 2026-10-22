local root=assert(arg[1])
local prefix=root..'/mods/darktidevr/scripts/mods/darktidevr/darktidevr_melee_'
local Tether,Pose,Inertia=dofile(prefix..'tether.lua'),dofile(prefix..'pose.lua'),dofile(prefix..'inertia.lua')
local frame={target={},node=3,position={0,0,0},rotation={0,0,0,1}}
local binding=Tether.attach(frame,{position={1,0,0},rotation={0,0,0,1}})
frame.position={2,3,0};frame.rotation={0,0,math.sqrt(.5),math.sqrt(.5)}
local result=assert(Tether.resolve(binding,frame))
assert(math.abs(result.position[1]-2)<1e-10 and math.abs(result.position[2]-4)<1e-10)
assert(math.abs(result.rotation[3]-math.sqrt(.5))<1e-10)
frame.target={};assert(not Tether.resolve(binding,frame),'different actor inherited constraint')
local solver=assert(Pose.new(Inertia,{profile='hammer',library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'}))
local raw={position={0,0,1},rotation={-.7071067811865475,0,0,.7071067811865475}}
local request={frame=1,time=0,tracking_valid=true,reference={},dominant=raw}
local first=assert(solver.update(request))
local constrained={position={.1,0,1},rotation=raw.rotation}
assert(solver.pin(constrained)==first and solver.latest()==first and solver.at(0)==first)
assert(first.position[1]==.1 and first.raw_dominant.position[1]==0 and first.linear_velocity[1]==0)
assert(solver.update(request)==first,'duplicate frame replaced constrained presentation snapshot')
assert(not solver.pin({position={.3,0,1},rotation=raw.rotation}),'constraint exceeded native separation bound')
assert(first.position[1]==.1,'rejected constraint partially changed presentation')
request.frame=2;request.time=.01
local resumed=assert(solver.update(request))
assert(not resumed.constrained and resumed.position[1]<.1 and resumed.raw_dominant.position[1]==0,'release failed to resume inertia')
solver.reset();assert(not solver.pin(constrained));solver.close()
local actor,target={},{}
Unit={alive=function(t) return t==target end,actor=function(t,index) assert(t==target and index==5);return actor end,
    world_position=function(t,node) assert(t==target and node==3);return 'native_node_position' end,
    world_rotation=function() return 'native_node_rotation' end}
Actor={node=function(a) assert(a==actor);return 3 end}
local action={_action_sweep_component={sweep_aborted_unit=target,sweep_aborted_actor_index=5}}
local native=assert(Tether.native_frame(action,function(p,q)
    assert(p=='native_node_position' and q=='native_node_rotation');return {position={0,0,0},rotation={0,0,0,1}}
end))
assert(native.target==target and native.node==3)
Unit.alive=function() return false end
assert(not Tether.native_frame(action,function() error('dead actor queried') end))
print('melee_tether=pass rigid_contact_frame real_DLL_pin single_snapshot raw_untouched separation_release cached_frame natural_resume native_actor_mapping')
