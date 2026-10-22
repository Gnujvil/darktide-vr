-- Online (stock authority) swings: aim solve, per-swing latch and the
-- runtime's stock route. No game, network or headset.
local root=assert(arg[1])
local prefix=root..'/mods/darktidevr/scripts/mods/darktidevr/darktidevr_melee_'
local Aim=dofile(prefix..'gesture_aim.lua')
local function close(a,b,e) return math.abs(a-b)<=(e or 1e-9) end
local function dot(a,b) return a[1]*b[1]+a[2]*b[2]+a[3]*b[3] end
local function norm(a) return math.sqrt(dot(a,a)) end
local function unit(a) local n=norm(a); return {a[1]/n,a[2]/n,a[3]/n} end
-- A reference engine frame: yaw about Z, pitch about X, roll about the
-- forward Y axis, applied yaw*pitch*roll. sign flips the roll convention.
local function mul(a,b)
    return {a[4]*b[1]+a[1]*b[4]+a[2]*b[3]-a[3]*b[2],a[4]*b[2]-a[1]*b[3]+a[2]*b[4]+a[3]*b[1],
        a[4]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[4],a[4]*b[4]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3]}
end
local function axis(i,angle) local q={0,0,0,math.cos(angle/2)}; q[i]=math.sin(angle/2); return q end
local function rotate(q,v)
    local r=mul(mul(q,{v[1],v[2],v[3],0}),{-q[1],-q[2],-q[3],q[4]})
    return {r[1],r[2],r[3]}
end
local function engine(sign)
    return function(yaw,pitch,roll,v)
        return rotate(mul(mul(axis(3,yaw),axis(1,pitch)),axis(2,sign*roll)),v)
    end
end
-- The solved orientation points forward at the swing and lays the authored
-- direction along the swing's direction across the view, in either convention.
local head={0,0,1.6}
local swings={
    {name='horizontal',points={{-.45,.65,1.3},{-.3,.66,1.3},{-.05,.68,1.31}}},
    {name='downward',points={{.1,.55,1.9},{.1,.6,1.6},{.12,.62,1.25}}},
    {name='diagonal',points={{.4,.5,1.8},{.2,.6,1.55},{-.05,.65,1.3}}},
    {name='behind_left',points={{-.6,-.1,1.4},{-.65,.15,1.4},{-.6,.4,1.35}}},
}
local authored_paths={{-1,.1,-.15},{.2,.05,-1},{.7,0,.7}}
for _,sign in ipairs({1,-1}) do
    local frame=engine(sign)
    for _,swing in ipairs(swings) do
        for _,authored in ipairs(authored_paths) do
            local yaw,pitch,roll,why=Aim.solve(head,swing.points,authored,frame)
            assert(yaw and roll and why==nil,swing.name..' did not align: '..tostring(why))
            local first,last=swing.points[1],swing.points[#swing.points]
            local d=unit({last[1]-first[1],last[2]-first[2],last[3]-first[3]})
            local target={last[1]+d[1]*Aim.LEAD-head[1],last[2]+d[2]*Aim.LEAD-head[2],last[3]+d[3]*Aim.LEAD-head[3]}
            local forward=frame(yaw,pitch,roll,{0,1,0})
            assert(dot(forward,unit(target))>1-1e-9,swing.name..' forward missed the swing')
            local across={d[1]-forward[1]*dot(d,forward),d[2]-forward[2]*dot(d,forward),d[3]-forward[3]*dot(d,forward)}
            local placed=frame(yaw,pitch,roll,unit({authored[1],0,authored[3]}))
            assert(dot(unit(placed),unit(across))>1-1e-9,swing.name..' authored path not laid along the swing')
        end
    end
end
-- With a struck point and the attack path's centre, the path (not the view
-- line) is laid through the point: a thrust at a head meets the head.
for _,sign in ipairs({1,-1}) do
    local frame=engine(sign)
    local target={.2,1.1,1.75}
    local dir=unit({target[1]-head[1],target[2]-head[2],target[3]-head[3]})
    for _,center in ipairs({{.08,1.3,-.25},{-.15,1.6,-.1}}) do
        for _,swing in ipairs({swings[1],{name='thrust',points={{.1,.4,1.6},{.15,.9,1.7}}}}) do
            local yaw,pitch,roll=Aim.solve(head,swing.points,authored_paths[1],frame,target,center)
            assert(yaw,swing.name..' did not solve with a target')
            local placed=unit(frame(yaw,pitch,roll or 0,unit(center)))
            assert(dot(placed,dir)>1-1e-6,swing.name..': the attack path missed the struck point')
        end
    end
