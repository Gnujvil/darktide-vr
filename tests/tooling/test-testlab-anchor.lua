-- Offline: anchored, immortal testlab targets (anchor.lua) against a fake world.
-- arg[1]: anchor.lua
local Anchor=dofile(assert(arg[1]))
local events={}
local world={}
local function unit(name,position)
    local u={name=name,pos={position[1],position[2],position[3]},rot={0,0,0,1},max=100,damage=0,alive=true,
        keyword_after=2,checks=0,buffs={}}
    world[u]=true
    return u
end
local fail={}
local deps={
    alive=function(u) return u.alive end,
    position=function(u) return {u.pos[1],u.pos[2],u.pos[3]} end,
    rotation=function(u) return {u.rot[1],u.rot[2],u.rot[3],u.rot[4]} end,
    teleport=function(u,p,q)
        if fail.teleport then error('no mover') end
        u.pos={p[1],p[2],p[3]};u.rot={q[1],q[2],q[3],q[4]};u.teleports=(u.teleports or 0)+1
    end,
    health=function(u) return u.max-u.damage,u.max end,
    restore=function(u) if fail.restore then error('no health sync') end;u.damage=0 end,
    prepare=function(u)
        if u.prepare_error then error('no extensions') end
        u.unkillable=true;u.buffs.havoc_no_stagger=true
        return {unkillable=true,no_stagger_buff=true}
    end,
    guard=function(u) u.checks=u.checks+1;return u.buffs.havoc_no_stagger==true and u.checks>=u.keyword_after end,
    emit=function(kind,detail) events[#events+1]=kind..' '..detail end}
local anchor=Anchor.new(deps)
local function last(kind)
    for i=#events,1,-1 do if events[i]:find('^'..kind..' ') then return events[i] end end
end
local a=unit('a',{0,2,0})
local yaw30={0,0,math.sin(math.rad(15)),math.cos(math.rad(15))}
anchor.adopt(a,'boss',{0,2,0},{0,0,0,1})
assert(anchor.owns(a) and anchor.count()==1,'adopt')
assert(last('anchor_adopted'):find('target=boss position=0.000,2.000,0.000 unkillable=true no_stagger_buff=true',1,true),last('anchor_adopted'))
-- The stagger guard is reported once its keyword is live.
anchor.update()
assert(not last('anchor_ready'),'guard reported before its keyword was active')
anchor.update()
assert(last('anchor_ready'):find('target=boss unkillable=true no_stagger=true checks=2',1,true),tostring(last('anchor_ready')))
-- Small drift stays; a push is undone.
a.pos={.03,2,0};anchor.update()
assert(not a.teleports and a.pos[1]==.03,'teleported inside the dead band')
a.pos={.4,2.6,0};anchor.update()
assert(a.teleports==1 and a.pos[1]==0 and a.pos[2]==2,'push not undone')
-- Turning away is undone too, slight sway is not.
a.rot={0,0,math.sin(math.rad(2)),math.cos(math.rad(2))};anchor.update()
assert(a.teleports==1,'turned back inside the angle band')
a.rot=yaw30;anchor.update()
assert(a.teleports==2 and a.rot[4]==1,'turn not undone')
-- Damage lands, then the health comes back: after the hit, and every update.
a.damage=60
assert(anchor.after_hit(a) and a.damage==0,'after_hit did not restore')
a.damage=25;anchor.update()
assert(a.damage==0,'update did not restore')
assert(not anchor.after_hit(a),'restore reported with nothing lost')
-- A run takes its own share; the next take starts from zero.
local share=anchor.take(a)
assert(share.teleports==2 and share.restores==2 and share.healed==85 and share.no_stagger==true and share.unkillable==true,'take')
assert(math.abs(share.max_offset-math.sqrt(.4^2+.6^2))<1e-9 and share.max_angle>29,'take maxima')
local text=anchor.text(share)
assert(text:find('target=boss teleports=2 max_offset=0.721 max_angle=30.0 health_restores=2 health_restored=85.000 unkillable=true no_stagger=true',1,true),text)
local again=anchor.take(a)
assert(again.teleports==0 and again.restores==0 and again.healed==0 and again.max_offset==0,'second take not reset')
-- A guard that never activates is reported absent after GUARD_CHECKS updates.
local b=unit('b',{1,2,0});b.keyword_after=math.huge
anchor.adopt(b,'pack:1',{1,2,0},nil)
for _=1,Anchor.GUARD_CHECKS-1 do anchor.update() end
assert(not (last('anchor_ready') or ''):find('pack:1',1,true),'absent guard reported early')
anchor.update()
assert(last('anchor_ready'):find('target=pack:1 unkillable=true no_stagger=false checks='..Anchor.GUARD_CHECKS,1,true),last('anchor_ready'))
-- Without a spawn rotation only the position is held.
b.rot=yaw30;anchor.update()
assert(not b.teleports,'rotation enforced without a spawn rotation')
-- Engine failures are reported once and never stop the others.
fail.teleport=true;fail.restore=true
a.pos={1,2,0};a.damage=10;b.pos={3,2,0};b.damage=10
anchor.update();anchor.update()
local errors=0;for _,e in ipairs(events) do if e:find('^anchor_error ') then errors=errors+1 end end
assert(errors==4,'each failure kind reported once per target: '..errors)
fail.teleport=false;fail.restore=false
anchor.update()
assert(a.pos[1]==0 and a.damage==0 and b.pos[1]==1,'recovered after failures')
local failed=anchor.take(a)
assert(anchor.text(failed):find('teleport_error=',1,true),'error not carried into the report')
-- Dead or despawned targets are left alone.
a.alive=false;a.pos={5,5,5};a.damage=50;anchor.update()
assert(a.pos[1]==5 and a.damage==50,'dead target moved or healed')
assert(not anchor.after_hit(a),'dead target healed after a hit')
-- A target whose extensions are missing is still held in place.
local c=unit('c',{2,2,0});c.prepare_error=true
anchor.adopt(c,'bare',{2,2,0},{0,0,0,1})
assert(last('anchor_adopted'):find('target=bare',1,true) and last('anchor_adopted'):find('error=',1,true),'prepare failure hidden')
c.pos={2.5,2,0};anchor.update();assert(c.pos[1]==2,'bare target not held')
anchor.clear()
assert(not anchor.owns(b) and anchor.count()==0,'clear')
assert(not pcall(anchor.adopt,c,'x',nil,nil),'adopt without a position accepted')
print('testlab_anchor=pass guard_wait push_undone dead_band turn_band health_after_hit health_per_update run_share guard_absent position_only failures_once dead_left bare_target clear')
