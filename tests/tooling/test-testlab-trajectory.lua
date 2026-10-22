local Replay=dofile(assert(arg[1]))
local f=assert(io.open(assert(arg[2]),"r")); local text=f:read("*a"); f:close()
local keys=assert(Replay.parse(text))
assert(#keys==6)
local mid=Replay.sample(keys,.525)
assert(math.abs(mid.right.position[1])<1e-10)
assert(mid.left.position[1]==-.25)
assert(Replay.sample(keys,.15).buttons[1])
assert(not Replay.sample(keys,.25).buttons[1])
assert(not Replay.sample(keys,100).buttons[1])
assert(Replay.sample(keys,-1).t==0)
local flipped=text:gsub("%-0%.70710678 0 0 0%.70710678","0.70710678 0 0 -0.70710678",1)
local antipodal=assert(Replay.parse(flipped))
local q=Replay.sample(antipodal,.1).right.rotation
assert(math.abs(math.abs(q[1])-math.sqrt(.5))<1e-8)
assert(not Replay.parse(text:gsub("0.15","0.00",1)))
assert(not Replay.parse(text:gsub("%-0.25","999",1)))
assert(not Replay.parse(text:gsub("%-0.25","garbage",1)))
assert(not Replay.parse(text.."\n2 0 0\n"))
assert(not Replay.parse(string.rep("a",262145)))
local a=Replay.sample(keys,.525); local b=Replay.sample(keys,.525)
for _,hand in ipairs({"left","right"}) do
    for i=1,3 do assert(a[hand].position[i]==b[hand].position[i]) end
end
local huge=assert(Replay.parse(text:gsub("%-0%.70710678 0 0 0%.70710678","-1e308 0 0 1e308")))
assert(math.abs(huge[1].right.rotation[1]+math.sqrt(.5))<1e-10,'quaternion overflow')
local pulse=assert(Replay.parse(text))
pulse[3].t=.151
local edges=Replay.transitions(pulse,.14,.16)
assert(edges[1].pressed and edges[1].released and not edges[1].held and edges[1].transitions==2,'sub-tick pulse lost')
local state={}
assert(Replay.advance(state,pulse,10,1))
assert(Replay.advance(state,pulse,10.08,2))
assert(Replay.advance(state,pulse,10.14,3))
local sampled=assert(Replay.advance(state,pulse,10.16,4))
assert(sampled.inputs[1].pressed and sampled.inputs[1].released)
assert(Replay.advance(state,pulse,10.16,4)==sampled,'duplicate frame changed sample')
local invalid,reason=Replay.advance(state,pulse,10.15,3)
assert(not invalid and reason=='simulation_rewind')
invalid,reason=Replay.advance(state,pulse,10.4,5)
assert(not invalid and reason=='simulation_gap')
invalid,reason=Replay.advance(state,pulse,10.17,4)
assert(not invalid and reason=='frame_time_changed')
local special=text:gsub('([^\r\n]+)',function(line)
    if line:match('^#') then return line end
    return line..(line:match('^0.15') and ' 1' or ' 0')
end)
local extended=assert(Replay.parse(special))
assert(Replay.sample(extended,.16).buttons[5])
assert(not Replay.sample(extended,1).buttons[5])
local dodge=special:gsub('([^\r\n]+)',function(line)
    if line:match('^#') then return line end
    return line..(line:match('^0.15') and ' 1' or ' 0')
end)
local dodging=assert(Replay.parse(dodge))
local dodge_edges=Replay.transitions(dodging,.14,.26)
assert(dodge_edges[6].pressed and dodge_edges[6].released and not dodge_edges[6].held,'native dodge pulse lost')
assert(not Replay.sample(keys,.16).buttons[6],'legacy scenario invented dodge')
if arg[3] then
    local scenario=assert(io.open(arg[3],'r'));local data=assert(Replay.parse(scenario:read('*a')));scenario:close()
    local edge=Replay.transitions(data,1.84,1.91)[6]
    assert(edge.pressed and edge.released and not edge.held,'prepared sticky dodge scenario lost native pulse')
end
if arg[4] then
    for _,kind in ipairs({'horizontal','idle'}) do
        local file=assert(io.open(arg[4]..'/dodge_'..kind..'.tsv','r'))
        local data=assert(Replay.parse(file:read('*a')));file:close()
        local edge=Replay.transitions(data,.49,.53)[6]
        assert(edge.pressed and edge.released and not edge.held,'movement scenario lost dodge pulse')
        if kind=='idle' then
            for _,key in ipairs(data) do
                for i=1,3 do assert(key.right.position[i]==data[1].right.position[i]) end
            end
        end
    end
end
print("testlab_trajectory=pass interpolation buttons bounds shortest_quaternion invalid_data pulse_edges simulation_ownership special_input")
