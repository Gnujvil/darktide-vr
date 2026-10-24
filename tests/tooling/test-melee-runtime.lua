local root=assert(arg[1])
local prefix=root..'/mods/darktidevr/scripts/mods/darktidevr/darktidevr_melee_'
local deps={}
for key,file in pairs({Timing='timing',Volume='volume',Planner='sweep_plan',Bridge='action_bridge',Defense='defense',Tether='tether'}) do deps[key]=dofile(prefix..file..'.lua') end
local Runtime,Pose,Inertia,Strokes=dofile(prefix..'runtime.lua'),dofile(prefix..'pose.lua'),dofile(prefix..'inertia.lua'),dofile(prefix..'strokes.lua')
local Replay=dofile(root..'/testlab/darktide_testlab/scripts/mods/darktide_testlab/trajectory.lua')
local file=assert(io.open(root..'/testlab/darktide_testlab/horizontal.tsv'))
local keys=assert(Replay.parse(file:read('*a'))); file:close()
local template={actions={
    windup={kind='windup',start_input='start_attack',allowed_chain_actions={
        light_attack={action_name='light'},heavy_attack={action_name='heavy',chain_time=.4}}},
    light={kind='sweep',sweeps={{}},damage_window_start=.316,allowed_chain_actions={start_attack={action_name='windup',chain_time=.6}}},
    heavy={kind='sweep'}},weapon_box={.15,.65,.15},action_inputs={heavy_attack={input_sequence={
        {input='action_one_hold',value=true,duration=.35},{input='action_one_hold',value=false}}}}}
local weapon={weapon_template=template,actions={}}
local component={current_action_name='none',start_t=10,time_scale=1}
local extension={_weapons={slot_primary=weapon},_weapon_action_component=component,
    _action_handler={_calculate_time_scale=function() return 1 end,_validate_action=function() return true end},
    condition_func_params=function() return {} end}
