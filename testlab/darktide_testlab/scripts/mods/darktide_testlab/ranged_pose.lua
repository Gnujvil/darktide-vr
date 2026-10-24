-- Ranged weapon hand/muzzle frames, engine-independent. Quaternions are
-- {x,y,z,w}; frames are Darktide's (x right, y forward, z up).
--
-- Why these metrics: the VR gun alignment (darktidevr_gun_aim) turns the
-- third-person weapon attach node so the muzzle FX node's world rotation
-- equals the controller aim, and darktidevr_body_proxy.align_gun_hand then
-- carries the stock hand along in the attach frame. Composed:
--     hand_world = aim * inverse(muzzle_stock) * hand_stock
-- so the drawn gun hand's roll about the controller aim is the roll of the
-- stock hand in the stock MUZZLE frame (hand_in_muzzle). Its two factors are
-- reported too: muzzle_in_attach (the authored muzzle node frame, which turns
-- the whole gun) and hand_in_attach (the stock animation's grip).
local Pose={}
Pose.THRESHOLD_DEGREES=10
-- The weapons the user reports as held correctly.
Pose.BASELINE_PREFIXES={"shotgun_p1","stubrevolver_p1"}
-- At most 15 temporary equips per game process (testlab loader pinning).
-- Baselines first, then one mark of each family; run more marks in another
-- process: rangedsweep autogun_p1_m2,autogun_p1_m3,...
Pose.DEFAULT_TEMPLATES={"shotgun_p1_m1","stubrevolver_p1_m1","autogun_p1_m1","autogun_p2_m1","autogun_p3_m1",
    "lasgun_p1_m1","lasgun_p2_m1","lasgun_p3_m1","bolter_p1_m1","plasmagun_p1_m1","laspistol_p1_m1",
    "autopistol_p1_m1","boltpistol_p1_m1","shotpistol_shield_p1_m1","shotgun_p4_m1"}
Pose.METRICS={"hand_in_muzzle_3p","muzzle_in_attach_3p","hand_in_attach_3p","support_in_muzzle_3p",
    "hand_in_muzzle_1p","muzzle_in_attach_1p","hand_in_attach_1p"}
-- Flagged metrics: what the VR hand shows, and the authored muzzle frame.
Pose.FLAG_METRICS={"hand_in_muzzle_3p","muzzle_in_attach_3p","hand_in_muzzle_1p","muzzle_in_attach_1p"}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function normalize(q)
    if type(q)~="table" then return nil end
    for i=1,4 do if not finite(q[i]) then return nil end end
    local n=math.sqrt(q[1]^2+q[2]^2+q[3]^2+q[4]^2)
    if n<1e-9 then return nil end
    return {q[1]/n,q[2]/n,q[3]/n,q[4]/n}
end
Pose.normalize=normalize
function Pose.multiply(a,b)
    return {a[4]*b[1]+a[1]*b[4]+a[2]*b[3]-a[3]*b[2],
        a[4]*b[2]-a[1]*b[3]+a[2]*b[4]+a[3]*b[1],
        a[4]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[4],
        a[4]*b[4]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3]}
end
function Pose.inverse(q) return {-q[1],-q[2],-q[3],q[4]} end
function Pose.rotate(q,v)
    local r=Pose.multiply(Pose.multiply(q,{v[1],v[2],v[3],0}),Pose.inverse(q))
    return {r[1],r[2],r[3]}
end
-- child expressed in parent's frame.
function Pose.relative(parent,child)
    parent,child=normalize(parent),normalize(child)
    if not parent or not child then return nil end
    return normalize(Pose.multiply(Pose.inverse(parent),child))
end
function Pose.wrap(degrees)
    degrees=(degrees+180)%360-180
    if degrees==-180 then degrees=180 end
    return degrees