end
-- An upside-down solution is sent upright: the same rotation, pitch in +-90.
for _,sign in ipairs({1,-1}) do
    local frame=engine(sign)
    for _,case in ipairs({{1.9,-3.57,3.12},{-4.26,-2.95,2.93},{.4,2.2,.3},{.2,.3,1}}) do
        local y,p,r=Aim.upright(case[1],case[2],case[3])
        assert(p>=-math.pi/2-1e-12 and p<=math.pi/2+1e-12,'pitch left the stock range')
        for _,v in ipairs({{1,0,0},{0,1,0},{0,0,1}}) do
            local a,b=frame(case[1],case[2],sign*case[3]*sign,v),frame(y,p,r,v)
            assert(dot(a,b)>1-1e-9,'upright form is a different rotation')
        end
    end
    assert(Aim.upright(.1,2.5,nil)==nil,'an upside-down thrust aim was sent without a roll')
    -- Solved aims always come back upright.
    for _,swing in ipairs(swings) do
        local y,p=Aim.solve(head,swing.points,authored_paths[1],frame,{.2,1.1,1.75},{.08,1.3,-.25})
        assert(y and p>=-math.pi/2-1e-12 and p<=math.pi/2+1e-12,swing.name..' solved an upside-down aim')
    end
end
-- Unaligned results keep the wrist's roll, never a guess.
do
    local frame=engine(1)
    local yaw,pitch,roll,why=Aim.solve(head,{{0,.3,1.6},{0,.6,1.6}},{1,0,0},frame)
    assert(yaw and pitch and roll==nil and why=='thrust','a thrust along the view picked a plane')
    yaw,pitch,roll,why=Aim.solve(head,swings[1].points,nil,frame)
    assert(yaw and roll==nil and why=='authored_unavailable')
    yaw,pitch,roll,why=Aim.solve(head,swings[1].points,{0,1,0},frame)
    assert(yaw and roll==nil and why=='authored_thrust')
    assert(Aim.solve(head,{{0,.6,1.3},{.01,.6,1.3}},{1,0,0},frame)==nil,'a tiny motion aimed an attack')
    assert(Aim.solve(head,{{0,.6,1.3}},{1,0,0},frame)==nil)
    assert(Aim.solve(head,{{0,.6,1.3},{0/0,.6,1.3}},{1,0,0},frame)==nil)
    assert(Aim.solve({0,.6,1.3},{{-.2,.6,1.3},{-.1,.6,1.3}},{1,0,0},frame)==nil,'a swing through the head aimed')
end
-- One orientation per swing, for the attack that swing started.
do
    local latch=Aim.latch()
    assert(not latch.push({time=0/0,yaw=0,pitch=0}) and not latch.push({time=1,yaw=1,pitch=0,roll=0/0}))
    assert(latch.push({time=10,yaw=1,pitch=.1,roll=2}))
    assert(latch.current('none',nil,10,10)==nil,'idle sent a swing orientation')
    local yaw,pitch,roll=latch.current('windup','windup',10,10)
    assert(yaw==1 and pitch==.1 and roll==2,'the swing\'s own windup lost its orientation')
    assert(latch.current('light','sweep',10.3,10.4)==1)
    assert(latch.current('block','block',10.5,10.5)==nil,'a block took a swing orientation')
    assert(latch.current('light','sweep',9.5,10.1)==nil,'an attack begun before the swing took its orientation')
    -- A swing queued during that attack waits for its own.
    assert(latch.push({time=10.6,yaw=2,pitch=0}))
    assert(latch.current('light','sweep',10.3,10.7)==1,'a queued swing turned the running attack')
    yaw,pitch,roll=latch.current('windup','windup',10.8,10.8)
    assert(yaw==2 and roll==nil and latch.count()==1)
    assert(latch.current('light','sweep',16,16)==nil,'a much later attack took an old swing\'s orientation')
    latch.clear(); assert(latch.count()==0)
