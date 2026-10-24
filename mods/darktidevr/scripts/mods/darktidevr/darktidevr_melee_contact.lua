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
Contact.STEPS=6
Contact.MIN_HORIZON,Contact.MAX_HORIZON=.12,.6
-- A swing presses as soon as it is seen if an enemy lies on its way: this far
-- ahead even when the attack lands sooner (user, 22 October: launch the
-- attack when the swing is detected, at the first enemy on its way).
Contact.WAY=.45
-- Predicted poses at most this far apart, so a longer way still probes
-- every slice of the swing; at most MAX_STEPS of them.
Contact.STEP_SECONDS,Contact.MAX_STEPS=.05,12
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
-- How far ahead a swing's way is probed: its attack's press-to-damage
-- horizon, or WAY when that is shorter.
function Contact.way(horizon)
    if not finite(horizon) then return Contact.WAY end
    return math.max(horizon,math.min(Contact.MAX_HORIZON,Contact.WAY))
end
local function rotate(q,v)
    local r=mul(mul(q,{v[1],v[2],v[3],0}),{-q[1],-q[2],-q[3],q[4]})
    return {r[1],r[2],r[3]}
end
-- The current pose and the predicted poses up to horizon: STEPS of them, or
-- more for a longer horizon (STEP_SECONDS apart, at most MAX_STEPS).
-- held: the drawn weapon now, when previous/current are the hand carrying
-- it. Each predicted hand pose then carries the weapon as it is held now:
-- the weapon's inertia lag is kept, not continued as a spin (PC run fastE,
-- 22 October: a heavy maul head trailing a fast swing turned its predicted
-- path away from the enemy it was about to strike, so the press waited
-- until the weapon was 30 ms away).
function Contact.path(previous,current,span,horizon,held)
    local carry
    if held then
        if not vector(held.position) or not quaternion(held.rotation) or not vector(current.position) or
                not quaternion(current.rotation) then return nil end
        local q=normalize(current.rotation)
        local inverse={-q[1],-q[2],-q[3],q[4]}
        local p,h=current.position,held.position
        carry={position=rotate(inverse,{h[1]-p[1],h[2]-p[2],h[3]-p[3]}),rotation=normalize(mul(inverse,held.rotation))}
    end
    local poses={held or current}
    local steps=Contact.STEPS
    if finite(horizon) and horizon>0 then
        steps=math.max(steps,math.min(Contact.MAX_STEPS,math.ceil(horizon/Contact.STEP_SECONDS-1e-9)))
    end
    for step=1,steps do
        local pose=Contact.extrapolate(previous,current,span,horizon*step/steps)
        if not pose then return nil end
        if carry then
            local at=rotate(pose.rotation,carry.position)
            pose={position={pose.position[1]+at[1],pose.position[2]+at[2],pose.position[3]+at[3]},
                rotation=normalize(mul(pose.rotation,carry.rotation))}
        end
        poses[#poses+1]=pose
    end
    return poses
end
-- A reach gate around the first-person origin (an engine Vector3): the
-- attack's own reach plus a margin for hit zones that sit inside the body.
-- motion (optional): {velocity={x,y,z}, horizon=s, count=n}, the character's
-- own velocity over the probed way of n poses: the attack swings from where
-- the head will be when the weapon gets there, not from where it is now
-- (user, 24 October: worn swings registered 85% standing, 46-65% running).
Contact.REACH_MARGIN=.15
function Contact.within(head,reach,motion)
    if not finite(reach) or reach<=0 then return nil end
    local x,y,z=Vector3.x(head),Vector3.y(head),Vector3.z(head)
    local limit=(reach+Contact.REACH_MARGIN)^2
    local v=type(motion)=="table" and vector(motion.velocity) and motion.velocity or nil
    local horizon,count=v and tonumber(motion.horizon),v and tonumber(motion.count)
    return function(p,step)
        local t=0
        if v and finite(horizon) and finite(count) and count>1 and tonumber(step) then t=math.max(0,step-1)*horizon/(count-1) end
        local hx,hy,hz=x,y,z
        if t>0 then hx,hy,hz=x+v[1]*t,y+v[2]*t,z+v[3]*t end
        return (p[1]-hx)^2+(p[2]-hy)^2+(p[3]-hz)^2<=limit
    end
end
-- Where the attack's target sits relative to the head when the attack lands:
-- delay seconds from now, the character has moved by its velocity. Aiming
-- from the head now at that point points the attack the same way as aiming
-- from the head then at the enemy. The enemy's own velocity is not used: an
-- enemy held against the player (or the testlab's anchored targets) reports
-- its walk while it does not move (PC run moveB, 24 October: leads of 2.2 m
-- sideways). The two bodies cannot pass through each other: the target is led
-- no closer than LEAD_MIN metres across the ground (PC run moveA: running at
-- 4 m/s into a target 1.2 m away, a press led by its full 0.4 s would aim
-- behind the head). Returns the shifted target and zones (new tables) and the
-- shift, or the inputs.
Contact.LEAD_MIN=.6
-- The character's mean velocity over the last VELOCITY_WINDOW seconds of
-- sampled velocities: a body sliding back and forth against an enemy (PC run
-- moveC, 24 October: 0.2-4.6 m/s, flipping sideways frame to frame) is led
-- by its net motion, a steady run by its speed. add(t, {x,y,z} or nil) once
-- per simulation frame; velocity() -> {x,y,z} or nil.
Contact.VELOCITY_WINDOW=.25
function Contact.motion()
    local samples={}
    local api={}
    function api.add(t,v)
        if not finite(t) then return end
        local last=samples[#samples]
        if last and t<=last.t then
            if t==last.t then return end
            samples={}
        end
        if vector(v) then samples[#samples+1]={t=t,v={v[1],v[2],v[3]}} end
        while samples[1] and samples[1].t<t-Contact.VELOCITY_WINDOW do table.remove(samples,1) end
    end
    function api.velocity()
        if #samples==0 then return nil end
        local sum={0,0,0}
        for _,sample in ipairs(samples) do for i=1,3 do sum[i]=sum[i]+sample.v[i] end end
        return {sum[1]/#samples,sum[2]/#samples,sum[3]/#samples}
    end
    return api
end
function Contact.lead(eye,target,zones,delay,velocity)
    if not vector(eye) or not vector(target) or not finite(delay) or delay<=0 or not vector(velocity) then return target,zones end
    local d={-velocity[1]*delay,-velocity[2]*delay,-velocity[3]*delay}
    if d[1]==0 and d[2]==0 and d[3]==0 then return target,zones end
    -- The first point along the shift where the ground distance reaches
    -- LEAD_MIN (|p+s*d|=LEAD_MIN), if the shift comes that close at all.
    local x,y,m=target[1]-eye[1],target[2]-eye[2],Contact.LEAD_MIN
    local a,b,c=d[1]^2+d[2]^2,x*d[1]+y*d[2],x*x+y*y-m*m
    if a>0 and b<0 then
        local s=c<=0 and 0 or nil
        if not s and b*b-a*c>=0 then
            local first=(-b-math.sqrt(b*b-a*c))/a
            if first<1 then s=first end
        end
        if s then d={d[1]*s,d[2]*s,d[3]*s} end
    end
    local moved={target[1]+d[1],target[2]+d[2],target[3]+d[3]}
    local shifted=zones
    if type(zones)=="table" then
        shifted={}
        for i,zone in ipairs(zones) do shifted[i]={zone[1]+d[1],zone[2]+d[2],zone[3]+d[3],zone=zone.zone} end
    end
    return moved,shifted,d
end
-- Engine adapter: the first enemy hit zone any pose's stock sweep box would
-- overlap, as {unit, zone, position, step}, or nil. Never damages.
-- context: world, volume, filter, attacker, enemy(unit)->bool, Probe, HitZone,
-- and optionally within(position)->bool: the attack's own reach. The probe box
-- is anchored at the hand, so it can touch what the attack, swung from the
-- head, cannot reach.
function Contact.query(context,poses)
    -- Living targets only, as the stock sweep counts them: a corpse still
    -- exists (ALIVE) until it despawns, but has no health (HEALTH_ALIVE).
    local living=HEALTH_ALIVE or ALIVE
    for step,pose in ipairs(poses) do
        local result=context.Probe.overlap(context.world,context.volume,
            Vector3(pose.position[1],pose.position[2],pose.position[3]),
            Quaternion.from_elements(pose.rotation[1],pose.rotation[2],pose.rotation[3],pose.rotation[4]),
            context.filter,0)
        for _,actor in ipairs(result and result.actors or {}) do
            local unit=Actor.unit(actor)
            if unit and unit~=context.attacker and ALIVE[unit] and living[unit] and context.enemy(unit) then
                local zone=context.HitZone.get(unit,actor)
                if zone then
                    local at=Actor.position(actor)
                    local position={Vector3.x(at),Vector3.y(at),Vector3.z(at)}
                    if not context.within or context.within(position,step) then
                        return {unit=unit,zone=zone.name,step=step,position=position}
                    end
                end
            end
        end
    end
    return nil
end
-- The zones an attack may be laid on instead of the one it touched: flesh
-- that takes damage, never a shield.
function Contact.aim_zone(name)
    return type(name)=="string" and (name=="head" or name=="torso" or name:find("_arm$")~=nil or name:find("_leg$")~=nil)
end
-- Engine adapter: one enemy's hit zones as world points ({x, y, z, zone=name},
-- one per actor), or {} when unavailable. Read-only.
function Contact.zones(unit,HitZone)
    local result={}
    if not unit or type(ALIVE)~="table" or not ALIVE[unit] or type(HitZone)~="table" or type(HitZone.hit_zone_names)~="table" then return result end
    for _,name in pairs(HitZone.hit_zone_names) do
        if Contact.aim_zone(name) then
            pcall(function()
                for _,actor_name in ipairs(HitZone.get_actor_names(unit,name) or {}) do
                    local actor=Unit.actor(unit,actor_name)
                    if actor then
                        local at=Actor.position(actor)
                        result[#result+1]={Vector3.x(at),Vector3.y(at),Vector3.z(at),zone=name}
                    end
                end
            end)
        end
    end
    return result
end
return Contact