end
-- q = Rz(yaw) * Rx(pitch) * Ry(roll): yaw about up, pitch about right, roll
-- about forward. Degrees. Roll is the twist about the frame's own forward.
function Pose.euler(q)
    q=normalize(q)
    if not q then return nil end
    local f=Pose.rotate(q,{0,1,0})
    local u=Pose.rotate(q,{0,0,1})
    local pitch=math.asin(math.max(-1,math.min(1,f[3])))
    local yaw=math.atan2(-f[1],f[2])
    local cy,sy,cp,sp=math.cos(yaw),math.sin(yaw),math.cos(pitch),math.sin(pitch)
    local r0={cy,sy,0}
    local u0={sy*sp,-cy*sp,cp}
    local roll=math.atan2(u[1]*r0[1]+u[2]*r0[2]+u[3]*r0[3],u[1]*u0[1]+u[2]*u0[2]+u[3]*u0[3])
    return math.deg(yaw),math.deg(pitch),math.deg(roll)
end
function Pose.from_euler(yaw,pitch,roll)
    local function axis(x,y,z,degrees)
        local h=math.rad(degrees)/2
        return {x*math.sin(h),y*math.sin(h),z*math.sin(h),math.cos(h)}
    end
    return Pose.multiply(Pose.multiply(axis(0,0,1,yaw),axis(1,0,0,pitch)),axis(0,1,0,roll))
end
function Pose.angle(a,b)
    a,b=normalize(a),normalize(b)
    if not a or not b then return nil end
    local d=math.abs(a[1]*b[1]+a[2]*b[2]+a[3]*b[3]+a[4]*b[4])
    return math.deg(2*math.acos(math.min(1,d)))
end
-- Sign-aligned mean of nearby rotations, and the largest deviation from it.
function Pose.average(list)
    local sum,first={0,0,0,0}
    for _,q in ipairs(list) do
        q=normalize(q)
        if q then
            first=first or q
            local sign=(q[1]*first[1]+q[2]*first[2]+q[3]*first[3]+q[4]*first[4])<0 and -1 or 1
            for i=1,4 do sum[i]=sum[i]+sign*q[i] end
        end
    end
    local mean=normalize(sum)
    if not mean then return nil end
    local spread=0
    for _,q in ipairs(list) do
        local a=Pose.angle(mean,q)
        if a and a>spread then spread=a end
    end
    return mean,spread
end
-- One frame of world rotations/positions read from the engine:
-- frame.rig_3p/rig_1p = {attach={q,p},right={q,p},left={q,p}}; frame.muzzle_3p/muzzle_1p={q,p}.
function Pose.relatives(frame)
    local out={}
    for _,rig in ipairs({"3p","1p"}) do
        local nodes=frame["rig_"..rig]
        local muzzle=frame["muzzle_"..rig]
        if nodes and nodes.attach then
            if muzzle then out["muzzle_in_attach_"..rig]=Pose.relative(nodes.attach.q,muzzle.q) end
            if nodes.right then out["hand_in_attach_"..rig]=Pose.relative(nodes.attach.q,nodes.right.q) end
        end
        if nodes and muzzle then
            if nodes.right then out["hand_in_muzzle_"..rig]=Pose.relative(muzzle.q,nodes.right.q) end
            if nodes.left and rig=="3p" then out["support_in_muzzle_"..rig]=Pose.relative(muzzle.q,nodes.left.q) end
        end
        if nodes and nodes.attach and muzzle and muzzle.p and nodes.attach.p then
            local d={muzzle.p[1]-nodes.attach.p[1],muzzle.p[2]-nodes.attach.p[2],muzzle.p[3]-nodes.attach.p[3]}
            out["muzzle_length_"..rig]=math.sqrt(d[1]^2+d[2]^2+d[3]^2)
            -- The grip's place around the bore, from straight below, degrees:
            -- what darktidevr_gun_aim uncants (Alignment.cant). 0 is upright.
            local q=normalize(muzzle.q)
            if q then
                local g=Pose.rotate(Pose.inverse(q),{-d[1],-d[2],-d[3]})
                if g[1]*g[1]+g[3]*g[3]>.0004 then out["cant_"..rig]=math.deg(math.atan2(g[1],-g[3])) end
            end
        end
        if rig=="3p" and nodes and nodes.left and muzzle and muzzle.p and nodes.left.p then
            -- The support hand in the muzzle frame: the two-hand "socket".
            out.support_socket_3p=Pose.rotate(Pose.inverse(normalize(muzzle.q)),
                {nodes.left.p[1]-muzzle.p[1],nodes.left.p[2]-muzzle.p[2],nodes.left.p[3]-muzzle.p[3]})
        end
    end
    return out
