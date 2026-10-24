-- Online swing direction. A remote server runs the weapon's own next attack
-- from the stock yaw/pitch/roll input; it never sees the hand. Point that
-- input at the swing and roll it so the attack's authored path runs the way
-- the swing went. Reach, damage, timing and the attack itself stay stock.
local Aim={}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function sub(a,b) return {a[1]-b[1],a[2]-b[2],a[3]-b[3]} end
local function add(a,b) return {a[1]+b[1],a[2]+b[2],a[3]+b[3]} end
local function scale(a,s) return {a[1]*s,a[2]*s,a[3]*s} end
local function dot(a,b) return a[1]*b[1]+a[2]*b[2]+a[3]*b[3] end
local function norm(a) return math.sqrt(dot(a,a)) end
local function vector(v) return type(v)=="table" and finite(v[1]) and finite(v[2]) and finite(v[3]) end
Aim.LEAD=.15
-- head: eye position; points: the stroke's weapon-tip path so far, oldest
-- first, in the same world frame. authored: the next attack's tip direction
-- in its first-person frame (x right, y forward, z up), or nil.
-- frame(yaw,pitch,roll,v) returns the world vector of first-person v, in the
-- engine's own convention, so the roll needs no sign assumption. target: the
-- world point a predicted contact will strike, if any; it overrides the lead.
-- center: the centre of the attack's authored tip path in its first-person
-- frame; with a target, the attack's own path (not the view line) is laid
-- through the target, so a thrust at a head meets the head.
-- Returns yaw, pitch and roll (nil roll: keep the wrist's), or nil and why.
-- trace (optional table): filled with each stage's yaw/pitch/roll and its
-- landing error (radians), for diagnostics.
function Aim.solve(head,points,authored,frame,target,center,trace)
    if not vector(head) or type(points)~="table" or #points<2 or type(frame)~="function" then return nil,"invalid_input" end
    for _,point in ipairs(points) do if not vector(point) then return nil,"invalid_input" end end
    local first,last=points[1],points[#points]
    local swing=sub(last,first)
    local length=norm(swing)
    if length<.05 then return nil,"short_stroke" end
    swing=scale(swing,1/length)
    -- The stroke commits early in a swing; aim at where it is heading, or at
    -- the enemy its look-ahead found.
    local forward=sub(vector(target) and target or add(last,scale(swing,Aim.LEAD)),head)
    local reach=norm(forward)
    if reach<.1 then return nil,"too_close" end
    forward=scale(forward,1/reach)
    local yaw=math.atan2(-forward[1],forward[2])
    local pitch=math.atan2(forward[3],math.sqrt(forward[1]^2+forward[2]^2))
    local across=sub(swing,scale(forward,dot(swing,forward)))
    -- A thrust along the view has no plane to match; it still goes through
    -- the target (at the wrist's roll, unknown here: taken as level).
    if norm(across)<.2 then
        local y,p=Aim.through(yaw,pitch,0,frame,target and forward,center)
        y,p=Aim.upright(y,p,nil)
        if not y then y,p=yaw,pitch end
        return y,p,nil,"thrust"
    end
    if not vector(authored) then return yaw,pitch,nil,"authored_unavailable" end
    local plane={authored[1],0,authored[3]}
    local size=norm(plane)
    if size<1e-6 then
        local y,p=Aim.through(yaw,pitch,0,frame,target and forward,center)
        y,p=Aim.upright(y,p,nil)
        if not y then y,p=yaw,pitch end
        return y,p,nil,"authored_thrust"
    end
    plane=scale(plane,1/size)
    -- Rolling about the view turns the authored direction in the view plane:
    -- r -> cos(r)*w0 + sin(r)*w90. Pick r nearest the swing.
    local w0,w90=frame(yaw,pitch,0,plane),frame(yaw,pitch,math.pi/2,plane)
    if not vector(w0) or not vector(w90) then return yaw,pitch,nil,"frame_unavailable" end
    local roll=math.atan2(dot(across,w90),dot(across,w0))%(2*math.pi)
    if not finite(roll) then return yaw,pitch,nil,"frame_unavailable" end
    local function stage(name,sy,sp,sr)
        if type(trace)=="table" and sy then
            trace[#trace+1]={name=name,yaw=sy,pitch=sp,roll=sr,
                error=vector(center) and Aim.error(sy,sp,sr,frame,forward,center) or nil}
        end
    end
    stage("initial",yaw,pitch,roll)
    local yaw0,pitch0=yaw,pitch
    yaw,pitch=Aim.through(yaw,pitch,roll,frame,target and forward,center)
    stage("through",yaw,pitch,roll)
    local y,p,r=Aim.upright(yaw,pitch,roll)
    stage("upright",y,p,r)
    -- Aim.upright's flip is the same rotation only in one Euler composition,
    -- not the engine's (PC run fastR, 22 October: the flipped ogryn club aims
    -- landed 45-67 degrees off, over the enemy's head). Check the result
    -- through the engine's own frame; if the path no longer meets the target,
    -- lay it through again at the final roll.
    if y and vector(target) and vector(center) and Aim.error(y,p,r,frame,forward,center)>Aim.TOLERANCE then
        local y2,p2=Aim.through(y,p,r,frame,forward,center)
        local y3,p3,r3=Aim.upright(y2,p2,r)
        stage("repass",y3,p3,r3)
        if y3 and r3==r and Aim.error(y3,p3,r3,frame,forward,center)<=Aim.TOLERANCE then y,p=y3,p3 end
    end
    -- The roll that lays the path along the swing can put the target out of
    -- reach: the engine applies roll before pitch, so near 90 degrees of roll
    -- the view barely tilts up or down (PC run fastZ, 22 October: an ogryn
    -- pickaxe chop rolled 79 degrees aimed 50-70 degrees off a poxwalker below
    -- and never hit). Then the nearest roll that reaches the target is used:
    -- the attack meets the enemy, laid as close to the swing as it can be.
    if y and vector(target) and vector(center) and Aim.error(y,p,r,frame,forward,center)>Aim.TOLERANCE then
        for step=1,Aim.ROLL_STEPS do
            local found
            for _,sign in ipairs({1,-1}) do
                local candidate=(roll+sign*step*math.pi/Aim.ROLL_STEPS)%(2*math.pi)
                local cy,cp=Aim.through(yaw0,pitch0,candidate,frame,forward,center)
                local uy,up,ur=Aim.upright(cy,cp,candidate)
                if uy and ur==candidate and Aim.error(uy,up,ur,frame,forward,center)<=Aim.TOLERANCE then
                    found={uy,up,ur};break
                end
            end
            if found then
                y,p,r=found[1],found[2],found[3]
                stage("reach_roll",y,p,r)
                break
            end
        end
    end
    return y,p,r
end
-- Roll steps searched each way (of pi each) for a reachable aim.
Aim.ROLL_STEPS=12
-- A heavy keeps the wrist's roll and is not laid along the swing; it is
-- turned so its own point center (else the view centre) meets the target at
-- the roll it is sent with. The engine applies roll before pitch, so plain
-- pointing at a low enemy with the wrist rolled aimed beside it (PC overnight
-- battery, 23 October: ogryn heavies hit 1-3 of 6). Returns yaw, pitch and
-- nil (the wrist's roll reaches the target: send it as it is), or the nearest
-- roll that does reach it, to send instead (a rolled wrist cannot always tilt
-- the view down far enough, as with a light's swing roll).
function Aim.point(head,target,frame,center,roll)
    if not vector(head) or not vector(target) or type(frame)~="function" then return nil,"invalid_input" end
    local forward=sub(target,head)
    local reach=norm(forward)
    if reach<.1 then return nil,"too_close" end
    forward=scale(forward,1/reach)
    local yaw=math.atan2(-forward[1],forward[2])
    local pitch=math.atan2(forward[3],math.sqrt(forward[1]^2+forward[2]^2))
    local r=finite(roll) and roll or 0
    local c=vector(center) and center or {0,1,0}
    for step=0,Aim.ROLL_STEPS do
        for _,sign in ipairs(step==0 and {1} or {1,-1}) do
            local candidate=step==0 and r or (r+sign*step*math.pi/Aim.ROLL_STEPS)%(2*math.pi)
            local y,p=Aim.through(yaw,pitch,candidate,frame,forward,c)
            local uy,up,ur=Aim.upright(y,p,candidate)
            if uy and ur==candidate and Aim.error(uy,up,ur,frame,forward,c)<=Aim.TOLERANCE then
                return uy,up,step>0 and candidate or nil
            end
        end
    end
    return yaw,pitch
end
-- The angle between where the attack's first-person point center lands and
-- direction (a unit world vector), radians; huge when it cannot be read.
Aim.TOLERANCE=math.rad(2)
function Aim.error(yaw,pitch,roll,frame,direction,center)
    local w=frame(yaw,pitch,roll or 0,center)
    if not vector(w) or not vector(direction) then return math.huge end
    local size=norm(w)*norm(direction)
    if size<1e-9 then return math.huge end
    return math.acos(math.max(-1,math.min(1,dot(w,direction)/size)))
end
-- The same rotation with pitch within +-90 degrees: from_yaw_pitch_roll(y,p,r)
-- equals (y+pi, pi-p, r+pi). Stock input clamps pitch, so an upside-down
-- solution must be sent in this form. Without a roll the flip is not exact,
-- so such a solution is refused (nil).
function Aim.upright(yaw,pitch,roll)
    pitch=(pitch+math.pi)%(2*math.pi)-math.pi
    if pitch>math.pi/2 or pitch<-math.pi/2 then
        if roll==nil then return nil end
        pitch=(pitch>0 and math.pi or -math.pi)-pitch
        yaw=yaw+math.pi
        roll=(roll+math.pi)%(2*math.pi)
    end
    return yaw%(2*math.pi),pitch,roll
end
-- Turn yaw/pitch so the first-person point center (the attack's path) lies
-- along direction (a unit world vector) instead of the view line. Unchanged
-- without a usable direction or centre.
-- Newton steps on (yaw, pitch) with the frame's own numerical Jacobian: under
-- a large roll a pitch change moves the point sideways, and the old one-axis
-- steps never converged (PC overnight battery, 22 October: the ogryn pickaxe,
-- hammer and power maul aims landed 5-80 degrees off). The plain steps remain
-- the fallback when the Jacobian is singular.
Aim.THROUGH_STEPS=12
function Aim.through(yaw,pitch,roll,frame,direction,center)
    if not vector(direction) or not vector(center) or norm(center)<.3 then return yaw,pitch end
    local c=scale(center,1/norm(center))
    local ty=math.atan2(-direction[1],direction[2])
    local tp=math.atan2(direction[3],math.sqrt(direction[1]^2+direction[2]^2))
    -- The landing error in yaw and pitch, or nil when the frame cannot be read.
    local function miss(y,p)
        local w=frame(y,p,roll or 0,c)
        if not vector(w) then return nil end
        local wy=math.atan2(-w[1],w[2])
        local wp=math.atan2(w[3],math.sqrt(w[1]^2+w[2]^2))
        return math.atan2(math.sin(ty-wy),math.cos(ty-wy)),tp-wp
    end
    local y,p=yaw,pitch
    local h=1e-4
    for _=1,Aim.THROUGH_STEPS do
        local ey,ep=miss(y,p)
        if not ey then return yaw,pitch end
        if math.abs(ey)<1e-7 and math.abs(ep)<1e-7 then break end
        -- d(miss)/d(yaw, pitch); the step solves miss(y+dy, p+dp) = 0.
        local ay,ap=miss(y+h,p)
        local by,bp=miss(y,p+h)
        local step_y,step_p=ey,ep
        if ay and by then
            local j11,j21=(ey-ay)/h,(ep-ap)/h
            local j12,j22=(ey-by)/h,(ep-bp)/h
            local det=j11*j22-j12*j21
            if finite(det) and math.abs(det)>1e-6 then
                step_y=(j22*ey-j12*ep)/det
                step_p=(j11*ep-j21*ey)/det
                -- Damped: never more than half a turn in one step.
                local size=math.sqrt(step_y^2+step_p^2)
                if size>math.pi/2 then step_y,step_p=step_y*math.pi/2/size,step_p*math.pi/2/size end
            end
        end
        y,p=y+step_y,p+step_p
    end
    if not finite(y) or not finite(p) then return yaw,pitch end
    return y,p
end
-- One orientation per committed swing. It holds for the attack that swing
-- started: an action that began at or after the commit and within window
-- seconds of it. A queued swing waits until its own attack begins, so the
-- running attack keeps the orientation it started with.
Aim.WINDOW=1
function Aim.latch(window)
    window=window or Aim.WINDOW
    local entries={}
    local api={}
    function api.push(entry)
        if type(entry)~="table" or not finite(entry.time) or not finite(entry.yaw) or not finite(entry.pitch) then return false end
        if entry.roll~=nil and not finite(entry.roll) then return false end
        entries[#entries+1]={time=entry.time,yaw=entry.yaw,pitch=entry.pitch,roll=entry.roll}
        while #entries>4 do table.remove(entries,1) end
        return true
    end
    -- name/kind/start: the running weapon action, its kind and start time;
    -- t: now. Only an attack follows a swing; a block or push keeps the hand.
    function api.current(name,kind,start,t)
        while #entries>0 and finite(t) and t-entries[1].time>window+2 do table.remove(entries,1) end
        if not name or name=="none" or not finite(start) or (kind~="windup" and kind~="block_windup" and kind~="sweep") then return nil end
        for index=#entries,1,-1 do
            local entry=entries[index]
            if start>=entry.time-1e-4 and start-entry.time<=window then
                for _=1,index-1 do table.remove(entries,1) end
                return entry.yaw,entry.pitch,entry.roll
            end
        end
        return nil
    end
    function api.clear() entries={} end
    function api.count() return #entries end
    return api
end
return Aim
