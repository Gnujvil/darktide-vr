local Debug=dofile(assert(arg[1]))
local mt={}
local function v(x,y,z) return setmetatable({x=x,y=y,z=z},mt) end
mt.__add=function(a,b) return v(a.x+b.x,a.y+b.y,a.z+b.z) end
mt.__sub=function(a,b) return v(a.x-b.x,a.y-b.y,a.z-b.z) end
mt.__mul=function(a,b) return v(a.x*b,a.y*b,a.z*b) end
mt.__div=function(a,b) return v(a.x/b,a.y/b,a.z/b) end
local function length(a) return math.sqrt(a.x*a.x+a.y*a.y+a.z*a.z) end
Vector3=setmetatable({length=length,normalize=function(a) return a/length(a) end,
    cross=function(a,b) return v(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x) end},
    {__call=function(_,...) return v(...) end})
Vector3Box=function(p) local saved=v(p.x,p.y,p.z); return {unbox=function() return saved end} end
Vector2=function() return {} end
Quaternion={rotate=function(_,p) return p end,identity=function() return {} end}
Color=function() return {} end
Matrix4x4={identity=function() return {} end,set_right=function() end,set_up=function() end,
    set_forward=function() end,set_translation=function() end}
local creates,destroys,lines=0,0,0
World={create_world_gui=function() creates=creates+1; return {} end,
    destroy_gui=function() destroys=destroys+1 end}
Gui={set_visible=function() end,rect_3d=function() lines=lines+1 end}
local pose={position=v(.4,.8,1),rotation={}}
local hands={raw={left=pose,right=pose},virtual={left=pose,right=pose}}
local volume={shape='oobb',offset={0,0,.3},half_extents={.1,.1,.3}}
local debug=Debug.new()
local world={}
debug.contact(v(.5,.8,1),0)
debug.draw(world,v(0,-1,1),1,0,hands,{0,0,.3},volume)
local first=lines
-- A contact recorded before the first render must survive GUI creation.
local clean=Debug.new(); lines=0
clean.draw({},v(0,-1,1),1,0,hands,{0,0,.3},volume)
assert(first>lines,'first-frame contact marker was discarded')
clean.destroy()
local max=0
for frame=2,200 do
    lines=0
    debug.draw(world,v(0,-1,1),frame,frame/90,hands,{0,0,.3},volume)
    max=math.max(max,lines)
end
assert(max<170,'debug trails grew without bound')
local before=creates
debug.draw(world,v(0,-1,1),200,200/90,hands,{0,0,.3},volume)
assert(creates==before,'render update created a new GUI')
debug.draw({},v(0,-1,1),201,201/90,hands,{0,0,.3},volume)
assert(creates==before+1 and destroys==2,'world change retained old GUI')
debug.destroy(); debug.destroy()
assert(destroys==3,'destroy was not idempotent')
print('testlab_debug=pass first_contact bounded_trails reused_gui world_change idempotent_cleanup')
