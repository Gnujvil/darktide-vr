local root=assert(arg[1])
local prefix=root..'/mods/darktidevr/scripts/mods/darktidevr/darktidevr_melee_'
local Inertia,Owner,Strokes=dofile(prefix..'inertia.lua'),dofile(prefix..'pose.lua'),dofile(prefix..'strokes.lua')
local Replay=dofile(root..'/testlab/darktide_testlab/scripts/mods/darktide_testlab/trajectory.lua')
local function tip(pose)
    local q,p=pose.rotation,pose.position
    -- Fixed weapon-local tip; native combo/reach settings cannot move it.
    local x,y,z,w=q[1],q[2],q[3],q[4]
    return {p[1]+.3*2*(x*z+w*y),p[2]+.3*2*(y*z-w*x),p[3]+.3*(1-2*(x*x+y*y))}
end
for _,profile in ipairs({'knife','hammer'}) do
    for _,name in ipairs({'horizontal.tsv','whiff.tsv','idle.tsv','jiggle.tsv','two_hand.tsv','support_only.tsv'}) do
        local file=assert(io.open(root..'/testlab/darktide_testlab/'..name))
        local keys=assert(Replay.parse(file:read('*a'))); file:close()
        local owner=assert(Owner.new(Inertia,{profile=profile,library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'}))
        local strokes=Strokes.new()
        local count,reference,support_frames=0,{},0
        for frame=0,math.ceil((keys[#keys].t+.8)*52) do
            local time=frame/52
            local sample=Replay.sample(keys,time)
            local virtual=assert(owner.update({dominant=sample.right,support=sample.left,time=time,frame=frame,
                support_held=sample.buttons[3],reference=reference,tracking_valid=true,recovery=strokes.status().recovery}))
            assert(math.abs(virtual.mass-(profile=='knife' and .2 or 1.4))<1e-9,'support changed steel mass')
            if virtual.support_engaged then support_frames=support_frames+1 end
            local result=strokes.update({time=time,frame=frame,point=tip(virtual),raw_point=tip(sample.right),
                raw_support_point=virtual.support_engaged and tip(sample.left) or nil,
                interval=.57,weapon=profile,reference=reference,mode='physical',tracking_valid=true,intent=true,native_ready=true})
            if result.committed then count=count+1 end
        end
        local expected=(name=='horizontal.tsv' or name=='whiff.tsv' or name=='two_hand.tsv' or name=='support_only.tsv') and 1 or 0
        assert(count==expected,profile..' '..name..' committed '..count..' strokes, expected '..expected)
        if name=='two_hand.tsv' or name=='support_only.tsv' then
            assert(support_frames>0,'programmed support hand failed to engage')
            assert(not owner.latest().support_engaged,'support release failed')
        end
        owner.close()
    end
end
print('melee_physical_trajectory=pass real_native_solver 52hz knife hammer hit_path whiff_path stationary_gravity 50hz_jiggle moving_support support_only grip_release invariant_mass')