end
-- The stock route: a stroke is one attack press. Nothing is owned, rerouted
-- or cancelled, and a press waits while the parser still holds one.
local deps={}
for key,file in pairs({Timing='timing',Volume='volume',Planner='sweep_plan',Bridge='action_bridge',Defense='defense',Tether='tether',Contact='contact'}) do deps[key]=dofile(prefix..file..'.lua') end
local Runtime,Pose,Inertia,Strokes=dofile(prefix..'runtime.lua'),dofile(prefix..'pose.lua'),dofile(prefix..'inertia.lua'),dofile(prefix..'strokes.lua')
local Replay=dofile(root..'/mods/darktide_testlab/scripts/mods/darktide_testlab/trajectory.lua')
local file=assert(io.open(root..'/mods/darktide_testlab/horizontal.tsv'))
local keys=assert(Replay.parse(file:read('*a'))); file:close()
local template={actions={
    windup={kind='windup',start_input='start_attack',allowed_chain_actions={
        light_attack={action_name='light'},heavy_attack={action_name='heavy',chain_time=.4}}},
    light={kind='sweep',sweeps={{}},damage_window_start=.316,allowed_chain_actions={start_attack={action_name='windup',chain_time=.6}}},
    heavy={kind='sweep',allowed_chain_actions={start_attack={action_name='windup',chain_time=.6}}}},
    weapon_box={.15,.65,.15},action_inputs={heavy_attack={input_sequence={
        {input='action_one_hold',value=true,duration=.35},{input='action_one_hold',value=false}}}}}
local weapon={weapon_template=template,actions={}}
local component={current_action_name='none',start_t=10,time_scale=1}
local queued
local extension={_weapons={slot_primary=weapon},_weapon_action_component=component,
    _action_handler={_calculate_time_scale=function() return 1 end,_validate_action=function() return true end,
        _action_input_extension={peek_next_input=function(_,id) assert(id=='weapon_action'); return queued end}},
    condition_func_params=function() return {} end}
-- Ready-in: the seconds until the running attack's chain window opens.
do
    component.current_action_name='light'; component.start_t=10
    local timing=assert(deps.Timing.live(extension,'slot_primary',10.2))
    assert(not timing.ready and close(timing.ready_in,.4),'chain wait unknown')
    timing=assert(deps.Timing.live(extension,'slot_primary',10.7))
    assert(timing.ready and timing.ready_in==0)
    component.current_action_name='none'
    timing=assert(deps.Timing.live(extension,'slot_primary',10.7))
    assert(timing.ready and timing.ready_in==0)
