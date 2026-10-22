-- Native cleanup source is cached from the game-source mirror. No damage
-- numbers here certify actual game results; native chain selection is retained.
local root=assert(arg[1])
local Bridge=dofile(root..'/mods/darktidevr/scripts/mods/darktidevr/darktidevr_melee_action_bridge.lua')
local removed=0
local env=setmetatable({Vector3={flat=function() end,normalize=function() end}}, {__index=_G})
env.table=setmetatable({clear=function(t) for k in pairs(t) do t[k]=nil end end},{__index=table})
env.require=function(name)
    if name:match('/chain_lightning$') then
        return {breadth_first_validation_functions={},depth_first_validation_functions={},jump_validation_functions={}}
    elseif name:match('/chain_lightning_target$') then
        return {remove_all_child_nodes=function(node,callback,context)
            for _,child in ipairs(node.children) do callback(child,context);removed=removed+1 end
            node.children={}
        end}
    end
    return {}
end
local chunk=assert(loadfile(root..'/artifacts/game-reference/chain_lightning_action.lua'))
setfenv(chunk,env)
local Native=chunk()
for _,mode in ipairs({'natural','cancel','resim','stroke_change','native_abort','buffered','cleanup_error'}) do
    local lifecycle=Bridge.new({native_events=true})
    local target,child={},{}
    local chain={is_server=true,chain_root_node={children={}},chain_lightning_hit_units={},
        chain_lightning_temp_targets={},targeting_module_component={},func_context={}}
    function chain.chain_root_node:set_value(key,value) self[key]=value end
    chain.on_chain_node_remove_func=function() if mode=='cleanup_error' then error('injected native node failure') end end
    local queries,starts,exits,procs,finishes=0,0,0,0,0
    local action={_is_server=true,_unit_data_extension={is_resimulating=false},_action_sweep_component={},
        _action_settings={weapon_chain_lightning_template='native'},_chain_lightning_action_data=chain,
        _do_chain_lightning_on_sweep=true,_num_hit_enemies=0,
        _try_make_chain_from_sweep_hit=function(self)
            if self._has_started_chain_lightning then return end
            self._has_started_chain_lightning=true;starts=starts+1
            chain.chain_root_node.children={child};chain.chain_lightning_hit_units[target]=true
            chain.chain_lightning_temp_targets[1]=target;chain.targeting_module_component.target_unit_1=target
        end,
        _is_sweep_aborted=function(self) return self.aborted end,_any_sweep_aborted=function(self) return self.aborted end}
    local function hit(self)
        if lifecycle.claim(self,target) then self:_try_make_chain_from_sweep_hit() end
    end
    action._do_overlap=function(self)
        queries=queries+1
        if mode=='buffered' then self._saved_entries={target};self._num_saved_entries=1 else hit(self) end
    end
    action._merge_saved_entries=function(self,_,_,saved,count) return saved,count end
    action._process_sweep_results=hit
    action._exit_damage_window=function(self)
        lifecycle.native_event(self,'_exit_damage_window',function() exits=exits+1 end)
    end
    action._handle_exit_procs=function(self)
        lifecycle.native_event(self,'_handle_exit_procs',function() procs=procs+1 end)
    end
    action.finish=function(self)
        finishes=finishes+1
        Native.action_finish(self._chain_lightning_action_data)
        self._has_started_chain_lightning=false
        self:_exit_damage_window();self:_handle_exit_procs()
    end
    if mode=='buffered' then action._action_settings.num_frames_before_process=3 end
    assert(lifecycle.bind(action,1))
    assert(lifecycle.step(action,{time=1,frame=1,active=true,stroke_id=1,segments={{},{}},before_query=function() return {} end}))
    assert(queries==2 and starts==(mode=='buffered' and 0 or 1),'physical subdivisions duplicated chain root')
    if mode=='resim' then action._unit_data_extension.is_resimulating=true end
    if mode=='native_abort' then action.aborted=true end
    if mode=='cancel' then lifecycle.finish(action,1.02)
    else lifecycle.step(action,{time=1.02,frame=2,active=false,natural_end=true,stroke_id=mode=='stroke_change' and 2 or 1}) end
    assert(starts==1 and #chain.chain_root_node.children==1,'physical window retired native chain early or lost saved hit')
    assert(not lifecycle.claim(action,{}),'closed stroke admitted another root')
    -- The production hook always executes original finish, even after a
    -- physical cleanup error. Native owns tree removal and no reset is added.
    local ok=pcall(action.finish,action)
    lifecycle.forget(action)
    assert(ok==(mode~='cleanup_error'))
    assert(finishes==1 and exits==1 and procs==1,'native finish or physical exit was duplicated')
    if ok then
        assert(#chain.chain_root_node.children==0 and next(chain.chain_lightning_hit_units)==nil)
        assert(next(chain.chain_lightning_temp_targets)==nil and next(chain.targeting_module_component)==nil)
        assert(action._has_started_chain_lightning==false)
    end
end
local invalid={_is_server=true,_unit_data_extension={},_action_settings={weapon_chain_lightning_template='missing'}}
local ok,why=Bridge.new({native_events=true}).bind(invalid,1)
assert(not ok and why=='native_lightning_lifecycle_unavailable')
print('melee_lightning=pass native_action_lifetime single_root delayed_contact cancellation native_cleanup_source; NOT live damage proof')
