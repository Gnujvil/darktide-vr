-- Online contact look-ahead. A server attack lands its damage a windup after
-- the press, so a stroke presses only when its weapon, carried on by its own
-- recent motion, will reach an enemy within that delay. The probe never
-- damages; the stock box and stock reach decide what "reach" means.
local Contact={}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function quaternion(q) return type(q)=="table" and finite(q[1]) and finite(q[2]) and finite(q[3]) and finite(q[4]) end
local function vector(v) return type(v)=="table" and finite(v[1]) and finite(v[2]) and finite(v[3]) end
local function mul(a,b)
    return {a[4]*b[1]+a[1]*b[4]+a[2]*b[3]-a[3]*b[2],a[4]*b[2]-a[1]*b[3]+a[2]*b[4]+a[3]*b[1],
        a[4]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[4],a[4]*b[4]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3]}
end
local function normalize(q)
    local n=math.sqrt(q[1]^2+q[2]^2+q[3]^2+q[4]^2)
    return {q[1]/n,q[2]/n,q[3]/n,q[4]/n}
end
Contact.STEPS=3
Contact.MIN_HORIZON,Contact.MAX_HORIZON=.12,.6
-- The pose dt seconds after current, continuing the motion from previous
-- (span seconds earlier): constant velocity and constant world-frame spin.
function Contact.extrapolate(previous,current,span,dt)
    if type(previous)~="table" or type(current)~="table" or not vector(previous.position) or not vector(current.position) or
            not quaternion(previous.rotation) or not quaternion(current.rotation) or not finite(span) or span<=0 or
            not finite(dt) or dt<0 then return nil end
    local k=dt/span
    local p,c=current.position,previous.position
    local position={p[1]+(p[1]-c[1])*k,p[2]+(p[2]-c[2])*k,p[3]+(p[3]-c[3])*k}
    local q,r=normalize(current.rotation),normalize(previous.rotation)
    local delta=mul(q,{-r[1],-r[2],-r[3],r[4]})
    if delta[4]<0 then delta={-delta[1],-delta[2],-delta[3],-delta[4]} end
    local half=math.acos(math.max(-1,math.min(1,delta[4])))
    local s=math.sin(half)
    local rotation=q
    if s>1e-9 then
        local angle=half*2*k
        local axis={delta[1]/s,delta[2]/s,delta[3]/s}
        local sh=math.sin(angle/2)
        rotation=normalize(mul({axis[1]*sh,axis[2]*sh,axis[3]*sh,math.cos(angle/2)},q))
    end
    return {position=position,rotation=rotation}
end
-- Seconds from an attack press to its damage: the action's own damage window
-- start at its time scale, plus any wait for the running attack's chain.
function Contact.horizon(settings,scale,ready_in)
    local start=type(settings)=="table" and settings.damage_window_start
    if not finite(start) or start<0 or not finite(scale) or scale<=0 then start,scale=.3,1 end
    local value=start/scale+(finite(ready_in) and ready_in>0 and ready_in or 0)
    return math.max(Contact.MIN_HORIZON,math.min(Contact.MAX_HORIZON,value))
end
-- The current pose and STEPS predicted poses up to horizon.
function Contact.path(previous,current,span,horizon)
    local poses={current}
    for step=1,Contact.STEPS do
        local pose=Contact.extrapolate(previous,current,span,horizon*step/Contact.STEPS)
        if not pose then return nil end
        poses[#poses+1]=pose
    end
    return poses
end
-- A reach gate around the first-person origin (an engine Vector3): the
-- attack's own reach plus a margin for hit zones that sit inside the body.
Contact.REACH_MARGIN=.15
function Contact.within(head,reach)
    if not finite(reach) or reach<=0 then return nil end
    local x,y,z=Vector3.x(head),Vector3.y(head),Vector3.z(head)
    local limit=(reach+Contact.REACH_MARGIN)^2
    return function(p) return (p[1]-x)^2+(p[2]-y)^2+(p[3]-z)^2<=limit end
end
-- Engine adapter: the first enemy hit zone any pose's stock sweep box would
-- overlap, as {unit, zone, position, step}, or nil. Never damages.
-- context: world, volume, filter, attacker, enemy(unit)->bool, Probe, HitZone,
-- and optionally within(position)->bool: the attack's own reach. The probe box
-- is anchored at the hand, so it can touch what the attack, swung from the
-- head, cannot reach.
function Contact.query(context,poses)
    for step,pose in ipairs(poses) do
        local result=context.Probe.overlap(context.world,context.volume,
            Vector3(pose.position[1],pose.position[2],pose.position[3]),
            Quaternion.from_elements(pose.rotation[1],pose.rotation[2],pose.rotation[3],pose.rotation[4]),
            context.filter,0)
        for _,actor in ipairs(result and result.actors or {}) do
            local unit=Actor.unit(actor)
            if unit and unit~=context.attacker and ALIVE[unit] and context.enemy(unit) then
                local zone=context.HitZone.get(unit,actor)
                if zone then
                    local at=Actor.position(actor)
                    local position={Vector3.x(at),Vector3.y(at),Vector3.z(at)}
                    if not context.within or context.within(position) then
                        return {unit=unit,zone=zone.name,step=step,position=position}
                    end
                end
            end
        end
    end
    return nil
end
return Contact
