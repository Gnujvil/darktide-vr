local Visual=dofile(assert(arg[1]))
local mt={}
local function v(x,y,z) return setmetatable({x=x,y=y,z=z},mt) end
mt.__add=function(a,b) return v(a.x+b.x,a.y+b.y,a.z+b.z) end
mt.__sub=function(a,b) return v(a.x-b.x,a.y-b.y,a.z-b.z) end
Vector3={length=function(a) return math.sqrt(a.x*a.x+a.y*a.y+a.z*a.z) end}
Vector3Box=function(p) local saved=v(p.x,p.y,p.z); return {unbox=function() return saved end} end
QuaternionBox=function(q) return {unbox=function() return q end} end
local identity={0,0,0,1}
Quaternion={to_elements=function(q) return unpack(q) end,from_elements=function(...) return {...} end,
    rotate=function(_,p) return p end,multiply=function(_,q) return q end}
Unit={alive=function(u) return u.alive~=false end,local_position=function(u) return u.local_p end,
    local_rotation=function() return identity end,world_rotation=function() return identity end,
    world_position=function(u) return u.parent and u.parent.local_p+u.local_p or u.local_p end,
    set_local_position=function(u,_,p) u.local_p=p end,set_local_rotation=function() end}
World={update_unit_and_children=function() end}
local container={local_p=v(10,20,30)}
local right={parent=container,local_p=v(1,0,0)}
local left={parent=container,local_p=v(-1,0,0)}
local equipment={slot_primary={attachment_id_lookup_1p={right=right,left=left}}}
local extension={_equipment=equipment,unit_and_attachments_from_slot=function() return container end}
local visual=Visual.new()
local grips={dominant={position=v(2,3,4),rotation=identity},support={position=v(-2,3,4),rotation=identity}}
visual.apply({},extension,'slot_primary',grips)
assert(container.local_p.x==10 and container.local_p.y==20,'combined equipment container moved with dominant hand')
assert(Unit.world_position(right).x==2 and Unit.world_position(right).z==4)
assert(Unit.world_position(left).x==-2 and Unit.world_position(left).z==4)
grips.support=nil
visual.apply({},extension,'slot_primary',grips)
assert(left.local_p.x==-1 and left.local_p.z==0,'support release retained a stale attachment-root offset')
assert(Unit.world_position(right).x==2,'support release also restored the active dominant weapon')
visual.restore(); visual.restore()
assert(right.local_p.x==1 and left.local_p.x==-1)
equipment.slot_primary.attachment_id_lookup_1p=nil
visual.apply({},extension,'slot_primary',grips)
assert(container.local_p.x==2,'single unnamed weapon lost its slot-root fallback')
visual.restore()
assert(container.local_p.x==10)
print('melee_visual=pass actual_per_hand_roots untouched_container shared_world_pose support_release fallback restore_idempotent')
