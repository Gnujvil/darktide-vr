local root=assert(arg[1])
local prefix=root..'/mods/darktide_testlab/scripts/mods/darktide_testlab/'
local Controls=dofile(prefix..'combat_controls.lua')
local Isolation=dofile(prefix..'range_isolation.lua')
local toggles,allowed=0,true
local input=Controls.new(function() toggles=toggles+1 end,function() return allowed end)
input.sample(0,true,0);input.sample(0,true,.02)
assert(input.sample(128,true,.04)==128,'single sprint click consumed')
input.sample(0,true,.06)
for frame=4,40 do assert(input.sample(384+1,true,frame*.02)==1,'chord leaked to sprint/tag or ate trigger') end
assert(toggles==1,'held chord repeated toggle')
assert(input.sample(128,true,.82)==0,'partial chord release became sprint')
input.sample(0,true,.84)
for frame=43,65 do input.sample(384,true,frame*.02) end
assert(toggles==2,'second deliberate chord did not stop')
allowed=false
assert(input.sample(384,true,1.32)==384)
allowed=true
for frame=67,95 do input.sample(384,true,frame*.02) end
assert(toggles==2,'held chord acquired ownership on context return')
input.sample(0,true,1.92);input.sample(384,true,1.94);input.sample(384,true,3)
assert(toggles==2,'time discontinuity fired chord')

do
    local taps,holds=0,0
    local controls=Controls.new(function()holds=holds+1 end,function()return true end,function()taps=taps+1 end)
    controls.sample(0,true,0);controls.sample(0,true,.02)
    controls.sample(384,true,.04);controls.sample(384,true,.12);controls.sample(0,true,.14)
    controls.sample(0,true,.16);assert(taps==1 and holds==0,'short chord did not request exactly one enemy')
    for i=9,35 do controls.sample(384,true,i*.02) end
    controls.sample(0,true,.72);assert(holds==1 and taps==1,'hold also spawned enemy')
    controls.sample(384,true,.74);controls.sample(128,true,.76);controls.sample(0,true,.78)
    assert(taps==1,'partial-release chord requested enemy')
end
do
    local blocked=true
    local calls={start=0,condition=0,event=0}
    local steps={}
    for _,name in ipairs({'enemies_loop','weak_enemies_loop','medium_enemies_loop','heavy_enemies_loop'}) do
        steps[name]={start_func=function(_,_,_,data) calls.start=calls.start+1;data.native=true end,
            condition_func=function()calls.condition=calls.condition+1;return 'native' end,
            on_event=function()calls.event=calls.event+1 end}
    end
    Isolation.guard_defaults(steps,function()return blocked end,function()end)
    for _,step in pairs(steps)do
        local data={};step.start_func(nil,nil,nil,data,0)
        assert(next(data.units)==nil and next(data.spawn_datas)==nil and next(data.enemies)==nil)
        for i=1,100 do assert(step.condition_func()==false);step.on_event() end
    end
    assert(calls.start==0 and calls.condition==0 and calls.event==0,'default spawning reached native/Creature loop')
    blocked=false
    for _,step in pairs(steps)do
        local data={};step.start_func(nil,nil,nil,data,0);assert(data.native)
        assert(step.condition_func()=='native');step.on_event()
    end
    assert(calls.start==4 and calls.condition==4 and calls.event==4,'native default restoration was not forwarded')
