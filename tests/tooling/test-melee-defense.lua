local root=assert(arg[1])
local prefix=root..'/mods/darktidevr/scripts/mods/darktidevr/darktidevr_melee_'
local Defense=dofile(prefix..'defense.lua')
local Timing=dofile(prefix..'timing.lua')
assert(Defense.guard_role({name='powermaul_shield_p1_m1'})=='support')
assert(Defense.guard_role({name='powermaul_shield_p1_m2'})=='support')
assert(Defense.guard_role({keywords={'melee','powermaul_shield'}})=='support')
assert(Defense.guard_role({name='powermaul_p1_m1'})=='dominant')
assert(Defense.guard_role({keywords={'melee','dual_wield'}})=='dominant')
local function pose(y,x,z,q) return {position={x or .2,y,z or -.3},rotation=q or {0,0,0,1}} end
local detector=Defense.new()
local function sample(frame,raw,virtual,intent,ready)
    return detector.update({frame=frame,time=frame*.02,raw=raw,virtual=virtual or raw,
        intent=intent~=false,push_ready=ready~=false})
end
assert(not sample(0,pose(.3),nil,false).blocking,'guard pose alone granted block')
assert(not sample(1,pose(.3,0,-1)).blocking,'button alone granted block below guard')
assert(not sample(2,pose(.3,0,-.3,{-math.sqrt(.5),0,0,math.sqrt(.5)})).blocking,'forward-pointing shaft counted as guard')
local entry=sample(3,pose(.3))
assert(entry.blocking and entry.pressed)
for frame=4,10 do assert(not sample(frame,pose(.3)).push) end
local pushes=0
for frame=11,16 do
    local current=sample(frame,pose(.3+(frame-10)*.04))
    if current.push then pushes=pushes+1 end
    assert(sample(frame,pose(.9))==current,'duplicate frame changed gesture result')
end
assert(pushes==1,'coherent raw and actual forward shove did not commit once')
for frame=17,40 do assert(not sample(frame,pose(.54)).push,'stationary overlap repeated push') end
for frame=41,140 do assert(not sample(frame,pose(.54+(frame%2)*.02)).push,'50Hz waggle committed push') end
local released=sample(141,pose(.54),nil,false)
assert(released.released and not released.blocking)
assert(sample(142,pose(.3)).blocking)
local lost=detector.update({frame=143,time=2.86,intent=true,push_ready=true})
assert(lost.released and not lost.blocking and not lost.push,'lost shield tracking kept guard')
do
    local automatic=Defense.new()
    local function auto(frame,raw,virtual,enabled)
        return automatic.update({frame=frame,time=frame*.02,raw=raw,virtual=virtual or raw,
            intent=enabled~=false,pose_only=true,push_ready=true})
    end
    assert(not auto(0,pose(.3)).blocking,'pose guard engaged without deliberate settling')
    for frame=1,4 do assert(not auto(frame,pose(.3)).blocking) end
    for frame=5,12 do auto(frame,pose(.3)) end
    assert(auto(13,pose(.3)).blocking,'settled pose did not block without button')
    local count=0
    for frame=14,20 do if auto(frame,pose(.3+math.min(frame-13,6)*.04)).push then count=count+1 end end
    assert(count==1,'pose-only shove did not retain native single-push gesture')
    assert(auto(21,pose(.54),nil,false).released,'disabling pose guard left block latched')
    automatic.reset()
    for frame=0,15 do assert(not auto(frame,pose(.2+frame*.03)).blocking,'fast pass through guard became auto block') end
    automatic.reset()
    for frame=0,15 do auto(frame,pose(.3)) end
    assert(auto(16,pose(.3,0,-1)).released,'lowering pose did not release auto block')
    automatic.reset()
    for frame=0,15 do assert(not auto(frame,pose(.3),pose(.3,0,-1)).blocking,'raw-only pose bypassed weighted guard') end
    automatic.reset()
    for frame=0,15 do auto(frame,pose(.3)) end
    assert(not automatic.update({frame=16,time=1,raw=pose(.3),virtual=pose(.3),intent=true,pose_only=true}).blocking,
        'tracking time gap retained auto block')
end
detector.reset()
for frame=0,10 do sample(frame,pose(.3)) end
for frame=11,18 do assert(not sample(frame,pose(.3+(frame-10)*.04),pose(.3)).push,'raw shove bypassed weighted weapon') end
detector.reset()
for frame=0,10 do sample(frame,pose(.3)) end
for frame=11,18 do assert(not sample(frame,pose(.3+(frame-10)*.04),nil,true,false).push,'shove bypassed native readiness') end
local allow=true
local template={action_inputs={block={input_sequence={{input='action_two_hold',value=true}}},
    push={input_sequence={{input='action_one_pressed',hold_input='action_two_hold',value=true}}}},
    actions={block={kind='block',allowed_chain_actions={push={action_name='push',chain_time=.3}}},push={kind='push'}}}
local component={current_action_name='block',start_t=0}
local extension={_weapons={primary={weapon_template=template}},_weapon_action_component=component,
    _action_handler={_calculate_time_scale=function() return 2 end,_validate_action=function() return allow end},
    condition_func_params=function() return {} end}
assert(Timing.defense(extension,'primary',.1).supported and not Timing.defense(extension,'primary',.1).push_ready)
assert(Timing.defense(extension,'primary',.15).push_ready,'native chain scale ignored')
allow=false; assert(not Timing.defense(extension,'primary',1).push_ready,'native conditions ignored')
allow=true; component.current_action_name='push'; assert(not Timing.defense(extension,'primary',1).push_ready)
template.action_inputs.block.input_sequence[1].input='unknown'
assert(not Timing.defense(extension,'primary',1).supported,'unknown parser granted defensive inputs')
template.actions.push.total_time=.8
template.actions.push.allowed_chain_actions={push_follow_up={action_name='follow',chain_time=.25}}
template.actions.follow={kind='sweep',allowed_chain_actions={start_attack={action_name='windup',chain_time=.58}}}
template.actions.windup={kind='windup',allowed_chain_actions={light_attack={action_name='light'}}}
template.actions.light={kind='sweep'}
template.action_inputs.push_follow_up={input_sequence={{input='action_one_hold',hold_input='action_two_hold',value=true,duration=.3}}}
local queued=true
extension._action_handler._action_input_extension={peek_next_input=function() return queued and 'push_follow_up' end}
component.current_action_name='push';component.time_scale=2
local plan=assert(Timing.follow_up(extension,'primary',.29,'push'))
assert(not plan.ready and plan.open_after==.3 and plan.close_after==.4,'fixed input hold scaled with attack speed')
assert(Timing.follow_up(extension,'primary',.3,'push').ready)
assert(not Timing.follow_up(extension,'primary',.4,'push').ready,'expired native action accepted follow-up')
queued=false; assert(not Timing.follow_up(extension,'primary',.3,'push').ready,'expired native input queue accepted follow-up')
queued=true;allow=false;assert(not Timing.follow_up(extension,'primary',.3,'push').ready,'follow-up bypassed native conditions')
allow=true;component.time_scale=4
assert(not Timing.follow_up(extension,'primary',.3,'push'),'impossible native hold/window was widened')
component.time_scale=1;extension._action_handler._action_input_extension=nil
assert(not Timing.follow_up(extension,'primary',.3,'push'),'missing native parser silently assumed readiness')
print('melee_defense=pass guard_requires_input_pose raw_and_weighted_shove single_commit duplicate_frame idle_waggle native_chain_scale_conditions unknown_parser')
