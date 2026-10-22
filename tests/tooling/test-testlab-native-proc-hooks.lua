-- Execute cached native class copying, native queue/drain, and the installed
-- DMF hook implementation. Buff callback is a fixture, not a real blessing.
local root=assert(arg[1])
local function read(path)
    local f=assert(io.open(root..'/'..path,'r'));local value=f:read('*a');f:close();return value
end
local class_source=read('artifacts/game-reference/class.lua')
local hooks_source=read('artifacts/game-reference/installed_dmf_hooks.lua')
local buff_source=read('artifacts/game-reference/buff_extension_base.lua')
local queue_source=assert(buff_source:match('(BuffExtensionBase.add_proc_event = function.-\nend)'))
local drain_source=assert(buff_source:match('(BuffExtensionBase._update_proc_events = function.-)\nlocal _proc_active_buff_index_array'))
local attack_source=read('artifacts/game-reference/attack.lua')
local attack_procs=assert(attack_source:match('(function _already_procced.-)\nlocal _attack_table'))
local attack_buffs=assert(attack_source:match('(function _add_buffs_to_target.-)\nreturn Attack'))
local Observations=dofile(root..'/mods/darktide_testlab/scripts/mods/darktide_testlab/observations.lua')
for _,mode in ipairs({'early','late','mixed'}) do
    local events,warnings={},{}
    local env=setmetatable({},{__index=_G});env._G=env
    env.CLASS={};env.CLASSES=env.CLASS
    env.require=function() return {} end
    env.table=setmetatable({clear=function(value) for key in pairs(value) do value[key]=nil end end,
        is_empty=function(value) return next(value)==nil end},{__index=table})
    local function execute(source,name)
        local chunk=assert(loadstring(source,'@'..name));setfenv(chunk,env);return chunk()
    end
    execute(class_source,'cached_native_class')
    local base=env.class('BuffExtensionBase')
    env.BuffExtensionBase=base;env.PROC_EVENTS_STRIDE=2
    execute(queue_source..'\n'..drain_source,'cached_native_proc_queue_and_drain')
    base.init=function(self)
        self._unit={};self._num_proc_events=0;self._proc_events={};self._proc_events_backup={}
        self._unique_frame_proc={};self._is_server=true;self._portable_random={};self._local_portable_random={}
        self.processed=0;self.activated=0
        self._buffs={{is_predicted=function() return false end,force_predicted_proc=function() return false end,
            skip_send_active_time_rpc=function() return false end,remove_stack_on_proc=function() return false end,
            remove_on_proc=function() return false end,update_proc_events=function(_,t,queue,count)
                assert(t==17 and count==1 and queue[1]=='on_hit' and queue[2].triggering_proc_event=='on_hit')
                self.processed=self.processed+1;return true
            end}}
        self._find_local_index=function() return 3 end
        self._set_proc_active_start_time=function(_,index,t) assert(index==3 and t==17);self.activated=self.activated+1 end
        self._clear_param_tables=function(_,count) assert(count==1) end
    end
    if mode~='late' then env.class('PlayerUnitBuffExtension','BuffExtensionBase') end
    if mode=='early' then env.class('MinionBuffExtension','BuffExtensionBase') end
    env.CLASS.InputService={start_simulate_action=function() end,stop_simulate_action=function() end}
    env.CLASS.InputManager={update=function() end}
    env.DMFMod={info=function() end,warning=function(_,message) warnings[#warnings+1]=message end,
        error=function(_,message) error(message) end,is_enabled=function() return true end,
        get_name=function(self) return self.name end,get_internal_data=function() return false end}
    local dmf=setmetatable({name='DMF',check_wrong_argument_type=function() return false end,
        safe_call_nr=function(_,_,fn,...) return fn(...) end},{__index=env.DMFMod})
    env.get_mod=function() return dmf end
    execute(hooks_source,'installed_dmf_hooks')
    local mod=setmetatable({name='testlab'},{__index=env.DMFMod})
    local api=Observations.new({identity=function() return 'owned' end,report=function(_,record) events[#events+1]=record end})
    local function observer(invoke,self,event,params,...) return api.proc(invoke,{},self,event,params,...) end
    mod:hook('BuffExtensionBase','add_proc_event',observer)
    if mode~='late' then
        local before=env.CLASS.PlayerUnitBuffExtension:new()
        before:add_proc_event('on_hit',{})
        assert(before._num_proc_events==1 and #events==0,'fixture did not reproduce copied method escaping late base hook')
    end
    mod:hook('PlayerUnitBuffExtension','add_proc_event',observer)
    mod:hook('MinionBuffExtension','add_proc_event',observer)
    if mode=='late' then env.class('PlayerUnitBuffExtension','BuffExtensionBase') end
    if mode~='early' then env.class('MinionBuffExtension','BuffExtensionBase') end
    for _,name in ipairs({'PlayerUnitBuffExtension','MinionBuffExtension'}) do
        local extension=env.CLASS[name]:new()
        local count=#events;local params={actual_damage_dealt=9}
        extension:add_proc_event('on_hit',params)
        assert(extension._num_proc_events==1 and extension._proc_events[2]==params and #events==count+1,
            mode..':'..name..': native queue duplicated or missed')
        assert(events[#events].extension_class==name and events[#events].queued and events[#events].actual_damage==9)
        extension:_update_proc_events(17)
        assert(extension.processed==1 and extension.activated==1 and extension._num_proc_events==0 and
            next(extension._proc_events_backup)==nil,'native event draining or activation changed')
    end
    env.Managers={state={extension={system=function() return {is_ally=function() return false end} end}}}
    env.Breed={is_player=function(breed) return breed and breed.player==true end}
    env.ScriptUnit={has_extension=function(_,kind)
        if kind=='unit_data_system' then return {read_component=function() return {is_active=false} end} end
    end}
    env.Vector3Box=function(value) return value end
    env.FixedFrame={get_latest_fixed_time=function() return 17 end}
    env.damage_types_no_proc={};env.attack_results={died='died'}
    env.proc_events={on_hit='on_hit',on_damage_dealt='on_damage_dealt',on_kill='on_kill',
        on_player_hit_received='on_player_hit_received',on_bleed_on_activated_hit_trait_hit='on_bleed_on_activated_hit_trait_hit'}
    execute(attack_procs..'\n'..attack_buffs,'cached_native_attack_proc_dispatch')
    local function extension(name)
        local value=env.CLASS[name]:new()
        value.request_proc_event_param_table=function() return {} end
        return value
    end
    local attacker,recipient={},{}
    local function dispatch(server,owner_ext,target_ext,result,damage,actual,already)
        env._handle_buffs(server,already,{name='native_fixture_profile'},owner_ext,target_ext,recipient,
            damage,0,actual,result,'staggered',false,'torso',false,false,false,false,'melee',attacker,attacker,
            {0,1,0},1,1,1,{name='player',player=true},{name='player',player=true},{name='player',player=true},
            'slash',1,nil,nil,nil,false,false,nil)
    end
    local owner=extension('PlayerUnitBuffExtension')
    local target=extension('PlayerUnitBuffExtension')
    local count=#events
    dispatch(true,owner,target,'damaged',12,9)
    assert(owner._num_proc_events==2 and target._num_proc_events==1 and #events==count+3)
    assert(owner._proc_events[1]=='on_hit' and owner._proc_events[2].actual_damage_dealt==9 and
        owner._proc_events[3]=='on_damage_dealt' and target._proc_events[1]=='on_player_hit_received',
        'native outgoing/incoming proc dispatch metadata changed')
    target=extension('PlayerUnitBuffExtension');count=#events
    dispatch(true,nil,target,'blocked',0,0)
    assert(target._num_proc_events==1 and #events==count+1 and events[#events].result=='blocked',
        'native blocked outcome missed concrete player observation')
    target=extension('PlayerUnitBuffExtension');count=#events
    dispatch(false,nil,target,'blocked',0,0)
    assert(target._num_proc_events==0 and #events==count,'client-only incoming proc invented')
    dispatch(true,nil,target,'blocked',0,0,{on_player_hit_received=true})
    assert(target._num_proc_events==0 and #events==count,'native per-attack proc dedup bypassed')
    assert(#warnings==0,'DMF rejected/duplicated a registered hook')
end
do
    local source=read('artifacts/game-reference/proc_buff.lua')
    local update=assert(source:match('(ProcBuff.update_proc_events = function.-)\nProcBuff._proc_chance'))
    local chance=assert(source:match('(ProcBuff._proc_chance = function.-)\nProcBuff._start_proc_fx'))
    local activation=assert(source:match('(ProcBuff._can_activate = function.-)\nProcBuff.update ='))
    local env=setmetatable({ProcBuff={},PROC_EVENTS_STRIDE=2,PROCCED_PROC_EVENTS={},
        table=setmetatable({clear=function(value) for key in pairs(value) do value[key]=nil end end},{__index=table})},{__index=_G})
    local chunk=assert(loadstring(update..'\n'..chance..'\n'..activation,'@cached_native_ProcBuff_processing'))
    setfenv(chunk,env);chunk()
    local records={}
    local api=Observations.new({identity=function() return 'player' end,report=function(_,record) records[#records+1]=record end})
    local function random(value)
        return {draws=0,value=value,seed=function(self) return self.draws end,
            next_random=function(self) self.draws=self.draws+1;return self.value end}
    end
    local rng,local_rng=random(.2),random(.9)
    local buff=setmetatable({_unit={},__class_name='ProcBuff',_template_data={calls=0},_template_context={},
        _buff_component={},_component_keys={active_start_time_key='active'},
        _template={name='native_fixture_proc',proc_events={on_hit=1},proc_func=function(_,data) data.calls=data.calls+1 end},
        _is_proc_active=function() return true end,_is_cooling_down=function() return false end},{__index=env.ProcBuff})
    local function invoke(local_event)
        return api.buff_proc(env.ProcBuff.update_proc_events,{},buff,17,{'on_hit',{is_local_proc_event=local_event}},1,rng,local_rng)
    end
    local active,map=invoke(false)
    assert(active and map==env.PROCCED_PROC_EVENTS and map.on_hit==1 and buff._template_data.calls==1 and
        buff._buff_component.active==17 and rng.draws==0 and local_rng.draws==0)
    assert(records[1].events.on_hit==1 and records[1].seed_before==0 and records[1].seed_after==0)
    buff._template.proc_events.on_hit=.5
    active,map=invoke(false)
    assert(not active and next(map)==nil and #records==1 and local_rng.draws==1 and rng.draws==0 and
        records[1].events.on_hit==1,'native RNG miss or recycled event-map snapshot changed')
    buff._template.predicted=true
    active=invoke(false)
    assert(active and rng.draws==1 and local_rng.draws==1 and records[#records].seed_before==0 and records[#records].seed_after==1,
        'observer consumed RNG or switched native RNG source')
    local_rng.value=.2
    active=invoke(true)
    assert(not active and records[#records].total==1 and records[#records].activated==false and local_rng.draws==2,
        'local-only native event misreported as replicated activation')
    local count=#records
    buff._template.check_proc_func=function() return false end
    invoke(false);assert(#records==count,'native check rejection fabricated activation')
    buff._template.check_proc_func=nil;buff._template.cooldown_duration=2
    local draws=rng.draws
    invoke(false);assert(#records==count and rng.draws==draws,'native cooldown rejection consumed RNG or activated')
    buff._template.cooldown_duration=nil
    local failure={native_proc_error=true}
    buff._template.proc_func=function() error(failure) end
    local ok,err=pcall(invoke,false);assert(not ok and err==failure)
    buff._template.proc_func=function(_,data) data.calls=data.calls+1 end
    invoke(false);assert(#records==count+1,'failed native callback stranded observer')
    local calls=buff._template_data.calls;count=#records
    local wrapper=function(self,t,events,total,prng,lrng)
        return api.buff_proc(env.ProcBuff.update_proc_events,{},self,t,events,total,prng,lrng)
    end
    api.buff_proc(wrapper,{},buff,17,{'on_hit',{}},1,rng,local_rng)
    assert(buff._template_data.calls==calls+1 and #records==count+1,'copied buff processor duplicated native effects/observations')
end
print('testlab_native_proc_hooks=pass actual_native_class_copy installed_DMF early_late_mixed player_minion_once native_queue_drain native_Attack_dispatch_dedup actual_ProcBuff_conditions_RNG_cooldown_local_event_recycled_map_errors; NOT live_buff_effect_proof')