end
local function fixture(native,respawn)
    local f={time=0,settings={cs_enable_training_grounds_respawn=respawn},context={unit={},session={}},events={}}
    f.enemy={};f.ally={};f.units={f.enemy,f.ally}
    f.system={_current_scenario={},_parallel_scenarios={shooting_range={}}}
    local step=native and {spawn_datas={{unit=f.enemy},{unit={}},{}}} or {units={[f.enemy]={},[1]={}}}
    f.system._parallel_scenarios.shooting_range.enemies_loop={scenario_data={step_data=step}}
    function f.system:stop_parallel_scenario(alias,name)
        self._parallel_scenarios[alias][name]=nil;f.stops=(f.stops or 0)+1
        if f.fail_stop then error('stop failure after removal') end
    end
    function f.system:start_parallel_scenario(alias,name)
        if f.fail_start then error('start failure') end
        self._parallel_scenarios[alias][name]={};f.starts=(f.starts or 0)+1
    end
    f.api=Isolation.new({context=function() return f.context end,scenario=function() return f.system end,
        settings=function() return f.settings end,minions=function() return f.units end,
        alive=function(u) assert(type(u)=='table','placeholder passed to native Unit.alive');return u and not u.dead end,
        allied=function(_,u) return u==f.ally end,retire=function(u)
            assert(u==f.enemy);f.despawns=(f.despawns or 0)+1
            if not f.delayed then u.dead=true end
        end,
        time=function() return f.time end,emit=function(kind) f.events[#f.events+1]=kind end})
    return f
end
local function drained(f)
    -- One update observes native retirement; later updates let delayed VFX
    -- cleanup drain. Repeated calls at the same timestamp cannot skip it.
    assert(not f.api.ready())
    assert(not f.api.ready())
    f.time=f.time+4.01
    assert(f.api.ready())
end
do
    local f=fixture(false,true);f.delayed=true;f.api.begin()
    assert(not f.api.ready() and f.api.active() and not f.starts,'attacker started before native dissolution completed')
    assert(not f.api.restore('cancel') and not f.starts and not f.settings.cs_enable_training_grounds_respawn,
        'cancel restarted targets while old dissolution was pending')
    f.time=1;assert(not f.api.ready() and f.despawns==1,'native dissolution requested twice')
    f.enemy.dead=true
    drained(f);assert(f.api.restore('finished') and f.starts==1 and f.settings.cs_enable_training_grounds_respawn)
end
do
    local f=fixture(false,true);f.delayed=true;f.api.begin();f.time=46
    assert(not pcall(f.api.ready) and f.api.active(),'dissolution timeout allowed attacker')
    f.context=nil;f.api.restore('level_exit')
    assert(not f.api.active() and not f.starts and f.settings.cs_enable_training_grounds_respawn)
end
for _,original in ipairs({false,true}) do
    local f=fixture(false,original);f.delayed=true;f.api.begin()
    assert(f.api.restore('unload') and not f.api.active() and f.starts==1)
    assert(f.settings.cs_enable_training_grounds_respawn==original and not f.enemy.dead,
        'unload lost original cache or bypassed pending native dissolution')
end
for _,native in ipairs({false,true}) do
    local f=fixture(native,true);f.api.begin()
    assert(f.api.active() and f.enemy.dead and not f.ally.dead and not f.settings.cs_enable_training_grounds_respawn)
    drained(f)
    f.api.restore('off');f.api.restore('duplicate')
    assert(not f.api.active() and f.starts==1 and f.despawns==1 and f.settings.cs_enable_training_grounds_respawn)
end
do
    local f=fixture(false,true);f.units[#f.units+1]={}
    assert(not pcall(f.api.begin) and not f.api.active() and not f.stops,'unknown trial mutated before refusal')
end
do
    local f=fixture(false,true);f.fail_stop=true
    assert(not pcall(f.api.begin));assert(not f.api.restore('rollback'));drained(f);f.api.restore('rollback')
    assert(f.starts==1 and not f.api.active() and f.settings.cs_enable_training_grounds_respawn)
end
do
    local f=fixture(false,false);f.api.begin();drained(f);f.fail_start=true
    assert(not pcall(f.api.restore,'failed') and f.settings.cs_enable_training_grounds_respawn==false)
    f.fail_start=false;f.api.restore('retry')
    assert(f.api.active() and f.settings.cs_enable_training_grounds_respawn,'one-time native respawn was not allowed')
    f.units[1]={};f.api.restore('spawned')
    assert(not f.api.active() and f.settings.cs_enable_training_grounds_respawn==false)
end
do
    local f=fixture(false,true);f.delayed=true
    local enemies={}
    for i=1,48 do enemies[i]={} end
    f.units={unpack(enemies)};f.units[#f.units+1]=f.ally
    f.system._parallel_scenarios.shooting_range.enemies_loop.scenario_data.step_data.units={}
    for _,u in ipairs(enemies) do
        f.system._parallel_scenarios.shooting_range.enemies_loop.scenario_data.step_data.units[u]={}
    end
    -- Observe calls without changing the production scheduler or lifetime.
    local calls,inflight,peak,last,finished=0,{},0,-math.huge,-math.huge
    f.api=Isolation.new({context=function() return f.context end,scenario=function() return f.system end,
        settings=function() return f.settings end,minions=function() return f.units end,
        alive=function(u) return not u.dead end,allied=function(_,u) return u==f.ally end,
        retire=function(u)
            assert(f.time-last>=.249,'multiple retirements in one update or interval')
            assert(f.time-finished>=.249,'native deletion settling gap skipped')
            last=f.time;calls=calls+1;inflight[u]=f.time+1.2
            local n=0;for _ in pairs(inflight) do n=n+1 end
            peak=math.max(peak,n);assert(n<=1,'overlapping native retirements')
        end,time=function() return f.time end,emit=function() end})
    f.api.begin()
    for i=1,3 do assert(not f.api.ready()) end
    assert(calls==1,'same-frame calls bypassed retirement limit')
    for frame=1,6000 do
        f.time=frame*.02
        for u,done in pairs(inflight) do
            if f.time>=done then u.dead=true;inflight[u]=nil;finished=f.time end
        end
        if f.api.ready() then break end
    end
    assert(calls==48 and peak==1 and not f.ally.dead,'populated range did not drain sequentially')
    assert(f.time>48*1.2,'settling gaps were skipped')
    assert(f.api.ready() and f.api.restore('off') and f.starts==1,'normal targets not restored after drain')
    print(string.format('range_retirement=pass targets=%d peak_inflight=%d elapsed_seconds=%.2f native_duration_seconds=1.2',calls,peak,f.time))
end
do
    local f=fixture(false,true)
    local second={};f.units[#f.units+1]=second
    f.system._parallel_scenarios.shooting_range.enemies_loop.scenario_data.step_data.units[second]={}
    local calls=0
    f.api=Isolation.new({context=function()return f.context end,scenario=function()return f.system end,
        settings=function()return f.settings end,minions=function()return f.units end,
        alive=function(u)return not u.dead end,allied=function(_,u)return u==f.ally end,
        retire=function(u) calls=calls+1;u.dead=true end,time=function()return f.time end,emit=function()end})
    f.api.begin();assert(calls==1)
    assert(not f.api.ready());f.time=.24;assert(not f.api.ready() and calls==1)
    -- Even a long missed update requests only one new deletion.
    f.time=5;assert(not f.api.ready() and calls==2)
    assert(not f.api.ready() and calls==2)
    f.time=9.01;assert(f.api.ready())
    assert(f.api.restore('off') and f.starts==1 and not f.ally.dead)
end
do
    local f=fixture(false,true);f.api.begin();f.context=nil;f.api.restore('level_exit')
    assert(not f.starts and not f.api.active() and f.settings.cs_enable_training_grounds_respawn)
end
local data=dofile(prefix..'darktide_testlab_data.lua')
do
    local f=fixture(false,true)
    assert(not pcall(f.api.begin,true),'populated combat activation was not refused')
    assert(not f.api.active() and not f.stops and not f.despawns and not f.enemy.dead and f.settings.cs_enable_training_grounds_respawn,
        'refused populated activation changed native room or respawn setting')
end
do
    -- Exercise the actual production isolation adapter: quiet native
    -- unregister/deletion, never the scenario's dissolve-effect entry point.
    local file=assert(io.open(prefix..'darktide_testlab.lua','r'))
    local source=file:read('*all');file:close()
    local first=assert(source:find('isolation=mod:io_dofile(',1,true))
    local last=assert(source:find('local function elapsed',first,true))
    local f=fixture(false,true)
    local calls=0
    f.system.dissolve_unit=function()error('dissolve effects must not start')end
    local side={side_by_unit={[f.context.unit]='heroes',[f.enemy]='enemies',[f.ally]='heroes'}}
    function side:is_ally(a,b)return self.side_by_unit[a]==self.side_by_unit[b]end
    local env=setmetatable({target_context=function()return f.context end,event=function()end,
        get_mod=function()return {settings=f.settings}end,Unit={alive=function(u)return not u.dead end},
        mod={io_dofile=function()return Isolation end},Managers={time={time=function()return f.time end},
            state={extension={system=function(_,name)
                return name=='side_system' and side or f.system
            end},minion_spawn={_spawned_minions=f.units,despawn_minion=function(_,u)
                assert(u==f.enemy,'foreign unit retired');calls=calls+1;u.dead=true
            end}}}},{__index=_G})
    local chunk=assert(loadstring(source:sub(first,last-1)));setfenv(chunk,env);chunk()
    env.isolation.begin();assert(calls==1 and not f.ally.dead)
    assert(not env.isolation.ready());f.time=4.01
    assert(env.isolation.ready() and env.isolation.restore('off') and f.starts==1)
end
do
    local file=assert(io.open(prefix..'darktide_testlab.lua','r'));local source=file:read('*all');file:close()
    assert(source:find('scripts/extension_systems/training_grounds/shooting_range_steps',1,true),'wrong native hook path')
    local first=assert(source:find('local function start_manual_combat()',1,true))
    local last=assert(source:find('mod.toggle_combat=function()',first,true))
    local state,spawns,threat_phase={manual_pending=true},0,'idle'
    local context={unit={},session={}}
    local env=setmetatable({state=state,mod={},isolation={ready=function()return true end,active=function()return true end},
        targets={entries=function()return {} end},event=function()end,target_context=function()return context end,
        local_range=function()return true end,Unit={alive=function(u)return not u.dead end},health=function()return 1 end,
        spawn=function(breed,distance,id,count,spacing,active)
            assert(breed=='chaos_poxwalker' and distance==2 and count==1 and active==true)
            spawns=spawns+1
        end,threat={status=function()return threat_phase end,begin=function()threat_phase='active' end}}, {__index=_G})
    local chunk=assert(loadstring(source:sub(first,last-1)..'return start_manual_combat'))
    setfenv(chunk,env);chunk()()
    assert(spawns==0 and state.manual and state.empty_combat and not state.manual_pending,'combat activation automatically spawned enemy')
    env.mod.spawn_combat_enemy();assert(spawns==1 and threat_phase=='active','manual spawn did not create exactly one attacker')
    env.mod.spawn_combat_enemy();assert(spawns==1,'manual request replaced a live attacker')
end
do
    local file=assert(io.open(prefix..'darktide_testlab.lua','r'));local source=file:read('*all');file:close()
    local body=assert(source:match('finish=function%(context,reason%)(.-)\n    end%}%)\nisolation='))
    local state={manual={run='manual'}};local restored,cleaned=0,0
    local env=setmetatable({state=state,event=function()end,cleanup=function()cleaned=cleaned+1 end,
        threat={restore=function()restored=restored+1;return true end}}, {__index=_G})
    local chunk=assert(loadstring('return function(context,reason)'..body..'\nend'));setfenv(chunk,env)
    local finish=chunk();finish({run='manual'},'attacker_removed')
    assert(restored==1 and cleaned==0 and state.manual,'attacker death restored default room instead of retaining manual-only combat')
    state.manual=nil;state.run={id='scripted'};finish({run='scripted'},'timeout');assert(cleaned==1)
end
assert(data.options.widgets[1].default_value==true and data.options.widgets[2].default_value==true)
assert(dofile(prefix..'darktide_testlab_localization.lua').testlab_controller_chord.en)
print('testlab_combat=pass VR_chord_no_repeat_partial_release_context_gate native_and_creature_spawners_restore rollback_retry_original_false_one_time_respawn no_ally_or_unknown_trial_mutation')
