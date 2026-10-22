-- Real inertia DLL plus a bounded native-parser fixture. Native stamina,
-- hit acceptance and proc behavior still require an actual local range run.
local root=assert(arg[1])
local prefix=root..'/mods/darktidevr/scripts/mods/darktidevr/darktidevr_melee_'
local deps={}
for key,file in pairs({Timing='timing',Volume='volume',Planner='sweep_plan',Bridge='action_bridge',Defense='defense'}) do
    deps[key]=dofile(prefix..file..'.lua')
end
local Runtime,Pose,Inertia,Strokes=dofile(prefix..'runtime.lua'),dofile(prefix..'pose.lua'),dofile(prefix..'inertia.lua'),dofile(prefix..'strokes.lua')
local Replay=dofile(root..'/mods/darktide_testlab/scripts/mods/darktide_testlab/trajectory.lua')
local file=assert(io.open(root..'/mods/darktide_testlab/push_followup.tsv'))
local keys=assert(Replay.parse(file:read('*a')));file:close()
local template={weapon_box={.15,.65,.15},actions={
    windup={kind='windup',start_input='start_attack',allowed_chain_actions={
        light_attack={action_name='light'},heavy_attack={action_name='heavy',chain_time=.4}}},
    light={kind='sweep',sweeps={{}},allowed_chain_actions={start_attack={action_name='windup',chain_time=.6}}},
    heavy={kind='sweep'},block={kind='block',allowed_chain_actions={push={action_name='push'}}},
    push={kind='push',total_time=.8,allowed_chain_actions={push_follow_up={action_name='follow',chain_time=.25}}},
    follow={kind='sweep',sweeps={{}},allowed_chain_actions={start_attack={action_name='windup',chain_time=.58}}}},
    action_inputs={block={input_sequence={{input='action_two_hold',value=true}}},
        push={input_sequence={{input='action_one_pressed',hold_input='action_two_hold',value=true}}},
        push_follow_up={input_sequence={{input='action_one_hold',hold_input='action_two_hold',value=true,duration=.3}}},
        heavy_attack={input_sequence={{input='action_one_hold',value=true,duration=.35},{input='action_one_hold',value=false}}}}}
