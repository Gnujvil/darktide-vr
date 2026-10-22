require = function(path)
    assert(path ~= "scripts/utilities/action/action_handler",
        "ActionHandler loaded before native NetworkConstants initialization")
    return {}
end
local aim = assert(loadfile(arg[1]))()
local player_unit = {}
Managers = {
    player = {local_player = function() return {player_unit = player_unit} end},
    state = {game_mode = {game_mode_name = function() return "shooting_range" end}},
}
local hand_position, hand_rotation = {}, {}
local head_position, head_rotation = {}, {}
-- The mod resolves a role to a physical side in one place now
-- (presentation.hand_side, docs/phase1/handedness-audit-2026-09-16.md).
local presentation = {controller_aim_target = function() return hand_position, hand_rotation end,
    eye_pose = function() return head_position, head_rotation end,
    hand_side = function(role) return role == 'support' and 'left' or 'right' end}
local hooks = {}
local mod = {
    hook = function(_, object, method, callback)
        if method == "_validate_single_chain_action" then
            assert(object == "ActionHandler", "Native chain hook must use DMF delayed class lookup")
        end
        hooks[method] = callback
    end,
    hook_safe = function() end, command = function() end, info = function() end,
}
aim.install(mod, presentation, {authoring_enabled = true})
local component = {position = {}, rotation = {}, other = 7}
local extension = {_first_person_component=component}
extension.is_within_default_view = function(self, point)
    return self._first_person_component.rotation == head_rotation and
        self._first_person_component.position == head_position and point ~= 'behind'
end
extension.unrelated_method = function(self) assert(self == extension); return 9 end
local action = {_player_unit = player_unit, _first_person_component = component,
    _first_person_extension=extension}
local function verify(self, argument)
    assert(argument == 42)
    assert(self._first_person_component.rotation == hand_rotation)
    assert(self._first_person_component.position == component.position, "changed melee reach origin")
    assert(self._first_person_component.other == 7)
    assert(component.rotation ~= hand_rotation, "changed shared movement heading")
    assert(self._first_person_extension:is_within_default_view({}), "head-facing view rejected hand-directed contact")
    assert(self._first_person_extension:unrelated_method() == 9)
    assert(extension._first_person_component == component, "modified camera extension")
    return "position", nil, "direction"
end
local a, b, c = aim.with_melee_aim(action, verify, 42)
assert(a == "position" and b == nil and c == "direction", "lost action return values")
assert(action._first_person_component == component)
assert(action._first_person_extension == extension)
local ok = pcall(aim.with_melee_aim, action, function() error("fixture") end)
assert(not ok and action._first_person_component == component, "failed action leaked pose override")
assert(action._first_person_extension == extension, "failed action leaked view override")
for _, method in ipairs({"start", "_update_sweep", "_push", "_find_explosion_position_and_direction"}) do
    assert(hooks[method], "missing melee hook: " .. method)
    hooks[method](verify, action, 42)
end
action._player_unit = {}
aim.with_melee_aim(action, function(self) assert(self._first_person_component == component) end)
action._player_unit = player_unit
local interactor = {_unit=player_unit,_first_person_component=component}
for _, method in ipairs({"_find_interaction_object", "_find_interaction_object_3p",
        "_check_valid_ongoing_interaction", "force_update_smart_tag_targets"}) do
    local function verify_interaction(self)
        assert(self._first_person_component.position == hand_position)
        assert(self._first_person_component.rotation == hand_rotation)
        assert(self._first_person_component.other == 7)
        return "target", nil, 4
    end
    local target, missing, node = hooks[method](verify_interaction, interactor)
    assert(target == "target" and missing == nil and node == 4)
    assert(interactor._first_person_component == component)
    assert(not pcall(hooks[method], function() error("interaction failure") end, interactor))
    assert(interactor._first_person_component == component)
    interactor._unit = {}
    hooks[method](function(self) assert(self._first_person_component == component) end, interactor)
    interactor._unit = player_unit
end
hand_rotation = nil
aim.with_melee_aim(action, function(self) assert(self._first_person_component == component) end)
-- Desktop stock attacks have a fresh rendered head but no tracked controller.
-- Preserve their stock action pose while evaluating the native cone at that head.
aim.with_melee_aim(action, function(self)
    assert(self._first_person_component == component)
    assert(self._first_person_extension:is_within_default_view('front'))
    assert(not self._first_person_extension:is_within_default_view('behind'))
end)
assert(not pcall(aim.with_melee_aim, action, function() error('missing hand native failure') end))
assert(action._first_person_component == component and action._first_person_extension == extension)
-- Private stock proving keeps its simulated action pose. Only the native view
-- predicate uses the rendered head; no hand-authored attack pose is installed.
hand_rotation = {}
presentation.is_controller_aim_mode = function() return false end
for _, method in ipairs({"start", "_update_sweep", "_push", "_find_explosion_position_and_direction"}) do
    local result, missing, tail = hooks[method](function(self)
        assert(self._first_person_component == component)
        assert(self._first_person_extension:is_within_default_view('front'))
        assert(not self._first_person_extension:is_within_default_view('behind'))
        return 'stock', nil, 12
    end, action)
    assert(result == 'stock' and missing == nil and tail == 12)
