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
function Aim.solve(head,points,authored,frame,target,center)
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
    yaw,pitch=Aim.through(yaw,pitch,roll,frame,target and forward,center)
    return Aim.upright(yaw,pitch,roll)
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
function Aim.through(yaw,pitch,roll,frame,direction,center)
    if not vector(direction) or not vector(center) or norm(center)<.3 then return yaw,pitch end
    local c=scale(center,1/norm(center))
    local ty=math.atan2(-direction[1],direction[2])
    local tp=math.atan2(direction[3],math.sqrt(direction[1]^2+direction[2]^2))
    local y,p=yaw,pitch
    for _=1,4 do
        local w=frame(y,p,roll or 0,c)
        if not vector(w) then return yaw,pitch end
        local wy=math.atan2(-w[1],w[2])
        local wp=math.atan2(w[3],math.sqrt(w[1]^2+w[2]^2))
        y=y+math.atan2(math.sin(ty-wy),math.cos(ty-wy))
        p=p+(tp-wp)
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
        if not name or name=="none" or not finite(start) or (kind~="windup" and kind~="sweep") then return nil end
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