local owner=assert(Pose.new(Inertia,{profile='hammer',library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'}))
local strokes=Strokes.new()
local emitted,cancels,queries,exits,procs={stroke=0},0,0,0,0
local unit,reference,target={},{},{}
local runtime,action,commit_frame
runtime=Runtime.new(deps,{source='synthetic',owner=owner,strokes=strokes,extension=extension,weapon=weapon,
    slot='slot_primary',unit=unit,defaults={sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1},
    to_world=function(pose) return pose.position,pose.rotation end,
    cancel_native=function(t)
        cancels=cancels+1; component.current_action_name='none'
        if action then runtime.on_finish(action,t) end
    end,
    emit=function(kind,data) emitted[kind]=(emitted[kind] or 0)+1 end})
local Alias=dofile(prefix..'runtime.lua')
assert(Alias.owner(unit)==runtime and runtime.source=='synthetic','mod aliases did not share producer ownership')
local acquired=pcall(Alias.new,deps,{unit=unit})
assert(not acquired,'a second producer acquired the same player through a different module alias')
local function native_action(time,name)
    name=name or 'light'
    component.current_action_name=name; component.start_t=time
    return {_player_unit=unit,_weapon=weapon,_is_server=true,_unit_data_extension={is_resimulating=false},
        _weapon_action_component=component,_action_sweep_component={},_action_settings=template.actions[name],
        _uses_matrix_data=true,_num_hit_enemies=0,_is_sweep_aborted=function() return false end,
        _any_sweep_aborted=function() return false end,_exit_damage_window=function() exits=exits+1 end,
        _handle_exit_procs=function() procs=procs+1 end,
        _do_overlap=function(self,t,a,ar,b,br)
            queries=queries+1
            assert(type(a)=='table' and type(b)=='table' and ar[4] and br[4],'native query lost shared virtual pose')
        end}
end
local request
for frame=0,60 do
    local elapsed=frame/52
    local sample=Replay.sample(keys,elapsed)
    request={source='synthetic',active=true,tracking_valid=true,reference=reference,
        frame=frame,time=10+elapsed,pose_time=elapsed,dominant=sample.right,support=sample.left,
        support_held=sample.buttons[3],intent=true,guarding=false}
    local current,advanced=assert(runtime.sample(request))
    assert(advanced and current.source=='synthetic' and current.pose==owner.latest())
    if current.stroke.committed then
        assert(not commit_frame,'same path produced multiple physical strokes')
        commit_frame=frame
        assert(runtime.inputs(frame).pressed)
        local again,changed=runtime.sample(request)
        assert(again==current and changed==false and emitted.stroke==1,'duplicate consumer reintegrated/recommitted')
        local unrelated=native_action(request.time)
        unrelated._weapon_action_component={current_action_name='heavy',start_t=request.time,time_scale=1}
        assert(runtime.on_start(unrelated,template.actions.heavy,request.time))
        assert(not runtime.claim(unrelated,target),'unrelated native profile stole a committed light stroke')
        local before=queries
        runtime.update_sweep(unrelated,1/52,request.time,template.actions.heavy)
        assert(queries==before)
        runtime.on_finish(unrelated,request.time)
        action=native_action(request.time)
        assert(runtime.on_start(action,action._action_settings,request.time))
    end
    if action then
        local native_make=deps.Planner.make
        if frame==commit_frame+1 then
            deps.Planner.make=function() return {reset=true,reason='query_budget',required_segments=74,overlap=true} end
        end
        local before_queries=queries
        assert(runtime.update_sweep(action,1/52,request.time,action._action_settings))
        deps.Planner.make=native_make
        if frame==commit_frame+1 then
            assert(queries==before_queries+1 and runtime.current_action()==action,
                'over-budget frame closed the stroke instead of current-pose overlap')
        elseif frame==commit_frame+2 then
            assert(queries>before_queries,'stroke did not resume queries after over-budget frame')
        end
        local count=queries
        runtime.update_sweep(action,1/52,request.time,action._action_settings)
        assert(queries==count,'duplicate frame queried the native sweep again')
        if frame==commit_frame+1 then
            assert(runtime.inputs(frame).released and not runtime.inputs(frame).pressed)
            assert(runtime.claim(action,target) and not runtime.claim(action,target),'hurtbox dedup failed')
            local before={unpack(owner.latest().linear_velocity)}
            assert(runtime.impact(false))
            for i=1,3 do assert(math.abs(owner.latest().linear_velocity[i]-before[i]*.55)<1e-10) end
        end
        if frame==commit_frame+2 then break end
    end
end
assert(action and queries>0 and emitted.stroke==1)
local remaining=strokes.status().remaining
assert(remaining>0)
request.source='tracking'
local result,reason=runtime.sample(request)
assert(not result and reason=='source_changed' and not runtime.latest() and not owner.latest())
assert(cancels==1 and exits==1 and procs==1,'source loss did not close native action exactly once')
assert(strokes.status().remaining==remaining,'source transition erased recovery debt')
assert(not runtime.inputs(request.frame).held and not runtime.inputs(nil).pressed)
runtime.close(); runtime.close()
assert(not Alias.owner(unit),'closed runtime retained the player pose lease')
assert(cancels==1,'closing an already inactive owner cancelled a later unrelated action')
assert(not runtime.sample(request))
-- The same real-DLL runtime drives defensive replay input. This fixture models
-- parser transitions only; it cannot certify native stamina or enemy stagger.
template.actions.block={kind='block',allowed_chain_actions={push={action_name='push'}}}
template.actions.push={kind='push'}
template.action_inputs.block={input_sequence={{input='action_two_hold',value=true}}}
template.action_inputs.push={input_sequence={{input='action_one_pressed',hold_input='action_two_hold',value=true}}}
component.current_action_name='none'
local defensive_owner=assert(Pose.new(Inertia,{profile='hammer',library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'}))
local defensive=Runtime.new(deps,{source='synthetic',owner=defensive_owner,strokes=strokes,extension=extension,weapon=weapon,
    slot='slot_primary',unit=unit,defaults={sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1},
    to_world=function(pose) return pose.position,pose.rotation end,
    cancel_native=function() component.current_action_name='none' end})
local scenario=assert(io.open(root..'/testlab/darktide_testlab/guard_push.tsv'))
local defensive_keys=assert(Replay.parse(scenario:read('*a'))); scenario:close()
local push_count,block_frames,release_count=0,0,0
for frame=0,104 do
    local time=frame/52
    local sample=Replay.sample(defensive_keys,time)
    local current=assert(defensive.sample({source='synthetic',active=true,tracking_valid=true,reference=reference,
        frame=frame,time=20+time,pose_time=time,dominant=sample.right,support=sample.left,
        support_held=false,intent=true,guarding=sample.buttons[2]}))
    local primary,block=defensive.inputs(frame),defensive.block_inputs(frame)
    assert(not current.stroke.committed,'guard/shove incorrectly committed a melee sweep')
    if block.held then
        block_frames=block_frames+1
        if component.current_action_name=='none' then component.current_action_name='block'; component.start_t=20+time end
    end
    if block.released then release_count=release_count+1 end
    if primary.pressed then
        assert(block.held and component.current_action_name=='block','push lacked qualified native block context')
        push_count=push_count+1; component.current_action_name='push'; component.start_t=20+time
    end
end
assert(push_count==1 and block_frames>20 and release_count==1,'real weighted defensive replay failed')
defensive.invalidate('recenter')
assert(not defensive.block_inputs(104).held and not defensive.inputs(104).held)
defensive.close()
-- Independent shield guard uses the same support grip as rendering. Raising
-- the maul cannot substitute for the shield, and a shield cannot brace it.
local function guard_case(shield,raise_weapon,raise_shield,missing_shield,shove_hand,pose_block)
    template.name=shield and 'powermaul_shield_p1_m2' or 'powermaul_p1_m1'
    local guard_owner=assert(Pose.new(Inertia,{profile='hammer',library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'}))
    local guard_runtime=Runtime.new(deps,{source='synthetic',owner=guard_owner,strokes=Strokes.new(),extension=extension,
        weapon=weapon,slot='slot_primary',unit=unit,defaults={sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1},
        to_world=function(pose) return pose.position,pose.rotation end,cancel_native=function() end})
    component.current_action_name='block';component.start_t=0
    local held,pushes=0,0
    local settle=pose_block and 20 or 10
    for frame=0,settle+14 do
        local travel=frame>settle and math.min(frame-settle,6)*.04 or 0
        local right={position={.2,.3+(shove_hand=='weapon' and travel or 0),raise_weapon and -.3 or -1.1},rotation={0,0,0,1}}
        local left=not missing_shield and {position={-.2,.3+(shove_hand=='shield' and travel or 0),raise_shield and -.3 or -1.1},rotation={0,0,0,1}} or nil
        local current=assert(guard_runtime.sample({source='synthetic',active=true,tracking_valid=true,reference=reference,
            frame=frame,time=25+frame*.02,dominant=right,support=left,support_held=shield,intent=true,
            guarding=not pose_block,pose_block=pose_block}))
        if shield then
            assert(not current.pose.support_engaged,'shield was constrained as a two-hand weapon brace')
            assert((current.world_support~=nil)==(left~=nil),'shield rendering lost selected guard hand')
        end
        if guard_runtime.block_inputs(frame).held then held=held+1 end
        if guard_runtime.inputs(frame).pressed then pushes=pushes+1 end
    end
    guard_runtime.close()
    return held,pushes
end
assert(guard_case(true,true,false)==0,'raised weapon incorrectly blocked for lowered shield')
assert(guard_case(true,false,true)>0,'shield hand failed to block with weapon lowered')
assert(guard_case(true,true,true,true)==0,'missing shield pose fell back to raised weapon')
assert(guard_case(false,false,true)==0,'free hand incorrectly blocked without shield')
assert(guard_case(false,true,false)>0,'ordinary weapon hand failed to block')
local shield_blocks,shield_pushes=guard_case(true,false,true,false,'shield')
assert(shield_blocks>0 and shield_pushes==1,'shield shove did not create exactly one native push edge')
local _,wrong_pushes=guard_case(true,true,true,false,'weapon')
assert(wrong_pushes==0,'weapon shove pushed while shield remained still')
assert(guard_case(true,true,false,nil,nil,true)==0,'pose-only mode used weapon instead of shield')
assert(guard_case(true,false,true,nil,nil,true)>0,'pose-only shield failed without block button')
assert(guard_case(false,true,false,nil,nil,true)>0,'pose-only ordinary weapon failed without block button')
assert(guard_case(true,true,true,true,nil,true)==0,'pose-only lost shield fell back to weapon')
local auto_blocks,auto_pushes=guard_case(true,false,true,false,'shield',true)
assert(auto_blocks>0 and auto_pushes==1,'pose-only real ABI4 shield shove failed')
template.name=nil
-- Hold-to-charge heavy selection still uses a deliberate physical stroke, the
-- native parser and the heavy action's recovery route.
template.actions.heavy={kind='sweep',sweeps={{}},allowed_chain_actions={start_attack={action_name='windup',chain_time=.9}}}
template.action_inputs.heavy_attack.input_sequence[2].auto_complete=true
template.action_inputs.heavy_attack.input_sequence[2].time_window=1
local heavy_file=assert(io.open(root..'/testlab/darktide_testlab/heavy.tsv'))
local heavy_keys=assert(Replay.parse(heavy_file:read('*a'))); heavy_file:close()
local sticky_frame,sticky_release
local function heavy_runtime()
    local native_owner=assert(Pose.new(Inertia,{profile='hammer',library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'}))
    component.current_action_name='none'; action=nil
    return Runtime.new(deps,{source='synthetic',owner=native_owner,strokes=Strokes.new(),extension=extension,weapon=weapon,
        slot='slot_primary',unit=unit,native_events=true,sticky_frame=sticky_frame,defaults={sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1},
        to_world=function(pose) return pose.position,pose.rotation end,
        to_world_direction=function(value) return value end,
        emit=function(kind,data) if kind=='sticky_release' then sticky_release=data end end,
        cancel_native=function(t)
            component.current_action_name='none'
            if action then runtime.on_finish(action,t) end
        end})
end
runtime=heavy_runtime()
local heavy_commits,charge_frames,heavy_query_frames=0,0,0
for frame=0,78 do
    local time=frame/52
    local sample=Replay.sample(heavy_keys,time)
    local current=assert(runtime.sample({source='synthetic',active=true,tracking_valid=true,reference=reference,
        frame=frame,time=30+time,pose_time=time,dominant=sample.right,support=sample.left,
        support_held=false,intent=true,guarding=false,heavy_intent=sample.buttons[1]}))
    local edge=runtime.inputs(frame)
    if current.stroke.committed then
        heavy_commits=heavy_commits+1
        assert(edge.released and not edge.held and not edge.pressed,'heavy stroke did not release native charge')
        assert(math.abs(current.timing.heavy_interval-.9)<1e-10 and current.stroke.remaining>=.89,'heavy borrowed light recovery')
        assert(time>=.55,'heavy committed before native minimum charge')
        action=native_action(30+time,'heavy')
        assert(runtime.on_start(action,action._action_settings,30+time))
    elseif edge.held and not action then
        charge_frames=charge_frames+1
        if component.current_action_name=='none' then component.current_action_name='windup'; component.start_t=30+time end
    end
    if action then
        local before=queries
        runtime.update_sweep(action,1/52,30+time,action._action_settings)
        if queries>before then heavy_query_frames=heavy_query_frames+1 end
    end
end
assert(heavy_commits==1 and charge_frames>10 and heavy_query_frames>2,'charged stroke lost its physical follow-through')
runtime.close()
-- Stationary charge expires before parser auto-completion; held primary cannot
-- repeatedly re-arm it. No physical commitment or native damage query exists.
for _,charge_case in ipairs({'idle','early_release','early_motion'}) do
runtime=heavy_runtime()
local before=queries
for frame=0,130 do
    local time=frame/52
    local sample=Replay.sample(heavy_keys,0)
    -- A swing that ends before the minimum charge never becomes the heavy.
    -- (One still moving when the charge completes counts from that sample.)
    if charge_case=='early_motion' then sample.right.position[1]=-.6+math.min(1.2,math.max(0,time-.1)*4) end
    local current=assert(runtime.sample({source='synthetic',active=true,tracking_valid=true,reference=reference,
        frame=frame,time=40+time,pose_time=time,dominant=sample.right,support=sample.left,
        support_held=false,intent=true,guarding=false,heavy_intent=frame>=5 and (charge_case~='early_release' or frame<12)}))
    local edge=runtime.inputs(frame)
    assert(not current.stroke.committed)
    if edge.held and component.current_action_name=='none' then component.current_action_name='windup'; component.start_t=40+time end
end
assert(queries==before and not runtime.inputs(130).held and component.current_action_name=='none','idle charge auto-attacked or rearmed')
runtime.close()
end

local support_file=assert(io.open(root..'/testlab/darktide_testlab/support_only.tsv'))
local support_keys=assert(Replay.parse(support_file:read('*a')));support_file:close()
for _,support_case in ipairs({'stroke','free','jiggle','toggle','jump'}) do
    runtime=heavy_runtime()
    local count,before,support_frames=0,queries,0
    for frame=0,115 do
        local time=frame/52
        local sample=Replay.sample(support_keys,time)
        assert(sample.right.position[1]==0,'support-only fixture moved dominant hand')
        local held=sample.buttons[3]
        if support_case=='free' then held=false end
        if support_case=='jiggle' then sample.left.position[1]=time>.4 and .01*math.sin(100*math.pi*time) or 0 end
        if support_case=='toggle' and time>.4 then held=frame%2==0 end
        if support_case=='jump' then sample.left.position[1]=time>.4 and 2 or 0 end
        local current=assert(runtime.sample({source='synthetic',active=true,tracking_valid=true,reference=reference,
            frame=frame,time=50+time,pose_time=time,dominant=sample.right,support=sample.left,
            support_held=held,intent=true,guarding=false}))
        if current.pose.support_engaged then support_frames=support_frames+1 end
        if current.stroke.committed then
            count=count+1
            assert(support_case=='stroke','support discontinuity/waggle manufactured stroke: '..support_case)
            assert(current.stroke.intent_hand=='support','fixed dominant hand falsely qualified raw intent')
            action=native_action(50+time)
            assert(runtime.on_start(action,action._action_settings,50+time))
        end
        if action then runtime.update_sweep(action,1/52,50+time,action._action_settings) end
    end
    if support_case=='stroke' then assert(count==1 and queries>before and support_frames>0,'support-only motion failed actual shared Runtime')
    else assert(count==0 and queries==before,'support negative produced a native query') end
    runtime.close()
end
-- A delayed contact already admitted by a moving stroke survives its natural
-- end, but explicit invalidation must discard it. No terminal overlap is run.
template.actions.light.num_frames_before_process=4
for _,ending in ipairs({'natural','cancel'}) do
    runtime=heavy_runtime()
    local buffered_target={}
    local processed,processed_after_motion=0,false
    local started,closed_before,procs_before=false,exits,procs
    for frame=0,110 do
        local time=frame/52
        local sample=Replay.sample(keys,time)
        local current=assert(runtime.sample({source='synthetic',active=true,tracking_valid=true,reference=reference,
            frame=frame,time=60+time,pose_time=time,dominant=sample.right,support=sample.left,
            support_held=false,intent=true,guarding=false}))
        if current.stroke.committed then
            action=native_action(60+time)
            action._merge_saved_entries=function(self,none,count,saved,total)
                assert(#none==0 and count==0 and total==1);return saved,total
            end
            action._process_sweep_results=function(self,t,results,count,settings,direction)
                processed_after_motion=not runtime.latest().stroke.collision_allowed
                assert(direction==runtime.world_direction(self),'buffered hit lost actual world swing direction')
                assert(runtime.claim(self,results[1]) and not runtime.claim(self,results[1]),'final drain lost dedup/admission scope')
                processed=processed+1
            end
            action._do_overlap=function(self)
                queries=queries+1;self._num_saved_entries=1;self._saved_entries={buffered_target}
            end
            assert(runtime.on_start(action,action._action_settings,60+time));started=true
        end
        if action then
            local before=queries
            runtime.update_sweep(action,1/52,60+time,action._action_settings)
            if started and action._num_saved_entries==1 and ending=='cancel' then
                runtime.invalidate('reference_change');assert(action._num_saved_entries==0);break
            end
            if processed>0 then assert(queries==before,'draining final contact ran a stationary overlap');break end
        end
    end
    assert(started and processed==(ending=='natural' and 1 or 0))
    if ending=='natural' then assert(processed_after_motion,'fixture did not exercise claim after motion ended') end
    runtime.close()
    assert(exits==closed_before+1 and procs==procs_before+1,'buffered lifecycle ended more than once')
end
-- Native sticky events own their timed phase. The real inertia owner keeps
-- sampling, but a held contact never opens another physical overlap.
template.actions.light.num_frames_before_process=0
template.actions.light.hit_stickyness_settings={duration=.2}
for _,sticky_case in ipairs({'natural','tick_error','tether','hold','withdrawal','target_lost','constraint_error'}) do
    sticky_release=nil
    local anchor,contact={},{position={0,0,0},rotation={0,0,0,1},target={},node=1}
    if sticky_case=='tether' or sticky_case=='hold' or sticky_case=='withdrawal' or sticky_case=='target_lost' or sticky_case=='constraint_error' then
        sticky_frame=function()
            if anchor.error then error('injected native actor query failure') end
            if anchor.lost then return nil end
            return contact
        end
    else sticky_frame=nil end
    runtime=heavy_runtime()
    local before=queries
    local ticks,window,proc,stops,stroke_count=0,0,0,0,0
    for frame=0,90 do
        local time=frame/52
        local sample=Replay.sample(keys,time)
        local function request(at)
            local value=Replay.sample(keys,at/52)
            return {source='synthetic',active=true,tracking_valid=true,reference=reference,
                frame=at,time=70+at/52,pose_time=at/52,dominant=value.right,support=value.left,
                support_held=false,intent=true,guarding=false}
        end
        local current,_,released=runtime.sample(request(frame))
        if not current then
            assert(sticky_case=='tick_error' or sticky_case=='withdrawal' or sticky_case=='target_lost' or sticky_case=='constraint_error')
            -- Pulling away from a live contact releases it: the stroke ends,
            -- the source does not. A failed contact query still fails it.
            local recoverable=sticky_case=='withdrawal' or sticky_case=='target_lost'
            assert((released==true)==recoverable,'sticky release misreported source failure')
            if recoverable then assert(runtime.sample(request(frame+1)),'released sticky contact did not resume sampling') end
            break
        end
        if current.stroke.committed then
            stroke_count=stroke_count+1;action=native_action(70+time)
            action._movement_state_component={can_jump=true}
            action._is_currently_sticky=function(self) return self._action_sweep_component.is_sticky==true end
            action._exit_damage_window=function(self,...)
                runtime.native_event(self,'_exit_damage_window',function() window=window+1 end,...)
            end
            action._handle_exit_procs=function(self)
                runtime.native_event(self,'_handle_exit_procs',function() proc=proc+1 end)
            end
            action._is_sweep_aborted=action._is_currently_sticky;action._any_sweep_aborted=action._is_currently_sticky
            action._stop_hit_stickyness=function(self)
                stops=stops+1;self:_handle_exit_procs()
                self._action_sweep_component.is_sticky=false;self._movement_state_component.can_jump=true
            end
            action._update_hit_stickyness=function(self)
                ticks=ticks+1
                if sticky_case=='tick_error' and ticks==2 then error('injected native sticky step failure') end
                if ticks==3 then self:_stop_hit_stickyness() end
            end
            action._do_overlap=function(self)
                queries=queries+1
                assert(runtime.claim(self,{}),'first sticky contact was not admitted')
                self._action_sweep_component.is_sticky=true;self._movement_state_component.can_jump=false
                self:_exit_damage_window()
            end
            assert(runtime.on_start(action,action._action_settings,70+time))
        end
        if action then
            runtime.update_sweep(action,1/52,70+time,action._action_settings)
            if sticky_frame and runtime.latest() and action:_is_currently_sticky() then
                local constrained=runtime.latest().pose
                assert(constrained.constrained and owner~=nil,'sticky contact did not constrain actual shared pose')
                if not anchor.position then anchor.position={unpack(constrained.position)} end
                if sticky_case=='tether' then
                    assert(math.abs(constrained.position[1]-anchor.position[1])<1e-8,'contact anchor drifted with raw hand')
                    assert(constrained.raw_dominant.position[1]==sample.right.position[1],'constraint overwrote raw intent')
                elseif sticky_case=='withdrawal' then contact.position[1]=1
                elseif sticky_case=='hold' then
                    -- A follow-through short of STICKY_HOLD keeps the weapon in the target.
                    if anchor.held then
                        assert(math.abs(constrained.position[1]-anchor.held)<1e-8,'held weapon left its target')
                    elseif constrained.held then anchor.held=constrained.position[1] end
                    contact.position[1]=.45
                elseif sticky_case=='constraint_error' then anchor.error=true
                else anchor.lost=true end
            end
            local observed=ticks
            runtime.update_sweep(action,1/52,70+time,action._action_settings)
            assert(ticks==observed,'duplicate native simulation frame ticked sticky effect')
        end
    end
    assert(stroke_count==1 and queries==before+1 and window==1 and proc==1 and stops==1,'shared sticky runtime duplicated native lifecycle')
    assert(not action._action_sweep_component.is_sticky and action._movement_state_component.can_jump)
    if sticky_case=='tick_error' then
        assert(ticks==2 and not runtime.latest(),'native step error did not invalidate source')
        local sample,reason=runtime.sample({})
        assert(not sample and reason=='native_query_failed','failed source silently retried combat')
    elseif sticky_case=='withdrawal' or sticky_case=='target_lost' or sticky_case=='constraint_error' then
        assert(ticks==1)
        assert(sticky_release and sticky_release.reason,'sticky release lost reason')
        if sticky_case=='withdrawal' then
            assert(sticky_release.raw_distance>.5 and sticky_release.virtual_distance>.5 and
                sticky_release.raw_angle>=0 and sticky_release.virtual_angle>=0,'rejected constraint lost numeric measurements')
        else assert(sticky_release.raw_distance==nil,'unavailable target fabricated constraint measurements') end
        if sticky_case=='constraint_error' then
            local result,reason=runtime.sample({})
            assert(not result and reason=='native_query_failed','constraint failure source was silently retried')
        end
    else assert(ticks==3) end
    if sticky_case=='hold' then assert(sticky_release==nil and anchor.held,'a short follow-through broke the lock-in') end
    runtime.on_finish(action,72)
    action:_exit_damage_window();action:_handle_exit_procs()
    assert(window==1 and proc==1,'original native finish repeated sticky events')
    runtime.after_finish(action);runtime.close()
end
sticky_frame=nil
template.actions.light.hit_stickyness_settings=nil
template.actions.light.weapon_chain_lightning_template='native_lightning'
for _,ending in ipairs({'natural','cancel'}) do
    runtime=heavy_runtime()
    local chains,removals,commits=0,0,0
    local chain_target={}
    for frame=0,90 do
        local time=frame/52
        local sample=Replay.sample(keys,time)
        local current=assert(runtime.sample({source='synthetic',active=true,tracking_valid=true,reference=reference,
            frame=frame,time=80+time,pose_time=time,dominant=sample.right,support=sample.left,
            support_held=false,intent=true,guarding=false}))
        if current.stroke.committed then
            commits=commits+1;action=native_action(80+time)
            action._do_chain_lightning_on_sweep=true
            action._chain_lightning_action_data={is_server=true,chain_root_node={},chain_lightning_hit_units={},
                chain_lightning_temp_targets={},targeting_module_component={},on_chain_node_remove_func=function() end}
            action._try_make_chain_from_sweep_hit=function(self)
                if not self._has_started_chain_lightning then self._has_started_chain_lightning=true;chains=chains+1 end
            end
            action.finish=function(self) removals=removals+1;self._has_started_chain_lightning=false end
            action._do_overlap=function(self)
                queries=queries+1
                if runtime.claim(self,chain_target) then self:_try_make_chain_from_sweep_hit() end
            end
            assert(runtime.on_start(action,action._action_settings,80+time))
        end
        if action then
            runtime.update_sweep(action,1/52,80+time,action._action_settings)
            if ending=='cancel' and chains>0 then runtime.invalidate('reference_change');break end
        end
    end
    assert(commits==1 and chains==1 and removals==0,'shared Runtime repeated or prematurely cleared native lightning')
    runtime.on_finish(action,82);action:finish();runtime.after_finish(action)
    assert(removals==1 and not action._has_started_chain_lightning)
    runtime.close()
end
-- Real solver + changing world anchor. Motion intent remains body-local, while
-- the native sweep must retain yesterday's world endpoint, including rotation.
template.actions.light.weapon_chain_lightning_template=nil
for _,mode in ipairs({'moving','teleport','recenter','idle'}) do
    local anchor,previous,expected,first,last,commit,stopped=0,nil,nil,nil,nil,nil,0
    local reference={}
    component.current_action_name='none';action=nil
    local native_owner=assert(Pose.new(Inertia,{profile='hammer',library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'}))
    runtime=Runtime.new(deps,{source='synthetic',owner=native_owner,strokes=Strokes.new(),extension=extension,weapon=weapon,
        slot='slot_primary',unit=unit,defaults={sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1},
        to_world=function(pose)
            local c,s=math.cos(anchor),math.sin(anchor)
            local p,q=pose.position,pose.rotation
            local z,w=math.sin(anchor/2),math.cos(anchor/2)
            return {anchor+c*p[1]-s*p[2],s*p[1]+c*p[2],p[3]},
                {w*q[1]-z*q[2],w*q[2]+z*q[1],w*q[3]+z*q[4],w*q[4]-z*q[3]}
        end,
        cancel_native=function(t) stopped=stopped+1;if action then runtime.on_finish(action,t) end end})
    local count=0
    local captured,onset={},nil
    for frame=0,90 do
        anchor=frame*.003
        if commit and mode=='teleport' and frame==commit+2 then anchor=anchor+2 end
        if commit and mode=='recenter' and frame==commit+2 then reference={} end
        local time=frame/52
        local sample=Replay.sample(keys,mode=='idle' and 0 or time)
        local current=assert(runtime.sample({source='synthetic',active=true,tracking_valid=true,reference=reference,
            frame=frame,time=100+time,pose_time=time,dominant=sample.right,support=sample.left,
            support_held=false,intent=true,guarding=false}))
        captured[#captured+1]={time=100+time,world=current.world}
        if current.stroke.committed then
            assert(not commit,'world anchor created an extra stroke');commit=frame
            onset=assert(current.stroke.onset,'committed stroke has no onset')
            action=native_action(100+time)
            action._do_overlap=function(_,_,a,ar,b,br)
                count=count+1;first=first or {position=a,rotation=ar};last={position=b,rotation=br}
            end
            assert(runtime.on_start(action,action._action_settings,100+time))
        end
        expected=previous;first=nil;last=nil
        -- Binding also sweeps the stroke's own motion: its first query starts
        -- at the onset sample's captured world snapshot, likewise unremapped.
        if frame==commit then
            for _,entry in ipairs(captured) do
                if math.abs(entry.time-onset)<1e-9 then expected=entry.world end
            end
            assert(expected~=previous,'stroke onset precedes no earlier captured sample')
        end
        -- Mapping may change after sampling (render/update order). It must not
        -- remap either endpoint or mutate the captured query history.
        anchor=anchor+10
        if action then runtime.update_sweep(action,1/52,100+time,action._action_settings) end
        if first then
            local distance=assert(deps.Planner.trajectory(expected or current.world,first))
            assert(distance.translation<1e-8 and distance.angle<1e-7,'previous endpoint reprojected through current anchor')
            distance=assert(deps.Planner.trajectory(current.world,last))
            assert(distance.translation<1e-8 and distance.angle<1e-7,'query endpoint changed after sampling')
        end
        if commit and frame==commit+2 and (mode=='teleport' or mode=='recenter') then
            assert(not first and stopped>0,'anchor discontinuity/recenter authored a connecting sweep')
            if mode=='teleport' then assert(not runtime.latest(),'teleport kept authoring active') end
            break
        end
        previous=current.world
    end
    assert(mode=='idle' and not commit and count==0 or mode~='idle' and commit and count>0,'body intent/world query coverage missing')
    runtime.close()
end
-- A quick stroke can stop in the frame before its native action starts. It
-- still binds once, sweeps the path it travelled, and claims nothing after.
do
    local latest
    local passthrough={update=function(request)
            latest={position={unpack(request.dominant.position)},rotation={unpack(request.dominant.rotation)},
                raw_dominant=request.dominant,frame=request.frame,reset=latest==nil}
            return latest
        end,reset=function() latest=nil end,latest=function() return latest end,close=function() end,
        contact=function() return true end,pin=function() return nil,'unsupported' end}
    component.current_action_name='none';action=nil
    local quick,quick_runtime
    quick_runtime=Runtime.new(deps,{source='synthetic',owner=passthrough,strokes=Strokes.new(),extension=extension,weapon=weapon,
        slot='slot_primary',unit=unit,defaults={sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1},
        to_world=function(pose) return pose.position,pose.rotation end,
        cancel_native=function(t) component.current_action_name='none';if quick then quick_runtime.on_finish(quick,t) end end})
    local quick_reference,quick_target,x,frame={},{},0,1000
    local function sample(dx)
        frame=frame+1;x=x+dx
        return assert(quick_runtime.sample({source='synthetic',active=true,tracking_valid=true,reference=quick_reference,
            frame=frame,time=50+frame/52,pose_time=frame/52,
            dominant={position={x,.45,-.3},rotation={-0.70710678,0,0,0.70710678}},
            support={position={-.25,.3,-.35},rotation={0,0,0,1}},support_held=false,intent=true,guarding=false}))
    end
    for _=1,10 do sample(0) end
    local current
    repeat current=sample(.06) until current.stroke.committed or frame>1040
    assert(current.stroke.committed,'fast flick did not commit')
    current=sample(0)
    assert(not current.stroke.collision_allowed and current.stroke.ended,'flick did not stop before native binding')
    quick=native_action(50+frame/52)
    local seen,claimed=0,false
    quick._do_overlap=function() seen=seen+1;claimed=claimed or quick_runtime.claim(quick,quick_target) end
    assert(quick_runtime.on_start(quick,quick._action_settings,50+frame/52))
    quick_runtime.update_sweep(quick,1/52,50+frame/52,quick._action_settings)
    assert(seen>1 and claimed,'stopped stroke was not swept along its recorded path')
    assert(not quick_runtime.claim(quick,{}),'stationary weapon kept claim permission after the final pass')
    local before=seen
    sample(0)
    quick_runtime.update_sweep(quick,1/52,50+frame/52,quick._action_settings)
    assert(seen==before,'stationary weapon queried after the final pass')
    quick_runtime.close()
end
-- No attack cooldown: a new swing at stroke speed interrupts this runtime's
-- own attack while it is still inside its native chain time, once.
do
    local latest
    local passthrough={update=function(request)
            latest={position={unpack(request.dominant.position)},rotation={unpack(request.dominant.rotation)},
                raw_dominant=request.dominant,frame=request.frame,reset=latest==nil}
            return latest
        end,reset=function() latest=nil end,latest=function() return latest end,close=function() end,
        contact=function() return true end,pin=function() return nil,'unsupported' end}
    component.current_action_name='none';action=nil
    local running,swing_runtime
    local interrupts,stops=0,0
    swing_runtime=Runtime.new(deps,{source='synthetic',owner=passthrough,strokes=Strokes.new(),extension=extension,weapon=weapon,
        slot='slot_primary',unit=unit,defaults={sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1},
        to_world=function(pose) return pose.position,pose.rotation end,
        emit=function(kind) if kind=='interrupt' then interrupts=interrupts+1 end end,
        cancel_native=function(t)
            stops=stops+1;component.current_action_name='none'
            if running then swing_runtime.on_finish(running,t);running=nil end
        end})
    local swing_reference,x,frame={},0,2000
    local function sample(dx)
        frame=frame+1;x=x+dx
        return assert(swing_runtime.sample({source='synthetic',active=true,tracking_valid=true,reference=swing_reference,
            frame=frame,time=60+frame/52,pose_time=frame/52,
            dominant={position={x,.45,-.3},rotation={-0.70710678,0,0,0.70710678}},
            support={position={-.25,.3,-.35},rotation={0,0,0,1}},support_held=false,intent=true,guarding=false}))
    end
    for _=1,10 do sample(0) end
    local current
    repeat current=sample(.06) until current.stroke.committed or frame>2040
    assert(current.stroke.committed,'first swing did not commit')
    running=native_action(60+frame/52)
    assert(swing_runtime.on_start(running,running._action_settings,60+frame/52))
    for _=1,3 do sample(0) end
    repeat current=sample(-.06) until current.stroke.committed or frame>2080
    assert(current.stroke.committed and interrupts==1,'a swing waited for the running attack instead of interrupting it')
    -- The game ends the old attack itself: it chains straight into the next
    -- windup, with no stop and no change to the shared template.
    local authored=template.actions.light.allowed_chain_actions.start_attack
    local now=swing_runtime.select_chain(extension._action_handler,authored,60+frame/52,.1,1,template.actions)
    assert(stops==0 and component.current_action_name=='light','interrupt stopped the attack instead of chaining')
    assert(now~=authored and now.chain_time==nil and now.action_name=='windup' and authored.chain_time==.6,
        'interrupting chain still waited for its authored chain time')
    swing_runtime.close()
end
-- A sweep no stroke started (a weapon special: the trigger cannot start one
-- in physical mode) runs as the stock attack instead of being swallowed.
do
    local special_owner=assert(Pose.new(Inertia,{profile='hammer',library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'}))
    local special_unit,contexts={},{}
    local special_runtime=Runtime.new(deps,{source='synthetic',owner=special_owner,strokes=Strokes.new(),extension=extension,
        weapon=weapon,slot='slot_primary',unit=special_unit,defaults={sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1},
        to_world=function(pose) return pose.position,pose.rotation end,cancel_native=function() end,
        emit=function(kind,data) if kind=='context' then contexts[#contexts+1]=data end end})
    component.current_action_name='none'
    local still=Replay.sample(keys,0)
    assert(special_runtime.sample({source='synthetic',active=true,tracking_valid=true,reference={},frame=900,time=50,
        pose_time=0,dominant=still.right,support=still.left,intent=true,guarding=false}))
    component.current_action_name='light'
    local special={_player_unit=special_unit,_weapon=weapon,_unit_data_extension={is_resimulating=false},
        _weapon_action_component=component,_action_sweep_component={}}
    assert(special_runtime.on_start(special,template.actions.light,50)==false,'a weapon special sweep was swallowed')
    assert(special._action_sweep_component.sweep_state==nil and contexts[1].reason=='stock_sweep')
    assert(special_runtime.update_sweep(special,1/52,50,template.actions.light)==false,'the special sweep was replaced')
    component.current_action_name='none'
    special_runtime.close()
end
print('melee_runtime=pass real_native_pose shared_source canonical_timing deliberate_stroke native_context world_mapping queries_once target_dedup impact input_edges source_separation cancel_once persistent_debt guard_shove heavy_charge_followthrough_recovery idle_charge_cancel support_only raw_intent_provenance grip_changes_no_queries native_lightning_lifetime world_anchor_history teleport_recenter_no_sweep locomotion_no_stroke')
