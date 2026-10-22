-- Engine-independent, bounded two-hand replay. Coordinates: camera/body-local
-- metres, quaternion xyzw. No executable scenario data is accepted.
local Replay = {}
local function finite(x) return type(x)=="number" and x==x and math.abs(x)<math.huge end
local function quaternion(q)
    local scale=0
    for i=1,4 do if not finite(q[i]) then return nil end; scale=math.max(scale,math.abs(q[i])) end
    if scale<1e-12 then return nil end
    local n=0
    for i=1,4 do q[i]=q[i]/scale; n=n+q[i]*q[i] end
    n=math.sqrt(n)
    return {q[1]/n,q[2]/n,q[3]/n,q[4]/n}
end
local function slerp(a,b,u)
    local dot=0
    for i=1,4 do dot=dot+a[i]*b[i] end
    local sign=dot<0 and -1 or 1
    dot=math.min(1,math.abs(dot))
    local x,y=1-u,u
    if dot<.9995 then
        local angle=math.acos(dot)
        x,y=math.sin((1-u)*angle)/math.sin(angle),math.sin(u*angle)/math.sin(angle)
    end
    local out={}
    for i=1,4 do out[i]=x*a[i]+y*sign*b[i] end
    return quaternion(out)
end
function Replay.parse(text)
    if type(text)~="string" or #text>262144 then return nil,"scenario_size" end
    local keys={}
    for line in text:gmatch("[^\r\n]+") do
        -- "# grip=touch": rotations are raw Touch grips, not weapon hilts.
        if line:match("^%s*#%s*grip=touch%s*$") then keys.grip="touch" end
        if not line:match("^%s*#") and not line:match("^%s*$") then
            local values={}
            for token in line:gmatch("%S+") do
                local value=tonumber(token)
                if not finite(value) then return nil,"nonfinite" end
                values[#values+1]=value
            end
            if #values~=19 and #values~=20 and #values~=21 then return nil,"expected_19_20_or_21_columns" end
            for _,v in ipairs(values) do if not finite(v) then return nil,"nonfinite" end end
            local t=values[1]
            if t<0 or t>30 or (#keys==0 and t~=0) or (#keys>0 and t<=keys[#keys].t) then return nil,"timestamp_order" end
            local key={t=t,buttons={}}
            for hand,offset in pairs({left=1,right=8}) do
                local p={values[offset+1],values[offset+2],values[offset+3]}
                for i=1,3 do if math.abs(p[i])>3 then return nil,"position_limit" end end
                local q=quaternion({values[offset+4],values[offset+5],values[offset+6],values[offset+7]})
                if not q then return nil,"quaternion" end
                key[hand]={position=p,rotation=q}
            end
            for i=16,21 do
                if i>=20 and values[i]==nil then values[i]=0 end
                if values[i]~=0 and values[i]~=1 then return nil,"button_value" end
                key.buttons[i-15]=values[i]==1
            end
            keys[#keys+1]=key
            if #keys>1024 then return nil,"key_limit" end
        end
    end
    if #keys<2 or keys[#keys].t<=0 then return nil,"need_two_keys" end
    -- A replay must release every input before completing.
    for _,down in ipairs(keys[#keys].buttons) do if down then return nil,"final_buttons_held" end end
    return keys
end
function Replay.sample(keys,t)
    t=math.max(0,math.min(keys[#keys].t,t))
    local i=1
    while i<#keys-1 and keys[i+1].t<=t do i=i+1 end
    local a,b=keys[i],keys[i+1]
    local u=(t-a.t)/(b.t-a.t)
    local out={t=t,buttons={}}
    for _,hand in ipairs({"left","right"}) do
        local p={}
        for j=1,3 do p[j]=a[hand].position[j]+u*(b[hand].position[j]-a[hand].position[j]) end
        out[hand]={position=p,rotation=slerp(a[hand].rotation,b[hand].rotation,u)}
    end
    local buttons=t>=b.t and b.buttons or a.buttons
    for j=1,6 do out.buttons[j]=buttons[j] end
    return out
end
-- Preserve sub-tick pulses. A press and release may both be delivered on one
-- simulation tick, but neither edge silently disappears between samples.
function Replay.transitions(keys,previous,t)
    local before=previous<0 and {false,false,false,false,false,false} or Replay.sample(keys,previous).buttons
    local events={}
    for i=1,6 do events[i]={held=before[i],pressed=false,released=false,transitions=0} end
    for _,key in ipairs(keys) do
        if key.t>previous and key.t<=t then
            for i=1,6 do
                local event=events[i]
                if event.held~=key.buttons[i] then
                    event.held=key.buttons[i]
                    event.pressed=event.pressed or event.held
                    event.released=event.released or not event.held
                    event.transitions=event.transitions+1
                end
            end
        end
    end
    return events
end
-- One sample and input-edge set per simulation frame. Rendering reads this
-- snapshot; it must never advance a second trajectory on its own clock.
function Replay.advance(state,keys,t,frame)
    if not finite(t) or not finite(frame) or frame<0 or frame~=math.floor(frame) then return nil,"invalid_step" end
    if state.frame then
        if frame<state.frame or t<state.time then return nil,"simulation_rewind" end
        if frame==state.frame then
            if math.abs(t-state.time)>1e-7 then return nil,"frame_time_changed" end
            return state.sample
        end
        if t-state.time>.1 then return nil,"simulation_gap" end
    end
    state.start=state.start or t
    local elapsed=t-state.start
    local sample=Replay.sample(keys,elapsed)
    sample.inputs=Replay.transitions(keys,state.sample and state.sample.elapsed or -1,elapsed)
    sample.elapsed=elapsed
    state.frame,state.time,state.sample=frame,t,sample
    return sample
end
return Replay