local cases={'follow','idle','jiggle','early','late','expired_queue','release','recenter','native_denial'}
for _,pose_block in ipairs({false,true}) do
for _,case in ipairs(cases) do
    local unit,reference={},{}
    local component={current_action_name='none',start_t=0,time_scale=1}
    local clock=0
    local weapon={weapon_template=template,actions={}}
    local extension={_weapons={primary=weapon},_weapon_action_component=component,
        _action_handler={_calculate_time_scale=function() return 1 end,_validate_action=function(_,settings)
            return not (case=='native_denial' and settings==template.actions.follow)
        end},condition_func_params=function() return {} end}
    extension._action_handler._action_input_extension={peek_next_input=function(_,id)
        assert(id=='weapon_action')
        local elapsed=clock-component.start_t
        if component.current_action_name=='push' and elapsed>=.3 and elapsed<.6 then return 'push_follow_up' end
    end}
    local queries,procs,exits,commits,pushes,follow_starts,denials=0,0,0,0,0,0,0
    local actor,runtime
    local strokes=Strokes.new()
    local owner=assert(Pose.new(Inertia,{profile='hammer',library_path=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'}))
    runtime=Runtime.new(deps,{source='synthetic',unit=unit,owner=owner,strokes=strokes,extension=extension,weapon=weapon,slot='primary',
        defaults={sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1},to_world=function(p) return p.position,p.rotation end,
        cancel_native=function(t)
            if actor then runtime.on_finish(actor,t) end
            component.current_action_name='none'
        end})
    local push_time,commit_frame
    local target={}
    for frame=0,140 do
        local t=frame/52
        clock=t
        local sample=Replay.sample(keys,t)
        if case~='follow' then sample.right.rotation={0,0,0,1} end
        if push_time then
            local age=t-push_time
            if case=='idle' or case=='jiggle' then
                sample.right.position[1]=.2+(case=='jiggle' and .01*math.sin(100*math.pi*t) or 0)
            elseif case=='early' then sample.right.position[1]=.2-math.min(.8,math.max(0,age-.02)*3.2)
            elseif case=='late' then sample.right.position[1]=.2-math.min(.8,math.max(0,age-.85)*3.2)
            elseif case=='expired_queue' then sample.right.position[1]=.2-math.min(.8,math.max(0,age-.65)*3.2)
            elseif case=='release' and age>.1 then sample.buttons[1]=false end
            if case=='recenter' and age>.1 then reference={} end
        end
        local current=assert(runtime.sample({source='synthetic',active=true,tracking_valid=true,reference=reference,
            frame=frame,time=t,dominant=sample.right,support=sample.left,intent=true,
            guarding=not pose_block and sample.buttons[2],pose_block=pose_block,followup_intent=sample.buttons[1]}))
        local primary,block=runtime.inputs(frame),runtime.block_inputs(frame)
        if block.held and component.current_action_name=='none' then component.current_action_name='block';component.start_t=t end
        if primary.pressed and component.current_action_name=='block' then
            pushes=pushes+1; push_time=t; component.current_action_name='push';component.start_t=t
        end
        if current.stroke.committed then
            commits=commits+1;commit_frame=frame
            assert(case=='follow' and t-push_time>=.3 and t-push_time<.8,'out-of-window/non-deliberate follow-up committed: '..case)
            assert(math.abs(current.stroke.remaining-.58)<1e-9,'follow-up used ordinary light debt')
            assert(not primary.pressed and primary.held and block.held,'follow-up broke the native held chord')
        end
        if component.current_action_name=='push' and t-push_time>=.3 then
            local chain=template.actions.push.allowed_chain_actions.push_follow_up
            assert(runtime.allow_chain({},chain,t),'foreign handler was modified')
            local allowed=runtime.allow_chain(extension._action_handler,chain,t)
            if allowed and primary.held and block.held then
                assert(current.stroke.committed,'held chord auto-started follow-up without a stroke')
                follow_starts=follow_starts+1;component.current_action_name='follow';component.start_t=t
                actor={_player_unit=unit,_weapon=weapon,_is_server=true,_unit_data_extension={is_resimulating=false},
                    _weapon_action_component=component,_action_sweep_component={},_action_settings=template.actions.follow,
                    _uses_matrix_data=true,_num_hit_enemies=0,_is_sweep_aborted=function() return false end,_any_sweep_aborted=function() return false end,
                    _exit_damage_window=function() exits=exits+1 end,_handle_exit_procs=function() procs=procs+1 end,
                    _do_overlap=function() queries=queries+1 end}
                assert(runtime.on_start(actor,actor._action_settings,t))
            else denials=denials+1 end
        end
        if actor then
            runtime.update_sweep(actor,1/52,t,actor._action_settings)
            if frame==commit_frame+1 then
                assert(primary.released and not primary.held,'follow-up chord not released after native start')
                assert(runtime.claim(actor,target) and not runtime.claim(actor,target),'follow-up target dedup failed')
            end
            if frame==commit_frame+3 then
                local debt=strokes.status().remaining
                runtime.invalidate('recenter')
                assert(strokes.status().remaining==debt and not runtime.inputs(frame).held and not runtime.block_inputs(frame).held)
                break
            end
        end
        if push_time and component.current_action_name=='push' and t-push_time>=.8 then component.current_action_name='none' end
    end
    if case=='follow' then
        assert(pushes==1 and commits==1 and follow_starts==1 and queries>2 and procs==1 and exits==1,'follow-up runtime path incomplete')
    else assert(commits==0 and follow_starts==0 and queries==0,'rejected follow-up produced physical combat: '..case) end
    if case=='idle' or case=='jiggle' then assert(denials>2,'native automatic chord was not gated') end
    runtime.close()
end
end
print('melee_push_followup=pass real_DLL native_chord_gated deliberate_stroke chain_window recovery dedup idle_50Hzjiggle early_late release recenter native_denial cleanup')