end
for _, method in ipairs({"_find_interaction_object", "_find_interaction_object_3p",
        "_check_valid_ongoing_interaction", "force_update_smart_tag_targets"}) do
    local result, missing, tail = hooks[method](function(self)
        assert(self._first_person_component == component, 'Online interaction replaced simulation pose')
        return 'stock_target', nil, 14
    end, interactor)
    assert(result == 'stock_target' and missing == nil and tail == 14)
end
do
    local mode = Managers.state.game_mode.game_mode_name
    Managers.state.game_mode.game_mode_name = function() return 'mission' end
    aim.with_melee_aim(action, function(self)
        assert(self._first_person_extension == extension, 'Public stock view was replaced')
        assert(self._first_person_component == component)
    end)
    Managers.state.game_mode.game_mode_name = mode
    action._unit_data_extension = {is_resimulating=true}
    aim.with_melee_aim(action, function(self)
        assert(self._first_person_extension == extension, 'Historical stock view was replaced')
        assert(self._first_person_component == component)
    end)
    action._unit_data_extension = nil
end
do
    local updates,finishes,hits,after=0,0,0,0
    presentation.physical_melee={update_sweep=function() updates=updates+1;return true end,
        on_finish=function() finishes=finishes+1 end,before_hit=function() return false end,
        hit_direction=function() return 'actual_travel' end,after_hit=function() after=after+1 end}
    hooks._update_sweep(function() error('physical collision fell through to authored stock path') end,action,.02,1,0,{})
    assert(updates==1,'physical sweep dispatch was lost in the shared controller-aim hook')
    local function native_hit(_,t,u,a,h,s,p,d)
        hits=hits+1; assert(d=='actual_travel'); return true,false
    end
    hooks._process_hit(native_hit,action,1,{},nil,{}, {},nil,'authored',nil)
    assert(hits==0,'physical target denial was bypassed')
    presentation.physical_melee.before_hit=function() return true end
    local aborted,armor=hooks._process_hit(native_hit,action,1,{},nil,{}, {},nil,'authored',nil)
    assert(aborted and armor==false and hits==1 and after==1)
    assert(hooks.finish(function() return 'native_finish' end,action,'done',nil,1)=='native_finish' and finishes==1)
    local gate=true
    presentation.physical_melee.allow_chain=function() return gate end
    local function native_chain() return true,'follow','settings',nil end
    local valid,name,settings,reset=hooks._validate_single_chain_action(native_chain,{}, {},1)
    assert(valid and name=='follow' and settings=='settings' and reset==nil)
    gate=false
    valid,name,settings=hooks._validate_single_chain_action(native_chain,{}, {},1)
    assert(not valid and name=='follow' and settings=='settings','physical chain denial bypassed or lost native results')
    gate=true
    assert(not hooks._validate_single_chain_action(function() return false end,{}, {},1),'physical gate overrode native denial')
    local events={}
    presentation.physical_melee.native_event=function(self,name,invoke,...)
        events[name]=(events[name] or 0)+1
        return true
    end
    for _,name in ipairs({'_exit_damage_window','_handle_exit_procs'}) do
        hooks[name](function() error('handled native lifecycle fell through') end,action,1)
        assert(events[name]==1)
    end
    hooks._start_hit_stickyness(function(self,settings,t,direction) assert(direction=='actual_travel') end,action,{},1,'authored')
    local native_finishes,after_finishes=0,0
    presentation.physical_melee.on_finish=function() error('injected before-finish cleanup failure') end
    presentation.physical_melee.after_finish=function() after_finishes=after_finishes+1 end
    assert(not pcall(hooks.finish,function() native_finishes=native_finishes+1 end,action,'done',nil,1))
    assert(native_finishes==1 and after_finishes==1,'cleanup failure skipped native finish or event retirement')
end
do
    local head_position,head_rotation={},{}
    local original_predicate=extension.is_within_default_view
    extension.is_within_default_view=function(self,point)
        return self._first_person_component.position==head_position and
            self._first_person_component.rotation==head_rotation and point=='front'
    end
    presentation.eye_pose=function(unit) assert(unit==nil);return head_position,head_rotation end
    presentation.physical_melee.update_sweep=function(self)
        assert(self._first_person_component==component,'physical view changed shared pose/sweep origin')
        assert(self._first_person_extension:is_within_default_view('front'),'tracked visible contact rejected')
        assert(not self._first_person_extension:is_within_default_view('behind'),'native view rejection bypassed')
        assert(self._first_person_extension:unrelated_method()==9)
        return true
    end
    hooks._update_sweep(function() error('handled physical sweep fell through') end,action,.02,1,0,{})
    assert(action._first_person_extension==extension and action._first_person_component==component)
    local first,missing,last=aim.with_physical_view(action,function() return 'first',nil,7 end)
    assert(first=='first' and missing==nil and last==7,'physical view lost return values')
    assert(not pcall(aim.with_physical_view,action,function() error('native query failure') end))
    assert(action._first_person_extension==extension and action._first_person_component==component,'query failure leaked view proxy')
    action._player_unit={}
    aim.with_physical_view(action,function(self) assert(self._first_person_extension==extension,'remote view was replaced') end)
    action._player_unit=player_unit
    presentation.eye_pose=function() end
    aim.with_physical_view(action,function(self) assert(self._first_person_extension==extension,'stale head installed a view proxy') end)
    extension.is_within_default_view=original_predicate
end
print("melee_aim=pass physical_dispatch target_denial actual_direction native_finish scoped_tracked_head_view native_view_rejection exception_remote_stale_isolation")
