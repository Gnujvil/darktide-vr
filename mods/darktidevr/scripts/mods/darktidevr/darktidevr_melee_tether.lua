-- Numeric rigid contact attachment. Both contact frame and weapon pose are
-- body-local; the engine adapter resolves the target actor every frame.
local Tether={}
local function multiply(a,b)
    return {a[4]*b[1]+a[1]*b[4]+a[2]*b[3]-a[3]*b[2],
        a[4]*b[2]-a[1]*b[3]+a[2]*b[4]+a[3]*b[1],
        a[4]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[4],
        a[4]*b[4]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3]}
end
local function inverse(q) return {-q[1],-q[2],-q[3],q[4]} end
local function rotate(q,p)
    local value=multiply(multiply(q,{p[1],p[2],p[3],0}),inverse(q))
    return {value[1],value[2],value[3]}
end
function Tether.attach(frame,pose)
    local delta={}
    for i=1,3 do delta[i]=pose.position[i]-frame.position[i] end
    return {target=frame.target,node=frame.node,offset=rotate(inverse(frame.rotation),delta),
        rotation=multiply(inverse(frame.rotation),pose.rotation)}
end
function Tether.resolve(binding,frame)
    if not frame or frame.target~=binding.target or frame.node~=binding.node then return nil,'sticky_target_changed' end
    local offset=rotate(frame.rotation,binding.offset)
    local result={position={},rotation=multiply(frame.rotation,binding.rotation)}
    for i=1,3 do result.position[i]=frame.position[i]+offset[i] end
    return result
end
-- Reuses exactly the actor-node reference used by native SweepStickyness.
-- Native utility returns the actor centre, so preserve the weapon's initial
-- relative transform instead of snapping its grip to that centre.
function Tether.native_frame(action,from_world)
    local component=action._action_sweep_component
    local target=component.sweep_aborted_unit
    local index=component.sweep_aborted_actor_index
    if not target or not Unit.alive(target) or not index then return nil end
    local actor=Unit.actor(target,index)
    if not actor then return nil end
    local node=Actor.node(actor)
    local value=from_world(Unit.world_position(target,node),Unit.world_rotation(target,node))
    if value then value.target=target;value.node=node end
    return value
end
return Tether