end
-- Many frames of one weapon held still: mean rotation and stability per metric.
function Pose.combine(template,frames)
    local row={template=template,samples=#frames,metrics={}}
    for _,name in ipairs(Pose.METRICS) do
        local list={}
        for _,frame in ipairs(frames) do
            local value=Pose.relatives(frame)[name]
            if value then list[#list+1]=value end
        end
        local mean,spread=Pose.average(list)
        if mean then
            local yaw,pitch,roll=Pose.euler(mean)
            row.metrics[name]={q=mean,yaw=yaw,pitch=pitch,roll=roll,spread=spread,samples=#list}
        end
    end
    local last=frames[#frames] and Pose.relatives(frames[#frames]) or {}
    row.muzzle_length_3p=last.muzzle_length_3p;row.muzzle_length_1p=last.muzzle_length_1p
    row.cant_3p=last.cant_3p;row.cant_1p=last.cant_1p
    row.support_socket_3p=last.support_socket_3p
    return row
end
local function baseline_row(name,prefixes)
    for _,prefix in ipairs(prefixes) do
        if name:sub(1,#prefix)==prefix then return true end
    end
    return false
end
-- Baseline = circular mean of the baseline weapons' roll, per metric.
function Pose.flag(rows,options)
    options=options or {}
    local prefixes=options.baseline or Pose.BASELINE_PREFIXES
    local threshold=options.threshold or Pose.THRESHOLD_DEGREES
    local baseline,flags={}, {}
    for _,metric in ipairs(Pose.FLAG_METRICS) do
        local s,c,n=0,0,0
        for _,row in ipairs(rows) do
            local m=row.metrics[metric]
            if m and baseline_row(row.template,prefixes) then
                s=s+math.sin(math.rad(m.roll));c=c+math.cos(math.rad(m.roll));n=n+1
            end
        end
        if n>0 then baseline[metric]={roll=math.deg(math.atan2(s,c)),count=n} end
    end
    for _,row in ipairs(rows) do
        row.deltas={}
        for _,metric in ipairs(Pose.FLAG_METRICS) do
            local m,b=row.metrics[metric],baseline[metric]
            if m and b then
                local delta=Pose.wrap(m.roll-b.roll)
                row.deltas[metric]=delta
                if math.abs(delta)>threshold and not baseline_row(row.template,prefixes) then
                    flags[#flags+1]={template=row.template,metric=metric,roll=m.roll,baseline=b.roll,delta=delta}
                end
            end
        end
    end
    return baseline,flags
end
local function q_text(q) return q and string.format("%.4f,%.4f,%.4f,%.4f",q[1],q[2],q[3],q[4]) or "unavailable" end
local function degrees(x)
    local text=string.format("%.1f",x)
    return text=="-0.0" and "0.0" or text
end
function Pose.metric_text(name,m,delta)
    if not m then return name.."=unavailable" end
    return string.format("%s=ypr:%s,%s,%s spread=%.2f q=%s roll_delta=%s",name,degrees(m.yaw),degrees(m.pitch),degrees(m.roll),
        m.spread or 0,q_text(m.q),delta and degrees(delta) or "na")
end
function Pose.row_text(row)
    local parts={"template="..row.template,"samples="..row.samples}
    for _,name in ipairs(Pose.METRICS) do
        parts[#parts+1]=Pose.metric_text(name,row.metrics[name],row.deltas and row.deltas[name])
    end
    parts[#parts+1]=string.format("muzzle_length_3p=%s muzzle_length_1p=%s support_socket_3p=%s",
        row.muzzle_length_3p and string.format("%.3f",row.muzzle_length_3p) or "na",
        row.muzzle_length_1p and string.format("%.3f",row.muzzle_length_1p) or "na",
        row.support_socket_3p and string.format("%.3f,%.3f,%.3f",unpack(row.support_socket_3p)) or "na")
    parts[#parts+1]=string.format("cant_3p=%s cant_1p=%s",row.cant_3p and degrees(row.cant_3p) or "na",
        row.cant_1p and degrees(row.cant_1p) or "na")
    return table.concat(parts," ")
end
return Pose