end
local function drive(options)
    local owner=assert(Pose.new(Inertia,{profile='hammer',library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'}))
    local emitted,cancels,commits={},0,{}
    local runtime=Runtime.new(deps,{source='synthetic',owner=owner,strokes=Strokes.new(),extension=extension,weapon=weapon,
        slot='slot_primary',unit={},defaults={sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1},authority='stock',
        cancel_on_adopt=true,to_world=function(pose) return pose.position,pose.rotation end,
        cancel_native=function() cancels=cancels+1 end,
        on_commit=function(data) commits[#commits+1]=data end,contact=options.contact,
        emit=function(kind,data) emitted[kind]=(emitted[kind] or 0)+1;emitted[kind..'_data']=data end})
    local reference,pressed={},0
    emitted.press_frames={}
    for frame=0,60 do
        local elapsed=frame/52
        if options.before then options.before(10+elapsed) end
        local sample=Replay.sample(keys,elapsed)
        local current=assert(runtime.sample({source='synthetic',active=true,tracking_valid=true,reference=reference,
            frame=frame,time=10+elapsed,pose_time=elapsed,dominant=sample.right,support=sample.left,
            support_held=false,intent=true,guarding=false}))
        local edge=runtime.inputs(frame)
        if edge.pressed then pressed=pressed+1;emitted.press_frames[#emitted.press_frames+1]=frame end
        if current.stroke.committed then
            emitted.commit_frame=frame
            local native={_player_unit=runtime,_weapon=weapon,_unit_data_extension={is_resimulating=false},
                _weapon_action_component=component,_action_sweep_component={}}
            assert(runtime.on_start(native,template.actions.light,10+elapsed)==false,'stock route owned a server attack')
            local chain=template.actions.windup.allowed_chain_actions.light_attack
            assert(runtime.select_chain(extension._action_handler,chain,10+elapsed,nil,nil,template.actions)==chain,
                'stock route rewrote a chain')
            assert(runtime.allow_chain(extension._action_handler,chain,10+elapsed)==true)
            assert(runtime.update_sweep(native,1/52,10+elapsed,template.actions.light)==false,'stock route queried a sweep')
        end
    end
    runtime.invalidate('test_end'); runtime.close()
    assert(cancels==0,'stock route cancelled a server action')
    return emitted,commits,pressed
end
do
    component.current_action_name='none'; component.start_t=10; queued=nil
    local emitted,commits,pressed=drive({})
    assert(emitted.stroke==1 and emitted.stroke_data.authority=='stock' and emitted.stroke_data.action=='light',
        'an idle swing did not press the stock light attack')
    assert(#commits==1 and commits[1].action=='light' and #commits[1].points>=2 and pressed==1)
    assert(not emitted.trajectory_selected and not emitted.interrupt,'stock route selected or interrupted an attack')
    -- A press waits while the parser still holds one.
    queued='start_attack'
    emitted,commits,pressed=drive({})
    assert(not emitted.stroke and emitted.suppressed_candidate and #commits==0 and pressed==0,
        'a swing pressed over an unconsumed input')
    -- Mid-attack: press only inside the parser's buffer before the window.
    queued=nil
    component.current_action_name='light'
    emitted=drive({before=function(t) component.start_t=t-.1 end})
    assert(not emitted.stroke,'a swing pressed far ahead of the chain window')
    emitted=drive({before=function(t) component.start_t=t-.6+Runtime.STOCK_BUFFER*.5 end})
    assert(emitted.stroke==1,'a swing just before the chain window was not buffered')
    component.current_action_name='none'
end
-- Contact look-ahead: pure prediction, the engine probe adapter, and the
-- runtime arming a stroke until its weapon will reach an enemy.
do
    local Contact=deps.Contact
    local function rot_z(angle) return {0,0,math.sin(angle/2),math.cos(angle/2)} end
    local before={position={0,0,1},rotation=rot_z(0)}
    local now={position={.1,0,1},rotation=rot_z(.2)}
    local ahead=assert(Contact.extrapolate(before,now,.05,.1))
    assert(close(ahead.position[1],.3,1e-9) and close(ahead.position[3],1,1e-9),'linear motion not continued')
    local expect=rot_z(.6)
    local d=0; for i=1,4 do d=d+ahead.rotation[i]*expect[i] end
    assert(math.abs(d)>1-1e-9,'spin not continued at constant rate')
    assert(Contact.extrapolate(before,now,0,.1)==nil and Contact.extrapolate(before,{position={0/0,0,0},rotation=rot_z(0)},.05,.1)==nil)
    assert(close(Contact.horizon({damage_window_start=.3},1.2,nil),.25) and close(Contact.horizon({damage_window_start=.3},1,.2),.5))
    assert(Contact.horizon({damage_window_start=5},1,0)==Contact.MAX_HORIZON and Contact.horizon({damage_window_start=0},1,0)==Contact.MIN_HORIZON)
    assert(close(Contact.horizon(nil,nil,nil),.3),'unknown attack timing has no fallback')
    local path=assert(Contact.path(before,now,.05,.3))
    assert(#path==Contact.STEPS+1 and path[1]==now and close(path[#path].position[1],.7,1e-9))
    -- Engine adapter: the first enemy hit zone over the poses, skipping allies,
    -- scenery without a hit zone, the attacker itself and dead units.
    local saved={Vector3=Vector3,Quaternion=Quaternion,Actor=Actor,ALIVE=ALIVE}
    Vector3=setmetatable({x=function(v) return v[1] end,y=function(v) return v[2] end,z=function(v) return v[3] end},
        {__call=function(_,x,y,z) return {x,y,z} end})
    Quaternion={from_elements=function(...) return {...} end}
    local units={self={},ally={},wall={},dead={},enemy={}}
    ALIVE={[units.self]=true,[units.ally]=true,[units.wall]=true,[units.enemy]=true}
    local actors={}
    for name,unit in pairs(units) do actors[name]={unit=unit,at={1,2,3}} end
    Actor={unit=function(actor) return actor.unit end,position=function(actor) return actor.at end}
    local per_pose={{actors.self,actors.ally,actors.wall,actors.dead},{actors.enemy}}
    local queried=0
    local context={world={},volume={},filter='filter_player_character_melee_sweep',attacker=units.self,
        enemy=function(unit) return unit~=units.ally end,
        Probe={overlap=function(_,_,_,_,filter) queried=queried+1;assert(filter=='filter_player_character_melee_sweep')
            return {actors=per_pose[queried] or {}} end},
        HitZone={get=function(unit) if unit~=units.wall then return {name='torso'} end end}}
    local hit=Contact.query(context,{now,now,now})
    assert(hit and hit.unit==units.enemy and hit.zone=='torso' and hit.step==2 and hit.position[3]==3,'enemy contact not found')
    queried=0;per_pose={{actors.ally},{actors.wall}}
    assert(Contact.query(context,{now,now})==nil,'an ally or scenery armed an attack')
    -- The probe box is anchored at the hand; only enemies inside the attack's
    -- own reach from the head count.
    local far={unit={},at={3.5,0,1.6}}
    ALIVE[far.unit]=true
    context.within=Contact.within({0,0,1.6},3)
    queried=0;per_pose={{far},{actors.enemy}}
    hit=Contact.query(context,{now,now})
    assert(hit and hit.unit==units.enemy and hit.step==2,'an enemy beyond the attack reach armed it')
    assert(Contact.within({0,0,0},0)==nil and Contact.within({0,0,0},2)({0,0,2.1})==true and Contact.within({0,0,0},2)({0,0,2.2})==false)
    context.within=nil
    for key,value in pairs(saved) do _G[key]=value end
end
-- A stroke in contact mode arms and presses only when the look-ahead finds an
-- enemy, aiming at it; one that finds none is a whiff and sends nothing.
do
    component.current_action_name='none'; component.start_t=10; queued=nil
    local calls,seen=0,nil
    local emitted,commits,pressed=drive({contact=function(args)
        calls=calls+1;seen=args
        if calls>=3 then return {zone='head',step=2,position={1,2,1.7}} end
    end})
    assert(emitted.gesture_armed==1 and emitted.gesture_contact==1 and not emitted.gesture_whiff,'contact stroke did not arm then press')
    assert(pressed==1 and emitted.press_frames[1]>emitted.commit_frame,'attack pressed before its contact')
    assert(#seen.poses==deps.Contact.STEPS+1 and seen.horizon>=deps.Contact.MIN_HORIZON,'look-ahead path missing')
    assert(#commits==1 and commits[1].target and commits[1].target[3]==1.7,'attack not aimed at the contact')
    emitted,commits,pressed=drive({contact=function() return nil end})
    assert(emitted.gesture_armed==1 and emitted.gesture_whiff==1 and pressed==0 and #commits==0,'a whiff sent an attack')
end
-- The trigger only charges. Let go without a swing, the server's charge is
-- block-cancelled: the attack stays held while block is pressed, never a
-- release that the stock parser would turn into a light attack.
do
    component.current_action_name='none'; component.start_t=10; queued=nil
    local owner=assert(Pose.new(Inertia,{profile='hammer',library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'}))
    local emitted={}
    local runtime=Runtime.new(deps,{source='synthetic',owner=owner,strokes=Strokes.new(),extension=extension,weapon=weapon,
        slot='slot_primary',unit={},defaults={sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1},authority='stock',
        to_world=function(pose) return pose.position,pose.rotation end,cancel_native=function() error('stock cancelled') end,
        emit=function(kind) emitted[kind]=(emitted[kind] or 0)+1 end})
    local still=Replay.sample(keys,0)
    local one,two={},{}
    for frame=0,14 do
        assert(runtime.sample({source='synthetic',active=true,tracking_valid=true,reference=two,frame=frame,time=20+frame/52,
            pose_time=frame/52,dominant=still.right,support=still.left,intent=true,guarding=false,heavy_intent=frame>=1 and frame<=3}))
        one[frame]=runtime.inputs(frame); two[frame]=runtime.block_inputs(frame)
    end
    runtime.close()
    assert(emitted.charge_start==1 and emitted.charge_cancel==1 and not emitted.stroke)
    assert(one[1].pressed and one[1].held and one[3].held and not one[3].released,'trigger did not charge')
    for frame=4,6 do assert(one[frame].held and not one[frame].released and not one[frame].pressed,'charge released before its block') end
    assert(one[7].released and not one[7].held and not one[8].held,'charge not released after the block took it')
    assert(two[4].pressed and two[4].held and two[9].held and not two[9].released,'no cancelling block')
    assert(two[10].released and not two[10].held and not two[11].held and not two[11].pressed,'cancelling block not let go')
    for frame=0,3 do assert(not two[frame].held,'block before the trigger was let go') end
end
print('PASS: contact look-ahead (prediction, probe, arm/press/whiff), online trigger charge cancelled into block, online swing aim in both roll conventions, thrust/short/through-head refusals, per-swing latch, stock press route and buffer gate')
