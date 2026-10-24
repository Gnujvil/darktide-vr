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
-- The textbook upright flip is the same rotation only in one Euler
-- composition. In another (here roll about up after pitch) it turned the aim
-- 150-177 degrees off the target; the result is checked through the frame and
-- laid through the target again (PC run fastR, 22 October: ogryn club lights
-- aimed 45-67 degrees over the enemy's head on every other swing).
do
    local frame=function(y,p,r,v) return rotate(mul(mul(axis(3,y),axis(1,p)),axis(3,r)),v) end
    local center={.05,1.78,-.12}
    for _,target in ipairs({{-.8,1.4,-1.2},{0,1.4,-1.2},{.8,1.4,-1.2},{-.8,1.4,-.6}}) do
        local points={{-.5,1.0,-.6},{0,1.05,-.62},{.5,1.0,-.6}}
        local y,p,r=Aim.solve({0,0,0},points,{-.68,-.30,-.39},frame,target,center)
        assert(y and p>=-math.pi/2-1e-12 and p<=math.pi/2+1e-12,'repaired aim left the stock pitch range')
        local w=frame(y,p,r or 0,center)
        assert(Aim.error(y,p,r,frame,unit(target),center)<=Aim.TOLERANCE,
            'a flipped aim missed its target: '..math.deg(Aim.error(y,p,r,frame,unit(target),center)))
        assert(dot(unit(w),unit(target))>math.cos(Aim.TOLERANCE))
    end
end
-- The attack's point lands on the target whatever the engine's Euler form: a
-- pitch of the other sign, or a roll that couples pitch into yaw, where the
-- old one-axis steps diverged (PC overnight battery, 22 October: ogryn
-- pickaxe, hammer and power maul aims 5-80 degrees off).
do
    local engines={
        neg_pitch=function(y,p,r,v) return rotate(mul(mul(axis(3,y),axis(1,-p)),axis(2,r)),v) end,
        roll_up=function(y,p,r,v) return rotate(mul(mul(axis(3,y),axis(1,p)),axis(3,r)),v) end,
        reference=engine(1)}
    for name,frame in pairs(engines) do
        for _,s in ipairs({1,-1}) do for _,tz in ipairs({-1.2,-.6,0,.6}) do for _,tx in ipairs({-.8,0,.8}) do
            local target={tx,1.4,tz}
            local points={{.5*s,1.0,-.6},{0,1.05,-.62},{-.5*s,1.0,-.6}}
            local y,p,r=Aim.solve({0,0,0},points,{-.68,-.30,-.39},frame,target,{.05,1.78,-.12})
            assert(y and p>=-math.pi/2-1e-12 and p<=math.pi/2+1e-12,name..': aim left the stock pitch range')
            local miss=Aim.error(y,p,r,frame,unit(target),{.05,1.78,-.12})
            assert(miss<=Aim.TOLERANCE,string.format('%s: aim landed %.1f deg off (s=%d tx=%.1f tz=%.1f)',name,math.deg(miss),s,tx,tz))
        end end end
    end
end
-- The game's own composition of the input orientation: yaw, then roll, then
-- pitch (roll before pitch). Measured on PC (run fastZ, 22 October): the view
-- the stock sweep was laid from, for three latched inputs.
do
    local game=function(y,p,r,v) return rotate(mul(mul(axis(3,y),axis(2,r)),axis(1,p)),v) end
    for _,seen in ipairs({{1.78,.47,3.08,1.75,-.47},{1.75,-.77,4.24,1.04,.32},{3.22,1.08,1.38,2.15,.17}}) do
        local f=game(seen[1],seen[2],seen[3],{0,1,0})
        assert(math.abs(math.atan2(-f[1],f[2])-seen[4])<.02 and math.abs(math.asin(f[3])-seen[5])<.02,
            'the game composition model no longer matches the measured view')
    end
    -- Under it a roll near 90 degrees barely lets the view tilt: an overhead
    -- chop laid along a sideways swing cannot look down at a low enemy. The
    -- nearest roll that reaches it is used, so every attack meets its target.
    local shapes={{{.05,0,-.95},{0,1.9,-.49}},{{-.68,-.30,-.39},{.05,1.78,-.12}},{{-.95,0,-.1},{-.1,1.8,-.34}}}
    for _,shape in ipairs(shapes) do
        for _,s in ipairs({1,-1}) do for _,tz in ipairs({-1.2,-.9,-.6,0,.6}) do for _,tx in ipairs({-.8,0,.8}) do
            local target={tx,1.6,tz}
            local points={{.5*s,1.0,-.6},{0,1.05,-.62},{-.5*s,1.0,-.6}}
            local y,p,r=Aim.solve({0,0,0},points,shape[1],game,target,shape[2])
            assert(y and p>=-math.pi/2-1e-12 and p<=math.pi/2+1e-12,'aim left the stock pitch range')
            local miss=Aim.error(y,p,r,game,unit(target),shape[2])
            assert(miss<=Aim.TOLERANCE,string.format('game composition: aim landed %.1f deg off',math.deg(miss)))
        end end end
    end
end
-- A heavy keeps the wrist's roll: it is turned so its own point (else the
-- view centre) meets the target at that roll, in the game's composition,
-- where plain pointing with a rolled wrist aims beside a low enemy.
do
    local game=function(y,p,r,v) return rotate(mul(mul(axis(3,y),axis(2,r)),axis(1,p)),v) end
    for _,wrist in ipairs({0,.6,-.9,2.5}) do
        for _,target in ipairs({{0,1.4,-1.0},{.6,1.2,-.4},{-.5,1.6,.3}}) do
            for _,center in ipairs({{.1,1.6,-.4},false}) do
                local y,p,sent=Aim.point({0,0,0},target,game,center or nil,wrist)
                assert(y and p>=-math.pi/2-1e-12 and p<=math.pi/2+1e-12,'heavy aim left the stock pitch range')
                local miss=Aim.error(y,p,sent or wrist,game,unit(target),center or {0,1,0})
                assert(miss<=Aim.TOLERANCE,string.format('heavy at wrist roll %.1f aimed %.1f deg off',wrist,math.deg(miss)))
            end
        end
    end
    -- Plain pointing (the old heavy aim) misses with the wrist rolled.
    local target={0,1.4,-1.0}
    local f=target; local n=norm(f)
    local py,pp=math.atan2(-f[1],f[2]),math.asin(f[3]/n)
    assert(Aim.error(py,pp,.6,game,unit(target),{0,1,0})>math.rad(10),'fixture does not show the rolled-wrist error')
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
local Replay=dofile(root..'/testlab/darktide_testlab/scripts/mods/darktide_testlab/trajectory.lua')
local file=assert(io.open(root..'/testlab/darktide_testlab/horizontal.tsv'))
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
        cancel_on_adopt=true,to_world=options.to_world or function(pose) return pose.position,pose.rotation end,
        cancel_native=function() cancels=cancels+1 end,
        on_commit=function(data) commits[#commits+1]=data end,contact=options.contact,trigger=options.trigger,
        emit=function(kind,data) emitted[kind]=(emitted[kind] or 0)+1;emitted[kind..'_data']=data end})
    local reference,pressed={},0
    emitted.press_frames={}
    for frame=0,options.frames or 60 do
        local elapsed=frame/52
        if options.before then options.before(10+elapsed) end
        local sample=Replay.sample(keys,elapsed)
        local current=assert(runtime.sample({source='synthetic',active=true,tracking_valid=true,reference=reference,
            frame=frame,time=10+elapsed,pose_time=elapsed,dominant=sample.right,support=sample.left,
            support_held=false,intent=true,guarding=false,walk_speed=options.walk}))
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
    -- The same swing while the character runs at 4 m/s (PC run moveA, 24
    -- October): the aim's stroke path is the hand's relative to the character,
    -- so the locomotion since the onset is not in it.
    local body=0
    component.current_action_name='none'; component.start_t=10; queued=nil
    local _,moving=drive({before=function(t) body=4*(t-10) end,
        to_world=function(pose) return {pose.position[1],pose.position[2]+body,pose.position[3]},pose.rotation end})
    local function swing(points) local a,b=points[1],points[#points]; return {b[1]-a[1],b[2]-a[2],b[3]-a[3]} end
    local s,m=swing(commits[1].points),swing(moving[1].points)
    assert(#moving==1 and #moving[1].points==#commits[1].points and math.abs(s[1]-m[1])<1e-6 and math.abs(s[2]-m[2])<1e-6 and
        math.abs(s[3]-m[3])<1e-6,'the aim\'s stroke path carried the character\'s locomotion')
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
    -- A swing's way (user, 22 October: press when the swing is seen, at the
    -- first enemy on its way): at least WAY ahead, sliced no coarser than
    -- STEP_SECONDS, so a longer way skips no thin target.
    assert(Contact.way(.25)==Contact.WAY and Contact.way(.5)==.5 and Contact.way(nil)==Contact.WAY,'swing way not extended')
    path=assert(Contact.path(before,now,.05,Contact.WAY))
    assert(#path==math.ceil(Contact.WAY/Contact.STEP_SECONDS-1e-9)+1 and close(path[#path].position[1],.1+.1*Contact.WAY/.05,1e-9),
        'long way not sliced finely')
    assert(#Contact.path(before,now,.05,Contact.MAX_HORIZON)==Contact.MAX_STEPS+1,'way slices not capped')
    -- The hand's motion carries the weapon as it is held now: a heavy head
    -- trailing the hand keeps its lag along the way and is not spun further
    -- by it (PC run fastE: a trailing maul's path turned away from its enemy).
    local hand_before={position={0,0,1},rotation=rot_z(0)}
    local hand_now={position={.1,0,1},rotation=rot_z(0)}
    local held={position={.1,.05,1},rotation=rot_z(-.3)}
    path=assert(Contact.path(hand_before,hand_now,.05,.3,held))
    assert(path[1]==held and #path==Contact.STEPS+1,'carried path does not start at the drawn weapon')
    local last=path[#path]
    assert(close(last.position[1],.7,1e-9) and close(last.position[2],.05,1e-9) and close(last.position[3],1,1e-9),
        'weapon not carried along the hand\'s way')
    expect=rot_z(-.3)
    d=0; for i=1,4 do d=d+last.rotation[i]*expect[i] end
    assert(math.abs(d)>1-1e-9,'the weapon\'s lag was not kept along its way')
    -- Its own lag spin (from -.1 to -.3 rad in 50 ms) would have turned it 1.2 rad more.
    local spun=assert(Contact.path({position={0,.05,1},rotation=rot_z(-.1)},held,.05,.3))[Contact.STEPS+1]
    d=0; for i=1,4 do d=d+spun.rotation[i]*expect[i] end
    assert(math.abs(d)<.9,'fixture does not show the lag spin it guards against')
    hand_now.rotation=rot_z(.4)
    path=assert(Contact.path(hand_before,hand_now,.05,.3,held))
    last=path[#path]
    -- Hand turned on to 7 x .4 rad; the weapon keeps its -.7 rad from the hand's .4.
    expect=rot_z(.4*7-.4-.3)
    d=0; for i=1,4 do d=d+last.rotation[i]*expect[i] end
    assert(math.abs(d)>1-1e-9,'the hand\'s own turn did not carry the weapon')
    assert(Contact.path(hand_before,hand_now,.05,.3,{position={0/0,0,0},rotation=rot_z(0)})==nil,'a broken held pose was carried')
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
    -- A corpse still exists (ALIVE) but has no health (HEALTH_ALIVE): the
    -- stock sweep ignores it, so it must not take the attack's aim (PC run
    -- pcO, 22 October: a swing-released heavy aimed at a body on the floor).
    local corpse={unit={},at={1,2,1}}
    ALIVE[corpse.unit]=true
    HEALTH_ALIVE={[units.self]=true,[units.enemy]=true}
    queried=0;per_pose={{corpse},{actors.enemy}}
    hit=Contact.query(context,{now,now})
    assert(hit and hit.unit==units.enemy and hit.step==2,'a corpse took the attack\'s contact')
    HEALTH_ALIVE=nil
    -- The probe box is anchored at the hand; only enemies inside the attack's
    -- own reach from the head count.
    local far={unit={},at={3.5,0,1.6}}
    ALIVE[far.unit]=true
    context.within=Contact.within({0,0,1.6},3)
    queried=0;per_pose={{far},{actors.enemy}}
    hit=Contact.query(context,{now,now})
    assert(hit and hit.unit==units.enemy and hit.step==2,'an enemy beyond the attack reach armed it')
    assert(Contact.within({0,0,0},0)==nil and Contact.within({0,0,0},2)({0,0,2.1})==true and Contact.within({0,0,0},2)({0,0,2.2})==false)
    -- Moving (user, 24 October: running swings registered far less often): the
    -- reach is from where the head will be when the weapon gets there. Running
    -- at 4 m/s, an enemy 3.5 m ahead is out of a 3 m reach now, in it at the
    -- way's last pose 0.4 s on; backing away, one 2.9 m ahead leaves it.
    local running=Contact.within({0,0,0},3,{velocity={4,0,0},horizon=.4,count=5})
    assert(running({3.5,0,0},1)==false and running({3.5,0,0},5)==true,'the reach gate ignored the character running at the enemy')
    assert(Contact.within({0,0,0},3,{velocity={-4,0,0},horizon=.4,count=5})({2.9,0,0},5)==false,'backing away kept the enemy in reach')
    context.within=Contact.within({0,0,1.6},3,{velocity={4,0,0},horizon=.4,count=5})
    queried=0;per_pose={{far},{},{},{},{far}}
    hit=Contact.query(context,{now,now,now,now,now})
    assert(hit and hit.unit==far.unit and hit.step==5,'running at an enemy: not out of reach now and in reach on arrival')
    -- The aim's target where it will be relative to the head when the attack
    -- lands: running at 5 m/s, 0.3 s on.
    local eye={0,0,1.6}
    local led,zones,shift=Contact.lead(eye,{2.5,0,1},{{2.5,0,1.5,zone='head'}},.3,{5,0,0})
    assert(math.abs(led[1]-1)<1e-9 and math.abs(zones[1][1]-1)<1e-9 and zones[1][3]==1.5 and zones[1].zone=='head' and
        math.abs(shift[1]+1.5)<1e-9,'the attack was not led onto where the enemy will be')
    -- Pressed late into an enemy 1.2 m away (moveA): led no closer than LEAD_MIN.
    led=Contact.lead(eye,{1.2,0,1},nil,.4,{4,0,0})
    assert(math.abs(led[1]-Contact.LEAD_MIN)<1e-9,'a late press was led through the enemy: '..led[1])
    assert(Contact.lead(eye,{.4,0,1},nil,.4,{4,0,0})[1]==.4,'an enemy already inside LEAD_MIN was moved closer')
    led=Contact.lead(eye,{1.2,0,1},nil,.4,{-2,0,0})
    assert(math.abs(led[1]-2)<1e-9,'backing away did not lead the target farther')
    -- The lead's velocity is the recent mean (moveC: sliding against an enemy
    -- flipped sideways frame to frame); a steady run keeps its speed.
    local motion=Contact.motion()
    for i=0,13 do motion.add(10+i/52,{0,i%2==0 and 4 or -4,0}) end
    local mean=motion.velocity()
    assert(math.abs(mean[2])<.5 and mean[1]==0,'a body sliding back and forth was led by its last frame')
    for i=14,40 do motion.add(10+i/52,{4,0,0}) end
    mean=motion.velocity()
    assert(math.abs(mean[1]-4)<1e-9 and mean[2]==0,'a steady run did not lead by its speed')
    motion.add(10+40/52,{0,0,0}); assert(motion.velocity()[1]==4,'a repeated frame was sampled twice')
    motion.add(5,{1,0,0}); assert(motion.velocity()[1]==1,'a restarted clock kept old samples')
    assert(Contact.motion().velocity()==nil,'an empty history gave a velocity')
    local still={2,0,1}
    assert(Contact.lead(eye,still,nil,.3,{0,0,0})==still and Contact.lead(eye,still,nil,nil,{4,0,0})==still and
        Contact.lead(eye,still,nil,.3,nil)==still,
        'a standing or undelayed attack was moved')
    context.within=nil
    for key,value in pairs(saved) do _G[key]=value end
end
-- A stroke in contact mode arms and presses only when the look-ahead finds an
-- enemy, aiming at it; one that finds none is a whiff and sends nothing.
do
    component.current_action_name='none'; component.start_t=10; queued=nil
    local calls,seen=0,nil
    local emitted,commits,pressed=drive({contact=function(args)
        calls=calls+1;if #args.poses>1 then seen=args end
        if calls>=3 then return {zone='head',step=2,position={1,2,1.7}} end
    end})
    assert(emitted.gesture_armed==1 and emitted.gesture_contact==1 and not emitted.gesture_whiff,'contact stroke did not arm then press')
    -- An enemy found while the swing builds up presses as it qualifies.
    assert(pressed==1 and emitted.press_frames[1]>=emitted.commit_frame,'attack pressed before its contact')
    assert(#seen.poses>=deps.Contact.STEPS+1 and seen.horizon>=deps.Contact.WAY,'look-ahead path missing or short of the way')
    assert(#commits==1 and commits[1].target and commits[1].target[3]==1.7,'attack not aimed at the contact')
    emitted,commits,pressed=drive({contact=function() return nil end})
    assert(emitted.gesture_armed==1 and emitted.gesture_whiff==1 and pressed==0 and #commits==0,'a whiff sent an attack')
    -- An enemy the swing reaches within its attack's press-to-damage time
    -- presses on the frame the swing is seen.
    emitted,commits,pressed=drive({contact=function() return {zone='torso',step=8,position={1,2,1.2}} end})
    assert(pressed==1 and emitted.press_frames[1]==emitted.commit_frame,'a swing with an enemy on its way waited to press')
    assert(#commits==1 and commits[1].target[3]==1.2)
    assert(emitted.gesture_contact_data.ahead<=emitted.gesture_contact_data.delay+Runtime.PRESS_SLACK,'contact timing not reported')
    -- One further along than that waits until it is as far off as the damage
    -- (user, 23 October: damage landed before the weapon reached the enemy).
    local far=0
    emitted,commits,pressed=drive({contact=function(args)
        if #args.poses<2 then return nil end
        far=far+1
        return {zone='torso',step=far<=4 and #args.poses or 2,position={1,2,1.2}}
    end})
    assert(emitted.gesture_wait==1 and emitted.gesture_wait_data.ahead>emitted.gesture_wait_data.delay,'a far contact did not wait')
    assert(pressed==1 and emitted.press_frames[1]>emitted.commit_frame,'a far contact pressed before the weapon came within its damage time')
    assert(emitted.gesture_contact_data.ahead<=emitted.gesture_contact_data.delay+Runtime.PRESS_SLACK,'pressed early')
    -- The attack's box can touch an enemy well before the blade as drawn does
    -- (pass 7, 23 October: a crowbar's box ran 0.4 s of swing ahead of it).
    -- The press is timed by the blade when it reaches that enemy...
    local foe,blade_calls={},0
    emitted,commits,pressed=drive({contact=function(args)
        if #args.poses<2 then return nil end
        if not args.visual then return {unit=foe,zone='torso',step=1,position={1,2,1.2}} end
        blade_calls=blade_calls+1
        return {unit=foe,zone='torso',step=blade_calls<=4 and #args.poses or 2,position={1,2,1.2}}
    end})
    assert(emitted.gesture_wait==1 and emitted.gesture_wait_data.blade==true,'a box contact ahead of the blade did not wait for it')
    assert(pressed==1 and emitted.press_frames[1]>emitted.commit_frame and emitted.gesture_contact_data.blade==true,
        'the press was not timed by the blade')
    -- ...and by the box when only the box reaches it.
    emitted,commits,pressed=drive({contact=function(args)
        if #args.poses<2 or args.visual then return nil end
        return {unit=foe,zone='torso',step=1,position={1,2,1.2}}
    end})
    assert(pressed==1 and emitted.press_frames[1]==emitted.commit_frame and not emitted.gesture_wait and
        emitted.gesture_contact_data.blade==false,'an enemy only the box reaches was not pressed at once')
    -- A swing that never comes that close sends nothing, and gives up after
    -- ARM_WAIT (shortened to fit this fixture's second of motion).
    local wait=Runtime.ARM_WAIT;Runtime.ARM_WAIT=.3
    emitted,commits,pressed=drive({contact=function(args)
        if #args.poses>1 then return {zone='torso',step=#args.poses,position={1,2,1.2}} end
    end})
    Runtime.ARM_WAIT=wait
    assert(pressed==0 and #commits==0 and emitted.gesture_wait==1 and emitted.gesture_whiff==1 and
        emitted.gesture_whiff_data.reason=='never_arrived','a contact the swing never neared was pressed: '..pressed)
end
-- A dual weapon's other blade is a second stock runtime on its own lease
-- (user, 22 October: both hands swing). Physical authority owns actions and
-- may never share the player this way.
do
    local unit,lease={},{}
    local function build(extra)
        local opts={source='synthetic',owner=assert(Pose.new(Inertia,{profile='knife',
            library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'})),strokes=Strokes.new(),
            extension=extension,weapon=weapon,slot='slot_primary',unit=unit,
            defaults={sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1},authority='stock',
            to_world=function(pose) return pose.position,pose.rotation end,cancel_native=function() end}
        for key,value in pairs(extra or {}) do opts[key]=value end
        return opts
    end
    local main=Runtime.new(deps,build())
    local off=Runtime.new(deps,build({lease=lease}))
    assert(Runtime.owner(unit)==main and Runtime.owner(lease)==off,'the two hands did not each lease their own key')
    local refused=build({lease={},authority='physical'})
    assert(not pcall(Runtime.new,deps,refused),'a physical runtime took a second lease')
    refused.owner.close()
    off.close(); main.close()
    assert(Runtime.owner(unit)==nil and Runtime.owner(lease)==nil,'a hand kept its lease after closing')
end
-- "Every swing" presses each stroke as it is seen, aimed at the first enemy
-- on its way when there is one, else turned along the swing.
do
    component.current_action_name='none'; component.start_t=10; queued=nil
    local emitted,commits,pressed=drive({trigger='swing',contact=function(args)
        if #args.poses>1 then return {zone='head',step=3,position={1,2,1.6}} end
    end})
    assert(pressed==1 and emitted.press_frames[1]==emitted.commit_frame and not emitted.gesture_armed,'swing mode armed instead of pressing')
    assert(emitted.gesture_contact==1 and #commits==1 and commits[1].target and commits[1].target[3]==1.6,
        'swing mode not aimed at the first enemy on its way')
    emitted,commits,pressed=drive({trigger='swing',contact=function() return nil end})
    assert(pressed==1 and #commits==1 and commits[1].target==nil and not emitted.gesture_contact and not emitted.gesture_whiff,
        'swing mode at nothing did not attack along the swing')
end
-- The stock trigger is the attack button (user, 22 October): it charges
-- while held, letting go releases it for the server to fire (heavy once
-- charged, light if tapped), and no block is ever pressed for it.
local function trigger_run(held_until,frames,guard)
    component.current_action_name='none'; component.start_t=10; queued=nil
    local owner=assert(Pose.new(Inertia,{profile='hammer',library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'}))
    local emitted={}
    local runtime=Runtime.new(deps,{source='synthetic',owner=owner,strokes=Strokes.new(),extension=extension,weapon=weapon,
        slot='slot_primary',unit={},defaults={sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1},authority='stock',
        to_world=function(pose) return pose.position,pose.rotation end,cancel_native=function() error('stock cancelled') end,
        emit=function(kind) emitted[kind]=(emitted[kind] or 0)+1 end})
    local still=Replay.sample(keys,0)
    local one,two,reference={},{},{}
    for frame=0,frames do
        assert(runtime.sample({source='synthetic',active=true,tracking_valid=true,reference=reference,frame=frame,time=20+frame/52,
            pose_time=frame/52,dominant=still.right,support=still.left,intent=true,guarding=guard and guard(frame) or false,
            heavy_intent=frame>=1 and frame<=held_until}))
        one[frame]=runtime.inputs(frame); two[frame]=runtime.block_inputs(frame)
    end
    runtime.close()
    if not guard then
        for frame=0,frames do assert(not two[frame].held and not two[frame].pressed,'the trigger pressed block') end
    end
    return emitted,one
end
do
    local emitted,one=trigger_run(3,14)
    assert(emitted.charge_start==1 and emitted.charge_release==1 and not emitted.charge_cancel and not emitted.stroke)
    assert(one[1].pressed and one[1].held and one[3].held and not one[3].released,'trigger did not charge')
    assert(one[4].released and not one[4].held and not one[5].held,'letting go did not release the charge')
    -- Held past the server's auto-complete: the button stays held, as a held
    -- stock attack button does; nothing cancels it.
    emitted,one=trigger_run(150,150)
    assert(emitted.charge_start==1 and not emitted.charge_cancel and not emitted.charge_release,'a long hold was cancelled')
    for frame=1,150 do assert(one[frame].held and not one[frame].released,'a held trigger let go at frame '..frame) end
    -- Block while charging keeps the charge held, so the server cancels it
    -- (stock attack_cancel); a release there would fire it (review, 22 Oct).
    emitted,one=trigger_run(20,26,function(frame) return frame>=8 and frame<=14 end)
    assert(emitted.charge_start==1 and emitted.charge_release==1,'block during a charge released or restarted it')
    for frame=1,20 do assert(one[frame].held and not one[frame].released,'block released the charge at frame '..frame) end
    assert(one[21].released and not one[21].held,'letting go after the block did not release')
end
-- One swing seen as two strokes into the same enemy, before the server has
-- started the first press, presses once (worn 22 October: one swing, two hits).
do
    local back=assert(Replay.parse(table.concat({
        '# t left_xyz left_xyzw right_xyz right_xyzw primary block left_grip right_grip',
        '0.00 -0.25 0.30 -0.35 0 0 0 1 -0.60 0.45 -0.30 -0.70710678 0 0 0.70710678 0 0 0 0',
        '0.20 -0.25 0.30 -0.35 0 0 0 1 -0.60 0.45 -0.30 -0.70710678 0 0 0.70710678 0 0 0 0',
        '0.40 -0.25 0.30 -0.35 0 0 0 1 0.40 0.45 -0.30 -0.70710678 0 0 0.70710678 0 0 0 0',
        '0.46 -0.25 0.30 -0.35 0 0 0 1 0.40 0.45 -0.30 -0.70710678 0 0 0.70710678 0 0 0 0',
        '0.64 -0.25 0.30 -0.35 0 0 0 1 -0.60 0.45 -0.30 -0.70710678 0 0 0.70710678 0 0 0 0',
        '1.20 -0.25 0.30 -0.35 0 0 0 1 -0.60 0.45 -0.30 -0.70710678 0 0 0.70710678 0 0 0 0'},'\n')))
    local saved=keys;keys=back
    local enemy={}
    component.current_action_name='none'; component.start_t=10; queued=nil
    local emitted,_,pressed=drive({contact=function() return {unit=enemy,zone='torso',step=1,position={0,1,1.5}} end})
    keys=saved
    assert(emitted.gesture_armed==2,'fixture did not produce two strokes: '..tostring(emitted.gesture_armed))
    assert(pressed==1 and emitted.gesture_contact==1 and emitted.gesture_duplicate==1,
        'one swing into one enemy pressed '..pressed..' attacks')
    assert(emitted.weapon_reach==1 and emitted.weapon_reach_data.after_press=='0.000',
        'the weapon reaching its pressed enemy was not reported')
    -- Once the server has started the first press, a back-swing into the same
    -- enemy is a new attack and presses (review, 22 October).
    keys=back
    component.current_action_name='none'; component.start_t=10; queued=nil
    emitted,_,pressed=drive({contact=function() return {unit=enemy,zone='torso',step=1,position={0,1,1.5}} end,
        before=function(t) if t>=10.42 then component.start_t=10.42 end end})
    keys=saved
    assert(emitted.gesture_armed==2 and pressed==2 and not emitted.gesture_duplicate,
        'a back-swing after the first attack started was swallowed: '..pressed..' presses')
    -- A press buffered behind a running attack is still guarded while that
    -- attack runs; once it ends without starting the press (PC run valH2,
    -- 23 October: an activated thunderhammer's hit ended its swing) the
    -- press was dropped, and the retry swing presses.
    local enemy_contact=function() return {unit=enemy,zone='torso',step=1,position={0,1,1.5}} end
    keys=back
    component.current_action_name='light'; component.start_t=9; queued=nil
    emitted,_,pressed=drive({contact=enemy_contact})
    keys=saved
    assert(pressed==1 and emitted.gesture_duplicate==1,'a press behind a running attack was not guarded: '..pressed..' presses')
    keys=back
    component.current_action_name='light'; component.start_t=9; queued=nil
    emitted,_,pressed=drive({contact=enemy_contact,before=function(t) if t>=10.3 then component.current_action_name='none' end end})
    keys=saved
    assert(pressed==2 and not emitted.gesture_duplicate,'a retry after a dropped press was refused: '..pressed..' presses')
    component.current_action_name='none'; component.start_t=10
end
-- Walking with arm-pump locomotion (VR StrideS; user, 23 October: a jog read
-- as slow swings). Slow strokes whose other hand swings the opposite way are
-- strides while walking; fast ones always attack (user: sometimes you swing
-- hard while walking); a real swing with the other hand still attacks.
do
    local function pump(amplitude,height,hertz)
        local lines={'# grip=touch','# t left_xyz left_xyzw right_xyz right_xyzw primary block left_grip right_grip'}
        for i=0,120 do
            local t=i*.025
            local p=math.sin(2*math.pi*hertz*t)
            lines[#lines+1]=string.format('%.3f -0.25 %.4f %.4f 0.70710678 0 0 0.70710678 0.25 %.4f %.4f 0 0 0 1 0 0 0 0',
                t,.3-amplitude*p,-.4-height*p,.3+amplitude*p,-.4+height*p)
        end
        return assert(Replay.parse(table.concat(lines,'\n')))
    end
    local foe={}
    local function enemy(args) if #args.poses>1 then return {unit=foe,zone='torso',step=1,position={1,2,1.2}} end end
    local saved=keys
    local function run(fixture,walk)
        keys=fixture
        component.current_action_name='none'; component.start_t=10; queued=nil
        local emitted,_,pressed=drive({contact=enemy,walk=walk,frames=150})
        keys=saved
        return emitted,pressed
    end
    local slow,hard=pump(.2,.08,1.4),pump(.3,.1,2.2)
    -- Off by default (worn-8: too sensitive): the pumps attack, and each stroke
    -- logs that the filter would have held it.
    assert(Runtime.STRIDE_FILTER==false,'the stride filter is on by default')
    local emitted,pressed=run(slow,1.6)
    assert(pressed>=1 and not emitted.stroke_filtered and emitted.stroke_data.stride_match==true,
        'the disabled stride filter held strokes or did not log the match: '..pressed)
    Runtime.STRIDE_FILTER=true
    emitted,pressed=run(slow,1.6)
    assert(pressed==0 and (emitted.stroke_filtered or 0)>=1,'arm pumps while walking pressed attacks: '..pressed)
    local filtered=emitted.stroke_filtered_data
    assert(tonumber(filtered.walk)>=1.5 and tonumber(filtered.cos)<=-.5 and tonumber(filtered.hand)<Runtime.STRIDE_FAST,
        'stride inputs not logged')
    emitted,pressed=run(slow,0)
    assert(pressed>=1 and not emitted.stroke_filtered,'the pump fixture made no attacks standing still: it proves nothing')
    assert(emitted.stroke_data.walk=='0.00' and emitted.stroke_data.cos~=nil,'stroke motion not logged')
    -- A hard stroke commits while its hand still speeds up: held as a stride,
    -- it attacks as soon as the hand passes STRIDE_FAST.
    emitted,pressed=run(hard,1.6)
    assert(pressed>=3 and (emitted.stroke_released or 0)>=1 and tonumber(emitted.stroke_released_data.hand)>=Runtime.STRIDE_FAST,
        'fast swings while walking were filtered as strides: '..pressed..' presses')
    -- The default fixture's real swing, with the support hand still, while walking.
    component.current_action_name='none'; component.start_t=10; queued=nil
    emitted,_,pressed=drive({contact=enemy,walk=1.6})
    assert(pressed==1 and not emitted.stroke_filtered,'a real swing while walking was filtered')
    Runtime.STRIDE_FILTER=false
end
print('PASS: contact look-ahead (prediction, probe, swing way, arm/press/whiff, press on sight, moving reach and lead), swing mode aimed at the first enemy, online trigger is the attack button (release on let-go, held past auto-complete), duplicate press guard, stride filter (off by default, logged), online swing aim in both roll conventions, thrust/short/through-head refusals, per-swing latch, stock press route and buffer gate')
