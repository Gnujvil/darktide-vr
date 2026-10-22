-- Local test visualization. Owns only an immediate GUI and bounded snapshots;
-- it never supplies poses to simulation or grants contact/damage eligibility.
local Debug={}
function Debug.new()
    local state={trails={raw={},virtual={}},contacts={}}
    local api={}
    function api.destroy()
        if state.gui then pcall(World.destroy_gui,state.world,state.gui) end
        state.gui=nil; state.world=nil; state.trails={raw={},virtual={}}; state.contacts={}
    end
    function api.contact(position,time)
        if not position then return end
        state.contacts[#state.contacts+1]={position=Vector3Box(position),time=time}
        if #state.contacts>16 then table.remove(state.contacts,1) end
    end
    local function line(a,b,eye,color,width)
        local delta=b-a
        local length=Vector3.length(delta)
        if length<.00001 then return end
        local right=delta/length
        local across=Vector3.cross(right,eye-(a+b)*.5)
        if Vector3.length(across)<.00001 then return end
        local up=Vector3.normalize(across)
        local tm=Matrix4x4.identity()
        Matrix4x4.set_right(tm,right); Matrix4x4.set_up(tm,up)
        Matrix4x4.set_forward(tm,Vector3.cross(up,right)); Matrix4x4.set_translation(tm,a)
        Gui.rect_3d(state.gui,tm,Vector2(0,-width*.5),1,Vector2(length,width),color)
    end
    local function axes(position,rotation,eye,color,size)
        for _,axis in ipairs({Vector3(size,0,0),Vector3(0,size,0),Vector3(0,0,size)}) do
            local arm=Quaternion.rotate(rotation,axis)
            line(position-arm,position+arm,eye,color,.005)
        end
    end
    local function box(position,rotation,volume,eye,color)
        if not volume or volume.shape~="oobb" then return end
        local half,offset=volume.half_extents,volume.offset
        local corners={}
        for x=0,1 do for y=0,1 do for z=0,1 do
            local index=x*4+y*2+z+1
            corners[index]=position+Quaternion.rotate(rotation,Vector3(
                offset[1]+(x*2-1)*half[1],offset[2]+(y*2-1)*half[2],offset[3]+(z*2-1)*half[3]))
        end end end
        for index=0,7 do
            for _,bit in ipairs({1,2,4}) do
                if math.floor(index/bit)%2==0 then line(corners[index+1],corners[index+bit+1],eye,color,.003) end
            end
        end
    end
    function api.draw(world,eye,frame,time,hands,offset,volume)
        if state.world and state.world~=world then api.destroy() end
        state.world=world
        if not state.gui then state.gui=World.create_world_gui(world,Matrix4x4.identity(),1,1,"immediate") end
        Gui.set_visible(state.gui,true)
        local orange,cyan,red=Color(210,255,150,30),Color(210,30,230,255),Color(230,255,40,40)
        local first=state.frame~=frame
        state.frame=frame
        for _,source in ipairs({"raw","virtual"}) do
            local color=source=="raw" and orange or cyan
            for _,hand in ipairs({"left","right"}) do
                local pose=hands[source][hand]
                axes(pose.position,pose.rotation,eye,color,.035)
                if hand=="right" then
                    local tip=pose.position+Quaternion.rotate(pose.rotation,Vector3(offset[1]*2,offset[2]*2,offset[3]*2))
                    line(pose.position,tip,eye,color,.007)
                    local trail=state.trails[source]
                    if first then
                        trail[#trail+1]=Vector3Box(tip)
                        if #trail>60 then table.remove(trail,1) end
                    end
                    for i=2,#trail do line(trail[i-1]:unbox(),trail[i]:unbox(),eye,color,.003) end
                    if source=="virtual" then box(pose.position,pose.rotation,volume,eye,cyan) end
                end
            end
        end
        for i=#state.contacts,1,-1 do
            local contact=state.contacts[i]
            if time-contact.time>.6 then table.remove(state.contacts,i)
            else axes(contact.position:unbox(),Quaternion.identity(),eye,red,.06) end
        end
    end
    return api
end
return Debug
